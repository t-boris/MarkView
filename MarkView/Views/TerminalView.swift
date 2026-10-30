import SwiftUI
import WebKit

/// Hosts a session's web view. The view belongs to the session, so it keeps its
/// screen when SwiftUI rebuilds this host (tab or panel switches).
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @Environment(\.appFontScale) private var fontScale

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        session.setFontScale(fontScale)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.webView.superview !== container { attach(to: container) }
        session.setFontScale(fontScale)
        DispatchQueue.main.async { session.refit() }
    }

    private func attach(to container: NSView) {
        let view = session.webView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async {
            session.applyTheme()
            session.refit()
        }
    }
}

/// Microphone for a terminal: dictated text (Whisper) is typed at the prompt, not sent —
/// check it and press Enter yourself.
struct TerminalDictationButton: View {
    let session: TerminalSession?

    var body: some View {
        if let session {
            SessionDictationButton(session: session, whisper: session.dictation)
        } else {
            Image(systemName: "mic").uiFont(size: 12).foregroundColor(VSDark.textDim.opacity(0.5))
        }
    }
}

/// The microphone of one session: the recording lives in the session, so switching tabs or
/// panels keeps it going; the text is typed into the terminal the recording was started for.
private struct SessionDictationButton: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var whisper: WhisperClient
    @State private var message: String?

    var body: some View {
        Button(action: toggle) {
            Image(systemName: whisper.isRecording ? "mic.fill" : session.transcribing ? "waveform" : "mic")
                .uiFont(size: 12)
                .foregroundColor(whisper.isRecording ? VSDark.red : VSDark.textDim)
        }
        .buttonStyle(.plain)
        .disabled(session.transcribing)
        .help(message ?? whisper.error ?? (whisper.isRecording ? "Stop and insert the text" : "Dictate (Whisper): the text is typed at the prompt"))
    }

    private func toggle() {
        if whisper.isRecording {
            session.transcribing = true
            let session = self.session, whisper = self.whisper
            Task {
                let text = await whisper.stopRecording()
                session.transcribing = false
                if let text, !text.isEmpty { session.paste(text) }
            }
        } else if !whisper.hasAPIKey {
            message = "Dictation needs an OpenAI API key in Settings → DDE."
        } else {
            message = nil
            whisper.startRecording()
        }
    }
}

/// "Restart" in a terminal header: ends the session (and whatever runs in it) and starts anew.
struct TerminalRestartButton: View {
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
                .foregroundColor(VSDark.text)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(VSDark.border.opacity(0.6)))
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

