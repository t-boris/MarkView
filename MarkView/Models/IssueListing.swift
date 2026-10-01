import Foundation

// Filtering and sorting of the Issues list (issue #24): features and bugs by status, type and
// implementation, ordered by date or priority. Foundation only, so
// tools/tests/issue-listing-tests.sh compiles it on its own.

/// What the Issues list reads from a feature or bug to filter and sort it.
struct IssueFacts: Equatable {
    enum Kind: Equatable { case feature, bug }

    var kind: Kind
    /// Slug of a feature, key of a bug ("BUG-012").
    var id: String
    var title: String
    /// Status as written in the file; "" when there is none.
    var status: String
    /// Feature `priority` or bug `severity` as written.
    var priority: String = ""
    var updated: String = ""
    var created: String = ""
    /// Modification time of the item's file(s).
    var modified: Date? = nil
}

/// Status values as the filters understand them (DEC-002, DEC-005, DEC-014).
enum IssueStatus {
    /// "In Progress", " in_progress " → "in-progress".
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
    }

    /// Delivered features. `done` is accepted for features written by hand.
    static let implementedFeature: Set<String> = ["implemented", "verified", "done"]
    /// Features that are over, delivered or not.
    static let closedFeature = implementedFeature.union(["archived", "rejected", "cancelled", "canceled"])
    static let closedBug: Set<String> = ["closed", "fixed"]
    /// Work under way: shown in its own colour.
    static let inProgress: Set<String> = ["implementing", "fixing", "in-progress"]

    /// Anything not closed — including a missing or unknown status — is open.
    static func isClosed(_ facts: IssueFacts) -> Bool {
        let status = normalize(facts.status)
        return facts.kind == .feature ? closedFeature.contains(status) : closedBug.contains(status)
    }

    /// Only features are implemented or not; a bug is neither.
    static func isImplemented(_ facts: IssueFacts) -> Bool {
        facts.kind == .feature && implementedFeature.contains(normalize(facts.status))
    }

    /// How a status badge reads at a glance.
    enum Tone: Equatable { case open, active, done, dropped }

    static func tone(_ facts: IssueFacts) -> Tone {
        let status = normalize(facts.status)
        if inProgress.contains(status) { return .active }
        guard isClosed(facts) else { return .open }
        return facts.kind == .bug || isImplemented(facts) ? .done : .dropped
    }
}

/// One entry of the funnel menu.
enum IssueFilterToggle: String, CaseIterable {
    case open, closed, bugs, features, implemented
    case notImplemented = "not-implemented"

    /// Toggles of a group combine with OR, groups with AND (DEC-006).
    enum Group: CaseIterable {
        case status, type, implementation

        var title: String {
            switch self {
            case .status: return "Status"
            case .type: return "Type"
            case .implementation: return "Implementation"
            }
        }

        var toggles: [IssueFilterToggle] { IssueFilterToggle.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .open, .closed: return .status
        case .bugs, .features: return .type
        case .implemented, .notImplemented: return .implementation
        }
    }

    var title: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .bugs: return "Bugs"
        case .features: return "Features"
        case .implemented: return "Implemented"
        case .notImplemented: return "Not Implemented"
        }
    }
}

/// The funnel filter. Empty = everything is shown (DEC-008).
struct IssueFilter: Equatable {
    var selected: Set<IssueFilterToggle> = []

    var isDefault: Bool { selected.isEmpty }

    mutating func toggle(_ item: IssueFilterToggle) {
        if selected.contains(item) { selected.remove(item) } else { selected.insert(item) }
    }

    func matches(_ facts: IssueFacts) -> Bool {
        let status = selected.filter { $0.group == .status }
        if status.count == 1, status.contains(.closed) != IssueStatus.isClosed(facts) { return false }
        let type = selected.filter { $0.group == .type }
        if type.count == 1, type.contains(.bugs) != (facts.kind == .bug) { return false }
        let implementation = selected.filter { $0.group == .implementation }
        if !implementation.isEmpty {
            // Implementation is a property of features only: choosing it leaves the bugs out.
            if facts.kind == .bug { return false }
            if implementation.count == 1, implementation.contains(.implemented) != IssueStatus.isImplemented(facts) { return false }
        }
        return true
    }

    /// "Open · Bugs", "Open, Closed · Features · Not Implemented".
    var summary: String {
        IssueFilterToggle.Group.allCases.compactMap { group in
            let titles = group.toggles.filter(selected.contains).map(\.title)
            return titles.isEmpty ? nil : titles.joined(separator: ", ")
        }.joined(separator: " · ")
    }

