import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The UI Studio tool of a window: builds the tab of a new session on the project's real web interface and gives the session what it
/// asks of the window (the unsaved editor text, the usage counter, files, the feature panel). The sessions live in their tabs; what the
/// host starts itself is owned by a `TaskBag` and ends with the window (`AR-19`).
@MainActor
final class UIStudioHost: StudioFeatureExportDelegate {
    private let project: any ProjectProviding
    private let tabs: TabsController
    private let features: FeatureStore
    private weak var window: (any ToolTabsWindow)?
    private let tasks = TaskBag()

    init(project: any ProjectProviding, tabs: TabsController, features: FeatureStore, window: any ToolTabsWindow) {
        self.project = project
        self.tabs = tabs
        self.features = features
        self.window = window
    }

    /// What opening UI Studio does: a new session in a new tab (`ToolTabsRouter` shows the one already open instead), started once added.
    var opener: ToolOpener {
        ToolOpener(
            makeTab: { [unowned self] root, tool in makeTab(root: root, tool: tool) },
            opened: { tab in if case .uiStudio(let session) = tab.kind { session.start() } })
    }

    /// The window closes: nothing the host started goes on.
    func close() { tasks.cancelAll() }

    /// The tab of a new UI Studio session on the project's real web interface (REQ-001).
    private func makeTab(root: URL, tool: ToolDescriptor) -> OpenTab {
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
        session.recordUsage = { [weak self] input, output, cost in self?.recordUsage(input, output, cost) }
        session.openFile = { [weak self] url in self?.window?.openFile(url) }
        session.featureStore = { [weak self] in self?.features }
        session.featureExportDelegate = self
        var tab = OpenTab(url: tool.sentinelURL(in: root, suffix: session.id.uuidString), content: "", originalContent: "")
        tab.kind = .uiStudio(session)
        return tab
    }

    func studioDidExportFeature(_ slug: String) { window?.showFeatureContext(slug) }

    /// Adds a session's tokens and cost to the project's usage counter; one task per record, owned until it is written.
    private func recordUsage(_ input: Int, _ output: Int, _ cost: Double) {
        guard let db = project.database else { return }
        let key = "usage-" + UUID().uuidString
        tasks.store(Task { [weak self] in
            await db.addUsage(inputTokens: input, outputTokens: output, costCents: cost * 100)
            self?.tasks.cancel(key: key)
        }, for: key)
    }
}
