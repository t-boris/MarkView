import AppKit
import MarkViewCore
import WebKit
import XCTest
@testable import MarkView

/// Exercise the shipping control runner and window registry in the isolated host.
final class ControlToolRunnerTests: XCTestCase {
    @MainActor
    func testRoutesControlRequestsToTheSelectedRealWorkspace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-control-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("first.json"))
        let second = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("second.json"))
        let firstWindow = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        firstWindow.title = "First test window"
        secondWindow.title = "Second test window"
        first.hostWindow = firstWindow
        second.hostWindow = secondWindow
        let firstID = UUID()
        let secondID = UUID()
        AgentToolServer.register(firstID, AgentToolWindow(workspace: { first }, root: { nil }))
        AgentToolServer.register(secondID, AgentToolWindow(workspace: { second }, root: { nil }))
        defer {
            AgentToolServer.unregister(firstID)
            AgentToolServer.unregister(secondID)
            first.windowWillClose()
            second.windowWillClose()
        }
        let caller = ControlToolRunner.Caller(pids: [], folder: folder.path)
        let list = await ControlToolRunner.run("markview_windows", [:], caller: caller)
        XCTAssertFalse(list.isError)
        XCTAssertTrue(list.text.contains("First test window"))
        XCTAssertTrue(list.text.contains("Second test window"))
        let chosen = try ControlToolRunner.window(["window": secondID.uuidString], caller: caller)
        XCTAssertEqual(chosen.id, secondID)
        XCTAssertTrue((chosen.workspace as AnyObject) === second)
        let ambiguous = await ControlToolRunner.run("markview_agents", [:], caller: caller)
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("Several windows"))
        let missing = await ControlToolRunner.run("markview_agents", ["window": "missing-window"], caller: caller)
        XCTAssertTrue(missing.isError)
    }
    func testStaleSocketCleanupKeepsLiveAndUnrelatedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-stale-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = folder.appendingPathComponent("mv-browser-2147483647.sock")
        let token = URL(fileURLWithPath: PrivateSocket.tokenPath(forSocket: stale.path))
        let live = folder.appendingPathComponent("mv-browser-\(ProcessInfo.processInfo.processIdentifier).sock")
        let unrelated = folder.appendingPathComponent("another.sock")
        for file in [stale, token, live, unrelated] { try Data().write(to: file) }
        AgentToolServer.removeStaleSockets(near: live.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: token.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

}


// Exercise the real app types, private socket and WebKit without touching user windows or website data.
/// One raw control request without the client's automatic token: what the server answers, nil when it closes silently.
private func rawControlReply(_ path: String, _ request: [String: Any]) -> BrowserAgentTools.Reply? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var address = PrivateSocket.address(path), let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard connected == 0, BrowserAgentTools.writeAll(fd, body + Data("\n".utf8)),
          let line = BrowserAgentTools.readLine(fd), let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
    return BrowserAgentTools.Reply(json: object)
}


