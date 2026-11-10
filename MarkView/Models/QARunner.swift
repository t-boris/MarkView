import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-001..003, DEC-005, DEC-011, REQ-002, REQ-003): the run itself. Every selected branch is a check
// of its own: its baseline is restored, its players sign in, its condition is brought about, and then its steps are carried out one after
// another, each by a loop of "look at the page, ask the assistant, do what it says". The rules of an outcome are QACheckMachine's; the
// approval and the production confirmations are QAGate's. The browser, the assistant and the observer are passed in, so the whole run is
// checked on its own (tools/tests/qa-tests.sh). Foundation only.

/// One browser (or application) session that belongs to one player. Sessions of different players never share cookies or storage.
protocol QAActorDriver: AnyObject {
    func open(_ address: String) async throws
    func observe() async throws -> QAObservation
    /// Does what the action says and answers, in a few words, what came of it. A failed action throws.
    func perform(_ action: QAAction) async throws -> String
    func screenshot() async -> Data?
    /// Makes the session's requests fail, wait or answer with a status; the fault is armed before the page loads.
    func arm(_ fault: QAFault) async throws
    /// How many requests the armed faults have met so far.
    func faultHits() async -> Int
    /// What the page shows by measure (small text, low contrast, clipped content…) for the review; nil when it cannot be measured.
    func measure() async -> QAPageEvidence?
    func close() async
}

extension QAActorDriver {
    func measure() async -> QAPageEvidence? { nil }
}

struct QADriverRequest {
    /// Nil for the session that prepares data and is nobody's.
    var actor: QAActor?
    var app: QAApp
    /// Where the application is, in the chosen environment.
    var address: String
    var login: QALoginReference?
}

protocol QADriverFactory: AnyObject {
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver
}

/// The assistant: one structured answer to one prompt. What it costs is the caller's to account for.
protocol QAAssistant: AnyObject {
    func decide(system: String, prompt: String, schema: [String: Any]) async throws -> Any?
}

/// One look at an actor's page. `isNew` when it is a screen that actor had not shown before (REQ-008): only such a screen is measured and
/// worth a review.
struct QAScreenEvent {
    var branch: String
    var node: String?
    var actor: String?
    var observation: QAObservation
    var isNew: Bool
    var png: Data?
    var evidence: QAPageEvidence?
    /// What the step has cost so far, and what the branch has cost up to now.
    var stepEffort: QAEffort
    var branchEffort: QAEffort
}

enum QARunEvent {
    case runStarted(id: String, branches: [String])
    case branchStarted(branch: String, label: String)
    case narration(QATimelineEntry)
    /// What an actor's page showed at one turn.
    case screen(QAScreenEvent)
    case nodeStarted(branch: String, node: String, actor: String?, title: String)
    case nodeFinished(branch: String, node: String, effort: QAEffort)
    case branchFinished(QACheckResult)
    case runFinished(QARunRecord)
}

protocol QARunObserver: AnyObject {
    func handle(_ event: QARunEvent)
}

final class QARunner {
    struct Config {
        /// Actions one step may take before it is given up as blocked.
        var maxActionsPerStep = 12
        /// Failed actions in a row before the step is given up as blocked.
        var maxFailedActions = 3
        /// Unusable answers of the assistant in a row before the step is given up as blocked.
        var maxBadAnswers = 2
        var captureFrames = true
        /// Measure each new screen of a step in the page (for the review).
        var measureScreens = true
    }

    private enum Outcome {
        case done
        case notMet(String)
        case blocked(QABlockReason, String)
        case interrupted
    }

    private final class Tally {
        var effort = QAEffort()
    }

    let scenario: QAScenario
    let plan: QAExecutionPlan
    private(set) var gate: QAGate
    private let factory: QADriverFactory
    private let assistant: QAAssistant
    private let runID: String
    private let confirm: (QAConfirmation) async -> Bool
    private weak var observer: QARunObserver?
    private let now: () -> Date
    private let config: Config

    private var startedAt = Date()
    private var timeline: [QATimelineEntry] = []
    private var drivers: [String: QAActorDriver] = [:]
    private var lastScreen: [String: String] = [:]

