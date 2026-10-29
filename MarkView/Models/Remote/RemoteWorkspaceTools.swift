import Foundation

/// The complete workspace interface is advertised to both providers through the same MCP server.
enum RemoteWorkspaceTools {
    static let serverName = "markview_remote_workspace"
    static let toolPrefix = "mcp__" + serverName + "__"
    private static let fileNames: Set<String> = ["workspace_info", "list_directory", "read_file", "write_file", "edit_file", "exec_command", "write_stdin"]
    static let browserNames = Set(BrowserAgentTools.tools.map(\.name))
    static let names = fileNames.union(browserNames)
    static let instructions = """
    MarkView connects TWO computers. The assistant CLI process runs on the HOME computer in a transport
    directory, not in the user's project. Its native filesystem sandbox and approval policy describe
    HOME access only. The user's project, files, Git, commands and browser tabs are on the WORK computer.
    These MCP workspace tools execute on WORK as its local user; they support reading AND writing files.
    Native HOME restrictions do not make the WORK project read-only and do not prohibit write_file,
    edit_file or work-computer exec_command. For a requested file change, read_file then edit_file or
    write_file on WORK. Do not refuse an edit based on the CLI's read-only sandbox message. Report a
    WORK file as unwritable only if a WORK tool actually returns a permission error for that operation.
    When the user says "local file", "this file" or supplies an absolute path, they mean the file on WORK.
    Pass that exact path to these tools; do not translate it into the home transport directory or inspect
    a home-computer namesake. workspace_info identifies WORK and its project root. File tools stay inside
    that root; an outside-workspace error is a scope error, not evidence that the workspace is read-only.
    Use these tools for EVERY filesystem and command operation. Never use HOME native shell, patch or
    file tools. Read AGENTS.md and CLAUDE.md through read_file when present. exec_command can return a
    running session; use write_stdin to wait, send input, interrupt or terminate it. Read images through
    read_file. Work-computer OS permissions still apply; do not claim a failed edit succeeded.
    The browser_* tools control the tabs in the WORK computer's connected MarkView window, including
    existing signed-in pages and localhost development servers. Start with browser_tabs, then
    browser_snapshot for page text and element refs. browser_screenshot returns a page image. Respect
    tabs stopped by the user; do not retry them. The window is fixed; project_folder is unnecessary.
    """

    private static func tool(_ name: String, _ description: String, _ properties: [String: RemoteJSON], required: [String] = []) -> RemoteJSON {
        .object(["name": .string(name), "description": .string(description),
                 "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                                         "required": .array(required.map(RemoteJSON.string))])])
    }
    private static func field(_ type: String, _ description: String) -> RemoteJSON {
        .object(["type": .string(type), "description": .string(description)])
    }
    /// Reuse the shipping browser schemas, without the local MCP server's folder-routing argument.
    static let browserTools: [RemoteJSON] = BrowserAgentTools.tools.map { definition in
        var definition = definition
        definition.addsFolder = false
        let data = try! JSONSerialization.data(withJSONObject: definition.json)
        return try! JSONDecoder().decode(RemoteJSON.self, from: data)
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
    ] + browserTools

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
