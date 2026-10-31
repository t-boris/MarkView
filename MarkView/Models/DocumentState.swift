import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Supported file types for viewing/editing
enum FileType: String {
    case markdown
    case json
    case xml
    case yaml
    case canvas
    /// Source code or plain text, shown read-only in the code viewer.
    case code
    /// Data files with their own viewers (Task 84), read by the page from `markview-data:`:
    /// tables (CSV, TSV, JSON Lines…) with SQL, Parquet, SQLite databases and logs.
    case table
    case parquet
    case sqlite
    case log

    static let tableExtensions: Set<String> = ["csv", "tsv", "tab", "psv", "jsonl", "ndjson", "xlsx", "xlsm", "ods", "har",
                                                     "arrow", "feather", "ipc", "arrows", "avro"]
    static let parquetExtensions: Set<String> = ["parquet", "pq"]
    static let sqliteExtensions: Set<String> = ["sqlite", "sqlite3", "db", "db3"]
    static let logExtensions: Set<String> = ["log", "out"]

    /// Data viewers whose original bytes can also be explained as line-numbered text.
    static func hasTextSource(_ url: URL) -> Bool {
        !isData(url) || ["csv", "tsv", "tab", "psv", "jsonl", "ndjson", "har", "log", "out"]
            .contains(url.pathExtension.lowercased())
    }

    /// A data file: opened without reading it as text, shown by the page's data viewers.
    static func isData(_ url: URL) -> Bool {
        [.table, .parquet, .sqlite, .log].contains(from(url: url))
    }

    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// A web page that can be shown in the browser tab.
    static func isHTML(_ url: URL) -> Bool { htmlExtensions.contains(url.pathExtension.lowercased()) }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Extensions with a dedicated viewer (markdown, structured data, canvas).
    static let supportedExtensions: Set<String> = markdownExtensions.union([
        "json",
        "xml", "plist", "xsd", "xsl", "xslt", "svg",
        "yml", "yaml",
        "canvas"
    ]).union(tableExtensions).union(parquetExtensions).union(sqliteExtensions).union(logExtensions)

