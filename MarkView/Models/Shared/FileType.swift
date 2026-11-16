import Foundation
import UniformTypeIdentifiers

/// Supported file types for viewing/editing
enum FileType: String {
    case markdown
    case json
    case xml
    case yaml
    case canvas
    case pdf
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
        from(url: url) != .pdf && (!isData(url) || ["csv", "tsv", "tab", "psv", "jsonl", "ndjson", "har", "log", "out"]
            .contains(url.pathExtension.lowercased()))
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
        "canvas", "pdf"
    ]).union(tableExtensions).union(parquetExtensions).union(sqliteExtensions).union(logExtensions)

    /// Whether the filename identifies a dedicated viewer or known text format.
    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) || codeLanguage(for: url) != nil
    }

    /// Whether MarkView has a viewer for the file, decided by its name and never by reading it
    /// (DEC-004 of flexible-files-views-and-visible-agent-usage): the Openable files category of Files
    /// keeps these. `isOpenable` is wider: the editor may still try any other file as text.
    static func hasViewer(_ url: URL) -> Bool {
        isSupported(url) || isImage(url) || Archive.isArchive(url) || viewerDotfiles.contains(url.lastPathComponent)
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
        case "pdf": return .pdf
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

    /// Configuration and shell dotfiles that Files treats as having a viewer (they open as text on a click, DEC-005).
    /// Kept apart from the tables above on purpose: those also tell the X-Ray scanner what is source code.
    private static let viewerDotfiles: Set<String> = [
        ".gitignore", ".gitmodules", ".gitattributes", ".mailmap", ".dockerignore", ".npmignore", ".prettierignore",
        ".eslintignore", ".prettierrc", ".eslintrc", ".babelrc", ".nvmrc", ".tool-versions", ".ruby-version",
        ".node-version", ".python-version", ".editorconfig",
        ".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile",
    ]

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
