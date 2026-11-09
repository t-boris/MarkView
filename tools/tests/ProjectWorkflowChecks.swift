// Checks the project workflow (MarkView/Models/ProjectWorkflow.swift, ProjectWorkflowStore.swift) against docs/features/feature-3:
// the standard workflow, validation, rule variants and templates, the policy reading a workflow, the effect of a change on work
// items, and where the workflow is stored. The standard workflow is held equal to the old hard-coded tables by the unchanged
// policy, completion and collector suites, which now run against it.
import Foundation

let person = LifecycleActor.human("Boris")
let agent = LifecycleActor.ai("claude-code", session: "s1")
let app = LifecycleActor.system("MarkView")
let handedOff = StartEvidence.handoff(tool: "Claude Code", at: Date())
let note = StartEvidence.note(text: "Started by hand on the other Mac", by: "Boris", at: Date())
let delivered = DeliveryVerdict.complete(summary: ["merged"])
let accepted = AcceptanceEvidence(text: "Checked the result by hand", criteriaAllTicked: true)

func decide(_ workflow: ProjectWorkflow, _ kind: IssueKind, from: String, to: String, actor: LifecycleActor, variant: String? = nil,
            reason: String? = nil, force: Bool = false, evidence: LifecycleEvidence = .none) -> TransitionDecision {
    LifecyclePolicy.decide(TransitionRequest(kind: kind, issue: kind == .feature ? "f" : "BUG-001", from: from, to: to, actor: actor,
                                             reason: reason, force: force, evidence: evidence, workflow: workflow, variantID: variant))
}
func allowed(_ d: TransitionDecision) -> Bool { if case .allowed = d { return true } else { return false } }
func rejected(_ d: TransitionDecision) -> Rejection? { if case .rejected(let r) = d { return r } else { return nil } }
func basis(_ d: TransitionDecision) -> TransitionKind? { if case .allowed(let b) = d { return b.kind } else { return nil } }

let standard = ProjectWorkflow.standard

// MARK: The standard workflow

check("the standard workflow is valid", standard.validate().isEmpty)
check("the standard feature statuses are the vocabulary", standard.feature.statusIDs == FeatureVocabulary.featureStatuses)
check("the standard bug statuses are the vocabulary", standard.bug.statusIDs == FeatureVocabulary.bugStatuses)
check("implementing is active, implemented and verified are completed, archived is cancelled",
      standard.role(.feature, "implementing") == .active && standard.role(.feature, "implemented") == .completed
      && standard.role(.feature, "verified") == .completed && standard.role(.feature, "archived") == .cancelled
      && standard.role(.feature, "draft") == .notStarted)
check("fixing is active, fixed and closed are completed",
      standard.role(.bug, "fixing") == .active && standard.role(.bug, "fixed") == .completed && standard.role(.bug, "closed") == .completed
      && standard.role(.bug, "open") == .notStarted)
check("a status the workflow lacks has no role", standard.role(.feature, "shipped") == nil && !standard.lifecycle(.feature).isKnown("shipped"))
check("the completion target is read from the rules", standard.feature.completionTarget(from: "implementing") == "implemented"
      && standard.bug.completionTarget(from: "fixing") == "fixed" && standard.feature.completionTarget(from: "draft") == nil)
check("each type has its standard variant as the default",
      standard.resolvedVariant(.feature, assigned: nil)?.id == StandardWorkflow.featureVariantID
      && standard.resolvedVariant(.bug, assigned: nil)?.id == StandardWorkflow.bugVariantID)
check("a variant of the other type or a missing one falls back to the default",
      standard.resolvedVariant(.feature, assigned: StandardWorkflow.bugVariantID)?.id == StandardWorkflow.featureVariantID
      && standard.resolvedVariant(.bug, assigned: "gone")?.id == StandardWorkflow.bugVariantID)

let standardFeatureRules = standard.variant(StandardWorkflow.featureVariantID)!.deliveryRules
let standardBugRules = standard.variant(StandardWorkflow.bugVariantID)!.deliveryRules
check("the standard feature needs no pull request, checks or release",
      !standardFeatureRules.pullRequestRequired && !standardFeatureRules.checksRequired && !standardFeatureRules.githubReleaseRequired)
check("the standard bug needs a pull request and checks but no release",
      standardBugRules.pullRequestRequired && standardBugRules.checksRequired && !standardBugRules.githubReleaseRequired)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let encoded = try! encoder.encode(standard)
let decoded = try! JSONDecoder().decode(ProjectWorkflow.self, from: encoded)
check("the standard workflow survives a JSON round trip", decoded == standard)
check("the encoding is stable", (try! encoder.encode(decoded)) == encoded)

