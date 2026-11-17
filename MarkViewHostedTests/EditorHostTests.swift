import AppKit
import Combine
import os
import MarkViewCore
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

private actor DraftCheckpointRecorder {
    private var drafts: [ProjectDraft] = []
    func append(_ draft: ProjectDraft) { drafts.append(draft) }
    func snapshot() -> [ProjectDraft] { drafts }
}

@MainActor private final class TerminalCloseTestObserver: TerminalCloseObserver {
    var calls = 0
    func terminalWillClose() { calls += 1 }
}

@MainActor private final class WindowDelegateProbe: NSObject, NSWindowDelegate {
    var resizeCount = 0
    var closeCount = 0
    var allowsClose = false
    func windowDidResize(_ notification: Notification) { resizeCount += 1 }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeCount += 1; return allowsClose }
}

@MainActor private final class CockpitTestAssistants: AssistantProviding {
    var currentAssistant: CLICompletion.Assistant? { nil }
    var sessions: [TerminalSession] { [] }
    var shownID: UUID? { nil }
    func liveModelReported(_ model: String, terminalID: UUID) {}
    func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession? { nil }
    func showAIConsole() {}
}

@MainActor private final class TerminalTestConnection: TerminalConnection {
    weak var observer: (any TerminalConnectionObserver)?
    var started = false
    func start() { started = true }
    func write(_ text: String) {}
    func resize(cols: Int, rows: Int) {}
    func stop() {}
}

private actor SessionTestDriver: QAActorDriver {
    private var opening: CheckedContinuation<Void, Never>?
    private(set) var didStart = false
    private(set) var closeCount = 0
    func open(_ address: String) async throws {
        didStart = true
        await withCheckedContinuation { opening = $0 }
    }
    func finishOpening() { opening?.resume(); opening = nil }
    func observe() async throws -> QAObservation { throw CancellationError() }
    func perform(_ action: QAAction) async throws -> String { throw CancellationError() }
    func screenshot() async -> Data? { nil }
    func arm(_ fault: QAFault) async throws {}
    func faultHits() async -> Int { 0 }
    func close() async { closeCount += 1 }
}

private actor SessionTestFactory: QADriverFactory {
    private var drivers: [SessionTestDriver]
    init(_ drivers: [SessionTestDriver]) { self.drivers = drivers }
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        guard !drivers.isEmpty else { throw CancellationError() }
        return drivers.removeFirst()
    }
}

private actor DelayedSessionTestFactory: QADriverFactory {
    let driver: SessionTestDriver
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var didStart = false
    init(_ driver: SessionTestDriver) { self.driver = driver }
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        didStart = true
        await withCheckedContinuation { waiting = $0 }
        return driver
    }
    func finishMaking() { waiting?.resume(); waiting = nil }
}

