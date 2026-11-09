import Foundation

// Checks for MarkView/Models/CycleTime.swift and CycleTimeReport.swift (feature cycle-time-as-a-view-over-the-workflow), run by
// tools/tests/cycle-time-tests.sh. Fixtures are journal records; nothing touches a file but the settings round trip in a temp folder.

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
let hour: TimeInterval = 3600, dayLength: TimeInterval = 86_400
/// Hours after 08:00 of the fixture day.
func at(_ hours: Double) -> Date { day0.addingTimeInterval(8 * hour + hours * hour) }
let createdToday = day0
let createdEarlier = day0.addingTimeInterval(-3 * dayLength)

func rec(_ phase: TransitionRecord.Phase = .applied, _ kind: IssueKind = .bug, _ issue: String = "B1", to: String, at time: Date,
         kindOfStep: TransitionKind? = nil, actor: LifecycleActor = .human("boris"), override: Bool = false, message: String? = nil) -> TransitionRecord {
    TransitionRecord(phase: phase, command: "t", kind: kind, issue: issue, to: to, actor: actor, at: time, transitionKind: kindOfStep,
                     override: override, message: message)
}

func baseline(_ kind: IssueKind = .bug, _ issue: String = "B1", _ status: String, _ time: Date) -> TransitionRecord {
    rec(.baseline, kind, issue, to: status, at: time, actor: .system("MarkView"))
}

let kanban = WorkflowFlow.kanban
let roles = CycleRoles(
    workflow: { kind, status in kanban.lifecycle(kind).role(of: status) },
    known: { kind, status in
        if let role = ProjectWorkflow.standard.role(kind, status) { return role }
        for flow in WorkflowFlow.catalogue { if let role = flow.lifecycle(kind).role(of: status) { return role } }
        return nil
    })
let standardRoles = CycleRoles(workflow: { kind, status in ProjectWorkflow.standard.role(kind, status) }, known: { _, _ in nil })

func info(_ kind: IssueKind = .bug, _ issue: String = "B1", status: String = "done", created: Date? = createdToday) -> CycleItemInfo {
    CycleItemInfo(kind: kind, issue: issue, title: issue + " title", status: status, created: created)
}

func fold(_ item: CycleItemInfo, _ records: [TransitionRecord], roles: CycleRoles = roles, now: Date = at(1000)) -> CycleItem {
    CycleFolder.fold(item, records: records, role: { roles.role(item.kind, $0) }, now: now)
}

func hours(_ value: CycleValue) -> Double? { value.seconds.map { $0 / hour } }
func missing(_ value: CycleValue) -> CycleMissing? { if case .missing(let reason) = value { return reason }; return nil }

// MARK: - A Kanban bug from creation to done

do {
    let item = fold(info(status: "done"), [
        baseline(.bug, "B1", "backlog", at(0)),
        rec(to: "in-progress", at: at(2), kindOfStep: .start),
        rec(to: "in-review", at: at(5)),
        rec(to: "done", at: at(9), kindOfStep: .completion),
    ])
    check("kanban: waiting is creation to the first active status", hours(item.value(.waiting)) == 2)
    check("kanban: cycle time is the first active to the first completed status", hours(item.value(.cycle)) == 7)
    check("kanban: lead time is creation to completion", hours(item.value(.lead)) == 9)
    check("kanban: no acceptance lag where nobody accepts", missing(item.value(.acceptance)) == .notAccepted)
    check("kanban: finished, one round, no marks", item.state == .finished && item.rounds.count == 1 && item.marks.isEmpty)
    let dwell = item.dwell(in: item.rounds[0]).map { "\($0.status)=\($0.seconds / hour)" }
    check("kanban: time in status counts only visits that began and ended by real moves", dwell == ["in-progress=3.0", "in-review=4.0"])
    check("kanban: the first look is not an event", item.stays[0].cause == .firstSight && !item.stays[0].dwellKnown)
    check("kanban: who made a move reads as a person would say it", item.stays[0].actorText == "MarkView (system)" && item.stays[1].actorText == "boris")
}

// MARK: - An item that existed before MarkView first saw it

do {
    let item = fold(info(created: createdEarlier), [
        baseline(.bug, "B1", "backlog", at(0)),
        rec(to: "in-progress", at: at(2), kindOfStep: .start),
        rec(to: "done", at: at(5), kindOfStep: .completion),
    ])
    check("old item: waiting and lead time are unknown", missing(item.value(.waiting)) == .createdBeforeSight && missing(item.value(.lead)) == .createdBeforeSight)
    check("old item: cycle time is still measured", hours(item.value(.cycle)) == 3)
    check("old item: marked", item.marks.contains(.createdBeforeSight))
    let noDate = fold(info(created: nil), [baseline(.bug, "B1", "backlog", at(0)), rec(to: "done", at: at(1), kindOfStep: .completion)])
    check("an item with no created date has an unknown start", missing(noDate.value(.lead)) == .createdBeforeSight)
}

