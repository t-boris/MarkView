import Foundation

// REQ-014 (DEC-007): UI Studio places the application in an artificial environment without knowing its backend in advance.
// Once per application, in the background, the assistant lists the API surface its code calls (services, endpoints grouped by
// resource, their call sites, from the browser and from the server); each group is prepared with the preparation schema and
// committed like any other preparation, and a check verifies that the seed is coherent: references point at records that
// exist, and every value a list filters by has records. The map is saved in `environment.json` (`spec.map`), so a completed
// map is not redone and an interrupted one resumes. This file holds the map and the pure functions over it; the driver is
// `StudioEnvironmentMapper` (UIStudioEnvironmentMapper.swift).

/// A service the application calls: one base address, reached from the page, from the server or from both.
struct StudioMapService: Codable, Hashable, Sendable {
    enum Side: String, Codable, CaseIterable, Sendable { case browser, server, both }

    /// The name of the application's own server (relative paths, its route handlers).
    static let application = "app"

    var name: String
    /// The base address written in the code, or "".
    var baseURL = ""
    /// The environment variable that holds the address, or "".
    var variable = ""
    var side: Side = .browser
    /// What its rules' paths start with: "" for the application's own server; the address of the simulated connection of
    /// `variable`, or `baseURL`, otherwise (origin and path, no trailing slash); nil while UI Studio does not know it.
    var address: String? = nil

    var isApplication: Bool { name == Self.application }

    private enum CodingKeys: String, CodingKey { case name, baseURL, variable, side, address }
}

/// One request the application's code can make, as the inventory found it.
struct StudioMapEndpoint: Codable, Hashable, Sendable {
    var method: String
    /// The path after the service's address, `:name` for the parts that vary: `/bundles/:id`.
    var path: String
    /// `file:line` of one place that makes the request, relative to the project root.
    var callSite = ""
    var side: StudioMapService.Side = .browser
    var resource = ""

    private enum CodingKeys: String, CodingKey { case method, path, callSite, side, resource }
}

/// Endpoints of one service prepared together, at most `StudioMapLimits.groupSize` of them.
struct StudioMapGroup: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case pending, preparing, done, failed
        /// The assistant answered that MarkView cannot serve these requests over HTTP.
        case unsupported
    }

    var id: String
    var service: String
    /// The resources it covers, for the person.
    var resource: String
    var endpoints: [StudioMapEndpoint]
    var status: Status = .pending
    /// How many times a session started preparing it.
    var attempts = 0
    /// The rules it registered.
    var rules: [String] = []
    var message = ""

    var isFinished: Bool { [.done, .failed, .unsupported].contains(status) }

    private enum CodingKeys: String, CodingKey { case id, service, resource, endpoints, status, attempts, rules, message }
}

/// The application's map (REQ-014), saved in the environment. Optional there, so files written before it still load.
struct StudioEnvironmentMap: Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable {
        /// Listing the API or preparing its groups; also when a session closed meanwhile, so the next one resumes.
        case mapping
        case complete
        /// The inventory failed; the next session tries again (`StudioMapLimits.inventoryAttempts` times in all).
        case failed
        /// Stopped by the person; it resumes only when the person asks.
        case cancelled
    }

    var status: Status = .mapping
    /// The application folder the map is for, relative to the project root ("" for the root).
    var appFolder = ""
    var started: Date? = nil
    var finished: Date? = nil
    /// The inventory answered; `services` and `groups` hold it.
    var inventoried = false
    var inventoryAttempts = 0
    var services: [StudioMapService] = []
    var groups: [StudioMapGroup] = []
    /// What the inventory found that is not an HTTP request, and what it could not follow.
    var notes: [String] = []
    /// What the last coherence check found, one line per gap.
    var gaps: [String] = []
    /// Why the map failed or stopped.
    var message = ""
    /// The user roles the code checks (`app_metadata.role`, a role claim), and the one an ordinary signed-in user has.
    var userRoles: [String] = []
    var ordinaryRole = ""
    /// The map's format: what its inventory was asked to list. A map saved without one is version 1.
    var version = StudioEnvironmentMap.currentVersion

    /// 1: REQ-014. 2: the inventory lists an Electron renderer's preload bridge (REQ-016).
    static let currentVersion = 2

    private enum CodingKeys: String, CodingKey {
        case status, appFolder, started, finished, inventoried, inventoryAttempts, services, groups, notes, gaps, message, userRoles, ordinaryRole
        case version
    }

    var endpointCount: Int { groups.reduce(0) { $0 + $1.endpoints.count } }
    var finishedGroups: Int { groups.filter(\.isFinished).count }
    /// Every group was prepared, so a page needs no preparation ahead (BUG-074) for the requests the map covers.
    var coversEveryGroup: Bool { status == .complete && !groups.isEmpty && groups.allSatisfy { $0.status == .done } }

    func service(_ name: String) -> StudioMapService? { services.first { $0.name == name } }

    /// An inventoried map of an older version that misses what the current inventory lists for this application, so it is
    /// extended (`StudioMapPlanner.extended`): version 2 adds the preload bridge, which only an Electron renderer has.
    func isOutdated(electron: Bool) -> Bool { inventoried && version < Self.currentVersion && electron }
}

