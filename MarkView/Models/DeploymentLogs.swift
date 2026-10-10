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

    /// A unit or container name that can sit in a command unquoted.
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-@:".unicodeScalars.contains($0) }
    }
}
