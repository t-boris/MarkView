import SwiftUI
import AppKit

struct RemoteConnectionsView: View {
    @EnvironmentObject var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var host = RemoteHostController.shared
    @AppStorage("remote.relayURL") private var relayURL = ""
    @State private var connectionCode = ""
    @State private var provider = RemoteProviderConfiguration.Provider.claude
    @State private var model = ""
    @State private var resume = true
    @State private var error: String?
    @State private var connecting = false
    @State private var relayAccessKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Remote Assistants").uiFont(.title2, weight: .semibold)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TabView {
                work.padding(12).tabItem { Text("Connect to Home") }
                home.padding(12).tabItem { Text("Allow This Mac") }
            }
            if let error { Text(error).foregroundColor(.red).textSelection(.enabled) }
        }
        .padding(20).frame(width: 610, height: 440)
        .onAppear {
            if AIAssistantPreferences.backend(project: workspace.aiProject) == .codex { provider = .codex }
        }
    }

    private var work: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use your home assistant in the folder open on this Mac.").uiFont(.headline)
            Text("On the home computer, open Allow This Mac and copy its connection code. Both computers must stay awake with MarkView running.")
                .uiFont(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
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
                            _ = try await workspace.openRemoteAITerminal(code: connectionCode, provider: provider,
                                model: model.isEmpty ? nil : model, resume: resume)
                            connectionCode = ""; dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(connecting || connectionCode.isEmpty || (workspace.aiWorkspaceRoot == nil && workspace.rootNode == nil))
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
            TextField("https://relay.example.com", text: $relayURL).textFieldStyle(.roundedBorder).disabled(host.isHosting)
            SecureField("Relay access key", text: $relayAccessKey).textFieldStyle(.roundedBorder).disabled(host.isHosting)
            HStack {
                Button(host.isHosting ? "Stop Hosting" : "Allow Connection") {
                    if host.isHosting { host.stop() } else { host.start(relay: relayURL, accessKey: relayAccessKey) }
                }
                if !host.connectionCode.isEmpty {
                    Button("Copy Connection Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host.connectionCode, forType: .string)
                    }
                }
            }
            Text(host.status).uiFont(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("The code allows one work-computer terminal to connect. Share it only with your other device. Stop Hosting revokes access. Connections expire after eight hours.")
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
