import CryptoKit
import Foundation

/// A service URL the development server reads from its environment (REQ-007, DEC-006). While simulated, MarkView starts the
/// server with the variable pointing at its gateway on 127.0.0.1, and the server's requests are answered by the simulation.
struct StudioServerConnection: Codable, Equatable, Sendable, Identifiable {
    enum Mode: String, Codable, Sendable { case simulated, real }

    var variable: String
    /// The service's origin as the project names it (scheme, host and port), used in contract keys and shown to the person.
    var origin: String
    /// The path of the variable's value (no trailing slash), kept after the gateway's address so relative URLs still work.
    var basePath: String
    var mode: Mode
    /// Where the variable was found: an env file, or a source file and line.
    var foundIn: String

    var id: String { variable }
}

/// Lenient, because one damaged entry must not make environment.json unreadable (it would then be replaced): an unknown
/// mode is simulated, a missing field is empty, and an entry without a variable matches no connection and is ignored.
extension StudioServerConnection {
    private enum Keys: String, CodingKey { case variable, origin, basePath, mode, foundIn }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String { (try? container?.decodeIfPresent(String.self, forKey: key)) ?? "" }
        variable = text(.variable)
        origin = text(.origin)
        basePath = text(.basePath)
        mode = Mode(rawValue: text(.mode)) ?? .simulated
        foundIn = text(.foundIn)
    }
}

/// What the project's environment and sources say about the services its server talks to.
struct StudioConnectionDiscovery: Sendable {
    struct Note: Equatable, Sendable {
        var variable: String
        var reason: String
    }

    var connections: [StudioServerConnection] = []
    /// Secret-named variables the project reads, with the test value each gets unless the person keeps it real.
    var testValues: [String: String] = [:]
    /// URL variables that are left as they are, and why.
    var notRedirected: [Note] = []
    var disclosures: [String] = []
    /// SHA-256 (hex) of secret values found in env files → the variable's name. Kept in memory only, to redact those values
    /// from requests before they are logged or shown to the assistant.
    var secretHashes: [String: String] = [:]

    var secrets: [String] { testValues.keys.sorted() }
}

