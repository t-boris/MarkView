import AppKit
import WebKit

// Minimal app dependencies; the production controller, executor, schemas and workspace run unchanged.
enum CLITool: String { case claude, codex }
@MainActor final class WorkspaceManager {
    var hostWindow: NSWindow?
    var aiWorkspaceRoot: URL?
    var rootNode: Node?
    struct Node { let url: URL }
}
final class FeatureStore {}
final class DeploymentStore {}
final class DiscussionStore {}
enum ProjectAgentTools { static let toolNames: Set<String> = [] }
enum DeploymentAgentTools { static let names: Set<String> = [] }
enum DiscussionAgentTools { static let names: Set<String> = [] }
enum ControlAgentTools { static let names: Set<String> = [] }
enum ControlToolRunner {
    struct Caller { var pids: [Int32]; var folder: String }
    static func run(_ tool: String, _ args: [String: Any], caller: Caller) async -> BrowserAgentTools.Reply { .error("Unexpected control tool") }
}
enum ProjectToolRunner {
    static func run(_ tool: String, _ args: [String: Any], store: FeatureStore) -> BrowserAgentTools.Reply { .error("Unexpected project tool") }
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

@main enum RemoteBrowserTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        for key in ["test.browser.enabled", BrowserControlServer.agentToolsKey(.claude), BrowserControlServer.agentToolsKey(.codex)] {
            defaults.removeObject(forKey: key)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceManager(), other = WorkspaceManager()
        workspace.aiWorkspaceRoot = root; other.aiWorkspaceRoot = root
        let session = BrowserSession(), unrelated = BrowserSession()
        session.agentName = "WorkTab"; unrelated.agentName = "OtherWindow"
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.webView
        workspace.hostWindow = window
        session.webView.loadHTMLString("<title>Relay fixture</title><button onclick=\"document.querySelector('p').textContent='clicked'\">Run</button><p>work page</p>", baseURL: URL(string: "http://localhost"))
        let id = UUID(), otherID = UUID()
        func registration(_ workspace: WorkspaceManager, _ tab: BrowserSession) -> BrowserControlServer.Window {
            .init(workspace: { workspace }, root: { root }, tabs: { [tab] }, active: { tab }, show: { _ in }, open: { _, _ in tab })
        }
        BrowserControlServer.register(id, registration(workspace, session))
        BrowserControlServer.register(otherID, registration(other, unrelated))
        defer { BrowserControlServer.unregister(id); BrowserControlServer.unregister(otherID) }
        let endpoint = try await RemoteWorkspace(root: root, browserCall: { name, args in
            await BrowserControlServer.performRemoteBrowser(name, arguments: args, window: id, root: root, agent: .codex)
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
        let image = await call("browser_screenshot")
        check(image["content"].array?.contains { $0["type"].string == "image" && $0["mimeType"].string == "image/png" && !($0["data"].string ?? "").isEmpty } == true, "Real page screenshot returns an MCP PNG image")
        let noArgs = await BrowserControlServer.performRemoteBrowser("browser_tabs", arguments: .null, window: id, root: root, agent: .claude)
        check(text(noArgs).contains("WorkTab"), "MCP calls with omitted optional arguments work for Claude too")
        session.agentStopped = true
        let stopped = await call("browser_click", ["ref": .string("e1")])
        check(stopped["isError"].bool == true && text(stopped).contains("stopped"), "The user's stopped tab is respected")
        session.agentStopped = false
        defaults.set(false, forKey: BrowserControlServer.agentToolsKey(.codex))
        let disabled = await call("browser_tabs")
        check(disabled["isError"].bool == true, "Per-agent browser opt-out is respected")
        defaults.removeObject(forKey: BrowserControlServer.agentToolsKey(.codex))
        defaults.set(false, forKey: "test.browser.enabled")
        let globalDisabled = await call("browser_tabs")
        check(globalDisabled["isError"].bool == true, "Terminal browser opt-out is respected")
        defaults.removeObject(forKey: "test.browser.enabled")
        let invalid = await BrowserControlServer.performRemoteBrowser("write_file", arguments: .object([:]), window: id, root: root, agent: .codex)
        check(invalid["isError"].bool == true, "The browser endpoint refuses project and filesystem tools")
        workspace.aiWorkspaceRoot = root.appendingPathComponent("changed")
        let changed = await call("browser_tabs")
        check(changed["isError"].bool == true, "Changing the connected project revokes browser access")
        workspace.aiWorkspaceRoot = root
        BrowserControlServer.unregister(id)
        let closed = await call("browser_tabs")
        check(closed["isError"].bool == true && !text(closed).contains("OtherWindow"), "Closing the window never falls back to another project")
        await endpoint.close()
        print("Remote browser integration passed.")
    }
}
