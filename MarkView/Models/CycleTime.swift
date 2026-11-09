import Foundation

// Cycle time of a feature or a bug as a read-only view over the workflow journal (feature cycle-time-as-a-view-over-the-workflow,
// REQ-001, DEC-015). The journal (`.dde/lifecycle/transitions.jsonl`) is the one record of state changes; this file folds the
// records of one item into the stays it made in the statuses of the project's own workflow, cuts them into rounds, and reads
// the durations from the roles of the statuses, never from their names. Nothing is stored here, so a rule fixed later repairs
// the numbers of everything that happened before.
//
// Foundation only (with FeatureVocabulary.swift, IssueListing.swift, ProjectWorkflow.swift, IssueLifecycle.swift and
// IssueTransitionLog.swift), so tools/tests/cycle-time-tests.sh compiles it on its own.

// MARK: - Stays

/// How a stay in a status began. Only a real transition (or an outside edit, with a mark) is evidence of *when* something
/// happened; the other two only say what the status was when MarkView looked or after a person's replacement.
enum CycleCause: Equatable, Sendable {
    /// The journal's first look at the item (`baseline`): the status the item already had, at the time MarkView first saw it.
    case firstSight
    /// A transition MarkView made or recorded under the rules.
    case transition(TransitionKind?)
    /// The workflow lost the old status and a person chose the new one (`replacement`): a bookkeeping move, not work. The
    /// Kanban switch of 2026-11-09 wrote 144 of them in one second.
    case replacement
    /// The stored status changed outside MarkView and was found later; the time is when it was found.
    case outsideEdit

    /// The record says when something really happened.
    var isEvent: Bool {
        switch self {
        case .transition, .outsideEdit: return true
        case .firstSight, .replacement: return false
        }
    }
}

struct CycleStay: Equatable, Sendable {
    let status: String
    /// The role the status has in the workflow (or in a flow MarkView knows, for a status the workflow has dropped); nil: unknown.
    let role: LifecycleRole?
    let entered: Date
    var left: Date?
    let cause: CycleCause
    /// What began the next stay; nil while this one goes on.
    var leftBy: CycleCause?
    let actor: LifecycleActor
    /// A person forced the step, bypassing conditions.
    let forced: Bool
    let reason: String?

    /// Who made the move, as a person reads it: "Boris", "Claude Code (AI)", "MarkView (system)".
    var actorText: String {
        switch actor.kind {
        case .human: return actor.name
        case .ai: return actor.name + " (AI)"
        case .system: return actor.name + " (system)"
        }
    }

    /// The role the arithmetic uses: an unknown status counts as waiting, and is marked.
    var effectiveRole: LifecycleRole { role ?? .notStarted }

    /// Both the entry and the exit are real events, so the time spent here is known (a stay that began or ended by a replacement or a
    /// first look is cut off at an unknown moment).
    var dwellKnown: Bool { cause.isEvent && (leftBy?.isEvent ?? false) }

    func duration(now: Date) -> TimeInterval { max((left ?? now).timeIntervalSince(entered), 0) }
}

// MARK: - Quality marks

/// Why a number should be read with care. Never a pace colour: a mark says the data is thin, not that the work was slow.
enum CycleQuality: String, CaseIterable, Sendable {
    case createdBeforeSight = "created-before-sight"
    case outsideEdit = "outside-edit"
    case forced
    case unknownStatus = "unknown-status"
    case replaced
    case clockSkew = "clock-skew"
    case bulkCreated = "bulk-created"
    case noHistory = "no-history"
    case excluded

    var title: String {
        switch self {
        case .createdBeforeSight: return "created before MarkView watched it"
        case .outsideEdit: return "status changed outside MarkView"
        case .forced: return "a step was forced"
        case .unknownStatus: return "a status the workflow does not know"
        case .replaced: return "a status was replaced by a flow change"
        case .clockSkew: return "a record is older than the one before it"
        case .bulkCreated: return "created together with many others"
        case .noHistory: return "no history recorded yet"
        case .excluded: return "excluded from statistics"
        }
    }

