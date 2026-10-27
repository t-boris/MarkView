import AppKit
import PDFKit

// App services outside this opt-in CLI/renderer integration check.
enum ACPAssistant {
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] { [] }
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result { fatalError("Select Claude or Codex for this check.") }
}
final class SemanticDatabase {
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {}
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String { fileURL.path.replacingOccurrences(of: root.path + "/", with: "") }
}

@main
enum BookPDFLiveChecks {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) } catch { print("Live book check failed: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        guard let provider = CLITool(rawValue: CommandLine.arguments[3]) else { fatalError("Unknown provider") }
        let root = URL(fileURLWithPath: CommandLine.arguments[2]); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = """
        # Reliable publishing

        ## Readable books

        A good book gives readers a clear route through the material. Its contents page lists chapters in reading order and gives the actual page number for each destination. Clicking a contents entry takes the reader to that chapter. Consistent headings also make the document easier to scan when a reader returns to it later.

        A reliable export preserves every original paragraph unless the reader explicitly requests a shorter edition. It also preserves links, photographs, tables and code samples. When the export translates the prose, the facts must stay the same. The team has 42 members and retains records for 27 days. These numbers are contractual requirements and cannot change.

        ## Careful production

        Tables need repeated column headings when they span several pages. A long cell needs to continue naturally onto the following page. A large picture must fit inside the page margins with its aspect ratio intact. Headers and footers provide context without competing with the text, and page numbers help readers orient themselves in the printed edition.

        Source documents remain unchanged throughout the export. A finished book is a separate PDF, saved only when rendering has succeeded. If the user stops the operation, unfinished output should not replace an existing document. A clear progress message should name the current chapter or rendering stage so the reader knows what is happening.

        See [publishing reference](https://example.com/publishing).

        | Requirement | Value |
        | --- | --- |
        | Team members | 42 |
        | Retention days | 27 |

        ```python
        untouched = "This code must not be translated"
        print(untouched)
        ```
        """
        let path = root.appendingPathComponent("source.md"); try source.write(to: path, atomically: true, encoding: .utf8)
        let chapters = try BookPDFSource.collect([path]).chapters
        for (name, language, reduction) in [("russian", "Russian", 0), ("short", "document", 50)] {
            if CommandLine.arguments.count > 4, CommandLine.arguments[4] != "both", CommandLine.arguments[4] != name { continue }
            var options = BookPDFOptions(); options.title = "Publishing"; options.language = language; options.reduction = reduction
            let renderer = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
            let prepared = try await renderer.prepare(chapters, options: options)
            let originalWords = try await renderer.proseWords()
            for chapter in prepared.html {
                try await BookPDFAssistant.rewriteChapter(renderer: renderer, id: chapter.id, html: chapter.text, language: language, reduction: reduction,
                    project: nil, tool: provider)
            }
            let words = try await renderer.proseWords()
            let ratio = Double(words) / Double(originalWords)
            let result = try await renderer.render(options: options, labels: ["contents":name == "russian" ? "Оглавление" : "Contents", "book":"BOOK", "edition":"Edition"]) { _, _ in }
            let pdf = PDFDocument(data: result.data)!
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            try result.data.write(to: root.appendingPathComponent(name + ".pdf"))
            FileHandle.standardOutput.write(Data("\(provider.rawValue) \(name): \(originalWords) → \(words) prose words, ratio \(ratio).\n".utf8))
            precondition(text.contains("42") && text.contains("27") && text.contains("This code must not be translated"))
            if name == "russian" { precondition(text.filter { ("а"..."я").contains(String($0).lowercased()) }.count > 200, "The book must actually be translated.") }
            else { precondition((0.30...0.80).contains(ratio), "A 50% reduction should meaningfully shorten prose, measured independently of font size.") }
            print("\(provider.rawValue) \(name): protected links/table/code, \(originalWords) → \(words) prose words, \(result.pages) pages passed.")
        }
        let after = try String(contentsOf: path, encoding: .utf8); precondition(after == source)
        print("Live book artifacts: \(root.path)")
    }
}