// MARK: - Lenient decoding

// A damaged entry must not make environment.json unreadable (UI Studio would then replace it): unknown values fall back, a
// missing field is empty, and an entry that does not decode is left out.

private struct StudioMapLossy<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private extension KeyedDecodingContainer {
    func text(_ key: Key) -> String { ((try? decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
    func list<Value: Decodable>(_ key: Key) -> [Value] {
        (((try? decodeIfPresent([StudioMapLossy<Value>].self, forKey: key)) ?? nil) ?? []).compactMap(\.value)
    }
}

extension StudioMapService {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        baseURL = container.text(.baseURL)
        variable = container.text(.variable)
        side = Side(rawValue: container.text(.side)) ?? .browser
        address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? nil
    }
}

extension StudioMapEndpoint {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        path = try container.decode(String.self, forKey: .path)
        callSite = container.text(.callSite)
        side = StudioMapService.Side(rawValue: container.text(.side)) ?? .browser
        resource = container.text(.resource)
    }
}

extension StudioMapGroup {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        service = container.text(.service)
        resource = container.text(.resource)
        endpoints = container.list(.endpoints)
        status = Status(rawValue: container.text(.status)) ?? .pending
        attempts = ((try? container.decodeIfPresent(Int.self, forKey: .attempts)) ?? nil) ?? 0
        rules = ((try? container.decodeIfPresent([String].self, forKey: .rules)) ?? nil) ?? []
        message = container.text(.message)
    }
}

extension StudioEnvironmentMap {
    /// Never throws: a map that is not an object reads as a map that was never made.
    init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        status = Status(rawValue: container.text(.status)) ?? .mapping
        appFolder = container.text(.appFolder)
        started = (try? container.decodeIfPresent(Date.self, forKey: .started)) ?? nil
        finished = (try? container.decodeIfPresent(Date.self, forKey: .finished)) ?? nil
        inventoried = ((try? container.decodeIfPresent(Bool.self, forKey: .inventoried)) ?? nil) ?? false
        inventoryAttempts = ((try? container.decodeIfPresent(Int.self, forKey: .inventoryAttempts)) ?? nil) ?? 0
        services = container.list(.services)
        groups = container.list(.groups)
        notes = ((try? container.decodeIfPresent([String].self, forKey: .notes)) ?? nil) ?? []
        gaps = ((try? container.decodeIfPresent([String].self, forKey: .gaps)) ?? nil) ?? []
        message = container.text(.message)
        userRoles = ((try? container.decodeIfPresent([String].self, forKey: .userRoles)) ?? nil) ?? []
        ordinaryRole = container.text(.ordinaryRole)
        version = ((try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
    }
}

// MARK: - Limits

/// The bounds of mapping (§12): group size, how much of an inventory is kept, how many groups run at once, and how much
/// refilling one check may ask for.
struct StudioMapLimits: Equatable, Sendable {
    /// Endpoints per group: Codex needs 30-90 s for one small preparation and did not finish a whole page in 95 s.
    var groupSize = 8
    var maxGroups = 40
    var maxEndpoints = 300
    var maxServices = 30
    /// Groups prepared at the same time. They take none of the slots the page's own preparations wait for.
    var concurrent = 2
    /// The inventory reads the whole application, so it gets longer than a page.
    var inventoryDeadline: TimeInterval = 420
    /// Sessions that try the inventory before the map waits for the person (Resume).
    var inventoryAttempts = 3
    /// Sessions in which a group that failed is tried.
    var groupSessions = 2
    /// Entities whose seed one coherence check may refill, one assistant call each.
    var maxRefills = 6
    var refillDeadline: TimeInterval = 240
    var maxRefillRecords = 120
}

// MARK: - Inventory

/// The inventory as the assistant answered it, checked and normalized (`StudioMapParsing.inventory`).
struct StudioMapInventory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var service: String
        var endpoint: StudioMapEndpoint
    }

    var services: [StudioMapService] = []
    var entries: [Entry] = []
    var notes: [String] = []
    /// The user roles the code checks, and the ordinary signed-in user's ("" when the code checks none).
    var roles: [String] = []
    var ordinaryRole = ""
}

