import SwiftUI
import AppKit
import AVFoundation

/// Settings panel for DDE — AI CLI (assistant, model, paths), voice input, maintenance
struct DDESettingsView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var openaiKey: String = ""
    @AppStorage(ActionOutputLanguage.storageKey) private var outputLanguage = ActionOutputLanguage.documentLanguage
    @AppStorage(ResearchSettings.timeoutKey) private var researchTimeout = ResearchSettings.defaultTimeoutMinutes
    @AppStorage(AIAssistantPreferences.autoAnalyzeKey) private var autoAnalyze = true
    @AppStorage(AppFontScale.storageKey) private var fontScalePercent = AppFontScale.defaultPercent
    @AppStorage("appearance.workspaceTransparency") private var workspaceTransparency = 0.0
    @State private var showKey = false
    @State private var showDone = false
    @State private var saved = false
    @State private var openaiStatus: KeyStatus = .unknown

    // AI CLI tools (Claude Code / Codex)
    @State private var cliPaths: [CLITool: String] = [:]
    @State private var cliProbes: [CLITool: CLIToolLocator.ProbeResult] = [:]
    @State private var cliProbing: Set<CLITool> = []
    @State private var extraPath: String = ""

    // Voice input: Whisper (with an OpenAI key) or macOS's built-in recognition (without one)
    @AppStorage(WhisperClient.modelStorage) private var whisperModel: String = WhisperClient.defaultModel
    @AppStorage(OnDeviceSpeech.languageStorage) private var dictationLanguage = ""
    /// Languages macOS can recognize on this Mac; nil until the first lookup finishes.
    @State private var installedLanguages: [String]?
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
        GeometryReader { geometry in
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
                    HStack {
                        Text("Workspace transparency: \(Int(workspaceTransparency * 100))%")
                        Slider(value: $workspaceTransparency, in: 0...0.7, step: 0.05)
                        Button("Reset") { workspaceTransparency = 0 }.disabled(workspaceTransparency == 0)
                    }
                    Text("Shows the selected welcome background behind workspace panels. Some embedded content retains its own background.")
                        .uiFont(size: 9).foregroundColor(palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Scales text in every window: AI answers, settings, sidebars, labels, buttons and the terminal. Document text in the editor and previews keeps its own size slider.")
                        .uiFont(size: 9).foregroundColor(palette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }

            // OpenAI (Whisper)
            GroupBox("OpenAI (optional: Whisper voice input)") {
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
                        Text("Optional: Whisper voice input")
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                    }
                    Text("The 🎤 in the terminals and in the New Feature / New Bug / I Need to Understand text works without a key, using macOS's built-in speech recognition on this Mac (nothing is sent anywhere; choose its language below). With a key, dictation uses OpenAI Whisper instead: it detects the language by itself and is usually more accurate, but the dictated audio is sent to OpenAI and billed to this key; it is not stored — the temporary recording is deleted right after. Recordings stop at 10 minutes.")
                        .uiFont(size: 9).foregroundColor(palette.textDim)
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
                            .uiFont(size: 9).foregroundColor(palette.textDim)
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
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                        Stepper(value: $researchTimeout, in: 5...120, step: 5) {
                            Text("New Research time limit: \(researchTimeout) min").uiFont(.caption)
                        }
                        .fixedSize()
                        Text("A research job that runs longer stops; what it found so far is saved and marked incomplete.")
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                        Toggle("Analyze code projects automatically (X-Ray)", isOn: $autoAnalyze)
                            .uiFont(.caption)
                        Text("When a code project opens, X-Ray scans it and the assistant reads its architecture and traces its main scenarios in the background; refreshed after code changes (60 s of quiet, at most one AI run per 15 min, projects up to 5000 source files). Off: only the local layers, no CLI is started.")
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
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
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                    }
                }.padding(8)
            }

            // Usage chips in the workspace top bar: which detected agents are shown (DEC-012).
            GroupBox("Agent usage (Terminal tab)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(UsageAgent.allCases) { agent in AgentUsageVisibilityToggle(agent: agent) }
                    Text("Official limit data is requested with the agent's own sign-in, read locally and sent only to its vendor. Otherwise usage is counted from local logs (~/.claude, ~/.codex).")
                        .uiFont(size: 9).foregroundColor(palette.textDim)
                }.padding(8)
            }

            // Voice input — the config that has to line up for dictation: the microphone, and either
            // OpenAI (key, model) or macOS's built-in recognition (permission, language).
            GroupBox("Voice input") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone:").uiFont(.caption)
                        micStatusView
                        Spacer()
                        if WhisperClient.microphoneStatus != .authorized {
                            Button("Open System Settings") { openPrivacyPane("Privacy_Microphone") }
                                .uiFont(.caption)
                        }
                    }
                    HStack {
                        Text("Engine:").uiFont(.caption)
                        Text(WhisperClient.engineName).uiFont(.caption)
                        Spacer()
                        Text(WhisperClient.engine == .openAI ? "Audio is sent to OpenAI" : "Runs on this Mac, nothing is sent")
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                    }
                    if WhisperClient.engine == .openAI {
                        HStack {
                            Text("OpenAI key:").uiFont(.caption)
                            Label("Set", systemImage: "checkmark.circle.fill")
                                .uiFont(.caption).foregroundColor(.green)
                            Spacer()
                        }
                        Picker("Model:", selection: $whisperModel) {
                            ForEach(WhisperClient.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }.pickerStyle(.menu)
                    } else {
                        HStack {
                            Text("Speech Recognition:").uiFont(.caption)
                            speechStatusView
                            Spacer()
                            if OnDeviceSpeech.authorization == .denied || OnDeviceSpeech.authorization == .restricted {
                                Button("Open System Settings") { openPrivacyPane("Privacy_SpeechRecognition") }
                                    .uiFont(.caption)
                            }
                        }
                        Picker("Language:", selection: $dictationLanguage) {
                            Text("Automatic (system languages)").tag("")
                            ForEach(languageChoices, id: \.self) { identifier in
                                Text(OnDeviceSpeech.displayName(identifier)).tag(identifier)
                            }
                        }.pickerStyle(.menu)
                        Text("macOS recognizes one language at a time and cannot detect it, so pick the language you dictate in. More languages: System Settings \u{2192} Keyboard \u{2192} Dictation (each downloads once). For mixed languages or the best accuracy, add an OpenAI key above.")
                            .uiFont(size: 9).foregroundColor(palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
            .task { installedLanguages = await Task.detached { OnDeviceSpeech.installedLanguages() }.value }

            GitHubSettingsSection()

            RemoteSettingsSection()

            GroupBox("Workflow templates") {
                VStack(alignment: .leading, spacing: 6) {
                    WorkflowTemplatesSettings(library: .shared)
                    Divider().padding(.vertical, 4)
                    Text("The workflow of a project (its statuses, transitions and processes) is configured inside the project, in its Workflow tab, and kept in .dde/workflow/workflow.json. These are the general templates a process starts from; the project keeps its own copy.")
                        .uiFont(.caption).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    ForEach(ProcessTemplate.allCases) { template in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(template.title).uiFont(size: 11, weight: .medium)
                            Text(template.summary).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Delivery rules").uiFont(size: 11, weight: .medium)
                        Text(VariantTemplate.allCases.map(\.title).joined(separator: "; ") + ". They keep the transitions of the type.")
                            .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open the project's Workflow tab") { workspaceManager.openWorkflow() }
                        .disabled(workspaceManager.projectFolder == nil)
                        .help(workspaceManager.projectFolder == nil ? "Open a project folder first" : "Configure this project's statuses, transitions and processes")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            GroupBox("Implement with AI") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What “done” means for an implementation goal: a fresh branch from origin/main, up-to-date records and GitHub issues, everything committed, a pull request with green CI, tests, deploy… Each item can be required, asked about or skipped; you can also change it just before a run. It guides the assistant; what a status change needs is set in the project workflow above.")
                        .uiFont(.caption).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    Button("Definition of Done…") { showDone = true }
                        .disabled(workspaceManager.projectFolder == nil)
                        .help(workspaceManager.projectFolder == nil ? "Open a project folder first" : "Choose what the assistant must finish")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .sheet(isPresented: $showDone) { DefinitionOfDoneSheet(root: workspaceManager.projectFolder) }

            // Clear database
            GroupBox("Maintenance") {
                VStack(alignment: .leading, spacing: 8) {
                    if let folder = workspaceManager.rootNode?.url {
                        Text("MarkView data stored in “\(folder.lastPathComponent)”: the search index, architecture, AI descriptions and filters, file contents and Insight pages. Documents and code are never touched.")
                            .uiFont(.caption)
                            .foregroundColor(palette.textDim)
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
                            .foregroundColor(palette.textDim)
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        .frame(width: max(0, geometry.size.width - 40), alignment: .leading)
        .padding(20)
        }
        }
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
                        .uiFont(.caption).foregroundColor(palette.textDim)
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
                    .foregroundColor(palette.textDim)
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
                    Text("· sign-in state unknown").uiFont(.caption).foregroundColor(palette.textDim)
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

    // MARK: - Voice input diagnostics

    /// The installed languages for the picker, plus the stored choice when it is not installed (so
    /// the picker never shows a selection it has no row for).
    private var languageChoices: [String] {
        var choices = installedLanguages ?? []
        let stored = DictationLanguage.normalized(dictationLanguage)
        if !stored.isEmpty, !choices.contains(stored) { choices.append(stored) }
        return choices
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var speechStatusView: some View {
        switch OnDeviceSpeech.authorization {
        case .authorized:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .uiFont(.caption).foregroundColor(.green)
        case .denied, .restricted:
            Label("Denied", systemImage: "xmark.circle.fill")
                .uiFont(.caption).foregroundColor(.red)
        case .notDetermined:
            Label("Asked on first use", systemImage: "questionmark.circle")
                .uiFont(.caption).foregroundColor(.orange)
        @unknown default:
            Label("Unknown", systemImage: "questionmark.circle")
                .uiFont(.caption).foregroundColor(palette.textDim)
        }
    }

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
                .uiFont(.caption).foregroundColor(palette.textDim)
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
                .uiFont(.caption).foregroundColor(palette.textDim)
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
    @Environment(\.palette) private var palette
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
                Text("not detected").uiFont(size: 9).foregroundColor(palette.textDim)
            }
        }
    }
}
