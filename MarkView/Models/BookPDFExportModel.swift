import AppKit
import Combine
import UniformTypeIdentifiers
import NaturalLanguage

@MainActor
final class BookPDFExportModel: ObservableObject {
    @Published var chapters: [BookPDFChapter] = []
    @Published var options = BookPDFOptions()
    @Published var customLanguage = ""
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Choose files or folders for your book."
    @Published private(set) var progress = 0.0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    private var task: Task<Void, Never>?
    private var renderer: BookPDFRenderer?
    private let project: URL?
    private let drafts: [String: String]
    private let database: SemanticDatabase?

    init(project: URL?, drafts: [String: String], database: SemanticDatabase?) {
        self.project = project; self.drafts = drafts; self.database = database
    }

    func chooseSources() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.prompt = "Add to Book"
        panel.begin { [weak self] response in if response == .OK { self?.add(panel.urls) } }
    }

    func add(_ urls: [URL]) {
        guard !isBusy, !urls.isEmpty else { return }
        isBusy = true; error = nil; savedURL = nil; status = "Reading selected files and folders…"
        let drafts = drafts
        task = Task {
            defer { isBusy = false; task = nil }
            do {
                let reading = Task.detached { try BookPDFSource.collect(urls, drafts: drafts) }
                let collection = try await withTaskCancellationHandler { try await reading.value } onCancel: { reading.cancel() }
                try Task.checkCancellation()
                var known = Set(chapters.map { $0.url.resolvingSymlinksInPath().path })
                for var chapter in collection.chapters where known.insert(chapter.url.resolvingSymlinksInPath().path).inserted {
                    chapter.id = "c" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    chapters.append(chapter)
                }
                warnings += collection.skipped.map { "Skipped unsupported file or symbolic link: " + $0 }
                if options.title.isEmpty { options.title = chapters.count == 1 ? chapters[0].title : project?.lastPathComponent ?? "Collected writings" }
                status = chapters.isEmpty ? "No supported documents in this selection." : "\(chapters.count) chapters ready. Arrange them in reading order."
            } catch { self.error = Task.isCancelled ? nil : error.localizedDescription; status = Task.isCancelled ? "Stopped reading sources." : "Could not read the selection." }
        }
    }

    func move(_ id: String, by offset: Int) {
        guard !isBusy, let i = chapters.firstIndex(where: { $0.id == id }), chapters.indices.contains(i + offset) else { return }
        chapters.swapAt(i, i + offset); savedURL = nil
    }
    func remove(_ id: String) { guard !isBusy else { return }; chapters.removeAll { $0.id == id }; savedURL = nil }

    func export() {
        guard !isBusy, !chapters.isEmpty, !options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = options.title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.export(to: url) } }
    }

    func export(to url: URL) {
        guard !isBusy else { return }
        let chapters = chapters
        var options = options
        if options.language == "custom" {
            options.language = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !options.language.isEmpty else { error = "Enter a language name."; return }
        }
        isBusy = true; error = nil; savedURL = nil; progress = 0; status = "Preparing chapters and illustrations…"
        task = Task {
            defer { isBusy = false; renderer = nil; task = nil }
            do {
                let renderer = try BookPDFRenderer(); self.renderer = renderer
                let prepared = try await renderer.prepare(chapters, options: options)
                let originalWords = try await renderer.proseWords()
                let transformationCount = prepared.html.count
                if options.needsAI {
                    for (index, chapter) in prepared.html.enumerated() {
                        try Task.checkCancellation()
                        try await BookPDFAssistant.rewriteChapter(renderer: renderer, id: chapter.id, html: chapter.text, language: options.language,
                            reduction: options.reduction, project: project, usage: { $0.record(in: database) }) { message, fraction in
                                status = "Chapter \(index + 1) of \(transformationCount) · " + message
                                progress = 0.1 + 0.55 * (Double(index) + fraction) / Double(transformationCount)
                            }
                    }
                }
                var renderedOptions = options
                if options.language != "document" {
                    status = "Translating the book title…"
                    var request = CLICompletion.Request(project: project, prompt: options.title,
                        systemPrompt: "Translate this book title into \(options.language). Preserve proper names and identifiers. Return JSON with only the text field; do not add commentary.",
                        jsonSchema: BookPDFTransform.schema)
                    request.label = "pdf-book:cover-title"; request.effort = "low"
                    let result = try await CLICompletion.run(request); result.record(in: database)
                    guard let title = (result.structured as? [String: Any])?["text"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookPDFError.invalid("The book title could not be translated.") }
                    renderedOptions.title = title
                }
                let finalWords = try await renderer.proseWords()
                let labels = try await bookLabels(options: options, chapters: chapters)
                status = "Typesetting the cover, contents, tables and chapters…"; progress = 0.68
                let output = try await renderer.render(options: renderedOptions, labels: labels) { [weak self] page, count in
                    self?.status = "Rendering page \(page) of \(count)…"; self?.progress = 0.7 + 0.29 * Double(page) / Double(count)
                }
                try Task.checkCancellation(); status = "Saving the PDF book…"
                try await Task.detached { try output.data.write(to: url, options: .atomic) }.value
                warnings += output.warnings; savedURL = url; progress = 1
                status = "Saved \(output.pages) pages · \(ByteCountFormatter.string(fromByteCount: Int64(output.data.count), countStyle: .file))"
                if options.reduction > 0, originalWords > 0 { status += " · Prose: \(Int((Double(finalWords) / Double(originalWords) * 100).rounded()))% retained" }
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
                status = Task.isCancelled ? "Export stopped. Source documents were preserved." : "The book could not be exported."
            }
        }
    }

    func cancel() { task?.cancel(); renderer?.cancel() }

    private func bookLabels(options: BookPDFOptions, chapters: [BookPDFChapter]) async throws -> [String: String] {
        let known: [String: [String]] = [
            "en": ["Contents", "COLLECTED WRITINGS", "A reader’s edition"],
            "ru": ["Оглавление", "СОБРАНИЕ ТЕКСТОВ", "Книжное издание"],
            "uk": ["Зміст", "ЗІБРАННЯ ТЕКСТІВ", "Книжкове видання"],
            "de": ["Inhalt", "GESAMMELTE TEXTE", "Eine Leseausgabe"],
            "fr": ["Table des matières", "RECUEIL DE TEXTES", "Édition de lecture"],
            "es": ["Contenido", "TEXTOS REUNIDOS", "Edición de lectura"],
            "he": ["תוכן עניינים", "אסופת כתבים", "מהדורת קריאה"],
            "zh-Hans": ["目录", "文集", "阅读版"]
        ]
        let names = ["English":"en", "Russian":"ru", "Ukrainian":"uk", "German":"de", "French":"fr", "Spanish":"es", "Hebrew":"he", "Chinese (Simplified)":"zh-Hans"]
        let language: String
        if options.language == "document" {
            language = NLLanguageRecognizer.dominantLanguage(for: String(chapters.map(\.text).joined(separator: "\n").prefix(4000)))?.rawValue ?? "en"
        } else { language = names[options.language] ?? options.language }
        if let labels = known[language] { return ["contents":labels[0], "book":labels[1], "edition":labels[2]] }
        if options.language == "document" { return ["contents":"Contents", "book":"COLLECTED WRITINGS", "edition":"A reader’s edition"] }
        let schema: [String: Any] = ["type":"object", "properties":["contents":["type":"string"], "book":["type":"string"], "edition":["type":"string"]], "required":["contents","book","edition"]]
        var request = CLICompletion.Request(project: project, prompt: "Translate these three book labels into \(options.language): contents = Contents; book = Collected writings; edition = A reader’s edition. Return JSON only.", jsonSchema: schema)
        request.label = "pdf-book:labels"; request.effort = "low"
        let result = try await CLICompletion.run(request); result.record(in: database)
        guard let labels = result.structured as? [String: String], ["contents","book","edition"].allSatisfy({ !(labels[$0] ?? "").isEmpty }) else { throw BookPDFError.invalid("Book labels could not be translated.") }
        return labels
    }
}
