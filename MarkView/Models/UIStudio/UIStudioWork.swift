import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The one piece of work a session does at a time (the assistant's answer, a repair, a restore, an export): its title and detail for the
/// busy banner, the conversation turn it answers, and the task to wait for or cancel.
@MainActor
final class StudioWork: ObservableObject {
    unowned let session: StudioSession

    /// The turn the assistant is answering; nil once it is in `history`, and after a failure or Stop.
    @Published var pendingTurn: StudioSession.PendingTurn?
    /// The title of the work in progress; nil when the session is free.
    @Published private(set) var busy: String?
    /// What the work is doing now.
    @Published var busyDetail = ""
    private(set) var workTask: Task<Void, Never>?

    /// Waits for the work `runWork` started.
    func awaitWork() async { await workTask?.value }

    /// What the busy banner says the work is doing now.
    func showBusyDetail(_ text: String) { busyDetail = text }

    /// Runs one piece of work at a time. `pending` is the conversation turn it answers, shown until the work appends it
    /// to the history; whatever way the work ends (answered, failed, cancelled), no pending turn outlives it.
    func runWork(_ title: String, pending: StudioSession.PendingTurn? = nil, _ work: @escaping @MainActor (StudioSession) async -> Void) {
        guard busy == nil, !session.closed else {
            session.notice = "Wait for \(busy ?? "the current work") to finish."
            return
        }
        busy = title
        busyDetail = ""
        pendingTurn = pending
        workTask = Task { [weak self, session] in
            guard let self else { return }
            await work(session)
            self.busy = nil
            self.busyDetail = ""
            self.pendingTurn = nil
        }
    }

    /// Stops the work in progress, and every rule preparation with it.
    func cancelWork() {
        workTask?.cancel()
        session.preparation.cancelEverything()
    }

    /// What the busy banner says for what the assistant is doing.
    func progress(_ activity: CLICompletion.Activity) {
        switch activity {
        case .read(let path): busyDetail = "Reading " + (path as NSString).lastPathComponent
        case .search(let pattern): busyDetail = "Searching for " + String(pattern.prefix(40))
        case .run: busyDetail = "Looking at the project"
        case .thinking: busyDetail = "Thinking"
        case .writing(let count): busyDetail = "Writing (\(count) characters)"
        case .webSearch, .webFetch, .answerDelta: break
        }
    }

    init(session: StudioSession) {
        self.session = session
    }
}
