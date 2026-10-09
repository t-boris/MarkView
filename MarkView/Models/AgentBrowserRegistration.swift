import AppKit
import Foundation

/// "Connect Agents to MarkView's Browser…" (Task 82): registers `MarkView --mcp-browser` — without
/// arguments, so it finds the window through its parent processes — in each installed agent's own
/// configuration. Agents then get the browser tools even when started by hand in any MarkView
/// terminal; outside MarkView the server offers no tools. Claude Code and Codex are registered with
/// their own `mcp add` commands, Copilot and Cline by adding one entry to their JSON settings
/// (everything else in those files is kept).
enum AgentBrowserRegistration {
    struct Outcome {
        var agent: String
        var ok: Bool
        var detail: String
    }

    static let copilotConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/mcp-config.json")
    static let clineConfig = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cline/data/settings/cline_mcp_settings.json")

    /// The servers of this binary an agent can use: the browser tools and the project tools.
    struct Server {
        let name: String
        let codexName: String
        let flag: String
        let label: String
    }

    static let servers = [
        Server(name: BrowserAgentTools.serverName, codexName: "markview_browser", flag: "--mcp-browser", label: "browser"),
        Server(name: ProjectAgentTools.serverName, codexName: ProjectAgentTools.serverName, flag: "--mcp-project", label: "project"),
    ]

