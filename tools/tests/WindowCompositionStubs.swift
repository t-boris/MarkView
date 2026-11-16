import AppKit
import Combine
import Foundation

// The parts of a window that `WindowComposition` builds and joins, as stand-ins named like the real ones. Each keeps what it was given at
// construction and records what the window asked of it, so the checks can tell that the composition built every part once, with the
// window's own project, tabs and task bag, and that its events reach the right part. The composition and the task bag are the shipping code.

/// What the window's parts ask of their window: one narrow protocol each (empty here; the stand-in window conforms to all of them).
@MainActor protocol AITerminalsHost: AnyObject {}
@MainActor protocol BrowserHostWindow: AnyObject {}
@MainActor protocol CodeXRayHost: AnyObject {}
@MainActor protocol FeatureFlowTabs: AnyObject {}
@MainActor protocol FileOperationsHost: AnyObject {}
@MainActor protocol InsightHost: AnyObject {}
@MainActor protocol ResearchHost: AnyObject {}
@MainActor protocol ToolTabsWindow: AnyObject {}

/// What was built and what was shut down, in order.
@MainActor
enum Journal {
    static var built: [String] = []
    static var shutdown: [String] = []
    static func reset() { built = []; shutdown = [] }
}

struct FileNode { let url: URL }
struct InsightSession { let id = UUID() }
struct GitHubRepo: Equatable { let slug: String }

@MainActor final class StandInFileTree {
    let timerBeats = PassthroughSubject<Void, Never>()
    var refreshes = 0
    var polling = PollingScheduler.app
    func refresh() { refreshes += 1 }
}

@MainActor final class ProjectContext: ObservableObject {
    let fileTree = StandInFileTree()
    var rootNode: FileNode?
    init() { Journal.built.append("project") }
    func close() { Journal.shutdown.append("project") }
}

@MainActor final class PanelLayout: ObservableObject { init() { Journal.built.append("layout") } }
@MainActor final class WindowUIState: ObservableObject { init() { Journal.built.append("windowUI") } }
@MainActor final class WindowChrome: ObservableObject { init() { Journal.built.append("chrome") } }
@MainActor final class WindowRequests: ObservableObject { init() { Journal.built.append("requests") } }
@MainActor final class WindowTheme: ObservableObject { init() { Journal.built.append("theme") } }
@MainActor final class AIToolJobs { init() { Journal.built.append("aiJobs") } }

enum TabsEvent {
    case saved(URL)
    case reloadedFromDisk
    case terminalClosed(UUID)
    case insightClosed(InsightSession)
}

@MainActor final class TabsController: ObservableObject {
    private let eventSubject = PassthroughSubject<TabsEvent, Never>()
    var events: AnyPublisher<TabsEvent, Never> { eventSubject.eraseToAnyPublisher() }
    var polling = PollingScheduler.app
    init() { Journal.built.append("tabs") }
    func emit(_ event: TabsEvent) { eventSubject.send(event) }
    func shutdown() { Journal.shutdown.append("tabs") }
}

@MainActor final class GitClient {
    var isGitRepo = false
    var isOperating = false
    var statusLooks = 0
    var looks = 0
    init() { Journal.built.append("gitClient") }
    func refreshStatus() async { statusLooks += 1 }
    func refresh() async { looks += 1 }
}

@MainActor final class ResearchMapController {
    let project: ProjectContext
    let tasks: TaskBag
    init(host: any ResearchHost, project: ProjectContext, tasks: TaskBag) {
        self.project = project; self.tasks = tasks
        Journal.built.append("research")
    }
}

@MainActor final class AITerminalsController {
    let host: any AITerminalsHost
    let project: ProjectContext
    let tasks: TaskBag
    let polling: PollingScheduler
    var closedTabTerminals: [UUID] = []
    init(host: any AITerminalsHost, project: ProjectContext, tasks: TaskBag, polling: PollingScheduler) {
        self.host = host; self.project = project; self.tasks = tasks; self.polling = polling
        Journal.built.append("terminals")
    }
    func closeTabTerminal(_ id: UUID) { closedTabTerminals.append(id) }
}

@MainActor final class FeatureStore { init() {} }

@MainActor final class GitHubStore: ObservableObject {
    @Published var selectedRepo: GitHubRepo?
}

@MainActor final class FeatureFlowCoordinator {
    let features = FeatureStore()
    let gitHub = GitHubStore()
    let terminals: AITerminalsController
    let research: ResearchMapController
    let tabs: any FeatureFlowTabs
    let gitClient: GitClient
    init(project: ProjectContext, assistants: AITerminalsController, tabs: any FeatureFlowTabs, requests: WindowRequests, layout: PanelLayout,
         chrome: WindowChrome, gitClient: GitClient, research: ResearchMapController) {
        self.terminals = assistants; self.tabs = tabs; self.gitClient = gitClient; self.research = research
        Journal.built.append("flow")
    }
    func close() { Journal.shutdown.append("flow") }
}

@MainActor final class FileOperationsController {
    let tabs: TabsController
    init(host: any FileOperationsHost, tabs: TabsController, project: ProjectContext, tasks: TaskBag) {
        self.tabs = tabs
        Journal.built.append("fileOperations")
    }
}

@MainActor final class DocumentTranslator {
    let tasks: TaskBag
    init(tabs: TabsController, project: ProjectContext, tasks: TaskBag) {
        self.tasks = tasks
        Journal.built.append("translator")
    }
}

@MainActor final class BrowserHost {
    let terminals: AITerminalsController
    let tabs: TabsController
    init(tabs: TabsController, layout: PanelLayout, chrome: WindowChrome, project: ProjectContext, terminals: AITerminalsController,
         window: any BrowserHostWindow) {
        self.tabs = tabs; self.terminals = terminals
        Journal.built.append("browser")
    }
    func close() { Journal.shutdown.append("browser") }
}

@MainActor final class ChangeReviewStore { var gitHubRepo: GitHubRepo? }

@MainActor final class ArchitectureStore {
    let review = ChangeReviewStore()
    var projectChanges = 0
    func noteProjectChanged() { projectChanges += 1 }
}

@MainActor final class CodeAndXRayCoordinator: ObservableObject {
    let architecture = ArchitectureStore()
    let project: ProjectContext
    init(project: ProjectContext, host: any CodeXRayHost) {
        self.project = project
        Journal.built.append("codeXRay")
    }
    func close() { Journal.shutdown.append("codeXRay") }
}

@MainActor final class InsightCoordinator {
    let tasks: TaskBag
    var closed: [UUID] = []
    init(host: any InsightHost, project: ProjectContext, tasks: TaskBag) {
        self.tasks = tasks
        Journal.built.append("insight")
    }
    func close(_ session: InsightSession) { closed.append(session.id) }
}

@MainActor final class ToolTabsRouter {
    let features: FeatureStore
    let terminals: AITerminalsController
    let tabs: TabsController
    init(window: any ToolTabsWindow, project: ProjectContext, tabs: TabsController, layout: PanelLayout, chrome: WindowChrome,
         requests: WindowRequests, features: FeatureStore, assistants: AITerminalsController) {
        self.tabs = tabs; self.features = features; self.terminals = assistants
        Journal.built.append("toolTabs")
    }
    func close() { Journal.shutdown.append("toolTabs") }
}

/// The window: it conforms to every narrow protocol its parts ask for, and does nothing else.
@MainActor final class StandInWindow: AITerminalsHost, BrowserHostWindow, CodeXRayHost, FeatureFlowTabs, FileOperationsHost, InsightHost,
                                     ResearchHost, ToolTabsWindow {}
