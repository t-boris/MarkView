import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}
let step: [String: Any] = ["title": "Research", "agent": "Codex", "assignment": "Inspect", "completionCondition": "Report", "isPrerequisite": true]
var answer: [String: Any] = ["scenarios": [], "steps": [step], "successCriteria": ["Report exists"], "unavailableOutcomes": ["Delivery"], "alternatives": ["Prepare an order"]]
var controls = CockpitControls(); controls.fixBugs = false
let schema = CockpitPlanning.schema
let rootRequired = Set(schema["required"] as? [String] ?? [])
let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
let stepSchema = properties["steps"]?["items"] as? [String: Any] ?? [:]
check(rootRequired == Set(["scenarios", "steps", "successCriteria", "unavailableOutcomes", "alternatives"]), "the schema requires every root field the parser reads")
check(Set(stepSchema["required"] as? [String] ?? []) == Set(["title", "agent", "assignment", "completionCondition", "isPrerequisite"]), "the schema requires every step field the parser reads")
let plan = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
check(plan.controls == controls && plan.steps.first?.isPrerequisite == true, "the person's controls and prerequisite survive parsing")
check(plan.unavailableOutcomes == ["Delivery"] && plan.alternatives == ["Prepare an order"], "unavailable outcomes and alternatives survive parsing")
check((try? CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Claude"])) == nil, "an unavailable agent is rejected")
answer["steps"] = []
answer["successCriteria"] = []
let infeasible = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
check(infeasible.unavailableOutcomes == ["Delivery"] && CockpitApproval(plan: infeasible, productionConfirmed: false) == nil,
      "an infeasible goal can be explained but cannot be approved for execution")
answer["steps"] = [["title": "Missing fields"]]
check((try? CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "malformed steps are rejected")
print("All cockpit planning checks passed")
