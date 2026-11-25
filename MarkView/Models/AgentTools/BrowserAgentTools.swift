import Foundation
import Darwin
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Agents in MarkView's terminals drive the window's browser tabs instead of Chrome (Tasks 80, 82).
///
/// Agents get an MCP server, `MarkView --mcp-browser`: this same binary, run without UI, speaking
/// MCP (JSON-RPC, one message per line) on stdin/stdout. Each tool call is relayed over a Unix
/// socket to the running app, which performs it in a browser tab of the window the terminal
/// belongs to (`AgentToolServer`). Claude Code, Codex and Copilot started from the AI panel
/// get the server with the window in its arguments; an agent started by hand (registered once in
/// its own configuration) finds the app and the window through its parent processes.
enum BrowserAgentTools {
    static let serverName = "markview-browser"

    /// Shown to the agent by the MCP client: use these tabs, not another browser.
    static let instructions = """
    MarkView browser: these tools drive browser tabs inside the MarkView window in the background \
    without switching the user's active tab or stealing keyboard focus. For any web page work — \
    opening the app under development (localhost), clicking through it, filling forms, following \
    instructions on a platform the user is signed in to, reading the page, its console or a \
    screenshot — use these tools instead of Chrome, Playwright or other browser automation. The tabs \
    share the user's sign-ins, so never ask for credentials. Tabs have names (T1, T2… or names the \
    user gave, like "Jira"): browser_open_tab opens a new background tab and returns its name — pass \
    that name as `tab` on follow-up calls to keep targeting stable; browser_tabs lists all tabs and \
    which one is currently active for the user. Start with browser_snapshot (or browser_navigate) to \
    see the page and the element refs that browser_click and browser_type take. If a tool reports a \
    pending sign-in popup or an operation that requires the tab in front (such as browser_screenshot), \
    tell the user which tab to select. If a tool says the user stopped a tab, do not retry it. \
    The app determines the project window from the verified process and its working folder.
    """

    /// Outside a MarkView terminal: no tools, and this note.
    static let unavailableNote = "MarkView browser: this agent is not running in a MarkView terminal, so no tab is available."

    struct Tool {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
        var json: [String: Any] {
            return ["name": name, "description": description,
                    "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
        }
    }

