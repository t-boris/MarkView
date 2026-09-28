import Foundation

/// The Sync action of the Issues list (issue #36): closes the GitHub issues whose linked
/// Features and Bugs are all done, then keeps the report until the next run. One-way: GitHub is
/// never read back into the docs, and no Markdown file is written (REQ-001).
@MainActor
final class IssueSyncRun: ObservableObject {
    /// "Checking GitHub…", "Reading documents…", "Issue 3 of 12"; nil when no run is active.
    @Published private(set) var phase: String?
    /// The last run's report (DEC-009): replaced by the next run, dropped with the store.
    @Published var report: IssueSyncReport?

    var isRunning: Bool { phase != nil }

    /// Projects with a run under way, across windows: one run per project (DEC-009).
    private static var activeProjects: Set<String> = []
    /// Bumped by `clear()`: a run that finishes after the project was closed drops its report.
    private var generation = 0

    /// Start a run over the listed features and bugs; ignored while one runs for this project.
    func start(root: URL, features: [URL], bugs: [URL]) {
        let project = root.standardizedFileURL.path
        guard GitHubSettings.enabled, !isRunning, !Self.activeProjects.contains(project) else { return }
        Self.activeProjects.insert(project)
        report = nil
        phase = "Checking GitHub…"
        let started = generation
        Task {
            let result = await run(root: root, features: features, bugs: bugs)
            Self.activeProjects.remove(project)
            guard started == generation else { return }
            report = result
            phase = nil
        }
    }

    /// The project was closed: forget the report (a run in progress still completes on GitHub).
    func clear() {
        generation += 1
        report = nil
        phase = nil
    }

    private func run(root: URL, features: [URL], bugs: [URL]) async -> IssueSyncReport {
        let started = generation
        let client: GitHubClient
        switch await Self.preflight(root: root) {
        case .failure(let error): return IssueSyncReport(origin: "", error: error.message)
        case .success(let ready): client = ready
        }
        let origin = client.repo.slug
        if started == generation { phase = "Reading documents…" }
        let items = await Task.detached(priority: .userInitiated) {
            IssueSyncLoader.items(features: features, bugs: bugs)
        }.value
        let plan = IssueSyncPlan(items: items, origin: origin)
        var outcomes = plan.known
        // One lookup and at most one change per issue (DEC-008); a failure does not stop the rest.
        for (index, target) in plan.lookups.enumerated() {
            if started == generation { phase = "Issue \(index + 1) of \(plan.lookups.count)" }
            let remote = await Self.lookup(target, client: client)
            switch plan.decide(target, remote: remote) {
            case .outcome(let outcome):
                outcomes[target] = outcome
            case .close:
                do {
                    try await client.gh(["issue", "close", String(target.number), "-R", origin, "--reason", "completed"])
                    outcomes[target] = .closed
                } catch {
                    outcomes[target] = IssueSyncOutcome(kind: .failed, detail: error.localizedDescription)
                }
            }
        }
        return IssueSyncReport(plan: plan, outcomes: outcomes)
    }

    /// gh installed and signed in, a GitHub origin, and triage access or more; otherwise the
    /// run ends here with nothing changed (DEC-007).
    private static func preflight(root: URL) async -> Result<GitHubClient, GitHubError> {
        guard GitHubClient.ghPath() != nil else {
            return .failure(GitHubError(message: "GitHub CLI (gh) is not installed. Install it with `brew install gh`, then run `gh auth login`."))
        }
        let auth = await GitHubClient.execute(["auth", "status", "--hostname", "github.com"], in: root, timeout: 20)
        guard auth.status == 0 else {
            return .failure(GitHubError(message: "Not signed in to GitHub. Run `gh auth login` in a terminal, then Sync again."))
        }
        let remote = await GitHubClient.execute(["remote", "get-url", "origin"], in: root, git: true)
        guard remote.status == 0,
              let slug = GitHubClient.slug(fromRemoteURL: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(GitHubError(message: "This project has no GitHub `origin` remote, so there are no issues to sync."))
        }
        let view = await GitHubClient.execute(["repo", "view", slug, "--json", "viewerPermission"], in: root, timeout: 30)
        guard view.status == 0 else {
            let message = view.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitHubError(message: "Cannot reach \(slug) on GitHub: \(message.isEmpty ? "no answer" : String(message.prefix(300)))"))
        }
        if let problem = IssueSyncPreflight.permissionProblem(json: view.stdout, repo: slug) {
            return .failure(GitHubError(message: problem + " Run `gh auth refresh` if your access changed."))
        }
        return .success(GitHubClient(root: root, repo: GitHubRepo(slug: slug, remote: "origin", isUpstream: false)))
    }

    private static func lookup(_ target: IssueSyncTarget, client: GitHubClient) async -> IssueSyncRemote {
        let output = await GitHubClient.execute(["api", "repos/\(client.repo.slug)/issues/\(target.number)"], in: client.root, timeout: 30)
        guard output.status == 0 else {
            // gh's one-line summary ("gh: Not Found (HTTP 404)"); the API's JSON body on stdout is never shown.
            return .failure(message: String(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
        }
        return .parse(json: output.stdout)
    }
}

/// Reads Features and Bugs from disk at the time of the run (never a cached copy).
enum IssueSyncLoader {
    static func items(features: [URL], bugs: [URL]) -> [IssueSyncItem] {
        features.compactMap(feature) + bugs.compactMap(bug)
    }

    /// Explicit fields of the overview and the plan; full issue URLs in the overview and the
    /// feature's own documents.
    static func feature(_ folder: URL) -> IssueSyncItem? {
        guard let feature = Feature.load(folder: folder) else { return nil }
        var fields = explicitFields(feature.front)
        fields += (feature.planFront["issues"]?.list ?? []).compactMap { $0["github"]?.string }
        fields.append(feature.planFront.string("epic"))
        let texts = [feature.overviewBody] + feature.documents.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        return IssueSyncItem(kind: .feature, id: feature.slug, title: feature.title, status: feature.front.string("status"),
                             fieldValues: fields.filter { !$0.isEmpty }, texts: texts)
    }

    static func bug(_ url: URL) -> IssueSyncItem? {
        guard let report = BugReport.load(url), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (front, body) = FrontMatter.split(text)
        return IssueSyncItem(kind: .bug, id: report.key, title: report.title, status: front.string("status"),
                             fieldValues: explicitFields(front), texts: [body])
    }

    private static func explicitFields(_ front: FrontMatter) -> [String] {
        front.strings("issue") + front.strings("issues") + front.strings("github")
    }
}