// MARK: - Already under way or already done when first seen

do {
    let active = fold(info(created: createdEarlier), [baseline(.bug, "B1", "in-progress", at(0)), rec(to: "done", at: at(4), kindOfStep: .completion)])
    check("under way at first sight: cycle time unknown", missing(active.value(.cycle)) == .startedBeforeSight)
    check("under way at first sight: the item is still finished", active.state == .finished)
    let done = fold(info(created: createdEarlier), [baseline(.bug, "B1", "done", at(0))])
    check("done at first sight: nothing is measured", [CycleMetric.waiting, .cycle, .lead].allSatisfy { missing(done.value($0)) != nil })
    check("done at first sight: the reason is said", missing(done.value(.cycle)) == .finishedBeforeSight && missing(done.value(.lead)) == .createdBeforeSight)
}

// MARK: - A flow change is not work (the Kanban switch of 2026-11-09)

do {
    // Feature in the old flow: real start and completion, then the flow lost `implemented` and a person moved it to `done`.
    let item = fold(info(.feature, "F1", status: "done"), [
        baseline(.feature, "F1", "ready", at(0)),
        rec(.applied, .feature, "F1", to: "implementing", at: at(1), kindOfStep: .start),
        rec(.applied, .feature, "F1", to: "implemented", at: at(3), kindOfStep: .completion),
        rec(.applied, .feature, "F1", to: "done", at: at(500), kindOfStep: .replacement),
    ])
    check("replacement: the completion time is the real one", hours(item.value(.cycle)) == 2 && hours(item.value(.lead)) == 3)
    check("replacement: marked, and the item is finished", item.marks.contains(.replaced) && item.state == .finished)
    check("replacement: moving between completed statuses is not an acceptance", item.rounds[0].accepted == nil)

    // Waiting item that a flow change moved into a status where work is under way: nobody started it.
    let moved = fold(info(.feature, "F4", status: "in-progress"), [
        baseline(.feature, "F4", "ready", at(0)),
        rec(.applied, .feature, "F4", to: "in-progress", at: at(500), kindOfStep: .replacement),
    ])
    check("replacement: a waiting item moved into an active status has not started", moved.rounds[0].firstActive == nil && moved.rounds[0].startedBeforeSight
          && missing(moved.value(.cycle)) == .startedBeforeSight)
    check("replacement: the statuses of dropped flows keep their roles", item.stays[1].role == .active && item.stays[2].role == .completed)

    // A bug that was `fixed` before the switch and is only `done` by replacement.
    let bug = fold(info(.bug, "B2", created: createdEarlier), [
        baseline(.bug, "B2", "fixed", at(0)),
        rec(.applied, .bug, "B2", to: "done", at: at(500), kindOfStep: .replacement),
    ])
    check("replacement: a rewritten completed status is not a completion", missing(bug.value(.cycle)) == .finishedBeforeSight && bug.rounds[0].completed == nil)

    // Mid-flow: real start, then the status of the work was replaced by another one that is also under way.
    let mid = fold(info(.feature, "F3", status: "in-progress"), [
        baseline(.feature, "F3", "ready", at(0)),
        rec(.applied, .feature, "F3", to: "implementing", at: at(2), kindOfStep: .start),
        rec(.applied, .feature, "F3", to: "in-progress", at: at(500), kindOfStep: .replacement),
        rec(.applied, .feature, "F3", to: "done", at: at(510), kindOfStep: .completion),
    ])
    check("replacement: work that went on across it keeps its real start", mid.rounds[0].firstActive == at(2) && hours(mid.value(.cycle)) == 508)
    check("replacement: a stay cut off by it has no known length", mid.stays[1].dwellKnown == false && mid.stays[2].dwellKnown == false)
}

// MARK: - Reopening starts a round

