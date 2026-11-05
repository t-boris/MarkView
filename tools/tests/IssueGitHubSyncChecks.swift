// Checks the GitHub sync planner (MarkView/Models/IssueGitHubSync.swift) and the verified-completion rule of manual Sync
// (MarkView/Models/IssueSync.swift) against REQ-004 criterion 4, REQ-005 criterion 4, REQ-006 criteria 1-5 and DEC-010,
// Q-004 of docs/features/issue-lifecycle-management.
import Foundation

let origin = "t-boris/MarkView"
let boris = LifecycleActor.human("Boris")
let claude = LifecycleActor.ai("claude-code")
let app = LifecycleActor.system("MarkView")
let hand = StartEvidence.handoff(tool: "Claude Code", at: Date())
let done = DeliveryVerdict.complete(summary: ["PR #7 merged", "checks passed"])

func t(_ number: Int, _ repo: String = origin) -> IssueSyncTarget { IssueSyncTarget(repo: repo, number: number) }

func item(_ kind: IssueSyncItem.Kind, _ id: String, _ status: String, fields: [String] = []) -> IssueSyncItem {
    IssueSyncItem(kind: kind, id: id, title: id, status: status, fieldValues: fields, texts: [])
}

func linked(_ kind: IssueSyncItem.Kind, _ id: String, _ status: String, _ completion: IssueCompletionState, issues: [String],
            history: IssueHistory? = nil) -> LinkedItem {
    LinkedItem(item: item(kind, id, status, fields: issues), completion: completion, history: history)
}

func feature(_ id: String, _ status: String, _ completion: IssueCompletionState, issues: [String] = ["#10"], history: IssueHistory? = nil) -> LinkedItem {
    linked(.feature, id, status, completion, issues: issues, history: history)
}

func bug(_ id: String, _ status: String, _ completion: IssueCompletionState, issues: [String] = ["#10"], history: IssueHistory? = nil) -> LinkedItem {
    linked(.bug, id, status, completion, issues: issues, history: history)
}

let verified = IssueCompletionState.verified(basis: ["delivery: PR #7 merged"])

func plan(_ items: [LinkedItem], _ remotes: [IssueSyncTarget: IssueSyncRemote], closedAt: [IssueSyncTarget: Date] = [:]) -> [GitHubAction] {
    IssueGitHubPlanner.plan(items: items, origin: origin, remotes: remotes, closedAt: closedAt)
}

func isWrite(_ action: GitHubAction) -> Bool {
    switch action {
    case .close, .reopen: return true
    default: return false
    }
}

func leaveDetail(_ action: GitHubAction) -> String? { if case .leave(_, let outcome) = action { return outcome.detail } else { return nil } }
func discrepancy(_ action: GitHubAction) -> Discrepancy? { if case .discrepancy(_, let found) = action { return found } else { return nil } }
func reopenReason(_ action: GitHubAction) -> String? { if case .reopen(_, let because) = action { return because } else { return nil } }

let closedTime = Date(timeIntervalSince1970: 1_800_000_100)

func reopenRecord(_ kind: IssueKind, _ issue: String, at seconds: Double) -> TransitionRecord {
    TransitionRecord(phase: .applied, command: UUID().uuidString, kind: kind, issue: issue, from: kind == .feature ? "implemented" : "fixed",
                     to: kind == .feature ? "implementing" : "open", actor: boris, at: Date(timeIntervalSince1970: seconds),
                     reason: "It broke again", transitionKind: .reopen)
}

func history(_ kind: IssueKind, _ issue: String, _ records: [TransitionRecord]) -> IssueHistory {
    IssueHistory(kind: kind, issue: issue, all: records)
}

// MARK: Close only on verified completion of every linked item (REQ-006 criterion 1, DEC-010)

do {
    let actions = plan([feature("f", "implemented", verified)], [t(10): .issue(open: true)])
    check("a verified feature closes its open issue", actions == [.close(t(10), because: ["f"])])
}

do {
    let actions = plan([feature("f1", "implemented", verified), bug("BUG-001", "fixed", verified)], [t(10): .issue(open: true)])
    check("a shared issue closes when every linked item is verified", actions == [.close(t(10), because: ["f1", "BUG-001"])])
}

