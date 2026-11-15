#!/bin/bash
# Task ownership (AR-19): which asynchronous starts in the app have no owner that can cancel them. It reads the working tree,
# classifies every site, and prints a report (default), the unowned count per file (`--counts`, the allow-list format of
# tools/lint/unowned-task-allowlist.txt) or every unowned site with its line (`--sites`). tools/lint/architecture-lint.sh runs it
# as the ratchet rule `unowned-task`; this is the one implementation of the classification.
#
# A site is one of
#   Task { ... }, Task(priority:) { ... }, Task.detached { ... }     an unstructured task
#   Timer.scheduledTimer / Timer(timeInterval:) / Timer.publish      a repeating or delayed callback no one pauses
#   .asyncAfter(                                                     a delayed hop that cannot be cancelled
# A site is OWNED, and not counted, when it is
#   stored     the task is the value of an assignment to a property or to a local that is read again afterwards (`task = Task {`,
#              `let run = Task {` followed by `run.cancel()` / `await run.value`), an argument of `.store(` / `.append(` / `.insert(`
#              (a TaskBag or a collection that someone cancels), or returned (`return Task {`). `_ = Task {` is not stored.
#              A timer or `.asyncAfter` is never stored: they are counted unless they are justified.
#   awaited    `await Task { ... }.value` / `.result`: the caller waits for it in place and is cancelled with it (Task.detached
#              only; a `Task {` that is awaited is a pointless hop and is counted).
#   hop        a `Task { ... }` whose body has no `await` and no `async let` (`Task { @MainActor in self?.deliver(data) }`): it
#              never suspends, so it runs to completion in one turn on its actor and there is nothing to cancel. It is counted
#              apart in the report. A body that awaits, however short, is not a hop.
#   justified  a one-line comment `// task: <why it needs no owner>` on the site's line or on the comment line right above it.
#              Use it for an immediate hop that finishes quickly and touches nothing that dies with its window (a hop onto the main
#              actor from a callback, a button's one-shot action on a shared store). A reason is required: `// task:` alone is not one.
# Everything else is unowned. A migration is finished when its files are out of tools/lint/unowned-task-allowlist.txt.
#
# Usage: tools/lint/task-ownership.sh [--root <repo>] [--counts | --sites | --report]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="report"
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="$(cd "${2:?--root requires a folder}" && pwd)"; shift 2 ;;
        --counts) MODE="counts"; shift ;;
        --sites) MODE="sites"; shift ;;
        --report) MODE="report"; shift ;;
        *) echo "usage: $0 [--root <repo>] [--counts | --sites | --report]" >&2; exit 2 ;;
    esac
done

exec python3 - "$ROOT" "$MODE" <<'PY'
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

root, mode = Path(sys.argv[1]), sys.argv[2]

def blank(text):
    """The code of a Swift file with comments and string contents replaced by spaces (line breaks kept), so that a brace or a
    keyword inside a comment or a string is never read as code and every offset still maps to the same line."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
            continue
        opening = re.match(r'#*"', text[i:i + 40]) if c in '#"' else None
        if opening:
            hashes = opening.group(0).count("#")
            k = i + len(opening.group(0))
            multi = text.startswith('""', k)
            if multi:
                k += 2
            close = ('"""' if multi else '"') + "#" * hashes
            escape = "\\" + "#" * hashes
            while k < n and not text.startswith(close, k):
                k += len(escape) + 1 if text.startswith(escape, k) else 1
            k = min(n, k + len(close))
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:k]))
            i = k
            continue
        out.append(c)
        i += 1
    return "".join(out)

def match_close(code, i, opener):
    """The index of the bracket that closes the one at code[i], or the end of the text."""
    closer = {"{": "}", "(": ")"}[opener]
    depth = 0
    for k in range(i, len(code)):
        if code[k] == opener:
            depth += 1
        elif code[k] == closer:
            depth -= 1
            if depth == 0:
                return k
    return len(code) - 1

def enclosing_end(code, position):
    """The index of the brace that closes the block around `position` (the end of the file at the top level)."""
    depth = 0
    for k in range(position - 1, -1, -1):
        if code[k] == "}":
            depth += 1
        elif code[k] == "{":
            if depth == 0:
                return match_close(code, k, "{")
            depth -= 1
    return len(code)

TASK = re.compile(r"(?<![\w.])Task\s*(?:<[^{}()]*?>)?\s*(?:\((?:[^()]|\([^()]*\))*\))?\s*\{")
DETACHED = re.compile(r"(?<![\w.])Task\s*\.\s*detached\b")
TIMER = re.compile(r"(?<![\w.])Timer\s*\.\s*(?:scheduledTimer|publish)\b|(?<![\w.])Timer\s*\(\s*(?:timeInterval|fire)")
AFTER = re.compile(r"\.asyncAfter\s*\(")
TYPE_DECLARATION = re.compile(r"\b(?:class|struct|enum|actor|extension|protocol|typealias)\s+$")
STORING_CALLS = ("store", "append", "insert")
MARKER = re.compile(r"//\s*task:\s*\S")

def project_files():
    found = []
    for base in ("MarkView", "Packages"):
        folder = root / base
        if folder.is_dir():
            found += [p for p in folder.rglob("*.swift") if p.is_file() and "/Tests/" not in p.as_posix() and "/.build/" not in p.as_posix()]
    return sorted(found)

