import Foundation

/// The project's bug reports (`docs/bugs/`) as the place End-to-End QA files its bugs (QABugFiler.swift). A new report goes through
/// `FeatureStore.createBug`, the writer of the `markview_create_bug` tool and of UI Studio's change tracking, so it is numbered, written
/// and listed like theirs; it starts in the status the project's bug workflow gives a report nobody has started on. Which reports
/// already exist is read off the main thread from the front matter of the files (QABugIndex).
struct QAFeatureStoreBugSink: QABugSink {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let store: FeatureStore

    func bugFolder() async -> URL? { await store.bugsFolder }

    func filedBugs(forKeys keys: [String]) async throws -> [String: String] {
        guard let folder = await store.bugsFolder else { throw Failure(message: "This window has no project folder open.") }
        let wanted = Set(keys)
        return try await Task.detached(priority: .userInitiated) { try QABugIndex.filedBugs(in: folder, keys: wanted) }.value
    }

    func allFiledKeys() async throws -> [String] {
        guard let folder = await store.bugsFolder else { throw Failure(message: "This window has no project folder open.") }
        return try await Task.detached(priority: .userInitiated) { try QABugIndex.allKeys(in: folder) }.value
    }

    func createBug(_ report: QABugReport) async throws -> String {
        guard let status = await store.bugStatus(role: .notStarted) else {
            throw Failure(message: "This project's bug workflow has no status with the role \"Not started\", so a new bug has no status to start in.")
        }
        let reporter = await store.defaultOwner
        var draft = BugReportDraft(title: report.title, body: report.body, status: status, severity: report.severity, reporter: reporter,
                                   provenance: report.provenance)
        draft.fields = report.fields.map { (key: $0.key, value: $0.value) }
        return try await store.createBug(draft).id
    }

    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome {
        guard let folder = await store.bugsFolder else { throw Failure(message: "This window has no project folder open.") }
        let file = try await Task.detached(priority: .userInitiated) { try QABugIndex.file(forKey: key, in: folder) }.value
        guard let file else { return .noReport }
        return await apply(change, to: file)
    }

    @MainActor
    private func apply(_ change: QABugTriageChange, to file: URL) async -> QABugTriageOutcome {
        var previous: QATriageState?
        let fallbackID = String(file.deletingPathExtension().lastPathComponent.prefix(7))
        guard store.updateBug(file, { front, body in previous = QABugTriage.apply(change, front: &front, body: &body) }) else {
            return .notChanged(id: fallbackID, reason: store.lastError ?? "The report could not be rewritten.")
        }
        guard let bug = store.bugs.first(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) else { return .updated(id: fallbackID) }
        let flow = store.lifecycle.workflow.bug
        let actor = LifecycleActor.human(store.lifecycleActor)
        let current = LifecycleVocabulary.normalize(bug.status)
        // The steps are the workflow's own: the one that gives a bug up (closed, won't do, canceled) and the one that takes it back.
        if let reason = change.cancelReason {
            guard let step = flow.rules.first(where: { $0.kind == .cancellation && $0.from.contains(current) && $0.needs[.human] != nil }) else {
                return flow.role(of: current)?.isFinished == true ? .updated(id: bug.key)
                    : .notChanged(id: bug.key, reason: "This project's bug workflow has no step that closes a bug without a fix from \(bug.status).")
            }
            let result = await store.lifecycle.request(.bug, bug.key, to: step.to, actor: actor, reason: reason, cancellation: .invalid(reason), surface: false)
            return result.reachedStatus ? .updated(id: bug.key) : .notChanged(id: bug.key, reason: result.explanation)
        }
        if previous == .notABug, let step = flow.rules.first(where: { $0.kind == .reopen && $0.from.contains(current) && $0.needs[.human] != nil }) {
            let result = await store.lifecycle.request(.bug, bug.key, to: step.to, actor: actor, reason: "The QA mark \"Not a bug\" was taken back.", surface: false)
            return result.reachedStatus ? .updated(id: bug.key) : .notChanged(id: bug.key, reason: result.explanation)
        }
        return .updated(id: bug.key)
    }
}
