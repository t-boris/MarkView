import SwiftUI
import WebKit

/// Hosts a session's web view. The view belongs to the session, so it keeps its
/// screen when SwiftUI rebuilds this host (tab or panel switches).
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var theme: WindowTheme
    @Environment(\.appFontScale) private var fontScale

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        applyTheme()
        attach(to: container)
        session.setFontScale(fontScale)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.webView.superview !== container { attach(to: container) }
        applyTheme()
        session.setFontScale(fontScale)
        DispatchQueue.main.async { session.refit() }
    }

    private func applyTheme() {
        session.applyTheme(arguments: theme.webArguments, firstPaint: theme.firstPaintScript)
    }

    private func attach(to container: NSView) {
        let view = session.webView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async {
            applyTheme()
            session.refit()
        }
    }
}

/// Microphone for a terminal: dictated text is typed at the prompt, not sent —
/// check it and press Enter yourself.
struct TerminalDictationButton: View {
    @Environment(\.palette) private var palette
    let session: TerminalSession?

    var body: some View {
        if let session {
            SessionDictationButton(session: session, whisper: session.dictation)
        } else {
            Image(systemName: "mic").uiFont(size: 12).foregroundColor(palette.textDim.opacity(0.5))
        }
    }
}

/// The microphone of one session: the recording lives in the session, so switching tabs or
/// panels keeps it going; the text is typed into the terminal the recording was started for.
private struct SessionDictationButton: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: TerminalSession
    @ObservedObject var whisper: WhisperClient
    /// The last transcript held no words: not an error of the recorder, but the person is told why it may be.
    @State private var nothingHeard: TranscriptionFailure?

    var body: some View {
        Button(action: toggle) {
            Image(systemName: whisper.isRecording ? "mic.fill" : session.transcribing ? "waveform" : "mic")
                .uiFont(size: 12)
                .foregroundColor(whisper.isRecording ? palette.red : palette.textDim)
        }
        .buttonStyle(.plain)
        .disabled(session.transcribing)
        .help(help)
        .popover(isPresented: noticeShown, arrowEdge: .bottom) { notice }
    }

    private var help: String {
        if whisper.isRecording {
            return "Recording" + (whisper.language.map { " in \($0)" } ?? "") + " — click to stop and insert the text"
        }
        return whisper.error ?? "Dictate: the text is typed at the prompt"
    }

    /// A failure or an empty transcript stays in view until it is dismissed: a hover tooltip alone left
    /// "nothing happened" as the only thing to see.
    private var message: String? { whisper.isRecording || session.transcribing ? nil : (whisper.error ?? nothingHeard?.message) }

    private var noticeShown: Binding<Bool> {
        Binding(get: { message != nil },
                set: { if !$0 { whisper.error = nil; nothingHeard = nil } })
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundColor(palette.orange)
                Text(message ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if WhisperClient.microphoneStatus == .denied || WhisperClient.microphoneStatus == .restricted {
                    Button("Open Microphone Settings") { DictationStatusView.openPrivacySettings("Privacy_Microphone") }
                } else if WhisperClient.engine == .onDevice,
                          OnDeviceSpeech.authorization == .denied || OnDeviceSpeech.authorization == .restricted {
                    Button("Open Speech Recognition Settings") { DictationStatusView.openPrivacySettings("Privacy_SpeechRecognition") }
                }
                Spacer(minLength: 0)
                Button("OK") { whisper.error = nil; nothingHeard = nil }
            }
        }
        .uiFont(.caption)
        .padding(12)
        .frame(width: 320)
    }

    private func toggle() {
        if whisper.isRecording {
            session.transcribing = true
            let session = self.session, whisper = self.whisper
            Task {
                let text = await whisper.stopRecording()
                session.transcribing = false
                guard let text else { return } // the failure is in `whisper.error`
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nothingHeard = whisper.nothingHeard
                } else {
                    session.paste(text)
                }
            }
        } else {
            nothingHeard = nil
            whisper.startRecording()
        }
    }
}

