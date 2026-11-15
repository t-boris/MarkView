import Foundation

// End-to-End QA (feature end-to-end-qa): material a person attaches to a new scenario (screenshots, designs, documents, any file).
// The assistant reads files through its own tools and only inside the project folder, so a file from outside is copied under
// `.dde/qa/inputs/<id>/` (git-ignored) for the one run and removed after it; a file of the project is named by its path as it is.
// Foundation only; checked on its own by tools/tests/qa-tests.sh.

enum QAAttachments {
    struct Staged: Equatable {
        /// Every attachment as a path relative to the project folder, in the order given.
        var paths: [String] = []
        /// The ones that are images, as absolute URLs under the project folder (the assistant opens them as pictures).
        var images: [URL] = []
        /// The folder holding the copies of files from outside the project; nil when nothing was copied.
        var copies: URL?
    }

    enum Failure: Error, Equatable, LocalizedError {
        case tooMany(Int)
        case tooLarge(String)
        case notAFile(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooMany(let limit): return "A scenario takes at most \(limit) attached files."
            case .tooLarge(let name): return "\(name) is over \(QAAttachments.maxBytes / 1_000_000) MB and cannot be attached."
            case .notAFile(let name): return "\(name) is a folder; attach the files in it."
            case .unreadable(let name): return "\(name) could not be read."
            }
        }
    }

    static let maxFiles = 12
    /// The size of one file that is copied from outside the project.
    static let maxBytes = 25_000_000
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// Makes `urls` readable for the assistant. `id` names the folder of the copies, so two generations never share one.
    static func stage(_ urls: [URL], root: URL, id: String, fileManager: FileManager = .default) throws -> Staged {
        var seen = Set<String>()
        let files = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
        guard files.count <= maxFiles else { throw Failure.tooMany(maxFiles) }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let copyFolder = QAStore.localFolder(root).appendingPathComponent("inputs/" + QAStore.safeID(id), isDirectory: true)
        var staged = Staged()
        do {
            for (index, file) in files.enumerated() {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory) else { throw Failure.unreadable(file.lastPathComponent) }
                var target = file
                if file.path.hasPrefix(rootPath + "/") {
                    // A file of the project is read where it is, whatever its size.
                    staged.paths.append(String(file.path.dropFirst(rootPath.count + 1)))
                } else {
                    if isDirectory.boolValue { throw Failure.notAFile(file.lastPathComponent) }
                    let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
                    guard let size else { throw Failure.unreadable(file.lastPathComponent) }
                    guard size <= maxBytes else { throw Failure.tooLarge(file.lastPathComponent) }
                    if staged.copies == nil {
                        QAStore.prepareLocalFolder(root)
                        try fileManager.createDirectory(at: copyFolder, withIntermediateDirectories: true)
                        staged.copies = copyFolder
                    }
                    target = copyFolder.appendingPathComponent("\(index + 1)-" + plainName(file.lastPathComponent))
                    do { try fileManager.copyItem(at: file, to: target) } catch { throw Failure.unreadable(file.lastPathComponent) }
                    staged.paths.append(String(target.path.dropFirst(rootPath.count + 1)))
                }
                if isImage(file) { staged.images.append(target) }
            }
        } catch {
            discard(staged, fileManager: fileManager)
            throw error
        }
        return staged
    }

    /// Removes the copies made for one generation. The files of the project are never touched.
    static func discard(_ staged: Staged, fileManager: FileManager = .default) {
        if let copies = staged.copies { try? fileManager.removeItem(at: copies) }
    }

    /// A file name that is safe inside a path the assistant is given: no separators, no leading dot.
    static func plainName(_ name: String) -> String {
        var plain = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while plain.hasPrefix(".") { plain.removeFirst() }
        return plain.isEmpty ? "file" : plain
    }
}
