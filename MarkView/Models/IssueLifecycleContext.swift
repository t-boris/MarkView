import Foundation

// What an AI session is told about the issue lifecycle (issue-lifecycle-management, plan I-5, REQ-003): the rules, the
// context of one linked issue (status, outstanding work, what the next transition still needs), the block appended to the
// prompts that hand an issue to an agent, and the links between sessions and issues. Foundation only (with
// IssueLifecycle.swift and IssueTransitionLog.swift), so tools/tests/issue-lifecycle-tests.sh compiles it on its own.
//
// Everything here reads; the only thing written is `SessionLinkStore`'s own file. Text is deterministic: the same input gives
// the same text, with fixed UTC timestamps and the statuses in vocabulary order.

// MARK: - Sessions linked to issues (REQ-003 criterion 4, Q-005)

/// An AI session declared to be working on an issue. A session counts only after an explicit `attached` record (the session
/// called markview_attach_issue) or a `handoff` record (MarkView handed the issue to it). Registering with the MCP server
/// alone creates nothing; `lastSeen` is the only sign that the session takes part in the workflow.
struct SessionAttachment: Codable, Equatable, Sendable {
    enum Via: String, Codable, Sendable {
        /// MarkView handed the issue to the agent ("Implement with AI", "Fix with AI").
        case handoff
        /// The session attached itself through project MCP.
        case attached
    }

    /// Feature slug or bug key ("BUG-012").
    var issue: String
    var kind: IssueKind
    /// The session label the caller gave.
    var session: String
    /// The assistant ("Claude Code", "codex").
    var tool: String
    var since: Date
    var via: Via
    /// The last time MarkView saw the session call a lifecycle tool for this issue; nil: registered but not seen.
    var lastSeen: Date?

    /// The start evidence the attachments give (DEC-011): the earliest one counts.
    static func startEvidence(_ attachments: [SessionAttachment]) -> StartEvidence? {
        let ordered = attachments.sorted { ($0.since, $0.session) < ($1.since, $1.session) }
        guard let first = ordered.first else { return nil }
        switch first.via {
        case .handoff: return .handoff(tool: first.tool, at: first.since)
        case .attached: return .attached(session: first.session, at: first.since)
        }
    }
}

enum SessionLinkError: Error, LocalizedError, Equatable {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let what): return "\(what) must not be empty."
        }
    }
}

/// One line of `.dde/lifecycle/sessions.jsonl`.
struct SessionLinkRecord: Codable, Equatable, Sendable {
    enum Op: String, Codable, Sendable {
        case attach
        /// A lifecycle tool call of an attached session was seen. With an issue: for that issue. Without: for the session as a whole.
        case seen
    }

    var op: Op
    var at: Date
    var session: String
    var issue: String?
    var kind: IssueKind?
    var tool: String?
    var via: SessionAttachment.Via?
}

/// The session links of a project: append-only JSON lines under `.dde/lifecycle/sessions.jsonl`, folded when read. A damaged
/// line is skipped. A call by a session that never attached is not recorded: registration alone proves nothing (REQ-003).
final class SessionLinkStore: @unchecked Sendable {
    let url: URL
    private let now: () -> Date
    private let lock = NSLock()

    /// A sighting of the same session and issue closer than this to the last one is not written again, so that a busy
    /// session does not grow the file with every call.
    static let seenThrottle: TimeInterval = 60

    init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    convenience init(projectRoot: URL, now: @escaping () -> Date = Date.init) {
        self.init(url: projectRoot.appendingPathComponent(".dde/lifecycle/sessions.jsonl"), now: now)
    }

    // MARK: Writing

    /// Links a session to an issue. Repeating it for the same issue and session returns the first attachment and writes
    /// nothing. Throws when the link could not be recorded: the caller must not report the session as attached then.
    @discardableResult
    func attach(issue: String, kind: IssueKind, session: String, tool: String, via: SessionAttachment.Via) throws -> SessionAttachment {
        let issue = Self.trim(issue), session = Self.trim(session)
        guard !issue.isEmpty else { throw SessionLinkError.missing("The issue") }
        guard !session.isEmpty else { throw SessionLinkError.missing("The session") }
        lock.lock(); defer { lock.unlock() }
        let state = Self.fold(try load())
        if let existing = state.attachment(issue, session) { return existing }
        let tool = Self.trim(tool).isEmpty ? "unknown" : Self.trim(tool)
        let at = Self.whole(now())
        try append(SessionLinkRecord(op: .attach, at: at, session: session, issue: issue, kind: kind, tool: tool, via: via))
        return SessionAttachment(issue: issue, kind: kind, session: session, tool: tool, since: at, via: via, lastSeen: nil)
    }

