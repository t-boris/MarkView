import Foundation

/// Where UI Studio keeps its files (§10.3). Reusable configuration that may be committed — the environment, scenarios and
/// feature packages — lives in `.markview/studio/` next to the team-owned `.markview/operations.json`. Session data — the
/// operation history, captures, selection pictures — lives in `.dde/studio/`, which carries its own `.gitignore` so large
/// pictures never enter Git automatically.
enum StudioStore {
    static func configFolder(_ root: URL) -> URL { root.appendingPathComponent(".markview/studio", isDirectory: true) }
    static func environmentURL(_ root: URL) -> URL { configFolder(root).appendingPathComponent("environment.json") }
    static func scenariosFolder(_ root: URL) -> URL { configFolder(root).appendingPathComponent("scenarios", isDirectory: true) }
    static func packagesFolder(_ root: URL) -> URL { configFolder(root).appendingPathComponent("packages", isDirectory: true) }

    static func localFolder(_ root: URL) -> URL { root.appendingPathComponent(".dde/studio", isDirectory: true) }
    static func historyURL(_ root: URL) -> URL { localFolder(root).appendingPathComponent("history.json") }
    static func capturesFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("captures", isDirectory: true) }
    static func capturesURL(_ root: URL) -> URL { localFolder(root).appendingPathComponent("captures.json") }
    static func selectionFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("selection", isDirectory: true) }
    /// The images a person attached to requests (REQ-005): `<8 hex digits>.png`, kept with the turn that sent them.
    static func attachmentsFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("attachments", isDirectory: true) }
    /// The project-relative form of `attachmentsFolder`, as a turn records and a prompt names an attached image.
    static let attachmentsPath = ".dde/studio/attachments"
    /// Whether `path` is a project-relative path of a saved attachment. A turn read from `history.json` may name anything, so
    /// only these reach a prompt or the assistant's image list.
    static func isAttachmentPath(_ path: String) -> Bool {
        guard path.hasPrefix(attachmentsPath + "/"), path.hasSuffix(".png") else { return false }
        let stem = path.dropFirst(attachmentsPath.count + 1).dropLast(4)
        return !stem.isEmpty && stem.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    static func logURL(_ root: URL) -> URL { localFolder(root).appendingPathComponent("session.log") }
    static func activeScenarioURL(_ root: URL) -> URL { localFolder(root).appendingPathComponent("active-scenario.json") }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Creates `.dde/studio/` with a `.gitignore` that ignores everything in it.
    static func prepareLocalFolder(_ root: URL) {
        let folder = localFolder(root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? "# UI Studio session data: history, captures and selection pictures stay out of Git.\n*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// The scenario a session ended on, so that the next one opens on it and the data asked for is still there (BUG-087). It is the
    /// person's own state, kept with the session data (never committed), not with the team's scenarios.
    private struct ActiveScenario: Codable { var id: String }
    static func loadActiveScenarioID(_ root: URL) -> String? { load(ActiveScenario.self, from: activeScenarioURL(root))?.id }
    static func saveActiveScenarioID(_ id: String, root: URL) {
        prepareLocalFolder(root)
        try? save(ActiveScenario(id: id), to: activeScenarioURL(root))
    }

    static func loadEnvironment(_ root: URL) -> StudioEnvironmentSpec? { load(StudioEnvironmentSpec.self, from: environmentURL(root)) }
    static func saveEnvironment(_ spec: StudioEnvironmentSpec, root: URL) throws { try save(spec, to: environmentURL(root)) }

    /// A scenario id is a file name: letters, digits and dashes.
    static func safeID(_ text: String) -> String {
        let slug = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { result, character in
            if character == "-" && result.hasSuffix("-") { return }
            result.append(character)
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "scenario" : slug).prefix(60))
    }

    static func loadScenarios(_ root: URL) -> [StudioScenario] {
        let files = (try? FileManager.default.contentsOfDirectory(at: scenariosFolder(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { load(StudioScenario.self, from: $0) }
            .sorted { ($0.kind.sortOrder, $0.name) < ($1.kind.sortOrder, $1.name) }
    }

    static func saveScenario(_ scenario: StudioScenario, root: URL) throws {
        try save(scenario, to: scenariosFolder(root).appendingPathComponent(safeID(scenario.id) + ".json"))
    }

    static func deleteScenario(_ id: String, root: URL) {
        try? FileManager.default.removeItem(at: scenariosFolder(root).appendingPathComponent(safeID(id) + ".json"))
    }

    static func loadHistory(_ root: URL) -> [StudioOperation] { load([StudioOperation].self, from: historyURL(root)) ?? [] }
    static func saveHistory(_ history: [StudioOperation], root: URL) throws {
        prepareLocalFolder(root)
        try save(history, to: historyURL(root))
    }

    static func loadCaptures(_ root: URL) -> [StudioCapture] { load([StudioCapture].self, from: capturesURL(root)) ?? [] }
    static func saveCaptures(_ captures: [StudioCapture], root: URL) throws {
        prepareLocalFolder(root)
        try save(captures, to: capturesURL(root))
    }

    static func loadPackages(_ root: URL) -> [StudioPackage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: packagesFolder(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { load(StudioPackage.self, from: $0) }.sorted { $0.created > $1.created }
    }

    static func savePackage(_ package: StudioPackage, root: URL) throws {
        try save(package, to: packagesFolder(root).appendingPathComponent(safeID(package.id) + ".json"))
    }
}

extension StudioScenario.Kind {
    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 99 }
    var title: String {
        switch self {
        case .populated: return "Populated"
        case .empty: return "Empty"
        case .loading: return "Loading"
        case .error: return "Error"
        case .detail: return "Detail"
        case .editing: return "Editing"
        case .custom: return "Custom"
        }
    }
}

/// Whether a saved scenario still fits the environment's contracts (SCN-04): a changed contract marks it incompatible
/// and only an explicit update changes its baseline.
enum StudioScenarioCompatibility {
    /// The contracts a scenario depends on: the definitions of the entities its data holds and of the rules it overrides.
    static func fingerprint(_ scenario: StudioScenario, spec: StudioEnvironmentSpec) -> String {
        let data = scenario.data ?? spec.seed
        var text = ""
        for name in data.keys.sorted() {
            guard let entity = spec.entity(name) else { text += "entity:\(name):missing\n"; continue }
            text += "entity:\(name):\(entity.idField):" + entity.fields.sorted { $0.name < $1.name }
                .map { "\($0.name)/\($0.type)/\($0.required)/\(($0.enumValues ?? []).joined(separator: "|"))/\($0.references ?? "")" }
                .joined(separator: ",") + "\n"
        }
        for override in scenario.overrides {
            let rule = spec.rules.first { rule in
                override.ruleId.map { $0 == rule.id } ?? (override.method?.uppercased() == rule.method.uppercased() && override.path == rule.path)
            }
            text += "override:\(override.ruleId ?? "\(override.method ?? "") \(override.path ?? "")"):"
                + (rule.map { "\($0.method) \($0.path) \($0.operation.rawValue) \($0.entity ?? "")" } ?? "missing") + "\n"
        }
        return StudioHash.sha256(text)
    }

    /// Why the scenario no longer fits; empty when it does.
    static func problems(_ scenario: StudioScenario, spec: StudioEnvironmentSpec) -> [String] {
        var problems: [String] = []
        if !scenario.contractFingerprint.isEmpty, scenario.contractFingerprint != fingerprint(scenario, spec: spec) {
            problems.append("The contracts this scenario was saved against changed.")
        }
        let data = scenario.data ?? spec.seed
        for (name, records) in data {
            guard let entity = spec.entity(name) else { problems.append("Entity \(name) is no longer defined."); continue }
            for record in records { problems += StudioValidator.problems(record: record, entity: entity, state: data, spec: spec) }
        }
        for override in scenario.overrides {
            let found = spec.rules.contains { rule in
                override.ruleId.map { $0 == rule.id } ?? (override.method?.uppercased() == rule.method.uppercased() && override.path == rule.path)
            }
            if !found { problems.append("The override of \(override.ruleId ?? override.path ?? "a rule") names a rule that no longer exists.") }
        }
        return problems
    }

    /// The explicit "Update scenario" (SCN-04): records of removed entities are dropped, missing required fields get empty
    /// values of their type, overrides of removed rules are dropped. Returns the scenario and what changed, in words.
    static func updated(_ scenario: StudioScenario, spec: StudioEnvironmentSpec) -> (StudioScenario, [String]) {
        var next = scenario
        var notes: [String] = []
        if var data = scenario.data {
            for name in data.keys.sorted() {
                guard let entity = spec.entity(name) else {
                    notes.append("Dropped \(data[name]?.count ?? 0) records of \(name), which is no longer defined.")
                    data[name] = nil
                    continue
                }
                data[name] = data[name]?.map { record in
                    guard var fields = record.objectValue else { return record }
                    for field in entity.fields where field.required && (fields[field.name] == nil || fields[field.name]?.isNull == true) {
                        fields[field.name] = defaultValue(field)
                        notes.append("\(name) \(record[entity.idField]?.identityKey ?? "?"): filled the new required field \(field.name).")
                    }
                    return .object(fields)
                }
            }
            next.data = data
        }
        let kept = scenario.overrides.filter { override in
            spec.rules.contains { rule in
                override.ruleId.map { $0 == rule.id } ?? (override.method?.uppercased() == rule.method.uppercased() && override.path == rule.path)
            }
        }
        if kept.count != scenario.overrides.count { notes.append("Dropped \(scenario.overrides.count - kept.count) overrides of removed rules.") }
        next.overrides = kept
        next.revision += 1
        next.updated = Date()
        next.contractFingerprint = fingerprint(next, spec: spec)
        return (next, notes)
    }

    static func defaultValue(_ field: StudioField) -> StudioJSON {
        if let first = field.enumValues?.first { return .string(first) }
        switch field.type {
        case "integer", "number": return .number(0)
        case "boolean": return .bool(false)
        case "array": return .array([])
        case "object": return .object([:])
        default: return .string("")
        }
    }

    /// The built-in states of a project (REQ-005): populated, empty, loading and error, made of the environment's list
    /// rules without touching the application's code (SCN-03).
    static func presets(spec: StudioEnvironmentSpec, base: StudioScenario) -> [StudioScenario] {
        let lists = spec.rules.filter { $0.operation == .list }
        func make(_ kind: StudioScenario.Kind, _ overrides: [StudioOverride]) -> StudioScenario {
            var scenario = base
            scenario.id = "builtin-" + kind.rawValue
            scenario.name = kind.title
            scenario.kind = kind
            scenario.overrides = overrides
            scenario.data = nil
            scenario.steps = []
            scenario.contractFingerprint = fingerprint(scenario, spec: spec)
            return scenario
        }
        var result = [make(.populated, [])]
        guard !lists.isEmpty else { return result }
        result.append(make(.empty, lists.map { StudioOverride(ruleId: $0.id, empty: true) }))
        result.append(make(.loading, lists.map { StudioOverride(ruleId: $0.id, hang: true) }))
        result.append(make(.error, lists.map { StudioOverride(ruleId: $0.id, status: 500, body: .object(["error": .string("Simulated server error")])) }))
        return result
    }
}
