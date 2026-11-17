import Foundation
import MarkViewCore
import XCTest
@testable import MarkView


extension EditorHostTests {
    func testIssueGitHubSync() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let origin = "t-boris/MarkView"
        let boris = LifecycleActor.human("Boris")
        let claude = LifecycleActor.ai("claude-code")
        let app = LifecycleActor.system("MarkView")
        let hand = StartEvidence.handoff(tool: "Claude Code", at: Date())
        let done = DeliveryVerdict.complete(summary: ["PR #7 merged", "checks passed"])

        func t(_ number: Int, _ repo: String = "t-boris/MarkView") -> IssueSyncTarget { IssueSyncTarget(repo: repo, number: number) }

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

        // MARK: Which actions run on their own (feature-3, DEC-030)

        do {
            let actions: [GitHubAction] = [.close(t(1), because: ["BUG-001"]), .reopen(t(2), because: "BUG-002 was reopened"),
                                           .leave(t(3), IssueSyncOutcome(kind: .skipped, detail: "x")), .discrepancy(t(4), Discrepancy(kind: .githubClosedEarly, message: "x"))]
            check("the synchronization that existed before workflows runs on its own", actions.prefix(2).allSatisfy { !$0.needsConfirmation })
            check("actions that write nothing need no confirmation", actions.suffix(2).allSatisfy { !$0.needsConfirmation })
        }

    }
}


