import Foundation
import SwiftUI
import Combine
import UniformTypeIdentifiers
import os
#if canImport(MarkViewCore)
import MarkViewCore
#endif

enum WorkspaceAITool: String {
    case architecture
    case dataflow
    case pipeline
    case deployment
    case sequence
    case er
    case critic
    case audit
    case codemap

    var opensGraphCreator: Bool {
        switch self {
        case .architecture, .dataflow, .pipeline, .deployment, .sequence, .er:
            return true
        case .critic, .audit, .codemap:
            return false
        }
    }
}

/// Manages the workspace state including open files, tabs, and folder structure
@MainActor
class WorkspaceManager: ObservableObject, TabsProviding, FeatureFlowTabs, WindowSessionHost, ToolTabsWindow {
    /// The open project: its folder and tree, linked and excluded folders, search database, index and recents (`AR-14` step 8).
    let project = ProjectContext()
    /// Which tab each panel of this window shows; never shared with other windows (BUG-004).
    let layout = PanelLayout()
    /// Everything else this window shows of itself (expanded sections, widths, panel modes); never shared with other windows.
    let windowUI = WindowUIState()
    /// The panels of this window that are shown. Views that draw or toggle them observe this object, not the manager (`AR-14`).
    let chrome = WindowChrome()
    /// What this window was asked to show in a sheet, popover or alert; never shared with other windows (`AR-14`).
    let requests = WindowRequests()
    /// The theme of this window; a change here leaves every other window alone.
    let theme = WindowTheme()
    /// The tabs of this window. Views that show them observe this object, not the manager (`AR-15`).
    let tabs = TabsController()
    /// Keyed cancellable background task bag owned by this window (`AR-19`).
    let taskBag = TaskBag()
    /// The polls of this window run while the app is active and this window is on screen (`AR-19`); closing the window ends them.
    let polling = PollingScheduler()
    /// AI tool runs working in a headless agent (diagrams, code map, review, audit).
    let aiJobs = AIToolJobs()

    // MARK: - Tool tabs

    /// The tools of this window: the tab of each tool of `ToolRegistry`, and the stores that need wiring to the project (`AR-14` step 10).
    private(set) lazy var toolTabs = ToolTabsRouter(window: self, project: project, tabs: tabs, layout: layout, chrome: chrome,
                                                    requests: requests, features: flow.features, assistants: terminals)

    /// Opens the tab of a tool of `ToolRegistry`, or returns to it.
    func openTool(_ id: ToolID) { toolTabs.open(id) }

    /// The project's operations, with this window as the one that shows what the person starts from here.
    func operations() -> ProjectOperationsStore? {
        projectOperations?.presenter = self
        return projectOperations
    }

    /// Dismisses a finished run of the store, and moves this window's selection and console on when it was the one shown.
    func dismissOperationRun(id: String) {
        guard let store = projectOperations else { return }
        store.dismiss(id: id)
        if requests.operationSelectedRunID == id { requests.operationSelectedRunID = store.runs.keys.sorted().first }
        if store.runs.isEmpty { requests.operationConsoleVisible = false }
    }


    /// Files opened from outside the app on their own (Finder, Quick Action): the documents, nothing around them.
    func openDocumentsOnly(_ urls: [URL]) {
        for url in urls { openFile(url) }
        chrome.showDocumentOnly()
    }

    func presentPDFBook(_ urls: [URL]? = nil) {
        let sources: [URL]
        if let urls { sources = urls }
        else if openTabs.indices.contains(activeTabIndex), case .file = openTabs[activeTabIndex].kind { sources = [openTabs[activeTabIndex].url] }
        else { sources = [] }
        requests.pdfBookSelection = BookPDFSelection(urls: sources)
    }

