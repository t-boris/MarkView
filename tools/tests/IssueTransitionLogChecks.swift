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

finish("transition log")
