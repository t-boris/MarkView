// Checks verified completion (MarkView/Models/IssueCompletion.swift) and the reconciler (IssueReconciler.swift) against
// REQ-005 criteria 1-3 and 5, REQ-006 criteria 3-4 and DEC-009, DEC-010, DEC-013, DEC-015 of
// docs/features/issue-lifecycle-management.
import Foundation

let boris = LifecycleActor.human("Boris")
let claude = LifecycleActor.ai("claude-code")
let app = LifecycleActor.system("MarkView")
let hand = StartEvidence.handoff(tool: "Claude Code", at: Date())
let done = DeliveryVerdict.complete(summary: ["PR #7 merged", "checks passed"])
let notDone = DeliveryVerdict.incomplete(missing: ["required check Build failed"])
let cannotTell = DeliveryVerdict.unknown(reasons: ["GitHub unreachable"])
let start = LifecycleEvidence(start: hand)
let delivered = LifecycleEvidence(delivery: done)
let baseTime = 1_800_000_000.0

struct Rig {
    let storage = MemoryTransitionStorage()
    let statuses = MemoryStatusStore()
    let service: IssueTransitionService
    let kind: IssueKind
    let issue: String

    init(_ status: String, kind: IssueKind = .feature) {
        let issue = kind == .feature ? "f" : "BUG-001"
        self.kind = kind
        self.issue = issue
        let storage = self.storage, statuses = self.statuses
        statuses.statuses[MemoryStatusStore.key(kind, issue)] = status
        var ticks = 0
        service = IssueTransitionService(storage: storage, statuses: statuses,
                                         now: { ticks += 1; return Date(timeIntervalSince1970: baseTime + Double(ticks)) })
    }

    var status: String { statuses.status(kind: kind, issue: issue) ?? "" }
    var history: IssueHistory { service.history(kind, issue) }

    @discardableResult
    func move(_ to: String, _ actor: LifecycleActor, reason: String? = nil, force: Bool = false,
              evidence: LifecycleEvidence = .none, command: String = UUID().uuidString) -> ApplyResult {
        service.apply(TransitionRequest(command: command, kind: kind, issue: issue, from: status, to: to, actor: actor,
                                        reason: reason, force: force, evidence: evidence))
    }

    /// A person edits the file by hand: the status changes, nothing is recorded.
    func edit(_ to: String) { statuses.statuses[MemoryStatusStore.key(kind, issue)] = to }

    func state(_ delivery: DeliveryVerdict? = nil) -> IssueCompletionState {
        IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery)
    }

    func input(_ delivery: DeliveryVerdict? = nil, regression: String? = nil) -> ReconcileInput {
        ReconcileInput(kind: kind, issue: issue, storedStatus: status, history: history, delivery: delivery, regressionBug: regression)
    }

    func actions(_ delivery: DeliveryVerdict? = nil, regression: String? = nil) -> [ReconcileAction] {
        IssueReconciler.actions(input(delivery, regression: regression))
    }

    func discrepancies(_ delivery: DeliveryVerdict? = nil, regression: String? = nil) -> [Discrepancy] {
        IssueReconciler.discrepancies(input(delivery, regression: regression))
    }

    /// Carries the actions out the way the app's runner does.
    func run(_ actions: [ReconcileAction]) {
        for action in actions {
            switch action {
            case .baseline(let status): service.recordBaseline(kind, issue, status: status)
            case .externalEdit(let from, let to): service.recordExternalEdit(kind, issue, from: from, to: to)
            case .confirm(let status, let evidence): service.recordConfirmation(kind, issue, status: status, evidence: evidence)
            case .reopen(let bug, _):
                move(kind == .feature ? "implementing" : "open", claude, evidence: LifecycleEvidence(regression: .bug(id: bug)))
            case .recoverPending: service.recoverPending()
            }
        }
    }
}

func basis(_ state: IssueCompletionState) -> [String]? { if case .verified(let lines) = state { return lines } else { return nil } }
func cancelled(_ state: IssueCompletionState) -> String? { if case .cancelled(let text) = state { return text } else { return nil } }
func unknownReason(_ state: IssueCompletionState) -> String? { if case .unknown(let text) = state { return text } else { return nil } }
func isApplied(_ result: ApplyResult) -> Bool { result.isApplied }
func kinds(_ list: [Discrepancy]) -> [Discrepancy.Kind] { list.map(\.kind) }

func completedFeature() -> Rig {
    let rig = Rig("ready")
    rig.move("implementing", app, evidence: start)
    rig.move("implemented", app, evidence: delivered)
    return rig
}

