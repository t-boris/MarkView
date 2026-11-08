import Foundation

// Verified completion of one feature or bug (issue-lifecycle-management, DEC-010, DEC-013, DEC-015): whether the
// completed status an issue shows is backed by evidence, read from the transition history. GitHub closure
// (IssueGitHubSync.swift), manual Sync and the reconciler (IssueReconciler.swift) all ask this one function.
// Foundation only (with IssueLifecycle.swift and IssueTransitionLog.swift), so tools/tests/issue-lifecycle-tests.sh
// compiles it on its own.

/// Something a person should look at: local status against the history, or local status against GitHub (REQ-004
/// criterion 3, REQ-005 criterion 4). Shown, never fixed by itself.
struct Discrepancy: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The stored status was changed outside MarkView and nothing has confirmed it yet.
        case unverifiedEdit
        /// A completed status that no delivery evidence backs (a person's override, or first sight of a completed issue).
        case completedWithoutEvidence
        /// An operation began and never closed.
        case pendingOperation
        /// A verified completion whose delivery evidence no longer holds (a failing check, a missing release).
        case regressionCandidate
        /// A linked GitHub issue is closed although linked work is not verified complete.
        case githubClosedEarly
        /// A linked GitHub issue is open although all linked work is completed locally (without verification).
        case githubOpenDespiteCompletion
    }

    var kind: Kind
    var message: String
}

/// How far an issue's completion is proven (DEC-010).
enum IssueCompletionState: Equatable, Sendable {
    /// Completed on delivery evidence, or confirmed by it later. `basis` is the evidence behind it.
    case verified(basis: [String])
    /// The work is not completed (unstarted, under way, reopened). Certain, whatever the history says.
    case notComplete
    /// Closed or archived without completing the work (a duplicate bug, a feature archived before implementation).
    case cancelled(String)
    /// Completed by a person's override: the delivery conditions were bypassed.
    case overridden
    /// A completed status set outside MarkView (or found at first sight) that no evidence has confirmed.
    case unverifiedEdit
    /// The history cannot say: no history, a status that is not the one the history ends with, a status outside the
    /// vocabulary, an interrupted operation. Never a pass.
    case unknown(String)
}

enum IssueCompletion {
    /// The completion state of an issue now.
    ///
    /// - `status`: the stored status.
    /// - `history`: the records of this issue.
    /// - `deliveryNow`: the delivery evidence collected now, when it was collected. It only matters for an overridden
    ///   or unconfirmed completion: complete evidence confirms it (DEC-015). A completion that is verified stays
    ///   verified whatever `deliveryNow` says; whether it still holds on the remote is a question for the GitHub runner.
    static func state(kind: IssueKind, status: String, history: IssueHistory, deliveryNow: DeliveryVerdict?,
                      workflow: ProjectWorkflow = .standard) -> IssueCompletionState {
        analysis(kind: kind, status: status, history: history, deliveryNow: deliveryNow, adoptExternalEdit: false, workflow: workflow).state
    }

    static func isVerified(_ state: IssueCompletionState) -> Bool {
        if case .verified = state { return true } else { return false }
    }

    /// An issue was reopened (applied or recovered transition of kind `reopen`) after `date`.
    static func reopened(after date: Date, in history: IssueHistory) -> Bool {
        history.records.contains { record in
            (record.phase == .applied || record.phase == .recovered) && record.transitionKind == .reopen && record.at > date
        }
    }

    /// "delivery: PR #7 merged" lines of a verdict, in the form the history keeps evidence.
    static func deliveryLines(_ verdict: DeliveryVerdict) -> [String] {
        verdict.lines.map { "delivery: \($0)" }
    }

    // MARK: Analysis (shared with the reconciler)

    struct Analysis: Equatable, Sendable {
        var state: IssueCompletionState
        /// Why the state is what it is, for a person.
        var note: String
    }

