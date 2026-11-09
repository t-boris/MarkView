import Foundation

// The software development workflow of one project (feature-3, REQ-001…006): the statuses of features and bugs with their
// lifecycle roles, the transitions between them and who may make each, and the rule variants that say how the start, delivery
// and acceptance conditions of those transitions are met. The workflow is data: the tables that used to be code in
// IssueLifecycle.swift are the `standard` workflow, and every consumer (the policy, completion, the reconciler, the GitHub
// sync, the filters, the agent tools) reads the project's workflow instead of fixed vocabularies. Foundation only (with
// FeatureVocabulary.swift and IssueLifecycle.swift), so tools/tests/project-workflow-tests.sh compiles it on its own.

// MARK: - Roles and statuses

// `LifecycleRole` (what a status means to the code that is not a transition table) lives in IssueListing.swift, with the filters that
// read it.

struct WorkflowStatus: Codable, Equatable, Identifiable, Sendable {
    /// The stored value in the Markdown front matter: lower-case words joined by hyphens.
    var id: String
    var title: String
    var role: LifecycleRole

    init(id: String, title: String? = nil, role: LifecycleRole) {
        self.id = id
        self.title = title ?? FeatureVocabulary.label(id)
        self.role = role
    }
}

// MARK: - Transition rules as data

/// An event after which MarkView makes the step of a rule by itself (feature assistants-confirm-delivery-with-evidence-and-propose-workflow,
/// REQ-004, DEC-006). The name is kept as written: a name this app does not know never fires and is reported by `validate()`, so a
/// workflow written by a newer app cannot make an older one move items wrongly.
struct RuleEvent: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// A hand-off to an agent was accepted, or a session attached itself to the item.
    static let workStarted = RuleEvent(rawValue: "work-started")
    /// The investigation of a bug by the app produced its result.
    static let investigationFinished = RuleEvent(rawValue: "investigation-finished")
    /// GitHub shows a pull request for the item that was not there before (needs the GitHub integration).
    static let pullRequestOpened = RuleEvent(rawValue: "pull-request-opened")
    /// GitHub shows that a pull request of the item has been merged (needs the GitHub integration).
    static let pullRequestMerged = RuleEvent(rawValue: "pull-request-merged")

    static let known: [RuleEvent] = [.workStarted, .investigationFinished, .pullRequestOpened, .pullRequestMerged]

    var isKnown: Bool { Self.known.contains(self) }

    /// For the editor and the diagram: "work is started".
    var title: String {
        switch self {
        case .workStarted: return "work is started"
        case .investigationFinished: return "an investigation finishes"
        case .pullRequestOpened: return "a pull request is opened"
        case .pullRequestMerged: return "a pull request is merged"
        default: return "\u{201C}\(rawValue)\u{201D} happens"
        }
    }

    /// What the event means, for the agent guide.
    var meaning: String {
        switch self {
        case .workStarted: return "A hand-off to an agent was accepted, or an agent session attached itself to the item."
        case .investigationFinished: return "The investigation of a bug report by MarkView produced its result (bugs only)."
        case .pullRequestOpened: return "GitHub shows a pull request of the item that was not seen before (needs the GitHub integration)."
        case .pullRequestMerged: return "GitHub shows that a pull request of the item has been merged (needs the GitHub integration)."
        default: return "Not known to this app: it never fires."
        }
    }
}

struct LifecycleRule: Codable, Equatable, Sendable {
    var from: Set<String>
    var to: String
    var kind: TransitionKind
    /// Conditions each actor kind must meet. An actor kind that is absent may not make this transition by the rules: a person can
    /// force it, the others cannot.
    var needs: [LifecycleActorKind: [LifecycleCondition]]
    /// The event after which MarkView makes this step itself, as the system actor under its conditions; nil = the step happens
    /// only when somebody asks for it. The rule must have a `system` entry (REQ-004).
    var event: RuleEvent?

    init(from: Set<String>, to: String, kind: TransitionKind, needs: [LifecycleActorKind: [LifecycleCondition]], event: RuleEvent? = nil) {
        self.from = from
        self.to = to
        self.kind = kind
        self.needs = needs
        self.event = event
    }

    /// A stable name for the editor and for messages: "draft+ready>implementing".
    var id: String { from.sorted().joined(separator: "+") + ">" + to }

    private enum CodingKeys: String, CodingKey { case from, to, kind, human, ai, system, event }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = Set(try container.decode([String].self, forKey: .from))
        to = try container.decode(String.self, forKey: .to)
        kind = try container.decode(TransitionKind.self, forKey: .kind)
        var needs: [LifecycleActorKind: [LifecycleCondition]] = [:]
        if let value = try container.decodeIfPresent([LifecycleCondition].self, forKey: .human) { needs[.human] = value }
        if let value = try container.decodeIfPresent([LifecycleCondition].self, forKey: .ai) { needs[.ai] = value }
        if let value = try container.decodeIfPresent([LifecycleCondition].self, forKey: .system) { needs[.system] = value }
        self.needs = needs
        event = try container.decodeIfPresent(RuleEvent.self, forKey: .event)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from.sorted(), forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(needs[.human], forKey: .human)
        try container.encodeIfPresent(needs[.ai], forKey: .ai)
        try container.encodeIfPresent(needs[.system], forKey: .system)
        try container.encodeIfPresent(event, forKey: .event)
    }
}

