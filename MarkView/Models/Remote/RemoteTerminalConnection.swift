import Foundation

@MainActor
final class RemoteTerminalConnection: TerminalConnection {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onState: ((RemoteConnectionState.Phase, String) -> Void)?
    private var channel: RemoteChannel?
    private var workspace: RemoteWorkspace?
    private let invitation: RemoteInvitation
    private let root: URL
    private let browserWindowID: UUID
    private let provider: RemoteProviderConfiguration.Provider
    private let model: String?
    private let resume: Bool
    private let savedConnectionID: UUID?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var readyToSend = false
    private var outgoing: [RemoteMessage] = []
    private var sending: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastHomeMessage = Date()
    private var size = (cols: 120, rows: 30)

    init(invitation: RemoteInvitation, root: URL, browserWindowID: UUID, provider: RemoteProviderConfiguration.Provider,
         model: String?, resume: Bool, savedConnectionID: UUID? = nil) async throws {
        self.invitation = invitation; self.root = root; self.browserWindowID = browserWindowID
        self.provider = provider; self.model = model; self.resume = resume; self.savedConnectionID = savedConnectionID
    }

    func start() {
        guard task == nil, !stopped else { return }
        task = Task { [weak self] in
            guard let self else { return }
            var reset = true, first = true
            while !stopped, !Task.isCancelled {
                let channel = RemoteChannel(invitation: invitation, role: .work)
                self.channel = channel
                do {
                    onState?(.connecting, "Connecting to home Mac…")
                    let root = root, windowID = browserWindowID, provider = provider
                    let workspace = try await RemoteWorkspace(root: root, browserCall: { name, arguments in
                        await BrowserControlServer.performRemoteBrowser(name, arguments: arguments, window: windowID,
                                                                       root: root, agent: provider == .claude ? .claude : .codex)
                    })
                    self.workspace = workspace
                    try await channel.prepareSession(reset: reset)
                    var environment = await workspace.describe().object ?? [:]
                    environment["connectionID"] = .string(invitation.room.uuidString)
                    let context = RemoteJSON.object(environment)
                    try await channel.send(RemoteMessage("workspace", .object([
                        "context": context, "provider": .string(provider.rawValue), "model": model.map(RemoteJSON.string) ?? .null,
                        "resume": .bool(first ? resume : true), "cols": .int(size.cols), "rows": .int(size.rows)])))
                    first = false; readyToSend = true; drain(); lastHomeMessage = Date()
                    onState?(.waiting, "Waiting for home assistant…")
                    watchdog = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 15_000_000_000)
                            guard let self, !Task.isCancelled else { return }
                            if Date().timeIntervalSince(lastHomeMessage) > 75 {
                                onState?(.reconnecting, "Home Mac is offline · reconnecting")
                                await channel.close(); return
                            }
                        }
                    }
                    try await channel.receive { [weak self] message in try await self?.receive(message) }
                    reset = true
                } catch RemoteFailure.sessionChanged { reset = false }
                catch RemoteFailure.expired {
                    onState?(.revoked, "Access was revoked. A new connection code is required.")
                    finish(1); return
                } catch {
                    reset = true
                    if !stopped { onState?(.reconnecting, "Reconnecting · " + error.localizedDescription) }
                }
                await clearTransport()
                guard !stopped, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: reset ? 3_000_000_000 : 100_000_000)
            }
        }
    }

    private func receive(_ message: RemoteMessage) async throws {
        guard !stopped else { return }
        lastHomeMessage = Date()
        onState?(.online, "Connected · " + provider.title)
        switch message.kind {
        case "output":
            if let value = message.payload.string, let data = Data(base64Encoded: value), data.count <= 65536 { onOutput?(data) }
        case "exited":
            onState?(.offline, "The home assistant exited. Use Reconnect to continue.")
            finish(Int32(clamping: message.payload.integer ?? 1))
        case "error":
            onState?(.offline, message.payload.string ?? "Remote session failed.")
            finish(1)
        case "toolCall":
            guard let name = message.payload["name"].string, let workspace, let channel else { return }
            let result = await workspace.call(id: message.id, name: name, arguments: message.payload["arguments"])
            try await channel.send(RemoteMessage("toolResult", result, id: message.id))
        case "heartbeat": enqueue(RemoteMessage("heartbeat"))
        default: break
        }
    }

    func write(_ text: String) {
        guard !stopped, readyToSend else { return }
        let data = Data(text.utf8)
        for start in stride(from: 0, to: data.count, by: 32768) {
            enqueue(RemoteMessage("input", .string(data.subdata(in: start..<min(start + 32768, data.count)).base64EncodedString())))
        }
    }
    func resize(cols: Int, rows: Int) {
        size = (max(2, min(cols, 1000)), max(2, min(rows, 1000)))
        if readyToSend { enqueue(RemoteMessage("resize", .object(["cols": .int(size.cols), "rows": .int(size.rows)]))) }
    }
    private func enqueue(_ message: RemoteMessage) {
        guard !stopped else { return }
        guard outgoing.count < 256 else {
            onState?(.reconnecting, "Remote input paused · reconnecting")
            if let channel { Task { await channel.close() } }; return
        }
        outgoing.append(message); drain()
    }
    private func drain() {
        guard readyToSend, sending == nil, !stopped, let channel else { return }
        sending = Task { [weak self] in
            guard let self else { return }
            while !outgoing.isEmpty, !stopped {
                let message = outgoing.removeFirst()
                do { try await channel.send(message) }
                catch { await channel.close(); break }
            }
            sending = nil
        }
    }
    private func clearTransport() async {
        readyToSend = false
        watchdog?.cancel(); watchdog = nil
        sending?.cancel(); sending = nil; outgoing.removeAll()
        let workspace = workspace, channel = channel
        self.workspace = nil; self.channel = nil
        await workspace?.close(); await channel?.close()
    }
    /// Closing a terminal suspends its session; it does not revoke the saved pairing.
    func stop() {
        guard !stopped else { return }
        onState?(.offline, "Session paused. Use Reconnect to continue.")
        suspend()
        onExit?(130)
    }
    private func suspend() {
        guard !stopped else { return }
        stopped = true; readyToSend = false; task?.cancel(); task = nil
        if let savedConnectionID { RemoteConnectionsStore.shared.connectionStopped(savedConnectionID) }
        Task { await clearTransport() }
    }
    private func finish(_ code: Int32) { suspend(); onExit?(code) }
}
