import AppKit
import Foundation
import MarkViewCore

/// "Connect Agents to MarkView…": registers `MarkView --mcp-browser` and `MarkView --mcp-project` — without
/// window arguments, so they find the window through their parent processes — in each installed agent's own
/// configuration. Honors each agent's per-service MCP selections (`DEC-005`): only enabled MarkView services
/// are registered, disabled services are skipped and reported without altering saved selections, and skipped
/// services never become available through registration on a subsequent launch.
enum AgentBrowserRegistration {
    struct Outcome: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case registered
            case skipped
            case failed
        }

        var agent: String
        var status: Status
        var detail: String

        var ok: Bool { status == .registered }
        var isSkipped: Bool { status == .skipped }

        init(agent: String, status: Status, detail: String) {
            self.agent = agent
            self.status = status
            self.detail = detail
        }

        init(agent: String, ok: Bool, detail: String) {
            self.agent = agent
            self.status = ok ? .registered : .failed
            self.detail = detail
        }
    }

    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async -> CLIToolLocator.RunResult

    /// The servers of this binary an agent can use: the browser tools and the project tools.
    static let servers = [
        AgentMCPServer(name: BrowserAgentTools.serverName, tomlName: AgentMCPServer.markviewBrowserTomlName, flag: "--mcp-browser", label: "browser"),
        AgentMCPServer(name: ProjectAgentTools.serverName, tomlName: ProjectAgentTools.serverName, flag: "--mcp-project", label: "project"),
    ]

    /// Register enabled MarkView services for every installed agent; off the main thread.
    /// Disabled services are skipped without modifying saved selections or the agent's configuration.
    static func registerAll(
        executable: String,
        env: AgentMCPEnvironment = .standard,
        runCommand: @escaping CommandRunner = { path, args in await CLIToolLocator.run(path, args, timeout: 30) }
    ) async -> [Outcome] {
        AgentMCPServices.migrateAllIfNeeded(env: env)
        var outcomes: [Outcome] = []
        for server in servers {
            let suffix = " (\(server.label) tools)"
            for tool in CLITool.allCases {
                guard let registration = tool.provider.mcp else { continue }
                // An agent that is not found is reported, not skipped silently (BUG-026).
                guard let path = env.resolveExecutable(tool) else {
                    if server.flag == "--mcp-browser" {
                        outcomes.append(Outcome(agent: tool.displayName, status: .failed,
                                                detail: "not found — set its path in Settings (⌘⇧,) and connect again"))
                    }
                    continue
                }
                guard AgentMCPServices.isEnabled(server.name, for: tool, env: env) else {
                    outcomes.append(Outcome(
                        agent: tool.displayName + suffix,
                        status: .skipped,
                        detail: "skipped — \"\(server.name)\" is disabled for \(tool.displayName)"
                    ))
                    continue
                }
                switch registration {
                case .commands(let commands):
                    _ = await runCommand(path, commands.remove(server))
                    let result = await runCommand(path, commands.add(server, executable))
                    let failure = commands.reportsStdoutOnFailure ? result.stderr + result.stdout : result.stderr
                    outcomes.append(Outcome(agent: tool.displayName + suffix, ok: result.exitCode == 0,
                                            detail: result.exitCode == 0 ? commands.location : failure.trimmingCharacters(in: .whitespacesAndNewlines)))
                case .jsonFile(let file):
                    let targetFile = file.file(in: env.homeDirectory)
                    outcomes.append(addServer(file.entry(executable, server), to: targetFile, agent: tool.displayName + suffix, name: server.name))
                }
            }
        }
        return outcomes
    }

    /// An assistant with no per-session MCP option (Cline, Antigravity): make sure its own settings list only the
    /// enabled MarkView servers with this copy of MarkView before it starts (BUG-026, DEC-005). Disabled servers are
    /// never added or re-enabled.
    static func ensureRegistered(
        _ tool: CLITool,
        executable: String,
        servers enabledServers: [AgentMCPServer]? = nil,
        env: AgentMCPEnvironment = .standard
    ) {
        let targetServers = enabledServers ?? AgentMCPServices.enabledServers(from: Self.servers, for: tool, env: env)
        guard !targetServers.isEmpty else { return }
        switch tool.provider.mcp {
        case .commands(let commands)?:
            guard let list = commands.list, let path = env.resolveExecutable(tool) else { return }
            // task: one registration with an agent's CLI at launch; it holds nothing of a window
            Task.detached(priority: .userInitiated) {
                let listed = await CLIToolLocator.run(path, list, timeout: 30)
                let text = listed.stdout + listed.stderr
                for server in targetServers where !(text.contains(server.name) && text.contains(executable)) {
                    guard AgentMCPServices.isEnabled(server.name, for: tool, env: env) else { continue }
                    _ = await CLIToolLocator.run(path, commands.remove(server), timeout: 30)
                    let result = await CLIToolLocator.run(path, commands.add(server, executable), timeout: 30)
                    AppLog.browser.notice("\(tool.displayName) \(server.label) tools: \(result.exitCode == 0 ? "registered" : "not registered")")
                }
            }
        case .jsonFile(let file)? where file.checkedAtStart:
            let targetFile = file.file(in: env.homeDirectory)
            DispatchQueue.global(qos: .userInitiated).async {
                let settings = (try? Data(contentsOf: targetFile)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                for server in targetServers {
                    guard AgentMCPServices.isEnabled(server.name, for: tool, env: env) else { continue }
                    if let entry = (settings?["mcpServers"] as? [String: Any])?[server.name] as? [String: Any], file.isCurrent(entry, executable) {
                        continue
                    }
                    let outcome = addServer(file.entry(executable, server), to: targetFile, agent: tool.displayName, name: server.name)
                    AppLog.browser.notice("\(tool.displayName) \(server.label) tools: \(outcome.ok ? "registered" : "not registered: " + outcome.detail)")
                }
            }
        default:
            return
        }
    }

    /// Put `entry` under `mcpServers[name]` of a JSON settings file, keeping the rest.
    static func addServer(_ entry: [String: Any], to file: URL, agent: String, name: String = BrowserAgentTools.serverName) -> Outcome {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return Outcome(agent: agent, status: .failed, detail: "\(file.path) is not a JSON object; left unchanged")
            }
            root = object
        }
        root = BrowserAgentTools.withServer(entry, in: root, name: name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try AtomicFile.write(data, to: file)
            return Outcome(agent: agent, status: .registered, detail: file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        } catch {
            return Outcome(agent: agent, status: .failed, detail: error.localizedDescription)
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
                return Outcome(agent: agent + " (skill)", status: .registered, detail: "~/" + path)
            } catch {
                return Outcome(agent: agent + " (skill)", status: .failed, detail: error.localizedDescription)
            }
        }
    }

    /// Format outcomes for presentation after Connect Agents, explicitly highlighting skipped disabled services.
    static func formatSummary(_ outcomes: [Outcome]) -> (title: String, detail: String) {
        let registered = outcomes.filter { $0.status == .registered }
        let skipped = outcomes.filter { $0.status == .skipped }
        let title: String
        if !registered.isEmpty {
            title = "Agents connected to MarkView"
        } else if !skipped.isEmpty {
            title = "All MarkView MCP services were skipped"
        } else {
            title = "No agent was connected"
        }
        let lines = outcomes.map { outcome -> String in
            let symbol: String
            switch outcome.status {
            case .registered: symbol = "✓"
            case .skipped: symbol = "⊘"
            case .failed: symbol = "✗"
            }
            return "\(symbol) \(outcome.agent) — \(outcome.detail)"
        }
        var body = lines.joined(separator: "\n")
        if !skipped.isEmpty {
            body += "\n\nSkipped services remain disabled in your per-agent MCP settings and were not registered."
        }
        body += "\n\nAgents already running pick up changes when restarted. In a MarkView terminal, "
            + "`/Applications/MarkView.app/Contents/MacOS/MarkView --mcp-browser --diagnose` checks the connection."
        return (title, body)
    }

    /// The menu command: explain, confirm, register, report.
    @MainActor
    static func connectInteractively(prompts: any UserPrompts) {
        guard let executable = Bundle.main.executablePath else { return }
        let connect = UserPrompt(title: "Connect agents to MarkView?", detail: """
        Claude Code, Codex, Copilot, Cline and Antigravity (those installed) get only the enabled MarkView tool sets \
        in their own settings: "markview-browser" (drive this window's browser tabs) and "markview" (read and extend \
        the project's features, bugs and prototypes, written by MarkView in its own format, only in the window's project). \
        Services you disabled for an agent are skipped and kept disabled. They work when MarkView is running; otherwise \
        the tools stay hidden.

        Where an organisation does not allow MCP servers (Copilot at work, for one), the same tools work through \
        a Skill: a markview/SKILL.md in each installed agent's skills folder, which tells the agent to call \
        `MarkView --project-call`.

        Claude Code: user-scope MCP server · Codex: ~/.codex/config.toml · Copilot: ~/.copilot/mcp-config.json · \
        Cline: its MCP settings · Antigravity: agy mcp. Manage individual services anytime from the globe menu or DDE Settings.
        """, buttons: ["Connect", "Cancel"])
        guard prompts.confirm(connect, proceedingWith: 0) else { return }
        // task: one registration the person asked for, which shows its own result
        Task {
            let outcomes = await registerAll(executable: executable) + installSkills(executable: executable)
            AgentMCPServicesStore.shared.reloadFromFiles()
            let summary = formatSummary(outcomes)
            prompts.inform(summary.title, summary.detail)
        }
    }
}
