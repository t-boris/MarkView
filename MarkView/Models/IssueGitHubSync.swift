import Foundation

// What to do with the GitHub issues linked to features and bugs (issue-lifecycle-management, REQ-006, REQ-005 criterion 4,
// REQ-004 criterion 4, DEC-010, Q-004): close an open issue only when every linked item has verified completion, reopen a
// closed one when linked work was reopened after the closure, and only show a difference when a person closed it by
// hand. The plan is pure: it reads a snapshot (items, their completion, what GitHub says) and returns the writes and
// the notes; the runner carries the writes out and records their outcome. Foundation only (with IssueSync.swift,
// IssueListing.swift, IssueCompletion.swift), so tools/tests/issue-lifecycle-tests.sh compiles it on its own.

/// A feature or bug as the planner sees it: what Sync read from disk, how far its completion is proven, its history.
struct LinkedItem: Equatable, Sendable {
    var item: IssueSyncItem
    var completion: IssueCompletionState
    /// Needed to tell a reopen after the GitHub closure; nil when the item has no history.
    var history: IssueHistory?

    init(item: IssueSyncItem, completion: IssueCompletionState, history: IssueHistory? = nil) {
        self.item = item
        self.completion = completion
        self.history = history
    }
}

/// One thing to do or to show about one GitHub issue. At most one `close` or `reopen` per issue.
enum GitHubAction: Equatable, Sendable {
    /// Close as completed. `because` names the linked items whose completion is verified.
    case close(IssueSyncTarget, because: [String])
    /// Reopen. `because` says which linked work was reopened.
    case reopen(IssueSyncTarget, because: String)
    /// Nothing to write; the outcome is what the report shows (other repository, pull request, not verified yet, ...).
    case leave(IssueSyncTarget, IssueSyncOutcome)
    /// Nothing to write, but GitHub and MarkView disagree and a person should look. Local statuses are never changed
    /// because of GitHub (Q-004).
    case discrepancy(IssueSyncTarget, Discrepancy)

    /// Whether a person has to confirm the action before it writes to GitHub (feature-3, DEC-030, Q-003). The classification is a
    /// function of the action type: this switch has no default, so a new action type does not compile until it is classified, and the
    /// runner carries out only actions that need no confirmation. Only the synchronization that existed before workflows (close on
    /// verified completion, reopen when linked work was reopened) and the actions that write nothing run on their own; any other
    /// kind of action starts as `true` and is shown to the person first.
    var needsConfirmation: Bool {
        switch self {
        case .close, .reopen: return false
        case .leave, .discrepancy: return false
        }
    }
}

enum IssueGitHubPlanner {
    /// The actions for every issue the items link to: the lookups in the order of the plan, then the issues known from
    /// the links alone (other repositories, pull request links) in order.
    ///
    /// - `remotes`: what GitHub said about each looked-up issue just now. A missing answer is a failure, not a pass.
    /// - `closedAt`: when a closed issue was closed (`IssueSyncRemote.closedAt(json:)`).
    static func plan(items: [LinkedItem], origin: String, remotes: [IssueSyncTarget: IssueSyncRemote],
                     closedAt: [IssueSyncTarget: Date]) -> [GitHubAction] {
        let plan = IssueSyncPlan(items: items.map(\.item), origin: origin)
        var actions: [GitHubAction] = []

        for target in plan.lookups {
            let linked = linkedItems(of: target, plan: plan, items: items)
            guard let remote = remotes[target] else {
                actions.append(.leave(target, IssueSyncOutcome(kind: .failed, detail: "GitHub was not asked about this issue")))
                continue
            }
            if let settled = remote.settledOutcome {
                actions.append(.leave(target, settled))
                continue
            }
            switch remote {
            case .issue(open: true):
                actions += openIssue(target, linked: linked, origin: origin)
            case .issue(open: false):
                actions += closedIssue(target, linked: linked, origin: origin, closedAt: closedAt[target])
            case .pullRequest, .notFound, .failed:
                break  // settled above
            }
        }
        for target in plan.known.keys.sorted() {
            if let outcome = plan.known[target] { actions.append(.leave(target, outcome)) }
        }
        return actions
    }

    // MARK: Open on GitHub

