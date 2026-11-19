import AppKit
import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What the terminals of a window need of the window: the browser the agents drive, the editor, and the watch over open files that
/// runs while a terminal does. The folder, the project and its linked folders come from the window's `ProjectProviding`.
/// `WorkspaceManager` conforms.
@MainActor
protocol AITerminalsHost: TerminalLinkTarget {
    /// This window's id for agents driving its browser tab (`AgentToolServer`).
    var browserControlID: UUID { get }
    func registerBrowserControl()
    func showAIConsole()
    /// A terminal started: open files an assistant changes on disk are reloaded while terminals run.
    func terminalStarted()
}

/// The terminals of one window: the AI panel's (Claude Code, Codex, a plain shell, a home assistant), the ones shown as editor tabs, the
/// dev servers of Preview Web App, the AI terminals that come back across launches (BUG-005) and the monitor of what the assistants do.
/// Everything else reaches the assistants through `AssistantProviding`.
@MainActor
final class AITerminalsController: ObservableObject, AssistantProviding, RemoteAssistantHost {
    private weak var host: (any AITerminalsHost)?
    /// The folder, the project whose assistant choice applies and the folders linked to it.
    private let projectContext: any ProjectProviding
    /// How the terminals tell the person that an assistant's policy blocks MarkView's tools (`AR-22`).
    private let prompts: any UserPrompts
    /// What the assistants in the AI terminals are doing (the toolbar, the tabs).
    let activity: AgentActivityMonitor

    /// Where the AI terminal starts: the open folder, or a single file's folder.
    @Published var workspaceRoot: URL? {
        // After a relaunch the folder's AI terminals come back even while the panel is hidden.
        didSet {
            if workspaceRoot != nil, workspaceRoot != oldValue {
                restoreAITerminals()
                RemoteConnectionsStore.shared.attach(self)
            }
        }
    }
    /// The AI panel's terminals, in tab order: Claude Code, Codex or a plain shell each.
    @Published private(set) var sessions: [TerminalSession] = []
    private var policyObservations: [UUID: AnyCancellable] = [:]
    /// The terminal shown in the AI panel.
    @Published var shownID: UUID? {
        // Closing the workspace empties `sessions` first, so it does not overwrite the saved set.
        didSet { if !sessions.isEmpty { saveAITerminals() } }
    }
    /// Terminals opened in folders, shown as editor tabs (keyed by tab id).
    private var tabTerminals: [UUID: TerminalSession] = [:]
    /// Dev server terminals started by Preview Web App, by app folder path.
    private var previewTerminals: [String: UUID] = [:]

    init(host: any AITerminalsHost, project: any ProjectProviding, tasks: TaskBag, polling: PollingScheduler, prompts: any UserPrompts) {
        self.host = host
        self.projectContext = project
        self.prompts = prompts
        activity = AgentActivityMonitor(tasks: tasks, polling: polling)
        activity.provider = self
        activity.start()
    }

    // MARK: - Where and which

    /// Where new terminals start: the AI root, else the folder open in the window.
    var root: URL? { workspaceRoot ?? projectContext.root }

    /// The project whose assistant choice applies.
    var project: URL? { projectContext.aiProject }

    func showAIConsole() { host?.showAIConsole() }

    /// The terminal shown in the AI panel.
    var shown: TerminalSession? {
        sessions.first { $0.id == shownID } ?? sessions.first
    }

    /// The assistant a prompt goes to now: the shown agent decides which assistant answers; the model is the project's chosen one,
    /// not what that tab happens to run.
    var currentAssistant: CLICompletion.Assistant? {
        guard let terminal = assistantTerminal, let tool = terminal.profile.tool else { return nil }
        return CLICompletion.Assistant.chosen(tool: tool, project: project)
    }

    // MARK: - Starting an assistant

    /// The command that starts `profile` in the shell with the model chosen for it, or nil
    /// for a plain shell. Every assistant runs without permission prompts; one that updates itself does that first.
    /// `continuing` adds the assistant's option that picks up its last session in the folder.
    /// `model` replaces the model chosen for the project: a Cockpit step runs with the model its plan names.
    private func startupCommand(for profile: TerminalProfile, continuing: Bool = false, model: String? = nil) -> String? {
        guard let tool = profile.tool else { return nil }
        let path = CLIToolLocator.resolve(tool) ?? tool.binaryName
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let linked = tool.additionalFolderArgs(projectContext.linkedFolderURLs).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let run = ([quoted] + (continuing ? tool.continueArgs : []) + tool.modelArgs(model ?? chosenModel(for: profile))
                   + tool.fullAccessArgs + linked + browserToolArgs(for: tool)).joined(separator: " ")
        guard !tool.provider.updateArgs.isEmpty else { return run }
        return ([quoted] + tool.provider.updateArgs).joined(separator: " ") + " && " + run
    }

