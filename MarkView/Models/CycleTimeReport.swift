import Foundation

// The project report of cycle time (feature cycle-time-as-a-view-over-the-workflow, REQ-002, REQ-003, REQ-004): the metrics of
// `CycleTime.swift` over all items of a kind, judged against the project's own history. Three signals are kept apart (DEC-014):
// pace (green, amber, red against the project's percentiles), facts (reopened, refused, waiting for acceptance) and the quality of
// the data (`CycleQuality`). Foundation only, with CycleTime.swift's dependencies, so tools/tests/cycle-time-tests.sh compiles it.

// MARK: - Formatting

enum CycleFormat {
    /// "2d 3h 15m": rounded to the minute, leading zero units left out; under half a minute "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(seconds, 0)
        let minutes = Int((value / 60).rounded())
        if minutes == 0 { return value > 0 ? "<1m" : "0m" }
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return "\(days)d \(hours)h \(rest)m" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }
}

// MARK: - Distribution and pace

struct CycleDistribution: Equatable, Sendable {
    let count: Int
    let lowest: TimeInterval
    /// The median.
    let p50: TimeInterval
    /// Nearest rank: 85 % of the values are at most this.
    let p85: TimeInterval
    let highest: TimeInterval
    let mean: TimeInterval

    static func make(_ values: [TimeInterval]) -> CycleDistribution? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        let rank = max(Int((0.85 * Double(sorted.count)).rounded(.up)), 1)
        return CycleDistribution(count: sorted.count, lowest: sorted[0], p50: median, p85: sorted[min(rank, sorted.count) - 1],
                                 highest: sorted[sorted.count - 1], mean: sorted.reduce(0, +) / Double(sorted.count))
    }
}

/// Green, amber or red against the project's own history of the same measure (DEC-014); grey when there is too little of it.
enum CyclePace: String, Equatable, Sendable {
    case good, slow, bad
    /// Fewer than `minimumSamples` finished measures to compare with.
    case unknown
    /// Not judged: a status where work only waits.
    case neutral

    static let minimumSamples = 8

    static func judge(_ seconds: TimeInterval, against distribution: CycleDistribution?) -> CyclePace {
        guard let distribution, distribution.count >= minimumSamples else { return .unknown }
        if seconds <= distribution.p50 { return .good }
        if seconds <= distribution.p85 { return .slow }
        return .bad
    }

    var rank: Int {
        switch self {
        case .bad: return 3
        case .slow: return 2
        case .unknown, .neutral: return 1
        case .good: return 0
        }
    }
}

// MARK: - Settings (the corrections of DEC-001)

struct CycleExclusion: Codable, Equatable, Sendable {
    var kind: IssueKind
    var issue: String
    var reason: String
    var at: Date
}

/// What the owner decided about the statistics of a project: stored beside the journal, never inside it.
struct CycleSettings: Codable, Equatable, Sendable {
    /// Items whose latest round began before this are left out; nil = all time.
    var since: Date?
    var excluded: [CycleExclusion] = []

    static let empty = CycleSettings(since: nil, excluded: [])

    func isExcluded(_ kind: IssueKind, _ issue: String) -> Bool { excluded.contains { $0.kind == kind && $0.issue == issue } }

    func exclusion(_ kind: IssueKind, _ issue: String) -> CycleExclusion? { excluded.first { $0.kind == kind && $0.issue == issue } }

    func excluding(_ kind: IssueKind, _ issue: String, reason: String, at: Date = Date()) -> CycleSettings {
        guard !isExcluded(kind, issue) else { return self }
        var copy = self
        copy.excluded.append(CycleExclusion(kind: kind, issue: issue, reason: reason, at: at))
        return copy
    }

    func including(_ kind: IssueKind, _ issue: String) -> CycleSettings {
        var copy = self
        copy.excluded.removeAll { $0.kind == kind && $0.issue == issue }
        return copy
    }
}

