import AppKit
import Foundation

/// The agent tools of `ControlToolRunner`: list the assistants and terminals of a window, start one in the AI panel,
/// give it a prompt or a goal, read its screen, wait for it, press a key. A terminal is only written to through
/// `TerminalSession` (`pasteWhenReady`, `write`), which keeps long pastes whole and in order.
@MainActor
extension ControlToolRunner {
    /// When each terminal last got a prompt or a key from here: a wait does not call a terminal finished before its agent began.
    static var lastSent: [UUID: Date] = [:]

    // MARK: - Terminals

    static func activity(of session: TerminalSession, in workspace: WorkspaceManager) -> AgentActivity? {
        workspace.agentActivity.entries.first { $0.id == session.id }?.activity
    }

    /// What the terminal is doing, in a few words.
    static func state(of session: TerminalSession, in workspace: WorkspaceManager) -> String {
        guard session.isRunning else { return session.exitCode.map { "exited, code \($0)" } ?? "starting" }
        if let activity = activity(of: session, in: workspace) {
            switch activity.state {
            case .working: return "working — \(activity.text)"
            case .failing: return "failing — \(activity.text)"
            case .idle: return session.printed(within: 3) ? "printing" : "idle"
            }
        }
        return session.printed(within: 3) ? "working (printing)" : "quiet"
    }

    /// Working now: its log says so, or it has run a while and is printing. A terminal that has just started prints
    /// while it comes up; that is not work, and a prompt sent to it waits for it (`pasteWhenReady`).
    static func isWorking(_ session: TerminalSession, in workspace: WorkspaceManager) -> Bool {
        guard session.isRunning else { return false }
        if activity(of: session, in: workspace)?.state == .working { return true }
        let up = session.runningSince.map { Date().timeIntervalSince($0) } ?? 0
        return up > 30 && session.printed(within: 3)
    }

    /// The agent terminal the arguments name. `forInput`: it is going to be written to, so never the caller's own.
    static func terminal(_ target: Target, _ args: [String: Any], caller: Caller?, forInput: Bool) throws -> TerminalSession {
        let sessions = target.workspace.aiTerminals.filter { $0.profile != .shell }
        guard !sessions.isEmpty else {
            throw Invalid(message: "Window \(target.shortID) has no agent terminal. markview_agent_start opens one.")
        }
        let query = try ProjectAgentTools.text(args, "terminal")
        let infos = sessions.map { (id: $0.id.uuidString, tool: $0.profile.rawValue, title: $0.title) }
        let lines = { (list: [TerminalSession]) in
            list.map { "\(ControlAgentTools.shortID($0.id.uuidString)) · \($0.profile.rawValue) · \"\($0.title)\"" }.joined(separator: "\n")
        }
        let session: TerminalSession
        switch ControlAgentTools.pickTerminal(query, among: infos, shown: target.workspace.activeAITerminalID?.uuidString) {
        case .one(let index): session = sessions[index]
        case .none: throw Invalid(message: "No agent terminal matches “\(query)”. Terminals:\n" + lines(sessions))
        case .many(let indices):
            throw Invalid(message: (query.isEmpty ? "The window has several agent terminals" : "“\(query)” matches several terminals")
                          + ": pass `terminal` (id, tool or a part of the title).\n" + lines(indices.map { sessions[$0] }))
        }
        if forInput, let caller, session.shellPID > 0, caller.pids.contains(session.shellPID) {
            throw Invalid(message: "That is the terminal you run in; an agent does not prompt itself. Start another with markview_agent_start.")
        }
        return session
    }

