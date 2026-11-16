import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Generates per-run CLI configuration without changing either provider's global settings.
/// The home login remains owned by the provider CLI. Home native tools are blocked, not merely
/// discouraged by a prompt, so a missing MCP connection cannot become a home-disk operation.
enum RemoteProviderConfiguration {
    /// The assistants the home Mac can host for a work Mac: those whose provider has a `remote` facet.
    static var tools: [CLITool] { CLITool.allCases.filter { $0.provider.remote != nil } }

    /// The assistant a saved connection starts with when it names none.
    static var defaultTool: CLITool { tools[0] }

    /// The hostable assistant with this stored name; nil for an unknown one or one that cannot be hosted.
    static func tool(named name: String) -> CLITool? {
        CLITool(rawValue: name).flatMap { $0.provider.remote == nil ? nil : $0 }
    }

    static func command(tool: CLITool, executable: String, app: String, socket: String,
                        context: RemoteJSON, directory: URL, model: String?, resume: Bool,
                        resumeThreadID: String? = nil) throws -> String {
        guard let remote = tool.provider.remote else { throw RemoteFailure.invalid("Unsupported remote assistant.") }
        let server: RemoteJSON = .object(["command": .string(app),
            "args": .array([.string("--remote-workspace-mcp"), .string("--socket"), .string(socket)])])
        let mcp = RemoteJSON.object(["mcpServers": .object([RemoteWorkspaceTools.serverName: server])])
        let config = directory.appendingPathComponent("mcp.json")
        try write(mcp, to: config)
        let plan = AssistantRemotePlan(
            directory: directory, mcpConfig: config, app: app, socket: socket,
            serverName: RemoteWorkspaceTools.serverName, toolPrefix: RemoteWorkspaceTools.toolPrefix,
            instructions: try instructions(context: context), guardCommand: quote(app) + " --remote-workspace-guard",
            resume: resume, resumeThreadID: resumeThreadID,
            writeJSON: { object, name in
                let url = directory.appendingPathComponent(name)
                try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: url, permissions: 0o600)
                return url
            })
        let args = try remote.arguments(plan) + tool.provider.modelArgs(model)
        return ([executable] + args).map(quote).joined(separator: " ")
    }

    static func instructions(context: RemoteJSON) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let environment = String(decoding: try encoder.encode(context), as: UTF8.self)
        return """
        \(RemoteWorkspaceTools.instructions)

        WORK computer environment (these tools target this computer; native CLI sandbox permissions belong to HOME):
        \(environment)

        Begin by using workspace_info and reading the project's instructions on the work computer.
        """
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func write(_ value: RemoteJSON, to url: URL) throws {
        try AtomicFile.write(JSONEncoder().encode(value), to: url, permissions: 0o600)
    }
}
