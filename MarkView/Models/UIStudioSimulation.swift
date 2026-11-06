import Foundation

/// A request the page made through fetch or XMLHttpRequest, as the simulation sees it.
struct StudioHTTPRequest: Equatable {
    var method: String
    /// The full URL as the page asked for it.
    var url: URL
    /// Lower-cased header names.
    var headers: [String: String] = [:]
    var body: String? = nil
    /// Set by the page runtime for every call: a write is applied at most once per id (SIM-09).
    var requestId: String

    var path: String { url.path.isEmpty ? "/" : url.path }
    var query: [String: String] {
        var items: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { items[item.name] = item.value ?? "" }
        return items
    }
    var jsonBody: StudioJSON? { body.flatMap { StudioJSON(text: $0) } }
    /// The client's own idempotency key, when it sends one.
    var idempotencyKey: String? { headers["idempotency-key"] ?? headers["x-idempotency-key"] }
    var isWrite: Bool { !["GET", "HEAD", "OPTIONS"].contains(method) }
}

/// An answer of the simulation.
struct StudioSimResponse: Equatable, Codable {
    var status: Int
    var headers: [String: String] = ["content-type": "application/json"]
    var body: String?
    var delayMs = 0
    /// The page keeps the request pending (the loading state).
    var hang = false

    static func json(_ status: Int, _ value: StudioJSON?, delayMs: Int = 0) -> StudioSimResponse {
        StudioSimResponse(status: status, body: value?.text, delayMs: delayMs)
    }

    /// What an unknown request gets when it cannot be answered (SIM-08): a controlled error, never the real service.
    static func unresolved(_ contract: String, reason: String) -> StudioSimResponse {
        var response = json(503, .object([
            "error": .string("markview_simulation_unresolved"),
            "contract": .string(contract),
            "message": .string("MarkView UI Studio has no simulation rule for \(contract): \(reason) The request did not reach any real service."),
        ]))
        response.headers["x-markview-simulation"] = "unresolved"
        return response
    }

    /// The answer of a page's request whose rule is still being prepared (BUG-089): the page gets it at once instead of
    /// waiting a minute or more, and is loaded again when the rule is ready. It is not a simulated answer of the application.
    static func preparing(_ contract: String) -> StudioSimResponse {
        var response = json(503, .object([
            "error": .string("markview_simulation_preparing"),
            "contract": .string(contract),
            "message": .string("MarkView UI Studio is still preparing the simulation rule for \(contract); the page is loaded again when it is ready. "
                               + "The request did not reach any real service.")
        ]))
        response.headers["x-markview-simulation"] = "preparing"
        response.headers["retry-after"] = "2"
        return response
    }

    /// SDKs and other dependencies the simulation cannot serve (DEC-004), named in `reason`.
    static func unsupported(_ contract: String, reason: String) -> StudioSimResponse {
        var response = json(501, .object([
            "error": .string("markview_simulation_unsupported"),
            "contract": .string(contract),
            "message": .string("MarkView UI Studio does not simulate \(reason). The request did not reach any real service."),
            "errors": .array([.object(["message": .string("\(reason) is not simulated by MarkView UI Studio")])]),
        ]))
        response.headers["x-markview-simulation"] = "unsupported"
        return response
    }
}

/// What the simulation decided for a request.
enum StudioSimOutcome: Equatable {
    case respond(StudioSimResponse, rule: String)
    /// No rule matches: prepare one (or answer with a controlled error).
    case unknown(contract: String)
    /// A dependency the simulation cannot serve (a GraphQL subscription over HTTP), named in `reason`.
    case unsupported(contract: String, reason: String)
}

/// Route patterns and contract keys.
enum StudioRoute {
    /// Path and origin of a pattern: `/api/x` (same origin as the app) or `https://host/api/x`.
    static func split(_ pattern: String) -> (origin: String?, path: String) {
        if let url = URL(string: pattern), let scheme = url.scheme, let host = url.host, ["http", "https"].contains(scheme) {
            let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
            return (origin, url.path.isEmpty ? "/" : url.path)
        }
        return (nil, pattern)
    }

    static func segments(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }

    /// Parameters of `path` when it matches `pattern`; nil when it does not. `:name` takes one segment, `*` the rest.
    static func match(pattern: String, path: String) -> [String: String]? {
        let wanted = segments(pattern), given = segments(path)
        var parameters: [String: String] = [:]
        for (index, part) in wanted.enumerated() {
            if part == "*" { return parameters }
            guard index < given.count else { return nil }
            if part.hasPrefix(":") {
                guard !given[index].isEmpty else { return nil }
                parameters[String(part.dropFirst())] = given[index].removingPercentEncoding ?? given[index]
            } else if part != given[index] {
                return nil
            }
        }
        return wanted.count == given.count ? parameters : nil
    }

