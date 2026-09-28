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

/// A private, memory-only index of supported UTF-8 project text. Rebuilding it
/// on search open and Refresh makes external edits and deletions visible without
/// persisting document contents in a new database.
actor ProjectSearchIndex {
    private struct Document {
        let path: String
        let content: String?
    }

    private var documents: [Document] = []
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
    static let excludedFileNames: Set<String> = [".env", ".env.local", ".env.production"]
    static let excludedExtensions: Set<String> = ["pem", "p12", "p8", "key", "cer", "crt"]
    static let maximumTextBytes = 2_097_152

    func rebuild(root: URL, progress: @Sendable (Int) -> Void) throws {
        documents = []
        indexedAt = nil
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]) else {
            documents = []
            indexedAt = Date()
            return
        }
        let prefix = root.standardizedFileURL.path + "/"
        var next: [Document] = []
        var count = 0
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
            let path = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let allowedText = Self.textExtensions.contains(url.pathExtension.lowercased()) || Self.textNames.contains(name)
            let content: String?
            if allowedText, (values.fileSize ?? 0) <= Self.maximumTextBytes {
                content = try? String(contentsOf: url, encoding: .utf8)
            } else {
                content = nil
            }
            next.append(Document(path: path, content: content))
            count += 1
            if count.isMultiple(of: 50) { progress(count) }
        }
        documents = next.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        indexedAt = Date()
        progress(count)
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
