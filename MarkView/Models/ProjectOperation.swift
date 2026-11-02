import Foundation

/// The team-owned definition in .markview/operations.json. Only the run summary is local.
struct ProjectOperation: Codable, Identifiable {
    struct Discovered: Codable, Equatable {
        var command: String
        var cwd: String
    }

    /// The other user-editable fields as discovery last proposed them. Together with `discovered`
    /// it is the baseline that tells a user edit from a discovery change (BUG-036). Optional and
    /// written only by discovery: a file from an earlier version has none, and an earlier version
    /// keeps the `discoveredFields` key untouched in `extra` when it saves. When the object is
    /// present, a missing `environment` or `target` means discovery proposed none.
    struct DiscoveredFields: Codable, Equatable {
        var label: String
        var kind: String
        var environment: String?
        var target: String?
        var prerequisites: [String]
        var remoteTrigger: Bool
    }

    struct Node: Codable, Equatable {
        var id: String
        var name: String
    }

    struct Source: Codable, Equatable {
        /// project, external, or web
        var kind: String
        var location: String
        var line: Int?
    }

    var id: String
    var label: String
    var kind: String
    var environment: String?
    var target: String?
    var nodes: [Node]
    var command: String
    var cwd: String
    var origin: String
    var discovered: Discovered?
    var discoveredFields: DiscoveredFields?
    var deleted: Bool
    var confidence: String?
    var prerequisites: [String]
    var provenance: [Source]
    var remoteTrigger: Bool
    /// Preserve fields written by a newer MarkView when this version saves an edit.
    var extra: [String: AnyCodable] = [:]

    /// The command or working directory is the user's, not discovery's. This is what the confidence
    /// text, the external-source warning and the "Adopt discovered" action key off, so a changed
    /// label or environment does not count. Re-discovery uses `hasUserChanges(comparedTo:)` instead.
    var isEdited: Bool {
        origin == "user" || (discovered != nil && (command != discovered?.command || cwd != discovered?.cwd))
    }

    /// The editor sets this when the user picks another deployment node (DEC-027); it lives in
    /// `extra`, so older versions keep it when they save.
    var nodesEdited: Bool {
        if case .bool(true)? = extra["nodesEdited"] { return true }
        return false
    }

    /// The values `discoveredFields` records, as they stand now.
    var currentFields: DiscoveredFields {
        DiscoveredFields(label: label, kind: kind, environment: environment, target: target,
                         prerequisites: prerequisites, remoteTrigger: remoteTrigger)
    }