/// The statuses and transitions of one work-item type.
struct IssueLifecycleDefinition: Codable, Equatable, Sendable {
    var statuses: [WorkflowStatus]
    var rules: [LifecycleRule]

    var statusIDs: [String] { statuses.map(\.id) }

    func status(_ id: String) -> WorkflowStatus? {
        let value = IssueStatus.normalize(id)
        return statuses.first { $0.id == value }
    }

    func role(of id: String) -> LifecycleRole? { status(id)?.role }

    func isKnown(_ id: String) -> Bool { status(id) != nil }

    /// The status a new item of this type starts in: the first one.
    var initialStatus: String { statuses.first?.id ?? "" }

    func statuses(with role: LifecycleRole) -> [WorkflowStatus] { statuses.filter { $0.role == role } }

    /// The completed status that work in `status` reaches by itself once the delivery evidence is complete (feature
    /// implementing → implemented, bug fixing → fixed): the target of a completion rule the system may make from an active status.
    func completionTarget(from status: String) -> String? {
        let value = IssueStatus.normalize(status)
        guard role(of: value) == .active else { return nil }
        return rules.first { $0.kind == .completion && $0.from.contains(value) && $0.needs[.system] != nil }?.to
    }

    /// Where finished work goes from `status` when a person marks it done: the target of the first completion rule that starts there.
    func finishTarget(from status: String) -> String? {
        let value = IssueStatus.normalize(status)
        return rules.first { $0.kind == .completion && $0.from.contains(value) }?.to
    }
}

// MARK: - Rule variants

/// How the work of an item reaches the default branch (DEC-025).
enum IntegrationPath: String, Codable, CaseIterable, Sendable {
    /// A commit made straight on the default branch counts, and so does a pull request.
    case directToMain = "direct"
    /// Every unit of work must be a pull request that GitHub confirms merged (presence and merge).
    case pullRequest = "pull-request"

    var title: String { self == .directToMain ? "Direct to the default branch" : "Pull request" }
}

enum StartEvidenceMode: String, Codable, CaseIterable, Sendable {
    /// The issue was handed to an agent, or a session attached itself (the standard).
    case agentSession = "agent"
    /// Or a person's note says that manual work has started (REQ-004).
    case agentOrNote = "agent-or-note"

    var title: String { self == .agentSession ? "An agent session" : "An agent session or a person's note" }
}

enum AcceptanceMode: String, Codable, CaseIterable, Sendable {
    /// An AI may accept with its evidence text and every acceptance criterion ticked (DEC-008); a person always may.
    case aiWithEvidence = "ai-with-evidence"
    case humanOnly = "human-only"

    var title: String { self == .aiWithEvidence ? "A person, or an AI with evidence" : "A person only" }
}

/// Which event counts as delivery (Q-002, DEC-018).
enum DeliveryEvent: Codable, Equatable, Sendable {
    case none
    /// A published GitHub release that contains the merged work, verified automatically.
    case githubRelease
    /// An event outside GitHub that a person confirms ("deployed to production", "installed").
    case humanConfirmed(name: String)

