import Foundation

// The shared lifecycle rules of features and bugs (issue-lifecycle-management, plan I-1): who may move an
// issue from one status to another, on what evidence, and why a request is refused. UI, project MCP and
// MarkView's own workflows all ask this one function (REQ-001). Foundation only (with FeatureVocabulary.swift
// and IssueListing.swift), so tools/tests/issue-lifecycle-tests.sh compiles it on its own.
//
// The stored statuses stay the vocabularies of `FeatureVocabulary` (DEC-013): features idea … archived, bugs
// open, fixing, fixed, closed. Nothing here writes a file; `IssueTransitionService` does that around a decision.

enum IssueKind: String, Codable, Sendable {
    case feature, bug
}

/// Who asks (DEC-011). Only a human gesture in the MarkView UI can force a transition.
enum LifecycleActorKind: String, Codable, Sendable {
    case human, ai, system
}

struct LifecycleActor: Codable, Equatable, Sendable {
    var kind: LifecycleActorKind
    /// For display: "Boris", "claude-code", "MarkView handoff".
    var name: String
    /// The agent session label, when the caller gave one.
    var session: String?

    init(kind: LifecycleActorKind, name: String, session: String? = nil) {
        self.kind = kind
        self.name = name
        self.session = session
    }

    static func human(_ name: String = "person") -> LifecycleActor { LifecycleActor(kind: .human, name: name) }
    static func ai(_ name: String = "AI", session: String? = nil) -> LifecycleActor { LifecycleActor(kind: .ai, name: name, session: session) }
    static func system(_ name: String) -> LifecycleActor { LifecycleActor(kind: .system, name: name) }
}

/// What a transition needs before it is allowed. A person may force a transition whose conditions are not met,
/// with a reason; the history then names the bypassed conditions (REQ-004).
enum LifecycleCondition: String, Codable, CaseIterable, Sendable {
    /// The issue was handed to an agent, or an AI session attached itself to it.
    case startEvidence = "start-evidence"
    /// Every associated work unit is merged, the required checks passed and a required release was delivered (DEC-007).
    case deliveryEvidence = "delivery-evidence"
    /// AI: verification text and (features) every acceptance criterion ticked (DEC-008).
    case acceptanceEvidence = "acceptance-evidence"
    /// A linked bug report names this issue in `regression_of` (DEC-009).
    case regressionEvidence = "regression-evidence"
    /// A duplicate, an invalid report or an "already fixed" finding for a bug closed without a fix.
    case cancellationEvidence = "cancellation-evidence"
    /// A non-empty reason written by the person.
    case reason
    /// The pair of statuses is not in the lifecycle table at all.
    case listedTransition = "listed-transition"

    var title: String {
        switch self {
        case .startEvidence: return "start evidence (the issue was handed to an agent or a session attached to it)"
        case .deliveryEvidence: return "delivery evidence (all work merged, checks passed, required release published)"
        case .acceptanceEvidence: return "acceptance evidence (verification text and every acceptance criterion ticked)"
        case .regressionEvidence: return "regression evidence (a bug report with regression_of naming this issue)"
        case .cancellationEvidence: return "cancellation evidence (duplicate, invalid or already fixed)"
        case .reason: return "a reason"
        case .listedTransition: return "a transition that exists in the lifecycle table"
        }
    }
}

/// What kind of step a transition is. Completion and cancellation are told apart so that closing a bug
/// as a duplicate never counts as verified completion (DEC-010, DEC-013).
enum TransitionKind: String, Codable, Sendable {
    case spec           // moves between the specification stages
    case start          // implementing / fixing
    case completion     // implemented / fixed on delivery evidence
    case acceptance     // verified / closed after a fix
    case cancellation   // archived before completion, a bug closed without a fix
    case archive        // archived after completion
    case reopen         // a completed issue back to unfinished work
    case rollback       // unfinished work back to an earlier stage
    case unlisted       // forced; not in the table
}

// MARK: - Evidence the policy reads

enum StartEvidence: Codable, Equatable, Sendable {
    /// MarkView sent the issue to an agent and the agent accepted it.
    case handoff(tool: String, at: Date)
    /// An AI session declared itself to be working on the issue through project MCP.
    case attached(session: String, at: Date)

    var summary: String {
        switch self {
        case .handoff(let tool, _): return "handed to \(tool)"
        case .attached(let session, _): return "session \(session) attached"
        }
    }
}

