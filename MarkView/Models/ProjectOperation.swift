import Foundation

/// The team-owned definition in .markview/operations.json. Only the run summary is local.
struct ProjectOperation: Codable, Identifiable {
    struct Discovered: Codable, Equatable {
        var command: String
        var cwd: String
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
    var deleted: Bool
    var confidence: String?
    var prerequisites: [String]
    var provenance: [Source]
    var remoteTrigger: Bool
    /// Preserve fields written by a newer MarkView when this version saves an edit.
    var extra: [String: AnyCodable] = [:]

    var isEdited: Bool {
        origin == "user" || (discovered != nil && (command != discovered?.command || cwd != discovered?.cwd))
    }

    var hasExternalOrigin: Bool { provenance.contains { $0.kind == "external" || $0.kind == "web" } }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, kind, environment, target, nodes, command, cwd, origin, discovered
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
         prerequisites: [String] = [], provenance: [Source] = [], remoteTrigger: Bool = false) {
        self.id = id; self.label = label; self.kind = kind; self.environment = environment
        self.target = target; self.nodes = nodes; self.command = command; self.cwd = cwd
        self.origin = origin; self.discovered = discovered; self.deleted = deleted
        self.confidence = confidence; self.prerequisites = prerequisites; self.provenance = provenance
        self.remoteTrigger = remoteTrigger
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
