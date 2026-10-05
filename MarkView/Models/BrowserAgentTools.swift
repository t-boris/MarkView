import Foundation

/// Agents in MarkView's terminals drive the window's browser tabs instead of Chrome (Tasks 80, 82).
///
/// Agents get an MCP server, `MarkView --mcp-browser`: this same binary, run without UI, speaking
/// MCP (JSON-RPC, one message per line) on stdin/stdout. Each tool call is relayed over a Unix
/// socket to the running app, which performs it in a browser tab of the window the terminal
/// belongs to (`BrowserControlServer`). Claude Code, Codex and Copilot started from the AI panel
/// get the server with the window in its arguments; an agent started by hand (registered once in
/// its own configuration) finds the app and the window through its parent processes.
enum BrowserAgentTools {
    static let serverName = "markview-browser"

    /// Shown to the agent by the MCP client: use these tabs, not another browser.
    static let instructions = """
    MarkView browser: these tools drive the browser tabs inside the MarkView window the user is \
    working in, where they watch what happens. For any web page work — opening the app under \
    development (localhost), clicking through it, filling forms, following instructions on a platform \
    the user is signed in to, reading the page, its console or a screenshot — use these tools instead \
    of Chrome, Playwright or other browser automation. The tabs share the user's sign-ins, so never ask \
    for credentials. Tabs have names (T1, T2… or names the user gave, like "Jira"): when the user says \
    which tab to use, pass it as `tab`; browser_tabs lists them, browser_open_tab opens a new one. \
    Start with browser_snapshot (or browser_navigate) to see the page and the element refs that \
    browser_click and browser_type take. If a tool says the user stopped a tab, do not retry it.
    """

    /// Outside a MarkView terminal: no tools, and this note.
    static let unavailableNote = "MarkView browser: this agent is not running in a MarkView terminal, so no tab is available."

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

    private static let tab: [String: [String: Any]] = [
        "tab": ["type": "string", "description": "Which browser tab: its name (T2, Jira…), number, or part of its title or address. Default: the active browser tab."],
    ]

    private static let target: [String: [String: Any]] = tab.merging([
        "ref": ["type": "string", "description": "Element ref from browser_snapshot, e.g. e12"],
        "selector": ["type": "string", "description": "CSS selector (when there is no ref)"],
        "text": ["type": "string", "description": "Visible text of the element (when there is no ref or selector)"],
    ]) { $1 }

    private static func with(_ extra: [String: [String: Any]]) -> [String: [String: Any]] {
        tab.merging(extra) { $1 }
    }

