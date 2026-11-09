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

    /// A person says that manual work has started (REQ-004): the note is asked first and is the start evidence for a variant that
    /// accepts one. The start itself is still decided by the workflow.
    @discardableResult
    static func startByNote(store: FeatureStore, kind: IssueKind, issue: String) -> Bool {
        guard let note = askReason(title: "Start \(issue) by hand", message: "Write what has been started. The history keeps your note as the start evidence.",
                                   button: "Start", placeholder: "What has been started (required)") else { return false }
        let result = store.lifecycle.startManually(kind, issue, note: note, by: .human(store.lifecycleActor), surface: false)
        if result.reachedStatus { return true }
        store.lastError = result.explanation
        return false
    }

    /// A person confirms the delivery event the variant names. MarkView then completes the work when the rest of its evidence is there.
    @discardableResult
    static func confirmDelivery(store: FeatureStore, kind: IssueKind, issue: String, event: String) async -> Bool {
        guard let note = askReason(title: "Confirm “\(event)”", message: "\(issue): say how you know. The history keeps your note as delivery evidence.",
                                   button: "Confirm", placeholder: "How you know (required)") else { return false }
        if case .refused(let reason) = store.lifecycle.confirmDelivery(kind, issue, note: note, by: .human(store.lifecycleActor)) {
            store.lastError = reason
            return false
        }
        await store.lifecycle.completeFinishedWork(only: [(kind: kind, issue: issue)])
        return true
    }

    /// A sheet that asks for one line of text; nil when cancelled or left empty.
    private static func askReason(title: String, message: String, button: String, placeholder: String = "Why (required)") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
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
