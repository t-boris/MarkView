import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Result of reading a schema-versioned local store (`AR-36`, `FU-04`).
///
/// Distinguishes missing files, corrupted files, and files written by a newer schema version
/// so callers never silently overwrite unrecognized or corrupted state as if it were empty.
enum StoreLoadResult<T> {
    case loaded(T, schemaVersion: Int)
    case missing(URL)
    case newerSchema(URL, Int)
    case corrupted(URL, String)

    var value: T? {
        if case .loaded(let v, _) = self { return v }
        return nil
    }

    var isCorrupted: Bool {
        if case .corrupted = self { return true }
        return false
    }

    var isNewerSchema: Bool {
        if case .newerSchema = self { return true }
        return false
    }

    /// One sentence for a notice or a log when the file is there but cannot be used; nil when it was read or does not exist yet.
    /// A caller that shows it keeps its empty in-memory state and leaves the file alone: a save backs a damaged file up first and
    /// refuses a newer one.
    var problem: String? {
        switch self {
        case .loaded, .missing:
            return nil
        case .newerSchema(let url, let found):
            return "\(url.lastPathComponent) was written by a newer MarkView (schema \(found)); it is left untouched. Update MarkView to use it."
        case .corrupted(let url, let reason):
            return "\(url.lastPathComponent) cannot be read (\(reason)); it is kept as it is and copied to a backup before anything replaces it."
        }
    }

    /// Logs `problem` once per call, tagged with the store that read the file; does nothing when the file was read or is not there.
    func logProblem(_ owner: String) {
        if let problem { AppLog.store.error("\(owner): \(problem)") }
    }

    /// The loaded value, or the failure as a thrown error: for callers that must fail closed (a missing file is an error too).
    func get() throws -> T {
        switch self {
        case .loaded(let value, _): return value
        case .missing(let url): throw SchemaStoreError.missing(url: url)
        case .newerSchema(let url, let found): throw SchemaStoreError.unreadable(url: url, reason: "written by a newer MarkView (schema \(found))")
        case .corrupted(let url, let reason): throw SchemaStoreError.unreadable(url: url, reason: reason)
        }
    }
}

extension StoreLoadResult: Sendable where T: Sendable {}

enum SchemaStoreError: LocalizedError, Equatable {
    case newerSchemaVersion(url: URL, found: Int, supported: Int)
    case missing(url: URL)
    case unreadable(url: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .newerSchemaVersion(let url, let found, let supported):
            return "Refusing to overwrite \(url.lastPathComponent) because its schema version (\(found)) is newer than supported (\(supported))."
        case .missing(let url):
            return "\(url.lastPathComponent) does not exist."
        case .unreadable(let url, let reason):
            return "\(url.lastPathComponent) cannot be used: \(reason)"
        }
    }
}

/// Standard schema-versioned envelope for JSON persistence (`AR-36`).
struct VersionedEnvelope<Payload: Codable>: Codable {
    var schema: Int
    var updatedAt: Date
    var data: Payload

    init(schema: Int = 1, updatedAt: Date = Date(), data: Payload) {
        self.schema = schema
        self.updatedAt = updatedAt
        self.data = data
    }
}

/// Reads the schema of any JSON document that has one, and whether the document has the envelope's shape (`schema` and `data`).
private struct EnvelopeProbe: Decodable {
    private struct Anything: Decodable { init(from decoder: Decoder) throws {} }
    let schema: Int?
    private let data: Anything?
    var hasEnvelopeShape: Bool { schema != nil && data != nil }
}

private let schemaBackupTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMddHHmmss"
    return f
}()

