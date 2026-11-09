// Checks the transition service and its history (MarkView/Models/IssueTransitionLog.swift) against REQ-004 criterion 1,
// REQ-005 criteria 2, 3 and 5, REQ-001 criterion 3 and DEC-014 of docs/features/issue-lifecycle-management.
import Foundation

let boris = LifecycleActor.human("Boris")
let claude = LifecycleActor.ai("claude-code")
let markview = LifecycleActor.system("MarkView")
let hand = StartEvidence.handoff(tool: "Claude Code", at: Date())
let done = DeliveryVerdict.complete(summary: ["PR #7 merged", "checks passed", "release v5.36.0"])

struct Rig {
    let storage = MemoryTransitionStorage()
    let statuses = MemoryStatusStore()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let service: IssueTransitionService
    init(_ status: String = "ready", kind: IssueKind = .feature, issue: String = "f") {
        let storage = self.storage, statuses = self.statuses
        statuses.statuses[MemoryStatusStore.key(kind, issue)] = status
        var ticks = 0
        service = IssueTransitionService(storage: storage, statuses: statuses,
                                         now: { ticks += 1; return Date(timeIntervalSince1970: 1_800_000_000 + Double(ticks)) })
    }
    func status(_ kind: IssueKind = .feature, _ issue: String = "f") -> String? { statuses.status(kind: kind, issue: issue) }
}

func request(_ from: String, _ to: String, _ actor: LifecycleActor, command: String = UUID().uuidString, kind: IssueKind = .feature,
             issue: String = "f", reason: String? = nil, force: Bool = false, evidence: LifecycleEvidence = .none, observedAt: Date? = nil) -> TransitionRequest {
    TransitionRequest(command: command, kind: kind, issue: issue, from: from, to: to, actor: actor, reason: reason, force: force,
                      evidence: evidence, observedAt: observedAt)
}

// MARK: An applied transition is on record (REQ-004 criterion 1)

do {
    let rig = Rig("ready")
    let result = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    check("a decided transition is applied", result.isApplied)
    check("the stored status changed", rig.status() == "implementing")
    let history = rig.service.history(.feature, "f")
    check("begin and applied are on record", history.records.map(\.phase) == [.begin, .applied])
    check("the applied record names previous and resulting status", history.lastChange?.from == "ready" && history.lastChange?.to == "implementing")
    check("it names the actor and the time", history.lastChange?.actor == markview && history.lastChange?.at != nil)
    check("it keeps the supporting evidence", history.lastChange?.evidence.contains("start: handed to Claude Code") == true)
    check("it is a start", history.lastChange?.transitionKind == .start)
    check("first start does not exclude an earlier fix", history.deliveryRoundStart == nil)
    check("it is not an override", history.lastChange?.override == false)
    check("the history ends in the new status", history.expectedStatus == "implementing")
    check("no operation is pending", history.pending.isEmpty)
}

do {
    let reopenedAt = Date(timeIntervalSince1970: 100)
    let records = [TransitionRecord(phase: .applied, kind: .bug, issue: "BUG-012", actor: boris, at: reopenedAt, transitionKind: .reopen),
                   TransitionRecord(phase: .applied, kind: .bug, issue: "BUG-012", actor: markview, at: reopenedAt.addingTimeInterval(10), transitionKind: .start)]
    check("a later start preserves the reopening boundary", IssueHistory(kind: .bug, issue: "BUG-012", all: records).deliveryRoundStart == reopenedAt)
}

// MARK: A rejection changes nothing and is inspectable (REQ-001 criterion 3, REQ-004 criterion 3)

do {
    let rig = Rig("implementing")
    let result = rig.service.apply(request("implementing", "implemented", claude, reason: "done", evidence: LifecycleEvidence(delivery: .incomplete(missing: ["PR #2 not merged"]))))
    if case .rejected(let rejection) = result { check("the AI is refused with the missing condition", rejection.missing == [.deliveryEvidence]) } else { check("the AI is refused", false) }
    check("a refused request leaves the status", rig.status() == "implementing")
    let history = rig.service.history(.feature, "f")
    check("the refusal is on record for the person", history.rejections.count == 1 && history.rejections[0].missing == [.deliveryEvidence])
    check("the refusal wrote no journal entry", history.records.allSatisfy { $0.phase == .rejected })
    check("the explanation mentions what to do", result.explanation.contains("delivery"))
}

