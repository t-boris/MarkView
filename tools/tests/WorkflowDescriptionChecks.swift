// Checks the workflow in words, the differences between two workflows in words and the format guide for assistants
// (MarkView/Models/WorkflowDescription.swift; feature assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-002, REQ-003).
import Foundation

let standard = ProjectWorkflow.standard
let guide = WorkflowFormatGuide.text

// MARK: The guide names every value the code accepts

func guideNames(_ values: [String], _ what: String) {
    for value in values { check("the guide names the \(what) \(value)", guide.contains("\"\(value)\"")) }
}
guideNames(LifecycleRole.allCases.map(\.rawValue), "role")
guideNames(TransitionKind.allCases.map(\.rawValue), "kind")
guideNames(LifecycleCondition.allCases.map(\.rawValue), "condition")
guideNames(RuleEvent.known.map(\.rawValue), "event")
guideNames(StartEvidenceMode.allCases.map(\.rawValue), "start mode")
guideNames(IntegrationPath.allCases.map(\.rawValue), "integration")
guideNames(AcceptanceMode.allCases.map(\.rawValue), "acceptance mode")
guideNames(DeliveryConfirmer.allCases.map(\.rawValue), "confirmer")
guideNames(DeliveryEvent.typeNames, "delivery type")
check("every delivery type in the list decodes",
      DeliveryEvent.typeNames.allSatisfy { (try? JSONDecoder().decode(DeliveryEvent.self, from: Data("{\"type\":\"\($0)\"}".utf8))) != nil })
