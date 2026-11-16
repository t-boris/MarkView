import Foundation

/// What a window offers so that its session can be saved and restored (`AR-14` step 7). The snapshotter reaches the window's own
/// parts (tabs, panels, layout, interface state) directly; what only the window can open (a folder, a terminal, a browser, an
/// architecture view, a tool) goes through the calls below.
@MainActor
protocol WindowSessionHost: AnyObject {
    var tabs: TabsController { get }
    var chrome: WindowChrome { get }
    var layout: PanelLayout { get }
    var windowUI: WindowUIState { get }
    var themeSettings: WindowThemeSettings { get }
    /// The folder the window has open, if any.
    var windowFolder: URL? { get }
    /// The folder of the terminal tab `id`; nil once that terminal is gone.
    func terminalDirectory(for id: UUID) -> URL?
    /// Opens `url`; `completion` runs when its tree has loaded.
    func openFolder(_ url: URL, completion: (() -> Void)?)
    func openTool(_ tool: ToolID)
    func openFile(_ url: URL)
    func openGitHubTab(_ item: GitHubItem)
    /// Reopens an architecture view from its cache, without scanning or reviewing anything.
    func restoreArchitectureTab(scope: String)
    func restoreTerminal(in directory: URL)
    func restoreBrowser(_ url: URL)
}

/// Takes a window's session (`WorkspaceWindowState`) and puts it back: the folder, the tabs with their unsaved drafts and scroll
/// positions, the active tab, the panels and the interface state. The saved form is the one `WindowSessionStorage` writes; what the
/// window cannot show again (an in-memory Insight job, a live UI Studio session, a file that is gone) is left out.
@MainActor
enum WindowSessionSnapshotter {
    static func snapshot(of host: WindowSessionHost, id: UUID) -> WorkspaceWindowState {
        let tabs = host.tabs
        var state = WorkspaceWindowState(id: id, folder: host.windowFolder)
        state.theme = host.themeSettings
        state.uiState = host.windowUI.saved
        for (index, tab) in tabs.openTabs.enumerated() {
            let saved: WorkspaceTabState
            switch tab.kind {
            case .file:
                let draft = tab.isModified ? WorkspaceDraft(content: tab.content, original: tab.originalContent) : nil
                let currentScroll = tabs.scroll.scrollPosition(for: tab.id)
                saved = .file(url: tab.url, draft: draft, notes: tab.notesView, scroll: Double(currentScroll))
            case .image: saved = .image(tab.url)
            case .pdf: saved = .pdf(tab.url)
            case .archive: saved = .archive(tab.url)
            case .data: saved = .data(tab.url)
            case .github(let item): saved = .github(item)
            case .architecture(let scope): saved = .architecture(scope)
            case .terminal(let terminalID):
                guard let directory = host.terminalDirectory(for: terminalID) else { continue }
                saved = .terminal(directory)
            case .browser(let session):
                guard let url = session.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                saved = .browser(url)
            case .insight: continue // in-memory jobs have their own export workflow
            case .prototype: continue // reopened from AI Tools → Prototype
            case .tool, .uiStudio, .cockpit:
                // A tool tab is saved when its descriptor says so; UI Studio (a live session with a development server) and the
                // Cockpit are opened again from the View menu or the toolbar.
                guard let tool = tab.kind.toolID, ToolRegistry.shared.isRestorable(tool) else { continue }
                saved = .tool(tool)
            }
            if index == tabs.activeTabIndex { state.activeTabIndex = state.tabs.count }
            state.tabs.append(saved)
        }
        var panels = WorkspacePanelState(workspaceArea: host.layout.workspaceArea.rawValue,
            workSection: host.layout.workSection.rawValue,
            navigator: host.layout.navigatorTab.rawValue, left: host.layout.leftPanel,
            feature: host.layout.issuesFeature, git: host.layout.gitSection.rawValue, stage: host.layout.featureStage.rawValue,
            showFiles: false, showNavigator: false, welcomeBackdrop: host.layout.welcomeBackdrop.rawValue)
        host.chrome.save(into: &panels)
        state.panels = panels
        return state
    }

    static func restore(_ state: WorkspaceWindowState, into host: WindowSessionHost) async {
        host.windowUI.restore(state.uiState)
        let tabs = host.tabs
        let fm = FileManager.default
        if let folder = state.folder, folder.isFileURL,
           (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            await withCheckedContinuation { continuation in
                host.openFolder(folder) { continuation.resume() }
            }
            // A folder chosen meanwhile wins over the old session.
            guard host.windowFolder == folder else { return }
        }
        var selected: Int?
        for (savedIndex, saved) in state.tabs.enumerated() {
            let before = tabs.openTabs.count
            switch saved {
            case .file(let url, let draft, let notes, let scroll):
                guard url.isFileURL else { continue }
                if fm.fileExists(atPath: url.path) { await tabs.openTextFile(url) }
                if tabs.openTabs.count == before, let draft {
                    // A removed file must not take the unsaved editor text with it.
                    var tab = OpenTab(url: url, content: draft.content, originalContent: draft.original)
                    tab.headings = TabsController.headings(in: draft.content)
                    tabs.appendTab(tab)
                }
                guard tabs.openTabs.count > before else { continue }
                let restoredScroll: CGFloat = scroll.isFinite ? CGFloat(max(0, scroll)) : 0
                tabs.updateTab(at: before) { tab in
                    if let draft {
                        tab.content = draft.content
                        tab.isModified = draft.content != tab.originalContent
                        tab.headings = TabsController.headings(in: draft.content)
                    }
                    tab.notesView = notes
                }
                tabs.scroll.setScrollPosition(restoredScroll, for: tabs.openTabs[before].id)
            case .tool(let tool):
                if ToolRegistry.shared.isRestorable(tool) { host.openTool(tool) }
            case .image(let url), .pdf(let url), .data(let url), .archive(let url):
                if url.isFileURL, fm.fileExists(atPath: url.path) { host.openFile(url) }
            case .github(let item): host.openGitHubTab(item)
            case .architecture(let scope): host.restoreArchitectureTab(scope: scope)
            case .terminal(let directory):
                if directory.isFileURL, (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    host.restoreTerminal(in: directory)
                }
            case .browser(let url):
                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { host.restoreBrowser(url) }
            }
            if savedIndex == state.activeTabIndex, tabs.openTabs.count > before { selected = before }
        }
        tabs.activeTabIndex = state.activeTabIndex == -1 ? -1 : (selected ?? (tabs.openTabs.isEmpty ? -1 : 0))
        if let panels = state.panels {
            let layout = host.layout
            layout.workspaceArea = panels.workspaceArea.flatMap(WorkspaceArea.init) ?? .files
            let restoredWorkSection = panels.workSection.flatMap(WorkSection.init) ?? .features
            layout.workSection = restoredWorkSection == .terminal ? .features : restoredWorkSection
            let restoredNavigator = NavigatorTab(rawValue: panels.navigator) ?? .contents
            layout.navigatorTab = [.terminal, .git, .search].contains(restoredNavigator) ? .contents : restoredNavigator
            layout.leftPanel = panels.left == "issues" ? "issues" : "files"
            layout.issuesFeature = panels.feature
            layout.gitSection = GitSection(rawValue: panels.git) ?? .changes
            layout.featureStage = FeatureStage.stored(panels.stage)
            // A session saved before BUG-120 has none: the window keeps the starting choice it was created with.
            if let backdrop = panels.welcomeBackdrop { layout.welcomeBackdrop = WelcomeBackdrop.stored(backdrop) }
            host.chrome.restore(panels)
        }
    }
}
