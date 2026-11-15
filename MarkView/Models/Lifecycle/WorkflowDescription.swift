import Foundation

// The workflow in plain words, the difference between two workflows in plain words, and the guide to the workflow file for
// assistants (feature assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-002, REQ-003). Foundation only (with
// ProjectWorkflow.swift, IssueListing.swift, IssueLifecycle.swift and WorkflowEvents.swift), so that
// tools/tests/issue-lifecycle-tests.sh compiles it on its own. Nothing here reads or writes a file.

enum WorkflowDescription {
    // MARK: One workflow

    /// What the workflow says, in words an assistant can read before it proposes a change.
    static func describe(_ workflow: ProjectWorkflow) -> String {
        var lines = ["Workflow \u{201C}\(workflow.name)\u{201D}, revision \(workflow.revision) (schema \(workflow.schema))."]
        for kind in [IssueKind.feature, .bug] {
            let definition = workflow.lifecycle(kind)
            lines.append("")
            lines.append("\(label(kind)) statuses: " + definition.statuses.map { "\($0.id) (\($0.title); \($0.role.title.lowercased()))" }.joined(separator: ", ") + ".")
            lines.append("\(label(kind)) steps of the type, and who may make each (the rules of a process that has its own steps replace these for its items):")
            lines += definition.rules.map { "- " + sentence($0) }
        }
        lines.append("")
        lines.append("Processes (each work item follows one; the default of a type is used when none is chosen):")
        for variant in workflow.variants {
            var marks: [String] = []
            if workflow.defaultFeatureVariant == variant.id || workflow.defaultBugVariant == variant.id { marks.append("default for \(variant.kind.rawValue)s") }
            lines.append("- \(variant.id) (\u{201C}\(variant.name)\u{201D}, \(variant.kind.rawValue)\(marks.isEmpty ? "" : "; " + marks.joined(separator: "; "))): \(variant.description).")
            if let rules = variant.rules {
                lines += rules.map { "    own step: " + sentence($0) }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func label(_ kind: IssueKind) -> String { kind == .feature ? "Feature" : "Bug" }

    /// One step as a sentence: from, to, kind, what each actor needs, and the event that makes MarkView take it.
    static func sentence(_ rule: LifecycleRule) -> String {
        func actor(_ name: String, _ kind: LifecycleActorKind) -> String {
            guard let conditions = rule.needs[kind] else { return "\(name): not by the rules" }
            return "\(name): " + (conditions.isEmpty ? "no conditions" : conditions.map(\.words).joined(separator: " and "))
        }
        var text = "\(rule.from.sorted().joined(separator: " or ")) \u{2192} \(rule.to) [\(rule.kind.rawValue)]; "
        text += [actor("a person", .human), actor("an AI", .ai), actor("MarkView", .system)].joined(separator: "; ")
        if let event = rule.event { text += "; MarkView takes this step itself when \(event.title)" }
        return text
    }

    // MARK: Two workflows

    /// What changes from `old` to `new`, one plain sentence each; empty when nothing does. The revision is not a change.
    static func differences(from old: ProjectWorkflow, to new: ProjectWorkflow) -> [String] {
        var out: [String] = []
        if old.name != new.name { out.append("The workflow is renamed from \u{201C}\(old.name)\u{201D} to \u{201C}\(new.name)\u{201D}.") }
        for kind in [IssueKind.feature, .bug] {
            let before = old.lifecycle(kind), after = new.lifecycle(kind)
            for status in after.statuses where before.status(status.id) == nil {
                out.append("\(label(kind)) status added: \(status.id) (\(status.title); \(status.role.title.lowercased())).")
            }
            for status in before.statuses where after.status(status.id) == nil {
                out.append("\(label(kind)) status removed: \(status.id). Items in it need a replacement status when the change is saved.")
            }
            for status in after.statuses {
                guard let was = before.status(status.id), was != status else { continue }
                if was.title != status.title { out.append("\(label(kind)) status \(status.id) is renamed from \u{201C}\(was.title)\u{201D} to \u{201C}\(status.title)\u{201D}.") }
                if was.role != status.role {
                    out.append("\(label(kind)) status \(status.id) changes its role from \(was.role.title.lowercased()) to \(status.role.title.lowercased()).")
                }
            }
            out += ruleDifferences(label: "\(label(kind)) step", old: before.rules, new: after.rules)
        }

        for variant in new.variants where old.variant(variant.id) == nil {
            out.append("Process added: \(variant.id) (\u{201C}\(variant.name)\u{201D}, \(variant.kind.rawValue)): \(variant.description).")
        }
        for variant in old.variants where new.variant(variant.id) == nil {
            out.append("Process removed: \(variant.id) (\u{201C}\(variant.name)\u{201D}). Items that follow it need a replacement process when the change is saved.")
        }
        for variant in new.variants {
            guard let was = old.variant(variant.id), was != variant else { continue }
            out += processDifferences(was, variant)
        }
        for kind in [IssueKind.feature, .bug] {
            let was = old.defaultVariantID(kind), now = new.defaultVariantID(kind)
            if was != now { out.append("The default \(kind.rawValue) process changes from \(was) to \(now).") }
        }
        return out
    }

    private static func processDifferences(_ was: RuleVariant, _ now: RuleVariant) -> [String] {
        let name = "Process \u{201C}\(now.name)\u{201D}"
        var out: [String] = []
        if was.name != now.name { out.append("Process \u{201C}\(was.name)\u{201D} is renamed to \u{201C}\(now.name)\u{201D}.") }
        func quoted(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
        if was.start != now.start { out.append("\(name): the start changes from \(quoted(was.start.title)) to \(quoted(now.start.title)).") }
        if was.integration != now.integration {
            out.append("\(name): the way work reaches the branch changes from \(quoted(was.integration.title)) to \(quoted(now.integration.title)).")
        }
        if was.checks != now.checks { out.append("\(name): checks become \(now.checks ? "required" : "not required").") }
        if was.delivery != now.delivery { out.append("\(name): the delivery event changes from \(quoted(was.delivery.title)) to \(quoted(now.delivery.title)).") }
        if was.confirmer != now.confirmer && (was.delivery.isConfirmedBySomeone || now.delivery.isConfirmedBySomeone) {
            out.append("\(name): the delivery event is confirmed by \(quoted(now.confirmer.title)) instead of \(quoted(was.confirmer.title)).")
        }
        if was.acceptance != now.acceptance { out.append("\(name): acceptance changes from \(quoted(was.acceptance.title)) to \(quoted(now.acceptance.title)).") }
        if was.summary != now.summary { out.append("\(name): its description changes.") }
        switch (was.rules, now.rules) {
        case (nil, nil): break
        case (nil, .some(let own)): out.append("\(name) gets its own \(own.count) steps instead of following the steps of its type.")
        case (.some, nil): out.append("\(name) follows the steps of its type again; its own steps are gone.")
        case (.some(let before), .some(let after)): out += ruleDifferences(label: "\(name): step", old: before, new: after)
        }
        return out
    }

    private static func ruleDifferences(label: String, old: [LifecycleRule], new: [LifecycleRule]) -> [String] {
        var out: [String] = []
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for rule in new where before[rule.id] == nil { out.append("\(label) added: \(sentence(rule)).") }
        for rule in old where after[rule.id] == nil { out.append("\(label) removed: \(rule.id).") }
        for rule in new {
            guard let was = before[rule.id], was != rule else { continue }
            out.append("\(label) \(rule.id) changes: now \(sentence(rule)).")
        }
        return out
    }
}

// MARK: - The guide for assistants

/// How the workflow file is written: what an assistant reads before it proposes a change. Every allowed value comes from the enum that
/// the code decodes it with, so a value that the code accepts is in the guide (checked by the workflow suite).
enum WorkflowFormatGuide {
    static var text: String {
        """
        The workflow of a project says which statuses features and bugs have, which steps move an item between them, who may make each step \
        and with what evidence, and how work is delivered. It is the file .dde/workflow/workflow.json. You never write it. To change it:

        1. Read the current one with markview_get_workflow (the file as JSON and a description in words, with its revision).
        2. Change what the person asked for, keeping everything else as it was, and send the WHOLE workflow to markview_propose_workflow \
        with a one-sentence summary and the revision you read. MarkView checks it with the rules that Save uses and answers with every \
        problem (correct them and propose again) or with the differences in words.
        3. A valid proposal is only held in the person's window. Tell the person to open the Workflow tab of this window, look at the \
        proposal and press Save. Nothing is changed until they do, and you cannot save it. Do not say that it is saved.

        TOP LEVEL
        schema (1), name, revision (copy the number you read; a proposal made on an older revision is outdated), feature and bug (each has \
        statuses and rules), variants (the processes), defaultFeatureVariant and defaultBugVariant (ids of variants of that kind).

        STATUSES of a type: {"id": "in-progress", "title": "In progress", "role": "active"}. The id is lower-case words joined by hyphens \
        and is what is stored in the Markdown files. Roles say what a status means to the code: \
        \(LifecycleRole.allCases.map { "\"\($0.rawValue)\" (\(roleMeaning($0)))" }.joined(separator: "; ")). A type needs at least one \
        status with each of the roles not-started, active and completed.

        RULES (the steps) of a type: {"from": ["in-progress"], "to": "in-review", "kind": "spec", "human": [], "ai": [], "system": [], "event": "work-started"}.
        - kind is one of: \(TransitionKind.allCases.map { "\"\($0.rawValue)\" (\($0.meaning))" }.joined(separator: "; ")).
        - human, ai and system list the conditions that person, assistant and MarkView must meet to make the step. [] = no condition. An absent \
        key = that actor may not make the step by the rules (a person can still force it in the window, with a reason; an assistant never can). \
        The conditions are: \(LifecycleCondition.allCases.map { "\"\($0.rawValue)\" (\($0.title))" }.joined(separator: "; ")).
        - event (optional) makes MarkView take the step itself, as "system", when the event happens to an item in one of the from statuses. \
        The rule must have a "system" entry, and the conditions listed there must be met, or the step is not made. Events: \
        \(RuleEvent.known.map { "\"\($0.rawValue)\" (\($0.meaning))" }.joined(separator: "; ")). An event that is not in this list never fires and \
        Save refuses it. Events are not retroactive: an item whose event has already happened is not moved when the rule is saved.
        - Completion rules must require "delivery-evidence" from everyone listed, and each type needs one completion rule from an active status \
        that is open to "system", so that finished work is recorded by MarkView.

        PROCESSES (variants): {"id": "standard-bug", "name": "Standard bug", "kind": "bug", "start": "agent", "integration": "pull-request", \
        "checks": true, "delivery": {"type": "human-confirmed", "name": "Installed on mac"}, "confirmedBy": "person-or-ai", \
        "acceptance": "ai-with-evidence", "summary": "..."}. A process may have its own "rules" (same format as above); without them its items \
        follow the rules of their type.
        - start: \(StartEvidenceMode.allCases.map { "\"\($0.rawValue)\" (\($0.title.lowercased()))" }.joined(separator: ", ")).
        - integration: \(IntegrationPath.allCases.map { "\"\($0.rawValue)\" (\($0.title.lowercased()))" }.joined(separator: ", ")).
        - checks: true when the checks of the merged work must have passed.
        - delivery.type: \(DeliveryEvent.typeNames.map { "\"\($0)\"" }.joined(separator: ", ")). "github-release" is verified by MarkView from GitHub; \
        "human-confirmed" needs a "name" and is confirmed by a person, or by an assistant with evidence when "confirmedBy" says so.
        - confirmedBy (only with "human-confirmed"; absent = a person only): \(DeliveryConfirmer.allCases.map { "\"\($0.rawValue)\" (\($0.title.lowercased()))" }.joined(separator: ", ")). \
        An assistant confirms with markview_confirm_delivery and the evidence of what it verified.
        - acceptance: \(AcceptanceMode.allCases.map { "\"\($0.rawValue)\" (\($0.title.lowercased()))" }.joined(separator: ", ")).

        EXAMPLES
        - Let an assistant move a bug from in-progress to in-review: add or edit the rule {"from": ["in-progress"], "to": "in-review", "kind": "spec", "human": [], "ai": []}.
        - Move a bug to in-review by itself when its investigation finishes: {"from": ["in-progress"], "to": "in-review", "kind": "spec", "human": [], "ai": [], "system": [], "event": "investigation-finished"}.
        - Move an item to in-review as soon as work on it starts: the same with "event": "work-started" and from the status that the start step leads to.
        - Let an assistant confirm "Installed on mac" in the bug process: set "confirmedBy": "person-or-ai" on that process.

        WHAT THE MODEL CANNOT EXPRESS
        Events other than the ones listed (a pull request being opened, time passing, a file changing), conditions of your own, permissions per \
        person, and rules that apply only to some items of a process. If the person asks for one of these, say that the workflow cannot do it yet \
        and offer the nearest thing that it can; do not invent a field (MarkView refuses unknown values and ignores unknown keys).
        """
    }

    private static func roleMeaning(_ role: LifecycleRole) -> String {
        switch role {
        case .notStarted: return "no work has started"
        case .active: return "work is under way"
        case .completed: return "the work is delivered"
        case .cancelled: return "the work was dropped without being delivered"
        }
    }
}

extension TransitionKind {
    /// For the guide: what kind of step it is.
    var meaning: String {
        switch self {
        case .spec: return "a move between stages before and around the work, with no evidence needed"
        case .start: return "work begins; must end in an active status and needs start evidence"
        case .completion: return "work is delivered; must end in a completed status and needs delivery evidence"
        case .acceptance: return "delivered work is accepted or closed after a fix"
        case .cancellation: return "work is dropped before it was completed"
        case .archive: return "completed work is put away"
        case .reopen: return "completed work goes back to unfinished work"
        case .rollback: return "unfinished work goes back to an earlier stage"
        case .unlisted: return "a step that is not in the table; only a person's forced move is recorded this way, do not write it"
        case .replacement: return "a person replaced a status that the workflow no longer has; recorded by MarkView, do not write it"
        }
    }
}
