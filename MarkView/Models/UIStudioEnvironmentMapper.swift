import Foundation

// REQ-014: how the application's map is made. One inventory call lists the API surface, each group of endpoints is prepared
// with the preparation schema through the preparation queue (environment jobs: Reset does not cancel them, and a request to a
// group's service waits for it), a coherence check runs over the seed, and a bounded refill fixes the entities it found gaps
// in. Everything runs in the background: the page keeps working and its own requests are still prepared one by one.

/// What a map is made for: the application folder, its origin and the simulated connections of its server.
struct StudioMapContext: Equatable, Sendable {
    /// Relative to the project root ("" for the root).
    var appFolder: String
    var appOrigin: String?
    /// The development server's simulated connections (REQ-007): their addresses are the services' addresses.
    var connections: [StudioServerConnection]
    /// An Electron renderer: its preload bridge is part of the API (REQ-016).
    var electron = false

    var connectionLines: [String] {
        connections.map { "\($0.variable) → \($0.origin)\($0.basePath)" + ($0.foundIn.isEmpty ? "" : " (read at \($0.foundIn))") }
    }
}

/// One call to the assistant for the map.
struct StudioMapRequest: Equatable, Sendable {
    var prompt: String
    var timeout: TimeInterval
    /// `ui-studio:map`, `ui-studio:map-group` or `ui-studio:map-refill`, as the AI call log shows it.
    var label: String
}

/// New seed records for one entity, as the assistant answered them (not validated yet).
struct StudioMapRefill: Equatable, Sendable {
    var records: [StudioJSON]
    var assumptions: [String]
}

/// The assistant of the map: the app's implementation asks the project's CLI read-only (`StudioCLIMapAssistant`); tests use
/// stand-ins. Answers are parsed here and validated by the mapper before anything is registered.
protocol StudioMapAssistant: Sendable {
    func inventory(_ request: StudioMapRequest) async throws -> StudioMapInventory
    func prepareGroup(_ request: StudioMapRequest) async throws -> StudioProposal
    func refill(_ request: StudioMapRequest) async throws -> StudioMapRefill
}

/// An answer that does not have the shape of its schema.
struct StudioMapUnreadable: LocalizedError {
    var what: String
    var errorDescription: String? { "The assistant's answer was not \(what)." }
}

/// A group's preparation for the queue: its prompt is written when an attempt starts, from the environment as it is then
/// (other groups may have registered entities meanwhile) and with the previous attempt's problems.
struct StudioMapGroupPreparer: StudioRulePreparing {
    let assistant: StudioMapAssistant
    let timeout: TimeInterval
    let prompt: @Sendable (_ problems: [String]) async -> String

    func prepare(_ context: StudioPreparationContext) async throws -> StudioProposal {
        let text = await prompt(context.problems)
        return try await assistant.prepareGroup(StudioMapRequest(prompt: text, timeout: timeout, label: "ui-studio:map-group"))
    }
}

// MARK: - Prompts

/// The prompts and strict schemas of the map: every property is required, free-form JSON travels as JSON text. The group
/// preparation uses `StudioPrompts.preparationSystem` and `preparationSchema`, so the mock-up policy (DEC-007) applies.
enum StudioMapPrompts {
    static let inventorySystem = """
        You map the API surface of a web application for MarkView UI Studio. UI Studio runs the application for real in a \
        browser and answers every request it makes, from the page and from its development server, with a simulation (a \
        mock-up: nothing is checked for real). To prepare that simulation before the pages ask, it needs the list of every \
        request the application's code can make. Read the project's code (read-only) and return that list.

        What to cover:
        - Browser and server code, and every route: pages, layouts, components, hooks, stores, server components, loaders \
          and actions, route handlers and middleware.
        - Every way the code makes an HTTP request: fetch, axios, ky, got, XMLHttpRequest, SWR, React Query / TanStack \
          Query, RTK Query, supabase-js (its REST, storage and auth endpoints), Firebase REST, and the project's own clients \
          and wrappers (a function such as `serviceFetch` or `api.get`): follow each wrapper to the requests it builds and \
          list those requests, not the wrapper.
        - The application's own server endpoints the page calls (Next.js route handlers in app/**/route.ts or pages/api, \
          Remix resource routes, SvelteKit +server files, Express routes): they belong to the service `app`.

        How to answer:
        - services: one per base address. `name` is short and plain (`marketplace-core`, `supabase`, `app`); `baseURL` is the \
          address written in the code, or ""; `variable` is the environment variable that holds it, as the code reads it \
          without `process.env.`, or ""; `side` is browser, server or both. The application's own server is `app`, with an \
          empty baseURL and variable.
        - endpoints: one per method and path of a service. `path` is the path after the service's address, starting with \
          `/`, with `:name` for every part that varies (ids, slugs, codes) and without the query string; `resource` is the \
          plain name of what it reads or writes (`bundles`, `catalog-categories`); `callSite` is `path/to/file.ts:line`, \
          relative to the project root, of one place that makes it; `side` is browser or server.
        - Leave out static files, images, fonts, analytics and error reporting, and the framework's own requests (hot \
          reload, RSC payloads, server actions).
        - An Electron renderer's preload bridge (`contextBridge.exposeInMainWorld('<global>', …)`): UI Studio runs the \
          renderer as a web page and answers each bridge method like an endpoint of the service `\(StudioIPC.service)`, \
          baseURL `\(StudioIPC.origin)`, empty variable, side browser. List every method the preload exposes as one endpoint: \
          its path is `/<global>/<property path>/<method>`, then `/:name` for each string, number or boolean argument in \
          order (objects and arrays are the JSON body, not the path): `desk.settings.getBroker(id)` is \
          `/desk/settings/getBroker/:id`. Its method follows the name's first word: get, list, load, fetch, read, find, \
          query, is, has, can → GET; delete, remove, clear → DELETE; update, patch → PATCH; save, set, put, reset, import → \
          PUT; any other → POST. `ipcRenderer.invoke('<channel>', …)` called directly is `/electron/ipcRenderer/invoke/<channel>`. \
          `callSite` is the preload line; `resource` is what the method reads or writes. A method that takes a callback \
          (`onDocumentApplied(cb)`) is not an endpoint: name it in `notes`.
        - `notes`: what the application talks to that is not a JSON request over HTTP (GraphQL, WebSockets, server-sent \
          events, a database driver or ORM in server code), and what you could not follow.
        - userRoles: the roles the code checks for the signed-in user (a role claim or field such as `app_metadata.role`, \
          `user.role` or a roles list, compared in middleware, route guards, the server or its backend for frontend). \
          `names` lists every role value it compares with, exactly as written; `ordinary` is the one an ordinary signed-in \
          user has (a customer, not an administrator or support). Both are empty when the code checks no role.
        """ + "\n" + StudioPrompts.dataNotInstructions

