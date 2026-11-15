import Foundation

/// GitHub Copilot CLI 1.x (`copilot`), driven over the Agent Client Protocol (`ACPAssistant`).
struct CopilotProvider: AssistantProvider, AssistantACPSupport {
    let id = "copilot"
    let displayName = "Copilot"
    let binaryName = "copilot"
    let authStatusArgs: [String] = []
    let loginCommand = "login"
    let fullAccessArgs = ["--allow-all"]
    let continueArgs = ["--continue"]
    let terminalIcon = "airplane"
    var activity: (any AssistantActivitySupport)? { CopilotActivity() }
    /// An organisation's policy may allow only listed MCP servers; Copilot then says so at every start (BUG-025).
    let reportsMCPPolicyBlock = true

    func goalPrompt(_ objective: String, closing: String) -> String { "/autopilot \(objective)" }

    var acp: (any AssistantACPSupport)? { self }

    func modelOptions() -> [AIModelOption] {
        [AIModelOption(id: "", name: "Default", detail: "Copilot's configured model")] + ACPModelCache.cached(id)
    }

    func launchProfile(effort: String?) -> ACPLaunchProfile {
        // Only these tools exist for the model: no shell, no edits, no web, no subagents.
        var arguments = ["--acp", "--no-auto-update", "--no-ask-user", "--disable-builtin-mcps",
                         "--no-custom-instructions"]
        if let effort { arguments += ["--reasoning-effort", effort] }
        arguments += ["--available-tools", "view", "grep", "glob"]
        return ACPLaunchProfile(arguments: arguments, readOnlyMode: nil, noticePrefix: "Info: Disabled tools:")
    }

    /// Copilot lists models per account, so a list means signed in.
    var probe: ACPProbeProfile {
        ACPProbeProfile(minimumMajorVersion: 1, installCommand: "npm i -g @github/copilot@latest",
                        silentExitMessage: nil, modelListImpliesSignedIn: true)
    }

    func mcpLaunchArguments(for servers: [AgentMCPServer], quote: (String) -> String) -> [String]? {
        let config: [String: Any] = ["mcpServers": Dictionary(uniqueKeysWithValues: servers.map {
            ($0.name, ["type": "local", "command": $0.command, "args": $0.args, "tools": ["*"]] as [String: Any]) })]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["--additional-mcp-config", quote(json)]
    }

    /// An entry in `~/.copilot/mcp-config.json`, written by Connect Agents (a terminal gets its servers per session).
    var mcp: AssistantMCPRegistration? {
        .jsonFile(.init(
            file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/mcp-config.json"),
            entry: { executable, server in ["type": "local", "command": executable, "args": [server.flag], "tools": ["*"]] },
            isCurrent: { _, _ in true },
            checkedAtStart: false))
    }

    let skillPath: String? = ".copilot/skills/markview/SKILL.md"
}

// MARK: - Activity

/// What Copilot is doing: the last finished turn of the folder in `~/.copilot/session-store.db`.
struct CopilotActivity: AssistantActivitySupport {
    func read(_ request: ActivityRequest) -> ActivityRead? {
        guard let turn = AgentActivityLog.copilotTurn(directory: request.directory) else { return nil }
        return ActivityRead(source: request.directory, size: 0, date: Date(),
                            activity: AgentActivityParser.copilot(userMessage: turn.user, response: turn.response, busy: request.printing))
    }
}
