import AppKit
import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the parts of a window ask of the window itself: each part holds only its own narrow protocol, and the window (the
/// `WorkspaceManager`) conforms to all of them.
typealias WindowHost = AITerminalsHost & BrowserHostWindow & CodeXRayHost & FeatureFlowTabs & FileOperationsHost & InsightHost
    & ResearchHost & ToolTabsWindow

/// Everything one window is made of, built in one place (`AR-17`). A part takes what it needs at construction: the other parts it works
/// with, and `host`, the window, through its own narrow protocol. Nothing is wired afterwards by assigning a closure or a back-reference.
///
/// The parts that react to each other's events are connected once, by `connect()`: a saved file refreshes the code analysis, a closed
/// terminal tab ends its shell, the GitHub repository of the flow reaches the X-Ray. `close()` is the window's ordered shutdown.
///
/// A window that shows no folder pays for the parts only when a view or a command first uses them (`lazy`).
@MainActor
final class WindowComposition {
    /// The open project: its folder and tree, linked and excluded folders, search database, index and recents.
    let project: ProjectContext
    /// Which tab each panel of the window shows; never shared with other windows (BUG-004).
    let layout = PanelLayout()
    /// Everything else the window shows of itself (expanded sections, widths, panel modes); never shared with other windows.
    let windowUI = WindowUIState()
    /// The panels of the window that are shown.
    let chrome = WindowChrome()
    /// What the window was asked to show in a sheet, popover or alert.
    let requests = WindowRequests()
    /// The theme of the window; a change here leaves every other window alone.
    let theme = WindowTheme()
    /// The tabs of the window.
    let tabs: TabsController
    /// Keyed cancellable background tasks owned by the window (`AR-19`).
    let taskBag = TaskBag()
    /// The polls of the window run while the app is active and the window is on screen (`AR-19`); closing the window ends them.
    let polling = PollingScheduler()
    /// AI tool runs working in a headless agent (diagrams, code map, review, audit).
    let aiJobs = AIToolJobs()
    /// The Git state of the window.
    let gitClient = GitClient()

    private unowned let host: any WindowHost
    /// How the parts of the window ask the person; the app gives it to the window (`AR-22`).
    private let prompts: any UserPrompts
    private var connections = Set<AnyCancellable>()

    /// Research of the window: the maps, and the jobs for new research, follow-ups and comments (docs/research/).
    private(set) lazy var research = ResearchMapController(host: host, project: project, tasks: taskBag)
    /// The terminals of the window: the AI panel's, the editor tabs', the AI terminals that come back across launches, and what the
    /// assistants are doing.
    private(set) lazy var terminals = AITerminalsController(host: host, project: project, tasks: taskBag, polling: polling, prompts: prompts)
    /// The feature flow: the feature workspaces and the GitHub repository of the folder, intake, "Implement with AI" and "Fix with AI",
    /// and the bug basket.
    private(set) lazy var flow = FeatureFlowCoordinator(project: project, assistants: terminals, tabs: host, requests: requests,
                                                        layout: layout, chrome: chrome, gitClient: gitClient, research: research)
    /// Creates, renames, moves, copies and trashes the files of the project, with the tabs that follow or close.
    private(set) lazy var fileOperations = FileOperationsController(host: host, tabs: tabs, project: project, tasks: taskBag)
    /// Translates documents into another language and opens the result in a new tab.
    private(set) lazy var translator = DocumentTranslator(tabs: tabs, project: project, tasks: taskBag)
    /// The browser of the window: its tabs, what agents drive of them, Preview Web App and the picked page element.
    private(set) lazy var browser = BrowserHost(tabs: tabs, layout: layout, chrome: chrome, project: project, terminals: terminals, window: host, prompts: prompts)
    /// Code explanations, code navigation, the X-Ray tabs and the AI actions on selected text.
    private(set) lazy var codeXRay = CodeAndXRayCoordinator(project: project, host: host, prompts: prompts)
    /// Recursive Insight of the window: its graph engine runs over the project's database.
    private(set) lazy var insight = InsightCoordinator(host: host, project: project, tasks: taskBag, prompts: prompts)
    /// The tools of the window: the tab of each tool of `ToolRegistry`, and the stores that need the project.
    private(set) lazy var toolTabs = ToolTabsRouter(window: host, project: project, tabs: tabs, layout: layout, chrome: chrome,
                                                    requests: requests, features: flow.features, assistants: terminals)

    /// Builds the plain parts. The other parts are made when first used, and `connect()` joins them; both come after the host is ready to
    /// answer, which is why the host's own init does not call them.
    init(host: any WindowHost, prompts: any UserPrompts, recentFilesURL: URL? = nil) {
        self.host = host
        self.prompts = prompts
        project = ProjectContext(prompts: prompts, recentFilesURL: recentFilesURL)
        tabs = TabsController(prompts: prompts)
    }

    /// Anything the window shows about its project or its code analysis changed (the window redraws what observes it).
    var changes: AnyPublisher<Void, Never> {
        project.objectWillChange.merge(with: codeXRay.objectWillChange).map { _ in () }.eraseToAnyPublisher()
    }

    /// Anything the saved session records changed in the parts the views observe on their own: the tabs, the panels, the theme and the
    /// interface state.
    var sessionChanges: AnyPublisher<Void, Never> {
        tabs.objectWillChange.merge(with: layout.objectWillChange, chrome.objectWillChange, theme.objectWillChange, windowUI.objectWillChange)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// Joins the parts that react to each other's events. Called once, after the host is built.
    func connect() {
        project.fileTree.polling = polling
        tabs.polling = polling
        // The X-Ray of the window follows the repository the GitHub integration works with (the PR X-Ray reads it).
        flow.gitHub.$selectedRepo
            .sink { [weak self] repo in self?.codeXRay.architecture.review.gitHubRepo = repo }
            .store(in: &connections)
        // The Git status changes without the top folder changing: look at it on every beat of the file watcher while the app is in front.
        project.fileTree.timerBeats
            .sink { [weak self] in
                guard let self, self.gitClient.isGitRepo, !self.gitClient.isOperating, NSApp.isActive else { return }
                self.taskBag.store(Task { await self.gitClient.refreshStatus() }, for: "git-status")
            }
            .store(in: &connections)
        tabs.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .saved(let url):
                    // A file saved inside the project is a change the automatic code analysis refreshes
                    // from (REQ-002), at once rather than after the change watcher's latency.
                    if let root = self.project.rootNode?.url.standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") {
                        self.codeXRay.architecture.noteProjectChanged()
                    }
                case .reloadedFromDisk:
                    self.project.fileTree.refresh()
                case .terminalClosed(let id):
                    self.terminals.closeTabTerminal(id)
                case .insightClosed(let session):
                    self.insight.close(session)
                }
            }
            .store(in: &connections)
        // Edits made outside MarkView (an agent, a terminal) change the status: look again when the app comes back to the front.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.gitClient.isGitRepo, !self.gitClient.isOperating else { return }
                self.taskBag.store(Task { await self.gitClient.refresh() }, for: "git-refresh")
            }
            .store(in: &connections)
    }

    /// The window closes: everything it started stops, in an order that lets each part finish what it owes the next.
    func close() {
        // UI Studio sessions stop the development servers they started (REQ-006); the tabs' background work ends.
        tabs.shutdown()
        // The project's index process, file watcher and background jobs end with its window (AR-19), and so do the window's polls.
        project.close()
        polling.stopAll()
        // So do the code analysis, the X-Ray scans and the AI answers about code that it started.
        codeXRay.close()
        // And the feature flow's: the GitHub setting is no longer watched and its tasks stop.
        flow.close()
        // And the browser's: the look for a web app and the wait for a dev server stop.
        browser.close()
        // The answers and records the tools started (Discussions, UI Studio) stop too.
        toolTabs.close()
        // So do the looks and the operations of the Git client.
        gitClient.close()
        // What the window's own commands started (the folder's setup, wikilinks, translations) ends with it.
        taskBag.cancelAll()
        connections.removeAll()
    }
}