/// The boundary of the inventory: what the assistant returned becomes services and endpoints only when it has their shape.
enum StudioMapParsing {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    /// The inventory in an answer of `StudioMapPrompts.inventorySchema`; nil when it is not one. Entries that do not fit are
    /// left out, names and paths are normalized, and an endpoint of a service the answer did not list gets that service.
    static func inventory(from structured: Any?, limits: StudioMapLimits = StudioMapLimits()) -> StudioMapInventory? {
        guard let object = structured as? [String: Any], let rawServices = object["services"] as? [Any],
              let rawEndpoints = object["endpoints"] as? [Any] else { return nil }
        var inventory = StudioMapInventory()
        var names = Set<String>()
        for case let item as [String: Any] in rawServices {
            guard let name = plainName(item["name"] as? String ?? ""), names.count < limits.maxServices, names.insert(name).inserted else { continue }
            let application = name == StudioMapService.application
            // The Electron preload bridge has one logical address, whatever the answer wrote (REQ-016).
            if name == StudioIPC.service {
                inventory.services.append(StudioMapService(name: name, baseURL: StudioIPC.origin, side: .browser))
                continue
            }
            inventory.services.append(StudioMapService(name: name, baseURL: application ? "" : baseAddress(item["baseURL"] as? String ?? ""),
                                                       variable: application ? "" : variableName(item["variable"] as? String ?? ""),
                                                       side: StudioMapService.Side(rawValue: item["side"] as? String ?? "") ?? .browser))
        }
        var seen = Set<String>()
        var dropped = 0
        for case let item as [String: Any] in rawEndpoints {
            var method = (item["method"] as? String ?? "").uppercased()
            let service = plainName(item["service"] as? String ?? "") ?? StudioMapService.application
            // A full URL of the service starts with its base address, which its rules' paths already carry.
            var raw = (item["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let base = inventory.services.first(where: { $0.name == service })?.baseURL, !base.isEmpty,
               raw.lowercased().hasPrefix(base.lowercased()) {
                raw = String(raw.dropFirst(base.count))
            }
            guard let path = templatePath(raw) else { continue }
            // A preload bridge method is called with the verb its name gives (REQ-016), so its rule must have that one.
            let ipc = service == StudioIPC.service || inventory.services.first { $0.name == service }?.baseURL == StudioIPC.origin
            if ipc, let verb = StudioIPC.verb(ofPath: path) { method = verb }
            guard methods.contains(method) else { continue }
            let side = StudioMapService.Side(rawValue: item["side"] as? String ?? "")
            if !names.contains(service) {
                guard names.count < limits.maxServices else { continue }
                names.insert(service)
                inventory.services.append(ipc ? StudioMapService(name: service, baseURL: StudioIPC.origin, side: .browser)
                                          : StudioMapService(name: service, side: side ?? .browser))
            }
            guard seen.insert("\(service) \(method) \(routeKey(path))").inserted else { continue }
            guard inventory.entries.count < limits.maxEndpoints else { dropped += 1; continue }
            let resource = plainName(item["resource"] as? String ?? "")
                ?? path.split(separator: "/").first { !$0.hasPrefix(":") }.flatMap { plainName(String($0)) } ?? "root"
            let endpoint = StudioMapEndpoint(method: method, path: path, callSite: callSite(item["callSite"] as? String ?? ""),
                                             side: side ?? inventory.services.first { $0.name == service }?.side ?? .browser,
                                             resource: resource)
            inventory.entries.append(StudioMapInventory.Entry(service: service, endpoint: endpoint))
        }
        inventory.notes = ((object["notes"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(20)
            .map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        if dropped > 0 { inventory.notes.append("\(dropped) more endpoint(s) were left out: a map keeps at most \(limits.maxEndpoints).") }
        let roles = object["userRoles"] as? [String: Any] ?? [:]
        for case let raw as String in roles["names"] as? [Any] ?? [] {
            if let name = roleName(raw), !inventory.roles.contains(name), inventory.roles.count < 20 { inventory.roles.append(name) }
        }
        if let ordinary = roleName(roles["ordinary"] as? String ?? "") {
            if !inventory.roles.contains(ordinary), inventory.roles.count < 20 { inventory.roles.append(ordinary) }
            inventory.ordinaryRole = inventory.roles.contains(ordinary) ? ordinary : ""
        }
        return inventory
    }

    /// A role as the code compares it (`customer`, `ROLE_ADMIN`, `org:member`): kept as written, without spaces; nil otherwise.
    static func roleName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count), name.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else { return nil }
        return name
    }

    /// A short lower-case name of letters, digits, `.`, `_` and `-`; nil when nothing is left.
    static func plainName(_ raw: String) -> String? {
        var name = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character)) {
                name.append(character)
            } else if !name.hasSuffix("-") {
                name.append("-")
            }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return name.isEmpty ? nil : String(name.prefix(64))
    }

    /// An http(s) address without its query and trailing slash, or "".
    static func baseAddress(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !text.contains("${") else { return "" }
        return text
    }

    /// An environment variable's name (`process.env.API_URL` → `API_URL`), or "".
    static func variableName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").last.map(String.init) ?? ""
        return StudioConnections.isValidName(name) ? name : ""
    }