    static let tools: [Tool] = [
        Tool(name: "browser_tabs", description: "The browser tabs of the MarkView window: name, title, address, which is active, and which the user stopped.",
             properties: [:], required: []),
        Tool(name: "browser_open_tab", description: "Open a new browser tab (optionally at a URL) with a name to refer to it later.",
             properties: ["url": ["type": "string"], "name": ["type": "string", "description": "A short name, e.g. Billing"]], required: []),
        Tool(name: "browser_navigate", description: "Open a URL (http, https, localhost or file) in a MarkView browser tab and wait until it has loaded.",
             properties: with(["url": ["type": "string"]]), required: ["url"]),
        Tool(name: "browser_snapshot", description: "The page's URL, title, visible text and its interactive elements, each with a ref for browser_click and browser_type.",
             properties: tab, required: []),
        Tool(name: "browser_click", description: "Click an element (by ref, CSS selector or visible text) with a real mouse click and wait for any navigation it starts.",
             properties: target, required: []),
        Tool(name: "browser_type", description: "Type into an input, textarea or editable element as real keystrokes; optionally submit with Enter.",
             properties: target.merging([
                "value": ["type": "string", "description": "The text to enter"],
                "submit": ["type": "boolean", "description": "Press Enter afterwards"],
                "append": ["type": "boolean", "description": "Keep the current value and add to it"],
             ]) { $1 }, required: ["value"]),
        Tool(name: "browser_press_key", description: "Press a key on the focused element: Enter, Escape, Tab, ArrowDown, a letter…",
             properties: with(["key": ["type": "string"]]), required: ["key"]),
        Tool(name: "browser_evaluate", description: "Run JavaScript in the page as the body of an async function and return its result as JSON (use `return`).",
             properties: with(["script": ["type": "string"]]), required: ["script"]),
        Tool(name: "browser_screenshot", description: "A PNG screenshot of the visible part of the page.",
             properties: tab, required: []),
        Tool(name: "browser_console", description: "Console messages, uncaught errors and dialogs of the page since it loaded.",
             properties: with(["clear": ["type": "boolean", "description": "Empty the log after reading"]]), required: []),
        Tool(name: "browser_wait_for", description: "Wait until the page shows a text, or for a number of milliseconds.",
             properties: with(["text": ["type": "string"], "timeout_ms": ["type": "integer", "description": "At most this long (default 10000, max 60000)"]]),
             required: []),
        Tool(name: "browser_back", description: "Go back one page.", properties: tab, required: []),
        Tool(name: "browser_reload", description: "Reload the page and wait until it has loaded.", properties: tab, required: []),
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
    /// `available`: false outside a MarkView terminal — the server then offers no tools.
    static func handle(_ message: [String: Any], available: Bool = true, call: (String, [String: Any]) -> Reply) -> [String: Any]? {
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
                "instructions": available ? instructions : unavailableNote,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": available ? tools.map(\.json) : []])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard available else { return result(Reply.error(unavailableNote).mcpResult) }
            guard let name = params["name"] as? String, tools.contains(where: { $0.name == name }) else {
                return result(Reply.error("Unknown tool").mcpResult)
            }
            return result(call(name, params["arguments"] as? [String: Any] ?? [:]).mcpResult)
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    /// `MarkView --mcp-browser [--socket <path> --window <id>]`: serve MCP on stdin/stdout until stdin
    /// closes. Without `--socket` (an agent started by hand, registered once in its own configuration)
    /// the app is found among this process's ancestors — MarkView ← shell ← agent ← this server — and
    /// the window by the terminal's shell, so no environment variable has to survive the MCP client.
    static func runServer(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let ancestors = ancestorPIDs()
        let fromAncestors = ancestors.lazy.map(socketPath(forApp:)).first { FileManager.default.fileExists(atPath: $0) }
        // BUG-027: an agent that runs its tools in a background process (Cline's hub daemon) has no
        // MarkView among its ancestors; then any running MarkView is used and the window is chosen
        // by the folder the agent works in (`cwd` in each request).
        let fallbacks = value("--socket") == nil && fromAncestors == nil ? runningAppSockets() : []
        let socket = value("--socket") ?? fromAncestors ?? fallbacks.first ?? ""
        let window = value("--window") ?? ""
        let cwd = FileManager.default.currentDirectoryPath
        if arguments.contains("--diagnose") {
            diagnose(socket: socket, window: window, ancestors: ancestors, viaAncestors: fromAncestors != nil || value("--socket") != nil, cwd: cwd)
        }
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            guard let answer = handle(message, available: !socket.isEmpty, call: { tool, args in
                let payload: [String: Any] = ["window": window, "pids": ancestors.map(Int.init), "cwd": cwd, "tool": tool, "arguments": args]
                // Found by socket only: ask each running MarkView until one has the agent's folder open.
                for candidate in fallbacks.dropLast() {
                    let reply = request(socket: candidate, payload: payload)
                    if !(reply.isError && reply.text.hasPrefix(noWindowPrefix)) { return reply }
                }
                return request(socket: fallbacks.last ?? socket, payload: payload)
            }), let out = try? JSONSerialization.data(withJSONObject: answer) else { continue }
            FileHandle.standardOutput.write(out + Data("\n".utf8))
        }
        exit(0)
    }

    /// `MarkView --mcp-browser --diagnose`, typed in a terminal where an agent lacks the browser tools
    /// (BUG-026): which processes are above it, whether a MarkView is among them, and whether that
    /// MarkView knows the window. Prints and exits.
    static func diagnose(socket: String, window: String, ancestors: [Int32], viaAncestors: Bool, cwd: String) -> Never {
        func name(_ pid: Int32) -> String {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "?" }
            return withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        print("MarkView browser tools — diagnosis")
        print("Parent processes: " + ancestors.map { "\($0) \(name($0))" }.joined(separator: " ← "))
        print("Working folder: \(cwd)")
        guard !socket.isEmpty else {
            print("✗ MarkView is not running (no control socket found).")
            exit(1)
        }
        print(viaAncestors ? "✓ MarkView found among the parent processes: \(socket)"
                           : "✓ MarkView found by its socket (the agent runs its tools in a background process): \(socket)")
        let reply = request(socket: socket, payload: ["window": window, "pids": ancestors.map(Int.init), "cwd": cwd, "tool": "browser_tabs", "arguments": [String: Any]()], timeout: 10)
        print(reply.isError ? "✗ " + reply.text : "✓ The window answered. Its browser tabs:\n" + reply.text)
        exit(reply.isError ? 1 : 0)
    }

    /// The control socket of the MarkView process `pid`: in the user's temporary folder (resolved
    /// by the system, not from `$TMPDIR`, which MCP clients may not pass on).
    static func socketPath(forApp pid: Int32) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mv-browser-\(pid).sock").path
    }

