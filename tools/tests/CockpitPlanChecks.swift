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
check(CockpitApproval(plan: scenarioPlan, productionConfirmed: true) == nil, "a selected scenario requires its exact QA review")
let reviewed = CockpitQAReview(scenarioID: "scenario", targetID: "prod", fingerprint: "hash", production: true, exactPlan: "exact", dataChangingActions: ["write"])
scenarioPlan.qaReviews = [reviewed]
scenarioPlan.productionQA = CockpitProductionQA(exactPlan: "exact", dataChangingActions: ["write"])
check(CockpitApproval(plan: scenarioPlan, productionConfirmed: false) == nil, "production data changes require explicit confirmation")
let scenarioApproval = CockpitApproval(plan: scenarioPlan, productionConfirmed: true)
check(scenarioApproval != nil, "the exact production QA plan can be approved")
scenarioPlan.qaReviews?[0].fingerprint = "changed"
check(scenarioApproval?.permits(scenarioPlan) == false, "a changed QA fingerprint invalidates cockpit approval")
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
print("All cockpit plan checks passed")
