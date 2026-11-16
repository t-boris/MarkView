import Foundation

// Checks the layout presets (AR-33, DEC-002) on the app's own code: the presets that ship are read from the bundled folder and are the
// four the decision names; a person's folder is validated file by file and a file that cannot be used is reported with its reason, never
// skipped and never touched; and applying a preset changes the tabs of one window's `PanelLayout` and nothing else.
// Arguments: the folder of the shipped presets (MarkView/Resources/Layouts).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

guard CommandLine.arguments.count > 1 else { print("usage: layout-preset-tests <Layouts folder>"); exit(2) }
let shipped = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

// MARK: Helpers

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

    print(failures == 0 ? "\nAll layout preset checks passed" : "\n\(failures) layout preset check(s) FAILED")
}

MainActor.assumeIsolated { run() }

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
print(failures == 0 ? "\nAll layout catalog checks passed" : "\n\(failures) check(s) FAILED")
if failures > 0 { exit(1) }
