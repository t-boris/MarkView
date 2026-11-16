import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The app side of the MCP servers of this binary (`--mcp-browser`, `--mcp-project`, `--mcp-control`): a Unix socket in the user's
/// temporary folder that the servers of this app's terminals connect to. A request names the window (by id, or by the processes
/// above the MCP server, its terminal's shell) and a tool, and the tool runs for that window: the control, project, deployments,
/// discussions and lifecycle tools on its stores (`ControlToolRunner`, `ProjectToolRunner`, ...), a browser tool in its browser
/// tabs (`AgentToolWindow.browser`). Windows register themselves; the Browser domain depends on this one for that, not the reverse.
@MainActor
enum AgentToolServer {
    private static var windows: [UUID: AgentToolWindow] = [:]
    private static var listening: String?
    private static var windowOpener: ((URL) -> Bool)?

    static func setWindowOpener(_ opener: @escaping (URL) -> Bool) { windowOpener = opener }
    static func openWindow(folder: URL) -> Bool { windowOpener?(folder) ?? false }
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

    static func register(_ id: UUID, _ window: AgentToolWindow) {
        windows[id] = window
        _ = socketPath
    }

    static func unregister(_ id: UUID) {
        windows[id] = nil
    }

    /// The windows that exist now, for the control tools: each with the workspace that shows it. A window whose
    /// workspace is gone (closed) leaves the table here; one that has no host window yet (still being set up) is not listed.
    static func liveWindows() -> [(id: UUID, window: AgentToolWindow, workspace: any AgentControlWindow)] {
        for (id, window) in windows where window.workspace() == nil { windows[id] = nil }
        return windows.compactMap { id, window in
            guard let workspace = window.workspace(), workspace.hostWindow != nil else { return nil }
            return (id, window, workspace)
        }
    }

    /// The MCP servers of this binary for window `id`, as an assistant's launch takes them: the browser tools (when asked for) and the
    /// project tools, each a server of this same binary bound to the window.
    static func mcpServers(window id: UUID, includingBrowser: Bool) -> [AgentMCPServer] {
        guard let socket = socketPath, let executable = Bundle.main.executablePath else { return [] }
        func server(_ name: String, _ tomlName: String, _ flag: String, _ label: String) -> AgentMCPServer {
            AgentMCPServer(name: name, tomlName: tomlName, flag: flag, label: label,
                           command: executable, args: [flag, "--socket", socket, "--window", id.uuidString])
        }
        var servers: [AgentMCPServer] = []
        if includingBrowser { servers.append(server(BrowserAgentTools.serverName, "markview_browser", "--mcp-browser", "browser")) }
        servers.append(server(ProjectAgentTools.serverName, ProjectAgentTools.serverName, "--mcp-project", "project"))
        return servers
    }

    // MARK: - Socket

