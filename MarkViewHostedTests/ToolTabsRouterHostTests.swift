import Foundation
import AppKit
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor
private final class RoutingAssistant: AssistantPrompting {
    var assistantIsBusy = false
    private(set) var prompts: [(text: String, submit: Bool)] = []
    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? {
        prompts.append((prompt, submit))
        return nil
    }
    func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? { nil }
}

private final class DiscussionRunnerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CLICompletion.Request] = []
    private var cancellations = 0
    func record(_ request: CLICompletion.Request) { lock.lock(); requests.append(request); lock.unlock() }
    func recordCancellation() { lock.lock(); cancellations += 1; lock.unlock() }
    var seen: [CLICompletion.Request] { lock.lock(); defer { lock.unlock() }; return requests }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

extension EditorHostTests {
    @MainActor func testRealBrowserHostTabLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-routing-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.chrome.showCenter = false
        window.layout.workspaceArea = .work
        let browser = window.browser
        let first = browser.open(nil)
        XCTAssertEqual(first.agentName, "T1")
        XCTAssertEqual(window.tabs.openTabs.count, 1)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertTrue(window.chrome.showCenter)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertEqual(window.tabs.openTabs[0].url.deletingLastPathComponent().path, root.path)
        if case .browser(let session) = window.tabs.openTabs[0].kind {
            XCTAssertTrue(session === first)
        } else {
            XCTFail("The new tab must contain the browser session")
        }
        first.agentName = "Jira"
        let second = browser.open(nil)
        let third = browser.open(nil)
        XCTAssertEqual(second.agentName, "T1")
        XCTAssertEqual(third.agentName, "T2")
        XCTAssertEqual(browser.sessions.map(\.id), [first.id, second.id, third.id])
        window.chrome.showCenter = false
        window.layout.workspaceArea = .work
        browser.show(first)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        browser.show(BrowserSession(url: nil, prompts: NoPrompts()))
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        let fourth = browser.open(nil, activate: false)
        XCTAssertEqual(fourth.agentName, "T3")
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        browser.browserSession(first, openInNewTab: try XCTUnwrap(URL(string: "http://127.0.0.1:1/new")))
        XCTAssertEqual(browser.sessions.count, 5)
        XCTAssertEqual(browser.sessions.last?.url?.path, "/new")
        XCTAssertEqual(window.tabs.activeTabIndex, 4)
    }

    @MainActor func testRealBrowserHostLocalHTMLRouting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-html-" + UUID().uuidString, isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = site.appendingPathComponent("index.html")
        try "<html><body>Isolated fixture</body></html>".write(to: page, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let browser = window.browser
        browser.openHTML(site.appendingPathComponent("missing.html"))
        browser.openHTML(site.appendingPathComponent("notes.md"))
        XCTAssertTrue(browser.sessions.isEmpty)
        browser.openHTML(page)
        let first = try XCTUnwrap(browser.sessions.first)
        XCTAssertEqual(first.url?.standardizedFileURL, page.standardizedFileURL)
        XCTAssertEqual(first.localReadRoot?.standardizedFileURL, root.standardizedFileURL)
        browser.open(nil)
        XCTAssertEqual(window.tabs.activeTabIndex, 1)
        browser.openHTML(page)
        XCTAssertEqual(browser.sessions.count, 2)
        XCTAssertTrue(browser.sessions.first === first)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertEqual(first.url?.standardizedFileURL, page.standardizedFileURL)
    }

    @MainActor func testRealBrowserHostPreviewSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("empty.json"))
        defer { empty.composition.close() }
        empty.browser.previewWebApp()
        let emptyPreview = try XCTUnwrap(empty.browser.sessions.first)
        XCTAssertTrue(emptyPreview.isAppPreview)
        XCTAssertEqual(emptyPreview.preview, .noApp)

        for name in ["api", "web"] {
            let config = root.appendingPathComponent(name).appendingPathComponent(".markview", isDirectory: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try #"{"command":"npm run dev","ports":[12345],"reuseRunningServer":false}"#
                .write(to: config.appendingPathComponent("preview.json"), atomically: true, encoding: .utf8)
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.browser.previewWebApp()
        let preview = try XCTUnwrap(window.browser.sessions.first)
        for _ in 0..<500 {
            if case .choose = preview.preview { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .choose(let targets) = preview.preview else {
            XCTFail("The preview must offer both discovered applications")
            return
        }
        XCTAssertEqual(Set(targets.map(\.label)), Set(["api", "web"]))
        window.browser.previewWebApp()
        XCTAssertEqual(window.browser.sessions.count, 1)
        XCTAssertTrue(window.browser.sessions.first === preview)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
    }

    @MainActor func testRealBrowserHostAgentRegistration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-agent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings.standard
        let agent = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldBrowserSetting = settings.stored(Setting.openTerminalLinksInApp)
        let oldAgentSetting = settings.stored(agent.agentToolsKey)
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(true, for: Setting.openTerminalLinksInApp)
        settings.set(true, for: agent.agentToolsKey)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldBrowserSetting, for: Setting.openTerminalLinksInApp)
            settings.set(oldAgentSetting, for: agent.agentToolsKey)
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.terminals.workspaceRoot = root
        let host = window.browser
        host.register()
        let createdListener = AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true
        defer {
            AgentToolServer.unregister(host.controlID)
            window.composition.close()
            if createdListener { AgentToolServer.shutdown() }
        }
        func call(_ tool: String, _ args: [String: Any] = [:]) async -> BrowserAgentTools.Reply {
            await AgentToolServer.performForRelay(tool, args, window: host.controlID, root: root, agent: agent)
        }
        let empty = await call("browser_tabs")
        XCTAssertFalse(empty.isError)
        XCTAssertTrue(empty.text.contains("No browser tabs are open"))
        let opened = await call("browser_open_tab", ["name": "Jira"])
        XCTAssertFalse(opened.isError)
        XCTAssertEqual(opened.text, "Opened tab Jira.")
        let first = try XCTUnwrap(host.sessions.first)
        XCTAssertEqual(first.agentName, "Jira")
        XCTAssertNotNil(first.agentLastUsed)
        let list = await call("browser_tabs")
        XCTAssertTrue(list.text.contains("Jira"))
        XCTAssertTrue(list.text.contains("[active]"))
        let missing = await call("browser_click", ["tab": "Nowhere"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No single browser tab matches"))
        first.agentStopped = true
        let stopped = await call("browser_click", ["tab": "Jira"])
        XCTAssertTrue(stopped.isError)
        XCTAssertTrue(stopped.text.contains("stopped agent control"))
        let second = await call("browser_open_tab")
        XCTAssertEqual(second.text, "Opened tab T1.")
        XCTAssertEqual(host.sessions.map(\.agentName), ["Jira", "T1"])
    }

    @MainActor func testRealBrowserHostReusesTabsForProgramPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-pages-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var listeners: [Int32] = []
        defer { for descriptor in listeners { Darwin.close(descriptor) } }
        func localAddress(_ path: String) throws -> URL {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            listeners.append(descriptor)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EIO) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            guard found == 0 else { throw POSIXError(.EIO) }
            return try XCTUnwrap(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/\(path)"))
        }
        let firstURL = try localAddress("first")
        let otherURL = try localAddress("other")
        let thirdURL = try localAddress("third")
        let fourthURL = try localAddress("fourth")
        let note = root.appendingPathComponent("note.md")
        try "fixture".write(to: note, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let browser = window.browser
        browser.openInAppBrowser(firstURL)
        let first = try XCTUnwrap(browser.sessions.first)
        XCTAssertEqual(first.url, firstURL)
        let other = browser.open(otherURL)
        let sameServer = try XCTUnwrap(URL(string: "next", relativeTo: firstURL)?.absoluteURL)
        browser.openInAppBrowser(sameServer)
        XCTAssertEqual(browser.sessions.count, 2)
        XCTAssertEqual(first.url, sameServer)
        XCTAssertEqual(other.url, otherURL)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        window.tabs.activeTabIndex = 1
        browser.openInAppBrowser(thirdURL)
        XCTAssertEqual(other.url, thirdURL)
        XCTAssertEqual(window.tabs.activeTabIndex, 1)
        first.isAppPreview = true
        await window.tabs.openTextFile(note)
        browser.openInAppBrowser(fourthURL)
        XCTAssertEqual(first.url, fourthURL)
        XCTAssertEqual(other.url, thirdURL)
        first.isAppPreview = false
        await window.tabs.openTextFile(note)
        browser.openInAppBrowser(otherURL)
        XCTAssertEqual(first.url, otherURL)
        XCTAssertEqual(browser.sessions.count, 2)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
    }

    @MainActor func testRealBrowserHostStartsAndCancelsPreviewTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-server-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        IFS= read -r line || exit 1
        printf '%s' "$line" > received.txt
        while IFS= read -r line; do :; done
        """
        try shellSource.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let oldShell = getenv("SHELL").map { String(cString: $0) }
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        setenv("SHELL", shell.path, 1)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") }
            if let oldSocketDirectory { setenv("MARKVIEW_SOCKET_DIR", oldSocketDirectory, 1) }
            else { unsetenv("MARKVIEW_SOCKET_DIR") }
        }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let browser = window.browser
        let session = browser.open(nil)
        let target = WebAppTarget(folder: root, label: "fixture", command: "fixture-command", ports: [], reuseRunningServer: false)
        browser.browserSession(session, startWebApp: target)
        defer {
            AgentToolServer.unregister(browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
        }
        for _ in 0..<500 {
            if session.previewTerminalID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let terminalID = try XCTUnwrap(session.previewTerminalID)
        let terminal = try XCTUnwrap(window.terminals.tabTerminal(terminalID))
        XCTAssertEqual(terminal.directory.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(terminal.startupCommand, "fixture-command")
        XCTAssertTrue(terminal.isRunning)
        if case .starting(let found, started: true) = session.preview {
            XCTAssertEqual(found, target)
        } else {
            XCTFail("The preview must wait for its started server")
        }
        let received = root.appendingPathComponent("received.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: received.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try String(contentsOf: received, encoding: .utf8), "fixture-command")
        browser.browserSessionShowTerminal(session)
        XCTAssertEqual(window.tabs.activeTabIndex, 1)
        let pid = terminal.shellPID
        XCTAssertGreaterThan(pid, 0)
        browser.close()
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(terminal.isRunning)
        if case .starting = session.preview {} else { XCTFail("Closing the host must not report a server timeout") }
    }

    @MainActor func testRealBrowserHostPreviewOccupiedAndReusableServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-listener-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else { Darwin.close(descriptor); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard found == 0 else { Darwin.close(descriptor); throw POSIXError(.EIO) }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let server = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        server.setEventHandler {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let response = Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            Darwin.close(client)
        }
        server.setCancelHandler { Darwin.close(descriptor) }
        server.resume()
        defer { server.cancel() }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let browser = window.browser
        let busy = browser.open(nil)
        let isolated = WebAppTarget(folder: root, label: "fixture", command: "must-not-run", ports: [port], reuseRunningServer: false)
        browser.browserSession(busy, startWebApp: isolated)
        for _ in 0..<500 {
            if case .portInUse = busy.preview { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .portInUse(let target, let occupiedPort) = busy.preview {
            XCTAssertEqual(target, isolated)
            XCTAssertEqual(occupiedPort, port)
        } else {
            XCTFail("An isolated preview must refuse a port owned by another server")
        }
        XCTAssertNil(busy.previewTerminalID)
        XCTAssertEqual(window.tabs.openTabs.count, 1)
        let reusable = browser.open(nil)
        var shared = isolated
        shared.reuseRunningServer = true
        browser.browserSession(reusable, startWebApp: shared)
        for _ in 0..<500 {
            if reusable.url?.port == port { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(reusable.url?.port, port)
        XCTAssertNil(reusable.preview)
        XCTAssertNil(reusable.previewTerminalID)
        XCTAssertEqual(window.tabs.openTabs.count, 2)
    }

    @MainActor func testRealToolTabsRoutingAndProjectLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-routing-" + UUID().uuidString)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        blank.toolTabs.open(.git)
        XCTAssertTrue(blank.tabs.openTabs.isEmpty, "A tool cannot open without a project")
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: first, isDirectory: true)
        let router = window.toolTabs
        XCTAssertTrue(router.qa.assistants === window.terminals)
        let tools = ToolRegistry.shared.tools
        for tool in tools {
            router.open(tool.id)
            XCTAssertEqual(window.tabs.openTabs.filter { $0.kind.toolID == tool.id }.count, 1, "\(tool.id.rawValue) opens once")
            XCTAssertEqual(window.tabs.activeTab?.kind.toolID, tool.id)
        }
        XCTAssertEqual(window.tabs.openTabs.count, tools.count)
        for tool in tools {
            router.open(tool.id)
            XCTAssertEqual(window.tabs.openTabs.filter { $0.kind.toolID == tool.id }.count, 1, "\(tool.id.rawValue) is reused")
            XCTAssertEqual(window.tabs.activeTab?.kind.toolID, tool.id)
        }
        XCTAssertEqual(window.tabs.openTabs.count, tools.count)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        XCTAssertEqual(router.deployments.store.root, first)
        XCTAssertEqual(router.discussions.store.root, first)
        XCTAssertEqual(router.qa.root, first)
        XCTAssertNotNil(router.qa.run.bugFiler)
        XCTAssertTrue(router.qa.run.bugFiler === router.qa.archive.bugFiler)
        XCTAssertTrue(router.qa.run.runLinks is CockpitRunLinks)
        XCTAssertTrue(router.qa.archive.runLinks is CockpitRunLinks)
        guard let studioTab = window.tabs.openTabs.first(where: { $0.kind.toolID == .uiStudio }),
              case .uiStudio(let studio) = studioTab.kind,
              let cockpitTab = window.tabs.openTabs.first(where: { $0.kind.toolID == .cockpit }),
              case .cockpit(let cockpit) = cockpitTab.kind else {
            XCTFail("UI Studio and Cockpit must carry their actual sessions")
            return
        }
        XCTAssertEqual(studio.root, first)
        XCTAssertEqual(cockpit.root, first)
        let cockpitIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit })
        window.tabs.closeTab(at: cockpitIndex)
        router.open(.cockpit)
        guard case .cockpit(let reopened)? = window.tabs.activeTab?.kind else { XCTFail("Cockpit did not reopen"); return }
        XCTAssertTrue(reopened === cockpit)
        let deploymentIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .deployments })
        window.tabs.closeTab(at: deploymentIndex)
        router.deployments.store.needsAttention.send()
        XCTAssertEqual(window.tabs.activeTab?.kind.toolID, .deployments)
        router.projectOpened(second)
        XCTAssertEqual(router.deployments.store.root, second)
        XCTAssertEqual(router.discussions.store.root, second)
        router.projectClosed()
        XCTAssertNil(router.deployments.store.root)
        XCTAssertNil(router.discussions.store.root)
        let oldCockpitIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit })
        window.tabs.closeTab(at: oldCockpitIndex)
        router.open(.cockpit)
        guard case .cockpit(let renewed)? = window.tabs.activeTab?.kind else { XCTFail("Cockpit did not renew"); return }
        XCTAssertFalse(renewed === cockpit)
        await studio.close()
    }

    @MainActor func testRealDiscussionHostLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-routing-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "discussion-routing-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"), settings: Settings(defaults))
        project.beginOpening(root)
        project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        func expectEventually(_ condition: () -> Bool, line: UInt = #line) async throws {
            let reached = try await wait(condition)
            XCTAssertTrue(reached, "Expected condition was not reached", line: line)
        }
        let spy = DiscussionRunnerSpy()
        let notes = "\n```discussion-notes\n{\"decisions\": [\"Documents only\"], \"open_questions\": [\"Sync back?\"]}\n```"
        let answer: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = { request, onDelta, onActivity in
            spy.record(request)
            onActivity?(.read("/project/Sources/App.swift"))
            onDelta?("Offline works ")
            onDelta?("for documents.")
            return try CLICompletion.Result(text: "Offline works for documents." + notes, structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        var opened = 0
        let host = DiscussionsHost(project: project, showTab: { opened += 1 }, runner: answer)
        defer { host.close() }
        host.projectOpened(root)
        let slug = try XCTUnwrap(host.store.create(title: "Offline mode", scope: "Sources"))
        host.ask(slug, question: "   ")
        XCTAssertNil(host.store.asking)
        host.ask(slug, question: "  Which data must work offline?  ")
        XCTAssertEqual(host.store.asking, slug)
        XCTAssertEqual(host.store.live?.question, "Which data must work offline?")
        host.ask(slug, question: "A second question")
        let finished = try await wait { host.store.asking == nil }
        XCTAssertTrue(finished)
        let discussion = try XCTUnwrap(host.store.discussions.first { $0.slug == slug })
        XCTAssertEqual(discussion.turns.count, 1)
        XCTAssertEqual(discussion.turns.first?.question, "Which data must work offline?")
        XCTAssertEqual(discussion.turns.first?.answer, "Offline works for documents.")
        XCTAssertEqual(discussion.items(.decision).map(\.text), ["Documents only"])
        XCTAssertEqual(discussion.items(.question).map(\.text), ["Sync back?"])
        XCTAssertNil(host.store.live)
        XCTAssertNil(host.store.lastError)
        let sent = try XCTUnwrap(spy.seen.first)
        XCTAssertEqual(spy.seen.count, 1)
        XCTAssertEqual(sent.label, "discussion")
        XCTAssertEqual(sent.effort, "medium")
        XCTAssertEqual(sent.timeout, 900)
        XCTAssertEqual(sent.systemPrompt, DiscussionPrompt.system)
        XCTAssertEqual(sent.project, root)
        XCTAssertEqual(sent.readableFolder, root)
        let away = try XCTUnwrap(host.store.create(title: "Outside", scope: outside.path))
        host.ask(away, question: "What is there?")
        try await expectEventually { host.store.asking == nil }
        XCTAssertEqual(spy.seen.last?.readableFolder, outside)
        XCTAssertEqual(spy.seen.last?.extraReadableFolders, [root])

        let silent = DiscussionsHost(project: project, showTab: {}, runner: { _, _, _ in
            try CLICompletion.Result(text: "  \n", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        defer { silent.close() }
        silent.projectOpened(root)
        silent.ask(slug, question: "Anything?")
        try await expectEventually { silent.store.asking == nil }
        XCTAssertEqual(silent.store.lastError, "The assistant gave no answer.")
        XCTAssertEqual(silent.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        let broken = DiscussionsHost(project: project, showTab: {}, runner: { _, _, _ in
            throw NSError(domain: "assistant", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        })
        defer { broken.close() }
        broken.projectOpened(root)
        broken.ask(slug, question: "Anything?")
        try await expectEventually { broken.store.asking == nil }
        XCTAssertEqual(broken.store.lastError, "boom")
        XCTAssertNil(broken.store.live)

        let stopSpy = DiscussionRunnerSpy()
        let lingering: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = { request, delta, _ in
            stopSpy.record(request)
            delta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { stopSpy.recordCancellation(); throw error }
            return try CLICompletion.Result(text: "late", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        let stopping = DiscussionsHost(project: project, showTab: {}, runner: lingering)
        defer { stopping.close() }
        stopping.projectOpened(root)
        stopping.ask(slug, question: "Long one")
        try await expectEventually { stopping.store.live?.text == "Partial " }
        stopping.stop()
        try await expectEventually { stopping.store.asking == nil }
        XCTAssertEqual(stopSpy.cancellationCount, 1)
        XCTAssertNil(stopping.store.live)
        XCTAssertNil(stopping.store.lastError)
        XCTAssertEqual(stopping.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        stopping.ask(slug, question: "Again")
        try await expectEventually { stopping.store.live?.text == "Partial " }
        stopping.projectClosed()
        try await expectEventually { stopSpy.cancellationCount == 2 }
        XCTAssertNil(stopping.store.root)
        XCTAssertNil(stopping.store.asking)
        stopping.projectOpened(root)
        XCTAssertEqual(stopping.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        let closeSpy = DiscussionRunnerSpy()
        let closing = DiscussionsHost(project: project, showTab: {}, runner: { request, delta, _ in
            closeSpy.record(request)
            delta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { closeSpy.recordCancellation(); throw error }
            return try CLICompletion.Result(text: "late", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        closing.projectOpened(root)
        closing.ask(slug, question: "Long one")
        try await expectEventually { closing.store.live?.text == "Partial " }
        closing.close()
        try await expectEventually { closeSpy.cancellationCount == 1 }

        let file = root.appendingPathComponent("Sources/App.swift")
        host.discuss(about: file)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(host.store.selected?.scope, "Sources/App.swift")
        XCTAssertEqual(host.store.selected?.title, "App.swift")
        let count = host.store.discussions.count
        host.discuss(about: file)
        XCTAssertEqual(host.store.discussions.count, count)
        host.discuss(about: outside)
        XCTAssertEqual(host.store.selected?.scope, outside.path)
        project.fileTree.rootNode = nil
        let countOpened = opened
        host.discuss(about: file)
        XCTAssertEqual(opened, countOpened)
    }

    @MainActor func testRealDeploymentHostApprovalAndAssistantRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deployment-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let assistant = RoutingAssistant()
        let host = DeploymentsHost(project: window.project, assistants: assistant, showTab: {})
        defer { host.close() }
        host.analyzeWithAI()
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertTrue(assistant.prompts[0].submit)
        XCTAssertTrue(assistant.prompts[0].text.contains(root.lastPathComponent))
        assistant.assistantIsBusy = true
        host.analyzeWithAI()
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertEqual(host.store.lastError, "The assistant is still working.")
        host.projectOpened(root)
        host.store.add(DeploymentEnvironment(id: "prod", name: "Production", kind: .local))
        host.store.lastError = nil
        let prod = try XCTUnwrap(host.store.selected)
        host.askAssistant(prod, question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertEqual(host.store.lastError, "The assistant is still working.")
        assistant.assistantIsBusy = false
        host.askAssistant("missing", question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 1)
        host.askAssistant(prod, question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 2)
        XCTAssertTrue(assistant.prompts[1].text.contains("Is it up?"))

        let polling = PollingScheduler()
        host.store.polling = polling
        host.store.autoRefresh = true
        XCTAssertEqual(polling.keys.count, 1)
        let command = "touch \(root.path)/never.txt"
        let asked = Task { await host.store.run(command, on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.store.approval)
        XCTAssertEqual(host.store.tasks.activeCount, 1)
        host.store.answer(false)
        guard case .denied = await asked.value else { return XCTFail("The refused command was not denied") }
        XCTAssertEqual(host.store.tasks.activeCount, 0)
        let closing = Task { await host.store.run(command, on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.store.approval)
        host.close()
        guard case .denied = await closing.value else { return XCTFail("Closing did not deny the pending command") }
        XCTAssertNil(host.store.approval)
        XCTAssertEqual(host.store.tasks.activeCount, 0)
        XCTAssertTrue(polling.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("never.txt").path))
    }

    @MainActor func testRealStudioWindowServices() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("studio-services-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = root.appendingPathComponent("note.md")
        let stray = outside.appendingPathComponent("stray.md")
        try "Note".write(to: note, atomically: true, encoding: .utf8)
        try "Stray".write(to: stray, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.project.releaseDatabase(); window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let opened = try await window.project.openDatabase(at: root)
        XCTAssertTrue(opened)
        weak var database = window.project.database
        XCTAssertNotNil(database)
        window.toolTabs.open(.uiStudio)
        guard case .uiStudio(let studio)? = window.tabs.activeTab?.kind else { return XCTFail("UI Studio was not opened") }
        await window.tabs.openTextFile(note)
        await window.tabs.openTextFile(stray)
        XCTAssertTrue(studio.editorBuffers().isEmpty)
        for tab in window.tabs.openTabs where tab.isFileBacked {
            window.tabs.updateTabContent("Edited", documentID: tab.id)
        }
        XCTAssertEqual(studio.editorBuffers(), ["note.md": "Edited"])
        window.project.fileTree.rootNode = FileNode(url: outside, isDirectory: true)
        XCTAssertEqual(studio.editorBuffers(), ["note.md": "Edited"], "The session retains its original root")
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        studio.recordUsage(10, 20, 0.5)
        studio.recordUsage(1, 2, 0.25)
        var usage = await window.project.database?.getUsageStats()
        for _ in 0..<200 where (usage?.totalJobs ?? 0) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
            usage = await window.project.database?.getUsageStats()
        }
        let stats = try XCTUnwrap(usage)
        XCTAssertEqual(stats.totalJobs, 2)
        XCTAssertEqual(stats.totalInputTokens, 11)
        XCTAssertEqual(stats.totalOutputTokens, 22)
        XCTAssertEqual(stats.totalCostCents, 75, accuracy: 0.001)
        studio.openFile(note)
        for _ in 0..<200 where window.tabs.activeTab?.url != note {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(window.tabs.activeTab?.url, note)
        studio.windowServices?.studioDidExportFeature("feature-one")
        XCTAssertEqual(window.layout.issuesFeature, "feature-one")
        XCTAssertTrue(studio.featureStore() === window.flow.features)
        await studio.close()
        window.toolTabs.uiStudio.close()
        window.project.releaseDatabase()
        for _ in 0..<200 where database != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(database, "The temporary database must close before its folder is removed")
    }

    @MainActor func testRealPrototypeStudioRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prototype-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.toolTabs.prototypes
        XCTAssertTrue(host.saved().isEmpty)
        let manifest = PrototypeFiles.Manifest(title: "Support Desk", slug: "support-desk", brief: "", sources: [], version: 3,
                                               approved: true, history: [.init(version: 3, instruction: "", summary: "", date: Date())])
        try PrototypeFiles.saveManifest(manifest, in: PrototypeFiles.folder(root: root, slug: manifest.slug))
        XCTAssertEqual(host.saved().map(\.label), ["Support Desk · v3 · approved"])

        host.openCreator(mode: .requirements)
        XCTAssertTrue(window.requests.showPrototypeCreator)
        XCTAssertEqual(window.requests.prototypeCreatorMode, .requirements)
        window.requests.showPrototypeCreator = false
        host.openCreator(mode: .code)
        XCTAssertFalse(window.requests.showPrototypeCreator)
        let studios = window.tabs.openTabs.filter { if case .uiStudio = $0.kind { return true }; return false }
        XCTAssertEqual(studios.count, 1)
        guard let studioTab = studios.first, case .uiStudio(let studio) = studioTab.kind else {
            return XCTFail("UI Studio was not opened")
        }

        host.openSaved(manifest.slug)
        guard case .prototype? = window.tabs.activeTab?.kind else { return XCTFail("Saved prototype was not opened") }
        let count = window.tabs.openTabs.count
        window.tabs.activeTabIndex = 0
        host.openSaved(manifest.slug)
        XCTAssertEqual(window.tabs.openTabs.count, count)
        guard case .prototype? = window.tabs.activeTab?.kind else { return XCTFail("Saved prototype was not selected") }

        host.create(title: "Admin", brief: "An admin console", sources: ["docs"])
        guard case .prototype(let created)? = window.tabs.activeTab?.kind else { return XCTFail("New prototype was not opened") }
        XCTAssertEqual(created.manifest.title, "Admin")
        XCTAssertEqual(created.manifest.brief, "An admin console")
        XCTAssertEqual(created.manifest.sources, ["docs"])
        host.create(title: "From code", brief: "", sources: [], mode: .code)
        XCTAssertEqual(window.tabs.openTabs.filter { if case .prototype = $0.kind { return true }; return false }.count, 2)
        await studio.close()
    }

}