    /// `file:line` relative to the project root; "" for anything else (an absolute path, a path out of the project).
    static func callSite(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty, !text.contains(".."), !text.hasPrefix("/"), !text.hasPrefix("~"), !text.contains("://") else { return "" }
        return String(text.prefix(200))
    }

    /// A route without its parameter names: `/bundles/:id` and `/bundles/:slug` are the same endpoint.
    static func routeKey(_ path: String) -> String {
        StudioRoute.segments(path).map { $0.hasPrefix(":") ? ":" : $0 }.joined(separator: "/")
    }

    /// A path template as rules write it: `/bundles/:id`. Template parts (`${id}`, `{id}`, `[slug]`, `<id>`) become
    /// parameters, a leading address part (`${API_URL}`, a full URL) and the query string are dropped. nil when the result is
    /// not a plain route.
    static func templatePath(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") {
            let rest = text[scheme.upperBound...]
            text = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        var segments = text.split(separator: "/").map(String.init)
        while let first = segments.first, isTemplate(first), isAddressPart(first) { segments.removeFirst() }
        let path = "/" + segments.map { segment -> String in
            if segment.hasPrefix(":"), segment.count > 1 { return ":" + parameterName(String(segment.dropFirst())) }
            return isTemplate(segment) ? ":" + parameterName(segment) : segment
        }.joined(separator: "/")
        guard path.count <= 300, !path.contains(".."), path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return path
    }

    private static func isTemplate(_ segment: String) -> Bool {
        segment.contains("${") || segment.contains("{") || (segment.hasPrefix("[") && segment.hasSuffix("]"))
            || (segment.hasPrefix("<") && segment.hasSuffix(">"))
    }

    /// `${API_URL}`, `${process.env.CORE_URL}`, `{baseUrl}`: the service's address written before the path.
    private static func isAddressPart(_ segment: String) -> Bool {
        let inner = segment.trimmingCharacters(in: CharacterSet(charactersIn: "${}[]<>"))
        let lowered = inner.lowercased()
        return lowered.contains("env") || lowered.contains("url") || lowered.contains("base") || lowered.contains("host")
            || inner.range(of: #"^[A-Z][A-Z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// The last identifier in a template part: `${bundle.id}` → `id`, `[...slug]` → `slug`; `id` when there is none.
    private static func parameterName(_ segment: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#) else { return "id" }
        let matches = regex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment))
        return matches.last.flatMap { Range($0.range, in: segment) }.map { String(segment[$0]) } ?? "id"
    }
}

// MARK: - Planning

