import Foundation

// Reconciles the stored status of one feature or bug with its transition history and the delivery evidence at hand
// (issue-lifecycle-management, REQ-005, DEC-009, DEC-015): what MarkView should record or ask next, and what a person
// should look at. Pure: it reads a snapshot and returns values; `IssueTransitionService` does the writing. Foundation
// only (with IssueCompletion.swift), so tools/tests/issue-lifecycle-tests.sh compiles it on its own.

/// A snapshot of one issue for the reconciler.
struct ReconcileInput: Equatable, Sendable {
    var kind: IssueKind
    /// Feature slug or bug key.
    var issue: String
    /// The status as the file says it now.
    var storedStatus: String
    var history: IssueHistory
    /// Delivery evidence collected now; nil when it was not collected. Unavailable or incomplete evidence never confirms.
    var delivery: DeliveryVerdict?
    /// A bug report with `regression_of` naming this issue, not closed as invalid or duplicate (DEC-009).
    var regressionBug: String?

    init(kind: IssueKind, issue: String, storedStatus: String, history: IssueHistory,
         delivery: DeliveryVerdict? = nil, regressionBug: String? = nil) {
        self.kind = kind
        self.issue = issue
        self.storedStatus = storedStatus
        self.history = history
        self.delivery = delivery
        self.regressionBug = regressionBug
    }
}

/// One step the caller carries out through the transition service, in order.
enum ReconcileAction: Equatable, Sendable {
    /// First sight of the issue: record the status as the history's start (`recordBaseline`).
    case baseline(status: String)
    /// The stored status is not the one the history ends with: record the edit as unverified (`recordExternalEdit`).
    case externalEdit(from: String, to: String)
    /// Delivery evidence confirms a completed status that an override or an outside edit set (`recordConfirmation`).
    case confirm(status: String, evidence: [String])
    /// A regression bug names the completed issue: reopen it with regression evidence through the transition rules.
    case reopen(bug: String, from: String)
    /// An operation began and never closed: `recoverPending` first; nothing else is decided on a half-written state.
    case recoverPending
}

enum IssueReconciler {
    /// The completed status that work under way can reach on its own, when the delivery evidence is complete: a feature being
    /// implemented becomes implemented, a bug being fixed becomes fixed (REQ-002 criterion 2, DEC-007). Nothing else completes
    /// by itself: a start needs a hand-off, verified and closed need acceptance, and an issue that was never started has no work.
    static func completionTarget(kind: IssueKind, status: String) -> String? {
        switch (kind, LifecycleVocabulary.normalize(status)) {
        case (.feature, "implementing"): return "implemented"
        case (.bug, "fixing"): return "fixed"
        default: return nil
        }
    }

    /// What to do about the issue now. Only `recoverPending` is returned while an operation is pending, only `baseline`
    /// while the issue has no history; the caller runs the pass again afterwards.
    static func actions(_ input: ReconcileInput) -> [ReconcileAction] {
        let history = input.history
        if !history.pending.isEmpty { return [.recoverPending] }
        let stored = LifecycleVocabulary.normalize(input.storedStatus)
        guard let expected = history.expectedStatus.map(LifecycleVocabulary.normalize) else { return [.baseline(status: stored)] }

        var out: [ReconcileAction] = []
        if stored != expected { out.append(.externalEdit(from: expected, to: stored)) }

        // What the issue is once the edit is on record, without today's delivery evidence.
        let projected = IssueCompletion.analysis(kind: input.kind, status: stored, history: history, deliveryNow: nil,
                                                 adoptExternalEdit: true).state

        // A confirmed regression (DEC-009) reopens a completed issue, once per regression bug. A completion that was
        // never a completion (cancelled) is not reopened, and confirming a completion that is reopened now is pointless.
        if let bug = input.regressionBug, LifecycleVocabulary.isCompletedStatus(input.kind, stored), !isCancelled(projected),
           !alreadyReopened(for: bug, in: history) {
            out.append(.reopen(bug: bug, from: stored))
            return out
        }

        // Evidence confirms an unproven completion only when it is complete: incomplete or unavailable evidence never does.
        if let delivery = input.delivery, delivery.isComplete, IssueCompletion.isCompletedOrArchived(input.kind, stored) {
            switch projected {
            case .overridden, .unverifiedEdit:
                out.append(.confirm(status: stored, evidence: IssueCompletion.deliveryLines(delivery)))
            default:
                break
            }
        }
        return out
    }