extension EditorHostTests {
    func testIssueLifecycleContext() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
        func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }

        let sessionAI = LifecycleActor.ai("claude-code", session: "s1")
        let person = LifecycleActor.human("Boris")
        let robot = LifecycleActor.system("MarkView")

        func has(_ text: String, _ needle: String) -> Bool { text.contains(needle) }
        func lineCount(_ text: String) -> Int { text.components(separatedBy: "\n").count }

        func record(_ phase: TransitionRecord.Phase, _ from: String, _ to: String, _ actor: LifecycleActor, minute: Int,
                    kind: IssueKind = .feature, issue: String = "export-pdf", reason: String? = nil, override: Bool = false,
                    bypassed: [LifecycleCondition] = [], missing: [LifecycleCondition] = [], transition: TransitionKind? = nil,
                    message: String? = nil, verified: Bool? = nil, id: UUID = UUID()) -> TransitionRecord {
            TransitionRecord(id: id, phase: phase, command: UUID().uuidString, kind: kind, issue: issue, from: from, to: to, actor: actor,
                             at: at(minute), reason: reason, transitionKind: transition, override: override, bypassed: bypassed,
                             missing: missing, message: message, verified: verified)
        }

        func history(_ records: [TransitionRecord], kind: IssueKind = .feature, issue: String = "export-pdf") -> IssueHistory {
            IssueHistory(kind: kind, issue: issue, all: records)
        }

        func attachment(_ session: String, tool: String = "Claude Code", issue: String = "export-pdf", kind: IssueKind = .feature,
                        since: Int = 5, via: SessionAttachment.Via = .attached, seen: Int? = nil) -> SessionAttachment {
            SessionAttachment(issue: issue, kind: kind, session: session, tool: tool, since: at(since), via: via, lastSeen: seen.map(at))
        }

        func featureInput(status: String, delivery: DeliveryVerdict, records: [TransitionRecord] = [], actor: LifecycleActorKind = .ai,
                          criteria: Bool? = nil, sessions: [SessionAttachment] = [], discrepancies: [String] = [],
                          label: String = "not complete", links: [String] = []) -> IssueContextInput {
            IssueContextInput(kind: .feature, issue: "export-pdf", title: "Export to PDF", status: status, history: history(records),
                              delivery: delivery, completionLabel: label, discrepancies: discrepancies, attached: sessions, actor: actor,
                              criteriaTicked: criteria, githubLinks: links)
        }

        func bugInput(status: String, delivery: DeliveryVerdict = .notCollected, actor: LifecycleActorKind = .ai,
                      sessions: [SessionAttachment] = []) -> IssueContextInput {
            IssueContextInput(kind: .bug, issue: "BUG-012", title: "Crash on export", status: status,
                              history: history([], kind: .bug, issue: "BUG-012"), delivery: delivery, attached: sessions, actor: actor)
        }

        // MARK: Guidance (REQ-003 criteria 1 and 3)

        do {
            let guidance = IssueLifecycleContext.guidance
            check("the guidance fits 45 lines", lineCount(guidance) <= 45)
            check("the guidance is plain text", guidance.unicodeScalars.allSatisfy { $0.isASCII })
            for tool in ["markview_issue_context", "markview_attach_issue", "markview_set_status", "markview_set_bug_status",
                         "markview_get_feature", "markview_get_bug"] {
                check("the guidance names \(tool)", has(guidance, tool))
            }
            for status in FeatureVocabulary.featureStatuses + FeatureVocabulary.bugStatuses {
                check("the guidance names the status \(status)", has(guidance, status))
            }
            check("only a person forces a status, with a reason", has(guidance, "Only a person in the MarkView window can force a status, and only with a reason"))
            check("an AI never can, and by_user changes nothing", has(guidance, "You never can") && has(guidance, "by_user: true") && has(guidance, "does not make a request the person's"))
            check("it forbids claiming to be the person", has(guidance, "Never claim to be the person") && has(guidance, "approval"))
            check("start needs a handoff or markview_attach_issue", has(guidance, "start evidence") && has(guidance, "MarkView handed the issue to you") && has(guidance, "you called markview_attach_issue"))
            check("feature completion follows landing and bug completion follows required delivery", has(guidance, "implemented is recorded") && has(guidance, "default branch") && has(guidance, "required checks") && has(guidance, "release"))
            check("an AI request succeeds only on complete evidence", has(guidance, "succeeds only when that evidence is complete"))
            check("unknown evidence is never completion", has(guidance, "never completion") && has(guidance, "unknown is not done"))
            check("acceptance needs evidence text and ticked criteria", has(guidance, "needs your evidence text") && has(guidance, "every acceptance criterion") && has(guidance, "criteria_done"))
            check("reopening needs a human reason or regression_of", has(guidance, "reopens an issue with a reason") && has(guidance, "regression_of"))
            check("a failing check alone reopens nothing", has(guidance, "A failing check alone reopens nothing"))
            check("a duplicate or invalid bug closes with its evidence", has(guidance, "duplicate_of") && has(guidance, "validity check"))
            check("status fields are never edited by hand", has(guidance, "Never edit a status in the Markdown files") && has(guidance, "unverified"))
            check("a refused request is not retried by another route", has(guidance, "A refused request says what is missing") && has(guidance, "another route"))
        }

        // MARK: One issue: a feature being implemented (REQ-003 criteria 1 and 2)

        do {
            let records = [
                record(.baseline, "", "ready", robot, minute: 0, verified: true),
                record(.applied, "ready", "implementing", robot, minute: 5, transition: .start),
            ]
            let incomplete = DeliveryVerdict.incomplete(missing: ["PR #7 is not merged", "2 checks pending"])
            let text = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: incomplete, records: records, criteria: false,
                                                               sessions: [attachment("s1", via: .handoff, seen: 20)], links: ["#294", "#301"]))
            check("the context names the issue, title and status", has(text, "Feature export-pdf: Export to PDF") && has(text, "Status: implementing"))
            check("it states the completion label", has(text, "Completion: not complete"))
            check("it says delivery is incomplete", has(text, "Outstanding work: delivery evidence is incomplete."))
            check("it lists every missing item", has(text, "- PR #7 is not merged") && has(text, "- 2 checks pending"))
            check("it says whether the criteria are ticked", has(text, "Acceptance criteria: not all ticked."))
            check("it points at the status tool for a feature", has(text, "request one with markview_set_status"))
            check("completion lists what is still unmet", has(text, "- implementing → implemented (completion): needs delivery evidence (incomplete; see Outstanding work)."))
            check("archiving is offered with nothing missing", has(text, "- implementing → archived (cancellation, not a completion): nothing missing."))
            check("an AI is not offered the human-only step back", !has(text, "implementing → ready"))
            check("an AI is never shown the override", !text.lowercased().contains("override") && !text.lowercased().contains("force"))
            check("it says anything else is the person's", has(text, "Anything else is the person's to change in the MarkView window."))
            check("it lists the GitHub links", has(text, "GitHub: #294, #301"))
            check("the output is deterministic", text == IssueLifecycleContext.text(featureInput(status: "implementing", delivery: incomplete, records: records, criteria: false,
                                                                                                 sessions: [attachment("s1", via: .handoff, seen: 20)], links: ["#294", "#301"])))
        }

        do {
            let human = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .incomplete(missing: ["PR #7 is not merged"]), actor: .human))
            check("a person is told about the override and its reason", has(human, "override") && has(human, "writing a reason"))
            check("a person sees the step back with its reason", has(human, "- implementing → ready (step back): needs a reason (written by the person)."))
            check("a person is not told that the person decides", !has(human, "Anything else is the person's"))
            let agent = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .incomplete(missing: []), actor: .system))
            check("MarkView's own workflow gets its own header", has(agent, "Next steps open to MarkView:") && !has(agent, "override"))
        }

        do {
            let unknown = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .unknown(reasons: ["GitHub could not be read", "no workflow run found"])))
            check("unknown delivery is named as such", has(unknown, "delivery evidence is unknown (unknown is never completion)"))
            check("the reasons are listed", has(unknown, "- GitHub could not be read") && has(unknown, "- no workflow run found"))
            check("completion is shown as unmet with the unknown verdict", has(unknown, "needs delivery evidence (unknown; see Outstanding work)"))

            let complete = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .complete(summary: ["PR #7 merged", "release v5.36.0"])))
            check("complete delivery says nothing is missing", has(complete, "Outstanding work: no delivery evidence is missing.") && has(complete, "- PR #7 merged"))
            check("completion is then open with nothing missing", has(complete, "- implementing → implemented (completion): nothing missing."))
        }

        do {
            // Acceptance: implemented → verified needs the AI's evidence text and every criterion ticked (DEC-008).
            let done = DeliveryVerdict.complete(summary: ["PR #7 merged"])
            let ticked = IssueLifecycleContext.text(featureInput(status: "implemented", delivery: done, criteria: true, label: "verified completion"))
            let notTicked = IssueLifecycleContext.text(featureInput(status: "implemented", delivery: done, criteria: false))
            let unchecked = IssueLifecycleContext.text(featureInput(status: "implemented", delivery: done, criteria: nil))
            check("acceptance asks for the verification text", has(ticked, "implemented → verified (acceptance): needs acceptance evidence (your verification text, and every acceptance criterion ticked: all ticked)"))
            check("it reports unticked criteria", has(notTicked, "every acceptance criterion ticked: not all ticked") && has(notTicked, "Acceptance criteria: not all ticked."))
            check("it reports criteria it did not check", has(unchecked, "every acceptance criterion ticked: not checked"))
            check("it shows the completion label", has(ticked, "Completion: verified completion"))
            check("reopening needs a regression report for an AI", has(ticked, "implemented → implementing (reopen): needs regression evidence (a bug report whose regression_of names export-pdf)."))
            check("archiving after completion keeps the completion", has(ticked, "implemented → archived (archive, keeps the completion): nothing missing."))
        }

        do {
            // Start evidence comes from a handoff or an attached session (DEC-011).
            let none = IssueLifecycleContext.text(featureInput(status: "ready", delivery: .notCollected))
            check("start without a session needs attaching", has(none, "- ready → implementing (start): needs start evidence (no handoff and no attached session yet: call markview_attach_issue)."))
            check("the specification stages an AI may set are grouped", has(none, "- Within the specification: idea, exploring, draft, review (no evidence needed)."))
            check("resolving is not offered to an AI", !has(none, "resolving"))
            let attached = IssueLifecycleContext.text(featureInput(status: "ready", delivery: .notCollected, sessions: [attachment("s2", since: 9)]))
            check("an attached session is start evidence", has(attached, "- ready → implementing (start): nothing missing."))
            let elsewhere = IssueLifecycleContext.text(featureInput(status: "ready", delivery: .notCollected, sessions: [attachment("s2", issue: "other-feature")]))
            check("a session attached to another issue is not start evidence", has(elsewhere, "ready → implementing (start): needs start evidence"))
            check("and it is not listed here", has(elsewhere, "Sessions: none attached"))
            let personText = IssueLifecycleContext.text(featureInput(status: "ready", delivery: .notCollected, actor: .human))
            check("a person sees every specification stage in vocabulary order", has(personText, "- Within the specification: idea, exploring, draft, review, resolving (no evidence needed)."))
        }

        do {
            let before = IssueLifecycleContext.text(featureInput(status: "idea", delivery: .notCollected))
            check("delivery is not tracked before work starts", has(before, "Outstanding work: delivery is not tracked at status idea"))
            let archived = IssueLifecycleContext.text(featureInput(status: "archived", delivery: .notCollected))
            check("nothing is open to an AI on an archived feature", has(archived, "- none from archived; ask the person."))
            let odd = IssueLifecycleContext.text(featureInput(status: "done", delivery: .complete(summary: ["x"])))
            check("a status outside the vocabulary is unknown state", has(odd, "Status \"done\" is not a feature status (unknown state)") && has(odd, "only a person can move"))
            check("no next steps are invented for it", !has(odd, "Next steps"))
        }

        // MARK: Bugs

        do {
            let open = IssueLifecycleContext.text(bugInput(status: "open"))
            check("a bug names itself and its tool", has(open, "Bug BUG-012: Crash on export") && has(open, "request one with markview_set_bug_status"))
            check("fixing needs start evidence", has(open, "- open → fixing (start): needs start evidence"))
            check("closing without a fix needs duplicate_of or validity", has(open, "- open → closed (closed without a fix, not a completion): needs cancellation evidence (duplicate_of, or the validity check's finding)."))
            check("a bug has no criteria line", !has(open, "Acceptance criteria"))
            let fixed = IssueLifecycleContext.text(bugInput(status: "fixed", delivery: .complete(summary: ["fix merged"])))
            check("closing after a fix asks only for the verification text", has(fixed, "- fixed → closed (acceptance): needs acceptance evidence (your verification text)."))
            check("a fixed bug reopens only with a regression report", has(fixed, "fixed → open (reopen): needs regression evidence (a bug report whose regression_of names BUG-012)."))
            let fixing = IssueLifecycleContext.text(bugInput(status: "fixing", delivery: .incomplete(missing: ["fix not merged"]), sessions: [attachment("b1", issue: "BUG-012", kind: .bug)]))
            check("an AI may put a bug back to open", has(fixing, "- fixing → open (step back): nothing missing."))
            check("fixing → fixed waits for delivery", has(fixing, "- fixing → fixed (completion): needs delivery evidence (incomplete; see Outstanding work)."))
            check("a bug has the lowercase kind in the next-step order", fixing.range(of: "fixing → open")!.lowerBound < fixing.range(of: "fixing → fixed")!.lowerBound)
        }

        // MARK: History, blocked requests, discrepancies (REQ-003 criterion 2, REQ-004)

        do {
            var records: [TransitionRecord] = [record(.baseline, "", "idea", robot, minute: 0, verified: true)]
            let sequence = ["exploring", "draft", "review", "ready"]
            var previous = "idea"
            for (index, status) in sequence.enumerated() {
                records.append(record(.applied, previous, status, person, minute: 1 + index, transition: .spec))
                previous = status
            }
            records.append(record(.applied, "ready", "implementing", robot, minute: 10, transition: .start))
            records.append(record(.applied, "implementing", "implemented", person, minute: 20, reason: "Released by hand, CI was down", override: true,
                                  bypassed: [.deliveryEvidence], transition: .unlisted))
            let text = IssueLifecycleContext.text(featureInput(status: "implemented", delivery: .unknown(reasons: ["GitHub unreachable"]), records: records))
            check("only the last five entries are shown", has(text, "History (newest first; 5 of 7):"))
            check("the oldest entries are left out", !has(text, "(none) → idea") && !has(text, "idea → exploring"))
            check("the newest entry comes first", text.range(of: "implementing → implemented")!.lowerBound < text.range(of: "ready → implementing")!.lowerBound)
            check("an override is flagged with what it bypassed", has(text, "OVERRIDE, bypassed: delivery-evidence"))
            check("the actor and the time are shown", has(text, "2027-01-15 08:20 UTC implementing → implemented by person Boris"))
            check("the reason is shown", has(text, "— reason: Released by hand, CI was down"))
            check("a machine actor is named plainly", has(text, "ready → implementing by MarkView"))
        }

        do {
            var records = [record(.baseline, "", "implemented", robot, minute: 0, verified: true)]
            records.append(record(.external, "implemented", "verified", LifecycleActor(kind: .system, name: "external edit"), minute: 30, verified: false))
            records.append(record(.confirmed, "implemented", "implemented", robot, minute: 40, transition: .completion))
            records.append(record(.recovered, "implemented", "implementing", robot, minute: 50, transition: .reopen))
            let text = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .incomplete(missing: ["PR #9 not merged"]), records: records))
            check("a first sight is marked", has(text, "(none) → implemented by MarkView [first seen]"))
            check("an outside edit is marked unverified", has(text, "changed outside MarkView, unverified"))
            check("a confirmation by evidence is marked", has(text, "confirmed by evidence"))
            check("a recovered operation is marked", has(text, "finished after an interruption"))
        }

        do {
            let unresolved = [record(.baseline, "", "implemented", robot, minute: 0, verified: true),
                              record(.external, "implemented", "verified", LifecycleActor(kind: .system, name: "external edit"), minute: 30, verified: false)]
            let text = IssueLifecycleContext.text(featureInput(status: "verified", delivery: .complete(summary: ["ok"]), records: unresolved,
                                                               discrepancies: ["GitHub issue #294 is closed but the feature is not verified"]))
            check("the caller's discrepancies are listed", has(text, "Discrepancies (not resolved):") && has(text, "- GitHub issue #294 is closed but the feature is not verified"))
            check("an unresolved outside edit is listed", has(text, "The status was changed outside MarkView (implemented → verified, 2027-01-15 08:30 UTC) and is unverified."))
            let clean = IssueLifecycleContext.text(featureInput(status: "implemented", delivery: .complete(summary: ["ok"])))
            check("no discrepancies reads as none", has(clean, "Discrepancies: none."))
            check("an empty history reads as none", has(clean, "History: none recorded."))
        }

        do {
            let begin = record(.begin, "ready", "implementing", robot, minute: 3)
            let text = IssueLifecycleContext.text(featureInput(status: "ready", delivery: .notCollected, records: [begin]))
            check("an unfinished operation is listed", has(text, "An operation ready → implementing began 2027-01-15 08:03 UTC and is not closed"))
        }

        do {
            let rejected = record(.rejected, "implementing", "implemented", sessionAI, minute: 12, missing: [.deliveryEvidence],
                                  message: "implementing → implemented needs delivery evidence (all work merged).")
            let stale = record(.rejected, "ready", "implementing", sessionAI, minute: 13, message: "stale: the stored status is \"implementing\"")
            let text = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .incomplete(missing: ["PR #7 is not merged"]), records: [rejected, stale]))
            check("blocked requests are listed", has(text, "Blocked requests (nothing was changed):"))
            check("a refusal names who asked and what was missing", has(text, "2027-01-15 08:12 UTC AI claude-code (s1) asked implementing → implemented: implementing → implemented needs delivery evidence") && has(text, "(missing: delivery-evidence)"))
            check("a stale request is listed too", has(text, "asked ready → implementing: stale: the stored status is \"implementing\""))
            check("the newest refusal comes first", text.range(of: "asked ready → implementing")!.lowerBound < text.range(of: "asked implementing → implemented")!.lowerBound)

            var many: [TransitionRecord] = []
            for index in 0..<5 { many.append(record(.rejected, "implementing", "implemented", sessionAI, minute: index, message: "no \(index)")) }
            let capped = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .notCollected, records: many))
            check("at most three refusals are shown", capped.components(separatedBy: "asked implementing → implemented").count - 1 == 3 && has(capped, "no 4") && !has(capped, "no 1"))

            let applied = record(.applied, "implementing", "implemented", robot, minute: 300, transition: .completion)
            var old = [rejected]
            for index in 0..<13 { old.append(record(.applied, "a\(index)", "b\(index)", robot, minute: 20 + index, transition: .spec)) }
            old.append(applied)
            let aged = IssueLifecycleContext.text(featureInput(status: "implemented", delivery: .complete(summary: ["ok"]), records: old))
            check("a refusal long before the latest records is not shown", has(aged, "Blocked requests: none recently."))
        }

        // MARK: Sessions: registered is not participating (REQ-003 criterion 4)

        do {
            let sessions = [attachment("s-late", tool: "codex", since: 9, via: .attached),
                            attachment("s-early", tool: "Claude Code", since: 5, via: .handoff, seen: 20)]
            let text = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .notCollected, sessions: sessions))
            check("the section says registration is not participation", has(text, "registered is not participating"))
            check("a session seen calling lifecycle tools shows when", has(text, "- s-early [Claude Code], handed off 2027-01-15 08:05 UTC: seen 2027-01-15 08:20 UTC"))
            check("a session never seen is registered but not seen", has(text, "- s-late [codex], attached 2027-01-15 08:09 UTC: registered but not seen"))
            check("sessions are listed earliest first", text.range(of: "s-early")!.lowerBound < text.range(of: "s-late")!.lowerBound)
            let none = IssueLifecycleContext.text(featureInput(status: "implementing", delivery: .notCollected))
            check("without a session it says how one joins", has(none, "Sessions: none attached.") && has(none, "markview_attach_issue(issue: \"export-pdf\")"))
            check("no linked GitHub issue is said so", has(none, "GitHub: no linked issue."))
        }

        // MARK: Text is one line per item

        do {
            let messy = IssueContextInput(kind: .feature, issue: "export-pdf", title: "Export\n  to\tPDF " + String(repeating: "x", count: 300),
                                          status: " Implementing ", history: history([]), delivery: .incomplete(missing: ["line one\nline two"]))
            let text = IssueLifecycleContext.text(messy)
            check("a title is cut to one short line", text.components(separatedBy: "\n")[0].count < 130 && has(text, "Export to PDF xxx") && has(text, "…"))
            check("the status is normalised", has(text, "Status: implementing"))
            check("a delivery line is one line", has(text, "- line one line two"))
        }

        // MARK: Handoff block

        do {
            let steps = LifecyclePolicy.nextSteps(kind: .feature, status: "ready", actor: .ai, evidence: .none)
            let block = IssueLifecycleContext.handoffBlock(kind: .feature, issue: "export-pdf", status: "ready", nextSteps: steps)
            let count = lineCount(block)
            check("the handoff block is 6 to 10 lines", count >= 6 && count <= 10)
            check("it names the issue and status", has(block, "feature export-pdf (status: ready)"))
            check("it points at the context tool with the issue", has(block, "markview_issue_context(issue: \"export-pdf\")"))
            check("it names the status tool for a feature", has(block, "markview_set_status"))
            check("it says the handoff is the start evidence", has(block, "This handoff is your start evidence"))
            check("it forbids editing the Markdown status", has(block, "never by editing the Markdown files"))
            check("it says a feature is implemented on landing", has(block, "MarkView records implemented when associated implementation lands on the default branch"))
            check("it still allows asking, and refuses early asks", has(block, "you may ask with markview_set_status") && has(block, "refused with what is missing"))
            check("a feature's block asks for the Feature trailer", has(block, "write \"Feature: export-pdf\" on a line of its own"))
            check("it says acceptance needs evidence and ticked criteria", has(block, "verified / closed after a fix needs your evidence text") && has(block, "every acceptance criterion ticked"))
            check("it says the agent is not the person", has(block, "You are not the person") && has(block, "by_user: true does not change that"))
            check("it lists the next steps without the start condition", has(block, "Next steps open to you from ready: implementing; implemented (needs delivery evidence); archived."))
            check("it leaves out the specification stages", !has(block, "exploring"))

            let bugSteps = LifecyclePolicy.nextSteps(kind: .bug, status: "open", actor: .ai, evidence: .none)
            let bug = IssueLifecycleContext.handoffBlock(kind: .bug, issue: "BUG-012", status: " Open ", nextSteps: bugSteps)
            check("a bug names its own tool and status", has(bug, "bug BUG-012 (status: open)") && has(bug, "markview_set_bug_status") && !has(bug, "(markview_set_status)"))
            check("a bug lists fixing, fixed and closed", has(bug, "fixing; fixed (needs delivery evidence); closed (needs duplicate_of or the validity finding)"))
            check("a bug block is also 6 to 10 lines", lineCount(bug) >= 6 && lineCount(bug) <= 10)
            check("a bug block has no Feature trailer line", !has(bug, "Feature:"))

            let nothing = IssueLifecycleContext.handoffBlock(kind: .feature, issue: "export-pdf", status: "archived", nextSteps: [])
            check("with no steps it says to ask the person", has(nothing, "none; ask the person"))
        }

        // MARK: List

        do {
            check("an empty list says how to proceed", has(IssueLifecycleContext.listText([]), "No issue is in progress and no session is attached.")
                  && has(IssueLifecycleContext.listText([]), "markview_attach_issue"))
            let lines = [
                IssueSummaryLine(kind: .bug, issue: "BUG-012", title: "Crash on export", status: "fixing", completionLabel: "not complete",
                                 sessions: [attachment("b1", issue: "BUG-012", kind: .bug, seen: 30)]),
                IssueSummaryLine(kind: .feature, issue: "zeta", title: "Zeta", status: "implementing", sessions: []),
                IssueSummaryLine(kind: .feature, issue: "export-pdf", title: "Export to PDF", status: " Implementing ", completionLabel: "overridden",
                                 sessions: [attachment("s1", seen: 20), attachment("s2")]),
            ]
            let text = IssueLifecycleContext.listText(lines)
            let rows = text.components(separatedBy: "\n")
            check("the list has a header, a row per issue and a footer", rows.count == 5 && has(rows[0], "(3):") && has(rows[4], "markview_issue_context"))
            check("features come first, by name, then bugs", has(rows[1], "feature export-pdf") && has(rows[2], "feature zeta") && has(rows[3], "bug BUG-012"))
            check("a row has the status and completion label", has(rows[1], "[implementing]; overridden"))
            check("a row counts attached and seen sessions", has(rows[1], "sessions: 2 attached, 1 seen") && has(rows[3], "sessions: 1 attached, 1 seen"))
            check("a row without a session says none", has(rows[2], "sessions: none"))
            check("the list is deterministic", text == IssueLifecycleContext.listText(lines.reversed()))
        }

        // MARK: Start evidence from sessions

        do {
            check("no session is no evidence", SessionAttachment.startEvidence([]) == nil)
            if case .handoff(let tool, let when)? = SessionAttachment.startEvidence([attachment("s1", tool: "codex", since: 5, via: .handoff)]) {
                check("a handoff is handoff evidence", tool == "codex" && when == at(5))
            } else { check("a handoff is handoff evidence", false) }
            if case .attached(let session, _)? = SessionAttachment.startEvidence([attachment("s9", since: 9), attachment("s2", since: 4)]) {
                check("the earliest attachment counts", session == "s2")
            } else { check("an attachment is attached evidence", false) }
        }

        // MARK: Session store (Q-005)

        final class Ticker {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        }

        func lines(of url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-sessions-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let ticker = Ticker()
            let store = SessionLinkStore(projectRoot: folder, now: { ticker.now })
            check("the file lives under .dde/lifecycle", store.url.path.hasSuffix(".dde/lifecycle/sessions.jsonl"))
            check("an absent file reads as empty", store.all().isEmpty && store.attachments(for: "export-pdf").isEmpty)

            let first = try! store.attach(issue: "export-pdf", kind: .feature, session: "s1", tool: "Claude Code", via: .attached)
            check("attach returns the link", first.issue == "export-pdf" && first.kind == .feature && first.session == "s1" && first.tool == "Claude Code"
                  && first.via == .attached && first.since == t0 && first.lastSeen == nil)
            check("attach writes one line", lines(of: store.url).count == 1)
            ticker.advance(120)
            let again = try! store.attach(issue: "export-pdf", kind: .feature, session: "s1", tool: "codex", via: .handoff)
            check("attaching twice is idempotent", again == first && lines(of: store.url).count == 1)
            check("the first attachment keeps its way and time", again.via == .attached && again.since == t0)
            check("the same issue in other letters is the same link", (try! store.attach(issue: " Export-PDF ", kind: .feature, session: "s1", tool: "x", via: .attached)) == first)
            check("a stored link equals the returned one", store.attachments(for: "export-pdf") == [first])

            let second = try! store.attach(issue: "export-pdf", kind: .feature, session: "s2", tool: "codex", via: .handoff)
            check("another session is another link", store.attachments(for: "export-pdf") == [first, second] && second.since == t0.addingTimeInterval(120))
            let other = try! store.attach(issue: "BUG-012", kind: .bug, session: "s1", tool: "Claude Code", via: .attached)
            check("one session can work on two issues", store.all().count == 3 && store.attachments(for: "BUG-012") == [other] && store.attachments(for: "nothing").isEmpty)
            check("an empty tool is recorded as unknown", (try! store.attach(issue: "f2", kind: .feature, session: "s3", tool: "  ", via: .attached)).tool == "unknown")

            // Observable participation.
            ticker.advance(60)
            check("a call for an attached issue is associated", store.noteCall(issue: "export-pdf", session: "s1") == true)
            let afterCall = store.attachments(for: "export-pdf")
            check("it stamps that attachment only", afterCall[0].lastSeen == ticker.now && afterCall[1].lastSeen == nil)
            check("another issue of the same session is not stamped", store.attachments(for: "BUG-012")[0].lastSeen == nil)
            check("a call about an issue the session did not attach to is not associated", store.noteCall(issue: "unrelated", session: "s1") == false)
            check("and stamps nothing", store.attachments(for: "export-pdf")[0].lastSeen == ticker.now && store.attachments(for: "BUG-012")[0].lastSeen == nil)
            ticker.advance(120)
            check("a call without an issue is session-wide", store.noteCall(issue: nil, session: "s1") == true)
            check("it stamps every attachment of the session", store.attachments(for: "BUG-012")[0].lastSeen == ticker.now && store.attachments(for: "export-pdf")[0].lastSeen == ticker.now)
            check("other sessions are untouched", store.attachments(for: "export-pdf")[1].lastSeen == nil)

            // Throttle: a busy session does not grow the file with every call.
            let before = lines(of: store.url).count
            ticker.advance(10)
            check("a call right after another is still associated", store.noteCall(issue: nil, session: "s1") == true)
            check("but it is not written again", lines(of: store.url).count == before)
            ticker.advance(SessionLinkStore.seenThrottle + 1)
            store.noteCall(issue: nil, session: "s1")
            check("a later call is written", lines(of: store.url).count == before + 1 && store.attachments(for: "BUG-012")[0].lastSeen == ticker.now)

            // A call from a session that never attached is not recorded.
            ticker.advance(5)
            check("an unattached session's call is not associated", store.noteCall(issue: "export-pdf", session: "stranger") == false)
            check("it creates no attachment", store.all().count == 4 && store.attachments(for: "export-pdf").count == 2)
            check("it writes nothing", lines(of: store.url).count == before + 1)
            check("a call with an empty session is ignored", store.noteCall(issue: "export-pdf", session: "  ") == false)

            // A new store on the same file sees the same links.
            let reopened = SessionLinkStore(url: store.url, now: { ticker.now })
            check("the links survive a restart", reopened.all() == store.all())

            // Validation.
            var rejectedEmptySession = false, rejectedEmptyIssue = false
            do { _ = try store.attach(issue: "export-pdf", kind: .feature, session: "  ", tool: "x", via: .attached) } catch { rejectedEmptySession = (error as? SessionLinkError) == .missing("The session") }
            do { _ = try store.attach(issue: "", kind: .feature, session: "s9", tool: "x", via: .attached) } catch { rejectedEmptyIssue = (error as? SessionLinkError) == .missing("The issue") }
            check("an empty session cannot attach", rejectedEmptySession && store.attachments(for: "export-pdf").count == 2)
            check("an empty issue cannot attach", rejectedEmptyIssue && store.all().count == 4)

            // Start evidence read back from the file.
            if case .attached(let session, _)? = SessionAttachment.startEvidence(store.attachments(for: "export-pdf")) {
                check("the stored links give start evidence", session == "s1")
            } else { check("the stored links give start evidence", false) }
        }

        do {
            // A damaged line is skipped, a cut-off line does not swallow the next record, and an unwritable file is an error.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-sessions-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let ticker = Ticker()
            let store = SessionLinkStore(projectRoot: folder, now: { ticker.now })
            try! store.attach(issue: "export-pdf", kind: .feature, session: "s1", tool: "Claude Code", via: .handoff)
            var handle = try! FileHandle(forWritingTo: store.url)
            handle.seekToEndOfFile()
            handle.write(Data("{ damaged line\n".utf8))
            try? handle.close()
            ticker.advance(60)
            try! store.attach(issue: "export-pdf", kind: .feature, session: "s2", tool: "codex", via: .attached)
            check("a damaged line is skipped", store.all().map(\.session) == ["s1", "s2"] && lines(of: store.url).count == 3)

            handle = try! FileHandle(forWritingTo: store.url)
            handle.seekToEndOfFile()
            handle.write(Data("{\"op\":\"attach\",\"sess".utf8))   // cut off, no newline
            try? handle.close()
            ticker.advance(60)
            let after = try! store.attach(issue: "export-pdf", kind: .feature, session: "s3", tool: "cline", via: .attached)
            let reread = SessionLinkStore(url: store.url).all()
            check("a record after a cut-off line is not lost", reread.map(\.session) == ["s1", "s2", "s3"] && reread.last == after)
            check("the handoff way is kept in the file", reread[0].via == .handoff && reread[1].via == .attached)

            let blocker = folder.appendingPathComponent("blocker")
            try! Data("x".utf8).write(to: blocker)
            let broken = SessionLinkStore(url: blocker.appendingPathComponent("sub/sessions.jsonl"))
            var failed = false
            do { _ = try broken.attach(issue: "export-pdf", kind: .feature, session: "s1", tool: "x", via: .attached) } catch { failed = true }
            check("a link that cannot be written is an error, not a silent success", failed && broken.all().isEmpty)
            check("a sighting that cannot be written is not associated", broken.noteCall(issue: "export-pdf", session: "s1") == false)
        }

        // MARK: The workflow and the rule variant in the context (feature-3)

        do {
            var workflow = ProjectWorkflow.standard
            workflow.variants.append(VariantTemplate.manualWork.variant(kind: .feature, id: "by-hand"))
            let input = IssueContextInput(kind: .feature, issue: "export-pdf", title: "Export to PDF", status: "ready", history: history([]),
                                          delivery: .notCollected, actor: .human, workflow: workflow, variantID: "by-hand")
            let text = IssueLifecycleContext.text(input)
            check("the context names the rule variant and what it requires", text.contains("Rule variant: Manual work, accepted by a person") && text.contains("accepted by: a person"))
            check("a variant that accepts a note says a note starts the work", text.contains("a person writes a note that manual work has started"))
            let standardText = IssueLifecycleContext.text(featureInput(status: "ready", delivery: .notCollected, actor: .human))
            check("the standard variant does not offer a note", !standardText.contains("a person writes a note"))
            check("the standard variant is named too", standardText.contains("Rule variant: Standard feature"))

            let ai = IssueContextInput(kind: .feature, issue: "export-pdf", title: "Export to PDF", status: "implemented", history: history([]),
                                       delivery: .complete(summary: ["PR #7 merged"]), actor: .ai, workflow: workflow, variantID: "by-hand")
            check("under a person-only variant an AI is told a person must accept", IssueLifecycleContext.text(ai).contains("a person's acceptance"))

            let problem = IssueContextInput(kind: .feature, issue: "export-pdf", title: "Export to PDF", status: "ready", history: history([]),
                                            delivery: .notCollected, actor: .ai, workflowProblem: "The project workflow file cannot be used (the file is not a JSON object).")
            check("a workflow that cannot be read is said to be replaced by the standard rules", IssueLifecycleContext.text(problem).contains("The standard rules apply until it is repaired."))

            check("the guidance is the standard text for the standard workflow", IssueLifecycleContext.guidance(for: .standard) == IssueLifecycleContext.guidance)
            var custom = ProjectWorkflow.standard
            custom.bug.statuses = custom.bug.statuses.map { WorkflowStatus(id: $0.id == "fixing" ? "doing" : $0.id, role: $0.role) }
            check("the guidance names the statuses of a different workflow", IssueLifecycleContext.guidance(for: custom).contains("doing (active)"))

            let note = TransitionRecord(phase: .evidence, command: "e1", kind: .feature, issue: "export-pdf", actor: .human("Boris"), at: Date(), reason: "Started by hand",
                                        humanEvidence: .start)
            let withNote = IssueContextInput(kind: .feature, issue: "export-pdf", title: "Export to PDF", status: "ready", history: history([note]),
                                             delivery: .notCollected, actor: .human, workflow: workflow, variantID: "by-hand")
            check("a pending start note makes the start step need nothing more", !IssueLifecycleContext.text(withNote).contains("ready → implementing (start): needs start evidence"))
        }

    }
}


