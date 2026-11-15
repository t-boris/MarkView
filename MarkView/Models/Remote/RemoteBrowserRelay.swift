import Foundation

/// A browser tool call of a relay session (`RemoteWorkspace`): the work computer's window that the relay connected to answers it
/// (`AgentToolServer.performForRelay`), and the result goes back as MCP JSON. Project and file tools are not served here.
@MainActor
enum RemoteBrowserRelay {
    static func perform(_ tool: String, arguments: RemoteJSON, window id: UUID, root: URL, agent: CLITool) async -> RemoteJSON {
        guard RemoteWorkspaceTools.browserNames.contains(tool) else {
            return .textResult("Only the browser tools are served here; the connected window has no other.", error: true)
        }
        guard let data = try? JSONEncoder().encode(arguments == .null ? .object([:]) : arguments),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .textResult("Browser arguments must be an object.", error: true)
        }
        let reply = await AgentToolServer.performForRelay(tool, args, window: id, root: root, agent: agent)
        guard let result = try? JSONSerialization.data(withJSONObject: reply.mcpResult),
              let json = try? JSONDecoder().decode(RemoteJSON.self, from: result) else {
            return .textResult("Could not encode the browser result.", error: true)
        }
        return json
    }
}
