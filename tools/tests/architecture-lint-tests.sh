#!/bin/bash
# The architecture lint itself (tools/lint/architecture-lint.sh, FU-28), run against small fixture trees: a clean tree passes,
# and every rule and every ratchet fails with the offending file listed when its rule is broken. It does not lint this
# repository (CI runs the lint for that): the suite must not fail on documentation or unrelated edits.
#   tools/tests/architecture-lint-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 - "$PWD/tools/lint/architecture-lint.sh" <<'PY'
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

lint = sys.argv[1]
failures = 0

def check(condition, message):
    global failures
    print(("ok   " if condition else "FAIL ") + message)
    if not condition:
        failures += 1

SWIFT = {
    "MarkView/Models/AI/AIOperation.swift": "// the one caller\nlet r = try await CLICompletion.run(request)\n",
    "MarkView/Models/AI/Ask.swift": "// Process() in a comment and CLICompletion.run in this one do not count\nstruct Ask {}\n",
    "MarkView/Models/Workspace/Runner.swift": "let process = Process()\n",
    "MarkView/Views/Workspace/Tab.swift": "struct Tab {\n    @EnvironmentObject var workspace: WorkspaceManager\n    @ObservedObject var other: WorkspaceManager\n    @EnvironmentObject var theme: Theme\n}\n",
    "Packages/MarkViewCore/Sources/MarkViewCore/Subprocess.swift": "let process = Process()\n",
}

def write(root, relative, text):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)

def project(root, app_files, build_files=None, extra_refs=()):
    """A project.pbxproj (XML property list) with one target whose Sources phase builds `build_files` (default: all `app_files`)."""
    objects, counter = {}, [0]
    def new(obj):
        counter[0] += 1
        key = f"K{counter[0]:04d}"
        objects[key] = obj
        return key
    groups = {}
    def group_for(directory):
        if directory in groups:
            return groups[directory]
        parent, _, name = directory.rpartition("/")
        key = new({"isa": "PBXGroup", "path": name, "sourceTree": "<group>", "children": []})
        groups[directory] = key
        objects[group_for(parent) if parent else main]["children"].append(key)
        return key
    main = new({"isa": "PBXGroup", "sourceTree": "<group>", "children": []})
    refs = {}
    for path in list(app_files) + list(extra_refs):
        directory, _, name = path.rpartition("/")
        key = new({"isa": "PBXFileReference", "path": name, "sourceTree": "<group>", "lastKnownFileType": "sourcecode.swift"})
        refs[path] = key
        objects[group_for(directory)]["children"].append(key)
    built = [new({"isa": "PBXBuildFile", "fileRef": refs[path]}) for path in (app_files if build_files is None else build_files)]
    phase = new({"isa": "PBXSourcesBuildPhase", "files": built})
    target = new({"isa": "PBXNativeTarget", "name": "MarkView", "buildPhases": [phase]})
    root_object = new({"isa": "PBXProject", "mainGroup": main, "targets": [target]})
    folder = root / "MarkView.xcodeproj"
    folder.mkdir(exist_ok=True)
    (folder / "project.pbxproj").write_bytes(plistlib.dumps({"objects": objects, "rootObject": root_object}, fmt=plistlib.FMT_XML))

def fixture():
    root = Path(tempfile.mkdtemp(prefix="markview-lint-"))
    app_files = []
    for relative, text in SWIFT.items():
        write(root, relative, text)
        if relative.startswith("MarkView/"):
            app_files.append(relative)
    write(root, "MarkView/Resources/Editor/index.html", "<script src=\"js/mv-kit.js\"></script>\n")
    project(root, app_files)
    write(root, "tools/lint/process-allowlist.txt", "# Process() sites\n1 MarkView/Models/Workspace/Runner.swift\n")
    write(root, "tools/lint/clicompletion-allowlist.txt", "# none outside AIOperation\n")
    write(root, "tools/lint/workspace-manager-views.txt", "1 MarkView/Views/Workspace/Tab.swift\n")
    return root

