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
    @State private var showGraphCreator = false
    @State private var graphPreselectedType = "architecture"

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

            // MARK: - Right Panel: TOC or Semantic (no max width — can expand fully)
            if workspaceManager.showTOC {
                if workspaceManager.showSemanticPanel {
                    ModuleExplorerView()
                        .environmentObject(workspaceManager)
                        .frame(minWidth: 260, idealWidth: 380)
                } else {
                    TOCView()
                        .environmentObject(workspaceManager)
                        .frame(minWidth: 200, idealWidth: 250)
                }
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
                Button(action: { showGraphCreator = true }) {
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
                        Button("🏗 System Architecture") { triggerAITool("architecture") }
                        Button("🔀 Data Flow") { triggerAITool("dataflow") }
                        Button("⚙ Pipeline") { triggerAITool("pipeline") }
                        Button("☁ Deployment") { triggerAITool("deployment") }
                        Button("↔ Sequence") { triggerAITool("sequence") }
                        Button("◆ Entity-Relationship") { triggerAITool("er") }
                    }
                    Section("Analysis") {
                        Button("🔍 Constructive Critic") { triggerAITool("critic") }
                        Button("🌐 Deep Research") { triggerAITool("research") }
                        Button("📋 Full Codebase Audit") { triggerAITool("audit") }
                        Button("🗂 Code Structure Map") { triggerAITool("codemap") }
                        Button("📚 Generate Full Documentation") { triggerAITool("fulldocs") }
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
        .onReceive(NotificationCenter.default.publisher(for: .openInActiveWindow)) { notification in
            guard let url = notification.object as? URL else { return }
            // Only one ContentView should handle — prefer the one with no folder open
            let hasFolder = workspaceManager.rootNode != nil
            let otherEmptyExists = NSApp.windows.count > 1
            if hasFolder && otherEmptyExists { return }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                workspaceManager.openFolder(url)
            } else {
                workspaceManager.openFile(url)
            }
        }
        .focusedSceneValue(\.workspaceManager, workspaceManager)
        .sheet(isPresented: $showGraphCreator) {
            GraphCreatorSheet(workspaceManager: workspaceManager, isPresented: $showGraphCreator, preselectedType: graphPreselectedType)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("triggerAITool"))) { notification in
            if let tool = notification.object as? String {
                triggerAITool(tool)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openGraphCreator"))) { notification in
            graphPreselectedType = notification.object as? String ?? "architecture"
            showGraphCreator = true
        }
        .onAppear {
            // Check if a new window was requested with a pending folder
            if let url = MarkViewApp.pendingFolderURL {
                MarkViewApp.pendingFolderURL = nil
                workspaceManager.openFolder(url)
            }
        }
    }

    private var themeToken: Int { workspaceManager.themeVersion }

    private func triggerAITool(_ tool: String) {
        guard let engine = workspaceManager.aiConsoleEngine else {
            // No workspace — can't run AI tools
            return
        }

        // Diagrams go through GraphCreator sheet
        let diagramTypes = ["architecture","dataflow","pipeline","deployment","sequence","er"]
        if diagramTypes.contains(tool) {
            graphPreselectedType = tool
            showGraphCreator = true
            return
        }

        // Get current file content if any
        var content = ""
        if workspaceManager.activeTabIndex >= 0,
           workspaceManager.activeTabIndex < workspaceManager.openTabs.count {
            content = String(workspaceManager.openTabs[workspaceManager.activeTabIndex].content.prefix(15000))
        }

        let fileName = workspaceManager.activeTabIndex >= 0 && workspaceManager.activeTabIndex < workspaceManager.openTabs.count
            ? workspaceManager.openTabs[workspaceManager.activeTabIndex].url.lastPathComponent : "project"

        switch tool {
        case "audit":
            engine.sendMessage(AIConsoleEngine.codebaseAuditPrompt)
        case "fulldocs":
            engine.sendMessage(AIConsoleEngine.fullDocumentationPrompt)
        case "codemap":
            engine.sendMessage("""
            Scan the current directory recursively and generate a VISUAL CODE STRUCTURE MAP.

            Create a file called "code-structure-map.md" with the following sections:

            # Code Structure Map

            ## Directory Tree
            Show the full directory tree with annotations for each folder/file purpose.
            Use indentation and icons:
            📁 folder — description
            📄 file — description
            ⚙️ config file — what it configures
            🧪 test file — what it tests
            🐳 Docker — what it builds
            📦 package manifest — dependencies

            ## Architecture Layers Diagram
            ```mermaid
            %%INTERACTIVE
            graph TD
            subgraph "Entry Points"
            ...
            end
            subgraph "Application Layer"
            ...
            end
            subgraph "Domain / Business Logic"
            ...
            end
            subgraph "Data Access / Persistence"
            ...
            end
            subgraph "Infrastructure / External"
            ...
            end
            ```
            Show ALL files/modules as nodes grouped by architectural layer.
            Connect them by actual import/dependency relationships found in code.

            ## Configuration Map
            Table showing:
            | Config File | Purpose | Key Settings | Environment Vars | Notes |
            For every config file found (.env, .yaml, .json, .toml, Dockerfile, CI files, etc.)

            ## Dependency Graph
            ```mermaid
            %%INTERACTIVE
            graph LR
            ```
            Show package/module dependencies — what imports what, what depends on what.
            Use subgraph for internal vs external dependencies.

            ## Entry Points
            List all entry points:
            - Main app entry
            - API routes/endpoints
            - CLI commands
            - Background workers
            - Scheduled tasks
            - Event handlers
            For each: file path, purpose, how it's triggered.

            ## Data Flow
            ```mermaid
            %%INTERACTIVE
            graph TD
            ```
            Show how data flows through the system:
            - User input → API → Service → DB
            - Events → Queue → Worker → Storage
            - Cron → Batch → External API

            ## File Statistics
            | Metric | Value |
            |--------|-------|
            | Total files | ... |
            | Source files | ... |
            | Test files | ... |
            | Config files | ... |
            | Languages | ... |
            | Largest files | top 10 |
            | Most connected modules | top 10 |

            Be thorough — scan EVERY file. Use %%INTERACTIVE in mermaid blocks for interactive diagrams.
            """)

        case "critic":
            engine.sendMessage("""
            You are a CONSTRUCTIVE CRITIC. Analyze the current workspace documentation thoroughly.
            Create a file "review-\(fileName).md" with: Summary, Strengths, Issues (with severity/location/fix), Missing Content, Consistency Issues, Action Items (P1/P2/P3), Overall Score 1-10.
            Also create "tasks/review-tasks-\(fileName).md" with action items as checkboxes.
            \(content.isEmpty ? "Scan all files in the current directory." : "Document:\n\(content)")
            """)
        case "research":
            engine.sendMessage("""
            You are a DEEP RESEARCHER. Analyze the current workspace and identify all external APIs, technologies, dependencies.
            For each, search online for: current status, best practices, known issues, alternatives.
            Create "research-\(fileName).md" with detailed findings and recommendations (Keep/Replace/Update).
            \(content.isEmpty ? "Scan all files in the current directory." : "Document:\n\(content)")
            """)
        default:
            break
        }

        // Switch to AI tab
        workspaceManager.showTOC = true
        workspaceManager.showSemanticPanel = true
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
            if let root = workspaceManager.rootNode?.url {
                workspaceManager.rootNode = FileNode.buildTree(from: root)
            }
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
            // Build prompt from semantic DB
            guard let engine = workspaceManager.aiConsoleEngine else {
                NSLog("[Docs] No AI engine")
                return
            }

            // Switch to AI tab
            workspaceManager.showTOC = true
            workspaceManager.showSemanticPanel = true

            let prompt = buildDocGenPrompt(outputDir: outputURL)
            engine.sendMessage(prompt)
        }
    }

    private func buildDocGenPrompt(outputDir: URL) -> String {
        var prompt = """
        Create a comprehensive documentation structure in the folder: \(outputDir.path)

        Generate the following structure based on the project files in this workspace:

        1. README.md — project overview with links to all sections
        2. architecture/ folder:
           - overview.md — high-level architecture with mermaid diagrams
           - components.md — all components/modules listed with descriptions
           - data-flow.md — how data flows between components
        3. modules/ folder — one .md file per major component/service, with:
           - Description, responsibilities
           - Dependencies (links to other module files)
           - API/interfaces
           - Configuration
        4. decisions/ folder:
           - ADR-001.md (and more) — key architectural decisions
        5. guides/ folder:
           - getting-started.md
           - deployment.md

        Requirements:
        - Every file must use proper markdown with headings, lists, code blocks
        - Cross-reference between files using relative markdown links: [Component X](../modules/component-x.md)
        - Include mermaid diagrams where appropriate (architecture overview, data flow)
        - Be thorough and detailed — this should be production-quality documentation
        - Write in English unless instructed otherwise
        """

        // Add context from semantic DB
        if let db = workspaceManager.semanticDatabase {
            let modules = db.allModules()
            let contentModules = modules.filter { $0.id.hasPrefix("cmod_") }
            if !contentModules.isEmpty {
                prompt += "\n\nExisting components found in workspace (\(contentModules.count)):\n"
                for mod in contentModules.prefix(50) {
                    let symbols = db.symbolsForModule(mod.id)
                    let desc = symbols.first(where: { $0.kind == "component" })?.context ?? ""
                    prompt += "- \(mod.name): \(desc)\n"
                }
            }

            // Add relations
            var relations: [String] = []
            for mod in contentModules.prefix(30) {
                for rel in db.relationsForModule(mod.id) {
                    relations.append("\(mod.name) → \(rel.targetId) (\(rel.type))")
                }
            }
            if !relations.isEmpty {
                prompt += "\nDependencies:\n"
                for rel in relations.prefix(30) { prompt += "- \(rel)\n" }
            }
        }

        return prompt
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
        NotificationCenter.default.post(name: NSNotification.Name("PerformPDFExport"), object: fileName)
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