    /// Whether the event is one that somebody confirms, not one MarkView reads from GitHub.
    var isConfirmedBySomeone: Bool {
        if case .humanConfirmed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .none: return "No delivery event"
        case .githubRelease: return "A published GitHub release"
        case .humanConfirmed(let name): return "A person confirms: \(name)"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "none": self = .none
        case "github-release": self = .githubRelease
        case "human-confirmed":
            let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            self = .humanConfirmed(name: name)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown delivery event \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try container.encode("none", forKey: .type)
        case .githubRelease: try container.encode("github-release", forKey: .type)
        case .humanConfirmed(let name):
            try container.encode("human-confirmed", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Who may confirm the delivery event of a process when that event is not a GitHub release (DEC-004 of the feature
/// assistants-confirm-delivery-with-evidence-and-propose-workflow). Absent in a file = a person only.
enum DeliveryConfirmer: String, Codable, CaseIterable, Sendable {
    case person
    case personOrAI = "person-or-ai"

    var title: String { self == .person ? "A person only" : "A person, or an AI with evidence" }
}

/// Whether someone may confirm the delivery event of a process now, and if not, why (feature assistants-confirm-delivery-with-evidence-
/// and-propose-workflow, REQ-001). Pure, so that the refusals are checked without the app.
enum DeliveryConfirmationPolicy {
    /// The reason a confirmation is refused, written for whoever asked; nil when it may be recorded.
    static func refusal(issue: String, actor: LifecycleActor, process: RuleVariant?, status: String, role: LifecycleRole?, note: String) -> String? {
        guard let process, let event = process.deliveryRules.confirmedEventName else {
            return "The process of \(issue) has no delivery event that somebody confirms, so there is nothing to confirm."
        }
        guard actor.kind == .human || actor.kind == .ai else { return "Only a person or an AI confirms a delivery event." }
        if actor.kind == .ai, process.confirmer == .person {
            return "The process \u{201C}\(process.name)\u{201D} lets only a person confirm \u{201C}\(event)\u{201D}. Ask the person to confirm it in the "
                + "Lifecycle section of \(issue) in the MarkView window, or to set \u{201C}Who confirms\u{201D} of the process to a person or an AI with evidence "
                + "(Workflow, Processes)."
        }
        guard role == .active || role == .completed else {
            return "\(issue) is in \(status), where the work has not started. \u{201C}\(event)\u{201D} can be confirmed once the work is under way."
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Write what was verified and how: the evidence text is required."
        }
        return nil
    }
}

/// The delivery conditions of a variant: what the collector and the evaluator read (DEC-027).
struct DeliveryRules: Equatable, Sendable {
    var integration: IntegrationPath
    var checksRequired: Bool
    var event: DeliveryEvent
    /// Who may confirm `event` when it is confirmed by someone.
    var confirmedBy: DeliveryConfirmer = .person

    var pullRequestRequired: Bool { integration == .pullRequest }
    var githubReleaseRequired: Bool { event == .githubRelease }
    /// The name of the event a person must confirm; nil when delivery needs no confirmation.
    var confirmedEventName: String? {
        if case .humanConfirmed(let name) = event { return name }
        return nil
    }
    /// Whether GitHub must be readable for these rules to be judged.
    var needsGitHub: Bool { pullRequestRequired || checksRequired || githubReleaseRequired }
}

/// One process of the project for one work-item type: the development and delivery conditions (DEC-019, DEC-025, DEC-027) and,
/// when the process has them, its own transitions (BUG-108). The statuses and their roles belong to the type and are shared by
/// all its processes, so every list, filter and sync keeps reading one vocabulary; a process decides which steps between those
/// statuses exist and what each needs. A process without `rules` follows the transitions of its type.
struct RuleVariant: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: IssueKind
    var start: StartEvidenceMode
    var integration: IntegrationPath
    var checks: Bool
    var delivery: DeliveryEvent
    /// Who may confirm a delivery event that is confirmed by someone; nil = a person only (the reading of every older file).
    var confirmedBy: DeliveryConfirmer?
    var acceptance: AcceptanceMode
    var summary: String
    /// The transitions of this process; nil = those of its type.
    var rules: [LifecycleRule]?

    init(id: String, name: String, kind: IssueKind, start: StartEvidenceMode = .agentSession, integration: IntegrationPath,
         checks: Bool, delivery: DeliveryEvent = .none, confirmedBy: DeliveryConfirmer? = nil, acceptance: AcceptanceMode = .aiWithEvidence,
         summary: String = "", rules: [LifecycleRule]? = nil) {
        self.rules = rules
        self.id = id
        self.name = name
        self.kind = kind
        self.start = start
        self.integration = integration
        self.checks = checks
        self.delivery = delivery
        self.confirmedBy = confirmedBy
        self.acceptance = acceptance
        self.summary = summary
    }

    /// Who may confirm the delivery event; a person unless the file says otherwise. Setting a person clears the field, so a file
    /// that never needed it stays as it was.
    var confirmer: DeliveryConfirmer {
        get { confirmedBy ?? .person }
        set { confirmedBy = newValue == .person ? nil : newValue }
    }

    var deliveryRules: DeliveryRules {
        DeliveryRules(integration: integration, checksRequired: checks, event: delivery, confirmedBy: confirmer)
    }

    /// One line for the editor, the history and the agent context.
    var description: String {
        var parts = [integration.title, checks ? "checks required" : "no checks", delivery.title.lowercased()]
        if delivery.isConfirmedBySomeone, confirmer == .personOrAI { parts.append("confirmed by a person or an AI with evidence") }
        parts.append("start: " + (start == .agentSession ? "agent session" : "agent session or note"))
        parts.append("accepted by: " + (acceptance == .humanOnly ? "a person" : "a person or an AI with evidence"))
        if let rules { parts.append("its own \(rules.count) transition\(rules.count == 1 ? "" : "s")") }
        return parts.joined(separator: "; ")
    }
}

enum VariantTemplate: String, CaseIterable, Sendable {
    case pullRequestWithChecks = "pull-request-with-checks"
    case pullRequestChecksRelease = "pull-request-checks-release"
    case directToMain = "direct-to-main"
    case manualWork = "manual-work"

    var title: String {
        switch self {
        case .pullRequestWithChecks: return "Pull request with checks"
        case .pullRequestChecksRelease: return "Pull request, checks and a GitHub release"
        case .directToMain: return "Direct to the default branch"
        case .manualWork: return "Manual work, accepted by a person"
        }
    }

    func variant(kind: IssueKind, id: String) -> RuleVariant {
        switch self {
        case .pullRequestWithChecks:
            return RuleVariant(id: id, name: title, kind: kind, integration: .pullRequest, checks: true,
                               summary: "Every change goes through a merged pull request with passing checks.")
        case .pullRequestChecksRelease:
            return RuleVariant(id: id, name: title, kind: kind, integration: .pullRequest, checks: true, delivery: .githubRelease,
                               summary: "A merged pull request with passing checks, and the work is in a published release.")
        case .directToMain:
            return RuleVariant(id: id, name: title, kind: kind, start: .agentOrNote, integration: .directToMain, checks: false,
                               summary: "Changes are committed straight to the default branch; nothing else is required.")
        case .manualWork:
            return RuleVariant(id: id, name: title, kind: kind, start: .agentOrNote, integration: .directToMain, checks: false,
                               acceptance: .humanOnly, summary: "Work done by hand: a person's note starts it and a person accepts it.")
        }
    }
}

// MARK: - Process templates

/// The general templates a project starts a process of its own from (BUG-108): a process is a rule variant with its own
/// transitions. A template is only a starting point: the project keeps its own copy and changes it freely, so editing the project's
/// process never touches the template, and the Settings window holds nothing but these templates.
enum ProcessTemplate: String, CaseIterable, Identifiable, Sendable {
    case quickFeature = "quick-feature"
    case standardTransitions = "standard-transitions"
    case fromScratch = "from-scratch"

    var id: String { rawValue }

    /// The id the Quick Feature intake looks for: a project that has a process with it gives its quick features that process.
    static let quickFeatureID = "quick-feature"

    var title: String {
        switch self {
        case .quickFeature: return "Quick feature"
        case .standardTransitions: return "Copy of the standard transitions"
        case .fromScratch: return "From scratch"
        }
    }

    var summary: String {
        switch self {
        case .quickFeature:
            return "A small feature without the specification stages: it goes to Ready, is implemented straight on the default branch and is accepted by a person or an AI with evidence."
        case .standardTransitions:
            return "The transitions of the type as they are now, with the delivery rules of its default process, to change one step at a time."
        case .fromScratch:
            return "Only a start and a completion, the least a process needs; every other step is added by hand."
        }
    }

    /// Quick feature is a way to work on a feature; the others suit both types.
    func applies(to kind: IssueKind) -> Bool { self != .quickFeature || kind == .feature }

    /// A new process of `kind` made from this template, on top of the statuses the project's type has now.
    func variant(kind: IssueKind, id: String, in workflow: ProjectWorkflow) -> RuleVariant {
        let definition = workflow.lifecycle(kind)
        switch self {
        case .quickFeature:
            return RuleVariant(id: id, name: title, kind: kind, start: .agentOrNote, integration: .directToMain, checks: false,
                               summary: "A small feature: no specification stages, committed straight to the default branch.",
                               rules: Self.transitions(definition, quick: true))
        case .standardTransitions:
            let base = workflow.resolvedVariant(kind, assigned: nil)
            return RuleVariant(id: id, name: "Copy of " + (base?.name ?? "standard"), kind: kind, start: base?.start ?? .agentSession,
                               integration: base?.integration ?? .directToMain, checks: base?.checks ?? false,
                               delivery: base?.delivery ?? .none, acceptance: base?.acceptance ?? .aiWithEvidence,
                               summary: "Starts as a copy of the standard transitions; change what differs.",
                               rules: definition.rules)
        case .fromScratch:
            return RuleVariant(id: id, name: "New process", kind: kind, integration: .directToMain, checks: false,
                               summary: "A process built from nothing: add the steps it needs.",
                               rules: Self.transitions(definition, quick: false))
        }
    }

    /// Transitions built from the roles of the type's statuses, so they fit a project that renamed or added statuses: a start from
    /// every not-started status, a completion that needs delivery evidence, and, for a quick feature, the rest of a short path.
    static func transitions(_ definition: IssueLifecycleDefinition, quick: Bool) -> [LifecycleRule] {
        let waiting = definition.statuses(with: .notStarted).map(\.id)
        let completed = definition.statuses(with: .completed).map(\.id)
        guard let active = definition.statuses(with: .active).first?.id, let done = completed.first, !waiting.isEmpty else { return [] }
        let everyone: [LifecycleActorKind: [LifecycleCondition]] = [.human: [.startEvidence], .ai: [.startEvidence], .system: [.startEvidence]]
        var rules: [LifecycleRule] = []
        // A quick feature skips the specification: any not-started status goes straight to the last one (Ready).
        if quick, let ready = waiting.last, waiting.count > 1 {
            rules.append(LifecycleRule(from: Set(waiting).subtracting([ready]), to: ready, kind: .spec, needs: [.human: [], .ai: [], .system: []]))
        }
        rules.append(LifecycleRule(from: Set(waiting), to: active, kind: .start, needs: everyone))
        if quick, let ready = waiting.last {
            rules.append(LifecycleRule(from: [active], to: ready, kind: .rollback, needs: [.human: [.reason], .system: []]))
        }
        rules.append(LifecycleRule(from: Set(waiting).union([active]), to: done, kind: .completion,
                                   needs: [.human: [.deliveryEvidence], .ai: [.deliveryEvidence], .system: [.deliveryEvidence]]))
        if quick {
            if completed.count > 1 {
                rules.append(LifecycleRule(from: [done], to: completed[1], kind: .acceptance, needs: [.human: [], .ai: [.acceptanceEvidence]]))
            }
            rules.append(LifecycleRule(from: Set(completed), to: active, kind: .reopen,
                                       needs: [.human: [.reason], .ai: [.regressionEvidence], .system: [.regressionEvidence]]))
            if let cancelled = definition.statuses(with: .cancelled).first?.id {
                let open = Set(definition.statusIDs).subtracting([cancelled])
                rules.append(LifecycleRule(from: open, to: cancelled, kind: .cancellation, needs: [.human: [], .ai: []]))
                if let ready = waiting.last {
                    rules.append(LifecycleRule(from: [cancelled], to: ready, kind: .reopen, needs: [.human: [.reason]]))
                }
            }
        }
        return rules
    }
}

// MARK: - The workflow

struct ProjectWorkflow: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schema: Int
    /// Raised by every saved change; transition records name it, so an old decision can be explained.
    var revision: Int
    var name: String
    var feature: IssueLifecycleDefinition
    var bug: IssueLifecycleDefinition
    var variants: [RuleVariant]
    var defaultFeatureVariant: String
    var defaultBugVariant: String

    func lifecycle(_ kind: IssueKind) -> IssueLifecycleDefinition { kind == .feature ? feature : bug }

    /// The statuses of a type with the transitions of the process an item follows: the process's own when it has them, else the
    /// type's. `assigned` is the item's variant id (nil = the default of its type).
    func lifecycle(_ kind: IssueKind, variant assigned: String?) -> IssueLifecycleDefinition {
        var definition = lifecycle(kind)
        if let own = resolvedVariant(kind, assigned: assigned)?.rules { definition.rules = own }
        return definition
    }

    mutating func setLifecycle(_ kind: IssueKind, _ definition: IssueLifecycleDefinition) {
        if kind == .feature { feature = definition } else { bug = definition }
    }

    func variants(for kind: IssueKind) -> [RuleVariant] { variants.filter { $0.kind == kind } }

    func variant(_ id: String?) -> RuleVariant? {
        guard let id else { return nil }
        return variants.first { $0.id == id }
    }

    func defaultVariantID(_ kind: IssueKind) -> String { kind == .feature ? defaultFeatureVariant : defaultBugVariant }

    /// The variant of an item: its assignment when that still exists for its type, else the default of the type.
    func resolvedVariant(_ kind: IssueKind, assigned: String?) -> RuleVariant? {
        if let found = variant(assigned), found.kind == kind { return found }
        return variant(defaultVariantID(kind)) ?? variants(for: kind).first
    }

    // MARK: Roles

    func role(_ kind: IssueKind, _ status: String) -> LifecycleRole? { lifecycle(kind).role(of: status) }

    func isCompleted(_ kind: IssueKind, _ status: String) -> Bool { role(kind, status) == .completed }

    func isActive(_ kind: IssueKind, _ status: String) -> Bool { role(kind, status) == .active }

    /// Completed or cancelled: the work is over (a feature archived, a bug closed).
    func isFinished(_ kind: IssueKind, _ status: String) -> Bool { role(kind, status)?.isFinished == true }
}

// MARK: - The standard workflow

/// What every project starts with: the statuses, transitions, conditions and delivery rules that were code before this feature
/// (DEC-016, DEC-017). Checks in `tools/tests/ProjectWorkflowChecks.swift` hold it equal to the old tables.
enum StandardWorkflow {
    static let featureVariantID = "standard-feature"
    static let bugVariantID = "standard-bug"

    /// What the bug variant takes from the project at adoption (DEC-022): the pull request, checks and release requirements the
    /// Definition of Done and the guide expressed until then. The feature variant never required them (DEC-007 as implemented).
    struct BugDelivery: Equatable, Sendable {
        var pullRequestRequired: Bool
        var checksRequired: Bool
        var releaseRequired: Bool

        /// A project without a Definition of Done: pull request and checks required, no release.
        static let defaults = BugDelivery(pullRequestRequired: true, checksRequired: true, releaseRequired: false)
    }

    static let value = make(bug: .defaults)

    static func make(bug delivery: BugDelivery) -> ProjectWorkflow {
        let feature = IssueLifecycleDefinition(
            statuses: FeatureVocabulary.featureStatuses.map { WorkflowStatus(id: $0, role: featureRole($0)) },
            rules: featureRules)
        let bug = IssueLifecycleDefinition(
            statuses: FeatureVocabulary.bugStatuses.map { WorkflowStatus(id: $0, role: bugRole($0)) },
            rules: bugRules)
        let variants = [
            RuleVariant(id: featureVariantID, name: "Standard feature", kind: .feature, integration: .directToMain, checks: false,
                        summary: "How features were completed before workflows: the associated code is on the default branch."),
            RuleVariant(id: bugVariantID, name: "Standard bug", kind: .bug, integration: delivery.pullRequestRequired ? .pullRequest : .directToMain,
                        checks: delivery.checksRequired, delivery: delivery.releaseRequired ? .githubRelease : .none,
                        summary: "How bugs were completed before workflows, as the Definition of Done and the guide set it when the workflow was adopted."),
        ]
        return ProjectWorkflow(schema: ProjectWorkflow.currentSchema, revision: 1, name: "MarkView standard", feature: feature, bug: bug,
                               variants: variants, defaultFeatureVariant: featureVariantID, defaultBugVariant: bugVariantID)
    }

    private static func featureRole(_ id: String) -> LifecycleRole {
        switch id {
        case "implementing": return .active
        case "implemented", "verified": return .completed
        case "archived": return .cancelled
        default: return .notStarted
        }
    }

    private static func bugRole(_ id: String) -> LifecycleRole {
        switch id {
        case "fixing": return .active
        case "fixed", "closed": return .completed
        default: return .notStarted
        }
    }

    /// The specification stages of a feature, before implementation.
    static let specStages: Set<String> = ["idea", "exploring", "draft", "review", "resolving", "ready"]
    /// Stages an AI may set a feature to (the allow-list of the project tools).
    static let aiSpecStages: Set<String> = ["idea", "exploring", "draft", "review", "ready"]

    private static let beforeStart: Set<String> = specStages.subtracting(["idea"])

    private static let featureRules: [LifecycleRule] = {
        var rules: [LifecycleRule] = []
        // Between the specification stages: the existing flows (Explore, AI Review, the project tools) keep their freedom;
        // an AI keeps the stages the project tools always allowed it.
        for stage in specStages.sorted() {
            var needs: [LifecycleActorKind: [LifecycleCondition]] = [.human: [], .system: []]
            if aiSpecStages.contains(stage) { needs[.ai] = [] }
            rules.append(LifecycleRule(from: specStages.subtracting([stage]), to: stage, kind: .spec, needs: needs))
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
            LifecycleRule(from: specStages.union(["implementing", "implemented", "verified"]), to: "archived", kind: .cancellation,
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
}

extension ProjectWorkflow {
    static let standard = StandardWorkflow.value
}

// MARK: - Validation

/// Something that makes a workflow unusable or unsafe to save. A problem has a plain-language message for the editor.
struct WorkflowProblem: Equatable, Sendable {
    var message: String
}

extension ProjectWorkflow {
    func validate() -> [WorkflowProblem] {
        var problems: [WorkflowProblem] = []
        func add(_ text: String) { problems.append(WorkflowProblem(message: text)) }

        if schema != Self.currentSchema { add("The workflow schema \(schema) is not supported (this app reads \(Self.currentSchema)).") }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("The workflow needs a name.") }

        for kind in [IssueKind.feature, .bug] {
            let label = kind.rawValue
            let definition = lifecycle(kind)
            let ids = definition.statusIDs
            if ids.isEmpty { add("The \(label) lifecycle has no statuses."); continue }
            for status in definition.statuses {
                if status.id.isEmpty || status.id != IssueStatus.normalize(status.id)
                    || status.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
                    add("The \(label) status \"\(status.id)\" must be lower-case words joined by hyphens.")
                }
                if status.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("The \(label) status \(status.id) needs a title.") }
            }
            if Set(ids).count != ids.count { add("The \(label) statuses must have different ids.") }
            for role in [LifecycleRole.notStarted, .active, .completed] where definition.statuses(with: role).isEmpty {
                add("The \(label) lifecycle needs a status with the role \"\(role.title)\".")
            }
            Self.validateTransitions(definition, label: label, kind: label, add: add)
        }

        let variantIDs = variants.map(\.id)
        if Set(variantIDs).count != variantIDs.count { add("The rule variants must have different ids.") }
        for variant in variants {
            if variant.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == nil {
                add("The rule variant id \"\(variant.id)\" must be lower-case words joined by hyphens.")
            }
            if variant.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("The rule variant \(variant.id) needs a name.") }
            if case .humanConfirmed(let event) = variant.delivery, event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("The rule variant \(variant.name) needs the name of the delivery event a person confirms.")
            }
            // A process with its own transitions is judged like a type: its steps use the statuses of its type.
            if let own = variant.rules {
                var definition = lifecycle(variant.kind)
                definition.rules = own
                Self.validateTransitions(definition, label: "\u{201C}\(variant.name)\u{201D} process", kind: variant.kind.rawValue, add: add)
            }
        }
        for kind in [IssueKind.feature, .bug] {
            let chosen = variant(defaultVariantID(kind))
            if variants(for: kind).isEmpty { add("There must be at least one \(kind.rawValue) rule variant.") }
            else if chosen == nil || chosen?.kind != kind { add("The default \(kind.rawValue) rule variant must be one of the \(kind.rawValue) rule variants.") }
        }
        return problems
    }

