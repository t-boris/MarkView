import AppKit
import Foundation
import MarkViewCore

/// "Connect Agents to MarkView's Browser…" (Task 82): registers `MarkView --mcp-browser` — without
/// arguments, so it finds the window through its parent processes — in each installed agent's own
/// configuration. Agents then get the browser tools even when started by hand in any MarkView
/// terminal; outside MarkView the server offers no tools. How each assistant takes a server (its own `mcp add`
/// command, or one entry in a JSON settings file whose other content is kept) is described by its provider
/// (`AssistantProvider.mcp`); this file only carries it out.
enum AgentBrowserRegistration {
    struct Outcome {
        var agent: String
        var ok: Bool
        var detail: String
    }

    /// The servers of this binary an agent can use: the browser tools and the project tools.
    static let servers = [
        AgentMCPServer(name: BrowserAgentTools.serverName, tomlName: "markview_browser", flag: "--mcp-browser", label: "browser"),
        AgentMCPServer(name: ProjectAgentTools.serverName, tomlName: ProjectAgentTools.serverName, flag: "--mcp-project", label: "project"),
    ]

    /// Register for every agent that is installed; off the main thread.
    static func registerAll(executable: String) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for server in servers {
            let suffix = " (\(server.label) tools)"
            for tool in CLITool.allCases {
                guard let registration = tool.provider.mcp else { continue }
                // An agent that is not found is reported, not skipped silently (BUG-026).
                guard let path = CLIToolLocator.resolve(tool) else {
                    if server.flag == "--mcp-browser" {
                        outcomes.append(Outcome(agent: tool.displayName, ok: false,
                                                detail: "not found — set its path in Settings (⌘⇧,) and connect again"))
                    }
                    continue
                }
                switch registration {
                case .commands(let commands):
                    _ = await CLIToolLocator.run(path, commands.remove(server), timeout: 30)
                    let result = await CLIToolLocator.run(path, commands.add(server, executable), timeout: 30)
                    let failure = commands.reportsStdoutOnFailure ? result.stderr + result.stdout : result.stderr
                    outcomes.append(Outcome(agent: tool.displayName + suffix, ok: result.exitCode == 0,
                                            detail: result.exitCode == 0 ? commands.location : failure.trimmingCharacters(in: .whitespacesAndNewlines)))
                case .jsonFile(let file):
                    outcomes.append(addServer(file.entry(executable, server), to: file.file, agent: tool.displayName + suffix, name: server.name))
                }
            }
        }
        return outcomes
    }

    /// An assistant with no per-session MCP option (Cline, Antigravity): make sure its own settings list the servers with
    /// this copy of MarkView before it starts (BUG-026). Only what is missing or points at another copy of MarkView is
    /// written (outside MarkView terminals the servers offer no tools); off the main thread.
    static func ensureRegistered(_ tool: CLITool, executable: String) {
        switch tool.provider.mcp {
        case .commands(let commands)?:
            guard let list = commands.list, let path = CLIToolLocator.resolve(tool) else { return }
            Task.detached(priority: .userInitiated) {
                let listed = await CLIToolLocator.run(path, list, timeout: 30)
                let text = listed.stdout + listed.stderr
                for server in servers where !(text.contains(server.name) && text.contains(executable)) {
                    _ = await CLIToolLocator.run(path, commands.remove(server), timeout: 30)
                    let result = await CLIToolLocator.run(path, commands.add(server, executable), timeout: 30)
                    AppLog.browser.notice("\(tool.displayName) \(server.label) tools: \(result.exitCode == 0 ? "registered" : "not registered")")
                }
            }
        case .jsonFile(let file)? where file.checkedAtStart:
            DispatchQueue.global(qos: .userInitiated).async {
                let settings = (try? Data(contentsOf: file.file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                for server in servers {
                    if let entry = (settings?["mcpServers"] as? [String: Any])?[server.name] as? [String: Any], file.isCurrent(entry, executable) {
                        continue
                    }
                    let outcome = addServer(file.entry(executable, server), to: file.file, agent: tool.displayName, name: server.name)
                    AppLog.browser.notice("\(tool.displayName) \(server.label) tools: \(outcome.ok ? "registered" : "not registered: " + outcome.detail)")
                }
            }
        default:
            return
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
            try AtomicFile.write(data, to: file)
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
        let targets: [(String, Bool, String)] = CLITool.allCases.compactMap { tool in
            tool.provider.skillPath.map { (tool.displayName, CLIToolLocator.resolve(tool) != nil, $0) }
        }
        return targets.filter(\.1).map { agent, _, path in
            let file = home.appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AtomicFile.write(Data(text.utf8), to: file)
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
        Claude Code, Codex, Copilot, Cline and Antigravity (those installed) get two tool sets in their own settings: \
        "markview-browser" (drive this window's browser tabs) and "markview" (read and extend the project's \
        features, bugs and prototypes, written by MarkView in its own format, only in the window's project). \
        They work when MarkView is running; otherwise the tools stay hidden.

        Where an organisation does not allow MCP servers (Copilot at work, for one), the same tools work through \
        a Skill: a markview/SKILL.md in each installed agent's skills folder, which tells the agent to call \
        `MarkView --project-call`.

        Claude Code: user-scope MCP server · Codex: ~/.codex/config.toml · Copilot: ~/.copilot/mcp-config.json · \
        Cline: its MCP settings · Antigravity: agy mcp. Remove the servers later with each agent's "mcp remove" and delete the \
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
