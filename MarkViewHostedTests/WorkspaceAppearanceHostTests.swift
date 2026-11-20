import AppKit
import Combine
import MarkViewCore
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

extension EditorHostTests {
    @MainActor func testLayoutPresetRules() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let shipped = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Layouts", isDirectory: true))
        func scratchFolder() -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("layout-preset-tests-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// A preset file of the current schema; `edit` changes the JSON object before it is written out.
        func presetJSON(_ edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
            var object: [String: Any] = [
                "schema": 1, "id": "mine", "name": "Mine", "symbol": "star", "summary": "My own layout",
                "panels": ["files": true, "center": true, "right": false, "agents": false] as [String: Any],
                "left": "files", "right": "contents", "tool": "qa"
            ]
            edit(&object)
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        func parse(_ data: Data, tools: ToolRegistry = .shared) -> Result<LayoutPreset, LayoutPreset.Problem> {
            LayoutPreset.parse(data, tools: tools)
        }

        /// True when the file is refused and the reason contains `fragment`.
        func refused(_ data: Data, _ fragment: String) -> Bool {
            if case .failure(let problem) = parse(data) { return problem.reason.contains(fragment) }
            return false
        }

        @MainActor func run() {
            // MARK: The presets that ship

            let library = LayoutLibrary.load(builtInFolder: shipped, userFolder: nil)
            func shippedPreset(_ id: String) -> LayoutPreset? { library.presets.first { $0.id == id } }
            check(library.ignored.isEmpty, "every shipped preset file is usable (\(library.ignored.map { "\($0.file): \($0.reason)" }))")
            check(library.presets.map(\.id) == ["writing", "review", "qa", "cockpit"], "the four presets of DEC-002 ship, in the order Writing, Review, QA, Cockpit")
            check(library.presets.map(\.name) == ["Writing", "Review", "QA", "Cockpit"], "their names are the ones the menu shows")
            check(Set(library.presets.map(\.symbol)).count == 4, "each has its own symbol")
            check(shippedPreset("review")?.tool == .git && shippedPreset("qa")?.tool == .qa && shippedPreset("cockpit")?.tool == .cockpit
                  && shippedPreset("writing")?.tool == nil, "Review opens Git, QA opens End-to-End QA, Cockpit opens the Cockpit, Writing opens no tool")
            check(library.presets.allSatisfy { ToolRegistry.shared.tools.map(\.id).contains($0.tool ?? .git) }, "every tool a preset names is in the tool registry")
            check(shippedPreset("cockpit")?.panels == LayoutPreset.Panels(files: false, center: true, right: false, agents: true)
                  && shippedPreset("writing")?.panels == LayoutPreset.Panels(files: true, center: true, right: true, agents: false),
                  "Cockpit shows the center and the agents; Writing shows files, center and right")
            check(library.presets.allSatisfy { $0.panels.files || $0.panels.center || $0.panels.right }, "no shipped preset hides every panel")

            // MARK: Validation

            check({ if case .success = parse(presetJSON()) { return true } else { return false } }(), "a complete file is a preset")
            check({
                if case .success(let preset) = parse(presetJSON { $0["summary"] = nil; $0["left"] = nil; $0["right"] = nil; $0["tool"] = nil }) {
                    return preset.summary == "" && preset.left == nil && preset.right == nil && preset.tool == nil
                }
                return false
            }(), "summary, left, right and tool are optional")
            check({
                if case .success(let preset) = parse(presetJSON()) {
                    return preset.id == "mine" && preset.name == "Mine" && preset.left == .files && preset.right == .contents && preset.tool == .qa
                        && preset.panels == LayoutPreset.Panels(files: true, center: true, right: false, agents: false)
                }
                return false
            }(), "every field is read as written")

            check(refused(Data("{ nope".utf8), "not valid JSON"), "text that is not JSON is refused")
            check(refused(Data("[1, 2]".utf8), "must be an object"), "a top level that is not an object is refused")
            check(refused(presetJSON { $0["schema"] = nil }, "\"schema\""), "a file without a schema is refused")
            check(refused(presetJSON { $0["schema"] = "1" }, "\"schema\""), "a schema written as text is refused")
            check(refused(presetJSON { $0["schema"] = true }, "\"schema\""), "a schema written as true is refused")
            check(refused(presetJSON { $0["schema"] = 2 }, "newer MarkView"), "a newer schema is named as written by a newer MarkView")
            check(refused(presetJSON { $0["schema"] = 0 }, "schema 0"), "an older schema is refused with its number")
            check(refused(presetJSON { $0["colour"] = "red" }, "unknown key \"colour\""), "an unknown key is refused by name")
            check(refused(presetJSON { $0["panels"] = ["files": true, "center": true, "right": true, "agents": true, "dock": true] as [String: Any] }, "unknown key \"panels.dock\""),
                  "an unknown panel is refused by name")
            check(refused(presetJSON { $0["panels"] = ["files": true, "center": true, "right": true] as [String: Any] }, "\"panels.agents\" is missing"),
                  "a panel that is not stated is refused: a preset describes the whole row")
            check(refused(presetJSON { $0["panels"] = ["files": 1, "center": true, "right": true, "agents": false] as [String: Any] }, "\"panels.files\" has the wrong type"),
                  "a panel written as a number is refused")
            check(refused(presetJSON { $0["id"] = "Mine" }, "\"id\""), "an id with a capital letter is refused")
            check(refused(presetJSON { $0["id"] = "mine\n" }, "\"id\""), "an id with a line break is refused")
            check(refused(presetJSON { $0["id"] = "-mine" }, "\"id\""), "an id that starts with a hyphen is refused")
            check(refused(presetJSON { $0["id"] = "../mine" }, "\"id\""), "an id that is a path is refused")
            check(refused(presetJSON { $0["id"] = String(repeating: "a", count: 41) }, "\"id\""), "an id longer than 40 characters is refused")
            check(refused(presetJSON { $0["id"] = "" }, "\"id\""), "an empty id is refused")
            check(refused(presetJSON { $0["name"] = "  " }, "\"name\""), "a blank name is refused")
            check(refused(presetJSON { $0["name"] = "Two\nlines" }, "\"name\""), "a name with a line break is refused")
            check(refused(presetJSON { $0["name"] = String(repeating: "n", count: 41) }, "\"name\""), "a name longer than 40 characters is refused")
            check(refused(presetJSON { $0["symbol"] = "Star Fill" }, "\"symbol\""), "a symbol that is not a symbol name is refused")
            check(refused(presetJSON { $0["summary"] = String(repeating: "s", count: 121) }, "\"summary\""), "a summary longer than 120 characters is refused")
            check(refused(presetJSON { $0["panels"] = ["files": false, "center": false, "right": false, "agents": true] as [String: Any] }, "one of them must stay"),
                  "a preset that hides the files, center and right panels is refused")
            check(refused(presetJSON { $0["left"] = "terminal" }, "\"left\" must be \"files\" or \"issues\" (found \"terminal\")"), "an unknown left panel is refused with the choices")
            check(refused(presetJSON { $0["right"] = "git" }, "\"right\" must be \"contents\" or \"feature\""), "an unknown right panel is refused with the choices")
            check(refused(presetJSON { $0["tool"] = "terminal" }, "unknown tool \"terminal\"; the tools are git, deployments"), "an unknown tool is refused and the known ones are named")
            check(refused(presetJSON { $0["panels"] = ["files": true, "center": false, "right": true, "agents": false] as [String: Any] }, "hides"),
                  "a tool with the center panel hidden is refused")
            check(refused(presetJSON { $0["name"] = String(repeating: "x", count: LayoutPreset.maxFileSize) }, "larger than 16 KB"), "a file over the size limit is refused before it is parsed")
            check(refused(presetJSON { $0["id"] = "bad id" + String(repeating: "x\u{0007}", count: 3) }, "\"id\""), "control characters in a value do not reach the message")
            if case .failure(let problem) = parse(presetJSON { $0["tool"] = "x\n\u{0007}" + String(repeating: "y", count: 200) }) {
                check(!problem.reason.contains("\n") && problem.reason.count < 400, "a message quotes a bad value on one line and shortened")
            } else { check(false, "a tool with control characters is refused") }

            // A registry other than the app's decides which tools a preset may open: the same file is a preset in one and refused in the other.
            let fake = ToolDescriptor(id: ToolID(rawValue: "fakeTool"), title: "Fake", icon: "star", sentinelPath: ".dde/.markview-fake", restorable: false)
            let extended = ToolRegistry(tools: ToolRegistry.shared.tools + [fake])
            let fakeFile = presetJSON { $0["tool"] = "fakeTool" }
            check({ if case .success(let preset) = parse(fakeFile, tools: extended) { return preset.tool == fake.id } else { return false } }()
                  && refused(fakeFile, "unknown tool \"fakeTool\""), "a tool added to the registry can be named by a preset, and is unknown to the real one")

            // MARK: A person's folder

            let root = scratchFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let user = root.appendingPathComponent("layouts", isDirectory: true)
            try! FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            func write(_ name: String, _ data: Data) { try! data.write(to: user.appendingPathComponent(name)) }

            check(LayoutLibrary.load(builtInFolder: shipped, userFolder: root.appendingPathComponent("nothing-here")).ignored.isEmpty,
                  "a person with no layouts folder has no problems and the four presets")
            check(LayoutLibrary.load(builtInFolder: nil, userFolder: nil).ignored.map(\.file) == ["Layouts"], "an app without its presets folder says so")

            write("b-mine.json", presetJSON { $0["id"] = "mine" })
            write("a-first.json", presetJSON { $0["id"] = "first"; $0["name"] = "First"; $0["tool"] = nil })
            write("c-writing.json", presetJSON { $0["id"] = "writing" })
            write("d-twice.json", presetJSON { $0["id"] = "mine" })
            write("e-broken.json", Data("{ nope".utf8))
            write("f-unknown-tool.json", presetJSON { $0["id"] = "other"; $0["tool"] = "terminal" })
            write("g-huge.json", Data(repeating: 0x20, count: LayoutPreset.maxFileSize + 1))
            write("notes.txt", Data("not a layout".utf8))
            write(".hidden.json", presetJSON { $0["id"] = "hidden" })
            let brokenBefore = try! Data(contentsOf: user.appendingPathComponent("e-broken.json"))

            let mixed = LayoutLibrary.load(builtInFolder: shipped, userFolder: user)
            check(mixed.presets.map(\.id) == ["writing", "review", "qa", "cockpit", "first", "mine"], "the person's presets follow the built-in ones, in file-name order")
            check(mixed.presets.first { $0.id == "first" }?.name == "First", "a person's preset is read like a shipped one")
            check(mixed.ignored.map(\.file) == ["c-writing.json", "d-twice.json", "e-broken.json", "f-unknown-tool.json", "g-huge.json"],
                  "every file that cannot be used is listed by name, and notes and hidden files are not layout files (\(mixed.ignored.map(\.file)))")
            func reason(_ file: String) -> String { mixed.ignored.first { $0.file == file }?.reason ?? "" }
            check(reason("c-writing.json").contains("\"writing\" is the id of a built-in layout"), "a person's preset cannot take a built-in id, and the list says why")
            check(reason("d-twice.json").contains("\"mine\" is the id of a built-in layout or of another file"), "a second file with the same id is refused, the first one wins")
            check(reason("e-broken.json").contains("not valid JSON"), "a broken file says it is not JSON")
            check(reason("f-unknown-tool.json").contains("unknown tool \"terminal\""), "a file with an unknown tool says which tool")
            check(reason("g-huge.json").contains("larger than 16 KB"), "an oversized file is reported without being read")
            check(try! Data(contentsOf: user.appendingPathComponent("e-broken.json")) == brokenBefore
                  && FileManager.default.fileExists(atPath: user.appendingPathComponent("g-huge.json").path), "a file that cannot be used is left exactly as it was")

            let many = root.appendingPathComponent("many", isDirectory: true)
            try! FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
            for index in 0..<(LayoutLibrary.userFileLimit + 3) {
                let name = String(format: "layout-%03d", index)
                try! presetJSON { $0["id"] = name }.write(to: many.appendingPathComponent(name + ".json"))
            }
            let crowded = LayoutLibrary.load(builtInFolder: nil, userFolder: many)
            check(crowded.presets.count == LayoutLibrary.userFileLimit && crowded.ignored.filter { $0.reason.contains("only the first 64") }.count == 3,
                  "a folder with more than 64 files has its first 64 read and the rest listed")

            // MARK: Applying a preset: one window's tabs

            let suite = "layout-preset-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            // Two windows of the same app share one UserDefaults; each has its own PanelLayout.
            let windowA = PanelLayout(defaults: defaults), windowB = PanelLayout(defaults: defaults)
            windowA.gitSection = .pullRequests
            windowA.issuesFeature = "login"
            windowA.workspaceArea = .projectMap
            check(windowA.leftPanel == "files" && windowA.navigatorTab == .contents, "a window starts on Files and Contents")

            windowA.apply(shippedPreset("review")!)
            check(windowA.leftPanel == "issues" && windowA.navigatorTab == .feature, "Review puts the Issues list on the left and the Tasks on the right of the window it is applied to")
            check(windowB.leftPanel == "files" && windowB.navigatorTab == .contents, "another window that is open keeps its own tabs")
            check(windowA.gitSection == .pullRequests && windowA.issuesFeature == "login" && windowA.workspaceArea == .projectMap,
                  "the window's other choices (Git section, open feature, area) are not touched")

            windowA.apply(shippedPreset("cockpit")!)
            check(windowA.leftPanel == "issues" && windowA.navigatorTab == .feature, "a preset that names no tabs (Cockpit) leaves the window's tabs as they are")
            windowA.apply(shippedPreset("qa")!)
            check(windowA.leftPanel == "issues" && windowA.navigatorTab == .feature, "QA names the right tab only; the left one stays")
            windowA.apply(shippedPreset("writing")!)
            check(windowA.leftPanel == "files" && windowA.navigatorTab == .contents, "Writing brings the window back to Files and Contents")
            check(windowB.leftPanel == "files" && windowB.navigatorTab == .contents && windowB.gitSection == .changes && windowB.workspaceArea == .files,
                  "and the other window has not moved through any of it")
            windowB.apply(shippedPreset("review")!)
            check(windowA.leftPanel == "files" && windowA.navigatorTab == .contents, "applying in the second window leaves the first alone")

        }

        run()

        // MARK: The catalog reads the person's folder in the background

        /// Waits (at most five seconds) until `condition` holds, letting the catalog's tasks run.
        @MainActor func eventually(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }

        @MainActor func catalogReads() async {
            let root = scratchFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let user = root.appendingPathComponent("layouts", isDirectory: true)
            try! FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let catalog = LayoutCatalog(builtInFolder: shipped, userFolder: user)
            check(catalog.library.presets.map(\.id) == ["writing", "review", "qa", "cockpit"], "a new catalog starts with the built-in presets")

            try! presetJSON { $0["id"] = "mine" }.write(to: user.appendingPathComponent("mine.json"))
            catalog.startReload()
            catalog.startReload()
            check(await eventually { catalog.library.presets.map(\.id).contains("mine") }, "two reloads asked at once end with the new file chosen")

            try! FileManager.default.removeItem(at: user.appendingPathComponent("mine.json"))
            catalog.startReload()
            check(await eventually { !catalog.library.presets.map(\.id).contains("mine") }, "a reload after the file went drops the preset")

            // The catalog going away stops what it started: the read that was running does not touch it.
            weak var gone: LayoutCatalog?
            do {
                let short = LayoutCatalog(builtInFolder: shipped, userFolder: user)
                short.startReload()
                gone = short
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            check(gone == nil, "a catalog that is let go is not kept alive by its reads")
        }

        await catalogReads()
    }

    @MainActor func testAppFontScaleRules() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // Offered steps: 80…200 in 10% steps, default 100%.
        for percent in stride(from: 80, through: 200, by: 10) {
            check(AppFontScale.validated(percent) == percent, "\(percent)% is a valid step")
        }
        check(AppFontScale.validated(70) == 100, "below range falls back to 100%")
        check(AppFontScale.validated(210) == 100, "above range falls back to 100%")
        check(AppFontScale.validated(115) == 100, "off-step value falls back to 100%")
        check(AppFontScale.validated(0) == 100, "zero falls back to 100%")
        check(AppFontScale.validated(-100) == 100, "negative falls back to 100%")
        check(AppFontScale.factor(percent: 150) == 1.5, "factor of 150% is 1.5")
        check(AppFontScale.factor(percent: 999) == 1, "factor of an invalid value is 1")

        // Stored value: missing, invalid type and invalid number all give 100%.
        let domain = "MarkViewFontScaleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        let settings = MarkViewCore.Settings(defaults)
        let scaleName = Setting.fontScalePercent.name
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.removeObject(forKey: scaleName)
        check(AppFontScale.storedFactor(read: { settings.value(Setting.fontScalePercent) }) == 1, "missing preference is 100%")
        defaults.set("large", forKey: scaleName)
        check(AppFontScale.storedFactor(read: { settings.value(Setting.fontScalePercent) }) == 1, "non-numeric preference is 100%")
        defaults.set(300, forKey: scaleName)
        check(AppFontScale.storedFactor(read: { settings.value(Setting.fontScalePercent) }) == 1, "out-of-range preference is 100%")
        defaults.set(120, forKey: scaleName)
        check(AppFontScale.storedFactor(read: { settings.value(Setting.fontScalePercent) }) == 1.2, "saved 120% is used")
        defaults.removeObject(forKey: scaleName)

        // Text styles keep the macOS hierarchy; headline stays bold.
        check(AppFontScale.pointSize(.body) == 13, "body is 13 pt")
        check(AppFontScale.pointSize(.caption) == 10, "caption is 10 pt")
        check(AppFontScale.pointSize(.title2) == 17, "title2 is 17 pt")
        check(AppFontScale.defaultWeight(.headline) == .bold, "headline is bold")
        check(AppFontScale.defaultWeight(.caption) == .regular, "caption is regular")

        // Editor slider mirror: its own range (10…20), independent of the interface scale.
        check(EditorTextSize.validated(16) == 16, "slider size 16 is kept")
        check(EditorTextSize.validated(40) == 13, "out-of-range slider size falls back to 13")
        check(Setting.editorTextSizeMirror.name != scaleName, "the two controls use separate keys")

    }

    @MainActor func testFileBrowserRulesOnTemporaryProject() throws {
        func check(_ condition: Bool, _ label: String, line: UInt = #line) {
            XCTAssertTrue(condition, label, line: line)
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("file-browser-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let project = base.appendingPathComponent("project", isDirectory: true)
        let linked = base.appendingPathComponent("notes", isDirectory: true)

        func path(_ root: URL, _ relative: String) -> URL { root.appendingPathComponent(relative) }
        func makeFolder(_ root: URL, _ relative: String) throws {
            try fm.createDirectory(at: path(root, relative), withIntermediateDirectories: true)
        }
        func makeFile(_ root: URL, _ relative: String, modified: Date? = nil) throws {
            try fm.createDirectory(at: path(root, relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: path(root, relative))
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path(root, relative).path) }
        }

        // project/
        //   src/{main.swift, notes.md}   .hidden/secret.md   .env   build/out.o (ignored)   docs/deep/er/needle.md
        //   video.mov (no viewer)   readme.md   Zeta.txt   alpha.txt   image.png
        let old = Date(timeIntervalSince1970: 1_000_000)
        let mid = Date(timeIntervalSince1970: 2_000_000)
        let new = Date(timeIntervalSince1970: 3_000_000)
        try makeFile(project, "src/main.swift")
        try makeFile(project, "src/notes.md")
        try makeFile(project, ".hidden/secret.md")
        try makeFile(project, ".env")
        try makeFile(project, "build/out.o")
        try makeFile(project, "docs/deep/er/needle.md")
        try makeFile(project, "video.mov", modified: mid)
        try makeFile(project, "readme.md", modified: old)
        try makeFile(project, "Zeta.txt", modified: new)
        try makeFile(project, "alpha.txt", modified: new)
        try makeFile(project, "image.png", modified: mid)
        try makeFile(linked, "todo.md")
        try makeFile(linked, "deep/needle-linked.md")

        let projectRoot = FileBrowserRoot(url: project, name: "project", linkedID: nil)
        let linkedRoot = FileBrowserRoot(url: linked, name: "Notes", linkedID: linked.path)
        let roots = [projectRoot, linkedRoot]
        let ignoredPaths: Set<String> = [FileBrowser.key(path(project, "build"))]

        func source(_ filter: FileBrowserFilter = FileBrowserFilter(), sort: FileTreeSortOrder = FileTreeSortOrder(),
                    roots: [FileBrowserRoot] = roots) -> FileBrowserSource {
            FileBrowserSource(roots: roots, filter: filter, sort: sort,
                              hasViewer: { FileType.hasViewer($0) },
                              isIgnored: { url, _ in
                                  let key = FileBrowser.key(url)
                                  return ignoredPaths.contains { key == $0 || key.hasPrefix($0 + "/") }
                              })
        }
        func names(_ entries: [FileBrowserEntry]) -> [String] { entries.map(\.name) }
        func list(_ filter: FileBrowserFilter = FileBrowserFilter(), sort: FileTreeSortOrder = FileTreeSortOrder(),
                  query: Bool = true) -> [String] {
            names(FileBrowser.listing(of: project, source: source(filter, sort: sort), applyQuery: query))
        }

        // MARK: Viewer classification (DEC-004)

        for name in ["a.md", "a.swift", "a.json", "a.yaml", "a.pdf", "a.png", "a.zip", "a.csv", "a.sqlite", "a.log", "a.canvas", "Makefile", "a.html"] {
            check(FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) has a viewer")
        }
        for name in [".gitignore", ".dockerignore", ".zshrc", ".env", ".env.local", "LICENSE", "a.conf", "a.txt"] {
            check(FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) (configuration file) has a viewer")
        }
        for name in ["a.mov", "a.dylib", "a.bin", "a.unknownext", "NOEXTENSION", ".custom"] {
            check(!FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) has no viewer")
        }

        // MARK: Preferences (AC-5, DEC-008)

        // WindowUIState belongs to the main actor, as the views that read it do.
        @MainActor func windowPreferenceChecks() {
            let suite = "file-browser-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            // Each window keeps its own view and filter choices (`FileTreeView` stores them in the window's `WindowUIState`).
            func browserPreferences(_ state: WindowUIState) -> FileBrowserPreferences {
                FileBrowserPreferences(mode: FileBrowserViewMode(rawValue: state.value(Setting.fileBrowserViewMode)) ?? .list,
                                       showHidden: state.value(Setting.fileBrowserShowHidden),
                                       hideIgnored: state.value(Setting.fileBrowserHideIgnored),
                                       category: FileBrowserCategory(rawValue: state.value(Setting.fileBrowserCategory)) ?? .all)
            }
            let windowA = WindowUIState(defaults: defaults), windowB = WindowUIState(defaults: defaults)
            check(browserPreferences(windowA) == FileBrowserPreferences(), "defaults: list, hidden off, ignored shown, all")
            check(browserPreferences(windowB) == FileBrowserPreferences(), "a second window starts the same")
            check(FileBrowserPreferences().mode == .list && !FileBrowserPreferences().showHidden, "hidden items are excluded by default")
            windowA.set(FileBrowserViewMode.tree.rawValue, for: Setting.fileBrowserViewMode)
            windowA.set(true, for: Setting.fileBrowserShowHidden)
            windowA.set(FileBrowserCategory.openable.rawValue, for: Setting.fileBrowserCategory)
            check(browserPreferences(windowA).mode == .tree && browserPreferences(windowA).showHidden && browserPreferences(windowA).category == .openable,
                  "the window that changed its view shows it")
            check(browserPreferences(windowB) == FileBrowserPreferences(), "another window that already shows its files keeps its own view")
            let windowC = WindowUIState(defaults: defaults)
            check(browserPreferences(windowC).mode == .tree && browserPreferences(windowC).showHidden, "a window opened later starts from the last choice")
            defer { UserDefaults(suiteName: suite + "-empty")?.removePersistentDomain(forName: suite + "-empty") }
        let restored = WindowUIState(defaults: UserDefaults(suiteName: suite + "-empty")!)
            restored.restore(windowA.saved)
            check(browserPreferences(restored).mode == .tree && browserPreferences(restored).category == .openable,
                  "the view, hidden and category come back with the window's session")
            defaults.set("nonsense", forKey: "fileBrowser.viewMode")
            defaults.set("nonsense", forKey: "fileBrowser.category")
            let windowD = WindowUIState(defaults: defaults)
            check(browserPreferences(windowD).mode == .list && browserPreferences(windowD).category == .all,
                  "unknown stored values fall back to the defaults")
        }
        windowPreferenceChecks()
        check(!FileBrowserFilter().isActive && FileBrowserFilter(query: "a").isActive && FileBrowserFilter(hideIgnored: true).hasSettings,
              "an active filter is reported")

        // MARK: Listing and filters (AC-3, REQ-001)

        let everything = list()
        check(!everything.contains(".hidden") && !everything.contains(".env"), "hidden items are excluded by default")
        check(everything.contains("build"), "ignored items stay visible by default")
        check(everything.contains("video.mov"), "All shows files MarkView cannot open (DEC-003)")
        check(list(FileBrowserFilter(showHidden: true)).contains(".hidden") && list(FileBrowserFilter(showHidden: true)).contains(".env"),
              "the hidden toggle shows dot items")
        check(!list(FileBrowserFilter(hideIgnored: true)).contains("build"), "Hide Git-ignored removes ignored folders")
        check(list(FileBrowserFilter(hideIgnored: true)).contains("src"), "Hide Git-ignored keeps other folders")
        check(list(FileBrowserFilter(showHidden: true, hideIgnored: true)).contains(".hidden"),
              "the two toggles are independent: ignored off, hidden on keeps dot items")
        check(list(FileBrowserFilter(category: .folders)) == ["build", "docs", "src"], "Folders shows only folders: \(list(FileBrowserFilter(category: .folders)))")
        let openable = list(FileBrowserFilter(category: .openable))
        check(openable.contains("src") && openable.contains("readme.md") && openable.contains("image.png"), "Openable keeps folders and viewer files")
        check(!openable.contains("video.mov"), "Openable drops files without a viewer")
        check(list(FileBrowserFilter(query: "ALPHA")) == ["alpha.txt"], "the name query is case-insensitive")
        check(list(FileBrowserFilter(query: "a"), query: false).count == everything.count, "children of a tree folder ignore the query")
        check(list(FileBrowserFilter(query: "zz-none")).isEmpty, "a query without a match lists nothing")
        check(list(FileBrowserFilter(query: "ALPHA", category: .folders)).isEmpty, "the query applies on top of the category")

        // MARK: Sort (AC-4)

        check(list(sort: FileTreeSortOrder(field: .name, ascending: true)) ==
              ["build", "docs", "src", "alpha.txt", "image.png", "readme.md", "video.mov", "Zeta.txt"], "name ascending: folders first, case-insensitive")
        check(list(sort: FileTreeSortOrder(field: .name, ascending: false)) ==
              ["src", "docs", "build", "Zeta.txt", "video.mov", "readme.md", "image.png", "alpha.txt"], "name descending: folders still first")
        let byDateDescending = list(sort: FileTreeSortOrder(field: .dateModified, ascending: false)).filter { !["build", "docs", "src"].contains($0) }
        check(byDateDescending == ["alpha.txt", "Zeta.txt", "image.png", "video.mov", "readme.md"],
              "date descending; equal dates fall back to name ascending: \(byDateDescending)")
        let byDateAscending = list(sort: FileTreeSortOrder(field: .dateModified, ascending: true)).filter { !["build", "docs", "src"].contains($0) }
        check(byDateAscending == ["readme.md", "image.png", "video.mov", "alpha.txt", "Zeta.txt"], "date ascending: \(byDateAscending)")
        check(Array(list(sort: FileTreeSortOrder(field: .dateModified, ascending: false)).prefix(3)).allSatisfy { ["build", "docs", "src"].contains($0) },
              "folders precede files whatever the field")

        // MARK: Workspace level (AC-2)

        let places = FileBrowser.workspaceEntries(source: source(), applyQuery: true)
        check(names(places) == ["project", "Notes"], "the project folder and the linked folder are siblings: \(names(places))")
        check(places.allSatisfy { $0.isDirectory && $0.root != nil }, "places are folders that carry their root")
        check(names(FileBrowser.workspaceEntries(source: source(FileBrowserFilter(query: "note")), applyQuery: true)) == ["Notes"],
              "the query filters the places")
        check(names(FileBrowser.workspaceEntries(source: source(FileBrowserFilter(hideIgnored: true, category: .folders)), applyQuery: true)) == ["project", "Notes"],
              "category and ignore filters never remove a place")
        let dotted = FileBrowserRoot(url: path(base, ".dotproject"), name: ".dotproject", linkedID: nil)
        try fm.createDirectory(at: dotted.url, withIntermediateDirectories: true)
        check(names(FileBrowser.workspaceEntries(source: source(roots: [dotted]), applyQuery: true)) == [".dotproject"],
              "a project folder whose name starts with a dot is still shown")

        // MARK: Tree (AC-1)

        let collapsed = FileBrowser.treeRows(source: source(), expanded: [])
        check(collapsed.map(\.depth) == [0, 0] && collapsed.allSatisfy { !$0.isExpanded && $0.isExpandable }, "a collapsed tree shows the two places")
        let opened = FileBrowser.treeRows(source: source(), expanded: [projectRoot.key, FileBrowser.key(path(project, "src"))])
        check(opened.map(\.entry.name).prefix(4) == ["project", "build", "docs", "src"], "expanding the project lists its children below it")
        let srcIndex = opened.firstIndex { $0.entry.name == "src" }!
        check(opened[srcIndex].depth == 1 && opened[srcIndex].isExpanded, "the expanded folder is marked open")
        check(opened[srcIndex + 1].entry.name == "main.swift" && opened[srcIndex + 1].depth == 2, "grandchildren sit one level deeper")
        check(opened.last?.entry.name == "Notes" && opened.last?.depth == 0, "the linked folder follows as a sibling of the project")
        let folderTree = FileBrowser.treeRows(source: source(FileBrowserFilter(category: .folders)), expanded: [projectRoot.key])
        check(folderTree.filter { $0.depth == 1 }.allSatisfy { $0.entry.isDirectory }, "Folders applies to the tree")

        // MARK: Search (DEC-001)

        let found = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(Set(names(found.matches)) == ["needle.md", "needle-linked.md"], "search finds files in never-opened folders of the project and of a linked folder: \(names(found.matches))")
        let rows = FileBrowser.searchRows(found, source: source(FileBrowserFilter(query: "needle")))
        check(rows.map(\.entry.name) == ["project", "docs", "deep", "er", "needle.md", "Notes", "deep", "needle-linked.md"],
              "ancestors are kept to reach each match: \(rows.map(\.entry.name))")
        check(rows.map(\.depth) == [0, 1, 2, 3, 4, 0, 1, 2], "the rows carry their depth")
        check(rows.filter(\.isMatch).map(\.entry.name).sorted() == ["Notes", "needle-linked.md", "needle.md", "project"],
              "only the matches (and the places) are drawn as matches")
        check(rows.allSatisfy { $0.entry.isDirectory ? $0.isExpanded : true }, "every ancestor is open")
        check(FileBrowser.searchRows(FileBrowser.search(source: source(FileBrowserFilter(query: "todo"))), source: source(FileBrowserFilter(query: "todo"))).map(\.entry.name)
              == ["Notes", "todo.md"], "a place without a match is left out")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "secret"))).matches.isEmpty, "hidden folders are not searched by default")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "secret", showHidden: true))).matches) == ["secret.md"], "…and are with the hidden toggle")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "out.o"))).matches.count == 1, "ignored folders are searched when shown")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "out.o", hideIgnored: true))).matches.isEmpty, "Hide Git-ignored also hides search results")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "e", category: .folders))).matches).allSatisfy { ["deep", "er", "docs"].contains($0) || $0 == "deep" },
              "category Folders searches folders only")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "video", category: .openable))).matches).isEmpty,
              "category Openable drops files without a viewer from the results")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "video"))).matches) == ["video.mov"], "All keeps them")

        let limited = FileBrowser.search(source: source(FileBrowserFilter(query: "e")), matchLimit: 3)
        check(limited.truncated && limited.matches.count == 3, "a search stops at the match limit and says so")
        var cancelAfter = 2
        let cancelled = FileBrowser.search(source: source(FileBrowserFilter(query: "e")), isCancelled: { cancelAfter -= 1; return cancelAfter < 0 })
        check(!cancelled.truncated, "a cancelled search returns what it had")
        try fm.createSymbolicLink(at: path(project, "loop"), withDestinationURL: project)
        let withLoop = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(Set(names(withLoop.matches)) == ["needle.md", "needle-linked.md"] && !withLoop.truncated, "a symbolic link to a folder is not followed")
        try fm.removeItem(at: path(project, "loop"))
        let locked = path(project, "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let withLocked = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(withLocked.unreadableFolders == 1 && withLocked.matches.count == 2, "an unreadable folder is counted, the rest is searched")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // Breadth-first: a cap reached deep inside the project must not starve a linked folder or a shallow match.
        let capBase = base.appendingPathComponent("cap-project", isDirectory: true)
        let capLinked = base.appendingPathComponent("cap-linked", isDirectory: true)
        for index in 0..<40 { try makeFile(capBase, "node_modules/pkg\(index)/needle-\(index).js") }
        try makeFile(capBase, "needle-shallow.md")
        try makeFile(capLinked, "needle-linked-shallow.md")
        let capRoots = [FileBrowserRoot(url: capBase, name: "cap-project", linkedID: nil),
                        FileBrowserRoot(url: capLinked, name: "Cap linked", linkedID: capLinked.path)]
        let capped = FileBrowser.search(source: source(FileBrowserFilter(query: "needle"), roots: capRoots), matchLimit: 5)
        check(capped.truncated, "the capped search reports that more exist")
        check(Set(names(capped.matches)).isSuperset(of: ["needle-shallow.md", "needle-linked-shallow.md"]),
              "a capped search still returns the shallow matches of every place: \(names(capped.matches))")

        // A linked folder that vanished is still a folder row, so it can be unlinked.
        let gone = FileBrowserRoot(url: base.appendingPathComponent("gone-\(UUID().uuidString)"), name: "Gone", linkedID: "gone")
        let goneEntries = FileBrowser.workspaceEntries(source: source(roots: roots + [gone]), applyQuery: false)
        check(goneEntries.first { $0.name == "Gone" }?.isDirectory == true, "a vanished linked folder stays a folder row")
        check(FileBrowser.listing(of: gone.url, source: source(roots: [gone]), applyQuery: false).isEmpty, "…and lists nothing")

        // MARK: Navigation (AC-2)

        let inside = path(project, "docs/deep")
        check(FileBrowser.parent(of: .workspace, roots: roots) == nil, "the Workspace level has no parent")
        check(FileBrowser.parent(of: .folder(project), roots: roots) == .workspace, ".. from the project root goes to the Workspace level")
        check(FileBrowser.parent(of: .folder(linked), roots: roots) == .workspace, ".. from a linked folder's root goes to the Workspace level")
        check(FileBrowser.parent(of: .folder(inside), roots: roots) == .folder(path(project, "docs")), ".. inside a place goes to the parent folder")
        check(FileBrowser.crumbs(for: .workspace, roots: roots).map(\.title) == ["Workspace"], "the Workspace breadcrumb is alone at the top")
        check(FileBrowser.crumbs(for: .folder(inside), roots: roots).map(\.title) == ["Workspace", "project", "docs", "deep"], "breadcrumbs run from Workspace to the folder")
        check(FileBrowser.crumbs(for: .folder(inside), roots: roots).last?.location == .folder(inside), "the last crumb is the folder itself")
        check(FileBrowser.crumbs(for: .folder(path(linked, "deep")), roots: roots).map(\.title) == ["Workspace", "Notes", "deep"], "a linked folder shows its own name")
        check(FileBrowser.root(containing: path(linked, "deep"), in: roots)?.name == "Notes", "the root of an item is found")
        check(FileBrowser.root(containing: base, in: roots) == nil, "an item outside every place has no root")
        let nested = FileBrowserRoot(url: path(project, "docs"), name: "docs-link", linkedID: "x")
        check(FileBrowser.root(containing: inside, in: roots + [nested])?.name == "docs-link", "the innermost root wins")
        check(FileBrowser.ancestors(of: path(project, "docs/deep/er/needle.md"), roots: roots).map { $0.lastPathComponent } == ["project", "docs", "deep", "er"],
              "ancestors lead from the place's root to the item")
        check(FileBrowser.ancestors(of: project, roots: roots).isEmpty, "a place has no ancestors")

        // MARK: Reveal vs filters (DEC-008)

        let secret = path(project, ".hidden/secret.md")
        let everyFilter = FileBrowserFilter(query: "typed", showHidden: false, hideIgnored: true, category: .folders)
        let toSecret = FileBrowser.relaxing(everyFilter, toShow: secret, source: source(everyFilter))
        check(toSecret.showHidden && toSecret.category == .all && toSecret.query.isEmpty && toSecret.hideIgnored,
              "revealing a file in a hidden folder turns Hidden on, resets Folders to All and clears the query, nothing else")
        let toOut = FileBrowser.relaxing(everyFilter, toShow: path(project, "build/out.o"), source: source(everyFilter))
        check(!toOut.hideIgnored && !toOut.showHidden, "revealing an ignored file turns Hide Git-ignored off only")
        let plain = FileBrowserFilter(category: .openable)
        check(FileBrowser.relaxing(plain, toShow: path(project, "src/notes.md"), source: source(plain)) == FileBrowserFilter(category: .openable),
              "a visible item leaves the filter as it is")
        check(FileBrowser.relaxing(plain, toShow: path(project, "video.mov"), source: source(plain)).category == .all,
              "an item the category hides resets it to All")
        check(FileBrowser.relaxing(everyFilter, toShow: project, source: source(everyFilter)).hideIgnored,
              "revealing a place changes no setting")

    }
}


