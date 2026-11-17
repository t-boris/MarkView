import Combine
import Foundation
import Darwin
import MarkViewCore
import os
import XCTest
@testable import MarkView

/// Checks that a Git remote is recognized as GitHub through an SSH host alias, and that a
/// folder's `gh` configuration directory is resolved from its `.ghprofile`.
private enum GitHubRemoteProfileChecks {
    static func run() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mv-github-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try remotesWithoutAliases(home: home)
        try aliasedRemotes(home: home)
        let suite = "github-profile-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try profiles(home: home, settings: Settings(defaults))
    }

    // MARK: Remotes

    static func remotesWithoutAliases(home: URL) throws {
        let expected: [String: String?] = [
            "git@github.com:owner/name.git": "owner/name",
            "https://github.com/owner/name.git": "owner/name",
            "https://github.com/owner/name": "owner/name",
            "ssh://git@github.com/owner/name.git": "owner/name",
            "git@gitlab.com:owner/name.git": nil,
            "https://example.com/owner/name.git": nil
        ]
        for (url, slug) in expected {
            let actual = GitHubClient.slug(fromRemoteURL: url, home: home)
            XCTAssertTrue(actual == slug, "\(url) resolved to \(actual ?? "nil"), expected \(slug ?? "nil")")
        }
    }

    static func aliasedRemotes(home: URL) throws {
        let config = """
            # A personal identity reached through an alias.
            Host github-personal
              HostName github.com
              User git

            Host gl-*
              HostName gitlab.com

            Include config.d/*.conf
            """
        try config.write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh/config.d"), withIntermediateDirectories: true)
        try "Host gh-work\n  HostName github.com\n"
            .write(to: home.appendingPathComponent(".ssh/config.d/work.conf"), atomically: true, encoding: .utf8)

        XCTAssertTrue(SSHHostAliases.resolve("github-personal", home: home) == "github.com")
        XCTAssertTrue(SSHHostAliases.resolve("gh-work", home: home) == "github.com", "An Include'd file must be read.")
        XCTAssertTrue(SSHHostAliases.resolve("gl-main", home: home) == "gitlab.com", "A wildcard Host pattern must match.")
        XCTAssertTrue(SSHHostAliases.resolve("unknown-host", home: home) == "unknown-host")
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            XCTAssertTrue(SSHHostAliases.resolve("gh-work", home: home) == "github.com", "Concurrent cache reads must agree.")
        }

        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "git@github-personal:owner/name.git", home: home) == "owner/name")
        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "ssh://git@gh-work/owner/name.git", home: home) == "owner/name")
        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "git@gl-main:owner/name.git", home: home) == nil,
                     "An alias that is not GitHub must stay unrecognized.")

        // An edited configuration is picked up rather than served from the cache.
        try (config + "\nHost later\n  HostName github.com\n")
            .write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SSHHostAliases.resolve("later", home: home) == "github.com", "A changed ~/.ssh/config must be re-read.")
    }

    // MARK: Profiles

    static func profiles(home: URL, settings: Settings) throws {
        let project = home.appendingPathComponent("Projects/app")
        let nested = project.appendingPathComponent("docs/features")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory == nil,
                     "Without a marker file gh keeps its own configuration.")

        try "personal\n".write(to: project.appendingPathComponent(".ghprofile"), atomically: true, encoding: .utf8)
        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory == nil,
                     "A marker naming a profile that does not exist must not invent a directory.")

        let profile = home.appendingPathComponent(".config/gh-profiles/personal")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let resolved = GitHubProfile.resolve(root: project, home: home, settings: settings)
        XCTAssertTrue(resolved.directory?.path == profile.path, "The profile directory must come from .ghprofile.")
        XCTAssertTrue(resolved.name == "personal")
        XCTAssertTrue(GitHubProfile.resolve(root: nested, home: home, settings: settings).directory?.path == profile.path,
                     "A subfolder follows the marker of the folder above it.")

        try "GHP_SSH_KEY=\"~/.ssh/id_personal\"\nGHP_TOKEN='secret-token' # inline\n"
            .write(to: profile.appendingPathComponent("profile.env"), atomically: true, encoding: .utf8)
        let withEnvironment = GitHubProfile.resolve(root: project, home: home, settings: settings)
        XCTAssertTrue(withEnvironment.token == "secret-token", "Quotes and trailing comments must be stripped.")
        XCTAssertTrue(withEnvironment.sshCommand == "ssh -i \(home.path)/.ssh/id_personal -o IdentitiesOnly=yes")

        var environment = ["GITHUB_TOKEN": "inherited", "PATH": "/usr/bin"]
        GitHubProfile.apply(to: &environment, root: project, home: home, settings: settings)
        XCTAssertTrue(environment["GH_CONFIG_DIR"] == profile.path)
        XCTAssertTrue(environment["GITHUB_TOKEN"] == "secret-token")
        XCTAssertTrue(environment["PATH"] == "/usr/bin")

        // A profile without a token must drop an inherited one: it belongs to another account.
        try "".write(to: profile.appendingPathComponent("profile.env"), atomically: true, encoding: .utf8)
        var inherited = ["GITHUB_TOKEN": "inherited"]
        GitHubProfile.apply(to: &inherited, root: project, home: home, settings: settings)
        XCTAssertTrue(inherited["GITHUB_TOKEN"] == nil, "An inherited token would override the profile's own credentials.")

        // An explicit setting wins over the folder's marker.
        let chosen = home.appendingPathComponent("chosen-config")
        settings.set(chosen.path, for: Setting.gitHubConfigDirectory)
        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory?.path == chosen.path)
        settings.remove(Setting.gitHubConfigDirectory)
    }
}

