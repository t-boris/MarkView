import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

private extension CLITool {
    static var claude: CLITool { CLITool(rawValue: "claude")! }
    static var codex: CLITool { CLITool(rawValue: "codex")! }
    static var antigravity: CLITool { CLITool(rawValue: "antigravity")! }
}

final class ProjectAIChoiceHostTests: XCTestCase {
    @MainActor func testProjectAssistantChoices() async throws {
        func check(_ name: String, _ got: String?, _ want: String?) { XCTAssertEqual(got, want, name) }
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost",
              let homePath = environment["MARKVIEW_AI_TEST_HOME"],
              environment["CFFIXED_USER_HOME"] == homePath else {
            XCTFail("An isolated test host and temporary home are required"); return
        }
        let fixedHome = URL(fileURLWithPath: homePath, isDirectory: true).resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard fixedHome.lastPathComponent == "home",
              fixedHome.deletingLastPathComponent().lastPathComponent.hasPrefix("mvaichoice."),
              fixedHome.path.hasPrefix(temporaryRoot.path + "/"),
              PreferenceRecord.defaultFolder.resolvingSymlinksInPath().path.hasPrefix(fixedHome.path + "/") else {
            XCTFail("Preference recovery must be confined to the temporary test home"); return
        }
        let defaults = UserDefaults.standard
        let domain = "com.markview.tests.apphost"
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("ai-\(UUID().uuidString)", isDirectory: true)
let a = base.appendingPathComponent("alpha", isDirectory: true)
let b = base.appendingPathComponent("beta", isDirectory: true)
try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }

// Defaults only.
Settings.standard.set("claude", for: Setting.aiBackend)
Settings.standard.set("opus", for: Setting.cliModel(CLITool.claude.rawValue))
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
check("defaults untouched", Settings.standard.stored(Setting.aiBackend), "claude")

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

// An operation tied to a window (End-to-End QA) uses the shown agent's tool, but the model chosen for that tool in the project:
// never the model a running tab reports. Alpha chose gpt-6-sol for Codex above; beta chose fable for Claude, and the default model (opus) must not leak into it.
check("window operation: the shown tool keeps the project's chosen model",
      CLICompletion.Assistant.chosen(tool: .codex, project: a).model, "gpt-6-sol")
check("window operation: another tool of the project uses its own choice, not Codex's",
      CLICompletion.Assistant.chosen(tool: .claude, project: a).model, "opus")
check("window operation: a project's own choice wins over the default model",
      CLICompletion.Assistant.chosen(tool: .claude, project: b).model, "fable")
check("window operation: without a shown agent the project's assistant and model answer",
      "\(CLICompletion.Assistant.project(a).tool.rawValue):\(CLICompletion.Assistant.project(a).model ?? "nil")", "codex:gpt-6-sol")
AssistantChoice(project: a).setModel("", for: .codex)
check("window operation: a project left on the CLI default stays on it",
      CLICompletion.Assistant.chosen(tool: .codex, project: a).model, nil)
AssistantChoice(project: a).setModel("gpt-6-sol", for: .codex)

// A window without a project edits the defaults.
AssistantChoice(project: nil).setTool("codex")
check("no project writes defaults", Settings.standard.stored(Setting.aiBackend), "codex")
check("beta follows the new default", AIAssistantPreferences.backend(project: b).rawValue, "codex")

// Manual only: the wrapper forwards this opt-in explicitly.
if ProcessInfo.processInfo.environment["MARKVIEW_LIVE_ANTIGRAVITY"] == "1", CLIToolLocator.resolve(.antigravity) != nil {
    check("antigravity binary name", CLITool.antigravity.binaryName, "agy")
    let schema: [String: Any] = ["type": "object", "properties": ["answer": ["type": "number"]], "required": ["answer"]]
    let request = CLICompletion.Request(project: nil, prompt: "What is 2+2? Answer with the number.", jsonSchema: schema, toolOverride: .antigravity)
    let result = try? await CLICompletion.run(request)
    let answer = ((result?.structured as? [String: Any])?["answer"] as? NSNumber)?.doubleValue
    check("antigravity structured answer", answer.map { String(Int($0)) }, "4")
}

// A record in the preferences that cannot be read is not "none" (AR-36): it reads as absent, a copy of its bytes is kept once, and the
// next save replaces the value without losing what was there. A record that can be read leaves no copy.
do {
    let garbage = Data("{ not a choice".utf8)
    let copiesFolder = PreferenceRecord.defaultFolder
    check("home is the temporary one", copiesFolder.path.hasPrefix(fixedHome.resolvingSymlinksInPath().path) || copiesFolder.path.hasPrefix(fixedHome.path) ? "yes" : copiesFolder.path, "yes")
    let c = base.appendingPathComponent("gamma", isDirectory: true)
    try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
    AssistantChoice(project: c).setTool("codex")
    check("a readable choice leaves no copy", String(PreferenceRecord.copies(named: "project-ai-choice").count), "0")

    var all = Settings.standard.value(Setting.projectAI)
    all[ProjectAIChoice.key(c)] = garbage
    Settings.standard.set(all, for: Setting.projectAI)
    check("an unreadable choice reads as none", ProjectAIChoice.load(c) == nil ? "none" : "choice", "none")
    _ = ProjectAIChoice.load(c)
    let kept = PreferenceRecord.copies(named: "project-ai-choice")
    check("a copy of it is kept, once", String(kept.count), "1")
    check("the copy holds its bytes", (kept.first.flatMap { try? Data(contentsOf: $0) }) == garbage ? "same" : "different", "same")
    check("the other projects' choices still read", AIAssistantPreferences.backend(project: a).rawValue, "codex")
    ProjectAIChoice.update(c) { $0.backend = "claude" }
    check("a save replaces the value", ProjectAIChoice.load(c)?.backend, "claude")
    check("and the copy is still there", (kept.first.flatMap { try? Data(contentsOf: $0) }) == garbage ? "same" : "gone", "same")
    check("no second copy for the readable value", String(PreferenceRecord.copies(named: "project-ai-choice").count), "1")

    let linked = [LinkedFolder(path: a.path, name: "alpha", added: Date(timeIntervalSince1970: 1_800_000_000))]
    LinkedFolders.save(linked, project: c)
    check("linked folders read back", String(LinkedFolders.load(project: c).count), "1")
    var folders = Settings.standard.value(Setting.linkedFolders)
    folders[LinkedFolders.key(c)] = garbage
    Settings.standard.set(folders, for: Setting.linkedFolders)
    check("an unreadable list of linked folders reads as empty", String(LinkedFolders.load(project: c).count), "0")
    check("a copy of it is kept", String(PreferenceRecord.copies(named: "linked-folders").count), "1")
    LinkedFolders.save(linked, project: c)
    check("a save replaces it", String(LinkedFolders.load(project: c).count), "1")
    check("the copy keeps the old bytes", (PreferenceRecord.copies(named: "linked-folders").first.flatMap { try? Data(contentsOf: $0) }) == garbage ? "same" : "gone", "same")
}

// Simultaneous project choices must not lose one another.
let pickProjects = (0..<100).map { fixedHome.appendingPathComponent("pick-\($0)") }
let pickDate = Date(timeIntervalSince1970: 2_524_608_000)
DispatchQueue.concurrentPerform(iterations: pickProjects.count) { index in
    ModelPickLog.record(tool: .codex, project: pickProjects[index], at: pickDate)
}
let picksIntact = pickProjects.allSatisfy { ModelPickLog.lastPick(tool: .codex, project: $0) == pickDate }
check("concurrent model picks remain independent", picksIntact ? "yes" : "no", "yes")

    }
}
