import Foundation

// End-to-End QA (feature end-to-end-qa, Q-010 option A): puts the retention rule (QARunRetention) to work on the runs in `.dde/qa/runs/`.
// A run that starts prunes the older runs of its scenario; the Run panel asks the person before it deletes runs by hand. The bug reports
// that name runs are read through the bug filer. Every file read or removed here happens off the main thread. Foundation only; checked on
// its own by tools/tests/qa-retention-tests.sh.

/// The runs that results kept outside QA link to (the Cockpit's), and the lock those results are saved under. A run a result links is never
/// deleted, so cleanup reads both through this; the window that owns the results supplies it (`ToolTabsRouter`).
protocol QARunLinks: Sendable {
    /// Runs `body` while holding the lock the results are saved under, shared across windows and app instances.
    func withLock<T>(_ root: URL, _ body: () throws -> T) throws -> T
    /// The ids of the runs the results link. Call only while holding `withLock`; throws when a result cannot be read, so cleanup never
    /// discards evidence a result links.
    func linkedRunIDsLocked(_ root: URL) throws -> Set<String>
}

enum QARunCleanup {
    /// What deleting some runs would remove, worked out for the question put to the person.
    struct Plan: Equatable {
        var runIDs: [String]
        /// The bytes in their files.
        var bytes: Int64
        /// The runs among them that a filed bug report names.
        var namedByBugs: [String]
        /// False when the bug reports could not be read, so it is not known whether any of the runs is named.
        var bugsChecked: Bool
        /// Runs linked from cockpit results, and whether those references could be read.
        var namedByCockpit: [String] = []
        var cockpitChecked: Bool = true
    }

    /// Without `links` it is not known which runs results link, so `cockpitChecked` is false.
    static func plan(deleting runIDs: [String], root: URL, filer: QABugFiler?, links: (any QARunLinks)?) async -> Plan {
        let named = await runsNamedByBugs(filer)
        let details = await Task.detached(priority: .userInitiated) {
            let bytes = QAStore.sizeOfRuns(root, runIDs: runIDs)
            let linked = links.flatMap { links in try? links.withLock(root) { try links.linkedRunIDsLocked(root) } }
            return (bytes, linked)
        }.value
        return Plan(runIDs: runIDs, bytes: details.0, namedByBugs: runIDs.filter { named?.contains($0) == true }, bugsChecked: named != nil,
                    namedByCockpit: runIDs.filter { details.1?.contains($0) == true }, cockpitChecked: details.1 != nil)
    }

    static func delete(_ plan: Plan, root: URL, links: (any QARunLinks)?) async -> QARunDeletion {
        await Task.detached(priority: .userInitiated) {
            do {
                guard let links else { throw QARunLinksUnavailable() }
                return try links.withLock(root) {
                    let linked = try links.linkedRunIDsLocked(root)
                    guard plan.cockpitChecked, Set(plan.runIDs).intersection(linked).isSubset(of: Set(plan.namedByCockpit)) else {
                        return QARunDeletion(deleted: 0, failed: plan.runIDs.count, firstFailure: "Cockpit links changed or could not be checked; review the deletion again.")
                    }
                    return QAStore.deleteRuns(root, runIDs: plan.runIDs)
                }
            } catch {
                return QARunDeletion(deleted: 0, failed: plan.runIDs.count, firstFailure: "Cockpit links could not be checked; nothing was deleted.")
            }
        }.value
    }

    /// Deletes the runs of `scenarioID` that the rule gives up, for a run that is starting (`runInProgress`, which holds one of the kept
    /// places and is never deleted). Without a way to read the bug reports nothing is deleted, as a run a bug names could go. A run that
    /// cannot be deleted is left for the next time: pruning never fails the run that asked for it. Without `links` nothing is deleted either.
    static func prune(root: URL, scenarioID: String, runInProgress: String, filer: QABugFiler?, links: (any QARunLinks)?) async {
        guard let named = await runsNamedByBugs(filer), let links else { return }
        await Task.detached(priority: .utility) {
            try? links.withLock(root) {
                let linked = try links.linkedRunIDsLocked(root)
                let runs = QAStore.loadRuns(root).filter { $0.scenarioID == scenarioID }
                    .map { QARunRetention.Entry(id: $0.id, startedAt: $0.startedAt, isFinished: $0.finishedAt != nil) }
                _ = QAStore.deleteRuns(root, runIDs: QARunRetention.runsToDelete(runs, referencedByBugs: named.union(linked), inProgress: runInProgress))
            }
        }.value
    }

    private struct QARunLinksUnavailable: Error {}

    /// The runs the filed bug reports name; nil when they cannot be read.
    private static func runsNamedByBugs(_ filer: QABugFiler?) async -> Set<String>? {
        guard let filer, let keys = try? await filer.allFiledKeys() else { return nil }
        return QARunRetention.runIDs(inBugKeys: keys)
    }
}