do {
    let item = fold(info(.bug, "B1", status: "fixed"), [
        baseline(.bug, "B1", "open", at(0)),
        rec(to: "fixing", at: at(1), kindOfStep: .start),
        rec(to: "fixed", at: at(3), kindOfStep: .completion),
        rec(to: "closed", at: at(10), kindOfStep: .acceptance),
        rec(to: "open", at: at(20), kindOfStep: .reopen),
        rec(to: "fixing", at: at(21), kindOfStep: .start),
        rec(to: "fixed", at: at(25), kindOfStep: .completion),
    ], roles: standardRoles)
    check("reopen: two rounds and one rework", item.rounds.count == 2 && item.reopens == 1)
    check("reopen: the second round begins at the reopening", item.rounds[1].start == at(20))
    check("reopen: durations use the latest round that has them", hours(item.value(.waiting)) == 1 && hours(item.value(.cycle)) == 4 && hours(item.value(.lead)) == 5)
    check("reopen: acceptance falls back to the round that has it", hours(item.value(.acceptance)) == 7)
    if case .value(_, _, let round) = item.value(.acceptance) { check("reopen: and says which round", round == 0) } else { check("reopen: acceptance has a value", false) }
    check("reopen: the first round keeps its own numbers", hours(item.value(.cycle, in: item.rounds[0])) == 2)
}

// MARK: - Rollback, outside edits, cancellation, shortcuts, acceptance, unknown statuses, clocks

do {
    let rollback = fold(info(.feature, "F1", status: "done"), [
        baseline(.feature, "F1", "ready", at(0)),
        rec(.applied, .feature, "F1", to: "implementing", at: at(1), kindOfStep: .start),
        rec(.applied, .feature, "F1", to: "ready", at: at(2), kindOfStep: .rollback),
        rec(.applied, .feature, "F1", to: "implementing", at: at(6), kindOfStep: .start),
        rec(.applied, .feature, "F1", to: "implemented", at: at(8), kindOfStep: .completion),
    ], roles: standardRoles)
    check("rollback: counted, and the first start stays the start", rollback.rollbacks == 1 && rollback.rounds[0].firstActive == at(1) && hours(rollback.value(.cycle)) == 7)

    let outside = fold(info(status: "done"), [
        baseline(.bug, "B1", "backlog", at(0)),
        rec(.external, .bug, "B1", to: "in-progress", at: at(2)),
        rec(to: "done", at: at(4), kindOfStep: .completion),
    ])
    check("outside edit: counted at the time it was found, and marked", hours(outside.value(.cycle)) == 2 && outside.marks.contains(.outsideEdit))

    let cancelled = fold(info(status: "wont-do"), [
        baseline(.bug, "B1", "backlog", at(0)),
        rec(to: "in-progress", at: at(2), kindOfStep: .start),
        rec(to: "wont-do", at: at(3), kindOfStep: .cancellation),
    ])
    check("cancelled: waiting is real, cycle and lead are not", hours(cancelled.value(.waiting)) == 2 && missing(cancelled.value(.cycle)) == .cancelled && missing(cancelled.value(.lead)) == .cancelled)
    check("cancelled: the state", cancelled.state == .cancelled && cancelled.rounds[0].cancelled == at(3))

    let straight = fold(info(status: "done"), [baseline(.bug, "B1", "backlog", at(0)), rec(to: "done", at: at(4), kindOfStep: .completion)])
    check("straight to done: lead time yes, waiting and cycle time say why not",
          hours(straight.value(.lead)) == 4 && missing(straight.value(.waiting)) == .skippedActive && missing(straight.value(.cycle)) == .skippedActive)

    let accepted = fold(info(.feature, "F1", status: "verified"), [
        baseline(.feature, "F1", "ready", at(0)),
        rec(.applied, .feature, "F1", to: "implementing", at: at(1), kindOfStep: .start),
        rec(.applied, .feature, "F1", to: "implemented", at: at(3), kindOfStep: .completion),
        rec(.applied, .feature, "F1", to: "verified", at: at(30), kindOfStep: .acceptance),
    ], roles: standardRoles)
    check("acceptance lag: completed to accepted", hours(accepted.value(.acceptance)) == 27)

    let notAccepted = fold(info(.feature, "F1", status: "implemented"), [
        baseline(.feature, "F1", "ready", at(0)),
        rec(.applied, .feature, "F1", to: "implementing", at: at(1), kindOfStep: .start),
        rec(.applied, .feature, "F1", to: "implemented", at: at(3), kindOfStep: .completion),
    ], roles: standardRoles)
    check("acceptance lag: not accepted yet is said", missing(notAccepted.value(.acceptance)) == .notAccepted)

    let unknown = fold(info(status: "blocked-by-legal"), [baseline(.bug, "B1", "backlog", at(0)), rec(to: "blocked-by-legal", at: at(1))])
    check("unknown status: no role, counted as waiting, marked", unknown.stays[1].role == nil && unknown.state == .open && unknown.marks.contains(.unknownStatus))

    let skew = fold(info(status: "done"), [baseline(.bug, "B1", "backlog", at(5)), rec(to: "in-progress", at: at(3)), rec(to: "done", at: at(8), kindOfStep: .completion)])
    check("clock skew: moved forward to keep the order, marked", skew.stays[1].entered == at(5) && skew.marks.contains(.clockSkew))

    let nothing = fold(info(), [])
    check("no history: a state of its own", nothing.state == .noHistory && nothing.marks == [.noHistory] && missing(nothing.value(.cycle)) == .noHistory)

    let refused = fold(info(status: "backlog"), [
        baseline(.bug, "B1", "backlog", at(0)),
        rec(.rejected, .bug, "B1", to: "done", at: at(2), message: "Delivery evidence is missing."),
    ])
    check("a refused request after the last change is kept", refused.blocked?.message == "Delivery evidence is missing.")
    let moved = fold(info(status: "in-progress"), [
        baseline(.bug, "B1", "backlog", at(0)),
        rec(.rejected, .bug, "B1", to: "done", at: at(2), message: "no"),
        rec(to: "in-progress", at: at(3), kindOfStep: .start),
    ])
    check("a refusal before the last change is history", moved.blocked == nil)

    let forced = fold(info(status: "done"), [baseline(.bug, "B1", "backlog", at(0)), rec(to: "done", at: at(1), kindOfStep: .completion, override: true)])
    check("a forced step is marked", forced.marks.contains(.forced))
}

