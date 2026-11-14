import Foundation

// Checks for MarkView/Models/QARunRetention.swift, QARunCleanup.swift and the run deletion of QAStore.swift (feature end-to-end-qa, Q-010),
// run by tools/tests/qa-retention-tests.sh. The rule is checked on plain values, with deliberately wrong rules that the same checks must
// reject; the deletion on real folders in a temp directory (including links that lead out of the runs folder); the whole path on a fake
// bug sink and on bug files that are really on disk. Temp folders only.

setvbuf(stdout, nil, _IOLBF, 0)

let base = Date(timeIntervalSince1970: 1_790_000_000)

/// A run id as the app makes them: `yyyyMMdd-HHmmss-xxxx`; `n` minutes after the first one.
func runName(_ n: Int, suffix: String = "aa11") -> String { String(format: "20261110-10%02d00-", n % 60) + suffix }

func entry(_ n: Int, finished: Bool = true, at: Date? = nil, suffix: String = "aa11") -> QARunRetention.Entry {
    QARunRetention.Entry(id: runName(n, suffix: suffix), startedAt: at ?? base.addingTimeInterval(Double(n) * 60), isFinished: finished)
}

func names(_ numbers: [Int]) -> [String] { numbers.map { runName($0) } }

// MARK: - The rule

typealias Rule = (_ runs: [QARunRetention.Entry], _ named: Set<String>, _ running: String?, _ keep: Int) -> [String]

let realRule: Rule = { runs, named, running, keep in QARunRetention.runsToDelete(runs, referencedByBugs: named, inProgress: running, keepNewest: keep) }

