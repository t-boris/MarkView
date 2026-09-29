// Checks per-project assistant choices (BUG-021): AIAssistantPreferences resolves the assistant,
// model and X-Ray model for a project from its own choice, else the defaults, and one project's
// choice never changes another's. Uses the test process's own defaults domain, cleared around.
import Foundation

var failures = 0
func check(_ name: String, _ got: String?, _ want: String?) {
    if got == want { print("ok  \(name)") } else { failures += 1; print("FAIL \(name): got \(got.debugDescription) want \(want.debugDescription)") }
}

let domain = ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: domain)
defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("ai-\(UUID().uuidString)", isDirectory: true)
let a = base.appendingPathComponent("alpha", isDirectory: true)
let b = base.appendingPathComponent("beta", isDirectory: true)
try! FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

// Defaults only.
UserDefaults.standard.set("claude", forKey: AIAssistantPreferences.backendKey)
UserDefaults.standard.set("opus", forKey: AIAssistantPreferences.modelKey(for: .claude))
check("no choice: default assistant", AIAssistantPreferences.backend(project: a).rawValue, "claude")
check("no choice: default model", AIAssistantPreferences.model(for: .claude, project: a), "opus")
check("no choice: default X-Ray model", AIAssistantPreferences.xrayModel(for: .claude, project: a), "sonnet")
check("no project: defaults", AIAssistantPreferences.backend(project: nil).rawValue, "claude")

// Alpha chooses its own; beta keeps the defaults.
AssistantChoice(project: a).setTool("codex")
AssistantChoice(project: a).setModel("gpt-6-sol", for: .codex)
AssistantChoice(project: a).setXRayModel("gpt-5.6-luna", for: .codex)
check("alpha: own assistant", AIAssistantPreferences.backend(project: a).rawValue, "codex")
check("alpha: own model", AIAssistantPreferences.model(for: .codex, project: a), "gpt-6-sol")
check("alpha: own X-Ray model", AIAssistantPreferences.xrayModel(for: .codex, project: a), "gpt-5.6-luna")
check("beta untouched: assistant", AIAssistantPreferences.backend(project: b).rawValue, "claude")
check("beta untouched: model", AIAssistantPreferences.model(for: .claude, project: b), "opus")
check("defaults untouched", UserDefaults.standard.string(forKey: AIAssistantPreferences.backendKey), "claude")

// Same project under another spelling of its path.
check("trailing slash is the same project",
      AIAssistantPreferences.backend(project: URL(fileURLWithPath: a.path + "/")).rawValue, "codex")

// A request carries its project's assistant and models.
let request = CLICompletion.Request(project: a, prompt: "x")
check("request: project's assistant", request.tool.rawValue, "codex")
check("request: project's X-Ray model", request.xrayModel, "gpt-5.6-luna")
check("request without project: defaults", CLICompletion.Request(project: nil, prompt: "x").tool.rawValue, "claude")
var forced = CLICompletion.Request(project: a, prompt: "x")
forced.tool = .claude
check("explicit tool wins", forced.tool.rawValue, "claude")

// "" model = the CLI default; "" X-Ray model = the assistant's model.
AssistantChoice(project: b).setModel("", for: .claude)
check("empty model: CLI default", AIAssistantPreferences.model(for: .claude, project: b), nil)
AssistantChoice(project: b).setModel("fable", for: .claude)
AssistantChoice(project: b).setXRayModel("", for: .claude)
check("empty X-Ray model: assistant's model", AIAssistantPreferences.xrayModel(for: .claude, project: b), "fable")
check("alpha still its own", AIAssistantPreferences.backend(project: a).rawValue, "codex")

// A window without a project edits the defaults.
AssistantChoice(project: nil).setTool("codex")
check("no project writes defaults", UserDefaults.standard.string(forKey: AIAssistantPreferences.backendKey), "codex")
check("beta follows the new default", AIAssistantPreferences.backend(project: b).rawValue, "codex")

print(failures == 0 ? "All project AI choice checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