/// Shared terminal area: session tabs for assistant CLIs or a plain shell,
/// with buttons that hand a ready-made prompt to the assistant.
struct AITerminalPanel: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.appFontScale) private var fontScale
    /// This window's project choice when last seen ("tool|model"): the terminal follows only its own
    /// project's changes, never another window's (BUG-021).
    @State private var seenChoice: (tool: String, model: String)?
    @State private var showRemoteConnections = false
    @AppStorage("layout.terminalPromptsExpanded.v3") private var promptsExpanded = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 420 * max(1, fontScale)
            VStack(spacing: 0) {
                tabBar(compact: compact)
                AgentActivityBanner(monitor: workspaceManager.agentActivity, terminalID: workspaceManager.aiTerminal?.id)
                Divider().background(VSDark.border)
                if let session = workspaceManager.aiTerminal {
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
                    .uiFont(size: 9).foregroundColor(VSDark.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(VSDark.bgSidebar)
                }
                if workspaceManager.aiWorkspaceRoot != nil || workspaceManager.rootNode != nil {
                    TerminalPromptBar(expanded: $promptsExpanded)
                    Divider().background(VSDark.border)
                }
                if let session = workspaceManager.aiTerminal {
                    TerminalHostView(session: session).id(session.id)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VSDark.bg)
        .sheet(isPresented: $showRemoteConnections) { RemoteConnectionsView() }
        .onAppear {
            workspaceManager.ensureAITerminal()
            seenChoice = currentChoice()
        }
        // At launch the last folder reopens after the panel appeared.
        .onChange(of: workspaceManager.aiWorkspaceRoot) { _ in
            workspaceManager.ensureAITerminal()
            seenChoice = currentChoice()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = currentChoice()
            defer { seenChoice = now }
            guard let seen = seenChoice else { return }
            if now.tool != seen.tool { workspaceManager.aiBackendChanged() }
            else if now.model != seen.model { workspaceManager.aiModelChanged() }
        }
    }

    private func currentChoice() -> (tool: String, model: String) {
        let project = workspaceManager.aiProject
        let tool = AIAssistantPreferences.backend(project: project)
        return (tool.rawValue, AIAssistantPreferences.model(for: tool, project: project) ?? "")
    }

    private func tabBar(compact: Bool) -> some View {
        Group {
            if workspaceManager.aiTerminals.count == 1, let session = workspaceManager.aiTerminals.first {
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
                            ForEach(workspaceManager.aiTerminals) { session in
                                terminalTab(session, compact: compact)
                            }
                        }
                    }
                    terminalControls(compact: compact)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(VSDark.bgSidebar)
    }

    private func terminalTab(_ session: TerminalSession, compact: Bool) -> some View {
        TerminalPanelTab(session: session, monitor: workspaceManager.agentActivity,
                         compact: compact, isActive: session.id == workspaceManager.aiTerminal?.id,
                         select: { workspaceManager.activeAITerminalID = session.id },
                         close: { workspaceManager.closeAITerminal(session.id) })
    }

    private func terminalControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            newTerminalMenu
            TerminalDictationButton(session: workspaceManager.aiTerminal)
            if let session = workspaceManager.aiTerminal { TerminalStopButton(session: session, compact: compact) }
            TerminalRestartButton(help: "Start the shown terminal again (with the model chosen in the toolbar)", compact: compact) {
                workspaceManager.restartAITerminal()
            }
            .disabled(workspaceManager.aiTerminal == nil || workspaceManager.aiTerminal?.isRemote == true)
        }
        .fixedSize()
    }

    private var newTerminalMenu: some View {
        Menu {
            ForEach(TerminalProfile.allCases) { profile in
                Button { workspaceManager.openAITerminal(profile) } label: { Label(profile.title, systemImage: profile.icon) }
            }
            Divider()
            Button { showRemoteConnections = true } label: { Label("Connect to Home…", systemImage: "network") }
        } label: {
            Image(systemName: "plus").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.textDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New terminal: Claude Code, Codex, Cline, Copilot, Antigravity, or shell")
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "terminal").uiFont(size: 26).foregroundColor(VSDark.textDim)
            if workspaceManager.aiWorkspaceRoot == nil && workspaceManager.rootNode == nil {
                Text("Open a folder to start a terminal").uiFont(size: 11).foregroundColor(VSDark.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100 * min(fontScale, 1.5)))], spacing: 8) {
                    ForEach(TerminalProfile.allCases) { profile in
                        Button { workspaceManager.openAITerminal(profile) } label: {
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
    @ObservedObject var session: TerminalSession
    let monitor: AgentActivityMonitor
    let compact: Bool
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: session.profile.icon).uiFont(size: 9).help(session.title)
            Text(compact && session.profile == .claude && !session.isRemote ? "Claude" : session.title)
                .uiFont(size: 10, weight: isActive ? .semibold : .regular)
                .lineLimit(1)
                .help(session.title)
            if let remote = session.remoteConnectionState {
                Circle().fill(remote.phase == .online ? Color.green : Color.orange).frame(width: 6, height: 6)
                    .help(remote.detail)
                Text(remote.detail).uiFont(size: 9).lineLimit(1).frame(maxWidth: 170).help(remote.detail)
            } else if !session.isRunning {
                Circle().fill(VSDark.textDim).frame(width: 5, height: 5).help("Exited")
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
        .foregroundColor(isActive ? VSDark.text : VSDark.textDim)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(isActive ? VSDark.border.opacity(0.7) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// Buttons that hand a ready-made prompt to the assistant (`TerminalPrompt.all`).
/// Click sends it; ⌥-click only types it, to edit before pressing Enter.
private struct TerminalPromptBar: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Binding var expanded: Bool
    @State private var pickingPullRequest = false
    @State private var pickingGitHubActivity = false
    @State private var activityTypeOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").uiFont(size: 8, weight: .bold)
                    Text("PROMPTS").uiFont(size: 9, weight: .bold)
                    Spacer()
                }
                .foregroundColor(VSDark.textDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click a prompt to send it to the assistant; ⌥-click to type it without sending")
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(TerminalPrompt.all) { prompt in button(for: prompt) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(VSDark.bgSidebar)
    }

    private var activeFile: String? {
        guard let tab = workspaceManager.activeTab, tab.isFileBacked else { return nil }
        return workspaceManager.workspaceRelativePath(tab.url)
    }

    @ViewBuilder
    private func button(for prompt: TerminalPrompt) -> some View {
        let unavailable = prompt.input == .activeFile && activeFile == nil
        let chip = Button {
            if prompt.input == .pullRequest {
                pickingPullRequest = true
            } else if prompt.input == .githubActivity {
                activityTypeOnly = NSEvent.modifierFlags.contains(.option)
                pickingGitHubActivity = true
            } else {
                send(prompt, pullRequest: nil)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: prompt.icon).uiFont(size: 9).frame(width: 12)
                Text(prompt.title).uiFont(size: 10).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(unavailable ? VSDark.textDim.opacity(0.5) : VSDark.text)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(VSDark.border.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .help(unavailable ? prompt.help + " (open a file first)" : prompt.help)
        if prompt.input == .pullRequest {
            chip.popover(isPresented: $pickingPullRequest, arrowEdge: .bottom) {
                PullRequestPicker(root: workspaceManager.aiWorkspaceRoot ?? workspaceManager.rootNode?.url) { choice in
                    pickingPullRequest = false
                    send(prompt, pullRequest: choice)
                }
            }
        } else if prompt.input == .githubActivity {
            chip.popover(isPresented: $pickingGitHubActivity, arrowEdge: .bottom) {
                GitHubActivityPicker(typeOnly: activityTypeOnly) { window in
                    pickingGitHubActivity = false
                    let text = prompt.text(file: nil, pullRequest: nil, activityWindow: window)
                    workspaceManager.sendToAssistant(text, submit: !activityTypeOnly)
                }
            }
        } else {
            chip
        }
    }

    private func send(_ prompt: TerminalPrompt, pullRequest: String?) {
        let typeOnly = NSEvent.modifierFlags.contains(.option)
        workspaceManager.sendToAssistant(prompt.text(file: activeFile, pullRequest: pullRequest), submit: !typeOnly)
    }
}

/// Preview the actual bounds before handing the synchronization request to the current agent.
private struct GitHubActivityPicker: View {
    let typeOnly: Bool
    let choose: (GitHubActivityWindow) -> Void
    @State private var period: GitHubActivityPeriod = .weekdays
    @State private var weekdays = 2
    @State private var hours = 48
    @State private var anchor: Date
    @State private var customStart: Date
    @State private var customEnd: Date

    init(typeOnly: Bool, choose: @escaping (GitHubActivityWindow) -> Void) {
        self.typeOnly = typeOnly
        self.choose = choose
        let now = Date()
        _anchor = State(initialValue: now)
        _customStart = State(initialValue: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now)
        _customEnd = State(initialValue: now)
    }

    private var window: GitHubActivityWindow? {
        GitHubActivityWindow.make(period: period, count: period == .hours ? hours : weekdays,
                                  customStart: customStart, customEnd: customEnd, now: anchor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub → MarkView").uiFont(size: 12, weight: .semibold)
            Picker("Period", selection: $period) {
                ForEach(GitHubActivityPeriod.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch period {
            case .weekdays:
                Stepper("\(weekdays) weekdays (\(weekdays * 24) hours)", value: $weekdays, in: 1...30)
                Text("Weekdays count as 24 hours; Saturday and Sunday extend the lookback. Monday 09:00 → Thursday 09:00 for two weekdays. No holiday calendar.")
                    .uiFont(size: 10).foregroundColor(.secondary)
            case .hours:
                Stepper("Last \(hours) calendar hours", value: $hours, in: 1...720)
            case .custom:
                DatePicker("From", selection: $customStart, in: ...anchor, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Through", selection: $customEnd, in: ...anchor, displayedComponents: [.date, .hourAndMinute])
            }
            if let window {
                Text("From: \(window.start.formatted(date: .abbreviated, time: .shortened))\nThrough: \(window.end.formatted(date: .abbreviated, time: .shortened))\nTimezone: \(TimeZone.current.identifier)")
                    .uiFont(size: 11).textSelection(.enabled)
                Text("Includes all GitHub activity within these dates, including weekends. Creates or updates local features and bugs, then reports priorities.")
                    .uiFont(size: 10).foregroundColor(.secondary)
            } else {
                Text("Choose an end after the start, no later than now.")
                    .uiFont(size: 10).foregroundColor(.red)
            }
            HStack {
                Spacer()
                Button(typeOnly ? "Insert prompt" : "Sync and report") {
                    if let window { choose(window) }
                }
                .disabled(window == nil)
            }
        }
        .padding(12)
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which pull request to review: typed (number or URL), picked from the open ones, or the
/// current branch's.
private struct PullRequestPicker: View {
    let root: URL?
    let choose: (String?) -> Void
    @State private var typed = ""
    @State private var open: [(number: Int, title: String)] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review pull request").uiFont(size: 12, weight: .semibold)
            HStack {
                TextField("Number or URL", text: $typed).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit(submitTyped)
                Button("Review", action: submitTyped).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Current branch's pull request") { choose(nil) }
            Divider()
            if loading {
                ProgressView().scaleEffect(0.6)
            } else if open.isEmpty {
                Text("No open pull requests found (gh).").uiFont(size: 10).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(open, id: \.number) { pr in
                            Button { choose("pull request #\(pr.number)") } label: {
                                HStack(spacing: 6) {
                                    Text("#\(pr.number)").uiFont(size: 11, design: .monospaced).foregroundColor(.secondary)
                                    Text(pr.title).uiFont(size: 11).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 320)
        .task {
            guard let root else { loading = false; return }
            open = await Task.detached { ArchitectureStore.openPullRequests(root: root) }.value
            loading = false
        }
    }

    private func submitTyped() {
        let value = typed.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let number = value.hasPrefix("#") ? String(value.dropFirst()) : value
        choose(Int(number) != nil ? "pull request #\(number)" : "the pull request \(value)")
    }
}

/// An editor tab showing a terminal opened in a folder.
struct TerminalTabView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").uiFont(size: 10).foregroundColor(VSDark.textDim)
                Text(session.directory.path).uiFont(size: 10).foregroundColor(VSDark.textDim)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                TerminalDictationButton(session: session)
                TerminalStopButton(session: session)
                TerminalRestartButton(help: "End this shell and start a new one in the same folder") {
                    session.restart()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(VSDark.bgSidebar)
            Divider().background(VSDark.border)
            TerminalHostView(session: session)
        }
        .onAppear { DispatchQueue.main.async { session.focus() } }
    }
}
