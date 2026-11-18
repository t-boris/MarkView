import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Runs real completion processes only against an isolated, local fixture executable.
final class CLICompletionTimeoutHostTests: XCTestCase {
    @MainActor func testCompletionDeadlinesAndCancellation() async throws {
        executionTimeAllowance = 180
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost",
              let homePath = environment["MARKVIEW_CLI_TEST_HOME"],
              environment["CFFIXED_USER_HOME"] == homePath,
              let fixturePath = environment["MARKVIEW_CLI_TEST_FIXTURE"] else {
            XCTFail("Completion checks require an isolated app host, temporary home and fixture executable")
            return
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        let root = home.deletingLastPathComponent()
        let temporaryRoot = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        let fixture = URL(fileURLWithPath: fixturePath).resolvingSymlinksInPath()
        let logFolder = AICallLog.url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard home.lastPathComponent == "home", root.lastPathComponent.hasPrefix("mvcli-test-"),
              home.path.hasPrefix(temporaryRoot.path + "/"),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == home,
              fixture.deletingLastPathComponent() == root, fixture.lastPathComponent == "timeout.py",
              FileManager.default.isExecutableFile(atPath: fixture.path),
              logFolder.path.hasPrefix(home.path + "/"), AgentProcesses.count == 0,
              let codex = CLITool(rawValue: "codex"), let claude = CLITool(rawValue: "claude"),
              let copilot = CLITool(rawValue: "copilot") else {
            XCTFail("Completion checks refused a nonisolated home, fixture, log or child registry")
            return
        }
        let defaults = UserDefaults.standard
        let domain = "com.markview.tests.apphost"
        defaults.removePersistentDomain(forName: domain)
        defer {
            AgentProcesses.terminateAll(grace: 0.2)
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
        }
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
}