/// Finds the service URLs and secrets of a web app (REQ-007): env files from the app folder up to the project root, the
/// app's sources and the sources of the workspace packages it depends on. Values of secrets are read only to recognise
/// their shape and hash; they are never stored or returned.
enum StudioConnections {
    static let envFiles = [".env.development.local", ".env.local", ".env.development", ".env"]
    static let exampleFiles = [".env.example", ".env.sample", ".env.template", ".env.defaults"]
    static let skippedFolders: Set<String> = ["node_modules", ".git", ".next", ".nuxt", ".svelte-kit", ".turbo", ".output", ".vite",
                                              "dist", "build", "out", "coverage", "vendor", ".markview",
                                              // Test code does not run in the development server.
                                              "e2e", "__tests__", "__mocks__", "cypress", "playwright", "test", "tests"]
    static let sourceExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts", "vue", "svelte", "astro", "py",
                                                "rb", "go", "php", "java", "kt", "cs", "rs", "ex", "exs"]
    static let maxFiles = 4_000
    static let maxFileSize = 512 * 1024

    // MARK: Names

    /// A variable that holds a service's address.
    static func isURLVariable(_ name: String) -> Bool {
        ["_URL", "_URI", "_ENDPOINT", "_ORIGIN"].contains { name.hasSuffix($0) }
    }

    /// Addresses of the application itself, which must stay real.
    static func isSelfVariable(_ name: String) -> Bool {
        let exact: Set<String> = ["NEXTAUTH_URL", "AUTH_URL", "PUBLIC_URL", "BASE_URL", "ORIGIN", "APP_URL", "VERCEL_URL", "SITE_URL",
                                  "NEXTAUTH_URL_INTERNAL"]
        return exact.contains(name) || name.hasSuffix("_SITE_URL") || name.hasSuffix("_APP_URL") || name.hasSuffix("_PUBLIC_URL")
            || name.hasSuffix("_VERCEL_URL")
    }

    /// A credential the server sends to a service. Database connection strings are not: databases are outside the simulation.
    static func isSecretVariable(_ name: String) -> Bool {
        guard !isURLVariable(name), !["DSN", "DATABASE", "CONNECTION_STRING"].contains(where: { name.contains($0) }) else { return false }
        return name.range(of: #"(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL|ACCESS_?KEY|SESSION_?KEY|ANON_?KEY|SERVICE_?ROLE_?KEY|PUBLISHABLE_?KEY|CLIENT_?SECRET|SIGNING_?KEY|WEBHOOK_?SECRET)"#,
                          options: .regularExpression) != nil
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil
    }

    // MARK: Values

    /// `KEY=value` lines of a dotenv file: `export` prefixes, quotes and trailing comments handled; invalid names skipped.
    static func parseEnvFile(_ text: String) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isValidName(name) else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let rest = value.dropFirst()
                value = rest.firstIndex(of: quote).map { String(rest[..<$0]) } ?? String(rest)
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            result.append((name, value))
        }
        return result
    }

    /// The origin and path of an HTTP address, without credentials, query or fragment; nil for other schemes.
    static func split(_ value: String) -> (origin: String, basePath: String)? {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return ("\(scheme)://\(shownHost)\(port)", path)
    }

    /// The value a secret gets while the server is simulated: shaped like the real one where a library checks the shape.
    /// A JWT stays a signed JWT (BUG-073): libraries reject tokens with an empty signature, and an auth middleware that
    /// rejects its key fails closed and sends every page to the login page.
    static func testValue(for name: String, real: String?) -> String {
        let real = real ?? ""
        let plain = "markview-test-" + name.lowercased().replacingOccurrences(of: "_", with: "-")
        if real.hasPrefix("eyJ"), real.split(separator: ".", omittingEmptySubsequences: false).count == 3 {
            // Only the role claim is copied (anon and service-role keys behave differently); a project ref or any other
            // claim of the real key never reaches the test value.
            return StudioTestJWT.make(["iss": .string("markview-test"), "role": .string(StudioTestJWT.role(of: real) ?? "anon"),
                                       "iat": .number(StudioTestJWT.issuedAt), "exp": .number(StudioTestJWT.expires)])
        }
        for kind in ["sk", "pk", "rk"] where real.hasPrefix(kind + "_live_") || real.hasPrefix(kind + "_test_") {
            return "\(kind)_test_markview_" + name.lowercased()
        }
        return plain
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `text` with every token whose hash is a known secret's replaced by `[redacted:NAME]`.
    static func redact(_ text: String, hashes: [String: String]) -> String {
        guard !hashes.isEmpty, !text.isEmpty else { return text }
        var result = ""
        var token = ""
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._~+/=-"))
        func flush() {
            if token.count >= 8, let name = hashes[hash(token)] { result += "[redacted:\(name)]" } else { result += token }
            token = ""
        }
        for scalar in text.unicodeScalars {
            if tokenCharacters.contains(scalar) { token.unicodeScalars.append(scalar) } else { flush(); result.unicodeScalars.append(scalar) }
        }
        flush()
        return result
    }

    // MARK: Discovery

    static func discover(root: URL, appFolder: URL, appOrigin: String?, saved: [StudioServerConnection] = []) -> StudioConnectionDiscovery {
        let root = root.standardizedFileURL, appFolder = appFolder.standardizedFileURL
        var discovery = StudioConnectionDiscovery()

        // Env files, the app folder's first: real files decide values, examples only name variables and suggest addresses.
        var values: [String: (value: String, file: String)] = [:]
        var examples: [String: (value: String, file: String)] = [:]
        for folder in folders(from: appFolder, upTo: root) {
            for name in envFiles {
                for (key, value) in read(folder.appendingPathComponent(name)) where values[key] == nil {
                    values[key] = (value, relative(folder.appendingPathComponent(name), root))
                }
            }
            for name in exampleFiles {
                for (key, value) in read(folder.appendingPathComponent(name)) where examples[key] == nil {
                    examples[key] = (value, relative(folder.appendingPathComponent(name), root))
                }
            }
        }

        // Sources: names the app reads, and the defaults the code gives URL variables.
        let scan = scanSources(in: [appFolder] + workspacePackages(of: appFolder, root: root), root: root)
        var names = Set(values.keys).union(examples.keys).union(scan.referenced)
        names.formUnion(scan.literalURLVariables)
        discovery.disclosures = scan.disclosures

        for name in names.sorted() {
            if isSecretVariable(name) {
                let real = values[name]?.value
                discovery.testValues[name] = testValue(for: name, real: real)
                if let real, real.count >= 8 { discovery.secretHashes[hash(real)] = name }
                continue
            }
            guard isURLVariable(name) else { continue }
            if isSelfVariable(name) {
                discovery.notRedirected.append(.init(variable: name, reason: "It is the application's own address."))
                continue
            }
            let given = values[name] ?? examples[name]
            if let given, !given.value.isEmpty, split(given.value) == nil {
                let scheme = given.value.split(separator: ":").first.map(String.init) ?? "unknown"
                discovery.notRedirected.append(.init(variable: name, reason: "Its \(scheme): address is not HTTP; only HTTP services are simulated."))
                continue
            }
            let origin: String, basePath: String, foundIn: String
            if let given, let parts = split(given.value) {
                (origin, basePath, foundIn) = (parts.origin, parts.basePath, given.file)
            } else if let fallback = scan.defaults[name], let parts = split(fallback.value) {
                (origin, basePath, foundIn) = (parts.origin, parts.basePath, fallback.file)
            } else {
                // Setting a variable the app runs without would switch on an optional integration.
                discovery.notRedirected.append(.init(variable: name, reason: "It has no address in the env files or the code; the app runs without it."))
                continue
            }
            if let appOrigin, sameServer(origin, appOrigin) {
                discovery.notRedirected.append(.init(variable: name, reason: "It points at the application itself."))
                continue
            }
            let mode = saved.first { $0.variable == name }?.mode ?? .simulated
            discovery.connections.append(StudioServerConnection(variable: name, origin: origin, basePath: basePath, mode: mode, foundIn: foundIn))
        }
        return discovery
    }

    /// The variables to set when MarkView starts the server: simulated connections at their gateway port (with their path),
    /// secrets at their test values unless kept real. Names are validated; nothing else is touched.
    static func launchOverrides(_ discovery: StudioConnectionDiscovery, ports: [String: UInt16], keptReal: Set<String>) -> [String: String] {
        var overrides: [String: String] = [:]
        for connection in discovery.connections where connection.mode == .simulated {
            guard let port = ports[connection.variable], isValidName(connection.variable) else { continue }
            overrides[connection.variable] = "http://127.0.0.1:\(port)" + connection.basePath
        }
        for (name, value) in discovery.testValues where !keptReal.contains(name) && isValidName(name) {
            overrides[name] = value
        }
        return overrides
    }

    // MARK: Helpers

    private static func folders(from appFolder: URL, upTo root: URL) -> [URL] {
        var result: [URL] = []
        var folder = appFolder
        while folder.path.hasPrefix(root.path) {
            result.append(folder)
            if folder.path == root.path { break }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        return result
    }

    private static func read(_ file: URL) -> [(name: String, value: String)] {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parseEnvFile(text)
    }

    private static func relative(_ file: URL, _ root: URL) -> String {
        let path = file.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : file.lastPathComponent
    }

    private static func sameServer(_ origin: String, _ appOrigin: String) -> Bool {
        guard let a = URLComponents(string: origin), let b = URLComponents(string: appOrigin) else { return false }
        let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
        func port(_ c: URLComponents) -> Int { c.port ?? (c.scheme == "https" ? 443 : 80) }
        let hosts = a.host == b.host || (loopback.contains(a.host ?? "") && loopback.contains(b.host ?? ""))
        return hosts && port(a) == port(b)
    }

    /// Folders of the packages in this repository that the app depends on (npm, pnpm and yarn workspaces): their code runs in
    /// the app's server too.
    static func workspacePackages(of appFolder: URL, root: URL) -> [URL] {
        guard let data = try? Data(contentsOf: appFolder.appendingPathComponent("package.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var wanted = Set<String>()
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            wanted.formUnion(((manifest[key] as? [String: Any]) ?? [:]).keys)
        }
        guard !wanted.isEmpty, let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "package.json", enumerator.level <= 4,
                  let data = try? Data(contentsOf: url), let package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = package["name"] as? String, wanted.contains(name) else { continue }
            let folder = url.deletingLastPathComponent().standardizedFileURL
            if folder.path != appFolder.path { found.append(folder) }
        }
        return found
    }

    struct SourceScan {
        var referenced = Set<String>()
        /// Quoted names of URL variables (`urlEnv: "API_URL"`): a registry that reads them through `process.env[name]`.
        var literalURLVariables = Set<String>()
        var defaults: [String: (value: String, file: String)] = [:]
        var firstSeen: [String: String] = [:]
        var disclosures: [String] = []
    }

    private static let referencePatterns: [NSRegularExpression] = [
        #"process\.env\.([A-Z_][A-Z0-9_]*)"#, #"process\.env\[\s*["'`]([A-Z_][A-Z0-9_]*)["'`]\s*\]"#, #"import\.meta\.env\.([A-Z_][A-Z0-9_]*)"#,
        #"\bDeno\.env\.get\(\s*["']([A-Z_][A-Z0-9_]*)["']"#, #"\bBun\.env\.([A-Z_][A-Z0-9_]*)"#,
        #"os\.environ(?:\.get)?\s*[\[(]\s*["']([A-Z_][A-Z0-9_]*)["']"#, #"os\.getenv\(\s*["']([A-Z_][A-Z0-9_]*)["']"#,
        #"\bENV(?:\.fetch)?\s*[\[(]\s*["']([A-Z_][A-Z0-9_]*)["']"#, #"\bgetenv\(\s*["']([A-Z_][A-Z0-9_]*)["']"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let literalPattern = try? NSRegularExpression(pattern: #"["'`]([A-Z][A-Z0-9_]*_(?:URL|URI|ENDPOINT|ORIGIN))["'`]"#)
    private static let urlPattern = try? NSRegularExpression(pattern: #"["'`](https?://[^"'`\s$]+)["'`]"#)
    private static let overridePattern = try? NSRegularExpression(
        pattern: #"(dotenv[^\n]{0,80}override\s*:\s*true|override\s*:\s*true[^\n]{0,80}dotenv|Dotenv\.overload|load_dotenv\([^)]*override\s*=\s*True)"#)

    private static func scanSources(in folders: [URL], root: URL) -> SourceScan {
        var scan = SourceScan()
        var files = 0
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard sourceExtensions.contains(url.pathExtension.lowercased()),
                      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
                      !url.lastPathComponent.contains(".test."), !url.lastPathComponent.contains(".spec."),
                      !url.pathComponents.contains("__tests__"),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files += 1
                if files > maxFiles { return scan }
                scanFile(text, file: relative(url, root), into: &scan)
            }
        }
        return scan
    }

    static func scanFile(_ text: String, file: String, into scan: inout SourceScan) {
        let lines = text.components(separatedBy: "\n")
        func names(_ regex: NSRegularExpression?, in line: String) -> [String] {
            guard let regex else { return [] }
            let range = NSRange(line.startIndex..., in: line)
            return regex.matches(in: line, range: range).compactMap { Range($0.range(at: 1), in: line).map { String(line[$0]) } }
        }
        for (index, line) in lines.enumerated() where line.count < 4_000 {
            var found: [String] = []
            for pattern in referencePatterns { found += names(pattern, in: line) }
            let literals = names(literalPattern, in: line)
            scan.referenced.formUnion(found)
            scan.literalURLVariables.formUnion(literals)
            for name in found + literals where scan.firstSeen[name] == nil { scan.firstSeen[name] = "\(file):\(index + 1)" }
            // A URL variable's default: an http literal on the same line or within five lines after it.
            for name in Set(found + literals) where isURLVariable(name) && scan.defaults[name] == nil {
                for offset in 0...5 where index + offset < lines.count {
                    if let url = names(urlPattern, in: lines[index + offset]).first {
                        scan.defaults[name] = (url, "\(file):\(index + offset + 1)")
                        break
                    }
                }
            }
            if let overridePattern, overridePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                let note = "\(file):\(index + 1) loads env files over the process environment, so simulated connections may not apply there."
                if !scan.disclosures.contains(note) { scan.disclosures.append(note) }
            }
        }
    }
}

/// Test JWTs (BUG-073, REQ-010): HS256-signed with a fixed key that is published here, so libraries that check a token's
/// shape (three non-empty segments, a known algorithm) accept it while no real service does. Their dates are fixed and far
/// apart, so they are valid at any scenario test time and the same on every start.
enum StudioTestJWT {
    static let key = "markview-ui-studio-test-key"
    /// 2023-11-14T22:13:20Z.
    static let issuedAt: Double = 1_700_000_000
    /// 2100-01-01T00:00:00Z.
    static let expires: Double = 4_102_444_800
    static let roles: Set<String> = ["anon", "authenticated", "service_role"]

    static func make(_ claims: [String: StudioJSON]) -> String {
        let header = base64URL(Data(StudioJSON.object(["alg": .string("HS256"), "typ": .string("JWT")]).text.utf8))
        let payload = base64URL(Data(StudioJSON.object(claims).text.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data("\(header).\(payload)".utf8), using: SymmetricKey(data: Data(key.utf8)))
        return "\(header).\(payload).\(base64URL(Data(signature)))"
    }

    /// The claims of a token, without checking its signature; nil when it is not a JWT.
    static func claims(of token: String) -> [String: StudioJSON]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return StudioJSON(any: object).objectValue
    }

    /// The role of a real Supabase-style key, when it is one of the known roles: the only claim a test value copies.
    static func role(of token: String) -> String? {
        claims(of: token)?["role"]?.stringValue.flatMap { roles.contains($0) ? $0 : nil }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
