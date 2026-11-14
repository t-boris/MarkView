import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

func makePlan(steps count: Int, controls: CockpitControls = CockpitControls()) -> CockpitPlan {
    let steps = (1...count).map { CockpitStep(title: "Step \($0)", agent: "Claude Code", assignment: "Do \($0)", completionCondition: "Done \($0)") }
    return CockpitPlan(goal: "Check the panel", controls: controls, scenarios: [], steps: steps, successCriteria: ["Done"],
                       unavailableOutcomes: [], alternatives: [], productionQA: nil)
}

func started(_ plan: CockpitPlan, at index: Int = 0, now: Date = t0) -> CockpitRun {
    var run = CockpitRun(plan: plan)
    precondition(run.start(approval: CockpitApproval(plan: plan, productionConfirmed: false)!, at: index, now: now))
    return run
}

// --- Altitude and distance
var plan = makePlan(steps: 4)
var run = started(plan)
var readings = CockpitReadings(run: run, live: true, now: at(1))
check(readings.altitude.done == 0 && readings.altitude.total == 4 && readings.altitude.fraction == 0, "a new run is on the ground")
check(readings.distance.stepsLeft == 4 && readings.distance.estimatedSeconds == nil, "no estimate before a step has passed")

check(run.completeCurrent(passed: true, detail: "ok", build: "", now: at(10)), "step 1 passes after 10 minutes")
readings = CockpitReadings(run: run, live: true, now: at(10))
check(readings.altitude.done == 1 && readings.altitude.fraction == 0.25, "one of four steps is a quarter of the altitude")
check(readings.distance.stepsLeft == 3 && readings.distance.estimatedSeconds == 3 * 600, "the estimate is the mean of the passed steps times the steps left")
readings = CockpitReadings(run: run, live: true, now: at(14))
check(readings.distance.estimatedSeconds == 3 * 600 - 240, "the running step has already used part of its share")
readings = CockpitReadings(run: run, live: true, now: at(100))
check(readings.distance.estimatedSeconds == 2 * 600, "a step that runs longer than the mean never makes the estimate negative")
readings = CockpitReadings(run: run, live: false, now: at(14))
check(readings.distance.estimatedSeconds == 3 * 600, "a saved run is not read against the clock")

var skipped = started(plan, at: 2)
readings = CockpitReadings(run: skipped, live: true, now: at(1))
check(readings.altitude.done == 2 && readings.distance.stepsLeft == 2, "steps before the starting step count as done")
check(readings.distance.estimatedSeconds == nil, "skipped steps give no duration to estimate from")
for _ in 0..<2 { _ = skipped.completeCurrent(passed: true, detail: "ok", build: "", now: at(2)) }
readings = CockpitReadings(run: skipped, live: false, now: at(3))
check(readings.distance.stepsLeft == 0 && readings.distance.estimatedSeconds == nil, "nothing is left at the destination")

// --- Fuel and turns
var limited = CockpitControls()
limited.timeLimitMinutes = 100
limited.fixCycleLimit = 4
run = started(makePlan(steps: 2, controls: limited))
readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 60 * 60, usedFixCycles: 1)
check(readings.fuel.band == .ok && readings.fuel.fraction == 0.6 && readings.turns.band == .ok && readings.turns.fraction == 0.25, "below 70% is ok")
readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 75 * 60, usedFixCycles: 3)
check(readings.fuel.band == .caution && readings.turns.band == .caution, "from 70% of the limit is caution")
readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 100 * 60, usedFixCycles: 4)
check(readings.fuel.band == .limit && readings.turns.band == .limit && readings.lamps.limitReached, "at the limit the lamp is lit")
readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 500 * 60)
check(readings.fuel.fraction == 1, "the needle stops at full")
run = started(makePlan(steps: 2))
readings = CockpitReadings(run: run, live: true, now: at(1), usedSeconds: 9_999, usedFixCycles: 99)
check(readings.fuel.limit == nil && readings.fuel.fraction == nil && readings.fuel.band == .ok && readings.turns.band == .ok && !readings.lamps.limitReached,
      "a quantity without a limit never warns")
readings = CockpitReadings(run: run, live: true, now: at(1))
check(readings.fuel.used == 0 && readings.turns.used == 0, "nothing used yet reads as zero")

