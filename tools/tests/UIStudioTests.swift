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

let app = "http://localhost:5173"
var requestCounter = 0
func request(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:], id: String? = nil) -> StudioHTTPRequest {
    requestCounter += 1
    return StudioHTTPRequest(method: method, url: URL(string: app + path)!, headers: headers, body: body, requestId: id ?? "r\(requestCounter)")
}
// MARK: - Bounded preparation (SIM-07…SIM-10, AC-05…AC-07)

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
    await changeChecks()
    await environmentMapChecks()
    await channelChecks()
    await ipcChecks()
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
print(failures == 0 ? "All UI Studio checks passed." : "\(failures) UI Studio check(s) failed.")
exit(failures == 0 ? 0 : 1)