var withEvent = standard
withEvent.variants[1].delivery = .humanConfirmed(name: "installed on the other Mac")
let eventRound = try! JSONDecoder().decode(ProjectWorkflow.self, from: try! encoder.encode(withEvent))
check("a delivery event a person confirms keeps its name through JSON", eventRound.variants[1].delivery == .humanConfirmed(name: "installed on the other Mac"))
check("an unknown delivery event does not decode",
      (try? JSONDecoder().decode(DeliveryEvent.self, from: Data(#"{"type":"teleport"}"#.utf8))) == nil)

// MARK: Validation

func problems(_ change: (inout ProjectWorkflow) -> Void) -> [String] {
    var workflow = standard
    change(&workflow)
    return workflow.validate().map(\.message)
}
func mentions(_ list: [String], _ text: String) -> Bool { list.contains { $0.contains(text) } }

check("an empty name is refused", mentions(problems { $0.name = "  " }, "needs a name"))
check("duplicate status ids are refused", mentions(problems { $0.bug.statuses.append(WorkflowStatus(id: "open", role: .notStarted)) }, "different ids"))
check("a status id with spaces or capitals is refused", mentions(problems { $0.bug.statuses.append(WorkflowStatus(id: "Not Started", role: .notStarted)) }, "lower-case words"))
check("a lifecycle without an active status is refused",
      mentions(problems { $0.bug.statuses = $0.bug.statuses.map { WorkflowStatus(id: $0.id, role: $0.role == .active ? .notStarted : $0.role) } }, "Active"))
check("a lifecycle without a completed status is refused",
      mentions(problems { $0.feature.statuses = $0.feature.statuses.map { WorkflowStatus(id: $0.id, role: $0.role == .completed ? .active : $0.role) } }, "Completed"))
check("a transition to an unknown status is refused",
      mentions(problems { $0.bug.rules.append(LifecycleRule(from: ["open"], to: "nowhere", kind: .spec, needs: [.human: []])) }, "not a bug status"))
check("a transition from an unknown status is refused",
      mentions(problems { $0.bug.rules.append(LifecycleRule(from: ["nowhere"], to: "open", kind: .spec, needs: [.human: []])) }, "starts at nowhere"))
check("a transition to itself is refused",
      mentions(problems { $0.bug.rules.append(LifecycleRule(from: ["open"], to: "open", kind: .spec, needs: [.human: []])) }, "to itself"))
check("a transition listed twice is refused", mentions(problems { $0.bug.rules.append($0.bug.rules[0]) }, "listed twice"))
check("a start transition must end in an active status",
      mentions(problems { $0.bug.rules[0] = LifecycleRule(from: ["open"], to: "closed", kind: .start, needs: [.human: []]) }, "role \"Active\""))
check("a completion transition must end in a completed status",
      mentions(problems { $0.bug.rules.append(LifecycleRule(from: ["open"], to: "fixing", kind: .completion, needs: [.human: []])) }, "role \"Completed\""))
check("a lifecycle without a start transition is refused", mentions(problems { $0.bug.rules.removeAll { $0.kind == .start } }, "needs a start"))
check("a lifecycle without a completion transition is refused", mentions(problems { $0.bug.rules.removeAll { $0.kind == .completion } }, "needs a completion"))
check("a completion that MarkView may not make is refused (finished work must be recorded by the app)",
      mentions(problems { w in w.bug.rules = w.bug.rules.map { $0.kind == .completion ? LifecycleRule(from: $0.from, to: $0.to, kind: .completion, needs: [.human: $0.needs[.human] ?? []]) : $0 } }, "open to MarkView"))
check("a completion that does not require delivery evidence is refused (a role never confirms delivery)",
      mentions(problems { w in w.bug.rules = w.bug.rules.map { $0.kind == .completion ? LifecycleRule(from: $0.from, to: $0.to, kind: .completion, needs: [.human: [], .ai: [.deliveryEvidence], .system: [.deliveryEvidence]]) : $0 } }, "must require delivery evidence from human"))
check("each actor who may complete the work needs delivery evidence",
      mentions(problems { w in w.feature.rules = w.feature.rules.map { $0.kind == .completion ? LifecycleRule(from: $0.from, to: $0.to, kind: .completion, needs: [.human: [.deliveryEvidence], .ai: [.reason], .system: [.deliveryEvidence]]) : $0 } }, "must require delivery evidence from AI"))
check("the standard workflow completes on delivery evidence for everyone", standard.validate().isEmpty)
check("duplicate variant ids are refused", mentions(problems { $0.variants.append($0.variants[0]) }, "different ids"))
check("a default variant of the wrong type is refused", mentions(problems { $0.defaultBugVariant = StandardWorkflow.featureVariantID }, "default bug rule variant"))
check("a missing default variant is refused", mentions(problems { $0.defaultFeatureVariant = "gone" }, "default feature rule variant"))
check("a type without variants is refused", mentions(problems { $0.variants.removeAll { $0.kind == .bug } }, "at least one bug"))
check("a delivery event a person confirms needs a name", mentions(problems { $0.variants[1].delivery = .humanConfirmed(name: " ") }, "name of the delivery event"))
check("an unsupported schema is refused", mentions(problems { $0.schema = 99 }, "schema 99"))

// MARK: Who confirms a delivery event, and events on rules (feature assistants-confirm-delivery-with-evidence-and-propose-workflow)

let oldText = Data(ProjectWorkflowStore.text(of: standard).utf8)
check("the standard workflow writes neither confirmedBy nor an event",
      !String(decoding: oldText, as: UTF8.self).contains("confirmedBy") && !String(decoding: oldText, as: UTF8.self).contains("\"event\""))
check("a process without confirmedBy reads as a person only", standard.variants.allSatisfy { $0.confirmedBy == nil && $0.confirmer == .person })
check("the delivery rules of a process carry who confirms", standard.variants[1].deliveryRules.confirmedBy == .person)

var byAI = standard
byAI.variants[1].delivery = .humanConfirmed(name: "installed")
byAI.variants[1].confirmer = .personOrAI
let byAIRound = try! JSONDecoder().decode(ProjectWorkflow.self, from: try! encoder.encode(byAI))
check("a process that lets an AI confirm keeps it through JSON", byAIRound.variants[1].confirmer == .personOrAI && byAIRound == byAI)
check("the confirmer reaches the delivery rules", byAIRound.variants[1].deliveryRules.confirmedBy == .personOrAI)
check("the encoding uses the word person-or-ai", String(decoding: try! encoder.encode(byAI), as: UTF8.self).contains("\"confirmedBy\":\"person-or-ai\""))
byAI.variants[1].confirmer = .person
check("setting a person again clears the field, so the file is as it was", byAI.variants[1].confirmedBy == nil)
check("the description of a process says an AI may confirm",
      { var v = standard.variants[1]; v.delivery = .humanConfirmed(name: "installed"); v.confirmer = .personOrAI
        return v.description.contains("confirmed by a person or an AI with evidence") }())
check("an unknown confirmer does not decode", (try? JSONDecoder().decode(DeliveryConfirmer.self, from: Data(#""robot""#.utf8))) == nil)

// Who may confirm now (DeliveryConfirmationPolicy)
var installedRule = standard.variants[1]
installedRule.delivery = .humanConfirmed(name: "Installed on mac")
func refusal(_ actor: LifecycleActor, _ process: RuleVariant?, role: LifecycleRole? = .active, note: String = "checked") -> String? {
    DeliveryConfirmationPolicy.refusal(issue: "BUG-001", actor: actor, process: process, status: "in-progress", role: role, note: note)
}
check("a person confirms under a process that wants a person", refusal(person, installedRule) == nil)
check("an AI is refused under a process that wants a person, and is told what to ask for",
      refusal(agent, installedRule)?.contains("lets only a person confirm") == true && refusal(agent, installedRule)?.contains("Who confirms") == true)
installedRule.confirmer = .personOrAI
check("an AI confirms under a process that lets an AI", refusal(agent, installedRule) == nil)
check("a person still confirms under a process that lets an AI", refusal(person, installedRule) == nil)
check("MarkView itself never confirms a delivery event", refusal(app, installedRule) != nil)
check("a confirmation needs the work to be under way", refusal(agent, installedRule, role: .notStarted)?.contains("has not started") == true)
check("a completed item can still be confirmed", refusal(agent, installedRule, role: .completed) == nil)
check("a cancelled item cannot be confirmed", refusal(agent, installedRule, role: .cancelled) != nil)
check("an AI's confirmation needs an evidence text", refusal(agent, installedRule, note: "  ")?.contains("evidence text is required") == true)
check("a person's confirmation needs a note too", refusal(person, installedRule, note: "") != nil)
check("a process without a confirmed event has nothing to confirm", refusal(agent, standard.variants[0])?.contains("nothing to confirm") == true)
check("an item without a process has nothing to confirm", refusal(agent, nil)?.contains("nothing to confirm") == true)

let eventRule = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: [], .system: []], event: .workStarted)
check("a rule without an event is unchanged", standard.feature.rules.allSatisfy { $0.event == nil })
let eventRuleRound = try! JSONDecoder().decode(LifecycleRule.self, from: try! encoder.encode(eventRule))
check("a rule keeps its event through JSON", eventRuleRound == eventRule && eventRuleRound.event == .workStarted)
check("the event is written as its word", String(decoding: try! encoder.encode(eventRule), as: UTF8.self).contains("\"event\":\"work-started\""))
check("a rule written by an older app reads without an event",
      (try! JSONDecoder().decode(LifecycleRule.self, from: Data(#"{"from":["a"],"to":"b","kind":"spec","human":[]}"#.utf8))).event == nil)
let futureRule = try! JSONDecoder().decode(LifecycleRule.self, from: Data(#"{"from":["a"],"to":"b","kind":"spec","system":[],"event":"teleported"}"#.utf8))
check("an event this app does not know is kept as written, and is not known", futureRule.event?.rawValue == "teleported" && futureRule.event?.isKnown == false)
check("an unknown event is written back unchanged", String(decoding: try! encoder.encode(futureRule), as: UTF8.self).contains("\"event\":\"teleported\""))
check("every known event has a title and a meaning",
      RuleEvent.known.allSatisfy { !$0.title.isEmpty && !$0.meaning.isEmpty && !$0.title.contains("happens") && !$0.meaning.contains("Not known") })
check("the first events are the ones the app sees", RuleEvent.known.map(\.rawValue) == ["work-started", "investigation-finished", "pull-request-merged"])

func withRule(_ rule: LifecycleRule, kind: IssueKind = .bug) -> [String] {
    problems { w in
        if kind == .bug { w.bug.rules.append(rule) } else { w.feature.rules.append(rule) }
    }
}
// The standard bug statuses are open, fixing, fixed and closed; fixed > fixing is not a standard step, so a new rule can use it.
let ruleOnEvent = LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .system: []], event: .workStarted)
check("a rule on a known event with a system entry is valid", withRule(ruleOnEvent).isEmpty)
check("a rule on an event without a system entry is refused",
      mentions(withRule(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: []], event: .workStarted)), "does not let MarkView make the step"))
check("a rule on an unknown event is refused and names the known ones",
      mentions(withRule(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.system: []], event: RuleEvent(rawValue: "teleported"))), "does not know")
      && mentions(withRule(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.system: []], event: RuleEvent(rawValue: "teleported"))), "pull-request-merged"))
check("the investigation event is refused for features",
      mentions(withRule(LifecycleRule(from: ["ready"], to: "idea", kind: .spec, needs: [.system: []], event: .investigationFinished), kind: .feature), "exists only for bugs"))
check("the investigation event is accepted for bugs",
      withRule(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.system: []], event: .investigationFinished), kind: .bug).isEmpty)
check("an event on a process's own rules is checked like one on a type",
      mentions(problems { w in
          let kind = w.variants[1].kind
          w.variants[1].rules = w.lifecycle(kind).rules + [LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: []], event: .workStarted)]
      }, "does not let MarkView make the step"))

