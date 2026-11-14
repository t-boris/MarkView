// Checks the events on transition rules (MarkView/Models/WorkflowEvents.swift; feature
// assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-004, DEC-006): which step an event asks for, the command that
// makes it happen once, and the bookkeeping of merged pull requests.
import Foundation

let standard = ProjectWorkflow.standard
let inProgress = LifecycleRule(from: ["fixing"], to: "open", kind: .rollback, needs: [.human: [], .system: []], event: .workStarted)
let onMerge = LifecycleRule(from: ["fixing", "open"], to: "fixed", kind: .spec, needs: [.system: []], event: .pullRequestMerged)
let aiOnly = LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.ai: []], event: .workStarted)
var table = standard.bug
table.rules += [inProgress, onMerge, aiOnly]

check("an event finds the rule that names it and starts at the status", RuleEventPlanner.step(for: .workStarted, in: table, status: "fixing")?.id == inProgress.id)
check("the status is compared normalised", RuleEventPlanner.step(for: .workStarted, in: table, status: " Fixing ")?.id == inProgress.id)
check("an item in another status gets no step", RuleEventPlanner.step(for: .workStarted, in: table, status: "closed") == nil)
check("an event that no rule names changes nothing", RuleEventPlanner.step(for: .investigationFinished, in: table, status: "fixing") == nil)
let reviewed = LifecycleRule(from: ["backlog"], to: "ready", kind: .spec, needs: [.system: []], event: .reviewPassed)
let featureReview = IssueLifecycleDefinition(statuses: [WorkflowStatus(id: "backlog", role: .notStarted), WorkflowStatus(id: "ready", role: .notStarted)], rules: [reviewed])
check("a passed review selects the configured ready transition", RuleEventPlanner.step(for: .reviewPassed, in: featureReview, status: "backlog")?.to == "ready")
check("a rule that MarkView may not make is not an event step", RuleEventPlanner.step(for: .workStarted, in: table, status: "fixed") == nil)
check("a rule with several from-statuses applies from each", RuleEventPlanner.step(for: .pullRequestMerged, in: table, status: "open")?.to == "fixed")
check("the standard workflow has no event steps",
      RuleEvent.known.allSatisfy { event in standard.bug.statusIDs.allSatisfy { RuleEventPlanner.step(for: event, in: standard.bug, status: $0) == nil } })

var firstWins = table
firstWins.rules.insert(LifecycleRule(from: ["fixing"], to: "closed", kind: .spec, needs: [.system: []], event: .workStarted), at: 0)
check("the first rule in the table wins when two match", RuleEventPlanner.step(for: .workStarted, in: firstWins, status: "fixing")?.to == "closed")

let first = RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-1", cause: "abc")
check("the command names the event, the item and the cause", first == "event:work-started:bug:BUG-1:abc")
check("the same cause gives the same command", first == RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-1", cause: "abc"))
check("another cause, item or event gives another command",
      first != RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-1", cause: "abd")
      && first != RuleEventPlanner.command(.workStarted, kind: .bug, issue: "BUG-2", cause: "abc")
      && first != RuleEventPlanner.command(.pullRequestMerged, kind: .bug, issue: "BUG-1", cause: "abc"))
check("the reason names the event, the cause and the rule",
      RuleEventPlanner.reason(.workStarted, rule: inProgress, cause: "abc").contains("work is started")
      && RuleEventPlanner.reason(.workStarted, rule: inProgress, cause: "abc").contains("abc")
      && RuleEventPlanner.reason(.workStarted, rule: inProgress, cause: "abc").contains(inProgress.id))

var watcher = MergedPullRequestWatcher()
check("the first look at an item only records what is merged", watcher.newlyMerged(item: "BUG-1", merged: [4, 5]).isEmpty)
check("nothing new, nothing reported", watcher.newlyMerged(item: "BUG-1", merged: [4, 5]).isEmpty)
check("a pull request merged since the last look is reported once", watcher.newlyMerged(item: "BUG-1", merged: [4, 5, 7]) == [7])
check("and not again", watcher.newlyMerged(item: "BUG-1", merged: [4, 5, 7]).isEmpty)
check("several new ones come oldest number first", watcher.newlyMerged(item: "BUG-1", merged: [4, 5, 7, 9, 8]) == [8, 9])
check("another item has its own first look", watcher.newlyMerged(item: "BUG-2", merged: [1]).isEmpty && watcher.newlyMerged(item: "BUG-2", merged: [1, 2]) == [2])
check("a pull request that drops out of the list and returns is not reported twice", {
    var w = MergedPullRequestWatcher()
    _ = w.newlyMerged(item: "x", merged: [1]); _ = w.newlyMerged(item: "x", merged: [1, 2]); _ = w.newlyMerged(item: "x", merged: [1])
    return w.newlyMerged(item: "x", merged: [1, 2]).isEmpty
}())

finish("workflow events")
