import Foundation

/// A GitHub repository the workspace talks to: `origin`, or the repository it was forked from.
struct GitHubRepo: Hashable, Sendable {
    /// "owner/name"
    let slug: String
    /// Git remote (name or URL) that pull request heads are fetched from.
    let remote: String
    /// True for the parent of a fork (the `upstream` remote, or GitHub's parent).
    let isUpstream: Bool

    var webURL: URL? { URL(string: "https://github.com/" + slug) }
}

struct GitHubError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Models (the JSON `gh` prints)

struct GHUser: Codable, Hashable, Sendable {
    let login: String
}

struct GHLabel: Codable, Hashable, Sendable {
    let name: String
    var color: String?
}

struct GHComment: Codable, Hashable, Sendable {
    var author: GHUser?
    var body: String
    var createdAt: String?
}

/// A check on a pull request: a check run (status/conclusion) or a commit status (state).
struct GHCheck: Codable, Hashable, Sendable {
    var name: String?
    var context: String?
    var status: String?
    var conclusion: String?
    var state: String?

    var title: String { name ?? context ?? "check" }

    var outcome: GHOutcome {
        if let state {  // commit status
            switch state.uppercased() {
            case "SUCCESS": return .success
            case "PENDING", "EXPECTED": return .running
            default: return .failure
            }
        }
        if (status ?? "").uppercased() != "COMPLETED" { return .running }
        return GHOutcome(conclusion: conclusion)
    }
}

/// How something ended (or that it has not yet).
enum GHOutcome: Sendable {
    case success, failure, running, neutral

    init(conclusion: String?) {
        switch (conclusion ?? "").lowercased() {
        case "success": self = .success
        case "failure", "timed_out", "startup_failure", "action_required": self = .failure
        case "": self = .running
        default: self = .neutral  // cancelled, skipped, neutral, stale
        }
    }

    init(status: String?, conclusion: String?) {
        if (status ?? "").lowercased() != "completed" { self = .running } else { self.init(conclusion: conclusion) }
    }
}

struct GHPullRequest: Codable, Identifiable, Hashable, Sendable {
    var id: Int { number }
    let number: Int
    var title: String
    var author: GHUser?
    var headRefName: String
    var baseRefName: String
    var state: String
    var isDraft: Bool?
    var url: String
    var createdAt: String?
    var updatedAt: String?
    var reviewDecision: String?
    var statusCheckRollup: [GHCheck]?
    var comments: [GHComment]?
    var mergeable: String?
    var headRefOid: String?

    static let listFields = "number,title,author,headRefName,baseRefName,state,isDraft,url,createdAt,updatedAt,reviewDecision,statusCheckRollup,comments"

    var checks: [GHCheck] { statusCheckRollup ?? [] }
    var passedChecks: Int { checks.filter { $0.outcome == .success }.count }

    /// Worst outcome of the checks, nil without checks.
    var checksOutcome: GHOutcome? {
        guard !checks.isEmpty else { return nil }
        if checks.contains(where: { $0.outcome == .failure }) { return .failure }
        if checks.contains(where: { $0.outcome == .running }) { return .running }
        return .success
    }
}

struct GHIssue: Codable, Identifiable, Hashable, Sendable {
    var id: Int { number }
    let number: Int
    var title: String
    var state: String
    var author: GHUser?
    var labels: [GHLabel]?
    var assignees: [GHUser]?
    var createdAt: String?
    var updatedAt: String?
    var comments: [GHComment]?
    var url: String
    var body: String?

    static let listFields = "number,title,state,author,labels,assignees,createdAt,updatedAt,comments,url"
    static let viewFields = listFields + ",body"

    var isOpen: Bool { state.uppercased() == "OPEN" }
}

struct GHRun: Codable, Identifiable, Hashable, Sendable {
    var id: Int { databaseId }
    let databaseId: Int
    var number: Int
    var name: String?
    var displayTitle: String
    var workflowName: String
    var workflowDatabaseId: Int?
    var status: String
    var conclusion: String?
    var headBranch: String
    var event: String
    var createdAt: String
    var startedAt: String?
    var updatedAt: String?
    var url: String
    var attempt: Int?