// --- Wind
run = started(makePlan(steps: 3))
readings = CockpitReadings(run: run, live: true, now: at(1))
check(readings.wind.score == 0 && readings.wind.band == .calm && !readings.lamps.stepFailed, "a calm start")
run.noteRefusal("markview_create_bug refused: filing is off", now: at(2))
run.noteRefusal("markview_set_bug_status refused", now: at(3))
readings = CockpitReadings(run: run, live: true, now: at(4))
check(readings.wind.refusals == 2 && readings.wind.band == .breeze, "two refusals are a breeze")
readings = CockpitReadings(run: run, live: true, now: at(65), activity: at(64))
check(readings.wind.refusals == 0 && readings.wind.band == .calm, "refusals older than an hour no longer count")
readings = CockpitReadings(run: run, live: true, now: at(65))
check(readings.wind.refusals == 0 && readings.wind.silent && readings.wind.band == .breeze, "an hour of quiet is itself a little wind")
readings = CockpitReadings(run: run, live: false, now: at(5_000))
check(readings.wind.refusals == 2, "a saved run is judged as of its last activity, not as of today")
run.addExchange(CockpitSupervisorExchange(stepID: run.plan.steps[0].id.uuidString, asked: at(5), question: "q", answer: "", outOfScope: false, failed: true))
run.addExchange(CockpitSupervisorExchange(stepID: run.plan.steps[0].id.uuidString, asked: at(5), question: "q2", answer: "a", outOfScope: false, failed: false))
readings = CockpitReadings(run: run, live: true, now: at(6))
check(readings.wind.unanswered == 1 && readings.wind.score == 3 && readings.wind.band == .gusty, "an unanswered question adds wind; an answered one does not")
check(run.completeCurrent(passed: false, detail: "broken", build: "", now: at(7)), "a step fails")
readings = CockpitReadings(run: run, live: true, now: at(8))
check(readings.wind.failedSteps == 1 && readings.lamps.stepFailed && readings.lamps.paused && readings.wind.score == 4, "a failed step is wind, and lights two lamps")
check(CockpitReadings.windBand(0) == .calm && CockpitReadings.windBand(2) == .breeze && CockpitReadings.windBand(3) == .gusty
      && CockpitReadings.windBand(5) == .gusty && CockpitReadings.windBand(6) == .storm && CockpitReadings.windBand(40) == .storm, "wind bands")

// --- Pulse and silence
run = started(makePlan(steps: 2))
readings = CockpitReadings(run: run, live: true, now: at(1))
check(readings.pulse.band == .ok && readings.pulse.quietSeconds == 60 && !readings.lamps.silent, "a minute after the step began the pulse is fine")
readings = CockpitReadings(run: run, live: true, now: at(6))
check(readings.pulse.band == .caution, "five minutes of quiet is caution")
readings = CockpitReadings(run: run, live: true, now: at(21))
check(readings.pulse.band == .silent && readings.lamps.silent && readings.wind.silent && readings.wind.score == 1, "20 minutes of quiet is silence, and a little wind")
readings = CockpitReadings(run: run, live: true, now: at(21), activity: at(20))
check(readings.pulse.band == .ok, "a call of the agent that is too small to save still counts as a sign of life")
readings = CockpitReadings(run: run, live: false, now: at(21))
check(readings.pulse.band == .idle && readings.pulse.quietSeconds == nil && !readings.lamps.silent, "a run that is not going has no pulse")

// --- Lamps and the supervisor lever
var noSupervisor = CockpitControls()
noSupervisor.supervisor = false
run = started(makePlan(steps: 2, controls: noSupervisor))
check(CockpitReadings(run: run, live: true, now: at(1)).lamps.supervisorOff, "a supervisor that the plan leaves off lights its lamp")
run = started(makePlan(steps: 2))
check(!CockpitReadings(run: run, live: true, now: at(1)).lamps.supervisorOff, "a supervisor that is on does not")
var cut = CockpitLiveSwitches()
cut.supervisorCut = true
check(CockpitReadings(run: run, live: true, now: at(1), cuts: cut).lamps.supervisorOff, "a lever that switches the supervisor off lights it")
run.setSwitches(cut, now: at(2))
check(CockpitReadings(run: run, live: false, now: at(3)).lamps.supervisorOff, "a saved run remembers the lever")
run = started(makePlan(steps: 2))
run.pauseAtBoundary(reason: "paused by test", now: at(1))
check(CockpitReadings(run: run, live: true, now: at(2)).lamps.paused, "a paused run lights its lamp")
print("all instrument checks passed")
