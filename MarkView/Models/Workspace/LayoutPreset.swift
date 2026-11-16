import Foundation

// A window layout the person chooses by hand (architecture review AR-33, DEC-002): which panels one window shows, what the left and
// right panels show, and the tool whose tab is brought forward. A preset is data: the ones that ship are JSON files in
// `Resources/Layouts/`, a person's own go in `~/Library/Application Support/MarkView/layouts/` (`LayoutLibrary` reads both).
// Nothing applies a preset by itself (no trigger on a tool, a project or a Git change): a window keeps its own state until its person
// chooses one from the View menu or the toolbar. Foundation only, so `tools/tests/layout-preset-tests.sh` compiles it without the app.

struct LayoutPreset: Equatable, Identifiable, Sendable {
    /// Which panels the window shows. Every key is required in a file, so a preset describes the whole row of panels.
    struct Panels: Equatable, Sendable {
        /// The left panel (Files or Issues).
        var files: Bool
        /// The workspace in the middle: the tab bar and what the active tab shows.
        var center: Bool
        /// The right panel (Contents or Tasks).
        var right: Bool
        /// The floating Agents panel.
        var agents: Bool
    }

    /// What the left panel shows; the values are the ones `PanelLayout.leftPanel` stores.
    enum LeftPanel: String, CaseIterable, Sendable {
        case files, issues
    }

    /// What the right panel shows.
    enum RightPanel: String, CaseIterable, Sendable {
        case contents, feature

        var navigatorTab: NavigatorTab {
            switch self {
            case .contents: return .contents
            case .feature: return .feature
            }
        }
    }

    /// Why a file is not a usable preset, in one sentence that names the value at fault.
    struct Problem: Error, Equatable, Sendable {
        let reason: String
    }

    static let schemaVersion = 1
    /// A preset file is a few hundred bytes; a larger one is not a preset.
    static let maxFileSize = 16 * 1024

    let id: String
    let name: String
    /// An SF Symbol name for the menu and the toolbar.
    let symbol: String
    let summary: String
    let panels: Panels
    /// `nil`: the window's left panel keeps what it shows.
    let left: LeftPanel?
    /// `nil`: the window's right panel keeps what it shows.
    let right: RightPanel?
    /// The tool whose tab is opened or brought forward; `nil`: the center keeps its active tab.
    let tool: ToolID?

    // MARK: Reading

    private static let topKeys: Set<String> = ["schema", "id", "name", "symbol", "summary", "panels", "left", "right", "tool"]
    private static let panelKeys: Set<String> = ["files", "center", "right", "agents"]
    private static let idLimit = 40
    private static let nameLimit = 40
    private static let summaryLimit = 120
    private static let symbolLimit = 64

    private struct File: Decodable {
        struct Panels: Decodable {
            let files: Bool
            let center: Bool
            let right: Bool
            let agents: Bool
        }

        let schema: Int
        let id: String
        let name: String
        let symbol: String
        let summary: String?
        let panels: Panels
        let left: String?
        let right: String?
        let tool: String?
    }

    /// The preset in `data`, or the one reason it cannot be used. `tools` names the tools a preset may open.
    static func parse(_ data: Data, tools: ToolRegistry = .shared) -> Result<LayoutPreset, Problem> {
        do { return .success(try read(data, tools: tools)) } catch let problem as Problem { return .failure(problem) } catch {
            return .failure(Problem(reason: "the file cannot be read"))
        }
    }

    private static func read(_ data: Data, tools: ToolRegistry) throws -> LayoutPreset {
        guard data.count <= maxFileSize else { throw Problem(reason: "the file is larger than \(maxFileSize / 1024) KB") }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Problem(reason: "the file is not valid JSON") }
        guard let top = object as? [String: Any] else { throw Problem(reason: "the top level of the file must be an object") }

        // The schema comes first: a file written by a newer MarkView may have keys and values this one cannot judge.
        guard let schema = top["schema"] as? Int, !isBoolean(top["schema"]) else { throw Problem(reason: "\"schema\" is missing or is not a number") }
        guard schema == schemaVersion else {
            throw Problem(reason: schema > schemaVersion
                ? "the file uses schema \(schema), which a newer MarkView wrote; this one reads schema \(schemaVersion)"
                : "the file uses schema \(schema); this MarkView reads schema \(schemaVersion)")
        }
        if let unknown = top.keys.filter({ !topKeys.contains($0) }).sorted().first { throw Problem(reason: "unknown key \(quoted(unknown))") }
        if let panels = top["panels"] as? [String: Any], let unknown = panels.keys.filter({ !panelKeys.contains($0) }).sorted().first {
            throw Problem(reason: "unknown key \(quoted("panels." + unknown))")
        }

        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch let error as DecodingError { throw Problem(reason: describe(error)) }

