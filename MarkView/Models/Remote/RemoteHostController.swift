import Foundation
import Combine

/// App-lifetime home endpoint. Hosting is explicitly enabled by the person and lasts only until
/// Stop, app exit or connection failure. An invitation controls one work-computer terminal.
@MainActor
final class RemoteHostController: ObservableObject {
    static let shared = RemoteHostController()
    @Published private(set) var status = "Remote access is off."
    @Published private(set) var connectionCode = ""
    @Published private(set) var isHosting = false
    private var channel: RemoteChannel?
    private var requests: RemoteToolRequests?
    private var bridge: RemoteToolBridge?
    private var terminal: TerminalSession?
    private var task: Task<Void, Never>?
    private var lastPeerMessage = Date()
    private var heartbeat: Task<Void, Never>?
    private var outputBuffer = Data()
    private var outputTask: Task<Void, Never>?

    func start(relay: String, accessKey: String = "") {
        guard !isHosting else { return }
        do {
            guard let url = URL(string: relay.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteFailure.invalid("Enter an HTTPS relay URL.") }
            let invitation = try RemoteInvitation(relay: url)
            let channel = RemoteChannel(invitation: invitation, role: .home)
            self.channel = channel; requests = RemoteToolRequests(channel: channel)
            isHosting = true; status = "Connecting to relay…"
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await channel.register(accessKey: accessKey)
                    connectionCode = try invitation.code
                    status = "Waiting for your work computer."
                    try await channel.receive { [weak self] message in try await self?.receive(message) }
                } catch {
                    if !Task.isCancelled { stop(message: error.localizedDescription) }
                }
            }
        } catch { status = error.localizedDescription }
    }

    private func receive(_ message: RemoteMessage) async throws {
        lastPeerMessage = Date()
        switch message.kind {
        case "workspace":
            guard terminal == nil else { return }
            do { try await openTerminal(message.payload) }
            catch {
                status = error.localizedDescription
                try await channel?.send(RemoteMessage("error", .string(error.localizedDescription)))
            }
        case "input":
            if let text = message.payload.string, let data = Data(base64Encoded: text), data.count <= 65536 { terminal?.writeBytesForConnection(data) }
        case "resize":
            terminal?.resizeForConnection(cols: message.payload["cols"].integer ?? 120, rows: message.payload["rows"].integer ?? 30)
        case "toolResult": await requests?.finish(message.id, result: message.payload)
        case "heartbeat": break
        case "disconnect": stop(message: "The work computer disconnected.")
        default: break
        }
    }

    private func openTerminal(_ payload: RemoteJSON) async throws {
        guard let providerName = payload["provider"].string,
              let provider = RemoteProviderConfiguration.Provider(rawValue: providerName),
              let tool = CLITool(rawValue: providerName), let requests, let channel,
              let app = Bundle.main.executablePath else { throw RemoteFailure.invalid("Unsupported remote assistant.") }
        let context = payload["context"]
        let cwd = try context.requiredString("cwd", limit: 8192)
        let hostname = try context.requiredString("hostname", limit: 1024)
        let deviceID = try context.requiredString("deviceID", limit: 128)
        guard UUID(uuidString: deviceID) != nil else { throw RemoteFailure.invalid("Invalid work-computer identity.") }
        let prepared = try await Task.detached { () async throws -> (URL, RemoteToolBridge, String) in
            guard let executable = await CLIToolLocator.resolveThorough(tool) else {
                throw RemoteFailure.invalid("Install and sign in to \(provider.title) on the home computer, then reconnect.")
            }
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MarkView/RemoteWorkspaces", isDirectory: true)
                .appendingPathComponent(String(ContentHash.of(deviceID + "\n" + cwd + "\n" + providerName).prefix(24)), isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let bridge = try RemoteToolBridge { id, name, arguments in await requests.call(id: id, name: name, arguments: arguments) }
            let resume = payload["resume"].bool == true && (provider == .codex || AgentModelProbe.hasClaudeSession(cwd: root))
            let command = try RemoteProviderConfiguration.command(provider: provider, executable: executable, app: app,
                socket: bridge.path, context: context, directory: root, model: payload["model"].string, resume: resume)
            return (root, bridge, command)
        }.value
        guard isHosting, self.channel === channel else { prepared.1.stop(); throw RemoteFailure.disconnected }
        self.bridge = prepared.1
        let terminal = TerminalSession(directory: prepared.0, profile: TerminalProfile(tool), title: "Remote · " + provider.title, operationCommand: prepared.2)
        self.terminal = terminal
        terminal.onOutput = { [weak self] data in
            self?.sendOutput(data, channel: channel)
        }
        terminal.onExit = { [weak self] code in
            let drain = self?.outputTask
            Task { await drain?.value; try? await channel.send(RemoteMessage("exited", .int(Int(code)))) }
            self?.status = "\(provider.title) exited (\(code)). Stop hosting to revoke the connection."
        }
        terminal.onLaunchFailure = { [weak self] _ in self?.stop(message: "Could not start the home assistant.") }
        terminal.resizeForConnection(cols: payload["cols"].integer ?? 120, rows: payload["rows"].integer ?? 30)
        terminal.start()
        status = "\(provider.title) connected to \(hostname) · \(cwd)"
        lastPeerMessage = Date()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(lastPeerMessage) > 75 { stop(message: "The work computer stopped responding."); return }
                try? await channel.send(RemoteMessage("heartbeat"))
            }
        }
    }

    private func sendOutput(_ data: Data, channel: RemoteChannel) {
        outputBuffer.append(data)
        guard outputBuffer.count <= 8 * 1024 * 1024 else { stop(message: "The remote terminal cannot keep up. Reconnect before continuing."); return }
        guard outputTask == nil else { return }
        outputTask = Task { [weak self] in
            guard let self else { return }
            while !outputBuffer.isEmpty, !Task.isCancelled {
                let chunk = Data(outputBuffer.prefix(32768)); outputBuffer.removeFirst(chunk.count)
                do { try await channel.send(RemoteMessage("output", .string(chunk.base64EncodedString()))) }
                catch { stop(message: "Could not deliver terminal output. Reconnect before continuing."); return }
            }
            outputTask = nil
        }
    }

    func stop(message: String = "Remote access is off.") {
        heartbeat?.cancel(); heartbeat = nil
        outputTask?.cancel(); outputTask = nil; outputBuffer.removeAll()
        task?.cancel(); task = nil
        terminal?.onOutput = nil; terminal?.onExit = nil; terminal?.terminate(); terminal = nil
        bridge?.stop(); bridge = nil
        if let requests { Task { await requests.close() } }; requests = nil
        if let channel { Task { await channel.revoke() } }; channel = nil
        connectionCode = ""; isHosting = false; status = message
    }
}
