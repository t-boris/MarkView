import Foundation

struct CockpitCriterionResult: Codable, Equatable, Sendable {
    var criterion: String
    var met: Bool
    var evidence: String
}
struct CockpitProgress: Codable, Equatable, Sendable {
    var passNumber: Int
    var activity: String
    var scenarioCoverage: [String]
    var bugs: [String]
    var fixes: [String]
    var latestChange: String
    var blockers: [String]
    var buildLogPath: String?
    var criteriaResults: [CockpitCriterionResult]? = nil
}

enum CockpitOutcome: Equatable {
    case success, blocked, unverified

    static func evaluate(criteria: [String], progress: CockpitProgress?) -> CockpitOutcome {
        guard let progress else { return .unverified }
        if !progress.blockers.isEmpty || progress.criteriaResults?.contains(where: { !$0.met }) == true { return .blocked }
        guard let results = progress.criteriaResults, !criteria.isEmpty, results.count == criteria.count,
              Set(results.map(\.criterion)) == Set(criteria), Set(criteria).count == criteria.count,
              results.allSatisfy({ $0.met && !$0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return .unverified }
        return .success
    }
}

// The reviewed plan is a value: approval is tied to its complete contents, including a production QA plan.
struct CockpitControls: Codable, Equatable {
    var createScenarios = false
    var checks = ""
    var fileBugs = true
    var fixBugs = false
    var build = false
    var deployment = "Disabled"
    /// Whether the Copilot answers the questions the step agents ask (`CockpitSupervisor`). Runs saved before it existed get it on.
    var supervisor = true
    /// How long the run's agents may work in total, in minutes; nil means no limit.
    var timeLimitMinutes: Int?
    /// How many fix cycles the run may use; nil means no limit.
    var fixCycleLimit: Int?
    /// Who answers the step agents' questions: an agent's display name (`CLITool.displayName`) and one of its models.
    /// nil means the project's own assistant and model. Runs saved before the choice existed have neither.
    var supervisorAgent: String?
    var supervisorModel: String?

    init() {}

