import Foundation

// Feature workflow-templates, REQ-001..003: a template is the whole workflow in a file of a shared folder; it is read back as it was
// saved, applied to another project as a whole, and a file that cannot be used is named and left alone.
// Run through tools/tests/workflow-template-tests.sh.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

let fileManager = FileManager.default
let temp = fileManager.temporaryDirectory.appendingPathComponent("mv-template-checks-\(UUID().uuidString)", isDirectory: true)
defer { try? fileManager.removeItem(at: temp) }
let folder = temp.appendingPathComponent("WorkflowTemplates", isDirectory: true)
let store = WorkflowTemplateStore(folder: folder)
let moment = Date(timeIntervalSince1970: 1_800_000_000)

/// Boris's setup: Kanban with the pull request, the checks and the release switched on for both types.
func configured() -> ProjectWorkflow {
    var workflow = WorkflowFlow.kanban.applied(to: .standard)
    workflow.revision = 7
    for index in workflow.variants.indices {
        workflow.variants[index].integration = .pullRequest
        workflow.variants[index].checks = true
        workflow.variants[index].delivery = .githubRelease
    }
    return workflow
}

// MARK: Ids

check(WorkflowTemplateStore.slug("My Kanban (no CI)") == "my-kanban-no-ci", "a name becomes a file-name id")
check(WorkflowTemplateStore.slug("  ../../etc/passwd ") == "etc-passwd", "a name with path characters cannot make an id that leaves the folder")
check(WorkflowTemplateStore.slug("Мой процесс") == "template", "a name with no ASCII letters falls back to 'template'")
check(WorkflowTemplateStore.isValid(id: "kanban-2") && !WorkflowTemplateStore.isValid(id: "../x") && !WorkflowTemplateStore.isValid(id: "A")
      && !WorkflowTemplateStore.isValid(id: "") && !WorkflowTemplateStore.isValid(id: "default"), "only lower-case words with hyphens are ids; 'default' is reserved for the pointer")

// MARK: Empty folder

let empty = store.list()
check(empty.templates.isEmpty && empty.unusable.isEmpty && empty.defaultID == nil && empty.defaultTemplate == nil, "a folder that does not exist is an empty library")

// MARK: Save and read back (REQ-001)

let source = configured()
let saved = try! store.save(name: "Kanban with GitHub", note: "PR, CI and release on", workflow: source, now: moment)
check(saved.id == "kanban-with-github" && saved.name == "Kanban with GitHub", "saving gives the template its own id")
check(fileManager.fileExists(atPath: folder.appendingPathComponent("kanban-with-github.json").path), "one JSON file per template in the folder")
let listed = store.list()
check(listed.templates.count == 1 && listed.templates[0] == saved, "the template is read back exactly as it was saved")
check(listed.templates[0].workflow.feature == source.feature && listed.templates[0].workflow.bug == source.bug
      && listed.templates[0].workflow.variants == source.variants && listed.templates[0].workflow.defaultBugVariant == source.defaultBugVariant,
      "it keeps the states, the transitions, every process with its delivery settings and the defaults")
check(saved.workflow.revision == 1 && saved.workflow.name == "Kanban with GitHub", "the stored workflow starts at revision 1 and carries the template's name")
check(saved.needsGitHub, "a template whose processes need a pull request, checks and a release says it needs GitHub")
check(!(try! store.save(name: "Plain", workflow: WorkflowFlow.kanban.applied(to: StandardWorkflow.make(bug: .init(pullRequestRequired: false, checksRequired: false, releaseRequired: false))))).needsGitHub,
      "a template whose processes require nothing does not")
check(try! store.list().templates.map(\.name) == ["Kanban with GitHub", "Plain"], "templates are listed by name")

// Same name, own file; replacing keeps the id
let second = try! store.save(name: "Kanban with GitHub", workflow: source, now: moment)
check(second.id == "kanban-with-github-2", "a name that is taken gets its own file and does not overwrite")
var changed = source
changed.name = "x"
changed.bug.statuses[0].title = "Renamed first state"
let replaced = try! store.save(name: "Kanban with GitHub", note: "again", workflow: changed, replacing: saved.id, now: moment.addingTimeInterval(60))
check(replaced.id == saved.id && store.list().templates.first { $0.id == saved.id }?.note == "again", "replacing writes over the same file and keeps the id")
check((try? store.save(name: "Gone", workflow: source, replacing: "nope")) == nil, "replacing a template that is not there is refused")

// Invalid input is refused
check((try? store.save(name: "   ", workflow: source)) == nil, "a template needs a name")
var broken = source
broken.feature.rules[0].to = "no-such-status"
do { _ = try store.save(name: "Broken", workflow: broken); check(false, "an invalid workflow cannot be saved as a template") }
catch let error as WorkflowTemplateError { check({ if case .invalid = error { return true } else { return false } }(), "an invalid workflow cannot be saved as a template", error.localizedDescription) }
catch { check(false, "an invalid workflow cannot be saved as a template", "\(error)") }
check(!store.list().templates.contains { $0.name == "Broken" }, "…and nothing was written for it")

