import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}
let first = CockpitStep(title: "Prerequisite", agent: "Codex", assignment: "Check", completionCondition: "Available", isPrerequisite: true)
let second = CockpitStep(title: "Work", agent: "Claude Code", assignment: "Implement", completionCondition: "Done")
let plan = CockpitPlan(goal: "Work", controls: CockpitControls(), scenarios: [], steps: [first, second], successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
let approved = CockpitApproval(plan: plan, productionConfirmed: false)!
var run = CockpitRun(plan: plan)
check(!run.start(approval: approved, at: 9), "an invalid selected step is refused")
check(run.start(approval: approved, at: 0), "the approved plan starts")
check(run.completeCurrent(passed: false, detail: "Unavailable", build: "build-1") && run.status == .paused && run.currentIndex == 0, "a failed prerequisite pauses before the next step")
check(run.retryPrerequisite() && run.status == .running, "the prerequisite can be retried")
check(run.completeCurrent(passed: true, detail: "Available", build: "build-1") && run.currentIndex == 1, "passing advances to the next step")
check(run.completeCurrent(passed: true, detail: "Done", build: "build-2") && run.status == .finished, "the final result finishes the run")
check(run.results.count == 3 && run.results.first?.plan == plan && run.results.last?.build == "build-2", "results retain their plan and build")
check(run.start(approval: approved, at: 1) && run.steps[0].status == .skipped, "a user can start at any selected step")
run.pauseAtBoundary(reason: "Paused by user")
check(run.status == .paused && run.resumeAtBoundary() && run.status == .running, "a user can pause and resume at a safe boundary")
var changed = plan; changed.goal = "Different"
var other = CockpitRun(plan: changed)
check(!other.start(approval: approved, at: 0), "an approval cannot start a changed plan")
let restored = try JSONDecoder().decode(CockpitRun.self, from: JSONEncoder().encode(run))
check(restored == run, "run state and historical results round-trip")
var recovered = restored
recovered.prepareAfterRestart()
check(recovered.status == .paused && recovered.steps[1].status == .interrupted && !recovered.resumeAtBoundary(),
      "recovery pauses an interrupted step without replaying it")
var withEvidence = run
let evidence = CockpitProgress(passNumber: 1, activity: "Partial work", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "File changed", blockers: [], buildLogPath: nil)
check(withEvidence.recordProgress(evidence, stepID: second.id), "partial step evidence is recorded while running")
withEvidence.prepareAfterRestart()
var chooseOther = withEvidence
check(chooseOther.continueAfterInterruption(plan: plan, approval: approved, at: 0) && chooseOther.currentIndex == 0,
      "the person may choose a different step instead of repeating the interrupted one")
check(withEvidence.steps[1].progress == evidence && withEvidence.continueAfterInterruption(plan: plan, approval: approved, at: 1),
      "the person can explicitly choose to repeat an interrupted step after seeing its evidence")
check(withEvidence.results.last?.interrupted == true && withEvidence.results.last?.progress == evidence,
      "the continued run retains the interrupted step's evidence without treating it as completed")
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
try CockpitRunStore.save(run, root: root)
let diskRun = try CockpitRunStore.load(run.id, root: root)
check(diskRun.status == .paused && diskRun.steps[1].status == .interrupted && diskRun.results == run.results,
      "disk recovery preserves results and presents an interrupted run paused")
let listed = try CockpitRunStore.loadAll(root: root)
check(listed.count == 1 && listed[0].id == run.id && listed[0].status == .paused && listed[0].waitingReason.contains("background processes"),
      "listing saved runs warns about interruption and detached processes without resuming")
var revising = CockpitRun(plan: plan)
check(revising.start(approval: approved, at: 0), "a revisable run starts")
var revisedPlan = plan; revisedPlan.goal = "Revised goal"
let revisedApproval = CockpitApproval(plan: revisedPlan, productionConfirmed: false)!
check(revising.queueRevision(plan: revisedPlan, approval: revisedApproval, at: 1, fingerprint: "revision"), "a reviewed revision is persisted as pending")
check(!revising.applyRevision(fingerprint: "wrong"), "an unexpected revision cannot be applied")
check(revising.completeCurrent(passed: true, detail: "Old plan", build: "b1") && revising.applyRevision(fingerprint: "revision"), "the revision applies after the previous step")
check(revising.plan == revisedPlan && revising.currentIndex == 1 && revising.results.first?.plan == plan,
      "earlier results retain their original plan after revision")

// MARK: Timeline, times and silence

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
var timed = CockpitRun(plan: plan)
check(timed.events == nil && timed.startedAt == nil && timed.lastSignal == nil, "a new run has no history yet")
check(timed.start(approval: approved, at: 0, now: at(0)), "a timed run starts")
check(timed.startedAt == at(0) && timed.steps[0].startedAt == at(0), "the run and its first step remember when they began")
check(timed.events?.map(\.kind) == [.started, .stepStarted], "starting writes the start and the first step")
check(timed.quietSeconds(now: at(5)) == 300, "silence counts from the step's start when nothing has been seen")
check(!timed.isSilent(now: at(19)) && timed.isSilent(now: at(20)), "the warning is due at the threshold, not before")
let report = CockpitProgress(passNumber: 1, activity: "Reading the code", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
check(timed.recordProgress(report, stepID: first.id, now: at(10)), "progress is recorded")
check(timed.lastSignal == at(10) && timed.quietSeconds(now: at(15)) == 300, "a report is a sign of life")
check(timed.events?.last?.kind == .report && timed.events?.last?.text.contains("Reading the code") == true, "a new activity is a report event")
let eventsBefore = timed.events?.count
check(timed.recordProgress(report, stepID: first.id, now: at(11)) && timed.events?.count == eventsBefore, "the same report again adds no event")
var withBug = report; withBug.bugs = ["BUG-1"]; withBug.fixes = ["BUG-0"]; withBug.blockers = ["Server down"]
check(timed.recordProgress(withBug, stepID: first.id, now: at(12)), "a report with findings is recorded")
let kinds = timed.events?.suffix(3).map(\.kind)
check(kinds == [.bug, .fix, .report], "a new bug, a confirmed fix and a blocker each get an event")
timed.noteSignal(at: at(30))
check(timed.lastSignal == at(30), "a tool call is a sign of life")
timed.noteSignal(at: at(25))
check(timed.lastSignal == at(30), "an older sign of life does not move the clock back")
timed.noteRefusal("markview_flow_new refused: outside this step", now: at(31))
check(timed.events?.last?.kind == .refusal && timed.lastSignal == at(31), "a refusal is an event and a sign of life")
check(timed.quietSeconds(now: at(32), activity: at(31.5)) == 30, "an unsaved tool call counts too")
timed.addExchange(CockpitSupervisorExchange(stepID: first.id.uuidString, asked: at(33), question: "Which branch?", answer: "main", outOfScope: false, failed: false))
check(timed.events?.last?.kind == .question && timed.events?.last?.text.contains("Which branch?") == true && timed.lastSignal == at(33), "a question the supervisor answered is an event and a sign of life")
check(timed.completeCurrent(passed: true, detail: "Available\nsecond line", build: "b", now: at(40)), "the step passes")
check(timed.steps[0].startedAt == at(0) && timed.steps[0].endedAt == at(40), "a step keeps when it began and ended")
check(timed.events?.suffix(2).map(\.kind) == [.stepPassed, .stepStarted] && timed.events?.suffix(2).first?.text == "Available", "a passed step ends and the next one begins; the event keeps the first line only")
check(timed.steps[1].startedAt == at(40) && timed.quietSeconds(now: at(45)) == 300, "silence restarts with each step")
timed.pauseAtBoundary(reason: "Paused by user", now: at(50))
check(timed.events?.last?.kind == .paused && timed.quietSeconds(now: at(90)) == nil, "a paused run is not silent")
check(timed.resumeAtBoundary(now: at(60)) && timed.events?.last?.kind == .resumed, "resuming is an event")
timed.stop(now: at(70))
timed.stop(now: at(71))
check(timed.events?.filter { $0.kind == .stopped }.count == 1, "stopping twice is one event")
check(timed.events?.allSatisfy { $0.stepID == nil || [first.id.uuidString, second.id.uuidString].contains($0.stepID!) } == true, "events name steps by their plan id")
let timedBack = try JSONDecoder().decode(CockpitRun.self, from: JSONEncoder().encode(timed))
check(timedBack == timed, "a run with a timeline round-trips")

// A failed step that pauses the run is not announced twice, and a retry is dated when it begins.
var retrying = CockpitRun(plan: plan)
check(retrying.start(approval: approved, at: 0, now: at(0)) && retrying.completeCurrent(passed: false, detail: "Unavailable", build: "b", now: at(5)), "a prerequisite fails")
let eventsAtFailure = retrying.events?.count
retrying.notePauseState(paused: true, reason: "Unavailable", now: at(5))
check(retrying.events?.count == eventsAtFailure, "the coordinator's pause after a failed step adds no second event")
retrying.notePauseState(paused: false, reason: "", now: at(9))
check(retrying.events?.last?.kind == .resumed && retrying.steps[0].startedAt == at(9) && retrying.steps[0].endedAt == nil, "a retry begins when the person asks for it")
check(retrying.retryPrerequisite() && retrying.status == .running, "the retry is applied when its result arrives")
var userPause = CockpitRun(plan: plan)
check(userPause.start(approval: approved, at: 0, now: at(0)), "a run to pause")
userPause.notePauseState(paused: true, reason: "Paused by user", now: at(3))
check(userPause.events?.last?.kind == .paused && userPause.events?.last?.text == "Paused by user", "a pause by the person is an event")

// Old runs have none of it.
let oldRun = CockpitRun(plan: plan)
var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRun)) as! [String: Any]
for key in ["startedAt", "lastSignal", "events"] { oldJSON.removeValue(forKey: key) }
let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
let oldDecoded = try JSONDecoder().decode(CockpitRun.self, from: oldData)
check(oldDecoded.events == nil && oldDecoded.startedAt == nil && oldDecoded.began == nil && oldDecoded.lastKnownActivity == nil, "a run saved before the timeline existed decodes without it")
var oldStepJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CockpitRun.StepRecord(stepID: first.id))) as! [String: Any]
oldStepJSON.removeValue(forKey: "startedAt"); oldStepJSON.removeValue(forKey: "endedAt")
check((try? JSONDecoder().decode(CockpitRun.StepRecord.self, from: JSONSerialization.data(withJSONObject: oldStepJSON))) != nil, "a step record without times decodes")

