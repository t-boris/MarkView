import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor private final class SavedConnectionTestHost: RemoteAssistantHost {
    var root: URL?
    private(set) var opens = 0
    private var terminals: [TerminalSession] = []
    func openRemoteAITerminal(code: String, provider: CLITool, model: String?, resume: Bool,
                              savedConnectionID: UUID?) async throws -> TerminalSession {
        guard let root else { throw RemoteFailure.invalid("Test project is missing") }
        let connection = try await RemoteTerminalConnection(invitation: RemoteInvitation(code: code), root: root,
            browserWindowID: UUID(), provider: provider, model: model, resume: resume, savedConnectionID: nil)
        let terminal = TerminalSession(directory: root)
        terminal.connection = connection
        terminals.append(terminal)
        opens += 1
        return terminal
    }
}

/// The wrapper supplies a temporary home, unique Keychain services and an owned loopback-only offline relay.
final class SavedRemoteConnectionsHostTests: XCTestCase {
    @MainActor func testSavedConnections() async throws {
        executionTimeAllowance = 120
        let environment = ProcessInfo.processInfo.environment
        let prefix = "MarkView saved connection host tests "
        let relayPrefix = "MarkView saved connection relay host tests "
        let suitePrefix = "com.markview.saved-connection-host-tests."
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost",
              let phase = environment["MARKVIEW_SAVED_TEST_PHASE"], ["write", "read", "cleanup"].contains(phase),
              let home = environment["MARKVIEW_SAVED_TEST_HOME"], environment["CFFIXED_USER_HOME"] == home,
              URL(fileURLWithPath: home).resolvingSymlinksInPath() == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath(),
              let service = environment["MARKVIEW_SAVED_TEST_SERVICE"], service.hasPrefix(prefix),
              let identifier = UUID(uuidString: String(service.dropFirst(prefix.count))),
              let relayService = environment["MARKVIEW_SAVED_TEST_RELAY_SERVICE"], relayService == relayPrefix + identifier.uuidString,
              let suite = environment["MARKVIEW_SAVED_TEST_SUITE"], suite == suitePrefix + identifier.uuidString,
              let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Saved-connection isolation is incomplete")
            return
        }
        let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        let scratch = resolvedHome.deletingLastPathComponent()
        let portText = try String(contentsOf: scratch.appendingPathComponent("relay.port"), encoding: .ascii)
        let port = Int(portText) ?? 0
        let homeValid = resolvedHome.lastPathComponent == "home"
        let rootValid = scratch.lastPathComponent.hasPrefix("mvsaved-test-")
            && scratch.deletingLastPathComponent().path == URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
        let relayValid = (1...65535).contains(port) && environment["MARKVIEW_SAVED_TEST_RELAY"] == "http://127.0.0.1:\(port)"
        guard homeValid, rootValid, relayValid else {
            XCTFail("Saved-connection isolation failed: home=\(homeValid), root=\(rootValid), relay=\(relayValid)")
            return
        }
        let relay = "http://127.0.0.1:\(port)"
        let keychain = RemoteRelayKeychain(service: service, maxBytes: 1_048_576)
        let relayKeychain = RemoteRelayKeychain(service: relayService)
        if phase == "cleanup" {
            try await keychain.save("", account: "saved-connections-v1")
            try await relayKeychain.save("", account: relay)
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
            let left = try await keychain.read(account: "saved-connections-v1")
            let relayLeft = try await relayKeychain.read(account: relay)
            XCTAssertTrue(left.isEmpty && relayLeft.isEmpty)
            XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
            return
        }
        Settings(defaults).set(relay, for: Setting.remoteRelayURL)
        let settings = RemoteRelaySettings(defaults: defaults, keychain: relayKeychain)
        await settings.finishPendingChanges()
        let store = RemoteConnectionsStore(keychain: keychain, relaySettings: settings)
        defer { store.suspend() }
        await store.ready()
        XCTAssertNil(store.storageError)
        if phase == "write" {
            XCTAssertTrue(store.entries.isEmpty)
            try await store.allow(name: "Office Mac", relay: relay)
            try await store.allow(name: "Laptop", relay: relay)
            let project = scratch.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let host = SavedConnectionTestHost(); host.root = project
            let invitation = try RemoteInvitation(relay: URL(string: relay)!, persistent: true)
            try await store.connect(name: "Home Mac", code: invitation.code, provider: CLITool(rawValue: "codex")!,
                                    model: "test-model", resume: true, host: host)
            XCTAssertEqual(store.entries.count, 3)
            XCTAssertEqual(host.opens, 1)
            XCTAssertNotEqual(try RemoteInvitation(code: store.entries[0].code).room,
                              try RemoteInvitation(code: store.entries[1].code).room)
            let saved = try await keychain.read(account: "saved-connections-v1")
            XCTAssertTrue(saved.contains("Office Mac") && saved.contains("Home Mac"))
            try String(ProcessInfo.processInfo.processIdentifier).write(to: scratch.appendingPathComponent("writer.pid"), atomically: true, encoding: .utf8)
            return
        }
        let previousPID = try String(contentsOf: scratch.appendingPathComponent("writer.pid"), encoding: .utf8)
        XCTAssertNotEqual(previousPID, String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(store.entries.count, 3)
        guard store.entries.count == 3, let work = store.entries.first(where: { $0.role == .work }) else { return }
        XCTAssertEqual(store.entries.first?.name, "Office Mac")
        XCTAssertEqual(store.entries.filter { $0.role == .home }.count, 2)
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let host = SavedConnectionTestHost(); host.root = project
        store.connectionStopped(work.id)
        store.attach(host)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(host.opens, 0, "A paused connection must not reopen immediately")
        let reopened = RemoteConnectionsStore(keychain: keychain, relaySettings: settings)
        defer { reopened.suspend() }
        await reopened.ready()
        host.root = URL(fileURLWithPath: "/tmp").appendingPathComponent(scratch.lastPathComponent).appendingPathComponent("project")
        reopened.attach(host)
        for _ in 0..<100 where host.opens == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(host.opens, 1, "A saved project reconnects across temporary-directory aliases")
        let wrong = SavedConnectionTestHost(); wrong.root = scratch.appendingPathComponent("wrong-project")
        reopened.attach(wrong)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(wrong.opens, 0)
        func answer(_ start: (@escaping (Error?) -> Void) -> Void) async -> Error? {
            await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
        }
        let before = store.entries.count
        let allowed = await answer { store.startAllow(name: "Started", relay: relay, finished: $0) }
        XCTAssertNil(allowed)
        XCTAssertEqual(store.entries.count, before + 1)
        XCTAssertEqual(store.entries.last?.name, "Started")
        let invalid = await answer { store.startAllow(name: "No relay", relay: "", finished: $0) }
        XCTAssertNotNil(invalid)
        XCTAssertEqual(store.entries.count, before + 1)
        var answers: [Error?] = []
        let opensBeforeReconnect = host.opens
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for _ in 0..<2 {
                store.startReconnect(work, host: host) { result in
                    answers.append(result)
                    if answers.count == 2 { done.resume() }
                }
            }
        }
        XCTAssertEqual(answers.count, 2)
        if answers.count == 2 {
            XCTAssertTrue(answers[0] is CancellationError)
            XCTAssertNil(answers[1])
        }
        XCTAssertEqual(host.opens, opensBeforeReconnect + 1)
        let saved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            store.startSaving(relaySettings: settings) { done.resume(returning: true) }
        }
        XCTAssertTrue(saved)
        var calledAfterSuspend = false
        store.startSaving(relaySettings: settings) { calledAfterSuspend = true }
        store.suspend()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(calledAfterSuspend, "Suspending cancels an unfinished save callback")
        try await store.disconnect(store.entries[0])
        let pending = try JSONDecoder().decode([SavedRemoteConnection].self, from: Data(try await keychain.read(account: "saved-connections-v1").utf8))
        XCTAssertTrue(pending[0].revoking, "Offline revocation intent survives in Keychain")
        store.suspend()
        let pendingStore = RemoteConnectionsStore(keychain: keychain, relaySettings: settings)
        defer { pendingStore.suspend() }
        await pendingStore.ready()
        XCTAssertEqual(pendingStore.state(pending[0].id).phase, .revoking)
    }
}

