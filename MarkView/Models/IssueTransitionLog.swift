import Foundation

// The durable side of the lifecycle (issue-lifecycle-management, plan I-2): the transition history and operation journal
// of a project (DEC-014) and the one service that applies a decided transition around the stored status. Foundation only
// (with IssueLifecycle.swift), so tools/tests/issue-lifecycle-tests.sh compiles it on its own.
//
// One operation is: a `begin` record (the journal), the status written with a compare-and-set, an `applied` record.
// A request repeated with the same command id returns its first outcome; a request that saw an older status is stale; an
// operation that stopped between its writes is found by `recoverPending` and finished or closed, never left as a success.

/// One line of `.dde/lifecycle/transitions.jsonl`.
struct TransitionRecord: Codable, Equatable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Journal: the operation is about to write the status.
        case begin
        /// The status was written and the transition counts.
        case applied
        /// The operation finished after an interruption (the status had been written, the record had not).
        case recovered
        /// The operation did not change the status (stale, write failure, interrupted before the write).
        case aborted
        /// A request that the rules refused (kept so the person can inspect blocked transitions, REQ-004).
        case rejected
        /// The stored status changed outside the service (DEC-015); `verified` is false until confirmed.
        case external
        /// Evidence now confirms an externally edited or overridden completion.
        case confirmed
        /// First sight of an issue: the status the history starts from.
        case baseline
        /// Outcome of a GitHub close or reopen (`githubOutcome`).
        case github
        /// A rule variant was assigned to the item (`to` is the variant id, `from` the earlier one; feature-3, DEC-019, DEC-024).
        case assignment
        /// A person's note that is evidence: manual work has started, or a delivery event happened (`humanEvidence`).
        case evidence
    }

    /// What a person's evidence note is about (REQ-004, DEC-018).
    enum HumanEvidenceKind: String, Codable, Sendable {
        case start
        case delivery
    }

    /// The operation id: the begin and the applied record of one transition share it.
    var id: UUID
    var phase: Phase
    var command: String
    var kind: IssueKind
    var issue: String
    var from: String
    var to: String
    var actor: LifecycleActor
    var at: Date
    var reason: String?
    var transitionKind: TransitionKind?
    var override: Bool
    var bypassed: [LifecycleCondition]
    var missing: [LifecycleCondition]
    var evidence: [String]
    var message: String?
    /// `external` records: false until confirmed. Others: nil.
    var verified: Bool?
    /// `github` records: the target ("#294") and how the write ended. `evidence` records of a delivery: the event.
    var target: String?
    var githubOutcome: GitHubWriteOutcome?
    /// The revision of the project workflow and the rule variant the record was decided under (feature-3, DEC-026); nil on
    /// records written before workflows existed.
    var workflowRevision: Int?
    var variant: String?
    var humanEvidence: HumanEvidenceKind?

    init(id: UUID = UUID(), phase: Phase, command: String = "", kind: IssueKind, issue: String, from: String = "", to: String = "",
         actor: LifecycleActor, at: Date = Date(), reason: String? = nil, transitionKind: TransitionKind? = nil, override: Bool = false,
         bypassed: [LifecycleCondition] = [], missing: [LifecycleCondition] = [], evidence: [String] = [], message: String? = nil,
         verified: Bool? = nil, target: String? = nil, githubOutcome: GitHubWriteOutcome? = nil,
         workflowRevision: Int? = nil, variant: String? = nil, humanEvidence: HumanEvidenceKind? = nil) {
        self.workflowRevision = workflowRevision
        self.variant = variant
        self.humanEvidence = humanEvidence
        self.id = id
        self.phase = phase
        self.command = command
        self.kind = kind
        self.issue = issue
        self.from = from
        self.to = to
        self.actor = actor
        self.at = at
        self.reason = reason
        self.transitionKind = transitionKind
        self.override = override
        self.bypassed = bypassed
        self.missing = missing
        self.evidence = evidence
        self.message = message
        self.verified = verified
        self.target = target
        self.githubOutcome = githubOutcome
    }

    /// The record changed the issue's status (or established it).
    var setsStatus: Bool {
        switch phase {
        case .applied, .recovered, .external, .baseline: return true
        default: return false
        }
    }
}

/// How a GitHub close or reopen ended (REQ-004 criterion 4).
enum GitHubWriteOutcome: String, Codable, Sendable {
    /// GitHub showed the new state afterwards.
    case confirmed
    /// GitHub refused or the call failed and the state is unchanged.
    case failed
    /// The call did not answer and the state afterwards could not be read: neither success nor failure is known.
    case unconfirmed
}