/// Every requirement of the rule as one question per line. Returns the names of the lines that failed, so that the real rule must answer
/// all of them and each wrong rule below must fail at least one.
func ruleFailures(_ rule: Rule) -> [String] {
    var failed: [String] = []
    func expect(_ name: String, _ condition: Bool) { if !condition { failed.append(name) } }

    let eight = (1...8).map { entry($0) }
    expect("keeps the newest 5 and deletes the rest, oldest first", rule(eight, [], nil, 5) == names([1, 2, 3]))
    expect("the order of the input does not matter", rule(eight.reversed(), [], nil, 5) == names([1, 2, 3]))
    expect("fewer runs than the limit: nothing goes", rule(Array(eight.prefix(3)), [], nil, 5).isEmpty)
    expect("exactly the limit: nothing goes", rule(Array(eight.prefix(5)), [], nil, 5).isEmpty)
    expect("no runs: nothing goes", rule([], [], nil, 5).isEmpty)
    expect("one more than the limit: only the oldest goes", rule(Array(eight.prefix(6)), [], nil, 5) == names([1]))

    expect("a run a bug names stays, however old", rule(eight, [runName(1)], nil, 5) == names([2, 3]))
    expect("two named runs stay", rule(eight, [runName(1), runName(3)], nil, 5) == names([2]))
    expect("a named run among the newest takes no extra place", rule(eight, [runName(7)], nil, 5) == names([1, 2, 3]))
    expect("every run named: nothing goes", rule(eight, Set(eight.map(\.id)), nil, 5).isEmpty)
    expect("a name that is no run changes nothing", rule(eight, ["20250101-000000-zzzz"], nil, 5) == names([1, 2, 3]))

    expect("the run in progress on the list is never deleted", rule(eight, [], runName(1), 5) == names([2, 3]))
    expect("a run in progress with no record yet holds one of the places", rule(Array(eight.prefix(5)), [], "20261110-109900-new1", 5) == names([1]))
    expect("a run in progress with no record yet, among many older ones", rule(eight, [], "20261110-109900-new1", 5) == names([1, 2, 3, 4]))
    expect("a run in progress that is on the list holds no further place", rule(eight, [], runName(8), 5) == names([1, 2, 3]))
    expect("a run in progress is never deleted even at no places", rule(eight, [], runName(1), 0).contains(runName(1)) == false)

    expect("a run that has not ended is never deleted", rule([entry(1, finished: false)] + (2...8).map { entry($0) }, [], nil, 5) == names([2, 3]))
    expect("a run that has not ended is counted by its time", rule((1...7).map { entry($0, finished: $0 != 7) }, [], nil, 5) == names([1, 2]))

    let tied = "bcdefgh".map { QARunRetention.Entry(id: "20261110-100000-a\($0)1", startedAt: base, isFinished: true) }
    expect("equal start times: the higher ids are the newer", rule(tied, [], nil, 5) == ["20261110-100000-ab1", "20261110-100000-ac1"])
    expect("equal start times: the answer does not depend on the order",
           (0..<12).allSatisfy { seed in
               var generator = SeededGenerator(seed: UInt64(seed + 1))
               return rule(tied.shuffled(using: &generator), [], nil, 5) == ["20261110-100000-ab1", "20261110-100000-ac1"]
           })
    expect("a run listed twice is answered once", rule(eight + [eight[0]], [], nil, 5) == names([1, 2, 3]))

    expect("no places: everything that is not protected goes", rule(eight, [runName(2)], nil, 0) == names([1, 3, 4, 5, 6, 7, 8]))
    expect("negative places count as none", rule(eight, [], nil, -3) == eight.map(\.id))
    expect("more places than runs: nothing goes", rule(eight, [], nil, 100).isEmpty)
    expect("the limit is the count given", rule(eight, [], nil, 2) == names([1, 2, 3, 4, 5, 6]))
    return failed
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

func ruleChecks() {
    check("the default is the newest 5 (Q-010)", QARunRetention.defaultKeepNewest == 5)
    let failed = ruleFailures(realRule)
    check("rule: every requirement holds" + (failed.isEmpty ? "" : " (failed: \(failed.joined(separator: "; ")))"), failed.isEmpty)

    let defaulted = QARunRetention.runsToDelete((1...8).map { entry($0) }, referencedByBugs: [])
    check("rule: the limit and the run in progress have defaults (5 kept, none running)", defaulted == names([1, 2, 3]))

    // Wrong rules: the requirements above must tell each of them from the real one.
    let mutants: [(name: String, rule: Rule)] = [
        ("ignores the bug reports", { runs, _, running, keep in realRule(runs, [], running, keep) }),
        ("keeps one run too few", { runs, named, running, keep in realRule(runs, named, running, keep - 1) }),
        ("keeps one run too many", { runs, named, running, keep in realRule(runs, named, running, keep + 1) }),
        ("deletes the run in progress", { runs, named, _, keep in realRule(runs, named, nil, keep) }),
        ("keeps the oldest runs instead of the newest", { runs, named, running, keep in
            realRule(runs.map { QARunRetention.Entry(id: $0.id, startedAt: Date(timeIntervalSince1970: -$0.startedAt.timeIntervalSince1970), isFinished: $0.isFinished) }, named, running, keep)
        }),
        ("deletes a run that has not ended", { runs, named, running, keep in realRule(runs.map { QARunRetention.Entry(id: $0.id, startedAt: $0.startedAt, isFinished: true) }, named, running, keep) }),
        ("deletes the newest first", { runs, named, running, keep in realRule(runs, named, running, keep).reversed() }),
        ("orders by time only, so equal times fall to the input order", { runs, named, running, keep in
            let newestFirst = runs.sorted { $0.startedAt > $1.startedAt }
            var doomed: [String] = []
            for (position, run) in newestFirst.enumerated() where position >= max(keep, 0) {
                if run.id == running || !run.isFinished || named.contains(run.id) { continue }
                doomed.append(run.id)
            }
            return doomed.reversed()
        }),
    ]
    for mutant in mutants {
        check("rule: a wrong rule is told apart (\(mutant.name))", !ruleFailures(mutant.rule).isEmpty)
    }
}

// MARK: - The runs a bug names

func keyChecks() {
    let run = "20261110-101500-ab12"
    let branch = "n1>n2>n3>n4>n5"
    check("key: a check's key (as QABugDrafts makes it) names its run", QARunRetention.runID(inBugKey: QABugDrafts.key(run: run, branch: branch)) == run)
    check("key: a finding's key (as QABugDrafts makes it) names its run", QARunRetention.runID(inBugKey: QABugDrafts.key(run: run, finding: "f3")) == run)
    check("key: a branch id with spaces and underscores still names its run", QARunRetention.runID(inBugKey: QABugDrafts.key(run: run, branch: "n1 > n_2")) == run)
    check("key: white space around the key is ignored", QARunRetention.runID(inBugKey: "  \(run):finding:f1\n") == run)
    check("key: a run id is kept as it is, dashes included", QARunRetention.runID(inBugKey: "a-b-9:x") == "a-b-9")

    let malformed = ["", "   ", "garbage", ":x", "\(run):", "\(run): ", "Run-1:x", "a b:c", "../x:y", "a/b:c", "a\\b:c", "ünï:x", "a\u{0}b:c", "a.b:c", "a_b:c"]
    for key in malformed {
        check("key: \"\(key.replacingOccurrences(of: "\u{0}", with: "\\0"))\" names no run", QARunRetention.runID(inBugKey: key) == nil)
    }
    let all = QARunRetention.runIDs(inBugKeys: ["\(run):n1", "\(run):finding:f1", "other-run:n1", "garbage", "", "\(run):n2"])
    check("key: the runs of a list of keys, once each, malformed keys left out", all == [run, "other-run"])
    check("key: no keys name no runs", QARunRetention.runIDs(inBugKeys: []).isEmpty)
}

// MARK: - Real folders

func tempProject() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-retention-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

func record(_ n: Int, scenario: String = "checkout", finished: Bool = true) -> QARunRecord {
    QARunRecord(id: runName(n), scenarioID: scenario, targetID: "local", targetKind: .local, selected: ["n1"],
                startedAt: base.addingTimeInterval(Double(n) * 60), finishedAt: finished ? base.addingTimeInterval(Double(n) * 60 + 30) : nil)
}

/// Saves a run the way a finished run is saved and puts a recording and a frame in its folder; returns the bytes it holds.
@discardableResult
func makeRun(_ root: URL, _ n: Int, scenario: String = "checkout", finished: Bool = true, video: Int = 4000, frame: Int = 700) throws -> Int64 {
    let saved = record(n, scenario: scenario, finished: finished)
    try QAStore.saveRun(saved, root: root)
    let folder = QAStore.runFolder(root, runID: saved.id)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
    try Data(repeating: 7, count: video).write(to: folder.appendingPathComponent("branch-1.mp4"))
    try Data(repeating: 9, count: frame).write(to: folder.appendingPathComponent("frames/1.png"))
    let json = (try FileManager.default.attributesOfItem(atPath: QAStore.runURL(root, runID: saved.id).path)[.size] as? NSNumber)?.int64Value ?? 0
    return json + Int64(video + frame)
}

func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

func runFolders(_ root: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: QAStore.runsFolder(root).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

func storeChecks() throws {
    let root = tempProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let sizes = try (1...4).map { try makeRun(root, $0, video: 1000 * $0) }
    let sentinel = root.appendingPathComponent("docs/keep.txt")
    try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
    let ignore = QAStore.localFolder(root).appendingPathComponent(".gitignore")

    check("size: a run's size is the bytes in its files", QAStore.sizeOfRuns(root, runIDs: [runName(1)]) == sizes[0])
    check("size: the size of several runs is the sum", QAStore.sizeOfRuns(root, runIDs: names([1, 2, 3])) == sizes[0] + sizes[1] + sizes[2])
    check("size: a run that is not there counts for nothing", QAStore.sizeOfRuns(root, runIDs: [runName(30)]) == 0)
    check("size: an id that is not a run id counts for nothing", QAStore.sizeOfRuns(root, runIDs: ["..", "", "../docs", "a/b"]) == 0)

    var removed = false
    do { removed = try QAStore.deleteRun(root, runID: runName(2)) } catch { removed = false }
    check("delete: a run's folder is removed from the disk", removed && !exists(QAStore.runFolder(root, runID: runName(2))))
    check("delete: the other runs are left as they were",
          runFolders(root) == names([1, 3, 4]).sorted() && QAStore.loadRuns(root).map(\.id).sorted() == names([1, 3, 4]).sorted()
              && QAStore.sizeOfRuns(root, runIDs: [runName(3)]) == sizes[2])
    check("delete: the files around the runs are left alone", exists(sentinel) && exists(ignore) && exists(QAStore.runsFolder(root)))

    var again = true
    var againFailed = false
    do { again = try QAStore.deleteRun(root, runID: runName(2)) } catch { againFailed = true }
    check("delete: a run that is gone is not an error", again == false && !againFailed)
    let many = QAStore.deleteRuns(root, runIDs: [runName(2), runName(77), runName(1)])
    check("delete: missing runs are not counted, the others go", many == QARunDeletion(deleted: 1, failed: 0, firstFailure: nil) && runFolders(root) == names([3, 4]).sorted())
    check("delete: nothing to delete is nothing done", QAStore.deleteRuns(root, runIDs: []) == QARunDeletion())

    // Ids that are not run ids are refused before any path is made from them.
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "precious".write(to: outside.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let hostile = ["", "..", ".", "../outside", "../../docs", "a/b", "/etc", "/tmp", "x/../y", "..\\outside", "~", "Run-A", "a b", "a\u{0}b", "a/", "outside/.."]
    for id in hostile {
        var error: Error?
        do { try QAStore.deleteRun(root, runID: id) } catch let caught { error = caught }
        check("delete: \"\(id.replacingOccurrences(of: "\u{0}", with: "\\0"))\" is refused", (error as? QAStoreError) == .badID(id))
    }
    let refused = QAStore.deleteRuns(root, runIDs: hostile)
    check("delete: refused ids are counted as failures and nothing else goes", refused.deleted == 0 && refused.failed == hostile.count && refused.firstFailure != nil
              && runFolders(root) == names([3, 4]).sorted() && exists(outside.appendingPathComponent("file.txt")) && exists(sentinel))

    // A folder in the runs folder that is a link to somewhere else is not followed out.
    let escape = QAStore.runsFolder(root).appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
    var leaving: Error?
    do { try QAStore.deleteRun(root, runID: "escape") } catch let caught { leaving = caught }
    check("delete: a run folder that leads out of the runs folder is refused", (leaving as? QAStoreError) == .outsideRuns("escape"))
    check("delete: ... and neither the link nor what it leads to is touched", exists(escape) && exists(outside.appendingPathComponent("file.txt")))
    check("size: ... and what it leads to is not counted", QAStore.sizeOfRuns(root, runIDs: ["escape"]) == 0)
    try FileManager.default.removeItem(at: escape)

    // A link to nothing cannot be followed anywhere: it is removed as the link it is.
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: root.appendingPathComponent("nowhere"))
    let danglingRemoved = (try? QAStore.deleteRun(root, runID: "escape")) ?? false
    check("delete: a link to nothing is removed as a link", danglingRemoved && !exists(escape) && exists(outside.appendingPathComponent("file.txt")) && exists(sentinel))

    // A link inside the runs folder is removed as a link: the run it points to stays.
    let alias = QAStore.runsFolder(root).appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: QAStore.runFolder(root, runID: runName(3)))
    let aliasRemoved = (try? QAStore.deleteRun(root, runID: "alias")) ?? false
    check("delete: a link to another run is removed and the run it points to stays", aliasRemoved && !exists(alias) && exists(QAStore.runURL(root, runID: runName(3))))

    // A link inside a run's folder is removed as a link: what it points to stays.
    let inner = QAStore.runFolder(root, runID: runName(4)).appendingPathComponent("link-out")
    try FileManager.default.createSymbolicLink(at: inner, withDestinationURL: outside)
    try QAStore.deleteRun(root, runID: runName(4))
    check("delete: a link inside a run is not followed", !exists(QAStore.runFolder(root, runID: runName(4))) && exists(outside.appendingPathComponent("file.txt")))

    // The runs folder itself may be a link (the runs on another disk): runs in it are deleted like any other.
    let moved = tempProject()
    defer { try? FileManager.default.removeItem(at: moved) }
    let elsewhere = tempProject()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try FileManager.default.createDirectory(at: QAStore.localFolder(moved), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: QAStore.runsFolder(moved), withDestinationURL: elsewhere)
    try makeRun(moved, 5)
    let viaLink = QAStore.deleteRuns(moved, runIDs: [runName(5)])
    check("delete: a runs folder that is a link to another place still works", viaLink.deleted == 1 && runFolders(moved).isEmpty)
}

// MARK: - The rule on the disk

actor KeysSink: QABugSink {
    var keys: [String]
    var failing = false
    init(_ keys: [String]) { self.keys = keys }
    func setFailing(_ value: Bool) { failing = value }
    func bugFolder() async -> URL? { nil }
    func filedBugs(forKeys wanted: [String]) async throws -> [String: String] { [:] }
    func allFiledKeys() async throws -> [String] {
        if failing { throw SinkFailure(message: "the folder is locked") }
        return keys
    }
    func createBug(_ report: QABugReport) async throws -> String { throw SinkFailure(message: "not used") }
    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome { .noReport }
}

struct SinkFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

func ids(_ root: URL) -> [String] { QAStore.loadRuns(root).map(\.id).sorted() }

func cleanupChecks() async throws {
    let current = runName(40, suffix: "new1")

    // Pruning keeps the newest places, the runs bugs name and the run that is starting; other scenarios are not touched.
    do {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 1...8 { try makeRun(root, n) }
        for n in 11...18 { try makeRun(root, n, scenario: "signup") }
        let starting = QAStore.runFolder(root, runID: current)
        try FileManager.default.createDirectory(at: starting.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: starting.appendingPathComponent("frames/1.png"))

        let filer = QABugFiler(sink: KeysSink([QABugDrafts.key(run: runName(1), branch: "n1>n2"), QABugDrafts.key(run: runName(2), finding: "f1"), "garbage", ""]))
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: filer)
        check("prune: keeps the runs bugs name, and the newest 4 beside the run that is starting",
              ids(root).filter { names(Array(1...8)).contains($0) } == names([1, 2, 5, 6, 7, 8]).sorted())
        check("prune: another scenario's runs are not touched", names(Array(11...18)).allSatisfy { ids(root).contains($0) })
        check("prune: the run that is starting keeps its folder and files",
              exists(starting.appendingPathComponent("frames/1.png")))
        check("prune: what it deleted is gone from the disk, files and all",
              [3, 4].allSatisfy { !exists(QAStore.runFolder(root, runID: runName($0))) })

        // The same again deletes nothing more, and a second pass in a crowd of runs is quiet.
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: filer)
        check("prune: pruning again changes nothing", ids(root).count == 6 + 8)
    }

    // Without a way to tell which runs bugs name, nothing is deleted.
    do {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 1...8 { try makeRun(root, n) }
        let blind = KeysSink([])
        await blind.setFailing(true)
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: QABugFiler(sink: blind))
        check("prune: bug reports that cannot be read: nothing is deleted", ids(root).count == 8)
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: nil)
        check("prune: no way to read the bug reports at all: nothing is deleted", ids(root).count == 8)
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: QABugFiler(sink: KeysSink([])))
        check("prune: bug reports read and none name a run: the older runs go", ids(root) == names([5, 6, 7, 8]).sorted())
    }

    // A run that has not ended is left alone, however old.
    do {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeRun(root, 1, finished: false)
        for n in 2...9 { try makeRun(root, n) }
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: QABugFiler(sink: KeysSink([])))
        check("prune: a run that has not ended stays", ids(root).contains(runName(1)) && ids(root) == names([1, 6, 7, 8, 9]).sorted())
    }

    // Runs that cannot be read are not runs: they are not touched. A first run in a project has nothing to prune.
    do {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: QABugFiler(sink: KeysSink([])))
        check("prune: a project with no runs is fine", !exists(QAStore.runsFolder(root)))
        for n in 1...7 { try makeRun(root, n) }
        let broken = QAStore.runFolder(root, runID: runName(50))
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{ not json".write(to: broken.appendingPathComponent("run.json"), atomically: true, encoding: .utf8)
        await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: current, filer: QABugFiler(sink: KeysSink([])))
        check("prune: a run file that cannot be read is left alone", exists(broken) && ids(root) == names([4, 5, 6, 7]).sorted())
    }

    // The question put to the person.
    do {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let sizes = try (1...3).map { try makeRun(root, $0, video: 1000 * $0) }
        let filer = QABugFiler(sink: KeysSink([QABugDrafts.key(run: runName(2), branch: "n1"), QABugDrafts.key(run: runName(2), finding: "f1")]))
        let plan = await QARunCleanup.plan(deleting: names([1, 2, 3]), root: root, filer: filer)
        check("plan: how many runs, how many bytes, which runs a bug names", plan.runIDs == names([1, 2, 3]) && plan.bytes == sizes.reduce(0, +)
                  && plan.namedByBugs == [runName(2)] && plan.bugsChecked)
        let blind = KeysSink([])
        await blind.setFailing(true)
        let unknown = await QARunCleanup.plan(deleting: names([1]), root: root, filer: QABugFiler(sink: blind))
        check("plan: when the bug reports cannot be read, the plan says it is not known", unknown.namedByBugs.isEmpty && !unknown.bugsChecked && unknown.bytes == sizes[0])
        let noFiler = await QARunCleanup.plan(deleting: names([1]), root: root, filer: nil)
        check("plan: with no bug filer it is not known either", !noFiler.bugsChecked)

        let result = await QARunCleanup.delete(plan, root: root)
        check("plan: deleting a plan deletes the runs of the plan, named ones too", result.deleted == 3 && result.failed == 0 && ids(root).isEmpty)
        let afterwards = await QARunCleanup.delete(plan, root: root)
        check("plan: deleting it again is not an error", afterwards == QARunDeletion())
    }
}