def run(root, *args):
    done = subprocess.run([lint, "--root", str(root), *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return done.returncode, done.stdout

def app_swift(root):
    return sorted(p.relative_to(root).as_posix() for p in (root / "MarkView").rglob("*.swift"))

fixtures = []
def fresh():
    root = fixture()
    fixtures.append(root)
    return root

try:
    # --- A clean tree passes, and says what it counted.
    root = fresh()
    code, out = run(root)
    check(code == 0 and "hold" in out and "process: 1 in 1 file(s), 1 allowed" in out and "workspace-manager: 1 in 1 file(s), 1 allowed" in out,
          "a clean tree passes and reports the ratchet numbers")
    check("Subprocess.swift" not in out and "AIOperation.swift" not in out, "Subprocess.swift and AIOperation.swift are the allowed homes, not counted")

    # --- no-loose-swift
    root = fresh()
    write(root, "MarkView/Models/Loose.swift", "struct Loose {}\n")
    write(root, "MarkView/Views/AlsoLoose.swift", "struct AlsoLoose {}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[no-loose-swift] MarkView/Models/Loose.swift" in out and "[no-loose-swift] MarkView/Views/AlsoLoose.swift" in out,
          "a Swift file directly in Models or Views fails and is named")
    check(out.count("[no-loose-swift]") == 2, "only the loose files are reported for that rule")

    # --- no-vendor-markview
    root = fresh()
    write(root, "MarkView/Models/AI/Ask.swift", "let path = \"Editor/vendor/js/markview-state.js\"\n")
    write(root, "MarkView/Resources/Editor/book.html", "<p>ok</p>\n<script src=\"vendor/js/markview-book.js\"></script>\n")
    code, out = run(root)
    check(code == 1 and "[no-vendor-markview] MarkView/Models/AI/Ask.swift:1" in out and "[no-vendor-markview] MarkView/Resources/Editor/book.html:2" in out,
          "a `vendor/js/markview-` reference in Swift or HTML fails with file and line")

    # --- target-membership
    root = fresh()
    write(root, "MarkView/Models/Git/Orphan.swift", "struct Orphan {}\n")
    code, out = run(root)
    check(code == 1 and "[target-membership] MarkView/Models/Git/Orphan.swift: on disk but not a file reference" in out, "a Swift file on disk that the project does not know fails")
    root = fresh()
    project(root, app_swift(root), extra_refs=["MarkView/Models/Git/Gone.swift"])
    code, out = run(root)
    check(code == 1 and "[target-membership] MarkView/Models/Git/Gone.swift: referenced by MarkView.xcodeproj but missing on disk" in out,
          "a Swift file the project references but that is gone from disk fails")
    root = fresh()
    files = app_swift(root)
    project(root, files, build_files=[f for f in files if not f.endswith("Ask.swift")])
    code, out = run(root)
    check(code == 1 and "[target-membership] MarkView/Models/AI/Ask.swift: referenced by MarkView.xcodeproj but not in the target's Sources build phase" in out,
          "a referenced Swift file that is not compiled by the target fails")

    # --- process ratchet
    root = fresh()
    write(root, "MarkView/Models/Git/Shell.swift", "func f() { let p = Process() }\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[process] MarkView/Models/Git/Shell.swift: 1 Process() site(s), 0 allowed (new sites)" in out, "a new Process() site fails and is named")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Runner.swift", "let a = Process()\nlet b = Process()\n")
    code, out = run(root)
    check(code == 1 and "[process] MarkView/Models/Workspace/Runner.swift: 2 Process() site(s), 1 allowed (more sites)" in out, "a higher Process() count in a listed file fails")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Runner.swift", "struct Runner {}\n")
    code, out = run(root)
    check(code == 1 and "[process] MarkView/Models/Workspace/Runner.swift: 0 Process() site(s), 1 allowed; the count fell" in out,
          "a lower Process() count fails until the allowance is lowered (no slack)")
    before = (root / "tools/lint/process-allowlist.txt").read_text()
    code, out = run(root, "--tighten")
    after = (root / "tools/lint/process-allowlist.txt").read_text()
    check(code == 0 and "1 MarkView/Models/Workspace/Runner.swift" in before and "Runner.swift" not in after and after.startswith("#"),
          "--tighten lowers the allowance to today's count and keeps the header")
    code, out = run(root)
    check(code == 0, "after --tighten the tree passes")
    root = fresh()
    write(root, "MarkView/Models/Git/Shell.swift", "let p = Process()\n")
    project(root, app_swift(root))
    before = (root / "tools/lint/process-allowlist.txt").read_text()
    code, out = run(root, "--tighten")
    check(code == 1 and "--tighten only lowers the allowance" in out and (root / "tools/lint/process-allowlist.txt").read_text() == before,
          "--tighten refuses to raise an allowance and leaves the list alone")

    # --- clicompletion ratchet
    root = fresh()
    write(root, "MarkView/Models/AI/Ask.swift", "func ask() async { _ = try? await CLICompletion.run(request) }\n")
    code, out = run(root)
    check(code == 1 and "[clicompletion] MarkView/Models/AI/Ask.swift: 1 CLICompletion.run call(s), 0 allowed (new sites)" in out, "a new CLICompletion.run call outside AIOperation fails")
    root = fresh()
    write(root, "tools/lint/clicompletion-allowlist.txt", "1 MarkView/Models/AI/Ask.swift\n")
    code, out = run(root)
    check(code == 1 and "[clicompletion] MarkView/Models/AI/Ask.swift: 0 CLICompletion.run call(s), 1 allowed; the count fell" in out, "a lower CLICompletion.run count fails until the allowance is lowered")

    # --- workspace-manager ratchet
    root = fresh()
    write(root, "MarkView/Views/Workspace/Panel.swift", "struct Panel {\n    @EnvironmentObject private var manager: WorkspaceManager\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[workspace-manager] MarkView/Views/Workspace/Panel.swift: 1 @EnvironmentObject WorkspaceManager declaration(s), 0 allowed (new sites)" in out,
          "a new view that takes the whole WorkspaceManager fails")
    check("Tab.swift" not in out, "@ObservedObject and other environment objects are not counted")

    # --- bridge-no-bypass
    root = fresh()
    write(root, "MarkView/Resources/Editor/js/mv-kit.js", "webkit.messageHandlers[name].postMessage(message);\n")
    write(root, "MarkView/Resources/Editor/js/markview-ui-studio-core.js", "var handlers = window.webkit.messageHandlers;\n")
    write(root, "MarkView/Resources/Editor/js/markview-note.js", "// talks to webkit.messageHandlers.bridge only in this comment\nmvBridge.send('ready', {}, 'bridge');\n")
    code, out = run(root)
    check(code == 0 and "bridge-no-bypass" in out, "the one sender, the other host and a comment do not count as a bypass")
    write(root, "MarkView/Resources/Editor/js/markview-bad.js", "ok();\nwindow.webkit.messageHandlers.bridge.postMessage({ type: 'x' });\n")
    write(root, "MarkView/Models/Workspace/EditorWindowPrefs.swift", "let s = \"window.webkit.messageHandlers.bridge.postMessage({})\"\n")
    write(root, "MarkView/Bridge/WebViewBridge.swift", "switch type {\n    case \"ready\":\n        break\n// case \"ignored\":\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[bridge-no-bypass] MarkView/Resources/Editor/js/markview-bad.js:2" in out
          and "[bridge-no-bypass] MarkView/Models/Workspace/EditorWindowPrefs.swift:1" in out
          and "[bridge-no-bypass] MarkView/Bridge/WebViewBridge.swift:2" in out and out.count("[bridge-no-bypass]") == 3,
          "a direct messageHandlers call in a page script or in EditorWindowPrefs, and a string case in WebViewBridge, fail with file and line")

    # --- no-private-escape
    root = fresh()
    write(root, "MarkView/Resources/Editor/js/mv-kit.js", "var table = { '&': '&amp;' };\n")
    write(root, "MarkView/Resources/Editor/js/markview-iframe.js", "// mvkit-exempt: runs in a document without mv-kit.js\nfunction e(s) {\n    return s.replace(/&/g, '&amp;');\n}\n")
    code, out = run(root)
    check(code == 0, "mv-kit.js and a line with an exemption note above it are not private escaping")
    write(root, "MarkView/Resources/Editor/js/markview-bad.js", "ok();\nfunction esc(s) { return s.replace(/&/g, '&amp;'); }\n")
    code, out = run(root)
    check(code == 1 and "[no-private-escape] MarkView/Resources/Editor/js/markview-bad.js:2" in out and out.count("[no-private-escape]") == 1,
          "a private HTML escape in a page script fails with file and line")

    # --- lists
    root = fresh()
    (root / "tools/lint/process-allowlist.txt").unlink()
    code, out = run(root)
    check(code == 1 and "[process] tools/lint/process-allowlist.txt is missing" in out, "a missing allow-list fails")
    code, out = run(root, "--tighten")
    check(code == 0 and (root / "tools/lint/process-allowlist.txt").read_text().count("1 MarkView/Models/Workspace/Runner.swift") == 1, "--tighten creates a missing allow-list from today's counts")
    root = fresh()
    write(root, "tools/lint/process-allowlist.txt", "not a count\n")
    code, out = run(root)
    check(code == 1 and "expected `<count> <path>` once per path" in out, "a malformed allow-list line fails")
    check(subprocess.run([lint, "--bogus"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).returncode == 2, "an unknown option exits 2 with the usage")
finally:
    for folder in fixtures:
        shutil.rmtree(folder, ignore_errors=True)

if failures:
    print(f"architecture-lint checks FAILED: {failures}")
    sys.exit(1)
print("architecture-lint checks passed")
PY
