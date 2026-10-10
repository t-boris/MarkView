import Foundation

/// The app side of `DeploymentAgentTools`, for the Deployments of one window.
@MainActor
enum DeploymentToolRunner {
    static let outputLimit = 40_000

    static func run(_ tool: String, _ args: [String: Any], store: DeploymentStore) async -> BrowserAgentTools.Reply {
        guard store.root != nil else { return .error("This window has no project folder open.") }
        do {
            switch tool {
            case "markview_deployments":
                return .init(text: clip(store.report() + suggestionsNote(store)))
            case "markview_deployments_propose":
                return try propose(args, store: store)
            case "markview_deployments_status":
                let id = try environmentID(args, store: store)
                await store.refresh(id)
                return .init(text: clip(store.report(for: id)))
            case "markview_deployments_run":
                let id = try environmentID(args, store: store)
                let command = try ProjectAgentTools.text(args, "command", required: true)
                let purpose = try ProjectAgentTools.text(args, "purpose")
                let outcome = await store.run(command, on: id, origin: "The assistant", purpose: purpose)
                return .init(text: clip(outcome.summary))
            case "markview_deployments_logs":
                let id = try environmentID(args, store: store)
                let sourceID = try ProjectAgentTools.text(args, "source", required: true)
                guard let source = store.environment(id)?.logSources.first(where: { $0.id == sourceID }) else {
                    let known = store.environment(id)?.logSources.map(\.id).joined(separator: ", ") ?? ""
                    throw ProjectAgentTools.Invalid(message: "No log source \"\(sourceID)\" on \(id)." + (known.isEmpty ? " It has none; use markview_deployments_run with a read-only command." : " Log sources: \(known)"))
                }
                let outcome = await store.run(source.command, on: id, origin: "The assistant", purpose: "Show the log \"\(source.title)\"")
                var text = outcome.summary
                if case .ran = outcome, let lines = args["lines"] as? Int, lines > 0 {
                    let all = text.split(separator: "\n", omittingEmptySubsequences: false)
                    text = all.suffix(lines + 1).joined(separator: "\n")
                }
                return .init(text: clip(text))
            default:
                return .error("Unknown tool \(tool).")
            }
        } catch let invalid as ProjectAgentTools.Invalid {
            return .error(invalid.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func clip(_ text: String) -> String {
        text.count <= outputLimit ? text : String(text.suffix(outputLimit)) + "\n… (the start was cut)"
    }

    private static func suggestionsNote(_ store: DeploymentStore) -> String {
        store.suggestions.isEmpty ? "" : "\n\nProposed, waiting for the person: " + store.suggestions.map(\.name).joined(separator: ", ")
    }

    private static func environmentID(_ args: [String: Any], store: DeploymentStore) throws -> String {
        let id = try ProjectAgentTools.text(args, "environment", required: true)
        guard store.environment(id) != nil else {
            let known = store.environments.map(\.id).joined(separator: ", ")
            throw ProjectAgentTools.Invalid(message: "No environment \"\(id)\"." + (known.isEmpty ? " None is set up yet: propose one with markview_deployments_propose." : " Environments: \(known)"))
        }
        return id
    }

    private static func objects(_ args: [String: Any], _ key: String) -> [[String: String]] {
        (args[key] as? [[String: Any]] ?? []).prefix(30).map { $0.compactMapValues { $0 as? String } }
    }

    private static func propose(_ args: [String: Any], store: DeploymentStore) throws -> BrowserAgentTools.Reply {
        let name = try ProjectAgentTools.text(args, "name", required: true)
        guard let kind = DeploymentEnvironment.Kind(rawValue: try ProjectAgentTools.text(args, "kind", required: true)) else {
            throw ProjectAgentTools.Invalid(message: "kind must be ssh, local or cloud.")
        }
        var s = DeploymentSuggestion(id: DeploymentEnvironment.slug(name), name: name, kind: kind)
        s.host = try ProjectAgentTools.text(args, "host")
        s.user = try ProjectAgentTools.text(args, "user")
        s.port = args["port"] as? Int ?? 22
        s.identityFile = try ProjectAgentTools.text(args, "identity_file")
        s.provider = try ProjectAgentTools.text(args, "provider")
        s.evidence = try ProjectAgentTools.list(args, "evidence")
        let notes = try ProjectAgentTools.text(args, "notes")
        if !notes.isEmpty { s.missing = [notes] }
        s.confidence = 75
        s.checks = objects(args, "checks").enumerated().compactMap { index, o in
            guard let kind = DeploymentCheck.Kind(rawValue: o["kind"] ?? ""), let target = o["target"], !target.isEmpty else { return nil }
            return DeploymentCheck(id: "check-\(index + 1)", title: o["title"] ?? "", kind: kind, target: target, expect: o["expect"] ?? "")
        }
        s.logSources = objects(args, "log_sources").enumerated().compactMap { index, o in
            guard let command = o["command"], !command.isEmpty else { return nil }
            return LogSource(id: "log-\(index + 1)", title: o["title"] ?? "Log \(index + 1)", command: command)
        }
        s.cloudCommands = objects(args, "cloud_commands").enumerated().compactMap { index, o in
            guard let command = o["command"], !command.isEmpty else { return nil }
            return CloudCommand(id: "cmd-\(index + 1)", title: o["title"] ?? "Command \(index + 1)", command: command)
        }
        if let problem = secretLooking(in: [s.host, s.user, s.identityFile, s.provider, notes] + s.evidence + s.checks.map(\.target) + s.logSources.map(\.command) + s.cloudCommands.map(\.command)) {
            throw ProjectAgentTools.Invalid(message: "Not saved: \(problem) Never put secrets into a proposal.")
        }
        store.propose(s)
        return .init(text: "Proposed \"\(name)\". It is in the Deployments tab under \"Found in the project\"; the person adds it, and fills in what is missing (\(notes.isEmpty ? "nothing noted" : notes)). You can look at it with markview_deployments_status once it is added.")
    }

    /// A password or key pasted by mistake.
    static func secretLooking(in values: [String]) -> String? {
        let patterns = [#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, #"(?i)\b(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*\S{6,}"#, #"\bAKIA[0-9A-Z]{16}\b"#, #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, #"\bsk-[A-Za-z0-9]{20,}\b"#]
        for value in values {
            for pattern in patterns where value.range(of: pattern, options: .regularExpression) != nil { return "a value looks like a secret." }
        }
        return nil
    }
}
