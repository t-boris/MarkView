// Checks the bug validity check (MarkView/Models/BugValidity.swift) against REQ-001…REQ-005 and DEC-001…DEC-004 of
// docs/features/bug-validity-check-before-analysis. Run from the repository root by tools/tests/bug-validity-tests.sh.
// Git behaviour is checked on real repositories in a temporary folder; the assistant is replaced by answers written in the tests.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// MARK: - Git fixtures

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("bug-validity-tests-" + UUID().uuidString)
try! fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

@discardableResult
func git(_ arguments: [String], in directory: URL) -> (status: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                         "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"] + arguments
    process.currentDirectoryURL = directory
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"; env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

let runner: BugValidity.GitRunner = { arguments, directory, _ in
    let r = git(arguments, in: directory)
    return BugValidity.GitOutput(status: r.status, stdout: r.out, stderr: r.status == 0 ? "" : r.out)
}

func write(_ text: String, to path: String, in root: URL) {
    let url = root.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func repo(_ name: String) -> URL {
    let url = work.appendingPathComponent(name)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main"], in: url)
    return url
}

func commit(_ message: String, in root: URL) {
    git(["add", "-A"], in: root)
    git(["commit", "-q", "-m", message], in: root)
}

func head(_ ref: String, in root: URL) -> String { git(["rev-parse", ref], in: root).out }

// MARK: - Baseline: an identifiable revision of main (REQ-001, DEC-002)

// A project with a remote: origin/main is the baseline, and a local main commit that was never pushed is not.
let upstream = work.appendingPathComponent("upstream.git")
try! fm.createDirectory(at: upstream, withIntermediateDirectories: true)
git(["init", "-q", "--bare", "-b", "main"], in: upstream)
let project = repo("project")
write("old behaviour\n", to: "Sources/Feature.swift", in: project)
write("# BUG-001\n", to: "docs/bugs/BUG-001.md", in: project)
commit("Initial commit", in: project)
git(["remote", "add", "origin", upstream.path], in: project)
git(["push", "-q", "-u", "origin", "main"], in: project)
let pushed = head("HEAD", in: project)

write("fixed behaviour on a pushed commit\n", to: "Sources/Fixed.swift", in: project)
commit("Fix BUG-001: handle the empty list (#41)", in: project)
git(["push", "-q", "origin", "main"], in: project)
let mainTip = head("HEAD", in: project)

// A local-only commit on main, a feature branch with a fix, and uncommitted work.
write("only in an unpushed commit\n", to: "Sources/LocalOnly.swift", in: project)
commit("Unpushed work", in: project)
git(["checkout", "-q", "-b", "feature/other-fix"], in: project)
write("only on a feature branch\n", to: "Sources/BranchFix.swift", in: project)
commit("Fix only on a branch", in: project)
write("modified but not committed\n", to: "Sources/Feature.swift", in: project)
write("untracked file\n", to: "Sources/Untracked.swift", in: project)

let baseline = await BugValidity.resolveMain(root: project, git: runner)
check("main is identified: origin/main wins over the local main", baseline?.ref == "origin/main")
check("the baseline is one commit: the tip of origin/main, not the unpushed commit or the branch", baseline?.commit == mainTip && baseline?.commit != head("HEAD", in: project))
check("the baseline carries the commit's date and subject", (baseline?.date.count ?? 0) == 10 && baseline?.subject == "Fix BUG-001: handle the empty list (#41)")
check("the baseline label names the ref and the short commit", baseline?.label.contains("`origin/main`") == true && baseline?.label.contains(String(mainTip.prefix(10))) == true)

let exported = await BugValidity.exportMain(baseline!, root: project, git: runner)
check("main is exported", exported != nil)
if let exported {
    func has(_ path: String) -> Bool { fm.fileExists(atPath: exported.tree.appendingPathComponent(path).path) }
    check("the export holds what main holds", has("Sources/Fixed.swift") && has("docs/bugs/BUG-001.md"))
    check("a fix only on another branch cannot appear in the export", !has("Sources/BranchFix.swift"))
    check("a commit that was never pushed to main cannot appear in the export", !has("Sources/LocalOnly.swift"))
    check("uncommitted and untracked work cannot appear in the export", !has("Sources/Untracked.swift"))
    check("a modified file is exported as committed", (try? String(contentsOf: exported.tree.appendingPathComponent("Sources/Feature.swift"), encoding: .utf8)) == "old behaviour\n")
    check("the export is not the working tree", exported.tree.standardizedFileURL.path != project.standardizedFileURL.path
          && !exported.tree.path.hasPrefix(project.path))
    let tree = exported.tree
    exported.remove()
    check("removing the export removes its folder", !fm.fileExists(atPath: tree.path))
}

// The hints: commits on main that mention the report.
let hints = await BugValidity.commitHints(key: "BUG-001", issues: [41, 99], baseline: baseline!, root: project, git: runner)
check("commit hints find the commits that mention the report or its issue", hints.count == 1 && hints[0].contains("Fix BUG-001"))
check("no hint when nothing mentions it", await BugValidity.commitHints(key: "BUG-777", issues: [], baseline: baseline!, root: project, git: runner).isEmpty)

// A repository with only a local main, one with only master, one without commits, and a folder that is no repository.
let localOnly = repo("local-only")
write("a\n", to: "a.txt", in: localOnly)
commit("one", in: localOnly)
let local = await BugValidity.resolveMain(root: localOnly, git: runner)
check("without a remote the local main is the baseline", local?.ref == "main" && local?.commit == head("main", in: localOnly))

let masterRepo = work.appendingPathComponent("master-repo")
try! fm.createDirectory(at: masterRepo, withIntermediateDirectories: true)
git(["init", "-q", "-b", "master"], in: masterRepo)
write("a\n", to: "a.txt", in: masterRepo)
commit("one", in: masterRepo)
check("a repository whose main branch is called master uses it", await BugValidity.resolveMain(root: masterRepo, git: runner)?.ref == "master")

let onlyBranch = repo("only-branch")
write("a\n", to: "a.txt", in: onlyBranch)
commit("one", in: onlyBranch)
git(["checkout", "-q", "-b", "work"], in: onlyBranch)
git(["branch", "-q", "-D", "main"], in: onlyBranch)
check("a repository without a main branch has no baseline: inconclusive, never a guess", await BugValidity.resolveMain(root: onlyBranch, git: runner) == nil)

let empty = repo("empty")
check("a repository without commits has no baseline", await BugValidity.resolveMain(root: empty, git: runner) == nil)
let plain = work.appendingPathComponent("plain-folder")
try! fm.createDirectory(at: plain, withIntermediateDirectories: true)
check("a folder that is not a repository has no baseline", await BugValidity.resolveMain(root: plain, git: runner) == nil)

// A project below the repository root keeps project-relative paths.
let mono = repo("mono")
write("app\n", to: "app/Sources/App.swift", in: mono)
write("other\n", to: "other/File.swift", in: mono)
commit("mono", in: mono)
let sub = await BugValidity.resolveMain(root: mono.appendingPathComponent("app"), git: runner)
check("the project folder inside the repository is recorded", sub?.prefix == "app/")
if let sub, let subExport = await BugValidity.exportMain(sub, root: mono.appendingPathComponent("app"), git: runner) {
    check("the export of a sub-project holds project-relative paths only",
          fm.fileExists(atPath: subExport.tree.appendingPathComponent("Sources/App.swift").path)
          && !fm.fileExists(atPath: subExport.tree.appendingPathComponent("other/File.swift").path))
    subExport.remove()
} else { check("the export of a sub-project works", false) }

let missing = BugValidity.Baseline(ref: "origin/main", commit: String(repeating: "0", count: 40))
check("an export that fails is nil (the outcome is then inconclusive)", await BugValidity.exportMain(missing, root: project, git: runner) == nil)
check("a failed export leaves nothing behind", (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path))?.filter { $0.hasPrefix("markview-validity-") }.isEmpty ?? true)