    /// The checks of one transition table: of a type, or of a process that has its own. `label` names the table in the messages and
    /// `kind` the type whose statuses the transitions use.
    private static func validateTransitions(_ definition: IssueLifecycleDefinition, label: String, kind: String, add: (String) -> Void) {
        var seen = Set<String>()
        for rule in definition.rules {
            if rule.from.isEmpty { add("A \(label) transition to \(rule.to) has no source status.") }
            for from in rule.from where !definition.isKnown(from) { add("A \(label) transition starts at \(from), which is not a \(kind) status.") }
            if !definition.isKnown(rule.to) { add("A \(label) transition ends at \(rule.to), which is not a \(kind) status.") }
            if rule.from.contains(rule.to) { add("A \(label) transition from \(rule.to) to itself changes nothing.") }
            if let event = rule.event {
                if !event.isKnown {
                    add("The \(label) transition \(rule.id) names the event \u{201C}\(event.rawValue)\u{201D}, which this app does not know (known: \(RuleEvent.known.map(\.rawValue).joined(separator: ", "))).")
                }
                if rule.needs[.system] == nil {
                    add("The \(label) transition \(rule.id) happens on an event but does not let MarkView make the step: give it a system entry.")
                }
                if event == .investigationFinished, kind != IssueKind.bug.rawValue {
                    add("The event \u{201C}\(event.rawValue)\u{201D} exists only for bugs, so the \(label) transition \(rule.id) cannot use it.")
                }
            }
            if !seen.insert(rule.id).inserted { add("The \(label) transition \(rule.id) is listed twice.") }
            if rule.kind == .start, definition.role(of: rule.to) != .active {
                add("The \(label) start transition to \(rule.to) must end in a status with the role \"Active\".")
            }
            if rule.kind == .completion, definition.role(of: rule.to) != .completed {
                add("The \(label) completion transition to \(rule.to) must end in a status with the role \"Completed\".")
            }
            if rule.kind == .completion, rule.from.contains(where: { definition.role(of: $0) == .completed }) {
                add("The \(label) completion transition to \(rule.to) cannot start in a completed status.")
            }
            // A role alone never confirms delivery (DEC-023): whoever may complete the work needs delivery evidence for it.
            if rule.kind == .completion {
                for (actor, conditions) in rule.needs where !conditions.contains(.deliveryEvidence) {
                    add("The \(label) completion transition to \(rule.to) must require delivery evidence from \(actor.rawValue == "ai" ? "AI" : actor.rawValue).")
                }
            }
        }
        if !definition.rules.contains(where: { $0.kind == .start }) { add("The \(label) lifecycle needs a start transition.") }
        if !definition.rules.contains(where: { $0.kind == .completion }) { add("The \(label) lifecycle needs a completion transition.") }
        if !definition.rules.contains(where: { $0.kind == .completion && $0.needs[.system] != nil && !$0.from.filter { definition.role(of: $0) == .active }.isEmpty }) {
            add("The \(label) completion from an active status must be open to MarkView, so finished work is recorded as soon as its evidence is complete.")
        }
    }
}

