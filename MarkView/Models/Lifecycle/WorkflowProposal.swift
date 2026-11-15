import Foundation

// A workflow change that an assistant proposes through MCP (feature assistants-confirm-delivery-with-evidence-and-propose-workflow,
// REQ-003, DEC-001, DEC-005): checked with the rules that Save uses, held by the window in memory, and shown to the person in the
// Workflow tab, who reviews it in the draft and saves it. Nothing here writes a file. Foundation only (with ProjectWorkflow.swift,
// ProjectWorkflowStore.swift, WorkflowDescription.swift, WorkflowEvents.swift, IssueListing.swift and IssueLifecycle.swift), so that
// tools/tests/issue-lifecycle-tests.sh compiles it on its own.

struct WorkflowProposal: Equatable, Identifiable {
    let id: UUID
    /// The whole workflow as the assistant proposes it, on the revision it read.
    var workflow: ProjectWorkflow
    /// One sentence from the assistant: what the change is for.
    var summary: String
    /// Which assistant proposed it, for display.
    var proposedBy: String
    var at: Date
    /// What changes compared with the workflow of the project when it was proposed, one plain sentence each.
    var differences: [String]

    /// The workflow file has moved on since the proposal was made: saving it would overwrite a change nobody looked at, so it cannot
    /// be loaded into the draft.
    func isOutdated(against current: ProjectWorkflow) -> Bool { workflow.revision != current.revision }
}

enum WorkflowProposalChecker {
    /// Why a proposal was not accepted: every problem, so that the assistant can correct them all at once.
    struct Refusal: Error, Equatable {
        var problems: [String]
    }

    /// Reads what an assistant sent as the workflow (a JSON object, or its text), checks it like Save does and, when it is sound and
    /// changes something, makes the proposal.
    static func evaluate(workflow value: Any?, summary: String, current: ProjectWorkflow, by name: String, now: Date = Date()) -> Result<WorkflowProposal, Refusal> {
        var problems: [String] = []
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { problems.append("`summary` is required: one sentence that tells the person what the change is for.") }
        guard let data = data(of: value) else {
            problems.append("`workflow` must be the whole workflow as a JSON object (or its JSON text), in the format of the guide topic workflow-format.")
            return .failure(Refusal(problems: problems))
        }
        let proposed: ProjectWorkflow
        switch ProjectWorkflowStore.parse(data) {
        case .success(let workflow): proposed = workflow
        case .failure(let load):
            switch load {
            case .unsupported(let schema): problems.append("The schema \(schema) is not supported (this app reads \(ProjectWorkflow.currentSchema)).")
            case .damaged(let reason): problems.append("This is not a workflow in the file format: \(reason)")
            case .missing, .loaded: problems.append("This is not a workflow.")
            }
            return .failure(Refusal(problems: problems))
        }
        if proposed.revision != current.revision {
            problems.append("The proposal is on revision \(proposed.revision) but the workflow of the project is revision \(current.revision). "
                            + "Read it again with markview_get_workflow, make the change on that, and propose again.")
        }
        problems += proposed.validate().map(\.message)
        let differences = WorkflowDescription.differences(from: current, to: proposed)
        if differences.isEmpty { problems.append("The proposal changes nothing compared with the workflow of the project.") }
        guard problems.isEmpty else { return .failure(Refusal(problems: problems)) }
        return .success(WorkflowProposal(id: UUID(), workflow: proposed, summary: text, proposedBy: name, at: now, differences: differences))
    }

    private static func data(of value: Any?) -> Data? {
        switch value {
        case let text as String: return text.data(using: .utf8)
        case let object as [String: Any]: return JSONSerialization.isValidJSONObject(object) ? try? JSONSerialization.data(withJSONObject: object) : nil
        default: return nil
        }
    }

    /// What the assistant is told when the proposal was accepted. `needsReplacement` lists the work items that would need a replacement
    /// status or process when the change is saved.
    static func reply(_ proposal: WorkflowProposal, needsReplacement: [String]) -> String {
        var lines = ["Your proposal is held for the person: \u{201C}\(proposal.summary)\u{201D}", "", "What it changes:"]
        lines += proposal.differences.map { "- " + $0 }
        if !needsReplacement.isEmpty {
            lines += ["", "Work items that need a replacement when it is saved (the person chooses it):"] + needsReplacement.map { "- " + $0 }
        }
        lines += ["", "Nothing is saved. Tell the person to open the Workflow tab of this window, press \u{201C}Review in the draft\u{201D}, check the "
                      + "Features, Bugs and Processes pages and press Save. You cannot save it, and you should not say that it is saved."]
        return lines.joined(separator: "\n")
    }

    /// Items that a save of `proposal` would owe a replacement, one line each.
    static func replacementLines(_ impact: WorkflowImpact) -> [String] {
        var lines: [String] = []
        for kind in [IssueKind.feature, .bug] {
            for (status, items) in (impact.statuses[kind] ?? [:]).sorted(by: { $0.key < $1.key }) where !items.isEmpty {
                lines.append("\(items.count) \(kind.rawValue) item(s) in the status \(status) (\(items.sorted().prefix(5).joined(separator: ", "))\(items.count > 5 ? ", …" : ""))")
            }
        }
        for (variant, items) in impact.variants.sorted(by: { $0.key < $1.key }) where !items.isEmpty {
            lines.append("\(items.count) item(s) that follow the process \(variant) (\(items.sorted().prefix(5).joined(separator: ", "))\(items.count > 5 ? ", …" : ""))")
        }
        return lines
    }
}