    /// Notes that MarkView saw `session` call a lifecycle tool (about `issue`, or in general when nil). Returns true when the call
    /// belongs to an attached session (and was written or was already noted a moment ago); a call of a session that never
    /// attached to that issue is not written.
    @discardableResult
    func noteCall(issue: String?, session: String, at date: Date? = nil) -> Bool {
        let session = Self.trim(session)
        guard !session.isEmpty else { return false }
        let issue = issue.map(Self.trim).flatMap { $0.isEmpty ? nil : $0 }
        lock.lock(); defer { lock.unlock() }
        let state = Self.fold((try? load()) ?? [])
        let when = Self.whole(date ?? now())
        let associated = issue.map { state.attachment($0, session) != nil } ?? state.attachments.contains { $0.session == session }
        guard associated else { return false }
        if let previous = state.lastStamp[Self.seenKey(issue, session)], when >= previous, when.timeIntervalSince(previous) < Self.seenThrottle {
            return true
        }
        guard (try? append(SessionLinkRecord(op: .seen, at: when, session: session, issue: issue))) != nil else { return false }
        return true
    }

    // MARK: Reading

    /// The sessions linked to an issue now, earliest first.
    func attachments(for issue: String) -> [SessionAttachment] {
        let wanted = Self.trim(issue).lowercased()
        return all().filter { $0.issue.lowercased() == wanted }
    }

    /// Every link that is active now, earliest first.
    func all() -> [SessionAttachment] {
        lock.lock(); defer { lock.unlock() }
        let state = Self.fold((try? load()) ?? [])
        return state.attachments.sorted { ($0.since, $0.issue, $0.session) < ($1.since, $1.issue, $1.session) }
    }

    // MARK: Folding

    private struct State {
        var attachments: [SessionAttachment] = []
        /// session and issue → last sighting written.
        var lastStamp: [String: Date] = [:]

        func attachment(_ issue: String, _ session: String) -> SessionAttachment? {
            let wanted = issue.lowercased()
            return attachments.first { $0.issue.lowercased() == wanted && $0.session == session }
        }
    }

    private static func fold(_ records: [SessionLinkRecord]) -> State {
        var state = State()
        for record in records {
            switch record.op {
            case .attach:
                guard let issue = record.issue, let kind = record.kind, let via = record.via,
                      state.attachment(issue, record.session) == nil else { continue }
                state.attachments.append(SessionAttachment(issue: issue, kind: kind, session: record.session, tool: record.tool ?? "unknown",
                                                           since: record.at, via: via, lastSeen: nil))
            case .seen:
                state.lastStamp[seenKey(record.issue, record.session)] = record.at
                for index in state.attachments.indices where state.attachments[index].session == record.session {
                    if let issue = record.issue, state.attachments[index].issue.lowercased() != issue.lowercased() { continue }
                    state.attachments[index].lastSeen = record.at
                }
            }
        }
        return state
    }

    private static func seenKey(_ issue: String?, _ session: String) -> String {
        "\(session)\u{1F}\(issue?.lowercased() ?? "")"
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The file keeps whole seconds, so what attach returns equals what is read back.
    private static func whole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    // MARK: File

    private func load() throws -> [SessionLinkRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(SessionLinkRecord.self, from: Data($0.utf8)) }
    }

    private func append(_ record: SessionLinkRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let line = try encoder.encode(record) + Data("\n".utf8)
        try JSONLinesFile.append(line, to: url)
    }
}

// MARK: - The context of an issue

