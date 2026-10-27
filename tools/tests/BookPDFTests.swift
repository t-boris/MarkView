import AppKit
import PDFKit

@main
enum BookPDFTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("Book PDF check failed: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = """
        <svg xmlns="http://www.w3.org/2000/svg" width="640" height="240" viewBox="0 0 640 240">
        <rect width="640" height="240" rx="18" fill="#e0f1ec"/><circle cx="120" cy="120" r="70" fill="#21746d"/>
        <path d="M220 120H540" stroke="#21746d" stroke-width="12"/><text x="260" y="95" font-family="Arial" font-size="28" fill="#173f3a">Illustration</text></svg>
        """
        try image.write(to: root.appendingPathComponent("illustration.svg"), atomically: true, encoding: .utf8)
        let rows = (1...50).map { "| Row \($0) | \(String(repeating: "Table content stays readable. ", count: 3)) | \($0 * 17) |" }.joined(separator: "\n")
        let first = """
        # The Field Guide

        A book needs breathing room, consistent typography and a clear reading order. This opening paragraph must remain complete.

        See [the second chapter](02-chapter.md#details), [the website](https://example.com/reference), and this footnote.[^note]

        ## A real illustration

        ![A vector illustration](illustration.svg)

        ## A table over several pages

        | Item | Explanation | Value |
        | --- | --- | ---: |
        \(rows)

        ## A very long paragraph

        \(String(repeating: "All original sentences survive pagination, including inline **emphasis** and [a link](https://example.com). ", count: 90))

        ## Code and mathematics

        ```swift
        let book = "Keep code exactly as written"
        print(book)
        ```

        The formula is $E = mc^2$.

        ```mermaid
        graph LR
          Source --> Book
          Book --> Reader
        ```

        [^note]: This footnote has a working return link.

        LAST_SENTINEL_FIRST
        """
        let second = """
        # Вторая глава

        Кириллица должна читаться правильно, без квадратов и потерянных букв.

        ## Details

        [Return to the first chapter](01-guide.md#a-real-illustration).

        | Name | Long cell |
        | --- | --- |
        | Tall row | \(String(repeating: "An exceptionally tall cell must continue on following pages without losing words. ", count: 85)) |

        LAST_SENTINEL_SECOND
        """
        let a = root.appendingPathComponent("01-guide.md"), b = root.appendingPathComponent("02-chapter.md")
        try first.write(to: a, atomically: true, encoding: .utf8); try second.write(to: b, atomically: true, encoding: .utf8)
        let collection = try BookPDFSource.collect([a, b, a])
        precondition(collection.chapters.count == 2, "Selected overlaps must not duplicate chapters.")
        let draft = try BookPDFSource.collect([a], drafts: [a.path: "# Unsaved draft\n\nKeep my draft."])
        precondition(draft.chapters[0].text.contains("Keep my draft."))
        let saved = try String(contentsOf: a, encoding: .utf8)
        precondition(saved == first, "Export must not save a draft into its source.")
        let html = "<h1>Title &amp; context</h1><p>A <a href=\"#target\">link</a> and prose.</p><pre><code>x &lt; 4</code></pre><img src=\"data:image/png;base64,AAA\">"
        let protected = BookPDFTransform.prepare(html, chunkSize: 150)
        let restored = try protected.restore(protected.chunks.map(\.text))
        precondition(restored == html, "A neutral transformation must preserve exact markup/entities/code/links.")
        do { _ = try protected.restore(protected.chunks.map { $0.text + "MVBOOK_DEAD_0_END" }); preconditionFailure("Invented tokens must fail closed.") } catch {}
        precondition(BookPDFTransform.system(language: "Russian", reduction: 50).contains("50%"))
        precondition(!BookPDFOptions().needsAI, "Default export must not need an assistant or change any prose.")
        var options = BookPDFOptions(); options.title = "A Reader’s Field Guide"; options.author = "MarkView · Export verification"
        let renderer = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
        let prepared = try await renderer.prepare(collection.chapters, options: options)
        precondition(prepared.html.count == 2)
        let result = try await renderer.render(options: options, labels: ["book":"FIELD NOTES", "edition":"A complete edition", "contents":"Contents"]) { _, _ in }
        try result.data.write(to: root.appendingPathComponent("book.pdf"))
        let pdf = PDFDocument(data: result.data)!
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        precondition(pdf.pageCount > 6)
        precondition(text.contains("LAST_SENTINEL_FIRST") && text.contains("LAST_SENTINEL_SECOND"), "Both chapter endings must survive pagination.")
        precondition(text.contains("Кириллица должна читаться правильно"))
        precondition(text.components(separatedBy: "Table content stays readable.").count - 1 == 150, "Table rows must not lose or duplicate their text.")
        precondition(text.components(separatedBy: "exceptionally").count - 1 == 85 && text.components(separatedBy: "losing").count - 1 == 85,
                     "Tall cells must be split without losing or duplicating text, including sentences crossing a page boundary.")
        precondition(pdf.outlineRoot!.numberOfChildren >= 3)
        let links = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }
        precondition(links.contains { $0.action is PDFActionGoTo } && links.contains { $0.action is PDFActionURL })
        precondition(result.warnings.isEmpty, "All selected local references should resolve: \(result.warnings)")
        let folder = root.appendingPathComponent("selection", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Ten".utf8).write(to: folder.appendingPathComponent("10.txt")); try Data("Two".utf8).write(to: folder.appendingPathComponent("02.txt"))
        try Data([0,255,3]).write(to: folder.appendingPathComponent("unsupported.bin"))
        let nested = try BookPDFSource.collect([folder, folder.appendingPathComponent("02.txt")])
        precondition(nested.chapters.map(\.title) == ["02", "10"] && nested.skipped.count == 1, "Folders need natural order, overlap deduplication and explicit unsupported-file notices.")
        let extra = root.appendingPathComponent("many.html")
        let sections = (1...60).map { "<h2>Section \($0)</h2><p>Readable section \($0), retained in full.</p>" }.joined()
        try ("<article id='named'><p>HTML_INTRO <a href='#named'>named container</a></p>" + sections + "<p>HTML_LAST</p></article><script>throw Error('Source script must never execute')</script>").write(to: extra, atomically: true, encoding: .utf8)
        options.theme = "white"; options.paper = "letter"; options.title = "An extended contents page"
        let many = try BookPDFSource.collect([extra]).chapters
        let more = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
        _ = try await more.prepare(many, options: options)
        let extended = try await more.render(options: options, labels: ["book":"BOOK", "edition":"Complete edition", "contents":"Contents"]) { _, _ in }
        let extendedPDF = PDFDocument(data: extended.data)!
        precondition(extendedPDF.page(at: 2)!.string!.contains("Contents"), "A long contents list must flow across pages with working numbering.")
        precondition(extendedPDF.outlineRoot!.child(at: 1)!.numberOfChildren == 60, "Every heading must have a native PDF bookmark.")
        precondition(extendedPDF.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 612,height:792))
        precondition(extended.warnings.isEmpty, "HTML container anchors must survive pagination.")
        try extended.data.write(to: root.appendingPathComponent("extended-contents.pdf"))
        options.paper = "a4Landscape"; options.theme = "midnight"; options.title = "A wide table"
        let wide = root.appendingPathComponent("wide.md")
        try "# A wide table\n\n中文排版保持清晰。\n\n| One | Two | Three | Four | Five | Six | Seven |\n|---|---|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 | 6 | 7 |\n\nWIDE_SENTINEL\n".write(to: wide, atomically: true, encoding: .utf8)
        let landscape = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
        _ = try await landscape.prepare(BookPDFSource.collect([wide]).chapters, options: options)
        let wideResult = try await landscape.render(options: options, labels: ["book":"BOOK", "edition":"Complete", "contents":"Contents"]) { _, _ in }
        let widePDF = PDFDocument(data: wideResult.data)!
        try wideResult.data.write(to: root.appendingPathComponent("landscape.pdf"))
        precondition(widePDF.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width:842,height:595))
        let wideText = (0..<widePDF.pageCount).compactMap { widePDF.page(at:$0)?.string }.joined(separator:"\n")
        // System CJK fonts can emit compatibility radicals in PDF ToUnicode.
        let normalizedWideText = wideText.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
        precondition(wideText.contains("WIDE_SENTINEL") && normalizedWideText.contains("中文"), "Landscape pages must retain body and normalized CJK text.")
        let cancellation = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cancelled = Task { try await cancellation.prepare(many, options: options) }; cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must finish without producing a PDF.") } catch {}
        let longFile = root.appendingPathComponent("layout-cancellation.md")
        try ("# Long layout\n\n" + String(repeating: "A long book must stay cancellable while the renderer paginates its chapters.\n\n", count: 9000)).write(to: longFile, atomically: true, encoding: .utf8)
        let longRenderer = try BookPDFRenderer(entry: URL(fileURLWithPath: CommandLine.arguments[1]))
        _ = try await longRenderer.prepare(BookPDFSource.collect([longFile]).chapters, options: options)
        let job = Task { try await longRenderer.render(options: options, labels: ["book":"BOOK", "edition":"Complete", "contents":"Contents"]) { _, _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let stoppedAt = Date(); job.cancel(); longRenderer.cancel()
        do { _ = try await job.value; preconditionFailure("A cancelled layout must not return a PDF.") } catch {}
        precondition(Date().timeIntervalSince(stoppedAt) < 10, "Cancellation must yield promptly during a long layout.")
        try FileManager.default.removeItem(at: longFile)
        print("Book PDF: source/draft/deduplication, protected transformation, \(pdf.pageCount) pages, Cyrillic, complete tables, bookmarks and \(links.count) links passed.")
        print("Folder selection, long contents, Letter pages, sanitized HTML anchors and cancellation during long layout passed.")
        print("Artifact: \(root.appendingPathComponent("book.pdf").path)")
    }
}