// MARK: Overrides are visible with their reason and bypassed conditions (REQ-004 criterion 2)

do {
    let rig = Rig("implementing")
    let result = rig.service.apply(request("implementing", "implemented", boris, reason: "Released by hand", force: true,
                                           evidence: LifecycleEvidence(delivery: .unknown(reasons: ["GitHub unreachable"]))))
    check("a person forces a completion", result.isApplied && rig.status() == "implemented")
    let change = rig.service.history(.feature, "f").lastChange
    check("the override is marked", change?.override == true)
    check("the reason is kept", change?.reason == "Released by hand")
    check("the bypassed conditions are named", change?.bypassed == [.deliveryEvidence])
    let refused = rig.service.apply(request("implemented", "implementing", claude, reason: "x", force: true))
    check("an AI cannot force", { if case .rejected = refused { return true } else { return false } }() && rig.status() == "implemented")
}

// MARK: Stale and repeated requests (REQ-005 criterion 2)

do {
    let rig = Rig("ready")
    _ = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    let late = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    check("a request that saw an older status is stale", late == .stale(current: "implementing"))
    check("a stale request changes nothing", rig.status() == "implementing" && rig.service.history(.feature, "f").changes.count == 1)
    let same = rig.service.apply(request("implementing", "implementing", markview))
    check("asking for the status it has is no change", same == .unchanged)
}

do {
    let rig = Rig("ready")
    let key = "handoff:f:1"
    let first = rig.service.apply(request("ready", "implementing", markview, command: key, evidence: LifecycleEvidence(start: hand)))
    let second = rig.service.apply(request("ready", "implementing", markview, command: key, evidence: LifecycleEvidence(start: hand)))
    check("the first request applies", first.isApplied)
    if case .duplicate(let original) = second { check("a repeated command returns its first outcome", original.to == "implementing") } else { check("a repeated command returns its first outcome", false) }
    check("a repeated command is not applied twice", rig.service.history(.feature, "f").changes.count == 1)
    // Rewound: the repeated command must not move a status that was changed since.
    rig.statuses.statuses["feature:f"] = "ready"
    let third = rig.service.apply(request("ready", "implementing", markview, command: key, evidence: LifecycleEvidence(start: hand)))
    check("a repeated command is answered even after the status moved on", { if case .duplicate = third { return true } else { return false } }())
}

do {
    let rig = Rig("implementing")
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let result = rig.service.apply(request("implementing", "implemented", markview, evidence: LifecycleEvidence(delivery: done), observedAt: old))
    check("an observation older than the last change is not trusted: no history yet, so it applies", result.isApplied)
    _ = rig.service.apply(request("implemented", "implementing", boris, reason: "Regression"))
    let delayed = rig.service.apply(request("implementing", "implemented", markview, evidence: LifecycleEvidence(delivery: done), observedAt: old))
    check("a delayed observation does not overwrite a newer state", delayed == .stale(current: "implementing") && rig.status() == "implementing")
}

// MARK: Concurrent requests (REQ-005 criterion 2)

do {
    let rig = Rig("ready")
    let group = DispatchGroup()
    var results: [ApplyResult] = []
    let resultLock = NSLock()
    for i in 0..<8 {
        group.enter()
        DispatchQueue.global().async {
            let r = rig.service.apply(request("ready", "implementing", markview, command: "c\(i)", evidence: LifecycleEvidence(start: hand)))
            resultLock.lock(); results.append(r); resultLock.unlock()
            group.leave()
        }
    }
    group.wait()
    check("exactly one of eight concurrent requests applies", results.filter(\.isApplied).count == 1)
    check("the others are stale", results.filter { $0 == .stale(current: "implementing") }.count == 7)
    check("one change on record", rig.service.history(.feature, "f").changes.count == 1)
}

