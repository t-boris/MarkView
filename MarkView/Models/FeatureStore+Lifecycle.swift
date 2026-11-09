import Foundation

/// The one place where the status of a feature or a bug changes (issue-lifecycle-management, REQ-001, plan I-3). It owns the
/// project's `IssueTransitionService` (journal `.dde/lifecycle/transitions.jsonl`, status stored in the Markdown front matter),
/// the session links, and the glue that turns a request from the window, an agent tool, a hand-off or the GitHub sync into
/// evidence and a `TransitionRequest`. Every writer calls `transition` or `request`; a status written any other way is found by
/// `reconcileLocal` and recorded as an unverified external edit (DEC-015).
@MainActor
final class IssueLifecycleCoordinator {
    private unowned let store: FeatureStore

    private struct Parts {
        var root: String
        var service: IssueTransitionService
        var statuses: MarkdownIssueStatusStore
        var sessions: SessionLinkStore
        var workflowStore: ProjectWorkflowStore
        /// What the workflow file held when it was last read (feature-3, DEC-026).
        var workflow: WorkflowLoad
    }

    private var cached: Parts?
    private var reconciling = false
    private var progressTask: Task<Void, Never>?
    /// When each item under way was last looked at for completion ("bug:BUG-012").
    private var lastProgressCheck: [String: Date] = [:]
    private static let progressInterval: TimeInterval = 300

    init(store: FeatureStore) { self.store = store }

    private var parts: Parts? {
        guard let root = store.root else { return nil }
        let key = root.standardizedFileURL.path
        if let cached, cached.root == key { return cached }
        let folder = root.appendingPathComponent(".dde/lifecycle", isDirectory: true)
        let statuses = MarkdownIssueStatusStore(root: root)
        let workflowStore = ProjectWorkflowStore(projectRoot: root)
        let load = readWorkflow(workflowStore, root: root)
        let made = Parts(root: key,
                         service: IssueTransitionService(storage: FileTransitionStorage(url: folder.appendingPathComponent("transitions.jsonl")), statuses: statuses),
                         statuses: statuses,
                         sessions: SessionLinkStore(url: folder.appendingPathComponent("sessions.jsonl")),
                         workflowStore: workflowStore, workflow: load)
        cached = made
        return made
    }

    // MARK: - The project workflow (feature-3)

    /// What the workflow file holds now: loaded, not adopted yet, damaged, or from a newer app.
    var workflowLoad: WorkflowLoad { parts?.workflow ?? .missing }

    /// The workflow that decides transitions now. When the file cannot be used this is the built-in standard workflow, and
    /// `workflowProblem` says so (DEC-026).
    var workflow: ProjectWorkflow { workflowLoad.effective }

    var workflowProblem: String? { workflowLoad.problem }

    var workflowStore: ProjectWorkflowStore? { parts?.workflowStore }

    /// What the workflow file holds. A project that records its lifecycle adopts the standard workflow the first time it is opened
    /// and again whenever an adoption could not be written (DEC-022, DEC-024); a draft that is not a project yet, or a plain folder
    /// opened as a viewer, gets no files.
    private func readWorkflow(_ workflowStore: ProjectWorkflowStore, root: URL) -> WorkflowLoad {
        let load = workflowStore.load()
        if case .missing = load, store.recordsLifecycle {
            return workflowStore.adoptIfMissing(projectRoot: root, newProjectTemplate: WorkflowTemplateStore.shared.defaultTemplate())
        }
        return load
    }

    /// Reads the file again, so that a repair made outside the app takes effect.
    func reloadWorkflow() {
        guard var current = cached ?? parts, let root = store.root else { return }
        current.workflow = readWorkflow(current.workflowStore, root: root)
        cached = current
        store.objectWillChange.send()
    }

    /// The variant assigned to an item, else the default of its type.
    func variant(_ kind: IssueKind, _ issue: String) -> RuleVariant? {
        workflow.resolvedVariant(kind, assigned: history(kind, issue)?.assignedVariant)
    }

    /// The assigned variant id, nil when none was assigned (the item follows the default of its type).
    func assignedVariantID(_ kind: IssueKind, _ issue: String) -> String? { history(kind, issue)?.assignedVariant }

    /// Records the variant of an item. Only a person picks one (DEC-019); the variant must exist for the type of the item.
    @discardableResult
    func assignVariant(_ kind: IssueKind, _ issue: String, to variantID: String, by actor: LifecycleActor, reason: String? = nil) -> Bool {
        guard let parts, actor.kind == .human, let chosen = workflow.variant(variantID), chosen.kind == kind else { return false }
        let previous = parts.service.history(kind, issue).assignedVariant
        let wrote = parts.service.recordAssignment(kind, issue, variant: variantID, previous: previous, actor: actor, reason: reason,
                                                   workflowRevision: workflow.revision) != nil
        if wrote { store.objectWillChange.send() }
        return wrote || previous == variantID
    }

