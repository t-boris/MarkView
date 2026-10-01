import Foundation

/// A web page or its selection saved as a Markdown document in the project
/// ("Save as Markdown" in the browser tab).
enum WebClip {
    /// The folder offered first: where research documents live.
    static let defaultFolder = ResearchDocument.folder

    /// The document: front matter (title, source URL, capture date, whether it is a selection)
    /// and the converted Markdown.
    static func document(_ capture: PageCapture, mode: PageCapture.Mode, title: String, date: String) -> String {
        var front = FrontMatter()
        front.set("type", "web-clip")
        front.set("title", title)
        front.set("source", capture.url?.absoluteString)
        front.set("captured", date)
        if mode == .selection { front.set("excerpt", "true") }
        var body = capture.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .selection, !body.hasPrefix("# ") {
            let source = capture.url.map { " — [\(linkText($0))](\($0.absoluteString))" } ?? ""
            body = "# \(title)\n\n> Excerpt\(source)\n\n" + body
        }
        return front.join(body: body + "\n")
    }

    /// `<date>-<slug>.md` from the page title (or its host when it has none).
    static func fileName(title: String, url: URL?, date: String) -> String {
        let name = title.isEmpty ? (url?.host ?? "page") : title
        return "\(date)-\(ResearchDocument.slug(name)).md"
    }

    /// The title written into the document: the page's, else its host.
    static func title(of capture: PageCapture) -> String {
        let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return capture.url?.host ?? "Web page"
    }

    /// A free file in `folder` for `name`, adding `-2`, `-3`, … before the extension.
    static func freeURL(in folder: URL, name: String, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "md" : (name as NSString).pathExtension
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    /// A file name the user typed, made safe: no folders, `.md` added when missing.
    static func sanitizedName(_ typed: String) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext != "md" && ext != "markdown" { name += ".md" }
        return name
    }

    /// Folders offered for saving, relative to the project: research first, then the
    /// usual places for notes and documentation that exist, then the other top-level
    /// folders that already hold Markdown.
    static func suggestedFolders(root: URL, fileManager: FileManager = .default) -> [String] {
        var folders = [defaultFolder]
        let usual = ["docs/notes", "docs/web", "docs/references", "docs", "notes", "research", "references"]
        for folder in usual where !folders.contains(folder) && isDirectory(root.appendingPathComponent(folder), fileManager) {
            folders.append(folder)
        }
        let children = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        let ignored: Set<String> = ["node_modules", "build", "dist", "out", "target", "vendor", "Pods", "DerivedData"]
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard !folders.contains(name), !ignored.contains(name), isDirectory(child, fileManager),
                  containsMarkdown(child, fileManager) else { continue }
            folders.append(name)
        }
        return folders
    }

    /// True when `url` is `root` or inside it (after resolving symbolic links).
    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func linkText(_ url: URL) -> String {
        (url.host ?? url.absoluteString) + (url.port.map { ":\($0)" } ?? "")
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func containsMarkdown(_ folder: URL, _ fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen > 400 { return false }
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            if ["md", "markdown"].contains(url.pathExtension.lowercased()) { return true }
        }
        return false
    }
}