// MARK: - Storage

protocol TransitionStorage: AnyObject {
    func append(_ record: TransitionRecord) throws
    /// Every record, oldest first. Damaged lines are skipped.
    func load() throws -> [TransitionRecord]
}

/// An append-only JSON-lines file, written by the journal and by the session links.
enum JSONLinesFile {
    /// Adds one line with a single `O_APPEND` write, so two writers (two windows on one project) never overwrite each other. A
    /// line that an earlier, interrupted write left without its newline is ended first, so the new line stands on its own.
    static func append(_ line: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var data = line
        let size = lseek(descriptor, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0
            if pread(descriptor, &last, 1, size - 1) == 1, last != 0x0A { data = Data([0x0A]) + line }
        }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// `.dde/lifecycle/transitions.jsonl` of a project: append-only, one JSON object per line.
final class FileTransitionStorage: TransitionStorage {
    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    convenience init(projectRoot: URL) {
        self.init(url: projectRoot.appendingPathComponent(".dde/lifecycle/transitions.jsonl"))
    }

    /// Times are kept to the millisecond, so what is read back orders against an observation made a moment before it.
    private static func timeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func encoder() -> JSONEncoder {
        let formatter = timeFormatter()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func append(_ record: TransitionRecord) throws {
        let line = try Self.encoder().encode(record) + Data("\n".utf8)
        lock.lock(); defer { lock.unlock() }
        try JSONLinesFile.append(line, to: url)
    }

    func load() throws -> [TransitionRecord] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let formatter = Self.timeFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a time: \(text)"))
            }
            return date
        }
        return text.split(separator: "\n").compactMap { try? decoder.decode(TransitionRecord.self, from: Data($0.utf8)) }
    }
}

// MARK: - Status store

/// The stored status of features and bugs (Markdown front matter in the app).
protocol LifecycleStatusStore: AnyObject {
    /// The stored status ("" when the file has none); nil when the issue does not exist.
    func status(kind: IssueKind, issue: String) -> String?
    /// Writes `to` only while the stored status is still `expected`. False: it changed meanwhile (nothing written).
    /// Throws when the file could not be written.
    func compareAndSet(kind: IssueKind, issue: String, expected: String, to: String) throws -> Bool
}

// MARK: - History view

/// The records of one issue, folded: a transition is its begin and its closing record together.
struct IssueHistory: Equatable, Sendable {
    let kind: IssueKind
    let issue: String
    /// Records of this issue, oldest first.
    let records: [TransitionRecord]

    init(kind: IssueKind, issue: String, all: [TransitionRecord]) {
        self.kind = kind
        self.issue = issue
        records = all.filter { $0.kind == kind && $0.issue == issue }
    }

    /// Records that set the status, oldest first.
    var changes: [TransitionRecord] { records.filter(\.setsStatus) }

    /// Starting an issue may follow an existing fix; only reopening starts a new delivery round.
    var deliveryRoundStart: Date? { changes.last { $0.phase != .baseline && $0.transitionKind == .reopen }?.at }

    /// The status the history says the issue has now; nil with no history.
    var expectedStatus: String? { changes.last?.to }

    var lastChange: TransitionRecord? { changes.last }

    /// Operations that wrote a begin record and never closed.
    var pending: [TransitionRecord] {
        let closed = Set(records.filter { [.applied, .recovered, .aborted].contains($0.phase) }.map(\.id))
        return records.filter { $0.phase == .begin && !closed.contains($0.id) }
    }

    var rejections: [TransitionRecord] { records.filter { $0.phase == .rejected } }

    /// External edits that no later `confirmed` record or applied change has resolved.
    var unresolvedExternal: [TransitionRecord] {
        // The journal is append-only, so its order says what came later, whatever the clock did.
        guard let index = records.lastIndex(where: { $0.phase == .external }) else { return [] }
        let later = records[(index + 1)...]
        return later.contains { $0.phase == .confirmed || $0.phase == .applied || $0.phase == .recovered } ? [] : [records[index]]
    }

    /// The transition a command id already produced. A refused or aborted request is not an answer: asked again
    /// (the evidence may have changed) it is decided again.
    func answered(command: String) -> TransitionRecord? {
        records.last { $0.command == command && [.applied, .recovered].contains($0.phase) }
    }

    var githubOutcomes: [TransitionRecord] { records.filter { $0.phase == .github } }

    // MARK: Workflow records (feature-3)

