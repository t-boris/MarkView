import AppKit
import Combine
import Darwin
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


extension EditorHostTests {
    func testCockpitRunRecoveryAndStorage() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(value(), message, line: line)
        }
        let first = CockpitStep(title: "Prerequisite", agent: "Codex", assignment: "Check", completionCondition: "Available", isPrerequisite: true)
        let second = CockpitStep(title: "Work", agent: "Claude Code", assignment: "Implement", completionCondition: "Done")
        let plan = CockpitPlan(goal: "Work", controls: CockpitControls(), scenarios: [], steps: [first, second], successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        let approved = CockpitApproval(plan: plan, productionConfirmed: false)!
        var run = CockpitRun(plan: plan)
        check(!run.start(approval: approved, at: 9), "an invalid selected step is refused")
        check(run.start(approval: approved, at: 0), "the approved plan starts")
        check(run.completeCurrent(passed: false, detail: "Unavailable", build: "build-1") && run.status == .paused && run.currentIndex == 0, "a failed prerequisite pauses before the next step")
        check(run.retryPrerequisite() && run.status == .running, "the prerequisite can be retried")
        check(run.completeCurrent(passed: true, detail: "Available", build: "build-1") && run.currentIndex == 1, "passing advances to the next step")
        check(run.completeCurrent(passed: true, detail: "Done", build: "build-2") && run.status == .finished, "the final result finishes the run")
        check(run.results.count == 3 && run.results.first?.plan == plan && run.results.last?.build == "build-2", "results retain their plan and build")
        check(run.start(approval: approved, at: 1) && run.steps[0].status == .skipped, "a user can start at any selected step")
        run.pauseAtBoundary(reason: "Paused by user")
        check(run.status == .paused && run.resumeAtBoundary() && run.status == .running, "a user can pause and resume at a safe boundary")
        var changed = plan; changed.goal = "Different"
        var other = CockpitRun(plan: changed)
        check(!other.start(approval: approved, at: 0), "an approval cannot start a changed plan")
        let restored = try JSONDecoder().decode(CockpitRun.self, from: JSONEncoder().encode(run))
        check(restored == run, "run state and historical results round-trip")
        var recovered = restored
        recovered.prepareAfterRestart()
        check(recovered.status == .paused && recovered.steps[1].status == .interrupted && !recovered.resumeAtBoundary(),
              "recovery pauses an interrupted step without replaying it")
        var withEvidence = run
        let evidence = CockpitProgress(passNumber: 1, activity: "Partial work", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "File changed", blockers: [], buildLogPath: nil)
        check(withEvidence.recordProgress(evidence, stepID: second.id), "partial step evidence is recorded while running")
        withEvidence.prepareAfterRestart()
        var chooseOther = withEvidence
        check(chooseOther.continueAfterInterruption(plan: plan, approval: approved, at: 0) && chooseOther.currentIndex == 0,
              "the person may choose a different step instead of repeating the interrupted one")
        check(withEvidence.steps[1].progress == evidence && withEvidence.continueAfterInterruption(plan: plan, approval: approved, at: 1),
              "the person can explicitly choose to repeat an interrupted step after seeing its evidence")
        check(withEvidence.results.last?.interrupted == true && withEvidence.results.last?.progress == evidence,
              "the continued run retains the interrupted step's evidence without treating it as completed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try CockpitRunStore.save(run, root: root)
        let diskRun = try CockpitRunStore.load(run.id, root: root)
        check(diskRun.status == .paused && diskRun.steps[1].status == .interrupted && diskRun.results == run.results,
              "disk recovery preserves results and presents an interrupted run paused")
        let listed = try CockpitRunStore.loadAll(root: root)
        check(listed.count == 1 && listed[0].id == run.id && listed[0].status == .paused && listed[0].waitingReason.contains("background processes"),
              "listing saved runs warns about interruption and detached processes without resuming")
        // The file of a run is a schema-versioned store (AR-36). The legacy fixture is what the store wrote before the envelope: the run
        // encoded with a plain `JSONEncoder`.
        do {
            let storeRoot = StoreFixture.folder("cockpit-run-store")
            defer { try? FileManager.default.removeItem(at: storeRoot) }
            let file = storeRoot.appendingPathComponent(".dde/cockpit/runs/\(run.id.uuidString).json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacyBytes = try JSONEncoder().encode(run)
            try legacyBytes.write(to: file)
            let upgraded = try CockpitRunStore.load(run.id, root: storeRoot)
            check(upgraded.results == run.results && upgraded.plan == run.plan && upgraded.status == .paused, "legacy run file: it loads intact")
            check(StoreFixture.envelope(file) == nil, "legacy run file: loading leaves it as written")
            try CockpitRunStore.save(run, root: storeRoot)
            check(StoreFixture.envelope(file)?.schema == 1 && StoreFixture.backups(of: file).isEmpty, "legacy run file: the next save writes the envelope, with no backup")
            let reloadedRun = try CockpitRunStore.load(run.id, root: storeRoot)
            check(reloadedRun.results == run.results, "legacy run file: the envelope reloads with the same results")
            let permissions = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            check(permissions == 0o600, "a run file stays private to the user")

            let junk = Data("{ \"plan\": ".utf8)
            try junk.write(to: file)
            var failedToLoad = false
            do { _ = try CockpitRunStore.load(run.id, root: storeRoot) } catch { failedToLoad = true }
            let listedDamaged = try? CockpitRunStore.loadAll(root: storeRoot)
            check(failedToLoad && listedDamaged == nil, "damaged run file: it is an error, never an empty run")
            check(StoreFixture.bytes(file) == junk && StoreFixture.backups(of: file).isEmpty, "damaged run file: loading leaves it as it is")
            try CockpitRunStore.save(run, root: storeRoot)
            check(StoreFixture.backups(of: file).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: file)[0]) == junk,
                  "damaged run file: a save keeps the old bytes in a dated backup")

            let future = Data(StoreFixture.newerFile(payload: "{}").utf8)
            try future.write(to: file)
            var refused = false
            do { try CockpitRunStore.save(run, root: storeRoot) } catch SchemaStoreError.newerSchemaVersion { refused = true }
            check(refused && StoreFixture.bytes(file) == future, "newer run file: a save is refused and the file is untouched")
        }
        var revising = CockpitRun(plan: plan)
        check(revising.start(approval: approved, at: 0), "a revisable run starts")
        var revisedPlan = plan; revisedPlan.goal = "Revised goal"
        let revisedApproval = CockpitApproval(plan: revisedPlan, productionConfirmed: false)!
        check(revising.queueRevision(plan: revisedPlan, approval: revisedApproval, at: 1, fingerprint: "revision"), "a reviewed revision is persisted as pending")
        check(!revising.applyRevision(fingerprint: "wrong"), "an unexpected revision cannot be applied")
        check(revising.completeCurrent(passed: true, detail: "Old plan", build: "b1") && revising.applyRevision(fingerprint: "revision"), "the revision applies after the previous step")
        check(revising.plan == revisedPlan && revising.currentIndex == 1 && revising.results.first?.plan == plan,
              "earlier results retain their original plan after revision")

        // MARK: Timeline, times and silence

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        var timed = CockpitRun(plan: plan)
        check(timed.events == nil && timed.startedAt == nil && timed.lastSignal == nil, "a new run has no history yet")
        check(timed.start(approval: approved, at: 0, now: at(0)), "a timed run starts")
        check(timed.startedAt == at(0) && timed.steps[0].startedAt == at(0), "the run and its first step remember when they began")
        check(timed.events?.map(\.kind) == [.started, .stepStarted], "starting writes the start and the first step")
        check(timed.quietSeconds(now: at(5)) == 300, "silence counts from the step's start when nothing has been seen")
        check(!timed.isSilent(now: at(19)) && timed.isSilent(now: at(20)), "the warning is due at the threshold, not before")
        let report = CockpitProgress(passNumber: 1, activity: "Reading the code", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
        check(timed.recordProgress(report, stepID: first.id, now: at(10)), "progress is recorded")
        check(timed.lastSignal == at(10) && timed.quietSeconds(now: at(15)) == 300, "a report is a sign of life")
        check(timed.events?.last?.kind == .report && timed.events?.last?.text.contains("Reading the code") == true, "a new activity is a report event")
        let eventsBefore = timed.events?.count
        check(timed.recordProgress(report, stepID: first.id, now: at(11)) && timed.events?.count == eventsBefore, "the same report again adds no event")
        var withBug = report; withBug.bugs = ["BUG-1"]; withBug.fixes = ["BUG-0"]; withBug.blockers = ["Server down"]
        check(timed.recordProgress(withBug, stepID: first.id, now: at(12)), "a report with findings is recorded")
        let kinds = timed.events?.suffix(3).map(\.kind)
        check(kinds == [.bug, .fix, .report], "a new bug, a confirmed fix and a blocker each get an event")
        timed.noteSignal(at: at(30))
        check(timed.lastSignal == at(30), "a tool call is a sign of life")
        timed.noteSignal(at: at(25))
        check(timed.lastSignal == at(30), "an older sign of life does not move the clock back")
        timed.noteRefusal("markview_flow_new refused: outside this step", now: at(31))
        check(timed.events?.last?.kind == .refusal && timed.lastSignal == at(31), "a refusal is an event and a sign of life")
        check(timed.quietSeconds(now: at(32), activity: at(31.5)) == 30, "an unsaved tool call counts too")
        timed.addExchange(CockpitSupervisorExchange(stepID: first.id.uuidString, asked: at(33), question: "Which branch?", answer: "main", outOfScope: false, failed: false))
        check(timed.events?.last?.kind == .question && timed.events?.last?.text.contains("Which branch?") == true && timed.lastSignal == at(33), "a question the supervisor answered is an event and a sign of life")
        check(timed.completeCurrent(passed: true, detail: "Available\nsecond line", build: "b", now: at(40)), "the step passes")
        check(timed.steps[0].startedAt == at(0) && timed.steps[0].endedAt == at(40), "a step keeps when it began and ended")
        check(timed.events?.suffix(2).map(\.kind) == [.stepPassed, .stepStarted] && timed.events?.suffix(2).first?.text == "Available", "a passed step ends and the next one begins; the event keeps the first line only")
        check(timed.steps[1].startedAt == at(40) && timed.quietSeconds(now: at(45)) == 300, "silence restarts with each step")
        timed.pauseAtBoundary(reason: "Paused by user", now: at(50))
        check(timed.events?.last?.kind == .paused && timed.quietSeconds(now: at(90)) == nil, "a paused run is not silent")
        check(timed.resumeAtBoundary(now: at(60)) && timed.events?.last?.kind == .resumed, "resuming is an event")
        timed.stop(now: at(70))
        timed.stop(now: at(71))
        check(timed.events?.filter { $0.kind == .stopped }.count == 1, "stopping twice is one event")
        check(timed.events?.allSatisfy { $0.stepID == nil || [first.id.uuidString, second.id.uuidString].contains($0.stepID!) } == true, "events name steps by their plan id")
        let timedBack = try JSONDecoder().decode(CockpitRun.self, from: JSONEncoder().encode(timed))
        check(timedBack == timed, "a run with a timeline round-trips")

        // A failed step that pauses the run is not announced twice, and a retry is dated when it begins.
        var retrying = CockpitRun(plan: plan)
        check(retrying.start(approval: approved, at: 0, now: at(0)) && retrying.completeCurrent(passed: false, detail: "Unavailable", build: "b", now: at(5)), "a prerequisite fails")
        let eventsAtFailure = retrying.events?.count
        retrying.notePauseState(paused: true, reason: "Unavailable", now: at(5))
        check(retrying.events?.count == eventsAtFailure, "the coordinator's pause after a failed step adds no second event")
        retrying.notePauseState(paused: false, reason: "", now: at(9))
        check(retrying.events?.last?.kind == .resumed && retrying.steps[0].startedAt == at(9) && retrying.steps[0].endedAt == nil, "a retry begins when the person asks for it")
        check(retrying.retryPrerequisite() && retrying.status == .running, "the retry is applied when its result arrives")
        var userPause = CockpitRun(plan: plan)
        check(userPause.start(approval: approved, at: 0, now: at(0)), "a run to pause")
        userPause.notePauseState(paused: true, reason: "Paused by user", now: at(3))
        check(userPause.events?.last?.kind == .paused && userPause.events?.last?.text == "Paused by user", "a pause by the person is an event")

        // Old runs have none of it.
        let oldRun = CockpitRun(plan: plan)
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRun)) as! [String: Any]
        for key in ["startedAt", "lastSignal", "events"] { oldJSON.removeValue(forKey: key) }
        let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
        let oldDecoded = try JSONDecoder().decode(CockpitRun.self, from: oldData)
        check(oldDecoded.events == nil && oldDecoded.startedAt == nil && oldDecoded.began == nil && oldDecoded.lastKnownActivity == nil, "a run saved before the timeline existed decodes without it")
        var oldStepJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CockpitRun.StepRecord(stepID: first.id))) as! [String: Any]
        oldStepJSON.removeValue(forKey: "startedAt"); oldStepJSON.removeValue(forKey: "endedAt")
        check((try? JSONDecoder().decode(CockpitRun.StepRecord.self, from: JSONSerialization.data(withJSONObject: oldStepJSON))) != nil, "a step record without times decodes")

        // The timeline is bounded.
        var crowded: [CockpitRunEvent] = []
        for i in 0..<(CockpitRunEvent.capacity + 25) { crowded = CockpitRunEvent.appending(CockpitRunEvent(at: at(Double(i)), kind: .report, stepID: nil, text: "event \(i)"), to: crowded) }
        check(crowded.count == CockpitRunEvent.capacity && crowded.last?.text == "event \(CockpitRunEvent.capacity + 24)" && crowded.first?.text == "event 25", "the timeline keeps the latest events")
        let long = CockpitRunEvent.appending(CockpitRunEvent(at: t0, kind: .report, stepID: nil, text: String(repeating: "x", count: 5_000)), to: [])
        check(long.first?.text.count == CockpitRunEvent.textLimit, "an event text is cut to one line's worth")

        // A run read back after a restart keeps its history, and the interruption is dated when it was last alive.
        var interrupted = CockpitRun(plan: plan)
        check(interrupted.start(approval: approved, at: 0, now: at(0)) && interrupted.recordProgress(report, stepID: first.id, now: at(12)), "a run to interrupt")
        interrupted.prepareAfterRestart(now: interrupted.lastKnownActivity ?? at(99))
        check(interrupted.events?.last?.kind == .paused && interrupted.events?.last?.at == at(12) && interrupted.steps[0].endedAt == at(12), "an interruption is dated from the last sign of life")

        // MARK: Notifications

        var live = CockpitRun(plan: plan)
        check(live.start(approval: approved, at: 0, now: at(0)), "a run to watch")
        check(CockpitNotice.transition(from: live, to: live) == nil, "nothing changed, nothing to say")
        var pausedRun = live; pausedRun.pauseAtBoundary(reason: "Paused by user", now: at(1))
        check(CockpitNotice.transition(from: live, to: pausedRun)?.kind == .paused, "a pause is announced")
        check(CockpitNotice.transition(from: live, to: pausedRun, limitReached: true)?.kind == .limit, "a pause caused by a limit is announced as a limit")
        var failed = live; _ = failed.completeCurrent(passed: false, detail: "Unavailable\nmore", build: "b", now: at(2))
        check(CockpitNotice.transition(from: live, to: failed)?.kind == .stepFailed && CockpitNotice.transition(from: live, to: failed)?.body.contains("Unavailable") == true, "a failed step is announced with its reason")
        var done = live; _ = done.completeCurrent(passed: true, detail: "ok", build: "b", now: at(3)); _ = done.completeCurrent(passed: true, detail: "ok", build: "b", now: at(4))
        check(CockpitNotice.transition(from: live, to: done)?.kind == .finished, "a finished run is announced")
        check(CockpitNotice.transition(from: live, to: done)?.body == "Work", "an untitled run is named by its goal in a notice")
        var namedPlan = plan; namedPlan.title = "Weekly release checklist"
        var namedLive = CockpitRun(plan: namedPlan); _ = namedLive.start(approval: CockpitApproval(plan: namedPlan, productionConfirmed: false)!, at: 0, now: at(0))
        var namedDone = namedLive; _ = namedDone.completeCurrent(passed: true, detail: "ok", build: "b", now: at(3)); _ = namedDone.completeCurrent(passed: true, detail: "ok", build: "b", now: at(4))
        check(CockpitNotice.transition(from: namedLive, to: namedDone)?.body == "Weekly release checklist", "a titled run is named by its title in a notice")
        check(CockpitNotice.transition(from: done, to: done) == nil, "a finished run is announced once")
        var passing = live; _ = passing.completeCurrent(passed: true, detail: "ok", build: "b", now: at(3))
        check(CockpitNotice.transition(from: live, to: passing) == nil, "a step that passes does not interrupt the person")
        var stopped = live; stopped.stop(now: at(5))
        check(CockpitNotice.transition(from: live, to: stopped)?.kind == .stopped, "a stop is announced")
        check(CockpitNotice.transition(from: nil, to: live) == nil, "a run seen for the first time is not announced while it runs")
        check(CockpitNotice.transition(from: nil, to: pausedRun)?.kind == .paused, "a run first seen paused is announced")
        let quiet = CockpitNotice.silence(of: live, minutes: 25)
        check(quiet?.kind == .silent && quiet?.body.contains("25 min") == true, "silence is announced with its length")
        check(CockpitNotice.silence(of: pausedRun, minutes: 25) == nil, "a paused run is never called silent")
        check(quiet?.key == CockpitNotice.silence(of: live, minutes: 45)?.key, "one quiet stretch is one notice, however long it lasts")
        // MARK: levers and notes (DEC-028)

        var levered = CockpitRun(plan: plan)
        check(levered.start(approval: approved, at: 0, now: Date(timeIntervalSince1970: 1_000)), "a run to move levers on")
        var fixOff = CockpitLiveSwitches(); fixOff.fixBugsCut = true
        levered.setSwitches(fixOff, now: Date(timeIntervalSince1970: 1_100))
        check(levered.switches == fixOff && levered.events?.last?.kind == .switched && levered.events?.last?.text == "Fixing bugs was switched off by you.",
              "switching a lever off is kept and goes on the timeline")
        let eventCount = levered.events?.count ?? 0
        levered.setSwitches(fixOff, now: Date(timeIntervalSince1970: 1_200))
        check(levered.events?.count == eventCount, "the same lever state is not logged twice")
        levered.setSwitches(CockpitLiveSwitches(), now: Date(timeIntervalSince1970: 1_300))
        check(levered.switches == nil && levered.events?.last?.text == "Fixing bugs was switched back on.", "a lever put back is logged and leaves no cuts")
        levered.setSwitches(fixOff, now: Date(timeIntervalSince1970: 1_400))
        let note = CockpitCuratorNote(at: Date(timeIntervalSince1970: 1_500), text: "  Keep the runs short.  ")
        levered.addNote(note)
        levered.addNote(note)
        check(levered.notes?.count == 1 && levered.notes?.first?.text == "Keep the runs short." && levered.events?.last?.kind == .note, "a note is kept once, trimmed, and goes on the timeline")
        levered.addNote(CockpitCuratorNote(at: Date(), text: "   "))
        check(levered.notes?.count == 1, "an empty note is not kept")
        let leveredBack = try JSONDecoder().decode(CockpitRun.self, from: JSONEncoder().encode(levered))
        check(leveredBack == levered && leveredBack.switches == fixOff && leveredBack.notes == levered.notes, "levers and notes round-trip with the run")

        // A run saved before levers and notes existed has neither key.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(levered)) as! [String: Any]
        legacy.removeValue(forKey: "switches"); legacy.removeValue(forKey: "notes")
        let legacyRun = try JSONDecoder().decode(CockpitRun.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyRun.switches == nil && legacyRun.notes == nil && legacyRun.status == levered.status, "a run saved before levers and notes still loads")

        // Where a note has got to.
        var delivered = CockpitRun(plan: plan)
        _ = delivered.start(approval: approved, at: 0, now: Date(timeIntervalSince1970: 2_000))
        let early = CockpitCuratorNote(at: Date(timeIntervalSince1970: 2_100), text: "early")
        delivered.addNote(early)
        check(delivered.delivery(of: early).isQueued, "a note nobody has used yet is queued")
        delivered.addExchange(CockpitSupervisorExchange(stepID: first.id.uuidString, asked: Date(timeIntervalSince1970: 2_200), question: "q", answer: "a", outOfScope: false, failed: false))
        check(delivered.delivery(of: early) == CockpitRun.NoteDelivery(answersAfter: 1, briefedStep: nil), "a supervisor answer after the note means it was heard")
        _ = delivered.completeCurrent(passed: true, detail: "ok", build: "", now: Date(timeIntervalSince1970: 2_300))
        check(delivered.delivery(of: early).briefedStep == 2 && !delivered.delivery(of: early).isQueued, "the step that begins after the note carries it in its briefing")
        check(delivered.delivery(of: CockpitCuratorNote(at: Date(timeIntervalSince1970: 3_000), text: "late")).isQueued, "a note sent after everything is queued")


    }
}


