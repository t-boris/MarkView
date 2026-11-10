import Foundation

// End-to-End QA (feature end-to-end-qa, Q-010 option A): which of a scenario's runs are kept. Every run leaves `run.json`, frames and one
// recording per branch in `.dde/qa/runs/<run id>/`; the newest few are kept, and so is every run a filed bug report names. Foundation
// only and pure: the decision is made from the values given, never from the file system; QARunCleanup.swift applies it to the disk.
// Checked on its own by tools/tests/qa-retention-tests.sh.

enum QARunRetention {
    /// How many of a scenario's newest runs are kept, a run in progress included (Q-010).
    static let defaultKeepNewest = 5

    /// What the rule needs to know about a run of the scenario.
    struct Entry: Equatable {
        var id: String
        var startedAt: Date
        /// False for a run that has not ended: another window may be writing it, so it is never deleted.
        var isFinished: Bool
    }

    /// The ids of the runs to delete, oldest first. The `keepNewest` runs that started last stay, and a run in progress holds one of those
    /// places even when it has no record on disk yet. Beyond them a run stays when a bug report names it (`referencedByBugs`), when it is
    /// the run in progress or when it has not ended. Runs are ordered by start time, then by id, so equal times always give the same answer.
    static func runsToDelete(_ runs: [Entry], referencedByBugs: Set<String>, inProgress: String? = nil, keepNewest: Int = defaultKeepNewest) -> [String] {
        var seen = Set<String>()
        let newestFirst = runs.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }.filter { seen.insert($0.id).inserted }
        var places = max(keepNewest, 0)
        if let inProgress, !seen.contains(inProgress) { places = max(places - 1, 0) }
        var doomed: [String] = []
        for (position, run) in newestFirst.enumerated() where position >= places {
            if run.id == inProgress || !run.isFinished || referencedByBugs.contains(run.id) { continue }
            doomed.append(run.id)
        }
        return doomed.reversed()
    }

    // MARK: The runs bug reports name

    /// The run a bug report names, from its `qa_key`: `<run id>:<branch>` for a check and `<run id>:finding:<finding>` for a finding
    /// (QABugDrafts.key). A run id is what QAStore.safeID makes: lower-case letters, digits and dashes. Nil for any other key.
    static func runID(inBugKey key: String) -> String? {
        let text = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let run = text[..<colon]
        guard !run.isEmpty, !text[text.index(after: colon)...].isEmpty, run.allSatisfy(isRunIDCharacter) else { return nil }
        return String(run)
    }

    /// The runs that these `qa_key` values name; a key that names none is left out.
    static func runIDs(inBugKeys keys: [String]) -> Set<String> {
        Set(keys.compactMap(runID(inBugKey:)))
    }

    private static func isRunIDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber || character == "-")
    }
}
