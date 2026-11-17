import Foundation
#if canImport(MarkView)
@testable import MarkView
#endif

/// One configurable project fake shared by the standalone coordinator tests.
@MainActor
final class StubProject: ProjectProviding {
    var root: URL?
    private var assistantOverride: URL??
    private let aiProjectTracksRoot: Bool
    private let pathsRelativeToRoot: Bool
    var linkedFolderURLs: [URL] = []
    var treeRefreshes = 0

    init(root: URL? = nil, aiProjectTracksRoot: Bool = false, pathsRelativeToRoot: Bool = false) {
        self.root = root
        self.aiProjectTracksRoot = aiProjectTracksRoot
        self.pathsRelativeToRoot = pathsRelativeToRoot
    }

    var aiProject: URL? {
        get {
            if let assistantOverride { return assistantOverride }
            return aiProjectTracksRoot ? root : nil
        }
        set { assistantOverride = .some(newValue) }
    }
    var searchRoots: [URL] { (root.map { [$0] } ?? []) + linkedFolderURLs }
    var database: SemanticDatabase?
    func relativePath(of url: URL) -> String {
        guard pathsRelativeToRoot, let root else { return url.path }
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    func markdownFiles(in folder: URL) -> [URL] { [] }
    func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
    func refreshFileTree() { treeRefreshes += 1 }
    func containerRoot(for url: URL) -> URL? { root }
}