/// Everything `IssueLifecycleContext.text` reads about one issue. The caller gathers it (status store, transition history,
/// delivery verdict, session links); this module only words it.
struct IssueContextInput: Sendable {
    var kind: IssueKind
    /// Feature slug or bug key.
    var issue: String
    var title: String
    var status: String
    var history: IssueHistory
    var delivery: DeliveryVerdict
    /// "verified completion", "not complete", "overridden", … as the completion evaluation words it.
    var completionLabel: String
    /// Differences between the stored status, the history and the observed work that are not resolved.
    var discrepancies: [String]
    var attached: [SessionAttachment]
    /// Whom the context is for. An AI is never shown the override.
    var actor: LifecycleActorKind
    /// Features: every acceptance criterion of the active requirements is ticked; nil: not known.
    var criteriaTicked: Bool?
    var githubLinks: [String]

    init(kind: IssueKind, issue: String, title: String, status: String, history: IssueHistory, delivery: DeliveryVerdict,
         completionLabel: String = "", discrepancies: [String] = [], attached: [SessionAttachment] = [],
         actor: LifecycleActorKind = .ai, criteriaTicked: Bool? = nil, githubLinks: [String] = []) {
        self.kind = kind
        self.issue = issue
        self.title = title
        self.status = status
        self.history = history
        self.delivery = delivery
        self.completionLabel = completionLabel
        self.discrepancies = discrepancies
        self.attached = attached
        self.actor = actor
        self.criteriaTicked = criteriaTicked
        self.githubLinks = githubLinks
    }
}

/// One line of the list markview_issue_context gives without an issue.
struct IssueSummaryLine: Equatable, Sendable {
    var kind: IssueKind
    var issue: String
    var title: String
    var status: String
    var completionLabel: String
    var sessions: [SessionAttachment]

    init(kind: IssueKind, issue: String, title: String, status: String, completionLabel: String = "", sessions: [SessionAttachment] = []) {
        self.kind = kind
        self.issue = issue
        self.title = title
        self.status = status
        self.completionLabel = completionLabel
        self.sessions = sessions
    }
}

enum IssueLifecycleContext {
    // MARK: Guidance

    /// The lifecycle rules for an AI session. Short on purpose: it is part of what every session is told.
    static let guidance = """
    Issue lifecycle: how features and bugs move through their statuses. MarkView checks every change against these rules, \
    records who made it, when, why and on what evidence, and refuses what the evidence does not support.

    Statuses
    - Feature: idea, exploring, draft, review, resolving, ready, implementing, implemented, verified, archived.
    - Bug: open, fixing, fixed, closed.
    - implemented / fixed: the work is delivered. verified / closed after a fix: the delivery was accepted. archived before \
    implemented, or a bug closed without a fix, is a cancellation, not a completion.

    Tools
    - markview_issue_context(issue): where one issue stands (status, outstanding work, the next steps open to you, history, \
    refused requests, sessions). Without issue: the issues in progress. Read it before you change a status and again after a \
    merge, a CI run or a release.
    - markview_attach_issue(issue, session?): declare that this session works on the issue. A session that MarkView did not \
    start counts only after this call.
    - markview_set_status(feature, status, reason?, evidence?) and markview_set_bug_status(id, status, reason?, evidence?, \
    duplicate_of?): request a step. MarkView applies it only when the rules and the evidence allow it and says what is missing \
    when they do not.
    - markview_get_feature / markview_get_bug: the full text, with requirements and acceptance criteria. Tick the criteria you \
    proved with markview_update_object (criteria_done).

    Rules
    1. Only a person in the MarkView window can force a status, and only with a reason. You never can: by_user: true on a tool \
    call does not make a request the person's. Never claim to be the person, to speak for them or to have their approval.
    2. Start: implementing / fixing needs start evidence: MarkView handed the issue to you (Implement with AI, Fix with AI) or \
    you called markview_attach_issue. Working from your own terminal, attach first.
    3. Completion: implemented / fixed is recorded by MarkView from evidence: every associated pull request merged, the \
    required checks passed and the release the project requires published. Your request succeeds only when that evidence is \
    complete. Missing, unavailable, stale or ambiguous evidence is never completion: unknown is not done.
    4. Acceptance: verified (feature) or closed after a fix (bug) needs your evidence text, what you verified and how, and for a \
    feature every acceptance criterion of its active requirements ticked. The work must already be implemented / fixed.
    5. Reopening: a person reopens an issue with a reason, or a bug report that is not closed as a duplicate or invalid names the \
    issue in regression_of. A failing check alone reopens nothing. New work that is independent of the finished work is not a \
    reopening: create a new feature or bug and name the finished one in `related`.
    6. A bug is closed without a fix only as a duplicate (duplicate_of) or with the validity check's finding that it is invalid \
    or already fixed.
    7. You may set the specification stages idea, exploring, draft, review and ready; resolving is the person's and MarkView's. \
    A person approves requirements, decisions and answers; you do not.
    8. Never edit a status in the Markdown files. An outside edit is recorded as unverified, never counts as completion and is \
    listed as a discrepancy.
    9. A refused request says what is missing: do that work or tell the person. Do not repeat it in other words or look for \
    another route to the same status.
    10. Report what MarkView accepted and what it refused. Do not call an issue complete before markview_issue_context says so.
    """

