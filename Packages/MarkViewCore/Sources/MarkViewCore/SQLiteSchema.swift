import Foundation
import SQLite3

/// One forward step of a SQLite schema (`AR-38`). Applying the step with `version` N moves `PRAGMA user_version` to N.
public struct SQLiteMigration {
    public let version: Int32
    public let name: String
    /// Runs inside the transaction that also writes `user_version`; throwing rolls the whole step back.
    public let apply: (OpaquePointer) throws -> Void

    public init(version: Int32, name: String, apply: @escaping (OpaquePointer) throws -> Void) {
        self.version = version
        self.name = name
        self.apply = apply
    }
}

public enum SQLiteSchemaError: Error, LocalizedError, Equatable {
    /// The file could not be opened or moved aside; nothing else was changed.
    case openFailed(String)
    /// The file belongs to a newer app than this one; it is left exactly as it was.
    case newerSchema(found: Int32, supported: Int32)
    /// A step failed and was rolled back; the file stays at the version before it.
    case migrationFailed(version: Int32, name: String, message: String)
    /// A statement of a migration failed.
    case statementFailed(String)
    /// The migration list is empty, not ascending, or starts below 1.
    case invalidMigrations(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "SQLite open failed: \(message)"
        case .newerSchema(let found, let supported):
            return "The database has schema version \(found); this app knows up to \(supported)"
        case .migrationFailed(let version, let name, let message):
            return "Schema migration \(version) (\(name)) failed: \(message)"
        case .statementFailed(let message): return "SQLite statement failed: \(message)"
        case .invalidMigrations(let message): return "Invalid migration list: \(message)"
        }
    }
}

/// An open, migrated database. The caller owns `handle` and closes it with `sqlite3_close`.
public struct SQLiteOpened {
    public let handle: OpaquePointer
    /// `user_version` found in the file (0 for a new or unversioned file).
    public let startVersion: Int32
    public let endVersion: Int32
    /// Where a corrupt file was moved to (its `-wal` and `-shm` sit beside it), or nil.
    public let backup: URL?
}