extension EditorHostTests {
    func testWindowTitleUsesDisplayName() throws {
        func check(_ name: String, _ got: String, _ want: String, line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        check("folder open", WindowTitle.text(version: "1.4", folderName: "my-project"), "my-project — MarkView 1.4")
        check("no folder", WindowTitle.text(version: "1.4", folderName: nil), "MarkView 1.4")
        check("empty folder name", WindowTitle.text(version: "1.4", folderName: ""), "MarkView 1.4")
        check("empty version, folder", WindowTitle.text(version: "", folderName: "foo"), "foo — MarkView")
        check("empty version, no folder", WindowTitle.text(version: "", folderName: nil), "MarkView")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)/my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let name = WindowTitle.folderName(of: dir)
        check("display name of a folder", name, "my-project")
        let title = WindowTitle.text(version: "1.4", folderName: name)
        check("full path never in the title", String(title.contains(dir.path) || title.contains("/")), "false")
        let volume = WindowTitle.folderName(of: URL(fileURLWithPath: "/"))
        check("root volume has a name, not '/'", String(!volume.isEmpty && volume != "/"), "true")
        check("missing folder falls back to last component", WindowTitle.folderName(of: URL(fileURLWithPath: "/no/such/place-xyz")), "place-xyz")

    }
}


/// A view that fills itself with its window's background colour, read from the environment.
private struct ThemeTestProbe: View {
    @Environment(\.palette) private var palette
    var body: some View { palette.bg.frame(width: 40, height: 40) }
}


