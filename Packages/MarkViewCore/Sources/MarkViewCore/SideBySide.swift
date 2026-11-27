import Foundation

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
                group.addTaskUnlessCancelled { (index, try await work(item)) }
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
}
