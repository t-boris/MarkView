import Foundation
import MarkViewCore
import SQLite3
import XCTest
@testable import MarkView

private func projectOperationFixture(_ number: Int) -> ProjectOperation {
    ProjectOperation(id: "op-\(number)", label: "Operation \(number)", kind: "build", command: "echo \(number)")
}

extension EditorHostTests {
    func testProjectOperationDiscoveryScan() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("operation-scan-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project", isDirectory: true)
        let scripts = base.appendingPathComponent("infra/scripts", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("server"), withIntermediateDirectories: true)
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "../infra contains the install procedure.\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "The scripts live in ../../infra/scripts as well.\n".write(to: root.appendingPathComponent("docs/runbook.md"), atomically: true, encoding: .utf8)
        try #"{"scripts":{"build":"echo build"}}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "[project]\n".write(to: root.appendingPathComponent("server/pyproject.toml"), atomically: true, encoding: .utf8)
        try "plugins {}\n".write(to: root.appendingPathComponent("server/build.gradle.kts"), atomically: true, encoding: .utf8)
        try "echo install\n".write(to: scripts.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        let secret = base.appendingPathComponent("infra/.env")
        try "SECRET=do-not-read\n".write(to: secret, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: scripts.appendingPathComponent("linked.env"), withDestinationURL: secret)
        let first = ProjectOperationDiscovery.scan(root: root)
        XCTAssertTrue(first.files.contains { $0.location == "package.json" })
        XCTAssertTrue(first.files.contains { $0.location == "server/pyproject.toml" })
        XCTAssertTrue(first.files.contains { $0.location == "server/build.gradle.kts" })
        XCTAssertEqual(first.grantedFolders.count, 2)
        XCTAssertEqual(Set(first.files.map(\.url.path)).count, first.files.count)
        XCTAssertEqual(first.files.filter { $0.location.hasSuffix("install.sh") }.count, 1)
        XCTAssertTrue(first.files.contains { $0.location.hasSuffix("install.sh") && $0.external })
        XCTAssertFalse(first.files.contains { $0.location.hasSuffix(".env") || $0.location.hasSuffix("linked.env") })
        try #"{"scripts":{"build":"echo changed"}}"#.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(first.signature, ProjectOperationDiscovery.scan(root: root).signature)
    }

    @MainActor func testProjectOperationWritesAndHistory() async throws {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail(), line: line)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-operation-writes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = ProjectOperationWrites(root: root)

        // 1. Forty edits asked for without waiting for one another: none is dropped by another, and each is written on top of the last.
        var seen: [Int] = []
        var failed: [String] = []
        for number in 1...40 {
            writes.edit({ document in document.operations.append(projectOperationFixture(number)) }) { result in
                switch result {
                case .success(let document): seen.append(document.operations.count)
                case .failure(let error): failed.append(error.localizedDescription)
                }
            }
        }
        await writes.drain()
        let stored = try ProjectOperationsFile.read(root: root)
        check("every one of 40 edits is in the file", Set(stored.operations.map(\.id)) == Set((1...40).map { "op-\($0)" }),
              "found \(stored.operations.count)")
        check("each edit saw the file as the one before it left it", seen == Array(1...40), "\(seen)")
        check("no edit failed", failed.isEmpty, "\(failed)")

        // 2. An edit that fails (it duplicates an id) reports its own error and stops none of the edits after it.
        var outcomes: [String] = []
        writes.edit({ $0.operations.append(projectOperationFixture(41)) }) { result in outcomes.append((try? result.get()) != nil ? "41 saved" : "41 failed") }
        writes.edit({ $0.operations.append(projectOperationFixture(41)) }) { result in outcomes.append((try? result.get()) != nil ? "41 again saved" : "41 again failed") }
        writes.edit({ $0.operations.append(projectOperationFixture(42)) }) { result in outcomes.append((try? result.get()) != nil ? "42 saved" : "42 failed") }
        await writes.drain()
        let afterFailure = try ProjectOperationsFile.read(root: root)
        check("a failing edit is reported to its own caller", outcomes == ["41 saved", "41 again failed", "42 saved"], "\(outcomes)")
        check("an edit after a failing one is still written", afterFailure.operations.count == 42, "found \(afterFailure.operations.count)")

        // 3. A change that landed in the file by hand between two edits is kept by the edit that follows it.
        writes.edit({ $0.operations.append(projectOperationFixture(43)) }) { _ in }
        await writes.drain()
        var byHand = try ProjectOperationsFile.read(root: root)
        byHand.operations.append(projectOperationFixture(900))
        try ProjectOperationsFile.write(byHand, root: root)
        writes.edit({ $0.operations.append(projectOperationFixture(44)) }) { _ in }
        await writes.drain()
        let merged = try ProjectOperationsFile.read(root: root)
        check("an edit is applied on top of a hand edit", Set(merged.operations.map(\.id)).isSuperset(of: ["op-43", "op-900", "op-44"]), "\(merged.operations.count)")

        // 4. A run's records are saved in the order they were asked for: a short run asks for "running" and then "succeeded".
        let started = Date()
        for round in 0..<30 {
            for state in ["running", "succeeded"] {
                writes.record(ProjectOperationLastRun(id: "build", label: "Build", environment: nil, command: "make", cwd: ".", started: started,
                                                      ended: state == "running" ? nil : Date(), state: state, exitCode: state == "running" ? nil : Int32(round)))
            }
        }
        writes.record(ProjectOperationLastRun(id: "deploy", label: "Deploy", environment: "production", command: "make deploy", cwd: ".",
                                              started: started, ended: nil, state: "running", exitCode: nil))
        await writes.drain()
        let history = try ProjectOperationHistory.load(root: root)
        check("the last record asked for is the one kept", history["build"]?.state == "succeeded" && history["build"]?.exitCode == 29,
              "\(String(describing: history["build"]?.state)) \(String(describing: history["build"]?.exitCode))")
        check("another operation's record is kept too", history["deploy"]?.state == "running")

        // 4b. A row of the history that cannot be read is logged and left out; the others are read and the row stays (AR-36).
        let database = try ProjectOperationHistory.open(root: root)
        sqlite3_exec(database, "INSERT INTO project_operation_runs (id, json) VALUES ('broken', '{ cut')", nil, nil, nil)
        sqlite3_close(database)
        let withBroken = try ProjectOperationHistory.load(root: root)
        check("a damaged history row is left out and the others are read", withBroken["broken"] == nil && withBroken["build"]?.exitCode == 29 && withBroken["deploy"] != nil)
        let again = try ProjectOperationHistory.open(root: root)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(again, "SELECT count(*) FROM project_operation_runs WHERE id = 'broken'", -1, &statement, nil)
        let kept = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        sqlite3_finalize(statement)
        sqlite3_close(again)
        check("reading leaves the damaged row in the database", kept == 1, "\(kept)")

        // 5. `drain()` with nothing asked for returns at once, and a queue that went idle takes more work.
        await writes.drain()
        writes.edit({ $0.operations.append(projectOperationFixture(45)) }) { _ in }
        await writes.drain()
        check("work asked for after the queue went idle is written", try ProjectOperationsFile.read(root: root).operations.contains { $0.id == "op-45" })

    }
}
