import Combine
import Foundation

// The owners of the Git tab's work (AR-19): `GitClient` and `GitHubStore`, the shipping classes, over a real temporary repository with a
// bare "origin" next to it and real `git`. A tap starts work the model keeps in its task bag; a restart replaces it, a close cancels it,
// and nothing is written after the close. `gh` is never run.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

/// Runs real git in `dir`; the standard output, trimmed.
@discardableResult
func git(_ args: [String], in dir: URL) -> String {
    let result = Subprocess.runBlocking(SubprocessSpec(executable: "/usr/bin/env", arguments: ["git"] + args, cwd: dir, timeout: 30,
                                                       maxOutputBytes: 1 << 20))
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Polls until `condition` holds or `seconds` pass; the main actor keeps running meanwhile.
@MainActor func waitFor(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return condition()
}

/// A repository with one commit on `main` and a bare "origin" it tracks.
func makeRepository(_ name: String) -> (repo: URL, origin: URL, base: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("git-ownership-\(name)-\(UUID().uuidString)", isDirectory: true)
    let repo = base.appendingPathComponent("repo", isDirectory: true), origin = base.appendingPathComponent("origin.git", isDirectory: true)
    try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    git(["init", "--bare", "-b", "main"], in: origin)
    git(["init", "-b", "main"], in: repo)
    git(["config", "user.name", "Check"], in: repo)
    git(["config", "user.email", "check@example.invalid"], in: repo)
    git(["config", "commit.gpgsign", "false"], in: repo)
    git(["remote", "add", "origin", origin.path], in: repo)
    try? "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    git(["add", "a.txt"], in: repo)
    git(["commit", "-m", "first"], in: repo)
    git(["push", "-u", "origin", "main"], in: repo)
    return (repo, origin, base)
}

@MainActor func gitClientChecks() async {
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
    let (repo, origin, base) = makeRepository("client")
    defer { try? FileManager.default.removeItem(at: base) }

    // Start: opening the folder starts a look, and the client keeps it.
    let client = GitClient()
    var reports = 0
    let subscription = client.branchReports.sink { _ in reports += 1 }
    client.setup(at: repo)
    check(await waitFor { client.isGitRepo && client.branch == "main" }, "setup starts a look at the repository: the branch is read")

    // Restart: a look asked for while another is waiting replaces it, so the repository is read once.
    reports = 0
    client.startRefresh(); client.startRefresh()
    check(await waitFor { reports >= 1 }, "a look reports the branch")
    try? await Task.sleep(nanoseconds: 700_000_000)
    check(reports == 1, "a second look asked for at once replaces the first: one report, not two (\(reports))")

    // Operations never replace one another: two `.gitignore` entries asked for one after the other both land.
    client.startIgnore("one.txt", isDirectory: false)
    client.startIgnore("two.txt", isDirectory: false)
    let ignore = repo.appendingPathComponent(".gitignore")
    check(await waitFor { ((try? String(contentsOf: ignore, encoding: .utf8)) ?? "").contains("/two.txt") }, "the second operation runs")
    let ignored = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
    check(ignored.contains("/one.txt") && ignored.contains("/two.txt"), "an operation asked for later does not end the one before it")

    // The commit bar: the client commits what is staged, tells the bar through a receipt, and pushes when asked. The looks the operations
    // above ended with are over first: a look and a commit both want git's index lock.
    check(await waitFor { !client.isOperating && client.activity == nil }, "the operations are over")
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    try? "two\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    git(["add", "b.txt"], in: repo)
    client.startCommit(message: "second", thenPush: true)
    check(await waitFor { client.lastCommit?.message == "second" }, "a commit leaves a receipt with its message")
    check(await waitFor { git(["--git-dir", origin.path, "log", "--format=%s", "-1"], in: repo) == "second" }, "the commit is pushed when asked")

    // A transfer asked for while one runs is dropped, not started twice (a slow pre-push hook counts its runs).
    let hookLog = base.appendingPathComponent("hook.log")
    let hook = repo.appendingPathComponent(".git/hooks/pre-push")
    try? "#!/bin/sh\necho run >> '\(hookLog.path)'\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
    git(["update-index", "--chmod=+x", "--add", "--", ".git/hooks/pre-push"], in: repo)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try? "three\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
    git(["add", "c.txt"], in: repo)
    git(["commit", "-m", "third"], in: repo)
    client.startPush(); client.startPush()
    check(await waitFor(15) { git(["--git-dir", origin.path, "log", "--format=%s", "-1"], in: repo) == "third" }, "the push goes through")
    let runs = ((try? String(contentsOf: hookLog, encoding: .utf8)) ?? "").split(separator: "\n").count
    check(runs == 1, "a second push asked for while one runs is dropped: the hook ran once (\(runs))")
    try? FileManager.default.removeItem(at: hook)

    // Close: what is waiting never starts, and a look that is under way writes nothing more.
    client.startIgnore("never.txt", isDirectory: false)
    client.close()
    try? await Task.sleep(nanoseconds: 800_000_000)
    check(!((try? String(contentsOf: ignore, encoding: .utf8)) ?? "").contains("/never.txt"), "close cancels an operation that has not started")

    let closing = GitClient()
    var closingReports = 0
    let closingSubscription = closing.branchReports.sink { _ in closingReports += 1 }
    closing.workingDirectory = repo
    closing.startRefresh()
    var spins = 0
    while !closing.isGitRepo && spins < 200 { await Task.yield(); spins += 1 }
    check(closing.isGitRepo, "the look had started when the window closed")
    closing.close()
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    check(closing.branch.isEmpty && closingReports == 0 && closing.localBranches.isEmpty, "a look cancelled by the close writes nothing after it")
    subscription.cancel(); closingSubscription.cancel()
}

@MainActor func gitHubStoreChecks() async {
    let store = GitHubStore()

    // Start: the job runs under its key with the words its row shows, and ends with how it went.
    var release: CheckedContinuation<Void, Never>?
    store.start("pr-1", label: "Merging…", title: "Merge") {
        await withCheckedContinuation { release = $0 }
        return nil
    }
    check(store.jobs["pr-1"]?.isRunning == true && store.jobs["pr-1"]?.label == "Merging…", "a started job shows its label while it runs")
    check(await waitFor { release != nil }, "the job's work is under way")
    release?.resume()
    check(await waitFor { store.jobs["pr-1"]?.end == .done }, "a job whose work returns no error ends done")
    store.clearJob("pr-1")
    check(store.jobs["pr-1"] == nil, "the view that started a job forgets it once it has the outcome")

    store.start("pr-2", label: "Closing…", title: "Close") { "boom" }
    check(await waitFor { store.jobs["pr-2"]?.failure == "boom" }, "a job whose work returns an error ends failed with it")
    check(store.jobs["pr-2"]?.title == "Close", "the failure carries the title of its alert")

    // Restart: the same key replaces the job that runs, which is cancelled and writes nothing.
    var firstCancelled = false
    store.start("pr-3", label: "First…") {
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { firstCancelled = true }
        return "stale"
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    store.start("pr-3", label: "Second…") { nil }
    check(await waitFor { store.jobs["pr-3"]?.end == .done }, "the second job of a key ends done")
    check(await waitFor { firstCancelled }, "the first job of the key is cancelled")
    try? await Task.sleep(nanoseconds: 200_000_000)
    check(store.jobs["pr-3"]?.end == .done && store.jobs["pr-3"]?.label == "Second…", "the cancelled job writes nothing after its replacement")

    // Close: a reset (the folder or the window closing) cancels what runs, forgets the jobs and nothing is written after it.
    var closeCancelled = false
    store.start("pr-4", label: "Running…") {
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { closeCancelled = true }
        return "late"
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    store.reset()
    check(await waitFor { closeCancelled }, "a reset cancels the job that runs")
    try? await Task.sleep(nanoseconds: 200_000_000)
    check(store.jobs.isEmpty, "a reset forgets the jobs and a cancelled job writes nothing after it")
}

@main struct GitTaskOwnershipTests {
    @MainActor static func main() async {
        await gitClientChecks()
        await gitHubStoreChecks()
        if failures > 0 { print("\(failures) check(s) FAILED"); exit(1) }
        print("all checks passed")
    }
}