// MARK: - The answer is checked before it is believed (REQ-002, REQ-004, REQ-005, DEC-001)

let tree = work.appendingPathComponent("tree")
write("func handle() {}\n", to: "Sources/Fixed.swift", in: tree)
write("func testHandle() {}\n", to: "Tests/FixedTests.swift", in: tree)
write("# the report\n", to: "docs/bugs/BUG-001.md", in: tree)
write("secret\n", to: "../outside.txt", in: tree)
let base = BugValidity.Baseline(ref: "origin/main", commit: mainTip, date: "2026-11-03", subject: "Fix")
let report = "docs/bugs/BUG-001.md"

func fixed(basis: String = "fix-in-code", evidence: [[String: Any]]? = nil, explanation: String = "The empty list is now handled before the loop.",
           reason: String = "handle() returns early on an empty list.") -> [String: Any] {
    ["outcome": "already-fixed", "reason": reason, "basis": basis, "explanation": explanation,
     "evidence": evidence ?? [["path": "Sources/Fixed.swift", "finding": "handle() checks isEmpty first."]]]
}
func verdict(_ object: [String: Any]?, tree: URL? = tree) -> BugValidity.Verdict {
    BugValidity.verdict(from: object, baseline: base, tree: tree, reportPath: report)
}

let good = verdict(fixed())
check("an affirmative, evidenced answer is already-fixed", good.outcome == .alreadyFixed && good.evidence.count == 1 && good.basis == .fixInCode && good.baseline == base)
check("a test on main is evidence too", verdict(fixed(basis: "covered-by-test", evidence: [["path": "Tests/FixedTests.swift", "finding": "covers the empty list"]])).outcome == .alreadyFixed)
check("a scenario that can no longer occur is evidence", verdict(fixed(basis: "scenario-removed")).outcome == .alreadyFixed)