// MARK: - Roles of statuses

do {
    check("roles: the workflow answers first", roles.role(.bug, "in-review") == .active)
    check("roles: a dropped status keeps its role from the flows MarkView knows", roles.role(.feature, "implemented") == .completed && roles.role(.bug, "fixing") == .active)
    check("roles: a status written by hand is read by its words", CycleRoles(workflow: { _, _ in nil }, known: { _, _ in nil }).role(.feature, "Done") == .completed)
    check("roles: and a rejected feature is dropped work", CycleRoles(workflow: { _, _ in nil }, known: { _, _ in nil }).role(.feature, "rejected") == .cancelled)
    check("roles: a name nothing knows has none", CycleRoles(workflow: { _, _ in nil }, known: { _, _ in nil }).role(.bug, "zebra") == nil)
}

// MARK: - Distribution, pace, format

do {
    let values = (1...10).map { Double($0) * hour }
    let d = CycleDistribution.make(values)!
    check("distribution: median, P85, bounds, mean", d.p50 == 5.5 * hour && d.p85 == 9 * hour && d.lowest == hour && d.highest == 10 * hour && d.mean == 5.5 * hour && d.count == 10)
    check("distribution: one value", CycleDistribution.make([hour])!.p85 == hour)
    check("distribution: nothing", CycleDistribution.make([]) == nil)
    check("pace: at most the median is good", CyclePace.judge(5 * hour, against: d) == .good && CyclePace.judge(5.5 * hour, against: d) == .good)
    check("pace: up to P85 is slow, above is bad", CyclePace.judge(8 * hour, against: d) == .slow && CyclePace.judge(9 * hour, against: d) == .slow && CyclePace.judge(9.5 * hour, against: d) == .bad)
    check("pace: under eight samples there is no colour", CyclePace.judge(100 * hour, against: CycleDistribution.make((1...7).map { Double($0) * hour })) == .unknown)
    check("pace: no distribution, no colour", CyclePace.judge(hour, against: nil) == .unknown)
    check("format: days, hours, minutes", CycleFormat.duration(2 * dayLength + 3 * hour + 15 * 60) == "2d 3h 15m" && CycleFormat.duration(90 * 60) == "1h 30m" && CycleFormat.duration(5 * 60) == "5m")
    check("format: under a minute", CycleFormat.duration(20) == "<1m" && CycleFormat.duration(0) == "0m")
}

// MARK: - The report

/// A bug that waited `wait` hours, was worked on for `work` hours and finished `done` hours after 08:00 of the fixture day.
func finishedBug(_ id: String, wait: Double, work: Double, begin: Double = 0) -> (CycleItemInfo, [TransitionRecord]) {
    (info(.bug, id, status: "done", created: calendar.startOfDay(for: at(begin))),
     [baseline(.bug, id, "backlog", at(begin)),
      rec(.applied, .bug, id, to: "in-progress", at: at(begin + wait), kindOfStep: .start),
      rec(.applied, .bug, id, to: "done", at: at(begin + wait + work), kindOfStep: .completion)])
}

func input(_ items: [(CycleItemInfo, [TransitionRecord])], settings: CycleSettings = .empty, now: Date = at(2000), models: [String: String] = [:]) -> CycleInput {
    CycleInput(items: items.map(\.0), records: items.flatMap(\.1), roles: roles,
               statusOrder: { kind in kanban.lifecycle(kind).statusIDs }, acceptanceStep: { _ in false }, acceptsFrom: { _, _ in false },
               settings: settings, models: models, now: now)
}