/// The real editor with the real per-window parts, in the isolated app-hosted test build.
final class EditorHostTests: XCTestCase {
    @MainActor
    func testWindowDelegateForwardsOnlyOnMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-window-delegate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("recent.json"))
        let previous = WindowDelegateProbe()
        let delegate = ProjectOperationWindowCloseDelegate(previous: previous, workspace: workspace)
        let selector = #selector(NSWindowDelegate.windowDidResize(_:))
        XCTAssertTrue(delegate.responds(to: selector))
        XCTAssertTrue((delegate.forwardingTarget(for: selector) as AnyObject?) === previous)
        _ = delegate.perform(selector, with: NSNotification(name: NSWindow.didResizeNotification, object: nil))
        XCTAssertEqual(previous.resizeCount, 1)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(delegate.windowShouldClose(window))
        previous.allowsClose = true
        XCTAssertTrue(delegate.windowShouldClose(window))
        XCTAssertEqual(previous.closeCount, 2)
        let background = await Task.detached {
            let selector = NSSelectorFromString("windowDidResize:")
            return (delegate.responds(to: selector), delegate.forwardingTarget(for: selector) != nil)
        }.value
        XCTAssertFalse(background.0)
        XCTAssertFalse(background.1)
        XCTAssertEqual(previous.resizeCount, 1)
    }

    @MainActor
    func testTerminalEventsFromRealProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-terminal-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = TerminalSession(directory: root, operationCommand: "printf MV_EVENT_OUTPUT; exit 7")
        defer { terminal.terminate() }
        var first = Data(), second = Data()
        var code: Int32?
        let finished = expectation(description: "PTY process exited")
        let subscriptions = [
            terminal.outputEvents.sink { first.append($0) },
            terminal.outputEvents.sink { second.append($0) },
            terminal.exitEvents.sink { code = $0; finished.fulfill() },
        ]
        terminal.start()
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertEqual(code, 7)
        XCTAssertEqual(first, second)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("MV_EVENT_OUTPUT"))
        withExtendedLifetime(subscriptions) {}
    }

    @MainActor
    func testCockpitSupervisorUsesCurrentStepChoiceAndLiveCut() async {
        let assistants = CockpitTestAssistants()
        var choices: [(String?, String?)] = [], exchanges: [CockpitSupervisorExchange] = []
        var cuts = CockpitLiveSwitches()
        let attempt = CockpitAgentAttempt(assistants: assistants, root: FileManager.default.temporaryDirectory,
            askSupervisor: { _, tool, model in
                choices.append((tool?.rawValue, model))
                return CockpitSupervisor.Answer(text: "Proceed carefully", outOfScope: false)
            }, onExchange: { exchanges.append($0) }, liveCuts: { cuts })
        let firstTool = CLITool.allCases.first!, secondTool = CLITool.allCases.last!
        let step = CockpitHostStep(id: UUID().uuidString, agent: "fixture", assignment: "Check", prerequisite: false)
        let task = CockpitHostTask(step: step, planFingerprint: "fixture", goal: "Check", controls: "{}", successCriteria: [], priorResults: [])
        attempt.supervisorTool = firstTool; attempt.supervisorModel = "first"
        let first = await attempt.supervise(.init(text: "First question"), task: task)
        attempt.supervisorTool = secondTool; attempt.supervisorModel = "second"
        let second = await attempt.supervise(.init(text: "Second question"), task: task)
        cuts.supervisorCut = true
        let disabled = await attempt.supervise(.init(text: "Third question"), task: task)
        XCTAssertEqual(choices.map { $0.0 }, [firstTool.rawValue, secondTool.rawValue])
        XCTAssertEqual(choices.map { $0.1 }, ["first", "second"])
        XCTAssertTrue(first.contains("Proceed carefully"))
        XCTAssertTrue(second.contains("Proceed carefully"))
        XCTAssertEqual(disabled, CockpitSupervisor.disabledReply)
        XCTAssertEqual(exchanges.count, 2)
    }

    @MainActor
    func testTerminalConnectionForwardsStateOutputAndExit() {
        let terminal = TerminalSession(directory: FileManager.default.temporaryDirectory)
        let first = TerminalTestConnection(), next = TerminalTestConnection()
        var output = Data(), secondOutput = Data(), exits: [Int32] = []
        let outputObservation = terminal.outputEvents.sink { output.append($0) }
        let secondObservation = terminal.outputEvents.sink { secondOutput.append($0) }
        let exitObservation = terminal.exitEvents.sink { exits.append($0) }
        terminal.connection = first
        first.observer?.connectionDidReceive(Data("early".utf8))
        first.observer?.connectionDidExit(99)
        XCTAssertTrue(output.isEmpty)
        XCTAssertTrue(exits.isEmpty)
        first.observer?.connectionDidChangeState(.online, detail: "Connected")
        if case .online? = terminal.remoteConnectionState?.phase {} else { XCTFail("Expected online state") }
        XCTAssertEqual(terminal.remoteConnectionState?.detail, "Connected")
        XCTAssertNotNil(terminal.remoteConnectionState?.lastSeen)
        terminal.start()
        XCTAssertTrue(first.started)
        first.observer?.connectionDidReceive(Data("hello".utf8))
        XCTAssertEqual(secondOutput, Data("hello".utf8))
        secondObservation.cancel()
        first.observer?.connectionDidReceive(Data(" again".utf8))
        first.observer?.connectionDidExit(7)
        XCTAssertEqual(output, Data("hello again".utf8))
        XCTAssertEqual(secondOutput, Data("hello".utf8))
        XCTAssertEqual(exits, [7])
        XCTAssertFalse(terminal.isRunning)
        terminal.connection = next
        XCTAssertNil(first.observer)
        XCTAssertNotNil(next.observer)
        terminal.terminate()
        withExtendedLifetime((outputObservation, exitObservation)) {}
    }

    @MainActor
    func testTerminalCloseObserverIsCalledOnceAndCanBeCleared() {
        let terminal = TerminalSession(directory: FileManager.default.temporaryDirectory)
        let observer = TerminalCloseTestObserver()
        terminal.closeObserver = observer
        terminal.terminate()
        terminal.terminate()
        XCTAssertEqual(observer.calls, 1)
        terminal.closeObserver = observer
        terminal.closeObserver = nil
        terminal.terminate()
        XCTAssertEqual(observer.calls, 1)
    }

    @MainActor
    func testProjectChangeReviewLayoutUsesRealModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-review-layout-" + UUID().uuidString)
        let changed = root.appendingPathComponent("apps/demo/ConfigurationWindowModel.swift")
        let added = root.appendingPathComponent("docs/notes/another-file.md")
        try FileManager.default.createDirectory(at: changed.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = (1...120).map { "let value\($0) = compute(\($0))" }
        var after = before
        for index in stride(from: 5, to: 120, by: 15) { after[index] = "let value\(index + 1) = recomputed(\(index + 1))" }
        after[50] = "let long = " + String(repeating: "a very long expression that has to wrap instead of widening the page + ", count: 12)
        try (before.joined(separator: "\n") + "\n").write(to: changed, atomically: true, encoding: .utf8)
        let review = ProjectChangeReview()
        await review.open(root)
        try (after.joined(separator: "\n") + "\n").write(to: changed, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "new\n".write(to: added, atomically: true, encoding: .utf8)
        await review.refresh()
        XCTAssertEqual(review.changes.count, 2)
        let tree = WorkspaceFileTreeStore()
        tree.rootNode = FileNode(url: root, isDirectory: true)
        let hosting = NSHostingView(rootView: ProjectChangeReviewTab(review: review).environmentObject(tree))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for (width, height) in [(CGFloat(400), CGFloat(500)), (800, 640), (1600, 900)] {
            window.setContentSize(NSSize(width: width, height: height))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            for _ in 0..<30 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let views = descendants(hosting)
            func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
            let list = try XCTUnwrap(views.first { String(describing: type(of: $0)).hasPrefix("ListCoreScrollView") })
            let diffView = try XCTUnwrap(views.filter { String(describing: type(of: $0)) == "HostingScrollView" }
                .max { frame($0).height < frame($1).height })
            let diff = frame(diffView)
            let document = ((diffView as? NSScrollView)?.documentView).map(frame)
                ?? views.first { String(describing: type(of: $0)) == "DocumentView" && abs(frame($0).minX - diff.minX) < 2 }.map(frame)
            let clip = ((diffView as? NSScrollView)?.contentView).map(frame)
                ?? views.first { (String(describing: type(of: $0)).contains("ClipView") || $0 is NSClipView) && abs(frame($0).minX - diff.minX) < 2 }.map(frame)
            XCTAssertGreaterThanOrEqual(frame(list).width, 145)
            XCTAssertLessThanOrEqual(frame(list).width, 265)
            XCTAssertGreaterThanOrEqual(diff.minX, 0)
            XCTAssertLessThanOrEqual(diff.maxX, width + 0.5)
            XCTAssertGreaterThanOrEqual(diff.width, max(190, (width - 265) - 2))
            let measuredDocument = try XCTUnwrap(document), measuredClip = try XCTUnwrap(clip)
            XCTAssertLessThanOrEqual(measuredDocument.width, measuredClip.width + 0.5)
            XCTAssertGreaterThan(measuredDocument.height, measuredClip.height)
        }
        await review.open(nil)
    }

    private func waitForOpen(_ driver: SessionTestDriver) async throws {
        for _ in 0..<500 {
            if await driver.didStart { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Driver did not start opening")
        throw CancellationError()
    }

    func testQASessionsCloseInvalidatesInFlightOpen() async throws {
        for key in ["branch|player", "attach|player"] {
            let sessions = QARunSessions(), driver = SessionTestDriver(), factory = SessionTestFactory([driver])
            let request = QADriverRequest(actor: nil, app: QAApp(id: "app", name: "App"), address: "fixture", login: nil)
            let opening = Task { try await sessions.session(key: key, request: request, factory: factory) }
            try await waitForOpen(driver)
            if key.hasPrefix("attach|") { await sessions.closeAttached() } else { await sessions.close() }
            await driver.finishOpening()
            do { _ = try await opening.value; XCTFail("An invalidated open must not return a session") }
            catch is CancellationError {}
            let closed = await driver.closeCount
            XCTAssertEqual(closed, 1)
        }
    }

    func testQASessionsCancelledOpenClosesDriver() async throws {
        let sessions = QARunSessions(), driver = SessionTestDriver(), factory = SessionTestFactory([driver])
        let request = QADriverRequest(actor: nil, app: QAApp(id: "app", name: "App"), address: "fixture", login: nil)
        let opening = Task { try await sessions.session(key: "branch|player", request: request, factory: factory) }
        try await waitForOpen(driver)
        opening.cancel()
        await driver.finishOpening()
        do { _ = try await opening.value; XCTFail("A cancelled open must not return a session") }
        catch is CancellationError {}
        let closed = await driver.closeCount
        XCTAssertEqual(closed, 1)
    }

    func testQASessionsCloseDuringFactoryDoesNotOpenDriver() async throws {
        let sessions = QARunSessions(), driver = SessionTestDriver(), factory = DelayedSessionTestFactory(driver)
        let request = QADriverRequest(actor: nil, app: QAApp(id: "app", name: "App"), address: "fixture", login: nil)
        let opening = Task { try await sessions.session(key: "branch|player", request: request, factory: factory) }
        for _ in 0..<500 {
            if await factory.didStart { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await factory.didStart
        guard started else { opening.cancel(); XCTFail("Factory did not start"); return }
        await sessions.close()
        await factory.finishMaking()
        do { _ = try await opening.value; XCTFail("A closed session must not open its newly created driver") }
        catch is CancellationError {}
        let didOpen = await driver.didStart, closed = await driver.closeCount
        XCTAssertFalse(didOpen)
        XCTAssertEqual(closed, 1)
    }

    func testQASessionsReuseOneDriverWhenOpensOverlap() async throws {
        let sessions = QARunSessions(), first = SessionTestDriver(), second = SessionTestDriver()
        let factory = SessionTestFactory([first, second])
        let request = QADriverRequest(actor: nil, app: QAApp(id: "app", name: "App"), address: "fixture", login: nil)
        let firstOpen = Task { try await sessions.session(key: "branch|player", request: request, factory: factory) }
        try await waitForOpen(first)
        let secondOpen = Task { try await sessions.session(key: "branch|player", request: request, factory: factory) }
        try await waitForOpen(second)
        await first.finishOpening()
        let retained = try await firstOpen.value
        await second.finishOpening()
        let reused = try await secondOpen.value
        XCTAssertTrue(retained === reused)
        let duplicateCloses = await second.closeCount
        XCTAssertEqual(duplicateCloses, 1)
        await sessions.close()
        let retainedCloses = await first.closeCount
        XCTAssertEqual(retainedCloses, 1)
    }

    @MainActor
    func testQAGraphWheelDetachesAndReleasesAfterWindowChanges() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        weak var released: QAGraphWheelView?
        do {
            let wheel = QAGraphWheelView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            released = wheel
            window.contentView?.addSubview(wheel)
            wheel.removeFromSuperview()
            window.contentView?.addSubview(wheel)
            wheel.removeFromSuperview()
        }
        await Task.yield()
        XCTAssertNil(released)
        window.close()
    }

    @MainActor
    func testClusterNamingSchemaIncludesGroupsOnlyForSingleBatch() throws {
        let single = ArchitectureStore.clusterNamingSchema(single: true)
        let multi = ArchitectureStore.clusterNamingSchema(single: false)
        let singleProperties = try XCTUnwrap(single["properties"] as? [String: Any])
        let multiProperties = try XCTUnwrap(multi["properties"] as? [String: Any])
        XCTAssertEqual(Set(singleProperties.keys), ["clusters", "system", "subsystems"])
        XCTAssertEqual(Set(multiProperties.keys), ["clusters"])
        XCTAssertEqual(Set(try XCTUnwrap(single["required"] as? [String])), ["clusters", "system", "subsystems"])
        XCTAssertEqual(try XCTUnwrap(multi["required"] as? [String]), ["clusters"])
    }

    @MainActor
    func testPrototypeWaiterTimesOutAndCancels() async throws {
        let timed = PrototypeWaiter<String?>()
        do {
            _ = try await timed.wait(within: 0.03, timeoutMessage: "test timeout")
            XCTFail("An unanswered call must time out")
        } catch let error as PrototypeScreenshots.Failure {
            XCTAssertEqual(error, .timedOut("test timeout"))
        }
        timed.finish(.success("late"))
        do {
            _ = try await timed.wait(within: 1, timeoutMessage: "unused")
            XCTFail("A late result must not replace the timeout")
        } catch let error as PrototypeScreenshots.Failure {
            XCTAssertEqual(error, .timedOut("test timeout"))
        }

        let cancelled = PrototypeWaiter<Void>()
        let task = Task { @MainActor in try await cancelled.wait(within: 10, timeoutMessage: "unused") }
        await Task.yield()
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled call must stop waiting")
        } catch is CancellationError {}
        cancelled.finish(.success(()))
    }

    @MainActor
    func testPrototypeScreenshotRendersLocalPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-screenshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "<html><body><h1>Prototype</h1></body></html>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let png = try await PrototypeScreenshots().capture(.init(site: folder, screen: nil, page: nil))
        XCTAssertNotNil(NSImage(data: png))
    }

    @MainActor
    func testStudioPageCallCompletesOrCancelsOnce() async throws {
        let completed = StudioPageCall()
        let answer: StudioPageValue = try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(completed.begin(continuation))
            completed.finish(.success("answer"))
            completed.cancel()
        }
        XCTAssertEqual(answer.value as? String, "answer")

        let cancelled = StudioPageCall()
        do {
            let _: StudioPageValue = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(cancelled.begin(continuation))
                cancelled.cancel()
                cancelled.finish(.success("too late"))
            }
            XCTFail("Cancellation must finish the call")
        } catch is CancellationError {
            // Expected: a late WebKit reply cannot resume the continuation a second time.
        }

        let cancelledBeforeStart = StudioPageCall()
        cancelledBeforeStart.cancel()
        do {
            let _: StudioPageValue = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(cancelledBeforeStart.begin(continuation))
            }
            XCTFail("Cancellation before start must finish the call")
        } catch is CancellationError {}
    }

    func testAssistantJSONSearchPlacesAcrossTask() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-places-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "one\ntwo\n".write(to: folder.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        let json: [String: Any] = ["steps": [["title": "Trace", "places": [
            ["path": "file.swift", "start": 1, "end": 99],
            ["path": "../outside", "start": 1],
        ]]]]
        let result = try CLICompletion.Result(text: "", structured: json, inputTokens: 0, outputTokens: 0, costUSD: nil)
        let places = await Task.detached {
            XRaySearch.places(from: (result.structured as? [String: Any])?["steps"], root: folder)
        }.value
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.path, "file.swift")
        XCTAssertEqual(places.first?.start, 1)
        XCTAssertEqual(places.first?.end, 3)
    }

    func testAssistantResultOwnsValidatedJSON() throws {
        let original = NSMutableDictionary(dictionary: ["items": [1, 2, 3], "flag": true, "label": "Пример"])
        let result = try CLICompletion.Result(text: "answer", structured: original, inputTokens: 3, outputTokens: 4, costUSD: nil)
        original["label"] = "changed"
        let object = try XCTUnwrap(result.structured as? [String: Any])
        XCTAssertEqual(object["label"] as? String, "Пример")
        XCTAssertEqual(object["items"] as? [Int], [1, 2, 3])
        XCTAssertEqual(object["flag"] as? Bool, true)
        let fragment = try CLICompletion.Result(text: "", structured: "value", inputTokens: 0, outputTokens: 0, costUSD: nil)
        XCTAssertEqual(fragment.structured as? String, "value")
        XCTAssertThrowsError(try CLICompletion.Result(text: "", structured: Date(), inputTokens: 0, outputTokens: 0, costUSD: nil))
        let raw = try AIRawJSONObject(["nested": original, "count": 7, "large": UInt64.max])
        original["label"] = "changed again"
        XCTAssertEqual((raw.dictionary["nested"] as? [String: Any])?["label"] as? String, "changed")
        XCTAssertEqual(raw.dictionary["count"] as? Int, 7)
        XCTAssertEqual((raw.dictionary["large"] as? NSNumber)?.uint64Value, UInt64.max)
        XCTAssertThrowsError(try AIRawJSONObject(["invalid": Date()]))
    }

    @MainActor
    func testAssistantRequestOwnsValidatedSchema() async throws {
        let nested = NSMutableDictionary(dictionary: ["label": "original", "values": [1, 2]])
        var request = CLICompletion.Request(project: nil, prompt: "test", jsonSchema: ["nested": nested, "large": UInt64.max])
        nested["label"] = "changed"
        XCTAssertEqual((request.jsonSchema?["nested"] as? [String: Any])?["label"] as? String, "original")
        XCTAssertEqual((request.jsonSchema?["large"] as? NSNumber)?.uint64Value, UInt64.max)
        let snapshot = request
        let detachedLabel = await Task.detached { (snapshot.jsonSchema?["nested"] as? [String: Any])?["label"] as? String }.value
        XCTAssertEqual(detachedLabel, "original")

        request.jsonSchema = ["invalid": Date()]
        XCTAssertThrowsError(try request.validateSchema())
        var called = false
        let operation = AIOperation<CLICompletion.Request, CLICompletion.Result>.run(name: "invalid-schema", runner: { _, _, _ in
            called = true
            return try CLICompletion.Result(text: "", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        do {
            _ = try await operation.execute(request)
            XCTFail("An invalid schema must fail before running an assistant")
        } catch {}
        XCTAssertFalse(called)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-invalid-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await ArchitectureStore().xrayCall(request, root: root, db: nil, call: 0)
            XCTFail("X-Ray must reject an invalid schema")
        } catch {}
        request.jsonSchema = nil
        XCTAssertNoThrow(try request.validateSchema())
    }

    func testProjectBootstrapPersistsEachStage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-bootstrap-" + UUID().uuidString)
        let specification = folder.appendingPathComponent("specification")
        try FileManager.default.createDirectory(at: specification, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Requirements\n".write(to: specification.appendingPathComponent("requirements.md"), atomically: true, encoding: .utf8)
        var draft = ProjectDraft(idea: "Test project")
        draft.parentPath = folder.path
        draft.folderName = "created-project"
        let recorder = DraftCheckpointRecorder()
        let result = try await ProjectBootstrap.run(&draft, specification: specification, slug: "test-feature", readme: "# Test\n") { saved in
            await recorder.append(saved)
        }
        let checkpoints = await recorder.snapshot()
        XCTAssertEqual(checkpoints.count, 3)
        XCTAssertEqual(checkpoints.map(\.filesWritten), [false, true, true])
        XCTAssertEqual(checkpoints.map(\.gitInitialized), [false, false, true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent(".git").path))
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("docs/features/test-feature/requirements.md"), encoding: .utf8),
                       "# Requirements\n")
    }

    func testNotificationRouterExposesResponseCallback() {
        let router = ProjectOperationNotificationRouter()
        let selector = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        XCTAssertTrue(router.responds(to: selector), "UserNotifications must be able to call the response handler")
        XCTAssertEqual(ProjectOperationNotificationRouter.destination(for: ["cockpitRoot": "/project", "cockpitRunID": "run"]),
                       .cockpit(root: "/project", runID: "run"))
        XCTAssertEqual(ProjectOperationNotificationRouter.destination(for: ["projectOperationRoot": "/project", "projectOperationID": "build"]),
                       .operation(root: "/project", id: "build"))
        XCTAssertNil(ProjectOperationNotificationRouter.destination(for: ["projectOperationRoot": "/project"]))
    }

    func testParallelSearchScoresAllReadableFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = (0..<64).map { "file-\($0).txt" }
        for (index, name) in names.enumerated() {
            try (index.isMultiple(of: 2) ? "needle" : "unrelated").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let results = FilterSearch.scoreFiles(names + ["missing.txt"], root: folder, terms: ["needle"])
        XCTAssertEqual(results.count, names.count)
        XCTAssertNil(results["missing.txt"])
        for (index, name) in names.enumerated() {
            XCTAssertEqual((results[name]?.score ?? -1) > 0, index.isMultiple(of: 2), name)
        }
    }

    func testScannerRetainsParallelDocumentAndCodeResults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<32 {
            try "func check\(index)(_ n: Int) -> Int { if n > 0 { return n }; return 0 }\n"
                .write(to: folder.appendingPathComponent("source\(index).swift"), atomically: true, encoding: .utf8)
            try "# Chapter \(index)\n\nSee source\(index).swift.\n"
                .write(to: folder.appendingPathComponent("chapter\(index).md"), atomically: true, encoding: .utf8)
        }
        let result = ArchitectureScanner(root: folder).run()
        XCTAssertEqual(result.sourceFileCount, 32)
        for index in 0..<32 {
            XCTAssertNotNil(result.metrics["m:source\(index).swift"], "source \(index)")
            XCTAssertTrue(result.docs.nodes.contains { $0.path == "chapter\(index).md" }, "chapter \(index)")
        }
    }

    @MainActor
    func testEditorLoadsDocumentWithScopedWindowParts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-hosted-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("sample.md")
        let text = "# Hosted editor\n\nScoped window parts work.\n"
        try text.write(to: document, atomically: true, encoding: .utf8)
        let workspace = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("recent.json"))
        defer { workspace.windowWillClose() }
        let editor = EditorView(research: workspace.research, insight: workspace.insight, taskBag: workspace.taskBag)
            .observingParts(of: workspace)
            .environmentObject(workspace.theme)
        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        workspace.tabs.openDocument(document)

        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            for child in view.subviews { if let found = findWebView(child) { return found } }
            return nil
        }
        var rendered: String?
        for _ in 0..<200 {
            if let webView = findWebView(hosting), !webView.isLoading {
                rendered = try? await webView.callAsyncJavaScript(
                    "return document.querySelector('#editor-input')?.value || '';", arguments: [:], in: nil, contentWorld: .page) as? String
                if rendered == text { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(rendered, text, "The real editor receives the opened document through its scoped dependencies")
        let webView = try XCTUnwrap(findWebView(hosting))
        _ = try await webView.callAsyncJavaScript(
            "window.__observedHeading = ''; window.scrollToHeading = value => { window.__observedHeading = value; };",
            arguments: [:], in: nil, contentWorld: .page)
        let other = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("other-recent.json"))
        defer { other.windowWillClose() }
        NotificationCenter.default.post(.scrollToHeading, for: other, object: "wrong-window")
        try await Task.sleep(nanoseconds: 100_000_000)
        var heading = try await webView.callAsyncJavaScript("return window.__observedHeading;", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(heading, "", "A notification for another window must not reach this editor")
        NotificationCenter.default.post(.scrollToHeading, for: workspace, object: "right-window")
        for _ in 0..<50 {
            heading = try await webView.callAsyncJavaScript("return window.__observedHeading;", arguments: [:], in: nil, contentWorld: .page) as? String
            if heading == "right-window" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(heading, "right-window", "The window's own notification reaches its editor")
    }
    @MainActor
    func testEditorObserverLifetimeRemovesRegistrations() {
        let center = NotificationCenter()
        let name = Notification.Name("EditorObserverLifetime-" + UUID().uuidString)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var observers: NotificationObservers? = NotificationObservers()
        observers?.observe(name, center: center) { _ in calls.withLock { $0 += 1 } }
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        observers?.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.withLock { $0 }, 1, "Removed observers must not receive future notifications")
        observers?.observe(name, center: center) { _ in calls.withLock { $0 += 1 } }
        observers = nil
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.withLock { $0 }, 1, "Released observers must not receive future notifications")
    }

    @MainActor
    func testGitHubNavigationDelegateExposesPolicyCallback() {
        let coordinator = GitHubHTMLView.Coordinator()
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(coordinator.responds(to: selector), "WebKit must be able to call the navigation policy handler")
    }

    @MainActor
    func testDiscussionNavigationDelegateExposesPolicyCallback() {
        let coordinator = DiscussionThreadView.Coordinator()
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(coordinator.responds(to: selector), "WebKit must be able to call the navigation policy handler")
    }

}

