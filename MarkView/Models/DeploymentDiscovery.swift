import Foundation

/// A place the project seems to run, found in its files (workflows, config of a platform, docs, scripts) and in
/// `~/.ssh/config`. The person looks at each one and keeps the ones that are real. Foundation only, checked in
/// `tools/tests/deployment-discovery-tests.sh`.
struct DeploymentSuggestion: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: DeploymentEnvironment.Kind
    var host = ""
    var user = ""
    var port = 22
    var identityFile = ""
    var provider = ""
    var cloudCommands: [CloudCommand] = []
    var checks: [DeploymentCheck] = []
    var logSources: [LogSource] = []
    /// Why it is suggested: file and what it says.
    var evidence: [String] = []
    /// What is still missing ("the host is a secret named PROD_HOST: ask your team or the settings of the repository").
    var missing: [String] = []
    /// 0…100: how sure the scan is that this is a real place the project runs.
    var confidence = 50

    func makeEnvironment(existing: Set<String>) -> DeploymentEnvironment {
        var env = DeploymentEnvironment(id: DeploymentEnvironment.slug(name, existing: existing), name: name, kind: kind)
        env.host = host; env.user = user; env.port = port; env.identityFile = identityFile; env.provider = provider
        env.cloudCommands = cloudCommands; env.checks = checks; env.logSources = logSources; env.evidence = evidence
        env.notes = missing.joined(separator: "\n")
        return env
    }
}

struct SSHConfigHost: Equatable {
    var alias: String
    var hostName = ""
    var user = ""
    var port = 22
    var identityFile = ""
}