    /// Stored as the ids of the selected toggles, in menu order.
    var storedValue: [String] { IssueFilterToggle.allCases.filter(selected.contains).map(\.rawValue) }

    /// Unknown ids (from another version) are dropped.
    init(stored: [String]?) {
        selected = Set((stored ?? []).compactMap(IssueFilterToggle.init(rawValue:)))
    }

    init(_ selected: Set<IssueFilterToggle> = []) { self.selected = selected }
}

/// Order of the items within each section of the list (DEC-003, DEC-007, DEC-011).
struct IssueSort: Equatable {
    enum Field: String, CaseIterable {
        case date, priority

        var title: String { self == .date ? "Date" : "Priority" }
    }

    var field: Field = .date
    /// Newest first for dates, highest first for priority.
    var descending = true

    static let `default` = IssueSort()

    var directionTitle: String { Self.directionTitle(field, descending: descending) }

    static func directionTitle(_ field: Field, descending: Bool) -> String {
        switch field {
        case .date: return descending ? "Newest First" : "Oldest First"
        case .priority: return descending ? "Highest First" : "Lowest First"
        }
    }

    /// "date:desc", "priority:asc".
    var storedValue: String { field.rawValue + ":" + (descending ? "desc" : "asc") }

    init(field: Field = .date, descending: Bool = true) {
        self.field = field
        self.descending = descending
    }

    /// A stored value this version does not know falls back to the default.
    init(stored: String?) {
        let parts = (stored ?? "").split(separator: ":").map(String.init)
        guard parts.count == 2, let field = Field(rawValue: parts[0]), ["asc", "desc"].contains(parts[1]) else {
            self = .default
            return
        }
        self.init(field: field, descending: parts[1] == "desc")
    }

    /// Items with no value for the field come last in both directions. Ties: priority by date
    /// (newest first), then by id in the order of the dates (BUG-017).
    func sorted<Item>(_ items: [Item], facts: (Item) -> IssueFacts) -> [Item] {
        let keyed = items.map { item -> (item: Item, facts: IssueFacts, date: Date?, value: Double?) in
            let itemFacts = facts(item)
            let date = Self.date(itemFacts)
            let value = field == .date ? date?.timeIntervalSinceReferenceDate : Self.priorityRank(itemFacts).map(Double.init)
            return (item, itemFacts, date, value)
        }
        let newestFirst = field == .date ? descending : true
        return keyed.sorted { a, b in
            switch (a.value, b.value) {
            case let (x?, y?) where x != y: return descending ? x > y : x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if field == .priority {
                switch (a.date, b.date) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            // Front matter dates name a day, so everything filed that day ties. Ids are given in
            // filing order ("BUG-021" after "BUG-020"), so they keep the list in that order; a title
            // tie-breaker shuffled a day's items alphabetically (BUG-017).
            return Self.idsNewestFirst(a.facts.id, b.facts.id) == newestFirst
        }.map(\.item)
    }

    /// Whether `a` was filed after `b`: ids compare with their numbers ("BUG-21" after "BUG-9").
    static func idsNewestFirst(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedDescending
    }

    /// `updated`, else `created`, else the file's modification time.
    static func date(_ facts: IssueFacts) -> Date? {
        parseDate(facts.updated) ?? parseDate(facts.created) ?? facts.modified
    }

    /// YYYY-MM-DD (start of that day, local time) or an ISO 8601 date-time; nil otherwise.
    static func parseDate(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            let calendar = Calendar.current
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            // 2026-02-31 would roll over into March: not a date.
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            return back.year == year && back.month == month && back.day == day ? date : nil
        }
        return isoFormatter.date(from: text) ?? isoFractionalFormatter.date(from: text)
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// critical 4 > high 3 > medium 2 > low 1; nil when absent or unknown (DEC-007).
    static func priorityRank(_ facts: IssueFacts) -> Int? {
        let value = IssueStatus.normalize(facts.priority)
        switch facts.kind {
        case .bug: return bugSeverityRanks[value]
        case .feature: return featurePriorityRanks[value]
        }
    }

    static let bugSeverityRanks = ["blocker": 4, "critical": 4, "high": 3, "medium": 2, "normal": 2,
                                   "low": 1, "minor": 1, "trivial": 1]
    static let featurePriorityRanks = ["critical": 4, "p0": 4, "high": 3, "p1": 3, "medium": 2, "p2": 2,
                                       "low": 1, "p3": 1]
}

/// Per-project keys of the filter and sort (DEC-015); `project` is the 12-character root hash.
enum IssueListSettings {
    static func filterKey(_ project: String) -> String { "features.issues.filter." + project }
    static func sortKey(_ project: String) -> String { "features.issues.sort." + project }
}