/// "Restart" in a terminal header: ends the session (and whatever runs in it) and starts anew.
struct TerminalRestartButton: View {
    @Environment(\.palette) private var palette
    let help: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact { Image(systemName: "arrow.clockwise") }
                else { Label("Restart", systemImage: "arrow.clockwise") }
            }
                .uiFont(size: 10, weight: .medium)
                .foregroundColor(palette.text)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(palette.border.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Restart terminal")
    }
}

struct TerminalStopButton: View {
    @ObservedObject var session: TerminalSession
    var compact = false

    var body: some View {
        if session.isRunning {
            Button { session.terminate() } label: {
                if compact { Image(systemName: "stop.fill") }
                else { Label("Stop", systemImage: "stop.fill") }
            }
                .help("End the terminal process. Files and remote actions are not rolled back.")
                .accessibilityLabel("Stop terminal")
        }
    }
}

/// Shared terminal area: session tabs for assistant CLIs or a plain shell.
struct AITerminalPanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var terminals: AITerminalsController
    /// A folder is open in the window (its terminal root may follow a moment later).
    let folderOpen: Bool
    @Environment(\.appFontScale) private var fontScale
    /// This window's project choice when last seen ("tool|model"): the terminal follows only its own
    /// project's changes, never another window's (BUG-021).
    @State private var seenChoice: (tool: String, model: String)?
    @State private var showRemoteConnections = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 420 * max(1, fontScale)
            VStack(spacing: 0) {
                tabBar(compact: compact)
                AgentActivityBanner(monitor: terminals.activity, terminalID: terminals.shown?.id)
                Divider().background(palette.border)
                if let session = terminals.shown {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.shield")
                        if session.isRemote {
                            Text("Local files and commands").fixedSize()
                            Text(session.directory.path).lineLimit(1).truncationMode(.middle)
                                .help(session.directory.path)
                        } else {
                            Text(compact ? "Unrestricted · \(session.title)" : "Unrestricted · \(session.title) · \(session.directory.path)")
                                .lineLimit(1).truncationMode(.middle)
                                .help(session.directory.path)
                        }
                        Spacer(minLength: 0)
                        if !compact { Text("Changes: review below") }
                    }
                    .uiFont(size: 9).foregroundColor(palette.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(palette.bgSidebar)
                }
                if let session = terminals.shown {
                    TerminalHostView(session: session).id(session.id)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg)
        .sheet(isPresented: $showRemoteConnections) { RemoteConnectionsView(terminals: terminals) }
        .onAppear {
            terminals.ensureAITerminal()
            // This panel exists only while its navigator tab is open, so a model picked in the
            // toolbar meanwhile never reached the observer below: apply it now (a no-op when the
            // shown terminal already runs the chosen model).
            terminals.aiModelChanged()
            seenChoice = currentChoice()
        }
        // At launch the last folder reopens after the panel appeared.
        .onChange(of: terminals.workspaceRoot) { _ in
            terminals.ensureAITerminal()
            seenChoice = currentChoice()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = currentChoice()
            defer { seenChoice = now }
            guard let seen = seenChoice else { return }
            if now.tool != seen.tool { terminals.aiBackendChanged() }
            else if now.model != seen.model { terminals.aiModelChanged() }
        }
    }

    private func currentChoice() -> (tool: String, model: String) {
        let project = terminals.project
        let tool = AIAssistantPreferences.backend(project: project)
        return (tool.rawValue, AIAssistantPreferences.model(for: tool, project: project) ?? "")
    }

    private func tabBar(compact: Bool) -> some View {
        Group {
            if terminals.sessions.count == 1, let session = terminals.sessions.first {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        terminalTab(session, compact: false).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        terminalControls(compact: compact)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        terminalTab(session, compact: false)
                        HStack {
                            Spacer(minLength: 0)
                            terminalControls(compact: compact)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(terminals.sessions) { session in
                                terminalTab(session, compact: compact)
                            }
                        }
                    }
                    terminalControls(compact: compact)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(palette.bgSidebar)
    }

    private func terminalTab(_ session: TerminalSession, compact: Bool) -> some View {
        TerminalPanelTab(session: session, monitor: terminals.activity,
                         compact: compact, isActive: session.id == terminals.shown?.id,
                         select: { terminals.shownID = session.id },
                         close: { terminals.closeAITerminal(session.id) })
    }

    private func terminalControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            newTerminalMenu
            if let session = terminals.shown, session.profile != .shell, !session.isRemote {
                AgentModelMenu(session: session, monitor: terminals.activity) { model in
                    terminals.switchModel(of: session, to: model)
                }
            }
            TerminalDictationButton(session: terminals.shown)
            if let session = terminals.shown { TerminalStopButton(session: session, compact: compact) }
            TerminalRestartButton(help: "Start the shown terminal again (with the model chosen in the toolbar)", compact: compact) {
                terminals.restartAITerminal()
            }
            .disabled(terminals.shown == nil || terminals.shown?.isRemote == true)
        }
        .fixedSize()
    }

    private var newTerminalMenu: some View {
        Menu {
            ForEach(TerminalProfile.allCases) { profile in
                Button { terminals.openAITerminal(profile) } label: { Label(profile.title, systemImage: profile.icon) }
            }
            Divider()
            Button { showRemoteConnections = true } label: { Label("Connect to Home…", systemImage: "network") }
        } label: {
            Image(systemName: "plus").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New terminal: Claude Code, Codex, Cline, Copilot, Antigravity, or shell")
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "terminal").uiFont(size: 26).foregroundColor(palette.textDim)
            if terminals.workspaceRoot == nil && !folderOpen {
                Text("Open a folder to start a terminal").uiFont(size: 11).foregroundColor(palette.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100 * min(fontScale, 1.5)))], spacing: 8) {
                    ForEach(TerminalProfile.allCases) { profile in
                        Button { terminals.openAITerminal(profile) } label: {
                            Label(profile.title, systemImage: profile.icon).uiFont(size: 11)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One terminal in the AI panel's tab bar.
private struct TerminalPanelTab: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: TerminalSession
    let monitor: AgentActivityMonitor
    let compact: Bool
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    /// The tab's name. On a narrow panel "Claude Code" shortens to "Claude", keeping the number and
    /// the model ("Claude 2 · opus"), so the tab still shows what it runs.
    private var label: String {
        let long = "Claude Code"
        guard compact, session.profile == .claude, !session.isRemote, session.title.hasPrefix(long) else { return session.title }
        return "Claude" + session.title.dropFirst(long.count)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: session.profile.icon).uiFont(size: 9).help(session.title)
            Text(label)
                .uiFont(size: 10, weight: isActive ? .semibold : .regular)
                .lineLimit(1)
                .help(session.title)
            if let remote = session.remoteConnectionState {
                Circle().fill(remote.phase == .online ? Color.green : Color.orange).frame(width: 6, height: 6)
                    .help(remote.detail)
                Text(remote.detail).uiFont(size: 9).lineLimit(1).frame(maxWidth: 170).help(remote.detail)
            } else if !session.isRunning {
                Circle().fill(palette.textDim).frame(width: 5, height: 5).help("Exited")
            } else {
                AgentTabDot(monitor: monitor, terminalID: session.id)
            }
            Button(action: close) {
                Image(systemName: "xmark").uiFont(size: 8, weight: .bold)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 1 : 0)
            .help("Close this terminal (ends what runs in it)")
        }
        .foregroundColor(isActive ? palette.text : palette.textDim)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(isActive ? palette.border.opacity(0.7) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// An editor tab showing a terminal opened in a folder.
struct TerminalTabView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").uiFont(size: 10).foregroundColor(palette.textDim)
                Text(session.directory.path).uiFont(size: 10).foregroundColor(palette.textDim)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                TerminalDictationButton(session: session)
                TerminalStopButton(session: session)
                TerminalRestartButton(help: "End this shell and start a new one in the same folder") {
                    session.restart()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(palette.bgSidebar)
            Divider().background(palette.border)
            TerminalHostView(session: session)
        }
        .onAppear { DispatchQueue.main.async { session.focus() } }
    }
}
