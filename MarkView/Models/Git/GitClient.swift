import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Git integration — status, diff, commit, push/pull
@MainActor
class GitClient: ObservableObject {
    @Published var isGitRepo = false
    @Published var branch = ""
    /// Local branches, most recently committed first.
    @Published var localBranches: [String] = []
    /// Remote branches ("origin/x") with no local branch of the same name, most recent first.
    @Published var remoteBranches: [String] = []
    /// Every working copy of this repository (the open folder is one of them), main checkout first.
    @Published var worktrees: [GitWorktree] = []
    @Published var changedFiles: [GitFileStatus] = []
    /// Everything Git says about the work tree: changes, untracked, conflicts and (when asked) ignored paths.
    @Published var repoStatus = GitRepoStatus.empty
    /// Tracked files without a change; loaded only while `showTracked` is on.
    @Published var cleanTracked: [String] = []
    @Published var stashCount = 0
    /// What Git is in the middle of: "merge", "rebase", "cherry-pick" or "revert" (nil = nothing).
    @Published var operationInProgress: String?
    /// The Git tab lists the ignored paths on request; the file tree always knows them (a big ignored
    /// tree such as node_modules is a single entry).
    @Published var showIgnored = false
    @Published var showTracked = false { didSet { if showTracked != oldValue { startRefresh() } } }
    @Published var commitLog: [GitCommit] = []
    @Published private(set) var hasMoreCommits = false
    @Published private(set) var loadingHistory = false
    private var historyLimit = 200
    @Published var isOperating = false
    /// What a running operation is doing, in words ("Pushing…"), for the progress line of the Git tab.
    @Published var activity: String?
    @Published var lastError: String?

    /// Why the last branch operation of the Git tab failed; nil when it went through or has been read.
    @Published private(set) var branchFailure: String?
    /// The last commit the Git tab's commit bar made: the bar clears its draft when it sees its own message come back.
    @Published private(set) var lastCommit: CommitReceipt?

    var workingDirectory: URL?
    /// The current branch, sent after every refresh (the GitHub store of the window follows it).
    let branchReports = PassthroughSubject<String, Never>()
    /// What the client started for itself or for the Git tab (`AR-19`): the looks at the repository and the operations the person
    /// started. `close` cancels them with the window, and so does a change of folder.
    private let tasks = TaskBag()
    /// Operations are keyed one by one: a second `git add` must not end the first, so none replaces another.
    private var operationSerial = 0

    struct CommitReceipt: Equatable {
        let id = UUID()
        let message: String
    }

    struct GitFileStatus: Identifiable {
        let id = UUID()
        let status: String  // M, A, D, ?, etc.
        let file: String
        var isStaged: Bool

        var statusIcon: String {
            switch status {
            case "M": return "pencil.circle"
            case "A", "?": return "plus.circle"
            case "D": return "minus.circle"
            case "R": return "arrow.right.circle"
            default: return "circle"
            }
        }

        var statusColor: String {
            switch status {
            case "M": return "orange"
            case "A", "?": return "green"
            case "D": return "red"
            default: return "textDim"
            }
        }
    }

    struct GitCommit: Identifiable {
        var id: String { hash }
        let hash: String
        let message: String
        let author: String
        let date: String
        let parents: [String]
        let refs: String
    }

    /// The one-line status the file tree and the commit bar use: staged wins over unstaged.
    private static func changedFile(_ entry: GitStatusEntry) -> GitFileStatus? {
        switch entry.special {
        case .ignored?: return nil
        case .untracked?: return GitFileStatus(status: "U", file: entry.path, isStaged: false)
        case .conflicted?: return GitFileStatus(status: "!", file: entry.path, isStaged: false)
        default:
            if let index = entry.index { return GitFileStatus(status: index.letter, file: entry.path, isStaged: true) }
            if let worktree = entry.worktree { return GitFileStatus(status: worktree.letter, file: entry.path, isStaged: false) }
            return nil
        }
    }

    // MARK: - Setup

    func setup(at url: URL) {
        workingDirectory = url
        startRefresh()
    }

    /// Forget the repository, e.g. when the workspace folder is closed. What was started for it stops: an answer about the old folder
    /// never lands.
    func reset() {
        tasks.cancelAll()
        workingDirectory = nil
        isGitRepo = false
        branch = ""
        localBranches = []
        remoteBranches = []
        worktrees = []
        changedFiles = []
        repoStatus = .empty
        operationInProgress = nil
        cleanTracked = []
        stashCount = 0
        commitLog = []
        historyLimit = 200
        hasMoreCommits = false
        lastError = nil
    }