    /// The rule variant a person or the adoption assigned last; nil when none was.
    var assignedVariant: String? { records.last { $0.phase == .assignment }?.to }

    /// A person's note that manual work has started, written after the last change of status and not yet used by a start
    /// (REQ-004). The note is the start evidence only for a variant that accepts it.
    var pendingStartNote: TransitionRecord? {
        let lastChange = records.lastIndex { $0.setsStatus && $0.phase != .baseline } ?? -1
        return records.enumerated().last { $0.offset > lastChange && $0.element.phase == .evidence && $0.element.humanEvidence == .start }?.element
    }

    /// A person's confirmation of `event` in the current round of work: after the last reopening, or ever when it was not reopened.
    func deliveryConfirmation(event: String) -> TransitionRecord? {
        let wanted = Self.normalizeEvent(event)
        let round = records.lastIndex { ($0.phase == .applied || $0.phase == .recovered) && $0.transitionKind == .reopen } ?? -1
        return records.enumerated().last {
            $0.offset > round && $0.element.phase == .evidence && $0.element.humanEvidence == .delivery
                && Self.normalizeEvent($0.element.target ?? "") == wanted
        }?.element
    }

    static func normalizeEvent(_ event: String) -> String {
        event.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}

// MARK: - The service

enum ApplyResult: Equatable, Sendable {
    /// The status changed and the transition is on record.
    case applied(TransitionRecord)
    /// Already in that status; nothing was written.
    case unchanged
    /// The command id was answered before; its first outcome is returned and nothing was written.
    case duplicate(TransitionRecord)
    case rejected(Rejection)
    /// The stored status is no longer what the requester saw, or the observation is older than the current state.
    case stale(current: String)
    /// Nothing was changed (the journal or the status could not be written).
    case failed(String)
    /// The status was written but its record was not; `recoverPending` closes the operation. Not a confirmed success.
    case unrecorded(operation: UUID, message: String)

    var isApplied: Bool { if case .applied = self { return true } else { return false } }

    /// The issue has the requested status now: the change was made, was already there, was made by an earlier answer to the same
    /// command, or was written and only its record is missing (the next start closes it). A caller that undoes work when a
    /// change fails must not do that for any of these.
    var reachedStatus: Bool {
        switch self {
        case .applied, .unchanged, .duplicate, .unrecorded: return true
        case .rejected, .stale, .failed: return false
        }
    }

    /// A line for a person or an AI.
    var explanation: String {
        switch self {
        case .applied(let record): return "\(record.issue) is now \(record.to)."
        case .unchanged: return "No change: the status is already as requested."
        case .duplicate(let record): return "This request was already handled (\(record.phase.rawValue) \(record.from) → \(record.to))."
        case .rejected(let rejection): return ([rejection.message] + rejection.hints).joined(separator: " ")
        case .stale(let current): return "The status is now \"\(current)\", not what the request was based on. Read it again and decide again."
        case .failed(let message): return "Nothing was changed: \(message)"
        case .unrecorded(_, let message): return "The status was written but the history could not record it (\(message)); it is finished at the next start."
        }
    }
}

/// Serial: one transition at a time per project in this process. Another process or window is guarded by the
/// compare-and-set on the stored status.
final class IssueTransitionService: @unchecked Sendable {
    private let storage: TransitionStorage
    private let statuses: LifecycleStatusStore
    private let now: () -> Date
    private let lock = NSRecursiveLock()

    init(storage: TransitionStorage, statuses: LifecycleStatusStore, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.statuses = statuses
        self.now = now
    }

    func records() -> [TransitionRecord] { (try? storage.load()) ?? [] }

    func history(_ kind: IssueKind, _ issue: String) -> IssueHistory {
        lock.lock(); defer { lock.unlock() }
        return IssueHistory(kind: kind, issue: issue, all: records())
    }

    // MARK: Applying

    func apply(_ request: TransitionRequest) -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        // An operation of an earlier run that stopped half way is closed first, against the status as it is now.
        if !records().filter({ $0.phase == .begin }).isEmpty { recoverPending() }
        let history: IssueHistory
        do {
            history = IssueHistory(kind: request.kind, issue: request.issue, all: try storage.load())
        } catch {
            return .failed("the lifecycle history could not be read (\(error.localizedDescription))")
        }
        if let first = history.answered(command: request.command) { return .duplicate(first) }