do {
    var items = (1...10).map { finishedBug("B\($0)", wait: 1, work: Double($0)) }
    // Open items in progress for 12 h (beyond P85 = 9 h), 7 h (above the median) and 3 h; one in the backlog for ages.
    func openBug(_ id: String, since: Double, status: String = "in-progress") -> (CycleItemInfo, [TransitionRecord]) {
        (info(.bug, id, status: status, created: calendar.startOfDay(for: at(since - 1))),
         [baseline(.bug, id, "backlog", at(since - 1)), rec(.applied, .bug, id, to: status, at: at(since), kindOfStep: .start)])
    }
    let now = at(2000)
    items.append(openBug("B20", since: 2000 - 12))
    items.append(openBug("B21", since: 2000 - 7))
    items.append(openBug("B22", since: 2000 - 3))
    items.append((info(.bug, "B23", status: "backlog"), [baseline(.bug, "B23", "backlog", at(0))]))
    let report = CycleReport.make(input(items, now: now)).bugs

    check("report: ten finished bugs are the cycle samples", report.row(.cycle)?.used == 10 && report.row(.cycle)?.distribution?.p50 == 5.5 * hour)
    check("report: the cycle row counts every item in scope", report.row(.cycle)?.inScope == 14)
    check("report: and says why the others are left out", report.row(.cycle)?.leftOut.map { "\($0.reason.rawValue):\($0.keys.count)" } == ["not-finished:3", "never-active:1"])
    check("report: the used items and the left-out ones add up to all of them", (report.row(.cycle)?.used ?? 0) + (report.row(.cycle)?.leftOut.reduce(0) { $0 + $1.keys.count } ?? 0) == 14)
    check("report: samples are longest first with their pace", report.row(.cycle)?.samples.first?.key == "bug:B10" && report.row(.cycle)?.samples.first?.pace == .bad
          && report.row(.cycle)?.samples.last?.pace == .good)
    var same = true
    for row in report.rows { for sample in row.samples { same = same && report.items[sample.key]?.value(row.metric).seconds == sample.seconds } }
    check("report: the item detail shows the same number as the summary row", same && !report.rows.isEmpty)
    check("report: no acceptance row where the flow has no acceptance", report.row(.acceptance) == nil && report.hasAcceptanceStep == false)
    let inProgress = report.statuses.first { $0.status == "in-progress" }
    check("report: a status row knows how long visits last, and an open visit is not one of them", inProgress?.visits?.count == 10 && inProgress?.here == 3)
    check("report: the open items are judged by their age in the status",
          Dictionary(uniqueKeysWithValues: report.open.map { ($0.key, $0.pace) }) == ["bug:B20": .bad, "bug:B21": .slow, "bug:B22": .good, "bug:B23": .neutral])
    check("report: the backlog is not judged", report.open.first { $0.key == "bug:B23" }?.pace == .neutral)
    check("report: attention lists the red before the amber, with a sentence", report.attention.map(\.key) == ["bug:B20", "bug:B21"] && report.attention.first?.severity == .red
          && report.attention.first?.reasons.first?.contains("usually") == true)
    let sum = report.counts.finished + report.counts.open + report.counts.cancelled + report.counts.finishedBeforeSight + report.counts.noHistory
    check("report: every counted item is in exactly one state", sum == report.counts.inScope)
    check("report: counts", report.counts.total == 14 && report.counts.finished == 10 && report.counts.open == 4 && report.counts.bad == 1 && report.counts.slow == 1 && report.counts.good == 1)

    // Pace needs eight finished visits: seven give no colour at all.
    let few = CycleReport.make(input(Array(items.prefix(7)) + [openBug("B20", since: 2000 - 50)], now: now)).bugs
    check("report: too little history gives no pace and no attention", few.open.first { $0.key == "bug:B20" }?.pace == .unknown && few.attention.isEmpty)

    // Exclusion and window
    let excluded = CycleReport.make(input(items, settings: CycleSettings.empty.excluding(.bug, "B10", reason: "test data"), now: now)).bugs
    check("settings: an excluded item leaves every row and is listed as such", excluded.row(.cycle)?.used == 9 && excluded.row(.cycle)?.leftOut.last?.reason == .excluded
          && excluded.counts.excluded == 1 && excluded.items["bug:B10"]?.marks.contains(.excluded) == true)
    check("settings: including it again brings it back", CycleSettings.empty.excluding(.bug, "B10", reason: "x").including(.bug, "B10").excluded.isEmpty)
    let windowed = CycleReport.make(input(items, settings: CycleSettings(since: at(2000 - 20), excluded: []), now: now)).bugs
    check("settings: Measure since leaves out items whose round began earlier", windowed.row(.cycle)?.used == 0 && windowed.counts.outsideWindow == 11 && windowed.counts.inScope == 3)
    check("settings: and says so in the row", windowed.row(.cycle)?.leftOut.contains { $0.reason == .outsideWindow && $0.keys.count == 11 } == true)

    // Duplicate infos do not trap (BUG-114).
    let twice = CycleReport.make(input([items[0], items[0]], now: now)).bugs
    check("report: a repeated item does not trap", twice.items.count == 1)
}

