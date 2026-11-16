import Foundation

/// Work that must happen one piece at a time, in the order it was asked for, and must not be dropped (`AR-19`): the writes of an
/// object that outlives its windows, where a later write that finished first would be overwritten by an earlier one, or two
/// read-modify-write cycles of one file would each lose the other's change.
///
/// Unlike `TaskBag` it never cancels: a piece of work is something the person asked for and the file must have. The owner calls
/// `drain()` before it goes away (the quit of the application, the end of a test) and every piece asked for so far has ended by then.
@MainActor
public final class OrderedWork {
    /// The last piece asked for. Each piece waits for the one before it, so the chain is the queue; a piece that has ended is released.
    private var last: Task<Void, Never>?

    public init() {}

    /// Runs `work` once every piece asked for before it has ended. The pieces never overlap, even where they suspend.
    public func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let before = last
        last = Task {
            await before?.value
            await work()
        }
    }

    /// Returns once every piece asked for before this call has ended (a piece asked for later may still be running).
    public func drain() async {
        await last?.value
    }
}