/// The live QA screen exposes the same rows to Accessibility without SwiftUI's crashing lazy scroll nodes.
final class QALiveAccessibilityHostTests: XCTestCase {
    /// SwiftUI's accessibility nodes implement the Objective-C selector without declaring the Swift protocol.
    private func press(_ element: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard element.responds(to: selector), let implementation = element.method(for: selector) else { return false }
        let action = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return action(element, selector)
    }

    @MainActor func testScenarioListAccessibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-accessibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<80 {
            var scenario = QAScenario(id: "scenario-\(index)", title: "Fixture scenario \(index)", goal: "test",
                                      appKind: .web, created: Date(), updated: Date())
            scenario.summary = "Fixture summary"
            scenario.summarySource = QASummary.source(scenario)
            try QAStore.saveScenario(scenario, root: root)
        }
        let model = QAModel()
        model.attach(root: root)
        defer { model.close() }
        let deadline = Date().addingTimeInterval(10)
        while model.scenarios.count < 80 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(model.scenarios.count, 80)
        let hosting = NSHostingView(rootView: QATabView(model: model).environmentObject(WindowUIState()))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.orderFrontRegardless()
        defer { window.close() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        var labels: [String] = []
        var scenarioButton: NSObject?
        func walk(_ element: NSObject, depth: Int = 0) {
            guard depth < 24 else { return }
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let name = NSSelectorFromString(selector)
                if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String {
                    labels.append(value)
                    if value.contains("Fixture scenario 79"), element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                        scenarioButton = element
                    }
                }
            }
            let names = NSSelectorFromString("accessibilityActionNames")
            if element.responds(to: names), let actions = element.perform(names)?.takeUnretainedValue() as? [String] {
                for action in ["AXScrollToBottom", "AXScrollToTop"] where actions.contains(action) {
                    element.perform(NSSelectorFromString("accessibilityPerformAction:"), with: action)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for child in values { walk(child, depth: depth + 1) }
            }
        }
        walk(hosting)
        XCTAssertTrue(labels.contains { $0.contains("Fixture scenario 0") })
        XCTAssertTrue(labels.contains { $0.contains("Fixture scenario 79") })
        if let scenarioButton {
            XCTAssertTrue(press(scenarioButton))
            XCTAssertEqual(model.current?.id, "scenario-79", "An accessibility press opens the requested scenario")
        } else {
            XCTFail("The scenario remains an accessible button")
        }
    }

    @MainActor func testAccessibilityScrollAndRows() {
        let run = QARunModel()
        for index in 0..<80 {
            run.handle(.narration(QATimelineEntry(id: index, time: Double(index), branch: "branch", node: nil,
                                                 actor: nil, kind: .action, text: "Fixture feed \(index)")))
        }
        for index in 0..<40 {
            let result = QACheckResult(branch: "Fixture branch \(index)", verdict: QACheckVerdict(outcome: .passed, reason: "ok"),
                                       startedAt: Date(), finishedAt: Date())
            run.handle(.branchFinished(result))
        }
        for index in 40..<60 {
            let result = QACheckResult(branch: "Fixture branch \(index)", verdict: QACheckVerdict(outcome: .uncovered, reason: "not run"),
                                       startedAt: Date(), finishedAt: Date())
            run.handle(.branchFinished(result))
        }
        let hosting = NSHostingView(rootView: QALiveRunView(run: run, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.orderFrontRegardless()
        defer { window.close() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        var labels: [String] = []
        var uncoveredControl: NSObject?
        func walk(_ element: NSObject, depth: Int = 0) {
            guard depth < 24 else { return }
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let name = NSSelectorFromString(selector)
                if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String {
                    labels.append(value)
                    if value.contains("Not executed (20)"), element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                        uncoveredControl = element
                    }
                }
            }
            let names = NSSelectorFromString("accessibilityActionNames")
            if element.responds(to: names), let actions = element.perform(names)?.takeUnretainedValue() as? [String] {
                for action in ["AXScrollToBottom", "AXScrollToTop"] where actions.contains(action) {
                    element.perform(NSSelectorFromString("accessibilityPerformAction:"), with: action)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for child in values { walk(child, depth: depth + 1) }
            }
        }
        settle()
        for index in 80..<100 {
            run.handle(.narration(QATimelineEntry(id: index, time: Double(index), branch: "branch", node: nil,
                                                 actor: nil, kind: .action, text: "Fixture feed \(index)")))
        }
        settle(); walk(hosting); settle(); walk(hosting)
        XCTAssertTrue(labels.contains { $0.contains("Fixture feed 0") }, "The first feed entry is accessible")
        XCTAssertTrue(labels.contains { $0.contains("Fixture feed 99") }, "A new feed entry remains accessible")
        XCTAssertTrue(labels.contains { $0.contains("Fixture branch 39") }, "The branch results remain accessible")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let areas = descendants(hosting).compactMap { $0 as? NSScrollView }
        var moved = false
        for area in areas {
            guard let document = area.documentView, document.bounds.height > area.contentView.bounds.height + 10 else { continue }
            let before = area.contentView.bounds.origin.y
            let maxY = document.bounds.height - area.contentView.bounds.height
            let target = before < maxY / 2 ? maxY : 0
            area.contentView.scroll(to: NSPoint(x: area.contentView.bounds.origin.x, y: target))
            area.reflectScrolledClipView(area.contentView)
            moved = moved || abs(area.contentView.bounds.origin.y - before) > 1
        }
        XCTAssertTrue(moved, "A long QA region remains scrollable")
        func containsFeed(_ element: NSObject, depth: Int = 0) -> Bool {
            guard depth < 24 else { return false }
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let name = NSSelectorFromString(selector)
                if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String,
                   value.contains("Fixture feed 50") { return true }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            guard element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] else { return false }
            return values.contains { containsFeed($0, depth: depth + 1) }
        }
        if let area = areas.first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 && containsFeed($0) }),
           let document = area.documentView {
            let middle = (document.bounds.height - area.contentView.bounds.height) / 2
            settle()
            area.contentView.scroll(to: NSPoint(x: 0, y: middle))
            area.reflectScrolledClipView(area.contentView)
            let before = area.contentView.bounds.origin.y
            area.accessibilityPerformAction(NSAccessibility.Action(rawValue: "AXScrollUpByPage"))
            settle()
            let up = area.contentView.bounds.origin.y
            area.contentView.scroll(to: NSPoint(x: 0, y: middle))
            area.reflectScrolledClipView(area.contentView)
            let beforeDown = area.contentView.bounds.origin.y
            area.accessibilityPerformAction(NSAccessibility.Action(rawValue: "AXScrollDownByPage"))
            settle()
            let down = area.contentView.bounds.origin.y
            XCTAssertGreaterThan(abs(up - before), 1, "Accessibility page-up scrolls the feed: \(before) → \(up)")
            XCTAssertGreaterThan(abs(down - beforeDown), 1, "Accessibility page-down scrolls the feed: \(beforeDown) → \(down)")
        } else {
            XCTFail("A scrollable QA region is present for the accessibility page actions")
        }
        if let button = uncoveredControl {
            XCTAssertTrue(press(button), "The uncovered-branches control accepts an accessibility press")
            settle()
            walk(hosting)
            XCTAssertTrue(labels.contains { $0.contains("Fixture branch 59") }, "Uncovered branches remain accessible after expansion")
        } else {
            XCTFail("The uncovered-branches control remains accessible")
        }
    }
}