/// How the inventory becomes groups, where the groups' rules point, and what is already covered.
enum StudioMapPlanner {
    /// Groups of at most `limits.groupSize` endpoints, in the inventory's order: a resource that fills a group is split, the
    /// smaller resources of one service are packed together, so a map takes few assistant calls.
    static func groups(_ inventory: StudioMapInventory, limits: StudioMapLimits = StudioMapLimits()) -> [StudioMapGroup] {
        let size = max(1, limits.groupSize)
        var services: [String] = []
        var resources: [String: [(name: String, endpoints: [StudioMapEndpoint])]] = [:]
        for entry in inventory.entries {
            if resources[entry.service] == nil {
                services.append(entry.service)
                resources[entry.service] = []
            }
            if let index = resources[entry.service]?.firstIndex(where: { $0.name == entry.endpoint.resource }) {
                resources[entry.service]?[index].endpoints.append(entry.endpoint)
            } else {
                resources[entry.service]?.append((entry.endpoint.resource, [entry.endpoint]))
            }
        }
        var groups: [StudioMapGroup] = []
        var ids = Set<String>()
        func add(_ service: String, _ names: [String], _ endpoints: [StudioMapEndpoint]) {
            let base = String((service + "/" + names.joined(separator: "+")).prefix(100))
            var id = base
            var number = 2
            while !ids.insert(id).inserted {
                id = "\(base)-\(number)"
                number += 1
            }
            groups.append(StudioMapGroup(id: id, service: service, resource: names.joined(separator: ", "), endpoints: endpoints))
        }
        for service in services {
            var packed: [String] = []
            var packedEndpoints: [StudioMapEndpoint] = []
            for resource in resources[service] ?? [] {
                if resource.endpoints.count >= size {
                    for (part, start) in stride(from: 0, to: resource.endpoints.count, by: size).enumerated() {
                        add(service, [part == 0 ? resource.name : "\(resource.name)-\(part + 1)"],
                            Array(resource.endpoints[start..<min(start + size, resource.endpoints.count)]))
                    }
                    continue
                }
                if packedEndpoints.count + resource.endpoints.count > size {
                    add(service, packed, packedEndpoints)
                    packed = []
                    packedEndpoints = []
                }
                packed.append(resource.name)
                packedEndpoints += resource.endpoints
            }
            if !packedEndpoints.isEmpty { add(service, packed, packedEndpoints) }
        }
        return Array(groups.prefix(limits.maxGroups))
    }

    /// The services with the addresses their rules use: the simulated connection of their variable, else their base URL,
    /// else what was known before.
    static func resolve(_ services: [StudioMapService], connections: [StudioServerConnection]) -> [StudioMapService] {
        services.map { service in
            var resolved = service
            if service.isApplication {
                resolved.address = ""
            } else if !service.variable.isEmpty, let connection = connections.first(where: { $0.variable == service.variable }) {
                resolved.address = connection.origin + connection.basePath
            } else if !service.baseURL.isEmpty {
                resolved.address = service.baseURL
            }
            return resolved
        }
    }

    /// The path of the rule that answers `endpoint`: the path alone on the application's own server, the full URL on another
    /// service; nil while the service's address is not known.
    static func rulePath(_ endpoint: StudioMapEndpoint, service: StudioMapService?) -> String? {
        guard let address = service?.address else { return nil }
        return address.isEmpty ? endpoint.path : address + endpoint.path
    }

    /// Whether a registered rule answers `endpoint` (a rule for `/bundles/:id` answers `/bundles/:id`, one for
    /// `/bundles/search` does not).
    static func isCovered(_ endpoint: StudioMapEndpoint, service: StudioMapService?, rules: [StudioRule]) -> Bool {
        guard let path = rulePath(endpoint, service: service) else { return false }
        let (origin, wanted) = StudioRoute.split(path)
        return rules.contains { rule in
            guard rule.method.uppercased() == endpoint.method.uppercased() else { return false }
            let (ruleOrigin, rulePath) = StudioRoute.split(rule.path)
            return ruleOrigin == origin && StudioRoute.match(pattern: rulePath, path: wanted) != nil
        }
    }

    static func isCovered(_ group: StudioMapGroup, service: StudioMapService?, rules: [StudioRule]) -> Bool {
        !group.endpoints.isEmpty && group.endpoints.allSatisfy { isCovered($0, service: service, rules: rules) }
    }

    /// Whether a request is one of `endpoint`'s: the same method, the service's origin (the application's own for `app`) and
    /// a path the endpoint's rule path matches. A request waits while the group that has its endpoint is prepared.
    static func matches(_ endpoint: StudioMapEndpoint, service: StudioMapService?, method: String, url: URL, appOrigin: String?) -> Bool {
        guard endpoint.method == method.uppercased(), let path = rulePath(endpoint, service: service),
              let requestOrigin = StudioBridge.Origin(url: url)?.text else { return false }
        let (origin, pattern) = StudioRoute.split(path)
        let wanted = origin.flatMap { URL(string: $0) }.flatMap { StudioBridge.Origin(url: $0)?.text } ?? appOrigin
        return wanted == requestOrigin && StudioRoute.match(pattern: pattern, path: url.path.isEmpty ? "/" : url.path) != nil
    }