// MARK: - Editing

extension ProjectWorkflow {
    /// Removes a status of a type with the transitions that ended there or started only there, in the table of the type and in the
    /// own tables of its processes. Returns how many transitions went with it.
    @discardableResult
    mutating func removeStatus(_ id: String, kind: IssueKind) -> Int {
        func without(_ rules: [LifecycleRule]) -> [LifecycleRule] {
            rules.compactMap { rule in
                guard rule.to != id else { return nil }
                var rule = rule
                rule.from.remove(id)
                return rule.from.isEmpty ? nil : rule
            }
        }
        var current = lifecycle(kind)
        var dropped = current.rules.count
        current.statuses.removeAll { $0.id == id }
        current.rules = without(current.rules)
        dropped -= current.rules.count
        setLifecycle(kind, current)
        for index in variants.indices where variants[index].kind == kind {
            guard let own = variants[index].rules else { continue }
            let kept = without(own)
            dropped += own.count - kept.count
            variants[index].rules = kept
        }
        return dropped
    }

    /// `base`, or `base-2`, `base-3`… when a process already has that id.
    func freshVariantID(_ base: String) -> String {
        var id = base
        var suffix = 2
        while variant(id) != nil { id = base + "-\(suffix)"; suffix += 1 }
        return id
    }
}