// MARK: - Bug reports on disk

func indexChecks() async throws {
    let bugs = FileManager.default.temporaryDirectory.appendingPathComponent("qa-retention-bugs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bugs) }
    check("index: a bug folder that does not exist has no keys", (try? QABugIndex.allKeys(in: bugs)) == [])
    try FileManager.default.createDirectory(at: bugs, withIntermediateDirectories: true)

    /// A report as the app files it (BugReportWriter, with the fields QABugFiler.fields gives it) ...
    func filed(_ id: String, key: String, run: String) throws {
        var draft = BugReportDraft(title: "QA failed: \(id)", body: "# QA failed\n\nText", status: "open", severity: "high", reporter: "Tester", provenance: "Created by End-to-End QA")
        draft.fields = [(key: QABugIndex.keyField, value: key), (key: QABugIndex.runField, value: run), (key: QABugIndex.outcomeField, value: "failed")]
        try BugReportWriter.write(draft, id: id, slug: "qa-failed", created: "2026-11-10", in: bugs)
    }
    /// ... and a report written by hand.
    func report(_ file: String, _ front: [String]) throws {
        try (["---"] + front + ["---", "", "# A bug"]).joined(separator: "\n").write(to: bugs.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    let old = runName(1), middle = runName(2), recent = runName(8)
    try filed("BUG-002", key: QABugDrafts.key(run: middle, finding: "f1"), run: middle)
    try filed("BUG-001", key: QABugDrafts.key(run: old, branch: "n1>n2"), run: old)
    try report("BUG-003-c.md", ["id: BUG-003", "title: Not from QA"])
    try report("BUG-004-d.md", ["id: BUG-004", "qa_key: garbage"])
    try report("BUG-005-e.md", ["id: BUG-005", "qa_key: "])
    try report("README.md", ["qa_key: \(QABugDrafts.key(run: recent, branch: "n1"))"])
    try "not a report".write(to: bugs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try Data([0xFF, 0xFE, 0x00]).write(to: bugs.appendingPathComponent("BUG-006-binary.md"))

    let keys = try QABugIndex.allKeys(in: bugs)
    check("index: the keys of the reports that have one, in file-name order, the README and other files left out",
          keys == [QABugDrafts.key(run: old, branch: "n1>n2"), QABugDrafts.key(run: middle, finding: "f1"), "garbage"])
    check("index: the runs those keys name (a malformed key names none)", QARunRetention.runIDs(inBugKeys: keys) == [old, middle])

    var notAFolder: Error?
    do { _ = try QABugIndex.allKeys(in: bugs.appendingPathComponent("BUG-001-qa-failed.md")) } catch let caught { notAFolder = caught }
    check("index: a file where the folder should be is an error, not an empty list", notAFolder != nil)

    // The whole path: bugs on disk, runs on disk, a run that starts.
    let root = tempProject()
    defer { try? FileManager.default.removeItem(at: root) }
    for n in 1...8 { try makeRun(root, n) }
    let filer = QABugFiler(sink: DiskBugs(folder: bugs))
    await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: runName(40, suffix: "new1"), filer: filer)
    check("whole path: the runs two bug files name stay, the newest 4 stay, the rest go", ids(root) == names([1, 2, 5, 6, 7, 8]).sorted())
    check("whole path: the runs the bug files do not name are gone from the disk", [3, 4].allSatisfy { !exists(QAStore.runFolder(root, runID: runName($0))) })

    let before = ids(root)
    await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: runName(40, suffix: "new1"), filer: QABugFiler(sink: DiskBugs(folder: bugs.appendingPathComponent("BUG-001-qa-failed.md"))))
    check("whole path: a bug folder that cannot be read: nothing is deleted", ids(root) == before)
}

/// The sink of the real bug folder, as far as the retention rule uses it.
actor DiskBugs: QABugSink {
    let folder: URL
    init(folder: URL) { self.folder = folder }
    func bugFolder() async -> URL? { folder }
    func filedBugs(forKeys keys: [String]) async throws -> [String: String] { try QABugIndex.filedBugs(in: folder, keys: Set(keys)) }
    func allFiledKeys() async throws -> [String] { try QABugIndex.allKeys(in: folder) }
    func createBug(_ report: QABugReport) async throws -> String { throw SinkFailure(message: "not used") }
    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome { .noReport }
}

func cockpitChecks() async throws {
    let root = tempProject()
    defer { try? FileManager.default.removeItem(at: root) }
    for n in 1...8 { try makeRun(root, n) }
    let step = CockpitStep(title: "Check", agent: "Codex", assignment: "Check", completionCondition: "Pass")
    let plan = CockpitPlan(goal: "Check", controls: CockpitControls(), scenarios: [], steps: [step], successCriteria: ["Pass"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
    let result = CockpitResult(plan: plan, build: "build-1", outcome: "passed", qaRunID: runName(1))
    try CockpitResults.save(result, root: root)
    let listedBefore = try CockpitResults.loadAll(root: root)
    check("cockpit: linked evidence is listed while details exist", listedBefore.first?.detailsDeleted == false)
    let filer = QABugFiler(sink: KeysSink([]))
    await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: runName(40, suffix: "new1"), filer: filer)
    check("cockpit: automatic cleanup retains a linked old run", exists(QAStore.runURL(root, runID: runName(1))))
    let deletion = await QARunCleanup.plan(deleting: [runName(1)], root: root, filer: filer)
    check("cockpit: manual deletion identifies the link for the warning", deletion.cockpitChecked && deletion.namedByCockpit == [runName(1)])
    let deleted = await QARunCleanup.delete(deletion, root: root)
    let savedURL = root.appendingPathComponent(".dde/cockpit/results/\(result.id.uuidString).json")
    let retained = try JSONDecoder().decode(CockpitResult.self, from: Data(contentsOf: savedURL))
    check("cockpit: manual deletion keeps the plan, build and outcome while details are gone", deleted.deleted == 1 && retained == result && !exists(QAStore.runURL(root, runID: runName(1))))
    let shown = try CockpitResults.loadAll(root: root).first
    check("cockpit: listed evidence indicates deletion and retains plan, build and outcome", shown?.detailsDeleted == true && shown?.result.plan == plan && shown?.result.build == "build-1" && shown?.result.outcome == "passed")

    let beforeLink = await QARunCleanup.plan(deleting: [runName(5)], root: root, filer: filer)
    try CockpitResults.save(CockpitResult(plan: plan, build: "build-2", outcome: "passed", qaRunID: runName(5)), root: root)
    let refused = await QARunCleanup.delete(beforeLink, root: root)
    check("cockpit: a link added after the warning blocks deletion until reviewed", refused.failed == 1 && exists(QAStore.runURL(root, runID: runName(5))))
    try Data("bad json".utf8).write(to: savedURL)
    let before = ids(root)
    await QARunCleanup.prune(root: root, scenarioID: "checkout", runInProgress: runName(40, suffix: "new1"), filer: filer)
    check("cockpit: unreadable result references prevent automatic deletion", ids(root) == before)
}

ruleChecks()
keyChecks()
try storeChecks()
try await cleanupChecks()
try await cockpitChecks()
try await indexChecks()
finish("QA retention")
