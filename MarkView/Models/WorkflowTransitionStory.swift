import Foundation

// A transition of the workflow in plain words (BUG-115): what makes the step happen, who may make it and on which evidence, and what
// the project's processes add to that evidence (how the work reaches the default branch, whether checks must pass, which event counts
// as delivery, who accepts, how work starts). The diagram labels its arrows with it and the arrow's card shows it in full.
//
// Nothing here is stored: the story is read from the rule (`LifecycleRule.needs`) and from the processes that follow it
// (`RuleVariant`), so it changes when either is edited. Foundation only (with FeatureVocabulary.swift, IssueListing.swift,
// ProjectWorkflow.swift and IssueLifecycle.swift), so tools/tests/workflow-story-tests.sh compiles it on its own.

/// Which settings of a process a transition depends on. They follow the conditions of the rule, so a rule that needs no delivery
/// evidence shows no delivery settings.
struct ProcessParts: OptionSet, Equatable, Sendable {
    let rawValue: Int
    /// How work starts: the start evidence a process accepts.
    static let start = ProcessParts(rawValue: 1)
    /// How the work reaches the default branch, the checks and the delivery event.
    static let delivery = ProcessParts(rawValue: 2)
    /// Who may accept the result.
    static let acceptance = ProcessParts(rawValue: 4)
    /// Every setting: the Processes page shows them all.
    static let all: ProcessParts = [.start, .delivery, .acceptance]
}

struct TransitionStory: Equatable, Sendable {
    struct ActorLine: Equatable, Sendable {
        var actor: LifecycleActorKind
        /// "A person", "An AI", "MarkView".
        var name: String
        /// False when the rules do not let this actor make the step.
        var allowed: Bool
        var text: String
    }

    struct ProcessLine: Equatable, Sendable {
        var id: String
        var name: String
        /// What this process requires for the step, one fact per line.
        var lines: [String]
    }

    /// What happens, in a few words: "The work is delivered".
    var trigger: String
    /// The text on the arrow: "Completion · automatic".
    var label: String
    /// True when MarkView moves the item by itself once the evidence is there.
    var automatic: Bool
    var actors: [ActorLine]
    var parts: ProcessParts
    var processes: [ProcessLine]

    /// The story of `rule`, with the process lines of `processes` (those that follow the transitions it belongs to).
    static func make(_ rule: LifecycleRule, processes: [RuleVariant]) -> TransitionStory {
        let used = processParts(of: rule)
        let actors = [LifecycleActorKind.human, .ai, .system].map { line($0, rule) }
        let automatic = isAutomatic(rule)
        return TransitionStory(
            trigger: rule.event.map { "When \($0.title)" } ?? triggerWords(for: rule.kind), label: labelWords(for: rule, automatic: automatic),
            automatic: automatic, actors: actors,
            parts: used,
            processes: processes.compactMap { variant in
                let lines = processLines(variant, parts: used)
                return lines.isEmpty ? nil : ProcessLine(id: variant.id, name: variant.name, lines: lines)
            })
    }

    /// The settings of a process that this rule reads, from the conditions it names.
    static func processParts(of rule: LifecycleRule) -> ProcessParts {
        let all = rule.needs.values.flatMap { $0 }
        var parts: ProcessParts = []
        if all.contains(.startEvidence) { parts.insert(.start) }
        if all.contains(.deliveryEvidence) { parts.insert(.delivery) }
        if all.contains(.acceptanceEvidence) || all.contains(.humanAcceptance) || rule.kind == .acceptance { parts.insert(.acceptance) }
        return parts
    }

    // MARK: Words

    static func triggerWords(for kind: TransitionKind) -> String {
        switch kind {
        case .spec: return "The item moves between specification stages"
        case .start: return "Work on the item starts"
        case .completion: return "The work is delivered"
        case .acceptance: return "The result is accepted"
        case .reopen: return "Finished work is reopened"
        case .rollback: return "Work goes back to an earlier stage"
        case .cancellation: return "The item is dropped before it is finished"
        case .archive: return "The finished item is archived"
        case .unlisted, .replacement: return "A person overrides the workflow"
        }
    }

