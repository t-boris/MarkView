import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-006 and DEC-014): where scenarios and runs live. Reusable assets (scenarios) are in
// `.markview/qa/`, which may be committed; runs, with their frames and video, are in `.dde/qa/`, which carries its own
// `.gitignore`. Foundation only.

enum QAStoreError: Error, Equatable {
    case badID(String)
}

/// A file in the scenarios folder that could not be used, kept as it is and reported.
struct QAUnreadable: Equatable {
    var file: String
    var message: String
}

struct QAScenarioListing: Equatable {
    var scenarios: [QAScenario]
    var unreadable: [QAUnreadable]
}

enum QAStore {
    static func configFolder(_ root: URL) -> URL { root.appendingPathComponent(".markview/qa", isDirectory: true) }
    static func scenariosFolder(_ root: URL) -> URL { configFolder(root).appendingPathComponent("scenarios", isDirectory: true) }

    static func localFolder(_ root: URL) -> URL { root.appendingPathComponent(".dde/qa", isDirectory: true) }
    static func runsFolder(_ root: URL) -> URL { localFolder(root).appendingPathComponent("runs", isDirectory: true) }
    static func runFolder(_ root: URL, runID: String) -> URL { runsFolder(root).appendingPathComponent(safeID(runID), isDirectory: true) }
    static func runURL(_ root: URL, runID: String) -> URL { runFolder(root, runID: runID).appendingPathComponent("run.json") }

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

    /// An id is a file name: lower-case letters, digits and single dashes.
    static func safeID(_ text: String) -> String {
        var slug = ""
        for character in text.lowercased() {
            let plain = character.isASCII && (character.isLetter || character.isNumber)
            if plain { slug.append(character) } else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "scenario" : slug).prefix(60))
    }

    /// An id for a new scenario from its title that no existing scenario uses.
    static func newScenarioID(title: String, existing: Set<String>) -> String {
        let base = safeID(title)
        if !existing.contains(base) { return base }
        var number = 2
        while existing.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    /// `yyyyMMdd-HHmmss-xxxx` in UTC: sorts by time, and the suffix tells two runs of the same second apart.
    static func newRunID(at date: Date, suffix: String = String(UUID().uuidString.prefix(4)).lowercased()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(safeID(suffix))"
    }

    /// Creates `.dde/qa/` with a `.gitignore` that ignores everything in it: runs hold frames and video.
    static func prepareLocalFolder(_ root: URL) {
        let folder = localFolder(root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try? "# End-to-End QA runs: recordings, frames and evidence stay out of Git.\n*\n".write(to: ignore, atomically: true, encoding: .utf8)
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

    // MARK: Scenarios

    private struct SchemaProbe: Decodable { var schema: Int? }

    /// Every scenario file. A file that is damaged, made by a newer MarkView or named for a different id is reported and left alone.
    static func loadScenarios(_ root: URL) -> QAScenarioListing {
        let files = ((try? FileManager.default.contentsOfDirectory(at: scenariosFolder(root), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var scenarios: [QAScenario] = []
        var unreadable: [QAUnreadable] = []
        for file in files {
            let name = file.lastPathComponent
            guard let data = try? Data(contentsOf: file) else {
                unreadable.append(QAUnreadable(file: name, message: "The file could not be read."))
                continue
            }
            if let probe = try? decoder.decode(SchemaProbe.self, from: data), let schema = probe.schema, schema > QAScenario.currentSchema {
                unreadable.append(QAUnreadable(file: name, message: "Made by a newer version of MarkView."))
                continue
            }
            guard let scenario = try? decoder.decode(QAScenario.self, from: data) else {
                unreadable.append(QAUnreadable(file: name, message: "Not a QA scenario."))
                continue
            }
            guard safeID(scenario.id) == scenario.id, name == scenario.id + ".json" else {
                unreadable.append(QAUnreadable(file: name, message: "The scenario id does not match the file name."))
                continue
            }
            scenarios.append(scenario)
        }
        scenarios.sort { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
        return QAScenarioListing(scenarios: scenarios, unreadable: unreadable)
    }

    static func saveScenario(_ scenario: QAScenario, root: URL) throws {
        guard safeID(scenario.id) == scenario.id else { throw QAStoreError.badID(scenario.id) }
        try save(scenario, to: scenariosFolder(root).appendingPathComponent(scenario.id + ".json"))
    }

    static func deleteScenario(_ id: String, root: URL) {
        guard safeID(id) == id else { return }
        try? FileManager.default.removeItem(at: scenariosFolder(root).appendingPathComponent(id + ".json"))
    }

    // MARK: Runs

    static func saveRun(_ run: QARunRecord, root: URL) throws {
        guard safeID(run.id) == run.id else { throw QAStoreError.badID(run.id) }
        prepareLocalFolder(root)
        try save(run, to: runURL(root, runID: run.id))
    }

    static func loadRun(_ root: URL, runID: String) -> QARunRecord? {
        guard safeID(runID) == runID else { return nil }
        return load(QARunRecord.self, from: runURL(root, runID: runID))
    }

    /// The runs on this Mac, newest first.
    static func loadRuns(_ root: URL) -> [QARunRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: runsFolder(root), includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { load(QARunRecord.self, from: $0.appendingPathComponent("run.json")) }.sorted { $0.startedAt > $1.startedAt }
    }
}
