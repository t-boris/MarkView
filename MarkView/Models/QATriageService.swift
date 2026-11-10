import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-015): sets the person's mark on a finding of a run. The mark is written into the run file and,
// for a defect, carried to the bug report QA filed for it (QABugFiler.applyTriage). Both the run that just ended (QARunModel) and a run
// opened from the list (QARunArchive) mark through here.

enum QATriageService {
    struct Outcome {
        /// The run with the mark set.
        var record: QARunRecord
        /// What happened to the bug, in a sentence; nil when there was nothing to tell.
        var notice: String?
    }

    /// Marks (or, with a nil state, un-marks) `finding` of `record`, saves the run file off the main thread and updates the finding's bug.
    /// Nil when the run has no such finding or the mark is refused (a mark the finding does not offer, a workaround with no words).
    static func apply(_ record: QARunRecord, root: URL, finding id: String, state: QATriageState?, note: String, filer: QABugFiler?) async -> Outcome? {
        var updated = record
        guard QATriage.mark(&updated, finding: id, state, note: note, now: Date()), let finding = updated.findings.first(where: { $0.id == id }) else { return nil }
        let saved = updated
        var problems: [String] = []
        do {
            try await Task.detached(priority: .userInitiated) { try QAStore.saveRun(saved, root: root) }.value
        } catch {
            problems.append("The run could not be saved: \(error.localizedDescription)")
        }
        var notice: String?
        if finding.isDefect, let filer {
            let key = QABugDrafts.key(run: record.id, finding: id)
            do {
                let outcome = try await filer.applyTriage(key: key, QABugTriageChange.make(state, note: finding.triageNote ?? ""))
                notice = describe(outcome, state: state)
            } catch {
                problems.append("The bug report could not be changed: \(error.localizedDescription)")
            }
        }
        let text = ([notice].compactMap { $0 } + problems).joined(separator: " ")
        return Outcome(record: updated, notice: text.isEmpty ? nil : text)
    }

    static func describe(_ outcome: QABugTriageOutcome, state: QATriageState?) -> String? {
        switch outcome {
        case .noReport:
            return "No bug report was filed for this finding, so the mark stays on the finding only."
        case .updated(let id):
            switch state {
            case .confirmed?: return "\(id) is marked ready to fix."
            case .notABug?: return "\(id) is closed as not a bug."
            case .workaround?: return "The workaround is written into \(id)."
            case .seen?, .dismissed?, nil: return "The mark on \(id) is taken back."
            }
        case .notChanged(let id, let reason):
            return "The mark is saved on the finding, but \(id) was not changed: \(reason)"
        }
    }
}
