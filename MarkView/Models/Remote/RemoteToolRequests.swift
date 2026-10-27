import Foundation

/// Correlates asynchronous work-computer tool results with the home MCP child's requests.
actor RemoteToolRequests {
    private struct Pending {
        let continuation: CheckedContinuation<RemoteJSON, Never>
        let timeout: Task<Void, Never>
    }
    private let channel: RemoteChannel
    private var pending: [UUID: Pending] = [:]
    private var closed = false
    init(channel: RemoteChannel) { self.channel = channel }

    func call(id: UUID, name: String, arguments: RemoteJSON) async -> RemoteJSON {
        guard !closed else { return .textResult("Workspace disconnected.", error: true) }
        guard pending[id] == nil else { return .textResult("This tool request is already in progress.", error: true) }
        return await withCheckedContinuation { continuation in
            let timeout = Task {
                do { try await Task.sleep(nanoseconds: 90_000_000_000) }
                catch { return }
                finish(id, result: .textResult("The work computer did not answer in time. Reconnect before continuing.", error: true))
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            Task {
                do { try await channel.send(RemoteMessage("toolCall", .object(["name": .string(name), "arguments": arguments]), id: id)) }
                catch { finish(id, result: .textResult(error.localizedDescription, error: true)) }
            }
        }
    }
    func finish(_ id: UUID, result: RemoteJSON) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(returning: result)
    }
    func close() {
        closed = true
        let requests = pending.values; pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(returning: .textResult("Workspace disconnected.", error: true))
        }
    }
}
