#!/bin/bash
# The build-warning ratchet itself (tools/lint/build-warnings.sh, AR-43), run against fixture build logs: it counts the distinct
# compiler warnings of this repository's own files (the repeated diagnostic echo lines, dependency files and notes do not count),
# passes at the allowance, and fails for a new warning, a higher count, and a lower count the list does not yet say.
# It does not build or lint this repository: the suite must not depend on the state of the app's warnings.
#   tools/tests/build-warnings-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 - "$PWD/tools/lint/build-warnings.sh" <<'PY'
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

script = sys.argv[1]
failures = 0

def check(condition, message):
    global failures
    print(("ok   " if condition else "FAIL ") + message)
    if not condition:
        failures += 1

fixtures = []

def fresh(allowlist=None):
    """A fixture repository whose allow-list says `allowlist` (a string), or has none when it is None."""
    root = Path(tempfile.mkdtemp(prefix="mv-build-warnings-")).resolve()
    fixtures.append(root)
    (root / "tools/lint").mkdir(parents=True)
    if allowlist is not None:
        (root / "tools/lint/build-warnings-allowlist.txt").write_text(allowlist)
    return root

def warning(root, path, line, column, message):
    """One warning as xcodebuild prints it, with the diagnostic echo the compiler adds after it."""
    where = f"{root}/{path}:{line}:{column}"
    return (f"{where}: warning: {message}\n"
            f"{line} |     let value = work()\n"
            f"  |     `- warning: {message}\n"
            f"  |            |- note: a note about it\n")

def log(root, *entries, name="build.log"):
    path = root / name
    path.write_text("".join(entries))
    return path

def run(root, *logs, tighten=False):
    command = [script, "--root", str(root)]
    for path in logs:
        command += ["--log", str(path)]
    if tighten:
        command.append("--tighten")
    done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return done.returncode, done.stdout

def allowlist(root):
    return (root / "tools/lint/build-warnings-allowlist.txt").read_text()

