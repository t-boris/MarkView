import Foundation
import Security

/// One saved login of the browser. `password` is filled only when a login is read for filling.
struct SavedLogin: Identifiable, Equatable {
    var host: String
    var username: String
    var password: String
    var modified: Date
    var id: String { host + "\u{1F}" + username }
}

/// Passwords the browser saved, one login Keychain item per host and user name. Nothing is kept
/// anywhere else; an item is read only when the person asks to fill a page of that exact host.
struct BrowserPasswordStore {
    static let shared = BrowserPasswordStore()
    /// Marks the items as this browser's, so a listing never touches other apps' passwords.
    let domain: String

    init(domain: String = "MarkView browser") { self.domain = domain }

    private func base(host: String? = nil, username: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrSecurityDomain as String: domain]
        if let host { query[kSecAttrServer as String] = host }
        if let username { query[kSecAttrAccount as String] = username }
        return query
    }

    /// Every saved login, newest first, without passwords.
    func all() -> [SavedLogin] {
        var query = base()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            // The Keychain keeps an empty account as no account at all.
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            return SavedLogin(host: host, username: item[kSecAttrAccount as String] as? String ?? "", password: "",
                              modified: item[kSecAttrModificationDate as String] as? Date ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// The logins of `host` with their passwords, most recently saved first.
    func logins(for host: String) -> [SavedLogin] {
        all().filter { $0.host == host }.compactMap { login in
            password(host: host, username: login.username).map { SavedLogin(host: host, username: login.username, password: $0, modified: login.modified) }
        }
    }

    func password(host: String, username: String) -> String? {
        var query = base(host: host, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func has(host: String) -> Bool { all().contains { $0.host == host } }

    @discardableResult
    func save(host: String, username: String, password: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(base(host: host, username: username) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var item = base(host: host, username: username)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MarkView browser: \(host)"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete(host: String, username: String) -> Bool {
        let status = SecItemDelete(base(host: host, username: username) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Which pages may be offered saved passwords, and for which sites the person said "never".
enum PasswordRules {
    private static let neverKey = "browserNeverSavePasswordHosts"

    /// The host a login belongs to: lower case, without a leading `www.`.
    static func host(of url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Passwords are only saved and filled on https pages and on this machine's own servers.
    static func isEligible(scheme: String, host: String) -> Bool {
        let scheme = scheme.lowercased()
        return scheme == "https" || (scheme == "http" && BrowserAddress.isLocal(host))
    }

    static func neverHosts(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: neverKey) ?? [])
    }

    static func neverSave(host: String, _ defaults: UserDefaults = .standard) {
        defaults.set(Array(neverHosts(defaults).union([host])).sorted(), forKey: neverKey)
    }

    static func allowSaving(host: String, _ defaults: UserDefaults = .standard) {
        defaults.set(Array(neverHosts(defaults).subtracting([host])).sorted(), forKey: neverKey)
    }
}

/// What a submitted login form asks the person: save it, or update the saved password.
struct PasswordPrompt: Equatable {
    var host: String
    var username: String
    var password: String
    var isUpdate: Bool
}

/// A login form is on the page and logins are saved for its site.
struct PasswordFillOffer: Equatable {
    var host: String
    var usernames: [String]
}

/// The CSV a password manager exports (Chrome: name,url,username,password,note; Safari and Firefox
/// name the columns alike). Only the url, username and password columns are read.
enum PasswordCSV {
    struct Row: Equatable {
        var host: String
        var username: String
        var password: String
    }

    struct Result: Equatable {
        var rows: [Row] = []
        var skipped = 0
    }

    static func parse(_ text: String) -> Result? {
        let table = records(text)
        guard let header = table.first else { return nil }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let urlColumn = names.firstIndex(where: { $0 == "url" || $0 == "origin" || $0 == "website" }),
              let userColumn = names.firstIndex(where: { $0 == "username" || $0 == "login" || $0 == "user" }),
              let passwordColumn = names.firstIndex(of: "password") else { return nil }
        var result = Result()
        for row in table.dropFirst() where row.contains(where: { !$0.isEmpty }) {
            guard row.count > max(urlColumn, userColumn, passwordColumn) else { result.skipped += 1; continue }
            let address = row[urlColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            let user = row[userColumn]
            let password = row[passwordColumn]
            guard let url = URL(string: address), let scheme = url.scheme, let host = PasswordRules.host(of: url),
                  PasswordRules.isEligible(scheme: scheme, host: host), !password.isEmpty else { result.skipped += 1; continue }
            result.rows.append(Row(host: host, username: user, password: password))
        }
        return result
    }

    /// RFC 4180 records: quoted fields may hold commas, quotes (doubled) and line breaks.
    static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text.unicodeScalars)
        var index = 0
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }
        if characters.first == "\u{FEFF}" { index = 1 }
        while index < characters.count {
            let c = characters[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { field.unicodeScalars.append("\""); index += 1 }
                    else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                endField()
            } else if c == "\r" {
                if index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                endRow()
            } else if c == "\n" {
                endRow()
            } else {
                field.unicodeScalars.append(c)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