    static func inventoryPrompt(_ context: StudioMapContext) -> String {
        var lines = ["Map the API surface of the web application in `\(context.appFolder.isEmpty ? "." : context.appFolder)` "
                     + "(relative to the project root) for MarkView UI Studio."]
        lines.append("Service addresses UI Studio found in the env files and the code, which its development server reads "
                     + "(variable → address; where it is read):\n"
                     + (context.connectionLines.isEmpty ? "(none)" : context.connectionLines.map { "- " + $0 }.joined(separator: "\n")))
        if context.electron {
            lines.append("This is an Electron renderer: list its preload bridge's methods as endpoints of the service "
                         + "`\(StudioIPC.service)` (read the preload's `contextBridge.exposeInMainWorld` and the main process's "
                         + "`ipcMain.handle` / `ipcMain.on` handlers).")
        }
        lines.append("Return every service and every endpoint the application's code can call, from the browser and from the server.")
        return lines.joined(separator: "\n\n")
    }

    static let inventorySchema: [String: Any] = {
        let service: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "name": ["type": "string"], "baseURL": ["type": "string"], "variable": ["type": "string"],
            "side": ["type": "string", "enum": StudioMapService.Side.allCases.map(\.rawValue)]],
            "required": ["name", "baseURL", "variable", "side"]]
        let endpoint: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "service": ["type": "string"], "resource": ["type": "string"],
            "method": ["type": "string", "enum": StudioMapParsing.methods],
            "path": ["type": "string", "description": "Path after the service's address, :name for the parts that vary"],
            "callSite": ["type": "string", "description": "file:line relative to the project root"],
            "side": ["type": "string", "enum": ["browser", "server"]]],
            "required": ["service", "resource", "method", "path", "callSite", "side"]]
        let roles: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "names": ["type": "array", "items": ["type": "string"], "description": "Every role value the code compares the user's role with"],
            "ordinary": ["type": "string", "description": "The role of an ordinary signed-in user, one of names; empty when the code checks no role"]],
            "required": ["names", "ordinary"]]
        return ["type": "object", "additionalProperties": false, "properties": [
            "services": ["type": "array", "items": service],
            "endpoints": ["type": "array", "items": endpoint],
            "notes": ["type": "array", "items": ["type": "string"]],
            "userRoles": roles],
            "required": ["services", "endpoints", "notes", "userRoles"]]
    }()

    /// The prompt of one group: its service and endpoints with the rule path each must get, the entities already registered
    /// with their records' ids (so groups share entities and point at each other's records), and the coherence rules.
    static func groupPrompt(_ group: StudioMapGroup, service: StudioMapService?, context: StudioMapContext,
                            spec: StudioEnvironmentSpec, problems: [String]) -> String {
        var lines = ["Prepare MarkView UI Studio's simulation for one group of the application's API, found when its code was "
                     + "mapped. The application runs in a simulated environment: every endpoint below needs a rule, with the entities "
                     + "and seed records its answers need, before the pages ask for it.",
                     "Group: \(group.id)",
                     "Application folder (relative to the project): \(context.appFolder.isEmpty ? "." : context.appFolder)"]
        let name = service?.name ?? group.service
        if service?.isApplication == true {
            lines.append("Service: the application's own server (`app`). A rule's path is the request's path alone, such as `/api/items`.")
        } else if let address = service?.address, !address.isEmpty {
            lines.append("Service `\(name)` (\(service?.side.rawValue ?? "browser")): its address is `\(address)`"
                         + (service?.variable.isEmpty == false ? ", from the variable \(service?.variable ?? "")" : "")
                         + ". A rule's path is the full URL: the address, then the endpoint's path.")
        } else {
            let known = [service?.variable.isEmpty == false ? "variable \(service?.variable ?? "")" : nil,
                         service?.baseURL.isEmpty == false ? "base URL \(service?.baseURL ?? "")" : nil].compactMap { $0 }
            lines.append("Service `\(name)`" + (known.isEmpty ? "" : " (" + known.joined(separator: ", ") + ")")
                         + ": UI Studio does not know its address. Find it in the code; a rule's path is the service's full URL followed by the endpoint's path.")
        }
        lines.append("Endpoints of this group (\(group.resource)):\n" + group.endpoints.map { endpoint in
            "- \(endpoint.method) \(endpoint.path) — \(endpoint.side.rawValue)" + (endpoint.callSite.isEmpty ? "" : ", called at \(endpoint.callSite)")
                + (StudioMapPlanner.rulePath(endpoint, service: service).map { "; rule path `\($0)`" } ?? "")
        }.joined(separator: "\n"))
        if !context.connections.isEmpty {
            lines.append("Simulated service addresses of the development server (variable → address; where it is read):\n"
                         + context.connectionLines.map { "- " + $0 }.joined(separator: "\n"))
        }
        lines.append("""
            The data must be coherent across the whole application, not only this group:
            - Reuse an entity that is already registered (below) when it is the same resource; never define it again under \
            another name or with another id field.
            - A field that holds another record's id sets `references` and holds the id of a record that exists: one listed \
            below or one in your answer. If it points at an entity that is not registered yet, include that entity and the \
            records it points at in your answer; MarkView keeps the records that are already there.
            - Coverage: every value the screens group, filter or tab by (each category, city, status, type) gets 2-4 records \
            in every list filtered or grouped by it, so no carousel, tab or list is empty. A list has 6-12 records in all. A \
            list filtered by a query parameter names that field in `filters`.
            - Realistic, varied values in the application's language and domain; never real people's data, never real credentials.
            """)
        if let roles = spec.map?.userRoles, !roles.isEmpty {
            lines.append("User roles the code checks: " + roles.joined(separator: ", ") + ". The scenario's test user has the role "
                         + (spec.testUserRole ?? StudioRole.tester.roleName ?? "member") + "; a user, member or session record uses these roles.")
        }
        lines.append("Entities already registered, with the ids of their records:\n" + entityLines(spec))
        let rules = spec.rules.prefix(150).map { "- \($0.id): \($0.method) \($0.path) → \($0.operation.rawValue) \($0.entity ?? "")" }
        lines.append("Rules already registered (do not repeat them):\n" + (rules.isEmpty ? "(none)" : rules.joined(separator: "\n")))
        if !problems.isEmpty {
            lines.append("Your previous answer was refused for these reasons; fix them:\n" + problems.map { "- " + $0 }.joined(separator: "\n"))
        }
        lines.append("Return the rules, entities and records for every endpoint of this group.")
        return lines.joined(separator: "\n\n")
    }

    /// One line per entity: its fields and the ids (with names) of its first records.
    static func entityLines(_ spec: StudioEnvironmentSpec, seed: [String: [StudioJSON]]? = nil) -> String {
        let seed = seed ?? spec.seed
        let lines = spec.entities.map { entity -> String in
            let fields = entity.fields.map { field in
                "\(field.name):\(field.type)\(field.required ? "!" : "")" + (field.references.map { "→\($0)" } ?? "")
            }.joined(separator: ", ")
            let records = seed[entity.name] ?? []
            let ids = records.prefix(12).compactMap { record -> String? in
                guard let id = record[entity.idField]?.identityKey else { return nil }
                let label = StudioCoherence.label(of: record)
                return label.isEmpty ? id : "\(id) \"\(label)\""
            }
            return "- \(entity.name) (id \(entity.idField)): \(fields)"
                + (ids.isEmpty ? " — no records" : " — records: " + ids.joined(separator: ", ") + (records.count > ids.count ? ", …" : ""))
        }
        return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
    }

    static let refillSystem = """
        You write seed records for MarkView UI Studio's simulated backend: the records one entity starts with in every \
        scenario. UI Studio is a mock-up (nothing is checked for real), and its records must make every screen show content.
        - Keep the entity's fields and their types. A field that points at another entity holds an id from the records \
          listed for that entity.
        - Coverage: every value a list filters or groups by gets 2-4 records. Give the entity 6-12 records in all, more only \
          when coverage needs them, at most 60.
        - Keep the ids listed as kept, with what they stand for: other records point at them.
        - Realistic, varied values in the application's language and domain; never real people's data, never real credentials.
        Return the records as one JSON array in `json`.
        """ + "\n" + StudioPrompts.dataNotInstructions

    static func refillPrompt(_ entity: StudioEntity, spec: StudioEnvironmentSpec, seed: [String: [StudioJSON]],
                             gaps: [StudioCoherenceGap], keep: [String]) -> String {
        var lines = ["Write new seed records for the simulated entity `\(entity.name)` (id field `\(entity.idField)`)."]
        lines.append("Fields:\n" + entity.fields.map { field in
            var text = "- \(field.name): \(field.type)" + (field.required ? ", required" : "")
            if let values = field.enumValues { text += ", one of " + values.joined(separator: ", ") }
            if let target = StudioCoherence.referencedEntity(field, of: entity, in: spec) { text += ", an id of \(target)" }
            return text
        }.joined(separator: "\n"))
        let lists = spec.rules.filter { $0.entity == entity.name && $0.operation == .list }.map { rule in
            "- \(rule.method) \(rule.path)" + ((rule.filters ?? []).isEmpty ? "" : ", filtered by " + (rule.filters ?? []).joined(separator: ", "))
        }
        lines.append("Lists that show it:\n" + (lists.isEmpty ? "(none)" : lists.joined(separator: "\n")))
        let targets = Set(entity.fields.compactMap { StudioCoherence.referencedEntity($0, of: entity, in: spec) })
        var related = spec
        related.entities = spec.entities.filter { targets.contains($0.name) }
        lines.append("Records it may point at:\n" + entityLines(related, seed: seed))
        if !gaps.isEmpty { lines.append("What the check of the current records found:\n" + gaps.map { "- " + $0.line }.joined(separator: "\n")) }
        if !keep.isEmpty { lines.append("Ids to keep (other records point at them): " + keep.prefix(60).joined(separator: ", ")) }
        lines.append("Return the new records of \(entity.name).")
        return lines.joined(separator: "\n\n")
    }

    static let refillSchema: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
        "json": ["type": "string", "description": "JSON array of the entity's records"],
        "assumptions": ["type": "array", "items": ["type": "string"]]], "required": ["json", "assumptions"]]

    /// The records in an answer of `refillSchema`; nil when `json` is not a JSON array.
    static func refill(from structured: Any?) -> StudioMapRefill? {
        guard let object = structured as? [String: Any], let text = object["json"] as? String,
              let records = StudioJSON(text: text)?.arrayValue else { return nil }
        return StudioMapRefill(records: records, assumptions: (object["assumptions"] as? [Any] ?? []).compactMap { $0 as? String })
    }
}

