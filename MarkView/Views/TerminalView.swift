import SwiftUI
import WebKit

/// Hosts a session's web view. The view belongs to the session, so it keeps its
/// screen when SwiftUI rebuilds this host (tab or panel switches).
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let view = session.webView
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { session.applyTheme() }
    }
}

/// Microphone for a terminal: dictated text (Whisper) is typed at the prompt, not sent —
/// check it and press Enter yourself.
struct TerminalDictationButton: View {
    let session: TerminalSession?
    @StateObject private var whisper = WhisperClient()
    @State private var transcribing = false
    @State private var message: String?

    var body: some View {
        Button(action: toggle) {
            Image(systemName: whisper.isRecording ? "mic.fill" : transcribing ? "waveform" : "mic")
                .font(.system(size: 12))
                .foregroundColor(whisper.isRecording ? VSDark.red : VSDark.textDim)
        }
        .buttonStyle(.plain)
        .disabled(session == nil || transcribing)
        .help(message ?? (whisper.isRecording ? "Stop and insert the text" : "Dictate (Whisper): the text is typed at the prompt"))
    }

    private func toggle() {
        guard let session else { return }
        if whisper.isRecording {
            transcribing = true
            Task {
                let text = await whisper.stopRecording()
                transcribing = false
                if let text, !text.isEmpty { session.paste(text) }
                message = whisper.error
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Restart", systemImage: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(VSDark.text)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(VSDark.border.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// AI panel → Terminal: several terminals side by side (Claude Code, Codex or a plain
/// shell), with buttons that hand a ready-made prompt to the assistant.
struct AITerminalPanel: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage(AIAssistantPreferences.backendKey) private var backend = CLITool.claude.rawValue
    @AppStorage(AIAssistantPreferences.modelKey(for: .claude)) private var claudeModel = ""
    @AppStorage(AIAssistantPreferences.modelKey(for: .codex)) private var codexModel = ""
    @AppStorage("layout.terminalPromptsExpanded") private var promptsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(VSDark.border)
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
        .onAppear { workspaceManager.ensureAITerminal() }
        // At launch the last folder reopens after the panel appeared.
        .onChange(of: workspaceManager.aiWorkspaceRoot) { _ in workspaceManager.ensureAITerminal() }
        .onChange(of: backend) { _ in workspaceManager.aiBackendChanged() }
        .onChange(of: claudeModel) { _ in workspaceManager.aiModelChanged() }
        .onChange(of: codexModel) { _ in workspaceManager.aiModelChanged() }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspaceManager.aiTerminals) { session in
                        TerminalPanelTab(session: session,
                                         isActive: session.id == workspaceManager.aiTerminal?.id,
                                         select: { workspaceManager.activeAITerminalID = session.id },
                                         close: { workspaceManager.closeAITerminal(session.id) })
                    }
                }
            }
            newTerminalMenu
            TerminalDictationButton(session: workspaceManager.aiTerminal)
            TerminalRestartButton(help: "Start the shown terminal again (with the model chosen in the toolbar)") {
                workspaceManager.restartAITerminal()
            }
            .disabled(workspaceManager.aiTerminal == nil)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(VSDark.bgSidebar)
    }

    private var newTerminalMenu: some View {
        Menu {
            ForEach(TerminalProfile.allCases) { profile in
                Button { workspaceManager.openAITerminal(profile) } label: { Label(profile.title, systemImage: profile.icon) }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.textDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New terminal: Claude Code, Codex or a plain shell")
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "terminal").font(.system(size: 26)).foregroundColor(VSDark.textDim)
            if workspaceManager.aiWorkspaceRoot == nil && workspaceManager.rootNode == nil {
                Text("Open a folder to start a terminal").font(.system(size: 11)).foregroundColor(VSDark.textDim)
            } else {
                HStack(spacing: 8) {
                    ForEach(TerminalProfile.allCases) { profile in
                        Button { workspaceManager.openAITerminal(profile) } label: {
                            Label(profile.title, systemImage: profile.icon).font(.system(size: 11))
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
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: session.profile.icon).font(.system(size: 9))
            Text(session.title).font(.system(size: 10, weight: isActive ? .semibold : .regular)).lineLimit(1)
            if !session.isRunning {
                Circle().fill(VSDark.textDim).frame(width: 5, height: 5).help("Exited")
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                    Text("PROMPTS").font(.system(size: 9, weight: .bold))
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
            } else {
                send(prompt, pullRequest: nil)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: prompt.icon).font(.system(size: 9)).frame(width: 12)
                Text(prompt.title).font(.system(size: 10)).lineLimit(1)
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
        } else {
            chip
        }
    }

    private func send(_ prompt: TerminalPrompt, pullRequest: String?) {
        let typeOnly = NSEvent.modifierFlags.contains(.option)
        workspaceManager.sendToAssistant(prompt.text(file: activeFile, pullRequest: pullRequest), submit: !typeOnly)
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
            Text("Review pull request").font(.system(size: 12, weight: .semibold))
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
                Text("No open pull requests found (gh).").font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(open, id: \.number) { pr in
                            Button { choose("pull request #\(pr.number)") } label: {
                                HStack(spacing: 6) {
                                    Text("#\(pr.number)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                    Text(pr.title).font(.system(size: 11)).lineLimit(1)
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
                Image(systemName: "terminal").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                Text(session.directory.path).font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                TerminalDictationButton(session: session)
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
