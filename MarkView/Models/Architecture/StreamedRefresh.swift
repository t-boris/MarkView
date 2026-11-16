import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

extension TaskBag {
    /// The refresh of a streamed answer, at most once per quiet period (`AR-19`): `refresh` runs `nanoseconds` after the first piece that
    /// arrives while no refresh is waiting, however many pieces arrive meanwhile. The wait is the bag's work under `key`, so the reset or
    /// the close of its owner ends it and `refresh` does not run after that.
    func coalesce(key: String, after nanoseconds: UInt64 = 300_000_000, _ refresh: @escaping @MainActor () -> Void) {
        guard !contains(key: key) else { return }
        self.store(Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            refresh()
        }, for: key)
    }
}
