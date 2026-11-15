#!/bin/bash
# Architecture lint (FU-28, CLAUDE.md "Architecture & Refactoring Rules" 4): the structural rules of the repository, kept out of
# the feature tests. It reads the working tree, lists every violation and exits 1 when there is one. CI runs it in the pure job.
#
# Rules that must hold:
#   no-loose-swift       no *.swift directly in MarkView/Models or MarkView/Views (every file lives in a domain folder)
#   no-vendor-markview   no reference to `vendor/js/markview-` in the app's Swift code and HTML (the scripts live in Editor/js)
#   target-membership    every MarkView/**/*.swift on disk is a file reference and a Sources build file of the Xcode target in
#                        MarkView.xcodeproj/project.pbxproj, and every Swift file the project references exists on disk
#   semantic-database-actor  MarkView/Models/Insight/SemanticDatabase.swift declares `actor SemanticDatabase` and no @MainActor, so
#                        none of its sqlite3 calls can run on the main thread (AR-37)
#   bridge-no-bypass     (AR-28) the editor page's scripts send through mvBridge.send only: no `messageHandlers` in
#                        Editor/js/*.js (except mv-kit.js, the one sender, and markview-ui-studio-*.js, a different host) or in
#                        EditorWindowPrefs.swift, and no string `case "..."` in Bridge/WebViewBridge.swift (handlers are registered)
#   no-private-escape    (AR-29) no private HTML escaping in Editor/js/*.js: every `&amp;` literal outside mv-kit.js (mvKit.escapeHtml and
#                        escapeAttr are the one implementation) needs an `mvkit-exempt:` note within three lines above it
#   js-interpolation     (AR-04) no `evaluateJavaScript(` or `callAsyncJavaScript(` in MarkView/ or Packages/ takes a script that is built by
#                        string interpolation `\(...)`, directly or through a variable or a helper function: a script that takes values
#                        is a `JS.call(function, args:)` (JSON-encoded arguments) or a constant literal with `arguments:`. A raw string
#                        (`#"..."#`) interpolates with `\#(`; it is not scanned and is for a script made of compile-time constants only
# Ratchets: a count that may fall and never rise. Today's sites are listed per file in an allow-list; a new site or a higher
# count fails, and so does a lower count that the list does not yet say (run `--tighten`), so that the allowance never has slack.
#   process              Process() outside Packages/MarkViewCore Subprocess.swift     tools/lint/process-allowlist.txt
#   clicompletion        CLICompletion.run outside Models/AI/AIOperation.swift          tools/lint/clicompletion-allowlist.txt
#   workspace-manager    `@EnvironmentObject ... WorkspaceManager` declarations         tools/lint/workspace-manager-views.txt
# A migration that reaches zero ends with an empty list (no lines), which means none allowed.
#
# Usage: tools/lint/architecture-lint.sh [--root <repo>] [--tighten]
#   --root     lint another tree (the self-test uses a fixture); default: this repository
#   --tighten  rewrite the allow-lists to today's counts; refuses when any count rose or a new site exists
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIGHTEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="$(cd "${2:?--root requires a folder}" && pwd)"; shift 2 ;;
        --tighten) TIGHTEN=1; shift ;;
        *) echo "usage: $0 [--root <repo>] [--tighten]" >&2; exit 2 ;;
    esac
done

exec python3 - "$ROOT" "$TIGHTEN" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

root, tighten = Path(sys.argv[1]), sys.argv[2] == "1"
violations = []   # (rule, message)
notes = []

def swift_files(*folders):
    found = []
    for folder in folders:
        base = root / folder
        if base.is_dir():
            found += sorted(p for p in base.rglob("*.swift") if p.is_file())
    return found

def rel(path):
    return path.relative_to(root).as_posix()

def code_lines(path):
    """The lines of a Swift file that are not whole-line comments, with their numbers."""
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not line.lstrip().startswith("//"):
            yield number, line

