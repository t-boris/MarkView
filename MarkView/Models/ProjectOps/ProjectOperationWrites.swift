import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Everything the operations of one project write to disk, in the order it was asked for (`AR-19`): the edits the person makes to the
/// shared operations file (`.markview/operations.json`) and the run records of the local history (`state.db`).
///
/// An edit reads the file, changes it and writes it back, so two of them at once would each start from the same text and the later
/// write would drop the earlier change. A run's record is written when the run starts and again when it ends, and the two writes of a
/// short run would otherwise race each other for the last word. Each kind has a lane that runs one piece at a time, in order. The work
/// is never cancelled (it is what the person asked for and the file must have it); the quit of the application drains it.
@MainActor
final class ProjectOperationWrites {
    private let root: URL
    private let edits = OrderedWork()
    private let history = OrderedWork()

    init(root: URL) {
        self.root = root
    }

    /// Applies `edit` to the operations file once every edit asked for before it has been written (a hand edit or a git update that landed
    /// while it was prepared is applied again on top, `ProjectOperationsFile.mutate`), then tells `finished` what came of it.
    func edit(_ edit: @escaping @Sendable (inout ProjectOperationsDocument) throws -> Void,
              finished: @escaping @MainActor (Result<ProjectOperationsDocument, Error>) -> Void) {
        let root = self.root
        edits.enqueue {
            let result = await Task.detached { Result { try ProjectOperationsFile.mutate(root: root, edit) } }.value
            finished(result)
        }
    }

    /// Saves a run's record to the local history after the records asked for before it, so the last one asked for is the one kept.
    func record(_ run: ProjectOperationLastRun) {
        let root = self.root
        history.enqueue {
            await Task.detached { try? ProjectOperationHistory.save(run, root: root) }.value
        }
    }

    /// Returns once every edit and every record asked for before this call is on disk.
    func drain() async {
        await edits.drain()
        await history.drain()
    }
}
