import Foundation
import NaturalLanguage
import UniformTypeIdentifiers

/// An immutable snapshot: exporting never saves or rewrites a source document.
struct BookPDFChapter: Identifiable, Codable, Sendable {
    var id: String
    var url: URL
    var path: String
    var title: String
    var format: String
    var text: String
    var original: String
}

struct BookPDFSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum BookPDFError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum BookPDFSource {
    struct Collection: Sendable {
        var chapters: [BookPDFChapter]
        var skipped: [String]
    }
    static let maximumBytes = 12 * 1024 * 1024
    static let maximumChapters = 1000
    private static let ignored = Set([".git", ".dde", "node_modules", ".build", ".DS_Store"])
    private static let markdown = Set(["md", "markdown", "mdown", "mkd"])

    static func collect(_ urls: [URL], drafts: [String: String] = [:]) throws -> Collection {
        let canonicalDrafts = Dictionary(drafts.map { (URL(fileURLWithPath: $0.key).resolvingSymlinksInPath().path, $0.value) }, uniquingKeysWith: { _, latest in latest })
        var result = Collection(chapters: [], skipped: [])
        var seen = Set<String>()
        var total = 0
        func visit(_ input: URL, base: URL, explicit: Bool) throws {
            try Task.checkCancellation()
            var url = input.standardizedFileURL
            let initial = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if initial.isSymbolicLink == true, !explicit { result.skipped.append(url.lastPathComponent + " (symbolic link)"); return }
            if initial.isSymbolicLink == true { url = url.resolvingSymlinksInPath() }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let canonical = url.resolvingSymlinksInPath().path
            guard seen.insert(canonical).inserted else { return }
            if values.isDirectory == true {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children where !ignored.contains(child.lastPathComponent) { try visit(child, base: base, explicit: false) }
                return
            }
            guard result.chapters.count < maximumChapters else { throw BookPDFError.invalid("This selection exceeds 1,000 chapters. Choose fewer folders or files; nothing has been truncated.") }
            let ext = url.pathExtension.lowercased()
            let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) == true
            let path = url.path.hasPrefix(base.path + "/") ? String(url.path.dropFirst(base.path.count + 1)) : url.lastPathComponent
            if isImage {
                result.chapters.append(BookPDFChapter(id: "c" + String(result.chapters.count), url: url, path: path,
                    title: url.deletingPathExtension().lastPathComponent, format: "image", text: "", original: ""))
                return
            }
            guard (values.fileSize ?? 0) <= maximumBytes else {
                throw BookPDFError.invalid("\(url.lastPathComponent) exceeds the 12 MB text limit. Choose a smaller selection.")
            }
            let data = try Data(contentsOf: url)
            let text: String?
            if let draft = canonicalDrafts[canonical] { text = draft }
            else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
            else { text = data.contains(0) ? nil : String(data: data, encoding: .utf8) }
            guard let text else {
                if explicit { throw BookPDFError.invalid("\(url.lastPathComponent) is not a supported text document or image. Export Markdown, HTML, UTF-8/UTF-16 text, source code, CSV/TSV or images.") }
                result.skipped.append(path); return
            }
            total += text.utf8.count
            guard total <= maximumBytes else { throw BookPDFError.invalid("The selected text exceeds 12 MB. Choose fewer files; nothing has been truncated.") }
            let format: String
            if markdown.contains(ext) { format = "markdown" }
            else if ["html", "htm", "xhtml"].contains(ext) { format = "html" }
            else if ["csv", "tsv"].contains(ext) { format = ext }
            else if ["txt", "text", "rst", "org", "adoc", "asciidoc", "log"].contains(ext) { format = "text" }
            else { format = "code" }
            let title = markdown.contains(ext) ? markdownTitle(text) ?? url.deletingPathExtension().lastPathComponent : url.deletingPathExtension().lastPathComponent
            result.chapters.append(BookPDFChapter(id: "c" + String(result.chapters.count), url: url, path: path,
                title: title, format: format, text: text, original: text))
        }
        for url in urls { try visit(url, base: url.deletingLastPathComponent(), explicit: true) }
        return result
    }

    private static func markdownTitle(_ text: String) -> String? {
        var fence = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle() }
            if !fence, line.hasPrefix("# ") { return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}

struct BookPDFOptions: Sendable {
    var title = ""
    var author = ""
    var language = "document"
    /// 0 preserves the complete text; 50 targets half the prose, never a smaller font.
    var reduction = 0
    var theme = "paper"
    var paper = "a4"
    /// "book" prints chapters with a cover and contents; "document" prints one file as a document (title page from its front matter,
    /// contents only when it is long, running head with the section).
    var mode = "book"
    /// BCP 47 language code the dates on a title page are written in; empty uses the system language.
    var locale = ""
    var needsAI: Bool { reduction > 0 || language != "document" }
}

/// The fixed words of a printed book or document, by the language of its text. A language without a row asks the assistant (book) or uses English (document).
enum BookPDFLabels {
    struct Words { var contents, book, edition, document: String }
    static let known: [String: Words] = [
        "en": Words(contents: "Contents", book: "COLLECTED WRITINGS", edition: "A reader’s edition", document: "DOCUMENT"),
        "ru": Words(contents: "Оглавление", book: "СОБРАНИЕ ТЕКСТОВ", edition: "Книжное издание", document: "ДОКУМЕНТ"),
        "uk": Words(contents: "Зміст", book: "ЗІБРАННЯ ТЕКСТІВ", edition: "Книжкове видання", document: "ДОКУМЕНТ"),
        "de": Words(contents: "Inhalt", book: "GESAMMELTE TEXTE", edition: "Eine Leseausgabe", document: "DOKUMENT"),
        "fr": Words(contents: "Table des matières", book: "RECUEIL DE TEXTES", edition: "Édition de lecture", document: "DOCUMENT"),
        "es": Words(contents: "Contenido", book: "TEXTOS REUNIDOS", edition: "Edición de lectura", document: "DOCUMENTO"),
        "he": Words(contents: "תוכן עניינים", book: "אסופת כתבים", edition: "מהדורת קריאה", document: "מסמך"),
        "zh-Hans": Words(contents: "目录", book: "文集", edition: "阅读版", document: "文档"),
    ]
    static let languageCodes = ["English": "en", "Russian": "ru", "Ukrainian": "uk", "German": "de", "French": "fr", "Spanish": "es",
                                "Hebrew": "he", "Chinese (Simplified)": "zh-Hans"]

    /// The dominant language of `text` as a language code ("en" when it cannot be told).
    /// The language of the prose of `text`. Front matter, code blocks (diagram sources), table rows and short lines (labels, numbers,
    /// names) say little about it and in a business plan are mostly English words, so only the running text is looked at.
    static func detectedLanguage(of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = lines[(end + 1)...]
        }
        var sample = "", fenced = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || trimmed.hasPrefix("|") || trimmed.count < 25 { continue }
            sample += trimmed + " "
            if sample.count >= 20_000 { break }
        }
        if sample.isEmpty { sample = String(text.prefix(4000)) }
        return NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue ?? "en"
    }

    static func dictionary(_ words: Words) -> [String: String] {
        ["contents": words.contents, "book": words.book, "edition": words.edition, "document": words.document]
    }
}
