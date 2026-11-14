import Foundation

/// What the agent of one Cockpit step may do through MarkView's MCP tools, derived from the controls the person approved.
/// Foundation only, no app state: tools/tests/cockpit-policy-tests.sh compiles this file on its own and checks the rules.
///
/// The gate refuses a call; it does not stop the agent's own shell or editor. `CockpitStepAudit` compares the project before and
/// after the step for what this gate cannot see.
struct CockpitStepPolicy: Equatable {
    var fileBugs: Bool
    var fixBugs: Bool
    /// The environment the step may deploy to (lower-cased); nil when deployment is disabled.
    var deploymentTarget: String?

    enum Decision: Equatable {
        case allow
        case refuse(String)
    }

    /// How a tool is judged. Every MarkView MCP tool appears in `classes`; a tool that is not listed is refused.
    enum ToolClass {
        /// Reports of the Cockpit step itself.
        case report
        /// Reads and lists.
        case read
        /// Writes of project documentation (features, requirements, discussions) that the step may need to record its findings.
        case record
        case fileBug
        case bugStatus
        case deploy
        case deployPropose
        case delivery
        /// Starts or drives another agent: that agent would not be under this policy.
        case otherAgent
    }

    static let classes: [String: ToolClass] = [
        "markview_cockpit_report_progress": .report, "markview_cockpit_complete_step": .report, "markview_cockpit_ask": .report,

        "markview_guide": .read, "markview_project": .read, "markview_list_features": .read, "markview_get_feature": .read,
        "markview_list_bugs": .read, "markview_get_bug": .read, "markview_list_prototypes": .read, "markview_get_prototype": .read,
        "markview_issue_context": .read, "markview_get_workflow": .read, "markview_open_questions": .read,
        "markview_control_guide": .read, "markview_windows": .read, "markview_recent_projects": .read, "markview_agents": .read,
        "markview_agent_read": .read, "markview_agent_wait": .read, "markview_flow_status": .read,
        "markview_deployments": .read, "markview_deployments_status": .read, "markview_deployments_logs": .read, "markview_deployments_db": .read,
        "markview_discussions": .read, "markview_get_discussion": .read,

        "markview_create_feature": .record, "markview_add_requirement": .record, "markview_add_decision": .record,
        "markview_add_question": .record, "markview_set_status": .record, "markview_update_feature": .record,
        "markview_update_object": .record, "markview_answer_question": .record, "markview_add_source": .record,
        "markview_add_discussion_note": .record, "markview_update_bug": .record, "markview_answer_bug_question": .record,
        "markview_link_issue": .record, "markview_attach_issue": .record, "markview_propose_workflow": .record,
        "markview_create_discussion": .record, "markview_discussion_item": .record,
        "markview_open_project": .record, "markview_focus_window": .record,

        "markview_create_bug": .fileBug,
        "markview_set_bug_status": .bugStatus,
        "markview_deployments_run": .deploy,
        "markview_deployments_propose": .deployPropose,
        "markview_confirm_delivery": .delivery,

        "markview_agent_start": .otherAgent, "markview_agent_send": .otherAgent, "markview_agent_key": .otherAgent,
        "markview_flow_new": .otherAgent, "markview_flow_answer": .otherAgent, "markview_flow_run": .otherAgent,
        "markview_flow_implement": .otherAgent, "markview_flow_fix_bug": .otherAgent, "markview_flow_stop": .otherAgent,
    ]

    /// The text of a deployment control that means "nowhere".
    static func isDeploymentDisabled(_ text: String) -> Bool {
        ["", "disabled", "none", "no", "off"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    init(controls: CockpitControls) {
        fileBugs = controls.fileBugs
        fixBugs = controls.fixBugs
        deploymentTarget = Self.isDeploymentDisabled(controls.deployment)
            ? nil : controls.deployment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `isFixingStatus` says whether a bug status of the project's workflow means work on the fix is going on. A move to "fixed" is
    /// not refused: MarkView itself demands merge and check evidence for it, and closing a duplicate is not fixing.
    /// `environmentNames` gives the names an environment id goes by, so "Production" in the controls matches the id `prod`.
    func decision(tool: String, arguments: [String: Any], isFixingStatus: (String) -> Bool,
                  environmentNames: (String) -> [String]) -> Decision {
        // The browser tools only act on the pages the step works with.
        if tool.hasPrefix("browser_") { return .allow }
        guard let kind = Self.classes[tool] else {
            return .refuse("\(tool) is not known to the Cockpit policy, so it is refused during a Cockpit step.")
        }
        switch kind {
        case .report, .read, .record:
            return .allow
        case .otherAgent:
            return .refuse("A Cockpit step cannot start or drive other agents. Do the work yourself in this terminal, or report a blocker.")
        case .fileBug:
            return fileBugs ? .allow : .refuse("Filing bugs is turned off for this Cockpit run. Describe the problem in your step report instead.")
        case .bugStatus:
            let status = (arguments["status"] as? String) ?? ""
            if !fixBugs, isFixingStatus(status) {
                return .refuse("Fixing bugs is turned off for this Cockpit run, so a bug cannot move to \"\(status)\". Report what you found instead.")
            }
            return .allow
        case .deploy, .deployPropose, .delivery:
            guard let target = deploymentTarget else {
                return .refuse("Deployment is disabled for this Cockpit run. Do not try another way to deploy; report a blocker if it is needed.")
            }
            guard kind == .deploy else { return .allow }
            let asked = ((arguments["environment"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let names = ([asked] + environmentNames(asked)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard !asked.isEmpty, names.contains(target) else {
                return .refuse("This Cockpit run may deploy only to \"\(target)\", not to \"\(asked)\".")
            }
            return .allow
        }
    }

    /// True when the call moves a bug into a state of work on the fix: one fix cycle started. Counted by the gate, not by the agent.
    static func startsFixCycle(tool: String, arguments: [String: Any], isFixingStatus: (String) -> Bool) -> Bool {
        tool == "markview_set_bug_status" && isFixingStatus((arguments["status"] as? String) ?? "")
    }

    /// What the gate refuses, in the words shown when the plan is reviewed.
    var enforced: [String] {
        var lines = ["Start or drive other agents through MarkView"]
        if !fileBugs { lines.append("File bug reports") }
        if !fixBugs { lines.append("Move a bug into fixing") }
        if let target = deploymentTarget {
            lines.append("Deploy anywhere but \"\(target)\"")
        } else {
            lines.append("Run commands on deployment environments, propose environments or confirm delivery")
        }
        return lines
    }

    /// What only the written instruction carries: MarkView has no tool for it, so it can be neither refused nor checked.
    static func instructionOnly(_ controls: CockpitControls) -> [String] {
        var lines: [String] = []
        if !controls.build { lines.append("Build") }
        if !controls.checks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("Checks") }
        return lines
    }
}
