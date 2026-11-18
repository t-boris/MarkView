import Foundation
import AppKit
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor
private final class TerminalPolicyPrompts: UserPrompts {
    var answers: [Int?] = []
    private(set) var asked: [UserPrompt] = []
    func ask(_ prompt: UserPrompt) -> Int? {
        asked.append(prompt)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}



extension EditorHostTests {
    @MainActor func testRealAITerminalsLifecycleAndPersistence() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-ai-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldClaudeTools = settings.stored(claude.agentToolsKey)
        let oldCodexTools = settings.stored(codex.agentToolsKey)
        let oldBackend = settings.stored(Setting.aiBackend)
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(nil, for: savedKey)
        settings.set(true, for: claude.agentToolsKey)
        settings.set(true, for: codex.agentToolsKey)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldClaudeTools, for: claude.agentToolsKey)
            settings.set(oldCodexTools, for: codex.agentToolsKey)
            settings.set(oldBackend, for: Setting.aiBackend)
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        let other = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("other.json"))
        defer {
            AgentToolServer.unregister(window.browser.controlID)
            AgentToolServer.unregister(other.browser.controlID)
            window.composition.close()
            other.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        let terminals = window.terminals
        XCTAssertTrue(terminals.activity.provider === terminals)
        XCTAssertNil(terminals.root)
        XCTAssertTrue(terminals.sessions.isEmpty)
        XCTAssertNil(terminals.openAITerminal(TerminalProfile(claude)))
        XCTAssertNil(terminals.ensureAITerminal())
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        XCTAssertEqual(terminals.root?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertNil(terminals.workspaceRoot)
        let first = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(claude)))
        let second = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(claude)))
        let shell = try XCTUnwrap(terminals.openAITerminal(.shell))
        XCTAssertEqual(first.directory.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(first.title, "Claude Code")
        XCTAssertEqual(second.title, "Claude Code 2")
        XCTAssertEqual(shell.title, "Shell")
        XCTAssertNil(shell.startupCommand)
        XCTAssertTrue(first.startupCommand?.contains(" update && ") == true)
        XCTAssertTrue(first.startupCommand?.contains("--mcp-config") == true)
        XCTAssertEqual(first.browserWindowID, window.browser.controlID)
        XCTAssertTrue(terminals.shown === shell)
        XCTAssertTrue(terminals.assistantTerminal === first)
        XCTAssertTrue(terminals.sessions.allSatisfy { !$0.isRunning })
        let model = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(codex), model: "gpt-fixture"))
        XCTAssertEqual(model.model, "gpt-fixture")
        XCTAssertTrue(model.startupCommand?.contains("gpt-fixture") == true)
        let resumed = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(codex), resuming: true))
        XCTAssertEqual(resumed.profile, TerminalProfile(codex))
        terminals.closeAITerminal(model.id)
        terminals.closeAITerminal(resumed.id)
        terminals.workspaceRoot = root
        terminals.shownID = second.id
        let saved = try XCTUnwrap(settings.stored(savedKey))
        XCTAssertEqual(saved["profiles"] as? [String], ["claude", "claude", "shell"])
        XCTAssertEqual(saved["shown"] as? Int, 1)
        terminals.stopAll()
        XCTAssertTrue(terminals.sessions.isEmpty)
        XCTAssertNil(terminals.shownID)
        XCTAssertEqual(settings.stored(savedKey)?["profiles"] as? [String], ["claude", "claude", "shell"])
        other.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        other.terminals.workspaceRoot = root
        XCTAssertEqual(other.terminals.sessions.map(\.profile.rawValue), ["claude", "claude", "shell"])
        guard other.terminals.sessions.count == 3 else { XCTFail("The saved terminals must be restored"); return }
        XCTAssertEqual(other.terminals.shown?.profile, TerminalProfile(claude))
        XCTAssertTrue(other.terminals.shown === other.terminals.sessions[1])
        XCTAssertTrue(other.terminals.sessions.allSatisfy { !$0.isRunning })
        let restoredIDs = other.terminals.sessions.map(\.id)
        other.terminals.closeAITerminal(restoredIDs[1])
        XCTAssertEqual(other.terminals.shownID, restoredIDs[2])
        XCTAssertEqual(settings.stored(savedKey)?["profiles"] as? [String], ["claude", "shell"])
        other.terminals.closeAITerminal(UUID())
        XCTAssertEqual(other.terminals.sessions.count, 2)
        let restoredAssistant = try XCTUnwrap(other.terminals.sessions.first)
        let restoredShell = try XCTUnwrap(other.terminals.sessions.last)
        XCTAssertTrue(other.terminals.assistantTerminal === restoredAssistant)
        XCTAssertEqual(other.terminals.currentAssistant?.tool, claude)
        XCTAssertFalse(other.terminals.assistantIsBusy)
        let receiver = other.terminals.sendToAssistant("isolated prompt", submit: true)
        XCTAssertTrue(receiver === restoredAssistant)
        XCTAssertEqual(other.terminals.shownID, restoredAssistant.id)
        XCTAssertTrue(restoredAssistant.hasPendingPaste)
        var requestedProfile: TerminalProfile?
        let direct = other.terminals.sendToAssistant(submit: false, to: restoredShell) { session in
            requestedProfile = session.profile
            return "shell prompt"
        }
        XCTAssertTrue(direct === restoredShell)
        XCTAssertEqual(requestedProfile, .shell)
        XCTAssertTrue(restoredShell.hasPendingPaste)
        XCTAssertNil(other.terminals.sendToAssistant(submit: true, to: restoredShell) { _ in nil })
        other.terminals.closeAITerminal(restoredAssistant.id)
        XCTAssertNil(other.terminals.assistantTerminal)
        XCTAssertNil(other.terminals.currentAssistant)
        settings.set(codex.rawValue, for: Setting.aiBackend)
        let fresh = try XCTUnwrap(other.terminals.sendToAssistant("open a new assistant"))
        XCTAssertEqual(fresh.profile, TerminalProfile(codex))
        XCTAssertTrue(fresh.hasPendingPaste)
        XCTAssertFalse(fresh.isRunning)
    }

    @MainActor func testRealAITerminalResumesWithoutStartingAnAssistant() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-resume-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        IFS= read -r line || exit 1
        printf '%s' "$line" > command.txt
        while IFS= read -r line; do :; done
        """
        try shellSource.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let oldShell = getenv("SHELL").map { String(cString: $0) }
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldTools = settings.stored(codex.agentToolsKey)
        settings.set(false, for: codex.agentToolsKey)
        setenv("SHELL", shell.path, 1)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldTools, for: codex.agentToolsKey)
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer {
            AgentToolServer.unregister(window.browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let terminal = try XCTUnwrap(window.terminals.openAITerminal(TerminalProfile(codex), resuming: true))
        terminal.start()
        let pid = terminal.shellPID
        XCTAssertGreaterThan(pid, 0)
        let commandFile = root.appendingPathComponent("command.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: commandFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let command = try String(contentsOf: commandFile, encoding: .utf8)
        XCTAssertTrue(command.contains("resume --last"), "The restored terminal sends the provider's resume command")
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(pid, 0), -1)
        try FileManager.default.removeItem(at: commandFile)
        window.terminals.restartAITerminal()
        let restartedPID = terminal.shellPID
        XCTAssertGreaterThan(restartedPID, 0)
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: commandFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let restartedCommand = try String(contentsOf: commandFile, encoding: .utf8)
        XCTAssertFalse(restartedCommand.contains("resume --last"), "An explicit restart uses the ordinary startup command")
        XCTAssertEqual(terminal.profile, TerminalProfile(codex))
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(restartedPID, 0), -1)
    }

    @MainActor func testRealAITerminalPromptDeliveryAndActivity() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-prompt-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        IFS= read -r line || exit 1
        printf 'started' > started.txt
        IFS= read -r line || exit 1
        printf '%s' "$line" > prompt.txt
        while IFS= read -r line; do :; done
        """
        try shellSource.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldTools = settings.stored(codex.agentToolsKey)
        let oldShell = getenv("SHELL").map { String(cString: $0) }
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(false, for: codex.agentToolsKey)
        setenv("SHELL", shell.path, 1)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldTools, for: codex.agentToolsKey)
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer {
            AgentToolServer.unregister(window.browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let terminals = window.terminals
        let terminal = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(codex)))
        terminal.start()
        let pid = terminal.shellPID
        XCTAssertGreaterThan(pid, 0)
        let started = root.appendingPathComponent("started.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertTrue(terminals.assistantIsBusy)
        let receiver = terminals.sendToAssistant("test prompt from fixture", submit: true)
        XCTAssertTrue(receiver === terminal)
        XCTAssertTrue(terminal.hasPendingPaste)
        let promptFile = root.appendingPathComponent("prompt.txt")
        for _ in 0..<800 where !FileManager.default.fileExists(atPath: promptFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let received = try String(contentsOf: promptFile, encoding: .utf8)
        XCTAssertTrue(received.contains("test prompt from fixture"))
        XCTAssertFalse(terminal.hasPendingPaste)
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(terminals.assistantIsBusy)
    }

    @MainActor func testRealAITerminalReceivesLinkedProjectFolders() throws {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-linked-" + UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let linked = base.appendingPathComponent("linked docs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "mv-linked-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"), settings: Settings(defaults))
        defer { project.close() }
        project.beginOpening(root)
        project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        XCTAssertTrue(project.linkFolders([linked]).isEmpty)
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let oldTools = settings.stored(claude.agentToolsKey)
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(false, for: claude.agentToolsKey)
        setenv("MARKVIEW_SOCKET_DIR", base.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldTools, for: claude.agentToolsKey)
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("window.json"))
        let tasks = TaskBag()
        let polling = PollingScheduler()
        let terminals = AITerminalsController(host: window, project: project, tasks: tasks, polling: polling, prompts: QAPlayerPrompts())
        defer {
            terminals.stopAll()
            tasks.cancelAll()
            polling.stopAll()
            AgentToolServer.unregister(window.browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(base.path + "/") == true { AgentToolServer.shutdown() }
        }
        XCTAssertTrue(polling.keys.contains { $0.hasPrefix("agent-activity-") })
        XCTAssertEqual(polling.runningCount, 1)
        polling.setWindowVisible(false)
        XCTAssertEqual(polling.runningCount, 0)
        polling.setWindowVisible(true)
        XCTAssertEqual(polling.runningCount, 1)
        let terminal = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(claude)))
        let command = try XCTUnwrap(terminal.startupCommand)
        XCTAssertTrue(command.contains("--add-dir"))
        XCTAssertTrue(command.contains("'" + linked.standardizedFileURL.path + "'"))
        XCTAssertFalse(terminal.isRunning)
    }

    @MainActor func testRealRemoteAITerminalStaysOutOfLocalSavedProfiles() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-remote-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldTools = settings.stored(codex.agentToolsKey)
        let oldDeviceID = settings.stored(Setting.remoteDeviceID)
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(nil, for: savedKey)
        settings.set(false, for: codex.agentToolsKey)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldTools, for: codex.agentToolsKey)
            settings.set(oldDeviceID, for: Setting.remoteDeviceID)
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer {
            AgentToolServer.unregister(window.browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let terminals = window.terminals
        terminals.workspaceRoot = root
        let local = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(codex)))
        let server = try BrowserFixtureServer()
        let relay = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)"))
        let invitation = try RemoteInvitation(relay: relay, persistent: true)
        let connectionID = UUID()
        let remote = try await terminals.openRemoteAITerminal(code: invitation.code, provider: codex, model: nil, resume: true,
                                                               savedConnectionID: connectionID)
        XCTAssertTrue(remote.isRemote)
        XCTAssertFalse(remote.isRunning, "The fixture must not connect to a relay")
        XCTAssertEqual(remote.title, "Home · Codex")
        XCTAssertTrue(terminals.shown === remote)
        terminals.switchModel(of: remote, to: "fixture-model")
        XCTAssertNil(remote.model)
        XCTAssertFalse(remote.isRunning)
        XCTAssertEqual(settings.stored(savedKey)?["profiles"] as? [String], ["codex"])
        remote.start()
        for _ in 0..<500 where RemoteConnectionsStore.shared.state(connectionID).phase == .offline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(RemoteConnectionsStore.shared.state(connectionID).phase, .offline)
        terminals.closeAITerminal(remote.id)
        XCTAssertEqual(RemoteConnectionsStore.shared.state(connectionID).phase, .offline)
        XCTAssertTrue(terminals.shown === local)
        do {
            _ = try await terminals.openRemoteAITerminal(code: "invalid", provider: codex, model: nil, resume: false)
            XCTFail("An invalid invitation must be refused")
        } catch {
            XCTAssertEqual(terminals.sessions.count, 1)
            XCTAssertTrue(terminals.sessions.first === local)
        }
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        var refusedConnection: RemoteTerminalConnection?
        RemoteTerminalConnection.testOnInitialized = { connection in
            refusedConnection = connection
            terminals.workspaceRoot = otherRoot
        }
        defer { RemoteTerminalConnection.testOnInitialized = nil }
        do {
            _ = try await terminals.openRemoteAITerminal(code: invitation.code, provider: codex, model: nil, resume: false)
            XCTFail("A connection for the old project must be refused")
        } catch {
            XCTAssertEqual(terminals.sessions.count, 1)
            XCTAssertTrue(terminals.sessions.first === local)
            XCTAssertTrue(refusedConnection?.testIsStopped == true)
            XCTAssertEqual(settings.stored(savedKey)?["profiles"] as? [String], ["codex"])
        }
        withExtendedLifetime(server) {}
    }

    @MainActor func testRealAITerminalPolicyPromptAndRestart() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-policy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        while IFS= read -r line; do
          printf 'MCP server was blocked by policy: "markview-browser"\\n'
        done
        """
        try shellSource.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let copilot = try XCTUnwrap(CLITool(rawValue: "copilot"))
        let oldTools = settings.stored(copilot.agentToolsKey)
        let oldShell = getenv("SHELL").map { String(cString: $0) }
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(true, for: copilot.agentToolsKey)
        setenv("SHELL", shell.path, 1)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldTools, for: copilot.agentToolsKey)
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let prompts = TerminalPolicyPrompts()
        prompts.answers = [1, nil, 0]
        let window = WorkspaceManager(prompts: prompts, recentFilesURL: root.appendingPathComponent("recent.json"))
        defer {
            AgentToolServer.unregister(window.browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let terminal = try XCTUnwrap(window.terminals.openAITerminal(TerminalProfile(copilot)))
        terminal.start()
        let originalPID = terminal.shellPID
        XCTAssertGreaterThan(originalPID, 0)
        for _ in 0..<500 where prompts.asked.count < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(prompts.asked.count, 1)
        XCTAssertEqual(prompts.asked.first?.buttons, ["Restart Copilot Without Them", "Later"])
        XCTAssertTrue(prompts.asked.first?.detail.contains("markview-browser") == true)
        XCTAssertFalse(settings.value(copilot.agentToolsKey))
        XCTAssertEqual(terminal.shellPID, originalPID, "Later must leave the terminal running")
        settings.set(true, for: copilot.agentToolsKey)
        terminal.write("again\r")
        for _ in 0..<500 where prompts.asked.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(prompts.asked.count, 2)
        XCTAssertEqual(terminal.shellPID, originalPID, "No answer must leave the terminal running")
        settings.set(true, for: copilot.agentToolsKey)
        terminal.write("again\r")
        for _ in 0..<500 where prompts.asked.count < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(prompts.asked.count, 3)
        XCTAssertNotEqual(terminal.shellPID, originalPID)
        XCTAssertTrue(terminal.startupCommand?.contains("--continue") == true)
        XCTAssertFalse(terminal.startupCommand?.contains("--additional-mcp-config") == true)
        let restartedPID = terminal.shellPID
        XCTAssertGreaterThan(restartedPID, 0)
        if let reap = terminal.terminate() { await reap.value }
        for _ in 0..<500 where kill(originalPID, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(kill(originalPID, 0), -1)
        XCTAssertEqual(kill(restartedPID, 0), -1)
    }

    @MainActor func testRealAITerminalLiveModelChanges() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-model-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        IFS= read -r line || exit 1
        printf 'started' > started.txt
        IFS= read -r line || exit 1
        printf '%s' "$line" > model-command.txt
        while IFS= read -r line; do :; done
        """
        try shellSource.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let settings = Settings.standard
        let savedKey = Setting.aiTerminals(folder: String(ContentHash.of(root.standardizedFileURL.path).prefix(12)))
        let oldSaved = settings.stored(savedKey)
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let oldTools = settings.stored(claude.agentToolsKey)
        let modelKey = Setting.cliModel(claude.rawValue)
        let oldModel = settings.stored(modelKey)
        let oldShell = getenv("SHELL").map { String(cString: $0) }
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(false, for: claude.agentToolsKey)
        settings.set("", for: modelKey)
        setenv("SHELL", shell.path, 1)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldSaved, for: savedKey)
            settings.set(oldTools, for: claude.agentToolsKey)
            settings.set(oldModel, for: modelKey)
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer {
            AgentToolServer.unregister(window.browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let terminals = window.terminals
        let terminal = try XCTUnwrap(terminals.openAITerminal(TerminalProfile(claude)))
        XCTAssertNil(terminal.model)
        terminal.start()
        let pid = terminal.shellPID
        XCTAssertGreaterThan(pid, 0)
        let started = root.appendingPathComponent("started.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        terminals.liveModelReported("opus", terminalID: terminal.id)
        XCTAssertEqual(terminal.observedModel, "opus")
        XCTAssertNil(terminal.model, "The first report names the CLI default, not a model choice")
        terminals.liveModelReported("sonnet", terminalID: terminal.id)
        XCTAssertEqual(terminal.model, "sonnet")
        XCTAssertTrue(terminal.title.contains("sonnet"))
        XCTAssertEqual(settings.value(modelKey), "sonnet")
        for _ in 0..<500 where terminal.printed(within: 3) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(terminals.assistantIsBusy)
        terminals.switchModel(of: terminal, to: "opus")
        XCTAssertEqual(terminal.pendingModelPick, "opus")
        let commandFile = root.appendingPathComponent("model-command.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: commandFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let command = try String(contentsOf: commandFile, encoding: .utf8)
        XCTAssertTrue(command.contains("/model opus"))
        terminals.liveModelReported("opus", terminalID: terminal.id)
        XCTAssertNil(terminal.pendingModelPick)
        XCTAssertEqual(terminal.model, "opus")
        XCTAssertEqual(settings.value(modelKey), "opus")
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(pid, 0), -1)
        terminals.liveModelReported("haiku", terminalID: terminal.id)
        XCTAssertEqual(terminal.model, "opus", "Reports for a stopped terminal are ignored")
    }

}
