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
        case createScenarios, checks, fileBugs, fixBugs, build, deployment, supervisor, timeLimitMinutes, fixCycleLimit
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
        try container.encodeIfPresent(timeLimitMinutes, forKey: .timeLimitMinutes)
        try container.encodeIfPresent(fixCycleLimit, forKey: .fixCycleLimit)
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

    var problems: [String] {
        var result: [String] = []
        func empty(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if empty(goal) { result.append("A goal is required.") }
        if steps.isEmpty { result.append("At least one step is required.") }
        if Set(steps.map(\.id)).count != steps.count { result.append("Step identifiers must be unique.") }
        for (index, step) in steps.enumerated() where empty(step.title) || empty(step.agent) || empty(step.assignment) || empty(step.completionCondition) {
            result.append("Step \(index + 1) needs a title, agent, assignment and completion condition.")
        }
        if successCriteria.isEmpty || successCriteria.contains(where: empty) { result.append("Explicit success criteria are required.") }
        if let qa = productionQA, empty(qa.exactPlan) || qa.dataChangingActions.contains(where: empty) {
            result.append("Production QA needs the exact plan and data-changing actions.")
        }
        return result
    }
}

struct CockpitApproval: Codable, Equatable {
    private let plan: CockpitPlan
    let productionConfirmed: Bool

    init?(plan: CockpitPlan, productionConfirmed: Bool) {
        guard plan.problems.isEmpty else { return nil }
        guard Set(plan.steps.compactMap(\.qaScenarioID)) == Set(plan.scenarios) else { return nil }
        guard plan.scenarios.isEmpty || plan.steps.last?.qaScenarioID == nil else { return nil }
        if plan.scenarios.isEmpty, plan.qaReviews?.isEmpty == false { return nil }
        if !plan.scenarios.isEmpty {
            guard let reviews = plan.qaReviews, reviews.count == plan.scenarios.count,
                  Set(reviews.map(\.scenarioID)) == Set(plan.scenarios), Set(plan.scenarios).count == plan.scenarios.count,
                  reviews.allSatisfy({ !$0.fingerprint.isEmpty && !$0.exactPlan.isEmpty && !$0.targetID.isEmpty }) else { return nil }
            let production = reviews.filter(\.production)
            if production.contains(where: \.productionConfirmationRequired) && !productionConfirmed { return nil }
            if !production.isEmpty {
                guard plan.productionQA == CockpitProductionQA(exactPlan: production.map(\.exactPlan).joined(separator: "\n\n"),
                                                               dataChangingActions: production.flatMap(\.dataChangingActions)) else { return nil }
            }
        }
        if let qa = plan.productionQA, !qa.dataChangingActions.isEmpty, !productionConfirmed { return nil }
        self.plan = plan
        self.productionConfirmed = productionConfirmed
    }

    func permits(_ candidate: CockpitPlan) -> Bool { candidate == plan && candidate.problems.isEmpty }
}
