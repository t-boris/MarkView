import Foundation

// The assistant proposes a whole plan. Controls always come from the person, not from its response.
enum CockpitPlanning {
    enum ParseError: LocalizedError {
        case malformed, invalid([String])
        var errorDescription: String? {
            switch self {
            case .malformed: return "The assistant returned an incomplete plan. Try again."
            case .invalid(let problems): return problems.joined(separator: " ")
            }
        }
    }

    static let systemPrompt = """
    Turn the person's goal into a sequential plan. Inspect the project and use only the available capabilities and agent names supplied.
    Each step needs a specific assignment, an agent, and a verifiable completion condition. Include explicit success criteria.
    State outcomes you know cannot be achieved and offer alternatives; do not present them as achievable. If a prerequisite is uncertain,
    a first step may check it. Use a prerequisite step only for a check whose failure must pause later steps.
    Return a complete plan, not a patch, including after a refinement. Do not execute the plan or modify project files during planning.
    If production QA is needed, say so in an assignment; the exact QA plan and production actions require separate inspection before approval.
    """

    static var schema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let step: [String: Any] = ["type": "object", "properties": [
            "title": string, "agent": string, "assignment": string, "completionCondition": string,
            "isPrerequisite": ["type": "boolean"]
        ]]
        return ["type": "object", "properties": [
            "scenarios": strings, "steps": ["type": "array", "items": step], "successCriteria": strings,
            "unavailableOutcomes": strings, "alternatives": strings
        ]]
    }

    static func parse(_ value: Any?, goal: String, controls: CockpitControls, availableAgents: Set<String>) throws -> CockpitPlan {
        guard let object = value as? [String: Any], let scenarios = object["scenarios"] as? [String],
              let rawSteps = object["steps"] as? [[String: Any]], rawSteps.count <= 100,
              let criteria = object["successCriteria"] as? [String], let unavailable = object["unavailableOutcomes"] as? [String],
              let alternatives = object["alternatives"] as? [String] else { throw ParseError.malformed }
        var steps: [CockpitStep] = []
        for raw in rawSteps {
            guard let title = raw["title"] as? String, let agent = raw["agent"] as? String,
                  let assignment = raw["assignment"] as? String, let condition = raw["completionCondition"] as? String,
                  let prerequisite = raw["isPrerequisite"] as? Bool else { throw ParseError.malformed }
            guard availableAgents.contains(agent) else { throw ParseError.invalid(["Unknown agent: \(agent)"]) }
            steps.append(CockpitStep(title: title, agent: agent, assignment: assignment, completionCondition: condition, isPrerequisite: prerequisite))
        }
        let plan = CockpitPlan(goal: goal, controls: controls, scenarios: scenarios, steps: steps, successCriteria: criteria,
                               unavailableOutcomes: unavailable, alternatives: alternatives, productionQA: nil)
        // An infeasible goal still needs an honest explanation and alternatives. It is not an
        // approvable execution plan: CockpitApproval continues to reject its missing steps.
        let problems = plan.problems
        let explanationOnly = steps.isEmpty && !unavailable.isEmpty && problems.allSatisfy {
            $0 == "At least one step is required." || $0 == "Explicit success criteria are required."
        }
        if !problems.isEmpty && !explanationOnly {
            throw ParseError.invalid(problems)
        }
        return plan
    }
}
