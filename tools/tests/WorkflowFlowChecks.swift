import Foundation

// Feature workflow-flows, REQ-003: the catalogue of classic flows (Models/WorkflowFlow.swift): every flow is a valid workflow, the
// transitions generated from the roles are the ones a board has, and applying a flow keeps what is the project's own.
// Run through tools/tests/workflow-flow-tests.sh.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

let standard = ProjectWorkflow.standard

// MARK: The catalogue

check(WorkflowFlow.catalogue.map(\.id) == ["markview", "kanban", "scrum", "linear", "github-projects", "azure-agile", "shape-up", "kanban-triage"],
      "the Flow menu offers MarkView, Kanban, Scrum, Linear, GitHub Projects, Azure DevOps Agile, Shape Up and Kanban with bug triage")
check(Set(WorkflowFlow.catalogue.map(\.id)).count == WorkflowFlow.catalogue.count && Set(WorkflowFlow.catalogue.map(\.title)).count == WorkflowFlow.catalogue.count,
      "ids and titles are different")
for flow in WorkflowFlow.catalogue {
    let made = flow.applied(to: standard)
    let problems = made.validate().map(\.message)
    check(problems.isEmpty, "\(flow.title): the workflow it makes passes the workflow validation", problems.joined(separator: " | "))
    check(!flow.summary.isEmpty && !flow.origin.isEmpty, "\(flow.title): says what it is and where it comes from")
    for kind in [IssueKind.feature, .bug] {
        let roles = Set(flow.lifecycle(kind).statuses.map(\.role))
        check([LifecycleRole.notStarted, .active, .completed].allSatisfy(roles.contains), "\(flow.title): \(kind.rawValue) statuses have a waiting, a working and a finished state")
    }
}

// MARK: MarkView with specification is what every project had

check(WorkflowFlow.markView.feature == standard.feature && WorkflowFlow.markView.bug == standard.bug, "the MarkView flow is the standard workflow, unchanged")
check(WorkflowFlow.matching(standard)?.id == "markview", "a project on the standard workflow is recognised as MarkView with specification")

// MARK: Kanban

let kanban = WorkflowFlow.kanban
func rule(_ flow: WorkflowFlow, _ id: String, _ kind: IssueKind = .feature) -> LifecycleRule? { flow.lifecycle(kind).rules.first { $0.id == id } }
check(kanban.feature.statuses.map(\.id) == ["backlog", "ready", "in-progress", "in-review", "done", "wont-do"], "Kanban: Backlog, Ready, In progress, In review, Done, Won't do")
check(kanban.feature.statuses.map(\.role) == [.notStarted, .notStarted, .active, .active, .completed, .cancelled], "…waiting, waiting, working, working, finished, dropped")
check(kanban.bug == kanban.feature, "…one board for features and bugs")
let start = rule(kanban, "backlog+ready>in-progress")
check(start?.kind == .start && start?.needs[.system] == [.startEvidence], "work starts from Backlog or Ready into In progress, on start evidence, and MarkView may do it")
check(rule(kanban, "in-progress>in-review")?.kind == .spec && rule(kanban, "in-review>in-progress")?.kind == .rollback, "In progress → In review, and back")
let completion = rule(kanban, "backlog+in-progress+in-review+ready>done")
check(completion?.kind == .completion && completion?.needs.values.allSatisfy { $0 == [.deliveryEvidence] } == true, "delivery completes the work into Done from every state before it")
check(!kanban.feature.rules.contains { $0.kind == .acceptance }, "a board whose only finished state is Done has no acceptance step")
check(rule(kanban, "done>in-progress")?.kind == .reopen, "Done is reopened into In progress")
check(rule(kanban, "backlog+done+in-progress+in-review+ready>wont-do")?.kind == .cancellation && rule(kanban, "wont-do>backlog")?.kind == .reopen,
      "anything can be dropped into Won't do, and brought back to Backlog")
check(rule(kanban, "ready>backlog")?.kind == .spec && rule(kanban, "backlog>ready")?.kind == .spec, "Backlog and Ready are free to reorder")
check(rule(kanban, "backlog>ready")?.needs[.system] != nil, "…also for the app's own steps (a quick feature goes to Ready)")

