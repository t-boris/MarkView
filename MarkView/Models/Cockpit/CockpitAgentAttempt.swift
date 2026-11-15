import Foundation
import Darwin

/// One step gets a fresh existing agent terminal and a one-use reporting ticket.
@MainActor
final class CockpitAgentAttempt {
    private weak var workspace: WorkspaceManager?
    private let root: URL
    private var session: TerminalSession?
    private var ticket: UUID?
    private var continuation: CheckedContinuation<CockpitHostReply, Never>?
    private var progress: CockpitProgress?
    /// The project as it was when the step began, and the controls it is held to; compared when the step ends.
    private var audited: (before: CockpitStepAudit.Snapshot, controls: CockpitControls)?
    private var watchdog: CockpitChild?
    private var watchdogTask: Task<Void, Never>?
    private var watchdogExited: CockpitExitSignal?
    private var terminationTask: Task<Void, Never>?
    private let onProgress: (CockpitProgress) async throws -> Void
    /// Told how many times the step's agent has moved a bug into fixing; set by the session before each step.
    var onFixCycle: (Int) -> Void = { _ in }
    /// Told of every MarkView tool call of the step's agent (the tool, and the reason when it was refused), for the run's timeline.
    var onGate: (String, String?) -> Void = { _, _ in }
    /// The supervisor: set by the session. Takes the prompt built for a question and returns the model's answer, or throws.
    var askSupervisor: ((String) async throws -> CockpitSupervisor.Answer)?
    /// Told of every question the step asked and what came back, for the run's log.
    var onExchange: (CockpitSupervisorExchange) -> Void = { _ in }
    /// What the person has switched off, and what the person told the supervisor, as of now; set by the session. Asked on every gate
    /// call and every question, so a lever or a note counts from the agent's next move.
    var liveCuts: () -> CockpitLiveSwitches = { CockpitLiveSwitches() }
    var liveNotes: () -> [CockpitCuratorNote] = { [] }
    /// One line per step of the plan, for the supervisor's context.
    var planOutline: [String] = []
    /// The model of the step about to run, from the approved plan: the runtime does not carry it, so the session sets it before each step.
    var stepModel: String?
    private var ledger = CockpitSupervisor.Ledger()

    init(workspace: WorkspaceManager, root: URL, onProgress: @escaping (CockpitProgress) async throws -> Void = { _ in }) {
        self.workspace = workspace; self.root = root.standardizedFileURL; self.onProgress = onProgress
    }

