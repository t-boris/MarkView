import Foundation
import Combine

/// App-lifetime home endpoint. Hosting is explicitly enabled by the person and lasts only until
/// explicit revocation. Transport sessions can restart without replacing the saved pairing.
@MainActor
final class RemoteHostController: ObservableObject {
    var onState: ((RemoteConnectionState.Phase, String) -> Void)?
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

    func start(code: String) {
        guard !isHosting else { return }
        do {
            let invitation = try RemoteInvitation(code: code)
            connectionCode = code; isHosting = true
            task = Task { [weak self] in
                guard let self else { return }
                var reset = true
                while isHosting, !Task.isCancelled {
                    let channel = RemoteChannel(invitation: invitation, role: .home)
                    self.channel = channel; requests = RemoteToolRequests(channel: channel)
                    do {
                        setState(.connecting, "Connecting to relay…")
                        let settings = RemoteRelaySettings.shared
                        await settings.finishPendingChanges()
                        let sameRelay = (try? RemoteRelayKeychain.account(for: settings.relayURL)) == (try? RemoteRelayKeychain.account(for: invitation.relay.absoluteString))
                        do { try await channel.prepareSession(reset: reset) }
                        catch RemoteFailure.expired {
                            try await channel.register(accessKey: sameRelay ? settings.accessKey : "")
                            try await channel.prepareSession(reset: reset)
                        }
                        setState(.waiting, "Available · waiting for your work Mac")
                        lastPeerMessage = Date()
                        startHeartbeat(channel)
                        try await channel.receive { [weak self] message in try await self?.receive(message) }
                        reset = true
                    } catch RemoteFailure.sessionChanged { reset = false }
                    catch RemoteFailure.expired {
                        setState(.revoked, "Access was revoked. Create a new connection code.")
                        await clearTransport(); isHosting = false; return
                    } catch {
                        reset = true
                        if !Task.isCancelled { setState(.reconnecting, "Reconnecting · " + error.localizedDescription) }
                    }
                    await clearTransport()
                    guard isHosting, !Task.isCancelled else { return }
                    try? await Task.sleep(nanoseconds: reset ? 3_000_000_000 : 100_000_000)
                }
            }
        } catch { setState(.offline, error.localizedDescription) }
    }

    private func setState(_ phase: RemoteConnectionState.Phase, _ text: String) {
        status = text; onState?(phase, text)
    }

    private func startHeartbeat(_ channel: RemoteChannel) {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if terminal != nil, Date().timeIntervalSince(lastPeerMessage) > 75 {
                    setState(.reconnecting, "Work Mac is offline · reconnecting")
                    await channel.close(); return
                }
                guard terminal != nil else { continue }
                do { try await channel.send(RemoteMessage("heartbeat")) }
                catch { await channel.close(); return }
            }
        }
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
        case "heartbeat":
            if terminal != nil { setState(.online, status) }
        case "disconnect": await channel?.close()
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
                .appendingPathComponent(String(ContentHash.of(deviceID + "\n" + cwd + "\n" + providerName + "\n" + (context["connectionID"].string ?? "")).prefix(24)), isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let bridge = try RemoteToolBridge { id, name, arguments in await requests.call(id: id, name: name, arguments: arguments) }
            do {
                var resume = payload["resume"].bool == true && (provider == .codex || AgentModelProbe.hasClaudeSession(cwd: root))
                let threadID: String?
                if provider == .codex, resume {
                    threadID = try await RemoteCodexContext.prepare(executable: executable, directory: root, context: context)
                    resume = threadID != nil
                } else { threadID = nil }
                let command = try RemoteProviderConfiguration.command(provider: provider, executable: executable, app: app,
                    socket: bridge.path, context: context, directory: root, model: payload["model"].string,
                    resume: resume, resumeThreadID: threadID)
                return (root, bridge, command)
            } catch { bridge.stop(); throw error }
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
            self?.setState(.offline, "\(provider.title) exited (\(code)). Reconnect to continue the saved connection.")
        }
        terminal.onLaunchFailure = { [weak self] _ in
            self?.setState(.reconnecting, "Could not start the home assistant.")
            Task { await channel.close() }
        }
        terminal.resizeForConnection(cols: payload["cols"].integer ?? 120, rows: payload["rows"].integer ?? 30)
        terminal.start()
        setState(.online, "\(provider.title) connected to \(hostname) · \(cwd)")
        lastPeerMessage = Date()
    }

    private func sendOutput(_ data: Data, channel: RemoteChannel) {
        outputBuffer.append(data)
        guard outputBuffer.count <= 8 * 1024 * 1024 else { setState(.reconnecting, "Remote terminal paused · reconnecting"); Task { await channel.close() }; return }
        guard outputTask == nil else { return }
        outputTask = Task { [weak self] in
            guard let self else { return }
            while !outputBuffer.isEmpty, !Task.isCancelled {
                let chunk = Data(outputBuffer.prefix(32768)); outputBuffer.removeFirst(chunk.count)
                do { try await channel.send(RemoteMessage("output", .string(chunk.base64EncodedString()))) }
                catch { setState(.reconnecting, "Could not deliver terminal output · reconnecting"); await channel.close(); return }
            }
            outputTask = nil
        }
    }

    private func clearTransport() async {
        heartbeat?.cancel(); heartbeat = nil
        outputTask?.cancel(); outputTask = nil; outputBuffer.removeAll()
        terminal?.onOutput = nil; terminal?.onExit = nil; terminal?.terminate(); terminal = nil
        bridge?.stop(); bridge = nil
        if let requests { await requests.close() }; requests = nil
        if let channel { await channel.close() }; channel = nil
    }

    /// App exit and temporary failures preserve the saved pairing. Only the store revokes access.
    func suspend() {
        isHosting = false; task?.cancel(); task = nil
        Task { await clearTransport() }
    }
}
