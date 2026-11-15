import Foundation

/// One MCP server of this binary that an assistant can use: the browser tools or the project tools.
struct AgentMCPServer: Sendable {
    /// Name in the assistant's settings (`markview-browser`, `markview`).
    let name: String
    /// The same server under a name that is valid as a TOML key (Codex keeps its servers in `config.toml`).
    let tomlName: String
    /// The argument that starts the server in the MarkView binary (`--mcp-browser`, `--mcp-project`).
    let flag: String
    /// "browser" or "project", for messages.
    let label: String
    /// The command and arguments that start the server for one window (per-session registration only).
    var command = ""
    var args: [String] = []
}

/// How MarkView's MCP servers are registered in an assistant's own settings. `AgentBrowserRegistration` interprets it.
enum AssistantMCPRegistration {
    /// The assistant's own `mcp` commands.
    case commands(CommandRegistration)
    /// One entry per server in a JSON settings file; everything else in the file is kept.
    case jsonFile(JSONFileRegistration)

    struct CommandRegistration {
        /// Arguments that remove a server (run before every add, so the entry points at this copy of MarkView).
        let remove: @Sendable (AgentMCPServer) -> [String]
        /// Arguments that add a server running `executable server.flag`.
        let add: @Sendable (AgentMCPServer, String) -> [String]
        /// Arguments that list the registered servers; when present a start only registers what the list lacks.
        let list: [String]?
        /// Where the registration lands, shown after Connect Agents.
        let location: String
        /// A failed add reports stdout and stderr (else stderr only).
        let reportsStdoutOnFailure: Bool
    }

    struct JSONFileRegistration {
        /// The settings file under the home folder.
        let file: URL
        /// The entry for `server` running `executable`.
        let entry: @Sendable (_ executable: String, _ server: AgentMCPServer) -> [String: Any]
        /// An existing entry already runs `executable` and is enabled.
        let isCurrent: @Sendable (_ entry: [String: Any], _ executable: String) -> Bool
        /// Every start checks the file; false: only Connect Agents writes it.
        let checkedAtStart: Bool
    }
}