extension EditorHostTests {
    func testWorkflowEventPlanning() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let standard = ProjectWorkflow.standard
        let inProgress = LifecycleRule(from: ["fixing"], to: "open", kind: .rollback, needs: [.human: [], .system: []], event: .workStarted)
        let onMerge = LifecycleRule(from: ["fixing", "open"], to: "fixed", kind: .spec, needs: [.system: []], event: .pullRequestMerged)
        let aiOnly = LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.ai: []], event: .workStarted)
        var table = standard.bug
        table.rules += [inProgress, onMerge, aiOnly]

        check("an event finds the rule that names it and starts at the status", RuleEventPlanner.step(for: .workStarted, in: table, status: "fixing")?.id == inProgress.id)
        check("the status is compared normalised", RuleEventPlanner.step(for: .workStarted, in: table, status: " Fixing ")?.id == inProgress.id)
        check("an item in another status gets no step", RuleEventPlanner.step(for: .workStarted, in: table, status: "closed") == nil)
        check("an event that no rule names changes nothing", RuleEventPlanner.step(for: .investigationFinished, in: table, status: "fixing") == nil)
        let reviewed = LifecycleRule(from: ["backlog"], to: "ready", kind: .spec, needs: [.system: []], event: .reviewPassed)
        let featureReview = IssueLifecycleDefinition(statuses: [WorkflowStatus(id: "backlog", role: .notStarted), WorkflowStatus(id: "ready", role: .notStarted)], rules: [reviewed])
        check("a passed review selects the configured ready transition", RuleEventPlanner.step(for: .reviewPassed, in: featureReview, status: "backlog")?.to == "ready")
        check("a rule that MarkView may not make is not an event step", RuleEventPlanner.step(for: .workStarted, in: table, status: "fixed") == nil)
        check("a rule with several from-statuses applies from each", RuleEventPlanner.step(for: .pullRequestMerged, in: table, status: "open")?.to == "fixed")
        check("the standard workflow has no event steps",
              RuleEvent.known.allSatisfy { event in standard.bug.statusIDs.allSatisfy { RuleEventPlanner.step(for: event, in: standard.bug, status: $0) == nil } })

        var firstWins = table
        firstWins.rules.insert(LifecycleRule(from: ["fixing"], to: "closed", kind: .spec, needs: [.system: []], event: .workStarted), at: 0)
        check("the first rule in the table wins when two match", RuleEventPlanner.step(for: .workStarted, in: firstWins, status: "fixing")?.to == "closed")

        let first = RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-1", cause: "abc")
        check("the command names the event, the item and the cause", first == "event:work-started:bug:BUG-1:abc")
        check("the same cause gives the same command", first == RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-1", cause: "abc"))
        check("another cause, item or event gives another command",
              first != RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-1", cause: "abd")
              && first != RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-2", cause: "abc")
              && first != RuleEventPlanner.command(.pullRequestMerged, kind: .bug, issue: "BUG-1", cause: "abc"))
        check("the reason names the event, the cause and the rule",
              RuleEventPlanner.reason(.workStarted, rule: inProgress, cause: "abc").contains("work is started")
              && RuleEventPlanner.reason(.workStarted, rule: inProgress, cause: "abc").contains("abc")
              && RuleEventPlanner.reason(.workStarted, rule: inProgress, cause: "abc").contains(inProgress.id))

        var watcher = MergedPullRequestWatcher()
        check("the first look at an item only records what is merged", watcher.newlyMerged(item: "BUG-1", merged: [4, 5]).isEmpty)
        check("nothing new, nothing reported", watcher.newlyMerged(item: "BUG-1", merged: [4, 5]).isEmpty)
        check("a pull request merged since the last look is reported once", watcher.newlyMerged(item: "BUG-1", merged: [4, 5, 7]) == [7])
        check("and not again", watcher.newlyMerged(item: "BUG-1", merged: [4, 5, 7]).isEmpty)
        check("several new ones come oldest number first", watcher.newlyMerged(item: "BUG-1", merged: [4, 5, 7, 9, 8]) == [8, 9])
        check("another item has its own first look", watcher.newlyMerged(item: "BUG-2", merged: [1]).isEmpty && watcher.newlyMerged(item: "BUG-2", merged: [1, 2]) == [2])
        check("a pull request that drops out of the list and returns is not reported twice", {
            var w = MergedPullRequestWatcher()
            _ = w.newlyMerged(item: "x", merged: [1]); _ = w.newlyMerged(item: "x", merged: [1, 2]); _ = w.newlyMerged(item: "x", merged: [1])
            return w.newlyMerged(item: "x", merged: [1, 2]).isEmpty
        }())

    }
}


extension EditorHostTests {
    func testWorkflowDescription() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let standard = ProjectWorkflow.standard
        let guide = WorkflowFormatGuide.text

        // MARK: The guide names every value the code accepts

        func guideNames(_ values: [String], _ what: String) {
            for value in values { check("the guide names the \(what) \(value)", guide.contains("\"\(value)\"")) }
        }
        guideNames(LifecycleRole.allCases.map(\.rawValue), "role")
        guideNames(TransitionKind.allCases.map(\.rawValue), "kind")
        guideNames(LifecycleCondition.allCases.map(\.rawValue), "condition")
        guideNames(RuleEvent.known.map(\.rawValue), "event")
        guideNames(StartEvidenceMode.allCases.map(\.rawValue), "start mode")
        guideNames(IntegrationPath.allCases.map(\.rawValue), "integration")
        guideNames(AcceptanceMode.allCases.map(\.rawValue), "acceptance mode")
        guideNames(DeliveryConfirmer.allCases.map(\.rawValue), "confirmer")
        guideNames(DeliveryEvent.typeNames, "delivery type")
        check("every delivery type in the list decodes",
              DeliveryEvent.typeNames.allSatisfy { (try? JSONDecoder().decode(DeliveryEvent.self, from: Data("{\"type\":\"\($0)\"}".utf8))) != nil })
        check("a delivery type that is not in the list does not decode", (try? JSONDecoder().decode(DeliveryEvent.self, from: Data(#"{"type":"teleport"}"#.utf8))) == nil)
        check("every kind has a meaning", TransitionKind.allCases.allSatisfy { !$0.meaning.isEmpty })

        for key in ["schema", "revision", "defaultFeatureVariant", "defaultBugVariant", "variants", "statuses", "rules", "confirmedBy", "markview_get_workflow",
                    "markview_propose_workflow", "markview_confirm_delivery", "Workflow tab", "press Save"] {
            check("the guide mentions \(key)", guide.contains(key))
        }
        check("the guide says that the assistant cannot save", guide.contains("you cannot save it") && guide.contains("Do not say that it is saved"))
        check("the guide says what the model cannot express", guide.contains("WHAT THE MODEL CANNOT EXPRESS") && guide.contains("do not invent a field"))
        check("the guide has examples", guide.contains("EXAMPLES") && guide.contains("investigation-finished") && guide.contains("work-started"))

        // The examples in the guide are real rules: build the ones it describes and validate them.
        var withExamples = standard
        withExamples.bug.rules.append(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .ai: [], .system: []], event: .investigationFinished))
        check("the investigation example is a valid rule", withExamples.validate().isEmpty)
        withExamples.variants[1].delivery = .humanConfirmed(name: "Installed on mac")
        withExamples.variants[1].confirmer = .personOrAI
        check("the confirmation example is a valid process", withExamples.validate().isEmpty)

        // MARK: A workflow in words

        let described = WorkflowDescription.describe(standard)
        check("the description names the workflow, its revision and the schema", described.contains("\u{201C}\(standard.name)\u{201D}") && described.contains("revision \(standard.revision)") && described.contains("schema 1"))
        check("the description lists every status of both types", (standard.feature.statusIDs + standard.bug.statusIDs).allSatisfy { described.contains($0) })
        check("the description lists the processes and their defaults", standard.variants.allSatisfy { described.contains($0.id) } && described.contains("default for bugs"))
        check("a step says who may make it", WorkflowDescription.sentence(standard.bug.rules[0]).contains("a person:") && WorkflowDescription.sentence(standard.bug.rules[0]).contains("an AI:") && WorkflowDescription.sentence(standard.bug.rules[0]).contains("MarkView:"))
        let eventRule = LifecycleRule(from: ["fixing"], to: "open", kind: .rollback, needs: [.human: [], .system: []], event: .workStarted)
        check("a step with an event says that MarkView takes it itself", WorkflowDescription.sentence(eventRule).contains("MarkView takes this step itself when work is started"))
        check("an actor without an entry is not allowed by the rules", WorkflowDescription.sentence(eventRule).contains("an AI: not by the rules"))
        check("conditions are named in words", WorkflowDescription.sentence(standard.bug.rules.first { $0.kind == .completion }!).contains("delivery evidence"))

        // MARK: Two workflows in words

        check("a workflow has no difference from itself", WorkflowDescription.differences(from: standard, to: standard).isEmpty)
        var revised = standard
        revised.revision += 1
        check("the revision alone is not a difference", WorkflowDescription.differences(from: standard, to: revised).isEmpty)
        var changed = standard
        changed.name = "Kanban"
        check("a rename is told", WorkflowDescription.differences(from: standard, to: changed).contains { $0.contains("renamed") && $0.contains("Kanban") })
        let newRule = LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .system: []], event: .workStarted)
        changed.bug.rules.append(newRule)
        let ruleAdded = WorkflowDescription.differences(from: standard, to: changed)
        check("a new step is told with its event", ruleAdded.contains { $0.contains("Bug step added") && $0.contains("when work is started") })
        var ruleChanged = changed
        ruleChanged.bug.rules[ruleChanged.bug.rules.count - 1].event = .investigationFinished
        check("a changed step is told", WorkflowDescription.differences(from: changed, to: ruleChanged).contains { $0.contains("Bug step fixed>fixing changes") && $0.contains("an investigation finishes") })
        var ruleRemoved = changed
        ruleRemoved.bug.rules.removeLast()
        check("a removed step is told", WorkflowDescription.differences(from: changed, to: ruleRemoved).contains { $0.contains("Bug step removed: fixed>fixing") })

