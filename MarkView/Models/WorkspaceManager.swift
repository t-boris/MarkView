import Foundation
import SwiftUI
import Combine

/// Owns file-tree state, exclusion rules, and file-system watching for the active workspace.
@MainActor
final class WorkspaceFileTreeStore: ObservableObject {
    @Published var rootNode: FileNode?
    @Published private(set) var excludedFolders: Set<String> = []
    @Published var sortOrder = FileTreeSortOrder() {
        didSet {
            UserDefaults.standard.set(sortOrder.field.rawValue, forKey: "fileTree.sortField")
            UserDefaults.standard.set(sortOrder.ascending, forKey: "fileTree.sortAscending")
            refresh()
        }
    }

    var shouldAutoRefresh: () -> Bool = { true }

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileWatchTimer: Timer?
    private var fileWatchDebounce: DispatchWorkItem?
    private var lastRootModDate: Date?

    init() {
        let ud = UserDefaults.standard
        if let savedField = ud.string(forKey: "fileTree.sortField"),
           let field = FileTreeSortField(rawValue: savedField) {
            sortOrder.field = field
        }
        if ud.object(forKey: "fileTree.sortAscending") != nil {
            sortOrder.ascending = ud.bool(forKey: "fileTree.sortAscending")
        }
    }

    func reset() {
        stopWatching()
        rootNode = nil
        excludedFolders = []
        lastRootModDate = nil
    }

    func setRootNode(_ node: FileNode?) {
        rootNode = node
        lastRootModDate = node.map { rootModificationDate(for: $0.url) } ?? nil
    }

    func loadExcludedFolders() {
        let key = "excludedFolders.\(rootNode?.url.lastPathComponent ?? "default")"
        if let saved = UserDefaults.standard.stringArray(forKey: key) {
            excludedFolders = Set(saved)
        } else {
            excludedFolders = []
        }
    }

    @discardableResult
    func excludeFolder(_ folderURL: URL) -> String? {
        guard let relativePath = relativePath(for: folderURL) else { return nil }
        excludedFolders.insert(relativePath)
        saveExcludedFolders()
        return relativePath
    }

    @discardableResult
    func includeFolder(_ relativePath: String) -> Bool {
        let removed = excludedFolders.remove(relativePath) != nil
        if removed {
            saveExcludedFolders()
        }
        return removed
    }

    func isExcluded(_ url: URL) -> Bool {
        guard let relativePath = relativePath(for: url) else { return false }
        return excludedFolders.contains { relativePath.hasPrefix($0) }
    }

    func refresh() {
        Self.log("refresh() called, rootNode=\(rootNode?.url.path ?? "nil")")
        // Clear all cached resource values for the root URL tree
        if let rootURL = rootNode?.url {
            (rootURL as NSURL).removeAllCachedResourceValues()
        }
        reloadFileTree()
    }

    func reveal(url: URL) {
        guard let root = rootNode else { return }
        expandToReveal(node: root, targetURL: url)
    }

    func startWatchingCurrentRoot() {
        guard let rootURL = rootNode?.url else { return }
        startFileWatcher(for: rootURL)
    }

    func stopWatching() {
        fileWatchDebounce?.cancel()
        fileWatchDebounce = nil
        fileWatchTimer?.invalidate()
        fileWatchTimer = nil
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private func saveExcludedFolders() {
        let key = "excludedFolders.\(rootNode?.url.lastPathComponent ?? "default")"
        UserDefaults.standard.set(Array(excludedFolders), forKey: key)
    }

    private func relativePath(for url: URL) -> String? {
        guard let root = rootNode?.url else { return nil }
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path

        if targetPath == rootPath { return "" }
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }
        return String(targetPath.dropFirst(rootPath.count + 1))
    }

    @discardableResult
    private func expandToReveal(node: FileNode, targetURL: URL) -> Bool {
        if node.url == targetURL { return true }
        guard node.isDirectory, targetURL.path.hasPrefix(node.url.path + "/") else { return false }

        if node.children == nil || node.children?.isEmpty == true {
            node.loadChildren()
        }
        node.isExpanded = true

        for child in node.children ?? [] {
            if expandToReveal(node: child, targetURL: targetURL) {
                return true
            }
        }
        return false
    }

    private func startFileWatcher(for url: URL) {
        stopWatching()
        lastRootModDate = rootModificationDate(for: url)

        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }

        let queue = DispatchQueue.main
        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )

        fileWatcher?.setEventHandler { [weak self] in
            guard let self else { return }
            self.fileWatchDebounce?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self, self.shouldAutoRefresh() else { return }
                self.reloadFileTree()
            }

            self.fileWatchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }

        fileWatcher?.setCancelHandler { close(fd) }
        fileWatcher?.resume()

        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkForFileTreeChanges()
        }
    }

    private func checkForFileTreeChanges() {
        guard let rootURL = rootNode?.url else { return }
        guard shouldAutoRefresh() else { return }
        // Clear cached resource values so we see fresh modification dates
        (rootURL as NSURL).removeCachedResourceValue(forKey: .contentModificationDateKey)
        guard let modDate = rootModificationDate(for: rootURL) else { return }

        if modDate != lastRootModDate {
            lastRootModDate = modDate
            reloadFileTree()
        }
    }

    private func reloadFileTree() {
        guard let currentRoot = rootNode else {
            Self.log("reloadFileTree: rootNode is nil, skipping")
            return
        }
        let rootURL = currentRoot.url
        Self.log("reloadFileTree: rebuilding from \(rootURL.path)")
        let expandedPaths = currentRoot.expandedDirectoryPaths()
        let sort = sortOrder

        // Clear URL resource cache so FileManager sees new files
        (rootURL as NSURL).removeCachedResourceValue(forKey: .contentModificationDateKey)

        Task.detached {
            let rebuilt = FileNode.buildTree(from: rootURL, sortOrder: sort)
            rebuilt.restoreExpansionState(from: expandedPaths, sortOrder: sort)
            let childCount = rebuilt.children?.count ?? 0
            Self.log("reloadFileTree: rebuilt with \(childCount) children")
            await MainActor.run {
                self.rootNode = rebuilt
                self.lastRootModDate = self.rootModificationDate(for: rootURL)
                Self.log("reloadFileTree: rootNode updated on MainActor")
            }
        }
    }

    private nonisolated static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [FileTree] \(msg)\n"
        let path = NSHomeDirectory() + "/markview_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func rootModificationDate(for url: URL) -> Date? {
        // Must clear cache — URL resource values are aggressively cached by Foundation
        (url as NSURL).removeCachedResourceValue(forKey: .contentModificationDateKey)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

/// Owns the open-tab session state for a workspace.
@MainActor
final class WorkspaceTabsStore: ObservableObject {
    @Published var openTabs: [OpenTab] = []
    @Published var activeTabIndex: Int = -1

    func reset() {
        openTabs = []
        activeTabIndex = -1
    }

    func firstIndex(of url: URL) -> Int? {
        openTabs.firstIndex(where: { $0.url == url })
    }

    @discardableResult
    func selectTab(matching url: URL) -> Int? {
        guard let index = firstIndex(of: url) else { return nil }
        activeTabIndex = index
        return index
    }

    func appendTab(_ tab: OpenTab, activate: Bool = true) {
        openTabs.append(tab)
        if activate {
            activeTabIndex = openTabs.count - 1
        }
    }

    func updateTab(at index: Int, _ mutate: (inout OpenTab) -> Void) {
        guard index >= 0 && index < openTabs.count else { return }
        var tab = openTabs[index]
        mutate(&tab)
        openTabs[index] = tab
    }

    func updateActiveTab(_ mutate: (inout OpenTab) -> Void) {
        updateTab(at: activeTabIndex, mutate)
    }

    func removeTab(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }
        openTabs.remove(at: index)
        normalizeActiveTabIndex(preferred: activeTabIndex)
    }

    func keepOnlyTab(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }
        let kept = openTabs[index]
        openTabs = [kept]
        activeTabIndex = 0
    }

    func keepTabs(through index: Int) {
        guard index >= 0 && index < openTabs.count else { return }
        openTabs = Array(openTabs.prefix(index + 1))
        normalizeActiveTabIndex(preferred: activeTabIndex)
    }

    func normalizeActiveTabIndex(preferred: Int? = nil) {
        let candidate = preferred ?? activeTabIndex

        guard !openTabs.isEmpty else {
            activeTabIndex = -1
            return
        }

        activeTabIndex = min(max(candidate, 0), openTabs.count - 1)
    }
}

