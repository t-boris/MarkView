import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The operations of a session (UI Studio history) and the conversation the assistant remembers: every question, context change and
/// code change with its checks, kept in `.dde/studio/history`; and which of them the thread shows (BUG-075).
@MainActor
final class StudioHistory: ObservableObject {
    unowned let session: StudioSession

    @Published private(set) var history: [StudioOperation] = []

    /// The turns of the current conversation: the thread shows them and the assistant remembers them. A UI Studio session
    /// starts with an empty conversation and Clear starts a new one (BUG-075), so yesterday's request about another element
    /// neither fills the thread nor steers today's change (BUG-068). Every operation stays in History, with undo.
    @Published private(set) var conversationIds: Set<String> = []

    /// The conversation, oldest first.
    var conversation: [StudioOperation] { history.filter { conversationIds.contains($0.id) } }

    /// Starts a new conversation (BUG-075): the thread is empty and the assistant forgets its turns. History, undo and
    /// versions are not touched.
    func clearConversation() {
        guard session.busy == nil else { return }
        conversationIds = []
    }

    func newOperationID() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "op-\(stamp)-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// Keeps a change (it stays in the history and can still be undone).
    func keep(_ id: String) {
        guard var operation = history.first(where: { $0.id == id }), operation.status == .applied else { return }
        operation.status = .kept
        replace(operation)
    }

    /// Puts `operation` at the end of the history and into the thread. A turn that ends the assistant's pending one says so; one that
    /// is only noted for the person (a connection that cannot be simulated) leaves the pending turn alone.
    func append(_ operation: StudioOperation, endsPendingTurn: Bool = true) {
        history.removeAll { $0.id == operation.id }
        history.append(operation)
        conversationIds.insert(operation.id)
        // The turn is in the thread now (a change may still be verifying, under the busy banner).
        if endsPendingTurn { session.pendingTurn = nil }
        persistHistory()
    }

    /// A question that was answered belongs to the conversation again (the assistant asked it).
    func rejoinConversation(_ id: String) { conversationIds.insert(id) }

    func replace(_ operation: StudioOperation) {
        if let index = history.firstIndex(where: { $0.id == operation.id }) { history[index] = operation } else { history.append(operation) }
        persistHistory()
    }

    private func persistHistory() {
        let history = history, root = session.root
        session.io.async { try? StudioStore.saveHistory(history, root: root) }
    }

    init(session: StudioSession) {
        self.session = session
        history = StudioStore.loadHistory(session.root)
    }
}
