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
}
