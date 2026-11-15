import Foundation

// The terminals of a window (AR-14 step 4): the shipping AITerminalsController runs over real folders and the real UserDefaults, with a
// stand-in window (`StubHost`) and stand-in terminals (`TerminalSession` here starts no shell and types nothing: it records what the
// controller asks of it). The assistants' command lines, the saved AI terminals of BUG-005, which terminal a prompt goes to, the
// model reports of Claude Code, the editor-tab terminals and the home assistant are the production code's own.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

/// The assistants the checks start: the providers' ids (`CLITool` is a string-backed struct, with no case per assistant).
let claudeTool = CLITool(rawValue: "claude")!
let codexTool = CLITool(rawValue: "codex")!
extension TerminalProfile {
    static let claude = TerminalProfile(claudeTool)
    static let codex = TerminalProfile(codexTool)
}

/// The open project as the terminals read it (`ProjectProviding`): the folder, the project whose assistant choice applies, the links.
@MainActor
final class StubProject: ProjectProviding {
    var root: URL?
    var aiProject: URL?
    var linkedFolderURLs: [URL] = []
    var searchRoots: [URL] { (root.map { [$0] } ?? []) + linkedFolderURLs }
    var database: SemanticDatabase? { nil }
    func relativePath(of url: URL) -> String { url.path }
    func markdownFiles(in folder: URL) -> [URL] { [] }
    func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
    func refreshFileTree() {}
}

@MainActor
final class StubHost: AITerminalsHost {
    let browserControlID = UUID()
    var registered = 0
    var opened: [(url: URL, line: Int?)] = []
    var browserOpened: [URL] = []
    var consoleShown = 0
    var started = 0
    func registerBrowserControl() { registered += 1 }
    func openFile(_ url: URL, line: Int?, endLine: Int?) { opened.append((url, line)) }
    func openInAppBrowser(_ url: URL) { browserOpened.append(url) }
    func showAIConsole() { consoleShown += 1 }
    func terminalStarted() { started += 1 }
}