// MARK: - Changes and their impact

/// An item the editor and the store ask about: where it stands in the workflow.
struct WorkflowItem: Equatable, Sendable {
    var kind: IssueKind
    var issue: String
    var status: String
    var variant: String?
}

/// What saving a changed workflow would remove from under work items (Q-009, DEC-021).
struct WorkflowImpact: Equatable, Sendable {
    /// Statuses that the old workflow had, the new one lacks and some item has, with the items.
    var statuses: [IssueKind: [String: [String]]] = [:]
    /// Variants that the old workflow had, the new one lacks and some item uses, with the items.
    var variants: [String: [String]] = [:]

    var isEmpty: Bool { statuses.values.allSatisfy(\.isEmpty) && variants.isEmpty }
}

/// What a save of the workflow still owes the work items it takes a status or a variant away from (DEC-021). It is written before the
/// workflow file and removed when every item is moved, so a save that was interrupted, or an item that could not be moved, is
/// finished at the next start. `revision` is the workflow revision the save produces: a plan whose revision the file never reached
/// belongs to a save that did not happen and is dropped.
struct PendingReplacements: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var kind: IssueKind
        var issue: String
        var from: String
        var to: String
    }

    var revision: Int
    /// The person who chose the replacements; the moves are made in their name.
    var actor: String
    var statuses: [Entry] = []
    var variants: [Entry] = []

    var isEmpty: Bool { statuses.isEmpty && variants.isEmpty }
}

