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

/// Width of the left pane (Files and Issues share it), remembered across launches.
enum LeftPanelWidth {
    static let key = "layout.leftPanelWidth"
    static let range: ClosedRange<CGFloat> = 180...800
    static let standard: CGFloat = 220

    static var saved: CGFloat {
        let width = CGFloat(UserDefaults.standard.double(forKey: key))
        return width > 0 ? min(max(width, range.lowerBound), range.upperBound) : standard
    }

    static func save(_ width: CGFloat) {
        guard range.contains(width) else { return }
        UserDefaults.standard.set(Double(width.rounded()), forKey: key)
    }
}

/// Behind the left pane: when the pane appears it moves the split view's divider to the saved
/// width (HSplitView ignores `idealWidth` and hands out space itself), then saves every width
/// the user drags it to. Widths before the restore are layout passes, not the user's, and are not saved.
private struct LeftPanelWidthKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { KeeperView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeeperView: NSView {
        private var restored = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            restored = false
            let width = LeftPanelWidth.saved
            // After this layout pass, when the split view has its panes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.enclosingSplitView?.setPosition(width, ofDividerAt: 0)
                self.restored = true
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if restored { LeftPanelWidth.save(newSize.width) }
        }

        private var enclosingSplitView: NSSplitView? {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView { return split }
                view = current.superview
            }
            return nil
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var workspaceManager = WorkspaceManager()
    @State private var showFolderPicker = false
    /// NSWindow hosting this view — lets open-URL notifications target only the
    /// active window instead of racing across all ContentView instances.
    @State private var hostWindow: NSWindow?
    /// Finder name of the open folder, for the window title; nil without a folder.
    @State private var workspaceFolderName: String?

    var body: some View {
        let _ = themeToken // force re-render of entire tree on theme change
        HSplitView {
            // MARK: - Left Panel: File Tree
            if workspaceManager.showFileTree {
                LeftPanelView()
                    .environmentObject(workspaceManager)
                    .frame(minWidth: LeftPanelWidth.range.lowerBound, idealWidth: LeftPanelWidth.standard,
                           maxWidth: LeftPanelWidth.range.upperBound)
                    .background(LeftPanelWidthKeeper())
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
                        } else if case .github(let item) = activeTab.kind {
                            GitHubTabView(item: item)
                                .environmentObject(workspaceManager)
                                .id(activeTab.id)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Matrix-style diagnostics status bar
                    DiagnosticsBarView()
                        .environmentObject(workspaceManager)
                } else {
                    welcomeView
                }

                // New Research: running jobs and, for a research document, "Continue / deepen".
                ResearchBar(research: workspaceManager.research, root: workspaceManager.rootNode?.url,
                            activeFile: workspaceManager.activeTab.flatMap { $0.isFileBacked ? $0.url : nil },
                            activeContent: workspaceManager.activeTab?.content ?? "")
            }
            .frame(minWidth: 400)

            // MARK: - Right Panel: Contents / Search / Git / Terminal
            if workspaceManager.showTOC {
                TOCView(layout: workspaceManager.layout)
                    .environmentObject(workspaceManager)
                    .frame(minWidth: 200, idealWidth: 300)
            }
        }
        .toolbar {
            // Panels, side by side at the leading edge.
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { workspaceManager.showFileTree.toggle() }) {
                    Image(systemName: "sidebar.leading")
                }
                .help("Files panel (⌘1)")

