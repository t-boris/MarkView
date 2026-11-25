import Foundation

/// Reads the delivery of a managed run's branch from git and GitHub (`CockpitDeliveryEvidence`): before a run starts or resumes, and
/// before each scheduled delivery action, so a step whose result exists already is not repeated (REQ-002, REQ-003). Every command
/// runs through `GitHubClient.execute` (`Subprocess`), off the main thread, never prompts, and has a timeout; a command that fails
/// leaves its part unknown rather than guessed.
enum CockpitDeliveryProbe {
    /// The checkout's current commit, or nil outside a git repository.
    static func head(root: URL) async -> String? {
        let head = await GitHubClient.execute(["rev-parse", "HEAD"], in: root, git: true, timeout: 15)
        let value = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.status == 0 && !value.isEmpty ? value : nil
    }

    static func probe(root: URL, branch: String) async -> CockpitDeliveryEvidence {
        var evidence = CockpitDeliveryEvidence()
        evidence.head = await head(root: root)
        let current = await GitHubClient.execute(["rev-parse", "--abbrev-ref", "HEAD"], in: root, git: true, timeout: 15)
        if current.status == 0 { evidence.currentBranch = current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        let exists = await GitHubClient.execute(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: root, git: true, timeout: 15)
        evidence.branchExists = exists.status == 0
        let listed = await GitHubClient.execute(["pr", "list", "--head", branch, "--state", "all", "--limit", "5",
                                                 "--json", "number,url,state,headRefOid,mergeCommit,statusCheckRollup"], in: root, timeout: 30)
        guard listed.status == 0 else { return evidence }
        evidence.github = true
        guard let pr = pullRequest(fromJSON: listed.stdout) else { return evidence }
        evidence.pullRequest = pr.pullRequest
        evidence.checks = pr.checks
        if let merge = pr.pullRequest.mergeCommit, pr.pullRequest.state == "MERGED" {
            evidence.release = await release(containing: merge, root: root)
        }
        return evidence
    }

    /// The newest pull request of `gh pr list --json number,url,state,headRefOid,mergeCommit,statusCheckRollup`, with the state of its
    /// head commit's checks: failed when any failed, pending while any runs, passed when all passed, none without checks.
    static func pullRequest(fromJSON text: String) -> (pullRequest: CockpitDeliveryEvidence.PullRequest, checks: CockpitDeliveryEvidence.Checks)? {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return nil }
        let open = rows.first { ($0["state"] as? String) == "OPEN" }
        let merged = rows.first { ($0["state"] as? String) == "MERGED" }
        guard let row = merged ?? open ?? rows.first, let number = row["number"] as? Int else { return nil }
        let mergeCommit = (row["mergeCommit"] as? [String: Any])?["oid"] as? String
        let pr = CockpitDeliveryEvidence.PullRequest(number: number, url: row["url"] as? String ?? "", state: row["state"] as? String ?? "",
                                                     headSHA: row["headRefOid"] as? String ?? "", mergeCommit: mergeCommit)
        let rollup = row["statusCheckRollup"] as? [[String: Any]] ?? []
        return (pr, checks(rollup))
    }

    static func checks(_ rollup: [[String: Any]]) -> CockpitDeliveryEvidence.Checks {
        guard !rollup.isEmpty else { return .none }
        var pending = false
        for check in rollup {
            // A check run has status and conclusion; a commit status has state.
            let conclusion = ((check["conclusion"] as? String) ?? (check["state"] as? String) ?? "").uppercased()
            let status = ((check["status"] as? String) ?? "").uppercased()
            if ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) { return .failed }
            if ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(conclusion) { continue }
            if status == "COMPLETED", conclusion.isEmpty { continue }
            pending = true
        }
        return pending ? .pending : .passed
    }

    /// The newest published (not draft) release whose tag contains `commit`, or nil.
    private static func release(containing commit: String, root: URL) async -> String? {
        let listed = await GitHubClient.execute(["release", "list", "--limit", "10", "--json", "tagName,isDraft"], in: root, timeout: 30)
        guard listed.status == 0, let rows = try? JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]] else { return nil }
        _ = await GitHubClient.execute(["fetch", "--quiet", "--tags", "origin"], in: root, git: true, timeout: 60)
        for row in rows where (row["isDraft"] as? Bool) != true {
            guard let tag = row["tagName"] as? String, !tag.isEmpty, !tag.hasPrefix("-") else { continue }
            let contains = await GitHubClient.execute(["merge-base", "--is-ancestor", commit, "refs/tags/" + tag], in: root, git: true, timeout: 15)
            if contains.status == 0 { return tag }
        }
        return nil
    }
}
