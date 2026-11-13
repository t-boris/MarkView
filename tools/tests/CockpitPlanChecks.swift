import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}

let step = CockpitStep(title: "Review", agent: "Codex", assignment: "Inspect the project", completionCondition: "Report findings")
var plan = CockpitPlan(goal: "Inspect", controls: CockpitControls(), scenarios: [], steps: [step], successCriteria: ["Report provided"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
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
