import SwiftUI
import UniformTypeIdentifiers

/// AI Console tab — chat with Claude Code CLI
struct AIConsoleView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    @State private var inputText = ""
    @State private var scrollTarget: UUID?
    @StateObject private var whisper = WhisperClient()

    var body: some View {
        if let engine = workspaceManager.aiConsoleEngine {
            AIConsoleInnerView(engine: engine, workspaceManager: workspaceManager, whisper: whisper)
        } else {
            VStack {
                Spacer()
                Image(systemName: "terminal").font(.system(size: 24)).foregroundColor(VSDark.textDim)
                Text("Open a file or folder to start").font(.system(size: 11)).foregroundColor(VSDark.textDim)
                Spacer()
            }.frame(maxWidth: .infinity).background(VSDark.bgSidebar)
        }
    }
}

/// Inner view that directly observes the engine
struct AIConsoleInnerView: View {
    @ObservedObject var engine: AIConsoleEngine
    let workspaceManager: WorkspaceManager
    @ObservedObject var whisper: WhisperClient

    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Backend selector
            HStack(spacing: 4) {
                ForEach(AIConsoleEngine.AIBackend.allCases, id: \.self) { b in
                    Button(action: { engine.backend = b; engine.clearHistory() }) {
                        Text(b.rawValue)
                            .font(.system(size: 9, weight: engine.backend == b ? .bold : .regular))
                            .foregroundColor(engine.backend == b ? VSDark.textBright : VSDark.textDim)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(engine.backend == b ? VSDark.bgActive : Color.clear)
                            .cornerRadius(3)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text(engine.backend == .claude ? "claude" : "codex")
                    .font(.system(size: 8, design: .monospaced)).foregroundColor(VSDark.textDim)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(VSDark.bgSidebar)

            messageListView
            Divider().background(VSDark.border)
            inputBarView
        }
        .background(VSDark.bgSidebar)
        .onAppear { initialSetup() }
    }

    // MARK: - Message List

    private var messageListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }

                    if engine.isProcessing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5)
                            Text(engine.currentStatus ?? "Processing...")
                                .font(.system(size: 10)).foregroundColor(VSDark.blue)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .id("processing")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: engine.messages.count) { _ in
                withAnimation {
                    if let last = engine.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Message Bubble

    private func messageBubble(_ msg: AIConsoleEngine.ConsoleMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            switch msg.role {
            case .user:
                Spacer(minLength: 40)
                Text(msg.content)
                    .font(.system(size: 11))
                    .foregroundColor(VSDark.textBright)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(VSDark.blue.opacity(0.2))
                    .cornerRadius(8)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)

            case .assistant:
                VStack(alignment: .leading, spacing: 4) {
                    let lineCount = max(3, msg.content.components(separatedBy: "\n").count)
                    let estimatedHeight = CGFloat(lineCount) * 18 + 40
                    MarkdownContentView(markdown: msg.content)
                        .frame(height: min(estimatedHeight, 2000))
                        .cornerRadius(8)
                    HStack(spacing: 8) {
                        if let cost = msg.cost {
                            Text("$\(String(format: "%.4f", cost))")
                                .font(.system(size: 8)).foregroundColor(VSDark.textDim)
                        }
                        Spacer()
                        // Save as MD button
                        Button(action: { saveMessageAsMD(msg.content) }) {
                            HStack(spacing: 2) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 8))
                                Text("Save .md").font(.system(size: 8))
                            }.foregroundColor(VSDark.blue)
                        }.buttonStyle(.plain)
                        // Copy button
                        Button(action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(msg.content, forType: .string) }) {
                            HStack(spacing: 2) {
                                Image(systemName: "doc.on.doc").font(.system(size: 8))
                                Text("Copy").font(.system(size: 8))
                            }.foregroundColor(VSDark.textDim)
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 10)
                }
                .padding(.horizontal, 8)
                Spacer(minLength: 20)

            case .system:
                HStack(spacing: 4) {
                    if msg.content.hasPrefix("File:") {
                        let fileName = msg.content.replacingOccurrences(of: "File: ", with: "")
                        Image(systemName: "doc.text").font(.system(size: 9)).foregroundColor(VSDark.green)
                        Button(action: { openChangedFile(fileName) }) {
                            Text(fileName).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.green)
                        }.buttonStyle(.plain)
                    } else {
                        Image(systemName: "info.circle").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                        Text(msg.content).font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 2)

            case .error:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundColor(VSDark.red)
                    Text(msg.content).font(.system(size: 10)).foregroundColor(VSDark.red)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(VSDark.red.opacity(0.1)).cornerRadius(4)
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Input Bar

    // Dynamic height: 1 line = ~20px, max 6 lines = ~120px
    private var inputHeight: CGFloat {
        let lineCount = max(1, inputText.components(separatedBy: "\n").count)
        let estimated = CGFloat(lineCount) * 18 + 12
        return min(estimated, 120)
    }

    private var inputBarView: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Voice input button
            Button(action: { toggleRecording() }) {
                Image(systemName: whisper.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 12))
                    .foregroundColor(whisper.isRecording ? VSDark.red : VSDark.textDim)
            }
            .buttonStyle(.plain)
            .help("Voice input (Whisper)")
            .padding(.bottom, 4)

            // Multi-line text input
            ZStack(alignment: .topLeading) {
                // Placeholder
                if inputText.isEmpty {
                    Text("Ask Claude Code...")
                        .font(.system(size: 12))
                        .foregroundColor(VSDark.textDim)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                }
                TextEditor(text: $inputText)
                    .font(.system(size: 12))
                    .foregroundColor(VSDark.text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: inputHeight)
                    .disabled(engine.isProcessing)
                    .onChange(of: inputText) { newValue in
                        // Detect Enter key (newline without Shift)
                        if newValue.hasSuffix("\n") && !NSEvent.modifierFlags.contains(.shift) {
                            inputText = String(newValue.dropLast())
                            if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                send()
                            }
                        }
                    }
            }
            .padding(4)
            .background(VSDark.bg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(VSDark.border, lineWidth: 1))

            // Buttons column
            VStack(spacing: 4) {
                if engine.isProcessing {
                    Button(action: { engine.stop() }) {
                        Image(systemName: "stop.fill").font(.system(size: 10)).foregroundColor(VSDark.red)
                    }.buttonStyle(.plain).help("Stop")
                } else if !inputText.isEmpty {
                    Button(action: { send() }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 14)).foregroundColor(VSDark.blue)
                    }.buttonStyle(.plain)
                }

                if !(engine.messages.isEmpty) {
                    Button(action: { engine.clearHistory() }) {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain).help("Clear history")
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VSDark.bgInput)
        .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { providers in
            for provider in providers {
                // Handle dragged file path as text
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    if let data = data as? Data, let path = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async { inputText += (inputText.isEmpty ? "" : " ") + path }
                    }
                }
                // Handle dragged file URL
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    if let data = data as? Data, let urlStr = String(data: data, encoding: .utf8),
                       let url = URL(string: urlStr) {
                        DispatchQueue.main.async { inputText += (inputText.isEmpty ? "" : " ") + url.path }
                    }
                }
            }
            return true
        }
    }

    // MARK: - No Engine View


    // MARK: - Actions

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        engine.sendMessage(text)
    }

    private func initialSetup() {
        // Generate CLAUDE.md on first appearance
        if engine.messages.isEmpty {
            engine.generateSkillFile()

            // Auto-read current file
            let wm = workspaceManager
            if wm.activeTabIndex >= 0, wm.activeTabIndex < wm.openTabs.count {
                let tab = wm.openTabs[wm.activeTabIndex]
                engine.readCurrentFile(tab.url)
            }
        }
    }

    private func saveMessageAsMD(_ content: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "claude-response.md"
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            workspaceManager.openFile(url)
        }
    }

    private func openChangedFile(_ relativePath: String) {
        let root = workspaceManager.rootNode?.url ?? engine.workspaceRoot
        let fileURL = root.appendingPathComponent(relativePath)
        workspaceManager.openOrRefreshFile(fileURL)
    }

    private func toggleRecording() {
        if whisper.isRecording {
            // Stop recording → transcribe → insert text for review
            Task {
                if let text = await whisper.stopRecording() {
                    inputText = text
                    // Don't auto-send — let user review/edit the transcription first
                }
            }
        } else {
            if !whisper.hasAPIKey {
                engine.messages.append(AIConsoleEngine.ConsoleMessage(role: .error,
                    content: "OpenAI API key not set. Add it in Settings for Whisper voice input."))
                return
            }
            whisper.startRecording()
        }
    }
}