func fixedBug() -> Rig {
    let rig = Rig("open", kind: .bug)
    rig.move("fixing", app, evidence: start)
    rig.move("fixed", app, evidence: delivered)
    return rig
}

/// A feature completed by a person's override: delivery evidence missing.
func overriddenFeature() -> Rig {
    let rig = Rig("implementing")
    rig.move("implemented", boris, reason: "Released by hand", force: true, evidence: LifecycleEvidence(delivery: cannotTell))
    return rig
}

/// A feature whose file was edited to `implemented` outside MarkView, the edit recorded.
func editedFeature() -> Rig {
    let rig = Rig("ready")
    rig.service.recordBaseline(.feature, "f", status: "ready")
    rig.edit("implemented")
    rig.service.recordExternalEdit(.feature, "f", from: "ready", to: "implemented")
    return rig
}

// MARK: Evidence-backed completion is verified (DEC-010)

do {
    let rig = completedFeature()
    check("a feature completed on delivery evidence is verified", IssueCompletion.isVerified(rig.state()))
    check("the basis is the delivery evidence", basis(rig.state())?.contains("delivery: PR #7 merged") == true)
    check("delivery evidence collected later changes nothing", IssueCompletion.isVerified(rig.state(notDone)) && IssueCompletion.isVerified(rig.state(cannotTell)))
    rig.move("verified", boris)
    check("a person's acceptance keeps the verified completion", IssueCompletion.isVerified(rig.state()))
    check("and its basis", basis(rig.state())?.contains("delivery: PR #7 merged") == true)
}

do {
    let rig = completedFeature()
    let result = rig.move("verified", claude, evidence: LifecycleEvidence(acceptance: AcceptanceEvidence(text: "Ran the flow end to end", criteriaAllTicked: true)))
    check("an AI accepts with evidence", result.isApplied)
    check("AI acceptance on evidence-backed delivery is verified", IssueCompletion.isVerified(rig.state()))
    check("the acceptance text joins the basis", basis(rig.state())?.contains("acceptance: Ran the flow end to end") == true)
}

do {
    let rig = fixedBug()
    check("a bug fixed on delivery evidence is verified", IssueCompletion.isVerified(rig.state()))
    rig.move("closed", boris)
    check("a bug closed after a fix is verified", IssueCompletion.isVerified(rig.state()) && rig.status == "closed")
}

// MARK: Not complete

do {
    let rig = Rig("ready")
    check("a specification stage is not complete", rig.state() == .notComplete)
    rig.move("implementing", app, evidence: start)
    check("work under way is not complete", rig.state() == .notComplete)
    check("delivery evidence does not complete work that is not completed", rig.state(done) == .notComplete)
    let bug = Rig("open", kind: .bug)
    check("an open bug is not complete", bug.state() == .notComplete)
    bug.move("fixing", app, evidence: start)
    check("a bug being fixed is not complete", bug.state() == .notComplete)
}

// MARK: A person's override is not verified completion (REQ-006 criterion 3)

do {
    let rig = overriddenFeature()
    check("a forced completion is overridden", rig.state() == .overridden)
    check("an override is not verified", !IssueCompletion.isVerified(rig.state()))
    rig.move("verified", boris)
    check("a person's acceptance on top of an override stays overridden", rig.state() == .overridden)
    check("incomplete evidence now does not confirm it", rig.state(notDone) == .overridden)
    check("unavailable evidence now does not confirm it", rig.state(cannotTell) == .overridden)
    check("complete evidence now confirms it (DEC-015)", IssueCompletion.isVerified(rig.state(done)))
    check("the confirming basis is the delivery evidence", basis(rig.state(done)) == ["delivery: PR #7 merged", "delivery: checks passed"])
}

do {
    let rig = Rig("ready")
    let result = rig.move("verified", boris, reason: "Accepted without the steps", force: true)
    check("a forced jump outside the table is applied", result.isApplied)
    check("a forced jump to a completed status is overridden", rig.state() == .overridden)
}

do {
    let rig = Rig("implementing", kind: .bug)
    check("an unknown bug transition is not applied by the rules", !rig.move("closed", claude, reason: "x").isApplied)
}

do {
    let rig = Rig("open", kind: .bug)
    rig.move("fixed", boris, reason: "Fixed in a branch nobody merged", force: true)
    check("a bug marked fixed by force is overridden", rig.state() == .overridden)
    rig.move("closed", boris)
    check("closing it keeps the override", rig.state() == .overridden)
}