// MARK: - Mapper

/// Makes the application's map in the background (REQ-014) and refills the seed. It changes the environment only through its
/// hooks, which the session gives it: the same commit path as every preparation, and the environment file.
@MainActor
final class StudioEnvironmentMapper: ObservableObject {
    enum Phase: String, Sendable { case idle, inventory, groups, checking, refilling }

    struct Hooks {
        /// The environment as the simulation has it now.
        var spec: @MainActor () -> StudioEnvironmentSpec
        /// The simulation's current records, to leave out records that exist.
        var state: @MainActor () -> [String: [StudioJSON]]
        /// Saves the map in the environment.
        var save: @MainActor (StudioEnvironmentMap?) -> Void
        /// Validates and registers a proposal; its problems, empty when it was registered.
        var commit: @MainActor (StudioProposal) -> [String]
        /// Replaces the seed of these entities; the rules stay.
        var replaceSeed: @MainActor ([String: [StudioJSON]]) -> Void
        /// The user roles the code checks and the ordinary one, after the inventory found them.
        var userRoles: @MainActor (_ roles: [String], _ ordinary: String) -> Void
        var log: @MainActor (_ problem: Bool, _ text: String) -> Void
        /// A map or a refill ended: what it did, whether seed records were replaced, and whether the person asked for it.
        var finished: @MainActor (_ summary: String, _ refilled: Bool, _ requested: Bool) -> Void
    }

