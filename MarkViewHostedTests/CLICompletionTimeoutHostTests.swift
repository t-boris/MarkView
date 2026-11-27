import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Runs real completion processes only against an isolated, local fixture executable.
final class CLICompletionTimeoutHostTests: XCTestCase {
    /// The temporary home, the folder that holds it and the fixture executable the suite prepared; nil (with a failure) in any
    /// other host, home or folder, or while assistant processes of another test are still running.
    @MainActor private func isolatedFixture() -> (home: URL, root: URL, fixture: URL)? {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost",
              let homePath = environment["MARKVIEW_CLI_TEST_HOME"],
              environment["CFFIXED_USER_HOME"] == homePath,
              let fixturePath = environment["MARKVIEW_CLI_TEST_FIXTURE"] else {
            XCTFail("Completion checks require an isolated app host, temporary home and fixture executable")
            return nil
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        let root = home.deletingLastPathComponent()
        let temporaryRoot = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        let fixture = URL(fileURLWithPath: fixturePath).resolvingSymlinksInPath()
        let logFolder = AICallLog.url.deletingLastPathComponent().resolvingSymlinksInPath()
        let sessionNotes = KeptSessions.folder.resolvingSymlinksInPath()
        guard home.lastPathComponent == "home", root.lastPathComponent.hasPrefix("mvcli-test-"),
              home.path.hasPrefix(temporaryRoot.path + "/"),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == home,
              fixture.deletingLastPathComponent() == root, fixture.lastPathComponent == "timeout.py",
              FileManager.default.isExecutableFile(atPath: fixture.path),
              logFolder.path.hasPrefix(home.path + "/"), sessionNotes.path.hasPrefix(home.path + "/"),
              AgentProcesses.count == 0 else {
            XCTFail("Completion checks refused a nonisolated home, fixture, log or child registry")
            return nil
        }
        return (home, root, fixture)
    }

    /// Clears the test host's settings before and after a test (the assistant paths it points at the fixture).
    private func isolateSettings() {
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: "com.markview.tests.apphost")
        addTeardownBlock {
            AgentProcesses.terminateAll(grace: 0.2)
            defaults.removePersistentDomain(forName: "com.markview.tests.apphost")
            defaults.synchronize()
        }
    }

