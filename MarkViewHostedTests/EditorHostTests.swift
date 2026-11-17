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
    @MainActor func testCockpitAgentRegistryTickets() async {
        let root = URL(fileURLWithPath: "/tmp/project-a"), other = URL(fileURLWithPath: "/tmp/project-b")
        var replies: [CockpitHostReply] = []
        var progressReports: [CockpitProgress] = []
        let ticket = CockpitAgentRegistry.register(root: root, progress: { progressReports.append($0) }) { replies.append($0) }
        let progress = CockpitProgress(passNumber: 2, activity: "Testing", scenarioCoverage: ["checkout"], bugs: ["BUG-1"], fixes: [], latestChange: "Changed", blockers: [], buildLogPath: "build/log.txt")
        guard !(await CockpitAgentRegistry.report(root: other, token: ticket, progress: progress)),
              await CockpitAgentRegistry.report(root: root, token: ticket, progress: progress), progressReports == [progress] else { XCTFail("progress was not project-scoped"); return }
        var invalid = progress; invalid.passNumber = 0
        guard !(await CockpitAgentRegistry.report(root: root, token: ticket, progress: invalid)) else { XCTFail("invalid pass accepted"); return }
        invalid = progress; invalid.activity = String(repeating: "x", count: 16_001)
        guard !(await CockpitAgentRegistry.report(root: root, token: ticket, progress: invalid)) else { XCTFail("oversized progress accepted"); return }
        let result = CockpitHostResult(passed: true, detail: "Done", build: "b1")
        guard !CockpitAgentRegistry.complete(root: other, token: ticket, result: result), replies.isEmpty else { XCTFail("cross-project report accepted"); return }
        let long = CockpitHostResult(passed: true, detail: String(repeating: "x", count: 32_001), build: "")
        guard !CockpitAgentRegistry.complete(root: root, token: ticket, result: long), replies.isEmpty else { XCTFail("oversized report accepted"); return }
        guard CockpitAgentRegistry.complete(root: root, token: ticket, result: result), replies.count == 1,
              !CockpitAgentRegistry.complete(root: root, token: ticket, result: result) else { XCTFail("ticket was not one-use"); return }
        guard !(await CockpitAgentRegistry.report(root: root, token: ticket, progress: progress)) else { XCTFail("expired ticket accepted progress"); return }
        let unsaved = CockpitAgentRegistry.register(root: root, progress: { _ in throw NSError(domain: "test", code: 1) }) { replies.append($0) }
        guard !(await CockpitAgentRegistry.report(root: root, token: unsaved, progress: progress)) else { XCTFail("failed persistence was acknowledged"); return }
        CockpitAgentRegistry.cancel(unsaved, reason: "Unavailable")
        let interrupted = CockpitAgentRegistry.register(root: root) { replies.append($0) }
        CockpitAgentRegistry.cancel(interrupted, reason: "Stopped")
        CockpitAgentRegistry.cancel(interrupted, reason: "Again")
        guard replies.count == 3, replies[2].error == "Stopped" else { XCTFail("cancellation was not one-use"); return }
        _ = CockpitAgentRegistry.register(root: root) { replies.append($0) }
        _ = CockpitAgentRegistry.register(root: other) { replies.append($0) }
        CockpitAgentRegistry.cancelAll(reason: "Closing")
        guard replies.count == 5, replies.suffix(2).allSatisfy({ $0.error == "Closing" }) else { XCTFail("app close did not stop every cockpit assignment"); return }
        var waited = false
        _ = CockpitAgentRegistry.register(root: root, waitForShutdown: { waited = true }) { replies.append($0) }
        await CockpitAgentRegistry.cancelAllAndWait(reason: "Quitting")
        guard waited, replies.last?.error == "Quitting" else { XCTFail("quit did not wait for terminal shutdown"); return }

    }
}


