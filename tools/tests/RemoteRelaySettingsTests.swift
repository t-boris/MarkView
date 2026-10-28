import Foundation

@main
enum RemoteRelaySettingsTests {
    static let first = "https://relay-a.example.invalid"
    static let second = "https://relay-b.example.invalid/prefix"
    static let firstKey = "first-test-key-not-a-credential"
    static let secondKey = "second-test-key-not-a-credential"
    static let replacement = "replacement-test-key-not-a-credential"

    @MainActor static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, arguments[2].hasPrefix("MarkView relay credentials tests "),
                  arguments[3].hasPrefix("com.markview.relay-credentials-tests."),
                  let defaults = UserDefaults(suiteName: arguments[3]) else { fatalError("Use an isolated test service and defaults suite.") }
            let store = RemoteRelayKeychain(service: arguments[2])
            if arguments[1] == "cleanup" {
                try await store.save("", account: first); try await store.save("", account: second)
                defaults.removePersistentDomain(forName: arguments[3])
                return
            }
            if arguments[1] == "write" {
                let canonical = try RemoteRelayKeychain.account(for: " https://RELAY-A.example.invalid:443/ \n")
                precondition(canonical == first, "Equivalent relay URLs must share a credential.")
                let path = try RemoteRelayKeychain.account(for: second + "/")
                precondition(path == second && path != first, "Relay prefixes must remain distinct.")
                for invalid in ["http://example.com", "https://user:password@example.com", first + "?q=x", first + "#fragment"] {
                    do { _ = try RemoteRelayKeychain.account(for: invalid); preconditionFailure("Unsafe relay URL accepted.") } catch {}
                }
                defaults.set(first, forKey: "remote.relayURL")
                let settings = RemoteRelaySettings(defaults: defaults, keychain: store)
                await settings.finishPendingChanges()
                precondition(settings.accessKey.isEmpty && settings.storageError == nil)
                settings.setAccessKey("intermediate-test-value")
                settings.setAccessKey(firstKey)
                await settings.finishPendingChanges()
                precondition(settings.storageError == nil && !settings.isSaving)
                settings.relayURL = second
                await settings.finishPendingChanges()
                precondition(settings.accessKey.isEmpty, "A credential must never follow an edit to a different relay.")
                settings.setAccessKey(secondKey)
                await settings.finishPendingChanges()
                settings.relayURL = first
                await settings.finishPendingChanges()
                precondition(settings.accessKey == firstKey, "Returning to a relay must restore its key.")
                let persisted = defaults.persistentDomain(forName: arguments[3]) ?? [:]
                let data = try JSONSerialization.data(withJSONObject: persisted)
                let text = String(decoding: data, as: UTF8.self)
                precondition(!text.contains(firstKey) && !text.contains(secondKey), "Preferences must not contain credentials.")
                defaults.synchronize()
                print("Relay credentials: ordered writes, URL normalization, separate relays and no plaintext preferences passed.")
            } else if arguments[1] == "read" {
                let settings = RemoteRelaySettings(defaults: defaults, keychain: store)
                await settings.finishPendingChanges()
                precondition(settings.relayURL == first && settings.accessKey == firstKey, "A fresh process must restore the saved key.")
                settings.relayURL = second
                settings.relayURL = first
                await settings.finishPendingChanges()
                precondition(settings.accessKey == firstKey, "A late read from a previous relay must not overwrite the current field.")
                settings.setAccessKey(replacement)
                settings.relayURL = second
                await settings.finishPendingChanges()
                precondition(settings.accessKey == secondKey, "A pending save must retain its original relay account.")
                settings.relayURL = first
                await settings.finishPendingChanges()
                precondition(settings.accessKey == replacement)
                settings.setAccessKey("invalid\nkey")
                await settings.finishPendingChanges()
                precondition(settings.storageError != nil, "A save failure must be visible.")
                let preserved = try await store.read(account: first)
                precondition(preserved == replacement, "A failed update must preserve the previous credential.")
                settings.setAccessKey("")
                await settings.finishPendingChanges()
                let reopened = RemoteRelaySettings(defaults: defaults, keychain: store)
                await reopened.finishPendingChanges()
                precondition(reopened.accessKey.isEmpty && reopened.storageError == nil, "Clearing a key must remove it durably.")
                reopened.relayURL = second
                await reopened.finishPendingChanges()
                precondition(reopened.accessKey == secondKey, "Clearing one relay must leave another intact.")
                print("Relay credentials: cross-process restore, switching races, updates, visible failure and explicit removal passed.")
            } else { fatalError("Unknown test phase.") }
        } catch {
            print("Relay credential check failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
