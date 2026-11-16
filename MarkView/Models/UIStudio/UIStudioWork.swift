import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The one piece of work a session does at a time (the assistant's answer, a repair, a restore, an export): its title and detail for the
/// busy banner, the conversation turn it answers, and the task to wait for or cancel. It also starts every task the session's parts
/// start, so that none outlives its session (`startPartTask`).
@MainActor
final class StudioWork: ObservableObject {
    /// Unowned: the session owns this part. A task a part starts holds the session through `startPartTask`, so it is never read after it is gone.
    unowned let session: StudioSession

    /// The turn the assistant is answering; nil once it is in `history`, and after a failure or Stop.
    @Published var pendingTurn: StudioSession.PendingTurn?
    /// The title of the work in progress; nil when the session is free.
    @Published private(set) var busy: String?
    /// What the work is doing now.
    @Published var busyDetail = ""
    private(set) var workTask: Task<Void, Never>?
    /// Every task a part of the session started and that has not ended; `close()` of the session cancels them.
    private let tasks = TaskBag()

    /// The one way a part of the session starts a task that goes on after the call (the lifetime rule of the parts, AR-16): the parts hold
    /// their session `unowned`, and a continuation that reads it after an `await` traps once the session has been released, so the task
    /// holds the session until it ends. The session closes with `close()`, which cancels every task started here; a task that ignores its
    /// cancellation keeps the session alive for as long as it runs, and nothing else does. The closure gets the session it holds.
    @discardableResult
    func startPartTask(_ body: @escaping @MainActor (StudioSession) async -> Void) -> Task<Void, Never> {
        // task: the one place a part's task starts; it is kept in `tasks`, which close() cancels
        let task = Task { [session] in await body(session) }
        tasks.store(task, for: UUID().uuidString)
        // A task started once the session has closed has nothing left to do: it starts cancelled, so that it ends at its first check.
        if session.closed { task.cancel() }
        return task
    }

    /// Cancels every task a part started (the session closes).
    func cancelPartTasks() { tasks.cancelAll() }

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
        workTask = startPartTask { session in
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
