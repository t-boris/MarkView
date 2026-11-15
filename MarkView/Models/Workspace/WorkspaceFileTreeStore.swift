import Foundation
import Combine
import os
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Owns file-tree state, exclusion rules, and file-system watching for the active workspace.
@MainActor
final class WorkspaceFileTreeStore: ObservableObject {
    @Published var rootNode: FileNode?
    @Published private(set) var excludedFolders: Set<String> = []
    @Published var sortOrder = FileTreeSortOrder() {
        didSet {
            Settings.standard.set(sortOrder.field.rawValue, for: Setting.fileTreeSortField)
            Settings.standard.set(sortOrder.ascending, for: Setting.fileTreeSortAscending)
            refresh()
        }
    }

    /// True while the folder is still being opened (its index is being built): the watcher leaves the tree alone until it is done.
    var autoRefreshPaused = false
    /// One beat of the watcher's timer (the Git status changes without the top folder changing); the window follows it.
    let timerBeats = PassthroughSubject<Void, Never>()

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileWatchTimer: Timer?
    private var fileWatchDebounce: DispatchWorkItem?
    private var lastRootModDate: Date?
    /// Whether the open folder holds a Markdown file (`AR-42`). A background walk answers it after the tree loads or reloads;
    /// until it has answered the flag is false, and the views that read it update when it changes.
    @Published private(set) var hasMarkdownFiles = false
    private var markdownProbe: Task<Void, Never>?
    /// The tree rebuild in flight (`AR-19`): a newer rebuild, a reset or a stop replaces or cancels it.
    private var reloadTask: Task<Void, Never>?

    init() {
        let settings = Settings.standard
        if let savedField = settings.stored(Setting.fileTreeSortField), let field = FileTreeSortField(rawValue: savedField) {
            sortOrder.field = field
        }
        if let ascending = settings.stored(Setting.fileTreeSortAscending) {
            sortOrder.ascending = ascending
        }
    }

    func reset() {
        stopWatching()
        reloadTask?.cancel()
        reloadTask = nil
        rootNode = nil
        excludedFolders = []
        lastRootModDate = nil
        probeMarkdownFiles()
    }

    func setRootNode(_ node: FileNode?) {
        rootNode = node
        lastRootModDate = node.map { rootModificationDate(for: $0.url) } ?? nil
        probeMarkdownFiles()
    }

    /// Look for a Markdown file in the open folder off the main thread; a newer probe (another tree load) replaces this one.
    private func probeMarkdownFiles() {
        markdownProbe?.cancel()
        guard let folder = rootNode?.url else {
            markdownProbe = nil
            hasMarkdownFiles = false
            return
        }
        markdownProbe = Task.detached(priority: .utility) { [weak self] in
            let found = BackgroundFileScans.containsMarkdown(in: folder)
            guard !Task.isCancelled else { return }
            await self?.finishMarkdownProbe(folder: folder, found: found)
        }
    }

    private func finishMarkdownProbe(folder: URL, found: Bool) {
        guard rootNode?.url == folder else { return }
        hasMarkdownFiles = found
    }

    func loadExcludedFolders() {
        excludedFolders = rootNode.map { ExcludedFolders.load(for: $0.url) } ?? []
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
        guard let root = rootNode?.url else { return }
        ExcludedFolders.save(excludedFolders, for: root)
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
                guard let self, !self.autoRefreshPaused else { return }
                self.reloadFileTree()
            }

            self.fileWatchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }

        fileWatcher?.setCancelHandler { close(fd) }
        fileWatcher?.resume()

        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForFileTreeChanges() }
        }
    }

    private func checkForFileTreeChanges() {
        timerBeats.send()
        guard let rootURL = rootNode?.url else { return }
        guard !autoRefreshPaused else { return }
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

        reloadTask?.cancel()
        reloadTask = Task.detached { [weak self] in
            var rebuilt = FileTree.build(from: rootURL, sortOrder: sort)
            rebuilt.restoreExpansion(from: expandedPaths, sortOrder: sort)
            let childCount = rebuilt.children?.count ?? 0
            Self.log("reloadFileTree: rebuilt with \(childCount) children")
            guard !Task.isCancelled else { return }
            await self?.finishReload(rebuilt, of: rootURL)
        }
    }

    /// Shows a rebuilt tree unless the folder changed while it was being built.
    private func finishReload(_ rebuilt: FileTree, of rootURL: URL) {
        guard rootNode?.url == rootURL else { return }
        rootNode = FileNode(rebuilt)
        lastRootModDate = rootModificationDate(for: rootURL)
        probeMarkdownFiles()
        Self.log("reloadFileTree: rootNode updated on MainActor")
    }


    private nonisolated static func log(_ msg: String) {
        AppLog.fileTree.debug("\(msg)")
    }

    private func rootModificationDate(for url: URL) -> Date? {
        // Must clear cache — URL resource values are aggressively cached by Foundation
        (url as NSURL).removeCachedResourceValue(forKey: .contentModificationDateKey)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