do {
    // Another window writes between the check and the write: the compare-and-set refuses.
    let rig = Rig("ready")
    rig.statuses.beforeSet = { rig.statuses.statuses["feature:f"] = "archived" }
    let result = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    check("a write that lost the race is stale", result == .stale(current: "archived"))
    check("and the other writer's status stands", rig.status() == "archived")
    let history = rig.service.history(.feature, "f")
    check("the lost operation is closed as aborted", history.pending.isEmpty && history.records.map(\.phase) == [.begin, .aborted])
}

// MARK: Partial failures are recoverable and not success (REQ-005 criterion 5, plan I-2)

do {
    let rig = Rig("ready")
    rig.storage.failing = [.begin]
    let result = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    if case .failed = result { check("a journal that cannot be written stops the change", true) } else { check("a journal that cannot be written stops the change", false) }
    check("and the status is untouched", rig.status() == "ready")
}

do {
    let rig = Rig("ready")
    rig.statuses.writeFails = true
    let result = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    if case .failed = result { check("a status that cannot be written is a failure", true) } else { check("a status that cannot be written is a failure", false) }
    check("the failed write is closed as aborted", rig.service.history(.feature, "f").pending.isEmpty)
    check("the status is as before", rig.status() == "ready")
}

do {
    let rig = Rig("ready")
    rig.storage.failing = [.applied]
    let result = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    guard case .unrecorded(let operation, _) = result else { fatalError("expected unrecorded, got \(result)") }
    check("a status written without its record is not a confirmed success", !result.isApplied)
    check("the status did change", rig.status() == "implementing")
    check("but the issue has the requested status, so a caller must not undo its work", result.reachedStatus)
    check("the journal still holds the operation", rig.service.history(.feature, "f").pending.map(\.id) == [operation])
    rig.storage.failing = []
    let recovered = rig.service.recoverPending()
    if case .finished(let record)? = recovered.first { check("recovery finishes the operation with the status as written", record.to == "implementing" && record.phase == .recovered) } else { check("recovery finishes the operation", false) }
    check("after recovery nothing is pending and the change counts", rig.service.history(.feature, "f").pending.isEmpty && rig.service.history(.feature, "f").expectedStatus == "implementing")
    check("recovering twice is harmless", rig.service.recoverPending().isEmpty && rig.service.history(.feature, "f").changes.count == 1)
}

do {
    // Which answers leave the issue in the requested status.
    let rig = Rig("ready")
    let first = rig.service.apply(request("ready", "implementing", markview, evidence: LifecycleEvidence(start: hand)))
    check("an applied change reached the status", first.reachedStatus)
    check("an unchanged status is reached", rig.service.apply(request("implementing", "implementing", markview)).reachedStatus)
    check("a stale request did not reach it", !rig.service.apply(request("ready", "implemented", markview, evidence: LifecycleEvidence(delivery: done))).reachedStatus)
    check("a rejected request did not reach it", !rig.service.apply(request("implementing", "verified", markview)).reachedStatus)
    check("a failure did not reach it", !ApplyResult.failed("x").reachedStatus)
}

do {
    // The app quit after the journal write and before the status write.
    let rig = Rig("ready")
    let operation = UUID()
    try! rig.storage.append(TransitionRecord(id: operation, phase: .begin, command: "x", kind: .feature, issue: "f", from: "ready", to: "implementing", actor: markview))
    let recovered = rig.service.recoverPending()
    if case .aborted? = recovered.first { check("an operation interrupted before the write is aborted", rig.status() == "ready") } else { check("an operation interrupted before the write is aborted", false) }
    check("and is no longer pending", rig.service.history(.feature, "f").pending.isEmpty)
}