    var pdfBookDrafts: [String: String] {
        var result: [String: String] = [:]
        for tab in openTabs where tab.isModified { if case .file = tab.kind { result[tab.url.path] = tab.content } }
        return result
    }
    /// The Git state of this window. Views that show it observe this object, not the manager (`AR-15`).
    let gitClient = GitClient()
    /// Research of this window: the maps, and the jobs for new research, follow-ups and comments (docs/research/).
    private(set) lazy var research = ResearchMapController(host: self, project: project, tasks: taskBag)
    /// The feature flow: the feature workspaces and the GitHub repository of the folder, intake, "Implement with AI" and "Fix with AI",
    /// and the bug basket (`AR-14` step 9).
    private(set) lazy var flow = FeatureFlowCoordinator(project: project, assistants: terminals, tabs: self, requests: requests, layout: layout,
                                                        chrome: chrome, gitClient: gitClient, research: research)
    /// Creates, renames, moves, copies and trashes the files of the project, with the tabs that follow or close (`AR-14` step 2).
    private(set) lazy var fileOperations = FileOperationsController(host: self, tabs: tabs, project: project)
    /// Translates documents into another language and opens the result in a new tab (`AR-14` step 1).
    private(set) lazy var translator = DocumentTranslator(tabs: tabs, project: project, tasks: taskBag)
    /// The terminals of this window: the AI panel's, the editor tabs', the AI terminals that come back across launches, and what the
    /// assistants are doing.
    private(set) lazy var terminals = AITerminalsController(host: self, project: project, tasks: taskBag, polling: polling)
    /// The browser of this window: its tabs, what agents drive of them, Preview Web App and the picked page element (`AR-14` step 9).
    private(set) lazy var browser = BrowserHost(tabs: tabs, layout: layout, chrome: chrome, project: project, terminals: terminals, window: self)
    /// Code explanations, code navigation, the X-Ray tabs and the AI actions on selected text (`AR-14` step 11).
    let codeXRay: CodeAndXRayCoordinator
    /// Team-shared operation definitions and the process registry for this workspace root.
    @Published private(set) var projectOperations: ProjectOperationsStore?
    /// Recursive Insight of this window (`AR-14`): its graph engine runs over the project's database.
    private(set) lazy var insight = InsightCoordinator(host: self, project: project, tasks: taskBag)
    private var cancellables: Set<AnyCancellable> = []

    // The project is read through `project` (`ProjectProviding`). These four read-only aliases stay for the code of the regions
    // that the other decompositions of this file (`AR-14` steps 2-7) are still moving out, and go with them.
    var rootNode: FileNode? { project.rootNode }
    var projectFolder: URL? { project.projectFolder }
    var aiProject: URL? { project.aiProject }
    var semanticDatabase: SemanticDatabase? { project.database }

    /// The tabs of this window for the code that is not a view. A view that shows tabs observes `tabs` itself: reading them
    /// through the manager would not redraw it (`AR-15`).
    var openTabs: [OpenTab] { tabs.openTabs }

    var activeTabIndex: Int {
        get { tabs.activeTabIndex }
        set { tabs.activeTabIndex = newValue }
    }

    var activeTab: OpenTab? { tabs.activeTab }

    func showGitHubTab(_ item: GitHubItem, root: URL) { tabs.showGitHubTab(item, root: root) }

    /// `ToolTabsWindow`: the feature panel shown beside a document.
    func showFeatureContext(_ slug: String?) { flow.showFeatureContext(slug) }

    /// `WindowSessionHost`: a restored session shows the GitHub tab again.
    func openGitHubTab(_ item: GitHubItem) { flow.openGitHubTab(item) }

    func reloadChangedOpenFiles(all: Bool) async { await tabs.reloadChangedOpenFiles(all: all) }

