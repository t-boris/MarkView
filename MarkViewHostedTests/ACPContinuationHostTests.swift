import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Uses a local ACP fixture to check real continuation and permission handling.
final class ACPContinuationHostTests: XCTestCase {
    @MainActor func testContinuationsAndPermissions() async throws {
        executionTimeAllowance = 180
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost",
              let homePath = environment["MARKVIEW_CLI_TEST_HOME"],
              environment["CFFIXED_USER_HOME"] == homePath,
              let fixturePath = environment["MARKVIEW_CLI_TEST_FIXTURE"],
              let scratchPath = environment["MARKVIEW_CLI_TEST_SCRATCH"] else {
            XCTFail("ACP checks require an isolated app host, temporary home and fixture executable")
            return
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        let root = home.deletingLastPathComponent()
        let temporaryRoot = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        let fixture = URL(fileURLWithPath: fixturePath).resolvingSymlinksInPath()
        let logFolder = AICallLog.url.deletingLastPathComponent().resolvingSymlinksInPath()
        let scratch = URL(fileURLWithPath: scratchPath).resolvingSymlinksInPath()
        guard home.lastPathComponent == "home", root.lastPathComponent.hasPrefix("mvcli-test-"),
              home.path.hasPrefix(temporaryRoot.path + "/"),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == home,
              fixture.deletingLastPathComponent() == root, fixture.lastPathComponent == "continuation.py",
              FileManager.default.isExecutableFile(atPath: fixture.path),
              logFolder.path.hasPrefix(home.path + "/"),
              scratch.path == root.appendingPathComponent("scratch", isDirectory: true).path,
              AgentProcesses.count == 0,
              let copilot = CLITool(rawValue: "copilot") else {
            XCTFail("ACP checks refused a nonisolated home, fixture, log or child registry")
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
        CLIToolLocator.setOverride(fixture.path, for: copilot)
        guard CLIToolLocator.resolve(copilot) == fixture.path else {
            XCTFail("The ACP provider must resolve to the local test fixture")
            return
        }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func run(_ scenario: String) async throws -> CLICompletion.Result {
            var request = CLICompletion.Request(project: project, prompt: scenario, readableFolder: nil)
            request.tool = copilot
            request.timeout = 60
            request.jsonSchema = ["type": "object", "properties": ["body": ["type": "string"]], "required": ["body"]]
            return try await CLICompletion.run(request)
        }
        func body(_ result: CLICompletion.Result) -> String {
            ((result.structured as? [String: Any])?["body"] as? String) ?? ""
        }
        let expected = (0..<40).map { "prototype-markup-\($0) section" }.joined(separator: " ") + " end"
        let full = "{\"body\":\"" + expected + "\"}"
        let split = 300
        for scenario in ["[resume]", "[repeat-tail]", "[restart]", "[narrated]", "[internal-restart]",
                         "[internal-restart-continued]", "[pretty-restart]", "[pretty-restart-continued]"] {
            let result = body(try await run(scenario))
            XCTAssertEqual(result, expected, "Continuation must retain the complete answer for \(scenario)")
        }
        let completed = body(try await run("[complete-max-tokens]"))
        let narrated = body(try await run("[narrated-complete]"))
        XCTAssertEqual(completed, "done")
        XCTAssertEqual(narrated, "narrated")
        let large: [String: Any] = ["body": (0..<100).map { ["record": $0, "text": String(repeating: "source ", count: 400)] }]
        let largeJSON = String(decoding: try JSONSerialization.data(withJSONObject: large, options: [.prettyPrinted]), as: UTF8.self)
        let recovered = ACPAssistant.parseJSON(String(full.prefix(split)) + "\n" + largeJSON,
                                               schema: ["properties": ["body": [:]], "required": ["body"]]) as? [String: Any]
        XCTAssertEqual((recovered?["body"] as? [[String: Any]])?.count, 100)
        for (scenario, details) in [("[declines]", ["after 2 continuation turns"]),
                                    ("[never-ends]", ["cut off", "after 10 continuation turns"]),
                                    ("[no-progress]", ["after 1 continuation turn"])] {
            do {
                _ = try await run(scenario)
                XCTFail("An unfinished answer must fail for \(scenario)")
            } catch CLICompletion.Failure.invalidOutput(_, let detail) {
                for expectedDetail in details { XCTAssertTrue(detail.contains(expectedDetail), "Unexpected continuation failure: \(detail)") }
            }
        }
        var plain = CLICompletion.Request(project: project, prompt: "[plain-cut-off]", readableFolder: nil)
        plain.tool = copilot
        plain.timeout = 60
        let plainText = try await CLICompletion.run(plain).text
        XCTAssertEqual(plainText, "first part second part")
        func answers(readableFolder: URL?) async throws -> String {
            var request = CLICompletion.Request(project: project, prompt: "[permission]|" + project.path, readableFolder: readableFolder)
            request.tool = copilot
            request.timeout = 60
            return try await CLICompletion.run(request).text
        }
        let seen = try await answers(readableFolder: project)
        XCTAssertEqual(seen, "read-inside=yes,read-relative=yes,read-outside=no,search=yes,edit=no")
        let blind = try await answers(readableFolder: nil)
        XCTAssertEqual(blind, "read-inside=no,read-relative=no,read-outside=no,search=no,edit=no")
        for _ in 0..<100 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(AgentProcesses.count, 0, "Finished test assistants must be reaped")
    }
}
