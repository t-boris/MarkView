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
/// The left pane's width. It has no ceiling of its own: the split view lets it grow until the
/// centre and the terminal are at their minimum widths; `range` only bounds what is remembered.
enum LeftPanelWidth {
    static let key = "layout.leftPanelWidth"
    static let range: ClosedRange<CGFloat> = 180...6000
    static let standard: CGFloat = 220

    /// The width this window last had (or, for a window that has none yet, the last one any window left).
    static func saved(in state: WindowUIState) -> CGFloat {
        let width = CGFloat(state.value(key, fallback: 0.0))
        return width > 0 ? min(max(width, range.lowerBound), range.upperBound) : standard
    }

    static func save(_ width: CGFloat, in state: WindowUIState) {
        guard range.contains(width) else { return }
        state.set(Double(width.rounded()), for: key, publishing: false)
    }
}

/// Behind the left pane: when the pane appears it moves the split view's divider to the saved
/// width (HSplitView ignores `idealWidth` and hands out space itself), then saves every width
/// the user drags it to. Widths before the restore are layout passes, not the user's, and are not saved.
private struct LeftPanelWidthKeeper: NSViewRepresentable {
    let state: WindowUIState

    func makeNSView(context: Context) -> NSView { KeeperView(state: state) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeeperView: NSView {
        private var restored = false
        private let state: WindowUIState

        init(state: WindowUIState) {
            self.state = state
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            restored = false
            let width = LeftPanelWidth.saved(in: state)
            // After this layout pass, when the split view has its panes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.enclosingSplitView?.setPosition(width, ofDividerAt: 0)
                self.restored = true
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if restored { LeftPanelWidth.save(newSize.width, in: state) }
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

/// Restores the terminal column to a useful width after SwiftUI recreates the split view.
/// The user can still drag the divider; that width becomes the next starting width.
private enum RightPanelWidth {
    static let key = "layout.rightPanelWidth"
    static let range: ClosedRange<CGFloat> = 320...1200
    static let standard: CGFloat = 500

    /// The width this window last had (or, for a window that has none yet, the last one any window left).
    static func saved(in state: WindowUIState) -> CGFloat {
        let width = CGFloat(state.value(key, fallback: 0.0))
        return width > 0 ? min(max(width, range.lowerBound), range.upperBound) : standard
    }

    static func save(_ width: CGFloat, in state: WindowUIState) {
        guard range.contains(width) else { return }
        state.set(Double(width.rounded()), for: key, publishing: false)
    }
}

private struct RightPanelWidthKeeper: NSViewRepresentable {
    let centerVisible: Bool
    let state: WindowUIState

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView(state: state)
        view.centerVisible = centerVisible
        return view
    }

    func updateNSView(_ nsView: KeeperView, context: Context) {
        let centerWasVisible = nsView.centerVisible
        nsView.centerVisible = centerVisible
        if centerVisible && !centerWasVisible { nsView.restoreWidth() }
    }

    final class KeeperView: NSView {
        private var restored = false
        var centerVisible = true
        private var saveGeneration = 0
        private let state: WindowUIState

        init(state: WindowUIState) {
            self.state = state
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            restoreWidth()
        }

        func restoreWidth() {
            restored = false
            saveGeneration += 1
            DispatchQueue.main.async { [weak self] in
                guard let self, self.centerVisible, let split = self.enclosingSplitView,
                      split.subviews.count >= 2 else { return }
                let width = min(RightPanelWidth.saved(in: self.state), split.bounds.width / 2)
                split.setPosition(split.bounds.width - width, ofDividerAt: split.subviews.count - 2)
                self.restored = true
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            saveGeneration += 1
            let generation = saveGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.saveGeneration == generation, self.restored,
                      self.centerVisible, self.window != nil,
                      (self.enclosingSplitView?.subviews.count ?? 0) >= 2,
                      abs(self.frame.width - newSize.width) < 1 else { return }
                RightPanelWidth.save(newSize.width, in: self.state)
            }
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
    @Environment(\.appFontScale) private var appFontScale
    @Environment(\.openWindow) private var openWindow
    var windowSessionID = UUID()
    @StateObject private var workspaceManager = WorkspaceManager()
    @StateObject private var changeReview = ProjectChangeReview()
    @State private var showFolderPicker = false
    /// Project Cycle Time summary, opened from the top bar (DEC-002, DEC-006).
    @State private var showCycleTime = false
    /// NSWindow hosting this view — lets open-URL notifications target only the
    /// active window instead of racing across all ContentView instances.
    @State private var hostWindow: NSWindow?
    /// Finder name of the open folder, for the window title; nil without a folder.
    @State private var workspaceFolderName: String?
    /// Project color identity of the open project folder; nil without one (feature-2, DEC-012).
    @State private var projectKey: String?
    @ObservedObject private var projectColors = ProjectColorStore.shared
    @State private var sessionAttached = false
    @State private var restorationComplete = false
    @State private var lastFilesTab: UUID?
    @AppStorage(TerminalBrowserBridge.enabledKey) private var openTerminalLinksInApp = true
    @AppStorage(BrowserControlServer.agentToolsKey(.claude)) private var browserToolsClaude = true
    @AppStorage(BrowserControlServer.agentToolsKey(.codex)) private var browserToolsCodex = true
    @AppStorage(BrowserControlServer.agentToolsKey(.copilot)) private var browserToolsCopilot = true
    @AppStorage(BrowserControlServer.agentToolsKey(.antigravity)) private var browserToolsAntigravity = true

    var body: some View {
        WindowThemeHost(theme: workspaceManager.theme) { windowContent }
    }

    /// The palette of this window, for the parts of this view that draw with it (its children read it from the environment).
    private var palette: AppPalette { workspaceManager.theme.palette }

    private var windowContent: some View {
        VStack(spacing: 0) {
            workspaceHeader
            if let projectKey { ProjectColorBand(color: projectColors.color(forKey: projectKey)) }
            GeometryReader { geometry in
                let compact = geometry.size.width < 1280 * max(1, appFontScale)
                let terminalMinimum = min(500, max(300, geometry.size.width - 700))
                ZStack(alignment: .bottomTrailing) {
                HSplitView {
                    if workspaceManager.showFileTree {
                        navigationPane
                            .frame(minWidth: compact ? 160 : LeftPanelWidth.range.lowerBound,
                                   idealWidth: compact ? 190 : LeftPanelWidth.standard,
                                   maxWidth: compact ? 240 : .infinity)
                            .background { if !compact { LeftPanelWidthKeeper(state: workspaceManager.windowUI) } }
                    }
                    if workspaceManager.showCenter {
                        workspaceCenter.frame(minWidth: 400, idealWidth: 500)
                    }
                    if workspaceManager.terminalVisible {
                        rightPane.frame(minWidth: terminalMinimum, idealWidth: max(500, terminalMinimum))
                            .background(RightPanelWidthKeeper(centerVisible: workspaceManager.showCenter, state: workspaceManager.windowUI))
                    }
                }
                if workspaceManager.agentsVisible {
                    FloatingAgentsView(workspaceManager: workspaceManager, available: geometry.size)
                }
                }
                .onAppear {
                    workspaceManager.compactLayout = compact
                }
                .onChange(of: compact) { value in
                    workspaceManager.compactLayout = value
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportPDFRequested)) { notification in
            if notification.isFor(workspaceManager) { exportPDF() }
        }
        .onChange(of: workspaceManager.activeTabIndex) { index in
            guard workspaceManager.openTabs.indices.contains(index) else { return }
            let tab = workspaceManager.openTabs[index]
            switch tab.kind {
            case .file, .image, .pdf, .archive, .deployments, .discussions, .workflow, .git, .changeReview, .terminal, .browser, .data, .prototype, .uiStudio, .qa:
                lastFilesTab = tab.id
                workspaceManager.layout.workspaceArea = .files
                if case .file = tab.kind,
                   let feature = workspaceManager.features.locate(tab.url)?.feature {
                    workspaceManager.showFeatureContext(feature.slug)
                }
            case .architecture, .insight:
                workspaceManager.layout.workspaceArea = .projectMap
            case .github(let item):
                workspaceManager.layout.workspaceArea = .files
                switch item {
                case .issue: workspaceManager.layout.gitSection = .issues
                case .pullRequest: workspaceManager.layout.gitSection = .pullRequests
                case .run: workspaceManager.layout.gitSection = .actions
                }
            }
            workspaceManager.showCenter = true
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
            guard isActiveWindow else { return }
            showFolderPicker = true
        }
        .overlay(alignment: .bottomTrailing) { AIToolJobsBanner(jobs: workspaceManager.aiJobs) }
        .sheet(item: $workspaceManager.pdfBookSelection) { selection in
            BookPDFExportView(selection: selection, project: workspaceManager.aiProject,
                              drafts: workspaceManager.pdfBookDrafts, database: workspaceManager.semanticDatabase)
        }
        .sheet(isPresented: graphCreatorSheetBinding) {
            GraphCreatorSheet(
                workspaceManager: workspaceManager,
                isPresented: graphCreatorSheetBinding,
                preselectedType: workspaceManager.pendingGraphCreatorType ?? "architecture"
            )
        }
        .sheet(isPresented: $workspaceManager.showPrototypeCreator) {
            PrototypeCreatorSheet(workspaceManager: workspaceManager, isPresented: $workspaceManager.showPrototypeCreator,
                                  mode: workspaceManager.prototypeCreatorMode)
        }
        .sheet(isPresented: Binding(get: { workspaceManager.doneRequest != nil },
                                    set: { if !$0 { workspaceManager.doneRequest = nil } })) {
            if let url = workspaceManager.doneRequest {
                DefinitionOfDoneSheet(root: workspaceManager.projectFolder, feature: url) { done in
                    workspaceManager.startImplementation(url, done: done)
                }
            }
        }
        .sheet(isPresented: $workspaceManager.showGlobalSearch) {
            SharedSearchView()
                .environmentObject(workspaceManager)
                .windowThemed(workspaceManager.theme)
        }
        .sheet(isPresented: $workspaceManager.operationConsoleVisible) {
            if let store = workspaceManager.projectOperations {
                ProjectOperationConsole(store: store).environmentObject(workspaceManager)
            }
        }
        .sheet(item: $workspaceManager.operationEditRequest) { request in
            if let store = workspaceManager.projectOperations {
                let nodes = workspaceManager.architecture.snapshot?.view("deployment")?.nodes
                    .filter { $0.kind != "root" && $0.kind != "moduleRef" }
                    .map { ProjectOperation.Node(id: $0.id, name: $0.name) } ?? []
                ProjectOperationEditor(store: store, request: request, deploymentNodes: nodes)
            }
        }
        .sheet(item: $workspaceManager.intake) { request in
            IntakeSheet(request: request, workspaceManager: workspaceManager)
        }
        .sheet(item: $workspaceManager.newProject) { request in
            NewProjectSheet(request: request, workspaceManager: workspaceManager)
        }
        .sheet(isPresented: $workspaceManager.gitHubPublishRequested) {
            if let root = workspaceManager.rootNode?.url {
                GitHubPublishSheet(root: root, workspaceManager: workspaceManager)
            } else {
                VStack(spacing: 10) {
                    Text("Open a folder first, then publish it to GitHub.")
                    Button("Close") { workspaceManager.gitHubPublishRequested = false }.keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
        }
        // One for the whole window: `@WindowStorage` in any view below reads this window's own values.
        .environmentObject(workspaceManager.windowUI)
        .environment(\.openDictationSettings, { [weak workspaceManager] in
            Task { @MainActor in DDESettingsWindow.show(workspace: workspaceManager) }
        })
        .navigationTitle(WindowTitle.text(version: MarkViewApp.version, folderName: workspaceFolderName))
        .background(WindowAccessor(window: $hostWindow))
        .onChange(of: workspaceManager.rootNode?.url) { _ in updateWindowIdentity() }
        .task(id: workspaceManager.rootNode?.url) {
            await changeReview.open(workspaceManager.rootNode?.url)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { break }
                await changeReview.refresh()
            }
        }
        .onChange(of: workspaceManager.rootOpenedAsFolder) { _ in updateWindowIdentity() }
        // Finder "Open With" / Quick Action: requests wait in
        // MarkViewApp.pendingOpenURLs until the active window takes them.
        // Drain on every moment this window may have become eligible — a new
        // request, its NSWindow becoming known (cold launch: the request
        // arrives before WindowAccessor resolves), or the window becoming key.
        .onReceive(NotificationCenter.default.publisher(for: .openInActiveWindow)) { _ in
            drainPendingOpens(trigger: "request")
        }
        .onChange(of: hostWindow) { window in
            if let window { workspaceManager.theme.attach(window) }
            updateWindowIdentity()
            attachWindowSession()
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
            // File › New Project… from a window with a folder: this new window takes it.
            if MarkViewApp.pendingNewProject {
                MarkViewApp.pendingNewProject = false
                workspaceManager.newProject = NewProjectRequest()
            }
        }
    }

    private var workspaceHeader: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1100 * max(1, appFontScale)
            let controlWidth = toolbarIconWidth
            HStack(spacing: 5) {
                HStack(spacing: 1) {
                    headerButton("sidebar.leading", help: "Navigation (⌘1)", width: controlWidth,
                                 selected: workspaceManager.showFileTree) { workspaceManager.toggleNavigation() }
                    headerButton("rectangle", help: "Workspace content", width: controlWidth,
                                 selected: workspaceManager.showCenter) { workspaceManager.toggleCenter() }
                    headerButton("sidebar.trailing", help: "Right panel (⌘2)", width: controlWidth,
                                 selected: workspaceManager.terminalVisible) { workspaceManager.toggleRightPanel() }
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(palette.bgActive.opacity(0.5)))
                headerDivider
                HStack(spacing: 6) {
                    if let projectKey {
                        ProjectColorButton(store: projectColors, projectKey: projectKey)
                            .buttonStyle(.plain)
                            .frame(width: 22 * min(1.5, max(1, appFontScale)))
                    }
                    Text(workspaceFolderName ?? "MarkView")
                        .uiFont(size: 12, weight: .semibold)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: compact ? 100 : 160, alignment: .leading)
                        .help(WindowTitle.text(version: MarkViewApp.version, folderName: workspaceFolderName))
                        .accessibilityLabel("\(workspaceFolderName.map { "Project: \($0), " } ?? "")MarkView version \(MarkViewApp.version)")
                }
                .padding(.horizontal, 10).frame(height: controlWidth)
                .fixedSize(horizontal: true, vertical: false)
                .background(palette.bgActive).cornerRadius(7)
                AgentUsageBar()
                Spacer(minLength: 4)
                HStack(spacing: 1) {
                    headerButton("viewfinder", help: "X-Ray (⌘4)", width: controlWidth,
                                 selected: workspaceManager.layout.workspaceArea == .projectMap) { activate(.projectMap) }
                        .disabled(workspaceManager.rootNode == nil)
                    headerButton("checklist", help: "Tasks", width: controlWidth,
                                 selected: workspaceManager.layout.workspaceArea == .work) { activate(.work) }
                        .disabled(workspaceManager.rootNode == nil)
                    headerButton("arrow.triangle.branch", help: "Git", width: controlWidth,
                                 selected: { if case .git? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openGit()
                    }.disabled(workspaceManager.rootNode == nil)
                    headerButton("server.rack", help: "Build & Deployment (⌃⌘D)", width: controlWidth,
                                 selected: { if case .deployments? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openDeployments()
                    }.disabled(workspaceManager.rootNode == nil)
                    headerButton("point.3.connected.trianglepath.dotted", help: "Workflow", width: controlWidth,
                                 selected: { if case .workflow? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openWorkflow()
                    }.disabled(workspaceManager.rootNode == nil)
                    headerButton("checkmark.shield", help: "End-to-End QA (⌘8)", width: controlWidth,
                                 selected: { if case .qa? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openQA()
                    }.disabled(workspaceManager.rootNode == nil)
                    headerButton("macwindow.and.cursorarrow", help: "UI Studio (⌘7)", width: controlWidth,
                                 selected: { if case .uiStudio? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openUIStudio()
                    }.disabled(workspaceManager.rootNode == nil)
                    browserMenu.frame(width: controlWidth, height: controlWidth)
                    headerButton("bubble.left.and.text.bubble.right", help: "Discussions (⌃⌘I)", width: controlWidth,
                                 selected: { if case .discussions? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openDiscussions()
                    }.disabled(workspaceManager.rootNode == nil)
                    headerButton("terminal", help: "Agents (⌘3)", width: controlWidth,
                                 selected: workspaceManager.agentsVisible) { workspaceManager.toggleAIConsole() }
                    projectMenu.frame(width: controlWidth, height: controlWidth)
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(palette.bgActive.opacity(0.5)))
                headerButton("magnifyingglass", help: "Search project (⌘⇧K)", width: controlWidth) {
                    workspaceManager.showGlobalSearch = true
                }
                newMenu.frame(width: controlWidth, height: controlWidth)
                AIToolbarMenu(workspaceManager: workspaceManager, compact: compact)
                    .frame(maxWidth: compact ? controlWidth : 200)
                headerButton("paintpalette", help: "Theme (⇧⌘T)", width: controlWidth) {
                    workspaceManager.theme.showsPicker.toggle()
                }
                .themePicker(workspaceManager.theme)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: min(70, 44 * max(1, appFontScale)))
        .background(palette.bgSidebar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showCycleTime, onDismiss: { workspaceManager.cycleTimeItem = nil }) {
            CycleTimeSheet(store: workspaceManager.features, focus: workspaceManager.cycleTimeItem, open: { item in
                showCycleTime = false
                if item.kind == .feature {
                    workspaceManager.showFeature(item.issue, stage: .explore)
                } else if let bug = workspaceManager.features.bugs.first(where: { $0.key == item.issue }) {
                    workspaceManager.openFile(bug.url)
                }
            }, close: { showCycleTime = false })
        }
        .onChange(of: workspaceManager.cycleTimeItem) { item in if item != nil { showCycleTime = true } }
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(palette.border)
            .frame(width: 1, height: 22 * min(1.5, max(1, appFontScale)))
            .padding(.horizontal, 3)
    }

    private var toolbarIconWidth: CGFloat { 28 * min(1.5, max(1, appFontScale)) }

    private func toolbarIcon(_ symbol: String, width: CGFloat, selected: Bool = false) -> some View {
        Image(systemName: symbol)
            .uiFont(size: 14)
            .foregroundColor(selected ? palette.blue : palette.text)
            .frame(width: width, height: width)
            .background(selected ? palette.bgActive : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
    }

    private func headerButton(_ symbol: String, help: String, width: CGFloat,
                              selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolbarIcon(symbol, width: width, selected: selected)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Less frequent window tools, kept alongside the direct project buttons.
    private var projectMenu: some View {
        Menu {
            Button("Project Cycle Time…") { showCycleTime = true }
                .disabled(workspaceManager.rootNode == nil)
            Button("DDE Settings…") { DDESettingsWindow.show(workspace: workspaceManager) }
        } label: {
            toolbarIcon("ellipsis", width: toolbarIconWidth)
        }
        .menuStyle(.borderlessButton)
        .tint(palette.text)
        .menuIndicator(.hidden)
        .help("More project tools")
        .accessibilityLabel("More project tools")
    }

    private var browserMenu: some View {
        let selected: Bool = { if case .browser? = workspaceManager.activeTab?.kind { return true } else { return false } }()
        return Menu {
            Button("Preview Web App (⌘6)") { workspaceManager.previewWebApp() }
                .disabled(workspaceManager.rootNode == nil)
            Button("New Browser Tab (⌘5)") { workspaceManager.openBrowser(nil) }
            Divider()
            Toggle("Open Terminal Links in MarkView", isOn: $openTerminalLinksInApp)
                .help("Pages that Claude Code, Codex or dev servers open from MarkView's terminals show in the browser tab instead of the default browser (new terminals)")
            Menu("Browser Tools for Agents") {
                Toggle("Claude Code", isOn: $browserToolsClaude)
                Toggle("Codex", isOn: $browserToolsCodex)
                Toggle("Copilot", isOn: $browserToolsCopilot)
                Toggle("Antigravity", isOn: $browserToolsAntigravity)
                Text("For agents started from the AI panel (restart them after a change). Turn one off when its organisation's policy blocks MCP servers.")
            }
            Button("Connect Agents to MarkView…") { AgentBrowserRegistration.connectInteractively() }
                .help("Let Claude Code, Codex, Copilot, Cline and Antigravity drive these browser tabs even when started by hand in a MarkView terminal")
        } label: {
            toolbarIcon("globe", width: toolbarIconWidth, selected: selected)
        }
        .menuStyle(.borderlessButton)
        .tint(selected ? palette.blue : palette.text)
        .menuIndicator(.hidden)
        .help("Preview the project's web app on localhost, or open a browser tab")
        .accessibilityLabel("Browser and web app preview")
    }

    private var newMenu: some View {
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
            toolbarIcon("plus.square", width: toolbarIconWidth)
        }
        .menuStyle(.borderlessButton)
        .tint(palette.text)
        .menuIndicator(.hidden)
        .help("New feature, new bug, or research something in the project")
        .accessibilityLabel("New project item")
        .disabled(workspaceManager.rootNode == nil)
    }

    @ViewBuilder
    private var navigationPane: some View {
        LeftPanelView()
            .environmentObject(workspaceManager)
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            TOCView(layout: workspaceManager.layout)
                .environmentObject(workspaceManager)
            if workspaceManager.rootNode != nil {
                Divider()
                ProjectChangeReviewBar(review: changeReview)
                    .environmentObject(workspaceManager)
            }
        }
    }

    private var workspaceCenter: some View {
        VStack(spacing: 0) {
            TabBarView().environmentObject(workspaceManager)
            filesCenter
        }
        .background(palette.bg)
    }

    private var filesCenter: some View {
        VStack(spacing: 0) {
            if !workspaceManager.selectionActions.isEmpty {
                SelectionActionBar().environmentObject(workspaceManager)
            }
            if let resume = workspaceManager.handoffResume,
               workspaceManager.layout.workspaceArea == .files {
                HandoffResumeBar(resume: resume).environmentObject(workspaceManager)
            }
            if workspaceManager.openTabs.indices.contains(workspaceManager.activeTabIndex) {
                ZStack {
                    EditorView()
                        .environmentObject(workspaceManager)
                    let activeTab = workspaceManager.openTabs[workspaceManager.activeTabIndex]
                    if case .terminal(let id) = activeTab.kind,
                       let session = workspaceManager.terminalSession(id) {
                        TerminalTabView(session: session)
                    } else if case .image = activeTab.kind {
                        ImageViewerView(url: activeTab.url)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .pdf(let reader) = activeTab.kind {
                        PDFReaderView(url: activeTab.url, reader: reader)
                            .id(activeTab.id)
                    } else if case .discussions = activeTab.kind {
                        DiscussionsView(store: workspaceManager.discussions)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .git = activeTab.kind {
                        GitView(git: workspaceManager.gitClient, workspaceManager: workspaceManager)
                            .id(activeTab.id)
                    } else if case .workflow = activeTab.kind {
                        WorkflowTabView(store: workspaceManager.features, editor: workspaceManager.workflowEditor)
                            .id(activeTab.id)
                    } else if case .qa = activeTab.kind {
                        QATabView(model: workspaceManager.qa)
                            .id(activeTab.id)
                    } else if case .changeReview = activeTab.kind {
                        ProjectChangeReviewTab(review: changeReview)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .deployments = activeTab.kind {
                        DeploymentsView(store: workspaceManager.deployments)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .archive = activeTab.kind {
                        ArchiveTabView(url: activeTab.url)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .browser(let session) = activeTab.kind {
                        BrowserTabView(session: session)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .prototype(let session) = activeTab.kind {
                        PrototypeStudioView(session: session)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .uiStudio(let session) = activeTab.kind {
                        UIStudioView(session: session)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    } else if case .github(let item) = activeTab.kind {
                        GitHubTabView(item: item)
                            .environmentObject(workspaceManager)
                            .id(activeTab.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                DiagnosticsBarView().environmentObject(workspaceManager)
            } else {
                welcomeView
            }
            ResearchBar(research: workspaceManager.research,
                        root: workspaceManager.rootNode?.url,
                        activeFile: workspaceManager.activeTab.flatMap { $0.isFileBacked ? $0.url : nil },
                        activeContent: workspaceManager.activeTab?.content ?? "")
        }
    }

    private func activate(_ area: WorkspaceArea) {
        workspaceManager.showCenter = true
        switch area {
        case .files:
            if let id = lastFilesTab,
               let index = workspaceManager.openTabs.firstIndex(where: { $0.id == id }) {
                workspaceManager.activeTabIndex = index
            } else if let index = workspaceManager.openTabs.firstIndex(where: { tab in
                switch tab.kind {
                case .file, .image, .pdf, .archive, .deployments, .discussions, .workflow, .git, .changeReview, .terminal, .browser, .prototype, .uiStudio, .qa: return true
                default: return false
                }
            }) {
                workspaceManager.activeTabIndex = index
            }
            workspaceManager.layout.workspaceArea = .files
        case .projectMap:
            workspaceManager.openArchitecture()
        case .work:
            workspaceManager.layout.workspaceArea = .work
            workspaceManager.layout.leftPanel = "issues"
            workspaceManager.showFeatureContext(workspaceManager.features.active?.slug)
        }
    }

    /// Title, proxy icon and project color follow the workspace root: every way of opening,
    /// restoring or closing a folder changes `rootNode`.
    private func updateWindowIdentity() {
        let root = workspaceManager.rootNode?.url
        workspaceFolderName = root.map(WindowTitle.folderName(of:))
        hostWindow?.titleVisibility = .hidden
        hostWindow?.titlebarAppearsTransparent = true
        hostWindow?.styleMask.insert(.fullSizeContentView)
        hostWindow?.isMovableByWindowBackground = true
        hostWindow?.representedURL = root
        projectKey = workspaceManager.projectFolder.map(ProjectColor.projectKey(for:))
        // Agents driving MarkView see every window, also one with nothing open yet.
        workspaceManager.hostWindow = hostWindow
        if hostWindow != nil { workspaceManager.registerBrowserControl() }
    }

    private func attachWindowSession() {
        guard let window = hostWindow, !sessionAttached else { return }
        sessionAttached = true
        Task { @MainActor in
            await WindowSessionController.shared.attach(id: windowSessionID, window: window, workspace: workspaceManager) { id in
                openWindow(id: WindowSessionController.sceneID, value: id)
            }
            restorationComplete = true
            drainPendingOpens(trigger: "restorationComplete")
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
        guard restorationComplete, !MarkViewApp.pendingOpenURLs.isEmpty, isActiveWindow else { return }
        let urls = MarkViewApp.pendingOpenURLs
        MarkViewApp.pendingOpenURLs.removeAll()
        WorkspaceManager.debugLog("openInActiveWindow (\(trigger), window empty: \(workspaceManager.isBlank)): opening \(urls.map(\.path))")
        // Plain files on their own are shown as documents, without the file tree and the agents panel: in this window when
        // it is empty, else in a window of their own, so a project window keeps its panels. A request with a folder in
        // it, and a window that cannot open another one yet, open as before.
        let files = urls.filter { !isFolder($0) }
        if files.count == urls.count {
            if workspaceManager.isBlank {
                workspaceManager.openDocumentsOnly(files)
                return
            }
            if WindowSessionController.shared.openDocumentWindow(files: files) { return }
        }
        for url in urls { openURL(url) }
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func openURL(_ url: URL) {
        if isFolder(url) { workspaceManager.openFolder(url) } else { workspaceManager.openFile(url) }
    }

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

    /// The pinned welcome tab: action tiles over an animated backdrop (`WelcomeScreen`). What each tile does is
    /// decided here, with the same calls as the menus and the search commands.
    private var welcomeView: some View {
        ProjectWelcomeScreen(root: workspaceManager.rootNode?.url,
                      isGitRepo: workspaceManager.gitClient.isGitRepo,
                      store: workspaceManager.features,
                      backdrop: Binding(get: { workspaceManager.layout.welcomeBackdrop },
                                        set: { workspaceManager.layout.welcomeBackdrop = $0 }),
                      perform: performWelcomeAction) {
            if workspaceManager.rootNode != nil {
                HandoffStartList(store: workspaceManager.features)
                    .environmentObject(workspaceManager)
                    .frame(maxWidth: 700)
            } else {
                ProjectDraftList(drafts: ProjectDraftStore.shared) { id in
                    workspaceManager.newProject = NewProjectRequest(resume: id)
                }
                if !workspaceManager.recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recent projects").uiFont(size: 13, weight: .semibold)
                        ForEach(workspaceManager.recentProjects, id: \.self) { path in
                            RecentProjectRow(path: path) {
                                workspaceManager.openFolder(URL(fileURLWithPath: path, isDirectory: true))
                            } onRemove: {
                                workspaceManager.removeRecentProject(path)
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.bgActive.opacity(0.94)))
                    .frame(maxWidth: 600, alignment: .leading)
                }
            }
        }
    }

    private func performWelcomeAction(_ id: WelcomeActionID) {
        switch id {
        case .terminal: workspaceManager.showAIConsole()
        case .newFeature:
            workspaceManager.intake = IntakeRequest(kind: .feature)
            workspaceManager.layout.workspaceArea = .work
        case .quickFeature:
            workspaceManager.intake = IntakeRequest(kind: .quickFeature)
            workspaceManager.layout.workspaceArea = .work
        case .newBug:
            workspaceManager.intake = IntakeRequest(kind: .bug)
            workspaceManager.layout.workspaceArea = .work
        case .understand: workspaceManager.intake = IntakeRequest(kind: .understand)
        case .research: workspaceManager.newResearch()
        case .discussions: workspaceManager.openDiscussions()
        case .tasks: activate(.work)
        case .xray: workspaceManager.openArchitecture()
        case .search: workspaceManager.showGlobalSearch = true
        case .files: activate(.files)
        case .openFile: openFile()
        case .git: workspaceManager.openGit()
        case .deployments: workspaceManager.openDeployments()
        case .workflow: workspaceManager.openWorkflow()
        case .qa: workspaceManager.openQA()
        case .uiStudio: workspaceManager.openUIStudio()
        case .browser: _ = workspaceManager.openBrowser(nil)
        case .openFolder: openFolder()
        case .newProject: workspaceManager.newProject = NewProjectRequest()
        }
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
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
        NotificationCenter.default.post(.performPDFExport, for: workspaceManager, object: fileName)
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
/// A recent folder on the start screen: click opens it; the hover "×" or the context menu
/// removes it from the list.
private struct RecentProjectRow: View {
    @Environment(\.palette) private var palette
    let path: String
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
            }
            .buttonStyle(.plain)
            .help(path)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(palette.textDim)
            }
            .buttonStyle(.plain)
            .help("Remove from Recent Projects")
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Remove from Recent Projects") { onRemove() }
        }
    }
}

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
        .environmentObject(WorkspaceManager())
}

/// The one toolbar menu of the AI: the assistant CLI and its model for this window's project (BUG-021; other projects keep theirs), the model
/// that X-Ray and the other large structured answers use, and the AI tools (diagrams, prototypes, analyses). A window showing a single file
/// edits the defaults, as DDE Settings does. The bar shows the assistant and its model; the X-Ray model is named in the menu.
struct AIToolbarMenu: View {
    let workspaceManager: WorkspaceManager
    var compact = false
    /// The models each tool offers, as loaded (Codex's list is read from disk, so off the main thread).
    @State private var catalog: [CLITool: [AIModelOption]] = [:]
    @State private var availability: [CLITool: Bool] = [:]
    /// Bumped when any choice changes, so the menu shows the stored values.
    @State private var refresh = 0

    private var choice: AssistantChoice { AssistantChoice(project: workspaceManager.aiProject) }
    private var tool: CLITool { choice.tool }
    private var backend: Binding<String> {
        Binding(get: { choice.tool.rawValue }, set: { choice.setTool($0) })
    }
    private var model: Binding<String> {
        let tool = tool
        return Binding(get: { choice.model(for: tool) }, set: { choice.setModel($0, for: tool) })
    }
    private var xrayModel: Binding<String> {
        let tool = tool
        return Binding(get: { choice.xrayModel(for: tool) }, set: { choice.setXRayModel($0, for: tool) })
    }

    /// The assistant's models. A model saved earlier stays selectable, but the list says that the CLI does not offer it
    /// (Codex rejects models its catalog dropped or the account cannot use).
    private var assistantOptions: [AIModelOption] {
        let id = model.wrappedValue
        guard let loaded = catalog[tool] else {
            return [AIModelOption(id: id, name: id.isEmpty ? "Default" : id, detail: "")]
        }
        return loaded.contains { $0.id == id } ? loaded
            : loaded + [AIModelOption(id: id, name: "\(id) — not in \(tool.displayName)'s list", detail: "")]
    }

    var body: some View {
        let _ = refresh
        let unavailable = availability[tool] == false
        let xrayRecommended = AIAssistantPreferences.defaultXRayModel(for: tool)
        let xrayListed = (catalog[tool] ?? []).filter { !$0.id.isEmpty }
        let xrayName = xrayModel.wrappedValue.isEmpty ? "assistant's model" : xrayModel.wrappedValue
        Menu {
            if unavailable {
                Text("Assistant unavailable. Set its CLI path in Settings.")
                Button("Open AI Settings…") { DDESettingsWindow.show(workspace: workspaceManager) }
                Button("Check Again") {
                    let selected = tool
                    Task { availability[selected] = await CLIToolLocator.resolveThorough(selected) != nil }
                }
                Divider()
            }
            Picker("Assistant", selection: backend) {
                ForEach(CLITool.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Model", selection: model) {
                ForEach(assistantOptions) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Divider()
            // X-Ray, operations discovery, filters and explanations write large structured answers, where a fast model matters more than raw
            // capability: the fast default is marked as recommended.
            Menu("X-Ray model · " + xrayName) {
                Picker("X-Ray model", selection: xrayModel) {
                    Text("Same as the assistant's model").tag("")
                    ForEach(xrayListed) { option in
                        Text(option.id == xrayRecommended ? "\(option.name) (Recommended)" : option.name).tag(option.id)
                    }
                    if !xrayModel.wrappedValue.isEmpty, !xrayListed.contains(where: { $0.id == xrayModel.wrappedValue }) {
                        Text(xrayModel.wrappedValue).tag(xrayModel.wrappedValue)
                    }
                }
                .pickerStyle(.inline)
                Text("Used by X-Ray, operations discovery, filters and explanations.")
            }
            AIToolsMenuItems(workspaceManager: workspaceManager)
        } label: {
            if compact {
                Image(systemName: unavailable ? "exclamationmark.triangle" : "cpu")
            } else {
                Label(AIAssistantPreferences.summary(tool: tool, model: model.wrappedValue),
                      systemImage: unavailable ? "exclamationmark.triangle" : "cpu")
            }
        }
        // An icon-only menu has no room for the chevron: it would reach into the button beside it.
        .menuIndicator(compact ? .hidden : .automatic)
        .help(unavailable ? "Assistant unavailable. Set its CLI path in Settings." :
              (workspaceManager.aiProject == nil ? "Default assistant and model" : "Assistant and model for this project")
              + " — the AI terminal, features and research. X-Ray model: \(xrayName). The menu also holds the AI tools.")
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh += 1 }
        .task(id: tool) {
            let current = tool
            availability[current] = await CLIToolLocator.resolveThorough(current) != nil
            guard catalog[current] == nil else { return }
            catalog[current] = await Self.loadOptions(for: current)
        }
    }
}

extension AIToolbarMenu {
    /// The models `tool` offers. ACP assistants list the account's models only over ACP:
    /// they are fetched the first time.
    static func loadOptions(for tool: CLITool) async -> [AIModelOption] {
        var loaded = await Task.detached { AIAssistantPreferences.modelOptions(for: tool) }.value
        if tool.usesACP, loaded.count <= 1, let path = CLIToolLocator.resolve(tool),
           let models = try? await ACPAssistant.refreshModels(tool, toolPath: path) {
            loaded = [loaded.first].compactMap { $0 } + models
        }
        return loaded
    }
}

/// The AI tools, as submenus of the AI menu: diagrams (Graph Creator), prototypes and the analyses that work.
private struct AIToolsMenuItems: View {
    // Passed in: toolbar content does not get the window's environment objects.
    @ObservedObject var workspaceManager: WorkspaceManager

    var body: some View {
        Menu("Diagrams") {
            Button("System Architecture") { workspaceManager.runAITool(named: "architecture") }
            Button("Data Flow") { workspaceManager.runAITool(named: "dataflow") }
            Button("Pipeline") { workspaceManager.runAITool(named: "pipeline") }
            Button("Deployment") { workspaceManager.runAITool(named: "deployment") }
            Button("Sequence") { workspaceManager.runAITool(named: "sequence") }
            Button("Entity-Relationship") { workspaceManager.runAITool(named: "er") }
        }
        Menu("Prototype") {
            Button("New Prototype…") { workspaceManager.openPrototypeCreator(mode: .requirements) }
                .disabled(workspaceManager.rootNode == nil)
            // Existing code opens as the real application in UI Studio, not as a reconstruction (DEC-002, DEC-005).
            Button("UI Studio (Existing Code)") { workspaceManager.openUIStudio() }
                .disabled(workspaceManager.rootNode == nil)
            let saved = workspaceManager.savedPrototypes()
            Menu("Open Prototype (\(saved.count))") {
                if saved.isEmpty {
                    Text("No prototypes in this project yet")
                } else {
                    ForEach(saved) { prototype in
                        Button(prototype.label) { workspaceManager.openSavedPrototype(prototype.slug) }
                    }
                }
            }
            .disabled(workspaceManager.rootNode == nil || saved.isEmpty)
        }
        Menu("Analysis") {
            Button("Constructive Critic") { workspaceManager.runAITool(named: "critic") }
            // Superseded by New Research, which saves a report (DEC-010).
            Button("Deep Research…") { workspaceManager.newResearch() }
            Button("Codebase Audit") { workspaceManager.runAITool(named: "audit") }
            Button("Code Structure Map") { workspaceManager.runAITool(named: "codemap") }
            Button("Recursive Insight") { workspaceManager.startRecursiveInsight() }
                .disabled(workspaceManager.rootNode == nil || !workspaceManager.hasMarkdownFiles)
        }
    }
}

/// A resizable surface over the workspace, independent of the right panel.
private struct FloatingAgentsView: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @ObservedObject private var state: WindowUIState
    let available: CGSize
    @State private var resizeTranslation = CGSize.zero
    @State private var moveTranslation = CGSize.zero
    @State private var minimized = false
    @State private var maximized = false
    @Environment(\.palette) private var palette
    @Environment(\.appFontScale) private var fontScale

    init(workspaceManager: WorkspaceManager, available: CGSize) {
        self.workspaceManager = workspaceManager
        self.state = workspaceManager.windowUI
        self.available = available
    }

    var body: some View {
        let savedWidth = CGFloat(state.value("layout.agentsWidth", fallback: 650.0))
        let savedHeight = CGFloat(state.value("layout.agentsHeight", fallback: 600.0))
        let baseWidth = min(max(280, savedWidth), available.width)
        let baseHeight = min(max(180, savedHeight), available.height)
        let savedX = max(0, CGFloat(state.value("layout.agentsOffsetX", fallback: 0.0)))
        let savedY = max(0, CGFloat(state.value("layout.agentsOffsetY", fallback: 0.0)))
        let baseX = min(savedX, max(0, available.width - baseWidth))
        let baseY = min(savedY, max(0, available.height - baseHeight))
        let normalWidth = min(available.width - baseX, max(min(280, available.width), baseWidth - resizeTranslation.width))
        let normalHeight = min(available.height - baseY, max(min(180, available.height), baseHeight - resizeTranslation.height))
        let headerHeight = 26 * min(1.5, max(1, fontScale))
        let width = maximized ? available.width : normalWidth
        let height = maximized ? available.height : (minimized ? min(headerHeight, available.height) : normalHeight)
        let x = maximized ? 0 : min(max(0, available.width - width), max(0, baseX - moveTranslation.width))
        let y = maximized ? 0 : min(max(0, available.height - height), max(0, baseY - moveTranslation.height))
        return ModuleExplorerView()
            .environmentObject(workspaceManager)
            .accessibilityHidden(minimized)
            .allowsHitTesting(!minimized)
            .opacity(minimized ? 0 : 1)
            .frame(width: max(0, width), height: max(0, height), alignment: .top)
            .clipped()
            .background(palette.bg)
            .overlay(alignment: .top) {
                HStack(spacing: 0) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .uiFont(size: 11, weight: .semibold)
                        .foregroundColor(palette.textDim.opacity(minimized || maximized ? 0.4 : 1))
                        .frame(width: 30, height: headerHeight)
                        .background(palette.bg)
                        .contentShape(Rectangle())
                        .help("Drag to resize Agents")
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { if !minimized && !maximized { resizeTranslation = $0.translation } }
                            .onEnded { value in
                                guard !minimized && !maximized else { return }
                                state.set(Double(min(available.width - baseX, max(min(280, available.width), baseWidth - value.translation.width))), for: "layout.agentsWidth")
                                state.set(Double(min(available.height - baseY, max(min(180, available.height), baseHeight - value.translation.height))), for: "layout.agentsHeight")
                                resizeTranslation = .zero
                            })
                    Group {
                        if minimized {
                            MinimizedAgentStatus(monitor: workspaceManager.agentActivity)
                        } else {
                            Color.clear
                        }
                    }
                        .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .help("Drag to move Agents")
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { if !maximized { moveTranslation = $0.translation } }
                            .onEnded { value in
                                guard !maximized else { return }
                                state.set(Double(min(max(0, available.width - width), max(0, baseX - value.translation.width))), for: "layout.agentsOffsetX")
                                state.set(Double(min(max(0, available.height - height), max(0, baseY - value.translation.height))), for: "layout.agentsOffsetY")
                                moveTranslation = .zero
                            })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            if maximized { maximized = false }
                            if !minimized { NSApp.keyWindow?.makeFirstResponder(nil) }
                            minimized.toggle()
                        })
                    headerControl(minimized ? "arrow.up.left.and.arrow.down.right" : "minus", help: minimized ? "Restore Agents" : "Minimize Agents", height: headerHeight) {
                        if maximized { maximized = false }
                        if !minimized { NSApp.keyWindow?.makeFirstResponder(nil) }
                        minimized.toggle()
                    }
                    headerControl(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", help: maximized ? "Restore Agents size" : "Maximize Agents", height: headerHeight) {
                        minimized = false
                        maximized.toggle()
                    }
                    headerControl("xmark", help: "Hide Agents", height: headerHeight) {
                        workspaceManager.agentsVisible = false
                    }
                }
            }
            .overlay(Rectangle().stroke(palette.border, lineWidth: 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.3), radius: 12, x: -3, y: -3)
            .offset(x: -x, y: -y)
    }

    private func headerControl(_ symbol: String, help: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).uiFont(size: 10, weight: .bold)
                .foregroundColor(palette.textDim).frame(width: 28, height: height)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Keep the same activity previously shown in the workspace toolbar visible while Agents is collapsed.
private struct MinimizedAgentStatus: View {
    @Environment(\.palette) private var palette
    @ObservedObject var monitor: AgentActivityMonitor

    var body: some View {
        HStack(spacing: 6) {
            Text("Agents").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
            if let entry = monitor.headline {
                AgentStatusDot(state: entry.activity.state)
                Text(entry.name + ": " + entry.activity.text + (monitor.othersWorking > 0 ? "  +\(monitor.othersWorking)" : ""))
                    .uiFont(size: 10, weight: .medium)
                    .foregroundColor(entry.activity.state == .idle ? palette.textDim : palette.text)
                    .lineLimit(1).truncationMode(.tail)
                    .help(entry.activity.summary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
    }
}