/// The verdict of the delivery evidence (merge, checks, release) at the time of the request. Missing,
/// unavailable, stale or ambiguous evidence is never a pass (REQ-005).
enum DeliveryVerdict: Codable, Equatable, Sendable {
    case complete(summary: [String])
    case incomplete(missing: [String])
    case unknown(reasons: [String])

    var isComplete: Bool { if case .complete = self { return true } else { return false } }

    var lines: [String] {
        switch self {
        case .complete(let summary): return summary
        case .incomplete(let missing): return missing
        case .unknown(let reasons): return reasons
        }
    }

    var label: String {
        switch self {
        case .complete: return "complete"
        case .incomplete: return "incomplete"
        case .unknown: return "unknown"
        }
    }

    static let notCollected = DeliveryVerdict.unknown(reasons: ["Delivery evidence was not collected."])
}

struct AcceptanceEvidence: Codable, Equatable, Sendable {
    /// What was verified and how, written by the caller.
    var text: String
    /// Features: every acceptance criterion of the active requirements is ticked. Bugs have none (true).
    var criteriaAllTicked: Bool

    init(text: String, criteriaAllTicked: Bool) {
        self.text = text
        self.criteriaAllTicked = criteriaAllTicked
    }
}

enum RegressionEvidence: Codable, Equatable, Sendable {
    /// A bug report with `regression_of` naming the issue, not closed as invalid or duplicate.
    case bug(id: String)
}

enum CancellationEvidence: Codable, Equatable, Sendable {
    case duplicate(of: String)
    case invalid(String)
    /// The bug validity check found the bug already fixed on the default branch. It closes the bug, but it is a finding of a model
    /// about the code, not delivery evidence, so it is a cancellation and not verified completion.
    case alreadyFixed(String)
}

struct LifecycleEvidence: Equatable, Sendable {
    var start: StartEvidence?
    var delivery: DeliveryVerdict
    var acceptance: AcceptanceEvidence?
    var regression: RegressionEvidence?
    var cancellation: CancellationEvidence?

    init(start: StartEvidence? = nil, delivery: DeliveryVerdict = .notCollected, acceptance: AcceptanceEvidence? = nil,
         regression: RegressionEvidence? = nil, cancellation: CancellationEvidence? = nil) {
        self.start = start
        self.delivery = delivery
        self.acceptance = acceptance
        self.regression = regression
        self.cancellation = cancellation
    }

    static let none = LifecycleEvidence()

    /// The evidence lines the history keeps with an applied transition.
    func lines(for met: [LifecycleCondition]) -> [String] {
        var out: [String] = []
        if met.contains(.startEvidence), let start { out.append("start: " + start.summary) }
        if met.contains(.deliveryEvidence) { out += delivery.lines.map { "delivery: " + $0 } }
        if met.contains(.acceptanceEvidence), let acceptance { out.append("acceptance: " + acceptance.text) }
        if met.contains(.regressionEvidence), let regression, case .bug(let id) = regression { out.append("regression: " + id) }
        if met.contains(.cancellationEvidence), let cancellation {
            switch cancellation {
            case .duplicate(let id): out.append("duplicate of " + id)
            case .invalid(let text): out.append("invalid: " + text)
            case .alreadyFixed(let text): out.append("already fixed: " + text)
            }
        }
        return out
    }
}

// MARK: - Request and decision

struct TransitionRequest: Sendable {
    /// Idempotency key: a request repeated with the same key returns its first outcome (REQ-005).
    var command: String
    var kind: IssueKind
    /// Feature slug or bug key ("BUG-012").
    var issue: String
    /// The status the requester saw. A different stored status makes the request stale.
    var from: String
    var to: String
    var actor: LifecycleActor
    var reason: String?
    /// The person's override. Honoured for a human only, and only with a reason.
    var force: Bool
    var evidence: LifecycleEvidence
    var at: Date
    /// When the facts behind an automatic request were observed; older than the latest applied change → stale.
    var observedAt: Date?

    init(command: String = UUID().uuidString, kind: IssueKind, issue: String, from: String, to: String, actor: LifecycleActor,
         reason: String? = nil, force: Bool = false, evidence: LifecycleEvidence = .none, at: Date = Date(), observedAt: Date? = nil) {
        self.command = command
        self.kind = kind
        self.issue = issue
        self.from = from
        self.to = to
        self.actor = actor
        self.reason = reason
        self.force = force
        self.evidence = evidence
        self.at = at
        self.observedAt = observedAt
    }

