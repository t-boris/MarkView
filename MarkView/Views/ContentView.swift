import SwiftUI
import UniformTypeIdentifiers

// Focused value so menu commands target the active window's WorkspaceManager
struct FocusedWorkspaceKey: FocusedValueKey {
    typealias Value = WorkspaceManager
}
// Menus re-evaluate only when a focused value changes. The WorkspaceManager
// reference stays the same while a folder loads or closes, so menu state that
// depends on the folder needs its own value-typed key.
struct FocusedWorkspaceHasFolderKey: FocusedValueKey {
    typealias Value = Bool
}
extension FocusedValues {
    var workspaceManager: WorkspaceManager? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
    var workspaceHasFolder: Bool? {
        get { self[FocusedWorkspaceHasFolderKey.self] }
        set { self[FocusedWorkspaceHasFolderKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var workspaceManager = WorkspaceManager()
    /// Language of everything the AI writes; shared by every AI feature.
    @AppStorage(ActionOutputLanguage.storageKey) private var aiLanguage = ActionOutputLanguage.documentLanguage
    @State private var showFolderPicker = false
    /// NSWindow hosting this view — lets open-URL notifications target only the
    /// active window instead of racing across all ContentView instances.
    @State private var hostWindow: NSWindow?

    var body: some View {
        let _ = themeToken // force re-render of entire tree on theme change
        HSplitView {
            // MARK: - Left Panel: File Tree
            if workspaceManager.showFileTree {
                FileTreeView()
                    .environmentObject(workspaceManager)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 350)
            }

            // MARK: - Center Panel: Editor
            VStack(spacing: 0) {
                // Tab Bar
                if !workspaceManager.openTabs.isEmpty {
                    TabBarView()
                        .environmentObject(workspaceManager)
                }

                // Editor or Welcome Screen
                if workspaceManager.activeTabIndex >= 0,
                   workspaceManager.activeTabIndex < workspaceManager.openTabs.count {
                    ZStack {
                        EditorView()
                            .environmentObject(workspaceManager)
                            .environmentObject(themeManager)
                        // Terminal and image tabs cover the editor, which stays loaded underneath.
                        let activeTab = workspaceManager.openTabs[workspaceManager.activeTabIndex]
                        if case .terminal(let id) = activeTab.kind, let session = workspaceManager.terminalSession(id) {
                            TerminalTabView(session: session)
                        } else if case .image = activeTab.kind {
                            ImageViewerView(url: activeTab.url).id(activeTab.id)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Matrix-style diagnostics status bar
                    DiagnosticsBarView()
                        .environmentObject(workspaceManager)
                } else {
                    welcomeView
                }
            }
            .frame(minWidth: 400)

            // MARK: - Right Panel: Contents/Search/Git or AI
            // Single container with stable width — only content switches inside
            if workspaceManager.showTOC {
                VStack(spacing: 0) {
                    if workspaceManager.showSemanticPanel {
                        ModuleExplorerView()
                            .environmentObject(workspaceManager)
                    } else {
                        TOCView()
                            .environmentObject(workspaceManager)
                    }
                }
                .frame(minWidth: 200, idealWidth: 300)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // X-Ray: the project's structure, logic, deployment and docs (the Architecture tab).
                Button(action: { workspaceManager.openArchitecture() }) {
                    Label("X-Ray", systemImage: "viewfinder")
                        .labelStyle(.titleAndIcon)
                }
                .help("X-Ray — see the project's components, deployment and docs (⌘4)")
                .disabled(workspaceManager.rootNode == nil)

                // Language of all AI output (explanations, analysis, actions).
                Menu {
                    Picker("AI language", selection: $aiLanguage) {
                        ForEach(ActionOutputLanguage.options, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(aiLanguage == ActionOutputLanguage.documentLanguage ? "Auto" : ActionOutputLanguage.label(for: aiLanguage),
                          systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                }
                .help("Language the AI writes in — for every AI feature")

                // Which assistant (and model) does every AI job: X-Ray, Explain, filters, AI terminal.
                AssistantToolbarMenu()

                Divider()

                // Toggle File Tree
                Button(action: { workspaceManager.showFileTree.toggle() }) {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle File Tree")

                // Theme Toggle
                Button(action: { themeManager.toggleTheme() }) {
                    Image(systemName: themeManager.effectiveTheme == .dark ? "sun.max.fill" : "moon.fill")
                }
                .help("Toggle Theme")

                // Toggle AI panel (Terminal) vs Contents / Search / Git
                Button(action: { workspaceManager.showSemanticPanel.toggle() }) {
                    Image(systemName: workspaceManager.showSemanticPanel ? "brain.head.profile" : "brain")
                }
                .help("Toggle AI Panel")

                // Toggle TOC
                Button(action: { workspaceManager.showTOC.toggle() }) {
                    Image(systemName: "list.bullet.indent")
                }
                .help("Toggle Table of Contents")

                // New File
                Button(action: { createNewFileFromToolbar() }) {
                    Image(systemName: "doc.badge.plus")
                }
                .help("New Markdown File")

                // New Graph
                Button(action: { workspaceManager.presentGraphCreator() }) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .help("New Graph Diagram")

                // Generate Documentation
                Button(action: { generateDocumentation() }) {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Generate Documentation")

                // AI Tools menu — always accessible
                Menu {
                    Section("Diagrams") {
                        Button("🏗 System Architecture") { workspaceManager.runAITool(named: "architecture") }
                        Button("🔀 Data Flow") { workspaceManager.runAITool(named: "dataflow") }
                        Button("⚙ Pipeline") { workspaceManager.runAITool(named: "pipeline") }
                        Button("☁ Deployment") { workspaceManager.runAITool(named: "deployment") }
                        Button("↔ Sequence") { workspaceManager.runAITool(named: "sequence") }
                        Button("◆ Entity-Relationship") { workspaceManager.runAITool(named: "er") }
                    }
                    Section("Analysis") {
                        Button("🔍 Constructive Critic") { workspaceManager.runAITool(named: "critic") }
                        Button("🌐 Deep Research") { workspaceManager.runAITool(named: "research") }
                        Button("📋 Full Codebase Audit") { workspaceManager.runAITool(named: "audit") }
                        Button("🗂 Code Structure Map") { workspaceManager.runAITool(named: "codemap") }
                        Button("📚 Generate Full Documentation") { workspaceManager.runAITool(named: "fulldocs") }
                        Button("🧭 Recursive Insight") {
                            workspaceManager.startRecursiveInsight()
                        }
                        .disabled(workspaceManager.rootNode == nil || !workspaceManager.hasMarkdownFiles)
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .help("AI Tools")

                Divider()

                // Export PDF
                Button(action: { exportPDF() }) {
                    Image(systemName: "arrow.down.doc")
                }
                .help("Export PDF")
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportPDFRequested)) { _ in
            exportPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            workspaceManager.themeVersion += 1
        }
        // NOTE: Do NOT use .onOpenURL — it causes SwiftUI to intercept
        // folder URLs, preventing application:open: from receiving them.
        .focusedSceneValue(\.workspaceManager, workspaceManager)
        .focusedSceneValue(\.workspaceHasFolder, workspaceManager.rootNode != nil)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                workspaceManager.openFolder(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFolderPicker)) { _ in
            showFolderPicker = true
        }
        .sheet(isPresented: graphCreatorSheetBinding) {
            GraphCreatorSheet(
                workspaceManager: workspaceManager,
                isPresented: graphCreatorSheetBinding,
                preselectedType: workspaceManager.pendingGraphCreatorType ?? "architecture"
            )
        }
        .background(WindowAccessor(window: $hostWindow))
        // Finder "Open With" / Quick Action: requests wait in
        // MarkViewApp.pendingOpenURLs until the active window takes them.
        // Drain on every moment this window may have become eligible — a new
        // request, its NSWindow becoming known (cold launch: the request
        // arrives before WindowAccessor resolves), or the window becoming key.
        .onReceive(NotificationCenter.default.publisher(for: .openInActiveWindow)) { _ in
            drainPendingOpens(trigger: "request")
        }
        .onChange(of: hostWindow) { _ in
            drainPendingOpens(trigger: "windowAttached")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            drainPendingOpens(trigger: "didBecomeKey")
        }
        .onAppear {
            // Pending folder from the explicit Open Folder → new window flow
            if let url = MarkViewApp.pendingFolderURL {
                MarkViewApp.pendingFolderURL = nil
                WorkspaceManager.debugLog("onAppear: opening \(url.path)")
                workspaceManager.openFolder(url)
            }
            restoreLastFolder()
        }
    }

    /// Reopen the folder that was open when the app last quit. Waits briefly so a
    /// Finder "Open With" request that launched the app wins over the restore.
    private func restoreLastFolder() {
        guard !MarkViewApp.lastFolderRestored else { return }
        MarkViewApp.lastFolderRestored = true
        guard let path = UserDefaults.standard.string(forKey: WorkspaceManager.lastFolderKey) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Something was opened meanwhile (Finder, Open Recent): leave it alone.
            guard workspaceManager.rootNode == nil, workspaceManager.openTabs.isEmpty,
                  MarkViewApp.pendingOpenURLs.isEmpty else { return }
            WorkspaceManager.debugLog("restoreLastFolder: \(path)")
            workspaceManager.openFolder(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    /// True when this view's window should receive "open in active window"
    /// requests: the key window, or the frontmost visible window while the app
    /// is still activating and no window is key yet.
    private var isActiveWindow: Bool {
        guard let hostWindow else { return false }
        if let key = NSApp.keyWindow { return hostWindow === key }
        let frontmost = NSApp.orderedWindows.first { $0.isVisible && !$0.className.contains("Panel") }
        return hostWindow === frontmost
    }

    /// Open all queued external requests in this window if it is the active one.
    /// The queue is emptied before opening, so exactly one window takes them.
    private func drainPendingOpens(trigger: String) {
        guard !MarkViewApp.pendingOpenURLs.isEmpty, isActiveWindow else { return }
        let urls = MarkViewApp.pendingOpenURLs
        MarkViewApp.pendingOpenURLs.removeAll()
        for url in urls {
            WorkspaceManager.debugLog("openInActiveWindow (\(trigger)): opening \(url.path)")
            openURL(url)
        }
    }

    private func openURL(_ url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir { workspaceManager.openFolder(url) } else { workspaceManager.openFile(url) }
    }

    private var themeToken: Int { workspaceManager.themeVersion }
    private var graphCreatorSheetBinding: Binding<Bool> {
        Binding(
            get: { workspaceManager.pendingGraphCreatorType != nil },
            set: { isPresented in
                if !isPresented {
                    workspaceManager.dismissGraphCreator()
                }
            }
        )
    }


    private func createNewFileFromToolbar() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "untitled.md"
        panel.message = "Create new Markdown file"

        if panel.runModal() == .OK, let url = panel.url {
            let name = url.deletingPathExtension().lastPathComponent
            let template = "# \(name)\n\n"
            try? template.write(to: url, atomically: true, encoding: .utf8)
            workspaceManager.openFile(url)
            // Refresh file tree if in same workspace
            workspaceManager.refreshFileTree()
        }
    }

    private func generateDocumentation() {
        // Ask for output folder
        let panel = NSOpenPanel()
        panel.message = "Choose where to create documentation"
        panel.prompt = "Create Here"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let outputURL = panel.url {
            workspaceManager.generateDocumentation(into: outputURL)
        }
    }

    // MARK: - Welcome View

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundColor(VSDark.blue)

            Text("MarkView DDE")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(VSDark.textBright)

            Text("Documentation Development Environment")
                .font(.system(size: 13))
                .foregroundColor(VSDark.textDim)

            if workspaceManager.rootNode != nil {
                // A folder is open but no document yet.
                HStack(spacing: 16) {
                    Button(action: { workspaceManager.openArchitecture() }) {
                        Label("Open X-Ray", systemImage: "viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VSDark.blue)
                    .keyboardShortcut("4", modifiers: [.command])
                    Button("Open File...") { openFile() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 8)
                Text(workspaceManager.isCodeProject
                     ? "This folder is a code project. X-Ray groups it into logical components with AI."
                     : "Pick a document in the file tree, or open X-Ray.")
                    .font(.system(size: 11))
                    .foregroundColor(VSDark.textDim)
            } else {
                HStack(spacing: 16) {
                    Button("Open File...") { openFile() }
                        .buttonStyle(.borderedProminent)
                        .tint(VSDark.blue)
                    Button("Open Folder...") { openFolder() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSDark.bg)
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.markdownText, .plainText]
        if let canvasType = UTType(filenameExtension: "canvas") {
            types.append(canvasType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            workspaceManager.openFile(url)
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            workspaceManager.openFolder(url)
        }
    }

    private func exportPDF() {
        guard workspaceManager.activeTabIndex >= 0,
              workspaceManager.activeTabIndex < workspaceManager.openTabs.count else { return }

        let activeTab = workspaceManager.openTabs[workspaceManager.activeTabIndex]
        let fileName = activeTab.url.deletingPathExtension().lastPathComponent + ".pdf"
        NotificationCenter.default.post(name: .performPDFExport, object: fileName)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let path = String(data: data, encoding: .utf8),
                      let url = URL(string: path) else { return }

                DispatchQueue.main.async {
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        workspaceManager.openFolder(url)
                    } else if FileType.isOpenable(url) {
                        workspaceManager.openFile(url)
                    }
                }
            }
        }
        return true
    }
}

/// Captures the NSWindow hosting a SwiftUI view, so open-URL notifications can
/// be filtered to the active window instead of racing across all instances.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.window = nsView.window }
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(WorkspaceManager())
}

/// Toolbar menu choosing the assistant CLI and its model for all AI features.
/// Edits the same settings as DDE Settings.
struct AssistantToolbarMenu: View {
    @AppStorage(AIAssistantPreferences.backendKey) private var backend = CLITool.claude.rawValue
    @AppStorage(AIAssistantPreferences.modelKey(for: .claude)) private var claudeModel = ""
    @AppStorage(AIAssistantPreferences.modelKey(for: .codex)) private var codexModel = ""
    @AppStorage(AIAssistantPreferences.xrayModelKey(for: .claude)) private var xrayClaudeModel = AIAssistantPreferences.defaultXRayModel(for: .claude)
    @AppStorage(AIAssistantPreferences.xrayModelKey(for: .codex)) private var xrayCodexModel = AIAssistantPreferences.defaultXRayModel(for: .codex)
    /// Model lists per tool; Codex's is read from disk, so off the main thread.
    @State private var options: [CLITool: [AIModelOption]] = [:]

    private var tool: CLITool { CLITool(rawValue: backend) ?? .claude }
    private var model: Binding<String> { tool == .claude ? $claudeModel : $codexModel }
    private var xrayModel: Binding<String> { tool == .claude ? $xrayClaudeModel : $xrayCodexModel }

    var body: some View {
        Menu {
            Picker("Assistant", selection: $backend) {
                ForEach(CLITool.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Model", selection: model) {
                ForEach(options[tool] ?? [AIModelOption(id: model.wrappedValue, name: model.wrappedValue.isEmpty ? "Default" : model.wrappedValue, detail: "")]) {
                    Text($0.name).tag($0.id)
                }
            }
            .pickerStyle(.inline)
            // X-Ray answers are large; a fast model keeps a full analysis near a minute.
            Picker("X-Ray model", selection: xrayModel) {
                Text("Same as above").tag("")
                ForEach((options[tool] ?? []).filter { !$0.id.isEmpty }) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(AIAssistantPreferences.summary(tool: tool, model: model.wrappedValue), systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .help("Assistant and model for every AI feature (X-Ray, Explain, filters, AI terminal)")
        .task(id: backend) {
            let current = tool
            guard options[current] == nil else { return }
            let loaded = await Task.detached { AIAssistantPreferences.modelOptions(for: current) }.value
            // Keep a model saved earlier selectable, but say that the CLI does not list it
            // (Codex rejects models its catalog dropped or the account cannot use).
            let id = current == .claude ? claudeModel : codexModel
            options[current] = loaded.contains { $0.id == id } ? loaded
                : loaded + [AIModelOption(id: id, name: "\(id) — not in \(current.displayName)'s list", detail: "")]
        }
    }
}
