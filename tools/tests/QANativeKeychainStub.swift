import Foundation

// Stands in for the browser's password store (Models/BrowserPasswords.swift) so that Models/QANativeFactory.swift compiles on its own in
// tools/tests/qa-native-tests.sh. The checks never read the Keychain: this store knows no password.
struct BrowserPasswordStore {
    static let shared = BrowserPasswordStore()
    func password(host: String, username: String) -> String? { nil }
}
