import Foundation

/// Connects a local project to GitHub (REQ-003): the signed-in account and its owners, an
/// explicit name and visibility (DEC-010, DEC-017), checks of the target, the local origin and
/// the repository's history, a reviewed initial commit, a linked push, and MarkView's GitHub
/// integration turned on for it (DEC-018, DEC-020). Used right after bootstrap and later from
/// the Git tab or the File menu. Progress is kept in `.dde/github-connection.json`, so a retry
/// continues with the same repository and never creates a second one (DEC-019).
@MainActor
final class GitHubPublisher: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// gh is missing or nobody is signed in.
        case needsSignIn(String)
        /// The folder cannot be published as it is (no Git repository, another origin…).
        case blocked(String)
        case choose
        case checking
        case confirm
        case publishing
        case done(String)
        case failed(String)
    }

    /// What the chosen target is on GitHub.
    enum Target: Equatable {
        case new
        /// Exists and may receive this project: created by MarkView for it, or empty with push access.
        case existing(visibility: String, createdByMarkView: Bool)
    }

    let root: URL
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var account = ""
    @Published private(set) var owners: [String] = []
    @Published var owner = ""
    @Published var name: String
    /// "private" or "public"; nil until the user chooses (DEC-010).
    @Published var visibility: String?
    @Published private(set) var target: Target?
    /// Why the chosen name cannot be used, shown next to it.
    @Published private(set) var targetProblem: String?
    /// The initial commit's review (DEC-018).
    @Published private(set) var files: [String] = []
    @Published var commitMessage = "Initial project specification"
    @Published private(set) var hasCommits = false
    @Published private(set) var branch = "main"
    /// Commit the uncommitted files (always for a first commit; a choice when history exists).
    @Published var commitChanges = true
    /// origin already points to the target: publishing only pushes.
    @Published private(set) var originSet = false
    /// The stage running now, for the progress line.
    @Published private(set) var progress = ""

    /// Turns MarkView's integration on for this folder and reports whether it found the
    /// repository (nil) or why not.
    private let activate: (String) async -> String?
    private var record: GitHubConnectionRecord?

    init(root: URL, activate: @escaping (String) async -> String?) {
        self.root = root
        self.activate = activate
        name = ProjectNaming.suggestedRepoName(root.lastPathComponent)
    }

    var slug: String { owner + "/" + name }

    private var recordURL: URL { root.appendingPathComponent(GitHubConnectionRecord.relativePath) }

    // MARK: Preparing

    func prepare() async {
        phase = .loading
        record = await loadRecord()
        guard await git(["rev-parse", "--is-inside-work-tree"]).status == 0 else {
            phase = .blocked("This folder has no Git repository. Initialize one in the Git tab first.")
            return
        }
        guard GitHubClient.ghPath() != nil else {
            phase = .needsSignIn("The GitHub CLI (gh) is not installed. Install it with `brew install gh`, then check again.")
            return
        }
        do {
            account = try await GitHubClient.account(root: root).login
        } catch {
            phase = .needsSignIn("Sign in to GitHub to create or connect a repository. (\(error.localizedDescription))")
            return
        }
        let orgs = await GitHubClient.execute(["api", "user/orgs", "--jq", ".[].login"], in: root)
        owners = [account] + orgs.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != account }
        if let record {
            owner = record.owner
            name = record.name
            visibility = record.visibility
        } else if owner.isEmpty || !owners.contains(owner) {
            owner = account
        }
        // Origin already set to a GitHub repository: that is the target (never another one).
        let origin = await git(["remote", "get-url", "origin"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !origin.isEmpty {
            guard let existing = OriginState.githubSlug(fromRemoteURL: origin) else {
                phase = .blocked("This project's origin is \(origin), which is not on GitHub. MarkView never replaces an existing remote — remove or rename it first.")
                return
            }
            let parts = existing.split(separator: "/").map(String.init)
            if parts.count == 2 { owner = parts[0]; name = parts[1] }
            if !owners.contains(owner) { owners.append(owner) }
        }
        phase = .choose
    }

    private func loadRecord() async -> GitHubConnectionRecord? {
        let url = recordURL
        return await Task.detached { () -> GitHubConnectionRecord? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(GitHubConnectionRecord.self, from: data)
        }.value
    }

    /// Without this record a retry could create a second repository, so a failed write stops publishing.
    private func saveRecord(_ record: GitHubConnectionRecord) async throws {
        self.record = record
        let url = recordURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try await Task.detached {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// MarkView created a repository for this project that is not pushed yet: the target is fixed,
    /// so renaming cannot leave it behind and create another one (DEC-019).
    var lockedTarget: Bool { record?.createdByMarkView == true && record?.pushed == false }

    // MARK: Checking the target (DEC-010)

    /// Look at the chosen repository, the local origin and what would be committed, then ask for
    /// confirmation. Nothing is written.
    func check() async {
        targetProblem = nil
        if lockedTarget, let record {
            owner = record.owner
            name = record.name
            visibility = record.visibility
        }
        if let problem = ProjectNaming.repoNameProblem(name) { targetProblem = problem; return }
        guard !owner.isEmpty else { targetProblem = "Choose an owner."; return }
        phase = .checking
        let slug = slug
        let origin = await OriginState.of(currentURL: git(["remote", "get-url", "origin"]).stdout, target: slug)
        originSet = origin == .same
        if case .other(let url) = origin {
            phase = .choose
            targetProblem = "This project's origin already points to \(url). MarkView never replaces a remote — choose that repository or remove the remote first."
            return
        }
        let view = await GitHubClient.execute(["api", "repos/\(slug)"], in: root)
        if view.status == 0 {
            let object = (try? JSONSerialization.jsonObject(with: Data(view.stdout.utf8))) as? [String: Any] ?? [:]
            let canPush = (object["permissions"] as? [String: Any])?["push"] as? Bool ?? false
            let existingVisibility = (object["private"] as? Bool ?? true) ? "private" : "public"
            let ours = record?.slug.lowercased() == slug.lowercased() && record?.createdByMarkView == true
            guard canPush else {
                phase = .choose
                targetProblem = "\(slug) already exists and \(account) cannot push to it. Choose another name."
                return
            }
            // A repository this project does not push to yet (no origin for it, not created or
            // pushed by MarkView) must be empty.
            if origin == .none, !ours, !(record?.slug.lowercased() == slug.lowercased() && record?.pushed == true) {
                // Someone else's history is never overwritten or merged into (DEC-010).
                // Only GitHub's "Git Repository is empty" (HTTP 409) counts as empty; any other failure stops.
                let commits = await GitHubClient.execute(["api", "repos/\(slug)/commits?per_page=1"], in: root)
                if commits.status == 0 {
                    phase = .choose
                    targetProblem = "\(slug) already exists and has its own history. MarkView does not publish into it — choose another name."
                    return
                }
                guard commits.stderr.contains("HTTP 409") else {
                    phase = .choose
                    targetProblem = "Could not check whether \(slug) is empty: " + commits.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
            }
            target = .existing(visibility: existingVisibility, createdByMarkView: ours)
            visibility = existingVisibility
        } else if view.stderr.contains("HTTP 404") {
            target = .new
            guard visibility != nil else {
                phase = .choose
                targetProblem = "Choose private or public."
                return
            }
        } else {
            phase = .choose
            targetProblem = "Could not check \(slug): " + view.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        files = GitPublication.changedFiles(porcelainZ: await git(["status", "--porcelain", "-z", "--untracked-files=all"]).stdout)
        hasCommits = await git(["rev-parse", "--verify", "--quiet", "HEAD"]).status == 0
        let head = await git(["symbolic-ref", "--short", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else {
            phase = .choose
            targetProblem = "HEAD is detached. Check out a branch first, then publish it."
            return
        }
        branch = head
        // A new project commits its files; a folder with history only pushes unless the user asks.
        commitChanges = !hasCommits
        if hasCommits && commitMessage == "Initial project specification" { commitMessage = "Update from MarkView" }
        if !hasCommits && files.isEmpty {
            phase = .choose
            targetProblem = "There is nothing to publish yet: the project has no files and no commits."
            return
        }
        phase = .confirm
    }

    // MARK: Publishing (DEC-018, DEC-019, DEC-020)

    func publish() async {
        guard phase == .confirm, let target, let visibility else { return }
        phase = .publishing
        let slug = slug
        var record = self.record?.slug.lowercased() == slug.lowercased() ? self.record! :
            GitHubConnectionRecord(owner: owner, name: name, visibility: visibility, createdByMarkView: false,
                                   committed: false, pushed: false, updated: Date())
        record.updated = Date()
        do { try await saveRecord(record) } catch { return fail("Could not save the connection progress: \(error.localizedDescription)") }

        // 1. The repository — created only when it still does not exist. One that appeared since the
        // check is not taken as ours: Retry checks it again (history, access).
        if target == .new {
            progress = "Creating \(slug) on GitHub…"
            let exists = await GitHubClient.execute(["api", "repos/\(slug)", "--silent"], in: root).status == 0
            if exists && !record.createdByMarkView {
                return fail("\(slug) exists now although it did not a moment ago. Retry to check it again.")
            }
            if !exists {
                let created = await GitHubClient.execute(["repo", "create", slug, "--" + visibility], in: root, timeout: 120)
                guard created.status == 0 else { return fail("Could not create \(slug): " + created.stderr) }
            }
            record.createdByMarkView = true
            do { try await saveRecord(record) } catch { return fail("Could not save the connection progress: \(error.localizedDescription)") }
        }

        // 2. The reviewed initial commit.
        if commitChanges && !files.isEmpty {
            progress = "Committing \(files.count) file\(files.count == 1 ? "" : "s")…"
            let add = await git(["add", "--"] + files)
            guard add.status == 0 else { return fail("git add failed: " + add.stderr) }
            let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = await git(["commit", "-m", message.isEmpty ? "Initial project specification" : message])
            guard commit.status == 0 else {
                return fail("git commit failed: " + (commit.stderr.isEmpty ? commit.stdout : commit.stderr))
            }
            files = []
            hasCommits = true
        }
        record.committed = true
        do { try await saveRecord(record) } catch { return fail("Could not save the connection progress: \(error.localizedDescription)") }

        // 3. origin: added when missing, kept when it is this repository, never replaced.
        let remote = await git(["remote", "get-url", "origin"]).stdout
        switch OriginState.of(currentURL: remote, target: slug) {
        case .other(let url): return fail("origin points to \(url) now; MarkView does not replace it.")
        case .same: break
        case .none:
            let add = await git(["remote", "add", "origin", await remoteURL(slug)])
            guard add.status == 0 else { return fail("git remote add failed: " + add.stderr) }
        }

        // 4. The linked push, verified against GitHub.
        progress = "Pushing \(branch) to \(slug)…"
        let push = await git(credentialArgs + ["push", "-u", "origin", branch], timeout: 180)
        guard push.status == 0 else { return fail("git push failed: " + push.stderr) }
        let local = await git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHead = GitPublication.remoteHead(
            lsRemote: await git(credentialArgs + ["ls-remote", "origin", "refs/heads/\(branch)"], timeout: 60).stdout, branch: branch)
        let upstream = await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitPublication.isPublished(localHead: local, remoteHead: remoteHead, upstream: upstream, branch: branch) else {
            return fail("The push finished, but GitHub does not show \(branch) at the local commit yet. Retry to check again.")
        }
        record.pushed = true
        do { try await saveRecord(record) } catch { return fail("Could not save the connection progress: \(error.localizedDescription)") }

        // 5. MarkView's GitHub features for this repository.
        progress = "Turning on GitHub in MarkView…"
        if let problem = await activate(slug) {
            return fail("Published to \(slug), but MarkView's GitHub features did not start: \(problem)")
        }
        let url = recordURL
        await Task.detached { try? FileManager.default.removeItem(at: url) }.value
        self.record = nil
        progress = ""
        phase = .done(slug)
    }

    /// Back from the confirmation to the choices.
    func back() {
        phase = .choose
    }

    /// After a failure: check again and show the confirmation (with the files as they are now);
    /// the record keeps what already happened, so nothing is created twice.
    func retry() async {
        await check()
    }

    private func fail(_ message: String) {
        progress = ""
        phase = .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Git

    /// The clone URL in the protocol gh is set up for (https by default).
    private func remoteURL(_ slug: String) async -> String {
        let proto = await GitHubClient.execute(["config", "get", "git_protocol", "-h", "github.com"], in: root)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return proto == "ssh" ? "git@github.com:\(slug).git" : "https://github.com/\(slug).git"
    }

    /// HTTPS pushes use gh's own sign-in, as `gh auth setup-git` would configure — for this
    /// command only, without changing the user's git configuration.
    private var credentialArgs: [String] {
        guard let gh = GitHubClient.ghPath() else { return [] }
        return ["-c", "credential.https://github.com.helper=", "-c", "credential.https://github.com.helper=!\"\(gh)\" auth git-credential"]
    }

    private func git(_ arguments: [String], timeout: TimeInterval = 60) async -> GitHubClient.Output {
        await GitHubClient.execute(arguments, in: root, git: true, timeout: timeout)
    }
}