    static let fields = "databaseId,number,name,displayTitle,workflowName,workflowDatabaseId,status,conclusion,headBranch,event,createdAt,startedAt,updatedAt,url,attempt"

    var outcome: GHOutcome { GHOutcome(status: status, conclusion: conclusion) }
    var isActive: Bool { outcome == .running }

    /// Seconds the run took (or has taken so far).
    var duration: TimeInterval? {
        guard let start = GHDate.parse(startedAt ?? createdAt) else { return nil }
        let end = isActive ? Date() : (GHDate.parse(updatedAt) ?? Date())
        return max(0, end.timeIntervalSince(start))
    }
}

struct GHStep: Codable, Hashable, Sendable {
    var name: String
    var number: Int
    var status: String
    var conclusion: String?
    var startedAt: String?
    var completedAt: String?

    var outcome: GHOutcome { GHOutcome(status: status, conclusion: conclusion) }
    var duration: TimeInterval? { GHDate.span(startedAt, completedAt, running: outcome == .running) }
}

struct GHJob: Codable, Identifiable, Hashable, Sendable {
    var id: Int { databaseId }
    let databaseId: Int
    var name: String
    var status: String
    var conclusion: String?
    var startedAt: String?
    var completedAt: String?
    var url: String?
    var steps: [GHStep]?

    var outcome: GHOutcome { GHOutcome(status: status, conclusion: conclusion) }
    var duration: TimeInterval? { GHDate.span(startedAt, completedAt, running: outcome == .running) }
}

struct GHWorkflow: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var path: String
    var state: String
}

/// One `workflow_dispatch` input, read from the workflow file.
struct GHWorkflowInput: Hashable, Sendable {
    var name: String
    var description: String?
    var required: Bool
    var defaultValue: String?
    /// string | boolean | choice | number | environment
    var type: String
    var options: [String]
}

/// Dates as `gh` prints them (ISO 8601; the zero date for "not yet").
enum GHDate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, !text.hasPrefix("0001-") else { return nil }
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text) ?? fractional.date(from: text)
    }

    static func span(_ start: String?, _ end: String?, running: Bool) -> TimeInterval? {
        guard let from = parse(start) else { return nil }
        let to = parse(end) ?? (running ? Date() : nil)
        return to.map { max(0, $0.timeIntervalSince(from)) }
    }

    /// "4:12", "1:02:40"
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "5m ago", "2h ago", "3d ago"
    static func ago(_ text: String?) -> String {
        guard let date = parse(text) else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        case ..<2_592_000: return "\(seconds / 86_400)d ago"
        default: return "\(seconds / 2_592_000)mo ago"
        }
    }
}

// MARK: - The `gh` command

/// Runs the GitHub CLI for one repository. Everything happens off the main thread; both
/// pipes are drained while `gh` runs, so a large answer (logs, diffs) cannot deadlock it.
struct GitHubClient: Sendable {
    let root: URL
    let repo: GitHubRepo