// MARK: Edits outside MarkView (DEC-015)

do {
    let rig = Rig("ready")
    rig.service.recordBaseline(.feature, "f", status: "ready")
    rig.edit("implemented")
    check("an edit that is not recorded yet is stale, not a pass", unknownReason(rig.state())?.contains("not the one the history ends with") == true)
    check("complete evidence does not rescue a stale status", unknownReason(rig.state(done)) != nil)
}

do {
    let rig = editedFeature()
    check("a recorded outside edit to a completed status is unverified", rig.state() == .unverifiedEdit)
    check("it is not verified completion", !IssueCompletion.isVerified(rig.state()))
    check("incomplete evidence does not confirm it", rig.state(notDone) == .unverifiedEdit)
    check("unavailable evidence does not confirm it", rig.state(cannotTell) == .unverifiedEdit)
    check("complete evidence confirms it now", IssueCompletion.isVerified(rig.state(done)))
    rig.service.recordConfirmation(.feature, "f", status: "implemented", evidence: ["delivery: PR #7 merged"])
    check("a confirmation record makes it verified for good", basis(rig.state()) == ["delivery: PR #7 merged"])
    check("and it stays verified when the evidence cannot be read", IssueCompletion.isVerified(rig.state(cannotTell)))
}

do {
    let rig = completedFeature()
    rig.edit("verified")
    rig.service.recordExternalEdit(.feature, "f", from: "implemented", to: "verified")
    check("an outside edit after a verified completion makes it unverified", rig.state() == .unverifiedEdit)
    rig.service.recordConfirmation(.feature, "f", status: "verified", evidence: ["delivery: PR #7 merged"])
    check("a later confirmation restores it", IssueCompletion.isVerified(rig.state()))
    rig.edit("archived")
    rig.service.recordExternalEdit(.feature, "f", from: "verified", to: "archived")
    check("an outside edit to archived is unverified", rig.state() == .unverifiedEdit)
}

do {
    let rig = completedFeature()
    rig.edit("ready")
    rig.service.recordExternalEdit(.feature, "f", from: "implemented", to: "ready")
    check("an outside edit back to unfinished work is not complete", rig.state() == .notComplete)
}

do {
    let rig = editedFeature()
    rig.move("verified", boris)
    check("a person's acceptance on an unconfirmed edit stays unverified", rig.state() == .unverifiedEdit)
}

do {
    let rig = Rig("implemented")
    rig.service.recordBaseline(.feature, "f", status: "implemented")
    check("a completed status found at first sight has no evidence", rig.state() == .unverifiedEdit)
    check("complete evidence confirms it", IssueCompletion.isVerified(rig.state(done)))
    let early = Rig("implementing")
    early.service.recordBaseline(.feature, "f", status: "implementing")
    check("an unfinished status at first sight is not complete", early.state() == .notComplete)
    let shelved = Rig("archived")
    shelved.service.recordBaseline(.feature, "f", status: "archived")
    check("an archived feature found at first sight is unknown", unknownReason(shelved.state()) != nil)
}

// MARK: Unknown (REQ-005 criterion 1)

do {
    check("a completed status with no history is unknown", unknownReason(Rig("implemented").state()) != nil)
    check("evidence does not rescue a status with no history", unknownReason(Rig("implemented").state(done)) != nil)
    let refused = Rig("implemented")
    let refusal = refused.move("verified", claude)
    check("an AI acceptance without evidence is refused", !refusal.isApplied && refused.history.rejections.count == 1)
    check("refusals alone are no history", refused.history.changes.isEmpty && unknownReason(refused.state()) != nil)
    let history = IssueHistory(kind: .feature, issue: "f", all: [])
    check("a status outside the vocabulary is unknown", unknownReason(IssueCompletion.state(kind: .feature, status: "done", history: history, deliveryNow: done)) != nil)
    check("a bug status is not a feature status", unknownReason(IssueCompletion.state(kind: .feature, status: "fixed", history: history, deliveryNow: nil)) != nil)
    check("no status at all is unknown", unknownReason(IssueCompletion.state(kind: .bug, status: "", history: history, deliveryNow: nil)) != nil)
    check("a status is read without case or spaces", Rig("ready").state() == .notComplete
          && IssueCompletion.state(kind: .feature, status: " Implementing ", history: history, deliveryNow: nil) == .notComplete)
}