    // MARK: Context of one issue

    static func text(_ input: IssueContextInput) -> String {
        let kind = input.kind
        let status = LifecycleVocabulary.normalize(input.status)
        let known = LifecycleVocabulary.isKnown(kind, status)
        let sessions = input.attached.filter { $0.issue.lowercased() == input.issue.lowercased() && $0.kind == kind }
        var out: [String] = []

        out.append("\(kind.rawValue.capitalized) \(input.issue): \(oneLine(input.title, limit: 100))")
        out.append("Status: \(status.isEmpty ? "(none)" : status)")
        let label = oneLine(input.completionLabel, limit: 60)
        if !label.isEmpty { out.append("Completion: \(label)") }
        out.append(roleLine(input.actor))

        if known {
            out.append("")
            out += outstanding(input, status: status)
            out.append("")
            out += nextStepLines(input, status: status, sessions: sessions)
        } else {
            out.append("")
            out.append("Status \"\(oneLine(input.status, limit: 40))\" is not a \(kind.rawValue) status (unknown state). It never counts as completion, and only a person can move the issue in the MarkView window.")
        }

        out.append("")
        out += historyLines(input.history)
        out.append("")
        out += blockedLines(input.history)
        out.append("")
        out += discrepancyLines(input)
        out.append("")
        out += sessionLines(sessions, issue: input.issue)
        out.append("")
        out.append(input.githubLinks.isEmpty
                   ? "GitHub: no linked issue."
                   : "GitHub: \(input.githubLinks.map { oneLine($0, limit: 80) }.joined(separator: ", "))")
        return out.joined(separator: "\n")
    }

    private static func roleLine(_ actor: LifecycleActorKind) -> String {
        switch actor {
        case .ai:
            return "Role: AI session. You follow the lifecycle rules; any change beyond them is the person's to make in the MarkView window."
        case .system:
            return "Role: MarkView (automatic workflow). It follows the lifecycle rules."
        case .human:
            return "Role: person. You can also override a rule in the Lifecycle section by writing a reason; the history records what was bypassed."
        }
    }

    // MARK: Outstanding work

    private static func outstanding(_ input: IssueContextInput, status: String) -> [String] {
        let kind = input.kind
        guard LifecycleVocabulary.isActiveStatus(kind, status) || LifecycleVocabulary.isCompletedStatus(kind, status) else {
            return ["Outstanding work: delivery is not tracked at status \(status); it is checked while work is under way and after completion."]
        }
        var lines: [String] = []
        switch input.delivery {
        case .complete: lines.append("Outstanding work: no delivery evidence is missing.")
        case .incomplete: lines.append("Outstanding work: delivery evidence is incomplete.")
        case .unknown: lines.append("Outstanding work: delivery evidence is unknown (unknown is never completion).")
        }
        lines += bullets(input.delivery.lines, limit: 8)
        if kind == .feature, status == "implementing" || status == "implemented" {
            lines.append("Acceptance criteria: \(criteriaWord(input.criteriaTicked)).")
        }
        return lines
    }

    private static func criteriaWord(_ ticked: Bool?) -> String {
        switch ticked {
        case true?: return "all ticked"
        case false?: return "not all ticked"
        case nil: return "not checked"
        }
    }

    // MARK: Next steps