    init() {
        Self.debugLog("WorkspaceManager init START")
        codeXRay = CodeAndXRayCoordinator(project: project)
        codeXRay.host = self
        // The X-Ray of this window follows the repository the GitHub integration works with (the PR X-Ray reads it).
        flow.gitHub.$selectedRepo
            .sink { [weak self] repo in self?.codeXRay.architecture.review.gitHubRepo = repo }
            .store(in: &cancellables)

        project.fileTree.polling = polling
        tabs.polling = polling
        project.fileTree.onTimer = { [weak self] in
            guard let self, self.gitClient.isGitRepo, !self.gitClient.isOperating else { return }
            Task { await self.gitClient.refreshStatus() }
        }
        project.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        codeXRay.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        tabs.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .saved(let url):
                    // A file saved inside the project is a change the automatic code analysis refreshes
                    // from (REQ-002), at once rather than after the change watcher's latency.
                    if let root = self.rootNode?.url.standardizedFileURL.path, url.standardizedFileURL.path.hasPrefix(root + "/") {
                        self.codeXRay.architecture.noteProjectChanged()
                    }
                case .reloadedFromDisk:
                    self.refreshFileTree()
                case .terminalClosed(let id):
                    self.terminals.closeTabTerminal(id)
                case .insightClosed(let session):
                    self.insight.close(session)
                }
            }
            .store(in: &cancellables)
        // Edits made outside MarkView (an agent, a terminal) change the status: look again when the
        // app comes back to the front.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.gitClient.isGitRepo, !self.gitClient.isOperating else { return }
                Task { await self.gitClient.refresh() }
            }
            .store(in: &cancellables)
        Self.debugLog("WorkspaceManager init DONE")
    }

    /// Write workspace diagnostic message to the unified system log (`AR-24`, `AR-42`).
    nonisolated static func debugLog(_ msg: String) {
        AppLog.workspace.debug("\(msg)")
    }

    func openFolder(_ url: URL, completion: (() -> Void)? = nil) {
        projectOperations = ProjectOperationsStore.forRoot(url)
        project.beginOpening(url)
        // Agents working in this folder can reach its browser tabs (BUG-027) and its project tools even from
        // outside its terminals; the browser tools check the terminal-links setting themselves.
        browser.register()
        taskBag.cancelAll()
        flow.cancelWork()
        tabs.reset()
        codeXRay.reset()
        Self.debugLog("openFolder START: \(url.path)")

        // Run setup steps asynchronously — sleep briefly to let SwiftUI render each step
        let setupTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms — let UI render progress
            guard !Task.isCancelled else { return }
            Self.debugLog("Task started, building tree...")

            // Prototypes made before DEC-006 move from .dde/prototypes to docs/prototypes once, before the
            // tree and the prototype lists read the folder; a slug already there stays and is only logged.
            let migration = await Task.detached { PrototypeFiles.migrateLegacy(root: url) }.value
            if !migration.isEmpty { Self.debugLog("Prototype storage migration: \(migration.summary)") }

            guard await project.loadTree(of: url) else { return }

            project.indexingProgress = "Setting up workspace..."
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }

            project.startWatching(url)
            Self.debugLog("File watcher started, calling initDDEWorkspaceAsync...")

            await initDDEWorkspaceAsync(at: url)
            Self.debugLog("openFolder COMPLETE")

            // Code projects are analyzed in the background without the X-Ray tab; the store
            // honours the switch (`.off`, DEC-001) and applies the size cap from its own scan (DEC-003).
            let isCode = await Task.detached { ArchitectureScanner.looksLikeCodeProject(url) }.value
            if project.root == url, isCode {
                codeXRay.architecture.startAutomaticCodeAnalysis(root: url, db: project.database)
            }
            completion?()
        }
        taskBag.store(setupTask, for: "openFolder")
    }

    /// Opens the folder's database and connects the services that work on it — async to keep UI responsive.
    private func initDDEWorkspaceAsync(at url: URL) async {
        do {
            guard try await project.openDatabase(at: url) else { return }
            Self.debugLog("initDDE: database opened")
            terminals.workspaceRoot = url

            project.indexingProgress = "Connecting services..."
            try? await Task.sleep(nanoseconds: 100_000_000)

            gitClient.setup(at: url)
            flow.setUp(at: url)
            toolTabs.projectOpened(url)
            Self.debugLog("initDDE: git setup done")

            // Structural indexing runs silently in background — no progress indicator
            project.indexingProgress = nil
            project.refreshSemanticViews()
            project.runStructuralIndex(at: url)
            Self.debugLog("initDDE: structural index started")
        } catch {
            Self.debugLog("initDDE: ERROR: \(error)")
            project.indexingProgress = nil
        }
    }

    /// Open a file in a new tab or switch to existing tab
    func openFile(_ url: URL) {
        layout.workspaceArea = .files
        // Always init workspace for .md files if DB is missing or file is from different dir —
        // unless a project folder is open: a Markdown file from elsewhere (an agent's report in
        // /tmp, a terminal link) opens as a tab and must not replace the project's search
        // database, git client and AI root.
        let isMD = url.pathExtension.lowercased() == "md"
        if isMD && !project.rootOpenedAsFolder && !isFileInCurrentWorkspace(url) {
            initSingleFileWorkspace(fileURL: url)
        }
        if let feature = flow.features.locate(url)?.feature {
            flow.showFeatureContext(feature.slug)
        }

        tabs.openDocument(url)
    }

    // MARK: - Window session

    // The session of a window is saved and restored by `WindowSessionSnapshotter`; this is what the window itself opens for it.
    var windowFolder: URL? { rootNode?.url }
    var themeSettings: WindowThemeSettings { theme.settings }

    func terminalDirectory(for id: UUID) -> URL? { terminals.tabTerminal(id)?.directory }

    func restoreArchitectureTab(scope: String) {
        // Reopen cached views without triggering new scans/reviews during launch.
        guard let root = rootNode?.url else { return }
        var tab = OpenTab(url: root.appendingPathComponent(ProjectPaths.placeholderName("restored-xray-" + String(ContentHash.of(scope).prefix(12)))),
                          content: "", originalContent: "")
        tab.kind = .architecture(scope: scope)
        tabs.appendTab(tab)
        codeXRay.restoreCachedXRay(scope: scope)
    }

    func restoreTerminal(in directory: URL) { openTerminal(in: directory) }

    func restoreBrowser(_ url: URL) { browser.open(url, activate: false) }

    // MARK: - Workspace metadata

    /// Delete this folder's metadata after confirmation. With `recreate`, rebuild the
    /// index right away; otherwise nothing is written again until the folder is
    /// reopened or Recreate is chosen.
    func removeMetadata(recreate: Bool) {
        guard let root = rootNode?.url else { return }
        let items = project.metadataItems()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = recreate
            ? "Rebuild MarkView data for “\(root.lastPathComponent)”?"
            : "Remove MarkView data from “\(root.lastPathComponent)”?"
        let list = items.isEmpty ? "Nothing is stored yet." : items.map { "• " + $0.path.replacingOccurrences(of: root.path + "/", with: "") }.joined(separator: "\n")
        alert.informativeText = """
            \(list)

            The search index, architecture, AI descriptions, filters, file contents and Insight pages are deleted. \
            Your documents and code are not touched.\(recreate ? " The folder is then indexed and scanned again." : "")
            """
        alert.addButton(withTitle: recreate ? "Rebuild" : "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Stop everything that could still write into the folder.
        stopAllTerminals()
        project.stopIndexing()
        insight.cancelSessions()
        let keep = openTabs.enumerated().filter { $0.element.isFileBacked }.map(\.offset)
        for index in openTabs.indices.reversed() where !keep.contains(index) { tabs.removeTab(at: index) }
        releaseWorkspaceEngines()
        codeXRay.reset()

        let failures = project.deleteMetadata(items)
        if !failures.isEmpty {
            let error = NSAlert()
            error.messageText = "Some items could not be deleted"
            error.informativeText = failures.joined(separator: ", ")
            error.runModal()
        }
        Self.debugLog("removeMetadata: \(items.count) items removed from \(root.path), recreate=\(recreate)")
        if recreate {
            taskBag.store(Task { await initDDEWorkspaceAsync(at: root) }, for: "recreateWorkspace")
        }
    }

    // MARK: - Opening documents

    /// Show a text file's Explain notes, or return to its dedicated viewer.
    func setNotesView(_ show: Bool, explain: Bool = false) {
        guard let tab = activeTab else { return }
        if case .data = tab.kind {
            guard FileType.hasTextSource(tab.url) else { return }
            if show {
                let url = tab.url
                taskBag.store(Task {
                    do {
                        let text = try await Task.detached(priority: .userInitiated) { try FileType.readText(at: url) }.value
                        guard activeTab?.url == url, let index = tabs.firstIndex(of: url) else { return }
                        tabs.updateTab(at: index) { tab in
                            tab.content = text
                            tab.originalContent = text
                            tab.notesView = true
                        }
                        if explain { codeXRay.explainIfNeeded(url) }
                    } catch { tabs.showReadError(error, url: url) }
                }, for: "notes:" + url.path)
            } else { tabs.updateActiveTab { $0.notesView = false } }
        } else if tab.isFileBacked {
            tabs.updateActiveTab { $0.notesView = show }
            if show && explain { codeXRay.explainIfNeeded(tab.url) }
        }
    }

    /// Open a file with its Explain notes, starting an explanation if there is none yet.
    func explainFile(_ url: URL) {
        layout.workspaceArea = .files
        guard !FileType.isImage(url), !Archive.isArchive(url), FileType.hasTextSource(url) else {
            openFile(url)
            return
        }
        taskBag.store(Task {
            if FileType.isData(url) {
                openFile(url)
            } else {
                await tabs.openTextFile(url)
            }
            guard activeTab?.url == url else { return }
            setNotesView(true, explain: true)
        }, for: "explain:" + url.path)
    }

    /// Open `url` and, for code, reveal `line`…`endLine` in the code viewer.
    func openFile(_ url: URL, line: Int?, endLine: Int? = nil) {
        openFile(url)
        guard let line, line > 0 else { return }
        NotificationCenter.default.post(.revealCodeLine, for: self, userInfo:
            ["url": url, "line": line, "endLine": endLine ?? line])
    }

    /// Show a key of a JSON / YAML file picked in the Contents panel: the file's tab comes forward and
    /// its tree viewer scrolls to the node (a source view to the line).
    func revealStructure(_ url: URL, item: StructureOutline.Item) {
        openFile(url)
        NotificationCenter.default.post(.revealStructure, for: self,
                                        userInfo: ["url": url, "path": item.pathJSON, "line": item.line])
    }

    /// Open `url`, honouring a GitHub-style line fragment: `L42` or `L40-L60`.
    func openFile(_ url: URL, lineFragment fragment: String?) {
        let target = URL(fileURLWithPath: url.path)
        guard let fragment,
              let match = fragment.range(of: #"^L(\d+)(?:-L?(\d+))?$"#, options: .regularExpression) else {
            openFile(target)
            return
        }
        let numbers = fragment[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        openFile(target, line: numbers.first, endLine: numbers.count > 1 ? numbers[1] : nil)
    }

    /// Open the note a wikilink names (`[[Note]]`, `[[folder/Note#Heading]]`), the way
    /// Obsidian resolves it: a path from the vault root, else a file with that name —
    /// preferring the current note's folder, then the shortest path.
    func openWikiLink(note: String, heading: String?) {
        guard let root = rootNode?.url.standardizedFileURL, !note.isEmpty, !note.contains("..") else { return }
        let hasExtension = !(note as NSString).pathExtension.isEmpty && FileType.isSupported(URL(fileURLWithPath: note))
        let fileName = hasExtension ? note : note + ".md"
        let currentFolder = activeTab?.url.deletingLastPathComponent().standardizedFileURL.path
        taskBag.store(Task {
            let found: URL? = await Task.detached {
                if fileName.contains("/") {
                    let direct = root.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: direct.path) { return direct }
                }
                let wanted = (fileName as NSString).lastPathComponent.lowercased()
                var matches: [URL] = []
                let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                                options: [.skipsPackageDescendants])
                while let url = enumerator?.nextObject() as? URL {
                    let name = url.lastPathComponent
                    if name == ".git" || name == ProjectPaths.localFolderName || name == "node_modules" { enumerator?.skipDescendants(); continue }
                    if name.lowercased() == wanted { matches.append(url.standardizedFileURL) }
                }
                return WikiLinkResolver.choose(candidates: matches.map(\.path), from: currentFolder)
                    .map { URL(fileURLWithPath: $0) }
            }.value
            guard !Task.isCancelled else { return }
            guard let found else {
                NSSound.beep()
                return
            }
            openFile(found)
            if let heading, !heading.isEmpty {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                NotificationCenter.default.post(.scrollToText, for: self, object: heading, userInfo: ["heading": true])
            }
        }, for: "wikilink:" + note)
    }

    /// Open a file referenced by a JSON Canvas file-node. Canvas paths are
    /// vault-root-relative (Obsidian convention); resolve against the workspace
    /// root first, then fall back to the canvas file's own directory. Files the
    /// app can't render are handed to the system default app.
    func openCanvasFileReference(_ path: String) {
        // Reject absolute/escaping paths — canvas files are untrusted input.
        guard !path.hasPrefix("/"), !path.contains("..") else { return }

        var candidates: [URL] = []
        if let root = rootNode?.url {
            candidates.append(root.appendingPathComponent(path))
        }
        if activeTabIndex >= 0, activeTabIndex < openTabs.count {
            let canvasDir = openTabs[activeTabIndex].url.deletingLastPathComponent()
            candidates.append(canvasDir.appendingPathComponent(path))
        }

        guard let target = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            AppLog.workspace.error("Canvas file reference not found: \(path)")
            return
        }

        if FileType.isOpenable(target) {
            openFile(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// Check if a file belongs to the currently open workspace
    private func isFileInCurrentWorkspace(_ url: URL) -> Bool {
        guard project.hasWorkspace else { return false }
        // A pull request's copy of a project file (MarkView's cache, opened from the PR
        // X-Ray) belongs to the open project: it must not turn it into a single-file workspace.
        if codeXRay.architecture.review.prRelativePath(for: url) != nil { return true }
        return project.contains(url)
    }

    /// Drop the database and every engine bound to the current workspace.
    private func releaseWorkspaceEngines() {
        toolTabs.projectClosed()
        project.releaseDatabase()
        stopAllTerminals()
        terminals.workspaceRoot = nil
    }

    /// Close the open folder and every tab, returning the window to the welcome
    /// screen so another folder can be chosen. Returns false if the user cancelled
    /// or unsaved changes could not be written.
    @discardableResult
    func closeFolder() -> Bool {
        if let operations = projectOperations {
            let active = operations.runs.values.filter(\.isActive)
            if !active.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Stop running project operations before closing?"
                alert.informativeText = active.map { $0.snapshot.label + ($0.snapshot.environment.map { " (\($0))" } ?? "") }
                    .joined(separator: "\n")
                alert.addButton(withTitle: "Keep working")
                alert.addButton(withTitle: "Stop operations and close")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
                operations.cancelForClose()
                taskBag.store(Task { [weak self] in
                    while operations.runs.values.contains(where: \.isActive), !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    _ = self?.closeFolder()
                }, for: "closeFolderAfterOperations")
                return false
            }
        }
        guard tabs.resolveUnsavedChanges(at: Array(openTabs.indices), before: "closing the folder") else { return false }

        Self.debugLog("closeFolder: \(rootNode?.url.path ?? "(no folder)")")
        Settings.standard.remove(Setting.lastFolder)

        // Stop work that would otherwise keep writing into the old workspace.
        insight.cancelSessions()
        stopAllTerminals()
        taskBag.cancelAll()

        tabs.reset()
        project.closeFolder()
        releaseWorkspaceEngines()
        codeXRay.reset()
        projectOperations = nil
        gitClient.reset()
        flow.reset()
        requests.pendingGraphCreatorType = nil
        return true
    }

    /// Initialize workspace for a single .md file — DB named after the file, indexes only this file
    private func initSingleFileWorkspace(fileURL: URL) {
        let parentDir = fileURL.deletingLastPathComponent()
        Self.debugLog("initSingleFileWorkspace: dir=\(parentDir.path)")

        releaseWorkspaceEngines()

        terminals.workspaceRoot = parentDir
        gitClient.setup(at: parentDir)
        project.openSingleFile(fileURL)
    }


    /// Show the file tree at `url`'s folder with `url` highlighted.
    func revealInFileTree(url: URL) {
        chrome.showFileTree = true
        requests.fileTreeRevealRequest = url.standardizedFileURL
    }

    // MARK: - File tree and graph tools

    /// Reload the file tree from disk. Kept for the regions of this file that other decompositions still move out (`AR-14` steps 2-7).
    func refreshFileTree() { project.fileTree.refresh() }

    /// Folder a new diagram goes into (the file tree's "New Graph Diagram"); nil = project root.
    private(set) var graphCreatorFolder: URL?

    func presentGraphCreator(for type: String = "architecture", in folder: URL? = nil) {
        graphCreatorFolder = folder
        requests.pendingGraphCreatorType = type
    }

    func dismissGraphCreator() {
        requests.pendingGraphCreatorType = nil
    }

    func runAITool(named toolName: String, contentOverride: String? = nil) {
        guard let tool = WorkspaceAITool(rawValue: toolName) else { return }

        if tool.opensGraphCreator {
            presentGraphCreator(for: tool.rawValue)
            return
        }

        switch tool {
        case .critic: runCritic(contentOverride: contentOverride)
        case .audit: runAudit()
        case .codemap: runCodemap()
        case .architecture, .dataflow, .pipeline, .deployment, .sequence, .er: break
        }
    }

    func runGraphEdit(instruction: String, currentMermaid: String) {
        editDiagram(instruction: instruction, currentMermaid: currentMermaid)
    }

    // MARK: - Agents surface and handoff

    /// Show the floating agents surface without changing the other panels.
    func showAIConsole() { chrome.agentsVisible = true }

    func toggleAIConsole() { chrome.agentsVisible.toggle() }

    // MARK: - Host window

    /// The window this workspace is shown in; set by its view. Control tools list, focus and name windows by it.
    weak var hostWindow: NSWindow? {
        didSet { if let hostWindow, hostWindow !== oldValue { polling.follow(window: hostWindow) } }
    }

    /// A window with nothing open: no folder, no tab. Agents may open a project in it; they never replace a project.
    var isBlank: Bool { rootNode == nil && openTabs.isEmpty }

    // MARK: - Terminal tabs

    /// Open a terminal in `folder` as an editor tab; `startupCommand` is typed once the shell is up.
    @discardableResult
    func openTerminal(in folder: URL, startupCommand: String? = nil, title: String? = nil,
                      activate: Bool = true) -> TerminalSession {
        let session = terminals.makeTabTerminal(in: folder, startupCommand: startupCommand, title: title)
        var tab = OpenTab(url: folder.appendingPathComponent(ProjectPaths.placeholderName("terminal-" + session.id.uuidString)),
                          content: "", originalContent: "")
        tab.kind = .terminal(session.id)
        tabs.appendTab(tab, activate: activate)
        return session
    }


    /// End every terminal of the window, and the watch over open files that runs while they do.
    private func stopAllTerminals() {
        terminals.stopAll()
        tabs.stopWatchingOpenFiles()
    }

    /// The open document, whole: the terminal writer delivers pastes of any length (BUG-002).
    private func activeDocumentContext(contentOverride: String? = nil, defaultFileName: String = "project") -> (fileName: String, content: String) {
        let fileName = activeTab?.url.lastPathComponent ?? defaultFileName

        if let contentOverride {
            return (fileName, contentOverride)
        }

        let content = activeTab?.content ?? ""
        return (fileName, content)
    }

}

