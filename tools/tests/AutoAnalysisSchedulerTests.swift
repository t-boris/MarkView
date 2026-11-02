import Foundation

// Test main for AutoAnalysisScheduler.swift, run by tools/tests/auto-analysis-scheduler-tests.sh.
// The decision table of DEC-003 (automatic-code-architecture): quiet period, AI run interval,
// active run, switch off, size cap and the first run.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL line \(line): \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

let base = Date(timeIntervalSince1970: 1_790_000_000)
let minute: TimeInterval = 60
func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

typealias Decision = AutoAnalysisScheduler.Decision

// Constants of DEC-003
expect(AutoAnalysisScheduler.quietPeriod, 60, "60 s of quiet")
expect(AutoAnalysisScheduler.aiRunInterval, 15 * minute, "15 min between AI runs")
expect(AutoAnalysisScheduler.maximumSourceFiles, 5000, "5000 source files at most")
expect(AutoAnalysisScheduler.exceedsSizeCap(5000), false, "5000 files are within the cap")
expect(AutoAnalysisScheduler.exceedsSizeCap(5001), true, "5001 files exceed the cap")

// Nothing recorded: nothing to do
var scheduler = AutoAnalysisScheduler()
expect(scheduler.decision(at: base), .nothing(reason: "No change recorded"), "no change, no run")

// First run: a change, the quiet period, no AI run yet
scheduler.lastChange = base
expect(scheduler.decision(at: at(10)), .wait(until: at(60)), "within the quiet period: wait until it ends")
expect(scheduler.decision(at: at(59.9)), .wait(until: at(60)), "just before the quiet period ends")
expect(scheduler.decision(at: at(60)), .analyze, "first run analyzes once the project is quiet")
expect(scheduler.decision(at: at(3600)), .analyze, "a late check still analyzes")

// A later change restarts the quiet period
scheduler.lastChange = at(40)
expect(scheduler.decision(at: at(60)), .wait(until: at(100)), "a newer change moves the deadline")
expect(scheduler.decision(at: at(100)), .analyze, "quiet again after the newer change")

// AI run interval: local rescans in between, AI again after 15 minutes
scheduler = AutoAnalysisScheduler(lastChange: at(5 * minute), lastAIRun: base)
expect(scheduler.decision(at: at(6 * minute)), .rescan(aiAllowedAt: at(15 * minute)),
       "quiet but within 15 min of the last AI run: rescan locally")
expect(scheduler.decision(at: at(14 * minute + 59)), .rescan(aiAllowedAt: at(15 * minute)), "still within the interval")
expect(scheduler.decision(at: at(15 * minute)), .analyze, "the interval has passed: AI run")
expect(scheduler.decision(at: at(5 * minute + 30)), .wait(until: at(6 * minute)),
       "the quiet period applies before the interval rule")

// One local rescan per change inside the interval, then wait for the AI slot
scheduler = AutoAnalysisScheduler(lastChange: at(5 * minute), lastRescan: at(6 * minute), lastAIRun: base)
expect(scheduler.decision(at: at(7 * minute)), .wait(until: at(15 * minute)),
       "already rescanned for this change: wait until the AI run is allowed")
expect(scheduler.decision(at: at(15 * minute)), .analyze, "the AI run follows when allowed")
scheduler.lastChange = at(8 * minute)
expect(scheduler.decision(at: at(9 * minute)), .rescan(aiAllowedAt: at(15 * minute)),
       "a newer change gets its own rescan")
scheduler = AutoAnalysisScheduler(lastChange: at(5 * minute), lastRescan: at(2 * minute), lastAIRun: base)
expect(scheduler.decision(at: at(7 * minute)), .rescan(aiAllowedAt: at(15 * minute)),
       "a rescan older than the change does not count")

// Active run: wait for it, whatever the timestamps say
scheduler = AutoAnalysisScheduler(lastChange: base, runActive: true)
expect(scheduler.decision(at: at(3600)), .waitForRun, "a run in progress postpones the decision")
scheduler.runActive = false
expect(scheduler.decision(at: at(3600)), .analyze, "the same state once the run ended")
scheduler = AutoAnalysisScheduler(lastChange: base, lastAIRun: at(30), runActive: true)
expect(scheduler.decision(at: at(90)), .waitForRun, "active run beats the rescan decision")

// Switch off: nothing, even with a pending change and a free slot
scheduler = AutoAnalysisScheduler(enabled: false, lastChange: base)
expect(scheduler.decision(at: at(3600)), .nothing(reason: AutoAnalysisScheduler.switchOffReason), "switch off")
scheduler.runActive = true
expect(scheduler.decision(at: at(3600)), .nothing(reason: AutoAnalysisScheduler.switchOffReason),
       "switch off is checked before the active run")

// Size cap: nothing above 5000 source files, normal below
scheduler = AutoAnalysisScheduler(sourceFileCount: 5001, lastChange: base)
expect(scheduler.decision(at: at(3600)), .nothing(reason: AutoAnalysisScheduler.sizeCapReason(5001)), "above the size cap")
scheduler.sourceFileCount = 5000
expect(scheduler.decision(at: at(3600)), .analyze, "at the size cap the project is analyzed")
scheduler.sourceFileCount = nil
expect(scheduler.decision(at: at(3600)), .analyze, "an unknown count does not block the first run")

// Reasons are plain sentences without file contents
expect(AutoAnalysisScheduler.sizeCapReason(7000).contains("7000"), true, "the reason names the count")
expect(AutoAnalysisScheduler.sizeCapReason(7000).contains("5000"), true, "the reason names the limit")

print(failures == 0 ? "OK: \(checks) checks passed" : "FAILED: \(failures) of \(checks) checks")
exit(failures == 0 ? 0 : 1)
