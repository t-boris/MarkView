import Foundation

/// The app side of the delivery evidence (issue-lifecycle-management, plan I-4, DEC-012): reads git and, when the GitHub
/// integration is on, GitHub, and hands the facts to `DeliveryEvaluator`. Everything runs off the main thread (`git` and `gh`
/// through `GitHubClient.execute`). A source that cannot be read is reported as unavailable, never skipped: the verdict is then
/// unknown, which is not completion. With the integration off `gh` is not started at all (optional integrations stay silent).
enum IssueEvidenceCollector {
    struct Subject: Sendable {
        var kind: IssueKind
        /// The feature slug or the bug key.
        var issue: String
        /// GitHub issue numbers only this item links.
        var exclusiveNumbers: Set<Int>
        /// GitHub issue numbers that another feature or bug also links: naming only these cannot tie work to this item.
        var sharedNumbers: Set<Int>
        /// When the item was last started or reopened.
        var since: Date?
    }

    /// Units read in full, newest first. More implementation work than this names the item only in a project that tracks it in
    /// a very long series of commits; the evidence is then reported as unreadable instead of silently ignoring the older part.
    private static let unitLimit = 30
    /// Commits of the default branch that are looked at (`GitWorkLog.arguments`).
    private static let logLimit = 400
    private static let releaseLimit = 30
    private static let releaseChecks = 6

