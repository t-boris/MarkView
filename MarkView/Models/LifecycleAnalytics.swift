import Foundation

// Lifecycle events of a feature and the durations computed from them. Foundation only, no app
// state: tools/tests/lifecycle-tests.sh compiles this file on its own and checks the rules.

/// The canonical lifecycle stages, in order (DEC-006). No other event types exist.
enum LifecycleStage: String, CaseIterable, Codable, Sendable {
    case ideaCreated = "idea_created"
    case questionsResolved = "questions_resolved"
    case specReady = "spec_ready"
    case implementationStarted = "implementation_started"
    case implementationFinished = "implementation_finished"
    case reviewDone = "review_done"
    case ciRequested = "ci_requested"
    case ciStarted = "ci_started"
    case ciPassed = "ci_passed"
    case mergedToMain = "merged_to_main"
    case verified

    var title: String {
        switch self {
        case .ideaCreated: return "Idea created"
        case .questionsResolved: return "Questions resolved"
        case .specReady: return "Spec ready"
        case .implementationStarted: return "Implementation started"
        case .implementationFinished: return "Implementation finished"
        case .reviewDone: return "Review done"
        case .ciRequested: return "CI requested"
        case .ciStarted: return "CI started"
        case .ciPassed: return "CI passed"
        case .mergedToMain: return "Merged to main"
        case .verified: return "Verified"
        }
    }

    /// Recorded by MarkView itself; never marked by hand (DEC-013).
    var isAutomatic: Bool { [.ideaCreated, .questionsResolved, .specReady, .ciRequested, .ciStarted].contains(self) }

    /// Run details of CI (queue wait, re-runs): read from GitHub, kept out of the chain of adjacent
    /// steps because CI starts when a pull request opens, before its review is done. Their
    /// durations are in `LifecycleCI`.
    var isCIDetail: Bool { self == .ciRequested || self == .ciStarted }

    /// The stages whose adjacent pairs are the steps.
    static var chain: [LifecycleStage] { allCases.filter { !$0.isCIDetail } }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static var manual: [LifecycleStage] { allCases.filter { !$0.isAutomatic } }
}

enum LifecycleSource: String, Codable, Sendable {
    case automatic, manual
}

/// One immutable event. Keyed by the project root's absolute path and the feature slug (DEC-012).
struct LifecycleEvent: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let project: String
    let feature: String
    let stage: LifecycleStage
    let timestamp: Date
    let actor: String
    let source: LifecycleSource
    /// AI model or agent, when an AI did the step.
    let model: String?
    /// Free text on manual marks, at most `LifecycleEvent.noteLimit` characters (DEC-015).
    let note: String?

    static let noteLimit = 500
}

/// A step: two adjacent canonical stages (DEC-009).
struct LifecycleStep: Hashable, Sendable {
    let start: LifecycleStage
    let end: LifecycleStage

    var title: String { "\(start.title) → \(end.title)" }

    /// The step whose duration is compared per AI model (DEC-011).
    var isAIStep: Bool { start == .implementationStarted }

    static let all: [LifecycleStep] = zip(LifecycleStage.chain, LifecycleStage.chain.dropFirst()).map(LifecycleStep.init)
}

enum LifecycleDuration: Equatable, Sendable {
    /// A boundary event is missing (skipped stages are not bridged).
    case missing
    /// The end came before the start.
    case inconsistent
    case valid(TimeInterval)

    var seconds: TimeInterval? {
        if case .valid(let value) = self { return value }
        return nil
    }
}

enum LifecycleAnalytics {
    /// Earliest event of `start` to latest event of `end`, calendar time (DEC-009, DEC-014).
    static func duration(from start: LifecycleStage, to end: LifecycleStage, in events: [LifecycleEvent]) -> LifecycleDuration {
        guard let first = events.filter({ $0.stage == start }).map(\.timestamp).min(),
              let last = events.filter({ $0.stage == end }).map(\.timestamp).max() else { return .missing }
        let seconds = last.timeIntervalSince(first)
        return seconds < 0 ? .inconsistent : .valid(seconds)
    }

    /// Every step of one feature's events.
    static func steps(_ events: [LifecycleEvent]) -> [(step: LifecycleStep, duration: LifecycleDuration)] {
        LifecycleStep.all.map { ($0, duration(from: $0.start, to: $0.end, in: events)) }
    }

