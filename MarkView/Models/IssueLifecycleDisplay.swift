import Foundation

// How the Lifecycle section of the window presents one feature or bug (issue-lifecycle-management, REQ-004, REQ-005): the same
// records and rules the AI context reads (IssueLifecycleContext), as rows a person can scan. An applied transition shows the
// previous and the resulting status, the actor, the time, the reason and the evidence; an override is marked with its reason and
// the conditions it bypassed; blocked requests, discrepancies and GitHub outcomes are listed apart. Pure and Foundation only, so
// tools/tests/issue-lifecycle-tests.sh compiles it on its own.

/// One line of the history, of the blocked requests or of the GitHub outcomes.
struct LifecycleRow: Equatable, Identifiable, Sendable {
    enum Tone: String, Sendable {
        case normal
        /// A person forced the step (REQ-002); always shown with its reason and the conditions it bypassed.
        case override
        /// The status was changed outside MarkView and nothing has confirmed it (DEC-015).
        case external
        /// The rules refused the request; nothing was changed.
        case blocked
        /// Evidence backs the step, or GitHub confirmed the write.
        case success
        /// GitHub refused the write.
        case failure
        /// GitHub did not answer and the state afterwards is not known.
        case unconfirmed
    }

    var id: String
    var tone: Tone
    var time: Date
    /// "implemented → verified", "asked implemented → verified", "GitHub #294: closed and confirmed".
    var headline: String
    /// "person Boris", "AI Claude Code (s1)", "MarkView".
    var actor: String
    /// Reason, evidence, bypassed or missing conditions, one per line.
    var notes: [String]
}

struct IssueLifecycleDisplay: Equatable, Sendable {
    var kind: IssueKind
    var issue: String
    /// The status as stored, normalised.
    var status: String
    /// "verified completion", "completed by an override, not verified", …
    var completion: String
    /// Newest first: every applied, recovered, external and baseline record and every confirmation.
    var history: [LifecycleRow]
    /// Requests the rules refused, newest first.
    var blocked: [LifecycleRow]
    /// Close and reopen outcomes on GitHub, newest first.
    var github: [LifecycleRow]
    /// What differs between the stored status, the history and the observed work, and what is not resolved.
    var discrepancies: [String]
    /// The status a person accepts into (feature implemented → verified, bug fixed → closed); nil when the issue is not there.
    var acceptTarget: String?
    /// The unfinished status a person reopens a completed issue into; nil when the issue is not completed.
    var reopenTarget: String?
    /// Only a completed status can be confirmed against the delivery evidence (DEC-015).
    var canCheckEvidence: Bool
    /// The rule variant of the item (feature-3): its name and one line of what it requires.
    var variantID: String = ""
    var variantName: String = ""
    var variantSummary: String = ""
    /// A person may start manual work with a note: the item has not started and its variant accepts a note (REQ-004).
    var canStartWithNote: Bool = false
    /// The delivery event a person confirms, when the variant has one and the work is under way or completed.
    var eventToConfirm: String?
    var eventConfirmed: Bool = false

    static let historyLimit = 30
    static let blockedLimit = 5
    static let githubLimit = 5

    static func make(kind: IssueKind, issue: String, status: String, history: IssueHistory, completion: String,
                     discrepancies: [String] = [], workflow: ProjectWorkflow = .standard, variantID: String? = nil) -> IssueLifecycleDisplay {
        let current = LifecycleVocabulary.normalize(status)
        let variant = workflow.resolvedVariant(kind, assigned: variantID)
        let role = workflow.role(kind, current)
        let changes = history.records.filter { $0.setsStatus || $0.phase == .confirmed }
        var notes = discrepancies.map(oneLine).filter { !$0.isEmpty }
        for external in history.unresolvedExternal {
            notes.append("The status was changed outside MarkView (\(show(external.from)) → \(show(external.to)), \(stamp(external.at))) "
                         + "and is unverified: nothing shows the lifecycle conditions were met.")
        }
        for pending in history.pending {
            notes.append("An operation \(show(pending.from)) → \(show(pending.to)) began \(stamp(pending.at)) and is not closed; "
                         + "it is finished at the next start.")
        }
        return IssueLifecycleDisplay(
            kind: kind, issue: issue, status: current, completion: completion,
            history: changes.suffix(historyLimit).reversed().map(row),
            blocked: history.rejections.suffix(blockedLimit).reversed().map(blockedRow),
            github: history.githubOutcomes.suffix(githubLimit).reversed().map(githubRow),
            discrepancies: notes,
            acceptTarget: acceptStatus(kind: kind, status: current, workflow: workflow, variantID: variantID),
            reopenTarget: reopenStatus(kind: kind, status: current, workflow: workflow, variantID: variantID),
            canCheckEvidence: LifecycleVocabulary.isCompletedStatus(kind, current, in: workflow),
            variantID: variant?.id ?? "", variantName: variant?.name ?? "", variantSummary: variant?.description ?? "",
            canStartWithNote: role == .notStarted && variant?.start == .agentOrNote
                && workflow.lifecycle(kind, variant: variantID).rules.contains { $0.kind == .start && $0.from.contains(current) && $0.needs[.human] != nil },
            eventToConfirm: (role == .active || role == .completed) ? variant?.deliveryRules.confirmedEventName : nil,
            eventConfirmed: variant?.deliveryRules.confirmedEventName.map { history.deliveryConfirmation(event: $0) != nil } ?? false)
    }

