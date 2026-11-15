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
class WorkspaceManager: ObservableObject, TabsProviding, WindowSessionHost {
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
    /// AI tool runs working in a headless agent (diagrams, code map, review, audit).
    let aiJobs = AIToolJobs()

    // MARK: - Tool tabs

    /// What opening a tool does beyond showing its tab: wiring the tool's own store to the project, or building the tab of a tool that
    /// carries a session. A tool that needs neither has no entry here; `ToolRegistry` describes the rest of it.
    private struct ToolOpener {
        /// Runs on every open, also when the tool's tab exists already.
        var prepare: (WorkspaceManager, URL) -> Void = { _, _ in }
        /// The tab of a tool that carries a session; every other tool gets a plain `.tool` tab.
        var makeTab: ((WorkspaceManager, URL, ToolDescriptor) -> OpenTab)?
        /// Runs once, after a tab built by `makeTab` was added.
        var opened: (WorkspaceManager, OpenTab) -> Void = { _, _ in }
    }

    private static let toolOpeners: [ToolID: ToolOpener] = [
        .deployments: ToolOpener(prepare: { workspace, root in
            workspace.deployments.setRoot(root)
            workspace.deployments.onNeedsAttention = { [weak workspace] in workspace?.openTool(.deployments) }
        }),
        .discussions: ToolOpener(prepare: { workspace, root in workspace.discussions.setRoot(root) }),
        .workflow: ToolOpener(prepare: { workspace, _ in workspace.hostWindow?.makeKeyAndOrderFront(nil) }),
        .qa: ToolOpener(prepare: { workspace, root in
            workspace.hostWindow?.makeKeyAndOrderFront(nil)
            workspace.qa.attach(root: root)
            if workspace.qa.run.bugFiler == nil { workspace.qa.run.bugFiler = QABugFiler(sink: QAFeatureStoreBugSink(store: workspace.features)) }
            workspace.qa.archive.bugFiler = workspace.qa.run.bugFiler
        }),
        .uiStudio: ToolOpener(
            makeTab: { workspace, root, tool in workspace.makeUIStudioTab(root: root, tool: tool) },
            opened: { _, tab in if case .uiStudio(let session) = tab.kind { session.start() } }),
        .cockpit: ToolOpener(makeTab: { workspace, root, tool in workspace.makeCockpitTab(root: root, tool: tool) })
    ]

    /// Opens the tab of a tool, or returns to it: a tool has one tab per window.
    func openTool(_ id: ToolID) {
        guard let root = rootNode?.url, let tool = ToolRegistry.shared.descriptor(for: id) else { return }
        let opener = Self.toolOpeners[id] ?? ToolOpener()
        opener.prepare(self, root)
        layout.workspaceArea = .files
        chrome.showCenter = true
        if let index = openTabs.firstIndex(where: { $0.kind.toolID == id }) {
            activeTabIndex = index
            return
        }
        let tab: OpenTab
        if let makeTab = opener.makeTab {
            tab = makeTab(self, root, tool)
        } else {
            var plain = OpenTab(url: tool.sentinelURL(in: root), content: "", originalContent: "")
            plain.kind = .tool(id)
            tab = plain
        }
        tabs.appendTab(tab, activate: true)
        opener.opened(self, tab)
    }

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

    /// Keep the selected task visible beside its documents in the right column.
    func showFeatureContext(_ slug: String?) {
        if let slug {
            features.activeSlug = slug
            layout.issuesFeature = slug
        }
        layout.navigatorTab = .feature
        chrome.showTOC = true
        chrome.terminalVisible = true
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
    /// Where the project runs and how each place is doing (the Deployments tab).
    let deployments = DeploymentStore()
    /// The state of the Workflow tab: the draft being edited survives a switch to another tab.
    let workflowEditor = WorkflowEditorModel()
    /// End-to-End QA: the scenarios of the project and the one being edited.
    let qa = QAModel()
    private var cockpitSession: CockpitSession?
    /// Questions asked before there is a feature, answered as pages (the Discussions tab).
    let discussions = DiscussionStore()
    private var discussionTask: Task<Void, Never>?
    /// Answers to questions about an environment, read from state and logs by the project's own assistant.
    let deploymentAdvisor = DeploymentAdvisor()
    /// Pull requests, issues and Actions of the folder's GitHub repository.
    let gitHub = GitHubStore()
    /// Feature workspaces of the folder (docs/features/<slug>/…).
    let features = FeatureStore()
    /// Research of this window: the maps, and the jobs for new research, follow-ups and comments (docs/research/).
    private(set) lazy var research = ResearchMapController(host: self, project: project, tasks: taskBag)
    /// Creates, renames, moves, copies and trashes the files of the project, with the tabs that follow or close (`AR-14` step 2).
    private(set) lazy var fileOperations = FileOperationsController(host: self, tabs: tabs, project: project)
    /// Translates documents into another language and opens the result in a new tab (`AR-14` step 1).
    private(set) lazy var translator = DocumentTranslator(tabs: tabs, project: project, tasks: taskBag)
    /// This window's bug basket for batch Fix with AI (issue #31); a new folder empties it.
    private(set) lazy var bugBatch = BugBatch(store: features)
    /// The terminals of this window: the AI panel's, the editor tabs', the AI terminals that come back across launches, and what the
    /// assistants are doing.
    private(set) lazy var terminals = AITerminalsController(host: self, project: project, tasks: taskBag)
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

    init() {
        Self.debugLog("WorkspaceManager init START")
        codeXRay = CodeAndXRayCoordinator(project: project)
        codeXRay.host = self
        qa.assistants = terminals

        project.fileTree.onTimer = { [weak self] in
            guard let self, self.gitClient.isGitRepo, !self.gitClient.isOperating, NSApp.isActive else { return }
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
        registerBrowserControl()
        taskBag.cancelAll()
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
            setUpGitHub(at: url)
            setUpFeatures(at: url)
            deployments.setRoot(url)
            discussions.setRoot(url)
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
        if let feature = features.locate(url)?.feature {
            showFeatureContext(feature.slug)
        }

        tabs.openDocument(url)
    }

    // MARK: - Window session

    // The session of a window is saved and restored by `WindowSessionSnapshotter`; this is what the window itself opens for it.
    var windowFolder: URL? { rootNode?.url }
    var themeSettings: WindowThemeSettings { theme.settings }

    func terminalDirectory(for id: UUID) -> URL? { terminals.tabTerminal(id)?.directory }

    func restoreFolder(_ folder: URL) async {
        await withCheckedContinuation { continuation in
            openFolder(folder) { continuation.resume() }
        }
    }

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

    func restoreBrowser(_ url: URL) { _ = openBrowser(url, activate: false) }

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
        if codeXRay.architecture.prRelativePath(for: url) != nil { return true }
        return project.contains(url)
    }

    /// Drop the database and every engine bound to the current workspace.
    private func releaseWorkspaceEngines() {
        cockpitSession?.closeProject()
        cockpitSession = nil
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
        UserDefaults.standard.removeObject(forKey: ProjectContext.lastFolderKey)

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
        gitHubRoot = nil
        gitHub.reset()
        features.reset()
        deployments.setRoot(nil)
        discussions.setRoot(nil)
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

    func resumeHandoff(slug: String, title: String, linkedFiles: [String]) {
        guard let root = features.root else { return }
        taskBag.store(Task {
            let checked = await Task.detached { () -> (available: [URL], missing: [String]) in
                let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                var available: [URL] = []
                var missing: [String] = []
                for path in linkedFiles {
                    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                    guard !path.hasPrefix("/"), !parts.isEmpty,
                          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                        missing.append(path)
                        continue
                    }
                    let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                    guard url.path.hasPrefix(base),
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        missing.append(path)
                        continue
                    }
                    available.append(url)
                }
                return (available, missing)
            }.value
            guard !Task.isCancelled, features.root == root else { return }
            requests.handoffResume = HandoffResume(slug: slug, title: title,
                                          linkedFiles: linkedFiles, missingFiles: checked.missing)
            for url in checked.available { openFile(url) }
            layout.workspaceArea = .files
        }, for: "resumeHandoff:" + slug)
    }