// MARK: Variants and templates

let templateIDs = Dictionary(uniqueKeysWithValues: VariantTemplate.allCases.map { ($0, $0.variant(kind: .feature, id: $0.rawValue)) })
check("the pull request template requires a merged pull request and checks",
      templateIDs[.pullRequestWithChecks]!.deliveryRules == DeliveryRules(integration: .pullRequest, checksRequired: true, event: .none))
check("the release template adds a published GitHub release",
      templateIDs[.pullRequestChecksRelease]!.deliveryRules.githubReleaseRequired && templateIDs[.pullRequestChecksRelease]!.deliveryRules.pullRequestRequired)
check("the direct template requires nothing but the commit", templateIDs[.directToMain]!.deliveryRules == DeliveryRules(integration: .directToMain, checksRequired: false, event: .none))
check("the manual template is started by a note and accepted by a person",
      templateIDs[.manualWork]!.start == .agentOrNote && templateIDs[.manualWork]!.acceptance == .humanOnly)
check("every template is a valid variant of a workflow",
      VariantTemplate.allCases.allSatisfy { template in
          var workflow = standard
          workflow.variants.append(template.variant(kind: .bug, id: "extra-" + template.rawValue))
          return workflow.validate().isEmpty
      })
check("the description names the integration path, checks, event, start and acceptance",
      templateIDs[.pullRequestChecksRelease]!.description.contains("Pull request") && templateIDs[.pullRequestChecksRelease]!.description.contains("checks required")
      && templateIDs[.manualWork]!.description.contains("accepted by: a person"))
check("needsGitHub is true when a pull request, checks or a release is required",
      DeliveryRules(integration: .pullRequest, checksRequired: false, event: .none).needsGitHub
      && DeliveryRules(integration: .directToMain, checksRequired: true, event: .none).needsGitHub
      && DeliveryRules(integration: .directToMain, checksRequired: false, event: .githubRelease).needsGitHub
      && !DeliveryRules(integration: .directToMain, checksRequired: false, event: .humanConfirmed(name: "x")).needsGitHub)

// MARK: The policy reads the workflow and the variant

var manual = standard
manual.variants.append(VariantTemplate.manualWork.variant(kind: .feature, id: "by-hand"))
check("the workflow with a manual variant is valid", manual.validate().isEmpty)

let startByNote = decide(manual, .feature, from: "ready", to: "implementing", actor: person, variant: "by-hand", evidence: LifecycleEvidence(start: note))
check("a person's note starts work under a variant that accepts one", allowed(startByNote) && basis(startByNote) == .start)
let startByNoteStandard = decide(manual, .feature, from: "ready", to: "implementing", actor: person, evidence: LifecycleEvidence(start: note))
check("the same note does not start work under the standard variant", rejected(startByNoteStandard)?.missing == [.startEvidence])
let startByHandoff = decide(manual, .feature, from: "ready", to: "implementing", actor: agent, variant: "by-hand", evidence: LifecycleEvidence(start: handedOff))
check("a handoff still starts work under a variant that also accepts a note", allowed(startByHandoff))

