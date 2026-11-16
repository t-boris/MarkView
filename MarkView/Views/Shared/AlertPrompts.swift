import AppKit

/// The app's answer to `UserPrompts` (`AR-22`): each question is an app-modal `NSAlert`, its buttons added in the order the model gave
/// them (the first is the default), and the answer is the index of the one pressed. The only place that makes an alert for a model.
@MainActor
struct AlertPrompts: UserPrompts {
    func ask(_ prompt: UserPrompt) -> Int? {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        for title in prompt.buttons { alert.addButton(withTitle: title) }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        // An alert with no button of its own shows one "OK". A response outside the buttons (the modal session was stopped) is no answer.
        return (0..<max(prompt.buttons.count, 1)).contains(index) ? index : nil
    }

    func chooseFiles(allowsMultiple: Bool, allowsDirectories: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