    // MARK: - Browser control

    /// This window's id for agents driving its browser tab (`BrowserControlServer`).
    let browserControlID = UUID()

    /// The window this workspace is shown in; set by its view. Control tools list, focus and name windows by it.
    weak var hostWindow: NSWindow?

    /// A window with nothing open: no folder, no tab. Agents may open a project in it; they never replace a project.
    var isBlank: Bool { rootNode == nil && openTabs.isEmpty }

    /// Offer this window to agents (`BrowserControlServer`): its browser tabs, its project's features, and the
    /// workspace itself for the control tools. Called when the window is shown, a folder opens or a terminal starts.
    func registerBrowserControl() {
        BrowserControlServer.register(browserControlID, .init(
            workspace: { [weak self] in self },
            root: { [weak self] in self?.project.root },
            tabs: { [weak self] in self?.browserSessions ?? [] },
            active: { [weak self] in
                guard let self, self.openTabs.indices.contains(self.activeTabIndex),
                      case .browser(let session) = self.openTabs[self.activeTabIndex].kind else { return nil }
                return session
            },
            show: { [weak self] session in self?.showBrowser(session) },
            open: { [weak self] url, name in
                guard let self else { return BrowserSession(url: url) }
                let session = self.openBrowser(url)
                if let name { session.agentName = name }
                return session
            },
            features: { [weak self] in self?.features },
            deployments: { [weak self] in self?.deployments },
            discussions: { [weak self] in self?.discussions }))
    }

    /// The window's browser tabs, in tab order.
    var browserSessions: [BrowserSession] {
        openTabs.compactMap { if case .browser(let session) = $0.kind { return session }; return nil }
    }

    /// Bring a browser tab to the front.
    func showBrowser(_ session: BrowserSession) {
        guard let index = openTabs.firstIndex(where: { if case .browser(let s) = $0.kind { return s === session }; return false }) else { return }
        layout.workspaceArea = .files
        chrome.showCenter = true
        activeTabIndex = index
    }

    // MARK: - GitHub

