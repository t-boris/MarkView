import Foundation

// The classic flows a project can choose on the Workflow tab (feature workflow-flows, REQ-003). A flow is data in the workflow
// format that already exists: the statuses of features and bugs with their roles, and the transitions built from those roles. It
// adds nothing to workflow.json, so every flow is also reachable by editing the file, and choosing one only changes the draft.
//
// Every board a team knows (Jira and Trello Kanban, Scrum, Linear, GitHub Projects, Azure DevOps, Shape Up, Bugzilla) reduces to the
// same four things, which are the four roles: states where the work waits, states where it is being done, states where it is over,
// and a state for dropped work. "In review" is work being done; "Ready" and "Selected for sprint" are work waiting; Azure's
// "Resolved" is completed (the delivery), "Closed" the acceptance after it. Foundation only (with FeatureVocabulary.swift,
// IssueListing.swift, ProjectWorkflow.swift and IssueLifecycle.swift), so tools/tests/workflow-flow-tests.sh compiles it alone.

struct WorkflowFlow: Identifiable, Equatable, Sendable {
    let id: String
    /// The menu entry; also the name of the workflow it makes.
    let title: String
    /// Where the flow comes from, so a person can recognise it.
    let origin: String
    /// What the flow is for, one sentence.
    let summary: String
    let feature: IssueLifecycleDefinition
    let bug: IssueLifecycleDefinition

    func lifecycle(_ kind: IssueKind) -> IssueLifecycleDefinition { kind == .feature ? feature : bug }

    /// `draft` with this flow's statuses and transitions, keeping what is the project's own: the name changes, the revision does not
    /// (a save still notices that the file moved on). A process that follows the transitions of its type keeps its settings (branch,
    /// checks, release, acceptance); one with transitions of its own is left out, because they name the statuses of the old flow.
    /// A type left without a process, or without its default one, takes it from `fallback`. Saving shows what this takes away from
    /// the work items (DEC-021).
    func applied(to draft: ProjectWorkflow, fallback: ProjectWorkflow = .standard) -> ProjectWorkflow {
        var result = draft
        result.name = title
        result.feature = feature
        result.bug = bug
        result.variants = draft.variants.filter { $0.rules == nil }
        for kind in [IssueKind.feature, .bug] where result.variants(for: kind).isEmpty {
            result.variants += fallback.variants(for: kind)
        }
        if result.variant(result.defaultFeatureVariant)?.kind != .feature {
            result.defaultFeatureVariant = result.variants(for: .feature).first?.id ?? result.defaultFeatureVariant
        }
        if result.variant(result.defaultBugVariant)?.kind != .bug {
            result.defaultBugVariant = result.variants(for: .bug).first?.id ?? result.defaultBugVariant
        }
        return result
    }

    /// The states of a type from the first to the last, grouped by what they mean: "Backlog, Ready → In progress, In review → Done
    /// (dropped: Won't do)". It is what the picker shows, so a person sees the columns before choosing.
    func outline(_ kind: IssueKind) -> String { Self.outline(lifecycle(kind)) }

    /// The same for any lifecycle (a saved template's, too).
    static func outline(_ definition: IssueLifecycleDefinition) -> String {
        let statuses = definition.statuses
        func titles(_ role: LifecycleRole) -> String { statuses.filter { $0.role == role }.map(\.title).joined(separator: ", ") }
        var text = [LifecycleRole.notStarted, .active, .completed].map(titles).filter { !$0.isEmpty }.joined(separator: " → ")
        let dropped = titles(.cancelled)
        if !dropped.isEmpty { text += " (dropped: \(dropped))" }
        return text
    }

    /// True when bugs have states of their own, so the picker shows their outline too.
    var bugsDiffer: Bool { bug.statuses.map(\.id) != feature.statuses.map(\.id) }

    // MARK: The transitions of a flow