    var explanation: String {
        switch self {
        case .createdBeforeSight:
            return "The item existed before the journal first saw it, so the time from creation to the first move is unknown. Durations that start later are still used."
        case .outsideEdit:
            return "A status was changed without MarkView. The time is when MarkView found it, and the lifecycle conditions were not checked."
        case .forced:
            return "A person forced a step that the rules did not allow, with a reason."
        case .unknownStatus:
            return "A status that neither the workflow nor a known flow has: it counts as waiting."
        case .replaced:
            return "The workflow dropped a status and a person moved the item to another. That move is not work and is never counted as one."
        case .clockSkew:
            return "A record carries an earlier time than the record before it; the time was moved forward to keep the order."
        case .bulkCreated:
            return "Many items were created within one minute (an import), so durations that start at their creation are those of the batch."
        case .noHistory:
            return "The journal has no record of this item yet."
        case .excluded:
            return "You excluded this item from the statistics."
        }
    }
}

// MARK: - Rounds and the item

/// One round of work on an item: from its creation, or from a reopening, to the next reopening (REQ-001). A reopened item starts
/// a new round instead of making the old one longer.
struct CycleRound: Equatable, Sendable {
    let index: Int
    /// When the round began; nil when the item existed before MarkView first saw it (round 0 only).
    var start: Date?
    /// The first record of the round.
    let observedFrom: Date
    var firstActive: Date?
    /// The item was already active when first seen: when work began is unknown.
    var startedBeforeSight = false
    var completed: Date?
    var completedStatus: String?
    /// The item was already completed when first seen (or by a replacement): when it finished is unknown.
    var finishedBeforeSight = false
    var accepted: Date?
    var cancelled: Date?
    /// The stays of the round, as indexes into the item's `stays`.
    var stays: ClosedRange<Int>
}

enum CycleState: Equatable, Sendable {
    case noHistory
    case open
    case finished
    case cancelled
}

struct CycleItem: Equatable, Sendable, Identifiable {
    let kind: IssueKind
    let issue: String
    let title: String
    /// The stored status now.
    let status: String
    var stays: [CycleStay]
    var rounds: [CycleRound]
    var reopens = 0
    var rollbacks = 0
    var marks: Set<CycleQuality> = []
    /// A request the rules refused after the last change of status: the item wanted to move and could not.
    var blocked: TransitionRecord?

    var id: String { key }
    var key: String { kind.rawValue + ":" + issue }

    var current: CycleStay? { stays.last }

    var state: CycleState {
        guard let current else { return .noHistory }
        switch current.effectiveRole {
        case .completed: return .finished
        case .cancelled: return .cancelled
        case .notStarted, .active: return .open
        }
    }

    /// The round the item is in now.
    var round: CycleRound? { rounds.last }

    /// When the item's latest round began, as far as it is known: used for the Measure since window.
    var windowStart: Date? { rounds.last.map { $0.start ?? $0.observedFrom } }
}

// MARK: - Metrics

/// The durations of an item, defined by the roles of the statuses (REQ-001).
enum CycleMetric: String, CaseIterable, Sendable {
    case waiting, cycle, lead, acceptance

    var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .cycle: return "Cycle time"
        case .lead: return "Lead time"
        case .acceptance: return "Waiting for acceptance"
        }
    }

    /// The definition in words, shown when a number is opened.
    var definition: String {
        switch self {
        case .waiting: return "From the item's creation (or its reopening) to the first time it enters a status where work is under way."
        case .cycle: return "From the first time the item enters a status where work is under way to the first time it enters a completed status, in the same round."
        case .lead: return "From the item's creation (or its reopening) to the first time it enters a completed status."
        case .acceptance: return "From the first completed status to the step that accepts the work (for example implemented to verified). Only in flows that have such a step."
        }
    }
}

/// Why an item has no value for a metric.
enum CycleMissing: String, Sendable {
    case notFinished = "not-finished"
    case neverActive = "never-active"
    case skippedActive = "skipped-active"
    case startedBeforeSight = "started-before-sight"
    case createdBeforeSight = "created-before-sight"
    case finishedBeforeSight = "finished-before-sight"
    case notAccepted = "not-accepted"
    case cancelled
    case inconsistent
    case excluded
    case outsideWindow = "outside-window"
    case noHistory = "no-history"

