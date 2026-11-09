// Checks how a workflow proposed by an assistant is read and judged (MarkView/Models/WorkflowProposal.swift; feature
// assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-003, DEC-001).
import Foundation

let current: ProjectWorkflow = { var w = ProjectWorkflow.standard; w.revision = 4; return w }()
let encoder = JSONEncoder()
func object(_ workflow: ProjectWorkflow) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: try! encoder.encode(workflow)) as! [String: Any]
}
func text(_ workflow: ProjectWorkflow) -> String { String(decoding: try! encoder.encode(workflow), as: UTF8.self) }
func refusal(_ result: Result<WorkflowProposal, WorkflowProposalChecker.Refusal>) -> [String] {
    if case .failure(let refusal) = result { return refusal.problems } else { return [] }
}
func proposal(_ result: Result<WorkflowProposal, WorkflowProposalChecker.Refusal>) -> WorkflowProposal? {
    if case .success(let proposal) = result { return proposal } else { return nil }
}
func evaluate(_ value: Any?, summary: String = "Let an AI move a bug back", at: ProjectWorkflow = current) -> Result<WorkflowProposal, WorkflowProposalChecker.Refusal> {
    WorkflowProposalChecker.evaluate(workflow: value, summary: summary, current: at, by: "Claude Code", now: Date(timeIntervalSince1970: 1_800_000_000))
}

var changed = current
changed.bug.rules.append(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .ai: [], .system: []], event: .investigationFinished))

// MARK: A sound proposal

let accepted = proposal(evaluate(object(changed)))
check("a sound proposal as a JSON object is accepted", accepted != nil)
check("it is the workflow that was sent", accepted?.workflow == changed)
check("it names who proposed it, when and why", accepted?.proposedBy == "Claude Code" && accepted?.summary == "Let an AI move a bug back" && accepted?.at == Date(timeIntervalSince1970: 1_800_000_000))
check("it carries the differences in words", accepted?.differences.contains { $0.contains("Bug step added") && $0.contains("an investigation finishes") } == true)
check("the same workflow as JSON text is accepted too", proposal(evaluate(text(changed))) != nil)
check("a proposal on the current revision is not outdated", accepted?.isOutdated(against: current) == false)
var moved = current
moved.revision = 5
check("a proposal is outdated once the file has moved on", accepted?.isOutdated(against: moved) == true)
check("the summary is trimmed", proposal(evaluate(object(changed), summary: "  Because  "))?.summary == "Because")

// MARK: A proposal that is refused, with every problem

check("a missing summary is refused", refusal(evaluate(object(changed), summary: "  ")).contains { $0.contains("`summary` is required") })
check("something that is not a workflow is refused", refusal(evaluate(nil)).contains { $0.contains("whole workflow as a JSON object") }
      && refusal(evaluate(42)).contains { $0.contains("whole workflow as a JSON object") })
check("text that is not JSON is refused", refusal(evaluate("not json")).contains { $0.contains("not a workflow in the file format") })
check("an object of the wrong shape is refused", refusal(evaluate(["name": "x"])).contains { $0.contains("not a workflow in the file format") })
var newer = changed
newer.schema = 99
check("a schema from a newer app is refused", refusal(evaluate(object(newer))).contains { $0.contains("schema 99") })
var stale = changed
stale.revision = 3
check("a proposal on an older revision is refused and says to read again",
      refusal(evaluate(object(stale))).contains { $0.contains("revision 3") && $0.contains("revision 4") && $0.contains("markview_get_workflow") })
var ahead = changed
ahead.revision = 9
check("a proposal on a newer revision is refused too", refusal(evaluate(object(ahead))).contains { $0.contains("revision 9") })
check("a workflow that breaks a rule is refused with the rule's message", {
    var broken = changed
    broken.name = " "
    return refusal(evaluate(object(broken))).contains { $0.contains("needs a name") }
}())
check("an event this app does not know is refused", {
    var future = current
    future.bug.rules.append(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.system: []], event: RuleEvent(rawValue: "teleported")))
    return refusal(evaluate(object(future))).contains { $0.contains("teleported") && $0.contains("does not know") }
}())
check("a proposal that changes nothing is refused", refusal(evaluate(object(current))).contains { $0.contains("changes nothing") })
check("all the problems come back at once", {
    var broken = changed
    broken.name = " "
    broken.revision = 3
    return refusal(evaluate(object(broken), summary: "")).count >= 3
}())
check("a refusal makes no proposal", proposal(evaluate(object(stale))) == nil)

// MARK: What the assistant is told

let told = WorkflowProposalChecker.reply(accepted!, needsReplacement: [])
check("the reply says what changes", told.contains("What it changes:") && told.contains("Bug step added"))
check("the reply tells the person where to save and that the assistant cannot",
      told.contains("Workflow tab") && told.contains("Review in the draft") && told.contains("press Save") && told.contains("You cannot save it"))
check("the reply lists no replacements when there are none", !told.contains("need a replacement"))
var impact = WorkflowImpact()
impact.statuses[.bug] = ["open": ["BUG-1", "BUG-2"]]
impact.variants["quick"] = ["f1"]
let lines = WorkflowProposalChecker.replacementLines(impact)
check("replacements are listed by status and process", lines.count == 2 && lines[0].contains("2 bug item(s) in the status open") && lines[1].contains("process quick"))
check("the reply lists the replacements", WorkflowProposalChecker.reply(accepted!, needsReplacement: lines).contains("need a replacement when it is saved"))
check("a long list of items is cut", WorkflowProposalChecker.replacementLines({ var i = WorkflowImpact(); i.statuses[.bug] = ["open": (1...9).map { "BUG-\($0)" }]; return i }())[0].contains("…"))

finish("workflow proposal")
