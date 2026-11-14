import Foundation

// Checks for MarkView/Models/CockpitStepPolicy.swift and the controls of CockpitPlan.swift, run by tools/tests/cockpit-policy-tests.sh
// from the repository root. Nothing touches the app: the tool names are read from the sources that declare them.

func controls(_ edit: (inout CockpitControls) -> Void = { _ in }) -> CockpitControls {
    var value = CockpitControls()
    edit(&value)
    return value
}

let isFixing: (String) -> Bool = { ["fixing", "fixed"].contains($0.lowercased()) }
let namesOf: (String) -> [String] = { id in id == "prod" ? ["Production"] : [] }

func decide(_ policy: CockpitStepPolicy, _ tool: String, _ arguments: [String: Any] = [:]) -> CockpitStepPolicy.Decision {
    policy.decision(tool: tool, arguments: arguments, isFixingStatus: isFixing, environmentNames: namesOf)
}

func allowed(_ policy: CockpitStepPolicy, _ tool: String, _ arguments: [String: Any] = [:]) -> Bool {
    if case .allow = decide(policy, tool, arguments) { return true }
    return false
}

// MARK: every tool is classified

let sources = ["ProjectAgentTools", "ControlAgentTools", "DeploymentAgentTools", "DiscussionAgentTools"]
var declared: Set<String> = []
for source in sources {
    let text = (try? String(contentsOfFile: "MarkView/Models/\(source).swift", encoding: .utf8)) ?? ""
    let pattern = try! NSRegularExpression(pattern: #"tool\("(markview_[a-z_]+)""#)
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text) { declared.insert(String(text[range])) }
    }
}
check("tool names are read from the four declaring files (\(declared.count) found)", declared.count > 50)
let unclassified = declared.filter { CockpitStepPolicy.classes[$0] == nil }.sorted()
check("every MarkView tool is classified (unclassified: \(unclassified))", unclassified.isEmpty)
let stale = CockpitStepPolicy.classes.keys.filter { !declared.contains($0) }.sorted()
check("the table names no tool that does not exist (stale: \(stale))", stale.isEmpty)

// MARK: decisions

let strict = CockpitStepPolicy(controls: controls { $0.fileBugs = false; $0.fixBugs = false; $0.deployment = "Disabled" })
let open = CockpitStepPolicy(controls: controls { $0.fileBugs = true; $0.fixBugs = true; $0.deployment = "Production" })

check("an unknown tool is refused", !allowed(open, "markview_invented"))
check("browser tools stay open", allowed(strict, "browser_click") && allowed(strict, "browser_snapshot"))
check("reports are always allowed", allowed(strict, "markview_cockpit_complete_step") && allowed(strict, "markview_cockpit_report_progress"))
check("reads are always allowed", allowed(strict, "markview_list_bugs") && allowed(strict, "markview_deployments_logs") && allowed(strict, "markview_flow_status"))
check("project records are allowed", allowed(strict, "markview_add_requirement") && allowed(strict, "markview_update_bug"))

for tool in ["markview_agent_start", "markview_agent_send", "markview_agent_key", "markview_flow_new", "markview_flow_answer",
             "markview_flow_run", "markview_flow_implement", "markview_flow_fix_bug", "markview_flow_stop"] {
    check("\(tool) is refused even when everything else is allowed", !allowed(open, tool))
}

check("create_bug follows File bugs", allowed(open, "markview_create_bug") && !allowed(strict, "markview_create_bug"))
check("a bug may be reopened or closed with fixing off", allowed(strict, "markview_set_bug_status", ["status": "open"]) && allowed(strict, "markview_set_bug_status", ["status": "closed"]))
check("a bug may not move into fixing or fixed with fixing off", !allowed(strict, "markview_set_bug_status", ["status": "fixing"]) && !allowed(strict, "markview_set_bug_status", ["status": "Fixed"]))
check("a bug may move into fixing with fixing on", allowed(open, "markview_set_bug_status", ["status": "fixing"]))

