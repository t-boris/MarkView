import Foundation
import AppKit
import UserNotifications

/// Settings keys of the GitHub integration.
enum GitHubSettings {
    /// The integration is opt-in: off, MarkView never runs `gh` or polls GitHub.
    static let enabledKey = "settings.github.enabled"
    /// Seconds between checks of Actions while nothing runs (300 by default).
    static let idleIntervalKey = "settings.github.idleInterval"
    /// Seconds between checks while a run is active (30 by default).
    static let activeIntervalKey = "settings.github.activeInterval"
    /// macOS notification when a run on one of my branches finishes (on by default).
    static let notifyKey = "settings.github.notifyRuns"
    /// "Review" on a pull request starts the AI review at once (on by default).
    static let autoReviewKey = "settings.github.autoReview"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var idleInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: idleIntervalKey)
        return value > 0 ? value : 300
    }
    static var activeInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: activeIntervalKey)
        return value > 0 ? value : 30
    }
    static var notify: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
    static var autoReview: Bool { UserDefaults.standard.object(forKey: autoReviewKey) as? Bool ?? true }
}

/// GitHub state of one window's folder: pull requests, issues and Actions of the selected
/// repository, refreshed on demand and (for Actions) on a timer. Answers that arrive after
/// the repository changed or the integration was turned off are dropped (`generation`).
@MainActor
final class GitHubStore: ObservableObject {
    @Published private(set) var repos: [GitHubRepo] = []
    @Published var selectedRepo: GitHubRepo? {
        didSet {
            guard oldValue != selectedRepo else { return }
            clearRepoState()
            onRepoChange?(selectedRepo)
            if selectedRepo != nil { refreshAll() }
        }
    }
    /// Told the repository GitHub requests go to (the PR X-Ray of the same window follows it).
    var onRepoChange: ((GitHubRepo?) -> Void)?
    /// Told on every poll (and when polling starts), for other state that follows GitHub.
    var onPoll: ((GitHubClient) -> Void)?
    @Published var lastError: String?

    // Pull requests
    @Published private(set) var pullRequests: [GHPullRequest] = []
    @Published var prState = "open" { didSet { refreshPullRequests() } }
    @Published var prFilter: GitHubClient.PRFilter = .all { didSet { refreshPullRequests() } }
    @Published private(set) var loadingPRs = false

    // Issues
    @Published private(set) var issues: [GHIssue] = []
    @Published var issueState = "open" { didSet { refreshIssues() } }
    @Published var issueFilter: GitHubClient.IssueFilter = .all { didSet { refreshIssues() } }
    @Published private(set) var loadingIssues = false
    @Published private(set) var labels: [GHLabel] = []
    @Published private(set) var assignableUsers: [String] = []

    // Actions
    @Published private(set) var runs: [GHRun] = []
    @Published private(set) var workflows: [GHWorkflow] = []
    @Published var runWorkflow: Int? { didSet { if oldValue != runWorkflow { refreshRuns() } } }
    @Published var runBranch = "" { didSet { if oldValue != runBranch { refreshRuns() } } }
    @Published private(set) var loadingRuns = false

    /// Latest run of each workflow on the current branch — the Git tab's CI dot.
    @Published private(set) var branchRuns: [GHRun] = []
    @Published private(set) var account: GitHubClient.Account?

    private(set) var root: URL?
    /// Current branch, told by the Git client.
    private(set) var branch = ""
    /// Bumped on every reset and repository change; async results of an older one are dropped.
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    private var loadingBranchRuns = false
    private var loadingMetadata = false
    /// Runs seen active, to notify when they finish.
    private var activeRunIds: Set<Int> = []
    /// Tab models by "<repo>#<number>".
    private var runModels: [String: GitHubRunModel] = [:]
    private var issueModels: [String: GitHubIssueModel] = [:]

    var client: GitHubClient? {
        guard let root, let repo = selectedRepo else { return nil }
        return GitHubClient(root: root, repo: repo)
    }

    /// A client for one of this folder's repositories, by "owner/name".
    func client(for slug: String) -> GitHubClient? {
        guard let root, let repo = repos.first(where: { $0.slug == slug }) else { return nil }
        return GitHubClient(root: root, repo: repo)
    }

    var isAvailable: Bool { selectedRepo != nil }

    // MARK: Setup

    func setup(root: URL) {
        guard GitHubSettings.enabled, self.root != root else { return }
        reset()
        self.root = root
        let generation = self.generation
        Task {
            let found = await GitHubClient.detectRepos(root: root)
            guard generation == self.generation else { return }
            repos = found
            selectedRepo = found.first
            loadAccount()
            startPolling()
        }
    }