    /// The step and who moves it: "Completion · automatic", "Acceptance · person or AI", "Reopening · person".
    static func labelWords(for rule: LifecycleRule, automatic: Bool) -> String {
        let name = rule.kind.editorTitle
        if automatic { return name + " · automatic" }
        switch (rule.needs[.human] != nil, rule.needs[.ai] != nil) {
        case (true, true): return name + " · person or AI"
        case (true, false): return name + " · person"
        case (false, true): return name + " · AI"
        case (false, false): return rule.needs[.system] != nil ? name + " · MarkView" : name
        }
    }

    /// The events MarkView watches for and acts on by itself: a hand-off or an attached session starts the work, complete delivery
    /// evidence completes it and a regression report reopens it (FeatureStore+Lifecycle). A condition without an event here is
    /// something a person or an AI supplies, so a rule that lists MarkView with such a condition only allows it.
    static func event(_ condition: LifecycleCondition) -> String? {
        switch condition {
        case .startEvidence: return "the item is handed to an agent or an agent session attaches to it"
        case .deliveryEvidence: return "the delivery evidence is complete"
        case .regressionEvidence: return "a bug report names the item as a regression"
        case .acceptanceEvidence, .cancellationEvidence, .reason, .listedTransition, .humanAcceptance: return nil
        }
    }

    /// True when MarkView moves the item by itself: its conditions are all events it watches for.
    static func isAutomatic(_ rule: LifecycleRule) -> Bool {
        guard let needs = rule.needs[.system] else { return false }
        // A rule that names an event is taken by MarkView when the event happens, whatever else it asks for that MarkView watches.
        if rule.event != nil { return needs.allSatisfy { event($0) != nil } }
        return !needs.isEmpty && needs.allSatisfy { event($0) != nil }
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func line(_ actor: LifecycleActorKind, _ rule: LifecycleRule) -> ActorLine {
        let name: String
        switch actor {
        case .human: name = "A person"
        case .ai: name = "An AI"
        case .system: name = "MarkView"
        }
        guard let needs = rule.needs[actor] else {
            let text: String
            switch actor {
            case .human: text = "The rules do not offer this step; a person can still force it, with a reason."
            case .ai: text = "May not make this step."
            case .system: text = "Does not make this step by itself."
            }
            return ActorLine(actor: actor, name: name, allowed: false, text: text)
        }
        let needed = list(needs.map(\.words))
        let text: String
        switch actor {
        case .human:
            text = needs.isEmpty ? "May make this step." : "May make this step, with \(needed)."
        case .ai:
            let base = "May make this step through MarkView's project tools"
            text = needs.isEmpty ? base + "." : base + ", with \(needed)."
        case .system:
            if isAutomatic(rule) {
                var moments = rule.event.map { ["\($0.title)"] } ?? []
                moments += needs.compactMap(event)
                text = "Makes this step by itself as soon as " + list(moments) + "."
            } else {
                text = needs.isEmpty ? "May make this step." : "May make this step, with \(needed)."
            }
        }
        return ActorLine(actor: actor, name: name, allowed: true, text: text)
    }

    /// What one process requires for the step, limited to the settings the rule reads.
    static func processLines(_ variant: RuleVariant, parts: ProcessParts) -> [String] {
        var lines: [String] = []
        if parts.contains(.start) {
            lines.append(variant.start == .agentSession ? "Work starts with an agent session"
                                                        : "Work starts with an agent session or a person's note")
        }
        if parts.contains(.delivery) {
            lines.append(variant.integration == .pullRequest ? "Every unit of work is a pull request that GitHub confirms merged"
                                                             : "The work is on the default branch (a direct commit or a merged pull request)")
            lines.append(variant.checks ? "The required checks passed" : "No checks are required")
            switch variant.delivery {
            case .none: lines.append("No delivery event")
            case .githubRelease: lines.append("A GitHub release that contains the work is published")
            case .humanConfirmed(let name):
                let who = variant.confirmer == .personOrAI ? "A person, or an AI with its evidence, confirms" : "A person confirms"
                lines.append(name.trimmingCharacters(in: .whitespaces).isEmpty ? "\(who) the delivery event" : "\(who): \(name)")
            }
        }
        if parts.contains(.acceptance) {
            lines.append(variant.acceptance == .humanOnly ? "Only a person accepts"
                                                          : "A person accepts, or an AI with its evidence and every criterion ticked")
        }
        return lines
    }
}
