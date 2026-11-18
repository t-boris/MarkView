import Foundation
import AppKit
import Combine
import CoreText
import PDFKit
import SQLite3
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor
private final class RoutingAssistant: AssistantPrompting {
    var assistantIsBusy = false
    private(set) var prompts: [(text: String, submit: Bool)] = []
    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? {
        prompts.append((prompt, submit))
        return nil
    }
    func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? { nil }
}

@MainActor
private final class FeatureFlowAssistantSpy: AssistantProviding, AssistantPrompting {
    let session: TerminalSession
    var sends = true
    var assistantIsBusy = false
    private(set) var sent: [(prompt: String, submit: Bool, terminal: TerminalSession)] = []
    var currentAssistant: CLICompletion.Assistant? { nil }
    var sessions: [TerminalSession] { [session] }
    var shownID: UUID? { session.id }
    init(root: URL) { session = TerminalSession(directory: root, profile: .assistant(CLITool(rawValue: "claude")!)) }
    func liveModelReported(_ model: String, terminalID: UUID) {}
    func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession? { nil }
    func showAIConsole() {}
    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? {
        guard sends else { return nil }
        sent.append((prompt, submit, session))
        return session
    }
    func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? {
        guard sends else { return nil }
        let target = terminal ?? session
        guard let prompt = promptFor(target) else { return nil }
        sent.append((prompt, submit, target))
        return target
    }
}

@MainActor
private final class FeatureFlowTabsSpy: FeatureFlowTabs {
    var activeTab: OpenTab?
    private(set) var opened: [URL] = []
    func openFile(_ url: URL) { opened.append(url) }
    func showGitHubTab(_ item: GitHubItem, root: URL) {}
    func reloadChangedOpenFiles(all: Bool) async {}
}

private final class DiscussionRunnerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CLICompletion.Request] = []
    private var cancellations = 0
    func record(_ request: CLICompletion.Request) { lock.lock(); requests.append(request); lock.unlock() }
    func recordCancellation() { lock.lock(); cancellations += 1; lock.unlock() }
    var seen: [CLICompletion.Request] { lock.lock(); defer { lock.unlock() }; return requests }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

private actor FeatureIntakeFixture {
    enum Mode { case answer, fail, wait }
    var mode: Mode = .answer
    var requests: [CLICompletion.Request] = []
    var cancellations = 0
    func setMode(_ mode: Mode) { self.mode = mode }
    func count() -> Int { requests.count }
    func cancellationCount() -> Int { cancellations }
    func run(_ request: CLICompletion.Request, _ delta: (@Sendable (String) -> Void)?,
             _ activity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
        requests.append(request)
        switch mode {
        case .answer:
            let object: [String: Any] = ["title": "Fixture feature", "idea": "A fixture", "problem": "A problem", "scope": "A scope",
                                         "analysis": "An analysis", "assumptions": [], "acceptance_criteria": ["It works"]]
            return try CLICompletion.Result(text: "", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
        case .fail:
            throw NSError(domain: "FeatureIntakeFixture", code: 7, userInfo: [NSLocalizedDescriptionKey: "fixture failure"])
        case .wait:
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancellations += 1; throw error }
            throw CancellationError()
        }
    }
}

