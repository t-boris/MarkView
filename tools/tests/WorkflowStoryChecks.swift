import Foundation

// BUG-115: a transition in plain words (Models/WorkflowTransitionStory.swift). Run through tools/tests/workflow-story-tests.sh.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

let standard = ProjectWorkflow.standard
let feature = standard.feature.rules, bug = standard.bug.rules
func rule(_ rules: [LifecycleRule], _ kind: TransitionKind, to: String? = nil) -> LifecycleRule {
    rules.first { $0.kind == kind && (to == nil || $0.to == to) }!
}
func actor(_ story: TransitionStory, _ kind: LifecycleActorKind) -> TransitionStory.ActorLine { story.actors.first { $0.actor == kind }! }

let pullRequest = RuleVariant(id: "pr", name: "Pull request, checks and a release", kind: .feature, integration: .pullRequest, checks: true,
                              delivery: .githubRelease, acceptance: .humanOnly)
let direct = RuleVariant(id: "direct", name: "Direct", kind: .feature, start: .agentOrNote, integration: .directToMain, checks: false)
let installed = RuleVariant(id: "installed", name: "Installed", kind: .feature, integration: .directToMain, checks: false,
                            delivery: .humanConfirmed(name: "installed on the other Mac"))

// MARK: Every rule of the standard workflow has a story

var told = 0
for rule in feature + bug {
    let story = TransitionStory.make(rule, processes: [])
    if !story.trigger.isEmpty && !story.label.isEmpty && story.actors.count == 3 { told += 1 }
}
check(told == feature.count + bug.count, "every rule of the standard workflow has a trigger, a label and a line for each actor (\(told) rules)")

// MARK: Completion is the step MarkView makes by itself

let completion = TransitionStory.make(rule(feature, .completion), processes: [pullRequest, direct, installed])
check(completion.automatic, "the completion step is automatic: MarkView makes it once the delivery evidence is complete")
check(completion.label == "Completion · automatic", "…and its arrow says so", completion.label)
check(actor(completion, .system).text.contains("as soon as the delivery evidence is complete"), "MarkView's line names the event", actor(completion, .system).text)
check(actor(completion, .ai).text.contains("project tools") && actor(completion, .ai).text.contains("delivery evidence"),
      "an AI may make it through the project tools, with delivery evidence", actor(completion, .ai).text)
check(completion.parts == .delivery, "completion reads the delivery settings of a process only", "\(completion.parts)")
check(completion.processes.count == 3, "every process that follows the type has its lines")

let prLines = completion.processes.first { $0.id == "pr" }!.lines
check(prLines.contains { $0.contains("pull request") && $0.contains("merged") }, "a pull-request process says every unit of work is a merged pull request", "\(prLines)")
check(prLines.contains("The required checks passed"), "…that checks must pass")
check(prLines.contains { $0.contains("GitHub release") }, "…and that a GitHub release counts as delivery")
let directLines = completion.processes.first { $0.id == "direct" }!.lines
check(directLines.contains { $0.contains("default branch") && !$0.contains("pull request that GitHub") }, "a direct process accepts work on the default branch", "\(directLines)")
check(directLines.contains("No checks are required") && directLines.contains("No delivery event"), "…with no checks and no delivery event")
check(completion.processes.first { $0.id == "installed" }!.lines.contains("A person confirms: installed on the other Mac"),
      "an event a person confirms is named")

// MARK: Acceptance

let acceptance = TransitionStory.make(rule(feature, .acceptance), processes: [pullRequest, direct])
check(!acceptance.automatic && acceptance.label == "Acceptance · person or AI", "acceptance is made by a person or an AI, not automatically", acceptance.label)
check(actor(acceptance, .ai).text.contains("acceptance evidence"), "an AI needs acceptance evidence", actor(acceptance, .ai).text)
check(!actor(acceptance, .system).allowed && actor(acceptance, .system).text.contains("not make"), "MarkView does not accept by itself")
check(acceptance.parts == .acceptance, "acceptance reads who may accept")
check(acceptance.processes.first { $0.id == "pr" }!.lines == ["Only a person accepts"], "a process that lets only a person accept says so")
check(acceptance.processes.first { $0.id == "direct" }!.lines.first?.contains("an AI with its evidence") == true, "…and one that lets an AI accept says that")

// MARK: Start, reopening, cancellation

