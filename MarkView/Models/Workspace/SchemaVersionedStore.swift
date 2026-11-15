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
}

enum SchemaStoreError: LocalizedError, Equatable {
    case newerSchemaVersion(url: URL, found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .newerSchemaVersion(let url, let found, let supported):
            return "Refusing to overwrite \(url.lastPathComponent) because its schema version (\(found)) is newer than supported (\(supported))."
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

private struct SchemaVersionProbe: Decodable {
    let schema: Int?
}

private let schemaBackupTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyyMMddHHmmss"
    return f
}()

/// Atomic, schema-versioned JSON store (`AR-36`, `AR-39`, `FU-04`).
///
/// - Writes through `AtomicFile.write` (POSIX `fchmod` before `rename`) so permissions and file contents are atomic.
/// - Wraps payloads in `VersionedEnvelope` (`schema: currentSchemaVersion`), while transparently reading
///   legacy unversioned payloads (`schemaVersion: 0`) so existing user files upgrade in place.
/// - Refuses to overwrite or downgrade payloads whose schema/version is newer than `currentSchemaVersion`.
/// - Preserves non-clobbering `.corrupt-<timestamp>-<suffix>` backup copies before overwriting corrupted files.
struct SchemaVersionedStore<T: Codable> {
    let currentSchemaVersion: Int
    let backupCorruptedOnSave: Bool

    init(currentSchemaVersion: Int = 1, backupCorruptedOnSave: Bool = true) {
        self.currentSchemaVersion = max(1, currentSchemaVersion)
        self.backupCorruptedOnSave = backupCorruptedOnSave
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let probe = try? decoder.decode(SchemaVersionProbe.self, from: raw),
           let foundSchema = probe.schema,
           foundSchema > currentSchemaVersion {
            return .newerSchema(url, foundSchema)
        }

        if let envelope = try? decoder.decode(VersionedEnvelope<T>.self, from: raw) {
            if envelope.schema > currentSchemaVersion {
                return .newerSchema(url, envelope.schema)
            }
            return .loaded(envelope.data, schemaVersion: envelope.schema)
        }

        // Fallback for legacy unversioned JSON files (`schemaVersion: 0`)
        let legacyDecoder = JSONDecoder()
        do {
            let legacy = try legacyDecoder.decode(T.self, from: raw)
            return .loaded(legacy, schemaVersion: 0)
        } catch {
            return .corrupted(url, error.localizedDescription)
        }
    }

    func save(_ value: T, to url: URL, permissions: Int16 = 0o600) throws {
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
                if backupCorruptedOnSave {
                    let stamp = schemaBackupTimestampFormatter.string(from: Date())
                    let uniqueSuffix = UUID().uuidString.prefix(8).lowercased()
                    let backupURL = url.appendingPathExtension("corrupt-\(stamp)-\(uniqueSuffix)")
                    try? fm.copyItem(at: url, to: backupURL)
                }
            case .loaded, .missing:
                break
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = VersionedEnvelope(schema: currentSchemaVersion, updatedAt: Date(), data: value)
        let encoded = try encoder.encode(envelope)
        try AtomicFile.write(encoded, to: url, permissions: permissions)
    }
}
