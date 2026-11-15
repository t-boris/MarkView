import Foundation

// Reading a unified diff (ChangeDiff): the diff text is what git itself prints for a real temporary repository (a changed file, a
// deleted one, a new one), so the parsing is checked against the real format and nothing is mocked. No window, no assistant.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

func git(_ arguments: [String], in directory: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

let fm = FileManager.default
let repo = fm.temporaryDirectory.appendingPathComponent("change-diff-tests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: repo) }
func write(_ text: String, _ name: String) { try? text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }

_ = git(["init", "-q", "-b", "main", "."], in: repo)
_ = git(["config", "user.email", "t@t.test"], in: repo)
_ = git(["config", "user.name", "t"], in: repo)
write((1...10).map { "l\($0)" }.joined(separator: "\n") + "\n", "a.txt")
write("keep\n", "b.txt")
write("gone1\ngone2\n", "c.txt")
_ = git(["add", "-A"], in: repo)
_ = git(["commit", "-q", "-m", "init"], in: repo)
// a.txt: line 3 rewritten, two lines added after l7, l9 removed. c.txt is deleted, d.txt is new, b.txt is untouched.
let changed = "l1\nl2\nL3 changed\nl4\nl5\nl6\nl7\nnew-a\nnew-b\nl8\nl10\n"
write(changed, "a.txt")
try? fm.removeItem(at: repo.appendingPathComponent("c.txt"))
write("n1\nn2\nn3\n", "d.txt")
_ = git(["add", "-A"], in: repo)
let diff = git(["diff", "--cached", "--no-color", "-U3", "HEAD"], in: repo)
check(diff.hasPrefix("diff --git a/a.txt b/a.txt"), "the fixture is a real git diff of three files")

print("\n-- files")
let files = ChangeDiff.files(diff)
check(files.map(\.path) == ["a.txt", "c.txt", "d.txt"], "a changed, a deleted and a new file are listed, the untouched one is not")
check(files[0].additions == 3 && files[0].deletions == 2, "a changed file counts its added and removed lines")
check(files[0].ranges == [[3, 3], [8, 9], [11, 11]], "the touched new-file ranges are the rewrite, the two new lines, and the place the removed line was (\(files[0].ranges))")
check(files[1].deleted == true && files[1].deletions == 2 && files[1].additions == 0 && files[1].ranges.isEmpty, "a deleted file is kept, flagged, with no new-file ranges")
check(files[2].additions == 3 && files[2].deletions == 0 && files[2].ranges == [[1, 3]] && files[2].deleted != true, "a new file is all added lines")

print("\n-- one file's part of the diff")
let parts = ChangeDiff.split(diff)
check(Set(parts.keys) == ["a.txt", "c.txt", "d.txt"], "each file gets its own part, a deleted one under its old path")
check(parts["c.txt"]?.contains("-gone1") == true && parts["c.txt"]?.contains("a.txt") != true, "a part holds only its own lines")
check(parts["a.txt"]?.hasPrefix("@@ -1,10 +1,11 @@") == true, "the git header lines are dropped, the hunk is kept")
let text = ChangeDiff.lines(diff)
check(text["a.txt"]?.added == "L3 changed\nnew-a\nnew-b\n" && text["a.txt"]?.removed == "l3\nl9\n", "added and removed lines of a file are returned as text")
check(text["d.txt"]?.added == "n1\nn2\nn3\n" && text["c.txt"] == nil, "a new file is all added, and a file with no new side has no entry")
check(ChangeDiff.changedRanges(parts["a.txt"] ?? "") == [[3, 3], [8, 9], [11, 11]], "changed ranges of one file's part agree with the file listing")

print("\n-- lines of the file as it is now")
let inSync = ChangeDiff.lineMap(diff: parts["a.txt"] ?? "", current: changed)
check(inSync.inSync && inSync.line(8) == 8 && inSync.exists(8), "a file equal to the change's version maps every line to itself")
let shifted = ChangeDiff.lineMap(diff: parts["a.txt"] ?? "", current: "x\ny\n" + changed)
check(!shifted.inSync && shifted.line(3) == 5 && shifted.line(8) == 10 && shifted.exists(3), "two lines added above shift the change's lines by two")
let edited = ChangeDiff.lineMap(diff: parts["a.txt"] ?? "", current: changed.replacingOccurrences(of: "L3 changed", with: "L3 edited later"))
check(!edited.inSync && !edited.exists(3) && edited.exists(4) && edited.line(4) == 4, "a line edited after the change has no match, its neighbours do")

print("\n-- the diff as the assistant reads it")
let numbered = ChangeDiff.numbered(parts["a.txt"] ?? "")
check(numbered.contains("3 + L3 changed") && numbered.contains("     - l3") && numbered.contains("4   l4"),
      "added lines carry their new-file line number, removed ones none, context both")
check(ChangeDiff.numbered(parts["a.txt"] ?? "", maxLines: 3).hasSuffix("… (diff clipped)"), "a long diff is clipped")

print("\n-- where in a file's contents the change falls")
let markdown = "# Intro\n\nsome text\n\n## Setup\n\nmore text\n\n## Usage\n\nlast words\n"
let outline = XRayContent.localOutline(text: markdown, language: "markdown", signature: "s")
let spans = ChangeDiff.itemSpans(outline)
check(spans.map(\.name) == ["Intro", "Setup", "Usage"] && spans.map(\.start) == [1, 5, 9] && spans.map(\.end) == [4, 8, Int.max],
      "each heading covers its lines up to the next heading (\(spans.map { "\($0.name) \($0.start)-\($0.end)" }))")
check(ChangeDiff.part(at: 6, in: spans) == spans[1].part && ChangeDiff.part(at: 0, in: spans) == nil, "a line belongs to the part of the last item before it")
let notes = ChangeDiff.changeNotes(hunks: [[6, 7], [10, 10], [2, 2]], spans: spans)
check(notes.map(\.title) == ["Setup", "Usage", "Intro"] && notes[0].start == 6 && notes[0].end == 7, "a changed range is placed in the item it touches")
let outside = ChangeDiff.changeNotes(hunks: [[3, 5]], spans: [])
check(outside.count == 1 && outside[0].title == "Lines 3–5" && outside[0].part == nil, "with no items the change is named by its lines")
let straddling = ChangeDiff.changeNotes(hunks: [[3, 6]], spans: spans)
check(straddling.map(\.title) == ["Intro", "Setup"] && straddling[0].end == 4 && straddling[1].start == 5, "a range across two items becomes one note for each, cut at the boundary")

print("\n-- what the code viewer shows of a file's change")
var overlay = PROverlay(source: PRSource(id: "local", title: "feature: all changes"), files: files, reviewed: false, dependencies: [])
for i in overlay.files.indices {
    overlay.files[i].changes = ChangeDiff.changeNotes(hunks: ChangeDiff.changedRanges(parts[overlay.files[i].path] ?? ""), spans: [])
}
let aFile = overlay.files[0]
let current = ChangeDiff.fileNotes(overlay: overlay, file: aFile, diff: parts["a.txt"] ?? "", content: changed, focus: true)
check(current.added == [[3, 3], [8, 9]] && current.removed == [[3, 1], [11, 1]] && !current.remapped && current.focus,
      "a file as the change left it shows its added lines and the two removal points (\(current.added) \(current.removed))")
check(current.additions == 3 && current.deletions == 2 && current.deletedLines == nil, "with the counts of the change")
check(current.changes.map(\.start) == [3, 8, 11] && current.changes[1].diff == ["+new-a", "+new-b"],
      "each change carries the diff lines that fall in it (\(current.changes.map(\.start)))")
let moved = ChangeDiff.fileNotes(overlay: overlay, file: aFile, diff: parts["a.txt"] ?? "", content: "x\ny\n" + changed, focus: false)
check(moved.remapped && moved.added == [[5, 5], [10, 11]] && moved.changes.map(\.start) == [5, 10, 13] && !moved.focus,
      "two lines added above move every line along and say the file moved on (\(moved.added) \(moved.changes.map(\.start)))")
let edited2 = ChangeDiff.fileNotes(overlay: overlay, file: aFile, diff: parts["a.txt"] ?? "",
                                   content: changed.replacingOccurrences(of: "L3 changed", with: "L3 edited later"), focus: false)
check(edited2.remapped && edited2.added == [[8, 9]], "an added line edited since is no longer marked as added")
let gone = ChangeDiff.fileNotes(overlay: overlay, file: overlay.files[1], diff: parts["c.txt"] ?? "", content: "gone1\ngone2\n", focus: false)
// The editor shows the text's last newline as one more (empty) line, so two lines of text are three editor lines.
check(gone.deletedLines == 3 && gone.added.isEmpty && gone.deletions == 2 && !gone.changes.isEmpty
      && gone.changes.allSatisfy { $0.start == 1 && $0.end == 3 && $0.kind == "removed" && $0.diff == ["-gone1", "-gone2"] },
      "a deleted file's changes cover its old text from the first editor line to the last")

print("\n-- the review as a task list")
check(overlay.tasksText() == nil, "a change nobody reviewed has no tasks")
var reviewed = overlay
reviewed.files[0].findings = [
    PRFinding(line: 3, severity: "bug", message: "Wrong line"),
    PRFinding(line: 0, severity: "warning", message: "Dismissed one", dismissed: true),
    PRFinding(line: 8, severity: "info", message: "Mind this"),
]
reviewed.files[2].verdict = "concern"
reviewed.files[2].summary = "Looks risky"
reviewed.analysis = PRAnalysis(summary: "s", verdict: "attention", impact: [], risks: ["Coupling"], checks: [.init(path: "d.txt", line: 2, note: "Check n2")])
let tasks = reviewed.tasksText() ?? ""
check(tasks.hasPrefix("Tasks from the review of feature: all changes."), "the list names the change")
check(tasks.contains("## Bugs\n- [ ] a.txt:3 — Wrong line") && tasks.contains("## Concerns\n- [ ] d.txt — Looks risky") && tasks.contains("## Notes\n- [ ] a.txt:8 — Mind this"),
      "findings go under their severity, a file without findings under its verdict")
check(!tasks.contains("Dismissed one") && tasks.contains("## To check\n- [ ] d.txt:2 — Check n2\n- [ ] Risk: Coupling"), "a dismissed finding is left out, the analysis's checks and risks are added")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
