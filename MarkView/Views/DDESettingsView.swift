import SwiftUI
import AppKit
import AVFoundation

/// Settings panel for DDE — AI CLI (assistant, model, paths), Whisper, maintenance
struct DDESettingsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var openaiKey: String = ""
    @AppStorage(ActionOutputLanguage.storageKey) private var outputLanguage = ActionOutputLanguage.documentLanguage
    @AppStorage(ResearchSettings.timeoutKey) private var researchTimeout = ResearchSettings.defaultTimeoutMinutes
    @AppStorage(AppFontScale.storageKey) private var fontScalePercent = AppFontScale.defaultPercent
    @State private var showKey = false
    @State private var saved = false
    @State private var openaiStatus: KeyStatus = .unknown

    // AI CLI tools (Claude Code / Codex)
    @State private var cliPaths: [CLITool: String] = [:]
    @State private var cliProbes: [CLITool: CLIToolLocator.ProbeResult] = [:]
    @State private var cliProbing: Set<CLITool> = []
    @State private var extraPath: String = ""

    // Whisper diagnostics
    @AppStorage(WhisperClient.modelStorage) private var whisperModel: String = WhisperClient.defaultModel
    @StateObject private var whisperClient = WhisperClient()
    @State private var whisperTesting = false
    @State private var whisperTestResult: String?

    /// Shows and edits the validated value, so an invalid stored value starts from 100%.
    private var fontScaleBinding: Binding<Int> {
        Binding(get: { AppFontScale.validated(fontScalePercent) },
                set: { fontScalePercent = AppFontScale.validated($0) })
    }

    enum KeyStatus { case unknown, checking, valid, invalid(String) }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("DDE Settings")
                .uiFont(.title2, weight: .bold)

            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Stepper(value: fontScaleBinding, in: AppFontScale.range, step: AppFontScale.step) {
                            Text("Interface text size: \(AppFontScale.validated(fontScalePercent))%")
                        }
                        Spacer()
                        Button("Reset") { fontScalePercent = AppFontScale.defaultPercent }
                            .disabled(AppFontScale.validated(fontScalePercent) == AppFontScale.defaultPercent)
                    }
                    Text("Scales text in every window: AI answers, settings, sidebars, labels, buttons and the terminal. Document text in the editor and previews keeps its own size slider.")
                        .uiFont(size: 9).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }

            // OpenAI (Whisper)
            GroupBox("OpenAI (Whisper voice input)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField("OpenAI API Key (sk-...)", text: $openaiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Save & Verify") {
                            EmbeddingClient.saveKey(openaiKey)
                            workspaceManager.embeddingClient.updateAPIKey(openaiKey)
                            verifyOpenAIKey(openaiKey)
                        }.disabled(openaiKey.isEmpty)
                    }
                    HStack {
                        keyStatusView(openaiStatus)
                        Spacer()
                        Text("Used for: Whisper voice input")
                            .uiFont(size: 9).foregroundColor(.secondary)
                    }
                    Text("Used by the 🎤 in the terminals and in the New Feature / New Bug / I Need to Understand text (shown there only while a key is set). Dictated audio is sent to OpenAI for transcription and billed to this key; it is not stored — the temporary recording is deleted right after. Recordings stop at 10 minutes.")
                        .uiFont(size: 9).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }

            // AI CLI Tools — paths, auth, and PATH, all overridable so a broken
            // integration can always be repaired from the UI.
            GroupBox("AI CLI Tools (Claude Code / Codex)") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        // The window's project, as its toolbar menu edits it; other projects keep
                        // theirs (BUG-022). Without a project these are the defaults.
                        let project = workspaceManager.aiProject
                        Text(project.map { "Assistant & model for \($0.lastPathComponent)" } ?? "Default assistant & model")
                            .uiFont(.caption, weight: .bold)
                        Text(project == nil
                             ? "No project is open in this window, so this sets the defaults for projects that have not chosen their own. Each project chooses its assistant, model and X-Ray model in its own window: here or in the toolbar."
                             : "This project's choice, the same as its window's toolbar menu; other projects keep theirs. Applies to its X-Ray, Explain, selection actions, translation, diagrams, Recursive Insight and AI terminal. The X-Ray model is chosen in the toolbar.")
                            .uiFont(size: 9).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        AIAssistantPickerView(project: project)
                        HStack {
                            Text("AI output language").uiFont(.caption)
                            Picker("", selection: $outputLanguage) {
                                ForEach(ActionOutputLanguage.options, id: \.value) { option in
                                    Text(option.label).tag(option.value)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Text("Explanations, descriptions, reviews and Actions results. Changing it marks existing explanations as outdated.")
                            .uiFont(size: 9).foregroundColor(.secondary)
                        Stepper(value: $researchTimeout, in: 5...120, step: 5) {
                            Text("New Research time limit: \(researchTimeout) min").uiFont(.caption)
                        }
                        .fixedSize()
                        Text("A research job that runs longer stops; what it found so far is saved and marked incomplete.")
                            .uiFont(size: 9).foregroundColor(.secondary)
                    }

                    Divider()
                    ForEach(CLITool.allCases, id: \.self) { tool in
                        cliToolRow(tool)
                        if tool != CLITool.allCases.last { Divider() }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra PATH entries")
                            .uiFont(.caption, weight: .bold)
                        TextField("/opt/homebrew/bin:/some/other/bin", text: $extraPath)
                            .textFieldStyle(.roundedBorder)
                            .uiFont(size: 10, design: .monospaced)
                            .onSubmit { UserDefaults.standard.set(extraPath, forKey: "settings.cli.extraPATH") }
                        Text("Added to PATH for spawned CLIs. Node version dirs are included automatically.")
                            .uiFont(size: 9).foregroundColor(.secondary)
                    }
                }.padding(8)
            }

            // Usage chips in the Terminal tab header: which detected agents are shown (DEC-012).
            GroupBox("Agent usage (Terminal tab)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(UsageAgent.allCases) { agent in AgentUsageVisibilityToggle(agent: agent) }
                    Text("Official limit data is requested with the agent's own sign-in, read locally and sent only to its vendor. Otherwise usage is counted from local logs (~/.claude, ~/.codex).")
                        .uiFont(size: 9).foregroundColor(.secondary)
                }.padding(8)
            }

            // Whisper diagnostics — the config that has to line up for voice input.
            GroupBox("Whisper (voice input)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone:").uiFont(.caption)
                        micStatusView
                        Spacer()
                        if WhisperClient.microphoneStatus != .authorized {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }.uiFont(.caption)
                        }
                    }
                    HStack {
                        Text("OpenAI key:").uiFont(.caption)
                        if !(EmbeddingClient.loadKey() ?? "").isEmpty {
                            Label("Set", systemImage: "checkmark.circle.fill")
                                .uiFont(.caption).foregroundColor(.green)
                        } else {
                            Label("Not set", systemImage: "xmark.circle.fill")
                                .uiFont(.caption).foregroundColor(.red)
                        }
                        Spacer()
                    }
                    Picker("Model:", selection: $whisperModel) {
                        ForEach(WhisperClient.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }.pickerStyle(.menu)

                    HStack {
                        Button(whisperTesting ? "Recording..." : "Record 3s and transcribe") {
                            runWhisperTest()
                        }
                        .disabled(whisperTesting)
                        if whisperTesting { ProgressView().scaleEffect(0.5) }
                        Spacer()
                    }
                    if let result = whisperTestResult {
                        Text(result)
                            .uiFont(size: 10, design: .monospaced)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(8)
            }

            GitHubSettingsSection()

            // Clear database
            GroupBox("Maintenance") {
                VStack(alignment: .leading, spacing: 8) {
                    if let folder = workspaceManager.rootNode?.url {
                        Text("MarkView data stored in “\(folder.lastPathComponent)”: the search index, architecture, AI descriptions and filters, file contents and Insight pages. Documents and code are never touched.")
                            .uiFont(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                workspaceManager.removeMetadata(recreate: true)
                            } label: {
                                Label("Recreate Metadata…", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) {
                                workspaceManager.removeMetadata(recreate: false)
                            } label: {
                                Label("Remove Metadata…", systemImage: "trash")
                            }
                        }
                    } else {
                        Text("Open a folder to manage its MarkView data. The same commands are in the File menu.")
                            .uiFont(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        }
        .padding(20)
        .frame(width: 520, height: 700)
        .onAppear {
            openaiKey = EmbeddingClient.loadKey() ?? ""
            // Log presence and length only — never any part of the key itself.
            WorkspaceManager.debugLog("[DDE Settings] openai key: \(openaiKey.isEmpty ? "absent" : "present (\(openaiKey.count) chars)")")
            if !openaiKey.isEmpty { verifyOpenAIKey(openaiKey) }
            loadCLISettings()
            for tool in CLITool.allCases { probeCLI(tool) }
        }
    }

    // MARK: - AI CLI Tools

    /// One configurable CLI: path override, auto-detect, probe, and Terminal login.
    @ViewBuilder
    private func cliToolRow(_ tool: CLITool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tool.displayName).uiFont(.caption, weight: .bold)

            HStack(spacing: 6) {
                TextField(
                    CLIToolLocator.resolve(tool) ?? "not found — enter the full path",
                    text: Binding(
                        get: { cliPaths[tool] ?? "" },
                        set: { cliPaths[tool] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .uiFont(size: 10, design: .monospaced)
                .onSubmit { applyCLIPath(tool) }

                Button("Save") { applyCLIPath(tool) }
                    .uiFont(.caption)
                Button("Auto-detect") {
                    cliPaths[tool] = ""
                    CLIToolLocator.setOverride(nil, for: tool)
                    probeCLI(tool)
                }.uiFont(.caption)
            }

            HStack(spacing: 8) {
                if cliProbing.contains(tool) {
                    ProgressView().scaleEffect(0.5)
                    Text("Checking...").uiFont(.caption).foregroundColor(.orange)
                } else if let probe = cliProbes[tool] {
                    cliProbeStatusView(probe)
                } else {
                    Label("Not checked", systemImage: "questionmark.circle")
                        .uiFont(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Check") { probeCLI(tool) }
                    .uiFont(.caption).disabled(cliProbing.contains(tool))
                Button("Login in Terminal") {
                    if let error = CLIToolLocator.openLoginInTerminal(tool) {
                        cliProbes[tool] = CLIToolLocator.ProbeResult(error: error)
                    }
                }.uiFont(.caption)
            }

            if let path = cliProbes[tool]?.path {
                Text(path)
                    .uiFont(size: 9, design: .monospaced)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func cliProbeStatusView(_ probe: CLIToolLocator.ProbeResult) -> some View {
        if let error = probe.error {
            Label(error, systemImage: "xmark.circle.fill")
                .uiFont(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                Label(probe.version ?? "found", systemImage: "checkmark.circle.fill")
                    .uiFont(.caption).foregroundColor(.green)
                switch probe.loggedIn {
                case .some(true):
                    Text("· signed in").uiFont(.caption).foregroundColor(.green)
                case .some(false):
                    Text("· NOT signed in").uiFont(.caption).foregroundColor(.orange)
                case nil:
                    Text("· sign-in state unknown").uiFont(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func applyCLIPath(_ tool: CLITool) {
        CLIToolLocator.setOverride(cliPaths[tool], for: tool)
        probeCLI(tool)
    }

    private func probeCLI(_ tool: CLITool) {
        cliProbing.insert(tool)
        Task {
            let result = await CLIToolLocator.probe(tool)
            cliProbes[tool] = result
            cliProbing.remove(tool)
        }
    }

    private func loadCLISettings() {
        for tool in CLITool.allCases {
            cliPaths[tool] = CLIToolLocator.override(for: tool) ?? ""
        }
        extraPath = UserDefaults.standard.string(forKey: "settings.cli.extraPATH") ?? ""
    }

    // MARK: - Whisper diagnostics

    @ViewBuilder
    private var micStatusView: some View {
        switch WhisperClient.microphoneStatus {
        case .authorized:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .uiFont(.caption).foregroundColor(.green)
        case .denied, .restricted:
            Label("Denied", systemImage: "xmark.circle.fill")
                .uiFont(.caption).foregroundColor(.red)
        case .notDetermined:
            Label("Not requested yet", systemImage: "questionmark.circle")
                .uiFont(.caption).foregroundColor(.orange)
        @unknown default:
            Label("Unknown", systemImage: "questionmark.circle")
                .uiFont(.caption).foregroundColor(.secondary)
        }
    }

    private func runWhisperTest() {
        whisperTesting = true
        whisperTestResult = nil
        Task {
            let result = await whisperClient.runSelfTest()
            whisperTestResult = result
            whisperTesting = false
        }
    }

    @ViewBuilder
    private func keyStatusView(_ status: KeyStatus) -> some View {
        switch status {
        case .unknown:
            Label("Not verified", systemImage: "questionmark.circle")
                .uiFont(.caption).foregroundColor(.secondary)
        case .checking:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5)
                Text("Verifying...").uiFont(.caption).foregroundColor(.orange)
            }
        case .valid:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .uiFont(.caption).foregroundColor(.green)
        case .invalid(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .uiFont(.caption).foregroundColor(.red)
        }
    }

    private func verifyOpenAIKey(_ key: String) {
        openaiStatus = .checking
        Task {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    openaiStatus = .valid
                } else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    if body.contains("invalid_api_key") {
                        openaiStatus = .invalid("Invalid API key")
                    } else if body.contains("insufficient_quota") {
                        openaiStatus = .invalid("No credits")
                    } else {
                        openaiStatus = .invalid("HTTP \(status)")
                    }
                }
            } catch {
                openaiStatus = .invalid(error.localizedDescription)
            }
        }
    }
}

/// Show or hide one agent's usage chip; undetected agents are listed but never shown.
private struct AgentUsageVisibilityToggle: View {
    let agent: UsageAgent
    @AppStorage private var hidden: Bool
    private let detected: Bool

    init(agent: UsageAgent) {
        self.agent = agent
        _hidden = AppStorage(wrappedValue: false, agent.hiddenKey)
        detected = AgentUsageTracker.isDetected(agent)
    }

    var body: some View {
        HStack {
            Toggle("Show \(agent.displayName) usage", isOn: Binding(get: { !hidden }, set: { hidden = !$0 }))
                .uiFont(.caption)
                .disabled(!detected)
            if !detected {
                Text("not detected").uiFont(size: 9).foregroundColor(.secondary)
            }
        }
    }
}
