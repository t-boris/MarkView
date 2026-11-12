import AppKit
import Foundation
import WebKit

/// The app side of `BrowserAgentTools`: a Unix socket in the user's temporary folder that the
/// `--mcp-browser` processes of this app's terminals connect to. A request names the window — by
/// id, or by the processes above the MCP server (its terminal's shell) — and a tool; the tool runs
/// in one of that window's browser tabs (`BrowserAgentExecutor`).
@MainActor
enum BrowserControlServer {
    /// What a window offers agents: its browser tabs, the active one, bringing one to the front,
    /// and opening a new one.
    struct Window {
        /// The window's workspace, for the control tools (`ControlToolRunner`); nil once the window is gone.
        var workspace: () -> WorkspaceManager? = { nil }
        /// The window's project folder (agents outside its terminals are matched by their folder).
        var root: () -> URL?
        var tabs: () -> [BrowserSession]
        var active: () -> BrowserSession?
        var show: (BrowserSession) -> Void
        var open: (URL?, String?) -> BrowserSession
        /// The window's features and bugs, for the project tools (`ProjectToolRunner`).
        var features: () -> FeatureStore? = { nil }
        /// The window's Deployments, for the deployments tools (`DeploymentToolRunner`).
        var deployments: () -> DeploymentStore? = { nil }
        /// The window's Discussions, for the discussions tools (`DiscussionToolRunner`).
        var discussions: () -> DiscussionStore? = { nil }
    }

    private static var windows: [UUID: Window] = [:]
    private static var listening: String?

    /// The socket path of this app process, listening once started.
    static var socketPath: String? {
        if let listening { return listening }
        let path = BrowserAgentTools.socketPath(forApp: ProcessInfo.processInfo.processIdentifier)
        guard listen(at: path) else { return nil }
        listening = path
        return path
    }

    /// Per agent and per Mac: give it the server when it starts from the AI panel (default on). Off
    /// for an agent whose organisation blocks MCP servers it does not list (BUG-025).
    static func agentToolsKey(_ tool: CLITool) -> String { "browser.agentTools." + tool.rawValue }

    static func agentToolsEnabled(_ tool: CLITool) -> Bool {
        UserDefaults.standard.object(forKey: agentToolsKey(tool)) as? Bool ?? true
    }

    static func register(_ id: UUID, _ window: Window) {
        windows[id] = window
        _ = socketPath
    }

    static func unregister(_ id: UUID) {
        windows[id] = nil
    }

    /// The windows that exist now, for the control tools: each with the workspace that shows it. A window whose
    /// workspace is gone (closed) leaves the table here; one that has no host window yet (still being set up) is not listed.
    static func liveWindows() -> [(id: UUID, window: Window, workspace: WorkspaceManager)] {
        for (id, window) in windows where window.workspace() == nil { windows[id] = nil }
        return windows.compactMap { id, window in
            guard let workspace = window.workspace(), workspace.hostWindow != nil else { return nil }
            return (id, window, workspace)
        }
    }

    /// The arguments that start this binary as the MCP server for window `id`.
    static func mcpArguments(window id: UUID, flag: String = "--mcp-browser") -> (command: String, args: [String])? {
        guard let socket = socketPath, let executable = Bundle.main.executablePath else { return nil }
        return (executable, [flag, "--socket", socket, "--window", id.uuidString])
    }

    // MARK: - Socket