def closure_end(code, match, kind):
    """(index of the closure's closing brace or argument list's closing parenthesis) for a Task site."""
    if kind == "task":
        return match_close(code, match.end() - 1, "{")
    k = match.end()
    while k < len(code) and code[k] in " \t\n":
        k += 1
    if k < len(code) and code[k] == "(":
        close = match_close(code, k, "(")
        after = close + 1
        while after < len(code) and code[after] in " \t\n":
            after += 1
        if after < len(code) and code[after] == "{":
            return match_close(code, after, "{")
        return close
    if k < len(code) and code[k] == "{":
        return match_close(code, k, "{")
    return k

def classify(code, raw_lines, match, kind, line):
    """'stored', 'awaited', 'justified' or None (unowned) for the site that `match` found at 1-based `line`."""
    line_start = code.rfind("\n", 0, match.start()) + 1
    prefix = code[line_start:match.start()]
    if kind in ("task", "detached") and TYPE_DECLARATION.search(prefix):
        return "skip"
    # justified: `// task: why` on the line or on the comment line right above
    if MARKER.search(raw_lines[line - 1]) or (line >= 2 and raw_lines[line - 2].lstrip().startswith("//") and MARKER.search(raw_lines[line - 2])):
        return "justified"
    if kind not in ("task", "detached"):
        return None
    end = closure_end(code, match, kind)
    if kind == "task" and not re.search(r"\bawait\b|\basync\s+let\b", code[match.end():end]):
        return "hop"                               # a body that never suspends is done in one turn: there is nothing to cancel
    if kind == "detached" and re.match(r"\s*\.\s*(?:value|result)\b", code[end + 1:end + 40]):
        return "awaited"
    # stored: look at what precedes the site on its statement (the previous code line when this one starts with the site)
    before = prefix.strip()
    if not before:
        previous = code[:line_start].rstrip().rsplit("\n", 1)[-1].strip()
        before = previous
    assignments = list(re.finditer(r"(?<![=!<>+\-*/&|^%])=(?![=>])", before))
    rest = before[assignments[-1].end():].strip() if assignments else None
    if rest is not None and (rest == "" or (rest[-1] in "?:" and not re.search(r"[{};]", rest))):
        lvalue = before[:assignments[-1].start()].strip()
        declared = re.match(r"(?:.*[\s;{(])?(let|var)\s+([A-Za-z_]\w*)", lvalue)
        if lvalue.endswith("_") and re.search(r"(?:^|[\s;{(])_$", lvalue):
            return None                            # `_ = Task { }` throws the task away
        if not lvalue:
            return None
        if declared is None:
            return "stored"                        # a property or a collection element: the owner holds the task
        later = code[end + 1:enclosing_end(code, match.start())]
        return "stored" if re.search(r"(?<![\w.])" + re.escape(declared.group(2)) + r"\b", later) else None
    if re.search(r"\.(?:" + "|".join(STORING_CALLS) + r")\(\s*$", before) or re.search(r"(?:^|[\s;{])return\s*$", before):
        return "stored"
    return None

def analyse():
    """(unowned sites as (path, line, kind), owned counter by class, per-file unowned counter by kind)."""
    unowned, owned, sites_total = [], Counter(), Counter()
    for path in project_files():
        raw = path.read_text(encoding="utf-8", errors="replace")
        code = blank(raw)
        raw_lines = raw.splitlines()
        for kind, pattern in (("task", TASK), ("detached", DETACHED), ("timer", TIMER), ("after", AFTER)):
            for match in pattern.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                verdict = classify(code, raw_lines, match, kind, line)
                if verdict == "skip":
                    continue
                sites_total[kind] += 1
                if verdict is None:
                    unowned.append((path.relative_to(root).as_posix(), line, kind))
                else:
                    owned[(kind, verdict)] += 1
    return unowned, owned, sites_total

unowned, owned, sites_total = analyse()
per_file = Counter(path for path, _, _ in unowned)

if mode == "counts":
    for path, count in sorted(per_file.items()):
        print(f"{count} {path}")
elif mode == "sites":
    for path, line, kind in sorted(unowned):
        print(f"{path}:{line}: {kind}")
else:
    by_kind = Counter(kind for _, _, kind in unowned)
    print("task-ownership: sites (total / owned / unowned)")
    for kind, label in (("task", "Task { }"), ("detached", "Task.detached"), ("timer", "Timer"), ("after", "asyncAfter")):
        own = sum(count for (k, _), count in owned.items() if k == kind)
        print(f"  {label:<14} {sites_total[kind]:>4} / {own:>4} / {by_kind[kind]:>4}"
              + ("   owned: " + ", ".join(f"{count} {how}" for (k, how), count in sorted(owned.items()) if k == kind) if own else ""))
    print(f"  unowned: {len(unowned)} in {len(per_file)} file(s)")
    folders = Counter()
    for path, count in per_file.items():
        parts = path.split("/")
        folders["/".join(parts[:3]) if parts[0] == "MarkView" and len(parts) > 3 else "/".join(parts[:2])] += count
    for folder, count in folders.most_common():
        print(f"    {count:>4}  {folder}")
PY
