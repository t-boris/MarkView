import Foundation
import AppKit
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

final class BrowserFixtureServer {
    let port: Int
    private let source: DispatchSourceRead

    init() throws {
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
        port = Int(UInt16(bigEndian: address.sin_port))
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setEventHandler {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let response = Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
            _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            Darwin.close(client)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
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
        window.chrome.showCenter = false
        let fourth = browser.open(nil, activate: false)
        XCTAssertEqual(fourth.agentName, "T3")
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertFalse(window.chrome.showCenter)
        browser.browserSession(first, openInNewTab: try XCTUnwrap(URL(string: "http://127.0.0.1:1/new")))
        XCTAssertEqual(browser.sessions.count, 5)
        XCTAssertEqual(browser.sessions.last?.url?.path, "/new")
        XCTAssertEqual(window.tabs.activeTabIndex, 4)
    }

    @MainActor func testRealBrowserHostLocalHTMLRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-html-" + UUID().uuidString, isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = site.appendingPathComponent("index.html")
        try "<html><head><title>Original fixture</title></head><body>Isolated fixture</body></html>".write(to: page, atomically: true, encoding: .utf8)
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
        for _ in 0..<500 where first.webView.title != "Original fixture" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(first.webView.title, "Original fixture")
        _ = try await first.webView.evaluateJavaScript("document.title = 'Changed fixture'")
        for _ in 0..<500 where first.webView.title != "Changed fixture" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(first.webView.title, "Changed fixture")
        browser.open(nil)
        XCTAssertEqual(window.tabs.activeTabIndex, 1)
        browser.openHTML(page)
        XCTAssertEqual(browser.sessions.count, 2)
        XCTAssertTrue(browser.sessions.first === first)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertEqual(first.url?.standardizedFileURL, page.standardizedFileURL)
        for _ in 0..<500 where first.webView.title != "Original fixture" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(first.webView.title, "Original fixture", "Reopening the file reloads the existing tab")
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
        XCTAssertTrue(empty.tabs.openTabs[0].url.path.hasPrefix(FileManager.default.temporaryDirectory.path))

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
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-agent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings.standard
        let agent = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldBrowserSetting = settings.stored(Setting.openTerminalLinksInApp)
        let oldAgentSetting = settings.stored(agent.agentToolsKey)
        let oldAgentSel = settings.stored(Setting.mcpServiceSelections(agent.rawValue))
        let oldAgentMig = settings.stored(Setting.mcpServiceMigrated(agent.rawValue))
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        settings.set(true, for: Setting.openTerminalLinksInApp)
        settings.set(true, for: agent.agentToolsKey)
        settings.set(true, for: Setting.mcpServiceMigrated(agent.rawValue))
        AgentMCPServices.saveSelections(AgentMCPSelectionRecord(selections: [
            AgentMCPServer.markviewName: true,
            AgentMCPServer.markviewBrowserName: true,
        ]), for: agent)
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
            settings.set(oldBrowserSetting, for: Setting.openTerminalLinksInApp)
            settings.set(oldAgentSetting, for: agent.agentToolsKey)
            settings.set(oldAgentSel, for: Setting.mcpServiceSelections(agent.rawValue))
            settings.set(oldAgentMig, for: Setting.mcpServiceMigrated(agent.rawValue))
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
        // AC1: Starting from Welcome (-1), browser_open_tab opens in the background and keeps Welcome selected.
        XCTAssertEqual(window.tabs.activeTabIndex, -1)
        window.layout.workspaceArea = .work
        window.chrome.showCenter = false
        let opened = await call("browser_open_tab", ["name": "Jira"])
        XCTAssertFalse(opened.isError)
        XCTAssertTrue(opened.text.contains("Opened tab Jira"))
        XCTAssertEqual(window.tabs.activeTabIndex, -1, "Opening the first browser tab must keep Welcome selected")
        XCTAssertEqual(window.layout.workspaceArea, .work)
        XCTAssertFalse(window.chrome.showCenter)
        let first = try XCTUnwrap(host.sessions.first)
        XCTAssertEqual(first.agentName, "Jira")
        XCTAssertNotNil(first.agentLastUsed)
        let list = await call("browser_tabs")
        XCTAssertTrue(list.text.contains("Jira"))
        XCTAssertFalse(list.text.contains("[active]"), "Welcome is active, so no browser tab is marked [active]")
        first.webView.loadHTMLString("<title>Isolated agent fixture</title><p>Host routing works</p>", baseURL: nil)
        for _ in 0..<500 where first.webView.title != "Isolated agent fixture" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(first.webView.title, "Isolated agent fixture")
        let second = await call("browser_open_tab")
        XCTAssertTrue(second.text.contains("Opened tab T1"))
        XCTAssertEqual(host.sessions.map(\.agentName), ["Jira", "T1"])
        XCTAssertEqual(window.tabs.activeTabIndex, -1, "Opening a second tab must not steal tab selection")
        // User manually selects T1; browser_tabs must reflect the user's actual active tab.
        window.tabs.activeTabIndex = 1
        let activeList = await call("browser_tabs")
        XCTAssertTrue(activeList.text.contains("T1:") && activeList.text.contains("[active]"))
        XCTAssertFalse(activeList.text.split(separator: "\n").first { $0.contains("Jira:") }?.contains("[active]") == true)
        // Inspecting Jira in the background must keep T1 selected and preserve workspace area and panel visibility.
        window.layout.workspaceArea = .work
        window.chrome.showCenter = false
        let snapshot = await call("browser_snapshot", ["tab": "Jira"])
        XCTAssertFalse(snapshot.isError, snapshot.text)
        XCTAssertTrue(snapshot.text.contains("Isolated agent fixture"))
        XCTAssertTrue(snapshot.text.contains("Host routing works"))
        XCTAssertEqual(window.tabs.activeTabIndex, 1, "Background snapshot must not switch the user's active tab")
        XCTAssertEqual(window.layout.workspaceArea, .work)
        XCTAssertFalse(window.chrome.showCenter)
        XCTAssertNotNil(first.agentLastUsed)
        let missing = await call("browser_click", ["tab": "Nowhere"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No single browser tab matches"))
        first.agentStopped = true
        let stopped = await call("browser_click", ["tab": "Jira"])
        XCTAssertTrue(stopped.isError)
        XCTAssertTrue(stopped.text.contains("stopped agent control"))
        first.agentStopped = false
        let allowedAgain = await call("browser_snapshot", ["tab": "Jira"])
        XCTAssertFalse(allowedAgain.isError, "Allowing control again must let agent calls resume")
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
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-server-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserFixtureServer()
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        IFS= read -r line || exit 1
        printf '%s' "$line" > received.txt
        IFS= read -r line || exit 1
        printf 'Local: http://localhost:\(server.port)/\\n'
        printf 'emitted' > emitted.txt
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
            withExtendedLifetime(server) {}
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
        terminal.write("emit\r")
        let emitted = root.appendingPathComponent("emitted.txt")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: emitted.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: emitted.path))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertNil(session.url, "Output arriving after the browser closes must not load a page")
        if case .starting = session.preview {} else { XCTFail("Closing the host must not report a server timeout") }
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertFalse(terminal.isRunning)
    }

