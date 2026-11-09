import Foundation

// What "done" means in a process, in plain words (feature workflow-flows, REQ-001): which of a pull request, passing checks, a
// release or a confirmed event, and an acceptance the process requires, where in the transition table delivery is judged and the
// result accepted, and where the project's Definition of Done (`.dde/definition-of-done.json`) says something else. The process is the
// authority for the lifecycle (DEC-003); a difference with the checklist is a warning to read, never a change. Foundation only (with
// FeatureVocabulary.swift, IssueListing.swift, ProjectWorkflow.swift, IssueLifecycle.swift and DefinitionOfDone.swift), so
// tools/tests/workflow-done-tests.sh compiles it on its own.

struct WorkflowDone: Equatable, Sendable {
    /// One thing that may be required for the work to count as done.
    struct Mark: Equatable, Sendable {
        var name: String
        var required: Bool
        /// What it means for this process, one sentence.
        var detail: String
    }

    var processID: String
    var processName: String
    var marks: [Mark]
    /// "Done here means a merged pull request, passing checks and a published GitHub release, then accepted by a person."
    var sentence: String
    /// Where the Definition of Done and the process disagree.
    var warnings: [String]

    /// `acceptanceStep` is false when the transitions have no step from one completed status to another: a flow whose only completed
    /// status is Done is finished by its delivery evidence, and nobody accepts anything afterwards.
    static func make(_ variant: RuleVariant, definition: DefinitionOfDone?, acceptanceStep: Bool = true) -> WorkflowDone {
        let pullRequest = variant.integration == .pullRequest
        let release: Mark
        switch variant.delivery {
        case .none:
            release = Mark(name: "Release", required: false, detail: "No release or delivery event is required")
        case .githubRelease:
            release = Mark(name: "Release", required: true, detail: "A GitHub release that contains the work is published")
        case .humanConfirmed(let name):
            let event = name.trimmingCharacters(in: .whitespaces)
            release = Mark(name: "Delivery event", required: true, detail: event.isEmpty ? "A person confirms the delivery event" : "A person confirms: \(event)")
        }
        let marks = [
            Mark(name: "Pull request", required: pullRequest,
                 detail: pullRequest ? "Every unit of work is a pull request that GitHub confirms merged"
                                     : "A direct commit to the default branch counts, and so does a merged pull request"),
            Mark(name: "CI checks", required: variant.checks, detail: variant.checks ? "The required checks passed" : "No checks are required"),
            release,
            Mark(name: "Acceptance", required: acceptanceStep,
                 detail: !acceptanceStep ? "These transitions have no acceptance step"
                     : variant.acceptance == .humanOnly ? "Only a person accepts" : "A person accepts, or an AI with its evidence and every criterion ticked"),
        ]
        return WorkflowDone(processID: variant.id, processName: variant.name, marks: marks, sentence: doneSentence(variant, acceptanceStep: acceptanceStep),
                            warnings: definition.map { mismatches(variant, $0) } ?? [])
    }

    private static func doneSentence(_ variant: RuleVariant, acceptanceStep: Bool) -> String {
        var parts: [String] = []
        parts.append(variant.integration == .pullRequest ? "a merged pull request" : "the work on the default branch")
        if variant.checks { parts.append("passing checks") }
        switch variant.delivery {
        case .none: break
        case .githubRelease: parts.append("a published GitHub release")
        case .humanConfirmed(let name):
            let event = name.trimmingCharacters(in: .whitespaces)
            parts.append(event.isEmpty ? "a confirmed delivery event" : "a person's confirmation: \(event)")
        }
        let joined: String
        switch parts.count {
        case 1: joined = parts[0]
        default: joined = parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        guard acceptanceStep else { return "Done here means \(joined)." }
        let accepted = variant.acceptance == .humanOnly ? "accepted by a person" : "accepted by a person or an AI with evidence"
        return "Done here means \(joined), then \(accepted)."
    }

    /// The differences between the process and the project's Definition of Done. "Ask me" items are left alone: they are a question,
    /// not a requirement either way.
    static func mismatches(_ variant: RuleVariant, _ definition: DefinitionOfDone) -> [String] {
        func mode(_ id: String) -> DoneMode? { definition.items.first { $0.id == id }?.mode }
        var out: [String] = []
        if mode("pr") == .require, variant.integration == .directToMain {
            out.append("The Definition of Done requires a pull request, but this process also accepts a direct commit to the default branch.")
        }
        if mode("pr") == .skip, variant.integration == .pullRequest {
            out.append("The Definition of Done skips the pull request, but this process requires one.")
        }
        if mode("ci") == .require, !variant.checks {
            out.append("The Definition of Done requires green CI, but this process does not require checks.")
        }
        if mode("ci") == .skip, variant.checks {
            out.append("The Definition of Done skips CI, but this process requires checks to pass.")
        }
        if mode("deploy") == .require, variant.delivery == .none {
            out.append("The Definition of Done requires a build and deploy, but this process has no delivery event.")
        }
        return out
    }

    // MARK: Where in the transitions

    /// The steps where delivery is judged and where the result is accepted, as the transition table of a type or process has them.
    struct Steps: Equatable, Sendable {
        /// "Implementing → Implemented": the work reaches a completed status, with the delivery evidence.
        var delivery: String?
        /// "Implemented → Verified"; nil when the flow has no acceptance step.
        var acceptance: String?
    }

    static func steps(in definition: IssueLifecycleDefinition) -> Steps {
        func title(_ id: String) -> String { definition.status(id)?.title ?? id }
        func order(_ ids: Set<String>) -> [String] { definition.statusIDs.filter { ids.contains($0) } }
        func text(_ rule: LifecycleRule) -> String {
            // Work under way is where delivery is judged; a step that also starts earlier (from Ready) is still named by where work is.
            let all = order(rule.from)
            let active = all.filter { definition.role(of: $0) == .active }
            let sources = active.isEmpty ? all : active
            let shown = sources.count > 2 ? "\(title(sources[0])) and \(sources.count - 1) more" : sources.map(title).joined(separator: ", ")
            return "\(shown) → \(title(rule.to))"
        }
        let completion = definition.rules.first { $0.kind == .completion && $0.needs[.system] != nil } ?? definition.rules.first { $0.kind == .completion }
        let acceptance = definition.rules.first { $0.kind == .acceptance }
        return Steps(delivery: completion.map(text), acceptance: acceptance.map(text))
    }
}