do {
    // Someone else changed the status while the operation was pending.
    let rig = Rig("archived")
    try! rig.storage.append(TransitionRecord(phase: .begin, command: "x", kind: .feature, issue: "f", from: "ready", to: "implementing", actor: markview))
    if case .conflicting? = rig.service.recoverPending().first { check("a pending operation against a changed status is reported as a conflict", true) } else { check("a pending operation against a changed status is reported as a conflict", false) }
    check("the stored status is left alone", rig.status() == "archived")
}

do {
    // A new request reconciles an old interrupted operation first.
    let rig = Rig("implementing")
    try! rig.storage.append(TransitionRecord(phase: .begin, command: "old", kind: .feature, issue: "f", from: "ready", to: "implementing", actor: markview))
    let result = rig.service.apply(request("implementing", "implemented", markview, evidence: LifecycleEvidence(delivery: done)))
    check("a request first closes an interrupted operation", result.isApplied && rig.service.history(.feature, "f").pending.isEmpty)
}

// MARK: External edits, baseline, confirmation (REQ-005 criterion 3, DEC-015)

do {
    let rig = Rig("ready")
    check("the first look records a baseline", rig.service.recordBaseline(.feature, "f", status: "ready"))
    check("a second look records nothing", !rig.service.recordBaseline(.feature, "f", status: "ready"))
    check("the baseline is the expected status", rig.service.history(.feature, "f").expectedStatus == "ready")
    check("an edit that the file does not show is not recorded (a stale copy is not a fact)",
          rig.service.recordExternalEdit(.feature, "f", from: "ready", to: "implemented") == nil && rig.service.history(.feature, "f").expectedStatus == "ready")
    rig.statuses.statuses[MemoryStatusStore.key(.feature, "f")] = "implemented"
    let edit = rig.service.recordExternalEdit(.feature, "f", from: "ready", to: "implemented")
    check("an edit outside the service is recorded unverified", edit?.phase == .external && edit?.verified == false)
    check("the history now expects the edited status", rig.service.history(.feature, "f").expectedStatus == "implemented")
    check("the edit stays unresolved", rig.service.history(.feature, "f").unresolvedExternal.count == 1)
    check("the same edit is not recorded twice", rig.service.recordExternalEdit(.feature, "f", from: "ready", to: "implemented") == nil)
    let confirmation = rig.service.recordConfirmation(.feature, "f", status: "implemented", evidence: ["PR #7 merged"])
    check("evidence confirms it", confirmation?.verified == true)
    check("a confirmed edit is resolved", rig.service.history(.feature, "f").unresolvedExternal.isEmpty)
    check("a confirmation for another status is refused", rig.service.recordConfirmation(.feature, "f", status: "verified", evidence: []) == nil)
}

do {
    let rig = Rig("implemented")
    check("a baseline of a status the file no longer has is not recorded", !rig.service.recordBaseline(.feature, "f", status: "ready") && rig.service.history(.feature, "f").records.isEmpty)
    check("the baseline of the status the file has is", rig.service.recordBaseline(.feature, "f", status: " Implemented "))
}

do {
    // What came later is told by its place in the journal, whatever the clock did.
    let moment = Date(timeIntervalSince1970: 1_800_000_000)
    func step(_ phase: TransitionRecord.Phase, _ from: String, _ to: String) -> TransitionRecord {
        TransitionRecord(phase: phase, command: UUID().uuidString, kind: .feature, issue: "f", from: from, to: to, actor: markview, at: moment)
    }
    let editedAfter = IssueHistory(kind: .feature, issue: "f", all: [step(.applied, "ready", "implementing"), step(.external, "implementing", "implemented")])
    check("an edit made in the same second as an earlier change is unresolved", editedAfter.unresolvedExternal.count == 1)
    let resolvedAfter = IssueHistory(kind: .feature, issue: "f", all: [step(.external, "implementing", "implemented"), step(.confirmed, "implemented", "implemented")])
    check("a confirmation in the same second as the edit resolves it", resolvedAfter.unresolvedExternal.isEmpty)
}

