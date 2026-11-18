// Checks the pure modules of UI Studio (MarkView/Models/UIStudio*.swift): the simulation engine, rule validation,
// bounded preparation, redaction, bridge validation, the change manager with selective undo, code revision identity,
// scenarios and their compatibility, image comparison and feature packages. Run by tools/tests/ui-studio-tests.sh.
import CoreGraphics
import Combine
import Foundation
import os

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
// The viewport menu lists presets by name: names are unique, the default desktop stays first, and larger desktops are offered.
let presetNames = StudioViewport.presets.map(\.name)
check("viewport presets have unique names and the default desktop first",
      Set(presetNames).count == presetNames.count && StudioViewport.presets.first?.viewport == StudioScenario(id: "x", name: "x").viewport)
check("viewport presets offer Full HD and QHD desktops",
      StudioViewport.presets.contains { $0.viewport == StudioViewport(width: 1920, height: 1080) }
      && StudioViewport.presets.contains { $0.viewport == StudioViewport(width: 2560, height: 1440) })
// BUG-087: the scenario a session ended on is remembered per project, in the session data that stays out of Git.
let activeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("markview-active-scenario-\(UUID().uuidString)")
check("BUG-087 no scenario is remembered in a new project", StudioStore.loadActiveScenarioID(activeRoot) == nil)
StudioStore.saveActiveScenarioID("33-strikes", root: activeRoot)
check("BUG-087 the active scenario is remembered with the session data, kept out of Git",
      StudioStore.loadActiveScenarioID(activeRoot) == "33-strikes"
      && StudioStore.activeScenarioURL(activeRoot).path.contains("/.dde/studio/")
      && ((try? String(contentsOf: StudioStore.localFolder(activeRoot).appendingPathComponent(".gitignore"), encoding: .utf8)) ?? "").contains("*"))
try? "not json".write(to: StudioStore.activeScenarioURL(activeRoot), atomically: true, encoding: .utf8)
check("BUG-087 an unreadable record is no scenario", StudioStore.loadActiveScenarioID(activeRoot) == nil)
try? FileManager.default.removeItem(at: activeRoot)

