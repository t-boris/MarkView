import Foundation
import AppKit
import PDFKit
import SQLite3

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
    var page: Int? = nil

    var id: String { "\(scope.rawValue):\(path ?? title):\(line ?? 0):\(page ?? 0)" }
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
        var pdfPages: [(number: Int, text: String)] = []
        /// Large files or files beyond the memory budget are searched on demand.
        var deferredText: URL?
        var deferredDocument: URL?
        var deferredRoot: URL?
    }

    private var documents: [Document] = []
    /// Text held in memory so far in this rebuild (a guard for a project with a great deal of text).
    private var contentBytes = 0
    static let maximumTotalTextBytes = 400 * 1_048_576
    private let textBudget: Int

    init(textBudget: Int = ProjectSearchIndex.maximumTotalTextBytes) {
        self.textBudget = max(0, textBudget)
    }
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
        "node_modules", "build", "dist", "coverage", "deriveddata", "venv",
        // Build tool caches (BUG-083): Turborepo's `.turbo` held 8.9 GB of task outputs in one project.
        ".turbo", ".cache", ".parcel-cache", ".svelte-kit", ".nuxt", ".angular"
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
    static let maximumDeferredTextBytes = 64 * 1_048_576
    /// Extract text from reasonably sized documents, keeping the same overall in-memory budget.
    static let maximumDocumentBytes = 20 * 1_048_576
    static let maximumPDFPages = 500

    static func wordText(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = try? NSAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil).string else { return nil }
        return String(text.prefix(maximumTextBytes))
    }

    static func pdfText(of url: URL) -> [(number: Int, text: String)] {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.allowsCopying else { return [] }
        var pages: [(number: Int, text: String)] = []
        var bytes = 0
        for index in 0..<min(pdf.pageCount, maximumPDFPages) {
            guard let text = pdf.page(at: index)?.string, !text.isEmpty else { continue }
            let remaining = maximumTextBytes - bytes
            guard remaining > 0 else { break }
            let part = String(text.prefix(remaining))
            bytes += part.utf8.count
            pages.append((number: index + 1, text: part))
        }
        return pages
    }

    /// The text of a file, or nil for a binary one: a known text extension is read at once, any other
    /// file (a `.vue`, a `.tf`, a file without extension) when its first bytes hold no NUL and it is UTF-8.
    static func text(of url: URL, known: Bool) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= maximumDeferredTextBytes else { return nil }
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
            let ext = url.pathExtension.lowercased()
            var content: String?
            var pdfPages: [(number: Int, text: String)] = []
            var deferredText: URL?
            var deferredDocument: URL?
            let knownText = Self.textExtensions.contains(ext) || Self.textNames.contains(name)
            if contentBytes < textBudget {
                if ext == "pdf", size <= Self.maximumDocumentBytes {
                    pdfPages = Self.pdfText(of: url)
                } else if ext == "docx", size <= Self.maximumDocumentBytes {
                    content = Self.wordText(of: url)
                } else if size <= Self.maximumTextBytes {
                    content = Self.text(of: url, known: knownText)
                }
            }
            if contentBytes >= textBudget, ["pdf", "docx"].contains(ext), size <= Self.maximumDocumentBytes {
                deferredDocument = url
            } else if content == nil, ext != "pdf", ext != "docx", size <= Self.maximumDeferredTextBytes,
                      !Self.binaryExtensions.contains(ext), (size > Self.maximumTextBytes || contentBytes >= textBudget) {
                deferredText = url
            }
            contentBytes += (content?.utf8.count ?? 0) + pdfPages.reduce(0) { $0 + $1.text.utf8.count }
            next.append(Document(path: path, content: content, pdfPages: pdfPages, deferredText: deferredText,
                                 deferredDocument: deferredDocument,
                                 deferredRoot: deferredText == nil && deferredDocument == nil ? nil : root))
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

    /// A short excerpt centred on the match, even for a long line of source or extracted document text.
    static func snippet(_ line: String, matching needle: String) -> String {
        guard let match = line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(line.prefix(240)).trimmingCharacters(in: .whitespaces)
        }
        let start = line.index(match.lowerBound, offsetBy: -80, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(start, offsetBy: 240, limitedBy: line.endIndex) ?? line.endIndex
        return (start == line.startIndex ? "" : "…") + String(line[start..<end]).trimmingCharacters(in: .whitespaces) + (end == line.endIndex ? "" : "…")
    }

    func search(_ query: String) -> [ProjectSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var files: [ProjectSearchResult] = []
        var contents: [ProjectSearchResult] = []
        for document in documents {
            if Task<Never, Never>.isCancelled { return [] }
            if document.path.localizedCaseInsensitiveContains(needle) {
                files.append(ProjectSearchResult(scope: .file, title: URL(fileURLWithPath: document.path).lastPathComponent,
                                                 path: document.path, snippet: nil, line: nil))
            }
            guard contents.count < 150 else { continue }
            func safeDeferred(_ url: URL, limit: Int) -> Bool {
                guard let root = document.deferredRoot,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= limit else { return false }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                return resolved.hasPrefix(base)
            }
            let text = document.content ?? document.deferredText.flatMap { url in
                guard safeDeferred(url, limit: Self.maximumDeferredTextBytes) else { return nil }
                return Self.text(of: url, known: Self.textExtensions.contains(url.pathExtension.lowercased()) || Self.textNames.contains(url.lastPathComponent.lowercased()))
            } ?? document.deferredDocument.flatMap { url in
                guard url.pathExtension.lowercased() == "docx", safeDeferred(url, limit: Self.maximumDocumentBytes) else { return nil }
                return Self.wordText(of: url)
            }
            let pages = document.deferredDocument.flatMap { url in
                guard url.pathExtension.lowercased() == "pdf", safeDeferred(url, limit: Self.maximumDocumentBytes) else { return nil }
                return Self.pdfText(of: url)
            } ?? document.pdfPages
            let sources: [(page: Int?, text: String)] = pages.isEmpty
                ? text.map { [(page: nil, text: $0)] } ?? []
                : pages.map { (page: Optional($0.number), text: $0.text) }
            for source in sources {
                for (offset, line) in source.text.components(separatedBy: .newlines).enumerated() {
                    if line.localizedCaseInsensitiveContains(needle) {
                        contents.append(ProjectSearchResult(scope: .content,
                            title: URL(fileURLWithPath: document.path).lastPathComponent,
                            path: document.path, snippet: Self.snippet(line, matching: needle),
                            line: offset + 1, page: source.page))
                        if contents.count >= 150 { break }
                    }
                }
                if contents.count >= 150 { break }
            }
        }
        return Array(files.prefix(75)) + Array(contents.prefix(150))
    }
}

/// Search the existing document FTS index on a separate read-only connection.
enum ProjectDocumentSearch {
    static func search(databasePath: String, query: String, limit: Int = 50) -> [ProjectSearchResult] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).prefix(16).map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        guard !terms.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT document_id, title, snippet(fts_documents, 2, '', '', '…', 40) FROM fts_documents WHERE fts_documents MATCH ? ORDER BY rank LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let expression = terms.joined(separator: " AND ")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, expression, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 500))))
        var results: [ProjectSearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
            let snippet = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            results.append(ProjectSearchResult(scope: .content, title: String(cString: title),
                path: String(cString: id), snippet: snippet, line: nil))
        }
        return results
    }
}