let notReproduced = verdict(fixed(basis: "could-not-reproduce"))
check("inability to reproduce alone is not evidence (DEC-001)", notReproduced.outcome == .inconclusive && notReproduced.reason.contains("not evidence"))
check("no basis is not evidence", verdict(fixed(basis: "none")).outcome == .inconclusive)
check("an unknown basis is not evidence", verdict(fixed(basis: "i-looked")).outcome == .inconclusive)
check("no evidence, no closure", verdict(fixed(evidence: [])).outcome == .inconclusive)
check("evidence naming a file that main does not hold is rejected", verdict(fixed(evidence: [["path": "Sources/Imagined.swift", "finding": "x"]])).outcome == .inconclusive)
check("evidence needs a finding", verdict(fixed(evidence: [["path": "Sources/Fixed.swift", "finding": "  "]])).outcome == .inconclusive)
check("the report itself is not evidence that it was fixed", verdict(fixed(evidence: [["path": report, "finding": "says it is fixed"]])).outcome == .inconclusive)
check("evidence cannot leave the export", verdict(fixed(evidence: [["path": "../outside.txt", "finding": "x"]])).outcome == .inconclusive
      && verdict(fixed(evidence: [["path": work.appendingPathComponent("outside.txt").path, "finding": "x"]])).outcome == .inconclusive)
check("an explanation of why nothing more is needed is required", verdict(fixed(explanation: " ")).outcome == .inconclusive)
check("one good piece among rejected ones is enough and only it is kept",
      { let v = verdict(fixed(evidence: [["path": "Sources/Imagined.swift", "finding": "x"], ["path": "./Sources/Fixed.swift", "finding": "handles it"]]))
        return v.outcome == .alreadyFixed && v.evidence.map(\.path) == ["Sources/Fixed.swift"] }())
check("without an export to read nothing can be established", verdict(fixed(), tree: nil).outcome == .inconclusive)
check("the downgrade keeps the assistant's finding for the reader", notReproduced.reason.contains("handle() returns early"))
check("a downgrade never carries evidence or an explanation", notReproduced.evidence.isEmpty && notReproduced.explanation.isEmpty && notReproduced.basis == .none)
check("no answer is inconclusive", verdict(nil).outcome == .inconclusive)
check("an unreadable outcome is inconclusive", verdict(["outcome": "probably-fine"]).outcome == .inconclusive && verdict([:]).outcome == .inconclusive)
check("still-present passes through with its finding", verdict(["outcome": "still-present", "reason": "The loop still crashes."]).outcome == .stillPresent
      && verdict(["outcome": "still-present", "reason": "The loop still crashes."]).reason == "The loop still crashes.")
