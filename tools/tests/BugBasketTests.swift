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
    check("\(name): the branch is added only after the commit, and fixed is left to MarkView", prompt.contains("Only after a bug's commit exists") && prompt.contains("branch: <branch name>") && prompt.contains("Do not write status: fixed"))
    check("\(name): unfixed back to open through the project tool, with a note", prompt.contains("markview_set_bug_status") && prompt.contains("## AI fix attempt"))
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

// MARK: Starting a batch (REQ-004, DEC-006, BUG-032; issue-lifecycle-management REQ-003)

/// A fake lifecycle and assistant: records every call so the order can be checked. The prompt goes out before any mark.
final class StartRig {
    var statuses: [String: String]
    var log: [String] = []
    var sent: [[String]] = []
    let blocked: Set<String>       // paths the lifecycle does not let start
    let failMark: Set<String>      // paths whose "fixing" hand-off cannot be recorded
    let sendWorks: Bool

    init(_ bugs: [BasketBug], blocked: Set<String> = [], failMark: Set<String> = [], sendWorks: Bool = true) {
        statuses = Dictionary(uniqueKeysWithValues: bugs.map { ($0.path, $0.status) })
        self.blocked = blocked
        self.failMark = failMark
        self.sendWorks = sendWorks
    }

    func run(_ bugs: [BasketBug]) -> BatchStart.Outcome {
        BatchStart.run(bugs, canStart: { bug in
            log.append("check \(bug.key)")
            return !blocked.contains(bug.path)
        }, send: { startable in
            log.append("send")
            sent.append(startable.map(\.key))
            return sendWorks
        }, start: { bug in
            let fails = failMark.contains(bug.path)
            log.append("\(fails ? "failed " : "")start \(bug.key)")
            if !fails { statuses[bug.path] = "fixing" }
            return !fails
        })
    }

    func status(_ bug: BasketBug) -> String? { statuses[bug.path] }
}

let open1 = bug("BUG-101", "open"), open2 = bug("BUG-102", "Open"), open3 = bug("BUG-103", "open")
let trio = [open1, open2, open3]

let allGood = StartRig(trio)
let allGoodOutcome = allGood.run(trio)
check("start: every bug can start → started, nobody left out or unmarked", allGoodOutcome == .started(leftOut: [], unmarked: []))
check("start: every bug is fixing and in the prompt", trio.allSatisfy { allGood.status($0) == "fixing" } && allGood.sent == [["BUG-101", "BUG-102", "BUG-103"]])
check("start: the send comes before the first mark (a failed send leaves nothing marked)",
      allGood.log == ["check BUG-101", "check BUG-102", "check BUG-103", "send", "start BUG-101", "start BUG-102", "start BUG-103"])
check("start: no notice when all were sent and marked", BatchStart.notice(allGoodOutcome) == nil)

let oneBlocked = StartRig(trio, blocked: [open2.path])
let oneBlockedOutcome = oneBlocked.run(trio)
check("start: a bug the lifecycle does not let start is left out of the prompt, the rest go",
      oneBlockedOutcome == .started(leftOut: [open2], unmarked: []) && oneBlocked.sent == [["BUG-101", "BUG-103"]])
check("start: the left-out bug keeps its status", oneBlocked.status(open2) == "Open" && oneBlocked.status(open1) == "fixing" && oneBlocked.status(open3) == "fixing")
check("start: the notice names the left-out bug", BatchStart.notice(oneBlockedOutcome).map { $0.contains("BUG-102 was left out") && !$0.contains("BUG-101") } == true)

let manyBlocked = StartRig(trio + [bug("BUG-104", "open")], blocked: [open1.path, open3.path])
let manyBlockedNotice = BatchStart.notice(manyBlocked.run(trio + [bug("BUG-104", "open")]))
check("start: several left out read in the plural", manyBlockedNotice.map { $0.contains("BUG-101, BUG-103 were left out") && $0.contains("they cannot be started now") } == true)

let twoBugs = [open1, open2]
let tooFew = StartRig(twoBugs, blocked: [open2.path])
let tooFewOutcome = tooFew.run(twoBugs)
check("start: too few can start → nothing is sent and nothing is marked",
      tooFewOutcome == .tooFewStartable(leftOut: [open2]) && tooFew.sent.isEmpty && !tooFew.log.contains("send") && !tooFew.log.contains { $0.hasPrefix("start") })
check("start: too few can start → both keep their status", tooFew.status(open1) == "open" && tooFew.status(open2) == "Open")
check("start: too few can start → a notice says why", BatchStart.notice(tooFewOutcome).map {
    $0.hasPrefix("Nothing was sent") && $0.contains("the report of BUG-102") && $0.contains("at least 2") && $0.contains("basket is unchanged") && $0.contains("No bug was marked")
} == true)

let noneStart = StartRig(twoBugs, blocked: [open1.path, open2.path])
let noneStartOutcome = noneStart.run(twoBugs)
check("start: none can start → nothing sent, nothing marked", noneStartOutcome == .tooFewStartable(leftOut: twoBugs) && noneStart.log == ["check BUG-101", "check BUG-102"])
check("start: none can start → plural notice", BatchStart.notice(noneStartOutcome)?.contains("the reports of BUG-101, BUG-102") == true)

let unsent = StartRig(trio, sendWorks: false)
let unsentOutcome = unsent.run(trio)
check("start: prompt not sent → no bug was marked, so none has to be restored", unsentOutcome == .notSent(leftOut: [])
      && unsent.status(open1) == "open" && unsent.status(open2) == "Open" && unsent.status(open3) == "open"
      && !unsent.log.contains { $0.hasPrefix("start") })
check("start: prompt not sent → the notice keeps the basket", BatchStart.notice(unsentOutcome).map {
    $0.hasPrefix("Nothing was sent") && $0.contains("basket is unchanged") && $0.contains("No bug was marked")
} == true)

let unsentAndBlocked = StartRig(trio, blocked: [open3.path], sendWorks: false)
check("start: prompt not sent with one left out → still nothing marked", unsentAndBlocked.run(trio) == .notSent(leftOut: [open3])
      && unsentAndBlocked.status(open1) == "open" && unsentAndBlocked.status(open2) == "Open" && unsentAndBlocked.status(open3) == "open")

let unmarkedRig = StartRig(trio, failMark: [open2.path])
let unmarkedOutcome = unmarkedRig.run(trio)
check("start: a hand-off that cannot be recorded after the send is reported, the others stay marked",
      unmarkedOutcome == .started(leftOut: [], unmarked: [open2]) && unmarkedRig.status(open2) == "Open" && unmarkedRig.status(open1) == "fixing")
check("start: the notice names the unmarked bug", BatchStart.notice(unmarkedOutcome).map {
    $0.contains("BUG-102 is in the prompt but could not be marked fixing") && $0.contains("its status is unchanged")
} == true)

// The role the project's workflow gives the status decides (feature-3).
func roled(_ status: String, _ role: LifecycleRole) -> BasketBug { var item = bug("B1", status); item.role = role; return item }
check("a not-started status can be added whatever it is called", BugBasket.canAdd(roled("triaged", .notStarted)) && !BugBasket.canAdd(roled("open", .active)))
check("an active status is being fixed whatever it is called", BugBasket.isBeingFixed(roled("in-review", .active)) && !BugBasket.isBeingFixed(roled("fixing", .notStarted)))

print(failures == 0 ? "All bug basket checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
