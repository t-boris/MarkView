import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the tools' tabs need of the window beyond its parts: the window itself, a file opened the way the window opens files, and the
/// feature panel shown beside a document. `WorkspaceManager` is the one implementation.
@MainActor
protocol ToolTabsWindow: AnyObject {
    /// The window this workspace is shown in; nil before its view has one.
    var hostWindow: NSWindow? { get }
    func openFile(_ url: URL)
    func showFeatureContext(_ slug: String?)
    func showAIConsole()
}

/// What opening a tool does beyond showing its tab: wiring the tool's own store to the project, or building the tab of a tool that
/// carries a session. A tool that needs neither has no entry in the router's table; `ToolRegistry` describes the rest of it.
struct ToolOpener {
    /// Runs on every open, also when the tool's tab exists already.
    var prepare: (URL) -> Void = { _ in }
    /// The tab of a tool that carries a session; every other tool gets a plain `.tool` tab.
    var makeTab: ((URL, ToolDescriptor) -> OpenTab)?
    /// Runs once, after a tab built by `makeTab` was added.
    var opened: (OpenTab) -> Void = { _ in }
}

/// Opens the tabs of the tools of `ToolRegistry` in one window (`AR-14` step 10, `AR-31`): the tool's tab is shown, or built once, and
/// the tool's own store is wired to the project the window has open. The router owns the stores of the tools that have one; the
/// window holds the router and no tool of its own. A new tool is one `ToolDescriptor`, one view in `ToolTabViews` and, when its store
/// needs wiring, one entry in `openers`.
@MainActor
final class ToolTabsRouter {
    weak var window: (any ToolTabsWindow)?
    private let project: any ProjectProviding
    private let tabs: TabsController
    private let layout: PanelLayout
    private let chrome: WindowChrome
    let features: FeatureStore
    let assistants: any AssistantProviding

    /// Where the project runs and how each place is doing (the Deployments tab).
    let deployments = DeploymentStore()
    /// Answers to questions about an environment, read from state and logs by the project's own assistant.
    let deploymentAdvisor = DeploymentAdvisor()
    /// The state of the Workflow tab: the draft being edited survives a switch to another tab.
    let workflowEditor = WorkflowEditorModel()
    /// End-to-End QA: the scenarios of the project and the one being edited.
    let qa = QAModel()
    /// Questions asked before there is a feature, answered as pages (the Discussions tab).
    let discussions = DiscussionStore()
    /// The Cockpit of this window: one session for its project, so a tab closed and opened again shows the same plans and runs.
    private var cockpitSession: CockpitSession?

    init(project: any ProjectProviding, tabs: TabsController, layout: PanelLayout, chrome: WindowChrome,
         features: FeatureStore, assistants: any AssistantProviding) {
        self.project = project
        self.tabs = tabs
        self.layout = layout
        self.chrome = chrome
        self.features = features
        self.assistants = assistants
        qa.assistants = assistants
    }

    /// The tools that need more than a plain tab. Every other tool of the registry opens as a plain `.tool` tab.
    private lazy var openers: [ToolID: ToolOpener] = [
        .deployments: ToolOpener(prepare: { [unowned self] root in
            deployments.setRoot(root)
            deployments.onNeedsAttention = { [weak self] in self?.open(.deployments) }
        }),
        .discussions: ToolOpener(prepare: { [unowned self] root in discussions.setRoot(root) }),
        .workflow: ToolOpener(prepare: { [unowned self] _ in window?.hostWindow?.makeKeyAndOrderFront(nil) }),
        .qa: ToolOpener(prepare: { [unowned self] root in
            window?.hostWindow?.makeKeyAndOrderFront(nil)
            qa.attach(root: root)
            if qa.run.bugFiler == nil { qa.run.bugFiler = QABugFiler(sink: QAFeatureStoreBugSink(store: features)) }
            qa.archive.bugFiler = qa.run.bugFiler
        }),
        .uiStudio: ToolOpener(
            makeTab: { [unowned self] root, tool in makeUIStudioTab(root: root, tool: tool) },
            opened: { tab in if case .uiStudio(let session) = tab.kind { session.start() } }),
        .cockpit: ToolOpener(makeTab: { [unowned self] root, tool in makeCockpitTab(root: root, tool: tool) })
    ]