    /// An older map extended with a new inventory (REQ-016): its groups, their rules and the data stay as they are; the
    /// services the inventory adds are added, and its endpoints that no group has and no registered rule answers get new
    /// groups, prepared like the others. The map gets the current version. Returns the new groups too.
    static func extended(_ map: StudioEnvironmentMap, with inventory: StudioMapInventory, rules: [StudioRule],
                         connections: [StudioServerConnection], limits: StudioMapLimits = StudioMapLimits())
        -> (map: StudioEnvironmentMap, added: [StudioMapGroup]) {
        var next = map
        var services = map.services
        for service in inventory.services where !services.contains(where: { $0.name == service.name }) { services.append(service) }
        next.services = resolve(services, connections: connections)
        let known = Set(map.groups.flatMap { group in
            group.endpoints.map { "\(group.service) \($0.method) \(StudioMapParsing.routeKey($0.path))" }
        })
        let entries = inventory.entries.filter { entry in
            !known.contains("\(entry.service) \(entry.endpoint.method) \(StudioMapParsing.routeKey(entry.endpoint.path))")
                && !isCovered(entry.endpoint, service: next.service(entry.service), rules: rules)
        }
        var room = limits
        room.maxGroups = max(0, limits.maxGroups - map.groups.count)
        var ids = Set(map.groups.map(\.id))
        let added = groups(StudioMapInventory(services: inventory.services, entries: entries), limits: room).map { group -> StudioMapGroup in
            var unique = group
            var number = 2
            while !ids.insert(unique.id).inserted {
                unique.id = "\(group.id)-\(number)"
                number += 1
            }
            return unique
        }
        next.groups = map.groups + added
        next.notes = Array((map.notes + inventory.notes.filter { !map.notes.contains($0) }).prefix(20))
        if map.userRoles.isEmpty {
            next.userRoles = inventory.roles
            next.ordinaryRole = inventory.ordinaryRole
        }
        next.inventoried = true
        next.version = StudioEnvironmentMap.currentVersion
        return (next, added)
    }

    /// The role the built-in scenarios' test user gets after the inventory: the ordinary role, when the application checks
    /// roles and `current` is not one of them; nil when nothing changes.
    static func testUserRole(current: String, roles: [String], ordinary: String) -> String? {
        guard !roles.isEmpty, !ordinary.isEmpty, roles.contains(ordinary), !roles.contains(current) else { return nil }
        return ordinary
    }

    /// The groups a session prepares: those not started, those a closed session left, and those that failed in fewer than
    /// `sessions` sessions.
    static func resumable(_ map: StudioEnvironmentMap, sessions: Int) -> [String] {
        map.groups.filter { group in
            switch group.status {
            case .pending, .preparing: return true
            case .failed: return group.attempts < sessions
            case .done, .unsupported: return false
            }
        }.map(\.id)
    }

    /// A group's proposal without what is already registered: a rule for a method and path that has one is left out, a rule
    /// id already used gets a number, and a record whose id exists keeps the existing record. Groups run side by side and
    /// share entities, so the same categories or the same list may come from two of them. Returns what was left out.
    static func deduplicated(_ proposal: StudioProposal, spec: StudioEnvironmentSpec,
                             state: [String: [StudioJSON]]) -> (proposal: StudioProposal, dropped: [String]) {
        var result = proposal
        var dropped: [String] = []
        var taken = Set(spec.rules.map { "\($0.method.uppercased()) \($0.path)" })
        var ids = Set(spec.rules.map(\.id))
        result.rules = []
        for var rule in proposal.rules {
            let key = "\(rule.method.uppercased()) \(rule.path)"
            guard taken.insert(key).inserted else {
                dropped.append("the rule for \(key)")
                continue
            }
            if rule.id.isEmpty || ids.contains(rule.id) {
                let base = rule.id.isEmpty ? "rule" : rule.id
                var number = 2
                while ids.contains("\(base)-\(number)") { number += 1 }
                rule.id = "\(base)-\(number)"
            }
            ids.insert(rule.id)
            result.rules.append(rule)
        }
        for (name, records) in proposal.records {
            let idField = proposal.entities.first { $0.name == name }?.idField ?? spec.entity(name)?.idField ?? "id"
            let existing = Set((state[name] ?? []).compactMap { $0[idField]?.identityKey })
            let kept = records.filter { record in record[idField]?.identityKey.map { !existing.contains($0) } ?? true }
            if kept.count < records.count { dropped.append("\(records.count - kept.count) \(name) record(s) that exist") }
            result.records[name] = kept.isEmpty ? nil : kept
        }
        return (result, dropped)
    }

