import Foundation

// Checks for MarkView/Models/CockpitStepPolicy.swift and the controls of CockpitPlan.swift, run by tools/tests/cockpit-policy-tests.sh
// from the repository root. Nothing touches the app: the tool names are read from the sources that declare them.

func controls(_ edit: (inout CockpitControls) -> Void = { _ in }) -> CockpitControls {
    var value = CockpitControls()
    edit(&value)
    return value
}

let isFixing: (String) -> Bool = { $0.lowercased() == "fixing" }
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
check("a bug may not move into fixing with fixing off", !allowed(strict, "markview_set_bug_status", ["status": "fixing"]) && !allowed(strict, "markview_set_bug_status", ["status": "Fixing"]))
check("a move to fixed is left to MarkView's own evidence rules", allowed(strict, "markview_set_bug_status", ["status": "fixed"]))
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

// MARK: audit after the step

typealias Snap = CockpitStepAudit.Snapshot
func snap(_ files: [String: String] = [:], head: String? = "aaaaaaa1", scenarios: Set<String> = [], git: Bool = true) -> Snap {
    Snap(isGitRepository: git, head: head, files: files, scenarios: scenarios)
}
let noFixing = controls { $0.fixBugs = false; $0.createScenarios = false }
let fixing = controls { $0.fixBugs = true; $0.createScenarios = true }

check("an untouched project has no violations", CockpitStepAudit.violations(before: snap(), after: snap(), controls: noFixing).isEmpty)
let edited = CockpitStepAudit.violations(before: snap(), after: snap(["Sources/App.swift": "h1"]), controls: noFixing)
check("a source file changed with fixing off is a violation that names it", edited.count == 1 && edited[0].contains("Sources/App.swift") && edited[0].contains("Fix bugs is off"))
check("the same change is fine with fixing on", CockpitStepAudit.violations(before: snap(), after: snap(["Sources/App.swift": "h1"]), controls: fixing).isEmpty)
check("a file that was already dirty and stayed as it was is not the step's", CockpitStepAudit.violations(before: snap(["a.swift": "h1"]), after: snap(["a.swift": "h1"]), controls: noFixing).isEmpty)
check("a file that was dirty and changed again is detected", CockpitStepAudit.changedSources(before: snap(["a.swift": "h1"]), after: snap(["a.swift": "h2"])) == ["a.swift"])
check("a dirty file put back to clean is detected", CockpitStepAudit.changedSources(before: snap(["a.swift": "h1"]), after: snap()) == ["a.swift"])
check("a deleted file is detected", CockpitStepAudit.changedSources(before: snap(), after: snap(["a.swift": "deleted"])) == ["a.swift"])
check("documentation and notes are not source", CockpitStepAudit.violations(before: snap(), after: snap(["docs/bugs/BUG-1.md": "h", "tasks/todo.md": "h", ".dde/qa/x.json": "h"]), controls: noFixing).isEmpty)
check("a commit with fixing off is a violation", CockpitStepAudit.violations(before: snap(head: "aaaaaaa1"), after: snap(head: "bbbbbbb2"), controls: noFixing).contains { $0.contains("commit") })
check("a commit with fixing on is fine", CockpitStepAudit.violations(before: snap(head: "aaaaaaa1"), after: snap(head: "bbbbbbb2"), controls: fixing).isEmpty)
let many = Dictionary(uniqueKeysWithValues: (1...14).map { ("f\($0).swift", "h") })
let longList = CockpitStepAudit.violations(before: snap(), after: snap(many), controls: noFixing)
check("a long list of files is cut and counted", longList.count == 1 && longList[0].contains("14 source file") && longList[0].contains("and 4 more"))
check("a new scenario with creating off is a violation", CockpitStepAudit.violations(before: snap(scenarios: ["a"]), after: snap(scenarios: ["a", "b"]), controls: noFixing).contains { $0.contains("scenario") && $0.contains("b") })
check("a new scenario with creating on is fine", CockpitStepAudit.violations(before: snap(scenarios: ["a"]), after: snap(scenarios: ["a", "b"]), controls: fixing).isEmpty)
check("a deleted scenario is not a creation", CockpitStepAudit.violations(before: snap(scenarios: ["a", "b"]), after: snap(scenarios: ["a"]), controls: noFixing).isEmpty)
check("outside git nothing is claimed about sources", CockpitStepAudit.violations(before: snap(git: false), after: snap(["a.swift": "h"], git: false), controls: noFixing).isEmpty)
check("outside git the audit says what it could not look at", CockpitStepAudit.limits(of: snap(git: false), controls: noFixing).count == 1)
check("inside git it says nothing extra", CockpitStepAudit.limits(of: snap(), controls: noFixing).isEmpty)
check("with fixing on it has nothing to excuse", CockpitStepAudit.limits(of: snap(git: false), controls: fixing).isEmpty)

// MARK: step meter

var meter = CockpitStepMeter(cycleLimit: 2, cyclesBefore: 0)
check("a new step has used no fix cycle", meter.stepCycles == 0 && !meter.overCycleLimit)
meter.noteGate(cycles: 1)
meter.noteGate(cycles: 2)
check("the gate count within the limit is not over", meter.stepCycles == 2 && !meter.overCycleLimit)
meter.noteGate(cycles: 3)
check("a cycle beyond the limit is over", meter.overCycleLimit)
meter.noteGate(cycles: 1)
check("the gate count never goes down", meter.stepCycles == 3)

var reports = CockpitStepMeter(cycleLimit: 1, cyclesBefore: 0)
reports.noteReport(pass: 1, fixes: [])
check("a report without fixes is not a cycle", reports.stepCycles == 0)
reports.noteReport(pass: 1, fixes: ["BUG-1"])
check("a report with a new fix is a cycle", reports.stepCycles == 1 && !reports.overCycleLimit)
reports.noteReport(pass: 2, fixes: ["BUG-1"])
check("the same fix listed again is not another cycle", reports.stepCycles == 1)
reports.noteReport(pass: 2, fixes: ["BUG-1", "BUG-2"])
check("a cumulative list with one new fix is one more cycle", reports.stepCycles == 2 && reports.overCycleLimit)
reports.noteReport(pass: 2, fixes: ["BUG-1", "BUG-2", "BUG-3"])
check("two fixes in one pass are one cycle", reports.stepCycles == 2)

var both = CockpitStepMeter(cycleLimit: nil, cyclesBefore: 5)
both.noteGate(cycles: 1)
both.noteReport(pass: 1, fixes: ["A"]); both.noteReport(pass: 2, fixes: ["B"]); both.noteReport(pass: 3, fixes: ["C"])
check("the larger of the two counts wins", both.stepCycles == 3)
check("earlier steps' cycles are added", both.totalCycles == 8)
check("no limit is never over", !both.overCycleLimit)
check("earlier cycles count against the limit", CockpitStepMeter(cycleLimit: 3, cyclesBefore: 3).overCycleLimit == false
      && { var m = CockpitStepMeter(cycleLimit: 3, cyclesBefore: 3); m.noteGate(cycles: 1); return m.overCycleLimit }())

check("no time limit has no remaining seconds", CockpitStepMeter.remainingSeconds(limitMinutes: nil, used: 500) == nil)
check("the remaining seconds are the limit less what was used", CockpitStepMeter.remainingSeconds(limitMinutes: 2, used: 30) == 90)
check("used up time is zero or less", (CockpitStepMeter.remainingSeconds(limitMinutes: 1, used: 60) ?? 1) <= 0 && (CockpitStepMeter.remainingSeconds(limitMinutes: 1, used: 90) ?? 1) < 0)

finish("cockpit policy")
