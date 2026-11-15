#!/bin/bash
# The terminals of a window (AR-14 step 4): the shipping AITerminalsController, AssistantProviding, AgentActivityMonitor, TerminalProfile, the assistants'
# providers and the saved-terminals defaults of BUG-005, with a stand-in window and stand-in terminals. The stand-in
# TerminalSession starts no shell and records what the controller asks of it; the browser server, the saved remote connections and the
# home connection are compile-time stand-ins too. Nothing is started, shown or typed; the test process has its own UserDefaults domain.
#   tools/tests/ai-terminals-controller-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/AITerminalsControllerTests.swift "$out/main.swift"
cat > "$out/Stub.swift" <<'SWIFT'
import Foundation

@MainActor
protocol TerminalLinkTarget: AnyObject {
    func openFile(_ url: URL, line: Int?, endLine: Int?)
    func openInAppBrowser(_ url: URL)
}

/// A terminal that starts no shell: it records what the controller asked of it.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let directory: URL
    @Published private(set) var profile: TerminalProfile
    var title: String
    var startupCommand: String?
    var resumeCommand: String?
    var model: String?
    var observedModel: String?
    var pendingModelPick: String?
    private(set) var launchedAt = Date()
    var connection: AnyObject?
    var isRemote: Bool { connection != nil }
    @Published var remoteConnectionState: RemoteConnectionState?
    var onOutput: ((Data) -> Void)?
    private(set) weak var links: (any TerminalLinkTarget)?
    var browserWindowID: UUID?
    var shellPID: pid_t { 0 }
    var running = false
    var isRunning: Bool { running }
    var runningSince: Date? { running ? launchedAt : nil }
    var printedRecently = false
    var terminated = false
    var pasted: [(text: String, submit: Bool)] = []
    var restarts: [(profile: TerminalProfile, command: String?, title: String, model: String?)] = []
    var adopted: [(model: String, title: String)] = []

    init(directory: URL, profile: TerminalProfile = .shell, startupCommand: String? = nil, resumeCommand: String? = nil,
         title: String? = nil, model: String? = nil, links: (any TerminalLinkTarget)? = nil) {
        self.links = links
        self.directory = directory
        self.profile = profile
        self.startupCommand = startupCommand
        self.resumeCommand = resumeCommand
        self.model = model
        self.title = title ?? profile.title
        super.init()
    }
    func restart(profile newProfile: TerminalProfile, startupCommand command: String?, title newTitle: String, model newModel: String?) {
        restarts.append((newProfile, command, newTitle, newModel))
        profile = newProfile; startupCommand = command; title = newTitle; model = newModel
        launchedAt = Date(); observedModel = nil; pendingModelPick = nil
    }
    func adoptRunningModel(_ newModel: String, title newTitle: String) {
        adopted.append((newModel, newTitle))
        model = newModel; title = newTitle
    }
    func paste(_ text: String, submit: Bool = false) { pasted.append((text, submit)) }
    func pasteWhenReady(_ text: String, submit: Bool) { pasted.append((text, submit)) }
    func printed(within seconds: TimeInterval) -> Bool { printedRecently }
    @discardableResult func terminate(beforeReap: (@Sendable () async -> Void)? = nil) -> Task<Void, Never>? { terminated = true; return nil }
}

/// The home connection: opens at once; the test can change the window's folder while it "connects".
@MainActor
final class RemoteTerminalConnection {
    static var rootChange: (() -> Void)?
    static var stopped = 0
    var onState: ((RemoteConnectionState.Phase, String) -> Void)?
    init() {}
    init(invitation: RemoteInvitation, root: URL, browserWindowID: UUID, provider: CLITool,
         model: String?, resume: Bool, savedConnectionID: UUID?) async throws {
        Self.rootChange?()
    }
    func stop() { Self.stopped += 1 }
}

@MainActor
final class RemoteConnectionsStore {
    static let shared = RemoteConnectionsStore()
    var attached = 0
    func attach(_ host: any RemoteAssistantHost) { attached += 1 }
    func update(_ id: UUID, _ phase: RemoteConnectionState.Phase, _ detail: String) {}
}

enum BrowserControlServer {
    static func agentToolsEnabled(_ tool: CLITool) -> Bool { true }
    static func agentToolsKey(_ tool: CLITool) -> SettingsKey<Bool> { Setting.browserAgentTools(tool.rawValue) }
    static func mcpArguments(window id: UUID, flag: String = "--mcp-browser") -> (command: String, args: [String])? {
        ("/usr/local/bin/markview", [flag, "--window", id.uuidString])
    }
}
enum BrowserAgentTools {
    static let serverName = "markview-browser"
    static func reportsPolicyBlock(_ output: String) -> Bool { output.contains("blocked by policy") }
}
enum ProjectAgentTools { static let serverName = "markview" }
enum AgentBrowserRegistration {
    static func ensureRegistered(_ tool: CLITool, executable: String) {}
}
enum TerminalBrowserBridge { static var isEnabled: Bool { true } }
actor SemanticDatabase {
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {}
    nonisolated static func documentId(for url: URL, root: URL) -> String { url.path }
}
enum ACPAssistant {
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] { [] }
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] { [] }
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?)
        async throws -> CLICompletion.Result { fatalError("not used by the checks") }
}
enum AgentModelProbe { static func hasClaudeSession(cwd: URL) -> Bool { false } }
SWIFT
swiftc -o "$out/ai-terminals-controller-tests" -target "$(uname -m)-apple-macos13.0" \
    Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/Terminal/AITerminalsController.swift MarkView/Models/Terminal/AssistantProviding.swift MarkView/Models/Terminal/TerminalProfile.swift \
    MarkView/Models/Workspace/ProjectProviding.swift \
    MarkView/Models/Remote/RemoteAssistantHost.swift MarkView/Models/Remote/RemoteProtocol.swift \
    MarkView/Models/Remote/RemoteConnectionState.swift \
    MarkView/Models/AI/AgentActivityMonitor.swift \
    MarkView/Models/AI/AIAssistants.swift MarkView/Models/AI/CLICompletion.swift MarkView/Models/AI/Providers/*.swift \
    MarkView/Models/AI/AICallLog.swift MarkView/Models/AI/AgentProcesses.swift MarkView/Models/AI/AIOperation.swift \
    MarkView/Models/AI/OutputLanguage.swift MarkView/Models/Workspace/TaskBag.swift MarkView/Models/Workspace/LinkedFolders.swift MarkView/Models/Appearance/ProjectColor.swift \
    "$out/Stub.swift" "$out/main.swift"
"$out/ai-terminals-controller-tests"