/// Atomic, schema-versioned JSON store (`AR-36`, `AR-39`, `FU-04`): the one way the app keeps a whole document of user or project
/// data in a file under `.dde/` or Application Support.
///
/// - Writes through `AtomicFile.write`, so a reader sees the old file or the new one and a link, the permissions and the extended
///   attributes of an existing file are kept.
/// - Wraps payloads in `VersionedEnvelope` (`schema: currentSchemaVersion`), while transparently reading legacy files that
///   hold the bare payload (`schemaVersion: 0`) so existing user files upgrade in place on their next save.
/// - Refuses to overwrite or downgrade a file whose schema is newer than `currentSchemaVersion`.
/// - Copies a file that cannot be read to a dated, non-clobbering `.corrupt-<timestamp>-<suffix>` backup before it is replaced; if
///   the backup cannot be made, nothing is replaced.
///
/// A reader of the file by other means (a test, a script) finds the payload under the `data` key.
struct SchemaVersionedStore<T: Codable> {
    /// How dates are written and read. It must be the strategy the file's previous writer used, so that existing files
    /// decode: `.iso8601` (whole seconds) or the default `Codable` seconds since the reference date. A bare legacy payload is
    /// read with either, so a store may change its strategy at the upgrade that adds the envelope.
    enum Dates {
        case iso8601
        case referenceDate
    }

    let currentSchemaVersion: Int
    let dates: Dates

    init(currentSchemaVersion: Int = 1, dates: Dates = .iso8601) {
        self.currentSchemaVersion = max(1, currentSchemaVersion)
        self.dates = dates
    }

    private func decoder(_ dates: Dates) -> JSONDecoder {
        let decoder = JSONDecoder()
        if dates == .iso8601 { decoder.dateDecodingStrategy = .iso8601 }
        return decoder
    }

    func load(from url: URL) -> StoreLoadResult<T> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return .missing(url)
        }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            return .corrupted(url, error.localizedDescription)
        }
        guard !raw.isEmpty else {
            return .corrupted(url, "File is empty (0 bytes)")
        }

        let probe = try? JSONDecoder().decode(EnvelopeProbe.self, from: raw)
        if let foundSchema = probe?.schema, foundSchema > currentSchemaVersion {
            return .newerSchema(url, foundSchema)
        }

        // A document that has the envelope's shape is never read as a bare payload: a payload whose fields are all optional would
        // load as empty, and the next save would replace the real content.
        if probe?.hasEnvelopeShape == true {
            do {
                let envelope = try decoder(dates).decode(VersionedEnvelope<T>.self, from: raw)
                return .loaded(envelope.data, schemaVersion: envelope.schema)
            } catch {
                return .corrupted(url, StoredJSON.describe(error))
            }
        }

        // A legacy file holds the payload itself (`schemaVersion: 0`).
        var firstFailure: Error?
        for strategy in [dates, dates == .iso8601 ? Dates.referenceDate : Dates.iso8601] {
            do {
                return .loaded(try decoder(strategy).decode(T.self, from: raw), schemaVersion: 0)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        return .corrupted(url, StoredJSON.describe(firstFailure ?? CocoaError(.fileReadCorruptFile)))
    }

    /// Saves `value` in the envelope. Throws `SchemaStoreError.newerSchemaVersion` and leaves the file alone when it was written by
    /// a newer MarkView; a file that cannot be read is copied to a backup first.
    func save(_ value: T, to url: URL, permissions: Int16? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            switch load(from: url) {
            case .newerSchema(_, let foundVersion):
                throw SchemaStoreError.newerSchemaVersion(
                    url: url,
                    found: foundVersion,
                    supported: currentSchemaVersion
                )
            case .corrupted:
                let stamp = schemaBackupTimestampFormatter.string(from: Date())
                let uniqueSuffix = UUID().uuidString.prefix(8).lowercased()
                try fm.copyItem(at: url, to: url.appendingPathExtension("corrupt-\(stamp)-\(uniqueSuffix)"))
            case .loaded, .missing:
                break
            }
        }

        let encoder = JSONEncoder()
        if dates == .iso8601 { encoder.dateEncodingStrategy = .iso8601 }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = VersionedEnvelope(schema: currentSchemaVersion, updatedAt: Date(), data: value)
        try AtomicFile.write(try encoder.encode(envelope), to: url, permissions: permissions)
    }
}
