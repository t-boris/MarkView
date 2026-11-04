// Checks the pure modules of UI Studio (MarkView/Models/UIStudio*.swift): the simulation engine, rule validation,
// bounded preparation, redaction, bridge validation, the change manager with selective undo, code revision identity,
// scenarios and their compatibility, image comparison and feature packages. Run by tools/tests/ui-studio-tests.sh.
import CoreGraphics
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("ok  \(name)") } else {
        failures += 1
        let more = detail()
        print("FAIL \(name)" + (more.isEmpty ? "" : "\n     \(more)"))
    }
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-tests-\(UUID().uuidString)")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

// MARK: - Reference environment (§13: projects with list, details, create, rename, delete)

func project(_ id: Int, _ name: String, _ status: String = "active") -> StudioJSON {
    .object(["id": .number(Double(id)), "name": .string(name), "status": .string(status)])
}
var spec = StudioEnvironmentSpec()
spec.entities = [
    StudioEntity(name: "projects", fields: [StudioField(name: "name", type: "string", required: true),
                                             StudioField(name: "status", type: "string", required: true, enumValues: ["active", "archived"])]),
    StudioEntity(name: "tasks", fields: [StudioField(name: "title", type: "string", required: true),
                                          StudioField(name: "projectId", type: "integer", required: true, references: "projects")]),
]
spec.seed = [
    "projects": [project(1, "Apollo"), project(2, "Gemini"), project(3, "Mercury", "archived")],
    "tasks": [.object(["id": .number(10), "title": .string("Design"), "projectId": .number(1)]),
              .object(["id": .number(11), "title": .string("Build"), "projectId": .number(1)])],
]
spec.rules = [
    StudioRule(id: "list-projects", method: "GET", path: "/api/projects", operation: .list, entity: "projects", filters: ["status"]),
    StudioRule(id: "get-project", method: "GET", path: "/api/projects/:id", operation: .get, entity: "projects",
               include: [StudioInclude(field: "tasks", entity: "tasks", foreignKey: "projectId")]),
    StudioRule(id: "create-project", method: "POST", path: "/api/projects", operation: .create, entity: "projects"),
    StudioRule(id: "rename-project", method: "PATCH", path: "/api/projects/:id", operation: .update, entity: "projects"),
    StudioRule(id: "delete-project", method: "DELETE", path: "/api/projects/:id", operation: .delete, entity: "projects"),
    StudioRule(id: "me", method: "GET", path: "/api/me", operation: .session),
]
let app = "http://localhost:5173"
var requestCounter = 0
func request(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:], id: String? = nil) -> StudioHTTPRequest {
    requestCounter += 1
    return StudioHTTPRequest(method: method, url: URL(string: app + path)!, headers: headers, body: body, requestId: id ?? "r\(requestCounter)")
}
func answer(_ outcome: StudioSimOutcome) -> (Int, StudioJSON?) {
    guard case .respond(let response, _) = outcome else { return (-1, nil) }
    return (response.status, response.body.flatMap { StudioJSON(text: $0) })
}

var base = StudioScenario(id: "populated", name: "Populated", kind: .populated)
var sim = StudioSimulator(spec: spec, scenario: base, appOrigin: app)

// MARK: Simulation (SIM-01…SIM-04, AC-01…AC-04)

let list = answer(sim.handle(request("GET", "/api/projects")))
check("AC-01 list answers prepared data without a backend", list.0 == 200 && list.1?.arrayValue?.count == 3)
let detail = answer(sim.handle(request("GET", "/api/projects/1")))
check("AC-02 detail matches the list", detail.1?["name"] == list.1?.arrayValue?.first?["name"])
check("AC-02 detail includes related records from the same state", detail.1?["tasks"]?.arrayValue?.count == 2)
check("list filters by query", answer(sim.handle(request("GET", "/api/projects?status=archived"))).1?.arrayValue?.count == 1)
check("literal route beats parameter", StudioRoute.specificity("/api/projects/archived") > StudioRoute.specificity("/api/projects/:id"))