    /// A new terminal with `tool` in the window's AI panel, once its agent process runs.
    static func startTerminal(_ target: Target, tool: CLITool, resume: Bool) async throws -> TerminalSession {
        let workspace = target.workspace
        guard workspace.projectFolder != nil else {
            throw Invalid(message: "Window \(target.shortID) has no project open. markview_open_project first.")
        }
        guard CLIToolLocator.resolve(tool) != nil else {
            throw Invalid(message: "\(tool.displayName) is not installed (or its path is not set in MarkView's Settings). markview_agents lists what is.")
        }
        // The terminal starts when its page has loaded, which needs the panel on screen.
        workspace.showAIConsole()
        guard let session = workspace.openAITerminal(TerminalProfile(tool), resuming: resume) else {
            throw Invalid(message: "The terminal could not be opened.")
        }
        _ = await waitUntil(15) { session.isRunning }
        return session
    }

    private static func tool(named value: Any?, in workspace: WorkspaceManager) throws -> CLITool {
        guard let name = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else {
            return AIAssistantPreferences.backend(project: workspace.aiProject)
        }
        guard let tool = CLITool(rawValue: name) else {
            throw Invalid(message: "`tool` must be one of: \(ControlAgentTools.agentTools.joined(separator: ", ")).")
        }
        return tool
    }

    /// The tool for a flow tool: the one named, else the project's.
    static func chosenTool(_ args: [String: Any], in workspace: WorkspaceManager) throws -> CLITool {
        try tool(named: args["tool"], in: workspace)
    }

    // MARK: - Tools

    static func agents(_ target: Target) -> Reply {
        let workspace = target.workspace
        let chosen = AIAssistantPreferences.backend(project: workspace.aiProject)
        var out = "Window \(target.shortID) — \(workspace.projectFolder?.path ?? "no project open")\n\nAssistants:\n"
        for tool in CLITool.allCases {
            let model = AIAssistantPreferences.model(for: tool, project: workspace.aiProject)
            out += "  \(tool.rawValue) — \(tool.displayName): \(CLIToolLocator.resolve(tool) ?? "not installed")"
                + (tool == chosen ? "  [the project's assistant" + (model.map { $0.isEmpty ? "]" : ", model \($0)]" } ?? "]") : "") + "\n"
        }
        out += "\nTerminals:\n"
        let terminals = workspace.aiTerminals
        if terminals.isEmpty {
            out += "  none (markview_agent_start opens one)\n"
        } else {
            for session in terminals {
                out += "  \(ControlAgentTools.shortID(session.id.uuidString)) · \(session.profile.rawValue) · \"\(session.title)\" · \(state(of: session, in: workspace))"
                    + (session.id == workspace.activeAITerminalID ? " · shown" : "") + "\n"
                if let task = activity(of: session, in: workspace)?.task, !task.isEmpty { out += "      asked: \(task.prefix(160))\n" }
            }
        }
        return .init(text: out)
    }

    static func agentStart(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let tool = try tool(named: args["tool"], in: target.workspace)
        let session = try await startTerminal(target, tool: tool, resume: args["resume"] as? Bool == true)
        let id = ControlAgentTools.shortID(session.id.uuidString)
        let running = session.isRunning
        return .init(text: "Started \(tool.displayName) in window \(target.shortID): terminal \(id) (\"\(session.title)\")"
                     + (running ? "." : "; it is not running yet (its panel may be hidden). markview_agent_read shows the screen.")
                     + "\nA prompt sent now (markview_agent_send { terminal: \"\(id)\" }) is delivered when the agent has come up and is quiet. "
                     + "A first run in a folder may ask whether to trust it: read the screen, then markview_agent_key { key: \"enter\" }.")
    }

