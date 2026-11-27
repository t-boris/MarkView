import Foundation
import Combine
import Darwin

/// One step gets a fresh existing agent terminal and a one-use reporting ticket.
@MainActor
final class CockpitAgentAttempt: TerminalCloseObserver {
    private weak var assistants: (any AssistantProviding)?
    private let root: URL
    private var session: TerminalSession?
    private var ticket: UUID?
    private var continuation: CheckedContinuation<CockpitHostReply, Never>?
    private var progress: CockpitProgress?
    /// The project as it was when the step began, the controls it is held to, and whether it may change source whatever fixing says;
    /// compared when the step ends.
    private var audited: (before: CockpitStepAudit.Snapshot, controls: CockpitControls, changes: CockpitStepAudit.ChangeRule)?
    private var watchdog: CockpitChild?
    private var watchdogTask: Task<Void, Never>?
    private var watchdogExited: CockpitExitSignal?
    private var terminationTask: Task<Void, Never>?
    private var terminalExitObservation: AnyCancellable?
    private let onProgress: (CockpitProgress) async throws -> Void
    /// Told how many times the step's agent has moved a bug into fixing.
    private let onFixCycle: (Int) -> Void
    /// Told of every MarkView tool call of the step's agent (the tool, and the reason when it was refused), for the run's timeline.
    private let onGate: (String, String?) -> Void
    /// The supervisor takes the prompt and the current step's model, and returns its answer or throws.
    private let askSupervisor: ((String, CLITool?, String?) async throws -> CockpitSupervisor.Answer)?
    /// Told of every question the step asked and what came back, for the run's log.
    private let onExchange: (CockpitSupervisorExchange) -> Void
    /// What the person has switched off, and what the person told the supervisor, as of now. Asked on every gate
    /// call and every question, so a lever or a note counts from the agent's next move.
    private let liveCuts: () -> CockpitLiveSwitches
    private let liveNotes: () -> [CockpitCuratorNote]
    /// One line per step of the plan, for the supervisor's context.
    var planOutline: [String] = []
    /// The model of the step about to run, from the approved plan: the runtime does not carry it, so the session sets it before each step.
    var stepModel: String?
    var supervisorTool: CLITool?
    var supervisorModel: String?
    /// Whether the step about to run may delegate to its agent's own subagents, and how that agent does it (REQ-002). The session sets
    /// it before each step from the approved plan, the controls and the launch profile.
    var delegation: String?
    /// Extra lines of a managed run's step: what to report and how to treat an interrupted attempt's changes.
    var managedBrief: String?
    /// Who decides whether the step about to run may change source and commit: a managed run's writing step may (DEC-036), its
    /// verification step may not (BUG-132), and every step of a plan made outside Build follows Fix bugs. The session sets it before
    /// each step.
    var changes: CockpitStepAudit.ChangeRule = .fixBugsControl
    /// Told, when a step has ended and its terminal's group was stopped, which of the processes it started are still alive.
    private let onSurvivors: ([CockpitProcessRecord]) -> Void
    private let delegates = CockpitDelegateWatch()
    private var ledger = CockpitSupervisor.Ledger()

    init(assistants: any AssistantProviding, root: URL, onFixCycle: @escaping (Int) -> Void = { _ in },
         onGate: @escaping (String, String?) -> Void = { _, _ in },
         askSupervisor: ((String, CLITool?, String?) async throws -> CockpitSupervisor.Answer)? = nil,
         onExchange: @escaping (CockpitSupervisorExchange) -> Void = { _ in },
         liveCuts: @escaping () -> CockpitLiveSwitches = { CockpitLiveSwitches() },
         liveNotes: @escaping () -> [CockpitCuratorNote] = { [] },
         onProgress: @escaping (CockpitProgress) async throws -> Void = { _ in },
         onSurvivors: @escaping ([CockpitProcessRecord]) -> Void = { _ in }) {
        self.assistants = assistants; self.root = root.standardizedFileURL; self.onProgress = onProgress; self.onSurvivors = onSurvivors
        self.onFixCycle = onFixCycle; self.onGate = onGate; self.askSupervisor = askSupervisor
        self.onExchange = onExchange; self.liveCuts = liveCuts; self.liveNotes = liveNotes
    }

