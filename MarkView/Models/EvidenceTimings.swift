import Foundation

// Delivery evidence of a feature, kept in the per-Mac evidence log (feature cycle-time-as-a-view-over-the-workflow, REQ-005, REQ-006):
// when work was handed to an AI, when pull requests were opened, approved, checked and merged, how long CI waited and ran. It is
// not a record of state changes - the workflow journal is - and the app never derives it from a change of status. Foundation only,
// so the standalone test scripts compile it on its own.

/// What GitHub and git show about the delivery of a feature. The raw values are those the log has always used, so older lines read.
enum EvidenceStage: String, CaseIterable, Codable, Sendable {
    /// The feature was handed to an AI assistant, with the model that took it.
    case workStarted = "implementation_started"
    case pullRequestOpened = "implementation_finished"
    case approved = "review_done"
    case ciRequested = "ci_requested"
    case ciStarted = "ci_started"
    case ciPassed = "ci_passed"
    /// Merged into the default branch: a pull request, or a commit made straight on it.
    case mergedToMain = "merged_to_main"

    var title: String {
        switch self {
        case .workStarted: return "Handed to an AI assistant"
        case .pullRequestOpened: return "Pull request opened"
        case .approved: return "Approved"
        case .ciRequested: return "CI requested"
        case .ciStarted: return "CI started"
        case .ciPassed: return "CI passed"
        case .mergedToMain: return "Merged to the default branch"
        }
    }

    /// Run details of CI (queue wait, re-runs), read from GitHub.
    var isCIDetail: Bool { self == .ciRequested || self == .ciStarted }
}

enum LifecycleSource: String, Codable, Sendable {
    case automatic
    /// Written by the manual stage marks that no longer exist; such lines are never read.
    case manual
}

/// One immutable line of the evidence log. Keyed by the project root's absolute path and the feature slug.
struct LifecycleEvent: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let project: String
    let feature: String
    let stage: EvidenceStage
    let timestamp: Date
    let actor: String
    let source: LifecycleSource
    /// AI model or agent, when an AI did the step.
    let model: String?
    /// The pull request or commit the event belongs to ("PR #12", "commit abc1234"), or what started the work.
    let note: String?

    /// Lines of the retired observer and of manual marks are not evidence: the observer wrote "implementation finished" with the note
    /// "Status implemented" when a status changed, and nothing else ever wrote a note that starts so.
    var isEvidence: Bool {
        source == .automatic && !(stage == .pullRequestOpened && note?.hasPrefix("Status ") == true)
    }
}

// MARK: - Timings per unit of work

struct EvidenceRow: Equatable, Sendable, Identifiable {
    let stage: EvidenceStage
    let at: Date
    /// Time since the row before it (for the first row, since the work was handed over); nil when there is nothing before.
    let since: TimeInterval?
    var id: String { stage.rawValue }
}

/// What happened to one pull request or one commit.
struct EvidenceUnit: Equatable, Sendable, Identifiable {
    let name: String
    let rows: [EvidenceRow]
    /// CI requested to started: waiting for a runner.
    let queue: TimeInterval?
    /// CI started to passed, failed attempts and re-runs included.
    let ciTime: TimeInterval?
    let reruns: Int
    var id: String { name }

    var merged: Date? { rows.first { $0.stage == .mergedToMain }?.at }
}

struct EvidenceTimeline: Equatable, Sendable {
    let started: Date?
    let model: String?
    let units: [EvidenceUnit]
}

enum EvidenceTimings {
    /// A re-run is a `ciRequested` event whose note has this marker: "PR #12 · re-run 2 of run 987".
    static let rerunMarker = " · re-run "

    /// The unit an event belongs to ("PR #12"), without the re-run marker; nil for what started the work.
    static func unit(of event: LifecycleEvent) -> String? {
        guard event.stage != .workStarted, let note = event.note, !note.isEmpty else { return nil }
        return note.components(separatedBy: rerunMarker)[0]
    }

    static func isRerun(_ event: LifecycleEvent) -> Bool {
        event.stage == .ciRequested && (event.note?.contains(rerunMarker) ?? false)
    }

    /// The stages that mean something for a process. A direct-to-the-default-branch process has no pull request to open or approve,
    /// so it shows neither, and nothing is ordered before the merge: CI may run after it.
    static func stages(directToMain: Bool) -> Set<EvidenceStage> {
        directToMain ? [.mergedToMain, .ciRequested, .ciStarted, .ciPassed] : Set(EvidenceStage.allCases).subtracting([.workStarted])
    }

    /// The evidence of one feature, from its events in recording order. `since` leaves out what was recorded before the feature
    /// existed (a deleted feature may have left lines under the same slug).
    static func timeline(_ events: [LifecycleEvent], directToMain: Bool, since: Date? = nil) -> EvidenceTimeline {
        let floor = since ?? .distantPast
        let own = events.filter { $0.isEvidence && $0.timestamp >= floor }
        let start = own.filter { $0.stage == .workStarted }.min { $0.timestamp < $1.timestamp }
        let wanted = stages(directToMain: directToMain)
        var byUnit: [String: [LifecycleEvent]] = [:]
        for event in own where wanted.contains(event.stage) {
            if let name = unit(of: event) { byUnit[name, default: []].append(event) }
        }
        var units: [EvidenceUnit] = []
        for (name, all) in byUnit {
            var firsts: [EvidenceStage: Date] = [:]
            for event in all where !isRerun(event) {
                firsts[event.stage] = min(firsts[event.stage] ?? event.timestamp, event.timestamp)
            }
            let ordered = firsts.sorted { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }
            var previous = start?.timestamp
            var rows: [EvidenceRow] = []
            for (stage, at) in ordered {
                rows.append(EvidenceRow(stage: stage, at: at, since: previous.map { max(at.timeIntervalSince($0), 0) }))
                previous = at
            }
            func between(_ from: EvidenceStage, _ to: EvidenceStage) -> TimeInterval? {
                guard let a = firsts[from], let b = firsts[to], b >= a else { return nil }
                return b.timeIntervalSince(a)
            }
            units.append(EvidenceUnit(name: name, rows: rows, queue: between(.ciRequested, .ciStarted), ciTime: between(.ciStarted, .ciPassed),
                                      reruns: all.filter(isRerun).count))
        }
        units.sort { ($0.rows.first?.at ?? .distantFuture, $0.name) < ($1.rows.first?.at ?? .distantFuture, $1.name) }
        return EvidenceTimeline(started: start?.timestamp, model: start?.model.flatMap { $0.isEmpty ? nil : $0 }, units: units)
    }
}