    /// Transitions built from the order and the roles of `statuses`, like a board has them: free moves between the waiting states,
    /// a start into the first working state, a step forward and back through the working states, a completion that needs delivery
    /// evidence, an acceptance from one completed state to the next, a reopening, and a way out to the dropped state and back.
    static func rules(for statuses: [WorkflowStatus]) -> [LifecycleRule] {
        func ids(_ role: LifecycleRole) -> [String] { statuses.filter { $0.role == role }.map(\.id) }
        let waiting = ids(.notStarted), active = ids(.active), completed = ids(.completed), dropped = ids(.cancelled)
        guard let first = active.first, let done = completed.first, !waiting.isEmpty else { return [] }
        let free: [LifecycleActorKind: [LifecycleCondition]] = [.human: [], .ai: []]
        // The app's own steps (a quick feature that goes to Ready) may reorder the waiting states too.
        let reorder: [LifecycleActorKind: [LifecycleCondition]] = [.human: [], .ai: [], .system: []]
        var rules: [LifecycleRule] = []

        if waiting.count > 1 {
            for state in waiting {
                rules.append(LifecycleRule(from: Set(waiting).subtracting([state]), to: state, kind: .spec, needs: reorder))
            }
        }
        rules.append(LifecycleRule(from: Set(waiting), to: first, kind: .start,
                                   needs: [.human: [.startEvidence], .ai: [.startEvidence], .system: [.startEvidence]]))
        for index in 0..<(active.count - 1) {
            rules.append(LifecycleRule(from: [active[index]], to: active[index + 1], kind: .spec, needs: free))
            rules.append(LifecycleRule(from: [active[index + 1]], to: active[index], kind: .rollback, needs: free))
        }
        rules.append(LifecycleRule(from: Set(active), to: waiting[waiting.count - 1], kind: .rollback, needs: [.human: [.reason], .system: []]))
        rules.append(LifecycleRule(from: Set(waiting).union(active), to: done, kind: .completion,
                                   needs: [.human: [.deliveryEvidence], .ai: [.deliveryEvidence], .system: [.deliveryEvidence]]))
        for index in 0..<(completed.count - 1) {
            rules.append(LifecycleRule(from: [completed[index]], to: completed[index + 1], kind: .acceptance,
                                       needs: [.human: [], .ai: [.acceptanceEvidence]]))
            rules.append(LifecycleRule(from: [completed[index + 1]], to: completed[index], kind: .reopen, needs: [.human: [.reason]]))
        }
        rules.append(LifecycleRule(from: Set(completed), to: first, kind: .reopen,
                                   needs: [.human: [.reason], .ai: [.regressionEvidence], .system: [.regressionEvidence]]))
        if let out = dropped.first {
            rules.append(LifecycleRule(from: Set(statuses.map(\.id)).subtracting(dropped), to: out, kind: .cancellation, needs: free))
            rules.append(LifecycleRule(from: [out], to: waiting[0], kind: .reopen, needs: [.human: [.reason]]))
        }
        return rules
    }

    private static func board(_ statuses: [(String, String, LifecycleRole)]) -> IssueLifecycleDefinition {
        let list = statuses.map { WorkflowStatus(id: $0.0, title: $0.1, role: $0.2) }
        return IssueLifecycleDefinition(statuses: list, rules: rules(for: list))
    }

    // MARK: The catalogue

    /// The flow every project had before flows existed: features are specified (idea to ready) before work starts.
    static let markView = WorkflowFlow(
        id: "markview", title: "MarkView with specification", origin: "MarkView",
        summary: "Features are specified (idea, exploring, draft, review, resolving, ready) before work starts; bugs go open, fixing, fixed, closed. The Explore and Review steps move features through these stages.",
        feature: ProjectWorkflow.standard.feature, bug: ProjectWorkflow.standard.bug)

    private static let kanbanBoard: [(String, String, LifecycleRole)] = [
        ("backlog", "Backlog", .notStarted), ("ready", "Ready", .notStarted),
        ("in-progress", "In progress", .active), ("in-review", "In review", .active),
        ("done", "Done", .completed), ("wont-do", "Won't do", .cancelled),
    ]

    static let kanban = WorkflowFlow(
        id: "kanban", title: "Kanban", origin: "Kanban method; Jira and Trello boards",
        summary: "One board for features and bugs: Backlog and Ready wait, In progress and In review are work, Done ends it. No specification stages and no separate acceptance.",
        feature: board(kanbanBoard), bug: board(kanbanBoard))

    private static let scrumBoard: [(String, String, LifecycleRole)] = [
        ("product-backlog", "Product backlog", .notStarted), ("sprint-backlog", "Sprint backlog", .notStarted),
        ("in-progress", "In progress", .active), ("in-review", "In review", .active),
        ("done", "Done", .completed), ("removed", "Removed", .cancelled),
    ]

    static let scrum = WorkflowFlow(
        id: "scrum", title: "Scrum", origin: "Scrum guide; Jira Scrum board",
        summary: "Product backlog, then the sprint backlog the team committed to, then work and review. Done means the Definition of Done is met: the panel under the diagram shows what that is here.",
        feature: board(scrumBoard), bug: board(scrumBoard))

    private static let linearBoard: [(String, String, LifecycleRole)] = [
        ("triage", "Triage", .notStarted), ("backlog", "Backlog", .notStarted), ("todo", "Todo", .notStarted),
        ("in-progress", "In progress", .active), ("in-review", "In review", .active),
        ("done", "Done", .completed), ("canceled", "Canceled", .cancelled),
    ]

    static let linear = WorkflowFlow(
        id: "linear", title: "Linear", origin: "Linear workflow categories",
        summary: "Triage, Backlog and Todo (unstarted), then In progress and In review (started), Done (completed) and Canceled.",
        feature: board(linearBoard), bug: board(linearBoard))

