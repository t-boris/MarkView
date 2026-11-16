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

/// The observable face of one window. The window is made of parts (tabs, panels, project, terminals, browser, X-Ray, feature flow, ...)
/// built in one place, `WindowComposition` (`AR-17`); this class holds them for the views that observe it, conforms to the narrow host
/// protocols the parts ask of their window, and carries the window's own commands: open or close a folder, open a file in its ways,
/// remove the folder's metadata.
@MainActor
class WorkspaceManager: ObservableObject, FeatureFlowTabs, WindowSessionWindow, ToolTabsWindow {
    /// How this window and its parts ask the person a question or tell them something (`AR-22`): given by the app when the window is made.
    let prompts: any UserPrompts
    /// The parts of this window. The one late binding of the window: each part is given this object through its own narrow protocol.
    private(set) lazy var composition = WindowComposition(host: self, prompts: prompts)

    var project: ProjectContext { composition.project }
    var layout: PanelLayout { composition.layout }
    var windowUI: WindowUIState { composition.windowUI }
    var chrome: WindowChrome { composition.chrome }
    var requests: WindowRequests { composition.requests }
    var theme: WindowTheme { composition.theme }
    var tabs: TabsController { composition.tabs }
    var taskBag: TaskBag { composition.taskBag }
    var polling: PollingScheduler { composition.polling }
    var aiJobs: AIToolJobs { composition.aiJobs }
    var gitClient: GitClient { composition.gitClient }
    var research: ResearchMapController { composition.research }
    var flow: FeatureFlowCoordinator { composition.flow }
    var fileOperations: FileOperationsController { composition.fileOperations }
    var translator: DocumentTranslator { composition.translator }
    var terminals: AITerminalsController { composition.terminals }
    var browser: BrowserHost { composition.browser }
    var codeXRay: CodeAndXRayCoordinator { composition.codeXRay }
    var insight: InsightCoordinator { composition.insight }
    var toolTabs: ToolTabsRouter { composition.toolTabs }

    // MARK: - Tool tabs

    /// Opens the tab of a tool of `ToolRegistry`, or returns to it.
    func openTool(_ id: ToolID) { toolTabs.open(id) }

    /// The project's operations, with this window as the one that shows what the person starts from here.
    func operations() -> ProjectOperationsStore? {
        projectOperations?.presenter = self
        return projectOperations
    }

    /// Files opened from outside the app on their own (Finder, Quick Action): the documents, nothing around them.
    func openDocumentsOnly(_ urls: [URL]) {
        for url in urls { openFile(url) }
        chrome.showDocumentOnly()
    }

    func presentPDFBook(_ urls: [URL]? = nil) {
        let sources: [URL]
        if let urls { sources = urls }
        else if tabs.openTabs.indices.contains(tabs.activeTabIndex), case .file = tabs.openTabs[tabs.activeTabIndex].kind { sources = [tabs.openTabs[tabs.activeTabIndex].url] }
        else { sources = [] }
        requests.pdfBookSelection = BookPDFSelection(urls: sources)
    }

    var pdfBookDrafts: [String: String] {
        var result: [String: String] = [:]
        for tab in tabs.openTabs where tab.isModified { if case .file = tab.kind { result[tab.url.path] = tab.content } }
        return result
    }
    /// Team-shared operation definitions and the process registry for this workspace root.
    @Published private(set) var projectOperations: ProjectOperationsStore?
    private var cancellables: Set<AnyCancellable> = []

    // The project is read through `project` (`ProjectProviding`). These four read-only aliases stay for the code of the regions
    // that the other decompositions of this file (`AR-14` steps 2-7) are still moving out, and go with them.
    var rootNode: FileNode? { project.rootNode }
    var projectFolder: URL? { project.projectFolder }
    var aiProject: URL? { project.aiProject }
    var semanticDatabase: SemanticDatabase? { project.database }

    /// The tab the person is looking at. A view that shows tabs observes `tabs` itself: reading them through the manager would not
    /// redraw it (`AR-15`).
    var activeTab: OpenTab? { tabs.activeTab }

    func showGitHubTab(_ item: GitHubItem, root: URL) { tabs.showGitHubTab(item, root: root) }

    /// `ToolTabsWindow`: the feature panel shown beside a document.
    func showFeatureContext(_ slug: String?) { flow.showFeatureContext(slug) }

    /// `WindowSessionHost`: a restored session shows the GitHub tab again.
    func openGitHubTab(_ item: GitHubItem) { flow.openGitHubTab(item) }

    func reloadChangedOpenFiles(all: Bool) async { await tabs.reloadChangedOpenFiles(all: all) }

    init(prompts: any UserPrompts) {
        self.prompts = prompts
        Self.debugLog("WorkspaceManager init START")
        composition.connect()
        composition.changes
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Self.debugLog("WorkspaceManager init DONE")
    }

    /// Write workspace diagnostic message to the unified system log (`AR-24`, `AR-42`).
    nonisolated static func debugLog(_ msg: String) {
        AppLog.workspace.debug("\(msg)")
    }

    func openFolder(_ url: URL, completion: (() -> Void)? = nil) {
        projectOperations = ProjectOperationsStore.forRoot(url, prompts: prompts)
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

    var sessionChanges: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.merge(with: composition.sessionChanges).eraseToAnyPublisher()
    }

