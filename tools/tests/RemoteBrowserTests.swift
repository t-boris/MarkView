import AppKit
import WebKit

// Minimal app dependencies; the production controller, executor, schemas and workspace run unchanged.
enum CLITool: String { case claude, codex }   // AgentToolsSetting.swift adds agentToolsKey and agentToolsEnabled
@MainActor final class Terminals { var root: URL? }
@MainActor protocol AgentControlWindow: AnyObject {
    var hostWindow: NSWindow? { get }
    var controlTerminalRoot: URL? { get }
}
@MainActor final class WorkspaceManager: AgentControlWindow {
    var hostWindow: NSWindow?
    let terminals = Terminals()
    var controlTerminalRoot: URL? { terminals.root }
}
// The Cockpit gate in AgentToolServer asks the project's workflow which bug statuses mean "fixing" and the deployments for names.
struct ProjectWorkflow {
    enum Kind { case bug }
    enum Role { case active, completed, notStarted }
    static let standard = ProjectWorkflow()
    func role(_ kind: Kind, _ status: String) -> Role? { nil }
}
final class FeatureStore {
    struct Lifecycle { var workflow = ProjectWorkflow.standard }
    var lifecycle = Lifecycle()
}
final class DeploymentStore {
    struct Environment { var name: String }
    func environment(_ id: String) -> Environment? { nil }
}
final class DiscussionStore {}
enum ProjectAgentTools { static let toolNames: Set<String> = ["markview_test"]; static let serverName = "markview" }
enum DeploymentAgentTools { static let names: Set<String> = [] }
enum DiscussionAgentTools { static let names: Set<String> = [] }
enum ControlAgentTools { static let names: Set<String> = [] }
enum ControlToolRunner {
    struct Caller { var pids: [Int32]; var folder: String }
    static func run(_ tool: String, _ args: [String: Any], caller: Caller) async -> BrowserAgentTools.Reply { .error("Unexpected control tool") }
}
enum ProjectToolRunner {
    static func run(_ tool: String, _ args: [String: Any], store: FeatureStore) -> BrowserAgentTools.Reply { .init(text: "project served") }
    static func reportCockpitProgress(_ args: [String: Any], store: FeatureStore) async -> BrowserAgentTools.Reply { .error("Unexpected project tool") }
    static func askCockpitSupervisor(_ args: [String: Any], store: FeatureStore) async -> BrowserAgentTools.Reply { .error("Unexpected project tool") }
}
enum LifecycleToolRunner {
    static func handles(_ tool: String, _ args: [String: Any]) -> Bool { false }
    static func run(_ tool: String, _ args: [String: Any], store: FeatureStore) async -> BrowserAgentTools.Reply { .error("Unexpected lifecycle tool") }
}
enum DeploymentToolRunner {
    static func run(_ tool: String, _ args: [String: Any], store: DeploymentStore) async -> BrowserAgentTools.Reply { .error("Unexpected deployment tool") }
}
enum DiscussionToolRunner {
    static func run(_ tool: String, _ args: [String: Any], store: DiscussionStore) -> BrowserAgentTools.Reply { .error("Unexpected discussion tool") }
}
enum TerminalBrowserBridge {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "test.browser.enabled") as? Bool ?? true }
    static func windowID(forAncestors pids: [Int32]) -> UUID? { nil }
}
enum BrowserAddress { static func url(from text: String) -> URL? { URL(string: text) } }
@MainActor final class BrowserSession {
    let agentFrames = BrowserAgentExecutor.Frames()
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 320))
    var agentName = "T1"
    var agentStopped = false
    var agentControlled = false
    var agentLastUsed: Date?
    var agentDialogs: [String] = []
    var loadError: String? { nil }
    var url: URL? { webView.url }
    var displayTitle: String { webView.title ?? "" }
    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func reload() { webView.reload() }
}

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

