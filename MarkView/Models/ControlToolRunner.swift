import AppKit
import Foundation

/// The app side of `ControlAgentTools`: an outside agent runs this MarkView. It lists the windows, opens a project in
/// one, starts and prompts agents in the AI panel, and takes a feature through the Feature flow — each by calling what
/// the interface calls when a person clicks (`WorkspaceManager`, `FeatureAssistant`, `TerminalSession`).
///
/// Windows are chosen by the `window` argument (`ControlAgentTools.pickWindow`). Nothing here blocks the main thread:
/// a step that takes minutes is a `Task` that outlives the socket request, and the request waits for it in short sleeps.
@MainActor
enum ControlToolRunner {
    typealias Invalid = ProjectAgentTools.Invalid
    typealias Reply = BrowserAgentTools.Reply

    /// Who asks: the processes above the MCP server (to keep an agent from prompting its own terminal) and the folder
    /// it works in (to pick its window when it does not say).
    struct Caller {
        var pids: [Int32]
        var folder: String
    }

    /// One window: its id, and the workspace that shows it.
    struct Target {
        let id: UUID
        let workspace: WorkspaceManager
        var shortID: String { ControlAgentTools.shortID(id.uuidString) }
    }

    static func run(_ tool: String, _ args: [String: Any], caller: Caller) async -> Reply {
        do {
            switch tool {
            case "markview_control_guide": return .init(text: ControlAgentTools.guide(args["topic"] as? String))
            case "markview_windows": return .init(text: windowList())
            case "markview_recent_projects": return .init(text: recentProjects())
            case "markview_open_project": return try await openProject(args, caller: caller)
            default: break
            }
            let target = try window(args, caller: caller)
            switch tool {
            case "markview_focus_window": return focus(target)
            case "markview_agents": return agents(target)
            case "markview_agent_start": return try await agentStart(target, args)
            case "markview_agent_send": return try await agentSend(target, args, caller: caller)
            case "markview_agent_read": return try await agentRead(target, args)
            case "markview_agent_wait": return try await agentWait(target, args)
            case "markview_agent_key": return try agentKey(target, args, caller: caller)
            case "markview_flow_status": return try await flowStatus(target, args)
            case "markview_flow_new": return try await flowNew(target, args)
            case "markview_flow_answer": return try await flowAnswer(target, args)
            case "markview_flow_run": return try await flowRun(target, args)
            case "markview_flow_implement": return try await flowImplement(target, args, caller: caller)
            case "markview_flow_fix_bug": return try await flowFixBug(target, args, caller: caller)
            case "markview_flow_stop": return try flowStop(target, args)
            default: return .error("Unknown tool \(tool).")
            }
        } catch let invalid as Invalid {
            return .error(invalid.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Choosing a window

    private static func windowInfos(_ live: [(id: UUID, window: BrowserControlServer.Window, workspace: WorkspaceManager)])
        -> [(id: String, title: String, project: String?)] {
        live.map { (id: $0.id.uuidString, title: $0.workspace.hostWindow?.title ?? "", project: $0.workspace.projectFolder?.path) }
    }

    static func window(_ args: [String: Any], caller: Caller) throws -> Target {
        let live = BrowserControlServer.liveWindows()
        let query = try ProjectAgentTools.text(args, "window")
        switch ControlAgentTools.pickWindow(query, among: windowInfos(live), callerFolder: caller.folder) {
        case .one(let index):
            return Target(id: live[index].id, workspace: live[index].workspace)
        case .none:
            // The prefix lets the MCP server ask the next running MarkView.
            throw Invalid(message: BrowserAgentTools.noWindowMatchPrefix + (query.isEmpty ? ": no window is open in this MarkView." : " “\(query)”.")
                          + (live.isEmpty ? "" : "\n" + windowLines(live)))
        case .many(let indices):
            throw Invalid(message: (query.isEmpty ? "Several windows are open" : "“\(query)” matches several windows")
                          + ": pass `window` (id, a part of the title, or the project folder).\n" + windowLines(indices.map { live[$0] }))
        }
    }

    private static func windowLines(_ live: [(id: UUID, window: BrowserControlServer.Window, workspace: WorkspaceManager)]) -> String {
        live.map { entry in
            "\(ControlAgentTools.shortID(entry.id.uuidString)) · \"\(entry.workspace.hostWindow?.title ?? "")\" · "
                + (entry.workspace.projectFolder?.path ?? "no project open")
        }.joined(separator: "\n")
    }

    // MARK: - Windows and projects

    /// The frontmost visible window (panels do not count).
    private static var frontmost: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && !$0.className.contains("Panel") }
    }

    private static func windowList() -> String {
        let live = BrowserControlServer.liveWindows()
        let pid = ProcessInfo.processInfo.processIdentifier
        guard !live.isEmpty else { return "MarkView (process \(pid)) has no window open yet." }
        let order = NSApp.orderedWindows
        let sorted = live.sorted { position($0.workspace.hostWindow, in: order) < position($1.workspace.hostWindow, in: order) }
        var out = "MarkView (process \(pid)): \(live.count) window\(live.count == 1 ? "" : "s")\n"
        for entry in sorted {
            let workspace = entry.workspace
            let front = workspace.hostWindow.map { $0 === frontmost } ?? false
            out += "\n\(ControlAgentTools.shortID(entry.id.uuidString)) · \"\(workspace.hostWindow?.title ?? "")\" · "
                + (workspace.projectFolder?.path ?? "no project open") + (front ? " · in front" : "") + "\n"
            let terminals = workspace.aiTerminals
            out += "    agents: " + (terminals.isEmpty ? "none" : terminals.map { "\($0.title) (\(state(of: $0, in: workspace)))" }.joined(separator: ", ")) + "\n"
            let running = runningSteps(workspace.features.assistant)
            if !running.isEmpty { out += "    running: " + running.joined(separator: ", ") + "\n" }
        }
        return out
    }

    private static func position(_ window: NSWindow?, in order: [NSWindow]) -> Int {
        window.flatMap { window in order.firstIndex { $0 === window } } ?? Int.max
    }

    /// The AI steps in progress, each with what it is doing and for how long.
    static func runningSteps(_ assistant: FeatureAssistant) -> [String] {
        assistant.running.union(assistant.preparing).sorted().map { key in
            guard let action = assistant.actions[key] else { return key }
            return "\(key) (\(action.stage), \(Int(Date().timeIntervalSince(action.started))) s)"
        }
    }

    private static func recentProjects() -> String {
        let paths = UserDefaults.standard.stringArray(forKey: WorkspaceManager.recentProjectsKey) ?? []  // shared by all windows
        let open = Set(BrowserControlServer.liveWindows().compactMap { $0.workspace.projectFolder?.path })
        let lines = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { $0 + (open.contains($0) ? "  (open)" : "") }
        return lines.isEmpty ? "No recent projects." : lines.joined(separator: "\n")
    }

    private static func standardized(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func openProject(_ args: [String: Any], caller: Caller) async throws -> Reply {
        let raw = try ProjectAgentTools.text(args, "path", required: true)
        let path = standardized(raw)
        guard path.hasPrefix("/"), path != "/" else { throw Invalid(message: "`path` must be the absolute path of a project folder.") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Invalid(message: "\(path) is not a folder.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let live = BrowserControlServer.liveWindows()
        if let open = live.first(where: { $0.workspace.projectFolder.map { standardized($0.path) } == path }) {
            let target = Target(id: open.id, workspace: open.workspace)
            return .init(text: "\(path) is already open in window \(target.shortID). \(projectLine(target.workspace))")
        }
        let named = try ProjectAgentTools.text(args, "window")
        let reuse: Target?
        if !named.isEmpty {
            let target = try window(args, caller: caller)
            guard target.workspace.isBlank else {
                throw Invalid(message: "Window \(target.shortID) has \(target.workspace.projectFolder?.path ?? "tabs") open and is not replaced. Leave `window` out to open \(path) in a new window.")
            }
            reuse = target
        } else if args["new_window"] as? Bool == true {
            reuse = nil
        } else {
            reuse = live.first { $0.workspace.isBlank }.map { Target(id: $0.id, workspace: $0.workspace) }
        }
        if let reuse {
            reuse.workspace.openFolder(url)
            guard await waitUntil(20, { isOpen(reuse.workspace, path) }) else {
                throw Invalid(message: "Window \(reuse.shortID) did not finish opening \(path) in 20 s. Look at it with markview_windows.")
            }
            return .init(text: "Opened \(path) in window \(reuse.shortID). \(projectLine(reuse.workspace))\nNext: markview_agent_start { window: \"\(reuse.shortID)\" } or markview_flow_new.")
        }
        guard WindowSessionController.shared.openWorkspaceWindow(folder: url) else {
            throw Invalid(message: "MarkView cannot open another window yet (it has none to open it from, or it is quitting). Open one in MarkView and call again.")
        }
        var opened: Target?
        let appeared = await waitUntil(25) {
            opened = BrowserControlServer.liveWindows().first { isOpen($0.workspace, path) }.map { Target(id: $0.id, workspace: $0.workspace) }
            return opened != nil
        }
        guard appeared, let opened else {
            throw Invalid(message: "The new window for \(path) did not open in 25 s. Look at markview_windows.")
        }
        return .init(text: "Opened \(path) in a new window \(opened.shortID). \(projectLine(opened.workspace))\nNext: markview_agent_start { window: \"\(opened.shortID)\" } or markview_flow_new.")
    }

    /// The folder is the window's project and its features are loaded.
    private static func isOpen(_ workspace: WorkspaceManager, _ path: String) -> Bool {
        workspace.projectFolder.map { standardized($0.path) } == path && workspace.features.root != nil
    }

    private static func projectLine(_ workspace: WorkspaceManager) -> String {
        let store = workspace.features
        return "Features: \(store.features.count), bugs: \(store.bugs.count)."
    }

    private static func focus(_ target: Target) -> Reply {
        guard let window = target.workspace.hostWindow else { return .error("That window is not on screen.") }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return .init(text: "Window \(target.shortID) is in front.")
    }

    // MARK: - Waiting

    /// Poll `condition` every 150 ms for at most `seconds`; whether it held.
    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return condition()
    }
}
