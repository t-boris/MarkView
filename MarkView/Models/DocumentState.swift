import Foundation
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

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Extensions with a dedicated viewer (markdown, structured data, canvas).
    static let supportedExtensions: Set<String> = markdownExtensions.union([
        "json",
        "xml", "plist", "xsd", "xsl", "xslt", "svg",
        "yml", "yaml",
        "canvas"
    ])

    /// Whether the app can open `url` — a dedicated viewer or the code viewer.
    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) || codeLanguage(for: url) != nil
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
        default: return codeLanguage(for: url) != nil ? .code : .markdown
        }
    }

    /// CodeMirror language id for a source file ("" = plain text), or nil when the
    /// file is not code. Ids match `languages` in tools/web-vendor/codemirror-entry.js.
    static func codeLanguage(for url: URL) -> String? {
        if let byName = codeFileNames[url.lastPathComponent] { return byName }
        return codeExtensions[url.pathExtension.lowercased()]
    }

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
        add("", "txt", "log", "csv", "tsv", "graphql", "gql", "tf", "hcl", "lock", "gitignore")
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

    /// Scope of the PR X-Ray tab: the project's X-Ray seen through one change.
    static let pullRequestScope = "#pr"
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
    /// A markdown document shown like code, with the Explain margin notes.
    var notesView = false

    // Semantic block extraction (DDE Stage 1)
    var blocks: [SemanticBlock] = []
    var activeBlockId: String?
    var blockCompilationState: [String: BlockCompilationState] = [:]

    /// The display name for the tab (file name)
    var displayName: String {
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