extension EditorHostTests {
    func testIssueLifecycleFileStore() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("markview-store-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        func write(_ text: String, _ path: String) {
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "<missing>" }
        func journalLines() -> Int { read(".dde/lifecycle/transitions.jsonl").split(separator: "\n").count }

        let demo = "docs/features/demo/overview.md"
        let crash = "docs/bugs/BUG-001-crash-on-export.md"
        let longer = "docs/bugs/BUG-0010-other.md"
        write("---\ntitle: Demo\nstatus: draft\nowner: Boris\n---\n\nBody text.\n", demo)
        write("---\ntype: bug\nid: BUG-001\ntitle: Crash\nstatus: open\nseverity: high\n---\n\n## Summary\n\nIt crashes.\n", crash)
        write("---\ntype: bug\nid: BUG-0010\ntitle: Other\nstatus: open\n---\n\nOther.\n", longer)
        write("---\ntitle: No status\n---\n\nText.\n", "docs/features/plain/overview.md")
        write("---\ntype: bug\nid: BUG-002\ntitle: No status\n---\n\nText.\n", "docs/bugs/BUG-002-no-status.md")
        try? fm.createDirectory(at: root.appendingPathComponent("docs/features/hand-written"), withIntermediateDirectories: true)

        let statuses = MarkdownIssueStatusStore(root: root)
        let service = IssueTransitionService(storage: FileTransitionStorage(projectRoot: root), statuses: statuses)
        let person = LifecycleActor.human("Boris")
        let agent = LifecycleActor.ai("Claude Code", session: "s1")