do {
    let rig = completedFeature()
    rig.edit("verified")
    check("a status the history does not end with is unknown", unknownReason(rig.state()) != nil)
    rig.edit("implemented")
    check("and known again when the file matches the history", IssueCompletion.isVerified(rig.state()))
}

do {
    let rig = Rig("implementing")
    rig.storage.failing = [.applied]
    let result = rig.move("implemented", app, evidence: delivered)
    guard case .unrecorded = result else { fatalError("expected unrecorded, got \(result)") }
    check("a status written without its record is unknown", unknownReason(rig.state())?.contains("interrupted") == true)
    check("the reconciler asks to recover first", rig.actions(done) == [.recoverPending])
    check("and shows the pending operation", kinds(rig.discrepancies()) == [.pendingOperation])
    rig.storage.failing = []
    rig.run(rig.actions(done))
    check("after recovery the completion counts as it was decided", IssueCompletion.isVerified(rig.state()))
    check("and nothing is left to do", rig.actions(done).isEmpty && rig.discrepancies(done).isEmpty)
}

// MARK: Reopening ends the chain (DEC-009, REQ-006 criterion 2)

do {
    let rig = completedFeature()
    let before = Date(timeIntervalSince1970: baseTime)
    rig.move("implementing", boris, reason: "The export broke again")
    check("a reopened feature is not complete", rig.state() == .notComplete)
    check("the reopen is on record after an earlier time", IssueCompletion.reopened(after: before, in: rig.history))
    let reopenedAt = rig.history.lastChange?.at ?? before
    check("not after its own time", !IssueCompletion.reopened(after: reopenedAt, in: rig.history))
    rig.move("implemented", app, evidence: delivered)
    check("completing again on evidence verifies it again", IssueCompletion.isVerified(rig.state()))
    check("the earlier reopen still counts as a reopen", IssueCompletion.reopened(after: before, in: rig.history))
}

do {
    let rig = completedFeature()
    rig.move("implementing", boris, reason: "Regression")
    rig.move("implemented", boris, reason: "Finished by hand", force: true, evidence: LifecycleEvidence(delivery: notDone))
    check("a reopened issue completed again by override is not verified", rig.state() == .overridden)
}

do {
    let rig = completedFeature()
    rig.move("verified", boris)
    rig.move("implemented", boris, reason: "Accepted too early")
    check("withdrawing an acceptance leaves the delivery as it was", IssueCompletion.isVerified(rig.state()) && rig.status == "implemented")
}

do {
    let rig = fixedBug()
    rig.move("open", claude, evidence: LifecycleEvidence(regression: .bug(id: "BUG-050")))
    check("a bug reopened by an AI on a regression bug is not complete", rig.state() == .notComplete)
    check("the reopen is recorded", IssueCompletion.reopened(after: Date(timeIntervalSince1970: baseTime), in: rig.history))
}

do {
    let rig = completedFeature()
    check("a refused reopen is not a reopen", !rig.move("implementing", claude, evidence: .none).isApplied
          && !IssueCompletion.reopened(after: Date(timeIntervalSince1970: baseTime), in: rig.history))
    let other = Rig("ready")
    check("an issue with no reopen reports none", !IssueCompletion.reopened(after: .distantPast, in: other.history))
}

do {
    let rig = completedFeature()
    rig.move("implementing", boris, reason: "Regression")
    rig.move("ready", boris, reason: "Back to the plan")
    check("a rollback is not complete", rig.state() == .notComplete)
}

// MARK: Archived features (DEC-013)

do {
    let rig = completedFeature()
    rig.move("archived", boris)
    check("archived after a verified completion keeps it", IssueCompletion.isVerified(rig.state()) && rig.status == "archived")
}

do {
    let rig = completedFeature()
    rig.move("verified", boris)
    rig.move("archived", boris)
    check("archived after acceptance keeps the completion", IssueCompletion.isVerified(rig.state()))
}

do {
    let rig = Rig("ready")
    rig.move("archived", boris)
    check("archived before implementation is a cancellation", cancelled(rig.state()) == "archived before completion")
    check("a cancellation is not verified", !IssueCompletion.isVerified(rig.state()))
    check("evidence now does not make a cancellation a completion", cancelled(rig.state(done)) != nil)
    rig.move("ready", boris, reason: "Not dropped after all")
    check("restoring an archived feature makes it unfinished again", rig.state() == .notComplete)
}

do {
    let rig = Rig("ready")
    rig.move("implementing", app, evidence: start)
    rig.move("archived", claude)
    check("archived while under way is a cancellation", cancelled(rig.state()) != nil)
}