private extension AppTheme {
    static let darcula = AppTheme("darcula"), midnight = AppTheme("midnight"), graphite = AppTheme("graphite")
    static let tokyoNight = AppTheme("tokyo-night"), carbonRed = AppTheme("carbon-red"), nord = AppTheme("nord")
    static let forest = AppTheme("forest"), paper = AppTheme("paper"), daylight = AppTheme("daylight")
}


extension EditorHostTests {
    @MainActor func testIndependentWindowThemes() {
        var testDefaultsNames: [String] = []
        defer { for name in testDefaultsNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func freshStore() -> ThemeSettingsStore {
            let name = "window-theme-tests-\(UUID().uuidString)"
            testDefaultsNames.append(name)
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return ThemeSettingsStore(defaults: defaults)
        }
        func spin(_ what: String, until done: () -> Bool) {
            let limit = Date().addingTimeInterval(5)
            while !done() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(done(), "timed out waiting for \(what)")
        }
        /// The colour at the middle of a rendered image, as 0xRRGGBB in sRGB (the image is redrawn into an sRGB bitmap first).
        func centre(_ image: NSImage?) -> UInt32? {
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let offset = ((cg.height / 2) * cg.width + cg.width / 2) * 4
            return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
        }

        _ = NSApplication.shared
        // The shipped themes only: a window of this program never reads the real themes folder of the person running it.
        let catalog = ThemeCatalog(userFolder: nil)
        check(catalog.library.ignored.isEmpty && catalog.library.themes.count == 11, "the shipped themes are all there")
        let outFolder = ProcessInfo.processInfo.environment["MARKVIEW_THEME_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        // Project transparency persists independently and is shared by windows of the same project.
        let transparencyName = "transparency-test-\(UUID().uuidString)"
        let transparencyDefaults = UserDefaults(suiteName: transparencyName)!
        let projectA = URL(fileURLWithPath: "/tmp/project-a", isDirectory: true)
        let projectB = URL(fileURLWithPath: "/tmp/project-b", isDirectory: true)
        let transparency = ProjectTransparencyStore(defaults: transparencyDefaults)
        transparency.set(0.45, for: projectA)
        check(transparency.value(for: projectA) == 0.45 && transparency.value(for: projectB) == 0, "projects have independent transparency")
        let restoredTransparency = ProjectTransparencyStore(defaults: transparencyDefaults)
        check(restoredTransparency.value(for: projectA) == 0.45, "project transparency survives relaunch")
        transparency.set(0.2, for: nil)
        check(transparency.value(for: nil) == 0, "a window without a project cannot change a project")
        transparencyDefaults.removePersistentDomain(forName: transparencyName)

        // MARK: windows are independent (criterion 3)
        let store = freshStore()
        let a = WindowTheme(store: store, catalog: catalog), b = WindowTheme(store: store, catalog: catalog)
        check(a.settings.theme == .classicDark && b.settings.theme == .classicDark, "windows start as Classic Dark with nothing saved")
        a.select(.midnight)
        check(a.settings.theme == .midnight && a.webID == "midnight" && a.isDark, "window A takes Midnight")
        check(b.settings.theme == .classicDark && b.webID == "classic-dark", "window B is not changed by A")
        b.select(.paper)
        check(b.webID == "paper" && !b.isDark && a.webID == "midnight", "B takes Paper and A keeps Midnight")
        a.setAccent(ThemeColor(0xFF4D9A))
        check(a.palette.model.accent.rgb == 0xFF4D9A && b.palette.model.accent.rgb == 0x315E9B, "an accent in A does not change B")
        check(a.webAccent == "#FF4D9A" && b.webAccent == nil, "the web payload carries the accent only where it was chosen")
        check(a.webArguments.id == "midnight" && a.webArguments.accent == "#FF4D9A" && a.webArguments.list.count == 3 &&
              b.webArguments.id == "paper" && b.webArguments.accent == nil && b.webArguments.list[1] is NSNull, "web call arguments: id, accent, theme")
        let tail = a.webArguments.payload
        let sent = (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any]
        check(sent?["id"] as? String == "midnight" && sent?["mode"] as? String == "dark" && (sent?["t"] as? [String: String])?.isEmpty == false,
              "the web call carries the whole theme as JSON")
        check((sent?["base"] as? [String: String])?["bg"] == "#151c2b", "and it is the theme's own colours")
        let attributes = a.htmlAttributes
        check(attributes.hasPrefix(##"data-preset="midnight" data-theme="dark" data-accent="#FF4D9A" data-theme-tokens=""##) &&
              b.htmlAttributes.hasPrefix(##"data-preset="paper" data-theme="light" data-theme-tokens=""##), "html attributes for the first paint")
        let escaped = attributes.components(separatedBy: #"data-theme-tokens=""#).last.map { String($0.dropLast()) } ?? ""
        check(!escaped.contains("\"") && !escaped.contains("<") &&
              escaped.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&") == tail,
              "the tokens in the page text are the same JSON, escaped for an attribute")
        let script = a.firstPaintScript
        check(script.contains("setAttribute('data-preset', \"midnight\")") && script.contains("setAttribute('data-accent', \"#FF4D9A\")") &&
              script.contains("setAttribute('data-theme-tokens', \"{") && !script.contains("\n"), "first-paint script sets the same attributes")

        // MARK: accents are remembered per appearance (DEC-002)
        a.select(.graphite)
        check(a.webAccent == nil, "Graphite has no accent of its own yet")
        a.select(.midnight)
        check(a.webAccent == "#FF4D9A", "Midnight gets its accent back")
        a.setAccent(nil)
        check(a.webAccent == nil && a.settings.accentOverride(for: .midnight) == nil, "reset removes the override")

        // MARK: a new window inherits the last change with every accent (DEC-005)
        let s2 = freshStore()
        let first = WindowTheme(store: s2, catalog: catalog)
        first.select(.paper); first.setAccent(ThemeColor(0x00AA00)); first.select(.darcula); first.setAccent(ThemeColor(0x123456))
        let second = WindowTheme(store: s2, catalog: catalog)
        check(second.settings == first.settings, "a new window starts from the last change, accents included")
        second.select(.graphite)
        check(first.settings.theme == .darcula, "the new window is independent of the first")
        let third = WindowTheme(store: s2, catalog: catalog)
        check(third.settings.theme == .graphite && third.settings.accentOverride(for: .paper)?.rgb == 0x00AA00,
              "the next window follows the newest change")

        // MARK: restoring a saved window is not a change anyone made
        let s3 = freshStore()
        let seed = WindowTheme(store: s3, catalog: catalog); seed.select(.midnight)
        let restored = WindowTheme(store: s3, catalog: catalog)
        restored.restore(WindowThemeSettings(theme: .paper, accents: [.paper: ThemeColor(0xABCDEF)]))
        check(restored.settings.theme == .paper && restored.webAccent == "#ABCDEF", "a restored window shows its saved theme and accent")
        check(WindowTheme(store: s3, catalog: catalog).settings.theme == .midnight, "restoring does not become the starting value of new windows")

        // MARK: the window's own appearance
        func makeWindow() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        }
        let w1 = makeWindow(), w2 = makeWindow()
        let t1 = WindowTheme(store: freshStore(), catalog: catalog), t2 = WindowTheme(store: freshStore(), catalog: catalog)
        t1.attach(w1); t2.attach(w2)
        t1.select(.darcula); t2.select(.paper)
        check(w1.appearance?.name == .darkAqua, "a dark preset gives its window the dark appearance")
        check(w2.appearance?.name == .aqua, "Paper gives its window the light appearance")
        t1.select(.system)
        check(w1.appearance == nil, "System leaves the window on the macOS appearance")
        t1.select(.classicLight)
        check(w1.appearance?.name == .aqua, "Classic Light is light")
        t2.detach(w2); t2.select(.midnight)
        check(w2.appearance?.name == .aqua, "a detached window is left alone")

        // MARK: two windows render with two palettes at the same time (criteria 2 and 3)
        @MainActor func render<V: View>(_ view: V) -> NSImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return renderer.nsImage
        }
        let ta = WindowTheme(store: freshStore(), catalog: catalog), tb = WindowTheme(store: freshStore(), catalog: catalog)
        ta.select(.darcula); tb.select(.paper)
        let imageA = render(ThemeTestProbe().windowThemed(ta)), imageB = render(ThemeTestProbe().windowThemed(tb))
        check(centre(imageA) == 0x2B2B2B, "a view in a Darcula window draws the Darcula background (got \(String(describing: centre(imageA))))")
        check(centre(imageB) == 0xFFFCF5, "a view in a Paper window draws the Paper background (got \(String(describing: centre(imageB))))")
        ta.select(.midnight)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x151C2B, "the view follows a theme change at once")
        check(centre(render(ThemeTestProbe().windowThemed(tb))) == 0xFFFCF5, "and the other window does not")
        ta.select(.nord); tb.select(.daylight)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x2E3440, "a view in a Nord window draws the Nord background")
        check(centre(render(ThemeTestProbe().windowThemed(tb))) == 0xF7F9FC, "a view in a Daylight window draws the Daylight background")
        ta.select(.forest)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x1E2A22, "a view in a Forest window draws the Forest background")

        // MARK: the picker draws in every theme and lists what it should
        for theme in [AppTheme.classicDark, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight] {
            let t = WindowTheme(store: freshStore(), catalog: catalog)
            t.select(theme)
            let image = render(ThemePickerView().windowThemed(t))
            check((image?.size.width ?? 0) >= 300 && (image?.size.height ?? 0) > 200, "the picker renders for \(theme)")
            if let outFolder, let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: outFolder).appendingPathComponent("picker-\(theme.id).png"))
            }
        }
        // MARK: a theme file of the person's own is a theme of the window (DEC-003)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("window-theme-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func put(_ name: String, _ text: String) { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        func themeFile(_ id: String, bg: String) -> String {
            ##"{"schema":1,"id":"\##(id)","name":"\##(id.capitalized)","summary":"mine","native":{"bg":"\##(bg)","bgSidebar":"#16222E","text":"#E6EEF5","accent":"#4FC3F7"}}"##
        }
        put("ocean.json", themeFile("ocean", bg: "#0B1620"))
        put("broken.json", "{ not json")
        let own = ThemeCatalog(userFolder: folder)
        check(own.library.definition("ocean") != nil && own.library.ignored.map(\.file) == ["broken.json"], "the person's folder is read and the bad file is reported")
        let mine = WindowTheme(store: freshStore(), catalog: own)
        mine.select(AppTheme("ocean"))
        check(mine.webID == "ocean" && mine.isDark && mine.palette.model.bg.rgb == 0x0B1620 && mine.webArguments.payload.contains(#""id":"ocean""#),
              "a user theme draws natively and is sent to the web pages by the same data")
        check(centre(render(ThemeTestProbe().windowThemed(mine))) == 0x0B1620, "a view in a user-theme window draws the file's background")
        check(own.library.choices(current: .system).contains { $0.name == "Ocean" } && render(ThemePickerView().windowThemed(mine)) != nil,
              "the picker lists it and draws with the notice of the ignored file")

        // A stored theme that is not there is shown as Classic Dark, said once, and comes back with its file.
        let ghost = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
        check(ghost.webID == "classic-dark" && ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "an unknown stored theme is shown as Classic Dark and reported")
        let again = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
        check(again.webID == "classic-dark" && own.missing == ["ghost"], "and reported once")
        put("ghost.json", themeFile("ghost", bg: "#201830"))
        put("late.json", themeFile("late", bg: "#102030"))
        var reloaded = false
        Task { @MainActor in await own.reload(); reloaded = true }
        spin("the catalog to reload") { reloaded }
        check(own.library.definition("late") != nil && own.library.definition("ghost") != nil && own.missing.isEmpty, "a file added while the app runs is found, and the missing theme is no longer missing")
        spin("the windows to follow the catalog") { ghost.webID == "ghost" }
        check(ghost.webID == "ghost" && ghost.palette.model.bg.rgb == 0x201830 && again.webID == "ghost", "windows that had stored it draw it as soon as it is there")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ghost.json"))
        reloaded = false
        Task { @MainActor in await own.reload(); reloaded = true }
        spin("the catalog to reload again") { reloaded }
        spin("the window to fall back") { ghost.webID == "classic-dark" }
        check(ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "a deleted file falls back again, and the choice is kept for when the file returns")

        let system = SystemAppearance.shared
        check(system.isDark == (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "system appearance is read")

    }
}


