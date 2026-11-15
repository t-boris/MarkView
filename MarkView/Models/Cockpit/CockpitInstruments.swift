import Foundation

/// What the instrument panel of the run screen shows (DEC-028, REQ-009), computed from the run alone.
/// Foundation only: tools/tests/cockpit-instruments-tests.sh compiles this file with the run model and checks every reading.
///
/// Every reading is a real value of the run, or a stated convention over real values. Nothing is simulated, and what MarkView does
/// not measure (tokens, cost, context use) has no instrument.
struct CockpitReadings: Equatable {
    /// How close a limited quantity is to its limit. A quantity without a limit is always `ok`.
    enum Band: String, Equatable { case ok, caution, limit }
    /// The resistance the run has met, from nothing to a lot.
    enum WindBand: String, Equatable { case calm, breeze, gusty, storm }
    enum PulseBand: String, Equatable { case idle, ok, caution, silent }

    /// How far up the plan the run is: steps passed or skipped of all steps.
    struct Altitude: Equatable {
        var done: Int
        var total: Int
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    /// What is left: steps, and an estimate of the time they take, from the steps that have already passed.
    struct Distance: Equatable {
        var stepsLeft: Int
        var total: Int
        /// nil until a step has passed (nothing to estimate from) and when no step is left.
        var estimatedSeconds: Double?
    }

    /// A quantity the plan may limit: agent time in seconds (fuel) or fix cycles (turns).
    struct Gauge: Equatable {
        var used: Double
        var limit: Double?
        var band: Band
        /// nil without a limit.
        var fraction: Double? { limit.map { $0 > 0 ? min(1, used / $0) : 1 } }
    }

    /// The resistance met: what the gate refused and the supervisor could not answer in the last hour, steps that failed or were
    /// interrupted, and silence. The score is the sum; the counts are shown beside the dial.
    struct Wind: Equatable {
        var refusals: Int
        var failedSteps: Int
        var unanswered: Int
        var silent: Bool
        var score: Int
        var band: WindBand
    }

    /// How long the running step's agent has been quiet.
    struct Pulse: Equatable {
        var quietSeconds: Double?
        var band: PulseBand
    }

    /// The annunciator lamps. The banners of the run screen say the same in words and carry the actions.
    struct Lamps: Equatable {
        var paused: Bool
        var stepFailed: Bool
        var limitReached: Bool
        var silent: Bool
        var supervisorOff: Bool
    }

    var altitude: Altitude
    var distance: Distance
    var fuel: Gauge
    var turns: Gauge
    var wind: Wind
    var pulse: Pulse
    var lamps: Lamps

    /// Refusals and unanswered questions older than this no longer count as wind.
    static let windWindow: TimeInterval = 3_600
    /// A limited quantity is in `caution` from this share of its limit.
    static let cautionShare = 0.7

    /// `live`: the run is going now (its clock runs and silence can be told); a saved run is read as it ended.
    /// `usedSeconds`, `usedFixCycles`, `cuts` and `activity` are the live values the execution keeps ahead of the saved record.
    init(run: CockpitRun, live: Bool, now: Date, usedSeconds: Double? = nil, usedFixCycles: Int? = nil,
         cuts: CockpitLiveSwitches? = nil, activity: Date? = nil) {
        let controls = run.plan.controls
        let steps = run.steps
        let done = steps.filter { $0.status == .passed || $0.status == .skipped }.count
        altitude = Altitude(done: done, total: steps.count)

        let left = steps.count - done
        var estimate: Double?
        let durations = steps.compactMap { step -> Double? in
            guard step.status == .passed, let start = step.startedAt, let end = step.endedAt else { return nil }
            return max(0, end.timeIntervalSince(start))
        }
        if left > 0, !durations.isEmpty {
            let mean = durations.reduce(0, +) / Double(durations.count)
            var remaining = mean * Double(left)
            // The step in progress has already used part of its share.
            if live, let index = run.currentIndex, steps.indices.contains(index), steps[index].status == .running,
               let started = steps[index].startedAt {
                remaining -= min(max(0, now.timeIntervalSince(started)), mean)
            }
            estimate = max(0, remaining)
        }
        distance = Distance(stepsLeft: left, total: steps.count, estimatedSeconds: estimate)

        let seconds = usedSeconds ?? run.activeSeconds ?? 0
        let secondsLimit = controls.timeLimitMinutes.map { Double($0) * 60 }
        fuel = Gauge(used: seconds, limit: secondsLimit, band: Self.band(used: seconds, limit: secondsLimit))
        let cycles = Double(usedFixCycles ?? run.fixCyclesUsed ?? 0)
        let cycleLimit = controls.fixCycleLimit.map { Double($0) }
        turns = Gauge(used: cycles, limit: cycleLimit, band: Self.band(used: cycles, limit: cycleLimit))

        // A saved run is judged as of its last activity, so reopening it later does not make old trouble look new.
        let reference = live ? now : (run.lastKnownActivity ?? now)
        let since = reference.addingTimeInterval(-Self.windWindow)
        let refusals = (run.events ?? []).filter { $0.kind == .refusal && $0.at >= since }.count
        let failed = steps.filter { $0.status == .failed || $0.status == .interrupted }.count
        let unanswered = (run.exchanges ?? []).filter { $0.failed && $0.asked >= since }.count
        let silent = live && run.isSilent(now: now, activity: activity)
        let score = refusals + failed + unanswered + (silent ? 1 : 0)
        wind = Wind(refusals: refusals, failedSteps: failed, unanswered: unanswered, silent: silent, score: score, band: Self.windBand(score))

        let quiet = live ? run.quietSeconds(now: now, activity: activity) : nil
        let pulseBand: PulseBand
        if let quiet {
            pulseBand = silent ? .silent : (quiet >= CockpitRun.silenceThreshold / 4 ? .caution : .ok)
        } else {
            pulseBand = .idle
        }
        pulse = Pulse(quietSeconds: quiet, band: pulseBand)

        let effective = controls.narrowed(by: cuts ?? run.switches ?? CockpitLiveSwitches())
        lamps = Lamps(paused: run.status == .paused, stepFailed: failed > 0,
                      limitReached: fuel.band == .limit || turns.band == .limit,
                      silent: silent, supervisorOff: !effective.supervisor)
    }

    static func band(used: Double, limit: Double?) -> Band {
        guard let limit, limit > 0 else { return .ok }
        if used >= limit { return .limit }
        return used >= limit * cautionShare ? .caution : .ok
    }

    static func windBand(_ score: Int) -> WindBand {
        switch score {
        case ..<1: return .calm
        case 1...2: return .breeze
        case 3...5: return .gusty
        default: return .storm
        }
    }
}
