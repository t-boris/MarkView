import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}
let none = DeploymentPrompt.analyze(project: "shop", existing: [], hasMCP: true)
check(none.contains("project shop") && none.contains("No environment is set up yet.") && none.contains("markview_deployments_propose"), "a fresh project")
let some = DeploymentPrompt.analyze(project: "shop", existing: ["Production", "Staging"], hasMCP: true)
check(some.contains("Already set up: Production, Staging") && some.contains("Do not propose these again"), "existing environments are not proposed again")
check(none.contains("never ask me for a password") && none.contains("do not read, print or write secret values") && none.contains("approval"), "the rules about secrets and approval are in it")
check(DeploymentPrompt.analyze(project: "x", existing: [], hasMCP: false).contains("--project-call"), "without MCP it names the command")
let asked = DeploymentPrompt.ask(environment: "Prod", id: "prod", question: "Why is it slow?", report: "Prod (prod) — ssh\n  health: warning", logTitle: "App", log: "ERROR timeout\nERROR timeout")
check(asked.contains("\"Prod\" (id prod)") && asked.contains("Why is it slow?") && asked.contains("health: warning") && asked.contains("ERROR timeout") && asked.contains("(App)"), "a question carries the environment, the state and the log")
check(asked.contains("markview_deployments_status") && asked.contains("Do not change anything without asking me"), "and the rules")
check(asked.contains("you have tools for it"), "it points to the provider's own tools")
check(!DeploymentPrompt.ask(environment: "P", id: "p", question: "q", report: "r").contains("The log I am reading"), "no log section without a log")
check(DeploymentPrompt.ask(environment: "P", id: "p", question: "q", report: "r", logTitle: "L", log: String(repeating: "x", count: 20000)).count < 9500, "a long log is cut to its end")
let answer = DeploymentPrompt.answer(environment: "Prod", id: "prod", question: "Is the database fine?", report: "Prod (prod) — ssh", evidence: [("Container pg", "FATAL: too many connections"), ("Errors only", "-- No entries --")])
check(answer.contains("Use ONLY the evidence") && answer.contains("--- Container pg ---") && answer.contains("too many connections") && answer.contains("Is the database fine?"), "the in-app prompt carries the question and the evidence")
check(answer.contains("**Verdict:**") && answer.contains("(read-only)") && answer.contains("(changes something"), "and the shape of the answer")
check(DeploymentPrompt.answer(environment: "P", id: "p", question: "q", report: "r", evidence: []).contains("(No log could be read.)"), "with no evidence it says so")
check(DeploymentPrompt.answer(environment: "P", id: "p", question: "q", report: "r", evidence: [("a", String(repeating: "x", count: 50000)), ("b", String(repeating: "y", count: 50000))]).count < 40000, "a lot of evidence is cut")
print(failures == 0 ? "All deployment prompt checks passed." : "\(failures) deployment prompt check(s) failed.")
exit(failures == 0 ? 0 : 1)