    func windowWillClose() { composition.close() }

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
        let list = items.isEmpty ? "Nothing is stored yet." : items.map { "• " + $0.path.replacingOccurrences(of: root.path + "/", with: "") }.joined(separator: "\n")
        let removal = UserPrompt(
            title: recreate
                ? "Rebuild MarkView data for “\(root.lastPathComponent)”?"
                : "Remove MarkView data from “\(root.lastPathComponent)”?",
            detail: """
                \(list)

                The search index, architecture, AI descriptions, filters, file contents and Insight pages are deleted. \
                Your documents and code are not touched.\(recreate ? " The folder is then indexed and scanned again." : "")
                """,
            buttons: [recreate ? "Rebuild" : "Remove", "Cancel"])
        guard prompts.confirm(removal, proceedingWith: 0) else { return }

        // Stop everything that could still write into the folder.
        stopAllTerminals()
        project.stopIndexing()
        insight.cancelSessions()
        let keep = tabs.openTabs.enumerated().filter { $0.element.isFileBacked }.map(\.offset)
        for index in tabs.openTabs.indices.reversed() where !keep.contains(index) { tabs.removeTab(at: index) }
        releaseWorkspaceEngines()
        codeXRay.reset()

        let failures = project.deleteMetadata(items)
        if !failures.isEmpty {
            prompts.inform("Some items could not be deleted", failures.joined(separator: ", "))
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

    /// Open the PDF at `url` at `page`.
    func openPDF(_ url: URL, page: Int) {
        openFile(url)
        if case .pdf(let reader)? = tabs.activeTab?.kind { reader.openPageWhenReady(page) }
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
        if tabs.activeTabIndex >= 0, tabs.activeTabIndex < tabs.openTabs.count {
            let canvasDir = tabs.openTabs[tabs.activeTabIndex].url.deletingLastPathComponent()
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
                let stop = UserPrompt(
                    title: "Stop running project operations before closing?",
                    detail: active.map { $0.snapshot.label + ($0.snapshot.environment.map { " (\($0))" } ?? "") }.joined(separator: "\n"),
                    buttons: ["Keep working", "Stop operations and close"])
                guard prompts.confirm(stop, proceedingWith: 1) else { return false }
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
        guard tabs.resolveUnsavedChanges(at: Array(tabs.openTabs.indices), before: "closing the folder") else { return false }

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
    var isBlank: Bool { rootNode == nil && tabs.openTabs.isEmpty }

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
}

/// What the terminals read of the window: the browser agents drive, and the editor (`AITerminalsController`).
extension WorkspaceManager: FileOperationsHost {}

/// The commands a view of this window asks of the window as a whole (`AR-14`): the window puts itself in its views' environment.
extension WorkspaceManager: WindowCommands {
    func openFolder(_ url: URL) { openFolder(url, completion: nil) }

    func openTerminal(in folder: URL) { openTerminal(in: folder, startupCommand: nil, title: nil, activate: true) }

    func showSettings() { DDESettingsWindow.show(workspace: self) }
}

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
        guard let tab = tabs.openTabs.first(where: { $0.isFileBacked && $0.url.standardizedFileURL.path == path }) else { return nil }
        return ResearchTabText(text: tab.content, isModified: tab.isModified)
    }

    func researchTabSaved(_ file: URL, text: String) {
        let path = file.standardizedFileURL.path
        guard let index = tabs.openTabs.firstIndex(where: { $0.isFileBacked && $0.url.standardizedFileURL.path == path }) else { return }
        tabs.updateTab(at: index) { tab in
            tab.content = text
            tab.originalContent = text
            tab.isModified = false
        }
    }

    func researchEditorFile(documentID: UUID?, event: String) -> URL? {
        guard let index = tabs.editorTabIndex(documentID: documentID, event: event), tabs.openTabs[index].isFileBacked else { return nil }
        return tabs.openTabs[index].url
    }

    func researchWatchOpenFiles() { tabs.startWatchingOpenFiles() }

    func saveBeforeResearch(_ file: URL, action: String) -> Bool { tabs.saveBeforeReading(file, action: action) }

    func researchDocumentChanged(_ file: URL, content: String, applyToEdited: (String) -> String?) -> Bool {
        refreshFileTree()
        return tabs.fileRewritten(file, content: content, applyToEdited: applyToEdited)
    }

    func exportResearchPDF(_ markdown: String, fileName: String, near mapFile: URL) {
        PDFExporter.exportPDF(markdown: markdown, title: (fileName as NSString).deletingPathExtension, fileName: fileName,
                              baseURL: mapFile.deletingLastPathComponent(),
                              roots: DocumentFiles.roots(project: project.root, documents: tabs.openTabs.filter(\.isFileBacked).map(\.url)))
    }
}

/// What Recursive Insight reads of the window and does to its tabs (`InsightCoordinator`).
extension WorkspaceManager: InsightHost {
    var insightSessions: [InsightSession] {
        tabs.openTabs.compactMap { tab in
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
        guard let index = tabs.openTabs.firstIndex(where: {
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
    var activeXRayScope: String? {
        if case .architecture(let scope)? = tabs.activeTab?.kind { return scope }
        return nil
    }
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
