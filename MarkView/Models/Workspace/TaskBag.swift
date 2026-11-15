import Foundation

/// Keyed cancellable task bag owned per window, tool tab or long-lived object (`AR-19`).
///
/// Storing a task under an existing key cancels the previous task for that key, so a new run replaces the old one. A task that
/// ends on its own leaves the bag, so `activeCount` counts work that is still running and a unique key per run never piles up.
/// `cancelAll()` on folder switch, close of the tool or close of the window cancels everything that is tracked.
@MainActor
final class TaskBag {
    private struct Entry {
        let serial: UInt64
        let cancel: () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var serial: UInt64 = 0

    /// Store `task` under `key`, cancelling any prior task with the same key.
    func store<Success, Failure: Error>(_ task: Task<Success, Failure>, for key: String) {
        entries[key]?.cancel()
        serial += 1
        let mine = serial
        entries[key] = Entry(serial: mine, cancel: { task.cancel() })
        // task: waits for `task` to end so that it leaves the bag; it holds the bag weakly and touches nothing else
        Task { [weak self] in
            _ = await task.result
            self?.forget(key, serial: mine)
        }
    }

    /// Cancel and remove the task stored under `key`, if any.
    func cancel(key: String) {
        entries.removeValue(forKey: key)?.cancel()
    }

    /// Cancel and remove all tracked tasks.
    func cancelAll() {
        let all = entries.values
        entries.removeAll()
        for entry in all { entry.cancel() }
    }

    /// The tasks that are tracked and have not ended.
    var activeCount: Int { entries.count }
    func contains(key: String) -> Bool { entries[key] != nil }

    /// A task that ended leaves the bag, unless a newer task already took its key.
    private func forget(_ key: String, serial: UInt64) {
        if entries[key]?.serial == serial { entries[key] = nil }
    }
}
