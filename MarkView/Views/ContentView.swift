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
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.appFontScale) private var appFontScale
    @Environment(\.openWindow) private var openWindow
    var windowSessionID = UUID()
    @StateObject private var workspaceManager = WorkspaceManager()
    @StateObject private var changeReview = ProjectChangeReview()
    @State private var showFolderPicker = false
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
    @State private var showGitHubDetail = true

    var body: some View {
        let _ = themeToken // force re-render of entire tree on theme change
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
                                   maxWidth: compact ? 240 : LeftPanelWidth.range.upperBound)
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
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            workspaceManager.themeVersion += 1
        }
        .onChange(of: workspaceManager.activeTabIndex) { index in
            guard workspaceManager.openTabs.indices.contains(index) else { return }
            let tab = workspaceManager.openTabs[index]
            switch tab.kind {
            case .file, .image, .terminal:
                lastFilesTab = tab.id
                workspaceManager.layout.workspaceArea = .files
            case .architecture, .insight:
                workspaceManager.layout.workspaceArea = .projectMap
            case .github:
                showGitHubDetail = true
                workspaceManager.layout.workSection = .git
                workspaceManager.layout.workspaceArea = .work
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
        .sheet(isPresented: graphCreatorSheetBinding) {
            GraphCreatorSheet(
                workspaceManager: workspaceManager,
                isPresented: graphCreatorSheetBinding,
                preselectedType: workspaceManager.pendingGraphCreatorType ?? "architecture"
            )
        }
        .sheet(isPresented: $workspaceManager.showGlobalSearch) {
            SharedSearchView()
                .environmentObject(workspaceManager)
                .environmentObject(themeManager)
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
        .onChange(of: hostWindow) { _ in
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
                headerDivider
                ForEach(WorkspaceArea.allCases) { area in
                    headerButton(area.symbol, help: area.rawValue, width: controlWidth,
                                 selected: workspaceManager.layout.workspaceArea == area) {
                        activate(area)
                    }
                }
                Button { workspaceManager.toggleAIConsole() } label: {
                    Label("Terminal", systemImage: "terminal")
                        .uiFont(size: 12, weight: .semibold)
                        .foregroundColor(workspaceManager.terminalVisible && !workspaceManager.showTOC ? VSDark.blue : VSDark.text)
                        .padding(.horizontal, 9)
                        .frame(height: controlWidth)
                        .background(workspaceManager.terminalVisible && !workspaceManager.showTOC ? VSDark.bgActive : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Assistant terminal (⌘3): Claude Code, Codex, Cline, Copilot, or shell")
                .accessibilityLabel("Terminal (⌘3)")
                headerDivider
                HStack(spacing: 6) {
                    if let projectKey {
                        ProjectColorButton(store: projectColors, projectKey: projectKey)
                            .buttonStyle(.plain)
                            .frame(width: 22 * min(1.5, max(1, appFontScale)))
                    }
                    Text(workspaceFolderName ?? "MarkView")
                        .uiFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(workspaceFolderName ?? "MarkView")
                        .accessibilityLabel(workspaceFolderName.map { "Project: \($0)" } ?? "MarkView")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(width: compact ? min(230, geometry.size.width * 0.26) : min(300, geometry.size.width * 0.3),
                       height: controlWidth, alignment: .leading)
                .background(VSDark.bgActive)
                .cornerRadius(7)
                Spacer(minLength: 4)
                if workspaceManager.layout.workspaceArea == .files && hasDocumentContents {
                    headerButton("list.bullet.indent", help: "Document contents (⌘2)", width: controlWidth,
                                 selected: workspaceManager.terminalVisible && workspaceManager.showTOC) {
                        workspaceManager.toggleContext()
                    }
                }
                headerButton("magnifyingglass", help: "Search project (⌘⇧K)", width: controlWidth) {
                    workspaceManager.showGlobalSearch = true
                }
                newMenu.frame(width: controlWidth, height: controlWidth)
                AssistantToolbarMenu(workspaceManager: workspaceManager, compact: compact)
                    .frame(maxWidth: compact ? controlWidth : 230)
                if compact {
                    Menu {
                        Button("Open X-Ray") { workspaceManager.openArchitecture() }
                            .disabled(workspaceManager.rootNode == nil)
                        AIToolsMenu(workspaceManager: workspaceManager)
                        Button("Toggle Theme") { themeManager.toggleTheme() }
                        Button("DDE Settings…") { DDESettingsWindow.show(workspace: workspaceManager) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: controlWidth, height: controlWidth)
                    }
                    .menuIndicator(.hidden)
                    .help("More window actions")
                    .accessibilityLabel("More window actions")
                } else {
                    AIToolsMenu(workspaceManager: workspaceManager)
                    headerButton(themeManager.effectiveTheme == .dark ? "sun.max" : "moon",
                                 help: "Light / dark theme", width: controlWidth) {
                        themeManager.toggleTheme()
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: min(70, 44 * max(1, appFontScale)))
        .background(VSDark.bgSidebar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(VSDark.border)
            .frame(width: 1, height: 22 * min(1.5, max(1, appFontScale)))
            .padding(.horizontal, 3)
    }

    private func headerButton(_ symbol: String, help: String, width: CGFloat,
                              selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .uiFont(size: 14)
                .foregroundColor(selected ? VSDark.blue : VSDark.text)
                .frame(width: width, height: width)
                .background(selected ? VSDark.bgActive : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
        Group {
            if workspaceManager.showTOC && hasDocumentContents {
                TOCView(layout: workspaceManager.layout, showTabs: false)
                    .environmentObject(workspaceManager)
            } else {
                ModuleExplorerView().environmentObject(workspaceManager)
            }
        }
    }

    private var hasDocumentContents: Bool {
        guard let tab = workspaceManager.activeTab, case .file = tab.kind else { return false }
        return ["md", "markdown"].contains(tab.url.pathExtension.lowercased())
    }

    private var workspaceCenter: some View {
        ZStack {
            filesCenter
                .opacity(workspaceManager.layout.workspaceArea == .work ? 0 : 1)
                .allowsHitTesting(workspaceManager.layout.workspaceArea != .work)
            if workspaceManager.layout.workspaceArea == .work {
                workCenter
            }
        }
        .background(VSDark.bg)
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
            if !workspaceManager.openTabs.isEmpty {
                TabBarView().environmentObject(workspaceManager)
            }
            if workspaceManager.openTabs.indices.contains(workspaceManager.activeTabIndex) {
                ZStack {
                    EditorView()
                        .environmentObject(workspaceManager)
                        .environmentObject(themeManager)
                    let activeTab = workspaceManager.openTabs[workspaceManager.activeTabIndex]
                    if case .terminal(let id) = activeTab.kind,
                       let session = workspaceManager.terminalSession(id) {
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

    private var workCenter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([WorkSection.features, .git]) { section in
                    Button {
                        workspaceManager.layout.workSection = section
                        if section == .git { showGitHubDetail = false }
                    } label: {
                        Label(section.rawValue, systemImage: section.symbol)
                            .uiFont(size: 12, weight: workspaceManager.layout.workSection == section ? .semibold : .regular)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(workspaceManager.layout.workSection == section ? VSDark.bgActive : Color.clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(section.rawValue)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(VSDark.bgSidebar)
            Divider()
            switch workspaceManager.layout.workSection {
            case .features:
                VStack(spacing: 0) {
                    if let feature = workspaceManager.features.active {
                        HandoffPanelView(feature: feature).environmentObject(workspaceManager)
                    }
                    FeaturePanelView(store: workspaceManager.features, layout: workspaceManager.layout)
                        .environmentObject(workspaceManager)
                }
            case .git:
                if showGitHubDetail, let tab = workspaceManager.activeTab,
                   case .github(let item) = tab.kind {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Back to Git") { showGitHubDetail = false }
                            Spacer()
                            Text(item.title).lineLimit(1)
                        }
                        .padding(8)
                        GitHubTabView(item: item)
                            .environmentObject(workspaceManager)
                            .id(tab.id)
                    }
                } else {
                    GitView(git: workspaceManager.gitClient, workspaceManager: workspaceManager)
                }
            case .terminal:
                ModuleExplorerView().environmentObject(workspaceManager)
            }
            if workspaceManager.rootNode != nil {
                Divider()
                ProjectChangeReviewBar(review: changeReview)
                    .environmentObject(workspaceManager)
            }
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
                case .file, .image, .terminal: return true
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
            workspaceManager.layout.workSection = .features
        }
    }

    /// Title, proxy icon and project color follow the workspace root: every way of opening,
    /// restoring or closing a folder changes `rootNode`.
    private func updateWindowIdentity() {
        let root = workspaceManager.rootNode?.url
        workspaceFolderName = root.map(WindowTitle.folderName(of:))
        hostWindow?.title = WindowTitle.text(version: MarkViewApp.version, folderName: workspaceFolderName)
        hostWindow?.titleVisibility = .hidden
        hostWindow?.titlebarAppearsTransparent = true
        hostWindow?.styleMask.insert(.fullSizeContentView)
        hostWindow?.isMovableByWindowBackground = true
        hostWindow?.representedURL = root
        projectKey = workspaceManager.projectFolder.map(ProjectColor.projectKey(for:))
        if let projectKey { projectColors.assignIfNeeded(key: projectKey) }
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
        ScrollView {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .uiFont(size: 48)
                .foregroundColor(VSDark.blue)

            Text("Make sense of your project.")
                .uiFont(size: 24, weight: .light)
                .foregroundColor(VSDark.textBright)

            Text("Files · Project Map · Work")
                .uiFont(size: 13)
                .foregroundColor(VSDark.textDim)

            if workspaceManager.rootNode != nil {
                // A folder is open but no document yet.
                HStack(spacing: 16) {
                    Button { workspaceManager.showAIConsole() } label: {
                        Label("Open Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        workspaceManager.intake = IntakeRequest(kind: .feature)
                        workspaceManager.layout.workspaceArea = .work
                    } label: { Label("New Feature…", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    Button(action: { workspaceManager.openArchitecture() }) {
                        Label("Open X-Ray", systemImage: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("4", modifiers: [.command])
                    Button { openFile() } label: { Label("Open File...", systemImage: "doc") }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 8)
                Text("Start a specification in Work. Resume a handoff in Files.")
                    .uiFont(size: 11)
                    .foregroundColor(VSDark.textDim)
                HandoffStartList(store: workspaceManager.features)
                    .environmentObject(workspaceManager)
                    .frame(maxWidth: 700)
            } else {
                HStack(spacing: 16) {
                    Button("Open Folder...") { openFolder() }
                        .buttonStyle(.borderedProminent)
                        .tint(VSDark.blue)
                    Button("Open File...") { openFile() }
                        .buttonStyle(.bordered)
                    // Start a Project from Scratch (REQ-001): no folder needed.
                    Button("New Project...") { workspaceManager.newProject = NewProjectRequest() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 8)
                ProjectDraftList(drafts: ProjectDraftStore.shared) { id in
                    workspaceManager.newProject = NewProjectRequest(resume: id)
                }
                .padding(.top, 12)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent projects").uiFont(size: 13, weight: .semibold)
                    ForEach(UserDefaults.standard.stringArray(forKey: WorkspaceManager.recentProjectsKey) ?? [], id: \.self) { path in
                        Button {
                            workspaceManager.openFolder(URL(fileURLWithPath: path, isDirectory: true))
                        } label: {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .help(path)
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    let workspaceManager: WorkspaceManager
    var compact = false
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
    @State private var availability: [CLITool: Bool] = [:]

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
            if availability[tool] == false {
                Text("Assistant unavailable. Set its CLI path in Settings.")
                Button("Open AI Settings…") { DDESettingsWindow.show(workspace: workspaceManager) }
                Button("Check Again") {
                    let selected = tool
                    Task { availability[selected] = await CLIToolLocator.resolveThorough(selected) != nil }
                }
                Divider()
            }
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
            if compact {
                Image(systemName: availability[tool] == false ? "exclamationmark.triangle" : "cpu")
            } else {
                Label(AIAssistantPreferences.summary(tool: tool, model: model.wrappedValue),
                      systemImage: availability[tool] == false ? "exclamationmark.triangle" : "cpu")
            }
        }
        .help(availability[tool] == false ? "Assistant unavailable. Set its CLI path in Settings." :
              "Assistant and model for every AI feature (X-Ray, Explain, filters, AI terminal)")
        .task(id: backend) {
            let current = tool
            availability[current] = await CLIToolLocator.resolveThorough(current) != nil
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
