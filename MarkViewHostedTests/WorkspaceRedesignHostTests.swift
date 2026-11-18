import Foundation
import AppKit
import Combine
import CoreText
import PDFKit
import SQLite3
import MarkViewCore
import XCTest
@testable import MarkView

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