# --- no-loose-swift
for folder in ("MarkView/Models", "MarkView/Views"):
    base = root / folder
    if base.is_dir():
        for path in sorted(base.glob("*.swift")):
            violations.append(("no-loose-swift", f"{rel(path)}: a Swift file directly in {folder}; move it into a domain folder"))

# --- no-vendor-markview
pattern = "vendor/js/markview-"
app = root / "MarkView"
if app.is_dir():
    for path in sorted(p for p in app.rglob("*") if p.is_file() and p.suffix in (".swift", ".html")):
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if pattern in line:
                violations.append(("no-vendor-markview", f"{rel(path)}:{number}: references `{pattern}`; the editor scripts live in Resources/Editor/js"))

# --- target-membership
def project_swift_files():
    """(files referenced by the project, files in the Sources build phases of its native targets), as repo-relative paths."""
    project = root / "MarkView.xcodeproj" / "project.pbxproj"
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(project)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if converted.returncode != 0:
        raise RuntimeError(f"plutil could not read {rel(project)}: {converted.stderr.strip()}")
    objects = json.loads(converted.stdout)["objects"]
    parent = {}
    for key, obj in objects.items():
        if obj["isa"] == "PBXGroup":
            for child in obj.get("children", []):
                parent[child] = key
    def full_path(key):
        parts = []
        while key:
            obj = objects[key]
            where, name = obj.get("sourceTree"), obj.get("path")
            if where == "<group>" and name:
                parts.append(name)
            elif where in ("SOURCE_ROOT", "<absolute>") and name:
                parts.append(name)
                break
            key = parent.get(key)
        return "/".join(reversed(parts))
    refs = {key: full_path(key) for key, obj in objects.items()
            if obj["isa"] == "PBXFileReference" and obj.get("path", "").endswith(".swift")}
    built = set()
    for obj in objects.values():
        if obj["isa"] != "PBXNativeTarget":
            continue
        for phase_key in obj.get("buildPhases", []):
            phase = objects[phase_key]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_key in phase.get("files", []):
                ref = objects[build_key].get("fileRef")
                if ref in refs:
                    built.add(refs[ref])
    return set(refs.values()), built

if (root / "MarkView.xcodeproj" / "project.pbxproj").is_file():
    try:
        referenced, built = project_swift_files()
        on_disk = {rel(p) for p in swift_files("MarkView")}
        for path in sorted(on_disk - referenced):
            violations.append(("target-membership", f"{path}: on disk but not a file reference of MarkView.xcodeproj"))
        for path in sorted((on_disk & referenced) - built):
            violations.append(("target-membership", f"{path}: referenced by MarkView.xcodeproj but not in the target's Sources build phase"))
        for path in sorted(referenced - on_disk):
            violations.append(("target-membership", f"{path}: referenced by MarkView.xcodeproj but missing on disk"))
        for path in sorted(built - referenced):
            violations.append(("target-membership", f"{path}: in the Sources build phase but not on disk"))
    except (RuntimeError, OSError, KeyError, ValueError) as error:
        violations.append(("target-membership", f"could not compare the project with the disk: {error}"))
else:
    violations.append(("target-membership", "MarkView.xcodeproj/project.pbxproj is missing"))

# --- ratchets
def count_sites(files, matcher, exclude=lambda path: False):
    counts = {}
    for path in files:
        if exclude(path):
            continue
        hits = sum(1 for _, line in code_lines(path) if matcher.search(line))
        if hits:
            counts[rel(path)] = hits
    return counts

def read_allowlist(name):
    """The allowance per file, or None when the list does not exist."""
    path = root / "tools" / "lint" / name
    if not path.is_file():
        return None
    allowed = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        match = re.fullmatch(r"(\d+)\s+(\S.*)", text)
        if not match or match.group(2) in allowed:
            violations.append((name, f"tools/lint/{name}:{number}: expected `<count> <path>` once per path"))
            continue
        allowed[match.group(2)] = int(match.group(1))
    return allowed