let aiAccept = decide(manual, .feature, from: "implemented", to: "verified", actor: agent, variant: "by-hand", evidence: LifecycleEvidence(acceptance: accepted))
check("an AI cannot accept under a variant that lets only a person accept", rejected(aiAccept)?.missing.contains(.humanAcceptance) == true)
let humanAccept = decide(manual, .feature, from: "implemented", to: "verified", actor: person, variant: "by-hand")
check("a person accepts under that variant", allowed(humanAccept) && basis(humanAccept) == .acceptance)
let aiAcceptStandard = decide(manual, .feature, from: "implemented", to: "verified", actor: agent, evidence: LifecycleEvidence(acceptance: accepted))
check("an AI still accepts with evidence under the standard variant", allowed(aiAcceptStandard))
let aiAcceptNoEvidence = decide(manual, .feature, from: "implemented", to: "verified", actor: agent)
check("an AI without evidence is refused under the standard variant", rejected(aiAcceptNoEvidence)?.missing.contains(.acceptanceEvidence) == true)
let forcedByPerson = decide(manual, .feature, from: "implemented", to: "draft", actor: person, variant: "by-hand", reason: "Back to the specification", force: true)
if case .overridden = forcedByPerson { check("a person may still override with a reason", true) } else { check("a person may still override with a reason", false) }

// A workflow whose statuses are named differently and sit in a different order: the policy follows roles and rules, not names.
func renamed(_ definition: IssueLifecycleDefinition, _ names: [String: String]) -> IssueLifecycleDefinition {
    IssueLifecycleDefinition(
        statuses: definition.statuses.map { WorkflowStatus(id: names[$0.id] ?? $0.id, role: $0.role) },
        rules: definition.rules.map { LifecycleRule(from: Set($0.from.map { names[$0] ?? $0 }), to: names[$0.to] ?? $0.to, kind: $0.kind, needs: $0.needs) })
}
var custom = standard
custom.bug = renamed(standard.bug, ["open": "todo", "fixing": "doing", "fixed": "done", "closed": "accepted"])
check("a bug workflow with other status names is valid", custom.validate().isEmpty)
check("roles carry over to the renamed statuses", custom.role(.bug, "doing") == .active && custom.role(.bug, "done") == .completed && custom.role(.bug, "open") == nil)
check("the renamed start is allowed with evidence", allowed(decide(custom, .bug, from: "todo", to: "doing", actor: agent, evidence: LifecycleEvidence(start: handedOff))))
check("the renamed start is refused without evidence", rejected(decide(custom, .bug, from: "todo", to: "doing", actor: agent))?.missing == [.startEvidence])
check("the old status names are unknown to the policy of the renamed workflow",
      rejected(decide(custom, .bug, from: "open", to: "fixing", actor: agent, evidence: LifecycleEvidence(start: handedOff))) != nil)
check("the renamed completion needs delivery evidence",
      rejected(decide(custom, .bug, from: "doing", to: "done", actor: app))?.missing == [.deliveryEvidence]
      && allowed(decide(custom, .bug, from: "doing", to: "done", actor: app, evidence: LifecycleEvidence(delivery: delivered))))
check("accepting the renamed completion is an acceptance", basis(decide(custom, .bug, from: "done", to: "accepted", actor: person)) == .acceptance)
check("the renamed vocabulary knows its statuses", LifecycleVocabulary.isKnown(.bug, "doing", in: custom) && !LifecycleVocabulary.isKnown(.bug, "fixing", in: custom))
check("completed and active statuses come from roles",
      LifecycleVocabulary.isCompletedStatus(.bug, "done", in: custom) && LifecycleVocabulary.isActiveStatus(.bug, "doing", in: custom)
      && !LifecycleVocabulary.isCompletedStatus(.bug, "fixed", in: custom))

// The next steps open to an actor are the rules of the workflow.
let nextFromTodo = LifecyclePolicy.nextSteps(kind: .bug, status: "todo", actor: .ai, evidence: .none, workflow: custom, variantID: nil).map(\.to)
check("the next steps from the first renamed status are read from the workflow", nextFromTodo.contains("doing") && !nextFromTodo.contains("fixing"))

// MARK: What a change does to work items

let items = [
    WorkflowItem(kind: .feature, issue: "a", status: "implemented", variant: nil),
    WorkflowItem(kind: .feature, issue: "b", status: "draft", variant: "by-hand"),
    WorkflowItem(kind: .bug, issue: "BUG-001", status: "fixing", variant: nil),
    WorkflowItem(kind: .bug, issue: "BUG-002", status: "closed", variant: nil),
]
check("a change that removes nothing used has no impact", WorkflowChange.impact(from: manual, to: manual, items: items).isEmpty)
var smaller = manual
smaller.feature.statuses.removeAll { $0.id == "implemented" }
smaller.feature.rules = smaller.feature.rules.compactMap { rule in
    guard rule.to != "implemented" else { return nil }
    var rule = rule; rule.from.remove("implemented"); return rule.from.isEmpty ? nil : rule
}
smaller.variants.removeAll { $0.id == "by-hand" }
let impact = WorkflowChange.impact(from: manual, to: smaller, items: items)
check("the removed status is listed with the items that have it", impact.statuses[.feature]?["implemented"] == ["a"])
check("the removed variant is listed with the items that use it", impact.variants["by-hand"] == ["b"])
check("an item on a default variant that still exists is not in the impact", impact.variants[StandardWorkflow.bugVariantID] == nil)
let unanswered = WorkflowChange.problems(of: impact, in: smaller, statusReplacements: [:], variantReplacements: [:], old: manual)
check("an impact without replacements is a problem for each status and variant", unanswered.count == 2)
let answered = WorkflowChange.problems(of: impact, in: smaller, statusReplacements: [.feature: ["implemented": "implementing"]],
                                       variantReplacements: ["by-hand": StandardWorkflow.featureVariantID], old: manual)
check("replacements that exist in the new workflow answer the impact", answered.isEmpty)
let wrongKind = WorkflowChange.problems(of: impact, in: smaller, statusReplacements: [.feature: ["implemented": "implementing"]],
                                        variantReplacements: ["by-hand": StandardWorkflow.bugVariantID], old: manual)
check("a variant replacement of the other type is refused", wrongKind.count == 1)
let unknownStatus = WorkflowChange.problems(of: impact, in: smaller, statusReplacements: [.feature: ["implemented": "shipped"]],
                                            variantReplacements: ["by-hand": StandardWorkflow.featureVariantID], old: manual)
check("a status replacement the new workflow lacks is refused", unknownStatus.count == 1)

// The plan a save writes before the file changes (DEC-021): one entry per affected item, in the name of the person who chose it.
let plan = WorkflowChange.plan(of: impact, old: manual, revision: 3, actor: "Boris", statusReplacements: [.feature: ["implemented": "implementing"]],
                               variantReplacements: ["by-hand": StandardWorkflow.featureVariantID])
check("the plan has one entry for each item that needs a replacement",
      plan.statuses == [PendingReplacements.Entry(kind: .feature, issue: "a", from: "implemented", to: "implementing")]
      && plan.variants == [PendingReplacements.Entry(kind: .feature, issue: "b", from: "by-hand", to: StandardWorkflow.featureVariantID)])
