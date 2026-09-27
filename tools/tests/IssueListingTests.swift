// Checks the Issues list filter and sort (MarkView/Models/IssueListing.swift) against the
// acceptance criteria of REQ-001, REQ-002 and REQ-005 and decisions DEC-006…DEC-015.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func ids(_ items: [IssueFacts]) -> [String] { items.map(\.id) }

func feature(_ id: String, _ status: String, priority: String = "", updated: String = "", created: String = "",
             modified: Date? = nil, title: String? = nil) -> IssueFacts {
    IssueFacts(kind: .feature, id: id, title: title ?? id, status: status, priority: priority,
               updated: updated, created: created, modified: modified)
}
func bug(_ id: String, _ status: String, severity: String = "", updated: String = "", created: String = "",
         modified: Date? = nil, title: String? = nil) -> IssueFacts {
    IssueFacts(kind: .bug, id: id, title: title ?? id, status: status, priority: severity,
               updated: updated, created: created, modified: modified)
}
func filter(_ toggles: IssueFilterToggle...) -> IssueFilter { IssueFilter(Set(toggles)) }
func shown(_ f: IssueFilter, _ items: [IssueFacts]) -> [String] { ids(items.filter(f.matches)) }

// MARK: Status mapping (REQ-001, DEC-002, DEC-005, user decision on verified/archived)

check("bug fixed is Closed", IssueStatus.isClosed(bug("b", "fixed")))
check("bug closed is Closed", IssueStatus.isClosed(bug("b", "closed")))
check("bug fixed not under Open", !filter(.open).matches(bug("b", "fixed")))
check("bug fixed under Closed", filter(.closed).matches(bug("b", "fixed")))
check("bug fixing is Open", !IssueStatus.isClosed(bug("b", "fixing")))
check("feature done: Closed + Implemented", filter(.closed).matches(feature("f", "done")) && filter(.implemented).matches(feature("f", "done")))
check("feature rejected: Closed + Not Implemented",
      filter(.closed).matches(feature("f", "rejected")) && filter(.notImplemented).matches(feature("f", "rejected")))
check("feature verified: Closed + Implemented", IssueStatus.isClosed(feature("f", "verified")) && IssueStatus.isImplemented(feature("f", "verified")))
check("feature archived: Closed, not Implemented", IssueStatus.isClosed(feature("f", "archived")) && !IssueStatus.isImplemented(feature("f", "archived")))
check("feature implementing: Open", !IssueStatus.isClosed(feature("f", "implementing")))
check("missing feature status: Open", filter(.open).matches(feature("f", "")))
check("missing bug status: Open", filter(.open).matches(bug("b", "")))
check("unknown status: Open", filter(.open).matches(feature("f", "weird")) && filter(.open).matches(bug("b", "weird")))
check("case-insensitive", IssueStatus.isClosed(bug("b", "FIXED")) && IssueStatus.isImplemented(feature("f", "Implemented")))
check("whitespace and separators", IssueStatus.normalize("  In Progress ") == "in-progress" && IssueStatus.normalize("in_progress") == "in-progress")
check("bug closed is not Implemented", !IssueStatus.isImplemented(bug("b", "closed")))

// MARK: Combination (DEC-006, DEC-009)

let all = [feature("f-open", "draft"), feature("f-done", "implemented"), feature("f-rej", "rejected"),
           bug("b-open", "open"), bug("b-fixed", "fixed")]
check("default shows everything", shown(IssueFilter(), all) == ids(all))
check("Open+Closed shows all", shown(filter(.open, .closed), all) == ids(all))
check("Bugs+Features shows all", shown(filter(.bugs, .features), all) == ids(all))
check("Bugs+Open = open bugs", shown(filter(.bugs, .open), all) == ["b-open"])
check("Features+NotImplemented+Open", shown(filter(.features, .notImplemented, .open), all) == ["f-open"])
check("Bugs+Implemented is empty", shown(filter(.bugs, .implemented), all).isEmpty)
check("Implemented never shows bugs", !shown(filter(.implemented), all).contains { $0.hasPrefix("b-") })
check("Not Implemented never shows bugs", !shown(filter(.notImplemented), all).contains { $0.hasPrefix("b-") })
check("Implemented+NotImplemented = all features", shown(filter(.implemented, .notImplemented), all) == ["f-open", "f-done", "f-rej"])
check("Closed+Implemented = implemented features", shown(filter(.closed, .implemented), all) == ["f-done"])
check("summary", filter(.bugs, .open).summary == "Open · Bugs")
check("summary groups", filter(.open, .closed, .features, .notImplemented).summary == "Open, Closed · Features · Not Implemented")
check("default is default", IssueFilter().isDefault && !filter(.open).isDefault)
var toggled = IssueFilter(); toggled.toggle(.open); toggled.toggle(.bugs); toggled.toggle(.open)
check("toggle", toggled == filter(.bugs))

// MARK: Persisted values (REQ-005, DEC-015)

