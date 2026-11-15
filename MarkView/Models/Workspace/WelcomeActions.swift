import Foundation

/// The things the welcome screen offers (feature welcome-screen-with-action-tiles-and-a-falling, REQ-001). The list is plain data so
/// it can be checked without a window; `ContentView` decides what each id does, with the same calls as the menus.
enum WelcomeActionID: Hashable {
    // A window with a project
    case terminal, newFeature, quickFeature, newBug, tasks
    case xray, understand, research, search, files, openFile, browser
    // A window without a folder
    case openFolder, newProject
    /// A tool of `ToolRegistry`: its tile is generated from its descriptor, and opening it is `WorkspaceManager.openTool`.
    case tool(ToolID)
}

struct WelcomeAction: Identifiable, Equatable {
    let id: WelcomeActionID
    let title: String
    let hint: String
    let symbol: String
    /// The shortcut the app's menu gives the same action, as it is shown on a key cap; nil when there is none.
    let shortcut: String?
    var isProminent = false
}

enum WelcomeCatalogue {
    /// The tiles that are not tools. Tools are not listed here: their tiles come from the registry (`AR-31`).
    private static let plain: [WelcomeActionID: WelcomeAction] = {
        let list = [
            WelcomeAction(id: .terminal, title: "Open Terminal", hint: "Start an agent or a shell", symbol: "terminal",
                          shortcut: "⌘3", isProminent: true),
            WelcomeAction(id: .newFeature, title: "New Feature…", hint: "Turn an idea into a specification", symbol: "plus.square",
                          shortcut: nil),
            WelcomeAction(id: .quickFeature, title: "Quick Feature…", hint: "A small change on one page", symbol: "bolt", shortcut: nil),
            WelcomeAction(id: .newBug, title: "New Bug…", hint: "Report a problem to be fixed", symbol: "ladybug", shortcut: nil),
            WelcomeAction(id: .tasks, title: "Tasks", hint: "Features and bugs, by status", symbol: "checklist", shortcut: nil),
            WelcomeAction(id: .xray, title: "Open X-Ray", hint: "A map of the project", symbol: "viewfinder", shortcut: "⌘4"),
            WelcomeAction(id: .understand, title: "I Need to Understand…", hint: "How a part works, and why",
                          symbol: "questionmark.bubble", shortcut: nil),
            WelcomeAction(id: .research, title: "New Research…", hint: "Study an open question", symbol: "doc.text.magnifyingglass",
                          shortcut: nil),
            WelcomeAction(id: .search, title: "Search Project…", hint: "Files, text, commands", symbol: "magnifyingglass",
                          shortcut: "⇧⌘K"),
            WelcomeAction(id: .files, title: "Show Files", hint: "Browse the project's folders", symbol: "folder", shortcut: nil),
            WelcomeAction(id: .openFile, title: "Open File…", hint: "Read or edit a document", symbol: "doc", shortcut: "⌘O"),
            WelcomeAction(id: .browser, title: "Browser", hint: "Open a web page", symbol: "globe", shortcut: "⌘5"),
            WelcomeAction(id: .openFolder, title: "Open Folder…", hint: "Work on a project", symbol: "folder.badge.plus",
                          shortcut: "⇧⌘O", isProminent: true),
            WelcomeAction(id: .newProject, title: "New Project…", hint: "Start from scratch",
                          symbol: "plus.rectangle.on.folder", shortcut: nil)
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }()

    /// Where the tiles that are not tools sit in a window with a project; the tiles of tools sit by the `order` of their descriptor, among
    /// these (a gap is left for each). Ascending inside a section.
    private static let placements: [(section: WelcomeSection, order: Int, id: WelcomeActionID)] = [
        (.start, 10, .terminal), (.start, 20, .newFeature), (.start, 30, .quickFeature), (.start, 40, .newBug), (.start, 60, .tasks),
        (.explore, 10, .xray), (.explore, 20, .understand), (.explore, 30, .research), (.explore, 40, .search), (.explore, 50, .files),
        (.explore, 60, .openFile),
        (.run, 70, .browser)
    ]

    private static func tile(of tool: ToolDescriptor, hint: String) -> WelcomeAction {
        WelcomeAction(id: .tool(tool.id), title: tool.title, hint: hint, symbol: tool.icon, shortcut: tool.shortcut?.hint)
    }

    /// What a window with a project offers, in the order it is shown. The tile of a tool that needs a Git repository appears only for one.
    static func project(isGitRepo: Bool, registry: ToolRegistry = .shared) -> [(section: WelcomeSection, actions: [WelcomeAction])] {
        let tools: [(section: WelcomeSection, order: Int, action: WelcomeAction)] = registry.welcomeTools.compactMap { tool in
            guard let welcome = tool.welcome, isGitRepo || !welcome.requiresGitRepository else { return nil }
            return (welcome.section, welcome.order, tile(of: tool, hint: welcome.hint))
        }
        let others = placements.map { (section: $0.section, order: $0.order, action: plain[$0.id]!) }
        return WelcomeSection.allCases.map { section in
            (section, (tools + others).filter { $0.section == section }.sorted { $0.order < $1.order }.map(\.action))
        }
    }

    /// What a window without a folder offers.
    static var emptyWindow: [WelcomeAction] { [.openFolder, .openFile, .newProject].map { plain[$0]! } }
}
