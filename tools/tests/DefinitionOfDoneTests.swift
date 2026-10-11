import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let standard = DefinitionOfDone.standard
check("standard has the built-in items", standard.items.count == DefinitionOfDone.builtIn.count && standard.items.count >= 10)
check("ids are unique", Set(standard.items.map(\.id)).count == standard.items.count)
let text = standard.goalText()
check("goal text is one line", !text.contains("\n"))
check("required items are numbered", text.contains("(1) ") && text.contains("(2) "))
check("branch from origin/main is required", text.contains("origin/main"))
check("CI green is required", text.contains("CI checks"))
check("issues are in step", text.contains("GitHub issues"))
check("merge is asked, not required", text.contains("Ask me before you do any of these") && text.contains("Merge the pull request once"))
check("skipped items are named as not part of the goal", text.contains("Not part of this goal") && text.contains("Build and deploy"))
check("skipped wording is not given as an instruction", !text.contains("deploy it the way this project does"))
check("a checklist with evidence is asked for at the end", text.contains("checklist") && text.contains("evidence"))

// Switching items.
var custom = standard
for i in custom.items.indices where custom.items[i].id == "deploy" { custom.items[i].mode = .require }
for i in custom.items.indices where custom.items[i].id == "ci" { custom.items[i].mode = .skip }
let t2 = custom.goalText()
check("deploy now required", t2.contains("deploy it the way this project does"))
check("ci skipped", !t2.contains("Wait for the pull request's CI checks") && t2.contains("CI is green"))

// Custom items and empty ones.
var withCustom = standard
withCustom.items.append(DoneItem(id: "x1", title: "Changelog", instruction: "Add an entry to CHANGELOG.md", mode: .require, custom: true))
withCustom.items.append(DoneItem(id: "x2", title: "Empty", instruction: "   ", mode: .require, custom: true))
withCustom.items.append(DoneItem(id: "x3", title: "Skipped custom", instruction: "Do something odd", mode: .skip, custom: true))
let t3 = withCustom.goalText()
check("custom required item is added with a full stop", t3.contains("Add an entry to CHANGELOG.md."))
check("empty custom item is ignored", !t3.contains("Empty"))
check("skipped custom item is dropped silently", !t3.contains("Do something odd") && !t3.contains("Skipped custom"))
check("nothing set gives no text", DefinitionOfDone(items: []).goalText().isEmpty)
check("all skipped gives only the not-part list", {
    var d = standard
    for i in d.items.indices { d.items[i].mode = .skip }
    let g = d.goalText()
    return g.hasPrefix("Not part of this goal") && !g.contains("Definition of done")
}())

// Storage in a throwaway folder.
let root = FileManager.default.temporaryDirectory.appendingPathComponent("dod-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
check("no file: standard", DefinitionOfDone.load(root: root) == .standard)
check("no project: standard", DefinitionOfDone.load(root: nil) == .standard)
do { try withCustom.save(root: root) } catch { check("save: \(error)", false) }
let loaded = DefinitionOfDone.load(root: root)
check("round trip keeps the custom item", loaded.items.contains { $0.id == "x1" && $0.custom && $0.mode == .require })
check("round trip keeps a changed mode", loaded.items.first { $0.id == "merge" }?.mode == .ask)
check("file is where the app looks", FileManager.default.fileExists(atPath: root.appendingPathComponent(".dde/definition-of-done.json").path))

// An older file lacks a newer built-in item and has outdated wording.
let old = DefinitionOfDone(items: [DoneItem(id: "branch", title: "old title", instruction: "old words", mode: .skip),
                                   DoneItem(id: "gone", title: "Removed built-in", instruction: "x", mode: .require)])
let merged = DefinitionOfDone.merged(old)
check("old file: the choice is kept", merged.items.first { $0.id == "branch" }?.mode == .skip)
check("old file: wording follows the app", merged.items.first { $0.id == "branch" }?.instruction.contains("origin/main") == true)
check("old file: new built-ins appear", merged.items.count == DefinitionOfDone.builtIn.count)
check("old file: a removed built-in does not linger", !merged.items.contains { $0.id == "gone" })
try? Data("not json".utf8).write(to: root.appendingPathComponent(".dde/definition-of-done.json"))
check("a broken file falls back to standard", DefinitionOfDone.load(root: root) == .standard)

// The prompt.
let prompt = HandoffPrompt.feature("docs/features/x", backend: .claude, done: standard)
check("prompt keeps the objective and adds the checklist", prompt.hasPrefix("/goal Implement what docs/features/x") && prompt.contains("Definition of done"))
check("prompt stays on one line", !prompt.contains("\n"))
check("prompt without a checklist is unchanged", HandoffPrompt.feature("docs/features/x", backend: .claude) == HandoffPrompt.feature("docs/features/x", backend: .claude, done: DefinitionOfDone(items: [])))

exit(failures == 0 ? 0 : 1)