/// What the terminals read of the window: the browser agents drive, and the editor (`AITerminalsController`).
extension WorkspaceManager: FileOperationsHost {}

extension WorkspaceManager: AITerminalsHost {
    var browserControlID: UUID { browser.controlID }
    func registerBrowserControl() { browser.register() }
    func openInAppBrowser(_ url: URL) { browser.openInAppBrowser(url) }
    func terminalStarted() { tabs.startWatchingOpenFiles() }
}

/// What the window's browser asks of the window (`BrowserHost`).
extension WorkspaceManager: BrowserHostWindow {
    var controlWorkspace: WorkspaceManager { self }
    var controlFeatures: FeatureStore { flow.features }
    var controlDeployments: DeploymentStore { toolTabs.deployments.store }
    var controlDiscussions: DiscussionStore { toolTabs.discussions.store }
}

/// The dev server Preview Web App starts is one of the window's terminals, and a picked page element goes to the shown AI terminal.
extension AITerminalsController: DevServerTerminals {}

/// What the research maps and jobs read of the window's tabs and do to them and to files (`ResearchMapController`).
extension WorkspaceManager: ResearchHost {
    func researchTab(for file: URL) -> ResearchTabText? {
        let path = file.standardizedFileURL.path
        guard let tab = openTabs.first(where: { $0.isFileBacked && $0.url.standardizedFileURL.path == path }) else { return nil }
        return ResearchTabText(text: tab.content, isModified: tab.isModified)
    }

