import Foundation
import AppKit
import Combine
import MarkViewCore

/// What the Cockpit needs of the window it runs in: the window, its assistants, its QA model and bug features, and its tabs (whether the
/// Cockpit's own is shown, bringing it forward, opening a file). `CockpitHost` is the one implementation, built from the window's parts
/// (`AR-14` step 10).
@MainActor
protocol CockpitWindow: CockpitQAWindow {
    var hostWindow: NSWindow? { get }
    func showAIConsole()
    var assistants: any AssistantProviding { get }
    var features: FeatureStore { get }
    /// Whether the tab the person is looking at is the Cockpit's own.
    var cockpitTabIsActive: Bool { get }
    /// Brings the Cockpit's own tab forward.
    func showCockpitTool()
    /// Shows `url` in a tab of the window.
    func openFile(_ url: URL)
    /// Hands the feature to the assistant terminal with its checklist (the direct mode of "Implement with AI", REQ-001).
    func handOffDirectly(_ feature: CockpitFeatureContext)
}

@MainActor
final class CockpitSession: ObservableObject {
    let root: URL
    @Published var goal = ""
    @Published var controls = CockpitControls()
    @Published var refinement = ""
    @Published private(set) var plan: CockpitPlan?
    /// Which of the Cockpit's two screens is open: the plan editor, the run this window is running, or a saved run.
    enum Screen: Equatable { case plan, live, saved(UUID) }
    @Published var screen: Screen = .plan
    /// The goal or the controls on screen changed after the plan was written, so its steps were not re-checked against them.
    @Published private(set) var planNeedsRecheck = false
    /// The agents that can run a step here, with their models: what the pickers offer.
    @Published private(set) var agents: [CockpitAgentChoice] = []
    /// Who writes the plan: an agent's display name and one of its models; nil is the project's own assistant. Kept per project.
    @Published var plannerAgent: String? { didSet { savePlannerChoice() } }
    @Published var plannerModel: String? { didSet { savePlannerChoice() } }
    private var restoringPlannerChoice = true
    private var choseInitialScreen = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var savedRuns: [CockpitRun] = []
    @Published private(set) var savedQAResults: [CockpitLinkedResult] = []
    @Published private(set) var execution: CockpitExecution?
    @Published private(set) var runningPlan: CockpitPlan?
    @Published private(set) var pendingPlan: CockpitPlan?
    @Published private(set) var revisingExecution = false
    @Published private(set) var currentProgress: CockpitProgress?
    @Published private(set) var recoveryRun: CockpitRun?
    @Published private(set) var loadingRecovery = false
    /// Preferred starting step index when opening Plan from a paused run; consumed by `CockpitPlanScreen`.
    @Published var preferredStartStep: Int? = nil
    @Published private(set) var qaScenarios: [QAScenario] = []
    @Published private(set) var deletedQARuns: Set<String> = []
    @Published var qaTargets: [String: String] = [:]
    private var qaLogins: Set<QALoginReference> = []
    @Published private(set) var startingExecution = false
    /// The feature plans prepared from Build, one per feature (REQ-001), and the one on the plan screen; nil for a plan of the
    /// person's own goal.
    @Published private(set) var drafts: [CockpitDraft] = []
    @Published private(set) var draft: CockpitDraft?
    /// Why the last Start did not start: an unfinished run of the project, a missing capability (REQ-001, REQ-002).
    @Published private(set) var startBlocker: String?
    /// The steps the last managed start or continuation skipped, with the evidence that supports each (DEC-027).
    @Published private(set) var evidenceNote: [String] = []
    @Published private(set) var continuingManaged = false
    private weak var workspace: (any CockpitWindow)?
    private let notifier = CockpitNotifier()
    /// The reads, the replan and the controls that are running, keyed so that a new one replaces the old; closing the project cancels them (`AR-19`).
    private let tasks = TaskBag()
    private var observedRecord: CockpitRun?
    /// The once-a-minute look for a step that went silent, a job of the app's scheduler (`AR-19`). It keeps running while the app is in the
    /// background: that is when the person needs the notice.
    private let silenceKey = "cockpit-silence-" + UUID().uuidString
    private var noticeClicks: AnyCancellable?
    private var executionChange: AnyCancellable?
    private var executionTask: Task<Void, Never>?
    private var loadedTerminalStatus: String?
    private struct ReviewedExecution { var plan: CockpitPlan; var productionConfirmed: Bool }
    private var reviewedExecutions: [String: ReviewedExecution] = [:]
    private var reportingStep: (id: UUID, fingerprint: String)?
    private var task: Task<Void, Never>?

