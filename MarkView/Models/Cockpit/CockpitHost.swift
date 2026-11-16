import AppKit
import Foundation

/// The Cockpit tool of a window: the window keeps one session for its project, so a tab closed and opened again shows the same plans
/// and runs; the session ends with the project it was made for. The host is also what the session sees of the window (`CockpitWindow`),
/// built from the window's parts, so the Cockpit holds no reference to the whole window.
@MainActor
final class CockpitHost: CockpitWindow {
    private weak var window: (any ToolTabsWindow)?
    private let tabs: TabsController
    private weak var tools: (any ToolOpening)?
    let qa: QAModel
    let features: FeatureStore
    let assistants: any AssistantProviding
    private var session: CockpitSession?

    init(window: any ToolTabsWindow, tabs: TabsController, tools: any ToolOpening, qa: QAModel, features: FeatureStore,
         assistants: any AssistantProviding) {
        self.window = window
        self.tabs = tabs
        self.tools = tools
        self.qa = qa
        self.features = features
        self.assistants = assistants
    }

    /// What opening the Cockpit does: the tab of this window's session (`ToolTabsRouter` shows the tab already open instead).
    var opener: ToolOpener {
        ToolOpener(makeTab: { [unowned self] root, tool in makeTab(root: root, tool: tool) })
    }

    /// The window lets go of its folder: the session ends for it.
    func projectClosed() {
        session?.closeProject()
        session = nil
    }

    private func makeTab(root: URL, tool: ToolDescriptor) -> OpenTab {
        var tab = OpenTab(url: tool.sentinelURL(in: root), content: "", originalContent: "")
        let current: CockpitSession
        if let existing = session, existing.root.standardizedFileURL == root.standardizedFileURL {
            current = existing
            if existing.execution?.isActive != true { existing.loadRuns() }
        } else {
            current = CockpitSession(root: root, workspace: self)
            session = current
        }
        tab.kind = .cockpit(current)
        return tab
    }

    // MARK: CockpitWindow

    var hostWindow: NSWindow? { window?.hostWindow }
    var activeTab: OpenTab? { tabs.activeTab }
    func openFile(_ url: URL) { window?.openFile(url) }
    func showAIConsole() { window?.showAIConsole() }
    func openTool(_ id: ToolID) { tools?.open(id) }
}