        guard let current = statuses.status(kind: request.kind, issue: request.issue) else {
            return .failed("\(request.issue) does not exist.")
        }
        if LifecycleVocabulary.normalize(current) != LifecycleVocabulary.normalize(request.from) {
            return recordRejected(request, history, current: current, rejection: nil)
        }
        // An observation older than the state the history already holds must not overwrite it (REQ-005 criterion 2).
        if let observed = request.observedAt, let last = history.lastChange, observed < last.at {
            return recordRejected(request, history, current: current, rejection: nil)
        }

        switch LifecyclePolicy.decide(request) {
        case .noChange:
            return .unchanged
        case .rejected(let rejection):
            return recordRejected(request, history, current: current, rejection: rejection)
        case .allowed(let basis):
            return perform(request, basis: basis, override: false, bypassed: [])
        case .overridden(let basis, let bypassed):
            return perform(request, basis: basis, override: true, bypassed: bypassed)
        }
    }

    private func recordRejected(_ request: TransitionRequest, _ history: IssueHistory, current: String, rejection: Rejection?) -> ApplyResult {
        let message = rejection?.message ?? "stale: the stored status is \"\(current)\""
        let record = TransitionRecord(phase: .rejected, command: request.command, kind: request.kind, issue: request.issue,
                                      from: request.from, to: request.to, actor: request.actor, at: now(), reason: request.reason,
                                      missing: rejection?.missing ?? [], message: message,
                                      workflowRevision: request.workflow.revision, variant: request.variant.id)
        // MarkView's own observers ask again at every poll: a refusal identical to the last one is not recorded again.
        let repeated = request.actor.kind == .system && history.records.last.map { last in
            last.phase == .rejected && last.to == record.to && last.from == record.from && last.message == record.message
                && last.actor.name == record.actor.name
        } == true
        if !repeated { try? storage.append(record) }
        if let rejection { return .rejected(rejection) }
        return .stale(current: current)
    }

    private func perform(_ request: TransitionRequest, basis: TransitionBasis, override: Bool, bypassed: [LifecycleCondition],
                         workflowRevision: Int? = nil, variant: String? = nil) -> ApplyResult {
        let operation = UUID()
        let evidence = override ? [] : request.evidence.lines(for: basis.met)
        func record(_ phase: TransitionRecord.Phase, message: String? = nil) -> TransitionRecord {
            TransitionRecord(id: operation, phase: phase, command: request.command, kind: request.kind, issue: request.issue,
                             from: LifecycleVocabulary.normalize(request.from), to: LifecycleVocabulary.normalize(request.to),
                             actor: request.actor, at: now(), reason: request.trimmedReason.isEmpty ? nil : request.trimmedReason,
                             transitionKind: basis.kind, override: override, bypassed: bypassed, evidence: evidence, message: message,
                             workflowRevision: workflowRevision ?? request.workflow.revision, variant: variant ?? request.variant.id)
        }
        let begin = record(.begin)
        do { try storage.append(begin) } catch {
            return .failed("the lifecycle history could not be written (\(error.localizedDescription))")
        }
        let written: Bool
        do {
            written = try statuses.compareAndSet(kind: request.kind, issue: request.issue, expected: request.from, to: begin.to)
        } catch {
            try? storage.append(record(.aborted, message: "the status could not be written (\(error.localizedDescription))"))
            return .failed("the status could not be written (\(error.localizedDescription))")
        }
        guard written else {
            try? storage.append(record(.aborted, message: "the stored status changed meanwhile"))
            return .stale(current: statuses.status(kind: request.kind, issue: request.issue) ?? "")
        }
        let applied = record(.applied)
        do { try storage.append(applied) } catch {
            return .unrecorded(operation: operation, message: error.localizedDescription)
        }
        return .applied(applied)
    }

    // MARK: Recovery and external edits

    enum Recovery: Equatable, Sendable {
        case finished(TransitionRecord)
        case aborted(TransitionRecord)
        /// The status is neither the one before nor the one after: someone else changed it.
        case conflicting(TransitionRecord)
    }