// MARK: - The flow change does not move the numbers

do {
    var plain = (1...9).map { finishedBug("B\($0)", wait: 1, work: Double($0)) }
    let before = CycleReport.make(input(plain, now: at(900))).bugs
    // The same items, each rewritten from `done` to a status the new flow calls differently, in one second.
    plain = plain.map { item in
        let id = item.0.issue
        var records = item.1
        records.append(rec(.applied, .bug, id, to: "fixed", at: at(800), kindOfStep: .replacement))
        records.append(rec(.applied, .bug, id, to: "done", at: at(800.001), kindOfStep: .replacement))
        return (item.0, records)
    }
    let after = CycleReport.make(input(plain, now: at(900))).bugs
    for metric in [CycleMetric.waiting, .cycle, .lead] {
        check("flow change: \(metric.rawValue) is the same with the 2026-11-09 style rewrite", before.row(metric)?.distribution == after.row(metric)?.distribution)
    }
    check("flow change: the items are marked, not counted", after.items.values.allSatisfy { $0.marks.contains(.replaced) })
}

// MARK: - Trend, rework, facts

do {
    let now = at(24 * 80)
    // Ten finished bugs: five finished 40..60 days ago taking 2 h, five finished within 20 days taking 4 h.
    var items: [(CycleItemInfo, [TransitionRecord])] = []
    for n in 0..<5 { items.append(finishedBug("P\(n)", wait: 1, work: 2, begin: 24 * Double(20 + n * 3))) }
    for n in 0..<5 { items.append(finishedBug("R\(n)", wait: 1, work: 4, begin: 24 * Double(62 + n * 3))) }
    let trend = CycleReport.make(input(items, now: now)).bugs.row(.cycle)?.trend
    check("trend: the last 30 days against the 30 before", trend != nil && trend?.recent == 4 * hour && trend?.previous == 2 * hour && trend?.direction == .slower)
    check("trend: the change is a share of the earlier median", trend.map { abs($0.change - 1.0) < 0.0001 } == true)
    let thin = CycleReport.make(input(Array(items.dropFirst()), now: now)).bugs.row(.cycle)?.trend
    check("trend: under five samples in a window there is none", thin == nil)

    // Rework and facts
    let reopened = (info(.bug, "B90", status: "open"), [
        baseline(.bug, "B90", "open", at(0)),
        rec(.applied, .bug, "B90", to: "fixing", at: at(1), kindOfStep: .start),
        rec(.applied, .bug, "B90", to: "fixed", at: at(2), kindOfStep: .completion),
        rec(.applied, .bug, "B90", to: "open", at: at(3), kindOfStep: .reopen),
        rec(.applied, .bug, "B90", to: "fixing", at: at(4), kindOfStep: .start),
        rec(.applied, .bug, "B90", to: "fixed", at: at(5), kindOfStep: .completion),
        rec(.applied, .bug, "B90", to: "open", at: at(6), kindOfStep: .reopen),
    ])
    let blocked = (info(.bug, "B91", status: "backlog"), [baseline(.bug, "B91", "backlog", at(0)), rec(.rejected, .bug, "B91", to: "done", at: at(2), message: "Delivery evidence is missing.\nMore text.")])
    let standardInput = CycleInput(items: [reopened.0, blocked.0], records: reopened.1 + blocked.1, roles: standardRoles,
                                   statusOrder: { ProjectWorkflow.standard.lifecycle($0).statusIDs }, acceptanceStep: { _ in true },
                                   acceptsFrom: { _, _ in false }, settings: .empty, now: at(100))
    let report = CycleReport.make(standardInput).bugs
    check("facts: reopened twice is red", report.attention.first { $0.key == "bug:B90" }?.severity == .red && report.attention.first { $0.key == "bug:B90" }?.reasons == ["reopened 2 times"])
    check("facts: a refused request is amber and quotes the first line", report.attention.first { $0.key == "bug:B91" }?.severity == .amber
          && report.attention.first { $0.key == "bug:B91" }?.reasons.first?.hasSuffix("Delivery evidence is missing.") == true)
    check("facts: rework counts", report.rework.itemsReopened == 1 && report.rework.reopens == 2 && report.rework.inScope == 2)
    check("report: the flow with an acceptance step has the row", report.row(.acceptance) != nil)
}

