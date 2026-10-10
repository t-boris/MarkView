import Foundation

/// Git integration — status, diff, commit, push/pull
@MainActor
class GitClient: ObservableObject {
    @Published var isGitRepo = false
    @Published var branch = ""
    /// Local branches, most recently committed first.
    @Published var localBranches: [String] = []
    /// Remote branches ("origin/x") with no local branch of the same name, most recent first.
    @Published var remoteBranches: [String] = []
    @Published var changedFiles: [GitFileStatus] = []
    /// Everything Git says about the work tree: changes, untracked, conflicts and (when asked) ignored paths.
    @Published var repoStatus = GitRepoStatus.empty
    /// Tracked files without a change; loaded only while `showTracked` is on.
    @Published var cleanTracked: [String] = []
    @Published var stashCount = 0
    /// Ignored paths are listed only on request (a big ignored tree such as node_modules is a single line).
    @Published var showIgnored = false { didSet { if showIgnored != oldValue { Task { await refresh() } } } }
    @Published var showTracked = false { didSet { if showTracked != oldValue { Task { await refresh() } } } }
    @Published var commitLog: [GitCommit] = []
    @Published var isOperating = false
    @Published var lastError: String?

    var workingDirectory: URL?
    /// Told the current branch after every refresh (the GitHub store follows it).
    var onBranch: ((String) -> Void)?

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
        let id = UUID()
        let hash: String
        let message: String
        let author: String
        let date: String
    }

    /// The one-line status the file tree and the commit bar use: staged wins over unstaged.
    private static func changedFile(_ entry: GitStatusEntry) -> GitFileStatus? {
        switch entry.special {
        case .ignored?: return nil
        case .untracked?: return GitFileStatus(status: "?", file: entry.path, isStaged: false)
        case .conflicted?: return GitFileStatus(status: "U", file: entry.path, isStaged: false)
        default:
            if let index = entry.index { return GitFileStatus(status: index.letter, file: entry.path, isStaged: true) }
            if let worktree = entry.worktree { return GitFileStatus(status: worktree.letter, file: entry.path, isStaged: false) }
            return nil
        }
    }

    // MARK: - Setup

    func setup(at url: URL) {
        workingDirectory = url
        Task { await refresh() }
    }

    /// Forget the repository, e.g. when the workspace folder is closed.
    func reset() {
        workingDirectory = nil
        isGitRepo = false
        branch = ""
        localBranches = []
        remoteBranches = []
        changedFiles = []
        repoStatus = .empty
        cleanTracked = []
        stashCount = 0
        commitLog = []
        lastError = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard let dir = workingDirectory else { return }

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
        branch = (await run("git", "rev-parse", "--abbrev-ref", "HEAD", in: dir) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        onBranch?(branch)
        await loadBranches(in: dir)

        // Status — porcelain v2 with every untracked file listed; ignored paths only on request.
        var statusArgs = ["git", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]
        if showIgnored { statusArgs.append("--ignored=matching") }
        let parsed = GitRepoStatus.parse(await run(statusArgs, in: dir) ?? "")
        repoStatus = parsed
        changedFiles = parsed.entries.compactMap(Self.changedFile)
        stashCount = (await run(["git", "stash", "list"], in: dir) ?? "").split(separator: "\n").count
        if showTracked {
            cleanTracked = GitRepoStatus.cleanTracked(lsFiles: await run(["git", "ls-files", "-z"], in: dir) ?? "",
                                                      changed: parsed.changedPaths)
        } else {
            cleanTracked = []
        }

        // Log (last 20)
        let logOutput = await run("git", "log", "--oneline", "--format=%h|%s|%an|%ar", "-20", in: dir) ?? ""
        commitLog = logOutput.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 4 else { return nil }
            return GitCommit(hash: parts[0], message: parts[1], author: parts[2], date: parts[3])
        }
    }

    // MARK: - Operations

    func stageFile(_ file: String) {
        mutate(["add", "--", file])
    }

    func unstageFile(_ file: String) {
        mutate(["reset", "-q", "HEAD", "--", file])
    }

    func stageAll() {
        mutate(["add", "-A"])
    }

    /// Run a git command that changes the repository and refresh; a failure is shown, not swallowed.
    private func mutate(_ args: [String]) {
        guard let dir = workingDirectory else { return }
        lastError = nil
        Task {
            let result = await execute(["git"] + args, in: dir)
            if result.status != 0 { lastError = Self.explain(result) }
            await refresh()
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
        lastError = nil
        let result = await execute(["git", "commit", "-m", message], in: dir)
        isOperating = false
        await refresh()
        guard result.status == 0 else {
            // A hook that rejects the commit, a missing identity, nothing staged: say why and keep the message.
            lastError = result.output.contains("nothing to commit") ? "Nothing to commit" : Self.explain(result)
            return false
        }
        return true
    }

    func push() async -> Bool {
        guard let dir = workingDirectory else { return false }
        isOperating = true
        lastError = nil
        let result = await runWithError("git", "push", in: dir)
        isOperating = false
        if let err = result.error, !err.isEmpty {
            if err.contains("rejected") || err.contains("error") {
                lastError = String(err.prefix(200))
                return false
            }
        }
        await refresh()
        return true
    }

    func pull() async -> Bool {
        guard let dir = workingDirectory else { return false }
        isOperating = true
        lastError = nil
        let result = await runWithError("git", "pull", in: dir)
        isOperating = false
        if let err = result.error, err.contains("error") {
            lastError = String(err.prefix(200))
            return false
        }
        await refresh()
        return true
    }

    func diff(file: String, staged: Bool = false) async -> String {
        guard let dir = workingDirectory else { return "" }
        if staged { return await run("git", "diff", "--cached", "--", file, in: dir) ?? "" }
        if let d = await run("git", "diff", file, in: dir), !d.isEmpty { return d }
        return await run("git", "diff", "--cached", file, in: dir) ?? ""
    }

    func discardChanges(_ file: String) {
        guard let dir = workingDirectory else { return }
        mutate(["checkout", "--", file])
    }

    // MARK: - Branches

    private func loadBranches(in dir: URL) async {
        let output = await run("git", "for-each-ref", "--sort=-committerdate", "--format=%(refname)",
                               "refs/heads", "refs/remotes", in: dir) ?? ""
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
        lastError = nil
        let result = await GitHubClient.execute(args, in: dir, git: true)
        isOperating = false
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

    // Runs git OFF the main thread. Reads the pipe to EOF BEFORE waitUntilExit so a
    // large output (e.g. `git status` on a big repo) can't fill the 64KB pipe buffer
    // and deadlock the process — which previously froze the whole app on the main thread.
    nonisolated private func run(_ args: String..., in dir: URL) async -> String? {
        await run(args, in: dir)
    }

    nonisolated private func run(_ args: [String], in dir: URL) async -> String? {
        let argv = args
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.currentDirectoryURL = dir
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice  // ignored — avoids a 2nd pipe deadlock
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()  // drains until git exits
                process.waitUntilExit()
                return String(data: data, encoding: .utf8)
            } catch { return nil }
        }.value
    }

    /// Runs git off the main thread and keeps the exit status, stdout and stderr (both drained concurrently).
    nonisolated private func execute(_ args: [String], in dir: URL) async -> (status: Int32, output: String, error: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.currentDirectoryURL = dir
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
                let errHandle = errPipe.fileHandleForReading
                let errFuture = Task.detached { errHandle.readDataToEndOfFile() }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = await errFuture.value
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
            } catch { return (-1, "", error.localizedDescription) }
        }.value
    }

    nonisolated private func runWithError(_ args: String..., in dir: URL) async -> (output: String?, error: String?) {
        let argv = args
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.currentDirectoryURL = dir
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
                // Drain stderr concurrently so neither pipe buffer can fill and deadlock.
                let errHandle = errPipe.fileHandleForReading
                let errFuture = Task.detached { errHandle.readDataToEndOfFile() }
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                let err = String(data: await errFuture.value, encoding: .utf8)
                process.waitUntilExit()
                return (out, err)
            } catch { return (nil, error.localizedDescription) }
        }.value
    }
}