    /// Register for every agent that is installed; off the main thread.
    static func registerAll(executable: String) async -> [Outcome] {
        var outcomes: [Outcome] = []
        // An agent that is not found is reported, not skipped silently (BUG-026).
        let missing = { (agent: String) in Outcome(agent: agent, ok: false, detail: "not found — set its path in Settings (⌘⇧,) and connect again") }
        let claude = CLIToolLocator.resolve(.claude), codex = CLIToolLocator.resolve(.codex)
        let copilot = CLIToolLocator.resolve(.copilot) != nil, cline = CLIToolLocator.resolve(.cline) != nil
        for server in servers {
            let suffix = " (\(server.label) tools)"
            if let claude {
                _ = await CLIToolLocator.run(claude, ["mcp", "remove", "--scope", "user", server.name], timeout: 30)
                let result = await CLIToolLocator.run(claude, ["mcp", "add", "--scope", "user", server.name, "--", executable, server.flag], timeout: 30)
                outcomes.append(Outcome(agent: "Claude Code" + suffix, ok: result.exitCode == 0,
                                        detail: result.exitCode == 0 ? "user scope" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if server.flag == "--mcp-browser" { outcomes.append(missing("Claude Code")) }
            if let codex {
                _ = await CLIToolLocator.run(codex, ["mcp", "remove", server.codexName], timeout: 30)
                let result = await CLIToolLocator.run(codex, ["mcp", "add", server.codexName, "--", executable, server.flag], timeout: 30)
                outcomes.append(Outcome(agent: "Codex" + suffix, ok: result.exitCode == 0,
                                        detail: result.exitCode == 0 ? "~/.codex/config.toml" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if server.flag == "--mcp-browser" { outcomes.append(missing("Codex")) }
            if copilot {
                let entry: [String: Any] = ["type": "local", "command": executable, "args": [server.flag], "tools": ["*"]]
                outcomes.append(addServer(entry, to: copilotConfig, agent: "Copilot" + suffix, name: server.name))
            } else if server.flag == "--mcp-browser" { outcomes.append(missing("Copilot")) }
            if cline {
                outcomes.append(addServer(clineEntry(executable: executable, flag: server.flag), to: clineConfig, agent: "Cline" + suffix, name: server.name))
            } else if server.flag == "--mcp-browser" { outcomes.append(missing("Cline")) }
        }
        return outcomes
    }

    static func clineEntry(executable: String, flag: String = "--mcp-browser") -> [String: Any] {
        ["transport": ["type": "stdio", "command": executable, "args": [flag]] as [String: Any],
         "disabled": false, "autoApprove": [String](), "timeout": 120]
    }

    /// BUG-026: Cline has no per-session MCP option, so a Cline started from the AI panel had no
    /// browser tools until "Connect Agents…" was run on that Mac. Before it starts, make sure its
    /// settings list the server (outside MarkView terminals the server offers no tools). Writes only
    /// when the entry is missing or points at another copy of MarkView; off the main thread.
    static func ensureCline(executable: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let settings = (try? Data(contentsOf: clineConfig)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            for server in servers {
                if let entry = (settings?["mcpServers"] as? [String: Any])?[server.name] as? [String: Any],
                   let transport = entry["transport"] as? [String: Any], transport["command"] as? String == executable,
                   entry["disabled"] as? Bool != true {
                    continue
                }
                let outcome = addServer(clineEntry(executable: executable, flag: server.flag), to: clineConfig, agent: "Cline", name: server.name)
                NSLog("[MarkView] Cline \(server.label) tools: \(outcome.ok ? "registered" : "not registered: " + outcome.detail)")
            }
        }
    }

    /// Put `entry` under `mcpServers["markview-browser"]` of a JSON settings file, keeping the rest.
    static func addServer(_ entry: [String: Any], to file: URL, agent: String, name: String = BrowserAgentTools.serverName) -> Outcome {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return Outcome(agent: agent, ok: false, detail: "\(file.path) is not a JSON object; left unchanged")
            }
            root = object
        }
        root = BrowserAgentTools.withServer(entry, in: root, name: name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            return Outcome(agent: agent, ok: true, detail: file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        } catch {
            return Outcome(agent: agent, ok: false, detail: error.localizedDescription)
        }
    }

    /// The Skill (`SKILL.md`) for agents that cannot use MCP servers: it teaches them MarkView's features and bugs and the
    /// `--project-call` command. One folder per agent that is installed; Cline has no skills folder.
    static func installSkills(executable: String) -> [Outcome] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let text = ProjectAgentTools.skillText(executable: executable)
        let targets: [(String, Bool, String)] = [
            ("Claude Code", CLIToolLocator.resolve(.claude) != nil, ".claude/skills/markview/SKILL.md"),
            ("Copilot", CLIToolLocator.resolve(.copilot) != nil, ".copilot/skills/markview/SKILL.md"),
            ("Codex", CLIToolLocator.resolve(.codex) != nil, ".codex/skills/markview/SKILL.md"),
        ]
        return targets.filter(\.1).map { agent, _, path in
            let file = home.appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file, options: .atomic)
                return Outcome(agent: agent + " (skill)", ok: true, detail: "~/" + path)
            } catch {
                return Outcome(agent: agent + " (skill)", ok: false, detail: error.localizedDescription)
            }
        }
    }

    /// The menu command: explain, confirm, register, report.
    @MainActor
    static func connectInteractively() {
        guard let executable = Bundle.main.executablePath else { return }
        let ask = NSAlert()
        ask.messageText = "Connect agents to MarkView?"
        ask.informativeText = """
        Claude Code, Codex, Copilot and Cline (those installed) get two tool sets in their own settings: \
        "markview-browser" (drive this window's browser tabs) and "markview" (read and extend the project's \
        features, bugs and prototypes, written by MarkView in its own format, only in the window's project). \
        They work when MarkView is running; otherwise the tools stay hidden.

        Where an organisation does not allow MCP servers (Copilot at work, for one), the same tools work through \
        a Skill: a markview/SKILL.md in each installed agent's skills folder, which tells the agent to call \
        `MarkView --project-call`.

        Claude Code: user-scope MCP server · Codex: ~/.codex/config.toml · Copilot: ~/.copilot/mcp-config.json · \
        Cline: its MCP settings. Remove the servers later with each agent's "mcp remove" and delete the \
        markview skill folders.
        """
        ask.addButton(withTitle: "Connect")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let outcomes = await registerAll(executable: executable) + installSkills(executable: executable)
            let report = NSAlert()
            report.messageText = outcomes.contains(where: \.ok) ? "Agents connected to MarkView" : "No agent was connected"
            report.informativeText = outcomes.map { "\($0.ok ? "✓" : "✗") \($0.agent) — \($0.detail)" }.joined(separator: "\n")
                + "\n\nAgents already running pick it up when restarted. In a MarkView terminal, "
                + "`/Applications/MarkView.app/Contents/MacOS/MarkView --mcp-browser --diagnose` checks the connection."
            report.runModal()
        }
    }
}