    /// How the app's reply starts when no window has the agent's folder (another MarkView may have it).
    static let noWindowPrefix = "No MarkView window has the folder"

    /// Control sockets of MarkView processes that are running, newest process first.
    static func runningAppSockets() -> [String] {
        let folder = FileManager.default.temporaryDirectory.path
        let pids = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { name -> Int32? in
            guard name.hasPrefix("mv-browser-"), name.hasSuffix(".sock") else { return nil }
            return Int32(name.dropFirst("mv-browser-".count).dropLast(".sock".count))
        }.filter { kill($0, 0) == 0 || errno == EPERM }
        return pids.sorted(by: >).map(socketPath(forApp:))
    }

    /// The window whose project folder holds `cwd` (the deepest one), else the only window.
    static func windowIndex(forFolder cwd: String, roots: [String?]) -> Int? {
        let path = (cwd as NSString).standardizingPath
        let matches = roots.enumerated().compactMap { index, root -> (Int, Int)? in
            guard let root = root.map({ ($0 as NSString).standardizingPath }), !root.isEmpty else { return nil }
            return path == root || path.hasPrefix(root + "/") ? (index, root.count) : nil
        }
        if let best = matches.max(by: { $0.1 < $1.1 }) { return best.0 }
        return roots.count == 1 ? 0 : nil
    }

    /// This process's parent, grandparent… up to launchd.
    static func ancestorPIDs() -> [Int32] {
        var out: [Int32] = []
        var pid = getppid()
        while pid > 1, out.count < 32 {
            out.append(pid)
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            pid = info.kp_eproc.e_ppid
        }
        return out
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

    // MARK: - Choosing a tab

    /// The tab `query` names among `tabs` (name, title, address): exact name (case-insensitive),
    /// then a number ("2" → T2), then a part of the title or address. Nil when nothing matches or
    /// a part matches several tabs.
    static func tabIndex(_ query: String, in tabs: [(name: String, title: String, url: String)]) -> Int? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = tabs.firstIndex(where: { $0.name.lowercased() == q }) { return exact }
        if Int(q) != nil, let numbered = tabs.firstIndex(where: { $0.name.lowercased() == "t" + q }) { return numbered }
        let partial = tabs.indices.filter { tabs[$0].title.lowercased().contains(q) || tabs[$0].url.lowercased().contains(q) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// An agent's MCP settings with `mcpServers["markview-browser"] = entry`; other servers and keys stay.
    static func withServer(_ entry: [String: Any], in root: [String: Any]) -> [String: Any] {
        var root = root
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = entry
        root["mcpServers"] = servers
        return root
    }

    /// Whether an MCP client's output says it refused the server by policy (a Copilot organisation
    /// that allows only listed MCP servers): `MCP server was blocked by policy: "markview-browser"`.
    static func reportsPolicyBlock(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("blocked by policy") && text.contains(serverName)
    }

    /// The next free default name: T1, T2…
    static func nextTabName(taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var n = 1
        while used.contains("t\(n)") { n += 1 }
        return "T\(n)"
    }
}
