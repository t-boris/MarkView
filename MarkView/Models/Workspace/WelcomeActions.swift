import Foundation

/// The things the welcome screen offers (feature welcome-screen-with-action-tiles-and-a-falling, REQ-001). The list is plain data so
/// it can be checked without a window; `ContentView` decides what each id does, with the same calls as the menus.
enum WelcomeActionID: String, CaseIterable {
    // A window with a project
    case terminal, newFeature, quickFeature, newBug, discussions, tasks
    case xray, understand, research, search, files, openFile
    case git, deployments, workflow, qa, uiStudio, browser
    // A window without a folder
    case openFolder, newProject
}

enum WelcomeSection: String, CaseIterable, Identifiable {
    case start = "Start"
    case explore = "Explore"
    case run = "Build & Run"

    var id: String { rawValue }
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
    private static let all: [WelcomeActionID: WelcomeAction] = {
        let list = [
            WelcomeAction(id: .terminal, title: "Open Terminal", hint: "Start an agent or a shell", symbol: "terminal",
                          shortcut: "⌘3", isProminent: true),
            WelcomeAction(id: .newFeature, title: "New Feature…", hint: "Turn an idea into a specification", symbol: "plus.square",
                          shortcut: nil),
            WelcomeAction(id: .quickFeature, title: "Quick Feature…", hint: "A small change on one page", symbol: "bolt", shortcut: nil),
            WelcomeAction(id: .newBug, title: "New Bug…", hint: "Report a problem to be fixed", symbol: "ladybug", shortcut: nil),
            WelcomeAction(id: .discussions, title: "Discussions", hint: "Ask before it is a feature",
                          symbol: "bubble.left.and.bubble.right", shortcut: "⌃⌘I"),
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
            WelcomeAction(id: .git, title: "Git", hint: "Changes, commits, branches", symbol: "arrow.triangle.branch", shortcut: nil),
            WelcomeAction(id: .deployments, title: "Build & Deployment", hint: "Where the project runs",
                          symbol: "server.rack", shortcut: "⌃⌘D"),
            WelcomeAction(id: .workflow, title: "Workflow", hint: "Statuses and processes of tasks", symbol: "flowchart", shortcut: nil),
            WelcomeAction(id: .qa, title: "End-to-End QA", hint: "Scenarios checked branch by branch", symbol: "checklist.checked",
                          shortcut: "⌘8"),
            WelcomeAction(id: .uiStudio, title: "UI Studio", hint: "Design and compare UI", symbol: "paintpalette", shortcut: "⌘7"),
            WelcomeAction(id: .browser, title: "Browser", hint: "Open a web page", symbol: "globe", shortcut: "⌘5"),
            WelcomeAction(id: .openFolder, title: "Open Folder…", hint: "Work on a project", symbol: "folder.badge.plus",
                          shortcut: "⇧⌘O", isProminent: true),
            WelcomeAction(id: .newProject, title: "New Project…", hint: "Start from scratch",
                          symbol: "plus.rectangle.on.folder", shortcut: nil)
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }()

    static func action(_ id: WelcomeActionID) -> WelcomeAction { all[id]! }

    /// What a window with a project offers, in the order it is shown. Git appears only for a Git repository.
    static func project(isGitRepo: Bool) -> [(section: WelcomeSection, actions: [WelcomeAction])] {
        let layout: [(WelcomeSection, [WelcomeActionID])] = [
            (.start, [.terminal, .newFeature, .quickFeature, .newBug, .discussions, .tasks]),
            (.explore, [.xray, .understand, .research, .search, .files, .openFile]),
            (.run, (isGitRepo ? [.git] : []) + [.deployments, .workflow, .qa, .uiStudio, .browser])
        ]
        return layout.map { ($0.0, $0.1.map(action)) }
    }

    /// What a window without a folder offers.
    static var emptyWindow: [WelcomeAction] { [.openFolder, .openFile, .newProject].map(action) }
}