    /// A feature made by the Quick Feature intake follows the project's Quick feature process when the project has one (BUG-108). The
    /// intake is a person's choice, so the assignment is made in their name; without such a process the feature keeps the default.
    func assignQuickFeatureProcess(_ slug: String) {
        guard workflow.variant(ProcessTemplate.quickFeatureID)?.kind == .feature else { return }
        assignVariant(.feature, slug, to: ProcessTemplate.quickFeatureID, by: .human(store.lifecycleActor),
                      reason: "Created from the Quick Feature intake.")
    }

    /// Gives every item without a variant the standard one of its type, once, when the workflow was adopted (DEC-024). The default
    /// of a type may change later; the items that existed keep how they were treated before. The marker file survives a quit: the
    /// pass is repeated at each start until every item has its variant, and only after the project's items were read at least once.
    private func assignExistingItems(parts: Parts) {
        guard store.hasLoaded, parts.workflowStore.assignmentPending else { return }
        let complete = parts.service.recordInitialAssignments(
            items().map { (kind: $0.kind, issue: $0.issue) },
            variantFor: { $0 == .feature ? StandardWorkflow.featureVariantID : StandardWorkflow.bugVariantID },
            actor: .system("MarkView"), reason: "The standard workflow was adopted.", workflowRevision: workflow.revision)
        if complete { parts.workflowStore.clearAssignmentPending() }
    }

    /// The statuses of a type with the transitions of the process an item follows: its assigned variant's own, else the type's. With
    /// no item (`issue` nil) the default process of the type answers.
    func lifecycle(_ kind: IssueKind, of issue: String?) -> IssueLifecycleDefinition {
        workflow.lifecycle(kind, variant: issue.flatMap { history(kind, $0)?.assignedVariant })
    }

    /// The status a start moves an item to from `status`, as the workflow has it; nil when it has no start from there.
    func startTarget(_ kind: IssueKind, from status: String, issue: String? = nil) -> String? {
        let normalized = LifecycleVocabulary.normalize(status)
        return lifecycle(kind, of: issue).rules.first { $0.kind == .start && $0.from.contains(normalized) }?.to
    }

    /// The status the workflow lets `actor` end an item in from its status through a step of one of `kinds`: a cancellation
    /// closes a bug that needs no fix or archives a feature; an acceptance closes a fixed bug.
    func endingTarget(_ kind: IssueKind, _ issue: String, actor: LifecycleActorKind, via kinds: Set<TransitionKind>) -> String? {
        guard let stored = storedStatus(kind, issue) else { return nil }
        let normalized = LifecycleVocabulary.normalize(stored)
        return lifecycle(kind, of: issue).rules.first { kinds.contains($0.kind) && $0.from.contains(normalized) && $0.needs[actor] != nil }?.to
    }

    func cancellationTarget(_ kind: IssueKind, _ issue: String, actor: LifecycleActorKind) -> String? {
        endingTarget(kind, issue, actor: actor, via: [.cancellation])
    }

    /// The status a reopening by MarkView (a regression report) moves a completed item to.
    private func regressionTarget(_ kind: IssueKind, _ issue: String, from status: String) -> String? {
        let normalized = LifecycleVocabulary.normalize(status)
        return lifecycle(kind, of: issue).rules.first { $0.kind == .reopen && $0.from.contains(normalized) && $0.needs[.system] != nil }?.to
    }

    private func workflowItems() -> [WorkflowItem] {
        guard let service = parts?.service else { return [] }
        let all = service.records()
        return items().map {
            WorkflowItem(kind: $0.kind, issue: $0.issue, status: $0.status, variant: IssueHistory(kind: $0.kind, issue: $0.issue, all: all).assignedVariant)
        }
    }

    /// Gives sync items the role their status has in the project's workflow, so that "done" follows roles (REQ-006).
    func withRoles(_ items: [IssueSyncItem]) -> [IssueSyncItem] {
        let workflow = workflow
        return items.map { item in
            var copy = item
            copy.role = workflow.role(item.kind == .feature ? .feature : .bug, IssueStatus.normalize(item.status))
            return copy
        }
    }

    /// What saving `changed` would take away from items that use it: the statuses and variants they have that `changed` lacks.
    func workflowImpact(of changed: ProjectWorkflow) -> WorkflowImpact {
        WorkflowChange.impact(from: workflow, to: changed, items: workflowItems())
    }

    struct WorkflowSaveReport: Equatable {
        var workflow: ProjectWorkflow
        var statusesReplaced = 0
        var variantsReplaced = 0
        /// Items that could not be moved; each line says which and why. The workflow itself is saved.
        var failures: [String] = []
    }

