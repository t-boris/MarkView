// Checks the batch Fix with AI rules (MarkView/Models/BugBasket.swift) against REQ-001…REQ-006 and
// decisions DEC-001…DEC-013 of docs/features/batch-fix-with-ai-for-multiple-bugs.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func bug(_ key: String, _ status: String, path: String? = nil, feature: String = "") -> BasketBug {
    BasketBug(path: path ?? "docs/bugs/\(key).md", key: key, title: "Title of \(key)", status: status, feature: feature)
}

// MARK: Basket (REQ-001, DEC-008, DEC-010)

check("only open bugs can be added", BugBasket.canAdd(bug("B1", "open")) && BugBasket.canAdd(bug("B1", " Open "))
      && !BugBasket.canAdd(bug("B1", "fixing")) && !BugBasket.canAdd(bug("B1", "fixed")) && !BugBasket.canAdd(bug("B1", "closed")))
check("fixing is being fixed", BugBasket.isBeingFixed(bug("B1", "fixing")) && !BugBasket.isBeingFixed(bug("B1", "open")))

var basket = BugBasket()
basket.add("a"); basket.add("b"); basket.add("a")
check("add keeps order, no repeats", basket.paths == ["a", "b"])
basket.remove("a")
check("remove", basket.paths == ["b"])
basket.clear()
check("clear", basket.isEmpty)

// Same id, different files (two BUG-004 reports): both can be in the basket.
let twin1 = bug("BUG-004", "open", path: "docs/bugs/BUG-004-one.md")
let twin2 = bug("BUG-004", "open", path: "docs/bugs/BUG-004-two.md")
basket.add(twin1.path); basket.add(twin2.path)
check("identity is the path, not the id", basket.items(in: [twin1, twin2]).count == 2)

var stale = BugBasket()
for p in ["open", "fixing", "fixed", "gone", "closed"] { stale.add("docs/bugs/\(p).md") }
let current = [bug("open", "open"), bug("fixing", "fixing"), bug("fixed", "fixed"), bug("closed", "closed")]
let removed = stale.reconcile(with: current)
check("reconcile drops deleted and closed", removed == 3 && stale.paths == ["docs/bugs/open.md", "docs/bugs/fixing.md"])
check("fixing stays but is not eligible", stale.eligible(in: current).map(\.key) == ["open"])
check("reconcile again drops nothing", stale.reconcile(with: current) == 0)
check("minimum batch is two", BugBasket.minimumBatch == 2)

// MARK: Prompt (REQ-002…REQ-005, DEC-001…DEC-003, DEC-006, DEC-012)

let batch = [bug("BUG-001", "open", feature: "search"), bug("BUG-007", "open")]
for claude in [true, false] {
    let prompt = BatchFixPrompt.make(batch, claude: claude)
    let name = claude ? "claude" : "generic"
    check("\(name): every path, id and title", batch.allSatisfy { prompt.contains($0.path) && prompt.contains($0.key) && prompt.contains($0.title) })
    check("\(name): feature when known", prompt.contains("feature search"))
    check("\(name): reproduce, root cause, fix, verify", prompt.contains("reproduce it, find the root cause, fix it and verify the fix"))
    check("\(name): branch before changes, report its name", prompt.contains("Create and check out the branch") && prompt.contains("tell me its name"))
    check("\(name): dirty tree or existing branch → ask", prompt.contains("ask me how to proceed and change nothing until I answer"))
    check("\(name): own status edits are not dirty", prompt.contains("do not count as uncommitted changes"))
    check("\(name): MarkView's .dde/ is not dirty", prompt.contains(".dde/ folder are expected"))
    check("\(name): one commit per fixed bug with its id", prompt.contains("exactly one commit") && prompt.contains("starts with the bug id"))
    check("\(name): no commit for unfixed", prompt.contains("Do not commit anything for a bug you could not fix"))
    check("\(name): fixed only after commit, with branch", prompt.contains("Only after a bug's commit exists") && prompt.contains("status: fixed, branch:"))
    check("\(name): unfixed back to open with a note", prompt.contains("status: open") && prompt.contains("## AI fix attempt"))
    check("\(name): other bugs untouched", prompt.contains("not in this list"))
    check("\(name): per-bug outcome", prompt.contains("outcome per bug"))
}
let claudePrompt = BatchFixPrompt.make(batch, claude: true)
check("claude: one-line /goal", claudePrompt.hasPrefix("/goal ") && !claudePrompt.contains("\n"))
check("generic: no /goal", !BatchFixPrompt.make(batch, claude: false).hasPrefix("/goal"))

// MARK: Suggest similar (REQ-006)

var inBasket = BugBasket()
inBasket.add("docs/bugs/B1.md")
let all = [bug("B1", "open"), bug("B2", "open"), bug("B3", "fixing"), bug("B4", "fixed"), bug("B5", "open")]
check("candidates: open, not in basket", SimilarBugs.candidates(all, basket: inBasket).map(\.key) == ["B2", "B5"])
let candidates = SimilarBugs.candidates(all, basket: inBasket)
let answer: [String: Any] = ["suggestions": [
    ["path": "docs/bugs/B5.md", "reason": "Same view"],
    ["path": "docs/bugs/B5.md", "reason": "again"],
    ["path": "docs/bugs/B1.md", "reason": "in basket"],
    ["path": "docs/bugs/nope.md", "reason": "made up"],
    ["path": " docs/bugs/B2.md ", "reason": " Shared cause "],
]]
let parsed = SimilarBugs.parse(answer, candidates: candidates)
check("parse keeps known candidates once", parsed == [SimilarBugs.Suggestion(path: "docs/bugs/B5.md", reason: "Same view"),
                                                     SimilarBugs.Suggestion(path: "docs/bugs/B2.md", reason: "Shared cause")])
check("parse empty answer", SimilarBugs.parse(["suggestions": []], candidates: candidates).isEmpty)
check("parse malformed answer", SimilarBugs.parse(["x": 1], candidates: candidates).isEmpty)
let many = (0..<9).map { bug("C\($0)", "open") }
let manyAnswer: [String: Any] = ["suggestions": many.map { ["path": $0.path, "reason": "r"] }]
check("parse caps at limit", SimilarBugs.parse(manyAnswer, candidates: many).count == SimilarBugs.limit)
let prompt = SimilarBugs.prompt(basket: [.init(bug: all[0], excerpt: "line one\nline two")],
                                candidates: candidates.map { .init(bug: $0, excerpt: "text") })
check("suggest prompt lists basket and candidates", prompt.contains("docs/bugs/B1.md") && prompt.contains("docs/bugs/B5.md")
      && prompt.contains("line one line two"))

print(failures == 0 ? "All bug basket checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
