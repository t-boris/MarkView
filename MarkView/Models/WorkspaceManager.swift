import Foundation
import SwiftUI
import Combine
import UniformTypeIdentifiers

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
    /// Progress of the out-of-process structural index, shown ONLY in the footer.
    /// Separate from `indexingProgress` (which drives the file-tree spinner, the
    /// auto-refresh gate and the module panel) so background indexing never blocks
    /// the tree, the module explorer, or opening another folder.
    @Published var structuralIndexProgress: String?
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

    /// Closure wired by `EditorView.Coordinator` on insight tab routing. Called by
    /// `closeTab` STEP 1 of the ordered insight cleanup (Decision 11 §4) — invokes
    /// `bridge.releaseInsightBlobs(into: webView)` synchronously so any blob URLs
    /// the iframe materialised for vendored libs are revoked BEFORE
    /// `session.cancel()` allows new Combine emissions. `nil` if no insight tab has
    /// been routed yet, or if the WebView has been deallocated; either case is safe
    /// — WebView teardown on tab close GCs the blobs as a fallback.
    var releaseInsightBlobsHook: (() -> Void)?

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

    // MARK: - Markdown File Scanning (Recursive Insight)

    /// Hard cap on the number of `.md` files that `scanMarkdownFiles(in:)` will
    /// accept for a single Recursive Insight session. Folders exceeding this
    /// cap are rejected with `ScanError.folderTooLarge` (per tech-spec
    /// Decision 5 / Decision 10 §7).
    private static let insightFolderFileLimit = 500

    /// Errors raised by `scanMarkdownFiles(in:)`.
    enum ScanError: Error, LocalizedError {
        /// Folder contains more than `limit` markdown files.
        case folderTooLarge(count: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .folderTooLarge(let count, let limit):
                return "Folder too large for Recursive Insight: found \(count)+ markdown files (limit \(limit)). Try a subfolder instead."
            }
        }
    }

    /// Enumerate `.md` files in `folderURL` for Recursive Insight.
    ///
    /// Filters applied (per tech-spec Decision 10 §7):
    /// - `.skipsHiddenFiles` and `.skipsPackageDescendants` enumerator options
    ///   (the latter prevents descending into `.app` / `.bundle` / `.docset`).
    /// - Path extension must be `.md` (case-insensitive).
    /// - Paths containing `.dde` are excluded (matches existing convention).
    /// - Symlinks resolving outside `folderURL` are skipped (containment check
    ///   via `resolvingSymlinksInPath().standardizedFileURL` — order matters:
    ///   resolve symlinks BEFORE standardizing).
    ///
    /// Resource cap: returns `.failure(.folderTooLarge)` once more than
    /// `insightFolderFileLimit` matching files have been seen. Enumeration
    /// stops immediately on overflow (DoS-resistant, no full scan).
    ///
    /// Per-file size truncation is the caller's responsibility — this helper
    /// only enumerates URLs.
    func scanMarkdownFiles(in folderURL: URL) -> Result<[URL], ScanError> {
        let resolvedFolderPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        // Append the platform path separator so prefix checks cannot be bypassed
        // by sibling folders sharing a name prefix (e.g. `/x/foo` vs `/x/foobar`).
        // `URL.standardizedFileURL.path` strips trailing slashes, so guard against
        // an existing trailing `/` to avoid `//` artifacts on edge cases.
        let resolvedFolderPrefix = resolvedFolderPath.hasSuffix("/")
            ? resolvedFolderPath
            : resolvedFolderPath + "/"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .success([])
        }

        var results: [URL] = []
        let limit = WorkspaceManager.insightFolderFileLimit
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard !url.path.contains(".dde") else { continue }

            let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
            // The `==` clause covers the (unlikely) case of the folder URL itself
            // surfacing here; the prefix clause requires a path-separator boundary
            // so a sibling like `/x/foobar/secret.md` cannot pass for `/x/foo`.
            guard resolvedFile == resolvedFolderPath || resolvedFile.hasPrefix(resolvedFolderPrefix) else {
                NSLog("[Insight] Skipped symlink escape: \(url.path)")
                continue
            }

            results.append(url)
            if results.count > limit {
                return .failure(.folderTooLarge(count: results.count, limit: limit))
            }
        }
        return .success(results)
    }

    /// Cheap check for menu disabled-state: returns `true` as soon as one
    /// markdown file is found inside `rootNode`. Short-circuits on first match
    /// to keep the menu responsive even on large workspaces. The 500-file cap
    /// is intentionally NOT applied here — we exit on the first hit anyway.
    var hasMarkdownFiles: Bool {
        guard let folderURL = rootNode?.url else { return false }
        let resolvedFolderPath = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        // Same separator-aware containment as `scanMarkdownFiles(in:)` — keep in sync.
        let resolvedFolderPrefix = resolvedFolderPath.hasSuffix("/")
            ? resolvedFolderPath
            : resolvedFolderPath + "/"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard !url.path.contains(".dde") else { continue }
            let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedFile == resolvedFolderPath || resolvedFile.hasPrefix(resolvedFolderPrefix) else { continue }
            return true
        }
        return false
    }

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
                let docId = self.docId(for: url)
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

    /// Open or refresh a file — if already open, reload content from disk.
    /// Insight tabs are skipped on the refresh branch: their placeholder URL
    /// is never written to disk, so reading it back would corrupt the in-memory
    /// session. We still allow the tab to be activated by index match.
    func openOrRefreshFile(_ url: URL) {
        if let index = tabsStore.firstIndex(of: url) {
            if case .insight = openTabs[index].kind {
                tabsStore.activeTabIndex = index
                return
            }
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

    /// Canonical document id for `url` in the current workspace — path relative to
    /// the workspace root (folder root, or the parent dir for a single-file
    /// workspace). Must be used by EVERY docId producer so same-named files in
    /// different folders never collide. See `SemanticDatabase.documentId(for:root:)`.
    func docId(for url: URL) -> String {
        let root = rootNode?.url ?? url.deletingLastPathComponent()
        return SemanticDatabase.documentId(for: url, root: root)
    }

    /// Open a file in a new tab or switch to existing tab
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
            NSLog("Canvas file reference not found: \(path)")
            return
        }

        if FileType.supportedExtensions.contains(target.pathExtension.lowercased()) {
            openFile(target)
        } else {
            NSWorkspace.shared.open(target)
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
            let docId = self.docId(for: file.url)
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

        // Recursive Insight tabs (Decision 11 §4): execute the EXACT 4-step
        // ordered async close so race-prone state never ships into a different
        // step. Order is enforced by acceptance criteria — do not reorder.
        // Step 1: parent JS revokes any session blob URLs synchronously BEFORE
        //         the session is cancelled, so no Combine subscription can
        //         emit a chunk that would re-create a blob after revocation.
        // Step 2: `await session.cancel()` awaits the activeTask's natural
        //         exit (parallel Phase-2 section tasks observe Task.isCancelled
        //         and unwind cooperatively, plus any in-flight ZIP exporter
        //         Process is terminated via its onCancel hook).
        // Step 3: `try? session.cache.cleanup()` removes the on-disk session
        //         dir; ENOENT (already gone) is the success state.
        // Step 4: `tabsStore.removeTab(at:)` drops the strong reference held
        //         by OpenTab, releasing the session for ARC.
        // Skip the dirty-save prompt — insight tabs are ephemeral and never
        // carry isModified == true in the file-save sense.
        let tab = openTabs[index]
        if case .insight(let session) = tab.kind {
            let releaseHook = self.releaseInsightBlobsHook
            let sessionId = session.id
            Task { @MainActor in
                // Step 1 — parent JS releases blob URLs. The hook is wired by
                // EditorView.Coordinator on insight routing. If absent (initial
                // route lost the webView reference, etc.) the WebView teardown
                // on tab removal still GCs the blobs — skipping this step is
                // safe but suboptimal.
                releaseHook?()
                // Step 2 — await activeTask + parallel section tasks + any
                // in-flight ZIP exporter Process (cooperative cancellation).
                await session.cancel()
                // Step 3 — DO NOT cleanup cache. The cache lives at
                // `<workspace>/.markview-insight/` and persists across tab
                // close so that re-opening the insight on the same folder
                // reuses the cached HTML instead of re-running the LLM.
                // (Previous behaviour deleted the cache here, which forced
                // a full Phase 1 + Phase 2 regeneration on every reopen.)
                // Step 4 — drop the OpenTab → release session reference. The
                // captured `index` may be stale if other tabs were closed in
                // the meantime (the await above can take real time when Phase 2
                // is mid-stream), so re-resolve by sessionId before removing.
                if let liveIndex = self.openTabs.firstIndex(where: {
                    if case .insight(let s) = $0.kind { return s.id == sessionId }
                    return false
                }) {
                    self.tabsStore.removeTab(at: liveIndex)
                }
            }
            return
        }

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

    /// Save the active tab's file.
    /// Insight tabs are ephemeral (Decision 10 §7 / Task 7): the placeholder URL
    /// `.insight-<uuid>` must NEVER be written to disk. Cmd+S on an insight tab
    /// is a no-op here — the insight player has its own Save flow that calls
    /// `didRequestInsightSave` (NSSavePanel + sanitized filename + node body only).
    func saveActiveFile() {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }
        if case .insight = openTabs[activeTabIndex].kind { return }
        saveFile(at: activeTabIndex)
    }

    /// Handle selection actions: translate or explain selected text via Anthropic API.
    /// Result is shown in a popup — see `translateDocument` for the whole-document
    /// path, which produces a translated copy in a new tab instead.
    func handleSelectionAction(action: String, text: String, completion: @escaping (String, String) -> Void) async {
        guard let provider = incrementalCompiler?.orchestrator.providerClient,
              let apiKey = provider.apiKeyValue else {
            completion("Error", "No API key configured. Set it in DDE Settings.")
            return
        }

        let (systemPrompt, title): (String, String) = {
            switch action {
            case "translate_ru":
                return ("You are a professional translator. Translate the user's text to Russian word-for-word. Do NOT summarize, do NOT shorten, do NOT skip anything. Translate every single sentence. Return ONLY the translated text in markdown format.", "Перевод на русский")
            case "translate_en":
                return ("You are a professional translator. Translate the user's text to English word-for-word. Do NOT summarize, do NOT shorten, do NOT skip anything. Translate every single sentence. Return ONLY the translated text in markdown format.", "Translation to English")
            case "explain":
                return ("You are a knowledgeable assistant. Explain the following text clearly and concisely. Use markdown formatting. If it contains technical terms, define them. If it contains code, explain what it does.", "Explanation")
            default:
                return ("Process the following text.", "Result")
            }
        }()

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 8192,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
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
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(title, "API error: HTTP \(code)")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let contentBlocks = json["content"] as? [[String: Any]] else {
                completion(title, "Failed to parse API response")
                return
            }

            // Track usage
            if let usage = json["usage"] as? [String: Any],
               let db = semanticDatabase {
                let inp = usage["input_tokens"] as? Int ?? 0
                let out = usage["output_tokens"] as? Int ?? 0
                db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0003 + Double(out) * 0.0015)
            }

            let result = contentBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()

            completion(title, result.isEmpty ? "No response from AI" : result)
        } catch {
            completion(title, "Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Document Translation

    /// Which backend performs the translation. Chosen once per document so the
    /// whole file is translated by a single engine (mixing engines mid-document
    /// produces visibly inconsistent terminology).
    private enum TranslationEngine {
        case anthropic(apiKey: String)
        case ollama(model: String)

        var label: String {
            switch self {
            case .anthropic: return "Claude"
            case .ollama(let model): return "Ollama \(model)"
            }
        }
    }

    /// One atomic unit of the source document.
    ///
    /// `text` never spans a partial table, list or fenced code block, and
    /// `separator` holds the exact newline run that followed it in the source —
    /// so `prefix + chunks.map { $0.text + $0.separator }.joined()` reproduces
    /// the original document byte-for-byte. That is what lets the translated
    /// copy keep the source's block structure.
    private struct MarkdownChunk {
        var text: String
        var separator: String
        var isTranslatable: Bool
    }

    /// Structural fingerprint of a markdown fragment. A faithful translation
    /// changes the words but not any of these counts, so a mismatch means the
    /// model dropped, merged or invented structure.
    private struct MarkdownSkeleton: Equatable {
        var headingLevels: [Int] = []
        var tableRows: Int = 0
        var listItems: Int = 0
        var fences: Int = 0
        var quoteLines: Int = 0
    }

    /// Translate the whole document to `targetLang` and open the result in a new
    /// tab. The source file is never modified; the new tab is left unsaved so the
    /// user decides where (and whether) it lands on disk.
    ///
    /// Returns a message to show the user when translation could not start, or
    /// nil on success. The caller surfaces it in the editor popup — the sidebar
    /// progress line alone is easy to miss when the file tree is collapsed.
    @discardableResult
    func translateDocument(markdown: String, targetLang: String) async -> String? {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Nothing to translate — the document is empty."
        }

        // Engine choice, mirroring `reindexActiveFile`: local model first (free,
        // private), Anthropic when Ollama is not running, and a visible message
        // rather than a silent return when neither is available.
        let engine: TranslationEngine
        if ollamaClient.isConnected {
            engine = .ollama(model: ollamaClient.selectedModel)
        } else if let key = incrementalCompiler?.orchestrator.providerClient.apiKeyValue, !key.isEmpty {
            engine = .anthropic(apiKey: key)
        } else {
            NSLog("[DDE] Translation aborted: no engine available")
            return (providerRouter?.statusMessage(for: .translate)
                ?? "Configure an Anthropic API key in DDE Settings")
                + "\n\nAlternatively, start Ollama locally to translate without an API key."
        }

        // Create new tab immediately with placeholder
        let sourceTab = activeTabIndex >= 0 && activeTabIndex < openTabs.count ? openTabs[activeTabIndex] : nil
        let sourceName = sourceTab?.url.deletingPathExtension().lastPathComponent ?? "document"
        let newURL = sourceTab?.url.deletingLastPathComponent()
            .appendingPathComponent("\(sourceName)_\(targetLang.lowercased()).md") ?? URL(fileURLWithPath: "/tmp/translated.md")

        // Split at structural boundaries — never inside a table, list or code block.
        let (prefix, chunks) = splitForTranslation(markdown, maxChars: 4000)
        let translatableCount = chunks.filter { $0.isTranslatable }.count
        var parts: [String] = []
        var failedChunks: [Int] = []
        var done = 0

        /// Live progress banner, written into the tab itself. `indexingProgress`
        /// only renders in the file-tree sidebar, which may be collapsed — this
        /// is visible in the document the user is actually watching.
        func banner(_ completed: Int) -> String {
            let pct = translatableCount > 0 ? completed * 100 / translatableCount : 100
            let filled = translatableCount > 0 ? completed * 20 / translatableCount : 20
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
            return "> 🌐 **Translating to \(targetLang)** — `\(bar)` \(pct)% "
                + "(\(completed)/\(translatableCount) sections, \(engine.label))\n\n"
        }

        let translatedTab = OpenTab(url: newURL, content: banner(0), originalContent: "")
        let tabId = translatedTab.id
        tabsStore.appendTab(translatedTab)

        /// Re-resolve the tab by id on every write: the awaits below take real
        /// time and the user may open or close tabs meanwhile, which would make
        /// a captured index point at somebody else's document.
        func writeToTab(_ content: String) {
            guard let index = openTabs.firstIndex(where: { $0.id == tabId }) else { return }
            tabsStore.updateTab(at: index) { tab in
                tab.content = content
                tab.isModified = true
            }
        }

        for (i, chunk) in chunks.enumerated() {
            guard chunk.isTranslatable else {
                // Front matter and fenced code go through verbatim — never sent
                // to the model, so code can't come back "helpfully" rewritten.
                parts.append(chunk.text + chunk.separator)
                writeToTab(banner(done) + prefix + parts.joined())
                continue
            }

            done += 1
            indexingProgress = "Translating \(done)/\(translatableCount) (\(engine.label))..."

            let expected = skeleton(of: chunk.text)
            var translated = await translateChunk(chunk.text, targetLang: targetLang, engine: engine, strict: false)

            // Structural check, then one stricter retry. This is what keeps
            // tables intact when a small local model reflows them.
            if let candidate = translated, skeleton(of: candidate) != expected {
                NSLog("[DDE] Translation chunk \(i + 1): structure mismatch, retrying strictly")
                translated = await translateChunk(chunk.text, targetLang: targetLang, engine: engine, strict: true)
            }

            if let candidate = translated, skeleton(of: candidate) == expected {
                parts.append(candidate + chunk.separator)
            } else {
                // Keep the source text rather than emit corrupted markdown.
                failedChunks.append(done)   // numbered as the banner counts them
                parts.append(chunk.text + chunk.separator)
            }

            writeToTab(banner(done) + prefix + parts.joined())
        }

        var result = prefix + parts.joined()
        if !failedChunks.isEmpty {
            // Silent fallbacks previously made a partly-translated document look
            // finished. Say so, in the document itself.
            let list = failedChunks.map(String.init).joined(separator: ", ")
            result = "> ⚠️ Translation incomplete — section(s) \(list) kept in the original language "
                + "(the model's output did not preserve their structure).\n\n" + result
            NSLog("[DDE] Translation: \(failedChunks.count) chunk(s) left untranslated")
        }
        writeToTab(result)
        indexingProgress = nil
        NSLog("[DDE] Translation complete: \(chunks.count) chunks, engine \(engine.label)")
        return nil
    }

    /// Translate a single chunk. Returns nil when the call fails; the caller
    /// decides whether to retry or fall back to the source text.
    private func translateChunk(
        _ text: String,
        targetLang: String,
        engine: TranslationEngine,
        strict: Bool
    ) async -> String? {
        var systemPrompt = """
            You are a professional translator. Translate the following markdown text to \(targetLang).
            Rules:
            - Translate ONLY the text content. Keep ALL markdown formatting intact (headings, lists, code blocks, links, tables).
            - Do NOT translate code inside code blocks (```...```). Keep code exactly as-is.
            - Do NOT translate URLs, file paths, or technical identifiers.
            - Keep proper nouns, product names, and acronyms as-is.
            - Preserve the exact markdown structure — same number of headings, lists, paragraphs.
            - For tables: keep the same number of rows and columns, and keep the |---| separator row unchanged.
            - Do NOT wrap your answer in a code fence.
            - Return ONLY the translated markdown, no explanations.
            """
        if strict {
            systemPrompt += """

                IMPORTANT: your previous attempt changed the structure. Copy the layout line by line —
                same line count, same table rows, same list markers, same heading levels — and replace
                only the natural-language words.
                """
        }

        switch engine {
        case .ollama:
            guard let raw = await ollamaClient.generate(prompt: text, system: systemPrompt) else { return nil }
            return normalizeTranslation(raw)

        case .anthropic(let apiKey):
            let body: [String: Any] = [
                "model": ProviderRouter.ActionType.translate.recommendedModel,
                "max_tokens": 8192,
                "system": systemPrompt,
                "messages": [["role": "user", "content": text]]
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

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    // Never log the body: it echoes our request, which carries the key.
                    NSLog("[DDE] Translation HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return nil
                }
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let content = json["content"] as? [[String: Any]] else { return nil }

                if let usage = json["usage"] as? [String: Any] {
                    let inp = usage["input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    semanticDatabase?.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0003 + Double(out) * 0.0015)
                }

                // Join every text block — a leading non-text block would make
                // `content.first` miss the translation entirely.
                let joined = content.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined()
                return joined.isEmpty ? nil : normalizeTranslation(joined)
            } catch {
                NSLog("[DDE] Translation chunk error: \(error)")
                return nil
            }
        }
    }

    /// Strip the code fence models like to wrap whole-document answers in, and
    /// the surrounding blank lines the chunk separator already accounts for.
    private func normalizeTranslation(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 2,
           let first = lines.first?.trimmingCharacters(in: .whitespaces),
           let last = lines.last?.trimmingCharacters(in: .whitespaces),
           first.hasPrefix("```"), last == "```",
           // Only unwrap when the fence wraps the WHOLE answer.
           !lines.dropFirst().dropLast().contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .newlines)
    }

    // MARK: - Structure-aware splitting

    /// Split markdown into translation chunks without ever cutting through a
    /// table, list, block quote or fenced code block.
    ///
    /// Returns the document's leading whitespace separately so the chunks can be
    /// rejoined losslessly: `prefix + chunks.map { $0.text + $0.separator }.joined()`.
    private func splitForTranslation(_ markdown: String, maxChars: Int) -> (prefix: String, chunks: [MarkdownChunk]) {
        let (prefix, blocks) = tokenizeMarkdown(markdown)
        var chunks: [MarkdownChunk] = []
        var current: [MarkdownChunk] = []

        func flush() {
            guard !current.isEmpty else { return }
            var text = ""
            for (i, block) in current.enumerated() {
                text += block.text
                if i < current.count - 1 { text += block.separator }
            }
            chunks.append(MarkdownChunk(text: text, separator: current[current.count - 1].separator, isTranslatable: true))
            current = []
        }

        for block in blocks {
            guard block.isTranslatable else {
                flush()
                chunks.append(block)
                continue
            }
            let currentLength = current.reduce(0) { $0 + $1.text.count + $1.separator.count }
            if !current.isEmpty && currentLength + block.text.count > maxChars {
                flush()
            }
            current.append(block)
        }
        flush()
        return (prefix, chunks)
    }

    /// Break markdown into atomic blocks. Fenced code and YAML front matter are
    /// marked non-translatable so they are copied through untouched.
    private func tokenizeMarkdown(_ markdown: String) -> (prefix: String, blocks: [MarkdownChunk]) {
        let lines = markdown.components(separatedBy: "\n")
        // Each piece carries its own line terminator, so `pieces.joined()` is
        // exactly the input — including whatever the file ends with.
        let pieces: [String] = lines.enumerated().map { i, line in
            i < lines.count - 1 ? line + "\n" : line
        }
        let n = lines.count

        // .whitespacesAndNewlines, not .whitespaces: CRLF files leave a trailing
        // \r on every line, which would otherwise defeat delimiter matching.
        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespacesAndNewlines) }
        func isBlank(_ i: Int) -> Bool { trimmed(i).isEmpty }
        func isHeading(_ i: Int) -> Bool { trimmed(i).range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil }
        func isListItem(_ i: Int) -> Bool { lines[i].range(of: #"^\s{0,3}([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil }
        func isQuote(_ i: Int) -> Bool { trimmed(i).hasPrefix(">") }
        func isIndented(_ i: Int) -> Bool { lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") }
        func fenceMarker(_ i: Int) -> (char: Character, count: Int)? {
            let t = trimmed(i)
            guard let first = t.first, first == "`" || first == "~" else { return nil }
            let count = t.prefix(while: { $0 == first }).count
            return count >= 3 ? (first, count) : nil
        }
        func isTableDelimiter(_ i: Int) -> Bool {
            let t = trimmed(i)
            guard t.contains("-"), t.contains("|") else { return false }
            return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
        }
        func isTableStart(_ i: Int) -> Bool {
            lines[i].contains("|") && i + 1 < n && isTableDelimiter(i + 1)
        }
        func startsNewBlock(_ i: Int) -> Bool {
            fenceMarker(i) != nil || isHeading(i) || isListItem(i) || isQuote(i) || isTableStart(i)
        }

        var ranges: [(start: Int, end: Int, translatable: Bool)] = []
        var i = 0

        // YAML front matter — metadata, not prose: copied through as-is.
        if n > 1, trimmed(0) == "---" {
            var j = 1
            while j < n, trimmed(j) != "---" { j += 1 }
            if j < n {
                ranges.append((0, j + 1, false))
                i = j + 1
            }
        }

        while i < n {
            if isBlank(i) { i += 1; continue }
            let start = i

            if let fence = fenceMarker(i) {
                i += 1
                while i < n {
                    if let close = fenceMarker(i), close.char == fence.char, close.count >= fence.count { break }
                    i += 1
                }
                if i < n { i += 1 } // consume the closing fence
                ranges.append((start, i, false))
            } else if isTableStart(i) {
                i += 2 // header + delimiter
                while i < n, !isBlank(i), lines[i].contains("|") { i += 1 }
                ranges.append((start, i, true))
            } else if isListItem(i) || isQuote(i) {
                i += 1
                while i < n {
                    if isBlank(i) {
                        // A blank line only ends the run if what follows is not
                        // a continuation of the same list/quote.
                        var j = i
                        while j < n, isBlank(j) { j += 1 }
                        if j < n, isListItem(j) || isQuote(j) || isIndented(j) { i = j } else { break }
                    } else if isListItem(i) || isQuote(i) || isIndented(i) || !startsNewBlock(i) {
                        i += 1
                    } else {
                        break
                    }
                }
                ranges.append((start, i, true))
            } else if isHeading(i) {
                i += 1
                ranges.append((start, i, true))
            } else {
                i += 1
                while i < n, !isBlank(i), !startsNewBlock(i) { i += 1 }
                ranges.append((start, i, true))
            }
        }

        guard let firstRange = ranges.first else {
            return (markdown, [])
        }

        let prefix = pieces[0..<firstRange.start].joined()
        var blocks: [MarkdownChunk] = []
        for (idx, range) in ranges.enumerated() {
            var text = pieces[range.start..<range.end].joined()
            var separator = ""
            // Move the block's own line terminator into the separator, so the
            // model never sees (and cannot drop) a trailing newline. "\r\n" is a
            // single Character in Swift and does NOT match hasSuffix("\n"), so
            // CRLF has to be tested first or it slips through into `text`.
            if text.hasSuffix("\r\n") {
                text.removeLast()
                separator = "\r\n"
            } else if text.hasSuffix("\n") {
                text.removeLast()
                separator = "\n"
            }
            let nextStart = idx + 1 < ranges.count ? ranges[idx + 1].start : n
            separator += pieces[range.end..<nextStart].joined()
            blocks.append(MarkdownChunk(text: text, separator: separator, isTranslatable: range.translatable))
        }
        return (prefix, blocks)
    }

    /// Count the structure of a markdown fragment. Used to detect a translation
    /// that reflowed a table or dropped a list.
    private func skeleton(of text: String) -> MarkdownSkeleton {
        var result = MarkdownSkeleton()
        var insideFence = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                result.fences += 1
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if line.isEmpty { continue }
            if let match = line.range(of: #"^#{1,6}(?=\s)"#, options: .regularExpression) {
                result.headingLevels.append(line.distance(from: line.startIndex, to: match.upperBound))
            } else if line.hasPrefix(">") {
                result.quoteLines += 1
            } else if line.contains("|") {
                // Counts GFM rows with or without leading pipes. A prose line
                // containing "|" is counted on both sides, so it stays symmetric.
                result.tableRows += 1
            } else if rawLine.range(of: #"^\s{0,3}([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil {
                result.listItems += 1
            }
        }
        return result
    }

    // MARK: - Recursive Insight (Task 7)

    /// Entry point invoked by the AI Tools menu (Task 8). Validates the workspace,
    /// scans `.md` files (Task 2 helper), constructs an `InsightSession`, opens a
    /// new `.insight` tab, and kicks off `generateRoot()` without awaiting.
    /// Mirrors the `translateDocument` pattern of "create a tab immediately, then
    /// stream into it" but routes through `InsightSession` rather than driving the
    /// API call directly here.
    func startRecursiveInsight() {
        // 1. A folder must be open.
        guard let folderURL = rootNode?.url else {
            let alert = NSAlert()
            alert.messageText = "No folder open"
            alert.informativeText = "Open a folder before starting Recursive Insight."
            alert.runModal()
            return
        }

        // 2. AI provider must be ready (engines initialized = folder indexed).
        guard let provider = incrementalCompiler?.orchestrator.providerClient else {
            let alert = NSAlert()
            alert.messageText = "AI engines not ready"
            alert.informativeText = "Wait for workspace indexing to complete, or set an API key in DDE Settings."
            alert.runModal()
            return
        }

        // 3. Enumerate .md files (Task 2 helper enforces the 500-file hard cap
        //    via ScanError.folderTooLarge — surface to user as NSAlert).
        let scanResult = scanMarkdownFiles(in: folderURL)
        let mdFiles: [URL]
        switch scanResult {
        case .success(let urls):
            mdFiles = urls
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Cannot start Recursive Insight"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }

        // 4. Empty folder check.
        guard !mdFiles.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No markdown files"
            alert.informativeText = "This folder contains no .md files for Recursive Insight to summarize."
            alert.runModal()
            return
        }

        // 5. Build the session via the v2 5-arg init: construct an explicit
        // `InsightCache` rooted at `<folderURL>/.insight-cache/<sessionUUID>/` so
        // the cache lives alongside the analysed folder (Decision 4) and survives
        // for the duration of the insight tab. `closeTab`'s ordered cleanup
        // (Decision 11 §4) removes the directory via `cache.cleanup()` after
        // awaiting `session.cancel()`.
        let sessionId = UUID()
        let cache: InsightCache
        do {
            cache = try InsightCache(workspaceURL: folderURL, sessionId: sessionId)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot start Recursive Insight"
            alert.informativeText = "Failed to initialise insight cache: \(error.localizedDescription)"
            alert.runModal()
            return
        }

        let session = InsightSession(
            folderURL: folderURL,
            mdFiles: mdFiles,
            providerClient: provider,
            graphRAG: graphRAG,
            cache: cache
        )

        // 6. Build placeholder URL (never written to disk — exists only so
        //    `OpenTab.url`, `displayName`, and other file-only consumers keep
        //    working without special-casing kind).
        let placeholderURL = folderURL.appendingPathComponent(".insight-\(session.id.uuidString)")

        // 7. Append the new tab and activate it.
        let tab = OpenTab(
            url: placeholderURL,
            content: "",
            originalContent: "",
            kind: .insight(session)
        )
        tabsStore.appendTab(tab, activate: true)

        // 8. Kick off the root summary stream. We do NOT await — the UI must
        //    stay responsive while SSE chunks land.
        Task { await session.generateRoot() }
    }

    /// Resolve the `InsightSession` referenced by a bridge message. O(N≤20) scan
    /// of `openTabs`. Returns `nil` if the tab has been closed mid-message (race);
    /// callers log + return rather than crash.
    private func findInsightSession(sessionId: String) -> InsightSession? {
        for tab in openTabs {
            if case .insight(let session) = tab.kind, session.id.uuidString == sessionId {
                return session
            }
        }
        return nil
    }

    /// Strip newlines and NULs and truncate to 64 chars before logging an
    /// untrusted string from the JS bridge. Defends against log forgery
    /// (CWE-117): a compromised JS context could otherwise inject fake
    /// `[Insight]` log entries via embedded `\r\n`. The truncation also caps
    /// the cost of a malicious mega-payload.
    private static func sanitizeForLog(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: "[\\r\\n\\0]",
            with: "_",
            options: .regularExpression
        )
        return String(stripped.prefix(64))
    }

    /// Bridge forwarder: iframe finished loading and posted `insightIframeReady`.
    /// Logged for diagnostics; no further action required because the per-session
    /// 10 s load timeout is enforced by parent JS (`Resources/Editor/index.html`),
    /// not by this Swift-side path.
    func didReceiveInsightIframeReady(sessionId: String, nodeId: String) {
        guard findInsightSession(sessionId: sessionId) != nil else {
            NSLog("[Insight] didReceiveInsightIframeReady: no session for id %@ (tab closed?)",
                  Self.sanitizeForLog(sessionId))
            return
        }
        NSLog("[Insight] iframe ready for session %@ node %@",
              Self.sanitizeForLog(sessionId), Self.sanitizeForLog(nodeId))
    }

    /// Bridge forwarder: user clicked a 🤿 deep-dive control inside an iframe section.
    /// V2 signature: `(sessionId, sectionId, topicIndex)`. Defense-in-depth bounds
    /// validation lives here AND inside `session.expand` (Decision 3 — never trust
    /// untrusted JS, even after WebViewBridge schema validation).
    func didRequestInsightDeepDive(sessionId: String, sectionId: String, topicIndex: Int) {
        guard let session = findInsightSession(sessionId: sessionId) else {
            NSLog("[Insight] didRequestInsightDeepDive: no session for id %@ (tab closed?)",
                  Self.sanitizeForLog(sessionId))
            return
        }
        // Validate sectionId is in the current node's skeleton + topicIndex is
        // within the section's deepDiveTopics bounds. Out-of-range rejected with
        // a sanitized log entry; session.expand re-validates as a second layer.
        guard let skeleton = session.currentNode()?.skeleton else {
            NSLog("[Insight] didRequestInsightDeepDive: no skeleton on current node for session %@",
                  Self.sanitizeForLog(sessionId))
            return
        }
        guard let section = skeleton.sections.first(where: { $0.id == sectionId }) else {
            NSLog("[Insight] didRequestInsightDeepDive: unknown sectionId %@ for session %@",
                  Self.sanitizeForLog(sectionId), Self.sanitizeForLog(sessionId))
            return
        }
        guard let topics = section.deepDiveTopics,
              topicIndex >= 0,
              topicIndex < topics.count else {
            NSLog("[Insight] didRequestInsightDeepDive: topicIndex %d out of bounds for section %@ (topics: %d)",
                  topicIndex,
                  Self.sanitizeForLog(sectionId),
                  section.deepDiveTopics?.count ?? 0)
            return
        }
        Task { await session.expand(sectionId: sectionId, topicIndex: topicIndex) }
    }

    /// Bridge forwarder: user clicked a breadcrumb. Pure UI navigation —
    /// switches the current node to a cached one, no LLM call. Validates the
    /// nodeId payload as both a UUID-shaped string AND a member of the live
    /// session's manifest (defense-in-depth against forged postMessage from
    /// a compromised JS context per Decision 3).
    func didRequestInsightBreadcrumb(sessionId: String, nodeId: String) {
        guard let session = findInsightSession(sessionId: sessionId) else {
            NSLog("[Insight] didRequestInsightBreadcrumb: no session for id %@ (tab closed?)",
                  Self.sanitizeForLog(sessionId))
            return
        }
        guard let uuid = UUID(uuidString: nodeId) else {
            NSLog("[Insight] didRequestInsightBreadcrumb: invalid nodeId %@",
                  Self.sanitizeForLog(nodeId))
            return
        }
        // Manifest membership check (Decision 3 §3 — defense-in-depth against a
        // compromised iframe forging breadcrumb clicks for arbitrary UUIDs).
        guard session.nodes[uuid] != nil else {
            NSLog("[Insight] didRequestInsightBreadcrumb: nodeId %@ not in session manifest",
                  Self.sanitizeForLog(nodeId))
            return
        }
        Task { await session.navigateTo(nodeId: uuid) }
    }

    /// Bridge forwarder: user clicked Save (no payload — only one active insight
    /// session per WebView in v2, resolved via the active tab). Triggers the
    /// archive export pipeline (NSSavePanel → cache staging → /usr/bin/zip).
    func didRequestInsightSave() {
        guard let session = activeInsightSession() else {
            NSLog("[Insight] didRequestInsightSave: no active insight session")
            return
        }
        exportInsightArchive(sessionId: session.id.uuidString)
    }

    /// Bridge forwarder: user clicked the ↑ Up button (no payload — resolved via
    /// the active tab). Derives parentId from the current node and navigates;
    /// no-ops at root.
    func didRequestInsightUp() {
        guard let session = activeInsightSession() else {
            NSLog("[Insight] didRequestInsightUp: no active insight session")
            return
        }
        guard let parentId = session.currentNode()?.parentId else {
            NSLog("[Insight] didRequestInsightUp: already at root for session %@",
                  Self.sanitizeForLog(session.id.uuidString))
            return
        }
        Task { await session.navigateTo(nodeId: parentId) }
    }

    /// User clicked the ⟳ Regenerate button — wipe the persistent snapshot
    /// for this folder and re-run Phase 1+2 from scratch. Used when the LLM
    /// output is unsatisfying or the source `.md` files have changed.
    func didRequestInsightRegenerate() {
        guard let session = activeInsightSession() else {
            NSLog("[Insight] didRequestInsightRegenerate: no active insight session")
            return
        }
        Task { await session.regenerateRoot() }
    }

    /// User typed a custom deep-dive topic into the iframe footer input and
    /// clicked Explore. Creates a child node under the current node with the
    /// topic as the focus, re-runs Phase 1+2 (no skeleton-driven match — uses
    /// all source files since user wants a broader exploration).
    func didRequestInsightCustomDeepDive(topic: String) {
        guard let session = activeInsightSession() else {
            NSLog("[Insight] didRequestInsightCustomDeepDive: no active insight session")
            return
        }
        Task { await session.expandCustom(topic: topic) }
    }

    /// User clicked "🤿×N Explore all topics" — sequentially generate every
    /// deepDiveTopic on the current node's skeleton.
    func didRequestInsightExploreAll(depth: Int) {
        guard let session = activeInsightSession() else {
            NSLog("[Insight] didRequestInsightExploreAll: no active insight session")
            return
        }
        Task { await session.expandAllTopicsOnCurrentNode(depth: depth) }
    }

    /// User clicked "↻ Retry this section" inside a failed-section placeholder.
    /// Re-runs Phase 2 stream for ONE section on the current node.
    func didRequestInsightRetrySection(sectionId: String) {
        guard let session = activeInsightSession() else {
            NSLog("[Insight] didRequestInsightRetrySection: no active insight session")
            return
        }
        Task { await session.retrySection(sectionId: sectionId) }
    }

    /// Resolve the active tab's `InsightSession` (if the active tab is `.insight`).
    /// V2 payloads omit `sessionId` for actions that target the currently-viewed
    /// session; this helper centralises the active-tab lookup.
    private func activeInsightSession() -> InsightSession? {
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return nil }
        if case .insight(let session) = openTabs[activeTabIndex].kind {
            return session
        }
        return nil
    }

    /// Export the entire insight session as a self-contained ZIP archive
    /// (Decision 7). NSSavePanel default filename pattern:
    /// `<folderName>_insight_<ISO8601-no-colons>.zip`. On user OK:
    ///   1. Build a fresh staging dir under `NSTemporaryDirectory()` by
    ///      copying the session's cache root (so in-app navigation is
    ///      unaffected by export-time HTML rewriting).
    ///   2. Promote the root node's `nodes/<rootUUID>.html` to
    ///      `index.html` at the staging root, fixing its lib refs from
    ///      `../_assets/` to `_assets/` (it lives one level shallower
    ///      after promotion).
    ///   3. Rewrite every HTML file's deep-dive `<button>` controls into
    ///      `<a href="<targetUUID>.html">` links AND every breadcrumb
    ///      `href="#<uuid>"` into a relative file href, so the unzipped
    ///      archive navigates standalone in a browser without any JS
    ///      bridge.
    ///   4. Spawn `/usr/bin/zip` via `InsightArchiveExporter.bundle` —
    ///      explicit argument array, no `/bin/sh -c`, atomic move
    ///      `.zip.tmp` → final destination.
    ///   5. Best-effort remove the staging dir in `defer`.
    ///
    /// Sandbox note: the app currently runs with the macOS sandbox OFF
    /// (per project entitlements). If re-enabled, wrap the destination
    /// write in `pickedURL.startAccessingSecurityScopedResource()` / stop.
    func exportInsightArchive(sessionId: String) {
        guard let session = findInsightSession(sessionId: sessionId) else {
            NSLog("[Insight] exportInsightArchive: no session for id %@",
                  Self.sanitizeForLog(sessionId))
            return
        }

        // Default filename: <folder>_insight_<timestamp>.zip. Timestamp uses
        // ISO 8601 with `:` replaced by `-` (Finder display + case-insensitive
        // filesystem safety).
        let folderHint = Self.sanitizeInsightFilename(session.folderURL.lastPathComponent)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let defaultName = "\(folderHint)_insight_\(timestamp).zip"

        let panel = NSSavePanel()
        if let zipType = UTType(filenameExtension: "zip") {
            panel.allowedContentTypes = [zipType]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName

        guard panel.runModal() == .OK, let pickedURL = panel.url else { return }

        // Force `.zip` extension regardless of user input — keeps the bundled
        // archive recognisable to the OS even if the user typed a bare name.
        let destinationURL: URL
        if pickedURL.pathExtension.lowercased() == "zip" {
            destinationURL = pickedURL
        } else {
            destinationURL = pickedURL.deletingPathExtension().appendingPathExtension("zip")
        }

        // Snapshot the session's in-memory node tree NOW (on @MainActor) before
        // the async export Task runs — avoids races with concurrent navigation
        // mutating `session.nodes` while we walk children for the deep-dive
        // mapping. The snapshot only stores (parentId, sectionId)+orderIndex.
        let nodeChildMap = Self.buildExportNodeChildMap(session: session)
        // Root node = the unique level-0 node (parentId == nil). Resolved here
        // from the @MainActor snapshot of `session.nodes` so the export Task
        // does not need to re-touch session state.
        let rootNodeId = session.nodes.values.first { $0.parentId == nil }?.id
        let cache = session.cache

        // ALWAYS rewrite every node's HTML from the current in-memory state
        // using the latest buildHTMLTemplate code. Otherwise the export
        // would use whatever HTML happened to be in cache from older
        // generations — missing recent CSS additions, bootstrap, etc. This
        // also picks up retried-section content that wasn't in the cache yet.
        for (id, node) in session.nodes {
            guard let skel = node.skeleton else { continue }
            // Build breadcrumbs for this node.
            var crumbs: [(nodeId: String, title: String)] = []
            var cursor: InsightNode? = node
            while let n = cursor {
                crumbs.insert((n.id.uuidString, n.title), at: 0)
                cursor = n.parentId.flatMap { session.nodes[$0] }
            }
            let html = InsightSession.buildHTMLTemplate(
                skeleton: skel,
                sectionStates: node.sectionStates,
                breadcrumbs: crumbs,
                libRefMode: .exportRelative,
                cache: cache
            )
            try? cache.writeNode(nodeId: id, html: html)
        }

        Task { @MainActor in
            do {
                let stagingURL = try await cache.archiveStagingDirectory()
                // Copy staging contents into a fresh temp dir so HTML rewriting
                // does not mutate the live cache (in-app navigation may continue
                // to read it after export). The copy lives until `defer` removes
                // it on this Task's exit (success OR failure OR cancellation).
                let exportRoot = try Self.makeExportStagingCopy(from: stagingURL)
                defer { try? FileManager.default.removeItem(at: exportRoot) }

                // Promote root node + rewrite all HTML for standalone browsing.
                try Self.rewriteForStandaloneExport(
                    exportRoot: exportRoot,
                    rootNodeId: rootNodeId,
                    nodeChildMap: nodeChildMap
                )

                let exporter = InsightArchiveExporter()
                try await exporter.bundle(stagingURL: exportRoot, to: destinationURL)
            } catch is CancellationError {
                NSLog("[Insight] exportInsightArchive: cancelled")
            } catch InsightArchiveExporterError.cancelled {
                NSLog("[Insight] exportInsightArchive: cancelled mid-zip")
            } catch {
                let alert = NSAlert()
                alert.messageText = "ZIP export failed"
                alert.informativeText = Self.sanitizeForLog(error.localizedDescription)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Mapping snapshot used by the standalone-export HTML rewriter. Keyed by
    /// parent node id; for each parent stores the (sectionId, topicIndex) →
    /// child node id resolution. Built from the in-memory tree at export time
    /// because (sectionId, topicIndex) is NOT stored on `InsightNode` directly
    /// — child creation order in `parent.children` is the only mapping signal.
    /// Per `expand(sectionId:topicIndex:)`, child.title == topic.label, so we
    /// match on label as the canonical key.
    private static func buildExportNodeChildMap(
        session: InsightSession
    ) -> [UUID: [String: [Int: UUID]]] {
        var map: [UUID: [String: [Int: UUID]]] = [:]
        for parent in session.nodes.values {
            guard let skeleton = parent.skeleton else { continue }
            // For each child of this parent, resolve which (sectionId, topicIndex)
            // produced it. Match by `child.title == topic.label`.
            let childNodes = parent.children.compactMap { session.nodes[$0] }
            for section in skeleton.sections {
                guard let topics = section.deepDiveTopics else { continue }
                for (idx, topic) in topics.enumerated() {
                    if let child = childNodes.first(where: { $0.title == topic.label }) {
                        var sectionMap = map[parent.id] ?? [:]
                        var topicMap = sectionMap[section.id] ?? [:]
                        topicMap[idx] = child.id
                        sectionMap[section.id] = topicMap
                        map[parent.id] = sectionMap
                    }
                }
            }
        }
        return map
    }

    /// Copy `cacheRoot` to a fresh temp directory under `NSTemporaryDirectory()`.
    /// Returns the new export staging root. Caller is responsible for removing
    /// the directory (typically via `defer`).
    private static func makeExportStagingCopy(from cacheRoot: URL) throws -> URL {
        let fm = FileManager.default
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("insight-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempBase, withIntermediateDirectories: true)
        // Copy CONTENTS of cacheRoot into tempBase (not cacheRoot itself), so
        // tempBase ends up containing `nodes/`, `_assets/`, `manifest.json`
        // directly at its root (matching the archive layout).
        let entries = try fm.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for src in entries {
            let dst = tempBase.appendingPathComponent(src.lastPathComponent)
            try fm.copyItem(at: src, to: dst)
        }
        return tempBase
    }

    /// Walk the staging dir and:
    ///   1. Promote `nodes/<rootUUID>.html` to `index.html` at the export
    ///      root, fixing its lib refs from `../_assets/` to `_assets/` (one
    ///      level shallower) and breadcrumbs from `href="#<uuid>"` to
    ///      `nodes/<uuid>.html`.
    ///   2. For each non-root `nodes/<uuid>.html`, rewrite breadcrumbs to
    ///      sibling `<uuid>.html` (or `../index.html` for root) AND replace
    ///      every `<button class="deep-dive" data-section-id="…"
    ///      data-topic-index="…">…</button>` with an `<a class="deep-dive"
    ///      href="<childUUID>.html">…</a>` if a child exists for that
    ///      (sectionId, topicIndex). Buttons without a matching child are
    ///      left intact (inert in standalone browser, by design — user did
    ///      not expand that topic in-session).
    private static func rewriteForStandaloneExport(
        exportRoot: URL,
        rootNodeId: UUID?,
        nodeChildMap: [UUID: [String: [Int: UUID]]]
    ) throws {
        let fm = FileManager.default
        let nodesDir = exportRoot.appendingPathComponent("nodes", isDirectory: true)

        // Promote root: copy `nodes/<rootUUID>.html` → `index.html`, with lib
        // refs unshifted to top-level `_assets/`. Original file in `nodes/`
        // stays put so breadcrumb-up navigation from non-root nodes can also
        // target `../index.html` consistently.
        if let rootId = rootNodeId {
            let rootSrc = nodesDir.appendingPathComponent("\(rootId.uuidString).html")
            let rootDst = exportRoot.appendingPathComponent("index.html")
            if fm.fileExists(atPath: rootSrc.path) {
                var html = (try? String(contentsOf: rootSrc, encoding: .utf8)) ?? ""
                // Lib refs: `../_assets/<file>` → `_assets/<file>` (root is one
                // level shallower than nodes/<uuid>.html in the export tree).
                html = html.replacingOccurrences(of: "\"../_assets/", with: "\"_assets/")
                // Deep-dive buttons → links targeting `nodes/<childUUID>.html`.
                html = rewriteDeepDiveButtons(
                    in: html,
                    parentNodeId: rootId,
                    nodeChildMap: nodeChildMap,
                    childHrefPrefix: "nodes/"
                )
                // Root has no breadcrumbs (single-element breadcrumb is the
                // root itself, rendered as `<span class="crumb-active">`); but
                // a defensive sweep handles any future schema change.
                html = rewriteBreadcrumbHrefs(
                    in: html,
                    isRoot: true,
                    rootNodeId: rootId
                )
                try html.write(to: rootDst, atomically: true, encoding: .utf8)
            }
        }

        // Rewrite every `nodes/<uuid>.html`. Root copy stays so the non-root
        // breadcrumbs can target it via `../index.html` (preferred) — we use
        // `index.html` rather than `nodes/<rootUUID>.html` for the root crumb
        // because that's the canonical entry point for standalone viewers.
        guard fm.fileExists(atPath: nodesDir.path) else { return }
        let nodeFiles = try fm.contentsOfDirectory(
            at: nodesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for nodeFile in nodeFiles where nodeFile.pathExtension.lowercased() == "html" {
            let stem = nodeFile.deletingPathExtension().lastPathComponent
            guard let nodeId = UUID(uuidString: stem) else { continue }
            var html = (try? String(contentsOf: nodeFile, encoding: .utf8)) ?? ""
            html = rewriteDeepDiveButtons(
                in: html,
                parentNodeId: nodeId,
                nodeChildMap: nodeChildMap,
                childHrefPrefix: "" // sibling under nodes/
            )
            html = rewriteBreadcrumbHrefs(
                in: html,
                isRoot: (nodeId == rootNodeId),
                rootNodeId: rootNodeId
            )
            try html.write(to: nodeFile, atomically: true, encoding: .utf8)
        }
    }

    /// Replace every `<button class="deep-dive" data-section-id="X"
    /// data-topic-index="Y" title="…">label</button>` with an anchor pointing
    /// to the child node's HTML. Buttons without a matching child are left
    /// untouched (no JS in standalone export ⇒ they become inert by design).
    private static func rewriteDeepDiveButtons(
        in html: String,
        parentNodeId: UUID,
        nodeChildMap: [UUID: [String: [Int: UUID]]],
        childHrefPrefix: String
    ) -> String {
        guard let sectionMap = nodeChildMap[parentNodeId], !sectionMap.isEmpty else {
            return html
        }
        // Pattern targets the deterministic shape from `buildHTMLTemplate`:
        //   <button class="deep-dive" data-section-id="ID" data-topic-index="IDX" title="HINT">🤿 LABEL</button>
        // Use a regex with capture groups so we can introspect (section, idx)
        // and look up the child UUID; non-matches survive unchanged.
        let pattern = #"<button class="deep-dive" data-section-id="([^"]*)" data-topic-index="([0-9]+)" title="([^"]*)">([^<]*)</button>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        let nsString = html as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: html, range: fullRange)
        // Process in reverse so substring ranges remain valid as we mutate.
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges == 5 else { continue }
            let sectionId = nsString.substring(with: match.range(at: 1))
            guard let topicIdx = Int(nsString.substring(with: match.range(at: 2))) else { continue }
            let title = nsString.substring(with: match.range(at: 3))
            let label = nsString.substring(with: match.range(at: 4))
            guard let childId = sectionMap[sectionId]?[topicIdx] else { continue }
            let href = "\(childHrefPrefix)\(childId.uuidString).html"
            // Anchor variant — already-escaped fields stay escaped (we only
            // splice the URL we control). class+title kept identical.
            let replacement = "<a class=\"deep-dive\" href=\"\(href)\" title=\"\(title)\">\(label)</a>"
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: replacement)
        }
        return result
    }

    /// Rewrite every breadcrumb `<a class="crumb" href="#<uuid>">` to a
    /// relative file href so standalone-browser navigation works.
    /// - Root file (`index.html`) breadcrumbs target `nodes/<uuid>.html`
    ///   (children below the root).
    /// - Non-root files (`nodes/<uuid>.html`) target sibling
    ///   `<uuid>.html`, EXCEPT the root crumb which targets `../index.html`.
    private static func rewriteBreadcrumbHrefs(
        in html: String,
        isRoot: Bool,
        rootNodeId: UUID?
    ) -> String {
        // Pattern targets: <a class="crumb" href="#UUID"> — the embedded `"#`
        // sequence inside the regex requires `##"..."##` raw-string delimiter
        // so the early `"#` does not terminate the literal.
        let pattern = ##"<a class="crumb" href="#([0-9A-Fa-f-]+)">"##
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let nsString = html as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: html, range: fullRange)
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let uuidStr = nsString.substring(with: match.range(at: 1))
            guard let crumbUUID = UUID(uuidString: uuidStr) else { continue }
            let href: String
            if crumbUUID == rootNodeId {
                href = isRoot ? "index.html" : "../index.html"
            } else {
                href = isRoot ? "nodes/\(crumbUUID.uuidString).html" : "\(crumbUUID.uuidString).html"
            }
            let replacement = "<a class=\"crumb\" href=\"\(href)\">"
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: replacement)
        }
        return result
    }

    /// Sanitize an insight node title into a safe default filename stem (no
    /// extension): keep STRICT ASCII `[A-Za-z0-9_]`, replace anything else
    /// with `_`, collapse runs of `_`, trim leading/trailing `_`, fall back
    /// to `"insight"` when empty (Decision 10 §7 / Task 7 spec).
    ///
    /// The previous implementation used `Character.isLetter`/`isNumber` which
    /// are Unicode-aware (Cyrillic letters, Arabic-Indic digits, RTL-overrides
    /// classified as letters all leak through). The spec calls for the strict
    /// ASCII regex class; using `Set<Character>` membership matches it exactly
    /// without bringing in NSRegularExpression. NSSavePanel still lets the user
    /// override the suggested name — this is just the default.
    private static let insightFilenameAllowed: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
    )

    private static func sanitizeInsightFilename(_ title: String) -> String {
        let mapped = String(title.map { ch -> Character in
            insightFilenameAllowed.contains(ch) ? ch : "_"
        })
        // Collapse runs of underscores; `omittingEmptySubsequences: true` also
        // trims leading/trailing `_` because they produce empty leading/trailing
        // subsequences which are dropped before joining.
        let collapsed = mapped
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        if collapsed.isEmpty {
            return "insight"
        }
        return collapsed
    }

    /// Save a file at the given index.
    /// Defense-in-depth: insight tabs are guarded here too — even if a future
    /// caller forgets the kind-check, the placeholder URL never reaches `write(to:)`.
    private func saveFile(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }

        let tab = openTabs[index]
        if case .insight = tab.kind { return }
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
        // Insight tabs have a placeholder URL that does not exist on disk —
        // re-indexing it would create a bogus `.insight-<uuid>` doc in SQLite.
        if case .insight = tab.kind { return }
        reindexFile(fileURL: tab.url, content: tab.content)
    }

    private func reindexFile(fileURL: URL, content: String) {
        guard let db = semanticDatabase else { return }
        let docId = self.docId(for: fileURL)

        // Compute new hash
        var h: UInt32 = 0x811c9dc5
        for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        let newHash = String(h, radix: 16)

        NSLog("[DDE] Re-indexing: \(docId)")

        // Update hash
        try? db.upsertDocument(id: docId, projectId: fileURL.deletingPathExtension().lastPathComponent,
                               filePath: fileURL.path, fileName: fileURL.lastPathComponent, fileExt: "md",
                               contentHash: newHash)

        // Re-index FTS
        db.indexDocumentFTS(documentId: docId, title: fileURL.deletingPathExtension().lastPathComponent, content: content)

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

    /// Update the content of the active tab.
    /// Insight tabs own their content via `InsightSession`; the JS bridge must
    /// not write back into `tab.content` because (a) it would race with the SSE
    /// stream, and (b) `isModified` would flip true and prime an unwanted Cmd+S
    /// write to the placeholder URL.
    func updateActiveTabContent(_ content: String) {
        tabsStore.updateActiveTab { tab in
            if case .insight = tab.kind { return }
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
    /// Insight tabs are skipped: their URL is a placeholder that never exists on disk
    /// (see `startRecursiveInsight`). Reading it back would either fail (today) or,
    /// worse, clobber `tab.content` with stale data if a stray write ever produced
    /// the file. Returning nil leaves the insight player's state untouched.
    func reloadActiveTabFromDisk() -> String? {
        let idx = activeTabIndex
        guard idx >= 0 && idx < openTabs.count else { return nil }
        if case .insight = openTabs[idx].kind { return nil }

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

    /// Handle block delta from JS extraction — wrapped in safety guard.
    /// The insight player does not run the DDE block extractor, so this path
    /// should not fire for insight tabs in practice; the kind-check is defense
    /// in depth so a stray delta cannot pollute SQLite with a `.insight-<uuid>` doc.
    func handleBlocksDelta(_ delta: BlocksDelta) {
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return }
        guard !delta.isEmpty else { return }
        if case .insight = openTabs[activeTabIndex].kind { return }

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
            let docId = self.docId(for: tab.url)
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
    /// Live structural-index child processes — retained PROCESS-WIDE (static) until
    /// they exit so their `terminationHandler` always fires, independent of which
    /// `WorkspaceManager` instance (windows create several) spawned them. A `Process`
    /// with no strong reference is released when the spawning scope returns and its
    /// handler then never runs.
    private static var runningIndexers: [Process] = []

    /// Run structural indexing in a SEPARATE PROCESS (re-exec of this binary with
    /// `--dde-index <folder>`) so the directory scan never competes with the UI.
    /// The child writes modules/documents/symbols/FTS straight to the shared SQLite
    /// DB (WAL + busy_timeout); on exit the app reloads cached results from disk.
    private func runStructuralIndex(at url: URL) {
        guard let exePath = Bundle.main.executablePath else {
            Self.debugLog("runStructuralIndex: no executablePath")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exePath)
        proc.arguments = ["--dde-index", url.path]
        proc.standardOutput = FileHandle.nullDevice

        // Stream the child's stderr live so its progress shows in the footer.
        // Draining the pipe also prevents the child blocking on a full buffer.
        let pipe = Pipe()
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { fh.readabilityHandler = nil; return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            for raw in chunk.split(separator: "\n") {
                let line = String(raw)
                guard let r = line.range(of: "[mvindexer] ") else { continue }
                let msg = String(line[r.upperBound...])
                // The child emits bare "N/M" progress ticks; show them as a count.
                guard msg.range(of: #"^\d+/\d+$"#, options: .regularExpression) != nil else { continue }
                Task { @MainActor in self?.structuralIndexProgress = "Indexing \(msg) files" }
            }
        }

        proc.terminationHandler = { [weak self] p in
            // terminationHandler runs off the main actor → log via a direct file
            // write (debugLog is @MainActor) so we can confirm the handler fired
            // even before hopping back to the main actor for the UI refresh.
            let line = "\(ISO8601DateFormatter().string(from: Date())) structural index process exited code=\(p.terminationStatus)\n"
            if let h = FileHandle(forWritingAtPath: NSHomeDirectory() + "/markview_debug.log") {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
            }
            Task { @MainActor in
                WorkspaceManager.runningIndexers.removeAll { $0 === p }
                guard let self = self else { return }
                self.structuralIndexProgress = nil  // hide footer progress
                self.loadCachedResults()
                self.refreshSemanticViews()
            }
        }

        do {
            structuralIndexProgress = "Indexing…"  // footer only; updated from child stderr
            try proc.run()
            Self.runningIndexers.append(proc)  // retain until terminationHandler fires
            Self.debugLog("structural index process launched pid=\(proc.processIdentifier)")
        } catch {
            structuralIndexProgress = nil
            Self.debugLog("structural index process FAILED to launch: \(error)")
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
                // Detached context (off MainActor) → use the static helper directly.
                let docId = SemanticDatabase.documentId(for: fileURL, root: folderURL)
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