enum DeploymentDiscovery {
    static let maximumFileBytes = 300_000
    static let ignoredDirectories: Set<String> = [".git", "node_modules", ".build", "build", "dist", "DerivedData", ".dde", "vendor", "Pods", ".venv", "venv", "target"]
    /// Hosts that appear in docs as the place code lives, not as a server to look at.
    static let codeHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "git.sr.ht"]
    /// Words that follow "ssh" in prose and commands but are not machines.
    static let notHosts: Set<String> = ["github", "gitlab", "bitbucket", "apt-get", "apt", "install", "keygen", "add", "agent", "config", "copy-id", "keyscan", "key", "keys", "into", "to", "as", "in", "with", "tunnel", "access", "connection", "server", "login", "user", "root"]
    static let placeholders: Set<String> = ["host", "hostname", "server", "example.com", "your-server", "your-host", "your.server.com", "my-server", "yourserver", "domain.com", "localhost", "127.0.0.1", "0.0.0.0", "user", "ip", "address", "x.x.x.x", "1.2.3.4"]

    // MARK: ssh config

    static func parseSSHConfig(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [SSHConfigHost] = []
        func flush() { hosts += current; current = [] }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            switch key {
            case "host":
                flush()
                current = value.split(separator: " ").map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .map { SSHConfigHost(alias: $0) }
            case "match": flush()
            case "hostname": for i in current.indices { current[i].hostName = value }
            case "user": for i in current.indices { current[i].user = value }
            case "port": for i in current.indices { current[i].port = Int(value) ?? 22 }
            case "identityfile": for i in current.indices where current[i].identityFile.isEmpty { current[i].identityFile = value }
            default: break
            }
        }
        flush()
        return hosts
    }

    // MARK: scan

    static func scan(root: URL, sshConfig: String? = nil) -> [DeploymentSuggestion] {
        var found: [String: DeploymentSuggestion] = [:]
        func merge(_ s: DeploymentSuggestion) {
            if var old = found[s.id] {
                old.evidence += s.evidence.filter { !old.evidence.contains($0) }
                old.missing += s.missing.filter { !old.missing.contains($0) }
                old.checks += s.checks.filter { c in !old.checks.contains { $0.id == c.id } }
                old.cloudCommands += s.cloudCommands.filter { c in !old.cloudCommands.contains { $0.id == c.id } }
                if old.host.isEmpty { old.host = s.host }
                if old.user.isEmpty { old.user = s.user }
                old.confidence = max(old.confidence, s.confidence)
                found[s.id] = old
            } else { found[s.id] = s }
        }

        let files = projectFiles(root)
        // The enumerator may hand back /private/var/… for /var/…: compare resolved paths.
        let base = root.resolvingSymlinksInPath().path + "/"
        let rel: (URL) -> String = { url in
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
        }
        var docText: [(String, String)] = []
        var compose: [(String, String)] = []
        var packages: [(String, String)] = []
        for url in files {
            let path = rel(url), name = url.lastPathComponent.lowercased()
            guard let text = read(url) else { continue }
            if path.hasPrefix(".github/workflows/") && (name.hasSuffix(".yml") || name.hasSuffix(".yaml")) { workflow(text, path: path).forEach(merge) }
            else if name == "vercel.json" || path == ".vercel/project.json" { merge(vercel(path: path)) }
            else if name == "fly.toml" { merge(fly(text, path: path)) }
            else if name == "netlify.toml" { merge(simpleCloud(id: "netlify", name: "Netlify", provider: "netlify", path: path, commands: [])) }
            else if name == "render.yaml" { merge(simpleCloud(id: "render", name: "Render", provider: "render", path: path, commands: [])) }
            else if name == "app.json" || name == "procfile" { if let s = heroku(text, path: path, isProcfile: name == "procfile") { merge(s) } }
            else if name == "serverless.yml" || name == "serverless.yaml" || name == "cdk.json" || name == "samconfig.toml" {
                merge(simpleCloud(id: "aws", name: "AWS", provider: "aws", path: path, commands: [("identity", "Who am I", "aws sts get-caller-identity")]))
            }
            else if name == "app.yaml" && text.contains("runtime") { merge(simpleCloud(id: "gcloud-app-engine", name: "Google App Engine", provider: "gcloud", path: path, commands: [("services", "Services", "gcloud app services list")])) }
            else if name == "chart.yaml" || path.hasPrefix("k8s/") || path.hasPrefix("kubernetes/") || path.hasPrefix("deploy/k8s/") {
                merge(simpleCloud(id: "kubernetes", name: "Kubernetes", provider: "kubernetes", path: path, commands: [("pods", "Pods", "kubectl get pods"), ("deployments", "Deployments", "kubectl get deployments")]))
            }
            else if name.hasSuffix(".tf") { if let s = terraform(text, path: path) { merge(s) } }
            else if name.hasPrefix("docker-compose") || name.hasPrefix("compose.") { compose.append((path, text)) }
            else if name == "package.json" { packages.append((path, text)) }
            if name.hasSuffix(".md") || name.hasSuffix(".sh") || name == "makefile" || name.hasPrefix("deploy") || path.hasPrefix("scripts/") { docText.append((path, text)) }
        }

        // Managed services (a database in the cloud) and the hosting vendors the docs name.
        for s in managedServices(docs: docText + compose, packages: packages) { merge(s) }
        for s in vendorServers(docs: docText) where !found.values.contains(where: { $0.kind == .ssh && !$0.host.isEmpty && s.name.lowercased().hasPrefix($0.name.lowercased()) }) { merge(s) }

        // Hosts named in docs and scripts.
        var named: [String: (user: String, evidence: [String])] = [:]
        for (path, text) in docText {
            for hit in sshTargets(in: text) {
                var entry = named[hit.host] ?? (hit.user, [])
                if entry.user.isEmpty { entry.user = hit.user }
                entry.evidence.append("`\(path)`: \(hit.snippet)")
                named[hit.host] = entry
            }
        }
        let config = sshConfig.map(parseSSHConfig) ?? []
        for (host, info) in named.sorted(by: { $0.key < $1.key }) {
            let alias = config.first { $0.alias == host || $0.hostName == host }
            var s = DeploymentSuggestion(id: DeploymentEnvironment.slug(host), name: label(host), kind: .ssh, host: host, user: info.user.isEmpty ? (alias?.user ?? "") : info.user)
            if let alias { s.port = alias.port; s.identityFile = alias.identityFile; s.evidence.append("`~/.ssh/config`: Host \(alias.alias)") }
            s.evidence += Array(info.evidence.prefix(3))
            s.confidence = alias != nil ? 85 : 65
            merge(s)
        }

        // Compose services are checks on a server; attach them to the first SSH suggestion, or list them alone.
        let services = compose.flatMap { composeServices($0.1) }
        if !services.isEmpty {
            let checks = services.prefix(24).map { DeploymentCheck(id: "container-\($0)", title: "Container \($0)", kind: .docker, target: $0) }
            let servers = found.values.filter { $0.kind == .ssh && !$0.host.isEmpty }
            if servers.count == 1, let key = servers.first?.id {
                var s = found[key]!
                for check in checks where !s.checks.contains(where: { $0.id == check.id }) { s.checks.append(check) }
                s.evidence.append("`\(compose[0].0)`: services \(services.joined(separator: ", "))")
                found[key] = s
            } else {
                merge(DeploymentSuggestion(id: "docker-host", name: "Docker Compose services", kind: .ssh, checks: Array(checks),
                                           evidence: ["`\(compose[0].0)`: \(services.count) services (\(services.prefix(6).joined(separator: ", "))\(services.count > 6 ? ", …" : ""))"],
                                           missing: ["Which server runs these containers? Add its host; the container checks come with it."], confidence: 40))
            }
        }

        // ssh config hosts the project text mentions by name (not only in an ssh command).
        let corpus = docText.map { $0.1.lowercased() }.joined(separator: "\n")
        for host in config where found[DeploymentEnvironment.slug(host.hostName.isEmpty ? host.alias : host.hostName)] == nil && found[DeploymentEnvironment.slug(host.alias)] == nil {
            guard corpus.contains(host.alias.lowercased()) || (!host.hostName.isEmpty && corpus.contains(host.hostName.lowercased())) else { continue }
            merge(DeploymentSuggestion(id: DeploymentEnvironment.slug(host.alias), name: label(host.alias), kind: .ssh, host: host.hostName.isEmpty ? host.alias : host.hostName,
                                       user: host.user, port: host.port, identityFile: host.identityFile,
                                       evidence: ["`~/.ssh/config`: Host \(host.alias), named in the project's docs"], confidence: 70))
        }
        return found.values.sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.name < $1.name }
    }

    // MARK: managed services

    /// Cloud databases and caches: the hostnames they are reached at, which docs write down (the connection URL with its
    /// password is a secret and is never read), their port, and the CLI that shows their state.
    private static let managed: [(provider: String, title: String, host: String, port: Int, package: String)] = [
        ("neon", "Neon database", #"\bep-[a-z0-9-]+\.[a-z0-9.-]*neon\.tech\b"#, 5432, "@neondatabase/"),
        ("supabase", "Supabase database", #"\b(?:db\.[a-z0-9]+\.supabase\.co|[a-z0-9-]+\.pooler\.supabase\.com)\b"#, 5432, "@supabase/"),
        ("planetscale", "PlanetScale database", #"\b[a-z0-9.-]+\.psdb\.cloud\b"#, 3306, "@planetscale/"),
        ("turso", "Turso database", #"\b[a-z0-9.-]+\.turso\.io\b"#, 443, "@libsql/"),
        ("upstash", "Upstash Redis", #"\b[a-z0-9.-]+\.upstash\.io\b"#, 6379, "@upstash/"),
        ("aws-rds", "Amazon RDS database", #"\b[a-z0-9.-]+\.rds\.amazonaws\.com\b"#, 5432, ""),
        ("azure-postgres", "Azure PostgreSQL", #"\b[a-z0-9.-]+\.postgres\.database\.azure\.com\b"#, 5432, ""),
        ("aiven", "Aiven service", #"\b[a-z0-9.-]+\.aivencloud\.com\b"#, 0, ""),
        ("cockroach", "CockroachDB", #"\b[a-z0-9.-]+\.cockroachlabs\.cloud\b"#, 26257, ""),
        ("mongodb-atlas", "MongoDB Atlas", #"\b[a-z0-9.-]+\.mongodb\.net\b"#, 0, "")
    ]

    private static func managedServices(docs: [(String, String)], packages: [(String, String)]) -> [DeploymentSuggestion] {
        var out: [String: DeploymentSuggestion] = [:]
        let environmentWords = ["production", "prod", "staging", "stage", "development", "dev", "preview"]
        for entry in managed {
            guard let regex = try? NSRegularExpression(pattern: entry.host, options: [.caseInsensitive]) else { continue }
            var s = DeploymentSuggestion(id: entry.provider, name: entry.title, kind: .cloud, provider: entry.provider, confidence: 80)
            var hosts: [String] = []
            var labels: [String: String] = [:]
            var projectIDs = Set<String>()
            for (path, text) in docs {
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(rawLine)
                    let range = NSRange(line.startIndex..., in: line)
                    let found = regex.matches(in: line, range: range).compactMap { Range($0.range, in: line).map { String(line[$0]).lowercased() } }
                    for host in found {
                        // A host is often named on several lines; the one that says which environment it is labels it.
                        let label = environmentWords.first { line.lowercased().range(of: #"\b"# + $0 + #"\b"#, options: .regularExpression) != nil }
                            .map { $0 == "prod" ? "production" : $0 == "stage" ? "staging" : $0 == "development" ? "dev" : $0 }
                        if !hosts.contains(host) { hosts.append(host); s.evidence.append("`\(path)`: host \(host)") }
                        if let label, labels[host] == nil { labels[host] = label }
                    }
                    if entry.provider == "neon", line.lowercased().contains("neon") {
                        for m in matches(#"\b([a-z]{3,12}-[a-z]{3,12}-\d{6,10})\b"#, in: line) { projectIDs.insert(m[1]) }
                    }
                }
            }
            if entry.port > 0 {
                for host in hosts {
                    s.checks.append(DeploymentCheck(id: "port-\(host)", title: "Reachable" + (labels[host].map { " (\($0))" } ?? "") + ": \(host)", kind: .port, target: "\(host):\(entry.port)"))
                }
            }
            let packageHit = packages.first { $0.1.contains("\"\(entry.package)") && !entry.package.isEmpty }
            if hosts.isEmpty && packageHit == nil { continue }
            if let packageHit { s.evidence.append("`\(packageHit.0)`: depends on \(entry.package)…"); if hosts.isEmpty { s.confidence = 40; s.name = entry.title + " (library found)" } }
            s.cloudCommands = managedCommands(entry.provider, projectIDs: projectIDs.sorted())
            s.missing = ["The connection URL (DATABASE_URL, with its password) is a secret: MarkView never reads it." + (hosts.isEmpty ? " No host is written in the docs: add one as a port check in Edit." : " The hosts above come from the docs; reachability is checked from this Mac.")]
            if entry.provider == "neon" && projectIDs.isEmpty { s.missing.append("Neon project id not found in the docs: see the Neon console, or run `neonctl projects list`.") }
            out[entry.provider] = s
        }
        return out.values.sorted { $0.name < $1.name }
    }

    private static func managedCommands(_ provider: String, projectIDs: [String]) -> [CloudCommand] {
        switch provider {
        case "neon":
            var commands = [CloudCommand(id: "projects", title: "Projects", command: "neonctl projects list")]
            for id in projectIDs.prefix(2) {
                commands.append(CloudCommand(id: "branches-\(id)", title: "Branches of \(id)", command: "neonctl branches list --project-id \(id)"))
                commands.append(CloudCommand(id: "operations-\(id)", title: "Recent operations of \(id)", command: "neonctl operations list --project-id \(id)"))
                commands.append(CloudCommand(id: "databases-\(id)", title: "Databases of \(id)", command: "neonctl databases list --project-id \(id)"))
            }
            return commands
        case "supabase": return [CloudCommand(id: "projects", title: "Projects", command: "supabase projects list")]
        case "planetscale": return [CloudCommand(id: "databases", title: "Databases", command: "pscale database list")]
        case "turso": return [CloudCommand(id: "databases", title: "Databases", command: "turso db list")]
        case "aws-rds": return [CloudCommand(id: "instances", title: "DB instances", command: "aws rds describe-db-instances")]
        default: return []
        }
    }

    /// "production runs on a Contabo box", "dev: Hetzner server": the vendor and the environment, without a host.
    private static func vendorServers(docs: [(String, String)]) -> [DeploymentSuggestion] {
        let vendors = ["contabo": "Contabo", "hetzner": "Hetzner", "digitalocean": "DigitalOcean", "droplet": "DigitalOcean", "linode": "Linode", "vultr": "Vultr", "ovh": "OVH", "scaleway": "Scaleway", "lightsail": "AWS Lightsail", "ec2": "AWS EC2"]
        let environments: [(String, String)] = [("production", "Production"), ("prod", "Production"), ("staging", "Staging"), ("stage", "Staging"), ("development", "Dev"), ("dev", "Dev")]
        var out: [String: DeploymentSuggestion] = [:]
        for (path, text) in docs where path.hasSuffix(".md") {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine), lower = line.lowercased()
                guard line.count < 400, let vendor = vendors.first(where: { lower.range(of: #"\b"# + $0.key + #"\b"#, options: .regularExpression) != nil }) else { continue }
                var seen = Set<String>()
                for env in environments where lower.range(of: #"\b"# + env.0 + #"\b"#, options: .regularExpression) != nil && seen.insert(env.1).inserted {
                    let id = DeploymentEnvironment.slug("\(env.1) \(vendor.value)")
                    if out[id] == nil && out.count < 6 {
                        out[id] = DeploymentSuggestion(id: id, name: "\(env.1) (\(vendor.value))", kind: .ssh,
                                                       evidence: ["`\(path)`: \(line.trimmingCharacters(in: CharacterSet(charactersIn: "|- #>*`").union(.whitespaces)).prefix(110))"],
                                                       missing: ["The docs name \(vendor.value) but no host: add the host (and user) of this server."], confidence: 45)
                    }
                }
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }

    // MARK: files

    private static func projectFiles(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        let hiddenOK: Set<String> = [".github", ".vercel"]
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if ignoredDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if (values?.fileSize ?? 0) <= maximumFileBytes { urls.append(url) }
            if urls.count > 4000 { break }
        }
        // skipsHiddenFiles hides .github; look there directly.
        for dir in hiddenOK {
            let base = root.appendingPathComponent(dir)
            if let inner = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
                while let url = inner.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if values?.isDirectory != true, (values?.fileSize ?? 0) <= maximumFileBytes { urls.append(url) }
                }
            }
        }
        return urls
    }

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func label(_ host: String) -> String {
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.isEmpty ? host : first.prefix(1).uppercased() + first.dropFirst()
    }

    // MARK: sources

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { i in Range(match.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    /// `ssh user@host`, `scp … user@host:path`, `rsync … user@host:path` in docs and scripts.
    static func sshTargets(in text: String) -> [(user: String, host: String, snippet: String)] {
        var out: [(String, String, String)] = []
        let patterns = [#"\bssh\s+(?:-[A-Za-z]\s+\S+\s+|-[A-Za-z]+\s+)*(?:([A-Za-z0-9._-]+)@)?([A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9])\b"#,
                        #"\b(?:scp|rsync)\b[^\n]*?\s(?:([A-Za-z0-9._-]+)@)?([A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]):"#]
        for pattern in patterns {
            for m in matches(pattern, in: text) {
                let user = m[1], host = m[2].lowercased()
                if codeHosts.contains(host) || placeholders.contains(host) || placeholders.contains(user.lowercased()) || notHosts.contains(host) || user.lowercased() == "git" { continue }
                // A machine is a name with a letter or an IPv4 address; "109" is a number in a sentence.
                let isIPv4 = host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
                if !isIPv4 && host.rangeOfCharacter(from: .letters) == nil { continue }
                if host.hasPrefix("-") || !host.contains(".") && host.count < 3 { continue }
                // A bare word after "ssh" with no user and no dot is most often prose ("ssh into", "ssh keys").
                if user.isEmpty && !host.contains(".") && host.range(of: #"\d"#, options: .regularExpression) == nil && host.range(of: #"-"#, options: .regularExpression) == nil { continue }
                out.append((user, host, String(m[0].prefix(90))))
            }
        }
        return out
    }

    private static func workflow(_ text: String, path: String) -> [DeploymentSuggestion] {
        let lower = text.lowercased()
        let deploys = ["deploy", "appleboy/ssh-action", "ssh-action", "rsync", "scp ", "kubectl", "vercel", "flyctl", "fly deploy", "aws-actions", "aws ecs", "gcloud", "heroku", "azure/", "docker push", "helm "]
        guard deploys.contains(where: { lower.contains($0) }) else { return [] }
        var results: [DeploymentSuggestion] = []
        let environments = Array(Set(matches(#"^\s*environment:\s*['"]?([A-Za-z0-9_.-]+)['"]?\s*$"#, in: text).map { $0[1] })).sorted()
        let secretHosts = Array(Set(matches(#"\$\{\{\s*(?:secrets|vars)\.([A-Za-z0-9_]*(?:HOST|SERVER|IP)[A-Za-z0-9_]*)\s*\}\}"#, in: text).map { $0[1] })).sorted()
        let usesSSH = lower.contains("ssh") || lower.contains("rsync") || lower.contains("scp ")
        let names = environments.isEmpty ? secretHosts.map { secretEnvironmentName($0) } : environments
        for name in (names.isEmpty && usesSSH ? ["Server"] : names) {
            let secret = secretHosts.first { secretEnvironmentName($0).lowercased() == name.lowercased() } ?? secretHosts.first
            var s = DeploymentSuggestion(id: DeploymentEnvironment.slug(name), name: name.prefix(1).uppercased() + name.dropFirst(), kind: usesSSH ? .ssh : .cloud)
            if !usesSSH { s.provider = lower.contains("vercel") ? "vercel" : lower.contains("flyctl") || lower.contains("fly deploy") ? "fly" : lower.contains("heroku") ? "heroku" : lower.contains("kubectl") || lower.contains("helm") ? "kubernetes" : lower.contains("gcloud") ? "gcloud" : lower.contains("aws") ? "aws" : "cloud" }
            s.evidence = ["`\(path)`: deploys" + (environments.contains(name) ? " to the environment \(name)" : "")]
            if let secret { s.evidence.append("`\(path)`: host is the secret \(secret)"); if usesSSH { s.missing.append("The host is the repository secret \(secret): read it from the repository settings or ask your team.") } }
            s.confidence = environments.contains(name) ? 70 : 55
            results.append(s)
        }
        return results
    }

    private static func secretEnvironmentName(_ secret: String) -> String {
        let cleaned = secret.replacingOccurrences(of: #"_?(HOST|SERVER|IP|ADDRESS)S?$"#, with: "", options: .regularExpression)
        let words = cleaned.lowercased().split(separator: "_").map(String.init)
        return words.isEmpty ? "Server" : words.joined(separator: " ").capitalized
    }

    private static func vercel(path: String) -> DeploymentSuggestion {
        simpleCloud(id: "vercel", name: "Vercel", provider: "vercel", path: path,
                    commands: [("deployments", "Deployments", "vercel ls"), ("who", "Account", "vercel whoami")])
    }

    private static func fly(_ text: String, path: String) -> DeploymentSuggestion {
        let app = matches(#"^app\s*=\s*['"]([^'"]+)['"]"#, in: text).first?[1] ?? ""
        let flag = app.isEmpty ? "" : " -a \(app)"
        var s = simpleCloud(id: "fly", name: app.isEmpty ? "Fly.io" : "Fly.io \(app)", provider: "fly", path: path,
                            commands: [("status", "Status", "fly status\(flag)"), ("checks", "Health checks", "fly checks list\(flag)"), ("logs", "Recent logs", "fly logs\(flag) --no-tail")])
        s.confidence = 80
        return s
    }

    private static func heroku(_ text: String, path: String, isProcfile: Bool) -> DeploymentSuggestion? {
        if !isProcfile {
            guard text.contains("\"heroku\"") || text.contains("buildpacks") || text.contains("\"addons\"") else { return nil }
        }
        let name = matches(#""name"\s*:\s*"([^"]+)""#, in: text).first?[1] ?? ""
        let flag = name.isEmpty ? "" : " -a \(name)"
        return simpleCloud(id: "heroku", name: "Heroku", provider: "heroku", path: path,
                           commands: [("ps", "Dynos", "heroku ps\(flag)"), ("releases", "Releases", "heroku releases\(flag)"), ("logs", "Recent logs", "heroku logs -n 200\(flag)")])
    }

    private static func terraform(_ text: String, path: String) -> DeploymentSuggestion? {
        let lower = text.lowercased()
        if lower.contains("provider \"aws\"") || lower.contains("hashicorp/aws") { return simpleCloud(id: "aws", name: "AWS", provider: "aws", path: path, commands: [("identity", "Who am I", "aws sts get-caller-identity")]) }
        if lower.contains("provider \"google\"") || lower.contains("hashicorp/google") { return simpleCloud(id: "gcloud", name: "Google Cloud", provider: "gcloud", path: path, commands: [("projects", "Projects", "gcloud projects list")]) }
        if lower.contains("provider \"azurerm\"") || lower.contains("hashicorp/azurerm") { return simpleCloud(id: "azure", name: "Azure", provider: "azure", path: path, commands: [("groups", "Resource groups", "az group list")]) }
        if lower.contains("digitalocean") { return simpleCloud(id: "digitalocean", name: "DigitalOcean", provider: "digitalocean", path: path, commands: [("droplets", "Droplets", "doctl compute droplet list")]) }
        return nil
    }

    private static func simpleCloud(id: String, name: String, provider: String, path: String, commands: [(String, String, String)]) -> DeploymentSuggestion {
        DeploymentSuggestion(id: id, name: name, kind: .cloud, provider: provider,
                             cloudCommands: commands.map { CloudCommand(id: $0.0, title: $0.1, command: $0.2) },
                             evidence: ["`\(path)`"], confidence: 70)
    }

    /// Service names of a compose file (the keys under `services:`).
    static func composeServices(_ text: String) -> [String] {
        var names: [String] = []
        var inServices = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("services:") { inServices = true; continue }
            if inServices {
                if let first = s.first, first != " ", first != "\t", first != "#", first != "\r" { inServices = false; continue }
                let indent = s.prefix(while: { $0 == " " }).count
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if indent == 2 || (indent == 4 && names.isEmpty && !trimmed.isEmpty && !s.hasPrefix("  ")), trimmed.hasSuffix(":"), !trimmed.hasPrefix("#") {
                    names.append(String(trimmed.dropLast()))
                }
            }
        }
        return names
    }
}