    /// Opens the tab of a tool, or returns to it: a tool has one tab per window.
    func open(_ id: ToolID) {
        guard let root = project.root, let tool = ToolRegistry.shared.descriptor(for: id) else { return }
        let opener = openers[id] ?? ToolOpener()
        opener.prepare(root)
        layout.workspaceArea = .files
        chrome.showCenter = true
        if let index = tabs.openTabs.firstIndex(where: { $0.kind.toolID == id }) {
            tabs.activeTabIndex = index
            return
        }
        let tab: OpenTab
        if let makeTab = opener.makeTab {
            tab = makeTab(root, tool)
        } else {
            var plain = OpenTab(url: tool.sentinelURL(in: root), content: "", originalContent: "")
            plain.kind = .tool(id)
            tab = plain
        }
        tabs.appendTab(tab, activate: true)
        opener.opened(tab)
    }

    /// The folder finished opening: the stores that read it start over it, also when the tool's tab was never opened (agents use them).
    func projectOpened(_ root: URL) {
        deployments.setRoot(root)
        discussions.setRoot(root)
    }

    /// The window lets go of its folder: the stores forget it and the Cockpit ends its session for it.
    func projectClosed() {
        cockpitSession?.closeProject()
        cockpitSession = nil
        deployments.setRoot(nil)
        discussions.setRoot(nil)
    }

    // MARK: - Tabs that carry a session

    /// The tab of a new UI Studio session on the project's real web interface (REQ-001); `open` shows the session already open instead.
    private func makeUIStudioTab(root: URL, tool: ToolDescriptor) -> OpenTab {
        let session = StudioSession(root: root)
        let base = root.standardizedFileURL.path + "/"
        session.editorBuffers = { [weak self] in
            var buffers: [String: String] = [:]
            for tab in self?.tabs.openTabs ?? [] where tab.isFileBacked && tab.isModified {
                let path = tab.url.standardizedFileURL.path
                if path.hasPrefix(base) { buffers[String(path.dropFirst(base.count))] = tab.content }
            }
            return buffers
        }
        session.recordUsage = { [weak self] input, output, cost in
            guard let db = self?.project.database else { return }
            Task { await db.addUsage(inputTokens: input, outputTokens: output, costCents: cost * 100) }
        }
        session.openFile = { [weak self] url in self?.window?.openFile(url) }
        session.featureStore = { [weak self] in self?.features }
        session.onFeatureExported = { [weak self] slug in self?.window?.showFeatureContext(slug) }
        var tab = OpenTab(url: tool.sentinelURL(in: root, suffix: session.id.uuidString), content: "", originalContent: "")
        tab.kind = .uiStudio(session)
        return tab
    }

    /// The tab of the Cockpit of this window: the window keeps one session for its project, so a tab closed and opened again shows
    /// the same plans and runs (`open` shows the tab already open instead).
    private func makeCockpitTab(root: URL, tool: ToolDescriptor) -> OpenTab {
        var tab = OpenTab(url: tool.sentinelURL(in: root), content: "", originalContent: "")
        let session: CockpitSession
        if let existing = cockpitSession, existing.root.standardizedFileURL == root.standardizedFileURL {
            session = existing
            if existing.execution?.isActive != true { existing.loadRuns() }
        } else {
            session = CockpitSession(root: root, workspace: self)
            cockpitSession = session
        }
        tab.kind = .cockpit(session)
        return tab
    }
}

/// What the Cockpit reads of the window and does to it, from the window's parts and tools.
extension ToolTabsRouter: CockpitWindow {
    var hostWindow: NSWindow? { window?.hostWindow }
    var activeTab: OpenTab? { tabs.activeTab }
    func openFile(_ url: URL) { window?.openFile(url) }
    func showAIConsole() { window?.showAIConsole() }
    func openTool(_ id: ToolID) { open(id) }
}
