import Combine
import Foundation

// Collaborators of `FeatureFlowCoordinator` that the checks do not exercise: the feature store with its lifecycle, the GitHub store, the Git
// client, the terminals, the tabs, the research jobs and the window's sheet requests. They stand in for the app's own types (named like
// them) and record what the coordinator asks of them; the coordinator, the prompts it builds, the GitHub client that runs git, the panels,
// the batch rules and the Git status are the shipping code.

actor SemanticDatabase {}

/// The assistants' settings: the tool a project without its own choice uses.
enum AIAssistantPreferences {
    static func backend(project: URL?) -> CLITool { CLITool(rawValue: "claude")! }
}

/// Where the assistants' command-line tools live: `gh` is never run here, and `git` is found by its fixed path.
enum CLIToolLocator {
    static func subprocessPath(toolPath: String?) -> String { "/usr/bin:/bin" }
}

enum CLICompletion {
    struct Assistant {}
}

// MARK: Tabs and the project

/// The tab the person is looking at, as the coordinator reads it.
struct OpenTab {
    var url: URL
    var isFileBacked = true
}

@MainActor
final class StubTabs: FeatureFlowTabs {
    var activeTab: OpenTab?
    var opened: [URL] = []
    var githubTabs: [(item: GitHubItem, root: URL)] = []
    var reloads: [Bool] = []
    func openFile(_ url: URL) { opened.append(url) }
    func showGitHubTab(_ item: GitHubItem, root: URL) { githubTabs.append((item, root)) }
    func reloadChangedOpenFiles(all: Bool) async { reloads.append(all) }
}

@MainActor
final class StubProject: ProjectProviding {
    var root: URL?
    var aiProject: URL?
    var linkedFolderURLs: [URL] = []
    var searchRoots: [URL] { root.map { [$0] } ?? [] }
    var database: SemanticDatabase? { nil }
    var treeRefreshes = 0
    func relativePath(of url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.path }
        return String(url.path.dropFirst(root.path.count + 1))
    }
    func markdownFiles(in folder: URL) -> [URL] { [] }
    func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
    func refreshFileTree() { treeRefreshes += 1 }
    func containerRoot(for url: URL) -> URL? { root }
}

// MARK: Terminals

/// A terminal that starts no shell.
@MainActor
final class TerminalSession {
    let id = UUID()
    let directory: URL
    let profile: TerminalProfile
    var runningSince: Date?
    init(directory: URL, profile: TerminalProfile) {
        self.directory = directory
        self.profile = profile
    }
}

/// The assistants of the window: what is sent to them is recorded; `sends` false stands for "no terminal could be opened".
@MainActor
final class StubAssistants: AssistantProviding, AssistantPrompting {
    let session: TerminalSession
    var sends = true
    var assistantIsBusy = false
    var sent: [(prompt: String, submit: Bool, terminal: TerminalSession)] = []
    var currentAssistant: CLICompletion.Assistant? { nil }
    var sessions: [TerminalSession] { [session] }
    var shownID: UUID? { session.id }
    init(directory: URL, tool: CLITool) {
        session = TerminalSession(directory: directory, profile: .assistant(tool))
    }
    func liveModelReported(_ model: String, terminalID: UUID) {}
    func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession? { nil }
    func showAIConsole() {}
    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? {
        guard sends else { return nil }
        sent.append((prompt, submit, session))
        return session
    }
    func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? {
        guard sends else { return nil }
        let target = terminal ?? session
        guard let prompt = promptFor(target) else { return nil }
        sent.append((prompt, submit, target))
        return target
    }
}

// MARK: Research, Git and GitHub

@MainActor
final class ResearchJobs {
    var comments: [(passage: String, comment: String, file: URL)] = []
    func comment(on passage: String, comment: String, in file: URL) { comments.append((passage, comment, file)) }
    nonisolated static func relative(_ url: URL, to root: URL) -> String? {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
}

@MainActor
final class ResearchMapController {
    let jobs = ResearchJobs()
}

/// The folder's Git client with the one operation the checks need to answer: switching and creating a branch.
@MainActor
final class GitClient: ObservableObject {
    @Published var branch = ""
    @Published var repoStatus = GitRepoStatus()
    @Published var operationInProgress: String?
    @Published var lastError: String?
    var workingDirectory: URL?
    let branchReports = PassthroughSubject<String, Never>()
    var refreshes = 0
    var branchError: String?
    var switched: [String] = []
    var created: [(name: String, base: String?)] = []
    func refresh() async { refreshes += 1 }
    func switchBranch(_ name: String) async -> String? { switched.append(name); return branchError }
    func createBranch(_ name: String, from base: String?) async -> String? { created.append((name, base)); return branchError }
}

/// GitHub of the folder: what the coordinator sets up and resets is recorded. `perform` runs no `gh`; it records the label and answers.
@MainActor
final class GitHubStore: ObservableObject, GitHubClientSource {
    @Published var repos: [GitHubRepo] = []
    @Published var selectedRepo: GitHubRepo?
    @Published var lastError: String?
    let polls = PassthroughSubject<GitHubClient, Never>()
    private(set) var root: URL?
    var setups: [URL] = []
    var resets = 0
    var branches: [String] = []
    var performed: [String] = []
    var performError: String?
    /// What a repository lookup in a set-up folder finds.
    var reposFound: [GitHubRepo] = []