    private static func openIssue(_ target: IssueSyncTarget, linked: [LinkedItem], origin: String) -> [GitHubAction] {
        guard !linked.isEmpty else {
            return [.leave(target, IssueSyncOutcome(kind: .skipped, detail: "no linked feature or bug"))]
        }
        let unverified = linked.filter { !IssueCompletion.isVerified($0.completion) }
        if unverified.isEmpty { return [.close(target, because: linked.map(\.item.id))] }

        var actions: [GitHubAction] = [
            .leave(target, IssueSyncOutcome(kind: .skipped, detail: "not verified yet: " + unverified.map(label).joined(separator: ", "))),
        ]
        // Everything unproven is completed locally, only by an override or an outside edit: the person decides.
        if unverified.allSatisfy({ isCompletedUnproven($0.completion) }) {
            let names = unverified.map(\.item.id).joined(separator: ", ")
            actions.append(.discrepancy(target, Discrepancy(kind: .githubOpenDespiteCompletion,
                message: "\(target.label(origin: origin)) is open, but \(names) is completed in MarkView without verified completion. MarkView closes a GitHub issue only on verified completion; confirm the completion with delivery evidence or close the issue yourself.")))
        }
        return actions
    }

    // MARK: Closed on GitHub

    private static func closedIssue(_ target: IssueSyncTarget, linked: [LinkedItem], origin: String, closedAt: Date?) -> [GitHubAction] {
        if let closedAt {
            let reopened = linked.filter { entry in
                guard let history = entry.history else { return false }
                return IssueCompletion.reopened(after: closedAt, in: history) && !IssueCompletion.isVerified(entry.completion)
            }
            if !reopened.isEmpty {
                let names = reopened.map { "\($0.item.id) (\(statusText($0.item)))" }.joined(separator: ", ")
                return [.reopen(target, because: "\(names) reopened after the GitHub issue was closed")]
            }
        }
        let unverified = linked.filter { !IssueCompletion.isVerified($0.completion) }
        if unverified.isEmpty { return [.leave(target, .alreadyClosed)] }
        // A person closed it, or MarkView's own closure no longer holds: only a note, the local status stands (REQ-005 criterion 4).
        let names = unverified.map(label).joined(separator: ", ")
        return [.discrepancy(target, Discrepancy(kind: .githubClosedEarly,
            message: "\(target.label(origin: origin)) is closed on GitHub, but \(names) is not verified complete. MarkView did not change any status; reopen the issue or finish the work."))]
    }

    // MARK: Helpers

    /// Items linking to `target`, once each, in list order, with their completion.
    private static func linkedItems(of target: IssueSyncTarget, plan: IssueSyncPlan, items: [LinkedItem]) -> [LinkedItem] {
        var seen = Set<Int>()
        return plan.pairs.filter { $0.target == target && seen.insert($0.item).inserted }.map { items[$0.item] }
    }

    private static func isCompletedUnproven(_ state: IssueCompletionState) -> Bool {
        switch state {
        case .overridden, .unverifiedEdit: return true
        default: return false
        }
    }

    private static func statusText(_ item: IssueSyncItem) -> String {
        let value = IssueStatus.normalize(item.status)
        return value.isEmpty ? "no status" : value
    }

    /// "BUG-003 (fixing)", "f (completed by a person's override, not verified)".
    private static func label(_ entry: LinkedItem) -> String {
        let reason: String
        switch entry.completion {
        case .verified: reason = "verified"
        case .notComplete: reason = statusText(entry.item)
        case .cancelled(let message): reason = message
        case .overridden: reason = "completed by a person's override, not verified"
        case .unverifiedEdit: reason = "completed outside MarkView, not confirmed"
        case .unknown(let message): reason = "unknown: \(message)"
        }
        return "\(entry.item.id) (\(reason))"
    }
}

/// How a GitHub close or reopen ended, from the call and from what GitHub shows afterwards (REQ-004 criterion 4,
/// REQ-006 criterion 5: a retry reconciles the actual remote outcome). The caller reads the issue again after a failed call.
enum GitHubWriteClassifier {
    /// - `writeSucceeded`: the call returned success.
    /// - `remoteAfter`: the issue as read after the call; nil when it could not be read.
    /// - `expectedOpen`: the state the write aimed at (false for a close, true for a reopen).
    static func classify(writeSucceeded: Bool, remoteAfter: IssueSyncRemote?, expectedOpen: Bool) -> GitHubWriteOutcome {
        if writeSucceeded { return .confirmed }
        guard let remoteAfter else { return .unconfirmed }
        switch remoteAfter {
        case .issue(let open):
            // The response was lost but the state changed, or the call really failed and nothing changed.
            return open == expectedOpen ? .confirmed : .failed
        case .failed:
            return .unconfirmed
        case .pullRequest, .notFound:
            // Not an issue we could have changed.
            return .failed
        }
    }
}
