import Foundation

/// What a terminal in the AI panel runs: an assistant inside the user's shell, or the
/// shell alone. Its raw value is what is stored with the terminal: the assistant's id, or "shell".
enum TerminalProfile: Hashable, Identifiable {
    case assistant(CLITool)
    case shell

    /// Every assistant in the provider list's order, then the shell.
    static var allCases: [TerminalProfile] { CLITool.allCases.map(TerminalProfile.assistant) + [.shell] }

    init(_ tool: CLITool) { self = .assistant(tool) }

    init?(rawValue: String) {
        if rawValue == Self.shellValue {
            self = .shell
        } else if let tool = CLITool(rawValue: rawValue) {
            self = .assistant(tool)
        } else {
            return nil
        }
    }

    private static let shellValue = "shell"

    var rawValue: String {
        switch self {
        case .assistant(let tool): return tool.rawValue
        case .shell: return Self.shellValue
        }
    }

    var id: String { rawValue }

    var tool: CLITool? {
        if case .assistant(let tool) = self { return tool }
        return nil
    }

    var title: String { tool?.displayName ?? "Shell" }

    var icon: String { tool?.provider.terminalIcon ?? "terminal" }
}
