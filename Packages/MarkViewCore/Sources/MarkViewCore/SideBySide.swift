import os

/// Independent pieces of work that run at the same time, a bounded number at once: the runs of one action whose answers do not
/// depend on each other (the sections of a translation, the passages of a book chapter, the scenarios of an X-Ray trace).
public enum SideBySide {
    /// Runs `work` for every item, at most `limit` at a time, launched in the order of `items`. `done` receives each output as
    /// its run ends, in the order the runs end, on the caller's actor; the outputs are returned in the order of `items`.
    /// An error thrown by `work` cancels the runs still going and is rethrown once they have ended: a run whose failure must not
    /// stop the others returns the failure as its output. A cancellation of the caller cancels the runs still going and starts no
    /// more; `done` still gets what those runs return, and the call then throws `CancellationError`.
    public static func map<Item: Sendable, Output: Sendable>(
        _ items: [Item], limit: Int, isolation: isolated (any Actor)? = #isolation,
        work: @escaping @Sendable (Item) async throws -> Output,
        done: (Int, Output) -> Void = { _, _ in }
    ) async throws -> [Output] {
        var outputs = [Output?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, Output).self, isolation: isolation) { group in
            // The body runs on the caller's actor only when it captures the isolation (SE-0420), so `done` can touch its state.
            _ = isolation
            var next = 0
            func launch() {
                guard next < items.count else { return }
                let index = next, item = items[index]
                next += 1
                // A cancelled caller starts no more runs: the item keeps no output, so the call throws below.
                guard group.addTaskUnlessCancelled(operation: { (index, try await work(item)) }) else { return }
            }
            for _ in 0..<min(max(1, limit), items.count) { launch() }
            while let (index, output) = try await group.next() {
                outputs[index] = output
                done(index, output)
                launch()
            }
        }
        // Items never started: the caller was cancelled.
        if outputs.contains(where: { $0 == nil }) { throw CancellationError() }
        return outputs.compactMap { $0 }
    }

    /// A limit shared by runs that start at different times (the ratings asked for as a map is zoomed, the files added one by
    /// one, the passages of chapters rewritten side by side): at most `limit` run at once, and the others wait for a slot in the
    /// order they asked for one.
    public final class Slots: Sendable {
        private struct Queue {
            var running = 0
            var lastTicket = 0
            var waiting: [(ticket: Int, slot: CheckedContinuation<Void, any Error>)] = []
        }

        private let limit: Int
        private let queue = OSAllocatedUnfairLock(initialState: Queue())

        public init(limit: Int) { self.limit = max(1, limit) }

        /// Runs `work` on the caller's actor once a slot is free and frees the slot when it ends, whether it returns or throws. A
        /// caller cancelled while it waits leaves the queue without a slot and gets `CancellationError`.
        public func run<Output>(isolation: isolated (any Actor)? = #isolation,
                                _ work: () async throws -> Output) async throws -> Output {
            try await take()
            defer { free() }
            return try await work()
        }

        private func take() async throws {
            try Task.checkCancellation()
            let limit = limit
            let ticket: Int? = queue.withLock { queue in
                if queue.running < limit {
                    queue.running += 1
                    return nil
                }
                queue.lastTicket += 1
                return queue.lastTicket
            }
            guard let ticket else { return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (slot: CheckedContinuation<Void, any Error>) in
                    // A cancellation that came before the wait began finds no waiter to remove: it is seen here instead.
                    let cancelled = queue.withLock { queue in
                        if Task.isCancelled { return true }
                        queue.waiting.append((ticket, slot))
                        return false
                    }
                    if cancelled { slot.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let slot = queue.withLock { queue -> CheckedContinuation<Void, any Error>? in
                    guard let index = queue.waiting.firstIndex(where: { $0.ticket == ticket }) else { return nil }
                    return queue.waiting.remove(at: index).slot
                }
                slot?.resume(throwing: CancellationError())
            }
        }

        /// The slot passes to the first waiter, or is given back.
        private func free() {
            let next = queue.withLock { queue -> CheckedContinuation<Void, any Error>? in
                guard !queue.waiting.isEmpty else {
                    queue.running -= 1
                    return nil
                }
                return queue.waiting.removeFirst().slot
            }
            next?.resume()
        }
    }
}