// MARK: - Acceptance that waits

do {
    var items: [(CycleItemInfo, [TransitionRecord])] = []
    for n in 1...10 {
        let id = "F\(n)"
        items.append((info(.feature, id, status: "verified"), [
            baseline(.feature, id, "ready", at(0)),
            rec(.applied, .feature, id, to: "implementing", at: at(1), kindOfStep: .start),
            rec(.applied, .feature, id, to: "implemented", at: at(2), kindOfStep: .completion),
            rec(.applied, .feature, id, to: "verified", at: at(2 + Double(n)), kindOfStep: .acceptance),
        ]))
    }
    items.append((info(.feature, "F20", status: "implemented"), [
        baseline(.feature, "F20", "ready", at(0)),
        rec(.applied, .feature, "F20", to: "implementing", at: at(1), kindOfStep: .start),
        rec(.applied, .feature, "F20", to: "implemented", at: at(2), kindOfStep: .completion),
    ]))
    let waiting = CycleInput(items: items.map(\.0), records: items.flatMap(\.1), roles: standardRoles,
                             statusOrder: { ProjectWorkflow.standard.lifecycle($0).statusIDs }, acceptanceStep: { _ in true },
                             acceptsFrom: { _, status in status == "implemented" }, settings: .empty, now: at(2 + 30))
    let report = CycleReport.make(waiting).features
    check("acceptance: the lag is measured over the accepted ones", report.row(.acceptance)?.used == 10 && report.row(.acceptance)?.distribution?.p50 == 5.5 * hour)
    check("acceptance: one waiting far longer than usual is red", report.attention.first?.key == "feature:F20" && report.attention.first?.severity == .red
          && report.attention.first?.reasons.first?.contains("not accepted") == true)
}

// MARK: - Bulk creation, models

do {
    var five: [(CycleItemInfo, [TransitionRecord])] = (1...5).map { finishedBug("M\($0)", wait: 1, work: 1) }
    five += (1...4).map { finishedBug("N\($0)", wait: 1, work: 1, begin: 3) }
    let report = CycleReport.make(input(five)).bugs
    check("bulk: five items created in one minute are marked, four are not",
          (1...5).allSatisfy { report.items["bug:M\($0)"]?.marks.contains(.bulkCreated) == true } && (1...4).allSatisfy { report.items["bug:N\($0)"]?.marks.contains(.bulkCreated) == false })

    var items = (1...10).map { finishedBug("B\($0)", wait: 1, work: Double($0)) }
    items.append(finishedBug("B11", wait: 1, work: 20))
    var models: [String: String] = [:]
    for n in 1...5 { models["bug:B\(n)"] = "Claude Opus 5.5" }
    for n in 6...11 { models["bug:B\(n)"] = "Claude Sonnet 5.5" }
    let byModel = CycleReport.make(input(items, models: models)).bugs.models
    check("models: the cycle time per model, most items first", byModel.map(\.model) == ["Claude Sonnet 5.5", "Claude Opus 5.5"] && byModel[0].distribution.count == 6 && byModel[1].distribution.count == 5)
    check("models: five items are enough to compare, four are not", byModel[0].tooFew == false && CycleModelRow(model: "x", distribution: CycleDistribution.make([1, 2, 3, 4])!).tooFew)
}

// MARK: - Model names

do {
    let names = ["a": "opus", "b": "claude-opus-5-5", "c": "Claude Opus 5.5", "d": "anthropic/claude-opus-5.5", "e": "claude-opus-5-5-20251101", "f": "claude-sonnet-5-5[1m]"]
    let resolved = CycleModelNames.resolve(names)
    check("model names: the spellings of one model are one row", Set(["a", "b", "c", "d", "e"].compactMap { resolved[$0] }) == ["Claude Opus 5.5"])
    check("model names: another family stays another row", resolved["f"] == "Claude Sonnet 5.5")
    check("model names: a bare family is not guessed when the project has two versions",
          CycleModelNames.resolve(["a": "opus", "b": "claude-opus-5-5", "c": "claude-opus-4-1"])["a"] == "Claude Opus")
    check("model names: an unknown name is kept as written", CycleModelNames.resolve(["a": " gpt-5.1-codex "])["a"] == "gpt-5.1-codex")
    check("model names: an empty name is no model", CycleModelNames.resolve(["a": "  "])["a"] == nil)
    check("model names: the older spelling with the version first", CycleModelNames.parse("claude-3-5-sonnet-latest")?.display == "Claude Sonnet 3.5")
}

