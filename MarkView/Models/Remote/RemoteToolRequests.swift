import Foundation

/// Correlates asynchronous work-computer tool results with the home MCP child's requests.
actor RemoteToolRequests {
    private let channel: RemoteChannel
    private var pending: [UUID: CheckedContinuation<RemoteJSON, Never>] = [:]
    private var closed = false
    init(channel: RemoteChannel) { self.channel = channel }

    func call(id: UUID, name: String, arguments: RemoteJSON) async -> RemoteJSON {
        guard !closed else { return .textResult("Workspace disconnected.", error: true) }
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await channel.send(RemoteMessage("toolCall", .object(["name": .string(name), "arguments": arguments]), id: id)) }
                catch { finish(id, result: .textResult(error.localizedDescription, error: true)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                finish(id, result: .textResult("The work computer did not answer in time. Reconnect before continuing.", error: true))
            }
        }
    }
    func finish(_ id: UUID, result: RemoteJSON) { pending.removeValue(forKey: id)?.resume(returning: result) }
    func close() {
        closed = true
        let continuations = pending.values; pending.removeAll()
        for continuation in continuations { continuation.resume(returning: .textResult("Workspace disconnected.", error: true)) }
    }
}