        var statuses = standard
        statuses.bug.statuses.append(WorkflowStatus(id: "in-review", title: "In review", role: .active))
        check("a new status is told with its role", WorkflowDescription.differences(from: standard, to: statuses).contains { $0.contains("Bug status added: in-review") && $0.contains("active") })
        check("a removed status says that items need a replacement",
              WorkflowDescription.differences(from: statuses, to: standard).contains { $0.contains("Bug status removed: in-review") && $0.contains("replacement") })
        var retitled = standard
        retitled.bug.statuses[0].title = "Reported"
        retitled.bug.statuses[1] = WorkflowStatus(id: standard.bug.statuses[1].id, title: standard.bug.statuses[1].title, role: .completed)
        let statusChanges = WorkflowDescription.differences(from: standard, to: retitled)
        check("a renamed status and a changed role are told", statusChanges.contains { $0.contains("renamed") && $0.contains("Reported") } && statusChanges.contains { $0.contains("changes its role") })

        var processes = standard
        processes.variants[1].delivery = .humanConfirmed(name: "Installed on mac")
        processes.variants[1].confirmer = .personOrAI
        processes.variants[1].checks = false
        let processChanges = WorkflowDescription.differences(from: standard, to: processes)
        check("a delivery event change is told", processChanges.contains { $0.contains("the delivery event changes") && $0.contains("Installed on mac") })
        check("who confirms is told", processChanges.contains { $0.contains("confirmed by \u{201C}A person, or an AI with evidence\u{201D}") })
        check("a checks change is told", processChanges.contains { $0.contains("checks become not required") })
        var extra = standard
        extra.variants.append(RuleVariant(id: "quick-fix", name: "Quick fix", kind: .bug, integration: .directToMain, checks: false))
        check("a new process is told", WorkflowDescription.differences(from: standard, to: extra).contains { $0.contains("Process added: quick-fix") })
        check("a removed process says that items need a replacement", WorkflowDescription.differences(from: extra, to: standard).contains { $0.contains("Process removed: quick-fix") && $0.contains("replacement") })
        var own = extra
        own.variants[own.variants.count - 1].rules = standard.bug.rules
        check("a process that gets its own steps is told", WorkflowDescription.differences(from: extra, to: own).contains { $0.contains("gets its own") })
        var defaults = extra
        defaults.defaultBugVariant = "quick-fix"
        check("a new default process is told", WorkflowDescription.differences(from: extra, to: defaults).contains { $0.contains("default bug process changes") && $0.contains("quick-fix") })

    }
}


extension EditorHostTests {
    func testWorkflowProposal() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let current: ProjectWorkflow = { var w = ProjectWorkflow.standard; w.revision = 4; return w }()
        let encoder = JSONEncoder()
        func object(_ workflow: ProjectWorkflow) -> [String: Any] {
            try! JSONSerialization.jsonObject(with: try! encoder.encode(workflow)) as! [String: Any]
        }
        func text(_ workflow: ProjectWorkflow) -> String { String(decoding: try! encoder.encode(workflow), as: UTF8.self) }
        func refusal(_ result: Result<WorkflowProposal, WorkflowProposalChecker.Refusal>) -> [String] {
            if case .failure(let refusal) = result { return refusal.problems } else { return [] }
        }
        func proposal(_ result: Result<WorkflowProposal, WorkflowProposalChecker.Refusal>) -> WorkflowProposal? {
            if case .success(let proposal) = result { return proposal } else { return nil }
        }
        func evaluate(_ value: Any?, summary: String = "Let an AI move a bug back", at: ProjectWorkflow? = nil) -> Result<WorkflowProposal, WorkflowProposalChecker.Refusal> {
            WorkflowProposalChecker.evaluate(workflow: value, summary: summary, current: at ?? current, by: "Claude Code", now: Date(timeIntervalSince1970: 1_800_000_000))
        }

        var changed = current
        changed.bug.rules.append(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .ai: [], .system: []], event: .investigationFinished))

        // MARK: A sound proposal

        let accepted = proposal(evaluate(object(changed)))
        check("a sound proposal as a JSON object is accepted", accepted != nil)
        check("it is the workflow that was sent", accepted?.workflow == changed)
        check("it names who proposed it, when and why", accepted?.proposedBy == "Claude Code" && accepted?.summary == "Let an AI move a bug back" && accepted?.at == Date(timeIntervalSince1970: 1_800_000_000))
        check("it carries the differences in words", accepted?.differences.contains { $0.contains("Bug step added") && $0.contains("an investigation finishes") } == true)
        check("the same workflow as JSON text is accepted too", proposal(evaluate(text(changed))) != nil)
        check("a proposal on the current revision is not outdated", accepted?.isOutdated(against: current) == false)
        var moved = current
        moved.revision = 5
        check("a proposal is outdated once the file has moved on", accepted?.isOutdated(against: moved) == true)
        check("the summary is trimmed", proposal(evaluate(object(changed), summary: "  Because  "))?.summary == "Because")

        // MARK: A proposal that is refused, with every problem

        check("a missing summary is refused", refusal(evaluate(object(changed), summary: "  ")).contains { $0.contains("`summary` is required") })
        check("something that is not a workflow is refused", refusal(evaluate(nil)).contains { $0.contains("whole workflow as a JSON object") }
              && refusal(evaluate(42)).contains { $0.contains("whole workflow as a JSON object") })
        check("text that is not JSON is refused", refusal(evaluate("not json")).contains { $0.contains("not a workflow in the file format") })
        check("an object of the wrong shape is refused", refusal(evaluate(["name": "x"])).contains { $0.contains("not a workflow in the file format") })
        var newer = changed
        newer.schema = 99
        check("a schema from a newer app is refused", refusal(evaluate(object(newer))).contains { $0.contains("schema 99") })
        var stale = changed
        stale.revision = 3
        check("a proposal on an older revision is refused and says to read again",
              refusal(evaluate(object(stale))).contains { $0.contains("revision 3") && $0.contains("revision 4") && $0.contains("markview_get_workflow") })
        var ahead = changed
        ahead.revision = 9
        check("a proposal on a newer revision is refused too", refusal(evaluate(object(ahead))).contains { $0.contains("revision 9") })
        check("a workflow that breaks a rule is refused with the rule's message", {
            var broken = changed
            broken.name = " "
            return refusal(evaluate(object(broken))).contains { $0.contains("needs a name") }
        }())
        check("an event this app does not know is refused", {
            var future = current
            future.bug.rules.append(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.system: []], event: RuleEvent(rawValue: "teleported")))
            return refusal(evaluate(object(future))).contains { $0.contains("teleported") && $0.contains("does not know") }
        }())
        check("a proposal that changes nothing is refused", refusal(evaluate(object(current))).contains { $0.contains("changes nothing") })
        check("all the problems come back at once", {
            var broken = changed
            broken.name = " "
            broken.revision = 3
            return refusal(evaluate(object(broken), summary: "")).count >= 3
        }())
        check("a refusal makes no proposal", proposal(evaluate(object(stale))) == nil)

        // MARK: What the assistant is told

        let told = WorkflowProposalChecker.reply(accepted!, needsReplacement: [])
        check("the reply says what changes", told.contains("What it changes:") && told.contains("Bug step added"))
        check("the reply tells the person where to save and that the assistant cannot",
              told.contains("Workflow tab") && told.contains("Review in the draft") && told.contains("press Save") && told.contains("You cannot save it"))
        check("the reply lists no replacements when there are none", !told.contains("need a replacement"))
        var impact = WorkflowImpact()
        impact.statuses[.bug] = ["open": ["BUG-1", "BUG-2"]]
        impact.variants["quick"] = ["f1"]
        let lines = WorkflowProposalChecker.replacementLines(impact)
        check("replacements are listed by status and process", lines.count == 2 && lines[0].contains("2 bug item(s) in the status open") && lines[1].contains("process quick"))
        check("the reply lists the replacements", WorkflowProposalChecker.reply(accepted!, needsReplacement: lines).contains("need a replacement when it is saved"))
        check("a long list of items is cut", WorkflowProposalChecker.replacementLines({ var i = WorkflowImpact(); i.statuses[.bug] = ["open": (1...9).map { "BUG-\($0)" }]; return i }())[0].contains("…"))

    }
}


extension EditorHostTests {
    func testIssueLifecyclePolicy() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let person = LifecycleActor.human("Boris")
        let agent = LifecycleActor.ai("claude-code", session: "s1")
        let app = LifecycleActor.system("MarkView")

        let handedOff = StartEvidence.handoff(tool: "Claude Code", at: Date())
        let delivered = DeliveryVerdict.complete(summary: ["PR #1 merged", "checks passed"])
        let notDelivered = DeliveryVerdict.incomplete(missing: ["PR #2 is not merged"])

        func req(_ kind: IssueKind = .feature, from: String, to: String, actor: LifecycleActor, reason: String? = nil, force: Bool = false,
                 start: StartEvidence? = nil, delivery: DeliveryVerdict = .notCollected, acceptance: AcceptanceEvidence? = nil,
                 regression: RegressionEvidence? = nil, cancellation: CancellationEvidence? = nil) -> TransitionRequest {
            TransitionRequest(kind: kind, issue: kind == .feature ? "f" : "BUG-001", from: from, to: to, actor: actor, reason: reason, force: force,
                              evidence: LifecycleEvidence(start: start, delivery: delivery, acceptance: acceptance, regression: regression,
                                                          cancellation: cancellation))
        }
        func decision(_ r: TransitionRequest) -> TransitionDecision { LifecyclePolicy.decide(r) }
        func isAllowed(_ d: TransitionDecision) -> Bool { if case .allowed = d { return true } else { return false } }
        func isRejected(_ d: TransitionDecision) -> Bool { if case .rejected = d { return true } else { return false } }
        func rejection(_ d: TransitionDecision) -> Rejection? { if case .rejected(let r) = d { return r } else { return nil } }
        func bypassed(_ d: TransitionDecision) -> [LifecycleCondition]? { if case .overridden(_, let b) = d { return b } else { return nil } }
        func basisKind(_ d: TransitionDecision) -> TransitionKind? {
            switch d {
            case .allowed(let b), .overridden(let b, _): return b.kind
            default: return nil
            }
        }

        // MARK: Vocabulary stays separate (REQ-002 criterion 3)

        check("feature statuses are the existing vocabulary", LifecycleVocabulary.statuses(.feature) == FeatureVocabulary.featureStatuses)
        check("bug statuses are the existing vocabulary", LifecycleVocabulary.statuses(.bug) == ["open", "fixing", "fixed", "closed"])
        check("a bug status is not a feature status", isRejected(decision(req(.bug, from: "open", to: "implementing", actor: person))))
        check("unknown target status is refused even when forced",
              isRejected(decision(req(from: "ready", to: "done", actor: person, reason: "x", force: true))))
        check("same status is no change", decision(req(from: "ready", to: "ready", actor: agent)) == .noChange)
        check("status text is normalised", isAllowed(decision(req(from: " Ready ", to: "IMPLEMENTING", actor: app, start: handedOff))))

        // MARK: Starting needs start evidence (REQ-002 criterion 1)

        check("system starts on a recorded handoff", isAllowed(decision(req(from: "ready", to: "implementing", actor: app, start: handedOff))))
        check("handoff start is a start", basisKind(decision(req(from: "ready", to: "implementing", actor: app, start: handedOff))) == .start)
        check("no start evidence, no implementing", rejection(decision(req(from: "ready", to: "implementing", actor: app)))?.missing == [.startEvidence])
        check("a session attached counts as start evidence",
              isAllowed(decision(req(from: "ready", to: "implementing", actor: agent, start: .attached(session: "s1", at: Date())))))
        check("an AI without start evidence cannot start work", isRejected(decision(req(from: "ready", to: "implementing", actor: agent))))
        check("a person starting by hand without evidence is refused", isRejected(decision(req(from: "ready", to: "implementing", actor: person))))
        check("bug: handoff starts fixing", isAllowed(decision(req(.bug, from: "open", to: "fixing", actor: app, start: handedOff))))
        check("bug: no evidence, no fixing", rejection(decision(req(.bug, from: "open", to: "fixing", actor: agent)))?.missing == [.startEvidence])
        check("a failed handoff rolls the bug back to open for anyone", isAllowed(decision(req(.bug, from: "fixing", to: "open", actor: app))))
        check("an idea cannot jump to implementing", isRejected(decision(req(from: "idea", to: "implementing", actor: app, start: handedOff))))

        // MARK: Completion needs delivery evidence (REQ-002 criterion 2, DEC-007)

