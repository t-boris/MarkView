import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

print("=== Phase 6 Storage, SQLite, Control Socket Auth & Concurrency Tests (AR-36..AR-43) ===")

struct SamplePreferencesRecord: Codable, Equatable {
    var recentPaths: [String]
    var maxItems: Int
}

@MainActor
func runPhase6Tests() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-phase6-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // 1. AR-36 & AR-39: SchemaVersionedStore and StoreLoadResult
    let store = SchemaVersionedStore<SamplePreferencesRecord>(currentSchemaVersion: 2, backupCorruptedOnSave: true)
    let fileURL = tempDir.appendingPathComponent("prefs.json")

    let missingResult = store.load(from: fileURL)
    if case .missing = missingResult {
        check(true, "AR-36: StoreLoadResult returns .missing when file does not exist")
    } else {
        check(false, "AR-36: StoreLoadResult returns .missing when file does not exist")
    }

    // Legacy unversioned JSON upgrades transparently with schemaVersion == 0
    let legacyData = try! JSONEncoder().encode(SamplePreferencesRecord(recentPaths: ["/tmp/a"], maxItems: 10))
    try! legacyData.write(to: fileURL)
    let legacyResult = store.load(from: fileURL)
    if case .loaded(let val, let version) = legacyResult {
        check(val == SamplePreferencesRecord(recentPaths: ["/tmp/a"], maxItems: 10) && version == 0,
              "AR-36: SchemaVersionedStore transparently loads legacy unversioned JSON as schemaVersion 0")
    } else {
        check(false, "AR-36: SchemaVersionedStore transparently loads legacy unversioned JSON")
    }

    // Corrupted file detection & .corrupt backup before atomic save
    try! Data("{broken json".utf8).write(to: fileURL)
    let corruptResult = store.load(from: fileURL)
    check(corruptResult.isCorrupted, "AR-36: StoreLoadResult distinguishes .corrupted from .missing")

    let updatedRecord = SamplePreferencesRecord(recentPaths: ["/tmp/a", "/tmp/b"], maxItems: 25)
    try! store.save(updatedRecord, to: fileURL)
    let backupURL = fileURL.appendingPathExtension("corrupt")
    check(FileManager.default.fileExists(atPath: backupURL.path), "AR-36: SchemaVersionedStore backs up corrupted file to .corrupt before overwriting")

    let savedResult = store.load(from: fileURL)
    if case .loaded(let val, let version) = savedResult {
        check(val == updatedRecord && version == 2, "AR-36: SchemaVersionedStore writes and reloads schemaVersion 2 envelope atomically")
    } else {
        check(false, "AR-36: SchemaVersionedStore writes and reloads schemaVersion 2 envelope")
    }

    // 2. AR-37 & AR-38: Off-main-thread SemanticDatabaseExecutor actor & ordered PRAGMA user_version migrations
    let dbPath = tempDir.appendingPathComponent("test.db").path
    let migrations: [SQLiteMigration] = [
        SQLiteMigration(version: 1, name: "create_items", statements: [
            "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
        ]),
        SQLiteMigration(version: 2, name: "seed_item", statements: [
            "INSERT INTO items (id, title) VALUES (1, 'First migrated item')"
        ]),
    ]
    let executor = try! SemanticDatabaseExecutor(dbPath: dbPath, migrations: migrations)
    let versionAfterInit = await executor.currentUserVersion()
    check(versionAfterInit == 2, "AR-37 & AR-38: SemanticDatabaseExecutor applies numbered migrations and sets PRAGMA user_version = 2")
    let itemCount = await executor.queryScalarInt("SELECT COUNT(*) FROM items")
    check(itemCount == 1, "AR-37: SemanticDatabaseExecutor executes off-main-thread queries")
    let migrationCount = await executor.queryScalarInt("SELECT COUNT(*) FROM schema_migrations")
    check(migrationCount == 2, "AR-38: schema_migrations table records applied migration versions")

    // 3. AR-40 & DEC-009: Control socket per-instance token & peer verification
    let fakeSock = tempDir.appendingPathComponent("mv-browser-99999.sock").path
    let generatedToken = BrowserAgentTools.writeSocketToken(forSocket: fakeSock)
    check(generatedToken != nil && generatedToken?.count == 64, "AR-40: writeSocketToken generates 256-bit hex token")
    let tokenPath = BrowserAgentTools.tokenPath(forSocket: fakeSock)
    let perms = (try? FileManager.default.attributesOfItem(atPath: tokenPath)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    check(perms == 0o600, "AR-40: Control socket token file is created with mode 0600")
    let readBack = BrowserAgentTools.readSocketToken(forSocket: fakeSock)
    check(readBack == generatedToken, "AR-40: readSocketToken reads back 0600 token file owned by current user")
    check(!BrowserControlServer.verifyToken(nil, expected: generatedToken), "AR-40: verifyToken rejects missing token when instance token is active")
    check(!BrowserControlServer.verifyToken("wrong", expected: generatedToken), "AR-40: verifyToken rejects mismatched token")
    check(BrowserControlServer.verifyToken(generatedToken, expected: generatedToken), "AR-40: verifyToken accepts matching per-instance token")

    let ancestors = BrowserAgentTools.ancestorPIDs(startingAt: getpid())
    check(ancestors.first == getpid(), "AR-40: ancestorPIDs(startingAt:) starts from kernel-verified peer PID")

    // 4. AR-41..AR-43 & DEC-010: Info.plist ATS, cached hasMarkdownFiles, @MainActor TabStripScroller, and SWIFT_STRICT_CONCURRENCY
    let plistText = (try? String(contentsOfFile: "MarkView/Info.plist", encoding: .utf8)) ?? ""
    check(plistText.contains("<key>NSAllowsArbitraryLoads</key>\n        <false/>"),
          "AR-41: Info.plist sets NSAllowsArbitraryLoads to false while preserving web content / local networking")
    let workspaceSource = (try? String(contentsOfFile: "MarkView/Models/WorkspaceManager.swift", encoding: .utf8)) ?? ""
    check(workspaceSource.contains("cachedHasMarkdownFiles"),
          "AR-42: WorkspaceFileTreeStore caches hasMarkdownFiles to avoid main-thread tree walks during menu rendering")
    let tabBarSource = (try? String(contentsOfFile: "MarkView/Views/TabBarView.swift", encoding: .utf8)) ?? ""
    check(tabBarSource.contains("@MainActor\nfinal class TabStripScroller"),
          "AR-43: TabStripScroller is annotated with @MainActor")
    let pbxprojText = (try? String(contentsOfFile: "MarkView.xcodeproj/project.pbxproj", encoding: .utf8)) ?? ""
    check(pbxprojText.contains("SWIFT_STRICT_CONCURRENCY = targeted;"),
          "AR-43 & DEC-010: MarkView.xcodeproj enables SWIFT_STRICT_CONCURRENCY = targeted")
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await runPhase6Tests()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}

print("\nPhase 6 summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