    @Published private(set) var map: StudioEnvironmentMap?
    @Published private(set) var phase: Phase = .idle
    /// Groups (or entities, while refilling) finished, of `total`.
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    /// What the last coherence check found.
    @Published private(set) var gaps: [StudioCoherenceGap] = []

    var limits = StudioMapLimits()
    var hooks: Hooks?
    weak var queue: StudioPreparationQueue?
    var assistant: StudioMapAssistant?

    private var task: Task<Void, Never>?
    private var context: StudioMapContext?
    private var runningContracts: Set<String> = []
    private var registered: [String: [String]] = [:]
    /// Requests waiting for the group that has their endpoint, by group id.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var stopRequested = false
    private var closing = false

    var isRunning: Bool { task != nil }

    /// What the banner says.
    var progressText: String {
        switch phase {
        case .idle: return ""
        case .inventory: return "Mapping the application's APIs: listing the services and endpoints its code calls"
        case .groups: return "Mapping the application's APIs: \(done) of \(total) group\(total == 1 ? "" : "s")"
        case .checking: return "Mapping the application's APIs: checking that the data is coherent"
        case .refilling: return "Refilling the simulated data: \(done) of \(total) entit\(total == 1 ? "y" : "ies")"
        }
    }

    /// Whether the map can be resumed: it stopped, failed, was interrupted, or left groups that failed.
    var canResume: Bool {
        guard !isRunning, let map else { return false }
        return map.status != .complete || map.groups.contains { $0.status == .failed && $0.attempts < limits.groupSessions }
    }

    func load(_ map: StudioEnvironmentMap?) {
        guard !isRunning else { return }
        self.map = map
    }

    /// Whether a session opening `appFolder` maps it: no map for it yet, or one a closed session left unfinished, or an
    /// inventory that failed fewer than `attempts` times, or a completed map of an older version that misses what this
    /// application's inventory lists now (REQ-016: an Electron renderer's preload bridge). Another completed map and one
    /// the person cancelled are left as they are.
    static func needsMapping(_ map: StudioEnvironmentMap?, appFolder: String, attempts: Int = StudioMapLimits().inventoryAttempts,
                             electron: Bool = false) -> Bool {
        guard let map, map.appFolder == appFolder else { return true }
        switch map.status {
        case .mapping: return true
        case .failed: return map.inventoryAttempts < attempts
        case .complete: return map.isOutdated(electron: electron)
        case .cancelled: return false
        }
    }

    /// Maps the application, or resumes its map; `fresh` starts over (Map again), `retryFailed` prepares the groups that
    /// failed again however often they did (the person's Resume).
    func start(_ context: StudioMapContext, fresh: Bool = false, retryFailed: Bool = false) {
        guard task == nil, !closing, hooks != nil, queue != nil, assistant != nil else { return }
        stopRequested = false
        self.context = context
        task = Task { [weak self] in
            await self?.runMap(context, fresh: fresh, retryFailed: retryFailed)
            self?.ended()
        }
    }

    /// Regenerates the seed of every entity (Refill data); the rules stay.
    func refillAll(_ context: StudioMapContext) {
        guard task == nil, !closing, let hooks, assistant != nil else { return }
        stopRequested = false
        self.context = context
        let spec = hooks.spec()
        let names = spec.entities.map(\.name).filter { name in
            spec.rules.contains { $0.entity == name } || !(spec.seed[name] ?? []).isEmpty
        }
        task = Task { [weak self] in
            await self?.runRefill(names)
            self?.ended()
        }
    }

    /// The person's Cancel: running group preparations end, no other one starts, and the map waits for Resume.
    func cancel() {
        guard task != nil else { return }
        stopRequested = true
        queue?.cancelMapGroups(runningContracts)
        task?.cancel()
    }

