import Foundation

/// One thing a cloud place runs (a function, a hosting channel, a machine, a deployment) with what the person wants
/// to do about it: see its state, read its log, open it. Foundation only, checked in
/// `tools/tests/cloud-services-tests.sh`.
struct CloudService: Identifiable, Equatable {
    /// Worst last, so a sort puts the problems on top.
    enum Level: Int, Comparable {
        case ok, unknown, warn, bad
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var group: String
    var name: String
    var details: [String] = []
    /// A word for the badge ("ready", "stopped", "error"); nil = nothing to say about its state.
    var state: String?
    var level = Level.unknown
    /// The live thing (a site, a function's address) and the provider's page about it.
    var openURL: String?
    var consoleURL: String?
    /// A read-only command that prints its log.
    var logCommand: String?
    /// Reachability is worth checking from this Mac (a public site; never a service that wakes up when called).
    var probe = false
}

/// A read-only command whose JSON output lists one group of services.
struct CloudQuery: Equatable {
    var id: String
    var group: String
    var command: String
}

/// The project or app a cloud place's commands are about (`--project x`, `-a x`).
struct CloudScope: Equatable {
    var project: String?
    var app: String?
}

enum CloudServices {
    // MARK: what to ask

    static func scope(of commands: [CloudCommand]) -> CloudScope {
        var scope = CloudScope()
        for command in commands {
            let words = command.command.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() where index + 1 < words.count {
                if word == "--project" || word == "-P", scope.project == nil, isName(words[index + 1]) { scope.project = words[index + 1] }
                if word == "-a" || word == "--app", scope.app == nil, isName(words[index + 1]) { scope.app = words[index + 1] }
            }
        }
        return scope
    }

    /// Names that go into commands: nothing a shell would read as more than one word.
    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil
    }

    static func queries(provider: String, scope: CloudScope) -> [CloudQuery] {
        switch provider {
        case "firebase":
            guard let project = scope.project else { return [] }
            return [CloudQuery(id: "hosting", group: "Hosting", command: "firebase hosting:channel:list --project \(project) --json"),
                    CloudQuery(id: "functions", group: "Functions", command: "firebase functions:list --project \(project) --json")]
        case "fly":
            guard let app = scope.app else { return [] }
            return [CloudQuery(id: "app", group: "App", command: "fly status -a \(app) --json"),
                    CloudQuery(id: "machines", group: "Machines", command: "fly machines list -a \(app) --json")]
        case "vercel":
            return [CloudQuery(id: "deployments", group: "Deployments", command: "vercel ls --format json")]
        default:
            return []
        }
    }

    // MARK: reading the answers