extension EditorHostTests {
    @MainActor func testGitTaskOwnership() async {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
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
            let oldGlobal = getenv("GIT_CONFIG_GLOBAL").map { String(cString: $0) }
            let oldSystem = getenv("GIT_CONFIG_SYSTEM").map { String(cString: $0) }
            defer {
                if let oldGlobal { setenv("GIT_CONFIG_GLOBAL", oldGlobal, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
                if let oldSystem { setenv("GIT_CONFIG_SYSTEM", oldSystem, 1) } else { unsetenv("GIT_CONFIG_SYSTEM") }
            }
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

        await gitClientChecks()
        await gitHubStoreChecks()
    }

    func testGitHubRemoteProfiles() throws { try GitHubRemoteProfileChecks.run() }
}

extension EditorHostTests {
    func testGitHubCommandLocalFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-command-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("gh-fixture")
        let script = #"""
        #!/usr/bin/python3
        import os, signal, sys
        case = sys.argv[-1]
        if case == "inherited-writer":
            os.execv("/bin/sh", ["/bin/sh", "-c", "/bin/sleep 4 & printf '[]'"])
        elif case == "both-pipes":
            for _ in range(64):
                os.write(1, b"A" * 16384)
                os.write(2, b"A" * 16384)
            sys.exit(7)
        elif case == "mark":
            open("started", "wb").close()
            os.write(1, b"marked\n")
        elif case == "ignore-term":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open("hung.pid", "w") as f:
                f.write(str(os.getpid()))
            while True:
                signal.pause()
        else:
            os.write(1, "ready é\n".encode())
        """#
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        let dateErrors = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let stamp = index.isMultiple(of: 2) ? "2023-11-14T22:13:20Z" : "2023-11-14T22:13:20.000Z"
            if GHDate.parse(stamp) != expected { dateErrors.withLock { $0 += 1 } }
        }
        XCTAssertEqual(dateErrors.withLock { $0 }, 0)
        let started = Date()
        let inherited = await GitHubClient.execute(["--fixture", "inherited-writer"], in: root, timeout: 2, ghExecutable: fixture)
        XCTAssertEqual(inherited.status, 0); XCTAssertEqual(inherited.stdout, "[]")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let large = await GitHubClient.execute(["--fixture", "both-pipes"], in: root, timeout: 5, ghExecutable: fixture)
        XCTAssertEqual(large.status, 7); XCTAssertEqual(large.stdout.utf8.count, 1_048_576); XCTAssertEqual(large.stderr.utf8.count, 1_048_576)
        let timeoutStart = Date()
        let hung = await GitHubClient.execute(["--fixture", "ignore-term"], in: root, timeout: 1, ghExecutable: fixture)
        XCTAssertEqual(hung.status, -1); XCTAssertTrue(hung.stderr.contains("did not answer within"))
        XCTAssertLessThan(Date().timeIntervalSince(timeoutStart), 3)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: root.appendingPathComponent("hung.pid"), encoding: .utf8)))
        XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let output = await GitHubClient.execute(["--fixture", "success"], in: root, timeout: 3, ghExecutable: fixture)
                    return output.status == 0 && output.stdout == "ready é\n"
                }
            }
            for await success in group { XCTAssertTrue(success) }
        }
        let invalid = await GitHubClient.execute(["--fixture", "success"], in: root.appendingPathComponent("missing"), timeout: 0.1, ghExecutable: fixture)
        XCTAssertTrue(invalid.status != 0 && !invalid.stderr.isEmpty)
        let marker = root.appendingPathComponent("started")
        func output(_ mode: String, enabled: Bool, timeout: TimeInterval) async -> String? {
            await Task.detached { GitHubClient.output(["--fixture", mode], in: root, enabled: enabled, timeout: timeout, ghExecutable: fixture) }.value
        }
        let off = await output("mark", enabled: false, timeout: 2)
        XCTAssertNil(off); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let on = await output("mark", enabled: true, timeout: 2)
        XCTAssertEqual(on, "marked\n"); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let failed = await output("both-pipes", enabled: true, timeout: 5)
        XCTAssertNil(failed)
        let hungStart = Date()
        let blocked = await output("ignore-term", enabled: true, timeout: 1)
        XCTAssertNil(blocked); XCTAssertLessThan(Date().timeIntervalSince(hungStart), 3)
    }
}