private struct WorkspaceRedesignFixture {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        XCTAssertTrue(condition, message, line: line)
    }

    /// The app writes the live status through the lifecycle service; the checks write it the same way (`FrontMatter.writeFile`), byte for byte.
    nonisolated static func writeReady(_ overview: URL) -> @Sendable (String) -> Bool {
        { _ in
            guard let text = try? String(contentsOf: overview, encoding: .utf8) else { return false }
            var (front, body) = FrontMatter.split(text)
            front.set("status", "ready")
            return (try? front.writeFile(body: body, to: overview)) != nil
        }
    }

    static func makeSearchPDF(at url: URL) throws {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in ["First page", "pdf_unified_needle"] {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]))
            context.textPosition = CGPoint(x: 40, y: 500)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
    }

    static func run() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("markview-redesign-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let feature = project.appendingPathComponent("docs/features/demo")
        try FileManager.default.createDirectory(at: feature.appendingPathComponent("questions"), withIntermediateDirectories: true)
        try "---\ntitle: Demo\nstatus: draft\n---\n\nOriginal overview.\n".write(
            to: feature.appendingPathComponent("overview.md"), atomically: true, encoding: .utf8)
        try "First answer.\n".write(to: feature.appendingPathComponent("questions/Q-001.md"),
                                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "func workspaceSearch() {}\n".write(to: project.appendingPathComponent("src/main.swift"),
                                                   atomically: true, encoding: .utf8)
        try "secret-value".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ignored-content".write(to: project.appendingPathComponent(".git/internal.md"),
                                        atomically: true, encoding: .utf8)

        let handoff = SpecificationHandoffStore.shared
        try await handoff.setLinkedFiles(["src/main.swift", "src/missing.swift"], project: project, slug: "demo")
        let first = try await handoff.markReady(project: project, slug: "demo", actor: "Boris", commitStatus: Self.writeReady(feature.appendingPathComponent("overview.md")))
        check(first.number == 1 && first.actor == "Boris", "first handoff records revision and actor")
        check(first.linkedFiles == ["src/main.swift", "src/missing.swift"], "explicit links survive missing files")
        let ready = try await handoff.state(project: project, slug: "demo")
        check(ready.isReady && !ready.hasChanged, "published handoff matches current folder")
        check((try String(contentsOf: feature.appendingPathComponent("overview.md"), encoding: .utf8)).contains("status: ready"),
              "initial handoff marks specification ready")

        try "Updated answer.\n".write(to: feature.appendingPathComponent("questions/Q-001.md"),
                                        atomically: true, encoding: .utf8)
        try "Added externally.\n".write(to: feature.appendingPathComponent("discussion.md"),
                                          atomically: true, encoding: .utf8)
        let changed = try await handoff.state(project: project, slug: "demo")
        check(changed.changes.contains { $0.path == "questions/Q-001.md" && $0.kind == .modified },
              "external modifications appear")
        check(changed.changes.contains { $0.path == "discussion.md" && $0.kind == .added },
              "external additions appear")
        let old = try await handoff.snapshotText(project: project, slug: "demo", revision: 1,
                                                  path: "questions/Q-001.md")
        check(old == "First answer.\n", "handed-off snapshot stays immutable")

        try FileManager.default.removeItem(at: feature.appendingPathComponent("questions/Q-001.md"))
        let deleted = try await handoff.state(project: project, slug: "demo")
        check(deleted.changes.contains { $0.path == "questions/Q-001.md" && $0.kind == .deleted },
              "external deletion appears")
        let second = try await handoff.markReady(project: project, slug: "demo", actor: "Developer", commitStatus: Self.writeReady(feature.appendingPathComponent("overview.md")))
        let current = try await handoff.state(project: project, slug: "demo")
        check(second.number == 2 && !current.hasChanged, "ready again publishes a clean independent revision")
        check(current.history.count == 2 && current.currentHashes["questions/Q-001.md"] == nil,
              "history is retained and deleted file is absent")
        let metadata = project.appendingPathComponent(".dde/cache")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: project.appendingPathComponent(".dde"))
        check((try await handoff.state(project: project, slug: "demo")).history.count == 2,
              "metadata removal leaves handoff history intact")
        // A revision whose record cannot be read is skipped by the history, left as it is, and never collided with (AR-36).
        let secondRecord = project.appendingPathComponent("docs/handoffs/demo/revisions/000002/record.json")
        let cutRecord = Data("{ \"number\": 2, ".utf8)
        try cutRecord.write(to: secondRecord)
        let withDamaged = try await handoff.state(project: project, slug: "demo")
        check(withDamaged.history.map(\.number) == [1] && (try? Data(contentsOf: secondRecord)) == cutRecord,
              "a damaged revision record is left out of the history and left as it is")
        let third = try await handoff.markReady(project: project, slug: "demo", actor: "Developer", commitStatus: { _ in true })
        check(third.number == 3 && (try? Data(contentsOf: secondRecord)) == cutRecord,
              "the next revision is numbered after the damaged one and does not replace it")
        check((try await handoff.state(project: project, slug: "demo")).history.map(\.number) == [1, 3], "the readable revisions stay in the history")
        do {
            try await handoff.setLinkedFiles(["../outside.md"], project: project, slug: "demo")
            check(false, "a link cannot escape the project")
        } catch HandoffError.invalidPath {
            check(true, "a link cannot escape the project")
        }

        // The status can be written by the lifecycle service instead of by the handoff (issue-lifecycle-management).
        let gated = project.appendingPathComponent("docs/features/gated")
        try FileManager.default.createDirectory(at: gated, withIntermediateDirectories: true)
        let gatedOverview = gated.appendingPathComponent("overview.md")
        let gatedText = "---\ntitle: Gated\nstatus: draft\n---\n\nGated overview.\n"
        try gatedText.write(to: gatedOverview, atomically: true, encoding: .utf8)
        final class Seen: @unchecked Sendable { var from = "" }
        let seen = Seen()
        let refused = try? await handoff.markReady(project: project, slug: "gated", actor: "Boris", commitStatus: { _ in false })
        check(refused == nil, "a status write the lifecycle declines fails the handoff")
        check((try String(contentsOf: gatedOverview, encoding: .utf8)) == gatedText, "a declined status write leaves the overview alone")
        check((try await handoff.state(project: project, slug: "gated")).history.isEmpty, "a declined status write removes the new revision")
        let committed = try await handoff.markReady(project: project, slug: "gated", actor: "Boris", commitStatus: { from in
            seen.from = from
            return Self.writeReady(gatedOverview)(from)
        })
        let gatedState = try await handoff.state(project: project, slug: "gated")
        check(committed.number == 1 && seen.from == "draft", "the lifecycle write is told the status it replaces")
        check(gatedState.isReady && !gatedState.hasChanged, "a status written by the lifecycle matches the handed-off snapshot")
        check((try String(contentsOf: gatedOverview, encoding: .utf8)).contains("status: ready"), "the lifecycle write sets ready")

        try makeSearchPDF(at: project.appendingPathComponent("report.pdf"))
        let word = NSAttributedString(string: "word_unified_needle")
        let wordData = try word.data(from: NSRange(location: 0, length: word.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try wordData.write(to: project.appendingPathComponent("report.docx"))
        let largeText = String(repeating: "x", count: ProjectSearchIndex.maximumTextBytes + 10) + "\nlarge_deferred_needle\n"
        try largeText.write(to: project.appendingPathComponent("large.swift"), atomically: true, encoding: .utf8)
        let ftsURL = project.appendingPathComponent("document-search.sqlite")
        var ftsDB: OpaquePointer?
        check(sqlite3_open(ftsURL.path, &ftsDB) == SQLITE_OK, "document FTS fixture opens")
        check(sqlite3_exec(ftsDB, "CREATE VIRTUAL TABLE fts_documents USING fts5(document_id, title, content)", nil, nil, nil) == SQLITE_OK,
              "document FTS fixture is created")
        check(sqlite3_exec(ftsDB, "INSERT INTO fts_documents VALUES ('docs/features/demo/overview.md', 'Demo', 'alpha distant beta')", nil, nil, nil) == SQLITE_OK,
              "document FTS fixture is populated")
        sqlite3_close(ftsDB)
        let indexed = ProjectDocumentSearch.search(databasePath: ftsURL.path, query: "alpha beta")
        check(indexed.contains { $0.path == "docs/features/demo/overview.md" },
              "the shared search includes indexed documents matching separate terms")
        check(ProjectDocumentSearch.search(databasePath: ftsURL.path, query: "\" OR *").isEmpty,
              "special search characters cannot change the FTS expression")
        check(ProjectDocumentSearch.search(databasePath: project.appendingPathComponent("missing.sqlite").path, query: "alpha").isEmpty,
              "missing document index fails without creating a database")
        let search = ProjectSearchIndex()
        try await search.rebuild(root: project, progress: { _ in })
        let names = await search.search("main.swift")
        check(names.contains { $0.scope == .file && $0.path == "src/main.swift" }, "filename search")
        let contents = await search.search("workspaceSearch")
        check(contents.contains { $0.scope == .content && $0.path == "src/main.swift" && $0.line == 1 },
              "source content search with line")
        let taskResults = await search.search("Gated overview")
        check(taskResults.contains { $0.scope == .content && $0.path == "docs/features/gated/overview.md" },
              "feature and task documents are included in project-wide search")
        let deferredSearch = ProjectSearchIndex(textBudget: 0)
        try await deferredSearch.rebuild(root: project, progress: { _ in })
        let deferredPDF = await deferredSearch.search("pdf_unified_needle")
        check(deferredPDF.contains { $0.path == "report.pdf" && $0.page == 2 },
              "PDF text remains searchable after the memory budget is exhausted")
        let deferredWord = await deferredSearch.search("word_unified_needle")
        check(deferredWord.contains { $0.path == "report.docx" },
              "Word text remains searchable after the memory budget is exhausted")
        let pdfResults = await search.search("pdf_unified_needle")
        check(pdfResults.contains { $0.scope == .content && $0.path == "report.pdf" && $0.page == 2 },
              "PDF text search returns its page")
        let wordResults = await search.search("word_unified_needle")
        check(wordResults.contains { $0.scope == .content && $0.path == "report.docx" },
              "Word document text is searchable")
        let largeResults = await search.search("large_deferred_needle")
        check(largeResults.contains { $0.scope == .content && $0.path == "large.swift" && $0.line == 2 },
              "large source files are searched on demand beyond the memory index limit")
        check(ProjectSearchIndex.snippet(String(repeating: "x", count: 300) + "needle", matching: "needle").contains("needle"),
              "a long-line excerpt includes the match")
        let outside = project.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "outside_private_needle".write(to: outside, atomically: true, encoding: .utf8)
        let largeURL = project.appendingPathComponent("large.swift")
        try FileManager.default.removeItem(at: largeURL)
        try FileManager.default.createSymbolicLink(at: largeURL, withDestinationURL: outside)
        check((await search.search("outside_private_needle")).isEmpty, "a deferred file replaced with an outside symlink is not read")
        try FileManager.default.removeItem(at: largeURL)
        check((await search.search("secret-value")).isEmpty, "credential content excluded")
        check((await search.search("ignored-content")).isEmpty, "Git metadata excluded")
        check((await search.search("First answer")).isEmpty, "immutable handoff copies excluded from search")
        try Array(repeating: "needle", count: 160).joined(separator: "\n").write(
            to: project.appendingPathComponent("000-many-results.md"), atomically: true, encoding: .utf8)
        try "No matching content.\n".write(to: project.appendingPathComponent("zzz-needle.md"),
                                             atomically: true, encoding: .utf8)
        try await search.rebuild(root: project, progress: { _ in })
        check((await search.search("needle")).contains { $0.scope == .file && $0.path == "zzz-needle.md" },
              "filename search continues after content result limit")
        try FileManager.default.removeItem(at: project.appendingPathComponent("src/main.swift"))
        try await search.rebuild(root: project, progress: { _ in })
        check((await search.search("workspaceSearch")).isEmpty, "refresh removes deleted content")
        let changes = ProjectChangeScanner()
        try await changes.open(project)
        try "A new external note.\n".write(to: project.appendingPathComponent("note.md"),
                                              atomically: true, encoding: .utf8)
        let observed = try await changes.refresh()
        check(observed.contains { $0.path == "note.md" && $0.kind == .added &&
            $0.current == "A new external note.\n" }, "review records externally added text")
        await changes.acknowledge()
        check((try await changes.refresh()).isEmpty, "mark reviewed establishes a new baseline")
        try "Revised external note.\n".write(to: project.appendingPathComponent("note.md"),
                                              atomically: true, encoding: .utf8)
        let modified = try await changes.refresh()
        check(modified.contains { $0.path == "note.md" && $0.kind == .modified &&
            $0.before == "A new external note.\n" && $0.current == "Revised external note.\n" },
            "review compares old and current text")
        try FileManager.default.removeItem(at: project.appendingPathComponent("note.md"))
        let removed = try await changes.refresh()
        check(removed.contains { $0.path == "note.md" && $0.kind == .deleted },
              "review detects external deletion")
        XCTAssertGreaterThan(checks, 0)
    }
}

