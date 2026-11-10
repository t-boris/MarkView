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
    @Published private(set) var unreadable: [QAUnreadable] = []
    @Published private(set) var current: QAScenario?
    @Published var selectedNode: String?
    @Published var selectedEdge: QAEdge?
    /// The branch the pointer is over in the list: its steps are lit in the graph.
    @Published var lit: String?
    @Published private(set) var phase: Phase = .idle
    /// A line about what the last generation or save did, shown until the next action.
    @Published private(set) var notice: String?

    private var saveTask: Task<Void, Never>?
    private var generation: Task<Void, Never>?
    private let saveDelay: UInt64 = 500_000_000

    var problems: [QAProblem] { current?.problems() ?? [] }
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
    }

    func close() {
        flush()
        current = nil
        selectedNode = nil
        selectedEdge = nil
    }

    /// Adds a scenario to the project and opens it.
    func add(_ scenario: QAScenario) {
        flush()
        current = scenario
        selectedNode = nil
        selectedEdge = nil
        upsert(scenario)
        save(scenario)
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
        phase = .generating(attempt: 1, activity: "Starting the assistant")
        generation = Task { [weak self] in
            do {
                let outcome = try await QAGenerator.generate(
                    request,
                    onAttempt: { attempt in Task { @MainActor in self?.setAttempt(attempt) } },
                    complete: { prompt in
                        let result = try await CLICompletion.run(
                            CLICompletion.Request(project: root, prompt: prompt, systemPrompt: QAGeneration.systemPrompt(request.appKind),
                                                  jsonSchema: QAGeneration.schema, readableFolder: root, timeout: 420, label: "qa-generate"),
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
        guard case .generating(let attempt, _) = phase else { return }
        let text: String
        switch activity {
        case .read(let path): text = "Reading " + (path as NSString).lastPathComponent
        case .search(let pattern): text = "Searching for " + pattern
        case .thinking: text = "Thinking it through"
        case .writing(let count): text = "Writing the scenario (\(count) characters)"
        default: return
        }
        phase = .generating(attempt: attempt, activity: text)
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