    private static func listen(at path: String) -> Bool {
        removeStaleSockets(near: path)
        let opened: PrivateSocket.Listener
        do {
            opened = try PrivateSocket.open(at: path)
        } catch {
            AppLog.browser.error("agent tool socket unavailable at \(path): \(error)")
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
        thread.name = "MarkView agent tools"
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
        guard peer.isCurrentUser, let peerPID = peer.pid else {
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
        // Both ancestry and working folder come from the authenticated socket peer, never from request fields.
        let pids = BrowserAgentTools.ancestorPIDs(startingAt: peerPID)
        let cwd = BrowserAgentTools.workingDirectory(forPIDs: pids) ?? ""
        let tool = request["tool"] as? String ?? ""
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        // task: answers one request of an agent's socket and closes it; the agent's call has no owner here to cancel it
        Task { @MainActor in
            let reply = await perform(tool, arguments, window: window, pids: pids, cwd: cwd)
            let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BrowserAgentTools.writeAll(client, data + Data("\n".utf8))
                close(client)
            }
        }
    }

    // MARK: - Tools

    /// A browser call of a relay session (`RemoteBrowserRelay`): it addresses only its work-computer window, never a folder or process on
    /// the home Mac, and only while that window still shows the project the relay connected to.
    static func performForRelay(_ tool: String, _ args: [String: Any], window id: UUID, root: URL, agent: CLITool) async -> BrowserAgentTools.Reply {
        guard agent.agentToolsEnabled else {
            return .error("Browser tools for this assistant are turned off in the globe menu.")
        }
        guard let window = windows[id], let workspace = window.workspace(),
              workspace.controlTerminalRoot?.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else {
            return .error("The connected project window was closed or changed. Reconnect before using its browser.")
        }
        return await perform(tool, args, window: id, pids: [], cwd: root.path)
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

    private static func perform(_ tool: String, _ args: [String: Any], window id: UUID?, pids: [Int32], cwd: String) async -> BrowserAgentTools.Reply {
        // The agent of a Cockpit step gets only the tools its controls allow, whichever family a tool belongs to.
        if let refusal = cockpitRefusal(tool, args, pids: pids) { return .error(refusal) }
        // The control tools name their window themselves (`window`), or take the caller's folder when it says one.
        if ControlAgentTools.names.contains(tool) {
            return await ControlToolRunner.run(tool, args, caller: .init(pids: pids, folder: cwd))
        }
        let isProjectTool = ProjectAgentTools.toolNames.contains(tool)
        guard isProjectTool || TerminalBrowserBridge.isEnabled else {
            return .error("MarkView's browser for terminals is turned off (globe menu → Open Terminal Links in MarkView).")
        }
        let known = id.flatMap { windows[$0] != nil ? $0 : nil } ?? TerminalBrowserBridge.windowID(forAncestors: pids)
        let windowID: UUID?
        if let known { windowID = known } else { windowID = await windowForFolder(cwd) }
        guard let windowID, var window = windows[windowID] else {
            let open = windows.values.compactMap { $0.root()?.path }.sorted()
            return .error(BrowserAgentTools.noWindowPrefix + " this agent works in (\(cwd.isEmpty ? "unknown" : cwd)) open."
                          + (open.isEmpty ? "" : " Open project windows: " + open.joined(separator: ", ")))
        }
        var toolArguments = args
        if isProjectTool, let supplied = toolArguments.removeValue(forKey: "project_folder") {
            guard let text = supplied as? String else { return .error("project_folder must be a path. Nothing was done.") }
            let folder = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !folder.isEmpty {
                guard let root = window.root()?.path else { return .error("This window has no project open. Nothing was done.") }
                // task: the request awaits path resolution and checks that the window still holds the same project.
                let matches = await Task.detached { BrowserAgentTools.folder(folder, isInProject: root) }.value
                guard let current = windows[windowID], current.root()?.path == root else {
                    return .error("The project window changed. Nothing was done.")
                }
                guard matches else {
                    return .error("project_folder does not match the selected window’s project. Nothing was done.")
                }
                window = current
            }
        }
        if isProjectTool, DeploymentAgentTools.names.contains(tool) {
            guard let store = window.deployments() else { return .error("This window has no project open.") }
            return await DeploymentToolRunner.run(tool, toolArguments, store: store)
        }
        if isProjectTool, DiscussionAgentTools.names.contains(tool) {
            guard let store = window.discussions() else { return .error("This window has no project open.") }
            return DiscussionToolRunner.run(tool, toolArguments, store: store)
        }
        if isProjectTool {
            guard let store = window.features() else { return .error("This window has no project open.") }
            if tool == "markview_cockpit_report_progress" { return await ProjectToolRunner.reportCockpitProgress(toolArguments, store: store) }
            if tool == "markview_cockpit_ask" { return await ProjectToolRunner.askCockpitSupervisor(toolArguments, store: store) }
            if LifecycleToolRunner.handles(tool, toolArguments) { return await LifecycleToolRunner.run(tool, toolArguments, store: store) }
            return ProjectToolRunner.run(tool, toolArguments, store: store)
        }
        return await window.browser(tool, toolArguments)
    }

    /// Resolve filesystem aliases away from the main actor; a changed or closed window is never selected afterward.
    private static func windowForFolder(_ cwd: String) async -> UUID? {
        let entries = windows.map { (id: $0.key, root: $0.value.root()?.path) }
        let roots = entries.map(\.root)
        // task: the request awaits this filesystem lookup and verifies the selected window before dispatch.
        let index = await Task.detached {
            BrowserAgentTools.windowIndex(forFolder: cwd, roots: roots, strict: true)
        }.value
        guard let index, entries.indices.contains(index), let window = windows[entries[index].id],
              window.root()?.path == entries[index].root else { return nil }
        return entries[index].id
    }
}
