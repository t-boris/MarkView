import Foundation

enum ProjectSearchScope: String {
    case file = "File"
    case content = "Content"
    case command = "Command"
}

struct ProjectSearchResult: Identifiable {
    let scope: ProjectSearchScope
    let title: String
    let path: String?
    let snippet: String?
    let line: Int?

    var id: String { "\(scope.rawValue):\(path ?? title):\(line ?? 0)" }
}

/// A folder the search index walks: the project (empty prefix) or a linked folder, whose
/// paths are shown and stored as `@linked/<name>/…` (Task 59).
struct ProjectSearchRoot: Equatable {
    let prefix: String
    let url: URL

    static func project(_ url: URL) -> ProjectSearchRoot { ProjectSearchRoot(prefix: "", url: url) }
    static func linked(_ folder: LinkedFolder) -> ProjectSearchRoot {
        ProjectSearchRoot(prefix: LinkedFolders.documentIdPrefix + folder.name + "/", url: folder.url)
    }

    /// The roots of a workspace: the project, then its linked folders.
    static func all(project: URL, linked: [LinkedFolder]) -> [ProjectSearchRoot] {
        [.project(project)] + linked.map(ProjectSearchRoot.linked)
    }

    /// The file a result path names, when it is under one of `roots`.
    static func url(for path: String, in roots: [ProjectSearchRoot]) -> URL? {
        let root = roots.filter { !$0.prefix.isEmpty && path.hasPrefix($0.prefix) }.first ?? roots.first { $0.prefix.isEmpty }
        guard let root else { return nil }
        return root.url.appendingPathComponent(String(path.dropFirst(root.prefix.count)))
    }
}

