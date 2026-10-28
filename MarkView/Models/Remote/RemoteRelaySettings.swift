import Foundation
import Combine
import Security

/// Keeps the relay's registration credential in the login Keychain, never in preferences.
/// Serial Keychain calls run off the main actor and update an existing item in place.
actor RemoteRelayKeychain {
    private let service: String
    private let maxBytes: Int

    init(service: String = "MarkView remote relay access key", maxBytes: Int = 1024) {
        self.service = service; self.maxBytes = maxBytes
    }

    static func account(for relay: String) throws -> String {
        guard let url = URL(string: relay.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw RemoteFailure.invalid("Enter an HTTPS relay URL.")
        }
        try RemoteInvitation.validateRelay(url)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RemoteFailure.invalid("Enter an HTTPS relay URL.")
        }
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let account = parts.url?.absoluteString else { throw RemoteFailure.invalid("Enter an HTTPS relay URL.") }
        return account
    }

    func read(account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        try check(status)
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw RemoteFailure.invalid("The saved relay access key could not be read. Enter it again.")
        }
        return value
    }

    func save(_ value: String, account: String) throws {
        guard value.utf8.count <= maxBytes, !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
            throw RemoteFailure.invalid("The relay access key is invalid. Paste the key without a line break.")
        }
        let query = query(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let changes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "MarkView relay access key"
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, changes as CFDictionary) }
        }
        try check(status)
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
            throw RemoteFailure.invalid("The relay access key could not be saved or loaded from Keychain. \(reason)")
        }
    }
}

/// App lifetime ownership lets a pending save finish when its settings sheet closes.
@MainActor
final class RemoteRelaySettings: ObservableObject {
    private static var existing: RemoteRelaySettings?
    static var shared: RemoteRelaySettings {
        if let existing { return existing }
        let settings = RemoteRelaySettings()
        existing = settings
        return settings
    }
    static func finishBeforeQuit() async { await existing?.finishPendingChanges() }

    @Published var relayURL: String {
        didSet {
            defaults.set(relayURL, forKey: "remote.relayURL")
            selectRelay()
        }
    }
    @Published private(set) var accessKey = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var storageError: String?
    private let defaults: UserDefaults
    private let keychain: RemoteRelayKeychain
    private var account: String?
    private var selection = 0
    private var revision = 0
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, keychain: RemoteRelayKeychain = RemoteRelayKeychain()) {
        self.defaults = defaults; self.keychain = keychain
        relayURL = defaults.string(forKey: "remote.relayURL") ?? ""
        selectRelay()
    }

    var storageStatus: String? {
        if storageError != nil { return nil }
        if isLoading { return "Loading saved access key…" }
        if isSaving { return "Saving access key…" }
        if account == nil { return "Enter the relay URL before adding its access key." }
        return accessKey.isEmpty ? nil : "Access key saved on this Mac."
    }

    func setAccessKey(_ value: String) {
        guard !isLoading, let account else { return }
        accessKey = value; storageError = nil; isSaving = true
        revision += 1
        let revision = revision, previous = saving
        saving = Task { [self] in
            await previous?.value
            var failure: String?
            do { try await keychain.save(value, account: account) }
            catch { failure = error.localizedDescription }
            guard self.account == account, self.revision == revision else { return }
            isSaving = false; storageError = failure
        }
    }

    func finishPendingChanges() async {
        await loading?.value
        while let saving {
            let revision = revision
            await saving.value
            if self.revision == revision { return }
        }
    }

    private func selectRelay() {
        let account = try? RemoteRelayKeychain.account(for: relayURL)
        guard account != self.account else { return }
        self.account = account; selection += 1
        loading?.cancel(); accessKey = ""; storageError = nil; isSaving = false
        guard let account else { isLoading = false; return }
        isLoading = true
        let selection = selection, previous = saving
        loading = Task { [self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let value = try await keychain.read(account: account)
                guard self.selection == selection, !Task.isCancelled else { return }
                accessKey = value; isLoading = false
            } catch {
                guard self.selection == selection, !Task.isCancelled else { return }
                isLoading = false; storageError = error.localizedDescription
            }
        }
    }
}
