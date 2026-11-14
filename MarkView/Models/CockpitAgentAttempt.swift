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
    private var watchdog: CockpitChild?
    private var watchdogTask: Task<Void, Never>?
    private var watchdogExited: CockpitExitSignal?
    private var terminationTask: Task<Void, Never>?
    private let onProgress: (CockpitProgress) async throws -> Void

    init(workspace: WorkspaceManager, root: URL, onProgress: @escaping (CockpitProgress) async throws -> Void = { _ in }) {
        self.workspace = workspace; self.root = root.standardizedFileURL; self.onProgress = onProgress
    }

    func run(_ task: CockpitHostTask) async -> CockpitHostReply {
        guard !Task.isCancelled, let workspace,
              let tool = CLITool.allCases.first(where: { $0.displayName == task.step.agent }),
              BrowserControlServer.agentToolsEnabled(tool),
              let terminal = workspace.openAITerminal(TerminalProfile(tool)) else {
            return Self.failure("The assigned agent or its MarkView project tools are unavailable.")
        }
        guard terminal.directory.standardizedFileURL == root else {
            terminal.terminateCockpitStep()
            return Self.failure("The agent terminal is not in the cockpit's project.")
        }
        session = terminal
        progress = nil
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
                }, waitForShutdown: { [weak self] in await self?.terminationTask?.value }) { [weak self] reply in self?.finish(reply) }
                self.ticket = ticket
                // Controls that cannot be read are replaced by the defaults, which are the restrictive ones.
                let controls = (try? JSONDecoder().decode(CockpitControls.self, from: Data(task.controls.utf8))) ?? CockpitControls()
                CockpitAgentRegistry.restrict(ticket, policy: CockpitStepPolicy(controls: controls), shell: pty.shell)
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
                    When building is disabled, do not claim checks against a newly built version were performed. Build and checks are instructions only: MarkView cannot check them.
                    If this assignment names qaScenarioID, MarkView will run that exact reviewed QA scenario after your report; do not run it separately.
                    If isFinalStep is true, explicitly evaluate each success criterion against evidence, report unmet criteria as blockers, and report passed only if the criteria are met.
                    Use the available MarkView project and browser tools as appropriate. Once you have finished this step, call markview_cockpit_complete_step
                    with project_folder \(root.path), ticket \(ticket.uuidString), passed, detail (evidence and blockers), and build (the build identifier or an empty string).
                    While working, call markview_cockpit_report_progress with the same ticket to report the pass number, activity, scenario coverage, bugs, confirmed fixes, latest change, blockers, and build log path where known. On the final step include criteriaResults for every stated success criterion, with exact criterion text, met or unmet, and supporting evidence.
                    Report whether the completion condition was actually met. Your terminal session ends after your report; do not start subsequent steps.

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
        let finalized = reported
        // The next Temporal step must not start while this terminal's process group is still stopping.
        terminationTask = Task {
            await reaping?.value
            await exited?.wait()
            continuation.resume(returning: finalized)
        }
    }

    private static func failure(_ message: String) -> CockpitHostReply {
        CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: message)
    }
}
