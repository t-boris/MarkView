import AppKit

/// A status change the person asks for in the window (the status menus, "mark done" in the Sync report, Accept, Reopen).
/// The lifecycle service decides: when the conditions are met it just happens; when they are not, the person is told what
/// is missing and may change the status anyway with a reason, which the history keeps together with the bypassed
/// conditions (Q-002 B, DEC-011). Only a person can do this: it exists only here, in the window.
@MainActor
enum LifecycleStatusChange {
    /// Asks for `status` of the item. Returns true when the status is now the requested one.
    @discardableResult
    static func perform(store: FeatureStore, kind: IssueKind, issue: String, to status: String) async -> Bool {
        let actor = LifecycleActor.human(store.lifecycleActor)
        let result = await store.lifecycle.request(kind, issue, to: status, actor: actor, surface: false)
        switch result {
        case .applied, .unchanged, .duplicate:
            return true
        case .unrecorded:
            // The status is written; only its history record is missing and the next start finishes it.
            store.lastError = result.explanation
            return true
        case .rejected(let rejection):
            guard let reason = askToForce(issue: issue, status: status, rejection: rejection) else { return false }
            let forced = await store.lifecycle.request(kind, issue, to: status, actor: actor, reason: reason, force: true, surface: false)
            if forced.reachedStatus { return true }
            store.lastError = forced.explanation
            return false
        case .stale, .failed:
            store.lastError = result.explanation
            return false
        }
    }

    /// Reopens a completed item into its unfinished status. A person reopens with a reason (REQ-002); it is asked first, so
    /// nothing is forced and nothing is bypassed.
    @discardableResult
    static func reopen(store: FeatureStore, kind: IssueKind, issue: String, to status: String) async -> Bool {
        guard let reason = askReason(title: "Reopen \(issue)", message: "\(issue) goes back to \(status). The history keeps your reason.",
                                     button: "Reopen") else { return false }
        let actor = LifecycleActor.human(store.lifecycleActor)
        let result = await store.lifecycle.request(kind, issue, to: status, actor: actor, reason: reason, surface: false)
        if result.reachedStatus { return true }
        if case .rejected(let rejection) = result {
            guard let forced = askToForce(issue: issue, status: status, rejection: rejection) else { return false }
            let again = await store.lifecycle.request(kind, issue, to: status, actor: actor, reason: forced, force: true, surface: false)
            if again.reachedStatus { return true }
            store.lastError = again.explanation
            return false
        }
        store.lastError = result.explanation
        return false
    }

    /// A sheet that asks for one line of text; nil when cancelled or left empty.
    private static func askReason(title: String, message: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Why (required)"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The refusal in words, and the person's reason for changing the status anyway; nil when they decline.
    private static func askToForce(issue: String, status: String, rejection: Rejection) -> String? {
        let alert = NSAlert()
        alert.messageText = "MarkView will not set \(issue) to \(status) on its own"
        var lines = [rejection.message]
        lines += rejection.hints
        lines.append("")
        lines.append("You can change it anyway. The history keeps your reason and the conditions that were bypassed, and the status "
                     + "will not count as verified completion.")
        alert.informativeText = lines.joined(separator: "\n")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Why (required)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Change anyway")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let reason = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }
}