    var hasExternalOrigin: Bool { provenance.contains { $0.kind == "external" || $0.kind == "web" } }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, kind, environment, target, nodes, command, cwd, origin, discovered, discoveredFields
        case deleted, confidence, prerequisites, provenance, remoteTrigger
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(id: String, label: String, kind: String, environment: String? = nil, target: String? = nil,
         nodes: [Node] = [], command: String, cwd: String = ".", origin: String = "user",
         discovered: Discovered? = nil, deleted: Bool = false, confidence: String? = nil,
         prerequisites: [String] = [], provenance: [Source] = [], remoteTrigger: Bool = false,
         discoveredFields: DiscoveredFields? = nil) {
        self.id = id; self.label = label; self.kind = kind; self.environment = environment
        self.target = target; self.nodes = nodes; self.command = command; self.cwd = cwd
        self.origin = origin; self.discovered = discovered; self.deleted = deleted
        self.confidence = confidence; self.prerequisites = prerequisites; self.provenance = provenance
        self.remoteTrigger = remoteTrigger; self.discoveredFields = discoveredFields
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(String.self, forKey: .kind)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        command = try c.decode(String.self, forKey: .command)
        cwd = try c.decode(String.self, forKey: .cwd)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "discovered"
        discovered = try c.decodeIfPresent(Discovered.self, forKey: .discovered)
        // A damaged snapshot must not make the whole file unreadable; it only means "not recorded".
        discoveredFields = try? c.decodeIfPresent(DiscoveredFields.self, forKey: .discoveredFields)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        prerequisites = try c.decodeIfPresent([String].self, forKey: .prerequisites) ?? []
        provenance = try c.decodeIfPresent([Source].self, forKey: .provenance) ?? []
        remoteTrigger = try c.decodeIfPresent(Bool.self, forKey: .remoteTrigger) ?? false
        let all = try decoder.container(keyedBy: DynamicKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        extra = Dictionary(uniqueKeysWithValues: try all.allKeys.filter { !known.contains($0.stringValue) }
            .map { ($0.stringValue, try all.decode(AnyCodable.self, forKey: $0)) })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        try c.encode(kind, forKey: .kind); try c.encode(environment, forKey: .environment)
        try c.encode(target, forKey: .target); try c.encode(nodes, forKey: .nodes)
        try c.encode(command, forKey: .command); try c.encode(cwd, forKey: .cwd)
        try c.encode(origin, forKey: .origin); try c.encode(discovered, forKey: .discovered)
        // Omitted when absent, so a file written before the snapshot existed is saved byte for byte.
        try c.encodeIfPresent(discoveredFields, forKey: .discoveredFields)
        try c.encode(deleted, forKey: .deleted); try c.encode(confidence, forKey: .confidence)
        try c.encode(prerequisites, forKey: .prerequisites)
        try c.encode(provenance, forKey: .provenance); try c.encode(remoteTrigger, forKey: .remoteTrigger)
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in extra {
            if let codingKey = DynamicKey(stringValue: key) { try dynamic.encode(value, forKey: codingKey) }
        }
    }

    static let kinds: Set<String> = ["deploy", "install", "build", "clean", "restart", "other"]

    func validate() throws {
        let slug = id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
        guard slug else { throw ProjectOperationError.invalid("Invalid operation id: \(id)") }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectOperationError.invalid("Operation \(id) has no label")
        }
        guard Self.kinds.contains(kind) else { throw ProjectOperationError.invalid("Operation \(id) has invalid kind: \(kind)") }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectOperationError.invalid("Operation \(id) has no command")
        }
        guard !cwd.isEmpty else { throw ProjectOperationError.invalid("Operation \(id) has no working directory") }
        guard ["discovered", "user"].contains(origin) else {
            throw ProjectOperationError.invalid("Operation \(id) has invalid origin: \(origin)")
        }
        if let confidence, !["high", "medium", "low"].contains(confidence) {
            throw ProjectOperationError.invalid("Operation \(id) has invalid confidence: \(confidence)")
        }
    }
}

enum ProjectOperationError: LocalizedError {
    case invalid(String)
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .newerVersion(let version): return "Operations file version \(version) is newer than MarkView supports. Open it read-only or update MarkView."
        }
    }
}

struct ProjectOperationsDocument: Codable {
    var version = 1
    var operations: [ProjectOperation] = []
    var extra: [String: AnyCodable] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, operations }
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        operations = try c.decode([ProjectOperation].self, forKey: .operations)
        let all = try decoder.container(keyedBy: DynamicKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        extra = Dictionary(uniqueKeysWithValues: try all.allKeys.filter { !known.contains($0.stringValue) }
            .map { ($0.stringValue, try all.decode(AnyCodable.self, forKey: $0)) })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(operations.sorted { $0.id < $1.id }, forKey: .operations)
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in extra {
            if let codingKey = DynamicKey(stringValue: key) { try dynamic.encode(value, forKey: codingKey) }
        }
    }

    func validate(allowNewer: Bool = false) throws {
        if version > 1 && !allowNewer { throw ProjectOperationError.newerVersion(version) }
        guard version >= 1 else { throw ProjectOperationError.invalid("Unsupported operations file version: \(version)") }
        var ids = Set<String>()
        for operation in operations {
            if version == 1 { try operation.validate() }
            guard ids.insert(operation.id).inserted else {
                throw ProjectOperationError.invalid("Duplicate operation id: \(operation.id)")
            }
        }
    }
}

enum ProjectOperationsFile {
    static func url(root: URL) -> URL { root.appendingPathComponent(".markview/operations.json") }

