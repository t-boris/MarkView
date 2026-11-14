import Foundation

/// One step gets a fresh existing agent terminal and a one-use reporting ticket.
@MainActor
final class CockpitAgentAttempt {
    private weak var workspace: WorkspaceManager?
    private let root: URL
    private var session: TerminalSession?
    private var ticket: UUID?
    private var continuation: CheckedContinuation<CockpitHostReply, Never>?

    init(workspace: WorkspaceManager, root: URL) { self.workspace = workspace; self.root = root.standardizedFileURL }

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
        workspace.showAIConsole()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { terminal.terminateCockpitStep(); continuation.resume(returning: Self.failure("The step was interrupted.")); return }
                self.continuation = continuation
                let ticket = CockpitAgentRegistry.register(root: root) { [weak self] reply in self?.finish(reply) }
                self.ticket = ticket
                terminal.onExit = { [weak self] _ in self?.cancel(reason: "The agent terminal exited before reporting a result.") }
                terminal.onCockpitTermination = { [weak self] in self?.cancel(reason: "The agent terminal was closed before reporting a result.") }
                do {
                    let data = try JSONEncoder().encode(task)
                    let assignment = String(decoding: data, as: UTF8.self)
                    let prompt = """
                    This is one step of a user-approved Copilot Cockpit plan. Work only on the assignment below; the selected controls are advisory instructions.
                    Follow the controls in the assignment: when fixes are disabled, report findings without fixing them; when deployment is disabled, do not deploy.
                    When building is disabled, do not claim checks against a newly built version were performed.
                    If this assignment names qaScenarioID, MarkView will run that exact reviewed QA scenario after your report; do not run it separately.
                    Use the available MarkView project and browser tools as appropriate. Once you have finished this step, call markview_cockpit_complete_step
                    with project_folder \(root.path), ticket \(ticket.uuidString), passed, detail (evidence and blockers), and build (the build identifier or an empty string).
                    Report whether the completion condition was actually met. Your terminal session ends after your report; do not start subsequent steps.

                    Assignment and prior results (JSON):
                    \(assignment)
                    """
                    terminal.pasteWhenReady(prompt, submit: true)
                } catch { cancel(reason: "The step assignment could not be prepared.") }
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
        ticket = nil
        session?.onExit = nil
        session?.onCockpitTermination = nil
        let reaping = session?.terminateCockpitStep()
        session = nil
        // The next Temporal step must not start while this terminal's process group is still stopping.
        Task {
            await reaping?.value
            continuation.resume(returning: reply)
        }
    }

    private static func failure(_ message: String) -> CockpitHostReply {
        CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: message)
    }
}