        check("implementing → implemented on complete delivery",
              isAllowed(decision(req(from: "implementing", to: "implemented", actor: app, delivery: delivered))))
        check("completion is a completion", basisKind(decision(req(from: "implementing", to: "implemented", actor: app, delivery: delivered))) == .completion)
        check("incomplete delivery does not complete",
              rejection(decision(req(from: "implementing", to: "implemented", actor: app, delivery: notDelivered)))?.missing == [.deliveryEvidence])
        check("unknown delivery does not complete",
              isRejected(decision(req(from: "implementing", to: "implemented", actor: app, delivery: .unknown(reasons: ["GitHub unreachable"])))))
        check("an uncollected verdict does not complete", isRejected(decision(req(from: "implementing", to: "implemented", actor: app))))
        check("an AI is held to the same delivery rule",
              isRejected(decision(req(from: "implementing", to: "implemented", actor: agent, delivery: notDelivered))))
        check("an AI completes when MarkView's evidence says complete",
              isAllowed(decision(req(from: "implementing", to: "implemented", actor: agent, delivery: delivered))))
        check("work done outside a handoff may complete from ready", isAllowed(decision(req(from: "ready", to: "implemented", actor: app, delivery: delivered))))
        check("the rejection explains itself", (rejection(decision(req(from: "implementing", to: "implemented", actor: agent, delivery: notDelivered)))?.hints.joined().contains("PR #2 is not merged")) == true)
        check("bug: fixing → fixed on delivery", isAllowed(decision(req(.bug, from: "fixing", to: "fixed", actor: app, delivery: delivered))))
        check("bug: open → fixed on delivery of work done elsewhere", isAllowed(decision(req(.bug, from: "open", to: "fixed", actor: app, delivery: delivered))))
        check("bug: fixed without delivery is refused", isRejected(decision(req(.bug, from: "fixing", to: "fixed", actor: agent, delivery: notDelivered))))
        check("a feature cannot go from implementing to verified", isRejected(decision(req(from: "implementing", to: "verified", actor: person))))

        // MARK: The override is the person's and needs a reason (Q-002, REQ-002 criterion 4)

        let forced = decision(req(from: "implementing", to: "implemented", actor: person, reason: "Shipped by hand, CI is down", force: true,
                                  delivery: notDelivered))
        check("a person can force a completion with a reason", bypassed(forced) == [.deliveryEvidence])
        check("a forced transition is not silently allowed", !isAllowed(forced))
        check("force without a reason is refused",
              rejection(decision(req(from: "implementing", to: "implemented", actor: person, reason: "  ", force: true)))?.missing == [.reason])
        check("force with no reason at all is refused", isRejected(decision(req(from: "implementing", to: "implemented", actor: person, force: true))))
        check("an AI can never force", isRejected(decision(req(from: "implementing", to: "implemented", actor: agent, reason: "I said so", force: true))))
        check("the system can never force", isRejected(decision(req(from: "implementing", to: "implemented", actor: app, reason: "auto", force: true))))
        check("force that the rules allow anyway is not an override",
              isAllowed(decision(req(from: "implementing", to: "implemented", actor: person, reason: "ok", force: true, delivery: delivered))))
        check("a person can force a jump outside the table",
              bypassed(decision(req(from: "idea", to: "verified", actor: person, reason: "Imported", force: true))) == [.listedTransition])
        check("a forced jump is of the unlisted kind", basisKind(decision(req(from: "idea", to: "verified", actor: person, reason: "r", force: true))) == .unlisted)
        check("a forced start bypasses the start evidence",
              bypassed(decision(req(from: "ready", to: "implementing", actor: person, reason: "I began by hand", force: true))) == [.startEvidence])
        check("forced acceptance is a person's bypass of nothing when the person accepts",
              isAllowed(decision(req(from: "implemented", to: "verified", actor: person, reason: "checked", force: true))))
        check("a refused request says how to continue", (rejection(decision(req(from: "ready", to: "implementing", actor: person)))?.hints.isEmpty) == false)

        // MARK: Acceptance (DEC-008)

        check("a person accepts an implemented feature", isAllowed(decision(req(from: "implemented", to: "verified", actor: person))))
        check("acceptance is an acceptance", basisKind(decision(req(from: "implemented", to: "verified", actor: person))) == .acceptance)
        check("an AI accepts with evidence and every criterion ticked",
              isAllowed(decision(req(from: "implemented", to: "verified", actor: agent,
                                     acceptance: AcceptanceEvidence(text: "Ran the suites: 12 passed", criteriaAllTicked: true)))))
        check("an AI without ticked criteria cannot accept",
              rejection(decision(req(from: "implemented", to: "verified", actor: agent,
                                     acceptance: AcceptanceEvidence(text: "Looks fine", criteriaAllTicked: false))))?.missing == [.acceptanceEvidence])
        check("an AI with empty evidence text cannot accept",
              isRejected(decision(req(from: "implemented", to: "verified", actor: agent, acceptance: AcceptanceEvidence(text: "  ", criteriaAllTicked: true)))))
        check("an AI with no evidence cannot accept", isRejected(decision(req(from: "implemented", to: "verified", actor: agent))))
        check("the system never accepts", isRejected(decision(req(from: "implemented", to: "verified", actor: app))))
        check("bug: a person closes a fixed bug", isAllowed(decision(req(.bug, from: "fixed", to: "closed", actor: person))))
        check("bug: an AI closes a fixed bug with evidence text only",
              isAllowed(decision(req(.bug, from: "fixed", to: "closed", actor: agent, acceptance: AcceptanceEvidence(text: "Reproduced no more", criteriaAllTicked: false)))))
        check("bug: an AI cannot close a fixed bug without evidence", isRejected(decision(req(.bug, from: "fixed", to: "closed", actor: agent))))

        // MARK: Regression reopens the original (Q-003, DEC-009)

        check("a person reopens a verified feature with a reason", isAllowed(decision(req(from: "verified", to: "implementing", actor: person, reason: "Crash in 5.36"))))
        check("reopening is a reopen", basisKind(decision(req(from: "verified", to: "implementing", actor: person, reason: "r"))) == .reopen)
        check("a person must give a reason to reopen", rejection(decision(req(from: "implemented", to: "implementing", actor: person)))?.missing == [.reason])
        check("an AI reopens only on a regression bug",
              isAllowed(decision(req(from: "implemented", to: "implementing", actor: agent, regression: .bug(id: "BUG-050")))))
        check("an AI without the regression bug cannot reopen", rejection(decision(req(from: "implemented", to: "implementing", actor: agent)))?.missing == [.regressionEvidence])
        check("the system reopens on a regression bug", isAllowed(decision(req(from: "verified", to: "implementing", actor: app, regression: .bug(id: "BUG-050")))))
        check("a failing check alone is no regression evidence", isRejected(decision(req(from: "implemented", to: "implementing", actor: app, delivery: notDelivered))))
        check("bug: fixed reopens to open on a regression", isAllowed(decision(req(.bug, from: "fixed", to: "open", actor: agent, regression: .bug(id: "BUG-051")))))
        check("bug: closed reopens to open for a person with a reason", isAllowed(decision(req(.bug, from: "closed", to: "open", actor: person, reason: "Back again"))))
        check("bug: an AI cannot reopen a closed bug without evidence", isRejected(decision(req(.bug, from: "closed", to: "open", actor: agent))))
        check("a person can take an acceptance back", isAllowed(decision(req(from: "verified", to: "implemented", actor: person, reason: "Acceptance was premature"))))

        // MARK: Cancellation is not completion (DEC-013)

        check("archiving a feature is open to a person and an AI",
              isAllowed(decision(req(from: "draft", to: "archived", actor: person))) && isAllowed(decision(req(from: "draft", to: "archived", actor: agent))))
        check("archived before completion is a cancellation", basisKind(decision(req(from: "draft", to: "archived", actor: person))) == .cancellation)
        check("archived after completion keeps the completion", basisKind(decision(req(from: "verified", to: "archived", actor: person))) == .archive)
        check("the system does not archive", isRejected(decision(req(from: "draft", to: "archived", actor: app))))
        check("a person unarchives with a reason", isAllowed(decision(req(from: "archived", to: "draft", actor: person, reason: "Back on the roadmap"))))
        check("bug: a duplicate closes with its original named",
              isAllowed(decision(req(.bug, from: "open", to: "closed", actor: agent, cancellation: .duplicate(of: "BUG-002")))))
        check("bug: a close without a fix is a cancellation",
              basisKind(decision(req(.bug, from: "open", to: "closed", actor: agent, cancellation: .duplicate(of: "BUG-002")))) == .cancellation)
        check("bug: already fixed on main closes the bug but is a cancellation, not a completion",
              isAllowed(decision(req(.bug, from: "open", to: "closed", actor: app, cancellation: .alreadyFixed("fixed by 1a2b3c4"))))
              && basisKind(decision(req(.bug, from: "open", to: "closed", actor: app, cancellation: .alreadyFixed("fixed by 1a2b3c4")))) == .cancellation)
        check("bug: an AI cannot close an open bug without evidence", isRejected(decision(req(.bug, from: "open", to: "closed", actor: agent))))
        check("bug: a person closes without a fix only with a reason", isRejected(decision(req(.bug, from: "open", to: "closed", actor: person))))
        check("bug: a person closes without a fix with a reason", isAllowed(decision(req(.bug, from: "open", to: "closed", actor: person, reason: "Works as designed"))))

        // MARK: Spec stages keep their freedom (existing flows)

        check("spec stages move freely for the system", isAllowed(decision(req(from: "review", to: "resolving", actor: app))))
        check("an AI sets the stages the tools always allowed it", isAllowed(decision(req(from: "exploring", to: "draft", actor: agent))))
        check("an AI does not set resolving", isRejected(decision(req(from: "review", to: "resolving", actor: agent))))
        check("a spec move is a spec step", basisKind(decision(req(from: "draft", to: "review", actor: person))) == .spec)
        check("restart goes back to idea", isAllowed(decision(req(from: "ready", to: "idea", actor: app))))
        check("a failed handoff rolls the feature back", isAllowed(decision(req(from: "implementing", to: "ready", actor: app))))
        check("a person rolls implementing back with a reason", isAllowed(decision(req(from: "implementing", to: "ready", actor: person, reason: "Paused"))))

        // MARK: Unknown state (REQ-005)

        check("a hand-written status outside the vocabulary is unknown state for an AI",
              isRejected(decision(req(from: "in-progress", to: "implemented", actor: agent, delivery: delivered))))
        check("and for the system", isRejected(decision(req(from: "done", to: "verified", actor: app))))
        check("a person moves it with a reason", bypassed(decision(req(from: "done", to: "implemented", actor: person, reason: "Normalise", force: true))) == [.listedTransition])
        check("an empty status is unknown too", isRejected(decision(req(from: "", to: "implementing", actor: app, start: handedOff))))

        // MARK: Rejections change nothing and explain (REQ-001 criterion 3)

        let refused = rejection(decision(req(from: "ready", to: "implemented", actor: agent)))
        check("a rejection names what is missing", refused?.missing == [.deliveryEvidence])
        check("a rejection has a message", refused?.message.isEmpty == false)

        // MARK: Next steps for the AI context (REQ-003 criterion 2)

        let steps = LifecyclePolicy.nextSteps(kind: .feature, status: "implementing", actor: .ai, evidence: LifecycleEvidence(delivery: notDelivered))
        check("implementing offers completion and rollback", Set(steps.map(\.to)) == ["implemented", "ready", "archived"])
        check("the completion step lists what is missing", steps.first { $0.to == "implemented" }?.unmet == [.deliveryEvidence])
        check("a step the actor may not make has no needs", steps.first { $0.to == "ready" }?.needs == nil)
        let bugSteps = LifecyclePolicy.nextSteps(kind: .bug, status: "fixing", actor: .ai, evidence: LifecycleEvidence(delivery: delivered))
        check("a bug in fixing can be fixed when delivered", bugSteps.first { $0.to == "fixed" }?.unmet == [])

    }
}


extension EditorHostTests {
    func testIssueDeliveryEvidence() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func minutes(_ n: Double) -> Date { t0.addingTimeInterval(n * 60) }
        let sources = [EvidenceSource.available("git"), .available("GitHub checks"), .available("GitHub releases")]

