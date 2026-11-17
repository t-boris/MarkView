/// What the person starts from the panels of one project, each as a job under a key (`AR-19`): an AI step on a feature, a status
/// change, a source added. A button starts a job and returns at once; the task is kept here and not in the view, so a second tap
/// while the job runs does not start it again, and the folder switching or the window closing (`cancelAll`, called by
/// `FeatureStore.reset`) ends every job that still runs.
@MainActor
public final class FeatureJobs {
    public init() {}
    private let tasks = TaskBag()

    /// Starts `work` as the job `key` and returns at once. A job of that key that still runs makes this a no-op: the AI calls refuse a
    /// second run of their own key, and a second status change would ask the person the same question twice. Returns whether `work`
    /// was started.
    @discardableResult
    public func start(_ key: String, _ work: @escaping @MainActor () async -> Void) -> Bool {
        if tasks.contains(key: key) { return false }
        tasks.store(Task { await work() }, for: key)
        return true
    }

    /// Whether the job `key` has been started and has not ended.
    public func isRunning(_ key: String) -> Bool { tasks.contains(key: key) }

    /// Ends every job that still runs.
    public func cancelAll() { tasks.cancelAll() }
}