    static func agentSend(_ target: Target, _ args: [String: Any], caller: Caller) async throws -> Reply {
        let session = try terminal(target, args, caller: caller, forInput: true)
        let workspace = target.workspace
        if session.exitCode != nil { throw Invalid(message: "The agent in “\(session.title)” has exited. markview_agent_start opens a new one.") }
        let text = try ProjectAgentTools.text(args, "text", required: true)
        // An agent that has just drawn its screen (a key was pressed, a turn ended) is quiet in a few seconds.
        if args["force"] as? Bool != true, isWorking(session, in: workspace) {
            _ = await waitUntil(8) { !isWorking(session, in: workspace) }
        }
        if args["force"] as? Bool != true, isWorking(session, in: workspace) {
            throw Invalid(message: "“\(session.title)” is working (\(state(of: session, in: workspace))). Wait for it with markview_agent_wait, or pass force: true to send this as a follow-up.")
        }
        var prompt = text
        if args["goal"] as? Bool == true {
            guard let backend = HandoffPrompt.GoalBackend(rawValue: session.profile.rawValue) else {
                throw Invalid(message: "A goal needs an agent terminal; this one is a shell.")
            }
            prompt = HandoffPrompt.goal(text, backend: backend)
        }
        session.pasteWhenReady(prompt, submit: args["submit"] as? Bool ?? true)
        lastSent[session.id] = Date()
        return .init(text: "Sent \(prompt.count) characters to “\(session.title)” [\(ControlAgentTools.shortID(session.id.uuidString))]"
                     + (args["goal"] as? Bool == true ? " as a goal" : "")
                     + "; it is pasted once the agent is ready. Follow it with markview_agent_wait and markview_agent_read.")
    }

    static func agentRead(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let session = try terminal(target, args, caller: nil, forInput: false)
        let workspace = target.workspace
        let lines = min(max(args["lines"] as? Int ?? 40, 1), 200)
        return .init(text: await screen(of: session, in: workspace, lines: lines))
    }

    /// The terminal's header (name, state, last request) and its last lines.
    private static func screen(of session: TerminalSession, in workspace: WorkspaceManager, lines: Int) async -> String {
        var out = "“\(session.title)” [\(ControlAgentTools.shortID(session.id.uuidString))] — \(state(of: session, in: workspace))\n"
        if let task = activity(of: session, in: workspace)?.task, !task.isEmpty { out += "Asked: \(task.prefix(200))\n" }
        guard let screen = await session.screenTail(lines: lines * 4) else {  // a screen is mostly blank rows
            return out + "(The screen is not available: the terminal's panel has not been shown yet.)"
        }
        let tail = ControlAgentTools.tail(screen, lines: lines)
        return out + "--- last \(lines) lines ---\n" + (tail.isEmpty ? "(empty)" : tail)
    }

    static func agentWait(_ target: Target, _ args: [String: Any]) async throws -> Reply {
        let session = try terminal(target, args, caller: nil, forInput: false)
        let workspace = target.workspace
        let timeout = ControlAgentTools.seconds(args["timeout_s"])
        let quiet = min(max(args["quiet_s"] as? Int ?? 4, 1), 60)
        let started = Date()
        var reason = "the time (\(timeout) s) is up and it is still active"
        while Date().timeIntervalSince(started) < Double(timeout) {
            if session.exitCode != nil { reason = "the agent has exited"; break }
            let sinceSend = lastSent[session.id].map { Date().timeIntervalSince($0) } ?? .infinity
            if sinceSend > 4, !session.hasPendingPaste, !session.printed(within: Double(quiet)) {
                let working = activity(of: session, in: workspace)?.state == .working
                if !working { reason = "it has been quiet for \(quiet) s (its turn is over)"; break }
                if !session.printed(within: 45) { reason = "it has printed nothing for 45 s though its log says it is working"; break }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .init(text: "Stopped waiting after \(Int(Date().timeIntervalSince(started))) s: \(reason).\n" + (await screen(of: session, in: workspace, lines: 15)))
    }

    static func agentKey(_ target: Target, _ args: [String: Any], caller: Caller) throws -> Reply {
        let name = try ProjectAgentTools.text(args, "key", required: true).lowercased()
        guard let bytes = ControlAgentTools.keyBytes[name] else {
            throw Invalid(message: "`key` must be one of: \(ControlAgentTools.keyNames.joined(separator: ", ")).")
        }
        let session = try terminal(target, args, caller: caller, forInput: true)
        guard session.isRunning else { throw Invalid(message: "“\(session.title)” is not running.") }
        session.write(bytes)
        lastSent[session.id] = Date()
        return .init(text: "Pressed \(name) in “\(session.title)”. markview_agent_read shows what it did.")
    }
}