    static func read(root: URL) throws -> ProjectOperationsDocument {
        let file = url(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return ProjectOperationsDocument() }
        do {
            let document = try JSONDecoder().decode(ProjectOperationsDocument.self, from: Data(contentsOf: file))
            try document.validate(allowNewer: true)
            return document
        } catch {
            throw ProjectOperationError.invalid("Cannot read \(file.path): \(error.localizedDescription)")
        }
    }

    static func write(_ document: ProjectOperationsDocument, root: URL) throws {
        try document.validate()
        let file = url(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: file, options: .atomic)
    }

    /// Reapply one change if a hand edit or git update landed while it was prepared.
    static func mutate(root: URL, _ edit: (inout ProjectOperationsDocument) throws -> Void) throws -> ProjectOperationsDocument {
        let file = url(root: root)
        for _ in 0..<4 {
            let before = try? Data(contentsOf: file)
            var latest = try read(root: root)
            try edit(&latest)
            let current = try? Data(contentsOf: file)
            if before != current { continue }
            try write(latest, root: root)
            return latest
        }
        throw ProjectOperationError.invalid("\(file.path) changed repeatedly while saving. Review the file and try again.")
    }
}

extension ProjectOperation {
    /// True when the user changed any field that discovery would otherwise overwrite: command,
    /// working directory, label, kind, environment, target, prerequisites, remote-trigger flag or
    /// deployment node. Each value is compared with what discovery last proposed (`discovered`,
    /// `discoveredFields`). Where no proposal was recorded (a file from an earlier version), the
    /// baseline is the proposal being merged: a difference cannot be told from a user edit, so it
    /// counts as one and the stored value is kept.
    func hasUserChanges(comparedTo proposal: ProjectOperation) -> Bool {
        if origin == "user" || nodesEdited { return true }
        let baseline = discovered ?? proposal.discovered
        if command != baseline?.command || cwd != baseline?.cwd { return true }
        return currentFields != (discoveredFields ?? proposal.currentFields)
    }

    /// Folds a discovery proposal into the stored operation with the same id (REQ-007, DEC-017).
    /// - A deleted (tombstone) or user-added operation is returned as it is.
    /// - An operation the user has not changed is replaced by the proposal; fields this version does
    ///   not know (`extra`) are carried over.
    /// - An operation the user has changed keeps every value it has. Only discovery metadata is
    ///   refreshed: `discovered`, `discoveredFields`, `provenance`, `confidence`, and the deployment
    ///   node relations unless the user set them.
    static func merged(stored: ProjectOperation, proposal: ProjectOperation) -> ProjectOperation {
        if stored.deleted || stored.origin == "user" { return stored }
        guard stored.hasUserChanges(comparedTo: proposal) else {
            var next = proposal
            next.extra = stored.extra
            return next
        }
        var kept = stored
        kept.discovered = proposal.discovered
        kept.discoveredFields = proposal.discoveredFields
        kept.provenance = proposal.provenance
        kept.confidence = proposal.confidence
        if !stored.nodesEdited { kept.nodes = proposal.nodes }
        return kept
    }

    /// Operations shown up front; the rest are found by search.
    static let primaryLimit = 5
    /// Kinds in the order they matter for a primary slot.
    static let primaryKindOrder = ["deploy", "install", "build", "restart", "clean", "other"]

    /// The few operations worth a button: running ones first, then the most recently started,
    /// then by kind (`primaryKindOrder`) and label. Pure, so tools/tests can check it alone.
    static func primary(_ operations: [ProjectOperation], running: Set<String>,
                        lastStarted: [String: Date], limit: Int = primaryLimit) -> [ProjectOperation] {
        func kindRank(_ operation: ProjectOperation) -> Int {
            primaryKindOrder.firstIndex(of: operation.kind) ?? primaryKindOrder.count
        }
        let sorted = operations.sorted { a, b in
            let aRunning = running.contains(a.id), bRunning = running.contains(b.id)
            if aRunning != bRunning { return aRunning }
            let aStarted = lastStarted[a.id] ?? .distantPast, bStarted = lastStarted[b.id] ?? .distantPast
            if aStarted != bStarted { return aStarted > bStarted }
            let aKind = kindRank(a), bKind = kindRank(b)
            if aKind != bKind { return aKind < bKind }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }
}
