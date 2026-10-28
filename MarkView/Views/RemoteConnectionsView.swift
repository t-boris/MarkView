import SwiftUI
import AppKit

struct RemoteConnectionsView: View {
    private enum ConnectionMode: Hashable { case work, home }
    @EnvironmentObject var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connections = RemoteConnectionsStore.shared
    @ObservedObject private var relaySettings = RemoteRelaySettings.shared
    @State private var connectionName = ""
    @State private var connectionCode = ""
    @State private var provider = RemoteProviderConfiguration.Provider.claude
    @State private var model = ""
    @State private var resume = true
    @State private var error: String?
    @State private var connecting = false
    @State private var connectionMode = ConnectionMode.work

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Remote Assistants").uiFont(.title2, weight: .semibold)
                Spacer()
                Button("Done") {
                    Task { await relaySettings.finishPendingChanges(); await connections.finishPendingChanges(); dismiss() }
                }.keyboardShortcut(.cancelAction)
            }
            Picker("Connection direction", selection: $connectionMode) {
                Text("Connect to Home").tag(ConnectionMode.work)
                Text("Allow This Mac").tag(ConnectionMode.home)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Group {
                    VStack(alignment: .leading, spacing: 16) {
                        savedConnections
                        if connectionMode == .work { work } else { home }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            if let error { Text(error).foregroundColor(.red).textSelection(.enabled) }
        }
        .padding(20).frame(width: 680, height: 600)
        .onAppear {
            if AIAssistantPreferences.backend(project: workspace.aiProject) == .codex { provider = .codex }
        }
    }

    private var savedConnections: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connections.isLoading { ProgressView("Loading saved connections…") }
            if let storageError = connections.storageError { Text(storageError).foregroundColor(.red) }
            ForEach(connections.entries.filter { $0.role == (connectionMode == .work ? .work : .home) }) { entry in
                let state = connections.state(entry.id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(state.phase == .online ? Color.green : state.phase == .waiting ? Color.blue : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(entry.name).uiFont(.headline)
                        Spacer()
                        if entry.role == .home, !entry.revoking, state.phase == .waiting || state.phase == .online {
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.code, forType: .string)
                            }
                        }
                        if state.phase == .offline, !entry.revoking {
                            Button("Reconnect") {
                                Task {
                                    do { try await connections.reconnect(entry, workspace: workspace) }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                        Button(entry.revoking ? "Revoking…" : "Disconnect Access") {
                            Task {
                                do { try await connections.disconnect(entry) }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(entry.revoking)
                    }
                    Text(state.detail).uiFont(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let root = entry.rootPath { Text(root).uiFont(.caption).lineLimit(1).truncationMode(.middle) }
                    if let seen = state.lastSeen {
                        HStack(spacing: 4) { Text("Last response:"); Text(seen, style: .relative) }.uiFont(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(10).background(Color.secondary.opacity(0.08)).cornerRadius(8)
            }
            if !connections.entries.isEmpty { Divider() }
        }
    }

    private var work: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use your home assistant in the folder open on this Mac.").uiFont(.headline)
            Text("On the home computer, open Allow This Mac and copy its connection code. The connection is saved on this Mac and reconnects automatically when this project opens.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Connection name (for example, Home Mac)", text: $connectionName).textFieldStyle(.roundedBorder)
            SecureField("Connection code", text: $connectionCode).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Assistant", selection: $provider) {
                    ForEach(RemoteProviderConfiguration.Provider.allCases) { Text($0.title).tag($0) }
                }.frame(width: 230)
                TextField("Model (home default if empty)", text: $model).textFieldStyle(.roundedBorder)
            }
            Toggle("Continue the last home conversation for this folder", isOn: $resume)
            Text("Files, Git, builds and commands run on this Mac as your user. The assistant receives file contents through your home computer and uses its existing login.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(workspace.aiWorkspaceRoot?.path ?? workspace.rootNode?.url.path ?? "Open a folder first")
                    .uiFont(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(connecting ? "Connecting…" : "Connect") {
                    connecting = true; error = nil
                    Task {
                        defer { connecting = false }
                        do {
                            try await connections.connect(name: connectionName, code: connectionCode, provider: provider,
                                model: model.isEmpty ? nil : model, resume: resume, workspace: workspace)
                            connectionCode = ""; connectionName = ""
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(connections.isLoading || connecting || connectionCode.isEmpty || (workspace.aiWorkspaceRoot == nil && workspace.rootNode == nil))
                .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let your work computer use this Mac’s assistant.").uiFont(.headline)
            Text("Claude Code or Codex must already be installed and signed in on this Mac. Enter the HTTPS address of your MarkView relay.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://relay.example.com", text: $relaySettings.relayURL).textFieldStyle(.roundedBorder)
            SecureField("Relay access key", text: Binding(get: { relaySettings.accessKey }, set: { relaySettings.setAccessKey($0) }))
                .textFieldStyle(.roundedBorder)
                .disabled(relaySettings.isLoading || (try? RemoteRelayKeychain.account(for: relaySettings.relayURL)) == nil)
            if let message = relaySettings.storageError {
                Text(message).uiFont(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            } else if let status = relaySettings.storageStatus {
                Text(status).uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Connection name (for example, Work Mac)", text: $connectionName).textFieldStyle(.roundedBorder)
            Button(connecting ? "Saving…" : "Add Connection") {
                connecting = true; error = nil
                Task {
                    defer { connecting = false }
                    do {
                        try await connections.allow(name: connectionName, relay: relaySettings.relayURL)
                        connectionName = ""
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(connections.isLoading || connecting || relaySettings.isLoading)
            Text("Each named connection has its own code. Copy it once to your other Mac. Saved access stays available until Disconnect Access is confirmed by the relay; sleep, network interruptions and app restarts do not require another code. Both Macs need MarkView running to use an assistant.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct RemoteSettingsSection: View {
    @State private var showConnections = false
    var body: some View {
        GroupBox("Remote Assistants") {
            HStack {
                Text("Use a home Claude Code or Codex session with this Mac’s files and commands.")
                    .uiFont(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Connections…") { showConnections = true }
            }.padding(8)
        }
        .sheet(isPresented: $showConnections) { RemoteConnectionsView() }
    }
}
