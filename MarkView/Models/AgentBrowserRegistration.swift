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

    /// Register for every agent that is installed; off the main thread.
    static func registerAll(executable: String) async -> [Outcome] {
        var outcomes: [Outcome] = []
        if let claude = CLIToolLocator.resolve(.claude) {
            _ = await CLIToolLocator.run(claude, ["mcp", "remove", "--scope", "user", BrowserAgentTools.serverName], timeout: 30)
            let result = await CLIToolLocator.run(claude, ["mcp", "add", "--scope", "user", BrowserAgentTools.serverName, "--", executable, "--mcp-browser"], timeout: 30)
            outcomes.append(Outcome(agent: "Claude Code", ok: result.exitCode == 0,
                                    detail: result.exitCode == 0 ? "user scope" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if let codex = CLIToolLocator.resolve(.codex) {
            _ = await CLIToolLocator.run(codex, ["mcp", "remove", "markview_browser"], timeout: 30)
            let result = await CLIToolLocator.run(codex, ["mcp", "add", "markview_browser", "--", executable, "--mcp-browser"], timeout: 30)
            outcomes.append(Outcome(agent: "Codex", ok: result.exitCode == 0,
                                    detail: result.exitCode == 0 ? "~/.codex/config.toml" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if CLIToolLocator.resolve(.copilot) != nil {
            let entry: [String: Any] = ["type": "local", "command": executable, "args": ["--mcp-browser"], "tools": ["*"]]
            outcomes.append(addServer(entry, to: copilotConfig, agent: "Copilot"))
        }
        if CLIToolLocator.resolve(.cline) != nil {
            let entry: [String: Any] = ["transport": ["type": "stdio", "command": executable, "args": ["--mcp-browser"]] as [String: Any],
                                        "disabled": false, "autoApprove": [String](), "timeout": 120]
            outcomes.append(addServer(entry, to: clineConfig, agent: "Cline"))
        }
        return outcomes
    }

    /// Put `entry` under `mcpServers["markview-browser"]` of a JSON settings file, keeping the rest.
    static func addServer(_ entry: [String: Any], to file: URL, agent: String) -> Outcome {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return Outcome(agent: agent, ok: false, detail: "\(file.path) is not a JSON object; left unchanged")
            }
            root = object
        }
        root = BrowserAgentTools.withServer(entry, in: root)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            return Outcome(agent: agent, ok: true, detail: file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        } catch {
            return Outcome(agent: agent, ok: false, detail: error.localizedDescription)
        }
    }

    /// The menu command: explain, confirm, register, report.
    @MainActor
    static func connectInteractively() {
        guard let executable = Bundle.main.executablePath else { return }
        let ask = NSAlert()
        ask.messageText = "Connect agents to MarkView's browser?"
        ask.informativeText = """
        Claude Code, Codex, Copilot and Cline (those installed) get the "markview-browser" tools in their \
        own settings, so they can drive this window's browser tabs even when you start them by hand in a \
        MarkView terminal. Started anywhere else, the tools stay hidden.

        Claude Code: user-scope MCP server · Codex: ~/.codex/config.toml · Copilot: ~/.copilot/mcp-config.json · \
        Cline: its MCP settings. Remove it later with each agent's "mcp remove".
        """
        ask.addButton(withTitle: "Connect")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let outcomes = await registerAll(executable: executable)
            let report = NSAlert()
            report.messageText = outcomes.isEmpty ? "No agent CLI was found." : "Agents connected to MarkView's browser"
            report.informativeText = outcomes.map { "\($0.ok ? "✓" : "✗") \($0.agent) — \($0.detail)" }.joined(separator: "\n")
                + (outcomes.isEmpty ? "" : "\n\nAgents already running pick it up when restarted.")
            report.runModal()
        }
    }
}