/// A private, memory-only index of project file names and UTF-8 text (any text file, not a list of extensions),
/// plus the entry names inside zip and other archives. Rebuilding it
/// on search open and Refresh makes external edits and deletions visible without
/// persisting document contents in a new database.
actor ProjectSearchIndex {
    private struct Document {
        let path: String
        let content: String?
    }

    private var documents: [Document] = []
    /// Text held in memory so far in this rebuild (a guard for a project with a great deal of text).
    private var contentBytes = 0
    static let maximumTotalTextBytes = 400 * 1_048_576
    private(set) var indexedAt: Date?

    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "swift", "m", "h", "c", "cc", "cpp", "hpp",
        "js", "jsx", "ts", "tsx", "css", "scss", "html", "htm", "json", "jsonc",
        "yaml", "yml", "xml", "toml", "ini", "cfg", "conf", "sh", "zsh", "bash",
        "py", "rb", "go", "rs", "java", "kt", "cs", "php", "sql", "graphql",
        "proto", "gradle", "csv", "tsv", "canvas"
    ]
    static let textNames: Set<String> = [
        "readme", "license", "makefile", "dockerfile", "gemfile", ".gitignore", ".editorconfig"
    ]
    static let excludedDirectories: Set<String> = [
        ".git", ".dde", ".build", ".next", ".venv", ".markview-insight",
        "node_modules", "build", "dist", "coverage", "deriveddata", "venv"
    ]
    /// Files that are never read as text (their content is binary); their names are still searched.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "ico", "icns", "psd", "ai", "raw",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "jar", "war", "dmg", "pkg", "iso",
        "mp3", "m4a", "wav", "flac", "aac", "ogg", "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "ttf", "otf", "woff", "woff2", "eot", "exe", "dll", "dylib", "so", "a", "o", "class", "wasm", "pyc",
        "sqlite", "sqlite3", "db", "db3", "parquet", "pq", "arrow", "feather", "avro", "car", "ds_store", "nib", "xib"
    ]
    static let excludedFileNames: Set<String> = [".env", ".env.local", ".env.production"]
    /// Archives whose entry names are searched (their content is not): a zip lists from its central
    /// directory, so any size is quick; the others are decompressed to be listed, so only small ones.
    static let maximumZipBytes = 4_294_967_296
    static let maximumOtherArchiveBytes = 52_428_800
    static let maximumArchiveEntries = 5_000
    /// Marks an entry inside an archive in a result path: `docs/site.zip!/index.html`.
    static let archiveSeparator = "!/"
    static let excludedExtensions: Set<String> = ["pem", "p12", "p8", "key", "cer", "crt"]
    static let maximumTextBytes = 2_097_152

    /// The text of a file, or nil for a binary one: a known text extension is read at once, any other
    /// file (a `.vue`, a `.tf`, a file without extension) when its first bytes hold no NUL and it is UTF-8.
    static func text(of url: URL, known: Bool) -> String? {
        if !known {
            if binaryExtensions.contains(url.pathExtension.lowercased()) { return nil }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 8192)) ?? Data()
            if head.contains(0) { return nil }
        }
        guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func rebuild(root: URL, progress: @Sendable (Int) -> Void) throws {
        try rebuild(roots: [.project(root)], progress: progress)
    }

    /// Walk every root in turn: the project, then its linked folders.
    func rebuild(roots: [ProjectSearchRoot], progress: @Sendable (Int) -> Void) throws {
        documents = []
        indexedAt = nil
        contentBytes = 0
        var next: [Document] = []
        var count = 0
        for searchRoot in roots {
            try walk(searchRoot, into: &next, count: &count, progress: progress)
        }
        documents = next.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        indexedAt = Date()
        progress(count)
    }

    private func walk(_ searchRoot: ProjectSearchRoot, into next: inout [Document], count: inout Int,
                      progress: @Sendable (Int) -> Void) throws {
        let root = searchRoot.url
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]) else { return }
        let prefix = root.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            try Task<Never, Never>.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                                   .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            let name = url.lastPathComponent.lowercased()
            if values.isDirectory == true {
                if Self.excludedDirectories.contains(name) ||
                    url.standardizedFileURL.path == root.standardizedFileURL.appendingPathComponent("docs/handoffs").path {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  !Self.excludedFileNames.contains(name),
                  !Self.excludedExtensions.contains(url.pathExtension.lowercased()),
                  url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let path = searchRoot.prefix + String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let size = values.fileSize ?? 0
            let content = size <= Self.maximumTextBytes && contentBytes < Self.maximumTotalTextBytes
                ? Self.text(of: url, known: Self.textExtensions.contains(url.pathExtension.lowercased()) || Self.textNames.contains(name))
                : nil
            contentBytes += content?.utf8.count ?? 0
            next.append(Document(path: path, content: content))
            count += 1
            if Archive.isArchive(url) {
                let limit = ["zip", "jar"].contains(url.pathExtension.lowercased()) ? Self.maximumZipBytes : Self.maximumOtherArchiveBytes
                if size <= limit, let entries = try? Archive.list(url) {
                    for entry in entries.prefix(Self.maximumArchiveEntries) where !entry.isDirectory && entry.isSafe {
                        next.append(Document(path: path + Self.archiveSeparator + entry.path, content: nil))
                    }
                }
            }
            if count.isMultiple(of: 50) { progress(count) }
        }
    }

    func search(_ query: String) -> [ProjectSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var files: [ProjectSearchResult] = []
        var contents: [ProjectSearchResult] = []
        for document in documents {
            if document.path.localizedCaseInsensitiveContains(needle) {
                files.append(ProjectSearchResult(scope: .file, title: URL(fileURLWithPath: document.path).lastPathComponent,
                                                 path: document.path, snippet: nil, line: nil))
            }
            guard contents.count < 150, let content = document.content else { continue }
            for (offset, line) in content.components(separatedBy: .newlines).enumerated() {
                if line.localizedCaseInsensitiveContains(needle) {
                    contents.append(ProjectSearchResult(scope: .content,
                        title: URL(fileURLWithPath: document.path).lastPathComponent,
                        path: document.path, snippet: String(line.prefix(240)).trimmingCharacters(in: .whitespaces),
                        line: offset + 1))
                    if contents.count >= 150 { break }
                }
            }
        }
        return Array(files.prefix(75)) + Array(contents.prefix(150))
    }
}