    /// Open GitHub issue #n: its tab when the GitHub integration is on, else the issue page in
    /// the browser (repository from the `origin` remote; nothing is sent to GitHub by the app).
    func openGitHubIssue(_ number: Int) {
        if let slug = gitHub.selectedRepo?.slug {
            openGitHubTab(.issue(number: number, repo: slug, title: "#\(number)"))
            return
        }
        guard let root = rootNode?.url else { return }
        Task {
            let remote = await GitHubClient.execute(["remote", "get-url", "origin"], in: root, git: true)
            guard let slug = GitHubClient.slug(fromRemoteURL: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let url = URL(string: "https://github.com/\(slug)/issues/\(number)") else { return }
            NSWorkspace.shared.open(url)
        }
    }



    /// The project a new-project flow created: open it with its specification in front — the
    /// Issues list on it and the overview in the editor (DEC-023).
    func openCreatedProject(_ url: URL, specification slug: String) {
        openFolder(url) { [weak self] in
            guard let self else { return }
            self.features.activeSlug = slug
            self.layout.leftPanel = "issues"
            self.layout.issuesFeature = slug
            self.layout.featureStage = .explore
            self.chrome.showTOC = true
            self.chrome.showFileTree = true
            self.layout.navigatorTab = .feature
            self.openFile(url.appendingPathComponent(FeatureStore.folderName).appendingPathComponent(slug).appendingPathComponent("overview.md"))
        }
    }

    /// Turn MarkView's GitHub integration on (a Settings switch for every window, DEC-020) and
    /// look for `slug` in this folder again. Nil when found, else why not.
    func activateGitHub(expecting slug: String, in folder: URL) async -> String? {
        // Right after bootstrap the folder may still be opening in this window.
        for _ in 0..<40 where rootNode?.url.standardizedFileURL != folder.standardizedFileURL {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let root = rootNode?.url, root.standardizedFileURL == folder.standardizedFileURL else {
            return "This window does not show \(folder.lastPathComponent) any more. Open it and use File › Publish to GitHub… to finish."
        }
        if !GitHubSettings.enabled { UserDefaults.standard.set(true, forKey: GitHubSettings.enabledKey) }
        // The remote was added after the folder opened: detect again.
        gitHub.reset()
        gitHubRoot = root
        gitHubSettingChanged()
        for _ in 0..<40 {
            if gitHub.repos.contains(where: { $0.slug.lowercased() == slug.lowercased() }) { return nil }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return gitHub.lastError ?? "MarkView did not find \(slug) among this folder's remotes."
    }

    /// "New Feature / New Bug from #n": the issue's text and comments as the material, linked.
    func startIntake(_ kind: IntakeKind, fromIssue number: Int) {
        // The sheet opens at once and loads the issue itself (with a spinner).
        requests.intake = IntakeRequest(kind: kind, linkedIssue: number, loadIssue: number)
    }

    /// "New … from this pull request": its description as the material (a new issue is filed).
    func startIntake(_ kind: IntakeKind, fromPullRequest pr: GHPullRequest) {
        requests.intake = IntakeRequest(kind: kind, text: "Pull request #\(pr.number): \(pr.title) (\(pr.headRefName) → \(pr.baseRefName))",
                               loadPullRequest: pr.number)
    }

    /// "New … from this document": the document is the material (attached, so the AI reads it whole).
    func startIntake(_ kind: IntakeKind, fromDocument url: URL) {
        let path = project.relativePath(of: url)
        let lead: String
        switch kind {
        case .feature, .quickFeature: lead = "Build a feature from the document \(path) (attached)."
        case .bug: lead = "The document \(path) (attached) describes a problem to analyze as a bug."
        case .understand: lead = "What implements \(path) in this project, and how do the documented parts work in the code?"
        case .research: lead = "Review \(path): "
        }
        switch kind {
        case .understand: requests.intake = IntakeRequest(kind: kind, text: lead)
        case .research: requests.intake = IntakeRequest(kind: kind, text: lead, targets: [url])
        default: requests.intake = IntakeRequest(kind: kind, text: lead, attachments: [url])
        }
    }

    /// New Research (replaces the Deep Research AI tool, DEC-010): the intake sheet, with the open
    /// document as its first target.
    func newResearch() {
        requests.intake = IntakeRequest(kind: .research)
    }

    func startResearch(fromFolder folder: URL) {
        requests.intake = IntakeRequest(kind: .research, text: "Review the documents in \(project.relativePath(of: folder)) and its subfolders: ", targets: [folder])
    }

    /// Documents a new research starts with (DEC-009): the open document when it is a file in the folder.
    var researchDefaultTargets: [URL] {
        guard let root = rootNode?.url, let tab = activeTab, tab.isFileBacked,
              ResearchJobs.relative(tab.url, to: root) != nil else { return [] }
        return [tab.url]
    }

    /// Before a research job reads `file`: unsaved edits in its tab are saved, or the user
    /// cancels (DEC-014). True when the file on disk is current.
    func saveBeforeResearch(_ file: URL, action: String) -> Bool {
        guard let index = openTabs.firstIndex(where: { $0.url.standardizedFileURL == file.standardizedFileURL && $0.isFileBacked }),
              openTabs[index].isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(openTabs[index].displayName) before \(action)?"
        alert.informativeText = "The AI works on the document as it is saved on disk."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        tabs.saveFile(at: index)
        return !openTabs[index].isModified
    }

    /// A handoff is a disk snapshot; save all modified tabs in that feature first.
    func saveBeforeHandoff(_ folder: URL) -> Bool {
        let prefix = folder.standardizedFileURL.path + "/"
        for index in openTabs.indices where openTabs[index].isFileBacked && openTabs[index].isModified &&
            openTabs[index].url.standardizedFileURL.path.hasPrefix(prefix) {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(openTabs[index].displayName) before handoff?"
            alert.informativeText = "The handoff captures files as saved on disk."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            tabs.saveFile(at: index)
            if openTabs[index].isModified { return false }
        }
        return true
    }

    /// A research job rewrote `file` on disk: its tab shows the new text; a tab with unsaved
    /// edits gets the same change applied by `applyToEdited` so nothing typed is lost.
    func researchDocumentChanged(_ file: URL, content: String, applyToEdited: (String) -> String?) {
        refreshFileTree()
        guard let index = openTabs.firstIndex(where: { $0.url.standardizedFileURL == file.standardizedFileURL && $0.isFileBacked }) else { return }
        if !openTabs[index].isModified {
            tabs.updateTab(at: index) { tab in
                tab.content = content
                tab.originalContent = content
                tab.isModified = false
            }
        } else if let edited = applyToEdited(openTabs[index].content) {
            tabs.updateTab(at: index) { tab in
                tab.content = edited
                tab.originalContent = content
                tab.isModified = edited != content
            }
        } else {
            research.jobs.message = "\(file.lastPathComponent) was updated on disk, but its tab has unsaved edits that conflict; reload it to see the AI's change."
        }
    }

    /// Implement with AI: in a project the person first sees the definition of done for this run (and may
    /// change it); without a project folder the standard one is used at once.
    func implementWithAI(_ url: URL) {
        if projectFolder != nil { requests.doneRequest = url } else { startImplementation(url, done: .standard) }
    }

    /// Hand a document to the AI to implement, establishing a goal in the receiving assistant. The goal
    /// carries the definition of done. The feature is recorded as "implementation started" with the CLI
    /// that got it.
    func startImplementation(_ url: URL, done: DefinitionOfDone, in terminal: TerminalSession? = nil) {
        let path = project.relativePath(of: url)
        let target = url.standardizedFileURL.path
        let slug = features.features.first(where: { $0.folder.standardizedFileURL.path == target })?.slug
            ?? features.locate(url)?.feature.slug
        let block = slug.map { features.lifecycle.handoffBlock(.feature, [$0]) } ?? ""
        guard let session = terminals.sendToAssistant(submit: true, to: terminal, promptFor: { session in
            guard let tool = session.profile.tool else { return nil }
            let prompt = HandoffPrompt.feature(path, tool: tool, done: done)
            return block.isEmpty ? prompt : prompt + "\n\n" + block
        }) else { return }
        guard let slug else { return }
        // Handed to the assistant: the feature is being implemented (BUG-008). The hand-off that went out is the start
        // evidence; a hand-off that failed above left the status alone.
        features.markImplementing(slug, handoff: session.profile.tool?.displayName ?? "AI assistant")
        if let tool = session.profile.tool {
            features.recordImplementationStarted(slug, tool: tool, directory: session.directory, runningSince: session.runningSince)
        }
    }

    /// Hand the conflicted files to the assistant (Git tab → Conflicts → Resolve with AI). It resolves and
    /// stages them; committing, pushing and aborting stay with the person.
    func resolveConflictsWithAI() {
        let files = gitClient.repoStatus.entries(in: .conflicts).map(\.path)
        guard !files.isEmpty else { return }
        guard !terminals.assistantIsBusy else {
            gitClient.lastError = "The assistant is still working. Resolve the conflicts with it when it has finished."
            return
        }
        let prompt = ConflictPrompt.make(files: files, operation: gitClient.operationInProgress, branch: gitClient.branch)
        terminals.sendToAssistant(prompt, submit: true)
    }

    /// Hand a bug report to the assistant in the Terminal tab to fix; the report is marked `fixing`.
    /// `terminal`: the one to fix it in (an agent driving the window names it); else the usual choice.
    func fixBugWithAI(_ url: URL, in terminal: TerminalSession? = nil) {
        let tool: CLITool? = terminal != nil ? terminal?.profile.tool : AIAssistantPreferences.backend(project: aiProject)
        let key = features.bug(at: url)?.key
        // A bug the lifecycle does not let start (already fixed or closed) is not handed over: nothing could mark it.
        if let key, !features.lifecycle.canStartByHandoff(.bug, key) {
            features.lastError = "\(key) is \(features.lifecycle.storedStatus(.bug, key) ?? "not open") and cannot be handed to the assistant to fix. Reopen it first."
            return
        }
        let block = key.map { features.lifecycle.handoffBlock(.bug, [$0]) } ?? ""
        let base = HandoffPrompt.bug(project.relativePath(of: url), tool: tool)
        let prompt = block.isEmpty ? base : base + "\n\n" + block
        // The report is marked fixing only after the prompt went out: a hand-off that failed leaves it open (REQ-003).
        guard let session = terminals.sendToAssistant(submit: true, to: terminal, promptFor: { _ in prompt }), let key else { return }
        features.lifecycle.startByHandoff(.bug, key, tool: session.profile.tool?.displayName ?? "AI assistant", actor: .human(features.lifecycleActor))
    }

    /// Batch Fix with AI (issue #31): the basket's open bugs go to the assistant in one prompt —
    /// one branch made by the AI, one commit and one outcome per bug. A bug the lifecycle does
    /// not let start is left out of the prompt; once the prompt went out, each bug in it is marked
    /// `fixing` (the hand-off is the start evidence) and the basket is emptied. When too few bugs
    /// can start, or the prompt cannot be sent, nothing is marked and the basket is kept
    /// (BUG-032). The app runs no git itself (DEC-002).
    func fixBasketWithAI() {
        bugBatch.reconcile()
        let bugs = bugBatch.eligible
        guard bugs.count >= BugBasket.minimumBatch, !terminals.assistantIsBusy, features.root != nil else { return }
        let tool = AIAssistantPreferences.backend(project: aiProject)
        var session: TerminalSession?
        let outcome = BatchStart.run(bugs, canStart: { bug in
            features.lifecycle.canStartByHandoff(.bug, bug.key)
        }, send: { startable in
            let base = BatchFixPrompt.make(startable, tool: tool)
            let block = features.lifecycle.handoffBlock(.bug, startable.map(\.key))
            session = terminals.sendToAssistant(block.isEmpty ? base : base + "\n\n" + block, submit: true)
            return session != nil
        }, start: { bug in
            let tool = session?.profile.tool?.displayName ?? "AI assistant"
            let result = features.lifecycle.startByHandoff(.bug, bug.key, tool: tool, actor: .human(features.lifecycleActor), surface: false)
            return result.reachedStatus
        })
        if case .started = outcome { bugBatch.clear() }
        bugBatch.notice = BatchStart.notice(outcome)
    }

    /// An intake finished: open what it made, and for a feature show its workspace.
    func intakeFinished(_ kind: IntakeKind, outcome: FeatureAssistant.IntakeOutcome) {
        if let slug = outcome.feature {
            showFeature(slug, stage: kind == .quickFeature ? .build : .explore)
        } else if kind == .bug {
            // The report opens in the editor; its questions are answered in the Feature tab.
            chrome.showTOC = true
            layout.navigatorTab = .feature
        }
        refreshFileTree()
        if let file = outcome.file { openFile(file) }
    }


    /// Opens feature `slug` in the Feature panel at `stage`, with its documents beside it.
    func showFeature(_ slug: String, stage: FeatureStage) {
        features.activeSlug = slug
        layout.leftPanel = "issues"
        layout.issuesFeature = slug
        layout.featureStage = stage
        chrome.showTOC = true
        chrome.showFileTree = true
        layout.navigatorTab = .feature
    }

    /// A feature was written by the app itself (the prototype hand-off): open it at its Build stage, ready for "Implement with AI", with
    /// its overview in the editor. Nothing starts by itself.
    func featureWritten(_ slug: String, overview: URL) {
        showFeature(slug, stage: .build)
        refreshFileTree()
        openFile(overview)
    }

    /// A contextual action on text selected in the editor: the answer (or the created
    /// requirement / decision / question) appears in the right panel's Feature tab.
    func runFeatureAction(_ name: String, text: String, question: String) {
        // A comment on a research document: the AI revises that section (DEC-017).
        if name == "comment" {
            guard let url = activeTab?.url, activeTab?.isFileBacked == true, rootNode != nil else { return }
            research.jobs.comment(on: text, comment: question, in: url)
            return
        }
        guard let action = FeatureAction(rawValue: name) else { return }
        guard rootNode != nil else { return }
        let url = activeTab?.url
        let located = url.flatMap { features.locate($0) }
        let slug = located?.feature.slug ?? features.active?.slug
        let document = url.map { features.relativePath($0) }
        chrome.showTOC = true
        layout.navigatorTab = .feature
        Task { await features.assistant.perform(action, selection: text, document: document, question: question, feature: slug) }
    }

    /// Feature workspaces of a folder, with the AI's access to the index and GitHub.
    private func setUpFeatures(at root: URL) {
        let newFolder = features.root != root
        features.setup(root: root)
        if newFolder { bugBatch.reset() }
        features.assistant.project = project
        features.assistant.gitHubClient = { [weak self] in self?.gitHub.client }
    }

    /// Folder the GitHub integration works in (folders only, never a single file).
    private var gitHubRoot: URL?

    /// Watches the Settings switch (every window follows it).
    private var gitHubSettingObserver: NSObjectProtocol?
    private var gitHubWasEnabled = GitHubSettings.enabled

    /// Find the folder's GitHub repository and follow the current branch's CI — only when
    /// the integration is turned on in Settings (MarkView stays a plain viewer otherwise).
    private func setUpGitHub(at root: URL) {
        gitHubRoot = root
        gitClient.onBranch = { [weak self] branch in self?.gitHub.branchChanged(branch) }
        gitHub.onRepoChange = { [weak self] repo in self?.codeXRay.architecture.gitHubRepo = repo }
        gitHub.onPoll = { [weak self] client in self?.features.syncLifecycle(with: client) }
        if gitHubSettingObserver == nil {
            gitHubSettingObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, GitHubSettings.enabled != self.gitHubWasEnabled else { return }
                    self.gitHubSettingChanged()
                }
            }
        }
        gitHubSettingChanged()
    }

    /// Start or stop the integration for the open folder, as the Settings switch says.
    private func gitHubSettingChanged() {
        gitHubWasEnabled = GitHubSettings.enabled
        if GitHubSettings.enabled, let root = gitHubRoot {
            gitHub.setup(root: root)
            if !gitClient.branch.isEmpty { gitHub.branchChanged(gitClient.branch) }
        } else {
            gitHub.reset()
        }
    }

    /// Open (or switch to) the editor tab of a workflow run or an issue.
    func openGitHubTab(_ item: GitHubItem) {
        guard let root = rootNode?.url ?? gitHub.root else { return }
        layout.workspaceArea = .files
        layout.workSection = .git
        switch item {
        case .issue: layout.gitSection = .issues
        case .pullRequest: layout.gitSection = .pullRequests
        case .run: layout.gitSection = .actions
        }
        chrome.showCenter = true
        let url = root.appendingPathComponent(item.marker)
        if tabs.selectTab(matching: url) != nil { return }
        var tab = OpenTab(url: url, content: "", originalContent: "")
        tab.kind = .github(item)
        tabs.appendTab(tab)
    }

    /// Work on a pull request's code: check its branch out, refusing when the working tree
    /// has changes (nothing is stashed or overwritten). Returns an error to show.
    func checkoutPullRequest(_ number: Int) async -> String? {
        guard let root = gitClient.workingDirectory ?? rootNode?.url else { return "No folder open." }
        // Tracked changes only: untracked files (like MarkView's own .dde) do not block a
        // checkout, and git itself refuses one that would overwrite them.
        let status = await GitHubClient.execute(["status", "--porcelain", "--untracked-files=no"], in: root, git: true)
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The working tree has uncommitted changes. Commit or discard them before checking out PR #\(number)."
        }
        let error = await gitHub.perform("Checkout #\(number)") { try await $0.checkout(number) }
        await gitClient.refresh()
        refreshFileTree()
        return error
    }

