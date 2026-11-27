import Foundation
import MarkViewCore
import SQLite3
import XCTest
@testable import MarkView

private extension SemanticDatabase {
    func fixtureTotalChanges() -> Int32 { sqlite3_total_changes(db) }
    func fixtureReviewCount() -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM arch_reviews", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(statement, 0)
    }
}

private final class WeakXRayDatabase {
    weak var value: SemanticDatabase?
}

private actor XRayCancellationFixture {
    enum Mode { case wait, answer, review, fail }
    private var mode: Mode = .wait
    private var requested: [String] = []
    private var cancelled: [String] = []
    private var deltas: [String: [String]] = [:]
    private var holdCancellation = false
    private var cancellationEntries = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func answerNextCalls() { mode = .answer }
    func failNextCalls() { mode = .fail }
    func waitForCalls() { mode = .wait }
    func reviewNextCalls() { mode = .review }
    func stream(_ pieces: [String], for label: String) { deltas[label] = pieces }
    func holdCancellations() { holdCancellation = true }
    func cancellationEntryCount() -> Int { cancellationEntries }
    func releaseCancellations() {
        holdCancellation = false
        let waiters = cancellationWaiters
        cancellationWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    func requests(_ label: String) -> Int { requested.filter { $0 == label }.count }
    func cancellations(_ label: String) -> Int { cancelled.filter { $0 == label }.count }
    func requestCount() -> Int { requested.count }
    func cancellationCount() -> Int { cancelled.count }

    func run(_ request: CLICompletion.Request, onDelta: (@Sendable (String) -> Void)?) async throws -> CLICompletion.Result {
        requested.append(request.label)
        for piece in deltas[request.label] ?? [] { onDelta?(piece) }
        if mode == .fail { throw NSError(domain: "XRayFixture", code: 1) }
        if mode == .review {
            let object: [String: Any] = ["summary": "Fixture review", "files": [[
                "path": "Sources/App/Model.swift", "verdict": "concern", "risk": "low", "summary": "Fixture concern",
                "findings": [["line": 1, "severity": "warning", "message": "Fixture finding"]],
            ]]]
            return try CLICompletion.Result(text: "", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        if mode == .answer {
            let object: [String: Any] = ["summary": "A fixture model.", "sections": [[
                "startLine": 1, "endLine": 2, "title": "Model", "explanation": "A model.", "importance": "normal",
            ]]]
            return try CLICompletion.Result(text: "A fixture answer.", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        do { try await Task.sleep(nanoseconds: 120_000_000_000) }
        catch {
            if holdCancellation {
                cancellationEntries += 1
                await withCheckedContinuation { cancellationWaiters.append($0) }
            }
            cancelled.append(request.label)
            throw error
        }
        throw CancellationError()
    }
}

/// Answers the book's chapter calls at once and holds each "parts" call until a second one is running (or a few seconds have
/// passed), so a run that makes the parts calls one after another never has two of them in flight.
private actor XRayBookPartsFixture {
    private var running = 0
    private(set) var peak = 0
    private(set) var partsCalls = 0

    func run(_ request: CLICompletion.Request) async throws -> CLICompletion.Result {
        guard request.label == "xray-book:parts" else {
            let object: [String: Any] = ["chapter": ["summary": "What \(request.label) says."], "sections": []]
            return try CLICompletion.Result(text: "", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        partsCalls += 1
        running += 1
        peak = max(peak, running)
        for _ in 0..<150 where running < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        running -= 1
        let ids = request.prompt.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- ") else { return nil }
            return line.dropFirst(2).split(separator: " ").first.map(String.init)
        }
        var object: [String: Any] = ["parts": ids.map { ["id": $0, "summary": "Blurb of \($0)"] }]
        if request.systemPrompt?.contains("the BOOK itself") == true { object["book"] = ["summary": "The whole book."] }
        return try CLICompletion.Result(text: "", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
}

/// Explains a file at once, then holds the keyword search and the rating of a topic filter until both are with it (or a few
/// seconds have passed), so a rating that waits for the search never has both in flight.
private actor CodeRatingFixture {
    private var running = 0
    private(set) var peak = 0

    func run(_ request: CLICompletion.Request) async throws -> CLICompletion.Result {
        if request.label == "explain-file" {
            let sections: [[String: Any]] = [
                ["startLine": 1, "endLine": 1, "title": "Model", "explanation": "The model.", "importance": "normal"],
                ["startLine": 2, "endLine": 2, "title": "Value", "explanation": "A value.", "importance": "normal"],
            ]
            return try CLICompletion.Result(text: "", structured: ["summary": "A model file.", "sections": sections],
                                            inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        running += 1
        peak = max(peak, running)
        for _ in 0..<150 where running < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        running -= 1
        let object: [String: Any] = request.prompt.hasPrefix("Criterion:")
            ? ["terms": ["model", "struct"]]
            : ["ratings": [["key": "s1", "level": "strong", "reason": "Declares the model."],
                           ["key": "s2", "level": "none", "reason": "A plain value."]]]
        return try CLICompletion.Result(text: "", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
}

private final class XRayNavigationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func containsStopped(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains { value in
            guard let data = value.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return event["id"] as? String == id && event["stopped"] as? Bool == true
        }
    }
}

extension EditorHostTests {
    @MainActor func testRealXRayChangeReviewCancellationAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-review-" + UUID().uuidString, isDirectory: true)
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let weakDB = WeakXRayDatabase()
        defer { if weakDB.value == nil { try? FileManager.default.removeItem(at: root) } }
        let file = sources.appendingPathComponent("Model.swift")
        try "struct Model { var id = 1 }\n".write(to: file, atomically: true, encoding: .utf8)
        func git(_ arguments: [String]) async throws {
            let common = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
            let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
            let removed: Set<String> = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"]
            let result = await Subprocess.run(.init(executable: "/usr/bin/git", arguments: common + arguments, cwd: root,
                                                    environment: environment, removedEnvironment: removed))
            guard result.succeeded else { throw NSError(domain: "XRayGitFixture", code: Int(result.exitCode)) }
        }
        try await git(["init", "-q", "-b", "main"])
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "first"])
        try "struct Model { var id = 2 }\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["commit", "-q", "-am", "second"])
        try "struct Model { var id = 3 }\n".write(to: file, atomically: true, encoding: .utf8)
        let settings = Settings.standard
        let oldAuto = settings.stored(Setting.autoAnalyze)
        let oldGitHub = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.autoAnalyze)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            settings.set(oldAuto, for: Setting.autoAnalyze)
            settings.set(oldGitHub, for: Setting.gitHubEnabled)
        }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        do {
            let database = try await SemanticDatabase.open(workspacePath: root)
            weakDB.value = database
            let store = ArchitectureStore()
            defer { store.reset() }
            store.open(root: root, db: database)
            for _ in 0..<1000 {
                if store.snapshot != nil && !store.isBusy && store.review.prSources.contains(where: { $0.id == "local" }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(store.review.prSources.contains { $0.id == "local" })
            let review = store.review
            review.showPR("local", root: root, db: database)
            review.showComparison(id: "cmp:HEAD~1", title: "Prior commit", root: root, db: database)
            for _ in 0..<1000 {
                if review.prOverlay?.source.id == "cmp:HEAD~1" { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(review.prOverlay?.source.id, "cmp:HEAD~1")
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            review.listHistory(day: today, root: root)
            review.listHistory(day: "1999-12-31", root: root)
            for _ in 0..<1000 {
                if review.historyPicker?.state == "ready" && review.historyPicker?.day == "1999-12-31" { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(review.historyPicker?.day, "1999-12-31")
            XCTAssertEqual(review.historyPicker?.state, "ready")
            XCTAssertTrue(review.historyPicker?.commits.isEmpty == true)
            review.showPR("local", root: root, db: database)
            for _ in 0..<1000 {
                if review.prOverlay?.source.id == "local" && !store.isBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(review.prOverlay?.source.id, "local")
            review.reviewPR(root: root, db: database)
            for _ in 0..<500 {
                if await fixture.requests("xray-pr-review") == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let first = await fixture.requests("xray-pr-review")
            XCTAssertEqual(first, 1)
            XCTAssertTrue(store.isBusy)
            store.reset()
            for _ in 0..<500 {
                if await fixture.cancellations("xray-pr-review") == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let cancelled = await fixture.cancellations("xray-pr-review")
            let cancelledReviews = await database.fixtureReviewCount()
            XCTAssertEqual(cancelled, 1)
            XCTAssertEqual(cancelledReviews, 0)
            XCTAssertNil(review.prOverlay)
            XCTAssertFalse(store.isBusy)
            store.open(root: root, db: database)
            for _ in 0..<1000 {
                if store.snapshot != nil && !store.isBusy && review.prSources.contains(where: { $0.id == "local" }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            review.showPR("local", root: root, db: database)
            for _ in 0..<1000 {
                if review.prOverlay?.source.id == "local" && !store.isBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await fixture.reviewNextCalls()
            review.reviewPR(root: root, db: database)
            for _ in 0..<1000 {
                if review.prOverlay?.reviewed == true && !store.isBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(review.prOverlay?.reviewed, true)
            for _ in 0..<500 {
                if await database.fixtureReviewCount() == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let savedReviews = await database.fixtureReviewCount()
            XCTAssertEqual(savedReviews, 1)
            await fixture.waitForCalls()
            await fixture.stream(["Because ", "of this."], for: "xray-finding")
            review.explainFinding(path: "Sources/App/Model.swift", index: 0, db: database)
            for _ in 0..<500 {
                if await fixture.requests("xray-finding") == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let explanation = await fixture.requests("xray-finding")
            XCTAssertEqual(explanation, 1)
            for _ in 0..<500 {
                if review.prOverlay?.files.first(where: { $0.path == "Sources/App/Model.swift" })?.findings?.first?.explanation == "Because of this." { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(review.prOverlay?.files.first(where: { $0.path == "Sources/App/Model.swift" })?.findings?.first?.explanation, "Because of this.")
            store.reset()
            for _ in 0..<500 {
                if await fixture.cancellations("xray-finding") == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let explanationCancelled = await fixture.cancellations("xray-finding")
            XCTAssertEqual(explanationCancelled, 1)
            try await Task.sleep(nanoseconds: 200_000_000)
            let afterReset = await database.fixtureReviewCount()
            XCTAssertEqual(afterReset, 1)
            store.open(root: root, db: database)
            for _ in 0..<1000 {
                if store.snapshot != nil && !store.isBusy && review.prSources.contains(where: { $0.id == "local" }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            review.showPR("local", root: root, db: database)
            for _ in 0..<1000 {
                if review.prOverlay?.source.id == "local" && !store.isBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let previousRequests = await fixture.requestCount()
            let previousCancellations = await fixture.cancellationCount()
            review.analyzePR(root: root, db: database)
            for _ in 0..<500 {
                if await fixture.requestCount() > previousRequests { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let analysisRequests = await fixture.requestCount()
            XCTAssertGreaterThan(analysisRequests, previousRequests)
            store.reset()
            for _ in 0..<500 {
                if await fixture.cancellationCount() > previousCancellations { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let analysisCancellations = await fixture.cancellationCount()
            XCTAssertGreaterThan(analysisCancellations, previousCancellations)
            XCTAssertNil(review.prOverlay)
            XCTAssertNil(store.status)
        }
        for _ in 0..<500 where weakDB.value != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(weakDB.value, "SQLite must close before its fixture is removed")
    }

    @MainActor func testRealXRayFilterReplacementAndFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-filter-" + UUID().uuidString, isDirectory: true)
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "struct Model { var id = 1 }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
        try "struct ViewThing { let model = Model() }\n".write(to: sources.appendingPathComponent("ViewThing.swift"), atomically: true, encoding: .utf8)
        let settings = Settings.standard
        let oldAuto = settings.stored(Setting.autoAnalyze)
        let oldGitHub = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.autoAnalyze)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            settings.set(oldAuto, for: Setting.autoAnalyze)
            settings.set(oldGitHub, for: Setting.gitHubEnabled)
        }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let store = ArchitectureStore()
        defer { store.reset() }
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.snapshot)
        let filters = store.filters
        let first = ImportanceRater.Filter(id: "question", name: "Question", criterion: "where is the model", levels: ["strong", "none"])
        let second = ImportanceRater.Filter(id: "question", name: "Question", criterion: "how are views drawn", levels: ["strong", "none"])
        filters.understand(filter: first, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("understand-scope") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstRequests = await fixture.requests("understand-scope")
        XCTAssertEqual(firstRequests, 1)
        XCTAssertEqual(filters.understandingAnswers["question"]?.state, "loading")
        filters.understand(filter: second, root: root, db: nil)
        for _ in 0..<500 {
            let requests = await fixture.requests("understand-scope")
            let cancellations = await fixture.cancellations("understand-scope")
            if requests == 2 && cancellations == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await fixture.requests("understand-scope")
        let cancelled = await fixture.cancellations("understand-scope")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(filters.understandingAnswers["question"]?.question, "how are views drawn")
        XCTAssertEqual(filters.understandingAnswers["question"]?.state, "loading")
        filters.forgetRatings(filterId: "question", db: nil)
        for _ in 0..<500 {
            if await fixture.cancellations("understand-scope") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let forgotten = await fixture.cancellations("understand-scope")
        XCTAssertEqual(forgotten, 2)
        XCTAssertNil(filters.understandingAnswers["question"])
        await fixture.failNextCalls()
        filters.understand(filter: first, root: root, db: nil)
        for _ in 0..<1000 {
            if filters.understandingAnswers["question"]?.state == "failed" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(filters.understandingAnswers["question"]?.state, "failed")
        let failedAnswers = await fixture.requests("understand")
        XCTAssertGreaterThan(failedAnswers, 0, "Scope failure falls back to the answer call")
        await fixture.waitForCalls()
        filters.understand(filter: second, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("understand-scope") >= 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let beforeReset = await fixture.requests("understand-scope")
        XCTAssertGreaterThanOrEqual(beforeReset, 4)
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("understand-scope") == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let afterReset = await fixture.cancellations("understand-scope")
        XCTAssertEqual(afterReset, 3)
        XCTAssertTrue(filters.understandingAnswers.isEmpty)
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let search = try XCTUnwrap(ImportanceRater.temporaryFilter(for: "model flow"))
        filters.temporaryFilter = search
        let previousRequests = await fixture.requestCount()
        let previousCancellations = await fixture.cancellationCount()
        filters.searchFilter(filterId: search.id, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requestCount() > previousRequests { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let searchRequests = await fixture.requestCount()
        XCTAssertGreaterThan(searchRequests, previousRequests)
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellationCount() > previousCancellations { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let searchCancellations = await fixture.cancellationCount()
        XCTAssertGreaterThan(searchCancellations, previousCancellations)
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        filters.searchFilter(filterId: search.id, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requestCount() > searchRequests { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retryRequests = await fixture.requestCount()
        XCTAssertGreaterThan(retryRequests, searchRequests)
        store.reset()
    }

    @MainActor func testRealXRayProjectSwitchDoesNotWriteOldDatabase() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xray-databases-" + UUID().uuidString, isDirectory: true)
        let alpha = base.appendingPathComponent("alpha", isDirectory: true)
        let beta = base.appendingPathComponent("beta", isDirectory: true)
        for root in [alpha, beta] {
            let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "struct Model { var id = 1 }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
            try "struct ViewThing { let model = Model() }\n".write(to: sources.appendingPathComponent("ViewThing.swift"), atomically: true, encoding: .utf8)
        }
        let weakAlpha = WeakXRayDatabase(), weakBeta = WeakXRayDatabase()
        defer {
            if weakAlpha.value == nil && weakBeta.value == nil { try? FileManager.default.removeItem(at: base) }
        }
        let settings = Settings.standard
        let oldAuto = settings.stored(Setting.autoAnalyze)
        let oldGitHub = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.autoAnalyze)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            settings.set(oldAuto, for: Setting.autoAnalyze)
            settings.set(oldGitHub, for: Setting.gitHubEnabled)
        }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        do {
            let alphaDB = try await SemanticDatabase.open(workspacePath: alpha)
            let betaDB = try await SemanticDatabase.open(workspacePath: beta)
            weakAlpha.value = alphaDB
            weakBeta.value = betaDB
            let store = ArchitectureStore()
            defer { store.reset() }
            store.open(root: alpha, db: alphaDB)
            for _ in 0..<1000 {
                let persisted = await alphaDB.loadArchitecture()
                if store.snapshot != nil && !store.isBusy && persisted != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let initial = await alphaDB.loadArchitecture()
            XCTAssertNotNil(initial)
            store.analyze(root: alpha, db: alphaDB)
            for _ in 0..<1000 {
                if await fixture.requestCount() > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let requests = await fixture.requestCount()
            XCTAssertGreaterThan(requests, 0)
            store.reset()
            for _ in 0..<500 {
                if await fixture.cancellationCount() > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let cancellations = await fixture.cancellationCount()
            XCTAssertGreaterThan(cancellations, 0)
            try await Task.sleep(nanoseconds: 200_000_000)
            let oldChanges = await alphaDB.fixtureTotalChanges()
            store.open(root: beta, db: betaDB)
            for _ in 0..<1000 {
                let persisted = await betaDB.loadArchitecture()
                if store.snapshot != nil && !store.isBusy && persisted != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let newSnapshot = await betaDB.loadArchitecture()
            XCTAssertNotNil(newSnapshot)
            XCTAssertEqual(store.snapshot?.view("modules")?.nodes.first { $0.kind == "root" }?.name, "beta")
            try await Task.sleep(nanoseconds: 500_000_000)
            let afterSwitch = await alphaDB.fixtureTotalChanges()
            XCTAssertEqual(afterSwitch, oldChanges, "A cancelled analysis must not write to the previous project's database")
        }
        for _ in 0..<500 where weakAlpha.value != nil || weakBeta.value != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakAlpha.value, "The first SQLite database must close before its fixture is removed")
        XCTAssertNil(weakBeta.value, "The second SQLite database must close before its fixture is removed")
    }

    @MainActor func testRealXRayAnalysisStopsAcrossProjectChange() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xray-switch-" + UUID().uuidString, isDirectory: true)
        let alpha = base.appendingPathComponent("alpha", isDirectory: true)
        let beta = base.appendingPathComponent("beta", isDirectory: true)
        for root in [alpha, beta] {
            let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "struct Model { var id = 1 }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
            try "struct ViewThing { let model = Model() }\n".write(to: sources.appendingPathComponent("ViewThing.swift"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let settings = Settings.standard
        let oldAuto = settings.stored(Setting.autoAnalyze)
        let oldGitHub = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.autoAnalyze)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            settings.set(oldAuto, for: Setting.autoAnalyze)
            settings.set(oldGitHub, for: Setting.gitHubEnabled)
        }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let store = ArchitectureStore()
        defer { store.reset() }
        store.open(root: alpha, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.snapshot)
        await fixture.failNextCalls()
        store.analyze(root: alpha, db: nil)
        for _ in 0..<1000 {
            if await fixture.requestCount() > 0 && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let failedRequests = await fixture.requestCount()
        XCTAssertGreaterThan(failedRequests, 0)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(store.error?.hasPrefix("Analysis failed") == true)
        await fixture.waitForCalls()
        store.analyze(root: alpha, db: nil)
        for _ in 0..<1000 {
            if await fixture.requestCount() > failedRequests { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await fixture.requestCount()
        XCTAssertGreaterThan(requests, failedRequests)
        XCTAssertTrue(store.isBusy)
        store.reset()
        let newLease = store.beginRun()
        for _ in 0..<500 {
            if await fixture.cancellationCount() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancellations = await fixture.cancellationCount()
        XCTAssertGreaterThan(cancellations, 0)
        XCTAssertTrue(store.isBusy, "The old task must not release the new run's lease")
        store.endRun(newLease)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.snapshot)
        store.open(root: beta, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.rootPath, beta.standardizedFileURL.path)
        XCTAssertEqual(store.snapshot?.view("modules")?.nodes.first { $0.kind == "root" }?.name, "beta")
    }

    @MainActor func testRealXRayEdgeAndNodeCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-edge-" + UUID().uuidString, isDirectory: true)
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "struct Model { var id = 1 }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
        try "struct ViewThing { let model = Model() }\n".write(to: sources.appendingPathComponent("ViewThing.swift"), atomically: true, encoding: .utf8)
        let settings = Settings.standard
        let oldAuto = settings.stored(Setting.autoAnalyze)
        let oldGitHub = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.autoAnalyze)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            settings.set(oldAuto, for: Setting.autoAnalyze)
            settings.set(oldGitHub, for: Setting.gitHubEnabled)
        }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let store = ArchitectureStore()
        defer { store.reset() }
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let nodes = try XCTUnwrap(store.snapshot?.view("modules")?.nodes.filter { $0.kind == "file" })
        guard nodes.count >= 2 else { XCTFail("The scan must find both source files"); return }
        let source = nodes[0].id, target = nodes[1].id
        let key = "modules|\(source)|\(target)"
        store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("xray-link") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let first = await fixture.requests("xray-link")
        XCTAssertEqual(first, 1)
        store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: root, db: nil, fresh: true)
        for _ in 0..<500 {
            let requests = await fixture.requests("xray-link")
            let cancellations = await fixture.cancellations("xray-link")
            if requests == 2 && cancellations == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let replacements = await fixture.requests("xray-link")
        let firstCancelled = await fixture.cancellations("xray-link")
        XCTAssertEqual(replacements, 2)
        XCTAssertEqual(firstCancelled, 1)
        XCTAssertEqual(store.edgeNotes[key]?.pending, true)
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("xray-link") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let allCancelled = await fixture.cancellations("xray-link")
        XCTAssertEqual(allCancelled, 2)
        XCTAssertTrue(store.edgeNotes.isEmpty)
        XCTAssertNil(store.snapshot)
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await fixture.stream(["a", "b", "c"], for: "xray-link")
        let revision = store.revision
        store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: root, db: nil, fresh: true)
        for _ in 0..<500 {
            if store.edgeNotes[key]?.text == "abc" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.edgeNotes[key]?.text, "abc")
        XCTAssertGreaterThan(store.revision, revision)
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("xray-link") == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let streamCancelled = await fixture.cancellations("xray-link")
        XCTAssertEqual(streamCancelled, 3)
        let afterReset = store.revision
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(store.revision, afterReset, "A delayed streaming refresh must not update a closed project")
        XCTAssertTrue(store.edgeNotes.isEmpty)
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await fixture.stream([], for: "xray-link")
        await fixture.answerNextCalls()
        store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: root, db: nil, fresh: true)
        for _ in 0..<500 {
            if store.edgeNotes[key]?.pending == false { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.edgeNotes[key]?.pending, false)
        XCTAssertEqual(store.edgeNotes[key]?.text, "A fixture answer.")
        await fixture.waitForCalls()
        let node = try XCTUnwrap(store.snapshot?.view("modules")?.nodes.first { $0.kind == "file" })
        store.describe(viewId: "modules", nodeId: node.id, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("xray-describe") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let describe = await fixture.requests("xray-describe")
        XCTAssertEqual(describe, 1)
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("xray-describe") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let describeCancelled = await fixture.cancellations("xray-describe")
        XCTAssertEqual(describeCancelled, 1)
        XCTAssertNil(store.snapshot)
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        store.describe(viewId: "modules", nodeId: node.id, root: root, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("xray-describe") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retried = await fixture.requests("xray-describe")
        XCTAssertEqual(retried, 2)
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("xray-describe") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retriedCancelled = await fixture.cancellations("xray-describe")
        XCTAssertEqual(retriedCancelled, 2)
    }

    @MainActor func testRealCodeExplanationCancellationAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-explain-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let store = CodeExplainStore()
        defer { store.reset() }
        let path = "Sources/Model.swift"
        let content = "struct Model {}\nvar value = 1\n"
        store.explain(path: path, content: content, root: root, directory: directory, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("explain-file") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstRequests = await fixture.requests("explain-file")
        XCTAssertEqual(firstRequests, 1)
        XCTAssertTrue(store.working.contains(path))
        await fixture.holdCancellations()
        defer { Task { await fixture.releaseCancellations() } }
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellationEntryCount() == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await fixture.cancellationEntryCount()
        XCTAssertEqual(entered, 1)
        XCTAssertTrue(store.working.isEmpty)
        XCTAssertTrue(store.explanations.isEmpty)
        store.explain(path: path, content: content, root: root, directory: directory, db: nil)
        for _ in 0..<500 {
            if await fixture.requests("explain-file") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let replacementRequests = await fixture.requests("explain-file")
        XCTAssertEqual(replacementRequests, 2)
        await fixture.releaseCancellations()
        for _ in 0..<500 {
            if await fixture.cancellations("explain-file") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelled = await fixture.cancellations("explain-file")
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(store.working.contains(path), "The older cancelled task must not clear its replacement's state")
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("explain-file") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let bothCancelled = await fixture.cancellations("explain-file")
        XCTAssertEqual(bothCancelled, 2)
        XCTAssertTrue(store.working.isEmpty)
        XCTAssertTrue(store.explanations.isEmpty)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
        await fixture.answerNextCalls()
        store.explain(path: path, content: content, root: root, directory: directory, db: nil)
        for _ in 0..<500 {
            if store.explanations[path] != nil && !store.working.contains(path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.explanations[path]?.summary, "A fixture model.")
        XCTAssertFalse(store.working.contains(path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    @MainActor func testRealCodeNavigationCancellationAndReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-navigation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, delta, _ in try await fixture.run(request, onDelta: delta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let navigation = CodeNavigationStore()
        defer { navigation.reset() }
        let events = XRayNavigationEvents()
        let observer = NotificationCenter.default.addObserver(forName: .codeNavEvent, object: navigation, queue: .main) { note in
            if let json = note.userInfo?["json"] as? String { events.append(json) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let sourceFolder = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let url = sourceFolder.appendingPathComponent("Model.swift")
        try "import Foundation\nstruct Model {}\n".write(to: url, atomically: true, encoding: .utf8)
        try "import Foundation\nstruct ViewThing { let model = Model() }\n"
            .write(to: sourceFolder.appendingPathComponent("ViewThing.swift"), atomically: true, encoding: .utf8)
        var opened: [String] = []
        let open: (URL, Int) -> Void = { url, _ in opened.append(url.lastPathComponent) }
        navigation.goToDefinition(name: "Model", line: 1, url: url, path: "Sources/App/Model.swift", root: root, open: open)
        navigation.goToDefinition(name: "ViewThing", line: 1, url: url, path: "Sources/App/Model.swift", root: root, open: open)
        for _ in 0..<500 where opened.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(opened, ["ViewThing.swift"], "The latest symbol lookup wins")
        let beforeUsage = events.count()
        navigation.findUsages(name: "Model", url: url, path: "Sources/App/Model.swift", root: root)
        navigation.reset()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(events.count(), beforeUsage, "A lookup cancelled on close must not send results")
        func ask(_ id: String, question: String) {
            navigation.ask(id: id, question: question, snippet: "struct Model {}", start: 1, end: 1, path: "Sources/App/Model.swift",
                           language: "swift", history: [], url: url, root: root, db: nil)
        }
        ask("q1", question: "Why?")
        for _ in 0..<500 {
            if await fixture.requests("code-question") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstRequests = await fixture.requests("code-question")
        XCTAssertEqual(firstRequests, 1)
        navigation.stopAnswer(id: "q1")
        for _ in 0..<500 {
            if await fixture.cancellations("code-question") == 1 && events.containsStopped("q1") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let firstCancelled = await fixture.cancellations("code-question")
        XCTAssertEqual(firstCancelled, 1)
        XCTAssertTrue(events.containsStopped("q1"))
        ask("q2", question: "First")
        for _ in 0..<500 {
            if await fixture.requests("code-question") == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        ask("q2", question: "Replacement")
        for _ in 0..<500 {
            let requests = await fixture.requests("code-question")
            let cancellations = await fixture.cancellations("code-question")
            if requests == 3 && cancellations == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await fixture.requests("code-question")
        let replaced = await fixture.cancellations("code-question")
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(replaced, 2)
        navigation.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("code-question") == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelled = await fixture.cancellations("code-question")
        XCTAssertEqual(cancelled, 3)
    }

    /// The parts of a book are described by calls that do not depend on each other: they run side by side, and every part gets
    /// the blurb of its own call.
    @MainActor func testXRayBookPartsAreDescribedSideBySide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-book-parts-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // More parts than one call lists (`BookAnnotator.partsPerCall`), so the parts need two calls.
        let partCount = BookAnnotator.partsPerCall + 5
        for index in 1...partCount {
            let folder = root.appendingPathComponent(String(format: "part-%02d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "Plain notes about part \(index).\n".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        }
        let settings = Settings.standard
        let oldAuto = settings.stored(Setting.autoAnalyze)
        let oldGitHub = settings.stored(Setting.gitHubEnabled)
        settings.set(false, for: Setting.autoAnalyze)
        settings.set(false, for: Setting.gitHubEnabled)
        defer {
            settings.set(oldAuto, for: Setting.autoAnalyze)
            settings.set(oldGitHub, for: Setting.gitHubEnabled)
        }
        let fixture = XRayBookPartsFixture()
        AIAssistantRunner.setTestRunner { request, _, _ in try await fixture.run(request) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let store = ArchitectureStore()
        defer { store.reset() }
        store.open(root: root, db: nil)
        for _ in 0..<1000 {
            if store.snapshot?.view("docs") != nil && !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.snapshot?.view("docs"))
        store.describeBook(path: nil, root: root, db: nil)
        for _ in 0..<3000 {
            if !store.isBusy, await fixture.partsCalls > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let calls = await fixture.partsCalls
        let peak = await fixture.peak
        XCTAssertEqual(calls, 2, "two calls describe the parts")
        XCTAssertEqual(peak, 2, "the parts calls run at the same time")
        let nodes = store.snapshot?.view("docs")?.nodes ?? []
        let parts = nodes.filter { $0.kind == "dir" }
        XCTAssertEqual(parts.count, partCount)
        XCTAssertTrue(parts.allSatisfy { $0.summary == "Blurb of \($0.id)" }, "every part has the blurb of its own call")
        XCTAssertEqual(nodes.first { $0.kind == "root" }?.summary, "The whole book.")
        XCTAssertNil(store.error)
    }

    /// A topic filter's rating is built from the sections alone: it runs while the keyword search does, and its levels replace the
    /// search's provisional ones.
    @MainActor func testCodeRatingRunsBesideItsKeywordSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-rate-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = CodeRatingFixture()
        AIAssistantRunner.setTestRunner { request, _, _ in try await fixture.run(request) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let store = CodeExplainStore()
        defer { store.reset() }
        let path = "Sources/Model.swift"
        let content = "struct Model {}\nvar value = 1\n"
        store.explain(path: path, content: content, root: root, directory: directory, db: nil)
        for _ in 0..<500 where store.explanations[path] == nil || store.working.contains(path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.explanations[path]?.sections.count, 2)
        let filter = ImportanceRater.Filter(id: "topic", name: "Topic", criterion: "where is the model", levels: ["strong", "none"])
        store.rate(path: path, content: content, filter: filter, root: root, directory: directory, db: nil)
        for _ in 0..<1000 where store.working.contains(path) { try await Task.sleep(nanoseconds: 10_000_000) }
        let peak = await fixture.peak
        XCTAssertEqual(peak, 2, "the rating is with the assistant while the keyword search is")
        let ratings = store.explanations[path]?.ratings["topic"]
        XCTAssertEqual(ratings?["s1"]?.level, "strong")
        XCTAssertEqual(ratings?["s1"]?.reason, "Declares the model.", "the rating replaces the provisional level")
        XCTAssertEqual(ratings?["s2"]?.level, "none")
    }
}