    var title: String {
        switch self {
        case .noHistory: return "no history recorded yet"
        case .notFinished: return "not finished yet"
        case .neverActive: return "work has not started"
        case .skippedActive: return "went straight to completed, without a status where work is under way"
        case .startedBeforeSight: return "already under way when MarkView first saw it"
        case .createdBeforeSight: return "created before MarkView watched it"
        case .finishedBeforeSight: return "already completed when MarkView first saw it"
        case .notAccepted: return "not accepted yet"
        case .cancelled: return "dropped"
        case .inconsistent: return "inconsistent (the end is before the start)"
        case .excluded: return "excluded by you"
        case .outsideWindow: return "before the Measure since date"
        }
    }
}

enum CycleValue: Equatable, Sendable {
    /// `at` is when the measured thing ended; `round` the round it was measured in.
    case value(TimeInterval, at: Date, round: Int)
    case missing(CycleMissing)

    var seconds: TimeInterval? {
        if case .value(let seconds, _, _) = self { return seconds }
        return nil
    }
}

extension CycleItem {
    /// The value of a metric. An item counts once per metric, in the latest round that has a value, so a reopened item keeps the
    /// result of its first delivery until the second one is complete.
    func value(_ metric: CycleMetric) -> CycleValue {
        guard !rounds.isEmpty else { return .missing(.noHistory) }
        for round in rounds.reversed() {
            let result = value(metric, in: round)
            if case .value = result { return result }
        }
        return value(metric, in: rounds[rounds.count - 1])
    }

    func value(_ metric: CycleMetric, in round: CycleRound) -> CycleValue {
        func between(_ start: Date, _ end: Date) -> CycleValue {
            let seconds = end.timeIntervalSince(start)
            return seconds < 0 ? .missing(.inconsistent) : .value(seconds, at: end, round: round.index)
        }
        switch metric {
        case .waiting:
            guard let start = round.start else { return .missing(.createdBeforeSight) }
            if round.startedBeforeSight { return .missing(.startedBeforeSight) }
            guard let active = round.firstActive else {
                if round.completed != nil { return .missing(.skippedActive) }
                if round.finishedBeforeSight { return .missing(.finishedBeforeSight) }
                return .missing(round.cancelled != nil ? .cancelled : .neverActive)
            }
            return between(start, active)
        case .cycle:
            if round.startedBeforeSight { return .missing(.startedBeforeSight) }
            if round.finishedBeforeSight { return .missing(.finishedBeforeSight) }
            guard let active = round.firstActive else {
                if round.completed != nil { return .missing(.skippedActive) }
                return .missing(round.cancelled != nil ? .cancelled : .neverActive)
            }
            guard let completed = round.completed else { return .missing(round.cancelled != nil ? .cancelled : .notFinished) }
            return between(active, completed)
        case .lead:
            guard let start = round.start else { return .missing(.createdBeforeSight) }
            guard let completed = round.completed else {
                if round.finishedBeforeSight { return .missing(.finishedBeforeSight) }
                return .missing(round.cancelled != nil ? .cancelled : .notFinished)
            }
            return between(start, completed)
        case .acceptance:
            guard let completed = round.completed else {
                return .missing(round.finishedBeforeSight ? .finishedBeforeSight : (round.cancelled != nil ? .cancelled : .notFinished))
            }
            guard let accepted = round.accepted else { return .missing(.notAccepted) }
            return between(completed, accepted)
        }
    }

    /// Time spent in each status during a round, from the stays whose entry and exit are both real events; the open stay is not
    /// included (its age is `current`'s).
    func dwell(in round: CycleRound) -> [(status: String, seconds: TimeInterval)] {
        var order: [String] = []
        var total: [String: TimeInterval] = [:]
        for index in round.stays where stays[index].dwellKnown {
            let stay = stays[index]
            if total[stay.status] == nil { order.append(stay.status) }
            total[stay.status, default: 0] += stay.duration(now: stay.left ?? stay.entered)
        }
        return order.map { ($0, total[$0] ?? 0) }
    }
}

// MARK: - As text

