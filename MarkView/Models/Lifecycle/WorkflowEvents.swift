import Foundation

// Events on transition rules (feature assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-004, DEC-006): which step an
// event asks for, the command that makes the step happen once, and the bookkeeping of merged pull requests. Foundation only (with
// ProjectWorkflow.swift, IssueListing.swift and IssueLifecycle.swift), so tools/tests/workflow-events-tests.sh compiles it on its own.
// The coordinator (FeatureStore+Lifecycle.swift) applies the step; nothing here writes a file.

enum RuleEventPlanner {
    /// The step MarkView makes when `event` happens to an item in `status`: the first rule of the item's transition table that names
    /// the event, starts at `status` and lets MarkView (the system actor) make the step. nil when there is none, so an event that no
    /// rule names, or that happens to an item in another status, changes nothing.
    static func step(for event: RuleEvent, in definition: IssueLifecycleDefinition, status: String) -> LifecycleRule? {
        let value = IssueStatus.normalize(status)
        return definition.rules.first { $0.event == event && $0.from.contains(value) && $0.needs[.system] != nil }
    }

    /// The command id of the step. The same event with the same cause answers the same command, so the step is made once: a person
    /// who moved the item back is not overridden by the event that has already been answered, and an event step never starts a
    /// chain of steps (the next one would carry the same command).
    static func command(_ event: RuleEvent, kind: IssueKind, issue: String, cause: String) -> String {
        "event:\(event.rawValue):\(kind.rawValue):\(issue):\(cause)"
    }

    /// What the history says about the step.
    static func reason(_ event: RuleEvent, rule: LifecycleRule, cause: String) -> String {
        "After the event \u{201C}\(event.title)\u{201D} (\(cause)) the rule \(rule.id) moved the item."
    }
}

/// The pull requests of each item that have been seen merged since MarkView started. The first look at an item only records what is
/// merged already, so a pull request that was merged before MarkView looked, or before a rule was saved, is not an event.
struct MergedPullRequestWatcher {
    private var seen: [String: Set<Int>] = [:]

    /// The numbers in `merged` that were not merged at the previous look at `item`, oldest number first.
    mutating func newlyMerged(item: String, merged: Set<Int>) -> [Int] {
        defer { seen[item] = merged.union(seen[item] ?? []) }
        guard let before = seen[item] else { return [] }
        return merged.subtracting(before).sorted()
    }
}