    /// `adoptExternalEdit` answers the reconciler's question: what the state would be once a stored status that
    /// differs from the history is recorded as an external edit (until then it is `unknown`, a stale status).
    static func analysis(kind: IssueKind, status: String, history: IssueHistory, deliveryNow: DeliveryVerdict?,
                         adoptExternalEdit: Bool, workflow: ProjectWorkflow = .standard) -> Analysis {
        let stored = LifecycleVocabulary.normalize(status)
        guard LifecycleVocabulary.isKnown(kind, stored, in: workflow) else {
            let shown = stored.isEmpty ? "(none)" : stored
            return unknown("the status \"\(shown)\" is not a \(kind.rawValue) status")
        }
        guard isCompletedOrArchived(kind, stored, in: workflow) else {
            return Analysis(state: .notComplete, note: "\(stored) is not a completed status")
        }
        if !history.pending.isEmpty {
            return unknown("an interrupted operation on \(history.issue) is waiting to be recovered")
        }
        guard !history.changes.isEmpty else {
            return unknown("\(history.issue) has no lifecycle history, so its \(stored) status is not backed by a record")
        }

        var walked = fold(kind: kind, records: history.records, workflow: workflow)
        if walked.status != stored {
            let recorded = history.unresolvedExternal.contains { LifecycleVocabulary.normalize($0.to) == stored }
            guard adoptExternalEdit || recorded else {
                let expected = walked.status.map { $0.isEmpty ? "(none)" : $0 } ?? "(none)"
                return unknown("the stored status \"\(stored)\" is not the one the history ends with (\"\(expected)\")")
            }
            walked.chain = externalChain(kind: kind, from: walked.status ?? "", to: stored, workflow: workflow)
        }

        let confirmedNow = deliveryNow?.isComplete == true
        switch walked.chain {
        case .verified(let basis):
            return Analysis(state: .verified(basis: basis), note: "completed on delivery evidence")
        case .overridden(let note):
            if confirmedNow, let delivery = deliveryNow {
                return Analysis(state: .verified(basis: deliveryLines(delivery)), note: "the delivery evidence confirms it now")
            }
            return Analysis(state: .overridden, note: note)
        case .unverified(let note):
            if confirmedNow, let delivery = deliveryNow {
                return Analysis(state: .verified(basis: deliveryLines(delivery)), note: "the delivery evidence confirms it now")
            }
            return Analysis(state: .unverifiedEdit, note: note)
        case .cancelled(let message):
            return Analysis(state: .cancelled(message), note: message)
        case .unknown(let message):
            return unknown(message)
        case .none:
            return unknown("no recorded transition completed \(history.issue)")
        }
    }

    // MARK: The chain

    /// The history of one issue folded into how its present status was reached.
    private enum Chain {
        /// No completion in progress: specification, work under way, rolled back, reopened.
        case none
        case verified(basis: [String])
        case overridden(String)
        case unverified(String)
        case cancelled(String)
        case unknown(String)
    }

    private struct Walk {
        var chain: Chain = .none
        /// The status the records end with.
        var status: String?
    }

    /// Completed or cancelled by role: the work is over (a feature implemented or archived, a bug fixed or closed).
    static func isCompletedOrArchived(_ kind: IssueKind, _ status: String, in workflow: ProjectWorkflow = .standard) -> Bool {
        workflow.isFinished(kind, status)
    }

    private static func unknown(_ message: String) -> Analysis {
        Analysis(state: .unknown(message), note: message)
    }