    /// The session closes: the work ends without changing the saved map, so the next session resumes it.
    func close() {
        closing = true
        stopRequested = true
        queue?.cancelMapGroups(runningContracts)
        task?.cancel()
        let waiting = waiters.values.flatMap { $0 }
        waiters = [:]
        waiting.forEach { $0.resume() }
    }

    /// Waits while a group being prepared has the endpoint of this request (REQ-014): its rule is about to be registered, so
    /// the request does not start a second model call for it. A request whose group is not being prepared does not wait.
    func waitForEndpoint(_ method: String, url: URL) async {
        guard let map, let id = map.groups.first(where: { group in
            group.status == .preparing && runningContracts.contains("Map \(group.id)")
                && group.endpoints.contains { StudioMapPlanner.matches($0, service: map.service(group.service), method: method, url: url,
                                                                      appOrigin: context?.appOrigin) }
        })?.id else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    private func groupEnded(_ id: String) {
        waiters.removeValue(forKey: id)?.forEach { $0.resume() }
    }

    private func ended() {
        task = nil
        phase = .idle
        runningContracts = []
        let waiting = waiters.values.flatMap { $0 }
        waiters = [:]
        waiting.forEach { $0.resume() }
    }

    private var stopped: Bool { stopRequested || closing || Task.isCancelled }

    private func update(_ change: (inout StudioEnvironmentMap) -> Void) {
        var next = map ?? StudioEnvironmentMap()
        change(&next)
        map = next
        if phase == .groups { done = next.finishedGroups }
        if !closing { hooks?.save(next) }
    }

    private func updateGroup(_ id: String, _ change: (inout StudioMapGroup) -> Void) {
        update { map in
            guard let index = map.groups.firstIndex(where: { $0.id == id }) else { return }
            change(&map.groups[index])
        }
    }

    private func log(_ text: String, problem: Bool = false) {
        guard !closing else { return }
        hooks?.log(problem, text)
    }

    private static func seconds(since start: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(start)) }

    /// The run ended early: the person's Cancel leaves the map cancelled (groups that were preparing wait again); a closing
    /// session leaves the saved map as it was, so the next session resumes it.
    private func stoppedEarly() {
        guard !closing else { return }
        update { map in
            map.status = .cancelled
            map.message = "Cancelled by the person."
            for index in map.groups.indices where map.groups[index].status == .preparing { map.groups[index].status = .pending }
        }
        let left = (map?.groups.count ?? 0) - (map?.finishedGroups ?? 0)
        log("Mapping cancelled: \(map?.finishedGroups ?? 0) of \(map?.groups.count ?? 0) groups are prepared"
            + (left > 0 ? "; the other \(left) wait for Resume in the Environment panel" : ""))
    }

    // MARK: Mapping

    private func runMap(_ context: StudioMapContext, fresh: Bool, retryFailed: Bool) async {
        var start = fresh ? StudioEnvironmentMap() : (map ?? StudioEnvironmentMap())
        if start.appFolder != context.appFolder || (!start.inventoried && start.status != .failed) { start = StudioEnvironmentMap() }
        let label = context.appFolder.isEmpty ? "the project" : context.appFolder
        // An older map is inventoried again and extended (REQ-016); its first try has inventory attempts of its own.
        let extending = start.isOutdated(electron: context.electron)
        update { map in
            map = start
            map.appFolder = context.appFolder
            map.status = .mapping
            map.message = ""
            map.finished = nil
            if !map.inventoried { map.started = Date() }
            if extending && start.status == .complete { map.inventoryAttempts = 0 }
            if retryFailed {
                for index in map.groups.indices where map.groups[index].status == .failed { map.groups[index].attempts = 0 }
            }
        }
        let groupsBefore = map?.groups.count ?? 0
        if map?.inventoried != true || extending {
            phase = .inventory
            guard await inventory(context, label: label, extending: extending) else { return }
        } else {
            update { map in map.services = StudioMapPlanner.resolve(map.services, connections: context.connections) }
            let left = StudioMapPlanner.resumable(map ?? StudioEnvironmentMap(), sessions: limits.groupSessions).count
            log("Resuming the application's map of \(label): \(left) of \(map?.groups.count ?? 0) groups left")
        }
        if stopped { return stoppedEarly() }

        let todo = StudioMapPlanner.resumable(map ?? StudioEnvironmentMap(), sessions: limits.groupSessions)
        update { map in
            for index in map.groups.indices where todo.contains(map.groups[index].id) { map.groups[index].status = .pending }
        }
        total = map?.groups.count ?? 0
        phase = .groups
        done = map?.finishedGroups ?? 0
        await runGroups(todo, context)
        if stopped { return stoppedEarly() }

        // The coherence check is about what the map prepared; an inventory that found nothing, or an extension that added no
        // group, leaves the data as it is.
        let added = extending && (map?.groups.count ?? 0) > groupsBefore
        let refilled = (map?.groups.isEmpty ?? true) || (extending && !added) ? false : await checkAndRefill(requested: false)
        if stopped { return stoppedEarly() }
        update { map in
            map.status = .complete
            map.finished = Date()
            map.message = ""
        }
        let current = map ?? StudioEnvironmentMap()
        let failed = current.groups.filter { $0.status == .failed || $0.status == .unsupported }
        let rules = current.groups.reduce(0) { $0 + $1.rules.count }
        let spec = hooks?.spec() ?? StudioEnvironmentSpec()
        let uncovered = current.groups.flatMap { group in
            group.endpoints.filter { !StudioMapPlanner.isCovered($0, service: current.service(group.service), rules: spec.rules) }
        }
        let summary = "Mapping finished: \(current.finishedGroups - failed.count) of \(current.groups.count) groups prepared, \(rules) rules"
            + (current.endpointCount > 0 ? ", \(current.endpointCount - uncovered.count) of \(current.endpointCount) endpoints with a rule" : "")
            + (failed.isEmpty ? "" : "; not prepared: " + failed.prefix(4).map(\.id).joined(separator: ", "))
            + (gaps.isEmpty ? "" : "; \(gaps.count) data gap\(gaps.count == 1 ? "" : "s") left")
        if current.groups.isEmpty {
            log("Mapping finished: the inventory found no HTTP endpoint; requests are prepared as the pages make them")
            return
        }
        log(summary, problem: !failed.isEmpty)
        hooks?.finished(summary + ".", refilled, false)
    }

