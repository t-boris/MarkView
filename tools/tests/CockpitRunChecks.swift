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
print("All cockpit run checks passed")