    private static func fold(kind: IssueKind, records: [TransitionRecord], workflow: ProjectWorkflow) -> Walk {
        var result = Walk()
        for record in records {
            let to = LifecycleVocabulary.normalize(record.to)
            switch record.phase {
            case .baseline:
                result.status = to
                if LifecycleVocabulary.isCompletedStatus(kind, to, in: workflow) {
                    result.chain = .unverified("it was already \(to) when MarkView first recorded it, with no delivery evidence")
                } else if isCompletedOrArchived(kind, to, in: workflow) {
                    result.chain = .unknown("it was already archived when MarkView first recorded it")
                } else {
                    result.chain = .none
                }
            case .external:
                let from = LifecycleVocabulary.normalize(record.from)
                result.status = to
                result.chain = externalChain(kind: kind, from: from, to: to, workflow: workflow)
            case .applied, .recovered:
                result.chain = chain(after: record, kind: kind, previous: result.chain, workflow: workflow)
                result.status = to
            case .confirmed:
                // Evidence confirms the completed status the history ends with; nothing else.
                guard result.status == to, isCompletedOrArchived(kind, to, in: workflow) else { continue }
                switch result.chain {
                case .overridden, .unverified: result.chain = .verified(basis: record.evidence)
                default: break
                }
            case .begin, .aborted, .rejected, .github, .assignment, .evidence:
                continue
            }
        }
        return result
    }

    private static func externalChain(kind: IssueKind, from: String, to: String, workflow: ProjectWorkflow) -> Chain {
        guard isCompletedOrArchived(kind, to, in: workflow) else { return .none }
        let origin = from.isEmpty ? "(none)" : from
        return .unverified("the status was changed from \(origin) to \(to) outside MarkView, so no lifecycle condition was checked")
    }

    /// What an applied (or recovered) transition does to the chain.
    private static func chain(after record: TransitionRecord, kind: IssueKind, previous: Chain, workflow: ProjectWorkflow) -> Chain {
        let from = LifecycleVocabulary.normalize(record.from)
        let to = LifecycleVocabulary.normalize(record.to)
        switch record.transitionKind ?? .unlisted {
        case .completion:
            guard LifecycleVocabulary.isCompletedStatus(kind, to, in: workflow) else { return .none }
            if record.override {
                return .overridden(overrideNote(record, to: to))
            }
            return .verified(basis: record.evidence)
        case .acceptance:
            // Acceptance is a person's or an AI's step on top of the completion; it never makes a completion verified.
            switch previous {
            case .verified(let basis):
                return .verified(basis: basis + record.evidence)
            case .none:
                return .unknown("\(to) was reached with no recorded completion before it")
            default:
                return previous
            }
        case .archive:
            // Archived after completion keeps the completion as it was (DEC-013).
            if case .none = previous { return .unknown("archived with no recorded completion before it") }
            return previous
        case .cancellation:
            if kind == .bug {
                let detail = record.evidence.isEmpty ? (record.reason ?? "") : record.evidence.joined(separator: "; ")
                return .cancelled(detail.isEmpty ? "closed without a fix" : "closed without a fix: \(detail)")
            }
            return .cancelled("archived before completion")
        case .reopen:
            // Withdrawing an acceptance (verified back to implemented) leaves the delivery as it was; any other reopen ends the chain.
            if LifecycleVocabulary.isCompletedStatus(kind, from, in: workflow), LifecycleVocabulary.isCompletedStatus(kind, to, in: workflow) { return previous }
            return .none
        case .spec, .start, .rollback:
            return .none
        case .unlisted:
            // A forced step outside the table: a completed target is an override, a cancelled one a cancellation.
            if LifecycleVocabulary.isCompletedStatus(kind, to, in: workflow) { return .overridden(overrideNote(record, to: to)) }
            if workflow.role(kind, to) == .cancelled { return .cancelled("archived before completion") }
            return .none
        case .replacement:
            // The workflow lost a status and a person chose another for the item (DEC-021, DEC-029). A finished item stays what it was
            // while it is still finished; one that was not finished, or is not any more, has no completion in progress.
            guard isCompletedOrArchived(kind, to, in: workflow) else { return .none }
            if case .none = previous { return .unverified("the status was replaced by a person when the workflow changed, so no lifecycle condition was checked") }
            return previous
        }
    }

    private static func overrideNote(_ record: TransitionRecord, to: String) -> String {
        let reason = (record.reason ?? "").isEmpty ? "" : " (\(record.reason ?? ""))"
        return "\(to) was set by a person's override\(reason), without the delivery evidence"
    }
}
