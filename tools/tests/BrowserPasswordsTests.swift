import Foundation

// Stand-in for the app's BrowserAddress (BrowserSession.swift pulls in WebKit).
enum BrowserAddress {
    static func isLocal(_ host: String) -> Bool { ["localhost", "127.0.0.1"].contains(host) || host.hasSuffix(".localhost") }
}

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// Hosts and eligibility.
check("host drops www and case", PasswordRules.host(of: URL(string: "https://WWW.Example.com/login")) == "example.com")
check("host of nothing", PasswordRules.host(of: nil) == nil)
check("https eligible", PasswordRules.isEligible(scheme: "https", host: "example.com"))
check("http remote not eligible", !PasswordRules.isEligible(scheme: "http", host: "example.com"))
check("http localhost eligible", PasswordRules.isEligible(scheme: "http", host: "localhost"))
check("file not eligible", !PasswordRules.isEligible(scheme: "file", host: "localhost"))

// Never-save list, in its own defaults suite.
let suite = UserDefaults(suiteName: "mv-password-tests-\(UUID().uuidString)")!
check("never list starts empty", PasswordRules.neverHosts(suite).isEmpty)
PasswordRules.neverSave(host: "bank.example", suite)
check("never list adds", PasswordRules.neverHosts(suite) == ["bank.example"])
PasswordRules.allowSaving(host: "bank.example", suite)
check("never list removes", PasswordRules.neverHosts(suite).isEmpty)

// Chrome CSV.
let chrome = "\u{FEFF}name,url,username,password,note\r\n"
    + "example,https://www.example.com/login,ann@example.com,\"p,\"\"w\"\"d\",\"a note\nover two lines\"\r\n"
    + "plain,http://insecure.example/,bob,secret,\r\n"
    + "dev,http://localhost:3000/,carol,devpass,\r\n"
    + "empty,https://empty.example/,dave,,\r\n"
    + "\r\n"
let parsed = PasswordCSV.parse(chrome)
check("csv parsed", parsed != nil)
check("csv keeps https and local rows", parsed?.rows.map(\.host) == ["example.com", "localhost"])
check("csv quoted comma and quotes", parsed?.rows.first?.password == "p,\"w\"d")
check("csv skips insecure and empty", parsed?.skipped == 2)
check("csv multi-line note does not shift rows", parsed?.rows.last?.username == "carol")
check("csv without columns is rejected", PasswordCSV.parse("a,b\n1,2\n") == nil)
check("csv safari-style columns", PasswordCSV.parse("Title,URL,Username,Password,Notes,OTPAuth\nx,https://a.example,u,p,,\n")?.rows.count == 1)
check("csv records without trailing newline", PasswordCSV.records("a,b\nc,d") == [["a", "b"], ["c", "d"]])

// Download names.
let folder = URL(fileURLWithPath: "/tmp/dl")
var taken: Set<String> = ["/tmp/dl/report.pdf", "/tmp/dl/report 2.pdf"]
check("free name", BrowserDownloads.freeURL(in: folder, suggestedName: "new.zip") { taken.contains($0.path) }.lastPathComponent == "new.zip")
check("numbered name", BrowserDownloads.freeURL(in: folder, suggestedName: "report.pdf") { taken.contains($0.path) }.lastPathComponent == "report 3.pdf")
check("no extension", BrowserDownloads.freeURL(in: folder, suggestedName: "LICENSE") { taken.contains($0.path) }.lastPathComponent == "LICENSE")
check("server cannot pick a folder", BrowserDownloads.freeURL(in: folder, suggestedName: "../../etc/passwd") { _ in false }.path == "/tmp/dl/passwd")
check("empty name", BrowserDownloads.freeURL(in: folder, suggestedName: "") { _ in false }.lastPathComponent == "download")
taken = []

// The Keychain store, under a throwaway domain.
let store = BrowserPasswordStore(domain: "MarkView browser tests \(UUID().uuidString)")
check("store starts empty", store.all().isEmpty)
check("store saves", store.save(host: "a.example", username: "ann", password: "one"))
check("store saves a second user", store.save(host: "a.example", username: "bob", password: "two"))
check("store saves another site", store.save(host: "b.example", username: "ann", password: "three"))
check("store lists all", store.all().count == 3)
check("store lists without passwords", store.all().allSatisfy { $0.password.isEmpty })
check("store reads by site", Set(store.logins(for: "a.example").map(\.username)) == ["ann", "bob"])
check("store never mixes sites", store.logins(for: "b.example").map(\.password) == ["three"])
check("store has host", store.has(host: "a.example") && !store.has(host: "c.example"))
check("store keeps a login without a user name", store.save(host: "c.example", username: "", password: "nameless")
      && store.logins(for: "c.example").map(\.password) == ["nameless"] && store.all().contains { $0.host == "c.example" && $0.username.isEmpty })
check("store deletes it", store.delete(host: "c.example", username: "") && !store.has(host: "c.example"))
check("store updates", store.save(host: "a.example", username: "ann", password: "uno") && store.password(host: "a.example", username: "ann") == "uno")
check("update keeps the count", store.all().count == 3)
check("store deletes", store.delete(host: "a.example", username: "ann") && store.password(host: "a.example", username: "ann") == nil)
check("store delete of nothing is fine", store.delete(host: "zzz.example", username: "x"))
for login in store.all() { store.delete(host: login.host, username: login.username) }
check("store cleaned up", store.all().isEmpty)

exit(failures == 0 ? 0 : 1)