    /// Whether the filename identifies a known text format (unknown formats still open as text).
    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) || codeLanguage(for: url) != nil
    }

    /// Whether `url` is an image (any format the system decodes), shown in the image viewer.
    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// Every regular file is visible/openable, independent of its name or extension.
    /// Unknown formats are attempted as text; binary content is rejected by `readText`.
    static func isOpenable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    }

    /// Determine file type from URL extension
    static func from(url: URL) -> FileType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case _ where markdownExtensions.contains(ext): return .markdown
        case "json": return .json
        case "xml", "plist", "xsd", "xsl", "xslt", "svg": return .xml
        case "yml", "yaml": return .yaml
        case "canvas": return .canvas
        case _ where tableExtensions.contains(ext): return .table
        case _ where parquetExtensions.contains(ext): return .parquet
        case _ where sqliteExtensions.contains(ext): return .sqlite
        case _ where logExtensions.contains(ext): return .log
        default: return .code
        }
    }

    /// CodeMirror language id for a recognized source file ("" = known plain text),
    /// or nil when the filename has no known highlighter. Ids match `languages` in tools/web-vendor/codemirror-entry.js.
    static func codeLanguage(for url: URL) -> String? {
        if let byName = codeFileNames[url.lastPathComponent] { return byName }
        // Only recognized names get highlighting; arbitrary dotfiles stay plain text.
        let name = url.lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return "properties" }
        if [".npmrc", ".yarnrc", ".editorconfig", ".gitconfig", ".gitattributes"].contains(name) { return "properties" }
        if url.pathExtension.isEmpty {
            if plainFileNames.contains(url.lastPathComponent) { return "" }
        }
        return codeExtensions[url.pathExtension.lowercased()]
    }

    /// Language for the source/Explain view, including formats with dedicated viewers.
    static func sourceLanguage(for url: URL) -> String {
        switch from(url: url) {
        case .markdown: return "markdown"
        case .json, .canvas: return "json"
        case .xml: return "xml"
        case .yaml: return "yaml"
        default: return codeLanguage(for: url) ?? ""
        }
    }

    /// Bounded text loading for the generic viewer. Call off the main thread.
    /// BOM-tagged Unicode is accepted; binary/control bytes are never silently replaced.
    static func readText(at url: URL) throws -> String {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw TextReadError.notRegular }
        let limit = 32 * 1024 * 1024
        guard (values.fileSize ?? 0) <= limit else { throw TextReadError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw TextReadError.tooLarge }
        let text: String?
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf32)
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8)
        }
        guard let text, !text.unicodeScalars.contains(where: {
            $0.value < 32 && ![9, 10, 12, 13, 27].contains($0.value)
        }) else { throw TextReadError.binary }
        return text
    }

    enum TextReadError: LocalizedError {
        case notRegular, binary, tooLarge
        var errorDescription: String? {
            switch self {
            case .notRegular: return "This item is not a regular file."
            case .binary: return "This file contains binary data or an unsupported text encoding."
            case .tooLarge: return "This file is larger than the text viewer's 32 MB limit."
            }
        }
    }

    private static let plainFileNames: Set<String> = ["LICENSE", "LICENCE", "COPYING", "CODEOWNERS", "AUTHORS",
                                                       "NOTICE", "CHANGELOG", "VERSION", "CONTRIBUTORS"]

    private static let codeFileNames: [String: String] = [
        "Dockerfile": "dockerfile", "Containerfile": "dockerfile", "Makefile": "shell",
        "GNUmakefile": "shell", "CMakeLists.txt": "cmake", "Gemfile": "ruby", "Rakefile": "ruby",
        "Podfile": "ruby", "Fastfile": "ruby", "Brewfile": "ruby", "Jenkinsfile": "groovy",
        "Procfile": "shell", "Vagrantfile": "ruby",
    ]

    private static let codeExtensions: [String: String] = {
        var map: [String: String] = [:]
        func add(_ language: String, _ extensions: String...) { extensions.forEach { map[$0] = language } }
        add("javascript", "js", "mjs", "cjs", "jsx")
        add("typescript", "ts", "tsx", "mts", "cts")
        add("python", "py", "pyi", "pyw")
        add("rust", "rs")
        add("c", "c")
        add("cpp", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "ino", "cu")
        add("objectivec", "m")
        add("objectivecpp", "mm")
        add("java", "java")
        add("kotlin", "kt", "kts")
        add("scala", "scala", "sc")
        add("csharp", "cs")
        add("dart", "dart")
        add("swift", "swift")
        add("go", "go")
        add("php", "php")
        add("html", "html", "htm", "vue", "svelte", "xhtml")
        add("css", "css")
        add("scss", "scss")
        add("less", "less")
        add("sass", "sass")
        add("sql", "sql")
        add("shell", "sh", "bash", "zsh", "fish", "ksh", "command")
        add("ruby", "rb", "rake", "gemspec", "ex", "exs")
        add("lua", "lua")
        add("toml", "toml")
        add("perl", "pl", "pm")
        add("r", "r")
        add("powershell", "ps1", "psm1", "psd1")
        add("protobuf", "proto")
        add("diff", "diff", "patch")
        add("properties", "properties", "ini", "cfg", "conf", "env", "editorconfig")
        add("cmake", "cmake")
        add("haskell", "hs")
        add("clojure", "clj", "cljs", "cljc", "edn")
        add("erlang", "erl", "hrl")
        add("groovy", "groovy", "gradle")
        add("julia", "jl")
        add("ocaml", "ml", "mli")
        add("fsharp", "fs", "fsx", "fsi")
        add("crystal", "cr")
        // Text documents of the Book X-Ray open read-only here too (rst, adoc, org, text).
        add("", "txt", "text", "rst", "adoc", "asciidoc", "org", "log", "csv", "tsv", "graphql", "gql", "tf", "hcl", "lock", "gitignore")
        return map
    }()
}

/// Represents a table of contents heading entry
struct HeadingItem: Identifiable, Codable {
    let id: String
    let level: Int
    let text: String

    var indent: CGFloat {
        CGFloat((level - 1) * 16)
    }
}