    /// What a person should look at. Nothing here changes a status: a failing check shows as a candidate and reopens
    /// nothing (Q-008, DEC-009), an outside edit stays listed until it is confirmed, accepted or restored (DEC-015).
    static func discrepancies(_ input: ReconcileInput) -> [Discrepancy] {
        let history = input.history
        let issue = input.issue
        if !history.pending.isEmpty {
            let listed = history.pending.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")
            return [Discrepancy(kind: .pendingOperation,
                                message: "\(issue) has \(history.pending.count) interrupted operation(s) (\(listed)). They are checked against the current status before anything is retried.")]
        }
        // Never recorded: a baseline is taken first, there is nothing to compare yet.
        guard let expected = history.expectedStatus.map(LifecycleVocabulary.normalize) else { return [] }

        let stored = LifecycleVocabulary.normalize(input.storedStatus)
        var out: [Discrepancy] = []

        let projected = IssueCompletion.analysis(kind: input.kind, status: stored, history: history, deliveryNow: nil,
                                                 adoptExternalEdit: true)
        let now = IssueCompletion.analysis(kind: input.kind, status: stored, history: history, deliveryNow: input.delivery,
                                           adoptExternalEdit: true)
        let confirmedNow = IssueCompletion.isVerified(now.state) && !IssueCompletion.isVerified(projected.state)

        // An edit outside MarkView that nothing has resolved.
        var editListed = false
        let unresolved = history.unresolvedExternal
        if stored != expected || !unresolved.isEmpty, !confirmedNow {
            let from = stored != expected ? expected : unresolved.first.map { LifecycleVocabulary.normalize($0.from) } ?? expected
            out.append(Discrepancy(kind: .unverifiedEdit, message: "The status of \(issue) was changed outside MarkView from \(shown(from)) to \(shown(stored)). The lifecycle conditions were not checked, so the change is no proof. Confirm it with delivery evidence, restore the previous status, or accept it as an override with a reason."))
            editListed = true
        }

        // A status outside the vocabulary has no rule to apply.
        if !stored.isEmpty, !LifecycleVocabulary.isKnown(input.kind, stored), !editListed {
            out.append(Discrepancy(kind: .unverifiedEdit, message: "\(issue) has the status \"\(stored)\", which is not a \(input.kind.rawValue) status. No lifecycle rule applies to it; only a person can move it."))
        }

        // A completed status nothing backs.
        switch now.state {
        case .overridden:
            out.append(Discrepancy(kind: .completedWithoutEvidence, message: "\(issue) is \(stored), but \(projected.note). Delivery evidence: \(summary(input.delivery))."))
        case .unverifiedEdit where !editListed:
            out.append(Discrepancy(kind: .completedWithoutEvidence, message: "\(issue) is \(stored) without delivery evidence: \(projected.note). Delivery evidence: \(summary(input.delivery))."))
        default:
            break
        }

        // A verified completion whose evidence no longer holds: shown, never acted on.
        if IssueCompletion.isVerified(projected.state), let delivery = input.delivery {
            switch delivery {
            case .incomplete(let missing):
                out.append(Discrepancy(kind: .regressionCandidate, message: "\(issue) is \(stored), but its delivery evidence no longer holds: \(joined(missing)). A failing check alone does not reopen it; a regression bug or a person does."))
            case .unknown(let reasons):
                out.append(Discrepancy(kind: .regressionCandidate, message: "\(issue) is \(stored), but its delivery evidence cannot be checked now: \(joined(reasons)). Nothing was changed."))
            case .complete:
                break
            }
        }
        return out
    }

    // MARK: Helpers

    private static func isCancelled(_ state: IssueCompletionState) -> Bool {
        if case .cancelled = state { return true } else { return false }
    }

    /// A reopen made on this regression bug's evidence is already on record ("regression: BUG-123").
    private static func alreadyReopened(for bug: String, in history: IssueHistory) -> Bool {
        let line = "regression: \(bug)".lowercased()
        return history.records.contains { record in
            (record.phase == .applied || record.phase == .recovered) && record.transitionKind == .reopen
                && record.evidence.contains { $0.lowercased() == line }
        }
    }

    private static func shown(_ status: String) -> String { status.isEmpty ? "(none)" : status }

    private static func joined(_ lines: [String]) -> String {
        lines.isEmpty ? "no detail" : lines.joined(separator: "; ")
    }

    private static func summary(_ delivery: DeliveryVerdict?) -> String {
        guard let delivery else { return "not collected" }
        let detail = delivery.lines.isEmpty ? "" : ": \(delivery.lines.joined(separator: "; "))"
        return "\(delivery.label)\(detail)"
    }
}