extension EditorHostTests {
    @MainActor func testFileBrowserRulesOnTemporaryProject() throws {
        func check(_ condition: Bool, _ label: String, line: UInt = #line) {
            XCTAssertTrue(condition, label, line: line)
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("file-browser-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let project = base.appendingPathComponent("project", isDirectory: true)
        let linked = base.appendingPathComponent("notes", isDirectory: true)

        func path(_ root: URL, _ relative: String) -> URL { root.appendingPathComponent(relative) }
        func makeFolder(_ root: URL, _ relative: String) throws {
            try fm.createDirectory(at: path(root, relative), withIntermediateDirectories: true)
        }
        func makeFile(_ root: URL, _ relative: String, modified: Date? = nil) throws {
            try fm.createDirectory(at: path(root, relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: path(root, relative))
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path(root, relative).path) }
        }

        // project/
        //   src/{main.swift, notes.md}   .hidden/secret.md   .env   build/out.o (ignored)   docs/deep/er/needle.md
        //   video.mov (no viewer)   readme.md   Zeta.txt   alpha.txt   image.png
        let old = Date(timeIntervalSince1970: 1_000_000)
        let mid = Date(timeIntervalSince1970: 2_000_000)
        let new = Date(timeIntervalSince1970: 3_000_000)
        try makeFile(project, "src/main.swift")
        try makeFile(project, "src/notes.md")
        try makeFile(project, ".hidden/secret.md")
        try makeFile(project, ".env")
        try makeFile(project, "build/out.o")
        try makeFile(project, "docs/deep/er/needle.md")
        try makeFile(project, "video.mov", modified: mid)
        try makeFile(project, "readme.md", modified: old)
        try makeFile(project, "Zeta.txt", modified: new)
        try makeFile(project, "alpha.txt", modified: new)
        try makeFile(project, "image.png", modified: mid)
        try makeFile(linked, "todo.md")
        try makeFile(linked, "deep/needle-linked.md")

        let projectRoot = FileBrowserRoot(url: project, name: "project", linkedID: nil)
        let linkedRoot = FileBrowserRoot(url: linked, name: "Notes", linkedID: linked.path)
        let roots = [projectRoot, linkedRoot]
        let ignoredPaths: Set<String> = [FileBrowser.key(path(project, "build"))]

        func source(_ filter: FileBrowserFilter = FileBrowserFilter(), sort: FileTreeSortOrder = FileTreeSortOrder(),
                    roots: [FileBrowserRoot] = roots) -> FileBrowserSource {
            FileBrowserSource(roots: roots, filter: filter, sort: sort,
                              hasViewer: { FileType.hasViewer($0) },
                              isIgnored: { url, _ in
                                  let key = FileBrowser.key(url)
                                  return ignoredPaths.contains { key == $0 || key.hasPrefix($0 + "/") }
                              })
        }
        func names(_ entries: [FileBrowserEntry]) -> [String] { entries.map(\.name) }
        func list(_ filter: FileBrowserFilter = FileBrowserFilter(), sort: FileTreeSortOrder = FileTreeSortOrder(),
                  query: Bool = true) -> [String] {
            names(FileBrowser.listing(of: project, source: source(filter, sort: sort), applyQuery: query))
        }

        // MARK: Viewer classification (DEC-004)

        for name in ["a.md", "a.swift", "a.json", "a.yaml", "a.pdf", "a.png", "a.zip", "a.csv", "a.sqlite", "a.log", "a.canvas", "Makefile", "a.html"] {
            check(FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) has a viewer")
        }
        for name in [".gitignore", ".dockerignore", ".zshrc", ".env", ".env.local", "LICENSE", "a.conf", "a.txt"] {
            check(FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) (configuration file) has a viewer")
        }
        for name in ["a.mov", "a.dylib", "a.bin", "a.unknownext", "NOEXTENSION", ".custom"] {
            check(!FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) has no viewer")
        }

        // MARK: Preferences (AC-5, DEC-008)

        // WindowUIState belongs to the main actor, as the views that read it do.
        @MainActor func windowPreferenceChecks() {
            let suite = "file-browser-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            // Each window keeps its own view and filter choices (`FileTreeView` stores them in the window's `WindowUIState`).
            func browserPreferences(_ state: WindowUIState) -> FileBrowserPreferences {
                FileBrowserPreferences(mode: FileBrowserViewMode(rawValue: state.value(Setting.fileBrowserViewMode)) ?? .list,
                                       showHidden: state.value(Setting.fileBrowserShowHidden),
                                       hideIgnored: state.value(Setting.fileBrowserHideIgnored),
                                       category: FileBrowserCategory(rawValue: state.value(Setting.fileBrowserCategory)) ?? .all)
            }
            let windowA = WindowUIState(defaults: defaults), windowB = WindowUIState(defaults: defaults)
            check(browserPreferences(windowA) == FileBrowserPreferences(), "defaults: list, hidden off, ignored shown, all")
            check(browserPreferences(windowB) == FileBrowserPreferences(), "a second window starts the same")
            check(FileBrowserPreferences().mode == .list && !FileBrowserPreferences().showHidden, "hidden items are excluded by default")
            windowA.set(FileBrowserViewMode.tree.rawValue, for: Setting.fileBrowserViewMode)
            windowA.set(true, for: Setting.fileBrowserShowHidden)
            windowA.set(FileBrowserCategory.openable.rawValue, for: Setting.fileBrowserCategory)
            check(browserPreferences(windowA).mode == .tree && browserPreferences(windowA).showHidden && browserPreferences(windowA).category == .openable,
                  "the window that changed its view shows it")
            check(browserPreferences(windowB) == FileBrowserPreferences(), "another window that already shows its files keeps its own view")
            let windowC = WindowUIState(defaults: defaults)
            check(browserPreferences(windowC).mode == .tree && browserPreferences(windowC).showHidden, "a window opened later starts from the last choice")
            defer { UserDefaults(suiteName: suite + "-empty")?.removePersistentDomain(forName: suite + "-empty") }
        let restored = WindowUIState(defaults: UserDefaults(suiteName: suite + "-empty")!)
            restored.restore(windowA.saved)
            check(browserPreferences(restored).mode == .tree && browserPreferences(restored).category == .openable,
                  "the view, hidden and category come back with the window's session")
            defaults.set("nonsense", forKey: "fileBrowser.viewMode")
            defaults.set("nonsense", forKey: "fileBrowser.category")
            let windowD = WindowUIState(defaults: defaults)
            check(browserPreferences(windowD).mode == .list && browserPreferences(windowD).category == .all,
                  "unknown stored values fall back to the defaults")
        }
        windowPreferenceChecks()
        check(!FileBrowserFilter().isActive && FileBrowserFilter(query: "a").isActive && FileBrowserFilter(hideIgnored: true).hasSettings,
              "an active filter is reported")

        // MARK: Listing and filters (AC-3, REQ-001)

        let everything = list()
        check(!everything.contains(".hidden") && !everything.contains(".env"), "hidden items are excluded by default")
        check(everything.contains("build"), "ignored items stay visible by default")
        check(everything.contains("video.mov"), "All shows files MarkView cannot open (DEC-003)")
        check(list(FileBrowserFilter(showHidden: true)).contains(".hidden") && list(FileBrowserFilter(showHidden: true)).contains(".env"),
              "the hidden toggle shows dot items")
        check(!list(FileBrowserFilter(hideIgnored: true)).contains("build"), "Hide Git-ignored removes ignored folders")
        check(list(FileBrowserFilter(hideIgnored: true)).contains("src"), "Hide Git-ignored keeps other folders")
        check(list(FileBrowserFilter(showHidden: true, hideIgnored: true)).contains(".hidden"),
              "the two toggles are independent: ignored off, hidden on keeps dot items")
        check(list(FileBrowserFilter(category: .folders)) == ["build", "docs", "src"], "Folders shows only folders: \(list(FileBrowserFilter(category: .folders)))")
        let openable = list(FileBrowserFilter(category: .openable))
        check(openable.contains("src") && openable.contains("readme.md") && openable.contains("image.png"), "Openable keeps folders and viewer files")
        check(!openable.contains("video.mov"), "Openable drops files without a viewer")
        check(list(FileBrowserFilter(query: "ALPHA")) == ["alpha.txt"], "the name query is case-insensitive")
        check(list(FileBrowserFilter(query: "a"), query: false).count == everything.count, "children of a tree folder ignore the query")
        check(list(FileBrowserFilter(query: "zz-none")).isEmpty, "a query without a match lists nothing")
        check(list(FileBrowserFilter(query: "ALPHA", category: .folders)).isEmpty, "the query applies on top of the category")

        // MARK: Sort (AC-4)

        check(list(sort: FileTreeSortOrder(field: .name, ascending: true)) ==
              ["build", "docs", "src", "alpha.txt", "image.png", "readme.md", "video.mov", "Zeta.txt"], "name ascending: folders first, case-insensitive")
        check(list(sort: FileTreeSortOrder(field: .name, ascending: false)) ==
              ["src", "docs", "build", "Zeta.txt", "video.mov", "readme.md", "image.png", "alpha.txt"], "name descending: folders still first")
        let byDateDescending = list(sort: FileTreeSortOrder(field: .dateModified, ascending: false)).filter { !["build", "docs", "src"].contains($0) }
        check(byDateDescending == ["alpha.txt", "Zeta.txt", "image.png", "video.mov", "readme.md"],
              "date descending; equal dates fall back to name ascending: \(byDateDescending)")
        let byDateAscending = list(sort: FileTreeSortOrder(field: .dateModified, ascending: true)).filter { !["build", "docs", "src"].contains($0) }
        check(byDateAscending == ["readme.md", "image.png", "video.mov", "alpha.txt", "Zeta.txt"], "date ascending: \(byDateAscending)")
        check(Array(list(sort: FileTreeSortOrder(field: .dateModified, ascending: false)).prefix(3)).allSatisfy { ["build", "docs", "src"].contains($0) },
              "folders precede files whatever the field")

        // MARK: Workspace level (AC-2)

        let places = FileBrowser.workspaceEntries(source: source(), applyQuery: true)
        check(names(places) == ["project", "Notes"], "the project folder and the linked folder are siblings: \(names(places))")
        check(places.allSatisfy { $0.isDirectory && $0.root != nil }, "places are folders that carry their root")
        check(names(FileBrowser.workspaceEntries(source: source(FileBrowserFilter(query: "note")), applyQuery: true)) == ["Notes"],
              "the query filters the places")
        check(names(FileBrowser.workspaceEntries(source: source(FileBrowserFilter(hideIgnored: true, category: .folders)), applyQuery: true)) == ["project", "Notes"],
              "category and ignore filters never remove a place")
        let dotted = FileBrowserRoot(url: path(base, ".dotproject"), name: ".dotproject", linkedID: nil)
        try fm.createDirectory(at: dotted.url, withIntermediateDirectories: true)
        check(names(FileBrowser.workspaceEntries(source: source(roots: [dotted]), applyQuery: true)) == [".dotproject"],
              "a project folder whose name starts with a dot is still shown")

        // MARK: Tree (AC-1)

        let collapsed = FileBrowser.treeRows(source: source(), expanded: [])
        check(collapsed.map(\.depth) == [0, 0] && collapsed.allSatisfy { !$0.isExpanded && $0.isExpandable }, "a collapsed tree shows the two places")
        let opened = FileBrowser.treeRows(source: source(), expanded: [projectRoot.key, FileBrowser.key(path(project, "src"))])
        check(opened.map(\.entry.name).prefix(4) == ["project", "build", "docs", "src"], "expanding the project lists its children below it")
        let srcIndex = opened.firstIndex { $0.entry.name == "src" }!
        check(opened[srcIndex].depth == 1 && opened[srcIndex].isExpanded, "the expanded folder is marked open")
        check(opened[srcIndex + 1].entry.name == "main.swift" && opened[srcIndex + 1].depth == 2, "grandchildren sit one level deeper")
        check(opened.last?.entry.name == "Notes" && opened.last?.depth == 0, "the linked folder follows as a sibling of the project")
        let folderTree = FileBrowser.treeRows(source: source(FileBrowserFilter(category: .folders)), expanded: [projectRoot.key])
        check(folderTree.filter { $0.depth == 1 }.allSatisfy { $0.entry.isDirectory }, "Folders applies to the tree")

        // MARK: Search (DEC-001)

        let found = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(Set(names(found.matches)) == ["needle.md", "needle-linked.md"], "search finds files in never-opened folders of the project and of a linked folder: \(names(found.matches))")
        let rows = FileBrowser.searchRows(found, source: source(FileBrowserFilter(query: "needle")))
        check(rows.map(\.entry.name) == ["project", "docs", "deep", "er", "needle.md", "Notes", "deep", "needle-linked.md"],
              "ancestors are kept to reach each match: \(rows.map(\.entry.name))")
        check(rows.map(\.depth) == [0, 1, 2, 3, 4, 0, 1, 2], "the rows carry their depth")
        check(rows.filter(\.isMatch).map(\.entry.name).sorted() == ["Notes", "needle-linked.md", "needle.md", "project"],
              "only the matches (and the places) are drawn as matches")
        check(rows.allSatisfy { $0.entry.isDirectory ? $0.isExpanded : true }, "every ancestor is open")
        check(FileBrowser.searchRows(FileBrowser.search(source: source(FileBrowserFilter(query: "todo"))), source: source(FileBrowserFilter(query: "todo"))).map(\.entry.name)
              == ["Notes", "todo.md"], "a place without a match is left out")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "secret"))).matches.isEmpty, "hidden folders are not searched by default")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "secret", showHidden: true))).matches) == ["secret.md"], "…and are with the hidden toggle")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "out.o"))).matches.count == 1, "ignored folders are searched when shown")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "out.o", hideIgnored: true))).matches.isEmpty, "Hide Git-ignored also hides search results")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "e", category: .folders))).matches).allSatisfy { ["deep", "er", "docs"].contains($0) || $0 == "deep" },
              "category Folders searches folders only")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "video", category: .openable))).matches).isEmpty,
              "category Openable drops files without a viewer from the results")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "video"))).matches) == ["video.mov"], "All keeps them")

        let limited = FileBrowser.search(source: source(FileBrowserFilter(query: "e")), matchLimit: 3)
        check(limited.truncated && limited.matches.count == 3, "a search stops at the match limit and says so")
        var cancelAfter = 2
        let cancelled = FileBrowser.search(source: source(FileBrowserFilter(query: "e")), isCancelled: { cancelAfter -= 1; return cancelAfter < 0 })
        check(!cancelled.truncated, "a cancelled search returns what it had")
        try fm.createSymbolicLink(at: path(project, "loop"), withDestinationURL: project)
        let withLoop = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(Set(names(withLoop.matches)) == ["needle.md", "needle-linked.md"] && !withLoop.truncated, "a symbolic link to a folder is not followed")
        try fm.removeItem(at: path(project, "loop"))
        let locked = path(project, "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let withLocked = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(withLocked.unreadableFolders == 1 && withLocked.matches.count == 2, "an unreadable folder is counted, the rest is searched")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // Breadth-first: a cap reached deep inside the project must not starve a linked folder or a shallow match.
        let capBase = base.appendingPathComponent("cap-project", isDirectory: true)
        let capLinked = base.appendingPathComponent("cap-linked", isDirectory: true)
        for index in 0..<40 { try makeFile(capBase, "node_modules/pkg\(index)/needle-\(index).js") }
        try makeFile(capBase, "needle-shallow.md")
        try makeFile(capLinked, "needle-linked-shallow.md")
        let capRoots = [FileBrowserRoot(url: capBase, name: "cap-project", linkedID: nil),
                        FileBrowserRoot(url: capLinked, name: "Cap linked", linkedID: capLinked.path)]
        let capped = FileBrowser.search(source: source(FileBrowserFilter(query: "needle"), roots: capRoots), matchLimit: 5)
        check(capped.truncated, "the capped search reports that more exist")
        check(Set(names(capped.matches)).isSuperset(of: ["needle-shallow.md", "needle-linked-shallow.md"]),
              "a capped search still returns the shallow matches of every place: \(names(capped.matches))")

        // A linked folder that vanished is still a folder row, so it can be unlinked.
        let gone = FileBrowserRoot(url: base.appendingPathComponent("gone-\(UUID().uuidString)"), name: "Gone", linkedID: "gone")
        let goneEntries = FileBrowser.workspaceEntries(source: source(roots: roots + [gone]), applyQuery: false)
        check(goneEntries.first { $0.name == "Gone" }?.isDirectory == true, "a vanished linked folder stays a folder row")
        check(FileBrowser.listing(of: gone.url, source: source(roots: [gone]), applyQuery: false).isEmpty, "…and lists nothing")

        // MARK: Navigation (AC-2)

        let inside = path(project, "docs/deep")
        check(FileBrowser.parent(of: .workspace, roots: roots) == nil, "the Workspace level has no parent")
        check(FileBrowser.parent(of: .folder(project), roots: roots) == .workspace, ".. from the project root goes to the Workspace level")
        check(FileBrowser.parent(of: .folder(linked), roots: roots) == .workspace, ".. from a linked folder's root goes to the Workspace level")
        check(FileBrowser.parent(of: .folder(inside), roots: roots) == .folder(path(project, "docs")), ".. inside a place goes to the parent folder")
        check(FileBrowser.crumbs(for: .workspace, roots: roots).map(\.title) == ["Workspace"], "the Workspace breadcrumb is alone at the top")
        check(FileBrowser.crumbs(for: .folder(inside), roots: roots).map(\.title) == ["Workspace", "project", "docs", "deep"], "breadcrumbs run from Workspace to the folder")
        check(FileBrowser.crumbs(for: .folder(inside), roots: roots).last?.location == .folder(inside), "the last crumb is the folder itself")
        check(FileBrowser.crumbs(for: .folder(path(linked, "deep")), roots: roots).map(\.title) == ["Workspace", "Notes", "deep"], "a linked folder shows its own name")
        check(FileBrowser.root(containing: path(linked, "deep"), in: roots)?.name == "Notes", "the root of an item is found")
        check(FileBrowser.root(containing: base, in: roots) == nil, "an item outside every place has no root")
        let nested = FileBrowserRoot(url: path(project, "docs"), name: "docs-link", linkedID: "x")
        check(FileBrowser.root(containing: inside, in: roots + [nested])?.name == "docs-link", "the innermost root wins")
        check(FileBrowser.ancestors(of: path(project, "docs/deep/er/needle.md"), roots: roots).map { $0.lastPathComponent } == ["project", "docs", "deep", "er"],
              "ancestors lead from the place's root to the item")
        check(FileBrowser.ancestors(of: project, roots: roots).isEmpty, "a place has no ancestors")

        // MARK: Reveal vs filters (DEC-008)

        let secret = path(project, ".hidden/secret.md")
        let everyFilter = FileBrowserFilter(query: "typed", showHidden: false, hideIgnored: true, category: .folders)
        let toSecret = FileBrowser.relaxing(everyFilter, toShow: secret, source: source(everyFilter))
        check(toSecret.showHidden && toSecret.category == .all && toSecret.query.isEmpty && toSecret.hideIgnored,
              "revealing a file in a hidden folder turns Hidden on, resets Folders to All and clears the query, nothing else")
        let toOut = FileBrowser.relaxing(everyFilter, toShow: path(project, "build/out.o"), source: source(everyFilter))
        check(!toOut.hideIgnored && !toOut.showHidden, "revealing an ignored file turns Hide Git-ignored off only")
        let plain = FileBrowserFilter(category: .openable)
        check(FileBrowser.relaxing(plain, toShow: path(project, "src/notes.md"), source: source(plain)) == FileBrowserFilter(category: .openable),
              "a visible item leaves the filter as it is")
        check(FileBrowser.relaxing(plain, toShow: path(project, "video.mov"), source: source(plain)).category == .all,
              "an item the category hides resets it to All")
        check(FileBrowser.relaxing(everyFilter, toShow: project, source: source(everyFilter)).hideIgnored,
              "revealing a place changes no setting")

    }
}


