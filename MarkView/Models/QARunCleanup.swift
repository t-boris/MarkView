import Foundation

// End-to-End QA (feature end-to-end-qa, Q-010 option A): puts the retention rule (QARunRetention) to work on the runs in `.dde/qa/runs/`.
// A run that starts prunes the older runs of its scenario; the Run panel asks the person before it deletes runs by hand. The bug reports
// that name runs are read through the bug filer. Every file read or removed here happens off the main thread. Foundation only; checked on
// its own by tools/tests/qa-retention-tests.sh.

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
    }

    static func plan(deleting runIDs: [String], root: URL, filer: QABugFiler?) async -> Plan {
        let named = await runsNamedByBugs(filer)
        let bytes = await Task.detached(priority: .userInitiated) { QAStore.sizeOfRuns(root, runIDs: runIDs) }.value
        return Plan(runIDs: runIDs, bytes: bytes, namedByBugs: runIDs.filter { named?.contains($0) == true }, bugsChecked: named != nil)
    }

    static func delete(_ plan: Plan, root: URL) async -> QARunDeletion {
        await Task.detached(priority: .userInitiated) { QAStore.deleteRuns(root, runIDs: plan.runIDs) }.value
    }

    /// Deletes the runs of `scenarioID` that the rule gives up, for a run that is starting (`runInProgress`, which holds one of the kept
    /// places and is never deleted). Without a way to read the bug reports nothing is deleted, as a run a bug names could go. A run that
    /// cannot be deleted is left for the next time: pruning never fails the run that asked for it.
    static func prune(root: URL, scenarioID: String, runInProgress: String, filer: QABugFiler?) async {
        guard let named = await runsNamedByBugs(filer) else { return }
        await Task.detached(priority: .utility) {
            let runs = QAStore.loadRuns(root).filter { $0.scenarioID == scenarioID }
                .map { QARunRetention.Entry(id: $0.id, startedAt: $0.startedAt, isFinished: $0.finishedAt != nil) }
            _ = QAStore.deleteRuns(root, runIDs: QARunRetention.runsToDelete(runs, referencedByBugs: named, inProgress: runInProgress))
        }.value
    }

    /// The runs the filed bug reports name; nil when they cannot be read.
    private static func runsNamedByBugs(_ filer: QABugFiler?) async -> Set<String>? {
        guard let filer, let keys = try? await filer.allFiledKeys() else { return nil }
        return QARunRetention.runIDs(inBugKeys: keys)
    }
}
