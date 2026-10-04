import Foundation

// Checks the Finder-like selection (MarkView/Models/ListSelection.swift) and renaming in place
// (FileTransfer.rename). Compiled by tools/tests/list-selection-tests.sh.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let order = ["a", "b", "c", "d", "e"]
var selection = ListSelection<String>()
selection.click("b", .plain, in: order)
check(selection.ordered(order) == ["b"], "a click selects one")
selection.click("d", .toggle, in: order)
check(selection.ordered(order) == ["b", "d"], "⌘-click adds")
selection.click("b", .toggle, in: order)
check(selection.ordered(order) == ["d"], "⌘-click removes")
selection.click("a", .range, in: order)
check(selection.ordered(order) == ["a", "b"], "⇧-click selects from the anchor (the last ⌘-click, b) to here")
selection.click("e", .range, in: order)
check(selection.ordered(order) == ["b", "c", "d", "e"], "a second ⇧-click keeps the anchor")
selection.click("c", .plain, in: order)
check(selection.ordered(order) == ["c"], "a plain click starts over")
selection.keep(only: ["a", "b"])
check(selection.isEmpty && selection.anchor == nil, "items no longer listed are forgotten")
selection.click("zz", .range, in: order)
check(selection.ordered(order + ["zz"]) == ["zz"], "⇧-click without an anchor selects one")

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("notes.md")
try! "x".write(to: file, atomically: true, encoding: .utf8)
try! "y".write(to: folder.appendingPathComponent("taken.md"), atomically: true, encoding: .utf8)

var result = FileTransfer.rename(file, to: "taken.md")
check(!result.errors.isEmpty && FileManager.default.fileExists(atPath: file.path), "a taken name is refused")
result = FileTransfer.rename(file, to: "a/b.md")
check(!result.errors.isEmpty, "a name with a slash is refused")
result = FileTransfer.rename(file, to: " Plan.md ")
let renamed = folder.appendingPathComponent("Plan.md")
check(result.errors.isEmpty && FileManager.default.fileExists(atPath: renamed.path) && result.moved.count == 1, "renamed, name trimmed")
result = FileTransfer.rename(renamed, to: "plan.md")
let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
check(result.errors.isEmpty && names.contains("plan.md") && !names.contains("Plan.md"), "a change of case alone is renamed")

print(failures == 0 ? "All selection checks passed." : "\(failures) selection check(s) failed.")
exit(failures == 0 ? 0 : 1)