    /// Shell-quoted arguments that give an assistant only the enabled MarkView MCP servers for this window.
    private func browserToolArgs(for tool: CLITool) -> [String] {
        guard let host else { return [] }
        host.registerBrowserControl()
        AgentMCPServices.migrateIfNeeded(for: tool)
        let windowID = host.browserControlID
        // The browser tools (when terminal links open in MarkView) and the project tools (features, bugs,
        // prototypes), each a server of this same binary, both bound to this window — filtered by per-agent selections.
        let candidates = AgentToolServer.mcpServers(window: windowID, includingBrowser: TerminalBrowserBridge.isEnabled)
        let servers = AgentMCPServices.enabledServers(from: candidates, for: tool)
        guard !servers.isEmpty else { return [] }
        let shellQuote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if let arguments = tool.provider.mcpLaunchArguments(for: servers, quote: shellQuote) { return arguments }
        // No per-session option: the assistant's own settings must list only the enabled servers (BUG-026, DEC-005).
        AgentBrowserRegistration.ensureRegistered(tool, executable: servers[0].command, servers: servers)
        return []
    }

    /// True when at least one local terminal session for `tool` is currently running in this window.
    func hasRunningSession(for tool: CLITool) -> Bool {
        sessions.contains { !$0.isRemote && $0.profile.tool == tool && $0.isRunning }
    }

    /// Restart every running local session for `tool`, continuing its conversation where supported.
    func restartRunningSessions(for tool: CLITool) {
        for session in sessions where !session.isRemote && session.profile.tool == tool && session.isRunning {
            relaunch(session, as: session.profile, continuing: !tool.continueArgs.isEmpty)
        }
        AgentMCPServicesStore.shared.clearRestartNotice(for: tool)
    }

    /// BUG-025 / mcp: an organisation's policy may allow only listed MCP servers; the assistant then (Copilot)
    /// prints `MCP server was blocked by policy: "markview-browser"` at every start. On that message only the
    /// blocked service is turned off for it on this Mac (preserving other enabled services and never bypassing policy),
    /// and the terminal can restart without it.
    private func watchForMCPPolicyBlock(_ session: TerminalSession, tool: CLITool) {
        let name = tool.displayName
        var recent = ""
        policyObservations[session.id] = session.outputEvents.sink { [weak self, weak session] data in
            recent = String((recent + String(decoding: data, as: UTF8.self)).suffix(4_000))
            guard let blockedServer = BrowserAgentTools.blockedPolicyServer(in: recent) else { return }
            recent = ""
            DispatchQueue.main.async {
                guard let self, let session, tool.isMCPServiceEnabled(blockedServer) else { return }
                do {
                    try AgentMCPServices.setEnabled(false, service: blockedServer, for: tool)
                } catch {
                    AppLog.browser.error("Could not disable blocked MCP service \(blockedServer) for \(name): \(error.localizedDescription)")
                }
                AgentMCPServicesStore.shared.reloadFromFiles()
                let blocked = UserPrompt(
                    title: "\(name)'s policy blocks \"\(blockedServer)\"",
                    detail: "Your organisation allows \(name) only the MCP servers it lists, so it refused \"\(blockedServer)\". MarkView disabled \"\(blockedServer)\" for \(name) on this Mac while keeping your other enabled MCP services unchanged (globe menu → MCP Services for Agents or DDE Settings). \(name) itself keeps working.",
                    buttons: ["Restart \(name) Without It", "Later"])
                guard self.prompts.confirm(blocked, proceedingWith: 0) else { return }
                self.relaunch(session, as: session.profile, continuing: true)
            }
        }
    }

    /// The command that continues `profile`'s last session in `directory` (BUG-005), or nil to start
    /// fresh: a shell, an assistant with no "continue last" option (Cline), or one with no session there
    /// when it would stop instead of starting one (Claude Code: "No conversation found").
    private func resumeCommand(for profile: TerminalProfile, in directory: URL) -> String? {
        guard let tool = profile.tool, !tool.continueArgs.isEmpty, tool.provider.hasSession(in: directory) else { return nil }
        return startupCommand(for: profile, continuing: true)
    }