    private static let githubBoard: [(String, String, LifecycleRole)] = [
        ("todo", "Todo", .notStarted), ("in-progress", "In progress", .active),
        ("done", "Done", .completed), ("not-planned", "Not planned", .cancelled),
    ]

    static let githubProjects = WorkflowFlow(
        id: "github-projects", title: "GitHub Projects", origin: "The default GitHub Projects board",
        summary: "The smallest board: Todo, In progress, Done. An issue closed as not planned is Not planned.",
        feature: board(githubBoard), bug: board(githubBoard))

    static let azureAgile = WorkflowFlow(
        id: "azure-agile", title: "Azure DevOps Agile", origin: "Azure DevOps Agile process",
        summary: "New, Active, Resolved, Closed. The work is Resolved when it is delivered; a person or an AI then accepts it into Closed. Features can also be Removed.",
        feature: board([("new", "New", .notStarted), ("active", "Active", .active), ("resolved", "Resolved", .completed),
                        ("closed", "Closed", .completed), ("removed", "Removed", .cancelled)]),
        bug: board([("new", "New", .notStarted), ("active", "Active", .active), ("resolved", "Resolved", .completed),
                    ("closed", "Closed", .completed)]))

    static let shapeUp = WorkflowFlow(
        id: "shape-up", title: "Shape Up", origin: "Basecamp, Shape Up",
        summary: "Features are shaped before anyone builds them (Raw idea, Shaping, Shaped), then a bet is placed and the team builds until it ships. Bugs go Reported, Fixing, Fixed.",
        feature: board([("raw-idea", "Raw idea", .notStarted), ("shaping", "Shaping", .notStarted), ("shaped", "Shaped", .notStarted),
                        ("bet", "Bet", .notStarted), ("building", "Building", .active), ("shipped", "Shipped", .completed),
                        ("dropped", "Dropped", .cancelled)]),
        bug: board([("reported", "Reported", .notStarted), ("fixing", "Fixing", .active), ("fixed", "Fixed", .completed),
                    ("wont-fix", "Won't fix", .cancelled)]))

    static let kanbanTriage = WorkflowFlow(
        id: "kanban-triage", title: "Kanban with bug triage", origin: "Kanban board; Bugzilla bug life cycle",
        summary: "Features follow the Kanban board. A bug is Unconfirmed until it is confirmed, is then fixed, and is Resolved and Verified like in Bugzilla; an invalid report is Invalid.",
        feature: board(kanbanBoard),
        bug: board([("unconfirmed", "Unconfirmed", .notStarted), ("confirmed", "Confirmed", .notStarted),
                    ("in-progress", "In progress", .active), ("resolved", "Resolved", .completed),
                    ("verified", "Verified", .completed), ("invalid", "Invalid", .cancelled)]))

    /// The flows the Flow menu offers, in order.
    static let catalogue: [WorkflowFlow] = [markView, kanban, scrum, linear, githubProjects, azureAgile, shapeUp, kanbanTriage]

    static func flow(_ id: String) -> WorkflowFlow? { catalogue.first { $0.id == id } }

    /// The flow a workflow was made from, by the ids and roles of its statuses (a renamed state is still the same flow): a person sees
    /// which one is in effect. nil when the statuses match none, that is when someone added, removed or re-roled a state.
    static func matching(_ workflow: ProjectWorkflow) -> WorkflowFlow? {
        func shape(_ definition: IssueLifecycleDefinition) -> [String] { definition.statuses.map { "\($0.id):\($0.role.rawValue)" } }
        return catalogue.first { shape($0.feature) == shape(workflow.feature) && shape($0.bug) == shape(workflow.bug) }
    }
}

// MARK: - Flows without the specification stages (REQ-004, DEC-001)

extension IssueLifecycleDefinition {
    /// True when features have the stages the app's Explore and Review steps move them through. A board (Kanban, Scrum, …) has none:
    /// those steps still run, and leave the status as it is.
    var hasSpecificationStages: Bool { isKnown("exploring") }

    /// The status a new feature starts in: `preferred` (idea, exploring, draft) when this flow has it, else the first state where
    /// work waits, which is the entry of a board.
    func entryStatus(preferring preferred: String) -> String {
        if isKnown(preferred) { return preferred }
        return statuses(with: .notStarted).first?.id ?? preferred
    }

    /// Whether a feature has left Explore. With the specification stages that is the status (anything after Draft). Without them the
    /// status says nothing about discovery, so the requirements do: once work has started, or every requirement is approved, the
    /// feature is past Explore. A feature that is still in a waiting state with draft requirements can be explored and reviewed.
    func isPastExplore(status: String, requirementsApproved: Bool) -> Bool {
        if hasSpecificationStages { return !["idea", "exploring", "draft"].contains(status) }
        if let role = role(of: status), role != .notStarted { return true }
        return requirementsApproved
    }
}
