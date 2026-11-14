import Foundation
import Combine

@MainActor
final class CockpitSession: ObservableObject {
    let root: URL
    @Published var goal = ""
    @Published var controls = CockpitControls()
    @Published var refinement = ""
    @Published private(set) var plan: CockpitPlan?
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
    @Published private(set) var qaScenarios: [QAScenario] = []
    @Published private(set) var deletedQARuns: Set<String> = []
    @Published var qaTargets: [String: String] = [:]
    private var qaLogins: Set<QALoginReference> = []
    @Published private(set) var startingExecution = false
    private weak var workspace: WorkspaceManager?
    private var executionChange: AnyCancellable?
    private var executionTask: Task<Void, Never>?
    private var loadedTerminalStatus: String?
    private struct ReviewedExecution { var plan: CockpitPlan; var productionConfirmed: Bool }
    private var reviewedExecutions: [String: ReviewedExecution] = [:]
    private var reportingStep: (id: UUID, fingerprint: String)?
    private var task: Task<Void, Never>?

    init(root: URL, workspace: WorkspaceManager) { self.root = root; self.workspace = workspace; loadRuns() }

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
        guard !busy, !startingExecution, execution?.isActive != true, let workspace,
              (try? preparedPlan(startingAt: index)) == reviewed,
              let approval = CockpitApproval(plan: reviewed, productionConfirmed: productionConfirmed), reviewed.steps.indices.contains(index) else { return }
        let plan = reviewed
        let recovering = recoveryRun
        let attempt = CockpitAgentAttempt(workspace: workspace, root: root) { [weak self] progress in
            guard let self else { throw CancellationError() }
            try await self.publishProgress(progress)
        }
        guard let fingerprint = try? CockpitTemporalPlan(plan).fingerprint else { return }
        reviewedExecutions = [fingerprint: ReviewedExecution(plan: plan, productionConfirmed: productionConfirmed)]
        pendingPlan = nil
        let execution = CockpitExecution(root: root, service: .forProject(root)) { [weak self] task in
            guard let self else { return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "The cockpit was closed.") }
            return await self.perform(task, attempt: attempt)
        }
        loadedTerminalStatus = nil
        executionChange = execution.objectWillChange.sink { [weak self, weak execution] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self, weak execution] in
                await Task.yield()
                if let self, let fingerprint = execution?.state?.fingerprint,
                   let reviewed = self.reviewedExecutions[fingerprint], self.runningPlan != reviewed.plan {
                    self.runningPlan = reviewed.plan
                    if self.pendingPlan == reviewed.plan { self.pendingPlan = nil }
                }
                if let self, let status = execution?.state?.status, ["finished", "stopped"].contains(status), self.pendingPlan != nil {
                    self.error = "The run ended before the approved changes were applied."
                    self.pendingPlan = nil
                }
                guard let self, let status = execution?.state?.status,
                      ["finished", "stopped", "interrupted"].contains(status), self.loadedTerminalStatus != status else { return }
                self.loadedTerminalStatus = status
                self.loadRuns()
            }
        }
        self.execution = execution
        runningPlan = plan
        currentProgress = CockpitProgress(passNumber: 1, activity: "Starting the selected step", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
        startingExecution = true
        error = nil
        executionTask = Task { [weak self] in
            do {
                try await execution.start(plan: plan, approval: approval, step: index, recovering: recovering)
                self?.recoveryRun = nil
            }
            catch { self?.error = error.localizedDescription }
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
        attempt.onFixCycle = { [weak self] count in self?.execution?.noteFixCycles(fromGate: count) }
        let result = await attempt.run(task)
        guard result.error.isEmpty, result.result.passed, let id = task.step.qaScenarioID, !id.isEmpty else { return result }
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
        reviewedExecutions[fingerprint] = ReviewedExecution(plan: reviewed, productionConfirmed: productionConfirmed)
        pendingPlan = reviewed
        revisingExecution = true
        error = nil
        Task { [weak self] in
            do { try await execution.replan(reviewed, approval: approval, step: index) }
            catch { self?.error = error.localizedDescription }
            self?.revisingExecution = false
        }
    }

    func control(_ command: String) {
        guard let execution else { return }
        Task { [weak self] in
            do { try await execution.control(command) }
            catch { self?.error = error.localizedDescription }
        }
    }

    func cancelExecutionStartup() {
        executionTask?.cancel()
        execution?.shutdown()
    }

    func closeProject() {
        cancel()
        executionTask?.cancel()
        execution?.shutdown()
    }

    func loadRuns() {
        let root = self.root
        Task { [weak self] in
            do {
                let runs = try await Task.detached { try CockpitRunStore.loadAll(root: root) }.value
                let qaResults = await Task.detached { Result { try CockpitResults.loadAll(root: root) } }.value
                guard let self else { return }
                switch qaResults {
                case .success(let results): self.savedQAResults = results
                case .failure(let error): self.error = "Some QA evidence could not be loaded: \(error.localizedDescription)"
                }
                let activeID = self.execution?.isActive == true ? self.execution?.runID : nil
                self.savedRuns = runs.filter { $0.id != activeID }
                let ids = Set(runs.flatMap { $0.results.compactMap(\.qaRunID) })
                self.deletedQARuns = await Task.detached {
                    Set(ids.filter { id in
                        guard QARunRetention.runID(inBugKey: id + ":result") == id else { return true }
                        return !FileManager.default.fileExists(atPath: QAStore.runFolder(root, runID: id).appendingPathComponent("run.json").path)
                    })
                }.value
            }
            catch { self?.error = "Saved cockpit runs could not be loaded: \(error.localizedDescription)" }
        }
    }

    func prepareRecovery(_ run: CockpitRun, usePending: Bool = false) {
        guard execution?.isActive != true, (run.status == .paused || run.status == .stopped), let index = run.currentIndex,
              run.steps.indices.contains(index), run.steps[index].status == .interrupted else { return }
        guard let selected = usePending ? run.pendingRevision?.plan : run.plan else { return }
        loadingRecovery = true
        let root = root
        Task { [weak self] in
            let listing = await Task.detached { QAStore.loadScenarios(root) }.value
            let saved: [SavedLogin]
            if selected.scenarios.isEmpty { saved = [] }
            else { saved = await Task.detached { BrowserPasswordStore.shared.all() }.value }
            guard let self else { return }
            self.qaScenarios = listing.scenarios
            self.qaLogins = Set(saved.map { QALoginReference(host: $0.host, username: $0.username) })
            self.qaTargets = (selected.qaReviews ?? []).reduce(into: [:]) { $0[$1.scenarioID] = $1.targetID }
            self.goal = selected.goal
            self.controls = selected.controls
            self.plan = selected
            self.recoveryRun = run
            self.loadingRecovery = false
        }
    }

    func cancelRecovery() { recoveryRun = nil }

    func openQAResult(scenarioID: String, runID: String) {
        guard let workspace else { return }
        workspace.openQA()
        let qa = workspace.qa
        qa.reload()
        Task { [weak self, weak qa] in
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
        }
    }

    func openBug(_ key: String) {
        guard let workspace else { return }
        if let bug = workspace.features.bugs.first(where: { $0.key == key }) { workspace.openFile(bug.url); return }
        workspace.features.reload()
        Task { [weak self, weak workspace] in
            for _ in 0..<100 {
                guard let workspace else { return }
                if let bug = workspace.features.bugs.first(where: { $0.key == key }) { workspace.openFile(bug.url); return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.error = "The linked bug is no longer available: \(key)"
        }
    }

    func openBuildLog(_ path: String) {
        guard let workspace, !path.isEmpty else { return }
        let root = root
        Task { [weak self, weak workspace] in
            let candidate = await Task.detached { () -> URL? in
                let project = root.standardizedFileURL.resolvingSymlinksInPath()
                let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : project.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
                guard candidate.path.hasPrefix(project.path + "/"), FileManager.default.fileExists(atPath: candidate.path) else { return nil }
                return candidate
            }.value
            guard let candidate else { self?.error = "The linked build log is unavailable inside this project."; return }
            workspace?.openFile(candidate)
        }
    }

    func generate(refining: Bool = false) {
        guard !busy, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let goal = self.goal, controls = self.controls, previous = plan, refinement = self.refinement
        let root = self.root
        let candidates = CLITool.allCases.filter { BrowserControlServer.agentToolsEnabled($0) }
        busy = true; error = nil
        task = Task { [weak self] in
            do {
                var agents: [String] = []
                for tool in candidates {
                    try Task.checkCancellation()
                    if await CLIToolLocator.resolveThorough(tool) != nil { agents.append(tool.displayName) }
                }
                guard !agents.isEmpty else { throw PlanningFailure.noAgents }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                let listing = await Task.detached { QAStore.loadScenarios(root) }.value
                try Task.checkCancellation()
                self?.qaScenarios = listing.scenarios
                let scenarios = listing.scenarios.map { scenario in
                    ["id": scenario.id, "title": scenario.title, "targets": scenario.targets.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] }] as [String: Any]
                }
                let scenarioData = try JSONSerialization.data(withJSONObject: scenarios, options: [.sortedKeys])
                let settings = String(decoding: try encoder.encode(controls), as: UTF8.self)
                var prompt = "Goal: \(goal)\nAvailable agents: \(agents.joined(separator: ", "))\nControls (MarkView enforces them while the plan runs): \(settings)\n"
                prompt += "Existing QA scenarios and targets (JSON): \(String(decoding: scenarioData, as: UTF8.self))\n"
                prompt += "Available project actions include the MarkView MCP project, browser and control tools and the user's agent terminal. Check project capabilities before asserting an action is available.\n"
                if refining, let previous {
                    prompt += "Current plan: \(String(decoding: try encoder.encode(previous), as: UTF8.self))\nRequested changes: \(refinement)\n"
                }
                let result = try await CLICompletion.run(CLICompletion.Request(project: root, prompt: prompt,
                    systemPrompt: CockpitPlanning.systemPrompt, jsonSchema: CockpitPlanning.schema,
                    readableFolder: root, timeout: nil, label: "cockpit-plan"))
                let plan = try CockpitPlanning.parse(result.structured, goal: goal, controls: controls, availableAgents: Set(agents))
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
                self?.plan = plan; self?.refinement = ""; self?.busy = false
            } catch is CancellationError {
                self?.busy = false
            } catch {
                self?.error = error.localizedDescription; self?.busy = false
            }
        }
    }

    func cancel() { task?.cancel() }
    func invalidatePlan() { plan = nil }

    enum PlanningFailure: LocalizedError {
        case noAgents
        var errorDescription: String? { "No supported agent CLI with MarkView tools enabled was found." }
    }
}
