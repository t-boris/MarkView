import Foundation

// The reviewed plan is a value: approval is tied to its complete contents, including a production QA plan.
struct CockpitControls: Codable, Equatable {
    var createScenarios = false
    var checks = ""
    var fileBugs = true
    var fixBugs = false
    var build = false
    var deployment = "Disabled"
    var timeLimit = ""
    var budgetLimit = ""
    var fixCycleLimit = ""
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