    // MARK: Which actions the section offers

    /// Feature implemented → verified; bug fixed → closed. The person accepts without further evidence (Q-001); the history
    /// keeps who and when.
    static func acceptStatus(kind: IssueKind, status: String, workflow: ProjectWorkflow = .standard, variantID: String? = nil) -> String? {
        workflow.lifecycle(kind, variant: variantID).rules.first { $0.kind == .acceptance && $0.from.contains(status) && $0.needs[.human] != nil }?.to
    }

    /// A completed status goes back to the unfinished stage of its work: implementing for a feature, open for a bug (REQ-002).
    static func reopenStatus(kind: IssueKind, status: String, workflow: ProjectWorkflow = .standard, variantID: String? = nil) -> String? {
        let definition = workflow.lifecycle(kind, variant: variantID)
        guard definition.role(of: status) == .completed else { return nil }
        let targets = definition.rules.filter { $0.kind == .reopen && $0.from.contains(status) && $0.needs[.human] != nil }
            .map(\.to).filter { definition.role(of: $0) != .completed }
        return targets.first { definition.role(of: $0) == .active } ?? targets.first
    }

    // MARK: Rows

    private static func row(_ record: TransitionRecord) -> LifecycleRow {
        var notes: [String] = []
        var tone = LifecycleRow.Tone.normal
        switch record.phase {
        case .baseline:
            notes.append("First seen by MarkView; the history starts here.")
        case .external:
            tone = .external
            notes.append(record.verified == false
                         ? "Changed outside MarkView. Unverified until delivery evidence confirms it."
                         : "Changed outside MarkView.")
        case .confirmed:
            tone = .success
            notes.append("Confirmed by evidence.")
        case .recovered:
            notes.append("Finished after an interruption.")
        default:
            break
        }
        if record.override {
            tone = .override
            let bypassed = record.bypassed.map(\.words).joined(separator: "; ")
            notes.insert(bypassed.isEmpty ? "Override by a person." : "Override by a person, bypassed: \(bypassed).", at: 0)
        }
        if let reason = record.reason, !oneLine(reason).isEmpty { notes.append("Reason: \(oneLine(reason))") }
        if let kind = record.transitionKind, record.phase == .applied || record.phase == .recovered { notes.append("Step: \(kind.rawValue)") }
        for item in record.evidence where !oneLine(item).isEmpty { notes.append("Evidence: \(oneLine(item))") }
        if let message = record.message, !oneLine(message).isEmpty, record.phase != .confirmed, record.phase != .baseline {
            notes.append(oneLine(message))
        }
        let headline = record.phase == .baseline ? "first seen: \(record.to)" : "\(show(record.from)) → \(record.to)"
        return LifecycleRow(id: "\(record.id.uuidString)-\(record.phase.rawValue)", tone: tone, time: record.at, headline: headline,
                            actor: who(record.actor), notes: notes)
    }

    private static func blockedRow(_ record: TransitionRecord) -> LifecycleRow {
        var notes = [oneLine(record.message ?? "The request was refused.")]
        if !record.missing.isEmpty { notes.append("Missing: \(record.missing.map(\.words).joined(separator: "; "))") }
        if let reason = record.reason, !oneLine(reason).isEmpty { notes.append("Reason given: \(oneLine(reason))") }
        return LifecycleRow(id: "\(record.id.uuidString)-rejected-\(record.command)", tone: .blocked, time: record.at,
                            headline: "asked \(show(record.from)) → \(record.to), nothing changed", actor: who(record.actor), notes: notes)
    }

    private static func githubRow(_ record: TransitionRecord) -> LifecycleRow {
        let target = record.target ?? "the linked issue"
        let outcome = record.githubOutcome ?? .unconfirmed
        let tone: LifecycleRow.Tone
        let result: String
        switch outcome {
        case .confirmed: tone = .success; result = "confirmed"
        case .failed: tone = .failure; result = "failed"
        case .unconfirmed: tone = .unconfirmed; result = "not confirmed (the outcome is unknown)"
        }
        var notes: [String] = []
        if let message = record.message, !oneLine(message).isEmpty { notes.append(oneLine(message)) }
        return LifecycleRow(id: "\(record.id.uuidString)-github-\(record.command)", tone: tone, time: record.at,
                            headline: "GitHub \(target): \(result)", actor: who(record.actor), notes: notes)
    }

    // MARK: Words

    private static func show(_ status: String) -> String { status.isEmpty ? "(none)" : status }

    static func who(_ actor: LifecycleActor) -> String {
        switch actor.kind {
        case .human: return "person \(actor.name)"
        case .ai: return actor.session.map { "AI \(actor.name) (\($0))" } ?? "AI \(actor.name)"
        case .system: return actor.name
        }
    }

    private static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limit = 240
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// "2026-11-05 14:03 UTC": a fixed zone and format, so the same record always reads the same.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}

extension LifecycleCondition {
    /// A short name for a person: "delivery evidence", "a reason".
    var words: String {
        switch self {
        case .startEvidence: return "start evidence"
        case .deliveryEvidence: return "delivery evidence"
        case .acceptanceEvidence: return "acceptance evidence"
        case .regressionEvidence: return "regression evidence"
        case .cancellationEvidence: return "cancellation evidence"
        case .reason: return "a reason"
        case .listedTransition: return "a listed transition"
        case .humanAcceptance: return "a person's acceptance"
        }
    }
}