    /// Check out a branch from the branch menu. Returns an error to show.
    func switchBranch(_ name: String) async -> String? {
        let error = await gitClient.switchBranch(name)
        branchChanged()
        return error
    }

    /// Create a branch from the branch menu and check it out. Returns an error to show.
    func createBranch(_ name: String, from base: String?) async -> String? {
        let error = await gitClient.createBranch(name, from: base)
        branchChanged()
        return error
    }

    /// The working copy now holds another branch's files: show them in the tree and open tabs.
    private func branchChanged() {
        refreshFileTree()
        Task { await tabs.reloadChangedOpenFiles(all: true) }
    }

    /// The branch a pull request comes from, when it is the one checked out.
    private func isCheckedOut(_ number: Int) async -> Bool {
        guard let client = gitHub.client, let pr = try? await client.pullRequest(number) else { return false }
        return pr.headRefName == gitClient.branch
    }

    /// Send a fix request for a pull request's code to the AI terminal, after checking its
    /// branch out when needed. Returns an error to show.
    func fixInPullRequest(_ number: Int?, prompt: String) async -> String? {
        var prompt = prompt
        if let number, gitHub.client != nil {
            if !(await isCheckedOut(number)), let error = await checkoutPullRequest(number) { return error }
        } else if let number {
            // Without the GitHub integration the branch is not checked out for the AI.
            prompt += "\n\nNote: this is pull request #\(number); its branch may not be the one checked out here."
        }
        terminals.sendToAssistant(prompt, submit: true)
        return nil
    }

