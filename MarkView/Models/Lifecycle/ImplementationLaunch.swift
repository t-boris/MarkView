// How "Implement with AI" starts a feature (agent-aware-implementation-runs, DEC-011): handed to an assistant terminal at once, or
// prepared as a managed Cockpit plan that is approved and started separately. MarkView recommends one mode from the feature's
// implementation plan and the Definition of Done the person reviewed, says why, and the person may choose the other one. The
// managed run also has to know where the checklist and the project's own delivery rules disagree (REQ-004), so the person can
// reconcile them before anything runs. Standard library only.

enum ImplementationLaunchMode: String, Codable, Equatable, Sendable {
    case direct, cockpit

    var title: String {
        switch self {
        case .direct: return "Hand to the AI terminal"
        case .cockpit: return "Prepare a Cockpit plan"
        }
    }
}

/// What Build knows of a feature when it offers the two modes: its specification and the delivery rules of its process.
struct ImplementationLaunchOptions: Equatable, Sendable {
    var specification: ImplementationLaunchAdvice.Specification
    var rules: DeliveryRules
}

/// The recommended way to start, with the reasons that decided it, in the order they weigh.
struct ImplementationLaunchAdvice: Equatable, Sendable {
    var recommended: ImplementationLaunchMode
    var reasons: [String]

    /// What a feature offers the recommendation: the issues of its implementation plan, in order.
    struct Specification: Equatable, Sendable {
        var planIssues: [String]
        var approvedRequirements: Int
    }

    /// A managed run pays off when the work has several stages that must be delivered in order (the plan's issues) or when the
    /// checklist carries the work past the pull request into a release, a chain of external actions that Cockpit approves,
    /// reconciles after an interruption and keeps evidence for. Everything else is one goal for one terminal.
    static func recommend(_ specification: Specification, done: DefinitionOfDone) -> ImplementationLaunchAdvice {
        var cockpit: [String] = []
        var direct: [String] = []
        let issues = specification.planIssues.count
        if issues >= 2 {
            cockpit.append("The implementation plan has \(issues) issues (\(specification.planIssues.joined(separator: ", "))) to deliver one after another.")
        } else if issues == 1 {
            direct.append("The implementation plan has a single issue.")
        } else {
            direct.append("The feature has no implementation plan yet, so there are no stages to order.")
        }
        let release = done.mode(of: "deploy")
        if release == .require || release == .ask {
            cockpit.append("The checklist carries the work through a release (\(release?.title ?? "")): merge, release and their evidence are steps Cockpit approves and checks.")
        } else {
            let merge = done.mode(of: "merge")
            if merge == .require || merge == .ask {
                direct.append("Delivery ends at the merge (\(merge?.title ?? "")), which the terminal can ask you about.")
            } else {
                direct.append("Delivery ends at the pull request.")
            }
        }
        if specification.approvedRequirements >= 1, !cockpit.isEmpty {
            cockpit.append("Cockpit adds an independent review of the \(specification.approvedRequirements) approved requirement\(specification.approvedRequirements == 1 ? "" : "s") before delivery.")
        }
        return cockpit.isEmpty ? ImplementationLaunchAdvice(recommended: .direct, reasons: direct)
                               : ImplementationLaunchAdvice(recommended: .cockpit, reasons: cockpit)
    }
}

/// A place where the Definition of Done and the project's mandatory delivery rules disagree: the run would stop short of what the
/// project needs for the feature to count as delivered. The person reconciles it before execution: by changing the item, or by
/// acknowledging that the run delivers only what the checklist asks.
struct DeliveryConflict: Equatable, Identifiable, Codable, Sendable {
    /// The checklist item the conflict is about.
    var itemID: String
    var message: String
    var id: String { itemID }
}

enum ImplementationDeliveryRules {
    /// Every conflict between `done` and `rules`. Merged work is what the project's lifecycle completes a feature on, whatever its
    /// process, so skipping the merge always conflicts.
    static func conflicts(done: DefinitionOfDone, rules: DeliveryRules) -> [DeliveryConflict] {
        var found: [DeliveryConflict] = []
        func skipped(_ id: String) -> Bool { done.mode(of: id) == .skip }
        func title(_ id: String) -> String { done.items.first { $0.id == id }?.title ?? id }
        if rules.pullRequestRequired, skipped("pr") {
            found.append(DeliveryConflict(itemID: "pr", message: "The project delivers only through a merged pull request, but the checklist skips \u{201C}\(title("pr"))\u{201D}."))
        }
        if rules.checksRequired, skipped("ci") {
            found.append(DeliveryConflict(itemID: "ci", message: "The project requires passing checks, but the checklist skips \u{201C}\(title("ci"))\u{201D}."))
        }
        if skipped("merge") {
            found.append(DeliveryConflict(itemID: "merge", message: "A feature counts as delivered only on merged work, but the checklist skips \u{201C}\(title("merge"))\u{201D}."))
        }
        if rules.githubReleaseRequired, skipped("deploy") {
            found.append(DeliveryConflict(itemID: "deploy", message: "The project requires a published GitHub release, but the checklist skips \u{201C}\(title("deploy"))\u{201D}."))
        } else if let event = rules.confirmedEventName, skipped("deploy") {
            found.append(DeliveryConflict(itemID: "deploy", message: "The project's delivery needs \u{201C}\(event)\u{201D} confirmed, but the checklist skips \u{201C}\(title("deploy"))\u{201D}."))
        }
        return found
    }

    /// The checklist items the project needs for delivery, by `isMandatory`.
    static func mandatory(rules: DeliveryRules) -> [String] { ["pr", "ci", "merge", "deploy"].filter { isMandatory($0, rules: rules) } }

    /// Whether the project needs this delivery action for the feature to count as delivered: declining it blocks delivery.
    static func isMandatory(_ itemID: String, rules: DeliveryRules) -> Bool {
        switch itemID {
        case "pr": return rules.pullRequestRequired
        case "ci": return rules.checksRequired
        case "merge": return true
        case "deploy": return rules.githubReleaseRequired || rules.confirmedEventName != nil
        default: return false
        }
    }
}

extension DefinitionOfDone {
    /// The mode of a built-in or custom item; nil when the checklist has no such item.
    func mode(of id: String) -> DoneMode? { items.first { $0.id == id }?.mode }
}