// The session's own files in `.dde/studio/` are schema-versioned stores (AR-36). The legacy fixtures are the bare documents the
// previous version wrote; the history is written with the raw writer that version used (`StudioStore.save`).
do {
    let root = StoreFixture.folder("studio-stores")
    defer { try? FileManager.default.removeItem(at: root) }
    StoreFixture.write(#"{ "id" : "33-strikes" }"#, to: StudioStore.activeScenarioURL(root))
    check("legacy active scenario: it is read", StudioStore.loadActiveScenarioID(root) == "33-strikes")
    check("legacy active scenario: reading leaves it as written", StoreFixture.envelope(StudioStore.activeScenarioURL(root)) == nil)
    StudioStore.saveActiveScenarioID("other", root: root)
    check("legacy active scenario: the next save writes the envelope",
          StoreFixture.envelope(StudioStore.activeScenarioURL(root))?.schema == 1 && StudioStore.loadActiveScenarioID(root) == "other"
          && StoreFixture.backups(of: StudioStore.activeScenarioURL(root)).isEmpty)

    var earlier = StudioOperation(id: "op-earlier", kind: .edit, request: "Make the consent banner smaller", status: .applied)
    earlier.selection = "div.consent-banner"
    earlier.created = Date(timeIntervalSince1970: 1_790_000_000)   // whole seconds: the file keeps ISO 8601 dates
    try StudioStore.save([earlier], to: StudioStore.historyURL(root))
    check("legacy history: it loads intact", StudioStore.loadHistory(root) == [earlier])
    check("legacy history: reading leaves it as written", StoreFixture.envelope(StudioStore.historyURL(root)) == nil)
    var later = earlier; later.id = "op-later"
    try StudioStore.saveHistory([earlier, later], root: root)
    check("legacy history: the next save writes the envelope and it reloads",
          StoreFixture.envelope(StudioStore.historyURL(root))?.schema == 1 && StudioStore.loadHistory(root) == [earlier, later]
          && StoreFixture.backups(of: StudioStore.historyURL(root)).isEmpty)

    let junk = Data("[ { \"id\": ".utf8)
    try junk.write(to: StudioStore.historyURL(root))
    check("damaged history: it reads as empty and is left as it is", StudioStore.loadHistory(root).isEmpty && StoreFixture.bytes(StudioStore.historyURL(root)) == junk)
    try StudioStore.saveHistory([earlier], root: root)
    check("damaged history: a save keeps the old bytes in a dated backup",
          StoreFixture.backups(of: StudioStore.historyURL(root)).count == 1
          && StoreFixture.bytes(StoreFixture.backups(of: StudioStore.historyURL(root))[0]) == junk && StudioStore.loadHistory(root) == [earlier])

    let future = Data(StoreFixture.newerFile(payload: "[]").utf8)
    try future.write(to: StudioStore.capturesURL(root))
    var refused = false
    do { try StudioStore.saveCaptures([], root: root) } catch SchemaStoreError.newerSchemaVersion { refused = true }
    check("newer captures: a save is refused, the file is untouched, and reading shows none",
          refused && StoreFixture.bytes(StudioStore.capturesURL(root)) == future && StudioStore.loadCaptures(root).isEmpty)
}
check("AC-01 list answers prepared data without a backend", list.0 == 200 && list.1?.arrayValue?.count == 3)
let detail = answer(sim.handle(request("GET", "/api/projects/1")))
check("AC-02 detail matches the list", detail.1?["name"] == list.1?.arrayValue?.first?["name"])
check("AC-02 detail includes related records from the same state", detail.1?["tasks"]?.arrayValue?.count == 2)
check("list filters by query", answer(sim.handle(request("GET", "/api/projects?status=archived"))).1?.arrayValue?.count == 1)
check("literal route beats parameter", StudioRoute.specificity("/api/projects/archived") > StudioRoute.specificity("/api/projects/:id"))

// BUG-078: paging parameters named as filters (vivaa's bundles/search had `filters: [category_id, limit, offset]`) page the
// list instead of emptying it, and a filter on a field no record has is ignored.
do {
    var paged = spec
    paged.rules = [StudioRule(id: "search", method: "GET", path: "/api/projects/search", operation: .list, entity: "projects",
                              filters: ["status", "limit", "offset", "noSuchField"])]
    var pagedSim = StudioSimulator(spec: paged, scenario: base, appOrigin: app)
    let all = answer(pagedSim.handle(request("GET", "/api/projects/search?limit=10&offset=0"))).1?.arrayValue?.count
    check("BUG-078 limit and offset named as filters do not empty the list", all == 3, "\(all ?? -1)")
    let active = answer(pagedSim.handle(request("GET", "/api/projects/search?status=active&limit=10&offset=0&noSuchField=x"))).1?.arrayValue
    check("BUG-078 a real field still filters, a field no record has is ignored", active?.count == 2, "\(active?.count ?? -1)")
    let second = answer(pagedSim.handle(request("GET", "/api/projects/search?limit=2&offset=1"))).1?.arrayValue
    check("BUG-078 limit and offset page the list", second?.map { $0["name"]?.stringValue ?? "" } == ["Gemini", "Mercury"],
          "\(second ?? [])")
    let page2 = answer(pagedSim.handle(request("GET", "/api/projects/search?page=2&per_page=2"))).1?.arrayValue
    check("BUG-078 a 1-based page with per_page pages the list", page2?.map { $0["name"]?.stringValue ?? "" } == ["Mercury"], "\(page2 ?? [])")
}


// BUG-097: sort and search are applied to the filtered records before paging.
do {
    var searchSpec = spec
    searchSpec.rules = [StudioRule(id: "search", method: "GET", path: "/api/projects/search", operation: .list,
                                   entity: "projects", filters: ["status", "sort", "q", "search"])]
    var searchSim = StudioSimulator(spec: searchSpec, scenario: base, appOrigin: app)
    func names(_ query: String) -> [String] {
        answer(searchSim.handle(request("GET", "/api/projects/search?" + query))).1?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }
    check("BUG-097 descending numeric order precedes paging", names("sort=id&order=desc&limit=2") == ["Mercury", "Gemini"])
    check("BUG-097 order_by dot direction and sort_by minus", names("order_by=name.desc") == ["Mercury", "Gemini", "Apollo"]
          && names("sort_by=-id") == ["Mercury", "Gemini", "Apollo"])
    check("BUG-097 search is case insensitive and combines with filters before paging", names("q=EMI&status=active&limit=1") == ["Gemini"]
          && names("search=UR") == ["Mercury"])
    check("BUG-097 unknown sort field keeps seed order", names("sort=unknown") == ["Apollo", "Gemini", "Mercury"])
}

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
if case .unknown(let contract) = sim.handle(request("POST", "/graphql", body: #"{"query":"query { me { id } }"}"#)) {
    check("REQ-015 GraphQL without an operation is prepared, not refused", contract == "GRAPHQL /graphql query me", contract)
} else { check("REQ-015 GraphQL without an operation is prepared", false) }
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
    // BUG-077: the agent CLI's own limit follows the attempt's deadline, so a page's preparation ahead gets its 240 s and a
    // timeout ends the attempt in the queue (no retry), instead of a fixed 95 s that failed it twice.
    let limits = StudioPreparationLimits()
    var cliAhead = context("Page /: server requests")
    cliAhead.ahead = StudioRouteAhead(route: "/", connections: ["API_URL"])
    check("BUG-077 a request's CLI limit is a little after its 90 s deadline", limits.cliTimeout(for: context("GET /api/labels")) == 95)
    check("BUG-077 a page's preparation ahead gets 240 s, and the CLI a little longer",
          limits.deadline(for: cliAhead) == 240 && limits.cliTimeout(for: cliAhead) == 245)
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

    // BUG-074: the deadline is per attempt and starts when the attempt gets a slot, so queued preparations still finish.
    let queued = StudioPreparationQueue(limits: StudioPreparationLimits(deadline: 0.5, queueWait: 5, maxAttempts: 1, maxConcurrent: 1, maxContracts: 40))
    let steady = StubPreparer(delay: 300_000_000) { _ in StudioProposal() }
    async let q1 = queued.resolve(context("GET /q1"), generation: 1, preparer: steady, currentGeneration: { 1 }, commit: { _ in [] })
    async let q2 = queued.resolve(context("GET /q2"), generation: 1, preparer: steady, currentGeneration: { 1 }, commit: { _ in [] })
    async let q3 = queued.resolve(context("GET /q3"), generation: 1, preparer: steady, currentGeneration: { 1 }, commit: { _ in [] })
    let (o1, o2, o3) = await (q1, q2, q3)
    check("BUG-074 waiting for a slot does not use up a preparation's deadline",
          [o1, o2, o3].allSatisfy { $0 == .registered(rules: []) }, "\(o1) \(o2) \(o3)")

    // BUG-074: a preparation ahead of a page belongs to the environment: Reset (cancelAll) does not drop it; closing does.
    let aheadQueue = StudioPreparationQueue()
    var aheadSimulator = StudioSimulator(spec: spec, scenario: base, appOrigin: app)
    var aheadContext = context("Page /: server requests")
    aheadContext.ahead = StudioRouteAhead(route: "/", connections: ["API_URL → http://api.example.test"])
    let aheadTask = Task { @MainActor in
        await aheadQueue.prepareAhead(aheadContext, services: ["http://api.example.test"], preparer: StubPreparer(delay: 300_000_000, make: labels),
                                      commit: { aheadSimulator.register($0) })
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    aheadSimulator.activate(emptyScenario)
    aheadQueue.cancelAll()
    // A request to the same service waits for the preparation ahead instead of asking the model a second time.
    let waitStarted = Date()
    await aheadQueue.waitForGroup("http://api.example.test")
    let aheadOutcome = await aheadTask.value
    check("BUG-074 a request to a service that is being prepared waits for it", Date().timeIntervalSince(waitStarted) >= 0.2,
          "\(Date().timeIntervalSince(waitStarted))")
    check("BUG-074 a preparation ahead survives Reset and registers its rules", aheadOutcome == .registered(rules: ["list-labels"])
          && aheadSimulator.spec.rules.contains { $0.id == "list-labels" }, "\(aheadOutcome)")
    let closingQueue = StudioPreparationQueue()
    let closing = Task { @MainActor in
        await closingQueue.prepareAhead(aheadContext, services: [], preparer: StubPreparer(delay: 400_000_000, make: labels), commit: { _ in [] })
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    closingQueue.cancelEverything()
    let closedOutcome = await closing.value
    check("BUG-074 closing the session cancels a preparation ahead", closedOutcome == .cancelled, "\(closedOutcome)")
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
let standIn: [String: Any] = ["kind": "event", "session": "s-1", "generation": 3, "type": "standIn", "detail": "stripe: Stripe.js \u{2014} payments are simulated, no card is charged"]
if case .success(.event(let parsed)) = StudioBridge.validate(standIn, isMainFrame: true, origin: origin, expecting: expectation) {
    check("BUG-103 a stand-in event is accepted", parsed.kind == .standIn && parsed.detail.hasPrefix("stripe: "))
} else { check("BUG-103 a stand-in event is accepted", false) }
var forgedStandIn = standIn; forgedStandIn["detail"] = "not-an-sdk: anything"
if case .failure(.malformed) = StudioBridge.validate(forgedStandIn, isMainFrame: true, origin: origin, expecting: expectation) {
    check("BUG-103 a stand-in event naming no registered SDK is malformed, so it cannot add dependency rows", true)
} else { check("BUG-103 a stand-in event naming no registered SDK is malformed", false) }
// The page runtime registers the stand-ins; the bridge accepts exactly those ids.
if let runtime = StudioRuntime.source(in: URL(fileURLWithPath: "MarkView/Resources/Editor/js")) {
    var registered = Set<String>()
    var rest = Substring(runtime)
    while let found = rest.range(of: "sdkRegister('") {
        rest = rest[found.upperBound...]
        if let end = rest.firstIndex(of: "'") { registered.insert(String(rest[..<end])) }
    }
    check("BUG-103 the SDKs the runtime registers are exactly the ones the bridge accepts", registered == StudioBridge.standInIDs,
          "\(registered.sorted()) vs \(StudioBridge.standInIDs.sorted())")
} else { check("BUG-103 the runtime source is readable for the registry check", false) }

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

// MARK: - Browser features and kept browser data (REQ-008)

// MARK: - Evidence (CAP-01…CAP-06)

// MARK: - One request box and context changes (DEC-010, REQ-013)

/// A context object as a strict-schema assistant returns it: every property present, empty when not given.
// MARK: - Selection (PRE-07…PRE-09)


// MARK: - Session processes and connection policy (REQ-006, AC-17, AC-18)


// MARK: - Conversation memory and page events

// MARK: - Server connections (REQ-007)



// MARK: - Session log (REQ-011)

@MainActor
func logChecks() async {
    let ioQueue = DispatchQueue(label: "markview.ui-studio.log-tests")

    // The ring keeps the newest 2,000 entries and counts the problems among them.
    check("REQ-011 the log keeps 2,000 entries", StudioLogRing.capacity == 2_000)
    let memory = StudioLog(root: nil, redactor: StudioRedactor(), queue: ioQueue)
    for index in 1...2_500 { memory.add(index % 10 == 0 ? .server : .request, problem: index % 10 == 0, "entry \(index)") }
    check("REQ-011 the ring drops the oldest entries beyond 2,000", memory.entries.count == 2_000
          && memory.entries.first?.text == "entry 501" && memory.entries.last?.text == "entry 2500",
          "\(memory.entries.count) \(memory.entries.first?.text ?? "") … \(memory.entries.last?.text ?? "")")
    check("REQ-011 the problem count follows the entries kept", memory.problems == 200, "\(memory.problems)")
    memory.clear()
    check("REQ-011 Clear empties the view", memory.entries.isEmpty && memory.problems == 0)
    memory.add(.notice, "after clear")
    check("REQ-011 entry numbers go on after Clear", memory.entries.first?.id == 2_501, "\(memory.entries.first?.id ?? 0)")

    // Secrets never reach a line: a known secret (by hash, alone or glued to its name), a bearer value and a JWT.
    let secret = "s3cret-" + "value-" + "4711-known"
    let opaque = "opaqueToken" + "9f8e7d6c5b4a"
    let jwt = "eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    let logRoot = tmp.appendingPathComponent("log-project")
    let fileLog = StudioLog(root: logRoot, redactor: StudioRedactor(), queue: ioQueue)
    fileLog.secretHashes = [StudioConnections.hash(secret): "API_SECRET"]
    fileLog.add(.server, "loaded the key \(secret) from .env.local")
    fileLog.add(.server, "calling http://rates.example.test/v2/rates?key=\(secret)&page=2")
    fileLog.add(.request, "Authorization: Bearer \(opaque)")
    fileLog.add(.server, "retrying rates.example.test with bearer \(opaque)")
    fileLog.add(.page, problem: true, "runtimeError: token \(jwt) was rejected\n    at verify (auth.ts:12)")
    ioQueue.sync {}
    let logText = (try? String(contentsOf: StudioStore.logURL(logRoot), encoding: .utf8)) ?? ""
    let kept = fileLog.entries.map(\.text).joined(separator: "\n")
    for (name, value) in [("a known secret", secret), ("a Bearer value", opaque), ("a JWT", jwt), ("a JWT's header", "eyJhbGci")] {
        check("REQ-011 \(name) never reaches the log file or the view", !logText.contains(value) && !kept.contains(value))
    }
    check("REQ-011 a known secret is named, not shown", logText.contains("[redacted:API_SECRET] from .env.local")
          && logText.contains("?key=[redacted:API_SECRET]&page=2"), logText)
    check("REQ-011 the bearer scheme stays readable", fileLog.entries[3].text.hasSuffix("with bearer [redacted]")
          && fileLog.entries[2].text.hasPrefix("Authorization: [redacted]"), "\(fileLog.entries[2].text) | \(fileLog.entries[3].text)")
    let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    check("REQ-011 one line per entry, line breaks written as \\n", lines.count == 5 && lines[4].contains("rejected\\n    at verify"),
          "\(lines.count): \(lines.last ?? "")")
    check("REQ-011 a line has its time, kind and problem mark", lines[4].contains(StudioLogFormat.tag(.page, problem: true) + "runtimeError:")
          && lines[0].contains(StudioLogFormat.tag(.server, problem: false) + "loaded")
          && lines[0].range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}(Z|[+-]\d{4}) "#, options: .regularExpression) != nil,
          "\(lines[0]) | \(lines[4])")
    check("REQ-011 the kind column always ends before the mark", StudioLogFormat.tag(.preparation, problem: true) == "preparation ! "
          && StudioLogFormat.tag(.page, problem: false) == "page        - ")
    check("REQ-011 the log file stays out of Git", fm.fileExists(atPath: StudioStore.localFolder(logRoot).appendingPathComponent(".gitignore").path))
    let attributes = try? fm.attributesOfItem(atPath: StudioStore.logURL(logRoot).path)
    check("REQ-011 the log file is readable by its owner only", (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    // The file rotates at 2 MB into one `.1` file.
    check("REQ-011 the file rotates at 2 MB", StudioLogFile.rotationSize == 2 * 1024 * 1024)
    check("REQ-011 rotation: a line that fits is appended", !StudioLogFile.shouldRotate(size: 2 * 1024 * 1024 - 10, adding: 10, limit: 2 * 1024 * 1024))
    check("REQ-011 rotation: a line that does not fit rotates first", StudioLogFile.shouldRotate(size: 2 * 1024 * 1024 - 10, adding: 11, limit: 2 * 1024 * 1024))
    check("REQ-011 rotation: an empty file takes any line", !StudioLogFile.shouldRotate(size: 0, adding: 3 * 1024 * 1024, limit: 2 * 1024 * 1024))
    let rotationRoot = tmp.appendingPathComponent("log-rotation")
    let file = StudioLogFile(root: rotationRoot)
    let filler = String(repeating: "x", count: 1_000)
    var written = 0
    var index = 0
    while written <= 2 * 1024 * 1024 + 4_000 {
        let line = String(format: "%06d ", index) + filler + "\n"
        file.append(line)
        written += line.utf8.count
        index += 1
    }
    func size(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1 }
    let rotated = size(file.rotatedURL), current = size(file.url)
    check("REQ-011 the full file becomes session.log.1, at most 2 MB", rotated > 2 * 1024 * 1024 - 1_008 && rotated <= 2 * 1024 * 1024
          && file.rotatedURL.lastPathComponent == "session.log.1", "\(rotated)")
    check("REQ-011 writing goes on in a new session.log", current > 0 && current < 8_100 && rotated + current == written, "\(current)")
    let firstRotated = (try? String(contentsOf: file.rotatedURL, encoding: .utf8))?.prefix(6) ?? ""
    while written <= 4 * 1024 * 1024 + 8_000 {
        let line = String(format: "%06d ", index) + filler + "\n"
        file.append(line)
        written += line.utf8.count
        index += 1
    }
    let secondRotated = (try? String(contentsOf: file.rotatedURL, encoding: .utf8))?.prefix(6) ?? ""
    let names = ((try? fm.contentsOfDirectory(atPath: StudioStore.localFolder(rotationRoot).path)) ?? []).filter { $0.hasPrefix("session.log") }.sorted()
    check("REQ-011 a second rotation replaces the one .1 file", firstRotated == "000000" && secondRotated != firstRotated
          && names == ["session.log", "session.log.1"], "\(firstRotated) \(secondRotated) \(names)")

    // Server output arrives in pieces; lines that read like errors are problems.
    var splitter = StudioLogLines()
    let first = splitter.feed("ready - started\nerr")
    let second = splitter.feed("or: boom\r\n\n\u{1B}[31mred\u{1B}[0m\n")
    check("REQ-011 server output is split into whole lines", first == ["ready - started"] && second == ["error: boom", "red"],
          "\(first) \(second)")
    _ = splitter.feed("no newline at the end")
    check("REQ-011 the last piece is kept until the server ends", splitter.flush() == ["no newline at the end"] && splitter.flush().isEmpty)
    let errorLines = ["Error: Cannot find module 'x'", " ⨯ unhandledRejection: boom", "npm ERR! code ELIFECYCLE", " GET /dashboard 500 in 31ms",
                      #"127.0.0.1 - - [04/Nov/2026 10:00:00] "GET / HTTP/1.1" 502 -"#, "connect ECONNREFUSED 127.0.0.1:5432"]
    let calmLines = ["✓ Ready in 1.2s", "Found 0 errors. Watching for file changes.", " GET /dashboard 307 in 12ms", "  ➜  Local:   http://localhost:5173/"]
    check("REQ-011 error lines are problems", errorLines.allSatisfy(StudioLogFormat.looksLikeError), "\(errorLines.filter { !StudioLogFormat.looksLikeError($0) })")
    check("REQ-011 ordinary lines are not", !calmLines.contains(where: StudioLogFormat.looksLikeError), "\(calmLines.filter(StudioLogFormat.looksLikeError))")
    check("REQ-011 a redirect to a sign-in page is recognised", ["/auth/login", "/login", "/sign-in", "/api/auth/signin?x=1"].allSatisfy(StudioLogFormat.isSignInPath)
          && !["/authors", "/dashboard", "/"].contains(where: StudioLogFormat.isSignInPath))

    // The preparation queue reports the start and the end of each preparation, without being polled.
    let reported = StudioPreparationQueue(limits: StudioPreparationLimits(deadline: 0.2, maxAttempts: 1, maxConcurrent: 2, maxContracts: 40))
    var records: [StudioPreparationQueue.Record] = []
    let recordSubscription = reported.recordEvents.sink { records.append($0) }
    let outcome = await reported.resolve(context("GET /api/slow-log"), generation: 1, preparer: StubPreparer(delay: 1_000_000_000, make: labels),
                                         currentGeneration: { 1 }, commit: { _ in [] })
    check("REQ-011 a preparation reports its start and its end", outcome == .timedOut && records.count == 2
          && records[0].finished == nil && records[1].status == .timedOut && records[1].finished != nil
          && records[1].message.contains("did not finish"), "\(records.map { "\($0.status) \($0.finished != nil)" })")
    records = []
    var aheadLogContext = context("Page /log: server requests")
    aheadLogContext.ahead = StudioRouteAhead(route: "/log", connections: [])
    _ = await reported.prepareAhead(aheadLogContext, services: [], preparer: StubPreparer(make: labels), commit: { _ in [] })
    check("REQ-011 a preparation ahead of a page is reported too", records.map(\.contract) == ["Page /log: server requests", "Page /log: server requests"]
          && records.last?.status == .registered, "\(records.map { "\($0.contract) \($0.status)" })")
    withExtendedLifetime(recordSubscription) {}
}

// MARK: - Change tracking (REQ-012)



// MARK: - Application map (REQ-014)

/// Every object of a strict schema lists all its properties as required and allows no others (Codex's structured output).
func isStrict(_ schema: Any) -> Bool {
    guard let object = schema as? [String: Any] else { return true }
    if let properties = object["properties"] as? [String: Any] {
        let required = Set((object["required"] as? [String]) ?? [])
        guard required == Set(properties.keys), object["additionalProperties"] as? Bool == false else { return false }
        return properties.values.allSatisfy(isStrict)
    }
    if let items = object["items"] { return isStrict(items) }
    return true
}

@MainActor
func environmentMapChecks() async {
    // The inventory's boundary: what the assistant returned is normalized, and what does not fit is left out.
    let answer: [String: Any] = [
        "services": [
            ["name": "app", "baseURL": "", "variable": "", "side": "both"],
            ["name": "Marketplace Core", "baseURL": "https://core.example.test/v1/", "variable": "process.env.CORE_URL", "side": "server"],
            ["name": "app", "baseURL": "", "variable": "", "side": "browser"],
        ],
        "endpoints": [
            ["service": "marketplace core", "resource": "bundles", "method": "get", "path": "${process.env.CORE_URL}/bundles/search?category=${id}",
             "callSite": "src/lib/core.ts:12", "side": "server"],
            ["service": "marketplace-core", "resource": "bundles", "method": "GET", "path": "/bundles/{bundleId}", "callSite": "/Users/x/src/a.ts:3", "side": "server"],
            ["service": "marketplace-core", "resource": "bundles", "method": "GET", "path": "https://core.example.test/v1/bundles/[slug]/reviews/", "callSite": "", "side": "browser"],
            ["service": "marketplace-core", "resource": "bundles", "method": "GET", "path": "/bundles/:id", "callSite": "", "side": "server"],
            ["service": "app", "resource": "", "method": "POST", "path": "/api/consents", "callSite": "app/consent.tsx:40", "side": "browser"],
            ["service": "app", "resource": "session", "method": "GET", "path": "/api/auth/session", "callSite": "../outside.ts:1", "side": "browser"],
            ["service": "app", "resource": "session", "method": "GET", "path": "/api/auth/session", "callSite": "", "side": "browser"],
            ["service": "app", "resource": "x", "method": "OPTIONS", "path": "/api/x", "callSite": "", "side": "browser"],
            ["service": "app", "resource": "x", "method": "GET", "path": "/api/../secrets", "callSite": "", "side": "browser"],
            ["service": "Payments", "resource": "intents", "method": "POST", "path": "/v1/payment_intents", "callSite": "", "side": "server"],
        ],
        "notes": ["A WebSocket to wss://live.example.test", "  "],
        "userRoles": ["names": ["customer", "master", "fairy", "support", "admin", "bad role", "customer"], "ordinary": "customer"],
    ]
    let inventory = StudioMapParsing.inventory(from: answer)
    let core = inventory?.services.first { $0.name == "marketplace-core" }
    check("REQ-014 the inventory keeps each service once, with a plain name, its address and its variable",
          inventory?.services.map(\.name) == ["app", "marketplace-core", "payments"] && core?.baseURL == "https://core.example.test/v1"
          && core?.variable == "CORE_URL" && core?.side == .server, "\(inventory?.services ?? [])")
    let paths = inventory?.entries.map { "\($0.service) \($0.endpoint.method) \($0.endpoint.path)" } ?? []
    check("REQ-014 endpoint paths become route templates without the address, the query or a trailing slash",
          paths == ["marketplace-core GET /bundles/search", "marketplace-core GET /bundles/:bundleId", "marketplace-core GET /bundles/:slug/reviews",
                    "app POST /api/consents", "app GET /api/auth/session", "payments POST /v1/payment_intents"], "\(paths)")
    check("REQ-014 the inventory drops unknown methods, paths with .., duplicates (whatever the parameters are called) and call sites outside the project",
          inventory?.entries.count == 6 && inventory?.entries[1].endpoint.callSite == "" && inventory?.entries[4].endpoint.callSite == ""
          && inventory?.entries[0].endpoint.callSite == "src/lib/core.ts:12" && inventory?.entries[3].endpoint.resource == "api",
          "\(inventory?.entries.map(\.endpoint) ?? [])")
    check("REQ-014 an endpoint of a service the answer did not list gets that service, and blank notes are dropped",
          inventory?.services.last?.name == "payments" && inventory?.notes == ["A WebSocket to wss://live.example.test"])
    check("REQ-014 an answer without the inventory's shape is unreadable",
          StudioMapParsing.inventory(from: ["services": [], "endpoints": "GET /x"]) == nil && StudioMapParsing.inventory(from: "text") == nil
          && StudioMapParsing.inventory(from: ["services": [], "endpoints": [], "notes": []])?.entries.isEmpty == true)
    check("REQ-014 the inventory keeps the user roles the code checks and the ordinary one",
          inventory?.roles == ["customer", "master", "fairy", "support", "admin"] && inventory?.ordinaryRole == "customer"
          && StudioMapParsing.inventory(from: ["services": [], "endpoints": [], "userRoles": ["names": [], "ordinary": "client"]])?.roles == ["client"]
          && StudioMapParsing.inventory(from: ["services": [], "endpoints": []])?.roles.isEmpty == true, "\(inventory?.roles ?? [])")
    let vivaaRoles = ["customer", "master", "fairy", "support", "admin"]
    check("REQ-014 the test user gets the ordinary role only when the application does not know its role",
          StudioMapPlanner.testUserRole(current: "member", roles: vivaaRoles, ordinary: "customer") == "customer"
          && StudioMapPlanner.testUserRole(current: "admin", roles: vivaaRoles, ordinary: "customer") == nil
          && StudioMapPlanner.testUserRole(current: "member", roles: [], ordinary: "") == nil
          && StudioMapPlanner.testUserRole(current: "member", roles: vivaaRoles, ordinary: "") == nil)
    let customer = StudioRole.tester(role: "customer")
    check("REQ-014 the built-in test user with the application's role keeps everything else",
          customer.roleName == "customer" && customer.user["email"] == StudioRole.tester.user["email"] && customer.token == StudioRole.tester.token
          && StudioRole.tester(role: nil) == StudioRole.tester && StudioRole.tester.roleName == "member")
    check("REQ-014 the inventory and refill schemas are strict", isStrict(StudioMapPrompts.inventorySchema) && isStrict(StudioMapPrompts.refillSchema))

    // Groups: a resource that fills a group is split, small resources of one service are packed together.
    var big = StudioMapInventory()
    big.services = [StudioMapService(name: "core"), StudioMapService(name: "app")]
    for index in 1...10 { big.entries.append(.init(service: "core", endpoint: StudioMapEndpoint(method: "GET", path: "/bundles/\(index)", resource: "bundles"))) }
    for resource in ["cities", "categories", "fx"] {
        big.entries.append(.init(service: "core", endpoint: StudioMapEndpoint(method: "GET", path: "/\(resource)", resource: resource)))
    }
    for index in 1...6 { big.entries.append(.init(service: "core", endpoint: StudioMapEndpoint(method: "GET", path: "/orders/\(index)", resource: "orders"))) }
    big.entries.append(.init(service: "app", endpoint: StudioMapEndpoint(method: "GET", path: "/api/auth/session", resource: "session")))
    let groups = StudioMapPlanner.groups(big)
    check("REQ-014 the inventory is split into groups of at most eight endpoints by service and resource",
          groups.map(\.id) == ["core/bundles", "core/bundles-2", "core/cities+categories+fx", "core/orders", "app/session"]
          && groups.map(\.endpoints.count) == [8, 2, 3, 6, 1] && groups.allSatisfy { $0.status == .pending },
          "\(groups.map { "\($0.id) \($0.endpoints.count)" })")
    var small = StudioMapLimits()
    small.maxGroups = 2
    check("REQ-014 a map keeps at most maxGroups groups", StudioMapPlanner.groups(big, limits: small).count == 2)

    // Planning: where a group's rules point, and what is already covered.
    let connections = [StudioServerConnection(variable: "CORE_URL", origin: "http://core.example.test", basePath: "/v1", mode: .simulated, foundIn: ".env")]
    let services = StudioMapPlanner.resolve([StudioMapService(name: "app"), StudioMapService(name: "core", baseURL: "https://other.example.test", variable: "CORE_URL"),
                                             StudioMapService(name: "pay", baseURL: "https://pay.example.test/v1"), StudioMapService(name: "unknown")],
                                            connections: connections)
    check("REQ-014 a service's address is its simulated connection's, else its base URL; the application's is its own server",
          services.map(\.address) == ["", "http://core.example.test/v1", "https://pay.example.test/v1", nil], "\(services.map(\.address))")
    let bundle = StudioMapEndpoint(method: "GET", path: "/bundles/:id")
    check("REQ-014 a rule path is the full URL on another service and the path alone on the application's server",
          StudioMapPlanner.rulePath(bundle, service: services[1]) == "http://core.example.test/v1/bundles/:id"
          && StudioMapPlanner.rulePath(bundle, service: services[0]) == "/bundles/:id" && StudioMapPlanner.rulePath(bundle, service: services[3]) == nil)
    let rules = [StudioRule(id: "get-bundle", method: "GET", path: "http://core.example.test/v1/bundles/:bundleId", operation: .get, entity: "bundles")]
    let search = StudioMapEndpoint(method: "GET", path: "/bundles/search")
    check("REQ-014 an endpoint is covered by a registered rule of the same method, origin and route",
          StudioMapPlanner.isCovered(bundle, service: services[1], rules: rules)
          && !StudioMapPlanner.isCovered(StudioMapEndpoint(method: "POST", path: "/bundles/:id"), service: services[1], rules: rules)
          && !StudioMapPlanner.isCovered(bundle, service: services[2], rules: rules)
          && !StudioMapPlanner.isCovered(StudioMapGroup(id: "g", service: "core", resource: "bundles", endpoints: [bundle, StudioMapEndpoint(method: "GET", path: "/cities")]),
                                         service: services[1], rules: rules))
    check("REQ-014 a request matches its endpoint on the service's origin, the application's on its own origin",
          StudioMapPlanner.matches(bundle, service: services[1], method: "get", url: URL(string: "http://core.example.test/v1/bundles/7?x=1")!, appOrigin: nil)
          && !StudioMapPlanner.matches(bundle, service: services[1], method: "GET", url: URL(string: "http://core.example.test/v2/bundles/7")!, appOrigin: nil)
          && !StudioMapPlanner.matches(search, service: services[1], method: "GET", url: URL(string: "http://core.example.test/v1/bundles/7")!, appOrigin: nil)
          && StudioMapPlanner.matches(StudioMapEndpoint(method: "GET", path: "/api/auth/session"), service: services[0], method: "GET",
                                      url: URL(string: "http://localhost:3000/api/auth/session")!, appOrigin: "http://localhost:3000")
          && !StudioMapPlanner.matches(StudioMapEndpoint(method: "GET", path: "/api/auth/session"), service: services[0], method: "GET",
                                       url: URL(string: "http://other.test/api/auth/session")!, appOrigin: "http://localhost:3000"))
    var resumeMap = StudioEnvironmentMap(inventoried: true)
    resumeMap.groups = ["a", "b", "c", "d", "e", "f"].map { StudioMapGroup(id: $0, service: "core", resource: $0, endpoints: [bundle]) }
    resumeMap.groups[1].status = .preparing
    resumeMap.groups[2].status = .done
    resumeMap.groups[3].status = .failed
    resumeMap.groups[3].attempts = 1
    resumeMap.groups[4].status = .failed
    resumeMap.groups[4].attempts = 2
    resumeMap.groups[5].status = .unsupported
    check("REQ-014 a session resumes groups not started, interrupted, or failed in fewer than two sessions",
          StudioMapPlanner.resumable(resumeMap, sessions: 2) == ["a", "b", "d"], "\(StudioMapPlanner.resumable(resumeMap, sessions: 2))")
    check("REQ-014 a completed or cancelled map is not redone; a missing, interrupted or other folder's map is",
          StudioEnvironmentMapper.needsMapping(nil, appFolder: "web")
          && StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .complete, appFolder: "other"), appFolder: "web")
          && StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .mapping, appFolder: "web"), appFolder: "web")
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .complete, appFolder: "web"), appFolder: "web")
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .cancelled, appFolder: "web"), appFolder: "web")
          && StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .failed, appFolder: "web", inventoryAttempts: 2), appFolder: "web")
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .failed, appFolder: "web", inventoryAttempts: 3), appFolder: "web"))

    // Groups share entities: what is already registered is left out of a group's proposal.
    var shared = StudioEnvironmentSpec()
    shared.entities = [StudioEntity(name: "categories", fields: [StudioField(name: "name", type: "string")])]
    shared.rules = [StudioRule(id: "list-categories", method: "GET", path: "http://core.example.test/v1/categories", operation: .list, entity: "categories")]
    var groupProposal = StudioProposal()
    groupProposal.entities = shared.entities
    groupProposal.rules = [StudioRule(id: "list-categories", method: "GET", path: "http://core.example.test/v1/categories", operation: .list, entity: "categories"),
                           StudioRule(id: "list-categories", method: "GET", path: "http://core.example.test/v1/catalog-categories", operation: .list, entity: "categories")]
    groupProposal.records = ["categories": [.object(["id": .string("c1"), "name": .string("Spa")]), .object(["id": .string("c9"), "name": .string("Food")])]]
    let state: [String: [StudioJSON]] = ["categories": [.object(["id": .string("c1"), "name": .string("Spa")])]]
    let (clean, dropped) = StudioMapPlanner.deduplicated(groupProposal, spec: shared, state: state)
    check("REQ-014 a group's proposal leaves out rules and records that exist and renames a rule id in use",
          clean.rules.map(\.id) == ["list-categories-2"] && clean.rules.first?.path.hasSuffix("/catalog-categories") == true
          && clean.records["categories"]?.count == 1 && clean.records["categories"]?.first?["id"]?.stringValue == "c9" && dropped.count == 2,
          "\(clean.rules.map(\.id)) \(dropped)")
    var registeredSim = StudioSimulator(spec: shared, scenario: StudioScenario(id: "s", name: "S", kind: .populated))
    check("REQ-014 the deduplicated proposal registers", registeredSim.register(clean).isEmpty)

    // Map again keeps the project's and the person's rules with the entities they read.
    var prepared = StudioEnvironmentSpec()
    prepared.entities = [StudioEntity(name: "items", fields: [StudioField(name: "cityId", type: "string", references: "cities")]),
                         StudioEntity(name: "cities"), StudioEntity(name: "bundles")]
    prepared.rules = [StudioRule(id: "items", method: "GET", path: "/api/items", operation: .list, entity: "items", origin: .project),
                      StudioRule(id: "bundles", method: "GET", path: "/api/bundles", operation: .list, entity: "bundles", origin: .agent)]
    prepared.seed = ["items": [], "cities": [.object(["id": .string("x")])], "bundles": [.object(["id": .string("b")])]]
    prepared.dependencies = [StudioDependency(id: "GET /api/bundles", mode: .simulated, note: ""), StudioDependency(id: "GET /api/items", mode: .simulated, note: "")]
    prepared.preparedRoutes = ["/"]
    prepared.map = StudioEnvironmentMap(status: .complete, appFolder: "web")
    let fresh = StudioMapPlanner.withoutPrepared(prepared)
    check("REQ-014 Map again removes the assistant's rules and the data only they use, and the map",
          fresh.rules.map(\.id) == ["items"] && fresh.entities.map(\.name) == ["items", "cities"] && fresh.seed.keys.sorted() == ["cities", "items"]
          && fresh.dependencies.map(\.id) == ["GET /api/items"] && fresh.map == nil && fresh.preparedRoutes == nil)

    // An environment written before the map still loads; a damaged map does not make it unreadable.
    let older = #"{"schemaVersion":1,"entities":[{"name":"items","idField":"id","fields":[]}],"rules":[{"id":"list","method":"GET","path":"/api/items","operation":"list","entity":"items","evidence":[],"origin":"project","version":1}],"seed":{},"allowedRequests":[],"confidentialFields":[],"dependencies":[]}"#
    let decodedOlder = try? StudioStore.decoder.decode(StudioEnvironmentSpec.self, from: Data(older.utf8))
    check("REQ-014 an environment file written before the map decodes, without a map", decodedOlder?.rules.count == 1 && decodedOlder?.map == nil)
    let damaged = older.replacingOccurrences(of: #""dependencies":[]}"#, with: #""dependencies":[],"map":{"status":"weird","groups":[{"id":"g1","status":"strange","endpoints":[{"method":"GET","path":"/a"},{"path":"/b"}]},{"service":"no id"},7],"services":"x","started":"yesterday"}}"#)
    let decodedDamaged = try? StudioStore.decoder.decode(StudioEnvironmentSpec.self, from: Data(damaged.utf8))
    check("REQ-014 a damaged map is read leniently and the environment still loads",
          decodedDamaged?.rules.count == 1 && decodedDamaged?.map?.status == .mapping && decodedDamaged?.map?.groups.map(\.id) == ["g1"]
          && decodedDamaged?.map?.groups.first?.status == .pending && decodedDamaged?.map?.groups.first?.endpoints.count == 1
          && decodedDamaged?.map?.services.isEmpty == true && decodedDamaged?.map?.started == nil, "\(String(describing: decodedDamaged?.map))")
    let notObject = older.replacingOccurrences(of: #""dependencies":[]}"#, with: #""dependencies":[],"map":"broken"}"#)
    check("REQ-014 a map that is not an object reads as a map never made",
          (try? StudioStore.decoder.decode(StudioEnvironmentSpec.self, from: Data(notObject.utf8)))?.map.map { !$0.inventoried && $0.groups.isEmpty } == true)
    var saved = StudioEnvironmentMap(status: .complete, appFolder: "web", started: Date(timeIntervalSince1970: 1_800_000_000), inventoried: true,
                                     inventoryAttempts: 1, services: services, notes: ["n"], gaps: ["g"], userRoles: vivaaRoles, ordinaryRole: "customer")
    saved.groups = groups
    saved.groups[0].status = .done
    saved.groups[0].rules = ["r1"]
    var withMap = StudioEnvironmentSpec()
    withMap.map = saved
    withMap.testUserRole = "customer"
    let roundTrip = (try? StudioStore.encoder.encode(withMap)).flatMap { try? StudioStore.decoder.decode(StudioEnvironmentSpec.self, from: $0) }
    check("REQ-014 the map and the test user's role are saved and read back unchanged", roundTrip?.map == saved && roundTrip?.testUserRole == "customer"
          && decodedOlder?.testUserRole == nil && decodedDamaged?.map?.userRoles.isEmpty == true)

    // The coherence check: references between records and the coverage of every value a list filters by.
    var data = StudioEnvironmentSpec()
    data.entities = [StudioEntity(name: "categories", fields: [StudioField(name: "name", type: "string")]),
                     StudioEntity(name: "cities", fields: [StudioField(name: "name", type: "string")]),
                     StudioEntity(name: "bundles", fields: [StudioField(name: "categoryId", type: "string"),
                                                            StudioField(name: "cityId", type: "string", references: "cities"),
                                                            StudioField(name: "status", type: "string", enumValues: ["live", "draft"]),
                                                            StudioField(name: "tagIds", type: "array")]),
                     StudioEntity(name: "orders", fields: [])]
    data.rules = [StudioRule(id: "search", method: "GET", path: "/bundles/search", operation: .list, entity: "bundles", filters: ["categoryId", "status", "limit"]),
                  StudioRule(id: "orders", method: "GET", path: "/orders", operation: .list, entity: "orders")]
    data.seed = [
        "categories": [.object(["id": .string("c1"), "name": .string("Spa")]), .object(["id": .string("c2"), "name": .string("Food")]),
                       .object(["id": .string("c3"), "name": .string("Tours")])],
        "cities": [.object(["id": .string("tlv"), "name": .string("Tel Aviv")])],
        "bundles": (1...6).map { .object(["id": .string("b\($0)"), "categoryId": .string("c1"), "cityId": .string($0 == 6 ? "haifa" : "tlv"),
                                          "status": .string("live")]) },
    ]
    let gaps = StudioCoherence.check(data)
    let dangling = gaps.first { $0.kind == .dangling }
    let uncovered = gaps.filter { $0.kind == .uncovered }
    check("REQ-014 the coherence check finds a reference to a record that does not exist",
          dangling?.entity == "bundles" && dangling?.field == "cityId" && dangling?.values == ["haifa"]
          && dangling?.line.contains("bundles.cityId points at cities that do not exist: haifa") == true, "\(gaps.map(\.line))")
    check("REQ-014 the coherence check finds filter values with no records, through a reference named after its entity and an enumeration",
          uncovered.map(\.field) == ["categoryId", "status"] && uncovered.first?.values == ["c2", "c3"]
          && uncovered.first?.line.contains("c2 (Food), c3 (Tours)") == true && uncovered.last?.values == ["draft"], "\(uncovered.map(\.line))")
    check("REQ-014 the coherence check finds an empty list and ignores paging parameters",
          gaps.contains { $0.kind == .empty && $0.entity == "orders" } && !gaps.contains { $0.field == "limit" } && gaps.count == 4, "\(gaps.map(\.line))")
    var fixed = data
    fixed.seed["bundles"] = ["c1", "c1", "c2", "c2", "c3", "c3"].enumerated().map { index, category in
        .object(["id": .string("b\(index)"), "categoryId": .string(category), "cityId": .string("tlv"), "status": .string(index % 2 == 0 ? "live" : "draft")])
    }
    fixed.seed["orders"] = [.object(["id": .number(1)])]
    check("REQ-014 coherent records leave no gap", StudioCoherence.check(fixed).isEmpty, "\(StudioCoherence.check(fixed).map(\.line))")
    check("REQ-014 entities are refilled after the entities they point at",
          StudioCoherence.refillOrder(["bundles", "categories", "cities"], spec: data) == [["categories", "cities"], ["bundles"]],
          "\(StudioCoherence.refillOrder(["bundles", "categories", "cities"], spec: data))")
    let keep = StudioEnvironmentMapper.referencedIDs(of: "categories", spec: data, seed: data.seed, except: [])
    let bundlesEntity = data.entity("bundles")!
    check("REQ-014 refilled records are checked: types, references, ids used twice and ids others point at",
          keep == ["c1"]
          && !StudioEnvironmentMapper.refillProblems([.object(["id": .string("x"), "name": .string("New")])], entity: data.entity("categories")!,
                                                     spec: data, seed: data.seed, keep: keep, limits: StudioMapLimits()).isEmpty
          && StudioEnvironmentMapper.refillProblems([.object(["id": .string("c1"), "name": .string("Spa")])], entity: data.entity("categories")!,
                                                    spec: data, seed: data.seed, keep: keep, limits: StudioMapLimits()).isEmpty
          && !StudioEnvironmentMapper.refillProblems([.object(["id": .string("b1"), "cityId": .string("nowhere")])], entity: bundlesEntity,
                                                     spec: data, seed: data.seed, keep: [], limits: StudioMapLimits()).isEmpty
          && !StudioEnvironmentMapper.refillProblems([.object(["id": .string("b1")]), .object(["id": .string("b1")])], entity: bundlesEntity,
                                                     spec: data, seed: data.seed, keep: [], limits: StudioMapLimits()).isEmpty)
    let groupText = StudioMapPrompts.groupPrompt(groups[0], service: StudioMapService(name: "core", variable: "CORE_URL", address: "http://core.example.test/v1"),
                                                 context: StudioMapContext(appFolder: "web", appOrigin: nil, connections: connections), spec: data,
                                                 problems: ["bundles: id b1 is used twice"])
    check("REQ-014 a group's prompt has its endpoints with their rule paths, the registered entities with their ids, coverage and the last problems",
          groupText.contains("GET /bundles/1") && groupText.contains("rule path `http://core.example.test/v1/bundles/1`")
          && groupText.contains("categories (id id)") && groupText.contains("c2 \"Food\"") && groupText.contains("2-4 records")
          && groupText.contains("id b1 is used twice") && groupText.contains("CORE_URL → http://core.example.test/v1"))
}

// MARK: - Real-time channels and GraphQL (REQ-015)

func json(_ text: String) -> StudioJSON { StudioJSON(text: text) ?? .null }
func texts(_ frames: [StudioChannelFrame]) -> [String] { frames.compactMap { if case .text(let text) = $0 { return text }; return nil } }


extension StudioHTTPRequest {
    func withID(_ id: String?) -> StudioHTTPRequest {
        var copy = self
        if let id { copy.requestId = id }
        return copy
    }
}

final class SimulatorBox {
    var sim: StudioSimulator
    var changes: [StudioEntityChange] = []
    init(_ sim: StudioSimulator) { self.sim = sim }
}

@MainActor
func channelChecks() async {
    func message(_ data: String, event: String? = nil, topic: String? = nil) -> StudioChannelMessage {
        StudioChannelMessage(event: event, topic: topic, data: json(data))
    }
    var cspec = StudioEnvironmentSpec()
    cspec.entities = [StudioEntity(name: "messages", fields: [StudioField(name: "text", type: "string", required: true), StudioField(name: "room", type: "string")])]
    cspec.seed = ["messages": [json(#"{"id":1,"text":"Hello","room":"general"}"#)]]
    cspec.rules = [StudioRule(id: "messages-create", method: "POST", path: "/api/messages", operation: .create, entity: "messages")]
    cspec.channels = [
        StudioChannel(id: "chat", path: "/ws/chat", wire: .raw, onConnect: [message(#"{"type":"welcome"}"#)],
                      onMessage: [StudioChannelReply(match: ["type": .string("ping")], reply: [message(#"{"type":"pong"}"#)]),
                                  StudioChannelReply(match: ["type": .string("send")], reply: [message(#"{"type":"sent","message":"{{record}}"}"#)],
                                                     entity: "messages", operation: .create, recordPath: "message")],
                      events: [StudioChannelEvent(afterMs: 30, message: message(#"{"type":"tick","n":"{{count}}"}"#))],
                      links: [StudioChannelLink(entity: "messages", on: [.create], message: message(#"{"type":"new","message":"{{record}}"}"#))]),
        StudioChannel(id: "io", path: "/socket.io", wire: .socketio, onConnect: [message(#"{"user":"test"}"#, event: "hello")],
                      onMessage: [StudioChannelReply(match: ["event": .string("get-rooms")], reply: [message(#"["general","random"]"#)]),
                                  StudioChannelReply(match: ["event": .string("chat")], broadcast: [message(#""{{message.data}}""#, event: "chat")])]),
        StudioChannel(id: "realtime", path: "wss://abc.supabase.co/realtime/v1/websocket", wire: .phoenix),
        StudioChannel(id: "gql", path: "/graphql", wire: .graphqlWS),
        StudioChannel(id: "feed", path: "https://api.example.com/events/:room", wire: .raw, onConnect: [message(#"{"room":"{{params.room}}"}"#, event: "hello")]),
    ]
    cspec.graphQL = [StudioGraphQLOperation(id: "s-msg", kind: .subscription, field: "messageAdded", action: .get, entity: "messages", on: [.create]),
                     StudioGraphQLOperation(id: "q-msgs", kind: .query, field: "messages", action: .list, entity: "messages")]
    let box = SimulatorBox(StudioSimulator(spec: cspec, scenario: StudioScenario(id: "s", name: "S", kind: .populated), appOrigin: app))
    var logs: [String] = []
    var pushed: [String: [StudioChannelFrame]] = [:]
    let hub = StudioChannelHub(environment: StudioChannelHub.Environment(
        spec: { box.sim.spec }, state: { box.sim.state }, appOrigin: { app },
        perform: { operation, entity, id, fields in
            let before = box.sim.state
            let response = box.sim.perform(operation, entity: entity, id: id, fields: fields)
            box.changes += StudioEntityChange.diff(before: before, after: box.sim.state, spec: box.sim.spec)
            return response
        },
        graphQL: { url, payload in
            let http = StudioHTTPRequest(method: "POST", url: url, headers: ["content-type": "application/json"], body: payload.text, requestId: UUID().uuidString)
            if case .respond(let response, _) = box.sim.handle(http) { return StudioJSON(text: response.body ?? "") ?? .null }
            return .null
        },
        redact: { StudioRedactor().redact($0) }, log: { text, _ in logs.append(text) }))
    func open(_ id: String, _ url: String, protocols: [String] = [], transport: StudioChannelTransport = .webSocket) -> StudioChannelHub.Opening {
        hub.open(id: id, url: URL(string: url)!, protocols: protocols, transport: transport, source: "page", shown: url,
                 sink: { pushed[id, default: []] += $0 })
    }
    func flushChanges() {
        hub.entitiesChanged(box.changes)
        box.changes = []
    }

    // Matching and templates.
    check("channels: a ws URL matches a channel of the app's origin", StudioChannelRoute.channel(for: URL(string: "ws://localhost:5173/ws/chat")!,
          in: cspec.channels ?? [], appOrigin: app)?.0.id == "chat")
    check("channels: a full-URL channel matches wss and https alike, with parameters",
          StudioChannelRoute.channel(for: URL(string: "https://api.example.com/events/general")!, in: cspec.channels ?? [], appOrigin: app)?.1 == ["room": "general"]
          && StudioChannelRoute.channel(for: URL(string: "wss://abc.supabase.co/realtime/v1/websocket?vsn=1.0.0")!, in: cspec.channels ?? [], appOrigin: app)?.0.id == "realtime")
    check("channels: another origin does not match a path channel", StudioChannelRoute.channel(for: URL(string: "wss://other.example.com/ws/chat")!,
          in: cspec.channels ?? [], appOrigin: app) == nil)
    check("channels: a whole placeholder keeps its JSON value, an embedded one becomes text",
          StudioChannelTemplate.fill(json(#"{"a":"{{record}}","b":"id {{record.id}}!"}"#), ["record": json(#"{"id":7}"#)]) == json(#"{"a":{"id":7},"b":"id 7!"}"#))
    check("channels: match by dotted field and any value", StudioChannelTemplate.matches(["payload.type": .string("*"), "event": .string("x")],
          json(#"{"event":"x","payload":{"type":1}}"#)) && !StudioChannelTemplate.matches(["event": .string("y")], json(#"{"event":"x"}"#)))
    if case .unknown(let contract) = open("u1", "ws://localhost:5173/other/7") {
        check("channels: an address no channel answers is prepared by its contract", contract == "WS /other/:id", contract)
    } else { check("channels: unknown address", false) }
    if case .unknown(let contract) = open("u2", "https://api.example.com/stream", transport: .eventSource) {
        check("channels: an unknown event stream keeps its origin in the contract", contract == "SSE https://api.example.com/stream", contract)
    } else { check("channels: unknown event stream", false) }

    // Raw JSON: connect message, reply, a write that the link pushes to every connection, a REST write pushed too.
    if case .accepted(_, let welcome) = open("a", "ws://localhost:5173/ws/chat") {
        check("raw: the connect message arrives with the open", texts(welcome) == [#"{"type":"welcome"}"#], "\(welcome)")
    } else { check("raw: open", false) }
    _ = open("b", "ws://localhost:5173/ws/chat")
    check("raw: a matched message gets its reply", texts(hub.receive(id: "a", text: #"{"type":"ping"}"#)) == [#"{"type":"pong"}"#])
    let sent = texts(hub.receive(id: "a", text: #"{"type":"send","message":{"text":"Hi","room":"general"}}"#))
    check("raw: a message that creates a record answers with it", sent.count == 1 && json(sent[0])["message"]?["id"] == .number(2)
          && box.sim.state["messages"]?.count == 2, "\(sent)")
    flushChanges()
    check("raw: the link pushes the new record to the other connection",
          texts(pushed["b"] ?? []).contains { json($0)["type"] == .string("new") && json($0)["message"]?["text"] == .string("Hi") }, "\(pushed["b"] ?? [])")
    let before = box.sim.state
    _ = box.sim.handle(request("POST", "/api/messages", body: #"{"text":"From REST"}"#))
    hub.entitiesChanged(StudioEntityChange.diff(before: before, after: box.sim.state, spec: box.sim.spec))
    check("raw: a REST create reaches the subscriber through the link",
          texts(pushed["b"] ?? []).contains { json($0)["message"]?["text"] == .string("From REST") })
    check("raw: an unmatched message is logged, not answered", hub.receive(id: "a", text: "plain words").isEmpty
          && logs.contains { $0.contains("no channel rule answers") })
    try? await Task.sleep(nanoseconds: 200_000_000)
    check("raw: a timed event is pushed", texts(pushed["a"] ?? []).contains(#"{"n":1,"type":"tick"}"#), "\(pushed["a"] ?? [])")
    check("raw: an oversized message closes the connection with 1009",
          hub.receive(id: "b", text: String(repeating: "x", count: StudioChannelHub.maxMessage + 1)) == [.close(code: 1009, reason: "The message is larger than 1000000 bytes.")]
          && hub.connections["b"] == nil)
    if case .accepted(_, let hello) = open("f", "wss://api.example.com/events/sales", transport: .eventSource) {
        check("raw: an event stream sends named events with path parameters", hello == [.event(name: "hello", data: #"{"room":"sales"}"#, id: nil)], "\(hello)")
    } else { check("raw: event stream", false) }

    // Socket.IO over a WebSocket: open packet, namespace connect, greeting, acknowledgements, broadcast.
    if case .accepted(_, let opened) = open("io1", "ws://localhost:5173/socket.io/?EIO=4&transport=websocket") {
        let packet = texts(opened).first ?? ""
        check("socket.io: the Engine.IO open packet stays on this transport", packet.hasPrefix("0{") && packet.contains(#""upgrades":[]"#)
              && packet.contains(#""pingInterval":25000"#), packet)
    } else { check("socket.io: open", false) }
    let connected = texts(hub.receive(id: "io1", text: "40"))
    check("socket.io: connect answers with a sid and the greeting", connected.count == 2 && connected[0].hasPrefix(#"40{"sid":"#)
          && connected[1] == #"42["hello",{"user":"test"}]"#, "\(connected)")
    check("socket.io: an emit with a callback gets the reply as its acknowledgement",
          texts(hub.receive(id: "io1", text: #"421["get-rooms"]"#)) == [#"431[["general","random"]]"#])
    check("socket.io: an unanswered callback still gets an empty acknowledgement", texts(hub.receive(id: "io1", text: #"422["nobody"]"#)) == ["432[]"])
    check("socket.io: a ping is answered with a pong", texts(hub.receive(id: "io1", text: "2")) == ["3"])
    _ = open("io2", "ws://localhost:5173/socket.io/?EIO=4&transport=websocket")
    _ = hub.receive(id: "io2", text: "40")
    _ = hub.receive(id: "io1", text: #"42["chat",{"text":"yo"}]"#)
    check("socket.io: a broadcast reaches the other socket", texts(pushed["io2"] ?? []).contains(#"42["chat",{"text":"yo"}]"#), "\(pushed["io2"] ?? [])")

    // Socket.IO over HTTP long-polling.
    var polls: [StudioSimResponse] = []
    func poll(_ method: String, _ query: String, body: String? = nil) -> Bool {
        hub.poll(StudioHTTPRequest(method: method, url: URL(string: app + "/socket.io/?EIO=4&transport=polling" + query)!, body: body, requestId: UUID().uuidString),
                 source: "page", shown: "polling", reply: { polls.append($0) })
    }
    check("polling: a request without EIO is not a poll", !hub.poll(request("GET", "/socket.io/"), source: "page", shown: "", reply: { _ in }))
    _ = poll("GET", "&t=1")
    let sid = (polls.first?.body).flatMap { StudioJSON(text: String($0.dropFirst())) }?["sid"]?.stringValue ?? ""
    check("polling: the handshake opens a session", polls.first?.body?.hasPrefix("0{") == true && !sid.isEmpty, polls.first?.body ?? "nil")
    _ = poll("POST", "&sid=\(sid)", body: "40")
    check("polling: a POST of packets answers ok", polls.last?.body == "ok")
    _ = poll("GET", "&sid=\(sid)")
    let batch = polls.last?.body?.split(separator: "\u{1e}").map(String.init) ?? []
    check("polling: the next GET carries the connect answer and the greeting", batch.count == 2 && batch[0].hasPrefix("40{") && batch[1].hasPrefix(#"42["hello""#),
          polls.last?.body ?? "nil")
    let waitingCount = polls.count
    _ = poll("GET", "&sid=\(sid)")
    check("polling: a GET with nothing to send waits", polls.count == waitingCount)
    _ = poll("POST", "&sid=\(sid)", body: #"421["get-rooms"]"#)
    check("polling: the waiting GET gets the acknowledgement", polls.contains { $0.body == #"431[["general","random"]]"# }, "\(polls.map { $0.body ?? "" })")
    _ = poll("GET", "&sid=unknown")
    check("polling: an unknown sid is refused", polls.last?.status == 400)

    // Supabase Realtime (Phoenix): join with postgres_changes, heartbeat, a change pushed to the matching binding.
    if case .accepted(_, let none) = open("ph1", "wss://abc.supabase.co/realtime/v1/websocket?apikey=test-key&vsn=1.0.0") {
        check("phoenix: nothing is sent before a join", none.isEmpty)
    } else { check("phoenix: open", false) }
    let join = texts(hub.receive(id: "ph1", text: #"{"topic":"realtime:public:messages","event":"phx_join","payload":{"config":{"broadcast":{"self":false},"presence":{"key":""},"postgres_changes":[{"event":"INSERT","schema":"public","table":"messages"}]},"access_token":"test-token"},"ref":"1","join_ref":"1"}"#))
    let joinReply = join.first.map(json) ?? .null
    let binding = joinReply["payload"]?["response"]?["postgres_changes"]?.arrayValue?.first
    check("phoenix: the join reply echoes the bindings with ids and no invented filter",
          joinReply["event"] == .string("phx_reply") && joinReply["payload"]?["status"] == .string("ok") && joinReply["ref"] == .string("1")
          && binding?["table"] == .string("messages") && binding?["event"] == .string("INSERT") && binding?["id"]?.numberValue != nil
          && binding?["filter"] == nil, join.first ?? "nil")
    check("phoenix: presence is announced on join", join.contains { json($0)["event"] == .string("presence_state") })
    check("phoenix: a heartbeat is answered", texts(hub.receive(id: "ph1", text: #"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"2"}"#)).first.map(json)?["payload"]?["status"] == .string("ok"))
    pushed["ph1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .create, record: json(#"{"id":9,"text":"Live"}"#), old: nil)])
    let change = texts(pushed["ph1"] ?? []).first.map(json) ?? .null
    check("phoenix: an insert is pushed as postgres_changes to the binding",
          change["event"] == .string("postgres_changes") && change["payload"]?["ids"] == .array([binding?["id"] ?? .null])
          && change["payload"]?["data"]?["type"] == .string("INSERT") && change["payload"]?["data"]?["record"]?["text"] == .string("Live")
          && change["payload"]?["data"]?["table"] == .string("messages"), change.text)
    pushed["ph1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .update, record: json(#"{"id":9,"text":"Edited"}"#), old: json(#"{"id":9,"text":"Live"}"#))])
    check("phoenix: an update does not reach an INSERT binding", (pushed["ph1"] ?? []).isEmpty)
    _ = open("ph2", "wss://abc.supabase.co/realtime/v1/websocket?vsn=2.0.0")
    let arrayJoin = texts(hub.receive(id: "ph2", text: #"["1","1","realtime:room","phx_join",{"config":{"broadcast":{"self":true}}}]"#))
    check("phoenix: vsn 2.0.0 answers in arrays", arrayJoin.first.map(json)?.arrayValue?[3] == .string("phx_reply"), "\(arrayJoin)")
    let echo = texts(hub.receive(id: "ph2", text: #"[null,"2","realtime:room","broadcast",{"type":"broadcast","event":"typing","payload":{"u":1}}]"#))
    check("phoenix: broadcast with self comes back", echo.first.map(json)?.arrayValue?[3] == .string("broadcast")
          && echo.first.map(json)?.arrayValue?[4]["event"] == .string("typing"), "\(echo)")

    // GraphQL over WebSocket (graphql-transport-ws): ack, a query answered at once, a subscription pushed by a write.
    if case .accepted(let chosen, _) = open("g1", "ws://localhost:5173/graphql", protocols: ["graphql-transport-ws"]) {
        check("graphql-ws: the subprotocol is chosen", chosen == "graphql-transport-ws")
    } else { check("graphql-ws: open", false) }
    check("graphql-ws: connection_init is acknowledged", texts(hub.receive(id: "g1", text: #"{"type":"connection_init","payload":{}}"#)) == [#"{"type":"connection_ack"}"#])
    check("graphql-ws: a subscription waits for writes", hub.receive(id: "g1", text: #"{"id":"1","type":"subscribe","payload":{"query":"subscription { messageAdded { id text __typename } }"}}"#).isEmpty)
    let queried = texts(hub.receive(id: "g1", text: #"{"id":"2","type":"subscribe","payload":{"query":"{ messages { text } }"}}"#))
    check("graphql-ws: a query is answered with next and complete", queried.count == 2 && json(queried[0])["type"] == .string("next")
          && json(queried[0])["payload"]?["data"]?["messages"]?.arrayValue?.isEmpty == false && json(queried[1])["type"] == .string("complete"), "\(queried)")
    pushed["g1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .create, record: json(#"{"id":10,"text":"Sub"}"#), old: nil)])
    check("graphql-ws: a create is pushed to the subscription", texts(pushed["g1"] ?? []).first.map(json) == json(#"{"id":"1","type":"next","payload":{"data":{"messageAdded":{"id":10,"text":"Sub","__typename":"Message"}}}}"#),
          "\(pushed["g1"] ?? [])")
    _ = hub.receive(id: "g1", text: #"{"id":"1","type":"complete"}"#)
    pushed["g1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .create, record: json(#"{"id":11,"text":"After"}"#), old: nil)])
    check("graphql-ws: complete ends the subscription", (pushed["g1"] ?? []).isEmpty)
    let missing = texts(hub.receive(id: "g1", text: #"{"id":"3","type":"subscribe","payload":{"query":"subscription { nothing { id } }"}}"#))
    check("graphql-ws: a subscription without a rule is a named error", missing.first.map(json)?["type"] == .string("error"), "\(missing)")

    // Changes between states; closing.
    let diff = StudioEntityChange.diff(before: ["messages": [json(#"{"id":1,"text":"a"}"#), json(#"{"id":2,"text":"b"}"#)]],
                                       after: ["messages": [json(#"{"id":1,"text":"A"}"#), json(#"{"id":3,"text":"c"}"#)]], spec: cspec)
    check("changes: update, create and delete by id", diff.map(\.kind) == [.update, .create, .delete], "\(diff.map(\.kind))")
    pushed["a"] = []
    hub.closeAll(source: "page", code: 1012, reason: "reset")
    check("channels: the session closes connections with a close frame", pushed["a"]?.last == .close(code: 1012, reason: "reset") && hub.connections.isEmpty)
    check("channels: opens and closes are logged", logs.contains { $0.contains("open · raw channel chat") } && logs.contains { $0.contains("closed 1012") })
}


// MARK: - Electron preload bridge (REQ-016)

@MainActor
func ipcChecks() async {
    // The verb convention, the same as the page runtime's (the web harness compares both).
    let verbs = ["getDocument": "GET", "listBrokers": "GET", "loadState": "GET", "fetchAiModels": "GET", "readFile": "GET", "findOrder": "GET",
                 "queryBars": "GET", "isConnected": "GET", "hasKey": "GET", "canTrade": "GET", "deleteBroker": "DELETE", "removeItem": "DELETE",
                 "clearCache": "DELETE", "updateBroker": "PATCH", "patchOrder": "PATCH", "saveBroker": "PUT", "setTheme": "PUT", "put": "PUT",
                 "resetDocument": "PUT", "importSettings": "PUT", "testConnection": "POST", "issue": "POST", "getter": "POST",
                 "settings:get-document": "GET", "order:submit": "POST", "settings:delete_broker": "DELETE", "GetAll": "GET",
                 "constructor": "POST", "toString": "POST", "": "POST", "settings:": "POST", "_internal.save": "PUT"]
    let wrong = verbs.filter { StudioIPC.verb(of: $0.key) != $0.value }.map { "\($0.key) → \(StudioIPC.verb(of: $0.key))" }
    check("REQ-016 a bridge method's verb follows its name's first word, a channel's its last part", wrong.isEmpty, wrong.joined(separator: ", "))
    check("REQ-016 an endpoint path's verb is its method's, or its channel's after invoke",
          StudioIPC.verb(ofPath: "/desk/settings/getBroker/:id") == "GET"
          && StudioIPC.verb(ofPath: "/electron/ipcRenderer/invoke/settings:get-document") == "GET"
          && StudioIPC.verb(ofPath: "/electron/ipcRenderer/invoke/order%3Asubmit/:id") == "POST"
          && StudioIPC.verb(ofPath: "/desk/brokers/deleteBroker/:id") == "DELETE" && StudioIPC.verb(ofPath: "/:only") == nil)
    check("REQ-016 only http://electron.ipc is the bridge's address",
          StudioIPC.isIPC(URL(string: "http://electron.ipc/desk/settings/getDocument")!) && !StudioIPC.isIPC(URL(string: "https://electron.ipc/x")!)
          && !StudioIPC.isIPC(URL(string: "http://electron.ipc:8080/x")!) && !StudioIPC.isIPC(URL(string: "http://evil.electron.ipc/x")!)
          && StudioIPC.isIPC(path: "http://electron.ipc/desk/x") && !StudioIPC.isIPC(path: "/api/x"))

    // The bridge's messages: a call is a request with the ipc transport, a callback a channel with it; both only at the bridge.
    let ipcOrigin = StudioBridge.Origin(url: URL(string: app)!)!
    let expected = StudioBridge.Expectation(session: "s-1", generation: 3, origin: ipcOrigin)
    func message(_ fields: [String: Any]) -> [String: Any] { ["session": "s-1", "generation": 3].merging(fields) { _, new in new } }
    let call = message(["kind": "request", "requestId": "g3-1-x", "method": "PUT", "url": "http://electron.ipc/desk/settings/saveBroker",
                        "headers": ["content-type": "application/json", StudioIPC.argumentsHeader: #"[{"id":"b1"}]"#], "body": #"{"id":"b1"}"#,
                        "transport": "ipc"])
    var parsedCall: StudioBridge.Request?
    if case .success(.request(let parsed)) = StudioBridge.validate(call, isMainFrame: true, origin: ipcOrigin, expecting: expected) { parsedCall = parsed }
    check("REQ-016 a bridge call is a request with the ipc transport", parsedCall?.transport == "ipc" && parsedCall?.method == "PUT")
    var elsewhere = call
    elsewhere["url"] = app + "/api/brokers"
    let elsewhereResult = StudioBridge.validate(elsewhere, isMainFrame: true, origin: ipcOrigin, expecting: expected)
    check("REQ-016 the ipc transport is refused for another address", elsewhereResult == .failure(.malformed("ipc url")), "\(elsewhereResult)")
    let listen = message(["kind": "channel", "action": "open", "id": "c3-1-x", "url": "http://electron.ipc/desk/settings/onDocumentApplied",
                          "protocols": [String](), "transport": "ipc"])
    var parsedListen: StudioBridge.Channel?
    if case .success(.channel(let parsed)) = StudioBridge.validate(listen, isMainFrame: true, origin: ipcOrigin, expecting: expected) { parsedListen = parsed }
    var wrongListen = listen
    wrongListen["url"] = "ws://localhost:5173/ws"
    check("REQ-016 a bridge callback is a channel with the ipc transport, only at the bridge's address", parsedListen?.transport == .ipc
          && StudioBridge.validate(wrongListen, isMainFrame: true, origin: ipcOrigin, expecting: expected) == .failure(.malformed("ipc url")))

    // The arguments header is redacted field by field before it reaches a prompt or the log.
    let fakeKey = "sk-" + String(repeating: "q7", count: 12)
    let header = StudioRedactor().redact(headers: [StudioIPC.argumentsHeader: #"[{"name":"Paper","apiKey":"plain-value"},"\#(fakeKey)",3]"#])
    let redactedArgs = header[StudioIPC.argumentsHeader] ?? ""
    check("REQ-016 the arguments header is redacted field by field and for credential shapes",
          !redactedArgs.contains("plain-value") && !redactedArgs.contains(fakeKey) && redactedArgs.contains("Paper") && redactedArgs.contains("[redacted]"),
          redactedArgs)

    // The map: its version, lenient decoding, and an older map of an Electron renderer extended with the preload bridge.
    check("REQ-016 a new map has the current version; a completed older map of an Electron renderer is outdated, of a web app not",
          StudioEnvironmentMap().version == StudioEnvironmentMap.currentVersion
          && StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, version: 1).isOutdated(electron: true)
          && !StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, version: 1).isOutdated(electron: false)
          && !StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true).isOutdated(electron: true))
    let oldMap = StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, inventoryAttempts: 3, version: 1)
    check("REQ-016 a session maps again only an outdated completed map of an Electron renderer",
          StudioEnvironmentMapper.needsMapping(oldMap, appFolder: "web", electron: true)
          && !StudioEnvironmentMapper.needsMapping(oldMap, appFolder: "web", electron: false)
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true), appFolder: "web", electron: true)
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .cancelled, appFolder: "web", inventoried: true, version: 1),
                                                   appFolder: "web", electron: true))
    let ipcRoot = tmp.appendingPathComponent("ipc-environment")
    var stored = StudioEnvironmentSpec()
    stored.rules = [StudioRule(id: "list-orders", method: "GET", path: "https://api.example.test/orders", operation: .list, entity: "orders")]
    stored.entities = [StudioEntity(name: "orders")]
    stored.map = StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, inventoryAttempts: 1,
                                      services: [StudioMapService(name: "api", baseURL: "https://api.example.test", address: "https://api.example.test")],
                                      groups: [StudioMapGroup(id: "api/orders", service: "api", resource: "orders",
                                                              endpoints: [StudioMapEndpoint(method: "GET", path: "/orders", resource: "orders")],
                                                              status: .done, rules: ["list-orders"])])
    try? StudioStore.saveEnvironment(stored, root: ipcRoot)
    let environmentFile = StudioStore.environmentURL(ipcRoot)
    var written = (try? String(contentsOf: environmentFile, encoding: .utf8)) ?? ""
    check("REQ-016 the map is saved with its version", written.contains("\"version\" : 2") || written.contains("\"version\":2"), String(written.prefix(200)))
    // The map's version is its last key (sorted); a rule's own version is 1.
    written = written.replacingOccurrences(of: #",\s*"version"\s*:\s*2"#, with: "", options: .regularExpression)
    try? written.write(to: environmentFile, atomically: true, encoding: .utf8)
    let reloaded = StudioStore.loadEnvironment(ipcRoot)
    check("REQ-016 an environment saved before map versions loads, its map as version 1 with its groups and rules",
          !written.contains("\"version\" : 2") && reloaded?.map?.version == 1 && reloaded?.map?.groups.first?.status == .done
          && reloaded?.rules.first?.id == "list-orders" && reloaded?.map?.isOutdated(electron: true) == true,
          "\(String(describing: reloaded?.map))")

    let answer: [String: Any] = [
        "services": [["name": "api", "baseURL": "https://api.example.test", "variable": "", "side": "browser"],
                     ["name": "electron-ipc", "baseURL": "", "variable": "WRONG", "side": "server"]],
        "endpoints": [
            ["service": "api", "resource": "orders", "method": "GET", "path": "/orders", "callSite": "src/api.ts:3", "side": "browser"],
            ["service": "electron-ipc", "resource": "settings", "method": "POST", "path": "/desk/settings/getDocument", "callSite": "src/preload.ts:60", "side": "browser"],
            ["service": "electron-ipc", "resource": "settings", "method": "GET", "path": "http://electron.ipc/desk/settings/saveDocument/:expectedRevision",
             "callSite": "src/preload.ts:62", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/getBrokers", "callSite": "src/preload.ts:70", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/saveBroker", "callSite": "src/preload.ts:71", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/deleteBroker/:id", "callSite": "src/preload.ts:72", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/testConnection/:id", "callSite": "src/preload.ts:73", "side": "browser"],
        ],
        "notes": ["onDocumentApplied(cb) is a subscription"], "userRoles": ["names": [], "ordinary": ""]]
    let inventory = StudioMapParsing.inventory(from: answer)
    let methods = inventory?.entries.filter { $0.service == StudioIPC.service }.map { "\($0.endpoint.method) \($0.endpoint.path)" } ?? []
    check("REQ-016 the inventory gives the bridge its logical address and each method the verb the page calls it with",
          inventory?.services.first { $0.name == StudioIPC.service }?.baseURL == StudioIPC.origin
          && inventory?.services.first { $0.name == StudioIPC.service }?.variable == ""
          && methods == ["GET /desk/settings/getDocument", "PUT /desk/settings/saveDocument/:expectedRevision", "GET /desk/settings/getBrokers",
                         "PUT /desk/settings/saveBroker", "DELETE /desk/settings/deleteBroker/:id", "POST /desk/settings/testConnection/:id"],
          "\(methods)")
    let unlisted = StudioMapParsing.inventory(from: ["services": [], "endpoints": [
        ["service": "electron-ipc", "resource": "x", "method": "GET", "path": "/desk/clearAll", "callSite": "", "side": "browser"]]])
    check("REQ-016 a bridge endpoint whose service the answer did not list still gets the bridge's address",
          unlisted?.services.first?.baseURL == StudioIPC.origin && unlisted?.entries.first?.endpoint.method == "DELETE")

    // A page call prepared the document's getter before the map was extended: only what has no rule gets a group.
    var rules = stored.rules
    rules.append(StudioRule(id: "get-document", method: "GET", path: "http://electron.ipc/desk/settings/getDocument", operation: .respond,
                            response: StudioFixedResponse(status: 200, body: .object([:]))))
    var withIPCGroup = oldMap
    withIPCGroup.services = stored.map?.services ?? []
    withIPCGroup.groups = (stored.map?.groups ?? []) + [StudioMapGroup(id: "electron-ipc/settings+brokers", service: "other", resource: "x", endpoints: [])]
    if let inventory {
        let (extended, added) = StudioMapPlanner.extended(withIPCGroup, with: inventory, rules: rules, connections: [], limits: StudioMapLimits())
        let addedEndpoints = added.flatMap { $0.endpoints.map { "\($0.method) \($0.path)" } }
        check("REQ-016 an extended map keeps its groups and adds groups only for endpoints with no rule and no group",
              extended.groups.prefix(2).map(\.id) == ["api/orders", "electron-ipc/settings+brokers"] && extended.groups.first?.status == .done
              && extended.groups.first?.rules == ["list-orders"]
              && addedEndpoints == ["PUT /desk/settings/saveDocument/:expectedRevision", "GET /desk/settings/getBrokers", "PUT /desk/settings/saveBroker",
                                    "DELETE /desk/settings/deleteBroker/:id", "POST /desk/settings/testConnection/:id"]
              && added.allSatisfy { $0.status == .pending && $0.service == StudioIPC.service }, "\(addedEndpoints) \(extended.groups.map(\.id))")
        check("REQ-016 new group ids do not clash with the old ones; the map has the bridge's service and the current version",
              Set(extended.groups.map(\.id)).count == extended.groups.count && added.map(\.id) == ["electron-ipc/settings+brokers-2"]
              && extended.service(StudioIPC.service)?.address == StudioIPC.origin && extended.version == StudioEnvironmentMap.currentVersion
              && extended.notes == ["onDocumentApplied(cb) is a subscription"], "\(added.map(\.id))")
        let again = StudioMapPlanner.extended(extended, with: inventory, rules: rules, connections: [], limits: StudioMapLimits())
        check("REQ-016 extending twice adds nothing more", again.added.isEmpty && again.map.groups.count == extended.groups.count)
        check("REQ-016 every new endpoint is covered by a rule at the bridge's address once prepared",
              StudioMapPlanner.rulePath(added[0].endpoints[0], service: extended.service(StudioIPC.service))
                == "http://electron.ipc/desk/settings/saveDocument/:expectedRevision")
    } else {
        check("REQ-016 the inventory with the bridge is readable", false)
    }

    // What the prompts say about the bridge (DEC-007 included), and what the Environment panel shows.
    let electronContext = StudioMapContext(appFolder: "app", appOrigin: nil, connections: [], electron: true)
    let ipcContext = StudioPreparationContext(contract: "GET http://electron.ipc/desk/settings/getDocument", method: "GET",
                                              url: "http://electron.ipc/desk/settings/getDocument", headers: [StudioIPC.argumentsHeader: "[]"],
                                              body: nil, attempt: 1, problems: [])
    let preparation = StudioPrompts.preparationPrompt(ipcContext, spec: StudioEnvironmentSpec(), appFolder: "app")
    check("REQ-016 the prompts explain the bridge's address, where its answers are found, entities and DEC-007",
          StudioPrompts.preparationSystem.contains("http://electron.ipc/<global>/<path>/<method>")
          && StudioPrompts.preparationSystem.contains("ipcMain.handle") && StudioPrompts.preparationSystem.contains("testConnection")
          && StudioPrompts.preparationSystem.contains("saves and deletes change") && StudioPrompts.preparationSystem.contains(StudioIPC.argumentsHeader)
          && StudioMapPrompts.inventorySystem.contains("`electron-ipc`") && StudioMapPrompts.inventorySystem.contains("/desk/settings/getBroker/:id")
          && StudioMapPrompts.inventoryPrompt(electronContext).contains("This is an Electron renderer")
          && !StudioMapPrompts.inventoryPrompt(StudioMapContext(appFolder: "app", appOrigin: nil, connections: [])).contains("Electron renderer")
          && preparation.contains("A call of the Electron preload bridge") && preparation.contains(StudioIPC.argumentsHeader))
    var bridgeSpec = StudioEnvironmentSpec()
    bridgeSpec.rules = rules
    bridgeSpec.channels = [StudioChannel(id: "applied", path: "http://electron.ipc/desk/settings/onDocumentApplied")]
    check("REQ-016 the Environment panel counts the bridge's simulated methods",
          StudioIPC.summary(bridgeSpec, globals: ["desk"]) == "simulated (2 methods) · window.desk"
          && StudioIPC.summary(StudioEnvironmentSpec(), globals: []) == "simulated (0 methods)", StudioIPC.summary(bridgeSpec, globals: ["desk"]))

    // A callback waits for its channel and gets what the channel pushes once one is registered.
    var ispec = StudioEnvironmentSpec()
    ispec.entities = [StudioEntity(name: "documents")]
    ispec.seed = ["documents": [json(#"{"id":"current","theme":"dark"}"#)]]
    let box = SimulatorBox(StudioSimulator(spec: ispec, scenario: StudioScenario(id: "s", name: "S", kind: .populated), appOrigin: app))
    var logs: [String] = []
    var pushed: [String: [StudioChannelFrame]] = [:]
    let hub = StudioChannelHub(environment: StudioChannelHub.Environment(
        spec: { box.sim.spec }, state: { box.sim.state }, appOrigin: { app },
        perform: { _, _, _, _ in .json(501, nil) }, graphQL: { _, _ in .null }, redact: { $0 }, log: { text, _ in logs.append(text) }))
    let address = URL(string: "http://electron.ipc/desk/settings/onDocumentApplied")!
    let listening = hub.listen(id: "page-c1", url: address, transport: .ipc, source: "page", shown: address.absoluteString,
                               sink: { pushed["page-c1", default: []] += $0 })
    check("REQ-016 a callback no channel answers yet is accepted and waits, without a preparation",
          listening == .accepted(protocol: nil, frames: []) && hub.connections.isEmpty
          && logs.contains { $0.contains("IPC callback http://electron.ipc/desk/settings/onDocumentApplied · page · listening") }, logs.joined(separator: "\n"))
    var registered = box.sim.spec
    registered.channels = [StudioChannel(id: "applied", path: "http://electron.ipc/desk/settings/onDocumentApplied", wire: .raw,
                                         onConnect: [StudioChannelMessage(data: json(#"{"ready":true}"#))],
                                         links: [StudioChannelLink(entity: "documents", on: [.update], message: StudioChannelMessage(data: .string("{{record}}")))])]
    box.sim.replaceSpec(registered)
    hub.openListeners()
    check("REQ-016 a waiting callback opens when its channel is registered and gets its first message", hub.connections["page-c1"] != nil
          && texts(pushed["page-c1"] ?? []) == [#"{"ready":true}"#], "\(pushed)")
    hub.entitiesChanged([StudioEntityChange(entity: "documents", kind: .update, record: json(#"{"id":"current","theme":"light"}"#),
                                            old: json(#"{"id":"current","theme":"dark"}"#))])
    check("REQ-016 a write of the linked entity reaches the callback", texts(pushed["page-c1"] ?? []).last == #"{"id":"current","theme":"light"}"#,
          "\(texts(pushed["page-c1"] ?? []))")
    _ = hub.listen(id: "page-c2", url: URL(string: "http://electron.ipc/desk/orders/onOrderUpdate")!, transport: .ipc, source: "page",
                   shown: "onOrderUpdate", sink: { _ in })
    hub.close(id: "page-c2", code: nil)
    var more = box.sim.spec
    more.channels = (more.channels ?? []) + [StudioChannel(id: "orders", path: "http://electron.ipc/desk/orders/onOrderUpdate")]
    box.sim.replaceSpec(more)
    hub.openListeners()
    check("REQ-016 an unsubscribed callback does not open later", hub.connections["page-c2"] == nil)
    _ = hub.listen(id: "page-c3", url: URL(string: "http://electron.ipc/desk/x/onLater")!, transport: .ipc, source: "page", shown: "onLater", sink: { _ in })
    hub.closeAll(source: "page")
    more.channels = (more.channels ?? []) + [StudioChannel(id: "later", path: "http://electron.ipc/desk/x/onLater")]
    box.sim.replaceSpec(more)
    hub.openListeners()
    check("REQ-016 a new page drops the callbacks of the old one", hub.connections.isEmpty)
}

// MARK: - Fix data (REQ-017)



// MARK: - Run

let done = DispatchSemaphore(value: 0)
Task { @MainActor in
    await preparationChecks()
    await changeChecks()
    await logChecks()
    await environmentMapChecks()
    await channelChecks()
    await ipcChecks()
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
print(failures == 0 ? "All UI Studio checks passed." : "\(failures) UI Studio check(s) failed.")
exit(failures == 0 ? 0 : 1)