check("inconclusive passes through with its reason", verdict(["outcome": "inconclusive", "reason": "Needs a running app."]).reason == "Needs a running app.")
check("an inconclusive answer without a reason still says why", !verdict(["outcome": "inconclusive", "reason": ""]).reason.isEmpty)
let long = verdict(fixed(explanation: String(repeating: "y", count: 9_000), reason: String(repeating: "x", count: 9_000)))
check("long fields are cut", long.reason.count < 1_600 && long.explanation.count < 1_600)

// MARK: - The report: closure, evidence, retention (REQ-002, REQ-005, DEC-003)

let reportText = """
---
type: bug
id: BUG-001
title: List crashes
status: open
severity: high
ready_to_fix: true
issue: "#41"
questions:
  - id: BQ-1
    text: Which list?
    status: answered
    answer: The empty one
---

# List crashes

## Summary

The list crashes when empty.

## Likely causes

- no empty check

## Discussion

### User · 2026-11-02

Still happens for me.

## Original description

It crashes.
"""
let today = "2026-11-04"

func recorded(_ verdict: BugValidity.Verdict, in text: String = reportText) -> (front: FrontMatter, body: String, text: String) {
    var (front, body) = FrontMatter.split(text)
    BugValidity.record(verdict, today: today, front: &front, body: &body)
    return (front, body, front.join(body: body))
}

let closed = recorded(good)
check("an already-fixed verdict does not write the status itself (the lifecycle service closes the report)", closed.front.string("status") == "open")
check("the closure records the verification baseline (ref, commit, date)", closed.body.contains("`origin/main`") && closed.body.contains(String(mainTip.prefix(10))) && closed.body.contains("2026-11-03"))
check("the closure records the evidence addressing the scenario", closed.body.contains("`Sources/Fixed.swift` — handle() checks isEmpty first."))
check("the closure records why no further correction is needed", closed.body.contains("**Why no further correction is needed:** The empty list is now handled before the loop."))
check("the closure is identified as automatic in the report", closed.body.contains("closed automatically on 2026-11-04"))
check("the reason is visible in the conversation", closed.body.contains("### Validity check · 2026-11-04") && closed.body.contains("Closed automatically"))
check("a closed report is not proposed as ready to hand off", closed.front.string("ready_to_fix").isEmpty)
check("the rest of the report is untouched", closed.body.contains("The list crashes when empty.") && closed.body.contains("Still happens for me.")
      && closed.body.contains("## Original description") && closed.front.string("issue") == "#41" && closed.front.string("severity") == "high"
      && closed.front.string("title") == "List crashes")
check("the questions are untouched", closed.text.contains("Which list?") && closed.text.contains("The empty one"))
check("the section sits before the discussion and the original description",
      { let t = closed.body; return t.range(of: "## Validity check")!.lowerBound < t.range(of: "## Discussion")!.lowerBound
        && t.range(of: "## Discussion")!.lowerBound < t.range(of: "## Original description")!.lowerBound
        && t.range(of: "## Likely causes")!.lowerBound < t.range(of: "## Validity check")!.lowerBound }())
let reread = FrontMatter.split(closed.text)
check("the saved report reads back with the section", reread.0.string("status") == "open" && reread.0.isLossless
      && BugReportLayout.sections(reread.1).first { $0.heading == BugValidity.sectionName }?.text.contains("Sources/Fixed.swift") == true)
check("closing makes no change to the GitHub link, so the manual Sync still finds it", reread.0.string("issue") == "#41")