    var trimmedReason: String { (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct Rejection: Equatable, Codable, Sendable {
    var missing: [LifecycleCondition]
    var message: String
    var hints: [String]
}

struct TransitionBasis: Equatable, Sendable {
    var kind: TransitionKind
    /// Conditions that were required and met.
    var met: [LifecycleCondition]
}

enum TransitionDecision: Equatable, Sendable {
    case noChange
    case allowed(TransitionBasis)
    case overridden(TransitionBasis, bypassed: [LifecycleCondition])
    case rejected(Rejection)
}

// MARK: - Vocabulary helpers

enum LifecycleVocabulary {
    static func statuses(_ kind: IssueKind) -> [String] {
        kind == .feature ? FeatureVocabulary.featureStatuses : FeatureVocabulary.bugStatuses
    }

    /// Lower-case, hyphenated: " In Progress " → "in-progress".
    static func normalize(_ status: String) -> String { IssueStatus.normalize(status) }

    static func isKnown(_ kind: IssueKind, _ status: String) -> Bool { statuses(kind).contains(normalize(status)) }

    /// The specification stages of a feature, before implementation.
    static let specStages: Set<String> = ["idea", "exploring", "draft", "review", "resolving", "ready"]
    /// Stages an AI may set a feature to (the existing allow-list of the project tools).
    static let aiSpecStages: Set<String> = ["idea", "exploring", "draft", "review", "ready"]

    /// Implementation completed (and possibly accepted) by status alone; whether the evidence backs it is
    /// `IssueCompletion`'s question.
    static func isCompletedStatus(_ kind: IssueKind, _ status: String) -> Bool {
        let value = normalize(status)
        return kind == .feature ? ["implemented", "verified"].contains(value) : ["fixed", "closed"].contains(value)
    }

    /// Work that is under way.
    static func isActiveStatus(_ kind: IssueKind, _ status: String) -> Bool {
        let value = normalize(status)
        return kind == .feature ? value == "implementing" : value == "fixing"
    }
}

// MARK: - The table

struct LifecycleRule: Sendable {
    var from: Set<String>
    var to: String
    var kind: TransitionKind
    /// Conditions each actor kind must meet. An actor kind that is absent may not make this transition by the
    /// rules: a human can force it, the others cannot.
    var needs: [LifecycleActorKind: [LifecycleCondition]]
}

enum LifecyclePolicy {
    // MARK: Table

    static func rules(_ kind: IssueKind) -> [LifecycleRule] { kind == .feature ? featureRules : bugRules }

    private static let spec = LifecycleVocabulary.specStages
    private static let beforeStart: Set<String> = spec.subtracting(["idea"])

    private static let featureRules: [LifecycleRule] = {
        var rules: [LifecycleRule] = []
        // Between the specification stages: the existing flows (Explore, AI Review, the project tools) keep their freedom;
        // an AI keeps the stages the project tools always allowed it.
        for stage in spec {
            var needs: [LifecycleActorKind: [LifecycleCondition]] = [.human: [], .system: []]
            if LifecycleVocabulary.aiSpecStages.contains(stage) { needs[.ai] = [] }
            rules.append(LifecycleRule(from: spec.subtracting([stage]), to: stage, kind: .spec, needs: needs))
        }
        rules += [
            LifecycleRule(from: beforeStart, to: "implementing", kind: .start,
                          needs: [.human: [.startEvidence], .ai: [.startEvidence], .system: [.startEvidence]]),
            LifecycleRule(from: ["implementing"], to: "ready", kind: .rollback, needs: [.human: [.reason], .system: []]),
            LifecycleRule(from: beforeStart.union(["implementing"]), to: "implemented", kind: .completion,
                          needs: [.human: [.deliveryEvidence], .ai: [.deliveryEvidence], .system: [.deliveryEvidence]]),
            LifecycleRule(from: ["implemented"], to: "verified", kind: .acceptance,
                          needs: [.human: [], .ai: [.acceptanceEvidence]]),
            LifecycleRule(from: ["implemented", "verified"], to: "implementing", kind: .reopen,
                          needs: [.human: [.reason], .ai: [.regressionEvidence], .system: [.regressionEvidence]]),
            LifecycleRule(from: ["verified"], to: "implemented", kind: .reopen, needs: [.human: [.reason]]),
            LifecycleRule(from: spec.union(["implementing", "implemented", "verified"]), to: "archived", kind: .cancellation,
                          needs: [.human: [], .ai: []]),
            LifecycleRule(from: ["archived"], to: "draft", kind: .reopen, needs: [.human: [.reason]]),
            LifecycleRule(from: ["archived"], to: "ready", kind: .reopen, needs: [.human: [.reason]]),
        ]
        return rules
    }()

    private static let bugRules: [LifecycleRule] = [
        LifecycleRule(from: ["open"], to: "fixing", kind: .start,
                      needs: [.human: [.startEvidence], .ai: [.startEvidence], .system: [.startEvidence]]),
        LifecycleRule(from: ["fixing"], to: "open", kind: .rollback, needs: [.human: [], .ai: [], .system: []]),
        LifecycleRule(from: ["open", "fixing"], to: "fixed", kind: .completion,
                      needs: [.human: [.deliveryEvidence], .ai: [.deliveryEvidence], .system: [.deliveryEvidence]]),
        LifecycleRule(from: ["fixed"], to: "closed", kind: .acceptance, needs: [.human: [], .ai: [.acceptanceEvidence]]),
        LifecycleRule(from: ["open", "fixing"], to: "closed", kind: .cancellation,
                      needs: [.human: [.reason], .ai: [.cancellationEvidence], .system: [.cancellationEvidence]]),
        LifecycleRule(from: ["fixed", "closed"], to: "open", kind: .reopen,
                      needs: [.human: [.reason], .ai: [.regressionEvidence], .system: [.regressionEvidence]]),
    ]

    // MARK: Deciding

    /// The one decision function. A refusal changes nothing and says what is missing (REQ-001 criterion 3).
    static func decide(_ request: TransitionRequest) -> TransitionDecision {
        let kind = request.kind
        let from = LifecycleVocabulary.normalize(request.from)
        let to = LifecycleVocabulary.normalize(request.to)
        let vocabulary = LifecycleVocabulary.statuses(kind)

        guard vocabulary.contains(to) else {
            return .rejected(Rejection(missing: [], message: "\"\(request.to)\" is not a \(kind.rawValue) status.",
                                       hints: ["A \(kind.rawValue) status is one of: \(vocabulary.joined(separator: ", "))."]))
        }
        if request.force {
            if request.actor.kind != .human {
                return .rejected(Rejection(missing: [], message: "Only a person in the MarkView window can force a status.",
                                           hints: ["An AI or an automatic workflow follows the rules; ask the person to use the override in the Lifecycle section."]))
            }
            if request.trimmedReason.isEmpty {
                return .rejected(Rejection(missing: [.reason], message: "A forced status needs a reason.",
                                           hints: ["Write why the status is set without the evidence."]))
            }
        }
        if from == to { return .noChange }

        // A status outside the vocabulary (a hand-written "done" or "in-progress") is unknown state: only a person moves it.
        guard vocabulary.contains(from) else {
            return unlisted(request, bypassed: [.listedTransition],
                            message: "The current status \"\(request.from.isEmpty ? "(none)" : request.from)\" is not a \(kind.rawValue) status, so no rule applies.")
        }

        let candidates = rules(kind).filter { $0.to == to && $0.from.contains(from) }
        guard !candidates.isEmpty else {
            return unlisted(request, bypassed: [.listedTransition],
                            message: "\(kind.rawValue.capitalized) status \(from) → \(to) is not a lifecycle transition.")
        }

        // Several rules never overlap in the table; take the first that lets this actor in, else report on the first.
        let rule = candidates.first { $0.needs[request.actor.kind] != nil } ?? candidates[0]
        guard let required = rule.needs[request.actor.kind] else {
            return forcedOrRefused(request, rule: rule, unmet: [.listedTransition],
                                   message: "\(who(request.actor)) may not change \(from) → \(to) by the rules.",
                                   hints: actorHints(request.actor.kind, rule: rule))
        }

        var met: [LifecycleCondition] = []
        var unmet: [LifecycleCondition] = []
        for condition in required {
            if isMet(condition, request) { met.append(condition) } else { unmet.append(condition) }
        }
        if unmet.isEmpty {
            return .allowed(TransitionBasis(kind: outcomeKind(rule, request), met: met))
        }
        return forcedOrRefused(request, rule: rule, met: met, unmet: unmet,
                               message: "\(from) → \(to) needs " + unmet.map(\.title).joined(separator: " and ") + ".",
                               hints: unmetHints(unmet, request))
    }

    private static func forcedOrRefused(_ request: TransitionRequest, rule: LifecycleRule, met: [LifecycleCondition] = [],
                                        unmet: [LifecycleCondition], message: String, hints: [String]) -> TransitionDecision {
        if request.force {
            return .overridden(TransitionBasis(kind: rule.kind, met: met), bypassed: unmet)
        }
        return .rejected(Rejection(missing: unmet, message: message, hints: hints))
    }

    private static func unlisted(_ request: TransitionRequest, bypassed: [LifecycleCondition], message: String) -> TransitionDecision {
        if request.force { return .overridden(TransitionBasis(kind: .unlisted, met: []), bypassed: bypassed) }
        return .rejected(Rejection(missing: bypassed, message: message,
                                   hints: request.actor.kind == .human
                                       ? ["Use the override in the Lifecycle section and write a reason."]
                                       : ["Ask the person to change it in the MarkView window."]))
    }

    private static func who(_ actor: LifecycleActor) -> String {
        switch actor.kind {
        case .human: return "A person"
        case .ai: return "An AI session"
        case .system: return "MarkView"
        }
    }

    private static func actorHints(_ kind: LifecycleActorKind, rule: LifecycleRule) -> [String] {
        switch kind {
        case .human: return ["Use the override in the Lifecycle section and write a reason."]
        case .ai: return ["Ask the person; they can accept, reopen or force this in the MarkView window."]
        case .system: return ["This step is made by a person or an AI session."]
        }
    }

    private static func unmetHints(_ unmet: [LifecycleCondition], _ request: TransitionRequest) -> [String] {
        var hints: [String] = []
        for condition in unmet {
            switch condition {
            case .startEvidence:
                hints.append("Start it from MarkView (Implement with AI / Fix with AI) or attach the session with markview_attach_issue.")
            case .deliveryEvidence:
                let detail = request.evidence.delivery.lines.prefix(4).joined(separator: "; ")
                hints.append("Delivery evidence is \(request.evidence.delivery.label)" + (detail.isEmpty ? "." : ": \(detail)."))
            case .acceptanceEvidence:
                hints.append(request.kind == .feature
                             ? "Pass evidence (what was verified) and tick every acceptance criterion of the active requirements first."
                             : "Pass evidence: what was verified.")
            case .regressionEvidence:
                hints.append("File a bug report with regression_of: \(request.issue); an AI reopens only on that.")
            case .cancellationEvidence:
                hints.append("A bug is closed without a fix as a duplicate (duplicate_of) or with the validity check's evidence.")
            case .reason:
                hints.append("Write a reason.")
            case .listedTransition:
                break
            }
        }
        return hints
    }

    private static func isMet(_ condition: LifecycleCondition, _ request: TransitionRequest) -> Bool {
        let evidence = request.evidence
        switch condition {
        case .startEvidence: return evidence.start != nil
        case .deliveryEvidence: return evidence.delivery.isComplete
        case .acceptanceEvidence:
            guard let acceptance = evidence.acceptance else { return false }
            let text = acceptance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && (request.kind == .bug || acceptance.criteriaAllTicked)
        case .regressionEvidence: return evidence.regression != nil
        case .cancellationEvidence: return evidence.cancellation != nil
        case .reason: return !request.trimmedReason.isEmpty
        case .listedTransition: return true
        }
    }

    /// A close without a fix is a cancellation, whatever the finding (duplicate, invalid, withdrawn, already fixed on main): no
    /// merge, check or release backs it, so it is never verified completion (DEC-010, DEC-013); an archive after completion keeps
    /// the completion.
    private static func outcomeKind(_ rule: LifecycleRule, _ request: TransitionRequest) -> TransitionKind {
        if rule.to == "archived" {
            return LifecycleVocabulary.isCompletedStatus(.feature, request.from) ? .archive : .cancellation
        }
        return rule.kind
    }

    // MARK: What the next step needs (for the context an AI gets and for the Lifecycle section)

    struct NextStep: Equatable, Sendable {
        var to: String
        var kind: TransitionKind
        /// Needs of the asking actor; nil when that actor may not make the step by the rules.
        var needs: [LifecycleCondition]?
        /// Needs not met by the evidence at hand.
        var unmet: [LifecycleCondition]
    }

    static func nextSteps(kind: IssueKind, status: String, actor: LifecycleActorKind, evidence: LifecycleEvidence,
                          reason: String? = nil) -> [NextStep] {
        let from = LifecycleVocabulary.normalize(status)
        let probe = TransitionRequest(kind: kind, issue: "", from: from, to: "", actor: LifecycleActor(kind: actor, name: ""), reason: reason, evidence: evidence)
        return rules(kind).filter { $0.from.contains(from) }.map { rule in
            guard let needs = rule.needs[actor] else { return NextStep(to: rule.to, kind: rule.kind, needs: nil, unmet: []) }
            return NextStep(to: rule.to, kind: rule.kind, needs: needs, unmet: needs.filter { !isMet($0, probe) })
        }
    }
}