    /// Saves a changed workflow (REQ-001, DEC-021, DEC-029). A person must have chosen a replacement for every in-use status and
    /// variant the change removes. The file is saved first; then the items are re-assigned and moved, each by a record of its own
    /// kind that keeps the earlier history. Only a person changes the workflow.
    func saveWorkflow(_ changed: ProjectWorkflow, statusReplacements: [IssueKind: [String: String]] = [:],
                      variantReplacements: [String: String] = [:], by actor: LifecycleActor) -> Result<WorkflowSaveReport, WorkflowStoreError> {
        guard let parts, store.recordsLifecycle else { return .failure(.notEditable("This window has no project folder open.")) }
        guard actor.kind == .human else { return .failure(.notEditable("Only a person changes the workflow.")) }
        guard parts.workflow.isEditable else { return .failure(.notEditable(parts.workflow.problem ?? "The workflow file cannot be edited.")) }
        let current = workflow
        let invalid = changed.validate()
        guard invalid.isEmpty else { return .failure(.invalid(invalid.map(\.message))) }
        let impact = WorkflowChange.impact(from: current, to: changed, items: workflowItems())
        let missing = WorkflowChange.problems(of: impact, in: changed, statusReplacements: statusReplacements,
                                              variantReplacements: variantReplacements, old: current)
        guard missing.isEmpty else { return .failure(.invalid(missing.map(\.message))) }

        // What the save owes the items is written before the file changes, so a save that is interrupted, or an item that cannot be
        // moved now, is finished at the next start instead of leaving the item on a status the workflow no longer has.
        let plan = WorkflowChange.plan(of: impact, old: current, revision: changed.revision + 1, actor: actor.name,
                                       statusReplacements: statusReplacements, variantReplacements: variantReplacements)
        if !plan.isEmpty {
            do { try parts.workflowStore.savePending(plan) } catch { return .failure(.writeFailed(error.localizedDescription)) }
        }
        // The change is made on top of the revision the person edited: if the file moved on meanwhile (another window, an edit by hand),
        // the save is refused instead of overwriting that change.
        let saved: ProjectWorkflow
        do { saved = try parts.workflowStore.save(changed, expectedRevision: changed.revision) } catch let error as WorkflowStoreError {
            parts.workflowStore.clearPending()
            return .failure(error)
        } catch {
            parts.workflowStore.clearPending()
            return .failure(.writeFailed(error.localizedDescription))
        }
        cached?.workflow = .loaded(saved)

        var report = WorkflowSaveReport(workflow: saved)
        let outcome = carryOut(plan, workflow: saved, parts: parts)
        report.statusesReplaced = outcome.statusesReplaced
        report.variantsReplaced = outcome.variantsReplaced
        report.failures = outcome.failures
        store.objectWillChange.send()
        return .success(report)
    }

    struct ReplacementOutcome: Equatable {
        var statusesReplaced = 0
        var variantsReplaced = 0
        var failures: [String] = []
    }

    /// Moves the items a save owes a replacement, in the name of the person who chose it (DEC-021). It can be repeated: an item that
    /// already left the removed status or variant is skipped. What could not be done stays in the pending file for the next start.
    private func carryOut(_ plan: PendingReplacements, workflow saved: ProjectWorkflow, parts: Parts) -> ReplacementOutcome {
        var outcome = ReplacementOutcome()
        guard !plan.isEmpty else { return outcome }
        let actor = LifecycleActor.human(plan.actor)
        var remaining = PendingReplacements(revision: plan.revision, actor: plan.actor)
        for entry in plan.variants {
            let assigned = parts.service.history(entry.kind, entry.issue).assignedVariant
            if let assigned, assigned != entry.from { continue }
            let wrote = parts.service.recordAssignment(entry.kind, entry.issue, variant: entry.to, previous: entry.from, actor: actor,
                                                       reason: "The variant \"\(entry.from)\" was removed from the workflow.",
                                                       workflowRevision: saved.revision)
            if wrote != nil {
                outcome.variantsReplaced += 1
            } else {
                outcome.failures.append("\(entry.issue): the new variant could not be recorded.")
                remaining.variants.append(entry)
            }
        }
        for entry in plan.statuses {
            // An item that is gone, or already left the removed status, needs nothing.
            guard let stored = parts.statuses.status(kind: entry.kind, issue: entry.issue),
                  LifecycleVocabulary.normalize(stored) == LifecycleVocabulary.normalize(entry.from) else { continue }
            let variant = saved.resolvedVariant(entry.kind, assigned: parts.service.history(entry.kind, entry.issue).assignedVariant)?.id
            let result = parts.service.applyReplacement(entry.kind, entry.issue, from: entry.from, to: entry.to, actor: actor,
                                                        reason: "The status \"\(entry.from)\" was removed from the workflow.",
                                                        workflowRevision: saved.revision, variant: variant)
            if result.reachedStatus {
                outcome.statusesReplaced += 1
            } else {
                outcome.failures.append("\(entry.issue): \(result.explanation)")
                remaining.statuses.append(entry)
            }
        }
        if remaining.isEmpty { parts.workflowStore.clearPending() } else { try? parts.workflowStore.savePending(remaining) }
        if outcome.statusesReplaced > 0 { store.reloadSync() }
        return outcome
    }

    /// Finishes a save that was interrupted, or whose items could not all be moved (DEC-021). A plan whose revision the workflow file
    /// never reached belongs to a save that did not happen and is dropped.
    private func resumePendingReplacements(parts: Parts) {
        guard let plan = parts.workflowStore.pending() else { return }
        guard case .loaded(let saved) = parts.workflow else { return }
        guard saved.revision >= plan.revision else { parts.workflowStore.clearPending(); return }
        let outcome = carryOut(plan, workflow: saved, parts: parts)
        if !outcome.failures.isEmpty {
            store.lastError = "Some work items could not be moved to the replacement chosen when the workflow was saved: " + outcome.failures.prefix(3).joined(separator: " ")
        }
    }

