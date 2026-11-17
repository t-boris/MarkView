import AppKit
import Foundation
import MarkViewCore
import SQLite3
import XCTest
@testable import MarkView

private func projectOperationFixture(_ number: Int) -> ProjectOperation {
    ProjectOperation(id: "op-\(number)", label: "Operation \(number)", kind: "build", command: "echo \(number)")
}

extension EditorHostTests {
    func testProjectOperationMergeRules() {
        var failures = 0
        var quiet = false
        var details: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if !ok {
                failures += 1
                if !quiet { details.append(name + " " + detail()) }
            }
        }
        func json(_ operation: ProjectOperation) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try! encoder.encode(operation), as: UTF8.self)
        }

        // MARK: Fixtures

        /// What discovery proposed the first time, as it stands in the file when nobody touched it.
        func firstRun() -> ProjectOperation {
            var operation = ProjectOperation(
                id: "deploy-prod", label: "Deploy production", kind: "deploy", environment: "production", target: "api",
                nodes: [.init(id: "n1", name: "API")], command: "make deploy", cwd: ".", origin: "discovered",
                confidence: "medium", prerequisites: ["docker login"],
                provenance: [.init(kind: "project", location: "Makefile", line: 3)], remoteTrigger: false)
            operation.discovered = .init(command: operation.command, cwd: operation.cwd)
            operation.discoveredFields = operation.currentFields
            return operation
        }

        /// What the next discovery run proposes: every value discovery owns has changed.
        func secondRun() -> ProjectOperation {
            var operation = ProjectOperation(
                id: "deploy-prod", label: "Ship production", kind: "install", environment: "prod", target: "api-service",
                nodes: [.init(id: "n2", name: "API v2")], command: "make ship", cwd: "deploy", origin: "discovered",
                confidence: "high", prerequisites: ["docker login", "gh auth login"],
                provenance: [.init(kind: "project", location: "deploy.sh", line: 1)], remoteTrigger: false)
            operation.discovered = .init(command: operation.command, cwd: operation.cwd)
            operation.discoveredFields = operation.currentFields
            return operation
        }

        func edited(_ edit: (inout ProjectOperation) -> Void) -> ProjectOperation {
            var operation = firstRun()
            edit(&operation)
            return operation
        }

        /// The rule the store applied before BUG-036: an operation is the user's only when its command or
        /// working directory differs from `discovered`; any other operation is replaced by the proposal.
        func previousRule(stored: ProjectOperation, proposal: ProjectOperation) -> ProjectOperation {
            if stored.deleted || stored.origin == "user" { return stored }
            guard stored.isEdited else { return proposal }
            var kept = stored
            kept.discovered = proposal.discovered
            kept.provenance = proposal.provenance
            kept.confidence = proposal.confidence
            if !stored.nodesEdited { kept.nodes = proposal.nodes }
            return kept
        }

        typealias Merge = (ProjectOperation, ProjectOperation) -> ProjectOperation

        // MARK: Merge decisions

        func mergeChecks(_ merge: @escaping Merge) {
            // An operation nobody touched is refreshed with everything discovery now proposes.
            let refreshed = merge(firstRun(), secondRun())
            check("unedited operation: refreshed from the proposal", json(refreshed) == json(secondRun()), json(refreshed))

            var withFuture = firstRun()
            withFuture.extra["futureField"] = .string("kept")
            check("unedited operation: fields this version does not know are carried over",
                  merge(withFuture, secondRun()).extra["futureField"] != nil)

            var next = secondRun()
            next.remoteTrigger = true
            check("unedited operation: remote-trigger flag refreshed", merge(firstRun(), next).remoteTrigger)

            // Each edit alone, on an operation whose command and working directory are as discovered.
            // Whatever else the user did not touch stays as it is; only discovery metadata is refreshed.
            struct Edit { let name: String; let apply: (inout ProjectOperation) -> Void; let kept: (ProjectOperation) -> Bool }
            let edits: [Edit] = [
                Edit(name: "label", apply: { $0.label = "My label" }, kept: { $0.label == "My label" }),
                Edit(name: "kind", apply: { $0.kind = "other" }, kept: { $0.kind == "other" }),
                Edit(name: "environment set", apply: { $0.environment = "staging" }, kept: { $0.environment == "staging" }),
                Edit(name: "environment cleared", apply: { $0.environment = nil }, kept: { $0.environment == nil }),
                Edit(name: "target", apply: { $0.target = "worker" }, kept: { $0.target == "worker" }),
                Edit(name: "target cleared", apply: { $0.target = nil }, kept: { $0.target == nil }),
                Edit(name: "prerequisites", apply: { $0.prerequisites = ["my step"] }, kept: { $0.prerequisites == ["my step"] }),
                Edit(name: "prerequisites cleared", apply: { $0.prerequisites = [] }, kept: { $0.prerequisites.isEmpty }),
                Edit(name: "remote trigger", apply: { $0.remoteTrigger = true }, kept: { $0.remoteTrigger }),
                Edit(name: "command", apply: { $0.command = "make deploy-hotfix" }, kept: { $0.command == "make deploy-hotfix" }),
                Edit(name: "working directory", apply: { $0.cwd = "scripts" }, kept: { $0.cwd == "scripts" }),
                Edit(name: "deployment node", apply: { $0.nodes = [.init(id: "n9", name: "Mine")]; $0.extra["nodesEdited"] = .bool(true) },
                     kept: { $0.nodes.map(\.id) == ["n9"] }),
            ]
            for edit in edits {
                let stored = edited(edit.apply)
                let proposal = secondRun()
                let merged = merge(stored, proposal)
                check("\(edit.name) edit: user value kept", edit.kept(merged), json(merged))
                check("\(edit.name) edit: discovery metadata refreshed",
                      merged.discovered == proposal.discovered && merged.discoveredFields == proposal.discoveredFields
                        && merged.provenance == proposal.provenance && merged.confidence == proposal.confidence)
                var expected = stored
                expected.discovered = proposal.discovered
                expected.discoveredFields = proposal.discoveredFields
                expected.provenance = proposal.provenance
                expected.confidence = proposal.confidence
                if !stored.nodesEdited { expected.nodes = proposal.nodes }
                check("\(edit.name) edit: nothing else changes", json(merged) == json(expected), json(merged))
            }

            // An edit that was undone leaves nothing to protect.
            let undone = edited { $0.label = "Temporary"; $0.label = "Deploy production" }
            check("edit reverted by hand: refreshed again", json(merge(undone, secondRun())) == json(secondRun()))

            // A second run keeps comparing against the latest proposal, not the first one.
            let afterEdit = merge(edited { $0.label = "My label" }, secondRun())
            var third = secondRun()
            third.label = "Ship it"
            third.discoveredFields = third.currentFields
            check("edit survives a later run too", merge(afterEdit, third).label == "My label")

            // User-added and deleted operations are never touched by a proposal with the same id.
            var added = ProjectOperation(id: "deploy-prod", label: "Mine", kind: "deploy", command: "./mine.sh", cwd: ".", origin: "user")
            added.discoveredFields = nil
            check("user-added operation: untouched", json(merge(added, secondRun())) == json(added))
            var tombstone = firstRun()
            tombstone.deleted = true
            check("deleted operation: untouched", json(merge(tombstone, secondRun())) == json(tombstone))
            var editedTombstone = edited { $0.label = "Mine" }
            editedTombstone.deleted = true
            check("deleted operation with an edit: untouched", json(merge(editedTombstone, secondRun())) == json(editedTombstone))

            // The UI keys its confidence text and "Adopt discovered" action off isEdited: command or directory only.
            check("isEdited: a label edit is not a command edit", !edited { $0.label = "My label" }.isEdited)
            check("isEdited: a command edit is", edited { $0.command = "make x" }.isEdited)
        }

        // MARK: Operations written before the snapshot existed

        func legacyChecks(_ merge: @escaping Merge) {
            func legacy(_ edit: (inout ProjectOperation) -> Void = { _ in }) -> ProjectOperation {
                var operation = firstRun()
                edit(&operation)
                operation.discoveredFields = nil
                return operation
            }
            // Same discovery output, newer metadata: nothing to protect, and the snapshot is recorded.
            var same = firstRun()
            same.confidence = "high"
            same.provenance = [.init(kind: "project", location: "Makefile", line: 9)]
            let sameMerged = merge(legacy(), same)
            check("no snapshot, nothing differs: refreshed", json(sameMerged) == json(same), json(sameMerged))
            check("no snapshot, nothing differs: snapshot recorded", sameMerged.discoveredFields == same.discoveredFields)

            // A field that differs cannot be told from a user edit, so it stays. The snapshot is recorded so
            // that later runs compare against it.
            let differs = merge(legacy { $0.label = "My label" }, secondRun())
            check("no snapshot, label differs: kept", differs.label == "My label", json(differs))
            check("no snapshot, label differs: snapshot recorded", differs.discoveredFields == secondRun().discoveredFields)
            let drift = merge(legacy(), secondRun())
            check("no snapshot, discovery changed the label: kept", drift.label == "Deploy production" && drift.command == "make deploy")
            check("no snapshot, command edited: kept", merge(legacy { $0.command = "make x" }, secondRun()).command == "make x")

            var noBaseline = firstRun()
            noBaseline.discovered = nil
            noBaseline.discoveredFields = nil
            check("no snapshot at all, command differs: kept", merge(noBaseline, secondRun()).command == "make deploy")
            var matching = secondRun()
            matching.discovered = nil
            matching.discoveredFields = nil
            check("no snapshot at all, identical to the proposal: refreshed", json(merge(matching, secondRun())) == json(secondRun()))
        }

        // MARK: File layout

        func layoutChecks() {
            let decoder = JSONDecoder()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-merge-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            // A file written by an earlier version has no snapshot and is saved back byte for byte.
            var document = ProjectOperationsDocument()
            var older = firstRun()
            older.discoveredFields = nil
            var user = ProjectOperation(id: "my-script", label: "Mine", kind: "other", command: "./mine.sh")
            user.extra["futureField"] = .object(["list": .array([.int(1), .string("two")]), "flag": .bool(true), "none": .null])
            document.operations = [older, user]
            try! ProjectOperationsFile.write(document, root: root)
            let first = try! Data(contentsOf: ProjectOperationsFile.url(root: root))
            let text = String(decoding: first, as: UTF8.self)
            check("earlier file: no snapshot key is written", !text.contains("discoveredFields"))
            try! ProjectOperationsFile.write(try! ProjectOperationsFile.read(root: root), root: root)
            check("earlier file: saved back byte for byte", try! Data(contentsOf: ProjectOperationsFile.url(root: root)) == first)
            let reread = try! ProjectOperationsFile.read(root: root)
            check("earlier file: unknown fields survive", reread.operations.first { $0.id == "my-script" }?.extra["futureField"] != nil)

            // The snapshot goes into the file as one extra key per operation and nothing else changes.
            var proposal = secondRun()
            proposal.environment = nil
            proposal.discoveredFields = proposal.currentFields
            document.operations = [proposal]
            try! ProjectOperationsFile.write(document, root: root)
            let written = String(decoding: try! Data(contentsOf: ProjectOperationsFile.url(root: root)), as: UTF8.self)
            check("snapshot: written under discoveredFields", written.contains("\"discoveredFields\""))
            check("snapshot: command and cwd stay in discovered", written.contains("\"discovered\"") && written.contains("\"make ship\""))
            let back = try! ProjectOperationsFile.read(root: root).operations[0]
            check("snapshot: read back as written", back.discoveredFields == proposal.discoveredFields)
            check("snapshot: not mistaken for an unknown field", back.extra.isEmpty)
            check("snapshot: no environment means none", back.discoveredFields?.environment == nil)

            // A damaged snapshot only means "not recorded"; it must not make the file unreadable.
            let damaged = """
            {"id":"a","label":"A","kind":"build","nodes":[],"command":"make a","cwd":".","origin":"discovered",
             "discovered":{"command":"make a","cwd":"."},"discoveredFields":{"label":5},"prerequisites":[],"provenance":[]}
            """
            let operation = try? decoder.decode(ProjectOperation.self, from: Data(damaged.utf8))
            check("damaged snapshot: operation still reads", operation != nil && operation?.discoveredFields == nil)

            // The whole Re-discover step on a file: what the store does inside ProjectOperationsFile.mutate.
            var userEdit = firstRun()
            userEdit.id = "edited-label"
            userEdit.label = "My label"
            var untouched = firstRun()
            untouched.id = "untouched"
            var mine = ProjectOperation(id: "mine", label: "Mine", kind: "other", command: "./mine.sh")
            mine.discovered = nil
            var gone = firstRun()
            gone.id = "gone"
            gone.deleted = true
            document.operations = [userEdit, untouched, mine, gone]
            try! ProjectOperationsFile.write(document, root: root)
            var proposals: [ProjectOperation] = []
            for id in ["edited-label", "untouched", "mine", "gone", "brand-new"] {
                var next = secondRun()
                next.id = id
                proposals.append(next)
            }
            let result = try! ProjectOperationsFile.mutate(root: root) { document in
                for proposal in proposals {
                    if let index = document.operations.firstIndex(where: { $0.id == proposal.id }) {
                        document.operations[index] = ProjectOperation.merged(stored: document.operations[index], proposal: proposal)
                    } else {
                        document.operations.append(proposal)
                    }
                }
            }
            func find(_ id: String) -> ProjectOperation { result.operations.first { $0.id == id }! }
            check("file: edited label kept, snapshot refreshed",
                  find("edited-label").label == "My label" && find("edited-label").discoveredFields == secondRun().discoveredFields)
            check("file: untouched operation refreshed", find("untouched").label == "Ship production")
            check("file: user-added operation unchanged", find("mine").command == "./mine.sh" && find("mine").label == "Mine")
            check("file: deleted operation unchanged", find("gone").deleted && find("gone").label == "Deploy production")
            check("file: new operation added", result.operations.count == 5)
            let onDisk = try! ProjectOperationsFile.read(root: root)
            check("file: result is what was saved", onDisk.operations.map(json) == result.operations.sorted { $0.id < $1.id }.map(json))
        }

        // MARK: Run

        mergeChecks(ProjectOperation.merged(stored:proposal:))
        legacyChecks(ProjectOperation.merged(stored:proposal:))
        layoutChecks()
        let current = failures

        failures = 0
        quiet = true
        mergeChecks(previousRule(stored:proposal:))
        legacyChecks(previousRule(stored:proposal:))
        let previous = failures
        XCTAssertEqual(current, 0, details.joined(separator: "\n"))
        XCTAssertGreaterThan(previous, 0, "The checks must detect the old merge rule")
    }

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

