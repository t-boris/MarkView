import Foundation

/// Logs a person can read without setting anything up: what the machine says about itself, and one per
/// container and per service the environment names or the last look found. Foundation only, checked in
/// `tools/tests/deployment-logs-tests.sh`. Every command here is read-only (`CommandPolicy`).
enum DeploymentLogs {
    static let lines = 200

    /// Suggestions for an environment, given what the last look saw (nil before the first look).
    static func suggestions(for env: DeploymentEnvironment, snapshot: SystemSnapshot?) -> [LogSource] {
        guard env.kind != .cloud else { return [] }
        var out: [LogSource] = []
        func add(_ id: String, _ title: String, _ command: String) {
            if !out.contains(where: { $0.command == command }) { out.append(LogSource(id: id, title: title, command: command)) }
        }
        let darwin = env.kind == .local && (snapshot?.os ?? "Darwin") == "Darwin" || snapshot?.os == "Darwin"
        if darwin {
            add("auto-system", "System log (last 15 min)", "log show --last 15m --style compact | tail -n \(lines)")
        } else {
            add("auto-journal", "System journal", "journalctl -n \(lines) --no-pager")
            add("auto-errors", "Errors only", "journalctl -p err -n 100 --no-pager")
        }
        // Services named by checks, and failed ones.
        var units: [String] = env.checks.filter { $0.kind == .systemd }.map(\.target)
        units += snapshot?.failedUnits ?? []
        for unit in units where safeName(unit) { add("auto-unit-\(unit)", "Service \(unit)", "journalctl -u \(unit) -n \(lines) --no-pager") }
        // Containers: the ones seen, and the ones checked.
        var containers: [String] = env.checks.filter { $0.kind == .docker }.map(\.target)
        containers += snapshot?.containers.map(\.name) ?? []
        for name in containers where safeName(name) { add("auto-container-\(name)", "Container \(name)", "docker logs --tail \(lines) \(name)") }
        return out
    }

    /// The person's own sources first, then the suggestions that do not repeat them.
    static func all(for env: DeploymentEnvironment, snapshot: SystemSnapshot?) -> [LogSource] {
        let own = env.logSources
        return own + suggestions(for: env, snapshot: snapshot).filter { s in !own.contains { $0.command == s.command } }
    }

    /// The logs worth reading before answering `question` about this environment: errors first, then the
    /// failed services, the containers that are not up, those the question names (database, cache…), and the
    /// person's own sources; at most `limit`. The first look has to have happened for containers to be known.
    static func evidencePlan(question: String, env: DeploymentEnvironment, snapshot: SystemSnapshot?, limit: Int = 6) -> [LogSource] {
        let all = all(for: env, snapshot: snapshot)
        var chosen: [LogSource] = []
        func take(_ s: LogSource?) { if let s, !chosen.contains(where: { $0.command == s.command }), chosen.count < limit { chosen.append(s) } }
        let asked = question.lowercased()
        take(all.first { $0.id == "auto-errors" } ?? all.first { $0.id == "auto-system" })
        for unit in snapshot?.failedUnits ?? [] { take(all.first { $0.id == "auto-unit-\(unit)" }) }
        for container in snapshot?.containers ?? [] where !container.status.lowercased().hasPrefix("up") || container.status.lowercased().contains("unhealthy") {
            take(all.first { $0.id == "auto-container-\(container.name)" })
        }
        let words: [(String, [String])] = [("database", ["postgres", "mysql", "mariadb", "mongo", "db", "sql"]), ("db", ["postgres", "mysql", "mariadb", "mongo", "db", "sql"]),
                                           ("postgres", ["postgres"]), ("redis", ["redis"]), ("cache", ["redis", "memcache"]), ("proxy", ["nginx", "traefik", "caddy"]),
                                           ("web", ["nginx", "web", "app"]), ("auth", ["auth", "gotrue", "keycloak"])]
        for (word, needles) in words where asked.contains(word) {
            for container in snapshot?.containers ?? [] where needles.contains(where: { (container.name + " " + container.image).lowercased().contains($0) }) {
                take(all.first { $0.id == "auto-container-\(container.name)" })
            }
        }
        for own in env.logSources.prefix(2) { take(own) }
        // Nothing stands out: the journal and the first containers.
        for s in all where chosen.count < 3 { take(s) }
        return chosen
    }

    /// A unit or container name that can sit in a command unquoted.
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-@:".unicodeScalars.contains($0) }
    }
}
