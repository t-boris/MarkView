import Foundation

// BUG-109: the line diff behind the review of observed file changes. Run through tools/tests/text-diff-tests.sh, which compiles the
// shipping TextDiff.swift with this file.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

/// Applying a diff to the old text must give the new text: the hunks lose nothing and invent nothing.
func replay(_ old: [String], _ hunks: [DiffHunk]) -> [String] {
    var result: [String] = []
    var cursor = 0   // next old line (0-based) not yet copied
    for hunk in hunks {
        let firstOld = hunk.lines.compactMap(\.oldNumber).min().map { $0 - 1 } ?? cursor
        // For a hunk made only of added lines the first old line is a context one after it, or the end.
        if firstOld > cursor { result += old[cursor..<firstOld] }
        cursor = max(cursor, firstOld)
        for line in hunk.lines {
            switch line.kind {
            case .context: result.append(line.text); cursor = (line.oldNumber ?? cursor + 1)
            case .added: result.append(line.text)
            case .removed: cursor = (line.oldNumber ?? cursor)
            }
        }
    }
    if cursor < old.count { result += old[cursor...] }
    return result
}

func numbered(_ n: Int, _ prefix: String = "line") -> String { (1...n).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n" }

// MARK: Basics
check(TextDiff.hunks(old: "a\nb\n", new: "a\nb\n").isEmpty, "equal texts have no hunks")
check(TextDiff.hunks(old: nil, new: nil).isEmpty && TextDiff.hunks(old: "", new: "").isEmpty, "nothing against nothing has no hunks")

var hunks = TextDiff.hunks(old: nil, new: "one\ntwo\nthree\n")
check(hunks.count == 1 && hunks[0].added == 3 && hunks[0].removed == 0, "a new file is one hunk of added lines", "\(hunks.map { ($0.added, $0.removed) })")
check(hunks.first?.location == "lines 1–3" && hunks.first?.summary == "Adds 3 lines", "...located at lines 1–3 and summarised", "\(hunks.first?.location ?? "") / \(hunks.first?.summary ?? "")")

hunks = TextDiff.hunks(old: "one\ntwo\n", new: nil)
check(hunks.count == 1 && hunks[0].removed == 2 && hunks[0].added == 0, "a deleted file is one hunk of removed lines")
check(hunks.first?.location == "removed from old lines 1–2" && hunks.first?.summary == "Removes 2 lines", "...located by its old lines", hunks.first?.location ?? "")

// MARK: A change in the middle of a file, with context and numbers
let old = numbered(20)
var edited = old.components(separatedBy: "\n")
edited[9] = "line 10 CHANGED"
hunks = TextDiff.hunks(old: old, new: edited.joined(separator: "\n"))
check(hunks.count == 1, "one edit is one hunk", "\(hunks.count)")
if let hunk = hunks.first {
    check(hunk.added == 1 && hunk.removed == 1, "a replaced line is one added and one removed line")
    check(hunk.lines.count == 3 + 2 + 3, "it has three lines of context on each side (8 lines)", "\(hunk.lines.count)")
    check(hunk.location == "line 10 (was line 10)", "it says where the change is, new and old", hunk.location)
    check(hunk.summary == "Replaces 1 line with 1", "it says what happened", hunk.summary)
    let removed = hunk.lines.first { $0.kind == .removed }, added = hunk.lines.first { $0.kind == .added }
    check(removed?.oldNumber == 10 && removed?.newNumber == nil && removed?.text == "line 10", "the removed line has its old number and text")
    check(added?.newNumber == 10 && added?.oldNumber == nil && added?.text == "line 10 CHANGED", "the added line has its new number and text")
    check(hunk.lines.first?.oldNumber == 7 && hunk.lines.last?.oldNumber == 13, "context runs from line 7 to line 13", "\(hunk.lines.first?.oldNumber ?? 0)…\(hunk.lines.last?.oldNumber ?? 0)")
}

// MARK: Line numbers shift after an insertion
var inserted = old.components(separatedBy: "\n")
inserted.insert(contentsOf: ["new a", "new b"], at: 4)
hunks = TextDiff.hunks(old: old, new: inserted.joined(separator: "\n"))
check(hunks.count == 1 && hunks[0].added == 2 && hunks[0].removed == 0, "an insertion is one hunk of added lines")
check(hunks.first?.location == "lines 5–6" && hunks.first?.summary == "Adds 2 lines", "its location is in the new text", hunks.first?.location ?? "")
let after = hunks.first?.lines.last
check(after?.newNumber == 9 && after?.oldNumber == 7, "the context after it is numbered in both texts (old 7 is new 9)", "\(after?.oldNumber ?? 0)/\(after?.newNumber ?? 0)")

// MARK: Far apart edits are separate hunks, near ones share one
var far = old.components(separatedBy: "\n")
far[1] = "early"; far[18] = "late"
hunks = TextDiff.hunks(old: old, new: far.joined(separator: "\n"))
check(hunks.count == 2, "edits 17 lines apart are two hunks", "\(hunks.count)")
var near = old.components(separatedBy: "\n")
near[5] = "a"; near[9] = "b"
check(TextDiff.hunks(old: old, new: near.joined(separator: "\n")).count == 1, "edits 4 lines apart share one hunk")

// MARK: A pure removal says where
var removedMiddle = old.components(separatedBy: "\n")
removedMiddle.removeSubrange(9..<12)
hunks = TextDiff.hunks(old: old, new: removedMiddle.joined(separator: "\n"))
check(hunks.count == 1 && hunks[0].removed == 3 && hunks[0].added == 0, "removing three lines is one hunk")
check(hunks.first?.location == "removed from old lines 10–12, after line 9" && hunks.first?.summary == "Removes 3 lines", "it says which old lines went", hunks.first?.location ?? "")

// MARK: Replaying every diff gives the new text back (the diff loses nothing and invents nothing)
var seed: UInt64 = 12345
func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
var replayFailures = 0
for round in 0..<300 {
    let a = (0..<(random(40))).map { _ in "w\(random(6))" }
    var b = a
    for _ in 0..<random(8) {
        switch random(3) {
        case 0 where !b.isEmpty: b.remove(at: random(b.count))
        case 1: b.insert("w\(random(9))", at: random(b.count + 1))
        default: if !b.isEmpty { b[random(b.count)] = "x\(random(9))" }
        }
    }
    let oldText = a.isEmpty ? nil : a.joined(separator: "\n") + "\n", newText = b.isEmpty ? nil : b.joined(separator: "\n") + "\n"
    let result = TextDiff.hunks(old: oldText, new: newText)
    if replay(a, result) != b { replayFailures += 1; if replayFailures == 1 { print("first failing round \(round): \(a) -> \(b)") } }
}
check(replayFailures == 0, "300 random edits: every diff replays to the new text", "\(replayFailures) failed")

// MARK: Many edits and a rewrite stay quick and complete
let big = (1...6000).map { "row \($0)" }
var bigEdited = big
for i in stride(from: 100, to: 6000, by: 250) { bigEdited[i] = "changed \(i)" }
var started = Date()
hunks = TextDiff.hunks(old: big.joined(separator: "\n"), new: bigEdited.joined(separator: "\n"))
check(hunks.count == 24 && Date().timeIntervalSince(started) < 2, "24 edits in 6000 lines: 24 hunks, quickly", "\(hunks.count) hunks, \(Date().timeIntervalSince(started))s")
started = Date()
let rewritten = (1...6000).map { "other \($0)" }
hunks = TextDiff.hunks(old: big.joined(separator: "\n"), new: rewritten.joined(separator: "\n"))
check(hunks.count == 1 && hunks[0].removed == 6000 && hunks[0].added == 6000 && Date().timeIntervalSince(started) < 3,
      "a full rewrite is one hunk of everything replaced, without a long search", "\(hunks.count) hunks, \(Date().timeIntervalSince(started))s")

// MARK: CRLF and a missing final newline
check(TextDiff.hunks(old: "a\r\nb\r\n", new: "a\r\nb\r\n").isEmpty, "the same CRLF text has no hunks")
hunks = TextDiff.hunks(old: "a\nb", new: "a\nb\nc")
check(hunks.count == 1 && hunks[0].added == 1 && hunks[0].lines.last?.text == "c", "a line added after one with no final newline")
check(TextDiff.lines(of: "a\r\nb\r\n") == ["a", "b"], "CRLF line ends are not part of the lines")

// MARK: The section a change sits in
let swift = """
import Foundation

final class Model {
    var a = 1

    func startNew() {
        original = nil
        selected = nil
        id = ""
    }

    private func save() {
        let editing = original
    }
}
"""
var changed = swift.replacingOccurrences(of: "selected = nil", with: "selected = 0")
hunks = TextDiff.hunks(old: swift, new: changed)
check(hunks.first?.section == "func startNew()", "a change inside a method names the method", hunks.first?.section ?? "nil")
changed = swift.replacingOccurrences(of: "let editing = original", with: "let editing = copy")
hunks = TextDiff.hunks(old: swift, new: changed)
check(hunks.first?.section == "func save()", "modifiers are dropped from the section (private func save())", hunks.first?.section ?? "nil")
changed = swift.replacingOccurrences(of: "var a = 1", with: "var a = 2")
check(TextDiff.hunks(old: swift, new: changed).first?.section == "class Model", "a property names its type (final dropped)", TextDiff.hunks(old: swift, new: changed).first?.section ?? "nil")
let markdown = "# Guide\n\ntext\n\n## Install\n\nrun it\n"
hunks = TextDiff.hunks(old: markdown, new: markdown.replacingOccurrences(of: "run it", with: "run it twice"))
check(hunks.first?.section == "## Install", "a change in a document names its heading", hunks.first?.section ?? "nil")
check(TextDiff.hunks(old: "a\nb\n", new: "a\nc\n").first?.section == nil, "text without declarations has no section")
hunks = TextDiff.hunks(old: "#comment\nx\n", new: "#comment\ny\n")
check(hunks.first?.section == nil, "'#comment' without a space is not a heading", hunks.first?.section ?? "nil")

// MARK: The request for the assistant's explanation and the reading of its answer
let sample = TextDiff.hunks(old: old, new: edited.joined(separator: "\n"))
let asked = ChangeExplainer.prompt(path: "Sources/Model.swift", kind: "modified", hunks: sample)
check(asked.included == 1 && asked.text.contains("File: Sources/Model.swift") && asked.text.contains("=== Change 1: line 10 (was line 10) ==="),
      "the prompt names the file and numbers each change with its location", asked.text)
check(asked.text.contains("10 old - line 10\n") && asked.text.contains("10 + line 10 CHANGED\n") && asked.text.contains("9   line 9\n"),
      "it shows the removed line with its old number, the added line and the context with new numbers", asked.text)
let manyHunks = (0..<40).map { i in DiffHunk(id: i, lines: [DiffLine(id: 0, kind: .added, oldNumber: nil, newNumber: i + 1, text: String(repeating: "x", count: 4000))], section: nil) }
let capped = ChangeExplainer.prompt(path: "big.txt", kind: "modified", hunks: manyHunks)
check(capped.included > 1 && capped.included < 40 && capped.text.count < ChangeExplainer.characterBudget + 5000 && capped.text.contains("not shown"),
      "a very large diff is cut at the budget and says how many changes were left out", "included \(capped.included), \(capped.text.count) characters")
let reading = ChangeExplainer.parse(["summary": " Renames it. ", "changes": [
    ["change": 1, "what": "Renames the field", "why": "Probably clarity", "impact": "Callers must follow"],
    ["change": 7, "what": "Out of range", "why": "", "impact": ""],
    ["change": 2, "what": "  ", "why": "", "impact": ""],
]], hunkCount: 2)
check(reading?.summary == "Renames it." && reading?.hunks.count == 1 && reading?.hunks[0]?.impact == "Callers must follow",
      "the answer's changes are read by number (from 1) onto the hunks (from 0); an empty or out-of-range one is dropped", "\(String(describing: reading))")
check(ChangeExplainer.parse(["summary": "x", "changes": []], hunkCount: 3) == nil && ChangeExplainer.parse([:], hunkCount: 1) == nil,
      "an answer that explains nothing is no explanation")
check(ChangeExplainer.systemPrompt(language: "Russian").contains("Russian") && ChangeExplainer.systemPrompt(language: ActionOutputLanguage.documentLanguage).contains("language"),
      "the explanation is asked for in the chosen language")

print(failures == 0 ? "All text diff checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
