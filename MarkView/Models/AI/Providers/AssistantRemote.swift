import Foundation

// An assistant that the home Mac hosts for a work Mac (Remote Work): how its CLI is configured for one remote session. The
// transport, the tools and the guard are MarkView's (`RemoteProviderConfiguration`); this is what differs per CLI. Foundation
// only, like the rest of the provider contract.

/// What `RemoteProviderConfiguration` hands the provider to configure a remote-hosted CLI.
struct AssistantRemotePlan {
    /// The per-session folder of the home Mac that holds the configuration files.
    let directory: URL
    /// The MCP configuration file that lists the work-computer server.
    let mcpConfig: URL
    /// This app's executable (the server and the guard run it) and the socket of the work-computer server.
    let app: String
    let socket: String
    /// The name of the work-computer MCP server and the prefix of its tool names.
    let serverName: String
    let toolPrefix: String
    /// The instructions that describe the work computer.
    let instructions: String
    /// The command that denies native home tools (a tool hook).
    let guardCommand: String
    let resume: Bool
    /// The thread to resume, when the CLI resumes by id (`AssistantRemoteSupport.refreshesThreadInstructions`).
    let resumeThreadID: String?
    /// Writes `object` as JSON into the session folder (owner-only permissions) and returns the file.
    let writeJSON: (Any, String) throws -> URL
}

protocol AssistantRemoteSupport: Sendable {
    /// The arguments (after the executable, before the model flag) that start the CLI in the session folder: only the work
    /// computer's tools, native home tools blocked, no approval prompts.
    func arguments(_ plan: AssistantRemotePlan) throws -> [String]
    /// The saved thread keeps its developer messages: they are refreshed (`RemoteCodexContext`) before the thread is resumed.
    var refreshesThreadInstructions: Bool { get }
}

extension AssistantRemoteSupport {
    var refreshesThreadInstructions: Bool { false }
}