// The timeline is bounded.
var crowded: [CockpitRunEvent] = []
for i in 0..<(CockpitRunEvent.capacity + 25) { crowded = CockpitRunEvent.appending(CockpitRunEvent(at: at(Double(i)), kind: .report, stepID: nil, text: "event \(i)"), to: crowded) }
check(crowded.count == CockpitRunEvent.capacity && crowded.last?.text == "event \(CockpitRunEvent.capacity + 24)" && crowded.first?.text == "event 25", "the timeline keeps the latest events")
let long = CockpitRunEvent.appending(CockpitRunEvent(at: t0, kind: .report, stepID: nil, text: String(repeating: "x", count: 5_000)), to: [])
check(long.first?.text.count == CockpitRunEvent.textLimit, "an event text is cut to one line's worth")

// A run read back after a restart keeps its history, and the interruption is dated when it was last alive.
var interrupted = CockpitRun(plan: plan)
check(interrupted.start(approval: approved, at: 0, now: at(0)) && interrupted.recordProgress(report, stepID: first.id, now: at(12)), "a run to interrupt")
interrupted.prepareAfterRestart(now: interrupted.lastKnownActivity ?? at(99))
check(interrupted.events?.last?.kind == .paused && interrupted.events?.last?.at == at(12) && interrupted.steps[0].endedAt == at(12), "an interruption is dated from the last sign of life")