    /// The window closes: the looks and the operations the client started end with it.
    func close() { tasks.cancelAll() }

    // MARK: - Starting work (`AR-19`)

    /// Looks at the repository again. A look that is still running is replaced by this one.
    func startRefresh() {
        tasks.store(Task { await refresh() }, for: "refresh")
    }

    /// Lists more of the history. A request that is still running is replaced by this one.
    func startLoadMoreHistory() {
        tasks.store(Task { await loadMoreHistory() }, for: "history")
    }

    /// `git init` in the folder, then a look.
    func startInit() { start { await self.initRepo() } }

    func startPull() { startTransfer { _ = await self.pull() } }

    func startPush() { startTransfer { _ = await self.push() } }

    /// Commits what is staged (or `paths` only), then pushes when asked and the commit went through; the receipt tells the commit bar to
    /// clear its message.
    func startCommit(message: String, paths: [String]? = nil, thenPush: Bool = false) {
        start {
            let committed: Bool
            if let paths { committed = await self.commit(paths: paths, message: message) }
            else { committed = await self.commit(message: message) }
            guard committed, !Task.isCancelled else { return }
            self.lastCommit = CommitReceipt(message: message)
            if thenPush { _ = await self.push() }
        }
    }

    /// A branch operation (create or switch) the Git tab started: `work` returns what to tell the person when it went wrong.
    func startBranchOperation(_ work: @escaping () async -> String?) {
        start {
            let failure = await work()
            guard !Task.isCancelled else { return }
            self.branchFailure = failure
        }
    }

    /// The person has read why the last branch operation failed.
    func dismissBranchFailure() { branchFailure = nil }

    /// Takes one side of a conflicted file, then stages it.
    func startResolve(_ path: String, taking side: String) { start { await self.resolve(path, taking: side) } }

    /// Adds `path` to the repository's `.gitignore`.
    func startIgnore(_ path: String, isDirectory: Bool) { start { await self.ignore(path, isDirectory: isDirectory) } }

    /// Runs `work` as an operation of its own: the person asked for it, so no later request replaces it; only the close of the window
    /// (or the folder) ends it.
    private func start(_ work: @escaping () async -> Void) {
        operationSerial += 1
        tasks.store(Task { await work() }, for: "operation-\(operationSerial)")
    }

    /// A push or a pull: a second one asked for while one is running is dropped, and never replaces it, since ending a transfer
    /// half way is worse than waiting for it.
    private func startTransfer(_ work: @escaping () async -> Void) {
        guard !tasks.contains(key: "transfer") else { return }
        tasks.store(Task { await work() }, for: "transfer")
    }

    // MARK: - Refresh