    @MainActor func testCompletionDeadlinesAndCancellation() async throws {
        executionTimeAllowance = 180
        guard let (_, root, fixture) = isolatedFixture() else { return }
        guard let codex = CLITool(rawValue: "codex"), let claude = CLITool(rawValue: "claude"),
              let copilot = CLITool(rawValue: "copilot") else {
            XCTFail("The completion providers must be registered")
            return
        }
        isolateSettings()
        let tools = [copilot, codex, claude]
        for tool in tools { CLIToolLocator.setOverride(fixture.path, for: tool) }
        guard tools.allSatisfy({ CLIToolLocator.resolve($0) == fixture.path }) else {
            XCTFail("Every completion provider must resolve to the local test fixture")
            return
        }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func request(_ tool: CLITool, timeout: TimeInterval?) -> CLICompletion.Request {
            var request = CLICompletion.Request(project: project, prompt: "[delayed-test]", readableFolder: project)
            request.tool = tool
            request.timeout = timeout
            request.jsonSchema = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
            return request
        }
        XCTAssertEqual(CLICompletion.Request(project: project, prompt: "x").timeout, 180)
        var windowRequest = request(claude, timeout: nil)
        windowRequest.assistantOverride = CLICompletion.Assistant(tool: codex, model: "window-model")
        XCTAssertTrue(windowRequest.tool == codex && windowRequest.resolvedModel == "window-model")
        windowRequest.assistantOverride = CLICompletion.Assistant(tool: codex, model: nil)
        windowRequest.model = "stale-project-model"
        XCTAssertNil(windowRequest.resolvedModel, "A captured CLI default must not pick up another model")
        let windowResult = try await CLICompletion.run(windowRequest)
        XCTAssertTrue((windowResult.structured as? [String: Any])?["ok"] as? Bool == true)
        for tool in tools {
            let result = try await CLICompletion.run(request(tool, timeout: nil))
            XCTAssertTrue((result.structured as? [String: Any])?["ok"] as? Bool == true)
            do {
                _ = try await CLICompletion.run(request(tool, timeout: 0.1))
                XCTFail("An explicit deadline must stop the request")
            } catch CLICompletion.Failure.timedOut(let failedTool, _) {
                XCTAssertEqual(failedTool, tool)
            }
            let task = Task { try await CLICompletion.run(request(tool, timeout: nil)) }
            try await Task.sleep(nanoseconds: 120_000_000)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Stopping must cancel an unbounded request")
            } catch is CancellationError {}
        }
        for tool in [codex, copilot] {
            var stubborn = request(tool, timeout: nil)
            stubborn.prompt = "[ignores-term]"
            let ready = project.appendingPathComponent("stubborn-ready")
            try? FileManager.default.removeItem(at: ready)
            let task = Task { try await CLICompletion.run(stubborn) }
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "The test CLI must start")
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancellation must kill an uncooperative CLI")
            } catch is CancellationError {}
            for _ in 0..<400 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(AgentProcesses.count, 0, "An uncooperative test CLI must be reaped")
        }
        var failed = request(copilot, timeout: nil)
        failed.prompt = "[provider-error]"
        do {
            _ = try await CLICompletion.run(failed)
            XCTFail("Provider errors must fail the run")
        } catch CLICompletion.Failure.failed(_, let detail) {
            XCTAssertTrue(detail.contains("fixture provider error"))
        }
        for _ in 0..<100 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(AgentProcesses.count, 0, "Completed and cancelled test assistants must be removed")
    }

    /// A Codex run that may read files keeps its session for the subagents it is asked to start, and the session is deleted when
    /// the run ends: with an answer, a timeout or a stop. A run without files keeps none and its subagent tools stay off. Sessions
    /// noted by a MarkView whose process is gone (a crash) are deleted by the launch sweep; a running one's are left alone.
    @MainActor func testCodexSessionsOfRunsThatReadFilesAreDeletedHoweverTheyEnd() async throws {
        executionTimeAllowance = 120
        guard let (home, root, fixture) = isolatedFixture() else { return }
        guard let codex = CLITool(rawValue: "codex") else {
            XCTFail("Codex must be registered")
            return
        }
        isolateSettings()
        CLIToolLocator.setOverride(fixture.path, for: codex)
        let fm = FileManager.default
        let project = root.appendingPathComponent("project-sessions", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let notes = KeptSessions.folder.appendingPathComponent(codex.rawValue, isDirectory: true)
        func rollouts() -> [String] {
            (fm.enumerator(at: sessions, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .map(\.lastPathComponent).filter { $0.hasPrefix("rollout-") }.sorted()
        }
        func noted() -> [String] { ((try? fm.contentsOfDirectory(atPath: notes.path)) ?? []).sorted() }
        func deletes() -> [String] {
            ((try? String(contentsOf: root.appendingPathComponent("codex-deleted.txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        // Only what this test leaves counts (the other test of the suite shares the fixture's folder).
        let earlierRollouts = Set(rollouts()), earlierDeletes = deletes().count
        func newRollouts() -> [String] { rollouts().filter { !earlierRollouts.contains($0) } }
        func newDeletes() -> Int { deletes().count - earlierDeletes }
        func lastRun() throws -> [String: Bool] {
            let text = try String(contentsOf: root.appendingPathComponent("codex-runs.jsonl"), encoding: .utf8)
            let line = try XCTUnwrap(text.split(separator: "\n").last)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Bool])
        }
        func request(_ prompt: String, readsFiles: Bool, timeout: TimeInterval?) -> CLICompletion.Request {
            var request = CLICompletion.Request(project: project, prompt: prompt, readableFolder: readsFiles ? project : nil)
            request.tool = codex
            request.timeout = timeout
            request.jsonSchema = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
            return request
        }

        // An answer: subagents on, the session kept while the run lasts and deleted before the answer is handed back.
        let answer = try await CLICompletion.run(request("Check.", readsFiles: true, timeout: nil))
        XCTAssertTrue((answer.structured as? [String: Any])?["ok"] as? Bool == true)
        XCTAssertEqual(try lastRun(), ["ephemeral": false, "agents_off": false, "asks_for_subagents": true])
        XCTAssertEqual(newDeletes(), 1, "The answered run's session is deleted")
        XCTAssertEqual(newRollouts(), [])
        XCTAssertEqual(noted(), [])

        // A timeout.
        do {
            _ = try await CLICompletion.run(request("[slow]", readsFiles: true, timeout: 1))
            XCTFail("The deadline must stop the run")
        } catch CLICompletion.Failure.timedOut {}
        XCTAssertEqual(newDeletes(), 2, "A timed-out run's session is deleted")
        XCTAssertEqual(newRollouts(), [])
        XCTAssertEqual(noted(), [])

        // A stop while the CLI runs: the session is noted while it runs and deleted although the run was cancelled.
        let stopped = Task { try await CLICompletion.run(request("[slow]", readsFiles: true, timeout: nil)) }
        for _ in 0..<300 where newRollouts().isEmpty || noted().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(newRollouts().count, 1, "The test CLI must start and keep its session")
        XCTAssertEqual(noted().count, 1, "A running run's session is noted")
        stopped.cancel()
        do {
            _ = try await stopped.value
            XCTFail("Stopping must cancel the run")
        } catch is CancellationError {}
        XCTAssertEqual(newDeletes(), 3, "A stopped run's session is deleted")
        XCTAssertEqual(newRollouts(), [])
        XCTAssertEqual(noted(), [])

        // No files: nothing to hand to subagents, so no session and no delete.
        _ = try await CLICompletion.run(request("Check.", readsFiles: false, timeout: nil))
        XCTAssertEqual(try lastRun(), ["ephemeral": true, "agents_off": true, "asks_for_subagents": false])
        XCTAssertEqual(newDeletes(), 3)

        // The launch sweep: a session noted by a process that is gone is deleted; a running MarkView's session is left alone.
        let day = sessions.appendingPathComponent("2026/11/27", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let left = UUID().uuidString.lowercased(), live = UUID().uuidString.lowercased()
        for id in [left, live] {
            try Data().write(to: day.appendingPathComponent("rollout-2026-11-27T10-00-00-\(id).jsonl"))
        }
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try String(Int32.max).write(to: notes.appendingPathComponent(left), atomically: true, encoding: .utf8)
        try String(getpid()).write(to: notes.appendingPathComponent(live), atomically: true, encoding: .utf8)
        await KeptSessions.deleteLeftovers()
        XCTAssertEqual(newRollouts(), ["rollout-2026-11-27T10-00-00-\(live).jsonl"])
        XCTAssertEqual(noted(), [live])
        XCTAssertEqual(deletes().last, left)
        try fm.removeItem(at: notes.appendingPathComponent(live))
        try fm.removeItem(at: day.appendingPathComponent("rollout-2026-11-27T10-00-00-\(live).jsonl"))
    }
}