    /// The environment without what the assistant prepared (Map again): its rules, the entities and seed only they used,
    /// the routes prepared ahead and the map. Rules of the project and of the person stay, with the entities they read.
    static func withoutPrepared(_ spec: StudioEnvironmentSpec) -> StudioEnvironmentSpec {
        var next = spec
        let removed = spec.rules.filter { $0.origin == .agent }
        next.rules = spec.rules.filter { $0.origin != .agent }
        var used = Set(next.rules.compactMap(\.entity) + next.rules.flatMap { ($0.include ?? []).map(\.entity) })
        var queue = Array(used)
        while let name = queue.popLast() {
            for target in (spec.entity(name)?.fields ?? []).compactMap(\.references) where used.insert(target).inserted { queue.append(target) }
        }
        next.entities = spec.entities.filter { used.contains($0.name) }
        next.seed = spec.seed.filter { used.contains($0.key) }
        let removedKeys = Set(removed.map { "\($0.method) \($0.path)" })
        next.dependencies = spec.dependencies.filter { !($0.mode == .simulated && removedKeys.contains($0.id)) }
        next.preparedRoutes = nil
        next.map = nil
        next.updated = Date()
        return next
    }
}

extension StudioRole {
    /// The built-in test user with the application's role `name` (REQ-014), so a server that accepts only its own roles
    /// does not refuse it; the default user when `name` is nil.
    static func tester(role name: String?) -> StudioRole {
        guard let name, !name.isEmpty else { return tester }
        return tester.withRole(name)
    }

    /// The same user with another application role.
    func withRole(_ name: String) -> StudioRole {
        var role = self
        var user = role.user.objectValue ?? [:]
        user["role"] = .string(name)
        role.user = .object(user)
        return role
    }

    /// The user's application role, as the simulation answers it.
    var roleName: String? { user["role"]?.stringValue }
}

// MARK: - Coherence

/// Something in the seed that would leave a screen empty or broken (REQ-014): a reference to a record that does not exist,
/// a value a list filters by that no record has, or a list with no records at all.
struct StudioCoherenceGap: Equatable, Sendable {
    enum Kind: String, Sendable {
        case dangling, uncovered, empty
    }

    var kind: Kind
    var entity: String
    /// The field it is about; "" for an empty list.
    var field: String
    /// The missing ids or the values without records, at most a few.
    var values: [String]
    var line: String
}

/// The coherence check of the seed (REQ-014), after every group was prepared: references between records (the fields'
/// `references`, or a field named after an entity such as `categoryId`) and the coverage of every list rule's filter fields.
enum StudioCoherence {
    static let shownValues = 6