    private static func nextStepLines(_ input: IssueContextInput, status: String, sessions: [SessionAttachment]) -> [String] {
        let kind = input.kind
        let evidence = LifecycleEvidence(start: SessionAttachment.startEvidence(sessions), delivery: input.delivery)
        let order = LifecycleVocabulary.statuses(kind)
        let steps = LifecyclePolicy.nextSteps(kind: kind, status: status, actor: input.actor, evidence: evidence).sorted {
            (order.firstIndex(of: $0.to) ?? order.count, $0.kind.rawValue) < (order.firstIndex(of: $1.to) ?? order.count, $1.kind.rawValue)
        }
        let tool = kind == .feature ? "markview_set_status" : "markview_set_bug_status"
        var lines: [String] = []
        switch input.actor {
        case .ai: lines.append("Next steps open to you (request one with \(tool); MarkView checks the evidence itself):")
        case .system: lines.append("Next steps open to MarkView:")
        case .human: lines.append("Next steps (steps outside the rules are possible as an override, with a reason):")
        }

        let specification = steps.filter { $0.kind == .spec && $0.needs != nil }.map(\.to)
        if !specification.isEmpty {
            lines.append("- Within the specification: \(specification.joined(separator: ", ")) (no evidence needed).")
        }
        for step in steps where step.kind != .spec {
            if let line = stepLine(step, status: status, input: input) { lines.append(line) }
        }
        if lines.count == 1 {
            lines.append(input.actor == .human ? "- none by the rules from \(status)." : "- none from \(status); ask the person.")
        }
        if input.actor != .human { lines.append("Anything else is the person's to change in the MarkView window.") }
        return lines
    }

    private static func stepLine(_ step: LifecyclePolicy.NextStep, status: String, input: IssueContextInput) -> String? {
        let head = "- \(status) → \(step.to) (\(kindWord(step, from: status, kind: input.kind)))"
        guard step.needs != nil else {
            return input.actor == .human ? "\(head): only as an override; write a reason." : nil
        }
        if step.unmet.isEmpty { return "\(head): nothing missing." }
        let words = step.unmet.map { unmetWords($0, input) }.joined(separator: "; ")
        return "\(head): needs \(words)."
    }

    private static func kindWord(_ step: LifecyclePolicy.NextStep, from status: String, kind: IssueKind) -> String {
        switch step.kind {
        case .spec: return "specification"
        case .start: return "start"
        case .completion: return "completion"
        case .acceptance: return "acceptance"
        case .reopen: return "reopen"
        case .rollback: return "step back"
        case .unlisted: return "outside the table"
        case .archive, .cancellation:
            if kind == .bug { return "closed without a fix, not a completion" }
            return LifecycleVocabulary.isCompletedStatus(.feature, status) ? "archive, keeps the completion" : "cancellation, not a completion"
        }
    }

    private static func unmetWords(_ condition: LifecycleCondition, _ input: IssueContextInput) -> String {
        switch condition {
        case .startEvidence:
            return "start evidence (no handoff and no attached session yet: call markview_attach_issue)"
        case .deliveryEvidence:
            return "delivery evidence (\(input.delivery.label); see Outstanding work)"
        case .acceptanceEvidence:
            return input.kind == .feature
                ? "acceptance evidence (your verification text, and every acceptance criterion ticked: \(criteriaWord(input.criteriaTicked)))"
                : "acceptance evidence (your verification text)"
        case .regressionEvidence:
            return "regression evidence (a bug report whose regression_of names \(input.issue))"
        case .cancellationEvidence:
            return "cancellation evidence (duplicate_of, or the validity check's finding)"
        case .reason:
            return "a reason (written by the person)"
        case .listedTransition:
            return "a listed transition"
        }
    }

    // MARK: History, blocked requests, discrepancies, sessions

    private static let historyLimit = 5
    /// A refusal counts as recent while it is among this many latest records.
    private static let recentRecords = 12
    private static let blockedLimit = 3

    private static func historyLines(_ history: IssueHistory) -> [String] {
        let entries = history.records.filter { $0.setsStatus || $0.phase == .confirmed }
        guard !entries.isEmpty else { return ["History: none recorded."] }
        let shown = entries.suffix(historyLimit).reversed()
        let range = entries.count > historyLimit ? "; \(historyLimit) of \(entries.count)" : ""
        return ["History (newest first\(range)):"] + shown.map(historyLine)
    }

