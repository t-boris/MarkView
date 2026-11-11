import Foundation

@main
struct QAAPIChecks {
    static var failures = 0
    static var count = 0
    static func check(_ name: String, _ value: Bool) {
        count += 1
        if !value { failures += 1 }
        print("\(value ? "ok" : "FAIL")  \(name)")
    }
    static func rejects(_ name: String, _ operation: () async throws -> Void) async {
        do { try await operation(); check(name, false) }
        catch { check(name, true) }
    }
    final class NoAssistant: QAAssistant {
        var calls = 0
        func decide(system: String, prompt: String, schema: [String: Any]) async throws -> Any? {
            calls += 1
            throw QAAPIError.invalid("Saved API steps must never ask an assistant for their verdict.")
        }
    }
    final class FixtureFactory: QADriverFactory {
        func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
            try QAAPIActor(request: request, credentials: .init(username: "alice", password: "fixture-secret"))
        }
    }
    final class Observer: QARunObserver {
        var events = 0
        func handle(_ event: QARunEvent) { events += 1 }
    }
    static func scenario(_ url: String, nodes: [QANode], edges: [QAEdge]? = nil) -> QAScenario {
        var s = QAScenario(id: "api", title: "API lifecycle", goal: "Verify the API", appKind: .api,
                           apps: [.init(id: "service", name: "API")],
                           targets: [.init(id: "local", kind: .local, name: "Local", locations: ["service": .init(url: url)])],
                           actors: [.init(id: "alice", name: "Alice", app: "service")], nodes: nodes,
                           edges: edges ?? zip(nodes, nodes.dropFirst()).map { .init(from: $0.id, to: $1.id) },
                           start: nodes.first?.id, created: Date(timeIntervalSince1970: 1800000000), updated: Date(timeIntervalSince1970: 1800000000))
        s.selected = s.enumerateBranches().branches.map(\.id)
        return s
    }
    static func node(_ id: String, _ request: QAAPIRequest, kind: QANodeKind = .action) -> QANode {
        QANode(id: id, kind: kind, title: id, detail: "Expected API response", changesData: ["GET", "HEAD", "OPTIONS"].contains(request.method) ? .no : .yes, api: request)
    }
    static func run(_ s: QAScenario, confirm: Bool = true) async -> QARunRecord {
        let plan = QAPlanner.make(s, targetID: "local", savedLogins: [])
        var gate = QAGate(plan: plan)
        check("scenario valid: \(s.title)", plan.canBeApproved)
        gate.approve(acknowledgedProduction: true)
        let assistant = NoAssistant(), observer = Observer()
        let runner = QARunner(scenario: s, plan: plan, gate: gate, factory: FixtureFactory(), assistant: assistant, runID: QAStore.newRunID(at: Date()),
                              confirm: { _ in confirm }, observer: observer)
        let result = await runner.run()
        check("saved requests execute without assistant calls", assistant.calls == 0)
        check("runner emits live events", observer.events > 0)
        return result
    }
    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments[1] == "--export" {
            let folder = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: QAGeneration.schema(for: .api)).write(to: folder.appendingPathComponent("schema.json"))
            try QAGeneration.systemPrompt(.api).write(to: folder.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
            return
        }
        let url = CommandLine.arguments[1]
        let client = try QAAPIClient(address: url, credentials: .init(username: "alice", password: "fixture-secret"))
        defer { client.close() }
        check("JSON pointers escape slash and tilde and index arrays", (QAAPIRequest.value(at: "/a~1b/~0key/0", in: ["a/b": ["~key": [3]]]) as? Int) == 3)
        check("invalid pointers rejected", !QAAPIRequest.validPointer("x") && !QAAPIRequest.validPointer("/~2") && QAAPIRequest.validPointer(""))
        check("noncanonical array indexes rejected", QAAPIRequest.value(at: "/00", in: [1]) == nil)
        check("bad request blocked before network", !QAAPIRequest(method: "TRACE", statuses: []).problems.isEmpty)
        check("header newline rejected", !QAAPIRequest(headers: [.init(name: "X-Test", value: "a\r\nb")]).problems.isEmpty)
        check("malformed assertion JSON rejected", !QAAPIRequest(assertions: [.init(pointer: "/id", equals: "nope")]).problems.isEmpty)
        for path in ["https://example.com", "//example.com/x", "http://localhost:1", "file:///etc/passwd", "http://user:pass@127.0.0.1"] {
            await rejects("origin confinement: \(path)") { _ = try client.resolved(path) }
        }
        let login = QAAPIRequest(method: "POST", path: "/login", body: #"{"username":"{{username}}","password":"{{password}}"}"#,
                                 captures: [.init(name: "token", pointer: "/token", secret: true)])
        let loginResult = try await client.execute(login)
        check("auth placeholders resolved without disclosure", loginResult.passed && !loginResult.evidence.contains("fixture-secret") && !loginResult.evidence.contains("fixture-bearer"))
        check("session cookies retained", try await client.execute(.init(path: "/session", assertions: [.init(pointer: "/signedIn", equals: "true")])).passed)
        let other = try QAAPIClient(address: url)
        check("players have isolated cookies", try await other.execute(.init(path: "/session", statuses: [401])).passed)
        await rejects("players have isolated captures") { _ = try await other.execute(.init(path: "/items", headers: [.init(name: "Authorization", value: "Bearer {{token}}")])) }
        other.close()
        let auth = [QAAPIRequest.Header(name: "Authorization", value: "Bearer {{token}}")]
        let created = try await client.execute(.init(method: "POST", path: "/items", headers: auth, body: #"{"name":"QA item"}"#, statuses: [201],
                                                    assertions: [.init(pointer: "/name", equals: #""QA item""#)], captures: [.init(name: "itemId", pointer: "/id")]))
        check("create with body/header/status/assertion/capture", created.passed)
        check("read captured id", try await client.execute(.init(path: "/items/{{itemId}}", headers: auth, assertions: [.init(pointer: "/name", equals: #""QA item""#)])).passed)
        check("update captured id", try await client.execute(.init(method: "PATCH", path: "/items/{{itemId}}", headers: auth, body: #"{"name":"Updated"}"#, assertions: [.init(pointer: "/name", equals: #""Updated""#)])).passed)
        check("same-response check sends no request", try await client.execute(.init(path: "", assertions: [.init(pointer: "/name", equals: #""Updated""#)])).passed)
        check("delete captured id", try await client.execute(.init(method: "DELETE", path: "/items/{{itemId}}", headers: auth, statuses: [204])).passed)
        check("expected missing record passes", try await client.execute(.init(path: "/items/{{itemId}}", headers: auth, statuses: [404], assertions: [.init(pointer: "/error", equals: #""not found""#)])).passed)
        check("expected validation error passes", try await client.execute(.init(method: "POST", path: "/items", headers: auth, body: "{}", statuses: [422])).passed)
        check("wrong status fails deterministically", try await !client.execute(.init(path: "/types", statuses: [404])).passed)
        check("JSON boolean differs from number", try await !client.execute(.init(path: "/types", assertions: [.init(pointer: "/boolean", equals: "1")])).passed)
        check("null supported", try await client.execute(.init(path: "/types", assertions: [.init(pointer: "/null", equals: "null")])).passed)
        check("missing capture fails", try await !client.execute(.init(path: "/types", captures: [.init(name: "missing", pointer: "/missing")])).passed)
        await rejects("failed capture not committed") { _ = try await client.execute(.init(path: "/{{missing}}")) }
        let escaped = #"{"value":"quoted \"string\""}"#
        _ = try await client.execute(.init(method: "POST", path: "/echo", body: escaped, captures: [.init(name: "escaped", pointer: "/value")]))
        check("JSON interpolation escapes captured strings", try await client.execute(.init(method: "POST", path: "/echo", body: #"{"value":{{escaped.json}}}"#, assertions: [.init(pointer: "/value", equals: #""quoted \"string\"""#)])).passed)
        check("redirect treated as response without following it", try await client.execute(.init(path: "/redirect", statuses: [302])).passed)
        await rejects("response size bounded") { _ = try await client.execute(.init(path: "/large")) }
        await rejects("failed send clears previous response") { _ = try await client.execute(.init(path: "")) }
        await rejects("timeout is a transport failure") { _ = try await client.execute(.init(path: "/slow", timeoutSeconds: 1)) }
        let cancel = Task { try await client.execute(.init(path: "/slow")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancel.cancel()
        do { _ = try await cancel.value; check("cancellation interrupts pending request", false) }
        catch is CancellationError { check("cancellation interrupts pending request", true) }
        catch { check("cancellation interrupts pending request", false) }

        for index in 0..<50 {
            let race = Task { try await client.execute(.init(path: "/types")) }
            if index % 2 == 0 { try await Task.sleep(nanoseconds: 1) }
            race.cancel()
            _ = try? await race.value
        }
        check("repeated cancellation during request creation does not hang", true)

        // No credentials stored in this scenario: anonymous auth gets an expected rejection, followed by a normal JSON check.
        let good = scenario(url, nodes: [node("reject", .init(path: "/items", statuses: [401])), node("verify", .init(path: "/types", assertions: [.init(pointer: "/boolean", equals: "true")]), kind: .check)])
        let passed = await run(good)
        check("saved scenario passes real runner", passed.count(.passed) == 1 && passed.timeline.contains { $0.text.contains("HTTP 401") })
        check("saved scenario replays", await run(good).count(.passed) == 1)
        var multiService = scenario(url, nodes: [
            node("login", .init(method: "POST", path: "/login", body: #"{"username":"{{username}}","password":"{{password}}"}"#)),
            node("other", .init(path: "/session", statuses: [401]), kind: .check),
            node("original", .init(path: "/session", assertions: [.init(pointer: "/signedIn", equals: "true")]), kind: .check)
        ])
        multiService.apps.append(.init(id: "other", name: "Other service"))
        multiService.targets[0].locations["other"] = .init(url: url)
        multiService.nodes[1].app = "other"
        check("one player's sessions stay separated by service", await run(multiService).count(.passed) == 1)
        let branches = scenario(url, nodes: [
            QANode(id: "fork", kind: .alternative, title: "Choose flow", changesData: .no),
            node("login", .init(method: "POST", path: "/login", body: #"{"username":"{{username}}","password":"{{password}}"}"#)),
            node("signed", .init(path: "/session"), kind: .check),
            node("fresh", .init(path: "/session", statuses: [401]), kind: .check)
        ], edges: [.init(from: "fork", to: "login"), .init(from: "login", to: "signed"), .init(from: "fork", to: "fresh")])
        check("each branch starts with fresh cookies and variables", await run(branches).count(.passed) == 2)
        let once = scenario(url, nodes: [node("write", .init(method: "POST", path: "/write-once", statuses: [200]))])
        check("failed write response fails without retry", await run(once).count(.failed) == 1)
        check("mutating request sent exactly once", try await client.execute(.init(path: "/stats", assertions: [.init(pointer: "/writes", equals: "1")])).passed)
        let limit = scenario(url, nodes: [node("large", .init(path: "/large"))])
        check("response limit blocks rather than interrupts the branch", await run(limit).count(.blocked) == 1)
        var bad = good; bad.nodes[1].api?.assertions[0].equals = "false"
        check("false response assertion produces failed branch", await run(bad).count(.failed) == 1)
        var missing = good; missing.nodes[0].api?.path = "/{{unknown}}"
        check("missing variable produces blocked branch", await run(missing).count(.blocked) == 1)
        var production = scenario(url, nodes: [node("write", .init(method: "POST", path: "/echo", body: "{}"))])
        production.targets[0].kind = .production
        check("refused production write blocked", await run(production, confirm: false).count(.blocked) == 1)
        var readonly = production; readonly.nodes[0].changesData = .no
        check("write cannot bypass production gate as read-only", !readonly.problems().isEmpty)
        var checkWrite = production; checkWrite.nodes[0].kind = .check
        check("write cannot bypass production gate as check", !checkWrite.problems().isEmpty)
        var incomplete = good; incomplete.nodes[0].api = nil
        check("missing executable request blocks approval", !QAPlanner.make(incomplete, targetID: "local", savedLogins: []).canBeApproved)
        var changed = good; changed.nodes[0].api?.statuses = [200]
        check("request changes invalidate approval fingerprint", QAPlanner.fingerprint(good, target: good.targets[0], branches: good.selectedBranches().found) != QAPlanner.fingerprint(changed, target: changed.targets[0], branches: changed.selectedBranches().found))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try QAStore.saveScenario(good, root: folder)
        let roundtrip = try QAStore.decoder.decode(QAScenario.self, from: QAStore.encoder.encode(good))
        check("request scenario persists exactly", roundtrip == good)
        try QAStore.saveRun(passed, root: folder)
        let report = try QAStore.decoder.decode(QARunRecord.self, from: QAStore.encoder.encode(passed))
        check("response evidence survives archive", report.timeline == passed.timeline)

        let genRequest = QAGenerationRequest(goal: "Test the backend", appKind: .api, apps: good.apps, targets: good.targets)
        let object: [String: Any] = ["title": "Generated", "start": "get", "actors": [["id": "alice", "name": "Alice", "app": "service", "createTestAccount": false]],
                                    "nodes": [["id": "get", "kind": "check", "title": "Get types", "detail": "Boolean is true", "changesData": "no", "api": QAAPIRequest(path: "/types").source]], "edges": []]
        let generated = QAGeneration.parse(object, request: genRequest)
        check("generator parses executable HTTP steps", generated.isClean && generated.scenario.nodes.first?.api?.path == "/types")
        let fields = (((QAGeneration.schema(for: .api)["properties"] as? [String: Any])?["nodes"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any]
        check("API generation schema includes request source", fields?["api"] != nil)
        check("API prompt grounds proposals in source and auth contract", QAGeneration.systemPrompt(.api).contains("OpenAPI") && QAGeneration.systemPrompt(.api).contains("secret=true"))
        let legacy = #"{"id":"n","kind":"check","title":"Check","detail":"Expected","changesData":"no"}"#
        check("old web/native nodes load without API field", try JSONDecoder().decode(QANode.self, from: Data(legacy.utf8)).api == nil)
        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let structured = try JSONSerialization.jsonObject(with: data)
            let proposal = QAGeneration.parse(structured, request: genRequest)
            check("real assistant proposal validates", proposal.isClean)
            if proposal.isClean {
                var scenario = proposal.scenario
                scenario.selected = scenario.enumerateBranches().branches.map(\.id)
                let result = await run(scenario)
                check("real assistant scenario executes all proposed branches", result.results.allSatisfy { $0.verdict.outcome == .passed })
            } else { print(proposal.messages.joined(separator: "\n")) }
        }
        print("\(count) API checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