    /// Literal segments count more than parameters, so `/api/projects/archived` wins over `/api/projects/:id`.
    static func specificity(_ pattern: String) -> Int {
        segments(split(pattern).path).reduce(0) { $0 + ($1 == "*" ? 0 : $1.hasPrefix(":") ? 1 : 3) }
    }

    /// The contract an unknown request stands for: method and path with ids replaced by `:id` (SIM-07 de-duplicates by it).
    static func contractKey(method: String, url: URL, appOrigin: String?) -> String {
        let origin = url.scheme.flatMap { scheme in url.host.map { "\(scheme)://\($0)" + (url.port.map { ":\($0)" } ?? "") } }
        let path = segments(url.path).map { isIdentifier($0) ? ":id" : $0 }.joined(separator: "/")
        let prefix = origin == nil || origin == appOrigin ? "" : origin!
        return "\(method.uppercased()) \(prefix)/\(path)"
    }

    /// Numbers, UUIDs, long hex strings and slugs that carry a number look like record ids.
    static func isIdentifier(_ segment: String) -> Bool {
        if segment.allSatisfy(\.isNumber) && !segment.isEmpty { return true }
        if segment.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { return true }
        if segment.count >= 12, segment.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil { return true }
        if segment.count >= 3, segment.contains(where: \.isNumber), segment.contains(where: \.isLetter),
           segment.range(of: #"^[A-Za-z]+[-_][0-9]+$|^[a-z0-9]{20,}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// `pattern` (an allowed-request entry) covers `url`: a full URL prefix with `*`, or a path pattern on the app's origin.
    static func allows(_ pattern: String, url: URL, appOrigin: String?) -> Bool {
        let text = url.absoluteString
        if pattern.contains("://") {
            if pattern.hasSuffix("*") { return text.hasPrefix(String(pattern.dropLast())) }
            return text == pattern || text.hasPrefix(pattern.hasSuffix("/") ? pattern : pattern + "/") || text.hasPrefix(pattern + "?")
        }
        let origin = url.scheme.flatMap { scheme in url.host.map { "\(scheme)://\($0)" + (url.port.map { ":\($0)" } ?? "") } }
        guard origin == appOrigin else { return false }
        if pattern.hasSuffix("*") { return url.path.hasPrefix(String(pattern.dropLast())) }
        return match(pattern: pattern, path: url.path) != nil
    }
}

/// The simulation engine (SIM-01…SIM-11): registered rules answer from one mutable state without calling a model.
/// It is a value: a write builds the next state and replaces the current one only when it succeeded (atomic writes).
struct StudioSimulator {
    private(set) var spec: StudioEnvironmentSpec
    private(set) var scenario: StudioScenario
    /// The current records by entity; the scenario's baseline is never changed by them.
    private(set) var state: [String: [StudioJSON]] = [:]
    /// Writes already applied, by idempotency key or request id, with the answer they got (SIM-09).
    private(set) var journal: [String: StudioSimResponse] = [:]
    /// Ids deleted in this generation, by entity: a new record never takes the id of a deleted one, as with a real database.
    private(set) var retiredIDs: [String: Set<String>] = [:]
    /// Bumped by every Reset; late results of an older generation must not change the state (SIM-10).
    private(set) var generation = 1
    var appOrigin: String?
    /// The built-in Supabase Auth of a project that uses Supabase (REQ-010); nil for other projects.
    var authMock: StudioAuthMock?

    init(spec: StudioEnvironmentSpec, scenario: StudioScenario, appOrigin: String? = nil) {
        self.spec = spec
        self.scenario = scenario
        self.appOrigin = appOrigin
        state = baseline
    }

    /// The scenario's own records, else the environment's seed.
    var baseline: [String: [StudioJSON]] { scenario.data ?? spec.seed }

    /// Back to the scenario's baseline: records, journal; a new generation (SIM-04).
    mutating func reset() {
        state = baseline
        journal = [:]
        retiredIDs = [:]
        generation += 1
    }

    /// Another scenario (or the same one, changed); always a Reset.
    mutating func activate(_ scenario: StudioScenario) {
        self.scenario = scenario
        reset()
    }

    /// The rule that answers `request`, the most specific first.
    func rule(for request: StudioHTTPRequest) -> (StudioRule, [String: String])? {
        let origin = request.url.scheme.flatMap { scheme in request.url.host.map { "\(scheme)://\($0)" + (request.url.port.map { ":\($0)" } ?? "") } }
        let candidates = spec.rules.compactMap { rule -> (StudioRule, [String: String])? in
            guard rule.method.uppercased() == request.method.uppercased() else { return nil }
            let (ruleOrigin, path) = StudioRoute.split(rule.path)
            if let ruleOrigin { guard ruleOrigin == origin else { return nil } } else if origin != appOrigin, appOrigin != nil { return nil }
            guard let parameters = StudioRoute.match(pattern: path, path: request.path) else { return nil }
            return (rule, parameters)
        }
        return candidates.max { StudioRoute.specificity($0.0.path) < StudioRoute.specificity($1.0.path) }
    }

    /// Answers `request` from the state; a write changes the state once.
    mutating func handle(_ request: StudioHTTPRequest) -> StudioSimOutcome {
        if let answer = authAnswer(request) { return answer }
        // GraphQL is answered by its operation rules over the same state (REQ-015); a mutation is applied once per request id.
        if let graphQL = StudioGraphQLRequest.read(request) {
            let mutation = (try? graphQL.get())?.operation.kind == .mutation
            let key = mutation ? "write:" + (request.idempotencyKey ?? request.requestId) : nil
            if let key, let recorded = journal[key] { return .respond(recorded, rule: "graphql") }
            let outcome = handleGraphQL(graphQL, request: request)
            if let key, case .respond(let response, _) = outcome, response.status == 200, !response.hang { journal[key] = response }
            return outcome
        }
        guard let (rule, parameters) = rule(for: request) else {
            return .unknown(contract: StudioRoute.contractKey(method: request.method, url: request.url, appOrigin: appOrigin))
        }
        let key = request.isWrite ? "write:" + (request.idempotencyKey ?? request.requestId) : nil
        if let key, let recorded = journal[key] { return .respond(recorded, rule: rule.id) }

        let override = scenario.overrides.first { matches($0, rule: rule) }
        var response: StudioSimResponse
        if let override, override.hang == true {
            response = StudioSimResponse(status: 200, body: nil, hang: true)
        } else if let override, let status = override.status {
            response = .json(status, override.body ?? .object(["error": .string("Simulated error \(status)")]))
        } else if let override, override.empty == true {
            response = emptyAnswer(rule)
        } else {
            var next = state
            var retired = retiredIDs
            response = Self.apply(rule, parameters: parameters, request: request, state: &next, retired: &retired, spec: spec, role: scenario.role,
                                  baseline: baseline)
            if (200..<300).contains(response.status) {
                state = next
                retiredIDs = retired
            }
        }
        if rule.operation == .respond || rule.operation == .document || override != nil { response = withPlaceholders(response) }
        if let delay = override?.delayMs { response.delayMs = max(0, delay) }
        if let key, (200..<300).contains(response.status), !response.hang { journal[key] = response }
        return .respond(response, rule: rule.id)
    }

    private func matches(_ override: StudioOverride, rule: StudioRule) -> Bool {
        if let id = override.ruleId { return id == rule.id }
        guard let method = override.method, let path = override.path else { return false }
        return method.uppercased() == rule.method.uppercased() && path == rule.path
    }

    private func emptyAnswer(_ rule: StudioRule) -> StudioSimResponse {
        switch rule.operation {
        case .list:
            return .json(200, rule.envelope.map { .object([$0: .array([])]) } ?? .array([]))
        case .get:
            return .json(404, .object(["error": .string("Not found")]))
        default:
            return .json(rule.status ?? 200, .object([:]))
        }
    }

    /// A write that does not come through a REST rule: a GraphQL mutation or a channel message (REQ-015). The operation a
    /// rule would run, validated and applied atomically to the state; returns the answer the rule would give.
    mutating func perform(_ operation: StudioRule.Operation, entity: String, id: String?, fields: StudioJSON) -> StudioSimResponse {
        let method = operation == .update ? "PATCH" : operation == .delete ? "DELETE" : "POST"
        let rule = StudioRule(id: "perform", method: method, path: "/", operation: operation, entity: entity)
        let request = StudioHTTPRequest(method: method, url: URL(string: "http://simulation.markview.invalid/")!, body: fields.text,
                                        requestId: "perform")
        var next = state
        var retired = retiredIDs
        let response = Self.apply(rule, parameters: id.map { ["id": $0] } ?? [:], request: request, state: &next, retired: &retired, spec: spec,
                                  role: scenario.role)
        if (200..<300).contains(response.status) {
            state = next
            retiredIDs = retired
        }
        return response
    }

    // MARK: Operations

    static func apply(_ rule: StudioRule, parameters: [String: String], request: StudioHTTPRequest,
                      state: inout [String: [StudioJSON]], retired: inout [String: Set<String>],
                      spec: StudioEnvironmentSpec, role: StudioRole, baseline: [String: [StudioJSON]]? = nil) -> StudioSimResponse {
        let entityName = rule.entity ?? ""
        let entity = spec.entity(entityName) ?? StudioEntity(name: entityName)
        let idField = entity.idField
        let wantedID = parameters[rule.idParam ?? "id"] ?? parameters.values.first
        var records = state[entityName] ?? []
        let notFound = StudioSimResponse.json(404, .object(["error": .string("\(entityName) \(wantedID ?? "") was not found")]))

        switch rule.operation {
        case .respond:
            let fixed = rule.response ?? StudioFixedResponse(status: 200, body: .object([:]))
            var response = StudioSimResponse.json(fixed.status, fixed.body)
            for (name, value) in fixed.headers ?? [:] { response.headers[name.lowercased()] = value }
            return response
        case .document:
            return StudioDocument.apply(rule, parameters: parameters, request: request, idField: idField, records: &records,
                                        seed: (baseline ?? spec.seed)[entityName] ?? [], state: &state, entity: entityName)
        case .session:
            var user = role.user.objectValue ?? [:]
            user["token"] = .string(role.token)
            return .json(rule.status ?? 200, rule.envelope.map { .object([$0: .object(user)]) } ?? .object(user))
        case .list:
            let query = request.query
            var list = records
            // A filter is a field of the records. Paging parameters named as filters (`limit`, `offset`) matched no record and
            // emptied every list (BUG-078): they page the list instead.
            for name in rule.filters ?? [] where !StudioPaging.parameters.contains(name.lowercased()) && hasField(name, entity, records) {
                guard let wanted = query[name] else { continue }
                list = list.filter { $0[name]?.identityKey == wanted }
            }
            list = StudioPaging.searchAndSort(list, query: query)
            list = StudioPaging.page(list, query: query)
            list = list.map { attach(rule.include, to: $0, idField: idField, state: state, spec: spec) }
            return .json(rule.status ?? 200, rule.envelope.map { .object([$0: .array(list)]) } ?? .array(list))
        case .get:
            guard let wantedID, let record = records.first(where: { $0[idField]?.identityKey == wantedID }) else { return notFound }
            return .json(rule.status ?? 200, attach(rule.include, to: record, idField: idField, state: state, spec: spec))
        case .create:
            guard var fields = request.jsonBody?.objectValue else {
                return .json(400, .object(["error": .string("The request body must be a JSON object")]))
            }
            if fields[idField] == nil || fields[idField]?.isNull == true { fields[idField] = nextID(records, idField: idField, entity: entityName, retired: retired[entityName] ?? [])
            }
            if records.contains(where: { $0[idField]?.identityKey == fields[idField]?.identityKey }) {
                return .json(409, .object(["error": .string("\(entityName) \(fields[idField]?.identityKey ?? "") already exists")]))
            }
            let record = StudioJSON.object(fields)
            let problems = StudioValidator.problems(record: record, entity: entity, state: state, spec: spec)
            guard problems.isEmpty else { return .json(422, .object(["errors": .array(problems.map { .string($0) })])) }
            records.append(record)
            state[entityName] = records
            return .json(rule.status ?? 201, record)
        case .update:
            guard let wantedID, let index = records.firstIndex(where: { $0[idField]?.identityKey == wantedID }) else { return notFound }
            guard let changes = request.jsonBody?.objectValue else {
                return .json(400, .object(["error": .string("The request body must be a JSON object")]))
            }
            var fields = request.method == "PUT" ? [idField: records[index][idField] ?? .string(wantedID)] : (records[index].objectValue ?? [:])
            for (name, value) in changes where name != idField { fields[name] = value }
            let record = StudioJSON.object(fields)
            let problems = StudioValidator.problems(record: record, entity: entity, state: state, spec: spec)
            guard problems.isEmpty else { return .json(422, .object(["errors": .array(problems.map { .string($0) })])) }
            records[index] = record
            state[entityName] = records
            return .json(rule.status ?? 200, record)
        case .delete:
            guard let wantedID, let index = records.firstIndex(where: { $0[idField]?.identityKey == wantedID }) else { return notFound }
            if let removed = records[index][idField]?.identityKey { retired[entityName, default: []].insert(removed) }
            records.remove(at: index)
            state[entityName] = records
            let status = rule.status ?? 204
            return StudioSimResponse(status: status, body: status == 204 ? nil : StudioJSON.object([:]).text)
        }
    }

    /// Related records read from the same state, so a detail and its list never disagree (AC-02).
    /// Whether `name` is a field of the entity's records: declared, or present in one of them (BUG-078).
    private static func hasField(_ name: String, _ entity: StudioEntity, _ records: [StudioJSON]) -> Bool {
        entity.fields.contains { $0.name == name } || records.contains { $0[name] != nil }
    }

    private static func attach(_ includes: [StudioInclude]?, to record: StudioJSON, idField: String,
                               state: [String: [StudioJSON]], spec: StudioEnvironmentSpec) -> StudioJSON {
        guard let includes, !includes.isEmpty, var fields = record.objectValue, let id = record[idField]?.identityKey else { return record }
        for include in includes {
            fields[include.field] = .array((state[include.entity] ?? []).filter { $0[include.foreignKey]?.identityKey == id })
        }
        return .object(fields)
    }

    /// The next id in the style of the existing ones: integers count on, other ids get `<entity>-<n>`. `retired` ids (of
    /// records deleted in this generation) are never given out again.
    static func nextID(_ records: [StudioJSON], idField: String, entity: String, retired: Set<String> = []) -> StudioJSON {
        let ids = records.compactMap { $0[idField] }
        if !ids.isEmpty, ids.allSatisfy({ $0.typeName == "integer" }) {
            let highest = (ids.compactMap(\.numberValue) + retired.compactMap(Double.init)).max() ?? 0
            return .number(highest + 1)
        }
        let base = entity.hasSuffix("s") ? String(entity.dropLast()) : entity
        var number = records.count + 1
        let taken = Set(ids.compactMap(\.identityKey)).union(retired)
        while taken.contains("\(base)-\(number)") { number += 1 }
        return .string("\(base)-\(number)")
    }

    // MARK: Registration

    /// Adds validated rules, entities and records in one step (SIM-06, plan I-4): either everything is registered or nothing.
    /// Returns the problems; empty when the proposal was registered.
    @discardableResult
    mutating func register(_ proposal: StudioProposal) -> [String] {
        let problems = StudioValidator.problems(proposal: proposal, spec: spec, state: state)
        guard problems.isEmpty else { return problems }
        var nextSpec = spec
        var nextState = state
        for entity in proposal.entities {
            if let index = nextSpec.entities.firstIndex(where: { $0.name == entity.name }) {
                nextSpec.entities[index].fields = Self.merged(nextSpec.entities[index].fields, entity.fields)
            } else {
                nextSpec.entities.append(entity)
            }
        }
        for (name, records) in proposal.records {
            nextSpec.seed[name, default: []] += records
            nextState[name, default: []] += records
        }
        nextSpec.rules += proposal.rules
        if let channels = proposal.channels, !channels.isEmpty { nextSpec.channels = (nextSpec.channels ?? []) + channels }
        if let operations = proposal.graphQL, !operations.isEmpty { nextSpec.graphQL = (nextSpec.graphQL ?? []) + operations }
        nextSpec.updated = Date()
        spec = nextSpec
        state = nextState
        // The scenario's own baseline gains the new records too, so a Reset keeps them.
        if scenario.data != nil {
            for (name, records) in proposal.records { scenario.data?[name, default: []] += records }
        }
        return []
    }

    private static func merged(_ old: [StudioField], _ new: [StudioField]) -> [StudioField] {
        old + new.filter { field in !old.contains { $0.name == field.name } }
    }

    /// Replaces the environment (a saved spec was edited); the state is not touched until the next Reset.
    mutating func replaceSpec(_ spec: StudioEnvironmentSpec) { self.spec = spec }

    /// The scenario's test user got another role (REQ-014): the records stay, the next answers use the new user.
    mutating func replaceRole(_ role: StudioRole) { scenario.role = role }

    /// The current records as a scenario's baseline (Save snapshot, SIM-04); explicit, never automatic (CAP-01).
    func snapshot() -> [String: [StudioJSON]] { state }
}

/// What an agent proposes for an unknown request (or a whole environment): declarative rules, entities and records.
struct StudioProposal: Codable, Equatable, Sendable {
    var entities: [StudioEntity] = []
    var records: [String: [StudioJSON]] = [:]
    var rules: [StudioRule] = []
    /// WebSocket, server-sent event and Socket.IO channels (REQ-015). Optional, so proposals without them still decode.
    var channels: [StudioChannel]? = nil
    /// GraphQL operations (REQ-015).
    var graphQL: [StudioGraphQLOperation]? = nil
    /// The request needs a dependency the simulation cannot serve.
    var unsupported = false
    var reason = ""
    var assumptions: [String] = []
}

/// Schema checks of rules, entities and records (SIM-06): required fields, types, enumerations, references.
enum StudioValidator {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    static let types: Set<String> = ["string", "integer", "number", "boolean", "object", "array"]
    static let maxRules = 60, maxEntities = 30, maxRecords = 1_000, maxSize = 1_000_000

    static func problems(record: StudioJSON, entity: StudioEntity, state: [String: [StudioJSON]], spec: StudioEnvironmentSpec) -> [String] {
        guard let fields = record.objectValue else { return ["\(entity.name): a record must be a JSON object"] }
        var problems: [String] = []
        guard let id = fields[entity.idField], id.identityKey != nil, ["string", "integer"].contains(id.typeName) else {
            return ["\(entity.name): every record needs a string or integer \(entity.idField)"]
        }
        for field in entity.fields {
            guard let value = fields[field.name], !value.isNull else {
                if field.required { problems.append("\(entity.name) \(id.identityKey!): \(field.name) is required") }
                continue
            }
            let type = value.typeName
            let fits = type == field.type || (field.type == "number" && type == "integer")
            if !fits { problems.append("\(entity.name) \(id.identityKey!): \(field.name) must be \(field.type), not \(type)") }
            if let allowed = field.enumValues, let text = value.identityKey, !allowed.contains(text) {
                problems.append("\(entity.name) \(id.identityKey!): \(field.name) must be one of \(allowed.joined(separator: ", "))")
            }
            if let target = field.references, let key = value.identityKey {
                let targetID = spec.entity(target)?.idField ?? "id"
                if !(state[target] ?? []).contains(where: { $0[targetID]?.identityKey == key }) {
                    problems.append("\(entity.name) \(id.identityKey!): \(field.name) points at \(target) \(key), which does not exist")
                }
            }
        }
        return problems
    }

    /// Everything wrong with a proposal against the current environment and state; empty = it may be registered.
    static func problems(proposal: StudioProposal, spec: StudioEnvironmentSpec, state: [String: [StudioJSON]]) -> [String] {
        if proposal.unsupported { return ["The request needs a dependency UI Studio does not simulate: \(proposal.reason)"] }
        var problems: [String] = []
        if proposal.rules.isEmpty, (proposal.channels ?? []).isEmpty, (proposal.graphQL ?? []).isEmpty {
            problems.append("The proposal has no rule")
        }
        if proposal.rules.count > maxRules { problems.append("Too many rules (\(proposal.rules.count) > \(maxRules))") }
        if proposal.entities.count > maxEntities { problems.append("Too many entities (\(proposal.entities.count) > \(maxEntities))") }
        let recordCount = proposal.records.values.reduce(0) { $0 + $1.count }
        if recordCount > maxRecords { problems.append("Too many records (\(recordCount) > \(maxRecords))") }
        let size = (try? JSONEncoder().encode(proposal).count) ?? 0
        if size > maxSize { problems.append("The proposal is too large (\(size) bytes)") }

        var nextSpec = spec
        for entity in proposal.entities {
            if entity.name.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) == nil {
                problems.append("Entity name \"\(entity.name)\" is not a plain name")
            }
            for field in entity.fields where !types.contains(field.type) {
                problems.append("\(entity.name).\(field.name): unknown type \(field.type)")
            }
            if let index = nextSpec.entities.firstIndex(where: { $0.name == entity.name }) {
                if nextSpec.entities[index].idField != entity.idField {
                    problems.append("\(entity.name): the id field differs from the registered entity (\(nextSpec.entities[index].idField))")
                }
                nextSpec.entities[index].fields += entity.fields.filter { field in !nextSpec.entities[index].fields.contains { $0.name == field.name } }
            } else {
                nextSpec.entities.append(entity)
            }
        }
        var seen = Set(spec.rules.map { "\($0.method.uppercased()) \($0.path)" })
        var ids = Set(spec.rules.map(\.id))
        for rule in proposal.rules {
            let method = rule.method.uppercased()
            if !methods.contains(method) { problems.append("\(rule.id): method \(rule.method) is not supported") }
            let (_, path) = StudioRoute.split(rule.path)
            if !path.hasPrefix("/") { problems.append("\(rule.id): the path must start with / or be a full URL") }
            if path.contains("..") || path.contains(" ") { problems.append("\(rule.id): the path \(rule.path) is not a plain route") }
            if !seen.insert("\(method) \(rule.path)").inserted { problems.append("\(rule.id): \(method) \(rule.path) already has a rule") }
            if !ids.insert(rule.id).inserted || rule.id.isEmpty { problems.append("Rule id \"\(rule.id)\" is empty or already used") }
            switch rule.operation {
            case .respond:
                guard let response = rule.response else { problems.append("\(rule.id): a respond rule needs a response"); break }
                if !(100...599).contains(response.status) { problems.append("\(rule.id): status \(response.status) is not an HTTP status") }
            case .session:
                break
            default:
                guard let entity = rule.entity, nextSpec.entity(entity) != nil else {
                    problems.append("\(rule.id): \(rule.operation.rawValue) needs a defined entity (got \(rule.entity ?? "none"))")
                    break
                }
                if [.get, .update, .delete].contains(rule.operation),
                   StudioRoute.segments(path).allSatisfy({ !$0.hasPrefix(":") }) {
                    problems.append("\(rule.id): \(rule.operation.rawValue) needs an id parameter in the path")
                }
                for include in rule.include ?? [] where nextSpec.entity(include.entity) == nil {
                    problems.append("\(rule.id): included entity \(include.entity) is not defined")
                }
            }
            if let status = rule.status, !(100...599).contains(status) { problems.append("\(rule.id): status \(status) is not an HTTP status") }
        }
        problems += StudioChannelValidator.problems(channels: proposal.channels ?? [], operations: proposal.graphQL ?? [], spec: nextSpec,
                                                    registered: spec)
        // Records are checked in dependency order against the state they will join.
        var nextState = state
        for (name, records) in proposal.records {
            guard nextSpec.entity(name) != nil else { problems.append("Records for undefined entity \(name)"); continue }
            nextState[name, default: []] += records
        }
        for (name, records) in proposal.records {
            guard let entity = nextSpec.entity(name) else { continue }
            var keys = Set((state[name] ?? []).compactMap { $0[entity.idField]?.identityKey })
            for record in records {
                problems += Self.problems(record: record, entity: entity, state: nextState, spec: nextSpec)
                if let key = record[entity.idField]?.identityKey, !keys.insert(key).inserted {
                    problems.append("\(name): id \(key) is used twice")
                }
            }
        }
        return problems
    }
}

/// Paging of a simulated list (BUG-078): the common query names for a page size and an offset, applied after filtering.
enum StudioPaging {
    static let sizes = ["limit", "per_page", "perpage", "page_size", "pagesize", "size", "take", "first"]
    static let offsets = ["offset", "skip", "start"]
    static let pages = ["page", "page_number", "pagenumber"]
    static let parameters = Set(sizes + offsets + pages + ["cursor", "after", "before", "sort", "order", "order_by", "orderby", "sort_by", "q", "search"])