    func researchTabSaved(_ file: URL, text: String) {
        let path = file.standardizedFileURL.path
        guard let index = openTabs.firstIndex(where: { $0.isFileBacked && $0.url.standardizedFileURL.path == path }) else { return }
        tabs.updateTab(at: index) { tab in
            tab.content = text
            tab.originalContent = text
            tab.isModified = false
        }
    }

    func researchEditorFile(documentID: UUID?, event: String) -> URL? {
        guard let index = tabs.editorTabIndex(documentID: documentID, event: event), openTabs[index].isFileBacked else { return nil }
        return openTabs[index].url
    }

    func researchWatchOpenFiles() { tabs.startWatchingOpenFiles() }

    func saveBeforeResearch(_ file: URL, action: String) -> Bool { tabs.saveBeforeReading(file, action: action) }

    func researchDocumentChanged(_ file: URL, content: String, applyToEdited: (String) -> String?) {
        refreshFileTree()
        if !tabs.fileRewritten(file, content: content, applyToEdited: applyToEdited) {
            research.jobs.message = "\(file.lastPathComponent) was updated on disk, but its tab has unsaved edits that conflict; reload it to see the AI's change."
        }
    }
}

/// What Recursive Insight reads of the window and does to its tabs (`InsightCoordinator`).
extension WorkspaceManager: InsightHost {
    var insightSessions: [InsightSession] {
        openTabs.compactMap { tab in
            if case .insight(let session) = tab.kind { return session }
            return nil
        }
    }

