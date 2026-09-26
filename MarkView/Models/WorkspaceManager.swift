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

    /// Move a tab to `target` (the position it takes); the active tab stays active.
    func moveTab(id: UUID, to target: Int) {
        guard let from = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let activeID = openTabs.indices.contains(activeTabIndex) ? openTabs[activeTabIndex].id : nil
        let tab = openTabs.remove(at: from)
        let destination = min(max(0, target > from ? target - 1 : target), openTabs.count)
        openTabs.insert(tab, at: destination)
        if let activeID, let index = openTabs.firstIndex(where: { $0.id == activeID }) { activeTabIndex = index }
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

    var opensGraphCreator: Bool {
        switch self {
        case .architecture, .dataflow, .pipeline, .deployment, .sequence, .er:
            return true
        case .critic, .research, .audit, .codemap:
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

    @Published var semanticDatabase: SemanticDatabase?
    @Published var incrementalCompiler: IncrementalCompiler?
    @Published var embeddingClient = EmbeddingClient()
    @Published var gitClient = GitClient()
    /// Pull requests, issues and Actions of the folder's GitHub repository.
    let gitHub = GitHubStore()
    /// Feature workspaces of the folder (docs/features/<slug>/…).
    let features = FeatureStore()
    /// Where the AI terminal starts: the open folder, or a single file's folder.
    @Published private(set) var aiWorkspaceRoot: URL?
    /// The AI panel's terminals, in tab order: Claude Code, Codex or a plain shell each.
    @Published private(set) var aiTerminals: [TerminalSession] = []
    /// The terminal shown in the AI panel.
    @Published var activeAITerminalID: UUID?
    /// Terminals opened in folders, shown as editor tabs (keyed by tab id).
    private var terminalTabs: [UUID: TerminalSession] = [:]
    private var openFilesWatcher: Timer?
    /// Last seen modification dates of open files (to reload what the assistant changed).
    private var openFileDates: [URL: Date] = [:]
    /// Project architecture (Architecture tab).
    let architecture = ArchitectureStore()
    /// AI margin notes for code files (code viewer → Explain).
    let codeExplain = CodeExplainStore()
    /// Go to definition / find usages, jump history and AI answers about selected code.
    let codeNav = CodeNavigationStore()
    /// The open folder looks like a software project (manifest or source files).
    @Published var isCodeProject = false
    @Published var graphRAG: GraphRAG?
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
    @Published var semanticRefreshVersion: Int = 0
    @Published var themeVersion: Int = 0
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

    /// Folder reopened on the next launch; cleared by Close Folder.
    static let lastFolderKey = "workspace.lastFolder"

    func openFolder(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.lastFolderKey)
        fileTreeStore.reset()  // Clear previous tree so progress spinner is shown
        tabsStore.reset()
        architecture.reset()
        folderXRays = [:]
        codeNav.reset()
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

            // Code projects get a prominent "Open Architecture" on the welcome screen.
            let isCode = await Task.detached { ArchitectureScanner.looksLikeCodeProject(url) }.value
            if rootNode?.url == url { isCodeProject = isCode }
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
            self.graphRAG = GraphRAG(db: db)
            self.aiWorkspaceRoot = url
            Self.debugLog("initDDE: engines created")

            indexingProgress = "Connecting services..."
            try? await Task.sleep(nanoseconds: 100_000_000)

            gitClient.setup(at: url)
            setUpGitHub(at: url)
            setUpFeatures(at: url)
            Self.debugLog("initDDE: git setup done")

            // Load cached diagrams and analysis results from database
            loadCachedResults()

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
    /// There is no file-count limit: folders too large to inline are handed to
    /// the AI CLI as a catalog plus read-only folder access (see GraphRAG).
    ///
    /// Per-file size truncation is the caller's responsibility — this helper
    /// only enumerates URLs.
    func scanMarkdownFiles(in folderURL: URL) -> [URL] {
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
            return []
        }

        var results: [URL] = []
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
        }
        return results
    }

    /// Cheap check for menu disabled-state: returns `true` as soon as one
    /// markdown file is found inside `rootNode`. Short-circuits on first match
    /// to keep the menu responsive even on large workspaces.
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
                // Remove from FTS
                db.indexDocumentFTS(documentId: docId, title: "", content: "")
            }
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
    /// Open or refresh a file — if already open, reload content from disk.
    /// Insight tabs are skipped on the refresh branch: their placeholder URL
    /// is never written to disk, so reading it back would corrupt the in-memory
    /// session. We still allow the tab to be activated by index match.
    func openOrRefreshFile(_ url: URL) {
        if let index = tabsStore.firstIndex(of: url) {
            if !openTabs[index].isFileBacked {
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

        // Images: the image viewer reads the file itself.
        if FileType.isImage(url) {
            var tab = OpenTab(url: url, content: "", originalContent: "")
            tab.kind = .image
            tabsStore.appendTab(tab)
            addRecentFile(url)
            return
        }

        openTextFile(url)
    }

    /// The image viewer's "Source" (SVG): replace the image tab with the file as text.
    func openImageAsText(_ url: URL) {
        if let index = tabsStore.firstIndex(of: url), case .image = openTabs[index].kind {
            tabsStore.removeTab(at: index)
        }
        openTextFile(url)
    }

    private func openTextFile(_ url: URL) {
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

    // MARK: - Workspace metadata

    /// Everything MarkView has written into the open folder: the index database and
    /// caches (`.dde/`), Recursive Insight pages and a CLAUDE.md it generated.
    func metadataItems() -> [URL] {
        guard let root = rootNode?.url else { return [] }
        let fm = FileManager.default
        var items = [root.appendingPathComponent(".dde"), root.appendingPathComponent(".markview-insight")]
            .filter { fm.fileExists(atPath: $0.path) }
        let claude = root.appendingPathComponent(".claude/CLAUDE.md")
        if let text = try? String(contentsOf: claude, encoding: .utf8),
           text.hasPrefix("# Project Context — Auto-generated by MarkView DDE") {
            items.append(claude)
        }
        return items
    }

    /// Delete this folder's metadata after confirmation. With `recreate`, rebuild the
    /// index right away; otherwise nothing is written again until the folder is
    /// reopened or Recreate is chosen.
    func removeMetadata(recreate: Bool) {
        guard let root = rootNode?.url else { return }
        let items = metadataItems()
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
        structuralIndexer?.terminate()
        structuralIndexer = nil
        for tab in openTabs {
            if case .insight(let session) = tab.kind { Task { await session.cancel() } }
        }
        let keep = openTabs.enumerated().filter { $0.element.isFileBacked }.map(\.offset)
        for index in openTabs.indices.reversed() where !keep.contains(index) { tabsStore.removeTab(at: index) }
        releaseWorkspaceEngines()
        architecture.reset()
        folderXRays = [:]
        codeExplain.reset()
        indexingProgress = nil
        structuralIndexProgress = nil

        var failures: [String] = []
        for item in items {
            do { try FileManager.default.removeItem(at: item) } catch { failures.append(item.lastPathComponent) }
        }
        let claudeDir = root.appendingPathComponent(".claude")
        if (try? FileManager.default.contentsOfDirectory(atPath: claudeDir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: claudeDir)
        }
        if !failures.isEmpty {
            let error = NSAlert()
            error.messageText = "Some items could not be deleted"
            error.informativeText = failures.joined(separator: ", ")
            error.runModal()
        }
        Self.debugLog("removeMetadata: \(items.count) items removed from \(root.path), recreate=\(recreate)")
        if recreate {
            Task { await initDDEWorkspaceAsync(at: root) }
        }
    }

    // MARK: - Code explanations

    /// Workspace-relative path used as the cache key for a file's notes.
    func workspaceRelativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let root = rootNode?.url.standardizedFileURL.path, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    private func explainDirectory(for url: URL) -> URL {
        // A pull request's copy of a project file keeps its notes with the project's.
        if architecture.prRelativePath(for: url) != nil, let root = rootNode?.url {
            return root.appendingPathComponent(".dde/cache/explain", isDirectory: true)
        }
        return cacheDirectory(for: url).appendingPathComponent("explain", isDirectory: true)
    }

    /// AI filters available to the code viewer: Importance and the user's own.
    private var aiFilters: [ImportanceRater.Filter] { ImportanceRater.allFilters }

    /// Create or delete a user filter (from the Architecture tab or the code viewer).
    func createFilter(name: String, criterion: String) {
        ImportanceRater.addFilter(name: name, criterion: criterion)
        allXRayStores.forEach { $0.filtersChanged() }
        codeExplain.filtersChanged()
    }

    /// The one-off AI filter from a filter box (X-Ray or notes); empty clears it.
    func setTemporaryFilter(_ criterion: String) {
        if let previous = ImportanceRater.setTemporaryFilter(criterion) {
            architecture.forgetRatings(filterId: previous.id, db: semanticDatabase)
            folderXRays.values.forEach { $0.forgetRatings(filterId: previous.id, db: nil) }
        }
        allXRayStores.forEach { $0.filtersChanged() }
        codeExplain.filtersChanged()
    }

    func deleteFilter(id: String) {
        ImportanceRater.removeFilter(id: id)
        architecture.forgetRatings(filterId: id, db: semanticDatabase)
        codeExplain.filtersChanged()
    }

    /// Project path of a file in the code viewer. A file shown from a fetched pull request
    /// (MarkView's cache) counts as that project path, so its notes, explanations and PR
    /// lens are all about the same file.
    private func codePath(for url: URL) -> String {
        architecture.prRelativePath(for: url) ?? workspaceRelativePath(url)
    }

    /// Load cached notes for a code file that just opened.
    func prepareCodeNotes(for url: URL) {
        codeExplain.load(path: codePath(for: url), directory: explainDirectory(for: url))
        codeNav.sendState(url: url)
    }

    /// The margin panel state for `url`, as a JSON object literal.
    func codeNotesJSON(for url: URL) -> String {
        let content = openTabs.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.content ?? ""
        let path = codePath(for: url)
        return codeExplain.payloadJSON(path: path, content: content, filters: aiFilters,
                                       pr: architecture.prFileNotes(path: path, content: content),
                                       search: architecture.searchNotes(path: path))
    }

    // MARK: - Explain with AI

    /// "Explain with AI — everything related" on a code element: the X-Ray's ⚡ search for
    /// it, with everything connected to it in red.
    func explainSymbol(name: String, path: String, line: Int) {
        guard rootNode != nil, CodeNavigator.isNavigable(name) else { return }
        let criterion = "\(name) — \((path as NSString).lastPathComponent):\(line)"
        architecture.searchSymbols[criterion] = XRaySearch.Symbol(name: name, path: path, line: line)
        setTemporaryFilter(criterion)
        openArchitecture()
        if let id = ImportanceRater.temporaryFilter?.id { architecture.activate(filterId: id) }
    }

    /// Show the active markdown document with Explain notes (like code), or back as a document.
    func setNotesView(_ show: Bool) {
        tabsStore.updateActiveTab { tab in
            guard tab.isFileBacked else { return }
            tab.notesView = show
        }
    }

    /// Requests from the code viewer's margin panel.
    func handleCodeAction(_ action: String, payload: [String: Any], url: URL) {
        guard let tab = openTabs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let root = rootNode?.url ?? url.deletingLastPathComponent()
        let path = codePath(for: url)
        switch action {
        case "explain":
            codeExplain.explain(path: path, content: tab.content, root: root, directory: explainDirectory(for: url),
                                db: semanticDatabase)
        case "rate":
            let id = payload["filter"] as? String ?? ImportanceRater.importance.id
            guard let filter = aiFilters.first(where: { $0.id == id }) else { return }
            codeExplain.rate(path: path, content: tab.content, filter: filter, root: root,
                             directory: explainDirectory(for: url), db: semanticDatabase)
        case "freshness":
            codeExplain.freshness(path: path, root: root, directory: explainDirectory(for: url))
        case "explainPR":
            architecture.explainPRFile(path: path, root: root, db: semanticDatabase)
        case "createFilter":
            createFilter(name: payload["name"] as? String ?? "", criterion: payload["criterion"] as? String ?? "")
        case "tempFilter":
            setTemporaryFilter(payload["criterion"] as? String ?? "")
        case "explainSymbol":
            guard let name = payload["name"] as? String else { return }
            explainSymbol(name: name, path: path, line: (payload["line"] as? NSNumber)?.intValue ?? 1)
        case "navDefinition", "navUsages", "navOpen", "navBack", "navForward", "askAI", "askStop":
            handleNavigation(action, payload: payload, url: url, path: path, root: root)
        default:
            break
        }
    }

    /// Go to definition, find usages, history and AI questions from the code viewer.
    private func handleNavigation(_ action: String, payload: [String: Any], url: URL, path: String, root: URL) {
        let line = (payload["line"] as? NSNumber)?.intValue ?? 1
        let here = CodeNavigationStore.Place(url: url.standardizedFileURL, line: line)
        let open: (URL, Int) -> Void = { [weak self] target, line in self?.openFile(target, line: line) }
        switch action {
        case "navDefinition":
            guard let name = payload["name"] as? String else { return }
            codeNav.goToDefinition(name: name, line: line, url: url, path: path, root: root, open: open)
        case "navUsages":
            guard let name = payload["name"] as? String else { return }
            codeNav.findUsages(name: name, url: url, path: path, root: root)
        case "navOpen":
            // A result from the viewer's list or a `path:line` in an AI answer: a file inside
            // the project only. A bare or partial path is looked up by its ending.
            guard let target = payload["path"] as? String, let targetLine = (payload["target"] as? NSNumber)?.intValue else { return }
            let base = root.standardizedFileURL.path + "/"
            let file = root.appendingPathComponent(target).standardizedFileURL
            if file.path.hasPrefix(base), FileManager.default.fileExists(atPath: file.path) {
                codeNav.jump(from: here, to: file, line: targetLine, open: open)
                return
            }
            let suffix = "/" + target.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            let current = path
            Task {
                let match = await Task.detached(priority: .userInitiated) { () -> String? in
                    let candidates = ArchitectureScanner.listFiles(root: root).filter { ("/" + $0).hasSuffix(suffix) }
                    // Nearest to the file the question was about.
                    let folder = (current as NSString).deletingLastPathComponent
                    return candidates.max { a, b in
                        a.commonPrefix(with: folder).count < b.commonPrefix(with: folder).count
                    }
                }.value
                guard let match else { return }
                codeNav.jump(from: here, to: root.appendingPathComponent(match), line: targetLine, open: open)
            }
        case "navBack":
            codeNav.goBack(current: here, open: open)
        case "navForward":
            codeNav.goForward(current: here, open: open)
        case "askAI":
            guard let id = payload["id"] as? String, let question = payload["question"] as? String,
                  let snippet = payload["text"] as? String, !snippet.isEmpty else { return }
            let start = (payload["start"] as? NSNumber)?.intValue ?? 1
            let history = (payload["history"] as? [[String: String]]) ?? []
            codeNav.ask(id: id, question: question, snippet: snippet, start: start,
                        end: (payload["end"] as? NSNumber)?.intValue ?? start, path: path,
                        language: FileType.codeLanguage(for: url), history: history, url: url,
                        root: root, db: semanticDatabase)
        case "askStop":
            if let id = payload["id"] as? String { codeNav.stopAnswer(id: id) }
        default:
            break
        }
    }

    // MARK: - Architecture

    /// Folder X-Rays by folder path (relative to the project root). The project's own
    /// X-Ray is `architecture` (scope "").
    private var folderXRays: [String: ArchitectureStore] = [:]

    /// The store behind an X-Ray tab.
    func xrayStore(for scope: String) -> ArchitectureStore {
        if scope.isEmpty || scope == TabKind.pullRequestScope { return architecture }
        if let store = folderXRays[scope] { return store }
        let store = ArchitectureStore()
        if let root = rootNode?.url {
            // Kept in the project's .dde, never inside the folder itself.
            let key = String(ContentHash.of(scope).prefix(24))
            let base = root.appendingPathComponent(".dde/xray-folders", isDirectory: true)
            store.persistenceFile = base.appendingPathComponent(key + ".json")
            store.cacheDirectory = root.appendingPathComponent(".dde/cache/xray", isDirectory: true)
        }
        folderXRays[scope] = store
        return store
    }

    /// Every X-Ray store that exists (the project's and the folders').
    private var allXRayStores: [ArchitectureStore] { [architecture] + folderXRays.values }

    /// Root folder and database of an X-Ray scope (folder X-Rays keep no database).
    private func xrayContext(_ scope: String) -> (root: URL, db: SemanticDatabase?)? {
        guard let root = rootNode?.url else { return nil }
        if scope.isEmpty || scope == TabKind.pullRequestScope { return (root, semanticDatabase) }
        return (root.appendingPathComponent(scope), nil)
    }

    /// Open (or switch to) the project's X-Ray. The first time the folder is scanned;
    /// later openings show the stored result.
    func openArchitecture() {
        openXRayTab(scope: "")
    }

    private func openXRayTab(scope: String) {
        guard let root = rootNode?.url, let context = xrayContext(scope) else { return }
        let isThisTab = { (tab: OpenTab) -> Bool in
            if case .architecture(let s) = tab.kind { return s == scope }
            return false
        }
        if let index = openTabs.firstIndex(where: isThisTab) {
            tabsStore.activeTabIndex = index
        } else {
            let marker = scope.isEmpty ? ".markview-architecture"
                : scope == TabKind.pullRequestScope ? ".markview-pr-xray"
                : ".markview-architecture-" + String(ContentHash.of(scope).prefix(12))
            var tab = OpenTab(url: root.appendingPathComponent(marker), content: "", originalContent: "")
            tab.kind = .architecture(scope: scope)
            tabsStore.appendTab(tab)
        }
        xrayStore(for: scope).open(root: context.root, db: context.db)
    }

    // MARK: - Moving and copying files

    /// Drag and drop in the tab bar: `id` goes before the tab at `index` (or last).
    func moveTab(_ id: UUID, to index: Int) {
        tabsStore.moveTab(id: id, to: index)
    }

    /// Move (or copy) files and folders into `folder`, as the file tree's drag and drop
    /// does (see `FileTransfer`). Tabs of moved files follow them. Returns the errors.
    @discardableResult
    func transfer(_ sources: [URL], into folder: URL, copy: Bool) -> [String] {
        let result = FileTransfer.perform(sources, into: folder, copy: copy)
        for (source, destination) in result.moved {
            for index in openTabs.indices {
                let path = openTabs[index].url.standardizedFileURL.path
                guard path == source.path || path.hasPrefix(source.path + "/") else { continue }
                let moved = URL(fileURLWithPath: destination.path + path.dropFirst(source.path.count))
                tabsStore.updateTab(at: index) { $0.url = moved }
            }
        }
        refreshFileTree()
        return result.errors
    }

    /// The PR X-Ray tab: the project's X-Ray seen through one change — what it touches,
    /// the links it adds or removes, and the AI's architectural reading of it.
    func openPRXRay(source: String?) {
        guard let root = rootNode?.url else { return }
        openXRayTab(scope: TabKind.pullRequestScope)
        if let source, !source.isEmpty {
            architecture.refreshPRSources(root: root)
            architecture.analyzeWhenLoaded = true
            architecture.showPR(source, root: root, db: semanticDatabase)
        } else {
            // Nothing chosen yet: everything on this branch vs main, uncommitted included.
            architecture.selectDefaultSource = true
            architecture.refreshPRSources(root: root)
        }
    }

    /// X-Ray from the file tree. A folder gets its own X-Ray tab — its own structure,
    /// found and named inside it as if it were the project. A file opens with Explain
    /// (its sections, importance, freshness and filters).
    func openXRay(for url: URL) {
        guard let root = rootNode?.url.standardizedFileURL else { return }
        let target = url.standardizedFileURL
        let isFolder = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isFolder else {
            explainFile(target)
            return
        }
        openXRayTab(scope: target.path == root.path ? "" : workspaceRelativePath(target))
    }

    /// Open a file with its Explain notes, starting an explanation if there is none yet.
    private func explainFile(_ url: URL) {
        openFile(url)
        if FileType.from(url: url) == .markdown { setNotesView(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.prepareCodeNotes(for: url)
            if self.codeExplain.explanations[self.workspaceRelativePath(url)] == nil {
                self.handleCodeAction("explain", payload: [:], url: url)
            }
        }
    }

    /// Requests from an X-Ray tab's web view, for the X-Ray of the active tab.
    func handleArchitectureAction(_ action: String, payload: [String: Any]) {
        var scope = ""
        if case .architecture(let s) = activeTab?.kind { scope = s }
        guard let (root, db) = xrayContext(scope) else { return }
        let architecture = xrayStore(for: scope)
        let semanticDatabase = db
        switch action {
        case "openFile":
            guard let path = payload["path"] as? String, !path.isEmpty else { return }
            let url = root.appendingPathComponent(path).standardizedFileURL
            // Stay inside the open folder.
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
            // From the PR X-Ray: the viewer opens on the change ("Pull request" lens), showing
            // a fetched pull request's own version of the file (which may not exist here).
            // From the ⚡ search's answer: the viewer opens on the search's places in the file.
            if payload["fromSearch"] as? Bool == true { architecture.markSearchFocus(path: path) }
            if payload["fromPR"] as? Bool == true {
                architecture.markPRFocus(path: path)
                if let prFile = architecture.prFileURL(path: path) {
                    openFile(prFile, line: payload["line"] as? Int, endLine: payload["endLine"] as? Int)
                    return
                }
            }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if FileType.isOpenable(url) {
                openFile(url, line: payload["line"] as? Int, endLine: payload["endLine"] as? Int)
                // Markdown: scroll to a heading or to where the document mentions something.
                if let text = payload["find"] as? String, !text.isEmpty, FileType.from(url: url) == .markdown {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        NotificationCenter.default.post(name: .scrollToText, object: String(text.prefix(80)))
                    }
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case "rescan":
            architecture.scan(root: root, db: semanticDatabase)
        case "analyze":
            architecture.analyze(root: root, db: semanticDatabase)
        case "cancelAnalysis":
            architecture.cancelAnalysis()
        case "tempFilter":
            setTemporaryFilter(payload["criterion"] as? String ?? "")
        case "openPRXRay":
            openPRXRay(source: payload["source"] as? String)
        case "openPRNumber":
            // "123", "#123" or a GitHub link ".../pull/123".
            let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let number = text.range(of: #"(\d+)\s*$|pull/(\d+)"#, options: .regularExpression)
                .map { String(text[$0]).filter(\.isNumber) } ?? ""
            if !number.isEmpty { openPRXRay(source: "gh:" + number) }
        case "analyzePR":
            architecture.analyzePR(root: root, db: semanticDatabase, fresh: payload["again"] as? Bool == true)
        case "prFileDiff":
            architecture.showFileDiff(path: payload["path"] as? String ?? "")
        case "explainPRFile":
            architecture.explainPRFile(path: payload["path"] as? String ?? "", root: root, db: semanticDatabase)
        case "askPR":
            let path = payload["path"] as? String
            architecture.askPR(question: payload["question"] as? String ?? "", path: path?.isEmpty == true ? nil : path,
                               root: root, db: semanticDatabase)
        case "filterSearch":
            architecture.searchFilter(filterId: payload["filter"] as? String ?? "", root: root, db: semanticDatabase)
        case "showPR":
            architecture.showPR(payload["source"] as? String ?? "", root: root)
        case "reviewPR":
            if payload["again"] as? Bool == true {
                architecture.reviewAgain(root: root, db: semanticDatabase)
            } else {
                architecture.reviewPR(root: root, db: semanticDatabase)
            }
        case "prTasksToTerminal":
            // Typed at the assistant's prompt, not sent: check the list and press Enter.
            if let text = architecture.prTasksText() { sendToAssistant(text, submit: false) }
        case "copyPRTasks":
            if let text = architecture.prTasksText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "refreshPRSources":
            architecture.refreshPRSources(root: root)
        case "prAction":
            // op: approve | requestChanges | comment | merge | close; method: merge | squash | rebase.
            let op = payload["op"] as? String ?? ""
            let method = payload["method"] as? String ?? "squash"
            guard ["approve", "requestChanges", "comment", "merge", "close"].contains(op),
                  GitHubClient.mergeMethods.contains(method) else { return }
            architecture.prAction(op, body: payload["body"] as? String ?? "", method: method, root: root)
        case "prFindingFix", "prFixAll":
            let prompt = action == "prFixAll"
                ? architecture.prTasksText()
                : architecture.findingFixPrompt(path: payload["path"] as? String ?? "", index: payload["index"] as? Int ?? -1)
            guard let prompt else { return }
            let number = architecture.shownPRNumber
            Task {
                if let error = await fixInPullRequest(number, prompt: prompt) {
                    let alert = NSAlert()
                    alert.messageText = "Cannot fix in the pull request"
                    alert.informativeText = error
                    alert.runModal()
                }
            }
        case "prFindingExplain":
            architecture.explainFinding(path: payload["path"] as? String ?? "", index: payload["index"] as? Int ?? -1, db: semanticDatabase)
        case "prFindingComment":
            architecture.commentFinding(path: payload["path"] as? String ?? "", index: payload["index"] as? Int ?? -1, root: root)
        case "prFindingIssue":
            architecture.issueFromFinding(path: payload["path"] as? String ?? "", index: payload["index"] as? Int ?? -1, root: root)
        case "prFindingDismiss":
            architecture.dismissFinding(path: payload["path"] as? String ?? "", index: payload["index"] as? Int ?? -1)
        case "openURL":
            // Only GitHub links, opened in the browser.
            if let text = payload["url"] as? String, let url = URL(string: text), url.scheme == "https",
               url.host == "github.com" {
                NSWorkspace.shared.open(url)
            }
        case "setComponent":
            architecture.setComponent(path: payload["path"] as? String ?? "", component: payload["component"] as? String ?? "",
                                      db: semanticDatabase)
        case "rateImportance":
            architecture.rateImportance(viewId: payload["view"] as? String ?? "modules",
                                        parentId: payload["parent"] as? String ?? "",
                                        filterId: payload["filter"] as? String ?? "importance",
                                        root: root, db: semanticDatabase)
        case "createFilter":
            createFilter(name: payload["name"] as? String ?? "", criterion: payload["criterion"] as? String ?? "")
        case "deleteFilter":
            deleteFilter(id: payload["id"] as? String ?? "")
        case "outlineFile":
            guard let path = payload["path"] as? String, !path.isEmpty else { return }
            architecture.outlineFile(path: path, root: root, db: semanticDatabase)
        case "saveSearchAnswer":
            if let file = architecture.saveSearchAnswer(filterId: payload["filter"] as? String ?? "", root: root,
                                                        author: features.defaultOwner) {
                refreshFileTree()
                openFile(file)
            }
        case "explainEdge":
            guard let source = payload["source"] as? String, let target = payload["target"] as? String else { return }
            architecture.explainEdge(view: payload["view"] as? String ?? "modules", source: source, target: target,
                                     kind: payload["kind"] as? String ?? "uses", label: payload["label"] as? String,
                                     root: root, db: semanticDatabase, fresh: payload["again"] as? Bool == true)
        case "describe":
            architecture.describe(viewId: payload["view"] as? String ?? "modules", nodeId: payload["id"] as? String ?? "",
                                  root: root, db: semanticDatabase)
        default:
            break
        }
    }

    /// Open `url` and, for code, reveal `line`…`endLine` in the code viewer.
    func openFile(_ url: URL, line: Int?, endLine: Int? = nil) {
        openFile(url)
        guard let line, line > 0 else { return }
        NotificationCenter.default.post(name: .revealCodeLine, object: nil, userInfo:
            ["url": url, "line": line, "endLine": endLine ?? line])
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
        Task {
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
                    if name == ".git" || name == ".dde" || name == "node_modules" { enumerator?.skipDescendants(); continue }
                    if name.lowercased() == wanted { matches.append(url.standardizedFileURL) }
                }
                return matches.min { a, b in
                    let aHere = a.deletingLastPathComponent().path == currentFolder
                    let bHere = b.deletingLastPathComponent().path == currentFolder
                    if aHere != bHere { return aHere }
                    return a.pathComponents.count < b.pathComponents.count
                }
            }.value
            guard let found else {
                NSSound.beep()
                return
            }
            openFile(found)
            if let heading, !heading.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NotificationCenter.default.post(name: .scrollToText, object: heading, userInfo: ["heading": true])
                }
            }
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

        if FileType.isOpenable(target) {
            openFile(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// Check if a file belongs to the currently open workspace
    private func isFileInCurrentWorkspace(_ url: URL) -> Bool {
        guard semanticDatabase != nil else { return false }
        guard let root = rootNode else { return false }
        // A pull request's copy of a project file (MarkView's cache, opened from the PR
        // X-Ray) belongs to the open project: it must not turn it into a single-file workspace.
        if architecture.prRelativePath(for: url) != nil { return true }
        let filePath = url.standardizedFileURL.path
        let rootPath = root.url.standardizedFileURL.path
        return filePath.hasPrefix(rootPath + "/")
    }

    /// Drop the database and every engine bound to the current workspace.
    private func releaseWorkspaceEngines() {
        semanticDatabase = nil
        incrementalCompiler = nil
        graphRAG = nil
        stopAllTerminals()
        aiWorkspaceRoot = nil
    }

    /// Close the open folder and every tab, returning the window to the welcome
    /// screen so another folder can be chosen. Returns false if the user cancelled
    /// or unsaved changes could not be written.
    @discardableResult
    func closeFolder() -> Bool {
        let unsaved = openTabs.indices.filter { openTabs[$0].isModified }
        if !unsaved.isEmpty {
            let alert = NSAlert()
            alert.messageText = unsaved.count == 1
                ? "Save changes to \(openTabs[unsaved[0]].displayName) before closing the folder?"
                : "Save changes to \(unsaved.count) documents before closing the folder?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                unsaved.forEach { saveFile(at: $0) }
                // saveFile only logs write errors — never close over unsaved work.
                if let failed = openTabs.first(where: { $0.isModified }) {
                    let error = NSAlert()
                    error.messageText = "Couldn't save \(failed.displayName)"
                    error.informativeText = "The folder was left open so no changes are lost."
                    error.runModal()
                    return false
                }
            case .alertSecondButtonReturn:
                break
            default:
                return false
            }
        }

        Self.debugLog("closeFolder: \(rootNode?.url.path ?? "(no folder)")")
        UserDefaults.standard.removeObject(forKey: Self.lastFolderKey)

        // Stop work that would otherwise keep writing into the old workspace.
        for tab in openTabs {
            if case .insight(let session) = tab.kind {
                Task { await session.cancel() }
            }
        }
        stopAllTerminals()
        structuralIndexer?.terminate()
        structuralIndexer = nil

        tabsStore.reset()
        fileTreeStore.reset()
        releaseWorkspaceEngines()
        architecture.reset()
        folderXRays = [:]
        codeNav.reset()
        isCodeProject = false
        gitClient.reset()
        gitHubRoot = nil
        gitHub.reset()
        features.reset()
        indexingProgress = nil
        structuralIndexProgress = nil
        analysisStage = nil
        analysisDetail = nil
        totalFilesInWorkspace = 0
        analyzedFiles = 0
        pendingGraphCreatorType = nil
        return true
    }

    /// Initialize workspace for a single .md file — DB named after the file, indexes only this file
    private func initSingleFileWorkspace(fileURL: URL) {
        let parentDir = fileURL.deletingLastPathComponent()
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let dbName = "file_\(fileName).db"

        NSLog("[DDE] initSingleFileWorkspace: file=\(fileURL.path) dir=\(parentDir.path) dbName=\(dbName)")

        releaseWorkspaceEngines()

        do {
            let db = try SemanticDatabase(workspacePath: parentDir, dbName: dbName)
            let projectId = fileName
            try db.ensureProject(id: projectId, name: fileName, rootPath: parentDir.path)
            self.semanticDatabase = db
            self.incrementalCompiler = IncrementalCompiler(workspacePath: parentDir, database: db)
            self.graphRAG = GraphRAG(db: db)
            self.aiWorkspaceRoot = parentDir
            gitClient.setup(at: parentDir)

            // Build file tree showing just the parent dir
            if rootNode == nil {
                fileTreeStore.setRootNode(FileNode.buildTree(from: parentDir, sortOrder: fileTreeStore.sortOrder))
                fileTreeStore.loadExcludedFolders()
            }

            // Index this single file: create root module, parse document, index FTS
            indexSingleFile(fileURL: fileURL, db: db)

            NSLog("[DDE] Single-file workspace initialized: \(fileName) → \(dbName)")
        } catch {
            NSLog("[DDE] Failed to init single-file workspace: \(error)")
        }
    }

    /// Index a single markdown file — structural parse + FTS + Haiku extraction.
    /// Works fully in sandbox: no directory scan, content passed directly.
    private func indexSingleFile(fileURL: URL, db: SemanticDatabase) {
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
        // A terminal tab: end its shell; there is nothing to save.
        if case .terminal(let id) = tab.kind {
            closeTerminal(id)
            tabsStore.removeTab(at: index)
            return
        }
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

    /// A file the file tree should show ("Reveal in File Tree"); the tree browses its
    /// folder, highlights it and clears the request.
    @Published var fileTreeRevealRequest: URL?

    /// Show the file tree at `url`'s folder with `url` highlighted.
    func revealInFileTree(url: URL) {
        showFileTree = true
        fileTreeRevealRequest = url.standardizedFileURL
    }

    /// Save the active tab's file.
    /// Insight tabs are ephemeral (Decision 10 §7 / Task 7): the placeholder URL
    /// `.insight-<uuid>` must NEVER be written to disk. Cmd+S on an insight tab
    /// is a no-op here — the insight player has its own Save flow that calls
    /// `didRequestInsightSave` (NSSavePanel + sanitized filename + node body only).
    func saveActiveFile() {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }
        if !openTabs[activeTabIndex].isFileBacked { return }
        saveFile(at: activeTabIndex)
    }

    /// Handle selection actions: translate or explain selected text via the selected AI CLI.
    /// Result is shown in a popup — see `translateDocument` for the whole-document
    /// path, which produces a translated copy in a new tab instead.
    func handleSelectionAction(action: String, text: String, completion: @escaping (String, String) -> Void) async {
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

        do {
            var request = CLICompletion.Request(prompt: text, systemPrompt: systemPrompt)
            request.timeout = 120
            let result = try await CLICompletion.run(request)
            result.record(in: semanticDatabase)
            completion(title, result.text)
        } catch {
            completion(title, "Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Document Translation

    /// Which backend performs the translation. Chosen once per document so the
    /// whole file is translated by a single engine (mixing engines mid-document
    /// produces visibly inconsistent terminology).
    private struct TranslationEngine {
        let tool: CLITool
        let model: String?

        var label: String { AIAssistantPreferences.summary(tool: tool, model: model ?? "") }
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

        // The assistant chosen in DDE Settings / the toolbar; fixed for the
        // whole document. A missing CLI is reported up front rather than as a
        // document full of untranslated sections.
        let tool = AIAssistantPreferences.backend
        let engine = TranslationEngine(tool: tool, model: AIAssistantPreferences.model(for: tool))
        guard CLIToolLocator.resolve(tool) != nil else {
            NSLog("[DDE] Translation aborted: \(tool.binaryName) not found")
            return "\(tool.displayName) was not found. Set its path in DDE Settings → AI CLI Tools."
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
        var lastError: String?
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
            var translated = await translateChunk(chunk.text, targetLang: targetLang, engine: engine,
                                                  strict: false, error: &lastError)

            // Structural check, then one stricter retry. This is what keeps
            // tables intact when a small local model reflows them.
            if let candidate = translated, skeleton(of: candidate) != expected {
                NSLog("[DDE] Translation chunk \(i + 1): structure mismatch, retrying strictly")
                translated = await translateChunk(chunk.text, targetLang: targetLang, engine: engine,
                                                  strict: true, error: &lastError)
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
            let reason = lastError.map { "(\($0))" }
                ?? "(the model's output did not preserve their structure)"
            result = "> ⚠️ Translation incomplete — section(s) \(list) kept in the original language "
                + "\(reason).\n\n" + result
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
        strict: Bool,
        error lastError: inout String?
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

        var request = CLICompletion.Request(prompt: text, systemPrompt: systemPrompt)
        request.tool = engine.tool
        request.model = engine.model
        request.timeout = 240
        do {
            let result = try await CLICompletion.run(request)
            result.record(in: semanticDatabase)
            return normalizeTranslation(result.text)
        } catch {
            lastError = error.localizedDescription
            NSLog("[DDE] Translation chunk error: \(error.localizedDescription)")
            return nil
        }
    }

    /// `<workspace>/.dde/cache` — the open folder when the document is in it, otherwise
    /// the document's own folder (same place single-file mode keeps `.dde`).
    func cacheDirectory(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let root: URL
        if let folder = rootNode?.url, path.hasPrefix(folder.standardizedFileURL.path + "/") {
            root = folder
        } else {
            root = url.deletingLastPathComponent()
        }
        return root.appendingPathComponent(".dde/cache", isDirectory: true)
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

        // 2. The selected assistant CLI must be installed, and the workspace engines
        //    (GraphRAG) initialised.
        let tool = AIAssistantPreferences.backend
        guard CLIToolLocator.resolve(tool) != nil else {
            let alert = NSAlert()
            alert.messageText = "\(tool.displayName) not found"
            alert.informativeText = "Set its path in DDE Settings → AI CLI Tools, or choose the other assistant."
            alert.runModal()
            return
        }
        guard graphRAG != nil else {
            let alert = NSAlert()
            alert.messageText = "Workspace not ready"
            alert.informativeText = "Wait for the folder to finish opening, then try again."
            alert.runModal()
            return
        }

        // 3. Enumerate .md files (any number).
        let mdFiles = scanMarkdownFiles(in: folderURL)

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
        if !tab.isFileBacked { return }
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

    /// Update the content of the active tab.
    /// Insight tabs own their content via `InsightSession`; the JS bridge must
    /// not write back into `tab.content` because (a) it would race with the SSE
    /// stream, and (b) `isModified` would flip true and prime an unwanted Cmd+S
    /// write to the placeholder URL.
    func updateActiveTabContent(_ content: String) {
        tabsStore.updateActiveTab { tab in
            if !tab.isFileBacked { return }
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
        if !openTabs[idx].isFileBacked { return nil }

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

    /// Folder a new diagram goes into (the file tree's "New Graph Diagram"); nil = project root.
    private(set) var graphCreatorFolder: URL?

    func presentGraphCreator(for type: String = "architecture", in folder: URL? = nil) {
        graphCreatorFolder = folder
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

        guard let prompt = aiPrompt(for: tool, contentOverride: contentOverride) else { return }
        sendToAssistant(prompt)
    }

    func runGraphEdit(instruction: String, currentMermaid: String) {
        let file = activeTab.map { workspaceRelativePath($0.url) } ?? "the currently open file"
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
        6. Update the file with the new diagram (replace the old mermaid block)

        Save the updated diagram to \(file).
        """

        sendToAssistant(editPrompt)
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
        if !openTabs[activeTabIndex].isFileBacked { return }

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
    /// This workspace's indexer, so closing the folder can stop it. Weak: the
    /// static list above owns it.
    private weak var structuralIndexer: Process?

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
                // A newer indexer (folder closed and reopened) owns the footer now.
                if let current = self.structuralIndexer, current !== p { return }
                self.structuralIndexProgress = nil  // hide footer progress
                self.loadCachedResults()
                self.refreshSemanticViews()
            }
        }

        do {
            structuralIndexProgress = "Indexing…"  // footer only; updated from child stderr
            try proc.run()
            Self.runningIndexers.append(proc)  // retain until terminationHandler fires
            structuralIndexer = proc
            Self.debugLog("structural index process launched pid=\(proc.processIdentifier)")
        } catch {
            structuralIndexProgress = nil
            Self.debugLog("structural index process FAILED to launch: \(error)")
        }
    }

    func refreshSemanticViews() {
        semanticRefreshVersion &+= 1
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

    /// Refresh views that read the semantic database on demand.
    private func loadCachedResults() {
        // Don't load thousands of records into @Published arrays.
        NSLog("[DDE] DB ready for lazy loading")
        refreshSemanticViews()
    }

    /// Cursor moved to a different block
    func handleCursorBlockChange(_ blockId: String) {
        tabsStore.updateActiveTab { tab in
            tab.activeBlockId = blockId
        }
    }

    /// Show the right panel on its Terminal tab (the AI terminals).
    func showAIConsole() {
        showTOC = true
        UserDefaults.standard.set(TOCView.Tab.terminal.rawValue, forKey: TOCView.Tab.storageKey)
    }

    // MARK: - Terminals

    /// The terminal shown in the AI panel.
    var aiTerminal: TerminalSession? {
        aiTerminals.first { $0.id == activeAITerminalID } ?? aiTerminals.first
    }

    /// The command that starts `profile` in the shell with the model chosen for it, or nil
    /// for a plain shell. Claude updates itself first and runs without permission prompts.
    private func startupCommand(for profile: TerminalProfile) -> String? {
        guard let tool = profile.tool else { return nil }
        let path = CLIToolLocator.resolve(tool) ?? tool.binaryName
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let run = ([quoted] + tool.modelArgs(AIAssistantPreferences.model(for: tool))).joined(separator: " ")
        switch tool {
        case .claude: return "\(quoted) update && \(run) --dangerously-skip-permissions"
        case .codex, .cline, .copilot: return run
        }
    }

    /// "Claude Code · opus", "Codex 2 · gpt-5", "Shell" — unique among the open terminals.
    private func terminalTitle(for profile: TerminalProfile, excluding session: TerminalSession? = nil) -> String {
        let taken = Set(aiTerminals.filter { $0 !== session }.map(\.title))
        var base = profile.title
        var counter = 2
        while taken.contains(where: { $0 == base || $0.hasPrefix(base + " · ") }) {
            base = "\(profile.title) \(counter)"
            counter += 1
        }
        guard let tool = profile.tool, let model = AIAssistantPreferences.model(for: tool), !model.isEmpty else { return base }
        return base + " · " + model
    }

    /// Open another terminal in the AI panel and show it.
    @discardableResult
    func openAITerminal(_ profile: TerminalProfile) -> TerminalSession? {
        guard let directory = aiWorkspaceRoot ?? rootNode?.url else { return nil }
        let session = TerminalSession(directory: directory, profile: profile,
                                      startupCommand: startupCommand(for: profile),
                                      title: terminalTitle(for: profile))
        aiTerminals.append(session)
        activeAITerminalID = session.id
        startWatchingOpenFiles()
        return session
    }

    /// The first AI terminal (the toolbar's assistant) once a folder is open.
    @discardableResult
    func ensureAITerminal() -> TerminalSession? {
        if let session = aiTerminal { return session }
        return openAITerminal(TerminalProfile(AIAssistantPreferences.backend))
    }

    func closeAITerminal(_ id: UUID) {
        guard let index = aiTerminals.firstIndex(where: { $0.id == id }) else { return }
        aiTerminals.remove(at: index).terminate()
        if activeAITerminalID == id {
            activeAITerminalID = aiTerminals.isEmpty ? nil : aiTerminals[min(index, aiTerminals.count - 1)].id
        }
    }

    /// Start the shown terminal again, with the model chosen for its assistant now.
    func restartAITerminal() {
        guard let session = aiTerminal else { ensureAITerminal(); return }
        session.restart(profile: session.profile, startupCommand: startupCommand(for: session.profile),
                        title: terminalTitle(for: session.profile, excluding: session))
    }

    /// The toolbar's assistant changed: show a terminal running it — an open one, or the
    /// shown assistant terminal restarted with it, or a new one next to a plain shell.
    func aiBackendChanged() {
        let profile = TerminalProfile(AIAssistantPreferences.backend)
        if let existing = aiTerminals.first(where: { $0.profile == profile }) {
            activeAITerminalID = existing.id
            return
        }
        if let session = aiTerminal, session.profile != .shell {
            session.restart(profile: profile, startupCommand: startupCommand(for: profile),
                            title: terminalTitle(for: profile, excluding: session))
            objectWillChange.send()
        } else if aiTerminal != nil {
            openAITerminal(profile)
        }
    }

    /// A model changed in the toolbar: the shown terminal restarts when it runs that
    /// assistant with another model; other terminals keep their session.
    func aiModelChanged() {
        guard let session = aiTerminal, session.profile != .shell else { return }
        let command = startupCommand(for: session.profile)
        guard session.startupCommand != command else { return }
        session.restart(profile: session.profile, startupCommand: command,
                        title: terminalTitle(for: session.profile, excluding: session))
        objectWillChange.send()
    }

    /// Send a prompt to an assistant (prompt buttons, AI Tools menu, graph edits,
    /// documentation): the shown terminal when it runs one, else an open assistant
    /// terminal, else a new one with the toolbar's assistant. Pasted as one block;
    /// `submit` presses Enter.
    func sendToAssistant(_ prompt: String, submit: Bool = true) {
        showAIConsole()
        let session: TerminalSession?
        if let shown = aiTerminal, shown.profile != .shell {
            session = shown
        } else if let open = aiTerminals.first(where: { $0.profile == TerminalProfile(AIAssistantPreferences.backend) })
                    ?? aiTerminals.first(where: { $0.profile != .shell }) {
            session = open
        } else {
            session = openAITerminal(TerminalProfile(AIAssistantPreferences.backend))
        }
        guard let session else { return }
        activeAITerminalID = session.id
        session.pasteWhenReady(prompt, submit: submit)
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

    /// The "New" intake sheet shown (New Feature / New Bug / I Need to Understand).
    @Published var intake: IntakeRequest?

    /// "New Feature / New Bug from #n": the issue's text and comments as the material, linked.
    func startIntake(_ kind: IntakeKind, fromIssue number: Int) {
        guard let client = gitHub.client else { return }
        Task {
            do {
                let issue = try await client.issue(number)
                var text = "GitHub issue #\(number): \(issue.title)\n\n\(issue.body ?? "")"
                let comments = issue.comments ?? []
                if !comments.isEmpty {
                    text += "\n\nComments:\n\n" + comments.map { "\($0.author?.login ?? "someone"): \($0.body)" }.joined(separator: "\n\n")
                }
                intake = IntakeRequest(kind: kind, text: text, linkedIssue: number)
            } catch {
                gitHub.lastError = "Could not read #\(number): \(error.localizedDescription)"
            }
        }
    }

    /// "New … from this pull request": its description as the material (a new issue is filed).
    func startIntake(_ kind: IntakeKind, fromPullRequest pr: GHPullRequest) {
        guard let client = gitHub.client else { return }
        Task {
            let body = (try? await client.gh(["pr", "view", String(pr.number), "-R", client.repo.slug, "--json", "body", "-q", ".body"])) ?? ""
            intake = IntakeRequest(kind: kind, text: "Pull request #\(pr.number): \(pr.title) (\(pr.headRefName) → \(pr.baseRefName))\n\n\(body)")
        }
    }

    /// "I need to understand …": the X-Ray's ⚡ search for the question — what takes part is
    /// marked in every view, the answer and its places are on the right, and a file opened from
    /// there shows the places inside it.
    func understandInXRay(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rootNode != nil, !text.isEmpty else { return }
        setTemporaryFilter(String(text.prefix(300)))
        openArchitecture()
        if let id = ImportanceRater.temporaryFilter?.id { architecture.activate(filterId: id) }
    }

    /// "New … from this document": the document is the material (attached, so the AI reads it whole).
    func startIntake(_ kind: IntakeKind, fromDocument url: URL) {
        let path = workspaceRelativePath(url)
        let lead: String
        switch kind {
        case .feature: lead = "Build a feature from the document \(path) (attached)."
        case .bug: lead = "The document \(path) (attached) describes a problem to analyze as a bug."
        case .understand: lead = "What implements \(path) in this project, and how do the documented parts work in the code?"
        }
        intake = IntakeRequest(kind: kind, text: lead, attachments: kind == .understand ? [] : [url])
    }

    /// Hand a document to the AI to implement (the assistant in the Terminal tab): Claude Code gets
    /// it as a `/goal`, the others as a plain instruction.
    func implementWithAI(_ url: URL) {
        let path = workspaceRelativePath(url)
        let instruction = "implement \(path) — ask any question if you are in doubt"
        let prompt = AIAssistantPreferences.backend == .claude ? "/goal \(instruction)"
            : "Implement what \(path) specifies. Read it first; ask any question if you are in doubt before changing code."
        sendToAssistant(prompt, submit: true)
    }

    /// An intake finished: open what it made, and for a feature show its workspace.
    func intakeFinished(_ kind: IntakeKind, outcome: FeatureAssistant.IntakeOutcome) {
        if let slug = outcome.feature {
            features.activeSlug = slug
            UserDefaults.standard.set("issues", forKey: "layout.leftPanel")
            UserDefaults.standard.set(slug, forKey: "layout.issuesFeature")
            UserDefaults.standard.set(FeatureStage.explore.rawValue, forKey: FeatureStage.storageKey)
            showTOC = true
            showFileTree = true
            UserDefaults.standard.set(TOCView.Tab.feature.rawValue, forKey: TOCView.Tab.storageKey)
        }
        refreshFileTree()
        if let file = outcome.file { openFile(file) }
    }

    /// A contextual action on text selected in the editor: the answer (or the created
    /// requirement / decision / question) appears in the right panel's Feature tab.
    func runFeatureAction(_ name: String, text: String, question: String) {
        guard let action = FeatureAction(rawValue: name) else { return }
        guard rootNode != nil else { return }
        let url = activeTab?.url
        let located = url.flatMap { features.locate($0) }
        let slug = located?.feature.slug ?? features.active?.slug
        let document = url.map { features.relativePath($0) }
        showTOC = true
        UserDefaults.standard.set(TOCView.Tab.feature.rawValue, forKey: TOCView.Tab.storageKey)
        Task { await features.assistant.perform(action, selection: text, document: document, question: question, feature: slug) }
    }

    /// Feature workspaces of a folder, with the AI's access to the index and GitHub.
    private func setUpFeatures(at root: URL) {
        features.setup(root: root)
        features.assistant.database = { [weak self] in self?.semanticDatabase }
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
        gitHub.onRepoChange = { [weak self] repo in self?.architecture.gitHubRepo = repo }
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
        let url = root.appendingPathComponent(item.marker)
        if tabsStore.selectTab(matching: url) != nil { return }
        var tab = OpenTab(url: url, content: "", originalContent: "")
        tab.kind = .github(item)
        tabsStore.appendTab(tab)
    }

    /// "Review" on a pull request: its PR X-Ray, with the AI review started once it loads
    /// (unless turned off in Settings).
    func reviewPullRequest(_ number: Int) {
        architecture.reviewWhenLoaded = GitHubSettings.autoReview
        openPRXRay(source: "gh:\(number)")
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
        sendToAssistant(prompt, submit: true)
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
        sendToAssistant(prompt, submit: true)
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
            sendToAssistant(prompt, submit: true)
        }
    }

    /// Open a terminal in `folder` as an editor tab.
    func openTerminal(in folder: URL) {
        let session = TerminalSession(directory: folder.standardizedFileURL)
        var tab = OpenTab(url: folder.appendingPathComponent(".markview-terminal-" + session.id.uuidString),
                          content: "", originalContent: "")
        tab.kind = .terminal(session.id)
        terminalTabs[session.id] = session
        tabsStore.appendTab(tab)
        startWatchingOpenFiles()
    }

    func terminalSession(_ id: UUID) -> TerminalSession? { terminalTabs[id] }

    /// A terminal tab was closed: end its shell.
    func closeTerminal(_ id: UUID) {
        terminalTabs.removeValue(forKey: id)?.terminate()
    }

    private func stopAllTerminals() {
        aiTerminals.forEach { $0.terminate() }
        aiTerminals = []
        activeAITerminalID = nil
        terminalTabs.values.forEach { $0.terminate() }
        terminalTabs = [:]
        openFilesWatcher?.invalidate()
        openFilesWatcher = nil
    }

    /// While terminals run, reload open files an assistant (or a command) changed on disk —
    /// only tabs without unsaved edits, so nothing typed here is lost.
    private func startWatchingOpenFiles() {
        guard openFilesWatcher == nil else { return }
        openFilesWatcher = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadChangedOpenFiles() }
        }
    }

    private func reloadChangedOpenFiles() {
        var changed = false
        for index in openTabs.indices where openTabs[index].isFileBacked && !openTabs[index].isModified {
            let url = openTabs[index].url
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            defer { openFileDates[url] = date }
            guard let seen = openFileDates[url], date > seen,
                  let content = try? String(contentsOf: url, encoding: .utf8), content != openTabs[index].originalContent else { continue }
            tabsStore.updateTab(at: index) { tab in
                tab.content = content
                tab.originalContent = content
                tab.isModified = false
            }
            changed = true
        }
        if changed { refreshFileTree() }
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
            return AIPrompts.codebaseAuditPrompt

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
            Create a file "review-\((context.fileName as NSString).deletingPathExtension).md" with: Summary, Strengths, Issues (with severity/location/fix), Missing Content, Consistency Issues, Action Items (P1/P2/P3), Overall Score 1-10.
            Also create "tasks/review-tasks-\((context.fileName as NSString).deletingPathExtension).md" with action items as checkboxes.
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