    init(scenario: QAScenario, plan: QAExecutionPlan, gate: QAGate, factory: QADriverFactory, assistant: QAAssistant, runID: String,
         confirm: @escaping (QAConfirmation) async -> Bool, observer: QARunObserver? = nil, now: @escaping () -> Date = Date.init,
         config: Config = Config()) {
        self.scenario = scenario
        self.plan = plan
        self.gate = gate
        self.factory = factory
        self.assistant = assistant
        self.runID = runID
        self.confirm = confirm
        self.observer = observer
        self.now = now
        self.config = config
    }

    // MARK: The run

    func run() async -> QARunRecord {
        startedAt = now()
        var record = QARunRecord(id: runID, scenarioID: scenario.id, targetID: plan.target?.id ?? "", targetKind: plan.target?.kind ?? .local,
                                 selected: plan.branches.map(\.id), startedAt: startedAt)
        emit(.runStarted(id: runID, branches: record.selected))
        var stopped = false
        for branch in plan.branches {
            if Task.isCancelled { stopped = true }
            let result: QACheckResult
            if stopped {
                let at = now()
                result = QACheckResult(branch: branch.id, verdict: QACheckVerdict(outcome: .uncovered, reason: "Not executed: the run was stopped."),
                                       startedAt: at, finishedAt: at)
            } else {
                result = await check(branch)
                await closeDrivers()
                if result.verdict.interruption == .stoppedByUser { stopped = true }
            }
            record.record(result)
            emit(.branchFinished(result))
        }
        record.finishedAt = now()
        record.timeline = timeline
        emit(.runFinished(record))
        return record
    }

    // MARK: One check

