import Foundation
import CryptoKit

// The provider process is an inert echo terminal; both production endpoint controllers, HTTPS
// protocol, MCP sockets and workspace executors are real. No provider login or user project is used.
enum CLITool: String { case claude, codex }
struct TerminalProfile { init(_ tool: CLITool) {} }
enum ContentHash { static func of(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() } }
enum CLIToolLocator { static func resolveThorough(_ tool: CLITool) async -> String? { "/test/inert-agent" } }
enum AgentModelProbe { static func hasClaudeSession(cwd: URL) -> Bool { true } }
enum RemoteCodexContext {
    static func prepare(executable: String, directory: URL, context: RemoteJSON) async throws -> String? { nil }
}
@MainActor final class RemoteRelaySettings {
    static let shared = RemoteRelaySettings()
    var relayURL = "http://127.0.0.1:16393", accessKey = ""
    func finishPendingChanges() async {}
}
enum RemoteRelayKeychain { static func account(for text: String) throws -> String { text } }
@MainActor final class RemoteConnectionsStore {
    static let shared = RemoteConnectionsStore()
    func connectionStopped(_ id: UUID) {}
}
@MainActor enum BrowserControlServer {
    static func performRemoteBrowser(_ name: String, arguments: RemoteJSON, window: UUID, root: URL, agent: CLITool) async -> RemoteJSON {
        .textResult("BROWSER " + window.uuidString)
    }
}
@MainActor protocol TerminalConnection: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    func start(); func write(_ text: String); func resize(cols: Int, rows: Int); func stop()
}
@MainActor final class TerminalSession {
    static var starts = 0
    static var directories: Set<URL> = []
    let directory: URL
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onLaunchFailure: ((String) -> Void)?
    init(directory: URL, profile: TerminalProfile, title: String, operationCommand: String) {
        self.directory = directory; Self.directories.insert(directory)
    }
    func start() { Self.starts += 1; onOutput?(Data("SESSION_STARTED\n".utf8)) }
    func writeBytesForConnection(_ data: Data) { onOutput?(data) }
    func resizeForConnection(cols: Int, rows: Int) {}
    func terminate() {}
}

@main enum PersistentRemoteSessionTests {
    @MainActor static func main() async throws {
        let relay = URL(string: "http://127.0.0.1:16393")!
        let first = try RemoteInvitation(relay: relay, persistent: true), second = try RemoteInvitation(relay: relay, persistent: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-persistent-sessions-" + UUID().uuidString)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for (folder, text) in [(a, "WORK A"), (b, "WORK B")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("identity.txt"))
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            for directory in TerminalSession.directories { try? FileManager.default.removeItem(at: directory) }
        }
        func wait(_ message: String, seconds: Double = 30, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            precondition(predicate(), message); print("PASS: " + message)
        }
        let homeA = RemoteHostController(), homeB = RemoteHostController()
        var hostAReady = false, hostBReady = false
        homeA.onState = { phase, _ in if phase == .waiting { hostAReady = true } }
        homeB.onState = { phase, _ in if phase == .waiting { hostBReady = true } }
        homeA.start(code: try first.code); homeB.start(code: try second.code)
        defer { homeA.suspend(); homeB.suspend() }
        try await wait("Multiple saved hosts independently register and become available") { hostAReady && hostBReady }
        let windowA = UUID(), windowB = UUID()
        let workA = try await RemoteTerminalConnection(invitation: first, root: a, browserWindowID: windowA, provider: .claude, model: nil, resume: true)
        let workB = try await RemoteTerminalConnection(invitation: second, root: b, browserWindowID: windowB, provider: .codex, model: nil, resume: true)
        var outputA = "", outputB = "", exitedA = false
        workA.onOutput = { outputA += String(decoding: $0, as: UTF8.self) }
        workB.onOutput = { outputB += String(decoding: $0, as: UTF8.self) }
        workA.onExit = { _ in exitedA = true }
        workA.start(); workB.start()
        defer { workA.stop(); workB.stop() }
        try await wait("Two simultaneous work connections reach separate home terminals") { outputA.contains("SESSION_STARTED") && outputB.contains("SESSION_STARTED") }
        workA.write("ECHO_A\n"); workB.write("ECHO_B\n")
        try await wait("Terminal input/output stays isolated across connections") { outputA.contains("ECHO_A") && outputB.contains("ECHO_B") && !outputA.contains("ECHO_B") }
        // Probe every live MCP socket and prove that each reaches exactly its own work folder/browser.
        var identities: Set<String> = [], browsers: Set<String> = []
        for directory in TerminalSession.directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("mcp.json")),
                  let config = try? JSONDecoder().decode(RemoteJSON.self, from: data),
                  let socket = config["mcpServers"][RemoteWorkspaceTools.serverName]["args"].array?.last?.string else { continue }
            let file = await Task.detached { RemoteUnixRPC.call(socket: socket, id: UUID(), name: "read_file", arguments: .object(["path": .string("identity.txt")])) }.value
            let browser = await Task.detached { RemoteUnixRPC.call(socket: socket, id: UUID(), name: "browser_tabs", arguments: .object([:])) }.value
            identities.insert(file["content"].array?.first?["text"].string ?? "")
            browsers.insert(browser["content"].array?.first?["text"].string ?? "")
        }
        precondition(identities.count == 2 && identities.contains { $0.contains("WORK A") } && identities.contains { $0.contains("WORK B") })
        precondition(browsers == Set(["BROWSER " + windowA.uuidString, "BROWSER " + windowB.uuidString]))
        print("PASS: Real MCP bridge routes file/browser calls through the encrypted session to the correct work window")
        let starts = TerminalSession.starts
        homeA.suspend()
        let restarted = RemoteHostController(); restarted.start(code: try first.code)
        defer { restarted.suspend() }
        try await wait("Home app restart restores the saved pairing without another code") { TerminalSession.starts > starts && outputA.components(separatedBy: "SESSION_STARTED").count >= 3 }
        var request = URLRequest(url: relay.appendingPathComponent("test/outage")); request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        let beforeOutage = TerminalSession.starts
        try await wait("Both sessions recover automatically after a network outage without new codes", seconds: 45) { TerminalSession.starts >= beforeOutage + 2 }
        let revoker = RemoteChannel(invitation: first, role: .work)
        try await revoker.revokeAccess()
        try await wait("Explicit work-side revocation ends only that saved connection") { exitedA }
        workB.write("STILL_CONNECTED\n")
        try await wait("The second connection remains usable after the first is revoked") { outputB.contains("STILL_CONNECTED") }
        print("Persistent remote session integration passed.")
    }
}