    func run(_ task: CockpitHostTask) async -> CockpitHostReply {
        guard !Task.isCancelled, let workspace,
              let tool = CLITool.allCases.first(where: { $0.displayName == task.step.agent }),
              BrowserControlServer.agentToolsEnabled(tool),
              let terminal = workspace.openAITerminal(TerminalProfile(tool), model: stepModel) else {
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
        audited = (before, Self.controls(of: task).narrowed(by: liveCuts()))
        session = terminal
        progress = nil
        // One attempt object serves every step of the run: what a step asked the supervisor is not carried into the next.
        ledger = CockpitSupervisor.Ledger()
        workspace.showAIConsole()
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
                let ticket = CockpitAgentRegistry.register(root: root, progress: { [weak self] value in
                    guard let self else { throw CancellationError() }
                    self.progress = value
                    try await self.onProgress(value)
                }, ask: { [weak self] question in
                    await self?.supervise(question, task: task) ?? CockpitSupervisor.failureReply("the step has ended")
                }, waitForShutdown: { [weak self] in await self?.terminationTask?.value }) { [weak self] reply in self?.finish(reply) }
                self.ticket = ticket
                CockpitAgentRegistry.restrict(ticket, policy: CockpitStepPolicy(controls: Self.controls(of: task)),
                                              cuts: { [weak self] in self?.liveCuts() ?? CockpitLiveSwitches() }, shell: pty.shell,
                                              onFixCycle: { [weak self] count in self?.onFixCycle(count) },
                                              onActivity: { [weak self] tool, refusal in self?.onGate(tool, refusal) })
                terminal.onExit = { [weak self] _ in self?.cancel(reason: "The agent terminal exited before reporting a result.") }
                terminal.onCockpitTermination = { [weak self] in self?.cancel(reason: "The agent terminal was closed before reporting a result.") }
                do {
                    let data = try JSONEncoder().encode(task)
                    let assignment = String(decoding: data, as: UTF8.self)
                    let prompt = """
                    This is one step of a user-approved Copilot Cockpit plan. Work only on the assignment below.
                    The controls in the assignment bind you. MarkView refuses the MarkView tools they forbid and compares the project before and after your step:
                    when fixes are disabled, report findings without changing source files; when deployment is disabled, do not deploy by any route;
                    when filing bugs is disabled, describe problems in your report instead. A refused call is not a puzzle to get around: report it as a blocker.
                    You cannot start or drive other agents through MarkView during a step.
                    \(Self.controls(of: task).narrowed(by: liveCuts()).supervisor
                        ? "When you need a decision you cannot make from the assignment and the controls, call markview_cockpit_ask with project_folder \(root.path), ticket \(ticket.uuidString) and your question: the supervisor answers at once. Nobody else will be asked and nothing waits for a person, so do not print a question into the terminal and wait for it. If the answer says the matter is outside the plan, do not act on it: record it as a blocker."
                        : "There is no supervisor in this run and nobody to ask: decide conservatively inside the controls, say what you decided in your step report, or record a blocker.")
                    When building is disabled, do not claim checks against a newly built version were performed. Build and checks are instructions only: MarkView cannot check them.
                    If this assignment names qaScenarioID, MarkView will run that exact reviewed QA scenario after your report; do not run it separately.
                    If isFinalStep is true, explicitly evaluate each success criterion against evidence, report unmet criteria as blockers, and report passed only if the criteria are met.
                    Use the available MarkView project and browser tools as appropriate. Once you have finished this step, call markview_cockpit_complete_step
                    with project_folder \(root.path), ticket \(ticket.uuidString), passed, detail (evidence and blockers), and build (the build identifier or an empty string).
                    While working, call markview_cockpit_report_progress with the same ticket to report the pass number, activity, scenario coverage, bugs, confirmed fixes, latest change, blockers, and build log path where known. On the final step include criteriaResults for every stated success criterion, with exact criterion text, met or unmet, and supporting evidence.
                    Report whether the completion condition was actually met. Your terminal session ends after your report; do not start subsequent steps.
                    \(CockpitCuratorNote.block(liveNotes()).map { "\n" + $0 + "\n" } ?? "")
                    Assignment and prior results (JSON):
                    \(assignment)
                    """
                    watchdogTask = Task { [weak self, weak terminal] in
                        do {
                            let watcher = try await CockpitService.forProject(root).watchdog(ptyDescriptor: pty.descriptor, shell: pty.shell,
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
                    Task { await exited.finish() }
                    cancel(reason: "The step assignment could not be prepared.")
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(reason: "The step was interrupted.") }
        }
    }

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
        session?.onExit = nil
        session?.onCockpitTermination = nil
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
        // The next Temporal step must not start while this terminal's process group is still stopping. The "after" picture is
        // taken only then, so the agent cannot still be changing files.
        terminationTask = Task {
            await reaping?.value
            await exited?.wait()
            var finalized = base
            if let audit {
                let after = await Self.snapshot(of: root)
                let found = CockpitStepAudit.violations(before: audit.before, after: after, controls: audit.controls)
                let notes = CockpitStepAudit.limits(of: after, controls: audit.controls)
                if !found.isEmpty {
                    finalized.result.passed = false
                    finalized.result.detail += (finalized.result.detail.isEmpty ? "" : "\n\n")
                        + "Cockpit control violation, found by comparing the project before and after the step:\n" + found.map { "- " + $0 }.joined(separator: "\n")
                }
                if !notes.isEmpty {
                    finalized.result.detail += (finalized.result.detail.isEmpty ? "" : "\n\n") + notes.joined(separator: "\n")
                }
            }
            continuation.resume(returning: finalized)
        }
    }

    /// The agent's question to the supervisor: asked once per distinct question, at most `questionsPerStep` of them, and never waited on.
    private func supervise(_ question: CockpitSupervisor.Question, task: CockpitHostTask) async -> String {
        guard Self.controls(of: task).narrowed(by: liveCuts()).supervisor, let askSupervisor else { return CockpitSupervisor.disabledReply }
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
            let answer = try await askSupervisor(prompt)
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

    /// Controls that cannot be read are replaced by the defaults, which are the restrictive ones.
    private static func controls(of task: CockpitHostTask) -> CockpitControls {
        (try? JSONDecoder().decode(CockpitControls.self, from: Data(task.controls.utf8))) ?? CockpitControls()
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