do {
    let rig = completedFeature()
    rig.move("implementing", boris, reason: "Regression")
    rig.move("archived", boris)
    check("archived after a reopen is a cancellation, not the old completion", cancelled(rig.state()) != nil)
}

do {
    let rig = overriddenFeature()
    rig.move("archived", boris)
    check("archived after an override is still not verified", rig.state() == .overridden)
}

// MARK: Bugs: completion against cancellation (DEC-013, REQ-006 criterion 4)

do {
    let rig = Rig("open", kind: .bug)
    let result = rig.move("closed", claude, evidence: LifecycleEvidence(cancellation: .duplicate(of: "BUG-002")))
    check("an AI closes a duplicate with evidence", result.isApplied)
    check("a duplicate is a cancellation", cancelled(rig.state()) == "closed without a fix: duplicate of BUG-002")
    check("a cancellation is not verified", !IssueCompletion.isVerified(rig.state()))
    check("delivery evidence does not turn a duplicate into a fix", cancelled(rig.state(done)) != nil)
}

do {
    let rig = Rig("open", kind: .bug)
    rig.move("closed", boris, reason: "Cannot reproduce, withdrawn")
    check("a person's close without a fix is a cancellation with their reason", cancelled(rig.state())?.contains("Cannot reproduce") == true)
}

do {
    let rig = Rig("fixing", kind: .bug)
    rig.move("closed", claude, evidence: LifecycleEvidence(cancellation: .invalid("expected behaviour")))
    check("an invalid report is a cancellation", cancelled(rig.state())?.contains("invalid: expected behaviour") == true)
    rig.move("open", boris, reason: "It is a bug after all")
    check("reopening a cancelled bug makes it unfinished", rig.state() == .notComplete)
}

do {
    let rig = Rig("open", kind: .bug)
    rig.move("closed", claude, evidence: LifecycleEvidence(cancellation: .alreadyFixed("fixed on main by PR #7")))
    check("a bug already fixed on main is a cancellation: a model's finding is not delivery evidence", cancelled(rig.state())?.contains("already fixed: fixed on main by PR #7") == true)
    check("so it is not verified completion", !IssueCompletion.isVerified(rig.state()))
}

// MARK: Reconciler actions (REQ-005, DEC-015)

do {
    let rig = Rig("implemented")
    check("an issue never seen gets a baseline", rig.actions() == [.baseline(status: "implemented")])
    check("evidence does not skip the baseline", rig.actions(done) == [.baseline(status: "implemented")])
    let spaced = Rig(" Implemented ")
    check("the baseline status is normalised", spaced.actions() == [.baseline(status: "implemented")])
    rig.run(rig.actions())
    check("after the baseline the issue is unverified, not unknown", rig.state() == .unverifiedEdit)
    check("a second pass with evidence confirms it", rig.actions(done) == [.confirm(status: "implemented", evidence: ["delivery: PR #7 merged", "delivery: checks passed"])])
    rig.run(rig.actions(done))
    check("the confirmation makes it verified", IssueCompletion.isVerified(rig.state()))
    check("and the next pass has nothing to do", rig.actions(done).isEmpty)
}

do {
    let rig = completedFeature()
    check("a healthy verified issue needs nothing", rig.actions().isEmpty && rig.actions(done).isEmpty && rig.actions(notDone).isEmpty)
    let ready = Rig("ready")
    ready.service.recordBaseline(.feature, "f", status: "ready")
    check("an unfinished issue needs nothing", ready.actions(done).isEmpty)
}

do {
    let rig = completedFeature()
    rig.edit("verified")
    check("an unrecorded edit is recorded first", rig.actions() == [.externalEdit(from: "implemented", to: "verified")])
    check("incomplete evidence does not confirm an edit", rig.actions(notDone) == [.externalEdit(from: "implemented", to: "verified")])
    check("unavailable evidence does not confirm an edit", rig.actions(cannotTell) == [.externalEdit(from: "implemented", to: "verified")])
    check("complete evidence confirms the edit after recording it",
          rig.actions(done) == [.externalEdit(from: "implemented", to: "verified"),
                                .confirm(status: "verified", evidence: ["delivery: PR #7 merged", "delivery: checks passed"])])
}

do {
    let rig = Rig("ready")
    rig.service.recordBaseline(.feature, "f", status: "ready")
    rig.edit("implementing")
    check("an edit to unfinished work is only recorded", rig.actions(done) == [.externalEdit(from: "ready", to: "implementing")])
    rig.run(rig.actions(done))
    check("recording it twice does nothing", rig.actions(done).isEmpty)
}