    func run(_ task: CockpitHostTask) async -> CockpitHostReply {
        guard !Task.isCancelled, let assistants,
              let tool = CLITool.allCases.first(where: { $0.displayName == task.step.agent }),
              tool.isMCPServiceEnabled(AgentMCPServer.markviewName),
              let terminal = assistants.openAITerminal(TerminalProfile(tool), resuming: false, model: stepModel) else {
            return Self.failure("The assigned agent or its MarkView project tools are unavailable.")
        }
        guard terminal.directory.standardizedFileURL == root else {
            terminal.terminateCockpitStep()
            return Self.failure("The agent terminal is not in the cockpit's project.")
        }
        // Before the agent starts, so nothing it does can be missing from the "before" picture.
        let before = await Self.snapshot(of: root)
        guard !Task.isCancelled else {
            terminal.terminateCockpitStep()
            return Self.failure("The step was interrupted.")
        }
        // The file audit holds the step to the controls with the cuts in force when it begins; a cut made during the step is the gate's.
        audited = (before, CockpitControls(storedJSON: task.controls).narrowed(by: liveCuts()), changes)
        session = terminal
        progress = nil
        // One attempt object serves every step of the run: what a step asked the supervisor is not carried into the next.
        ledger = CockpitSupervisor.Ledger()
        assistants.showAIConsole()
        terminal.start()
        guard let pty = terminal.duplicateCockpitPTY() else {
            terminal.terminateCockpitStep()
            session = nil
            return Self.failure("The agent terminal could not start.")
        }
        let exited = CockpitExitSignal()
        watchdogExited = exited
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    close(pty.descriptor)
                    terminal.terminateCockpitStep()
                    watchdogExited = nil
                    continuation.resume(returning: Self.failure("The step was interrupted.")); return
                }
                self.continuation = continuation
                delegates.start(shell: pty.shell)
                let ticket = CockpitAgentRegistry.register(root: root, progress: { [weak self] value in
                    guard let self else { throw CancellationError() }
                    self.progress = value
                    try await self.onProgress(value)
                }, ask: { [weak self] question in
                    await self?.supervise(question, task: task) ?? CockpitSupervisor.failureReply("the step has ended")
                }, waitForShutdown: { [weak self] in await self?.terminationTask?.value }) { [weak self] reply in self?.finish(reply) }
                self.ticket = ticket
                CockpitAgentRegistry.restrict(ticket, policy: CockpitStepPolicy(controls: CockpitControls(storedJSON: task.controls)),
                                              cuts: { [weak self] in self?.liveCuts() ?? CockpitLiveSwitches() }, shell: pty.shell,
                                              onFixCycle: { [weak self] count in self?.onFixCycle(count) },
                                              onActivity: { [weak self] tool, refusal in self?.onGate(tool, refusal) })
                terminalExitObservation = terminal.exitEvents.sink { [weak self] _ in
                    self?.cancel(reason: "The agent terminal exited before reporting a result.")
                }
                terminal.closeObserver = self
                do {
                    let data = try JSONEncoder().encode(task)
                    let assignment = String(decoding: data, as: UTF8.self)
                    let recoveryNote = task.recoveryAttempt.map {
                        "This is authorized bounded recovery attempt \($0) for a failed prerequisite. Inspect the prior failure in priorResults, resolve the blocker within the approved controls so the prerequisite can be re-checked, and call markview_cockpit_complete_step with passed true when ready (or passed false with neededInput stating the exact input or decision needed from the person if the blocker persists).\n"
                    } ?? ""
                    let prompt = """
                    \(recoveryNote)This is one step of a user-approved Copilot Cockpit plan. Work only on the assignment below.
                    The controls in the assignment bind you. MarkView refuses the MarkView tools they forbid and compares the project before and after your step:
                    when fixes are disabled, report findings without changing source files; when deployment is disabled, do not deploy by any route;
                    when filing bugs is disabled, describe problems in your report instead. A refused call is not a puzzle to get around: report it as a blocker.
                    You cannot start or drive other agents through MarkView during a step.
                    \(self.delegation.map { "You may hand independent parts of this assignment to \($0). They stay within this assignment, its controls and your permissions. Wait for each to finish, or stop it, before you report, and list every delegated piece in delegates with its outcome: delegated work left outstanding fails the step, and MarkView checks which processes of this terminal are still running when the step ends." } ?? "Do not delegate any of this assignment: do not start subagents, agent teams, fleets, workflows or other agents. MarkView checks which processes of this terminal are still running when the step ends.")
                    \(self.managedBrief ?? "")
                    \(CockpitControls(storedJSON: task.controls).narrowed(by: liveCuts()).supervisor
                        ? "When you need a decision you cannot make from the assignment and the controls, call markview_cockpit_ask with ticket \(ticket.uuidString) and your question: the supervisor answers at once. Nobody else will be asked and nothing waits for a person, so do not print a question into the terminal and wait for it. If the answer says the matter is outside the plan, do not act on it: record it as a blocker."
                        : "There is no supervisor in this run and nobody to ask: decide conservatively inside the controls, say what you decided in your step report, or record a blocker.")
                    When building is disabled, do not claim checks against a newly built version were performed. Build and checks are instructions only: MarkView cannot check them.
                    If this assignment names qaScenarioID, MarkView will run that exact reviewed QA scenario after your report; do not run it separately.
                    A prior result with continuedAfterFailure true is a step that failed and that the run went on past: take its blockers and the bugs it filed (progress.bugs) into account, and record a blocker when your assignment needs what it did not achieve.
                    If isFinalStep is true, explicitly evaluate each success criterion against evidence, report unmet criteria as blockers, and report passed only if the criteria are met.
                    Use the available MarkView project and browser tools as appropriate. Once you have finished this step, call markview_cockpit_complete_step
                    with ticket \(ticket.uuidString), passed, detail (evidence and blockers), build (the build identifier or an empty string), and neededInput (when passed is false and you need specific input, credentials, or a decision from the person before retrying).
                    While working, call markview_cockpit_report_progress with the same ticket to report the pass number, activity, scenario coverage, bugs, confirmed fixes, latest change, blockers, and build log path where known. On the final step include criteriaResults for every stated success criterion, with exact criterion text, met or unmet, and supporting evidence.
                    Report whether the completion condition was actually met. Your terminal session ends after your report; do not start subsequent steps.
                    \(CockpitCuratorNote.block(liveNotes()).map { "\n" + $0 + "\n" } ?? "")
                    Assignment and prior results (JSON):
                    \(assignment)
                    """
                    let root = self.root
                    watchdogTask = Task { [weak self, weak terminal] in
                        do {
                            let watcher = try await CockpitService.forProject(root).watchdog(ptyDescriptor: pty.descriptor, shell: pty.shell,
                                                                                          // task: a non-async callback tells the exit signal once; the actor call ends at once and touches nothing of this step
                                                                                          onExit: { Task { await exited.finish() } })
                            guard let self, let terminal, self.ticket == ticket, terminal.shellPID == pty.shell, !Task.isCancelled else {
                                watcher.stop(); return
                            }
                            self.watchdog = watcher
                            terminal.pasteWhenReady(prompt, submit: true)
                        } catch { self?.cancel(reason: "The terminal watchdog could not start.") }
                    }
                } catch {
                    close(pty.descriptor)
                    // task: tells the exit signal once, so that nothing waits for a watchdog that never started; the actor call ends at once
                    Task { await exited.finish() }
                    cancel(reason: "The step assignment could not be prepared.")
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(reason: "The step was interrupted.") }
        }
    }

    func terminalWillClose() { cancel(reason: "The agent terminal was closed before reporting a result.") }

    private func cancel(reason: String) {
        guard let ticket else { return }
        CockpitAgentRegistry.cancel(ticket, reason: reason)
    }

    private func finish(_ reply: CockpitHostReply) {
        guard let continuation else { return }
        self.continuation = nil
        let refusals = ticket.map(CockpitAgentRegistry.refusals) ?? []
        ticket = nil
        watchdogTask?.cancel(); watchdogTask = nil
        watchdog?.stop(); watchdog = nil
        let exited = watchdogExited
        watchdogExited = nil
        terminalExitObservation = nil
        session?.closeObserver = nil
        let reaping = session?.terminateCockpitStep(beforeReap: { await exited?.wait() })
        session = nil
        var reported = reply
        reported.result.progress = progress
        if !refusals.isEmpty {
            reported.result.detail += (reported.result.detail.isEmpty ? "" : "\n\n")
                + "MarkView refused \(refusals.count) tool call(s) during this step under the Cockpit controls:\n"
                + refusals.map { "- " + $0 }.joined(separator: "\n")
        }
        let audit = reply.error.isEmpty ? audited : nil
        audited = nil
        let root = self.root
        let base = reported
        let seen = delegates.stop()
        let survivorsSeen = onSurvivors
        // The next Temporal step must not start while this terminal's process group is still stopping. The "after" picture is
        // taken only then, so the agent cannot still be changing files.
        terminationTask = Task {
            await reaping?.value
            await exited?.wait()
            var finalized = base
            if let audit {
                let after = await Self.snapshot(of: root)
                let found = CockpitStepAudit.violations(before: audit.before, after: after, controls: audit.controls, changes: audit.changes)
                let notes = CockpitStepAudit.limits(of: after, controls: audit.controls, changes: audit.changes)
                if !found.isEmpty {
                    finalized.result.passed = false
                    finalized.result.detail += (finalized.result.detail.isEmpty ? "" : "\n\n")
                        + "Cockpit control violation, found by comparing the project before and after the step:\n" + found.map { "- " + $0 }.joined(separator: "\n")
                }
                if !notes.isEmpty {
                    finalized.result.detail += (finalized.result.detail.isEmpty ? "" : "\n\n") + notes.joined(separator: "\n")
                }
            }
            // What the step started and the end of its group did not stop: a delegate that may still write to the checkout (REQ-003).
            let survivors = await Task.detached { CockpitDelegateWatch.alive(seen) }.value
            survivorsSeen(survivors)
            if !survivors.isEmpty, finalized.error.isEmpty {
                finalized.result.passed = false
                finalized.result.detail += (finalized.result.detail.isEmpty ? "" : "\n\n")
                    + "Processes this step started are still running after it ended, so its work is not accounted for:\n"
                    + survivors.map { "- \($0.command) (process \($0.pid))" }.joined(separator: "\n")
            }
            continuation.resume(returning: finalized)
        }
    }

    /// The agent's question to the supervisor: asked once per distinct question, at most `questionsPerStep` of them, and never waited on.
    func supervise(_ question: CockpitSupervisor.Question, task: CockpitHostTask) async -> String {
        guard CockpitControls(storedJSON: task.controls).narrowed(by: liveCuts()).supervisor, let askSupervisor else { return CockpitSupervisor.disabledReply }
        switch ledger.admit(question.text) {
        case .repeated(let reply): return reply
        case .exhausted: return CockpitSupervisor.exhaustedReply
        case .ask: break
        }
        let prompt = CockpitSupervisor.prompt(task: task, outline: planOutline, question: question, progress: progress, notes: liveNotes())
        var exchange = CockpitSupervisorExchange(stepID: task.step.id, asked: Date(), question: CockpitSupervisor.clip(question.text, to: CockpitSupervisor.textLimit),
                                                 answer: "", outOfScope: false, failed: false)
        let reply: String
        do {
            let answer = try await askSupervisor(prompt, supervisorTool, supervisorModel)
            reply = CockpitSupervisor.reply(for: answer)
            ledger.remember(question.text, reply: reply)
            exchange.answer = answer.text; exchange.outOfScope = answer.outOfScope
        } catch {
            reply = CockpitSupervisor.failureReply(CockpitSupervisor.clip((error as? LocalizedError)?.errorDescription ?? "no usable answer", to: 200))
            exchange.answer = reply; exchange.failed = true
        }
        onExchange(exchange)
        return reply
    }

    /// The git-changed files with their content hashes (UI Studio's revision probe), and the QA scenarios that exist.
    private static func snapshot(of root: URL) async -> CockpitStepAudit.Snapshot {
        let (_, working) = await StudioRevisionProbe.compute(root: root)
        let scenarios = await Task.detached { Set(QAStore.loadScenarios(root).scenarios.map(\.id)) }.value
        return CockpitStepAudit.Snapshot(isGitRepository: working.gitRoot != nil, head: working.head,
                                         files: working.files.mapValues { $0 ?? "deleted" }, scenarios: scenarios)
    }

    private static func failure(_ message: String) -> CockpitHostReply {
        CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: message)
    }
}
