import Foundation

/// What a feature reads of the open project: the folder, the folders linked to it, where search looks and the project's
/// semantic database. A feature takes this instead of a reference to the window's whole `WorkspaceManager` (`AR-14` step 8,
/// `AR-17`); `ProjectContext` is the one implementation.
@MainActor
protocol ProjectProviding: AnyObject {
    /// The open folder, or a single file's folder; nil while nothing is open.
    var root: URL? { get }
    /// The project whose assistant, model and X-Ray model the window uses (BUG-021); nil for a single file, which uses the defaults.
    var aiProject: URL? { get }
    /// The folders linked to the project as aliases (Task 59): readable by the AI together with it.
    var linkedFolderURLs: [URL] { get }
    /// The project folder followed by the folders linked to it: what search and the index cover.
    var searchRoots: [URL] { get }
    /// The project's search database; nil until it is open.
    var database: SemanticDatabase? { get }
    /// The name `url` has in the project: the path inside the root, the document id inside a linked folder, else its full path.
    func relativePath(of url: URL) -> String
    /// The `.md` files under `folder`, for Recursive Insight: hidden files, package contents and `.dde` paths are skipped, and a symlink
    /// that resolves outside the folder is skipped.
    func markdownFiles(in folder: URL) -> [URL]
    /// `<project>/.dde/cache` for a document of the project, else the document's own folder (where single-file mode keeps `.dde`).
    func cacheDirectory(for url: URL) -> URL
    /// The file tree reads the folder again (a feature, a bug report or a research document was written).
    func refreshFileTree()
}