do {
    let rig = Rig("implementing")
    check("an edit with no baseline is not recorded as an edit", rig.service.recordExternalEdit(.feature, "f", from: "ready", to: "implementing") == nil)
}

// MARK: GitHub outcomes (REQ-004 criterion 4)

do {
    let rig = Rig("implemented")
    rig.service.recordGitHub(.feature, "f", target: "#294", outcome: .confirmed, message: "closed as completed")
    rig.service.recordGitHub(.feature, "f", target: "#294", outcome: .unconfirmed, message: "no answer from GitHub")
    let outcomes = rig.service.history(.feature, "f").githubOutcomes
    check("the three outcomes are told apart", outcomes.map(\.githubOutcome) == [.confirmed, .unconfirmed])
    check("an outcome names its issue", outcomes.allSatisfy { $0.target == "#294" })
    check("a GitHub record does not set the status", rig.service.history(.feature, "f").changes.isEmpty)
}

// MARK: Missing issue, bugs, other issues untouched

do {
    let rig = Rig("open", kind: .bug, issue: "BUG-001")
    check("an unknown issue fails and writes nothing", { if case .failed = rig.service.apply(request("open", "fixing", markview, kind: .bug, issue: "BUG-404", evidence: LifecycleEvidence(start: hand))) { return true } else { return false } }())
    check("a bug moves on its own history", rig.service.apply(request("open", "fixing", markview, kind: .bug, issue: "BUG-001", evidence: LifecycleEvidence(start: hand))).isApplied)
    check("a feature history is separate from a bug history", rig.service.history(.feature, "BUG-001").records.isEmpty)
}

do {
    // The same system refusal at every poll is recorded once.
    let rig = Rig("implementing")
    for _ in 0..<5 { _ = rig.service.apply(request("implementing", "implemented", markview, evidence: LifecycleEvidence(delivery: .incomplete(missing: ["release pending"])))) }
    check("an observer's repeated refusal is recorded once", rig.service.history(.feature, "f").rejections.count == 1)
    for _ in 0..<3 { _ = rig.service.apply(request("implementing", "implemented", boris, evidence: LifecycleEvidence(delivery: .incomplete(missing: ["release pending"])))) }
    check("a person's refusals are all recorded", rig.service.history(.feature, "f").rejections.count == 4)
}

// MARK: Workflow records (feature-3)

do {
    var workflow = ProjectWorkflow.standard
    workflow.revision = 4
    let rig = Rig("ready")
    let started = TransitionRequest(command: "s1", kind: .feature, issue: "f", from: "ready", to: "implementing", actor: markview,
                                    evidence: LifecycleEvidence(start: hand), workflow: workflow, variantID: StandardWorkflow.featureVariantID)
    check("a transition is applied under a workflow", rig.service.apply(started).isApplied)
    let history = rig.service.history(.feature, "f")
    check("its records name the workflow revision and the variant", history.records.allSatisfy { $0.workflowRevision == 4 && $0.variant == StandardWorkflow.featureVariantID })

    let refused = TransitionRequest(command: "s2", kind: .feature, issue: "f", from: "implementing", to: "verified", actor: claude, workflow: workflow)
    _ = rig.service.apply(refused)
    check("a refusal names them too", rig.service.history(.feature, "f").records.last { $0.phase == .rejected }?.workflowRevision == 4)

    check("an item starts without an assigned variant", history.assignedVariant == nil)
    let first = rig.service.recordAssignment(.feature, "f", variant: "by-hand", previous: nil, actor: boris, reason: "Done by hand", workflowRevision: 4)
    check("a variant assignment is a record", first?.phase == .assignment && first?.to == "by-hand" && first?.reason == "Done by hand")
    check("the last assignment is the variant of the item", rig.service.history(.feature, "f").assignedVariant == "by-hand")
    check("the same variant again writes nothing", rig.service.recordAssignment(.feature, "f", variant: "by-hand", previous: "by-hand", actor: boris, workflowRevision: 4) == nil)
    _ = rig.service.recordAssignment(.feature, "f", variant: "standard-feature", previous: "by-hand", actor: boris, workflowRevision: 5)
    check("a later assignment replaces it", rig.service.history(.feature, "f").assignedVariant == "standard-feature")
    check("an assignment is not a change of status", rig.service.history(.feature, "f").expectedStatus == "implementing" && rig.status() == "implementing")
}