    private static func listen(at path: String) -> Bool {
        unlink(path)
        removeStaleSockets(near: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = BrowserAgentTools.unixAddress(path) else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            NSLog("[MarkView] browser control socket unavailable at \(path)")
            return false
        }
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global(qos: .userInitiated).async { serve(client) }
            }
        }
        thread.name = "MarkView browser control"
        thread.start()
        return true
    }

    /// Sockets of MarkView processes that are gone (they are not removed on quit).
    private static func removeStaleSockets(near path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            guard name.hasPrefix("mv-browser-"), name.hasSuffix(".sock"),
                  let pid = Int32(name.dropFirst("mv-browser-".count).dropLast(".sock".count)),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { unlink((folder as NSString).appendingPathComponent(name)) }
        }
    }

    /// One connection: a request line in, a reply line out.
    private nonisolated static func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let line = BrowserAgentTools.readLine(client),
              let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            close(client)
            return
        }
        let window = (request["window"] as? String).flatMap(UUID.init(uuidString:))
        let pids = (request["pids"] as? [Int] ?? []).map(Int32.init)
        let cwd = request["cwd"] as? String ?? ""
        let declared = request["folderDeclared"] as? Bool ?? false
        // Older servers do not say; their folder counts.
        let trusted = request["cwdTrusted"] as? Bool ?? true
        let tool = request["tool"] as? String ?? ""
        nonisolated(unsafe) let arguments = request["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let reply = await perform(tool, arguments, window: window, pids: pids, cwd: cwd, declared: declared, cwdTrusted: trusted)
            let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BrowserAgentTools.writeAll(client, data + Data("\n".utf8))
                close(client)
            }
        }
    }

    // MARK: - Tools

    /// Relay sessions address only their work-computer window, never a folder or process on the home Mac.
    static func performRemoteBrowser(_ tool: String, arguments: RemoteJSON, window id: UUID,
                                     root: URL, agent: CLITool) async -> RemoteJSON {
        guard BrowserControlServer.agentToolsEnabled(agent) else {
            return .textResult("Browser tools for this assistant are turned off in the globe menu.", error: true)
        }
        guard RemoteWorkspaceTools.browserNames.contains(tool), let window = windows[id],
              let workspace = window.workspace(), (workspace.aiWorkspaceRoot ?? workspace.rootNode?.url)?.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else {
            return .textResult("The connected project window was closed or changed. Reconnect before using its browser.", error: true)
        }
        guard let data = try? JSONEncoder().encode(arguments == .null ? .object([:]) : arguments),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .textResult("Browser arguments must be an object.", error: true)
        }
        let reply = await perform(tool, args, window: id, pids: [], cwd: root.path)
        guard let result = try? JSONSerialization.data(withJSONObject: reply.mcpResult),
              let json = try? JSONDecoder().decode(RemoteJSON.self, from: result) else {
            return .textResult("Could not encode the browser result.", error: true)
        }
        return json
    }

    private static func perform(_ tool: String, _ args: [String: Any], window id: UUID?, pids: [Int32], cwd: String,
                                 declared: Bool = false, cwdTrusted: Bool = true) async -> BrowserAgentTools.Reply {
        // The control tools name their window themselves (`window`), or take the caller's folder when it says one.
        if ControlAgentTools.names.contains(tool) {
            return await ControlToolRunner.run(tool, args, caller: .init(pids: pids, folder: declared || cwdTrusted ? cwd : ""))
        }
        let isProjectTool = ProjectAgentTools.toolNames.contains(tool)
        guard isProjectTool || TerminalBrowserBridge.isEnabled else {
            return .error("MarkView's browser for terminals is turned off (globe menu → Open Terminal Links in MarkView).")
        }
        let known = id.flatMap { windows[$0] != nil ? $0 : nil } ?? TerminalBrowserBridge.windowID(forAncestors: pids)
        // A shared background daemon's folder says nothing about the asking agent: without the folder the agent
        // gave, with several windows open, ask for it rather than pick one (the project tools would write to it).
        if known == nil, BrowserAgentTools.needsFolder(declared: declared, cwdTrusted: cwdTrusted, windowCount: windows.values.filter { $0.root() != nil }.count) {
            return .error(BrowserAgentTools.folderRequired)
        }
        // The project tools write files, and a window that is already fixed (the agent runs in it) takes no other
        // project: a folder the agent names that is not this window's project is refused, not silently ignored.
        if isProjectTool, declared, let known, let root = windows[known]?.root()?.path,
           !BrowserAgentTools.folder(cwd, isInProject: root) {
            return .error(BrowserAgentTools.wrongProject(declared: cwd, root: root))
        }
        let windowID = known ?? windowForFolder(cwd, strict: isProjectTool)
        guard let windowID, let window = windows[windowID] else {
            let open = windows.values.compactMap { $0.root()?.path }.sorted()
            return .error(BrowserAgentTools.noWindowPrefix + " this agent works in (\(cwd.isEmpty ? "unknown" : cwd)) open."
                          + (open.isEmpty ? "" : " Open project windows: " + open.joined(separator: ", ")))
        }
        if isProjectTool, DeploymentAgentTools.names.contains(tool) {
            guard let store = window.deployments() else { return .error("This window has no project open.") }
            return await DeploymentToolRunner.run(tool, args, store: store)
        }
        if isProjectTool, DiscussionAgentTools.names.contains(tool) {
            guard let store = window.discussions() else { return .error("This window has no project open.") }
            return DiscussionToolRunner.run(tool, args, store: store)
        }
        if isProjectTool {
            guard let store = window.features() else { return .error("This window has no project open.") }
            if LifecycleToolRunner.handles(tool, args) { return await LifecycleToolRunner.run(tool, args, store: store) }
            return ProjectToolRunner.run(tool, args, store: store)
        }
        switch tool {
        case "browser_tabs":
            return BrowserAgentTools.Reply(text: tabList(window))
        case "browser_open_tab":
            let url = (args["url"] as? String).flatMap { BrowserAddress.url(from: $0) ?? URL(string: $0) }
            let session = window.open(url, (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            session.agentLastUsed = Date()
            if url != nil { await BrowserAgentExecutor.settle(session, started: true) }
            return BrowserAgentTools.Reply(text: "Opened tab \(session.agentName)." + (url == nil ? "" : " " + BrowserAgentExecutor.status(session).text))
        default:
            let session: BrowserSession
            if let query = args["tab"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let tabs = window.tabs()
                guard let index = BrowserAgentTools.tabIndex(query, in: tabs.map { ($0.agentName, $0.displayTitle, $0.url?.absoluteString ?? "") }) else {
                    return .error("No single browser tab matches “\(query)”.\n" + tabList(window))
                }
                session = tabs[index]
            } else {
                session = window.active() ?? window.tabs().first ?? window.open(nil, nil)
            }
            guard !session.agentStopped else {
                return .error("The user stopped agent control of tab \(session.agentName). Do not retry; ask the user.")
            }
            window.show(session)
            session.agentLastUsed = Date()
            return await BrowserAgentExecutor.run(tool, args, in: session)
        }
    }

    /// BUG-027: an agent running its tools outside the terminal (Cline's background hub): the window
    /// whose project holds the agent's folder, else the only window.
    private static func windowForFolder(_ cwd: String, strict: Bool = false) -> UUID? {
        let entries = Array(windows)
        guard let index = BrowserAgentTools.windowIndex(forFolder: cwd, roots: entries.map { $0.value.root()?.path }, strict: strict) else { return nil }
        return entries[index].key
    }

    private static func tabList(_ window: Window) -> String {
        let active = window.active()
        let tabs = window.tabs()
        guard !tabs.isEmpty else { return "No browser tabs are open; browser_open_tab opens one." }
        return tabs.map { tab in
            var line = "\(tab.agentName): \(tab.displayTitle) — \(tab.url?.absoluteString ?? "(empty)")"
            if tab === active { line += " [active]" }
            if tab.agentStopped { line += " [stopped by the user]" }
            return line
        }.joined(separator: "\n")
    }
}

/// Performs the agent tools on a browser tab's web view.
@MainActor
enum BrowserAgentExecutor {
    /// WebKit supplies each frame handle. Page messages can identify a visible
    /// child element, but cannot manufacture a native handle for another tab.
    final class Frames: NSObject, WKScriptMessageHandler {
        static let handler = "markviewAgentFrame"
        struct Hop { var parent: WKFrameInfo?; var token: String }
        struct Entry { var number: Int; var info: WKFrameInfo; var chain: [Hop] = [] }
        private var entries: [String: Entry] = [:]
        private var active: Set<Int> = []
        private var next = 0

        func install(in controller: WKUserContentController) {
            controller.add(self, contentWorld: .defaultClient, name: Self.handler)
            controller.addUserScript(WKUserScript(source: Self.registration, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .defaultClient))
        }
        func reset() { entries = [:]; active = []; next = 0 }
        func beginSnapshot() { active = [] }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !message.frameInfo.isMainFrame, let token = message.body as? String,
                  token.range(of: "^[a-zA-Z0-9-]{8,80}$", options: .regularExpression) != nil,
                  entries[token] == nil, entries.count < 128 else { return }
            next += 1
            entries[token] = Entry(number: next, info: message.frameInfo)
        }
        func activate(_ token: String, chain: [Hop]) -> Entry? {
            guard var entry = entries[token] else { return nil }
            entry.chain = chain; entries[token] = entry; active.insert(entry.number)
            return entry
        }
        func entry(for ref: String) -> Entry? {
            guard let colon = ref.firstIndex(of: ":"), ref.hasPrefix("f"),
                  let number = Int(ref[ref.index(after: ref.startIndex)..<colon]), active.contains(number) else { return nil }
            return entries.values.first { $0.number == number }
        }
        static func localRef(_ ref: String) -> String { String(ref.split(separator: ":").last ?? Substring(ref)) }
        static func validRef(_ ref: String) -> Bool {
            ref.range(of: "^(?:f[0-9]{1,3}:)?e[0-9]{1,6}$", options: .regularExpression) != nil
        }
        private static let registration = #"""
        addEventListener('message', event => {
          const token = event.data && event.data.__markviewAgentFrame;
          if (typeof token !== 'string' || !/^[a-zA-Z0-9-]{8,80}$/.test(token)) return;
          for (const el of document.querySelectorAll('iframe,frame')) {
            if (el.contentWindow === event.source) { el.setAttribute('data-mv-frame', token); break; }
          }
        });
        if (window !== window.top) {
          const token = 'mv-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
          window.webkit.messageHandlers.markviewAgentFrame.postMessage(token);
          window.parent.postMessage({__markviewAgentFrame:token}, '*');
        }
        """#
    }

    private struct Target {
        var arguments: [String: Any]
        var entry: Frames.Entry?
    }
    private static func target(_ args: [String: Any], in session: BrowserSession) -> Target? {
        guard let ref = (args["ref"] ?? args["frame_ref"]) as? String, ref.hasPrefix("f") else {
            return Target(arguments: args)
        }
        guard Frames.validRef(ref), let entry = session.agentFrames.entry(for: ref) else { return nil }
        var local = args
        local["ref"] = Frames.localRef(ref)
        return Target(arguments: local, entry: entry)
    }

    /// Bring the embedding frames into view and project child CSS coordinates
    /// through their borders and any CSS scaling into the main viewport.
    private static func frameGeometry(_ target: Target, web: WKWebView, scroll: Bool) async -> (x: Double, y: Double, sx: Double, sy: Double)? {
        var result = (x: 0.0, y: 0.0, sx: 1.0, sy: 1.0)
        for hop in target.entry?.chain ?? [] {
            let reply = await script(web, #"""
            const el = document.querySelector('[data-mv-frame="'+token+'"]');
            if (!el) return null;
            if (scroll) el.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
            const r = el.getBoundingClientRect();
            const sx = r.width / (el.offsetWidth || r.width), sy = r.height / (el.offsetHeight || r.height);
            return JSON.stringify({x:r.x+el.clientLeft*sx,y:r.y+el.clientTop*sy,sx,sy});
            """#, ["token": hop.token, "scroll": scroll], in: hop.parent) { $0 as? String ?? "" }
            guard !reply.isError, let data = reply.text.data(using: .utf8),
                  let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double],
                  let x = r["x"], let y = r["y"], let sx = r["sx"], let sy = r["sy"] else { return nil }
            result.x += x * result.sx; result.y += y * result.sy
            result.sx *= sx; result.sy *= sy
        }
        return result
    }

    private static func snapshot(_ session: BrowserSession) async -> BrowserAgentTools.Reply {
        let web = session.webView
        func page(in frame: WKFrameInfo?) async -> [String: Any]? {
            let reply = await script(web, Scripts.snapshot, [:], in: frame) { $0 as? String ?? "" }
            guard !reply.isError, let data = reply.text.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let main = await page(in: nil) else { return .error("The page could not be read.") }
        session.agentFrames.beginSnapshot()
        var children: [String] = [], visited: Set<Int> = []
        func collect(_ parent: [String: Any], frame: WKFrameInfo?, chain: [Frames.Hop], depth: Int) async {
            guard depth < 8 else { return }
            for child in parent["frames"] as? [[String: Any]] ?? [] {
                guard visited.count < 16, let token = child["token"] as? String,
                      let entry = session.agentFrames.activate(token, chain: chain + [Frames.Hop(parent: frame, token: token)]),
                      visited.insert(entry.number).inserted, let content = await page(in: entry.info) else { continue }
                let elements = (content["elements"] as? [String] ?? []).map { line -> String in
                    guard line.hasPrefix("[e") else { return line }
                    return "[f\(entry.number):" + line.dropFirst()
                }.joined(separator: "\n")
                let title = String((child["title"] as? String ?? "embedded page").prefix(120))
                children.append("## Frame f\(entry.number): \(title) (\(entry.info.securityOrigin.host))\n\(elements)\n\nVisible text:\n\(content["viewportText"] ?? "")")
                await collect(content, frame: entry.info, chain: entry.chain, depth: depth + 1)
            }
        }
        await collect(main, frame: nil, chain: [], depth: 0)
        let elements = (main["elements"] as? [String] ?? []).joined(separator: "\n")
        return BrowserAgentTools.Reply(text: """
        Tab: \(session.agentName)
        URL: \(main["url"] ?? "")
        Title: \(main["title"] ?? "")

        ## Visible text
        \(main["viewportText"] ?? "")

        \(children.joined(separator: "\n\n"))

        ## Elements
        \(elements.isEmpty ? "(none)" : elements)

        ## Text (full-page excerpt; scroll to bring more text into view)
        \(main["text"] ?? "")
        """)
    }
    static func run(_ tool: String, _ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        session.agentControlled = true
        let web = session.webView
        switch tool {
        case "browser_navigate":
            guard let raw = args["url"] as? String, let url = BrowserAddress.url(from: raw) ?? URL(string: raw) else {
                return .error("A URL is required.")
            }
            session.load(url)
            await settle(session, started: true)
            return status(session)
        case "browser_snapshot":
            return await snapshot(session)
        case "browser_click":
            return await click(args, in: session)
        case "browser_type":
            return await type(args, in: session)
        case "browser_press_key":
            let key = args["key"] as? String ?? ""
            guard !key.isEmpty else { return .error("A key is required.") }
            let reply: BrowserAgentTools.Reply
            if canUseNativeInput(web), let event = keyEvents(key, in: web) {
                withFocus(web) {
                    web.keyDown(with: event.down)
                    web.keyUp(with: event.up)
                }
                reply = BrowserAgentTools.Reply(text: "Pressed \(key).")
            } else {
                reply = await script(web, Scripts.pressKey, ["key": key]) { $0 as? String ?? "" }
            }
            await settle(session, started: false)
            return reply
        case "browser_evaluate":
            guard let body = args["script"] as? String, !body.isEmpty else { return .error("A script is required.") }
            guard let chosen = target(args, in: session) else { return .error("The frame is no longer on the page. Take a new browser_snapshot.") }
            return await script(web, "return JSON.stringify(await (async () => { \(body)\n })(), null, 1) ?? 'undefined';", [:], in: chosen.entry?.info) {
                $0 as? String ?? "undefined"
            }
        case "browser_screenshot":
            return await screenshot(web)
        case "browser_console":
            let clear = (args["clear"] as? Bool) == true
            let reply = await script(web, Scripts.console, ["clear": clear]) { $0 as? String ?? "" }
            let dialogs = session.agentDialogs.map { "dialog: " + $0 }
            if clear { session.agentDialogs = [] }
            let text = ([reply.text] + dialogs).filter { !$0.isEmpty }.joined(separator: "\n")
            return BrowserAgentTools.Reply(text: text.isEmpty ? "(no console messages)" : text, isError: reply.isError)
        case "browser_wait_for":
            let limit = min(max((args["timeout_ms"] as? Int) ?? 10_000, 0), 60_000)
            let deadline = Date().addingTimeInterval(Double(limit) / 1000)
            guard let text = args["text"] as? String, !text.isEmpty else {
                try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000)
                return status(session)
            }
            while Date() < deadline {
                let found = try? await web.callAsyncJavaScript("return (document.body ? document.body.innerText : '').includes(t);",
                                                               arguments: ["t": text], in: nil, contentWorld: .page) as? Bool
                if found == true { return BrowserAgentTools.Reply(text: "Found “\(text)”.") }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return .error("“\(text)” did not appear within \(limit) ms.")
        case "browser_back":
            guard web.canGoBack else { return .error("There is no previous page.") }
            web.goBack()
            await settle(session, started: true)
            return status(session)
        case "browser_reload":
            session.reload()
            await settle(session, started: true)
            return status(session)
        default:
            return .error("Unknown tool \(tool).")
        }
    }

    // MARK: Real input (trusted events)

    /// Native events need the web view on screen in its window.
    private static func canUseNativeInput(_ web: WKWebView) -> Bool {
        web.window != nil && web.bounds.width > 0 && web.bounds.height > 0 && !web.isHiddenOrHasHiddenAncestor
    }

    /// A mouse click on the element's centre as the user's own (`isTrusted`) click; a script click
    /// when the tab is not on screen or something else covers the element.
    private static func click(_ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        let web = session.webView
        guard let chosen = target(args, in: session), await frameGeometry(chosen, web: web, scroll: true) != nil else {
            return .error("The frame is no longer on the page. Take a new browser_snapshot.")
        }
        let located = await script(web, Scripts.find + Scripts.locate, ["a": chosen.arguments], in: chosen.entry?.info) { $0 as? String ?? "" }
        guard !located.isError, let data = located.text.data(using: .utf8),
              let target = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return located }
        let description = target["describe"] as? String ?? "the element"
        if (target["disabled"] as? Bool) == true { return .error("\(description) is disabled.") }
        guard let geometry = await frameGeometry(chosen, web: web, scroll: false) else { return .error("The embedding frame moved. Take a new browser_snapshot.") }
        let point = CGPoint(x: geometry.x + (target["x"] as? Double ?? 0) * geometry.sx,
                            y: geometry.y + (target["y"] as? Double ?? 0) * geometry.sy)
        var how = "with a mouse click"
        if canUseNativeInput(web), (target["hit"] as? Bool) == true, let window = web.window {
            let location = windowPoint(point, in: web)
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                switch type {
                case .mouseMoved: web.mouseMoved(with: event)
                case .leftMouseDown: web.mouseDown(with: event)
                default: web.mouseUp(with: event)
                }
            }
        } else {
            let reply = await script(web, Scripts.find + Scripts.click, ["a": chosen.arguments], in: chosen.entry?.info) { $0 as? String ?? "" }
            guard !reply.isError else { return reply }
            how = (target["hit"] as? Bool) == false ? "by script (another element covers it)" : "by script (the tab is not on screen)"
        }
        await settle(session, started: false)
        return BrowserAgentTools.Reply(text: "Clicked \(description) \(how).\n" + status(session).text)
    }

    /// Focus the field, select what it holds (unless appending), and type the text through the web
    /// view's text input as real keystrokes; a script sets the value when that did not take.
    private static func type(_ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        let web = session.webView
        let value = args["value"] as? String ?? ""
        guard let chosen = target(args, in: session), await frameGeometry(chosen, web: web, scroll: true) != nil else {
            return .error("The frame is no longer on the page. Take a new browser_snapshot.")
        }
        let prepared = await script(web, Scripts.find + Scripts.prepareTyping, ["a": chosen.arguments], in: chosen.entry?.info) { $0 as? String ?? "" }
        guard !prepared.isError else { return prepared }
        var how = "as keystrokes"
        var typed = false
        if canUseNativeInput(web), let client = web as? NSTextInputClient {
            withFocus(web) { client.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let current = await script(web, Scripts.typedValue, ["expected": value], in: chosen.entry?.info) { ($0 as? Bool) == true ? "yes" : "no" }
            typed = value.isEmpty || current.text == "yes"
        }
        if !typed {
            let reply = await script(web, Scripts.find + Scripts.type, ["a": chosen.arguments.merging(["submit": false]) { $1 }], in: chosen.entry?.info) { $0 as? String ?? "" }
            guard !reply.isError else { return reply }
            how = "by script"
        }
        if (args["submit"] as? Bool) == true {
            if canUseNativeInput(web), let enter = keyEvents("Enter", in: web) {
                withFocus(web) {
                    web.keyDown(with: enter.down)
                    web.keyUp(with: enter.up)
                }
            } else {
                _ = await script(web, Scripts.pressKey, ["key": "Enter"]) { $0 as? String ?? "" }
            }
            await settle(session, started: false)
            return BrowserAgentTools.Reply(text: "Typed into \(prepared.text) \(how) and pressed Enter.\n" + status(session).text)
        }
        return BrowserAgentTools.Reply(text: "Typed into \(prepared.text) \(how).")
    }

    /// Run `body` with the web view as its window's first responder (key events and text input go
    /// to the first responder), then give the focus back to where it was.
    private static func withFocus(_ web: WKWebView, _ body: () -> Void) {
        guard let window = web.window else { return body() }
        let previous = window.firstResponder
        if previous !== web { window.makeFirstResponder(web) }
        body()
        if let previous, previous !== web { window.makeFirstResponder(previous) }
    }

    /// A point in page (CSS) pixels of the visible viewport → the window's coordinates.
    private static func windowPoint(_ point: CGPoint, in web: WKWebView) -> CGPoint {
        let scale = web.pageZoom * web.magnification
        var local = CGPoint(x: point.x * scale, y: point.y * scale)
        if !web.isFlipped { local.y = web.bounds.height - local.y }
        return web.convert(local, to: nil)
    }

    private static func keyEvents(_ key: String, in web: WKWebView) -> (down: NSEvent, up: NSEvent)? {
        func function(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        let named: [String: (code: UInt16, characters: String)] = [
            "Enter": (36, "\r"), "Return": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"),
            "Backspace": (51, "\u{7f}"), "Delete": (117, function(NSDeleteFunctionKey)), "Space": (49, " "),
            "ArrowUp": (126, function(NSUpArrowFunctionKey)), "ArrowDown": (125, function(NSDownArrowFunctionKey)),
            "ArrowLeft": (123, function(NSLeftArrowFunctionKey)), "ArrowRight": (124, function(NSRightArrowFunctionKey)),
            "Home": (115, function(NSHomeFunctionKey)), "End": (119, function(NSEndFunctionKey)),
            "PageUp": (116, function(NSPageUpFunctionKey)), "PageDown": (121, function(NSPageDownFunctionKey)),
        ]
        guard let window = web.window else { return nil }
        guard let spec = named[key] ?? (key.count == 1 ? (0, key) : nil) else { return nil }
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: spec.characters,
                             charactersIgnoringModifiers: spec.characters, isARepeat: false, keyCode: spec.code)
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { return nil }
        return (down, up)
    }

    // MARK: Helpers

    /// Wait until the page has loaded (at most 30 s). `started`: a load was just asked for; else
    /// give an action a moment to start one.
    static func settle(_ session: BrowserSession, started: Bool) async {
        try? await Task.sleep(nanoseconds: started ? 150_000_000 : 350_000_000)
        let deadline = Date().addingTimeInterval(30)
        while session.webView.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func status(_ session: BrowserSession) -> BrowserAgentTools.Reply {
        if let error = session.loadError { return .error("Could not load \(session.url?.absoluteString ?? "the page"): \(error)") }
        return BrowserAgentTools.Reply(text: "Tab \(session.agentName): \(session.webView.url?.absoluteString ?? "") — \(session.webView.title ?? "")")
    }

    private static func script(_ web: WKWebView, _ body: String, _ arguments: [String: Any], in frame: WKFrameInfo? = nil,
                               format: (Any?) -> String) async -> BrowserAgentTools.Reply {
        do {
            let value = try await web.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: .page)
            let text = format(value)
            if text.hasPrefix("ERROR: ") { return .error(String(text.dropFirst(7))) }
            return BrowserAgentTools.Reply(text: text)
        } catch {
            return .error("JavaScript error: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)")
        }
    }

    private static func screenshot(_ web: WKWebView) async -> BrowserAgentTools.Reply {
        guard web.window != nil, web.bounds.width > 0 else {
            return .error("The browser tab is not visible in its window, so it cannot be captured.")
        }
        guard let image = try? await web.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return .error("The screenshot failed.")
        }
        return BrowserAgentTools.Reply(text: "Screenshot of \(web.url?.absoluteString ?? "the page")", pngBase64: png.base64EncodedString())
    }

    /// Page-side scripts (run with `callAsyncJavaScript` in the page's world).
    enum Scripts {
        static let snapshot = #"""
        const out = [];
        let n = window.__mvRefCounter || 0;
        const visible = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
          return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
        const sel = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=switch],[role=combobox],[contenteditable=true],[onclick]';
        const onScreen = el => { const r = el.getBoundingClientRect(); return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth; };
        const candidates = [...document.querySelectorAll(sel)].filter(visible);
        candidates.sort((a,b) => Number(onScreen(b)) - Number(onScreen(a)));
        for (const el of candidates) {
          if (out.length >= 300) break;
          if (!visible(el)) continue;
          let ref = el.getAttribute('data-mv-ref');
          if (!ref) { ref = 'e' + (++n); el.setAttribute('data-mv-ref', ref); }
          const tag = el.tagName.toLowerCase();
          const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? 'input:' + (el.type || 'text') : tag);
          const name = (el.getAttribute('aria-label') || el.innerText || el.placeholder || el.title || el.name || '').trim().replace(/\s+/g, ' ').slice(0, 80);
          let extra = '';
          if (tag === 'a') extra += ' -> ' + el.getAttribute('href');
          if (el.type === 'checkbox' || el.type === 'radio') extra += el.checked ? ' [checked]' : ' [unchecked]';
          else if ((tag === 'input' || tag === 'textarea' || tag === 'select') && el.value && el.type !== 'password') {
            const sensitive = /cc-number|cc-csc/.test(el.autocomplete || '') || /^(cardnumber|cvc|cvv)$/i.test(el.name || '');
            const value = sensitive ? '[entered]' : String(el.value);
            extra += ' value=' + JSON.stringify(value.slice(0, 4000));
            if (value.length > 4000) extra += ' [value truncated: ' + value.length + ' characters total]';
          }
          if (el.disabled) extra += ' (disabled)';
          out.push('[' + ref + '] ' + role + ' "' + name + '"' + extra);
        }
        window.__mvRefCounter = n;
        const viewport = [];
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        let node, examined = 0, length = 0;
        while ((node = walker.nextNode()) && examined++ < 30000 && length < 4000) {
          const parent = node.parentElement, value = node.textContent.trim();
          if (!value || !parent || /^(SCRIPT|STYLE|NOSCRIPT|OPTION)$/.test(parent.tagName) || getComputedStyle(parent).visibility === 'hidden') continue;
          const range = document.createRange(); range.selectNodeContents(node);
          if ([...range.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth)) {
            viewport.push(value.slice(0, 4000-length)); length += value.length;
          }
        }
        const frames = [...document.querySelectorAll('iframe,frame')].filter(el => visible(el) && el.clientWidth > 1 && el.clientHeight > 1)
          .sort((a,b) => Number(onScreen(b)) - Number(onScreen(a)))
          .map(el => ({token:el.getAttribute('data-mv-frame'),title:el.title || 'embedded page'})).filter(f => f.token);
        const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 15000);
        return JSON.stringify({ url: location.href, title: document.title, text, viewportText:viewport.join('\n'), elements: out, frames });
        """#

        static let find = #"""
        const find = (a) => {
          if (a.ref) return document.querySelector('[data-mv-ref="' + a.ref + '"]');
          if (a.selector) return document.querySelector(a.selector);
          if (a.text) {
            // Buttons and links by their text; fields by placeholder, aria-label or <label>.
            const t = a.text.trim().toLowerCase();
            const name = e => (e.getAttribute('aria-label') || e.placeholder || (e.labels && e.labels[0] && e.labels[0].innerText)
              || e.innerText || (e.type === 'submit' || e.type === 'button' ? e.value : '') || e.title || '').trim().toLowerCase();
            const all = [...document.querySelectorAll('a,button,input,textarea,select,[contenteditable=true],[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],summary')];
            return all.find(e => name(e) === t) || all.find(e => name(e).includes(t));
          }
          return null;
        };
        const describe = (el) => el.tagName.toLowerCase() + ' "' + (el.getAttribute('aria-label') || el.innerText || el.placeholder || el.name || (/^(submit|button|reset)$/.test(el.type) ? el.value : '') || '').trim().replace(/\s+/g, ' ').slice(0, 60) + '"';
        const el = find(a);
        if (!el) return 'ERROR: No element matches ' + JSON.stringify(a.ref || a.selector || a.text || '(nothing given)') + '. Take a new browser_snapshot.';
        el.scrollIntoView({ block: 'center', inline: 'center' });
        """#

        /// The element's centre in viewport pixels, and whether a click there reaches it.
        static let locate = #"""
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        const top = document.elementFromPoint(x, y);
        return JSON.stringify({ x, y, hit: !!top && (top === el || el.contains(top) || top.contains(el)),
                                disabled: !!el.disabled, describe: describe(el) });
        """#

        static let click = #"""
        if (el.disabled) return 'ERROR: ' + describe(el) + ' is disabled.';
        if (el.focus) el.focus();
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
          el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        el.click();
        return 'Clicked ' + describe(el) + '.';
        """#

        /// Focus the field and select its content, so typing replaces it (or put the caret at the end).
        static let prepareTyping = #"""
        el.focus();
        if (el.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(el);
          if (a.append) range.collapse(false);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } else if ('value' in el && typeof el.select === 'function') {
          if (a.append) { try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {} } else { el.select(); }
        } else {
          return 'ERROR: ' + describe(el) + ' does not take text.';
        }
        return describe(el);
        """#

        /// Compare inside the frame: never return a password or card value.
        /// Payment Elements format a pasted card/expiry, so whitespace and
        /// separator changes are not evidence that native typing failed.
        static let typedValue = #"""
        const el = document.activeElement;
        if (!el) return false;
        const actual = el.isContentEditable ? el.textContent : String(el.value ?? '');
        if (actual.includes(expected)) return true;
        if (/cc-number|cc-exp|cc-csc|tel/.test(el.autocomplete || '') || /^(cardnumber|cardexpiry|cvc|cvv)$/i.test(el.name || '')) {
          const digits = expected.replace(/\D/g, '');
          return digits.length > 0 && actual.replace(/\D/g, '').includes(digits);
        }
        return false;
        """#

        static let type = #"""
        const value = String(a.value ?? '');
        el.focus();
        if (el.isContentEditable) {
          el.textContent = a.append ? el.textContent + value : value;
          el.dispatchEvent(new InputEvent('input', { bubbles: true }));
        } else if ('value' in el) {
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
            : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, a.append ? el.value + value : value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else {
          return 'ERROR: ' + describe(el) + ' does not take text.';
        }
        return 'Typed into ' + describe(el) + '.';
        """#

        static let pressKey = #"""
        const el = document.activeElement || document.body;
        const named = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, Delete: 46, Space: 32, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35, PageUp: 33, PageDown: 34 };
        const code = named[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
        const init = { key: key === 'Space' ? ' ' : key, keyCode: code, which: code, bubbles: true, cancelable: true };
        const go = el.dispatchEvent(new KeyboardEvent('keydown', init));
        if (key.length === 1) el.dispatchEvent(new KeyboardEvent('keypress', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
        if (go && key === 'Enter' && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
        return 'Pressed ' + key + ' on ' + el.tagName.toLowerCase() + '.';
        """#

        static let console = #"""
        const log = window.__mvConsole || [];
        const text = log.join('\n');
        if (clear) log.length = 0;
        return text;
        """#
    }
}
