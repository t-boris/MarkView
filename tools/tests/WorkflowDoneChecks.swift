import Foundation

// Feature workflow-flows, REQ-001: what "done" means in a process and where it disagrees with the Definition of Done
// (Models/WorkflowDone.swift). Run through tools/tests/workflow-done-tests.sh.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

let standard = ProjectWorkflow.standard
let feature = standard.variant(StandardWorkflow.featureVariantID)!
let bug = standard.variant(StandardWorkflow.bugVariantID)!
func mark(_ done: WorkflowDone, _ name: String) -> WorkflowDone.Mark { done.marks.first { $0.name == name }! }

// MARK: What done means

let featureDone = WorkflowDone.make(feature, definition: nil)
check(!mark(featureDone, "Pull request").required && !mark(featureDone, "CI checks").required && !mark(featureDone, "Release").required,
      "the standard feature process requires no pull request, no checks and no release")
check(featureDone.sentence == "Done here means the work on the default branch, then accepted by a person or an AI with evidence.",
      "…and says so in one sentence", featureDone.sentence)

let bugDone = WorkflowDone.make(bug, definition: nil)
check(mark(bugDone, "Pull request").required && mark(bugDone, "CI checks").required, "the standard bug process requires a pull request and passing checks")
check(bugDone.sentence == "Done here means a merged pull request and passing checks, then accepted by a person or an AI with evidence.", "…in one sentence", bugDone.sentence)

let strict = RuleVariant(id: "strict", name: "Strict", kind: .feature, integration: .pullRequest, checks: true, delivery: .githubRelease, acceptance: .humanOnly)
let strictDone = WorkflowDone.make(strict, definition: nil)
check(strictDone.sentence == "Done here means a merged pull request, passing checks and a published GitHub release, then accepted by a person.",
      "a pull request, checks, a release and a person's acceptance are all named", strictDone.sentence)
check(mark(strictDone, "Release").required && mark(strictDone, "Acceptance").detail == "Only a person accepts", "…each mark has its detail")

let confirmed = RuleVariant(id: "installed", name: "Installed", kind: .feature, integration: .directToMain, checks: false,
                            delivery: .humanConfirmed(name: "installed on the other Mac"))
let confirmedDone = WorkflowDone.make(confirmed, definition: nil)
check(mark(confirmedDone, "Delivery event").detail == "A person confirms: installed on the other Mac" && confirmedDone.sentence.contains("a person's confirmation: installed on the other Mac"),
      "an event a person confirms is named", confirmedDone.sentence)

var byAI = confirmed
byAI.confirmer = .personOrAI
let byAIDone = WorkflowDone.make(byAI, definition: nil)
check(mark(byAIDone, "Delivery event").detail == "A person, or an AI with its evidence, confirms: installed on the other Mac"
      && byAIDone.sentence.contains("a confirmation by a person or an AI with evidence: installed on the other Mac"),
      "an event that an AI may confirm says so", byAIDone.sentence)

// A flow whose only completed status is Done has no acceptance step.
let noStep = WorkflowDone.make(feature, definition: nil, acceptanceStep: false)
check(!mark(noStep, "Acceptance").required && noStep.sentence == "Done here means the work on the default branch.",
      "without an acceptance step nobody accepts afterwards", noStep.sentence)

// MARK: Where the Definition of Done disagrees

let checklist = DefinitionOfDone.standard   // a pull request and green CI required, merge asked, deploy skipped
check(WorkflowDone.make(feature, definition: checklist).warnings.count == 2,
      "the standard checklist requires a pull request and CI, the standard feature process does not: two warnings",
      "\(WorkflowDone.make(feature, definition: checklist).warnings)")
check(WorkflowDone.make(bug, definition: checklist).warnings.isEmpty, "…and the standard bug process agrees with it")
check(WorkflowDone.make(feature, definition: nil).warnings.isEmpty, "no checklist, no warning")

