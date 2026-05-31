import Foundation

/// Git integration — status, diff, commit, push/pull
@MainActor
class GitClient: ObservableObject {
    @Published var isGitRepo = false
    @Published var branch = ""
    @Published var changedFiles: [GitFileStatus] = []
    @Published var commitLog: [GitCommit] = []
    @Published var isOperating = false
    @Published var lastError: String?

    var workingDirectory: URL?

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

    // MARK: - Setup

    func setup(at url: URL) {
        workingDirectory = url
        Task { await refresh() }
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

        // Status — porcelain format: "XY filename" where X=index, Y=worktree
        let statusOutput = await run("git", "status", "--porcelain", in: dir) ?? ""
        changedFiles = statusOutput.components(separatedBy: "\n").compactMap { line in
            guard line.count >= 3 else { return nil }
            let indexStatus = line[line.startIndex]       // X: staged status
            let workStatus = line[line.index(after: line.startIndex)]  // Y: worktree status
            let file = String(line.dropFirst(3))
            guard !file.isEmpty else { return nil }

            let isStaged = indexStatus != " " && indexStatus != "?"
            let displayStatus: String
            if indexStatus == "?" { displayStatus = "?" }
            else if isStaged { displayStatus = String(indexStatus) }
            else { displayStatus = String(workStatus) }

            return GitFileStatus(status: displayStatus, file: file, isStaged: isStaged)
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
        guard let dir = workingDirectory else { return }
        Task { _ = await run("git", "add", file, in: dir); await refresh() }
    }

    func unstageFile(_ file: String) {
        guard let dir = workingDirectory else { return }
        Task { _ = await run("git", "reset", "HEAD", file, in: dir); await refresh() }
    }

    func stageAll() {
        guard let dir = workingDirectory else { return }
        Task { _ = await run("git", "add", "-A", in: dir); await refresh() }
    }

    func commit(message: String) async -> Bool {
        guard let dir = workingDirectory, !message.isEmpty else { return false }
        isOperating = true
        lastError = nil
        let result = await run("git", "commit", "-m", message, in: dir)
        isOperating = false
        if let result = result, result.contains("nothing to commit") {
            lastError = "Nothing to commit"
            return false
        }
        await refresh()
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

    func diff(file: String) async -> String {
        guard let dir = workingDirectory else { return "" }
        if let d = await run("git", "diff", file, in: dir), !d.isEmpty { return d }
        return await run("git", "diff", "--cached", file, in: dir) ?? ""
    }

    func discardChanges(_ file: String) {
        guard let dir = workingDirectory else { return }
        Task { _ = await run("git", "checkout", "--", file, in: dir); await refresh() }
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
