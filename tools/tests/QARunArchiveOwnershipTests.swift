import Foundation

// The owner of the deletion of runs (AR-19): the shipping QARunArchive over real run folders in a temporary project. The Run panel asks the
// archive to work out what a deletion removes and to delete; the archive keeps that work, runs one at a time, and ends it with the
// folder or the window (`end`), writing nothing after.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

@MainActor func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return condition()
}

let base = Date(timeIntervalSince1970: 1_790_000_000)
func runName(_ n: Int) -> String { String(format: "20261110-10%02d00-", n % 60) + "aa11" }

func makeRun(_ root: URL, _ n: Int) throws {
    let record = QARunRecord(id: runName(n), scenarioID: "checkout", targetID: "local", targetKind: .local, selected: ["n1"],
                             startedAt: base.addingTimeInterval(Double(n) * 60), finishedAt: base.addingTimeInterval(Double(n) * 60 + 30))
    try QAStore.saveRun(record, root: root)
}

struct SinkFailure: LocalizedError { var errorDescription: String? { "no" } }

/// Bug reports that name no run, read at once, or never (until the read is cancelled).
actor Sink: QABugSink {
    let slow: Bool
    init(slow: Bool) { self.slow = slow }
    func bugFolder() async -> URL? { nil }
    func filedBugs(forKeys wanted: [String]) async throws -> [String: String] { [:] }
    func allFiledKeys() async throws -> [String] {
        if slow { try await Task.sleep(nanoseconds: 30_000_000_000) }
        return []
    }
    func createBug(_ report: QABugReport) async throws -> String { throw SinkFailure() }
    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome { .noReport }
}

@MainActor func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-archive-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for n in 1...3 { try makeRun(root, n) }

    let archive = QARunArchive()
    archive.root = root
    archive.bugFiler = QABugFiler(sink: Sink(slow: false))
    archive.reload(scenarioID: "checkout")
    check(await waitFor { archive.runs.count == 3 }, "the archive reads the runs of the scenario")

    // Start: the size is worked out and the person is asked; one at a time.
    archive.startDeletionPlan([runName(1), runName(2)], title: "Delete two runs?", action: "Delete runs")
    check(archive.cleaning, "working out a deletion shows that it works")
    archive.startDeletionPlan([runName(3)], title: "Delete one run?", action: "Delete run")
    check(await waitFor { archive.deleteQuestion != nil && !archive.cleaning }, "the question appears when the work is done")
    check(archive.deleteQuestion?.plan.runIDs == [runName(1), runName(2)] && archive.deleteQuestion?.title == "Delete two runs?",
          "a second start while one works was dropped")
    check(archive.runs.count == 3, "nothing is deleted until the person says yes")

    // No: the question goes and the runs stay.
    archive.dismissDeleteQuestion()
    check(archive.deleteQuestion == nil && archive.runs.count == 3, "a no leaves the runs")

    // Yes: the runs go, the list is read again, the work ends.
    archive.startDeletionPlan([runName(1), runName(2)], title: "Delete two runs?", action: "Delete runs")
    check(await waitFor { archive.deleteQuestion != nil }, "asked again")
    if let asked = archive.deleteQuestion {
        archive.startDeletion(asked)
        check(archive.cleaning && archive.deleteQuestion == nil, "a yes shows that the deletion works and the question is gone")
    }
    check(await waitFor { !archive.cleaning && archive.runs.map(\.id) == [runName(3)] }, "the deletion removes the runs and the list is read again")
    check(archive.cleanupProblem == nil && QAStore.loadRuns(root).map(\.id) == [runName(3)], "and nothing went wrong")

    // End: the work still under way stops and nothing it would have said comes after.
    let slow = QARunArchive()
    slow.root = root
    slow.bugFiler = QABugFiler(sink: Sink(slow: true))
    slow.reload(scenarioID: "checkout")
    check(await waitFor { slow.runs.count == 1 }, "a second archive reads the run")
    slow.startDeletionPlan([runName(3)], title: "Delete?", action: "Delete run")
    check(slow.cleaning, "the work under way shows that it works")
    slow.end()
    check(!slow.cleaning, "ending the archive ends what it showed as working")
    try? await Task.sleep(nanoseconds: 800_000_000)
    check(slow.deleteQuestion == nil && !slow.cleaning, "a cancelled work writes nothing after the end")
    check(QAStore.loadRuns(root).map(\.id) == [runName(3)], "and the run is still on disk")

    // End drops a question that is on screen, and the archive can work again afterwards.
    archive.startDeletionPlan([runName(3)], title: "Delete one run?", action: "Delete run")
    check(await waitFor { archive.deleteQuestion != nil }, "a question is on screen")
    archive.end()
    check(archive.deleteQuestion == nil, "ending the archive takes the question away")
    archive.startDeletionPlan([runName(3)], title: "Delete one run?", action: "Delete run")
    check(await waitFor { archive.deleteQuestion != nil }, "and the archive asks again afterwards")
    archive.end()

    print(failures == 0 ? "All QA archive ownership checks passed." : "\(failures) QA archive ownership check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

Task { do { try await run() } catch { print("FAIL \(error)"); exit(1) } }
RunLoop.main.run()