    /// Looks at every operation that began and never closed (after a crash, a full disk, a quit) and closes it against the
    /// status as it is now. Safe to run any number of times.
    @discardableResult
    func recoverPending() -> [Recovery] {
        lock.lock(); defer { lock.unlock() }
        guard let all = try? storage.load() else { return [] }
        var results: [Recovery] = []
        var seen = Set<String>()
        for begin in all where begin.phase == .begin {
            let key = begin.kind.rawValue + ":" + begin.issue
            guard seen.insert(key).inserted else { continue }
            for pending in IssueHistory(kind: begin.kind, issue: begin.issue, all: all).pending {
                let current = LifecycleVocabulary.normalize(statuses.status(kind: pending.kind, issue: pending.issue) ?? "")
                var closing = pending
                closing.at = now()
                if current == pending.to {
                    closing.phase = .recovered
                    closing.message = "finished after an interruption"
                    if (try? storage.append(closing)) != nil { results.append(.finished(closing)) }
                } else if current == pending.from {
                    closing.phase = .aborted
                    closing.message = "interrupted before the status was written"
                    if (try? storage.append(closing)) != nil { results.append(.aborted(closing)) }
                } else {
                    closing.phase = .aborted
                    closing.message = "the status is now \"\(current)\", changed by someone else"
                    if (try? storage.append(closing)) != nil { results.append(.conflicting(closing)) }
                }
            }
        }
        return results
    }

    /// Whether the file says the issue has `status` right now. A caller that works from a copy loaded a moment ago must not
    /// record that copy as a fact: another thread may have changed the status since, and the record would be a false edit.
    private func isStored(_ kind: IssueKind, _ issue: String, _ status: String) -> Bool {
        statuses.status(kind: kind, issue: issue).map(LifecycleVocabulary.normalize) == LifecycleVocabulary.normalize(status)
    }