let inconclusive = BugValidity.inconclusive("Needs a running app.", baseline: base)
let stayed = recorded(inconclusive)
check("an inconclusive verdict leaves the status unchanged", stayed.front.string("status") == "open")
check("it records the uncertainty and its reason", stayed.body.contains("**Outcome:** Inconclusive") && stayed.body.contains("**Reason:** Needs a running app."))
check("it adds nothing to the conversation", !stayed.body.contains("### Validity check"))
check("it does not touch a status that was fixing", recorded(inconclusive, in: reportText.replacingOccurrences(of: "status: open", with: "status: fixing")).front.string("status") == "fixing")
let present = recorded(BugValidity.Verdict(outcome: .stillPresent, reason: "The loop still crashes.", baseline: base))
check("still-present keeps the status and records the finding", present.front.string("status") == "open" && present.body.contains("Still present on main"))
let twice = recorded(good, in: closed.text)
check("a later check replaces the section instead of adding another", BugReportLayout.sections(twice.body).filter { $0.heading == BugValidity.sectionName }.count == 1)
let none = recorded(BugValidity.inconclusive("No git.", baseline: nil))
check("a check without a baseline says so", none.body.contains("no revision of main could be identified"))

check("a check that found nothing new is not written again", BugValidity.isRecorded(inconclusive, today: "2026-12-01", in: stayed.body))
check("a check on a newer main is written", !BugValidity.isRecorded(inconclusive, today: today, in: stayed.body.replacingOccurrences(of: String(mainTip.prefix(10)), with: "abcdef0123")))
check("a changed outcome is written", !BugValidity.isRecorded(BugValidity.Verdict(outcome: .stillPresent, reason: "x", baseline: base), today: today, in: stayed.body))
check("a closure is always written", !BugValidity.isRecorded(good, today: today, in: closed.body))

let hostile = BugValidity.Verdict(outcome: .alreadyFixed, reason: "ok\n## Original description\nrewritten", basis: .fixInCode,
                                  evidence: [BugValidity.Evidence(path: "Sources/Fixed.swift", finding: "line\n## Summary\nfake")], explanation: "x\n## Discussion\ny", baseline: base)
let safe = recorded(hostile)
check("text from the assistant cannot create report sections", BugReportLayout.sections(safe.body).map(\.heading) == ["", "Summary", "Likely causes", "Validity check", "Discussion", "Original description"])

// What an analysis rewrite keeps: the evidence survives a later rewrite of the report.
let generated: [(heading: String, text: String)] = [("Summary", "New summary."), ("Likely causes", "- new cause")]
let rewritten = BugReportLayout.rewritten(closed.body, generated: generated, fallbackTitle: "List crashes")
let rewrittenSections = BugReportLayout.sections(rewritten)
check("a rewrite keeps the validity record as it was", rewrittenSections.first { $0.heading == BugValidity.sectionName }?.text == BugReportLayout.sections(closed.body).first { $0.heading == BugValidity.sectionName }?.text)
check("a rewrite replaces the analysis's own sections and keeps the discussion and the original description",
      rewrittenSections.map(\.heading) == ["", "Summary", "Likely causes", "Validity check", "Discussion", "Original description"]
      && rewritten.contains("New summary.") && !rewritten.contains("The list crashes when empty.") && rewritten.contains("Still happens for me.") && rewritten.contains("It crashes."))
check("a rewrite keeps the report's title", rewritten.hasPrefix("# List crashes"))
let handwritten = "# Hand written\n\nSomething is wrong.\n\n## My notes\n\nsee screenshot\n\n## Validity check\n\n**Outcome:** Inconclusive\n"
let adopted = BugReportLayout.rewritten(handwritten, generated: generated, fallbackTitle: "Hand written")
check("a hand-written report becomes the original description and still keeps the record",
      BugReportLayout.sections(adopted).map(\.heading) == ["", "Summary", "Likely causes", "Validity check", "Original description"] && adopted.contains("see screenshot"))
check("a report without a heading gets the fallback one", BugReportLayout.rewritten("text only", generated: generated, fallbackTitle: "T").hasPrefix("# T"))

// MARK: - The prompt and the note