extension EditorHostTests {
    func testWindowTitleUsesDisplayName() throws {
        func check(_ name: String, _ got: String, _ want: String, line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        check("folder open", WindowTitle.text(version: "1.4", folderName: "my-project"), "my-project — MarkView 1.4")
        check("no folder", WindowTitle.text(version: "1.4", folderName: nil), "MarkView 1.4")
        check("empty folder name", WindowTitle.text(version: "1.4", folderName: ""), "MarkView 1.4")
        check("empty version, folder", WindowTitle.text(version: "", folderName: "foo"), "foo — MarkView")
        check("empty version, no folder", WindowTitle.text(version: "", folderName: nil), "MarkView")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)/my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let name = WindowTitle.folderName(of: dir)
        check("display name of a folder", name, "my-project")
        let title = WindowTitle.text(version: "1.4", folderName: name)
        check("full path never in the title", String(title.contains(dir.path) || title.contains("/")), "false")
        let volume = WindowTitle.folderName(of: URL(fileURLWithPath: "/"))
        check("root volume has a name, not '/'", String(!volume.isEmpty && volume != "/"), "true")
        check("missing folder falls back to last component", WindowTitle.folderName(of: URL(fileURLWithPath: "/no/such/place-xyz")), "place-xyz")

    }
}


/// A view that fills itself with its window's background colour, read from the environment.
private struct ThemeTestProbe: View {
    @Environment(\.palette) private var palette
    var body: some View { palette.bg.frame(width: 40, height: 40) }
}


private extension AppTheme {
    static let darcula = AppTheme("darcula"), midnight = AppTheme("midnight"), graphite = AppTheme("graphite")
    static let tokyoNight = AppTheme("tokyo-night"), carbonRed = AppTheme("carbon-red"), nord = AppTheme("nord")
    static let forest = AppTheme("forest"), paper = AppTheme("paper"), daylight = AppTheme("daylight")
}


extension EditorHostTests {
    @MainActor func testIndependentWindowThemes() {
        var testDefaultsNames: [String] = []
        defer { for name in testDefaultsNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func freshStore() -> ThemeSettingsStore {
            let name = "window-theme-tests-\(UUID().uuidString)"
            testDefaultsNames.append(name)
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return ThemeSettingsStore(defaults: defaults)
        }
        func spin(_ what: String, until done: () -> Bool) {
            let limit = Date().addingTimeInterval(5)
            while !done() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(done(), "timed out waiting for \(what)")
        }
        /// The colour at the middle of a rendered image, as 0xRRGGBB in sRGB (the image is redrawn into an sRGB bitmap first).
        func centre(_ image: NSImage?) -> UInt32? {
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let offset = ((cg.height / 2) * cg.width + cg.width / 2) * 4
            return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
        }

        _ = NSApplication.shared
        // The shipped themes only: a window of this program never reads the real themes folder of the person running it.
        let catalog = ThemeCatalog(userFolder: nil)
        check(catalog.library.ignored.isEmpty && catalog.library.themes.count == 11, "the shipped themes are all there")
        let outFolder = ProcessInfo.processInfo.environment["MARKVIEW_THEME_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        // Project transparency persists independently and is shared by windows of the same project.
        let transparencyName = "transparency-test-\(UUID().uuidString)"
        let transparencyDefaults = UserDefaults(suiteName: transparencyName)!
        let projectA = URL(fileURLWithPath: "/tmp/project-a", isDirectory: true)
        let projectB = URL(fileURLWithPath: "/tmp/project-b", isDirectory: true)
        let transparency = ProjectTransparencyStore(defaults: transparencyDefaults)
        transparency.set(0.45, for: projectA)
        check(transparency.value(for: projectA) == 0.45 && transparency.value(for: projectB) == 0, "projects have independent transparency")
        let restoredTransparency = ProjectTransparencyStore(defaults: transparencyDefaults)
        check(restoredTransparency.value(for: projectA) == 0.45, "project transparency survives relaunch")
        transparency.set(0.2, for: nil)
        check(transparency.value(for: nil) == 0, "a window without a project cannot change a project")
        transparencyDefaults.removePersistentDomain(forName: transparencyName)

        // MARK: windows are independent (criterion 3)
        let store = freshStore()
        let a = WindowTheme(store: store, catalog: catalog), b = WindowTheme(store: store, catalog: catalog)
        check(a.settings.theme == .classicDark && b.settings.theme == .classicDark, "windows start as Classic Dark with nothing saved")
        a.select(.midnight)
        check(a.settings.theme == .midnight && a.webID == "midnight" && a.isDark, "window A takes Midnight")
        check(b.settings.theme == .classicDark && b.webID == "classic-dark", "window B is not changed by A")
        b.select(.paper)
        check(b.webID == "paper" && !b.isDark && a.webID == "midnight", "B takes Paper and A keeps Midnight")
        a.setAccent(ThemeColor(0xFF4D9A))
        check(a.palette.model.accent.rgb == 0xFF4D9A && b.palette.model.accent.rgb == 0x315E9B, "an accent in A does not change B")
        check(a.webAccent == "#FF4D9A" && b.webAccent == nil, "the web payload carries the accent only where it was chosen")
        check(a.webArguments.id == "midnight" && a.webArguments.accent == "#FF4D9A" && a.webArguments.list.count == 3 &&
              b.webArguments.id == "paper" && b.webArguments.accent == nil && b.webArguments.list[1] is NSNull, "web call arguments: id, accent, theme")
        let tail = a.webArguments.payload
        let sent = (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any]
        check(sent?["id"] as? String == "midnight" && sent?["mode"] as? String == "dark" && (sent?["t"] as? [String: String])?.isEmpty == false,
              "the web call carries the whole theme as JSON")
        check((sent?["base"] as? [String: String])?["bg"] == "#151c2b", "and it is the theme's own colours")
        let attributes = a.htmlAttributes
        check(attributes.hasPrefix(##"data-preset="midnight" data-theme="dark" data-accent="#FF4D9A" data-theme-tokens=""##) &&
              b.htmlAttributes.hasPrefix(##"data-preset="paper" data-theme="light" data-theme-tokens=""##), "html attributes for the first paint")
        let escaped = attributes.components(separatedBy: #"data-theme-tokens=""#).last.map { String($0.dropLast()) } ?? ""
        check(!escaped.contains("\"") && !escaped.contains("<") &&
              escaped.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&") == tail,
              "the tokens in the page text are the same JSON, escaped for an attribute")
        let script = a.firstPaintScript
        check(script.contains("setAttribute('data-preset', \"midnight\")") && script.contains("setAttribute('data-accent', \"#FF4D9A\")") &&
              script.contains("setAttribute('data-theme-tokens', \"{") && !script.contains("\n"), "first-paint script sets the same attributes")

        // MARK: accents are remembered per appearance (DEC-002)
        a.select(.graphite)
        check(a.webAccent == nil, "Graphite has no accent of its own yet")
        a.select(.midnight)
        check(a.webAccent == "#FF4D9A", "Midnight gets its accent back")
        a.setAccent(nil)
        check(a.webAccent == nil && a.settings.accentOverride(for: .midnight) == nil, "reset removes the override")

        // MARK: a new window inherits the last change with every accent (DEC-005)
        let s2 = freshStore()
        let first = WindowTheme(store: s2, catalog: catalog)
        first.select(.paper); first.setAccent(ThemeColor(0x00AA00)); first.select(.darcula); first.setAccent(ThemeColor(0x123456))
        let second = WindowTheme(store: s2, catalog: catalog)
        check(second.settings == first.settings, "a new window starts from the last change, accents included")
        second.select(.graphite)
        check(first.settings.theme == .darcula, "the new window is independent of the first")
        let third = WindowTheme(store: s2, catalog: catalog)
        check(third.settings.theme == .graphite && third.settings.accentOverride(for: .paper)?.rgb == 0x00AA00,
              "the next window follows the newest change")

        // MARK: restoring a saved window is not a change anyone made
        let s3 = freshStore()
        let seed = WindowTheme(store: s3, catalog: catalog); seed.select(.midnight)
        let restored = WindowTheme(store: s3, catalog: catalog)
        restored.restore(WindowThemeSettings(theme: .paper, accents: [.paper: ThemeColor(0xABCDEF)]))
        check(restored.settings.theme == .paper && restored.webAccent == "#ABCDEF", "a restored window shows its saved theme and accent")
        check(WindowTheme(store: s3, catalog: catalog).settings.theme == .midnight, "restoring does not become the starting value of new windows")

        // MARK: the window's own appearance
        func makeWindow() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        }
        let w1 = makeWindow(), w2 = makeWindow()
        let t1 = WindowTheme(store: freshStore(), catalog: catalog), t2 = WindowTheme(store: freshStore(), catalog: catalog)
        t1.attach(w1); t2.attach(w2)
        t1.select(.darcula); t2.select(.paper)
        check(w1.appearance?.name == .darkAqua, "a dark preset gives its window the dark appearance")
        check(w2.appearance?.name == .aqua, "Paper gives its window the light appearance")
        t1.select(.system)
        check(w1.appearance == nil, "System leaves the window on the macOS appearance")
        t1.select(.classicLight)
        check(w1.appearance?.name == .aqua, "Classic Light is light")
        t2.detach(w2); t2.select(.midnight)
        check(w2.appearance?.name == .aqua, "a detached window is left alone")

        // MARK: two windows render with two palettes at the same time (criteria 2 and 3)
        @MainActor func render<V: View>(_ view: V) -> NSImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return renderer.nsImage
        }
        let ta = WindowTheme(store: freshStore(), catalog: catalog), tb = WindowTheme(store: freshStore(), catalog: catalog)
        ta.select(.darcula); tb.select(.paper)
        let imageA = render(ThemeTestProbe().windowThemed(ta)), imageB = render(ThemeTestProbe().windowThemed(tb))
        check(centre(imageA) == 0x2B2B2B, "a view in a Darcula window draws the Darcula background (got \(String(describing: centre(imageA))))")
        check(centre(imageB) == 0xFFFCF5, "a view in a Paper window draws the Paper background (got \(String(describing: centre(imageB))))")
        ta.select(.midnight)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x151C2B, "the view follows a theme change at once")
        check(centre(render(ThemeTestProbe().windowThemed(tb))) == 0xFFFCF5, "and the other window does not")
        ta.select(.nord); tb.select(.daylight)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x2E3440, "a view in a Nord window draws the Nord background")
        check(centre(render(ThemeTestProbe().windowThemed(tb))) == 0xF7F9FC, "a view in a Daylight window draws the Daylight background")
        ta.select(.forest)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x1E2A22, "a view in a Forest window draws the Forest background")

        // MARK: the picker draws in every theme and lists what it should
        for theme in [AppTheme.classicDark, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight] {
            let t = WindowTheme(store: freshStore(), catalog: catalog)
            t.select(theme)
            let image = render(ThemePickerView().windowThemed(t))
            check((image?.size.width ?? 0) >= 300 && (image?.size.height ?? 0) > 200, "the picker renders for \(theme)")
            if let outFolder, let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: outFolder).appendingPathComponent("picker-\(theme.id).png"))
            }
        }
        // MARK: a theme file of the person's own is a theme of the window (DEC-003)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("window-theme-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func put(_ name: String, _ text: String) { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        func themeFile(_ id: String, bg: String) -> String {
            ##"{"schema":1,"id":"\##(id)","name":"\##(id.capitalized)","summary":"mine","native":{"bg":"\##(bg)","bgSidebar":"#16222E","text":"#E6EEF5","accent":"#4FC3F7"}}"##
        }
        put("ocean.json", themeFile("ocean", bg: "#0B1620"))
        put("broken.json", "{ not json")
        let own = ThemeCatalog(userFolder: folder)
        check(own.library.definition("ocean") != nil && own.library.ignored.map(\.file) == ["broken.json"], "the person's folder is read and the bad file is reported")
        let mine = WindowTheme(store: freshStore(), catalog: own)
        mine.select(AppTheme("ocean"))
        check(mine.webID == "ocean" && mine.isDark && mine.palette.model.bg.rgb == 0x0B1620 && mine.webArguments.payload.contains(#""id":"ocean""#),
              "a user theme draws natively and is sent to the web pages by the same data")
        check(centre(render(ThemeTestProbe().windowThemed(mine))) == 0x0B1620, "a view in a user-theme window draws the file's background")
        check(own.library.choices(current: .system).contains { $0.name == "Ocean" } && render(ThemePickerView().windowThemed(mine)) != nil,
              "the picker lists it and draws with the notice of the ignored file")

        // A stored theme that is not there is shown as Classic Dark, said once, and comes back with its file.
        let ghost = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
        check(ghost.webID == "classic-dark" && ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "an unknown stored theme is shown as Classic Dark and reported")
        let again = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
        check(again.webID == "classic-dark" && own.missing == ["ghost"], "and reported once")
        put("ghost.json", themeFile("ghost", bg: "#201830"))
        put("late.json", themeFile("late", bg: "#102030"))
        var reloaded = false
        Task { @MainActor in await own.reload(); reloaded = true }
        spin("the catalog to reload") { reloaded }
        check(own.library.definition("late") != nil && own.library.definition("ghost") != nil && own.missing.isEmpty, "a file added while the app runs is found, and the missing theme is no longer missing")
        spin("the windows to follow the catalog") { ghost.webID == "ghost" }
        check(ghost.webID == "ghost" && ghost.palette.model.bg.rgb == 0x201830 && again.webID == "ghost", "windows that had stored it draw it as soon as it is there")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ghost.json"))
        reloaded = false
        Task { @MainActor in await own.reload(); reloaded = true }
        spin("the catalog to reload again") { reloaded }
        spin("the window to fall back") { ghost.webID == "classic-dark" }
        check(ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "a deleted file falls back again, and the choice is kept for when the file returns")

        let system = SystemAppearance.shared
        check(system.isDark == (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "system appearance is read")

    }
}