final class RemoteBrowserHostTests: XCTestCase {
    @MainActor func testRemoteRelayAndControlSocket() async throws {
        let settings = Settings.standard
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let browserSetting = settings.stored(Setting.openTerminalLinksInApp)
        let claudeSetting = settings.stored(claude.agentToolsKey)
        let codexSetting = settings.stored(codex.agentToolsKey)
        let claudeSel = settings.stored(Setting.mcpServiceSelections(claude.rawValue))
        let codexSel = settings.stored(Setting.mcpServiceSelections(codex.rawValue))
        let claudeMig = settings.stored(Setting.mcpServiceMigrated(claude.rawValue))
        let codexMig = settings.stored(Setting.mcpServiceMigrated(codex.rawValue))
        defer {
            settings.set(browserSetting, for: Setting.openTerminalLinksInApp)
            settings.set(claudeSetting, for: claude.agentToolsKey)
            settings.set(codexSetting, for: codex.agentToolsKey)
            settings.set(claudeSel, for: Setting.mcpServiceSelections(claude.rawValue))
            settings.set(codexSel, for: Setting.mcpServiceSelections(codex.rawValue))
            settings.set(claudeMig, for: Setting.mcpServiceMigrated(claude.rawValue))
            settings.set(codexMig, for: Setting.mcpServiceMigrated(codex.rawValue))
        }
        settings.set(true, for: Setting.openTerminalLinksInApp)
        settings.set(true, for: claude.agentToolsKey)
        settings.set(true, for: codex.agentToolsKey)
        for tool in [claude, codex] {
            settings.set(true, for: Setting.mcpServiceMigrated(tool.rawValue))
            AgentMCPServices.saveSelections(AgentMCPSelectionRecord(selections: [
                AgentMCPServer.markviewName: true,
                AgentMCPServer.markviewBrowserName: true,
            ]), for: tool)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedWindow: URL?
        AgentToolServer.setWindowOpener { folder in requestedWindow = folder; return true }
        defer { AgentToolServer.setWindowOpener { _ in false } }
        XCTAssertTrue(AgentToolServer.openWindow(folder: root))
        XCTAssertEqual(requestedWindow, root, "The injected window opener works before any window is registered")
        let workspace = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent1.json"))
        let other = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent2.json"))
        workspace.terminals.workspaceRoot = root; other.terminals.workspaceRoot = root
        let session = BrowserSession(url: nil, dataStore: .nonPersistent(), prompts: QAPlayerPrompts())
        let unrelated = BrowserSession(url: nil, dataStore: .nonPersistent(), prompts: QAPlayerPrompts())
        defer { session.close(); unrelated.close(); workspace.windowWillClose(); other.windowWillClose() }
        let featureStore = FeatureStore()
        featureStore.setup(root: root)
        defer { featureStore.reset() }
        session.agentName = "WorkTab"; unrelated.agentName = "OtherWindow"
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
        workspace.hostWindow = window
        session.webView.loadHTMLString("<title>Relay fixture</title><button onclick=\"document.querySelector('p').textContent='clicked'\">Run</button><p>work page</p>", baseURL: URL(string: "http://localhost"))
        let id = UUID(), otherID = UUID()
        func registration(_ workspace: WorkspaceManager, _ tab: BrowserSession) -> AgentToolWindow {
            let tabs = BrowserAgentTabs(tabs: { [tab] }, active: { tab }, open: { _, _ in tab })
            return .init(workspace: { workspace }, root: { root }, features: { featureStore }, browser: { tool, args in await tabs.run(tool, args) })
        }
        AgentToolServer.register(id, registration(workspace, session))
        AgentToolServer.register(otherID, registration(other, unrelated))
        defer { AgentToolServer.unregister(id); AgentToolServer.unregister(otherID) }
        let endpoint = try await RemoteWorkspace(root: root, deviceID: "test-device", browserCall: { name, args in
            await RemoteBrowserRelay.perform(name, arguments: args, window: id, root: root, agent: codex)
        })
        func call(_ name: String, _ args: [String: RemoteJSON] = [:]) async -> RemoteJSON {
            await endpoint.call(id: UUID(), name: name, arguments: .object(args))
        }
        func text(_ reply: RemoteJSON) -> String { reply["content"].array?.first?["text"].string ?? "" }
        func check(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(condition, message, file: file, line: line) }
        let deadline = Date().addingTimeInterval(15)
        while session.webView.title != "Relay fixture", Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let tabs = await call("browser_tabs", ["project_folder": .string("/home/wrong-project")])
        check(text(tabs).contains("WorkTab") && !text(tabs).contains("OtherWindow"), "Remote discovery is bound to the connected window even with another window and misleading folder")
        let snapshot = await call("browser_snapshot")
        check(text(snapshot).contains("Relay fixture") && text(snapshot).contains("[e1]"), "Real WKWebView snapshot returns the open page and element refs")
        _ = await call("browser_click", ["tab": .string("WorkTab"), "ref": .string("e1")])
        let clicked = await call("browser_snapshot")
        check(text(clicked).contains("clicked"), "Remote click changes the work page")
        let question = "[QA-PACKAGE-20261111-212347-UTC] Здравствуйте! Я выбрал пакет „Праздник двух мастеров 20261111-01“. Подскажите, что нужно уточнить перед покупкой?"
        _ = try await session.webView.callAsyncJavaScript("""
            for (const [type, value] of [['textarea', question], ['textarea', 'x'.repeat(4100)], ['password', 'fixture-password-hidden']]) {
              const el = document.createElement(type === 'password' ? 'input' : 'textarea');
              if (type === 'password') el.type = type;
              el.value = value;
              document.body.appendChild(el);
            }
            """, arguments: ["question": question], in: nil, contentWorld: .page)
        let fields = text(await call("browser_snapshot"))
        check(fields.contains(question), "A 146-character QA chat draft is shown completely, not silently shortened to 60 characters")
        check(fields.contains("[value truncated: 4100 characters total]"), "Oversized field previews explicitly say they are truncated")
        check(!fields.contains("fixture-password-hidden"), "Full field previews still never expose password values")
        let image = await call("browser_screenshot")
        check(image["content"].array?.contains { $0["type"].string == "image" && $0["mimeType"].string == "image/png" && !($0["data"].string ?? "").isEmpty } == true, "Real page screenshot returns an MCP PNG image")
        let noArgs = await RemoteBrowserRelay.perform("browser_tabs", arguments: .null, window: id, root: root, agent: claude)
        check(text(noArgs).contains("WorkTab"), "MCP calls with omitted optional arguments work for Claude too")
        // AR-40: the control socket serves only a caller that holds the instance token. The blocking calls run off the
        // main actor, which the server's tool calls need.
        guard let controlSocket = AgentToolServer.socketPath else { fatalError("the control socket is not listening") }
        if let socketDirectory = ProcessInfo.processInfo.environment["MARKVIEW_SOCKET_DIR"] {
            XCTAssertEqual((controlSocket as NSString).deletingLastPathComponent, socketDirectory)
        }
        let controlToken = PrivateSocket.readToken(forSocket: controlSocket) ?? ""
        let tokenMode = (try? FileManager.default.attributesOfItem(atPath: PrivateSocket.tokenPath(forSocket: controlSocket))[.posixPermissions] as? NSNumber)?.intValue
        let socketMode = (try? FileManager.default.attributesOfItem(atPath: controlSocket)[.posixPermissions] as? NSNumber)?.intValue
        check(controlToken.count == 64 && tokenMode == 0o600 && socketMode == 0o600, "The control socket and its 256-bit token file are private to this user")
        let tabsRequest: [String: Any] = ["tool": "browser_tabs", "window": id.uuidString, "arguments": [String: Any]()]
        let controlReplies = await Task.detached { () -> [BrowserAgentTools.Reply?] in
            [rawControlReply(controlSocket, tabsRequest),
             rawControlReply(controlSocket, tabsRequest.merging(["token": "wrong"]) { $1 }),
             rawControlReply(controlSocket, tabsRequest.merging(["token": ""]) { $1 }),
             rawControlReply(controlSocket, tabsRequest.merging(["token": controlToken]) { $1 })]
        }.value
        check(controlReplies[0]?.isError == true && controlReplies[0]?.text.contains("authentication failed") == true
              && controlReplies[1]?.isError == true && controlReplies[2]?.isError == true
              && !(controlReplies.prefix(3).contains { $0?.text.contains("WorkTab") == true }),
              "A control request without the token, with a wrong one or an empty one is refused and runs no tool")
        check(controlReplies[3]?.isError == false && controlReplies[3]?.text.contains("WorkTab") == true, "A control request with the token is served")
        let spoofed: [String: Any] = ["tool": "browser_tabs", "token": controlToken, "cwd": root.path,
                                      "folderDeclared": true, "cwdTrusted": true, "pids": [Int(getpid())], "arguments": [String: Any]()]
        let spoofedReply = await Task.detached { rawControlReply(controlSocket, spoofed) }.value
        check(spoofedReply?.isError == true && !(spoofedReply?.text.contains("WorkTab") ?? false),
              "A forged folder and process ancestry cannot select a window")
        let pinned = tabsRequest.merging(["token": controlToken, "cwd": "/outside-the-window"]) { $1 }
        let pinnedReply = await Task.detached { rawControlReply(controlSocket, pinned) }.value
        check(pinnedReply?.isError == false && pinnedReply?.text.contains("WorkTab") == true,
              "A forged outside folder is ignored for a window-bound request")
        let legacyMismatch: [String: Any] = ["tool": "markview_list_features", "window": id.uuidString, "token": controlToken,
                                              "arguments": ["project_folder": "/outside-the-window"]]
        let mismatchReply = await Task.detached { rawControlReply(controlSocket, legacyMismatch) }.value
        check(mismatchReply?.isError == true && mismatchReply?.text.contains("Nothing was done") == true,
              "A legacy project folder outside a pinned window is refused before a project tool runs")
        let legacyMatch: [String: Any] = ["tool": "markview_list_features", "window": id.uuidString, "token": controlToken,
                                           "arguments": ["project_folder": root.path]]
        let matchReply = await Task.detached { rawControlReply(controlSocket, legacyMatch) }.value
        check(matchReply?.isError == false && matchReply?.text == "No features yet.",
              "A matching legacy project folder allows the selected project tool")
        let viaClient = await Task.detached { BrowserAgentTools.request(socket: controlSocket, payload: tabsRequest, timeout: 5) }.value
        check(viaClient.text.contains("WorkTab"), "The MCP client finds the token file by itself and is served")
        session.agentStopped = true
        let stopped = await call("browser_click", ["ref": .string("e1")])
        check(stopped["isError"].bool == true && text(stopped).contains("stopped"), "The user's stopped tab is respected")
        session.agentStopped = false
        let codexSelKey = Setting.mcpServiceSelections(codex.rawValue)
        let codexMigKey = Setting.mcpServiceMigrated(codex.rawValue)
        let oldCodexSel = Settings.standard.stored(codexSelKey)
        let oldCodexMig = Settings.standard.stored(codexMigKey)
        Settings.standard.set(true, for: codexMigKey)
        AgentMCPServices.saveSelections(AgentMCPSelectionRecord(selections: [BrowserAgentTools.serverName: false]), for: codex)
        let disabled = await call("browser_tabs")
        check(disabled["isError"].bool == true, "Per-agent browser opt-out is respected")
        Settings.standard.set(oldCodexSel, for: codexSelKey)
        Settings.standard.set(oldCodexMig, for: codexMigKey)
        settings.set(false, for: Setting.openTerminalLinksInApp)
        let globalDisabled = await call("browser_tabs")
        check(globalDisabled["isError"].bool == true, "Terminal browser opt-out is respected")
        settings.set(true, for: Setting.openTerminalLinksInApp)
        let invalid = await RemoteBrowserRelay.perform("write_file", arguments: .object([:]), window: id, root: root, agent: codex)
        check(invalid["isError"].bool == true, "The browser endpoint refuses project and filesystem tools")
        workspace.terminals.workspaceRoot = root.appendingPathComponent("changed")
        let changed = await call("browser_tabs")
        check(changed["isError"].bool == true, "Changing the connected project revokes browser access")
        workspace.terminals.workspaceRoot = root
        AgentToolServer.unregister(id)
        let closed = await call("browser_tabs")
        check(closed["isError"].bool == true && !text(closed).contains("OtherWindow"), "Closing the window never falls back to another project")
        await endpoint.close()
    }
}
