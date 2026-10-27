import Foundation

/// Generates per-run CLI configuration without changing either provider's global settings.
/// The home login remains owned by the provider CLI. Home native tools are blocked, not merely
/// discouraged by a prompt, so a missing MCP connection cannot become a home-disk operation.
enum RemoteProviderConfiguration {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case claude, codex
        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code" : "Codex" }
    }

    static func command(provider: Provider, executable: String, app: String, socket: String,
                        context: RemoteJSON, directory: URL, model: String?, resume: Bool) throws -> String {
        let server: RemoteJSON = .object(["command": .string(app),
            "args": .array([.string("--remote-workspace-mcp"), .string("--socket"), .string(socket)])])
        let mcp = RemoteJSON.object(["mcpServers": .object([RemoteWorkspaceTools.serverName: server])])
        let config = directory.appendingPathComponent("mcp.json")
        try write(mcp, to: config)
        let guardCommand = quote(app) + " --remote-workspace-guard"
        let hooks: RemoteJSON = .object(["PreToolUse": .array([.object([
            "matcher": .string(".*"), "hooks": .array([.object([
                "type": .string("command"), "command": .string(guardCommand), "timeout": .int(5)])])])])])
        let environment = String(data: try JSONEncoder().encode(context), encoding: .utf8)!
        let instructions = """
        \(RemoteWorkspaceTools.instructions)

        Actual execution environment (authoritative; the CLI transport's own cwd is NOT the project):
        \(environment)

        Begin by using workspace_info and reading the project's instructions on the work computer.
        """
        var args: [String] = []
        if provider == .claude {
            let settings = directory.appendingPathComponent("claude-settings.json")
            try write(.object(["hooks": hooks]), to: settings)
            args = ["--tools", "", "--strict-mcp-config", "--mcp-config", config.path,
                    "--settings", settings.path, "--setting-sources", "", "--append-system-prompt", instructions,
                    "--allowedTools", RemoteWorkspaceTools.toolPrefix + "*", "--dangerously-skip-permissions"]
            if resume { args.insert("--continue", at: 0) }
        } else {
            func override(_ key: String, _ value: String) { args += ["-c", key + "=" + value] }
            args = ["--no-daemon", "--dangerously-bypass-hook-trust", "--sandbox", "read-only", "--ask-for-approval", "never"]
            for name in ["shell_tool", "view_image", "multi_agent", "apps", "plugins", "computer_use", "browser_use", "image_generation"] {
                override("features." + name, "false")
            }
            override("features.hooks", "true")
            override("features.non_prefixed_mcp_tool_names", "false")
            override("features.skip_host_skill_discovery", "true")
            let serverKey = "mcp_servers." + RemoteWorkspaceTools.serverName
            override(serverKey + ".command", toml(app))
            override(serverKey + ".args", "[" + ["--remote-workspace-mcp", "--socket", socket].map(toml).joined(separator: ",") + "]")
            override(serverKey + ".tool_timeout_sec", "120")
            override(serverKey + ".required", "true")
            override(serverKey + ".default_tools_approval_mode", toml("approve"))
            override("developer_instructions", toml(instructions))
            override("hooks.PreToolUse", "[{matcher=\".*\",hooks=[{type=\"command\",command=" + toml(guardCommand) + ",timeout=5}]}]")
            if resume { args += ["resume", "--last"] }
        }
        if let model, !model.isEmpty { args += ["--model", model] }
        return ([executable] + args).map(quote).joined(separator: " ")
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func toml(_ text: String) -> String {
        // JSON string escaping is also valid for TOML basic strings.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(text), encoding: .utf8)!
    }
    private static func write(_ value: RemoteJSON, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
