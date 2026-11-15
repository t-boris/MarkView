import Foundation

/// What the features that work with a window's assistants (the Cockpit, End-to-End QA, the activity monitor) ask of the window: which
/// assistant answers now, which terminals run, and a new assistant terminal on request. They hold this instead of closures wired by the
/// workspace one by one (AR-17); `AITerminalsController` is the one implementation.
@MainActor
protocol AssistantProviding: AnyObject {
    /// The assistant a prompt goes to now: the shown agent's tool with the project's chosen model; nil when no agent terminal is open.
    var currentAssistant: CLICompletion.Assistant? { get }
    /// The AI panel's terminals, in tab order, and the shown one.
    var sessions: [TerminalSession] { get }
    var shownID: UUID? { get }
    /// An assistant terminal's own log names the model it runs now (BUG-048, Claude Code).
    func liveModelReported(_ model: String, terminalID: UUID)
    /// Open another terminal running `profile` in the AI panel and show it; nil without a folder.
    /// `model` starts the assistant with that model instead of the one chosen for the project.
    @discardableResult
    func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession?
    /// Bring the AI panel to the front.
    func showAIConsole()
}