    private func check(_ branch: QABranch) async -> QACheckResult {
        let started = now()
        var machine = QACheckMachine(conditionRequired: !scenario.conditions(of: branch).isEmpty)
        var steps: [QAStepEffort] = []
        var total = QAEffort()
        var armed: [String] = []
        emit(.branchStarted(branch: branch.id, label: scenario.label(of: branch)))

        func result() -> QACheckResult {
            let verdict = machine.verdict ?? QACheckVerdict(outcome: .interrupted, reason: "The check ended without a verdict.", interruption: .other)
            let finished = QACheckResult(branch: branch.id, verdict: verdict, nodesMet: machine.nodesMet, startedAt: started, finishedAt: now(),
                                         effort: total, steps: steps)
            note(branch, nil, nil, .result, "\(verdict.outcome.label): \(verdict.reason)")
            return finished
        }

        // Baseline, accounts and sign-ins.
        guard gate.canPrepare else {
            machine.apply(.baselineFailed(.approvalMissing, "The plan was not approved."))
            return result()
        }
        if let baseline = scenario.baseline {
            if let refusal = await permit("baseline:\(branch.id)") {
                machine.apply(.baselineFailed(.approvalMissing, refusal))
                return result()
            }
            if baseline.isManual {
                // The person said it is done (`permit` above); the assistant only has the application's pages and cannot restore a snapshot.
                note(branch, nil, nil, .preparation, "Baseline restored by the person: \(baseline.establish)")
            } else {
                let app = firstApp(of: branch)
                note(branch, nil, nil, .preparation, "Restoring the baseline: \(baseline.establish)")
                let outcome = await runSetup(branch, app: app, establish: baseline.establish, verify: baseline.verify, title: "Restore the baseline")
                if case .interrupted = outcome { machine.apply(.interrupted(.stoppedByUser, "Stopped by the person.")); return result() }
                if let failure = failure(of: outcome) {
                    // The assistant has only the application's pages: when the baseline needs more, the person has to do it (or drop the baseline).
                    let hint = failure.reason == .launchFailed ? "" : " If only a person can bring this about, switch on \"I restore it myself\" under Baseline in Setup; if it is not needed, switch the baseline off."
                    machine.apply(.baselineFailed(failure.reason == .launchFailed ? .launchFailed : .baselineNotEstablished, failure.message + hint))
                    return result()
                }
            }
        }
        for actorID in scenario.actors(in: branch) {
            guard let actor = scenario.actors.first(where: { $0.id == actorID }) else { continue }
            let stepID = plan.preparation.first { $0.actor == actorID && ($0.kind == .createAccount || $0.kind == .login) }
            guard let step = stepID else { continue }
            if let refusal = await permit(step.id) {
                machine.apply(.baselineFailed(.approvalMissing, refusal))
                return result()
            }
            let app = scenario.app(actor.app ?? firstApp(of: branch).id) ?? firstApp(of: branch)
            let driver: QAActorDriver
            do { driver = try await session(for: actor, app: app) } catch {
                machine.apply(.baselineFailed(.launchFailed, "The application could not be opened: \(describe(error))"))
                return result()
            }
            note(branch, nil, actor.id, .preparation, step.title)
            let task = QAStepTask(id: step.id, kind: .act,
                                  title: step.kind == .login ? "Sign in as \(actor.name)" : "Create a new test account for \(actor.name) and sign in",
                                  detail: step.kind == .login ? "Use the placeholders {{username}} and {{password}}; the real values are supplied for you." : "Use a made-up name and address of the form qa-<random>@example.com and a made-up password.",
                                  actorName: actor.name, appName: app.name)
            let outcome = await perform(task, branch: branch, node: nil, actor: actor.id, driver: driver, tally: Tally())
            if case .interrupted = outcome { machine.apply(.interrupted(.stoppedByUser, "Stopped by the person.")); return result() }
            if let failure = failure(of: outcome) {
                machine.apply(.baselineFailed(step.kind == .login ? .loginFailed : .other, failure.message))
                return result()
            }
        }
        machine.apply(.baselineEstablished)

        // The condition of the branch.
        for (nodeID, condition) in scenario.conditions(of: branch) {
            if let refusal = await permit("condition:\(branch.id):\(nodeID)") {
                machine.apply(.conditionNotAchieved(refusal))
                return result()
            }
            if let fault = condition.fault, condition.kind == .networkFault || condition.kind == .delay {
                guard let node = scenario.node(nodeID), let actorID = scenario.actorID(of: node), let actor = scenario.actors.first(where: { $0.id == actorID }),
                      let app = scenario.app(scenario.appID(of: node) ?? "") else {
                    machine.apply(.conditionNotAchieved("The step of the condition has no player or application."))
                    return result()
                }
                do {
                    let target = try await session(for: actor, app: app)
                    try await target.arm(fault)
                } catch {
                    machine.apply(.conditionNotAchieved("The fault could not be armed: \(describe(error))"))
                    return result()
                }
                armed.append(actorID)
                note(branch, nodeID, actorID, .preparation, condition.establish)
            } else if condition.isManual {
                note(branch, nodeID, nil, .preparation, "Set up by the person: \(condition.establish)")
            } else {
                let app = scenario.node(nodeID).flatMap { scenario.app(scenario.appID(of: $0) ?? "") } ?? firstApp(of: branch)
                note(branch, nodeID, nil, .preparation, condition.establish)
                let outcome = await runSetup(branch, app: app, establish: condition.establish, verify: condition.verify, title: "Bring about the condition")
                if case .interrupted = outcome { machine.apply(.interrupted(.stoppedByUser, "Stopped by the person.")); return result() }
                if let failure = failure(of: outcome) {
                    machine.apply(.conditionNotAchieved(failure.message))
                    return result()
                }
            }
        }
        if machine.phase == .condition { machine.apply(.conditionVerified) }

        // The steps.
        for nodeID in branch.nodes {
            guard let node = scenario.node(nodeID) else { continue }
            if Task.isCancelled { machine.apply(.interrupted(.stoppedByUser, "Stopped by the person.")); break }
            let actorID = scenario.actorID(of: node)
            let actor = actorID.flatMap { id in scenario.actors.first { $0.id == id } }
            if let refusal = await permit("node:\(node.id)") {
                machine.apply(.cannotProceed(node.id, .approvalMissing, refusal))
                break
            }
            guard let app = scenario.app(scenario.appID(of: node) ?? "") else {
                machine.apply(.cannotProceed(node.id, .other, "The step has no application."))
                break
            }
            let driver: QAActorDriver
            do { driver = try await session(for: actor, app: app) } catch {
                machine.apply(.cannotProceed(node.id, .launchFailed, "The application could not be opened: \(describe(error))"))
                break
            }
            emit(.nodeStarted(branch: branch.id, node: node.id, actor: actor?.id, title: node.title))
            let tally = Tally()
            let began = now()
            let task = QAStepTask(id: node.id, kind: node.kind == .check || node.kind == .failure ? .verify : .act, title: node.title, detail: node.detail,
                                  actorName: actor?.name ?? "the user", appName: app.name)
            let outcome = await perform(task, branch: branch, node: node.id, actor: actor?.id, driver: driver, tally: tally, branchBefore: total)
            tally.effort.milliseconds = Int(now().timeIntervalSince(began) * 1000)
            total = total + tally.effort
            steps.append(QAStepEffort(node: node.id, actor: actor?.id, effort: tally.effort))
            emit(.nodeFinished(branch: branch.id, node: node.id, effort: tally.effort))
            switch outcome {
            case .done: machine.apply(.nodeMet(node.id))
            case .notMet(let message): machine.apply(.checkNotMet(node.id, message))
            case .blocked(let reason, let message): machine.apply(.cannotProceed(node.id, reason, message))
            case .interrupted: machine.apply(.interrupted(.stoppedByUser, "Stopped by the person."))
            }
            if machine.verdict != nil { break }
        }
        if machine.verdict == nil {
            var unmet: String?
            for actorID in armed {
                if let target = drivers[actorID], await target.faultHits() == 0 { unmet = "The network fault was never met, so the branch did not run under its condition." }
            }
            if let unmet { machine.apply(.conditionNotAchieved(unmet)) } else { machine.apply(.allNodesDone) }
        }
        return result()
    }

