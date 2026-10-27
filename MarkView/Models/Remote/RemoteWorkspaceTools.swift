import Foundation

/// The complete workspace interface is advertised to both providers through the same MCP server.
enum RemoteWorkspaceTools {
    static let names: Set<String> = ["workspace_info", "list_directory", "read_file", "write_file", "edit_file", "exec_command", "write_stdin"]
    static let instructions = """
    Your execution environment is the WORK computer connected through MarkView. All project files, Git,
    commands, tests and development servers belong to that computer. Use these workspace tools for EVERY
    filesystem and command operation. workspace_info gives the actual working directory and environment.
    Never inspect the home computer's filesystem or use its native shell or patch tools. Absolute paths
    in prompts and tool results refer to the work computer. Read AGENTS.md and CLAUDE.md through read_file
    when present. Commands have normal local user permissions. exec_command can return a running session;
    use write_stdin to wait, send input, interrupt or terminate it. Read image files through read_file.
    """

    private static func tool(_ name: String, _ description: String, _ properties: [String: RemoteJSON], required: [String] = []) -> RemoteJSON {
        .object(["name": .string(name), "description": .string(description),
                 "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                                         "required": .array(required.map(RemoteJSON.string))])])
    }
    private static func field(_ type: String, _ description: String) -> RemoteJSON {
        .object(["type": .string(type), "description": .string(description)])
    }
    static let tools: [RemoteJSON] = [
        tool("workspace_info", "Actual work-computer working directory, OS, shell, hostname and project instructions.", [:]),
        tool("list_directory", "List a directory on the work computer, including hidden files.", ["path": field("string", "Absolute or workspace-relative path; defaults to .")]),
        tool("read_file", "Read UTF-8 text with line numbers or a PNG, JPEG, GIF or WebP image from the work computer.", [
            "path": field("string", "Absolute or workspace-relative file path"),
            "offset": field("integer", "Zero-based first line; default 0"),
            "limit": field("integer", "Number of lines; default 2000")], required: ["path"]),
        tool("write_file", "Create or replace a UTF-8 file on the work computer. Creates parent directories.", [
            "path": field("string", "Absolute or workspace-relative file path"),
            "content": field("string", "Complete new file contents")], required: ["path", "content"]),
        tool("edit_file", "Replace exact text in the current work-computer file. Ambiguous or stale matches fail.", [
            "path": field("string", "Absolute or workspace-relative file path"),
            "old_text": field("string", "Exact existing text including enough context to identify one match"),
            "new_text": field("string", "Replacement text"), "replace_all": field("boolean", "Replace every match; default false")], required: ["path", "old_text", "new_text"]),
        tool("exec_command", "Run a shell command ON THE WORK COMPUTER: search, Git, builds, tests, scripts or development servers. A running command returns session_id.", [
            "cmd": field("string", "Shell command"), "workdir": field("string", "Working directory; defaults to workspace root"),
            "yield_time_ms": field("integer", "Wait 0–30000 ms; default 1000")], required: ["cmd"]),
        tool("write_stdin", "Poll or send input to a work-computer command session. Use chars=Ctrl-C or terminate=true to stop it.", [
            "session_id": field("string", "Session returned by exec_command"), "chars": field("string", "Input to send"),
            "yield_time_ms": field("integer", "Wait 0–30000 ms; default 1000"),
            "close_stdin": field("boolean", "Close command stdin"), "terminate": field("boolean", "Stop the process")], required: ["session_id"]),
    ]

    static func response(to request: RemoteJSON, call: (UUID, String, RemoteJSON) -> RemoteJSON) -> RemoteJSON? {
        let id = request["id"]
        guard id != .null, let method = request["method"].string else { return nil }
        let result: RemoteJSON
        switch method {
        case "initialize": result = .object([
            "protocolVersion": .string("2024-11-05"), "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string("markview-workspace"), "version": .string("1.0.0")]),
            "instructions": .string(instructions)])
        case "ping": result = .object([:])
        case "tools/list": result = .object(["tools": .array(tools)])
        case "tools/call":
            guard let name = request["params"]["name"].string, names.contains(name) else {
                return .object(["jsonrpc": .string("2.0"), "id": id, "result": .textResult("Unknown workspace tool.", error: true)])
            }
            result = call(UUID(), name, request["params"]["arguments"])
        default:
            return .object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .int(-32601), "message": .string("Method not found")])])
        }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
}