/// Wait, with the main run loop turning, until `condition` holds.
func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@MainActor
func run() async {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("mv-terminals-" + UUID().uuidString)
    let folder = sandbox.appendingPathComponent("project")
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    // The test process has a defaults domain of its own (its executable's name): start clean and leave nothing behind.
    let defaults = UserDefaults.standard
    let domain = ProcessInfo.processInfo.processName
    defaults.removePersistentDomain(forName: domain)
    defer { defaults.removePersistentDomain(forName: domain) }
    func savedKey(_ directory: URL) -> String { "aiTerminals." + String(ContentHash.of(directory.standardizedFileURL.path).prefix(12)) }
    defer { defaults.removeObject(forKey: savedKey(folder)) }
    defaults.removeObject(forKey: savedKey(folder))

    let host = StubHost()
    let project = StubProject()
    project.aiProject = folder
    let tasks = TaskBag()
    let terminals = AITerminalsController(host: host, project: project, tasks: tasks)
    check(terminals.activity.provider === terminals, "the activity monitor reads the terminals through AssistantProviding, with no closure wired by the window")
    check(terminals.sessions.isEmpty && terminals.shown == nil && terminals.root == nil, "a window with no folder has no terminal and no root")
    check(terminals.openAITerminal(.claude) == nil, "no terminal opens without a folder")
    check(terminals.ensureAITerminal() == nil, "ensureAITerminal opens nothing without a folder")

    // The root falls back to the folder open in the window until the terminals' own root is set.
    project.root = folder
    check(terminals.root == folder, "the root is the open folder before the terminals have their own")
    check(terminals.workspaceRoot == nil, "the terminals' own root is still unset")

    // MARK: opening
    let claude = terminals.openAITerminal(.claude)
    check(claude != nil && terminals.sessions.count == 1 && terminals.shownID == claude?.id && terminals.shown === claude, "the first terminal opens and is shown")
    check(claude?.directory == folder, "it starts in the folder")
    check(claude?.title == "Claude Code", "its tab is named after the assistant (no model chosen: \(claude?.title ?? "nil"))")
    check(host.registered >= 1, "the window is offered to the agents' browser control when a terminal starts")
    check(host.started == 1, "the window is told a terminal started (open files are watched from then on)")
    check(claude?.browserWindowID == host.browserControlID, "the terminal carries the window's browser id")
    claude?.openFile?(folder.appendingPathComponent("a.md"), 7)
    claude?.openInAppBrowser?(URL(string: "http://localhost:3000")!)
    check(host.opened.count == 1 && host.opened[0].url.lastPathComponent == "a.md" && host.opened[0].line == 7, "a file link in the terminal opens in the window's editor at its line")
    check(host.browserOpened == [URL(string: "http://localhost:3000")!], "a web link in the terminal opens in the window's browser")

    let startup = claude?.startupCommand ?? ""
    check(startup.contains(" update && "), "Claude Code updates itself before it starts")
    check(startup.contains("--dangerously-skip-permissions") || startup.contains("--permission-mode"), "it runs without permission prompts")
    check(startup.contains("--mcp-config"), "it gets this window's browser and project tools")

    let second = terminals.openAITerminal(.claude)
    check(second?.title == "Claude Code 2", "a second terminal of the same assistant is numbered (\(second?.title ?? "nil"))")
    let shell = terminals.openAITerminal(.shell)
    check(shell?.startupCommand == nil && shell?.title == "Shell", "a plain shell has no startup command")
    check(terminals.shownID == shell?.id, "the newest terminal is shown")

    // The folders linked to the project reach the assistant, and only an assistant that reports MCP policy blocks is watched for one.
    project.linkedFolderURLs = [sandbox.appendingPathComponent("linked-docs")]
    let withLinks = terminals.openAITerminal(.claude)
    check(withLinks?.startupCommand?.contains("linked-docs") == true, "the folders linked to the project are given to the assistant")
    project.linkedFolderURLs = []
    check(withLinks?.onOutput == nil, "an assistant whose organisation policy cannot block the MCP servers is not watched for it")
    let copilot = terminals.openAITerminal(TerminalProfile(CLITool(rawValue: "copilot")!))
    check(copilot?.onOutput != nil, "Copilot's output is watched for the policy block of the browser tools (BUG-025)")
    terminals.closeAITerminal(withLinks!.id)
    terminals.closeAITerminal(copilot!.id)

    let withModel = terminals.openAITerminal(.codex, model: "gpt-test")
    check(withModel?.startupCommand?.contains("gpt-test") == true && withModel?.model == "gpt-test", "a Cockpit step's own model replaces the project's choice in the command")
    let resumed = terminals.openAITerminal(.codex, resuming: true)
    check(resumed?.resumeCommand != nil && resumed?.resumeCommand?.contains("resume") == true, "a restored Codex terminal continues its last session")
    terminals.closeAITerminal(withModel!.id)
    terminals.closeAITerminal(resumed!.id)

    // MARK: BUG-005: the terminals come back
    terminals.workspaceRoot = folder
    check(RemoteConnectionsStore.shared.attached == 1, "setting the root attaches the saved remote connections of the project")
    terminals.shownID = second?.id
    let saved = defaults.dictionary(forKey: savedKey(folder))
    check(saved?["profiles"] as? [String] == ["claude", "claude", "shell"], "the profiles of the open terminals are saved in tab order (\(String(describing: saved?["profiles"])))")
    check(saved?["shown"] as? Int == 1, "and which one is shown")

    // A home assistant is never saved as a local profile.
    let invitation = try? RemoteInvitation(relay: URL(string: "http://127.0.0.1:16394")!, persistent: true)
    RemoteTerminalConnection.rootChange = nil
    let remote = try? await terminals.openRemoteAITerminal(code: invitation?.code ?? "", provider: codexTool, model: nil, resume: true)
    check(remote != nil && remote?.isRemote == true && terminals.shown === remote, "a home assistant opens as a terminal and is shown")
    check(remote?.title == "Home · Codex", "its tab says it is the home assistant (\(remote?.title ?? "nil"))")
    check(host.consoleShown >= 1, "the panel is brought to the front for it")
    check((defaults.dictionary(forKey: savedKey(folder))?["profiles"] as? [String]) == ["claude", "claude", "shell"], "a home assistant is not saved among the local terminals")
    remote?.openFile?(folder.appendingPathComponent("b.md"), nil)
    check(host.opened.last?.url.lastPathComponent == "b.md", "a home assistant's file link opens in the window's editor too")

    // The folder changes while the home assistant connects: nothing opens for the old folder.
    let count = terminals.sessions.count
    RemoteTerminalConnection.rootChange = { terminals.workspaceRoot = sandbox }
    do {
        _ = try await terminals.openRemoteAITerminal(code: invitation?.code ?? "", provider: claudeTool, model: nil, resume: false)
        check(false, "a connection that finished after the folder changed must be refused")
    } catch {
        check(terminals.sessions.count == count, "a connection that finished after the folder changed is refused and opens no terminal (\(error))")
    }
    check(RemoteTerminalConnection.stopped == 1, "and its connection is stopped")
    terminals.workspaceRoot = folder
    RemoteTerminalConnection.rootChange = nil
    terminals.closeAITerminal(remote!.id)

    // MARK: stop and come back
    terminals.shownID = second?.id
    let before = defaults.dictionary(forKey: savedKey(folder))?["profiles"] as? [String]
    terminals.stopAll()
    check(terminals.sessions.isEmpty && terminals.shownID == nil, "closing the folder ends every AI terminal")
    check(claude?.terminated == true && second?.terminated == true && shell?.terminated == true, "each terminal's shell is ended")
    check(defaults.dictionary(forKey: savedKey(folder))?["profiles"] as? [String] == before, "closing the folder keeps the saved set, so the next launch brings the terminals back")

    let relaunched = AITerminalsController(host: host, project: project, tasks: tasks)
    relaunched.workspaceRoot = folder
    check(relaunched.sessions.map(\.profile.rawValue) == ["claude", "claude", "shell"], "a new window on the folder reopens the terminals it had (\(relaunched.sessions.map(\.profile.rawValue)))")
    check(relaunched.shown === relaunched.sessions[1], "with the same terminal shown")
    check(relaunched.sessions.allSatisfy { !$0.isRunning }, "(the stand-ins started no shell)")
    check(relaunched.sessions[2].resumeCommand == nil, "a plain shell has nothing to continue")
    check(RemoteConnectionsStore.shared.attached == 4, "every new root attaches the saved remote connections (the project, the folder that changed, the project again, the new window: \(RemoteConnectionsStore.shared.attached))")

    // MARK: closing one
    let ids = relaunched.sessions.map(\.id)
    relaunched.shownID = ids[1]
    relaunched.closeAITerminal(ids[1])
    check(relaunched.shown?.id == ids[2], "closing the shown terminal shows its right neighbour")
    check((defaults.dictionary(forKey: savedKey(folder))?["profiles"] as? [String]) == ["claude", "shell"], "and the saved set follows")
    relaunched.closeAITerminal(UUID())
    check(relaunched.sessions.count == 2, "an unknown id closes nothing")

    // MARK: which assistant takes a prompt
    // Sessions: claude, shell (shown).
    relaunched.shownID = ids[2]
    check(relaunched.assistantTerminal?.profile == .claude, "with a shell shown, a prompt goes to the open assistant")
    let reply = relaunched.sendToAssistant("fix it", submit: true)
    check(reply?.profile == .claude && reply?.pasted.map(\.text) == ["fix it"] && reply?.pasted.first?.submit == true, "the prompt is pasted into that terminal and submitted")
    check(relaunched.shownID == reply?.id, "and that terminal is shown")
    check(host.consoleShown >= 2, "the panel is shown for it")
    _ = relaunched.sendToAssistant("only type this", submit: false)
    check(reply?.pasted.last?.submit == false, "a prompt can be typed without pressing Enter")
    let target = relaunched.sessions[1]
    let direct = relaunched.sendToAssistant(submit: true, to: target) { session in "for \(session.profile.rawValue)" }
    check(direct === target && target.pasted.map(\.text) == ["for shell"], "an agent that names the terminal gets its own (the prompt is built for that terminal)")
    let nothing = relaunched.sendToAssistant(submit: true, to: target) { _ in nil }
    check(nothing == nil && target.pasted.count == 1, "a prompt that cannot be built for the terminal is not sent")

    check(relaunched.currentAssistant?.tool == claudeTool, "the assistant a prompt would go to is the open Claude Code")
    relaunched.closeAITerminal(relaunched.sessions[0].id)
    check(relaunched.assistantTerminal == nil && relaunched.currentAssistant == nil, "with only a shell open there is no assistant")
    let fresh = relaunched.sendToAssistant("new one")
    check(fresh != nil && fresh?.profile != .shell && fresh?.pasted.map(\.text) == ["new one"], "with no assistant open, a prompt opens the toolbar's assistant (\(fresh?.profile.rawValue ?? "nil"))")

    // Busy: an assistant that printed in the last seconds is working.
    fresh?.running = true
    fresh?.printedRecently = false
    check(relaunched.assistantIsBusy == false, "an assistant that is quiet is not busy")
    fresh?.printedRecently = true
    check(relaunched.assistantIsBusy == true, "an assistant that is printing is busy (batch Fix with AI waits for it)")
    fresh?.running = false
    check(relaunched.assistantIsBusy == false, "an assistant that has exited is not busy")

    // MARK: restart and the toolbar's choice
    let session = relaunched.sessions.first { $0.profile != .shell }!
    relaunched.shownID = session.id
    let restarts = session.restarts.count
    relaunched.restartAITerminal()
    check(session.restarts.count == restarts + 1 && session.restarts.last?.profile == session.profile, "Restart starts the shown terminal again with the chosen assistant")
    check(session.restarts.last?.title.hasPrefix(session.profile.title) == true, "and a title that is unique among the open terminals (\(session.restarts.last?.title ?? "nil"))")
    relaunched.shownID = relaunched.sessions.first { $0.profile == .shell }!.id
    let shellRestarts = relaunched.shown!.restarts.count
    relaunched.restartAITerminal()
    check(relaunched.shown!.restarts.count == shellRestarts + 1, "a plain shell restarts too")

    // MARK: models
    let claudeSession = relaunched.sessions.first { $0.profile == .claude } ?? relaunched.openAITerminal(.claude)!
    claudeSession.running = true
    claudeSession.model = nil
    relaunched.liveModelReported("opus", terminalID: claudeSession.id)
    check(claudeSession.observedModel == "opus" && claudeSession.adopted.isEmpty, "the first reading of a terminal started with the CLI's default is that default, not a choice")
    relaunched.liveModelReported("sonnet", terminalID: claudeSession.id)
    check(claudeSession.adopted.last?.model == "sonnet", "a model the user switched to inside the session is adopted by the tab (\(claudeSession.adopted.last?.model ?? "nil"))")
    check(claudeSession.title.contains("sonnet") || claudeSession.adopted.last?.title.contains("sonnet") == true, "and shown in its title")
    claudeSession.running = false
    let adopted = claudeSession.adopted.count
    relaunched.liveModelReported("haiku", terminalID: claudeSession.id)
    check(claudeSession.adopted.count == adopted, "a terminal that is not running adopts nothing")
    relaunched.liveModelReported("opus", terminalID: UUID())
    check(claudeSession.adopted.count == adopted, "a report for a terminal that is gone is ignored")

    claudeSession.running = true
    relaunched.shownID = claudeSession.id
    relaunched.switchModel(of: claudeSession, to: "not-a-family")
    check(claudeSession.pasted.last?.text.hasPrefix("/model") != true, "a model that is not a family alias is never typed into the session")
    claudeSession.printedRecently = false
    relaunched.switchModel(of: claudeSession, to: "opus")
    check(claudeSession.pasted.last?.text == "/model opus" && claudeSession.pasted.last?.submit == true && claudeSession.pendingModelPick == "opus", "Claude Code switches live: /model is typed into the running session")
    let remoteSession = TerminalSession(directory: folder, profile: .claude, startupCommand: nil, resumeCommand: nil, title: "Home", model: nil)
    remoteSession.connection = RemoteTerminalConnection()
    let remoteRestarts = remoteSession.restarts.count
    relaunched.switchModel(of: remoteSession, to: "opus")
    check(remoteSession.restarts.count == remoteRestarts && remoteSession.pasted.isEmpty, "a home assistant's model is not switched from here")

    // MARK: terminals shown as editor tabs
    let tab = terminals.makeTabTerminal(in: folder.appendingPathComponent("sub/../sub"), startupCommand: "npm run dev", title: "Dev server")
    check(terminals.tabTerminal(tab.id) === tab && tab.startupCommand == "npm run dev" && tab.title == "Dev server", "an editor-tab terminal is kept under its tab id")
    check(tab.directory == folder.appendingPathComponent("sub").standardizedFileURL, "its folder is standardized")
    check(!terminals.sessions.contains { $0 === tab }, "it is not one of the AI panel's terminals")
    check(terminals.previewTerminal(forApp: "/app") == nil, "no dev server is remembered at first")
    terminals.rememberPreviewTerminal(tab, forApp: "/app")
    check(terminals.previewTerminal(forApp: "/app") === tab, "Preview Web App finds the dev server it started")
    terminals.closeTabTerminal(tab.id)
    check(tab.terminated && terminals.tabTerminal(tab.id) == nil && terminals.previewTerminal(forApp: "/app") == nil, "closing the tab ends its shell and forgets the dev server")
    let other = terminals.makeTabTerminal(in: folder, startupCommand: nil, title: nil)
    terminals.rememberPreviewTerminal(other, forApp: "/other")
    terminals.stopAll()
    check(other.terminated && terminals.tabTerminal(other.id) == nil && terminals.previewTerminal(forApp: "/other") == nil, "closing the folder ends the editor-tab terminals and forgets the dev servers")

    tasks.cancelAll()
    try? fm.removeItem(at: sandbox)
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await run()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}

print("\nAI terminals summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
