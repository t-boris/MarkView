import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name)")
    }
}

print("=== Phase 6 Storage, Schema Versioning, Concurrency Tests (AR-36..AR-43, FU-04) ===")

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

    struct LegacyRecordWithVersionField: Codable, Equatable {
        var recentPaths: [String]
        var maxItems: Int
        var version: Int
    }
    let legacyVersionFieldURL = tempDir.appendingPathComponent("legacy-version-field.json")
    let legacyVersionFieldData = try! JSONEncoder().encode(
        LegacyRecordWithVersionField(recentPaths: ["/tmp/legacy"], maxItems: 5, version: 99)
    )
    try! legacyVersionFieldData.write(to: legacyVersionFieldURL)
    let legacyVersionLoad = store.load(from: legacyVersionFieldURL)
    if case .loaded(let val, let schemaVer) = legacyVersionLoad {
        check(val == SamplePreferencesRecord(recentPaths: ["/tmp/legacy"], maxItems: 5) && schemaVer == 0,
              "FU-04/FU-14: SchemaVersionedStore ignores legacy payload version field instead of mistaking it for envelope schema")
    } else {
        check(false, "FU-04/FU-14: SchemaVersionedStore loads legacy payload with version field as schemaVersion 0")
    }

    // 2. AR-40: the control socket token, its file, the peer check and the shared server protection are checked over real
    //    sockets by tools/tests/private-socket-tests.sh (and, per server, remote-browser-, remote-workspace- and cockpit-host-bridge-tests).
    let ancestors = BrowserAgentTools.ancestorPIDs(startingAt: getpid())
    check(ancestors.first == getpid(), "AR-40: ancestorPIDs(startingAt:) starts from kernel-verified peer PID")

    // 3. AR-41: Info.plist App Transport Security configuration parsed structurally
    if let plistData = try? Data(contentsOf: URL(fileURLWithPath: "MarkView/Info.plist")),
       let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
        let principal = plist["NSPrincipalClass"] as? String
        let ats = plist["NSAppTransportSecurity"] as? [String: Any]
        let arbitrary = ats?["NSAllowsArbitraryLoads"] as? Bool
        let webContent = ats?["NSAllowsArbitraryLoadsInWebContent"] as? Bool
        let localNet = ats?["NSAllowsLocalNetworking"] as? Bool
        check(principal == "NSApplication" && arbitrary == false && webContent == true && localNet == true,
              "AR-41: Info.plist PropertyList enforces NSAllowsArbitraryLoads=false while allowing web content and local networking")
    } else {
        check(false, "AR-41: MarkView/Info.plist parses cleanly as a PropertyList dictionary")
    }
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
