import AppKit
import Foundation
import MarkViewCore
import PDFKit
import XCTest
@testable import MarkView

/// Real-provider checks; excluded from the automatic suite and gated by explicit manual opt-in.
@MainActor
final class ManualProviderLiveHostTests: XCTestCase {
    func testManualBookPDF() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MARKVIEW_MANUAL_BOOK_PDF"] == "1" else { throw XCTSkip("Manual Book PDF is not enabled.") }
        let provider = try XCTUnwrap(CLITool(rawValue: try XCTUnwrap(env["MARKVIEW_MANUAL_BOOK_PROVIDER"])))
        let root = URL(fileURLWithPath: try XCTUnwrap(env["MARKVIEW_MANUAL_BOOK_ROOT"]), isDirectory: true)
        let entry = URL(fileURLWithPath: try XCTUnwrap(env["MARKVIEW_MANUAL_BOOK_ENTRY"]))
        let variant = try XCTUnwrap(env["MARKVIEW_MANUAL_BOOK_VARIANT"])
        AIAssistantRunner.setTestRunner { request, delta, activity in
            try await CLICompletion.run(request, onDelta: delta, onActivity: activity)
        }
        defer { AIAssistantRunner.setTestRunner(nil) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
            if variant != "both", variant != name { continue }
            var options = BookPDFOptions(); options.title = "Publishing"; options.language = language; options.reduction = reduction
            let renderer = try BookPDFRenderer(entry: entry)
            let prepared = try await renderer.prepare(chapters, options: options)
            let originalWords = try await renderer.proseWords()
            for chapter in prepared.html {
                try await BookPDFAssistant.rewriteChapter(renderer: renderer, id: chapter.id, html: chapter.text, language: language, reduction: reduction,
                    project: nil, tool: provider, slots: SideBySide.Slots(limit: CLICompletion.sideBySide))
            }
            let words = try await renderer.proseWords()
            let ratio = Double(words) / Double(originalWords)
            let result = try await renderer.render(options: options, labels: ["contents":name == "russian" ? "Оглавление" : "Contents", "book":"BOOK", "edition":"Edition"]) { _, _ in }
            let pdf = try XCTUnwrap(PDFDocument(data: result.data))
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            try result.data.write(to: root.appendingPathComponent(name + ".pdf"))
            FileHandle.standardOutput.write(Data("\(provider.rawValue) \(name): \(originalWords) → \(words) prose words, ratio \(ratio).\n".utf8))
            XCTAssertTrue(text.contains("42") && text.contains("27") && text.contains("This code must not be translated"))
            if name == "russian" { XCTAssertGreaterThan(text.filter { ("а"..."я").contains(String($0).lowercased()) }.count, 200, "The book must actually be translated.") }
            else { XCTAssertTrue((0.30...0.80).contains(ratio), "A 50% reduction should meaningfully shorten prose, measured independently of font size.") }
            print("\(provider.rawValue) \(name): protected links/table/code, \(originalWords) → \(words) prose words, \(result.pages) pages passed.")
        }
        let after = try String(contentsOf: path, encoding: .utf8); XCTAssertEqual(after, source)
        print("Live book artifacts: \(root.path)")
    }

    func testManualCopilot() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MARKVIEW_MANUAL_COPILOT"] == "1" else { throw XCTSkip("Manual Copilot is not enabled.") }
        let binary = try XCTUnwrap(env["MARKVIEW_MANUAL_COPILOT_BINARY"])
        let copilot = try XCTUnwrap(CLITool(rawValue: "copilot"))
        let key = Setting.cliPath(copilot.rawValue)
        let previous = Settings.standard.stored(key)
        Settings.standard.set(binary, for: key)
        defer { Settings.standard.set(previous, for: key) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-copilot-live-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var request = CLICompletion.Request(project: root, prompt: "Answer with exactly {\"ok\":true}. Do not use tools.")
        request.tool = copilot
        request.timeout = nil
        request.jsonSchema = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
        let liveRequest = request
        let result = try await withThrowingTaskGroup(of: CLICompletion.Result.self) { group in
            group.addTask { try await CLICompletion.run(liveRequest) }
            group.addTask {
                try await Task.sleep(nanoseconds: 90_000_000_000)
                throw CLICompletion.Failure.failed(copilot, "Live test did not finish in 90 seconds.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        XCTAssertEqual((result.structured as? [String: Any])?["ok"] as? Bool, true)
        print("Real Copilot ACP: structured request without a MarkView wall-clock limit passed.")
    }
}