    /// The JSON of a CLI's output: warnings or banners may come before it.
    static func json(_ text: String) -> Any? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))
    }

    /// Only the fields listed here are ever read; environment variables and secrets that the CLIs also print are left alone.
    static func parse(_ query: CloudQuery, provider: String, scope: CloudScope, output: String, now: Date = Date()) -> [CloudService] {
        guard let root = json(output) else { return [] }
        switch (provider, query.id) {
        case ("firebase", "functions"): return firebaseFunctions(root, project: scope.project ?? "")
        case ("firebase", "hosting"): return firebaseChannels(root, project: scope.project ?? "", now: now)
        case ("fly", "app"): return flyApp(root, app: scope.app ?? "")
        case ("fly", "machines"): return flyMachines(root, app: scope.app ?? "", now: now)
        case ("vercel", "deployments"): return vercelDeployments(root, now: now)
        default: return []
        }
    }

    private static func firebaseResult(_ root: Any) -> Any? {
        if let object = root as? [String: Any] { return object["result"] ?? object }
        return root
    }

    private static func firebaseFunctions(_ root: Any, project: String) -> [CloudService] {
        guard let list = firebaseResult(root) as? [[String: Any]] else { return [] }
        let triggers = ["callableTrigger": "callable", "httpsTrigger": "https", "eventTrigger": "event", "scheduleTrigger": "scheduled",
                        "taskQueueTrigger": "task queue", "blockingTrigger": "blocking"]
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let trigger = triggers.first { item[$0.key] != nil }?.value ?? "function"
            var details = [trigger]
            if let runtime = item["runtime"] as? String { details.append(runtime) }
            if let region = item["region"] as? String { details.append(region) }
            if let memory = item["availableMemoryMb"] as? Int { details.append("\(memory) MB") }
            var s = CloudService(id: "fn:" + id, group: "Functions", name: id, details: details)
            if trigger == "https", let uri = item["uri"] as? String, uri.hasPrefix("https://") { s.openURL = uri }
            if !project.isEmpty { s.consoleURL = "https://console.firebase.google.com/project/\(project)/functions" }
            if isName(id), isName(project) { s.logCommand = "firebase functions:log --project \(project) --only \(id) --lines 100" }
            return s
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func firebaseChannels(_ root: Any, project: String, now: Date) -> [CloudService] {
        guard let object = firebaseResult(root) as? [String: Any], let channels = object["channels"] as? [[String: Any]] else { return [] }
        return channels.compactMap { channel in
            guard let name = channel["name"] as? String else { return nil }
            let parts = name.split(separator: "/").map(String.init)
            let channelID = parts.last ?? name
            let site = parts.firstIndex(of: "sites").flatMap { $0 + 1 < parts.count ? parts[$0 + 1] : nil } ?? ""
            var details: [String] = []
            if let updated = (channel["updateTime"] as? String).flatMap(date) { details.append("updated " + ago(updated, now: now)) }
            if let expires = (channel["expireTime"] as? String).flatMap(date) { details.append("expires " + (expires > now ? "in " + span(expires.timeIntervalSince(now)) : "— expired")) }
            else { details.append("never expires") }
            var s = CloudService(id: "ch:" + name, group: "Hosting", name: site.isEmpty ? channelID : "\(site) · \(channelID)", details: details)
            if let url = channel["url"] as? String, url.hasPrefix("https://") { s.openURL = url; s.probe = true }
            if isName(project), isName(site) { s.consoleURL = "https://console.firebase.google.com/project/\(project)/hosting/sites/\(site)" }
            return s
        }.sorted { $0.name < $1.name }
    }

    private static func flyApp(_ root: Any, app: String) -> [CloudService] {
        guard let object = root as? [String: Any], let name = object["Name"] as? String ?? (app.isEmpty ? nil : app) else { return [] }
        let status = (object["Status"] as? String ?? "").lowercased()
        var s = CloudService(id: "app:" + name, group: "App", name: name)
        s.state = status.isEmpty ? nil : status
        s.level = ["deployed", "running"].contains(status) ? .ok : ["pending", "suspended"].contains(status) ? .warn : status == "dead" ? .bad : .unknown
        if let host = object["Hostname"] as? String, !host.isEmpty { s.details.append(host); s.openURL = "https://" + host }
        if let version = object["Version"] as? Int { s.details.append("version \(version)") }
        if isName(name) {
            s.logCommand = "fly logs -a \(name) --no-tail"
            s.consoleURL = "https://fly.io/apps/\(name)"
        }
        return [s]
    }

    private static func flyMachines(_ root: Any, app: String, now: Date) -> [CloudService] {
        guard let list = root as? [[String: Any]] else { return [] }
        return list.compactMap { machine in
            guard let id = machine["id"] as? String else { return nil }
            let state = (machine["state"] as? String ?? "").lowercased()
            var level: CloudService.Level = state == "started" ? .ok : ["failed", "destroyed"].contains(state) ? .bad : ["starting", "stopping", "replacing"].contains(state) ? .warn : .unknown
            // A health check that complains makes a started machine a problem.
            for check in machine["checks"] as? [[String: Any]] ?? [] {
                switch (check["status"] as? String ?? "").lowercased() {
                case "critical": level = max(level, .bad)
                case "warning": level = max(level, .warn)
                default: break
                }
            }
            var details: [String] = []
            if let region = machine["region"] as? String { details.append(region) }
            if let image = (machine["image_ref"] as? [String: Any]).flatMap({ ($0["repository"] as? String).map { repo in repo.split(separator: "/").last.map(String.init) ?? repo } }) { details.append(image) }
            if let updated = (machine["updated_at"] as? String).flatMap(date) { details.append("updated " + ago(updated, now: now)) }
            var s = CloudService(id: "machine:" + id, group: "Machines", name: (machine["name"] as? String) ?? id, details: details)
            s.state = state.isEmpty ? nil : state
            s.level = level
            if isName(id), isName(app) { s.logCommand = "fly logs -a \(app) --machine \(id) --no-tail" }
            if isName(app) { s.consoleURL = "https://fly.io/apps/\(app)/machines/\(id)" }
            return s
        }.sorted { rank($0.level) != rank($1.level) ? rank($0.level) < rank($1.level) : $0.name < $1.name }
    }

    /// Problems first, then what runs, then what is quiet (a stopped machine is usually meant to be).
    private static func rank(_ level: Level) -> Int {
        switch level { case .bad: return 0; case .warn: return 1; case .ok: return 2; case .unknown: return 3 }
    }

    private static func vercelDeployments(_ root: Any, now: Date) -> [CloudService] {
        guard let object = root as? [String: Any], let list = object["deployments"] as? [[String: Any]] else { return [] }
        return list.prefix(20).compactMap { item in
            guard let host = item["url"] as? String, isName(host) else { return nil }
            let state = (item["state"] as? String ?? "").lowercased()
            let level: CloudService.Level = state == "ready" ? .ok : state == "error" ? .bad : ["building", "queued", "initializing"].contains(state) ? .warn : .unknown
            var details: [String] = []
            if let target = item["target"] as? String { details.append(target) } else { details.append("preview") }
            if let created = item["createdAt"] as? Double ?? (item["createdAt"] as? Int).map(Double.init) { details.append(ago(Date(timeIntervalSince1970: created / 1000), now: now)) }
            var s = CloudService(id: "dep:" + host, group: "Deployments", name: item["name"] as? String ?? host, details: details)
            s.state = state.isEmpty ? nil : state
            s.level = level
            s.openURL = "https://" + host
            s.logCommand = "vercel inspect \(host) --logs"
            return s
        }
    }

    // MARK: totals

    struct Total: Equatable {
        var group: String
        var count = 0, ok = 0, warn = 0, bad = 0
    }

    /// One line per group, in the order the groups first appear.
    static func totals(_ services: [CloudService]) -> [Total] {
        var out: [Total] = []
        for s in services {
            let index = out.firstIndex { $0.group == s.group } ?? { out.append(Total(group: s.group)); return out.count - 1 }()
            out[index].count += 1
            switch s.level {
            case .ok: out[index].ok += 1
            case .warn: out[index].warn += 1
            case .bad: out[index].bad += 1
            case .unknown: break
            }
        }
        return out
    }

    // MARK: reachability

    /// The badge for a site's answer: nothing came back, or the status code.
    static func probeResult(code: Int?, seconds: Double) -> (level: Level, state: String) {
        guard let code else { return (.bad, "unreachable") }
        let time = String(format: "%.1f s", seconds)
        if (200..<400).contains(code) { return (seconds > 3 ? .warn : .ok, "\(code) · \(time)") }
        return (code >= 500 ? .bad : .warn, "\(code)")
    }

    typealias Level = CloudService.Level

    // MARK: dates

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func span(_ seconds: TimeInterval) -> String {
        let s = max(seconds, 0)
        if s < 90 { return "\(Int(s)) s" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        if s < 36 * 3600 { return "\(Int((s / 3600).rounded())) h" }
        return "\(Int((s / 86400).rounded())) d"
    }

    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 45 ? "just now" : span(now.timeIntervalSince(date)) + " ago"
    }
}
