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
        first.webView.loadHTMLString("<title>Isolated agent fixture</title><p>Host routing works</p>", baseURL: nil)
        for _ in 0..<500 where first.webView.title != "Isolated agent fixture" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(first.webView.title, "Isolated agent fixture")
        let second = await call("browser_open_tab")
        XCTAssertEqual(second.text, "Opened tab T1.")
        XCTAssertEqual(host.sessions.map(\.agentName), ["Jira", "T1"])
        XCTAssertEqual(window.tabs.activeTabIndex, 1)
        let snapshot = await call("browser_snapshot", ["tab": "Jira"])
        XCTAssertFalse(snapshot.isError, snapshot.text)
        XCTAssertTrue(snapshot.text.contains("Isolated agent fixture"))
        XCTAssertTrue(snapshot.text.contains("Host routing works"))
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertNotNil(first.agentLastUsed)
        let missing = await call("browser_click", ["tab": "Nowhere"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No single browser tab matches"))
        first.agentStopped = true
        let stopped = await call("browser_click", ["tab": "Jira"])
        XCTAssertTrue(stopped.isError)
        XCTAssertTrue(stopped.text.contains("stopped agent control"))
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

}
