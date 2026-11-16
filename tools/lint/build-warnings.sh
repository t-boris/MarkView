#!/bin/bash
# Build-warning ratchet (AR-43): the number of compiler warnings of the app target and of Packages/MarkViewCore may fall and never rise.
# It reads the log of an `xcodebuild` or `swift build` run, counts every distinct `<file>:<line>:<column>: warning: <message>` line (the
# compiler repeats each warning as a diagnostic echo that starts with spaces, a line number or a bar; those are not counted) and
# compares the count per file with tools/lint/build-warnings-allowlist.txt (`<count> <path>`, no line at all means none allowed).
# A warning in a file that is not on the list fails, so does a higher count, and so does a lower count the list does not yet say
# (run `--tighten`), so that the allowance never has slack. Only files of this repository count: a warning of a dependency does not.
# CI (the `build` job of .github/workflows/ci.yml) feeds it the logs of `swift test` and of the cached app build. The cached build only
# compiles what changed, so its log can miss old warnings: that is why the allowance is empty, which a log cannot fall below.
#
# Usage: tools/lint/build-warnings.sh [--log <file>]... [--root <repo>] [--tighten]
#   --log      a build log to read; repeat it for several (xcodebuild of the app, `swift build --build-tests` of the package)
#   --root     the repository the paths in the logs belong to (the self-test uses a fixture); default: this repository
#   --tighten  rewrite the allow-list to today's counts; refuses when a count rose or a file is new
# Without `--log` it builds both from a clean derived-data folder in the temporary directory (several minutes) and reads those logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TIGHTEN=0
LOGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --log) LOGS+=("${2:?--log requires a file}"); shift 2 ;;
        --root) ROOT="$(cd "${2:?--root requires a folder}" && pwd)"; shift 2 ;;
        --tighten) TIGHTEN=1; shift ;;
        *) echo "usage: $0 [--log <file>]... [--root <repo>] [--tighten]" >&2; exit 2 ;;
    esac
done

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

if [ ${#LOGS[@]} -eq 0 ]; then
    WORK="$(mktemp -d)"
    echo "build-warnings: building the app and the package (a clean build, several minutes)" >&2
    (cd "$ROOT" && xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug -derivedDataPath "$WORK/derived" \
        CODE_SIGNING_ALLOWED=NO build > "$WORK/app.log" 2>&1) || { tail -40 "$WORK/app.log" >&2; echo "build-warnings: the app build failed" >&2; exit 1; }
    (cd "$ROOT" && swift build --build-tests --scratch-path "$WORK/package" --package-path Packages/MarkViewCore > "$WORK/package.log" 2>&1) \
        || { tail -40 "$WORK/package.log" >&2; echo "build-warnings: the package build failed" >&2; exit 1; }
    LOGS=("$WORK/app.log" "$WORK/package.log")
fi

exec python3 - "$ROOT" "$TIGHTEN" "${LOGS[@]}" <<'PY'
import re
import sys
from pathlib import Path

root, tighten, logs = Path(sys.argv[1]).resolve(), sys.argv[2] == "1", sys.argv[3:]
allow_path = root / "tools" / "lint" / "build-warnings-allowlist.txt"
HEADER = ("# Compiler warnings of the app target and of Packages/MarkViewCore (AR-43): `<count> <path>`, a ratchet that only falls.\n"
          "# No line means none allowed. Fix the warning instead of adding a line; run tools/lint/build-warnings.sh --tighten after removing one.")

def relative(location):
    """The repository-relative path of an absolute path in a log, or None for a file that is not the repository's own."""
    path = location
    for prefix in (str(root), "/private" + str(root), str(root).removeprefix("/private")):
        if path.startswith(prefix + "/"):
            path = path[len(prefix) + 1:]
            break
    else:
        # A build of another checkout of the same project (CI, a worktree): keep what follows its own MarkView/ or Packages/ folder.
        found = None
        for anchor in ("/MarkView/", "/Packages/"):
            index = path.rfind(anchor)
            if index >= 0 and (found is None or index > found[0]):
                found = (index, anchor)
        if found is None:
            return None
        path = path[found[0] + 1:]
    if "/.build/" in "/" + path or "SourcePackages" in path or path.startswith(("/", "..")):
        return None
    return path if path.startswith(("MarkView/", "Packages/")) else None

seen = {}    # (relative path, line or "", message) -> where it was first seen
for log in logs:
    for raw in Path(log).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.startswith("/") or ": warning: " not in raw:
            continue
        location, message = raw.split(": warning: ", 1)
        message = re.sub(r"\s*\[#\w+\]$", "", message).strip()
        match = re.match(r"^(.*?):(\d+):(\d+)$", location)
        if match:
            path, line = match.group(1), f"{match.group(2)}:{match.group(3)}"
        else:   # the asset compiler names a catalog and a child, `/x/Assets.xcassets:./AppIcon.appiconset/...`
            path, line = location.split(":", 1)[0], ""
        where = relative(path)
        if where is None:
            continue
        seen.setdefault((where, line, message), None)

counts = {}
for path, _, _ in seen:
    counts[path] = counts.get(path, 0) + 1

allowed = {}
violations = []
if allow_path.is_file():
    for number, line in enumerate(allow_path.read_text(encoding="utf-8").splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        match = re.fullmatch(r"(\d+)\s+(\S.*)", text)
        if not match or match.group(2) in allowed:
            violations.append(f"tools/lint/{allow_path.name}:{number}: expected `<count> <path>` once per path")
            continue
        allowed[match.group(2)] = int(match.group(1))
elif not tighten:
    violations.append(f"tools/lint/{allow_path.name} is missing (create it with --tighten)")

rose = {p: (allowed.get(p, 0), n) for p, n in counts.items() if n > allowed.get(p, 0)}
fell = {p: (allowed[p], counts.get(p, 0)) for p in allowed if counts.get(p, 0) < allowed[p]}

def write_allowlist():
    lines = [HEADER] + [f"{n} {p}" for p, n in sorted(counts.items())]
    allow_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

if tighten:
    if rose:
        for path, (was, now) in sorted(rose.items()):
            violations.append(f"{path}: {now} warning(s), {was} allowed; --tighten only lowers the allowance")
    else:
        write_allowlist()
        print(f"build-warnings: allow-list written, {sum(counts.values())} warning(s) in {len(counts)} file(s)")
        sys.exit(0)
else:
    for path, (was, now) in sorted(rose.items()):
        kind = "new" if was == 0 else "more"
        violations.append(f"{path}: {now} warning(s), {was} allowed ({kind}); fix them instead of adding")
        for (where, line, message) in sorted(seen):
            if where == path:
                violations.append(f"  {where}:{line}: {message}" if line else f"  {where}: {message}")
    for path, (was, now) in sorted(fell.items()):
        violations.append(f"{path}: {now} warning(s), {was} allowed; the count fell, lower the allowance in tools/lint/{allow_path.name} (--tighten) so it cannot rise again")

if violations:
    print(f"build-warnings: {len(violations)} problem(s)")
    for message in violations:
        print(f"  {message}" if not message.startswith("  ") else message)
    sys.exit(1)
print(f"build-warnings: {sum(counts.values())} warning(s) in {len(counts)} file(s), {sum(allowed.values())} allowed")
PY
