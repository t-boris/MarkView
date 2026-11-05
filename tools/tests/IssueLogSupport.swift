import Foundation

// Test doubles for the lifecycle journal and the status store (MarkView/Models/IssueTransitionLog.swift), shared by the checks that
// run the transition service without files (tools/tests/issue-lifecycle-tests.sh). They are not part of the app.

/// For checks: an in-memory log whose writes can be made to fail.
final class MemoryTransitionStorage: TransitionStorage {
    var records: [TransitionRecord] = []
    /// Phases whose append throws (once the count reaches 0, no more failures); nil = never fails.
    var failing: Set<TransitionRecord.Phase> = []
    struct Failure: Error, LocalizedError { var errorDescription: String? { "the disk is full" } }

    func append(_ record: TransitionRecord) throws {
        if failing.contains(record.phase) { throw Failure() }
        records.append(record)
    }

    func load() throws -> [TransitionRecord] { records }
}

/// For checks.
final class MemoryStatusStore: LifecycleStatusStore {
    var statuses: [String: String] = [:]
    var writeFails = false
    /// Run before a compare-and-set, to simulate another writer.
    var beforeSet: (() -> Void)?
    struct Failure: Error, LocalizedError { var errorDescription: String? { "the file is read-only" } }

    static func key(_ kind: IssueKind, _ issue: String) -> String { kind.rawValue + ":" + issue }

    func status(kind: IssueKind, issue: String) -> String? { statuses[Self.key(kind, issue)] }

    func compareAndSet(kind: IssueKind, issue: String, expected: String, to: String) throws -> Bool {
        beforeSet?()
        if writeFails { throw Failure() }
        let key = Self.key(kind, issue)
        guard let current = statuses[key], LifecycleVocabulary.normalize(current) == LifecycleVocabulary.normalize(expected) else { return false }
        statuses[key] = to
        return true
    }
}