check("deployment Disabled refuses run, propose and delivery", ["markview_deployments_run", "markview_deployments_propose", "markview_confirm_delivery"].allSatisfy { !allowed(strict, $0, ["environment": "prod"]) })
check("deployment Disabled still allows reading an environment", allowed(strict, "markview_deployments_status", ["environment": "prod"]))
check("a named environment is accepted by id", allowed(CockpitStepPolicy(controls: controls { $0.deployment = "prod" }), "markview_deployments_run", ["environment": "prod", "command": "uptime"]))
check("a named environment is accepted by name", allowed(open, "markview_deployments_run", ["environment": "prod", "command": "uptime"]))
check("another environment is refused", !allowed(open, "markview_deployments_run", ["environment": "staging", "command": "uptime"]))
check("a run without an environment is refused", !allowed(open, "markview_deployments_run", ["command": "uptime"]))
for word in ["", "  ", "disabled", "None", "OFF", "no"] {
    check("deployment text \"\(word)\" means disabled", CockpitStepPolicy(controls: controls { $0.deployment = word }).deploymentTarget == nil)
}

check("a fix cycle starts with a move into fixing", CockpitStepPolicy.startsFixCycle(tool: "markview_set_bug_status", arguments: ["status": "fixing"], isFixingStatus: isFixing))
check("other calls do not start a fix cycle", !CockpitStepPolicy.startsFixCycle(tool: "markview_set_bug_status", arguments: ["status": "open"], isFixingStatus: isFixing)
      && !CockpitStepPolicy.startsFixCycle(tool: "markview_create_bug", arguments: ["status": "fixing"], isFixingStatus: isFixing))

check("the review lists what is refused", strict.enforced.contains { $0.contains("Deploy") || $0.contains("deployment") } && strict.enforced.contains { $0.contains("bug") })
check("Build and Checks are reported as instruction only", CockpitStepPolicy.instructionOnly(controls { $0.build = false; $0.checks = "unit tests" }) == ["Build", "Checks"])
check("nothing is instruction only when build is on and checks are empty", CockpitStepPolicy.instructionOnly(controls { $0.build = true }).isEmpty)

// MARK: controls and their limits

func decoded(_ json: String) -> CockpitControls? { try? JSONDecoder().decode(CockpitControls.self, from: Data(json.utf8)) }

for (text, minutes) in [("90", 90), ("90 min", 90), ("2h", 120), ("1h30m", 90), ("1.5 hours", 90), ("45 minutes", 45), ("1h and 30m", 90), ("1h, 30m", 90)] as [(String, Int)] {
    check("\"\(text)\" is \(minutes) minutes", CockpitControls.minutes(in: text) == minutes)
}
for text in ["", "soon", "two hours", "5 months", "0", "about 2h"] {
    check("\"\(text)\" is no limit", CockpitControls.minutes(in: text) == nil)
}

let legacy = decoded(#"{"createScenarios":true,"checks":"smoke","fileBugs":false,"fixBugs":true,"build":true,"deployment":"Production","timeLimit":"2h","budgetLimit":"$20","fixCycleLimit":"3"}"#)
check("a run saved with free-text limits still decodes", legacy != nil)
check("its time limit becomes minutes", legacy?.timeLimitMinutes == 120)
check("its fix cycle limit becomes a number", legacy?.fixCycleLimit == 3)
check("its other controls are kept", legacy?.createScenarios == true && legacy?.checks == "smoke" && legacy?.fileBugs == false && legacy?.fixBugs == true && legacy?.build == true && legacy?.deployment == "Production")
let blank = decoded(#"{"timeLimit":"","budgetLimit":"","fixCycleLimit":""}"#)
check("blank legacy limits are no limit", blank?.timeLimitMinutes == nil && blank?.fixCycleLimit == nil)
let vague = decoded(#"{"timeLimit":"a while","fixCycleLimit":"a few"}"#)
check("vague legacy limits are no limit", vague?.timeLimitMinutes == nil && vague?.fixCycleLimit == nil)
check("an empty object decodes to the defaults", decoded("{}") == CockpitControls())

var typed = CockpitControls()
typed.timeLimitMinutes = 90
typed.fixCycleLimit = 2
if let data = try? JSONEncoder().encode(typed) {
    check("typed limits round trip", (try? JSONDecoder().decode(CockpitControls.self, from: data)) == typed)
    check("the budget limit is not written", !(String(data: data, encoding: .utf8) ?? "").contains("budget"))
} else { check("typed limits encode", false) }
if let data = try? JSONEncoder().encode(CockpitControls()) {
    let text = String(data: data, encoding: .utf8) ?? ""
    check("no limit writes no limit keys", !text.contains("timeLimit") && !text.contains("fixCycleLimit"))
}

finish("cockpit policy")