    /// Records the status of an issue seen for the first time, so that a later difference can be told from a first look.
    @discardableResult
    func recordBaseline(_ kind: IssueKind, _ issue: String, status: String, actor: LifecycleActor = .system("MarkView")) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isStored(kind, issue, status) else { return false }
        guard IssueHistory(kind: kind, issue: issue, all: records()).changes.isEmpty else { return false }
        let record = TransitionRecord(phase: .baseline, command: "baseline:\(kind.rawValue):\(issue)", kind: kind, issue: issue,
                                      from: "", to: LifecycleVocabulary.normalize(status), actor: actor, at: now(), verified: true)
        return (try? storage.append(record)) != nil
    }

    /// Records that the stored status is not the one the history ends with and no operation is pending (DEC-015).
    @discardableResult
    func recordExternalEdit(_ kind: IssueKind, _ issue: String, from: String, to: String) -> TransitionRecord? {
        lock.lock(); defer { lock.unlock() }
        let history = IssueHistory(kind: kind, issue: issue, all: records())
        guard history.pending.isEmpty, let expected = history.expectedStatus, isStored(kind, issue, to),
              LifecycleVocabulary.normalize(expected) == LifecycleVocabulary.normalize(from),
              LifecycleVocabulary.normalize(from) != LifecycleVocabulary.normalize(to) else { return nil }
        let record = TransitionRecord(phase: .external, command: "external:\(kind.rawValue):\(issue):\(LifecycleVocabulary.normalize(from)):\(LifecycleVocabulary.normalize(to)):\(history.records.count)",
                                      kind: kind, issue: issue, from: LifecycleVocabulary.normalize(from), to: LifecycleVocabulary.normalize(to),
                                      actor: LifecycleActor(kind: .system, name: "external edit"), at: now(),
                                      message: "The status was changed outside MarkView; the lifecycle conditions were not checked.", verified: false)
        return (try? storage.append(record)) != nil ? record : nil
    }

    /// Evidence now confirms the issue's current completed status.
    @discardableResult
    func recordConfirmation(_ kind: IssueKind, _ issue: String, status: String, evidence: [String]) -> TransitionRecord? {
        lock.lock(); defer { lock.unlock() }
        let history = IssueHistory(kind: kind, issue: issue, all: records())
        guard history.expectedStatus.map({ LifecycleVocabulary.normalize($0) == LifecycleVocabulary.normalize(status) }) == true else { return nil }
        let record = TransitionRecord(phase: .confirmed, command: "confirm:\(kind.rawValue):\(issue):\(history.records.count)", kind: kind, issue: issue,
                                      from: LifecycleVocabulary.normalize(status), to: LifecycleVocabulary.normalize(status),
                                      actor: .system("MarkView evidence"), at: now(), transitionKind: .completion, evidence: evidence, verified: true)
        return (try? storage.append(record)) != nil ? record : nil
    }

    // MARK: Workflow records (feature-3)

    /// Assigns a rule variant to an item (DEC-019, DEC-024). Nothing is written when the item already has that variant.
    @discardableResult
    func recordAssignment(_ kind: IssueKind, _ issue: String, variant: String, previous: String?, actor: LifecycleActor,
                          reason: String? = nil, workflowRevision: Int) -> TransitionRecord? {
        lock.lock(); defer { lock.unlock() }
        let history = IssueHistory(kind: kind, issue: issue, all: records())
        if history.assignedVariant == variant { return nil }
        let record = TransitionRecord(phase: .assignment, command: "assign:\(kind.rawValue):\(issue):\(history.records.count)", kind: kind, issue: issue,
                                      from: previous ?? "", to: variant, actor: actor, at: now(), reason: reason?.isEmpty == true ? nil : reason,
                                      workflowRevision: workflowRevision, variant: variant)
        return (try? storage.append(record)) != nil ? record : nil
    }

    /// Gives every listed item that has no variant yet the one `variantFor` names for its type, reading the journal once (the adoption
    /// of a workflow assigns every existing item, DEC-024). Returns true when every item has a variant afterwards.
    @discardableResult
    func recordInitialAssignments(_ items: [(kind: IssueKind, issue: String)], variantFor: (IssueKind) -> String, actor: LifecycleActor,
                                  reason: String, workflowRevision: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let all = records()
        var complete = true
        for item in items {
            let history = IssueHistory(kind: item.kind, issue: item.issue, all: all)
            guard history.assignedVariant == nil else { continue }
            let variant = variantFor(item.kind)
            let record = TransitionRecord(phase: .assignment, command: "assign:\(item.kind.rawValue):\(item.issue):\(history.records.count)", kind: item.kind,
                                          issue: item.issue, from: "", to: variant, actor: actor, at: now(), reason: reason,
                                          workflowRevision: workflowRevision, variant: variant)
            if (try? storage.append(record)) == nil { complete = false }
        }
        return complete
    }

    /// A person's note that manual work has started, or that a delivery event happened (REQ-004, DEC-018).
    @discardableResult
    func recordHumanEvidence(_ kind: IssueKind, _ issue: String, evidence: TransitionRecord.HumanEvidenceKind, text: String, event: String? = nil,
                             actor: LifecycleActor, variant: String? = nil, workflowRevision: Int? = nil) -> TransitionRecord? {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actor.kind == .human, !note.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let history = IssueHistory(kind: kind, issue: issue, all: records())
        let record = TransitionRecord(phase: .evidence, command: "evidence:\(evidence.rawValue):\(kind.rawValue):\(issue):\(history.records.count)", kind: kind,
                                      issue: issue, actor: actor, at: now(), reason: note, target: event, workflowRevision: workflowRevision,
                                      variant: variant, humanEvidence: evidence)
        return (try? storage.append(record)) != nil ? record : nil
    }

    /// Moves an item out of a status the workflow no longer has, into the one a person chose (Q-009, DEC-021). It is a transition of
    /// its own kind: it is neither an override nor delivery evidence, and the earlier history stays as it was.
    func applyReplacement(_ kind: IssueKind, _ issue: String, from: String, to: String, actor: LifecycleActor, reason: String,
                          workflowRevision: Int, variant: String?) -> ApplyResult {
        lock.lock(); defer { lock.unlock() }
        guard actor.kind == .human else { return .failed("Only a person replaces a status.") }
        guard let current = statuses.status(kind: kind, issue: issue) else { return .failed("\(issue) does not exist.") }
        guard LifecycleVocabulary.normalize(current) == LifecycleVocabulary.normalize(from) else { return .stale(current: current) }
        let request = TransitionRequest(command: "replace:\(kind.rawValue):\(issue):\(LifecycleVocabulary.normalize(from)):\(LifecycleVocabulary.normalize(to)):\(workflowRevision)",
                                        kind: kind, issue: issue, from: from, to: to, actor: actor, reason: reason)
        if let first = IssueHistory(kind: kind, issue: issue, all: records()).answered(command: request.command) { return .duplicate(first) }
        return perform(request, basis: TransitionBasis(kind: .replacement, met: []), override: false, bypassed: [],
                       workflowRevision: workflowRevision, variant: variant)
    }

    /// The outcome of a GitHub close or reopen for an issue (REQ-004 criterion 4).
    @discardableResult
    func recordGitHub(_ kind: IssueKind, _ issue: String, target: String, outcome: GitHubWriteOutcome, message: String,
                      actor: LifecycleActor = .system("GitHub sync")) -> TransitionRecord? {
        lock.lock(); defer { lock.unlock() }
        let record = TransitionRecord(phase: .github, command: "github:\(UUID().uuidString)", kind: kind, issue: issue, actor: actor, at: now(),
                                      message: message, target: target, githubOutcome: outcome)
        return (try? storage.append(record)) != nil ? record : nil
    }
}