try:
    # --- A clean build passes against an empty list, and says what it counted.
    root = fresh("# none allowed\n")
    code, out = run(root, log(root))
    check(code == 0 and "0 warning(s) in 0 file(s), 0 allowed" in out, "a build without warnings passes an empty allow-list")

    # --- What counts: a distinct warning of the repository's own file, once however often the compiler prints it.
    root = fresh("# none allowed\n")
    same = warning(root, "MarkView/Models/QA/Run.swift", 12, 9, "capture of 'self' with non-Sendable type")
    code, out = run(root, log(root, same, same, "2026-11-15 appintentsmetadataprocessor[1:2] warning: Metadata extraction skipped\n"))
    check(code == 1 and "MarkView/Models/QA/Run.swift: 1 warning(s), 0 allowed (new)" in out
          and "MarkView/Models/QA/Run.swift:12:9: capture of 'self' with non-Sendable type" in out,
          "a warning is counted once with its echo lines and a repeat, and named with file, line and message")
    check(out.count("Run.swift:12:9") == 1 and "appintents" not in out, "a line that is not a compiler warning of a file is not counted")

    # --- What does not count: dependencies, build products and files outside the repository.
    root = fresh("# none allowed\n")
    code, out = run(root, log(
        root,
        warning(root, "Packages/MarkViewCore/.build/checkouts/dep/Sources/Dep.swift", 3, 1, "a dependency"),
        warning(root, "MarkView.xcodeproj/SourcePackages/checkouts/dep/Dep.swift", 3, 1, "a package checkout"),
        "/Applications/Xcode.app/Contents/Developer/SDK/Foo.h:1:1: warning: a header of the SDK\n",
        "/tmp/elsewhere/Other.swift:4:2: warning: a file of another folder\n"))
    check(code == 0 and "0 warning(s)" in out, "warnings of dependencies, the SDK and files outside the repository are not counted")

    # --- A log of another checkout (CI, a worktree) is read by the part after its own MarkView/ or Packages/ folder.
    root = fresh("# none allowed\n")
    other = "/Users/runner/work/MarkView/MarkView"
    code, out = run(root, log(root, f"{other}/MarkView/Views/Workspace/Tab.swift:7:3: warning: a warning of the CI checkout\n"))
    check(code == 1 and "MarkView/Views/Workspace/Tab.swift: 1 warning(s), 0 allowed (new)" in out, "a warning of another checkout is counted under its repository-relative path")
    plain = str(root).removeprefix("/private")
    code, out = run(root, log(root, f"{plain}/MarkView/Views/Workspace/Tab.swift:7:3: warning: reached without /private\n", name="b2.log"))
    check(code == 1 and "MarkView/Views/Workspace/Tab.swift: 1 warning(s), 0 allowed (new)" in out, "the spelling of the temporary folder with and without /private is the same path")

    # --- The asset catalog names a folder, not a line.
    root = fresh("# none allowed\n")
    code, out = run(root, log(root, f"{root}/MarkView/Assets.xcassets: warning: The app icon set \"AppIcon\" has 3 unassigned children.\n"))
    check(code == 1 and "MarkView/Assets.xcassets: 1 warning(s), 0 allowed (new)" in out, "a warning of the asset catalog (no line number) is counted")

    # --- The ratchet: equal passes, higher fails, lower fails until the list says so.
    root = fresh("# the tolerated\n2 MarkView/Models/QA/Run.swift\n")
    two = [warning(root, "MarkView/Models/QA/Run.swift", n, 1, f"problem {n}") for n in (10, 20)]
    code, out = run(root, log(root, *two))
    check(code == 0 and "2 warning(s) in 1 file(s), 2 allowed" in out, "a count equal to the allowance passes")
    code, out = run(root, log(root, *two, warning(root, "MarkView/Models/QA/Run.swift", 30, 1, "problem 30")))
    check(code == 1 and "Run.swift: 3 warning(s), 2 allowed (more)" in out, "a higher count in a listed file fails")
    code, out = run(root, log(root, *two, warning(root, "MarkView/Models/QA/New.swift", 1, 1, "a new file")))
    check(code == 1 and "New.swift: 1 warning(s), 0 allowed (new)" in out and "Run.swift" not in out,
          "a warning in a file that is not listed fails and only that file is named")
    code, out = run(root, log(root, two[0]))
    check(code == 1 and "1 warning(s), 2 allowed; the count fell" in out, "a lower count fails until the allowance is lowered (no slack)")

    # --- --tighten lowers the list, and refuses to raise it.
    code, out = run(root, log(root, two[0]), tighten=True)
    check(code == 0 and "1 MarkView/Models/QA/Run.swift" in allowlist(root) and "2 MarkView" not in allowlist(root), "--tighten rewrites the list to the lower count")
    code, out = run(root, log(root, two[0]))
    check(code == 0, "the tightened list passes")
    before = allowlist(root)
    code, out = run(root, log(root, *two), tighten=True)
    check(code == 1 and allowlist(root) == before, "--tighten refuses a higher count and leaves the list as it was")
    code, out = run(root, log(root), tighten=True)
    check(code == 0 and "Run.swift" not in allowlist(root), "--tighten drops a file that has no warning left")

    # --- Several logs (the app and the package) are one count.
    root = fresh("# none allowed\n")
    app = log(root, warning(root, "MarkView/Models/QA/Run.swift", 1, 1, "in the app"), name="app.log")
    package = log(root, warning(root, "Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift", 5, 5, "in the package"), name="package.log")
    code, out = run(root, app, package)
    check(code == 1 and "Run.swift: 1 warning(s)" in out and "Settings.swift: 1 warning(s)" in out, "the logs of the app and of the package are counted together")

    # --- The list itself.
    root = fresh(None)
    code, out = run(root, log(root))
    check(code == 1 and "build-warnings-allowlist.txt is missing" in out, "a missing allow-list fails")
    code, out = run(root, log(root), tighten=True)
    check(code == 0 and (root / "tools/lint/build-warnings-allowlist.txt").is_file(), "--tighten creates a missing allow-list")
    root = fresh("not a count\n")
    code, out = run(root, log(root))
    check(code == 1 and "expected `<count> <path>` once per path" in out, "a malformed allow-list line fails")
    root = fresh("1 MarkView/A.swift\n1 MarkView/A.swift\n")
    code, out = run(root, log(root))
    check(code == 1 and "once per path" in out, "a path listed twice fails")
    check(subprocess.run([script, "--bogus"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).returncode == 2, "an unknown option exits 2 with the usage")
finally:
    for folder in fixtures:
        shutil.rmtree(folder, ignore_errors=True)

if failures:
    print(f"build-warnings checks FAILED: {failures}")
    sys.exit(1)
print("build-warnings checks passed")
PY