    /// The inventory call; false when the map ends here (failed or stopped). `extending` keeps what an older map prepared
    /// and adds what it misses (REQ-016).
    private func inventory(_ context: StudioMapContext, label: String, extending: Bool = false) async -> Bool {
        guard let assistant else { return false }
        log(extending
            ? "Extending the application's map of \(label) (version \(map?.version ?? 1)): the assistant lists the services and endpoints "
              + "its code calls again, its preload bridge included; the rules and data prepared before stay"
            : "Mapping the application's APIs of \(label): the assistant lists the services and endpoints its code calls")
        update { $0.inventoryAttempts += 1 }
        let begun = Date()
        let request = StudioMapRequest(prompt: StudioMapPrompts.inventoryPrompt(context), timeout: limits.inventoryDeadline + 5, label: "ui-studio:map")
        let answer = await StudioPreparationQueue.withDeadline(Date().addingTimeInterval(limits.inventoryDeadline)) {
            try await assistant.inventory(request)
        }
        if stopped { return false }
        let message: String
        switch answer {
        case .value(let inventory) where extending:
            let before = map ?? StudioEnvironmentMap()
            let (next, added) = StudioMapPlanner.extended(before, with: inventory, rules: hooks?.spec().rules ?? [],
                                                          connections: context.connections, limits: limits)
            update { $0 = next }
            log("Inventory after \(Self.seconds(since: begun)): \(inventory.entries.count) endpoints; the map of version \(before.version) is "
                + "extended to version \(next.version) with \(added.reduce(0) { $0 + $1.endpoints.count }) endpoint(s) without a rule in "
                + "\(added.count) new group(s)" + (added.isEmpty ? "" : ": " + added.prefix(6).map(\.id).joined(separator: ", ")))
            for note in inventory.notes.filter({ !before.notes.contains($0) }).prefix(8) { log("Inventory note: " + note) }
            if before.userRoles.isEmpty, !inventory.roles.isEmpty { hooks?.userRoles(inventory.roles, inventory.ordinaryRole) }
            return true
        case .value(let inventory):
            let groups = StudioMapPlanner.groups(inventory, limits: limits)
            update { map in
                map.services = StudioMapPlanner.resolve(inventory.services, connections: context.connections)
                map.groups = groups
                map.notes = inventory.notes
                map.userRoles = inventory.roles
                map.ordinaryRole = inventory.ordinaryRole
                map.inventoried = true
            }
            let services = (map?.services ?? []).map { service in
                service.name + (service.isApplication ? " (the application's server)"
                                : service.address.map { $0.isEmpty ? "" : " → \($0)" } ?? (service.variable.isEmpty ? " (address unknown)" : " (\(service.variable), address unknown)"))
            }
            log("Inventory after \(Self.seconds(since: begun)): \(map?.services.count ?? 0) services, \(inventory.entries.count) endpoints "
                + "in \(groups.count) groups" + (services.isEmpty ? "" : " — " + services.joined(separator: ", ")))
            for note in inventory.notes.prefix(8) { log("Inventory note: " + note) }
            if !inventory.roles.isEmpty {
                log("Inventory: the code checks the user roles " + inventory.roles.joined(separator: ", ")
                    + (inventory.ordinaryRole.isEmpty ? "" : "; an ordinary signed-in user is \(inventory.ordinaryRole)"))
                hooks?.userRoles(inventory.roles, inventory.ordinaryRole)
            }
            return true
        case .failed(let reason): message = "The inventory of the application's API failed: \(reason)"
        case .timedOut: message = "The assistant did not list the application's API within \(Int(limits.inventoryDeadline)) s."
        case .cancelled: return false
        }
        update { map in
            map.status = .failed
            map.message = message
        }
        log(message, problem: true)
        return false
    }

    /// Prepares `ids`, `limits.concurrent` at a time. A group whose preparation someone else ended (Stop of the current work)
    /// is prepared again, at most twice.
    private func runGroups(_ ids: [String], _ context: StudioMapContext) async {
        var pending = ids
        var again: [String: Int] = [:]
        let concurrent = max(1, limits.concurrent)
        await withTaskGroup(of: String?.self) { tasks in
            var active = 0
            while active < concurrent, !stopped, !pending.isEmpty {
                let id = pending.removeFirst()
                tasks.addTask { @MainActor [weak self] in await self?.prepareGroup(id, context) }
                active += 1
            }
            while let result = await tasks.next() {
                active -= 1
                if let id = result, !stopped, again[id, default: 0] < 2 {
                    again[id, default: 0] += 1
                    pending.append(id)
                }
                while active < concurrent, !stopped, !pending.isEmpty {
                    let id = pending.removeFirst()
                    tasks.addTask { @MainActor [weak self] in await self?.prepareGroup(id, context) }
                    active += 1
                }
            }
        }
    }