    // MARK: Setup tasks

    /// Carries out what the person wrote to prepare the application (restore a baseline, bring about a condition), then checks it.
    private func runSetup(_ branch: QABranch, app: QAApp, establish: String, verify: String, title: String) async -> Outcome {
        let driver: QAActorDriver
        do { driver = try await session(for: nil, app: app) } catch { return .blocked(.launchFailed, "The application could not be opened: \(describe(error))") }
        let doing = QAStepTask(id: "setup", kind: .act, title: title, detail: establish, actorName: "the test", appName: app.name, allowsHTTP: true)
        let first = await perform(doing, branch: branch, node: nil, actor: nil, driver: driver, tally: Tally())
        guard case .done = first else { return first }
        let checking = QAStepTask(id: "setup", kind: .verify, title: "Confirm: \(title.lowercased())", detail: verify, actorName: "the test", appName: app.name, allowsHTTP: true)
        return await perform(checking, branch: branch, node: nil, actor: nil, driver: driver, tally: Tally())
    }

    private func failure(of outcome: Outcome) -> (reason: QABlockReason, message: String)? {
        switch outcome {
        case .done, .interrupted: return nil
        case .notMet(let message): return (.other, message)
        case .blocked(let reason, let message): return (reason, message)
        }
    }

    // MARK: One step: look, ask, do