// MARK: Notifications

var live = CockpitRun(plan: plan)
check(live.start(approval: approved, at: 0, now: at(0)), "a run to watch")
check(CockpitNotice.transition(from: live, to: live) == nil, "nothing changed, nothing to say")
var pausedRun = live; pausedRun.pauseAtBoundary(reason: "Paused by user", now: at(1))
check(CockpitNotice.transition(from: live, to: pausedRun)?.kind == .paused, "a pause is announced")
check(CockpitNotice.transition(from: live, to: pausedRun, limitReached: true)?.kind == .limit, "a pause caused by a limit is announced as a limit")
var failed = live; _ = failed.completeCurrent(passed: false, detail: "Unavailable\nmore", build: "b", now: at(2))
check(CockpitNotice.transition(from: live, to: failed)?.kind == .stepFailed && CockpitNotice.transition(from: live, to: failed)?.body.contains("Unavailable") == true, "a failed step is announced with its reason")
var done = live; _ = done.completeCurrent(passed: true, detail: "ok", build: "b", now: at(3)); _ = done.completeCurrent(passed: true, detail: "ok", build: "b", now: at(4))
check(CockpitNotice.transition(from: live, to: done)?.kind == .finished, "a finished run is announced")
check(CockpitNotice.transition(from: live, to: done)?.body == "Work", "an untitled run is named by its goal in a notice")
var namedPlan = plan; namedPlan.title = "Weekly release checklist"
var namedLive = CockpitRun(plan: namedPlan); _ = namedLive.start(approval: CockpitApproval(plan: namedPlan, productionConfirmed: false)!, at: 0, now: at(0))
var namedDone = namedLive; _ = namedDone.completeCurrent(passed: true, detail: "ok", build: "b", now: at(3)); _ = namedDone.completeCurrent(passed: true, detail: "ok", build: "b", now: at(4))
check(CockpitNotice.transition(from: namedLive, to: namedDone)?.body == "Weekly release checklist", "a titled run is named by its title in a notice")
check(CockpitNotice.transition(from: done, to: done) == nil, "a finished run is announced once")
var passing = live; _ = passing.completeCurrent(passed: true, detail: "ok", build: "b", now: at(3))
check(CockpitNotice.transition(from: live, to: passing) == nil, "a step that passes does not interrupt the person")
var stopped = live; stopped.stop(now: at(5))
check(CockpitNotice.transition(from: live, to: stopped)?.kind == .stopped, "a stop is announced")
check(CockpitNotice.transition(from: nil, to: live) == nil, "a run seen for the first time is not announced while it runs")
check(CockpitNotice.transition(from: nil, to: pausedRun)?.kind == .paused, "a run first seen paused is announced")
let quiet = CockpitNotice.silence(of: live, minutes: 25)
check(quiet?.kind == .silent && quiet?.body.contains("25 min") == true, "silence is announced with its length")
check(CockpitNotice.silence(of: pausedRun, minutes: 25) == nil, "a paused run is never called silent")
check(quiet?.key == CockpitNotice.silence(of: live, minutes: 45)?.key, "one quiet stretch is one notice, however long it lasts")
// MARK: levers and notes (DEC-028)

