import Foundation

/// One-use completion tickets bind an agent's report to the project and step that issued it.
@MainActor
enum CockpitAgentRegistry {
    private struct Pending {
        let root: URL
        let finish: (CockpitHostReply) -> Void
        let progress: (CockpitProgress) async throws -> Void
        let waitForShutdown: () async -> Void
    }
    private static var pending: [UUID: Pending] = [:]

    static func register(root: URL, progress: @escaping (CockpitProgress) async throws -> Void = { _ in },
                         waitForShutdown: @escaping () async -> Void = {}, finish: @escaping (CockpitHostReply) -> Void) -> UUID {
        let token = UUID()
        pending[token] = Pending(root: root.standardizedFileURL, finish: finish, progress: progress, waitForShutdown: waitForShutdown)
        return token
    }

    @discardableResult static func report(root: URL, token: UUID, progress: CockpitProgress) async -> Bool {
        guard (1...1_000).contains(progress.passNumber),
              [progress.scenarioCoverage, progress.bugs, progress.fixes, progress.blockers].allSatisfy({ $0.count <= 100 }),
              (progress.criteriaResults?.count ?? 0) <= 100,
              let data = try? JSONEncoder().encode(progress), data.count <= 16_000,
              let item = pending[token], item.root == root.standardizedFileURL else { return false }
        do { try await item.progress(progress); return true } catch { return false }
    }

    @discardableResult static func complete(root: URL, token: UUID, result: CockpitHostResult) -> Bool {
        guard result.detail.utf8.count <= 32_000, result.build.utf8.count <= 2_000,
              let item = pending[token], item.root == root.standardizedFileURL else { return false }
        pending[token] = nil
        item.finish(CockpitHostReply(result: result, error: ""))
        return true
    }

    static func cancel(_ token: UUID, reason: String) {
        guard let item = pending.removeValue(forKey: token) else { return }
        item.finish(CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: reason))
    }

    static func cancelAll(reason: String) {
        for token in Array(pending.keys) { cancel(token, reason: reason) }
    }

    static func cancelAllAndWait(reason: String) async {
        let items = pending
        for token in items.keys { cancel(token, reason: reason) }
        for item in items.values { await item.waitForShutdown() }
    }
}