        func unit(_ ref: WorkRef, merged: Date? = Date(timeIntervalSince1970: 1_800_000_600), head: String = "aaa1111", paths: [String]? = ["MarkView/Models/Lifecycle/IssueLifecycle.swift", "docs/features/x/overview.md"], checks: CheckState? = nil,
                  association: WorkAssociation = .explicit, closedUnmerged: Bool = false) -> WorkUnit {
            WorkUnit(ref: ref, headSHA: head, mergedAt: merged, closedUnmerged: closedUnmerged, changedPaths: paths,
                     checks: checks ?? .passed(sha: head), association: association)
        }
        func verdict(_ work: [WorkUnit], release: Bool = false, releases: [WorkRef: ReleaseState] = [:], since: Date? = nil,
                     sources: [EvidenceSource] = [.available("git"), .available("GitHub checks"), .available("GitHub releases")]) -> DeliveryVerdict {
            DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: work, releaseRequired: release, releases: releases, since: since))
        }
        func isComplete(_ v: DeliveryVerdict) -> Bool { v.isComplete }
        func isIncomplete(_ v: DeliveryVerdict) -> Bool { if case .incomplete = v { return true } else { return false } }
        func isUnknown(_ v: DeliveryVerdict) -> Bool { if case .unknown = v { return true } else { return false } }

        let pr1 = WorkRef.pullRequest(1), pr2 = WorkRef.pullRequest(2), c1 = WorkRef.commit("1234567890abcdef")

        // MARK: Completion needs merged work with passing checks (DEC-007)

        check("a merged unit with passing checks completes", isComplete(verdict([unit(pr1)])))
        check("the summary names the unit", verdict([unit(pr1)]).lines.first?.contains("PR #1") == true)
        check("a direct commit on main counts", isComplete(verdict([unit(c1, head: "1234567890abcdef")])))
        check("no work at all is not completion", isIncomplete(verdict([])))
        check("an unmerged pull request is not completion", isIncomplete(verdict([unit(pr1, merged: nil)])))
        check("a pull request closed without merging counts for nothing", isIncomplete(verdict([unit(pr1, merged: nil, closedUnmerged: true)])))
        check("a closed-unmerged unit does not block a merged one", isComplete(verdict([unit(pr1), unit(pr2, merged: nil, closedUnmerged: true)])))
        check("every associated unit must be merged", isIncomplete(verdict([unit(pr1), unit(pr2, merged: nil)])))
        check("the unmerged unit is named", verdict([unit(pr1), unit(pr2, merged: nil)]).lines.contains { $0.contains("PR #2") && $0.contains("not merged") })
        check("a failed check blocks", isIncomplete(verdict([unit(pr1, checks: .failed(sha: "aaa1111"))])))
        check("a running check blocks", isIncomplete(verdict([unit(pr1, checks: .pending(sha: "aaa1111"))])))
        check("a commit without any workflow run is unknown, not a pass", isUnknown(verdict([unit(pr1, checks: .noRuns(sha: "aaa1111"))])))
        check("unreadable checks are unknown", isUnknown(verdict([unit(pr1, checks: .unknown("rate limited"))])))

        // MARK: Stale evidence (REQ-005 criterion 1, plan I-4 "changed commit heads")

        check("checks of an older commit do not count for a moved head",
              isIncomplete(verdict([unit(pr1, head: "bbb2222", checks: .passed(sha: "aaa1111"))])))
        check("the stale head is named", verdict([unit(pr1, head: "bbb2222", checks: .passed(sha: "aaa1111"))]).lines.contains { $0.contains("older commit") })

        // MARK: Documentation-only work is not implementation work (DEC-012)

        check("a docs-only commit is not implementation work", isIncomplete(verdict([unit(c1, paths: ["docs/features/x/overview.md", "tasks/todo.md"])])))
        check("a docs-only commit does not block real work", isComplete(verdict([unit(pr1), unit(c1, merged: minutes(11), paths: ["README.md"], checks: .noRuns(sha: "aaa1111"))])))
        check("docs paths", DocumentationPaths.isDocumentation("docs/a.md") && DocumentationPaths.isDocumentation("tasks/x") && DocumentationPaths.isDocumentation("CLAUDE.md"))
        check("code paths", !DocumentationPaths.isDocumentation("MarkView/Models/A.swift") && !DocumentationPaths.isDocumentation("project.yml") && !DocumentationPaths.isDocumentation(".github/workflows/x.yml"))
        check("a unit with an unreadable file list is unknown", isUnknown(verdict([unit(pr1, paths: nil)])))
        check("an empty file list is not documentation-only", !unit(pr1, paths: []).isDocumentationOnly)

        // MARK: A required release (DEC-007, DEC-012)

        check("with a release required and delivered it completes",
              isComplete(verdict([unit(pr1)], release: true, releases: [pr1: .delivered(tag: "v5.36.0")])))
        check("the release is in the summary", verdict([unit(pr1)], release: true, releases: [pr1: .delivered(tag: "v5.36.0")]).lines.first?.contains("v5.36.0") == true)
        check("merged and green but unreleased stays unfinished", isIncomplete(verdict([unit(pr1)], release: true, releases: [pr1: .pending])))
        check("the missing release is named", verdict([unit(pr1)], release: true, releases: [pr1: .pending]).lines.contains { $0.contains("release") })
        check("a release that could not be determined is unknown", isUnknown(verdict([unit(pr1)], release: true, releases: [pr1: .unknown("compare failed")])))
        check("a release never collected is unknown", isUnknown(verdict([unit(pr1)], release: true)))
        check("no release is asked for when not required", isComplete(verdict([unit(pr1)], release: false, releases: [pr1: .pending])))
        check("every unit needs its release",
              isIncomplete(verdict([unit(pr1), unit(c1, head: "ccc3333")], release: true, releases: [pr1: .delivered(tag: "v1"), c1: .pending])))

        // MARK: Unavailable and ambiguous sources are never a pass (REQ-005 criterion 1)

        check("an unavailable source makes it unknown", isUnknown(verdict([unit(pr1)], sources: [.available("git"), .unavailable("GitHub", "not signed in")])))
        check("the reason is kept", verdict([unit(pr1)], sources: [.unavailable("GitHub", "not signed in")]).lines.first?.contains("not signed in") == true)
        check("a definite gap is reported as incomplete even when a source is down",
              isIncomplete(verdict([unit(pr1, merged: nil)], sources: [.unavailable("GitHub", "offline")])))
        check("an ambiguously associated unit never completes",
              !isComplete(verdict([unit(pr1, association: .ambiguous("#294 is linked by two features"))])))
        check("an ambiguous unit is reported as unknown", isUnknown(verdict([unit(pr1, association: .ambiguous("shared #294"))])) || isIncomplete(verdict([unit(pr1, association: .ambiguous("shared #294"))])))
        check("an ambiguous unit does not count as merged work even when the rest is fine",
              !isComplete(verdict([unit(pr1, association: .ambiguous("shared"))])))
        check("an ambiguous unit beside a clear one still blocks", !isComplete(verdict([unit(pr1), unit(pr2, association: .ambiguous("shared"))])))

        // MARK: A reopened issue needs new work (Q-003, DEC-009)

        check("work merged before the reopening does not complete it again", isIncomplete(verdict([unit(pr1, merged: minutes(10))], since: minutes(20))))
        check("work merged after the reopening does", isComplete(verdict([unit(pr1, merged: minutes(10)), unit(pr2, merged: minutes(30), head: "ddd4444")], since: minutes(20))))
        check("no start time asks for nothing more", isComplete(verdict([unit(pr1)], since: nil)))

        // MARK: Association (DEC-012)

        check("feature folder names the feature", WorkAssociationRules.mentionsFeature("feat: x\n\ndocs/features/issue-lifecycle-management/overview.md", slug: "issue-lifecycle-management", issues: []))
        check("a longer slug is not the feature", !WorkAssociationRules.mentionsFeature("docs/features/issue-lifecycle-management-2/x", slug: "issue-lifecycle-management", issues: []))
        check("a Feature trailer names the feature", WorkAssociationRules.mentionsFeature("feat: research map\n\nBody.\n\nFeature: issue-lifecycle-management\n", slug: "issue-lifecycle-management", issues: []))
        check("a trailer is case-insensitive and tolerates spaces", WorkAssociationRules.mentionsFeature("x\n  feature:   s  \ny", slug: "S", issues: []))
        check("a trailer of a longer slug is not the feature", !WorkAssociationRules.mentionsFeature("x\nFeature: s-2\n", slug: "s", issues: []))
        check("a trailer in the middle of a line is not a trailer", !WorkAssociationRules.mentionsFeature("see Feature: s for details", slug: "s", issues: []))
        check("an issue number of the feature names it", WorkAssociationRules.mentionsFeature("Fixes #294", slug: "s", issues: [294]))
        check("another number does not", !WorkAssociationRules.mentionsFeature("Fixes #2940", slug: "s", issues: [294]))
        check("a bug key names the bug", WorkAssociationRules.mentionsBug("fix: BUG-065 styles", key: "BUG-065", issues: []))
        check("a longer bug key is another bug", !WorkAssociationRules.mentionsBug("fix: BUG-0651", key: "BUG-065", issues: []))
        check("a bug key matches without case", WorkAssociationRules.mentionsBug("bug-065", key: "BUG-065", issues: []))
        check("a quoted feature slug in a PR description names the feature", WorkAssociationRules.mentionsFeature("Complete UI Studio (`ui-studio`) REQ-001", slug: "ui-studio", issues: []))
        check("a longer quoted feature slug does not name another feature", !WorkAssociationRules.mentionsFeature("`ui-studio-other`", slug: "ui-studio", issues: []))
        let prDescription = "Complete `ui-studio`.\nBUG-012 through BUG-016 were previously addressed in 4b8a783; this PR does not claim new fixes for them."
        let deliveryDescription = WorkAssociationRules.deliveryDescription(prDescription)
        check("historical bug references do not attribute this PR to those bugs", !WorkAssociationRules.mentionsBug(deliveryDescription, key: "BUG-012", issues: []))
        check("excluding a historical reference preserves the PR's feature link", WorkAssociationRules.mentionsFeature(deliveryDescription, slug: "ui-studio", issues: []))
        check("abbreviated batch names every bug", ["BUG-012", "BUG-013", "BUG-014"].allSatisfy { WorkAssociationRules.mentionsBug("fix: BUG-012/013/014", key: $0, issues: []) })
        check("abbreviated batch does not match a partial number", !WorkAssociationRules.mentionsBug("fix: BUG-012/0131", key: "BUG-013", issues: []))
        check("an anchor is not an issue number", !WorkAssociationRules.mentionsIssueNumber("see a#12 and &#12;", in: [12]))
        let split = WorkAssociationRules.exclusiveNumbers([1, 2], claimedByOthers: [2, 3])
        check("a number another issue also links is shared", split.exclusive == [1] && split.shared == [2])

        // Explicit project requirements, including an operator's documented override of old checklist defaults.
        let policyData = Data(#"{"items":[{"id":"pr","mode":"require"},{"id":"ci","mode":"require"}]}"#.utf8)
        let requiredPolicy = ProjectDeliveryPolicy.read(definition: policyData, guide: nil)
        check("project policy requires the configured PR and CI", requiredPolicy.pullRequestRequired && requiredPolicy.checksRequired)
        check("missing policy uses the standard PR and CI requirements", ProjectDeliveryPolicy.read(definition: nil, guide: nil).pullRequestRequired && ProjectDeliveryPolicy.read(definition: nil, guide: nil).checksRequired)
        let askPolicy = Data(#"{"items":[{"id":"pr","mode":"ask"}]}"#.utf8)
        check("ask before PR does not silently skip the PR", ProjectDeliveryPolicy.read(definition: askPolicy, guide: nil).pullRequestRequired)
        let directGuide = "## Commits go straight to main (operator)\nUntil further notice, commit directly to `main` and push it.\n\n## CI is switched off (operator)\nUntil further notice, do not wait for CI."
        let directPolicy = ProjectDeliveryPolicy.read(definition: policyData, guide: directGuide)
        check("explicit operator rules override outdated PR and CI settings", !directPolicy.pullRequestRequired && !directPolicy.checksRequired)
        let skipPR = Data(#"{"items":[{"id":"pr","mode":"skip"}]}"#.utf8)
        let requiredGuide = "## Git Workflow\n- Never commit to main directly for anything else.\n- Open a pull request into main."
        check("an explicit project rule requiring PR overrides a skipped checklist item", ProjectDeliveryPolicy.read(definition: skipPR, guide: requiredGuide).pullRequestRequired)
        check("an AGENTS.md rule requiring a PR is respected", ProjectDeliveryPolicy.read(definition: skipPR, guide: "The most important rule: every feature and bug fix goes through a pull request.").pullRequestRequired)
        let unconfirmedPR = WorkUnit(ref: .pullRequest(41), headSHA: "sha", mergedAt: minutes(10), changedPaths: ["app.swift"],
                                     checks: .passed(sha: "sha"), pullRequestVerified: false)
        let unresolvedPR = DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: [unconfirmedPR], releaseRequired: false, pullRequestRequired: true))
        check("a required PR must be confirmed by GitHub", !unresolvedPR.isComplete)
        let negativeGuide = "Never commit directly to main. CI may be switched off in other projects."
        let stillRequired = ProjectDeliveryPolicy.read(definition: policyData, guide: negativeGuide)
        check("a casual or negative mention does not override requirements", stillRequired.pullRequestRequired && stillRequired.checksRequired)

        // MARK: Reading git and GitHub output

        let log = "\u{1e}aaa111\u{1f}2026-11-05T10:00:00+00:00\u{1f}feat: x\n\ndocs/features/x\n\u{1f}\nMarkView/A.swift\ndocs/x.md\n\u{1e}bbb222\u{1f}2026-11-05T11:00:00+00:00\u{1f}docs: y\n\u{1f}\nREADME.md\n"
        let commits = GitWorkLog.commits(from: log)
        check("git log records are split", commits.count == 2 && commits[0].sha == "aaa111" && commits[1].sha == "bbb222")
        check("files and message are kept apart", commits[0].paths == ["MarkView/A.swift", "docs/x.md"] && commits[0].message.contains("docs/features/x"))
        check("a commit without code files is docs", commits[1].paths.allSatisfy(DocumentationPaths.isDocumentation))
        check("git arguments ask for names and the separators", GitWorkLog.arguments(ref: "origin/main").contains("--name-only"))

        let allGreen = Data(#"[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]"#.utf8)
        check("all runs green passes", RunsVerdict.state(runsJSON: allGreen, sha: "s") == .passed(sha: "s"))
        check("a failed run fails", RunsVerdict.state(runsJSON: Data(#"[{"status":"completed","conclusion":"failure"}]"#.utf8), sha: "s") == .failed(sha: "s"))
        check("a running run is pending", RunsVerdict.state(runsJSON: Data(#"[{"status":"in_progress","conclusion":""},{"status":"completed","conclusion":"success"}]"#.utf8), sha: "s") == .pending(sha: "s"))
        check("no runs is noRuns, not a pass", RunsVerdict.state(runsJSON: Data("[]".utf8), sha: "s") == .noRuns(sha: "s"))
        check("garbage is unknown", { if case .unknown = RunsVerdict.state(runsJSON: Data("nope".utf8), sha: "s") { return true } else { return false } }())
        check("a failed run beats a running one", RunsVerdict.state(runsJSON: Data(#"[{"status":"in_progress"},{"status":"completed","conclusion":"failure"}]"#.utf8), sha: "s") == .failed(sha: "s"))
        check("rollup SUCCESS passes", RunsVerdict.state(rollup: "SUCCESS", sha: "s") == .passed(sha: "s"))
        check("rollup PENDING is pending", RunsVerdict.state(rollup: "PENDING", sha: "s") == .pending(sha: "s"))
        check("rollup absent is noRuns", RunsVerdict.state(rollup: nil, sha: "s") == .noRuns(sha: "s"))

        // MARK: The project's release rule comes from its definition of done

        let dod = { (mode: String) in Data(#"{"items":[{"id":"branch","mode":"skip"},{"id":"deploy","mode":"\#(mode)"}]}"#.utf8) }
        check("deploy required", ReleaseRequirement.isRequired(definitionOfDoneJSON: dod("require")))
        check("deploy skipped", !ReleaseRequirement.isRequired(definitionOfDoneJSON: dod("skip")))
        check("deploy ask-me is not a requirement", !ReleaseRequirement.isRequired(definitionOfDoneJSON: dod("ask")))
        check("no file, no requirement", !ReleaseRequirement.isRequired(definitionOfDoneJSON: nil))
        check("damaged file, no requirement", !ReleaseRequirement.isRequired(definitionOfDoneJSON: Data("{".utf8)))

        // MARK: A unit whose files could not be read is no definite gap (BUG-106)

        let unreadable = unit(c1, head: "1234567890abcdef", paths: nil)
        func strict(_ work: [WorkUnit]) -> DeliveryVerdict {
            DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: work, releaseRequired: false, pullRequestRequired: true))
        }
        let beside = strict([unit(pr1), unreadable])
        check("a unit with unreadable files leaves the verdict unknown, not complete", isUnknown(beside))
        check("a unit with unreadable files is not reported as missing a pull request",
              !beside.lines.contains { $0.contains("requires a merged pull request") } && beside.lines.contains { $0.contains("changed files of") })
        check("a unit with unreadable files does not hide a definite gap elsewhere",
              isIncomplete(strict([unit(pr1, checks: .failed(sha: "aaa1111")), unreadable])))

    }
}


extension EditorHostTests {
    func testIssueLifecycleDisplay() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
        func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }

        let person = LifecycleActor.human("Boris")
        let agent = LifecycleActor.ai("Claude Code", session: "s1")
        let robot = LifecycleActor.system("MarkView")

        func record(_ phase: TransitionRecord.Phase, _ from: String, _ to: String, _ actor: LifecycleActor, minute: Int,
                    kind: IssueKind = .feature, issue: String = "export-pdf", command: String = "", reason: String? = nil,
                    transition: TransitionKind? = nil, override: Bool = false, bypassed: [LifecycleCondition] = [],
                    missing: [LifecycleCondition] = [], evidence: [String] = [], message: String? = nil, verified: Bool? = nil,
                    target: String? = nil, outcome: GitHubWriteOutcome? = nil, id: UUID = UUID()) -> TransitionRecord {
            TransitionRecord(id: id, phase: phase, command: command.isEmpty ? UUID().uuidString : command, kind: kind, issue: issue, from: from, to: to,
                             actor: actor, at: at(minute), reason: reason, transitionKind: transition, override: override, bypassed: bypassed,
                             missing: missing, evidence: evidence, message: message, verified: verified, target: target, githubOutcome: outcome)
        }

        func display(_ records: [TransitionRecord], status: String, kind: IssueKind = .feature, issue: String = "export-pdf",
                     completion: String = "not complete", notes: [String] = []) -> IssueLifecycleDisplay {
            IssueLifecycleDisplay.make(kind: kind, issue: issue, status: status, history: IssueHistory(kind: kind, issue: issue, all: records),
                                       completion: completion, discrepancies: notes)
        }

        // MARK: Applied transitions (REQ-004 criterion 1)

        do {
            let applied = record(.applied, "implementing", "implemented", robot, minute: 30, reason: "All work merged.", transition: .completion,
                                 evidence: ["PR #12 merged", "checks passed on 4f3a9c1"])
            let d = display([record(.baseline, "", "implementing", robot, minute: 0), applied], status: "implemented", completion: "verified completion")
            let row = d.history.first
            check("an applied transition names the previous and the resulting status", row?.headline == "implementing → implemented")
            check("an applied transition names the actor", row?.actor == "MarkView")
            check("an applied transition carries its time", row?.time == at(30))
            check("an applied transition shows the reason", row?.notes.contains("Reason: All work merged.") == true)
            check("an applied transition lists each piece of evidence",
                  row?.notes.contains("Evidence: PR #12 merged") == true && row?.notes.contains("Evidence: checks passed on 4f3a9c1") == true)
            check("an applied transition names the kind of step", row?.notes.contains("Step: completion") == true)
            check("history reads newest first", d.history.map(\.headline) == ["implementing → implemented", "first seen: implementing"])
            check("the first sight is a baseline row", d.history.last?.notes.first == "First seen by MarkView; the history starts here.")
            check("the completion label is kept", d.completion == "verified completion" && d.status == "implemented")
            check("an AI actor reads with its tool and session",
                  display([record(.applied, "ready", "implementing", agent, minute: 1, transition: .start)], status: "implementing").history.first?.actor == "AI Claude Code (s1)")
            check("a person actor reads with the name",
                  display([record(.applied, "draft", "review", person, minute: 1, transition: .spec)], status: "review").history.first?.actor == "person Boris")
        }

        // MARK: Overrides (REQ-004 criterion 2)

        do {
            let forced = record(.applied, "implementing", "implemented", person, minute: 40, reason: "Shipped by hand, CI is down.", transition: .completion,
                                override: true, bypassed: [.deliveryEvidence, .reason])
            let d = display([forced], status: "implemented", completion: "completed by an override, not verified")
            let row = d.history.first
            check("an override is marked", row?.tone == .override)
            check("an override shows its reason", row?.notes.contains("Reason: Shipped by hand, CI is down.") == true)
            check("an override names the conditions it bypassed",
                  row?.notes.first == "Override by a person, bypassed: delivery evidence; a reason.")
            check("an override without bypassed conditions is still marked",
                  display([record(.applied, "draft", "ready", person, minute: 1, reason: "x", override: true)], status: "ready").history.first?.notes.first == "Override by a person.")
            check("a normal step is not marked as an override",
                  display([record(.applied, "draft", "review", person, minute: 1, transition: .spec)], status: "review").history.first?.tone == .normal)
        }

        // MARK: Blocked requests and missing evidence (REQ-004 criterion 3)

        do {
            let blocked = record(.rejected, "implementing", "implemented", agent, minute: 50, missing: [.deliveryEvidence],
                                 message: "implemented needs delivery evidence: PR #12 is not merged.")
            let d = display([record(.applied, "ready", "implementing", agent, minute: 10, transition: .start), blocked], status: "implementing")
            check("a blocked request is listed apart from the history", d.blocked.count == 1 && d.history.count == 1)
            check("a blocked request says nothing changed", d.blocked.first?.headline == "asked implementing → implemented, nothing changed")
            check("a blocked request explains why", d.blocked.first?.notes.first == "implemented needs delivery evidence: PR #12 is not merged.")
            check("a blocked request names the missing evidence", d.blocked.first?.notes.contains("Missing: delivery evidence") == true)
            check("a blocked request is tagged blocked", d.blocked.first?.tone == .blocked)
            check("blocked requests are capped and newest first",
                  display((0..<9).map { record(.rejected, "open", "fixed", agent, minute: $0, kind: .bug, issue: "BUG-1", command: "c\($0)") }, status: "open", kind: .bug, issue: "BUG-1").blocked.map(\.time)
                    == [8, 7, 6, 5, 4].map(at))
        }

        // MARK: Discrepancies and uncertain state (REQ-005)

        do {
            let outside = record(.external, "implementing", "implemented", LifecycleActor.system("Markdown edit"), minute: 60, verified: false)
            let d = display([record(.applied, "ready", "implementing", agent, minute: 10, transition: .start), outside], status: "implemented",
                            completion: "status edited outside MarkView, not verified")
            check("an outside edit is a discrepancy until confirmed",
                  d.discrepancies.contains { $0.contains("changed outside MarkView") && $0.contains("implementing → implemented") && $0.contains("unverified") })
            check("an outside edit is shown in the history as unverified",
                  d.history.first?.tone == .external && d.history.first?.notes.first == "Changed outside MarkView. Unverified until delivery evidence confirms it.")

            let confirmed = record(.confirmed, "implemented", "implemented", robot, minute: 70, evidence: ["PR #12 merged"], message: "Evidence confirms the status.")
            let after = display([outside, confirmed], status: "implemented", completion: "verified completion")
            check("a confirmation closes the discrepancy", after.discrepancies.isEmpty)
            check("a confirmation is shown as evidence-backed", after.history.first?.tone == .success && after.history.first?.notes.contains("Confirmed by evidence.") == true)

            let pending = record(.begin, "implementing", "implemented", robot, minute: 80)
            check("an operation that never closed is a discrepancy",
                  display([pending], status: "implementing").discrepancies.contains { $0.contains("began") && $0.contains("not closed") })
            check("caller discrepancies are kept", display([], status: "implemented", notes: ["GitHub #294 is closed, but export-pdf is not verified complete."]).discrepancies
                  == ["GitHub #294 is closed, but export-pdf is not verified complete."])
            check("a clean history has no discrepancies", display([record(.applied, "draft", "review", person, minute: 1, transition: .spec)], status: "review").discrepancies.isEmpty)
            check("a begin record alone is not a history row", display([pending], status: "implementing").history.isEmpty)
        }

        // MARK: GitHub outcomes (REQ-004 criterion 4)

        do {
            let rows = display([
                record(.github, "implemented", "implemented", robot, minute: 90, command: "g1", message: "closed and confirmed", target: "#294", outcome: .confirmed),
                record(.github, "implemented", "implemented", robot, minute: 91, command: "g2", message: "GitHub refused", target: "#295", outcome: .failed),
                record(.github, "implemented", "implemented", robot, minute: 92, command: "g3", message: "no answer", target: "#296", outcome: .unconfirmed),
            ], status: "implemented").github
            check("GitHub outcomes are listed newest first", rows.map(\.time) == [92, 91, 90].map(at))
            check("a confirmed write reads as confirmed", rows.last?.headline == "GitHub #294: confirmed" && rows.last?.tone == .success)
            check("a failed write reads as failed", rows[1].headline == "GitHub #295: failed" && rows[1].tone == .failure)
            check("an unconfirmed write is neither success nor failure", rows.first?.headline == "GitHub #296: not confirmed (the outcome is unknown)" && rows.first?.tone == .unconfirmed)
            check("a GitHub row keeps the message", rows[1].notes == ["GitHub refused"])
            check("GitHub records are not part of the status history",
                  display([record(.github, "implemented", "implemented", robot, minute: 90, target: "#294", outcome: .confirmed)], status: "implemented").history.isEmpty)
        }

        // MARK: Actions the section offers

        do {
            check("an implemented feature can be accepted", IssueLifecycleDisplay.acceptStatus(kind: .feature, status: "implemented") == "verified")
            check("a fixed bug can be accepted", IssueLifecycleDisplay.acceptStatus(kind: .bug, status: "fixed") == "closed")
            check("nothing else is accepted", ["idea", "exploring", "draft", "review", "resolving", "ready", "implementing", "verified", "archived"]
                    .allSatisfy { IssueLifecycleDisplay.acceptStatus(kind: .feature, status: $0) == nil }
                  && ["open", "fixing", "closed"].allSatisfy { IssueLifecycleDisplay.acceptStatus(kind: .bug, status: $0) == nil })
            check("a completed feature reopens into implementing",
                  IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "implemented") == "implementing" && IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "verified") == "implementing")
            check("a completed bug reopens into open",
                  IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "fixed") == "open" && IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "closed") == "open")
            check("unfinished work is not reopened", IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "implementing") == nil && IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "open") == nil)
            check("only completed statuses are checked against the evidence",
                  display([], status: "implemented").canCheckEvidence && display([], status: "fixed", kind: .bug, issue: "BUG-1").canCheckEvidence
                    && !display([], status: "implementing").canCheckEvidence && !display([], status: "open", kind: .bug, issue: "BUG-1").canCheckEvidence)
            check("the display carries the actions with the status", display([], status: "Implemented").acceptTarget == "verified" && display([], status: "Implemented").status == "implemented")
        }

        // MARK: Bounds

        do {
            let many = (0..<45).map { record(.applied, "draft", "review", person, minute: $0, command: "c\($0)", transition: .spec) }
            let d = display(many, status: "review")
            check("the history shows the latest rows only", d.history.count == IssueLifecycleDisplay.historyLimit && d.history.first?.time == at(44))
            check("row ids are unique", Set(d.history.map(\.id)).count == d.history.count)
        }

        // MARK: Variant, note start and delivery event (feature-3)

        do {
            var workflow = ProjectWorkflow.standard
            workflow.variants.append(VariantTemplate.manualWork.variant(kind: .feature, id: "by-hand"))
            var confirmed = VariantTemplate.directToMain.variant(kind: .feature, id: "installed")
            confirmed.delivery = .humanConfirmed(name: "installed")
            workflow.variants.append(confirmed)
            func make(_ status: String, variant: String?, _ records: [TransitionRecord] = []) -> IssueLifecycleDisplay {
                IssueLifecycleDisplay.make(kind: .feature, issue: "export-pdf", status: status, history: IssueHistory(kind: .feature, issue: "export-pdf", all: records),
                                           completion: "not complete", workflow: workflow, variantID: variant)
            }
            let standard = make("ready", variant: nil)
            check("the standard variant is shown by default", standard.variantID == StandardWorkflow.featureVariantID && standard.variantName == "Standard feature")
            check("the standard variant offers no start by note", !standard.canStartWithNote)
            check("a variant that accepts a note offers one before the start", make("ready", variant: "by-hand").canStartWithNote)
            check("but not once the work is under way", !make("implementing", variant: "by-hand").canStartWithNote)
            check("a person-only variant still offers accepting an implemented item", make("implemented", variant: "by-hand").acceptTarget == "verified")
            let installed = make("implementing", variant: "installed")
            check("a variant with a delivery event a person confirms offers the confirmation", installed.eventToConfirm == "installed" && !installed.eventConfirmed)
            let confirmation = record(.evidence, "", "", person, minute: 5, target: "installed")
            var recorded = confirmation
            recorded.humanEvidence = .delivery
            check("a recorded confirmation is shown as confirmed", make("implementing", variant: "installed", [recorded]).eventConfirmed)
            check("a variant without a delivery event offers no confirmation", make("implementing", variant: nil).eventToConfirm == nil)
            check("reopening goes to the active status by role", IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "verified", workflow: workflow) == "implementing"
                  && IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "closed", workflow: workflow) == "open")
            check("only a completed status can be reopened", IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "ready", workflow: workflow) == nil
                  && IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "archived", workflow: workflow) == nil)

            // A process with transitions of its own (BUG-108): accepting, reopening and starting by a note follow the item's process.
            var withProcess = ProjectWorkflow.standard
            var own = ProcessTemplate.quickFeature.variant(kind: .feature, id: "quick-feature", in: withProcess)
            own.rules = own.rules!.filter { $0.kind != .acceptance }
            withProcess.variants.append(own)
            check("a process without an acceptance step offers none, while the standard feature does",
                  IssueLifecycleDisplay.acceptStatus(kind: .feature, status: "implemented", workflow: withProcess, variantID: "quick-feature") == nil
                  && IssueLifecycleDisplay.acceptStatus(kind: .feature, status: "implemented", workflow: withProcess, variantID: StandardWorkflow.featureVariantID) == "verified"
                  && IssueLifecycleDisplay.acceptStatus(kind: .feature, status: "implemented", workflow: withProcess) == "verified")
            check("a process reopens a completed item through its own transitions",
                  IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "implemented", workflow: withProcess, variantID: "quick-feature") == "implementing")
            let noted = IssueLifecycleDisplay.make(kind: .feature, issue: "small", status: "ready", history: IssueHistory(kind: .feature, issue: "small", all: []),
                                                   completion: "", workflow: withProcess, variantID: "quick-feature")
            check("the display of an item shows the process it follows and its note start", noted.variantID == "quick-feature" && noted.variantName == "Quick feature"
                  && noted.canStartWithNote)
        }

    }
}


