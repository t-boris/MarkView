import Foundation

// Runtime dependencies are inert here: this check exercises the production store and real Keychain.
@MainActor final class RemoteHostController {
    var onState: ((RemoteConnectionState.Phase, String) -> Void)?
    func start(code: String) { onState?(.waiting, "Test host available") }
    func suspend() {}
}
@MainActor final class RemoteTerminalConnection { func stop() {} }
@MainActor final class TerminalSession { var connection: AnyObject? = RemoteTerminalConnection() }
enum RemoteProviderConfiguration { enum Provider: String { case claude, codex } }
@MainActor final class WorkspaceManager {
    var aiWorkspaceRoot: URL?
    var rootNode: Node?
    var opens = 0
    struct Node { var url: URL }
    func openRemoteAITerminal(code: String, provider: RemoteProviderConfiguration.Provider, model: String?, resume: Bool,
                              savedConnectionID: UUID? = nil) async throws -> TerminalSession { opens += 1; return TerminalSession() }
}

@main enum SavedRemoteConnectionsTests {
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
        let workspace = WorkspaceManager(); workspace.aiWorkspaceRoot = root
        let invitation = try RemoteInvitation(relay: URL(string: "http://127.0.0.1:16394")!, persistent: true)
        try await store.connect(name: "Home Mac", code: invitation.code, provider: .codex, model: "test-model", resume: true, workspace: workspace)
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
        workspace.aiWorkspaceRoot = URL(fileURLWithPath: "/private" + root.path)
        reopened.attach(workspace)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(workspace.opens == 2, "Reopening the app must restore the saved project connection across /tmp and /private/tmp aliases")
        let wrong = WorkspaceManager(); wrong.aiWorkspaceRoot = URL(fileURLWithPath: "/tmp/wrong-project")
        reopened.attach(wrong)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(wrong.opens == 0)
        reopened.suspend()
        print("PASS: Session close pauses; app restart reconnects only to the saved project")
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