    /// `gh` on the PATH the AI CLIs get (Homebrew and friends), or nil.
    static func ghPath() -> String? {
        let path = CLIToolLocator.subprocessPath(toolPath: nil)
        return path.split(separator: ":").map { $0 + "/gh" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run `gh` (or, with `git: true`, git) in `root`. Never waits for a prompt: stdin is
    /// closed and git's terminal prompt is off. The blocking reads run on GCD threads, not on
    /// Swift's small cooperative pool, and a process that hangs (offline, stalled proxy) is
    /// terminated after `timeout` seconds.
    static func execute(_ arguments: [String], in root: URL, git: Bool = false, timeout: TimeInterval = 60) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(arguments, in: root, git: git, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in root: URL, git: Bool, timeout: TimeInterval) -> Output {
        let path = CLIToolLocator.subprocessPath(toolPath: nil)
        let process = Process()
        if git {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        } else {
            guard let gh = ghPath() else {
                return Output(status: -1, stdout: "", stderr: "GitHub CLI (gh) is not installed. Install it with `brew install gh`.")
            }
            process.executableURL = URL(fileURLWithPath: gh)
        }
        process.arguments = arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["NO_COLOR"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let timedOut = TimeoutFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        // Drain stderr concurrently so neither pipe can fill up and block the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        if timedOut.isSet {
            return Output(status: -1, stdout: "", stderr: "GitHub did not answer within \(Int(timeout)) s (offline?).")
        }
        return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// `gh …` for this repository; throws with gh's own message when it fails.
    @discardableResult
    func gh(_ arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        let output = await Self.execute(arguments, in: root, timeout: timeout)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError(message: message.isEmpty ? "gh \(arguments.first ?? "") failed" : String(message.prefix(400)))
        }
        return output.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        let text = try await gh(arguments)
        do { return try JSONDecoder().decode(T.self, from: Data(text.utf8)) } catch {
            throw GitHubError(message: "Unexpected answer from gh: \(error.localizedDescription)")
        }
    }

    private var r: [String] { ["-R", repo.slug] }

    // MARK: Repository and account

    /// GitHub repositories of the checkout at `root`: `origin`, then the repository it was
    /// forked from (`upstream` remote, or GitHub's parent fetched by URL).
    static func detectRepos(root: URL) async -> [GitHubRepo] {
        let remotes = await execute(["remote", "-v"], in: root, git: true)
        guard remotes.status == 0 else { return [] }
        var slugs: [String: String] = [:]  // remote name → slug
        for line in remotes.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let slug = slug(fromRemoteURL: String(parts[1])) else { continue }
            slugs[String(parts[0])] = slug
        }
        var repos: [GitHubRepo] = []
        if let origin = slugs["origin"] ?? slugs.values.sorted().first {
            repos.append(GitHubRepo(slug: origin, remote: slugs["origin"] != nil ? "origin" : (slugs.first { $0.value == origin }?.key ?? "origin"), isUpstream: false))
        }
        if let upstream = slugs["upstream"], upstream != repos.first?.slug {
            repos.append(GitHubRepo(slug: upstream, remote: "upstream", isUpstream: true))
        } else if let origin = repos.first {
            let view = await execute(["repo", "view", origin.slug, "--json", "parent"], in: root)
            if view.status == 0,
               let object = try? JSONSerialization.jsonObject(with: Data(view.stdout.utf8)) as? [String: Any],
               let parent = object["parent"] as? [String: Any],
               let owner = (parent["owner"] as? [String: Any])?["login"] as? String,
               let name = parent["name"] as? String {
                let slug = owner + "/" + name
                repos.append(GitHubRepo(slug: slug, remote: "https://github.com/\(slug).git", isUpstream: true))
            }
        }
        return repos
    }

    /// "owner/name" from git@github.com:owner/name.git or https://github.com/owner/name(.git).
    static func slug(fromRemoteURL url: String) -> String? {
        guard let range = url.range(of: #"github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?/?$"#, options: .regularExpression) else { return nil }
        var tail = String(url[range]).dropFirst("github.com".count + 1)
        if tail.hasSuffix("/") { tail = tail.dropLast() }
        if tail.hasSuffix(".git") { tail = tail.dropLast(4) }
        return String(tail)
    }

    struct Account: Sendable {
        let login: String
        let scopes: [String]
    }

    /// The signed-in account and its token's scopes.
    static func account(root: URL) async throws -> Account {
        let output = await execute(["api", "-i", "user"], in: root)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubError(message: message.isEmpty ? "Not signed in to GitHub." : message)
        }
        var scopes: [String] = []
        var login = ""
        let parts = output.stdout.components(separatedBy: "\r\n\r\n")
        for line in (parts.first ?? "").components(separatedBy: "\r\n") where line.lowercased().hasPrefix("x-oauth-scopes:") {
            scopes = line.dropFirst("x-oauth-scopes:".count).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let body = parts.dropFirst().joined(separator: "\r\n\r\n").data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            login = object["login"] as? String ?? ""
        }
        return Account(login: login, scopes: scopes)
    }

    // MARK: Pull requests

    enum PRFilter: String, CaseIterable, Sendable { case all = "All", mine = "Mine", reviewRequested = "Review requested" }

    func pullRequests(state: String, filter: PRFilter) async throws -> [GHPullRequest] {
        var args = ["pr", "list"] + r + ["--state", state, "--limit", "100", "--json", GHPullRequest.listFields]
        switch filter {
        case .all: break
        case .mine: args += ["--author", "@me"]
        case .reviewRequested: args += ["--search", "review-requested:@me"]
        }
        return try await decode([GHPullRequest].self, args)
    }

    func pullRequest(_ number: Int) async throws -> GHPullRequest {
        try await decode(GHPullRequest.self, ["pr", "view", String(number)] + r
            + ["--json", GHPullRequest.listFields + ",mergeable,headRefOid"])
    }

    /// Check the pull request out into the working copy (`gh pr checkout`).
    func checkout(_ number: Int) async throws {
        try await gh(["pr", "checkout", String(number)] + r)
    }

    /// approve | request-changes | comment
    func review(_ number: Int, action: String, body: String) async throws {
        guard ["approve", "request-changes", "comment"].contains(action) else { throw GitHubError(message: "Unknown review action.") }
        var args = ["pr", "review", String(number)] + r + ["--" + action]
        if !body.isEmpty { args += ["--body", body] }
        try await gh(args)
    }

    /// merge | squash | rebase
    static let mergeMethods: Set<String> = ["merge", "squash", "rebase"]

    func merge(_ number: Int, method: String) async throws {
        guard Self.mergeMethods.contains(method) else { throw GitHubError(message: "Unknown merge method \(method).") }
        try await gh(["pr", "merge", String(number)] + r + ["--" + method])
    }

    func closePR(_ number: Int) async throws {
        try await gh(["pr", "close", String(number)] + r)
    }

    func commentPR(_ number: Int, body: String) async throws {
        try await gh(["pr", "comment", String(number)] + r + ["--body", body])
    }

    /// A review comment on one line of the pull request's new code.
    func lineComment(_ number: Int, commit: String, path: String, line: Int, body: String) async throws {
        try await gh(["api", "repos/\(repo.slug)/pulls/\(number)/comments", "-X", "POST",
                      "-f", "body=\(body)", "-f", "commit_id=\(commit)", "-f", "path=\(path)",
                      "-F", "line=\(line)", "-f", "side=RIGHT"])
    }

    /// Open a pull request from `head` (already pushed); returns its URL.
    func createPR(title: String, body: String, base: String, head: String, draft: Bool) async throws -> String {
        var args = ["pr", "create"] + r + ["--title", title, "--body", body, "--base", base, "--head", head]
        if draft { args.append("--draft") }
        return try await gh(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Issues

    enum IssueFilter: String, CaseIterable, Sendable { case all = "All", assigned = "Assigned to me", created = "Created by me" }

    func issues(state: String, filter: IssueFilter) async throws -> [GHIssue] {
        var args = ["issue", "list"] + r + ["--state", state, "--limit", "100", "--json", GHIssue.listFields]
        switch filter {
        case .all: break
        case .assigned: args += ["--assignee", "@me"]
        case .created: args += ["--author", "@me"]
        }
        return try await decode([GHIssue].self, args)
    }

    func issue(_ number: Int) async throws -> GHIssue {
        try await decode(GHIssue.self, ["issue", "view", String(number)] + r + ["--json", GHIssue.viewFields])
    }

    func commentIssue(_ number: Int, body: String) async throws {
        try await gh(["issue", "comment", String(number)] + r + ["--body", body])
    }

    func setIssueOpen(_ number: Int, open: Bool) async throws {
        try await gh(["issue", open ? "reopen" : "close", String(number)] + r)
    }

    /// Add or remove labels and assignees.
    func editIssue(_ number: Int, addLabels: [String] = [], removeLabels: [String] = [],
                   addAssignees: [String] = [], removeAssignees: [String] = []) async throws {
        var args = ["issue", "edit", String(number)] + r
        for label in addLabels { args += ["--add-label", label] }
        for label in removeLabels { args += ["--remove-label", label] }
        for user in addAssignees { args += ["--add-assignee", user] }
        for user in removeAssignees { args += ["--remove-assignee", user] }
        try await gh(args)
    }

    /// Create an issue; returns its URL.
    func createIssue(title: String, body: String, labels: [String] = []) async throws -> String {
        var args = ["issue", "create"] + r + ["--title", title, "--body", body]
        for label in labels { args += ["--label", label] }
        return try await gh(args).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func labels() async throws -> [GHLabel] {
        try await decode([GHLabel].self, ["label", "list"] + r + ["--limit", "200", "--json", "name,color"])
    }

    /// People issues can be assigned to.
    func assignableUsers() async throws -> [String] {
        let text = try await gh(["api", "repos/\(repo.slug)/assignees", "--paginate", "--jq", ".[].login"])
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Actions

    func runs(workflow: Int?, branch: String?) async throws -> [GHRun] {
        var args = ["run", "list"] + r + ["--limit", "50", "--json", GHRun.fields]
        if let workflow { args += ["--workflow", String(workflow)] }
        if let branch, !branch.isEmpty { args += ["--branch", branch] }
        return try await decode([GHRun].self, args)
    }

    func run(_ id: Int) async throws -> GHRun {
        try await decode(GHRun.self, ["run", "view", String(id)] + r + ["--json", GHRun.fields])
    }

    func jobs(run id: Int) async throws -> [GHJob] {
        struct Jobs: Decodable { let jobs: [GHJob] }
        return try await decode(Jobs.self, ["run", "view", String(id)] + r + ["--json", "jobs"]).jobs
    }

    /// A finished job's whole log (GitHub serves logs once the job is complete).
    func jobLog(_ jobId: Int) async throws -> String {
        try await gh(["api", "repos/\(repo.slug)/actions/jobs/\(jobId)/logs"], timeout: 180)
    }

    func rerun(_ id: Int, failedOnly: Bool) async throws {
        try await gh(["run", "rerun", String(id)] + r + (failedOnly ? ["--failed"] : []))
    }

    func cancel(_ id: Int) async throws {
        try await gh(["run", "cancel", String(id)] + r)
    }

    func workflows() async throws -> [GHWorkflow] {
        try await decode([GHWorkflow].self, ["workflow", "list"] + r + ["--all", "--json", "id,name,path,state"])
    }

    /// Start a `workflow_dispatch` workflow on `ref` with `inputs`.
    func dispatch(workflow: Int, ref: String, inputs: [String: String]) async throws {
        var args = ["workflow", "run", String(workflow)] + r + ["--ref", ref]
        for (key, value) in inputs.sorted(by: { $0.key < $1.key }) { args += ["-f", "\(key)=\(value)"] }
        try await gh(args)
    }

    /// The workflow file as it is on the default branch.
    func workflowFile(_ path: String) async throws -> String {
        let text = try await gh(["api", "repos/\(repo.slug)/contents/\(path)", "-H", "Accept: application/vnd.github.raw"])
        return text
    }
}

// MARK: - Workflow files and logs

enum GHWorkflowFile {
    /// Whether the workflow can be started by hand, and its inputs. A small reader for the
    /// `on: workflow_dispatch: inputs:` block (indentation-based, no YAML library).
    static func dispatchInputs(_ yaml: String) -> (dispatchable: Bool, inputs: [GHWorkflowInput]) {
        let lines = yaml.components(separatedBy: "\n").map { line -> String in
            // Drop comments that are not inside quotes (good enough for keys and scalars).
            guard let hash = line.range(of: " #") else { return line.hasPrefix("#") ? "" : line }
            return String(line[..<hash.lowerBound])
        }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func keyValue(_ line: String) -> (String, String)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let key = trimmed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'-"))
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (key, unquote(value))
        }
        guard let dispatchIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("workflow_dispatch")
                || $0.contains("[") && $0.contains("workflow_dispatch")
                || $0.trimmingCharacters(in: .whitespaces) == "on: workflow_dispatch"
        }) else { return (false, []) }
        let base = indent(lines[dispatchIndex])
        var i = dispatchIndex + 1
        // Find "inputs:" inside the workflow_dispatch block.
        var inputsIndent: Int?
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if indent(line) <= base { break }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("inputs:") { inputsIndent = indent(line); i += 1; break }
            i += 1
        }
        guard let inputsIndent else { return (true, []) }
        var inputs: [GHWorkflowInput] = []
        var current: GHWorkflowInput?
        var nameIndent: Int?
        var inOptions = false
        while i < lines.count {
            let line = lines[i]; i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let level = indent(line)
            if level <= inputsIndent { break }
            if nameIndent == nil || level == nameIndent {
                if let current { inputs.append(current) }
                nameIndent = level
                let name = trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : (keyValue(line)?.0 ?? trimmed)
                current = GHWorkflowInput(name: unquote(name), description: nil, required: false, defaultValue: nil, type: "string", options: [])
                inOptions = false
                continue
            }
            if inOptions, trimmed.hasPrefix("- ") {
                current?.options.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            inOptions = false
            guard let (key, value) = keyValue(line) else { continue }
            switch key {
            case "description": current?.description = value
            case "required": current?.required = value.lowercased() == "true"
            case "default": current?.defaultValue = value
            case "type": current?.type = value
            case "options":
                if value.hasPrefix("[") {
                    current?.options = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                } else { inOptions = true }
            default: break
            }
        }
        if let current { inputs.append(current) }
        return (true, inputs)
    }

    private static func unquote(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}

/// One line of a job log, without its timestamp.
struct GHLogLine: Hashable, Sendable {
    let index: Int
    let text: String
    /// ##[error] lines and compiler-style "error:" lines.
    let isError: Bool
    let isWarning: Bool
}

enum GHJobLog {
    /// Split a job's log into its steps. The log marks where steps begin: after "Set up job"
    /// each step opens with a top-level `##[group]Run …` line, post steps with "Post job
    /// cleanup.", and "Complete job" with "Cleaning up orphan processes". Steps are walked in
    /// order; a `Run` marker only moves on once the next step has started (by the steps'
    /// whole-second times), so the inner steps of composite actions stay in their step.
    static func split(_ log: String, steps: [GHStep]) -> [Int: [GHLogLine]] {
        // Skipped steps print nothing.
        let ran = steps.filter { ($0.conclusion ?? "").lowercased() != "skipped" }
        var result: [Int: [GHLogLine]] = [:]
        var position = 0
        var index = 0
        func isPost(_ step: GHStep) -> Bool { step.name.hasPrefix("Post ") }
        func isComplete(_ step: GHStep) -> Bool { step.name == "Complete job" }
        func advance(where match: (GHStep) -> Bool, at date: Date?) {
            guard let next = ran.indices.first(where: { $0 > position && match(ran[$0]) }) else { return }
            if let date, let start = GHDate.parse(ran[next].startedAt), date < start { return }
            position = next
        }
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.hasSuffix("\r") { line.removeLast() }
            var text = line
            var date: Date?
            if line.count > 29, line.dropFirst(4).first == "-", let space = line.firstIndex(of: " ") {
                date = parseStamp(String(line[..<space]))
                text = String(line[line.index(after: space)...])
            }
            if text.hasPrefix("##[group]Run ") {
                advance(where: { !isPost($0) && !isComplete($0) }, at: date)
            } else if text == "Post job cleanup." {
                advance(where: isPost, at: nil)
            } else if text.hasPrefix("Cleaning up orphan processes") {
                advance(where: isComplete, at: nil)
            }
            if text == "##[endgroup]" { continue }
            let lower = text.lowercased()
            let isError = text.hasPrefix("##[error]") || lower.contains(" error:") || lower.hasPrefix("error:")
                || lower.contains("** build failed **") || lower.contains("fatal:")
            let isWarning = !isError && (text.hasPrefix("##[warning]") || lower.contains(" warning:"))
            // Workflow commands as readable text.
            for (marker, replacement) in [("##[group]", "▸ "), ("##[error]", "Error: "), ("##[warning]", "Warning: "),
                                          ("##[notice]", "Notice: "), ("##[debug]", "")] where text.hasPrefix(marker) {
                text = replacement + text.dropFirst(marker.count)
            }
            let step = ran.isEmpty ? 0 : ran[position].number
            result[step, default: []].append(GHLogLine(index: index, text: text, isError: isError, isWarning: isWarning))
            index += 1
        }
        return result
    }

    private static let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    /// "2026-09-25T11:51:34.4762030Z" (7 fraction digits) → Date.
    private static func parseStamp(_ stamp: String) -> Date? {
        guard stamp.hasSuffix("Z"), let dot = stamp.firstIndex(of: ".") else { return GHDate.parse(stamp) }
        let fraction = stamp[stamp.index(after: dot)..<stamp.index(before: stamp.endIndex)]
        let trimmed = String(stamp[..<dot]) + "." + fraction.prefix(3) + "Z"
        lock.lock(); defer { lock.unlock() }
        return stampFormatter.date(from: trimmed)
    }
}
