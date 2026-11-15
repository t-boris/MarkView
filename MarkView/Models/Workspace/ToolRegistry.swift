import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The identity of a tool that has one tab per window (Git, Workflow, QA...). The raw value is also the key the tool's tab is saved
/// under in a window session, so a value never changes once released (`AR-31`).
struct ToolID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let git = ToolID(rawValue: "git")
    static let deployments = ToolID(rawValue: "deployments")
    static let workflow = ToolID(rawValue: "workflow")
    static let qa = ToolID(rawValue: "qa")
    static let uiStudio = ToolID(rawValue: "uiStudio")
    static let cockpit = ToolID(rawValue: "cockpit")
    static let discussions = ToolID(rawValue: "discussions")
    static let changeReview = ToolID(rawValue: "changeReview")
}

/// A keyboard shortcut as plain data; the menu turns it into a SwiftUI `KeyboardShortcut` and every other surface prints `hint`.
struct ToolShortcut: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    let key: Character
    let modifiers: Modifiers

    /// The shortcut as it is printed on key caps ("⌃⌘D"), modifiers in the order macOS prints them.
    var hint: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }
}

/// Where a tool's button sits in the window toolbar.
enum ToolbarSlot: Hashable, Sendable {
    /// The cluster of project tools, before Prototype and Browser.
    case primary
    /// After the Browser menu.
    case afterBrowser
}

/// Where a tool's item sits in the View menu, between items the menu owns itself.
enum ToolMenuSlot: Hashable, Sendable {
    /// Right after "Agents".
    case afterAgents
    /// Right after "Preview Web App".
    case afterWebPreview
}

struct ToolMenuEntry: Hashable, Sendable {
    let slot: ToolMenuSlot
    /// Position inside the slot, ascending.
    let order: Int
    /// The item is disabled while the window has no folder.
    let requiresFolder: Bool
}

/// The sections of the welcome screen of a window with a project; a tool's tile names the one it sits in.
enum WelcomeSection: String, CaseIterable, Identifiable, Sendable {
    case start = "Start"
    case explore = "Explore"
    case run = "Build & Run"

    var id: String { rawValue }
}

/// A tool's tile on the welcome screen of a window with a project.
struct ToolWelcomeTile: Hashable, Sendable {
    let section: WelcomeSection
    /// Position inside the section next to the tiles that are not tools, ascending.
    let order: Int
    let hint: String
    /// The tile is offered only when the folder is a Git repository.
    var requiresGitRepository = false
}

/// Everything the app knows about a tool with one tab per window, in one value (`AR-31`, `DEC-001`, `FU-02`). The toolbar, the View
/// menu, the tab bar, the welcome screen and the window session are generated from these values by `ToolRegistry`.
struct ToolDescriptor: Identifiable, Hashable, Sendable {
    let id: ToolID
    /// The tab's name, the menu item and the welcome tile.
    let title: String
    /// One SF Symbol for the toolbar button, the tab and the tile.
    let icon: String
    /// The placeholder file the tab stands on (never read or written), relative to the project folder; saved tabs and the tab
    /// matching of older sessions depend on these values.
    let sentinelPath: String
    let shortcut: ToolShortcut?
    let toolbar: ToolbarSlot?
    let menu: ToolMenuEntry?
    let welcome: ToolWelcomeTile?
    /// The tab is saved in the window session and opened again on launch.
    let restorable: Bool

    init(id: ToolID, title: String, icon: String, sentinelPath: String, shortcut: ToolShortcut? = nil, toolbar: ToolbarSlot? = nil,
         menu: ToolMenuEntry? = nil, welcome: ToolWelcomeTile? = nil, restorable: Bool) {
        self.id = id
        self.title = title
        self.icon = icon
        self.sentinelPath = sentinelPath
        self.shortcut = shortcut
        self.toolbar = toolbar
        self.menu = menu
        self.welcome = welcome
        self.restorable = restorable
    }

    /// The toolbar button's tooltip and accessibility label.
    var help: String { shortcut.map { "\(title) (\($0.hint))" } ?? title }

    func sentinelURL(in root: URL, suffix: String = "") -> URL {
        root.appendingPathComponent(sentinelPath + suffix)
    }
}

/// The tools of the app, and every surface generated from them. A new tool is one `ToolDescriptor` in `shared` (plus the view its tab
/// shows); a registry made of other descriptors generates the same surfaces from them.
struct ToolRegistry: Sendable {
    let tools: [ToolDescriptor]