do {
    let actions = plan([feature("f1", "implemented", verified), feature("f2", "implementing", .notComplete)], [t(10): .issue(open: true)])
    check("a shared issue with unfinished work stays open", !actions.contains(where: isWrite))
    check("it says what is not verified", actions.compactMap(leaveDetail) == ["not verified yet: f2 (implementing)"])
    check("a skipped issue is a skip", { if case .leave(_, let outcome) = actions[0] { return outcome.kind == .skipped } else { return false } }())
}

do {
    let blockers: [(String, String, IssueCompletionState, String)] = [
        ("an unknown state", "implemented", .unknown("the status \"implemented\" is not the one the history ends with"), "unknown: "),
        ("a cancellation", "archived", .cancelled("archived before completion"), "archived before completion"),
        ("an override", "implemented", .overridden, "override"),
        ("an outside edit", "implemented", .unverifiedEdit, "outside MarkView"),
        ("work not complete", "fixing", .notComplete, "fixing"),
    ]
    for (name, status, state, expected) in blockers {
        let actions = plan([feature("f", status, state)], [t(10): .issue(open: true)])
        check("\(name) does not close the issue", !actions.contains(where: isWrite))
        check("\(name) is named in the reason", actions.compactMap(leaveDetail).first?.contains(expected) == true)
        let withVerified = plan([feature("f", status, state), feature("g", "implemented", verified)], [t(10): .issue(open: true)])
        check("\(name) blocks even beside a verified item", !withVerified.contains(where: isWrite))
    }
}

do {
    let duplicate = bug("BUG-002", "closed", .cancelled("closed without a fix: duplicate of BUG-001"))
    let actions = plan([bug("BUG-001", "fixed", verified), duplicate], [t(10): .issue(open: true)])
    check("a bug closed as a duplicate keeps the issue open", !actions.contains(where: isWrite))
    check("with its reason", actions.compactMap(leaveDetail).first?.contains("BUG-002 (closed without a fix: duplicate of BUG-001)") == true)
}

do {
    let override = plan([feature("f", "implemented", .overridden)], [t(10): .issue(open: true)])
    check("a human override alone does not close an issue (REQ-006 criterion 3)", !override.contains(where: isWrite))
    check("it is shown as open despite local completion", override.compactMap(discrepancy).map(\.kind) == [.githubOpenDespiteCompletion])
    check("the discrepancy names the item", override.compactMap(discrepancy).first?.message.contains("f") == true)
    let edited = plan([feature("f", "implemented", .unverifiedEdit), bug("BUG-001", "fixed", .overridden)], [t(10): .issue(open: true)])
    check("outside edits and overrides together show one discrepancy", edited.compactMap(discrepancy).count == 1)
    let mixed = plan([feature("f", "implemented", .overridden), feature("g", "implementing", .notComplete)], [t(10): .issue(open: true)])
    check("work still under way needs no extra note", mixed.compactMap(discrepancy).isEmpty)
    let cancelled = plan([feature("f", "archived", .cancelled("archived before completion"))], [t(10): .issue(open: true)])
    check("a cancellation needs no extra note", cancelled.compactMap(discrepancy).isEmpty)
}

// MARK: Closed on GitHub (Q-004, REQ-005 criterion 4)

do {
    let actions = plan([feature("f", "implemented", verified)], [t(10): .issue(open: false)])
    check("a closed issue with verified work is left as it is", actions == [.leave(t(10), .alreadyClosed)])
}