check("the plan names the revision the save produces and the person", plan.revision == 3 && plan.actor == "Boris" && !plan.isEmpty)
check("a replacement nobody chose gives no entry",
      WorkflowChange.plan(of: impact, old: manual, revision: 3, actor: "Boris", statusReplacements: [:], variantReplacements: [:]).isEmpty)
check("the plan survives being written and read", (try? JSONDecoder().decode(PendingReplacements.self, from: JSONEncoder().encode(plan))) == plan)

// MARK: Adoption from the Definition of Done and the guide (DEC-022)

func dod(_ items: [(String, String)]) -> Data {
    let list = items.map { #"{"id":"\#($0.0)","mode":"\#($0.1)"}"# }.joined(separator: ",")
    return Data(#"{"items":[\#(list)]}"#.utf8)
}
let plain = ProjectWorkflowStore.adopted(definition: nil, guide: nil)
check("a project without settings adopts the standard rules", plain.variants == standard.variants && plain.feature == standard.feature && plain.bug == standard.bug)
let direct = ProjectWorkflowStore.adopted(definition: dod([("pr", "skip"), ("ci", "skip")]), guide: nil)
let directBug = direct.variant(StandardWorkflow.bugVariantID)!.deliveryRules
check("skipped pull request and CI items become a direct bug variant without checks", !directBug.pullRequestRequired && !directBug.checksRequired)
check("the feature variant stays the standard one whatever the checklist says",
      direct.variant(StandardWorkflow.featureVariantID)!.deliveryRules == standardFeatureRules)
let released = ProjectWorkflowStore.adopted(definition: dod([("deploy", "require")]), guide: nil)
check("a required deploy item becomes a GitHub release for bugs", released.variant(StandardWorkflow.bugVariantID)!.deliveryRules.githubReleaseRequired)
let askDeploy = ProjectWorkflowStore.adopted(definition: dod([("deploy", "ask")]), guide: nil)
check("an ask-me deploy item is no requirement", !askDeploy.variant(StandardWorkflow.bugVariantID)!.deliveryRules.githubReleaseRequired)
let guided = ProjectWorkflowStore.adopted(definition: dod([("pr", "skip")]), guide: "Every feature and bug fix goes through a pull request.")
check("a stated guide rule still wins over a skipped item at adoption", guided.variant(StandardWorkflow.bugVariantID)!.deliveryRules.pullRequestRequired)
check("an adopted workflow is valid", [plain, direct, released, askDeploy, guided].allSatisfy { $0.validate().isEmpty })

// MARK: Storage

let fm = FileManager.default
func tempProject() -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("project-workflow-\(UUID().uuidString)")
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
let root = tempProject()
let store = ProjectWorkflowStore(projectRoot: root)

check("a project without a file has not adopted a workflow", store.load() == .missing)
check("a missing file runs on the standard rules without a problem", store.load().effective == standard && store.load().problem == nil && store.load().isEditable)

try! fm.createDirectory(at: root.appendingPathComponent(".dde"), withIntermediateDirectories: true)
try! dod([("pr", "skip"), ("ci", "skip"), ("deploy", "require")]).write(to: root.appendingPathComponent(".dde/definition-of-done.json"))
let adopted = store.adoptIfMissing(projectRoot: root)
guard case .loaded(let first) = adopted else { fatalError("adoption did not load") }
check("adoption writes revision 1", first.revision == 1 && fm.fileExists(atPath: root.appendingPathComponent(".dde/workflow/workflow.json").path))
check("adoption carries the Definition of Done into the bug variant",
      !first.variant(StandardWorkflow.bugVariantID)!.deliveryRules.pullRequestRequired && first.variant(StandardWorkflow.bugVariantID)!.deliveryRules.githubReleaseRequired)
check("the stored workflow reads back equal", store.load() == .loaded(first))
check("a project without features or bugs starts on Kanban (DEC-002)", first.name == "Kanban" && first.feature == WorkflowFlow.kanban.feature && first.bug == WorkflowFlow.kanban.bug)
check("…with the processes its own Definition of Done gave", first.variants.map(\.id) == [StandardWorkflow.featureVariantID, StandardWorkflow.bugVariantID]
      && first.defaultFeatureVariant == StandardWorkflow.featureVariantID && first.defaultBugVariant == StandardWorkflow.bugVariantID && first.validate().isEmpty)

// The Definition of Done is guidance after adoption: changing it changes nothing.
try! dod([("pr", "require"), ("ci", "require")]).write(to: root.appendingPathComponent(".dde/definition-of-done.json"))
check("a later change of the Definition of Done does not change the workflow", store.load() == .loaded(first))
check("adoption does not run again over an existing workflow", store.adoptIfMissing(projectRoot: root) == .loaded(first))

var edited = first
edited.name = "Fast lane"
edited.variants.append(VariantTemplate.pullRequestWithChecks.variant(kind: .feature, id: "pr-checks"))
let saved = try! store.save(edited, expectedRevision: 1)
check("saving raises the revision", saved.revision == 2 && saved.name == "Fast lane")
check("the saved workflow is what is read", store.load() == .loaded(saved))

var staleError: WorkflowStoreError?
do { try store.save(edited, expectedRevision: 1) } catch { staleError = error as? WorkflowStoreError }
check("saving from an older revision is refused", staleError == .stale(current: 2))

var invalid = saved
invalid.name = ""
var invalidError: WorkflowStoreError?
do { try store.save(invalid, expectedRevision: 2) } catch { invalidError = error as? WorkflowStoreError }
if case .invalid(let list)? = invalidError { check("an invalid workflow is refused with its problems", list.contains { $0.contains("needs a name") }) } else { check("an invalid workflow is refused with its problems", false) }
check("a refused save leaves the stored workflow as it was", store.load() == .loaded(saved))

let reset = try! store.resetToStandard(expectedRevision: 2)
check("resetting puts the standard rules back with a higher revision", reset.revision == 3 && reset.feature == standard.feature && reset.variants == standard.variants)

// Damaged and future files are never replaced.
let file = root.appendingPathComponent(".dde/workflow/workflow.json")
try! "{ not json".write(to: file, atomically: true, encoding: .utf8)
if case .damaged(let why) = store.load() { check("a file that is not JSON is damaged", !why.isEmpty) } else { check("a file that is not JSON is damaged", false) }
check("a damaged file runs on the standard rules and says so", store.load().effective == standard && store.load().problem?.contains("cannot be used") == true && !store.load().isEditable)
check("adoption does not overwrite a damaged file", { if case .damaged = store.adoptIfMissing(projectRoot: root) { return true } else { return false } }())
check("the damaged file is untouched", (try? String(contentsOf: file, encoding: .utf8)) == "{ not json")
var notEditable = false
do { try store.save(standard, expectedRevision: 0) } catch WorkflowStoreError.notEditable { notEditable = true } catch {}
check("a damaged file cannot be saved over", notEditable && (try? String(contentsOf: file, encoding: .utf8)) == "{ not json")

try! #"{"schema": 7, "revision": 1, "somethingNew": {"a": 1}}"#.write(to: file, atomically: true, encoding: .utf8)
check("a newer schema is reported as such, not as damage", store.load() == .unsupported(schema: 7))
check("a newer schema runs on the standard rules and says so", store.load().effective == standard && store.load().problem?.contains("newer") == true && !store.load().isEditable)

try! #"{"revision": 1}"#.write(to: file, atomically: true, encoding: .utf8)
if case .damaged(let why) = store.load() { check("a file without a schema is damaged", why.contains("schema")) } else { check("a file without a schema is damaged", false) }

var broken = standard
broken.name = ""
try! encoder.encode(broken).write(to: file)
if case .damaged(let why) = store.load() { check("a well-formed but invalid workflow is damaged with the reason", why.contains("needs a name")) } else { check("a well-formed but invalid workflow is damaged with the reason", false) }

try! fm.removeItem(at: file)
check("removing the file makes the project adopt again", store.load() == .missing)

// Which projects start on a board and which keep the specification stages (DEC-002).
func adopt(prepare: (URL) -> Void) -> ProjectWorkflow {
    let project = tempProject()
    prepare(project)
    guard case .loaded(let workflow) = ProjectWorkflowStore(projectRoot: project).adoptIfMissing(projectRoot: project) else { fatalError("adoption did not load") }
    return workflow
}
func folder(_ project: URL, _ path: String) { try! fm.createDirectory(at: project.appendingPathComponent(path), withIntermediateDirectories: true) }
func file(_ project: URL, _ path: String) {
    folder(project, (path as NSString).deletingLastPathComponent)
    try! "x".write(to: project.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
check("a project with a feature keeps the MarkView flow", adopt { folder($0, "docs/features/some-feature") }.feature == standard.feature)
check("a project with a bug report keeps the MarkView flow", adopt { file($0, "docs/bugs/BUG-001-crash.md") }.feature == standard.feature)
check("empty docs/features and docs/bugs folders still start on Kanban", adopt { folder($0, "docs/features"); folder($0, "docs/bugs") }.name == "Kanban")
check("a stray file or hidden entry in them is not an item", adopt { file($0, "docs/features/README.md"); folder($0, "docs/features/.hidden"); file($0, "docs/bugs/notes.txt") }.name == "Kanban")
check("a project with a feature keeps the standard processes and name", adopt { folder($0, "docs/features/some-feature") }.name == standard.name)

// What a new project asks of GitHub, and the template chosen for new projects (feature workflow-templates, DEC-002, DEC-004).
func needsNothing(_ workflow: ProjectWorkflow) -> Bool {
    workflow.variants.allSatisfy { $0.integration == .directToMain && !$0.checks && $0.delivery == .none && !$0.deliveryRules.needsGitHub }
}
let fresh = adopt { folder($0, "docs/features"); folder($0, "docs/bugs") }
check("a new project with nothing declared starts on Kanban whose processes ask nothing of GitHub", fresh.name == "Kanban" && needsNothing(fresh))
check("…for features and for bugs, with the standard process ids", fresh.variants.map(\.id) == [StandardWorkflow.featureVariantID, StandardWorkflow.bugVariantID] && fresh.validate().isEmpty)
let declaredPR = adopt { project in
    folder(project, ".dde")
    try! dod([("pr", "require"), ("ci", "require")]).write(to: project.appendingPathComponent(".dde/definition-of-done.json"))
}
check("a new project that saved a Definition of Done keeps what it declared", declaredPR.name == "Kanban" && declaredPR.variant(StandardWorkflow.bugVariantID)!.deliveryRules.pullRequestRequired
      && declaredPR.variant(StandardWorkflow.bugVariantID)!.checks)
let guidePR = adopt { project in
    try! "# Guide\n\nEvery feature and bug fix goes through a pull request.\n".write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
}
check("a new project whose guide says every fix goes through a pull request keeps that", guidePR.variant(StandardWorkflow.bugVariantID)!.deliveryRules.pullRequestRequired)
let casual = adopt { project in
    try! "We sometimes commit directly to main and CI is slow.\n".write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
}
check("a casual mention in the guide is not a declaration", needsNothing(casual))
check("a project that already has items keeps today's defaults: the bug process asks for a pull request and checks",
      adopt { folder($0, "docs/features/some-feature") }.variant(StandardWorkflow.bugVariantID)!.deliveryRules.pullRequestRequired)
check("isDeclared: no Definition of Done and no guide is nothing", !ProjectDeliveryPolicy.isDeclared(definition: nil, guide: nil) && !ProjectDeliveryPolicy.isDeclared(definition: nil, guide: "# Hello"))
check("isDeclared: a saved Definition of Done is a declaration", ProjectDeliveryPolicy.isDeclared(definition: dod([]), guide: nil))
check("isDeclared: CI switched off in the guide is a declaration",
      ProjectDeliveryPolicy.isDeclared(definition: nil, guide: "## CI is switched off\n\nPlease do not wait for CI.\n"))

var chosen = WorkflowFlow.scrum.applied(to: .standard)
for index in chosen.variants.indices { chosen.variants[index].integration = .pullRequest; chosen.variants[index].checks = true; chosen.variants[index].delivery = .githubRelease }
let template = WorkflowTemplate(id: "my-scrum", name: "My Scrum", note: "", savedAt: Date(timeIntervalSince1970: 1_800_000_000), workflow: chosen)
func adoptWith(_ template: WorkflowTemplate?, prepare: (URL) -> Void) -> ProjectWorkflow {
    let project = tempProject()
    prepare(project)
    guard case .loaded(let workflow) = ProjectWorkflowStore(projectRoot: project).adoptIfMissing(projectRoot: project, newProjectTemplate: template) else { fatalError("adoption did not load") }
    return workflow
}
let fromTemplate = adoptWith(template) { _ in }
check("a new project adopts the template chosen for new projects, whole", fromTemplate.name == "My Scrum" && fromTemplate.feature == chosen.feature && fromTemplate.bug == chosen.bug
      && fromTemplate.variants == chosen.variants && fromTemplate.revision == 1 && fromTemplate.validate().isEmpty)
check("…with the delivery settings it was saved with, even without GitHub", fromTemplate.variants.allSatisfy { $0.deliveryRules.needsGitHub })
check("the template wins over the project's own Definition of Done: it is what the person chose",
      adoptWith(template) { project in
          folder(project, ".dde")
          try! dod([("pr", "skip"), ("ci", "skip")]).write(to: project.appendingPathComponent(".dde/definition-of-done.json"))
      }.variants == chosen.variants)
check("a project that already has a feature is not changed by the chosen template", adoptWith(template) { folder($0, "docs/features/some-feature") }.feature == standard.feature)
check("no chosen template: the Kanban default", adoptWith(nil) { _ in }.name == "Kanban")
let existingRoot = tempProject()
let existingStore = ProjectWorkflowStore(projectRoot: existingRoot)
existingStore.adoptIfMissing(projectRoot: existingRoot)
let existingFirst = existingStore.load()
existingStore.adoptIfMissing(projectRoot: existingRoot, newProjectTemplate: template)
check("a project that has a workflow file is never changed by the chosen template", existingStore.load() == existingFirst)

// Work that survives an interruption: the adoption marker and the pending replacements.
let adoptRoot = tempProject()
let adoptStore = ProjectWorkflowStore(projectRoot: adoptRoot)
check("a project that never adopted has no assignment pending", !adoptStore.assignmentPending)
adoptStore.adoptIfMissing(projectRoot: adoptRoot)
check("adopting leaves a marker until the existing items have their variant", adoptStore.assignmentPending)
check("the marker is still there after the store is opened again", ProjectWorkflowStore(projectRoot: adoptRoot).assignmentPending)
adoptStore.clearAssignmentPending()
check("clearing the marker ends the pass for good", !adoptStore.assignmentPending && !ProjectWorkflowStore(projectRoot: adoptRoot).assignmentPending)
adoptStore.adoptIfMissing(projectRoot: adoptRoot)
check("adopting again over an existing workflow does not bring the marker back", !adoptStore.assignmentPending)

check("there is no pending plan at first", adoptStore.pending() == nil)
try! adoptStore.savePending(plan)
check("a saved plan is read back", adoptStore.pending() == plan && ProjectWorkflowStore(projectRoot: adoptRoot).pending() == plan)
adoptStore.clearPending()
check("a cleared plan is gone", adoptStore.pending() == nil)
try! "not json".write(to: adoptRoot.appendingPathComponent(".dde/workflow/pending-replacements.json"), atomically: true, encoding: .utf8)
check("a plan that cannot be read is ignored and left as it is",
      adoptStore.pending() == nil && fm.fileExists(atPath: adoptRoot.appendingPathComponent(".dde/workflow/pending-replacements.json").path))
try? fm.removeItem(at: adoptRoot)

// MARK: Processes with their own transitions (BUG-108)

// A project that has a Quick feature process: the template on top of the standard statuses.
var withQuick = ProjectWorkflow.standard
withQuick.variants.append(ProcessTemplate.quickFeature.variant(kind: .feature, id: ProcessTemplate.quickFeatureID, in: withQuick))
let quick = withQuick.variant(ProcessTemplate.quickFeatureID)!
check("a workflow with the Quick feature process is valid", withQuick.validate().isEmpty)
check("the Quick feature process has transitions of its own and the standard ones do not",
      quick.rules != nil && standard.variant(StandardWorkflow.featureVariantID)!.rules == nil)
check("a process without its own transitions reads those of its type",
      withQuick.lifecycle(.feature, variant: StandardWorkflow.featureVariantID).rules == withQuick.feature.rules
      && withQuick.lifecycle(.feature, variant: nil).rules == withQuick.feature.rules)
check("a process with its own transitions reads them, and the statuses stay those of its type",
      withQuick.lifecycle(.feature, variant: ProcessTemplate.quickFeatureID).rules == quick.rules!
      && withQuick.lifecycle(.feature, variant: ProcessTemplate.quickFeatureID).statusIDs == withQuick.feature.statusIDs)
check("a bug never takes the transitions of a feature process",
      withQuick.lifecycle(.bug, variant: ProcessTemplate.quickFeatureID).rules == withQuick.bug.rules)

// The same step is judged by the process the item follows.
check("a feature in idea goes straight to ready in the Quick feature process, as a person",
      allowed(decide(withQuick, .feature, from: "idea", to: "ready", actor: person, variant: ProcessTemplate.quickFeatureID)))
check("a feature in draft may not start without evidence in either process",
      rejected(decide(withQuick, .feature, from: "draft", to: "implementing", actor: agent, variant: ProcessTemplate.quickFeatureID)) != nil)
check("the Quick feature process lets MarkView, not only a person, move an idea to ready",
      allowed(decide(withQuick, .feature, from: "idea", to: "ready", actor: app, variant: ProcessTemplate.quickFeatureID)))
check("the Quick feature process starts from ready on a hand-off",
      allowed(decide(withQuick, .feature, from: "ready", to: "implementing", actor: agent, variant: ProcessTemplate.quickFeatureID,
                     evidence: LifecycleEvidence(start: handedOff))))
// A step that only the standard transitions have: draft → review is a specification stage there and no transition in a quick feature.
check("draft → review is a transition of the standard feature",
      allowed(decide(withQuick, .feature, from: "draft", to: "review", actor: agent, variant: StandardWorkflow.featureVariantID)))
check("draft → review is not a transition of the Quick feature process: an AI is refused, a person must force it",
      rejected(decide(withQuick, .feature, from: "draft", to: "review", actor: agent, variant: ProcessTemplate.quickFeatureID)) != nil
      && rejected(decide(withQuick, .feature, from: "draft", to: "review", actor: person, variant: ProcessTemplate.quickFeatureID)) != nil)
check("a person forces it with a reason",
      { if case .overridden = decide(withQuick, .feature, from: "draft", to: "review", actor: person, variant: ProcessTemplate.quickFeatureID,
                                     reason: "Wants a review after all", force: true) { return true } else { return false } }())
check("an item without a variant follows the default process of its type",
      allowed(decide(withQuick, .feature, from: "draft", to: "review", actor: agent)))

// What the item is offered next follows its process too.
func steps(_ variant: String?, from status: String) -> [String] {
    LifecyclePolicy.nextSteps(kind: .feature, status: status, actor: .human, evidence: .none, workflow: withQuick, variantID: variant).map(\.to)
}
check("from draft the standard feature offers the specification stages and the Quick feature process only ready",
      steps(StandardWorkflow.featureVariantID, from: "draft").contains("review") && steps(ProcessTemplate.quickFeatureID, from: "draft") == ["ready", "implementing", "implemented", "archived"]
      && !steps(ProcessTemplate.quickFeatureID, from: "draft").contains("review"))
check("the completion target reads the process too",
      withQuick.lifecycle(.feature, variant: ProcessTemplate.quickFeatureID).completionTarget(from: "implementing") == "implemented")

// A process without its own transitions is unchanged by the new field.
check("a variant without its own transitions writes no `rules` key, so an older app reads the file",
      { let object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        return (object["variants"] as! [[String: Any]]).allSatisfy { $0["rules"] == nil } }())
check("a variant with its own transitions writes them",
      { let object = try! JSONSerialization.jsonObject(with: try! encoder.encode(withQuick)) as! [String: Any]
        return (object["variants"] as! [[String: Any]]).contains { $0["id"] as? String == "quick-feature" && ($0["rules"] as? [Any])?.isEmpty == false } }())

// Validation judges the own transitions like those of a type.
var brokenProcess = withQuick
brokenProcess.variants[brokenProcess.variants.count - 1].rules = quick.rules!.filter { $0.kind != .completion }
check("a process without a completion transition is refused",
      brokenProcess.validate().contains { $0.message.contains("Quick feature") && $0.message.contains("needs a completion transition") })
brokenProcess = withQuick
brokenProcess.variants[brokenProcess.variants.count - 1].rules = quick.rules! + [LifecycleRule(from: ["draft"], to: "shipped", kind: .spec, needs: [.human: []])]
check("a process whose transition ends in a status its type lacks is refused",
      brokenProcess.validate().contains { $0.message.contains("Quick feature") && $0.message.contains("shipped") })
brokenProcess = withQuick
brokenProcess.variants[brokenProcess.variants.count - 1].rules = quick.rules!.map { rule in
    var rule = rule
    if rule.kind == .completion { rule.needs[.ai] = [] }
    return rule
}
check("a completion in a process still needs delivery evidence from everyone it lists",
      brokenProcess.validate().contains { $0.message.contains("must require delivery evidence from AI") })

// Templates.
for template in ProcessTemplate.allCases {
    for kind in [IssueKind.feature, .bug] where template.applies(to: kind) {
        var made = ProjectWorkflow.standard
        made.variants.append(template.variant(kind: kind, id: "made", in: made))
        check("a \(kind.rawValue) process from the \(template.title) template is valid", made.validate().isEmpty)
    }
}
check("Quick feature is offered for features only", ProcessTemplate.quickFeature.applies(to: .feature) && !ProcessTemplate.quickFeature.applies(to: .bug))
let copy = ProcessTemplate.standardTransitions.variant(kind: .bug, id: "copy", in: .standard)
check("the copy template starts from the transitions and the delivery rules of the type's default process",
      copy.rules == standard.bug.rules && copy.deliveryRules == standardBugRules)
check("the from-scratch template is the least a process needs: a start and a completion",
      Set(ProcessTemplate.fromScratch.variant(kind: .feature, id: "x", in: .standard).rules!.map(\.kind)) == [.start, .completion])
// A project that renamed its statuses still gets a valid process, because the template is built from roles.
var renamed = ProjectWorkflow.standard
var renamedFeature = renamed.feature
renamedFeature.statuses = [WorkflowStatus(id: "todo", role: .notStarted), WorkflowStatus(id: "doing", role: .active), WorkflowStatus(id: "done", role: .completed)]
renamedFeature.rules = ProcessTemplate.transitions(renamedFeature, quick: false)
renamed.feature = renamedFeature
renamed.variants.append(ProcessTemplate.quickFeature.variant(kind: .feature, id: "quick-feature", in: renamed))
check("the Quick feature template adapts to renamed statuses", renamed.validate().isEmpty
      && renamed.variant("quick-feature")!.rules!.contains { $0.kind == .start && $0.from == ["todo"] && $0.to == "doing" })

// Editing the draft: removing a status takes it out of the own transitions of the processes of its type.
var trimmed = withQuick
let dropped = trimmed.removeStatus("exploring", kind: .feature)
check("removing a status removes it from the type and from the own transitions of a process",
      !trimmed.feature.isKnown("exploring") && !trimmed.feature.rules.contains { $0.from.contains("exploring") || $0.to == "exploring" }
      && !trimmed.variant(ProcessTemplate.quickFeatureID)!.rules!.contains { $0.from.contains("exploring") || $0.to == "exploring" } && dropped > 0)
check("removing a status of the other type leaves the process alone",
      { var other = withQuick; other.removeStatus("closed", kind: .bug); return other.variant(ProcessTemplate.quickFeatureID)!.rules == quick.rules }())
check("a fresh process id is unique", withQuick.freshVariantID("quick-feature") == "quick-feature-2" && withQuick.freshVariantID("new") == "new")

// A process that is removed while an item follows it: the item is listed for a replacement, like any removed variant.
let followers = [WorkflowItem(kind: .feature, issue: "small", status: "ready", variant: ProcessTemplate.quickFeatureID)]
var withoutQuick = withQuick
withoutQuick.variants.removeAll { $0.id == ProcessTemplate.quickFeatureID }
check("removing a process that an item follows lists the item",
      WorkflowChange.impact(from: withQuick, to: withoutQuick, items: followers).variants[ProcessTemplate.quickFeatureID] == ["small"])

// The file: a process with its own transitions survives the round trip, an old file without the field is read as it is, and the
// source text is read by the same path as the file.
let quickFile = ProjectWorkflowStore.text(of: withQuick)
check("the source text of a workflow reads back as the same workflow",
      { if case .loaded(let back) = ProjectWorkflowStore.load(from: Data(quickFile.utf8)) { return back == withQuick } else { return false } }())
check("the source text ends with one newline and is stable", quickFile.hasSuffix("}\n") && ProjectWorkflowStore.text(of: withQuick) == quickFile)
check("a file written before processes had transitions is read unchanged",
      { if case .loaded(let old) = ProjectWorkflowStore.load(from: Data(ProjectWorkflowStore.text(of: standard).utf8)) { return old == standard && old.variants.allSatisfy { $0.rules == nil } } else { return false } }())
check("the source text that is not JSON is told apart",
      { if case .failure(.damaged(let why)) = ProjectWorkflowStore.parse(Data("{ nope".utf8)) { return why.contains("not a JSON object") } else { return false } }())
check("a source text that parses but breaks a rule is returned for the editor to judge, and the file read refuses it",
      { var invalid = standard; invalid.name = " "
        let text = Data(ProjectWorkflowStore.text(of: invalid).utf8)
        if case .success(let parsed) = ProjectWorkflowStore.parse(text), case .damaged = ProjectWorkflowStore.load(from: text) { return parsed.name == " " } else { return false } }())
check("a source text from a newer app is unsupported, not damaged",
      { if case .failure(.unsupported(let schema)) = ProjectWorkflowStore.parse(Data("{\"schema\": 99}".utf8)) { return schema == 99 } else { return false } }())

try? fm.removeItem(at: root)
finish("project workflow")
