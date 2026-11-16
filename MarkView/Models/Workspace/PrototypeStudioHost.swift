import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Prototype Studio in a window: the prototypes saved in the project, the creator sheet, and the tab of each prototype. A prototype's
/// build and review run in its own `PrototypeSession`, which its tab carries; the host only gives the session what it asks of the
/// window (the usage counter, the language of the labels it writes) and shows it.
@MainActor
final class PrototypeStudioHost {
    /// A prototype saved in the open project, for the lists in the menu and the creator sheet.
    struct SavedPrototype: Identifiable {
        let slug: String
        let title: String
        let version: Int
        let approved: Bool
        /// A reconstruction of existing code, saved before UI Studio replaced them: history, not the live interface.
        var historical = false
        var id: String { slug }
        /// "Support Desk · v3 · approved", "Admin · v2 · historical reconstruction"
        var label: String {
            "\(title) · v\(version)" + (approved ? " · approved" : "") + (historical ? " · historical reconstruction" : "")
        }
    }

    private let project: any ProjectProviding
    private let tabs: TabsController
    private let layout: PanelLayout
    private let chrome: WindowChrome
    private let requests: WindowRequests
    private weak var tools: (any ToolOpening)?

    init(project: any ProjectProviding, tabs: TabsController, layout: PanelLayout, chrome: WindowChrome, requests: WindowRequests,
         tools: any ToolOpening) {
        self.project = project
        self.tabs = tabs
        self.layout = layout
        self.chrome = chrome
        self.requests = requests
        self.tools = tools
    }

    /// Opens the creator sheet of Prototype Studio for requirements; `.code` ("New Prototype from Code…") opens UI Studio
    /// on the real application instead of generating a reconstruction (REQ-001).
    func openCreator(mode: PrototypeFiles.Mode) {
        guard mode == .requirements else { tools?.open(.uiStudio); return }
        requests.prototypeCreatorMode = mode
        requests.showPrototypeCreator = true
    }

    /// Prototypes saved in the open project, newest first.
    func saved() -> [SavedPrototype] {
        guard let root = project.root else { return [] }
        return PrototypeFiles.existingSlugs(root: root).compactMap { slug -> (SavedPrototype, Date)? in
            let folder = PrototypeFiles.folder(root: root, slug: slug)
            guard let manifest = PrototypeFiles.loadManifest(folder) else { return nil }
            let date = manifest.history.last?.date ?? .distantPast
            return (SavedPrototype(slug: slug, title: manifest.title, version: manifest.version, approved: manifest.approved,
                                   historical: manifest.mode == .code), date)
        }
        .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A new prototype from `sources` (project-relative files or folders) and the reviewer's brief; it builds at
    /// once. In `.code` mode the sources are existing code and `codeScope` lists the web apps detected in them,
    /// as hints for the planner.
    func create(title: String, brief: String, sources: [String], mode: PrototypeFiles.Mode = .requirements,
                codeScope: PrototypeAI.CodeScope = PrototypeAI.CodeScope()) {
        // Existing code is not reconstructed any more: it opens in UI Studio (DEC-002, DEC-005).
        guard mode == .requirements else { tools?.open(.uiStudio); return }
        guard let root = project.root else { return }
        let session = PrototypeSession(root: root, title: title, brief: brief, sources: sources, mode: mode)
        session.codeScope = codeScope
        show(session)
    }

    /// Opens a saved prototype, or returns to its tab.
    func openSaved(_ slug: String) {
        guard let root = project.root else { return }
        for index in tabs.openTabs.indices {
            if case .prototype(let session) = tabs.openTabs[index].kind, session.manifest.slug == slug {
                tabs.activeTabIndex = index
                return
            }
        }
        if let session = PrototypeSession(root: root, slug: slug) { show(session) }
    }

    private func show(_ session: PrototypeSession) {
        session.record = { [weak self] result in result.record(in: self?.project.database) }
        session.languageNote = ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage
            ? "" : "\n\nWrite every label, text and message in the prototype in \(ActionOutputLanguage.current)."
        var tab = OpenTab(url: session.folder.appendingPathComponent(ProjectPaths.placeholderName("prototype-" + session.id.uuidString)),
                          content: "", originalContent: "")
        tab.kind = .prototype(session)
        layout.workspaceArea = .files
        chrome.showCenter = true
        tabs.appendTab(tab, activate: true)
    }
}