    static let shared = ToolRegistry(tools: [
        ToolDescriptor(
            id: .git, title: "Git", icon: "arrow.triangle.branch", sentinelPath: ProjectPaths.sentinelRelativePath("git"),
            toolbar: .primary,
            welcome: ToolWelcomeTile(section: .run, order: 10, hint: "Changes, commits, branches", requiresGitRepository: true),
            restorable: true
        ),
        ToolDescriptor(
            id: .deployments, title: "Build & Deployment", icon: "server.rack", sentinelPath: ProjectPaths.sentinelRelativePath("deployments"),
            shortcut: ToolShortcut(key: "d", modifiers: [.command, .control]),
            toolbar: .primary,
            menu: ToolMenuEntry(slot: .afterAgents, order: 1, requiresFolder: false),
            welcome: ToolWelcomeTile(section: .run, order: 20, hint: "Where the project runs"),
            restorable: true
        ),
        ToolDescriptor(
            id: .workflow, title: "Workflow", icon: "point.3.connected.trianglepath.dotted", sentinelPath: ProjectPaths.sentinelRelativePath("workflow"),
            toolbar: .primary,
            welcome: ToolWelcomeTile(section: .run, order: 30, hint: "Statuses and processes of tasks"),
            restorable: true
        ),
        ToolDescriptor(
            id: .qa, title: "End-to-End QA", icon: "checkmark.shield", sentinelPath: ProjectPaths.sentinelRelativePath("qa"),
            shortcut: ToolShortcut(key: "8", modifiers: .command),
            toolbar: .primary,
            menu: ToolMenuEntry(slot: .afterWebPreview, order: 2, requiresFolder: true),
            welcome: ToolWelcomeTile(section: .run, order: 40, hint: "Scenarios checked branch by branch"),
            restorable: true
        ),
        ToolDescriptor(
            id: .uiStudio, title: "UI Studio", icon: "macwindow.and.cursorarrow", sentinelPath: ProjectPaths.sentinelRelativePath("ui-studio-"),
            shortcut: ToolShortcut(key: "7", modifiers: .command),
            toolbar: .primary,
            menu: ToolMenuEntry(slot: .afterWebPreview, order: 1, requiresFolder: true),
            welcome: ToolWelcomeTile(section: .run, order: 50, hint: "Design and compare UI"),
            restorable: false
        ),
        ToolDescriptor(
            id: .cockpit, title: "Copilot Cockpit", icon: "airplane", sentinelPath: ProjectPaths.sentinelRelativePath("cockpit"),
            toolbar: .primary,
            menu: ToolMenuEntry(slot: .afterWebPreview, order: 3, requiresFolder: true),
            welcome: ToolWelcomeTile(section: .run, order: 60, hint: "Plan a goal, then watch the run"),
            restorable: false
        ),
        ToolDescriptor(
            id: .discussions, title: "Discussions", icon: "bubble.left.and.text.bubble.right", sentinelPath: ProjectPaths.sentinelRelativePath("discussions"),
            shortcut: ToolShortcut(key: "i", modifiers: [.command, .control]),
            toolbar: .afterBrowser,
            menu: ToolMenuEntry(slot: .afterAgents, order: 2, requiresFolder: false),
            welcome: ToolWelcomeTile(section: .start, order: 50, hint: "Ask before it is a feature"),
            restorable: true
        ),
        ToolDescriptor(
            id: .changeReview, title: "File changes", icon: "doc.text.magnifyingglass", sentinelPath: ProjectPaths.sentinelRelativePath("file-changes"),
            restorable: true
        )
    ])

    func descriptor(for id: ToolID) -> ToolDescriptor? {
        tools.first { $0.id == id }
    }

    /// The tools whose button sits in `slot` of the toolbar, left to right.
    func toolbarTools(_ slot: ToolbarSlot) -> [ToolDescriptor] {
        tools.filter { $0.toolbar == slot }
    }

    /// The tools whose item sits in `slot` of the View menu, top to bottom.
    func menuTools(_ slot: ToolMenuSlot) -> [ToolDescriptor] {
        tools.compactMap { tool in tool.menu.flatMap { $0.slot == slot ? (tool, $0.order) : nil } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The tools that have a tile on the welcome screen of a window with a project.
    var welcomeTools: [ToolDescriptor] {
        tools.filter { $0.welcome != nil }
    }

    /// Whether the tool's tab is saved in the window session and opened again on launch.
    func isRestorable(_ id: ToolID) -> Bool {
        descriptor(for: id)?.restorable == true
    }
}