    @MainActor func testRealBrowserHostPreviewOccupiedAndReusableServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-listener-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserFixtureServer()
        let port = server.port
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
        withExtendedLifetime(server) {}
    }

    @MainActor func testRealBrowserHostReusesRememberedPreviewTerminal() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-reuse-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldSocketDirectory = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        setenv("MARKVIEW_SOCKET_DIR", root.path, 1)
        defer {
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
        let existing = window.openTerminal(in: root, startupCommand: "unused-fixture-command", activate: false)
        window.terminals.rememberPreviewTerminal(existing, forApp: root.standardizedFileURL.path)
        let browser = window.browser
        let session = browser.open(nil)
        let target = WebAppTarget(folder: root, label: "fixture", command: "unused-fixture-command", ports: [], reuseRunningServer: true)
        browser.browserSession(session, startWebApp: target)
        for _ in 0..<500 {
            if session.previewTerminalID != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.previewTerminalID, existing.id)
        XCTAssertFalse(existing.isRunning)
        XCTAssertEqual(window.tabs.openTabs.count, 2)
        if case .starting(let found, started: true) = session.preview {
            XCTAssertEqual(found, target)
        } else {
            XCTFail("The existing terminal must be watched for its server")
        }
        browser.close()
    }

    @MainActor func testRealBrowserHostUsesServerAddressPrintedByTerminal() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-output-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try BrowserFixtureServer()
        let shell = root.appendingPathComponent("fixture-shell")
        let shellSource = """
        #!/bin/sh
        printf 'fixture ready\\n'
        IFS= read -r line || exit 1
        printf 'Local: http://localhost:\(server.port)/\\n'
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
        defer {
            AgentToolServer.unregister(browser.controlID)
            window.composition.close()
            if AgentToolServer.socketPath?.hasPrefix(root.path + "/") == true { AgentToolServer.shutdown() }
            withExtendedLifetime(server) {}
        }
        let session = browser.open(nil)
        let target = WebAppTarget(folder: root, label: "fixture", command: "fixture-command", ports: [], reuseRunningServer: false)
        browser.browserSession(session, startWebApp: target)
        for _ in 0..<800 {
            if session.url?.port == server.port { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.url?.port, server.port)
        XCTAssertNil(session.preview)
        let terminalID = try XCTUnwrap(session.previewTerminalID)
        let terminal = try XCTUnwrap(window.terminals.tabTerminal(terminalID))
        let pid = terminal.shellPID
        XCTAssertGreaterThan(pid, 0)
        browser.close()
        if let reap = terminal.terminate() { await reap.value }
        XCTAssertEqual(kill(pid, 0), -1)
    }

    /// AC1, AC2, AC3, AC4 (foreground errors): Background browser tools interact with named tabs while
    /// preserving active tab selection, workspace area, panel visibility, and keyboard focus (even when
    /// the targeted browser tab is mounted in the same window beside the user's focused text input).
    @MainActor func testBackgroundAutomationPreservesFocusAndExplainsForegroundOps() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-bg-focus-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pageURL = root.appendingPathComponent("bg-app.html")
        try """
        <!doctype html><html><head><title>BG App</title></head><body>
          <input id="note" type="text" placeholder="Note">
          <button id="apply" onclick="document.getElementById('out').textContent='Applied:' + document.getElementById('note').value">Apply</button>
          <input id="picker" type="file">
          <p id="out">Waiting</p>
        </body></html>
        """.write(to: pageURL, atomically: true, encoding: .utf8)

        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.browser
        let browserTabs = BrowserAgentTabs(
            tabs: { [weak host] in host?.sessions ?? [] },
            active: { [weak window] in
                guard let window, window.tabs.openTabs.indices.contains(window.tabs.activeTabIndex),
                      case .browser(let s) = window.tabs.openTabs[window.tabs.activeTabIndex].kind else { return nil }
                return s
            },
            open: { [weak host] url, name in
                guard let host else { return BrowserSession(url: url, prompts: NoPrompts()) }
                let session = host.open(url, activate: false)
                if let name { session.agentName = name }
                return session
            })
        defer { window.composition.close() }

        // User has a document tab open and focused in a real NSWindow text field (simulating Copilot/editor typing).
        let docURL = root.appendingPathComponent("README.md")
        try "# Doc\n".write(to: docURL, atomically: true, encoding: .utf8)
        window.tabs.appendTab(OpenTab(url: docURL, content: "# Doc\n", originalContent: "# Doc\n"), activate: true)
        window.layout.workspaceArea = .work
        window.chrome.showCenter = false

        let nsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        nsWindow.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let userInput = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 24))
        container.addSubview(userInput)
        nsWindow.contentView = container
        nsWindow.makeFirstResponder(userInput)
        let editorResponder = nsWindow.firstResponder
        defer { nsWindow.close() }

        // AC1: open_tab with URL keeps document tab selected, layout/chrome unchanged, and focus untouched.
        let opened = await browserTabs.run("browser_open_tab", ["url": pageURL.absoluteString, "name": "WorkBg"])
        XCTAssertFalse(opened.isError, opened.text)
        XCTAssertTrue(opened.text.contains("WorkBg"))
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertEqual(window.layout.workspaceArea, .work)
        XCTAssertFalse(window.chrome.showCenter)
        XCTAssertTrue(nsWindow.firstResponder === editorResponder)

        let bgSession = try XCTUnwrap(host.sessions.first { $0.agentName == "WorkBg" })
        for _ in 0..<500 where bgSession.webView.title != "BG App" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // AC2: snapshot, type, click, press_key work in unmounted background tab with full visible text and elements.
        let snap = await browserTabs.run("browser_snapshot", ["tab": "WorkBg"])
        XCTAssertFalse(snap.isError, snap.text)
        XCTAssertTrue(snap.text.contains("BG App"))
        XCTAssertTrue(snap.text.contains("Waiting"), "Unmounted background tab must report visible text")
        XCTAssertTrue(snap.text.contains("Apply"), "Unmounted background tab must report interactive elements")

        let typed = await browserTabs.run("browser_type", ["tab": "WorkBg", "selector": "#note", "value": "hello"])
        XCTAssertFalse(typed.isError, typed.text)
        let clicked = await browserTabs.run("browser_click", ["tab": "WorkBg", "selector": "#apply"])
        XCTAssertFalse(clicked.isError, clicked.text)
        let afterSnap = await browserTabs.run("browser_snapshot", ["tab": "WorkBg"])
        XCTAssertTrue(afterSnap.text.contains("Applied:hello"), afterSnap.text)

        // AC4: foreground-only screenshot & file input return actionable guidance without changing tab or focus.
        let shot = await browserTabs.run("browser_screenshot", ["tab": "WorkBg"])
        XCTAssertTrue(shot.isError)
        XCTAssertTrue(shot.text.contains("WorkBg") && shot.text.contains("Select tab WorkBg"), shot.text)
        let fileClick = await browserTabs.run("browser_click", ["tab": "WorkBg", "selector": "#picker"])
        XCTAssertTrue(fileClick.isError)
        XCTAssertTrue(fileClick.text.contains("WorkBg") && fileClick.text.contains("manually"), fileClick.text)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertTrue(nsWindow.firstResponder === editorResponder)

        // AC2/AC3: Even when WorkBg IS mounted in the same window alongside the user's focused input (e.g. Copilot),
        // background browser_click/browser_type/browser_press_key MUST NOT steal firstResponder.
        bgSession.webView.frame = NSRect(x: 20, y: 80, width: 760, height: 480)
        container.addSubview(bgSession.webView)
        nsWindow.makeFirstResponder(userInput)
        let focusedBefore = nsWindow.firstResponder
        _ = await browserTabs.run("browser_type", ["tab": "WorkBg", "selector": "#note", "value": "mounted"])
        _ = await browserTabs.run("browser_click", ["tab": "WorkBg", "selector": "#apply"])
        _ = await browserTabs.run("browser_press_key", ["tab": "WorkBg", "key": "Tab"])
        XCTAssertTrue(nsWindow.firstResponder === focusedBefore, "Automated actions on a visible tab must not steal keyboard focus: \(type(of: focusedBefore as Any)) -> \(type(of: nsWindow.firstResponder as Any))")

        // Pending tool call never overrides a later user tab selection.
        let waitTask = Task { await browserTabs.run("browser_wait_for", ["tab": "WorkBg", "timeout_ms": 300]) }
        try await Task.sleep(nanoseconds: 50_000_000)
        window.tabs.activeTabIndex = 0
        _ = await waitTask.value
        XCTAssertEqual(window.tabs.activeTabIndex, 0, "Completing a pending tool call must preserve the user's later tab selection")
    }

    /// AC4 + DEC-001: A delayed new-tab request caused by an automated page action opens in the background
    /// even after the initiating tool returns and the user selects the originating tab, preserving selection and focus.
    @MainActor func testDelayedAutomatedNewTabOpensInBackgroundAfterUserSelectsOriginatingTab() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-bg-delayed-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("delayed-target.html")
        try "<!doctype html><html><head><title>Delayed Destination</title></head><body>Opened later</body></html>".write(to: targetURL, atomically: true, encoding: .utf8)
        let originURL = root.appendingPathComponent("origin.html")
        try """
        <!doctype html><html><head><title>Origin Page</title></head><body>
          <button id="delayed-open">Open Delayed</button>
          <script>
            document.getElementById('delayed-open').addEventListener('click', function () {
              setTimeout(function () { window.open('\(targetURL.absoluteString)', '_blank'); }, 450);
            });
          </script>
        </body></html>
        """.write(to: originURL, atomically: true, encoding: .utf8)

        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.browser
        let browserTabs = BrowserAgentTabs(
            tabs: { [weak host] in host?.sessions ?? [] },
            active: { [weak window] in
                guard let window, window.tabs.openTabs.indices.contains(window.tabs.activeTabIndex),
                      case .browser(let s) = window.tabs.openTabs[window.tabs.activeTabIndex].kind else { return nil }
                return s
            },
            open: { [weak host] url, name in
                guard let host else { return BrowserSession(url: url, prompts: NoPrompts()) }
                let session = host.open(url, activate: false)
                if let name { session.agentName = name }
                return session
            })
        defer { window.composition.close() }

        let opened = await browserTabs.run("browser_open_tab", ["url": originURL.absoluteString, "name": "Origin"])
        XCTAssertFalse(opened.isError, opened.text)
        let origin = try XCTUnwrap(host.sessions.first)
        for _ in 0..<500 where origin.webView.title != "Origin Page" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Mount originating tab alongside a focused input and fire the automated click.
        let nsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        nsWindow.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let userInput = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 24))
        origin.webView.frame = NSRect(x: 20, y: 60, width: 760, height: 500)
        container.addSubview(userInput)
        container.addSubview(origin.webView)
        nsWindow.contentView = container
        nsWindow.makeFirstResponder(userInput)
        let focusedBefore = nsWindow.firstResponder
        defer { nsWindow.close() }

        // User selects the originating tab BEFORE the delayed automated new-tab request arrives.
        window.tabs.activeTabIndex = 0
        let clickReply = await browserTabs.run("browser_click", ["tab": "Origin", "selector": "#delayed-open"])
        XCTAssertFalse(clickReply.isError, clickReply.text)
        // Tool has returned; ensure the user's originating tab is still selected and userInput stays focused.
        window.tabs.activeTabIndex = 0
        XCTAssertTrue(nsWindow.firstResponder === focusedBefore, "after click: \(type(of: focusedBefore as Any)) -> \(type(of: nsWindow.firstResponder as Any))")

        for _ in 0..<300 where host.sessions.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(host.sessions.count, 2, "Delayed automated window.open must create a new tab")
        XCTAssertEqual(host.sessions.last?.url?.lastPathComponent, "delayed-target.html")
        XCTAssertEqual(window.tabs.activeTabIndex, 0, "Delayed automated new tab must open in the background even after the tool returns and the user selected the originating tab")
        XCTAssertTrue(nsWindow.firstResponder === focusedBefore, "Delayed automated new tab must preserve keyboard focus")
    }

    /// AC6 + DEC-001 (separate test): After automation has used a page, a subsequent manual click on the same page
    /// that opens a new tab follows ordinary foreground browsing behavior and clears agentControlled.
    @MainActor func testManualClickOnSamePageOpensNewTabInForeground() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-bg-manual-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manualTargetURL = root.appendingPathComponent("manual-target.html")
        try "<!doctype html><html><head><title>Manual Destination</title></head><body>Opened manually</body></html>".write(to: manualTargetURL, atomically: true, encoding: .utf8)
        let originURL = root.appendingPathComponent("manual-origin.html")
        try """
        <!doctype html><html><head><title>Manual Origin</title></head><body style="margin:0;padding:0;">
          <button id="auto-noop" onclick="document.body.dataset.auto='1'">Auto</button>
          <a id="manual-link" href="\(manualTargetURL.absoluteString)" target="_blank" style="display:block;width:300px;height:120px;background:#ccc;">Open Manual Tab</a>
        </body></html>
        """.write(to: originURL, atomically: true, encoding: .utf8)

        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.browser
        let browserTabs = BrowserAgentTabs(
            tabs: { [weak host] in host?.sessions ?? [] },
            active: { [weak window] in
                guard let window, window.tabs.openTabs.indices.contains(window.tabs.activeTabIndex),
                      case .browser(let s) = window.tabs.openTabs[window.tabs.activeTabIndex].kind else { return nil }
                return s
            },
            open: { [weak host] url, name in
                guard let host else { return BrowserSession(url: url, prompts: NoPrompts()) }
                let session = host.open(url, activate: false)
                if let name { session.agentName = name }
                return session
            })
        defer { window.composition.close() }

        _ = await browserTabs.run("browser_open_tab", ["url": originURL.absoluteString, "name": "SharedTab"])
        let origin = try XCTUnwrap(host.sessions.first)
        for _ in 0..<500 where origin.webView.title != "Manual Origin" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // First, automation runs on this page.
        let autoClick = await browserTabs.run("browser_click", ["tab": "SharedTab", "selector": "#auto-noop"])
        XCTAssertFalse(autoClick.isError, autoClick.text)
        XCTAssertTrue(origin.agentControlled)

        // Now the user selects the tab and manually clicks the target=_blank link on the same page.
        window.tabs.activeTabIndex = 0
        let nsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        nsWindow.isReleasedWhenClosed = false
        origin.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        nsWindow.contentView = origin.webView
        defer { nsWindow.close() }

        let rawRect = try await origin.webView.callAsyncJavaScript(
            "const r = document.getElementById('manual-link').getBoundingClientRect(); return JSON.stringify({x: r.left + r.width/2, y: r.top + r.height/2});",
            arguments: [:], in: nil, contentWorld: .page) as? String
        let rectJSON = try XCTUnwrap(rawRect)
        let coords = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rectJSON.utf8)) as? [String: Double])
        let cssPoint = CGPoint(x: coords["x"] ?? 100, y: coords["y"] ?? 60)
        let localPoint = CGPoint(x: cssPoint.x, y: origin.webView.isFlipped ? cssPoint.y : origin.webView.bounds.height - cssPoint.y)
        let winPoint = origin.webView.convert(localPoint, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: winPoint, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: winPoint, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        origin.webView.mouseDown(with: down)
        origin.webView.mouseUp(with: up)

        for _ in 0..<300 where host.sessions.count < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(host.sessions.count, 2, "Manual click must open the new tab")
        XCTAssertEqual(host.sessions.last?.url?.lastPathComponent, "manual-target.html")
        XCTAssertEqual(window.tabs.activeTabIndex, 1, "Subsequent manual click on the same page must open in the foreground")
        XCTAssertFalse(origin.agentControlled, "Manual interaction restores ordinary browsing mode on an automation-created tab")
    }

    /// AC5 + DEC-002: Automated sign-in popups stay hidden while preserving window.opener; the tool names the
    /// originating tab and explains how to open the popup; explicit open shows it; unavailable popup explains manual retry.
    @MainActor func testBackgroundSignInPopupStaysHiddenUntilUserOpensIt() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-bg-popup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originURL = root.appendingPathComponent("signin.html")
        try """
        <!doctype html><html><head><title>Sign In Host</title></head><body>
          <button id="sso">Sign in with SSO</button>
          <p id="status">signed-out</p>
          <script>
            window.addEventListener('message', function (e) {
              document.getElementById('status').textContent = 'msg:' + e.data;
            });
            document.getElementById('sso').addEventListener('click', function () {
              var p = window.open('about:blank', 'sso-popup-' + Date.now(), 'width=480,height=600');
              if (p) {
                p.document.write('<title>SSO Provider</title><p>Enter credentials</p>');
                p.document.close();
              }
            });
          </script>
        </body></html>
        """.write(to: originURL, atomically: true, encoding: .utf8)

        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.browser
        let browserTabs = BrowserAgentTabs(
            tabs: { [weak host] in host?.sessions ?? [] },
            active: { [weak window] in
                guard let window, window.tabs.openTabs.indices.contains(window.tabs.activeTabIndex),
                      case .browser(let s) = window.tabs.openTabs[window.tabs.activeTabIndex].kind else { return nil }
                return s
            },
            open: { [weak host] url, name in
                guard let host else { return BrowserSession(url: url, prompts: NoPrompts()) }
                let session = host.open(url, activate: false)
                if let name { session.agentName = name }
                return session
            })
        defer { window.composition.close() }

        _ = await browserTabs.run("browser_open_tab", ["url": originURL.absoluteString, "name": "AuthTab"])
        let authSession = try XCTUnwrap(host.sessions.first)
        for _ in 0..<500 where authSession.webView.title != "Sign In Host" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Trigger sign-in popup via automated click in the background.
        let reply = await browserTabs.run("browser_click", ["tab": "AuthTab", "selector": "#sso"])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("AuthTab"), "Tool reply must name the originating tab: \(reply.text)")
        XCTAssertTrue(reply.text.contains("Open Sign-In Window"), "Tool reply must explain the explicit open action: \(reply.text)")
        XCTAssertEqual(authSession.pendingPopups.count, 1)
        XCTAssertTrue(authSession.pendingPopups[0].isAvailable)
        XCTAssertEqual(authSession.openPopupCount, 1)
        XCTAssertEqual(authSession.visiblePopupCount, 0, "Sign-in popup must stay hidden until the user explicitly opens it")
        let tabList = await browserTabs.run("browser_tabs", [:])
        XCTAssertTrue(tabList.text.contains("[pending sign-in window]"), tabList.text)

        // Verify window.opener connection is preserved while hidden.
        let firstPopupID = authSession.pendingPopups[0].id
        let livePopup = try XCTUnwrap(authSession.livePopup(id: firstPopupID))
        _ = try await livePopup.webView.evaluateJavaScript("window.opener.postMessage('oauth-token-ok', '*');")
        for _ in 0..<200 {
            let status = (try? await authSession.webView.evaluateJavaScript("document.getElementById('status').textContent") as? String) ?? ""
            if status == "msg:oauth-token-ok" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let openerStatus = try await authSession.webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertEqual(openerStatus, "msg:oauth-token-ok", "Hidden popup must keep its window.opener link to the originating page")

        // Explicit user action opens the popup.
        XCTAssertTrue(authSession.openPendingPopup(firstPopupID))
        XCTAssertTrue(authSession.pendingPopups.isEmpty)
        XCTAssertTrue(livePopup.isVisible, "Explicit user action must display the pending sign-in popup")
        livePopup.close()

        // Second case: popup closes/becomes unavailable before user invokes the open action.
        _ = await browserTabs.run("browser_click", ["tab": "AuthTab", "selector": "#sso"])
        XCTAssertEqual(authSession.pendingPopups.count, 1)
        let secondPopupID = authSession.pendingPopups[0].id
        let secondPopup = try XCTUnwrap(authSession.livePopup(id: secondPopupID))
        secondPopup.close()
        XCTAssertEqual(authSession.pendingPopups.count, 1)
        XCTAssertFalse(authSession.pendingPopups[0].isAvailable, "Closed pending popup must be marked unavailable")
        XCTAssertFalse(authSession.openPendingPopup(secondPopupID))
        let notice = try XCTUnwrap(authSession.unavailablePopupNotice)
        XCTAssertTrue(notice.contains("no longer available") && notice.contains("manually"), notice)
    }

}