extension EditorHostTests {
    func testThemeModelAndStoredSettings() throws {
        var testDefaultsNames: [String] = []
        defer { for name in testDefaultsNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func ratio(_ a: ThemeColor, _ b: ThemeColor) -> String { String(format: "%.2f", ThemeColor.contrast(a, b)) }
        let builtInFolder = try XCTUnwrap(ThemeCatalog.bundledFolder)
        let library = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: nil)
        func def(_ id: String) -> ThemeDefinition { library.definition(id)! }
        func palette(_ theme: AppTheme, accent: ThemeColor? = nil) -> ThemePalette { ThemePalette.make(def(theme.id), accent: accent) }

        let presets: [AppTheme] = [.darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight]
        let lightPresets: [AppTheme] = [.paper, .daylight]
        let classics: [AppTheme] = [.classicDark, .classicLight]
        let everyBuiltIn = classics + presets

        // MARK: colour basics
        check(ThemeColor(hex: "#12ab34")?.rgb == 0x12AB34, "lower-case hex with # parses")
        check(ThemeColor(hex: "12AB34")?.hex == "#12AB34", "hex without # parses and prints upper case")
        for bad in ["", "#12", "zzzzzz", "#1234567", "12 456", "#12AB3G"] { check(ThemeColor(hex: bad) == nil, "'\(bad)' is not a colour") }
        check(abs(ThemeColor.contrast(ThemeColor(0x000000), ThemeColor(0xFFFFFF)) - 21) < 0.01, "black on white is 21:1")
        check(abs(ThemeColor.contrast(ThemeColor(0x777777), ThemeColor(0x777777)) - 1) < 0.001, "a colour on itself is 1:1")
        check(ThemeColor(0xFFFFFF).readableText.rgb == 0x000000 && ThemeColor(0x000000).readableText.rgb == 0xFFFFFF, "readable text flips")
        check(ThemeColor(0x000000).mixed(with: ThemeColor(0xFFFFFF), fraction: 0.5).rgb == 0x808080, "mixing halfway")
        check(ThemeColor(0xAB12CD).cssHex == "#ab12cd", "the pages get lower-case #rrggbb")

        // MARK: the catalog of built-in themes is the files in Resources/Themes
        check(library.ignored.isEmpty, "no built-in theme file is ignored: \(library.ignored.map { "\($0.file): \($0.reason)" })")
        check(library.themes.map(\.id) == everyBuiltIn.map(\.id), "the built-in themes come in picker order: \(library.themes.map(\.id))")
        check(library.themes.allSatisfy { $0.source == .builtIn }, "every shipped theme is built in")
        check(Set(library.themes.map(\.name)).count == library.themes.count && library.themes.allSatisfy { !$0.summary.isEmpty }, "every theme has its own name and a summary")
        for t in lightPresets { check(!def(t.id).isDark, "\(t.id) is light even when macOS is dark") }
        for t in presets.filter({ !lightPresets.contains($0) }) + [.classicDark] { check(def(t.id).isDark, "\(t.id) is dark even when macOS is light") }
        check(!def("classic-light").isDark, "Classic Light is light")
        check(library.resolve(.system, systemIsDark: true).definition.id == "classic-dark" &&
              library.resolve(.system, systemIsDark: false).definition.id == "classic-light", "System draws Classic Dark or Classic Light")
        check(library.resolve(.system, systemIsDark: true).missing == nil, "System is never reported as missing")
        let gone = library.resolve(AppTheme("sunset"), systemIsDark: false)
        check(gone.definition.id == "classic-dark" && gone.missing == "sunset", "an id nobody has is shown as Classic Dark and named")
        check(library.resolve(.midnight, systemIsDark: false).definition.id == "midnight" && library.resolve(.midnight, systemIsDark: false).missing == nil,
              "a known theme resolves to itself")

        let rowsMidnight = library.choices(current: .midnight)
        check(rowsMidnight.map(\.theme) == [.system] + presets, "picker lists System and every preset: \(rowsMidnight.map(\.id))")
        let rowsClassic = library.choices(current: .classicDark)
        check(rowsClassic.first?.theme == .classicDark && rowsClassic.count == presets.count + 2, "Classic is listed while active")
        check(library.choices(current: .system).first?.theme == .system, "Classic is not listed while it is not active")
        check(rowsMidnight.first?.name == "System" && rowsMidnight.contains { $0.name == "Tokyo Night" }, "rows carry the names from the files")
        check(library.name(of: .tokyoNight) == "Tokyo Night" && library.name(of: .system) == "System" && library.name(of: AppTheme("x-y")) == "x-y",
              "the name of a theme, of System and of an unknown id")

        // MARK: every theme file gives a native palette and complete web tokens
        let tokenKeys: [String: Set<String>] = Dictionary(uniqueKeysWithValues: ThemeSchema.groups.map { ($0.key, Set($0.value)) })
        func checkPayload(_ theme: ThemeDefinition) {
            let id = theme.id
            let web = try! JSONSerialization.jsonObject(with: Data(theme.webPayload.utf8)) as! [String: Any]
            check(web["id"] as? String == id, "\(id): the payload names the theme")
            check(web["mode"] as? String == (theme.isDark ? "dark" : "light"), "\(id): the payload says dark or light")
            for (group, keys) in tokenKeys {
                let tokens = web[group] as? [String: String] ?? [:]
                // The terminal's background, foreground, cursor and selection follow the accent and are worked out by the page, unless a theme states them.
                let required = group == "term" ? keys.subtracting(["background", "foreground", "cursor", "selectionBackground"]) : keys
                check(Set(tokens.keys).isSubset(of: keys) && required.isSubset(of: Set(tokens.keys)),
                      "\(id): web.\(group) has its tokens (missing \(required.subtracting(tokens.keys).sorted()))")
                for (key, value) in tokens where ThemeColor(hex: value) == nil || value != value.lowercased() || value.count != 7 {
                    check(false, "\(id): web.\(group).\(key) is #rrggbb (\(value))")
                }
            }
            let base = web["base"] as? [String: String] ?? [:]
            let p = ThemePalette.make(theme)
            check(base["bg"] == p.bg.cssHex && base["panel"] == p.bgSidebar.cssHex && base["text"] == p.text.cssHex && base["accent"] == p.defaultAccent.cssHex,
                  "\(id): the web base colours are the native ones (one definition)")
            check(!theme.webPayload.contains("\n") && !theme.webPayload.contains("<"), "\(id): the payload is one line of JSON without markup")
        }
        for theme in library.themes { checkPayload(theme) }
        check(!def("classic-dark").web.vars.isEmpty && !def("classic-dark").web.ownAccentVars.isEmpty && def("classic-dark").web.mermaidBuiltIn &&
              def("classic-dark").web.chart?.count == 8, "Classic keeps its exact page values")
        check(presets.allSatisfy { def($0.id).web.vars.isEmpty && !def($0.id).web.mermaidBuiltIn }, "the presets state tokens only")

        // MARK: legibility of every preset (criterion 6) and Classic's own text
        for theme in everyBuiltIn {
            let p = palette(theme)
            let strict = !classics.contains(theme)
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
                check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(theme.id) text on \(name) is \(ratio(p.text, surface))")
                check(ThemeColor.contrast(p.textBright, surface) >= 4.5, "\(theme.id) bright text on \(name) is \(ratio(p.textBright, surface))")
            }
            check(ThemeColor.contrast(p.text, p.selection) >= 4.5, "\(theme.id) text on selection is \(ratio(p.text, p.selection))")
            check(ThemeColor.contrast(p.onAccent, p.badge) >= 4.5, "\(theme.id) text on badge is \(ratio(p.onAccent, p.badge))")
            check(p.isDark == def(theme.id).isDark, "\(theme.id) palette dark flag matches")
            guard strict else { continue }
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar)] {
                check(ThemeColor.contrast(p.textDim, surface) >= 4.5, "\(theme.id) dim text on \(name) is \(ratio(p.textDim, surface))")
                for (cn, c) in [("accent", p.blue), ("green", p.green), ("orange", p.orange), ("yellow", p.yellow),
                                ("purple", p.purple), ("red", p.red), ("cyan", p.cyan)] {
                    check(ThemeColor.contrast(c, surface) >= 4.5, "\(theme.id) \(cn) on \(name) is \(ratio(c, surface))")
                }
            }
            check(ThemeColor.contrast(p.border, p.bg) >= 1.3, "\(theme.id) border is visible on the background (\(ratio(p.border, p.bg)))")
            check(ThemeColor.contrast(p.bgActive, p.bg) >= 1.15, "\(theme.id) the active row is distinguishable (\(ratio(p.bgActive, p.bg)))")
        }

        // Base colours approved in DEC-003.
        let approved: [(AppTheme, UInt32, UInt32, UInt32, UInt32)] = [
            (.darcula, 0x2B2B2B, 0x323232, 0xE0E0E0, 0xE6A15C), (.midnight, 0x151C2B, 0x1D2738, 0xE5EBF5, 0x79B8FF),
            (.graphite, 0x202124, 0x2A2C30, 0xE8EAED, 0xB39DDB), (.paper, 0xFFFCF5, 0xF2EDE3, 0x292724, 0x315E9B),
            (.nord, 0x2E3440, 0x353C4A, 0xE5E9F0, 0x88C0D0), (.forest, 0x1E2A22, 0x26352B, 0xDDD8C0, 0xA7C080),
            (.daylight, 0xF7F9FC, 0xE8EDF4, 0x1F2933, 0x0F766E)]
        for (theme, bg, panel, text, accent) in approved {
            let n = def(theme.id).native
            check(n.bg.rgb == bg && n.bgSidebar.rgb == panel && n.text.rgb == text && n.accent.rgb == accent, "\(theme.id) keeps its approved base colours")
            let p = palette(theme)
            check(p.bg.rgb == bg && p.bgSidebar.rgb == panel && p.text.rgb == text && p.accent.rgb == accent, "\(theme.id) palette uses them")
        }

        // MARK: Classic is the look before themes (DEC-004)
        let cd = palette(.classicDark), cl = palette(.classicLight)
        check(cd.bg.rgb == 0x1E1E1E && cd.bgSidebar.rgb == 0x252526 && cd.blue.rgb == 0x569CD6 && cd.badge.rgb == 0x007ACC && cd.selection.rgb == 0x264F78,
              "Classic Dark keeps the VS Code Dark+ colours")
        check(cl.bg.rgb == 0xFFFFFF && cl.bgSidebar.rgb == 0xF3F3F3 && cl.cyan.rgb == 0x0070C1 && cl.selection.rgb == 0xADD6FF,
              "Classic Light keeps the Light+ colours")

        // MARK: accent
        let plain = palette(.midnight)
        let pink = ThemeColor(0xFF4D9A)
        let custom = palette(.midnight, accent: pink)
        check(custom.accent == pink && custom.badge == pink, "the accent override is the accent and the badge fill")
        check(custom.selection != plain.selection, "the selection follows the accent")
        check(custom.defaultAccent.rgb == 0x79B8FF, "the default accent is still known")
        let dark = palette(.midnight, accent: ThemeColor(0x101828))
        check(ThemeColor.contrast(dark.blue, dark.bg) >= 4.5 && ThemeColor.contrast(dark.blue, dark.bgSidebar) >= 4.5,
              "an unreadable accent is lightened where it is text (\(ratio(dark.blue, dark.bg)))")
        let pale = palette(.paper, accent: ThemeColor(0xFFF2B0))
        check(ThemeColor.contrast(pale.blue, pale.bg) >= 4.5, "a pale accent on Paper is darkened where it is text (\(ratio(pale.blue, pale.bg)))")
        check(ThemeColor.contrast(pale.onAccent, pale.badge) >= 4.5, "text on a pale badge is readable")
        let paleDay = palette(.daylight, accent: ThemeColor(0xFFF2B0))
        check(ThemeColor.contrast(paleDay.blue, paleDay.bg) >= 4.5 && ThemeColor.contrast(paleDay.blue, paleDay.bgSidebar) >= 4.5,
              "a pale accent on Daylight is darkened where it is text (\(ratio(paleDay.blue, paleDay.bg)))")
        let darkForest = palette(.forest, accent: ThemeColor(0x14301C))
        check(ThemeColor.contrast(darkForest.blue, darkForest.bg) >= 4.5, "a dark accent on Forest is lightened where it is text (\(ratio(darkForest.blue, darkForest.bg)))")
        check(palette(.classicDark, accent: pink).blue != cd.blue, "Classic takes an accent too")

        // MARK: per-appearance accent memory (DEC-002)
        var s = WindowThemeSettings(theme: .midnight)
        s.setAccent(ThemeColor(0xFF0000))
        s.select(.paper)
        check(s.activeOverride == nil, "Paper starts with its default accent")
        s.setAccent(ThemeColor(0x00AA00))
        s.select(.midnight)
        check(s.activeOverride?.rgb == 0xFF0000, "returning to Midnight restores its accent")
        s.setAccent(nil)
        check(s.activeOverride == nil && s.accentOverride(for: .paper)?.rgb == 0x00AA00, "resetting clears only the active appearance")
        check(palette(.midnight, accent: s.activeOverride).accent.rgb == 0x79B8FF, "after a reset the default accent is in use")
        s.select(.system)
        check(ThemePalette.make(library.resolve(s.theme, systemIsDark: true).definition, accent: s.activeOverride).accent.rgb == 0x569CD6,
              "System uses the Classic accent")

        // MARK: stored names (every value an earlier version wrote still decodes)
        let oldNames: [(stored: String, id: String)] = [
            ("classicDark", "classic-dark"), ("classicLight", "classic-light"), ("darcula", "darcula"), ("midnight", "midnight"),
            ("graphite", "graphite"), ("tokyoNight", "tokyo-night"), ("carbonRed", "carbon-red"), ("nord", "nord"), ("forest", "forest"),
            ("paper", "paper"), ("daylight", "daylight"), ("system", "system")]
        func decode(_ json: String) -> WindowThemeSettings? { try? JSONDecoder().decode(WindowThemeSettings.self, from: Data(json.utf8)) }
        for (stored, id) in oldNames {
            let decoded = decode(##"{"theme":"\##(stored)","accents":{"\##(stored)":"#123456"}}"##)
            check(decoded?.theme.id == id, "the stored name \(stored) is the theme \(id)")
            check(decoded?.accentOverride(for: AppTheme(id)) == ThemeColor(0x123456), "the accent stored under \(stored) is kept")
            if id != "system" { check(library.definition(id) != nil, "\(stored) still names a shipped theme") }
            let encoded = try! JSONEncoder().encode(WindowThemeSettings(theme: AppTheme(id)))
            check(String(decoding: encoded, as: UTF8.self).contains("\"\(id)\""), "\(id) is stored under its id")
        }
        check(AppTheme(stored: "tokyoNight") == .tokyoNight && AppTheme(stored: "tokyo-night") == .tokyoNight, "both spellings give the same theme")
        for bad in ["", "Has Space", "a_b", "-lead", "trail-", "a--b", String(repeating: "a", count: 41), "ABC"] {
            check(AppTheme(stored: bad) == nil, "'\(bad)' cannot be a theme id")
        }
        check(decode(##"{"theme":"ocean","accents":{"ocean":"#0A0B0C"}}"##)?.theme.id == "ocean", "a well-formed id with no theme behind it is kept")

        // MARK: coding
        var full = WindowThemeSettings(theme: .graphite)
        full.setAccent(ThemeColor(0x123456))
        full.select(.paper)
        full.setAccent(ThemeColor(0xABCDEF))
        let data = try! JSONEncoder().encode(full)
        check((try? JSONDecoder().decode(WindowThemeSettings.self, from: data)) == full, "settings survive a round trip")
        for theme in [AppTheme.tokyoNight, .carbonRed, .nord, .forest, .daylight] {
            let settings = WindowThemeSettings(theme: theme, accents: [theme: pink])
            let encoded = try! JSONEncoder().encode(settings)
            check((try? JSONDecoder().decode(WindowThemeSettings.self, from: encoded)) == settings, "\(theme.id) and its custom accent survive a relaunch")
        }
        check(decode(#"{"theme":"nope!","accents":{}}"#)?.theme == .classicDark, "a name that cannot be an id becomes Classic Dark")
        check(decode(##"{"theme":"paper","accents":{"paper":"#12","midnight":"#0A0B0C","x y":"#ffffff"}}"##)?.accents == [.midnight: ThemeColor(0x0A0B0C)],
              "unreadable accents and names that cannot be ids are dropped")
        check(decode(#"{"theme":"paper"}"#)?.theme == .paper, "a missing accents map is empty")
        check(decode(#"{"theme":3,"accents":[1]}"#)?.theme == .classicDark, "wrong types give the fallback")

        // MARK: starting settings, upgrade and inheritance (criteria 4 and 5, DEC-004, DEC-005)
        func store() -> (ThemeSettingsStore, UserDefaults) {
            let name = "theme-model-tests-\(UUID().uuidString)"
            testDefaultsNames.append(name)
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return (ThemeSettingsStore(defaults: d), d)
        }
        var (st, d) = store()
        check(st.startingSettings().theme == .classicDark, "nothing saved (today's default) starts as Classic Dark")
        d.set("light", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicLight, "a saved light setting stays light (Classic Light)")
        d.set("dark", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a saved dark setting stays dark (Classic Dark)")
        d.set("system", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a saved system setting keeps today's dark look")
        d.set("purple", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "an unreadable legacy value falls back to Classic Dark")
        d.set(42, forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a legacy value of the wrong type falls back to Classic Dark")

        d.set("light", forKey: Setting.legacyTheme.name)
        st.remember(full)
        check(st.startingSettings() == full, "the last change wins over the legacy setting and keeps every accent (DEC-005)")
        var newWindow = st.startingSettings()
        newWindow.select(.darcula)
        newWindow.setAccent(ThemeColor(0x010203))
        check(st.startingSettings() == full, "changing a window does not change the stored value until it is remembered")
        st.remember(newWindow)
        check(st.startingSettings().accentOverride(for: .paper)?.rgb == 0xABCDEF && st.startingSettings().theme == .darcula,
              "the next window gets the newest theme with the whole collection")

        d.set(Data("not json".utf8), forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "an unreadable last-changed record falls back to the legacy setting")
        d.set(Data(##"{"theme":"bo gus","accents":{"paper":"#112233"}}"##.utf8), forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "a record that names no possible theme is not used")
        d.set(42, forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "a record of the wrong type is not used")

        // MARK: user themes, from a folder of the person's own files
        let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-model-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }
        let userFolder = workFolder.appendingPathComponent("themes", isDirectory: true)
        try! FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String, in folder: URL? = nil) {
            try! Data(text.utf8).write(to: (folder ?? userFolder).appendingPathComponent(name))
        }
        func themeJSON(_ id: String, native: String, extra: String = "") -> String {
            #"{"schema":1,"id":"\#(id)","name":"\#(id.capitalized)","summary":"A test theme","native":{\#(native)}\#(extra)}"#
        }
        let oceanNative = ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##
        let sandNative = ##""bg":"#FBF6EC","bgSidebar":"#F0E8D8","text":"#2B2A28","accent":"#9A4F1B""##
        write("ocean.json", themeJSON("ocean", native: oceanNative))
        write("sand.json", themeJSON("sand", native: sandNative, extra: #","order":15,"picker":"listed""#))
        write("pinned.json", themeJSON("pinned", native: oceanNative, extra: ##","web":{"syn":{"keyword":"#FF00FF"},"t":{"codeBg":"#0A121A"}}"##))
        let withUser = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder)
        check(withUser.ignored.isEmpty, "valid user themes are not reported: \(withUser.ignored)")
        check(withUser.themes.count == everyBuiltIn.count + 3, "three user themes join the built-in ones")
        check(withUser.themes.map(\.order) == withUser.themes.map(\.order).sorted(), "the list is in order")
        check(withUser.themes.map(\.id).firstIndex(of: "sand") == 2, "order puts a user theme among the built-in ones (\(withUser.themes.map(\.id)))")
        check(withUser.themes.first { $0.id == "ocean" }?.source == .user(file: "ocean.json"), "a user theme knows its file")
        check(withUser.choices(current: .midnight).contains { $0.theme == AppTheme("ocean") && $0.name == "Ocean" }, "a user theme is a row of the picker")
        check(withUser.resolve(AppTheme("ocean"), systemIsDark: false).definition.id == "ocean", "a user theme resolves")
        for id in ["ocean", "sand", "pinned"] {
            let t = withUser.definition(id)!
            checkPayload(t)
            let p = ThemePalette.make(t)
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
                check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(id): derived surface \(name) keeps the text readable (\(ratio(p.text, surface)))")
            }
            for (cn, c) in [("green", p.green), ("orange", p.orange), ("yellow", p.yellow), ("purple", p.purple), ("red", p.red), ("cyan", p.cyan), ("dim", p.textDim)] {
                check(ThemeColor.contrast(c, p.bg) >= 4.5 && ThemeColor.contrast(c, p.bgSidebar) >= 4.5, "\(id): derived \(cn) is readable on both backgrounds")
            }
            check(t.web.vars.isEmpty && t.web.ownAccentVars.isEmpty && t.web.chart == nil && !t.web.mermaidBuiltIn, "\(id): no exact page values")
            let codeBackgrounds = [t.web.t["codeBg"]!, t.web.t["preBg"]!]
            for group in [t.web.syn, t.web.structure] {
                for (key, value) in group where key != "count" {
                    for background in codeBackgrounds {
                        check(ThemeColor.contrast(value, background) >= 4.5, "\(id): token \(key) reads on the code background (\(ratio(value, background)))")
                    }
                }
            }
            for key in ["textSecondary", "textTertiary", "secondary", "danger", "success", "warning", "h2", "h3"] {
                check(ThemeColor.contrast(t.web.t[key]!, p.bg) >= 4.5, "\(id): t.\(key) reads on the page background (\(ratio(t.web.t[key]!, p.bg)))")
            }
        }
        check(withUser.definition("ocean")!.isDark && !withUser.definition("sand")!.isDark, "dark or light follows the background")
        let pinned = withUser.definition("pinned")!
        check(pinned.web.syn["keyword"]?.rgb == 0xFF00FF && pinned.web.t["codeBg"]?.rgb == 0x0A121A, "a token a file gives wins over derivation")
        check(pinned.web.syn["string"]?.rgb != 0xFF00FF && pinned.web.t["preBg"] == withUser.definition("ocean")!.web.t["preBg"],
              "the tokens it does not give are derived as for any other theme")
        check(withUser.definition("ocean")!.webPayload == ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder).definition("ocean")!.webPayload,
              "the same file gives the same payload")

        // MARK: files that cannot be used are reported with their reason, never skipped silently
        let problemFolder = workFolder.appendingPathComponent("problems", isDirectory: true)
        try! FileManager.default.createDirectory(at: problemFolder, withIntermediateDirectories: true)
        let good = oceanNative
        let problems: [(file: String, text: String, reason: String)] = [
            ("broken.json", "{ not json", "not a JSON object"),
            ("array.json", "[1, 2]", "not a JSON object"),
            ("noschema.json", #"{"id":"noschema","name":"X","native":{}}"#, "no schema version"),
            ("future.json", #"{"schema":2,"id":"future","name":"X","native":{}}"#, "newer"),
            ("zero.json", #"{"schema":0,"id":"zero","name":"X","native":{}}"#, "not a known version"),
            ("badid.json", themeJSON("Bad_Id", native: good), "lower-case letters"),
            ("mismatch.json", themeJSON("other", native: good), "named \"mismatch.json\""),
            ("noname.json", ##"{"schema":1,"id":"noname","native":{"bg":"#000000"}}"##, "\"name\""),
            ("nonative.json", #"{"schema":1,"id":"nonative","name":"X"}"#, "\"native\" is missing"),
            ("missingkey.json", themeJSON("missingkey", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5""##), "native.accent"),
            ("badcolour.json", themeJSON("badcolour", native: ##""bg":"red","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
            ("shortcolour.json", themeJSON("shortcolour", native: ##""bg":"#000","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
            ("unknownnative.json", themeJSON("unknownnative", native: good + ##","glow":"#FFFFFF""##), "\"glow\""),
            ("unknowntop.json", themeJSON("unknowntop", native: good, extra: #","css":"body{display:none}""#), "unknown key \"css\""),
            ("lowtext.json", themeJSON("lowtext", native: ##""bg":"#202020","bgSidebar":"#242424","text":"#2A2A2A","accent":"#4FC3F7""##), "contrast"),
            ("lowaccent.json", themeJSON("lowaccent", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#0C1722""##), "\"accent\""),
            ("cssvalue.json", themeJSON("cssvalue", native: good, extra: #","web":{"t":{"codeBg":"red; background:url(https://x.test/a)"}}"#), "#RRGGBB"),
            ("unknowntoken.json", themeJSON("unknowntoken", native: good, extra: ##","web":{"syn":{"glow":"#FFFFFF"}}"##), "\"glow\""),
            ("varsindata.json", themeJSON("varsindata", native: good, extra: ##","web":{"vars":{"--bg-primary":"#000000"}}"##), "only allowed in the themes that ship"),
            ("chartshort.json", themeJSON("chartshort", native: good, extra: ##","web":{"chart":["#000000"]}"##), "8 colours"),
            ("picker.json", themeJSON("picker", native: good, extra: #","picker":"hidden""#), "\"picker\""),
            ("order.json", themeJSON("order", native: good, extra: #","order":-1"#), "\"order\""),
            ("classic-dark.json", themeJSON("classic-dark", native: good), "built-in theme"),
            ("huge.json", themeJSON("huge", native: good, extra: #","summary":"\#(String(repeating: "x", count: 70_000))""#), "larger than"),
        ]
        for item in problems { write(item.file, item.text, in: problemFolder) }
        write("notes.txt", "this is not a theme file", in: problemFolder)
        write("fine.json", themeJSON("fine", native: good), in: problemFolder)
        write("unreadable.json", themeJSON("unreadable", native: good), in: problemFolder)
        chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o000)
        let before = Dictionary(uniqueKeysWithValues: problems.map { ($0.file, try! Data(contentsOf: problemFolder.appendingPathComponent($0.file))) })
        let checked = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder)
        check(checked.themes.map(\.id).contains("fine"), "a good file next to bad ones is used")
        check(checked.themes.count == everyBuiltIn.count + 1, "no bad file becomes a theme (\(checked.themes.count - everyBuiltIn.count) user themes)")
        for item in problems {
            let found = checked.ignored.first { $0.file == item.file }
            check(found != nil, "\(item.file) is reported, not skipped")
            check(found?.reason.contains(item.reason) == true, "\(item.file): the reason names the problem (wanted \"\(item.reason)\", got \"\(found?.reason ?? "-")\")")
        }
        check(checked.ignored.first { $0.file == "unreadable.json" }?.reason.contains("cannot be read") == true, "an unreadable file is reported")
        check(!checked.ignored.contains { $0.file == "notes.txt" || $0.file == "fine.json" }, "a file that is not .json is not a theme file, and a good one is not reported")
        check(checked.ignored.count == problems.count + 1, "exactly the bad files are reported (\(checked.ignored.map(\.file)))")
        for item in problems { check((try? Data(contentsOf: problemFolder.appendingPathComponent(item.file))) == before[item.file], "\(item.file) is left exactly as it was") }
        chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o644)

        // MARK: limits and odd folders
        let crowdedFolder = workFolder.appendingPathComponent("crowded", isDirectory: true)
        try! FileManager.default.createDirectory(at: crowdedFolder, withIntermediateDirectories: true)
        for number in 0..<(ThemeLibrary.userFileLimit + 2) {
            write(String(format: "t%03d.json", number), themeJSON(String(format: "t%03d", number), native: good), in: crowdedFolder)
        }
        let crowded = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: crowdedFolder)
        check(crowded.themes.count == everyBuiltIn.count + ThemeLibrary.userFileLimit, "no more than \(ThemeLibrary.userFileLimit) user files are read")
        check(crowded.ignored.count == 2 && crowded.ignored.allSatisfy { $0.reason.contains("more than \(ThemeLibrary.userFileLimit)") }, "the files beyond the limit are reported")
        check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: workFolder.appendingPathComponent("absent")).ignored.isEmpty, "a missing themes folder is not a problem")
        check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder.appendingPathComponent("fine.json")).ignored.count == 1,
              "a themes 'folder' that is a file is reported")
        let noBuiltIn = ThemeLibrary.load(builtInFolder: nil, userFolder: nil)
        check(noBuiltIn.themes.isEmpty && noBuiltIn.ignored.count == 1, "an app without its built-in folder says so")

        // MARK: adding a built-in theme is adding one file
        let extendedFolder = workFolder.appendingPathComponent("builtin", isDirectory: true)
        try! FileManager.default.copyItem(at: builtInFolder, to: extendedFolder)
        write("aurora.json", themeJSON("aurora", native: ##""bg":"#10201C","bgSidebar":"#162A25","text":"#E3F2EC","accent":"#5CE0B8""##, extra: ##","order":105"##), in: extendedFolder)
        let extended = ThemeLibrary.load(builtInFolder: extendedFolder, userFolder: nil)
        check(extended.themes.count == library.themes.count + 1 && extended.ignored.isEmpty, "one more file is one more theme")
        check(extended.themes.last?.id == "aurora", "it is listed in its place with nothing else edited")
        check(extended.choices(current: .midnight).map(\.theme.id).last == "aurora", "and it is a row of the picker")
        let aurora = ThemePalette.make(extended.definition("aurora")!)
        check(aurora.isDark && ThemeColor.contrast(aurora.text, aurora.bg) >= 4.5, "and it draws")

    }
}


private let windowStateTestModeKey = SettingsKey<String>("search.panelMode", default: "Project", scope: .window)

extension EditorHostTests {
    @MainActor func testWindowStateIsolation() throws {
        let editorDirectory = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // The test's own keys: the registry's names with defaults a stored value can be told from.
        let modeKeyX = SettingsKey<String>("search.panelMode", default: "x", scope: .window)
        let infoKey = SettingsKey<Bool>("contents.infoExpanded", default: true, scope: .window)
        let countKey = SettingsKey<Int>("n", default: 0, scope: .window)
        let countKey7 = SettingsKey<Int>("n", default: 7, scope: .window)
        let countAsText = SettingsKey<String>("n", default: "", scope: .window)

        func freshDefaults() -> (UserDefaults, () -> Void) {
            let suite = "window-ui-state-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            return (defaults, { defaults.removePersistentDomain(forName: suite) })
        }

        // MARK: Two windows (WindowUIState belongs to the main actor, as the views that read it do)

        @MainActor func twoWindows() {
            let (defaults, cleanup) = freshDefaults()
            defer { cleanup() }
            let a = WindowUIState(defaults: defaults), b = WindowUIState(defaults: defaults)
            check(a.value(windowStateTestModeKey) == "Project", "a value nobody set is the fallback")
            check(b.value(windowStateTestModeKey) == "Project", "the second window starts the same")

            a.set("Documents", for: windowStateTestModeKey)
            check(a.value(windowStateTestModeKey) == "Documents", "the window that changed a value shows it")
            check(b.value(windowStateTestModeKey) == "Project", "another window that already shows it stays on its own value")

            b.set(false, for: infoKey)
            check(a.value(infoKey), "a flag set in one window leaves the other expanded, even one it shows only now")

            var changes = 0
            let watcher = b.objectWillChange.sink { changes += 1 }
            a.set("Project", for: windowStateTestModeKey)
            check(changes == 0, "a change in one window does not redraw another window")
            b.set(350.0, for: Setting.uiStudioInspectorWidth)
            check(changes == 1, "a change in the window redraws that window")
            b.set(350.0, for: Setting.uiStudioInspectorWidth)
            check(changes == 1, "setting the same value again redraws nothing")
            b.set(360.0, for: Setting.leftPanelWidth, publishing: false)
            check(changes == 1, "a divider position kept by an AppKit view redraws nothing")
            watcher.cancel()

            let later = WindowUIState(defaults: defaults)
            check(later.value(modeKeyX) == "Project", "a window opened later starts from the last value anywhere")
            check(later.value(Setting.leftPanelWidth) == 360.0, "the seed of a quiet value is kept too")
            a.set("Documents", for: windowStateTestModeKey)
            check(later.value(modeKeyX) == "Project", "and from then on follows nobody")
        }
        twoWindows()

        // MARK: The session

        @MainActor func theSession() {
            let (defaults, cleanup) = freshDefaults()
            let (emptyDefaults, emptyCleanup) = freshDefaults()
            defer { cleanup(); emptyCleanup() }
            let a = WindowUIState(defaults: defaults)
            a.set("Documents", for: windowStateTestModeKey)
            a.set(412.0, for: Setting.uiStudioInspectorWidth)
            a.set(false, for: infoKey)
            a.set(4, for: countKey)
            let data = try! JSONEncoder().encode(a.saved)
            let decoded = try! JSONDecoder().decode([String: WindowUIValue].self, from: data)
            check(decoded == a.saved, "the values survive the session file")

            let restored = WindowUIState(defaults: emptyDefaults)
            restored.restore(decoded)
            check(restored.value(windowStateTestModeKey) == "Documents" &&
                  restored.value(Setting.uiStudioInspectorWidth) == 412.0 &&
                  !restored.value(infoKey) && restored.value(countKey) == 4,
                  "a restored window has its own values, not the starting ones")

            let old = WindowUIState(defaults: emptyDefaults)
            old.restore(nil)
            check(old.saved.isEmpty && old.value(windowStateTestModeKey) == "Project", "a session saved before interface state has none")

            let wrongType = WindowUIState(defaults: emptyDefaults)
            wrongType.restore(["n": .string("not a number")])
            check(wrongType.value(countKey7) == 7, "a restored value of the wrong type falls back")
            check(wrongType.existing(countKey7) == 7 && wrongType.existing(countAsText) == nil, "the fallback replaces it, and existing() reads only the stored type")
        }
        theSession()

        // MARK: The editor page's own choices

        do {
            let keys = EditorWindowPrefs.keys
            check(keys.contains("markview-font-size") && keys.contains("markview-xray-details-width") && keys.contains("markview-code-notes-width")
                  && keys.contains("markview-xray-details-hidden"), "the text size, the panel widths and the X-Ray details are the window's")
            check(!keys.contains { $0.hasPrefix("mvMap:") }, "a map's view of a document is not the window's")
            check(EditorWindowPrefs.accepts(key: "markview-font-size", value: "13"), "the page may save its text size")
            check(!EditorWindowPrefs.accepts(key: "markview-other", value: "1"), "a key the window does not keep is refused")
            check(!EditorWindowPrefs.accepts(key: "markview-font-size", value: String(repeating: "9", count: 33)), "a long value is refused")
            check(Setting.editorPref("markview-font-size").name == "editor.markview-font-size", "the window files the value under its own name")

            let script = EditorWindowPrefs.script(values: ["markview-font-size": "16", "markview-other": "1", "markview-code-notes-width": "</script>"])
            check(script.contains("\"markview-font-size\":\"16\""), "the window's text size starts the page")
            check(!script.contains("markview-other\":"), "a value for a key the window does not keep is not passed to the page")
            check(!script.contains("</script>"), "nothing in the script can end the script element")
        }

        // MARK: Excluded folders belong to the project

        do {
            let (defaults, cleanup) = freshDefaults()
            defer { cleanup() }
            let one = URL(fileURLWithPath: "/work/one/app"), two = URL(fileURLWithPath: "/work/two/app")
            check(ExcludedFolders.key(for: one).name != ExcludedFolders.key(for: two).name, "two projects with the same folder name have different keys")
            let settings = Settings(defaults)
            check(ExcludedFolders.load(for: one, defaults: defaults).isEmpty, "a project with nothing excluded has none")
            ExcludedFolders.save(["build", "node_modules"], for: one, defaults: defaults)
            check(ExcludedFolders.load(for: one, defaults: defaults) == ["build", "node_modules"], "a project's list comes back")
            check(ExcludedFolders.load(for: two, defaults: defaults).isEmpty, "another project of the same folder name does not get it")

            settings.set(["dist"], for: Setting.excludedFoldersByName("legacy"))
            let legacy = URL(fileURLWithPath: "/work/legacy")
            check(ExcludedFolders.load(for: legacy, defaults: defaults) == ["dist"], "a list saved under the folder's name is not lost")
            ExcludedFolders.save(["dist", "out"], for: legacy, defaults: defaults)
            check(settings.stored(Setting.excludedFoldersByName("legacy")) == ["dist"], "and the project's own changes do not touch the old entry")
            check(ExcludedFolders.load(for: legacy, defaults: defaults) == ["dist", "out"], "the project then keeps its own list")
        }

        // MARK: Two hosted windows (@WindowStorage)

        /// What a hosted view last showed, and the binding it was given.
        final class Shown {
            var text = ""
            var renders = 0
            var binding: Binding<String>?
        }

        struct ModeView: View {
            @WindowStorage(windowStateTestModeKey) private var mode: String
            let shown: Shown
            var body: some View {
                shown.text = mode
                shown.renders += 1
                shown.binding = $mode
                return Text(mode)
            }
        }

        @MainActor func hostedChecks() {
            _ = NSApplication.shared
            let (defaults, cleanup) = freshDefaults()
            defer { cleanup() }
            var windows: [NSWindow] = []
            func host(_ state: WindowUIState, _ shown: Shown) {
                let hosting = NSHostingView(rootView: ModeView(shown: shown).environmentObject(state))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                windows.append(window)
            }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

            let stateA = WindowUIState(defaults: defaults), stateB = WindowUIState(defaults: defaults)
            let shownA = Shown(), shownB = Shown()
            host(stateA, shownA)
            host(stateB, shownB)
            settle()
            check(shownA.text == "Project" && shownB.text == "Project", "both hosted windows start on the same mode")

            let rendersB = shownB.renders
            shownA.binding?.wrappedValue = "Documents"
            settle()
            check(shownA.text == "Documents", "the window where the person changed the mode shows it")
            check(shownB.text == "Project", "the other window stays on its own mode")
            check(shownB.renders == rendersB, "and is not even redrawn")

            shownB.binding?.wrappedValue = "Project"
            shownB.binding?.wrappedValue = "Documents"
            settle()
            shownA.binding?.wrappedValue = "Project"
            settle()
            check(shownA.text == "Project" && shownB.text == "Documents", "each window goes its own way")
            check(stateA.saved["search.panelMode"] == .string("Project") && stateB.saved["search.panelMode"] == .string("Documents"),
                  "and each saves its own value with its session")
            windows.forEach { $0.close() }
        }
        hostedChecks()

        // MARK: The editor page, in two real web views that share one localStorage

        final class PageMessages: NSObject, WKScriptMessageHandler {
            var received: [[String: Any]] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { received.append(body) }
            }
        }

        @MainActor func pageChecks() {
            _ = NSApplication.shared
            let editor = editorDirectory
            let contract = try! BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json"))
            let mvKit = (try! String(contentsOfFile: editor + "/js/mv-kit.js", encoding: .utf8)).replacingOccurrences(of: "</", with: "<\\/")
            var keep: [WKWebView] = []
            let isolatedWebsiteData = WKWebsiteDataStore.nonPersistent()
            func page(own: [String: String]) -> (WKWebView, PageMessages) {
                let messages = PageMessages()
                let config = WKWebViewConfiguration()
                config.websiteDataStore = isolatedWebsiteData
                config.userContentController.add(messages, name: "bridge")
                // The page sends through mvBridge (mv-kit.js) with the contract the app gives it, as the editor does (AR-28).
                config.userContentController.addUserScript(contract.userScript)
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
                web.loadHTMLString("<html><head><script>\(mvKit)</script><script>\(EditorWindowPrefs.script(values: own))</script></head><body>x</body></html>",
                                   baseURL: URL(string: "https://markview.test/"))
                let deadline = Date().addingTimeInterval(10)
                while web.isLoading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                keep.append(web)
                return (web, messages)
            }
            func run(_ web: WKWebView, _ js: String) -> String {
                var result = "no answer"
                var done = false
                web.evaluateJavaScript(js) { value, error in
                    result = (value as? String) ?? error.map { "ERR \($0)" } ?? "nil"
                    done = true
                }
                let deadline = Date().addingTimeInterval(5)
                while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                return result
            }
            let size = "String(localStorage.getItem('markview-font-size'))"

            let (a, messagesA) = page(own: ["markview-font-size": "16"])
            check(run(a, "localStorage.clear(); 'cleared'") == "cleared", "the page's own localStorage still works")
            let (b, messagesB) = page(own: [:])
            check(run(a, size) == "16", "a page starts with its window's own text size")
            check(run(b, size) == "null", "a window with none starts from the shared store (empty here)")

            check(run(a, "localStorage.setItem('markview-font-size', 18); \(size)") == "18", "a save in the page is read back by the page")
            check(messagesA.received.count == 1 && messagesA.received[0]["type"] as? String == "editorWindowPref" &&
                  (messagesA.received[0]["payload"] as? [String: Any])?["key"] as? String == "markview-font-size" &&
                  (messagesA.received[0]["payload"] as? [String: Any])?["value"] as? String == "18",
                  "and reported to the app with its key and value")
            check(run(b, size) == "null", "the other window's page does not see it")
            check(messagesB.received.isEmpty, "and heard nothing")

            check(run(b, "localStorage.setItem('other-key', 'x'); String(localStorage.getItem('other-key'))") == "x", "any other key is the shared localStorage as before")
            check(messagesB.received.isEmpty, "and is not reported")

            let (c, _) = page(own: [:])
            check(run(c, size) == "18", "a window opened later starts from the last choice anywhere")
            check(run(a, "localStorage.setItem('markview-code-notes-width', 300); String(localStorage.getItem('markview-code-notes-width'))") == "300",
                  "the panel widths go the same way")
            check(run(c, "String(localStorage.getItem('markview-code-notes-width'))") == "300", "a page that has not read a width yet starts from the shared one")
            _ = keep
        }
        pageChecks()

    }
}