extension EditorHostTests {
    @MainActor func testRealFeatureFlowConflictAndBugBasketHandoffs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-basket-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let assistant = FeatureFlowAssistantSpy(root: root)
        let git = window.composition.gitClient
        let flow = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: git,
                                          research: window.composition.research)
        defer { flow.close() }
        flow.resolveConflictsWithAI()
        XCTAssertTrue(assistant.sent.isEmpty)
        git.branch = "feature"
        git.operationInProgress = "merge"
        git.repoStatus = GitRepoStatus.parse("u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/a.swift\0u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/b.swift\0")
        assistant.assistantIsBusy = true
        flow.resolveConflictsWithAI()
        XCTAssertTrue(assistant.sent.isEmpty)
        XCTAssertTrue(git.lastError?.contains("still working") == true)
        assistant.assistantIsBusy = false
        flow.resolveConflictsWithAI()
        let conflict = try XCTUnwrap(assistant.sent.last)
        for text in ["src/a.swift", "src/b.swift", "merge", "feature"] { XCTAssertTrue(conflict.prompt.contains(text)) }
        XCTAssertTrue(conflict.submit)

        flow.features.setup(root: root)
        let first = try flow.features.createBug(BugReportDraft(title: "First bug", body: "First", provenance: "Test"))
        let second = try flow.features.createBug(BugReportDraft(title: "Second bug", body: "Second", provenance: "Test"))
        let firstReport = try XCTUnwrap(flow.features.bug(at: first.url))
        let secondReport = try XCTUnwrap(flow.features.bug(at: second.url))
        flow.bugBatch.toggle(firstReport)
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 1, "One bug is not a batch")
        flow.bugBatch.toggle(secondReport)
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)
        assistant.assistantIsBusy = true
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 1)
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)
        assistant.assistantIsBusy = false
        assistant.sends = false
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 1)
        XCTAssertEqual(flow.bugBatch.eligible.count, 2)
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, first.id), "open")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, second.id), "open")
        XCTAssertNotNil(flow.bugBatch.notice)
        assistant.sends = true
        flow.fixBasketWithAI()
        XCTAssertEqual(assistant.sent.count, 2)
        let sent = try XCTUnwrap(assistant.sent.last)
        XCTAssertTrue(sent.prompt.contains(first.id))
        XCTAssertTrue(sent.prompt.contains(second.id))
        XCTAssertTrue(sent.submit)
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, first.id), "fixing")
        XCTAssertEqual(flow.features.lifecycle.storedStatus(.bug, second.id), "fixing")
        XCTAssertTrue(flow.bugBatch.basket.isEmpty)
    }

    @MainActor func testRealFeatureFlowIntakeSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-intake-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = FeatureIntakeFixture()
        AIAssistantRunner.setTestRunner { request, delta, activity in try await fixture.run(request, delta, activity) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)
        let tabs = FeatureFlowTabsSpy()
        let flow = FeatureFlowCoordinator(project: window.project, assistants: window.terminals, tabs: tabs, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        flow.features.setup(root: root)
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        var results: [String?] = []
        window.requests.intake = IntakeRequest(kind: .quickFeature)
        flow.submitIntake(.quickFeature, from: "make it", attachments: [], linkedIssue: 5, commentOnIssue: false) { results.append($0) }
        let success = try await wait { !results.isEmpty }
        XCTAssertTrue(success)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? "missing")
        XCTAssertNil(window.requests.intake)
        XCTAssertEqual(flow.features.features.first?.title, "Fixture feature")
        XCTAssertEqual(window.layout.featureStage, .build)
        let overview = try XCTUnwrap(flow.features.features.first?.overviewURL)
        XCTAssertEqual(tabs.opened, [overview])

        await fixture.setMode(.fail)
        results = []
        window.requests.intake = IntakeRequest(kind: .bug)
        flow.submitIntake(.bug, from: "it breaks", attachments: [], linkedIssue: nil, commentOnIssue: false) { results.append($0) }
        let failed = try await wait { !results.isEmpty }
        XCTAssertTrue(failed)
        XCTAssertEqual(results.first ?? nil, "fixture failure")
        XCTAssertEqual(window.requests.intake?.kind, .bug)

        await fixture.setMode(.wait)
        results = []
        let previous = await fixture.count()
        flow.submitIntake(.quickFeature, from: "one", attachments: [], linkedIssue: nil, commentOnIssue: false) { results.append($0) }
        flow.submitIntake(.quickFeature, from: "two", attachments: [], linkedIssue: nil, commentOnIssue: false) { results.append($0) }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first.flatMap { $0 }?.contains("already being made") == true)
        for _ in 0..<200 {
            if await fixture.count() > previous { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let count = await fixture.count()
        XCTAssertEqual(count, previous + 1)
        flow.close()
        let cancelled = try await wait { results.count == 2 }
        if !cancelled {
            flow.features.assistant.stopAction("intake:quick-feature")
            _ = try await wait { results.count == 2 }
        }
        XCTAssertTrue(cancelled, "Closing the window must cancel the pending assistant request and notify the sheet")
        let cancelledCalls = await fixture.cancellationCount()
        XCTAssertEqual(cancelledCalls, 1)
        XCTAssertNotNil(window.requests.intake)
    }

    @MainActor func testRealFeatureFlowStartIssueOnLocalBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-issue-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> String {
            let result = await GitHubClient.execute(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args,
                                                    in: root, git: true)
            guard result.status == 0 else { throw NSError(domain: "LocalGitFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        _ = try await git(["commit", "--allow-empty", "-q", "-m", "initial"])
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.composition.gitClient.workingDirectory = root
        let assistant = FeatureFlowAssistantSpy(root: root)
        let flow = FeatureFlowCoordinator(project: window.project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close() }
        let comments = (0..<12).map { #"{"author":{"login":"user\#($0)"},"body":"comment \#($0)"}"# }.joined(separator: ",")
        let json = #"{"number":12,"title":"Fix the Crash on Save!","state":"OPEN","url":"https://example.invalid/12","body":"It crashes.","comments":[\#(comments)]}"#
        let issue = try JSONDecoder().decode(GHIssue.self, from: Data(json.utf8))
        let error = await flow.startIssueWithAI(issue)
        XCTAssertNil(error)
        let branch = try await git(["branch", "--show-current"])
        XCTAssertEqual(branch, "issue-12-fix-the-crash-on-save")
        let sent = try XCTUnwrap(assistant.sent.first)
        XCTAssertTrue(sent.submit)
        XCTAssertTrue(sent.prompt.contains("Fix the Crash on Save!"))
        XCTAssertTrue(sent.prompt.contains("It crashes."))
        XCTAssertTrue(sent.prompt.contains("You are on branch issue-12-fix-the-crash-on-save"))
        XCTAssertFalse(sent.prompt.contains("- user0:"))
        XCTAssertFalse(sent.prompt.contains("- user1:"))
        XCTAssertTrue(sent.prompt.contains("- user2: comment 2"))
        XCTAssertTrue(sent.prompt.contains("- user11: comment 11"))
        _ = try await git(["switch", "-q", "main"])
        let repeated = await flow.startIssueWithAI(issue)
        XCTAssertNil(repeated)
        let branches = try await git(["branch", "--list", "issue-12*"])
        XCTAssertEqual(branches.split(separator: "\n").count, 1)
        let reopened = try await git(["branch", "--show-current"])
        XCTAssertEqual(reopened, "issue-12-fix-the-crash-on-save")
        let bare = try JSONDecoder().decode(GHIssue.self, from: Data(#"{"number":3,"title":"!!!","state":"OPEN","url":"https://example.invalid/3","body":null,"comments":[]}"#.utf8))
        let bareError = await flow.startIssueWithAI(bare)
        XCTAssertNil(bareError)
        let bareBranch = try await git(["branch", "--show-current"])
        XCTAssertEqual(bareBranch, "issue-3")
        XCTAssertTrue(assistant.sent.last?.prompt.contains("(no description)") == true)
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        let noFolder = await blank.flow.startIssueWithAI(issue)
        XCTAssertEqual(noFolder, "No folder open.")
    }

    @MainActor func testRealFeatureFlowAssistantHandoffs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-handoff-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "feature-handoff-host-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"), settings: Settings(defaults))
        project.beginOpening(root)
        project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("window-recent.json"))
        defer { window.composition.close() }
        let assistant = FeatureFlowAssistantSpy(root: root)
        let flow = FeatureFlowCoordinator(project: project, assistants: assistant, tabs: window, requests: window.requests,
                                          layout: window.layout, chrome: window.chrome, gitClient: window.composition.gitClient,
                                          research: window.composition.research)
        defer { flow.close(); project.close() }
        _ = try ProjectWorkflowStore(projectRoot: root).save(.standard, expectedRevision: 0)
        flow.features.setup(root: root)
        let slug = try XCTUnwrap(flow.features.createFeature(title: "A feature", idea: "A fixture"))
        let folder = root.appendingPathComponent("docs/features/\(slug)")
        flow.implementWithAI(folder)
        XCTAssertEqual(window.requests.doneRequest, folder)
        XCTAssertTrue(assistant.sent.isEmpty)
        let before = try XCTUnwrap(flow.features.feature(slug)?.status)
        assistant.sends = false
        flow.startImplementation(folder, done: .standard)
        XCTAssertTrue(assistant.sent.isEmpty)
        XCTAssertEqual(flow.features.feature(slug)?.status, before)
        assistant.sends = true
        flow.startImplementation(root.appendingPathComponent("notes.md"), done: .standard)
        XCTAssertEqual(assistant.sent.count, 1)
        XCTAssertTrue(assistant.sent[0].submit)
        XCTAssertTrue(assistant.sent[0].prompt.contains("notes.md"))
        XCTAssertEqual(flow.features.feature(slug)?.status, before)

        let bug = try flow.features.createBug(BugReportDraft(title: "Broken", body: "A fixture", provenance: "Test"))
        let bugStatus = try XCTUnwrap(flow.features.bug(at: bug.url)?.status)
        let canStart = flow.features.lifecycle.canStartByHandoff(.bug, bug.id)
        let target = flow.features.lifecycle.startTarget(.bug, from: bugStatus, issue: bug.id)
        XCTAssertTrue(canStart, "Bug \(bug.id), stored status \(flow.features.lifecycle.storedStatus(.bug, bug.id) ?? "nil"), target \(target ?? "nil"), error \(flow.features.lastError ?? "none")")
        assistant.sends = false
        flow.fixBugWithAI(bug.url)
        XCTAssertEqual(flow.features.bug(at: bug.url)?.status, bugStatus)
        assistant.sends = true
        flow.fixBugWithAI(bug.url)
        XCTAssertEqual(assistant.sent.count, 2)
        let sentBug = try XCTUnwrap(assistant.sent.last)
        XCTAssertTrue(sentBug.prompt.contains(bug.url.lastPathComponent))
        XCTAssertTrue(sentBug.submit)
        XCTAssertNotEqual(flow.features.bug(at: bug.url)?.status, bugStatus)

        let result = await flow.fixInPullRequest(14, prompt: "Please fix.")
        XCTAssertNil(result)
        XCTAssertEqual(assistant.sent.last?.prompt, "Please fix.\n\nNote: this is pull request #14; its branch may not be the one checked out here.")
        let plain = await flow.fixInPullRequest(nil, prompt: "Review it.")
        XCTAssertNil(plain)
        XCTAssertEqual(assistant.sent.last?.prompt, "Review it.")
    }

    @MainActor func testRealFeatureFlowLocalBranches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-git-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> String {
            let result = await GitHubClient.execute(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args,
                                                    in: root, git: true)
            guard result.status == 0 else { throw NSError(domain: "LocalGitFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr]) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
        let file = root.appendingPathComponent("tracked.md")
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "tracked.md"])
        _ = try await git(["commit", "-q", "-m", "initial"])
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.composition.gitClient.workingDirectory = root
        await window.tabs.openTextFile(file)
        let createError = await window.flow.createBranch("topic", from: "main")
        XCTAssertNil(createError)
        let topic = try await git(["branch", "--show-current"])
        XCTAssertEqual(topic, "topic")
        try "topic\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "tracked.md"])
        _ = try await git(["commit", "-q", "-m", "topic"])
        let switchError = await window.flow.switchBranch("main")
        XCTAssertNil(switchError)
        for _ in 0..<300 where window.tabs.activeTab?.content != "main\n" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.content, "main\n")
        let main = try await git(["branch", "--show-current"])
        XCTAssertEqual(main, "main")
        let againError = await window.flow.switchBranch("topic")
        XCTAssertNil(againError)
        for _ in 0..<300 where window.tabs.activeTab?.content != "topic\n" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.content, "topic\n")
        let duplicateError = await window.flow.createBranch("topic", from: "main")
        XCTAssertNotNil(duplicateError)
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        let checkoutError = await window.flow.checkoutPullRequest(6)
        XCTAssertTrue(checkoutError?.contains("uncommitted changes") == true)
        XCTAssertTrue(checkoutError?.contains("#6") == true)
        let current = try await git(["branch", "--show-current"])
        XCTAssertEqual(current, "topic")
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        let noFolder = await blank.flow.checkoutPullRequest(1)
        XCTAssertEqual(noFolder, "No folder open.")
    }

    @MainActor func testRealFeatureFlowGitHubTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feature-github-tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        blank.flow.openGitHubTab(.issue(number: 4, repo: "o/r", title: "#4"))
        XCTAssertTrue(blank.tabs.openTabs.isEmpty)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.chrome.showCenter = false
        let run = GitHubItem.run(id: 3, repo: "o/r", title: "run")
        window.flow.openGitHubTab(run)
        XCTAssertEqual(window.layout.gitSection, .actions)
        XCTAssertEqual(window.layout.workSection, .git)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        guard case .github(let openedRun)? = window.tabs.activeTab?.kind else { return XCTFail("Run tab was not opened") }
        XCTAssertEqual(openedRun, run)
        let issue = GitHubItem.issue(number: 4, repo: "o/r", title: "#4")
        window.flow.openGitHubTab(issue)
        XCTAssertEqual(window.layout.gitSection, .issues)
        guard case .github(let openedIssue)? = window.tabs.activeTab?.kind else { return XCTFail("Issue tab was not opened") }
        XCTAssertEqual(openedIssue, issue)
        let pull = GitHubItem.pullRequest(number: 5, repo: "o/r", title: "#5")
        window.flow.openGitHubTab(pull)
        XCTAssertEqual(window.layout.gitSection, .pullRequests)
        guard case .github(let openedPull)? = window.tabs.activeTab?.kind else { return XCTFail("Pull request tab was not opened") }
        XCTAssertEqual(openedPull, pull)
        let count = window.tabs.openTabs.count
        window.flow.openGitHubTab(run)
        XCTAssertEqual(window.tabs.openTabs.count, count)
        guard case .github(let selected)? = window.tabs.activeTab?.kind else { return XCTFail("Run tab was not selected") }
        XCTAssertEqual(selected, run)
    }

    @MainActor func testRealFeatureFlowResumeHandoff() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("feature-resume-host-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true).resolvingSymlinksInPath()
        let outside = base.appendingPathComponent("outside.md")
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = docs.appendingPathComponent("a.md")
        try "inside".write(to: file, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("link.md"), withDestinationURL: outside)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let flow = window.flow
        flow.resumeHandoff(slug: "f1", title: "No project", linkedFiles: ["docs/a.md"])
        XCTAssertNil(window.requests.handoffResume)
        flow.features.setup(root: root)
        flow.resumeHandoff(slug: "f1", title: "Cancelled", linkedFiles: ["docs/a.md"])
        flow.cancelWork()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(window.requests.handoffResume)
        XCTAssertTrue(window.tabs.openTabs.isEmpty)
        let missing = ["docs/gone.md", "docs/folder", "/etc/hosts", "../escape.md", "docs/link.md", "docs//a.md", ""]
        flow.resumeHandoff(slug: "f1", title: "Feature one", linkedFiles: ["docs/a.md"] + missing)
        for _ in 0..<200 where window.requests.handoffResume == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let resume = try XCTUnwrap(window.requests.handoffResume)
        XCTAssertEqual(resume.slug, "f1")
        XCTAssertEqual(resume.title, "Feature one")
        XCTAssertEqual(resume.missingFiles, missing)
        for _ in 0..<200 where window.tabs.activeTab?.url != file { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.openTabs.filter(\.isFileBacked).map(\.url), [file])
        XCTAssertEqual(window.layout.workspaceArea, .files)
    }

    @MainActor func testRealFeatureFlowIntakeAndPresentation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("feature-flow-host-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let doc = docs.appendingPathComponent("spec.md")
        let outside = base.appendingPathComponent("outside.md")
        let created = root.appendingPathComponent("docs/features/new-idea/overview.md")
        try FileManager.default.createDirectory(at: created.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [doc, outside, created] { try "fixture".write(to: url, atomically: true, encoding: .utf8) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let flow = window.flow
        flow.startIntake(.bug, fromIssue: 7)
        XCTAssertEqual(window.requests.intake?.kind, .bug)
        XCTAssertEqual(window.requests.intake?.linkedIssue, 7)
        XCTAssertEqual(window.requests.intake?.loadIssue, 7)
        let pull = try JSONDecoder().decode(GHPullRequest.self, from: Data(#"{"number":9,"title":"Fix it","headRefName":"fix","baseRefName":"main","state":"OPEN","url":"https://example.invalid/9"}"#.utf8))
        flow.startIntake(.feature, fromPullRequest: pull)
        XCTAssertEqual(window.requests.intake?.loadPullRequest, 9)
        XCTAssertEqual(window.requests.intake?.text, "Pull request #9: Fix it (fix → main)")
        flow.startIntake(.feature, fromDocument: doc)
        XCTAssertEqual(window.requests.intake?.attachments, [doc])
        XCTAssertEqual(window.requests.intake?.text, "Build a feature from the document docs/spec.md (attached).")
        flow.startIntake(.research, fromDocument: doc)
        XCTAssertEqual(window.requests.intake?.targets, [doc])
        XCTAssertEqual(window.requests.intake?.attachments, [])
        flow.startIntake(.understand, fromDocument: doc)
        XCTAssertEqual(window.requests.intake?.attachments, [])
        XCTAssertNil(window.requests.intake?.targets)
        XCTAssertTrue(window.requests.intake?.text.contains("docs/spec.md") == true)
        flow.startResearch(fromFolder: docs)
        XCTAssertEqual(window.requests.intake?.targets, [docs])
        XCTAssertTrue(window.requests.intake?.text.hasPrefix("Review the documents in docs and its subfolders") == true)
        flow.newResearch()
        XCTAssertEqual(window.requests.intake?.kind, .research)
        XCTAssertNil(window.requests.intake?.targets)
        await window.tabs.openTextFile(doc)
        XCTAssertEqual(flow.researchDefaultTargets, [doc])
        await window.tabs.openTextFile(outside)
        XCTAssertTrue(flow.researchDefaultTargets.isEmpty)
        flow.showCreatedProject(root, specification: "new-idea")
        XCTAssertEqual(flow.features.activeSlug, "new-idea")
        XCTAssertEqual(window.layout.leftPanel, "issues")
        XCTAssertEqual(window.layout.issuesFeature, "new-idea")
        XCTAssertEqual(window.layout.featureStage, .explore)
        XCTAssertEqual(window.layout.navigatorTab, .feature)
        XCTAssertTrue(window.chrome.showTOC)
        XCTAssertTrue(window.chrome.showFileTree)
        for _ in 0..<200 where window.tabs.activeTab?.url != created { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(window.tabs.activeTab?.url, created)
        flow.intakeFinished(.quickFeature, outcome: FeatureAssistant.IntakeOutcome(file: nil, feature: "quick"))
        XCTAssertEqual(window.layout.featureStage, .build)
        XCTAssertEqual(flow.features.activeSlug, "quick")
        flow.intakeFinished(.feature, outcome: FeatureAssistant.IntakeOutcome(file: nil, feature: "full"))
        XCTAssertEqual(window.layout.featureStage, .explore)
        XCTAssertEqual(flow.features.activeSlug, "full")
        flow.showFeatureContext("ctx")
        XCTAssertEqual(flow.features.activeSlug, "ctx")
        XCTAssertEqual(window.layout.issuesFeature, "ctx")
        XCTAssertTrue(window.chrome.showTOC)
        XCTAssertTrue(window.chrome.terminalVisible)
        flow.showFeatureContext(nil)
        XCTAssertEqual(window.layout.issuesFeature, "ctx")
    }

    @MainActor func testRealToolTabsRoutingAndProjectLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-routing-" + UUID().uuidString)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        blank.toolTabs.open(.git)
        XCTAssertTrue(blank.tabs.openTabs.isEmpty, "A tool cannot open without a project")
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: first, isDirectory: true)
        let router = window.toolTabs
        XCTAssertTrue(router.qa.assistants === window.terminals)
        let tools = ToolRegistry.shared.tools
        for tool in tools {
            router.open(tool.id)
            XCTAssertEqual(window.tabs.openTabs.filter { $0.kind.toolID == tool.id }.count, 1, "\(tool.id.rawValue) opens once")
            XCTAssertEqual(window.tabs.activeTab?.kind.toolID, tool.id)
        }
        XCTAssertEqual(window.tabs.openTabs.count, tools.count)
        for tool in tools {
            router.open(tool.id)
            XCTAssertEqual(window.tabs.openTabs.filter { $0.kind.toolID == tool.id }.count, 1, "\(tool.id.rawValue) is reused")
            XCTAssertEqual(window.tabs.activeTab?.kind.toolID, tool.id)
        }
        XCTAssertEqual(window.tabs.openTabs.count, tools.count)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        XCTAssertEqual(router.deployments.store.root, first)
        XCTAssertEqual(router.discussions.store.root, first)
        XCTAssertEqual(router.qa.root, first)
        XCTAssertNotNil(router.qa.run.bugFiler)
        XCTAssertTrue(router.qa.run.bugFiler === router.qa.archive.bugFiler)
        XCTAssertTrue(router.qa.run.runLinks is CockpitRunLinks)
        XCTAssertTrue(router.qa.archive.runLinks is CockpitRunLinks)
        guard let studioTab = window.tabs.openTabs.first(where: { $0.kind.toolID == .uiStudio }),
              case .uiStudio(let studio) = studioTab.kind,
              let cockpitTab = window.tabs.openTabs.first(where: { $0.kind.toolID == .cockpit }),
              case .cockpit(let cockpit) = cockpitTab.kind else {
            XCTFail("UI Studio and Cockpit must carry their actual sessions")
            return
        }
        XCTAssertEqual(studio.root, first)
        XCTAssertEqual(cockpit.root, first)
        let cockpitIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit })
        window.tabs.closeTab(at: cockpitIndex)
        router.open(.cockpit)
        guard case .cockpit(let reopened)? = window.tabs.activeTab?.kind else { XCTFail("Cockpit did not reopen"); return }
        XCTAssertTrue(reopened === cockpit)
        let deploymentIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .deployments })
        window.tabs.closeTab(at: deploymentIndex)
        router.deployments.store.needsAttention.send()
        XCTAssertEqual(window.tabs.activeTab?.kind.toolID, .deployments)
        router.projectOpened(second)
        XCTAssertEqual(router.deployments.store.root, second)
        XCTAssertEqual(router.discussions.store.root, second)
        router.projectClosed()
        XCTAssertNil(router.deployments.store.root)
        XCTAssertNil(router.discussions.store.root)
        let oldCockpitIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit })
        window.tabs.closeTab(at: oldCockpitIndex)
        router.open(.cockpit)
        guard case .cockpit(let renewed)? = window.tabs.activeTab?.kind else { XCTFail("Cockpit did not renew"); return }
        XCTAssertFalse(renewed === cockpit)
        await studio.close()
    }

    func testWorkspaceRedesign() async throws {
        try await WorkspaceRedesignFixture.run()
    }

    @MainActor func testRealWindowCompositionIsolationAndClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("first.json"))
        let second = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("second.json"))
        defer { second.composition.close() }
        let composition = first.composition
        XCTAssertTrue(composition.project === first.project)
        XCTAssertTrue(composition.tabs === first.tabs)
        XCTAssertTrue(composition.terminals === first.terminals)
        XCTAssertTrue(composition.browser === first.browser)
        XCTAssertTrue(composition.flow === first.flow)
        XCTAssertFalse(composition.project === second.project)
        XCTAssertFalse(composition.tabs === second.tabs)
        XCTAssertFalse(composition.polling === second.polling)
        XCTAssertTrue(composition.tabs.polling === composition.polling)
        XCTAssertTrue(composition.project.fileTree.polling === composition.polling)
        var changes = 0
        let changeSubscription = composition.changes.sink { changes += 1 }
        composition.project.objectWillChange.send()
        composition.codeXRay.objectWillChange.send()
        XCTAssertEqual(changes, 2, "Project and code changes both reach the window")
        changeSubscription.cancel()

        let repo = GitHubRepo(slug: "example/project", remote: "origin", isUpstream: false)
        composition.flow.gitHub.selectedRepo = repo
        XCTAssertEqual(composition.codeXRay.architecture.review.gitHubRepo, repo)
        XCTAssertNil(second.codeXRay.architecture.review.gitHubRepo)
        composition.flow.gitHub.selectedRepo = nil
        XCTAssertNil(composition.codeXRay.architecture.review.gitHubRepo)

        let pending = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        composition.taskBag.store(pending, for: "composition-test")
        composition.polling.every(60, key: "composition-test") {}
        XCTAssertEqual(composition.taskBag.activeCount, 1)
        XCTAssertTrue(composition.polling.keys.contains("composition-test"))
        composition.close()
        XCTAssertTrue(pending.isCancelled)
        XCTAssertEqual(composition.taskBag.activeCount, 0)
        XCTAssertTrue(composition.polling.keys.isEmpty)
        composition.flow.gitHub.selectedRepo = repo
        XCTAssertNil(composition.codeXRay.architecture.review.gitHubRepo)
        composition.flow.gitHub.selectedRepo = nil
        await pending.value
    }

    @MainActor func testRealWindowCompositionReloadsProjectTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-reload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("document.md")
        try "before".write(to: document, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        await window.tabs.openTextFile(document)
        XCTAssertEqual(window.tabs.activeTab?.content, "before")
        try "after".write(to: document, atomically: true, encoding: .utf8)
        let added = root.appendingPathComponent("added.md")
        try "new".write(to: added, atomically: true, encoding: .utf8)
        await window.tabs.reloadChangedOpenFiles(all: true)
        XCTAssertEqual(window.tabs.activeTab?.content, "after")
        for _ in 0..<100 {
            if window.project.fileTree.rootNode?.children?.contains(where: { $0.url == added }) == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(window.project.fileTree.rootNode?.children?.contains(where: { $0.url == added }) == true,
                      "Reloading an externally changed tab refreshes the real project tree")
    }

    @MainActor func testRealWindowCompositionClosesInsightTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-insight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let cache = try InsightCache(workspaceURL: root, sessionId: UUID(), pagePolicy: "")
        let session = InsightSession(folderURL: root, mdFiles: [], graphRAG: nil, cache: cache)
        window.showInsightTab(session, placeholder: root.appendingPathComponent(".insight-test"))
        var releasedWhileTabPresent = false
        let subscription = window.insight.blobReleases.sink {
            releasedWhileTabPresent = window.tabs.openTabs.contains { tab in
                if case .insight(let current) = tab.kind { return current.id == session.id }
                return false
            }
        }
        window.tabs.closeTab(at: 0)
        for _ in 0..<100 where !window.tabs.openTabs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(releasedWhileTabPresent, "The window releases blob URLs before removing the Insight tab")
        XCTAssertTrue(window.tabs.openTabs.isEmpty, "The window removes the tab after session cancellation")
        subscription.cancel()
    }

    @MainActor func testRealWindowCompositionClosesTerminalTab() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mvct-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            if let previousSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", previousSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        let terminal = window.openTerminal(in: root, startupCommand: nil)
        let socketPath = AgentToolServer.socketPath
        let createdListener = socketPath?.hasPrefix(root.path + "/") == true
        defer {
            window.composition.close()
            AgentToolServer.unregister(window.browser.controlID)
            if createdListener { AgentToolServer.shutdown() }
        }
        XCTAssertTrue(window.terminals.tabTerminal(terminal.id) === terminal)
        XCTAssertNotNil(socketPath, "The test host can register the terminal's control socket")
        XCTAssertEqual(window.tabs.openTabs.count, 1)
        XCTAssertFalse(terminal.isRunning, "Creating the fixture does not start a shell")
        window.tabs.closeTab(at: 0)
        XCTAssertNil(window.terminals.tabTerminal(terminal.id), "Closing the tab removes its owned terminal")
        XCTAssertTrue(window.tabs.openTabs.isEmpty)
    }

    @MainActor func testRealWindowCompositionRefreshesGitOnActivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let variables = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT",
                         "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"]
        let previous = variables.map { name in (name, getenv(name).map { String(cString: $0) }) }
        defer {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        for name in variables { unsetenv(name) }
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        setenv("GIT_TERMINAL_PROMPT", "0", 1)
        let initialized = await Subprocess.run(.init(executable: "/usr/bin/git", arguments: ["init", "-q", "-b", "main"], cwd: root))
        XCTAssertEqual(initialized.exitCode, 0)
        guard initialized.exitCode == 0 else { return }
        let committed = await Subprocess.run(.init(executable: "/usr/bin/git", arguments: ["-c", "user.name=Test",
            "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--allow-empty", "-qm", "fixture"], cwd: root))
        XCTAssertEqual(committed.exitCode, 0)
        guard committed.exitCode == 0 else { return }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let git = window.gitClient
        git.workingDirectory = root
        var reports: [String] = []
        let subscription = git.branchReports.sink { reports.append($0) }
        defer { subscription.cancel() }

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(reports.isEmpty, "A window without a detected repository does not refresh")
        git.isGitRepo = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where reports.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(reports.first, "main", "Activation refreshes the actual repository")
        git.isOperating = true
        let reportCount = reports.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        window.project.fileTree.timerBeats.send()
        XCTAssertFalse(window.taskBag.contains(key: "git-status"), "A file watcher beat does not refresh Git during an operation")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(reports.count, reportCount, "Activation does not refresh while Git is busy")
        window.composition.close()
        git.isOperating = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(reports.count, reportCount, "A closed window no longer responds to activation")
    }

    @MainActor func testRealWindowCompositionRoutesSavedFiles() async throws {
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost" else {
            XCTFail("The automatic-analysis setting may only be changed in the isolated test host")
            return
        }
        let original = Settings.standard.stored(Setting.autoAnalyze)
        Settings.standard.set(false, for: Setting.autoAnalyze)
        defer { Settings.standard.set(original, for: Setting.autoAnalyze) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-save-" + UUID().uuidString)
        let sibling = URL(fileURLWithPath: root.path + "-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: sibling) }
        let inside = root.appendingPathComponent("inside.md")
        let outside = sibling.appendingPathComponent("outside.md")
        for url in [inside, outside] { try "fixture".write(to: url, atomically: true, encoding: .utf8) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        await window.tabs.openTextFile(outside)
        await window.tabs.openTextFile(inside)
        let architecture = window.codeXRay.architecture
        architecture.startAutomaticCodeAnalysis(root: root, db: nil)
        XCTAssertEqual(architecture.automaticState, .off)
        func recordedChange() throws -> Date? {
            let scheduler = try XCTUnwrap(Mirror(reflecting: architecture).children.first { $0.label == "scheduler" }?.value as? AutoAnalysisScheduler)
            return scheduler.lastChange
        }
        XCTAssertNil(try recordedChange())
        window.tabs.saveFile(at: 0)
        XCTAssertNil(try recordedChange(), "A sibling folder with the same prefix is outside the project")
        window.tabs.saveFile(at: 1)
        XCTAssertNotNil(try recordedChange(), "Saving in the project notifies its actual analysis scheduler")
        window.composition.close()
        architecture.startAutomaticCodeAnalysis(root: root, db: nil)
        defer { architecture.reset() }
        XCTAssertNil(try recordedChange())
        window.tabs.saveFile(at: 1)
        XCTAssertNil(try recordedChange(), "A closed window no longer forwards saved-file events")
    }

    @MainActor func testRealDiscussionHostLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-routing-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "discussion-routing-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"), settings: Settings(defaults))
        project.beginOpening(root)
        project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        func expectEventually(_ condition: () -> Bool, line: UInt = #line) async throws {
            let reached = try await wait(condition)
            XCTAssertTrue(reached, "Expected condition was not reached", line: line)
        }
        let spy = DiscussionRunnerSpy()
        let notes = "\n```discussion-notes\n{\"decisions\": [\"Documents only\"], \"open_questions\": [\"Sync back?\"]}\n```"
        let answer: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = { request, onDelta, onActivity in
            spy.record(request)
            onActivity?(.read("/project/Sources/App.swift"))
            onDelta?("Offline works ")
            onDelta?("for documents.")
            return try CLICompletion.Result(text: "Offline works for documents." + notes, structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        var opened = 0
        let host = DiscussionsHost(project: project, showTab: { opened += 1 }, runner: answer)
        defer { host.close() }
        host.projectOpened(root)
        let slug = try XCTUnwrap(host.store.create(title: "Offline mode", scope: "Sources"))
        host.ask(slug, question: "   ")
        XCTAssertNil(host.store.asking)
        host.ask(slug, question: "  Which data must work offline?  ")
        XCTAssertEqual(host.store.asking, slug)
        XCTAssertEqual(host.store.live?.question, "Which data must work offline?")
        host.ask(slug, question: "A second question")
        let finished = try await wait { host.store.asking == nil }
        XCTAssertTrue(finished)
        let discussion = try XCTUnwrap(host.store.discussions.first { $0.slug == slug })
        XCTAssertEqual(discussion.turns.count, 1)
        XCTAssertEqual(discussion.turns.first?.question, "Which data must work offline?")
        XCTAssertEqual(discussion.turns.first?.answer, "Offline works for documents.")
        XCTAssertEqual(discussion.items(.decision).map(\.text), ["Documents only"])
        XCTAssertEqual(discussion.items(.question).map(\.text), ["Sync back?"])
        XCTAssertNil(host.store.live)
        XCTAssertNil(host.store.lastError)
        let sent = try XCTUnwrap(spy.seen.first)
        XCTAssertEqual(spy.seen.count, 1)
        XCTAssertEqual(sent.label, "discussion")
        XCTAssertEqual(sent.effort, "medium")
        XCTAssertEqual(sent.timeout, 900)
        XCTAssertEqual(sent.systemPrompt, DiscussionPrompt.system)
        XCTAssertEqual(sent.project, root)
        XCTAssertEqual(sent.readableFolder, root)
        let away = try XCTUnwrap(host.store.create(title: "Outside", scope: outside.path))
        host.ask(away, question: "What is there?")
        try await expectEventually { host.store.asking == nil }
        XCTAssertEqual(spy.seen.last?.readableFolder, outside)
        XCTAssertEqual(spy.seen.last?.extraReadableFolders, [root])

        let silent = DiscussionsHost(project: project, showTab: {}, runner: { _, _, _ in
            try CLICompletion.Result(text: "  \n", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        defer { silent.close() }
        silent.projectOpened(root)
        silent.ask(slug, question: "Anything?")
        try await expectEventually { silent.store.asking == nil }
        XCTAssertEqual(silent.store.lastError, "The assistant gave no answer.")
        XCTAssertEqual(silent.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        let broken = DiscussionsHost(project: project, showTab: {}, runner: { _, _, _ in
            throw NSError(domain: "assistant", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        })
        defer { broken.close() }
        broken.projectOpened(root)
        broken.ask(slug, question: "Anything?")
        try await expectEventually { broken.store.asking == nil }
        XCTAssertEqual(broken.store.lastError, "boom")
        XCTAssertNil(broken.store.live)

        let stopSpy = DiscussionRunnerSpy()
        let lingering: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = { request, delta, _ in
            stopSpy.record(request)
            delta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { stopSpy.recordCancellation(); throw error }
            return try CLICompletion.Result(text: "late", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        let stopping = DiscussionsHost(project: project, showTab: {}, runner: lingering)
        defer { stopping.close() }
        stopping.projectOpened(root)
        stopping.ask(slug, question: "Long one")
        try await expectEventually { stopping.store.live?.text == "Partial " }
        stopping.stop()
        try await expectEventually { stopping.store.asking == nil }
        XCTAssertEqual(stopSpy.cancellationCount, 1)
        XCTAssertNil(stopping.store.live)
        XCTAssertNil(stopping.store.lastError)
        XCTAssertEqual(stopping.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        stopping.ask(slug, question: "Again")
        try await expectEventually { stopping.store.live?.text == "Partial " }
        stopping.projectClosed()
        try await expectEventually { stopSpy.cancellationCount == 2 }
        XCTAssertNil(stopping.store.root)
        XCTAssertNil(stopping.store.asking)
        stopping.projectOpened(root)
        XCTAssertEqual(stopping.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        let closeSpy = DiscussionRunnerSpy()
        let closing = DiscussionsHost(project: project, showTab: {}, runner: { request, delta, _ in
            closeSpy.record(request)
            delta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { closeSpy.recordCancellation(); throw error }
            return try CLICompletion.Result(text: "late", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        closing.projectOpened(root)
        closing.ask(slug, question: "Long one")
        try await expectEventually { closing.store.live?.text == "Partial " }
        closing.close()
        try await expectEventually { closeSpy.cancellationCount == 1 }

        let file = root.appendingPathComponent("Sources/App.swift")
        host.discuss(about: file)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(host.store.selected?.scope, "Sources/App.swift")
        XCTAssertEqual(host.store.selected?.title, "App.swift")
        let count = host.store.discussions.count
        host.discuss(about: file)
        XCTAssertEqual(host.store.discussions.count, count)
        host.discuss(about: outside)
        XCTAssertEqual(host.store.selected?.scope, outside.path)
        project.fileTree.rootNode = nil
        let countOpened = opened
        host.discuss(about: file)
        XCTAssertEqual(opened, countOpened)
    }

    @MainActor func testRealDeploymentHostApprovalAndAssistantRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deployment-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let assistant = RoutingAssistant()
        let host = DeploymentsHost(project: window.project, assistants: assistant, showTab: {})
        defer { host.close() }
        host.analyzeWithAI()
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertTrue(assistant.prompts[0].submit)
        XCTAssertTrue(assistant.prompts[0].text.contains(root.lastPathComponent))
        assistant.assistantIsBusy = true
        host.analyzeWithAI()
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertEqual(host.store.lastError, "The assistant is still working.")
        host.projectOpened(root)
        host.store.add(DeploymentEnvironment(id: "prod", name: "Production", kind: .local))
        host.store.lastError = nil
        let prod = try XCTUnwrap(host.store.selected)
        host.askAssistant(prod, question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertEqual(host.store.lastError, "The assistant is still working.")
        assistant.assistantIsBusy = false
        host.askAssistant("missing", question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 1)
        host.askAssistant(prod, question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 2)
        XCTAssertTrue(assistant.prompts[1].text.contains("Is it up?"))

        let polling = PollingScheduler()
        host.store.polling = polling
        host.store.autoRefresh = true
        XCTAssertEqual(polling.keys.count, 1)
        let command = "touch \(root.path)/never.txt"
        let asked = Task { await host.store.run(command, on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.store.approval)
        XCTAssertEqual(host.store.tasks.activeCount, 1)
        host.store.answer(false)
        guard case .denied = await asked.value else { return XCTFail("The refused command was not denied") }
        XCTAssertEqual(host.store.tasks.activeCount, 0)
        let closing = Task { await host.store.run(command, on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.store.approval)
        host.close()
        guard case .denied = await closing.value else { return XCTFail("Closing did not deny the pending command") }
        XCTAssertNil(host.store.approval)
        XCTAssertEqual(host.store.tasks.activeCount, 0)
        XCTAssertTrue(polling.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("never.txt").path))
    }

    @MainActor func testRealStudioWindowServices() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("studio-services-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = root.appendingPathComponent("note.md")
        let stray = outside.appendingPathComponent("stray.md")
        try "Note".write(to: note, atomically: true, encoding: .utf8)
        try "Stray".write(to: stray, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let opened = try await window.project.openDatabase(at: root)
        XCTAssertTrue(opened)
        let database = try XCTUnwrap(window.project.database)
        window.toolTabs.open(.uiStudio)
        guard case .uiStudio(let studio)? = window.tabs.activeTab?.kind else { return XCTFail("UI Studio was not opened") }
        await window.tabs.openTextFile(note)
        await window.tabs.openTextFile(stray)
        XCTAssertTrue(studio.editorBuffers().isEmpty)
        for tab in window.tabs.openTabs where tab.isFileBacked {
            window.tabs.updateTabContent("Edited", documentID: tab.id)
        }
        XCTAssertEqual(studio.editorBuffers(), ["note.md": "Edited"])
        window.project.fileTree.rootNode = FileNode(url: outside, isDirectory: true)
        XCTAssertEqual(studio.editorBuffers(), ["note.md": "Edited"], "The session retains its original root")
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        studio.recordUsage(10, 20, 0.5)
        studio.recordUsage(1, 2, 0.25)
        var usage = await database.getUsageStats()
        for _ in 0..<200 where usage.totalJobs < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
            usage = await database.getUsageStats()
        }
        XCTAssertEqual(usage.totalJobs, 2)
        XCTAssertEqual(usage.totalInputTokens, 11)
        XCTAssertEqual(usage.totalOutputTokens, 22)
        XCTAssertEqual(usage.totalCostCents, 75, accuracy: 0.001)
        studio.openFile(note)
        for _ in 0..<200 where window.tabs.activeTab?.url != note {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(window.tabs.activeTab?.url, note)
        studio.windowServices?.studioDidExportFeature("feature-one")
        XCTAssertEqual(window.layout.issuesFeature, "feature-one")
        XCTAssertTrue(studio.featureStore() === window.flow.features)
        await studio.close()
    }

    @MainActor func testRealPrototypeStudioRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prototype-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.toolTabs.prototypes
        XCTAssertTrue(host.saved().isEmpty)
        let manifest = PrototypeFiles.Manifest(title: "Support Desk", slug: "support-desk", brief: "", sources: [], version: 3,
                                               approved: true, history: [.init(version: 3, instruction: "", summary: "", date: Date())])
        try PrototypeFiles.saveManifest(manifest, in: PrototypeFiles.folder(root: root, slug: manifest.slug))
        XCTAssertEqual(host.saved().map(\.label), ["Support Desk · v3 · approved"])

        host.openCreator(mode: .requirements)
        XCTAssertTrue(window.requests.showPrototypeCreator)
        XCTAssertEqual(window.requests.prototypeCreatorMode, .requirements)
        window.requests.showPrototypeCreator = false
        host.openCreator(mode: .code)
        XCTAssertFalse(window.requests.showPrototypeCreator)
        let studios = window.tabs.openTabs.filter { if case .uiStudio = $0.kind { return true }; return false }
        XCTAssertEqual(studios.count, 1)
        guard let studioTab = studios.first, case .uiStudio(let studio) = studioTab.kind else {
            return XCTFail("UI Studio was not opened")
        }

        host.openSaved(manifest.slug)
        guard case .prototype? = window.tabs.activeTab?.kind else { return XCTFail("Saved prototype was not opened") }
        let count = window.tabs.openTabs.count
        window.tabs.activeTabIndex = 0
        host.openSaved(manifest.slug)
        XCTAssertEqual(window.tabs.openTabs.count, count)
        guard case .prototype? = window.tabs.activeTab?.kind else { return XCTFail("Saved prototype was not selected") }

        host.create(title: "Admin", brief: "An admin console", sources: ["docs"])
        guard case .prototype(let created)? = window.tabs.activeTab?.kind else { return XCTFail("New prototype was not opened") }
        XCTAssertEqual(created.manifest.title, "Admin")
        XCTAssertEqual(created.manifest.brief, "An admin console")
        XCTAssertEqual(created.manifest.sources, ["docs"])
        host.create(title: "From code", brief: "", sources: [], mode: .code)
        XCTAssertEqual(window.tabs.openTabs.filter { if case .prototype = $0.kind { return true }; return false }.count, 2)
        await studio.close()
    }

    @MainActor func testRealWindowCompositionConstructsPartsOnDemand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-lazy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let composition = window.composition
        func isConstructed(_ name: String) throws -> Bool {
            let stored = try XCTUnwrap(Mirror(reflecting: composition).children.first { $0.label?.hasSuffix("_" + name) == true })
            let value = Mirror(reflecting: stored.value)
            XCTAssertEqual(value.displayStyle, .optional, "Lazy storage for \(name) must be observable as an optional")
            return !value.children.isEmpty
        }
        for name in ["research", "terminals", "flow", "codeXRay"] {
            XCTAssertTrue(try isConstructed(name), "Connecting the window constructs \(name)")
        }
        for name in ["browser", "toolTabs", "fileOperations", "translator", "insight"] {
            XCTAssertFalse(try isConstructed(name), "An unused \(name) is not constructed")
        }
        let browser = composition.browser
        XCTAssertTrue(try isConstructed("browser"))
        XCTAssertTrue(browser === composition.browser, "The same browser host is reused")
        XCTAssertFalse(try isConstructed("toolTabs"), "Opening the browser does not construct the tool tabs")
    }

    @MainActor func testRealWindowCompositionSharesPrompts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-prompts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompts = ScriptedPrompts()
        let window = WorkspaceManager(prompts: prompts, recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let composition = window.composition
        for component in [composition.project as AnyObject, composition.tabs, composition.terminals,
                          composition.browser, composition.codeXRay, composition.insight] {
            let injected = try XCTUnwrap(Mirror(reflecting: component).children.first { $0.label == "prompts" }?.value as? any UserPrompts)
            XCTAssertTrue(injected as AnyObject === prompts, "Each real component receives the window's prompt handler")
        }
        let document = root.appendingPathComponent("document.md")
        try "before".write(to: document, atomically: true, encoding: .utf8)
        await composition.tabs.openTextFile(document)
        let id = try XCTUnwrap(composition.tabs.activeTab?.id)
        composition.tabs.updateTabContent("changed", documentID: id)
        prompts.script = [.press("Cancel"), .press("Don't Save")]
        composition.tabs.closeTab(at: 0)
        XCTAssertEqual(composition.tabs.openTabs.count, 1)
        composition.tabs.closeTab(at: 0)
        XCTAssertTrue(composition.tabs.openTabs.isEmpty)
        XCTAssertEqual(prompts.titles, ["Save changes?", "Save changes?"])
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "before")
    }

    @MainActor func testRealWindowCompositionSharesWindowParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-parts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        let parts = window.composition
        func check(_ owner: AnyObject, _ field: String, _ expected: AnyObject, line: UInt = #line) throws {
            let actual = try XCTUnwrap(Mirror(reflecting: owner).children.first { $0.label == field }?.value, line: line)
            XCTAssertTrue(actual as AnyObject === expected, "\(type(of: owner)).\(field) must use this window's component", line: line)
        }
        try check(parts.terminals, "projectContext", parts.project)
        try check(parts.terminals.activity, "tasks", parts.taskBag)
        try check(parts.terminals.activity, "polling", parts.polling)
        XCTAssertFalse(window.chrome.agentsVisible)
        parts.terminals.showAIConsole()
        XCTAssertTrue(window.chrome.agentsVisible, "The terminal controller calls its own window host")
        try check(parts.research, "project", parts.project)
        try check(parts.research, "tasks", parts.taskBag)
        try check(parts.flow, "project", parts.project)
        try check(parts.flow, "assistants", parts.terminals)
        try check(parts.flow, "tabs", window)
        try check(parts.flow, "gitClient", parts.gitClient)
        try check(parts.flow, "research", parts.research)
        try check(parts.browser, "project", parts.project)
        try check(parts.browser, "tabs", parts.tabs)
        try check(parts.browser, "terminals", parts.terminals)
        try check(parts.codeXRay, "project", parts.project)
        try check(parts.insight, "project", parts.project)
        try check(parts.insight, "tasks", parts.taskBag)
        try check(parts.translator, "project", parts.project)
        try check(parts.translator, "tabs", parts.tabs)
        try check(parts.translator, "tasks", parts.taskBag)
        try check(parts.fileOperations, "project", parts.project)
        try check(parts.fileOperations, "tabs", parts.tabs)
        try check(parts.fileOperations, "tasks", parts.taskBag)
        try check(parts.toolTabs, "project", parts.project)
        try check(parts.toolTabs, "tabs", parts.tabs)
        try check(parts.toolTabs, "terminals", parts.terminals)
        XCTAssertTrue(parts.toolTabs.features === parts.flow.features)
    }
}
