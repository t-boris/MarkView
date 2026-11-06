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
        let made = Parts(root: key,
                         service: IssueTransitionService(storage: FileTransitionStorage(url: folder.appendingPathComponent("transitions.jsonl")), statuses: statuses),
                         statuses: statuses,
                         sessions: SessionLinkStore(url: folder.appendingPathComponent("sessions.jsonl")))
        cached = made
        return made
    }

    var service: IssueTransitionService? { parts?.service }
    var sessions: SessionLinkStore? { parts?.sessions }

    // MARK: - Reading

    func storedStatus(_ kind: IssueKind, _ issue: String) -> String? { parts?.statuses.status(kind: kind, issue: issue) }

    func history(_ kind: IssueKind, _ issue: String) -> IssueHistory? { parts?.service.history(kind, issue) }

    /// Whether the status of the item is backed by evidence (DEC-010), judged from its history.
    func completion(_ kind: IssueKind, _ issue: String, status: String, delivery: DeliveryVerdict? = nil) -> IssueCompletionState {
        guard let history = history(kind, issue) else { return .unknown("The project has no lifecycle history yet.") }
        return IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery)
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
                                        reason: reason, force: force, evidence: evidence)
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
        var evidence = LifecycleEvidence(start: SessionAttachment.startEvidence(parts.sessions.attachments(for: issue)),
                                         acceptance: acceptanceEvidence(kind, issue, text: acceptance),
                                         regression: regressionEvidence(kind, issue),
                                         cancellation: cancellation)
        let completes = (kind == .feature && target == "implemented") || (kind == .bug && target == "fixed")
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
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        _ = try? parts.sessions.attach(issue: issue, kind: kind, session: "\(tool)@\(stamp)", tool: tool, via: .handoff)
        return transition(kind, issue, to: kind == .feature ? "implementing" : "fixing", actor: actor,
                          evidence: LifecycleEvidence(start: .handoff(tool: tool, at: now)), surface: surface)
    }

    /// Whether the lifecycle lets a hand-off start the item now (asked before a prompt is sent, so the prompt names only items
    /// that can really be marked).
    func canStartByHandoff(_ kind: IssueKind, _ issue: String) -> Bool {
        guard let stored = storedStatus(kind, issue) else { return false }
        let probe = TransitionRequest(kind: kind, issue: issue, from: stored, to: kind == .feature ? "implementing" : "fixing",
                                      actor: .human("person"), evidence: LifecycleEvidence(start: .handoff(tool: "probe", at: Date())))
        switch LifecyclePolicy.decide(probe) {
        case .allowed, .noChange, .overridden: return true
        case .rejected: return false
        }
    }

    /// Whether the rules let `actor` move the item to `status` now with nothing but the request itself (no evidence, no reason):
    /// asked before work that cannot be undone (trashing files, sending a prompt) so it is not done for a move that will be refused.
    func canMove(_ kind: IssueKind, _ issue: String, to status: String, actor: LifecycleActor) -> Bool {
        guard let stored = storedStatus(kind, issue) else { return false }
        switch LifecyclePolicy.decide(TransitionRequest(kind: kind, issue: issue, from: stored, to: status, actor: actor)) {
        case .allowed, .noChange: return true
        case .overridden, .rejected: return false
        }
    }

    /// The lifecycle paragraph appended to the prompt that hands an item (or, for a batch, several bugs) to an agent.
    func handoffBlock(_ kind: IssueKind, _ issues: [String]) -> String {
        guard let first = issues.first, let status = storedStatus(kind, first) else { return "" }
        let steps = LifecyclePolicy.nextSteps(kind: kind, status: status, actor: .ai,
                                              evidence: LifecycleEvidence(start: .handoff(tool: "handoff", at: Date())))
        return IssueLifecycleContext.handoffBlock(kind: kind, issue: issues.joined(separator: ", "), status: status, nextSteps: steps)
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
            bug.regressionOf.uppercased() == wanted && bug.duplicateOf.isEmpty && ["open", "fixing"].contains(LifecycleVocabulary.normalize(bug.status))
                && bug.key.uppercased() != wanted
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
        let subject = IssueEvidenceCollector.Subject(kind: kind, issue: issue, exclusiveNumbers: linked.own.subtracting(linked.others),
                                                     sharedNumbers: linked.own.intersection(linked.others), since: since)
        return await IssueEvidenceCollector.collect(subject, root: root, githubEnabled: GitHubSettings.enabled)
    }

    // MARK: - Reconciling what the files say with what the history says

    private func items() -> [(kind: IssueKind, issue: String, status: String)] {
        store.features.map { (IssueKind.feature, $0.slug, $0.status) } + store.bugs.map { (IssueKind.bug, $0.key, $0.status) }
    }

    /// Cheap, no network: closes interrupted operations, records first looks (baseline) and edits made outside MarkView, and
    /// reopens a completed item when a bug report names it as a regression (DEC-009, DEC-015). Runs after every load.
    func reconcileLocal() {
        guard !reconciling, store.recordsLifecycle, let parts else { return }
        reconciling = true
        defer { reconciling = false }
        parts.service.recoverPending()
        let all = parts.service.records()
        for item in items() {
            let history = IssueHistory(kind: item.kind, issue: item.issue, all: all)
            let input = ReconcileInput(kind: item.kind, issue: item.issue, storedStatus: item.status, history: history, delivery: nil,
                                       regressionBug: regressionBug(item.kind, item.issue))
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
            let destination = item.kind == .feature ? "implementing" : "open"
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
                  let destination = IssueReconciler.completionTarget(kind: target.kind, status: status) else { continue }
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
              items().contains(where: { IssueReconciler.completionTarget(kind: $0.kind, status: $0.status) != nil }) else { return }
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
            guard let status = storedStatus(target.kind, target.issue), LifecycleVocabulary.isCompletedStatus(target.kind, status) else { continue }
            let before = parts.service.history(target.kind, target.issue)
            switch IssueCompletion.state(kind: target.kind, status: status, history: before, deliveryNow: nil) {
            case .overridden, .unverifiedEdit: break
            default: continue
            }
            let delivery = await deliveryVerdict(target.kind, target.issue)
            // The file may have changed while git and GitHub were read.
            guard let now = storedStatus(target.kind, target.issue), LifecycleVocabulary.normalize(now) == LifecycleVocabulary.normalize(status) else { continue }
            let input = ReconcileInput(kind: target.kind, issue: target.issue, storedStatus: status,
                                       history: parts.service.history(target.kind, target.issue), delivery: delivery, regressionBug: nil)
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
                                                            regressionBug: regressionBug(kind, issue)))
    }

    /// What the Lifecycle section of the window shows for one item (REQ-004). Reads the journal, so callers keep the result
    /// instead of asking on every redraw. `delivery` is the verdict of an explicit evidence check, when one was made.
    func display(_ kind: IssueKind, _ issue: String, delivery: DeliveryVerdict? = nil) -> IssueLifecycleDisplay? {
        guard let parts, let status = parts.statuses.status(kind: kind, issue: issue), let history = history(kind, issue) else { return nil }
        let state = IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery)
        let notes = discrepancies(kind, issue, status: status, delivery: delivery).map(\.message)
        return IssueLifecycleDisplay.make(kind: kind, issue: issue, status: status, history: history, completion: Self.label(state), discrepancies: notes)
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
        let state = IssueCompletion.state(kind: kind, status: status, history: history, deliveryNow: delivery)
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
                                                            githubLinks: links))
    }

    /// Items under way or with an attached session, one line each (`markview_issue_context` without an issue).
    func listText() -> String {
        guard let parts else { return "This window has no project folder open." }
        let all = parts.service.records()
        var lines: [IssueSummaryLine] = []
        for item in items() {
            let attached = parts.sessions.attachments(for: item.issue)
            guard LifecycleVocabulary.isActiveStatus(item.kind, item.status) || !attached.isEmpty else { continue }
            let state = IssueCompletion.state(kind: item.kind, status: item.status,
                                              history: IssueHistory(kind: item.kind, issue: item.issue, all: all), deliveryNow: nil)
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