@main enum RemoteBrowserTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        for key in ["test.browser.enabled", CLITool.claude.agentToolsKey.name, CLITool.codex.agentToolsKey.name] {
            defaults.removeObject(forKey: key)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var requestedWindow: URL?
        AgentToolServer.setWindowOpener { folder in requestedWindow = folder; return true }
        precondition(AgentToolServer.openWindow(folder: root) && requestedWindow == root,
                     "the injected window opener works before any window is registered")
        let workspace = WorkspaceManager(), other = WorkspaceManager()
        workspace.terminals.root = root; other.terminals.root = root
        let session = BrowserSession(), unrelated = BrowserSession()
        let featureStore = FeatureStore()
        session.agentName = "WorkTab"; unrelated.agentName = "OtherWindow"
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.webView
        workspace.hostWindow = window
        session.webView.loadHTMLString("<title>Relay fixture</title><button onclick=\"document.querySelector('p').textContent='clicked'\">Run</button><p>work page</p>", baseURL: URL(string: "http://localhost"))
        let id = UUID(), otherID = UUID()
        func registration(_ workspace: WorkspaceManager, _ tab: BrowserSession) -> AgentToolWindow {
            let tabs = BrowserAgentTabs(tabs: { [tab] }, active: { tab }, show: { _ in }, open: { _, _ in tab })
            return .init(workspace: { workspace }, root: { root }, features: { featureStore }, browser: { tool, args in await tabs.run(tool, args) })
        }
        AgentToolServer.register(id, registration(workspace, session))
        AgentToolServer.register(otherID, registration(other, unrelated))
        defer { AgentToolServer.unregister(id); AgentToolServer.unregister(otherID) }
        let endpoint = try await RemoteWorkspace(root: root, browserCall: { name, args in
            await RemoteBrowserRelay.perform(name, arguments: args, window: id, root: root, agent: .codex)
        })
        func call(_ name: String, _ args: [String: RemoteJSON] = [:]) async -> RemoteJSON {
            await endpoint.call(id: UUID(), name: name, arguments: .object(args))
        }
        func text(_ reply: RemoteJSON) -> String { reply["content"].array?.first?["text"].string ?? "" }
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); print("PASS: " + message) }
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
        let noArgs = await RemoteBrowserRelay.perform("browser_tabs", arguments: .null, window: id, root: root, agent: .claude)
        check(text(noArgs).contains("WorkTab"), "MCP calls with omitted optional arguments work for Claude too")
        // AR-40: the control socket serves only a caller that holds the instance token. The blocking calls run off the
        // main actor, which the server's tool calls need.
        guard let controlSocket = AgentToolServer.socketPath else { fatalError("the control socket is not listening") }
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
        let legacyMismatch: [String: Any] = ["tool": "markview_test", "window": id.uuidString, "token": controlToken,
                                              "arguments": ["project_folder": "/outside-the-window"]]
        let mismatchReply = await Task.detached { rawControlReply(controlSocket, legacyMismatch) }.value
        check(mismatchReply?.isError == true && mismatchReply?.text.contains("Nothing was done") == true,
              "A legacy project folder outside a pinned window is refused before a project tool runs")
        let legacyMatch: [String: Any] = ["tool": "markview_test", "window": id.uuidString, "token": controlToken,
                                           "arguments": ["project_folder": root.path]]
        let matchReply = await Task.detached { rawControlReply(controlSocket, legacyMatch) }.value
        check(matchReply?.isError == false && matchReply?.text == "project served",
              "A matching legacy project folder allows the selected project tool")
        let viaClient = await Task.detached { BrowserAgentTools.request(socket: controlSocket, payload: tabsRequest, timeout: 5) }.value
        check(viaClient.text.contains("WorkTab"), "The MCP client finds the token file by itself and is served")
        session.agentStopped = true
        let stopped = await call("browser_click", ["ref": .string("e1")])
        check(stopped["isError"].bool == true && text(stopped).contains("stopped"), "The user's stopped tab is respected")
        session.agentStopped = false
        Settings.standard.set(false, for: CLITool.codex.agentToolsKey)
        let disabled = await call("browser_tabs")
        check(disabled["isError"].bool == true, "Per-agent browser opt-out is respected")
        Settings.standard.remove(CLITool.codex.agentToolsKey)
        defaults.set(false, forKey: "test.browser.enabled")
        let globalDisabled = await call("browser_tabs")
        check(globalDisabled["isError"].bool == true, "Terminal browser opt-out is respected")
        defaults.removeObject(forKey: "test.browser.enabled")
        let invalid = await RemoteBrowserRelay.perform("write_file", arguments: .object([:]), window: id, root: root, agent: .codex)
        check(invalid["isError"].bool == true, "The browser endpoint refuses project and filesystem tools")
        workspace.terminals.root = root.appendingPathComponent("changed")
        let changed = await call("browser_tabs")
        check(changed["isError"].bool == true, "Changing the connected project revokes browser access")
        workspace.terminals.root = root
        AgentToolServer.unregister(id)
        let closed = await call("browser_tabs")
        check(closed["isError"].bool == true && !text(closed).contains("OtherWindow"), "Closing the window never falls back to another project")
        await endpoint.close()
        print("Remote browser integration passed.")
    }
}