var relaxed = DefinitionOfDone.standard
for index in relaxed.items.indices where ["pr", "ci"].contains(relaxed.items[index].id) { relaxed.items[index].mode = .skip }
check(WorkflowDone.make(strict, definition: relaxed).warnings.count == 2, "a checklist that skips a pull request and CI disagrees with a process that requires them",
      "\(WorkflowDone.make(strict, definition: relaxed).warnings)")
for index in relaxed.items.indices where ["pr", "ci"].contains(relaxed.items[index].id) { relaxed.items[index].mode = .ask }
check(WorkflowDone.make(feature, definition: relaxed).warnings.isEmpty, "'ask me' is a question, not a requirement either way")
var deploy = DefinitionOfDone.standard
for index in deploy.items.indices where deploy.items[index].id == "deploy" { deploy.items[index].mode = .require }
check(WorkflowDone.make(bug, definition: deploy).warnings == ["The Definition of Done requires a build and deploy, but this process has no delivery event."],
      "a required deploy against a process without a delivery event", "\(WorkflowDone.make(bug, definition: deploy).warnings)")

// MARK: Where in the transitions

let steps = WorkflowDone.steps(in: standard.feature)
check(steps.delivery == "Implementing → Implemented" && steps.acceptance == "Implemented → Verified",
      "delivery is judged at Implementing → Implemented and accepted at Implemented → Verified", "\(steps)")
var noAcceptance = standard.feature
noAcceptance.rules.removeAll { $0.kind == .acceptance }
check(WorkflowDone.steps(in: noAcceptance).acceptance == nil, "a flow without an acceptance step names none")
let bugSteps = WorkflowDone.steps(in: standard.bug)
check(bugSteps.delivery == "Fixing → Fixed" && bugSteps.acceptance == "Fixed → Closed", "bugs: Fixing → Fixed, then Fixed → Closed", "\(bugSteps)")

// MARK: GitHub (feature workflow-templates, REQ-004)

let strictOff = WorkflowDone.make(strict, definition: nil, githubEnabled: false)
check(strictOff.githubWarning != nil, "a process that needs GitHub warns while GitHub is not connected")
check(strictOff.githubWarning?.contains("a merged pull request, passing checks and a published GitHub release") == true, "…naming everything it needs", strictOff.githubWarning ?? "")
check(strictOff.githubWarning?.contains("Settings → GitHub") == true && strictOff.githubWarning?.contains("“Reaches the branch”, “Checks must pass” and “Delivery event”") == true,
      "…and both ways out: connect GitHub, or the controls that switch the requirements off", strictOff.githubWarning ?? "")
check(WorkflowDone.make(strict, definition: nil, githubEnabled: true).githubWarning == nil, "no warning once GitHub is connected")
check(WorkflowDone.make(strict, definition: nil).githubWarning == nil, "a caller that does not say whether GitHub is connected raises none")
let checksOnly = RuleVariant(id: "checks", name: "Checks only", kind: .bug, integration: .directToMain, checks: true)
check(WorkflowDone.make(checksOnly, definition: nil, githubEnabled: false).githubWarning?.contains("passing checks from GitHub") == true
      && WorkflowDone.make(checksOnly, definition: nil, githubEnabled: false).githubWarning?.contains("“Checks must pass”") == true,
      "only what is required is named")
check(WorkflowDone.make(feature, definition: nil, githubEnabled: false).githubWarning == nil, "a process that needs nothing does not warn")
check(WorkflowDone.make(confirmed, definition: nil, githubEnabled: false).githubWarning == nil, "a delivery event a person confirms needs no GitHub")
check(WorkflowDone.githubNeeds(strict).map(\.control) == ["Reaches the branch", "Checks must pass", "Delivery event"], "each need names the control that switches it")

check(featureDone.enableHint?.contains("Processes → Standard feature") == true && featureDone.enableHint?.contains("“Reaches the branch”, “Checks must pass” and “Delivery event”") == true
      && featureDone.enableHint?.contains("Settings → GitHub") == true, "a process that needs nothing says where to switch the requirements on", featureDone.enableHint ?? "")
check(strictDone.enableHint == nil && bugDone.enableHint == nil, "…and a process that already needs GitHub does not")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
