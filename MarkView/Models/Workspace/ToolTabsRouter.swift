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

/// Opens the tabs of the tools of `ToolRegistry` in one window (`AR-14` step 10, `AR-31`): the tool's tab is shown, or built once, and
/// the tool's own store is wired to the project the window has open. The router owns the objects of the tools that have state or
/// behaviour of their own (`DeploymentsHost`, `DiscussionsHost`, the studios), builds the ones that are not always needed on first
/// use, and tells them when the folder opens or closes and when the window ends. The window holds the router and no tool of its own.
/// A new tool is one `ToolDescriptor`, one view in `ToolTabViews` and, when it needs wiring, one entry of `opener(for:)`.
@MainActor
final class ToolTabsRouter: ToolOpening {
    private unowned let window: any ToolTabsWindow
    private let project: any ProjectProviding
    private let tabs: TabsController
    private let layout: PanelLayout
    private let chrome: WindowChrome
    private let requests: WindowRequests
    let features: FeatureStore
    private let terminals: any AssistantProviding & AssistantPrompting

    /// Where the project runs and how each place is doing (the Deployments tab), and the assistant questions about it.
    private(set) lazy var deployments = DeploymentsHost(project: project, assistants: terminals, tabs: self)
    /// Questions asked before there is a feature, answered as pages (the Discussions tab).
    private(set) lazy var discussions = DiscussionsHost(project: project, tabs: self)
    /// The state of the Workflow tab: the draft being edited survives a switch to another tab.
    let workflowEditor = WorkflowEditorModel()
    /// End-to-End QA: the scenarios of the project and the one being edited.
    let qa = QAModel()
    private(set) lazy var uiStudio = UIStudioHost(project: project, tabs: tabs, features: features, window: window)
    private lazy var cockpit = CockpitHost(window: window, tabs: tabs, tools: self, qa: qa, features: features, assistants: terminals)
    /// The prototypes of the project and the creator sheet (Prototype Studio).
    private(set) lazy var prototypes = PrototypeStudioHost(project: project, tabs: tabs, layout: layout, chrome: chrome, requests: requests, tools: self)

    init(window: any ToolTabsWindow, project: any ProjectProviding, tabs: TabsController, layout: PanelLayout, chrome: WindowChrome,
         requests: WindowRequests, features: FeatureStore, assistants: any AssistantProviding & AssistantPrompting) {
        self.window = window
        self.project = project
        self.tabs = tabs
        self.layout = layout
        self.chrome = chrome
        self.requests = requests
        self.features = features
        self.terminals = assistants
        qa.assistants = assistants
    }

    /// What opening the tool does beyond showing its tab. Every tool of the registry that is not listed opens as a plain `.tool` tab.
    private func opener(for id: ToolID) -> ToolOpener {
        switch id {
        case .deployments: return deployments.opener
        case .discussions: return discussions.opener
        case .workflow: return ToolOpener(prepare: { [unowned self] _ in window.hostWindow?.makeKeyAndOrderFront(nil) })
        case .qa:
            return ToolOpener(prepare: { [unowned self] root in
                window.hostWindow?.makeKeyAndOrderFront(nil)
                qa.attach(root: root)
                if qa.run.bugFiler == nil { qa.run.bugFiler = QABugFiler(sink: QAFeatureStoreBugSink(store: features)) }
                qa.archive.bugFiler = qa.run.bugFiler
            })
        case .uiStudio: return uiStudio.opener
        case .cockpit: return cockpit.opener
        default: return ToolOpener()
        }
    }

    /// Opens the tab of a tool, or returns to it: a tool has one tab per window.
    func open(_ id: ToolID) {
        guard let root = project.root, let tool = ToolRegistry.shared.descriptor(for: id) else { return }
        let opener = opener(for: id)
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
        deployments.projectOpened(root)
        discussions.projectOpened(root)
    }

    /// The window lets go of its folder: the stores forget it and the Cockpit ends its session for it.
    func projectClosed() {
        cockpit.projectClosed()
        deployments.projectClosed()
        discussions.projectClosed()
    }

    /// The window closes: the answers and records the tools started stop with it.
    func close() {
        discussions.close()
        uiStudio.close()
    }
}