    /// Runs saved before the limits were enforced hold free text ("2h", "3") and a budget limit that no longer exists.
    /// Text that is not a clear amount is read as "no limit"; unknown keys are ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        createScenarios = try container.decodeIfPresent(Bool.self, forKey: .createScenarios) ?? false
        checks = try container.decodeIfPresent(String.self, forKey: .checks) ?? ""
        fileBugs = try container.decodeIfPresent(Bool.self, forKey: .fileBugs) ?? true
        fixBugs = try container.decodeIfPresent(Bool.self, forKey: .fixBugs) ?? false
        build = try container.decodeIfPresent(Bool.self, forKey: .build) ?? false
        deployment = try container.decodeIfPresent(String.self, forKey: .deployment) ?? "Disabled"
        supervisor = try container.decodeIfPresent(Bool.self, forKey: .supervisor) ?? true
        supervisorAgent = Self.chosen(try container.decodeIfPresent(String.self, forKey: .supervisorAgent))
        supervisorModel = Self.chosen(try container.decodeIfPresent(String.self, forKey: .supervisorModel))
        if let minutes = try container.decodeIfPresent(Int.self, forKey: .timeLimitMinutes) {
            timeLimitMinutes = minutes > 0 ? minutes : nil
        } else if let text = try container.decodeIfPresent(String.self, forKey: .timeLimit) {
            timeLimitMinutes = Self.minutes(in: text)
        }
        if let count = try? container.decodeIfPresent(Int.self, forKey: .fixCycleLimit) {
            fixCycleLimit = count > 0 ? count : nil
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .fixCycleLimit) {
            fixCycleLimit = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    private enum Key: String, CodingKey {
        case createScenarios, checks, fileBugs, fixBugs, build, deployment, supervisor, supervisorAgent, supervisorModel, timeLimitMinutes, fixCycleLimit
        /// Only read, from runs saved with a free-text time limit.
        case timeLimit
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(createScenarios, forKey: .createScenarios)
        try container.encode(checks, forKey: .checks)
        try container.encode(fileBugs, forKey: .fileBugs)
        try container.encode(fixBugs, forKey: .fixBugs)
        try container.encode(build, forKey: .build)
        try container.encode(deployment, forKey: .deployment)
        try container.encode(supervisor, forKey: .supervisor)
        try container.encodeIfPresent(Self.chosen(supervisorAgent), forKey: .supervisorAgent)
        try container.encodeIfPresent(Self.chosen(supervisorModel), forKey: .supervisorModel)
        try container.encodeIfPresent(timeLimitMinutes, forKey: .timeLimitMinutes)
        try container.encodeIfPresent(fixCycleLimit, forKey: .fixCycleLimit)
    }

    /// An empty choice is no choice: the same value everywhere, so a plan that never chose encodes exactly as before.
    private static func chosen(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Whether the steps the planner chose may no longer fit: what the planner was told differs. The limits and the supervisor are applied
    /// by MarkView while the plan runs and change no step.
    func affectsSteps(comparedTo other: CockpitControls) -> Bool {
        createScenarios != other.createScenarios || checks != other.checks || fileBugs != other.fileBugs
            || fixBugs != other.fixBugs || build != other.build || deployment != other.deployment
    }

    /// "90", "90 min", "2h", "1h30m", "1.5 hours": the minutes they name, or nil when the text is not just an amount of time.
    static func minutes(in text: String) -> Int? {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let pattern = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)?"#) else { return nil }
        let whole = NSRange(value.startIndex..., in: value)
        var total = 0.0, covered = 0
        for match in pattern.matches(in: value, range: whole) {
            guard let numberRange = Range(match.range(at: 1), in: value), let number = Double(value[numberRange]) else { return nil }
            let unit = Range(match.range(at: 2), in: value).map { String(value[$0]) } ?? "m"
            total += unit.hasPrefix("h") ? number * 60 : number
            covered += match.range.length
        }
        // Whatever the amounts do not cover must be only separators ("1h and 30m", "1h, 30m").
        let rest = value.replacingOccurrences(of: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "and", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;+"))
        guard covered > 0, rest.isEmpty else { return nil }
        let minutes = Int(total.rounded())
        return minutes > 0 ? minutes : nil
    }
}

struct CockpitProductionQA: Codable, Equatable {
    var exactPlan: String
    var dataChangingActions: [String]
}

/// A value shown to the person and bound to one exact QA plan and target.
struct CockpitQAReview: Codable, Equatable {
    var scenarioID: String
    var targetID: String
    var fingerprint: String
    var production: Bool
    var exactPlan: String
    var dataChangingActions: [String]
    var productionConfirmationRequired: Bool = false
}

struct CockpitStep: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var agent: String
    var assignment: String
    var completionCondition: String
    var isPrerequisite: Bool = false
    /// An existing scenario this step will run through MarkView's QA gate, if any.
    var qaScenarioID: String? = nil
    /// The model the step's agent runs with: one of `AIAssistantPreferences.modelOptions(for:)`'s ids. nil or empty means the
    /// project's chosen model for that agent, or the agent's own default. Runs saved before the choice existed have none.
    var model: String? = nil

    /// `model` with an empty choice read as no choice.
    var chosenModel: String? {
        guard let value = model?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct CockpitPlan: Codable, Equatable {
    var id: UUID = UUID()
    var goal: String
    var controls: CockpitControls
    var scenarios: [String]
    var steps: [CockpitStep]
    var successCriteria: [String]
    var unavailableOutcomes: [String]
    var alternatives: [String]
    var productionQA: CockpitProductionQA?
    var qaReviews: [CockpitQAReview]? = nil

    /// Earlier steps are skipped, so their QA must not appear as production work in this approval.
    func selectingStart(_ index: Int) -> CockpitPlan? {
        guard steps.indices.contains(index) else { return nil }
        var copy = self
        let remaining = Set(steps.dropFirst(index).compactMap(\.qaScenarioID))
        for prior in 0..<index { copy.steps[prior].qaScenarioID = nil }
        copy.scenarios = scenarios.filter { remaining.contains($0) }
        copy.qaReviews = nil
        copy.productionQA = nil
        return copy
    }

    /// Why the plan cannot be approved, and which step each reason belongs to (nil: the plan as a whole).
    struct Blocker: Equatable {
        var stepID: UUID?
        var message: String
    }

    /// What is missing in the plan itself, whatever the QA environments chosen or the person's confirmations.
    var structuralBlockers: [Blocker] {
        var result: [Blocker] = []
        func empty(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if empty(goal) { result.append(Blocker(stepID: nil, message: "A goal is required.")) }
        if steps.isEmpty { result.append(Blocker(stepID: nil, message: "At least one step is required.")) }
        if Set(steps.map(\.id)).count != steps.count { result.append(Blocker(stepID: nil, message: "Step identifiers must be unique.")) }
        for (index, step) in steps.enumerated() where empty(step.title) || empty(step.agent) || empty(step.assignment) || empty(step.completionCondition) {
            result.append(Blocker(stepID: step.id, message: "Step \(index + 1) needs a title, agent, assignment and completion condition."))
        }
        if successCriteria.isEmpty || successCriteria.contains(where: empty) { result.append(Blocker(stepID: nil, message: "Explicit success criteria are required.")) }
        if let qa = productionQA, empty(qa.exactPlan) || qa.dataChangingActions.contains(where: empty) {
            result.append(Blocker(stepID: nil, message: "Production QA needs the exact plan and data-changing actions."))
        }
        return result
    }

    var problems: [String] { structuralBlockers.map(\.message) }

    /// Everything that keeps `CockpitApproval` from existing for this plan, in the order the checks run. `CockpitApproval`
    /// is created only when this is empty, so the screen can say why instead of leaving a button grey.
    func approvalBlockers(productionConfirmed: Bool) -> [Blocker] {
        let structural = structuralBlockers
        guard structural.isEmpty else { return structural }
        guard Set(steps.compactMap(\.qaScenarioID)) == Set(scenarios) else {
            return [Blocker(stepID: nil, message: "Each selected QA scenario must be assigned to a step.")]
        }
        guard scenarios.isEmpty || steps.last?.qaScenarioID == nil else {
            return [Blocker(stepID: steps.last?.id, message: "QA must be followed by a final verification step.")]
        }
        if scenarios.isEmpty, qaReviews?.isEmpty == false {
            return [Blocker(stepID: nil, message: "The plan carries a QA review for a scenario it does not run.")]
        }
        if !scenarios.isEmpty {
            guard let reviews = qaReviews, reviews.count == scenarios.count,
                  Set(reviews.map(\.scenarioID)) == Set(scenarios), Set(scenarios).count == scenarios.count,
                  reviews.allSatisfy({ !$0.fingerprint.isEmpty && !$0.exactPlan.isEmpty && !$0.targetID.isEmpty }) else {
                return [Blocker(stepID: nil, message: "Choose an environment for each QA scenario and review its exact plan.")]
            }
            let production = reviews.filter(\.production)
            if production.contains(where: \.productionConfirmationRequired) && !productionConfirmed {
                return [Blocker(stepID: nil, message: "Production QA needs your confirmation of the data-changing actions.")]
            }
            if !production.isEmpty,
               productionQA != CockpitProductionQA(exactPlan: production.map(\.exactPlan).joined(separator: "\n\n"),
                                                   dataChangingActions: production.flatMap(\.dataChangingActions)) {
                return [Blocker(stepID: nil, message: "The production QA plan does not match the reviewed scenarios.")]
            }
        }
        if let qa = productionQA, !qa.dataChangingActions.isEmpty, !productionConfirmed {
            return [Blocker(stepID: nil, message: "Production QA needs your confirmation of the data-changing actions.")]
        }
        return []
    }

    // MARK: Editing
    //
    // The person edits the plan step by step. Every helper keeps the plan's own rules: the QA scenarios the plan lists are exactly
    // the ones its steps name, once each, in step order; the values derived from a review (`qaReviews`, `productionQA`) are dropped,
    // and `CockpitSession.preparedPlan` builds them again.

    /// Makes `scenarios` equal to the QA scenarios the steps name.
    mutating func normalizeScenarios() {
        var seen = Set<String>()
        scenarios = steps.compactMap(\.qaScenarioID).filter { seen.insert($0).inserted }
        qaReviews = nil
        productionQA = nil
    }

    /// Moves a step by `offset` places; false when it would leave the plan.
    @discardableResult mutating func moveStep(at index: Int, by offset: Int) -> Bool {
        let target = index + offset
        guard steps.indices.contains(index), steps.indices.contains(target), offset != 0 else { return false }
        steps.swapAt(index, target)
        normalizeScenarios()
        return true
    }

    /// Puts `step` at `index` (the end when it is past it).
    mutating func insertStep(_ step: CockpitStep, at index: Int) {
        steps.insert(step, at: min(max(0, index), steps.count))
        normalizeScenarios()
    }

    /// A copy of the step just after it, with its own identifier. The copy runs no QA scenario: a scenario is run by one step.
    @discardableResult mutating func duplicateStep(at index: Int) -> UUID? {
        guard steps.indices.contains(index) else { return nil }
        var copy = steps[index]
        copy.id = UUID()
        copy.qaScenarioID = nil
        copy.isPrerequisite = false
        steps.insert(copy, at: index + 1)
        normalizeScenarios()
        return copy.id
    }

    @discardableResult mutating func removeStep(at index: Int) -> Bool {
        guard steps.indices.contains(index) else { return false }
        steps.remove(at: index)
        normalizeScenarios()
        return true
    }

    /// Sets a step's agent. The model belongs to an agent, so it is cleared when the agent changes.
    mutating func setAgent(_ agent: String, forStep id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].agent != agent else { return }
        steps[index].agent = agent
        steps[index].model = nil
    }

    /// Sets a step's model; an empty one means the default.
    mutating func setModel(_ model: String?, forStep id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        steps[index].model = (value?.isEmpty ?? true) ? nil : value
    }
}

struct CockpitApproval: Codable, Equatable {
    private let plan: CockpitPlan
    let productionConfirmed: Bool

    init?(plan: CockpitPlan, productionConfirmed: Bool) {
        guard plan.approvalBlockers(productionConfirmed: productionConfirmed).isEmpty else { return nil }
        self.plan = plan
        self.productionConfirmed = productionConfirmed
    }

    func permits(_ candidate: CockpitPlan) -> Bool { candidate == plan && candidate.problems.isEmpty }
}

// MARK: What the person switches off while a run is going (DEC-028)

/// What the person turned OFF on the run screen. It can only say "off": applying it to the approved controls never gives a step more than
/// the person approved, and putting a lever back up returns to exactly what the plan allows. Limits and the instruction-only controls
/// (create scenarios, build, checks) are not here: they change only through a revised plan.
struct CockpitLiveSwitches: Codable, Equatable, Sendable {
    var fileBugsCut = false
    var fixBugsCut = false
    var deploymentCut = false
    var supervisorCut = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        fileBugsCut = try container.decodeIfPresent(Bool.self, forKey: .fileBugsCut) ?? false
        fixBugsCut = try container.decodeIfPresent(Bool.self, forKey: .fixBugsCut) ?? false
        deploymentCut = try container.decodeIfPresent(Bool.self, forKey: .deploymentCut) ?? false
        supervisorCut = try container.decodeIfPresent(Bool.self, forKey: .supervisorCut) ?? false
    }

    private enum Key: String, CodingKey { case fileBugsCut, fixBugsCut, deploymentCut, supervisorCut }

    var isEmpty: Bool { !fileBugsCut && !fixBugsCut && !deploymentCut && !supervisorCut }

    /// The names of the levers that differ between two states, for the timeline: ("File bugs", now off).
    static func changes(from old: CockpitLiveSwitches, to new: CockpitLiveSwitches) -> [(name: String, off: Bool)] {
        var found: [(String, Bool)] = []
        if old.fileBugsCut != new.fileBugsCut { found.append(("Filing bugs", new.fileBugsCut)) }
        if old.fixBugsCut != new.fixBugsCut { found.append(("Fixing bugs", new.fixBugsCut)) }
        if old.deploymentCut != new.deploymentCut { found.append(("Deployment", new.deploymentCut)) }
        if old.supervisorCut != new.supervisorCut { found.append(("The supervisor", new.supervisorCut)) }
        return found
    }
}

extension CockpitControls {
    /// The controls the run is under now: what the plan approved, minus what the person has switched off.
    func narrowed(by cuts: CockpitLiveSwitches) -> CockpitControls {
        var narrowed = self
        if cuts.fileBugsCut { narrowed.fileBugs = false }
        if cuts.fixBugsCut { narrowed.fixBugs = false }
        if cuts.deploymentCut { narrowed.deployment = "Disabled" }
        if cuts.supervisorCut { narrowed.supervisor = false }
        return narrowed
    }
}
