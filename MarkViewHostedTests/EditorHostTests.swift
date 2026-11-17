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
