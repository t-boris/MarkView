// Checks the lifecycle context an AI session gets (MarkView/Models/IssueLifecycleContext.swift) against REQ-003 and
// DEC-007..DEC-011 of docs/features/issue-lifecycle-management: the guidance, the context of one issue, the handoff block, the
// list, and the session links (Q-005: external sessions count only after an explicit connection).
import Foundation

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
    check("completion is recorded from merge, checks and release", has(guidance, "recorded by MarkView from evidence") && has(guidance, "merged") && has(guidance, "required checks passed") && has(guidance, "release"))
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
    check("it says MarkView completes from evidence itself", has(block, "MarkView completes implemented / fixed itself, while the project is open, once the work is merged, its required checks passed and the release"))
    check("it still allows asking, and refuses early asks", has(block, "you may also ask with markview_set_status") && has(block, "refused with what is missing"))
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
    var now = t0
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

finish("context")