    /// Working directory reported by the kernel for the peer or one of its ancestors. Failure is not a trusted folder.
    static func workingDirectory(forPIDs pids: [Int32]) -> String? {
        for pid in pids where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = MemoryLayout.size(ofValue: info)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    /// A legacy folder may restrict a project call, but cannot select a window.
    static func folder(_ folder: String, isInProject root: String) -> Bool {
        guard !folder.isEmpty, !root.isEmpty else { return false }
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let path = resolved(folder), project = resolved(root)
        return path == project || path.hasPrefix(project + "/")
    }

    /// What an MCP server of this binary offers: the browser tools, or the project tools (`ProjectAgentTools`).
    /// `rechecksApp`: look for the app again with every message, so that quitting MarkView takes the tools away.
    struct MCPProfile {
        let serverName: String
        let instructions: String
        let unavailableNote: String
        let tools: [Tool]
        let probeTool: String
        var rechecksApp = false
        /// Show the tools even while MarkView is not running: a client keeps the list it first saw, and an empty
        /// one would hide the tools for the whole session. A call then says that MarkView is not running.
        var alwaysListsTools = false
    }

    static var browserProfile: MCPProfile { MCPProfile(serverName: serverName, instructions: instructions, unavailableNote: unavailableNote,
                                           tools: tools, probeTool: "browser_tabs") }

    private static var tab: [String: [String: Any]] { [
        "tab": ["type": "string", "description": "Which browser tab: its name (T2, Jira…), number, or part of its title or address. Default: the active browser tab."],
    ] }

    private static var target: [String: [String: Any]] { tab.merging([
        "ref": ["type": "string", "description": "Element ref from browser_snapshot, e.g. e12"],
        "selector": ["type": "string", "description": "CSS selector (when there is no ref)"],
        "text": ["type": "string", "description": "Visible text of the element (when there is no ref or selector)"],
    ]) { $1 } }

    private static func with(_ extra: [String: [String: Any]]) -> [String: [String: Any]] {
        tab.merging(extra) { $1 }
    }

    static var tools: [Tool] { [
        Tool(name: "browser_tabs", description: "The browser tabs of the MarkView window: name, title, address, which is active for the user, which the user stopped, and any pending sign-in window.",
             properties: [:], required: []),
        Tool(name: "browser_open_tab", description: "Open a new browser tab in the background (optionally at a URL) with a name to refer to it later without changing the user's active tab or focus.",
             properties: ["url": ["type": "string"], "name": ["type": "string", "description": "A short name, e.g. Billing"]], required: []),
        Tool(name: "browser_navigate", description: "Open a URL (http, https, localhost or file) in a MarkView browser tab without bringing it to the front, and wait until it has loaded.",
             properties: with(["url": ["type": "string"]]), required: ["url"]),
        Tool(name: "browser_snapshot", description: "The page's URL, title, visible text and its interactive elements, each with a ref for browser_click and browser_type.",
             properties: tab, required: []),
        Tool(name: "browser_click", description: "Click an element (by ref, CSS selector or visible text) in the target tab without stealing focus, and wait for any navigation it starts.",
             properties: target, required: []),
        Tool(name: "browser_type", description: "Type into an input, textarea or editable element without stealing focus; optionally submit with Enter.",
             properties: target.merging([
                "value": ["type": "string", "description": "The text to enter"],
                "submit": ["type": "boolean", "description": "Press Enter afterwards"],
                "append": ["type": "boolean", "description": "Keep the current value and add to it"],
             ]) { $1 }, required: ["value"]),
        Tool(name: "browser_press_key", description: "Press a key on the focused element in the target tab without stealing focus: Enter, Escape, Tab, ArrowDown, a letter…",
             properties: with(["key": ["type": "string"]]), required: ["key"]),
        Tool(name: "browser_evaluate", description: "Run JavaScript in the page as the body of an async function and return its result as JSON (use `return`).",
             properties: with(["script": ["type": "string"]]), required: ["script"]),
        Tool(name: "browser_screenshot", description: "A PNG screenshot of the visible part of the page when the tab is currently shown; returns instructions if the tab is in the background.",
             properties: tab, required: []),
        Tool(name: "browser_console", description: "Console messages, uncaught errors and dialogs of the page since it loaded.",
             properties: with(["clear": ["type": "boolean", "description": "Empty the log after reading"]]), required: []),
        Tool(name: "browser_wait_for", description: "Wait until the page shows a text, or for a number of milliseconds.",
             properties: with(["text": ["type": "string"], "timeout_ms": ["type": "integer", "description": "At most this long (default 10000, max 60000)"]]),
             required: []),
        Tool(name: "browser_back", description: "Go back one page.", properties: tab, required: []),
        Tool(name: "browser_reload", description: "Reload the page and wait until it has loaded.", properties: tab, required: []),
    ] }

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
    static func handle(_ message: [String: Any], available: Bool = true, profile: MCPProfile? = nil,
                       call: (String, [String: Any]) -> Reply) -> [String: Any]? {
        let profile = profile ?? browserProfile
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil }   // notifications need no answer
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            return result([
                "protocolVersion": params?["protocolVersion"] as? String ?? protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": profile.serverName, "version": "1"],
                "instructions": available || profile.alwaysListsTools ? profile.instructions : profile.unavailableNote,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": available || profile.alwaysListsTools ? profile.tools.map(\.json) : []])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard available else { return result(Reply.error(profile.unavailableNote).mcpResult) }
            guard let name = params["name"] as? String, profile.tools.contains(where: { $0.name == name }) else {
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
    static func runServer(arguments: [String], profile: MCPProfile? = nil) -> Never {
        let profile = profile ?? browserProfile
        let found = locateApp(arguments: arguments)
        let window = found.window
        let cwd = FileManager.default.currentDirectoryPath
        if arguments.contains("--diagnose") {
            diagnose(socket: found.socket, window: window, ancestors: found.ancestors, viaAncestors: found.viaAncestors, cwd: cwd, probe: profile.probeTool)
        }
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            // The project tools look for the app again with every message: with MarkView quit, they vanish.
            let now = profile.rechecksApp ? locateApp(arguments: arguments) : found
            guard let answer = handle(message, available: !now.socket.isEmpty, profile: profile, call: { tool, args in
                forward(tool, args, to: now)
            }), let out = try? JSONSerialization.data(withJSONObject: answer) else { continue }
            FileHandle.standardOutput.write(out + Data("\n".utf8))
        }
        exit(0)
    }

    /// Where the app is: its control socket (empty when it is not running), the processes above this one and the window.
    struct AppLocation {
        var socket: String
        var fallbacks: [String]
        var ancestors: [Int32]
        var viaAncestors: Bool
        var window: String
    }

    static func locateApp(arguments: [String]) -> AppLocation {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let ancestors = ancestorPIDs()
        let alive = { (path: String) in appIsAlive(socket: path) }
        let fromAncestors = ancestors.lazy.map(socketPath(forApp:)).first { FileManager.default.fileExists(atPath: $0) && alive($0) }
        // External agents find running instances by socket; the app selects a window using the verified peer.
        let given = value("--socket").flatMap { alive($0) ? $0 : nil }
        let fallbacks = given == nil && fromAncestors == nil ? runningAppSockets() : []
        let socket = given ?? fromAncestors ?? fallbacks.first ?? ""
        return AppLocation(socket: socket, fallbacks: fallbacks, ancestors: ancestors,
                           viaAncestors: fromAncestors != nil || given != nil, window: value("--window") ?? "")
    }

    /// The MarkView process a control socket belongs to (`mv-browser-<pid>.sock`) still runs.
    static func appIsAlive(socket path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("mv-browser-"), name.hasSuffix(".sock"),
              let pid = Int32(name.dropFirst("mv-browser-".count).dropLast(".sock".count)) else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// One tool call to the app that `location` names; with several running MarkViews, each is asked until one has the agent's folder open.
    static func forward(_ tool: String, _ args: [String: Any], to location: AppLocation) -> Reply {
        // A legacy project_folder is forwarded only as a restriction; the app never uses it to select a window.
        let payload: [String: Any] = ["window": location.window, "tool": tool, "arguments": args]
        // Each running MarkView knows only its own windows: a list is the sum of what every one of them says.
        if fanOutTools.contains(tool), location.fallbacks.count > 1 {
            let replies = location.fallbacks.map { request(socket: $0, payload: payload) }
            let shown = replies.filter { !$0.isError }
            return shown.isEmpty ? replies[0] : Reply(text: shown.map(\.text).joined(separator: "\n\n"))
        }
        for candidate in location.fallbacks.dropLast() {
            let reply = request(socket: candidate, payload: payload)
            if !(reply.isError && isNoWindow(reply.text)) { return reply }
        }
        return request(socket: location.fallbacks.last ?? location.socket, payload: payload)
    }

    /// One call from the command line (`--project-call`): the same path as an MCP call, with the same "no app, no tools".
    static func callApp(profile: MCPProfile, arguments: [String], tool: String, args: [String: Any]) -> Reply {
        let location = locateApp(arguments: arguments)
        guard !location.socket.isEmpty else { return .error(profile.unavailableNote) }
        return forward(tool, args, to: location)
    }

    /// `MarkView --mcp-browser --diagnose`, typed in a terminal where an agent lacks the browser tools
    /// (BUG-026): which processes are above it, whether a MarkView is among them, and whether that
    /// MarkView knows the window. Prints and exits.
    static func diagnose(socket: String, window: String, ancestors: [Int32], viaAncestors: Bool, cwd: String, probe: String = "browser_tabs") -> Never {
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
        let reply = request(socket: socket, payload: ["window": window, "tool": probe, "arguments": [String: Any]()], timeout: 10)
        print(reply.isError ? "✗ " + reply.text : "✓ The window answered:\n" + reply.text)
        exit(reply.isError ? 1 : 0)
    }

    /// The control socket of the MarkView process `pid`: in the user's temporary folder (resolved
    /// by the system, not from `$TMPDIR`, which MCP clients may not pass on).
    static func socketPath(forApp pid: Int32) -> String {
        URL(fileURLWithPath: socketFolder, isDirectory: true).appendingPathComponent("mv-browser-\(pid).sock").path
    }

    /// Where the control sockets live. `MARKVIEW_SOCKET_DIR` exists for the checks in tools/tests, which must not meet
    /// a MarkView that runs on the same Mac.
    static var socketFolder: String {
        ProcessInfo.processInfo.environment["MARKVIEW_SOCKET_DIR"] ?? FileManager.default.temporaryDirectory.path
    }

    /// Tools the MCP server asks every running MarkView, then merges (`markview_windows`).
    static let fanOutTools: Set<String> = ["markview_windows"]

    /// How the app's reply starts when no window has the agent's folder (another MarkView may have it).
    static let noWindowPrefix = "No MarkView window has the folder"
    /// How a control tool's reply starts when no window matches the `window` it was given.
    static let noWindowMatchPrefix = "No MarkView window matches"

    /// Whether a reply says this MarkView has no such window, so that another running MarkView may.
    static func isNoWindow(_ text: String) -> Bool {
        text.hasPrefix(noWindowPrefix) || text.hasPrefix(noWindowMatchPrefix)
    }

    /// Control sockets of MarkView processes that are running, newest process first.
    static func runningAppSockets() -> [String] {
        let folder = socketFolder
        let pids = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { name -> Int32? in
            guard name.hasPrefix("mv-browser-"), name.hasSuffix(".sock") else { return nil }
            return Int32(name.dropFirst("mv-browser-".count).dropLast(".sock".count))
        }.filter { kill($0, 0) == 0 || errno == EPERM }
        return pids.sorted(by: >).map(socketPath(forApp:))
    }

    /// The window whose project folder holds `cwd` (the deepest one), else the only window.
    /// `strict`: only a window whose project holds the folder counts (the project tools write files).
    static func windowIndex(forFolder cwd: String, roots: [String?], strict: Bool = false) -> Int? {
        let path = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
        let matches = roots.enumerated().compactMap { index, root -> (Int, Int)? in
            guard let root, !root.isEmpty, !path.isEmpty else { return nil }
            let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/") ? (index, normalizedRoot.count) : nil
        }
        if let best = matches.max(by: { $0.1 < $1.1 }) { return best.0 }
        return roots.count == 1 && !strict ? 0 : nil
    }

    /// This process's parent, grandparent… up to launchd.
    static func ancestorPIDs() -> [Int32] {
        ancestorPIDs(startingAt: getppid())
    }

    /// Walks parent process IDs starting from `startPID` up to launchd (`AR-40`).
    static func ancestorPIDs(startingAt startPID: Int32) -> [Int32] {
        var out: [Int32] = []
        var pid = startPID
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
        var outbound = payload
        if outbound["token"] == nil, let token = PrivateSocket.readToken(forSocket: path) {
            outbound["token"] = token
        }
        guard let body = try? JSONSerialization.data(withJSONObject: outbound) else { return .error("Bad request") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .error("Cannot create a socket") }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        guard var address = PrivateSocket.address(path) else { return .error("Socket path too long") }
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
    static func withServer(_ entry: [String: Any], in root: [String: Any], name: String? = nil) -> [String: Any] {
        var root = root
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[name ?? serverName] = entry
        root["mcpServers"] = servers
        return root
    }

    /// Whether an MCP client's output says it refused a MarkView server by policy (a Copilot organisation
    /// that allows only listed MCP servers): `MCP server was blocked by policy: "markview-browser"`.
    static func reportsPolicyBlock(_ output: String) -> Bool {
        blockedPolicyServer(in: output) != nil
    }

    /// The MarkView MCP server name refused by an organisation's policy in `output`, or nil.
    /// Recognizes both quoted styles (`"markview-browser"`, `'markview-browser'`), checking longer names first.
    static func blockedPolicyServer(in output: String) -> String? {
        let text = output.lowercased()
        guard text.contains("blocked by policy") else { return nil }
        for candidate in [AgentMCPServer.markviewBrowserName, AgentMCPServer.markviewControlName, AgentMCPServer.markviewName] {
            if text.contains("\"\(candidate)\"") || text.contains("'\(candidate)'") {
                return candidate
            }
        }
        // Fallback when quotes were stripped or wrapped across lines, still avoiding matching `markview` inside `markview-browser`.
        if text.contains(AgentMCPServer.markviewBrowserName) { return AgentMCPServer.markviewBrowserName }
        if text.contains(AgentMCPServer.markviewControlName) { return AgentMCPServer.markviewControlName }
        return nil
    }

    /// The next free default name: T1, T2…
    static func nextTabName(taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var n = 1
        while used.contains("t\(n)") { n += 1 }
        return "T\(n)"
    }
}
