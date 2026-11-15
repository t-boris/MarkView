import Foundation
import SQLite3

// MARK: - Schema-Versioned Atomic JSON Store & Load Result (AR-36, AR-39)

/// Explicit result of loading a persistent store file (`AR-36`).
///
/// Distinguishes a file that has not been created yet (`.missing`) from a file whose bytes
/// are unreadable or fail schema decoding (`.corrupted`), preventing silent data loss.
enum StoreLoadResult<T> {
    case loaded(T, schemaVersion: Int)
    case missing(URL)
    case corrupted(URL, String)

    var value: T? {
        if case .loaded(let v, _) = self { return v }
        return nil
    }

    var isCorrupted: Bool {
        if case .corrupted = self { return true }
        return false
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

/// Atomic, schema-versioned JSON store (`AR-36`, `AR-39`).
///
/// - Writes through a sibling temporary file + `FileManager.replaceItemAt` so power loss or crashes
///   never leave a truncated JSON file.
/// - Wraps payloads in `VersionedEnvelope` (`schema: currentSchemaVersion`), while transparently reading
///   legacy unversioned payloads (`schemaVersion: 0`) so existing user files upgrade in place.
/// - Preserves a `.corrupt` backup copy before overwriting a corrupted file when `backupCorruptedOnSave` is enabled.
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
        if let envelope = try? decoder.decode(VersionedEnvelope<T>.self, from: raw) {
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
        if backupCorruptedOnSave, fm.fileExists(atPath: url.path) {
            if case .corrupted = load(from: url) {
                let backupURL = url.appendingPathExtension("corrupt")
                try? fm.removeItem(at: backupURL)
                try? fm.copyItem(at: url, to: backupURL)
            }
        }

        let envelope = VersionedEnvelope(schema: currentSchemaVersion, updatedAt: Date(), data: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(envelope)
        try AtomicFile.write(encoded, to: url, permissions: permissions)
    }
}

// MARK: - Off-Main-Thread SQLite Executor & Ordered Schema Migrations (AR-37, AR-38)

/// Ordered SQLite schema migration entry applied under `BEGIN IMMEDIATE` and recorded in `PRAGMA user_version` (`AR-38`).
struct SQLiteMigration: Sendable {
    let version: Int32
    let name: String
    let statements: [String]
}

/// Serialized off-main-thread SQLite actor (`AR-37`, `AR-38`).
///
/// Runs queries, batch writes, and numbered schema migrations on its own actor executor so
/// SQLite I/O never blocks `@MainActor`.
actor SemanticDatabaseExecutor {
    let dbPath: String
    private var db: OpaquePointer?

    init(dbPath: String, migrations: [SQLiteMigration] = SemanticDatabaseExecutor.defaultMigrations) throws {
        self.dbPath = dbPath
        var ptr: OpaquePointer?
        guard sqlite3_open(dbPath, &ptr) == SQLITE_OK, let opened = ptr else {
            let msg = ptr.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open failed"
            if let ptr { sqlite3_close(ptr) }
            throw NSError(domain: "com.markview.sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.db = opened
        try Self.execSQL(opened, "PRAGMA foreign_keys = ON")
        try Self.execSQL(opened, "PRAGMA journal_mode = WAL")
        try Self.execSQL(opened, "PRAGMA synchronous = NORMAL")
        try Self.execSQL(opened, "PRAGMA busy_timeout = 5000")
        try Self.applyMigrations(migrations, on: opened)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func currentUserVersion() -> Int32 {
        guard let db else { return 0 }
        return Self.queryUserVersion(on: db)
    }

    func execute(_ sql: String) throws {
        guard let db else { return }
        try Self.execSQL(db, sql)
    }

    func executeTransaction(_ statements: [String]) throws {
        guard let db else { return }
        try Self.execSQL(db, "BEGIN IMMEDIATE")
        do {
            for sql in statements {
                try Self.execSQL(db, sql)
            }
            try Self.execSQL(db, "COMMIT")
        } catch {
            try? Self.execSQL(db, "ROLLBACK")
            throw error
        }
    }

    func queryScalarInt(_ sql: String) -> Int64? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    static let defaultMigrations: [SQLiteMigration] = [
        SQLiteMigration(
            version: 1,
            name: "initial_doc_id_scheme",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    applied_at INTEGER NOT NULL
                )
                """
            ]
        ),
        SQLiteMigration(
            version: 2,
            name: "documents_updated_at_index",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    applied_at INTEGER NOT NULL
                )
                """
            ]
        ),
    ]

    static func queryUserVersion(on db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    static func applyMigrations(_ migrations: [SQLiteMigration], on db: OpaquePointer) throws {
        let sorted = migrations.sorted { $0.version < $1.version }
        var current = queryUserVersion(on: db)
        for migration in sorted where migration.version > current {
            try execSQL(db, "BEGIN IMMEDIATE")
            do {
                try execSQL(db, """
                    CREATE TABLE IF NOT EXISTS schema_migrations (
                        version INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        applied_at INTEGER NOT NULL
                    )
                """)
                for sql in migration.statements {
                    try execSQL(db, sql)
                }
                let now = Int(Date().timeIntervalSince1970)
                let escapedName = migration.name.replacingOccurrences(of: "'", with: "''")
                try execSQL(db, "INSERT OR REPLACE INTO schema_migrations (version, name, applied_at) VALUES (\(migration.version), '\(escapedName)', \(now))")
                try execSQL(db, "PRAGMA user_version = \(migration.version)")
                try execSQL(db, "COMMIT")
                current = migration.version
            } catch {
                try? execSQL(db, "ROLLBACK")
                throw error
            }
        }
    }

    private static func execSQL(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw NSError(domain: "com.markview.sqlite", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