        // MARK: Reading

        check("a feature's status is read from its overview", statuses.status(kind: .feature, issue: "demo") == "draft")
        check("a bug's status is read from its report", statuses.status(kind: .bug, issue: "BUG-001") == "open")
        check("a feature with no status line is an idea", statuses.status(kind: .feature, issue: "plain") == "idea")
        check("a bug with no status line is open", statuses.status(kind: .bug, issue: "BUG-002") == "open")
        check("a hand-written feature folder without an overview is a draft", statuses.status(kind: .feature, issue: "hand-written") == "draft")
        check("an unknown feature has no status", statuses.status(kind: .feature, issue: "missing") == nil)
        check("a slug cannot leave the features folder", statuses.status(kind: .feature, issue: "../bugs") == nil && statuses.status(kind: .feature, issue: "demo/../demo") == nil)
        check("a bug is found by its key, not by a longer key it prefixes", statuses.bugFile(key: "BUG-001")?.lastPathComponent == "BUG-001-crash-on-export.md")
        check("the longer key is found by its own", statuses.bugFile(key: "BUG-0010")?.lastPathComponent == "BUG-0010-other.md")
        check("an unknown bug has no status", statuses.status(kind: .bug, issue: "BUG-999") == nil)
        write("---\ntype: bug\nid: BUG-003\nstatus: open\n---\n", "docs/bugs/BUG-003-new.md")
        check("a bug created after the directory index was built is found", statuses.status(kind: .bug, issue: "BUG-003") == "open")
        try! fm.moveItem(at: root.appendingPathComponent("docs/bugs/BUG-003-new.md"), to: root.appendingPathComponent("docs/bugs/BUG-003-renamed.md"))
        check("a renamed bug refreshes the directory index", statuses.bugFile(key: "BUG-003")?.lastPathComponent == "BUG-003-renamed.md")
        try! fm.removeItem(at: root.appendingPathComponent("docs/bugs/BUG-003-renamed.md"))
        check("a deleted bug disappears from the directory index", statuses.status(kind: .bug, issue: "BUG-003") == nil)