    var activeInsightSession: InsightSession? {
        guard let tab = activeTab, case .insight(let session) = tab.kind else { return nil }
        return session
    }

    func showInsightTab(_ session: InsightSession, placeholder: URL) {
        tabs.appendTab(OpenTab(url: placeholder, content: "", originalContent: "", kind: .insight(session)), activate: true)
    }

    func removeInsightTab(sessionID: UUID) {
        // The index is resolved now: tabs may have closed while the session was ending.
        guard let index = openTabs.firstIndex(where: {
            if case .insight(let session) = $0.kind { return session.id == sessionID }
            return false
        }) else { return }
        tabs.removeTab(at: index)
    }
}

extension WorkspaceManager: ProjectOperationsPresenter {
    func showOperationConsole(selecting id: String) {
        requests.operationSelectedRunID = id
        requests.operationConsoleVisible = true
    }

    func showOperationEditor(_ request: ProjectOperationEditRequest) {
        requests.operationEditRequest = request
    }

    var operationsHostWindow: NSWindow? { hostWindow }
}

/// What `CodeAndXRayCoordinator` needs of this window; the coordinator holds no other reference to it (`AR-14` step 11).
extension WorkspaceManager: CodeXRayHost {
    var activeTabKind: TabKind? { tabs.activeTab?.kind }
    var activeTabURL: URL? { tabs.activeTab?.url }
    var gitBranch: String { gitClient.branch }
    var defaultAuthor: String { flow.features.defaultOwner }

    func openTabContent(for url: URL) -> String? { tabs.content(ofOpen: url) }

    func scrollToText(_ text: String) {
        NotificationCenter.default.post(.scrollToText, for: self, object: text)
    }

    func startRecursiveInsight(at target: URL?, title: String?) { insight.start(at: target, title: title) }

    func fixInPullRequest(_ number: Int?, prompt: String) async -> String? { await flow.fixInPullRequest(number, prompt: prompt) }

    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? { terminals.sendToAssistant(prompt, submit: submit) }

    /// Bring the X-Ray tab of `scope` to the front, opening it when it is not there yet.
    func showXRayTab(scope: String, root: URL) {
        layout.workspaceArea = .projectMap
        tabs.showArchitectureTab(scope: scope, root: root)
    }
}