do {
    let rig = editedFeature()
    check("a recorded unresolved edit waits for evidence", rig.actions().isEmpty && rig.actions(notDone).isEmpty)
    check("and is confirmed by complete evidence", rig.actions(done) == [.confirm(status: "implemented", evidence: ["delivery: PR #7 merged", "delivery: checks passed"])])
}

do {
    let rig = overriddenFeature()
    check("an override is confirmed by complete evidence", rig.actions(done) == [.confirm(status: "implemented", evidence: ["delivery: PR #7 merged", "delivery: checks passed"])])
    check("not by incomplete or unavailable evidence", rig.actions(notDone).isEmpty && rig.actions(cannotTell).isEmpty && rig.actions().isEmpty)
    rig.run(rig.actions(done))
    check("after confirmation the override is verified", IssueCompletion.isVerified(rig.state()))
}

do {
    let rig = Rig("open", kind: .bug)
    rig.move("closed", claude, evidence: LifecycleEvidence(cancellation: .duplicate(of: "BUG-002")))
    check("a cancelled bug is never confirmed", rig.actions(done).isEmpty)
    let archived = Rig("ready")
    archived.move("archived", boris)
    check("a cancelled feature is never confirmed", archived.actions(done).isEmpty)
}

do {
    let rig = Rig("implementing")
    rig.service.recordBaseline(.feature, "f", status: "implementing")
    check("a pending operation is the only action", {
        try! rig.storage.append(TransitionRecord(phase: .begin, command: "x", kind: .feature, issue: "f", from: "implementing", to: "implemented", actor: app))
        rig.edit("verified")
        return rig.actions(done) == [.recoverPending]
    }())
}

// MARK: Confirmed regression reopens (DEC-009, Q-008)

do {
    let rig = completedFeature()
    check("a regression bug reopens a verified feature", rig.actions(done, regression: "BUG-100") == [.reopen(bug: "BUG-100", from: "implemented")])
    check("without a regression bug nothing reopens", rig.actions(notDone).isEmpty)
    rig.run(rig.actions(done, regression: "BUG-100"))
    check("the reopened feature is unfinished", rig.state() == .notComplete && rig.status == "implementing")
    check("the reopen carries the regression evidence", rig.history.lastChange?.evidence == ["regression: BUG-100"])
    check("nothing more to reopen", rig.actions(done, regression: "BUG-100").isEmpty)
    rig.move("implemented", app, evidence: delivered)
    check("a regression bug that already reopened it does not reopen it again", rig.actions(done, regression: "BUG-100").isEmpty)
    check("another regression bug does", rig.actions(done, regression: "BUG-101") == [.reopen(bug: "BUG-101", from: "implemented")])
}

do {
    let rig = fixedBug()
    check("a regression bug reopens a fixed bug", rig.actions(regression: "BUG-200") == [.reopen(bug: "BUG-200", from: "fixed")])
    rig.run(rig.actions(regression: "BUG-200"))
    check("to open", rig.status == "open" && rig.state() == .notComplete)
}

do {
    let rig = Rig("implementing")
    rig.service.recordBaseline(.feature, "f", status: "implementing")
    check("work under way is not reopened", rig.actions(regression: "BUG-100").isEmpty)
    let dup = Rig("open", kind: .bug)
    dup.move("closed", claude, evidence: LifecycleEvidence(cancellation: .duplicate(of: "BUG-002")))
    check("a duplicate was never completed, so it is not reopened", dup.actions(regression: "BUG-100").isEmpty)
}

do {
    let rig = overriddenFeature()
    check("an override with a regression bug is reopened, not confirmed", rig.actions(done, regression: "BUG-100") == [.reopen(bug: "BUG-100", from: "implemented")])
    let edited = completedFeature()
    edited.edit("verified")
    check("an unrecorded edit is recorded before the reopen",
          edited.actions(regression: "BUG-100") == [.externalEdit(from: "implemented", to: "verified"), .reopen(bug: "BUG-100", from: "verified")])
}

// MARK: Discrepancies (REQ-004 criterion 3, REQ-005, Q-008)

do {
    let rig = completedFeature()
    check("a verified issue with its evidence shows nothing", rig.discrepancies(done).isEmpty && rig.discrepancies().isEmpty)
    check("an issue with no history shows nothing yet", Rig("implemented").discrepancies(done).isEmpty)
}

