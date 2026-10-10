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
print(failures == 0 ? "All deployment prompt checks passed." : "\(failures) deployment prompt check(s) failed.")
exit(failures == 0 ? 0 : 1)
