import Foundation
#if canImport(MarkView)
@testable import MarkView
#endif

/// The person, as a script, for the checks of the models that ask a question (`AR-22`): a stand-in `UserPrompts` that records every
/// prompt it is given and answers from a list. The shipping models run unchanged; nothing is shown and nothing can block.
@MainActor
final class ScriptedPrompts: UserPrompts {
    /// What the person does next.
    enum Answer {
        /// Presses the button with this title (the prompt must offer it).
        case press(String)
        /// Nobody answers: the window is gone, or the prompt could not be shown.
        case dismiss
    }

    /// The answers still to give, in order. When the list is empty nobody answers, so a path that waits for the person is refused
    /// and a check that forgot an answer fails on the refusal instead of hanging.
    var script: [Answer] = []
    /// Every prompt asked, in order.
    private(set) var asked: [UserPrompt] = []

    func ask(_ prompt: UserPrompt) -> Int? {
        asked.append(prompt)
        guard !script.isEmpty else { return nil }
        switch script.removeFirst() {
        case .dismiss:
            return nil
        case .press(let title):
            guard let index = prompt.buttons.firstIndex(of: title) ?? (title == "OK" && prompt.buttons.isEmpty ? 0 : nil) else {
                preconditionFailure("the prompt \"\(prompt.title)\" has no button \"\(title)\": \(prompt.buttons)")
            }
            return index
        }
    }

    /// The titles asked, in order.
    var titles: [String] { asked.map(\.title) }
}
