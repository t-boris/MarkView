// Checks the Lifecycle section's model (MarkView/Models/IssueLifecycleDisplay.swift) against REQ-004 and REQ-005 of
// docs/features/issue-lifecycle-management: what an applied transition shows, how overrides, blocked requests, discrepancies and
// GitHub outcomes are told apart, and which actions the section offers.
import Foundation

let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }

let person = LifecycleActor.human("Boris")
let agent = LifecycleActor.ai("Claude Code", session: "s1")
let robot = LifecycleActor.system("MarkView")

func record(_ phase: TransitionRecord.Phase, _ from: String, _ to: String, _ actor: LifecycleActor, minute: Int,
            kind: IssueKind = .feature, issue: String = "export-pdf", command: String = "", reason: String? = nil,
            transition: TransitionKind? = nil, override: Bool = false, bypassed: [LifecycleCondition] = [],
            missing: [LifecycleCondition] = [], evidence: [String] = [], message: String? = nil, verified: Bool? = nil,
            target: String? = nil, outcome: GitHubWriteOutcome? = nil, id: UUID = UUID()) -> TransitionRecord {
    TransitionRecord(id: id, phase: phase, command: command.isEmpty ? UUID().uuidString : command, kind: kind, issue: issue, from: from, to: to,
                     actor: actor, at: at(minute), reason: reason, transitionKind: transition, override: override, bypassed: bypassed,
                     missing: missing, evidence: evidence, message: message, verified: verified, target: target, githubOutcome: outcome)
}

func display(_ records: [TransitionRecord], status: String, kind: IssueKind = .feature, issue: String = "export-pdf",
             completion: String = "not complete", notes: [String] = []) -> IssueLifecycleDisplay {
    IssueLifecycleDisplay.make(kind: kind, issue: issue, status: status, history: IssueHistory(kind: kind, issue: issue, all: records),
                               completion: completion, discrepancies: notes)
}

// MARK: Applied transitions (REQ-004 criterion 1)

do {
    let applied = record(.applied, "implementing", "implemented", robot, minute: 30, reason: "All work merged.", transition: .completion,
                         evidence: ["PR #12 merged", "checks passed on 4f3a9c1"])
    let d = display([record(.baseline, "", "implementing", robot, minute: 0), applied], status: "implemented", completion: "verified completion")
    let row = d.history.first
    check("an applied transition names the previous and the resulting status", row?.headline == "implementing → implemented")
    check("an applied transition names the actor", row?.actor == "MarkView")
    check("an applied transition carries its time", row?.time == at(30))
    check("an applied transition shows the reason", row?.notes.contains("Reason: All work merged.") == true)
    check("an applied transition lists each piece of evidence",
          row?.notes.contains("Evidence: PR #12 merged") == true && row?.notes.contains("Evidence: checks passed on 4f3a9c1") == true)
    check("an applied transition names the kind of step", row?.notes.contains("Step: completion") == true)
    check("history reads newest first", d.history.map(\.headline) == ["implementing → implemented", "first seen: implementing"])
    check("the first sight is a baseline row", d.history.last?.notes.first == "First seen by MarkView; the history starts here.")
    check("the completion label is kept", d.completion == "verified completion" && d.status == "implemented")
    check("an AI actor reads with its tool and session",
          display([record(.applied, "ready", "implementing", agent, minute: 1, transition: .start)], status: "implementing").history.first?.actor == "AI Claude Code (s1)")
    check("a person actor reads with the name",
          display([record(.applied, "draft", "review", person, minute: 1, transition: .spec)], status: "review").history.first?.actor == "person Boris")
}

// MARK: Overrides (REQ-004 criterion 2)

do {
    let forced = record(.applied, "implementing", "implemented", person, minute: 40, reason: "Shipped by hand, CI is down.", transition: .completion,
                        override: true, bypassed: [.deliveryEvidence, .reason])
    let d = display([forced], status: "implemented", completion: "completed by an override, not verified")
    let row = d.history.first
    check("an override is marked", row?.tone == .override)
    check("an override shows its reason", row?.notes.contains("Reason: Shipped by hand, CI is down.") == true)
    check("an override names the conditions it bypassed",
          row?.notes.first == "Override by a person, bypassed: delivery evidence; a reason.")
    check("an override without bypassed conditions is still marked",
          display([record(.applied, "draft", "ready", person, minute: 1, reason: "x", override: true)], status: "ready").history.first?.notes.first == "Override by a person.")
    check("a normal step is not marked as an override",
          display([record(.applied, "draft", "review", person, minute: 1, transition: .spec)], status: "review").history.first?.tone == .normal)
}

// MARK: Blocked requests and missing evidence (REQ-004 criterion 3)

do {
    let blocked = record(.rejected, "implementing", "implemented", agent, minute: 50, missing: [.deliveryEvidence],
                         message: "implemented needs delivery evidence: PR #12 is not merged.")
    let d = display([record(.applied, "ready", "implementing", agent, minute: 10, transition: .start), blocked], status: "implementing")
    check("a blocked request is listed apart from the history", d.blocked.count == 1 && d.history.count == 1)
    check("a blocked request says nothing changed", d.blocked.first?.headline == "asked implementing → implemented, nothing changed")
    check("a blocked request explains why", d.blocked.first?.notes.first == "implemented needs delivery evidence: PR #12 is not merged.")
    check("a blocked request names the missing evidence", d.blocked.first?.notes.contains("Missing: delivery evidence") == true)
    check("a blocked request is tagged blocked", d.blocked.first?.tone == .blocked)
    check("blocked requests are capped and newest first",
          display((0..<9).map { record(.rejected, "open", "fixed", agent, minute: $0, kind: .bug, issue: "BUG-1", command: "c\($0)") }, status: "open", kind: .bug, issue: "BUG-1").blocked.map(\.time)
            == [8, 7, 6, 5, 4].map(at))
}