    private static func historyLine(_ record: TransitionRecord) -> String {
        let from = record.from.isEmpty ? "(none)" : record.from
        var line = "- \(stamp(record.at)) \(from) → \(record.to) by \(who(record.actor))"
        var flags: [String] = []
        if record.override {
            let bypassed = record.bypassed.map(\.rawValue).joined(separator: ", ")
            flags.append(bypassed.isEmpty ? "OVERRIDE" : "OVERRIDE, bypassed: \(bypassed)")
        }
        switch record.phase {
        case .external: flags.append(record.verified == false ? "changed outside MarkView, unverified" : "changed outside MarkView")
        case .baseline: flags.append("first seen")
        case .recovered: flags.append("finished after an interruption")
        case .confirmed: flags.append("confirmed by evidence")
        default: break
        }
        if let transition = record.transitionKind, record.phase == .applied || record.phase == .recovered { flags.append(transition.rawValue) }
        if !flags.isEmpty { line += " [\(flags.joined(separator: "; "))]" }
        if let reason = record.reason, !reason.isEmpty { line += " — reason: \(oneLine(reason, limit: 120))" }
        return line
    }

    private static func blockedLines(_ history: IssueHistory) -> [String] {
        let recent = history.records.suffix(recentRecords).filter { $0.phase == .rejected }
        guard !recent.isEmpty else { return ["Blocked requests: none recently."] }
        var lines = ["Blocked requests (nothing was changed):"]
        for record in recent.suffix(blockedLimit).reversed() {
            var line = "- \(stamp(record.at)) \(who(record.actor)) asked \(record.from) → \(record.to): \(oneLine(record.message ?? "refused", limit: 160))"
            if !record.missing.isEmpty { line += " (missing: \(record.missing.map(\.rawValue).joined(separator: ", ")))" }
            lines.append(line)
        }
        return lines
    }

    private static func discrepancyLines(_ input: IssueContextInput) -> [String] {
        var items = input.discrepancies.map { oneLine($0, limit: 200) }.filter { !$0.isEmpty }
        for external in input.history.unresolvedExternal {
            items.append("The status was changed outside MarkView (\(external.from) → \(external.to), \(stamp(external.at))) and is unverified.")
        }
        for pending in input.history.pending {
            items.append("An operation \(pending.from) → \(pending.to) began \(stamp(pending.at)) and is not closed; it is finished at the next start.")
        }
        guard !items.isEmpty else { return ["Discrepancies: none."] }
        return ["Discrepancies (not resolved):"] + items.map { "- \($0)" }
    }

    private static func sessionLines(_ sessions: [SessionAttachment], issue: String) -> [String] {
        guard !sessions.isEmpty else {
            return ["Sessions: none attached. A session takes part in this issue only after markview_attach_issue(issue: \"\(issue)\") or a MarkView handoff."]
        }
        let ordered = sessions.sorted { ($0.since, $0.session) < ($1.since, $1.session) }
        var lines = ["Sessions (registered is not participating: a session counts as observed only after MarkView saw it call a lifecycle tool):"]
        for session in ordered {
            let how = session.via == .handoff ? "handed off" : "attached"
            let seen = session.lastSeen.map { "seen \(stamp($0))" } ?? "registered but not seen"
            lines.append("- \(oneLine(session.session, limit: 60)) [\(oneLine(session.tool, limit: 40))], \(how) \(stamp(session.since)): \(seen)")
        }
        return lines
    }

    // MARK: Handoff block

    /// Appended to the prompts that hand an issue to an agent ("Implement with AI", "Fix with AI").
    static func handoffBlock(kind: IssueKind, issue: String, status: String, nextSteps: [LifecyclePolicy.NextStep]) -> String {
        let tool = kind == .feature ? "markview_set_status" : "markview_set_bug_status"
        let current = LifecycleVocabulary.normalize(status)
        var lines: [String] = []
        lines.append("MarkView issue lifecycle for \(kind.rawValue) \(issue) (status: \(current.isEmpty ? "(none)" : current)):")
        lines.append("- Read where it stands with markview_issue_context(issue: \"\(issue)\") and again after a merge, a CI run or a release. This handoff is your start evidence.")
        lines.append("- Change statuses only through MarkView (\(tool)), never by editing the Markdown files: an outside edit is recorded as unverified and never counts as completion.")
        lines.append("- MarkView completes implemented / fixed itself, while the project is open, once the work is merged, its required checks passed and the release the project requires exists; you may also ask with \(tool), and a request made before that evidence is complete is refused with what is missing.")
        if kind == .feature {
            lines.append("- MarkView finds the work of this feature by a trailer line in each commit message and pull request description: write \"Feature: \(issue)\" on a line of its own (or name docs/features/\(issue)).")
        }
        lines.append("- verified / closed after a fix needs your evidence text (what you verified and how) and, for a feature, every acceptance criterion ticked.")
        lines.append("- You are not the person: you cannot override a rule or approve in their place, and by_user: true does not change that.")
        lines.append(nextLine(kind: kind, status: current, nextSteps: nextSteps))
        return lines.joined(separator: "\n")
    }

