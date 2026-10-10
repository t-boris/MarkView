import Foundation

/// A place the project runs: a server reached over SSH, this Mac, or a cloud service reached by its CLI.
/// Stored in `.dde/deployments.json`; it holds no passwords or keys (SSH uses the person's agent and
/// ~/.ssh/config, a cloud CLI its own login). Foundation only, checked in `tools/tests/deployment-models-tests.sh`.
struct DeploymentEnvironment: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case ssh, local, cloud }

    var id: String
    var name: String
    var kind: Kind
    /// SSH: the host name or address (or a Host alias of ~/.ssh/config).
    var host = ""
    var user = ""
    var port = 22
    /// SSH: a key file to use (path only; the key stays where it is).
    var identityFile = ""
    /// Cloud: vercel, fly, heroku, aws, gcloud, azure, kubernetes…
    var provider = ""
    /// Cloud: read-only commands that show the state (run on this Mac with the provider's CLI).
    var cloudCommands: [CloudCommand] = []
    var checks: [DeploymentCheck] = []
    var logSources: [LogSource] = []
    var notes = ""
    /// Where in the project this was found ("`.github/workflows/deploy.yml`: host PROD_HOST").
    var evidence: [String] = []

    /// `user@host`, as ssh takes it.
    var destination: String { user.isEmpty ? host : "\(user)@\(host)" }

    /// What is wrong with this definition, if anything (empty = fine). Host and user are checked so a
    /// value can never become an option of ssh (`-oProxyCommand=…`).
    var problems: [String] {
        var found: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { found.append("The environment needs a name.") }
        if kind == .ssh {
            if host.isEmpty { found.append("An SSH environment needs a host.") }
            if !host.isEmpty && !Self.isSafeToken(host) { found.append("The host holds characters that are not allowed.") }
            if !user.isEmpty && !Self.isSafeToken(user) { found.append("The user holds characters that are not allowed.") }
            if !(1...65535).contains(port) { found.append("The port must be between 1 and 65535.") }
            if !identityFile.isEmpty && (identityFile.hasPrefix("-") || identityFile.contains("\n")) { found.append("The key file path is not valid.") }
        }
        if kind == .cloud && provider.isEmpty { found.append("A cloud environment needs a provider.") }
        return found
    }

    /// Letters, digits and `. _ - : @ %`, not starting with `-` (IPv6 and aliases fit).
    static func isSafeToken(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-") else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-:@%".unicodeScalars.contains($0) }
    }

    /// A file-name friendly id from a name.
    static func slug(_ name: String, existing: Set<String> = []) -> String {
        var base = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "environment" }
        var candidate = base, n = 2
        while existing.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
        return candidate
    }
}

struct CloudCommand: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var command: String
}

struct DeploymentCheck: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case systemd, docker, port, http, postgres, redis, mysql, command }

    var id: String
    var title: String
    var kind: Kind
    /// systemd: the unit; docker: the container; port: `host:port` (host defaults to localhost); http: the URL;
    /// postgres / redis / mysql: optional `-h host`-style arguments; command: a read-only command.
    var target: String = ""
    /// http: the status codes that count (`200`, `2xx`; empty = any 2xx or 3xx); command: text the output must hold.
    var expect = ""
}

struct LogSource: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    /// A command that prints the log (it must be read-only: `journalctl -u app -n 200 --no-pager`).
    var command: String
}

struct DeploymentsFile: Codable, Equatable {
    var version = 1
    var environments: [DeploymentEnvironment] = []

    static func decode(_ data: Data) -> DeploymentsFile? { try? JSONDecoder().decode(DeploymentsFile.self, from: data) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