extension EditorHostTests {
    func testCockpitInstruments() {
        func check(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(value(), message, line: line)
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

        func makePlan(steps count: Int, controls: CockpitControls = CockpitControls()) -> CockpitPlan {
            let steps = (1...count).map { CockpitStep(title: "Step \($0)", agent: "Claude Code", assignment: "Do \($0)", completionCondition: "Done \($0)") }
            return CockpitPlan(goal: "Check the panel", controls: controls, scenarios: [], steps: steps, successCriteria: ["Done"],
                               unavailableOutcomes: [], alternatives: [], productionQA: nil)
        }

        func started(_ plan: CockpitPlan, at index: Int = 0, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CockpitRun {
            var run = CockpitRun(plan: plan)
            XCTAssertTrue(run.start(approval: CockpitApproval(plan: plan, productionConfirmed: false)!, at: index, now: now))
            return run
        }

        // --- Altitude and distance
        var plan = makePlan(steps: 4)
        var run = started(plan)
        var readings = CockpitReadings(run: run, live: true, now: at(1))
        check(readings.altitude.done == 0 && readings.altitude.total == 4 && readings.altitude.fraction == 0, "a new run is on the ground")
        check(readings.distance.stepsLeft == 4 && readings.distance.estimatedSeconds == nil, "no estimate before a step has passed")

        check(run.completeCurrent(passed: true, detail: "ok", build: "", now: at(10)), "step 1 passes after 10 minutes")
        readings = CockpitReadings(run: run, live: true, now: at(10))
        check(readings.altitude.done == 1 && readings.altitude.fraction == 0.25, "one of four steps is a quarter of the altitude")
        check(readings.distance.stepsLeft == 3 && readings.distance.estimatedSeconds == 3 * 600, "the estimate is the mean of the passed steps times the steps left")
        readings = CockpitReadings(run: run, live: true, now: at(14))
        check(readings.distance.estimatedSeconds == 3 * 600 - 240, "the running step has already used part of its share")
        readings = CockpitReadings(run: run, live: true, now: at(100))
        check(readings.distance.estimatedSeconds == 2 * 600, "a step that runs longer than the mean never makes the estimate negative")
        readings = CockpitReadings(run: run, live: false, now: at(14))
        check(readings.distance.estimatedSeconds == 3 * 600, "a saved run is not read against the clock")

        var skipped = started(plan, at: 2)
        readings = CockpitReadings(run: skipped, live: true, now: at(1))
        check(readings.altitude.done == 2 && readings.distance.stepsLeft == 2, "steps before the starting step count as done")
        check(readings.distance.estimatedSeconds == nil, "skipped steps give no duration to estimate from")
        for _ in 0..<2 { _ = skipped.completeCurrent(passed: true, detail: "ok", build: "", now: at(2)) }
        readings = CockpitReadings(run: skipped, live: false, now: at(3))
        check(readings.distance.stepsLeft == 0 && readings.distance.estimatedSeconds == nil, "nothing is left at the destination")

        // --- Fuel and turns
        var limited = CockpitControls()
        limited.timeLimitMinutes = 100
        limited.fixCycleLimit = 4
        run = started(makePlan(steps: 2, controls: limited))
        readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 60 * 60, usedFixCycles: 1)
        check(readings.fuel.band == .ok && readings.fuel.fraction == 0.6 && readings.turns.band == .ok && readings.turns.fraction == 0.25, "below 70% is ok")
        readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 75 * 60, usedFixCycles: 3)
        check(readings.fuel.band == .caution && readings.turns.band == .caution, "from 70% of the limit is caution")
        readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 100 * 60, usedFixCycles: 4)
        check(readings.fuel.band == .limit && readings.turns.band == .limit && readings.lamps.limitReached, "at the limit the lamp is lit")
        readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 500 * 60)
        check(readings.fuel.fraction == 1, "the needle stops at full")
        run = started(makePlan(steps: 2))
        readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 9_999, usedFixCycles: 99)
        check(readings.fuel.limit == nil && readings.fuel.fraction == nil && readings.fuel.band == .ok && readings.turns.band == .ok && !readings.lamps.limitReached,
              "a quantity without a limit never warns")
        readings = CockpitReadings(run: run, live: true, now: at(1))
        check(readings.fuel.used == 0 && readings.turns.used == 0, "nothing used yet reads as zero")

        // --- Wind
        run = started(makePlan(steps: 3))
        readings = CockpitReadings(run: run, live: true, now: at(1))
        check(readings.wind.score == 0 && readings.wind.band == .calm && !readings.lamps.stepFailed, "a calm start")
        run.noteRefusal("markview_create_bug refused: filing is off", now: at(2))
        run.noteRefusal("markview_set_bug_status refused", now: at(3))
        readings = CockpitReadings(run: run, live: true, now: at(4))
        check(readings.wind.refusals == 2 && readings.wind.band == .breeze, "two refusals are a breeze")
        readings = CockpitReadings(run: run, live: true, now: at(65), activity: at(64))
        check(readings.wind.refusals == 0 && readings.wind.band == .calm, "refusals older than an hour no longer count")
        readings = CockpitReadings(run: run, live: true, now: at(65))
        check(readings.wind.refusals == 0 && readings.wind.silent && readings.wind.band == .breeze, "an hour of quiet is itself a little wind")
        readings = CockpitReadings(run: run, live: false, now: at(5_000))
        check(readings.wind.refusals == 2, "a saved run is judged as of its last activity, not as of today")
        run.addExchange(CockpitSupervisorExchange(stepID: run.plan.steps[0].id.uuidString, asked: at(5), question: "q", answer: "", outOfScope: false, failed: true))
        run.addExchange(CockpitSupervisorExchange(stepID: run.plan.steps[0].id.uuidString, asked: at(5), question: "q2", answer: "a", outOfScope: false, failed: false))
        readings = CockpitReadings(run: run, live: true, now: at(6))
        check(readings.wind.unanswered == 1 && readings.wind.score == 3 && readings.wind.band == .gusty, "an unanswered question adds wind; an answered one does not")
        check(run.completeCurrent(passed: false, detail: "broken", build: "", now: at(7)), "a step fails")
        readings = CockpitReadings(run: run, live: true, now: at(8))
        check(readings.wind.failedSteps == 1 && readings.lamps.stepFailed && readings.lamps.paused && readings.wind.score == 4, "a failed step is wind, and lights two lamps")
        check(CockpitReadings.windBand(0) == .calm && CockpitReadings.windBand(2) == .breeze && CockpitReadings.windBand(3) == .gusty
              && CockpitReadings.windBand(5) == .gusty && CockpitReadings.windBand(6) == .storm && CockpitReadings.windBand(40) == .storm, "wind bands")

        // --- Pulse and silence
        run = started(makePlan(steps: 2))
        readings = CockpitReadings(run: run, live: true, now: at(1))
        check(readings.pulse.band == .ok && readings.pulse.quietSeconds == 60 && !readings.lamps.silent, "a minute after the step began the pulse is fine")
        readings = CockpitReadings(run: run, live: true, now: at(6))
        check(readings.pulse.band == .caution, "five minutes of quiet is caution")
        readings = CockpitReadings(run: run, live: true, now: at(21))
        check(readings.pulse.band == .silent && readings.lamps.silent && readings.wind.silent && readings.wind.score == 1, "20 minutes of quiet is silence, and a little wind")
        readings = CockpitReadings(run: run, live: true, now: at(21), activity: at(20))
        check(readings.pulse.band == .ok, "a call of the agent that is too small to save still counts as a sign of life")
        readings = CockpitReadings(run: run, live: false, now: at(21))
        check(readings.pulse.band == .idle && readings.pulse.quietSeconds == nil && !readings.lamps.silent, "a run that is not going has no pulse")

        // --- Lamps and the supervisor lever
        var noSupervisor = CockpitControls()
        noSupervisor.supervisor = false
        run = started(makePlan(steps: 2, controls: noSupervisor))
        check(CockpitReadings(run: run, live: true, now: at(1)).lamps.supervisorOff, "a supervisor that the plan leaves off lights its lamp")
        run = started(makePlan(steps: 2))
        check(!CockpitReadings(run: run, live: true, now: at(1)).lamps.supervisorOff, "a supervisor that is on does not")
        var cut = CockpitLiveSwitches()
        cut.supervisorCut = true
        check(CockpitReadings(run: run, live: true, now: at(1), cuts: cut).lamps.supervisorOff, "a lever that switches the supervisor off lights it")
        run.setSwitches(cut, now: at(2))
        check(CockpitReadings(run: run, live: false, now: at(3)).lamps.supervisorOff, "a saved run remembers the lever")
        run = started(makePlan(steps: 2))
        run.pauseAtBoundary(reason: "paused by test", now: at(1))
        check(CockpitReadings(run: run, live: true, now: at(2)).lamps.paused, "a paused run lights its lamp")

    }
}