    /// Idea created → verified; missing unless both exist.
    static func total(_ events: [LifecycleEvent]) -> LifecycleDuration {
        duration(from: .ideaCreated, to: .verified, in: events)
    }

    /// The model of a step: the one on the event its duration starts from.
    static func model(of step: LifecycleStep, in events: [LifecycleEvent]) -> String? {
        events.filter { $0.stage == step.start }.min { $0.timestamp < $1.timestamp }?.model
    }

    struct Statistic: Equatable, Sendable {
        let median: TimeInterval
        let mean: TimeInterval
        /// Features the statistic is based on.
        let count: Int
    }

    static func statistic(_ values: [TimeInterval]) -> Statistic? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        return Statistic(median: median, mean: sorted.reduce(0, +) / Double(sorted.count), count: sorted.count)
    }

    struct SummaryRow: Sendable {
        let step: LifecycleStep
        /// nil when no feature has a valid duration for the step.
        let statistic: Statistic?
        /// Model → statistic, for the AI step only; sorted by model name.
        let byModel: [(model: String, statistic: Statistic)]
    }

    /// Name used for an AI step recorded without a model.
    static let unknownModel = "Unknown model"

    /// Per-step statistics over features (feature slug → its events); only valid durations count.
    static func summary(_ features: [String: [LifecycleEvent]]) -> (rows: [SummaryRow], total: Statistic?) {
        let rows = LifecycleStep.all.map { step -> SummaryRow in
            var values: [TimeInterval] = []
            var perModel: [String: [TimeInterval]] = [:]
            for events in features.values {
                guard let seconds = duration(from: step.start, to: step.end, in: events).seconds else { continue }
                values.append(seconds)
                if step.isAIStep {
                    let model = model(of: step, in: events).flatMap { $0.isEmpty ? nil : $0 } ?? unknownModel
                    perModel[model, default: []].append(seconds)
                }
            }
            let byModel = perModel.compactMap { key, values in statistic(values).map { (key, $0) } }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            return SummaryRow(step: step, statistic: statistic(values), byModel: byModel)
        }
        let totals = features.values.compactMap { total($0).seconds }
        return (rows, statistic(totals))
    }

    /// "2d 3h 15m": rounded to the minute, leading zero units left out (DEC-014).
    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h \(rest)m" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }
}


/// How long CI takes and how often it was started again, from the events of `ci_requested`,
/// `ci_started` and `ci_passed`.
enum LifecycleCI {
    /// A re-run is a `ci_requested` event whose note has this marker: "PR #12 · re-run 2 of run 987".
    static let rerunMarker = " · re-run "

    static func isRerun(_ event: LifecycleEvent) -> Bool {
        event.stage == .ciRequested && (event.note?.contains(rerunMarker) ?? false)
    }

    /// Requested → started: waiting for a runner. Earliest request to the first start.
    static func queue(_ events: [LifecycleEvent]) -> LifecycleDuration {
        LifecycleAnalytics.duration(from: .ciRequested, to: .ciStarted, in: events)
    }

    /// Started → passed: the time CI ran until it was green, failed attempts and re-runs included.
    static func work(_ events: [LifecycleEvent]) -> LifecycleDuration {
        LifecycleAnalytics.duration(from: .ciStarted, to: .ciPassed, in: events)
    }

    static func reruns(_ events: [LifecycleEvent]) -> Int { events.filter(isRerun).count }

    struct Summary: Equatable, Sendable {
        let queue: LifecycleAnalytics.Statistic?
        let work: LifecycleAnalytics.Statistic?
        /// Features with any CI event, and how many of them needed a re-run, with the re-runs in all.
        let features: Int
        let rerunFeatures: Int
        let reruns: Int
    }

    static func summary(_ features: [String: [LifecycleEvent]]) -> Summary {
        let withCI = features.values.filter { $0.contains { $0.stage.isCIDetail || $0.stage == .ciPassed } }
        let counts = withCI.map(reruns)
        return Summary(queue: LifecycleAnalytics.statistic(withCI.compactMap { queue($0).seconds }),
                       work: LifecycleAnalytics.statistic(withCI.compactMap { work($0).seconds }),
                       features: withCI.count, rerunFeatures: counts.filter { $0 > 0 }.count, reruns: counts.reduce(0, +))
    }
}