    /// "Start with AI" on an issue: a branch for it, then the issue to the AI terminal.
    func startIssueWithAI(_ issue: GHIssue) async -> String? {
        guard let root = gitClient.workingDirectory ?? rootNode?.url else { return "No folder open." }
        let slug = String(issue.title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .split(separator: "-").prefix(6).joined(separator: "-")
        let branch = "issue-\(issue.number)" + (slug.isEmpty ? "" : "-" + slug)
        let exists = await GitHubClient.execute(["rev-parse", "--verify", "--quiet", branch], in: root, git: true)
        let result = await GitHubClient.execute(exists.status == 0 ? ["switch", branch] : ["switch", "-c", branch], in: root, git: true)
        if result.status != 0 {
            return "Could not switch to \(branch): " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        await gitClient.refresh()
        var prompt = "Work on GitHub issue #\(issue.number) of \(gitHub.selectedRepo?.slug ?? "this repository"): \(issue.title)\n\n"
        prompt += (issue.body ?? "").isEmpty ? "(no description)" : issue.body!
        let comments = (issue.comments ?? []).suffix(10)
        if !comments.isEmpty {
            prompt += "\n\nComments:\n" + comments.map { "- \($0.author?.login ?? "someone"): \($0.body)" }.joined(separator: "\n")
        }
        prompt += "\n\nYou are on branch \(branch). Investigate, implement the change, and summarise what you did."
        terminals.sendToAssistant(prompt, submit: true)
        return nil
    }

    /// "Fix with AI" on a failed run: its failed steps' logs to the AI terminal.
    func fixRunWithAI(_ model: GitHubRunModel) {
        Task {
            await model.loadFailedLogs()
            var prompt = model.failureText()
            if let run = model.run, run.headBranch != gitClient.branch {
                prompt += "\nNote: the run was on branch \(run.headBranch); the working copy is on \(gitClient.branch)."
            }
            prompt += "\nFind the cause in this repository and fix it."
            terminals.sendToAssistant(prompt, submit: true)
        }
    }

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

    // MARK: - Browser and web app preview

    /// A picked page element goes into the AI terminal's input line as text (page, selector,
    /// screenshot path, HTML) and, for pasting by hand, onto the clipboard as image plus text.
    func sendPickedElement(_ element: PickedElement, screenshot: URL?, from session: BrowserSession?) {
        let message = BrowserElementPick.message(for: element, screenshot: screenshot)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let screenshot, let image = NSImage(contentsOf: screenshot) { pasteboard.writeObjects([image]) }
        pasteboard.setString(message, forType: .string)
        let shot = screenshot == nil ? " (no screenshot: the element is off screen)" : ""
        if let terminal = terminals.shown {
            terminal.paste(message + "\n")
            session?.pickNotice = "Sent \(element.tag) to the AI input\(shot)"
        } else {
            session?.pickNotice = "No AI terminal is open — \(element.tag) is on the clipboard\(shot)"
        }
    }

    /// Open a browser tab (an empty one for nil), next to the files.
    @discardableResult
    func openBrowser(_ url: URL?, activate: Bool = true) -> BrowserSession {
        let session = BrowserSession(url: url)
        session.agentName = BrowserAgentTools.nextTabName(taken: browserSessions.map(\.agentName))
        session.onOpenInNewTab = { [weak self] url in self?.openBrowser(url) }
        session.onSaveMarkdown = { [weak session] mode in session?.saveRequest = mode }
        session.onElementPicked = { [weak self, weak session] element, screenshot in
            self?.sendPickedElement(element, screenshot: screenshot, from: session)
        }
        let base = rootNode?.url ?? FileManager.default.temporaryDirectory
        var tab = OpenTab(url: base.appendingPathComponent(ProjectPaths.placeholderName("browser-" + session.id.uuidString)),
                          content: "", originalContent: "")
        tab.kind = .browser(session)
        if activate {
            layout.workspaceArea = .files
            chrome.showCenter = true
        }
        tabs.appendTab(tab, activate: activate)
        return session
    }

    // MARK: - UI Studio

    /// The tab of a new UI Studio session on the project's real web interface (REQ-001); `openTool` shows the session already open instead.
    private func makeUIStudioTab(root: URL, tool: ToolDescriptor) -> OpenTab {
        let session = StudioSession(root: root)
        let base = root.standardizedFileURL.path + "/"
        session.editorBuffers = { [weak self] in
            var buffers: [String: String] = [:]
            for tab in self?.openTabs ?? [] where tab.isFileBacked && tab.isModified {
                let path = tab.url.standardizedFileURL.path
                if path.hasPrefix(base) { buffers[String(path.dropFirst(base.count))] = tab.content }
            }
            return buffers
        }
        session.recordUsage = { [weak self] input, output, cost in
            guard let db = self?.semanticDatabase else { return }
            Task { await db.addUsage(inputTokens: input, outputTokens: output, costCents: cost * 100) }
        }
        session.openFile = { [weak self] url in self?.openFile(url) }
        session.featureStore = { [weak self] in self?.features }
        session.onFeatureExported = { [weak self] slug in self?.showFeatureContext(slug) }
        var tab = OpenTab(url: tool.sentinelURL(in: root, suffix: session.id.uuidString), content: "", originalContent: "")
        tab.kind = .uiStudio(session)
        return tab
    }

    // MARK: - Prototype Studio


    /// Opens the creator sheet of Prototype Studio for requirements; `.code` ("New Prototype from Code…") opens UI Studio
    /// on the real application instead of generating a reconstruction (REQ-001).
    func openPrototypeCreator(mode: PrototypeFiles.Mode) {
        guard mode == .requirements else { return openTool(.uiStudio) }
        requests.prototypeCreatorMode = mode
        requests.showPrototypeCreator = true
    }

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

    /// Prototypes saved in the open project, newest first.
    func savedPrototypes() -> [SavedPrototype] {
        guard let root = rootNode?.url else { return [] }
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
    func newPrototype(title: String, brief: String, sources: [String], mode: PrototypeFiles.Mode = .requirements,
                      codeScope: PrototypeAI.CodeScope = PrototypeAI.CodeScope()) {
        // Existing code is not reconstructed any more: it opens in UI Studio (DEC-002, DEC-005).
        guard mode == .requirements else { return openTool(.uiStudio) }
        guard let root = rootNode?.url else { return }
        let session = PrototypeSession(root: root, title: title, brief: brief, sources: sources, mode: mode)
        session.codeScope = codeScope
        openPrototype(session)
    }

    /// The tab of the Cockpit of this window: the window keeps one session for its project, so a tab closed and opened again
    /// shows the same plans and runs (`openTool` shows the tab already open instead).
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

    /// Discussions → ask: the project's assistant reads the project (read-only) and answers inside the conversation,
    /// in the form the question needs. The answer streams into `discussions.live`, then becomes a turn.
    func askDiscussion(_ slug: String, question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = rootNode?.url, !text.isEmpty, discussions.asking == nil,
              let discussion = discussions.discussions.first(where: { $0.slug == slug }) else { return }
        discussions.asking = slug
        discussions.live = DiscussionStore.Live(question: text)
        discussions.lastError = nil
        let scope = discussionScope(discussion, root: root)
        var request = CLICompletion.Request(
            project: aiProject ?? root,
            prompt: DiscussionPrompt.prompt(discussion: discussion, question: text, scope: scope.description,
                                            language: ActionOutputLanguage.explanationLine()),
            systemPrompt: DiscussionPrompt.system, readableFolder: scope.readable)
        if scope.readable.standardizedFileURL != root.standardizedFileURL { request.extraReadableFolders = [root] }
        request.effort = "medium"
        request.timeout = 900
        request.label = "discussion"
        discussionTask = Task { [weak self] in
            defer { Task { @MainActor in self?.discussionTask = nil } }
            do {
                let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(request, name: "discussion", onDelta: { [weak self] delta in
                    Task { @MainActor in
                        guard let self, self.discussions.asking == slug else { return }
                        self.discussions.live?.text += delta
                        self.discussions.live?.status = "Writing the answer"
                    }
                }, onActivity: { [weak self] activity in
                    Task { @MainActor in
                        guard let self, self.discussions.asking == slug else { return }
                        switch activity {
                        case .read(let path): self.discussions.live?.status = DiscussionPrompt.status(read: path); self.discussions.live?.text = ""
                        case .search(let pattern): self.discussions.live?.status = "Searching for \(pattern.prefix(40))"; self.discussions.live?.text = ""
                        case .run: self.discussions.live?.status = "Looking at the project"; self.discussions.live?.text = ""
                        case .webSearch, .webFetch: self.discussions.live?.status = "Reading the web"; self.discussions.live?.text = ""
                        case .thinking: self.discussions.live?.status = "Thinking"
                        case .writing, .answerDelta: break
                        }
                    }
                })
                try Task.checkCancellation()
                await self?.finishDiscussionTurn(slug, question: text, text: result.text)
            } catch is CancellationError {
                await self?.stopDiscussionTurn(slug, keep: nil)
            } catch {
                await self?.failDiscussionTurn(error.localizedDescription)
            }
        }
    }

    private func finishDiscussionTurn(_ slug: String, question: String, text: String) {
        defer { discussions.asking = nil; discussions.live = nil }
        guard let answer = DiscussionPrompt.parse(text),
              discussions.addTurn(slug, question: question, answer: answer.answer, followUps: [],
                                  decisions: answer.decisions, openQuestions: answer.openQuestions) != nil else {
            discussions.lastError = "The assistant gave no answer."
            return
        }
    }

    private func stopDiscussionTurn(_ slug: String, keep: String?) {
        discussions.asking = nil
        discussions.live = nil
    }

    private func failDiscussionTurn(_ message: String) {
        discussions.lastError = message
        discussions.asking = nil
        discussions.live = nil
    }

    /// Stops the answer being written; what was written so far is dropped.
    func stopDiscussion() { discussionTask?.cancel() }

    /// Where the conversation looks: the text the assistant is told, and the folder it may read.
    private func discussionScope(_ discussion: Discussion, root: URL) -> (description: String, readable: URL) {
        let raw = discussion.scope ?? ""
        guard !raw.isEmpty else { return ("The whole project (\(root.lastPathComponent))", root) }
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ("The whole project (\(root.lastPathComponent)); the chosen path \(raw) no longer exists", root)
        }
        let inside = url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
        let readable = inside ? root : (isDirectory.boolValue ? url : url.deletingLastPathComponent())
        return ("\(isDirectory.boolValue ? "The folder" : "The file") `\(raw)`. Stay on it; look elsewhere only when it is needed to answer.", readable)
    }

    /// File tree → "Discuss…": a discussion about this file or folder.
    func openDiscussion(about url: URL) {
        guard let root = rootNode?.url else { return }
        openTool(.discussions)
        let rel = project.relativePath(of: url)
        let path = url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") ? rel : url.path
        if let existing = discussions.discussions.first(where: { $0.scope == path && $0.turns.isEmpty }) {
            discussions.selectedSlug = existing.slug
        } else {
            discussions.create(title: url.lastPathComponent, scope: path)
        }
    }

    /// Deployments → "Ask AI to find where it runs": the assistant reads the project and proposes environments.
    func analyzeDeploymentsWithAI() {
        guard let root = rootNode?.url else { return }
        guard !terminals.assistantIsBusy else { deployments.lastError = "The assistant is still working."; return }
        let prompt = DeploymentPrompt.analyze(project: root.lastPathComponent, existing: deployments.environments.map(\.name), hasMCP: true)
        terminals.sendToAssistant(prompt, submit: true)
    }

    /// Deployments → "Ask the AI": a question about one environment goes to the assistant with what MarkView
    /// last saw (and the log being read); it looks with the markview_deployments tools.
    func askAboutDeployment(_ id: String, question: String, logTitle: String? = nil, log: String? = nil) {
        guard let env = deployments.environment(id) else { return }
        guard !terminals.assistantIsBusy else { deployments.lastError = "The assistant is still working."; return }
        let prompt = DeploymentPrompt.ask(environment: env.name, id: env.id, question: question, report: deployments.report(for: id), logTitle: logTitle, log: log)
        terminals.sendToAssistant(prompt, submit: true)
    }

    func openSavedPrototype(_ slug: String) {
        guard let root = rootNode?.url else { return }
        for index in openTabs.indices {
            if case .prototype(let session) = openTabs[index].kind, session.manifest.slug == slug {
                activeTabIndex = index
                return
            }
        }
        if let session = PrototypeSession(root: root, slug: slug) { openPrototype(session) }
    }

    private func openPrototype(_ session: PrototypeSession) {
        session.record = { [weak self] result in result.record(in: self?.semanticDatabase) }
        session.languageNote = ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage
            ? "" : "\n\nWrite every label, text and message in the prototype in \(ActionOutputLanguage.current)."
        var tab = OpenTab(url: session.folder.appendingPathComponent(ProjectPaths.placeholderName("prototype-" + session.id.uuidString)),
                          content: "", originalContent: "")
        tab.kind = .prototype(session)
        layout.workspaceArea = .files
        chrome.showCenter = true
        tabs.appendTab(tab, activate: true)
    }

    /// Show a local HTML file in a browser tab: the tab already showing it is reloaded, else a new
    /// one opens. The page may read the project's files, so relative stylesheets and scripts load.
    func openHTMLInBrowser(_ file: URL) {
        let file = file.standardizedFileURL
        guard FileType.isHTML(file), FileManager.default.fileExists(atPath: file.path) else { return }
        layout.workspaceArea = .files
        chrome.showCenter = true
        for index in openTabs.indices {
            if case .browser(let session) = openTabs[index].kind, session.url?.standardizedFileURL == file {
                activeTabIndex = index
                session.load(file)
                return
            }
        }
        let session = openBrowser(nil)
        session.localReadRoot = project.containerRoot(for: file)
        session.load(file)
    }

    /// A page a terminal program opened: shown in this window's browser, reusing a tab rather than
    /// adding one — the tab already on the same server, else the active, preview or first browser tab.
    func openInAppBrowser(_ url: URL) {
        let candidates: [(index: Int, session: BrowserSession)] = openTabs.indices.compactMap { index in
            if case .browser(let session) = openTabs[index].kind { return (index, session) }
            return nil
        }
        let sameServer = { (session: BrowserSession) in
            session.url?.host == url.host && session.url?.port == url.port && session.url?.scheme == url.scheme
        }
        let chosen = candidates.first { sameServer($0.session) }
            ?? candidates.first { $0.index == activeTabIndex }
            ?? candidates.first { $0.session.isAppPreview }
            ?? candidates.first
        layout.workspaceArea = .files
        chrome.showCenter = true
        if let chosen {
            activeTabIndex = chosen.index
            chosen.session.load(url)
        } else {
            openBrowser(url)
        }
    }

    /// Preview Web App: the project's web app in a browser tab. A development server that
    /// already answers is shown at once; otherwise the app's dev script runs in a terminal
    /// tab and the tab shows the server as soon as it prints its address or a port answers.
    func previewWebApp() {
        if let index = openTabs.firstIndex(where: { tab in
            if case .browser(let session) = tab.kind { return session.isAppPreview }
            return false
        }), case .browser(let session) = openTabs[index].kind {
            // One preview tab per window: bring it back and look again.
            activeTabIndex = index
            layout.workspaceArea = .files
            chrome.showCenter = true
            findWebApp(for: session)
            return
        }
        let session = openBrowser(nil)
        findWebApp(for: session)
    }

    private func findWebApp(for session: BrowserSession) {
        session.isAppPreview = true
        session.preview = .searching
        session.startWebApp = { [weak self, weak session] target in
            guard let self, let session else { return }
            self.startWebApp(target, in: session)
        }
        session.showTerminal = { [weak self, weak session] in
            guard let self, let session else { return }
            self.showPreviewTerminal(for: session)
        }
        guard let root = rootNode?.url else {
            session.preview = .noApp
            return
        }
        Task { @MainActor in
            let targets = await Task.detached { WebAppPreview.targets(root: root) }.value
            switch targets.count {
            case 0:
                if let url = await WebAppPreview.firstAnswering(WebAppPreview.commonPorts) {
                    session.showPreview(url)
                } else {
                    session.preview = .noApp
                }
            case 1:
                startWebApp(targets[0], in: session)
            default:
                session.preview = .choose(targets)
            }
        }
    }

    /// Show `target` in `session`: at once when its server answers, else after starting it.
    func startWebApp(_ target: WebAppTarget, in session: BrowserSession) {
        session.preview = .starting(target, started: false)
        if target.isElectron { session.standInForElectron() }
        Task { @MainActor in
            if !target.reuseRunningServer, let occupied = await WebAppPreview.firstListening(target.ports) {
                session.preview = .portInUse(target, occupied.port ?? 0)
                return
            }
            if target.reuseRunningServer, let url = await WebAppPreview.firstAnswering(target.ports) {
                session.showPreview(url)
                return
            }
            let key = target.folder.standardizedFileURL.path
            let terminal: TerminalSession
            if target.reuseRunningServer, let existing = terminals.previewTerminal(forApp: key) {
                terminal = existing
            } else {
                terminal = openTerminal(in: target.folder, startupCommand: target.command,
                                        title: "Dev server", activate: false)
                if target.reuseRunningServer { terminals.rememberPreviewTerminal(terminal, forApp: key) }
                // A terminal tab starts its shell when its page is shown; this one starts now and
                // keeps the output until the tab is opened.
                terminal.start()
            }
            session.previewTerminalID = terminal.id
            session.preview = .starting(target, started: true)
            let watch = DevServerWatch()
            terminal.onOutput = { [weak watch] data in watch?.read(data) }
            defer { terminal.onOutput = nil }
            let deadline = Date().addingTimeInterval(180)
            var round = 0
            while Date() < deadline {
                guard !session.isClosed, case .starting = session.preview else { return }
                if let url = watch.url, await WebAppPreview.firstAnswering([url.port ?? 80], timeout: 1) != nil {
                    session.showPreview(url)
                    return
                }
                if round % 3 == 0, let url = await WebAppPreview.firstAnswering(target.ports) {
                    session.showPreview(url)
                    return
                }
                round += 1
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            if case .starting = session.preview { session.preview = .timedOut(target) }
        }
    }

    private func showPreviewTerminal(for session: BrowserSession) {
        guard let id = session.previewTerminalID,
              let index = openTabs.firstIndex(where: { tab in
                  if case .terminal(let terminal) = tab.kind { return terminal == id }
                  return false
              }) else { return }
        activeTabIndex = index
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
    func terminalStarted() { tabs.startWatchingOpenFiles() }
}

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
    var defaultAuthor: String { features.defaultOwner }

    func openTabContent(for url: URL) -> String? { tabs.content(ofOpen: url) }

    func scrollToText(_ text: String) {
        NotificationCenter.default.post(.scrollToText, for: self, object: text)
    }

    func startRecursiveInsight(at target: URL?, title: String?) { insight.start(at: target, title: title) }

    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? { terminals.sendToAssistant(prompt, submit: submit) }

    /// Bring the X-Ray tab of `scope` to the front, opening it when it is not there yet.
    func showXRayTab(scope: String, root: URL) {
        layout.workspaceArea = .projectMap
        tabs.showArchitectureTab(scope: scope, root: root)
    }
}
