import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Behaviour of the shipping `DocumentTranslator` (`AR-14` step 1) on the real `TabsController`, the real `MarkdownDocumentChunker` and the
/// real `AIOperation`: the assistant is a script that answers each section. Nothing here starts a CLI, shows a dialog or a window.
private enum DocumentTranslatorChecks {
    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }

    /// An open project that is only a folder: no database, no linked folders.


    /// The assistant of a check: what each call receives, and what it answers.
    @MainActor
    final class Assistant {
        /// The text of every section the translator sent, in order.
        var sent: [String] = []
        var systemPrompts: [String] = []
        /// The most calls that were with the assistant at once.
        var peak = 0
        private var running = 0
        /// What to answer for the section received; throws to fail the call.
        var answer: (_ text: String, _ call: Int) async throws -> String = { text, _ in Assistant.translate(text) }

        /// A "translation" that keeps the Markdown skeleton: the words in capitals.
        static func translate(_ text: String) -> String { text.uppercased() }

        func run(_ request: CLICompletion.Request,
                 _ onDelta: (@Sendable (String) -> Void)?,
                 _ onActivity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
            sent.append(request.prompt)
            systemPrompts.append(request.systemPrompt ?? "")
            running += 1
            peak = max(peak, running)
            defer { running -= 1 }
            let reply = try await answer(request.prompt, sent.count)
            return try CLICompletion.Result(text: reply, structured: nil, inputTokens: 1, outputTokens: 1, costUSD: nil)
        }
    }

    struct Failure: LocalizedError { var errorDescription: String? { "model offline" } }

    /// One window's worth of objects around a translator.
    @MainActor
    struct Window {
        let folder: URL
        let tabs: TabsController
        let tasks = TaskBag()
        let assistant = Assistant()
        let translator: DocumentTranslator

        init(folder: URL, toolAvailable: Bool = true) {
            self.folder = folder
            let tabs = TabsController(prompts: NoPrompts())
            self.tabs = tabs
            let assistant = self.assistant
            translator = DocumentTranslator(tabs: tabs, project: StubProject(root: folder, aiProjectTracksRoot: true), tasks: tasks,
                                            toolAvailable: { _ in toolAvailable }, runner: { request, onDelta, onActivity in try await assistant.run(request, onDelta, onActivity) })
        }

        /// Opens `text` as a document of the folder and makes it the shown tab.
        func open(_ text: String, named name: String = "guide.md") async throws -> URL {
            let file = folder.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            await tabs.openTextFile(file)
            return file
        }

        var translatedTab: OpenTab? { tabs.openTabs.last }
    }

    @MainActor
    static func folder(_ body: (URL) async throws -> Void) async rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doc-translator-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    /// A paragraph of about `size` characters that starts with `title`: two of them do not fit one 4000-character chunk, so each is a
    /// section of its own.
    static func section(_ title: String, size: Int = 2500) -> String {
        let line = "\(title) section words that need a translation. "
        return String(repeating: line, count: max(1, size / line.count)).trimmingCharacters(in: .whitespaces) + "\n\n"
    }

    static func run() async {
        await nothingToTranslate()
        await missingCLI()
        await translatesIntoANewTab()
        await structureMismatchRetriesStrictly()
        await failedSectionKeepsTheSource()
        await closingTheWindowStopsTheJob()
        await twoDocumentsTranslateTogether()

    }

    @MainActor
    static func nothingToTranslate() async {
        await folder { dir in
            let window = Window(folder: dir)
            _ = try? await window.open("# Title\n")
            let tabsBefore = window.tabs.openTabs.count
            let message = await window.translator.translate(markdown: "  \n\n ", targetLang: "German")
            check(message == "Nothing to translate — the document is empty.", "an empty document is reported, got \(message ?? "nil")")
            check(window.tabs.openTabs.count == tabsBefore, "an empty document opens no tab")
            check(window.assistant.sent.isEmpty, "an empty document asks nobody")
        }
    }

    @MainActor
    static func missingCLI() async {
        await folder { dir in
            let window = Window(folder: dir, toolAvailable: false)
            _ = try? await window.open("# Title\n\nText.\n")
            let tabsBefore = window.tabs.openTabs.count
            let message = await window.translator.translate(markdown: "# Title\n\nText.\n", targetLang: "German")
            check(message?.hasSuffix("was not found. Set its path in DDE Settings → AI CLI Tools.") == true, "a missing CLI is reported up front, got \(message ?? "nil")")
            check(window.tabs.openTabs.count == tabsBefore, "a missing CLI opens no tab")
            check(window.translator.progress == nil, "a missing CLI leaves no progress line")
        }
    }

    @MainActor
    static func translatesIntoANewTab() async {
        await folder { dir in
            let window = Window(folder: dir)
            let body = "---\ntitle: Guide\n---\n" + section("First") + "```swift\nlet untouched = 1\n```\n\n" + section("Second") + section("Third")
            guard let source = try? await window.open(body) else { return check(false, "fixture written") }
            let sourceText = window.tabs.activeTab?.content
            var lines: [String] = []
            var banners: [String] = []
            var whileThirdWaited = ""
            let translator = window.translator, tabs = window.tabs, assistant = window.assistant
            window.assistant.answer = { text, call in
                lines.append(translator.progress ?? "none")
                banners.append(tabs.openTabs.last?.content.components(separatedBy: "\n").first ?? "")
                // No section answers before all three are with the assistant: sent one after the other, they would wait in vain.
                var together = 0
                while assistant.sent.count < 3, together < 400 { try await Task.sleep(nanoseconds: 10_000_000); together += 1 }
                // The third answers once the other two are in the tab.
                if text.hasPrefix("Third") {
                    var waited = 0
                    while !(tabs.openTabs.last?.content.contains("2/3 sections") ?? false), waited < 400 {
                        try await Task.sleep(nanoseconds: 10_000_000); waited += 1
                    }
                    whileThirdWaited = tabs.openTabs.last?.content ?? ""
                }
                return Assistant.translate(text)
            }

            let message = await window.translator.translate(markdown: body, targetLang: "German")
            check(message == nil, "a translation that completes returns nothing to show, got \(message ?? "nil")")

            let tab = window.translatedTab
            check(tab?.url == dir.appendingPathComponent("guide_german.md"), "the new tab sits next to the source, named after the language")
            check(tab?.isModified == true, "the translated tab is left unsaved")
            check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("guide_german.md").path), "nothing is written to disk")
            check(window.tabs.openTabs.first?.url == source && window.tabs.openTabs.first?.content == sourceText, "the source tab is untouched")
            check(window.tabs.activeTab?.url == tab?.url, "the translated tab is shown")

            let content = tab?.content ?? ""
            check(content.hasPrefix("---\ntitle: Guide\n---\n"), "front matter comes first, verbatim")
            check(content.contains("```swift\nlet untouched = 1\n```"), "fenced code stays as it was")
            check(window.assistant.sent.allSatisfy { !$0.contains("let untouched") && !$0.contains("title: Guide") },
                  "code and front matter are never sent to the assistant")
            let places = ["FIRST SECTION", "SECOND SECTION", "THIRD SECTION"].compactMap { content.range(of: $0)?.lowerBound }
            check(places.count == 3 && places == places.sorted(), "every translatable section is replaced by its translation, in order")
            check(window.assistant.peak == 3 && CLICompletion.sideBySide >= 3,
                  "the three sections are with the assistant at the same time, got \(window.assistant.peak)")
            check(whileThirdWaited.contains("FIRST SECTION") && whileThirdWaited.contains("SECOND SECTION")
                  && whileThirdWaited.contains("Third section words") && whileThirdWaited.contains("```swift\nlet untouched = 1\n```"),
                  "while a section is out, the tab shows the whole document: the finished sections translated, the rest as it was")
            check(!content.contains("Translating to") && !content.contains("Translation incomplete"), "a finished translation carries no banner")

            check(lines.count == 3 && lines.allSatisfy { $0.hasPrefix("Translating 0/3") }, "the file tree line counts the finished sections: \(lines)")
            check(banners.count == 3 && banners[0].contains("Translating to German") && banners[0].contains("0/3"), "the tab shows the banner while it works: \(banners.first ?? "")")
            check(whileThirdWaited.hasPrefix("> 🌐 **Translating to German**") && whileThirdWaited.contains("2/3 sections"), "the banner advances")
            check(window.translator.progress == nil, "the progress line is gone when the job ends")
            check(window.tasks.activeCount == 0, "the finished job leaves nothing in the task bag")
        }
    }

    @MainActor
    static func structureMismatchRetriesStrictly() async {
        await folder { dir in
            let window = Window(folder: dir)
            let body = "# Plan\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nClosing words.\n"
            _ = try? await window.open(body)
            window.assistant.answer = { text, call in
                // The first answer reflows the table into prose; the strict retry keeps its rows.
                call == 1 ? "Plan\n\na and b, 1 and 2.\n\nClosing words." : "# Plan DE\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nClosing words DE."
            }
            let message = await window.translator.translate(markdown: body, targetLang: "German")
            check(message == nil, "a retried section is not reported")
            check(window.assistant.sent.count == 2, "a changed skeleton is asked again once, got \(window.assistant.sent.count) calls")
            check(window.assistant.systemPrompts.first?.contains("IMPORTANT: your previous attempt changed the structure") == false, "the first request is not strict")
            check(window.assistant.systemPrompts.last?.contains("IMPORTANT: your previous attempt changed the structure") == true, "the retry asks for the layout line by line")
            let content = window.translatedTab?.content ?? ""
            check(content.contains("# Plan DE") && content.contains("| 1 | 2 |"), "the retried answer is the one used")
            check(!content.contains("Translation incomplete"), "a mended section is not flagged")
        }
    }

    @MainActor
    static func failedSectionKeepsTheSource() async {
        await folder { dir in
            let window = Window(folder: dir)
            let body = section("First") + section("Second") + section("Third")
            _ = try? await window.open(body)
            window.assistant.answer = { text, call in
                if text.hasPrefix("Second") { throw Failure() }
                return Assistant.translate(text)
            }
            let message = await window.translator.translate(markdown: body, targetLang: "German")
            check(message == nil, "a failed section does not fail the translation")
            let content = window.translatedTab?.content ?? ""
            check(content.hasPrefix("> ⚠️ Translation incomplete — section(s) 2 kept in the original language (model offline)."),
                  "the document says which section stayed, and why: \(content.prefix(120))")
            check(content.contains("Second section words") && !content.contains("SECOND"), "the failed section keeps its source text")
            check(content.contains("FIRST SECTION WORDS") && content.contains("THIRD SECTION WORDS"), "the other sections are translated")
        }
    }

    @MainActor
    static func closingTheWindowStopsTheJob() async {
        await folder { dir in
            let window = Window(folder: dir)
            let body = section("First") + section("Second") + section("Third") + section("Fourth") + section("Fifth")
            _ = try? await window.open(body)
            // No section answers by itself: the window closes while the first three wait.
            window.assistant.answer = { text, call in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Assistant.translate(text)
            }
            let job = Task { await window.translator.translate(markdown: body, targetLang: "German") }
            var waited = 0
            while window.assistant.sent.count < 3 && waited < 400 { try? await Task.sleep(nanoseconds: 25_000_000); waited += 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            check(window.assistant.sent.count == 3, "three sections are with the assistant at once, got \(window.assistant.sent.count)")
            check(window.translator.progress?.hasPrefix("Translating 0/5") == true, "the file tree line shows the job while it runs")
            check(window.tasks.activeCount == 1, "the running job is a task of the window's bag")

            window.tasks.cancelAll()      // what closing the window or the folder does
            let message = await job.value
            check(message == "The translation was stopped before it finished.", "a stopped translation says so, got \(message ?? "nil")")
            check(window.assistant.sent.count == 3, "the sections after the stop are never sent, got \(window.assistant.sent.count)")
            let content = window.translatedTab?.content ?? ""
            check(content.hasPrefix("> ⚠️ Translation incomplete — section(s) 1, 2, 3, 4, 5 kept in the original language (the translation was stopped)."),
                  "the tab says what was left: \(content.prefix(140))")
            check(content.contains("First section words") && content.contains("Fifth section words"), "the sections that were not translated keep their text")
            check(window.translator.progress == nil, "a stopped job leaves no progress line")
        }
    }

    @MainActor
    static func twoDocumentsTranslateTogether() async {
        await folder { dir in
            let window = Window(folder: dir)
            let first = section("Alpha"), second = section("Beta")
            _ = try? await window.open(first, named: "a.md")
            var release: CheckedContinuation<Void, Never>?
            window.assistant.answer = { text, call in
                if text.hasPrefix("Alpha") { await withCheckedContinuation { release = $0 } }
                return Assistant.translate(text)
            }
            let one = Task { await window.translator.translate(markdown: first, targetLang: "French") }
            var waited = 0
            while release == nil && waited < 400 { try? await Task.sleep(nanoseconds: 25_000_000); waited += 1 }
            _ = try? await window.open(second, named: "b.md")
            let other = await window.translator.translate(markdown: second, targetLang: "French")
            check(other == nil, "a second translation completes while the first waits")
            check(window.tasks.activeCount == 1, "the second job did not replace or stop the first")
            check(window.translator.progress?.hasPrefix("Translating 0/1") == true, "the first job still shows its line")
            release?.resume()
            _ = await one.value
            let names = window.tabs.openTabs.map { $0.url.lastPathComponent }
            check(names.contains("a_french.md") && names.contains("b_french.md"), "both documents got their translated tab: \(names)")
            check(window.translator.progress == nil && window.tasks.activeCount == 0, "both jobs ended cleanly")
        }
    }
}

extension EditorHostTests {
    func testDocumentTranslatorLifecycle() async { await DocumentTranslatorChecks.run() }
}
