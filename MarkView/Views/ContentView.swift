import SwiftUI
import UniformTypeIdentifiers

// Focused value so menu commands target the active window's WorkspaceManager
struct FocusedWorkspaceKey: FocusedValueKey {
    typealias Value = WorkspaceManager
}
extension FocusedValues {
    var workspaceManager: WorkspaceManager? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var workspaceManager = WorkspaceManager()

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
                    EditorView()
                        .environmentObject(workspaceManager)
                        .environmentObject(themeManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Matrix-style diagnostics status bar
                    DiagnosticsBarView()
                        .environmentObject(workspaceManager)
                } else {
                    welcomeView
                }
            }
            .frame(minWidth: 400)

            // MARK: - Right Panel: TOC or Semantic
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

                // Toggle Semantic Panel (vs TOC)
                Button(action: { workspaceManager.showSemanticPanel.toggle() }) {
                    Image(systemName: workspaceManager.showSemanticPanel ? "brain.head.profile" : "brain")
                }
                .help("Toggle Semantic Panel")

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
        .sheet(isPresented: graphCreatorSheetBinding) {
            GraphCreatorSheet(
                workspaceManager: workspaceManager,
                isPresented: graphCreatorSheetBinding,
                preselectedType: workspaceManager.pendingGraphCreatorType ?? "architecture"
            )
        }
        .onAppear {
            // Check pending URLs from various sources (Open Folder menu, Finder Open With)
            let url = MarkViewApp.pendingFolderURL ?? MarkViewApp.pendingOpenURL
            if let url = url {
                MarkViewApp.pendingFolderURL = nil
                MarkViewApp.pendingOpenURL = nil
                WorkspaceManager.debugLog("onAppear: opening \(url.path)")
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { workspaceManager.openFolder(url) } else { workspaceManager.openFile(url) }
                return
            }
            // Delayed check: application:open: may fire AFTER onAppear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak workspaceManager] in
                guard let wm = workspaceManager, wm.rootNode == nil,
                      let url = MarkViewApp.pendingOpenURL else { return }
                MarkViewApp.pendingOpenURL = nil
                WorkspaceManager.debugLog("onAppear delayed: opening \(url.path)")
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { wm.openFolder(url) } else { wm.openFile(url) }
            }
            // Close this window later if it never got content (SwiftUI ghost window)
            closeIfEmpty()
        }
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

    /// Close the empty "ghost" window that SwiftUI creates for document types.
    /// Only closes windows with no content; windows with loaded folders are kept.
    private func closeIfEmpty() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak workspaceManager] in
            guard let wm = workspaceManager,
                  wm.rootNode == nil,
                  wm.openTabs.isEmpty else { return }
            // This window never got content — it's a ghost. Close it.
            for window in NSApp.windows where window.isVisible {
                // Find our window by checking if it's not the key/main window
                // and has the default title
                if window.title.contains("MarkView") && window != NSApp.keyWindow && window != NSApp.mainWindow {
                    WorkspaceManager.debugLog("Closing ghost window")
                    window.close()
                    return
                }
            }
        }
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

            HStack(spacing: 16) {
                Button("Open File...") { openFile() }
                    .buttonStyle(.borderedProminent)
                    .tint(VSDark.blue)
                Button("Open Folder...") { openFolder() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSDark.bg)
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdownText, .plainText]
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
                    } else if url.pathExtension.lowercased() == "md" {
                        workspaceManager.openFile(url)
                    }
                }
            }
        }
        return true
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .environmentObject(WorkspaceManager())
}