    static func collect(_ subject: Subject, root: URL, githubEnabled: Bool) async -> DeliveryVerdict {
        var sources: [EvidenceSource] = []
        guard let ref = await defaultBranch(root: root) else {
            return DeliveryEvaluator.evaluate(DeliveryInput(sources: [.unavailable("git", "no default branch (origin/main or main) was found")],
                                                            work: [], releaseRequired: false))
        }
        let log = await GitHubClient.execute(GitWorkLog.arguments(ref: ref, limit: logLimit) + ["--first-parent", "-m"], in: root, git: true, timeout: 30)
        guard log.status == 0 else {
            return DeliveryEvaluator.evaluate(DeliveryInput(sources: [.unavailable("git", "git log failed")], work: [], releaseRequired: false))
        }
        let history = GitWorkLog.commits(from: log.stdout)
        // Documentation-only commits are no implementation work (DEC-012) and are left out before anything is counted, so a run
        // of them cannot push the real work out of view. Work from before the item was last started or reopened is another round.
        // Git dates have whole seconds, so the start is compared to the second.
        let start = subject.since.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        let candidates = history.filter { commit in
            (start.map { commit.date >= $0 } ?? true)
                && (commit.paths.isEmpty || !commit.paths.allSatisfy(DocumentationPaths.isDocumentation))
        }
        var matches = matching(candidates, subject)
        matches = mergeMatches(matches, discussionMatches(candidates, subject: subject, root: root), order: candidates)
        // The log is a window: when it ends after the work started, work in between cannot be seen.
        let reachedStart = start.map { start in history.count < logLimit || history.last.map { $0.date <= start } ?? true } ?? true
        if !reachedStart {
            sources.append(.unavailable("git", "the last \(logLimit) commits of \(ref) do not reach back to when the work started"))
        } else {
            sources.append(.available("git"))
        }
        let definition = try? Data(contentsOf: root.appendingPathComponent(".dde/definition-of-done.json"))
        let required = ReleaseRequirement.isRequired(definitionOfDoneJSON: definition)
        let guide = try? String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        let policy = ProjectDeliveryPolicy.read(definition: definition, guide: guide)

        let needsGitHub = policy.checksRequired || policy.pullRequestRequired || required
        var client: GitHubClient?
        if githubEnabled {
            if GitHubClient.ghPath() == nil {
                if needsGitHub { sources.append(.unavailable("GitHub", "the GitHub CLI (gh) is not installed")) }
            } else if let repo = await GitHubClient.detectRepos(root: root).first(where: { !$0.isUpstream }) {
                client = GitHubClient(root: root, repo: repo)
                sources.append(.available("GitHub"))
            } else {
                if needsGitHub { sources.append(.unavailable("GitHub", "this project has no GitHub remote")) }
            }
        } else if needsGitHub {
            sources.append(.unavailable("GitHub", "the GitHub integration is off, so required checks, pull requests or releases cannot be read"))
        }

        // Merge commits normally contain only the PR title, not its body or the messages of the commits merged.
        // Read both sources before deciding that no implementation exists. Associate the evidence with the first-parent
        // commit, which is the work that actually landed, rather than treating an unmerged branch as delivered.
        let side = await sideBranchMatches(candidates, subject: subject, ref: ref, root: root)
        matches = mergeMatches(matches, side.matches, order: candidates)
        if let reason = side.error { sources.append(.unavailable("git branch history", reason)) }
        if let client {
            let prBodies = await pullRequestMatches(candidates, subject: subject, client: client)
            matches = mergeMatches(matches, prBodies.matches, order: candidates)
            if let reason = prBodies.error, needsGitHub { sources.append(.unavailable("GitHub pull requests", reason)) }
        }
        if matches.count > unitLimit {
            sources.append(.unavailable("git", "\(matches.count) commits name this item; only the newest \(unitLimit) can be read"))
        }

        var work: [WorkUnit] = []
        for match in matches.prefix(unitLimit) {
            work.append(await unit(for: match, root: root, client: client, checksRequired: policy.checksRequired))
        }
        var releases: [WorkRef: ReleaseState] = [:]
        if required {
            let codeUnits = work.filter { !$0.isDocumentationOnly && $0.mergedAt != nil && $0.association == .explicit }
            let all = await publishedReleases(client: client)
            for item in codeUnits {
                releases[item.ref] = await release(containing: item, among: all, client: client, root: root)
            }
        }
        return DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: work, releaseRequired: required, releases: releases, since: subject.since,
                                                        pullRequestRequired: policy.pullRequestRequired, checksRequired: policy.checksRequired))
    }

    // MARK: Git

    private static func defaultBranch(root: URL) async -> String? {
        for candidate in ["origin/main", "main", "origin/master", "master"] {
            let probe = await GitHubClient.execute(["rev-parse", "--verify", "--quiet", candidate], in: root, git: true, timeout: 10)
            if probe.status == 0 { return candidate }
        }
        return nil
    }

    private struct Match {
        var commit: GitWorkLog.Commit
        var association: WorkAssociation
        var pullRequest: Int?
    }

    private static func association(in text: String, subject: Subject) -> WorkAssociation? {
        let explicit: Bool
        switch subject.kind {
        case .feature:
            explicit = WorkAssociationRules.mentionsFeature(text, slug: subject.issue, issues: subject.exclusiveNumbers)
        case .bug:
            explicit = WorkAssociationRules.mentionsBug(text, key: subject.issue, issues: subject.exclusiveNumbers)
        }
        if explicit { return .explicit }
        if WorkAssociationRules.mentionsIssueNumber(text, in: subject.sharedNumbers) {
            return .ambiguous("it names only a GitHub issue that more than one feature or bug links")
        }
        return nil
    }

    private static func matching(_ commits: [GitWorkLog.Commit], _ subject: Subject) -> [Match] {
        commits.compactMap { commit in
            association(in: commit.message, subject: subject).map {
                Match(commit: commit, association: $0, pullRequest: pullRequest(in: commit.message))
            }
        }
    }

    /// A feature's own discussion may explicitly record the commit that landed on the default branch. Match only
    /// unambiguous hashes against the already verified first-parent history; text never makes an unmerged commit count.
    private static func discussionMatches(_ candidates: [GitWorkLog.Commit], subject: Subject, root: URL) -> [Match] {
        guard subject.kind == .feature, !subject.issue.isEmpty,
              subject.issue.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return [] }
        let url = root.appendingPathComponent("docs/features").appendingPathComponent(subject.issue).appendingPathComponent("discussion.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count <= 1_000_000,
              let pattern = try? NSRegularExpression(pattern: #"(?i)(?<![0-9a-f])([0-9a-f]{7,40})(?![0-9a-f])"#) else { return [] }
        var hashes = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard ["commit", "коммит", "main", "merged", "слил", "push"].contains(where: lower.contains) else { continue }
            for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                if let range = Range(match.range(at: 1), in: line) { hashes.insert(String(line[range]).lowercased()) }
            }
        }
        var found: [Match] = []
        for hash in hashes {
            let matching = candidates.filter { $0.sha.lowercased().hasPrefix(hash) }
            guard matching.count == 1, let commit = matching.first else { continue }
            found.append(Match(commit: commit, association: .explicit, pullRequest: pullRequest(in: commit.message)))
        }
        return found
    }

    /// Merge several independent links without double-counting the same landed change. An explicit link wins over a shared number.
    private static func mergeMatches(_ left: [Match], _ right: [Match], order: [GitWorkLog.Commit]) -> [Match] {
        var bySHA: [String: Match] = [:]
        for match in left + right {
            if let previous = bySHA[match.commit.sha], previous.association == .explicit { continue }
            bySHA[match.commit.sha] = match
        }
        return order.compactMap { bySHA[$0.sha] }
    }

    /// Read messages in merged branches, then locate the first mainline commit containing each one. A bounded scan or a
    /// failed ancestry lookup is reported, never silently interpreted as absence of work.
    private static func sideBranchMatches(_ mainline: [GitWorkLog.Commit], subject: Subject, ref: String, root: URL)
        async -> (matches: [Match], error: String?) {
        guard !mainline.isEmpty else { return ([], nil) }
        let limit = 20_000
        let format = "--format=\(GitWorkLog.separator)%H%x1f%cI%x1f%B%x1f"
        let output = await GitHubClient.execute(["log", ref, "-n", String(limit), "--no-merges", format], in: root, git: true, timeout: 30)
        guard output.status == 0 else { return ([], "the merged commit messages could not be read") }
        let commits = GitWorkLog.commits(from: output.stdout)
        let firstParents = await GitHubClient.execute(["log", ref, "--first-parent", "--format=%H"],
                                                      in: root, git: true, timeout: 30)
        guard firstParents.status == 0 else { return ([], "the mainline commits could not be read") }
        let primary = Set(firstParents.stdout.split(whereSeparator: \.isNewline).map(String.init))
        let merges = await GitHubClient.execute(["log", ref, "-n", String(logLimit), "--first-parent", "--merges", "--format=%H"],
                                                in: root, git: true, timeout: 30)
        guard merges.status == 0 else { return ([], "the mainline merges could not be read") }
        let mergeSHAs = Set(merges.stdout.split(whereSeparator: \.isNewline).map(String.init))
        let related = matching(commits.filter { !primary.contains($0.sha) }, subject)
        guard related.count <= 300 else { return ([], "more than 300 commits name this item; their merges could not be located safely") }
        var found: [Match] = []
        for match in related {
            let ancestry = await GitHubClient.execute(["log", "--first-parent", "--ancestry-path", "--reverse", "--format=%H",
                                                        match.commit.sha + ".." + ref], in: root, git: true, timeout: 30)
            guard ancestry.status == 0 else { return (found, "a merged commit's mainline ancestry could not be read") }
            guard let landed = ancestry.stdout.split(whereSeparator: \.isNewline).first.map(String.init),
                  mergeSHAs.contains(landed), let commit = mainline.first(where: { $0.sha == landed }) else { continue }
            found.append(Match(commit: commit, association: match.association, pullRequest: pullRequest(in: commit.message)))
        }
        if commits.count == limit, let oldest = mainline.last?.date, let last = commits.last?.date, last > oldest {
            return (found, "the merged commit message scan did not reach the oldest mainline work")
        }
        return (found, nil)
    }

    /// Read PR descriptions in bounded batches: a merge commit drops the description even when it has the association.
    private static func pullRequestMatches(_ mainline: [GitWorkLog.Commit], subject: Subject, client: GitHubClient)
        async -> (matches: [Match], error: String?) {
        let pieces = client.repo.slug.split(separator: "/")
        guard pieces.count == 2, pieces.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else {
            return ([], "the GitHub repository name is invalid")
        }
        let candidates = mainline.compactMap { commit -> (GitWorkLog.Commit, Int)? in
            pullRequest(in: commit.message).map { (commit, $0) }
        }
        var found: [Match] = []
        for start in stride(from: 0, to: candidates.count, by: 40) {
            let batch = Array(candidates[start..<min(start + 40, candidates.count)])
            let fields = batch.map { "p\($0.1): pullRequest(number: \($0.1)) { body }" }.joined(separator: " ")
            let query = "query { repository(owner: \"\(pieces[0])\", name: \"\(pieces[1])\") { \(fields) } }"
            let result = await GitHubClient.execute(["api", "graphql", "-f", "query=" + query], in: client.root, timeout: 30)
            guard result.status == 0, let object = json(result.stdout), object["errors"] == nil,
                  let data = object["data"] as? [String: Any], let repo = data["repository"] as? [String: Any] else {
                return (found, "pull request descriptions could not be read")
            }
            for (commit, number) in batch {
                // A squash title can end in an issue number rather than a pull request number.
                guard let pr = repo["p\(number)"] as? [String: Any], let body = pr["body"] as? String else { continue }
                if let association = association(in: body, subject: subject) {
                    found.append(Match(commit: commit, association: association, pullRequest: number))
                }
            }
        }
        return (found, nil)
    }

    /// "Merge pull request #12 from …" (merge commit) or "title (#12)" (squash).
    static func pullRequest(in message: String) -> Int? {
        let subject = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? message
        for pattern in [#"^Merge pull request #(\d+)"#, #"\(#(\d+)\)\s*$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
                  let range = Range(match.range(at: 1), in: subject) else { continue }
            return Int(subject[range])
        }
        return nil
    }

    // MARK: Checks

    private static func unit(for match: Match, root: URL, client: GitHubClient?, checksRequired: Bool) async -> WorkUnit {
        let commit = match.commit
        guard let client else {
            return WorkUnit(ref: match.pullRequest.map(WorkRef.pullRequest) ?? .commit(commit.sha), headSHA: commit.sha, mergedAt: commit.date,
                            changedPaths: commit.paths, checks: .unknown("GitHub is not available"), association: match.association)
        }
        if let number = match.pullRequest {
            // A pull request: its own head is judged; a repository that runs its workflows on push has none there, so the
            // commit that landed on the default branch is judged instead.
            let view = await GitHubClient.execute(["pr", "view", String(number), "-R", client.repo.slug, "--json", "headRefOid,mergeCommit,mergedAt,state"],
                                                  in: root, timeout: 30)
            var head = commit.sha
            var landed = commit.sha
            var verified = false
            if view.status == 0, let object = json(view.stdout) {
                head = object["headRefOid"] as? String ?? commit.sha
                landed = (object["mergeCommit"] as? [String: Any])?["oid"] as? String ?? commit.sha
                verified = (object["state"] as? String)?.uppercased() == "MERGED" && object["mergedAt"] is String
            }
            var state: CheckState = checksRequired ? await checks(of: head, client: client) : .noRuns(sha: head)
            var judged = head
            if checksRequired, case .noRuns = state, landed != head {
                state = await checks(of: landed, client: client)
                judged = landed
            }
            return WorkUnit(ref: .pullRequest(number), headSHA: judged, mergedAt: commit.date, changedPaths: commit.paths, checks: state,
                            association: match.association, landedSHA: landed, pullRequestVerified: verified)
        }
        return WorkUnit(ref: .commit(commit.sha), headSHA: commit.sha, mergedAt: commit.date, changedPaths: commit.paths,
                        checks: checksRequired ? await checks(of: commit.sha, client: client) : .noRuns(sha: commit.sha), association: match.association)
    }

    private static func checks(of sha: String, client: GitHubClient) async -> CheckState {
        let runs = await GitHubClient.execute(["run", "list", "-R", client.repo.slug, "--commit", sha, "-L", "100", "--json", "status,conclusion"],
                                              in: client.root, timeout: 30)
        guard runs.status == 0 else { return .unknown("gh run list failed") }
        return RunsVerdict.state(runsJSON: Data(runs.stdout.utf8), sha: sha)
    }

    // MARK: Releases

    private struct PublishedRelease {
        var tag: String
        var publishedAt: Date
    }

    private static func publishedReleases(client: GitHubClient?) async -> [PublishedRelease]? {
        guard let client else { return nil }
        let list = await GitHubClient.execute(["release", "list", "-R", client.repo.slug, "-L", String(releaseLimit), "--json", "tagName,publishedAt,isDraft"],
                                              in: client.root, timeout: 30)
        guard list.status == 0, let rows = try? JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]] else { return nil }
        var out: [PublishedRelease] = []
        for row in rows where row["isDraft"] as? Bool != true {
            guard let tag = row["tagName"] as? String, let stamp = row["publishedAt"] as? String, let date = GitWorkLog.parseDate(stamp) else { continue }
            out.append(PublishedRelease(tag: tag, publishedAt: date))
        }
        return out.sorted { $0.publishedAt < $1.publishedAt }
    }

    /// The first published release made after the unit landed whose commit contains it; pending when none does.
    private static func release(containing unit: WorkUnit, among releases: [PublishedRelease]?, client: GitHubClient?, root: URL) async -> ReleaseState {
        guard let client, let releases else { return .unknown("the releases of GitHub could not be read") }
        let landed = unit.mergedAt ?? .distantFuture
        let candidates = releases.filter { $0.publishedAt >= landed }.prefix(releaseChecks)
        if candidates.isEmpty { return .pending }
        let sha = unit.landedSHA ?? unit.ref.commitSHA ?? unit.headSHA
        var unreadable = false
        for candidate in candidates {
            let compare = await GitHubClient.execute(["api", "repos/\(client.repo.slug)/compare/\(sha)...\(candidate.tag)", "--jq", ".status"],
                                                     in: root, timeout: 30)
            guard compare.status == 0 else { unreadable = true; continue }
            let status = compare.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == "ahead" || status == "identical" { return .delivered(tag: candidate.tag) }
        }
        return unreadable ? .unknown("a release could not be compared with the work") : .pending
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

private extension WorkRef {
    var commitSHA: String? {
        if case .commit(let sha) = self { return sha }
        return nil
    }
}