def write_allowlist(name, header, counts):
    lines = [header.rstrip("\n")] + [f"{count} {path}" for path, count in sorted(counts.items())]
    (root / "tools" / "lint" / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

def ratchet(rule, name, noun, counts, header):
    allowed = read_allowlist(name)
    if allowed is None:
        if tighten:
            write_allowlist(name, header, counts)
            notes.append(f"{rule}: created tools/lint/{name} with {sum(counts.values())} in {len(counts)} file(s)")
        else:
            violations.append((rule, f"tools/lint/{name} is missing (create it with --tighten)"))
        return
    rose = {path: (allowed.get(path, 0), count) for path, count in counts.items() if count > allowed.get(path, 0)}
    fell = {path: (allowed[path], counts.get(path, 0)) for path in allowed if counts.get(path, 0) < allowed[path]}
    if tighten:
        if rose:
            for path, (was, now) in sorted(rose.items()):
                violations.append((rule, f"{path}: {now} {noun}, {was} allowed; --tighten only lowers the allowance"))
        else:
            write_allowlist(name, header, counts)
            return
    else:
        for path, (was, now) in sorted(rose.items()):
            kind = "new" if was == 0 else "more"
            violations.append((rule, f"{path}: {now} {noun}, {was} allowed ({kind} sites); remove them instead of adding"))
        for path, (was, now) in sorted(fell.items()):
            violations.append((rule, f"{path}: {now} {noun}, {was} allowed; the count fell, lower the allowance in tools/lint/{name} (--tighten) so it cannot rise again"))
    total = sum(counts.values())
    notes.append(f"{rule}: {total} in {len(counts)} file(s), {sum(allowed.values())} allowed")

app_swift = swift_files("MarkView")
package_swift = swift_files("Packages")
ratchet("process", "process-allowlist.txt", "Process() site(s)",
        count_sites(app_swift + package_swift, re.compile(r"(?<![A-Za-z0-9_])Process\(\)"),
                    exclude=lambda p: rel(p).startswith("Packages/MarkViewCore/") and p.name == "Subprocess.swift"),
        "# Process() sites outside Packages/MarkViewCore Subprocess.swift (AR-25). `<count> <path>`; a ratchet that only falls.\n"
        "# Run tools/lint/architecture-lint.sh --tighten after removing a site; the goal is an empty list.")
ratchet("clicompletion", "clicompletion-allowlist.txt", "CLICompletion.run call(s)",
        count_sites(app_swift, re.compile(r"CLICompletion\.run"), exclude=lambda p: rel(p) == "MarkView/Models/AI/AIOperation.swift"),
        "# CLICompletion.run calls outside Models/AI/AIOperation.swift (AR-26). `<count> <path>`; a ratchet that only falls.\n"
        "# Run tools/lint/architecture-lint.sh --tighten after removing a call; the goal is an empty list.")
ratchet("workspace-manager", "workspace-manager-views.txt", "@EnvironmentObject WorkspaceManager declaration(s)",
        count_sites(app_swift, re.compile(r"@EnvironmentObject\b.*:\s*WorkspaceManager\b")),
        "# `@EnvironmentObject ... WorkspaceManager` declarations: views that take the whole manager (AR-14). `<count> <path>`; a ratchet\n"
        "# that only falls. Run tools/lint/architecture-lint.sh --tighten after narrowing a view's dependency.")

# --- semantic-database-actor
database = root / "MarkView" / "Models" / "Insight" / "SemanticDatabase.swift"
if database.is_file():
    if not any(re.match(r"\s*actor\s+SemanticDatabase\b", line) for _, line in code_lines(database)):
        violations.append(("semantic-database-actor", f"{rel(database)}: `SemanticDatabase` must be declared as an `actor`; its SQLite calls must not run on the main thread"))
    for number, line in code_lines(database):
        if "@MainActor" in line:
            violations.append(("semantic-database-actor", f"{rel(database)}:{number}: `@MainActor` in the database; its SQLite calls must stay off the main thread"))

# --- bridge-no-bypass
bridge_senders = {"mv-kit.js"}   # and the UI Studio runtime parts below: a different host with its own handler
page_files = []
js_dir = root / "MarkView" / "Resources" / "Editor" / "js"
if js_dir.is_dir():
    page_files += sorted(p for p in js_dir.glob("*.js") if p.is_file() and p.name not in bridge_senders and not p.name.startswith("markview-ui-studio-"))
page_files += [p for p in [root / "MarkView" / "Models" / "Workspace" / "EditorWindowPrefs.swift"] if p.is_file()]
for path in page_files:
    for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if "messageHandlers" in line and not line.lstrip().startswith(("//", "*", "/*")):
            violations.append(("bridge-no-bypass", f"{rel(path)}:{number}: talks to `messageHandlers` directly; send through mvBridge.send so the contract is checked"))
for relative in ("MarkView/Bridge/WebViewBridge.swift",):
    path = root / relative
    if path.is_file():
        for number, line in code_lines(path):
            if re.match(r'\s*case\s+"', line):
                violations.append(("bridge-no-bypass", f"{relative}:{number}: a string `case` on a message type; register a typed handler (TypedWebBridge.on) instead"))

# --- no-private-escape
if js_dir.is_dir():
    for path in sorted(p for p in js_dir.glob("*.js") if p.is_file() and p.name != "mv-kit.js"):
        text_lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for index, line in enumerate(text_lines):
            if "&amp;" in line and not any("mvkit-exempt:" in near for near in text_lines[max(0, index - 3):index + 1]):
                violations.append(("no-private-escape", f"{rel(path)}:{index + 1}: escapes HTML itself; use window.mvKit.escapeHtml / escapeAttr"))

# --- js-interpolation (AR-04)
def skip_literal(text, i):
    """`text[i]` starts a Swift string literal (`"`, `\"\"\"`, or raw `#"`). Returns (index after it, whether it interpolates with `\\(`)."""
    hashes = 0
    k = i
    while text[k] == "#":
        hashes += 1
        k += 1
    multi = text.startswith('"' * 3, k)
    k += 3 if multi else 1
    close = ('"' * 3 if multi else '"') + "#" * hashes
    marker = "\\" + "#" * hashes
    interpolates = False
    while k < len(text):
        if text.startswith(close, k):
            return k + len(close), interpolates
        if text.startswith(marker, k):
            k += len(marker)
            if k < len(text) and text[k] == "(":
                if hashes == 0:
                    interpolates = True
                k = skip_group(text, k)
            else:
                k += 1
            continue
        k += 1
    return k, interpolates

def skip_group(text, i):
    """`text[i]` is `(`: the index after its matching `)`, with string literals skipped whole."""
    depth = 0
    k = i
    while k < len(text):
        c = text[k]
        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
            k, _ = skip_literal(text, k)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    return k

def expression(text, i, stop_at_comma):
    """The Swift expression that starts at `text[i]`: (its text, whether a string literal in it interpolates). It ends at a
    top-level `)` or `,` (an argument) or, for an initializer, at the first line break that does not continue it."""
    k = i
    depth = 0
    interpolates = False
    while k < len(text):
        c = text[k]
        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
            k, hit = skip_literal(text, k)
            interpolates = interpolates or hit
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0 and stop_at_comma:
            break
        elif c == "\n" and depth == 0 and not stop_at_comma:
            rest = text[k:].lstrip()
            if not rest.startswith(("+", ".", "?", ":", "&&", "||")):
                break
        k += 1
    return text[i:k], interpolates

def function_bodies(files):
    """name -> [(file, line, body text)] of every `func name(` in the given files."""
    found = {}
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*[<(]", text):
            brace = text.find("{", match.end())
            if brace < 0:
                continue
            depth, k = 0, brace
            while k < len(text):
                c = text[k]
                if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
                    k, _ = skip_literal(text, k)
                    continue
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            found.setdefault(match.group(1), []).append((path, text.count("\n", 0, match.start()) + 1, text[brace:k]))
    return found

def literal_interpolates(text):
    """Whether any string literal in `text` interpolates with `\\(`."""
    k = 0
    while k < len(text):
        c = text[k]
        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 40])):
            k, hit = skip_literal(text, k)
            if hit:
                return True
            continue
        k += 1
    return False