// MARK: Discrepancies and uncertain state (REQ-005)

do {
    let outside = record(.external, "implementing", "implemented", LifecycleActor.system("Markdown edit"), minute: 60, verified: false)
    let d = display([record(.applied, "ready", "implementing", agent, minute: 10, transition: .start), outside], status: "implemented",
                    completion: "status edited outside MarkView, not verified")
    check("an outside edit is a discrepancy until confirmed",
          d.discrepancies.contains { $0.contains("changed outside MarkView") && $0.contains("implementing → implemented") && $0.contains("unverified") })
    check("an outside edit is shown in the history as unverified",
          d.history.first?.tone == .external && d.history.first?.notes.first == "Changed outside MarkView. Unverified until delivery evidence confirms it.")

    let confirmed = record(.confirmed, "implemented", "implemented", robot, minute: 70, evidence: ["PR #12 merged"], message: "Evidence confirms the status.")
    let after = display([outside, confirmed], status: "implemented", completion: "verified completion")
    check("a confirmation closes the discrepancy", after.discrepancies.isEmpty)
    check("a confirmation is shown as evidence-backed", after.history.first?.tone == .success && after.history.first?.notes.contains("Confirmed by evidence.") == true)

    let pending = record(.begin, "implementing", "implemented", robot, minute: 80)
    check("an operation that never closed is a discrepancy",
          display([pending], status: "implementing").discrepancies.contains { $0.contains("began") && $0.contains("not closed") })
    check("caller discrepancies are kept", display([], status: "implemented", notes: ["GitHub #294 is closed, but export-pdf is not verified complete."]).discrepancies
          == ["GitHub #294 is closed, but export-pdf is not verified complete."])
    check("a clean history has no discrepancies", display([record(.applied, "draft", "review", person, minute: 1, transition: .spec)], status: "review").discrepancies.isEmpty)
    check("a begin record alone is not a history row", display([pending], status: "implementing").history.isEmpty)
}

// MARK: GitHub outcomes (REQ-004 criterion 4)

do {
    let rows = display([
        record(.github, "implemented", "implemented", robot, minute: 90, command: "g1", message: "closed and confirmed", target: "#294", outcome: .confirmed),
        record(.github, "implemented", "implemented", robot, minute: 91, command: "g2", message: "GitHub refused", target: "#295", outcome: .failed),
        record(.github, "implemented", "implemented", robot, minute: 92, command: "g3", message: "no answer", target: "#296", outcome: .unconfirmed),
    ], status: "implemented").github
    check("GitHub outcomes are listed newest first", rows.map(\.time) == [92, 91, 90].map(at))
    check("a confirmed write reads as confirmed", rows.last?.headline == "GitHub #294: confirmed" && rows.last?.tone == .success)
    check("a failed write reads as failed", rows[1].headline == "GitHub #295: failed" && rows[1].tone == .failure)
    check("an unconfirmed write is neither success nor failure", rows.first?.headline == "GitHub #296: not confirmed (the outcome is unknown)" && rows.first?.tone == .unconfirmed)
    check("a GitHub row keeps the message", rows[1].notes == ["GitHub refused"])
    check("GitHub records are not part of the status history",
          display([record(.github, "implemented", "implemented", robot, minute: 90, target: "#294", outcome: .confirmed)], status: "implemented").history.isEmpty)
}

// MARK: Actions the section offers

do {
    check("an implemented feature can be accepted", IssueLifecycleDisplay.acceptStatus(kind: .feature, status: "implemented") == "verified")
    check("a fixed bug can be accepted", IssueLifecycleDisplay.acceptStatus(kind: .bug, status: "fixed") == "closed")
    check("nothing else is accepted", ["idea", "exploring", "draft", "review", "resolving", "ready", "implementing", "verified", "archived"]
            .allSatisfy { IssueLifecycleDisplay.acceptStatus(kind: .feature, status: $0) == nil }
          && ["open", "fixing", "closed"].allSatisfy { IssueLifecycleDisplay.acceptStatus(kind: .bug, status: $0) == nil })
    check("a completed feature reopens into implementing",
          IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "implemented") == "implementing" && IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "verified") == "implementing")
    check("a completed bug reopens into open",
          IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "fixed") == "open" && IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "closed") == "open")
    check("unfinished work is not reopened", IssueLifecycleDisplay.reopenStatus(kind: .feature, status: "implementing") == nil && IssueLifecycleDisplay.reopenStatus(kind: .bug, status: "open") == nil)
    check("only completed statuses are checked against the evidence",
          display([], status: "implemented").canCheckEvidence && display([], status: "fixed", kind: .bug, issue: "BUG-1").canCheckEvidence
            && !display([], status: "implementing").canCheckEvidence && !display([], status: "open", kind: .bug, issue: "BUG-1").canCheckEvidence)
    check("the display carries the actions with the status", display([], status: "Implemented").acceptTarget == "verified" && display([], status: "Implemented").status == "implemented")
}

// MARK: Bounds

do {
    let many = (0..<45).map { record(.applied, "draft", "review", person, minute: $0, command: "c\($0)", transition: .spec) }
    let d = display(many, status: "review")
    check("the history shows the latest rows only", d.history.count == IssueLifecycleDisplay.historyLimit && d.history.first?.time == at(44))
    check("row ids are unique", Set(d.history.map(\.id)).count == d.history.count)
}

finish("display")