extension EditorHostTests {
    func testThemeModelAndStoredSettings() throws {
        var testDefaultsNames: [String] = []
        defer { for name in testDefaultsNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func ratio(_ a: ThemeColor, _ b: ThemeColor) -> String { String(format: "%.2f", ThemeColor.contrast(a, b)) }
        let builtInFolder = try XCTUnwrap(ThemeCatalog.bundledFolder)
        let library = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: nil)
        func def(_ id: String) -> ThemeDefinition { library.definition(id)! }
        func palette(_ theme: AppTheme, accent: ThemeColor? = nil) -> ThemePalette { ThemePalette.make(def(theme.id), accent: accent) }

        let presets: [AppTheme] = [.darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight]
        let lightPresets: [AppTheme] = [.paper, .daylight]
        let classics: [AppTheme] = [.classicDark, .classicLight]
        let everyBuiltIn = classics + presets

        // MARK: colour basics
        check(ThemeColor(hex: "#12ab34")?.rgb == 0x12AB34, "lower-case hex with # parses")
        check(ThemeColor(hex: "12AB34")?.hex == "#12AB34", "hex without # parses and prints upper case")
        for bad in ["", "#12", "zzzzzz", "#1234567", "12 456", "#12AB3G"] { check(ThemeColor(hex: bad) == nil, "'\(bad)' is not a colour") }
        check(abs(ThemeColor.contrast(ThemeColor(0x000000), ThemeColor(0xFFFFFF)) - 21) < 0.01, "black on white is 21:1")
        check(abs(ThemeColor.contrast(ThemeColor(0x777777), ThemeColor(0x777777)) - 1) < 0.001, "a colour on itself is 1:1")
        check(ThemeColor(0xFFFFFF).readableText.rgb == 0x000000 && ThemeColor(0x000000).readableText.rgb == 0xFFFFFF, "readable text flips")
        check(ThemeColor(0x000000).mixed(with: ThemeColor(0xFFFFFF), fraction: 0.5).rgb == 0x808080, "mixing halfway")
        check(ThemeColor(0xAB12CD).cssHex == "#ab12cd", "the pages get lower-case #rrggbb")

        // MARK: the catalog of built-in themes is the files in Resources/Themes
        check(library.ignored.isEmpty, "no built-in theme file is ignored: \(library.ignored.map { "\($0.file): \($0.reason)" })")
        check(library.themes.map(\.id) == everyBuiltIn.map(\.id), "the built-in themes come in picker order: \(library.themes.map(\.id))")
        check(library.themes.allSatisfy { $0.source == .builtIn }, "every shipped theme is built in")
        check(Set(library.themes.map(\.name)).count == library.themes.count && library.themes.allSatisfy { !$0.summary.isEmpty }, "every theme has its own name and a summary")
        for t in lightPresets { check(!def(t.id).isDark, "\(t.id) is light even when macOS is dark") }
        for t in presets.filter({ !lightPresets.contains($0) }) + [.classicDark] { check(def(t.id).isDark, "\(t.id) is dark even when macOS is light") }
        check(!def("classic-light").isDark, "Classic Light is light")
        check(library.resolve(.system, systemIsDark: true).definition.id == "classic-dark" &&
              library.resolve(.system, systemIsDark: false).definition.id == "classic-light", "System draws Classic Dark or Classic Light")
        check(library.resolve(.system, systemIsDark: true).missing == nil, "System is never reported as missing")
        let gone = library.resolve(AppTheme("sunset"), systemIsDark: false)
        check(gone.definition.id == "classic-dark" && gone.missing == "sunset", "an id nobody has is shown as Classic Dark and named")
        check(library.resolve(.midnight, systemIsDark: false).definition.id == "midnight" && library.resolve(.midnight, systemIsDark: false).missing == nil,
              "a known theme resolves to itself")

        let rowsMidnight = library.choices(current: .midnight)
        check(rowsMidnight.map(\.theme) == [.system] + presets, "picker lists System and every preset: \(rowsMidnight.map(\.id))")
        let rowsClassic = library.choices(current: .classicDark)
        check(rowsClassic.first?.theme == .classicDark && rowsClassic.count == presets.count + 2, "Classic is listed while active")
        check(library.choices(current: .system).first?.theme == .system, "Classic is not listed while it is not active")
        check(rowsMidnight.first?.name == "System" && rowsMidnight.contains { $0.name == "Tokyo Night" }, "rows carry the names from the files")
        check(library.name(of: .tokyoNight) == "Tokyo Night" && library.name(of: .system) == "System" && library.name(of: AppTheme("x-y")) == "x-y",
              "the name of a theme, of System and of an unknown id")

        // MARK: every theme file gives a native palette and complete web tokens
        let tokenKeys: [String: Set<String>] = Dictionary(uniqueKeysWithValues: ThemeSchema.groups.map { ($0.key, Set($0.value)) })
        func checkPayload(_ theme: ThemeDefinition) {
            let id = theme.id
            let web = try! JSONSerialization.jsonObject(with: Data(theme.webPayload.utf8)) as! [String: Any]
            check(web["id"] as? String == id, "\(id): the payload names the theme")
            check(web["mode"] as? String == (theme.isDark ? "dark" : "light"), "\(id): the payload says dark or light")
            for (group, keys) in tokenKeys {
                let tokens = web[group] as? [String: String] ?? [:]
                // The terminal's background, foreground, cursor and selection follow the accent and are worked out by the page, unless a theme states them.
                let required = group == "term" ? keys.subtracting(["background", "foreground", "cursor", "selectionBackground"]) : keys
                check(Set(tokens.keys).isSubset(of: keys) && required.isSubset(of: Set(tokens.keys)),
                      "\(id): web.\(group) has its tokens (missing \(required.subtracting(tokens.keys).sorted()))")
                for (key, value) in tokens where ThemeColor(hex: value) == nil || value != value.lowercased() || value.count != 7 {
                    check(false, "\(id): web.\(group).\(key) is #rrggbb (\(value))")
                }
            }
            let base = web["base"] as? [String: String] ?? [:]
            let p = ThemePalette.make(theme)
            check(base["bg"] == p.bg.cssHex && base["panel"] == p.bgSidebar.cssHex && base["text"] == p.text.cssHex && base["accent"] == p.defaultAccent.cssHex,
                  "\(id): the web base colours are the native ones (one definition)")
            check(!theme.webPayload.contains("\n") && !theme.webPayload.contains("<"), "\(id): the payload is one line of JSON without markup")
        }
        for theme in library.themes { checkPayload(theme) }
        check(!def("classic-dark").web.vars.isEmpty && !def("classic-dark").web.ownAccentVars.isEmpty && def("classic-dark").web.mermaidBuiltIn &&
              def("classic-dark").web.chart?.count == 8, "Classic keeps its exact page values")
        check(presets.allSatisfy { def($0.id).web.vars.isEmpty && !def($0.id).web.mermaidBuiltIn }, "the presets state tokens only")

        // MARK: legibility of every preset (criterion 6) and Classic's own text
        for theme in everyBuiltIn {
            let p = palette(theme)
            let strict = !classics.contains(theme)
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
                check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(theme.id) text on \(name) is \(ratio(p.text, surface))")
                check(ThemeColor.contrast(p.textBright, surface) >= 4.5, "\(theme.id) bright text on \(name) is \(ratio(p.textBright, surface))")
            }
            check(ThemeColor.contrast(p.text, p.selection) >= 4.5, "\(theme.id) text on selection is \(ratio(p.text, p.selection))")
            check(ThemeColor.contrast(p.onAccent, p.badge) >= 4.5, "\(theme.id) text on badge is \(ratio(p.onAccent, p.badge))")
            check(p.isDark == def(theme.id).isDark, "\(theme.id) palette dark flag matches")
            guard strict else { continue }
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar)] {
                check(ThemeColor.contrast(p.textDim, surface) >= 4.5, "\(theme.id) dim text on \(name) is \(ratio(p.textDim, surface))")
                for (cn, c) in [("accent", p.blue), ("green", p.green), ("orange", p.orange), ("yellow", p.yellow),
                                ("purple", p.purple), ("red", p.red), ("cyan", p.cyan)] {
                    check(ThemeColor.contrast(c, surface) >= 4.5, "\(theme.id) \(cn) on \(name) is \(ratio(c, surface))")
                }
            }
            check(ThemeColor.contrast(p.border, p.bg) >= 1.3, "\(theme.id) border is visible on the background (\(ratio(p.border, p.bg)))")
            check(ThemeColor.contrast(p.bgActive, p.bg) >= 1.15, "\(theme.id) the active row is distinguishable (\(ratio(p.bgActive, p.bg)))")
        }

        // Base colours approved in DEC-003.
        let approved: [(AppTheme, UInt32, UInt32, UInt32, UInt32)] = [
            (.darcula, 0x2B2B2B, 0x323232, 0xE0E0E0, 0xE6A15C), (.midnight, 0x151C2B, 0x1D2738, 0xE5EBF5, 0x79B8FF),
            (.graphite, 0x202124, 0x2A2C30, 0xE8EAED, 0xB39DDB), (.paper, 0xFFFCF5, 0xF2EDE3, 0x292724, 0x315E9B),
            (.nord, 0x2E3440, 0x353C4A, 0xE5E9F0, 0x88C0D0), (.forest, 0x1E2A22, 0x26352B, 0xDDD8C0, 0xA7C080),
            (.daylight, 0xF7F9FC, 0xE8EDF4, 0x1F2933, 0x0F766E)]
        for (theme, bg, panel, text, accent) in approved {
            let n = def(theme.id).native
            check(n.bg.rgb == bg && n.bgSidebar.rgb == panel && n.text.rgb == text && n.accent.rgb == accent, "\(theme.id) keeps its approved base colours")
            let p = palette(theme)
            check(p.bg.rgb == bg && p.bgSidebar.rgb == panel && p.text.rgb == text && p.accent.rgb == accent, "\(theme.id) palette uses them")
        }

        // MARK: Classic is the look before themes (DEC-004)
        let cd = palette(.classicDark), cl = palette(.classicLight)
        check(cd.bg.rgb == 0x1E1E1E && cd.bgSidebar.rgb == 0x252526 && cd.blue.rgb == 0x569CD6 && cd.badge.rgb == 0x007ACC && cd.selection.rgb == 0x264F78,
              "Classic Dark keeps the VS Code Dark+ colours")
        check(cl.bg.rgb == 0xFFFFFF && cl.bgSidebar.rgb == 0xF3F3F3 && cl.cyan.rgb == 0x0070C1 && cl.selection.rgb == 0xADD6FF,
              "Classic Light keeps the Light+ colours")

        // MARK: accent
        let plain = palette(.midnight)
        let pink = ThemeColor(0xFF4D9A)
        let custom = palette(.midnight, accent: pink)
        check(custom.accent == pink && custom.badge == pink, "the accent override is the accent and the badge fill")
        check(custom.selection != plain.selection, "the selection follows the accent")
        check(custom.defaultAccent.rgb == 0x79B8FF, "the default accent is still known")
        let dark = palette(.midnight, accent: ThemeColor(0x101828))
        check(ThemeColor.contrast(dark.blue, dark.bg) >= 4.5 && ThemeColor.contrast(dark.blue, dark.bgSidebar) >= 4.5,
              "an unreadable accent is lightened where it is text (\(ratio(dark.blue, dark.bg)))")
        let pale = palette(.paper, accent: ThemeColor(0xFFF2B0))
        check(ThemeColor.contrast(pale.blue, pale.bg) >= 4.5, "a pale accent on Paper is darkened where it is text (\(ratio(pale.blue, pale.bg)))")
        check(ThemeColor.contrast(pale.onAccent, pale.badge) >= 4.5, "text on a pale badge is readable")
        let paleDay = palette(.daylight, accent: ThemeColor(0xFFF2B0))
        check(ThemeColor.contrast(paleDay.blue, paleDay.bg) >= 4.5 && ThemeColor.contrast(paleDay.blue, paleDay.bgSidebar) >= 4.5,
              "a pale accent on Daylight is darkened where it is text (\(ratio(paleDay.blue, paleDay.bg)))")
        let darkForest = palette(.forest, accent: ThemeColor(0x14301C))
        check(ThemeColor.contrast(darkForest.blue, darkForest.bg) >= 4.5, "a dark accent on Forest is lightened where it is text (\(ratio(darkForest.blue, darkForest.bg)))")
        check(palette(.classicDark, accent: pink).blue != cd.blue, "Classic takes an accent too")

        // MARK: per-appearance accent memory (DEC-002)
        var s = WindowThemeSettings(theme: .midnight)
        s.setAccent(ThemeColor(0xFF0000))
        s.select(.paper)
        check(s.activeOverride == nil, "Paper starts with its default accent")
        s.setAccent(ThemeColor(0x00AA00))
        s.select(.midnight)
        check(s.activeOverride?.rgb == 0xFF0000, "returning to Midnight restores its accent")
        s.setAccent(nil)
        check(s.activeOverride == nil && s.accentOverride(for: .paper)?.rgb == 0x00AA00, "resetting clears only the active appearance")
        check(palette(.midnight, accent: s.activeOverride).accent.rgb == 0x79B8FF, "after a reset the default accent is in use")
        s.select(.system)
        check(ThemePalette.make(library.resolve(s.theme, systemIsDark: true).definition, accent: s.activeOverride).accent.rgb == 0x569CD6,
              "System uses the Classic accent")

        // MARK: stored names (every value an earlier version wrote still decodes)
        let oldNames: [(stored: String, id: String)] = [
            ("classicDark", "classic-dark"), ("classicLight", "classic-light"), ("darcula", "darcula"), ("midnight", "midnight"),
            ("graphite", "graphite"), ("tokyoNight", "tokyo-night"), ("carbonRed", "carbon-red"), ("nord", "nord"), ("forest", "forest"),
            ("paper", "paper"), ("daylight", "daylight"), ("system", "system")]
        func decode(_ json: String) -> WindowThemeSettings? { try? JSONDecoder().decode(WindowThemeSettings.self, from: Data(json.utf8)) }
        for (stored, id) in oldNames {
            let decoded = decode(##"{"theme":"\##(stored)","accents":{"\##(stored)":"#123456"}}"##)
            check(decoded?.theme.id == id, "the stored name \(stored) is the theme \(id)")
            check(decoded?.accentOverride(for: AppTheme(id)) == ThemeColor(0x123456), "the accent stored under \(stored) is kept")
            if id != "system" { check(library.definition(id) != nil, "\(stored) still names a shipped theme") }
            let encoded = try! JSONEncoder().encode(WindowThemeSettings(theme: AppTheme(id)))
            check(String(decoding: encoded, as: UTF8.self).contains("\"\(id)\""), "\(id) is stored under its id")
        }
        check(AppTheme(stored: "tokyoNight") == .tokyoNight && AppTheme(stored: "tokyo-night") == .tokyoNight, "both spellings give the same theme")
        for bad in ["", "Has Space", "a_b", "-lead", "trail-", "a--b", String(repeating: "a", count: 41), "ABC"] {
            check(AppTheme(stored: bad) == nil, "'\(bad)' cannot be a theme id")
        }
        check(decode(##"{"theme":"ocean","accents":{"ocean":"#0A0B0C"}}"##)?.theme.id == "ocean", "a well-formed id with no theme behind it is kept")

        // MARK: coding
        var full = WindowThemeSettings(theme: .graphite)
        full.setAccent(ThemeColor(0x123456))
        full.select(.paper)
        full.setAccent(ThemeColor(0xABCDEF))
        let data = try! JSONEncoder().encode(full)
        check((try? JSONDecoder().decode(WindowThemeSettings.self, from: data)) == full, "settings survive a round trip")
        for theme in [AppTheme.tokyoNight, .carbonRed, .nord, .forest, .daylight] {
            let settings = WindowThemeSettings(theme: theme, accents: [theme: pink])
            let encoded = try! JSONEncoder().encode(settings)
            check((try? JSONDecoder().decode(WindowThemeSettings.self, from: encoded)) == settings, "\(theme.id) and its custom accent survive a relaunch")
        }
        check(decode(#"{"theme":"nope!","accents":{}}"#)?.theme == .classicDark, "a name that cannot be an id becomes Classic Dark")
        check(decode(##"{"theme":"paper","accents":{"paper":"#12","midnight":"#0A0B0C","x y":"#ffffff"}}"##)?.accents == [.midnight: ThemeColor(0x0A0B0C)],
              "unreadable accents and names that cannot be ids are dropped")
        check(decode(#"{"theme":"paper"}"#)?.theme == .paper, "a missing accents map is empty")
        check(decode(#"{"theme":3,"accents":[1]}"#)?.theme == .classicDark, "wrong types give the fallback")

        // MARK: starting settings, upgrade and inheritance (criteria 4 and 5, DEC-004, DEC-005)
        func store() -> (ThemeSettingsStore, UserDefaults) {
            let name = "theme-model-tests-\(UUID().uuidString)"
            testDefaultsNames.append(name)
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return (ThemeSettingsStore(defaults: d), d)
        }
        var (st, d) = store()
        check(st.startingSettings().theme == .classicDark, "nothing saved (today's default) starts as Classic Dark")
        d.set("light", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicLight, "a saved light setting stays light (Classic Light)")
        d.set("dark", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a saved dark setting stays dark (Classic Dark)")
        d.set("system", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a saved system setting keeps today's dark look")
        d.set("purple", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "an unreadable legacy value falls back to Classic Dark")
        d.set(42, forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a legacy value of the wrong type falls back to Classic Dark")

        d.set("light", forKey: Setting.legacyTheme.name)
        st.remember(full)
        check(st.startingSettings() == full, "the last change wins over the legacy setting and keeps every accent (DEC-005)")
        var newWindow = st.startingSettings()
        newWindow.select(.darcula)
        newWindow.setAccent(ThemeColor(0x010203))
        check(st.startingSettings() == full, "changing a window does not change the stored value until it is remembered")
        st.remember(newWindow)
        check(st.startingSettings().accentOverride(for: .paper)?.rgb == 0xABCDEF && st.startingSettings().theme == .darcula,
              "the next window gets the newest theme with the whole collection")

        d.set(Data("not json".utf8), forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "an unreadable last-changed record falls back to the legacy setting")
        d.set(Data(##"{"theme":"bo gus","accents":{"paper":"#112233"}}"##.utf8), forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "a record that names no possible theme is not used")
        d.set(42, forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "a record of the wrong type is not used")

        // MARK: user themes, from a folder of the person's own files
        let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-model-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }
        let userFolder = workFolder.appendingPathComponent("themes", isDirectory: true)
        try! FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String, in folder: URL? = nil) {
            try! Data(text.utf8).write(to: (folder ?? userFolder).appendingPathComponent(name))
        }
        func themeJSON(_ id: String, native: String, extra: String = "") -> String {
            #"{"schema":1,"id":"\#(id)","name":"\#(id.capitalized)","summary":"A test theme","native":{\#(native)}\#(extra)}"#
        }
        let oceanNative = ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##
        let sandNative = ##""bg":"#FBF6EC","bgSidebar":"#F0E8D8","text":"#2B2A28","accent":"#9A4F1B""##
        write("ocean.json", themeJSON("ocean", native: oceanNative))
        write("sand.json", themeJSON("sand", native: sandNative, extra: #","order":15,"picker":"listed""#))
        write("pinned.json", themeJSON("pinned", native: oceanNative, extra: ##","web":{"syn":{"keyword":"#FF00FF"},"t":{"codeBg":"#0A121A"}}"##))
        let withUser = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder)
        check(withUser.ignored.isEmpty, "valid user themes are not reported: \(withUser.ignored)")
        check(withUser.themes.count == everyBuiltIn.count + 3, "three user themes join the built-in ones")
        check(withUser.themes.map(\.order) == withUser.themes.map(\.order).sorted(), "the list is in order")
        check(withUser.themes.map(\.id).firstIndex(of: "sand") == 2, "order puts a user theme among the built-in ones (\(withUser.themes.map(\.id)))")
        check(withUser.themes.first { $0.id == "ocean" }?.source == .user(file: "ocean.json"), "a user theme knows its file")
        check(withUser.choices(current: .midnight).contains { $0.theme == AppTheme("ocean") && $0.name == "Ocean" }, "a user theme is a row of the picker")
        check(withUser.resolve(AppTheme("ocean"), systemIsDark: false).definition.id == "ocean", "a user theme resolves")
        for id in ["ocean", "sand", "pinned"] {
            let t = withUser.definition(id)!
            checkPayload(t)
            let p = ThemePalette.make(t)
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
                check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(id): derived surface \(name) keeps the text readable (\(ratio(p.text, surface)))")
            }
            for (cn, c) in [("green", p.green), ("orange", p.orange), ("yellow", p.yellow), ("purple", p.purple), ("red", p.red), ("cyan", p.cyan), ("dim", p.textDim)] {
                check(ThemeColor.contrast(c, p.bg) >= 4.5 && ThemeColor.contrast(c, p.bgSidebar) >= 4.5, "\(id): derived \(cn) is readable on both backgrounds")
            }
            check(t.web.vars.isEmpty && t.web.ownAccentVars.isEmpty && t.web.chart == nil && !t.web.mermaidBuiltIn, "\(id): no exact page values")
            let codeBackgrounds = [t.web.t["codeBg"]!, t.web.t["preBg"]!]
            for group in [t.web.syn, t.web.structure] {
                for (key, value) in group where key != "count" {
                    for background in codeBackgrounds {
                        check(ThemeColor.contrast(value, background) >= 4.5, "\(id): token \(key) reads on the code background (\(ratio(value, background)))")
                    }
                }
            }
            for key in ["textSecondary", "textTertiary", "secondary", "danger", "success", "warning", "h2", "h3"] {
                check(ThemeColor.contrast(t.web.t[key]!, p.bg) >= 4.5, "\(id): t.\(key) reads on the page background (\(ratio(t.web.t[key]!, p.bg)))")
            }
        }
        check(withUser.definition("ocean")!.isDark && !withUser.definition("sand")!.isDark, "dark or light follows the background")
        let pinned = withUser.definition("pinned")!
        check(pinned.web.syn["keyword"]?.rgb == 0xFF00FF && pinned.web.t["codeBg"]?.rgb == 0x0A121A, "a token a file gives wins over derivation")
        check(pinned.web.syn["string"]?.rgb != 0xFF00FF && pinned.web.t["preBg"] == withUser.definition("ocean")!.web.t["preBg"],
              "the tokens it does not give are derived as for any other theme")
        check(withUser.definition("ocean")!.webPayload == ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder).definition("ocean")!.webPayload,
              "the same file gives the same payload")

        // MARK: files that cannot be used are reported with their reason, never skipped silently
        let problemFolder = workFolder.appendingPathComponent("problems", isDirectory: true)
        try! FileManager.default.createDirectory(at: problemFolder, withIntermediateDirectories: true)
        let good = oceanNative
        let problems: [(file: String, text: String, reason: String)] = [
            ("broken.json", "{ not json", "not a JSON object"),
            ("array.json", "[1, 2]", "not a JSON object"),
            ("noschema.json", #"{"id":"noschema","name":"X","native":{}}"#, "no schema version"),
            ("future.json", #"{"schema":2,"id":"future","name":"X","native":{}}"#, "newer"),
            ("zero.json", #"{"schema":0,"id":"zero","name":"X","native":{}}"#, "not a known version"),
            ("badid.json", themeJSON("Bad_Id", native: good), "lower-case letters"),
            ("mismatch.json", themeJSON("other", native: good), "named \"mismatch.json\""),
            ("noname.json", ##"{"schema":1,"id":"noname","native":{"bg":"#000000"}}"##, "\"name\""),
            ("nonative.json", #"{"schema":1,"id":"nonative","name":"X"}"#, "\"native\" is missing"),
            ("missingkey.json", themeJSON("missingkey", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5""##), "native.accent"),
            ("badcolour.json", themeJSON("badcolour", native: ##""bg":"red","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
            ("shortcolour.json", themeJSON("shortcolour", native: ##""bg":"#000","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
            ("unknownnative.json", themeJSON("unknownnative", native: good + ##","glow":"#FFFFFF""##), "\"glow\""),
            ("unknowntop.json", themeJSON("unknowntop", native: good, extra: #","css":"body{display:none}""#), "unknown key \"css\""),
            ("lowtext.json", themeJSON("lowtext", native: ##""bg":"#202020","bgSidebar":"#242424","text":"#2A2A2A","accent":"#4FC3F7""##), "contrast"),
            ("lowaccent.json", themeJSON("lowaccent", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#0C1722""##), "\"accent\""),
            ("cssvalue.json", themeJSON("cssvalue", native: good, extra: #","web":{"t":{"codeBg":"red; background:url(https://x.test/a)"}}"#), "#RRGGBB"),
            ("unknowntoken.json", themeJSON("unknowntoken", native: good, extra: ##","web":{"syn":{"glow":"#FFFFFF"}}"##), "\"glow\""),
            ("varsindata.json", themeJSON("varsindata", native: good, extra: ##","web":{"vars":{"--bg-primary":"#000000"}}"##), "only allowed in the themes that ship"),
            ("chartshort.json", themeJSON("chartshort", native: good, extra: ##","web":{"chart":["#000000"]}"##), "8 colours"),
            ("picker.json", themeJSON("picker", native: good, extra: #","picker":"hidden""#), "\"picker\""),
            ("order.json", themeJSON("order", native: good, extra: #","order":-1"#), "\"order\""),
            ("classic-dark.json", themeJSON("classic-dark", native: good), "built-in theme"),
            ("huge.json", themeJSON("huge", native: good, extra: #","summary":"\#(String(repeating: "x", count: 70_000))""#), "larger than"),
        ]
        for item in problems { write(item.file, item.text, in: problemFolder) }
        write("notes.txt", "this is not a theme file", in: problemFolder)
        write("fine.json", themeJSON("fine", native: good), in: problemFolder)
        write("unreadable.json", themeJSON("unreadable", native: good), in: problemFolder)
        chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o000)
        let before = Dictionary(uniqueKeysWithValues: problems.map { ($0.file, try! Data(contentsOf: problemFolder.appendingPathComponent($0.file))) })
        let checked = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder)
        check(checked.themes.map(\.id).contains("fine"), "a good file next to bad ones is used")
        check(checked.themes.count == everyBuiltIn.count + 1, "no bad file becomes a theme (\(checked.themes.count - everyBuiltIn.count) user themes)")
        for item in problems {
            let found = checked.ignored.first { $0.file == item.file }
            check(found != nil, "\(item.file) is reported, not skipped")
            check(found?.reason.contains(item.reason) == true, "\(item.file): the reason names the problem (wanted \"\(item.reason)\", got \"\(found?.reason ?? "-")\")")
        }
        check(checked.ignored.first { $0.file == "unreadable.json" }?.reason.contains("cannot be read") == true, "an unreadable file is reported")
        check(!checked.ignored.contains { $0.file == "notes.txt" || $0.file == "fine.json" }, "a file that is not .json is not a theme file, and a good one is not reported")
        check(checked.ignored.count == problems.count + 1, "exactly the bad files are reported (\(checked.ignored.map(\.file)))")
        for item in problems { check((try? Data(contentsOf: problemFolder.appendingPathComponent(item.file))) == before[item.file], "\(item.file) is left exactly as it was") }
        chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o644)

        // MARK: limits and odd folders
        let crowdedFolder = workFolder.appendingPathComponent("crowded", isDirectory: true)
        try! FileManager.default.createDirectory(at: crowdedFolder, withIntermediateDirectories: true)
        for number in 0..<(ThemeLibrary.userFileLimit + 2) {
            write(String(format: "t%03d.json", number), themeJSON(String(format: "t%03d", number), native: good), in: crowdedFolder)
        }
        let crowded = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: crowdedFolder)
        check(crowded.themes.count == everyBuiltIn.count + ThemeLibrary.userFileLimit, "no more than \(ThemeLibrary.userFileLimit) user files are read")
        check(crowded.ignored.count == 2 && crowded.ignored.allSatisfy { $0.reason.contains("more than \(ThemeLibrary.userFileLimit)") }, "the files beyond the limit are reported")
        check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: workFolder.appendingPathComponent("absent")).ignored.isEmpty, "a missing themes folder is not a problem")
        check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder.appendingPathComponent("fine.json")).ignored.count == 1,
              "a themes 'folder' that is a file is reported")
        let noBuiltIn = ThemeLibrary.load(builtInFolder: nil, userFolder: nil)
        check(noBuiltIn.themes.isEmpty && noBuiltIn.ignored.count == 1, "an app without its built-in folder says so")

        // MARK: adding a built-in theme is adding one file
        let extendedFolder = workFolder.appendingPathComponent("builtin", isDirectory: true)
        try! FileManager.default.copyItem(at: builtInFolder, to: extendedFolder)
        write("aurora.json", themeJSON("aurora", native: ##""bg":"#10201C","bgSidebar":"#162A25","text":"#E3F2EC","accent":"#5CE0B8""##, extra: ##","order":105"##), in: extendedFolder)
        let extended = ThemeLibrary.load(builtInFolder: extendedFolder, userFolder: nil)
        check(extended.themes.count == library.themes.count + 1 && extended.ignored.isEmpty, "one more file is one more theme")
        check(extended.themes.last?.id == "aurora", "it is listed in its place with nothing else edited")
        check(extended.choices(current: .midnight).map(\.theme.id).last == "aurora", "and it is a row of the picker")
        let aurora = ThemePalette.make(extended.definition("aurora")!)
        check(aurora.isDark && ThemeColor.contrast(aurora.text, aurora.bg) >= 4.5, "and it draws")

    }
}

extension EditorHostTests {
    @MainActor func testToolRegistryAndPanelDefaults() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let registry = ToolRegistry.shared
        let expectedToolIDs: [ToolID] = [.git, .deployments, .workflow, .qa, .uiStudio, .cockpit, .discussions, .changeReview]
        check(registry.tools.map(\.id) == expectedToolIDs, "AR-31: ToolRegistry registers the 8 live singleton workspace tools, once each")

        check(registry.toolbarTools(.primary).map(\.id) == [.git, .deployments, .workflow, .qa, .uiStudio, .cockpit],
              "AR-31: the primary toolbar cluster is Git, Deployments, Workflow, QA, UI Studio, Cockpit, in that order")
        check(registry.toolbarTools(.afterBrowser).map(\.id) == [.discussions], "AR-31: Discussions is the one button after the Browser menu")
        check(registry.tools.filter { $0.toolbar == nil }.map(\.id) == [.changeReview], "AR-31: Change Review has no toolbar button")

        check(registry.menuTools(.afterAgents).map(\.id) == [.deployments, .discussions],
              "AR-31: the View menu shows Build & Deployment, then Discussions, after Agents")
        check(registry.menuTools(.afterWebPreview).map(\.id) == [.uiStudio, .qa, .cockpit],
              "AR-31: the View menu shows UI Studio, End-to-End QA and Copilot Cockpit after Preview Web App")
        check(registry.menuTools(.afterWebPreview).allSatisfy { $0.menu?.requiresFolder == true }
              && registry.menuTools(.afterAgents).allSatisfy { $0.menu?.requiresFolder == false },
              "AR-31: the menu items that need a folder are the ones the menu disabled without one")

        // The shortcuts the app has always had, and no two tools on the same keys.
        func shortcutHint(_ id: ToolID) -> String? { registry.descriptor(for: id)?.shortcut?.hint }
        check(shortcutHint(.deployments) == "⌃⌘D" && shortcutHint(.discussions) == "⌃⌘I" && shortcutHint(.uiStudio) == "⌘7" && shortcutHint(.qa) == "⌘8",
              "AR-31: shortcuts are Build & Deployment ⌃⌘D, Discussions ⌃⌘I, UI Studio ⌘7, End-to-End QA ⌘8")
        check(registry.tools.filter { $0.shortcut == nil }.map(\.id) == [.git, .workflow, .cockpit, .changeReview],
              "AR-31: Git, Workflow, Cockpit and Change Review have no shortcut")
        let shortcuts = registry.tools.compactMap(\.shortcut)
        check(Set(shortcuts).count == shortcuts.count, "AR-31: no two tools share a shortcut")
        check(registry.descriptor(for: .deployments)?.help == "Build & Deployment (⌃⌘D)" && registry.descriptor(for: .git)?.help == "Git"
              && registry.descriptor(for: .qa)?.help == "End-to-End QA (⌘8)" && registry.descriptor(for: .cockpit)?.help == "Copilot Cockpit",
              "AR-31: the toolbar tooltip is the title plus the shortcut")

        // One title and one icon per tool (the toolbar, the tab and the tile used to disagree for Workflow, QA, Discussions and UI Studio).
        check(registry.tools.map(\.title) == ["Git", "Build & Deployment", "Workflow", "End-to-End QA", "UI Studio", "Copilot Cockpit", "Discussions", "File changes"],
              "AR-31: the titles the tabs show are unchanged")
        check(registry.descriptor(for: .workflow)?.icon == "point.3.connected.trianglepath.dotted" && registry.descriptor(for: .qa)?.icon == "checkmark.shield"
              && registry.descriptor(for: .discussions)?.icon == "bubble.left.and.text.bubble.right" && registry.descriptor(for: .uiStudio)?.icon == "macwindow.and.cursorarrow",
              "AR-31: Workflow, QA, Discussions and UI Studio each have one icon")
        check(Set(registry.tools.map(\.icon)).count == registry.tools.count, "AR-31: no two tools share an icon")

        // Saved tabs of older sessions, and the project's placeholder files, depend on the sentinel paths and the saved keys.
        let sampleRoot = URL(fileURLWithPath: "/tmp/markview-tool-registry-test")
        let oldSentinels: [(ToolID, String)] = [
            (.git, ".dde/.markview-git"), (.deployments, ".dde/.markview-deployments"), (.workflow, ".dde/.markview-workflow"),
            (.qa, ".dde/.markview-qa"), (.uiStudio, ".dde/.markview-ui-studio-"), (.cockpit, ".dde/.markview-cockpit"),
            (.discussions, ".dde/.markview-discussions"), (.changeReview, ".dde/.markview-file-changes")
        ]
        check(oldSentinels.allSatisfy { registry.descriptor(for: $0.0)?.sentinelURL(in: sampleRoot).path == "/tmp/markview-tool-registry-test/" + $0.1 },
              "AR-31/FU-02: every sentinel URL is the one older sessions used")
        check(registry.descriptor(for: .uiStudio)?.sentinelURL(in: sampleRoot, suffix: "abc").path == "/tmp/markview-tool-registry-test/.dde/.markview-ui-studio-abc",
              "AR-31/FU-02: UI Studio's sentinel takes its session id")
        check(registry.tools.map(\.id.rawValue) == ["git", "deployments", "workflow", "qa", "uiStudio", "cockpit", "discussions", "changeReview"],
              "AR-31: the saved keys of the tools are unchanged")

        // One new descriptor is every surface at once: a registry with a fake tool generates its button, menu item, tab icon and title, and restore.
        let fake = ToolDescriptor(id: ToolID(rawValue: "fakeTool"), title: "Fake Tool", icon: "star", sentinelPath: ".dde/.markview-fake",
                                  shortcut: ToolShortcut(key: "9", modifiers: [.command, .option]), toolbar: .primary,
                                  menu: ToolMenuEntry(slot: .afterAgents, order: 9, requiresFolder: true),
                                  welcome: ToolWelcomeTile(section: .explore, order: 99, hint: "A tool nobody wrote"), restorable: true)
        let extended = ToolRegistry(tools: registry.tools + [fake])
        check(extended.toolbarTools(.primary).last?.id == fake.id, "AR-31: a new descriptor appears in the toolbar")
        check(extended.menuTools(.afterAgents).last?.id == fake.id && fake.shortcut?.hint == "⌥⌘9", "AR-31: a new descriptor appears in the View menu, with its shortcut")
        let fakeTile = WelcomeCatalogue.project(isGitRepo: false, registry: extended).first { $0.section == .explore }?.actions.last
        check(fakeTile?.id == .tool(fake.id) && fakeTile?.title == "Fake Tool" && fakeTile?.symbol == "star" && fakeTile?.shortcut == "⌥⌘9",
              "AR-31: a new descriptor appears among the welcome tiles, in its section and place, with its icon and shortcut")
        check(WelcomeCatalogue.project(isGitRepo: false, registry: registry).flatMap(\.actions).allSatisfy { $0.id != .tool(fake.id) },
              "AR-31: the real registry offers no tile for the fake tool")
        check(extended.descriptor(for: fake.id)?.icon == "star" && extended.descriptor(for: fake.id)?.title == "Fake Tool",
              "AR-31: a new descriptor gives its tab an icon and a title")
        check(extended.isRestorable(fake.id) && !registry.isRestorable(fake.id), "AR-31: a new descriptor is in the restore set; the real registry does not know it")
        check(extended.descriptor(for: fake.id)?.sentinelURL(in: sampleRoot).path == "/tmp/markview-tool-registry-test/.dde/.markview-fake", "AR-31: a new descriptor gives its sentinel")
        check(extended.toolbarTools(.primary).dropLast().map(\.id) == registry.toolbarTools(.primary).map(\.id)
              && extended.menuTools(.afterAgents).dropLast().map(\.id) == registry.menuTools(.afterAgents).map(\.id),
              "AR-31: the other tools keep their places")

        // 2. AR-33 / FU-08: PanelLayout has no hidden layout presets and starts in default workspace state
        let suiteName = "com.markview.phase3.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        do {
            let layout = PanelLayout(defaults: defaults)
            check(layout.workspaceArea == .files
                      && layout.navigatorTab == .contents
                      && layout.workSection == .features
                      && layout.leftPanel == "files"
                      && layout.gitSection == .changes,
                  "AR-33/FU-08: PanelLayout initializes directly to clean defaults without presets")
        }
    }

    @MainActor func testToolbarMenusPlacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolbar-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { workspace.composition.close() }

        // 1. AIToolbarMenu help text describes only assistant, model, and X-Ray model (BUG-126).
        let projectHelp = AIToolbarMenu.helpText(unavailable: false, hasProject: true, xrayName: "fast-model")
        XCTAssertTrue(projectHelp.contains("Assistant and model for this project"))
        XCTAssertTrue(projectHelp.contains("X-Ray model: fast-model."))
        XCTAssertFalse(projectHelp.localizedCaseInsensitiveContains("AI tools"),
                       "AI toolbar menu help should not claim to hold AI tools: \(projectHelp)")
        let defaultHelp = AIToolbarMenu.helpText(unavailable: false, hasProject: false, xrayName: "assistant's model")
        XCTAssertTrue(defaultHelp.contains("Default assistant and model"))
        XCTAssertFalse(defaultHelp.localizedCaseInsensitiveContains("AI tools"))
        XCTAssertEqual(AIToolbarMenu.helpText(unavailable: true, hasProject: true, xrayName: "fast-model"),
                       "Assistant unavailable. Set its CLI path in Settings.")

        // 2. Host both AIToolbarMenu and ProjectToolsMenu in an offscreen window to verify view construction.
        var cycleTimeOpened = 0
        var settingsOpened = 0
        let toolbarHost = NSHostingView(rootView: HStack {
            ProjectToolsMenu(
                workspaceManager: workspace,
                fileTree: workspace.project.fileTree,
                tint: .primary,
                onShowCycleTime: { cycleTimeOpened += 1 },
                onOpenSettings: { settingsOpened += 1 }
            ) {
                Image(systemName: "ellipsis")
            }
            AIToolbarMenu(workspaceManager: workspace, compact: false)
            AIToolbarMenu(workspaceManager: workspace, compact: true)
        })
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = toolbarHost
        toolbarHost.frame = NSRect(origin: .zero, size: NSSize(width: 420, height: 60))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        toolbarHost.layoutSubtreeIfNeeded()
        themeWebSpin(0.1)

        func buildMenu() -> ProjectToolsMenuContent.Sections {
            ProjectToolsMenuContent.build(
                workspaceManager: workspace,
                fileTree: workspace.project.fileTree,
                onShowCycleTime: { cycleTimeOpened += 1 },
                onOpenSettings: { settingsOpened += 1 }
            )
        }

        func submenu(_ id: String, in sections: ProjectToolsMenuContent.Sections) throws -> ProjectToolsMenuContent.Submenu {
            try XCTUnwrap(sections.submenus.first(where: { $0.id == id }), "Missing submenu \(id)")
        }

        func action(_ id: String, in entries: [ProjectToolsMenuContent.Submenu.Entry]) throws -> ProjectToolsMenuContent.ActionItem {
            for entry in entries {
                if case .action(let item) = entry, item.id == id { return item }
            }
            XCTFail("Missing action \(id)")
            throw NSError(domain: "ToolbarMenuTest", code: 1)
        }

        func nestedSubmenu(_ id: String, in entries: [ProjectToolsMenuContent.Submenu.Entry]) throws -> ProjectToolsMenuContent.Submenu {
            for entry in entries {
                if case .submenu(let menu) = entry, menu.id == id { return menu }
            }
            XCTFail("Missing nested submenu \(id)")
            throw NSError(domain: "ToolbarMenuTest", code: 2)
        }

        // 3. No folder open: verify structure, titles, and disabled states.
        let withoutFolder = buildMenu()
        XCTAssertEqual(withoutFolder.submenus.map(\.title), ["Diagrams", "Prototype", "Analysis"])
        XCTAssertEqual(withoutFolder.utilities.map(\.title), ["Project Cycle Time…", "DDE Settings…"])
        XCTAssertEqual(withoutFolder.utilities.map(\.disabled), [true, false])

        let diagramsNoFolder = try submenu("diagrams", in: withoutFolder)
        XCTAssertEqual(diagramsNoFolder.entries.compactMap { if case .action(let item) = $0 { return item.title } else { return nil } },
                       ["System Architecture", "Data Flow", "Pipeline", "Deployment", "Sequence", "Entity-Relationship"])
        XCTAssertTrue(diagramsNoFolder.entries.allSatisfy { if case .action(let item) = $0 { return !item.disabled } else { return false } })

        let prototypeNoFolder = try submenu("prototype", in: withoutFolder)
        XCTAssertTrue(try action("prototype.new", in: prototypeNoFolder.entries).disabled)
        XCTAssertTrue(try action("prototype.uiStudio", in: prototypeNoFolder.entries).disabled)
        let openProtoNoFolder = try nestedSubmenu("prototype.open", in: prototypeNoFolder.entries)
        XCTAssertEqual(openProtoNoFolder.title, "Open Prototype (0)")
        XCTAssertTrue(openProtoNoFolder.disabled)
        if case .message(_, let text)? = openProtoNoFolder.entries.first {
            XCTAssertEqual(text, "No prototypes in this project yet")
        } else {
            XCTFail("Expected empty-prototypes placeholder text")
        }

        let analysisNoFolder = try submenu("analysis", in: withoutFolder)
        XCTAssertEqual(analysisNoFolder.entries.compactMap { if case .action(let item) = $0 { return item.title } else { return nil } },
                       ["Constructive Critic", "Deep Research…", "Codebase Audit", "Code Structure Map", "Recursive Insight"])
        XCTAssertFalse(try action("analysis.critic", in: analysisNoFolder.entries).disabled)
        XCTAssertFalse(try action("analysis.research", in: analysisNoFolder.entries).disabled)
        XCTAssertFalse(try action("analysis.audit", in: analysisNoFolder.entries).disabled)
        XCTAssertFalse(try action("analysis.codemap", in: analysisNoFolder.entries).disabled)
        XCTAssertTrue(try action("analysis.insight", in: analysisNoFolder.entries).disabled)

        // 4. Folder open without Markdown files or prototypes.
        let projectDir = root.appendingPathComponent("sample-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let emptyRoot = FileNode(url: projectDir, isDirectory: true)
        emptyRoot.children = []
        workspace.project.fileTree.rootNode = emptyRoot

        let withEmptyFolder = buildMenu()
        XCTAssertEqual(withEmptyFolder.utilities.map(\.disabled), [false, false])
        let protoEmptyFolder = try submenu("prototype", in: withEmptyFolder)
        XCTAssertFalse(try action("prototype.new", in: protoEmptyFolder.entries).disabled)
        XCTAssertFalse(try action("prototype.uiStudio", in: protoEmptyFolder.entries).disabled)
        XCTAssertTrue(try nestedSubmenu("prototype.open", in: protoEmptyFolder.entries).disabled)
        let analysisEmptyFolder = try submenu("analysis", in: withEmptyFolder)
        XCTAssertTrue(try action("analysis.insight", in: analysisEmptyFolder.entries).disabled)

        // 5. Folder open with a Markdown file and a saved prototype.
        let readme = projectDir.appendingPathComponent("README.md")
        try "# Sample\n".write(to: readme, atomically: true, encoding: .utf8)
        let protoFolder = PrototypeFiles.folder(root: projectDir, slug: "billing-portal")
        try FileManager.default.createDirectory(at: PrototypeFiles.site(of: protoFolder), withIntermediateDirectories: true)
        try "<html><body>Billing</body></html>".write(
            to: PrototypeFiles.site(of: protoFolder).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = PrototypeFiles.Manifest(
            title: "Billing Portal",
            slug: "billing-portal",
            brief: "Billing views",
            sources: ["README.md"],
            version: 2,
            approved: true,
            history: [PrototypeFiles.Entry(version: 2, instruction: "Initial", summary: "Built", date: Date())]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: PrototypeFiles.manifestURL(of: protoFolder))

        let populatedRoot = FileNode(url: projectDir, isDirectory: true)
        populatedRoot.children = [FileNode(url: readme, isDirectory: false)]
        workspace.project.fileTree.setRootNode(populatedRoot)
        for _ in 0..<100 where !workspace.project.fileTree.hasMarkdownFiles {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(workspace.project.fileTree.hasMarkdownFiles, "Real file tree probe should detect README.md")

        let withContent = buildMenu()
        let protoWithSaved = try submenu("prototype", in: withContent)
        let openProtoSaved = try nestedSubmenu("prototype.open", in: protoWithSaved.entries)
        XCTAssertEqual(openProtoSaved.title, "Open Prototype (1)")
        XCTAssertFalse(openProtoSaved.disabled)
        let savedAction = try action("prototype.open.billing-portal", in: openProtoSaved.entries)
        XCTAssertEqual(savedAction.title, "Billing Portal · v2 · approved")

        let analysisWithMarkdown = try submenu("analysis", in: withContent)
        XCTAssertFalse(try action("analysis.insight", in: analysisWithMarkdown.entries).disabled)

        // 6. Verify actions route to the expected workspace behaviors.
        let diagramsWithContent = try submenu("diagrams", in: withContent)
        for (id, expectedType) in [
            ("diagrams.architecture", "architecture"),
            ("diagrams.dataflow", "dataflow"),
            ("diagrams.pipeline", "pipeline"),
            ("diagrams.deployment", "deployment"),
            ("diagrams.sequence", "sequence"),
            ("diagrams.er", "er")
        ] {
            try action(id, in: diagramsWithContent.entries).perform()
            XCTAssertEqual(workspace.requests.pendingGraphCreatorType, expectedType, "Diagram action \(id) sets graph creator type")
        }

        try action("prototype.new", in: protoWithSaved.entries).perform()
        XCTAssertTrue(workspace.requests.showPrototypeCreator)
        XCTAssertEqual(workspace.requests.prototypeCreatorMode, .requirements)

        try action("prototype.uiStudio", in: protoWithSaved.entries).perform()
        XCTAssertTrue(workspace.tabs.openTabs.contains { $0.kind.toolID == .uiStudio })

        savedAction.perform()
        XCTAssertTrue(workspace.tabs.openTabs.contains {
            if case .prototype(let session) = $0.kind { return session.manifest.slug == "billing-portal" }
            return false
        })

        try action("analysis.research", in: analysisWithMarkdown.entries).perform()
        XCTAssertEqual(workspace.requests.intake?.kind, .research)

        try XCTUnwrap(withContent.utilities.first(where: { $0.id == "project.cycleTime" })).perform()
        try XCTUnwrap(withContent.utilities.first(where: { $0.id == "project.settings" })).perform()
        XCTAssertEqual(cycleTimeOpened, 1)
        XCTAssertEqual(settingsOpened, 1)
    }
}

@MainActor private func themeWebSpin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class ThemeWebHostTests: XCTestCase {
    @MainActor func testWebThemes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let editor = environment["MARKVIEW_THEME_EDITOR"] ?? root.appendingPathComponent("MarkView/Resources/Editor").path
        let captureOutput = environment["MARKVIEW_THEME_CAPTURE"]
        let capturing = captureOutput != nil
        let fixturePath: String? = captureOutput ?? root.appendingPathComponent("Tests/Fixtures/themes/classic-computed.json").path
        final class Context: @unchecked Sendable {
            let editor: String
            private let lock = NSLock()
            private var scratchFolders: [URL] = []
            var cleanups: [() -> Void] = []
            init(editor: String) { self.editor = editor }
            func registerScratch(_ folder: URL) {
                lock.lock(); scratchFolders.append(folder); lock.unlock()
            }
            func cleanupScratch() -> [URL] {
                lock.lock(); let folders = scratchFolders; scratchFolders.removeAll(); lock.unlock()
                for folder in folders { try? FileManager.default.removeItem(at: folder) }
                return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            func cleanup() -> [URL] {
                let callbacks = cleanups; cleanups.removeAll()
                callbacks.forEach { $0() }
                return cleanupScratch()
            }
        }
        let context = Context(editor: editor)
        defer { XCTAssertTrue(context.cleanup().isEmpty, "Temporary theme fixtures must be removed") }
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 300)
        watchdog.setEventHandler {
            FileHandle.standardError.write(Data("TIMEOUT: web-theme test exceeded 300 seconds\n".utf8))
            _ = context.cleanupScratch()
            exit(1)
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        _ = NSApplication.shared
        func check(_ ok: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
            if !ok { XCTFail("\(message): \(String(detail().prefix(1200)))") }
        }
final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    let context: Context
    var loaded = false
    var messages: [[String: Any]] = []

    init(context: Context, width: CGFloat = 1100, height: CGFloat = 760, firstPaint: String? = nil) {
        self.context = context
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let recorder = WKUserScript(source: """
        window.__errors = [];
        window.addEventListener('error', function (e) { window.__errors.push('error: ' + e.message + ' @' + (e.filename || '') + ':' + e.lineno); });
        window.addEventListener('unhandledrejection', function (e) { window.__errors.push('rejection: ' + (e.reason && e.reason.message || e.reason)); });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(recorder)
        // What the app injects into a page loaded from a file (discussion, terminal): the theme attributes, before the page's own scripts.
        if let firstPaint { config.userContentController.addUserScript(WKUserScript(source: firstPaint, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        // A window that is never shown does not run transitions, so a colour would stay at its old value: measure end states.
        let still = WKUserScript(source: """
        (function () { const style = document.createElement('style'); style.textContent = '*, *::before, *::after { transition: none !important; animation: none !important; }'; document.documentElement.appendChild(style); })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(still)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = QAWebWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = web
        super.init()
        window.orderBack(nil)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }, "Theme host stays outside every display")
        XCTAssertFalse(window.isKeyWindow || window.isMainWindow, "Theme host does not take focus")
        for name in ["bridge", "discussion", "terminal"] { config.userContentController.add(self, name: name) }
        web.navigationDelegate = self
        context.cleanups.append { [weak self] in self?.cleanup() }
    }

    func cleanup() {
        web.stopLoading(); web.navigationDelegate = nil
        for name in ["bridge", "discussion", "terminal"] { web.configuration.userContentController.removeScriptMessageHandler(forName: name) }
        window.contentView = nil; window.close()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// Loads a page of the editor folder. `rewrite` changes the page text first, the way the app writes the theme
    /// attributes into it; the changed page then sits in a scratch folder beside links to everything else of the editor.
    func load(_ name: String, rewrite: ((String) -> String)? = nil) {
        loaded = false
        let folder = URL(fileURLWithPath: context.editor)
        if let rewrite, let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("theme-web-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            context.registerScratch(scratch)
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where item != name {
                try? FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent(item), withDestinationURL: folder.appendingPathComponent(item))
            }
            let page = scratch.appendingPathComponent(name)
            try? rewrite(text).write(to: page, atomically: true, encoding: .utf8)
            web.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            web.loadFileURL(folder.appendingPathComponent(name), allowingReadAccessTo: folder)
        }
        themeWebSpin(60) { loaded }
        themeWebSpin(1.2)
        XCTAssertEqual(js("return String(document.visibilityState);"), "visible", "Theme host must allow WebKit's rendering clock to run")
    }

    /// Runs a function body in the page; the result is a string (JSON for structures).
    func js(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 20) -> String {
        var out: String?
        web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            switch result {
            case .success(let value): out = value as? String ?? "\(String(describing: value))"
            case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
            }
        }
        themeWebSpin(timeout) { out != nil }
        return out ?? "TIMEOUT"
    }
    func json(_ body: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        let text = js(body, arguments)
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["error": text] }
        return object
    }
    func eval(_ expression: String) -> String { js("return String(" + expression + ");") }
    var errors: [String] {
        let text = js("return JSON.stringify(window.__errors || []);")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? [text]
    }
}

// ---- colours ----------------------------------------------------------------------------------------------------------
/// The appearances: id, mode, and the base colours of the native palettes or the old page (Classic).
struct Look { let id: String; let dark: Bool; let background: String; let panel: String; let text: String; let accent: String; let classic: Bool }
let shippedLooks: [Look] = [
    Look(id: "classic-dark", dark: true, background: "#1e1e1e", panel: "#252526", text: "#d4d4d4", accent: "#569cd6", classic: true),
    Look(id: "classic-light", dark: false, background: "#ffffff", panel: "#f3f3f3", text: "#1e1e1e", accent: "#569cd6", classic: true),
    Look(id: "darcula", dark: true, background: "#2b2b2b", panel: "#323232", text: "#e0e0e0", accent: "#e6a15c", classic: false),
    Look(id: "midnight", dark: true, background: "#151c2b", panel: "#1d2738", text: "#e5ebf5", accent: "#79b8ff", classic: false),
    Look(id: "graphite", dark: true, background: "#202124", panel: "#2a2c30", text: "#e8eaed", accent: "#b39ddb", classic: false),
    Look(id: "tokyo-night", dark: true, background: "#1a1b26", panel: "#202233", text: "#d5daf0", accent: "#b49aff", classic: false),
    Look(id: "carbon-red", dark: true, background: "#171719", panel: "#212124", text: "#ede8e6", accent: "#ff6b81", classic: false),
    Look(id: "nord", dark: true, background: "#2e3440", panel: "#353c4a", text: "#e5e9f0", accent: "#88c0d0", classic: false),
    Look(id: "forest", dark: true, background: "#1e2a22", panel: "#26352b", text: "#ddd8c0", accent: "#a7c080", classic: false),
    Look(id: "paper", dark: false, background: "#fffcf5", panel: "#f2ede3", text: "#292724", accent: "#315e9b", classic: false),
    Look(id: "daylight", dark: false, background: "#f7f9fc", panel: "#e8edf4", text: "#1f2933", accent: "#0f766e", classic: false),
]

// Two theme files of the kind a person writes: native colours only, so every web token of them is derived.
let userThemesFolder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-web-tests-themes-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: userThemesFolder, withIntermediateDirectories: true)
context.registerScratch(userThemesFolder)
func writeUserTheme(_ id: String, name: String, bg: String, panel: String, text: String, accent: String) {
    let json = ##"{"schema":1,"id":"\##(id)","name":"\##(name)","native":{"bg":"\##(bg)","bgSidebar":"\##(panel)","text":"\##(text)","accent":"\##(accent)"}}"##
    try? Data(json.utf8).write(to: userThemesFolder.appendingPathComponent("\(id).json"))
}
writeUserTheme("ocean", name: "Ocean", bg: "#0B1620", panel: "#101F2C", text: "#E6EEF5", accent: "#4FC3F7")
writeUserTheme("sand", name: "Sand", bg: "#FBF6EC", panel: "#F0E8D8", text: "#2B2A28", accent: "#9A4F1B")
let userLooks = [
    Look(id: "ocean", dark: true, background: "#0b1620", panel: "#101f2c", text: "#e6eef5", accent: "#4fc3f7", classic: false),
    Look(id: "sand", dark: false, background: "#fbf6ec", panel: "#f0e8d8", text: "#2b2a28", accent: "#9a4f1b", classic: false),
]
let looks = shippedLooks + userLooks
let presets = looks.filter { !$0.classic }

// ---- what Swift sends: the real WindowTheme of each appearance --------------------------------------------------------
/// The three forms a window gives the web: the arguments of the page's theme function, the attributes written into the page
/// text, and the script injected into a page loaded from a file. All of them are produced by WindowTheme from the theme's data.
struct Sent { let arguments: WebThemeArguments; let payload: String; let attributes: String; let firstPaint: String }
let sentCatalog: ThemeCatalog = MainActor.assumeIsolated { ThemeCatalog(userFolder: userThemesFolder) }
var sentCache: [String: Sent] = [:]
func sentFor(_ id: String, accent: String? = nil) -> Sent {
    let key = id + "|" + (accent ?? "")
    if let cached = sentCache[key] { return cached }
    let made: Sent = MainActor.assumeIsolated {
        let name = "theme-web-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let theme = AppTheme(id)
        let accents: [AppTheme: ThemeColor] = accent.flatMap { ThemeColor(hex: $0) }.map { [theme: $0] } ?? [:]
        let window = WindowTheme(settings: WindowThemeSettings(theme: theme, accents: accents), store: ThemeSettingsStore(defaults: defaults), catalog: sentCatalog)
        return Sent(arguments: window.webArguments, payload: window.webArguments.payload, attributes: window.htmlAttributes, firstPaint: window.firstPaintScript)
    }
    sentCache[key] = made
    return made
}
/// The script a host sends to a page to set the theme: the same `JS.call` the hosts use.
func themeCall(_ function: String, _ sent: Sent) -> String { JS.call(function, args: sent.arguments.list) ?? "throw new Error('theme not encodable')" }
/// The theme data of an appearance as the page receives it (the JSON after the first two arguments).
func definitionObject(_ id: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(sentFor(id).payload.utf8)) as? [String: Any]) ?? [:]
}
/// Hands every appearance's data to a page, as repeated theme changes would have.
func defineAll(_ page: Page) {
    _ = page.js("defs.forEach(function (d) { MarkViewThemes.define(d); }); return 'ok';", ["defs": looks.map { definitionObject($0.id) }])
}

/// "rgb(30, 30, 30)" / "rgba(30, 30, 30, 0.5)" → [30, 30, 30, alpha]
func parseRGB(_ text: String) -> [Double]? {
    guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") else { return nil }
    let parts = text[text.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
    guard parts.count >= 3 else { return nil }
    return [parts[0], parts[1], parts[2], parts.count > 3 ? parts[3] : 1]
}
func hexOf(_ rgb: [Double]) -> String { String(format: "#%02x%02x%02x", Int(rgb[0].rounded()), Int(rgb[1].rounded()), Int(rgb[2].rounded())) }
func rgbFromHex(_ hex: String) -> [Double] {
    let n = Int(hex.dropFirst(), radix: 16) ?? 0
    return [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255), 1]
}
func luminance(_ c: [Double]) -> Double {
    let l = c.prefix(3).map { v -> Double in let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
}
func contrast(_ a: [Double], _ b: [Double]) -> Double {
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
/// `top` painted over `bottom` (alpha of `top` respected).
func over(_ top: [Double], _ bottom: [Double]) -> [Double] {
    let a = top[3]
    return [top[0] * a + bottom[0] * (1 - a), top[1] * a + bottom[1] * (1 - a), top[2] * a + bottom[2] * (1 - a), 1]
}

// ---- the editor page --------------------------------------------------------------------------------------------------
let markdown = """
# First heading

Some text with a [link](https://example.com), `inline code`, **bold** and *italic* words.

## Second heading

> A quote that is set apart.

### Third heading

| Name | Value |
|------|-------|
| one  | 1     |
| two  | 2     |

```swift
// a comment
func greet(_ name: String) -> String { return "Hello, \\(name)" + String(42) }
```

---

- a list item
- another list item
"""

/// What the sampled elements are called and where they are (the page before themes had all of them).
let probes: [(String, String)] = [
    ("html", "html"), ("body", "body"), ("container", ".editor-container"), ("toolbar", ".wysiwyg-toolbar"),
    ("toolbar-button", ".wysiwyg-toolbar button"), ("mode-label", ".wysiwyg-toolbar .mode-label"), ("toolbar-sep", ".wysiwyg-toolbar .sep"),
    ("rendered", ".editor-rendered"), ("source", ".editor-input"), ("h1", ".editor-rendered h1"), ("h2", ".editor-rendered h2"),
    ("h3", ".editor-rendered h3"), ("p", ".editor-rendered p"), ("link", ".editor-rendered a"), ("quote", ".editor-rendered blockquote"),
    ("inline-code", ".editor-rendered p code"), ("pre", ".editor-rendered pre"), ("pre-code", ".editor-rendered pre code"),
    ("th", ".editor-rendered th"), ("td", ".editor-rendered td"), ("hr", ".editor-rendered hr"), ("li", ".editor-rendered li"),
    ("token-comment", ".token.comment"), ("token-keyword", ".token.keyword"), ("token-string", ".token.string"),
    ("token-number", ".token.number"), ("token-function", ".token.function"), ("token-punctuation", ".token.punctuation"),
    ("find-bar", ".find-bar"), ("find-input", ".find-bar input"), ("find-button", ".find-bar button"),
    ("format-bar", ".format-bar"), ("format-button", ".format-bar button"), ("feature-menu", ".feature-menu"),
    ("feature-item", ".feature-menu-item"), ("more-menu", ".editor-more-menu"), ("insight-bar", ".insight-status-bar"),
    ("arch-toolbar", ".arch-toolbar"), ("arch-button", ".arch-btn"), ("empty-title", ".editor-empty-title"),
]
let sampleScript = """
const probes = [\(probes.map { "[\"\($0.0)\", \"\($0.1)\"]" }.joined(separator: ", "))];
const sides = ['Top', 'Bottom', 'Left'];
const out = {};
for (const [name, selector] of probes) {
  const el = document.querySelector(selector);
  if (!el) { out[name] = null; continue; }
  const cs = getComputedStyle(el), o = { color: cs.color, backgroundColor: cs.backgroundColor, textShadow: cs.textShadow, boxShadow: cs.boxShadow };
  // A border colour only counts where a border is drawn (otherwise it is just the text colour).
  sides.forEach(function (side) { o['border' + side + 'Color'] = (cs['border' + side + 'Style'] !== 'none' && parseFloat(cs['border' + side + 'Width']) > 0) ? cs['border' + side + 'Color'] : '-'; });
  o.outlineColor = (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0) ? cs.outlineColor : '-';
  out[name] = o;
}
return JSON.stringify(out);
"""

/// Sets the appearance through whichever entry point the page has (the old page took 'dark' or 'light').
func setLook(_ page: Page, _ look: Look, accent: String? = nil) {
    _ = page.js("""
    if (window.MarkViewThemes) \(themeCall("window.setTheme", sentFor(look.id, accent: accent)));
    else { window.setTheme('dark'); window.setTheme(dark ? 'dark' : 'light'); }   // the old page ignored a mode equal to its remembered one
    return 'ok';
    """, ["dark": look.dark])
    themeWebSpin(0.35)
}
func samples(_ page: Page) -> [String: [String: String]] {
    let text = page.js(sampleScript)
    if text.hasPrefix("JSERROR") || text == "TIMEOUT" { print("info sampling failed: \(text.prefix(300))") }
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
    var out: [String: [String: String]] = [:]
    for (name, value) in object { if let dict = value as? [String: String] { out[name] = dict } }
    return out
}
func loadEditor(rewrite: ((String) -> String)? = nil) -> Page {
    let page = Page(context: context)
    page.load("index.html", rewrite: rewrite)
    _ = page.js("window.setContent(text); return 'ok';", ["text": markdown])
    themeWebSpin(1.5)
    return page
}

/// The code view (CodeMirror): the editor, its text, its gutter and every coloured token by its text.
let codeSource = "func greet() -> String {\n    let n = 42 // a comment\n    return \"Hello\" + String(n)\n}\n"
let codeSampleScript = """
const out = {};
const sides = function (cs) { return { color: cs.color, backgroundColor: cs.backgroundColor }; };
[['cm-editor', '.cm-editor'], ['cm-content', '.cm-content'], ['cm-gutters', '.cm-gutters'], ['cm-line', '.cm-line'], ['cm-gutter-element', '.cm-lineNumbers .cm-gutterElement']].forEach(function (p) {
  const el = document.querySelector(p[1]);
  out[p[0]] = el ? sides(getComputedStyle(el)) : null;
});
document.querySelectorAll('.cm-line span').forEach(function (span) {
  const text = span.textContent.trim();
  if (text && !out['span:' + text]) out['span:' + text] = sides(getComputedStyle(span));
});
return JSON.stringify(out);
"""
func loadCodeView() -> Page {
    let page = Page(context: context)
    page.load("index.html")
    _ = page.js("window.setCodeContent(text, 'swift', 'Greeter.swift'); return 'ok';", ["text": codeSource])
    themeWebSpin(2.0)
    return page
}
func codeSamples(_ page: Page) -> [String: [String: String]] {
    let text = page.js(codeSampleScript)
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
    var out: [String: [String: String]] = [:]
    for (name, value) in object { if let dict = value as? [String: String] { out[name] = dict } }
    return out
}

// ---- capture mode -----------------------------------------------------------------------------------------------------
if capturing {
    let page = loadEditor()
    var result: [String: Any] = [:]
    for look in looks where look.classic {
        setLook(page, look)
        result[look.id] = samples(page)
    }
    let codePage = loadCodeView()
    for look in looks where look.classic {
        setLook(codePage, look)
        result["code:" + look.id] = codeSamples(codePage)
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: fixturePath!))
    print("captured \(result.count) appearances to \(fixturePath!)")
    return
}

// ---- the checks -------------------------------------------------------------------------------------------------------
let page = loadEditor()
check(page.eval("!!window.MarkViewThemes && typeof window.setTheme === 'function'") == "true", "the editor page has the window themes and setTheme")
let loadErrors = page.errors
print("info page errors after loading: \(loadErrors.count) \(loadErrors.prefix(3))")
let baselineErrors = loadErrors.count
check(page.eval("document.querySelector('.editor-rendered h1') !== null") == "true", "the sample document is drawn (heading present)")
// The page has no colours of any theme of its own: the data of a theme arrives with the call that applies it.
check(page.eval("Object.keys(MarkViewThemes.themes).length") == "0", "a page that was given no theme data holds none", page.eval("Object.keys(MarkViewThemes.themes).join()"))
defineAll(page)
check(page.eval("MarkViewThemes.ids().length") == "\(looks.count)", "after being given them the page knows every appearance (\(looks.count))", page.eval("MarkViewThemes.ids().join()"))

// The tokens of every appearance: the contrast the specification asks for, computed from the page's own functions.
let tokenReport = page.js("""
const T = window.MarkViewThemes, c = T.color, bad = [];
function chk(id, name, fg, bgs, min) {
  bgs.forEach(function (b) { const r = c.contrast(fg, b[1]); if (r < min) bad.push(id + ': ' + name + ' ' + fg + ' on ' + b[0] + ' ' + b[1] + ' = ' + r.toFixed(2) + ' < ' + min); });
}
T.ids().filter(function (id) { return !T.themes[id].vars; }).forEach(function (id) {
  const v = T.varsFor(id, ''), bgs = [['bg', v['--bg-primary']], ['panel', v['--bg-secondary']]];
  ['--text-primary', '--text-secondary', '--text-tertiary', '--accent-primary', '--accent-secondary', '--accent-warning', '--accent-success',
   '--accent-danger', '--h2-color', '--h3-color', '--ok-text', '--warn-text', '--bad-text', '--struct-key', '--struct-string', '--struct-number',
   '--struct-boolean', '--struct-null', '--struct-bracket', '--struct-tag', '--struct-attr-name', '--struct-attr-value', '--struct-comment',
   '--struct-count', '--mode-label', '--toolbar-text'].forEach(function (k) { chk(id, k, v[k], bgs, 4.5); });
  chk(id, 'code-text on code-bg', v['--code-text'], [['code-bg', v['--code-bg']]], 4.5);
  chk(id, 'text on tertiary', v['--text-primary'], [['tertiary', v['--bg-tertiary']]], 4.5);
  chk(id, 'secondary on tertiary', v['--text-secondary'], [['tertiary', v['--bg-tertiary']]], 4.5);
  chk(id, 'hover text on hover', v['--toolbar-text-hover'], [['hover', v['--toolbar-hover-bg']]], 4.5);
  chk(id, 'pre-text on pre-bg', v['--pre-text'], [['pre', v['--pre-bg']]], 4.5);
  ['--syn-comment', '--syn-punct', '--syn-property', '--syn-number', '--syn-string', '--syn-operator', '--syn-func', '--syn-keyword', '--syn-regex']
    .forEach(function (k) { chk(id, k, v[k], [['pre', v['--pre-bg']], ['bg', v['--bg-primary']]], 4.5); });
  chk(id, 'on-accent on the accent fill', v['--on-accent'], [['fill', v['--accent-fill']]], 4.5);
  chk(id, 'float text on float bg', v['--float-text'], [['float', v['--float-bg']]], 4.5);
  chk(id, 'float text on float hover', v['--float-text'], [['hover', v['--float-hover']]], 4.5);
  chk(id, 'discussion text on user bubble', v['--dc-fg'], [['user', v['--dc-user']], ['code', v['--dc-code']], ['card', v['--dc-card']]], 4.5);
  chk(id, 'discussion accent on bg', v['--dc-accent'], [['bg', v['--dc-bg']], ['card', v['--dc-card']]], 4.5);
  chk(id, 'discussion dim on bg', v['--dc-dim'], [['bg', v['--dc-bg']], ['card', v['--dc-card']]], 4.5);
  chk(id, 'discussion error on bg', v['--dc-error'], [['bg', v['--dc-bg']]], 4.5);
  const term = T.terminalTheme(id, ''), skip = T.themes[id].mode === 'dark' ? ['black'] : ['white', 'brightWhite'];
  Object.keys(term).forEach(function (k) {
    if (k === 'background' || k === 'selectionBackground' || skip.indexOf(k) >= 0) return;
    chk(id, 'terminal ' + k, term[k], [['terminal bg', term.background]], k === 'cursor' ? 3 : 4.5);
  });
  chk(id, 'terminal text on selection', term.foreground, [['selection', term.selectionBackground]], 4.5);
  ['--cm-fg', '--cm-gutter', '--cm-kw', '--cm-str', '--cm-num', '--cm-com', '--cm-fn', '--cm-type', '--cm-prop', '--cm-op', '--cm-tag'].forEach(function (k) {
    chk(id, k, v[k], [['code bg', v['--cm-bg']], ['code active line', v['--cm-active']]], 4.5);
    if (k !== '--cm-gutter') chk(id, k + ' on selection', v[k], [['code selection', v['--cm-sel']]], k === '--cm-fg' ? 4.5 : 3);
  });
});
return JSON.stringify(bad);
""")
let tokenFailures = (try? JSONSerialization.jsonObject(with: Data(tokenReport.utf8)) as? [String]) ?? [tokenReport]
check(tokenFailures.isEmpty, "every preset's text pairs meet 4.5:1 (cursor and syntax over a selection 3:1)", tokenFailures.joined(separator: "; "))

// Every appearance defines the same set of custom properties (nothing is left to the previous appearance).
let keyReport = page.js("""
const T = window.MarkViewThemes, ids = T.ids(), first = Object.keys(T.varsFor(ids[0], '')).sort().join();
return JSON.stringify(ids.filter(function (id) { return Object.keys(T.varsFor(id, '')).sort().join() !== first; }));
""")
check(keyReport == "[]", "all appearances define the same custom properties", keyReport)

// The colours of the real elements follow the tokens.
func colorOf(_ s: [String: [String: String]], _ probe: String, _ prop: String = "color") -> [Double]? {
    s[probe]?[prop].flatMap(parseRGB)
}
func near(_ a: [Double]?, _ hex: String, tolerance: Double = 1.5) -> Bool {
    guard let a else { return false }
    let b = rgbFromHex(hex)
    return (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
}
/// The colour a text sits on: the first opaque background up the element chain.
func effectiveBackground(_ page: Page, _ selector: String) -> [Double] {
    let text = page.js("""
    let el = document.querySelector(sel), layers = [];
    while (el) { layers.push(getComputedStyle(el).backgroundColor); el = el.parentElement; }
    return JSON.stringify(layers);
    """, ["sel": selector])
    let layers = ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? []).compactMap(parseRGB)
    var result: [Double] = [255, 255, 255, 1]
    for layer in layers.reversed() { result = over(layer, result) }
    return result
}
for look in looks {
    setLook(page, look)
    let s = samples(page)
    let attributes = page.json("const r = document.documentElement; return JSON.stringify({ preset: r.getAttribute('data-preset'), mode: r.getAttribute('data-theme'), accent: r.getAttribute('data-accent') || '' });")
    check((attributes["preset"] as? String) == look.id && (attributes["mode"] as? String) == (look.dark ? "dark" : "light"),
          "\(look.id): data-preset and data-theme follow the appearance", "\(attributes)")
    check(near(colorOf(s, "body", "backgroundColor"), look.background), "\(look.id): the page background is \(look.background)", "\(String(describing: s["body"]))")
    check(near(colorOf(s, "rendered"), look.text) || near(colorOf(s, "p"), look.text), "\(look.id): the document text is \(look.text)", "\(String(describing: s["p"]))")
    if !look.classic {
        let tokens = page.json("""
        const v = MarkViewThemes.varsFor(id, '');
        return JSON.stringify({ h2: v['--h2-color'], h3: v['--h3-color'], link: v['--accent-primary'], preBg: v['--pre-bg'], preText: v['--pre-text'],
          keyword: v['--syn-keyword'], string: v['--syn-string'], comment: v['--syn-comment'], number: v['--syn-number'], func: v['--syn-func'],
          toolbarText: v['--toolbar-text'], panel: v['--bg-secondary'] });
        """, ["id": look.id])
        func token(_ name: String) -> String { tokens[name] as? String ?? "#000000" }
        check(near(colorOf(s, "h2"), token("h2")), "\(look.id): second headings use the theme's heading colour", "\(String(describing: s["h2"]))")
        check(near(colorOf(s, "h3"), token("h3")), "\(look.id): third headings use the theme's heading colour", "\(String(describing: s["h3"]))")
        check(near(colorOf(s, "link"), token("link")), "\(look.id): links use the (legible) accent", "\(String(describing: s["link"]))")
        check(near(colorOf(s, "pre", "backgroundColor"), token("preBg")), "\(look.id): code blocks use the theme's block background", "\(String(describing: s["pre"]))")
        check(near(colorOf(s, "token-keyword"), token("keyword")), "\(look.id): Prism keywords use the theme's syntax colour", "\(String(describing: s["token-keyword"]))")
        check(near(colorOf(s, "token-string"), token("string")), "\(look.id): Prism strings use the theme's syntax colour", "\(String(describing: s["token-string"]))")
        check(near(colorOf(s, "token-comment"), token("comment")), "\(look.id): Prism comments use the theme's syntax colour", "\(String(describing: s["token-comment"]))")
        check(near(colorOf(s, "toolbar", "backgroundColor"), token("panel")) || colorOf(s, "toolbar", "backgroundColor") != nil, "\(look.id): the toolbar is painted", "\(String(describing: s["toolbar"]))")
        // The pairs a person reads, measured on the painted page (colour of the element over what is behind it).
        for (name, selector) in [("document text", ".editor-rendered p"), ("headings", ".editor-rendered h2"), ("links", ".editor-rendered a"),
                                 ("quotes", ".editor-rendered blockquote"), ("code blocks", ".editor-rendered pre code"), ("table cells", ".editor-rendered td"),
                                 ("keywords", ".token.keyword"), ("strings", ".token.string"), ("comments", ".token.comment"), ("numbers", ".token.number"),
                                 ("functions", ".token.function"), ("toolbar", ".wysiwyg-toolbar button"), ("mode label", ".wysiwyg-toolbar .mode-label")] {
            guard let key = probes.first(where: { $0.1 == selector })?.0, let color = colorOf(s, key) else {
                check(false, "\(look.id): \(name) can be measured", "no element for \(selector)"); continue
            }
            let background = effectiveBackground(page, selector)
            let ratio = contrast(over(color, background), background)
            check(ratio >= 4.5, "\(look.id): \(name) read at \(String(format: "%.1f", ratio)):1 on the painted page", "\(hexOf(color)) on \(hexOf(background)) = \(ratio)")
        }
    }
}

// An accent override reaches the accent colours; a reset returns the appearance's own.
for look in presets {
    let override = look.dark ? "#FF5555" : "#AA2200"
    setLook(page, look, accent: override)
    let overridden = page.json("""
    const v = getComputedStyle(document.documentElement);
    return JSON.stringify({ fill: v.getPropertyValue('--accent-fill').trim(), link: v.getPropertyValue('--accent-primary').trim(), attr: document.documentElement.getAttribute('data-accent') });
    """)
    let fill = overridden["fill"] as? String ?? ""
    let link = overridden["link"] as? String ?? ""
    check(fill.lowercased() == override.lowercased() && (overridden["attr"] as? String) == override, "\(look.id): the accent override is the accent fill", "\(overridden)")
    let linkRatio = contrast(rgbFromHex(link), rgbFromHex(look.background))
    check(linkRatio >= 4.5, "\(look.id): an accent override keeps links legible (\(String(format: "%.1f", linkRatio)):1)", "\(link)")
    setLook(page, look)
    let reset = page.json("""
    const v = getComputedStyle(document.documentElement);
    return JSON.stringify({ fill: v.getPropertyValue('--accent-fill').trim(), attr: document.documentElement.getAttribute('data-accent') || '' });
    """)
    check((reset["fill"] as? String)?.lowercased() == look.accent && (reset["attr"] as? String) == "", "\(look.id): a reset returns the appearance's own accent", "\(reset)")
}
// A null accent (what Swift sends for "no override") and an unreadable one fall back to the appearance's own accent.
for value in ["null", "'not a colour'", "undefined"] {
    let fill = page.js("window.setTheme('midnight', \(value)); return getComputedStyle(document.documentElement).getPropertyValue('--accent-fill').trim();")
    check(fill.lowercased() == "#79b8ff", "an accent of \(value) means the appearance's own", fill)
}
let unknown = page.js("window.setTheme('no-such-theme', null); return document.documentElement.getAttribute('data-preset');")
check(unknown == "classic-dark", "an unknown appearance falls back to Classic Dark", unknown)

// A theme change is a restyle: no reload, the text and the scroll position stay.
_ = page.js("window.__reloadMarker = 'same page'; return 'ok';")
let before = page.json("""
const r = document.querySelector('.editor-rendered');
r.style.minHeight = '3000px'; r.scrollTop = 120;
window.__editorNode = r;
return JSON.stringify({ html: r.innerHTML.length, text: r.textContent, scroll: r.scrollTop });
""")
for look in looks + looks.reversed() { setLook(page, look) }
let after = page.json("""
const r = document.querySelector('.editor-rendered');
return JSON.stringify({ html: r.innerHTML.length, text: r.textContent, scroll: r.scrollTop, marker: window.__reloadMarker, sameNode: r === window.__editorNode });
""")
// A reload would drop the marker and replace the element; the clock (performance.timeOrigin) is not used: some WebKit builds
// report it with a jitter, which made this check fail on the CI image while the page had not reloaded.
check((after["marker"] as? String) == "same page" && (after["sameNode"] as? Bool) == true, "repeated theme changes do not reload the page", "\(after)")
check((after["text"] as? String) == (before["text"] as? String) && (after["html"] as? Int) == (before["html"] as? Int), "the document text and structure are untouched by theme changes")
check((after["scroll"] as? Double) == (before["scroll"] as? Double), "the scroll position survives theme changes", "\(before["scroll"] ?? "") → \(after["scroll"] ?? "")")
// Source mode: the unsaved text in the editor field stays too.
_ = page.js("""
if (typeof window.toggleSourceMode === 'function') window.toggleSourceMode();
const input = document.getElementById('editor-input');
input.value = input.value + '\\n\\nUnsaved words that exist only in the field.';
return 'ok';
""")
themeWebSpin(0.3)
let typed = page.eval("document.getElementById('editor-input').value")
for look in looks { setLook(page, look) }
check(page.eval("document.getElementById('editor-input').value") == typed && typed.contains("Unsaved words"), "unsaved text in the source field survives theme changes")
let sourceColors = samples(page)
check(near(colorOf(sourceColors, "source"), looks.last!.text), "the source field takes the theme's text colour", "\(String(describing: sourceColors["source"]))")
let newErrors = page.errors
check(newErrors.count == baselineErrors, "theme changes raise no page errors", "\(newErrors.dropFirst(baselineErrors))")

// The first paint follows the attributes Swift writes into the page text (no setTheme call is needed).
for look in [looks[3], looks[5], looks[11]] {
    let attributes = sentFor(look.id, accent: "#C0FFEE").attributes
    let first = Page(context: context)
    first.load("index.html", rewrite: { $0.replacingOccurrences(of: "data-preset=\"classic-dark\" data-theme=\"dark\"", with: attributes) })
    let painted = first.json("""
    const v = getComputedStyle(document.documentElement);
    return JSON.stringify({ bg: getComputedStyle(document.body).backgroundColor, fill: v.getPropertyValue('--accent-fill').trim(), preset: document.documentElement.getAttribute('data-preset'),
      current: MarkViewThemes.current().id, stateTheme: state.theme });
    """)
    check(near(painted["bg"].flatMap { $0 as? String }.flatMap(parseRGB), look.background) && (painted["fill"] as? String)?.lowercased() == "#c0ffee" && (painted["current"] as? String) == look.id,
          "\(look.id): a page written with the theme attributes paints with them before any script call", "\(painted)")
    check((painted["stateTheme"] as? String) == (look.dark ? "dark" : "light"), "\(look.id): the page's mode follows the attributes", "\(painted)")
    check(first.eval("MarkViewThemes.ids().join()") == look.id, "\(look.id): the page learned only the theme in its attributes", first.eval("MarkViewThemes.ids().join()"))
}

// Two windows: two pages hold different appearances at the same time, and a change in one leaves the other alone.
let left = loadEditor(rewrite: { $0.replacingOccurrences(of: "data-preset=\"classic-dark\" data-theme=\"dark\"", with: sentFor("paper").attributes) })
let right = loadEditor(rewrite: { $0.replacingOccurrences(of: "data-preset=\"classic-dark\" data-theme=\"dark\"", with: sentFor("midnight", accent: "#FFAA00").attributes) })
func summary(_ p: Page) -> String { p.js("return document.documentElement.getAttribute('data-preset') + '|' + (document.documentElement.getAttribute('data-accent') || '') + '|' + getComputedStyle(document.body).backgroundColor;") }
check(summary(left) == "paper||rgb(255, 252, 245)" && summary(right) == "midnight|#FFAA00|rgb(21, 28, 43)", "two pages hold Paper and Midnight at the same time", "\(summary(left)) / \(summary(right))")
_ = left.js("\(themeCall("window.setTheme", sentFor("darcula", accent: "#33AAFF"))); return 'ok';")
themeWebSpin(0.3)
check(summary(left) == "darcula|#33AAFF|rgb(43, 43, 43)" && summary(right) == "midnight|#FFAA00|rgb(21, 28, 43)", "changing one page leaves the other as it was", "\(summary(left)) / \(summary(right))")

// ---- the code view ----------------------------------------------------------------------------------------------------
let codePage = loadCodeView()
check(codePage.eval("document.querySelector('.cm-editor') !== null") == "true", "the code view (CodeMirror) is drawn")
for look in looks {
    setLook(codePage, look)
    let cm = codeSamples(codePage)
    let tokens = codePage.json("const v = MarkViewThemes.varsFor(id, ''); return JSON.stringify({ bg: v['--cm-bg'], fg: v['--cm-fg'], kw: v['--cm-kw'], com: v['--cm-com'], num: v['--cm-num'], str: v['--cm-str'] });", ["id": look.id])
    func token(_ name: String) -> String { tokens[name] as? String ?? "#000000" }
    check(near(colorOf(cm, "cm-editor", "backgroundColor"), token("bg")), "\(look.id): the code view is painted with the theme's code background", "\(String(describing: cm["cm-editor"]))")
    check(near(colorOf(cm, "cm-content"), token("fg")) || near(colorOf(cm, "cm-line"), token("fg")), "\(look.id): code text uses the theme's text colour", "\(String(describing: cm["cm-line"]))")
    check(near(colorOf(cm, "span:func"), token("kw")), "\(look.id): code keywords use the theme's keyword colour", "\(String(describing: cm["span:func"]))")
    check(near(colorOf(cm, "span:// a comment"), token("com")), "\(look.id): code comments use the theme's comment colour", "\(cm.keys.sorted())")
    check(near(colorOf(cm, "span:42"), token("num")), "\(look.id): code numbers use the theme's number colour", "\(String(describing: cm["span:42"]))")
    if !look.classic {
        let background = rgbFromHex(token("bg"))
        for name in ["span:func", "span:// a comment", "span:42", "cm-line"] {
            guard let color = colorOf(cm, name) else { check(false, "\(look.id): \(name) is measurable", "no such element"); continue }
            let ratio = contrast(color, background)
            check(ratio >= 4.5, "\(look.id): \(name) in the code view reads at \(String(format: "%.1f", ratio)):1", "\(hexOf(color)) on \(token("bg"))")
        }
    }
}
check(codePage.errors.count <= baselineErrors, "theme changes in the code view raise no page errors", "\(codePage.errors)")

// ---- the discussion thread --------------------------------------------------------------------------------------------
let turnsJSON = """
[{"question":"What is in the plan?","answer":"## Result\\n\\nSee [the link](https://example.com) and `code`.\\n\\n| a | b |\\n|---|---|\\n| 1 | 2 |\\n\\n```js\\nlet x = 1\\n```\\n\\n> quoted"}]
"""
let discussion = Page(context: context, firstPaint: sentFor("nord").firstPaint)
discussion.load("discussion.html")
check(discussion.json("return JSON.stringify({ preset: document.documentElement.getAttribute('data-preset'), bg: getComputedStyle(document.body).backgroundColor });")["preset"] as? String == "nord" &&
      near(parseRGB(discussion.json("return JSON.stringify({ bg: getComputedStyle(document.body).backgroundColor });")["bg"] as? String ?? ""), "#2e3440"),
      "the discussion page loaded from a file paints the theme of the injected first-paint script before any call")
check(discussion.eval("typeof window.mvSetTheme === 'function' && !!window.MarkViewThemes") == "true", "the discussion page has mvSetTheme and the window themes")
_ = discussion.js("window.mvSetTurns(json); return 'ok';", ["json": turnsJSON])
themeWebSpin(1.2)
let discussionErrors = discussion.errors.count
for look in looks {
    _ = discussion.js("\(themeCall("window.mvSetTheme", sentFor(look.id))); return 'ok';")
    themeWebSpin(0.6)
    let d = discussion.json("""
    const cs = function (s, p) { const e = document.querySelector(s); return e ? getComputedStyle(e)[p] : null; };
    return JSON.stringify({ bg: cs('body', 'backgroundColor'), fg: cs('body', 'color'), link: cs('.a a', 'color'), th: cs('.a th', 'backgroundColor'), error: getComputedStyle(document.documentElement).getPropertyValue('--dc-error').trim(),
      preset: document.documentElement.getAttribute('data-preset') });
    """)
    let threadText = look.id == "classic-light" ? "#1f2328" : look.text   // the discussion and terminal pages had their own light text
    check(near((d["bg"] as? String).flatMap(parseRGB), look.background) && near((d["fg"] as? String).flatMap(parseRGB), threadText) && (d["preset"] as? String) == look.id,
          "\(look.id): the discussion thread takes the appearance (background \(look.background), text \(threadText))", "\(d)")
    if !look.classic, let link = (d["link"] as? String).flatMap(parseRGB), let bg = (d["bg"] as? String).flatMap(parseRGB) {
        let ratio = contrast(link, bg)
        check(ratio >= 4.5, "\(look.id): discussion links read at \(String(format: "%.1f", ratio)):1", "\(d)")
    }
}
check(discussion.errors.count == discussionErrors, "theme changes in the discussion raise no page errors", "\(discussion.errors.dropFirst(discussionErrors))")
check(discussion.eval("document.querySelectorAll('.turn').length") == "1" && discussion.eval("document.querySelector('.a').textContent.includes('Result')") == "true", "the discussion keeps its turns across theme changes")

// ---- the terminal -----------------------------------------------------------------------------------------------------
let terminal = Page(context: context, width: 800, height: 500, firstPaint: sentFor("forest").firstPaint)
terminal.load("terminal.html")
check(terminal.json("return JSON.stringify({ preset: document.documentElement.getAttribute('data-preset') });")["preset"] as? String == "forest" &&
      near(parseRGB(terminal.json("return JSON.stringify({ bg: getComputedStyle(document.body).backgroundColor });")["bg"] as? String ?? ""), "#1e2a22"),
      "the terminal page loaded from a file paints the theme of the injected first-paint script before any call")
check(terminal.eval("typeof window.mvSetTheme === 'function' && !!window.MarkViewThemes") == "true", "the terminal page has mvSetTheme and the window themes")
_ = terminal.js("window.mvWrite(btoa('plain text and \\u001b[31mred\\u001b[0m')); return 'ok';")
themeWebSpin(0.6)
for look in looks {
    _ = terminal.js("\(themeCall("window.mvSetTheme", sentFor(look.id))); return 'ok';")
    themeWebSpin(0.6)
    let t = terminal.json("""
    const rows = document.querySelector('.xterm-rows');
    return JSON.stringify({ page: getComputedStyle(document.body).backgroundColor, rows: rows ? getComputedStyle(rows).color : null, preset: document.documentElement.getAttribute('data-preset') });
    """)
    check(near((t["page"] as? String).flatMap(parseRGB), look.background) && (t["preset"] as? String) == look.id, "\(look.id): the terminal page is \(look.background)", "\(t)")
    if let rows = (t["rows"] as? String).flatMap(parseRGB) {
        let terminalText = look.id == "classic-light" ? "#1f2328" : look.text
        check(near(rows, terminalText), "\(look.id): the terminal draws its text in \(terminalText)", "\(t)")
    } else {
        check(false, "\(look.id): the terminal rows can be read", "\(t)")
    }
}

// ---- Classic equals the page before themes ----------------------------------------------------------------------------
if let fixturePath, let data = FileManager.default.contents(atPath: fixturePath),
   let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
    let fresh = loadEditor()
    for look in looks where look.classic {
        setLook(fresh, look)
        let now = samples(fresh)
        var different: [String] = []
        var compared = 0
        for (name, expected) in fixture[look.id] ?? [:] {
            guard let expectedProps = expected as? [String: String] else { continue }   // the element did not exist then
            guard let actual = now[name] else { different.append("\(name): element missing"); continue }
            for (prop, value) in expectedProps {
                compared += 1
                if actual[prop] != value { different.append("\(name).\(prop): \(value) → \(actual[prop] ?? "nil")") }
            }
        }
        check(different.isEmpty && compared > 100, "\(look.id): \(compared) sampled colours equal the page before themes", different.prefix(12).joined(separator: "; "))
    }
    let freshCode = loadCodeView()
    for look in looks where look.classic {
        setLook(freshCode, look)
        let now = codeSamples(freshCode)
        var different: [String] = []
        var compared = 0
        for (name, expected) in fixture["code:" + look.id] ?? [:] {
            guard let expectedProps = expected as? [String: String] else { continue }
            guard let actual = now[name] else { different.append("\(name): element missing"); continue }
            for (prop, value) in expectedProps {
                compared += 1
                if actual[prop] != value { different.append("\(name).\(prop): \(value) → \(actual[prop] ?? "nil")") }
            }
        }
        check(different.isEmpty && compared >= 20, "\(look.id): \(compared) code-view colours equal the page before themes", different.prefix(12).joined(separator: "; "))
    }
} else {
    print("info no fixture given: the comparison with the page before themes is skipped")
}


    }
}
