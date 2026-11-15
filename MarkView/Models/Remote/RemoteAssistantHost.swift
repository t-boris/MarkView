import Foundation

/// What a saved connection needs of the window it opens an assistant in: the folder the assistants work in, and a terminal for the
/// home assistant. `AITerminalsController` is the implementation.
@MainActor
protocol RemoteAssistantHost: AnyObject {
    /// The folder the window's assistants work in; nil with no folder open.
    var root: URL? { get }
    func openRemoteAITerminal(code: String, provider: CLITool, model: String?, resume: Bool,
                              savedConnectionID: UUID?) async throws -> TerminalSession
}
