import Foundation
import Combine
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The complete saved record, including its pairing secret, lives only in the login Keychain.
struct SavedRemoteConnection: Codable, Identifiable {
    var id = UUID()
    var name: String
    var code: String
    var role: RemoteRole
    var rootPath: String?
    var provider: String?
    var model: String?
    var resume = true
    var revoking = false
}

@MainActor
final class RemoteConnectionsStore: ObservableObject {
    static let shared = RemoteConnectionsStore()
    @Published private(set) var entries: [SavedRemoteConnection] = []
    @Published private(set) var states: [UUID: RemoteConnectionState] = [:]
    @Published private(set) var storageError: String?
    @Published private(set) var isLoading = true
    private let keychain: RemoteRelayKeychain
    private let account = "saved-connections-v1"
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var hosts: [UUID: RemoteHostController] = [:]
    private var connections: [UUID: RemoteTerminalConnection] = [:]
    private var starting: Set<UUID> = []
    private var paused: Set<UUID> = []
    private var revocations: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false
    /// What the Remote Assistants window asked for. It runs here and not in the window: the store lives for the process, and a handshake
    /// on its way does not stop because the window closed. A second request for the same connection replaces the first; quitting ends
    /// the rest (`AR-19`).
    private let requests = TaskBag()

    init(keychain: RemoteRelayKeychain = RemoteRelayKeychain(service: "MarkView saved remote connections." + (Bundle.main.bundleIdentifier ?? "cli"), maxBytes: 1_048_576)) {
        self.keychain = keychain
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await keychain.read(account: account)
                if !value.isEmpty { entries = try JSONDecoder().decode([SavedRemoteConnection].self, from: Data(value.utf8)) }
                isLoading = false
                for entry in entries {
                    if entry.revoking { scheduleRevocation(entry) }
                    else if entry.role == .home { startHost(entry) }
                    else { update(entry.id, .offline, "Open the saved project to reconnect.") }
                }
            } catch { isLoading = false; storageError = error.localizedDescription }
        }
    }

    func ready() async { await loading?.value }
    func finishPendingChanges() async { await loading?.value; await saving?.value }
    func state(_ id: UUID) -> RemoteConnectionState { states[id] ?? .init(phase: .offline, detail: "Not connected") }
    func update(_ id: UUID, _ phase: RemoteConnectionState.Phase, _ detail: String) {
        states[id] = .init(phase: phase, detail: detail, lastSeen: phase == .online ? Date() : states[id]?.lastSeen)
    }

    private func persist() async throws {
        let value = String(data: try JSONEncoder().encode(entries), encoding: .utf8)!
        let previous = saving, keychain = keychain, account = account
        let task = Task { await previous?.value; try await keychain.save(value, account: account) }
        // Order snapshots even when a second connection is added while Keychain is busy.
        saving = Task { _ = try? await task.value }
        do { try await task.value; storageError = nil }
        catch { storageError = error.localizedDescription; throw error }
    }

    func allow(name: String, relay: String) async throws {
        await ready()
        guard storageError == nil else { throw RemoteFailure.invalid(storageError!) }
        guard let url = URL(string: relay.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteFailure.invalid("Enter an HTTPS relay URL.") }
        let invitation = try RemoteInvitation(relay: url, persistent: true)
        let entry = SavedRemoteConnection(name: label(name, fallback: "Work Mac"), code: try invitation.code, role: .home)
        entries.append(entry)
        do { try await persist() } catch { entries.removeAll { $0.id == entry.id }; throw error }
        startHost(entry)
    }

    func connect(name: String, code: String, provider: CLITool, model: String?, resume: Bool,
                 host: any RemoteAssistantHost) async throws {
        await ready()
        guard storageError == nil else { throw RemoteFailure.invalid(storageError!) }
        let invitation = try RemoteInvitation(code: code)
        guard invitation.isPersistent else { throw RemoteFailure.invalid("Create a saved connection code with the updated MarkView on the home Mac first.") }
        guard let root = host.root else { throw RemoteFailure.invalid("Open a project folder first.") }
        guard !entries.contains(where: { (try? RemoteInvitation(code: $0.code).room) == invitation.room }) else {
            throw RemoteFailure.invalid("This connection is already saved. Use its existing row, or create another connection on the home Mac.")
        }
        let entry = SavedRemoteConnection(name: label(name, fallback: "Home Mac"), code: try invitation.code, role: .work,
                                          rootPath: canonical(root.path), provider: provider.rawValue, model: model, resume: resume)
        entries.append(entry)
        do { try await persist() } catch { entries.removeAll { $0.id == entry.id }; throw error }
        try await open(entry, host: host)
    }

    // MARK: Requests of the connections window

    /// Runs `action` as the request `key`; `finished` gets the failure, or nil. A request replaced or cancelled before it starts
    /// is not run and ends with `CancellationError`.
    private func request(_ key: String, finished: @escaping (Error?) -> Void, _ action: @escaping (RemoteConnectionsStore) async throws -> Void) {
        requests.store(Task { [weak self] in
            guard let self, !Task.isCancelled else { return finished(CancellationError()) }
            do { try await action(self); finished(nil) } catch { finished(error) }
        }, for: key)
    }

    /// Allow this Mac to be used from another one (see `allow`).
    func startAllow(name: String, relay: String, finished: @escaping (Error?) -> Void) {
        request("allow", finished: finished) { try await $0.allow(name: name, relay: relay) }
    }

    /// Connect to a home Mac with its code (see `connect`).
    func startConnect(name: String, code: String, provider: CLITool, model: String?, resume: Bool, host: any RemoteAssistantHost,
                      finished: @escaping (Error?) -> Void) {
        request("connect", finished: finished) {
            try await $0.connect(name: name, code: code, provider: provider, model: model, resume: resume, host: host)
        }
    }

    /// Reconnect a saved connection (see `reconnect`).
    func startReconnect(_ entry: SavedRemoteConnection, host: any RemoteAssistantHost, finished: @escaping (Error?) -> Void) {
        request("reconnect:" + entry.id.uuidString, finished: finished) { try await $0.reconnect(entry, host: host) }
    }

    /// Disconnect a saved connection and revoke its access (see `disconnect`).
    func startDisconnect(_ entry: SavedRemoteConnection, finished: @escaping (Error?) -> Void) {
        request("disconnect:" + entry.id.uuidString, finished: finished) { try await $0.disconnect(entry) }
    }

    /// Waits until the relay settings and the saved connections are in the Keychain, then calls `then` (the window's Done button).
    func startSaving(relaySettings: RemoteRelaySettings, then: @escaping () -> Void) {
        requests.store(Task { [weak self] in
            await relaySettings.finishPendingChanges()
            await self?.finishPendingChanges()
            if !Task.isCancelled { then() }
        }, for: "finish")
    }

    func attach(_ host: any RemoteAssistantHost) {
        // task: attaches a window to its saved connections; the store is process-wide and ends them itself when it shuts down
        Task { [weak self, weak host] in
            guard let self else { return }; await ready()
            guard let host, !shuttingDown, let root = host.root else { return }
            for entry in entries where entry.role == .work && !entry.revoking && entry.rootPath.map(canonical) == canonical(root.path) {
                guard connections[entry.id] == nil, !paused.contains(entry.id), !starting.contains(entry.id) else { continue }
                do { try await open(entry, host: host) }
                catch { update(entry.id, .offline, error.localizedDescription) }
            }
        }
    }

    func reconnect(_ entry: SavedRemoteConnection, host: any RemoteAssistantHost) async throws {
        guard !entry.revoking else { return }
        if entry.role == .home { hosts[entry.id]?.suspend(); startHost(entry); return }
        guard entry.rootPath.map(canonical) == host.root.map({ canonical($0.path) }) else {
            throw RemoteFailure.invalid("Open the saved project folder before reconnecting: " + (entry.rootPath ?? ""))
        }
        connections[entry.id]?.stop(); connections[entry.id] = nil
        paused.remove(entry.id)
        try await open(entry, host: host)
    }

    private func open(_ entry: SavedRemoteConnection, host: any RemoteAssistantHost) async throws {
        guard !starting.contains(entry.id), !entry.revoking else { return }
        starting.insert(entry.id); defer { starting.remove(entry.id) }
        let session = try await host.openRemoteAITerminal(code: entry.code,
            provider: RemoteProviderConfiguration.tool(named: entry.provider ?? "") ?? RemoteProviderConfiguration.defaultTool, model: entry.model, resume: entry.resume,
            savedConnectionID: entry.id)
        if let connection = session.connection as? RemoteTerminalConnection { connections[entry.id] = connection }
    }

    private func startHost(_ entry: SavedRemoteConnection) {
        let host = RemoteHostController()
        hosts[entry.id] = host
        host.onState = { [weak self] phase, text in self?.update(entry.id, phase, text) }
        host.start(code: entry.code)
    }

    func disconnect(_ entry: SavedRemoteConnection) async throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].revoking = true
        do { try await persist() } catch { entries[index].revoking = false; throw error }
        // Persist intent before stopping; an offline revocation survives an app restart.
        hosts.removeValue(forKey: entry.id)?.suspend()
        connections.removeValue(forKey: entry.id)?.stop()
        scheduleRevocation(entries[index])
    }

    private func scheduleRevocation(_ entry: SavedRemoteConnection) {
        guard revocations[entry.id] == nil else { return }
        update(entry.id, .revoking, "Revoking access…")
        revocations[entry.id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let invitation = try RemoteInvitation(code: entry.code)
                    let channel = RemoteChannel(invitation: invitation, role: entry.role)
                    do { try await channel.revokeAccess() } catch { await channel.close(); throw error }
                    entries.removeAll { $0.id == entry.id }; states[entry.id] = nil
                    try await persist(); revocations[entry.id] = nil
                    return
                } catch {
                    update(entry.id, .revoking, "Waiting for relay to confirm access is revoked. " + error.localizedDescription)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    func connectionStopped(_ id: UUID) {
        connections[id] = nil; paused.insert(id)
        if state(id).phase != .offline, state(id).phase != .revoking, state(id).phase != .revoked {
            update(id, .offline, "Session paused. Use Reconnect to continue.")
        }
    }
    func suspend() {
        shuttingDown = true
        requests.cancelAll()
        for host in hosts.values { host.suspend() }
        for connection in connections.values { connection.stop() }
        for task in revocations.values { task.cancel() }
    }
    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func label(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(80))
    }
}