check("filter round trip", IssueFilter(stored: filter(.bugs, .open).storedValue) == filter(.bugs, .open))
check("filter stored in menu order", filter(.bugs, .open).storedValue == ["open", "bugs"])
check("unknown filter ids dropped", IssueFilter(stored: ["open", "gone", "bugs"]) == filter(.open, .bugs))
check("no stored filter = default", IssueFilter(stored: nil).isDefault)
check("sort round trip", IssueSort(stored: IssueSort(field: .priority, descending: false).storedValue) == IssueSort(field: .priority, descending: false))
check("sort stored format", IssueSort().storedValue == "date:desc")
check("unknown sort = default", IssueSort(stored: "size:desc") == .default && IssueSort(stored: "date:up") == .default && IssueSort(stored: "garbage") == .default)
check("no stored sort = date desc", IssueSort(stored: nil) == IssueSort(field: .date, descending: true))
check("keys", IssueListSettings.filterKey("abc") == "features.issues.filter.abc" && IssueListSettings.sortKey("abc") == "features.issues.sort.abc")

// MARK: Dates (REQ-002, DEC-011)

let day = { (s: String) in IssueSort.parseDate(s)! }
check("YYYY-MM-DD parses", IssueSort.parseDate("2026-09-27") != nil)
check("ISO date-time parses", IssueSort.parseDate("2026-09-27T10:00:00Z") != nil)
check("ISO fractional parses", IssueSort.parseDate("2026-09-27T10:00:00.123+02:00") != nil)
check("quoted date parses", IssueSort.parseDate("\"2026-09-27\"") != nil)
check("invalid day rejected", IssueSort.parseDate("2026-02-31") == nil)
check("garbage rejected", IssueSort.parseDate("yesterday") == nil && IssueSort.parseDate("") == nil)
let mtime = day("2020-01-01")
check("updated wins", IssueSort.date(feature("f", "", updated: "2026-09-27", created: "2026-01-01", modified: mtime)) == day("2026-09-27"))
check("created next", IssueSort.date(feature("f", "", created: "2026-01-01", modified: mtime)) == day("2026-01-01"))
check("invalid updated falls through", IssueSort.date(feature("f", "", updated: "soon", created: "2026-01-01")) == day("2026-01-01"))
check("mtime last", IssueSort.date(feature("f", "", modified: mtime)) == mtime)

let dated = [feature("a", "", updated: "2026-03-01"), feature("b", "", created: "2026-05-01"),
             feature("c", "", modified: day("2026-04-01")), feature("none", "")]
check("date desc (default)", ids(IssueSort().sorted(dated) { $0 }) == ["b", "c", "a", "none"])
check("date asc, missing last", ids(IssueSort(field: .date, descending: false).sorted(dated) { $0 }) == ["a", "c", "b", "none"])
let ties = [feature("z2", "", created: "2026-01-01", title: "beta"), feature("z1", "", created: "2026-01-01", title: "Alpha"),
            feature("y", "", created: "2026-01-01", title: "alpha")]
check("ties by title (case-insensitive), then id", ids(IssueSort().sorted(ties) { $0 }) == ["y", "z1", "z2"])

// MARK: Priority (REQ-002, DEC-007)

check("bug scale", IssueSort.priorityRank(bug("b", "", severity: "Blocker")) == 4 && IssueSort.priorityRank(bug("b", "", severity: "normal")) == 2
      && IssueSort.priorityRank(bug("b", "", severity: "trivial")) == 1)
check("feature scale", IssueSort.priorityRank(feature("f", "", priority: "P0")) == 4 && IssueSort.priorityRank(feature("f", "", priority: " High ")) == 3)
check("unknown priority empty", IssueSort.priorityRank(feature("f", "", priority: "urgent-ish")) == nil && IssueSort.priorityRank(bug("b", "")) == nil)
let prioritized = [bug("low", "", severity: "low"), feature("none", ""), feature("crit", "", priority: "p0"),
                   bug("high", "", severity: "high"), bug("unknown", "", severity: "whatever")]
let desc = ids(IssueSort(field: .priority, descending: true).sorted(prioritized) { $0 })
let asc = ids(IssueSort(field: .priority, descending: false).sorted(prioritized) { $0 })
check("priority desc", Array(desc.prefix(3)) == ["crit", "high", "low"])
check("priority asc reverses valued items", Array(asc.prefix(3)) == ["low", "high", "crit"])
check("empty priority last both ways", Set(desc.suffix(2)) == ["none", "unknown"] && Set(asc.suffix(2)) == ["none", "unknown"])
let samePriority = [bug("old", "", severity: "high", created: "2026-01-01"), bug("new", "", severity: "high", created: "2026-06-01")]
check("priority ties: newest first", ids(IssueSort(field: .priority, descending: false).sorted(samePriority) { $0 }) == ["new", "old"])

// MARK: Badge tone

check("tone done", IssueStatus.tone(bug("b", "fixed")) == .done && IssueStatus.tone(feature("f", "verified")) == .done)
check("tone dropped", IssueStatus.tone(feature("f", "rejected")) == .dropped)
check("tone active", IssueStatus.tone(feature("f", "implementing")) == .active && IssueStatus.tone(bug("b", "fixing")) == .active)
check("tone open", IssueStatus.tone(bug("b", "")) == .open)

print(failures == 0 ? "All issue listing checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