enum WorkspaceAITool: String {
    case architecture
    case dataflow
    case pipeline
    case deployment
    case sequence
    case er
    case critic
    case research
    case audit
    case codemap
    case fulldocs

    var opensGraphCreator: Bool {
        switch self {
        case .architecture, .dataflow, .pipeline, .deployment, .sequence, .er:
            return true
        case .critic, .research, .audit, .codemap, .fulldocs:
            return false
        }
    }
}

/// Manages the workspace state including open files, tabs, and folder structure
@MainActor
class WorkspaceManager: ObservableObject {
    @Published var recentFiles: [URL] = []
    @Published var showFileTree: Bool = true {
        didSet { UserDefaults.standard.set(showFileTree, forKey: "layout.showFileTree") }
    }
    @Published var showTOC: Bool = true {
        didSet { UserDefaults.standard.set(showTOC, forKey: "layout.showTOC") }
    }
    @Published var showSemanticPanel: Bool = false {
        didSet { UserDefaults.standard.set(showSemanticPanel, forKey: "layout.showSemanticPanel") }
    }
    @Published var semanticDatabase: SemanticDatabase?
    @Published var incrementalCompiler: IncrementalCompiler?
    @Published var actionEngine: ActionEngine?
    @Published var researchEngine: ResearchEngine?
    @Published var hybridSearch: HybridSearch?
    @Published var embeddingClient = EmbeddingClient()
    @Published var ollamaClient = OllamaClient()
    @Published var gitClient = GitClient()
    @Published var aiConsoleEngine: AIConsoleEngine?
    @Published var implementEngine: ImplementEngine?
    @Published var testGenerator: TestGenerator?
    @Published var graphRAG: GraphRAG?
    @Published var providerRouter: ProviderRouter?
    @Published var indexingProgress: String?
    @Published var analysisStage: String?
    @Published var analysisDetail: String?
    @Published var totalFilesInWorkspace: Int = 0
    @Published var analyzedFiles: Int = 0
    @Published var softwareArchMermaid: String?
    @Published var dataFlowMermaid: String?
    @Published var deploymentMermaid: String?
    @Published var semanticRefreshVersion: Int = 0
    @Published var themeVersion: Int = 0
    @Published var activeDiagramGenerationModes: Set<String> = []
    @Published var diagramPrompts: [String: String] = AIProviderClient.defaultDiagramPrompts
    @Published var pendingGraphCreatorType: String?
    private let fileTreeStore = WorkspaceFileTreeStore()
    private let tabsStore = WorkspaceTabsStore()
    private var cancellables: Set<AnyCancellable> = []
    private var recentFilesURL: URL

    var rootNode: FileNode? {
        get { fileTreeStore.rootNode }
        set { fileTreeStore.setRootNode(newValue) }
    }

    var openTabs: [OpenTab] {
        get { tabsStore.openTabs }
        set { tabsStore.openTabs = newValue }
    }

    var activeTabIndex: Int {
        get { tabsStore.activeTabIndex }
        set { tabsStore.activeTabIndex = newValue }
    }

