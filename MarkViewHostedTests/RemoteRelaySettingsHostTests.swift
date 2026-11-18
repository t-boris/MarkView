import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

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