    private func perform(_ task: QAStepTask, branch: QABranch, node: String?, actor: String?, driver: QAActorDriver, tally: Tally,
                         branchBefore: QAEffort = QAEffort()) async -> Outcome {
        var history: [QAHistoryItem] = []
        var actions = 0, failed = 0, bad = 0
        while true {
            if Task.isCancelled { return .interrupted }
            if actions >= config.maxActionsPerStep {
                return .blocked(.stepBudgetExhausted, "The step was not completed within \(config.maxActionsPerStep) actions.")
            }
            let observation: QAObservation
            do { observation = try await driver.observe() } catch is CancellationError { return .interrupted } catch {
                return .blocked(.other, "The page could not be read: \(describe(error))")
            }
            let key = actor ?? "setup"
            let signature = QAScreen.signature(address: observation.address, snapshot: observation.snapshot)
            let isNew = lastScreen[key] != signature
            lastScreen[key] = signature
            if isNew && node != nil { tally.effort.screens += 1 }
            let png = config.captureFrames ? await driver.screenshot() : nil
            let evidence = (isNew && node != nil && config.measureScreens) ? await driver.measure() : nil
            emit(.screen(QAScreenEvent(branch: branch.id, node: node, actor: actor, observation: observation, isNew: isNew, png: png, evidence: evidence,
                                       stepEffort: tally.effort, branchEffort: branchBefore + tally.effort)))

            let decision: QADecision
            do {
                let answer = try await assistant.decide(system: QAStepPrompt.systemPrompt(),
                                                        prompt: QAStepPrompt.prompt(task: task, goal: scenario.goal, history: history, observation: observation,
                                                                                    actionsLeft: config.maxActionsPerStep - actions),
                                                        schema: QAStepPrompt.schema)
                decision = try QAStepPrompt.parse(answer, allowsHTTP: task.allowsHTTP)
            } catch is CancellationError {
                return .interrupted
            } catch is QAStepPrompt.ParseError {
                bad += 1
                history.append(QAHistoryItem(narration: "", action: "(unusable answer)", result: "Answer again with one valid move."))
                if bad > config.maxBadAnswers { return .blocked(.other, "The assistant's answers could not be used.") }
                continue
            } catch {
                return .blocked(.other, "The assistant did not answer: \(describe(error))")
            }
            bad = 0

            switch decision.move {
            case .done:
                note(branch, node, actor, task.kind == .verify ? .observation : .action, line(actor, decision.narration, fallback: task.kind == .verify ? "The expectation holds." : "Done."))
                return .done
            case .notMet(let reason):
                note(branch, node, actor, .observation, line(actor, decision.narration, fallback: reason))
                return .notMet(reason)
            case .blocked(let reason, let message):
                note(branch, node, actor, .observation, line(actor, decision.narration, fallback: message))
                return .blocked(reason, message)
            case .act(let action):
                note(branch, node, actor, .action, line(actor, decision.narration, fallback: action.summary))
                do {
                    let outcome = try await driver.perform(action)
                    failed = 0
                    if node != nil { action.addEffort(to: &tally.effort) }
                    history.append(QAHistoryItem(narration: decision.narration, action: action.summary, result: outcome))
                } catch is CancellationError {
                    return .interrupted
                } catch {
                    failed += 1
                    history.append(QAHistoryItem(narration: decision.narration, action: action.summary, result: "failed: \(describe(error))"))
                    if failed >= config.maxFailedActions {
                        return .blocked(.elementNotFound, "The action \"\(action.summary)\" failed \(failed) times: \(describe(error))")
                    }
                }
                actions += 1
            }
        }
    }

    // MARK: Helpers

    private func session(for actor: QAActor?, app: QAApp) async throws -> QAActorDriver {
        let key = actor?.id ?? "setup"
        if let existing = drivers[key] { return existing }
        guard let address = plan.target?.locations[app.id]?.url else { throw QARunnerError.noAddress(app.name) }
        let created = try await factory.makeDriver(QADriverRequest(actor: actor, app: app, address: address, login: actor?.login))
        drivers[key] = created
        do { try await created.open(address) } catch {
            drivers[key] = nil
            await created.close()
            throw error
        }
        return created
    }

    private func closeDrivers() async {
        let open = Array(drivers.values)
        drivers = [:]
        lastScreen = [:]
        for driver in open { await driver.close() }
    }

    private func firstApp(of branch: QABranch) -> QAApp {
        for id in branch.nodes { if let node = scenario.node(id), let app = scenario.app(scenario.appID(of: node) ?? "") { return app } }
        return scenario.apps.first ?? QAApp(id: "app", name: "Application")
    }

    /// Whether the gate lets this thing be done: nil when it does, otherwise why not. A thing that needs the person's yes asks for it.
    private func permit(_ id: String) async -> String? {
        switch gate.decision(for: id) {
        case .allowed: return nil
        case .refused(let message): return message
        case .needsConfirmation(let confirmation):
            if await confirm(confirmation) { gate.confirm(confirmation.id); return nil }
            return "You did not confirm: \(confirmation.title)."
        }
    }

    private func line(_ actor: String?, _ narration: String, fallback: String) -> String {
        let text = narration.isEmpty ? fallback : narration
        guard let actor, scenario.actors.count > 1, let name = scenario.actors.first(where: { $0.id == actor })?.name else { return text }
        return "\(name): \(text)"
    }

    private func note(_ branch: QABranch, _ node: String?, _ actor: String?, _ kind: QATimelineEntry.Kind, _ text: String) {
        let entry = QATimelineEntry(id: timeline.count + 1, time: max(0, now().timeIntervalSince(startedAt)), branch: branch.id, node: node, actor: actor, kind: kind, text: text)
        timeline.append(entry)
        emit(.narration(entry))
    }

    private func emit(_ event: QARunEvent) { observer?.handle(event) }

    private func describe(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? String(describing: error) }
}

enum QARunnerError: Error, LocalizedError {
    case noAddress(String)

    var errorDescription: String? {
        switch self {
        case .noAddress(let app): return "The environment has no address for \(app)."
        }
    }
}
