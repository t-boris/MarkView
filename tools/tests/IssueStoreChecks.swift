// Checks the lifecycle on real files (MarkView/Models/MarkdownIssueStatusStore.swift with the transition service and its journal)
// in a temporary project: a status is written to the `status` line of the overview or the bug report and nothing else, a stale or
// refused request changes no file, a bug is found by its key and never by a longer key it prefixes, a hand edit of the Markdown is
// detected and never counts as completion (REQ-001, REQ-002, REQ-005 of docs/features/issue-lifecycle-management).
import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("markview-store-" + UUID().uuidString)
func write(_ text: String, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
func read(_ path: String) -> String { (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "<missing>" }
func journalLines() -> Int { read(".dde/lifecycle/transitions.jsonl").split(separator: "\n").count }

let demo = "docs/features/demo/overview.md"
let crash = "docs/bugs/BUG-001-crash-on-export.md"
let longer = "docs/bugs/BUG-0010-other.md"
write("---\ntitle: Demo\nstatus: draft\nowner: Boris\n---\n\nBody text.\n", demo)
write("---\ntype: bug\nid: BUG-001\ntitle: Crash\nstatus: open\nseverity: high\n---\n\n## Summary\n\nIt crashes.\n", crash)
write("---\ntype: bug\nid: BUG-0010\ntitle: Other\nstatus: open\n---\n\nOther.\n", longer)
write("---\ntitle: No status\n---\n\nText.\n", "docs/features/plain/overview.md")
write("---\ntype: bug\nid: BUG-002\ntitle: No status\n---\n\nText.\n", "docs/bugs/BUG-002-no-status.md")
try? fm.createDirectory(at: root.appendingPathComponent("docs/features/hand-written"), withIntermediateDirectories: true)

let statuses = MarkdownIssueStatusStore(root: root)
let service = IssueTransitionService(storage: FileTransitionStorage(projectRoot: root), statuses: statuses)
let person = LifecycleActor.human("Boris")
let agent = LifecycleActor.ai("Claude Code", session: "s1")

// MARK: Reading

check("a feature's status is read from its overview", statuses.status(kind: .feature, issue: "demo") == "draft")
check("a bug's status is read from its report", statuses.status(kind: .bug, issue: "BUG-001") == "open")
check("a feature with no status line is an idea", statuses.status(kind: .feature, issue: "plain") == "idea")
check("a bug with no status line is open", statuses.status(kind: .bug, issue: "BUG-002") == "open")
check("a hand-written feature folder without an overview is a draft", statuses.status(kind: .feature, issue: "hand-written") == "draft")
check("an unknown feature has no status", statuses.status(kind: .feature, issue: "missing") == nil)
check("a slug cannot leave the features folder", statuses.status(kind: .feature, issue: "../bugs") == nil && statuses.status(kind: .feature, issue: "demo/../demo") == nil)
check("a bug is found by its key, not by a longer key it prefixes", statuses.bugFile(key: "BUG-001")?.lastPathComponent == "BUG-001-crash-on-export.md")
check("the longer key is found by its own", statuses.bugFile(key: "BUG-0010")?.lastPathComponent == "BUG-0010-other.md")
check("an unknown bug has no status", statuses.status(kind: .bug, issue: "BUG-999") == nil)
write("---\ntype: bug\nid: BUG-003\nstatus: open\n---\n", "docs/bugs/BUG-003-new.md")
check("a bug created after the directory index was built is found", statuses.status(kind: .bug, issue: "BUG-003") == "open")
try! fm.moveItem(at: root.appendingPathComponent("docs/bugs/BUG-003-new.md"), to: root.appendingPathComponent("docs/bugs/BUG-003-renamed.md"))
check("a renamed bug refreshes the directory index", statuses.bugFile(key: "BUG-003")?.lastPathComponent == "BUG-003-renamed.md")
try! fm.removeItem(at: root.appendingPathComponent("docs/bugs/BUG-003-renamed.md"))
check("a deleted bug disappears from the directory index", statuses.status(kind: .bug, issue: "BUG-003") == nil)

// MARK: A step writes the status line and nothing else

let first = service.apply(TransitionRequest(kind: .feature, issue: "demo", from: "draft", to: "review", actor: person))
check("a specification step by a person is applied", first.isApplied)
check("only the status line of the overview changed", read(demo) == "---\ntitle: Demo\nstatus: review\nowner: Boris\n---\n\nBody text.\n")
check("the journal holds the begin and the applied record", journalLines() == 2)
check("the history ends with the new status", service.history(.feature, "demo").expectedStatus == "review")

let before = read(demo)
let stale = service.apply(TransitionRequest(kind: .feature, issue: "demo", from: "draft", to: "ready", actor: person))
if case .stale(let current) = stale { check("a request made from an old status is stale and names the current one", current == "review") } else { check("a request made from an old status is stale and names the current one", false) }
check("a stale request changes no file", read(demo) == before)

let command = UUID().uuidString
let one = service.apply(TransitionRequest(command: command, kind: .feature, issue: "demo", from: "review", to: "ready", actor: person))
let again = service.apply(TransitionRequest(command: command, kind: .feature, issue: "demo", from: "review", to: "ready", actor: person))
check("the same command twice is applied once", one.isApplied && !again.isApplied && read(demo).contains("status: ready"))
check("and the second answer is the first outcome", { if case .duplicate = again { return true } else { return false } }())

// MARK: A bug is found by its key and only its report changes

let started = service.apply(TransitionRequest(kind: .bug, issue: "BUG-001", from: "open", to: "fixing", actor: person,
                                              evidence: LifecycleEvidence(start: .handoff(tool: "Claude Code", at: Date()))))
check("a hand-off starts a bug", started.isApplied)
check("only that bug's report changed", read(crash).contains("status: fixing") && read(longer).contains("status: open"))
check("the rest of the report is untouched", read(crash) == "---\ntype: bug\nid: BUG-001\ntitle: Crash\nstatus: fixing\nseverity: high\n---\n\n## Summary\n\nIt crashes.\n")

// MARK: A refused request changes nothing but the journal

let beforeRefused = read(crash)
let linesBefore = journalLines()
let refused = service.apply(TransitionRequest(kind: .bug, issue: "BUG-001", from: "fixing", to: "fixed", actor: agent))
if case .rejected(let rejection) = refused {
    check("an AI cannot record a fix without delivery evidence", rejection.missing.contains(.deliveryEvidence))
} else {
    check("an AI cannot record a fix without delivery evidence", false)
}
check("a refused request leaves the report alone", read(crash) == beforeRefused)
check("but it is kept so the person can inspect it", journalLines() == linesBefore + 1 && service.history(.bug, "BUG-001").rejections.count == 1)
let forced = service.apply(TransitionRequest(kind: .bug, issue: "BUG-001", from: "fixing", to: "fixed", actor: agent, reason: "just do it", force: true))
check("an AI cannot force it", !forced.isApplied && read(crash) == beforeRefused)

// MARK: What the files cannot take

write("---\ntitle: Commented\nstatus: draft\n# keep this comment\nowner: Boris\n---\n\nText.\n", "docs/features/commented/overview.md")
let commented = read("docs/features/commented/overview.md")
let lossy = service.apply(TransitionRequest(kind: .feature, issue: "commented", from: "draft", to: "review", actor: person))
check("front matter the app cannot rewrite without loss is refused, not damaged", !lossy.isApplied && read("docs/features/commented/overview.md") == commented)
let missing = service.apply(TransitionRequest(kind: .feature, issue: "nothing-here", from: "draft", to: "review", actor: person))
check("an issue that has no file is a failure", { if case .failed = missing { return true } else { return false } }())

// MARK: A hand edit of the Markdown is detected and is not completion (REQ-005 criterion 3)

write(read(demo).replacingOccurrences(of: "status: ready", with: "status: implemented"), demo)
let restarted = IssueTransitionService(storage: FileTransitionStorage(projectRoot: root), statuses: MarkdownIssueStatusStore(root: root))
let history = restarted.history(.feature, "demo")
check("the history survives a restart", history.expectedStatus == "ready" && history.changes.count >= 2)
check("times survive a restart to the millisecond", zip(service.history(.feature, "demo").records, history.records).allSatisfy { abs($0.at.timeIntervalSince($1.at)) < 0.001 })
check("and keep their order within a second", history.records.map(\.at) == history.records.map(\.at).sorted())
let stored = MarkdownIssueStatusStore(root: root).status(kind: .feature, issue: "demo") ?? ""
let actions = IssueReconciler.actions(ReconcileInput(kind: .feature, issue: "demo", storedStatus: stored, history: history))
check("the reconciler sees a status the history did not set", actions.contains(.externalEdit(from: "ready", to: "implemented")))
check("the edit is recorded as unverified", restarted.recordExternalEdit(.feature, "demo", from: "ready", to: "implemented")?.verified == false)
let afterEdit = restarted.history(.feature, "demo")
check("it is an unresolved discrepancy", afterEdit.unresolvedExternal.count == 1)
let state = IssueCompletion.state(kind: .feature, status: "implemented", history: afterEdit, deliveryNow: nil)
check("and the status does not count as verified completion", !IssueCompletion.isVerified(state))
check("the edit is not repeated while it is recorded", restarted.recordExternalEdit(.feature, "demo", from: "ready", to: "implemented") == nil
      && restarted.history(.feature, "demo").unresolvedExternal.count == 1)

// MARK: Appending

do {
    let file = root.appendingPathComponent("append/lines.jsonl")
    try! JSONLinesFile.append(Data("{\"a\":1}\n".utf8), to: file)
    try! JSONLinesFile.append(Data("{\"a\":2}\n".utf8), to: file)
    check("lines are appended in order, the file and its folder are created", (try? String(contentsOf: file, encoding: .utf8)) == "{\"a\":1}\n{\"a\":2}\n")
    let cut = root.appendingPathComponent("append/cut.jsonl")
    try! Data("{\"a\":1}\n{\"a\":".utf8).write(to: cut)
    try! JSONLinesFile.append(Data("{\"a\":3}\n".utf8), to: cut)
    check("a line cut short is ended before the next one", (try? String(contentsOf: cut, encoding: .utf8)) == "{\"a\":1}\n{\"a\":\n{\"a\":3}\n")
    // Two writers that hold no lock in common (two windows on one project) lose nothing.
    let busy = root.appendingPathComponent("append/busy.jsonl")
    DispatchQueue.concurrentPerform(iterations: 200) { index in
        let storage = FileTransitionStorage(url: busy)
        try? storage.append(TransitionRecord(phase: .baseline, command: "c\(index)", kind: .feature, issue: "f\(index)", to: "ready", actor: .system("test")))
    }
    let loaded = (try? FileTransitionStorage(url: busy).load()) ?? []
    check("200 concurrent appends by separate writers all survive", loaded.count == 200 && Set(loaded.map(\.issue)).count == 200)
}

try? fm.removeItem(at: root)
finish("store")