    /// Search text fields and sort scalar fields before slicing the result. Equal and missing values keep their seed order.
    static func searchAndSort(_ list: [StudioJSON], query: [String: String]) -> [StudioJSON] {
        let query = Dictionary(query.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let term = (query["q"] ?? query["search"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let found = term.isEmpty ? list : list.filter { record in
            (record.objectValue ?? [:]).values.contains { value in
                guard case .string(let text) = value else { return false }
                return text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        guard var field = query["sort"] ?? query["sort_by"] ?? query["order_by"] ?? query["orderby"], !field.isEmpty else { return found }
        var descending = query["order"]?.lowercased() == "desc"
        if field.hasPrefix("-") { descending = true; field.removeFirst() }
        if field.lowercased().hasSuffix(".desc") { descending = true; field = String(field.dropLast(5)) }
        else if field.lowercased().hasSuffix(".asc") { descending = false; field = String(field.dropLast(4)) }
        guard !field.isEmpty, found.contains(where: { $0[field] != nil }) else { return found }
        return found.enumerated().sorted { left, right in
            let a = left.element[field], b = right.element[field]
            let comparison: ComparisonResult
            func rank(_ value: StudioJSON?) -> Int {
                switch value { case .some(.number): return 0; case .some(.string): return 1; default: return 2 }
            }
            switch (a, b) {
            case (.some(.number(let x)), .some(.number(let y))): comparison = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case (.some(.string(let x)), .some(.string(let y))): comparison = x.localizedStandardCompare(y)
            default:
                let x = rank(a), y = rank(b)
                comparison = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return left.offset < right.offset }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }.map(\.element)
    }

    static func page(_ list: [StudioJSON], query: [String: String]) -> [StudioJSON] {
        let lowered = Dictionary(query.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func number(_ names: [String]) -> Int? { names.lazy.compactMap { lowered[$0].flatMap { Int($0) } }.first }
        let size = number(sizes).map { max(0, $0) }
        var offset = number(offsets).map { max(0, $0) } ?? 0
        if number(offsets) == nil, let page = number(pages), let size, page > 0 { offset = (page - 1) * size }
        guard offset > 0 || size != nil else { return list }
        let start = min(offset, list.count)
        let end = size.map { min(list.count, start + $0) } ?? list.count
        return Array(list[start..<end])
    }
}

/// The `document` operation: one stored JSON document per key, which the application reads and saves as a whole (settings,
/// preferences, a profile). A record holds it as `{ "<idField>": key, "value": document, "revision": n }`; a seed record
/// without `value` is the document itself (its id field aside). Saves change what later reads return.
enum StudioDocument {
    static let defaultKey = "default"

    static func action(_ rule: StudioRule, method: String) -> StudioRule.DocumentAction {
        if let action = rule.documentAction { return action }
        switch method.uppercased() {
        case "GET", "HEAD": return .read
        case "PATCH": return .merge
        case "DELETE": return .reset
        default: return .replace
        }
    }

    /// The document a record holds, and its revision.
    static func value(of record: StudioJSON, idField: String) -> (StudioJSON, Int) {
        guard var fields = record.objectValue else { return (record, 0) }
        let revision = fields["revision"]?.numberValue.map { Int($0) } ?? 0
        if let value = fields["value"], Set(fields.keys).isSubset(of: [idField, "value", "revision"]) { return (value, revision) }
        fields[idField] = nil
        return (.object(fields), 0)
    }

    /// RFC 7386 JSON merge patch: objects merge key by key, `null` removes a key, anything else replaces.
    static func merge(_ target: StudioJSON, _ patch: StudioJSON) -> StudioJSON {
        guard let changes = patch.objectValue else { return patch }
        var fields = target.objectValue ?? [:]
        for (name, value) in changes {
            if value.isNull { fields[name] = nil } else { fields[name] = merge(fields[name] ?? .null, value) }
        }
        return .object(fields)
    }

    static func apply(_ rule: StudioRule, parameters: [String: String], request: StudioHTTPRequest, idField: String,
                      records: inout [StudioJSON], seed: [StudioJSON], state: inout [String: [StudioJSON]], entity: String) -> StudioSimResponse {
        // Only a named key parameter selects the document: other path parameters (an expected revision) are not keys.
        let key = parameters[rule.idParam ?? "id"] ?? defaultKey
        let index = records.firstIndex { $0[idField]?.identityKey == key }
        let current = index.map { value(of: records[$0], idField: idField) }
        let seeded = seed.first { $0[idField]?.identityKey == key }.map { value(of: $0, idField: idField).0 }
        var next: StudioJSON?
        switch action(rule, method: request.method) {
        case .read:
            guard let current else {
                if rule.response != nil { return answer(rule, document: .null, revision: 0) }
                return .json(404, .object(["error": .string("\(entity) \(key) was not found")]))
            }
            return answer(rule, document: current.0, revision: current.1)
        case .replace:
            guard let body = request.jsonBody else {
                return .json(400, .object(["error": .string("The request body must be the document as JSON")]))
            }
            next = body
        case .merge:
            guard let body = request.jsonBody else {
                return .json(400, .object(["error": .string("The request body must be a JSON merge patch")]))
            }
            next = merge(current?.0 ?? .object([:]), body)
        case .reset:
            // A list of names resets those keys of the document to the seed; otherwise the whole document is.
            if let names = request.jsonBody?.arrayValue?.compactMap(\.stringValue), !names.isEmpty, var fields = current?.0.objectValue {
                for name in names { fields[name] = seeded?[name] }
                next = .object(fields)
            } else {
                next = seeded
            }
        }
        let revision = (current?.1 ?? 0) + 1
        if let next {
            let record = StudioJSON.object([idField: .string(key), "value": next, "revision": .number(Double(revision))])
            if let index { records[index] = record } else { records.append(record) }
        } else if let index {
            records.remove(at: index)
        }
        state[entity] = records
        return answer(rule, document: next ?? .null, revision: revision)
    }

    /// The document itself (in `envelope` when set), or the rule's template with `{{studio.document}}` and
    /// `{{studio.revision}}` filled in.
    static func answer(_ rule: StudioRule, document: StudioJSON, revision: Int) -> StudioSimResponse {
        guard let template = rule.response else {
            return .json(rule.status ?? 200, rule.envelope.map { .object([$0: document]) } ?? document)
        }
        var response = StudioSimResponse.json(rule.status ?? template.status, fill(template.body ?? .null, document: document, revision: revision))
        for (name, value) in template.headers ?? [:] { response.headers[name.lowercased()] = value }
        return response
    }

    static func fill(_ json: StudioJSON, document: StudioJSON, revision: Int) -> StudioJSON {
        switch json {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^\{\{\s*studio\.document\s*\}\}$"#, options: .regularExpression) != nil { return document }
            if trimmed.range(of: #"^\{\{\s*studio\.revision\s*\}\}$"#, options: .regularExpression) != nil { return .string(String(revision)) }
            return .string(text.replacingOccurrences(of: #"\{\{\s*studio\.revision\s*\}\}"#, with: String(revision), options: .regularExpression))
        case .array(let items): return .array(items.map { fill($0, document: document, revision: revision) })
        case .object(let fields): return .object(fields.mapValues { fill($0, document: document, revision: revision) })
        default: return json
        }
    }
}