    /// "Claude Code · opus", "Codex 2 · gpt-5", "Shell" — unique among the open terminals.
    private func terminalTitle(for profile: TerminalProfile, excluding session: TerminalSession? = nil) -> String {
        let taken = Set(sessions.filter { $0 !== session }.map(\.title))
        var base = profile.title
        var counter = 2
        while taken.contains(where: { $0 == base || $0.hasPrefix(base + " · ") }) {
            base = "\(profile.title) \(counter)"
            counter += 1
        }
        guard let model = chosenModel(for: profile) else { return base }
        return base + " · " + model
    }

    /// The model `profile` runs when started now: the project's choice for its assistant, nil for
    /// a shell or the CLI's own default. The command, the tab title and `TerminalSession.model`
    /// all come from this one answer.
    private func chosenModel(for profile: TerminalProfile) -> String? {
        guard let tool = profile.tool else { return nil }
        return AIAssistantPreferences.model(for: tool, project: project)
    }

    /// Start `session` again running `profile` with the model chosen for it now.
    private func relaunch(_ session: TerminalSession, as profile: TerminalProfile, continuing: Bool = false) {
        session.restart(profile: profile,
                        startupCommand: startupCommand(for: profile, continuing: continuing),
                        title: terminalTitle(for: profile, excluding: session),
                        model: chosenModel(for: profile))
    }

    /// Open another terminal in the AI panel and show it.
    /// `resuming` continues the assistant's last session in the folder (terminals restored after a relaunch).
    /// `model` starts the assistant with that model instead of the one chosen for the project (a Cockpit step's own).
    @discardableResult
    func openAITerminal(_ profile: TerminalProfile, resuming: Bool = false, model: String? = nil) -> TerminalSession? {
        guard let host, let directory = root else { return nil }
        let session = TerminalSession(directory: directory, profile: profile,
                                      startupCommand: startupCommand(for: profile, model: model),
                                      resumeCommand: resuming ? resumeCommand(for: profile, in: directory) : nil,
                                      title: terminalTitle(for: profile),
                                      model: model ?? chosenModel(for: profile), links: host)
        session.browserWindowID = host.browserControlID
        host.registerBrowserControl()
        if let tool = profile.tool, tool.provider.reportsMCPPolicyBlock { watchForMCPPolicyBlock(session, tool: tool) }
        sessions.append(session)
        shownID = session.id
        host.terminalStarted()
        return session
    }

    /// Connect a home assistant while preserving this window's work-computer root.
    @discardableResult
    func openRemoteAITerminal(code: String, provider: CLITool, model: String?, resume: Bool, savedConnectionID: UUID? = nil) async throws -> TerminalSession {
        guard let host, let root else { throw RemoteFailure.invalid("Open the folder you want the home assistant to work in.") }
        let invitation = try RemoteInvitation(code: code)
        host.registerBrowserControl()
        let session = TerminalSession(directory: root, profile: TerminalProfile(provider),
                                      title: "Home · " + provider.displayName, links: host)
        let connection = try await RemoteTerminalConnection(invitation: invitation, root: root, browserWindowID: host.browserControlID,
                                                            provider: provider, model: model, resume: resume, savedConnectionID: savedConnectionID) { [weak session] source, phase, text in
            if let session, session.connection !== source { return }
            if let savedConnectionID { RemoteConnectionsStore.shared.update(savedConnectionID, phase, text) }
        }
        guard self.root?.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else { connection.stop(); throw RemoteFailure.invalid("The open folder changed. Connect again for the new folder.") }
        session.connection = connection
        sessions.append(session)
        shownID = session.id
        host.showAIConsole()
        return session
    }

    /// The first AI terminal (the toolbar's assistant) once a folder is open.
    @discardableResult
    func ensureAITerminal() -> TerminalSession? {
        if let session = shown { return session }
        restoreAITerminals()
        return shown ?? openAITerminal(TerminalProfile(AIAssistantPreferences.backend(project: project)))
    }

    // MARK: - AI terminals across launches (BUG-005)

    private static func savedKey(_ directory: URL) -> SettingsKey<[String: Any]> {
        Setting.aiTerminals(folder: String(ContentHash.of(directory.standardizedFileURL.path).prefix(12)))
    }

    /// Remember the folder's AI terminals: what each runs, in tab order, and the shown one.
    private func saveAITerminals() {
        guard let directory = root else { return }
        // Saved remote pairings are restored by RemoteConnectionsStore, never as local assistant profiles.
        let local = sessions.filter { !$0.isRemote }
        let shownIndex = local.firstIndex { $0.id == shownID } ?? 0
        Settings.standard.set(["profiles": local.map(\.profile.rawValue), "shown": shownIndex], for: Self.savedKey(directory))
    }