    var client: GitHubClient? {
        guard let root, let repo = selectedRepo else { return nil }
        return GitHubClient(root: root, repo: repo)
    }
    func setup(root: URL) {
        self.root = root
        setups.append(root)
        repos = reposFound
        selectedRepo = reposFound.first
    }
    func reset() {
        resets += 1
        root = nil
        repos = []
        selectedRepo = nil
    }
    func branchChanged(_ name: String) { branches.append(name) }
    @discardableResult
    func perform(_ label: String, client: GitHubClient? = nil, _ action: @escaping (GitHubClient) async throws -> Void) async -> String? {
        performed.append(label)
        return performError
    }
}

/// A workflow run's page: its failed logs take a moment to load.
@MainActor
final class GitHubRunModel: ObservableObject {
    var run: GHRun?
    var loadDelay: UInt64 = 0
    func loadFailedLogs() async { if loadDelay > 0 { try? await Task.sleep(nanoseconds: loadDelay) } }
    func failureText(limit: Int = 300) -> String { "The run failed in step Build." }
}

// MARK: The feature store

struct Feature {
    let slug: String
    let folder: URL
}

struct FeatureObject {}

struct BugReport {
    let url: URL
    var key: String
}

/// The status of an issue changes through the lifecycle: the answers are the checks' own.
struct ApplyResult: Equatable {
    var reachedStatus: Bool
}

enum IssueKind { case feature, bug }

struct LifecycleActor: Equatable {
    var name: String
    static func human(_ name: String = "person") -> LifecycleActor { LifecycleActor(name: name) }
}

@MainActor
final class StubLifecycle {
    /// Keys the lifecycle refuses to start by a hand-off (already fixed or closed), and keys whose start it cannot record.
    var notStartable: Set<String> = []
    var notRecorded: Set<String> = []
    var started: [(key: String, tool: String, actor: LifecycleActor, surface: Bool)] = []
    func canStartByHandoff(_ kind: IssueKind, _ issue: String) -> Bool { !notStartable.contains(issue) }
    func storedStatus(_ kind: IssueKind, _ issue: String) -> String? { notStartable.contains(issue) ? "fixed" : "open" }
    func handoffBlock(_ kind: IssueKind, _ issues: [String]) -> String { "LIFECYCLE-BLOCK(\(issues.joined(separator: ",")))" }
    @discardableResult
    func startByHandoff(_ kind: IssueKind, _ issue: String, tool: String, actor: LifecycleActor, surface: Bool = true) -> ApplyResult {
        started.append((issue, tool, actor, surface))
        return ApplyResult(reachedStatus: !notRecorded.contains(issue))
    }
}

enum FeatureAction: String {
    case ask, challenge, expand, research
}

@MainActor
protocol GitHubClientSource: AnyObject {
    var client: GitHubClient? { get }
}

@MainActor
final class FeatureAssistant: ObservableObject {
    unowned let store: FeatureStore
    init(store: FeatureStore) { self.store = store }
    struct IntakeOutcome {
        var file: URL?
        var feature: String?
        var issue: String?
    }
    weak var project: (any ProjectProviding)?
    func gitHubClient() -> GitHubClient? { store.gitHub?.client }
    var performed: [(action: FeatureAction, selection: String, document: String?, question: String, feature: String?)] = []
    func perform(_ action: FeatureAction, selection: String, document: String?, question: String = "", feature slug: String?) async {
        performed.append((action, selection, document, question, slug))
    }
}

@MainActor
final class FeatureStore: ObservableObject {
    static let folderName = "docs/features"
    @Published var features: [Feature] = []
    @Published var bugs: [BugReport] = []
    @Published var activeSlug: String?
    @Published var lastError: String?
    private(set) var root: URL?
    let lifecycle = StubLifecycle()
    private(set) weak var gitHub: (any GitHubClientSource)?
    private(set) lazy var assistant = FeatureAssistant(store: self)
    init(gitHub: (any GitHubClientSource)? = nil) { self.gitHub = gitHub }
    var lifecycleActor = "Boris"
    var setups: [URL] = []
    var resets = 0
    var implementing: [(slug: String, handoff: String)] = []
    var implementationStarts: [(slug: String, tool: CLITool, directory: URL)] = []

    var active: Feature? { features.first { $0.slug == activeSlug } }
    func locate(_ url: URL) -> (feature: Feature, object: FeatureObject?)? {
        features.first { url.standardizedFileURL.path.hasPrefix($0.folder.standardizedFileURL.path + "/") }.map { ($0, nil) }
    }
    func relativePath(_ url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path + "/") else { return url.path }
        return String(url.path.dropFirst(root.path.count + 1))
    }
    func bug(at url: URL) -> BugReport? { bugs.first { $0.url == url } }
    func setup(root: URL) { self.root = root; setups.append(root) }
    func reset() { resets += 1; root = nil }
    var syncs = 0
    func syncLifecycle(with client: GitHubClient) { syncs += 1 }
    func markImplementing(_ slug: String, handoff tool: String) { implementing.append((slug, tool)) }
    func recordImplementationStarted(_ slug: String, tool: CLITool, directory: URL, runningSince: Date?) {
        implementationStarts.append((slug, tool, directory))
    }
}

/// The bug basket: which bugs a batch would fix is set by the check.
@MainActor
final class BugBatch: ObservableObject {
    unowned let store: FeatureStore
    @Published var notice: String?
    var eligible: [BasketBug] = []
    var resets = 0
    var reconciles = 0
    var clears = 0
    init(store: FeatureStore) { self.store = store }
    func reset() { resets += 1 }
    func reconcile() { reconciles += 1 }
    func clear() { clears += 1; eligible = [] }
}

// MARK: Sheet requests and settings

@MainActor
final class WindowRequests: ObservableObject {
    @Published var intake: IntakeRequest?
    @Published var doneRequest: URL?
    @Published var handoffResume: HandoffResume?
}