    static func check(_ spec: StudioEnvironmentSpec, seed: [String: [StudioJSON]]? = nil) -> [StudioCoherenceGap] {
        let seed = seed ?? spec.seed
        var gaps: [StudioCoherenceGap] = []
        func ids(_ entity: String) -> Set<String> {
            let idField = spec.entity(entity)?.idField ?? "id"
            return Set((seed[entity] ?? []).compactMap { $0[idField]?.identityKey })
        }
        func values(_ value: StudioJSON?) -> [String] {
            guard let value, !value.isNull else { return [] }
            if let list = value.arrayValue { return list.compactMap(\.identityKey) }
            return value.identityKey.map { [$0] } ?? []
        }
        for entity in spec.entities.sorted(by: { $0.name < $1.name }) {
            for field in entity.fields {
                guard let target = referencedEntity(field, of: entity, in: spec) else { continue }
                let existing = ids(target)
                var missing: [String] = []
                var count = 0
                for record in seed[entity.name] ?? [] {
                    for value in values(record[field.name]) where !existing.contains(value) {
                        count += 1
                        if !missing.contains(value) { missing.append(value) }
                    }
                }
                guard !missing.isEmpty else { continue }
                let shown = missing.prefix(shownValues).joined(separator: ", ") + (missing.count > shownValues ? "…" : "")
                gaps.append(StudioCoherenceGap(kind: .dangling, entity: entity.name, field: field.name, values: Array(missing.prefix(shownValues)),
                                               line: "\(entity.name).\(field.name) points at \(target) that do not exist: \(shown) "
                                                   + "(\(count) record\(count == 1 ? "" : "s"))"))
            }
        }
        var checked = Set<String>()
        for rule in spec.rules where rule.operation == .list {
            guard let name = rule.entity, let entity = spec.entity(name) else { continue }
            let records = seed[name] ?? []
            if records.isEmpty {
                if checked.insert(name + "\n").inserted {
                    gaps.append(StudioCoherenceGap(kind: .empty, entity: name, field: "", values: [],
                                                   line: "\(name) has no records, so the list \(rule.method) \(rule.path) is empty"))
                }
                continue
            }
            for filter in rule.filters ?? [] where !StudioPaging.parameters.contains(filter.lowercased()) {
                guard checked.insert(name + "\n" + filter).inserted else { continue }
                var wanted: [(value: String, label: String)] = []
                if let field = entity.fields.first(where: { $0.name == filter }), let target = referencedEntity(field, of: entity, in: spec) {
                    let idField = spec.entity(target)?.idField ?? "id"
                    wanted = (seed[target] ?? []).compactMap { record in
                        record[idField]?.identityKey.map { ($0, label(of: record)) }
                    }
                } else if let allowed = entity.fields.first(where: { $0.name == filter })?.enumValues {
                    wanted = allowed.map { ($0, "") }
                }
                let present = Set(records.flatMap { values($0[filter]) })
                let uncovered = wanted.filter { !present.contains($0.value) }
                guard !uncovered.isEmpty else { continue }
                let shown = uncovered.prefix(shownValues).map { $0.label.isEmpty ? $0.value : "\($0.value) (\($0.label))" }
                    .joined(separator: ", ") + (uncovered.count > shownValues ? "…" : "")
                gaps.append(StudioCoherenceGap(kind: .uncovered, entity: name, field: filter, values: uncovered.prefix(shownValues).map(\.value),
                                               line: "No \(name) with \(filter) \(shown), which the list \(rule.method) \(rule.path) filters by"))
            }
        }
        return gaps
    }

    /// The entity a field points at: its `references`, or an entity named like the field without `Id` (`categoryId` →
    /// `categories`, `city_id` → `cities`) when exactly one fits.
    static func referencedEntity(_ field: StudioField, of entity: StudioEntity, in spec: StudioEnvironmentSpec) -> String? {
        if let target = field.references, !target.isEmpty { return spec.entity(target) == nil ? nil : target }
        guard field.name != entity.idField, !["boolean", "number", "object"].contains(field.type),
              let match = field.name.range(of: #"^(.+?)(Ids?|IDs?|_ids?)$"#, options: .regularExpression) else { return nil }
        let base = String(field.name[match]).replacingOccurrences(of: #"(Ids?|IDs?|_ids?)$"#, with: "", options: .regularExpression)
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let stem = plain(base)
        guard !stem.isEmpty else { return nil }
        var forms: Set<String> = [stem, stem + "s", stem + "es"]
        if stem.hasSuffix("y") { forms.insert(String(stem.dropLast()) + "ies") }
        let names = spec.entities.map(\.name)
        let exact = names.filter { forms.contains(plain($0)) }
        if exact.count == 1 { return exact[0] }
        let suffixed = names.filter { name in forms.contains { plain(name).hasSuffix($0) && $0.count >= 3 } }
        return exact.isEmpty && suffixed.count == 1 ? suffixed[0] : nil
    }

    /// A record's name for the person: its name, title, label or slug.
    static func label(of record: StudioJSON) -> String {
        for key in ["name", "title", "label", "slug"] {
            if let text = record[key]?.stringValue, !text.isEmpty { return String(text.prefix(40)) }
        }
        return ""
    }

    /// The order in which entities are refilled: an entity after the entities it points at, so its new records can point at
    /// their new ids; entities that point at each other come last.
    static func refillOrder(_ names: [String], spec: StudioEnvironmentSpec) -> [[String]] {
        let wanted = Set(names)
        var needs: [String: Set<String>] = [:]
        for name in names {
            guard let entity = spec.entity(name) else { needs[name] = []; continue }
            needs[name] = Set(entity.fields.compactMap { referencedEntity($0, of: entity, in: spec) }.filter { $0 != name && wanted.contains($0) })
        }
        var levels: [[String]] = []
        var placed = Set<String>()
        var rest = names.filter { needs[$0] != nil }
        rest = rest.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        while !rest.isEmpty {
            let ready = rest.filter { (needs[$0] ?? []).isSubset(of: placed) }
            let level = ready.isEmpty ? rest : ready
            levels.append(level)
            placed.formUnion(level)
            rest.removeAll { placed.contains($0) }
        }
        return levels
    }
}