check("a delivery type that is not in the list does not decode", (try? JSONDecoder().decode(DeliveryEvent.self, from: Data(#"{"type":"teleport"}"#.utf8))) == nil)
check("every kind has a meaning", TransitionKind.allCases.allSatisfy { !$0.meaning.isEmpty })

for key in ["schema", "revision", "defaultFeatureVariant", "defaultBugVariant", "variants", "statuses", "rules", "confirmedBy", "markview_get_workflow",
            "markview_propose_workflow", "markview_confirm_delivery", "Workflow tab", "press Save"] {
    check("the guide mentions \(key)", guide.contains(key))
}
check("the guide says that the assistant cannot save", guide.contains("you cannot save it") && guide.contains("Do not say that it is saved"))
check("the guide says what the model cannot express", guide.contains("WHAT THE MODEL CANNOT EXPRESS") && guide.contains("do not invent a field"))
check("the guide has examples", guide.contains("EXAMPLES") && guide.contains("investigation-finished") && guide.contains("work-started"))

// The examples in the guide are real rules: build the ones it describes and validate them.
var withExamples = standard
withExamples.bug.rules.append(LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .ai: [], .system: []], event: .investigationFinished))
check("the investigation example is a valid rule", withExamples.validate().isEmpty)
withExamples.variants[1].delivery = .humanConfirmed(name: "Installed on mac")
withExamples.variants[1].confirmer = .personOrAI
check("the confirmation example is a valid process", withExamples.validate().isEmpty)

// MARK: A workflow in words

let described = WorkflowDescription.describe(standard)
check("the description names the workflow, its revision and the schema", described.contains("\u{201C}\(standard.name)\u{201D}") && described.contains("revision \(standard.revision)") && described.contains("schema 1"))
check("the description lists every status of both types", (standard.feature.statusIDs + standard.bug.statusIDs).allSatisfy { described.contains($0) })
check("the description lists the processes and their defaults", standard.variants.allSatisfy { described.contains($0.id) } && described.contains("default for bugs"))
check("a step says who may make it", WorkflowDescription.sentence(standard.bug.rules[0]).contains("a person:") && WorkflowDescription.sentence(standard.bug.rules[0]).contains("an AI:") && WorkflowDescription.sentence(standard.bug.rules[0]).contains("MarkView:"))
let eventRule = LifecycleRule(from: ["fixing"], to: "open", kind: .rollback, needs: [.human: [], .system: []], event: .workStarted)
check("a step with an event says that MarkView takes it itself", WorkflowDescription.sentence(eventRule).contains("MarkView takes this step itself when work is started"))
check("an actor without an entry is not allowed by the rules", WorkflowDescription.sentence(eventRule).contains("an AI: not by the rules"))
check("conditions are named in words", WorkflowDescription.sentence(standard.bug.rules.first { $0.kind == .completion }!).contains("delivery evidence"))

// MARK: Two workflows in words

check("a workflow has no difference from itself", WorkflowDescription.differences(from: standard, to: standard).isEmpty)
var revised = standard
revised.revision += 1
check("the revision alone is not a difference", WorkflowDescription.differences(from: standard, to: revised).isEmpty)
var changed = standard
changed.name = "Kanban"
check("a rename is told", WorkflowDescription.differences(from: standard, to: changed).contains { $0.contains("renamed") && $0.contains("Kanban") })
let newRule = LifecycleRule(from: ["fixed"], to: "fixing", kind: .spec, needs: [.human: [], .system: []], event: .workStarted)
changed.bug.rules.append(newRule)
let ruleAdded = WorkflowDescription.differences(from: standard, to: changed)
check("a new step is told with its event", ruleAdded.contains { $0.contains("Bug step added") && $0.contains("when work is started") })
var ruleChanged = changed
ruleChanged.bug.rules[ruleChanged.bug.rules.count - 1].event = .investigationFinished
check("a changed step is told", WorkflowDescription.differences(from: changed, to: ruleChanged).contains { $0.contains("Bug step fixed>fixing changes") && $0.contains("an investigation finishes") })
var ruleRemoved = changed
ruleRemoved.bug.rules.removeLast()
check("a removed step is told", WorkflowDescription.differences(from: changed, to: ruleRemoved).contains { $0.contains("Bug step removed: fixed>fixing") })

var statuses = standard
statuses.bug.statuses.append(WorkflowStatus(id: "in-review", title: "In review", role: .active))
check("a new status is told with its role", WorkflowDescription.differences(from: standard, to: statuses).contains { $0.contains("Bug status added: in-review") && $0.contains("active") })
check("a removed status says that items need a replacement",
      WorkflowDescription.differences(from: statuses, to: standard).contains { $0.contains("Bug status removed: in-review") && $0.contains("replacement") })
var retitled = standard
retitled.bug.statuses[0].title = "Reported"
retitled.bug.statuses[1] = WorkflowStatus(id: standard.bug.statuses[1].id, title: standard.bug.statuses[1].title, role: .completed)
let statusChanges = WorkflowDescription.differences(from: standard, to: retitled)
check("a renamed status and a changed role are told", statusChanges.contains { $0.contains("renamed") && $0.contains("Reported") } && statusChanges.contains { $0.contains("changes its role") })

var processes = standard
processes.variants[1].delivery = .humanConfirmed(name: "Installed on mac")
processes.variants[1].confirmer = .personOrAI
processes.variants[1].checks = false
let processChanges = WorkflowDescription.differences(from: standard, to: processes)
check("a delivery event change is told", processChanges.contains { $0.contains("the delivery event changes") && $0.contains("Installed on mac") })
check("who confirms is told", processChanges.contains { $0.contains("confirmed by \u{201C}A person, or an AI with evidence\u{201D}") })
check("a checks change is told", processChanges.contains { $0.contains("checks become not required") })
var extra = standard
extra.variants.append(RuleVariant(id: "quick-fix", name: "Quick fix", kind: .bug, integration: .directToMain, checks: false))
check("a new process is told", WorkflowDescription.differences(from: standard, to: extra).contains { $0.contains("Process added: quick-fix") })
check("a removed process says that items need a replacement", WorkflowDescription.differences(from: extra, to: standard).contains { $0.contains("Process removed: quick-fix") && $0.contains("replacement") })
var own = extra
own.variants[own.variants.count - 1].rules = standard.bug.rules
check("a process that gets its own steps is told", WorkflowDescription.differences(from: extra, to: own).contains { $0.contains("gets its own") })
var defaults = extra
defaults.defaultBugVariant = "quick-fix"
check("a new default process is told", WorkflowDescription.differences(from: extra, to: defaults).contains { $0.contains("default bug process changes") && $0.contains("quick-fix") })

finish("workflow description")