var levered = CockpitRun(plan: plan)
check(levered.start(approval: approved, at: 0, now: Date(timeIntervalSince1970: 1_000)), "a run to move levers on")
var fixOff = CockpitLiveSwitches(); fixOff.fixBugsCut = true
levered.setSwitches(fixOff, now: Date(timeIntervalSince1970: 1_100))
check(levered.switches == fixOff && levered.events?.last?.kind == .switched && levered.events?.last?.text == "Fixing bugs was switched off by you.",
      "switching a lever off is kept and goes on the timeline")
let eventCount = levered.events?.count ?? 0
levered.setSwitches(fixOff, now: Date(timeIntervalSince1970: 1_200))
check(levered.events?.count == eventCount, "the same lever state is not logged twice")
levered.setSwitches(CockpitLiveSwitches(), now: Date(timeIntervalSince1970: 1_300))
check(levered.switches == nil && levered.events?.last?.text == "Fixing bugs was switched back on.", "a lever put back is logged and leaves no cuts")
levered.setSwitches(fixOff, now: Date(timeIntervalSince1970: 1_400))
let note = CockpitCuratorNote(at: Date(timeIntervalSince1970: 1_500), text: "  Keep the runs short.  ")
levered.addNote(note)
levered.addNote(note)
check(levered.notes?.count == 1 && levered.notes?.first?.text == "Keep the runs short." && levered.events?.last?.kind == .note, "a note is kept once, trimmed, and goes on the timeline")
levered.addNote(CockpitCuratorNote(at: Date(), text: "   "))
check(levered.notes?.count == 1, "an empty note is not kept")
let leveredBack = try JSONDecoder().decode(CockpitRun.self, from: JSONEncoder().encode(levered))
check(leveredBack == levered && leveredBack.switches == fixOff && leveredBack.notes == levered.notes, "levers and notes round-trip with the run")

// A run saved before levers and notes existed has neither key.
var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(levered)) as! [String: Any]
legacy.removeValue(forKey: "switches"); legacy.removeValue(forKey: "notes")
let legacyRun = try JSONDecoder().decode(CockpitRun.self, from: JSONSerialization.data(withJSONObject: legacy))
check(legacyRun.switches == nil && legacyRun.notes == nil && legacyRun.status == levered.status, "a run saved before levers and notes still loads")

// Where a note has got to.
var delivered = CockpitRun(plan: plan)
_ = delivered.start(approval: approved, at: 0, now: Date(timeIntervalSince1970: 2_000))
let early = CockpitCuratorNote(at: Date(timeIntervalSince1970: 2_100), text: "early")
delivered.addNote(early)
check(delivered.delivery(of: early).isQueued, "a note nobody has used yet is queued")
delivered.addExchange(CockpitSupervisorExchange(stepID: first.id.uuidString, asked: Date(timeIntervalSince1970: 2_200), question: "q", answer: "a", outOfScope: false, failed: false))
check(delivered.delivery(of: early) == CockpitRun.NoteDelivery(answersAfter: 1, briefedStep: nil), "a supervisor answer after the note means it was heard")
_ = delivered.completeCurrent(passed: true, detail: "ok", build: "", now: Date(timeIntervalSince1970: 2_300))
check(delivered.delivery(of: early).briefedStep == 2 && !delivered.delivery(of: early).isQueued, "the step that begins after the note carries it in its briefing")
check(delivered.delivery(of: CockpitCuratorNote(at: Date(timeIntervalSince1970: 3_000), text: "late")).isQueued, "a note sent after everything is queued")

print("All cockpit run checks passed")
