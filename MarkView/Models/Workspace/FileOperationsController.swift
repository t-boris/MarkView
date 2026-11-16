import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the file operations ask of the window around them: the file tree reads the disk again after a change.
@MainActor
protocol FileOperationsHost: AnyObject {
    func refreshFileTree()
}

/// A file operation that did not happen, with the sentence the person is shown.
struct FileOperationError: Error, Equatable {
    let message: String
}

/// The changes the file tree makes to the files of the open project (`AR-14` step 2): creating a file or a folder, renaming,
/// moving and copying (also what a drop brings), and moving to the Trash. Each one also does what the window shows of it: the tabs of
/// moved files follow them, the tabs of trashed ones close, and the file tree is read again. The rules of moving and renaming are
/// in `FileTransfer`; the questions the person is asked, and what the list shows afterwards, are the file tree view's.
@MainActor
final class FileOperationsController {
    private weak var host: FileOperationsHost?
    private let tabs: TabsController
    private let project: any ProjectProviding
    /// Puts one item in the Trash; the system's by default, a check supplies a folder of its own.
    private let moveToTrash: (URL) throws -> Void

    init(host: FileOperationsHost, tabs: TabsController, project: any ProjectProviding,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.host = host
        self.tabs = tabs
        self.project = project
        self.moveToTrash = trash
    }

    // MARK: - Moving and copying

    /// Move (or copy) files and folders into `folder`, as the file tree's drag and drop does (see `FileTransfer`). Tabs of moved
    /// files follow them. Returns the errors.
    @discardableResult
    func transfer(_ sources: [URL], into folder: URL, copy: Bool) -> [String] {
        let result = FileTransfer.perform(sources, into: folder, copy: copy)
        tabs.follow(moved: result.moved)
        host?.refreshFileTree()
        return result.errors
    }

    /// Files dropped on a folder: moved when they all come from this project or one of its linked folders (⌥ Option copies, as in
    /// Finder), copied when any comes from elsewhere (e.g. Finder). Returns the errors.
    @discardableResult
    func drop(_ urls: [URL], into folder: URL, copyRequested: Bool) -> [String] {
        let roots = project.searchRoots.map { $0.standardizedFileURL.path }
        let inside = urls.allSatisfy { url in roots.contains { url.standardizedFileURL.path.hasPrefix($0 + "/") } }
        return transfer(urls, into: folder, copy: copyRequested || !inside)
    }

    /// Rename a file or folder in place; its open tabs follow. Returns the error, if any.
    func rename(_ url: URL, to name: String) -> String? {
        let result = FileTransfer.rename(url, to: name)
        tabs.follow(moved: result.moved)
        host?.refreshFileTree()
        return result.errors.first
    }

    // MARK: - Trash

    /// Move files and folders to the macOS Trash, recoverable from there. Their open tabs close without saving: the person chose to
    /// let them go. Returns the errors.
    func trash(_ urls: [URL]) -> [String] {
        var errors: [String] = []
        for url in urls {
            tabs.closeTabs(under: url)
            do { try moveToTrash(url) } catch {
                errors.append("Couldn't move “\(url.lastPathComponent)” to the Trash: \(error.localizedDescription)")
            }
        }
        host?.refreshFileTree()
        return errors
    }

    // MARK: - Creating

    /// Creates a file in `folder`: an empty name becomes "untitled.md", and a Markdown file starts with its name as the title. Never
    /// replaces an existing file.
    func createFile(named raw: String, in folder: URL) throws -> URL {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "untitled.md" }
        guard FileTransfer.isValidName(name) else { throw FileOperationError(message: "“\(name)” is not a valid file name.") }
        let fileURL = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FileOperationError(message: "“\(name)” already exists in this folder.")
        }
        let template = name.hasSuffix(".md") ? "# \(name.replacingOccurrences(of: ".md", with: ""))\n\n" : ""
        do {
            try AtomicFile.write(template, to: fileURL)
        } catch {
            throw FileOperationError(message: "Couldn't create “\(name)”: \(error.localizedDescription)")
        }
        host?.refreshFileTree()
        return fileURL
    }

    /// Creates a folder in `parent`; nil for an empty name (nothing to do). Never replaces an existing item.
    func createFolder(named raw: String, in parent: URL) throws -> URL? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        guard FileTransfer.isValidName(name) else { throw FileOperationError(message: "“\(name)” is not a valid folder name.") }
        let folderURL = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: folderURL.path) else {
            throw FileOperationError(message: "“\(name)” already exists in this folder.")
        }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        } catch {
            throw FileOperationError(message: "Couldn't create “\(name)”: \(error.localizedDescription)")
        }
        host?.refreshFileTree()
        return folderURL
    }
}