do {
    let rig = completedFeature()
    let incomplete = rig.discrepancies(notDone)
    check("a failing check on a verified issue is a regression candidate", kinds(incomplete) == [.regressionCandidate])
    check("it names the missing evidence", incomplete.first?.message.contains("required check Build failed") == true)
    check("and says nothing was reopened", incomplete.first?.message.contains("does not reopen") == true)
    check("it reopens nothing", rig.actions(notDone).isEmpty && rig.state(notDone) != .notComplete)
    let unavailable = rig.discrepancies(cannotTell)
    check("unavailable evidence is told apart from a failure", kinds(unavailable) == [.regressionCandidate]
          && unavailable.first?.message.contains("cannot be checked now") == true)
    check("complete evidence shows nothing", rig.discrepancies(done).isEmpty)
}

do {
    let rig = completedFeature()
    rig.edit("verified")
    let found = rig.discrepancies()
    check("an unrecorded edit is a discrepancy", kinds(found) == [.unverifiedEdit])
    check("it names both statuses", found.first?.message.contains("implemented to verified") == true)
    check("complete evidence confirms it, so nothing is listed", rig.discrepancies(done).isEmpty)
    rig.run(rig.actions())
    check("the recorded edit stays listed until resolved", kinds(rig.discrepancies(notDone)) == [.unverifiedEdit])
    rig.run(rig.actions(done))
    check("a confirmation resolves it", rig.discrepancies(done).isEmpty && rig.discrepancies().isEmpty)
}

do {
    let rig = overriddenFeature()
    let found = rig.discrepancies(notDone)
    check("an override is completed without evidence", kinds(found) == [.completedWithoutEvidence])
    check("it says why", found.first?.message.contains("override") == true && found.first?.message.contains("required check Build failed") == true)
    check("with no evidence collected it says so", rig.discrepancies().first?.message.contains("not collected") == true)
    check("complete evidence resolves it", rig.discrepancies(done).isEmpty)
}

do {
    let rig = Rig("implemented")
    rig.service.recordBaseline(.feature, "f", status: "implemented")
    check("a completed issue found at first sight is completed without evidence", kinds(rig.discrepancies()) == [.completedWithoutEvidence])
    check("complete evidence resolves it", rig.discrepancies(done).isEmpty)
}

do {
    let rig = Rig("done")
    rig.service.recordBaseline(.feature, "f", status: "done")
    check("a status outside the vocabulary is listed", kinds(rig.discrepancies()) == [.unverifiedEdit] && rig.discrepancies().first?.message.contains("\"done\"") == true)
    let cancelledBug = Rig("open", kind: .bug)
    cancelledBug.move("closed", claude, evidence: LifecycleEvidence(cancellation: .duplicate(of: "BUG-002")))
    check("a cancellation is not a discrepancy", cancelledBug.discrepancies(notDone).isEmpty)
    let working = Rig("ready")
    working.service.recordBaseline(.feature, "f", status: "ready")
    check("unfinished work with failing evidence is not a regression", working.discrepancies(notDone).isEmpty)
}

// MARK: A full pass leaves a settled issue

do {
    let rig = Rig("implemented")
    for _ in 0..<3 { rig.run(rig.actions(done)) }
    check("repeated passes settle: baseline, then confirmation", IssueCompletion.isVerified(rig.state()) && rig.history.changes.count == 1)
    check("one confirmation only", rig.history.records.filter { $0.phase == .confirmed }.count == 1)
    check("nothing left", rig.actions(done).isEmpty && rig.discrepancies(done).isEmpty)
}

// MARK: What completes by itself

check("a feature being implemented completes to implemented", IssueReconciler.completionTarget(kind: .feature, status: "implementing") == "implemented")
check("a bug being fixed completes to fixed", IssueReconciler.completionTarget(kind: .bug, status: "fixing") == "fixed")
check("the status is normalised", IssueReconciler.completionTarget(kind: .bug, status: " Fixing ") == "fixed")
for status in ["idea", "exploring", "draft", "review", "resolving", "ready", "implemented", "verified", "archived", "done", "in-progress", ""] {
    check("a feature in \(status.isEmpty ? "(none)" : status) completes by itself to nothing", IssueReconciler.completionTarget(kind: .feature, status: status) == nil)
}
for status in ["open", "fixed", "closed", "done", ""] {
    check("a bug in \(status.isEmpty ? "(none)" : status) completes by itself to nothing", IssueReconciler.completionTarget(kind: .bug, status: status) == nil)
}
check("a feature status is not read as a bug status", IssueReconciler.completionTarget(kind: .bug, status: "implementing") == nil
      && IssueReconciler.completionTarget(kind: .feature, status: "fixing") == nil)

