import Foundation

/// What the parts of the X-Ray (`ChangeReviewStore`, ...) share with the store that owns them: the snapshot they read, the one status
/// line and error the page shows, the run flag and the assistant call that go with it, and the revision the page re-renders on. The
/// parts own everything else themselves.
@MainActor
protocol ArchitectureHost: AnyObject {
    /// The architecture as last committed.
    var snapshot: ArchitectureSnapshot? { get }
    /// The project whose assistant, model and X-Ray model this X-Ray uses.
    var project: URL? { get }
    /// The project a folder X-Ray belongs to (nil for the project's own).
    var projectRoot: URL? { get }
    /// Root folder of this X-Ray (the project or one of its folders).
    var rootPath: String? { get }
    /// The status line the page shows.
    var status: String? { get }
    /// A scan or an AI pass of the store is running.
    var isBusy: Bool { get }
    /// What the file at `path` is made of, when it has been outlined.
    func outline(for path: String) -> XRayContent.Outline?
    /// Make `next` the architecture and save it to the project's database in the order commits were made.
    func commit(_ next: ArchitectureSnapshot, db: SemanticDatabase?)
    /// Show `next` while an answer streams in; it is saved by the `commit` that ends the answer, and the caller bumps the revision.
    func show(_ next: ArchitectureSnapshot)
    /// Where this X-Ray's cached assistant answers are kept.
    func answerCache(_ root: URL) -> URL
    /// The page must re-render.
    func bump()
    /// The error line the page shows (nil clears it). It does not re-render the page by itself: callers `bump` where they did.
    func setError(_ message: String?)
    /// The status line the page shows (nil clears it).
    func setStatus(_ text: String?)
    /// Take the run flag for an AI pass; `endRun` with the returned token releases it.
    func beginRun() -> Int
    func endRun(_ token: Int)
    /// One assistant call through the X-Ray settings: answered from the project's cache when the same input was analysed before,
    /// `fresh` asks again (see `ArchitectureStore.xrayCall`).
    func assistantCall(_ request: CLICompletion.Request, root: URL, db: SemanticDatabase?, call: Int, fresh: Bool) async throws -> [String: Any]
}