    var activeTab: OpenTab? {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return nil }
        return openTabs[activeTabIndex]
    }

    init() {
        Self.debugLog("WorkspaceManager init START")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupport.appendingPathComponent("MarkView", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        recentFilesURL = appDir.appendingPathComponent("recentFiles.json")

        // Restore layout from UserDefaults
        let ud = UserDefaults.standard
        if ud.object(forKey: "layout.showFileTree") != nil {
            showFileTree = ud.bool(forKey: "layout.showFileTree")
        }
        if ud.object(forKey: "layout.showTOC") != nil {
            showTOC = ud.bool(forKey: "layout.showTOC")
        }
        if ud.object(forKey: "layout.showSemanticPanel") != nil {
            showSemanticPanel = ud.bool(forKey: "layout.showSemanticPanel")
        }

        loadRecentFiles()
        fileTreeStore.shouldAutoRefresh = { [weak self] in
            self?.indexingProgress == nil
        }
        fileTreeStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        tabsStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        Self.debugLog("WorkspaceManager init DONE")
    }

    /// Open a folder and set it as the root node
    /// Write debug log to /tmp/markview_debug.log
    static func debugLog(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        let path = NSHomeDirectory() + "/markview_debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func openFolder(_ url: URL) {
        fileTreeStore.reset()  // Clear previous tree so progress spinner is shown
        tabsStore.reset()
        indexingProgress = "Loading folder structure..."
        Self.debugLog("openFolder START: \(url.path)")

        // Run setup steps asynchronously — sleep briefly to let SwiftUI render each step
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms — let UI render progress
            Self.debugLog("Task started, building tree...")

            // Build tree on background thread to avoid blocking UI
            let sort = self.fileTreeStore.sortOrder
            let node = await Task.detached {
                FileNode.buildTree(from: url, sortOrder: sort)
            }.value
            self.fileTreeStore.setRootNode(node)
            self.fileTreeStore.loadExcludedFolders()
            Self.debugLog("Tree loaded: \(node.children?.count ?? 0) children")

            indexingProgress = "Setting up workspace..."
            try? await Task.sleep(nanoseconds: 100_000_000)

            self.fileTreeStore.startWatchingCurrentRoot()
            addRecentFile(url)
            Self.debugLog("File watcher started, calling initDDEWorkspaceAsync...")

            await initDDEWorkspaceAsync(at: url)
            Self.debugLog("openFolder COMPLETE")
        }
    }

    /// Initialize .dde/ workspace structure and SQLite database — async to keep UI responsive
    private func initDDEWorkspaceAsync(at url: URL) async {
        let fm = FileManager.default
        let ddeRoot = url.appendingPathComponent(".dde")

        indexingProgress = "Creating workspace structure..."
        Self.debugLog("initDDE: creating dirs...")
        try? await Task.sleep(nanoseconds: 100_000_000)

        for subdir in ["cache/provider_responses", "cache/embeddings", "cache/indexes", "overlays"] {
            let dir = ddeRoot.appendingPathComponent(subdir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        indexingProgress = "Opening database..."
        Self.debugLog("initDDE: opening database...")
        try? await Task.sleep(nanoseconds: 100_000_000)

        do {
            let db = try SemanticDatabase(workspacePath: url)
            Self.debugLog("initDDE: database opened")
            let projectId = url.lastPathComponent
            try db.ensureProject(id: projectId, name: url.lastPathComponent, rootPath: url.path)
            self.semanticDatabase = db

            indexingProgress = "Initializing engines..."
            Self.debugLog("initDDE: creating engines...")
            try? await Task.sleep(nanoseconds: 100_000_000)

            self.incrementalCompiler = IncrementalCompiler(workspacePath: url, database: db)
            let provider = incrementalCompiler!.orchestrator.providerClient
            self.actionEngine = ActionEngine(db: db, providerClient: provider)
            let hs = HybridSearch(db: db, embeddingClient: embeddingClient, workspacePath: url)
            self.hybridSearch = hs
            self.researchEngine = ResearchEngine(db: db, hybridSearch: hs, providerClient: provider)
            self.implementEngine = ImplementEngine(db: db, providerClient: provider)
            self.testGenerator = TestGenerator(db: db, providerClient: provider)
            self.graphRAG = GraphRAG(db: db, providerClient: provider)
            self.providerRouter = ProviderRouter(anthropicClient: provider, embeddingClient: embeddingClient)
            let aiEngine = AIConsoleEngine(workspaceRoot: url, db: db)
            aiEngine.onFilesChanged = { [weak self] files in
                self?.handleClaudeFileChanges(files)
            }
            self.aiConsoleEngine = aiEngine
            Self.debugLog("initDDE: engines created")

            indexingProgress = "Connecting services..."
            try? await Task.sleep(nanoseconds: 100_000_000)

            Task { await ollamaClient.checkConnection() }
            gitClient.setup(at: url)
            Self.debugLog("initDDE: git setup done")

            // Load cached diagrams and analysis results from database
            loadCachedResults()
            ensureArchitectureDiagrams()

            // Structural indexing runs silently in background — no progress indicator
            indexingProgress = nil
            runStructuralIndex(at: url)
            Self.debugLog("initDDE: structural index started")

        } catch {
            Self.debugLog("initDDE: ERROR: \(error)")
            indexingProgress = nil
        }
    }

    /// Open a file in a new tab or switch to existing tab
    /// Open or refresh a file — if already open, reload content from disk
    // MARK: - Folder Exclusion

    /// Exclude a folder — removes all its entities from the DB
    func excludeFolder(_ folderURL: URL) {
        guard let relativePath = fileTreeStore.excludeFolder(folderURL) else { return }

        // Remove all DB entities for files in this folder
        guard let db = semanticDatabase else { return }
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "md" else { continue }
                let docId = url.lastPathComponent
                db.clearSymbols(forDocument: docId, kind: "heading")
                db.clearSymbols(forDocument: docId, kind: "link")
                db.clearSymbols(forDocument: docId, kind: "code_block")
                db.clearExtractedComponents(forDocument: docId)
                // Remove from FTS
                db.indexDocumentFTS(documentId: docId, title: "", content: "")
            }
        }
        // Remove directory modules for this path
        let modules = db.allModules()
        for mod in modules where mod.path.hasPrefix(folderURL.path) {
            db.clearSymbols(forDocument: mod.name, kind: "heading")
        }

        objectWillChange.send()
        NSLog("[DDE] Excluded folder: \(relativePath)")
    }

    /// Re-include a previously excluded folder
    func includeFolder(_ relativePath: String) {
        guard fileTreeStore.includeFolder(relativePath) else { return }
        // Re-index would happen on next Refresh
        objectWillChange.send()
        NSLog("[DDE] Re-included folder: \(relativePath)")
    }

    /// Check if a path is excluded
    func isExcluded(_ url: URL) -> Bool {
        fileTreeStore.isExcluded(url)
    }

    /// Handle files created/modified by Claude Code — auto-open and refresh tree
    private func handleClaudeFileChanges(_ relativePaths: [String]) {
        guard let root = rootNode?.url ?? aiConsoleEngine?.workspaceRoot else { return }

        // Refresh file tree
        refreshFileTree()

        // Open or refresh each changed file
        for relativePath in relativePaths {
            let fileURL = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            openOrRefreshFile(fileURL)
        }
    }

    func openOrRefreshFile(_ url: URL) {
        if let index = tabsStore.firstIndex(of: url) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                tabsStore.updateTab(at: index) { tab in
                    tab.content = content
                    tab.originalContent = content
                    tab.isModified = false
                }
                tabsStore.activeTabIndex = index
            }
        } else {
            openFile(url)
        }
    }

    func openFile(_ url: URL) {
        // Always init workspace for .md files if DB is missing or file is from different dir
        let isMD = url.pathExtension.lowercased() == "md"
        if isMD && !isFileInCurrentWorkspace(url) {
            initSingleFileWorkspace(fileURL: url)
        }

        // Check if file is already open
        if tabsStore.selectTab(matching: url) != nil {
            return
        }

        // Load file content
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var tab = OpenTab(url: url, content: content, originalContent: content)

            // Extract headings from markdown
            if url.pathExtension.lowercased() == "md" {
                tab.headings = extractHeadings(from: content)
            }

            tabsStore.appendTab(tab)
            addRecentFile(url)
        } catch {
            NSLog("Error opening file: \(error)")
        }
    }

    /// Check if a file belongs to the currently open workspace
    private func isFileInCurrentWorkspace(_ url: URL) -> Bool {
        guard semanticDatabase != nil else { return false }
        guard let root = rootNode else { return false }
        let filePath = url.standardizedFileURL.path
        let rootPath = root.url.standardizedFileURL.path
        return filePath.hasPrefix(rootPath)
    }

    /// Initialize workspace for a single .md file — DB named after the file, indexes only this file
    private func initSingleFileWorkspace(fileURL: URL) {
        let parentDir = fileURL.deletingLastPathComponent()
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let dbName = "file_\(fileName).db"

        NSLog("[DDE] initSingleFileWorkspace: file=\(fileURL.path) dir=\(parentDir.path) dbName=\(dbName)")

        // Close previous workspace
        semanticDatabase = nil
        researchEngine = nil
        actionEngine = nil
        hybridSearch = nil
        implementEngine = nil
        testGenerator = nil
        graphRAG = nil
        providerRouter = nil
        aiConsoleEngine = nil
        softwareArchMermaid = nil
        dataFlowMermaid = nil
        deploymentMermaid = nil

        do {
            let db = try SemanticDatabase(workspacePath: parentDir, dbName: dbName)
            let projectId = fileName
            try db.ensureProject(id: projectId, name: fileName, rootPath: parentDir.path)
            self.semanticDatabase = db
            self.incrementalCompiler = IncrementalCompiler(workspacePath: parentDir, database: db)
            let provider = incrementalCompiler!.orchestrator.providerClient
            self.actionEngine = ActionEngine(db: db, providerClient: provider)
            let hs = HybridSearch(db: db, embeddingClient: embeddingClient, workspacePath: parentDir)
            self.hybridSearch = hs
            self.researchEngine = ResearchEngine(db: db, hybridSearch: hs, providerClient: provider)
            self.implementEngine = ImplementEngine(db: db, providerClient: provider)
            self.testGenerator = TestGenerator(db: db, providerClient: provider)
            self.graphRAG = GraphRAG(db: db, providerClient: provider)
            self.providerRouter = ProviderRouter(anthropicClient: provider, embeddingClient: embeddingClient)
            let aiEngine = AIConsoleEngine(workspaceRoot: parentDir, db: db)
            aiEngine.onFilesChanged = { [weak self] files in
                self?.handleClaudeFileChanges(files)
            }
            self.aiConsoleEngine = aiEngine
            gitClient.setup(at: parentDir)

            // Build file tree showing just the parent dir
            if rootNode == nil {
                fileTreeStore.setRootNode(FileNode.buildTree(from: parentDir, sortOrder: fileTreeStore.sortOrder))
                fileTreeStore.loadExcludedFolders()
            }

            // Index this single file: create root module, parse document, index FTS
            indexSingleFile(fileURL: fileURL, db: db, provider: provider)

            NSLog("[DDE] Single-file workspace initialized: \(fileName) → \(dbName)")
        } catch {
            NSLog("[DDE] Failed to init single-file workspace: \(error)")
        }
    }

    /// Index a single markdown file — structural parse + FTS + Haiku extraction.
    /// Works fully in sandbox: no directory scan, content passed directly.
    private func indexSingleFile(fileURL: URL, db: SemanticDatabase, provider: AIProviderClient?) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            NSLog("[DDE] indexSingleFile: cannot read \(fileURL.path)")
            return
        }

        let docId = fileURL.lastPathComponent
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let modId = "mod_single_file"

        // Root module
        db.upsertModule(id: modId, name: fileName, path: fileURL.deletingLastPathComponent().path,
                        parentId: nil, level: 0, fileCount: 1)

        // FTS index
        db.indexDocumentFTS(documentId: docId, title: fileName, content: content)

        // Content hash
        var h: UInt32 = 0x811c9dc5
        for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        try? db.upsertDocument(id: docId, projectId: fileName, filePath: fileURL.path,
                               fileName: docId, fileExt: "md", contentHash: String(h, radix: 16))

        // Parse symbols inline (headings) — no directory scan
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineNum = i + 1
            if line.range(of: #"^#{1,6}\s+.+"#, options: .regularExpression) != nil {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let symId = "sym_h_\(singleFileFnv1a("\(docId):\(lineNum):\(text)"))"
                db.insertSymbol(id: symId, moduleId: modId, documentId: docId,
                               name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum, context: nil)
            }
        }

        NSLog("[DDE] indexSingleFile: parsed \(docId), \(content.count) chars")

        // Haiku component extraction — only on explicit user action (Refresh button), not on file open
        // Skip auto-extraction: user triggers it manually via the ↻ button in modules panel
        let autoExtract = false // Set to true to enable auto-extraction on file open
        if autoExtract, let provider = provider, provider.hasAPIKey {
            // Check content hash — skip if unchanged
            let currentHash = String(h, radix: 16)
            let previousHash = db.getDocumentHash(docId)
            let alreadyExtracted = db.hasExtractedComponents(forDocument: docId)

            if alreadyExtracted && previousHash == currentHash {
                NSLog("[DDE] Skipping extraction — file unchanged, \(db.symbolsForModule("").count) components cached")
                return
            }

            // File changed or never extracted — clear old and re-extract
            if alreadyExtracted {
                db.clearExtractedComponents(forDocument: docId)
            }
            let fullContent = content
            Task {
                indexingProgress = "Extracting components (Haiku)..."
                await extractSingleFileComponents(content: fullContent, docId: docId, db: db, provider: provider)
                indexingProgress = "Extraction complete"
                // Force UI refresh — briefly change indexingProgress so SwiftUI re-reads modules from DB
                try? await Task.sleep(nanoseconds: 500_000_000)
                indexingProgress = nil
                objectWillChange.send()
            }
        }
    }

    /// Extract components from a single file using Haiku — chunks entire document, works in sandbox
    private func extractSingleFileComponents(content: String, docId: String, db: SemanticDatabase, provider: AIProviderClient) async {
        guard let apiKey = provider.apiKeyValue else { return }

        // Split into chunks of ~12000 chars at paragraph boundaries
        let chunks = chunkContent(content, maxChars: 12000)
        NSLog("[DDE] Extracting from \(chunks.count) chunks (\(content.count) chars total)")

        var globalSeen = Set<String>()
        var totalComponents = 0

        for (chunkIdx, chunk) in chunks.enumerated() {
            indexingProgress = "Extracting components (Haiku) chunk \(chunkIdx + 1)/\(chunks.count)..."

            let tool: [String: Any] = [
                "name": "extract_components",
                "description": "Extract all named software components from documentation",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "components": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string"],
                                    "type": ["type": "string", "enum": ["service","database","api","queue","system","library","tool","framework","protocol","storage","cache","gateway","worker","scheduler","proxy","broker","sdk","platform","infrastructure","monitoring","testing","module","pipeline","classifier","resolver","analyzer","generator","processor"]],
                                    "description": ["type": "string"],
                                    "dependencies": ["type": "array", "items": ["type": "string"]]
                                ],
                                "required": ["name", "type", "description"]
                            ]
                        ]
                    ],
                    "required": ["components"]
                ]
            ]

            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 8192,
                "system": """
Extract ALL named technical components, modules, and architectural elements from this documentation chunk.
The document may be in any language (including Russian) — extract component names regardless of language.

Look for ALL of these:
- Python/code modules (*.py files, classes, functions mentioned as components)
- Pipeline stages and processing steps
- Services, APIs, databases, queues, caches
- Libraries, frameworks, tools, SDKs
- Classifiers, analyzers, resolvers, generators
- Infrastructure: storage, monitoring, orchestrators
- External systems and integrations

Extract EVERY named component — do NOT skip anything. If a module like 'orchestrator.py' or a stage like 'Document Intake' is mentioned, extract it.
Each component needs a correct type and one-sentence description.
""",
                "messages": [["role": "user", "content": "File: \(docId) (chunk \(chunkIdx + 1)/\(chunks.count))\n\n\(chunk)"]],
                "tools": [tool],
                "tool_choice": ["type": "tool", "name": "extract_components"]
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.httpBody = data
                request.timeoutInterval = 60

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    NSLog("[DDE] Haiku chunk \(chunkIdx + 1) error: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let contentBlocks = json["content"] as? [[String: Any]] else { continue }

                if let usage = json["usage"] as? [String: Any] {
                    let inp = usage["input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0001 + Double(out) * 0.0005)
                }

                for block in contentBlocks {
                    if block["type"] as? String == "tool_use",
                       let input = block["input"] as? [String: Any],
                       let components = input["components"] as? [[String: Any]] {
                        for m in components {
                            guard let name = m["name"] as? String, let type = m["type"] as? String else { continue }
                            let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                            guard !globalSeen.contains(key) else { continue }
                            globalSeen.insert(key)

                            let desc = m["description"] as? String ?? ""
                            let deps = m["dependencies"] as? [String] ?? []
                            let modId = "cmod_\(singleFileFnv1a("\(docId):\(name)"))"

                            db.upsertModule(id: modId, name: name, path: "cmod/\(name)", parentId: "mod_single_file", level: 1, fileCount: 0)
                            db.insertSymbol(id: "sym_cmod_\(singleFileFnv1a(modId))", moduleId: modId, documentId: docId,
                                           name: name, kind: "component", lineStart: nil, lineEnd: nil,
                                           context: "[\(type)] \(desc)")
                            for dep in deps {
                                let targetId = "cmod_\(singleFileFnv1a("\(docId):\(dep)"))"
                                db.insertRelation(id: "rel_\(singleFileFnv1a("\(modId)→\(dep)"))", sourceId: modId, targetId: targetId,
                                                  type: "depends_on", sourceDoc: docId, evidence: "\(name) → \(dep)")
                            }
                            totalComponents += 1
                        }
                        NSLog("[DDE] Chunk \(chunkIdx+1): \(components.count) components")
                    }
                }
            } catch {
                NSLog("[DDE] Chunk \(chunkIdx + 1) extraction error: \(error)")
            }
        }
        NSLog("[DDE] Total: \(totalComponents) unique components from \(chunks.count) chunks")
    }

    /// Split content into chunks at paragraph boundaries
    private func chunkContent(_ content: String, maxChars: Int) -> [String] {
        guard content.count > maxChars else { return [content] }
        var chunks: [String] = []
        var current = ""
        for paragraph in content.components(separatedBy: "\n\n") {
            if current.count + paragraph.count + 2 > maxChars && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n\n" }
            current += paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Ollama Extraction

    /// Extract components from all files using local Ollama model
    private func extractWithOllama(db: SemanticDatabase, rootURL: URL) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

        var files: [(url: URL, content: String)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
            if let content = try? String(contentsOf: url, encoding: .utf8), content.count > 50 {
                files.append((url, content))
            }
        }

        var totalComponents = 0
        var globalSeen = Set<String>()

        for (i, file) in files.enumerated() {
            let docId = file.url.lastPathComponent
            indexingProgress = "Ollama: \(i+1)/\(files.count) — \(docId)"

            // Skip if already extracted
            if db.hasExtractedComponents(forDocument: docId) { continue }

            // Chunk and extract
            let chunks = chunkContent(file.content, maxChars: 3000) // smaller chunks for local model
            for chunk in chunks {
                guard let components = await ollamaClient.extractJSON(
                    prompt: "File: \(docId)\n\n\(chunk)",
                    system: OllamaClient.extractionSystemPrompt
                ) else { continue }

                for comp in components {
                    guard let name = comp["name"] as? String, let type = comp["type"] as? String else { continue }
                    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !globalSeen.contains(key) else { continue }
                    globalSeen.insert(key)

                    let desc = comp["description"] as? String ?? ""
                    let modId = "cmod_\(singleFileFnv1a("\(docId):\(name)"))"

                    db.upsertModule(id: modId, name: name, path: "cmod/\(name)", parentId: nil, level: 1, fileCount: 0)
                    db.insertSymbol(id: "sym_cmod_\(singleFileFnv1a(modId))", moduleId: modId, documentId: docId,
                                   name: name, kind: "component", lineStart: nil, lineEnd: nil,
                                   context: "[\(type)] \(desc)")
                    totalComponents += 1
                }
            }
        }
        NSLog("[DDE] Ollama extraction: \(totalComponents) components from \(files.count) files")
    }

    private func singleFileFnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }

    /// Close a tab at the given index
    func closeTab(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }

        if openTabs[index].isModified {
            let alert = NSAlert()
            alert.messageText = "Save changes?"
            alert.informativeText = "Do you want to save changes to \(openTabs[index].displayName)?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                saveFile(at: index)
            } else if response == .alertThirdButtonReturn {
                return
            }
        }

        tabsStore.removeTab(at: index)
    }

    /// Close all tabs except the one at the given index
    func closeOtherTabs(except index: Int) {
        tabsStore.keepOnlyTab(at: index)
    }

    /// Close all tabs to the right of the given index
    func closeTabsToRight(of index: Int) {
        tabsStore.keepTabs(through: index)
    }

    /// Close all tabs
    func closeAllTabs() {
        tabsStore.reset()
    }

    /// Reveal a file in the file tree by expanding parent folders
    func revealInFileTree(url: URL) {
        showFileTree = true
        fileTreeStore.reveal(url: url)
    }

    /// Save the active tab's file
    func saveActiveFile() {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }
        saveFile(at: activeTabIndex)
    }

    /// Translate document to target language, chunk by chunk, open result in new tab
    func translateDocument(markdown: String, targetLang: String) async {
        guard let provider = incrementalCompiler?.orchestrator.providerClient,
              let apiKey = provider.apiKeyValue else {
            NSLog("[DDE] No API key for translation")
            return
        }

        // Create new tab immediately with placeholder
        let sourceTab = activeTabIndex >= 0 && activeTabIndex < openTabs.count ? openTabs[activeTabIndex] : nil
        let sourceName = sourceTab?.url.deletingPathExtension().lastPathComponent ?? "document"
        let newURL = sourceTab?.url.deletingLastPathComponent()
            .appendingPathComponent("\(sourceName)_\(targetLang.lowercased()).md") ?? URL(fileURLWithPath: "/tmp/translated.md")

        let translatedTab = OpenTab(url: newURL, content: "# Translating to \(targetLang)...\n\nPlease wait...", originalContent: "")
        tabsStore.appendTab(translatedTab)

        // Split markdown into chunks at heading boundaries for better translation
        let chunks = splitForTranslation(markdown, maxChars: 4000)
        var translatedParts: [String] = []
        let tabIndex = openTabs.count - 1

        for (i, chunk) in chunks.enumerated() {
            indexingProgress = "Translating chunk \(i + 1)/\(chunks.count)..."

            let body: [String: Any] = [
                "model": "claude-sonnet-4-6",
                "max_tokens": 8192,
                "system": """
                    You are a professional translator. Translate the following markdown text to \(targetLang).
                    Rules:
                    - Translate ONLY the text content. Keep ALL markdown formatting intact (headings, lists, code blocks, links, tables).
                    - Do NOT translate code inside code blocks (```...```). Keep code exactly as-is.
                    - Do NOT translate URLs, file paths, or technical identifiers.
                    - Keep proper nouns, product names, and acronyms as-is.
                    - Preserve the exact markdown structure — same number of headings, lists, paragraphs.
                    - Return ONLY the translated markdown, no explanations.
                    """,
                "messages": [["role": "user", "content": chunk]]
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.httpBody = data
                request.timeoutInterval = 120

                let (responseData, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let text = content.first?["text"] as? String else {
                    translatedParts.append(chunk) // Keep original on failure
                    continue
                }

                // Track cost (Sonnet: $3/1M in, $15/1M out)
                if let usage = json["usage"] as? [String: Any] {
                    let inp = usage["input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    semanticDatabase?.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0003 + Double(out) * 0.0015)
                }

                translatedParts.append(text)

                // Update tab content progressively
                tabsStore.updateTab(at: tabIndex) { tab in
                    tab.content = translatedParts.joined(separator: "\n\n")
                    tab.isModified = true
                }
            } catch {
                NSLog("[DDE] Translation chunk \(i + 1) error: \(error)")
                translatedParts.append(chunk)
            }
        }

        // Final update
        tabsStore.updateTab(at: tabIndex) { tab in
            tab.content = translatedParts.joined(separator: "\n\n")
            tab.isModified = true
        }
        tabsStore.activeTabIndex = tabIndex
        indexingProgress = nil
        NSLog("[DDE] Translation complete: \(chunks.count) chunks")
    }

    /// Split markdown at heading boundaries for translation
    private func splitForTranslation(_ markdown: String, maxChars: Int) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        for line in lines {
            let isHeading = line.range(of: #"^#{1,3}\s+"#, options: .regularExpression) != nil
            if isHeading && current.count > maxChars / 2 {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += line

            if current.count > maxChars {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Save a file at the given index
    private func saveFile(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }

        let tab = openTabs[index]
        do {
            try tab.content.write(to: tab.url, atomically: true, encoding: .utf8)
            tabsStore.updateTab(at: index) { mutableTab in
                mutableTab.isModified = false
                mutableTab.originalContent = tab.content // new baseline
            }
        } catch {
            NSLog("Error saving file: \(error)")
        }
    }

    /// Re-index active file: update FTS, headings, re-extract components
    /// Refresh: re-index current file + extraction. Prefers Ollama (free), falls back to Haiku.
    func reindexActiveFile() {
        // If a folder is open, re-run full structural index + extraction
        if let root = rootNode?.url, let db = semanticDatabase {
            indexingProgress = "Re-indexing workspace..."
            runStructuralIndex(at: root)

            Task {
                if ollamaClient.isConnected {
                    // Use Ollama (free, local)
                    indexingProgress = "Extracting modules (Ollama \(ollamaClient.selectedModel))..."
                    await extractWithOllama(db: db, rootURL: root)
                } else if let provider = incrementalCompiler?.orchestrator.providerClient, provider.hasAPIKey {
                    // Fallback to Haiku (cloud, paid)
                    indexingProgress = "Extracting modules (Haiku)..."
                    let indexer = StructuralIndexer(db: db, rootURL: root, providerClient: provider)
                    await indexer.extractContentModules()
                } else {
                    indexingProgress = "No AI available — structural index only"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                indexingProgress = nil
                objectWillChange.send()
            }
            return
        }

        // Single file mode
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return }
        let tab = openTabs[activeTabIndex]
        reindexFile(fileURL: tab.url, content: tab.content)
    }

    private func reindexFile(fileURL: URL, content: String) {
        guard let db = semanticDatabase else { return }
        let docId = fileURL.lastPathComponent

        // Compute new hash
        var h: UInt32 = 0x811c9dc5
        for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        let newHash = String(h, radix: 16)

        NSLog("[DDE] Re-indexing: \(docId)")

        // Update hash
        try? db.upsertDocument(id: docId, projectId: fileURL.deletingPathExtension().lastPathComponent,
                               filePath: fileURL.path, fileName: docId, fileExt: "md",
                               contentHash: newHash)

        // Re-index FTS
        db.indexDocumentFTS(documentId: docId, title: docId.replacingOccurrences(of: ".md", with: ""), content: content)

        // Re-parse headings
        let modId = "mod_single_file"
        db.clearSymbols(forDocument: docId, kind: "heading")

        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineNum = i + 1
            if line.range(of: #"^#{1,6}\s+.+"#, options: .regularExpression) != nil {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let symId = "sym_h_\(singleFileFnv1a("\(docId):\(lineNum):\(text)"))"
                db.insertSymbol(id: symId, moduleId: modId, documentId: docId,
                               name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum, context: nil)
            }
        }

        // Re-extract components in background
        let provider = incrementalCompiler?.orchestrator.providerClient
        if let provider = provider, provider.hasAPIKey {
            db.clearExtractedComponents(forDocument: docId)
            Task {
                indexingProgress = "Re-extracting components..."
                await extractSingleFileComponents(content: content, docId: docId, db: db, provider: provider)
                indexingProgress = "Re-indexing complete"
                try? await Task.sleep(nanoseconds: 500_000_000)
                indexingProgress = nil
                objectWillChange.send()
            }
        } else {
            objectWillChange.send()
        }
    }

    /// Update the content of the active tab
    func updateActiveTabContent(_ content: String) {
        tabsStore.updateActiveTab { tab in
            tab.content = content
            tab.isModified = (content != tab.originalContent)
        }
    }

    /// Update the headings for the active tab
    func updateActiveTabHeadings(_ headings: [HeadingItem]) {
        tabsStore.updateActiveTab { tab in
            tab.headings = headings
        }
    }

    /// Persist scroll state from the editor for the active tab.
    func updateActiveTabScrollPosition(_ position: CGFloat) {
        tabsStore.updateActiveTab { tab in
            tab.scrollPosition = position
        }
    }

    /// Update the active heading for the active tab
    func updateActiveHeading(_ headingId: String) {
        tabsStore.updateActiveTab { tab in
            tab.activeHeadingId = headingId
        }
    }

    /// Reload the active tab from disk and return the fresh content for the editor.
    func reloadActiveTabFromDisk() -> String? {
        let idx = activeTabIndex
        guard idx >= 0 && idx < openTabs.count else { return nil }

        let url = openTabs[idx].url
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        tabsStore.updateTab(at: idx) { tab in
            tab.content = content
            tab.originalContent = content
            tab.isModified = false
        }

        return content
    }

    func refreshFileTree() {
        Self.debugLog("refreshFileTree() called")
        fileTreeStore.refresh()
    }

    var fileTreeSortOrder: FileTreeSortOrder {
        get { fileTreeStore.sortOrder }
        set { fileTreeStore.sortOrder = newValue }
    }

    func presentGraphCreator(for type: String = "architecture") {
        pendingGraphCreatorType = type
    }

    func dismissGraphCreator() {
        pendingGraphCreatorType = nil
    }

    func runAITool(named toolName: String, contentOverride: String? = nil) {
        guard let tool = WorkspaceAITool(rawValue: toolName) else { return }

        if tool.opensGraphCreator {
            presentGraphCreator(for: tool.rawValue)
            return
        }

        guard let engine = aiConsoleEngine,
              let prompt = aiPrompt(for: tool, contentOverride: contentOverride) else {
            return
        }

        engine.sendMessage(prompt)
        showAIConsole()
    }

    func runGraphEdit(instruction: String, currentMermaid: String) {
        guard let engine = aiConsoleEngine else { return }

        let editPrompt = """
        I have a Mermaid diagram. Please modify it according to this instruction:

        INSTRUCTION: \(instruction)

        CURRENT MERMAID CODE:
        ```mermaid
        \(currentMermaid)
        ```

        RULES:
        1. Modify the diagram as requested
        2. Keep ALL other components that weren't mentioned
        3. Maintain the subgraph structure and layers
        4. Return the COMPLETE updated mermaid code
        5. The FIRST LINE inside the mermaid block MUST be: %%INTERACTIVE
        6. Update the current file with the new diagram (replace the old mermaid block)

        Save the updated diagram to the currently open file.
        """

        engine.sendMessage(editPrompt)
        showAIConsole()
    }

    func generateDocumentation(into outputURL: URL) {
        guard let engine = aiConsoleEngine else {
            NSLog("[Docs] No AI engine")
            return
        }

        engine.sendMessage(documentationGenerationPrompt(outputDir: outputURL))
        showAIConsole()
    }

    // MARK: - Recent Files

    private func loadRecentFiles() {
        guard let data = try? Data(contentsOf: recentFilesURL) else { return }
        do {
            let urls = try JSONDecoder().decode([String].self, from: data)
            recentFiles = urls.compactMap { URL(fileURLWithPath: $0) }
        } catch {
            NSLog("Error loading recent files: \(error)")
        }
    }

    private func addRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 {
            recentFiles = Array(recentFiles.prefix(20))
        }
        saveRecentFiles()
    }

    private func saveRecentFiles() {
        let paths = recentFiles.map { $0.path }
        if let data = try? JSONEncoder().encode(paths) {
            try? data.write(to: recentFilesURL)
        }
    }

    // MARK: - Markdown Parsing

    /// Extract headings from markdown content
    private func extractHeadings(from markdown: String) -> [HeadingItem] {
        var headings: [HeadingItem] = []
        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)

                if level >= 1 && level <= 6 && !text.isEmpty {
                    let id = UUID().uuidString
                    headings.append(HeadingItem(id: id, level: level, text: String(text)))
                }
            }
        }

        return headings
    }

    // MARK: - DDE Block Handling

    /// Handle block delta from JS extraction — wrapped in safety guard
    func handleBlocksDelta(_ delta: BlocksDelta) {
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return }
        guard !delta.isEmpty else { return }

        let tabIndex = activeTabIndex
        var tab = openTabs[tabIndex]

        tab.blocks.removeAll { delta.removed.contains($0.id) }

        for changed in delta.changed {
            if let idx = tab.blocks.firstIndex(where: { $0.id == changed.id }) {
                tab.blocks[idx] = changed
            }
        }

        tab.blocks.append(contentsOf: delta.added)
        tab.blocks.sort { $0.position < $1.position }

        tabsStore.updateTab(at: tabIndex) { currentTab in
            currentTab = tab
        }

        // Persist to SQLite
        if let db = semanticDatabase {
            let docId = tab.url.lastPathComponent
            for block in delta.added + delta.changed {
                try? db.upsertBlock(block, documentId: docId)
            }
            for id in delta.removed {
                try? db.deleteBlock(id: id)
            }
        }

        // Feed delta to incremental compiler
        incrementalCompiler?.compileDelta(delta, forFile: tab.url)
    }

    // MARK: - Background Folder Analysis

    /// V1: Deterministic structural indexing — instant, no LLM
    /// Then V1.5: Haiku-based content module extraction (cheap, fast)
    private func runStructuralIndex(at url: URL) {
        guard let db = semanticDatabase else { return }
        let provider = incrementalCompiler?.orchestrator.providerClient
        let indexer = StructuralIndexer(db: db, rootURL: url, providerClient: provider)
        indexer.progress = { msg in
            NSLog("[DDE] Index: %@", msg)
        }

        // Run indexing silently in background — no UI progress indicator
        Task {
            await indexer.indexAll()
            NSLog("[DDE] Structural index complete")

            if false && provider?.hasAPIKey == true {
                await indexer.extractContentModules()
                NSLog("[DDE] Content module extraction complete")
            }
        }
    }

    /// Smart analysis — only processes NEW or CHANGED files. Skips unchanged files entirely.
    private func analyzeAllFiles(in folderURL: URL) {
        // Load cached results IMMEDIATELY so panel has data
        loadCachedResults()
        ensureArchitectureDiagrams()

        // Run analysis in background — does NOT block UI
        Task.detached { [weak self] in
            guard let self else { return }

            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: folderURL,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

            var mdFiles: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "md" { mdFiles.append(url) }
            }
            let totalMarkdownFiles = mdFiles.count

            await MainActor.run {
                self.totalFilesInWorkspace = totalMarkdownFiles
                self.analysisStage = "Checking \(totalMarkdownFiles) files..."
            }

            // Check which files changed
            var changedFiles: [(docId: String, url: URL, content: String)] = []
            var skippedCount = 0

            for fileURL in mdFiles {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let docId = fileURL.lastPathComponent
                var hash: UInt32 = 0x811c9dc5
                for byte in content.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
                let contentHash = String(hash, radix: 16)

                let skip = await MainActor.run { () -> Bool in
                    guard let db = self.semanticDatabase else { return false }
                    if db.getDocumentHash(docId) == contentHash,
                       !db.documentNeedsReanalysis(docId) {
                        return true
                    }
                    try? db.upsertDocument(id: docId, projectId: folderURL.lastPathComponent,
                        filePath: fileURL.path, fileName: fileURL.deletingPathExtension().lastPathComponent,
                        fileExt: fileURL.pathExtension, contentHash: contentHash)
                    return false
                }

                if skip { skippedCount += 1; continue }
                changedFiles.append((docId, fileURL, content))
            }
            let changedCount = changedFiles.count
            let skippedTotal = skippedCount

            await MainActor.run {
                self.analysisDetail = "\(changedCount) changed, \(skippedTotal) cached"
            }
            NSLog("[DDE] \(changedCount) changed, \(skippedTotal) cached")

            if changedFiles.isEmpty {
                await MainActor.run {
                    self.analysisStage = nil
                    self.analysisDetail = nil
                    self.refreshSemanticViews()
                }
                return
            }

            // Extract changed files
            let changedFilesTotal = changedFiles.count
            for (index, (docId, _, content)) in changedFiles.enumerated() {
                await MainActor.run {
                    self.analyzedFiles = index + 1
                    self.analysisStage = "Extracting \(index + 1)/\(changedFilesTotal): \(docId)"
                }

                let blocks = MarkdownBlockParser.extractBlocks(from: content, documentId: docId)

                await MainActor.run {
                    if let db = self.semanticDatabase {
                        for block in blocks { try? db.upsertBlock(block, documentId: docId) }
                    }
                    if content.count > 20 {
                        // Insert file-level block into DB so FK constraints work for claims
                        let fileBlock = SemanticBlock(
                            id: "file_\(docId)", documentId: docId, type: .document, level: nil,
                            content: content, plainText: content, contentHash: "",
                            headingPath: [], parentBlockId: nil,
                            lineStart: 1, lineEnd: blocks.last?.lineEnd ?? 1,
                            position: 0, language: nil, anchor: nil)
                        // Store the file block in DB so claims can reference it (FK constraint)
                        if let db = self.semanticDatabase {
                            try? db.upsertBlock(fileBlock, documentId: docId)
                        }
                        self.incrementalCompiler?.orchestrator.submitExtraction(
                            block: fileBlock, documentId: docId, file: docId)
                    }
                }
            }

            // Wait for AI (with timeout, non-blocking for UI since we're detached)
            await self.waitForAICompletion()

            await MainActor.run {
                self.loadCachedResults()
                self.incrementalCompiler?.runContradictionDetection()
                self.analysisStage = nil
                self.analysisDetail = nil
                self.ensureArchitectureDiagrams()
                self.refreshSemanticViews()
                let ent = self.incrementalCompiler?.orchestrator.extractedEntities.count ?? 0
                let clm = self.incrementalCompiler?.orchestrator.extractedClaims.count ?? 0
                NSLog("[DDE] Done: \(ent) entities, \(clm) claims")
            }
        }
    }

    /// Load cached diagrams from DB, or generate in background if missing
    func ensureArchitectureDiagrams() {
        // Try loading from DB first
        if let db = semanticDatabase {
            if let cached = db.getDocumentHash("__diagram_software") {
                softwareArchMermaid = cached
            }
            if let cached = db.getDocumentHash("__diagram_dataflow") {
                dataFlowMermaid = cached
            }
            if let cached = db.getDocumentHash("__diagram_deployment") {
                deploymentMermaid = cached
            }
        }

        // Don't auto-generate — diagrams are only generated on explicit user action (Rerun button)
        // This prevents wasting API credits on every folder open
    }

    func refreshSemanticViews() {
        semanticRefreshVersion &+= 1
    }

    /// Get the full prompt = base + user instructions
    func diagramPrompt(for mode: String) -> String {
        let base = AIProviderClient.defaultDiagramPrompt(for: mode)
        let userInstr = diagramPrompts[mode] ?? ""
        if userInstr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }
        return base + "\n\nAdditional instructions from user:\n" + userInstr
    }

    /// Get only the user's additional instructions (for the editor)
    func diagramUserInstructions(for mode: String) -> String {
        diagramPrompts[mode] ?? ""
    }

    /// Store user's additional instructions
    func updateDiagramPrompt(_ instructions: String, for mode: String) {
        diagramPrompts[mode] = instructions
    }

    func resetDiagramPrompt(for mode: String) {
        diagramPrompts[mode] = ""
    }

    func regenerateArchitectureDiagram(mode: String) {
        Task { await generateArchitectureDiagram(mode: mode, force: true) }
    }

    func navigateToText(filePath: String?, fallbackDocumentId: String? = nil, searchText: String) {
        let trimmedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let url = resolveWorkspaceFileURL(filePath: filePath, fallbackDocumentId: fallbackDocumentId) {
            openFile(url)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            NotificationCenter.default.post(name: .scrollToText, object: trimmedText)
        }
    }

    /// Generate architecture diagrams using AI → Mermaid code (runs in background, doesn't block UI)
    private func generateArchitectureDiagrams(forceModes: Set<String>) async {
        for mode in ["software", "dataflow", "deployment"] {
            let shouldForce = forceModes.contains(mode)
            let hasCachedDiagram = !(currentDiagram(for: mode)?.isEmpty ?? true)
            if shouldForce || !hasCachedDiagram {
                await generateArchitectureDiagram(mode: mode, force: shouldForce)
            }
        }
    }

    /// Load ALL entities and claims from SQLite into orchestrator's @Published arrays
    /// Lazy load — only loads counts, not full data. Panel reads from DB on demand.
    private func loadCachedResults() {
        // Don't load thousands of records into @Published arrays.
        // The SemanticPanelView reads directly from DB when it needs to display.
        NSLog("[DDE] DB ready for lazy loading")
        refreshSemanticViews()
    }

    /// Wait until AI orchestrator finishes all pending jobs
    private func waitForAICompletion() async {
        guard let orch = incrementalCompiler?.orchestrator else { return }
        var waited = 0
        // Poll every 2 seconds, but stop if paused/disabled/timeout (max 5 min)
        while orch.isProcessing && !orch.isDisabled && !orch.isPaused && waited < 150 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 1
        }
    }

    /// Cursor moved to a different block
    func handleCursorBlockChange(_ blockId: String) {
        tabsStore.updateActiveTab { tab in
            tab.activeBlockId = blockId
        }
    }

    private func generateArchitectureDiagram(mode: String, force: Bool) async {
        guard let compiler = incrementalCompiler, compiler.orchestrator.hasAPIKey else { return }
        guard force || (currentDiagram(for: mode)?.isEmpty ?? true) else { return }
        guard !activeDiagramGenerationModes.contains(mode) else { return }
        guard let summaries = diagramSummaries() else { return }

        activeDiagramGenerationModes.insert(mode)
        defer { activeDiagramGenerationModes.remove(mode) }

        do {
            let results = try await compiler.orchestrator.providerClient.generateMermaidDiagrams(
                mode: mode,
                entitiesSummary: summaries.entities,
                claimsSummary: summaries.claims,
                customPrompt: diagramPrompt(for: mode)
            )
            // Combine multiple diagrams with separator markers
            let combined = results.map { "%%DIAGRAM_TITLE:\($0.title)\n\($0.mermaid)" }.joined(separator: "\n%%DIAGRAM_SEPARATOR\n")
            setDiagram(combined, for: mode)
            cacheDiagram(combined, for: mode)
            NSLog("[DDE] Generated \(results.count) \(mode) diagrams")
        } catch {
            NSLog("[DDE] Failed \(mode.capitalized) diagram: \(error)")
        }
    }

    private func showAIConsole() {
        showTOC = true
        showSemanticPanel = true
    }

    private func activeDocumentContext(contentLimit: Int = 15000, contentOverride: String? = nil, defaultFileName: String = "project") -> (fileName: String, content: String) {
        let fileName = activeTab?.url.lastPathComponent ?? defaultFileName

        if let contentOverride {
            return (fileName, contentOverride)
        }

        let content = activeTab.map { String($0.content.prefix(contentLimit)) } ?? ""
        return (fileName, content)
    }

    private func aiPrompt(for tool: WorkspaceAITool, contentOverride: String?) -> String? {
        let context = activeDocumentContext(contentOverride: contentOverride)

        switch tool {
        case .audit:
            return AIConsoleEngine.codebaseAuditPrompt

        case .fulldocs:
            return AIConsoleEngine.fullDocumentationPrompt

        case .codemap:
            return """
            Scan the current directory recursively and generate a VISUAL CODE STRUCTURE MAP.

            Create a file called "code-structure-map.md" with the following sections:

            # Code Structure Map

            ## Directory Tree
            Show the full directory tree with annotations for each folder/file purpose.
            Use indentation and icons:
            📁 folder — description
            📄 file — description
            ⚙️ config file — what it configures
            🧪 test file — what it tests
            🐳 Docker — what it builds
            📦 package manifest — dependencies

            ## Architecture Layers Diagram
            ```mermaid
            %%INTERACTIVE
            graph TD
            subgraph "Entry Points"
            ...
            end
            subgraph "Application Layer"
            ...
            end
            subgraph "Domain / Business Logic"
            ...
            end
            subgraph "Data Access / Persistence"
            ...
            end
            subgraph "Infrastructure / External"
            ...
            end
            ```
            Show ALL files/modules as nodes grouped by architectural layer.
            Connect them by actual import/dependency relationships found in code.

            ## Configuration Map
            Table showing:
            | Config File | Purpose | Key Settings | Environment Vars | Notes |
            For every config file found (.env, .yaml, .json, .toml, Dockerfile, CI files, etc.)

            ## Dependency Graph
            ```mermaid
            %%INTERACTIVE
            graph LR
            ```
            Show package/module dependencies — what imports what, what depends on what.
            Use subgraph for internal vs external dependencies.

            ## Entry Points
            List all entry points:
            - Main app entry
            - API routes/endpoints
            - CLI commands
            - Background workers
            - Scheduled tasks
            - Event handlers
            For each: file path, purpose, how it's triggered.

            ## Data Flow
            ```mermaid
            %%INTERACTIVE
            graph TD
            ```
            Show how data flows through the system:
            - User input → API → Service → DB
            - Events → Queue → Worker → Storage
            - Cron → Batch → External API

            ## File Statistics
            | Metric | Value |
            |--------|-------|
            | Total files | ... |
            | Source files | ... |
            | Test files | ... |
            | Config files | ... |
            | Languages | ... |
            | Largest files | top 10 |
            | Most connected modules | top 10 |

            Be thorough — scan EVERY file. Use %%INTERACTIVE in mermaid blocks for interactive diagrams.
            """

        case .critic:
            if contentOverride != nil {
                return """
                You are a CONSTRUCTIVE CRITIC reviewing documentation. Analyze the following document thoroughly.

                Create a file called "review-\(context.fileName)" with your review. Structure it as:

                # Constructive Review: \(context.fileName)

                ## Summary
                Brief overview of what the document covers and its overall quality.

                ## Strengths
                What's done well — be specific with examples.

                ## Issues Found
                For each issue:
                ### Issue N: [Title]
                - **Severity**: Critical / Major / Minor / Suggestion
                - **Location**: Where in the document
                - **Problem**: What's wrong
                - **Recommendation**: How to fix it
                - **Example**: Show the fix if applicable

                ## Missing Content
                What should be documented but isn't.

                ## Consistency Issues
                Terminology, formatting, style inconsistencies.

                ## Action Items
                Numbered list of concrete tasks to improve this document.
                Each with priority (P1/P2/P3) and estimated effort.

                ## Overall Score
                Rate 1-10 with brief justification.

                ---
                Also create a file called "tasks/review-tasks-\(context.fileName)" with just the action items as a task list:
                - [ ] P1: task description
                - [ ] P2: task description
                etc.

                Document to review:
                \(context.content)
                """
            }

            return """
            You are a CONSTRUCTIVE CRITIC. Analyze the current workspace documentation thoroughly.
            Create a file "review-\(context.fileName).md" with: Summary, Strengths, Issues (with severity/location/fix), Missing Content, Consistency Issues, Action Items (P1/P2/P3), Overall Score 1-10.
            Also create "tasks/review-tasks-\(context.fileName).md" with action items as checkboxes.
            \(context.content.isEmpty ? "Scan all files in the current directory." : "Document:\n\(context.content)")
            """

        case .research:
            if contentOverride != nil {
                return """
                You are a DEEP RESEARCHER. Analyze the following document and identify research points.

                STEP 1: Read the document and identify all:
                - External APIs, services, and integrations mentioned
                - Technologies, frameworks, libraries referenced
                - Architectural patterns and approaches used
                - Claims about performance, scalability, or capabilities
                - Third-party dependencies

                STEP 2: For each research point, search online to find:
                - Current status (is it still maintained? latest version?)
                - Best practices and recommendations
                - Known issues or limitations
                - Alternatives and comparisons
                - How it applies to this project specifically

                STEP 3: Create a file called "research-\(context.fileName)" with findings:

                # Deep Research Report: \(context.fileName)

                ## Research Points Identified
                List all points found.

                ## Detailed Findings

                ### 1. [Technology/API Name]
                - **What it is**: Brief description
                - **Current status**: Version, maintenance status
                - **How it's used here**: Context from the document
                - **Best practices**: What experts recommend
                - **Risks/Issues**: Known problems
                - **Alternatives**: Other options to consider
                - **Recommendation**: Keep / Replace / Update / Investigate

                (repeat for each research point)

                ## Summary & Recommendations
                Overall findings and priority actions.

                Document to research:
                \(context.content)
                """
            }

            return """
            You are a DEEP RESEARCHER. Analyze the current workspace and identify all external APIs, technologies, dependencies.
            For each, search online for: current status, best practices, known issues, alternatives.
            Create "research-\(context.fileName).md" with detailed findings and recommendations (Keep/Replace/Update).
            \(context.content.isEmpty ? "Scan all files in the current directory." : "Document:\n\(context.content)")
            """

        case .architecture, .dataflow, .pipeline, .deployment, .sequence, .er:
            return nil
        }
    }

    private func documentationGenerationPrompt(outputDir: URL) -> String {
        var prompt = """
        Create a comprehensive documentation structure in the folder: \(outputDir.path)

        Generate the following structure based on the project files in this workspace:

        1. README.md — project overview with links to all sections
        2. architecture/ folder:
           - overview.md — high-level architecture with mermaid diagrams
           - components.md — all components/modules listed with descriptions
           - data-flow.md — how data flows between components
        3. modules/ folder — one .md file per major component/service, with:
           - Description, responsibilities
           - Dependencies (links to other module files)
           - API/interfaces
           - Configuration
        4. decisions/ folder:
           - ADR-001.md (and more) — key architectural decisions
        5. guides/ folder:
           - getting-started.md
           - deployment.md

        Requirements:
        - Every file must use proper markdown with headings, lists, code blocks
        - Cross-reference between files using relative markdown links: [Component X](../modules/component-x.md)
        - Include mermaid diagrams where appropriate (architecture overview, data flow)
        - Be thorough and detailed — this should be production-quality documentation
        - Write in English unless instructed otherwise
        """

        if let db = semanticDatabase {
            let modules = db.allModules()
            let contentModules = modules.filter { $0.id.hasPrefix("cmod_") }
            if !contentModules.isEmpty {
                prompt += "\n\nExisting components found in workspace (\(contentModules.count)):\n"
                for mod in contentModules.prefix(50) {
                    let symbols = db.symbolsForModule(mod.id)
                    let desc = symbols.first(where: { $0.kind == "component" })?.context ?? ""
                    prompt += "- \(mod.name): \(desc)\n"
                }
            }

            var relations: [String] = []
            for mod in contentModules.prefix(30) {
                for rel in db.relationsForModule(mod.id) {
                    relations.append("\(mod.name) → \(rel.targetId) (\(rel.type))")
                }
            }
            if !relations.isEmpty {
                prompt += "\nDependencies:\n"
                for rel in relations.prefix(30) {
                    prompt += "- \(rel)\n"
                }
            }
        }

        return prompt
    }

    private func diagramSummaries() -> (entities: String, claims: String)? {
        guard let db = semanticDatabase else { return nil }

        // Use V1 modules + symbols as primary data source
        let modules = db.allModules()
        let entities = db.uniqueEntities()
        let claims = db.allClaims()

        // Build entity summary from modules (Haiku-extracted) + old entities
        var lines: [String] = []
        for mod in modules where mod.id.hasPrefix("cmod_") {
            let symbols = db.symbolsForModule(mod.id)
            let desc = symbols.first(where: { $0.kind == "component" })?.context ?? ""
            lines.append("- \(mod.name) [\(desc)]")
        }
        for ent in entities {
            lines.append("- \(ent.name) [\(ent.type)]")
        }

        if lines.isEmpty {
            // Fallback: use headings from symbols
            let allSymbols = modules.flatMap { db.symbolsForModule($0.id) }
            let headings = allSymbols.filter { $0.kind == "heading" }
            for h in headings.prefix(50) {
                lines.append("- \(h.name)")
            }
        }

        guard !lines.isEmpty else { return nil }

        let entitySummary = lines.joined(separator: "\n")
        let claimSummary = claims.prefix(80).map { "- [\($0.safeType)] \($0.safeRawText.prefix(100))" }.joined(separator: "\n")

        return (entitySummary, claimSummary.isEmpty ? "No claims extracted" : claimSummary)

        if let compiler = incrementalCompiler {
            let entities = compiler.orchestrator.extractedEntities
            let claims = compiler.orchestrator.extractedClaims
            guard !entities.isEmpty else { return nil }
            let entitySummary = entities
                .map { "- \($0.name) [\($0.type)]" }
                .joined(separator: "\n")
            let claimSummary = claims
                .prefix(80)
                .map { "- [\($0.safeType)] \($0.safeRawText.prefix(100))" }
                .joined(separator: "\n")
            return (entitySummary, claimSummary)
        }

        return nil
    }

    private func currentDiagram(for mode: String) -> String? {
        switch mode {
        case "software":
            return softwareArchMermaid
        case "dataflow":
            return dataFlowMermaid
        case "deployment":
            return deploymentMermaid
        default:
            return nil
        }
    }

    private func setDiagram(_ mermaid: String?, for mode: String) {
        switch mode {
        case "software":
            softwareArchMermaid = mermaid
        case "dataflow":
            dataFlowMermaid = mermaid
        case "deployment":
            deploymentMermaid = mermaid
        default:
            break
        }
    }

    private func cacheDiagram(_ mermaid: String, for mode: String) {
        guard let db = semanticDatabase, let projectId = rootNode?.url.lastPathComponent else { return }
        let documentId = "__diagram_\(mode)"
        try? db.upsertDocument(
            id: documentId,
            projectId: projectId,
            filePath: ".dde/\(documentId).mmd",
            fileName: documentId,
            fileExt: "mmd",
            contentHash: mermaid
        )
    }

    private func resolveWorkspaceFileURL(filePath: String?, fallbackDocumentId: String?) -> URL? {
        let fm = FileManager.default

        if let filePath, !filePath.isEmpty {
            let directURL = URL(fileURLWithPath: filePath)
            if fm.fileExists(atPath: directURL.path) {
                return directURL
            }

            if let rootURL = rootNode?.url {
                let relativeURL = rootURL.appendingPathComponent(filePath)
                if fm.fileExists(atPath: relativeURL.path) {
                    return relativeURL
                }
            }
        }

        guard let rootURL = rootNode?.url,
              let fallbackDocumentId,
              !fallbackDocumentId.isEmpty else { return nil }

        let directURL = rootURL.appendingPathComponent(fallbackDocumentId)
        if fm.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == fallbackDocumentId {
                return url
            }
        }

        return nil
    }
}
