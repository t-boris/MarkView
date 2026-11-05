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
        let matches = matching(history, subject).filter { match in start.map { match.commit.date >= $0 } ?? true }
        // The log is a window: when it ends after the work started, work in between cannot be seen.
        let reachedStart = start.map { start in history.count < logLimit || history.last.map { $0.date <= start } ?? true } ?? true
        if !reachedStart {
            sources.append(.unavailable("git", "the last \(logLimit) commits of \(ref) do not reach back to when the work started"))
        } else if matches.count > unitLimit {
            sources.append(.unavailable("git", "\(matches.count) commits name this item; only the newest \(unitLimit) can be read"))
        } else {
            sources.append(.available("git"))
        }
        let required = ReleaseRequirement.isRequired(definitionOfDoneJSON: try? Data(contentsOf: root.appendingPathComponent(".dde/definition-of-done.json")))

        var client: GitHubClient?
        if githubEnabled {
            if GitHubClient.ghPath() == nil {
                sources.append(.unavailable("GitHub", "the GitHub CLI (gh) is not installed"))
            } else if let repo = await GitHubClient.detectRepos(root: root).first(where: { !$0.isUpstream }) {
                client = GitHubClient(root: root, repo: repo)
                sources.append(.available("GitHub"))
            } else {
                sources.append(.unavailable("GitHub", "this project has no GitHub remote"))
            }
        } else {
            sources.append(.unavailable("GitHub", "the GitHub integration is off, so checks and releases cannot be read"))
        }

        var work: [WorkUnit] = []
        for match in matches.prefix(unitLimit) {
            work.append(await unit(for: match, root: root, client: client))
        }
        var releases: [WorkRef: ReleaseState] = [:]
        if required {
            let codeUnits = work.filter { !$0.isDocumentationOnly && $0.mergedAt != nil && $0.association == .explicit }
            let all = await publishedReleases(client: client)
            for item in codeUnits {
                releases[item.ref] = await release(containing: item, among: all, client: client, root: root)
            }
        }
        return DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: work, releaseRequired: required, releases: releases, since: subject.since))
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

    private static func matching(_ commits: [GitWorkLog.Commit], _ subject: Subject) -> [Match] {
        var matches: [Match] = []
        for commit in commits {
            if !commit.paths.isEmpty, commit.paths.allSatisfy(DocumentationPaths.isDocumentation) { continue }
            let explicit: Bool
            switch subject.kind {
            case .feature:
                explicit = WorkAssociationRules.mentionsFeature(commit.message, slug: subject.issue, issues: subject.exclusiveNumbers)
            case .bug:
                explicit = WorkAssociationRules.mentionsBug(commit.message, key: subject.issue, issues: subject.exclusiveNumbers)
            }
            var association: WorkAssociation = .explicit
            if !explicit {
                guard WorkAssociationRules.mentionsIssueNumber(commit.message, in: subject.sharedNumbers) else { continue }
                association = .ambiguous("it names only a GitHub issue that more than one feature or bug links")
            }
            matches.append(Match(commit: commit, association: association, pullRequest: pullRequest(in: commit.message)))
        }
        return matches
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

    private static func unit(for match: Match, root: URL, client: GitHubClient?) async -> WorkUnit {
        let commit = match.commit
        guard let client else {
            return WorkUnit(ref: match.pullRequest.map(WorkRef.pullRequest) ?? .commit(commit.sha), headSHA: commit.sha, mergedAt: commit.date,
                            changedPaths: commit.paths, checks: .unknown("GitHub is not available"), association: match.association)
        }
        if let number = match.pullRequest {
            // A pull request: its own head is judged; a repository that runs its workflows on push has none there, so the
            // commit that landed on the default branch is judged instead.
            let view = await GitHubClient.execute(["pr", "view", String(number), "-R", client.repo.slug, "--json", "headRefOid,mergeCommit"],
                                                  in: root, timeout: 30)
            var head = commit.sha
            var landed = commit.sha
            if view.status == 0, let object = json(view.stdout) {
                head = object["headRefOid"] as? String ?? commit.sha
                landed = (object["mergeCommit"] as? [String: Any])?["oid"] as? String ?? commit.sha
            }
            var state = await checks(of: head, client: client)
            var judged = head
            if case .noRuns = state, landed != head {
                state = await checks(of: landed, client: client)
                judged = landed
            }
            return WorkUnit(ref: .pullRequest(number), headSHA: judged, mergedAt: commit.date, changedPaths: commit.paths, checks: state,
                            association: match.association)
        }
        return WorkUnit(ref: .commit(commit.sha), headSHA: commit.sha, mergedAt: commit.date, changedPaths: commit.paths,
                        checks: await checks(of: commit.sha, client: client), association: match.association)
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
        let sha = unit.ref.commitSHA ?? unit.headSHA
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