    func refresh() async {
        guard let dir = workingDirectory, !Task.isCancelled else { return }

        // Check if git repo
        let gitDir = dir.appendingPathComponent(".git")
        isGitRepo = FileManager.default.fileExists(atPath: gitDir.path)
        if !isGitRepo {
            // Check parent dirs
            var check = dir.deletingLastPathComponent()
            for _ in 0..<5 {
                if FileManager.default.fileExists(atPath: check.appendingPathComponent(".git").path) {
                    isGitRepo = true
                    break
                }
                check = check.deletingLastPathComponent()
            }
        }
        guard isGitRepo else { return }

        // Branch
        let current = (await run("git", "rev-parse", "--abbrev-ref", "HEAD", in: dir) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The window closed or the folder changed while git was asked: the answer is of no one now.
        guard !Task.isCancelled else { return }
        branch = current
        branchReports.send(branch)
        await loadBranches(in: dir)
        await loadWorktrees(in: dir)

        await refreshStatus()

        await loadHistory(in: dir)

    }

    func loadMoreHistory() async {
        guard let dir = workingDirectory, !loadingHistory else { return }
        historyLimit += 200
        await loadHistory(in: dir)
    }

    private func loadHistory(in dir: URL) async {
        loadingHistory = true
        defer { loadingHistory = false }
        let limit = historyLimit, branchAtStart = branch
        let logOutput = await run("git", "log", "--all", "HEAD", "--topo-order", "--format=%H%x1f%s%x1f%an%x1f%ar%x1f%P%x1f%D%x1e", "-\(limit + 1)", in: dir) ?? ""
        guard !Task.isCancelled else { return }
        let commits: [GitCommit] = logOutput.components(separatedBy: "\u{1e}").compactMap { record in
            let parts = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard parts.count == 6, !parts[0].isEmpty else { return nil }
            return GitCommit(hash: parts[0], message: parts[1], author: parts[2], date: parts[3],
                             parents: parts[4].split(separator: " ").map(String.init), refs: parts[5])
        }
        guard workingDirectory == dir, historyLimit == limit, branch == branchAtStart else { return }
        hasMoreCommits = commits.count > limit
        commitLog = Array(commits.prefix(limit))
    }

    /// Only the work tree's state (no branches or log): cheap enough to repeat while the app is in front.
    func refreshStatus() async {
        guard let dir = workingDirectory, isGitRepo else { return }
        // Status — porcelain v2 with every untracked file and the ignored paths.
        let statusArgs = ["git", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignored=matching"]
        let parsed = GitRepoStatus.parse(await run(statusArgs, in: dir) ?? "")
        guard !Task.isCancelled else { return }
        let changed = parsed != repoStatus
        // The branch moved under us (an agent or a terminal switched it): the header, the branch lists and
        // the log follow, not just the file rows.
        let branchMoved = !repoStatus.head.isEmpty && !parsed.head.isEmpty && parsed.head != repoStatus.head
        if changed {
            repoStatus = parsed
            changedFiles = parsed.entries.compactMap(Self.changedFile)
        }
        if branchMoved {
            branch = parsed.head == "(detached)" ? "HEAD" : parsed.head
            branchReports.send(branch)
            tasks.store(Task { await refresh() }, for: "branch-moved")
        }
        let current = Self.operation(in: dir)
        if current != operationInProgress { operationInProgress = current }
        let stashes = (await run(["git", "stash", "list"], in: dir) ?? "").split(separator: "\n").count
        guard !Task.isCancelled else { return }
        if stashes != stashCount { stashCount = stashes }
        if showTracked {
            let listing = await run(["git", "ls-files", "-z"], in: dir) ?? ""
            guard !Task.isCancelled else { return }
            cleanTracked = GitRepoStatus.cleanTracked(lsFiles: listing, changed: parsed.changedPaths)
        } else if !cleanTracked.isEmpty {
            cleanTracked = []
        }
    }

    /// A merge, rebase, cherry-pick or revert that stopped (its marker is in the repository's .git folder).
    nonisolated private static func operation(in dir: URL) -> String? {
        let git = dir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let markers = [("MERGE_HEAD", "merge"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
                       ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")]
        return markers.first { FileManager.default.fileExists(atPath: git.appendingPathComponent($0.0).path) }?.1
    }

    // MARK: - Operations

    func stageFile(_ file: String) {
        mutate(["add", "--", file], activity: "Staging…")
    }

    func unstageFile(_ file: String) {
        mutate(["reset", "-q", "HEAD", "--", file], activity: "Unstaging…")
    }

    func stageAll() {
        mutate(["add", "-A"], activity: "Staging everything…")
    }

    /// Run a git command that changes the repository and refresh; a failure is shown, not swallowed.
    private func mutate(_ args: [String], activity label: String) {
        guard let dir = workingDirectory else { return }
        lastError = nil
        activity = label
        start {
            defer { self.activity = nil }
            let result = await self.execute(["git"] + args, in: dir)
            if result.status != 0, !Task.isCancelled { self.lastError = Self.explain(result) }
            // The state of the files first (one quick call): the rows and tree icons follow at once;
            // branches and the log, which these commands do not change, can wait.
            await self.refreshStatus()
            await self.refresh()
        }
    }

    /// The reason a command failed, in a few lines (git writes it to stderr; a hook may use stdout).
    private static func explain(_ result: (status: Int32, output: String, error: String)) -> String {
        let text = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git failed (exit \(result.status))" : String(text.suffix(600))
    }

    func commit(message: String) async -> Bool {
        guard let dir = workingDirectory, !message.isEmpty else { return false }
        isOperating = true
        activity = "Committing (hooks may run)…"
        lastError = nil
        let result = await execute(["git", "commit", "-m", message], in: dir)
        isOperating = false
        activity = nil
        await refresh()
        guard result.status == 0 else {
            // A hook that rejects the commit, a missing identity, nothing staged: say why and keep the message.
            guard !Task.isCancelled else { return false }
            lastError = result.output.contains("nothing to commit") ? "Nothing to commit" : Self.explain(result)
            return false
        }
        return true
    }

    func push() async -> Bool {
        await transfer(["push"], activity: "Pushing…")
    }

    func pull() async -> Bool {
        await transfer(["pull"], activity: "Pulling…")
    }

    /// Push or pull: the network can take a while, so the progress line says what is going on, and a
    /// failure (rejected, no upstream, a hook) is shown with git's own words.
    private func transfer(_ args: [String], activity label: String) async -> Bool {
        guard let dir = workingDirectory else { return false }
        isOperating = true
        activity = label
        lastError = nil
        let result = await execute(["git"] + args, in: dir)
        isOperating = false
        activity = nil
        guard result.status == 0 else {
            if !Task.isCancelled { lastError = Self.explain(result) }
            await refresh()
            return false
        }
        await refresh()
        return true
    }

    func diff(file: String, staged: Bool = false) async -> String {
        guard let dir = workingDirectory else { return "" }
        if staged { return await run("git", "diff", "--cached", "--", file, in: dir) ?? "" }
        return await run("git", "diff", "--", file, in: dir) ?? ""
    }

    func untrackedDiff(file: String) async -> String {
        guard let dir = workingDirectory else { return "" }
        return await run(["git", "diff", "--no-index", "--", "/dev/null", file], in: dir) ?? ""
    }

    /// Files and patch in a commit, including root commits and merge first-parent changes.
    func commitFiles(_ hash: String) async -> [String] {
        guard let dir = workingDirectory else { return [] }
        let output = await run(["git", "diff-tree", "--root", "-m", "--first-parent", "--no-commit-id", "--name-only", "-r", "-z", hash], in: dir) ?? ""
        return output.split(separator: "\0").map(String.init)
    }

    func commitDiff(_ hash: String, file: String) async -> String {
        guard let dir = workingDirectory else { return "" }
        return await run(["git", "show", "--format=", "--first-parent", "--no-ext-diff", hash, "--", file], in: dir) ?? ""
    }

    // MARK: - Actions on single paths (the Changes list's context menu)

    func stage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        mutate(["add", "--"] + paths, activity: "Staging…")
    }

    func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        mutate(["reset", "-q", "HEAD", "--"] + paths, activity: "Unstaging…")
    }

    /// Stop tracking a file or folder but keep it on disk (`git rm --cached`).
    func untrack(_ path: String) {
        mutate(["rm", "-r", "--cached", "-q", "--", path], activity: "Untracking…")
    }

    /// Resolve a conflicted file by taking one side wholesale (`ours` or `theirs`), then stage it.
    func resolve(_ path: String, taking side: String) async {
        guard let dir = workingDirectory else { return }
        lastError = nil
        activity = "Taking \(side)…"
        defer { activity = nil }
        var result = await execute(["git", "checkout", "--\(side)", "--", path], in: dir)
        if result.status == 0 { result = await execute(["git", "add", "--", path], in: dir) }
        if result.status != 0, !Task.isCancelled { lastError = Self.explain(result) }
        await refreshStatus()
        await refresh()
    }

    /// Commit only these paths (new files are added first); the message is kept by the caller on failure.
    func commit(paths: [String], message: String) async -> Bool {
        guard let dir = workingDirectory, !message.isEmpty, !paths.isEmpty else { return false }
        isOperating = true
        activity = "Committing (hooks may run)…"
        lastError = nil
        var result = await execute(["git", "add", "--"] + paths, in: dir)
        if result.status == 0 { result = await execute(["git", "commit", "-m", message, "--"] + paths, in: dir) }
        isOperating = false
        activity = nil
        await refresh()
        if result.status != 0, !Task.isCancelled { lastError = Self.explain(result) }
        return result.status == 0
    }

    /// Append `/path` (or `/path/`) to the repository's `.gitignore`, once.
    func ignore(_ path: String, isDirectory: Bool) async {
        guard let dir = workingDirectory else { return }
        let top = await run("git", "rev-parse", "--show-toplevel", in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The window closed while git was asked: nothing is written for it now.
        guard !Task.isCancelled else { return }
        let repo = URL(fileURLWithPath: top.isEmpty ? dir.path : top)
        var clean = path
        while clean.hasSuffix("/") { clean.removeLast() }
        let entry = "/" + clean + (isDirectory ? "/" : "")
        let file = repo.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == entry }) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += entry + "\n"
            do { try AtomicFile.write(text, to: file) } catch {
                lastError = "Couldn't update .gitignore: \(error.localizedDescription)"
                return
            }
        }
        await refresh()
    }