let prompt = BugValidity.prompt(reportPath: report, report: "It crashes.", baseline: base, hints: ["abc1234 Fix BUG-001"])
check("the prompt names the baseline commit and says nothing uncommitted is visible", prompt.contains(mainTip.prefix(10)) && prompt.contains("nothing uncommitted") && prompt.contains("any other branch"))
check("the prompt says not reproducing is not evidence", prompt.contains("NOT \nevidence") || prompt.contains("is NOT"))
check("the prompt passes the commit hints as leads only", prompt.contains("abc1234 Fix BUG-001") && prompt.contains("never evidence by themselves"))
check("the schema allows exactly the three outcomes", ((BugValidity.schema["properties"] as? [String: Any])?["outcome"] as? [String: Any])?["enum"] as? [String] == ["still-present", "already-fixed", "inconclusive"])
let unsureNote = BugValidity.note(for: inconclusive)
check("the note for an inconclusive check keeps the uncertainty and its reason", unsureNote.contains("INCONCLUSIVE") && unsureNote.contains("Needs a running app.") && unsureNote.contains("do not present the bug as confirmed"))
check("the note for a failed closure does not claim a closure", BugValidity.note(for: good, closeError: "disk full").contains("could not be closed")
      && !BugValidity.note(for: good, closeError: "disk full").contains("closed automatically"))
check("the note for a present bug says so", BugValidity.note(for: BugValidity.Verdict(outcome: .stillPresent, reason: "crash", baseline: base)).contains("still present"))

// MARK: - The gate and the three ways in (REQ-001, REQ-003, REQ-004, DEC-004)

final class Trace { var events: [String] = []; var notes: [String] = [] }

func gate(_ trace: Trace, verdict: BugValidity.Verdict?, saveError: String? = nil) -> BugValidity.Gate {
    BugValidity.Gate(verify: { trace.events.append("verify"); return verdict },
                     save: { v in trace.events.append("save:\(v.outcome.rawValue)"); return saveError })
}
let present1 = BugValidity.Verdict(outcome: .stillPresent, reason: "crash", baseline: base)

// Investigate.
var t = Trace()
await BugValidity.Entry.investigate(gate: gate(t, verdict: present1)) { p in t.events.append("analyze"); t.notes.append(p.note) }
check("investigate: the check comes first, then the analysis", t.events == ["verify", "save:still-present", "analyze"])
check("investigate: the analysis is told the outcome", t.notes.first?.contains("still present") == true)

t = Trace()
await BugValidity.Entry.investigate(gate: gate(t, verdict: inconclusive)) { p in t.events.append("analyze"); t.notes.append(p.note) }
check("inconclusive: the status is kept, the analysis continues and is told the uncertainty", t.events == ["verify", "save:inconclusive", "analyze"] && t.notes.first?.contains("INCONCLUSIVE") == true)

t = Trace()
await BugValidity.Entry.investigate(gate: gate(t, verdict: good)) { _ in t.events.append("analyze") }
check("already fixed and saved: the investigation stops, nothing is analysed", t.events == ["verify", "save:already-fixed"])

t = Trace()
await BugValidity.Entry.investigate(gate: gate(t, verdict: good, saveError: "disk full")) { p in t.events.append("analyze"); t.notes.append(p.note) }
check("already fixed but the save failed: no stop, the analysis is told the closure failed", t.events == ["verify", "save:already-fixed", "analyze"] && t.notes.first?.contains("disk full") == true)

t = Trace()
await BugValidity.Entry.investigate(gate: gate(t, verdict: nil)) { _ in t.events.append("analyze") }
check("a stopped check runs nothing else", t.events == ["verify"])

// Answering a question.
t = Trace()
await BugValidity.Entry.answer(record: { t.events.append("record"); return true }, gate: gate(t, verdict: present1)) { _ in t.events.append("analyze") }
check("answer: the answer is saved, then the check, then the analysis", t.events == ["record", "verify", "save:still-present", "analyze"])

t = Trace()
await BugValidity.Entry.answer(record: { t.events.append("record"); return true }, gate: gate(t, verdict: good)) { _ in t.events.append("analyze") }
check("answer: an already-fixed report keeps the user's answer and stops", t.events == ["record", "verify", "save:already-fixed"])

