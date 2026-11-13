import Foundation

/// One-use completion tickets bind an agent's report to the project and step that issued it.
@MainActor
enum CockpitAgentRegistry {
    private struct Pending {
        let root: URL
        let finish: (CockpitHostReply) -> Void
    }
    private static var pending: [UUID: Pending] = [:]

    static func register(root: URL, finish: @escaping (CockpitHostReply) -> Void) -> UUID {
        let token = UUID()
        pending[token] = Pending(root: root.standardizedFileURL, finish: finish)
        return token
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
}