                Button(action: { workspaceManager.showTOC.toggle() }) {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Contents / Search / Git / Terminal panel (⌘2)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // X-Ray: the project's structure, logic, deployment and docs (the Architecture tab).
                Button(action: { workspaceManager.openArchitecture() }) {
                    Image(systemName: "viewfinder")
                }
                .help("X-Ray — the project's components, deployment and docs (⌘4)")
                .disabled(workspaceManager.rootNode == nil)

                // New feature / bug / "I need to understand" — the standard ways into the project.
                Menu {
                    ForEach(IntakeKind.allCases) { kind in
                        Button(kind.title + "…") { workspaceManager.intake = IntakeRequest(kind: kind) }
                    }
                    if let url = workspaceManager.activeTab?.url, workspaceManager.activeTab?.isFileBacked == true {
                        Section("From the open document (\(url.lastPathComponent))") {
                            ForEach(IntakeKind.allCases) { kind in
                                Button(kind.title + " from It…") { workspaceManager.startIntake(kind, fromDocument: url) }
                            }
                            Button("Implement It with AI") { workspaceManager.implementWithAI(url) }
                        }
                    }
                } label: {
                    Image(systemName: "plus.square")
                }
                .menuIndicator(.hidden)
                .help("New feature, new bug, or research something in the project")
                .disabled(workspaceManager.rootNode == nil)

                // Which assistant (and model) does every AI job: X-Ray, Explain, filters, AI terminal.
                AssistantToolbarMenu()

                AIToolsMenu(workspaceManager: workspaceManager)

                Button(action: { themeManager.toggleTheme() }) {
                    Image(systemName: themeManager.effectiveTheme == .dark ? "sun.max" : "moon")
                }
                .help("Light / dark theme")
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
        .sheet(item: $workspaceManager.intake) { request in
            IntakeSheet(request: request, workspaceManager: workspaceManager)
        }
        .background(WindowAccessor(window: $hostWindow))
        // "MarkView 2.18.0 — my-project" and the folder as the proxy icon, per window (issue #25).
        .navigationTitle(WindowTitle.text(version: MarkViewApp.version, folderName: workspaceFolderName))
        .onChange(of: workspaceManager.rootNode?.url) { _ in updateWindowIdentity() }
        // Finder "Open With" / Quick Action: requests wait in
        // MarkViewApp.pendingOpenURLs until the active window takes them.
        // Drain on every moment this window may have become eligible — a new
        // request, its NSWindow becoming known (cold launch: the request
        // arrives before WindowAccessor resolves), or the window becoming key.
        .onReceive(NotificationCenter.default.publisher(for: .openInActiveWindow)) { _ in
            drainPendingOpens(trigger: "request")
        }
        .onChange(of: hostWindow) { _ in
            updateWindowIdentity()
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

    /// Title and proxy icon follow the workspace root: every way of opening, restoring or
    /// closing a folder changes `rootNode`.
    private func updateWindowIdentity() {
        let root = workspaceManager.rootNode?.url
        workspaceFolderName = root.map(WindowTitle.folderName(of:))
        hostWindow?.representedURL = root
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
    @AppStorage(AIAssistantPreferences.modelKey(for: .cline)) private var clineModel = ""
    @AppStorage(AIAssistantPreferences.modelKey(for: .copilot)) private var copilotModel = ""
    @AppStorage(AIAssistantPreferences.xrayModelKey(for: .claude)) private var xrayClaudeModel = AIAssistantPreferences.defaultXRayModel(for: .claude)
    @AppStorage(AIAssistantPreferences.xrayModelKey(for: .codex)) private var xrayCodexModel = AIAssistantPreferences.defaultXRayModel(for: .codex)
    @AppStorage(AIAssistantPreferences.xrayModelKey(for: .cline)) private var xrayClineModel = AIAssistantPreferences.defaultXRayModel(for: .cline)
    @AppStorage(AIAssistantPreferences.xrayModelKey(for: .copilot)) private var xrayCopilotModel = AIAssistantPreferences.defaultXRayModel(for: .copilot)
    /// Model lists per tool; Codex's is read from disk, so off the main thread.
    @State private var options: [CLITool: [AIModelOption]] = [:]

    private var tool: CLITool { CLITool(rawValue: backend) ?? .claude }
    private var model: Binding<String> {
        switch tool {
        case .claude: return $claudeModel
        case .codex: return $codexModel
        case .cline: return $clineModel
        case .copilot: return $copilotModel
        }
    }
    private var xrayModel: Binding<String> {
        switch tool {
        case .claude: return $xrayClaudeModel
        case .codex: return $xrayCodexModel
        case .cline: return $xrayClineModel
        case .copilot: return $xrayCopilotModel
        }
    }

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
            var loaded = await Task.detached { AIAssistantPreferences.modelOptions(for: current) }.value
            // ACP assistants list the account's models only over ACP: fetch them the first time.
            if current.usesACP, loaded.count <= 1, let path = CLIToolLocator.resolve(current),
               let models = try? await ACPAssistant.refreshModels(current, toolPath: path) {
                loaded = [loaded.first].compactMap { $0 } + models
            }
            // Keep a model saved earlier selectable, but say that the CLI does not list it
            // (Codex rejects models its catalog dropped or the account cannot use).
            let id = model.wrappedValue
            options[current] = loaded.contains { $0.id == id } ? loaded
                : loaded + [AIModelOption(id: id, name: "\(id) — not in \(current.displayName)'s list", detail: "")]
        }
    }
}

/// Toolbar menu of AI tools: diagrams (Graph Creator) and the analyses that work.
struct AIToolsMenu: View {
    // Passed in: toolbar content does not get the window's environment objects.
    @ObservedObject var workspaceManager: WorkspaceManager

    var body: some View {
        Menu {
            Section("Diagrams") {
                Button("System Architecture") { workspaceManager.runAITool(named: "architecture") }
                Button("Data Flow") { workspaceManager.runAITool(named: "dataflow") }
                Button("Pipeline") { workspaceManager.runAITool(named: "pipeline") }
                Button("Deployment") { workspaceManager.runAITool(named: "deployment") }
                Button("Sequence") { workspaceManager.runAITool(named: "sequence") }
                Button("Entity-Relationship") { workspaceManager.runAITool(named: "er") }
            }
            // Each hands a prompt to the assistant in the Terminal tab, which writes the result.
            Section("Analysis") {
                Button("Constructive Critic") { workspaceManager.runAITool(named: "critic") }
                // Superseded by New Research, which saves a report (DEC-010).
                Button("Deep Research…") { workspaceManager.newResearch() }
                Button("Codebase Audit") { workspaceManager.runAITool(named: "audit") }
                Button("Code Structure Map") { workspaceManager.runAITool(named: "codemap") }
                Button("Recursive Insight") { workspaceManager.startRecursiveInsight() }
                    .disabled(workspaceManager.rootNode == nil || !workspaceManager.hasMarkdownFiles)
            }
        } label: {
            Image(systemName: "wand.and.stars")
        }
        .menuIndicator(.hidden)
        .help("AI tools: diagrams and analysis")
    }
}