// MARK: Apply (REQ-002)

var other = WorkflowFlow.linear.applied(to: .standard)
other.revision = 12
let applied = saved.applied(to: other)
check(applied.revision == 12, "applying keeps the revision of the project that takes it, so a save still notices a newer file")
check(applied.feature == saved.workflow.feature && applied.bug == saved.workflow.bug && applied.variants == saved.workflow.variants
      && applied.defaultFeatureVariant == saved.workflow.defaultFeatureVariant && applied.name == saved.name, "applying replaces the whole workflow: states, transitions, processes")
check(applied.validate().isEmpty, "the result passes the workflow validation")
check(saved.matches(applied) && !saved.matches(other), "the draft is recognised as this template until it is changed")
var edited = applied
edited.variants[0].checks.toggle()
check(!saved.matches(edited), "…and not after a process is edited")
// A template is a copy: editing the project it came from, or the one that took it, never changes the file.
var after = applied
after.feature.statuses[0].title = "Edited in the project that took it"
check(store.list().templates.first { $0.id == saved.id }?.workflow.feature.statuses[0].title != after.feature.statuses[0].title, "a template is a copy: editing a project that took it does not change the file")

// MARK: The default for new projects (REQ-003)

check(store.defaultTemplate() == nil, "nothing is chosen at first")
try! store.setDefault(saved.id)
check(store.defaultTemplate()?.id == saved.id && store.list().defaultID == saved.id, "a saved template can be chosen for new projects")
check(fileManager.fileExists(atPath: folder.appendingPathComponent("default.json").path) && store.list().templates.allSatisfy { $0.id != "default" },
      "the choice is a small default.json in the same folder and is never listed as a template")
check((try? store.setDefault("missing")) == nil && store.list().defaultID == saved.id, "choosing a template that is not there is refused and keeps the old choice")
try! store.setDefault(nil)
check(store.defaultTemplate() == nil && !fileManager.fileExists(atPath: folder.appendingPathComponent("default.json").path), "the built-in default can be chosen again")
try! store.setDefault(saved.id)
try! store.delete(saved.id)
check(store.defaultTemplate() == nil && store.list().defaultID == nil && !fileManager.fileExists(atPath: folder.appendingPathComponent("kanban-with-github.json").path),
      "deleting the chosen template removes the choice with it")
check((try? store.delete("../../x")) == nil, "a delete cannot reach outside the folder")

// MARK: Files that cannot be used are named and left alone (REQ-001)

let good = try! store.save(name: "Good", workflow: source, now: moment)
func write(_ name: String, _ text: String) { try! Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
write("not-json.json", "this is not json")
write("no-schema.json", "{\"id\": \"x\"}")
write("newer.json", "{\"schema\": 99, \"id\": \"newer\"}")
write("wrong-shape.json", "{\"schema\": 1, \"id\": \"wrong-shape\"}")
let valid = try! Data(contentsOf: folder.appendingPathComponent("good.json"))
var invalidObject = try! JSONSerialization.jsonObject(with: valid) as! [String: Any]
var workflowObject = invalidObject["workflow"] as! [String: Any]
var feature = workflowObject["feature"] as! [String: Any]
var rules = feature["rules"] as! [[String: Any]]
rules[0]["to"] = "no-such-status"
feature["rules"] = rules
workflowObject["feature"] = feature
invalidObject["workflow"] = workflowObject
try! JSONSerialization.data(withJSONObject: invalidObject).write(to: folder.appendingPathComponent("invalid-workflow.json"))
write("Bad Name.json", "{}")
write("notes.txt", "not a template")
let mixed = store.list()
check(mixed.templates.map(\.id).contains(good.id), "a good template is listed next to the bad files")
let reasons = Dictionary(uniqueKeysWithValues: mixed.unusable.map { ($0.file, $0.reason) })
check(Set(reasons.keys) == ["not-json.json", "no-schema.json", "newer.json", "wrong-shape.json", "invalid-workflow.json", "Bad Name.json"],
      "every file that cannot be used is listed, and nothing else", reasons.keys.sorted().joined(separator: ", "))
check(reasons["newer.json"]?.contains("newer") == true, "a template from a newer app says so")
check(reasons["invalid-workflow.json"]?.contains("invalid") == true, "an invalid workflow says what is wrong")
check(try! String(contentsOf: folder.appendingPathComponent("not-json.json")) == "this is not json", "an unusable file is left exactly as it was")
try! store.setDefault(good.id)
try! Data("{\"template\": \"not-json\"}".utf8).write(to: folder.appendingPathComponent("default.json"))
check(store.defaultTemplate() == nil && store.list().defaultID == "not-json", "a choice that names an unusable template gives no default (new projects use the built-in one)")
try! Data("garbage".utf8).write(to: folder.appendingPathComponent("default.json"))
check(store.defaultTemplate() == nil && store.list().defaultID == nil, "a damaged pointer file gives no default")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
