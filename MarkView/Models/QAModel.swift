import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): the state of the QA tab. It keeps the scenarios of the project, the one being
// edited, and the generation in progress. Every edit is saved a moment later, off the main thread, so a scenario and its edits survive
// closing the tab, the window and the app (DEC-006).

@MainActor
final class QAModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case generating(attempt: Int, activity: String)
        case failed(String)
    }

    @Published private(set) var root: URL?
    @Published private(set) var scenarios: [QAScenario] = []
    /// When the assistant was asked to write the scenario; the sheet shows how long it has been working.
    @Published private(set) var generationStarted: Date?
    @Published private(set) var unreadable: [QAUnreadable] = []
    @Published private(set) var current: QAScenario?
    @Published var selectedNode: String?
    @Published var selectedEdge: QAEdge?
    /// The branch the pointer is over in the list: its steps are lit in the graph.
    @Published var lit: String?
    @Published private(set) var phase: Phase = .idle
    /// A line about what the last generation or save did, shown until the next action.
    @Published private(set) var notice: String?
    /// The environment the person chose to check; nil until they choose (or the scenario has one).
    @Published var targetID: String? { didSet { refreshGate() } }
    /// The logins the browser's password store holds (never the passwords), to choose a player's login from.
    @Published private(set) var savedLogins: [SavedLogin] = []
    /// The approval of the current plan. Nil until the person approves; it never outlives a change to the plan (DEC-002).
    @Published private(set) var gate: QAGate?

    /// The run in progress, or the last one (REQ-003). It outlives switching to another scenario.
    let run = QARunModel()

    private var saveTask: Task<Void, Never>?
    private var generation: Task<Void, Never>?
    private let saveDelay: UInt64 = 500_000_000

    var problems: [QAProblem] { current?.problems() ?? [] }

    /// What a run of the chosen branches against the chosen environment would do, as the scenario is now.
    var plan: QAExecutionPlan? {
        guard let current else { return nil }
        return QAPlanner.make(current, targetID: effectiveTargetID, savedLogins: Set(savedLogins.map { QALoginReference(host: $0.host, username: $0.username) }))
    }

    /// The chosen environment, or the only one there is.
    var effectiveTargetID: String? {
        guard let current else { return nil }
        if let targetID, current.target(targetID) != nil { return targetID }
        return current.targets.count == 1 ? current.targets[0].id : nil
    }
    var isGenerating: Bool { if case .generating = phase { return true } else { return false } }

    // MARK: Project

    /// Points the model at a project. The scenarios are read off the main thread.
    func attach(root newRoot: URL?) {
        guard newRoot != root else { return }
        flush()
        generation?.cancel()
        root = newRoot
        scenarios = []
        unreadable = []
        current = nil
        selectedNode = nil
        selectedEdge = nil
        phase = .idle
        notice = nil
        targetID = nil
        gate = nil
        reload()
    }

    func reload() {
        guard let root else { return }
        Task { [weak self] in
            let listing = await Task.detached(priority: .userInitiated) { QAStore.loadScenarios(root) }.value
            guard let self, self.root == root else { return }
            self.scenarios = listing.scenarios
            self.unreadable = listing.unreadable
            if let id = self.current?.id, !listing.scenarios.contains(where: { $0.id == id }), self.saveTask == nil { self.current = nil }
        }
    }

    // MARK: Opening and creating

    func open(_ id: String) {
        guard current?.id != id else { return }
        flush()
        guard let scenario = scenarios.first(where: { $0.id == id }) else { return }
        current = scenario
        selectedNode = nil
        selectedEdge = nil
        lit = nil
        notice = nil
        targetID = nil
        gate = nil
    }

    func close() {
        flush()
        current = nil
        selectedNode = nil
        selectedEdge = nil
        targetID = nil
        gate = nil
    }

    /// Adds a scenario to the project and opens it.
    func add(_ scenario: QAScenario) {
        flush()
        current = scenario
        selectedNode = nil
        selectedEdge = nil
        targetID = nil
        gate = nil
        upsert(scenario)
        save(scenario)
    }

    /// Makes a copy of a scenario and opens it: the copy is a scenario of its own, ready to be changed.
    func duplicate(_ id: String) {
        flush()
        guard let source = current?.id == id ? current : scenarios.first(where: { $0.id == id }) else { return }
        add(source.duplicated(existingIDs: existingIDs))
    }

    func delete(_ id: String) {
        guard let root else { return }
        if current?.id == id { current = nil; saveTask?.cancel(); saveTask = nil }
        scenarios.removeAll { $0.id == id }
        Task.detached { QAStore.deleteScenario(id, root: root) }
    }

    var existingIDs: Set<String> { Set(scenarios.map(\.id)) }

    // MARK: Editing

    /// Applies an edit to the open scenario and saves it shortly after.
    func edit(_ change: (inout QAScenario) -> Void) {
        guard var scenario = current else { return }
        change(&scenario)
        guard scenario != current else { return }
        current = scenario
        upsert(scenario)
        saveSoon()
        refreshGate()
    }

    // MARK: Approval (DEC-002)

    /// Gives the approval the plan as it is now: a plan that is no longer the one approved loses the approval.
    private func refreshGate() {
        guard var gate, let plan else { self.gate = nil; return }
        gate.update(plan: plan)
        self.gate = gate
    }

    /// Approves the plan as shown. On production the person has acknowledged the list of actions that change data.
    func approve(acknowledgedProduction: Bool) {
        guard let plan else { return }
        var next = QAGate(plan: plan)
        guard next.approve(acknowledgedProduction: acknowledgedProduction) else { return }
        gate = next
    }

    func withdrawApproval() { gate = nil }

    /// Starts the check of the chosen branches. Only an approved plan runs; the run takes its own copy of the scenario and the approval.
    func startRun() {
        guard let current, current.appKind == .web, let plan, let gate, let root, gate.canPrepare, !run.isRunning else { return }
        flush()
        run.start(scenario: current, plan: plan, gate: gate, root: root)
    }

    /// Reads the saved logins (user names and hosts only) off the main thread.
    func loadSavedLogins() {
        Task { [weak self] in
            let logins = await Task.detached(priority: .utility) { BrowserPasswordStore.shared.all() }.value
            self?.savedLogins = logins
        }
    }

    /// Saves a login in the browser's Keychain store (the one a scenario's login reference points into) off the main thread and refreshes the list.
    /// False when the Keychain refused it. The password is held only for the call.
    func saveLogin(host: String, username: String, password: String) async -> Bool {
        let saved = await Task.detached(priority: .userInitiated) { BrowserPasswordStore.shared.save(host: host, username: username, password: password) }.value
        if saved { savedLogins = await Task.detached(priority: .utility) { BrowserPasswordStore.shared.all() }.value }
        return saved
    }

    private func upsert(_ scenario: QAScenario) {
        if let index = scenarios.firstIndex(where: { $0.id == scenario.id }) { scenarios[index] = scenario } else {
            scenarios.append(scenario)
            scenarios.sort { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
        }
    }

    // MARK: Saving

    private func saveSoon() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            if let scenario = self.current { self.save(scenario) }
        }
    }

    /// Saves at once whatever waits for the delay: before another scenario opens, the project changes or the tab goes away.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        if let scenario = current { save(scenario) }
    }

    private func save(_ scenario: QAScenario) {
        guard let root else { return }
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .utility) {
                do { try QAStore.saveScenario(scenario, root: root); return nil } catch { return error.localizedDescription }
            }.value
            if let failure { self?.notice = "The scenario could not be saved: \(failure)" }
        }
    }

    // MARK: Generation

    func generate(_ request: QAGenerationRequest) {
        guard let root, !isGenerating else { return }
        var request = request
        request.existingIDs = existingIDs
        notice = nil
        generationStarted = Date()
        phase = .generating(attempt: 1, activity: request.attachments.isEmpty ? "Starting the assistant" : "Preparing the attached files")
        let inputsID = QAStore.newRunID(at: request.now)
        generation = Task { [weak self] in
            var staged = QAAttachments.Staged()
            defer { QAAttachments.discard(staged) }
            do {
                if !request.attachments.isEmpty {
                    let files = request.attachments
                    // Copying files is disk work: not on the main thread.
                    staged = try await Task.detached { try QAAttachments.stage(files, root: root, id: inputsID) }.value
                    request.attachmentPaths = staged.paths
                }
                let images = staged.images
                let outcome = try await QAGenerator.generate(
                    request,
                    onAttempt: { attempt in Task { @MainActor in self?.setAttempt(attempt) } },
                    complete: { prompt in
                        let result = try await CLICompletion.run(
                            CLICompletion.Request(project: root, prompt: prompt, systemPrompt: QAGeneration.systemPrompt(request.appKind),
                                                  jsonSchema: QAGeneration.schema, readableFolder: root, timeout: 420, images: images, label: "qa-generate"),
                            onActivity: { activity in Task { @MainActor in self?.setActivity(activity) } })
                        return QAGenerator.Answer(structured: result.structured, costUSD: result.costUSD)
                    })
                self?.finishGeneration(outcome)
            } catch is CancellationError {
                self?.phase = .idle
                self?.notice = "Generation was stopped."
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelGeneration() { generation?.cancel() }

    func dismissFailure() { if case .failed = phase { phase = .idle } }

    private func setAttempt(_ attempt: Int) {
        guard case .generating = phase else { return }
        phase = .generating(attempt: attempt, activity: attempt > 1 ? "Correcting the scenario" : "Starting the assistant")
    }

    private func setActivity(_ activity: CLICompletion.Activity) {
        guard case .generating(let attempt, _) = phase, let text = Self.progressText(for: activity) else { return }
        phase = .generating(attempt: attempt, activity: text)
    }

    /// What the person is told the assistant is doing. Every kind of activity has words: Codex reads files by running shell commands, and an
    /// assistant whose commands were dropped here looked stuck on "Starting the assistant" for the whole run.
    nonisolated static func progressText(for activity: CLICompletion.Activity) -> String? {
        func short(_ text: String, _ limit: Int = 70) -> String {
            let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        switch activity {
        case .read(let path): return "Reading " + (path as NSString).lastPathComponent
        case .search(let pattern): return "Searching for " + short(pattern)
        case .run(let command): return command.isEmpty ? "Working in the project" : "Running " + short(command)
        case .webSearch(let query): return "Searching the web for " + short(query)
        case .webFetch(let url): return "Reading " + (URL(string: url)?.host ?? short(url))
        case .thinking: return "Thinking it through"
        case .writing(let count): return "Writing the scenario (\(count) characters)"
        case .answerDelta: return nil
        }
    }

    private func finishGeneration(_ outcome: QAGenerator.Outcome) {
        phase = .idle
        add(outcome.scenario)
        if outcome.remaining.isEmpty {
            notice = "Scenario written in \(outcome.attempts) \(outcome.attempts == 1 ? "try" : "tries")."
        } else {
            notice = "\(outcome.remaining.count) \(outcome.remaining.count == 1 ? "problem is" : "problems are") left after \(outcome.attempts) tries; fix them in the editor."
        }
    }
}
