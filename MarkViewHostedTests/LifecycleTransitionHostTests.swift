import Foundation
import MarkViewCore
import XCTest
@testable import MarkView


extension EditorHostTests {
    func testIssueTransitionLog() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

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
            guard case .unrecorded(let operation, _) = result else { XCTFail("expected unrecorded, got \(result)"); return }
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

        // An AI's confirmation of a delivery event (feature assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-001)
        do {
            let rig = Rig("implementing")
            let history = { rig.service.history(.feature, "f") }
            check("a person cannot write through the AI path", rig.service.recordAIDeliveryConfirmation(.feature, "f", text: "ok", event: "installed", actor: boris) == nil)
            check("MarkView cannot write through the AI path", rig.service.recordAIDeliveryConfirmation(.feature, "f", text: "ok", event: "installed", actor: LifecycleActor.system("MarkView")) == nil)
            check("an empty text is no evidence", rig.service.recordAIDeliveryConfirmation(.feature, "f", text: "  ", event: "installed", actor: claude) == nil)
            let written = rig.service.recordAIDeliveryConfirmation(.feature, "f", text: "  Version 5.52.0 installed, codesign valid  ", event: "installed", actor: claude, variant: "standard-feature", workflowRevision: 4)
            check("an AI's confirmation is written with its actor, text and event",
                  written?.actor == claude && written?.reason == "Version 5.52.0 installed, codesign valid" && written?.target == "installed" && written?.humanEvidence == .delivery)
            check("it does not count under a process that wants a person", history().deliveryConfirmation(event: "installed") == nil)
            check("it does not count when the reader asks for a person explicitly", history().deliveryConfirmation(event: "installed", confirmer: .person) == nil)
            check("it counts under a process that lets an AI confirm", history().deliveryConfirmation(event: "installed", confirmer: .personOrAI)?.actor == claude)
            check("the evidence text is what the collector reads", history().deliveryConfirmation(event: "installed", confirmer: .personOrAI)?.reason == "Version 5.52.0 installed, codesign valid")
            _ = rig.service.recordHumanEvidence(.feature, "f", evidence: .delivery, text: "Seen on the other Mac", event: "installed", actor: boris)
            check("a person's later confirmation counts under either process", history().deliveryConfirmation(event: "installed")?.actor == boris
                  && history().deliveryConfirmation(event: "installed", confirmer: .personOrAI)?.actor == boris)
            _ = rig.service.recordAIDeliveryConfirmation(.feature, "f", text: "Checked again", event: "installed", actor: claude)
            check("under a process that wants a person, an AI's later record does not hide the person's earlier one",
                  history().deliveryConfirmation(event: "installed")?.actor == boris)
            check("under a process that lets an AI confirm, the latest record wins", history().deliveryConfirmation(event: "installed", confirmer: .personOrAI)?.reason == "Checked again")
            _ = rig.service.apply(request("implementing", "implemented", boris, reason: "delivered", force: true))
            _ = rig.service.apply(request("implemented", "implementing", boris, reason: "regression found"))
            check("a reopening ends an AI's confirmation too", history().deliveryConfirmation(event: "installed", confirmer: .personOrAI) == nil)
        }

        // The step of an event on a rule (REQ-004 of the feature assistants-confirm-delivery-with-evidence-and-propose-workflow): made by
        // MarkView under the rule's own conditions, once for the event and its cause.
        do {
            var workflow = ProjectWorkflow.standard
            workflow.feature.rules.append(LifecycleRule(from: ["implementing"], to: "review", kind: .spec, needs: [.system: []], event: .workStarted))
            func eventStep(_ rig: Rig, cause: String, workflow: ProjectWorkflow, to: String = "review", from: String = "implementing") -> ApplyResult {
                rig.service.apply(TransitionRequest(command: RuleEventPlanner.command(.workStarted, kind: .feature, issue: "f", cause: cause), kind: .feature,
                                                    issue: "f", from: from, to: to, actor: markview, reason: "After the event", workflow: workflow))
            }
            let rig = Rig("implementing")
            check("MarkView makes the step of an event rule", eventStep(rig, cause: "c1", workflow: workflow).isApplied && rig.status() == "review")
            check("the record is MarkView's, with the event in its reason", rig.service.history(.feature, "f").lastChange?.actor == markview
                  && rig.service.history(.feature, "f").lastChange?.reason == "After the event")
            _ = rig.service.apply(request("review", "implementing", boris, reason: "back to work", force: true))
            check("a person moves the item back", rig.status() == "implementing")
            let again = eventStep(rig, cause: "c1", workflow: workflow)
            check("the same event answers the same command and does not override the person", { if case .duplicate = again { return rig.status() == "implementing" } else { return false } }())
            check("a new event with a new cause makes the step again", eventStep(rig, cause: "c2", workflow: workflow).isApplied && rig.status() == "review")

            var closed = ProjectWorkflow.standard
            closed.feature.rules.append(LifecycleRule(from: ["implementing"], to: "review", kind: .spec, needs: [.human: []], event: .workStarted))
            let refused = Rig("implementing")
            check("a rule without a system entry does not let MarkView make the step", eventStep(refused, cause: "c1", workflow: closed).isApplied == false && refused.status() == "implementing")

            var conditional = ProjectWorkflow.standard
            conditional.feature.rules.append(LifecycleRule(from: ["implementing"], to: "review", kind: .spec, needs: [.system: [.startEvidence]], event: .workStarted))
            let unmet = Rig("implementing")
            check("an event step still needs the conditions the rule asks of MarkView", eventStep(unmet, cause: "c1", workflow: conditional).isApplied == false && unmet.status() == "implementing")

            let elsewhere = Rig("ready")
            check("an item in another status than the step's is not moved", eventStep(elsewhere, cause: "c1", workflow: workflow).isApplied == false && elsewhere.status() == "ready")
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

            let own = lineRecord(10)
            try! first.append(own)
            let fromCache = try! first.load()
            let fromDisk = try! FileTransitionStorage(projectRoot: folder).load()
            check("a warmed cache includes an appended record exactly as it decodes from disk", fromCache == fromDisk && fromCache.last?.issue == "BUG-10")
            try! FileManager.default.removeItem(at: first.url)
            for n in 1...3 { try! first.append(lineRecord(n)) }
            _ = try! first.load()

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

    }
}


extension EditorHostTests {
    func testIssueCompletion() {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }

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
                                                 now: { ticks += 1; return Date(timeIntervalSince1970: 1_800_000_000.0 + Double(ticks)) })
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
                        move(kind == .feature ? "implementing" : "open", .ai("claude-code"), evidence: LifecycleEvidence(regression: .bug(id: bug)))
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
            guard case .unrecorded = result else { XCTFail("expected unrecorded, got \(result)"); return }
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

            // The completion target of an item follows the process it follows (BUG-108).
            var processes = ProjectWorkflow.standard
            var own = ProcessTemplate.quickFeature.variant(kind: .feature, id: "quick-feature", in: processes)
            own.rules = own.rules!.filter { $0.kind != .completion || $0.needs[.system] == nil }
            own.rules!.append(LifecycleRule(from: ["implementing"], to: "implemented", kind: .completion, needs: [.human: [.deliveryEvidence]]))
            processes.variants.append(own)
            check("a process that does not let MarkView complete an item has no completion target of its own",
                  IssueReconciler.completionTarget(kind: .feature, status: "implementing", workflow: processes) == "implemented"
                  && IssueReconciler.completionTarget(kind: .feature, status: "implementing", workflow: processes, variantID: "quick-feature") == nil)
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

    }
}