        // MARK: A step writes the status line and nothing else

        let first = service.apply(TransitionRequest(kind: .feature, issue: "demo", from: "draft", to: "review", actor: person))
        check("a specification step by a person is applied", first.isApplied)
        check("only the status line of the overview changed, and the file got its schema", read(demo) == "---\ntitle: Demo\nstatus: review\nowner: Boris\nschema: 1\n---\n\nBody text.\n")
        check("the journal holds the begin and the applied record", journalLines() == 2)
        check("the history ends with the new status", service.history(.feature, "demo").expectedStatus == "review")

        let before = read(demo)
        let stale = service.apply(TransitionRequest(kind: .feature, issue: "demo", from: "draft", to: "ready", actor: person))
        if case .stale(let current) = stale { check("a request made from an old status is stale and names the current one", current == "review") } else { check("a request made from an old status is stale and names the current one", false) }
        check("a stale request changes no file", read(demo) == before)

        let command = UUID().uuidString
        let one = service.apply(TransitionRequest(command: command, kind: .feature, issue: "demo", from: "review", to: "ready", actor: person))
        let again = service.apply(TransitionRequest(command: command, kind: .feature, issue: "demo", from: "review", to: "ready", actor: person))
        check("the same command twice is applied once", one.isApplied && !again.isApplied && read(demo).contains("status: ready"))
        check("and the second answer is the first outcome", { if case .duplicate = again { return true } else { return false } }())