extension EditorHostTests {
    func testCockpitPlanValidationAndCompatibility() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(value(), message, line: line)
        }
        let step = CockpitStep(title: "Review", agent: "Codex", assignment: "Inspect the project", completionCondition: "Report findings")
        var plan = CockpitPlan(goal: "Inspect", controls: CockpitControls(), scenarios: [], steps: [step], successCriteria: ["Report provided"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        var scenarioPlan = plan
        scenarioPlan.scenarios = ["scenario"]
        scenarioPlan.steps[0].qaScenarioID = "scenario"
        scenarioPlan.steps.append(CockpitStep(title: "Verify", agent: "Codex", assignment: "Review evidence", completionCondition: "Criteria assessed"))
        check(CockpitApproval(plan: scenarioPlan, productionConfirmed: true) == nil, "a selected scenario requires its exact QA review")
        let reviewed = CockpitQAReview(scenarioID: "scenario", targetID: "prod", fingerprint: "hash", production: true, exactPlan: "exact", dataChangingActions: ["write"])
        scenarioPlan.qaReviews = [reviewed]
        scenarioPlan.productionQA = CockpitProductionQA(exactPlan: "exact", dataChangingActions: ["write"])
        check(CockpitApproval(plan: scenarioPlan, productionConfirmed: false) == nil, "production data changes require explicit confirmation")
        let scenarioApproval = CockpitApproval(plan: scenarioPlan, productionConfirmed: true)
        check(scenarioApproval != nil, "the exact production QA plan can be approved")
        scenarioPlan.qaReviews?[0].fingerprint = "changed"
        check(scenarioApproval?.permits(scenarioPlan) == false, "a changed QA fingerprint invalidates cockpit approval")
        var progress = CockpitProgress(passNumber: 1, activity: "Done", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
        check(CockpitOutcome.evaluate(criteria: ["Report provided"], progress: progress) == .unverified, "a finished run is not called successful without criterion evidence")
        progress.criteriaResults = [CockpitCriterionResult(criterion: "Report provided", met: true, evidence: "Report exists")]
        check(CockpitOutcome.evaluate(criteria: ["Report provided"], progress: progress) == .success, "matching evidence supports success")
        progress.blockers = ["Unresolved issue"]
        check(CockpitOutcome.evaluate(criteria: ["Report provided"], progress: progress) == .blocked, "remaining blockers prevent a success outcome")
        var skipQA = scenarioPlan
        skipQA.steps.append(CockpitStep(title: "Later", agent: "Codex", assignment: "Continue", completionCondition: "Done"))
        let later = skipQA.selectingStart(1)
        check(later?.scenarios.isEmpty == true && later?.steps[0].qaScenarioID == nil && later?.productionQA == nil,
              "starting after a QA step excludes its production actions from approval")
        check(plan.problems.isEmpty, "a complete plan is valid")
        let approval = CockpitApproval(plan: plan, productionConfirmed: false)!
        check(approval.permits(plan), "approval permits the reviewed plan")
        plan.steps[0].assignment = "Change files"
        check(!approval.permits(plan), "changing an assignment invalidates approval")
        plan.steps[0].assignment = step.assignment
        plan.controls.fixBugs = true
        check(!approval.permits(plan), "changing controls invalidates approval")
        plan.controls.fixBugs = false
        plan.productionQA = CockpitProductionQA(exactPlan: "Create and delete a record", dataChangingActions: ["Create a record", "Delete a record"])
        check(CockpitApproval(plan: plan, productionConfirmed: false) == nil, "production changes need explicit confirmation")
        let productionApproval = CockpitApproval(plan: plan, productionConfirmed: true)!
        plan.productionQA?.dataChangingActions.append("Update a record")
        check(!productionApproval.permits(plan), "changed production actions invalidate approval")
        plan.steps.append(step)
        check(!plan.problems.isEmpty, "duplicate step identifiers are rejected")
        let roundTrip = try JSONDecoder().decode(CockpitPlan.self, from: JSONEncoder().encode(plan))
        check(roundTrip == plan, "plan retains its reviewed contents through persistence")

        // MARK: Per-step models, supervisor choice, old data

        let oldStepJSON = #"{"id":"11111111-1111-1111-1111-111111111111","title":"Old","agent":"Codex","assignment":"A","completionCondition":"C","isPrerequisite":false}"#
        let oldStep = try JSONDecoder().decode(CockpitStep.self, from: Data(oldStepJSON.utf8))
        check(oldStep.model == nil && oldStep.chosenModel == nil, "a step saved before models existed decodes with the default model")
        let oldStepEncoded = String(decoding: try JSONEncoder().encode(oldStep), as: UTF8.self)
        check(!oldStepEncoded.contains("model"), "a step without a model encodes without the key, so old approvals keep their value")
        let oldControlsJSON = #"{"createScenarios":false,"checks":"","fileBugs":true,"fixBugs":false,"build":false,"deployment":"Disabled"}"#
        let oldControls = try JSONDecoder().decode(CockpitControls.self, from: Data(oldControlsJSON.utf8))
        check(oldControls.supervisorAgent == nil && oldControls.supervisorModel == nil && oldControls.supervisor, "controls saved before the supervisor's model was chosen decode with the project's assistant")
        // Controls a step carries as text: readable controls are read as they are; text that cannot be read is replaced by the restrictive defaults (AR-36).
        var storedControls = CockpitControls(); storedControls.fixBugs = true; storedControls.timeLimitMinutes = 30; storedControls.fixCycleLimit = 2
        let storedControlsText = String(decoding: (try? JSONEncoder().encode(storedControls)) ?? Data(), as: UTF8.self)
        check(CockpitControls(storedJSON: storedControlsText) == storedControls, "controls carried as text are read as they were set")
        check(CockpitControls(storedJSON: "{ \"fixBugs\": ") == CockpitControls(), "controls that cannot be read are the restrictive defaults")
        check(CockpitControls(storedJSON: "") == CockpitControls() && CockpitControls().fixBugs == false && CockpitControls().build == false,
              "empty controls are the restrictive defaults, which fix and build nothing")
        var chosenControls = CockpitControls(); chosenControls.supervisorAgent = " Codex "; chosenControls.supervisorModel = "gpt-5"
        let chosenBack = try JSONDecoder().decode(CockpitControls.self, from: JSONEncoder().encode(chosenControls))
        check(chosenBack.supervisorAgent == "Codex" && chosenBack.supervisorModel == "gpt-5", "the supervisor's agent and model round-trip, trimmed")
        var blankControls = CockpitControls(); blankControls.supervisorModel = "   "
        let blankBack = try JSONDecoder().decode(CockpitControls.self, from: JSONEncoder().encode(blankControls))
        check(blankBack.supervisorModel == nil, "a blank supervisor model reads as the default")
        var modelStep = CockpitStep(title: "M", agent: "Codex", assignment: "A", completionCondition: "C")
        modelStep.model = "  gpt-5 "
        check(modelStep.chosenModel == "gpt-5", "a step's model is trimmed")
        modelStep.model = " "
        check(modelStep.chosenModel == nil, "a blank step model is the default")
        let freshPlan = CockpitPlan(goal: "G", controls: CockpitControls(), scenarios: [], steps: [CockpitStep(title: "A", agent: "Codex", assignment: "Do A", completionCondition: "A done")],
                                    successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        var withModel = freshPlan
        withModel.steps[0].model = "gpt-5"
        let freshApproval = CockpitApproval(plan: freshPlan, productionConfirmed: false)
        check(freshApproval?.permits(freshPlan) == true && freshApproval?.permits(withModel) == false, "changing only a step's model invalidates the approval")

        // MARK: The flow's title

        check(CockpitText.firstLine("\n  First line  \nSecond") == "First line" && CockpitText.firstLine(" \n ") == "", "the first non-empty line of a text")
        var named = CockpitPlan(goal: "  \nWrite the quarterly report\nwith charts", controls: CockpitControls(), scenarios: [], steps: [], successCriteria: [], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        check(named.title == nil && named.displayTitle == "Write the quarterly report", "a plan without a title is named by the first line of its goal")
        named.title = "  "
        check(named.displayTitle == "Write the quarterly report", "a blank title is no title")
        named.title = "Quarterly report"
        check(named.displayTitle == "Quarterly report" && named.goal.hasPrefix("  \n"), "the title names the flow and the goal stays what the person typed")
        let namedBack = try JSONDecoder().decode(CockpitPlan.self, from: JSONEncoder().encode(named))
        check(namedBack == named, "a plan keeps its title through persistence")
        let encodedNames = try JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as? [String: Any] ?? [:]
        check(encodedNames["title"] as? String == "Quarterly report", "a title is saved with the plan")
        named.title = nil
        let encodedUntitled = try JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as? [String: Any] ?? [:]
        check(encodedUntitled["title"] == nil, "a plan without a title saves no title key, so the fingerprint of every earlier plan is unchanged")
        let oldPlanBack = try JSONDecoder().decode(CockpitPlan.self, from: JSONEncoder().encode(named))
        check(oldPlanBack.title == nil && oldPlanBack == named, "a plan saved before titles existed loads with none")

        // MARK: Approval blockers keep the old guards' outcome

        /// The guards `CockpitApproval.init?` held before they became `approvalBlockers`: the oracle the list must agree with.
        func oldApprovalAllowed(_ plan: CockpitPlan, _ productionConfirmed: Bool) -> Bool {
            guard plan.problems.isEmpty else { return false }
            guard Set(plan.steps.compactMap(\.qaScenarioID)) == Set(plan.scenarios) else { return false }
            guard plan.scenarios.isEmpty || plan.steps.last?.qaScenarioID == nil else { return false }
            if plan.scenarios.isEmpty, plan.qaReviews?.isEmpty == false { return false }
            if !plan.scenarios.isEmpty {
                guard let reviews = plan.qaReviews, reviews.count == plan.scenarios.count,
                      Set(reviews.map(\.scenarioID)) == Set(plan.scenarios), Set(plan.scenarios).count == plan.scenarios.count,
                      reviews.allSatisfy({ !$0.fingerprint.isEmpty && !$0.exactPlan.isEmpty && !$0.targetID.isEmpty }) else { return false }
                let production = reviews.filter(\.production)
                if production.contains(where: \.productionConfirmationRequired) && !productionConfirmed { return false }
                if !production.isEmpty {
                    guard plan.productionQA == CockpitProductionQA(exactPlan: production.map(\.exactPlan).joined(separator: "\n\n"),
                                                                   dataChangingActions: production.flatMap(\.dataChangingActions)) else { return false }
                }
            }
            if let qa = plan.productionQA, !qa.dataChangingActions.isEmpty, !productionConfirmed { return false }
            return true
        }

        func titled(_ title: String, qa: String? = nil) -> CockpitStep {
            CockpitStep(title: title, agent: "Codex", assignment: "Do \(title)", completionCondition: "\(title) done", qaScenarioID: qa)
        }
        let review = CockpitQAReview(scenarioID: "s1", targetID: "t", fingerprint: "f", production: false, exactPlan: "{}", dataChangingActions: [])
        let prodReview = CockpitQAReview(scenarioID: "s1", targetID: "prod", fingerprint: "f", production: true, exactPlan: "{}", dataChangingActions: ["write"])
        let prodQA = CockpitProductionQA(exactPlan: "{}", dataChangingActions: ["write"])
        func base(steps: [CockpitStep], scenarios: [String] = []) -> CockpitPlan {
            CockpitPlan(goal: "G", controls: CockpitControls(), scenarios: scenarios, steps: steps, successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        }
        var cases: [(String, CockpitPlan)] = []
        cases.append(("plain", base(steps: [titled("A")])))
        cases.append(("no steps", base(steps: [])))
        var noGoal = base(steps: [titled("A")]); noGoal.goal = " "; cases.append(("no goal", noGoal))
        var noCriteria = base(steps: [titled("A")]); noCriteria.successCriteria = []; cases.append(("no criteria", noCriteria))
        var emptyField = base(steps: [titled("A")]); emptyField.steps[0].assignment = ""; cases.append(("empty assignment", emptyField))
        var duplicate = base(steps: [titled("A")]); duplicate.steps.append(duplicate.steps[0]); cases.append(("duplicate ids", duplicate))
        cases.append(("scenario without a step", base(steps: [titled("A")], scenarios: ["s1"])))
        cases.append(("step without a scenario entry", base(steps: [titled("A", qa: "s1"), titled("V")])))
        cases.append(("qa last", base(steps: [titled("A"), titled("Q", qa: "s1")], scenarios: ["s1"])))
        var noReview = base(steps: [titled("Q", qa: "s1"), titled("V")], scenarios: ["s1"]); cases.append(("qa without a review", noReview))
        var reviewedPlan = noReview; reviewedPlan.qaReviews = [review]; cases.append(("qa reviewed", reviewedPlan))
        var strayReview = base(steps: [titled("A")]); strayReview.qaReviews = [review]; cases.append(("review without a scenario", strayReview))
        var emptyReview = reviewedPlan; emptyReview.qaReviews = [CockpitQAReview(scenarioID: "s1", targetID: "", fingerprint: "f", production: false, exactPlan: "{}", dataChangingActions: [])]; cases.append(("review without a target", emptyReview))
        var prod = noReview; prod.qaReviews = [prodReview]; cases.append(("production without its plan", prod))
        var prodWithPlan = prod; prodWithPlan.productionQA = prodQA; cases.append(("production with its plan", prodWithPlan))
        var prodWrong = prod; prodWrong.productionQA = CockpitProductionQA(exactPlan: "other", dataChangingActions: ["write"]); cases.append(("production plan mismatch", prodWrong))
        var strayProduction = base(steps: [titled("A")]); strayProduction.productionQA = prodQA; cases.append(("production actions without QA", strayProduction))
        var needsConfirm = prodWithPlan; needsConfirm.qaReviews = [CockpitQAReview(scenarioID: "s1", targetID: "prod", fingerprint: "f", production: true, exactPlan: "{}", dataChangingActions: ["write"], productionConfirmationRequired: true)]; cases.append(("production confirmation required", needsConfirm))
        for (name, candidate) in cases {
            for confirmed in [false, true] {
                let blockers = candidate.approvalBlockers(productionConfirmed: confirmed)
                check(blockers.isEmpty == oldApprovalAllowed(candidate, confirmed), "approval blockers agree with the old guards: \(name), confirmed \(confirmed)")
                check((CockpitApproval(plan: candidate, productionConfirmed: confirmed) != nil) == blockers.isEmpty, "approval exists exactly when nothing blocks it: \(name), confirmed \(confirmed)")
                check(blockers.allSatisfy { !$0.message.isEmpty }, "every blocker says why: \(name)")
            }
        }
        check(emptyField.approvalBlockers(productionConfirmed: false).first?.stepID == emptyField.steps[0].id, "a blocker of one step names that step")
        check(base(steps: [titled("A"), titled("Q", qa: "s1")], scenarios: ["s1"]).approvalBlockers(productionConfirmed: false).contains { $0.stepID != nil && $0.message.contains("final verification") },
              "the missing final verification points at the last step")

        // MARK: Editing keeps the invariants

        var edit = base(steps: [titled("A"), titled("B", qa: "s1"), titled("C")], scenarios: ["s1"])
        edit.qaReviews = [review]; edit.productionQA = prodQA
        let ids = edit.steps.map(\.id)
        edit.moveStep(at: 0, by: 1)
        check(edit.steps.map(\.title) == ["B", "A", "C"], "a step moves down")
        edit.moveStep(at: 0, by: -1)
        check(edit.steps.map(\.title) == ["B", "A", "C"], "a step cannot move above the first place")
        edit.moveStep(at: 2, by: 1)
        check(edit.steps.map(\.title) == ["B", "A", "C"], "a step cannot move below the last place")
        edit.normalizeScenarios()
        check(edit.scenarios == ["s1"] && edit.qaReviews == nil && edit.productionQA == nil, "normalizing follows the steps and drops the reviews that were derived from the old order")
        edit.duplicateStep(at: 0)
        check(edit.steps.count == 4 && Set(edit.steps.map(\.id)).count == 4 && edit.steps[1].title == edit.steps[0].title, "a duplicate gets its own identity")
        check(edit.steps[1].qaScenarioID == nil && edit.steps[1].isPrerequisite == false, "a duplicate never repeats a QA scenario or a prerequisite")
        edit.removeStep(at: 0)
        check(edit.scenarios.isEmpty && !edit.steps.contains { $0.qaScenarioID != nil }, "removing the only QA step removes its scenario")
        check(Set(edit.steps.map(\.id)).count == edit.steps.count && edit.steps.count == 3, "removal keeps identities unique")
        edit.insertStep(titled("New"), at: 99)
        check(edit.steps.last?.title == "New", "an insert past the end appends")
        edit.insertStep(titled("First"), at: -5)
        check(edit.steps.first?.title == "First", "an insert before the start prepends")
        edit.setAgent("Claude Code", forStep: edit.steps[0].id)
        edit.setModel("opus", forStep: edit.steps[0].id)
        check(edit.steps[0].agent == "Claude Code" && edit.steps[0].model == "opus", "agent and model are set by step id")
        edit.setAgent("Codex", forStep: edit.steps[0].id)
        check(edit.steps[0].model == nil, "changing the agent clears the model, which belonged to the other agent")
        edit.setModel("", forStep: edit.steps[0].id)
        check(edit.steps[0].model == nil, "an empty model is the default")
        _ = ids

        var shaping = CockpitControls()
        var limited = shaping; limited.timeLimitMinutes = 60; limited.fixCycleLimit = 3; limited.supervisor = false; limited.supervisorModel = "opus"
        check(!limited.affectsSteps(comparedTo: shaping), "limits and the supervisor change no step")
        var building = shaping; building.build = true
        check(building.affectsSteps(comparedTo: shaping), "what the planner was told does change the steps")

    }
}


extension EditorHostTests {
    func testCockpitPlanningParser() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(value(), message, line: line)
        }
        let step: [String: Any] = ["title": "Research", "agent": "Codex", "assignment": "Inspect", "completionCondition": "Report", "isPrerequisite": true, "qaScenarioID": ""]
        var answer: [String: Any] = ["scenarios": [], "steps": [step], "successCriteria": ["Report exists"], "unavailableOutcomes": ["Delivery"], "alternatives": ["Prepare an order"]]
        var controls = CockpitControls(); controls.fixBugs = false
        let schema = CockpitPlanning.schema
        let rootRequired = Set(schema["required"] as? [String] ?? [])
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let stepSchema = properties["steps"]?["items"] as? [String: Any] ?? [:]
        check(rootRequired == Set(["title", "scenarios", "steps", "successCriteria", "unavailableOutcomes", "alternatives"]), "the schema requires every root field the parser reads, the flow's title among them")
        check(Set(stepSchema["required"] as? [String] ?? []) == Set(["title", "agent", "model", "assignment", "completionCondition", "isPrerequisite", "qaScenarioID"]), "the schema requires every step field the parser reads")
        let plan = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
        check(plan.controls == controls && plan.steps.first?.isPrerequisite == true, "the person's controls and prerequisite survive parsing")
        check(plan.unavailableOutcomes == ["Delivery"] && plan.alternatives == ["Prepare an order"], "unavailable outcomes and alternatives survive parsing")
        check((try? CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Claude"])) == nil, "an unavailable agent is rejected")
        var qaAnswer = answer
        qaAnswer["scenarios"] = ["scenario-1"]
        check((try? CockpitPlanning.parse(qaAnswer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "an unassigned QA scenario is rejected")
        var qaStep = step; qaStep["qaScenarioID"] = "scenario-1"; qaAnswer["steps"] = [qaStep]
        check((try? CockpitPlanning.parse(qaAnswer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "QA needs a final verification step")
        qaAnswer["steps"] = [qaStep, step]
        check((try? CockpitPlanning.parse(qaAnswer, goal: "Research", controls: controls, availableAgents: ["Codex"]))?.steps.first?.qaScenarioID == "scenario-1", "a QA scenario is tied to its step")
        answer["steps"] = []
        answer["successCriteria"] = []
        let infeasible = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
        check(infeasible.unavailableOutcomes == ["Delivery"] && CockpitApproval(plan: infeasible, productionConfirmed: false) == nil,
              "an infeasible goal can be explained but cannot be approved for execution")
        var modelStep = step; modelStep["model"] = "gpt-5"
        answer["steps"] = [modelStep]
        answer["successCriteria"] = ["Report exists"]
        let known = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"], models: ["Codex": ["gpt-5", "gpt-5-mini"]])
        check(known.steps.first?.model == "gpt-5", "a proposed model the agent offers is kept")
        let unknown = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"], models: ["Codex": ["gpt-5-mini"]])
        check(unknown.steps.first?.model == nil, "a proposed model the agent does not offer becomes the default instead of failing the plan")
        let unlisted = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
        check(unlisted.steps.first?.model == nil, "without a model list no proposed model is trusted")
        modelStep["model"] = "  "
        answer["steps"] = [modelStep]
        let blank = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"], models: ["Codex": ["gpt-5"]])
        check(blank.steps.first?.model == nil, "a blank model means the default")

        // MARK: The assistant's name for the flow

        var titled = answer
        let untitled = try CockpitPlanning.parse(titled, goal: "Research the market\nin detail", controls: controls, availableAgents: ["Codex"])
        check(untitled.title == nil, "an answer without a title still parses, with no title")
        check(untitled.displayTitle == "Research the market", "without a title the flow is named by the first line of the goal")
        func parsedTitle(_ value: Any?) throws -> String? {
            titled["title"] = value
            return try CockpitPlanning.parse(titled, goal: "Research", controls: controls, availableAgents: ["Codex"]).title
        }
        let kept = try parsedTitle("Market research report")
        check(kept == "Market research report", "a title is kept")
        let collapsed = try parsedTitle("  Weekly\n release   checklist \n")
        check(collapsed == "Weekly release checklist", "line breaks and extra spaces in a title collapse to single spaces")
        let curly = try parsedTitle("\u{201C}Ship the release\u{201D}"), straight = try parsedTitle("'Ship it'")
        check(curly == "Ship the release" && straight == "Ship it", "quotes around a title are removed")
        let russian = try parsedTitle("Проверка релиза")
        check(russian == "Проверка релиза", "a title in the language of the goal is kept as it is")
        let longTitle = try parsedTitle(String(repeating: "word ", count: 40))
        check((longTitle?.count ?? 0) <= CockpitPlanning.maxTitleLength && longTitle?.hasSuffix(" ") == false, "a long title is cut to the limit")
        let blankTitle = try parsedTitle("   "), quotesOnly = try parsedTitle("\"\"")
        check(blankTitle == nil && quotesOnly == nil, "a blank title is no title and does not fail the plan")
        let wrongType = try parsedTitle(42), noTitle = try parsedTitle(nil)
        check(wrongType == nil && noTitle == nil, "a title of the wrong type is no title and does not fail the plan")

        answer["steps"] = [["title": "Missing fields"]]
        check((try? CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "malformed steps are rejected")

    }
}


extension EditorHostTests {
    func testTextDiffAndChangeExplanation() {
        func check(_ value: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(value, message + (detail.isEmpty ? "" : " — " + detail), line: line)
        }
        /// Applying a diff to the old text must give the new text: the hunks lose nothing and invent nothing.
        func replay(_ old: [String], _ hunks: [DiffHunk]) -> [String] {
            var result: [String] = []
            var cursor = 0   // next old line (0-based) not yet copied
            for hunk in hunks {
                let firstOld = hunk.lines.compactMap(\.oldNumber).min().map { $0 - 1 } ?? cursor
                // For a hunk made only of added lines the first old line is a context one after it, or the end.
                if firstOld > cursor { result += old[cursor..<firstOld] }
                cursor = max(cursor, firstOld)
                for line in hunk.lines {
                    switch line.kind {
                    case .context: result.append(line.text); cursor = (line.oldNumber ?? cursor + 1)
                    case .added: result.append(line.text)
                    case .removed: cursor = (line.oldNumber ?? cursor)
                    }
                }
            }
            if cursor < old.count { result += old[cursor...] }
            return result
        }

        func numbered(_ n: Int, _ prefix: String = "line") -> String { (1...n).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n" }

        // MARK: Basics
        check(TextDiff.hunks(old: "a\nb\n", new: "a\nb\n").isEmpty, "equal texts have no hunks")
        check(TextDiff.hunks(old: nil, new: nil).isEmpty && TextDiff.hunks(old: "", new: "").isEmpty, "nothing against nothing has no hunks")

        var hunks = TextDiff.hunks(old: nil, new: "one\ntwo\nthree\n")
        check(hunks.count == 1 && hunks[0].added == 3 && hunks[0].removed == 0, "a new file is one hunk of added lines", "\(hunks.map { ($0.added, $0.removed) })")
        check(hunks.first?.location == "lines 1–3" && hunks.first?.summary == "Adds 3 lines", "...located at lines 1–3 and summarised", "\(hunks.first?.location ?? "") / \(hunks.first?.summary ?? "")")

        hunks = TextDiff.hunks(old: "one\ntwo\n", new: nil)
        check(hunks.count == 1 && hunks[0].removed == 2 && hunks[0].added == 0, "a deleted file is one hunk of removed lines")
        check(hunks.first?.location == "removed from old lines 1–2" && hunks.first?.summary == "Removes 2 lines", "...located by its old lines", hunks.first?.location ?? "")

        // MARK: A change in the middle of a file, with context and numbers
        let old = numbered(20)
        var edited = old.components(separatedBy: "\n")
        edited[9] = "line 10 CHANGED"
        hunks = TextDiff.hunks(old: old, new: edited.joined(separator: "\n"))
        check(hunks.count == 1, "one edit is one hunk", "\(hunks.count)")
        if let hunk = hunks.first {
            check(hunk.added == 1 && hunk.removed == 1, "a replaced line is one added and one removed line")
            check(hunk.lines.count == 3 + 2 + 3, "it has three lines of context on each side (8 lines)", "\(hunk.lines.count)")
            check(hunk.location == "line 10 (was line 10)", "it says where the change is, new and old", hunk.location)
            check(hunk.summary == "Replaces 1 line with 1", "it says what happened", hunk.summary)
            let removed = hunk.lines.first { $0.kind == .removed }, added = hunk.lines.first { $0.kind == .added }
            check(removed?.oldNumber == 10 && removed?.newNumber == nil && removed?.text == "line 10", "the removed line has its old number and text")
            check(added?.newNumber == 10 && added?.oldNumber == nil && added?.text == "line 10 CHANGED", "the added line has its new number and text")
            check(hunk.lines.first?.oldNumber == 7 && hunk.lines.last?.oldNumber == 13, "context runs from line 7 to line 13", "\(hunk.lines.first?.oldNumber ?? 0)…\(hunk.lines.last?.oldNumber ?? 0)")
        }

        // MARK: Line numbers shift after an insertion
        var inserted = old.components(separatedBy: "\n")
        inserted.insert(contentsOf: ["new a", "new b"], at: 4)
        hunks = TextDiff.hunks(old: old, new: inserted.joined(separator: "\n"))
        check(hunks.count == 1 && hunks[0].added == 2 && hunks[0].removed == 0, "an insertion is one hunk of added lines")
        check(hunks.first?.location == "lines 5–6" && hunks.first?.summary == "Adds 2 lines", "its location is in the new text", hunks.first?.location ?? "")
        let after = hunks.first?.lines.last
        check(after?.newNumber == 9 && after?.oldNumber == 7, "the context after it is numbered in both texts (old 7 is new 9)", "\(after?.oldNumber ?? 0)/\(after?.newNumber ?? 0)")

        // MARK: Far apart edits are separate hunks, near ones share one
        var far = old.components(separatedBy: "\n")
        far[1] = "early"; far[18] = "late"
        hunks = TextDiff.hunks(old: old, new: far.joined(separator: "\n"))
        check(hunks.count == 2, "edits 17 lines apart are two hunks", "\(hunks.count)")
        var near = old.components(separatedBy: "\n")
        near[5] = "a"; near[9] = "b"
        check(TextDiff.hunks(old: old, new: near.joined(separator: "\n")).count == 1, "edits 4 lines apart share one hunk")

        // MARK: A pure removal says where
        var removedMiddle = old.components(separatedBy: "\n")
        removedMiddle.removeSubrange(9..<12)
        hunks = TextDiff.hunks(old: old, new: removedMiddle.joined(separator: "\n"))
        check(hunks.count == 1 && hunks[0].removed == 3 && hunks[0].added == 0, "removing three lines is one hunk")
        check(hunks.first?.location == "removed from old lines 10–12, after line 9" && hunks.first?.summary == "Removes 3 lines", "it says which old lines went", hunks.first?.location ?? "")

        // MARK: Replaying every diff gives the new text back (the diff loses nothing and invents nothing)
        var seed: UInt64 = 12345
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var replayFailures = 0
        for round in 0..<300 {
            let a = (0..<(random(40))).map { _ in "w\(random(6))" }
            var b = a
            for _ in 0..<random(8) {
                switch random(3) {
                case 0 where !b.isEmpty: b.remove(at: random(b.count))
                case 1: b.insert("w\(random(9))", at: random(b.count + 1))
                default: if !b.isEmpty { b[random(b.count)] = "x\(random(9))" }
                }
            }
            let oldText = a.isEmpty ? nil : a.joined(separator: "\n") + "\n", newText = b.isEmpty ? nil : b.joined(separator: "\n") + "\n"
            let result = TextDiff.hunks(old: oldText, new: newText)
            if replay(a, result) != b { replayFailures += 1; if replayFailures == 1 { print("first failing round \(round): \(a) -> \(b)") } }
        }
        check(replayFailures == 0, "300 random edits: every diff replays to the new text", "\(replayFailures) failed")

        // MARK: Many edits and a rewrite stay quick and complete
        let big = (1...6000).map { "row \($0)" }
        var bigEdited = big
        for i in stride(from: 100, to: 6000, by: 250) { bigEdited[i] = "changed \(i)" }
        var started = Date()
        hunks = TextDiff.hunks(old: big.joined(separator: "\n"), new: bigEdited.joined(separator: "\n"))
        check(hunks.count == 24 && Date().timeIntervalSince(started) < 2, "24 edits in 6000 lines: 24 hunks, quickly", "\(hunks.count) hunks, \(Date().timeIntervalSince(started))s")
        started = Date()
        let rewritten = (1...6000).map { "other \($0)" }
        hunks = TextDiff.hunks(old: big.joined(separator: "\n"), new: rewritten.joined(separator: "\n"))
        check(hunks.count == 1 && hunks[0].removed == 6000 && hunks[0].added == 6000 && Date().timeIntervalSince(started) < 3,
              "a full rewrite is one hunk of everything replaced, without a long search", "\(hunks.count) hunks, \(Date().timeIntervalSince(started))s")

        // MARK: CRLF and a missing final newline
        check(TextDiff.hunks(old: "a\r\nb\r\n", new: "a\r\nb\r\n").isEmpty, "the same CRLF text has no hunks")
        hunks = TextDiff.hunks(old: "a\nb", new: "a\nb\nc")
        check(hunks.count == 1 && hunks[0].added == 1 && hunks[0].lines.last?.text == "c", "a line added after one with no final newline")
        check(TextDiff.lines(of: "a\r\nb\r\n") == ["a", "b"], "CRLF line ends are not part of the lines")

        // MARK: The section a change sits in
        let swift = """
        import Foundation

        final class Model {
            var a = 1

            func startNew() {
                original = nil
                selected = nil
                id = ""
            }

            private func save() {
                let editing = original
            }
        }
        """
        var changed = swift.replacingOccurrences(of: "selected = nil", with: "selected = 0")
        hunks = TextDiff.hunks(old: swift, new: changed)
        check(hunks.first?.section == "func startNew()", "a change inside a method names the method", hunks.first?.section ?? "nil")
        changed = swift.replacingOccurrences(of: "let editing = original", with: "let editing = copy")
        hunks = TextDiff.hunks(old: swift, new: changed)
        check(hunks.first?.section == "func save()", "modifiers are dropped from the section (private func save())", hunks.first?.section ?? "nil")
        changed = swift.replacingOccurrences(of: "var a = 1", with: "var a = 2")
        check(TextDiff.hunks(old: swift, new: changed).first?.section == "class Model", "a property names its type (final dropped)", TextDiff.hunks(old: swift, new: changed).first?.section ?? "nil")
        let markdown = "# Guide\n\ntext\n\n## Install\n\nrun it\n"
        hunks = TextDiff.hunks(old: markdown, new: markdown.replacingOccurrences(of: "run it", with: "run it twice"))
        check(hunks.first?.section == "## Install", "a change in a document names its heading", hunks.first?.section ?? "nil")
        check(TextDiff.hunks(old: "a\nb\n", new: "a\nc\n").first?.section == nil, "text without declarations has no section")
        hunks = TextDiff.hunks(old: "#comment\nx\n", new: "#comment\ny\n")
        check(hunks.first?.section == nil, "'#comment' without a space is not a heading", hunks.first?.section ?? "nil")

        // MARK: The request for the assistant's explanation and the reading of its answer
        let sample = TextDiff.hunks(old: old, new: edited.joined(separator: "\n"))
        let asked = ChangeExplainer.prompt(path: "Sources/Model.swift", kind: "modified", hunks: sample)
        check(asked.included == 1 && asked.text.contains("File: Sources/Model.swift") && asked.text.contains("=== Change 1: line 10 (was line 10) ==="),
              "the prompt names the file and numbers each change with its location", asked.text)
        check(asked.text.contains("10 old - line 10\n") && asked.text.contains("10 + line 10 CHANGED\n") && asked.text.contains("9   line 9\n"),
              "it shows the removed line with its old number, the added line and the context with new numbers", asked.text)
        let manyHunks = (0..<40).map { i in DiffHunk(id: i, lines: [DiffLine(id: 0, kind: .added, oldNumber: nil, newNumber: i + 1, text: String(repeating: "x", count: 4000))], section: nil) }
        let capped = ChangeExplainer.prompt(path: "big.txt", kind: "modified", hunks: manyHunks)
        check(capped.included > 1 && capped.included < 40 && capped.text.count < ChangeExplainer.characterBudget + 5000 && capped.text.contains("not shown"),
              "a very large diff is cut at the budget and says how many changes were left out", "included \(capped.included), \(capped.text.count) characters")
        let reading = ChangeExplainer.parse(["summary": " Renames it. ", "changes": [
            ["change": 1, "what": "Renames the field", "why": "Probably clarity", "impact": "Callers must follow"],
            ["change": 7, "what": "Out of range", "why": "", "impact": ""],
            ["change": 2, "what": "  ", "why": "", "impact": ""],
        ]], hunkCount: 2)
        check(reading?.summary == "Renames it." && reading?.hunks.count == 1 && reading?.hunks[0]?.impact == "Callers must follow",
              "the answer's changes are read by number (from 1) onto the hunks (from 0); an empty or out-of-range one is dropped", "\(String(describing: reading))")
        check(ChangeExplainer.parse(["summary": "x", "changes": []], hunkCount: 3) == nil && ChangeExplainer.parse([:], hunkCount: 1) == nil,
              "an answer that explains nothing is no explanation")
        check(ChangeExplainer.systemPrompt(language: "Russian").contains("Russian") && ChangeExplainer.systemPrompt(language: ActionOutputLanguage.documentLanguage).contains("language"),
              "the explanation is asked for in the chosen language")

    }
}