        guard file.id.range(of: "^[a-z0-9][a-z0-9-]*\\z", options: .regularExpression) != nil, file.id.count <= idLimit else {
            throw Problem(reason: "\"id\" must be 1 to \(idLimit) characters: lowercase letters, digits and hyphens, not starting with a hyphen (found \(quoted(file.id)))")
        }
        let name = file.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= nameLimit, !hasControlCharacter(name) else {
            throw Problem(reason: "\"name\" must be 1 to \(nameLimit) characters on one line")
        }
        guard file.symbol.range(of: "^[a-z0-9]+(\\.[a-z0-9]+)*\\z", options: .regularExpression) != nil, file.symbol.count <= symbolLimit else {
            throw Problem(reason: "\"symbol\" must be an SF Symbol name such as \"doc.text\" (found \(quoted(file.symbol)))")
        }
        let summary = file.summary ?? ""
        guard summary.count <= summaryLimit, !hasControlCharacter(summary) else {
            throw Problem(reason: "\"summary\" must be at most \(summaryLimit) characters on one line")
        }

        let panels = Panels(files: file.panels.files, center: file.panels.center, right: file.panels.right, agents: file.panels.agents)
        // The window never hides its last panel (the toggles refuse to); a preset that would is not a layout.
        guard panels.files || panels.center || panels.right else { throw Problem(reason: "\"panels\" hides the files, center and right panels: one of them must stay") }

        let left = try file.left.map { raw -> LeftPanel in
            guard let value = LeftPanel(rawValue: raw) else { throw Problem(reason: "\"left\" must be \(choices(LeftPanel.allCases)) (found \(quoted(raw)))") }
            return value
        }
        let right = try file.right.map { raw -> RightPanel in
            guard let value = RightPanel(rawValue: raw) else { throw Problem(reason: "\"right\" must be \(choices(RightPanel.allCases)) (found \(quoted(raw)))") }
            return value
        }
        let tool = try file.tool.map { raw -> ToolID in
            let id = ToolID(rawValue: raw)
            guard tools.descriptor(for: id) != nil else {
                throw Problem(reason: "unknown tool \(quoted(raw)); the tools are \(tools.tools.map(\.id.rawValue).joined(separator: ", "))")
            }
            return id
        }
        // Opening a tool shows the center panel, so a preset that hides it and names a tool says two things at once.
        if tool != nil, !panels.center { throw Problem(reason: "\"tool\" opens a tab in the center panel, which \"panels\" hides") }

        return LayoutPreset(id: file.id, name: name, symbol: file.symbol, summary: summary, panels: panels, left: left, right: right, tool: tool)
    }

    /// A number that JSONSerialization hands out for `true` or `false` also reads as an integer; a boolean is not a schema number.
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func hasControlCharacter(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) != nil
    }

    private static func choices<T: RawRepresentable>(_ all: [T]) -> String where T.RawValue == String {
        all.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
    }

    /// A value from a file, for a message: on one line and short, whatever the file held.
    private static func quoted(_ text: String) -> String {
        let breaks = CharacterSet.controlCharacters.union(.newlines)
        let flat = String(text.unicodeScalars.map { breaks.contains($0) ? " " : Character($0) })
        return "\"" + (flat.count > 40 ? String(flat.prefix(40)) + "…" : flat) + "\""
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [CodingKey]) -> String { quoted(keys.map(\.stringValue).joined(separator: ".")) }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context.codingPath + [key])) is missing"
        case .typeMismatch(_, let context): return "\(path(context.codingPath)) has the wrong type"
        case .valueNotFound(_, let context): return "\(path(context.codingPath)) is empty"
        default: return "the file is not valid JSON"
        }
    }
}

// MARK: - Applying

extension PanelLayout {
    /// The tabs a preset names, in this window's layout only: another window's `PanelLayout` is another object and keeps what it shows.
    /// Which panels are visible, and the tool tab, belong to the window's `WorkspaceManager` (`applyLayoutPreset`).
    func apply(_ preset: LayoutPreset) {
        if let left = preset.left { leftPanel = left.rawValue }
        if let right = preset.right { navigatorTab = right.navigatorTab }
    }
}