// MARK: - Delivery evidence

func event(_ stage: EvidenceStage, _ note: String?, at time: Date, model: String? = nil, source: LifecycleSource = .automatic) -> LifecycleEvent {
    LifecycleEvent(id: UUID(), project: "/p", feature: "f", stage: stage, timestamp: time, actor: "boris", source: source, model: model, note: note)
}

do {
    let events = [
        event(.workStarted, "Implement with AI · Claude", at: at(0), model: "Claude Opus 5.5"),
        event(.pullRequestOpened, "PR #7", at: at(2)),
        event(.ciRequested, "PR #7", at: at(2.1)),
        event(.ciStarted, "PR #7", at: at(2.2)),
        event(.ciRequested, "PR #7 · re-run 2 of run 9", at: at(3)),
        event(.ciPassed, "PR #7", at: at(4)),
        event(.approved, "PR #7", at: at(5)),
        event(.mergedToMain, "PR #7", at: at(6)),
        event(.pullRequestOpened, "Status implemented", at: at(7)),
        event(.approved, "PR #8", at: at(8), source: .manual),
    ]
    let pr = EvidenceTimings.timeline(events, directToMain: false)
    check("evidence: the model is the one on the start event", pr.model == "Claude Opus 5.5" && pr.started == at(0))
    check("evidence: lines of the retired observer and of manual marks are not read", pr.units.map(\.name) == ["PR #7"] && events.filter(\.isEvidence).count == 8)
    let unit = pr.units[0]
    check("evidence: a pull request process shows the opening, the approval and the merge, in time order",
          unit.rows.map(\.stage) == [.pullRequestOpened, .ciRequested, .ciStarted, .ciPassed, .approved, .mergedToMain])
    check("evidence: each row is timed from the one before, the first from the start", unit.rows.first?.since == 2 * hour && unit.rows.last?.since == hour)
    check("evidence: CI queue, CI time and re-runs", abs((unit.queue ?? 0) - 0.1 * hour) < 1 && abs((unit.ciTime ?? 0) - 1.8 * hour) < 1 && unit.reruns == 1)
    let direct = EvidenceTimings.timeline([
        event(.workStarted, "Implement with AI", at: at(0)),
        event(.mergedToMain, "commit abc1234", at: at(1)),
        event(.pullRequestOpened, "commit abc1234", at: at(1.5)),
        event(.ciRequested, "commit abc1234", at: at(1.1)),
        event(.ciPassed, "commit abc1234", at: at(1.6)),
    ], directToMain: true)
    check("evidence: a direct process has no pull request or review row and CI may follow the merge",
          direct.units.first?.rows.map(\.stage) == [.mergedToMain, .ciRequested, .ciPassed])
    let reused = EvidenceTimings.timeline(events, directToMain: false, since: at(5.5))
    check("evidence: lines recorded before the item existed are left out", reused.started == nil && reused.units.map(\.name) == ["PR #7"] && reused.units[0].rows.map(\.stage) == [.mergedToMain])
    check("evidence: none gives an empty timeline", EvidenceTimings.timeline([], directToMain: false) == EvidenceTimeline(started: nil, model: nil, units: []))
}

// MARK: - Settings file

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-time-checks-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = CycleSettingsFile.url(projectRoot: folder)
    check("settings file: where it lives", url.path.hasSuffix("/.dde/lifecycle/cycle-time.json"))
    check("settings file: none is the empty settings", CycleSettingsFile.load(url) == .settings(.empty))
    let settings = CycleSettings(since: Date(timeIntervalSince1970: 1_790_000_000), excluded: []).excluding(.bug, "BUG-1", reason: "import", at: Date(timeIntervalSince1970: 1_790_000_100))
    do {
        try CycleSettingsFile.save(settings, to: url)
        check("settings file: a round trip keeps the date and the exclusions", CycleSettingsFile.load(url) == .settings(settings))
    } catch { check("settings file: saved (\(error))", false) }
    try? "not json".write(to: url, atomically: true, encoding: .utf8)
    if case .unreadable(let message) = CycleSettingsFile.load(url) { check("settings file: a damaged file is reported", message.contains("cycle-time.json")) } else { check("settings file: a damaged file is reported", false) }
    check("settings file: and left as it was", (try? String(contentsOf: url, encoding: .utf8)) == "not json")
}

finish("cycle time")