// MARK: A workflow with other status names, and a replaced status (feature-3)

do {
    func renamed(_ definition: IssueLifecycleDefinition, _ names: [String: String]) -> IssueLifecycleDefinition {
        IssueLifecycleDefinition(
            statuses: definition.statuses.map { WorkflowStatus(id: names[$0.id] ?? $0.id, role: $0.role) },
            rules: definition.rules.map { LifecycleRule(from: Set($0.from.map { names[$0] ?? $0 }), to: names[$0.to] ?? $0.to, kind: $0.kind, needs: $0.needs) })
    }
    var custom = ProjectWorkflow.standard
    custom.bug = renamed(custom.bug, ["open": "todo", "fixing": "doing", "fixed": "done", "closed": "accepted"])
    func request(_ from: String, _ to: String, _ actor: LifecycleActor, evidence: LifecycleEvidence = .none, reason: String? = nil) -> TransitionRequest {
        TransitionRequest(kind: .bug, issue: "BUG-001", from: from, to: to, actor: actor, reason: reason, evidence: evidence, workflow: custom)
    }
    let rig = Rig("todo", kind: .bug)
    check("work starts under the renamed statuses", rig.service.apply(request("todo", "doing", claude, evidence: start)).isApplied)
    check("and completes on evidence", rig.service.apply(request("doing", "done", app, evidence: delivered)).isApplied)
    let state = IssueCompletion.state(kind: .bug, status: "done", history: rig.history, deliveryNow: nil, workflow: custom)
    check("a completion under renamed statuses is verified", IssueCompletion.isVerified(state))
    check("a renamed completed status is a completed-or-archived one by role", IssueCompletion.isCompletedOrArchived(.bug, "accepted", in: custom)
          && !IssueCompletion.isCompletedOrArchived(.bug, "doing", in: custom))
    check("the old names are not statuses of that workflow", unknownReason(IssueCompletion.state(kind: .bug, status: "fixed", history: rig.history, deliveryNow: nil, workflow: custom)) != nil)
    check("the reconciler finds the completion target of the renamed active status", IssueReconciler.completionTarget(kind: .bug, status: "doing", workflow: custom) == "done"
          && IssueReconciler.completionTarget(kind: .bug, status: "fixing", workflow: custom) == nil)
    let reopened = rig.service.apply(request("done", "todo", boris, reason: "It came back"))
    check("a person reopens a completed status into an unstarted one", reopened.isApplied && rig.history.lastChange?.transitionKind == .reopen)
}

do {
    // The workflow loses "implemented": a person moves the item to "verified" (DEC-021, DEC-029).
    let rig = Rig("implementing")
    rig.move("implemented", app, evidence: delivered)
    check("the item is verified complete before the change", IssueCompletion.isVerified(IssueCompletion.state(kind: .feature, status: "implemented", history: rig.history, deliveryNow: nil)))
    let moved = rig.service.applyReplacement(.feature, "f", from: "implemented", to: "verified", actor: boris, reason: "implemented was removed", workflowRevision: 2, variant: nil)
    check("a replacement into another completed status moves the item", moved.isApplied && rig.status == "verified")
    check("it keeps its verified completion", IssueCompletion.isVerified(IssueCompletion.state(kind: .feature, status: "verified", history: rig.history, deliveryNow: nil)))
}

do {
    // A replacement into a completed status of an item that was not completed has no evidence behind it.
    let rig = Rig("draft")
    let moved = rig.service.applyReplacement(.feature, "f", from: "draft", to: "implemented", actor: boris, reason: "draft was removed", workflowRevision: 2, variant: nil)
    check("a replacement can move an unfinished item", moved.isApplied && rig.status == "implemented")
    check("a replacement is never delivery evidence", !IssueCompletion.isVerified(IssueCompletion.state(kind: .feature, status: "implemented", history: rig.history, deliveryNow: nil)))
    let toDraft = Rig("implemented")
    toDraft.move("implementing", boris, reason: "back")
    let replaced = toDraft.service.applyReplacement(.feature, "f", from: "implementing", to: "ready", actor: boris, reason: "implementing was removed", workflowRevision: 2, variant: nil)
    check("a replacement into an unfinished status leaves no completion", replaced.isApplied && IssueCompletion.state(kind: .feature, status: "ready", history: toDraft.history, deliveryNow: nil) == .notComplete)
}

finish("completion")