        // MARK: A bug is found by its key and only its report changes

        let started = service.apply(TransitionRequest(kind: .bug, issue: "BUG-001", from: "open", to: "fixing", actor: person,
                                                      evidence: LifecycleEvidence(start: .handoff(tool: "Claude Code", at: Date()))))
        check("a hand-off starts a bug", started.isApplied)
        check("only that bug's report changed", read(crash).contains("status: fixing") && read(longer).contains("status: open"))
        check("the rest of the report is untouched", read(crash) == "---\ntype: bug\nid: BUG-001\ntitle: Crash\nstatus: fixing\nseverity: high\nschema: 1\n---\n\n## Summary\n\nIt crashes.\n")

        // MARK: A refused request changes nothing but the journal

        let beforeRefused = read(crash)
        let linesBefore = journalLines()
        let refused = service.apply(TransitionRequest(kind: .bug, issue: "BUG-001", from: "fixing", to: "fixed", actor: agent))
        if case .rejected(let rejection) = refused {
            check("an AI cannot record a fix without delivery evidence", rejection.missing.contains(.deliveryEvidence))
        } else {
            check("an AI cannot record a fix without delivery evidence", false)
        }
        check("a refused request leaves the report alone", read(crash) == beforeRefused)
        check("but it is kept so the person can inspect it", journalLines() == linesBefore + 1 && service.history(.bug, "BUG-001").rejections.count == 1)
        let forced = service.apply(TransitionRequest(kind: .bug, issue: "BUG-001", from: "fixing", to: "fixed", actor: agent, reason: "just do it", force: true))
        check("an AI cannot force it", !forced.isApplied && read(crash) == beforeRefused)