    func reset() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        root = nil
        branch = ""
        repos = []
        selectedRepo = nil
        clearRepoState()
        account = nil
        lastError = nil
    }

    /// Everything that belongs to the selected repository.
    private func clearRepoState() {
        generation += 1
        pullRequests = []; issues = []; runs = []; workflows = []; branchRuns = []
        labels = []; assignableUsers = []
        runModels = [:]; issueModels = [:]
        activeRunIds = []
        runWorkflow = nil
        loadingPRs = false; loadingIssues = false; loadingRuns = false
        loadingBranchRuns = false; loadingMetadata = false
    }

    func loadAccount() {
        guard let root else { return }
        let generation = self.generation
        Task {
            let found = try? await GitHubClient.account(root: root)
            guard generation == self.generation else { return }
            account = found
        }
    }

    /// The Git client saw a (new) current branch.
    func branchChanged(_ name: String) {
        guard name != branch else { return }
        branch = name
        refreshBranchRuns()
    }

    func refreshAll() {
        refreshPullRequests()
        refreshIssues()
        refreshRuns()
        refreshWorkflows()
        refreshBranchRuns()
    }

    // MARK: Pull requests

    func refreshPullRequests() {
        guard let client else { return }
        loadingPRs = true
        let state = prState, filter = prFilter, generation = self.generation
        Task {
            do {
                let list = try await client.pullRequests(state: state, filter: filter)
                guard generation == self.generation, state == prState, filter == prFilter else { return }
                pullRequests = list
                lastError = nil
            } catch {
                if generation == self.generation { lastError = error.localizedDescription }
            }
            if generation == self.generation { loadingPRs = false }
        }
    }

    /// Run an action with `client` (the selected repository's by default). Returns the error.
    @discardableResult
    func perform(_ label: String, client: GitHubClient? = nil,
                 _ action: @escaping (GitHubClient) async throws -> Void) async -> String? {
        guard let client = client ?? self.client else { return "No GitHub repository." }
        do {
            try await action(client)
            lastError = nil
            return nil
        } catch {
            let message = "\(label): \(error.localizedDescription)"
            lastError = message
            return message
        }
    }

    // MARK: Issues

    func refreshIssues() {
        guard let client else { return }
        loadingIssues = true
        let state = issueState, filter = issueFilter, generation = self.generation
        Task {
            do {
                let list = try await client.issues(state: state, filter: filter)
                guard generation == self.generation, state == issueState, filter == issueFilter else { return }
                issues = list
                lastError = nil
            } catch {
                if generation == self.generation { lastError = error.localizedDescription }
            }
            if generation == self.generation { loadingIssues = false }
        }
    }

    /// Labels and assignable people, loaded once per repository.
    func loadIssueMetadata() {
        guard let client, labels.isEmpty, !loadingMetadata else { return }
        loadingMetadata = true
        let generation = self.generation
        Task {
            let foundLabels = (try? await client.labels()) ?? []
            let users = (try? await client.assignableUsers()) ?? []
            guard generation == self.generation else { return }
            labels = foundLabels
            assignableUsers = users
            loadingMetadata = false
        }
    }

    func issueModel(_ number: Int, repo slug: String) -> GitHubIssueModel? {
        let key = "\(slug)#\(number)"
        if let model = issueModels[key] { return model }
        guard let client = client(for: slug) else { return nil }
        let model = GitHubIssueModel(number: number, client: client, store: self)
        issueModels[key] = model
        return model
    }

    // MARK: Actions

    func refreshRuns() {
        guard let client, !loadingRuns else { return }
        loadingRuns = true
        let workflow = runWorkflow, branch = runBranch, generation = self.generation
        Task {
            do {
                let list = try await client.runs(workflow: workflow, branch: branch)
                if generation == self.generation, workflow == runWorkflow, branch == runBranch {
                    runs = list
                    lastError = nil
                    noteRuns(list)
                }
            } catch {
                if generation == self.generation { lastError = error.localizedDescription }
            }
            guard generation == self.generation else { return }
            loadingRuns = false
            // The filter changed while this one was loading.
            if workflow != runWorkflow || branch != runBranch { refreshRuns() }
        }
    }

    func refreshWorkflows() {
        guard let client else { return }
        let generation = self.generation
        Task {
            let list = (try? await client.workflows()) ?? []
            guard generation == self.generation else { return }
            workflows = list
        }
    }

    private func refreshBranchRuns() {
        guard let client, !branch.isEmpty, !loadingBranchRuns else { return }
        loadingBranchRuns = true
        let branch = self.branch, generation = self.generation
        Task {
            let list = try? await client.runs(workflow: nil, branch: branch)
            guard generation == self.generation else { return }
            loadingBranchRuns = false
            guard let list, branch == self.branch else { return }
            var latest: [String: GHRun] = [:]
            for run in list where latest[run.workflowName] == nil { latest[run.workflowName] = run }
            branchRuns = latest.values.sorted { $0.workflowName < $1.workflowName }
            noteRuns(list)
        }
    }

    /// Worst outcome of the current branch's latest runs.
    var branchOutcome: GHOutcome? {
        guard !branchRuns.isEmpty else { return nil }
        if branchRuns.contains(where: { $0.outcome == .failure }) { return .failure }
        if branchRuns.contains(where: { $0.isActive }) { return .running }
        return .success
    }

    func runModel(_ id: Int, repo slug: String) -> GitHubRunModel? {
        let key = "\(slug)#\(id)"
        if let model = runModels[key] { return model }
        guard let client = client(for: slug) else { return nil }
        let model = GitHubRunModel(runId: id, client: client, store: self)
        runModels[key] = model
        return model
    }

    // MARK: Polling and notifications

    private func startPolling() {
        pollTask?.cancel()
        guard selectedRepo != nil else { return }
        if let client { onPoll?(client) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let active = self?.anyRunActive ?? false
                let seconds = active ? GitHubSettings.activeInterval : GitHubSettings.idleInterval
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.refreshRuns()
                self.refreshBranchRuns()
                for model in self.runModels.values where model.isLive { model.refresh() }
                if let client = self.client { self.onPoll?(client) }
            }
        }
    }

    /// Something is running: the lists or an open run tab show it.
    private var anyRunActive: Bool {
        runs.contains(where: \.isActive) || branchRuns.contains(where: \.isActive)
            || runModels.values.contains { $0.run?.isActive == true }
    }

    /// Remember active runs; notify about the ones that finished since the last look.
    private func noteRuns(_ list: [GHRun]) {
        for run in list {
            if run.isActive {
                activeRunIds.insert(run.databaseId)
            } else if activeRunIds.remove(run.databaseId) != nil {
                notifyFinished(run)
            }
        }
    }

    /// Branches that are "mine": the current one and the heads of my open pull requests.
    private var myBranches: Set<String> {
        var set: Set<String> = branch.isEmpty ? [] : [branch]
        if let login = account?.login {
            for pr in pullRequests where pr.author?.login == login { set.insert(pr.headRefName) }
        }
        return set
    }

    private func notifyFinished(_ run: GHRun) {
        guard GitHubSettings.enabled, GitHubSettings.notify, myBranches.contains(run.headBranch) else { return }
        let result = run.outcome == .success ? "succeeded" : run.outcome == .failure ? "failed" : (run.conclusion ?? "finished")
        let title = "\(run.workflowName) \(result)"
        let body = "\(run.headBranch) · \(run.displayTitle)"
        let failed = run.outcome == .failure
        let id = "run-\(run.databaseId)"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = failed ? .default : nil
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

// MARK: - One workflow run (its editor tab)

@MainActor
final class GitHubRunModel: ObservableObject {
    let runId: Int
    /// The run's repository (fixed, whatever the Git tab selects later).
    let client: GitHubClient
    private weak var store: GitHubStore?

    @Published private(set) var run: GHRun?
    @Published private(set) var jobs: [GHJob] = []
    @Published var selectedJob: Int?
    /// Log lines by job, then by step number.
    @Published private(set) var logs: [Int: [Int: [GHLogLine]]] = [:]
    @Published private(set) var loadingLog: Set<Int> = []
    @Published var error: String?
    @Published private(set) var busy = false
    /// The AI's reading of the failure (streamed).
    @Published private(set) var explanation = ""
    @Published private(set) var explaining = false
    private var refreshing = false

    init(runId: Int, client: GitHubClient, store: GitHubStore) {
        self.runId = runId
        self.client = client
        self.store = store
        refresh()
    }

    var isLive: Bool { run?.isActive ?? true }

    var selected: GHJob? { jobs.first { $0.databaseId == selectedJob } ?? jobs.first }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let client = self.client
        Task {
            defer { refreshing = false }
            do {
                async let runValue = client.run(runId)
                async let jobsValue = client.jobs(run: runId)
                let (run, jobs) = try await (runValue, jobsValue)
                self.run = run
                self.jobs = jobs
                if selectedJob == nil || !jobs.contains(where: { $0.databaseId == selectedJob }) {
                    selectedJob = (jobs.first { $0.outcome == .failure } ?? jobs.first)?.databaseId
                }
                error = nil
                // The shown job finished: its log is available now.
                if let job = selected, job.outcome != .running, logs[job.databaseId] == nil { loadLog(job) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func select(_ job: GHJob) {
        selectedJob = job.databaseId
        if logs[job.databaseId] == nil, job.outcome != .running { loadLog(job) }
    }

    func loadLog(_ job: GHJob) {
        guard !loadingLog.contains(job.databaseId) else { return }
        loadingLog.insert(job.databaseId)
        Task {
            defer { loadingLog.remove(job.databaseId) }
            do {
                let text = try await client.jobLog(job.databaseId)
                let steps = job.steps ?? []
                logs[job.databaseId] = await Task.detached { GHJobLog.split(text, steps: steps) }.value
            } catch { self.error = "Log of \(job.name): \(error.localizedDescription)" }
        }
    }

    func rerun(failedOnly: Bool) { act("Re-run") { try await $0.rerun(self.runId, failedOnly: failedOnly) } }
    func cancel() { act("Cancel") { try await $0.cancel(self.runId) } }

    private func act(_ label: String, _ action: @escaping (GitHubClient) async throws -> Void) {
        guard let store else { return }
        busy = true
        Task {
            error = await store.perform(label, client: client, action)
            busy = false
            logs = [:]
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refresh()
            store.refreshRuns()
        }
    }

    /// The failed steps' log, last lines of each — what the AI gets.
    func failureText(limit: Int = 300) -> String {
        guard let run else { return "" }
        var text = "Workflow \"\(run.workflowName)\" run #\(run.number) on branch \(run.headBranch) (\(run.event)): \(run.conclusion ?? run.status).\n"
        for job in jobs where job.outcome == .failure {
            text += "\nJob \"\(job.name)\" failed."
            let failedSteps = (job.steps ?? []).filter { $0.outcome == .failure }
            for step in failedSteps {
                text += "\nStep \"\(step.name)\" failed. Last log lines:\n```\n"
                let lines = logs[job.databaseId]?[step.number] ?? []
                text += lines.suffix(limit).map(\.text).joined(separator: "\n")
                text += "\n```\n"
            }
            if failedSteps.isEmpty, let all = logs[job.databaseId]?.sorted(by: { $0.key < $1.key }).flatMap(\.value) {
                text += "\n```\n" + all.suffix(limit).map(\.text).joined(separator: "\n") + "\n```\n"
            }
        }
        return text
    }

    /// Load the logs of the failed jobs (needed before the AI can read them).
    func loadFailedLogs() async {
        for job in jobs where job.outcome == .failure && logs[job.databaseId] == nil {
            if let text = try? await client.jobLog(job.databaseId) {
                let steps = job.steps ?? []
                logs[job.databaseId] = await Task.detached { GHJobLog.split(text, steps: steps) }.value
            }
        }
    }

    func explainFailure(db: SemanticDatabase?) {
        guard !explaining else { return }
        explaining = true
        explanation = ""
        Task {
            await loadFailedLogs()
            var request = CLICompletion.Request(
                prompt: failureText(),
                systemPrompt: """
                You are a senior engineer reading a failed GitHub Actions run. Say in a few sentences what failed \
                and the most likely cause, quoting the decisive log line; then what to change to fix it (files, \
                commands, workflow settings). Plain text, short paragraphs or bullets, no headings.
                """ + "\n\n" + ActionOutputLanguage.explanationLine())
            request.model = AIAssistantPreferences.xrayModel(for: request.tool)
            request.effort = "low"
            request.timeout = 300
            var streamed = ""
            do {
                let result = try await CLICompletion.run(request, onDelta: { text in
                    Task { @MainActor in
                        streamed += text
                        self.explanation = streamed
                    }
                })
                result.record(in: db)
                if !result.text.isEmpty { explanation = result.text }
            } catch is CancellationError {
            } catch { explanation = "Failed: \(error.localizedDescription)" }
            explaining = false
        }
    }
}

// MARK: - One issue (its editor tab)

@MainActor
final class GitHubIssueModel: ObservableObject {
    let number: Int
    /// The issue's repository (fixed, whatever the Git tab selects later).
    let client: GitHubClient
    private weak var store: GitHubStore?

    @Published private(set) var issue: GHIssue?
    /// Text and comments as GitHub renders them (markdown, images, task lists…).
    @Published private(set) var html: GHIssueHTML?
    @Published var error: String?
    @Published private(set) var busy = false

    init(number: Int, client: GitHubClient, store: GitHubStore) {
        self.number = number
        self.client = client
        self.store = store
        refresh()
        if client.repo == store.selectedRepo { store.loadIssueMetadata() }
    }

    func refresh() {
        Task {
            do {
                async let details = client.issue(number)
                async let rendered = client.issueHTML(number)
                let (issue, html) = try await (details, rendered)
                self.issue = issue
                self.html = html
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Run an edit, then reload the issue and the list.
    func act(_ label: String, _ action: @escaping (GitHubClient) async throws -> Void) {
        guard let store else { return }
        busy = true
        Task {
            error = await store.perform(label, client: client, action)
            busy = false
            refresh()
            store.refreshIssues()
        }
    }
}
