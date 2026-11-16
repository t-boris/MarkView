import AppKit
import Combine
import Foundation
import os
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The open project of one window: its folder and file tree, the folders linked to it and left out of it, its search database,
/// the background index and the folders and files recently opened. The window's `WorkspaceManager` holds one and wires it to the
/// other features; nothing here knows the manager.
@MainActor
final class ProjectContext: ObservableObject, ProjectProviding {
    /// The folder tree, the exclusions and the file watcher.
    let fileTree: WorkspaceFileTreeStore
    /// False while the root is only a single file's folder (feature-2, DEC-012).
    @Published private(set) var rootOpenedAsFolder = false
    /// Folders attached to the open project as aliases: browsed, searched, indexed and readable by the AI together with it;
    /// the project's own elements stay in the project folder (Task 59).
    @Published private(set) var linkedFolders: [LinkedFolder] = []
    @Published private(set) var database: SemanticDatabase?
    @Published private(set) var recentFiles: [URL] = []
    /// Recently opened folders (standardized paths), most recent first.
    @Published private(set) var recentProjects: [String]
    /// What the folder is doing while it opens; drives the file-tree spinner, the auto-refresh gate and the module panel.
    @Published var indexingProgress: String? {
        didSet { fileTree.autoRefreshPaused = indexingProgress != nil }
    }
    /// Progress of the out-of-process structural index, shown ONLY in the footer. Separate from `indexingProgress` so that
    /// background indexing never blocks the tree, the module explorer or opening another folder.
    @Published private(set) var structuralIndexProgress: String?
    /// Bumped when the database changed under the views that read it on demand.
    @Published private(set) var semanticRefreshVersion = 0

    /// Folder reopened on the next launch; cleared by Close Folder.
    /// How many recently opened folders are remembered and listed on the welcome screen.
    static let maxRecentProjects = 30
    static let maxRecentFiles = 20

    private let recentFilesURL: URL
    /// The project's own background work (`AR-19`): cancelled when the folder closes or the window does.
    private let tasks = TaskBag()
    /// The single-file workspace being opened: while its database is still being created, another Markdown file from the same
    /// folder joins it instead of starting a second one.
    private var singleFileSetup: Task<Void, Never>?
    /// This project's indexer, so a newer one (folder closed and reopened) can tell its own exit from an older one's. Weak: a
    /// started `SubprocessChild` keeps itself alive until it has exited, so its exit handler always runs.
    private weak var structuralIndexer: SubprocessChild?
    private var treeChanges: AnyCancellable?


    /// `recentFilesURL` is where the recently opened files are kept; the window uses the shared file in Application Support.
    init(recentFilesURL: URL? = nil) {
        self.recentFilesURL = recentFilesURL ?? Self.defaultRecentFilesURL
        let fileTree = WorkspaceFileTreeStore()
        self.fileTree = fileTree
        recentProjects = Settings.standard.value(Setting.recentProjects)
        treeChanges = fileTree.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        loadRecentFiles()
    }

    /// `~/Library/Application Support/MarkView/recentFiles.json`.
    nonisolated static var defaultRecentFilesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("MarkView", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("recentFiles.json")
    }

    // MARK: - ProjectProviding

    var rootNode: FileNode? { fileTree.rootNode }
    var root: URL? { fileTree.rootNode?.url }
    /// The open project folder, the one that gets a project color; nil for a single file's folder.
    var projectFolder: URL? { rootOpenedAsFolder ? root : nil }
    var aiProject: URL? { projectFolder }
    var linkedFolderURLs: [URL] { linkedFolders.map(\.url) }
    var searchRoots: [URL] { (root.map { [$0] } ?? []) + linkedFolderURLs }

    /// Changes whenever the searchable roots change (the project or its linked folders).
    var searchRootsKey: String { ([root?.path ?? ""] + linkedFolders.map(\.path)).joined(separator: "\n") }