    func discardChanges(_ file: String) {
        guard workingDirectory != nil else { return }
        mutate(["checkout", "--", file], activity: "Discarding changes…")
    }

    // MARK: - Branches

    /// The repository's working copies, each with its number of changed paths. A single copy is not worth
    /// listing, so the list stays empty then.
    private func loadWorktrees(in dir: URL) async {
        var list = GitWorktree.parse(await run("git", "worktree", "list", "--porcelain", in: dir) ?? "")
        guard !Task.isCancelled else { return }
        guard list.count > 1 else { worktrees = []; return }
        for index in list.indices where !list[index].isBare {
            let status = await run("git", "status", "--porcelain", "--untracked-files=normal", in: URL(fileURLWithPath: list[index].path))
            list[index].changes = status?.split(separator: "\n").count
        }
        guard !Task.isCancelled else { return }
        worktrees = list
    }

    private func loadBranches(in dir: URL) async {
        let output = await run("git", "for-each-ref", "--sort=-committerdate", "--format=%(refname)",
                               "refs/heads", "refs/remotes", in: dir) ?? ""
        guard !Task.isCancelled else { return }
        var local: [String] = [], remote: [String] = []
        for ref in output.components(separatedBy: "\n") {
            if ref.hasPrefix("refs/heads/") {
                local.append(String(ref.dropFirst("refs/heads/".count)))
            } else if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
                remote.append(String(ref.dropFirst("refs/remotes/".count)))
            }
        }
        localBranches = local
        // A remote branch that already has a local one is reached through the local one.
        remoteBranches = remote.filter { name in
            guard let slash = name.firstIndex(of: "/") else { return false }
            return !local.contains(String(name[name.index(after: slash)...]))
        }
    }

    /// Check out a branch; a remote branch ("origin/x") gets a local tracking branch.
    /// Git refuses when uncommitted changes would be overwritten. Returns an error to show.
    func switchBranch(_ name: String) async -> String? {
        let args = remoteBranches.contains(name) ? ["switch", "--track", name] : ["switch", name]
        return await branchOperation(args, failure: "Could not switch to \(name)")
    }

    /// Create a branch from `base` (the current commit when nil) and check it out.
    /// A new branch does not track its base, so the first push sets its own upstream.
    func createBranch(_ name: String, from base: String?) async -> String? {
        guard let dir = workingDirectory else { return "No folder open." }
        let check = await GitHubClient.execute(["check-ref-format", "--branch", name], in: dir, git: true)
        guard check.status == 0 else { return "“\(name)” is not a valid branch name." }
        var args = ["switch", "--no-track", "-c", name]
        if let base { args.append(base) }
        return await branchOperation(args, failure: "Could not create \(name)")
    }

    private func branchOperation(_ args: [String], failure: String) async -> String? {
        guard let dir = workingDirectory else { return "No folder open." }
        isOperating = true
        activity = args.contains("-c") ? "Creating the branch…" : "Switching branch…"
        lastError = nil
        let result = await GitHubClient.execute(args, in: dir, git: true)
        isOperating = false
        activity = nil
        await refresh()
        guard result.status != 0 else { return nil }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? failure + "." : failure + ": " + String(detail.prefix(300))
    }

    /// A quick check while typing a new branch name; `git check-ref-format` decides on create.
    static func isPlausibleBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.hasSuffix("/")
            && !name.hasSuffix(".") && !name.hasSuffix(".lock") && !name.contains("..")
            && !name.contains("@{") && !name.contains("//")
            && !name.contains(where: { $0.isWhitespace || "~^:?*[\\".contains($0) || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
    }

    // MARK: - Init repo

    func initRepo() async {
        guard let dir = workingDirectory else { return }
        _ = await run("git", "init", in: dir)
        await refresh()
    }

    // MARK: - Helpers

    /// Runs git (through `/usr/bin/env`, which finds it on the PATH) off the main thread with no time limit: the standard
    /// output as text, nil when git could not be started.
    nonisolated private func run(_ args: String..., in dir: URL) async -> String? {
        await run(args, in: dir)
    }

    nonisolated private func run(_ args: [String], in dir: URL) async -> String? {
        let result = await execute(args, in: dir)
        return result.status == -1 ? nil : result.output
    }

    /// Runs git off the main thread and keeps the exit status (-1 when git could not be started), stdout and stderr.
    nonisolated private func execute(_ args: [String], in dir: URL) async -> (status: Int32, output: String, error: String) {
        let result = await Subprocess.run(SubprocessSpec(
            executable: "/usr/bin/env", arguments: args, cwd: dir, timeout: 0, maxOutputBytes: SubprocessSpec.unboundedOutput))
        return (result.exitCode, result.stdout, result.stderr)
    }
}