do {
    let actions = plan([feature("f", "implementing", .notComplete)], [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("a manual closure changes nothing", !actions.contains(where: isWrite))
    check("it shows a discrepancy", actions.compactMap(discrepancy).map(\.kind) == [.githubClosedEarly])
    let message = actions.compactMap(discrepancy).first?.message ?? ""
    check("it names the item and its status", message.contains("f (implementing)"))
    check("it says no status was changed", message.contains("did not change any status"))
    check("it names the issue", message.contains("#10"))
}

do {
    let actions = plan([feature("f", "implemented", verified), bug("BUG-001", "closed", .cancelled("closed without a fix: duplicate of BUG-002"))],
                       [t(10): .issue(open: false)])
    check("a closed issue with a cancelled item shows a discrepancy naming it", actions.compactMap(discrepancy).first?.message.contains("BUG-001") == true
          && actions.compactMap(discrepancy).first?.message.contains("f (") != true)
}

do {
    let actions = plan([feature("f", "implemented", .unknown("no lifecycle history"))], [t(10): .issue(open: false)])
    check("a closed issue with unknown state shows a discrepancy", actions.compactMap(discrepancy).map(\.kind) == [.githubClosedEarly])
}

// MARK: Reopen only when linked work was reopened after the closure (REQ-006 criterion 2)

do {
    let reopened = history(.feature, "f", [reopenRecord(.feature, "f", at: 1_800_000_200)])
    let actions = plan([feature("f", "implementing", .notComplete, history: reopened)], [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("work reopened after the closure reopens the issue", actions.count == 1 && reopenReason(actions[0])?.contains("f (implementing)") == true)
    check("the reason says when", reopenReason(actions[0])?.contains("after the GitHub issue was closed") == true)
    if case .reopen(let target, _) = actions[0] { check("for the right issue", target == t(10)) } else { check("for the right issue", false) }
}

do {
    let earlier = history(.feature, "f", [reopenRecord(.feature, "f", at: 1_800_000_050)])
    let actions = plan([feature("f", "implementing", .notComplete, history: earlier)], [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("a reopen before the closure does not reopen the issue", !actions.contains(where: isWrite))
    check("the closure is only a discrepancy", actions.compactMap(discrepancy).map(\.kind) == [.githubClosedEarly])
}

do {
    let reopened = history(.feature, "f", [reopenRecord(.feature, "f", at: 1_800_000_200)])
    let unknownTime = plan([feature("f", "implementing", .notComplete, history: reopened)], [t(10): .issue(open: false)])
    check("without the closing time nothing is reopened", !unknownTime.contains(where: isWrite))
    check("and the difference is shown", unknownTime.compactMap(discrepancy).map(\.kind) == [.githubClosedEarly])
    let noHistory = plan([feature("f", "implementing", .notComplete)], [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("an item with no history cannot be confirmed reopened", !noHistory.contains(where: isWrite))
}

do {
    let reopened = history(.feature, "f", [reopenRecord(.feature, "f", at: 1_800_000_200)])
    let again = plan([feature("f", "implemented", verified, history: reopened)], [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("work reopened and completed again on evidence does not reopen the issue", again == [.leave(t(10), .alreadyClosed)])
    let withdrawn = plan([feature("f", "implemented", verified, history: reopened)], [t(10): .issue(open: true)])
    check("verified completion after the reopen closes an open issue", withdrawn == [.close(t(10), because: ["f"])])
}

do {
    let reopened = history(.bug, "BUG-001", [reopenRecord(.bug, "BUG-001", at: 1_800_000_200)])
    let actions = plan([feature("f", "implemented", verified), bug("BUG-001", "open", .notComplete, history: reopened)],
                       [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("one reopened item among verified ones reopens the shared issue", actions.count == 1 && reopenReason(actions[0])?.contains("BUG-001 (open)") == true
          && reopenReason(actions[0])?.contains("f (") != true)
}

do {
    let notReopened = history(.feature, "f", [TransitionRecord(phase: .rejected, kind: .feature, issue: "f", from: "implemented", to: "implementing",
                                                              actor: claude, at: Date(timeIntervalSince1970: 1_800_000_200))])
    let actions = plan([feature("f", "implemented", verified, history: notReopened)], [t(10): .issue(open: false)], closedAt: [t(10): closedTime])
    check("a refused reopen does not reopen the issue", actions == [.leave(t(10), .alreadyClosed)])
}

// MARK: Other repositories, pull requests, missing and failed lookups follow manual Sync (DEC-006)

do {
    let items = [
        feature("f", "implemented", verified, issues: ["upstream/MarkView#5"]),
        feature("g", "implemented", verified, issues: ["https://github.com/t-boris/MarkView/pull/20"]),
        feature("h", "implemented", verified, issues: ["#11"]),
        feature("i", "implemented", verified, issues: ["#12"]),
        feature("j", "implemented", verified, issues: ["#13"]),
        feature("k", "implemented", verified, issues: ["#14"]),
        feature("lonely", "implemented", verified, issues: []),
    ]
    let remotes: [IssueSyncTarget: IssueSyncRemote] = [t(11): .pullRequest, t(12): .notFound, t(13): .failed("HTTP 403: Forbidden")]
    let actions = plan(items, remotes)
    check("another repository is skipped", actions.contains(.leave(t(5, "upstream/MarkView"), .otherRepository)))
    check("a pull request link is skipped", actions.contains(.leave(t(20), .pullRequest)))
    check("a number that is a pull request is skipped", actions.contains(.leave(t(11), .pullRequest)))
    check("a missing issue is skipped", actions.contains(.leave(t(12), .notFound)))
    check("a failed lookup is a failure with its message", actions.contains(.leave(t(13), IssueSyncOutcome(kind: .failed, detail: "HTTP 403: Forbidden"))))
    check("no answer is a failure, never a pass", actions.compactMap { action -> IssueSyncOutcome? in
        if case .leave(let target, let outcome) = action, target == t(14) { return outcome } else { return nil }
    }.first?.kind == .failed)
    check("none of them writes", !actions.contains(where: isWrite))
    check("each is the outcome its answer settles", [t(11), t(12), t(13)].allSatisfy { target in
        remotes[target]?.settledOutcome.map { actions.contains(.leave(target, $0)) } ?? false
    })
    check("an unlinked item has no action", actions.count == 6)
    check("lookups come first, then the links known without asking", actions.last == .leave(t(20), .pullRequest) || actions.last == .leave(t(5, "upstream/MarkView"), .otherRepository))
}

do {
    let actions = plan([feature("f", "implemented", verified, issues: ["#10", "#11"]), feature("g", "implementing", .notComplete, issues: ["#11"])],
                       [t(10): .issue(open: true), t(11): .issue(open: true)])
    check("an item linked to two issues closes only those without unfinished work", actions.filter(isWrite) == [.close(t(10), because: ["f"])])
    check("the other stays open", actions.contains(.leave(t(11), IssueSyncOutcome(kind: .skipped, detail: "not verified yet: g (implementing)"))))
}

// MARK: The planner on real histories

do {
    let storage = MemoryTransitionStorage()
    let statuses = MemoryStatusStore()
    var ticks = 0
    let service = IssueTransitionService(storage: storage, statuses: statuses, now: { ticks += 1; return Date(timeIntervalSince1970: 1_800_000_000 + Double(ticks)) })
    statuses.statuses["feature:f"] = "ready"
    statuses.statuses["bug:BUG-001"] = "open"
    statuses.statuses["bug:BUG-002"] = "open"
    func move(_ kind: IssueKind, _ issue: String, _ to: String, _ actor: LifecycleActor, reason: String? = nil, force: Bool = false, evidence: LifecycleEvidence = .none) {
        let from = statuses.status(kind: kind, issue: issue) ?? ""
        _ = service.apply(TransitionRequest(kind: kind, issue: issue, from: from, to: to, actor: actor, reason: reason, force: force, evidence: evidence))
    }
    func entry(_ kind: IssueKind, _ issue: String) -> LinkedItem {
        let status = statuses.status(kind: kind, issue: issue) ?? ""
        let h = service.history(kind, issue)
        return LinkedItem(item: item(kind == .feature ? .feature : .bug, issue, status, fields: ["#10"]),
                          completion: IssueCompletion.state(kind: kind, status: status, history: h, deliveryNow: nil), history: h)
    }
    move(.feature, "f", "implementing", app, evidence: LifecycleEvidence(start: hand))
    move(.feature, "f", "implemented", app, evidence: LifecycleEvidence(delivery: done))
    move(.bug, "BUG-001", "closed", claude, evidence: LifecycleEvidence(cancellation: .duplicate(of: "BUG-002")))
    move(.bug, "BUG-002", "fixing", app, evidence: LifecycleEvidence(start: hand))
    move(.bug, "BUG-002", "fixed", app, evidence: LifecycleEvidence(delivery: done))

    let both = [entry(.feature, "f"), entry(.bug, "BUG-002")]
    check("real histories: verified feature and fixed bug close the issue", plan(both, [t(10): .issue(open: true)]) == [.close(t(10), because: ["f", "BUG-002"])])
    let withDuplicate = both + [entry(.bug, "BUG-001")]
    let blocked = plan(withDuplicate, [t(10): .issue(open: true)])
    check("real histories: a duplicate bug blocks closure", !blocked.contains(where: isWrite) && blocked.compactMap(leaveDetail).first?.contains("BUG-001 (closed without a fix: duplicate of BUG-002)") == true)

    // A person overrides a feature to implemented.
    statuses.statuses["feature:g"] = "implementing"
    move(.feature, "g", "implemented", boris, reason: "Released by hand", force: true, evidence: LifecycleEvidence(delivery: .unknown(reasons: ["offline"])))
    let overridden = plan(both + [entry(.feature, "g")], [t(10): .issue(open: true)])
    check("real histories: a human override alone does not close", !overridden.contains(where: isWrite))

    // The file is edited by hand without MarkView.
    statuses.statuses["feature:f"] = "verified"
    let edited = plan([entry(.feature, "f"), entry(.bug, "BUG-002")], [t(10): .issue(open: true)])
    check("real histories: a status edited outside MarkView does not close", !edited.contains(where: isWrite)
          && edited.compactMap(leaveDetail).first?.contains("f (unknown:") == true)

    // MarkView reopens the bug after GitHub was closed; the closure is by hand.
    statuses.statuses["feature:f"] = "implemented"
    move(.bug, "BUG-002", "open", claude, evidence: LifecycleEvidence(regression: .bug(id: "BUG-077")))
    let afterReopen = [entry(.feature, "f"), entry(.bug, "BUG-002")]
    let closedBefore = Date(timeIntervalSince1970: 1_800_000_000 + 2)
    let reopenPlan = plan(afterReopen, [t(10): .issue(open: false)], closedAt: [t(10): closedBefore])
    check("real histories: a bug reopened after the closure reopens the issue", reopenPlan.count == 1 && reopenReason(reopenPlan[0])?.contains("BUG-002 (open)") == true)
    let closedAfter = Date(timeIntervalSince1970: 1_800_000_000 + 1_000)
    let late = plan(afterReopen, [t(10): .issue(open: false)], closedAt: [t(10): closedAfter])
    check("real histories: a closure after the reopen is a discrepancy only", !late.contains(where: isWrite) && late.compactMap(discrepancy).count == 1)
}

// MARK: How a write ended (REQ-004 criterion 4, REQ-006 criterion 5)

do {
    check("a write that succeeded is confirmed", GitHubWriteClassifier.classify(writeSucceeded: true, remoteAfter: .issue(open: false), expectedOpen: false) == .confirmed)
    check("a success is confirmed even when the re-read is missing", GitHubWriteClassifier.classify(writeSucceeded: true, remoteAfter: nil, expectedOpen: false) == .confirmed)
    check("a lost response that closed the issue is confirmed", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .issue(open: false), expectedOpen: false) == .confirmed)
    check("a lost response that reopened the issue is confirmed", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .issue(open: true), expectedOpen: true) == .confirmed)
    check("a failed close with the issue still open is a failure", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .issue(open: true), expectedOpen: false) == .failed)
    check("a failed reopen with the issue still closed is a failure", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .issue(open: false), expectedOpen: true) == .failed)
    check("a failed call and no re-read is unconfirmed", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: nil, expectedOpen: false) == .unconfirmed)
    check("a failed call and a failed re-read is unconfirmed", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .failed("HTTP 502"), expectedOpen: true) == .unconfirmed)
    check("a failed call and a pull request is a failure", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .pullRequest, expectedOpen: false) == .failed)
    check("a failed call and a vanished issue is a failure", GitHubWriteClassifier.classify(writeSucceeded: false, remoteAfter: .notFound, expectedOpen: false) == .failed)
}

// MARK: The closing time (REQ-006 criterion 2)

do {
    func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
    let expected = utc(2026, 11, 5, 10, 20, 30)
    check("closed_at is read", IssueSyncRemote.closedAt(json: #"{"state":"closed","closed_at":"2026-11-05T10:20:30Z"}"#) == expected)
    let fractional = IssueSyncRemote.closedAt(json: #"{"state":"closed","closed_at":"2026-11-05T10:20:30.250Z"}"#)
    check("closed_at with fractional seconds is read", fractional.map { abs($0.timeIntervalSince(expected) - 0.25) < 0.001 } == true)
    check("an offset is honoured", IssueSyncRemote.closedAt(json: #"{"closed_at":"2026-11-05T12:20:30+02:00"}"#) == expected)
    check("an open issue has none", IssueSyncRemote.closedAt(json: #"{"state":"open","closed_at":null}"#) == nil)
    check("a missing key has none", IssueSyncRemote.closedAt(json: #"{"state":"open"}"#) == nil)
    check("garbage has none", IssueSyncRemote.closedAt(json: "<html>") == nil && IssueSyncRemote.closedAt(json: #"{"closed_at":"yesterday"}"#) == nil)
    check("a number is not a time", IssueSyncRemote.closedAt(json: #"{"closed_at":12}"#) == nil)
    check("parsing the state is unchanged", IssueSyncRemote.parse(json: #"{"state":"closed","closed_at":"2026-11-05T10:20:30Z"}"#) == .issue(open: false))
}

finish("github")
