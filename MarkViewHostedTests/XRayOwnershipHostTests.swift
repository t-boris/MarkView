import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

private actor XRayCancellationFixture {
    private var answer = false
    private var requested: [String] = []
    private var cancelled: [String] = []

    func answerNextCalls() { answer = true }
    func requests(_ label: String) -> Int { requested.filter { $0 == label }.count }
    func cancellations(_ label: String) -> Int { cancelled.filter { $0 == label }.count }

    func run(_ request: CLICompletion.Request) async throws -> CLICompletion.Result {
        requested.append(request.label)
        if answer {
            let object: [String: Any] = ["summary": "A fixture model.", "sections": [[
                "startLine": 1, "endLine": 2, "title": "Model", "explanation": "A model.", "importance": "normal",
            ]]]
            return try CLICompletion.Result(text: "A fixture answer.", structured: object, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        do { try await Task.sleep(nanoseconds: 120_000_000_000) }
        catch { cancelled.append(request.label); throw error }
        throw CancellationError()
    }
}

private final class XRayNavigationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
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
    @MainActor func testRealCodeExplanationCancellationAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-explain-" + UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = XRayCancellationFixture()
        AIAssistantRunner.setTestRunner { request, _, _ in try await fixture.run(request) }
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
        store.reset()
        for _ in 0..<500 {
            if await fixture.cancellations("explain-file") == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelled = await fixture.cancellations("explain-file")
        XCTAssertEqual(cancelled, 1)
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
        AIAssistantRunner.setTestRunner { request, _, _ in try await fixture.run(request) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let navigation = CodeNavigationStore()
        defer { navigation.reset() }
        let events = XRayNavigationEvents()
        let observer = NotificationCenter.default.addObserver(forName: .codeNavEvent, object: navigation, queue: .main) { note in
            if let json = note.userInfo?["json"] as? String { events.append(json) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let url = root.appendingPathComponent("Model.swift")
        func ask(_ id: String, question: String) {
            navigation.ask(id: id, question: question, snippet: "struct Model {}", start: 1, end: 1, path: "Model.swift",
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
}
