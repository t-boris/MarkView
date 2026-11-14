import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}

let step = CockpitStep(title: "Review", agent: "Codex", assignment: "Inspect the project", completionCondition: "Report findings")
var plan = CockpitPlan(goal: "Inspect", controls: CockpitControls(), scenarios: [], steps: [step], successCriteria: ["Report provided"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
var scenarioPlan = plan
scenarioPlan.scenarios = ["scenario"]
scenarioPlan.steps[0].qaScenarioID = "scenario"
scenarioPlan.steps.append(CockpitStep(title: "Verify", agent: "Codex", assignment: "Review evidence", completionCondition: "Criteria assessed"))
check(CockpitApproval(plan: scenarioPlan, productionConfirmed: true) == nil, "a selected scenario requires its exact QA review")
let reviewed = CockpitQAReview(scenarioID: "scenario", targetID: "prod", fingerprint: "hash", production: true, exactPlan: "exact", dataChangingActions: ["write"])
scenarioPlan.qaReviews = [reviewed]
scenarioPlan.productionQA = CockpitProductionQA(exactPlan: "exact", dataChangingActions: ["write"])
check(CockpitApproval(plan: scenarioPlan, productionConfirmed: false) == nil, "production data changes require explicit confirmation")
let scenarioApproval = CockpitApproval(plan: scenarioPlan, productionConfirmed: true)
check(scenarioApproval != nil, "the exact production QA plan can be approved")
scenarioPlan.qaReviews?[0].fingerprint = "changed"
check(scenarioApproval?.permits(scenarioPlan) == false, "a changed QA fingerprint invalidates cockpit approval")
var progress = CockpitProgress(passNumber: 1, activity: "Done", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
check(CockpitOutcome.evaluate(criteria: ["Report provided"], progress: progress) == .unverified, "a finished run is not called successful without criterion evidence")
progress.criteriaResults = [CockpitCriterionResult(criterion: "Report provided", met: true, evidence: "Report exists")]
check(CockpitOutcome.evaluate(criteria: ["Report provided"], progress: progress) == .success, "matching evidence supports success")
progress.blockers = ["Unresolved issue"]
check(CockpitOutcome.evaluate(criteria: ["Report provided"], progress: progress) == .blocked, "remaining blockers prevent a success outcome")
var skipQA = scenarioPlan
skipQA.steps.append(CockpitStep(title: "Later", agent: "Codex", assignment: "Continue", completionCondition: "Done"))
let later = skipQA.selectingStart(1)
check(later?.scenarios.isEmpty == true && later?.steps[0].qaScenarioID == nil && later?.productionQA == nil,
      "starting after a QA step excludes its production actions from approval")
check(plan.problems.isEmpty, "a complete plan is valid")
let approval = CockpitApproval(plan: plan, productionConfirmed: false)!
check(approval.permits(plan), "approval permits the reviewed plan")
plan.steps[0].assignment = "Change files"
check(!approval.permits(plan), "changing an assignment invalidates approval")
plan.steps[0].assignment = step.assignment
plan.controls.fixBugs = true
check(!approval.permits(plan), "changing controls invalidates approval")
plan.controls.fixBugs = false
plan.productionQA = CockpitProductionQA(exactPlan: "Create and delete a record", dataChangingActions: ["Create a record", "Delete a record"])
check(CockpitApproval(plan: plan, productionConfirmed: false) == nil, "production changes need explicit confirmation")
let productionApproval = CockpitApproval(plan: plan, productionConfirmed: true)!
plan.productionQA?.dataChangingActions.append("Update a record")
check(!productionApproval.permits(plan), "changed production actions invalidate approval")
plan.steps.append(step)
check(!plan.problems.isEmpty, "duplicate step identifiers are rejected")
let roundTrip = try JSONDecoder().decode(CockpitPlan.self, from: JSONEncoder().encode(plan))
check(roundTrip == plan, "plan retains its reviewed contents through persistence")

// MARK: Per-step models, supervisor choice, old data

let oldStepJSON = #"{"id":"11111111-1111-1111-1111-111111111111","title":"Old","agent":"Codex","assignment":"A","completionCondition":"C","isPrerequisite":false}"#
let oldStep = try JSONDecoder().decode(CockpitStep.self, from: Data(oldStepJSON.utf8))
check(oldStep.model == nil && oldStep.chosenModel == nil, "a step saved before models existed decodes with the default model")
let oldStepEncoded = String(decoding: try JSONEncoder().encode(oldStep), as: UTF8.self)
check(!oldStepEncoded.contains("model"), "a step without a model encodes without the key, so old approvals keep their value")
let oldControlsJSON = #"{"createScenarios":false,"checks":"","fileBugs":true,"fixBugs":false,"build":false,"deployment":"Disabled"}"#
let oldControls = try JSONDecoder().decode(CockpitControls.self, from: Data(oldControlsJSON.utf8))
check(oldControls.supervisorAgent == nil && oldControls.supervisorModel == nil && oldControls.supervisor, "controls saved before the supervisor's model was chosen decode with the project's assistant")
var chosenControls = CockpitControls(); chosenControls.supervisorAgent = " Codex "; chosenControls.supervisorModel = "gpt-5"
let chosenBack = try JSONDecoder().decode(CockpitControls.self, from: JSONEncoder().encode(chosenControls))
check(chosenBack.supervisorAgent == "Codex" && chosenBack.supervisorModel == "gpt-5", "the supervisor's agent and model round-trip, trimmed")
var blankControls = CockpitControls(); blankControls.supervisorModel = "   "
let blankBack = try JSONDecoder().decode(CockpitControls.self, from: JSONEncoder().encode(blankControls))
check(blankBack.supervisorModel == nil, "a blank supervisor model reads as the default")
var modelStep = CockpitStep(title: "M", agent: "Codex", assignment: "A", completionCondition: "C")
modelStep.model = "  gpt-5 "
check(modelStep.chosenModel == "gpt-5", "a step's model is trimmed")
modelStep.model = " "
check(modelStep.chosenModel == nil, "a blank step model is the default")
let freshPlan = CockpitPlan(goal: "G", controls: CockpitControls(), scenarios: [], steps: [CockpitStep(title: "A", agent: "Codex", assignment: "Do A", completionCondition: "A done")],
                            successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
var withModel = freshPlan
withModel.steps[0].model = "gpt-5"
let freshApproval = CockpitApproval(plan: freshPlan, productionConfirmed: false)
check(freshApproval?.permits(freshPlan) == true && freshApproval?.permits(withModel) == false, "changing only a step's model invalidates the approval")

// MARK: The flow's title

check(CockpitText.firstLine("\n  First line  \nSecond") == "First line" && CockpitText.firstLine(" \n ") == "", "the first non-empty line of a text")
var named = CockpitPlan(goal: "  \nWrite the quarterly report\nwith charts", controls: CockpitControls(), scenarios: [], steps: [], successCriteria: [], unavailableOutcomes: [], alternatives: [], productionQA: nil)
check(named.title == nil && named.displayTitle == "Write the quarterly report", "a plan without a title is named by the first line of its goal")
named.title = "  "
check(named.displayTitle == "Write the quarterly report", "a blank title is no title")
named.title = "Quarterly report"
check(named.displayTitle == "Quarterly report" && named.goal.hasPrefix("  \n"), "the title names the flow and the goal stays what the person typed")
let namedBack = try JSONDecoder().decode(CockpitPlan.self, from: JSONEncoder().encode(named))
check(namedBack == named, "a plan keeps its title through persistence")
let encodedNames = try JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as? [String: Any] ?? [:]
check(encodedNames["title"] as? String == "Quarterly report", "a title is saved with the plan")
named.title = nil
let encodedUntitled = try JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as? [String: Any] ?? [:]
check(encodedUntitled["title"] == nil, "a plan without a title saves no title key, so the fingerprint of every earlier plan is unchanged")
let oldPlanBack = try JSONDecoder().decode(CockpitPlan.self, from: JSONEncoder().encode(named))
check(oldPlanBack.title == nil && oldPlanBack == named, "a plan saved before titles existed loads with none")

// MARK: Approval blockers keep the old guards' outcome

/// The guards `CockpitApproval.init?` held before they became `approvalBlockers`: the oracle the list must agree with.
func oldApprovalAllowed(_ plan: CockpitPlan, _ productionConfirmed: Bool) -> Bool {
    guard plan.problems.isEmpty else { return false }
    guard Set(plan.steps.compactMap(\.qaScenarioID)) == Set(plan.scenarios) else { return false }
    guard plan.scenarios.isEmpty || plan.steps.last?.qaScenarioID == nil else { return false }
    if plan.scenarios.isEmpty, plan.qaReviews?.isEmpty == false { return false }
    if !plan.scenarios.isEmpty {
        guard let reviews = plan.qaReviews, reviews.count == plan.scenarios.count,
              Set(reviews.map(\.scenarioID)) == Set(plan.scenarios), Set(plan.scenarios).count == plan.scenarios.count,
              reviews.allSatisfy({ !$0.fingerprint.isEmpty && !$0.exactPlan.isEmpty && !$0.targetID.isEmpty }) else { return false }
        let production = reviews.filter(\.production)
        if production.contains(where: \.productionConfirmationRequired) && !productionConfirmed { return false }
        if !production.isEmpty {
            guard plan.productionQA == CockpitProductionQA(exactPlan: production.map(\.exactPlan).joined(separator: "\n\n"),
                                                           dataChangingActions: production.flatMap(\.dataChangingActions)) else { return false }
        }
    }
    if let qa = plan.productionQA, !qa.dataChangingActions.isEmpty, !productionConfirmed { return false }
    return true
}

func titled(_ title: String, qa: String? = nil) -> CockpitStep {
    CockpitStep(title: title, agent: "Codex", assignment: "Do \(title)", completionCondition: "\(title) done", qaScenarioID: qa)
}
let review = CockpitQAReview(scenarioID: "s1", targetID: "t", fingerprint: "f", production: false, exactPlan: "{}", dataChangingActions: [])
let prodReview = CockpitQAReview(scenarioID: "s1", targetID: "prod", fingerprint: "f", production: true, exactPlan: "{}", dataChangingActions: ["write"])
let prodQA = CockpitProductionQA(exactPlan: "{}", dataChangingActions: ["write"])
func base(steps: [CockpitStep], scenarios: [String] = []) -> CockpitPlan {
    CockpitPlan(goal: "G", controls: CockpitControls(), scenarios: scenarios, steps: steps, successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
}
var cases: [(String, CockpitPlan)] = []
cases.append(("plain", base(steps: [titled("A")])))
cases.append(("no steps", base(steps: [])))
var noGoal = base(steps: [titled("A")]); noGoal.goal = " "; cases.append(("no goal", noGoal))
var noCriteria = base(steps: [titled("A")]); noCriteria.successCriteria = []; cases.append(("no criteria", noCriteria))
var emptyField = base(steps: [titled("A")]); emptyField.steps[0].assignment = ""; cases.append(("empty assignment", emptyField))
var duplicate = base(steps: [titled("A")]); duplicate.steps.append(duplicate.steps[0]); cases.append(("duplicate ids", duplicate))
cases.append(("scenario without a step", base(steps: [titled("A")], scenarios: ["s1"])))
cases.append(("step without a scenario entry", base(steps: [titled("A", qa: "s1"), titled("V")])))
cases.append(("qa last", base(steps: [titled("A"), titled("Q", qa: "s1")], scenarios: ["s1"])))
var noReview = base(steps: [titled("Q", qa: "s1"), titled("V")], scenarios: ["s1"]); cases.append(("qa without a review", noReview))
var reviewedPlan = noReview; reviewedPlan.qaReviews = [review]; cases.append(("qa reviewed", reviewedPlan))
var strayReview = base(steps: [titled("A")]); strayReview.qaReviews = [review]; cases.append(("review without a scenario", strayReview))
var emptyReview = reviewedPlan; emptyReview.qaReviews = [CockpitQAReview(scenarioID: "s1", targetID: "", fingerprint: "f", production: false, exactPlan: "{}", dataChangingActions: [])]; cases.append(("review without a target", emptyReview))
var prod = noReview; prod.qaReviews = [prodReview]; cases.append(("production without its plan", prod))
var prodWithPlan = prod; prodWithPlan.productionQA = prodQA; cases.append(("production with its plan", prodWithPlan))
var prodWrong = prod; prodWrong.productionQA = CockpitProductionQA(exactPlan: "other", dataChangingActions: ["write"]); cases.append(("production plan mismatch", prodWrong))
var strayProduction = base(steps: [titled("A")]); strayProduction.productionQA = prodQA; cases.append(("production actions without QA", strayProduction))
var needsConfirm = prodWithPlan; needsConfirm.qaReviews = [CockpitQAReview(scenarioID: "s1", targetID: "prod", fingerprint: "f", production: true, exactPlan: "{}", dataChangingActions: ["write"], productionConfirmationRequired: true)]; cases.append(("production confirmation required", needsConfirm))
for (name, candidate) in cases {
    for confirmed in [false, true] {
        let blockers = candidate.approvalBlockers(productionConfirmed: confirmed)
        check(blockers.isEmpty == oldApprovalAllowed(candidate, confirmed), "approval blockers agree with the old guards: \(name), confirmed \(confirmed)")
        check((CockpitApproval(plan: candidate, productionConfirmed: confirmed) != nil) == blockers.isEmpty, "approval exists exactly when nothing blocks it: \(name), confirmed \(confirmed)")
        check(blockers.allSatisfy { !$0.message.isEmpty }, "every blocker says why: \(name)")
    }
}
check(emptyField.approvalBlockers(productionConfirmed: false).first?.stepID == emptyField.steps[0].id, "a blocker of one step names that step")
check(base(steps: [titled("A"), titled("Q", qa: "s1")], scenarios: ["s1"]).approvalBlockers(productionConfirmed: false).contains { $0.stepID != nil && $0.message.contains("final verification") },
      "the missing final verification points at the last step")

// MARK: Editing keeps the invariants

var edit = base(steps: [titled("A"), titled("B", qa: "s1"), titled("C")], scenarios: ["s1"])
edit.qaReviews = [review]; edit.productionQA = prodQA
let ids = edit.steps.map(\.id)
edit.moveStep(at: 0, by: 1)
check(edit.steps.map(\.title) == ["B", "A", "C"], "a step moves down")
edit.moveStep(at: 0, by: -1)
check(edit.steps.map(\.title) == ["B", "A", "C"], "a step cannot move above the first place")
edit.moveStep(at: 2, by: 1)
check(edit.steps.map(\.title) == ["B", "A", "C"], "a step cannot move below the last place")
edit.normalizeScenarios()
check(edit.scenarios == ["s1"] && edit.qaReviews == nil && edit.productionQA == nil, "normalizing follows the steps and drops the reviews that were derived from the old order")
edit.duplicateStep(at: 0)
check(edit.steps.count == 4 && Set(edit.steps.map(\.id)).count == 4 && edit.steps[1].title == edit.steps[0].title, "a duplicate gets its own identity")
check(edit.steps[1].qaScenarioID == nil && edit.steps[1].isPrerequisite == false, "a duplicate never repeats a QA scenario or a prerequisite")
edit.removeStep(at: 0)
check(edit.scenarios.isEmpty && !edit.steps.contains { $0.qaScenarioID != nil }, "removing the only QA step removes its scenario")
check(Set(edit.steps.map(\.id)).count == edit.steps.count && edit.steps.count == 3, "removal keeps identities unique")
edit.insertStep(titled("New"), at: 99)
check(edit.steps.last?.title == "New", "an insert past the end appends")
edit.insertStep(titled("First"), at: -5)
check(edit.steps.first?.title == "First", "an insert before the start prepends")
edit.setAgent("Claude Code", forStep: edit.steps[0].id)
edit.setModel("opus", forStep: edit.steps[0].id)
check(edit.steps[0].agent == "Claude Code" && edit.steps[0].model == "opus", "agent and model are set by step id")
edit.setAgent("Codex", forStep: edit.steps[0].id)
check(edit.steps[0].model == nil, "changing the agent clears the model, which belonged to the other agent")
edit.setModel("", forStep: edit.steps[0].id)
check(edit.steps[0].model == nil, "an empty model is the default")
_ = ids

var shaping = CockpitControls()
var limited = shaping; limited.timeLimitMinutes = 60; limited.fixCycleLimit = 3; limited.supervisor = false; limited.supervisorModel = "opus"
check(!limited.affectsSteps(comparedTo: shaping), "limits and the supervisor change no step")
var building = shaping; building.build = true
check(building.affectsSteps(comparedTo: shaping), "what the planner was told does change the steps")
print("All cockpit plan checks passed")
