import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Where the Pull request X-Ray's changes come from: git for this checkout and for branch or date comparisons, and `gh` for pull
/// requests on GitHub (opt-in: `gitHub` is `GitHubSettings.enabled`, read on the main actor by the caller of each operation, and while
/// it is false `gh` is never started). Reads only; nothing is checked out and the working copy stays as it is. Blocking, so callers
/// run it off the main actor. The result is the unified diff that `ChangeDiff` reads.
enum ChangeSource {
    /// `git -C <root> <arguments>`: its standard output, or nil when it fails. `prompt: false` never waits for a password that
    /// cannot be answered (fetches).
    static func git(_ arguments: [String], in root: URL, prompt: Bool = true) -> String? {
        let result = Subprocess.runBlocking(SubprocessSpec(
            executable: "/usr/bin/env", arguments: (prompt ? [] : ["GIT_TERMINAL_PROMPT=0"]) + ["git", "-C", root.path] + arguments,
            timeout: 0, maxOutputBytes: SubprocessSpec.unboundedOutput, stderrRouting: .discard))
        return result.succeeded ? result.stdout : nil
    }

    /// The changes the PR X-Ray can show: this checkout against its base (git only), then the
    /// repository's pull requests when the GitHub integration is on (`gitHub`).
    static func list(root: URL, repo: GitHubRepo?, gitHub: Bool) -> [PRSource] {
        guard git(["rev-parse", "--is-inside-work-tree"], in: root) != nil else {
            return []
        }
        // Two kinds of change: this checkout (what a pull request from here would contain:
        // commits since the base plus uncommitted and new files), or a pull request on
        // GitHub, fetched and read at its own head.
        var sources: [PRSource] = []
        if let base = baseBranch(root: root) {
            let current = git(["rev-parse", "--abbrev-ref", "HEAD"], in: root)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let baseName = base.replacingOccurrences(of: "origin/", with: "")
            // Name both sides: this branch against the base it would be merged into.
            let subject = current.isEmpty || current == "HEAD" ? "All changes" : "\(current): all changes"
            sources.append(PRSource(id: "local", title: "\(subject) vs \(baseName) (commits + uncommitted)"))
        }
        // Every open pull request, then the 30 most recently merged or closed ones (two
        // queries: with one, old open ones fall outside the limit behind recent merges).
        // With the integration off `runGH` asks nothing and the list has no GitHub entries.
        var prs: [[String: Any]] = []
        for (state, limit) in [("open", "50"), ("closed", "30")] {
            if let json = gh(["pr", "list", "--state", state, "--limit", limit, "--json", "number,title,state"], root: root, repo: repo, gitHub: gitHub),
               let data = json.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                prs += list
            }
        }
        do {
            for pr in prs {
                guard let number = pr["number"] as? Int else { continue }
                let state = (pr["state"] as? String ?? "").lowercased()
                sources.append(PRSource(id: "gh:\(number)",
                                        title: "#\(number) \(pr["title"] as? String ?? "")" + (state == "open" || state.isEmpty ? "" : " (\(state))")))
            }
        }
        return sources
    }

    static func baseBranch(root: URL) -> String? {
        if let head = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty { return head }
        for candidate in ["main", "master", "origin/main", "origin/master"] {
            if git(["rev-parse", "--verify", "--quiet", candidate], in: root) != nil {
                return candidate
            }
        }
        return nil
    }

    /// `gh` for the PR X-Ray, through `GitHubClient`'s runner (the AI CLIs' PATH, pipes drained
    /// while it runs, terminated after `timeout` seconds). The only place this file starts `gh`.
    /// GitHub is opt-in: `gitHub` is `GitHubSettings.enabled`, read on the main actor by the
    /// caller of each operation; while it is false `gh` is not started and nil comes back, as
    /// when `gh` is missing or fails.
    static func gh(_ arguments: [String], root: URL, repo: GitHubRepo? = nil, gitHub: Bool,
                                          timeout: TimeInterval = 20) -> String? {
        // Pull requests of the repository chosen in the Git tab (origin or upstream).
        var arguments = arguments
        if arguments.first == "pr", arguments.count >= 2, let repo {
            arguments.insert(contentsOf: ["-R", repo.slug], at: 2)
        }
        return GitHubClient.output(arguments, in: root, enabled: gitHub, timeout: timeout)
    }

    /// A comparison the person chose: `cmp:<ref>` is this checkout (commits and uncommitted changes) against
    /// `<ref>`; `rev:<ref>` is what `<ref>` has that this checkout does not, read without checking it out.
    static func comparison(_ id: String) -> (reverse: Bool, ref: String)? {
        for (prefix, reverse) in [("cmp:", false), ("rev:", true)] where id.hasPrefix(prefix) {
            let ref = String(id.dropFirst(prefix.count))
            return ref.isEmpty || ref.hasPrefix("-") ? nil : (reverse, ref)
        }
        return nil
    }

    static func commit(of ref: String, root: URL) -> String? {
        git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mergeBase(with ref: String, root: URL) -> String? {
        guard commit(of: ref, root: root) != nil,
              let base = git(["merge-base", ref, "HEAD"], in: root)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else { return nil }
        return base
    }

    /// The change as a unified diff. Git serves the local checkout and branch comparisons; a
    /// pull request needs `gh`, which runs only while the GitHub integration is on (`gitHub`).
    static func diff(for source: PRSource, root: URL, repo: GitHubRepo?, gitHub: Bool) -> String? {
        if let sha = HistoricalBaseline.commitHash(fromSourceId: source.id) {
            // The chosen commit is the baseline itself, not its merge base with HEAD: it may sit on another
            // branch. The other side is the working copy: committed work, uncommitted changes and new files.
            guard commit(of: sha, root: root) != nil, let arguments = HistoricalBaseline.diffArguments(since: sha),
                  let tracked = git(arguments, in: root)
            else { return nil }
            return tracked + untrackedDiff(root: root)
        }
        if let chosen = comparison(source.id) {
            guard let base = mergeBase(with: chosen.ref, root: root) else { return nil }
            if chosen.reverse {
                return git(["diff", base, chosen.ref, "--no-color", "-U3"], in: root)
            }
            guard let tracked = git(["diff", base, "--no-color", "-U3"], in: root) else { return nil }
            return tracked + untrackedDiff(root: root)
        }
        switch source.id {
        case "local":
            guard let base = baseBranch(root: root),
                  let mergeBase = git(["merge-base", base, "HEAD"], in: root)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty,
                  let tracked = git(["diff", mergeBase, "--no-color", "-U3"], in: root)
            else { return nil }
            return tracked + untrackedDiff(root: root)
        default:
            guard source.id.hasPrefix("gh:") else { return nil }
            let number = String(source.id.dropFirst(3))
            if let checkout = fetch(number: number, root: root, repo: repo, gitHub: gitHub),
               let diff = git(["diff", checkout.mergeBase, checkout.head, "--no-color", "-U3"], in: root) {
                return diff
            }
            // Not fetchable (offline, no access): GitHub's diff; files are then the local ones.
            return gh(["pr", "diff", number, "--color", "never"], root: root, repo: repo, gitHub: gitHub, timeout: 60)
        }
    }

    /// Fetch pull request `number` (`pull/<n>/head`) and its base branch, unless already here.
    /// Nil while the GitHub integration is off (`gitHub`): the lookup needs `gh`.
    static func fetch(number: String, root: URL, repo: GitHubRepo?, gitHub: Bool) -> PRCheckout? {
        guard let json = gh(["pr", "view", number, "--json", "headRefOid,baseRefName"], root: root, repo: repo, gitHub: gitHub),
              let info = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let head = info["headRefOid"] as? String, let baseName = info["baseRefName"] as? String else { return nil }
        // Never wait for a password prompt that cannot be answered.
        func fetchGit(_ arguments: [String]) -> String? { git(arguments, in: root, prompt: false) }
        // The remote of the repository the pull request belongs to (a name, or a URL for a
        // fork's parent without an `upstream` remote).
        let remote = repo?.remote ?? "origin"
        if fetchGit(["cat-file", "-e", head + "^{commit}"]) == nil {
            _ = fetchGit(["fetch", "--no-tags", "--quiet", remote, "pull/\(number)/head"])
            guard fetchGit(["cat-file", "-e", head + "^{commit}"]) != nil else { return nil }
        }
        _ = fetchGit(["fetch", "--no-tags", "--quiet", remote, baseName])
        let baseRef = remote.contains("/") ? "FETCH_HEAD" : remote + "/" + baseName
        guard let mergeBase = fetchGit(["merge-base", baseRef, head])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mergeBase.isEmpty else { return nil }
        return PRCheckout(number: number, head: head, mergeBase: mergeBase)
    }

    static func cacheRoot(root: URL, label: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let repo = String(ContentHash.of(root.standardizedFileURL.path).prefix(12))
        return caches.appendingPathComponent("MarkView/pull-requests/\(repo)/\(label)", isDirectory: true)
    }

    /// Where this checkout's changes start: the merge base of the base branch and HEAD.
    static func localMergeBase(root: URL) -> String? {
        guard let base = baseBranch(root: root),
              let mergeBase = git(["merge-base", base, "HEAD"], in: root)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty else { return nil }
        return mergeBase
    }

    /// New files git does not track yet, as additions (text files up to 512 KB, at most 200).
    static func untrackedDiff(root: URL) -> String {
        guard let list = git(["ls-files", "--others", "--exclude-standard"], in: root)
        else { return "" }
        var out = ""
        for path in list.split(separator: "\n").prefix(200).map(String.init) {
            let url = root.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), data.count <= 512 * 1024, !data.contains(0),
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            let lines = text.editorLines
            out += "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n"
            out += lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// What the Pull request X-Ray loads for `source`: its diff, the pull request fetched for it (a pull request on GitHub, or the other
    /// branch of a `rev:` comparison), and the commit the change starts from, so a file it removes opens as it was there.
    static func read(_ source: PRSource, root: URL, repo: GitHubRepo?, gitHub: Bool) -> (diff: String?, checkout: PRCheckout?, base: String?) {
        var checkout = source.id.hasPrefix("gh:") ? fetch(number: String(source.id.dropFirst(3)), root: root, repo: repo, gitHub: gitHub) : nil
        var base = checkout?.mergeBase ?? (source.id == "local" ? localMergeBase(root: root) : nil)
        // A historical baseline is the commit itself; removed files open as they were in it.
        if let sha = HistoricalBaseline.commitHash(fromSourceId: source.id), commit(of: sha, root: root) != nil {
            base = sha
        }
        if let chosen = comparison(source.id), let fork = mergeBase(with: chosen.ref, root: root) {
            base = fork
            // Another branch's changes are read from that branch, not from the working copy.
            if chosen.reverse, let head = commit(of: chosen.ref, root: root) {
                let label = "branch-" + chosen.ref.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
                checkout = PRCheckout(number: label, head: head, mergeBase: fork)
            }
        }
        return (diff(for: source, root: root, repo: repo, gitHub: gitHub), checkout, base)
    }

    /// `path` as it was at `commit`, written under `cache` (MarkView's cache, never the project) so the viewer can open it. A file
    /// already there is returned as it is. Runs `git show` off the calling actor with a 15-second timeout (AR-06).
    static func materialize(path: String, at commit: String, into cache: URL, root: URL) async -> URL? {
        let file = cache.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let rootPath = root.path
        let spec = "\(commit):\(path)"
        let fetched: String? = await Task.detached(priority: .userInitiated) {
            let result = await Subprocess.run(SubprocessSpec(
                executable: "/usr/bin/env", arguments: ["git", "-C", rootPath, "show", spec], timeout: 15, maxOutputBytes: 2 * 1024 * 1024))
            guard result.succeeded, !result.timedOut else { return nil }
            return result.stdout
        }.value
        guard let text = fetched else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? AtomicFile.write(text, to: file)) != nil else { return nil }
        return file
    }
}
