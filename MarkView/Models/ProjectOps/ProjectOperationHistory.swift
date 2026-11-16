import Foundation
import SQLite3
#if canImport(MarkViewCore)
import MarkViewCore
#endif

private let projectSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ProjectOperationLastRun: Codable {
    var id: String
    var label: String
    var environment: String?
    var command: String
    var cwd: String
    var started: Date
    var ended: Date?
    var state: String
    var exitCode: Int32?
}

/// This is deliberately separate from the shared operations file: output and run history
/// can contain secrets or machine-specific details and never enter version control.
enum ProjectOperationHistory {
    static func open(root: URL) throws -> OpaquePointer {
        let folder = ProjectPaths.localFolder(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = folder.appendingPathComponent("state.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw ProjectOperationError.invalid("Cannot open local run history at \(path)")
        }
        sqlite3_busy_timeout(db, 5000)
        let sql = """
            CREATE TABLE IF NOT EXISTS project_operation_runs (
                id TEXT PRIMARY KEY, json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS project_operation_run_events (
                id TEXT NOT NULL, started REAL NOT NULL, json TEXT NOT NULL,
                PRIMARY KEY (id, started)
            );
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw ProjectOperationError.invalid("Cannot prepare local run history: \(error)")
        }
        return db
    }

    static func load(root: URL) throws -> [String: ProjectOperationLastRun] {
        let db = try open(root: root)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id, json FROM project_operation_runs", -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectOperationError.invalid("Cannot read local run history")
        }
        var result: [String: ProjectOperationLastRun] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0), let raw = sqlite3_column_text(stmt, 1),
                  let run = try? JSONDecoder().decode(ProjectOperationLastRun.self, from: Data(String(cString: raw).utf8)) else { continue }
            result[String(cString: id)] = run
        }
        return result
    }

    static func save(_ run: ProjectOperationLastRun, root: URL) throws {
        let db = try open(root: root)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT OR REPLACE INTO project_operation_runs(id, json) VALUES(?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectOperationError.invalid("Cannot write local run history")
        }
        let data = try JSONEncoder().encode(run)
        let json = String(decoding: data, as: UTF8.self)
        sqlite3_bind_text(stmt, 1, run.id, -1, projectSQLiteTransient)
        sqlite3_bind_text(stmt, 2, json, -1, projectSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ProjectOperationError.invalid("Cannot write local run history: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        stmt = nil
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO project_operation_run_events(id, started, json) VALUES(?, ?, ?)",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw ProjectOperationError.invalid("Cannot write operation run event")
        }
        sqlite3_bind_text(stmt, 1, run.id, -1, projectSQLiteTransient)
        sqlite3_bind_double(stmt, 2, run.started.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, json, -1, projectSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ProjectOperationError.invalid("Cannot write operation run event")
        }
    }
}