let start = TransitionStory.make(rule(feature, .start), processes: [pullRequest, direct])
check(start.automatic && start.parts == .start, "start is automatic on a hand-off and reads how a process starts work", "\(start.label) \(start.parts)")
check(actor(start, .system).text.contains("handed to an agent"), "…MarkView names the hand-off", actor(start, .system).text)
check(start.processes.first { $0.id == "direct" }!.lines == ["Work starts with an agent session or a person's note"], "a process may let a person's note start the work")

let regression = TransitionStory.make(rule(feature, .reopen, to: "implementing"), processes: [])
check(regression.automatic && actor(regression, .system).text.contains("regression"), "a regression reopens finished work by itself", actor(regression, .system).text)
let manualReopen = TransitionStory.make(rule(feature, .reopen, to: "implemented"), processes: [])
check(!manualReopen.automatic && manualReopen.label == "Reopening · person", "reopening a verified feature is a person's step", manualReopen.label)
check(!actor(manualReopen, .ai).allowed && !actor(manualReopen, .system).allowed, "…an AI may not do it")
check(actor(manualReopen, .human).text.contains("a reason"), "…and the person gives a reason", actor(manualReopen, .human).text)

let cancel = TransitionStory.make(rule(bug, .cancellation), processes: [pullRequest, direct])
check(cancel.label == "Cancellation · person or AI" && cancel.processes.isEmpty, "cancellation names no process settings: it reads none", "\(cancel.label) \(cancel.processes)")
check(!cancel.automatic && actor(cancel, .system).allowed && actor(cancel, .system).text == "May make this step, with cancellation evidence.",
      "MarkView is allowed to cancel with evidence but nothing makes it do so by itself, so the arrow does not claim it", actor(cancel, .system).text)

// MARK: The story follows edits

var edited = rule(feature, .completion)
edited.needs[.system] = nil
let noSystem = TransitionStory.make(edited, processes: [])
check(!noSystem.automatic && noSystem.label == "Completion · person or AI", "taking MarkView off a step takes 'automatic' off its arrow", noSystem.label)
edited.needs[.human] = [.deliveryEvidence, .reason]
check(actor(TransitionStory.make(edited, processes: []), .human).text == "May make this step, with delivery evidence and a reason.", "conditions are listed in words")
edited.needs = [:]
let nobody = TransitionStory.make(edited, processes: [pullRequest])
check(nobody.label == "Completion" && nobody.processes.isEmpty && nobody.actors.allSatisfy { !$0.allowed },
      "a step nobody may make has a plain label and no process lines", nobody.label)

// MARK: Events and who confirms

let onStart = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: [], .ai: [], .system: []], event: .workStarted)
let onStartStory = TransitionStory.make(onStart, processes: [])
check(onStartStory.trigger == "When work is started", "a rule with an event says when it happens", onStartStory.trigger)
check(onStartStory.automatic && onStartStory.label.hasSuffix("· automatic"), "a rule with an event is automatic", onStartStory.label)
check(actor(onStartStory, .system).text == "Makes this step by itself as soon as work is started.", "MarkView is said to take the step when the event happens", actor(onStartStory, .system).text)
let noEvent = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: [], .ai: [], .system: []])
check(!TransitionStory.make(noEvent, processes: []).automatic && TransitionStory.make(noEvent, processes: []).trigger == TransitionStory.triggerWords(for: .spec),
      "the same rule without an event is not automatic", TransitionStory.make(noEvent, processes: []).trigger)
let eventClosed = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: []], event: .workStarted)
check(!TransitionStory.make(eventClosed, processes: []).automatic, "an event without a MarkView entry does not make the step automatic")
let eventWithEvidence = LifecycleRule(from: ["in-progress"], to: "done", kind: .completion, needs: [.system: [.deliveryEvidence]], event: .pullRequestMerged)
check(actor(TransitionStory.make(eventWithEvidence, processes: []), .system).text == "Makes this step by itself as soon as a pull request is merged and the delivery evidence is complete.",
      "an event and a condition are both named", actor(TransitionStory.make(eventWithEvidence, processes: []), .system).text)

var installedByAI = installed
installedByAI.confirmer = .personOrAI
check(TransitionStory.processLines(installedByAI, parts: .delivery).contains("A person, or an AI with its evidence, confirms: installed on the other Mac"),
      "the process line says that an AI may confirm", "\(TransitionStory.processLines(installedByAI, parts: .delivery))")
check(TransitionStory.processLines(installed, parts: .delivery).contains("A person confirms: installed on the other Mac"), "and a person only otherwise")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