enum WorkflowChange {
    /// The moves a person's replacements ask for: one entry per affected item.
    static func plan(of impact: WorkflowImpact, old: ProjectWorkflow, revision: Int, actor: String,
                     statusReplacements: [IssueKind: [String: String]], variantReplacements: [String: String]) -> PendingReplacements {
        var plan = PendingReplacements(revision: revision, actor: actor)
        for (kind, removed) in impact.statuses.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for (status, issues) in removed.sorted(by: { $0.key < $1.key }) {
                guard let replacement = statusReplacements[kind]?[status] else { continue }
                plan.statuses += issues.map { PendingReplacements.Entry(kind: kind, issue: $0, from: status, to: replacement) }
            }
        }
        for (variant, issues) in impact.variants.sorted(by: { $0.key < $1.key }) {
            guard let kind = old.variant(variant)?.kind, let replacement = variantReplacements[variant] else { continue }
            plan.variants += issues.map { PendingReplacements.Entry(kind: kind, issue: $0, from: variant, to: replacement) }
        }
        return plan
    }

    /// The statuses and variants a change removes that work items still use. `assignments` maps an item (`kind:issue`) to the id of
    /// its assigned variant, when it has one.
    static func impact(from old: ProjectWorkflow, to new: ProjectWorkflow, items: [WorkflowItem]) -> WorkflowImpact {
        var impact = WorkflowImpact()
        for item in items {
            let status = IssueStatus.normalize(item.status)
            if old.lifecycle(item.kind).isKnown(status), !new.lifecycle(item.kind).isKnown(status) {
                impact.statuses[item.kind, default: [:]][status, default: []].append(item.issue)
            }
            let assigned = old.resolvedVariant(item.kind, assigned: item.variant)?.id
            if let assigned, new.variant(assigned) == nil {
                impact.variants[assigned, default: []].append(item.issue)
            }
        }
        return impact
    }

    /// Why a set of replacements does not cover an impact; empty when it does. A replacement for a status must be a status of the new
    /// workflow, for a variant a variant of the same type.
    static func problems(of impact: WorkflowImpact, in new: ProjectWorkflow, statusReplacements: [IssueKind: [String: String]],
                         variantReplacements: [String: String], old: ProjectWorkflow) -> [WorkflowProblem] {
        var out: [WorkflowProblem] = []
        for (kind, removed) in impact.statuses {
            for (status, issues) in removed {
                guard let replacement = statusReplacements[kind]?[status], new.lifecycle(kind).isKnown(replacement) else {
                    out.append(WorkflowProblem(message: "Choose a \(kind.rawValue) status to replace \"\(status)\", used by \(issues.count) item\(issues.count == 1 ? "" : "s")."))
                    continue
                }
            }
        }
        for (variant, issues) in impact.variants {
            let kind = old.variant(variant)?.kind
            guard let replacement = variantReplacements[variant], let found = new.variant(replacement), found.kind == kind else {
                out.append(WorkflowProblem(message: "Choose a rule variant to replace \"\(variant)\", used by \(issues.count) item\(issues.count == 1 ? "" : "s")."))
                continue
            }
        }
        return out
    }
}