/// Discriminator for the tab's underlying content source.
/// `.file` (default) preserves source-compat for all existing call sites that
/// read `tab.url` / `tab.content` — they continue to work unchanged.
/// `.insight` carries an in-memory Recursive Insight session (Task 4).
enum TabKind {
    case file
    case insight(InsightSession)
    /// X-Ray of the project (`scope` "") or of one of its folders (path relative to the
    /// project root); content lives in that scope's `ArchitectureStore`.
    case architecture(scope: String)
    /// A terminal opened in a folder; the session lives in `WorkspaceManager`.
    case terminal(UUID)
    /// An image file, shown by `ImageViewerView` (no text content).
    case image
    /// An archive (zip, tar, 7z…), shown by `ArchiveTabView`; its entries open as temporary copies.
    case archive
    /// The project's Deployments: where it runs and how each place is doing (`DeploymentsView`).
    case deployments
    /// The project's Discussions: questions answered as pages, with the decisions and open questions (`DiscussionsView`).
    case discussions
    /// A GitHub Actions run or an issue, shown by `GitHubRunView` / `GitHubIssueView`.
    case github(GitHubItem)
    /// A web page (a local development server or any site), shown by `BrowserTabView`.
    case browser(BrowserSession)
    /// A data file (`FileType.isData`): the editor page reads it itself and never writes it.
    case data
    /// Prototype Studio: a clickable prototype and its review conversation, shown by `PrototypeStudioView`.
    case prototype(PrototypeSession)

    /// Scope of the PR X-Ray tab: the project's X-Ray seen through one change.
    static let pullRequestScope = "#pr"
}

/// What a GitHub tab shows, in which repository ("owner/name"); `title` is the tab's name.
enum GitHubItem: Hashable, Codable {
    case run(id: Int, repo: String, title: String)
    case issue(number: Int, repo: String, title: String)
    case pullRequest(number: Int, repo: String, title: String)

    var title: String {
        switch self {
        case .run(_, _, let title), .issue(_, _, let title), .pullRequest(_, _, let title): return title
        }
    }

    var repo: String {
        switch self {
        case .run(_, let repo, _), .issue(_, let repo, _), .pullRequest(_, let repo, _): return repo
        }
    }

    /// Placeholder file name of the tab (never read or written).
    var marker: String {
        let repo = self.repo.replacingOccurrences(of: "/", with: "-")
        switch self {
        case .run(let id, _, _): return ".markview-github-\(repo)-run-\(id)"
        case .issue(let number, _, _): return ".markview-github-\(repo)-issue-\(number)"
        case .pullRequest(let number, _, _): return ".markview-github-\(repo)-pr-\(number)"
        }
    }
}

/// Represents an open tab with its associated file and state
struct OpenTab: Identifiable {
    let id = UUID()
    /// Where the tab's file is; changes when the file is moved in the file tree.
    var url: URL
    var content: String
    var originalContent: String // snapshot from disk — used to detect real changes
    var isModified: Bool = false
    var kind: TabKind = .file
    var headings: [HeadingItem] = []
    var activeHeadingId: String?
    var scrollPosition: CGFloat = 0
    /// A text file shown with line-aligned Explain notes instead of its dedicated viewer.
    var notesView = false
    /// Bumped when a data tab's file changes on disk: its viewer reads it again (a log follows).
    var dataRevision = 0

    // Semantic block extraction (DDE Stage 1)
    var blocks: [SemanticBlock] = []
    var activeBlockId: String?
    var blockCompilationState: [String: BlockCompilationState] = [:]

    /// The display name for the tab (file name)
    var displayName: String {
        if case .terminal = kind { return "Terminal: " + url.deletingLastPathComponent().lastPathComponent }
        if case .deployments = kind { return "Deployments" }
        if case .discussions = kind { return "Discussions" }
        if case .github(let item) = kind { return item.title }
        // The page title lives on the main actor; the tab bar shows it with `BrowserTabTitle`.
        if case .browser = kind { return "Browser" }
        if case .prototype(let session) = kind { return "Prototype: " + session.slug }
        if case .architecture(let scope) = kind {
            if scope == TabKind.pullRequestScope { return "PR X-Ray" }
            return scope.isEmpty ? "X-Ray" : "X-Ray: " + (scope as NSString).lastPathComponent
        }
        return url.lastPathComponent
    }

    /// True for tabs backed by a file on disk. Insight and Architecture tabs use a
    /// placeholder URL that must never be read, written or indexed.
    var isFileBacked: Bool {
        if case .file = kind { return true }
        return false
    }

    /// The file type of this tab
    var fileType: FileType {
        FileType.from(url: url)
    }

    /// Check if this tab is for a markdown file
    var isMarkdown: Bool {
        fileType == .markdown
    }
}