do {
    // The adoption of a workflow gives every existing item its variant in one pass over the journal (DEC-024).
    let rig = Rig("ready")
    _ = rig.service.recordAssignment(.bug, "BUG-002", variant: "by-hand-bug", previous: nil, actor: boris, workflowRevision: 1)
    let items: [(kind: IssueKind, issue: String)] = [(.feature, "f"), (.bug, "BUG-001"), (.bug, "BUG-002")]
    let done = rig.service.recordInitialAssignments(items, variantFor: { $0 == .feature ? StandardWorkflow.featureVariantID : StandardWorkflow.bugVariantID },
                                                    actor: .system("MarkView"), reason: "The standard workflow was adopted.", workflowRevision: 1)
    check("the pass reports that every item has a variant", done)
    check("a feature gets the standard feature variant", rig.service.history(.feature, "f").assignedVariant == StandardWorkflow.featureVariantID)
    check("a bug gets the standard bug variant", rig.service.history(.bug, "BUG-001").assignedVariant == StandardWorkflow.bugVariantID)
    check("an item that already has a variant keeps it", rig.service.history(.bug, "BUG-002").assignedVariant == "by-hand-bug")
    check("the records name MarkView and the reason",
          rig.service.history(.bug, "BUG-001").records.last { $0.phase == .assignment }.map { $0.actor.kind == .system && $0.reason == "The standard workflow was adopted." } == true)
    let before = rig.service.records().count
    check("repeating the pass writes nothing", rig.service.recordInitialAssignments(items, variantFor: { _ in "x" }, actor: .system("MarkView"), reason: "again", workflowRevision: 1)
          && rig.service.records().count == before)
}

do {
    let rig = Rig("ready")
    check("no start note is pending at first", rig.service.history(.feature, "f").pendingStartNote == nil)
    check("an AI cannot write a person's note", rig.service.recordHumanEvidence(.feature, "f", evidence: .start, text: "I started", actor: claude) == nil)
    check("an empty note is not evidence", rig.service.recordHumanEvidence(.feature, "f", evidence: .start, text: "   ", actor: boris) == nil)
    let written = rig.service.recordHumanEvidence(.feature, "f", evidence: .start, text: "  Started by hand  ", actor: boris, variant: "by-hand", workflowRevision: 2)
    check("a person's start note is a record", written?.phase == .evidence && written?.humanEvidence == .start && written?.reason == "Started by hand")
    check("it is pending until work starts", rig.service.history(.feature, "f").pendingStartNote?.reason == "Started by hand")
    check("a note is not a change of status", rig.status() == "ready" && rig.service.history(.feature, "f").expectedStatus == nil)
    var workflow = ProjectWorkflow.standard
    workflow.variants.append(VariantTemplate.manualWork.variant(kind: .feature, id: "by-hand"))
    let noteStart = TransitionRequest(command: "n1", kind: .feature, issue: "f", from: "ready", to: "implementing", actor: boris,
                                      evidence: LifecycleEvidence(start: .note(text: "Started by hand", by: "Boris", at: Date())),
                                      workflow: workflow, variantID: "by-hand")
    check("the standard variant does not take a note",
          !rig.service.apply(TransitionRequest(command: "n0", kind: .feature, issue: "f", from: "ready", to: "implementing", actor: boris,
                                               evidence: LifecycleEvidence(start: .note(text: "x", by: "Boris", at: Date())))).isApplied)
    let started = rig.service.apply(noteStart)
    check("the note starts work under a variant that accepts one", started.isApplied)
    check("a used note is no longer pending", rig.service.history(.feature, "f").pendingStartNote == nil)
    check("the start record keeps the note in its evidence", rig.service.history(.feature, "f").lastChange?.evidence.contains { $0.contains("note by Boris") } == true)
}

