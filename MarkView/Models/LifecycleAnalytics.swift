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
        case .ciPassed: return "CI passed"
        case .mergedToMain: return "Merged to main"
        case .verified: return "Verified"
        }
    }

    /// Recorded by MarkView itself; never marked by hand (DEC-013).
    var isAutomatic: Bool { [.ideaCreated, .questionsResolved, .specReady].contains(self) }

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

    static let all: [LifecycleStep] = zip(LifecycleStage.allCases, LifecycleStage.allCases.dropFirst()).map(LifecycleStep.init)
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
