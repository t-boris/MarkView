import Combine
import Foundation

// Collaborators of `BrowserHost` that the checks do not exercise: the browser tab itself (a real one is a WebKit view), the terminals, the
// stores the control tools reach, the control server's window table and the sessions a tab can carry. They stand in for the app's own types
// (named like them) and record what the host asks of them; the host, the tabs, the panels, the project's web-app discovery, the
// control window it registers and the browser tool it hands to agents are the shipping code.

struct InsightSession {
    let id = UUID()
    func cancel() async {}
}
struct PrototypeSession { let slug: String }
struct StudioSession { func close() async {} }
struct CockpitSession { func cancel() {} }
enum Archive { static func isArchive(_ url: URL) -> Bool { false } }

actor SemanticDatabase {}

/// A browser tab that loads nothing: the pages it was asked to show are recorded.
@MainActor
final class BrowserSession: NSObject, ObservableObject {
    let id = UUID()
    @Published private(set) var url: URL?
    @Published var agentName = "T1"
    var agentStopped = false
    var agentLastUsed: Date?
    var displayTitle: String { url?.host ?? "" }
    @Published var preview: WebPreviewState?
    @Published var pickNotice: String?
    private(set) weak var host: (any BrowserSessionHost)?
    var isAppPreview = false
    var localReadRoot: URL?
    var previewTerminalID: UUID?
    private(set) var isClosed = false
    var loaded: [URL] = []
    var previews: [URL] = []
    var electronStandIn = false
    init(url: URL?, host: (any BrowserSessionHost)? = nil, prompts: any UserPrompts) { self.url = url; self.host = host; self.prompts = prompts }
    let prompts: any UserPrompts
    func load(_ url: URL) { self.url = url; loaded.append(url) }
    func showPreview(_ url: URL) { previews.append(url); preview = nil; self.url = url }
    func standInForElectron() { electronStandIn = true }
    func close() { isClosed = true }
}

/// A terminal that starts no shell.
@MainActor
final class TerminalSession {
    let id = UUID()
    let directory: URL
    let startupCommand: String?
    var onOutput: ((Data) -> Void)?
    var started = 0
    var pasted: [String] = []
    init(directory: URL, startupCommand: String?) {
        self.directory = directory
        self.startupCommand = startupCommand
    }
    func start() { started += 1 }
    func paste(_ text: String, submit: Bool = false) { pasted.append(text) }
}

@MainActor
final class StubTerminals: DevServerTerminals {
    var shown: TerminalSession?
    var previews: [String: TerminalSession] = [:]
    func previewTerminal(forApp folderPath: String) -> TerminalSession? { previews[folderPath] }
    func rememberPreviewTerminal(_ session: TerminalSession, forApp folderPath: String) { previews[folderPath] = session }
}

/// The tool server's window table (`AgentToolServer`): the windows that registered, without a socket.
@MainActor
enum AgentToolServer {
    static var registered: [UUID: AgentToolWindow] = [:]
    static func register(_ id: UUID, _ window: AgentToolWindow) { registered[id] = window }
}

/// What an agent's tab tool runs in the page: the tab it ran in is recorded in the reply.
enum BrowserAddress { static func url(from text: String) -> URL? { URL(string: text) } }
@MainActor
enum BrowserAgentExecutor {
    static func settle(_ session: BrowserSession, started: Bool) async {}
    static func status(_ session: BrowserSession) -> BrowserAgentTools.Reply { .init(text: "loaded") }
    static func run(_ tool: String, _ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        .init(text: "\(tool) ran in \(session.agentName)")
    }
}

// What the control tools reach of the window.
@MainActor protocol AgentControlWindow: AnyObject {}
@MainActor final class WorkspaceManager: AgentControlWindow {}
final class FeatureStore {}
final class DeploymentStore {}
final class DiscussionStore {}

/// The project as the browser reads it.
@MainActor
final class StubProject: ProjectProviding {
    var root: URL?
    var aiProject: URL? { root }
    var linkedFolderURLs: [URL] = []
    var searchRoots: [URL] { root.map { [$0] } ?? [] }
    var database: SemanticDatabase? { nil }
    func relativePath(of url: URL) -> String { url.path }
    func markdownFiles(in folder: URL) -> [URL] { [] }
    func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
    func refreshFileTree() {}
    func containerRoot(for url: URL) -> URL? { root }
}
