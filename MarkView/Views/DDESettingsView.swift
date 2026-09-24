import SwiftUI
import AppKit
import AVFoundation

/// Settings panel for DDE — API key, model, privacy mode
struct DDESettingsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var apiKey: String = ""
    @State private var openaiKey: String = ""
    @AppStorage("settings.privacyMode") private var privacyMode: String = "trustedRemote"
    @State private var showKey = false
    @State private var saved = false
    @State private var anthropicStatus: KeyStatus = .unknown
    @State private var openaiStatus: KeyStatus = .unknown
    @State private var ollamaConnected = false
    @State private var ollamaModelCount = 0

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

    enum KeyStatus { case unknown, checking, valid, invalid(String) }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("DDE Settings")
                .font(.title2.bold())

            // API Key
            GroupBox("AI Provider (Anthropic Claude)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if showKey {
                            TextField("API Key (sk-ant-...)", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            SecureField("API Key (sk-ant-...)", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                            .buttonStyle(.borderless)
                    }

                    HStack {
                        Button("Save & Verify") {
                            AIProviderClient.saveKeyToKeychain(apiKey)
                            workspaceManager.incrementalCompiler?.orchestrator.updateAPIKey(apiKey)
                            verifyAnthropicKey(apiKey)
                        }
                        .disabled(apiKey.isEmpty)

                        Spacer()

                        keyStatusView(anthropicStatus)
                    }
                }
                .padding(8)
            }

            // Ollama (local LLM)
            GroupBox("Ollama (local LLM — free, private)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if ollamaConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(.green)
                            Text("(\(ollamaModelCount) models)")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Label("Not running", systemImage: "xmark.circle")
                                .font(.caption).foregroundColor(.red)
                            Text("Start with: ollama serve")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Check") {
                            Task {
                                await workspaceManager.ollamaClient.checkConnection()
                                ollamaConnected = workspaceManager.ollamaClient.isConnected
                                ollamaModelCount = workspaceManager.ollamaClient.availableModels.count
                            }
                        }
                    }
                    if !workspaceManager.ollamaClient.availableModels.isEmpty {
                        Picker("Model:", selection: $workspaceManager.ollamaClient.selectedModel) {
                            ForEach(workspaceManager.ollamaClient.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }.pickerStyle(.menu)
                    }
                    Text("Used for: module extraction, classification (instead of Haiku)")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }.padding(8)
            }

        // OpenAI (embeddings + Whisper)
            GroupBox("OpenAI (embeddings + Whisper voice input)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField("OpenAI API Key (sk-...)", text: $openaiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Save & Verify") {
                            EmbeddingClient.saveKey(openaiKey)
                            workspaceManager.embeddingClient.updateAPIKey(openaiKey)
                            workspaceManager.providerRouter?.updateStatus()
                            verifyOpenAIKey(openaiKey)
                        }.disabled(openaiKey.isEmpty)
                    }
                    HStack {
                        keyStatusView(openaiStatus)
                        Spacer()
                        Text("Used for: embeddings search, Whisper voice input")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }.padding(8)
            }

            // AI CLI Tools — paths, auth, and PATH, all overridable so a broken
            // integration can always be repaired from the UI.
            GroupBox("AI CLI Tools (Claude Code / Codex)") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assistant & model").font(.caption.bold())
                        Text("Answers the AI Console and every Ask AI action. Also switchable from the console header.")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                        AIAssistantPickerView()
                    }

                    Divider()
                    ForEach(CLITool.allCases, id: \.self) { tool in
                        cliToolRow(tool)
                        if tool != CLITool.allCases.last { Divider() }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra PATH entries")
                            .font(.caption.bold())
                        TextField("/opt/homebrew/bin:/some/other/bin", text: $extraPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                            .onSubmit { UserDefaults.standard.set(extraPath, forKey: "settings.cli.extraPATH") }
                        Text("Added to PATH for spawned CLIs. Node version dirs are included automatically.")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }.padding(8)
            }

            // Whisper diagnostics — the config that has to line up for voice input.
            GroupBox("Whisper (voice input)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone:").font(.caption)
                        micStatusView
                        Spacer()
                        if WhisperClient.microphoneStatus != .authorized {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }.font(.caption)
                        }
                    }
                    HStack {
                        Text("OpenAI key:").font(.caption)
                        if !(EmbeddingClient.loadKey() ?? "").isEmpty {
                            Label("Set", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(.green)
                        } else {
                            Label("Not set", systemImage: "xmark.circle.fill")
                                .font(.caption).foregroundColor(.red)
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
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(8)
            }

            // Privacy Mode
            GroupBox("Privacy") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Mode", selection: $privacyMode) {
                        Text("Local Only (no AI calls)").tag("localOnly")
                        Text("Trusted Remote").tag("trustedRemote")
                        Text("Redact Before Send").tag("redactBeforeSend")
                    }
                    .pickerStyle(.radioGroup)

                    Text(privacyDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }

            // Status
            if let compiler = workspaceManager.incrementalCompiler {
                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Queue") {
                            Text("\(compiler.compilationQueue.count) blocks")
                        }
                        LabeledContent("Entities") {
                            Text("\(workspaceManager.semanticDatabase?.entityCount() ?? compiler.orchestrator.extractedEntities.count)")
                        }
                        LabeledContent("Claims") {
                            Text("\(workspaceManager.semanticDatabase?.claimCount() ?? compiler.orchestrator.extractedClaims.count)")
                        }
                        LabeledContent("Processing") {
                            if compiler.orchestrator.isDisabled {
                                Text("Stopped (error)").foregroundColor(.red)
                            } else if compiler.orchestrator.isPaused {
                                Text("Paused").foregroundColor(.yellow)
                            } else {
                                Text(compiler.orchestrator.isProcessing ? "Active" : "Idle")
                                    .foregroundColor(compiler.orchestrator.isProcessing ? .orange : .secondary)
                            }
                        }

                        // Pause/Resume AI calls
                        HStack {
                            Button(compiler.orchestrator.isPaused ? "▶ Resume AI" : "⏸ Pause AI") {
                                compiler.orchestrator.isPaused.toggle()
                            }
                            .buttonStyle(.bordered)
                            .tint(compiler.orchestrator.isPaused ? .green : .orange)
                        }

                        if let error = compiler.orchestrator.lastError {
                            Text(error.prefix(150))
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(3)

                            Button("Reset & Retry") {
                                compiler.orchestrator.resetAndRetry()
                            }
                        }
                    }
                    .padding(8)
                }
            }

            // Clear database
            GroupBox("Maintenance") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clear all extracted semantic data (entities, claims, relations, diagnostics). Keeps the .dde folder structure.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(role: .destructive) {
                        if let db = workspaceManager.semanticDatabase {
                            try? db.clearAll()
                            workspaceManager.incrementalCompiler?.orchestrator.extractedEntities.removeAll()
                            workspaceManager.incrementalCompiler?.orchestrator.extractedClaims.removeAll()
                            workspaceManager.incrementalCompiler?.orchestrator.extractedRelations.removeAll()
                            workspaceManager.incrementalCompiler?.diagnostics.removeAll()
                            workspaceManager.incrementalCompiler?.orchestrator.totalInputTokens = 0
                            workspaceManager.incrementalCompiler?.orchestrator.totalOutputTokens = 0
                            workspaceManager.incrementalCompiler?.orchestrator.completedJobCount = 0
                            workspaceManager.softwareArchMermaid = nil
                            workspaceManager.dataFlowMermaid = nil
                            workspaceManager.deploymentMermaid = nil
                            for i in workspaceManager.openTabs.indices {
                                workspaceManager.openTabs[i].blocks.removeAll()
                            }
                            workspaceManager.refreshSemanticViews()
                        }
                    } label: {
                        Label("Clear All Semantic Data", systemImage: "trash")
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
            apiKey = AIProviderClient.loadKeyFromKeychain() ?? ""
            openaiKey = EmbeddingClient.loadKey() ?? ""
            // Log presence and length only — never any part of the key itself.
            WorkspaceManager.debugLog("[DDE Settings] anthropic key: \(apiKey.isEmpty ? "absent" : "present (\(apiKey.count) chars)")")
            WorkspaceManager.debugLog("[DDE Settings] openai key: \(openaiKey.isEmpty ? "absent" : "present (\(openaiKey.count) chars)")")
            ollamaConnected = workspaceManager.ollamaClient.isConnected
            ollamaModelCount = workspaceManager.ollamaClient.availableModels.count
            if !apiKey.isEmpty { verifyAnthropicKey(apiKey) }
            if !openaiKey.isEmpty { verifyOpenAIKey(openaiKey) }
            loadCLISettings()
            for tool in CLITool.allCases { probeCLI(tool) }
            Task {
                await workspaceManager.ollamaClient.checkConnection()
                ollamaConnected = workspaceManager.ollamaClient.isConnected
                ollamaModelCount = workspaceManager.ollamaClient.availableModels.count
            }
        }
    }

    private var privacyDescription: String {
        switch privacyMode {
        case "localOnly": return "No data sent to AI. Only structural parsing + cached results."
        case "redactBeforeSend": return "Sensitive content replaced with placeholders before sending."
        default: return "Content sent to Claude API as-is. Use for trusted environments."
        }
    }

    // MARK: - AI CLI Tools

    /// One configurable CLI: path override, auto-detect, probe, and Terminal login.
    @ViewBuilder
    private func cliToolRow(_ tool: CLITool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tool.displayName).font(.caption.bold())

            HStack(spacing: 6) {
                TextField(
                    CLIToolLocator.resolve(tool) ?? "not found — enter the full path",
                    text: Binding(
                        get: { cliPaths[tool] ?? "" },
                        set: { cliPaths[tool] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .onSubmit { applyCLIPath(tool) }

                Button("Save") { applyCLIPath(tool) }
                    .font(.caption)
                Button("Auto-detect") {
                    cliPaths[tool] = ""
                    CLIToolLocator.setOverride(nil, for: tool)
                    probeCLI(tool)
                }.font(.caption)
            }

            HStack(spacing: 8) {
                if cliProbing.contains(tool) {
                    ProgressView().scaleEffect(0.5)
                    Text("Checking...").font(.caption).foregroundColor(.orange)
                } else if let probe = cliProbes[tool] {
                    cliProbeStatusView(probe)
                } else {
                    Label("Not checked", systemImage: "questionmark.circle")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Check") { probeCLI(tool) }
                    .font(.caption).disabled(cliProbing.contains(tool))
                Button("Login in Terminal") {
                    if let error = CLIToolLocator.openLoginInTerminal(tool) {
                        cliProbes[tool] = CLIToolLocator.ProbeResult(error: error)
                    }
                }.font(.caption)
            }

            if let path = cliProbes[tool]?.path {
                Text(path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func cliProbeStatusView(_ probe: CLIToolLocator.ProbeResult) -> some View {
        if let error = probe.error {
            Label(error, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                Label(probe.version ?? "found", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundColor(.green)
                switch probe.loggedIn {
                case .some(true):
                    Text("· signed in").font(.caption).foregroundColor(.green)
                case .some(false):
                    Text("· NOT signed in").font(.caption).foregroundColor(.orange)
                case nil:
                    Text("· sign-in state unknown").font(.caption).foregroundColor(.secondary)
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
                .font(.caption).foregroundColor(.green)
        case .denied, .restricted:
            Label("Denied", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red)
        case .notDetermined:
            Label("Not requested yet", systemImage: "questionmark.circle")
                .font(.caption).foregroundColor(.orange)
        @unknown default:
            Label("Unknown", systemImage: "questionmark.circle")
                .font(.caption).foregroundColor(.secondary)
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
                .font(.caption).foregroundColor(.secondary)
        case .checking:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5)
                Text("Verifying...").font(.caption).foregroundColor(.orange)
            }
        case .valid:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.green)
        case .invalid(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red)
        }
    }

    private func verifyAnthropicKey(_ key: String) {
        anthropicStatus = .checking
        WorkspaceManager.debugLog("[DDE Verify] Anthropic key to verify: \(key.prefix(20))... (\(key.count) chars)")
        Task {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "claude-haiku-4-5-20251001", "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ])
            request.timeoutInterval = 10

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if json["content"] != nil {
                        anthropicStatus = .valid
                    } else if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                        anthropicStatus = .invalid(String(msg.prefix(60)))
                    } else {
                        anthropicStatus = .invalid("Unknown response")
                    }
                }
            } catch {
                anthropicStatus = .invalid(error.localizedDescription)
            }
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