do {
    let rig = Rig("implementing")
    let history = { rig.service.history(.feature, "f") }
    check("a delivery event is unconfirmed at first", history().deliveryConfirmation(event: "Installed") == nil)
    check("an AI cannot confirm a delivery event", rig.service.recordHumanEvidence(.feature, "f", evidence: .delivery, text: "ok", event: "installed", actor: claude) == nil)
    _ = rig.service.recordHumanEvidence(.feature, "f", evidence: .delivery, text: "On the other Mac", event: "installed", actor: boris)
    check("a person's confirmation is found by the event name, ignoring case and spacing", history().deliveryConfirmation(event: "  INSTALLED ")?.reason == "On the other Mac")
    check("another event is not confirmed", history().deliveryConfirmation(event: "deployed") == nil)
    _ = rig.service.apply(request("implementing", "implemented", boris, reason: "delivered", force: true))
    check("the confirmation survives completion", history().deliveryConfirmation(event: "installed") != nil)
    _ = rig.service.apply(request("implemented", "implementing", boris, reason: "regression found"))
    check("a reopening starts a new round, so the old confirmation no longer counts", history().deliveryConfirmation(event: "installed") == nil)
}

do {
    var workflow = ProjectWorkflow.standard
    workflow.revision = 6
    let rig = Rig("implemented")
    let blocked = rig.service.applyReplacement(.feature, "f", from: "implemented", to: "verified", actor: claude, reason: "workflow changed", workflowRevision: 6, variant: nil)
    check("only a person replaces a status", !blocked.isApplied && rig.status() == "implemented")
    let stale = rig.service.applyReplacement(.feature, "f", from: "draft", to: "verified", actor: boris, reason: "workflow changed", workflowRevision: 6, variant: nil)
    if case .stale = stale { check("a replacement from a status the item no longer has is stale", true) } else { check("a replacement from a status the item no longer has is stale", false) }
    let replaced = rig.service.applyReplacement(.feature, "f", from: "implemented", to: "verified", actor: boris, reason: "The workflow no longer has implemented", workflowRevision: 6, variant: nil)
    check("a replacement moves the item", replaced.isApplied && rig.status() == "verified")
    let record = rig.service.history(.feature, "f").lastChange
    check("it is recorded as a replacement, not an override", record?.transitionKind == .replacement && record?.override == false && record?.workflowRevision == 6)
    check("it keeps the person's reason", record?.reason == "The workflow no longer has implemented")
}

do {
    // Records written before workflows existed have none of the new fields and must still be read.
    let old = #"{"id":"00000000-0000-0000-0000-000000000001","phase":"applied","command":"c","kind":"feature","issue":"f","from":"ready","to":"implementing","actor":{"kind":"human","name":"Boris"},"at":"2026-11-05T10:00:00Z","override":false,"bypassed":[],"evidence":[],"missing":[]}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try? decoder.decode(TransitionRecord.self, from: Data(old.utf8))
    check("a record from before workflows decodes without the new fields", record?.workflowRevision == nil && record?.variant == nil && record?.humanEvidence == nil && record?.to == "implementing")
}

// MARK: File storage

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = FileTransitionStorage(projectRoot: folder)
    check("an absent file reads as empty", (try? storage.load())?.isEmpty == true)
    let record = TransitionRecord(phase: .applied, command: "c", kind: .bug, issue: "BUG-002", from: "open", to: "fixing", actor: claude,
                                  reason: "r", transitionKind: .start, evidence: ["start: handed to Claude Code"])
    try! storage.append(record)
    let handle = try! FileHandle(forWritingTo: storage.url)
    handle.seekToEndOfFile()
    handle.write(Data("{ damaged line\n".utf8))
    try? handle.close()
    try! storage.append(TransitionRecord(phase: .rejected, command: "d", kind: .bug, issue: "BUG-002", from: "fixing", to: "fixed", actor: claude, message: "no"))
    let loaded = (try? storage.load()) ?? []
    check("records round-trip through the file", loaded.first?.issue == "BUG-002" && loaded.first?.actor == claude && loaded.first?.evidence == record.evidence)
    check("a damaged line is skipped", loaded.count == 2)
    check("the file lives under .dde/lifecycle", storage.url.path.hasSuffix(".dde/lifecycle/transitions.jsonl"))
    let service = IssueTransitionService(storage: storage, statuses: { let s = MemoryStatusStore(); s.statuses["bug:BUG-002"] = "fixing"; return s }())
    check("the service reads the history back", service.history(.bug, "BUG-002").changes.count == 1)
}

