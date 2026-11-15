import Foundation

/// What one Cockpit step has used of the run's limits. Foundation only: tools/tests/cockpit-policy-tests.sh checks it.
///
/// Time is measured by the app against the clock, not reported by the agent. A fix cycle is counted two ways and the larger count
/// wins: the gate sees the agent move a bug into fixing, and a progress report lists a fix not seen before in this step. Direct
/// edits by the agent that it never reports cannot be seen.
struct CockpitStepMeter: Equatable {
    var cycleLimit: Int?
    /// Fix cycles the run's earlier steps used.
    var cyclesBefore: Int
    private(set) var gateCycles = 0
    private(set) var reportedPasses: Set<Int> = []
    private var seenFixes: Set<String> = []

    init(cycleLimit: Int?, cyclesBefore: Int) {
        self.cycleLimit = cycleLimit
        self.cyclesBefore = cyclesBefore
    }

    var stepCycles: Int { max(gateCycles, reportedPasses.count) }
    var totalCycles: Int { cyclesBefore + stepCycles }
    /// True once a cycle beyond the limit has started.
    var overCycleLimit: Bool { cycleLimit.map { totalCycles > $0 } ?? false }

    mutating func noteGate(cycles count: Int) { gateCycles = max(gateCycles, count) }

    /// A report that names a fix not named before in this step counts its pass as a fix cycle. Fixes may be listed cumulatively.
    mutating func noteReport(pass: Int, fixes: [String]) {
        let fresh = Set(fixes).subtracting(seenFixes)
        guard !fresh.isEmpty else { return }
        seenFixes.formUnion(fresh)
        reportedPasses.insert(pass)
    }

    /// Seconds left of a time limit given the seconds already used; nil when there is no limit. Zero or less means none left.
    static func remainingSeconds(limitMinutes: Int?, used: Double) -> Double? {
        limitMinutes.map { Double($0) * 60 - used }
    }
}
