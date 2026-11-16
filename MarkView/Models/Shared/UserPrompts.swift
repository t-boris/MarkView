import Foundation

/// One question or notice a model puts to the person: what the alert says and the buttons it offers.
struct UserPrompt: Equatable {
    var title: String
    var detail = ""
    /// The button titles in the order they are shown. The first is the default button (the one Return presses), so the safe answer
    /// comes first. No titles is a notice with a single "OK".
    var buttons: [String] = []
}

/// How a model asks the person for a decision or tells them what happened (`AR-22`). A model never shows a dialog itself: it is given a
/// `UserPrompts` when it is made (`WindowComposition` for a window's parts) and asks through it. The app answers with alerts
/// (`AlertPrompts`); a check answers with a script, so a path that waits for the person can be run without a window.
///
/// The answer is given before `ask` returns, because the callers sit where AppKit wants one at once: `windowShouldClose`, the question
/// before a folder closes, the unsaved changes of a tab, a page's own `confirm`.
@MainActor
protocol UserPrompts {
    /// Shows `prompt` and waits: the index of the button pressed (0 for the "OK" of a notice), or nil when nobody could answer.
    func ask(_ prompt: UserPrompt) -> Int?
}

extension UserPrompts {
    /// True when the button at `button` was pressed. Any other button, and no answer, leave things as they were.
    func confirm(_ prompt: UserPrompt, proceedingWith button: Int) -> Bool {
        ask(prompt) == button
    }

    /// Tells the person something and waits until they have read it.
    func inform(_ title: String, _ detail: String = "") {
        _ = ask(UserPrompt(title: title, detail: detail))
    }
}

/// A place nobody can be asked from (a headless QA player): every question stays unanswered, so a notice is dismissed and a
/// confirmation is refused.
struct NoPrompts: UserPrompts {
    func ask(_ prompt: UserPrompt) -> Int? { nil }
}
