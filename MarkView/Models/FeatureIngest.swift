import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Bringing material into a feature (spec §9–10): files, PDFs, images, URLs, GitHub issues,
/// pasted text and voice notes become sources (references/SRC-…); the AI names their role and
/// extracts candidate facts, which the user accepts or rejects before they count.
extension FeatureAssistant {
    enum SourceOrigin {
        case file(URL)
        case url(URL)
        case gitHubIssue(Int)
        case text(title: String, text: String, kind: String)
        case voice(text: String)
    }

    /// Add a source and extract its facts. Returns the source id.
    @discardableResult
    func ingest(_ origin: SourceOrigin, into slug: String) async -> String? {
        guard store.feature(slug) != nil else { return nil }
        var title = ""
        var originText = ""
        var content = ""
        do {
            switch origin {
            case .file(let url):
                title = url.lastPathComponent
                originText = "file"
                content = await Self.readableText(of: url)
            case .url(let url):
                title = url.host.map { "\($0)\(url.path)" } ?? url.absoluteString
                originText = url.absoluteString
                content = try await Self.fetchText(url)
            case .gitHubIssue(let number):
                guard let client = gitHubClient() else {
                    throw GitHubError(message: "Turn on the GitHub integration to import issues.")
                }
                let issue = try await client.issue(number)
                title = "#\(number) \(issue.title)"
                originText = issue.url
                content = "# \(issue.title)\n\n\(issue.body ?? "")\n\n"
                    + (issue.comments ?? []).map { "**\($0.author?.login ?? "someone")**: \($0.body)" }.joined(separator: "\n\n")
            case .text(let t, let text, let kind):
                title = t.isEmpty ? kind.capitalized : t
                originText = kind
                content = text
            case .voice(let text):
                title = "Voice note"
                originText = "voice"
                content = text
            }
        } catch {
            self.error = "Could not add the source: \(error.localizedDescription)"
            return nil
        }
        var body = "## Origin\n\n\(originText)\n"
        if case .file = origin {} else { body += "\n## Content\n\n\(content.prefix(60_000))\n" }
        // The object first (it reserves the id), then the file copied under that id.
        guard let source = store.create(.source, in: slug, title: title,
                                        fields: [("origin", .string(originText)), ("file", .string("")),
                                                 ("role", .string("")), ("facts", .list([]))],
                                        body: body, provenance: Self.provenance(origin)) else { return nil }
        if case .file(let url) = origin {
            let copy = source.url.deletingLastPathComponent().appendingPathComponent("\(source.id)-\(url.lastPathComponent)")
            let copied = await Task.detached { (try? FileManager.default.copyItem(at: url, to: copy)) != nil }.value
            if copied {
                store.update(source.id, in: slug) { front, body in
                    front.set("file", copy.lastPathComponent)
                    body += "\nFile: [\(copy.lastPathComponent)](\(copy.lastPathComponent))\n"
                }
            }
        }
        await extractFacts(slug, source: source.id, content: content)
        return source.id
    }

    private static func provenance(_ origin: SourceOrigin) -> String {
        switch origin {
        case .file(let url): return url.pathExtension.lowercased() == "pdf" ? "Extracted from PDF" : "Imported file"
        case .url: return "Imported from URL"
        case .gitHubIssue: return "Imported from GitHub"
        case .text(_, _, let kind): return "Pasted \(kind)"
        case .voice: return "Transcribed voice note"
        }
    }

    /// Role of a source and the facts it states, as candidates (spec §10).
    func extractFacts(_ slug: String, source id: String, content: String) async {
        guard let feature = store.feature(slug), let source = feature.object(id) else { return }
        let file = source.front.string("file")
        let fileNote = file.isEmpty ? "" : "\nThe source file is at \(store.relativePath(source.url.deletingLastPathComponent().appendingPathComponent(file))) — read it when its text below is empty or partial (images: look at them)."
        let prompt = context(feature, query: String(content.prefix(300))) + """

        ## New source \(id): \(source.title)\(fileNote)

        \(content.prefix(50_000))

        Task: decide the role this source plays for the feature, summarise it in 2–3 sentences, and extract \
        the facts relevant to the feature as candidates (not yet requirements). Mark each fact "stated" when \
        the source says it explicitly, "likely" when it is only implied.
        """
        let factSchema: [String: Any] = ["type": "object",
                                         "properties": ["text": ["type": "string"], "certainty": ["type": "string", "enum": ["stated", "likely"]]],
                                         "required": ["text", "certainty"]]
        let schema: [String: Any] = ["type": "object",
                                     "properties": ["role": ["type": "string", "enum": FeatureVocabulary.sourceRoles],
                                                    "summary": ["type": "string"],
                                                    "facts": ["type": "array", "items": factSchema]],
                                     "required": ["role", "summary", "facts"]]
        guard let object = await structured("ingest:" + id, prompt: prompt, schema: schema) else { return }
        let facts = (object["facts"] as? [[String: Any]] ?? []).map { f -> YAMLValue in
            .map([("text", .string(f["text"] as? String ?? "")), ("certainty", .string(f["certainty"] as? String ?? "likely")),
                  ("status", .string("pending"))])
        }
        store.update(id, in: slug) { front, body in
            front.set("role", object["role"] as? String ?? "")
            front["facts"] = .list(facts)
            body = "## Summary\n\n\(object["summary"] as? String ?? "")\n\n" + body
        }
    }

    /// Accept, reject or edit one extracted fact.
    func setFact(_ slug: String, source id: String, index: Int, status: String, text: String? = nil) {
        store.update(id, in: slug) { front, _ in
            var facts = front["facts"]?.list ?? []
            guard facts.indices.contains(index) else { return }
            var entries = facts[index].entries
            if let i = entries.firstIndex(where: { $0.key == "status" }) { entries[i].value = .string(status) } else { entries.append(("status", .string(status))) }
            if let text, let i = entries.firstIndex(where: { $0.key == "text" }) { entries[i].value = .string(text) }
            facts[index] = .map(entries)
            front["facts"] = .list(facts)
        }
    }

    // MARK: Reading sources

    /// Text of a file: Markdown/text/code as is, PDFs through PDFKit, audio through Whisper,
    /// images left for the assistant to look at.
    nonisolated static func readableText(of url: URL) async -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return "" }
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .audio) {
                return await MainActor.run { WhisperClient() }.transcribe(fileURL: url) ?? ""
            }
            if type.conforms(to: .image) { return "" }
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A web page as plain text (scripts, styles and tags removed).
    nonisolated static func fetchText(_ url: URL) async throws -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw GitHubError(message: "Only web addresses can be added.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 MarkView", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GitHubError(message: "The page answered \(http.statusCode).")
        }
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        var text = html
        for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?is)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
