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

/// Restores the terminal column to a useful width after SwiftUI recreates the split view.
/// The user can still drag the divider; that width becomes the next starting width.
private enum RightPanelWidth {
    static let key = "layout.rightPanelWidth"
    static let range: ClosedRange<CGFloat> = 320...1200
    static let standard: CGFloat = 500

    static var saved: CGFloat {
        let width = CGFloat(UserDefaults.standard.double(forKey: key))
        return width > 0 ? min(max(width, range.lowerBound), range.upperBound) : standard
    }

    static func save(_ width: CGFloat) {
        guard range.contains(width) else { return }
        UserDefaults.standard.set(Double(width.rounded()), forKey: key)
    }
}

private struct RightPanelWidthKeeper: NSViewRepresentable {
    let centerVisible: Bool

    func makeNSView(context: Context) -> KeeperView {
        let view = KeeperView()
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
                let width = min(RightPanelWidth.saved, split.bounds.width / 2)
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
                RightPanelWidth.save(newSize.width)
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
                HSplitView {
                    if workspaceManager.showFileTree {
                        navigationPane
                            .frame(minWidth: compact ? 160 : LeftPanelWidth.range.lowerBound,
                                   idealWidth: compact ? 190 : LeftPanelWidth.standard,
                                   maxWidth: compact ? 240 : .infinity)
                            .background { if !compact { LeftPanelWidthKeeper() } }
                    }
                    if workspaceManager.showCenter {
                        workspaceCenter.frame(minWidth: 400, idealWidth: 500)
                    }
                    if workspaceManager.terminalVisible {
                        rightPane.frame(minWidth: terminalMinimum, idealWidth: max(500, terminalMinimum))
                            .background(RightPanelWidthKeeper(centerVisible: workspaceManager.showCenter))
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
        .onReceive(NotificationCenter.default.publisher(for: .exportPDFRequested)) { _ in
            exportPDF()
        }
        .onChange(of: workspaceManager.activeTabIndex) { index in
            guard workspaceManager.openTabs.indices.contains(index) else { return }
            let tab = workspaceManager.openTabs[index]
            switch tab.kind {
            case .file, .image, .pdf, .archive, .deployments, .discussions, .workflow, .changeReview, .terminal, .browser, .data, .prototype, .uiStudio, .qa:
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
                workspaceManager.layout.navigatorTab = .git
                switch item {
                case .issue: workspaceManager.layout.gitSection = .issues
                case .pullRequest: workspaceManager.layout.gitSection = .pullRequests
                case .run: workspaceManager.layout.gitSection = .actions
                }
                workspaceManager.terminalVisible = true
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
        .sheet(isPresented: Binding(
            get: { workspaceManager.projectOperations?.panelVisible ?? false },
            set: { workspaceManager.projectOperations?.panelVisible = $0 })) {
            if let store = workspaceManager.projectOperations { ProjectOperationConsole(store: store) }
        }
        .sheet(item: Binding(
            get: { workspaceManager.projectOperations?.editRequest },
            set: { workspaceManager.projectOperations?.editRequest = $0 })) { request in
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
            let controlWidth = 32 * min(1.5, max(1, appFontScale))
            HStack(spacing: 6) {
                headerButton("sidebar.leading", help: "Navigation (⌘1)", width: controlWidth) {
                    workspaceManager.toggleNavigation()
                }
                headerButton("rectangle", help: "Workspace content", width: controlWidth,
                             selected: workspaceManager.showCenter) {
                    workspaceManager.toggleCenter()
                }
                Button { workspaceManager.toggleAIConsole() } label: {
                    Group {
                        if appFontScale >= 1.7 { Image(systemName: "terminal") }
                        else { Label("Agents", systemImage: "terminal") }
                    }
                    .uiFont(size: 12, weight: .semibold)
                    .fixedSize()
                    .foregroundColor(workspaceManager.terminalVisible && !workspaceManager.showTOC ? palette.blue : palette.text)
                    .padding(.horizontal, 9)
                    .frame(height: controlWidth)
                    .background(workspaceManager.terminalVisible && !workspaceManager.showTOC ? palette.bgActive : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Agents (⌘3): terminals for Claude Code, Codex, Cline, Copilot, Antigravity, or a shell")
                .accessibilityLabel("Agents (⌘3)")
                headerDivider
                ForEach(WorkspaceArea.allCases) { area in
                    headerButton(area.symbol, help: area.rawValue, width: controlWidth,
                                 selected: workspaceManager.layout.workspaceArea == area) {
                        activate(area)
                    }
                }
                headerDivider
                HStack(spacing: 6) {
                    if let projectKey {
                        ProjectColorButton(store: projectColors, projectKey: projectKey)
                            .buttonStyle(.plain)
                            .frame(width: 22 * min(1.5, max(1, appFontScale)))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(workspaceFolderName ?? "MarkView")
                            .uiFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !MarkViewApp.version.isEmpty {
                            Text("MarkView v\(MarkViewApp.version)")
                                .uiFont(size: 10, weight: .medium)
                                .foregroundColor(palette.text)
                                .lineLimit(1)
                        }
                    }
                    .help(WindowTitle.text(version: MarkViewApp.version, folderName: workspaceFolderName))
                    .accessibilityLabel("\(workspaceFolderName.map { "Project: \($0), " } ?? "")MarkView version \(MarkViewApp.version)")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(width: compact ? min(230, geometry.size.width * 0.26) : min(300, geometry.size.width * 0.3),
                       height: controlWidth, alignment: .leading)
                .background(palette.bgActive)
                .cornerRadius(7)
                Spacer(minLength: 4)
                AgentActivityChip(monitor: workspaceManager.agentActivity, workspaceManager: workspaceManager, compact: compact)
                // Claude Code and Codex quota, whatever the workspace shows and whether or not Agents is open (AC-6, AC-7).
                AgentUsageBar()
                if workspaceManager.layout.workspaceArea == .files && hasDocumentContents {
                    headerButton("list.bullet.indent", help: "Contents of this tab (⌘2): headings, structure, page, entries, facts", width: controlWidth,
                                 selected: workspaceManager.terminalVisible && workspaceManager.layout.navigatorTab == .contents) {
                        workspaceManager.toggleContext()
                    }
                }
                if workspaceManager.rootNode != nil {
                    headerButton("server.rack", help: "Build & Deployment (⌃⌘D): commands, environments, state and logs", width: controlWidth,
                                 selected: { if case .deployments? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openDeployments()
                    }
                    // In a narrow window it moves to the "…" menu (Operations → Workflow…), like Cycle Time below.
                    if !compact {
                        headerButton("arrow.triangle.branch", help: "Workflow: this project's statuses, transitions and processes for features and bugs", width: controlWidth,
                                     selected: { if case .workflow? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                            workspaceManager.openWorkflow()
                        }
                    }
                    // In a narrow window it moves to the "…" menu (Operations → End-to-End QA…), like Workflow above.
                    if !compact {
                        headerButton("checklist.checked", help: "End-to-End QA (⌘8): scenarios written from a goal, edited as a graph and checked branch by branch", width: controlWidth,
                                     selected: { if case .qa? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                            workspaceManager.openQA()
                        }
                    }
                    headerButton("bubble.left.and.text.bubble.right", help: "Discussions (⌃⌘I): think an idea through before it is a feature", width: controlWidth,
                                 selected: { if case .discussions? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openDiscussions()
                    }
                    // In a narrow window it moves to the "…" menu so the bar keeps its room for the usage chips.
                    if !compact {
                        headerButton("timer", help: "Project Cycle Time: how long features and bugs wait, take and finish, measured from the workflow", width: controlWidth,
                                     selected: showCycleTime) {
                            showCycleTime = true
                        }
                    }
                    // REQ-011: UI Studio one click away, not only in the AI tools menu.
                    headerButton("macwindow.and.cursorarrow", help: "UI Studio (⌘7): the project's real interface with simulated data — select, ask, change", width: controlWidth,
                                 selected: { if case .uiStudio? = workspaceManager.activeTab?.kind { return true } else { return false } }()) {
                        workspaceManager.openUIStudio()
                    }
                }
                browserMenu.frame(width: controlWidth, height: controlWidth)
                headerButton("magnifyingglass", help: "Search project (⌘⇧K)", width: controlWidth) {
                    workspaceManager.showGlobalSearch = true
                }
                newMenu.frame(width: controlWidth, height: controlWidth)
                AssistantToolbarMenu(workspaceManager: workspaceManager, compact: compact)
                    .frame(maxWidth: compact ? controlWidth : 230)
                XRayModelToolbarMenu(workspaceManager: workspaceManager, compact: compact)
                    .frame(maxWidth: compact ? controlWidth : 170)
                if let operations = workspaceManager.projectOperations {
                    ProjectDeployButton(store: operations)
                }
                if compact {
                    Menu {
                        Button("Open X-Ray") { workspaceManager.openArchitecture() }
                            .disabled(workspaceManager.rootNode == nil)
                        Button("Project Cycle Time…") { showCycleTime = true }
                            .disabled(workspaceManager.rootNode == nil)
                        AIToolsMenu(workspaceManager: workspaceManager)
                        Button("Theme…") { workspaceManager.theme.showsPicker = true }
                        Button("DDE Settings…") { DDESettingsWindow.show(workspace: workspaceManager) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: controlWidth, height: controlWidth)
                    }
                    .menuIndicator(.hidden)
                    .help("More window actions")
                    .accessibilityLabel("More window actions")
                    .themePicker(workspaceManager.theme)
                } else {
                    AIToolsMenu(workspaceManager: workspaceManager)
                    headerButton("paintpalette", help: "Theme (⇧⌘T)", width: controlWidth) {
                        workspaceManager.theme.showsPicker.toggle()
                    }
                    .themePicker(workspaceManager.theme)
                }
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

    private func headerButton(_ symbol: String, help: String, width: CGFloat,
                              selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .uiFont(size: 14)
                .foregroundColor(selected ? palette.blue : palette.text)
                .frame(width: width, height: width)
                .background(selected ? palette.bgActive : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var browserMenu: some View {
        Menu {
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
            Image(systemName: "globe")
        }
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
            Image(systemName: "plus.square")
        }
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

    private var hasDocumentContents: Bool {
        workspaceManager.activeTab != nil
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
                case .file, .image, .pdf, .archive, .deployments, .discussions, .workflow, .changeReview, .terminal, .browser, .prototype, .uiStudio, .qa: return true
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
        workspaceManager.projectOperations?.window = hostWindow
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

    /// The screen of a window with no file open: action tiles over an animated backdrop (`WelcomeScreen`). What each tile does is
    /// decided here, with the same calls as the menus and the search commands.
    private var welcomeView: some View {
        WelcomeScreen(projectName: workspaceManager.rootNode.map { WindowTitle.folderName(of: $0.url) },
                      isGitRepo: workspaceManager.gitClient.isGitRepo,
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
        case .git:
            workspaceManager.layout.workspaceArea = .work
            workspaceManager.layout.workSection = .git
        case .deployments: workspaceManager.openDeployments()
        case .workflow: workspaceManager.openWorkflow()
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

/// Toolbar menu choosing the assistant CLI and its model for this window's project (BUG-021);
/// other projects keep theirs. The X-Ray model is chosen apart, in `XRayModelToolbarMenu`.
/// A window showing a single file edits the defaults, as DDE Settings does.
struct AssistantToolbarMenu: View {
    let workspaceManager: WorkspaceManager
    var compact = false
    /// Model lists per tool; Codex's is read from disk, so off the main thread.
    @State private var options: [CLITool: [AIModelOption]] = [:]
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

    var body: some View {
        let _ = refresh
        Menu {
            if availability[tool] == false {
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
                ForEach(options[tool] ?? [AIModelOption(id: model.wrappedValue, name: model.wrappedValue.isEmpty ? "Default" : model.wrappedValue, detail: "")]) {
                    Text($0.name).tag($0.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if compact {
                Image(systemName: availability[tool] == false ? "exclamationmark.triangle" : "cpu")
            } else {
                Label(AIAssistantPreferences.summary(tool: tool, model: model.wrappedValue),
                      systemImage: availability[tool] == false ? "exclamationmark.triangle" : "cpu")
            }
        }
        .help(availability[tool] == false ? "Assistant unavailable. Set its CLI path in Settings." :
              (workspaceManager.aiProject == nil ? "Default assistant and model" : "Assistant and model for this project")
              + " — the AI terminal, features and research; X-Ray has its own model")
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh += 1 }
        .task(id: tool) {
            let current = tool
            availability[current] = await CLIToolLocator.resolveThorough(current) != nil
            guard options[current] == nil else { return }
            let loaded = await Self.loadOptions(for: current)
            // Keep a model saved earlier selectable, but say that the CLI does not list it
            // (Codex rejects models its catalog dropped or the account cannot use).
            let id = model.wrappedValue
            options[current] = loaded.contains { $0.id == id } ? loaded
                : loaded + [AIModelOption(id: id, name: "\(id) — not in \(current.displayName)'s list", detail: "")]
        }
    }
}

extension AssistantToolbarMenu {
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

/// Toolbar menu for the X-Ray model, apart from the assistant's model: X-Ray, operations discovery,
/// filters and explanations write large structured answers, where a fast model matters more than
/// raw capability. The fast default is marked as recommended.
struct XRayModelToolbarMenu: View {
    let workspaceManager: WorkspaceManager
    var compact = false
    @State private var options: [CLITool: [AIModelOption]] = [:]
    @State private var refresh = 0

    private var choice: AssistantChoice { AssistantChoice(project: workspaceManager.aiProject) }
    private var tool: CLITool { choice.tool }
    private var model: Binding<String> {
        let tool = tool
        return Binding(get: { choice.xrayModel(for: tool) }, set: { choice.setXRayModel($0, for: tool) })
    }

    var body: some View {
        let _ = refresh
        let recommended = AIAssistantPreferences.defaultXRayModel(for: tool)
        let listed = (options[tool] ?? []).filter { !$0.id.isEmpty }
        Menu {
            Picker("X-Ray model", selection: model) {
                Text("Same as the assistant's model").tag("")
                ForEach(listed) { option in
                    Text(option.id == recommended ? "\(option.name) (Recommended)" : option.name).tag(option.id)
                }
                if !model.wrappedValue.isEmpty, !listed.contains(where: { $0.id == model.wrappedValue }) {
                    Text(model.wrappedValue).tag(model.wrappedValue)
                }
            }
            .pickerStyle(.inline)
            Text("Used by X-Ray, operations discovery, filters and explanations.")
        } label: {
            if compact {
                Image(systemName: "viewfinder")
            } else {
                Label("X-Ray · " + (model.wrappedValue.isEmpty ? "assistant's model" : model.wrappedValue),
                      systemImage: "viewfinder")
            }
        }
        .help((workspaceManager.aiProject == nil ? "Default model" : "This project's model")
              + " for X-Ray, operations discovery, filters and explanations; a fast one is recommended")
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in refresh += 1 }
        .task(id: tool) {
            let current = tool
            guard options[current] == nil else { return }
            options[current] = await AssistantToolbarMenu.loadOptions(for: current)
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
            Section("Prototype") {
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
            Section("Operations") {
                Button("Deployments…") { workspaceManager.openDeployments() }
                Button("Discussions…") { workspaceManager.openDiscussions() }
                    .disabled(workspaceManager.rootNode == nil)
                Button("Workflow…") { workspaceManager.openWorkflow() }
                    .disabled(workspaceManager.rootNode == nil)
                Button("End-to-End QA…") { workspaceManager.openQA() }
                    .disabled(workspaceManager.rootNode == nil)
            }
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
