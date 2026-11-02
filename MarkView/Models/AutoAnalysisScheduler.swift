import Foundation

/// When the automatic code analysis of a project may refresh after its files changed
/// (DEC-003 of automatic-code-architecture): a local rescan after 60 seconds of quiet, an
/// AI run at most once per 15 minutes, nothing while a run is active, nothing with the
/// switch off or above the size cap. Pure: timestamps in, a decision out. `ArchitectureStore`
/// keeps the clock and acts on the decision; `tools/tests/auto-analysis-scheduler-tests.sh`
/// covers the decision table.
struct AutoAnalysisScheduler: Equatable {
    /// Quiet time after the last change before anything runs.
    static let quietPeriod: TimeInterval = 60
    /// Least time between two AI runs of one project; local rescans are not bound by it.
    static let aiRunInterval: TimeInterval = 15 * 60
    /// Projects with more source files are left to the manual Refresh.
    static let maximumSourceFiles = 5000

    enum Decision: Equatable {
        /// Nothing to do, and why (switch off, size cap, no change recorded).
        case nothing(reason: String)
        /// A run is active: decide again when it ends.
        case waitForRun
        /// The quiet period is not over: decide again at this date.
        case wait(until: Date)
        /// Rescan locally now; an AI run is allowed again at this date.
        case rescan(aiAllowedAt: Date)
        /// Rescan and, when the source changed, run the AI analysis.
        case analyze
    }

    /// The `xray.autoAnalyze` switch.
    var enabled = true
    /// Source files counted by the last scan; nil before the first scan.
    var sourceFileCount: Int? = nil
    /// Last change of the project's files that no AI run has handled yet.
    var lastChange: Date? = nil
    /// When the last local rescan for `lastChange` started; nil before the first one.
    var lastRescan: Date? = nil
    /// When the last AI run started; nil before the first one.
    var lastAIRun: Date? = nil
    /// A scan or analysis is in progress.
    var runActive = false

    static let switchOffReason = "Automatic analysis is off in Settings"

    static func sizeCapReason(_ count: Int) -> String {
        "\(count) source files exceed the automatic limit of \(maximumSourceFiles); use Refresh to analyze"
    }

    /// Whether a project of `count` source files is analyzed automatically.
    static func exceedsSizeCap(_ count: Int) -> Bool { count > maximumSourceFiles }

    func decision(at now: Date) -> Decision {
        guard enabled else { return .nothing(reason: Self.switchOffReason) }
        if let count = sourceFileCount, Self.exceedsSizeCap(count) { return .nothing(reason: Self.sizeCapReason(count)) }
        guard let lastChange else { return .nothing(reason: "No change recorded") }
        if runActive { return .waitForRun }
        let quietUntil = lastChange.addingTimeInterval(Self.quietPeriod)
        if now < quietUntil { return .wait(until: quietUntil) }
        guard let lastAIRun else { return .analyze }
        let aiAllowedAt = lastAIRun.addingTimeInterval(Self.aiRunInterval)
        if now >= aiAllowedAt { return .analyze }
        // Within the interval: one local rescan per change, then wait for the AI slot.
        if let lastRescan, lastRescan >= lastChange { return .wait(until: aiAllowedAt) }
        return .rescan(aiAllowedAt: aiAllowedAt)
    }
}