// MARK: File storage keeps the decoded log until the file changes (BUG-117)

func lineRecord(_ n: Int) -> TransitionRecord {
    TransitionRecord(phase: .applied, command: "c\(n)", kind: .bug, issue: "BUG-\(n)", from: "open", to: "fixing", actor: claude, reason: "r",
                     transitionKind: .start, evidence: ["start: handed to Claude Code"])
}

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = FileTransitionStorage(projectRoot: folder)
    let second = FileTransitionStorage(projectRoot: folder)  // another window, or another process, on the same project
    for n in 1...3 { try! first.append(lineRecord(n)) }
    let loaded = try! first.load()
    check("a repeated load returns the same records", try! first.load() == loaded && loaded.count == 3)

    try! second.append(lineRecord(4))
    check("a record appended through another storage shows at the next load",
          (try! first.load()).map(\.issue) == ["BUG-1", "BUG-2", "BUG-3", "BUG-4"])

    // The file rewritten in place with the same size and other content: the modification time tells.
    let text = try! String(contentsOf: first.url, encoding: .utf8)
    Thread.sleep(forTimeInterval: 0.02)
    try! text.replacingOccurrences(of: "BUG-1\"", with: "BUG-9\"").write(to: first.url, atomically: false, encoding: .utf8)
    check("a rewrite with the same size and other content shows", (try! first.load()).map(\.issue) == ["BUG-9", "BUG-2", "BUG-3", "BUG-4"])

    Thread.sleep(forTimeInterval: 0.02)
    try! (text.split(separator: "\n").prefix(2).joined(separator: "\n") + "\n").write(to: first.url, atomically: false, encoding: .utf8)
    check("a shorter file shows", (try! first.load()).map(\.issue) == ["BUG-1", "BUG-2"])

    // Replaced by another file (the way an editor or a git checkout writes): a new identity.
    let replacement = folder.appendingPathComponent("replacement.jsonl")
    try! (text.split(separator: "\n").suffix(1).joined(separator: "\n") + "\n").write(to: replacement, atomically: false, encoding: .utf8)
    _ = try! FileManager.default.replaceItemAt(first.url, withItemAt: replacement)
    check("a file replaced by another shows", (try! first.load()).map(\.issue) == ["BUG-4"])

    try! FileManager.default.removeItem(at: first.url)
    check("a deleted file reads as empty", (try! first.load()).isEmpty)
    try! first.append(lineRecord(7))
    check("a new file after it is read", (try! first.load()).map(\.issue) == ["BUG-7"])
}

do {
    // What scheduleProgressCheck did: the history of every work item in turn. 148 items and 700 records took 9.1 s without the cache.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = FileTransitionStorage(projectRoot: folder)
    for n in 1...700 { try! storage.append(lineRecord(n)) }
    check("a 700-record log has 700 records", try! storage.load().count == 700)
    let service = IssueTransitionService(storage: storage, statuses: MemoryStatusStore())
    let started = Date()
    for n in 1...148 { _ = service.history(.bug, "BUG-\(n)") }
    let elapsed = Date().timeIntervalSince(started)
    check("the history of 148 work items in a row takes well under 1.5 s (\(Int(elapsed * 1000)) ms)", elapsed < 1.5)
}

finish("transition log")