    /// Reopen the AI terminals the folder had when MarkView last ran, each assistant continuing
    /// its last session there. Does nothing once a terminal is open or when none were saved.
    private func restoreAITerminals() {
        guard sessions.isEmpty, let directory = root,
              let saved = Settings.standard.stored(Self.savedKey(directory)),
              let names = saved["profiles"] as? [String] else { return }
        let opened = names.compactMap(TerminalProfile.init(rawValue:)).compactMap { openAITerminal($0, resuming: true) }
        let shownIndex = saved["shown"] as? Int ?? 0
        if opened.indices.contains(shownIndex) { shownID = opened[shownIndex].id }
    }

    func closeAITerminal(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        policyObservations[id] = nil
        sessions.remove(at: index).terminate()
        if shownID == id {
            shownID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        saveAITerminals()
    }

    /// Start the shown terminal again, with the model chosen for its assistant now.
    func restartAITerminal() {
        guard let session = shown else { ensureAITerminal(); return }
        guard !session.isRemote else { return }
        relaunch(session, as: session.profile)
    }

    // MARK: - The chosen assistant and model

    /// The toolbar's assistant changed: show a terminal running it — an open one, or the
    /// shown assistant terminal restarted with it, or a new one next to a plain shell.
    func aiBackendChanged() {
        guard shown?.isRemote != true else { return }
        let profile = TerminalProfile(AIAssistantPreferences.backend(project: project))
        if let existing = sessions.first(where: { $0.profile == profile }) {
            shownID = existing.id
            return
        }
        if let session = shown, session.profile != .shell {
            relaunch(session, as: profile)
            saveAITerminals()
            objectWillChange.send()
        } else if shown != nil {
            openAITerminal(profile)
        }
    }

    /// The model chosen for the shown terminal's assistant differs from the one it runs: the shown
    /// terminal restarts with the chosen model and its tab is renamed; other terminals keep their
    /// session. Safe to call at any time — it does nothing when the models match. The AI panel
    /// calls it when the toolbar's model changes and when the panel opens, so a model picked
    /// while the panel was hidden is applied too.
    func aiModelChanged() {
        guard let session = shown, session.profile != .shell, !session.isRemote,
              session.model != chosenModel(for: session.profile) else { return }
        // Only a model picked in MarkView after this assistant started applies to it. A model remembered
        // from another session (the user switched with /model there, BUG-048) is the next start's, not a
        // reason to interrupt this one.
        guard let tool = session.profile.tool,
              let picked = ModelPickLog.lastPick(tool: tool, project: project), picked > session.launchedAt else { return }
        relaunch(session, as: session.profile)
        objectWillChange.send()
    }

    /// A live-switching agent's (Claude Code) own log names the model it runs now. When that is not what MarkView shows
    /// (the user switched with `/model` inside the session), the agent's tab shows it, and it becomes
    /// the model the project (and every project with no choice of its own) starts the assistant with next
    /// time. Nothing restarts: the conversation goes on.
    func liveModelReported(_ model: String, terminalID: UUID) {
        guard let session = sessions.first(where: { $0.id == terminalID }),
              let tool = session.profile.tool, let live = tool.provider.liveModelSwitch,
              !session.isRemote, session.isRunning else { return }
        let previous = session.observedModel
        session.observedModel = model
        let picked = session.pendingModelPick == model
        if picked { session.pendingModelPick = nil }
        guard model != session.model else { return }
        // Started with the CLI's own default: the first reading is that default, not a choice,
        // unless the Agents header asked for exactly this model.
        if session.model == nil, previous == nil, !picked { return }
        // A model pinned by id (--model claude-opus-4-1) and the family alias the log reports are the same.
        if let pinned = session.model, live.family(of: pinned) == model { return }
        session.adoptRunningModel(model, title: live.title(session.title, model: model))
        AIAssistantPreferences.remember(model, for: tool, project: project)
        objectWillChange.send()
    }

    /// The model switch in the Agents header. An assistant with a live switch (Claude Code) switches in place: the
    /// command (`/model`) is typed into the running session, so nothing restarts and the conversation goes on; the
    /// session's log then confirms it and `liveModelReported` renames the tab and remembers the model. Another
    /// assistant starts again with the model, and picks its conversation up where its CLI can resume.
    func switchModel(of session: TerminalSession, to model: String) {
        guard let tool = session.profile.tool, !session.isRemote, !model.isEmpty else { return }
        guard let live = tool.provider.liveModelSwitch else {
            AssistantChoice(project: project).setModel(model, for: tool)
            // The panel restarts the shown agent only when the project's own assistant changes its
            // model; a Copilot tab beside a Claude project would stay as it was.
            if session.model != chosenModel(for: session.profile) {
                relaunch(session, as: session.profile, continuing: !tool.continueArgs.isEmpty)
                objectWillChange.send()
            }
            return
        }
        // Only a family alias is typed, never free text. While the agent answers, the command would
        // queue behind the answer or land in the wrong place; the menu is off then, this covers the race.
        guard live.families.contains(model), session.isRunning, !session.printed(within: 3) else {
            NSSound.beep()
            return
        }
        session.pendingModelPick = model
        session.paste(live.command(for: model), submit: true)
    }

    // MARK: - Prompts

    /// Send a prompt to an assistant (prompt buttons, AI Tools menu, graph edits,
    /// documentation): the shown terminal when it runs one, else an open assistant
    /// terminal, else a new one with the toolbar's assistant. Pasted as one block;
    /// `submit` presses Enter.
    /// Returns the terminal session the prompt went to.
    @discardableResult
    func sendToAssistant(_ prompt: String, submit: Bool = true) -> TerminalSession? {
        sendToAssistant(submit: submit) { _ in prompt }
    }

    /// Build a backend-specific prompt only after choosing the actual receiving terminal.
    /// `terminal`: the one to send to (an agent driving the window names it); else the usual choice.
    @discardableResult
    func sendToAssistant(submit: Bool = true, to terminal: TerminalSession? = nil, promptFor: (TerminalSession) -> String?) -> TerminalSession? {
        host?.showAIConsole()
        restoreAITerminals()
        guard let session = terminal ?? assistantTerminal ?? openAITerminal(TerminalProfile(AIAssistantPreferences.backend(project: project))) else { return nil }
        shownID = session.id
        guard let prompt = promptFor(session) else { return nil }
        session.pasteWhenReady(prompt, submit: submit)
        return session
    }

    /// The open assistant terminal a prompt goes to: the one shown, else one of the chosen
    /// backend, else any assistant; nil when none is open (`sendToAssistant` then opens one).
    var assistantTerminal: TerminalSession? {
        if let shown, shown.profile != .shell { return shown }
        return sessions.first(where: { $0.profile == TerminalProfile(AIAssistantPreferences.backend(project: project)) })
            ?? sessions.first(where: { $0.profile != .shell })
    }

    /// The assistant terminal is working: it printed in the last few seconds (Claude Code's
    /// spinner keeps printing while it runs). Batch Fix with AI waits for it (DEC-010).
    var assistantIsBusy: Bool {
        guard let session = assistantTerminal, session.isRunning else { return false }
        return session.printed(within: 3)
    }

    // MARK: - Terminals shown as editor tabs

    /// A terminal in `folder` for an editor tab; `startupCommand` is typed once the shell is up. The window builds the tab.
    func makeTabTerminal(in folder: URL, startupCommand: String?, title: String?) -> TerminalSession {
        let session = TerminalSession(directory: folder.standardizedFileURL, startupCommand: startupCommand, title: title, links: host)
        session.browserWindowID = host?.browserControlID
        host?.registerBrowserControl()
        tabTerminals[session.id] = session
        host?.terminalStarted()
        return session
    }

    /// The terminal of the editor tab `id`.
    func tabTerminal(_ id: UUID) -> TerminalSession? { tabTerminals[id] }

    /// A terminal tab was closed: end its shell.
    func closeTabTerminal(_ id: UUID) {
        tabTerminals.removeValue(forKey: id)?.terminate()
        previewTerminals = previewTerminals.filter { $0.value != id }
    }

    /// The dev server terminal Preview Web App started for the app in `folderPath`, while it is still open.
    func previewTerminal(forApp folderPath: String) -> TerminalSession? {
        previewTerminals[folderPath].flatMap { tabTerminals[$0] }
    }

    func rememberPreviewTerminal(_ session: TerminalSession, forApp folderPath: String) {
        previewTerminals[folderPath] = session.id
    }

    // MARK: - Closing

    /// End every terminal of the window (the folder closes or another opens).
    func stopAll() {
        policyObservations.removeAll()
        sessions.forEach { $0.terminate() }
        sessions = []
        shownID = nil
        tabTerminals.values.forEach { $0.terminate() }
        tabTerminals = [:]
        previewTerminals = [:]
    }
}

/// The assistant's input line, for the tools that hand it a question (`DeploymentsHost`).
extension AITerminalsController: AssistantPrompting {}