    func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let root = root?.standardizedFileURL.path, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        if linkedFolder(containing: url) != nil, let root {
            return LinkedFolders.documentId(for: url, root: root, linked: linkedFolders)
        }
        return path
    }

    func refreshFileTree() { fileTree.refresh() }

    func cacheDirectory(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let base: URL
        if let folder = root, path.hasPrefix(folder.standardizedFileURL.path + "/") {
            base = folder
        } else {
            base = url.deletingLastPathComponent()
        }
        return ProjectPaths.cacheFolder(base)
    }

    /// Canonical document id for `url` in the project: its path relative to the root (the parent folder for a single-file workspace).
    /// Must be used by EVERY docId producer so same-named files in different folders never collide.
    func documentId(for url: URL) -> String {
        LinkedFolders.documentId(for: url, root: root ?? url.deletingLastPathComponent(), linked: linkedFolders)
    }

    /// The file a document id of this project names: a path inside the project, or `@linked/<name>/…` inside a linked folder
    /// (Task 59); nil when it is neither on disk.
    func fileURL(forDocumentId id: String) -> URL? {
        if let linked = LinkedFolders.resolve(documentId: id, in: linkedFolders) {
            return FileManager.default.fileExists(atPath: linked.path) ? linked : nil
        }
        guard let root else { return nil }
        let direct = root.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    /// The file a search hit names: `filePath` as it is or relative to the root, else the file the document id names, else the first file
    /// in the folder with that name.
    func fileURL(filePath: String?, fallbackDocumentId: String?) -> URL? {
        let fm = FileManager.default

        if let filePath, !filePath.isEmpty {
            let directURL = URL(fileURLWithPath: filePath)
            if fm.fileExists(atPath: directURL.path) {
                return directURL
            }

            if let rootURL = root {
                let relativeURL = rootURL.appendingPathComponent(filePath)
                if fm.fileExists(atPath: relativeURL.path) {
                    return relativeURL
                }
            }
        }

        guard let rootURL = root,
              let fallbackDocumentId,
              !fallbackDocumentId.isEmpty else { return nil }

        if let resolved = fileURL(forDocumentId: fallbackDocumentId) { return resolved }

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

    /// Whether a folder is open and a database, or the setup of a single file's database, holds its documents.
    var hasWorkspace: Bool { root != nil && (database != nil || singleFileSetup != nil) }

    /// Whether `url` belongs to the open project: inside its folder or in one of its linked folders. False while there is no
    /// database (or single-file setup) to hold it.
    func contains(_ url: URL) -> Bool {
        guard hasWorkspace, let root else { return false }
        let filePath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") { return true }
        return linkedFolder(containing: url) != nil
    }

    // MARK: - Opening and closing

    /// A folder is chosen: it is remembered as the last folder and in the recents, and the previous tree is cleared so that the
    /// progress spinner shows.
    func beginOpening(_ url: URL) {
        Settings.standard.set(url.standardizedFileURL.path, for: Setting.lastFolder)
        var recent = recentProjects
        recent.removeAll { $0 == url.standardizedFileURL.path }
        recent.insert(url.standardizedFileURL.path, at: 0)
        setRecentProjects(Array(recent.prefix(Self.maxRecentProjects)))
        rootOpenedAsFolder = true
        // A folder opened now replaces what a single file's setup was about to publish.
        singleFileSetup?.cancel()
        singleFileSetup = nil
        tasks.cancelAll()
        fileTree.reset()
        indexingProgress = "Loading folder structure..."
    }

    /// Builds the tree of `url` off the main thread, then reads the folder's exclusions and links. False when the window moved
    /// on to another folder meanwhile (the task was cancelled).
    func loadTree(of url: URL) async -> Bool {
        let sort = fileTree.sortOrder
        let tree = await Task.detached { FileTree.build(from: url, sortOrder: sort) }.value
        guard !Task.isCancelled else { return false }
        let node = FileNode(tree)
        fileTree.setRootNode(node)
        fileTree.loadExcludedFolders()
        loadLinkedFolders()
        AppLog.workspace.debug("Tree loaded: \(node.children?.count ?? 0) children")
        return true
    }

    /// The tree follows the folder on disk from now on, and the folder counts as opened.
    func startWatching(_ url: URL) {
        fileTree.startWatchingCurrentRoot()
        addRecentFile(url)
    }

    /// Creates `.dde/` and opens the project's database. False when the window moved on to another folder while it was opened.
    func openDatabase(at url: URL) async throws -> Bool {
        let fm = FileManager.default
        let ddeRoot = ProjectPaths.localFolder(url)

        indexingProgress = "Creating workspace structure..."
        try? await Task.sleep(nanoseconds: 100_000_000)
        for subdir in ["cache/provider_responses", "cache/embeddings", "cache/indexes", "overlays"] {
            try? fm.createDirectory(at: ddeRoot.appendingPathComponent(subdir), withIntermediateDirectories: true)
        }

        indexingProgress = "Opening database..."
        try? await Task.sleep(nanoseconds: 100_000_000)
        let db = try await SemanticDatabase.open(workspacePath: url)
        try await db.ensureProject(id: url.lastPathComponent, name: url.lastPathComponent, rootPath: url.path)
        // Another folder was opened while the file was being opened: this database is not for this window any more.
        guard !Task.isCancelled else { return false }
        database = db
        return true
    }

    /// A single Markdown file is opened without a project: its folder is the root, and a database named after the file indexes it.
    func openSingleFile(_ fileURL: URL) {
        let parentDir = fileURL.deletingLastPathComponent()
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let dbName = "file_\(fileName).db"

        // Build file tree showing just the parent dir
        if root == nil {
            rootOpenedAsFolder = false
            fileTree.setRootNode(FileNode.buildTree(from: parentDir, sortOrder: fileTree.sortOrder))
            fileTree.loadExcludedFolders()
        }

        // The database is opened and filled off the main thread; the project gets it when it is ready.
        singleFileSetup = Task {
            do {
                let db = try await SemanticDatabase.open(workspacePath: parentDir, dbName: dbName)
                try await db.ensureProject(id: fileName, name: fileName, rootPath: parentDir.path)
                // Closed, or another file's workspace took over, while the database was being opened.
                guard !Task.isCancelled else { return }
                database = db
                singleFileSetup = nil
                // Index this single file: create root module, parse document, index FTS
                await Self.indexSingleFile(fileURL: fileURL, db: db)
                AppLog.workspace.debug("Single-file workspace initialized: \(fileName) → \(dbName)")
            } catch {
                singleFileSetup = nil
                AppLog.workspace.error("Failed to init single-file workspace: \(String(describing: error))")
            }
        }
    }

    /// The database goes, and with it a single-file setup that was about to publish one.
    func releaseDatabase() {
        singleFileSetup?.cancel()
        singleFileSetup = nil
        database = nil
    }

    /// The folder closes: the index process, the tree, the links and the database go. The recents stay.
    func closeFolder() {
        stopIndexing()
        tasks.cancelAll()
        fileTree.reset()
        linkedFolders = []
        releaseDatabase()
    }

    /// The window closes: every background job of the project stops, the index process included.
    func close() {
        stopIndexing()
        tasks.cancelAll()
        singleFileSetup?.cancel()
        singleFileSetup = nil
        fileTree.stopWatching()
    }

    // MARK: - Linked folders (Task 59)

    func loadLinkedFolders() {
        linkedFolders = LinkedFolders.load(project: projectFolder).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Link `urls` to the open project. Returns the reasons for the ones that could not be linked.
    @discardableResult
    func linkFolders(_ urls: [URL]) -> [String] {
        guard let project = projectFolder else { return ["Open a project folder first."] }
        var errors: [String] = []
        var added = false
        for url in urls {
            switch LinkedFolders.link(url, to: project, existing: linkedFolders) {
            case .success(let folder):
                linkedFolders.append(folder)
                added = true
            case .failure(let error):
                errors.append(error.message)
            }
        }
        if added { linkedFoldersChanged(project) }
        return errors
    }

    func unlinkFolder(_ id: String) {
        guard let project = projectFolder, linkedFolders.contains(where: { $0.id == id }) else { return }
        linkedFolders.removeAll { $0.id == id }
        linkedFoldersChanged(project)
    }

    /// The folder panel of "Link Folder…" (File menu, file tree).
    func chooseFoldersToLink() {
        guard projectFolder != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to link to this project. They are browsed and searched with it; the project's own files stay where they are."
        panel.prompt = "Link"
        guard panel.runModal() == .OK else { return }
        let errors = linkFolders(panel.urls)
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = errors.count == 1 ? "The folder was not linked." : "Some folders were not linked."
            alert.informativeText = errors.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// The linked folder that contains `url`, if any.
    func linkedFolder(containing url: URL) -> LinkedFolder? {
        LinkedFolders.folder(containing: url, in: linkedFolders)
    }

    /// The root `url` belongs to: the project folder, or the linked folder containing it.
    func containerRoot(for url: URL) -> URL? {
        if let root {
            let path = url.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath + "/") { return root }
        }
        return linkedFolder(containing: url)?.url
    }

    /// Persist the list, then index the linked folders (the search index follows `searchRootsKey`).
    private func linkedFoldersChanged(_ project: URL) {
        LinkedFolders.save(linkedFolders, project: project)
        if let root, database != nil { runStructuralIndex(at: root) }
    }

    // MARK: - Folder exclusion

    /// Exclude a folder: it leaves the tree's searchable set and all its entities leave the database.
    func excludeFolder(_ folderURL: URL) {
        guard let relativePath = fileTree.excludeFolder(folderURL) else { return }

        // Remove all DB entities for files in this folder: the folder walk and the writes run off the main thread.
        guard let db = database else { return }
        let root = self.root
        let linked = linkedFolders
        let forget = Task.detached {
            var ids: [String] = []
            if let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "md" else { continue }
                    ids.append(LinkedFolders.documentId(for: url, root: root ?? url.deletingLastPathComponent(), linked: linked))
                }
            }
            guard !Task.isCancelled else { return }
            await db.forgetDocuments(ids)
        }
        tasks.store(forget, for: "forget:" + relativePath)
        objectWillChange.send()
        AppLog.workspace.debug("Excluded folder: \(relativePath)")
    }

    /// Re-include a previously excluded folder.
    func includeFolder(_ relativePath: String) {
        guard fileTree.includeFolder(relativePath) else { return }
        // Re-index would happen on next Refresh
        objectWillChange.send()
        AppLog.workspace.debug("Re-included folder: \(relativePath)")
    }

    func isExcluded(_ url: URL) -> Bool {
        fileTree.isExcluded(url)
    }

    // MARK: - Markdown file scanning (Recursive Insight)

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
    nonisolated func markdownFiles(in folderURL: URL) -> [URL] {
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
            guard !url.path.contains(ProjectPaths.localFolderName) else { continue }

            let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
            // The `==` clause covers the (unlikely) case of the folder URL itself
            // surfacing here; the prefix clause requires a path-separator boundary
            // so a sibling like `/x/foobar/secret.md` cannot pass for `/x/foo`.
            guard resolvedFile == resolvedFolderPath || resolvedFile.hasPrefix(resolvedFolderPrefix) else {
                AppLog.workspace.debug("Skipped symlink escape: \(url.path)")
                continue
            }

            results.append(url)
        }
        return results
    }

    /// Whether the open folder holds a Markdown file, for the menu's disabled state (`AR-42`): the store's flag, found by a
    /// background walk, so reading it never touches the disk.
    var hasMarkdownFiles: Bool { fileTree.hasMarkdownFiles }

    // MARK: - Workspace metadata

    /// Everything MarkView has written into the open folder: the index database and caches (`.dde/`), Recursive Insight pages
    /// and a CLAUDE.md it generated.
    func metadataItems() -> [URL] {
        guard let root else { return [] }
        let fm = FileManager.default
        var items = [ProjectPaths.localFolder(root), ProjectPaths.insightFolder(root)]
            .filter { fm.fileExists(atPath: $0.path) }
        let claude = root.appendingPathComponent(".claude/CLAUDE.md")
        if let text = try? String(contentsOf: claude, encoding: .utf8),
           text.hasPrefix("# Project Context — Auto-generated by MarkView DDE") {
            items.append(claude)
        }
        return items
    }

    /// Deletes `items` from the folder and the `.claude` folder when that leaves it empty. Returns the names that could not be deleted.
    func deleteMetadata(_ items: [URL]) -> [String] {
        guard let root else { return [] }
        var failures: [String] = []
        for item in items {
            do { try FileManager.default.removeItem(at: item) } catch { failures.append(item.lastPathComponent) }
        }
        let claudeDir = root.appendingPathComponent(".claude")
        if (try? FileManager.default.contentsOfDirectory(atPath: claudeDir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: claudeDir)
        }
        return failures
    }

    // MARK: - Recent files and folders

    /// Removes a folder from the recent projects list; the folder itself is untouched.
    func removeRecentProject(_ path: String) {
        setRecentProjects(recentProjects.filter { $0 != path })
    }

    private func setRecentProjects(_ paths: [String]) {
        recentProjects = paths
        Settings.standard.set(paths, for: Setting.recentProjects)
    }

    func addRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > Self.maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(Self.maxRecentFiles))
        }
        saveRecentFiles()
    }

    private static let recentFilesStore = SchemaVersionedStore<[String]>()

    private func loadRecentFiles() {
        let result = Self.recentFilesStore.load(from: recentFilesURL)
        result.logProblem("RecentFiles")
        guard let paths = result.value else { return }
        recentFiles = paths.compactMap { URL(fileURLWithPath: $0) }
    }

    private func saveRecentFiles() {
        do { try Self.recentFilesStore.save(recentFiles.map { $0.path }, to: recentFilesURL) }
        catch { AppLog.workspace.error("Could not save the recent files: \(error.localizedDescription)") }
    }

    // MARK: - Background folder analysis

    /// Deterministic structural indexing — instant, no LLM — in a SEPARATE PROCESS (re-exec of this binary with
    /// `--dde-index <folder>`) so the directory scan never competes with the UI. The child writes modules/documents/symbols/FTS
    /// straight to the shared SQLite DB (WAL + busy_timeout); on exit the views that read the database are told to refresh.
    func runStructuralIndex(at url: URL) {
        guard let exePath = Bundle.main.executablePath else {
            AppLog.index.debug("runStructuralIndex: no executablePath")
            return
        }

        structuralIndexProgress = "Indexing…"  // footer only; updated from child stderr
        // Stream the child's stderr live so its progress shows in the footer (the runner drains the pipe, so the
        // child never blocks on a full buffer).
        let spec = SubprocessSpec(executable: exePath, arguments: ["--dde-index", url.path], timeout: 0, stdoutRouting: .discard)
        do {
            let child = try Subprocess.start(spec, onStderr: { [weak self] data in
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                for raw in chunk.split(separator: "\n") {
                    let line = String(raw)
                    guard let r = line.range(of: "[mvindexer] ") else { continue }
                    let msg = String(line[r.upperBound...])
                    // The child emits bare "N/M" progress ticks; show them as a count.
                    guard msg.range(of: #"^\d+/\d+$"#, options: .regularExpression) != nil else { continue }
                    Task { @MainActor in self?.structuralIndexProgress = "Indexing \(msg) files" }
                }
            }, onExit: { [weak self] finished, exit in
                AppLog.index.debug("structural index process exited code=\(exit.status)")
                Task { @MainActor in
                    guard let self = self else { return }
                    // A newer indexer (folder closed and reopened) owns the footer now.
                    if let current = self.structuralIndexer, current !== finished { return }
                    self.structuralIndexProgress = nil  // hide footer progress
                    self.refreshSemanticViews()
                }
            })
            structuralIndexer = child
            AppLog.index.debug("structural index process launched pid=\(child.pid)")
        } catch {
            structuralIndexProgress = nil
            AppLog.index.error("structural index process FAILED to launch: \(String(describing: error))")
        }
    }

    /// Ends the index process and clears the progress of the folder and of the index.
    func stopIndexing() {
        structuralIndexer?.terminate()
        structuralIndexer = nil
        indexingProgress = nil
        structuralIndexProgress = nil
    }

    /// Tell the views that read the database on demand to read it again.
    func refreshSemanticViews() {
        semanticRefreshVersion &+= 1
    }

    // MARK: - Single-file index

    /// Index a single markdown file — structural parse + FTS. Works fully in sandbox: no directory scan, content passed directly.
    private static func indexSingleFile(fileURL: URL, db: SemanticDatabase) async {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            AppLog.index.error("indexSingleFile: cannot read \(fileURL.path)")
            return
        }

        let docId = fileURL.lastPathComponent
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let modId = "mod_single_file"

        // Root module
        await db.upsertModule(id: modId, name: fileName, path: fileURL.deletingLastPathComponent().path,
                              parentId: nil, level: 0, fileCount: 1)

        // FTS index
        await db.indexDocumentFTS(documentId: docId, title: fileName, content: content)

        // Content hash
        try? await db.upsertDocument(id: docId, projectId: fileName, filePath: fileURL.path,
                                     fileName: docId, fileExt: "md", contentHash: fnv1a(content))

        // Parse symbols inline (headings) — no directory scan
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineNum = i + 1
            if line.range(of: #"^#{1,6}\s+.+"#, options: .regularExpression) != nil {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let symId = "sym_h_\(fnv1a("\(docId):\(lineNum):\(text)"))"
                await db.insertSymbol(id: symId, moduleId: modId, documentId: docId,
                                      name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum, context: nil)
            }
        }

        AppLog.index.debug("indexSingleFile: parsed \(docId), \(content.count) chars")
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in text.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }
}