extension CycleItem {
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func causeText(_ cause: CycleCause) -> String {
        switch cause {
        case .firstSight: return "first seen by MarkView"
        case .transition(let kind): return kind.map { "transition (\($0.rawValue))" } ?? "transition"
        case .replacement: return "replaced when the flow changed"
        case .outsideEdit: return "edited outside MarkView"
        }
    }

    /// The stays, rounds, measures and marks of the item, for an agent or a log.
    func describe(now: Date) -> String {
        guard !stays.isEmpty else { return "\(kind.rawValue) \(issue) — \(title)\nNo lifecycle history recorded yet." }
        var lines = ["\(kind.rawValue) \(issue) — \(title)"]
        if let current {
            lines.append("Status: \(current.status) (\(current.role.map { "\($0)" } ?? "unknown role")) since \(Self.stamp(current.entered)), \(CycleFormat.duration(current.duration(now: now)))")
        }
        lines.append("Rounds: \(rounds.count)" + (reopens > 0 ? ", reopened \(reopens) time\(reopens == 1 ? "" : "s")" : ""))
        lines.append("Stays:")
        for stay in stays {
            let left = stay.left.map { " → " + Self.stamp($0) } ?? " → now"
            lines.append("- \(stay.status) \(Self.stamp(stay.entered))\(left), \(CycleFormat.duration(stay.duration(now: now))); entered by \(Self.causeText(stay.cause)), \(stay.actorText)" + (stay.forced ? ", forced" : ""))
        }
        let measures = CycleMetric.allCases.map { metric -> String in
            switch value(metric) {
            case .value(let seconds, _, let round): return "\(metric.title.lowercased()) \(CycleFormat.duration(seconds)) (round \(round + 1))"
            case .missing(let reason): return "\(metric.title.lowercased()) — \(reason.title)"
            }
        }
        lines.append("Measures: " + measures.joined(separator: "; "))
        if !marks.isEmpty { lines.append("Data quality: " + marks.map(\.title).sorted().joined(separator: "; ")) }
        if let blocked, let message = blocked.message { lines.append("Last request refused: \(message.split(separator: "\n").first.map(String.init) ?? message)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Folding the journal

/// What the app knows about an item besides its journal.
struct CycleItemInfo: Equatable, Sendable {
    let kind: IssueKind
    let issue: String
    let title: String
    /// The status stored in the item's file now.
    let status: String
    /// The `created` date of the item's front matter: the start of that day in UTC, the way MarkView writes it (FeatureStore.today);
    /// nil when it has none.
    let created: Date?
}

enum CycleFolder {
    /// `created` is a UTC date (FeatureStore.today), so the day of the first look is read the same way.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// The journal records of one item, folded into stays and rounds. `role` answers for any status string; the caller gives the
    /// project's workflow first and the flows MarkView knows after it, so that a status the workflow has dropped keeps its role.
    static func fold(_ info: CycleItemInfo, records: [TransitionRecord], role: (String) -> LifecycleRole?, now: Date) -> CycleItem {
        let history = IssueHistory(kind: info.kind, issue: info.issue, all: records)
        var marks: Set<CycleQuality> = []

        // Stays
        var stays: [CycleStay] = []
        for record in history.changes {
            let status = LifecycleVocabulary.normalize(record.to)
            if stays.last?.status == status { continue }
            let cause: CycleCause
            switch record.phase {
            case .baseline: cause = .firstSight
            case .external: cause = .outsideEdit
            default: cause = record.transitionKind == .replacement ? .replacement : .transition(record.transitionKind)
            }
            var at = record.at
            if let previous = stays.last, at < previous.entered { at = previous.entered; marks.insert(.clockSkew) }
            if !stays.isEmpty {
                stays[stays.count - 1].left = at
                stays[stays.count - 1].leftBy = cause
            }
            let resolved = role(status)
            if resolved == nil { marks.insert(.unknownStatus) }
            switch cause {
            case .outsideEdit: marks.insert(.outsideEdit)
            case .replacement: marks.insert(.replaced)
            default: break
            }
            if record.override { marks.insert(.forced) }
            stays.append(CycleStay(status: status, role: resolved, entered: at, left: nil, cause: cause, leftBy: nil, actor: record.actor,
                                   forced: record.override, reason: record.reason))
        }
        guard let first = stays.first else {
            return CycleItem(kind: info.kind, issue: info.issue, title: info.title, status: info.status, stays: [], rounds: [],
                             marks: [.noHistory])
        }

        // Rounds
        // The item was created at its first sight only when its `created` date is that very day (the date has no time of day);
        // an earlier date means the item waited unseen, and no date means nothing is known.
        var roundStart: Date? = nil
        if let created = info.created, utc.isDate(created, inSameDayAs: first.entered) { roundStart = first.entered }
        if roundStart == nil { marks.insert(.createdBeforeSight) }

        var rounds: [CycleRound] = []
        var current = CycleRound(index: 0, start: roundStart, observedFrom: first.entered, stays: 0...0)
        var reopens = 0, rollbacks = 0
        var previous: CycleStay?
        for (index, stay) in stays.enumerated() {
            let role = stay.effectiveRole
            let before = previous?.effectiveRole
            if let previous, stay.cause.isEvent, previous.effectiveRole == .completed || previous.effectiveRole == .cancelled,
               role == .notStarted || role == .active {
                current.stays = current.stays.lowerBound...(index - 1)
                rounds.append(current)
                reopens += 1
                current = CycleRound(index: rounds.count, start: stay.entered, observedFrom: stay.entered, stays: index...index)
            }
            current.stays = current.stays.lowerBound...index
            if role == .active, before != .active, current.firstActive == nil, !current.startedBeforeSight {
                if stay.cause.isEvent { current.firstActive = stay.entered } else { current.startedBeforeSight = true }
            }
            if role == .completed {
                if before != .completed {
                    if current.completed == nil, !current.finishedBeforeSight {
                        if stay.cause.isEvent { current.completed = stay.entered; current.completedStatus = stay.status } else { current.finishedBeforeSight = true }
                    }
                } else if stay.cause.isEvent, current.completed != nil, current.accepted == nil {
                    current.accepted = stay.entered
                }
            }
            if role == .cancelled, before != .cancelled, stay.cause.isEvent, current.cancelled == nil { current.cancelled = stay.entered }
            if stay.cause.isEvent, before == .active, role == .notStarted { rollbacks += 1 }
            previous = stay
        }
        rounds.append(current)

        // A request the rules refused after the last change.
        var blocked: TransitionRecord?
        if let rejection = history.rejections.last, let change = history.lastChange, rejection.at > change.at { blocked = rejection }

        return CycleItem(kind: info.kind, issue: info.issue, title: info.title, status: info.status, stays: stays, rounds: rounds,
                         reopens: reopens, rollbacks: rollbacks, marks: marks, blocked: blocked)
    }
}

// MARK: - Roles of statuses

/// Where a status gets its role from: the project's workflow first, then the flows MarkView knows (so a status the workflow dropped
/// keeps the meaning it had), then the words of the status itself. Nil only for a name nothing recognises.
struct CycleRoles: Sendable {
    /// The project workflow's answer for (kind, status).
    let workflow: @Sendable (IssueKind, String) -> LifecycleRole?
    /// The flows MarkView ships (`WorkflowFlow.catalogue` and the standard workflow), in the order to try them.
    let known: @Sendable (IssueKind, String) -> LifecycleRole?

    func role(_ kind: IssueKind, _ status: String) -> LifecycleRole? {
        let value = LifecycleVocabulary.normalize(status)
        return workflow(kind, value) ?? known(kind, value) ?? Self.byName(kind, value)
    }

    /// The words of a status written by hand (`done`, `rejected`): the same sets the filters use.
    static func byName(_ kind: IssueKind, _ status: String) -> LifecycleRole? {
        let value = LifecycleVocabulary.normalize(status)
        if IssueStatus.inProgress.contains(value) { return .active }
        switch kind {
        case .feature:
            if IssueStatus.implementedFeature.contains(value) { return .completed }
            if IssueStatus.closedFeature.contains(value) { return .cancelled }
        case .bug:
            if IssueStatus.closedBug.contains(value) { return .completed }
        }
        return nil
    }
}