        // MARK: The schema of the files (AR-39)

        let legacyText = "---\ntitle: Legacy\nstatus: draft\n---\n\nOld.\n"
        write(legacyText, "docs/features/legacy/overview.md")
        check("a file written before the schema is read as it is: its status is known and its bytes stay",
              statuses.status(kind: .feature, issue: "legacy") == "draft" && read("docs/features/legacy/overview.md") == legacyText)
        let legacyStep = service.apply(TransitionRequest(kind: .feature, issue: "legacy", from: "draft", to: "review", actor: person))
        check("its next write adds the schema and changes nothing else",
              legacyStep.isApplied && read("docs/features/legacy/overview.md") == "---\ntitle: Legacy\nstatus: review\nschema: 1\n---\n\nOld.\n")
        let legacyAgain = service.apply(TransitionRequest(kind: .feature, issue: "legacy", from: "review", to: "ready", actor: person))
        check("a file that has the schema keeps one schema line",
              legacyAgain.isApplied && read("docs/features/legacy/overview.md") == "---\ntitle: Legacy\nstatus: ready\nschema: 1\n---\n\nOld.\n")
        let futureText = "---\ntitle: Future\nstatus: draft\nschema: 99\nnew_field: kept\n---\n\nNew.\n"
        write(futureText, "docs/features/future/overview.md")
        check("a file of a newer schema is read: its status is known", statuses.status(kind: .feature, issue: "future") == "draft")
        let futureStep = service.apply(TransitionRequest(kind: .feature, issue: "future", from: "draft", to: "review", actor: person))
        check("a step on a file of a newer schema is not written and the file is untouched",
              !futureStep.isApplied && read("docs/features/future/overview.md") == futureText)

