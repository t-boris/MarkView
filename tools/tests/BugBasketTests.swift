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

// MARK: Starting a batch (REQ-004, DEC-006, BUG-032)

/// A fake report store and assistant: records every call so the order can be checked.
final class StartRig {
    var statuses: [String: String]
    var log: [String] = []
    var sent: [[String]] = []
    let failMark: Set<String>      // paths whose "fixing" write fails
    let failRestore: Set<String>   // paths whose write back fails
    let sendWorks: Bool

    init(_ bugs: [BasketBug], failMark: Set<String> = [], failRestore: Set<String> = [], sendWorks: Bool = true) {
        statuses = Dictionary(uniqueKeysWithValues: bugs.map { ($0.path, $0.status) })
        self.failMark = failMark
        self.failRestore = failRestore
        self.sendWorks = sendWorks
    }

    func run(_ bugs: [BasketBug]) -> BatchStart.Outcome {
        BatchStart.run(bugs, setStatus: { bug, status in
            let fails = status == "fixing" ? failMark.contains(bug.path) : failRestore.contains(bug.path)
            log.append("\(fails ? "failed " : "")set \(bug.key)=\(status)")
            if !fails { statuses[bug.path] = status }
            return !fails
        }, send: { marked in
            log.append("send")
            sent.append(marked.map(\.key))
            return sendWorks
        })
    }

    func status(_ bug: BasketBug) -> String? { statuses[bug.path] }
}

let open1 = bug("BUG-101", "open"), open2 = bug("BUG-102", "Open"), open3 = bug("BUG-103", "open")
let trio = [open1, open2, open3]

let allGood = StartRig(trio)
let allGoodOutcome = allGood.run(trio)
check("start: every write works → started, nobody left out", allGoodOutcome == .started(leftOut: []))
check("start: every bug is fixing and in the prompt", trio.allSatisfy { allGood.status($0) == "fixing" } && allGood.sent == [["BUG-101", "BUG-102", "BUG-103"]])
check("start: marks come before the send (the AI writes after them)", allGood.log == ["set BUG-101=fixing", "set BUG-102=fixing", "set BUG-103=fixing", "send"])
check("start: no notice when all were sent", BatchStart.notice(allGoodOutcome) == nil)

let oneFails = StartRig(trio, failMark: [open2.path])
let oneFailsOutcome = oneFails.run(trio)
check("start: a failed write is left out, the rest go", oneFailsOutcome == .started(leftOut: [open2]) && oneFails.sent == [["BUG-101", "BUG-103"]])
check("start: the left-out bug keeps its status", oneFails.status(open2) == "Open" && oneFails.status(open1) == "fixing" && oneFails.status(open3) == "fixing")
check("start: the notice names the left-out bug", BatchStart.notice(oneFailsOutcome).map { $0.contains("BUG-102 was left out") && !$0.contains("BUG-101") } == true)

let manyFail = StartRig(trio + [bug("BUG-104", "open")], failMark: [open1.path, open3.path])
let manyFailNotice = BatchStart.notice(manyFail.run(trio + [bug("BUG-104", "open")]))
check("start: several left out read in the plural", manyFailNotice.map { $0.contains("BUG-101, BUG-103 were left out") && $0.contains("their reports") } == true)

let twoBugs = [open1, open2]
let tooFew = StartRig(twoBugs, failMark: [open2.path])
let tooFewOutcome = tooFew.run(twoBugs)
check("start: too few marked → nothing is sent", tooFewOutcome == .tooFewMarked(leftOut: [open2], stuck: []) && tooFew.sent.isEmpty && !tooFew.log.contains("send"))
check("start: too few marked → the marked bug is restored", tooFew.status(open1) == "open" && tooFew.status(open2) == "Open"
      && tooFew.log == ["set BUG-101=fixing", "failed set BUG-102=fixing", "set BUG-101=open"])
check("start: too few marked → a notice says why", BatchStart.notice(tooFewOutcome).map {
    $0.hasPrefix("Nothing was sent") && $0.contains("the report of BUG-102") && $0.contains("at least 2") && $0.contains("basket is unchanged")
} == true)

let noneMarked = StartRig(twoBugs, failMark: [open1.path, open2.path])
let noneMarkedOutcome = noneMarked.run(twoBugs)
check("start: no write works → nothing sent, nothing to restore",
      noneMarkedOutcome == .tooFewMarked(leftOut: twoBugs, stuck: []) && noneMarked.log == ["failed set BUG-101=fixing", "failed set BUG-102=fixing"])
check("start: no write works → plural notice", BatchStart.notice(noneMarkedOutcome)?.contains("the reports of BUG-101, BUG-102") == true)

let unsent = StartRig(trio, sendWorks: false)
let unsentOutcome = unsent.run(trio)
check("start: prompt not sent → every bug is back to its status", unsentOutcome == .notSent(leftOut: [], stuck: [])
      && unsent.status(open1) == "open" && unsent.status(open2) == "Open" && unsent.status(open3) == "open")
check("start: prompt not sent → restore comes after the send attempt", unsent.log == [
    "set BUG-101=fixing", "set BUG-102=fixing", "set BUG-103=fixing", "send",
    "set BUG-101=open", "set BUG-102=Open", "set BUG-103=open"])
check("start: prompt not sent → the notice keeps the basket", BatchStart.notice(unsentOutcome).map {
    $0.hasPrefix("Nothing was sent") && $0.contains("basket is unchanged") && !$0.contains("However")
} == true)

let unsentAndLeftOut = StartRig(trio, failMark: [open3.path], sendWorks: false)
check("start: prompt not sent → only the marked bugs are restored", unsentAndLeftOut.run(trio) == .notSent(leftOut: [open3], stuck: [])
      && unsentAndLeftOut.status(open1) == "open" && unsentAndLeftOut.status(open2) == "Open" && unsentAndLeftOut.status(open3) == "open")

let stuckRig = StartRig(trio, failRestore: [open2.path, open3.path], sendWorks: false)
let stuckOutcome = stuckRig.run(trio)
check("start: a restore that fails is reported", stuckOutcome == .notSent(leftOut: [], stuck: [open2, open3])
      && stuckRig.status(open2) == "fixing" && stuckRig.status(open1) == "open")
check("start: the notice names bugs still fixing", BatchStart.notice(stuckOutcome).map {
    $0.contains("However, BUG-102, BUG-103 could not be set back to open and are still marked fixing") && $0.contains("their status by hand")
} == true)

let stuckOne = StartRig(twoBugs, failMark: [open2.path], failRestore: [open1.path])
check("start: too few marked and the restore fails → stuck", stuckOne.run(twoBugs) == .tooFewMarked(leftOut: [open2], stuck: [open1]))

print(failures == 0 ? "All bug basket checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
