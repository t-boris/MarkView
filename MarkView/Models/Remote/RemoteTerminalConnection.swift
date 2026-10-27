import Foundation

@MainActor
final class RemoteTerminalConnection: TerminalConnection {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    private let channel: RemoteChannel
    private let workspace: RemoteWorkspace
    private let provider: RemoteProviderConfiguration.Provider
    private let model: String?
    private let resume: Bool
    private var task: Task<Void, Never>?
    private var stopped = false
    private var readyToSend = false
    private var outgoing: [RemoteMessage] = []
    private var sending: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastHomeMessage = Date()
    private var size = (cols: 120, rows: 30)

    init(invitation: RemoteInvitation, root: URL, provider: RemoteProviderConfiguration.Provider, model: String?, resume: Bool) async throws {
        channel = RemoteChannel(invitation: invitation, role: .work)
        workspace = try await RemoteWorkspace(root: root)
        self.provider = provider; self.model = model; self.resume = resume
    }

    func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let context = await workspace.describe()
                try await channel.send(RemoteMessage("workspace", .object([
                    "context": context, "provider": .string(provider.rawValue), "model": model.map(RemoteJSON.string) ?? .null,
                    "resume": .bool(resume), "cols": .int(size.cols), "rows": .int(size.rows)])))
                readyToSend = true
                drain()
                lastHomeMessage = Date()
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        if Date().timeIntervalSince(lastHomeMessage) > 75 {
                            onOutput?(Data("\r\nThe home computer stopped responding. Local command sessions were stopped. Reconnect before continuing.\r\n".utf8))
                            finish(1); return
                        }
                    }
                }
                try await channel.receive { [weak self] message in await self?.receive(message) }
            } catch {
                if !stopped { onOutput?(Data(("\r\nRemote connection: " + error.localizedDescription + "\r\n").utf8)); finish(1) }
            }
        }
    }
    private func receive(_ message: RemoteMessage) async {
        guard !stopped else { return }
        lastHomeMessage = Date()
        switch message.kind {
        case "output":
            if let value = message.payload.string, let data = Data(base64Encoded: value), data.count <= 65536 { onOutput?(data) }
        case "exited": finish(Int32(clamping: message.payload.integer ?? 1))
        case "error":
            onOutput?(Data(("\r\n" + (message.payload.string ?? "Remote session failed.") + "\r\n").utf8)); finish(1)
        case "toolCall":
            guard let name = message.payload["name"].string else { return }
            let result = await workspace.call(id: message.id, name: name, arguments: message.payload["arguments"])
            do { try await channel.send(RemoteMessage("toolResult", result, id: message.id)) }
            catch { onOutput?(Data("\r\nCould not return a workspace tool result. Reconnect before continuing.\r\n".utf8)); finish(1) }
        case "heartbeat": enqueue(RemoteMessage("heartbeat"))
        default: break
        }
    }

    func write(_ text: String) {
        guard !stopped else { return }
        let data = Data(text.utf8)
        for start in stride(from: 0, to: data.count, by: 32768) {
            enqueue(RemoteMessage("input", .string(data.subdata(in: start..<min(start + 32768, data.count)).base64EncodedString())))
        }
    }
    func resize(cols: Int, rows: Int) {
        size = (max(2, min(cols, 1000)), max(2, min(rows, 1000)))
        if task != nil { enqueue(RemoteMessage("resize", .object(["cols": .int(size.cols), "rows": .int(size.rows)]))) }
    }
    private func enqueue(_ message: RemoteMessage) {
        guard !stopped else { return }
        guard outgoing.count < 256 else {
            onOutput?(Data("\r\nThe remote connection cannot keep up with terminal input. Reconnect before continuing.\r\n".utf8))
            finish(1); return
        }
        outgoing.append(message)
        drain()
    }
    private func drain() {
        guard readyToSend, sending == nil, !stopped else { return }
        sending = Task { [weak self] in
            guard let self else { return }
            while !outgoing.isEmpty, !stopped {
                let message = outgoing.removeFirst()
                do { try await channel.send(message) }
                catch { if !stopped { onOutput?(Data(("\r\n" + error.localizedDescription + "\r\n").utf8)); finish(1) }; break }
            }
            sending = nil
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        sending?.cancel(); sending = nil; outgoing.removeAll()
        Task {
            await workspace.close()
            try? await channel.send(RemoteMessage("disconnect"))
            await channel.close()
        }
    }
    private func finish(_ code: Int32) { stop(); onExit?(code) }
}