private actor ProjectOperationScriptedResponses {
    private var answers: [Data]
    init(_ answers: [Data]) { self.answers = answers }
    func next() throws -> Data {
        guard !answers.isEmpty else { throw CancellationError() }
        return answers.removeFirst()
    }
}

@MainActor
private final class TestOperationPresenter: ProjectOperationsPresenter {
    var editors: [ProjectOperationEditRequest] = []
    var consoles: [String] = []
    var operationsHostWindow: NSWindow? { nil }
    func showOperationEditor(_ request: ProjectOperationEditRequest) { editors.append(request) }
    func showOperationConsole(selecting id: String) { consoles.append(id) }
}

@MainActor
private enum ProjectOperationsStoreHostChecks {
    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }

    /// Polls `condition` until it holds or `seconds` have passed.
    static func wait(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Time for a decision that should do nothing to have done it, had it been going to.
    static func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    static func project(_ name: String, in base: URL, operations: [ProjectOperation] = []) throws -> URL {
        let folder = ProjectOperationDiscovery.canonical(base.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# \(name)\nBuild with make.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "{\"scripts\":{\"build\":\"make\"}}".write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        if !operations.isEmpty {
            var document = ProjectOperationsDocument()
            document.operations = operations
            try ProjectOperationsFile.write(document, root: folder)
        }
        return folder
    }

    static func stored(_ folder: URL) throws -> [ProjectOperation] { try ProjectOperationsFile.read(root: folder).operations }

    static func runAll() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("operations-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let oldShell = getenv("SHELL").map { String(cString: $0) }
        let oldZdot = getenv("ZDOTDIR").map { String(cString: $0) }
        setenv("SHELL", "/bin/zsh", 1)
        setenv("ZDOTDIR", base.path, 1)
        defer {
            for name in ["run", "adopt", "proposals"] {
                let root = ProjectOperationDiscovery.canonical(base.appendingPathComponent(name))
                ProjectOperationsStore.existing(rootPath: root.path)?.cancelForClose()
                let hash = String(ContentHash.of(root.path).prefix(24))
                MarkViewCore.Settings.standard.remove(Setting.operationFingerprints(project: hash))
                MarkViewCore.Settings.standard.remove(Setting.operationsRejected(project: hash))
            }
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            if let oldZdot { setenv("ZDOTDIR", oldZdot, 1) } else { unsetenv("ZDOTDIR") }
            try? FileManager.default.removeItem(at: base)
        }

        try await runApproval(base)
        try await adoptDiscovered(base)
        try await proposals(base)

    }

    // MARK: - Run: the person is asked first, and anything but Run starts nothing

    static func runApproval(_ base: URL) async throws {
        let build = ProjectOperation(id: "build", label: "Build the app", kind: "build", command: "sleep 30; echo built", cwd: ".")
        let folder = try project("run", in: base, operations: [build])
        let operationsFile = ProjectOperationsFile.url(root: folder)
        let before = try Data(contentsOf: operationsFile)
        let prompts = ScriptedPrompts()
        let store = ProjectOperationsStore.forRoot(folder, prompts: prompts)
        check(await wait { store.operations.map(\.id) == ["build"] }, "the store reads the operations of the project")

        prompts.script = [.press("Cancel")]
        store.run(id: "build")
        check(await wait { prompts.asked.count == 1 }, "starting an operation asks first")
        let question = prompts.asked[0]
        check(question.title == "Run Build the app?" && question.buttons == ["Cancel", "Run"],
              "with the title and the two buttons it always had, the safe one first (\(question.title) \(question.buttons))")
        check(question.detail.hasPrefix("Command:\nsleep 30; echo built\n\nWorking directory:\n\(folder.path)")
              && question.detail.contains("New or changed since your last run on this machine.") && question.detail.hasSuffix("User-added operation."),
              "that names the command, the folder and what is new about it")
        await settle()
        check(store.runs.isEmpty && store.lastRuns.isEmpty && store.state(id: "build") == nil,
              "Cancel starts no run and keeps no record of one")
        check((try? ProjectOperationHistory.load(root: folder))?.isEmpty == true, "and writes nothing to the run history")

        prompts.script = [.dismiss]
        store.run(id: "build")
        check(await wait { prompts.asked.count == 2 }, "an operation can be started again once the first question is answered")
        await settle()
        check(store.runs.isEmpty, "a window that cannot answer starts no run and waits for nothing")

        store.run(id: "build")
        check(await wait { prompts.asked.count == 3 }, "and a question nobody answers does not block the next start")
        await settle()
        check(store.runs.isEmpty, "a question with no answer left starts nothing either")
        check(try Data(contentsOf: operationsFile) == before, "the operations file is untouched by all three")
        let firstWindow = TestOperationPresenter()
        let secondWindow = TestOperationPresenter()
        store.edit(id: "build", presenter: firstWindow)
        store.edit(id: nil, presenter: secondWindow)
        check(firstWindow.editors.count == 1 && secondWindow.editors.count == 1,
              "shared project routes each editor to the window that requested it")
        prompts.script = [.press("Run")]
        store.run(id: "build", presenter: firstWindow)
        check(await wait { store.runs["build"] != nil }, "approved run starts with its originating window")
        check(firstWindow.consoles == ["build"] && secondWindow.consoles.isEmpty,
              "asynchronous run opens the originating window's console")
        store.run(id: "build", presenter: secondWindow)
        check(secondWindow.consoles == ["build"] && store.runs["build"]?.presenter === firstWindow,
              "another window opens its own console without replacing the run's notification owner")
        store.forceStop(id: "build")
        check(await wait { store.runs["build"]?.isActive == false }, "the test operation is stopped before cleanup")
    }

    // MARK: - Adopt the discovered command

    static func adoptDiscovered(_ base: URL) async throws {
        var deploy = ProjectOperation(id: "deploy", label: "Deploy", kind: "deploy", command: "make deploy-by-hand", cwd: ".",
                                      origin: "discovered", discovered: .init(command: "make deploy", cwd: "."))
        deploy.discoveredFields = deploy.currentFields
        let folder = try project("adopt", in: base, operations: [deploy])
        let prompts = ScriptedPrompts()
        let store = ProjectOperationsStore.forRoot(folder, prompts: prompts)
        check(await wait { store.operations.count == 1 }, "the store reads the operation")

        prompts.script = [.press("Keep current")]
        store.adoptDiscovered(id: "deploy")
        check(prompts.asked.last == UserPrompt(
                title: "Adopt the discovered command?", detail: "Command:\nmake deploy\n\nWorking directory:\n.",
                buttons: ["Keep current", "Adopt discovered"]), "adopting asks what the command would become")
        var commandOnDisk = try stored(folder)[0].command
        check(commandOnDisk == "make deploy-by-hand", "Keep current changes nothing")

        prompts.script = [.dismiss]
        store.adoptDiscovered(id: "deploy")
        commandOnDisk = try stored(folder)[0].command
        check(prompts.asked.count == 2 && commandOnDisk == "make deploy-by-hand", "no answer changes nothing either")

        prompts.script = [.press("Adopt discovered")]
        store.adoptDiscovered(id: "deploy")
        check(await wait { (try? stored(folder)[0].command) == "make deploy" }, "Adopt discovered writes the discovered command to the file")
        check(await wait { store.operations.first?.command == "make deploy" }, "and the store shows it")
    }

    // MARK: - Proposals: accept, keep and reject

    /// The answers of the two discovery rounds that propose one command found on the web.
    static func discoveryAnswers(command: String) -> [[String: Any]] {
        [["operations": [Any](),
          "notDetermined": [["label": "Deploy to production", "kind": "deploy", "environment": "", "reason": "not in the files",
                             "investigated": "README.md"]]],
         ["operations": [["id": "", "label": "Deploy to production", "kind": "deploy", "environment": "", "target": "",
                          "command": command, "cwd": ".", "nodeNames": [Any](), "prerequisites": [Any](),
                          "sources": [["kind": "web", "location": "https://example.com/deploy", "line": 0]],
                          "remoteTrigger": false] as [String: Any]],
          "notDetermined": [Any]()]]
    }

    static func discover(_ store: ProjectOperationsStore, command: String) async -> Bool {
        guard let answers = try? discoveryAnswers(command: command).map({ try JSONSerialization.data(withJSONObject: $0) }) else { return false }
        let scripted = ProjectOperationScriptedResponses(answers)
        let fixture = ProjectOperationDiscoveryService.Fixture(canSearchWeb: true, next: { try await scripted.next() })
        return await ProjectOperationDiscoveryService.$fixture.withValue(fixture) {
            store.discover(nodes: [])
            return await wait { store.discoveryPhase == nil && store.discoveryReport != nil }
        }
    }

    static func proposals(_ base: URL) async throws {
        let folder = try project("proposals", in: base)
        let prompts = ScriptedPrompts()
        let store = ProjectOperationsStore.forRoot(folder, prompts: prompts)
        check(await discover(store, command: "./deploy.sh --prod"), "discovery proposes the command that only the web names")
        check(store.discoveryReport?.proposals.map(\.command) == ["./deploy.sh --prod"] && store.operations.isEmpty,
              "as a proposal, not as an operation")

        prompts.script = [.press("Keep as proposal")]
        store.acceptProposal(index: 0)
        check(prompts.asked.last?.title == "Add externally sourced operation?" && prompts.asked.last?.buttons == ["Keep as proposal", "Accept operation"]
              && prompts.asked.last?.detail.hasPrefix("Deploy to production\n\n./deploy.sh --prod\n\nSource: https://example.com/deploy") == true,
              "accepting asks first, naming the command and where it came from (\(prompts.asked.last?.detail ?? ""))")
        var onDisk = try stored(folder)
        check(store.discoveryReport?.proposals.count == 1 && store.operations.isEmpty && onDisk.isEmpty, "Keep as proposal changes nothing")
        prompts.script = [.dismiss]
        store.acceptProposal(index: 0)
        onDisk = try stored(folder)
        check(store.discoveryReport?.proposals.count == 1 && onDisk.isEmpty, "no answer changes nothing either")

        prompts.script = [.press("Accept operation")]
        store.acceptProposal(index: 0)
        check(store.discoveryReport?.proposals.isEmpty == true, "Accept operation takes the proposal off the list")
        check(await wait { (try? stored(folder).map(\.command)) == ["./deploy.sh --prod"] }, "and writes the operation to the file")

        // Reject: the command is not proposed again on this machine.
        check(await discover(store, command: "./deploy-eu.sh"), "a second discovery proposes another command")
        check(store.discoveryReport?.proposals.map(\.command) == ["./deploy-eu.sh"], "as a proposal")
        prompts.script = [.press("Keep proposal")]
        store.rejectProposal(index: 0)
        check(prompts.asked.last == UserPrompt(
                title: "Reject this proposed command?",
                detail: "./deploy-eu.sh\n\nThe same command will not be proposed again on this machine.", buttons: ["Keep proposal", "Reject"]),
              "rejecting asks first")
        check(store.discoveryReport?.proposals.count == 1, "Keep proposal keeps it")
        prompts.script = [.dismiss]
        store.rejectProposal(index: 0)
        check(store.discoveryReport?.proposals.count == 1, "no answer keeps it too")
        prompts.script = [.press("Reject")]
        store.rejectProposal(index: 0)
        check(store.discoveryReport?.proposals.isEmpty == true, "Reject takes it off the list")
        check(await discover(store, command: "./deploy-eu.sh") && store.discoveryReport?.proposals.isEmpty == true,
              "and a later discovery does not propose the same command again")
    }
}


extension EditorHostTests {
    @MainActor func testProjectOperationsStoreRules() async throws {
        XCTAssertNil(ProjectOperationDiscoveryService.fixture)
        XCTAssertFalse(ProjectOperationsStore.suppressSystemNotifications)
        try await ProjectOperationsStore.$suppressSystemNotifications.withValue(true) {
            try await ProjectOperationsStoreHostChecks.runAll()
        }
    }
}