    /// Prepares one group through the queue. Returns its id when it should be prepared again.
    private func prepareGroup(_ id: String, _ context: StudioMapContext) async -> String? {
        guard !stopped, let queue, let hooks, let assistant, let group = map?.groups.first(where: { $0.id == id }) else { return nil }
        let service = map?.service(group.service)
        // Every endpoint got its rule meanwhile (a request of the page was prepared): nothing to ask.
        if StudioMapPlanner.isCovered(group, service: service, rules: hooks.spec().rules) {
            updateGroup(id) { group in
                group.status = .done
                group.message = "Every endpoint already had a rule."
            }
            log("Map group \(id): every endpoint already had a rule — \(done) of \(total) groups")
            return nil
        }
        updateGroup(id) { group in
            group.status = .preparing
            group.attempts += 1
            group.message = ""
        }
        log("Mapping group \(id): \(group.endpoints.count) endpoint\(group.endpoints.count == 1 ? "" : "s") of \(group.service)")
        let begun = Date()
        let contract = "Map \(id)"
        runningContracts.insert(contract)
        registered[id] = nil
        var preparation = StudioPreparationContext(contract: contract, method: "GET", url: group.service, headers: [:], body: nil,
                                                   attempt: 1, problems: [])
        preparation.mapGroup = id
        let preparer = StudioMapGroupPreparer(assistant: assistant, timeout: queue.limits.cliTimeout(for: preparation)) { [weak self] problems in
            await self?.groupPrompt(id, context: context, problems: problems) ?? ""
        }
        let outcome = await queue.prepareMapGroup(preparation, preparer: preparer, commit: { [weak self] proposal in
            self?.commitGroup(proposal, id: id) ?? ["The session is closed."]
        })
        runningContracts.remove(contract)
        defer { groupEnded(id) }
        let took = Self.seconds(since: begun)
        func finish(_ status: StudioMapGroup.Status, _ message: String) {
            updateGroup(id) { group in
                group.status = status
                group.message = message
                if status == .done { group.rules = self.registered[id] ?? [] }
            }
        }
        switch outcome {
        case .registered:
            finish(.done, "")
            log("Map group \(id): \(registered[id]?.count ?? 0) rules after \(took) — \(done) of \(total) groups")
        case .unsupported(let reason):
            finish(.unsupported, reason)
            log("Map group \(id): not simulated (\(reason)) — \(done) of \(total) groups", problem: true)
        case .failed(let reason):
            finish(.failed, reason)
            log("Map group \(id): failed after \(took): \(reason) — \(done) of \(total) groups", problem: true)
        case .timedOut:
            let seconds = Int(queue.limits.deadline(for: preparation))
            finish(.failed, "The agent did not finish within \(seconds) s.")
            log("Map group \(id): the agent did not finish within \(seconds) s — \(done) of \(total) groups", problem: true)
        case .cancelled, .stale, .limitReached:
            updateGroup(id) { group in
                group.status = .pending
                group.attempts = max(0, group.attempts - 1)
            }
            if stopped { return nil }
            log("Map group \(id) was interrupted; it is prepared again")
            return id
        }
        return nil
    }

    private func groupPrompt(_ id: String, context: StudioMapContext, problems: [String]) -> String {
        guard let map, let group = map.groups.first(where: { $0.id == id }) else { return "" }
        return StudioMapPrompts.groupPrompt(group, service: map.service(group.service), context: context,
                                            spec: hooks?.spec() ?? StudioEnvironmentSpec(), problems: problems)
    }

    /// The commit of a group: what is already registered is left out, the rest goes through the session's commit.
    private func commitGroup(_ proposal: StudioProposal, id: String) -> [String] {
        guard let hooks, !closing else { return ["The session is closed."] }
        let (clean, dropped) = StudioMapPlanner.deduplicated(proposal, spec: hooks.spec(), state: hooks.state())
        if !dropped.isEmpty { log("Map group \(id): left out what was already registered: " + dropped.prefix(6).joined(separator: "; ")) }
        if clean.rules.isEmpty, !proposal.rules.isEmpty {
            registered[id] = []
            return []
        }
        let problems = hooks.commit(clean)
        if problems.isEmpty { registered[id] = clean.rules.map(\.id) }
        return problems
    }

    // MARK: Coherence and refill

    /// Checks the seed, logs what it found, and refills the entities with gaps (at most `limits.maxRefills`, one call each).
    /// Returns whether seed records were replaced.
    private func checkAndRefill(requested: Bool) async -> Bool {
        guard let hooks else { return false }
        phase = .checking
        let found = StudioCoherence.check(hooks.spec())
        gaps = found
        logGaps(found, label: "Coherence check")
        guard !found.isEmpty else {
            update { $0.gaps = [] }
            return false
        }
        var names: [String] = []
        for gap in found where !names.contains(gap.entity) { names.append(gap.entity) }
        let refilled = await refillEntities(Array(names.prefix(limits.maxRefills)), gaps: found, full: false)
        if stopped { return false }
        let after = StudioCoherence.check(hooks.spec())
        gaps = after
        if refilled { logGaps(after, label: "Coherence check after the refill") }
        update { $0.gaps = after.prefix(20).map(\.line) }
        return refilled
    }

    private func logGaps(_ gaps: [StudioCoherenceGap], label: String) {
        if gaps.isEmpty {
            log("\(label): no gaps — every reference points at a record that exists and every value a list filters by has records")
            return
        }
        log("\(label): \(gaps.count) gap\(gaps.count == 1 ? "" : "s")", problem: true)
        for gap in gaps.prefix(12) { log("\(label): " + gap.line, problem: true) }
    }

    private func runRefill(_ names: [String]) async {
        guard let hooks else { return }
        let found = StudioCoherence.check(hooks.spec())
        log("Refilling the simulated data of \(names.count) entit\(names.count == 1 ? "y" : "ies"); the rules stay")
        let refilled = await refillEntities(names, gaps: found, full: true)
        if stopped {
            if !closing { log("Refilling the data was cancelled; the records are as they were") }
            return
        }
        let after = StudioCoherence.check(hooks.spec())
        gaps = after
        logGaps(after, label: "Coherence check after the refill")
        if map != nil { update { $0.gaps = after.prefix(20).map(\.line) } }
        let summary = refilled ? "Refilled the simulated data of \(names.count) entities" + (after.isEmpty ? "." : "; \(after.count) data gaps left.")
            : "The simulated data was not refilled: no answer could be used."
        hooks.finished(summary, refilled, true)
    }