/// `.dde/lifecycle/cycle-time.json`. A missing file is the empty settings; a file that cannot be read is reported and left alone.
enum CycleSettingsFile {
    static func url(projectRoot: URL) -> URL { projectRoot.appendingPathComponent(".dde/lifecycle/cycle-time.json") }

    enum Loaded: Equatable {
        case settings(CycleSettings)
        case unreadable(String)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load(_ url: URL) -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .settings(.empty) }
        do {
            return .settings(try decoder().decode(CycleSettings.self, from: Data(contentsOf: url)))
        } catch {
            return .unreadable("\(url.lastPathComponent) cannot be read (\(error.localizedDescription)); fix or remove it. The statistics ignore it until then.")
        }
    }

    static func save(_ settings: CycleSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

// MARK: - The report

struct CycleSample: Equatable, Sendable, Identifiable {
    let key: String
    let seconds: TimeInterval
    /// When the measured thing ended.
    let at: Date
    let round: Int
    let pace: CyclePace
    var id: String { key }
}

struct CycleLeftOut: Equatable, Sendable {
    let reason: CycleMissing
    let keys: [String]
}

/// The last 30 days against the 30 days before, by when each measure ended.
struct CycleTrend: Equatable, Sendable {
    enum Direction: Sendable { case slower, faster, flat }

    static let window: TimeInterval = 30 * 86_400
    static let minimumSamples = 5
    static let threshold = 0.2

    let recent: TimeInterval
    let previous: TimeInterval
    let recentCount: Int
    let previousCount: Int

    var change: Double { previous > 0 ? (recent - previous) / previous : 0 }

    /// Coloured only when the change is over 20 %; every measure here is better when shorter.
    var direction: Direction {
        if change > Self.threshold { return .slower }
        if change < -Self.threshold { return .faster }
        return .flat
    }

    static func make(_ samples: [CycleSample], now: Date) -> CycleTrend? {
        let recent = samples.filter { $0.at > now.addingTimeInterval(-window) && $0.at <= now }.map(\.seconds)
        let previous = samples.filter { $0.at > now.addingTimeInterval(-2 * window) && $0.at <= now.addingTimeInterval(-window) }.map(\.seconds)
        guard recent.count >= minimumSamples, previous.count >= minimumSamples,
              let r = CycleDistribution.make(recent), let p = CycleDistribution.make(previous) else { return nil }
        return CycleTrend(recent: r.p50, previous: p.p50, recentCount: recent.count, previousCount: previous.count)
    }
}

struct CycleMetricRow: Equatable, Sendable {
    let metric: CycleMetric
    let distribution: CycleDistribution?
    /// Longest first.
    let samples: [CycleSample]
    /// Why the other items have no value, including the ones left out on purpose.
    let leftOut: [CycleLeftOut]
    /// Items that could have a value: not excluded, inside the window.
    let inScope: Int
    let trend: CycleTrend?

    var used: Int { samples.count }
}

struct CycleStatusRow: Equatable, Sendable {
    let status: String
    let role: LifecycleRole?
    /// How long a visit to the status lasted, over the visits that began and ended by real moves.
    let visits: CycleDistribution?
    /// Items in the status now.
    let here: Int
}

struct CycleOpenItem: Equatable, Sendable, Identifiable {
    let key: String
    let status: String
    let role: LifecycleRole
    let entered: Date
    let age: TimeInterval
    /// The stay began at MarkView's first look, so the real age is at least this.
    let ageIsLowerBound: Bool
    let pace: CyclePace
    /// How long visits to this status usually take.
    let usual: CycleDistribution?
    var id: String { key }
}

enum CycleSeverity: Int, Comparable, Sendable {
    case amber = 1, red = 2
    static func < (lhs: CycleSeverity, rhs: CycleSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct CycleAttention: Equatable, Sendable, Identifiable {
    let key: String
    let severity: CycleSeverity
    /// One sentence each: what is wrong and what usual looks like.
    let reasons: [String]
    let age: TimeInterval
    var id: String { key }
}

struct CycleCounts: Equatable, Sendable {
    var total = 0
    var inScope = 0
    var excluded = 0
    var outsideWindow = 0
    var open = 0
    var finished = 0
    var cancelled = 0
    var finishedBeforeSight = 0
    var noHistory = 0
    var good = 0, slow = 0, bad = 0, unknown = 0
}

struct CycleRework: Equatable, Sendable {
    var itemsReopened = 0
    var reopens = 0
    var rollbacks = 0
    var inScope = 0
}

struct CycleModelRow: Equatable, Sendable {
    static let minimumItems = 5
    let model: String
    let distribution: CycleDistribution
    var tooFew: Bool { distribution.count < Self.minimumItems }
}

struct CycleKindReport: Sendable {
    let kind: IssueKind
    let items: [String: CycleItem]
    /// Every item's key, newest activity first.
    let order: [String]
    let rows: [CycleMetricRow]
    let statuses: [CycleStatusRow]
    let open: [CycleOpenItem]
    let attention: [CycleAttention]
    let counts: CycleCounts
    let rework: CycleRework
    /// The cycle time per model; only when some item has a model.
    let models: [CycleModelRow]
    let hasAcceptanceStep: Bool

    func row(_ metric: CycleMetric) -> CycleMetricRow? { rows.first { $0.metric == metric } }
}

/// What the report is built from: all plain values, so it can be built on a background thread.
struct CycleInput: Sendable {
    var items: [CycleItemInfo]
    var records: [TransitionRecord]
    var roles: CycleRoles
    /// The statuses of the project's workflow for a kind, in flow order.
    var statusOrder: @Sendable (IssueKind) -> [String]
    /// The flow has a step from one completed status to another (a person or an AI accepts the delivery).
    var acceptanceStep: @Sendable (IssueKind) -> Bool
    /// An acceptance step starts at this status.
    var acceptsFrom: @Sendable (IssueKind, String) -> Bool
    var settings: CycleSettings
    /// Item key ("bug:BUG-001") → the normalised name of the model that worked on it.
    var models: [String: String] = [:]
    var now: Date
    var calendar: Calendar = .current
}

struct CycleReport: Sendable {
    let generated: Date
    let features: CycleKindReport
    let bugs: CycleKindReport

    func report(_ kind: IssueKind) -> CycleKindReport { kind == .feature ? features : bugs }

    static func make(_ input: CycleInput) -> CycleReport {
        let grouped = Dictionary(grouping: input.records, by: { $0.kind.rawValue + ":" + $0.issue })
        var folded: [CycleItem] = input.items.map { info in
            CycleFolder.fold(info, records: grouped[info.kind.rawValue + ":" + info.issue] ?? [], role: { input.roles.role(info.kind, $0) },
                             now: input.now, calendar: input.calendar)
        }
        markBulk(&folded, calendar: input.calendar)
        for index in folded.indices where input.settings.isExcluded(folded[index].kind, folded[index].issue) { folded[index].marks.insert(.excluded) }
        return CycleReport(generated: input.now,
                           features: kindReport(.feature, folded, input), bugs: kindReport(.bug, folded, input))
    }

    /// Items created in the same minute as at least four others (an import): their creation time is the batch's.
    private static func markBulk(_ items: inout [CycleItem], calendar: Calendar) {
        var minutes: [Date: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard let start = item.rounds.first?.start else { continue }
            let minute = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 60).rounded(.down) * 60)
            minutes[minute, default: []].append(index)
        }
        for indexes in minutes.values where indexes.count >= 5 { for index in indexes { items[index].marks.insert(.bulkCreated) } }
    }

    // MARK: One kind

    private static func kindReport(_ kind: IssueKind, _ all: [CycleItem], _ input: CycleInput) -> CycleKindReport {
        let items = all.filter { $0.kind == kind }
        let settings = input.settings
        func excluded(_ item: CycleItem) -> Bool { settings.isExcluded(item.kind, item.issue) }
        func outside(_ item: CycleItem) -> Bool {
            guard let since = settings.since, let start = item.windowStart else { return false }
            return start < since
        }
        let scope = items.filter { !excluded($0) && !outside($0) }
        var counts = CycleCounts(total: items.count, inScope: scope.count, excluded: items.filter(excluded).count,
                                 outsideWindow: items.filter { !excluded($0) && outside($0) }.count)
        let acceptance = input.acceptanceStep(kind)

        // Metric rows
        var rows: [CycleMetricRow] = []
        for metric in CycleMetric.allCases where metric != .acceptance || acceptance {
            var samples: [(key: String, seconds: TimeInterval, at: Date, round: Int)] = []
            var missing: [CycleMissing: [String]] = [:]
            for item in items {
                if excluded(item) { missing[.excluded, default: []].append(item.key); continue }
                if outside(item) { missing[.outsideWindow, default: []].append(item.key); continue }
                switch item.value(metric) {
                case .value(let seconds, let at, let round): samples.append((item.key, seconds, at, round))
                case .missing(let reason): missing[reason, default: []].append(item.key)
                }
            }
            let distribution = CycleDistribution.make(samples.map(\.seconds))
            let judged = samples.sorted { $0.seconds > $1.seconds }.map {
                CycleSample(key: $0.key, seconds: $0.seconds, at: $0.at, round: $0.round, pace: CyclePace.judge($0.seconds, against: distribution))
            }
            let order: [CycleMissing] = [.notFinished, .neverActive, .skippedActive, .startedBeforeSight, .createdBeforeSight, .finishedBeforeSight,
                                         .notAccepted, .cancelled, .inconsistent, .noHistory, .excluded, .outsideWindow]
            let leftOut = order.compactMap { reason in missing[reason].map { CycleLeftOut(reason: reason, keys: $0.sorted()) } }
            let kept = leftOut.filter { $0.reason != .excluded && $0.reason != .outsideWindow }.reduce(0) { $0 + $1.keys.count }
            rows.append(CycleMetricRow(metric: metric, distribution: distribution, samples: judged, leftOut: leftOut,
                                       inScope: judged.count + kept, trend: CycleTrend.make(judged, now: input.now)))
        }

        // Status rows: how long visits last, from the stays whose entry and exit are both real
        var visits: [String: [TimeInterval]] = [:]
        var here: [String: Int] = [:]
        for item in scope {
            for stay in item.stays where stay.dwellKnown { visits[stay.status, default: []].append(stay.duration(now: stay.entered)) }
            if item.state == .open || item.state == .finished, let current = item.current { here[current.status, default: 0] += 1 }
        }
        var statusOrder = input.statusOrder(kind).map(LifecycleVocabulary.normalize)
        for status in (visits.keys.sorted() + here.keys.sorted()) where !statusOrder.contains(status) { statusOrder.append(status) }
        let statuses = statusOrder.map { status in
            CycleStatusRow(status: status, role: input.roles.role(kind, status), visits: CycleDistribution.make(visits[status] ?? []), here: here[status] ?? 0)
        }
        let statusDistribution = Dictionary(statuses.map { ($0.status, $0.visits) }, uniquingKeysWith: { first, _ in first })
        let acceptanceDistribution = rows.first { $0.metric == .acceptance }?.distribution

        // Open items and the attention list
        var open: [CycleOpenItem] = []
        var attention: [CycleAttention] = []
        var rework = CycleRework(inScope: scope.count)
        for item in scope {
            if item.reopens > 0 { rework.itemsReopened += 1 }
            rework.reopens += item.reopens
            rework.rollbacks += item.rollbacks
            switch item.state {
            case .noHistory: counts.noHistory += 1
            case .cancelled: counts.cancelled += 1
            case .finished:
                if item.rounds.allSatisfy({ $0.completed == nil }) { counts.finishedBeforeSight += 1 } else { counts.finished += 1 }
            case .open: counts.open += 1
            }
            var reasons: [(CycleSeverity, String)] = []
            var age: TimeInterval = 0
            if item.state == .open, let stay = item.current {
                age = stay.duration(now: input.now)
                let role = stay.effectiveRole
                let usual: CycleDistribution? = statusDistribution[stay.status] ?? nil
                let pace: CyclePace = role == .active ? CyclePace.judge(age, against: usual) : .neutral
                open.append(CycleOpenItem(key: item.key, status: stay.status, role: role, entered: stay.entered, age: age,
                                          ageIsLowerBound: !stay.cause.isEvent, pace: pace, usual: usual))
                switch pace {
                case .good: counts.good += 1
                case .slow: counts.slow += 1
                case .bad: counts.bad += 1
                case .unknown: counts.unknown += 1
                case .neutral: break
                }
                if let usual, pace == .slow || pace == .bad {
                    let prefix = stay.cause.isEvent ? "" : "at least "
                    reasons.append((pace == .bad ? .red : .amber,
                                    "\(FeatureVocabulary.label(stay.status)) for \(prefix)\(CycleFormat.duration(age)); usually \(CycleFormat.duration(usual.p50)), 85 % of visits take \(CycleFormat.duration(usual.p85)) or less"))
                }
            }
            if item.state != .finished, item.state != .cancelled, item.reopens > 0 {
                reasons.append((item.reopens > 1 ? .red : .amber, item.reopens == 1 ? "reopened once" : "reopened \(item.reopens) times"))
            }
            if item.state != .finished, item.state != .cancelled, let blocked = item.blocked {
                let why = (blocked.message ?? "the rules refused it").split(separator: "\n").first.map(String.init) ?? "the rules refused it"
                reasons.append((.amber, "the last request to move it was refused: \(String(why.prefix(120)))"))
            }
            if item.state == .finished, let stay = item.current, stay.cause.isEvent, input.acceptsFrom(kind, stay.status),
               let usual = acceptanceDistribution, usual.count >= CyclePace.minimumSamples {
                let waited = stay.duration(now: input.now)
                switch CyclePace.judge(waited, against: usual) {
                case .bad: reasons.append((.red, "completed \(CycleFormat.duration(waited)) ago and not accepted; acceptance usually takes \(CycleFormat.duration(usual.p50))"))
                case .slow: reasons.append((.amber, "completed \(CycleFormat.duration(waited)) ago and not accepted; acceptance usually takes \(CycleFormat.duration(usual.p50))"))
                default: break
                }
                age = waited
            }
            if let worst = reasons.map(\.0).max() {
                attention.append(CycleAttention(key: item.key, severity: worst, reasons: reasons.sorted { $0.0 > $1.0 }.map(\.1), age: age))
            }
        }
        attention.sort { ($0.severity, $0.age) > ($1.severity, $1.age) }
        open.sort { ($0.pace.rank, $0.age) > ($1.pace.rank, $1.age) }

        // Models: the cycle time per model
        var perModel: [String: [TimeInterval]] = [:]
        if let cycle = rows.first(where: { $0.metric == .cycle }) {
            for sample in cycle.samples { if let model = input.models[sample.key] { perModel[model, default: []].append(sample.seconds) } }
        }
        let models = perModel.compactMap { name, values in CycleDistribution.make(values).map { CycleModelRow(model: name, distribution: $0) } }
            .sorted { ($0.distribution.count, $1.model) > ($1.distribution.count, $0.model) }

        let order = items.sorted { ($0.current?.entered ?? .distantPast) > ($1.current?.entered ?? .distantPast) }.map(\.key)
        return CycleKindReport(kind: kind, items: Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }), order: order, rows: rows,
                               statuses: statuses, open: open, attention: attention, counts: counts, rework: rework, models: models,
                               hasAcceptanceStep: acceptance)
    }
}