// MARK: Two finished states: delivery, then acceptance

let azure = WorkflowFlow.azureAgile
check(rule(azure, "resolved>closed")?.kind == .acceptance && rule(azure, "closed>resolved")?.kind == .reopen, "Azure DevOps: Resolved is delivered, a person or an AI accepts it into Closed")
check(azure.bug.statuses.map(\.id) == ["new", "active", "resolved", "closed"], "…a bug has no Removed state")
check(!azure.bug.rules.contains { $0.kind == .cancellation }, "…so a bug has no cancellation")
let steps = WorkflowDone.steps(in: azure.feature)
check(steps.delivery == "Active → Resolved" && steps.acceptance == "Resolved → Closed", "…and the Done panel finds both steps", "\(steps)")
check(WorkflowDone.steps(in: kanban.feature).delivery == "In progress, In review → Done" && WorkflowDone.steps(in: kanban.feature).acceptance == nil,
      "Kanban: delivery is judged at In progress, In review → Done; there is no acceptance")

// MARK: Bugs that differ from features

let triage = WorkflowFlow.kanbanTriage
check(triage.feature == kanban.feature && triage.bug.statuses.map(\.id) == ["unconfirmed", "confirmed", "in-progress", "resolved", "verified", "invalid"],
      "Kanban with bug triage: features on the board, bugs Unconfirmed → Confirmed → In progress → Resolved → Verified")
check(rule(triage, "confirmed>unconfirmed", .bug)?.kind == .spec && rule(triage, "resolved>verified", .bug)?.kind == .acceptance, "…triage is a stage change, Verified is the acceptance")
check(WorkflowFlow.shapeUp.bug.statuses.map(\.id) == ["reported", "fixing", "fixed", "wont-fix"], "Shape Up: bugs are Reported, Fixing, Fixed")

// MARK: Lane titles of the flows

func lane(_ flow: WorkflowFlow, _ role: LifecycleRole) -> String { WorkflowDiagram.laneTitle(role, statuses: flow.feature.statuses, rules: flow.feature.rules) }
check(lane(kanban, .notStarted) == "To do" && lane(kanban, .active) == "In progress" && lane(kanban, .completed) == "Done",
      "Kanban lanes: To do, In progress, Done")
check(lane(WorkflowFlow.linear, .notStarted) == "Backlog & specification", "Linear: three waiting states joined by free moves form one backlog lane (Triage, Backlog, Todo)")
check(lane(WorkflowFlow.markView, .notStarted) == "Backlog & specification" && lane(WorkflowFlow.shapeUp, .notStarted) == "Backlog & specification",
      "MarkView and Shape Up: the waiting lane is where work is specified or shaped")
check(lane(WorkflowFlow.githubProjects, .notStarted) == "To do", "GitHub Projects: a single Todo is 'To do'")

// MARK: What the picker shows

check(kanban.outline(.feature) == "Backlog, Ready → In progress, In review → Done (dropped: Won't do)", "Kanban outline", kanban.outline(.feature))
check(WorkflowFlow.markView.outline(.feature) == "Idea, Exploring, Draft, Review, Resolving, Ready → Implementing → Implemented, Verified (dropped: Archived)", "MarkView outline", WorkflowFlow.markView.outline(.feature))
check(azure.outline(.bug) == "New → Active → Resolved, Closed", "a type without a dropped state has no dropped part", azure.outline(.bug))
check(!kanban.bugsDiffer && triage.bugsDiffer && WorkflowFlow.markView.bugsDiffer && WorkflowFlow.shapeUp.bugsDiffer, "the picker shows the bug outline only when bugs have states of their own")

// MARK: Applying a flow to a project

var tuned = standard
tuned.revision = 7
tuned.variants[1].integration = .pullRequest
tuned.variants[1].delivery = .githubRelease
let own = RuleVariant(id: "quick-feature", name: "Quick feature", kind: .feature, integration: .directToMain, checks: false,
                      rules: [LifecycleRule(from: ["ready"], to: "implementing", kind: .start, needs: [.human: [.startEvidence]])])