/// Cross-process relay credential checks; the wrapper supplies a unique test home, service and defaults suite.
final class RemoteRelaySettingsHostTests: XCTestCase {
    @MainActor func testRelayCredentials() async throws {
        executionTimeAllowance = 120
        let environment = ProcessInfo.processInfo.environment
        let servicePrefix = "MarkView relay credentials tests "
        let suitePrefix = "com.markview.relay-credentials-tests."
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost",
              let phase = environment["MARKVIEW_RELAY_TEST_PHASE"], ["write", "read", "cleanup"].contains(phase),
              let service = environment["MARKVIEW_RELAY_TEST_SERVICE"], service.hasPrefix(servicePrefix),
              let suite = environment["MARKVIEW_RELAY_TEST_SUITE"], suite.hasPrefix(suitePrefix),
              let testHome = environment["MARKVIEW_RELAY_TEST_HOME"],
              environment["CFFIXED_USER_HOME"] == testHome,
              URL(fileURLWithPath: testHome).resolvingSymlinksInPath().path == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path,
              URL(fileURLWithPath: testHome).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path + "/"),
              URL(fileURLWithPath: testHome).resolvingSymlinksInPath().lastPathComponent == "home",
              URL(fileURLWithPath: testHome).resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("mvrelay-test-"),
              let identifier = UUID(uuidString: String(service.dropFirst(servicePrefix.count))),
              suite == suitePrefix + identifier.uuidString,
              let defaults = UserDefaults(suiteName: suite) else {
            let homePath = environment["MARKVIEW_RELAY_TEST_HOME"] ?? ""
            let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath().path
            XCTFail("Relay isolation failed: bundle=\(Bundle.main.bundleIdentifier == "com.markview.tests.apphost"), phase=\(environment["MARKVIEW_RELAY_TEST_PHASE"] != nil), service=\(environment["MARKVIEW_RELAY_TEST_SERVICE"] != nil), suite=\(environment["MARKVIEW_RELAY_TEST_SUITE"] != nil), fixed-home=\(environment["CFFIXED_USER_HOME"] == homePath), ns-home=\(home == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path), tmp-prefix=\(home.hasPrefix(URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path + "/"))")
            return
        }
        let first = "https://relay-a.example.invalid"
        let second = "https://relay-b.example.invalid/prefix"
        let firstKey = "first-test-key-not-a-credential"
        let secondKey = "second-test-key-not-a-credential"
        let replacement = "replacement-test-key-not-a-credential"
        let store = RemoteRelayKeychain(service: service)
        if phase == "cleanup" {
            try await store.save("", account: first)
            try await store.save("", account: second)
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
            let firstAfterCleanup = try await store.read(account: first)
            let secondAfterCleanup = try await store.read(account: second)
            XCTAssertTrue(firstAfterCleanup.isEmpty && secondAfterCleanup.isEmpty, "Test credentials must be removed")
            XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty, "Test preferences must be removed")
            return
        }
        if phase == "write" {
            let canonical = try RemoteRelayKeychain.account(for: " https://RELAY-A.example.invalid:443/ \n")
            XCTAssertEqual(canonical, first, "Equivalent relay URLs must share a credential")
            let path = try RemoteRelayKeychain.account(for: second + "/")
            XCTAssertTrue(path == second && path != first, "Relay prefixes must remain distinct")
            for invalid in ["http://example.com", "https://user:password@example.com", first + "?q=x", first + "#fragment"] {
                XCTAssertThrowsError(try RemoteRelayKeychain.account(for: invalid), "Unsafe relay URL must be rejected")
            }
            defaults.set(first, forKey: "remote.relayURL")
            let settings = RemoteRelaySettings(defaults: defaults, keychain: store)
            await settings.finishPendingChanges()
            XCTAssertTrue(settings.accessKey.isEmpty && settings.storageError == nil)
            settings.setAccessKey("intermediate-test-value")
            settings.setAccessKey(firstKey)
            await settings.finishPendingChanges()
            XCTAssertTrue(settings.storageError == nil && !settings.isSaving)
            settings.relayURL = second
            await settings.finishPendingChanges()
            XCTAssertTrue(settings.accessKey.isEmpty, "A credential must not follow an edit to another relay")
            settings.setAccessKey(secondKey)
            await settings.finishPendingChanges()
            settings.relayURL = first
            await settings.finishPendingChanges()
            XCTAssertEqual(settings.accessKey, firstKey, "Returning to a relay must restore its key")
            let persisted = defaults.persistentDomain(forName: suite) ?? [:]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: persisted), as: UTF8.self)
            XCTAssertFalse(text.contains(firstKey) || text.contains(secondKey), "Preferences must not contain credentials")
            defaults.synchronize()
            let writerPID = URL(fileURLWithPath: testHome).appendingPathComponent("relay-writer.pid")
            try String(ProcessInfo.processInfo.processIdentifier).write(to: writerPID, atomically: true, encoding: .utf8)
            print("Relay credential write phase passed")
            return
        }
        let writerPID = URL(fileURLWithPath: testHome).appendingPathComponent("relay-writer.pid")
        let previousPID = try String(contentsOf: writerPID, encoding: .utf8)
        XCTAssertNotEqual(previousPID, String(ProcessInfo.processInfo.processIdentifier), "Read must use a fresh process")
        let settings = RemoteRelaySettings(defaults: defaults, keychain: store)
        await settings.finishPendingChanges()
        XCTAssertTrue(settings.relayURL == first && settings.accessKey == firstKey, "A fresh process must restore the saved key")
        settings.relayURL = second
        settings.relayURL = first
        await settings.finishPendingChanges()
        XCTAssertEqual(settings.accessKey, firstKey, "A late read from another relay must not replace the current key")
        settings.setAccessKey(replacement)
        settings.relayURL = second
        await settings.finishPendingChanges()
        XCTAssertEqual(settings.accessKey, secondKey, "A pending save must retain its original relay account")
        settings.relayURL = first
        await settings.finishPendingChanges()
        XCTAssertEqual(settings.accessKey, replacement)
        settings.setAccessKey("invalid\nkey")
        await settings.finishPendingChanges()
        XCTAssertNotNil(settings.storageError, "A save failure must be visible")
        let preserved = try await store.read(account: first)
        XCTAssertEqual(preserved, replacement, "A failed update must preserve the previous credential")
        settings.setAccessKey("")
        await settings.finishPendingChanges()
        let reopened = RemoteRelaySettings(defaults: defaults, keychain: store)
        await reopened.finishPendingChanges()
        XCTAssertTrue(reopened.accessKey.isEmpty && reopened.storageError == nil, "Clearing a key must remove it durably")
        reopened.relayURL = second
        await reopened.finishPendingChanges()
        XCTAssertEqual(reopened.accessKey, secondKey, "Clearing one relay must leave another intact")
        print("Relay credential read phase passed")
    }
}