    /// New seed for `names`, in the order of their references, `limits.concurrent` calls at a time. Each answer is checked like
    /// a proposal's records against the data written so far; an invalid one keeps the entity's records. Everything is applied
    /// at once at the end, and after a check (not for a full refill) only when it leaves fewer gaps. Returns whether records
    /// were replaced.
    private func refillEntities(_ names: [String], gaps: [StudioCoherenceGap], full: Bool) async -> Bool {
        guard let hooks, let assistant, !names.isEmpty else { return false }
        let spec = hooks.spec()
        var seed = spec.seed
        var replaced: [String: [StudioJSON]] = [:]
        let refilling = Set(names)
        phase = .refilling
        total = names.count
        done = 0
        for level in StudioCoherence.refillOrder(names, spec: spec) {
            var rest = level
            while !rest.isEmpty {
                if stopped { return false }
                let batch = Array(rest.prefix(max(1, limits.concurrent)))
                rest.removeFirst(batch.count)
                var requests: [(String, StudioMapRequest, [String])] = []
                for name in batch {
                    guard let entity = spec.entity(name) else { continue }
                    let keep = full ? Self.referencedIDs(of: name, spec: spec, seed: seed, except: refilling)
                        : Self.referencedIDs(of: name, spec: spec, seed: seed, except: [])
                    let prompt = StudioMapPrompts.refillPrompt(entity, spec: spec, seed: seed, gaps: gaps.filter { $0.entity == name }, keep: keep)
                    requests.append((name, StudioMapRequest(prompt: prompt, timeout: limits.refillDeadline + 5, label: "ui-studio:map-refill"), keep))
                    log("Refilling the records of \(name)")
                }
                let deadline = limits.refillDeadline
                let answers = await withTaskGroup(of: (String, StudioPreparationQueue.Answer<StudioMapRefill>).self) { group in
                    for (name, request, _) in requests {
                        group.addTask {
                            (name, await StudioPreparationQueue.withDeadline(Date().addingTimeInterval(deadline)) { try await assistant.refill(request) })
                        }
                    }
                    var answers: [String: StudioPreparationQueue.Answer<StudioMapRefill>] = [:]
                    for await (name, answer) in group { answers[name] = answer }
                    return answers
                }
                if stopped { return false }
                for (name, _, keep) in requests {
                    done += 1
                    guard let entity = spec.entity(name) else { continue }
                    switch answers[name] {
                    case .value(let refill):
                        let problems = Self.refillProblems(refill.records, entity: entity, spec: spec, seed: seed, keep: keep, limits: limits)
                        if problems.isEmpty {
                            seed[name] = refill.records
                            replaced[name] = refill.records
                            log("Refilled \(name): \(refill.records.count) records")
                        } else {
                            log("The new records of \(name) were not used: " + problems.prefix(4).joined(separator: "; "), problem: true)
                        }
                    case .failed(let reason): log("Refilling \(name) failed: \(reason)", problem: true)
                    case .timedOut: log("Refilling \(name): the agent did not finish within \(Int(deadline)) s", problem: true)
                    case .cancelled, .none: return false
                    }
                }
            }
        }
        guard !replaced.isEmpty else { return false }
        if !full {
            var candidate = spec
            candidate.seed = seed
            let before = StudioCoherence.check(spec).count, after = StudioCoherence.check(candidate).count
            guard after < before else {
                log("The refilled records were not used: they leave \(after) gaps, the current ones \(before)", problem: true)
                return false
            }
        }
        hooks.replaceSeed(replaced)
        return true
    }

    /// Ids of `name`'s records that records of other entities (not those in `except`) point at.
    static func referencedIDs(of name: String, spec: StudioEnvironmentSpec, seed: [String: [StudioJSON]], except: Set<String>) -> [String] {
        var ids: [String] = []
        for entity in spec.entities where entity.name != name && !except.contains(entity.name) {
            for field in entity.fields where StudioCoherence.referencedEntity(field, of: entity, in: spec) == name {
                for record in seed[entity.name] ?? [] {
                    let value = record[field.name]
                    for id in (value?.arrayValue ?? value.map { [$0] } ?? []).compactMap(\.identityKey) where !ids.contains(id) { ids.append(id) }
                }
            }
        }
        return ids
    }

    /// Why new records of `entity` cannot replace its seed: the validator's record checks against the data written so far,
    /// ids used twice, ids other records point at that are gone, and the size.
    static func refillProblems(_ records: [StudioJSON], entity: StudioEntity, spec: StudioEnvironmentSpec, seed: [String: [StudioJSON]],
                               keep: [String], limits: StudioMapLimits) -> [String] {
        if records.isEmpty { return ["no records"] }
        if records.count > limits.maxRefillRecords { return ["\(records.count) records, more than \(limits.maxRefillRecords)"] }
        var state = seed
        state[entity.name] = records
        var problems: [String] = []
        var ids = Set<String>()
        for record in records {
            problems += StudioValidator.problems(record: record, entity: entity, state: state, spec: spec)
            if let id = record[entity.idField]?.identityKey, !ids.insert(id).inserted { problems.append("\(entity.name): id \(id) is used twice") }
        }
        let missing = keep.filter { !ids.contains($0) }
        if !missing.isEmpty { problems.append("ids other records point at are missing: " + missing.prefix(6).joined(separator: ", ")) }
        return problems
    }
}