    private static func nextLine(kind: IssueKind, status: String, nextSteps: [LifecyclePolicy.NextStep]) -> String {
        let order = LifecycleVocabulary.statuses(kind)
        let open = nextSteps.filter { $0.needs != nil && $0.kind != .spec }.sorted {
            (order.firstIndex(of: $0.to) ?? order.count, $0.kind.rawValue) < (order.firstIndex(of: $1.to) ?? order.count, $1.kind.rawValue)
        }
        guard !open.isEmpty else { return "- Next steps open to you from \(status): none; ask the person." }
        let parts = open.map { step -> String in
            // The handoff itself is the start evidence, so a start step is not shown as missing anything.
            if step.kind == .start || step.unmet.isEmpty { return step.to }
            return "\(step.to) (needs \(step.unmet.map(shortName).joined(separator: ", ")))"
        }
        return "- Next steps open to you from \(status): \(parts.joined(separator: "; "))."
    }

    private static func shortName(_ condition: LifecycleCondition) -> String {
        switch condition {
        case .startEvidence: return "start evidence"
        case .deliveryEvidence: return "delivery evidence"
        case .acceptanceEvidence: return "acceptance evidence"
        case .regressionEvidence: return "regression evidence"
        case .cancellationEvidence: return "duplicate_of or the validity finding"
        case .reason: return "a reason"
        case .listedTransition: return "a listed transition"
        }
    }

    // MARK: List

    /// The issues in progress or with an attached session, for markview_issue_context without an issue.
    static func listText(_ summaries: [IssueSummaryLine]) -> String {
        guard !summaries.isEmpty else {
            return "No issue is in progress and no session is attached. Pass an issue (a feature slug or BUG-nnn) to markview_issue_context for its context; start work from MarkView or attach with markview_attach_issue."
        }
        func rank(_ kind: IssueKind) -> Int { kind == .feature ? 0 : 1 }
        let ordered = summaries.sorted { (rank($0.kind), $0.issue) < (rank($1.kind), $1.issue) }
        var lines = ["Issues in progress or with an attached session (\(ordered.count)):"]
        for summary in ordered {
            let status = LifecycleVocabulary.normalize(summary.status)
            var line = "- \(summary.kind.rawValue) \(summary.issue): \(oneLine(summary.title, limit: 80)) [\(status.isEmpty ? "(none)" : status)]"
            let label = oneLine(summary.completionLabel, limit: 40)
            if !label.isEmpty { line += "; \(label)" }
            if summary.sessions.isEmpty {
                line += "; sessions: none"
            } else {
                let seen = summary.sessions.filter { $0.lastSeen != nil }.count
                line += "; sessions: \(summary.sessions.count) attached, \(seen) seen"
            }
            lines.append(line)
        }
        lines.append("Call markview_issue_context with an issue for its status, outstanding work and next steps.")
        return lines.joined(separator: "\n")
    }

    // MARK: Words

    private static func who(_ actor: LifecycleActor) -> String {
        switch actor.kind {
        case .human: return "person \(actor.name)"
        case .ai: return actor.session.map { "AI \(actor.name) (\($0))" } ?? "AI \(actor.name)"
        case .system: return actor.name
        }
    }

    private static func bullets(_ lines: [String], limit: Int) -> [String] {
        let cleaned = lines.map { oneLine($0, limit: 200) }.filter { !$0.isEmpty }
        var out = cleaned.prefix(limit).map { "- \($0)" }
        if cleaned.count > limit { out.append("- … and \(cleaned.count - limit) more") }
        return out
    }

    /// One line: whitespace and newlines collapsed, cut at `limit` characters.
    private static func oneLine(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// "2026-11-05 14:03 UTC": fixed zone and format, so the same input always reads the same.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
