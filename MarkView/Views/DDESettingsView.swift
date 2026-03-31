import SwiftUI

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
                        if workspaceManager.ollamaClient.isConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(.green)
                            Text("(\(workspaceManager.ollamaClient.availableModels.count) models)")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            Label("Not running", systemImage: "xmark.circle")
                                .font(.caption).foregroundColor(.red)
                            Text("Start with: ollama serve")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Check") {
                            Task { await workspaceManager.ollamaClient.checkConnection() }
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
            // Auto-verify saved keys
            if !apiKey.isEmpty { verifyAnthropicKey(apiKey) }
            if !openaiKey.isEmpty { verifyOpenAIKey(openaiKey) }
        }
    }

    private var privacyDescription: String {
        switch privacyMode {
        case "localOnly": return "No data sent to AI. Only structural parsing + cached results."
        case "redactBeforeSend": return "Sensitive content replaced with placeholders before sending."
        default: return "Content sent to Claude API as-is. Use for trusted environments."
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