/// Ordered, transactional schema migrations driven by `PRAGMA user_version` (`AR-38`).
///
/// - An older database is migrated forward step by step; each step and its `user_version` write are one
///   `BEGIN IMMEDIATE` transaction, and the version is read again under the write lock, so two processes opening the
///   same file at once apply a step once.
/// - A database with a newer version than the migration list is refused before anything is written (not even the
///   journal mode changes); the file is left as it was.
/// - A file SQLite cannot read (not a database, malformed header or schema) is moved aside to a dated backup, with its
///   `-wal` and `-shm`, and a new file is created. The caller decides whether the content is derived data worth that.
public enum SQLiteSchema {
    public static func open(path: String, migrations: [SQLiteMigration], pragmas: [String] = [],
                            busyTimeoutMilliseconds: Int32 = 5000) throws -> SQLiteOpened {
        let latest = try validate(migrations)
        var backup: URL?
        for attempt in 0..<3 {
            let identity = fileIdentity(path)
            var unreadable = foreignHeader(path)
            var opened: (handle: OpaquePointer, version: Int32)?
            if unreadable == nil {
                let handle = try openHandle(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
                sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
                switch inspect(handle, waitMilliseconds: busyTimeoutMilliseconds) {
                case .version(let found):
                    opened = (handle, found)
                case .unreadable(let message):
                    sqlite3_close(handle)
                    unreadable = message
                case .failed(let error):
                    sqlite3_close(handle)
                    throw error
                }
            }
            guard let (handle, startVersion) = opened else {
                guard attempt < 2 else { throw SQLiteSchemaError.openFailed(unreadable ?? "unreadable") }
                // Another process may have replaced the file since it was inspected: only move aside what was inspected.
                guard fileIdentity(path) == identity else { continue }
                backup = try quarantine(path: path)
                continue
            }

            if startVersion > latest {
                sqlite3_close(handle)
                throw SQLiteSchemaError.newerSchema(found: startVersion, supported: latest)
            }
            do {
                for pragma in pragmas { try executeWaiting(handle, pragma, milliseconds: busyTimeoutMilliseconds) }
                let endVersion = try migrate(handle, migrations: migrations)
                return SQLiteOpened(handle: handle, startVersion: startVersion, endVersion: endVersion, backup: backup)
            } catch {
                sqlite3_close(handle)
                throw error
            }
        }
        throw SQLiteSchemaError.openFailed("the database kept changing while it was opened")
    }

    /// A private in-memory database with every migration applied: what the app uses when the file must be left alone.
    public static func openInMemory(migrations: [SQLiteMigration], pragmas: [String] = []) throws -> SQLiteOpened {
        _ = try validate(migrations)
        let handle = try openHandle(path: ":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        do {
            for pragma in pragmas { try execute(handle, pragma) }
            let endVersion = try migrate(handle, migrations: migrations)
            return SQLiteOpened(handle: handle, startVersion: 0, endVersion: endVersion, backup: nil)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    // MARK: - Helpers for migration steps

    /// Run one statement (or several separated by `;`) and throw its message on failure.
    public static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteSchemaError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &statement, nil) == SQLITE_OK
        else { return false }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public static func columnNames(_ db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
        return names
    }

    /// Add the nullable columns an older version of `table` lacks, keeping its rows.
    public static func addMissingColumns(_ db: OpaquePointer, table: String, _ columns: [(name: String, type: String)]) throws {
        let existing = columnNames(db, table: table)
        for column in columns where !existing.contains(column.name) {
            try execute(db, "ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.type)")
        }
    }

    public static func userVersion(_ db: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: - Internals

    private enum Inspection {
        case version(Int32)
        case unreadable(String)
        case failed(SQLiteSchemaError)
    }

    private static func validate(_ migrations: [SQLiteMigration]) throws -> Int32 {
        guard let first = migrations.first, let last = migrations.last else {
            throw SQLiteSchemaError.invalidMigrations("no migrations")
        }
        guard first.version >= 1 else { throw SQLiteSchemaError.invalidMigrations("versions start at 1") }
        for (previous, next) in zip(migrations, migrations.dropFirst()) where next.version <= previous.version {
            throw SQLiteSchemaError.invalidMigrations("version \(next.version) follows \(previous.version)")
        }
        return last.version
    }

    /// Why a file that exists cannot be a SQLite database, judged from its first bytes alone: SQLite reads a stale
    /// `-wal` beside a file it opens, and that would change the evidence before the file is moved aside.
    private static func foreignHeader(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        if head.isEmpty { return nil }
        return head == Data("SQLite format 3\0".utf8) ? nil : "the file does not start with a SQLite header"
    }

    private static func openHandle(path: String, flags: Int32) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw SQLiteSchemaError.openFailed(message)
        }
        return opened
    }

    /// The version stored in the file. Reading it and the schema table touches no page past the header and the schema,
    /// so a file that is not a database (or has a damaged schema) fails here, before any write.
    private static func inspect(_ handle: OpaquePointer, waitMilliseconds: Int32) -> Inspection {
        let deadline = Date().addingTimeInterval(Double(waitMilliseconds) / 1000)
        while true {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            if sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK,
               sqlite3_step(statement) == SQLITE_ROW {
                return .version(userVersion(handle))
            }
            let code = sqlite3_extended_errcode(handle) & 0xFF
            // Another connection may be switching the journal mode: SQLite reports "locked" without waiting then.
            if (code == SQLITE_BUSY || code == SQLITE_LOCKED) && Date() < deadline { usleep(5_000); continue }
            let message = String(cString: sqlite3_errmsg(handle))
            return code == SQLITE_NOTADB || code == SQLITE_CORRUPT ? .unreadable(message) : .failed(.openFailed(message))
        }
    }

    /// `execute` that waits out a lock another connection holds: converting a database to WAL needs a moment when no
    /// other connection reads it, and SQLite answers "locked" at once instead of calling the busy handler.
    private static func executeWaiting(_ db: OpaquePointer, _ sql: String, milliseconds: Int32) throws {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while true {
            let code = sqlite3_exec(db, sql, nil, nil, nil)
            if code == SQLITE_OK { return }
            if (code & 0xFF == SQLITE_BUSY || code & 0xFF == SQLITE_LOCKED) && Date() < deadline { usleep(5_000); continue }
            throw SQLiteSchemaError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func migrate(_ handle: OpaquePointer, migrations: [SQLiteMigration]) throws -> Int32 {
        for migration in migrations {
            guard userVersion(handle) < migration.version else { continue }
            do {
                try execute(handle, "BEGIN IMMEDIATE")
            } catch {
                throw SQLiteSchemaError.migrationFailed(version: migration.version, name: migration.name,
                                                        message: String(cString: sqlite3_errmsg(handle)))
            }
            do {
                // Another process may have applied this step while this one waited for the write lock.
                if userVersion(handle) < migration.version {
                    try migration.apply(handle)
                    try execute(handle, "PRAGMA user_version = \(migration.version)")
                }
                try execute(handle, "COMMIT")
            } catch {
                _ = try? execute(handle, "ROLLBACK")
                throw SQLiteSchemaError.migrationFailed(version: migration.version, name: migration.name,
                                                        message: (error as? SQLiteSchemaError)?.errorDescription
                                                            ?? error.localizedDescription)
            }
        }
        return userVersion(handle)
    }

    private struct FileIdentity: Equatable { let device: dev_t; let inode: ino_t }

    private static func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        return stat(path, &info) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }

    /// Move the database and its side files to `<path>.corrupt-<UTC time>[-n]`.
    private static func quarantine(path: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fm = FileManager.default
        let base = path + ".corrupt-" + formatter.string(from: Date())
        var target = base
        var counter = 1
        while fm.fileExists(atPath: target) {
            counter += 1
            target = base + "-\(counter)"
        }
        do {
            try fm.moveItem(atPath: path, toPath: target)
        } catch {
            throw SQLiteSchemaError.openFailed("cannot move the unreadable database aside: \(error.localizedDescription)")
        }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            // A stale write-ahead log beside a new database would be replayed into it, so it must not stay.
            do { try fm.moveItem(atPath: path + suffix, toPath: target + suffix) } catch {
                do { try fm.removeItem(atPath: path + suffix) } catch {
                    throw SQLiteSchemaError.openFailed("cannot move \(suffix) aside: \(error.localizedDescription)")
                }
            }
        }
        return URL(fileURLWithPath: target)
    }
}
