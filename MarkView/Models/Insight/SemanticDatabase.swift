import Foundation
import SQLite3
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// SQLite wrapper for .dde/state.db — stores semantic blocks, documents, and compilation cache.
///
/// An actor (`AR-37`): the connection belongs to the actor and every statement runs on its executor, never on the main
/// thread, so a lock held by the indexer child process (`busy_timeout`) or a large transaction cannot freeze the UI.
/// Callers `await`; each method is one atomic step of the actor, and a caller that needs two writes applied in order
/// awaits the first before it starts the second.
actor SemanticDatabase {
    /// The database file, or nil while this session uses an in-memory index because the file had to be left alone.
    nonisolated let dbPath: String?
    let db: OpaquePointer

    private init(handle: OpaquePointer, path: String?) {
        self.db = handle
        self.dbPath = path
    }

    /// The state database of a project folder: `.dde/state.db`, or the same name in the app container when the folder
    /// is read-only. The file is opened and migrated off the caller's thread.
    static func open(workspacePath: URL, dbName: String = "state.db") async throws -> SemanticDatabase {
        let file = try await Task.detached(priority: .userInitiated) {
            try Self.openFile(workspacePath: workspacePath, dbName: dbName)
        }.value
        return SemanticDatabase(handle: file.handle, path: file.path)
    }

    private struct OpenedFile: @unchecked Sendable {
        let handle: OpaquePointer
        let path: String?
    }

    private static func openFile(workspacePath: URL, dbName: String) throws -> OpenedFile {
        let fm = FileManager.default

        // Try .dde/ next to workspace first; fall back to app container if sandboxed
        var ddeDir = ProjectPaths.localFolder(workspacePath)
        do {
            if !fm.fileExists(atPath: ddeDir.path) {
                try fm.createDirectory(at: ddeDir, withIntermediateDirectories: true)
            }
        } catch {
            // Sandbox: can't write next to workspace. Use collision-free projectCacheIdentifier in Application Support (`AR-39`).
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let workspaceId = ProjectPaths.projectCacheIdentifier(for: workspacePath)
            ddeDir = appSupport.appendingPathComponent("MarkView/Projects/\(workspaceId)")
            try fm.createDirectory(at: ddeDir, withIntermediateDirectories: true)
            AppLog.index.notice("Sandbox fallback: \(ddeDir.path)")
        }

        let path = ddeDir.appendingPathComponent(dbName).path
        let (opened, persistent) = try openMigrated(path: path)
        return OpenedFile(handle: opened.handle, path: persistent ? path : nil)
    }

    /// Open `path` and bring it to the current schema (`AR-38`). A file that must stay as it is (written by a newer
    /// release, or a migration step failed and was rolled back) is not touched: this session gets an empty in-memory
    /// index and the log says so. An unreadable file is moved aside to a dated backup and rebuilt; the index is derived
    /// data, so the rebuild loses nothing the next index run cannot recreate, and no document is involved.
    private static func openMigrated(path: String) throws -> (opened: SQLiteOpened, persistent: Bool) {
        do {
            let opened = try SQLiteSchema.open(path: path, migrations: SemanticSchema.migrations,
                                               pragmas: SemanticSchema.pragmas,
                                               busyTimeoutMilliseconds: SemanticSchema.busyTimeoutMilliseconds)
            if let backup = opened.backup {
                AppLog.index.error("\(path) was unreadable; moved aside to \(backup.path) and rebuilt (derived index data)")
            }
            if opened.startVersion != opened.endVersion {
                AppLog.index.notice("Schema of \(path) migrated from version \(opened.startVersion) to \(opened.endVersion)")
            }
            return (opened, true)
        } catch let error as SQLiteSchemaError {
            switch error {
            case .newerSchema, .migrationFailed:
                AppLog.index.error("\(path) left untouched, using an empty in-memory index for this session: \(error.localizedDescription)")
                do {
                    return (try SQLiteSchema.openInMemory(migrations: SemanticSchema.migrations, pragmas: SemanticSchema.pragmas), false)
                } catch {
                    throw SemanticDBError.openFailed(error.localizedDescription)
                }
            default:
                throw SemanticDBError.openFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Document ID scheme

    /// Canonical document id: path relative to the workspace `root` (POSIX, forward
    /// slashes, no leading separator). Falls back to the file name for the root
    /// itself or paths outside the root — so single-file workspaces (root == parent
    /// dir) yield just the file name. Used everywhere a docId is derived from a URL
    /// so the key never collides across same-named files in different folders.
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        #if canImport(MarkViewCore)
        if let relative = ProjectPaths.relativePath(of: fileURL, under: root), !relative.isEmpty {
            return relative
        }
        return fileURL.lastPathComponent
        #else
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
        #endif
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Project CRUD

    func ensureProject(id: String, name: String, rootPath: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try execute("""
            INSERT INTO projects (project_id, project_name, root_path, created_at, updated_at, schema_version)
            VALUES (?, ?, ?, ?, ?, '1.0')
            ON CONFLICT(project_id) DO UPDATE SET updated_at = ?
        """, params: [.text(id), .text(name), .text(rootPath), .int(now), .int(now), .int(now)])
    }

    // MARK: - Document CRUD

    func upsertDocument(id: String, projectId: String, filePath: String, fileName: String,
                        fileExt: String, contentHash: String, fileMtime: Int? = nil) throws {
        let now = Int(Date().timeIntervalSince1970)
        // Bind NULL when mtime unknown (mirrors the existing line-number int/null pattern).
        let mtimeParam: SQLValue = fileMtime.map { .int($0) } ?? .textOrNull(nil)
        try execute("""
            INSERT INTO documents (document_id, project_id, file_path, file_name, file_ext, content_hash, file_mtime, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET content_hash = ?, file_mtime = ?, updated_at = ?
        """, params: [.text(id), .text(projectId), .text(filePath), .text(fileName),
                     .text(fileExt), .text(contentHash), mtimeParam, .int(now), .int(now),
                     .text(contentHash), mtimeParam, .int(now)])
    }

    /// Batch-fetch `document_id → (content_hash, file_mtime)` for every document in one query.
    /// Replaces the per-file `getDocumentHash()` round-trips the structural indexer used to make.
    func allDocumentMeta() -> [String: (hash: String, mtime: Int?)] {
        var results: [String: (hash: String, mtime: Int?)] = [:]
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT document_id, content_hash, file_mtime FROM documents"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let docId = String(cString: sqlite3_column_text(stmt, 0))
            let hash = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let mtime: Int? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 2))
            results[docId] = (hash, mtime)
        }
        return results
    }

    // MARK: - Blocks

    private func upsertBlock(_ block: SemanticBlock, documentId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        let headingPathJSON = (try? JSONEncoder().encode(block.headingPath))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try execute("""
            INSERT INTO blocks (block_id, document_id, parent_block_id, block_kind, heading_path_json,
                anchor, order_index, line_start, line_end, raw_markdown, plain_text, text_hash,
                semantic_hash, compile_status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'stale', ?, ?)
            ON CONFLICT(block_id) DO UPDATE SET
                raw_markdown = ?, plain_text = ?, text_hash = ?, compile_status = 'stale', updated_at = ?
        """, params: [
            .text(block.id), .text(documentId), .textOrNull(block.parentBlockId),
            .text(block.type.rawValue), .text(headingPathJSON), .textOrNull(block.anchor),
            .int(block.position), .int(block.lineStart), .int(block.lineEnd),
            .text(block.content), .text(block.plainText), .text(block.contentHash),
            .textOrNull(block.semanticHash), .int(now), .int(now),
            .text(block.content), .text(block.plainText), .text(block.contentHash), .int(now)
        ])
    }

    /// One block delta of an open document: the added and changed blocks are written, the removed ones are deleted with
    /// their claims, relations and diagnostics. Each statement stands alone and a failed one is skipped, as before.
    func applyBlockDelta(documentId: String, upserts: [SemanticBlock], removed: [String]) {
        for block in upserts {
            try? upsertBlock(block, documentId: documentId)
        }
        for id in removed {
            try? execute("DELETE FROM blocks WHERE block_id = ?", params: [.text(id)])
            try? execute("DELETE FROM claims WHERE source_block_id = ?", params: [.text(id)])
            try? execute("DELETE FROM entity_relations WHERE source_block_id = ?", params: [.text(id)])
            try? execute("DELETE FROM diagnostics WHERE block_id = ?", params: [.text(id)])
        }
    }

    // MARK: - Usage Stats (persisted across sessions)

    struct UsageStats {
        var totalInputTokens: Int
        var totalOutputTokens: Int
        var totalJobs: Int
        var totalCostCents: Double

        var totalTokens: Int { totalInputTokens + totalOutputTokens }
        var totalCostDollars: Double { totalCostCents / 100.0 }
    }

    func getUsageStats() -> UsageStats {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT total_input_tokens, total_output_tokens, total_jobs, total_cost_cents FROM usage_stats WHERE id = 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return UsageStats(totalInputTokens: 0, totalOutputTokens: 0, totalJobs: 0, totalCostCents: 0)
        }
        return UsageStats(
            totalInputTokens: Int(sqlite3_column_int64(stmt, 0)),
            totalOutputTokens: Int(sqlite3_column_int64(stmt, 1)),
            totalJobs: Int(sqlite3_column_int64(stmt, 2)),
            totalCostCents: sqlite3_column_double(stmt, 3)
        )
    }

    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {
        try? execute("""
            UPDATE usage_stats SET
                total_input_tokens = total_input_tokens + ?,
                total_output_tokens = total_output_tokens + ?,
                total_jobs = total_jobs + 1,
                total_cost_cents = total_cost_cents + ?
            WHERE id = 1
        """, params: [.int(inputTokens), .int(outputTokens), .real(costCents)])
    }

    // MARK: - V1 Structural Index

    func upsertModule(id: String, name: String, path: String, parentId: String?, level: Int, fileCount: Int) {
        try? execute("""
            INSERT INTO modules (module_id, name, path, parent_module_id, level, file_count)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(module_id) DO UPDATE SET file_count=?, name=?
        """, params: [.text(id), .text(name), .text(path), .textOrNull(parentId), .int(level), .int(fileCount), .int(fileCount), .text(name)])
    }

    func insertSymbol(id: String, moduleId: String?, documentId: String?, name: String, kind: String, lineStart: Int?, lineEnd: Int?, context: String?) {
        try? execute("""
            INSERT OR IGNORE INTO symbols (symbol_id, module_id, document_id, name, kind, line_start, line_end, context)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text(id), .textOrNull(moduleId), .textOrNull(documentId), .text(name), .text(kind),
                     lineStart.map { .int($0) } ?? .textOrNull(nil), lineEnd.map { .int($0) } ?? .textOrNull(nil), .textOrNull(context)])
    }

    func insertRelation(id: String, sourceId: String, targetId: String, type: String, sourceDoc: String?, evidence: String?) {
        try? execute("""
            INSERT OR IGNORE INTO struct_relations (relation_id, source_id, target_id, type, source_doc, evidence)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text(id), .text(sourceId), .text(targetId), .text(type), .textOrNull(sourceDoc), .textOrNull(evidence)])
    }

    func indexDocumentFTS(documentId: String, title: String, content: String) {
        // Delete old entry first, then insert new
        try? execute("DELETE FROM fts_documents WHERE document_id = ?", params: [.text(documentId)])
        try? execute("INSERT INTO fts_documents (document_id, title, content) VALUES (?, ?, ?)",
                    params: [.text(documentId), .text(title), .text(content)])
    }

    // MARK: - FTS5 Search

    struct SearchResult {
        let documentId: String
        let title: String
        let snippet: String
        let rank: Double
    }

    func search(query: String, limit: Int = 50) -> [SearchResult] {
        var results: [SearchResult] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT document_id, title, snippet(fts_documents, 2, '>>>', '<<<', '...', 40), rank FROM fts_documents WHERE fts_documents MATCH ? ORDER BY rank LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let docId = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let snippet = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 3)
            results.append(SearchResult(documentId: docId, title: title, snippet: snippet, rank: rank))
        }
        return results
    }

    // MARK: - Module Queries

    struct ModuleInfo {
        let id: String
        let name: String
        let path: String
        let level: Int
        let fileCount: Int
        let description: String?
    }

    func allModules() -> [ModuleInfo] {
        var results: [ModuleInfo] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT module_id, name, path, level, file_count, description FROM modules ORDER BY path"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(ModuleInfo(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2)),
                level: Int(sqlite3_column_int(stmt, 3)),
                fileCount: Int(sqlite3_column_int(stmt, 4)),
                description: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            ))
        }
        return results
    }

    /// Drop what the index holds for documents that left the project (an excluded folder): their heading, link and
    /// code-block symbols, and their search text (replaced by an empty entry, as the exclusion always did).
    func forgetDocuments(_ ids: [String]) {
        for id in ids {
            for kind in ["heading", "link", "code_block"] {
                try? execute("DELETE FROM symbols WHERE document_id = ? AND kind = ?", params: [.text(id), .text(kind)])
            }
            indexDocumentFTS(documentId: id, title: "", content: "")
        }
    }

    // MARK: - Low-level SQL
    // Internal to the module so a domain that keeps its own tables in this database can extend the actor (see the Architecture domain).

    enum SQLValue {
        case text(String)
        case textOrNull(String?)
        case int(Int)
        case intOrNull(Int?)
        case real(Double)
    }

    /// SQLITE_TRANSIENT tells SQLite to copy string data immediately,
    /// so the temporary Swift string buffer can be safely freed.
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var SQLITE_TRANSIENT: sqlite3_destructor_type { Self.sqliteTransient }

    func execute(_ sql: String, params: [SQLValue] = []) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SemanticDBError.prepareFailed(msg)
        }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .textOrNull(let s):
                if let s = s {
                    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, Int64(n))
            case .intOrNull(let n):
                if let n { sqlite3_bind_int64(stmt, idx, Int64(n)) } else { sqlite3_bind_null(stmt, idx) }
            case .real(let d):
                sqlite3_bind_double(stmt, idx, d)
            }
        }

        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SemanticDBError.executeFailed(msg)
        }
    }
}

enum SemanticDBError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .executeFailed(let msg): return "SQLite execute failed: \(msg)"
        }
    }
}
