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

try? fm.removeItem(at: root)
finish("project workflow")