t = Trace()
await BugValidity.Entry.answer(record: { t.events.append("record"); return false }, gate: gate(t, verdict: present1)) { _ in t.events.append("analyze") }
check("answer: when the answer could not be saved nothing else runs", t.events == ["record"])

// A discussion message.
t = Trace()
await BugValidity.Entry.discuss(record: { t.events.append("record"); return true }, gate: gate(t, verdict: present1),
                                reply: { p in t.events.append("reply"); t.notes.append(p.note); return true },
                                analyze: { p in t.events.append("analyze"); t.notes.append(p.note) })
check("discussion: message saved, then the check, and only then the reply and the analysis", t.events == ["record", "verify", "save:still-present", "reply", "analyze"])
check("discussion: the check runs once and the reply and the analysis share its outcome", t.events.filter { $0 == "verify" }.count == 1 && t.notes.count == 2 && t.notes[0] == t.notes[1])

t = Trace()
await BugValidity.Entry.discuss(record: { t.events.append("record"); return true }, gate: gate(t, verdict: good),
                                reply: { _ in t.events.append("reply"); return true }, analyze: { _ in t.events.append("analyze") })
check("discussion: an already-fixed report gets no reply and no analysis, and the message stays", t.events == ["record", "verify", "save:already-fixed"])

t = Trace()
await BugValidity.Entry.discuss(record: { t.events.append("record"); return true }, gate: gate(t, verdict: inconclusive),
                                reply: { _ in t.events.append("reply"); return true }, analyze: { _ in t.events.append("analyze") })
check("discussion: an inconclusive check still answers and analyses", t.events == ["record", "verify", "save:inconclusive", "reply", "analyze"])

t = Trace()
await BugValidity.Entry.discuss(record: { t.events.append("record"); return false }, gate: gate(t, verdict: present1),
                                reply: { _ in t.events.append("reply"); return true }, analyze: { _ in t.events.append("analyze") })
check("discussion: a message that could not be saved runs nothing", t.events == ["record"])

t = Trace()
await BugValidity.Entry.discuss(record: { t.events.append("record"); return true }, gate: gate(t, verdict: present1),
                                reply: { _ in t.events.append("reply"); return false }, analyze: { _ in t.events.append("analyze") })
check("discussion: a failed reply ends the flow as before", t.events == ["record", "verify", "save:still-present", "reply"])

// MARK: - The wiring in the sources

func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
let intake = source("MarkView/Models/FeatureIntake.swift")
let panel = source("MarkView/Views/FeaturePanelView.swift")
let validity = source("MarkView/Models/BugValidity.swift") + source("MarkView/Models/FeatureBugValidity.swift")
check("the sources are readable", !intake.isEmpty && !panel.isEmpty && !validity.isEmpty)
check("the three entry points go through the gate", count("validityGate(for: url)", in: intake) == 3
      && intake.contains("BugValidity.Entry.discuss") && intake.contains("BugValidity.Entry.answer") && intake.contains("BugValidity.Entry.investigate"))
check("the analysis is reached only through the entries", count("analyzeBug(url, validity:", in: intake) == 3 && !panel.contains("analyzeBug("))
check("selecting a bug starts no analysis: the only call from the panel is the Investigate button", count("investigateBug(", in: panel) == 1 && panel.contains("SmallButton(title: \"Investigate\""))
check("the reply to a discussion message is made only after the check", count("replyToBugDiscussion(", in: intake) == 2 && intake.contains("reply: { passed in"))
check("automatic closure never touches GitHub", !validity.contains("createIssue") && !validity.contains("commentOnIssue") && !validity.contains("closeIssue")
      && !validity.contains("updateIssue") && !validity.contains("gitHubClient(") && !validity.contains("IssueSync"))
check("the verification reads the export, not the project", source("MarkView/Models/FeatureBugValidity.swift").contains("readable: export.tree"))
check("the assistant stays read-only (no write tools were added)", !source("MarkView/Models/CLICompletion.swift").contains("\"Write\"") && !source("MarkView/Models/CLICompletion.swift").contains("\"Edit\""))

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("Bug validity check: main baseline, evidence rules, closure record, retention and the three entry points all hold.")
