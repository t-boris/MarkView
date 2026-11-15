import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
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
    /// The open control socket and its per-instance token (`AR-40`, `DEC-009`, `PrivateSocket`).
    private static var listener: PrivateSocket.Listener?

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
        removeStaleSockets(near: path)
        let opened: PrivateSocket.Listener
        do {
            opened = try PrivateSocket.open(at: path)
        } catch {
            AppLog.browser.error("browser control socket unavailable at \(path): \(error)")
            return false
        }
        listener = opened
        let thread = Thread {
            while true {
                let client = accept(opened.fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                DispatchQueue.global(qos: .userInitiated).async { serve(client, listener: opened) }
            }
        }
        thread.name = "MarkView browser control"
        thread.start()
        return true
    }

    /// Stops accepting new connections and removes the control socket and token files (`FU-03`).
    static func shutdown() {
        listener?.stop()
        listener = nil
        listening = nil
    }

    /// Sockets of MarkView processes that are gone (they are not removed on quit).
    private static func removeStaleSockets(near path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            guard name.hasPrefix("mv-browser-"), name.hasSuffix(".sock"),
                  let pid = Int32(name.dropFirst("mv-browser-".count).dropLast(".sock".count)),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                PrivateSocket.remove(socketAt: (folder as NSString).appendingPathComponent(name))
            }
        }
    }

    /// One connection: a request line in, a reply line out.
    private nonisolated static func serve(_ client: Int32, listener: PrivateSocket.Listener) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let peer = PrivateSocket.peer(of: client)
        guard peer.isCurrentUser else {
            close(client)
            return
        }
        guard let line = BrowserAgentTools.readLine(client),
              let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            close(client)
            return
        }
        if !listener.accepts(token: request["token"] as? String) {
            let errData = (try? JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply.error("Control socket authentication failed: missing or invalid instance token.").json)) ?? Data()
            _ = BrowserAgentTools.writeAll(client, errData + Data("\n".utf8))
            close(client)
            return
        }
        let window = (request["window"] as? String).flatMap(UUID.init(uuidString:))
        let clientReportedPIDs = (request["pids"] as? [Int] ?? []).map(Int32.init)
        // Prefer kernel-verified peer PID ancestry (`LOCAL_PEERPID`, AR-40) over unverified client-supplied PIDs.
        let pids: [Int32]
        if let peerPID = peer.pid {
            let kernelAncestors = BrowserAgentTools.ancestorPIDs(startingAt: peerPID)
            pids = kernelAncestors.isEmpty ? clientReportedPIDs : kernelAncestors
        } else {
            pids = clientReportedPIDs
        }
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
              let workspace = window.workspace(), (workspace.aiWorkspaceRoot ?? workspace.project.root)?.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else {
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

    /// The reason a call is refused when it comes from the agent of a running Cockpit step (its shell is among `pids`), else nil.
    /// The step's terminal belongs to a window, which knows the project's bug workflow and its deployment environments.
    private static func cockpitRefusal(_ tool: String, _ args: [String: Any], pids: [Int32]) -> String? {
        guard !pids.isEmpty else { return nil }
        let window = TerminalBrowserBridge.windowID(forAncestors: pids).flatMap { windows[$0] }
        let workflow = window?.features()?.lifecycle.workflow ?? .standard
        let deployments = window?.deployments()
        let decision = CockpitAgentRegistry.gate(
            tool: tool, arguments: args, ancestors: pids,
            isFixingStatus: { status in workflow.role(.bug, status) == .active },
            environmentNames: { id in deployments?.environment(id).map { [$0.name] } ?? [] })
        if case .refuse(let reason)? = decision { return reason }
        return nil
    }

    private static func perform(_ tool: String, _ args: [String: Any], window id: UUID?, pids: [Int32], cwd: String,
                                 declared: Bool = false, cwdTrusted: Bool = true) async -> BrowserAgentTools.Reply {
        // The agent of a Cockpit step gets only the tools its controls allow, whichever family a tool belongs to.
        if let refusal = cockpitRefusal(tool, args, pids: pids) { return .error(refusal) }
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
            if tool == "markview_cockpit_report_progress" { return await ProjectToolRunner.reportCockpitProgress(args, store: store) }
            if tool == "markview_cockpit_ask" { return await ProjectToolRunner.askCockpitSupervisor(args, store: store) }
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