        // MARK: What the files cannot take

        write("---\ntitle: Commented\nstatus: draft\n# keep this comment\nowner: Boris\n---\n\nText.\n", "docs/features/commented/overview.md")
        let commented = read("docs/features/commented/overview.md")
        let lossy = service.apply(TransitionRequest(kind: .feature, issue: "commented", from: "draft", to: "review", actor: person))
        check("front matter the app cannot rewrite without loss is refused, not damaged", !lossy.isApplied && read("docs/features/commented/overview.md") == commented)
        let missing = service.apply(TransitionRequest(kind: .feature, issue: "nothing-here", from: "draft", to: "review", actor: person))
        check("an issue that has no file is a failure", { if case .failed = missing { return true } else { return false } }())

        // MARK: A hand edit of the Markdown is detected and is not completion (REQ-005 criterion 3)

        write(read(demo).replacingOccurrences(of: "status: ready", with: "status: implemented"), demo)
        let restarted = IssueTransitionService(storage: FileTransitionStorage(projectRoot: root), statuses: MarkdownIssueStatusStore(root: root))
        let history = restarted.history(.feature, "demo")
        check("the history survives a restart", history.expectedStatus == "ready" && history.changes.count >= 2)
        check("times survive a restart to the millisecond", zip(service.history(.feature, "demo").records, history.records).allSatisfy { abs($0.at.timeIntervalSince($1.at)) < 0.001 })
        check("and keep their order within a second", history.records.map(\.at) == history.records.map(\.at).sorted())
        let stored = MarkdownIssueStatusStore(root: root).status(kind: .feature, issue: "demo") ?? ""
        let actions = IssueReconciler.actions(ReconcileInput(kind: .feature, issue: "demo", storedStatus: stored, history: history))
        check("the reconciler sees a status the history did not set", actions.contains(.externalEdit(from: "ready", to: "implemented")))
        check("the edit is recorded as unverified", restarted.recordExternalEdit(.feature, "demo", from: "ready", to: "implemented")?.verified == false)
        let afterEdit = restarted.history(.feature, "demo")
        check("it is an unresolved discrepancy", afterEdit.unresolvedExternal.count == 1)
        let state = IssueCompletion.state(kind: .feature, status: "implemented", history: afterEdit, deliveryNow: nil)
        check("and the status does not count as verified completion", !IssueCompletion.isVerified(state))
        check("the edit is not repeated while it is recorded", restarted.recordExternalEdit(.feature, "demo", from: "ready", to: "implemented") == nil
              && restarted.history(.feature, "demo").unresolvedExternal.count == 1)

        // MARK: Appending

        do {
            let file = root.appendingPathComponent("append/lines.jsonl")
            try! JSONLinesFile.append(Data("{\"a\":1}\n".utf8), to: file)
            try! JSONLinesFile.append(Data("{\"a\":2}\n".utf8), to: file)
            check("lines are appended in order, the file and its folder are created", (try? String(contentsOf: file, encoding: .utf8)) == "{\"a\":1}\n{\"a\":2}\n")
            let cut = root.appendingPathComponent("append/cut.jsonl")
            try! Data("{\"a\":1}\n{\"a\":".utf8).write(to: cut)
            try! JSONLinesFile.append(Data("{\"a\":3}\n".utf8), to: cut)
            check("a line cut short is ended before the next one", (try? String(contentsOf: cut, encoding: .utf8)) == "{\"a\":1}\n{\"a\":\n{\"a\":3}\n")
            // Two writers that hold no lock in common (two windows on one project) lose nothing.
            let busy = root.appendingPathComponent("append/busy.jsonl")
            DispatchQueue.concurrentPerform(iterations: 200) { index in
                let storage = FileTransitionStorage(url: busy)
                try? storage.append(TransitionRecord(phase: .baseline, command: "c\(index)", kind: .feature, issue: "f\(index)", to: "ready", actor: .system("test")))
            }
            let loaded = (try? FileTransitionStorage(url: busy).load()) ?? []
            check("200 concurrent appends by separate writers all survive", loaded.count == 200 && Set(loaded.map(\.issue)).count == 200)
        }

        try? fm.removeItem(at: root)
    }
}
