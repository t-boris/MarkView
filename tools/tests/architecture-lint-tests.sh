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
    # The settings store is the one place that touches UserDefaults and the one that listens to its notification.
    "Packages/MarkViewCore/Sources/MarkViewCore/Settings.swift": "public struct Settings {\n    func f(_ defaults: UserDefaults) { defaults.set(1, forKey: \"k\") }\n    let changes = UserDefaults.didChangeNotification\n}\n",
    # The providers are the one place that names an assistant; strings, paths and trailing comments never count.
    "MarkView/Models/AI/Providers/ClaudeProvider.swift": "struct P {\n    func f(_ t: CLITool) -> Int {\n        switch t {\n        case .claude, .codex: return 1\n        default: return 0\n        }\n    }\n}\n",
    "MarkView/Models/AI/Paths.swift": "let a = \"~/.claude/settings.json\"\nlet b = home.appendingPathComponent(\".codex\")\nlet c = other.claude\nlet d = 1 // .copilot in a comment\n",
    "Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift": "// the one writer and the one place that names the folders\nlet n = Darwin.write(fd, base, count)\nlet t = try data.write(to: tmp)\nlet f = \".dde\"\nlet p = \".markview-\" + kind\n",
    "Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift": "// the one place that makes a Logger\nlet l = Logger(subsystem: \"com.markview.app\", category: \"x\")\n",
    "MarkView/Models/Workspace/Export.swift": "// A comment about .write(to: is not a site\nfunc export() throws { try png.write(to: url) }\n",
    # What the window-wiring rule lets through: closures that are given at construction (`let`, a value type's field), a private or static
    # closure, a computed property, a narrow host protocol and a weak reference to it, and a view that only reads the manager.
    "MarkView/Models/Workspace/Wired.swift": (
        "@MainActor\nprotocol WiredHost: AnyObject {\n    var name: String { get }\n    func open(_ url: URL)\n}\n"
        "final class Wired {\n    private weak var host: (any WiredHost)?\n    let onDone: () -> Void\n    private var retry: (() -> Void)?\n"
        "    static var knob: (Int) -> Int = { $0 }\n    var doubled: (Int) -> Int { { $0 * 2 } }\n"
        "    init(host: any WiredHost, onDone: @escaping () -> Void) { self.host = host; self.onDone = onDone }\n}\n"
        "struct Dialogs {\n    var ask: (String) -> Bool\n}\n"
    ),
    "MarkView/Views/Workspace/Reader.swift": "struct Reader {\n    func f(manager: WorkspaceManager) { let n = manager.flow.features; manager.layout.area = .files; _ = n }\n}\n",
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
    write(root, "tools/lint/assistant-switch-allowlist.txt", "# no assistant is named outside its provider\n")
    write(root, "tools/lint/atomic-write-allowlist.txt", "1 MarkView/Models/Workspace/Export.swift\n")
    write(root, "tools/lint/file-size-allowlist.txt", "# no file is over the limit\n")
    write(root, "tools/lint/project-paths-allowlist.txt", "# none outside ProjectPaths\n")
    write(root, "tools/lint/app-log-allowlist.txt", "# none outside AppLog\n")
    write(root, "tools/lint/domain-cycles-allowlist.txt", "# no cycle between domain folders\n")
    write(root, "tools/lint/window-wiring-hooks.txt", "# no model has a hook that another object assigns\n")
    write(root, "tools/lint/window-wiring-backrefs.txt", "# no model holds the window's manager\n")
    write(root, "tools/lint/window-wiring-views.txt", "# no view writes a hook into a model\n")
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
    check(code == 0 and "hold" in out and "process: 1 in 1 file(s), 1 allowed" in out and "workspace-manager: 1 in 1 file(s), 1 allowed" in out
          and "atomic-write: 1 in 1 file(s), 1 allowed" in out,
          "a clean tree passes and reports the ratchet numbers")
    check("Subprocess.swift" not in out and "AIOperation.swift" not in out, "Subprocess.swift and AIOperation.swift are the allowed homes, not counted")
    check("window-wiring (hooks): 0 in 0 file(s), 0 allowed" in out and "window-wiring (back-references): 0 in 0 file(s), 0 allowed" in out
          and "window-wiring (views): 0 in 0 file(s), 0 allowed" in out,
          "a clean tree reports the three window-wiring counts: a let closure, a struct's closure, a private or static var, a computed property and a host protocol are not wiring")
    check("assistant-switch: 0 in 0 file(s), 0 allowed" in out,
          "the providers, strings, paths, member names and trailing comments do not count as naming an assistant")

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

    # --- semantic-database-actor
    root = fresh()
    write(root, "MarkView/Models/Insight/SemanticDatabase.swift", "// @MainActor in a comment does not count\nactor SemanticDatabase {\n    func search() {}\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0, "a SemanticDatabase declared as an actor passes")
    root = fresh()
    write(root, "MarkView/Models/Insight/SemanticDatabase.swift", "@MainActor\nclass SemanticDatabase {\n    func search() {}\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[semantic-database-actor] MarkView/Models/Insight/SemanticDatabase.swift: `SemanticDatabase` must be declared as an `actor`" in out
          and "[semantic-database-actor] MarkView/Models/Insight/SemanticDatabase.swift:1: `@MainActor` in the database" in out,
          "a SemanticDatabase that is a @MainActor class fails with both reasons")

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

    # --- assistant-switch ratchet
    root = fresh()
    write(root, "MarkView/Models/Workspace/Pick.swift", "func pick(_ tool: CLITool) -> Int {\n    switch tool {\n    case .claude: return 1\n    case .codex, .cline: return 2\n    default: return 0\n    }\n}\nlet same = tool == .antigravity\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[assistant-switch] MarkView/Models/Workspace/Pick.swift: 3 assistant literal(s), 0 allowed (new sites)" in out,
          "a switch case or a comparison that names an assistant outside the providers fails and is counted per line")
    root = fresh()
    write(root, "tools/lint/assistant-switch-allowlist.txt", "1 MarkView/Models/Workspace/Pick.swift\n")
    code, out = run(root)
    check(code == 1 and "[assistant-switch] MarkView/Models/Workspace/Pick.swift: 0 assistant literal(s), 1 allowed; the count fell" in out,
          "a lower assistant count fails until the allowance is lowered")
    root = fresh()
    (root / "tools/lint/assistant-switch-allowlist.txt").unlink()
    code, out = run(root)
    check(code == 1 and "[assistant-switch] tools/lint/assistant-switch-allowlist.txt is missing" in out, "a missing assistant allow-list fails")

    # --- workspace-manager ratchet
    root = fresh()
    write(root, "MarkView/Views/Workspace/Panel.swift", "struct Panel {\n    @EnvironmentObject private var manager: WorkspaceManager\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[workspace-manager] MarkView/Views/Workspace/Panel.swift: 1 @EnvironmentObject WorkspaceManager declaration(s), 0 allowed (new sites)" in out,
          "a new view that takes the whole WorkspaceManager fails")
    check("Tab.swift" not in out, "@ObservedObject and other environment objects are not counted")

    # --- file-size ratchet
    root = fresh()
    write(root, "MarkView/Models/Workspace/Big.swift", "let x = 1\n" * 2003)
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[file-size] MarkView/Models/Workspace/Big.swift: 3 line(s) beyond 2000, 0 allowed (new sites)" in out,
          "a Swift file longer than the limit fails")
    write(root, "tools/lint/file-size-allowlist.txt", "3 MarkView/Models/Workspace/Big.swift\n")
    code, out = run(root)
    check(code == 0 and "file-size: 3 in 1 file(s), 3 allowed" in out, "a listed oversized file passes while it does not grow")
    write(root, "MarkView/Models/Workspace/Big.swift", "let x = 1\n" * 2010)
    code, out = run(root)
    check(code == 1 and "10 line(s) beyond 2000, 3 allowed (more sites)" in out, "an oversized file that grows fails")

    # --- atomic-write ratchet
    root = fresh()
    write(root, "MarkView/Models/Workspace/Store.swift", "func save() throws { try text.write(to: url, atomically: true, encoding: .utf8) }\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[atomic-write] MarkView/Models/Workspace/Store.swift: 1 direct file write(s), 0 allowed (new sites)" in out, "a new direct file write fails and is named")
    check("CoreFiles.swift" not in out and "Export.swift" not in out, "AtomicFile's own file and a listed export are not reported")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Store.swift", "func save() throws { try data.write(toFile: path, atomically: true) }\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[atomic-write] MarkView/Models/Workspace/Store.swift: 1 direct file write(s), 0 allowed (new sites)" in out, "write(toFile:) counts too")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Export.swift", "struct Export {}\n")
    code, out = run(root)
    check(code == 1 and "[atomic-write] MarkView/Models/Workspace/Export.swift: 0 direct file write(s), 1 allowed; the count fell" in out,
          "a converted write fails until the allowance is lowered")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Export.swift", "func a() throws { try x.write(to: u); try y.write(to: v) }\nfunc b() throws { try z.write(to: w) }\n")
    code, out = run(root)
    check(code == 1 and "[atomic-write] MarkView/Models/Workspace/Export.swift: 2 direct file write(s), 1 allowed (more sites)" in out, "a second write line in a listed file fails")

    # --- project-paths ratchet
    root = fresh()
    write(root, "MarkView/Models/Workspace/Store.swift", "func f(root: URL) -> URL { root.appendingPathComponent(\".dde/cache\") }\n// \".dde in a comment does not count\nlet tab = \".markview-terminal-\" + id\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[project-paths] MarkView/Models/Workspace/Store.swift: 2 path literal(s), 0 allowed (new sites)" in out,
          "a literal that starts with .dde or .markview- fails and is named, comments are not counted")
    check("CoreFiles.swift" not in out, "ProjectPaths' own file is the allowed home, not counted")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Store.swift", "let help = \"Kept in .dde/workflow/workflow.json\"\nlet name = \"dde\"\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0, "prose that mentions .dde/ inside a longer sentence is not a path literal")

    # --- app-log ratchet
    root = fresh()
    write(root, "MarkView/Models/Workspace/Noisy.swift", "func f() { NSLog(\"Could not save: %@\", name) }\nlet l = Logger(subsystem: \"com.markview.app\", category: \"y\")\n// NSLog( in a comment does not count\nlet ok = AppLog.workspace\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[app-log] MarkView/Models/Workspace/Noisy.swift: 2 NSLog or Logger site(s), 0 allowed (new sites)" in out,
          "a new NSLog or Logger(subsystem:) fails and is named, comments are not counted")
    check("AppLog.swift" not in out, "AppLog's own file is the allowed home, not counted")
    # --- window-wiring (AR-17)
    root = fresh()
    write(root, "MarkView/Models/Workspace/Hooked.swift", (
        "final class Hooked {\n    var onTimer: () -> Void = {}\n    var onBranch: ((String) -> Void)?\n    var openFile: (@MainActor (URL, Int?) -> Void)?\n}\n"
        "protocol Link: AnyObject {\n    var onOutput: ((Data) -> Void)? { get set }\n}\n"))
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[window-wiring] MarkView/Models/Workspace/Hooked.swift: 4 closure wiring propert(ies)" in out and "0 allowed (new sites)" in out,
          "a `var` of function type in a class, and a settable one in a protocol, fail and are counted per declaration")
    write(root, "tools/lint/window-wiring-hooks.txt", "4 MarkView/Models/Workspace/Hooked.swift\n")
    code, out = run(root)
    check(code == 0 and "window-wiring (hooks): 4 in 1 file(s), 4 allowed" in out, "a listed hook passes while the count does not rise")
    write(root, "MarkView/Models/Workspace/Hooked.swift", "final class Hooked {\n    let onTimer: () -> Void\n    init(onTimer: @escaping () -> Void) { self.onTimer = onTimer }\n}\n")
    code, out = run(root)
    check(code == 1 and "[window-wiring] MarkView/Models/Workspace/Hooked.swift: 0 closure wiring propert(ies)" in out and "the count fell" in out,
          "a hook turned into an initializer parameter fails until the allowance is lowered")
    code, out = run(root, "--tighten")
    check(code == 0 and "Hooked.swift" not in (root / "tools/lint/window-wiring-hooks.txt").read_text(), "--tighten drops the converted hook from the list")
    root = fresh()
    write(root, "MarkView/Models/Workspace/Holder.swift", (
        "final class Holder {\n    weak var workspace: WorkspaceManager?\n    let tabs: TabsController\n"
        "    init(tabs: TabsController) { self.tabs = tabs }\n}\n"
        "@MainActor\nprotocol NeedsWindow: AnyObject {\n    var controlWorkspace: WorkspaceManager { get }\n}\n"
        "final class Maker {\n    func make(session: Session, task: Task?) {\n        session.host = self\n        task?.presenter = self\n    }\n}\n"))
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[window-wiring] MarkView/Models/Workspace/Holder.swift: 4 reference(s) to the window's WorkspaceManager" in out and "0 allowed (new sites)" in out,
          "a property of type WorkspaceManager, a protocol that returns it and `x.host = self` after construction fail and are counted")
    root = fresh()
    write(root, "MarkView/Views/Workspace/Writer.swift", (
        "struct Writer {\n    func f(workspaceManager: WorkspaceManager, window: NSWindow) {\n"
        "        workspaceManager.research.pdfExporter = { [weak self] text, name in self?.export(text, name) ?? false }\n"
        "        workspaceManager.insight.page = self\n        workspaceManager.hostWindow = window\n        let n = workspaceManager.flow.features\n    }\n}\n"))
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[window-wiring] MarkView/Views/Workspace/Writer.swift: 2 hook(s) a view writes into the window's models" in out and "0 allowed (new sites)" in out,
          "a view that assigns a closure or itself to a part of the manager fails; storing a window or reading the manager does not count")
    root = fresh()
    (root / "tools/lint/window-wiring-hooks.txt").unlink()
    code, out = run(root)
    check(code == 1 and "[window-wiring] tools/lint/window-wiring-hooks.txt is missing" in out, "a missing window-wiring allow-list fails")

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

    # --- js-interpolation
    root = fresh()
    write(root, "MarkView/Views/Workspace/GoodPage.swift", (
        "func ok(_ web: WKWebView, _ value: String) {\n"
        "    web.evaluateJavaScript(\"window.reset()\")\n"
        "    if let script = JS.call(\"window.f\", args: [\"a\\(value)\"]) { web.evaluateJavaScript(script) }\n"
        "    web.evaluateJavaScript(JS.call(\"window.g\") ?? \"\")\n"
        "    web.callAsyncJavaScript(\"return x\", arguments: [\"x\": value], in: nil, contentWorld: .page) { _ in }\n"
        "    // web.evaluateJavaScript(\"window.f(\\(value))\") is only a comment\n"
        "    web.evaluateJavaScript(Self.probe)\n"
        "    web.evaluateJavaScript(constant)\n"
        "}\n"
        "let constant = \"window.k()\"\n"
        "static let probe = #\"\"\"\n(function () { var n = \\#(3); })()\n\"\"\"#\n"))
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0 and "js-interpolation" in out, "constant scripts, JS.call with interpolated Swift arguments, arguments: and a raw-string constant pass js-interpolation")
    write(root, "MarkView/Views/Workspace/BadPage.swift", (
        "func bad(_ web: WKWebView, _ value: String) {\n"
        "    web.evaluateJavaScript(\"window.f(\\(value))\")\n"
        "    let script = \"window.g('\\(value)')\"\n"
        "    web.evaluateJavaScript(script)\n"
        "    web.evaluateJavaScript(Self.build(value))\n"
        "    web.evaluateJavaScript(\"\"\"\n"
        "        window.k(\\(value))\n"
        "        \"\"\")\n"
        "    web.callAsyncJavaScript(\"return \\(value)\", arguments: [:], in: nil, contentWorld: .page) { _ in }\n"
        "    let built = Self.build(value)\n"
        "    web.evaluateJavaScript(built)\n"
        "}\n"
        "static func build(_ v: String) -> String { \"window.h(\\(v))\" }\n"))
    project(root, app_swift(root))
    code, out = run(root)
    reported = {line.split(" ")[3] for line in out.splitlines() if line.startswith("  [js-interpolation]")}
    check(code == 1 and reported == {f"MarkView/Views/Workspace/BadPage.swift:{n}:" for n in (2, 4, 5, 6, 9, 11)},
          "a script built by interpolation fails js-interpolation: directly, through a variable, through a helper function, as a multi-line literal, and in callAsyncJavaScript")
    check("GoodPage.swift" not in out, "the good page is not reported")

    # --- webview-configuration
    root = fresh()
    write(root, "MarkView/Views/Workspace/GoodHost.swift", (
        "func make() -> WKWebView {\n"
        "    // WKWebViewConfiguration() is only named in a comment, as is WKWebView(frame: .zero)\n"
        "    let configuration = WebHost.makeConfiguration(handlers: [.message(\"bridge\", handler)])\n"
        "    let view = WebHost.makeWebView(configuration: configuration)\n"
        "    var views: [WKWebView] = []\n"
        "    let none = [WKWebView]()\n"
        "    let browser = BrowserWebView(frame: .zero, configuration: configuration) // WKWebView(frame: .zero) in a trailing comment\n"
        "    WebHost.markInspectable(browser)\n"
        "    return view\n"
        "}\n"))
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0 and "webview-configuration" in out, "WebHost calls, a subclass, a type annotation and comments pass webview-configuration")
    write(root, "MarkView/Views/Workspace/BadHost.swift", (
        "func make() {\n"
        "    let configuration = WKWebViewConfiguration()\n"
        "    let view = WKWebView(frame: .zero, configuration: configuration)\n"
        "    let other = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())\n"
        "}\n"))
    project(root, app_swift(root))
    code, out = run(root)
    reported = {line.split(" ")[3] for line in out.splitlines() if line.startswith("  [webview-configuration]")}
    check(code == 1 and reported == {f"MarkView/Views/Workspace/BadHost.swift:{n}:" for n in (2, 3, 4)},
          "a configuration or a web view made directly fails webview-configuration with file and line")
    check("GoodHost.swift" not in out, "the good host is not reported")

    # --- settings-literal and settings-observer
    root = fresh()
    write(root, "MarkView/Views/Workspace/GoodSettings.swift", (
        "struct Good {\n"
        "    @AppStorage(Setting.fontScalePercent) private var percent: Int\n"
        "    @WindowStorage(Setting.qaInspectorWidth) private var width: Double\n"
        "    private let defaults: UserDefaults\n"
        "    init(defaults: UserDefaults = .standard) { self.defaults = defaults; _flag = AppStorage(Setting.gitHubEnabled) }\n"
        "    func f() {\n"
        "        let value = Settings(defaults).value(Setting.autoAnalyze)\n"
        "        Settings.standard.set(value, for: Setting.autoAnalyze)\n"
        "        layer.add(animation, forKey: \"sway\")\n"
        "        view.setValue(false, forKey: \"drawsBackground\")\n"
        "        pending.removeValue(forKey: \"id\")\n"
        "        // UserDefaults.standard.set(1, forKey: \"k\") and didChangeNotification are only named in a comment\n"
        "        let observer = SettingsObserver([Setting.gitHubEnabled.erased]) { }\n"
        "    }\n"
        "}\n"))
    write(root, "Packages/MarkViewCore/Tests/MarkViewCoreTests/SettingsTests.swift", "let d = UserDefaults(suiteName: \"t\")!\nd.set(1, forKey: \"x\")\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0 and "settings-literal" in out and "settings-observer" in out,
          "registry keys, Settings, SettingsObserver, an injected UserDefaults, other forKey: calls, comments, Settings.swift itself and package tests pass the settings rules")
    write(root, "MarkView/Views/Workspace/BadSettings.swift", (
        "struct Bad {\n"
        "    @AppStorage(\"legacy.key\") private var a = 1\n"
        "    @WindowStorage(\"window.key\") private var b = 2.0\n"
        "    init() { _c = AppStorage(wrappedValue: true, \"dynamic.key\") }\n"
        "    func f(_ defaults: UserDefaults) {\n"
        "        UserDefaults.standard.set(1, forKey: \"k\")\n"
        "        let v = defaults.string(forKey: key)\n"
        "        let w = UserDefaults(suiteName: \"s\")\n"
        "    }\n"
        "    var body: some View {\n"
        "        Text(\"x\").onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in }\n"
        "    }\n"
        "}\n"))
    write(root, "Packages/MarkViewCore/Sources/MarkViewCore/Elsewhere.swift", "func g(_ ud: UserDefaults) { _ = ud.object(forKey: \"x\") }\nlet n = UserDefaults.didChangeNotification\n")
    project(root, app_swift(root))
    code, out = run(root)
    literal = {line.split(" ")[3] for line in out.splitlines() if line.startswith("  [settings-literal]")}
    observer = {line.split(" ")[3] for line in out.splitlines() if line.startswith("  [settings-observer]")}
    check(code == 1 and literal == {f"MarkView/Views/Workspace/BadSettings.swift:{n}:" for n in (2, 3, 4, 6, 7, 8)} | {"Packages/MarkViewCore/Sources/MarkViewCore/Elsewhere.swift:1:"},
          "a string-literal @AppStorage or @WindowStorage key, and a direct UserDefaults call, fail settings-literal with file and line")
    check(observer == {"MarkView/Views/Workspace/BadSettings.swift:11:", "Packages/MarkViewCore/Sources/MarkViewCore/Elsewhere.swift:2:"},
          "an observer of every UserDefaults write fails settings-observer with file and line")
    check("GoodSettings.swift" not in out and "MarkViewCore/Settings.swift" not in out, "the good file and the settings store itself are not reported")

    # --- tabs-direct
    root = fresh()
    write(root, "MarkView/Views/Workspace/Reader.swift", "struct Reader {\n    // workspaceManager.activeTab in a comment does not count\n    @EnvironmentObject var tabs: TabsController\n    var url: URL? { tabs.activeTab?.url }\n    var tree: FileNode? { workspaceManager.tabs.activeTab == nil ? nil : workspaceManager.rootNode }\n}\n")
    write(root, "MarkView/Models/Workspace/WorkspaceManager.swift", "final class WorkspaceManager {\n    func start() {\n        objectWillChange.send()\n        // tabs.objectWillChange in a comment does not count\n        tabs.events.sink { _ in }\n    }\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0 and "tabs-direct" in out, "views that observe the tabs, a manual objectWillChange and a comment do not break tabs-direct")
    write(root, "MarkView/Views/Workspace/Bad.swift", "struct Bad {\n    var count: Int { workspaceManager.openTabs.count }\n    var index: Int { manager.activeTabIndex }\n    var text: String? { wm?.lastSaveError }\n}\n")
    write(root, "MarkView/Models/Workspace/WorkspaceManager.swift", "final class WorkspaceManager {\n    init() {\n        tabs.objectWillChange\n            .sink { [weak self] _ in self?.objectWillChange.send() }\n        gitClient.objectWillChange.sink { _ in }\n    }\n}\n")
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 1 and "[tabs-direct] MarkView/Views/Workspace/Bad.swift:2" in out and "[tabs-direct] MarkView/Views/Workspace/Bad.swift:3" in out
          and "[tabs-direct] MarkView/Views/Workspace/Bad.swift:4" in out
          and "[tabs-direct] MarkView/Models/Workspace/WorkspaceManager.swift:3" in out and "[tabs-direct] MarkView/Models/Workspace/WorkspaceManager.swift:5" in out
          and out.count("[tabs-direct]") == 5,
          "a view that reads the tabs through the manager and a manager that forwards a part's changes fail with file and line")

    # --- unchecked-sendable (AR-43)
    root = fresh()
    write(root, "MarkView/Models/QA/GoodBoxes.swift", (
        "// unchecked Sendable: in a whole-line comment only, as is nonisolated(unsafe)\n"
        "/// A doc comment may say @unchecked Sendable without being a site.\n"
        "// unchecked Sendable: `lock` guards every field.\n"
        "final class Above: @unchecked Sendable {}\n"
        "final class Same: @unchecked Sendable {} // unchecked Sendable: only `queue` touches it\n"
        "enum Registry {\n"
        "    // unchecked Sendable: every access is inside `lock.withLock`.\n"
        "    nonisolated(unsafe) private static var running: [Int: Int] = [:]\n"
        "    private nonisolated(unsafe) var other = 0 // unchecked Sendable: main actor only\n"
        "}\n"
        "final class Checked: Sendable {}\n"
        "let note = \"@unchecked Sendable in a string\" // @unchecked Sendable in a trailing comment\n"))
    write(root, "Packages/MarkViewCore/Sources/MarkViewCore/GoodBox.swift", (
        "// unchecked Sendable: `lock` guards every field.\n"
        "public final class Box: @unchecked Sendable {}\n"))
    project(root, app_swift(root))
    code, out = run(root)
    check(code == 0 and "unchecked-sendable" in out, "a justified escape hatch (same line or previous line), a checked Sendable and comments pass unchecked-sendable")
    write(root, "MarkView/Models/QA/BadBoxes.swift", (
        "final class NoComment: @unchecked Sendable {}\n"
        "// unchecked Sendable: this comment belongs to the line below, not to the one after it\n"
        "let unrelated = 1\n"
        "final class TwoAway: @unchecked Sendable {}\n"
        "// unchecked Sendable:\n"
        "final class EmptyReason: @unchecked Sendable {}\n"
        "// guarded by a lock\n"
        "final class WrongMarker: @unchecked Sendable {}\n"
        "enum Statics {\n"
        "    nonisolated(unsafe) static var counter = 0\n"
        "    nonisolated (unsafe) static var spaced = 0\n"
        "}\n"))
    write(root, "Packages/MarkViewCore/Sources/MarkViewCore/BadBox.swift", "public final class Box2: @unchecked Sendable {}\n")
    project(root, app_swift(root))
    code, out = run(root)
    reported = {line.split(" ")[3] for line in out.splitlines() if line.startswith("  [unchecked-sendable]")}
    check(code == 1 and reported == {f"MarkView/Models/QA/BadBoxes.swift:{n}:" for n in (1, 4, 6, 8, 10, 11)}
          | {"Packages/MarkViewCore/Sources/MarkViewCore/BadBox.swift:1:"},
          "an @unchecked Sendable or nonisolated(unsafe) with no `// unchecked Sendable: <reason>` on the same or the previous line fails unchecked-sendable with file and line")
    check("GoodBoxes.swift" not in out and "GoodBox.swift" not in out, "the justified file is not reported")

    # --- domain-cycles ratchet (AR-21)
    def domain_files(root, models=None, views=None):
        """Write the given {domain: swift text} to MarkView/Models/<domain>/Files.swift (and Views), then refresh the project."""
        for layer, domains in (("Models", models or {}), ("Views", views or {})):
            for domain, text in domains.items():
                write(root, f"MarkView/{layer}/{domain}/{domain}Files.swift", text)
        project(root, app_swift(root))

    ALPHA = "struct AlphaOne {}\nstruct AlphaTwo {}\nstruct AlphaThree {}\n"
    BETA = "struct BetaOne {}\nstruct BetaTwo {}\n"
    root = fresh()
    check("domain-cycles: 0 in 0 pair(s), 0 allowed" in run(root)[1], "a tree without a cycle reports domain-cycles 0")
    domain_files(root, models={"Alpha": ALPHA + "let b = BetaOne()\n", "Beta": BETA + "let a = [AlphaOne(), AlphaTwo()]\n"})
    code, out = run(root)
    check(code == 1 and "[domain-cycles] Models/Alpha -> Models/Beta: 1 type(s) named back across a cycle, 0 allowed (new sites)" in out and out.count("[domain-cycles]") == 1,
          "two domains that name each other's types are a cycle: the lighter direction is the back-edge and a new one fails, named")
    write(root, "tools/lint/domain-cycles-allowlist.txt", "1 Models/Alpha -> Models/Beta  # Alpha shows a Beta type\n")
    code, out = run(root)
    check(code == 0 and "domain-cycles: 1 in 1 pair(s), 1 allowed" in out, "a listed back-edge passes while it does not grow")
    domain_files(root, models={"Beta": BETA + "let a = [AlphaOne(), AlphaTwo(), AlphaThree()]\n"})
    code, out = run(root)
    check(code == 0, "the forward direction may grow: only the back-edge is limited")
    domain_files(root, models={"Alpha": ALPHA + "let b = [BetaOne(), BetaTwo()]\n"})
    code, out = run(root)
    check(code == 1 and "[domain-cycles] Models/Alpha -> Models/Beta: 2 type(s) named back across a cycle, 1 allowed (more sites)" in out,
          "a back-edge that names one more type fails")
    domain_files(root, models={"Alpha": ALPHA + "let b = 1\n"})
    code, out = run(root)
    check(code == 1 and "[domain-cycles] Models/Alpha -> Models/Beta: 0 type(s) named back across a cycle, 1 allowed; the count fell" in out,
          "a cycle that is gone fails until the allowance is lowered (no slack)")
    code, out = run(root, "--tighten")
    check(code == 0 and "Alpha -> Models/Beta" not in (root / "tools/lint/domain-cycles-allowlist.txt").read_text(), "--tighten drops the entry of a cycle that is gone")

    root = fresh()
    ignored = ("// BetaOne in a comment\nlet s = \"BetaTwo in a string\"\nlet t = other.BetaOne\n"
               "struct Local {\n    struct BetaTwo {}\n}\nlet u = Local.BetaTwo()\nlet w = AlphaTwo()\n")
    domain_files(root, models={"Alpha": ALPHA + ignored, "Beta": BETA + "let a = AlphaOne()\n"})
    code, out = run(root)
    check(code == 0 and "domain-cycles: 0 in 0 pair(s)" in out,
          "a type named in a comment, in a string, as a member, or that is also declared nested in the domain does not count as a dependency")
    domain_files(root, models={"Alpha": ALPHA + "let line = \"count: \\(BetaOne().id)\"\n"})
    code, out = run(root)
    check(code == 1 and "[domain-cycles] Models/Alpha -> Models/Beta: 1 type(s)" in out, "a type named inside a string interpolation counts")

    root = fresh()
    domain_files(root, models={"Alpha": ALPHA + "let b = BetaOne()\n", "Beta": BETA + "let a = [AlphaOne(), AlphaTwo()]\n"},
                 views={"Alpha": "struct AlphaView {}\nlet m = BetaOne()\n", "Beta": "struct BetaView {}\n"})
    write(root, "tools/lint/domain-cycles-allowlist.txt", "1 Models/Alpha -> Models/Beta\n")
    code, out = run(root)
    check(code == 0 and "domain-cycles: 1 in 1 pair(s), 1 allowed" in out, "a view that names a model is not a cycle: Models and Views are separate graphs")
    domain_files(root, views={"Beta": "struct BetaView { let a = AlphaView() }\n"})
    code, out = run(root)
    check(code == 0 and "domain-cycles: 1 in 1 pair(s), 1 allowed" in out, "a view domain that names a view of another domain, which names only models back, is not a cycle")
    domain_files(root, views={"Alpha": "struct AlphaView {}\nlet b = BetaView()\n"})
    code, out = run(root)
    check(code == 1 and "[domain-cycles] Views/Alpha -> Views/Beta: 1 type(s) named back across a cycle, 0 allowed (new sites)" in out,
          "two view domains that name each other are a cycle of the Views graph")

    root = fresh()
    domain_files(root, models={"Alpha": ALPHA + "let w = [WorkspaceOne(), WorkspaceTwo()]\n", "Workspace": "struct WorkspaceOne {}\nstruct WorkspaceTwo {}\nlet a = AlphaOne()\n"})
    code, out = run(root)
    check(code == 1 and "[domain-cycles] Models/Alpha -> Models/Workspace: 2 type(s) named back across a cycle, 0 allowed (new sites)" in out,
          "in a pair with Workspace, the composition domain, the back-edge points at it even when it is the heavier direction")
    root = fresh()
    domain_files(root, models={"Alpha": ALPHA + "let b = BetaOne()\n", "Beta": BETA + "let a = [AlphaOne(), AlphaTwo()]\n"})
    write(root, "tools/lint/domain-cycles-allowlist.txt", "2 Models/Beta -> Models/Alpha  # the allow-list names the direction\n")
    code, out = run(root)
    check(code == 0 and "domain-cycles: 2 in 1 pair(s), 2 allowed" in out, "the direction an allow-list entry names is the back-edge, whatever the weights")
    write(root, "tools/lint/domain-cycles-allowlist.txt", "2 Models/Beta -> Models/Alpha  # the allow-list names the direction\n1 Models/Zeta -> Models/Eta  # gone\n")
    run(root, "--tighten")
    check((root / "tools/lint/domain-cycles-allowlist.txt").read_text().endswith("2 Models/Beta -> Models/Alpha  # the allow-list names the direction\n"),
          "--tighten keeps the reason of the entries that stay")

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
