import CryptoKit
import Foundation
import os
import SQLite3
import XCTest
@testable import MarkViewCore

/// Real SQLite files in a temporary folder (`AR-38`): no mocks, the files are opened with the same engine the app uses.
final class SQLiteSchemaTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mvcore-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var path: String { folder.appendingPathComponent("state.db").path }

    // MARK: - Helpers

    private func raw(_ sql: String, at file: String? = nil) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file ?? path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func scalar(_ sql: String, at file: String? = nil) -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file ?? path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func digest(_ file: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: file))).map { String(format: "%02x", $0) }.joined()
    }

    private let steps = [
        SQLiteMigration(version: 1, name: "notes") { db in
            try SQLiteSchema.execute(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
        },
        SQLiteMigration(version: 2, name: "notes.tag") { db in
            try SQLiteSchema.execute(db, "ALTER TABLE notes ADD COLUMN tag TEXT")
            try SQLiteSchema.execute(db, "CREATE TABLE tags (name TEXT PRIMARY KEY)")
        },
    ]

    // MARK: - Tests

    func testNewFileGetsEveryStepAndTheLatestVersion() throws {
        let opened = try SQLiteSchema.open(path: path, migrations: steps)
        defer { sqlite3_close(opened.handle) }
        XCTAssertEqual(opened.startVersion, 0)
        XCTAssertEqual(opened.endVersion, 2)
        XCTAssertNil(opened.backup)
        XCTAssertEqual(SQLiteSchema.userVersion(opened.handle), 2)
        XCTAssertTrue(SQLiteSchema.tableExists(opened.handle, "tags"))
        XCTAssertTrue(SQLiteSchema.columnNames(opened.handle, table: "notes").contains("tag"))
    }

    func testOlderFileIsMigratedForwardAndKeepsItsRows() throws {
        try raw("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL); INSERT INTO notes (body) VALUES ('kept'); PRAGMA user_version = 1")
        let inode = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int

        let opened = try SQLiteSchema.open(path: path, migrations: steps)
        sqlite3_close(opened.handle)

        XCTAssertEqual(opened.startVersion, 1)
        XCTAssertEqual(opened.endVersion, 2)
        XCTAssertNil(opened.backup)
        XCTAssertEqual(scalar("SELECT count(*) FROM notes WHERE body = 'kept'"), 1)
        XCTAssertEqual(scalar("PRAGMA user_version"), 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int, inode, "the file is migrated in place")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("corrupt") }
        XCTAssertTrue(siblings.isEmpty)
    }

    func testNewerFileIsRefusedAndLeftByteForByte() throws {
        try raw("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL); INSERT INTO notes (body) VALUES ('future'); PRAGMA user_version = 9")
        let hash = try digest(path)

        XCTAssertThrowsError(try SQLiteSchema.open(path: path, migrations: steps,
                                                   pragmas: ["PRAGMA journal_mode = WAL"])) { error in
            XCTAssertEqual(error as? SQLiteSchemaError, .newerSchema(found: 9, supported: 2))
        }
        XCTAssertEqual(try digest(path), hash, "not one byte of a newer file changes, not even the journal mode")
        XCTAssertEqual(scalar("PRAGMA user_version"), 9)
        XCTAssertEqual(scalar("SELECT count(*) FROM notes"), 1)
    }

    func testFailedStepRollsBackWithItsVersion() throws {
        let failing = steps + [SQLiteMigration(version: 3, name: "broken") { db in
            try SQLiteSchema.execute(db, "CREATE TABLE half (id INTEGER)")
            try SQLiteSchema.execute(db, "INSERT INTO missing_table VALUES (1)")
        }]
        XCTAssertThrowsError(try SQLiteSchema.open(path: path, migrations: failing)) { error in
            guard case .migrationFailed(let version, let name, _) = error as? SQLiteSchemaError else { return XCTFail("\(error)") }
            XCTAssertEqual(version, 3)
            XCTAssertEqual(name, "broken")
        }
        XCTAssertEqual(scalar("PRAGMA user_version"), 2, "steps 1 and 2 stay applied, step 3 left no trace")
        XCTAssertEqual(scalar("SELECT count(*) FROM sqlite_master WHERE name = 'half'"), 0)
        // The next release with a fixed step 3 finishes the job on the same file.
        let fixed = steps + [SQLiteMigration(version: 3, name: "fixed") { db in
            try SQLiteSchema.execute(db, "CREATE TABLE half (id INTEGER)")
        }]
        let opened = try SQLiteSchema.open(path: path, migrations: fixed)
        sqlite3_close(opened.handle)
        XCTAssertEqual(opened.startVersion, 2)
        XCTAssertEqual(opened.endVersion, 3)
    }

    func testUnreadableFileIsMovedAsideWithItsWalAndRebuilt() throws {
        try Data("this is not a database, only text that fills a page ".utf8 + Data(repeating: 0x41, count: 5000)).write(to: URL(fileURLWithPath: path))
        try Data("stale write-ahead log".utf8).write(to: URL(fileURLWithPath: path + "-wal"))
        try Data("stale shared memory".utf8).write(to: URL(fileURLWithPath: path + "-shm"))

        let opened = try SQLiteSchema.open(path: path, migrations: steps, pragmas: ["PRAGMA journal_mode = WAL"])
        defer { sqlite3_close(opened.handle) }

        let backup = try XCTUnwrap(opened.backup)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("state.db.corrupt-"), backup.lastPathComponent)
        XCTAssertTrue(try String(contentsOf: backup).hasPrefix("this is not a database"))
        XCTAssertEqual(try String(contentsOfFile: backup.path + "-wal"), "stale write-ahead log")
        XCTAssertEqual(try String(contentsOfFile: backup.path + "-shm"), "stale shared memory")
        XCTAssertEqual(SQLiteSchema.userVersion(opened.handle), 2)
        XCTAssertTrue(SQLiteSchema.tableExists(opened.handle, "notes"))
        if let wal = try? String(contentsOfFile: path + "-wal") { XCTAssertFalse(wal.contains("stale"), "the stale log must not be replayed into the new file") }
    }

    func testValidHeaderWithDamagedSchemaPageIsMovedAside() throws {
        try raw("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL); INSERT INTO notes (body) VALUES ('lost'); PRAGMA user_version = 1")
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 200))
        try handle.close()

        let opened = try SQLiteSchema.open(path: path, migrations: steps)
        defer { sqlite3_close(opened.handle) }
        let backup = try XCTUnwrap(opened.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(opened.startVersion, 0)
        XCTAssertEqual(opened.endVersion, 2)
        XCTAssertEqual(scalar("SELECT count(*) FROM notes"), 0, "the new file starts empty")
    }

    func testTwoOpensOfTheSameNewFileApplyEachStepOnce() throws {
        let counted = [
            SQLiteMigration(version: 1, name: "runs") { db in
                try SQLiteSchema.execute(db, "CREATE TABLE runs (step INTEGER)")
                try SQLiteSchema.execute(db, "INSERT INTO runs VALUES (1)")
            },
            SQLiteMigration(version: 2, name: "runs again") { db in
                try SQLiteSchema.execute(db, "INSERT INTO runs VALUES (2)")
            },
        ]
        let errors = OSAllocatedUnfairLock(initialState: [Error]())
        let path = self.path
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do {
                let opened = try SQLiteSchema.open(path: path, migrations: counted, pragmas: ["PRAGMA journal_mode = WAL"])
                sqlite3_close(opened.handle)
            } catch {
                errors.withLock { $0.append(error) }
            }
        }
        let failed = errors.withLock { $0 }
        XCTAssertTrue(failed.isEmpty, "\(failed)")
        XCTAssertEqual(scalar("SELECT count(*) FROM runs WHERE step = 1"), 1)
        XCTAssertEqual(scalar("SELECT count(*) FROM runs WHERE step = 2"), 1)
        XCTAssertEqual(scalar("PRAGMA user_version"), 2)
    }

    func testInMemoryDatabaseGetsEveryStep() throws {
        let opened = try SQLiteSchema.openInMemory(migrations: steps)
        defer { sqlite3_close(opened.handle) }
        XCTAssertEqual(SQLiteSchema.userVersion(opened.handle), 2)
        XCTAssertTrue(SQLiteSchema.tableExists(opened.handle, "tags"))
    }

    func testMigrationListMustAscendFromOne() {
        let nothing: @Sendable (OpaquePointer) throws -> Void = { _ in }
        XCTAssertThrowsError(try SQLiteSchema.open(path: path, migrations: []))
        XCTAssertThrowsError(try SQLiteSchema.open(path: path, migrations: [SQLiteMigration(version: 0, name: "zero", apply: nothing)]))
        XCTAssertThrowsError(try SQLiteSchema.open(path: path, migrations: [
            SQLiteMigration(version: 2, name: "b", apply: nothing), SQLiteMigration(version: 2, name: "c", apply: nothing)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "an invalid list must not create the file")
    }
}
