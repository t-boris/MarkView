import CryptoKit
import Foundation
import os
import SQLite3

// Opens real state.db files in a temporary folder through the shipping SemanticDatabase and checks what the schema
// migrations (`AR-38`) promise: nothing is deleted without a backup, a newer file is not written, an older file keeps
// its rows. Compiled by tools/tests/semantic-database-tests.sh.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("mv-semantic-db-" + UUID().uuidString.prefix(8), isDirectory: true)
try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }
let release626 = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
/// The version the last step of `SemanticSchema.migrations` stamps.
let latest: Int64 = 3

// MARK: - Raw access (a connection of the test's own, never the app's)

func raw(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { failures += 1; print("FAIL cannot open \(path)"); return }
    defer { sqlite3_close(db) }
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        failures += 1
        print("FAIL \(String(cString: sqlite3_errmsg(db))) in: \(sql.prefix(80))")
    }
}
func scalar(_ path: String, _ sql: String) -> Int64? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
}
func names(_ path: String, _ sql: String) -> Set<String> {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    var found: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW { if let text = sqlite3_column_text(statement, 0) { found.insert(String(cString: text)) } }
    return found
}
/// Which of the tables the editor's block extractor used to fill (step 3 drops them) the file still has.
func blockTables(_ path: String) -> Set<String> {
    names(path, "SELECT name FROM sqlite_master WHERE type = 'table'").intersection(["blocks", "claims", "block_compilation_cache"])
}
func digest(_ path: String) -> String {
    SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()).map { String(format: "%02x", $0) }.joined()
}
func inode(_ path: String) -> Int? { (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int }
func listing(_ folder: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

/// A project folder with `.dde/state.db` created by the given SQL.
func project(_ name: String, sql: String) -> (root: URL, db: String) {
    let root = sandbox.appendingPathComponent(name, isDirectory: true)
    let dde = root.appendingPathComponent(".dde", isDirectory: true)
    try? fm.createDirectory(at: dde, withIntermediateDirectories: true)
    let path = dde.appendingPathComponent("state.db").path
    raw(path, sql)
    return (root, path)
}

/// The rows a project has by the time it was last used: documents, a symbol, search text, an X-Ray node and the usage totals.
let usedRows = """
INSERT INTO projects (project_id, project_name, root_path, created_at, updated_at, schema_version) VALUES ('p', 'p', '/p', 1, 1, '1.0');
INSERT INTO documents (document_id, project_id, file_path, file_name, file_ext, content_hash, created_at, updated_at)
    VALUES ('docs/alpha.md', 'p', '/p/docs/alpha.md', 'alpha.md', 'md', 'h1', 1, 1);
INSERT INTO blocks (block_id, document_id, block_kind, heading_path_json, order_index, raw_markdown, text_hash, created_at, updated_at)
    VALUES ('b1', 'docs/alpha.md', 'paragraph', '[]', 0, 'text', 'th', 1, 1);
INSERT INTO claims (claim_id, type, source_file, source_block_id, created_at, updated_at) VALUES ('c1', 'fact', 'docs/alpha.md', 'b1', 1, 1);
INSERT INTO block_compilation_cache (block_id, text_hash, cache_created_at, cache_updated_at) VALUES ('b1', 'th', 1, 1);
INSERT INTO modules (module_id, name, path, level) VALUES ('mod_docs', 'docs', '/p/docs', 1);
INSERT INTO symbols (symbol_id, module_id, document_id, name, kind) VALUES ('s1', 'mod_docs', 'docs/alpha.md', 'Alpha', 'heading');
INSERT INTO fts_documents (document_id, title, content) VALUES ('docs/alpha.md', 'alpha', 'zebra crossing in the alpha document');
INSERT INTO arch_nodes (view, id, kind, name, path, loc, files, line, end_line, anchor)
    VALUES ('modules', 'm:', 'root', 'Shop', '', 12, 3, 4, 9, 'shop');
INSERT INTO arch_meta (key, value) VALUES ('scannedAt', '1700000000');
INSERT INTO arch_meta (key, value) VALUES ('systemName', 'Shop');
INSERT INTO arch_reviews (diff_hash, json, created_at) VALUES ('abc', '{"review":true}', 1);
UPDATE usage_stats SET total_input_tokens = 77, total_output_tokens = 5, total_jobs = 2 WHERE id = 1;
"""

@MainActor func run() async throws {
    // MARK: - A new file

    do {
        let root = sandbox.appendingPathComponent("fresh", isDirectory: true)
        let db = try await SemanticDatabase.open(workspacePath: root)
        let path = root.appendingPathComponent(".dde/state.db").path
        check(db.dbPath == path, "a new project gets .dde/state.db")
        check(scalar(path, "PRAGMA user_version") == latest, "a new file is stamped with the latest schema version")
        let tables = names(path, "SELECT name FROM sqlite_master WHERE type = 'table'")
        check(blockTables(path).isEmpty, "a new file has none of the block tables (step 2 creates them, step 3 drops them)")
        check(["projects", "documents", "symbols", "modules", "fts_documents", "arch_nodes", "arch_edges", "arch_meta",
               "arch_reviews", "usage_stats", "chunks", "citations"].allSatisfy(tables.contains), "every table of the index exists")
        check(!tables.contains("applied_migrations"), "the unused applied_migrations table is not created")
        check(["line", "end_line", "anchor", "signature", "tags_json"].allSatisfy(
            names(path, "SELECT name FROM pragma_table_info('arch_nodes')").contains), "arch_nodes has the Book and X-Ray columns")
        check(scalar(path, "SELECT count(*) FROM usage_stats WHERE id = 1") == 1, "the single usage row is seeded")
        check(names(path, "PRAGMA journal_mode") == ["wal"], "the journal mode is WAL")

        try await db.ensureProject(id: "fresh", name: "fresh", rootPath: root.path)
        await db.upsertModule(id: "mod_a", name: "a", path: root.path, parentId: nil, level: 0, fileCount: 1)
        await db.indexDocumentFTS(documentId: "a.md", title: "a", content: "zebra crossing")
        let found = await db.search(query: "zebra").map(\.documentId)
        check(found == ["a.md"], "a project created by the migrations indexes and finds text")
        var snapshot = ArchitectureSnapshot(views: [ArchView(id: "modules", nodes: [ArchNode(id: "m:", kind: "root", name: "Fresh", line: 3, endLine: 8, anchor: "fresh")],
                                                           edges: [])], coverage: [:], deploymentHints: [], scannedAt: Date())
        snapshot.systemName = "Fresh"
        try await db.saveArchitecture(snapshot)
        let stored = await db.loadArchitecture()
        check(stored?.systemName == "Fresh" && stored?.view("modules")?.nodes.first?.anchor == "fresh" && stored?.view("modules")?.nodes.first?.endLine == 8,
              "an X-Ray snapshot round-trips through the new schema")
    }

    // MARK: - A file written by release 6.26.x

    do {
        let (root, path) = project("release-626", sql: release626 + usedRows + "PRAGMA journal_mode = WAL; PRAGMA user_version = 1;")
        let before = inode(path)
        check(scalar(path, "PRAGMA user_version") == 1 && names(path, "SELECT name FROM sqlite_master").contains("applied_migrations"),
              "the fixture is what release 6.26 left: version 1, applied_migrations present")
        let db = try await SemanticDatabase.open(workspacePath: root)
        check(db.dbPath == path, "the file is opened in place")
        check(inode(path) == before, "the database file is not replaced")
        check(listing(root.appendingPathComponent(".dde")).filter { $0.contains("corrupt") }.isEmpty, "no backup was needed")
        check(scalar(path, "PRAGMA user_version") == latest, "the file is stamped with the new version")
        check(scalar(path, "SELECT count(*) FROM documents") == 1 && scalar(path, "SELECT count(*) FROM symbols") == 1
              && scalar(path, "SELECT count(*) FROM modules") == 1, "documents, modules and symbols are kept")
        check(blockTables(path).isEmpty, "the block tables of that release are dropped")
        let found = await db.search(query: "zebra").map(\.documentId)
        check(found == ["docs/alpha.md"], "the full-text index is kept")
        let snapshot = await db.loadArchitecture()
        check(snapshot?.systemName == "Shop" && snapshot?.view("modules")?.nodes.first?.anchor == "shop", "the stored X-Ray is kept")
        let review = await db.loadArchitectureReview(key: "abc")
        check(review == "{\"review\":true}", "the cached review is kept")
        let usage = await db.getUsageStats()
        check(usage.totalInputTokens == 77 && usage.totalJobs == 2, "the usage totals are kept")
        check(!names(path, "SELECT name FROM sqlite_master").contains("applied_migrations"), "the never-written applied_migrations table is dropped")
    }

    // MARK: - A file written by release 6.27 (version 2, the block tables filled)

    do {
        let (root, path) = project("release-627", sql: release626 + usedRows + "PRAGMA journal_mode = WAL; PRAGMA user_version = 2;")
        check(scalar(path, "PRAGMA user_version") == 2 && blockTables(path) == ["blocks", "claims", "block_compilation_cache"]
              && scalar(path, "SELECT count(*) FROM blocks") == 1 && scalar(path, "SELECT count(*) FROM claims") == 1
              && scalar(path, "SELECT count(*) FROM block_compilation_cache") == 1,
              "the fixture is a version 2 file with a block, a claim and a compilation cache row")
        let before = inode(path)
        let db = try await SemanticDatabase.open(workspacePath: root)
        check(db.dbPath == path && inode(path) == before, "the file is migrated in place")
        check(scalar(path, "PRAGMA user_version") == latest, "step 3 stamps the file with the latest version")
        check(blockTables(path).isEmpty, "blocks and its two child tables are gone")
        check(scalar(path, "SELECT count(*) FROM sqlite_master WHERE sql LIKE '%REFERENCES blocks%'") == 0,
              "no table is left with a foreign key to the dropped table")
        check(scalar(path, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'idx_blocks%' OR name LIKE 'idx_claims%'") == 0,
              "the indexes of the dropped tables are gone")
        check(scalar(path, "SELECT count(*) FROM pragma_foreign_key_check") == 0, "no row of any table points at a missing row")
        check(scalar(path, "SELECT count(*) FROM documents") == 1 && scalar(path, "SELECT count(*) FROM symbols") == 1
              && scalar(path, "SELECT count(*) FROM modules") == 1 && scalar(path, "SELECT count(*) FROM projects") == 1,
              "documents, modules, symbols and the project are kept")
        let found = await db.search(query: "zebra").map(\.documentId)
        check(found == ["docs/alpha.md"], "the full-text index is kept")
        let snapshot = await db.loadArchitecture()
        check(snapshot?.systemName == "Shop" && snapshot?.view("modules")?.nodes.first?.anchor == "shop", "the stored X-Ray is kept")
        let usage = await db.getUsageStats()
        check(usage.totalInputTokens == 77 && usage.totalJobs == 2, "the usage totals are kept")
        await db.forgetDocuments(["docs/alpha.md"])
        let forgotten = await db.search(query: "zebra")
        check(scalar(path, "SELECT count(*) FROM symbols") == 0 && forgotten.isEmpty, "forgetting a document still clears its symbols and search text")
        // A delete on the app's own connection (foreign keys on) no longer reaches for a table that is gone.
        var deleted = true
        do { try await db.execute("DELETE FROM documents WHERE document_id = ?", params: [.text("docs/alpha.md")]) } catch { deleted = false }
        check(deleted && scalar(path, "SELECT count(*) FROM documents") == 0, "a document can be deleted: its cascades have no block table left to reach")
    }

    // MARK: - A file of an older release (fewer tables and columns, same version stamp)

    do {
        let older = """
        DROP TABLE arch_reviews;
        ALTER TABLE arch_nodes DROP COLUMN anchor;
        ALTER TABLE arch_nodes DROP COLUMN end_line;
        ALTER TABLE arch_nodes DROP COLUMN line;
        ALTER TABLE arch_nodes DROP COLUMN tags_json;
        ALTER TABLE arch_nodes DROP COLUMN component;
        """
        let rows = usedRows
            .replacingOccurrences(of: "INSERT INTO arch_reviews (diff_hash, json, created_at) VALUES ('abc', '{\"review\":true}', 1);\n", with: "")
            .replacingOccurrences(of: "INSERT INTO arch_nodes (view, id, kind, name, path, loc, files, line, end_line, anchor)\n    VALUES ('modules', 'm:', 'root', 'Shop', '', 12, 3, 4, 9, 'shop');",
                                  with: "INSERT INTO arch_nodes (view, id, kind, name, path, loc, files) VALUES ('modules', 'm:', 'root', 'Shop', '', 12, 3);")
        let (root, path) = project("older-vintage", sql: release626 + rows + older + "PRAGMA journal_mode = WAL; PRAGMA user_version = 1;")
        check(!names(path, "SELECT name FROM pragma_table_info('arch_nodes')").contains("anchor"), "the fixture lacks the later columns")
        let db = try await SemanticDatabase.open(workspacePath: root)
        check(["line", "end_line", "anchor", "component", "tags_json"].allSatisfy(names(path, "SELECT name FROM pragma_table_info('arch_nodes')").contains),
              "the missing arch_nodes columns are added")
        check(names(path, "SELECT name FROM sqlite_master").contains("arch_reviews"), "a table the older release lacked is created")
        let hits = await db.search(query: "zebra").count
        let systemName = await db.loadArchitecture()?.systemName
        check(scalar(path, "SELECT count(*) FROM documents") == 1 && hits == 1 && systemName == "Shop", "the older file's rows are kept")
        await db.saveArchitectureReview(key: "k", json: "{}")
        let review = await db.loadArchitectureReview(key: "k")
        check(review == "{}", "the topped-up table is usable")
    }

    // MARK: - A file that predates the docId scheme (no version stamp)

    do {
        let (root, path) = project("unversioned", sql: release626 + usedRows + "PRAGMA user_version = 0;")
        let before = inode(path)
        let db = try await SemanticDatabase.open(workspacePath: root)
        check(db.dbPath == path && inode(path) == before, "the file is migrated in place, not deleted")
        check(scalar(path, "PRAGMA user_version") == latest, "it reaches the latest version")
        check(scalar(path, "SELECT count(*) FROM documents") == 0 && scalar(path, "SELECT count(*) FROM modules") == 0 && scalar(path, "SELECT count(*) FROM fts_documents") == 0,
              "rows keyed by the old document ids are cleared for the next index run")
        let systemName = await db.loadArchitecture()?.systemName
        let review = await db.loadArchitectureReview(key: "abc")
        check(systemName == "Shop" && review != nil, "X-Ray data survives")
        let usage = await db.getUsageStats()
        check(usage.totalInputTokens == 77, "usage totals survive")
    }

    // MARK: - A file from a newer release

    do {
        let (root, path) = project("newer", sql: release626 + usedRows + "PRAGMA journal_mode = DELETE; PRAGMA user_version = 7;")
        let hash = digest(path)
        let files = listing(root.appendingPathComponent(".dde"))
        let db = try await SemanticDatabase.open(workspacePath: root)
        check(db.dbPath == nil, "a newer file is not opened: the session uses an in-memory index")
        check(digest(path) == hash, "not one byte of the newer file changed")
        check(scalar(path, "PRAGMA user_version") == 7 && scalar(path, "SELECT count(*) FROM documents") == 1, "its version and rows are intact")
        try await db.ensureProject(id: "newer", name: "newer", rootPath: root.path)
        await db.indexDocumentFTS(documentId: "n.md", title: "n", content: "quokka")
        let quokka = await db.search(query: "quokka").map(\.documentId)
        let zebra = await db.search(query: "zebra")
        check(quokka == ["n.md"] && zebra.isEmpty, "the in-memory index works and starts empty")
        check(digest(path) == hash && listing(root.appendingPathComponent(".dde")) == files, "writes to the in-memory index never reach the file or its folder")
    }

    // MARK: - A corrupt file

    do {
        let root = sandbox.appendingPathComponent("corrupt", isDirectory: true)
        let dde = root.appendingPathComponent(".dde", isDirectory: true)
        try fm.createDirectory(at: dde, withIntermediateDirectories: true)
        let path = dde.appendingPathComponent("state.db").path
        let garbage = Data("not a database ".utf8) + Data(repeating: 0x5A, count: 6000)
        try garbage.write(to: URL(fileURLWithPath: path))
        try Data("stale log".utf8).write(to: URL(fileURLWithPath: path + "-wal"))

        let db = try await SemanticDatabase.open(workspacePath: root)
        let backups = listing(dde).filter { $0.hasPrefix("state.db.corrupt-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        check(backups.count == 1, "the unreadable file is kept as a dated backup")
        if let backup = backups.first {
            check(fm.contents(atPath: dde.appendingPathComponent(backup).path) == garbage, "the backup is the original, byte for byte")
            check(fm.contents(atPath: dde.appendingPathComponent(backup + "-wal").path) == Data("stale log".utf8), "its write-ahead log went with it")
        }
        check(db.dbPath == path && scalar(path, "PRAGMA user_version") == latest, "a new database is created at the old path")
        await db.indexDocumentFTS(documentId: "c.md", title: "c", content: "okapi")
        let okapi = await db.search(query: "okapi").count
        check(okapi == 1, "the rebuilt database works")
    }

    // MARK: - Off the main thread (AR-37)

    do {
        let (root, path) = project("locked", sql: release626 + usedRows + "PRAGMA journal_mode = WAL; PRAGMA user_version = 2;")
        let db = try await SemanticDatabase.open(workspacePath: root)

        // Another process (the indexer child) holds the write lock for about a second and a half.
        var holder: OpaquePointer?
        check(sqlite3_open(path, &holder) == SQLITE_OK && sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
              "a second connection holds the write lock")
        nonisolated(unsafe) let lockHolder = holder
        let release = Task.detached {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sqlite3_exec(lockHolder, "COMMIT", nil, nil, nil)
            sqlite3_close(lockHolder)
        }

        // A write that has to wait for that lock is started from the main actor ...
        let started = Date()
        let write = Task { () -> Double in
            await db.addUsage(inputTokens: 1, outputTokens: 1, costCents: 1)
            return Date().timeIntervalSince(started)
        }
        // ... and the main actor keeps running meanwhile: its longest pause is far below the lock time.
        var longestPause = 0.0
        var last = Date()
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 100_000_000)
            longestPause = max(longestPause, Date().timeIntervalSince(last) - 0.1)
            last = Date()
        }
        let waited = await write.value
        _ = await release.value
        check(longestPause < 0.3, "the main actor is not held while the database waits for a lock (longest extra pause \(String(format: "%.2f", longestPause)) s)")
        check(waited > 1.0, "the write itself waited for the lock (\(String(format: "%.2f", waited)) s) and then completed")
        let usage = await db.getUsageStats()
        check(usage.totalInputTokens == 78, "the waiting write was applied once the lock was released")
    }
}

/// What the indexer reported, collected from its progress callback (which may run on any thread).
final class ProgressLog: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// The headless `--dde-index` path: StructuralIndexer is Sendable and takes its progress callback at creation (AR-43).
func runIndexer() async throws {
    let root = sandbox.appendingPathComponent("indexed", isDirectory: true)
    try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try "# One\n\nBody of one.\n".write(to: root.appendingPathComponent("docs/one.md"), atomically: true, encoding: .utf8)
    try "# Two\n\nBody of two.\n".write(to: root.appendingPathComponent("docs/two.md"), atomically: true, encoding: .utf8)
    let db = try await SemanticDatabase.open(workspacePath: root)
    try await db.ensureProject(id: "indexed", name: "indexed", rootPath: root.path)

    let first = ProgressLog()
    await StructuralIndexer(db: db, rootURL: root, progress: { first.add($0) }).indexAll()
    let stored = await db.allDocumentMeta()
    check(Set(stored.keys) == ["docs/one.md", "docs/two.md"], "the indexer stores the Markdown files of the folder: \(stored.keys.sorted())")
    check(first.all.first == "Scanning directory tree..." && first.all.last == "Indexing complete",
          "the progress callback given at creation reports from the scan to the end: \(first.all)")

    let second = ProgressLog()
    await StructuralIndexer(db: db, rootURL: root, progress: { second.add($0) }).indexAll()
    check(second.all.last == "Index up to date", "a second run over an unchanged folder says so and writes nothing: \(second.all)")

    await StructuralIndexer(db: db, rootURL: root).indexAll()
    check(await db.allDocumentMeta().count == 2, "an indexer made without a progress callback runs the same")
}

try await run()
try await runIndexer()
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