    var service: IssueTransitionService? { parts?.service }
    var sessions: SessionLinkStore? { parts?.sessions }

    // MARK: - Reading

    func storedStatus(_ kind: IssueKind, _ issue: String) -> String? { parts?.statuses.status(kind: kind, issue: issue) }

    func history(_ kind: IssueKind, _ issue: String) -> IssueHistory? { parts?.service.history(kind, issue) }

    /// Whether the status of the item is backed by evidence (DEC-010), judged from its history.
    func completion(_ kind: IssueKind, _ issue: String, status: String, delivery: DeliveryVerdict? = nil) -> IssueCompletionState {
        guard let history = history(kind, issue) else { return .unknown("The project has no lifecycle history yet.") }
        return IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery, workflow: workflow)
    }

    static func label(_ state: IssueCompletionState) -> String {
        switch state {
        case .verified: return "verified completion"
        case .notComplete: return "not complete"
        case .cancelled(let why): return "cancelled (\(why))"
        case .overridden: return "completed by an override, not verified"
        case .unverifiedEdit: return "status edited outside MarkView, not verified"
        case .unknown(let why): return "unknown (\(why))"
        }
    }

    // MARK: - One transition, no evidence collection

    /// Applies one transition now. For the steps that need no delivery evidence (specification stages, start by hand-off,
    /// rollback, cancellation, acceptance with its evidence in `evidence`). `from` is the status the caller saw; a different
    /// stored status makes the request stale instead of overwriting someone else's change.
    @discardableResult
    func transition(_ kind: IssueKind, _ issue: String, to status: String, actor: LifecycleActor, reason: String? = nil, force: Bool = false,
                    evidence: LifecycleEvidence = .none, from seen: String? = nil, command: String = UUID().uuidString,
                    surface: Bool = true) -> ApplyResult {
        guard let parts, let stored = parts.statuses.status(kind: kind, issue: issue) else {
            return finish(.failed("\(issue) was not found in this project."), surface: surface)
        }
        parts.service.recordBaseline(kind, issue, status: stored)
        let request = TransitionRequest(command: command, kind: kind, issue: issue, from: seen ?? stored, to: status, actor: actor,
                                        reason: reason, force: force, evidence: evidence, workflow: workflow,
                                        variantID: parts.service.history(kind, issue).assignedVariant)
        let result = parts.service.apply(request)
        if result.reachedStatus { store.reloadSync(kind == .feature ? issue : nil) }
        return finish(result, surface: surface)
    }

    private func finish(_ result: ApplyResult, surface: Bool) -> ApplyResult {
        switch result {
        case .rejected, .stale, .failed, .unrecorded:
            if surface { store.lastError = result.explanation }
        default: break
        }
        return result
    }

    // MARK: - One transition with its evidence

    /// Applies a transition and gathers what the target status needs: the delivery evidence for `implemented` and `fixed`
    /// (git and GitHub are read off the main thread), acceptance and cancellation evidence from what the caller gives, the
    /// start evidence of attached sessions, and a regression report that names the issue.
    func request(_ kind: IssueKind, _ issue: String, to status: String, actor: LifecycleActor, reason: String? = nil, force: Bool = false,
                 acceptance: String? = nil, cancellation: CancellationEvidence? = nil, command: String = UUID().uuidString,
                 surface: Bool = true) async -> ApplyResult {
        guard let parts, let stored = parts.statuses.status(kind: kind, issue: issue) else {
            return finish(.failed("\(issue) was not found in this project."), surface: surface)
        }
        let target = LifecycleVocabulary.normalize(status)
        var evidence = LifecycleEvidence(start: startEvidence(kind, issue, parts: parts),
                                         acceptance: acceptanceEvidence(kind, issue, text: acceptance),
                                         regression: regressionEvidence(kind, issue),
                                         cancellation: cancellation)
        let completes = lifecycle(kind, of: issue).rules.contains { $0.kind == .completion && $0.to == target && $0.from.contains(LifecycleVocabulary.normalize(stored)) }
        if completes, LifecycleVocabulary.normalize(stored) != target {
            evidence.delivery = await deliveryVerdict(kind, issue)
        }
        return transition(kind, issue, to: status, actor: actor, reason: reason, force: force, evidence: evidence, from: stored,
                          command: command, surface: surface)
    }

    /// The handoff to an agent (Implement with AI, Fix with AI): the session is recorded and is the start evidence. Call it
    /// only after the prompt went out; a handoff that failed leaves nothing marked (REQ-003).
    @discardableResult
    func startByHandoff(_ kind: IssueKind, _ issue: String, tool: String, actor: LifecycleActor, surface: Bool = true) -> ApplyResult {
        guard let parts else { return finish(.failed("This window has no project folder open."), surface: surface) }
        guard let stored = storedStatus(kind, issue), let target = startTarget(kind, from: stored, issue: issue) else {
            return finish(.failed("\(issue) cannot be started from its status in this project's workflow."), surface: surface)
        }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        _ = try? parts.sessions.attach(issue: issue, kind: kind, session: "\(tool)@\(stamp)", tool: tool, via: .handoff)
        return transition(kind, issue, to: target, actor: actor,
                          evidence: LifecycleEvidence(start: .handoff(tool: tool, at: now)), surface: surface)
    }

    /// A person says that manual work on an item has started (REQ-004, DEC-018). The note is the start evidence only under a variant
    /// that accepts one; the start itself is then an ordinary transition decided by the policy.
    @discardableResult
    func startManually(_ kind: IssueKind, _ issue: String, note: String, by actor: LifecycleActor, surface: Bool = true) -> ApplyResult {
        guard let parts, let stored = parts.statuses.status(kind: kind, issue: issue) else {
            return finish(.failed("\(issue) was not found in this project."), surface: surface)
        }
        guard variant(kind, issue)?.start == .agentOrNote else {
            return finish(.failed("The rule variant of \(issue) starts only with an agent session. Choose another variant to start by a note."), surface: surface)
        }
        guard let target = startTarget(kind, from: stored, issue: issue) else {
            return finish(.failed("\(issue) cannot be started from its status in this project's workflow."), surface: surface)
        }
        guard parts.service.recordHumanEvidence(kind, issue, evidence: .start, text: note, actor: actor, variant: variant(kind, issue)?.id,
                                                workflowRevision: workflow.revision) != nil else {
            return finish(.failed("Write what has been started: a note is the evidence."), surface: surface)
        }
        let evidence = LifecycleEvidence(start: startEvidence(kind, issue, parts: parts))
        return transition(kind, issue, to: target, actor: actor, evidence: evidence, from: stored, surface: surface)
    }

    /// A person confirms the delivery event the variant names ("installed", "deployed to production"). It is evidence; the
    /// completion itself is still made by MarkView when the rest of the delivery is there (REQ-004, DEC-018).
    @discardableResult
    func confirmDelivery(_ kind: IssueKind, _ issue: String, note: String, by actor: LifecycleActor) -> Bool {
        guard let parts, let event = variant(kind, issue)?.deliveryRules.confirmedEventName else { return false }
        let wrote = parts.service.recordHumanEvidence(kind, issue, evidence: .delivery, text: note, event: event, actor: actor,
                                                      variant: variant(kind, issue)?.id, workflowRevision: workflow.revision) != nil
        if wrote { store.objectWillChange.send() }
        return wrote
    }

    /// The start evidence of an item: the earliest attached session, else a person's note when the variant accepts one.
    private func startEvidence(_ kind: IssueKind, _ issue: String, parts: Parts) -> StartEvidence? {
        if let session = SessionAttachment.startEvidence(parts.sessions.attachments(for: issue)) { return session }
        guard variant(kind, issue)?.start == .agentOrNote, let note = parts.service.history(kind, issue).pendingStartNote else { return nil }
        return .note(text: note.reason ?? "", by: note.actor.name, at: note.at)
    }

    /// Whether the lifecycle lets a hand-off start the item now (asked before a prompt is sent, so the prompt names only items
    /// that can really be marked).
    func canStartByHandoff(_ kind: IssueKind, _ issue: String) -> Bool {
        guard let stored = storedStatus(kind, issue), let target = startTarget(kind, from: stored, issue: issue) else { return false }
        let probe = TransitionRequest(kind: kind, issue: issue, from: stored, to: target,
                                      actor: .human("person"), evidence: LifecycleEvidence(start: .handoff(tool: "probe", at: Date())),
                                      workflow: workflow, variantID: assignedVariantID(kind, issue))
        switch LifecyclePolicy.decide(probe) {
        case .allowed, .noChange, .overridden: return true
        case .rejected: return false
        }
    }

    /// Whether the rules let `actor` move the item to `status` now with nothing but the request itself (no evidence, no reason):
    /// asked before work that cannot be undone (trashing files, sending a prompt) so it is not done for a move that will be refused.
    func canMove(_ kind: IssueKind, _ issue: String, to status: String, actor: LifecycleActor) -> Bool {
        guard let stored = storedStatus(kind, issue) else { return false }
        switch LifecyclePolicy.decide(TransitionRequest(kind: kind, issue: issue, from: stored, to: status, actor: actor,
                                                        workflow: workflow, variantID: assignedVariantID(kind, issue))) {
        case .allowed, .noChange: return true
        case .overridden, .rejected: return false
        }
    }

    /// The lifecycle paragraph appended to the prompt that hands an item (or, for a batch, several bugs) to an agent.
    func handoffBlock(_ kind: IssueKind, _ issues: [String]) -> String {
        guard let first = issues.first, let status = storedStatus(kind, first) else { return "" }
        let steps = LifecyclePolicy.nextSteps(kind: kind, status: status, actor: .ai,
                                              evidence: LifecycleEvidence(start: .handoff(tool: "handoff", at: Date())),
                                              workflow: workflow, variantID: assignedVariantID(kind, first))
        return IssueLifecycleContext.handoffBlock(kind: kind, issue: issues.joined(separator: ", "), status: status, nextSteps: steps,
                                                  workflow: workflow)
    }

    // MARK: - Evidence

    private func acceptanceEvidence(_ kind: IssueKind, _ issue: String, text: String?) -> AcceptanceEvidence? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard kind == .feature else { return AcceptanceEvidence(text: trimmed, criteriaAllTicked: true) }
        let criteria = (store.feature(issue)?.activeRequirements ?? []).flatMap(\.acceptanceCriteria)
        return AcceptanceEvidence(text: trimmed, criteriaAllTicked: !criteria.isEmpty && criteria.allSatisfy(\.done))
    }

    /// A bug report with `regression_of` naming the issue that is still open (not a duplicate, not closed): DEC-009.
    func regressionBug(_ kind: IssueKind, _ issue: String) -> String? {
        let wanted = issue.uppercased()
        return store.bugs.first { bug in
            bug.regressionOf.uppercased() == wanted && bug.duplicateOf.isEmpty && bug.key.uppercased() != wanted
                && [.notStarted, .active].contains(workflow.role(.bug, IssueStatus.normalize(bug.status)))
        }?.key
    }

    private func regressionEvidence(_ kind: IssueKind, _ issue: String) -> RegressionEvidence? {
        regressionBug(kind, issue).map { RegressionEvidence.bug(id: $0) }
    }

    /// The GitHub issue numbers an item links, and the numbers some other item also links.
    private func numbers(_ kind: IssueKind, _ issue: String) -> (own: Set<Int>, others: Set<Int>) {
        var own = Set<Int>(), others = Set<Int>()
        for feature in store.features {
            if kind == .feature && feature.slug == issue { own.formUnion(feature.issueNumbers) } else { others.formUnion(feature.issueNumbers) }
        }
        for bug in store.bugs {
            if kind == .bug && bug.key.uppercased() == issue.uppercased() { own.formUnion(bug.issueNumbers) } else { others.formUnion(bug.issueNumbers) }
        }
        return (own, others)
    }

    /// Delivery evidence of an item now (DEC-007, DEC-012). Runs git and gh off the main thread.
    func deliveryVerdict(_ kind: IssueKind, _ issue: String) async -> DeliveryVerdict {
        guard let root = store.root, let history = history(kind, issue) else { return .notCollected }
        let linked = numbers(kind, issue)
        let since = history.deliveryRoundStart
        let rules = (workflow.resolvedVariant(kind, assigned: history.assignedVariant) ?? workflow.resolvedVariant(kind, assigned: nil))?.deliveryRules
            ?? ProjectWorkflow.standard.resolvedVariant(kind, assigned: nil)!.deliveryRules
        let confirmation = rules.confirmedEventName.flatMap { history.deliveryConfirmation(event: $0)?.reason }
        let subject = IssueEvidenceCollector.Subject(kind: kind, issue: issue, exclusiveNumbers: linked.own.subtracting(linked.others),
                                                     sharedNumbers: linked.own.intersection(linked.others), since: since,
                                                     rules: rules, eventConfirmation: confirmation)
        return await IssueEvidenceCollector.collect(subject, root: root, githubEnabled: GitHubSettings.enabled)
    }

    // MARK: - Reconciling what the files say with what the history says

    private func items() -> [(kind: IssueKind, issue: String, status: String)] {
        store.features.map { (IssueKind.feature, $0.slug, $0.status) } + store.bugs.map { (IssueKind.bug, $0.key, $0.status) }
    }

    /// Cheap, no network: closes interrupted operations, records first looks (baseline) and edits made outside MarkView, and
    /// reopens a completed item when a bug report names it as a regression (DEC-009, DEC-015). Runs after every load.
    func reconcileLocal() {
        guard !reconciling, store.recordsLifecycle, parts != nil else { return }
        reconciling = true
        defer { reconciling = false }
        reloadWorkflow()
        guard let parts = self.parts else { return }
        assignExistingItems(parts: parts)
        resumePendingReplacements(parts: parts)
        parts.service.recoverPending()
        let all = parts.service.records()
        for item in items() {
            let history = IssueHistory(kind: item.kind, issue: item.issue, all: all)
            let input = ReconcileInput(kind: item.kind, issue: item.issue, storedStatus: item.status, history: history, delivery: nil,
                                       regressionBug: regressionBug(item.kind, item.issue), workflow: workflow)
            for action in IssueReconciler.actions(input) { perform(action, for: item, parts: parts) }
        }
        scheduleProgressCheck()
    }

    private func perform(_ action: ReconcileAction, for item: (kind: IssueKind, issue: String, status: String), parts: Parts) {
        switch action {
        case .recoverPending:
            parts.service.recoverPending()
        case .baseline(let status):
            parts.service.recordBaseline(item.kind, item.issue, status: status)
        case .externalEdit(let from, let to):
            parts.service.recordExternalEdit(item.kind, item.issue, from: from, to: to)
        case .confirm(let status, let evidence):
            parts.service.recordConfirmation(item.kind, item.issue, status: status, evidence: evidence)
        case .reopen(let bug, _):
            guard let destination = regressionTarget(item.kind, item.issue, from: item.status) else { return }
            transition(item.kind, item.issue, to: destination, actor: .system("regression report \(bug)"), reason: "Regression reported in \(bug).",
                       evidence: LifecycleEvidence(regression: .bug(id: bug)), command: "regression:\(item.issue):\(bug)", surface: false)
        }
    }

    /// Completes the work that the delivery evidence backs: a feature being implemented or a bug being fixed whose associated work is
    /// merged, whose required checks passed and whose required release exists (REQ-002 criterion 2, DEC-007). The system actor
    /// asks, and the same rules as for anyone decide. It reads git and GitHub, so it runs for the items a person or the GitHub
    /// sync asks about (`only`), and for the whole project at most once per `minimumInterval` per item after a load. Evidence that
    /// is incomplete or unreadable changes and records nothing. Returns the items that were completed.
    @discardableResult
    func completeFinishedWork(only targets: [(kind: IssueKind, issue: String)]? = nil, minimumInterval: TimeInterval = 0) async -> [String] {
        guard let parts, store.recordsLifecycle else { return [] }
        let candidates = targets ?? items().map { (kind: $0.kind, issue: $0.issue) }
        var completed: [String] = []
        for target in candidates {
            guard let status = storedStatus(target.kind, target.issue),
                  let destination = IssueReconciler.completionTarget(kind: target.kind, status: status, workflow: workflow,
                                                                     variantID: assignedVariantID(target.kind, target.issue)) else { continue }
            let key = "\(target.kind.rawValue):\(target.issue)"
            if let last = lastProgressCheck[key], Date().timeIntervalSince(last) < minimumInterval { continue }
            lastProgressCheck[key] = Date()
            let delivery = await deliveryVerdict(target.kind, target.issue)
            guard delivery.isComplete else { continue }
            // The file may have changed while git and GitHub were read.
            guard let now = storedStatus(target.kind, target.issue), LifecycleVocabulary.normalize(now) == LifecycleVocabulary.normalize(status) else { continue }
            let step = parts.service.history(target.kind, target.issue).changes.count
            let result = transition(target.kind, target.issue, to: destination, actor: .system("MarkView"), evidence: LifecycleEvidence(delivery: delivery),
                                    from: status, command: "complete:\(key):\(step)", surface: false)
            if result.isApplied { completed.append(target.issue) }
        }
        return completed
    }

    /// After a load: looks at the work that is under way, at most every few minutes per item, and only with the GitHub
    /// integration on (without it no check can be read, so nothing could complete).
    private func scheduleProgressCheck() {
        guard progressTask == nil, GitHubSettings.enabled,
              items().contains(where: { IssueReconciler.completionTarget(kind: $0.kind, status: $0.status, workflow: workflow,
                                                                   variantID: assignedVariantID($0.kind, $0.issue)) != nil }) else { return }
        progressTask = Task { [weak self] in
            guard let self else { return }
            await self.completeFinishedWork(minimumInterval: Self.progressInterval)
            self.progressTask = nil
        }
    }

    /// Checks completed items whose completion is not verified (a first look at an already completed status, an override, an edit
    /// outside MarkView) against the delivery evidence, and records a confirmation when it backs them (DEC-015). Reads git and
    /// GitHub, so it runs for the items a person or the GitHub sync asks about (`only`), never for the whole project at once.
    /// Returns the items that were confirmed.
    @discardableResult
    func reconcileEvidence(only targets: [(kind: IssueKind, issue: String)]) async -> [String] {
        guard let parts, store.recordsLifecycle else { return [] }
        var confirmed: [String] = []
        for target in targets {
            guard let status = storedStatus(target.kind, target.issue), LifecycleVocabulary.isCompletedStatus(target.kind, status, in: workflow) else { continue }
            let before = parts.service.history(target.kind, target.issue)
            switch IssueCompletion.state(kind: target.kind, status: status, history: before, deliveryNow: nil, workflow: workflow) {
            case .overridden, .unverifiedEdit: break
            default: continue
            }
            let delivery = await deliveryVerdict(target.kind, target.issue)
            // The file may have changed while git and GitHub were read.
            guard let now = storedStatus(target.kind, target.issue), LifecycleVocabulary.normalize(now) == LifecycleVocabulary.normalize(status) else { continue }
            let input = ReconcileInput(kind: target.kind, issue: target.issue, storedStatus: status,
                                       history: parts.service.history(target.kind, target.issue), delivery: delivery, regressionBug: nil, workflow: workflow)
            let item = (kind: target.kind, issue: target.issue, status: status)
            for action in IssueReconciler.actions(input) {
                perform(action, for: item, parts: parts)
                if case .confirm = action { confirmed.append(target.issue) }
            }
        }
        return confirmed
    }

    // MARK: - Context for people and agents

    func discrepancies(_ kind: IssueKind, _ issue: String, status: String, delivery: DeliveryVerdict?) -> [Discrepancy] {
        guard let history = history(kind, issue) else { return [] }
        return IssueReconciler.discrepancies(ReconcileInput(kind: kind, issue: issue, storedStatus: status, history: history, delivery: delivery,
                                                            regressionBug: regressionBug(kind, issue), workflow: workflow))
    }

    /// What the Lifecycle section of the window shows for one item (REQ-004). Reads the journal, so callers keep the result
    /// instead of asking on every redraw. `delivery` is the verdict of an explicit evidence check, when one was made.
    func display(_ kind: IssueKind, _ issue: String, delivery: DeliveryVerdict? = nil) -> IssueLifecycleDisplay? {
        guard let parts, let status = parts.statuses.status(kind: kind, issue: issue), let history = history(kind, issue) else { return nil }
        let state = IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery, workflow: workflow)
        var notes = discrepancies(kind, issue, status: status, delivery: delivery).map(\.message)
        if let problem = workflowProblem { notes.append(problem) }
        return IssueLifecycleDisplay.make(kind: kind, issue: issue, status: status, history: history, completion: Self.label(state), discrepancies: notes,
                                          workflow: workflow, variantID: history.assignedVariant)
    }

    /// The person asked to check the delivery evidence of one item: git and GitHub are read now (GitHub only when the integration
    /// is on), a completed status that the evidence backs is confirmed (DEC-015), and the verdict is returned for the section.
    func checkEvidence(_ kind: IssueKind, _ issue: String) async -> (verdict: DeliveryVerdict, confirmed: Bool) {
        let confirmed = await reconcileEvidence(only: [(kind, issue)]).contains(issue)
        return (await deliveryVerdict(kind, issue), confirmed)
    }

    /// The text `markview_issue_context` returns for one item.
    func contextText(_ kind: IssueKind, _ issue: String, actor: LifecycleActorKind) async -> String? {
        guard let parts, let status = parts.statuses.status(kind: kind, issue: issue), let history = history(kind, issue) else { return nil }
        let delivery = await deliveryVerdict(kind, issue)
        let state = IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery, workflow: workflow)
        let title: String
        var criteria: Bool?
        var links: [String] = []
        switch kind {
        case .feature:
            let feature = store.feature(issue)
            title = feature?.title ?? issue
            let all = (feature?.activeRequirements ?? []).flatMap(\.acceptanceCriteria)
            criteria = !all.isEmpty && all.allSatisfy(\.done)
            links = (feature?.issueNumbers ?? []).map { "#\($0)" }
        case .bug:
            let bug = store.bugs.first { $0.key.uppercased() == issue.uppercased() }
            title = bug?.title ?? issue
            links = (bug?.issueNumbers ?? []).map { "#\($0)" }
        }
        let notes = discrepancies(kind, issue, status: status, delivery: delivery).map(\.message)
        return IssueLifecycleContext.text(IssueContextInput(kind: kind, issue: issue, title: title, status: status, history: history, delivery: delivery,
                                                            completionLabel: Self.label(state), discrepancies: notes,
                                                            attached: parts.sessions.attachments(for: issue), actor: actor, criteriaTicked: criteria,
                                                            githubLinks: links, workflow: workflow, variantID: history.assignedVariant,
                                                            workflowProblem: workflowProblem))
    }

    /// Items under way or with an attached session, one line each (`markview_issue_context` without an issue).
    func listText() -> String {
        guard let parts else { return "This window has no project folder open." }
        let all = parts.service.records()
        var lines: [IssueSummaryLine] = []
        for item in items() {
            let attached = parts.sessions.attachments(for: item.issue)
            guard LifecycleVocabulary.isActiveStatus(item.kind, item.status, in: workflow) || !attached.isEmpty else { continue }
            let state = IssueCompletion.state(kind: item.kind, status: item.status,
                                              history: IssueHistory(kind: item.kind, issue: item.issue, all: all), deliveryNow: nil, workflow: workflow)
            let title = item.kind == .feature ? (store.feature(item.issue)?.title ?? item.issue)
                                              : (store.bugs.first { $0.key == item.issue }?.title ?? item.issue)
            lines.append(IssueSummaryLine(kind: item.kind, issue: item.issue, title: title, status: item.status,
                                          completionLabel: Self.label(state), sessions: attached))
        }
        return IssueLifecycleContext.listText(lines)
    }
}

extension FeatureStore {
    /// A step between the specification stages, made by the person's click or by the app's own workflow (Explore, Review,
    /// Quick feature). These steps need no evidence; archived, implementing and later statuses are not reached this way.
    @discardableResult
    func moveFeature(_ slug: String, to status: String, by actor: LifecycleActor, reason: String? = nil, surface: Bool = true) -> ApplyResult {
        lifecycle.transition(.feature, slug, to: status, actor: actor, reason: reason, surface: surface)
    }

    /// A bug status step the app itself makes (a validity verdict, a restore after a failed hand-off).
    @discardableResult
    func moveBug(_ key: String, to status: String, by actor: LifecycleActor, reason: String? = nil,
                 evidence: LifecycleEvidence = .none, surface: Bool = true) -> ApplyResult {
        lifecycle.transition(.bug, key, to: status, actor: actor, reason: reason, evidence: evidence, surface: surface)
    }
}
