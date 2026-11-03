import Foundation

/// The rule for `markview-doc:///<absolute path>`: which files next to a document the editor page may be given (BUG-061).
///
/// The editor page cannot read `file://`, so the pictures a document refers to by a relative path are served by the app
/// (`DocumentFileSchemeHandler`). The text of the document is never changed to carry them: it stays exactly what is on disk,
/// so a picture cannot make a file look modified and cannot be written into it by a save.
///
/// Only pictures are served, and only from inside the folders the person is working in: the project folder and the folder of each
/// open document. A path that leaves those folders, by `..` or by a symbolic link, is refused. The rule is pure so a standalone
/// check can cover it (`tools/tests/document-files-tests.sh`).
enum DocumentFiles {
    static let scheme = "markview-doc"

    /// The picture types a document can show, by file extension, with the content type the page needs (an SVG is drawn
    /// by an `<img>` only when it is declared as one).
    static let pictureTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "bmp": "image/bmp", "ico": "image/x-icon", "avif": "image/avif",
        "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic",
    ]

    enum Resolution: Equatable {
        case file(URL, contentType: String)
        case forbidden
    }

    /// The file a request asks for, or `.forbidden`. `roots` are the folders a picture may come from.
    static func resolve(_ request: URL, roots: [URL]) -> Resolution {
        guard request.scheme == scheme else { return .forbidden }
        let path = request.path
        guard path.hasPrefix("/") else { return .forbidden }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let contentType = pictureTypes[file.pathExtension.lowercased()] else { return .forbidden }
        let inside = roots.contains { root in
            let folder = root.resolvingSymlinksInPath().standardizedFileURL.path
            return file.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
        return inside ? .file(file, contentType: contentType) : .forbidden
    }

    /// The folders pictures may come from: the project folder and the folder of every open document.
    static func roots(project: URL?, documents: [URL]) -> [URL] {
        var result: [URL] = []
        for url in ([project].compactMap { $0 } + documents.map { $0.deletingLastPathComponent() }) where !result.contains(url) {
            result.append(url)
        }
        return result
    }
}
