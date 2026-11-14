import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}
let step: [String: Any] = ["title": "Research", "agent": "Codex", "assignment": "Inspect", "completionCondition": "Report", "isPrerequisite": true, "qaScenarioID": ""]
var answer: [String: Any] = ["scenarios": [], "steps": [step], "successCriteria": ["Report exists"], "unavailableOutcomes": ["Delivery"], "alternatives": ["Prepare an order"]]
var controls = CockpitControls(); controls.fixBugs = false
let schema = CockpitPlanning.schema
let rootRequired = Set(schema["required"] as? [String] ?? [])
let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
let stepSchema = properties["steps"]?["items"] as? [String: Any] ?? [:]
check(rootRequired == Set(["title", "scenarios", "steps", "successCriteria", "unavailableOutcomes", "alternatives"]), "the schema requires every root field the parser reads, the flow's title among them")
check(Set(stepSchema["required"] as? [String] ?? []) == Set(["title", "agent", "model", "assignment", "completionCondition", "isPrerequisite", "qaScenarioID"]), "the schema requires every step field the parser reads")
let plan = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
check(plan.controls == controls && plan.steps.first?.isPrerequisite == true, "the person's controls and prerequisite survive parsing")
check(plan.unavailableOutcomes == ["Delivery"] && plan.alternatives == ["Prepare an order"], "unavailable outcomes and alternatives survive parsing")
check((try? CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Claude"])) == nil, "an unavailable agent is rejected")
var qaAnswer = answer
qaAnswer["scenarios"] = ["scenario-1"]
check((try? CockpitPlanning.parse(qaAnswer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "an unassigned QA scenario is rejected")
var qaStep = step; qaStep["qaScenarioID"] = "scenario-1"; qaAnswer["steps"] = [qaStep]
check((try? CockpitPlanning.parse(qaAnswer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "QA needs a final verification step")
qaAnswer["steps"] = [qaStep, step]
check((try? CockpitPlanning.parse(qaAnswer, goal: "Research", controls: controls, availableAgents: ["Codex"]))?.steps.first?.qaScenarioID == "scenario-1", "a QA scenario is tied to its step")
answer["steps"] = []
answer["successCriteria"] = []
let infeasible = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
check(infeasible.unavailableOutcomes == ["Delivery"] && CockpitApproval(plan: infeasible, productionConfirmed: false) == nil,
      "an infeasible goal can be explained but cannot be approved for execution")
var modelStep = step; modelStep["model"] = "gpt-5"
answer["steps"] = [modelStep]
answer["successCriteria"] = ["Report exists"]
let known = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"], models: ["Codex": ["gpt-5", "gpt-5-mini"]])
check(known.steps.first?.model == "gpt-5", "a proposed model the agent offers is kept")
let unknown = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"], models: ["Codex": ["gpt-5-mini"]])
check(unknown.steps.first?.model == nil, "a proposed model the agent does not offer becomes the default instead of failing the plan")
let unlisted = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])
check(unlisted.steps.first?.model == nil, "without a model list no proposed model is trusted")
modelStep["model"] = "  "
answer["steps"] = [modelStep]
let blank = try CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"], models: ["Codex": ["gpt-5"]])
check(blank.steps.first?.model == nil, "a blank model means the default")

// MARK: The assistant's name for the flow

var titled = answer
let untitled = try CockpitPlanning.parse(titled, goal: "Research the market\nin detail", controls: controls, availableAgents: ["Codex"])
check(untitled.title == nil, "an answer without a title still parses, with no title")
check(untitled.displayTitle == "Research the market", "without a title the flow is named by the first line of the goal")
func parsedTitle(_ value: Any?) throws -> String? {
    titled["title"] = value
    return try CockpitPlanning.parse(titled, goal: "Research", controls: controls, availableAgents: ["Codex"]).title
}
let kept = try parsedTitle("Market research report")
check(kept == "Market research report", "a title is kept")
let collapsed = try parsedTitle("  Weekly\n release   checklist \n")
check(collapsed == "Weekly release checklist", "line breaks and extra spaces in a title collapse to single spaces")
let curly = try parsedTitle("\u{201C}Ship the release\u{201D}"), straight = try parsedTitle("'Ship it'")
check(curly == "Ship the release" && straight == "Ship it", "quotes around a title are removed")
let russian = try parsedTitle("Проверка релиза")
check(russian == "Проверка релиза", "a title in the language of the goal is kept as it is")
let longTitle = try parsedTitle(String(repeating: "word ", count: 40))
check((longTitle?.count ?? 0) <= CockpitPlanning.maxTitleLength && longTitle?.hasSuffix(" ") == false, "a long title is cut to the limit")
let blankTitle = try parsedTitle("   "), quotesOnly = try parsedTitle("\"\"")
check(blankTitle == nil && quotesOnly == nil, "a blank title is no title and does not fail the plan")
let wrongType = try parsedTitle(42), noTitle = try parsedTitle(nil)
check(wrongType == nil && noTitle == nil, "a title of the wrong type is no title and does not fail the plan")

answer["steps"] = [["title": "Missing fields"]]
check((try? CockpitPlanning.parse(answer, goal: "Research", controls: controls, availableAgents: ["Codex"])) == nil, "malformed steps are rejected")
print("All cockpit planning checks passed")