let renamed = answer(sim.handle(request("PATCH", "/api/projects/2", body: #"{"name":"Gemini II"}"#)))
check("AC-03 rename answers the record", renamed.0 == 200 && renamed.1?["name"]?.stringValue == "Gemini II" && renamed.1?["status"]?.stringValue == "active")
check("AC-03 later list reads the rename", answer(sim.handle(request("GET", "/api/projects"))).1?.arrayValue?.contains { $0["name"]?.stringValue == "Gemini II" } == true)
check("AC-03 later detail reads the rename", answer(sim.handle(request("GET", "/api/projects/2"))).1?["name"]?.stringValue == "Gemini II")
let deleted = answer(sim.handle(request("DELETE", "/api/projects/3")))
check("AC-03 delete answers 204", deleted.0 == 204)
check("AC-03 deleted record is gone from list and detail", answer(sim.handle(request("GET", "/api/projects"))).1?.arrayValue?.count == 2
      && answer(sim.handle(request("GET", "/api/projects/3"))).0 == 404)
let created = answer(sim.handle(request("POST", "/api/projects", body: #"{"name":"Vostok","status":"active"}"#)))
check("create assigns the next integer id", created.0 == 201 && created.1?["id"]?.identityKey == "4")
let invalid = answer(sim.handle(request("POST", "/api/projects", body: #"{"name":"Bad","status":"deleted"}"#)))
check("create validates enumerations (422) without changing state", invalid.0 == 422 && sim.state["projects"]?.count == 3)
let badTask = answer(sim.handle(request("POST", "/api/projects", body: #"{"status":"active"}"#)))
check("create validates required fields", badTask.0 == 422)

// AC-08: the same idempotency key (or request id) applies a write once.
let first = answer(sim.handle(request("POST", "/api/projects", body: #"{"name":"Soyuz","status":"active"}"#, headers: ["idempotency-key": "k-1"])))
let again = answer(sim.handle(request("POST", "/api/projects", body: #"{"name":"Soyuz","status":"active"}"#, headers: ["idempotency-key": "k-1"])))
check("AC-08 a repeated write with the same key does not duplicate", first.1 == again.1 && sim.state["projects"]?.filter { $0["name"]?.stringValue == "Soyuz" }.count == 1)
_ = sim.handle(request("POST", "/api/projects", body: #"{"name":"Voskhod","status":"active"}"#, id: "same-call"))
_ = sim.handle(request("POST", "/api/projects", body: #"{"name":"Voskhod","status":"active"}"#, id: "same-call"))
check("AC-08 a request delivered twice (same request id) applies once", sim.state["projects"]?.filter { $0["name"]?.stringValue == "Voskhod" }.count == 1)

let generation = sim.generation
sim.reset()
check("AC-04 Reset restores the baseline data", sim.state["projects"]?.count == 3 && answer(sim.handle(request("GET", "/api/projects/2"))).1?["name"]?.stringValue == "Gemini")
check("Reset starts a new generation and clears the journal", sim.generation == generation + 1 && sim.journal.isEmpty)
check("session rule answers the test user with test credentials", answer(sim.handle(request("GET", "/api/me"))).1?["token"]?.stringValue == "markview-test-token")

// Unknown and unsupported requests never reach a real service.
if case .unknown(let contract) = sim.handle(request("GET", "/api/projects/7/members")) {
    check("unknown request reports its contract with ids normalised", contract == "GET /api/projects/:id/members", contract)
} else { check("unknown request is unknown", false) }
if case .unknown(let contract) = sim.handle(StudioHTTPRequest(method: "GET", url: URL(string: "https://api.example.com/v1/users/42")!, requestId: "x1")) {
    check("cross-origin unknown request keeps its origin in the contract", contract == "GET https://api.example.com/v1/users/:id", contract)
} else { check("cross-origin unknown", false) }
if case .unsupported(_, let reason) = sim.handle(request("POST", "/graphql", body: #"{"query":"query { me { id } }"}"#)) {
    check("GraphQL is unsupported, not prepared", reason.contains("GraphQL"))
} else { check("GraphQL is unsupported", false) }
let unresolved = StudioSimResponse.unresolved("GET /api/x", reason: "the agent did not finish in time.")
check("AC-06 controlled error names the contract and that nothing reached a real service",
      unresolved.status == 503 && unresolved.headers["x-markview-simulation"] == "unresolved" && (unresolved.body ?? "").contains("did not reach any real service"))
check("contract keys normalise uuids and slugs", StudioRoute.contractKey(method: "get", url: URL(string: app + "/api/t/3f2504e0-4f89-11d3-9a0c-0305e82c3301/c/abc-12")!, appOrigin: app) == "GET /api/t/:id/c/:id")
check("allowed request pattern on the app origin", StudioRoute.allows("/locales/*", url: URL(string: app + "/locales/en.json")!, appOrigin: app))
check("allowed request pattern for another origin", StudioRoute.allows("https://fonts.googleapis.com/*", url: URL(string: "https://fonts.googleapis.com/css2?family=Inter")!, appOrigin: app)
      && !StudioRoute.allows("https://fonts.googleapis.com/*", url: URL(string: "https://evil.example/fonts.googleapis.com/")!, appOrigin: app))

// AC-16: empty, loading and error states without touching production code.
var emptyScenario = base; emptyScenario.overrides = [StudioOverride(ruleId: "list-projects", empty: true)]
sim.activate(emptyScenario)
check("AC-16 empty state answers an empty list", answer(sim.handle(request("GET", "/api/projects"))).1?.arrayValue?.isEmpty == true)
var errorScenario = base; errorScenario.overrides = [StudioOverride(ruleId: "list-projects", status: 500)]
sim.activate(errorScenario)
check("AC-16 error state answers 500", answer(sim.handle(request("GET", "/api/projects"))).0 == 500)
var loadingScenario = base; loadingScenario.overrides = [StudioOverride(ruleId: "list-projects", hang: true)]
sim.activate(loadingScenario)
if case .respond(let response, _) = sim.handle(request("GET", "/api/projects")) { check("AC-16 loading state keeps the request pending", response.hang) }
var slowScenario = base; slowScenario.overrides = [StudioOverride(ruleId: "get-project", delayMs: 1500)]
sim.activate(slowScenario)
if case .respond(let response, _) = sim.handle(request("GET", "/api/projects/1")) { check("SIM-11 delay is configured, independent of a model", response.delayMs == 1500 && response.status == 200) }
sim.activate(base)

// Registration (SIM-06): atomic, validated.
var proposal = StudioProposal()
proposal.entities = [StudioEntity(name: "members", fields: [StudioField(name: "projectId", type: "integer", required: true, references: "projects"),
                                                             StudioField(name: "name", type: "string", required: true)])]
proposal.records = ["members": [.object(["id": .string("m-1"), "projectId": .number(1), "name": .string("Ann")]),
                                .object(["id": .string("m-2"), "projectId": .number(99), "name": .string("Bob")])]]
proposal.rules = [StudioRule(id: "list-members", method: "GET", path: "/api/projects/:projectId/members", operation: .list, entity: "members")]
let before = sim.spec
let refused = sim.register(proposal)
check("invalid proposal (dangling reference) is refused", refused.contains { $0.contains("does not exist") }, refused.joined(separator: "; "))
check("refused proposal leaves rules, entities and state unchanged", sim.spec == before && sim.state["members"] == nil)
proposal.records["members"] = [proposal.records["members"]![0]]
check("valid proposal registers at once", sim.register(proposal).isEmpty && sim.spec.rules.count == before.rules.count + 1)
check("registered rule serves the request without a model", answer(sim.handle(request("GET", "/api/projects/1/members"))).1?.arrayValue?.count == 1)
var duplicate = StudioProposal(); duplicate.rules = [StudioRule(id: "dup", method: "GET", path: "/api/projects", operation: .list, entity: "projects")]
check("a rule for an existing route is refused", !sim.register(duplicate).isEmpty)
var codeLike = StudioProposal(); codeLike.rules = [StudioRule(id: "evil", method: "GET", path: "/api/../etc", operation: .respond, response: StudioFixedResponse(status: 200, body: .null))]
check("a path with .. is refused", !sim.register(codeLike).isEmpty)

// MARK: - Bounded preparation (SIM-07…SIM-10, AC-05…AC-07)

final class StubPreparer: StudioRulePreparing, @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    let delay: UInt64
    let make: @Sendable (StudioPreparationContext) -> StudioProposal
    init(delay: UInt64 = 50_000_000, make: @escaping @Sendable (StudioPreparationContext) -> StudioProposal) { self.delay = delay; self.make = make }
    func prepare(_ context: StudioPreparationContext) async throws -> StudioProposal {
        lock.withLock { calls += 1 }
        try await Task.sleep(nanoseconds: delay)
        return make(context)
    }
}

func context(_ contract: String) -> StudioPreparationContext {
    StudioPreparationContext(contract: contract, method: "GET", url: app + "/api/labels", headers: [:], body: nil, attempt: 1, problems: [])
}
let labels: @Sendable (StudioPreparationContext) -> StudioProposal = { _ in
    var p = StudioProposal()
    p.entities = [StudioEntity(name: "labels", fields: [StudioField(name: "name", type: "string", required: true)])]
    p.records = ["labels": [.object(["id": .number(1), "name": .string("urgent")])]]
    p.rules = [StudioRule(id: "list-labels", method: "GET", path: "/api/labels", operation: .list, entity: "labels")]
    return p
}

@MainActor
func preparationChecks() async {
    var simulator = StudioSimulator(spec: spec, scenario: base, appOrigin: app)
    // AC-05: concurrent identical unknown requests share one preparation; the rule is registered; a repeat calls no model.
    let queue = StudioPreparationQueue()
    let preparer = StubPreparer(make: labels)
    let generation = simulator.generation
    async let one = queue.resolve(context("GET /api/labels"), generation: generation, preparer: preparer,
                                  currentGeneration: { generation }, commit: { simulator.register($0) })
    async let two = queue.resolve(context("GET /api/labels"), generation: generation, preparer: preparer,
                                  currentGeneration: { generation }, commit: { simulator.register($0) })
    let (a, b) = await (one, two)
    check("AC-05 concurrent identical requests prepare once", preparer.calls == 1 && a == b, "calls \(preparer.calls)")
    check("AC-05 the prepared rule is registered", a == .registered(rules: ["list-labels"]))
    let calls = queue.modelCalls
    check("AC-05 a repeated request is served without a model call",
          answer(simulator.handle(request("GET", "/api/labels"))).1?.arrayValue?.count == 1 && queue.modelCalls == calls)

    // AC-06: an invalid answer is retried once, then a controlled failure without partial state.
    let badQueue = StudioPreparationQueue()
    let bad = StubPreparer { _ in var p = StudioProposal(); p.rules = [StudioRule(id: "x", method: "GET", path: "/api/x", operation: .list, entity: "nothing")]; return p }
    let snapshot = simulator.spec
    let badOutcome = await badQueue.resolve(context("GET /api/x"), generation: generation, preparer: bad,
                                            currentGeneration: { generation }, commit: { simulator.register($0) })
    if case .failed = badOutcome { check("AC-06 invalid format fails after two attempts", bad.calls == 2, "calls \(bad.calls)") }
    else { check("AC-06 invalid format fails", false, "\(badOutcome)") }
    check("AC-06 nothing was registered", simulator.spec == snapshot)
    let again = await badQueue.resolve(context("GET /api/x"), generation: generation, preparer: bad,
                                       currentGeneration: { generation }, commit: { simulator.register($0) })
    check("a failed contract is not prepared again until Retry", bad.calls == 2 && again != .registered(rules: []))

    // AC-06: the agent does not finish in time.
    let slowQueue = StudioPreparationQueue(limits: StudioPreparationLimits(deadline: 0.3, maxAttempts: 2, maxConcurrent: 2, maxContracts: 40))
    let slow = StubPreparer(delay: 2_000_000_000, make: labels)
    let started = Date()
    let timedOut = await slowQueue.resolve(context("GET /api/slow"), generation: generation, preparer: slow,
                                           currentGeneration: { generation }, commit: { simulator.register($0) })
    check("AC-06 a late agent ends in a timeout", timedOut == .timedOut && Date().timeIntervalSince(started) < 1.5, "\(timedOut)")
    check("AC-06 the timeout changed nothing", simulator.spec == snapshot)

    // AC-07: cancel the preparation and switch the scenario; the late answer does not change the new scenario.
    var current = generation
    let cancelQueue = StudioPreparationQueue()
    let late = StubPreparer(delay: 400_000_000, make: labels)
    var fresh = StudioSimulator(spec: spec, scenario: base, appOrigin: app)
    let pending = Task { @MainActor in
        await cancelQueue.resolve(context("GET /api/labels"), generation: current, preparer: late,
                                  currentGeneration: { current }, commit: { fresh.register($0) })
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    fresh.activate(emptyScenario)
    current = fresh.generation
    cancelQueue.cancelAll()
    let cancelled = await pending.value
    check("AC-07 cancelled preparation reports cancelled or stale", cancelled == .cancelled || cancelled == .stale, "\(cancelled)")
    try? await Task.sleep(nanoseconds: 500_000_000)
    check("AC-07 the late answer did not register a rule", fresh.spec.rules.count == spec.rules.count)

    // A generation change without cancel (Reset while the agent works) also drops the answer.
    var gen2 = 1
    let staleQueue = StudioPreparationQueue()
    var other = StudioSimulator(spec: spec, scenario: base, appOrigin: app)
    let pending2 = Task { @MainActor in
        await staleQueue.resolve(context("GET /api/labels"), generation: 1, preparer: StubPreparer(delay: 200_000_000, make: labels),
                                 currentGeneration: { gen2 }, commit: { other.register($0) })
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    gen2 = 2
    let staleOutcome = await pending2.value
    check("SIM-10 a result of an old generation is dropped", staleOutcome == .stale && other.spec.rules.count == spec.rules.count, "\(staleOutcome)")

    // Concurrency and budget bounds.
    let bounded = StudioPreparationQueue(limits: StudioPreparationLimits(deadline: 5, maxAttempts: 1, maxConcurrent: 1, maxContracts: 2))
    let counter = StubPreparer(delay: 100_000_000) { context in
        var p = StudioProposal(); p.unsupported = true; p.reason = "needs a WebSocket (\(context.contract))"; return p
    }
    let t0 = Date()
    async let x = bounded.resolve(context("GET /a"), generation: 1, preparer: counter, currentGeneration: { 1 }, commit: { _ in [] })
    async let y = bounded.resolve(context("GET /b"), generation: 1, preparer: counter, currentGeneration: { 1 }, commit: { _ in [] })
    let (rx, ry) = await (x, y)
    check("one preparation at a time when the limit is 1", Date().timeIntervalSince(t0) >= 0.19, "\(Date().timeIntervalSince(t0))")
    if case .unsupported = rx, case .unsupported = ry { check("an unsupported dependency is reported, not registered", true) } else { check("unsupported reported", false) }
    let over = await bounded.resolve(context("GET /c"), generation: 1, preparer: counter, currentGeneration: { 1 }, commit: { _ in [] })
    check("the preparation budget is bounded", over == .limitReached)
}

// MARK: - Redaction and environment (REQ-006)

let redactor = StudioRedactor()
let secretBody = StudioJSON(text: #"{"user":"ann","password":"hunter2","profile":{"apiKey":"abc123","bio":"token=ghp_abcdefghijklmnopqrstuvwxyz123456"}}"#)!
let redacted = redactor.redact(secretBody)
check("confidential fields are redacted at any depth", redacted["password"]?.stringValue == "[redacted]" && redacted["profile"]?["apiKey"]?.stringValue == "[redacted]")
check("credential shapes in text are redacted", !(redacted["profile"]?["bio"]?.stringValue ?? "").contains("ghp_"))
check("ordinary fields stay", redacted["user"]?.stringValue == "ann")
check("confidential headers are redacted", redactor.redact(headers: ["Authorization": "Bearer x", "Accept": "json"])["Authorization"] == "[redacted]")
check("JWTs and keys in free text", !redactor.redact(text: "header eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U and sk-ant-REDACTEDREDACTED123456").contains("eyJhbGci"))
check("name=value pairs of confidential names", redactor.redact(text: "?access_token=s3cr3tvalue&x=1").contains("[redacted]"))
let env = StudioRedactor.sanitizedEnvironment(["PATH": "/usr/bin", "HOME": "/Users/x", "GITHUB_TOKEN": "t", "OPENAI_API_KEY": "k",
                                               "DATABASE_URL": "postgres://", "STRIPE_SECRET": "s", "NODE_ENV": "development", "AWS_PROFILE": "prod"])
check("production secrets are not inherited by the app process", env.environment["GITHUB_TOKEN"] == nil && env.environment["OPENAI_API_KEY"] == nil
      && env.environment["DATABASE_URL"] == nil && env.environment["AWS_PROFILE"] == nil && env.environment["PATH"] == "/usr/bin" && env.environment["NODE_ENV"] == "development")
check("removed variables are named, never their values", env.removed.contains("GITHUB_TOKEN") && !env.removed.contains("t"))

// MARK: - Bridge validation (REQ-006)

let origin = StudioBridge.Origin(url: URL(string: app)!)!
let expectation = StudioBridge.Expectation(session: "s-1", generation: 3, origin: origin)
let good: [String: Any] = ["kind": "request", "session": "s-1", "generation": 3, "requestId": "r-1", "method": "get",
                           "url": app + "/api/projects", "headers": ["Accept": "application/json"], "body": NSNull(), "transport": "fetch"]
if case .success(.request(let parsed)) = StudioBridge.validate(good, isMainFrame: true, origin: origin, expecting: expectation) {
    check("a valid request message is accepted", parsed.method == "GET" && parsed.headers["accept"] == "application/json")
} else { check("valid request accepted", false) }
check("localhost and 127.0.0.1 are the same server", StudioBridge.Origin(scheme: "http", host: "127.0.0.1", port: 5173).sameServer(origin))
check("a subframe is rejected", StudioBridge.validate(good, isMainFrame: false, origin: origin, expecting: expectation) == .failure(.notMainFrame))
let foreign = StudioBridge.Origin(url: URL(string: "https://evil.example")!)!
if case .failure(.wrongOrigin) = StudioBridge.validate(good, isMainFrame: true, origin: foreign, expecting: expectation) { check("another origin is rejected", true) } else { check("another origin is rejected", false) }
var otherSession = good; otherSession["session"] = "s-2"
check("another session is rejected", StudioBridge.validate(otherSession, isMainFrame: true, origin: origin, expecting: expectation) == .failure(.wrongSession))
var stale = good; stale["generation"] = 2
check("a stale generation (after Reset) is rejected", StudioBridge.validate(stale, isMainFrame: true, origin: origin, expecting: expectation) == .failure(.stale(2)))
var badURL = good; badURL["url"] = "file:///etc/passwd"
if case .failure(.malformed) = StudioBridge.validate(badURL, isMainFrame: true, origin: origin, expecting: expectation) { check("a non-http url is malformed", true) } else { check("non-http url", false) }
var hugeBody = good; hugeBody["body"] = String(repeating: "x", count: StudioBridge.maxBody + 1)
if case .failure(.malformed) = StudioBridge.validate(hugeBody, isMainFrame: true, origin: origin, expecting: expectation) { check("an oversized body is malformed", true) } else { check("oversized body", false) }
let event: [String: Any] = ["kind": "event", "session": "s-1", "generation": 3, "type": "electron", "detail": "window.api.load()"]
if case .success(.event(let parsed)) = StudioBridge.validate(event, isMainFrame: true, origin: origin, expecting: expectation) { check("an event is accepted", parsed.kind == .electron) } else { check("event accepted", false) }

// MARK: - Change manager (EDIT-05…EDIT-07, AC-12…AC-14)

func shell(_ command: String, in folder: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run(); process.waitUntilExit()
}
let repo = tmp.appendingPathComponent("app")
try! fm.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
let card = """
    export function Card({ title }) {
      return (
        <div className="card" style={{ padding: 8 }}>
          <h3>{title}</h3>
        </div>
      );
    }

    export const footer = 'Made with care';
    """
try! card.write(to: repo.appendingPathComponent("src/Card.jsx"), atomically: true, encoding: .utf8)
try! "body { margin: 0; }\n".write(to: repo.appendingPathComponent("src/app.css"), atomically: true, encoding: .utf8)
shell("git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm init", in: repo)

func read(_ path: String) -> String { (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? "<missing>" }

func changeChecks() async {
    let (rev1, snapshot) = await StudioRevisionProbe.compute(root: repo)
    check("revision of a clean tree names the commit", rev1.head != nil && rev1.changedFiles == 0)
    let edits = [StudioEdit(path: "src/Card.jsx", search: "style={{ padding: 8 }}", replace: "style={{ padding: 16 }}"),
                 StudioEdit(path: "src/Card.jsx", search: "<h3>{title}</h3>", replace: "<h3 className=\"title\">{title}</h3>")]
    do {
        let changes = try await StudioChanges.plan(edits, snapshot: snapshot)
        check("plan combines edits of one file", changes.count == 1 && changes[0].after?.contains("padding: 16") == true && changes[0].after?.contains("className=\"title\"") == true)
        try StudioChanges.write(changes, root: repo)
        check("AC-12 the source file changed on disk", read("src/Card.jsx").contains("padding: 16"))
        let patch = await StudioChanges.unifiedDiff(changes)
        check("the patch is a unified diff of the change", patch.contains("--- a/src/Card.jsx") && patch.contains("+    <div className=\"card\" style={{ padding: 16 }}>"), patch)

        // AC-14: an independent later edit survives the undo of the AI change.
        let independent = read("src/Card.jsx").replacingOccurrences(of: "Made with care", with: "Made with love")
        try! independent.write(to: repo.appendingPathComponent("src/Card.jsx"), atomically: true, encoding: .utf8)
        let undo = await StudioChanges.undoPlan(changes[0], root: repo)
        if case .clean(_, let text) = undo {
            check("AC-14 undo removes the AI change", text?.contains("padding: 8") == true && text?.contains("<h3>{title}</h3>") == true)
            check("AC-14 undo keeps the independent edit", text?.contains("Made with love") == true)
        } else { check("AC-14 undo is clean", false, "\(undo)") }

        // An overlapping later edit becomes a conflict, not a rollback.
        let overlapping = read("src/Card.jsx").replacingOccurrences(of: "padding: 16", with: "padding: 24")
        try! overlapping.write(to: repo.appendingPathComponent("src/Card.jsx"), atomically: true, encoding: .utf8)
        if case .conflict(_, let merged, let hunks) = await StudioChanges.undoPlan(changes[0], root: repo) {
            check("an overlapping edit makes the undo a conflict with markers", hunks >= 1 && merged.contains("<<<<<<<"))
        } else { check("overlapping undo conflicts", false) }
        check("the conflict wrote nothing", read("src/Card.jsx").contains("padding: 24"))
    } catch { check("plan and write", false, "\(error)") }

    // AC-13: a file changed by hand while the assistant worked is a conflict; the hand edit is kept.
    let (_, start) = await StudioRevisionProbe.compute(root: repo)
    try! "body { margin: 4px; }\n".write(to: repo.appendingPathComponent("src/app.css"), atomically: true, encoding: .utf8)
    do {
        _ = try await StudioChanges.plan([StudioEdit(path: "src/app.css", search: "margin: 4px", replace: "margin: 0")], snapshot: start)
        check("AC-13 a concurrent manual change is detected", false)
    } catch StudioChangeError.conflict(let paths) {
        check("AC-13 a concurrent manual change is detected", paths == ["src/app.css"])
        check("AC-13 the manual change is not lost", read("src/app.css").contains("margin: 4px"))
    } catch { check("AC-13 conflict", false, "\(error)") }

    // An unsaved editor buffer counts as a change (applied editor buffers, EDIT-05).
    let (rev2, withBuffer) = await StudioRevisionProbe.compute(root: repo, editorBuffers: ["src/app.css": "body {}"])
    check("unsaved editor buffers change the revision", rev2.editorBuffers == 1 && rev2.id != rev1.id)
    do {
        _ = try await StudioChanges.plan([StudioEdit(path: "src/app.css", search: "margin: 4px", replace: "margin: 1px")], snapshot: withBuffer)
        check("an unsaved buffer is a conflict", false)
    } catch StudioChangeError.conflict { check("an unsaved buffer is a conflict", true) } catch { check("unsaved buffer", false, "\(error)") }

    let (rev3, fresh) = await StudioRevisionProbe.compute(root: repo)
    check("uncommitted changes are part of the revision", rev3.changedFiles >= 1 && rev3.id != rev1.id)
    do {
        _ = try await StudioChanges.plan([StudioEdit(path: "src/app.css", search: "nothing like this", replace: "x")], snapshot: fresh)
        check("missing search text fails", false)
    } catch StudioChangeError.notFound { check("missing search text fails", true) } catch { check("missing search", false, "\(error)") }
    do {
        _ = try await StudioChanges.plan([StudioEdit(path: "src/app.css", search: " ", replace: "  ")], snapshot: fresh)
        check("ambiguous search text fails", false)
    } catch StudioChangeError.ambiguous { check("ambiguous search text fails", true) } catch { check("ambiguous search", false, "\(error)") }

    for bad in ["../outside.css", "/etc/hosts", "node_modules/x/index.js", ".git/config", ".markview/studio/environment.json", "src/logo.png"] {
        check("path refused: \(bad)", StudioChanges.validatedURL(bad, root: repo) == nil)
    }
    try? fm.createSymbolicLink(at: repo.appendingPathComponent("link"), withDestinationURL: tmp)
    check("a symlink leading outside the project is refused", StudioChanges.validatedURL("link/escape.css", root: repo) == nil)
    check("a new file inside src is allowed", StudioChanges.validatedURL("src/new/Badge.css", root: repo) != nil)

    // Atomic writes: a failing file puts the earlier ones back.
    let good = StudioFileChange(path: "src/app.css", before: read("src/app.css"), after: "body { color: red; }\n")
    let failing = StudioFileChange(path: "../x.css", before: nil, after: "x")
    do { try StudioChanges.write([good, failing], root: repo); check("a failing write throws", false) } catch {
        check("a failing write puts earlier files back", read("src/app.css") == good.before)
    }
    // A created file: undo removes it only while it is unchanged.
    let createdFile = StudioFileChange(path: "src/Badge.css", before: nil, after: ".badge {}\n")
    try? StudioChanges.write([createdFile], root: repo)
    if case .clean(_, let text) = await StudioChanges.undoPlan(createdFile, root: repo) { check("undo of a created file removes it", text == nil) } else { check("undo created", false) }
}

// MARK: - Scenarios and compatibility (SCN-01…SCN-04)

func scenarioChecks() {
    let root = tmp.appendingPathComponent("store")
    var scenario = StudioScenario(id: "Long names!", name: "Long names", kind: .custom, route: "/projects")
    scenario.data = ["projects": [project(1, String(repeating: "Very long project name ", count: 4))]]
    scenario.steps = [StudioStep(action: .click, selector: "li.project:nth-of-type(1) > a")]
    scenario.contractFingerprint = StudioScenarioCompatibility.fingerprint(scenario, spec: spec)
    scenario.updated = Date(timeIntervalSince1970: 1_780_000_000) // ISO 8601 in the file keeps whole seconds
    try! StudioStore.saveScenario(scenario, root: root)
    let loaded = StudioStore.loadScenarios(root)
    check("scenarios are saved as reusable configuration", loaded.count == 1 && loaded[0] == scenario
          && fm.fileExists(atPath: root.appendingPathComponent(".markview/studio/scenarios/long-names.json").path))
    check("a saved scenario is compatible with its contracts", StudioScenarioCompatibility.problems(scenario, spec: spec).isEmpty)
    var changed = spec
    changed.entities[0].fields.append(StudioField(name: "owner", type: "string", required: true))
    let problems = StudioScenarioCompatibility.problems(scenario, spec: changed)
    check("SCN-04 a changed contract marks the scenario incompatible", problems.contains { $0.contains("contracts") } && problems.contains { $0.contains("owner is required") }, problems.joined(separator: "; "))
    let (updated, notes) = StudioScenarioCompatibility.updated(scenario, spec: changed)
    check("SCN-04 an explicit update fills the new field and bumps the revision", updated.revision == 2 && notes.contains { $0.contains("owner") }
          && StudioScenarioCompatibility.problems(updated, spec: changed).isEmpty)
    check("the baseline is not changed by the check itself", scenario.revision == 1 && scenario.data?["projects"]?.first?["owner"] == nil)
    let presets = StudioScenarioCompatibility.presets(spec: spec, base: base)
    check("built-in populated, empty, loading and error states", presets.map(\.kind) == [.populated, .empty, .loading, .error])
    StudioStore.prepareLocalFolder(root)
    check("session data folder ignores itself in Git", (try? String(contentsOf: root.appendingPathComponent(".dde/studio/.gitignore"), encoding: .utf8))?.contains("*") == true)
    try! StudioStore.saveEnvironment(spec, root: root)
    check("environment round trip", StudioStore.loadEnvironment(root)?.rules == spec.rules && StudioStore.loadEnvironment(root)?.seed == spec.seed)
}

// MARK: - Evidence (CAP-01…CAP-06)

func image(_ width: Int, _ height: Int, mark: Bool) -> CGImage {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    if mark { for y in 2..<5 { for x in 3..<7 { let i = (y * width + x) * 4; pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0 } } }
    return StudioImageDiff.makeImage(pixels, width: width, height: height)!
}

func evidenceChecks() {
    let plain = image(10, 8, mark: false), marked = image(10, 8, mark: true)
    check("identical captures have no difference", StudioImageDiff.compare(plain, plain)?.changed == 0)
    let difference = StudioImageDiff.compare(plain, marked)
    check("CAP-04 the difference counts and bounds the changed pixels", difference?.changed == 12 && difference?.bounds == CGRect(x: 3, y: 2, width: 4, height: 3), "\(String(describing: difference?.bounds))")
    check("pictures of different sizes are not compared", StudioImageDiff.compare(plain, image(9, 8, mark: false)) == nil)
    let file = tmp.appendingPathComponent("diff.png")
    check("the difference is written as PNG", difference.map { StudioImageDiff.writePNG($0.image, to: file) } == true && StudioImageDiff.load(file)?.width == 10)

    let rendering = StudioRendering(engine: "WebKit 621", os: "macOS 26.0", viewport: StudioViewport(width: 1280, height: 800), devicePixelRatio: 2,
                                    fonts: ["Inter"], locale: "en-US", timeZone: "UTC", colorScheme: "light")
    let revision = StudioRevision(id: "abc", head: "123", changedFiles: 0, editorBuffers: 0)
    let a = StudioCapture(id: "c1", label: "Before", file: "c1.png", revision: revision, scenarioId: "populated", scenarioRevision: 1, contractFingerprint: "f", rendering: rendering)
    var b = a; b.id = "c2"; b.label = "After"; b.revision.id = "def"
    check("CAP-01 captures of the same scenario and rendering are comparable", StudioImageDiff.incomparability(a, b).isEmpty)
    var c = b; c.rendering.viewport = StudioViewport(width: 390, height: 844); c.scenarioRevision = 2
    check("different viewport or scenario revision is not comparable", StudioImageDiff.incomparability(a, c).count == 2)

    // CAP-05 / CAP-06: package contents and revalidation after a later change of its files.
    let root = tmp.appendingPathComponent("pkg")
    try! fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try! "a { color: blue; }".write(to: root.appendingPathComponent("src/x.css"), atomically: true, encoding: .utf8)
    var scenario = base
    scenario.data = ["users": [.object(["id": .number(1), "name": .string("Ann"), "password": .string("hunter2")])]]
    let package = StudioPackage(id: "badge-color", featureSlug: "badge-color", title: "Badge colour", summary: "Blue badges",
                                requests: ["make the badge blue, token=sk-ant-abcdefghijklmnopqrstuv"], operations: ["op-1"], scenario: scenario,
                                baselineRevision: revision, finalRevision: b.revision,
                                files: StudioRevisionProbe.currentHashes(["src/x.css"], root: root),
                                patch: "-a { color: red; }\n+a { color: blue; }", rendering: rendering,
                                pictures: [StudioPackage.Picture(label: "Before", captureId: "c1", file: ".dde/studio/captures/c1.png", inFeature: false, bytes: 900_000)],
                                checks: [StudioCheck(name: "Build", passed: true)])
    let overview = package.overview(redactor: redactor)
    check("CAP-05 the overview holds revisions, scenario, rendering, captures, checks and patch",
          overview.contains("Baseline code revision") && overview.contains("Final code revision") && overview.contains("Scenario: Populated")
          && overview.contains("WebKit 621") && overview.contains("kept out of Git") && overview.contains("[x] Build") && overview.contains("```diff"))
    check("secrets stay out of exported evidence", !overview.contains("sk-ant-abcdefghijklmnopqrstuv"))
    check("a fresh package is current", package.revalidated(root: root).status == .current)
    try! "a { color: green; }".write(to: root.appendingPathComponent("src/x.css"), atomically: true, encoding: .utf8)
    let stalePackage = package.revalidated(root: root)
    check("CAP-06 a later change of its files requires revalidation", stalePackage.status == .revalidationRequired && stalePackage.changedSince == ["src/x.css"])
    check("CAP-06 historical captures are kept", stalePackage.pictures == package.pictures)
}

// MARK: - Prompts and answers

func promptChecks() {
    let structured: [String: Any] = [
        "unsupported": false, "reason": "", "assumptions": ["labels have only names"],
        "entities": [["name": "labels", "idField": "id", "fields": [["name": "name", "type": "string", "required": true, "enumValues": [], "references": ""]]]],
        "records": [["entity": "labels", "json": #"[{"id":1,"name":"urgent"},{"id":2,"name":"later"}]"#]],
        "rules": [["id": "list-labels", "method": "get", "path": "/api/labels", "operation": "list", "entity": "labels", "envelope": "",
                   "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "type", "detail": "src/api.ts:12 Label[]"]]]],
    ]
    let parsed = StudioPrompts.proposal(from: structured)
    check("a strict-schema answer becomes a proposal", parsed?.rules.first?.method == "GET" && parsed?.rules.first?.envelope == nil
          && parsed?.records["labels"]?.count == 2 && parsed?.entities.first?.fields.first?.enumValues == nil && parsed?.rules.first?.evidence.first?.kind == .type)
    let plan = StudioPrompts.editPlan(from: ["scope": "shared-component", "scopeNote": "Card is used 6 times", "needsClarification": true,
                                             "question": "All cards or this one?", "options": ["All cards", "Only this card"], "summary": "", "edits": []])
    check("a clarification answer has no edits", plan?.needsClarification == true && plan?.edits.isEmpty == true && plan?.scope == .sharedComponent)
    check("prompts treat page content as data", StudioPrompts.editSystem.contains("never instructions") && StudioPrompts.preparationSystem.contains("never instructions"))
}

// MARK: - Selection (PRE-07…PRE-09)

func selectionChecks() {
    let root = repo, appFolder = repo
    check("absolute source path inside the project", StudioSelectionContext.projectPath(repo.appendingPathComponent("src/Card.jsx").path, root: root, appFolder: appFolder) == "src/Card.jsx")
    check("dev server URL of a module", StudioSelectionContext.projectPath("http://localhost:5173/src/Card.jsx?t=12345", root: root, appFolder: appFolder) == "src/Card.jsx")
    check("relative path of the app folder", StudioSelectionContext.projectPath("src/Card.jsx", root: root, appFolder: appFolder) == "src/Card.jsx")
    check("a path outside the project is refused", StudioSelectionContext.projectPath("/etc/hosts", root: root, appFolder: appFolder) == nil)
    check("a missing file is refused", StudioSelectionContext.projectPath("src/Nope.jsx", root: root, appFolder: appFolder) == nil)
    // BUG-069: Turbopack (Next.js 16) names sources as file URLs in its maps and as [project]/… module ids.
    check("BUG-069 a source map's file URL inside the project", StudioSelectionContext.projectPath(repo.appendingPathComponent("src/Card.jsx").absoluteString,
                                                                                               root: root, appFolder: appFolder) == "src/Card.jsx")
    check("BUG-069 a Turbopack module id", StudioSelectionContext.projectPath("[project]/src/Card.jsx [app-client] (ecmascript)",
                                                                       root: root, appFolder: appFolder) == "src/Card.jsx")
    check("BUG-069 a file URL outside the project is refused", StudioSelectionContext.projectPath("file:///etc/hosts", root: root, appFolder: appFolder) == nil)
    // An indexed map like Turbopack's: chunk lines 10… belong to Card.jsx, lines 20… to List.jsx. Line 11 has two segments:
    // columns 0… map to Card.jsx line 2, columns 5… to line 3 column 3.
    let indexed = """
        {"version":3,"sources":[],"sections":[
          {"offset":{"line":10,"column":0},"map":{"version":3,"sources":["file:///p/src/Card.jsx"],"names":[],"mappings":"AAAA;AACA,KACE;AAIF"}},
          {"offset":{"line":20,"column":0},"map":{"version":3,"sources":["file:///p/src/List.jsx"],"names":[],"mappings":"AAAA;AAEA"}}]}
        """.data(using: .utf8)!
    let p1 = StudioSourceMap.original(in: indexed, line: 11, column: 1)
    let p2 = StudioSourceMap.original(in: indexed, line: 12, column: 3)
    let p3 = StudioSourceMap.original(in: indexed, line: 12, column: 9)
    let p4 = StudioSourceMap.original(in: indexed, line: 22, column: 1)
    check("BUG-069 a chunk position maps to its section's source and line",
          p1 == StudioSourceMap.Position(source: "file:///p/src/Card.jsx", line: 1, column: 1)
          && p2 == StudioSourceMap.Position(source: "file:///p/src/Card.jsx", line: 2, column: 1)
          && p3 == StudioSourceMap.Position(source: "file:///p/src/Card.jsx", line: 3, column: 3)
          && p4 == StudioSourceMap.Position(source: "file:///p/src/List.jsx", line: 3, column: 1),
          "\(String(describing: p1)) \(String(describing: p2)) \(String(describing: p3)) \(String(describing: p4))")
    check("BUG-069 a position before every section or beyond a map maps to nothing",
          StudioSourceMap.original(in: indexed, line: 5, column: 1) == nil && StudioSourceMap.original(in: Data("{}".utf8), line: 1, column: 1) == nil)
    let plainMap = Data(#"{"version":3,"sourceRoot":"/p/","sources":["src/App.jsx"],"names":[],"mappings":";;AAEA"}"#.utf8)
    check("BUG-069 a plain map with a source root", StudioSourceMap.original(in: plainMap, line: 3, column: 7)
          == StudioSourceMap.Position(source: "/p/src/App.jsx", line: 3, column: 1))
    let snippet = StudioSelectionContext.snippet(of: card, line: 3, radius: 1)
    check("the snippet marks the mapped line", snippet.contains("    3> ") && snippet.split(separator: "\n").count == 3, snippet)

    func element(_ node: String?, _ index: Int, _ count: Int) -> StudioSelectionContext {
        StudioSelectionContext(["rect": ["x": 0, "y": 0, "width": 10, "height": 10], "tag": "div.card", "selector": "div.card",
                                "source": ["framework": "react", "mapping": "exact", "file": "src/Card.jsx", "line": 3, "nodeId": node as Any,
                                           "instanceIndex": index, "instanceCount": count]])!
    }
    let selected = element("src/Card.jsx:3:5", 1, 3)
    check("AC-10 the selection knows its instance among shared ones", selected.instanceIndex == 1 && selected.instanceCount == 3 && selected.sourceNodeId == "src/Card.jsx:3:5")
    if case .kept(let kept) = StudioSelectionRevalidation.decide(previous: selected, candidates: [element("src/Card.jsx:3:5", 0, 3), element("src/Card.jsx:3:5", 1, 3)]) {
        check("PRE-09 the same instance is kept after a change", kept.instanceIndex == 1 && kept.revalidated)
    } else { check("PRE-09 kept", false) }
    if case .remapped = StudioSelectionRevalidation.decide(previous: selected, candidates: [element("src/Card.jsx:4:5", 1, 3)]) {
        check("PRE-09 a moved source line is remapped", true)
    } else { check("PRE-09 remapped", false) }
    if case .cleared = StudioSelectionRevalidation.decide(previous: selected, candidates: [element("src/Other.jsx:1:1", 0, 2), element("src/Other.jsx:1:1", 2, 2)]) {
        check("PRE-09 an ambiguous mapping is cleared", true)
    } else { check("PRE-09 cleared", false) }
    if case .cleared = StudioSelectionRevalidation.decide(previous: selected, candidates: []) { check("a vanished element clears the selection", true) } else { check("vanished", false) }

    // BUG-070: a framework's own data requests go to the development server with no-cache, never to the simulation.
    func framework(_ url: String, _ headers: [String: String] = [:]) -> Bool {
        StudioConnectionPolicy.isFrameworkRequest(URL(string: url)!, headers: headers)
    }
    check("BUG-070 Next.js refresh and navigation payloads are the server's", framework("http://localhost:3000/?_rsc=1x2", ["rsc": "1"])
          && framework("http://localhost:3000/orders", ["rsc": "1", "next-router-state-tree": "%5B%5D"]))
    check("BUG-070 Next.js server actions are the server's", framework("http://localhost:3000/", ["next-action": "abc123"]))
    check("BUG-070 Remix, SvelteKit, Nuxt and Astro data requests are the server's",
          framework("http://localhost:5173/orders?_data=routes%2Forders") && framework("http://localhost:5173/orders.data")
          && framework("http://localhost:5173/orders/__data.json?x-sveltekit-invalidated=01") && framework("http://localhost:3000/orders/_payload.json")
          && framework("http://localhost:3000/__nuxt_island/Card.json") && framework("http://localhost:4321/_server-islands/Cart"))
    check("BUG-070 the application's own API is not mistaken for a framework request",
          !framework("http://localhost:3000/api/orders") && !framework("http://localhost:3000/api/data?page=2")
          && !framework("http://localhost:3000/", ["accept": "text/x-component"]))
    let pass = StudioBridge.passThrough(adding: StudioConnectionPolicy.frameworkRequestHeaders)
    check("BUG-070 a framework request passes with no-cache", pass["action"] as? String == "pass"
          && (pass["headers"] as? [String: String])?["cache-control"] == "no-cache")

    // BUG-068: an element without source metadata is found again by what it is, not by where it was.
    func plain(_ tag: String, _ classes: [String], _ text: String, component: String? = nil, node: String? = nil) -> StudioSelectionContext {
        StudioSelectionContext(["rect": ["x": 0, "y": 0, "width": 10, "height": 10], "tag": tag, "selector": "body > section:nth-of-type(1) > button",
                                "text": text, "classes": classes,
                                "source": ["framework": component == nil ? "" : "react", "mapping": "none", "component": component ?? "",
                                           "nodeId": node ?? ""]])!
    }
    let cta = plain("button.cta", ["cta"], "Plan with us")
    if case .cleared = StudioSelectionRevalidation.decide(previous: cta, candidates: [plain("button.accept", ["accept"], "Accept all")]) {
        check("BUG-068 another element at the old position is not taken for the selected one", true)
    } else { check("BUG-068 another element at the old position is not taken for the selected one", false) }
    if case .remapped(let found) = StudioSelectionRevalidation.decide(previous: cta, candidates: [plain("button.accept", ["accept"], "Accept all"),
                                                                                               plain("button.cta", ["cta"], "Plan with us")]) {
        check("BUG-068 the same element is found where it is now", found.classes == ["cta"])
    } else { check("BUG-068 the same element is found where it is now", false) }
    if case .cleared = StudioSelectionRevalidation.decide(previous: cta, candidates: [plain("button.cta", ["cta"], "Book now")]) {
        check("BUG-068 before a change, a different text means a different element", true)
    } else { check("BUG-068 before a change, a different text means a different element", false) }
    if case .remapped = StudioSelectionRevalidation.decide(previous: cta, candidates: [plain("button.cta", ["cta", "soft"], "Plan it with us")], afterEdit: true) {
        check("BUG-068 after a change, the edited element is still found", true)
    } else { check("BUG-068 after a change, the edited element is still found", false) }
    let card = plain("div.mx-auto", ["mx-auto", "flex"], "Can't find the right package?", component: "PlanningInvitation",
                     node: "react|PlanningInvitation|div")
    let bannerButton = plain("div.mx-auto", ["mx-auto", "flex"], "A quick word on cookies", component: "ConsentBanner", node: "react|ConsentBanner|div")
    if case .cleared = StudioSelectionRevalidation.decide(previous: card, candidates: [bannerButton], afterEdit: true) {
        check("BUG-068 an element of another component is never taken, even after a change", true)
    } else { check("BUG-068 an element of another component is never taken, even after a change", false) }
}

// MARK: - Session processes and connection policy (REQ-006, AC-17, AC-18)

@MainActor
func processChecks() async {
    // A server the session started runs in a process group of its own; stopping it ends what it started too.
    let server = StudioDevServer(command: "sleep 300 & echo child=$!; wait", folder: tmp)
    do { try server.start(environment: ["PATH": "/usr/bin:/bin"]) } catch { check("AC-18 the server starts", false, "\(error)") }
    var child: pid_t = 0
    for _ in 0..<50 where child == 0 {
        if let range = server.output.range(of: #"child=(\d+)"#, options: .regularExpression) {
            child = pid_t(server.output[range].dropFirst(6)) ?? 0
        } else {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    check("AC-18 the server runs in its own process group", server.processID > 0 && getpgid(server.processID) == server.processID,
          "pid \(server.processID) group \(getpgid(server.processID))")
    check("AC-18 a process the server started is in the same group", child > 0 && getpgid(child) == server.processID, "child \(child)")
    check("the server does not share MarkView's process group", getpgid(server.processID) != getpgrp())
    await server.stop(grace: 2)
    try? await Task.sleep(nanoseconds: 300_000_000)
    check("AC-18 stopping the session's server ends the server", server.exitStatus != nil && kill(server.processID, 0) != 0)
    check("AC-18 stopping the session's server ends what it started", child > 0 && kill(child, 0) != 0)

    // A server that exits on its own reports its status and leaves nothing behind.
    let failing = StudioDevServer(command: "echo broken >&2; exit 3", folder: tmp)
    try? failing.start(environment: ["PATH": "/usr/bin:/bin"])
    let ended = await failing.waitForExit(timeout: 5)
    check("a server that fails reports its exit status and output", ended && failing.exitStatus == 3 && failing.output.contains("broken"),
          "\(failing.exitStatus ?? -1) \(failing.output)")

    // The launch environment carries no production secrets and keeps browsers closed (§11, AC-17).
    let base = ["PATH": "/usr/bin", "HOME": NSHomeDirectory(), "SHELL": "/bin/sh", "OPENAI_API_KEY": "sk-test-not-real",
                "AWS_SECRET_ACCESS_KEY": "not-real", "GITHUB_TOKEN": "not-real", "CLAUDECODE": "1", "LANG": "en_US.UTF-8"]
    let launch = await StudioLaunchEnvironment.make(base: base)
    check("AC-17 secrets of MarkView's environment do not reach the project's processes",
          launch.environment["OPENAI_API_KEY"] == nil && launch.environment["AWS_SECRET_ACCESS_KEY"] == nil
          && launch.environment["GITHUB_TOKEN"] == nil && launch.environment["CLAUDECODE"] == nil,
          launch.environment.keys.sorted().joined(separator: ","))
    check("AC-17 the removed names are listed, never their values", launch.removed.contains("OPENAI_API_KEY") && !launch.removed.contains("sk-test-not-real"))
    check("the project's processes get a usable PATH and no browser", (launch.environment["PATH"] ?? "").contains("/usr/bin")
          && launch.environment["BROWSER"] == "none" && launch.environment["LANG"] == "en_US.UTF-8")

    // Connection policy: allowed patterns become anchored filters; dev-server files pass, application data does not.
    check("AC-16 an allowed address becomes an anchored filter", StudioConnectionPolicy.filter(forAllowed: "https://fonts.googleapis.com/*") == #"^https://fonts\.googleapis\.com/"#,
          StudioConnectionPolicy.filter(forAllowed: "https://fonts.googleapis.com/*") ?? "nil")
    check("AC-16 something that is not an address is not allowed", StudioConnectionPolicy.filter(forAllowed: "javascript:alert(1)") == nil
          && StudioConnectionPolicy.filter(forAllowed: "https://evil.com\\@x/") == nil)
    let folder = tmp.appendingPathComponent("app")
    try? fm.createDirectory(at: folder.appendingPathComponent("public/locales"), withIntermediateDirectories: true)
    try? Data("{}".utf8).write(to: folder.appendingPathComponent("public/locales/en.json"))
    func resource(_ path: String) -> Bool { StudioConnectionPolicy.isDevelopmentResource(URL(string: "http://localhost:5173" + path)!, appFolder: folder) }
    check("the development server's own files pass", resource("/src/main.tsx") && resource("/@vite/client") && resource("/assets/logo.svg"))
    check("a JSON file the app folder serves passes", resource("/locales/en.json"))
    check("AC-16 application data is never passed through", !resource("/api/projects") && !resource("/api/projects.json") && !resource("/../secret.json"))
}

// MARK: - Run

let done = DispatchSemaphore(value: 0)
Task { @MainActor in
    await preparationChecks()
    await changeChecks()
    scenarioChecks()
    evidenceChecks()
    promptChecks()
    selectionChecks()
    await processChecks()
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
print(failures == 0 ? "All UI Studio checks passed." : "\(failures) UI Studio check(s) failed.")
exit(failures == 0 ? 0 : 1)