private func projectChangesFootprintMB() -> Double {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
}

extension EditorHostTests {
    func testProjectChangeScannerAndWatcher() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("markview-changes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        func write(_ path: String, _ data: Data) {
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        func write(_ path: String, _ text: String) { write(path, Data(text.utf8)) }
        /// Filesystem dates have a resolution; a later write must look newer.
        func waitForNewerDate() { usleep(20_000) }

        write("notes.md", "first\n")
        write("picture.png", Data(repeating: 7, count: 4_096))
        write("large.log", Data(repeating: 65, count: ProjectChangeScanner.maximumHashBytes + 1))
        write(".turbo/cache/task.log", "cached output\n")
        write(".claude/worktrees/feature/app.swift", "let copy = 1\n")
        write(".claude/settings.json", "{}\n")
        write(".worktrees/feature/app.swift", "let copy = 1\n")
        write("nested/.worktrees/feature/app.swift", "let copy = 1\n")
        write("worktrees/notes.md", "first\n")

        let scanner = ProjectChangeScanner()
        try await scanner.open(root)
        check(try await scanner.refresh().isEmpty, "an unchanged project reports no changes")

        waitForNewerDate()
        write("notes.md", "second\n")
        write(".turbo/cache/task.log", "new cached output\n")
        write(".turbo/cache/other.log", "more\n")
        write(".claude/worktrees/feature/app.swift", "let copy = 2\n")
        write(".claude/worktrees/feature/new.swift", "let added = 1\n")
        write(".worktrees/feature/app.swift", "let copy = 2\n")
        write(".worktrees/feature/new.swift", "let added = 1\n")
        write("nested/.worktrees/feature/app.swift", "let copy = 2\n")
        write("worktrees/notes.md", "second\n")
        var changes = try await scanner.refresh()
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        check(byPath["notes.md"]?.kind == .modified && byPath["notes.md"]?.before == "first\n" && byPath["notes.md"]?.current == "second\n",
              "a text change keeps both texts")
        check(!changes.contains { $0.path.hasPrefix(".turbo/") }, "a build cache is not walked: \(changes.map(\.path))")
        check(!changes.contains { $0.path.hasPrefix(".claude/worktrees/") }, "agent worktrees are not walked: \(changes.map(\.path))")
        check(!changes.contains { $0.path.split(separator: "/").contains(".worktrees") },
              "root and nested .worktrees copies are not walked: \(changes.map(\.path))")
        check(byPath["worktrees/notes.md"]?.kind == .modified, "an ordinary worktrees folder is still tracked")

        await scanner.acknowledge()
        waitForNewerDate()
        write("large.log", Data(repeating: 66, count: ProjectChangeScanner.maximumHashBytes + 2))
        write("picture.png", Data(repeating: 8, count: 4_096))
        write(".claude/settings.json", "{\"a\":1}\n")
        changes = try await scanner.refresh()
        let kinds = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        check(kinds["large.log"]?.kind == .modified && kinds["large.log"]?.current == nil,
              "a large file's change is seen without reading it")
        check(kinds["picture.png"]?.kind == .modified, "a binary file's change is seen without reading it")
        check(kinds[".claude/settings.json"]?.kind == .modified, "other files under .claude are still tracked")

        // 200 MB in 50 files below the hashing limit: each is read, and its chunks must not outlive the file.
        let bulk = root.appendingPathComponent("bulk", isDirectory: true)
        try? fm.createDirectory(at: bulk, withIntermediateDirectories: true)
        let chunk = Data(repeating: 1, count: 4 << 20)
        for index in 0..<50 { try? chunk.write(to: bulk.appendingPathComponent("part-\(index).bin.data")) }
        let before = projectChangesFootprintMB()
        let ready = DispatchSemaphore(value: 0)
        let measurement = Task.detached(priority: .userInitiated) { () -> Double in
            var peak = projectChangesFootprintMB()
            ready.signal()
            while !Task.isCancelled {
                peak = max(peak, projectChangesFootprintMB())
                usleep(1_000)
            }
            return max(peak, projectChangesFootprintMB())
        }
        defer { measurement.cancel() }
        ready.wait()
        let fresh = ProjectChangeScanner()
        try await fresh.open(root)
        measurement.cancel()
        let growth = await measurement.value - before
        check(before > 0 && growth < 80, "a walk over 200 MB of files holds at most one file at a time (peak grew \(Int(growth)) MB)")

        // The watcher sees nested changes without polling the full tree and ignores generated folders.
        let monitorRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".markview-watch-\(UUID().uuidString)")
        try? fm.createDirectory(at: monitorRoot.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: monitorRoot.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        final class NotificationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let notifications = NotificationCounter()
        let monitor = ProjectChangeMonitor(root: monitorRoot) { notifications.increment() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        try? Data("visible".utf8).write(to: monitorRoot.appendingPathComponent("nested/note.md"))
        for _ in 0..<40 where notifications.count() == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
        check(notifications.count() > 0, "the recursive watcher notices a nested file change")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let beforeIgnored = notifications.count()
        try? Data("generated".utf8).write(to: monitorRoot.appendingPathComponent("node_modules/generated.js"))
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        check(notifications.count() == beforeIgnored, "the watcher ignores changes under node_modules")
        withExtendedLifetime(monitor) {}
        try? fm.removeItem(at: monitorRoot)
    }
}

private func databaseFixtureShell(_ command: String, timeout: TimeInterval = 30) async -> (Int32, String) {
    let result = await Subprocess.run(.init(executable: "/bin/sh", arguments: ["-c", command], timeout: timeout))
    return (result.timedOut ? 124 : result.exitCode, result.stdout + result.stderr)
}

private final class DatabaseExplorerFixtureRecorder: DeploymentExecutor, @unchecked Sendable {
    let inner: DeploymentExecutor
    var commands: [String] = []
    var stdins: [String] = []
    init(inner: DeploymentExecutor) { self.inner = inner }
    func run(_ command: String, stdin: String?, timeout: TimeInterval) async -> CommandResult {
        commands.append(command); stdins.append(stdin ?? "")
        return await inner.run(command, stdin: stdin, timeout: timeout)
    }
}


extension EditorHostTests {
    @MainActor func testDatabaseExplorerParsingAndPolicy() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // MARK: URL
        let u = DatabaseURL("postgresql://app_user:p%40ss%2Fword@ep-cool-123.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require")
        check(u?.host == "ep-cool-123.us-east-2.aws.neon.tech" && u?.user == "app_user" && u?.password == "p@ss/word" && u?.database == "neondb", "a Neon URL is parsed, the password decoded")
        check(u?.sslmode == "require" && u?.channelBinding == "require", "sslmode and channel binding are kept")
        check(u?.redacted == "postgresql://app_user@ep-cool-123.us-east-2.aws.neon.tech/neondb", "the redacted form has no password")
        check(!"\(u!)".contains("ss") && !String(describing: u!).contains("word"), "printing the URL never shows the password")
        check(u?.scrub("FATAL: password authentication failed for p@ss/word and p%40ss%2Fword") == "FATAL: password authentication failed for •••• and ••••", "a password is scrubbed from text in both forms")
        let plain = DatabaseURL("postgres://u:pw1234@localhost:5433/mydb")
        check(plain?.port == 5433 && plain?.host == "localhost" && plain?.database == "mydb", "port and host")
        check(DatabaseURL("postgres://u:a@b@host/db")?.password == "a@b" && DatabaseURL("postgres://u:a@b@host/db")?.host == "host", "an unencoded @ in the password is tolerated")
        check(DatabaseURL("postgres://u@[::1]:5432/d")?.host == "::1", "IPv6 host")
        check(DatabaseURL("postgres://u:p@/db?host=/var/run/postgresql")?.host == "/var/run/postgresql", "socket path from the query")
        check(DatabaseURL("mysql://u:p@h/d") == nil && DatabaseURL("not a url") == nil && DatabaseURL("postgres://u:p@h/d\nx") == nil, "other things are refused")

