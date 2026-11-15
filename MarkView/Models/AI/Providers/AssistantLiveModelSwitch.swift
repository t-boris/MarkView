import Foundation

/// An assistant whose running session changes its model when a command is typed into it (Claude Code's `/model`), and
/// whose own session log says which model it runs now.
protocol AssistantLiveModelSwitch: Sendable {
    /// The models a command can name: family aliases that always mean the family's newest model.
    var families: [String] { get }
    /// "claude-sonnet-5-5" and "Sonnet 5.5" are both "sonnet"; nil when no family is named.
    func family(of name: String) -> String?
    /// The command to type into the session to switch to `model` (a member of `families`).
    func command(for model: String) -> String
    /// `title` with its model part replaced by `model` ("Claude Code · fable" → "Claude Code · sonnet").
    func title(_ title: String, model: String) -> String
    /// The newest model in the session log's `lines` (oldest first) that applied at or after `since`.
    func reading(lines: [Data], since: Date?) -> AssistantModelReading?
}

/// A model a session log says the session used, and when.
struct AssistantModelReading: Equatable, Sendable {
    /// What `--model` accepts: a family alias when the name belongs to a known family, else the model id as logged.
    let model: String
    let date: Date
}
