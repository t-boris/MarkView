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
    A step may also name a model for its agent, chosen only from the models listed for that agent; use an empty string for the agent's own default.
    Prefer a lighter, faster model for checks, listings and the final verification and the most capable one for implementation and diagnosis;
    when unsure leave it empty. The person can change any agent or model before approving.
    State outcomes you know cannot be achieved and offer alternatives; do not present them as achievable. If a prerequisite is uncertain,
    a first step may check it. Use a prerequisite step only for a check whose failure must pause later steps.
    Every other step never pauses the run: when it fails, Cockpit records the failure and starts the next step, which sees the failure
    and the bugs it filed in priorResults. So mark as a prerequisite each step whose failure makes later steps pointless or unsafe (the
    build, CI, a precondition of a deployment or of a cleanup), and leave a step that discovers problems for later steps to fix (a QA
    run, an audit) as a regular step.
    When a prerequisite check may fail for a recoverable reason that stays within the goal and controls (for example starting a local
    service, signing in with available credentials, or preparing a test precondition), you may include an optional recovery object
    (assignment and maxAttempts 1–3) on that prerequisite step so Cockpit can attempt a bounded recovery and rerun the prerequisite
    before pausing for the person. Never put an action forbidden by the controls in recovery.
    A prerequisite that verifies the pull request's CI should carry a recovery (maxAttempts 2) that diagnoses the failing or missing
    checks and repairs them on the feature branch; MarkView adds a default one when the controls allow fixing and you leave it out.
    If the controls forbid fixing, list repairing a failing CI under unavailableOutcomes.
    Return a complete plan, not a patch, including after a refinement. Do not execute the plan or modify project files during planning.
    Give the flow a title: a short name of 3 to 8 words, with no quotes and no final period, that says in your own words what this flow
    does, written in the language of the goal. Do not copy the goal's text. After a refinement keep the current title unless the changes
    alter what the flow is.
    For an existing QA scenario, use its supplied id in scenarios and in qaScenarioID on at least one step; use an empty string for non-QA steps.
    After all QA steps, include a final non-QA verification step that evaluates every success criterion using the prior results.
    Do not claim that an unknown or not-yet-created QA scenario can run without a later review of its exact plan.
    The controls are enforced by MarkView while the plan runs: its tools refuse what a control forbids (filing bugs, moving a bug into fixing,
    deploying anywhere but the named environment, starting other agents), the project is compared before and after each agent step for source
    changes and new scenarios the controls forbid, and a time limit (minutes of agent work in total) or fix cycle limit stops the run.
    Never plan a step that needs a forbidden capability: list that outcome as unavailable and offer an alternative. Size the steps to fit a limit.
    Build and Checks are instructions only. Starting other agents is never available to a step.
    While a step runs its agent may ask the supervisor (this Copilot) questions through markview_cockpit_ask when the supervisor control is on; the supervisor
    answers at once by its own judgment and never waits for the person. Never plan a step that needs the person's answer midway: ask for nothing the person
    must give while the run is going, and list a needed person's decision as an unavailable outcome with an alternative instead.
    """

    /// What the planner is told on top of `systemPrompt` when it plans the implementation of a feature (a managed run, DEC-030).
    static func managedPrompt(feature: CockpitFeatureContext) -> String {
        """
        This plan implements the feature specified in \(feature.folder) (\(feature.title)). Read the whole folder first: the overview, every
        requirement and its acceptance criteria, the implementation plan, and the records that bind the work. \(HandoffPrompt.featureRecords)
        Nothing waits for the person while the run goes: a question the specification leaves open is a blocker of the step that meets it.
        Write only the implementation steps, in dependency order, each one sized to be checked on its own (one per issue of the
        implementation plan when it has issues). MarkView adds the rest itself from the Definition of Done the person reviewed: the branch
        \(feature.branch), the tests, an independent review, fixes and their re-verification, the version, the pull request, CI, merge,
        release and the final verification. Do not plan those steps. Use successCriteria for the feature's acceptance criteria.
        """
    }

    /// What the planner is told about delegation in every plan whose controls allow it (DEC-033).
    static let delegationRule = "Set delegate to true on a step only when its agent is listed with a delegation mechanism and the step has "
        + "independent parts that its own subagents can do within the same assignment; otherwise false."

    /// What the planner of a plain plan is told about steps that run at the same time when "Parallel steps" is on (REQ-001, REQ-007).
    static let groupRule = "Steps that only inspect and do not need each other's results (reviews, analyses, reading checks) may run at the "
        + "same time: give 2 to \(CockpitPlan.groupLimit) adjacent such steps the same group label. A step in a group changes no files, builds "
        + "nothing, runs no tests and no QA scenario, has no recovery, is not a prerequisite and is never the plan's last step; MarkView fails "
        + "every step of a group when the project changed. Leave group empty on every other step."

    static var schema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let recovery: [String: Any] = ["type": "object", "properties": [
            "assignment": string, "maxAttempts": ["type": "integer"]
        ]]
        let step: [String: Any] = ["type": "object", "required": ["title", "agent", "model", "assignment", "completionCondition", "isPrerequisite", "qaScenarioID"], "properties": [
            "title": string, "agent": string, "model": string, "assignment": string, "completionCondition": string,
            "isPrerequisite": ["type": "boolean"], "qaScenarioID": string, "delegate": ["type": "boolean"], "recovery": recovery,
            "group": string
        ]]
        return ["type": "object", "required": ["title", "scenarios", "steps", "successCriteria", "unavailableOutcomes", "alternatives"], "properties": [
            "title": string, "scenarios": strings, "steps": ["type": "array", "items": step], "successCriteria": strings,
            "unavailableOutcomes": strings, "alternatives": strings
        ]]
    }

    /// The assistant's name for the flow as it is shown: whitespace and line breaks collapsed to single spaces, wrapping quotes removed,
    /// at most `maxTitleLength` characters. nil when nothing usable is left; a title is a suggestion and never costs the plan.
    static func cleanTitle(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        var text = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let quotes = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
        text = text.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
        if text.count > maxTitleLength { text = String(text.prefix(maxTitleLength)).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? nil : text
    }

    static let maxTitleLength = 80

    /// `models` holds, for each available agent, the model ids it offers. A model the assistant proposes that is not among them is read as
    /// "the agent's default": a suggestion that cannot be used must not cost the whole plan.
    static func parse(_ value: Any?, goal: String, controls: CockpitControls, availableAgents: Set<String>,
                      models: [String: Set<String>] = [:]) throws -> CockpitPlan {
        guard let object = value as? [String: Any], let scenarios = object["scenarios"] as? [String],
              let rawSteps = object["steps"] as? [[String: Any]], rawSteps.count <= 100,
              let criteria = object["successCriteria"] as? [String], let unavailable = object["unavailableOutcomes"] as? [String],
              let alternatives = object["alternatives"] as? [String] else { throw ParseError.malformed }
        var steps: [CockpitStep] = []
        for raw in rawSteps {
            guard let title = raw["title"] as? String, let agent = raw["agent"] as? String,
                  let assignment = raw["assignment"] as? String, let condition = raw["completionCondition"] as? String,
                  let prerequisite = raw["isPrerequisite"] as? Bool, let qaID = raw["qaScenarioID"] as? String else { throw ParseError.malformed }
            guard availableAgents.contains(agent) else { throw ParseError.invalid(["Unknown agent: \(agent)"]) }
            let proposed = (raw["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = !proposed.isEmpty && models[agent]?.contains(proposed) == true ? proposed : nil
            var recovery: CockpitStepRecovery?
            if prerequisite, let rawRecovery = raw["recovery"] as? [String: Any],
               let recAssignment = (rawRecovery["assignment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !recAssignment.isEmpty {
                let rawMax = (rawRecovery["maxAttempts"] as? Int) ?? 1
                let bounded = min(max(1, rawMax), CockpitStepRecovery.maxAllowedAttempts)
                recovery = CockpitStepRecovery(assignment: recAssignment, maxAttempts: bounded)
            }
            var step = CockpitStep(title: title, agent: agent, assignment: assignment, completionCondition: condition, isPrerequisite: prerequisite,
                                   qaScenarioID: qaID.isEmpty ? nil : qaID, model: model, delegate: (raw["delegate"] as? Bool) == true ? true : nil,
                                   recovery: recovery)
            // A CI prerequisite is repaired and checked again whatever the planner wrote (BUG-129); with fixing off a repair would be
            // refused, so none is promised and the plan screen says so instead.
            if step.recovery == nil, controls.fixBugs, step.verifiesCI { step.recovery = .ciRepair(branch: nil) }
            // A group label counts only while the switch is on; groups that may not run together are dropped below.
            if controls.parallelSteps { step.parallelGroup = raw["group"] as? String }
            steps.append(step)
        }
        guard Set(steps.compactMap(\.qaScenarioID)) == Set(scenarios), Set(scenarios).count == scenarios.count else {
            throw ParseError.invalid(["Each selected QA scenario must be assigned to a step."])
        }
        guard scenarios.isEmpty || steps.last?.qaScenarioID == nil else {
            throw ParseError.invalid(["QA must be followed by a final verification step."])
        }
        var plan = CockpitPlan(goal: goal, title: cleanTitle(object["title"]), controls: controls, scenarios: scenarios, steps: steps, successCriteria: criteria,
                               unavailableOutcomes: unavailable, alternatives: alternatives, productionQA: nil)
        plan.normalizeGroups()
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
