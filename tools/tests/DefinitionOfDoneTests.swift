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

// The file is a schema-versioned store (AR-36): a saved checklist is in an envelope; a file written before it still loads; a file
// that cannot be read is never replaced without a backup; a newer file is never replaced.
let dod = root.appendingPathComponent(".dde/definition-of-done.json")
let legacyFixture = """
{
  "items" : [
    { "custom" : false, "id" : "branch", "instruction" : "old words", "mode" : "skip", "title" : "old title" },
    { "custom" : false, "id" : "merge", "instruction" : "old merge words", "mode" : "ask", "title" : "Merge" },
    { "custom" : true, "id" : "x9", "instruction" : "Add an entry to CHANGELOG.md", "mode" : "require", "title" : "Changelog" }
  ]
}
"""
StoreFixture.write(legacyFixture, to: dod)
let upgraded = DefinitionOfDone.load(root: root)
check("legacy file: the person's choices and custom item survive the upgrade",
      upgraded.items.first { $0.id == "branch" }?.mode == .skip && upgraded.items.first { $0.id == "merge" }?.mode == .ask
      && upgraded.items.contains { $0.id == "x9" && $0.custom && $0.mode == .require })
check("legacy file: it is left as written until a save", StoreFixture.envelope(dod) == nil)
try upgraded.save(root: root)
check("legacy file: the next save writes the envelope", StoreFixture.envelope(dod)?.schema == 1)
check("legacy file: the envelope reloads to the same checklist", DefinitionOfDone.load(root: root) == upgraded)
check("legacy file: nothing was damaged, so no backup", StoreFixture.backups(of: dod).isEmpty)

let damaged = "{ \"items\": [ truncated"
StoreFixture.write(damaged, to: dod)
check("damaged file: the standard checklist is used in memory", DefinitionOfDone.load(root: root) == .standard)
check("damaged file: loading does not touch it", StoreFixture.bytes(dod) == Data(damaged.utf8) && StoreFixture.backups(of: dod).isEmpty)
try withCustom.save(root: root)
check("damaged file: a save keeps the old bytes in a dated backup",
      StoreFixture.backups(of: dod).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: dod)[0]) == Data(damaged.utf8))
check("damaged file: and writes the new checklist", DefinitionOfDone.load(root: root).items.contains { $0.id == "x1" })

let newer = StoreFixture.newerFile(payload: #"{"items":[],"somethingNew":true}"#)
StoreFixture.write(newer, to: dod)
check("newer file: it is not used", DefinitionOfDone.loadIfPresent(root: root) == nil)
var refused = false
do { try withCustom.save(root: root) } catch SchemaStoreError.newerSchemaVersion { refused = true } catch {}
check("newer file: a save is refused and the file stays as it is", refused && StoreFixture.bytes(dod) == Data(newer.utf8))
check("newer file: the policy readers see a declared checklist with no item set", DefinitionOfDone.policyData(root: root) == Data("{}".utf8))

// The prompt.
let prompt = HandoffPrompt.feature("docs/features/x", backend: .claude, done: standard)
check("prompt keeps the objective and adds the checklist", prompt.hasPrefix("/goal Implement what docs/features/x") && prompt.contains("Definition of done"))
check("prompt stays on one line", !prompt.contains("\n"))
check("prompt without a checklist is unchanged", HandoffPrompt.feature("docs/features/x", backend: .claude) == HandoffPrompt.feature("docs/features/x", backend: .claude, done: DefinitionOfDone(items: [])))

exit(failures == 0 ? 0 : 1)