script_files = swift_files("MarkView", "Packages")
script_functions = function_bodies(script_files)
for path in script_files:
    if "/Tests/" in rel(path):
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in re.finditer(r"\b(?:evaluateJavaScript|callAsyncJavaScript)\(", text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if text[line_start:match.start()].lstrip().startswith("//"):
            continue
        number = text.count("\n", 0, match.start()) + 1
        argument, interpolates = expression(text, match.end(), True)
        argument = argument.strip()
        where = f"{rel(path)}:{number}"
        if argument.startswith("JS."):
            continue
        if interpolates:
            violations.append(("js-interpolation", f"{where}: the script is built by string interpolation; use JS.call(function, args:) or a constant script with `arguments:`"))
            continue
        name = re.match(r"^(?:[A-Za-z_]\w*\.)*([A-Za-z_]\w*)\s*(\(|$)", argument)
        if not name:
            continue
        if name.group(2) == "(":   # a helper function builds the script
            for helper_path, helper_line, body in script_functions.get(name.group(1), []):
                if literal_interpolates(body):
                    violations.append(("js-interpolation", f"{where}: `{name.group(1)}` ({rel(helper_path)}:{helper_line}) builds the script by string interpolation"))
            continue
        # a variable or a property: its initializer (a bare name is looked up in this file, a qualified one in all files)
        declaration = None
        text_of = text
        pattern = r"\b(?:static\s+)?(?:let|var)\s+" + re.escape(name.group(1)) + r"\b[^=\n{]*=\s*"
        for candidate in re.finditer(pattern, text):
            if declaration is None or candidate.start() < match.start():
                declaration = candidate
        if declaration is None and "." in argument.split("(")[0]:
            for other in script_files:
                other_text = other.read_text(encoding="utf-8", errors="replace")
                found = re.search(pattern, other_text)
                if found:
                    declaration, text_of = found, other_text
                    break
        if declaration is None:
            continue   # a parameter: the caller builds the script
        initializer, init_interpolates = expression(text_of, declaration.end(), False)
        if initializer.strip().startswith("JS."):
            continue
        if init_interpolates:
            violations.append(("js-interpolation", f"{where}: `{name.group(1)}` is built by string interpolation; use JS.call(function, args:)"))
            continue
        helper = re.match(r"\s*(?:[A-Za-z_]\w*\.)*([A-Za-z_]\w*)\s*\(", initializer)
        if helper:
            for helper_path, helper_line, body in script_functions.get(helper.group(1), []):
                if literal_interpolates(body):
                    violations.append(("js-interpolation", f"{where}: `{name.group(1)}` comes from `{helper.group(1)}` ({rel(helper_path)}:{helper_line}), which builds the script by string interpolation"))

# --- report
rules = ["no-loose-swift", "no-vendor-markview", "target-membership", "semantic-database-actor", "process", "clicompletion", "workspace-manager", "bridge-no-bypass", "no-private-escape", "js-interpolation"]
if violations:
    print(f"architecture-lint: {len(violations)} violation(s)")
    for rule in rules + sorted({r for r, _ in violations} - set(rules)):
        for found_rule, message in violations:
            if found_rule == rule:
                print(f"  [{rule}] {message}")
    for note in notes:
        print(f"  ({note})")
    sys.exit(1)
print("architecture-lint: " + ", ".join(rules) + " hold")
for note in notes:
    print(f"  {note}")
PY