tuned.variants.append(own)
let moved = kanban.applied(to: tuned)
check(moved.revision == 7 && moved.schema == tuned.schema, "applying a flow keeps the revision, so a save still notices that the file moved on")
check(moved.name == "Kanban" && moved.feature == kanban.feature && moved.bug == kanban.bug, "…and sets the name, the statuses and the transitions")
check(moved.variant("standard-bug")?.delivery == .githubRelease && moved.variant("standard-bug")?.integration == .pullRequest,
      "a process that follows the type keeps its settings (the bug process still needs a pull request and a release)")
check(moved.variant("quick-feature") == nil, "a process with its own transitions is left out, they name the statuses of the old flow")
check(moved.validate().isEmpty, "…and the result is valid", moved.validate().map(\.message).joined(separator: " | "))

var bare = standard
bare.variants.removeAll { $0.kind == .bug }
let refilled = kanban.applied(to: bare)
check(refilled.variants(for: .bug).map(\.id) == ["standard-bug"] && refilled.defaultBugVariant == "standard-bug" && refilled.validate().isEmpty,
      "a type left without a process takes the standard one")

var lost = standard
lost.variants.removeAll { $0.id == "standard-feature" }
lost.variants.append(RuleVariant(id: "other-feature", name: "Other", kind: .feature, integration: .directToMain, checks: false))
let redefaulted = kanban.applied(to: lost)
check(redefaulted.defaultFeatureVariant == "other-feature" && redefaulted.validate().isEmpty, "a default process that no longer exists is replaced by another of its type")

check(WorkflowFlow.matching(moved)?.id == "kanban" && WorkflowFlow.matching(WorkflowFlow.scrum.applied(to: standard))?.id == "scrum", "the flow in effect is recognised by its statuses")
var edited = moved
edited.feature.statuses[0].title = "Ideas"
check(WorkflowFlow.matching(edited)?.id == "kanban", "a renamed state is still that flow (the ids and roles decide)" )

// MARK: Flows without the specification stages

let std = standard.feature
check(std.hasSpecificationStages && !kanban.feature.hasSpecificationStages && !WorkflowFlow.linear.feature.hasSpecificationStages, "only the MarkView flow has the specification stages")
check(std.entryStatus(preferring: "exploring") == "exploring" && std.entryStatus(preferring: "idea") == "idea" && std.entryStatus(preferring: "draft") == "draft",
      "a new feature keeps the stage the app asks for in the MarkView flow")
check(kanban.feature.entryStatus(preferring: "exploring") == "backlog" && WorkflowFlow.linear.feature.entryStatus(preferring: "idea") == "triage"
      && WorkflowFlow.shapeUp.feature.entryStatus(preferring: "draft") == "raw-idea" && azure.feature.entryStatus(preferring: "exploring") == "new",
      "…and the first waiting state of a board otherwise (Backlog, Triage, Raw idea, New)")
check(kanban.feature.entryStatus(preferring: "ready") == "ready", "a board that has the preferred state keeps it (Ready)")
check(kanban.bug.entryStatus(preferring: "open") == "backlog" && triage.bug.entryStatus(preferring: "open") == "unconfirmed", "a new bug takes the entry of its flow")

check(std.isPastExplore(status: "draft", requirementsApproved: true) == false && std.isPastExplore(status: "review", requirementsApproved: false) == true
      && std.isPastExplore(status: "implementing", requirementsApproved: false) == true, "with the stages, past Explore is the status, whatever the requirements")
check(kanban.feature.isPastExplore(status: "backlog", requirementsApproved: false) == false, "Kanban: a feature in Backlog with draft requirements is still in Explore")
check(kanban.feature.isPastExplore(status: "backlog", requirementsApproved: true) == true, "…and past it once every requirement is approved")
check(kanban.feature.isPastExplore(status: "in-progress", requirementsApproved: false) == true && kanban.feature.isPastExplore(status: "done", requirementsApproved: false) == true,
      "…and always once work has started or is finished")
check(kanban.feature.isPastExplore(status: "idea", requirementsApproved: false) == false, "…and a status the flow does not know is not past Explore")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
