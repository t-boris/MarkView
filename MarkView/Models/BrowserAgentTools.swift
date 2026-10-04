import Foundation

/// Agents in MarkView's terminals drive the window's browser tab instead of Chrome (Task 80).
///
/// Claude Code and Codex started from MarkView get an MCP server, `MarkView --mcp-browser`: this
/// same binary, run without UI, speaking MCP (JSON-RPC, one message per line) on stdin/stdout.
/// Each tool call is relayed over a Unix socket to the running app, which performs it in the
/// browser tab of the window the terminal belongs to (`BrowserControlServer`).
enum BrowserAgentTools {
    static let serverName = "markview-browser"

    /// Shown to the agent by the MCP client: use this tab, not another browser.
    static let instructions = """
    MarkView browser: these tools drive the browser tab inside the MarkView window the user is \
    working in, where they watch what happens. For any web page check — opening the app under \
    development (localhost), clicking through it, filling forms, reading the page, its console or \
    a screenshot — use these tools instead of Chrome, Playwright or other browser automation. Start \
    with browser_navigate, then browser_snapshot to see the page and the element refs that \
    browser_click and browser_type take.
    """

    struct Tool {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]

        var json: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
    }

    private static let target: [String: [String: Any]] = [
        "ref": ["type": "string", "description": "Element ref from browser_snapshot, e.g. e12"],
        "selector": ["type": "string", "description": "CSS selector (when there is no ref)"],
        "text": ["type": "string", "description": "Visible text of the element (when there is no ref or selector)"],
    ]

    static let tools: [Tool] = [
        Tool(name: "browser_navigate", description: "Open a URL (http, https, localhost or file) in the MarkView browser tab and wait until it has loaded.",
             properties: ["url": ["type": "string"]], required: ["url"]),
        Tool(name: "browser_snapshot", description: "The page's URL, title, visible text and its interactive elements, each with a ref for browser_click and browser_type.",
             properties: [:], required: []),
        Tool(name: "browser_click", description: "Click an element (by ref, CSS selector or visible text) and wait for any navigation it starts.",
             properties: target, required: []),
        Tool(name: "browser_type", description: "Type into an input, textarea or editable element; optionally submit its form.",
             properties: target.merging([
                "value": ["type": "string", "description": "The text to enter"],
                "submit": ["type": "boolean", "description": "Submit the form (or press Enter) afterwards"],
                "append": ["type": "boolean", "description": "Keep the current value and add to it"],
             ]) { $1 }, required: ["value"]),
        Tool(name: "browser_press_key", description: "Press a key on the focused element: Enter, Escape, Tab, ArrowDown, a letter…",
             properties: ["key": ["type": "string"]], required: ["key"]),
        Tool(name: "browser_evaluate", description: "Run JavaScript in the page as the body of an async function and return its result as JSON (use `return`).",
             properties: ["script": ["type": "string"]], required: ["script"]),
        Tool(name: "browser_screenshot", description: "A PNG screenshot of the visible part of the page.",
             properties: [:], required: []),
        Tool(name: "browser_console", description: "Console messages, uncaught errors and dialogs of the page since it loaded.",
             properties: ["clear": ["type": "boolean", "description": "Empty the log after reading"]], required: []),
        Tool(name: "browser_wait_for", description: "Wait until the page shows a text, or for a number of milliseconds.",
             properties: ["text": ["type": "string"], "timeout_ms": ["type": "integer", "description": "At most this long (default 10000, max 60000)"]],
             required: []),
        Tool(name: "browser_back", description: "Go back one page.", properties: [:], required: []),
        Tool(name: "browser_reload", description: "Reload the page and wait until it has loaded.", properties: [:], required: []),
    ]

    // MARK: - Replies (app → MCP server)

    /// The result of one tool call, as the app sends it back over the socket.
    struct Reply {
        var text: String
        var pngBase64: String?
        var isError = false

        static func error(_ message: String) -> Reply { Reply(text: message, pngBase64: nil, isError: true) }

        var json: [String: Any] {
            var object: [String: Any] = ["text": text, "isError": isError]
            if let pngBase64 { object["png"] = pngBase64 }
            return object
        }

        init(text: String, pngBase64: String? = nil, isError: Bool = false) {
            self.text = text
            self.pngBase64 = pngBase64
            self.isError = isError
        }

        init?(json: [String: Any]) {
            guard let text = json["text"] as? String else { return nil }
            self.init(text: text, pngBase64: json["png"] as? String, isError: json["isError"] as? Bool ?? false)
        }

        /// MCP `tools/call` result.
        var mcpResult: [String: Any] {
            var content: [[String: Any]] = []
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
            if let pngBase64 { content.append(["type": "image", "data": pngBase64, "mimeType": "image/png"]) }
            return ["content": content, "isError": isError]
        }
    }

    // MARK: - MCP (stdio side)

    static let protocolVersion = "2025-06-18"

    /// The answer to one MCP message, or nil for a notification. `call` performs a tool call.
    static func handle(_ message: [String: Any], call: (String, [String: Any]) -> Reply) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil }   // notifications need no answer
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            return result([
                "protocolVersion": params?["protocolVersion"] as? String ?? protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": "1"],
                "instructions": instructions,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools.map(\.json)])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String, tools.contains(where: { $0.name == name }) else {
                return result(Reply.error("Unknown tool").mcpResult)
            }
            return result(call(name, params["arguments"] as? [String: Any] ?? [:]).mcpResult)
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    /// `MarkView --mcp-browser --socket <path> --window <id>`: serve MCP on stdin/stdout until stdin closes.
    static func runServer(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let socket = value("--socket") ?? ""
        let window = value("--window") ?? ""
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            guard let answer = handle(message, call: { tool, args in
                request(socket: socket, payload: ["window": window, "tool": tool, "arguments": args])
            }), let out = try? JSONSerialization.data(withJSONObject: answer) else { continue }
            FileHandle.standardOutput.write(out + Data("\n".utf8))
        }
        exit(0)
    }

    // MARK: - Socket client

    /// Send one request line to the app and read its reply line.
    static func request(socket path: String, payload: [String: Any], timeout: Int = 120) -> Reply {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .error("Bad request") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .error("Cannot create a socket") }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        guard var address = unixAddress(path) else { return .error("Socket path too long") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            return .error("MarkView is not reachable (is the window that started this terminal still open?)")
        }
        guard writeAll(fd, body + Data("\n".utf8)) else { return .error("Could not send the request to MarkView") }
        guard let line = readLine(fd), let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let reply = Reply(json: object) else { return .error("MarkView did not answer in time") }
        return reply
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        return address
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Bytes up to the first newline (at most 32 MB: screenshots are large); nil on error or timeout.
    static func readLine(_ fd: Int32) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while out.count < 32_000_000 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { return out.isEmpty ? nil : out }
            if let newline = buffer[0..<count].firstIndex(of: 10) {
                out.append(contentsOf: buffer[0..<newline])
                return out
            }
            out.append(contentsOf: buffer[0..<count])
        }
        return nil
    }
}