        // MARK: .env
        let env = EnvFile.parse("""
        # comment
        DATABASE_URL="postgres://a:b1234@h1/d1"
        export OTHER=postgres://c:d1234@h2/d2 # note
        EMPTY=
        BAD LINE
        """)
        check(env.map(\.key) == ["DATABASE_URL", "OTHER", "EMPTY"] && env[0].value == "postgres://a:b1234@h1/d1" && env[1].value == "postgres://c:d1234@h2/d2", "env file lines, quotes, export and comments")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("api"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? "DATABASE_URL=postgres://real:s3cr3tpw@ep-a-1.neon.tech/prod\nPORT=3000\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try? "DB=postgres://user:password@localhost/x\n".write(to: root.appendingPathComponent("api/.env.example"), atomically: true, encoding: .utf8)
        let found = DatabaseCandidates.scan(root: root)
        check(found.count == 2 && found[0].redacted == "postgresql://real@ep-a-1.neon.tech/prod" && !found[0].looksLikeExample, "candidates are found in .env files")
        check(found.contains { $0.file == "api/.env.example" && $0.looksLikeExample }, "an example file is marked as one")
        check(!found.map(\.redacted).joined().contains("s3cr3tpw"), "candidates never hold the password")
        let target = DatabaseTarget(id: "d", title: "d", source: .envFile, file: ".env", key: "DATABASE_URL")
        if case .success(let url) = DatabaseCandidates.resolve(target, root: root, keychain: { _ in nil }) { check(url.password == "s3cr3tpw", "a target resolves to its URL") } else { check(false, "a target resolves to its URL") }
        var escape = target; escape.file = "../x/.env"
        if case .failure = DatabaseCandidates.resolve(escape, root: root, keychain: { _ in nil }) { check(true, "a file outside the project is refused") } else { check(false, "a file outside the project is refused") }
        var missing = target; missing.key = "NOPE"
        if case .failure(let p) = DatabaseCandidates.resolve(missing, root: root, keychain: { _ in nil }) { check(p.message.contains("NOPE"), "a missing variable is named") } else { check(false, "a missing variable is named") }

        // MARK: SQL policy
        func risk(_ s: String) -> SQLPolicy.Risk { SQLPolicy.classify(s) }
        check(risk("select 1") == .readOnly && risk("  SELECT * from t where a = 'x;y'; ") == .readOnly, "select is read-only, a ; in a string is not a second statement")
        check(risk("with a as (select 1) select * from a") == .readOnly && risk("show server_version") == .readOnly && risk("explain select 1") == .readOnly, "with, show and explain are read-only")
        check(risk("-- hi\n/* x */ select 1") == .readOnly, "comments are skipped")
        if case .needsConfirmation = risk("delete from t") {} else { check(false, "delete asks") }
        if case .needsConfirmation = risk("update t set a = 1") {} else { check(false, "update asks") }
        if case .needsConfirmation = risk("drop table t") {} else { check(false, "drop asks") }
        if case .needsConfirmation = risk("explain analyze delete from t") {} else { check(false, "explain analyze asks") }
        if case .needsConfirmation = risk("select pg_read_file('/etc/passwd')") {} else { check(false, "pg_read_file asks") }
        if case .needsConfirmation = risk("select * into new_t from t") {} else { check(false, "select into asks") }
        check({ if case .needsConfirmation = risk("delete from t") { return true }; return false }(), "writes ask")
        if case .blocked = risk("select 1; delete from t") {} else { check(false, "two statements are refused") }
        if case .blocked = risk("select 1\n\\! rm -rf /") {} else { check(false, "a psql meta-command is blocked") }
        check(risk("select 'a\\b'") == .readOnly, "a backslash inside a string is fine")
        if case .blocked = risk("copy t to program 'sh'") {} else { check(false, "copy program is blocked") }
        if case .blocked = risk("select 'unclosed") {} else { check(false, "an unfinished quote is refused") }
        check(risk("select $q$ ; \\ $q$") == .readOnly, "dollar quotes hold anything")
        if case .blocked = risk("   ") {} else { check(false, "nothing to run is refused") }

        // MARK: CSV
        let rows = CSV.parse("a,b\r\n1,\"x,\"\"y\"\"\nz\"\n,2\n")
        check(rows == [["a", "b"], ["1", "x,\"y\"\nz"], ["", "2"]], "csv: quotes, commas, newlines, empty cells")
        check(PostgresClient.parse("n\n" + (1...600).map(String.init).joined(separator: "\n")).rows.count == 500 && PostgresClient.parse("n\n1\n").truncated == false, "rows are capped at 500")
        check(PostgresClient.detailSQL(schema: "a\"b", table: "it's").contains("\"a\"\"b\".\"it''s\""), "identifiers are quoted in generated SQL")
    }

    @MainActor func testDatabaseExplorerLocalPostgres() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // MARK: A real database
        let hasDocker = await databaseFixtureShell("exec docker info >/dev/null 2>&1", timeout: 3).0 == 0
        let hasPsql = await databaseFixtureShell("command -v psql || ls /opt/homebrew/opt/libpq/bin/psql").0 == 0
        guard hasDocker, hasPsql else {
            throw XCTSkip("Docker or psql is unavailable")
        }
        let name = "mv-dbx-\(UUID().uuidString.prefix(8))"
        let port = 55000 + Int.random(in: 100...900)
        let image = await databaseFixtureShell("docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^(postgres|pgvector/pgvector):' | head -1").1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else { throw XCTSkip("No local PostgreSQL image is available") }
        _ = await databaseFixtureShell("docker run -d --rm --name \(name) -e POSTGRES_PASSWORD='pw:with@odd/chars' -e POSTGRES_DB=shop -p 127.0.0.1:\(port):5432 \(image)")
        var ready = false
        for _ in 0..<60 {
            if await databaseFixtureShell("docker exec \(name) pg_isready -U postgres -d shop").0 == 0, await databaseFixtureShell("docker exec \(name) psql -U postgres -d shop -c 'select 1'").0 == 0 { ready = true; break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        check(ready, "a throwaway PostgreSQL started")
        guard ready else { _ = await databaseFixtureShell("docker rm -f \(name)"); return }
        _ = await databaseFixtureShell("docker exec \(name) psql -U postgres -d shop -c \"create table customers(id serial primary key, name text not null, note text); insert into customers(name, note) select 'c' || g, case when g % 2 = 0 then 'multi' || chr(10) || 'line, ' || chr(34) || 'quoted' || chr(34) end from generate_series(1, 120) g; create index on customers(name); create view big as select * from customers where id > 100; analyze;\"")
        let encoded = "pw%3Awith%40odd%2Fchars"
        let url = DatabaseURL("postgresql://postgres:\(encoded)@127.0.0.1:\(port)/shop")!
        let local = LocalExecutor(directory: nil)

        switch await PostgresClient.overview(url: url, executor: local) {
        case .success(let o):
            check(o.database == "shop" && o.user == "postgres" && o.bytes > 1_000_000 && o.version.hasPrefix("PostgreSQL"), "overview: name, user, size, version (\(databaseBytes(o.bytes)))")
            let customers = o.tables.first { $0.name == "customers" }
            check(customers?.schema == "public" && (customers?.rows ?? 0) >= 100 && (customers?.bytes ?? 0) > 0 && (customers?.indexBytes ?? 0) > 0 && customers?.kind == "r", "overview: a table with rows, size and index size")
            check(o.tables.first { $0.name == "big" }?.kind == "v", "overview: a view is listed as a view")
            check(o.connections >= 1 && o.maxConnections > 0, "overview: connections")
            check(!o.tables.contains { $0.schema == "pg_catalog" }, "overview: system schemas are left out")
        case .failure(let p): check(false, "overview works: \(p.message)")
        }
        switch await PostgresClient.detail(schema: "public", table: "customers", url: url, executor: local) {
        case .success(let d):
            check(d.columns.map(\.name) == ["id", "name", "note"] && d.columns[1].notNull && d.columns[0].defaultValue.contains("nextval"), "detail: columns with types, not null and defaults")
            check(d.indexes.count == 2 && d.constraints.contains { $0.contains("PRIMARY KEY") }, "detail: indexes and constraints")
        case .failure(let p): check(false, "detail works: \(p.message)")
        }
        switch await PostgresClient.run(PostgresClient.sampleSQL(schema: "public", table: "customers"), url: url, executor: local, readOnly: true) {
        case .success(let r): check(r.columns == ["id", "name", "note"] && r.rows.count == 50 && r.rows[1][2] == "multi\nline, \"quoted\"", "sample rows, with a multi-line quoted cell intact (\(r.rows.count) rows, \(r.rows.dropFirst().first ?? []))")
        case .failure(let p): check(false, "sample works: \(p.message)")
        }
        switch await PostgresClient.run("select count(*) as n from customers", url: url, executor: local, readOnly: true) {
        case .success(let r): check(r.rows == [["120"]], "a query returns its rows")
        case .failure(let p): check(false, "query works: \(p.message)")
        }
        // The server itself refuses writes.
        switch await PostgresClient.run("delete from customers", url: url, executor: local, readOnly: true) {
        case .failure(let p): check(p.message.lowercased().contains("read-only"), "the server refuses a write in read-only mode (\(p.message))")
        case .success: check(false, "the server refuses a write in read-only mode")
        }
        switch await PostgresClient.run("with d as (delete from customers returning 1) select count(*) from d", url: url, executor: local, readOnly: true) {
        case .failure(let p): check(p.message.lowercased().contains("read-only"), "a data-changing WITH is refused too")
        case .success: check(false, "a data-changing WITH is refused too")
        }
        switch await PostgresClient.run("select pg_sleep(5)", url: url, executor: local, readOnly: true, timeoutSeconds: 1) {
        case .failure(let p): check(p.message.lowercased().contains("timeout"), "a slow query is cancelled by the server (\(p.message))")
        case .success: check(false, "a slow query is cancelled by the server")
        }
        // A wrong password: a clear error that does not hold the password.
        let wrong = DatabaseURL("postgresql://postgres:nope-nope@127.0.0.1:\(port)/shop")!
        switch await PostgresClient.run("select 1", url: wrong, executor: local, readOnly: true) {
        case .failure(let p): check(p.message.contains("authentication") && !p.message.contains("nope-nope"), "a wrong password is reported without the password (\(p.message))")
        case .success: check(false, "a wrong password fails")
        }
        let recorder = DatabaseExplorerFixtureRecorder(inner: local)
        _ = await PostgresClient.run("select 1", url: url, executor: recorder, readOnly: true)
        check(!recorder.commands.isEmpty && !recorder.commands.joined().contains("odd") && !recorder.commands.joined().contains("chars"), "the password is never in the command line")
        check(recorder.stdins.first?.contains("pw:with@odd/chars") == true, "it travels on standard input")

        // MARK: Through the store, with approval
        let previousApprovalTimeout = DeploymentStore.approvalTimeout
        defer { DeploymentStore.approvalTimeout = previousApprovalTimeout }
        DeploymentStore.approvalTimeout = 2
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try? "DATABASE_URL=postgresql://postgres:\(encoded)@127.0.0.1:\(port)/shop\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let store = DeploymentStore()
        store.setRoot(project)
        store.add(DeploymentEnvironment(id: "", name: "Cloud DB", kind: .cloud, provider: "neon"))
        let candidates = store.databaseCandidates()
        check(candidates.count == 1 && candidates[0].key == "DATABASE_URL", "the store finds the candidate")
        store.connectDatabase(env: "cloud-db", title: "Shop", candidate: candidates[0])
        let id = store.environment("cloud-db")?.databases.first?.id ?? ""
        check(id == "shop", "a database is connected to the environment")
        let saved = (try? String(contentsOf: project.appendingPathComponent(".dde/deployments.json"), encoding: .utf8)) ?? ""
        check(saved.contains("DATABASE_URL") && !saved.contains("odd") && !saved.contains("postgres://"), "the saved file names the variable, never the URL")
        for _ in 0..<80 where store.databaseState("cloud-db", id).overview == nil && store.databaseState("cloud-db", id).error == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        check(store.databaseState("cloud-db", id).overview?.tables.contains { $0.name == "customers" } == true, "connecting loads the overview")
        check(store.report().contains("database shop") && store.report().contains("markview_deployments_db"), "the report mentions the database")

        if case .ran(let r, let wrote) = await store.runQuery("select name from customers order by id limit 2", env: "cloud-db", target: id, origin: "You") {
            check(r.rows == [["c1"], ["c2"]] && !wrote && store.approval == nil, "a select runs at once")
        } else { check(false, "a select runs at once") }
        async let denied = store.runQuery("delete from customers", env: "cloud-db", target: id, origin: "The assistant", purpose: "test")
        for _ in 0..<50 where store.approval == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        check(store.approval?.command.contains("delete from customers") == true && store.approval?.command.contains("odd") == false, "a delete waits for the person, and shows the redacted host")
        store.answer(false)
        if case .denied = await denied {} else { check(false, "a no is a no") }
        if case .ran(let r, _) = await store.runQuery("select count(*) from customers", env: "cloud-db", target: id, origin: "You") { check(r.rows == [["120"]], "after a no the data is untouched") }
        async let allowed = store.runQuery("delete from customers where id > 100", env: "cloud-db", target: id, origin: "You")
        for _ in 0..<50 where store.approval == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        store.answer(true)
        if case .ran(_, let wrote) = await allowed { check(wrote, "after a yes the write runs") } else { check(false, "after a yes the write runs") }
        if case .ran(let r, _) = await store.runQuery("select count(*) from customers", env: "cloud-db", target: id, origin: "You") { check(r.rows == [["100"]], "and changed the data") }
        if case .blocked = await store.runQuery("select 1\n\\! echo hi", env: "cloud-db", target: id, origin: "The assistant") {} else { check(false, "a meta-command never runs") }
        let logText = (try? String(contentsOf: project.appendingPathComponent(".dde/deployments-log.jsonl"), encoding: .utf8)) ?? ""
        check(logText.contains("SQL on shop") && !logText.contains("odd") && logText.contains("denied") && logText.contains("blocked"), "the log notes the statements, not the password")
        store.disconnectDatabase(env: "cloud-db", target: id)
        check(store.environment("cloud-db")?.databases.isEmpty == true, "a database can be disconnected")

        _ = await databaseFixtureShell("docker rm -f \(name)")
    }
}
