import Combine
import Foundation

/// Keyed cancellable task bag owned per window (`AR-19`).
///
/// Storing a task under an existing key automatically cancels the previous task for that key.
/// Calling `cancelAll()` on folder switch or window close cancels all tracked background work.
@MainActor
final class TaskBag {
    private var keyedTasks: [String: AnyCancellable] = [:]

    /// Store a `Task<Success, Never>` under `key`, cancelling any prior task with the same key.
    func store<Success>(_ task: Task<Success, Never>, for key: String) {
        keyedTasks[key]?.cancel()
        keyedTasks[key] = AnyCancellable { task.cancel() }
    }

    /// Cancel and remove all tracked tasks.
    func cancelAll() {
        for (_, cancellable) in keyedTasks {
            cancellable.cancel()
        }
        keyedTasks.removeAll()
    }

    var activeCount: Int { keyedTasks.count }
    func contains(key: String) -> Bool { keyedTasks[key] != nil }
}
