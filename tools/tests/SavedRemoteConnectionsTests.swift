import Foundation

// Runtime dependencies are inert here: this check exercises the production store and real Keychain.
@MainActor final class RemoteHostController {
    var onState: ((RemoteConnectionState.Phase, String) -> Void)?
    func start(code: String) { onState?(.waiting, "Test host available") }
    func suspend() {}
}
@MainActor final class RemoteTerminalConnection { func stop() {} }
@MainActor final class TerminalSession { var connection: AnyObject? = RemoteTerminalConnection() }
enum RemoteProviderConfiguration {
    static var defaultTool: CLITool { CLITool.allCases[0] }
    static func tool(named name: String) -> CLITool? { CLITool(rawValue: name) }
}
/// A window's terminals as the store sees them: a root folder, and a home assistant to open.
@MainActor final class StubHost: RemoteAssistantHost {
    var root: URL?
    var opens = 0
    func openRemoteAITerminal(code: String, provider: CLITool, model: String?, resume: Bool,
                              savedConnectionID: UUID? = nil) async throws -> TerminalSession { opens += 1; return TerminalSession() }
}

@main enum SavedRemoteConnectionsTests {
    /// Waits for the one answer a `start...` request gives.
    @MainActor static func answer(_ start: (@escaping (Error?) -> Void) -> Void) async -> Error? {
        await withCheckedContinuation { continuation in start { continuation.resume(returning: $0) } }
    }

    /// The requests of the Remote Assistants window run in the store: they start, a second one for the same connection replaces the
    /// first, a failure is reported, and quitting cancels what is left.
    @MainActor static func requestsOfTheWindow(_ store: RemoteConnectionsStore, keychain: RemoteRelayKeychain, workspace: StubHost) async throws {
        let before = store.entries.count
        let allowed = await answer { store.startAllow(name: "Started", relay: "http://127.0.0.1:16394", finished: $0) }
        precondition(allowed == nil && store.entries.count == before + 1 && store.entries.last?.name == "Started", "startAllow adds the connection and reports success")
        let failed = await answer { store.startAllow(name: "No relay", relay: "", finished: $0) }
        precondition(failed != nil && store.entries.count == before + 1, "a failing request reports its reason and changes nothing")

        // Reconnect: a second request for the same connection replaces the first, which is told it was cancelled and does not run.
        let work = store.entries.first { $0.role == .work }!
        let opens = workspace.opens
        var answers: [Error?] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for _ in 0..<2 {
                store.startReconnect(work, host: workspace) { answers.append($0); if answers.count == 2 { done.resume() } }
            }
        }
        precondition(answers.count == 2 && answers[0] is CancellationError && answers[1] == nil, "the replaced reconnect is cancelled, the second one runs: \(answers)")
        precondition(workspace.opens == opens + 1, "two reconnects at once open the assistant once: \(workspace.opens - opens)")

        // The window's Done button waits for the Keychain writes, then calls back; quitting cancels one that is still waiting.
        let defaults = UserDefaults(suiteName: "saved-remote-tests-" + UUID().uuidString)!
        let relay = RemoteRelaySettings(defaults: defaults, keychain: RemoteRelayKeychain(service: "MarkView saved connection tests relay " + UUID().uuidString))
        let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.startSaving(relaySettings: relay) { continuation.resume(returning: true) }
        }
        precondition(saved, "startSaving calls back when everything is written")
        var called = false
        store.startSaving(relaySettings: relay) { called = true }
        store.suspend()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!called, "quitting cancels a Done that is waiting")
        print("PASS: The window's requests run in the store: start, replace, failure and quit")
    }

    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let service = args.count > 2 ? args[2] : "MarkView saved connection tests " + UUID().uuidString
        let keychain = RemoteRelayKeychain(service: service, maxBytes: 1_048_576)
        if args.contains("--clear") { try await keychain.save("", account: "saved-connections-v1"); return }
        let store = RemoteConnectionsStore(keychain: keychain)
        await store.ready()
        if args.contains("--restore") {
            precondition(store.entries.count == 3 && store.entries.filter { $0.role == .home }.count == 2)
            precondition(store.entries.first?.name == "Office Mac")
            print("PASS: Separate process restored multiple named connections from Keychain")
            store.suspend(); return
        }
        defer { store.suspend() }
        try await store.allow(name: "Office Mac", relay: "http://127.0.0.1:16394")
        try await store.allow(name: "Laptop", relay: "http://127.0.0.1:16394")
        let root = URL(fileURLWithPath: "/tmp/mv-saved-project-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StubHost(); workspace.root = root
        let invitation = try RemoteInvitation(relay: URL(string: "http://127.0.0.1:16394")!, persistent: true)
        try await store.connect(name: "Home Mac", code: invitation.code, provider: CLITool(rawValue: "codex")!, model: "test-model", resume: true, host: workspace)
        precondition(store.entries.count == 3 && workspace.opens == 1)
        let firstRoom = try RemoteInvitation(code: store.entries[0].code).room
        let secondRoom = try RemoteInvitation(code: store.entries[1].code).room
        precondition(firstRoom != secondRoom, "Multiple host connections must have independent secrets/rooms")
        let data = try await keychain.read(account: "saved-connections-v1")
        precondition(data.contains("Office Mac") && data.contains("Home Mac"))
        print("PASS: Multiple home/work connections persist names, project and provider with independent codes")
        let child = Process(); child.executableURL = URL(fileURLWithPath: args[0]); child.arguments = ["--restore", service]
        try child.run()
        while child.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(child.terminationStatus == 0)
        let workEntry = store.entries.last!
        store.connectionStopped(workEntry.id)
        store.attach(workspace)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(workspace.opens == 1, "Closing a terminal must not immediately reopen it")
        let reopened = RemoteConnectionsStore(keychain: keychain); await reopened.ready()
        workspace.root = URL(fileURLWithPath: "/private" + root.path)
        reopened.attach(workspace)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(workspace.opens == 2, "Reopening the app must restore the saved project connection across /tmp and /private/tmp aliases")
        let wrong = StubHost(); wrong.root = URL(fileURLWithPath: "/tmp/wrong-project")
        reopened.attach(wrong)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(wrong.opens == 0)
        reopened.suspend()
        print("PASS: Session close pauses; app restart reconnects only to the saved project")
        try await requestsOfTheWindow(store, keychain: keychain, workspace: workspace)
        try await store.disconnect(store.entries[0])
        let pending = try JSONDecoder().decode([SavedRemoteConnection].self, from: Data(try await keychain.read(account: "saved-connections-v1").utf8))
        precondition(pending.first?.revoking == true, "Offline revocation intent must persist before transport stops")
        store.suspend()
        let pendingStore = RemoteConnectionsStore(keychain: keychain); await pendingStore.ready()
        precondition(pendingStore.state(pending[0].id).phase == .revoking)
        pendingStore.suspend()
        try await keychain.save("", account: "saved-connections-v1")
        print("PASS: Offline revocation survives restart and is never silently re-enabled; test Keychain item removed")
    }
}