    init(root: URL, workspace: any CockpitWindow) {
        self.root = root; self.workspace = workspace
        let key = ProjectAIChoice.key(root)
        plannerAgent = Settings.standard.stored(Setting.cockpitPlannerAgent(project: key))
        plannerModel = Settings.standard.stored(Setting.cockpitPlannerModel(project: key))
        restoringPlannerChoice = false
        loadRuns()
        noticeClicks = NotificationCenter.default.publisher(for: .cockpitNoticeOpened).sink { [weak self] note in
            guard let self, let path = note.userInfo?["cockpitRoot"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL == self.root.standardizedFileURL else { return }
            let id = (note.userInfo?["cockpitRunID"] as? String).flatMap(UUID.init(uuidString:))
            // task: hops onto the main actor from a notification callback; it only shows a run and holds nothing of its own
            Task { @MainActor in self.showRun(id) }
        }
    }

    /// Brings the running step's agent terminal forward: where its questions and permission prompts are.
    func showAgentTerminal() {
        workspace?.hostWindow?.makeKeyAndOrderFront(nil)
        workspace?.showAIConsole()
    }

    /// A notification was clicked: bring this window forward and open the run it was about.
    private func showRun(_ id: UUID?) {
        workspace?.hostWindow?.makeKeyAndOrderFront(nil)
        workspace?.showCockpitTool()
        if let id { screen = execution?.runID == id ? .live : .saved(id) }
    }

    // MARK: Telling the person

    /// Whether the person is looking at the Cockpit right now: then the screen says it and a notification would only repeat it.
    private var watching: Bool {
        guard NSApp.isActive, let workspace, workspace.hostWindow?.isKeyWindow == true, workspace.cockpitTabIsActive else { return false }
        return true
    }

    private func observe(_ execution: CockpitExecution) {
        guard let record = execution.record else { return }
        let before = observedRecord?.id == record.id ? observedRecord : nil
        observedRecord = record
        let limitReached = execution.limitNotice.map { record.waitingReason == $0 } ?? false
        if let notice = CockpitNotice.transition(from: before, to: record, limitReached: limitReached), !watching {
            notifier.send(notice, root: root, runID: record.id)
        }
    }

    /// A step that shows no sign of life for a long time may be waiting for an answer in its terminal, which nothing else here can see.
    private func watchSilence(_ execution: CockpitExecution) {
        let key = silenceKey
        PollingScheduler.app.every(60, key: key, pausesWhenHidden: false) { [weak self, weak execution] in
            guard let self, let execution, let record = execution.record else { PollingScheduler.app.stop(key: key); return }
            let now = Date()
            if record.isSilent(now: now, activity: execution.lastSignal), let quiet = record.quietSeconds(now: now, activity: execution.lastSignal),
               let notice = CockpitNotice.silence(of: record, minutes: Int(quiet / 60)), !self.watching {
                self.notifier.send(notice, root: self.root, runID: record.id)
            }
        }
    }

    private func savePlannerChoice() {
        guard !restoringPlannerChoice else { return }
        let key = ProjectAIChoice.key(root)
        Settings.standard.set(plannerAgent, for: Setting.cockpitPlannerAgent(project: key))
        Settings.standard.set(plannerModel, for: Setting.cockpitPlannerModel(project: key))
    }

    /// The agents that can run a step in this project, each with the models it offers and what "default" means for it here.
    /// The model lists are read off the main thread: Codex's catalog is a large file.
    func loadAgents() async -> [CockpitAgentChoice] {
        let root = self.root
        var found: [CockpitAgentChoice] = []
        for tool in CLITool.allCases where tool.isMCPServiceEnabled(AgentMCPServer.markviewName) {
            guard await CLIToolLocator.resolveThorough(tool) != nil else { continue }
            let models = await Task.detached { AIAssistantPreferences.modelOptions(for: tool) }.value
            let defaultModel = AIAssistantPreferences.model(for: tool, project: root) ?? AIAssistantPreferences.configuredModel(for: tool)
            found.append(CockpitAgentChoice(tool: tool, models: models, defaultModel: defaultModel))
        }
        return found
    }

    func refreshAgents() {
        tasks.store(Task { [weak self] in
            guard let self else { return }
            let found = await self.loadAgents()
            if found != self.agents { self.agents = found }
        }, for: "agents")
    }

    // MARK: Editing the plan

    /// The person changes the plan. It keeps its identity; the scenarios it lists follow its steps (`CockpitPlan.normalizeScenarios`).
    func editPlan(_ change: (inout CockpitPlan) -> Void) {
        guard var edited = plan else { return }
        change(&edited)
        edited.normalizeScenarios()
        if edited != plan { plan = edited; persistDraft() }
    }

    /// The goal or the controls on screen changed after a plan was written. The plan is kept, since the person may have edited it by hand,
    /// and takes the new values (the approval covers exactly what is on screen); the screen says its steps were not re-checked.
    func goalOrControlsChanged() {
        guard var current = plan, current.goal != goal || current.controls != controls else { return }
        if current.goal != goal || current.controls.affectsSteps(comparedTo: controls) { planNeedsRecheck = true }
        current.goal = goal
        current.controls = controls
        plan = current
        persistDraft()
    }

    /// The person reviewed or hand-edited the steps after changing the goal or controls and chooses to keep them without AI re-planning.
    func acknowledgePlanRecheck() {
        planNeedsRecheck = false
    }

    /// Opens the Plan screen for a run (live or saved) so the person can edit steps or revise the plan directly.
    /// Keeps in-memory direct edits when reopening Plan for the active run already loaded in the editor.
    func openPlanForRun(_ run: CockpitRun) {
        error = nil
        recoveryRun = nil
        preferredStartStep = run.currentIndex ?? 0
        if execution?.runID == run.id, let existing = plan, runningPlan?.id == run.plan.id, draft == nil {
            _ = existing
            screen = .plan
            return
        }
        draft = nil
        goal = run.plan.goal
        controls = run.plan.controls
        plan = run.plan
        planNeedsRecheck = false
        screen = .plan
        guard !run.plan.scenarios.isEmpty else { return }
        let root = root
        let selected = run.plan
        tasks.store(Task { [weak self] in
            let listing = await Task.detached { QAStore.loadScenarios(root) }.value
            let saved = await Task.detached { BrowserPasswordStore.shared.all() }.value
            guard !Task.isCancelled, let self else { return }
            self.qaScenarios = listing.scenarios
            self.qaLogins = Set(saved.map { QALoginReference(host: $0.host, username: $0.username) })
            self.qaTargets = (selected.qaReviews ?? []).reduce(into: [:]) { $0[$1.scenarioID] = $1.targetID }
        }, for: "open-plan-qa")
    }

    /// Records the person's direct response to a failed step and immediately retries it.
    func respondAndRetry(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let execution, execution.isActive, !trimmed.isEmpty else { return }
        error = nil
        tasks.store(Task { [weak self] in
            await execution.sendStepResponse(trimmed)
            do { try await execution.control("retry") }
            catch { self?.error = error.localizedDescription }
        }, for: "respond-retry")
    }

    func preparedPlan(startingAt index: Int) throws -> CockpitPlan {
        guard var plan = plan?.selectingStart(index) else { throw CockpitPlanning.ParseError.invalid(["Choose a starting step."]) }
        guard !plan.scenarios.isEmpty else { return plan }
        let reviews = try plan.scenarios.map { id -> CockpitQAReview in
            guard let scenario = qaScenarios.first(where: { $0.id == id }),
                  let target = qaTargets[id] ?? (scenario.targets.count == 1 ? scenario.targets.first?.id : nil) else {
                throw CockpitPlanning.ParseError.invalid(["Choose an environment for each QA scenario."])
            }
            return try CockpitQAReviewBuilder.make(scenario: scenario, targetID: target, savedLogins: qaLogins)
        }
        plan.qaReviews = reviews
        let production = reviews.filter(\.production)
        plan.productionQA = production.isEmpty ? nil : CockpitProductionQA(exactPlan: production.map(\.exactPlan).joined(separator: "\n\n"),
                                                                            dataChangingActions: production.flatMap(\.dataChangingActions))
        return plan
    }

    /// Called only by the person's explicit approval in the cockpit.
    func start(at index: Int, reviewed: CockpitPlan, productionConfirmed: Bool) {
        guard !busy, !startingExecution, execution?.isActive != true, workspace != nil,
              (try? preparedPlan(startingAt: index)) == reviewed,
              let approval = CockpitApproval(plan: reviewed, productionConfirmed: productionConfirmed), reviewed.steps.indices.contains(index) else { return }
        launch(plan: reviewed, approval: approval, index: index, recovering: recoveryRun, productionConfirmed: productionConfirmed)
    }

    /// Every start asks first whether the project has an unfinished run (REQ-001, REQ-002): the saved runs are read, then the project is
    /// reserved at once on the main actor, so a second window that asks at the same moment is refused. A refused start leaves the
    /// plan and its approval as they are and says which run blocks it; nothing starts by itself when that run ends.
    private func launch(plan: CockpitPlan, approval: CockpitApproval, index: Int, recovering: CockpitRun?, productionConfirmed: Bool,
                        started: ((UUID) -> Void)? = nil) {
        startingExecution = true
        error = nil
        startBlocker = nil
        let root = root
        tasks.store(Task { [weak self] in
            let saved = await Task.detached { Result { try CockpitRunStore.loadAll(root: root) } }.value
            guard let self, !Task.isCancelled else { self?.startingExecution = false; return }
            guard case .success(let runs) = saved else {
                self.startBlocker = "The saved runs of this project could not be read, so whether one is unfinished is unknown."
                self.startingExecution = false
                return
            }
            let mine = self.execution?.isActive == true ? self.execution?.runID : nil
            if let blocker = CockpitAdmission.reserve(root: root, owner: self, title: plan.displayTitle,
                                                      saved: runs.filter { $0.id != mine }, continuing: recovering?.id) {
                self.startBlocker = blocker.message
                self.startingExecution = false
                if let id = blocker.runID, self.savedRuns.contains(where: { $0.id == id }) == false { self.loadRuns() }
                return
            }
            self.begin(plan: plan, approval: approval, index: index, recovering: recovering, productionConfirmed: productionConfirmed, started: started)
        }, for: "launch")
    }

    private func begin(plan: CockpitPlan, approval: CockpitApproval, index: Int, recovering: CockpitRun?, productionConfirmed: Bool,
                       started: ((UUID) -> Void)?) {
        guard let workspace else { startingExecution = false; CockpitAdmission.release(root: root, owner: self); return }
        let attempt = CockpitAgentAttempt(assistants: workspace.assistants, root: root,
            onFixCycle: { [weak self] count in self?.execution?.noteFixCycles(fromGate: count) },
            onGate: { [weak self] tool, refusal in self?.execution?.noteGate(tool: tool, refusal: refusal) },
            askSupervisor: { [root] prompt, tool, model in
                let supervising = AIOperation<CLICompletion.Request, CockpitSupervisor.Answer>(
                    name: "cockpit-supervisor",
                    parse: { result in
                        guard let answer = CockpitSupervisor.parse(result.structured) else { throw CockpitSupervisor.Failure.unusable }
                        return answer
                    })
                return try await supervising.execute(CLICompletion.Request(project: root, prompt: prompt,
                    systemPrompt: CockpitSupervisor.systemPrompt, jsonSchema: CockpitSupervisor.schema, readableFolder: root,
                    timeout: CockpitSupervisor.timeoutSeconds, toolOverride: tool, model: model, effort: "medium", label: "cockpit-supervisor")).output
            },
            onExchange: { [weak self] exchange in
                // task: records one exchange on the execution, which owns its own end
                Task { await self?.execution?.recordExchange(exchange) }
            },
            liveCuts: { [weak self] in self?.execution?.liveCuts ?? CockpitLiveSwitches() },
            liveNotes: { [weak self] in self?.execution?.liveNotes ?? [] },
            onProgress: { [weak self] progress in
                guard let self else { throw CancellationError() }
                try await self.publishProgress(progress)
            },
            onSurvivors: { [weak self] survivors in
                guard let execution = self?.execution else { return }
                // task: one save on the execution, which owns its own end
                Task { await execution.updateManaged({ $0.delegates = survivors },
                                                      event: survivors.isEmpty ? nil : "\(survivors.count) process(es) of the step are still running.") }
            })
        guard let fingerprint = try? CockpitTemporalPlan(plan).fingerprint else {
            startingExecution = false; CockpitAdmission.release(root: root, owner: self); return
        }
        reviewedExecutions = [fingerprint: ReviewedExecution(plan: plan, productionConfirmed: productionConfirmed)]
        pendingPlan = nil
        let execution = CockpitExecution(root: root, service: .forProject(root)) { [weak self] task in
            guard let self else { return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "The cockpit was closed.") }
            return await self.perform(task, attempt: attempt)
        }
        loadedTerminalStatus = nil
        executionChange = execution.objectWillChange.sink { [weak self, weak execution] _ in
            self?.objectWillChange.send()
            // task: lets the change land before it is observed, then ends; weak references only
            Task { @MainActor [weak self, weak execution] in
                await Task.yield()
                if let self, let execution { self.observe(execution) }
                if let self, let fingerprint = execution?.state?.fingerprint,
                   let reviewed = self.reviewedExecutions[fingerprint], self.runningPlan != reviewed.plan {
                    self.runningPlan = reviewed.plan
                    if self.pendingPlan == reviewed.plan { self.pendingPlan = nil }
                }
                if let self, self.pendingPlan != nil, !self.revisingExecution,
                   execution?.record?.pendingRevision == nil, (execution?.state?.pendingFingerprint ?? "").isEmpty {
                    self.pendingPlan = nil
                }
                if let self, let status = execution?.state?.status, ["finished", "stopped"].contains(status), self.pendingPlan != nil {
                    self.error = "The run ended before the approved changes were applied."
                    self.pendingPlan = nil
                }
                guard let self, let status = execution?.state?.status,
                      ["finished", "stopped", "interrupted"].contains(status), self.loadedTerminalStatus != status else { return }
                self.loadedTerminalStatus = status
                // A finished or stopped run no longer holds the project; an interrupted one does until it is stopped (REQ-001).
                if status != "interrupted" { CockpitAdmission.release(root: self.root, owner: self) }
                self.loadRuns()
            }
        }
        self.execution = execution
        observedRecord = nil
        notifier.requestAuthorization()
        watchSilence(execution)
        screen = .live
        runningPlan = plan
        currentProgress = CockpitProgress(passNumber: 1, activity: "Starting the selected step", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
        startingExecution = true
        error = nil
        executionTask = Task { [weak self] in
            do {
                try await execution.start(plan: plan, approval: approval, step: index, recovering: recovering)
                self?.recoveryRun = nil
                if let self, let id = execution.runID {
                    CockpitAdmission.note(root: self.root, owner: self, runID: id)
                    started?(id)
                }
            }
            catch {
                self?.error = error.localizedDescription
                if let self { CockpitAdmission.release(root: self.root, owner: self) }
            }
            self?.startingExecution = false
        }
    }

    private func perform(_ task: CockpitHostTask, attempt: CockpitAgentAttempt) async -> CockpitHostReply {
        guard let reviewed = reviewedExecutions[task.planFingerprint], let workspace else {
            return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "The step's approved plan is unavailable.")
        }
        reportingStep = UUID(uuidString: task.step.id).map { ($0, task.planFingerprint) }
        if var progress = currentProgress {
            progress.activity = task.step.title
            progress.blockers = []
            progress.criteriaResults = nil
            do { try await publishProgress(progress) }
            catch { return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "Progress could not be saved.") }
        }
        // The runtime does not carry the model (it only knows the fields it declares), so it comes from the approved plan by the step's id.
        attempt.stepModel = reviewed.plan.steps.first { $0.id.uuidString == task.step.id }?.chosenModel
        attempt.planOutline = reviewed.plan.steps.map { "\($0.title) (\($0.agent))" }
        attempt.supervisorTool = CLITool.allCases.first { $0.displayName == reviewed.plan.controls.supervisorAgent }
        attempt.supervisorModel = reviewed.plan.controls.supervisorModel
        let managedStep = reviewed.plan.feature != nil ? reviewed.plan.steps.first { $0.id.uuidString == task.step.id } : nil
        attempt.delegation = nil
        attempt.managedBrief = nil
        attempt.changesAllowed = false
        if let feature = reviewed.plan.feature, let step = managedStep {
            if let early = await managedGate(step: step, feature: feature) { return early }
            attempt.delegation = step.delegate == true && reviewed.plan.controls.allowDelegation
                ? CLITool.allCases.first { $0.displayName == step.agent }?.provider.cockpitDelegation : nil
            attempt.managedBrief = Self.managedBrief(step, branch: feature.branch, repairing: task.recoveryAttempt != nil)
            attempt.changesAllowed = CockpitManagedRun.changesAllowed(for: step.kind ?? .work, recoveryAttempt: task.recoveryAttempt)
            markImplementationStarted(feature: feature, agent: step.agent)
        }
        var result = await attempt.run(task)
        if let step = managedStep, result.error.isEmpty {
            let revision = await CockpitDeliveryProbe.head(root: root)
            var state = execution?.record?.managed ?? CockpitManagedState()
            CockpitManagedRun.absorb(&result.result, step: step, revision: revision, managed: &state,
                                     delegationAllowed: attempt.delegation != nil)
            let findings = state.findings.count - (execution?.record?.managed?.findings.count ?? 0)
            await execution?.updateManaged({ $0 = state }, event: findings > 0 ? "The review reported \(findings) finding(s)." : nil)
        }
        guard result.error.isEmpty, result.result.passed, task.recoveryAttempt == nil, let id = task.step.qaScenarioID, !id.isEmpty else { return result }
        let qa = CockpitQAAttempt(workspace: workspace, root: root, plan: reviewed.plan, productionConfirmed: reviewed.productionConfirmed) { [weak self] activity, coverage, blockers in
            guard let self, var progress = self.currentProgress else { return }
            progress.activity = activity
            progress.scenarioCoverage = progress.scenarioCoverage.filter { !$0.hasPrefix(id + "/") } + coverage
            progress.blockers = blockers
            try await self.publishProgress(progress)
        }
        return await qa.run(scenarioID: id, previous: result)
    }

    private func publishProgress(_ progress: CockpitProgress) async throws {
        currentProgress = progress
        guard let step = reportingStep, let execution else { throw CockpitExecution.Failure.unavailable }
        try await execution.saveProgress(progress, stepID: step.id, planFingerprint: step.fingerprint)
    }

    func applyRevision(at index: Int, reviewed: CockpitPlan, productionConfirmed: Bool) {
        guard !revisingExecution, let execution, execution.isActive,
              (try? preparedPlan(startingAt: index)) == reviewed,
              let approval = CockpitApproval(plan: reviewed, productionConfirmed: productionConfirmed),
              let fingerprint = try? CockpitTemporalPlan(reviewed).fingerprint,
              pendingPlan == nil || pendingPlan == reviewed else { return }
        if let blocker = execution.record?.revisionPrerequisiteBlocker(plan: reviewed, startingAt: index) {
            error = blocker
            return
        }
        let wasPaused = execution.state?.status == "paused"
        reviewedExecutions[fingerprint] = ReviewedExecution(plan: reviewed, productionConfirmed: productionConfirmed)
        pendingPlan = reviewed
        revisingExecution = true
        error = nil
        tasks.store(Task { [weak self] in
            do {
                try await execution.replan(reviewed, approval: approval, step: index)
                if wasPaused { self?.screen = .live }
            } catch {
                self?.error = error.localizedDescription
                if execution.record?.pendingRevision == nil { self?.pendingPlan = nil }
            }
            self?.revisingExecution = false
        }, for: "replan")
    }

    func control(_ command: String) {
        guard let execution else { return }
        tasks.store(Task { [weak self] in
            do { try await execution.control(command) }
            catch { self?.error = error.localizedDescription }
        }, for: "control:" + UUID().uuidString)
    }

    func cancelExecutionStartup() {
        executionTask?.cancel()
        execution?.shutdown()
    }

    func closeProject() {
        persistDraft()
        CockpitAdmission.release(root: root, owner: self)
        PollingScheduler.app.stop(key: silenceKey)
        tasks.cancelAll()
        cancel()
        executionTask?.cancel()
        execution?.shutdown()
    }

    func loadRuns() {
        let root = self.root
        tasks.store(Task { [weak self] in
            do {
                let runs = try await Task.detached { try CockpitRunStore.loadAll(root: root) }.value
                let drafts = await Task.detached { Result { try CockpitDraftStore.loadAll(root: root) } }.value
                if case .success(let loaded) = drafts, let self {
                    // The draft on screen is the one being edited; the file may lag behind it by a save.
                    self.drafts = loaded.map { $0.slug == self.draft?.slug ? (self.draft ?? $0) : $0 }
                } else if case .failure(let error) = drafts { self?.error = "Some Cockpit drafts could not be loaded: \(error.localizedDescription)" }
                let qaResults = await Task.detached { Result { try CockpitResults.loadAll(root: root) } }.value
                guard !Task.isCancelled, let self else { return }
                switch qaResults {
                case .success(let results): self.savedQAResults = results
                case .failure(let error): self.error = "Some QA evidence could not be loaded: \(error.localizedDescription)"
                }
                let activeID = self.execution?.isActive == true ? self.execution?.runID : nil
                self.savedRuns = runs.filter { $0.id != activeID }
                    .sorted { ($0.lastKnownActivity ?? .distantPast) > ($1.lastKnownActivity ?? .distantPast) }
                if !self.choseInitialScreen {
                    // Coming back to the Cockpit: a run that is going or waiting for the person comes first, not an empty plan form.
                    self.choseInitialScreen = true
                    if self.execution != nil { self.screen = .live }
                    else if self.screen == .plan, self.plan == nil, let waiting = self.savedRuns.first(where: { $0.status == .paused }) { self.screen = .saved(waiting.id) }
                }
                let ids = Set(runs.flatMap { $0.results.compactMap(\.qaRunID) })
                self.deletedQARuns = await Task.detached {
                    Set(ids.filter { id in
                        guard QARunRetention.runID(inBugKey: id + ":result") == id else { return true }
                        return !FileManager.default.fileExists(atPath: QAStore.runFolder(root, runID: id).appendingPathComponent("run.json").path)
                    })
                }.value
            }
            catch { self?.error = "Saved cockpit runs could not be loaded: \(error.localizedDescription)" }
        }, for: "runs")
    }

    func prepareRecovery(_ run: CockpitRun, usePending: Bool = false) {
        guard execution?.isActive != true, (run.status == .paused || run.status == .stopped), let index = run.currentIndex,
              run.steps.indices.contains(index), run.steps[index].status == .interrupted else { return }
        guard let selected = usePending ? run.pendingRevision?.plan : run.plan else { return }
        loadingRecovery = true
        let root = root
        tasks.store(Task { [weak self] in
            let listing = await Task.detached { QAStore.loadScenarios(root) }.value
            let saved: [SavedLogin]
            if selected.scenarios.isEmpty { saved = [] }
            else { saved = await Task.detached { BrowserPasswordStore.shared.all() }.value }
            guard !Task.isCancelled, let self else { return }
            self.qaScenarios = listing.scenarios
            self.qaLogins = Set(saved.map { QALoginReference(host: $0.host, username: $0.username) })
            self.qaTargets = (selected.qaReviews ?? []).reduce(into: [:]) { $0[$1.scenarioID] = $1.targetID }
            self.goal = selected.goal
            self.controls = selected.controls
            self.plan = selected
            self.recoveryRun = run
            self.planNeedsRecheck = false
            self.screen = .plan
            self.loadingRecovery = false
        }, for: "recovery")
    }

    func cancelRecovery() { recoveryRun = nil }

    func openQAResult(scenarioID: String, runID: String) {
        guard let workspace else { return }
        workspace.showQATool()
        let qa = workspace.qa
        qa.reload()
        tasks.store(Task { [weak self, weak qa] in
            guard let qa else { return }
            for _ in 0..<100 {
                if qa.scenarios.contains(where: { $0.id == scenarioID }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard qa.scenarios.contains(where: { $0.id == scenarioID }) else { self?.error = "The linked QA scenario is no longer available."; return }
            qa.open(scenarioID)
            qa.archive.reload(scenarioID: scenarioID)
            for _ in 0..<100 {
                if qa.archive.runs.contains(where: { $0.id == runID }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard qa.archive.runs.contains(where: { $0.id == runID }) else { self?.error = "The linked QA run details were deleted or are unavailable."; return }
            qa.archive.open(runID)
        }, for: "open-qa-result")
    }

    func openBug(_ key: String) {
        guard let workspace else { return }
        if let bug = workspace.features.bugs.first(where: { $0.key == key }) { workspace.openFile(bug.url); return }
        workspace.features.reload()
        tasks.store(Task { [weak self, weak workspace] in
            for _ in 0..<100 {
                guard let workspace else { return }
                if let bug = workspace.features.bugs.first(where: { $0.key == key }) { workspace.openFile(bug.url); return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.error = "The linked bug is no longer available: \(key)"
        }, for: "open-bug")
    }

    func openBuildLog(_ path: String) {
        guard let workspace, !path.isEmpty else { return }
        let root = root
        tasks.store(Task { [weak self, weak workspace] in
            let candidate = await Task.detached { () -> URL? in
                let project = root.standardizedFileURL.resolvingSymlinksInPath()
                let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : project.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
                guard ProjectPaths.containsStrictly(candidate, root: project), FileManager.default.fileExists(atPath: candidate.path) else { return nil }
                return candidate
            }.value
            guard let candidate else { self?.error = "The linked build log is unavailable inside this project."; return }
            workspace?.openFile(candidate)
        }, for: "open-build-log")
    }

    func generate(refining: Bool = false) {
        guard !busy, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let goal = self.goal, controls = self.controls, previous = plan, refinement = self.refinement
        let root = self.root
        let feature = draft?.feature
        if feature != nil { updateDraft { $0.preparation = .preparing; $0.blocker = nil } }
        let plannerTool = CLITool.allCases.first { $0.displayName == plannerAgent }, plannerModel = self.plannerModel
        busy = true; error = nil
        task = Task { [weak self] in
            do {
                let choices = await self?.loadAgents() ?? []
                try Task.checkCancellation()
                guard !choices.isEmpty else { throw PlanningFailure.noAgents }
                self?.agents = choices
                let agents = choices.map(\.name)
                let models = Dictionary(uniqueKeysWithValues: choices.map { ($0.name, Set($0.models.map(\.id).filter { !$0.isEmpty })) })
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let listing = await Task.detached { QAStore.loadScenarios(root) }.value
                try Task.checkCancellation()
                self?.qaScenarios = listing.scenarios
                let scenarios = listing.scenarios.map { scenario in
                    ["id": scenario.id, "title": scenario.title, "targets": scenario.targets.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] }] as [String: Any]
                }
                let scenarioData = try JSONSerialization.data(withJSONObject: scenarios, options: [.sortedKeys])
                let settings = String(decoding: try encoder.encode(controls), as: UTF8.self)
                let offered = choices.map { choice in
                    let ids = choice.models.map(\.id).filter { !$0.isEmpty }
                    var parts: [String] = []
                    if !ids.isEmpty { parts.append("models: " + ids.joined(separator: ", ")) }
                    if feature != nil { parts.append(choice.delegation.map { "delegation: " + $0 } ?? "delegation: none") }
                    return parts.isEmpty ? choice.name : "\(choice.name) (\(parts.joined(separator: "; ")))"
                }
                var prompt = feature.map { CockpitPlanning.managedPrompt(feature: $0) + "\n" } ?? ""
                prompt += "Goal: \(goal)\nAvailable agents and their models: \(offered.joined(separator: "; "))\nControls (MarkView enforces them while the plan runs): \(settings)\n"
                prompt += "Existing QA scenarios and targets (JSON): \(String(decoding: scenarioData, as: UTF8.self))\n"
                prompt += "Available project actions include the MarkView MCP project, browser and control tools and the user's agent terminal. Check project capabilities before asserting an action is available.\n"
                if refining, var previous {
                    // A managed plan's delivery steps are MarkView's: the planner revises only the implementation steps and gets those
                    // back alone, so a step it returns is never taken for one of its own and added twice (DEC-030).
                    if feature != nil {
                        previous.steps = previous.steps.filter { ($0.kind ?? .work) == .work }
                        previous.successCriteria = previous.successCriteria.filter { !$0.hasPrefix("Definition of Done — ") }
                        prompt += "The current plan below lists only its implementation steps; MarkView adds the delivery steps again.\n"
                    }
                    prompt += "Current plan: \(String(decoding: try encoder.encode(previous), as: UTF8.self))\nRequested changes: \(refinement)\n"
                }
                let planning = AIOperation<CLICompletion.Request, CockpitPlan>(
                    name: "cockpit-plan",
                    parse: { result in
                        try CockpitPlanning.parse(result.structured, goal: goal, controls: controls, availableAgents: Set(agents), models: models)
                    })
                var (plan, _) = try await planning.execute(CLICompletion.Request(project: root, prompt: prompt,
                    systemPrompt: CockpitPlanning.systemPrompt, jsonSchema: CockpitPlanning.schema,
                    readableFolder: root, timeout: nil, toolOverride: plannerTool, model: plannerModel, label: "cockpit-plan"))
                if let feature {
                    // A refinement gets the whole plan back; only its implementation steps are the planner's (DEC-030).
                    let work = plan.steps.filter { ($0.kind ?? .work) == .work }
                    guard !work.isEmpty else { throw CockpitPlanning.ParseError.invalid(plan.unavailableOutcomes.isEmpty ? ["The planner proposed no implementation steps."] : plan.unavailableOutcomes) }
                    let implementer = work.first?.agent ?? choices[0].name
                    let reviewer = choices.first { $0.name != implementer }?.name ?? implementer
                    let delegation = Set(choices.filter { $0.delegation != nil }.map(\.name))
                    let composed = CockpitManagedRun.compose(work: work, criteria: plan.successCriteria, feature: feature,
                                                             implementer: implementer, reviewer: reviewer, delegation: delegation)
                    plan.steps = composed.steps
                    plan.successCriteria = composed.criteria
                    plan.feature = feature
                }
                guard Set(plan.scenarios).isSubset(of: Set(listing.scenarios.map(\.id))) else {
                    throw CockpitPlanning.ParseError.invalid(["The proposed QA scenario is not available in this project."])
                }
                if !plan.scenarios.isEmpty {
                    let savedLogins = await Task.detached { BrowserPasswordStore.shared.all() }.value
                    self?.qaLogins = Set(savedLogins.map { QALoginReference(host: $0.host, username: $0.username) })
                } else { self?.qaLogins = [] }
                try Task.checkCancellation()
                guard self?.goal == goal, self?.controls == controls else {
                    self?.error = "The goal or controls changed during planning. Propose the plan again."
                    self?.busy = false
                    return
                }
                self?.plan = plan; self?.planNeedsRecheck = false; self?.refinement = ""; self?.busy = false
                if feature != nil { self?.updateDraft { $0.preparation = .ready; $0.blocker = nil } }
                self?.persistDraft()
            } catch is CancellationError {
                self?.busy = false
                if feature != nil, self?.plan == nil { self?.updateDraft { $0.preparation = .blocked; $0.blocker = "Planning was cancelled." } }
            } catch {
                self?.error = error.localizedDescription; self?.busy = false
                if feature != nil, self?.plan == nil { self?.updateDraft { $0.preparation = .blocked; $0.blocker = error.localizedDescription } }
            }
        }
    }

    func cancel() { task?.cancel() }

    enum PlanningFailure: LocalizedError {
        case noAgents
        var errorDescription: String? { "No supported agent CLI with MarkView tools enabled was found." }
    }
}

/// An agent that can run a step in this project: its models, and the one "default" means for it here.
struct CockpitAgentChoice: Identifiable, Equatable {
    let tool: CLITool
    let models: [AIModelOption]
    /// The model the agent runs when a step names none: the project's chosen model, or the agent's own configured one; nil when neither is known.
    let defaultModel: String?

    var id: String { tool.displayName }
    var name: String { tool.displayName }
    /// How the agent delegates to subagents of its own within a step; nil when it cannot (REQ-002).
    var delegation: String? { tool.provider.cockpitDelegation }
    /// The arguments its terminal is started with: the permissions every step and delegate of it has (REQ-004 warning).
    var permissions: [String] { tool.fullAccessArgs }

    /// How a step's model reads: its own name, or what the default is right now.
    func label(forModel model: String?) -> String {
        let chosen = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !chosen.isEmpty { return models.first { $0.id == chosen }?.name ?? chosen }
        return defaultModel.map { "default (\($0))" } ?? "default model"
    }
}

// MARK: - Managed implementation runs (agent-aware-implementation-runs)

extension CockpitSession {
    // MARK: Feature drafts

    /// Build chose Cockpit for a feature (REQ-001): its draft opens on the plan screen, the draft of the feature that was there is
    /// saved first, and a plan is prepared from the specification and the checklist unless the draft already has one for this
    /// exact checklist. Other features' drafts and runs are not touched.
    func prepareFeature(_ feature: CockpitFeatureContext, goal featureGoal: String) {
        persistDraft()
        recoveryRun = nil
        startBlocker = nil
        evidenceNote = []
        let existing = drafts.first { $0.slug == feature.slug }
        if var existing, existing.feature.done == feature.done, existing.plan != nil {
            existing.feature.conflicts = feature.conflicts
            existing.feature.mandatory = feature.mandatory
            show(existing)
            return
        }
        var controls = existing?.controls ?? CockpitControls()
        // A new feature draft lets steps delegate where their agent supports it (DEC-033); the person can switch it off before approval.
        if existing == nil { controls.allowDelegation = true }
        let fresh = CockpitDraft(feature: feature, goal: existing?.goal ?? featureGoal, controls: controls, plan: nil,
                                 preparation: .preparing, blocker: nil, approved: nil, runID: existing?.runID, updated: Date())
        show(fresh)
        persistDraft()
        generate()
    }

    /// Opens a feature's draft on the plan screen, keeping the one that was there.
    func openDraft(_ slug: String) {
        guard draft?.slug != slug, let target = drafts.first(where: { $0.slug == slug }) else { screen = .plan; return }
        persistDraft()
        show(target)
    }

    /// "New plan": the plan screen for a goal of the person's own; the draft that was there is kept.
    func leaveDraft() {
        guard draft != nil else { screen = .plan; return }
        persistDraft()
        cancel()
        draft = nil
        plan = nil
        goal = ""
        controls = CockpitControls()
        startBlocker = nil
        evidenceNote = []
        screen = .plan
    }

    private func show(_ target: CockpitDraft) {
        cancel()
        busy = false
        draft = target
        goal = target.goal
        controls = target.controls
        plan = target.plan
        planNeedsRecheck = false
        error = nil
        startBlocker = nil
        evidenceNote = []
        screen = .plan
        if let index = drafts.firstIndex(where: { $0.slug == target.slug }) { drafts[index] = target } else { drafts.append(target) }
    }

    func updateDraft(_ change: (inout CockpitDraft) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
        persistDraft()
    }

    /// Writes the draft on screen with what the plan screen holds now. An approval holds only for the plan it was given for.
    func persistDraft() {
        guard var current = draft else { return }
        current.goal = goal
        current.controls = controls
        current.plan = plan
        if let approved = current.approved, approved.plan != (try? preparedPlan(startingAt: approved.step)) { current.approved = nil }
        current.updated = Date()
        draft = current
        if let index = drafts.firstIndex(where: { $0.slug == current.slug }) { drafts[index] = current } else { drafts.append(current) }
        let root = root
        let saved = current
        tasks.store(Task { [weak self] in
            do { try await Task.detached { try CockpitDraftStore.save(saved, root: root) }.value }
            catch { self?.error = "The Cockpit draft could not be saved: \(error.localizedDescription)" }
        }, for: "draft-save:" + current.slug)
    }

    /// The person read the conflicts between the checklist and the project's rules and runs with the checklist as it is (REQ-004).
    func acknowledgeConflicts(_ acknowledged: Bool) {
        editPlan { $0.feature?.conflictsAcknowledged = acknowledged }
        updateDraft { $0.feature.conflictsAcknowledged = acknowledged }
    }

    /// The feature goes to the assistant terminal instead, with the checklist the person reviewed (REQ-001).
    func handOffDraftDirectly() {
        guard let draft else { return }
        workspace?.handOffDirectly(draft.feature)
    }

    // MARK: Approve, then Start

    /// The person approved the exact plan on screen; it does not start (REQ-001).
    func approveDraft(reviewed: CockpitPlan, productionConfirmed: Bool) {
        guard draft != nil, !busy, (try? preparedPlan(startingAt: 0)) == reviewed,
              let approval = CockpitApproval(plan: reviewed, productionConfirmed: productionConfirmed) else { return }
        updateDraft { $0.approved = CockpitDraft.Approval(approval: approval, step: 0, productionConfirmed: productionConfirmed, plan: reviewed) }
    }

    var draftApprovalHolds: Bool {
        guard let approved = draft?.approved else { return false }
        return approved.plan == (try? preparedPlan(startingAt: approved.step)) && approved.approval.permits(approved.plan)
    }

    /// The explicit Start of an approved draft: the agents are checked again in this launch profile, the project must have no
    /// unfinished run, and the run starts at the first step current evidence does not support (REQ-002, DEC-027).
    func startDraft() {
        guard let current = draft, let approved = current.approved, draftApprovalHolds, !startingExecution, execution?.isActive != true else { return }
        startingExecution = true
        startBlocker = nil
        error = nil
        let root = root
        tasks.store(Task { [weak self] in
            guard let self else { return }
            let choices = await self.loadAgents()
            self.agents = choices
            if let problem = Self.capabilityProblem(plan: approved.plan, agents: choices) {
                self.startBlocker = problem; self.startingExecution = false; return
            }
            let delivery = await CockpitDeliveryProbe.probe(root: root, branch: current.feature.branch)
            let (index, skipped) = CockpitManagedRun.firstUnsupported(plan: approved.plan, results: [], managed: CockpitManagedState(), delivery: delivery)
            guard approved.plan.steps.indices.contains(index) else {
                self.startBlocker = "Current evidence supports every step of this plan, so there is nothing to run."
                self.startingExecution = false; return
            }
            guard let plan = approved.plan.selectingStart(index), plan == approved.plan || index == approved.step else {
                self.startBlocker = "Evidence moves the start to step \(index + 1), which changes what was approved. Review and approve the plan again."
                self.startingExecution = false; return
            }
            self.evidenceNote = skipped
            self.startingExecution = false
            let slug = current.slug
            self.launch(plan: approved.plan, approval: approved.approval, index: index, recovering: nil,
                        productionConfirmed: approved.productionConfirmed) { [weak self] runID in
                guard let self else { return }
                if self.draft?.slug == slug { self.updateDraft { $0.runID = runID; $0.approved = nil } }
                else if let index = self.drafts.firstIndex(where: { $0.slug == slug }) {
                    self.drafts[index].runID = runID; self.drafts[index].approved = nil
                    let saved = self.drafts[index]
                    try? CockpitDraftStore.save(saved, root: root)
                }
            }
        }, for: "start-draft")
    }

    /// What keeps a managed plan from running in this launch profile: an agent that is not installed here or has no MarkView tools, or
    /// one that cannot run unattended (REQ-002). nil when every step can run.
    static func capabilityProblem(plan: CockpitPlan, agents: [CockpitAgentChoice]) -> String? {
        let available = Dictionary(uniqueKeysWithValues: agents.map { ($0.name, $0) })
        var missing: [String: [Int]] = [:]
        for (index, step) in plan.steps.enumerated() where available[step.agent] == nil { missing[step.agent, default: []].append(index + 1) }
        if !missing.isEmpty {
            let names = missing.keys.sorted().map { "\($0) (step\(missing[$0]!.count == 1 ? "" : "s") \(missing[$0]!.map(String.init).joined(separator: ", ")))" }
            let others = agents.map(\.name).filter { missing[$0] == nil }
            return "Not available in this launch profile (not installed, or MarkView tools are off): \(names.joined(separator: "; ")). "
                + (others.isEmpty ? "No other agent with MarkView tools is available." : "Choose another agent for those steps: \(others.joined(separator: ", ")).")
        }
        if let unattended = Set(plan.steps.map(\.agent)).sorted().first(where: { available[$0]?.permissions.isEmpty == true }) {
            return "\(unattended) has no launch arguments for unattended work, so its steps would stop at permission prompts nobody answers."
        }
        return nil
    }

    /// The pre-launch warning (REQ-004): the permissions each agent of the plan runs with, which its delegates keep too.
    static func permissionWarning(plan: CockpitPlan) -> String {
        let agents = Set(plan.steps.map(\.agent)).sorted()
        let lines = agents.map { name -> String in
            let tool = CLITool.allCases.first { $0.displayName == name }
            let arguments = tool?.fullAccessArgs.joined(separator: " ") ?? ""
            return arguments.isEmpty ? "\(name): its own permission prompts." : "\(name): started with \(arguments)."
        }
        let asks = plan.steps.filter { $0.asksFirst == true }.map(\.title)
        return "Agents and their delegates keep the permissions of their launch profiles — " + lines.joined(separator: " ")
            + (asks.isEmpty ? "" : " Cockpit waits for you before: \(asks.joined(separator: ", ")); an agent whose permissions allow it can still do such an action directly through its terminal, and Cockpit then records it as done outside Cockpit without its approval.")
    }

    // MARK: Gates of a managed step

    /// What a managed step meets before its agent runs (REQ-002, REQ-004): a delivery action already done outside Cockpit is recorded
    /// and skipped, one whose state cannot be read stays pending, merge and release wait for unresolved review findings, and an Ask me
    /// action waits for the person. nil when the agent may run.
    fileprivate func managedGate(step: CockpitStep, feature: CockpitFeatureContext) async -> CockpitHostReply? {
        let kind = step.kind ?? .work
        func reply(_ passed: Bool, _ detail: String) -> CockpitHostReply {
            CockpitHostReply(result: CockpitHostResult(passed: passed, detail: detail, build: ""), error: "")
        }
        // A retry waits until every process of an earlier attempt that could still write to the checkout has stopped (REQ-003).
        let recorded = execution?.record?.managed?.delegates ?? []
        if !recorded.isEmpty {
            let alive = await Task.detached { CockpitDelegateWatch.alive(recorded) }.value
            if !alive.isEmpty {
                return reply(false, "Processes of an earlier attempt are still running and may write to the checkout, so \(step.title) waits:\n"
                             + alive.map { "- \($0.command) (process \($0.pid))" }.joined(separator: "\n"))
            }
            await execution?.updateManaged({ $0.delegates = [] }, event: "The processes of the earlier attempt have stopped.")
        }
        var head: String?
        if kind.isExternalDelivery {
            let delivery = await CockpitDeliveryProbe.probe(root: root, branch: feature.branch)
            head = delivery.head
            let managed = execution?.record?.managed ?? CockpitManagedState()
            switch CockpitManagedRun.support(for: step, feature: feature, results: [], managed: managed, delivery: delivery) {
            case .supported(let evidence):
                await execution?.updateManaged({ state in
                    state.external.append(CockpitExternalCompletion(stepID: step.id, evidence: evidence, at: Date()))
                    if let head = delivery.head { state.revisions[step.id.uuidString] = head }
                }, event: "\(step.title): already done outside Cockpit, without its approval. \(evidence)")
                markImplementationStarted(feature: feature, agent: step.agent)
                return reply(true, "Completed outside Cockpit without its approval. \(evidence) The scheduled action was skipped.")
            case .uncertain(let reason):
                return reply(false, "\(step.title) is pending: \(reason) Retry when its state can be established.")
            case .unsupported:
                break
            }
        }
        let managed = execution?.record?.managed ?? CockpitManagedState()
        if kind.isPublishing {
            var revision = head
            if revision == nil { revision = await CockpitDeliveryProbe.head(root: root) }
            let blocking = managed.blockingFindings(at: revision)
            if !blocking.isEmpty {
                await execution?.updateManaged({ _ in }, event: "\(step.title) is blocked by review findings: \(blocking.map(\.id).joined(separator: ", ")).")
                return reply(false, "\(step.title) is blocked by review findings without a verified fix or an accepted risk for revision \(String((revision ?? "unknown").prefix(9))):\n"
                             + blocking.map { "- \($0.id) \($0.title) (violates \($0.basis == .criterion ? "acceptance criterion" : "project rule"): \($0.reference))" }.joined(separator: "\n"))
            }
        }
        if step.asksFirst == true {
            switch managed.decision(for: step.id)?.approved {
            case nil:
                return reply(false, "Waiting for your approval: \(step.title).")
            case false?:
                if step.doneItem.map(feature.mandatory.contains) == true {
                    return reply(false, "You declined \(step.title), which the project requires for delivery: delivery is blocked by it.")
                }
                return reply(true, "Declined by you; not performed.")
            case true?:
                break
            }
        }
        return nil
    }

    /// What a managed step's agent is told on top of the step prompt.
    fileprivate static func managedBrief(_ step: CockpitStep, branch: String, repairing: Bool = false) -> String {
        var lines = ["This step belongs to a managed implementation run. If the prior results show an interrupted attempt of this step, its changes are still in this checkout: continue from them and do not discard, reset or stash them."]
        // DEC-036: the steps that write or deliver the change may change source and commit; the verifiers may not. DEC-037: the repair
        // attempt of a verification may, because the verification then checks again.
        if repairing {
            lines.append("This is a repair attempt for a step that failed: you may change source files and commit on \(branch), never on the default branch, and push so the checks run on the new head. The Fix bugs control does not restrict this repair. After your report Cockpit checks again; that check may not change anything.")
        } else {
            lines.append((step.kind ?? .work).isVerification
                ? "This step checks the change: do not change source files and do not commit. MarkView compares the project before and after this step and fails it if you do; report what needs changing instead."
                : "This step writes or delivers the change: you may change source files and commit on \(branch), never on the default branch. The Fix bugs control does not restrict this step's own changes; it only governs moving a bug into fixing.")
        }
        switch step.kind ?? .work {
        case .review: lines.append("Report each confirmed violation in findings (title, detail, basis \"criterion\" or \"rule\", reference).")
        case .fix, .reverify: lines.append("Report findingChecks for the findings you checked: their ids are R1, R2, … as the prior results list them.")
        case .branch, .pullRequest, .checks, .merge, .release: lines.append("If this action turns out to be done already, verify it and report it with evidence instead of repeating it.")
        default: break
        }
        return lines.joined(separator: " ")
    }

    /// The feature counts as being implemented from the first step of its approved run that starts (REQ-001); once per run.
    fileprivate func markImplementationStarted(feature: CockpitFeatureContext, agent: String) {
        guard let execution, execution.record?.managed?.implementationStarted != true, let workspace else { return }
        workspace.features.markImplementing(feature.slug, handoff: "Cockpit · " + agent)
        if let tool = CLITool.allCases.first(where: { $0.displayName == agent }) {
            workspace.features.recordImplementationStarted(feature.slug, tool: tool, directory: root, runningSince: nil)
        }
        // task: one save on the execution, which owns its own end
        Task { await execution.updateManaged({ $0.implementationStarted = true }) }
    }

    // MARK: The person's answers while a managed run waits

    /// The person approves or declines the Ask me action the run waits on; the step then runs again and meets the answer.
    func decide(stepID: UUID, approved: Bool) {
        guard let execution, execution.isActive else { return }
        tasks.store(Task { [weak self] in
            let title = execution.record?.plan.steps.first { $0.id == stepID }?.title ?? "the action"
            await execution.updateManaged({ $0.decide(stepID, approved: approved) }, event: approved ? "You approved \(title)." : "You declined \(title).")
            do { try await execution.control("retry") } catch { self?.error = error.localizedDescription }
        }, for: "decide")
    }

    /// The person accepts the risk of one finding for the revision in the checkout, with a rationale (DEC-029, DEC-032).
    func acceptRisk(findingID: String, rationale: String) {
        guard let execution, execution.isActive else { return }
        let root = root
        tasks.store(Task { [weak self] in
            let revision = await CockpitDeliveryProbe.head(root: root)
            var state = execution.record?.managed ?? CockpitManagedState()
            do { try state.acceptRisk(findingID, rationale: rationale, revision: revision) }
            catch let failure as CockpitManagedState.AcceptanceFailure {
                switch failure {
                case .notPermitted: self?.error = "A finding against a mandatory project rule can only be lifted by a verified fix."
                case .noRationale: self?.error = "Say why you accept this risk."
                case .noRevision: self?.error = "The checkout's revision is unknown, so the acceptance cannot be tied to it."
                case .unknown: self?.error = "That finding is no longer part of the run."
                }
                return
            } catch { return }
            await execution.updateManaged({ $0 = state }, event: "You accepted the risk of \(findingID) for revision \(String((revision ?? "").prefix(9))).")
        }, for: "accept-risk")
    }

    /// Retries the step the live run waits on.
    func retryStep() { control("retry") }

    /// Continues a managed run from the first step current evidence does not support (DEC-027): after a failed or interrupted step, a
    /// limit, a decline or a blocked merge. A live workflow is stopped first, the processes of an interrupted step must have ended, and
    /// external actions are read back before they are tried again (REQ-003).
    func continueManaged(_ run: CockpitRun) {
        guard let feature = run.plan.feature, !continuingManaged, !startingExecution else { return }
        continuingManaged = true
        error = nil
        startBlocker = nil
        let root = root
        tasks.store(Task { [weak self] in
            defer { self?.continuingManaged = false }
            let alive = await Task.detached { CockpitDelegateWatch.alive(run.managed?.delegates ?? []) }.value
            guard let self else { return }
            guard alive.isEmpty else {
                self.startBlocker = "Processes of the interrupted step are still running: "
                    + alive.map { "\($0.command) (process \($0.pid))" }.joined(separator: ", ") + ". Stop them before continuing."
                return
            }
            if let execution = self.execution, execution.runID == run.id, execution.isActive {
                try? await execution.control("stop")
                for _ in 0..<150 where execution.isActive { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard !execution.isActive else { self.startBlocker = "The run did not stop, so it cannot continue yet."; return }
            }
            let latest = (try? await Task.detached { try CockpitRunStore.load(run.id, root: root) }.value) ?? run
            guard let approval = latest.approval, approval.permits(latest.plan) else { self.startBlocker = "The run's approval no longer holds."; return }
            let delivery = await CockpitDeliveryProbe.probe(root: root, branch: feature.branch)
            let (index, skipped) = CockpitManagedRun.firstUnsupported(plan: latest.plan, results: latest.results,
                                                                       managed: latest.managed ?? CockpitManagedState(), delivery: delivery)
            guard latest.plan.steps.indices.contains(index) else {
                self.startBlocker = "Current evidence supports every step of this run, so there is nothing left to run."
                return
            }
            self.evidenceNote = skipped
            self.launch(plan: latest.plan, approval: approval, index: index, recovering: latest, productionConfirmed: false)
        }, for: "continue-managed")
    }

    /// Stops the processes of a step that are still alive and records which of them remain (REQ-003).
    func stopDelegates(_ run: CockpitRun) {
        let recorded = run.managed?.delegates ?? []
        guard !recorded.isEmpty else { return }
        let root = root
        tasks.store(Task { [weak self] in
            let remaining = await CockpitDelegateWatch.stop(recorded)
            guard let self else { return }
            let event = remaining.isEmpty ? "Every process of the step has stopped." : "\(remaining.count) process(es) could not be stopped."
            if let execution = self.execution, execution.runID == run.id {
                await execution.updateManaged({ $0.delegates = remaining }, event: event)
            } else {
                do {
                    try await Task.detached {
                        var saved = try CockpitRunStore.load(run.id, root: root)
                        saved.updateManaged({ $0.delegates = remaining }, event: event)
                        try CockpitRunStore.save(saved, root: root)
                    }.value
                } catch { self.error = "The run could not be updated: \(error.localizedDescription)" }
                self.loadRuns()
            }
            if !remaining.isEmpty { self.error = "Still running: " + remaining.map { "\($0.command) (process \($0.pid))" }.joined(separator: ", ") }
        }, for: "stop-delegates")
    }

    /// Ends a saved run that no longer runs anywhere, so the project can start another (REQ-001).
    func endRun(_ run: CockpitRun) {
        guard execution?.runID != run.id || execution?.isActive != true, run.isUnfinished else { return }
        let root = root
        tasks.store(Task { [weak self] in
            do {
                try await Task.detached {
                    var saved = try CockpitRunStore.load(run.id, root: root)
                    saved.end()
                    try CockpitRunStore.save(saved, root: root)
                }.value
                self?.startBlocker = nil
            } catch { self?.error = "The run could not be ended: \(error.localizedDescription)" }
            self?.loadRuns()
        }, for: "end-run")
    }
}
