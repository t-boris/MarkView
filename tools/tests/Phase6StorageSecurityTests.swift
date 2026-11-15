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

print("=== Phase 6 Storage, Schema Versioning, Control Socket Auth & Concurrency Tests (AR-36..AR-43, FU-03, FU-04) ===")

struct SamplePreferencesRecord: Codable, Equatable {
    var recentPaths: [String]
    var maxItems: Int
}

@MainActor
func runPhase6Tests() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-phase6-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // 1. AR-36, AR-39 & FU-04: SchemaVersionedStore, non-clobbering corrupt backups, and downgrade refusal
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

    // Corrupted file detection & multiple non-clobbering .corrupt-<timestamp>-<suffix> backups
    let updatedRecord = SamplePreferencesRecord(recentPaths: ["/tmp/a", "/tmp/b"], maxItems: 25)
    try! Data("{broken json 1".utf8).write(to: fileURL)
    let corruptResult = store.load(from: fileURL)
    check(corruptResult.isCorrupted, "AR-36: StoreLoadResult distinguishes .corrupted from .missing")
    try! store.save(updatedRecord, to: fileURL, permissions: 0o600)

    try! Data("{broken json 2".utf8).write(to: fileURL)
    try! store.save(updatedRecord, to: fileURL, permissions: 0o600)
    let backups = ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
        .filter { $0.hasPrefix("prefs.json.corrupt-") }
    check(backups.count == 2,
          "FU-04: SchemaVersionedStore preserves non-clobbering timestamped .corrupt backups across repeated failures")

    let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    check(perms == 0o600, "AR-39/FU-04: SchemaVersionedStore writes private files atomically with 0o600 permissions")

    let savedResult = store.load(from: fileURL)
    if case .loaded(let val, let version) = savedResult {
        check(val == updatedRecord && version == 2, "AR-36: SchemaVersionedStore writes and reloads schemaVersion 2 envelope atomically")
    } else {
        check(false, "AR-36: SchemaVersionedStore writes and reloads schemaVersion 2 envelope")
    }

    // Newer-schema downgrade protection (`FU-04`)
    let futureURL = tempDir.appendingPathComponent("future-prefs.json")
    let futurePayload = Data(#"{"schema":99,"updatedAt":"2026-11-15T00:00:00Z","data":{"recentPaths":[],"maxItems":1}}"#.utf8)
    try! futurePayload.write(to: futureURL)
    let newerLoad = store.load(from: futureURL)
    check(newerLoad.isNewerSchema, "FU-04: SchemaVersionedStore returns .newerSchema when on-disk schema exceeds currentSchemaVersion")
    var threwNewer = false
    do {
        try store.save(updatedRecord, to: futureURL)
    } catch let err as SchemaStoreError {
        if case .newerSchemaVersion(_, let found, let supported) = err, found == 99, supported == 2 {
            threwNewer = true
        }
    } catch {}
    let preservedFutureData = try? Data(contentsOf: futureURL)
    check(threwNewer && preservedFutureData == futurePayload,
          "FU-04: SchemaVersionedStore.save throws SchemaStoreError.newerSchemaVersion and leaves newer file untouched")

    // 2. AR-40, DEC-009 & FU-03: Control socket fail-closed constant-time token verification & file/env precedence
    let fakeSock = tempDir.appendingPathComponent("mv-browser-99999.sock").path
    let generatedToken = BrowserAgentTools.writeSocketToken(forSocket: fakeSock)
    check(generatedToken != nil && generatedToken?.count == 64, "AR-40: writeSocketToken generates 256-bit hex token")
    let tokenPath = BrowserAgentTools.tokenPath(forSocket: fakeSock)
    let tokenPerms = (try? FileManager.default.attributesOfItem(atPath: tokenPath)[.posixPermissions] as? NSNumber)?.intValue ?? 0
    check(tokenPerms == 0o600, "AR-40: Control socket token file is created with mode 0600")
    let readBack = BrowserAgentTools.readSocketToken(forSocket: fakeSock)
    check(readBack == generatedToken, "AR-40: readSocketToken reads back 0600 token file owned by current user")

    setenv(BrowserAgentTools.controlTokenEnvKey, "env-fallback-token", 1)
    defer { unsetenv(BrowserAgentTools.controlTokenEnvKey) }
    check(BrowserAgentTools.readSocketToken(forSocket: fakeSock) == generatedToken,
          "FU-03: readSocketToken prefers on-disk 0600 token file over MARKVIEW_CONTROL_TOKEN env var")

    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenPath)
    check(BrowserAgentTools.readSocketToken(forSocket: fakeSock) == nil,
          "FU-03: readSocketToken rejects token file with group/world permissions even if env var is set")
    try? FileManager.default.removeItem(atPath: tokenPath)
    check(BrowserAgentTools.readSocketToken(forSocket: fakeSock) == "env-fallback-token",
          "FU-03: readSocketToken falls back to MARKVIEW_CONTROL_TOKEN only when token file is absent")

    check(!BrowserControlServer.verifyToken(nil, expected: nil), "FU-03: verifyToken fails closed when expected token is nil")
    check(!BrowserControlServer.verifyToken("", expected: ""), "FU-03: verifyToken fails closed when expected token is empty")
    check(!BrowserControlServer.verifyToken("anything", expected: ""), "FU-03: verifyToken rejects arbitrary token against empty expected")
    check(!BrowserControlServer.verifyToken(nil, expected: generatedToken), "AR-40: verifyToken rejects missing token when instance token is active")
    check(!BrowserControlServer.verifyToken("wrong", expected: generatedToken), "AR-40: verifyToken rejects mismatched token")
    check(BrowserControlServer.verifyToken(generatedToken, expected: generatedToken), "AR-40: verifyToken accepts matching per-instance token")
    check(BrowserAgentTools.verifyToken(generatedToken, expected: generatedToken) && !BrowserAgentTools.verifyToken(nil, expected: nil),
          "FU-03: BrowserAgentTools.verifyToken shares fail-closed constant-time semantics")

    let ancestors = BrowserAgentTools.ancestorPIDs(startingAt: getpid())
    check(ancestors.first == getpid(), "AR-40: ancestorPIDs(startingAt:) starts from kernel-verified peer PID")

    // 3. AR-41..AR-43 & DEC-010: Info.plist ATS, cached hasMarkdownFiles, @MainActor TabStripScroller, and SWIFT_STRICT_CONCURRENCY
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
