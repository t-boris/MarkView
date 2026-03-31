import SwiftUI
import WebKit

/// Module Explorer — structure-first panel with C4/arc42 approach
/// Shows modules, symbols, relations, search, and action buttons
struct ModuleExplorerView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage("layout.moduleExplorerTab") private var selectedTab = 0
    @State private var selectedModuleId: String?
    @State private var searchQuery = ""
    @State private var searchResults: [SemanticDatabase.SearchResult] = []
    @State private var actionResult: ActionEngine.ActionResult?
    @State private var showActionResult = false
    @State private var actionInProgress: String?

    var body: some View {
        let _ = workspaceManager.themeVersion // force re-render on theme change
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                tabBtn("Modules", tag: 0)
                tabBtn("Search", tag: 1)
                tabBtn("Git", tag: 2)
                tabBtn("Diagrams", tag: 3)
                tabBtn("AI", tag: 4)
            }
            .padding(4).background(VSDark.bg)
            Divider().background(VSDark.border)

            // Stats
            if let db = workspaceManager.semanticDatabase {
                let stats = db.getUsageStats()
                HStack(spacing: 6) {
                    Text("\(db.allModules().count) modules")
                        .font(.system(size: 9)).foregroundColor(VSDark.green)
                    Spacer()
                    if stats.totalJobs > 0 {
                        Text("$\(String(format: "%.2f", stats.totalCostDollars))")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textDim)
                    }
                    if workspaceManager.indexingProgress != nil {
                        ProgressView().scaleEffect(0.4)
                        Text(workspaceManager.indexingProgress ?? "")
                            .font(.system(size: 8)).foregroundColor(VSDark.blue).lineLimit(1)
                    } else {
                        Button(action: { workspaceManager.reindexActiveFile() }) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                                .foregroundColor(VSDark.textDim)
                        }.buttonStyle(.plain).help("Re-index current file")
                    }
                }.padding(.horizontal, 10).padding(.vertical, 3).background(VSDark.bgSidebar)
            }

            // Content
            switch selectedTab {
            case 0: modulesTab
            case 1: searchTab
            case 2: GitView(git: workspaceManager.gitClient, workspaceManager: workspaceManager)
            case 3: EntityGraphView().environmentObject(workspaceManager)
            case 4: AIConsoleView().environmentObject(workspaceManager)
            default: modulesTab
            }
        }
        .frame(minWidth: 260, idealWidth: 340)
        .sheet(isPresented: $showActionResult) {
            if let result = actionResult {
                actionResultSheet(result)
            }
        }
    }

    // MARK: - Tab Button
    private func tabBtn(_ title: String, tag: Int) -> some View {
        Button(action: { selectedTab = tag }) {
            Text(title).font(.system(size: 10, weight: selectedTab == tag ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .foregroundColor(selectedTab == tag ? VSDark.textBright : VSDark.textDim)
                .background(selectedTab == tag ? VSDark.bgActive : Color.clear).cornerRadius(4)
        }.buttonStyle(.plain)
    }

    // MARK: - Modules Tab

    private var modulesTab: some View {
        Group {
            if let db = workspaceManager.semanticDatabase {
                let allModules = db.allModules()
                if allModules.isEmpty {
                    VStack { Spacer(); Text("No modules indexed yet").foregroundColor(VSDark.textDim); Spacer() }
                        .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
                } else {
                    let contentModules = allModules.filter { $0.id.hasPrefix("cmod_") }
                    // Deduplicate by name (case-insensitive)
                    var seenNames = Set<String>()
                    let dedupedModules = contentModules.filter { m in
                        let key = m.name.lowercased()
                        if seenNames.contains(key) { return false }
                        seenNames.insert(key)
                        return true
                    }
                    let compTypes = !dedupedModules.isEmpty
                        ? groupComponentsByType(dedupedModules, db: db)
                        : groupFolderModules(allModules, db: db)

                    List {
                        ForEach(compTypes, id: \.type) { group in
                            DisclosureGroup(
                                content: {
                                    ForEach(group.modules, id: \.id) { mod in
                                        moduleRow(mod, db: db)
                                    }
                                },
                                label: {
                                    HStack {
                                        Circle().fill(typeColor(group.type)).frame(width: 8, height: 8)
                                        Text(group.type).font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.text)
                                        Spacer()
                                        Text("\(group.modules.count)").font(.system(size: 9, weight: .medium))
                                            .foregroundColor(VSDark.textBright)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(typeColor(group.type).opacity(0.2)).cornerRadius(6)
                                    }
                                }
                            )
                        }
                    }
                    .listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
                }
            } else {
                VStack { Spacer(); Text("Open a folder").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            }
        }
    }

    // Folder tree: show nested directories
    private func folderTreeRow(_ folder: SemanticDatabase.ModuleInfo, allFolders: [SemanticDatabase.ModuleInfo], db: SemanticDatabase) -> some View {
        let children = allFolders.filter { $0.path.hasPrefix(folder.path + "/") && $0.level == folder.level + 1 }

        return VStack(alignment: .leading, spacing: 0) {
            moduleRow(folder, db: db)
            if selectedModuleId == folder.id && !children.isEmpty {
                ForEach(children, id: \.id) { child in
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 16)
                        moduleRow(child, db: db)
                    }
                }
            }
        }
    }

    struct ComponentTypeGroup {
        let type: String
        let modules: [SemanticDatabase.ModuleInfo]
    }

    private func groupComponentsByType(_ components: [SemanticDatabase.ModuleInfo], db: SemanticDatabase) -> [ComponentTypeGroup] {
        var typeMap: [String: [SemanticDatabase.ModuleInfo]] = [:]

        for comp in components {
            // Get type from symbol context field (stored as "[type] description")
            let symbols = db.symbolsForModule(comp.id)
            let typeSymbol = symbols.first(where: { $0.kind == "component" })
            let type: String
            if let ctx = typeSymbol?.context, ctx.hasPrefix("["), let end = ctx.firstIndex(of: "]") {
                type = String(ctx[ctx.index(after: ctx.startIndex)..<end]).capitalized
            } else {
                type = "Component"
            }
            typeMap[type, default: []].append(comp)
        }

        // Sort: services first, then alphabetical
        let order = [
            // Software
            "System", "Pipeline", "Service", "Module", "Database", "Api", "Gateway", "Queue", "Broker",
            "Cache", "Storage", "Library", "Sdk", "Framework", "Tool", "Platform", "Infrastructure",
            "Protocol", "Worker", "Scheduler", "Proxy", "Monitoring", "Testing",
            "Classifier", "Resolver", "Analyzer", "Generator", "Processor",
            // Business
            "Process", "Strategy", "Stakeholder", "Regulation", "Metric", "Kpi", "Workflow",
            "Department", "Policy", "Objective", "Initiative", "Capability",
            // Trading/Finance
            "Instrument", "Portfolio", "Risk", "Indicator", "Signal", "Exchange", "Algorithm",
            "Model", "Fund", "Asset", "Position", "Order",
            // Generic
            "Concept", "Entity", "Relationship", "Document", "Template", "Checklist",
            "Milestone", "Resource", "Constraint", "Assumption", "Decision",
            "Component"
        ]
        return typeMap.map { ComponentTypeGroup(type: $0.key, modules: $0.value) }
            .sorted { a, b in
                let ai = order.firstIndex(of: a.type) ?? 99
                let bi = order.firstIndex(of: b.type) ?? 99
                return ai < bi
            }
    }

    /// Group folder modules — each folder with files becomes a module entry
    private func groupFolderModules(_ modules: [SemanticDatabase.ModuleInfo], db: SemanticDatabase) -> [ComponentTypeGroup] {
        // Each folder that has files is shown as a module
        let withFiles = modules.filter { $0.fileCount > 0 }

        if withFiles.isEmpty {
            return [ComponentTypeGroup(type: "Modules", modules: modules)]
        }

        // If only one level — just show flat list
        if withFiles.count <= 5 {
            return [ComponentTypeGroup(type: "Modules", modules: withFiles)]
        }

        // Group by level
        var byLevel: [String: [SemanticDatabase.ModuleInfo]] = [:]
        for mod in withFiles {
            let key = mod.level == 0 ? "Root" : "Level \(mod.level)"
            byLevel[key, default: []].append(mod)
        }

        return byLevel.map { ComponentTypeGroup(type: $0.key, modules: $0.value) }
            .sorted { $0.type < $1.type }
    }

    private func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "service": return VSDark.green
        case "system": return VSDark.cyan
        case "database": return VSDark.purple
        case "api": return VSDark.blue
        case "queue": return VSDark.orange
        case "library": return VSDark.yellow
        case "tool": return Color(hex: 0xd7ba7d)
        default: return VSDark.textDim
        }
    }

    private func moduleRow(_ mod: SemanticDatabase.ModuleInfo, db: SemanticDatabase) -> some View {
        let isSelected = selectedModuleId == mod.id
        let symbols = isSelected ? db.symbolsForModule(mod.id) : []
        let outRels = isSelected ? db.relationsForModule(mod.id) : []
        let inRels = isSelected ? db.incomingRelationsForModule(mod.id) : []
        let artifacts = isSelected ? db.artifactsForModule(mod.id) : []

        // Find source document for content-extracted modules
        let sourceDoc: String? = {
            let syms = db.symbolsForModule(mod.id)
            return syms.first?.doc
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // Module header
            Button(action: { selectedModuleId = isSelected ? nil : mod.id }) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).foregroundColor(VSDark.textDim).frame(width: 10)
                    Image(systemName: mod.id.hasPrefix("cmod_") ? "cube.fill" : "folder.fill")
                        .font(.system(size: 11)).foregroundColor(mod.id.hasPrefix("cmod_") ? VSDark.green : VSDark.yellow)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(mod.name).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text).lineLimit(1)
                        if let doc = sourceDoc {
                            Text(doc).font(.system(size: 8)).foregroundColor(VSDark.textDim).lineLimit(1)
                        }
                    }
                    Spacer()
                    if mod.fileCount > 0 {
                        Text("\(mod.fileCount)").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                    }
                }
            }.buttonStyle(.plain)

            // Expanded card
            if isSelected {
                VStack(alignment: .leading, spacing: 8) {
                    // Open source file button
                    if let doc = sourceDoc {
                        Button(action: { openSourceFile(doc, scrollTo: mod.name) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.doc").font(.system(size: 9))
                                Text("Open \(doc)").font(.system(size: 9))
                            }.foregroundColor(VSDark.blue)
                        }.buttonStyle(.plain)
                    } else if mod.fileCount > 0 {
                        // Folder module — list files
                        let dirURL = URL(fileURLWithPath: mod.path)
                        let mdFiles = (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil))?
                            .filter { $0.pathExtension.lowercased() == "md" } ?? []
                        ForEach(mdFiles, id: \.lastPathComponent) { fileURL in
                            Button(action: { workspaceManager.openFile(fileURL) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text").font(.system(size: 9)).foregroundColor(VSDark.blue)
                                    Text(fileURL.lastPathComponent).font(.system(size: 9)).foregroundColor(VSDark.text)
                                }
                            }.buttonStyle(.plain)
                        }
                    }

                    // Component description (from Haiku extraction)
                    let compSymbols = symbols.filter { $0.kind == "component" }
                    if let comp = compSymbols.first, let ctx = comp.context, !ctx.isEmpty {
                        Text(ctx).font(.system(size: 9, weight: .regular)).foregroundColor(VSDark.textDim).italic()
                    }

                    // Headings
                    let headings = symbols.filter { $0.kind == "heading" }
                    if !headings.isEmpty {
                        Text("Headings (\(headings.count))").font(.system(size: 9, weight: .semibold)).foregroundColor(VSDark.blue)
                        ForEach(headings.prefix(10), id: \.name) { s in
                            Button(action: { openSourceFile(s.doc ?? sourceDoc, scrollTo: s.name) }) {
                                Text("  \(s.name)").font(.system(size: 9)).foregroundColor(VSDark.text).lineLimit(1)
                            }.buttonStyle(.plain)
                        }
                        if headings.count > 10 { Text("  +\(headings.count - 10) more").font(.system(size: 8)).foregroundColor(VSDark.textDim) }
                    }

                    // Links
                    if !outRels.isEmpty {
                        Text("Links to (\(outRels.count))").font(.system(size: 9, weight: .semibold)).foregroundColor(VSDark.green)
                        ForEach(outRels.prefix(5), id: \.targetId) { r in
                            Button(action: { openSourceFile(r.targetId, scrollTo: nil) }) {
                                Text("  → \(r.targetId)").font(.system(size: 9)).foregroundColor(VSDark.green)
                            }.buttonStyle(.plain)
                        }
                    }

                    if !inRels.isEmpty {
                        Text("Referenced by (\(inRels.count))").font(.system(size: 9, weight: .semibold)).foregroundColor(VSDark.orange)
                        ForEach(inRels.prefix(5), id: \.sourceId) { r in
                            Button(action: { openSourceFile(r.sourceId, scrollTo: mod.name) }) {
                                Text("  ← \(r.sourceId)").font(.system(size: 9)).foregroundColor(VSDark.orange)
                            }.buttonStyle(.plain)
                        }
                    }

                    // Existing artifacts
                    if !artifacts.isEmpty {
                        Text("Artifacts").font(.system(size: 9, weight: .semibold)).foregroundColor(VSDark.purple)
                        ForEach(artifacts, id: \.kind) { a in
                            Button(action: { actionResult = ActionEngine.ActionResult(kind: a.kind, content: a.content, moduleId: mod.id); showActionResult = true }) {
                                HStack {
                                    Image(systemName: artifactIcon(a.kind)).font(.system(size: 9)).foregroundColor(VSDark.purple)
                                    Text(a.kind).font(.system(size: 9)).foregroundColor(VSDark.text)
                                }
                            }.buttonStyle(.plain)
                        }
                    }

                    // Action buttons
                    // Progress indicator
                    if let action = actionInProgress {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5)
                            Text(action).font(.system(size: 9)).foregroundColor(VSDark.orange)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 4) {
                        actionBtn("Describe", icon: "text.alignleft") { await describeModule(mod.id) }
                        actionBtn("Summary", icon: "doc.text") { await summarizeModule(mod.id) }
                        actionBtn("Diagram", icon: "chart.dots.scatter") { await diagramModule(mod.id) }
                    }
                    HStack(spacing: 4) {
                        actionBtn("Tests", icon: "checkmark.shield") { await generateTests(mod.id) }
                        actionBtn("ADR", icon: "doc.badge.gearshape") { await generateADR(mod.id) }
                    }
                }
                .padding(.leading, 26).padding(.vertical, 6)
            }
        }
    }

    private func actionBtn(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button(action: { Task { await action() } }) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8))
                Text(title).font(.system(size: 8))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(VSDark.bgActive).foregroundColor(VSDark.blue).cornerRadius(3)
        }.buttonStyle(.plain)
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        VStack(spacing: 0) {
            // Search input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(VSDark.textDim)
                TextField("Search all files...", text: $searchQuery, onCommit: { performSearch() })
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(VSDark.text)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; searchResults = [] }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain)
                }
            }.padding(8).background(VSDark.bgInput)

            // Results
            if searchResults.isEmpty {
                VStack { Spacer(); Text(searchQuery.isEmpty ? "Type to search" : "No results").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                List {
                    ForEach(searchResults.indices, id: \.self) { i in
                        let r = searchResults[i]
                        Button(action: { openSearchResult(r) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.blue)
                                Text(r.snippet.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: ""))
                                    .font(.system(size: 9)).foregroundColor(VSDark.text).lineLimit(3)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
            }
        }
    }

    private func performSearch() {
        guard let db = workspaceManager.semanticDatabase, !searchQuery.isEmpty else { return }
        searchResults = db.search(query: searchQuery)
    }

    private func openSearchResult(_ result: SemanticDatabase.SearchResult) {
        guard let root = workspaceManager.rootNode else { return }
        let fm = FileManager.default
        if let en = fm.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while let url = en.nextObject() as? URL {
                if url.lastPathComponent == result.documentId {
                    workspaceManager.openFile(url)
                    // Extract search term from snippet for scroll
                    let searchTerm = searchQuery.prefix(40).replacingOccurrences(of: "'", with: "\\'")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NotificationCenter.default.post(name: NSNotification.Name("ScrollToText"), object: String(searchTerm))
                    }
                    break
                }
            }
        }
    }

    // MARK: - Research Tab

    @State private var researchQuestion = ""
    @State private var researchAnswer: ResearchEngine.ResearchAnswer?
    @State private var isResearching = false
    @State private var researchError: String?
    @State private var researchHistory: [(id: String, content: String, createdAt: Int)] = []
    @State private var showHistory = false

    private var researchTab: some View {
        VStack(spacing: 0) {
            // Question input
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundColor(VSDark.blue)
                TextField("Ask about your documentation...", text: $researchQuestion, onCommit: { performResearch() })
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(VSDark.text)
                    .disabled(isResearching)
                if isResearching {
                    ProgressView().scaleEffect(0.5)
                    Text("Researching...").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                } else {
                    if !researchQuestion.isEmpty {
                        Button(action: { performResearch() }) {
                            Image(systemName: "arrow.right.circle.fill").font(.system(size: 14)).foregroundColor(VSDark.blue)
                        }.buttonStyle(.plain)
                    }
                    // History toggle
                    Button(action: { showHistory.toggle(); if showHistory { loadResearchHistory() } }) {
                        Image(systemName: showHistory ? "clock.fill" : "clock")
                            .font(.system(size: 11)).foregroundColor(VSDark.textDim)
                    }.buttonStyle(.plain).help("Research history")
                }
            }.padding(8).background(VSDark.bgInput)

            // Error
            if let error = researchError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.orange)
                    Text(error).font(.system(size: 10)).foregroundColor(.orange)
                    Spacer()
                }.padding(8).background(VSDark.bgActive)
            }

            if showHistory {
                // History view
                researchHistoryView
            } else if let answer = researchAnswer {
                // Current answer
                researchAnswerView(answer)
            } else if isResearching {
                VStack {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Text("Searching documents and analyzing...").font(.system(size: 11)).foregroundColor(VSDark.textDim).padding(.top, 8)
                    Spacer()
                }.frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                VStack {
                    Spacer()
                    Text("Ask a question about your documentation")
                        .font(.system(size: 12)).foregroundColor(VSDark.textDim)
                    Text("Examples: \"How does auth work?\", \"What databases are used?\"")
                        .font(.system(size: 10)).foregroundColor(VSDark.textDim.opacity(0.6))
                    Spacer()
                }.frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            }
        }
        .onAppear { loadResearchHistory() }
    }

    private func researchAnswerView(_ answer: ResearchEngine.ResearchAnswer) -> some View {
        VStack(spacing: 0) {
            // Top bar with export
            HStack(spacing: 8) {
                Text("Q: \(answer.question)").font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text).lineLimit(1)
                Spacer()
                Button(action: { exportResearchAsMD(question: answer.question, answer: answer.answer, citations: answer.citations) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 9))
                        Text("Export .md").font(.system(size: 9))
                    }.foregroundColor(VSDark.blue)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 10).padding(.vertical, 6).background(VSDark.bgActive)

            // Markdown rendered answer
            MarkdownContentView(markdown: answer.answer)

            // Citations bar
            if !answer.citations.isEmpty {
                Divider().background(VSDark.border)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Sources:").font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textDim)
                        ForEach(answer.citations.indices, id: \.self) { i in
                            let c = answer.citations[i]
                            Button(action: {
                                if let root = workspaceManager.rootNode {
                                    if let url = findFile(c.documentId, in: root.url) {
                                        workspaceManager.openFile(url)
                                    }
                                }
                            }) {
                                HStack(spacing: 2) {
                                    Image(systemName: "doc.text").font(.system(size: 8))
                                    Text(c.documentId).font(.system(size: 9))
                                }
                                .foregroundColor(VSDark.blue)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(VSDark.bgActive).cornerRadius(3)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 5)
                }.background(VSDark.bgSidebar)
            }
        }.background(VSDark.bgSidebar)
    }

    private var researchHistoryView: some View {
        VStack(spacing: 0) {
            // Header with Clear button
            HStack {
                Text("Research History (\(researchHistory.count))").font(.system(size: 10, weight: .bold)).foregroundColor(VSDark.textDim)
                Spacer()
                if !researchHistory.isEmpty {
                    Button(action: { exportAllResearchAsMD() }) {
                        HStack(spacing: 2) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 9))
                            Text("Export All").font(.system(size: 9))
                        }.foregroundColor(VSDark.blue)
                    }.buttonStyle(.plain)

                    Button(action: { clearResearchHistory() }) {
                        HStack(spacing: 2) {
                            Image(systemName: "trash").font(.system(size: 9))
                            Text("Clear").font(.system(size: 9))
                        }.foregroundColor(.red.opacity(0.8))
                    }.buttonStyle(.plain)
                }
            }.padding(8)

            Divider().background(VSDark.border)

            if researchHistory.isEmpty {
                VStack { Spacer(); Text("No research history yet").font(.system(size: 11)).foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(researchHistory, id: \.id) { item in
                            researchHistoryRow(item)
                        }
                    }
                }
            }
        }.background(VSDark.bgSidebar)
    }

    private func researchHistoryRow(_ item: (id: String, content: String, createdAt: Int)) -> some View {
        let lines = item.content.components(separatedBy: "\n")
        let question = lines.first(where: { $0.hasPrefix("## Q:") })?.replacingOccurrences(of: "## Q: ", with: "") ?? "Research"
        let preview = lines.dropFirst(2).prefix(3).joined(separator: " ").prefix(120)
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return Button(action: {
            showHistory = false
            researchAnswer = ResearchEngine.ResearchAnswer(
                question: question, answer: item.content.replacingOccurrences(of: "## Q: \(question)\n\n", with: ""),
                citations: [], searchResults: []
            )
        }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(question).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text).lineLimit(1)
                    Spacer()
                    Text(formatter.string(from: date)).font(.system(size: 8)).foregroundColor(VSDark.textDim)

                    Button(action: { exportResearchAsMD(question: question, answer: String(item.content.dropFirst(question.count + 7)), citations: []) }) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 9)).foregroundColor(VSDark.blue)
                    }.buttonStyle(.plain)
                }
                Text(preview).font(.system(size: 9)).foregroundColor(VSDark.textDim).lineLimit(2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(VSDark.bgActive)
        }.buttonStyle(.plain)
    }

    private func performResearch() {
        guard !researchQuestion.isEmpty, !isResearching else { return }

        guard workspaceManager.researchEngine != nil else {
            researchError = "Research engine not initialized. Open a folder first."
            return
        }
        guard workspaceManager.researchEngine?.providerClient.hasAPIKey == true else {
            researchError = "API key not set. Go to Settings to add your Anthropic API key."
            return
        }

        isResearching = true
        researchError = nil
        researchAnswer = nil
        showHistory = false

        Task {
            let result = await workspaceManager.researchEngine?.research(question: researchQuestion)
            isResearching = false
            if let result = result {
                researchAnswer = result
                loadResearchHistory()
            } else {
                researchError = "Research failed. Check console for details."
            }
        }
    }

    private func loadResearchHistory() {
        guard let db = workspaceManager.semanticDatabase else { return }
        researchHistory = db.allResearchArtifacts()
    }

    private func clearResearchHistory() {
        guard let db = workspaceManager.semanticDatabase else { return }
        db.clearResearchHistory()
        researchHistory = []
        researchAnswer = nil
    }

    private func exportResearchAsMD(question: String, answer: String, citations: [ResearchEngine.Citation]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "research-\(question.prefix(30).replacingOccurrences(of: " ", with: "-").lowercased()).md"

        var md = "# Research: \(question)\n\n"
        md += answer + "\n"
        if !citations.isEmpty {
            md += "\n## Sources\n\n"
            for c in citations {
                md += "- [\(c.documentId)](\(c.documentId))"
                if !c.quote.isEmpty { md += " — \(c.quote)" }
                md += "\n"
            }
        }
        md += "\n---\n*Generated by MarkView DDE on \(Date())*\n"

        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportAllResearchAsMD() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.nameFieldStringValue = "research-history.md"

        var md = "# Research History\n\n"
        for item in researchHistory {
            md += item.content + "\n\n---\n\n"
        }
        md += "*Exported from MarkView DDE on \(Date())*\n"

        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func findFile(_ name: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        while let url = en.nextObject() as? URL { if url.lastPathComponent == name { return url } }
        return nil
    }

    // MARK: - File Navigation

    private func openSourceFile(_ fileNameOrPath: String?, scrollTo: String?) {
        guard let name = fileNameOrPath, !name.isEmpty, let root = workspaceManager.rootNode else { return }

        // Try as exact filename first
        if let url = findFile(name, in: root.url) {
            workspaceManager.openFile(url)
            scrollAfterDelay(scrollTo)
            return
        }

        // Try adding .md extension
        if !name.hasSuffix(".md"), let url = findFile(name + ".md", in: root.url) {
            workspaceManager.openFile(url)
            scrollAfterDelay(scrollTo)
            return
        }

        // Try finding a file that contains this name in its content (search FTS)
        if let db = workspaceManager.semanticDatabase {
            let results = db.search(query: name, limit: 1)
            if let first = results.first, let url = findFile(first.documentId, in: root.url) {
                workspaceManager.openFile(url)
                scrollAfterDelay(name) // scroll to the name itself
                return
            }
        }
    }

    private func scrollAfterDelay(_ text: String?) {
        guard let text = text, !text.isEmpty else { return }
        let snippet = String(text.prefix(50)).replacingOccurrences(of: "'", with: "\\'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.Name("ScrollToText"), object: snippet)
        }
    }

    // MARK: - Actions

    private func describeModule(_ moduleId: String) async {
        actionInProgress = "Generating description..."
        defer { actionInProgress = nil }
        guard let engine = workspaceManager.actionEngine else { return }
        if let result = await engine.describe(moduleId: moduleId) {
            actionResult = result; showActionResult = true
        }
    }

    private func summarizeModule(_ moduleId: String) async {
        actionInProgress = "Generating summary..."
        defer { actionInProgress = nil }
        guard let engine = workspaceManager.actionEngine else { return }
        if let result = await engine.summarize(moduleId: moduleId) {
            actionResult = result; showActionResult = true
        }
    }

    private func diagramModule(_ moduleId: String) async {
        actionInProgress = "Generating C4 diagram..."
        defer { actionInProgress = nil }
        guard let engine = workspaceManager.actionEngine else { return }
        if let result = await engine.diagram(moduleId: moduleId) {
            actionResult = result; showActionResult = true
        }
    }

    private func generateTests(_ moduleId: String) async {
        actionInProgress = "Generating test specs..."
        defer { actionInProgress = nil }
        guard let gen = workspaceManager.testGenerator, let root = workspaceManager.rootNode else { return }
        let tests = await gen.generateTests(moduleId: moduleId, workspacePath: root.url)
        if let first = tests.first {
            actionResult = ActionEngine.ActionResult(kind: "tests", content: first.content, moduleId: moduleId)
            showActionResult = true
        }
    }

    private func generateADR(_ moduleId: String) async {
        actionInProgress = "Generating ADR..."
        defer { actionInProgress = nil }
        guard let engine = workspaceManager.actionEngine else { return }
        if let result = await engine.generateADR(moduleId: moduleId, topic: "Architecture decisions for this module") {
            actionResult = result; showActionResult = true
        }
    }

    // MARK: - Action Result Sheet

    private func actionResultSheet(_ result: ActionEngine.ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: artifactIcon(result.kind)).foregroundColor(VSDark.blue)
                Text(result.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.headline).foregroundColor(VSDark.text)
                Spacer()
                Button("Close") { showActionResult = false }.buttonStyle(.plain).foregroundColor(VSDark.textDim)
            }

            Divider()

            if result.kind == "c4_diagram" {
                MermaidWebView(mermaidCode: result.content).frame(minHeight: 300)
            } else {
                // Render markdown content via WKWebView
                MarkdownPreviewWebView(markdown: result.content)
            }

            HStack(spacing: 8) {
                Button(action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.content, forType: .string) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button(action: { exportAsMarkdown(result) }) {
                    Label("Save as .md", systemImage: "square.and.arrow.down")
                }

                Spacer()
            }
        }
        .padding(20).frame(width: 700, height: 550).background(VSDark.bg)
    }

    private func exportAsMarkdown(_ result: ActionEngine.ActionResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let defaultName = "\(result.kind)_\(result.moduleId ?? "doc").md"
        panel.nameFieldStringValue = defaultName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? result.content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Markdown Preview (renders markdown as HTML)

    struct MarkdownPreviewWebView: NSViewRepresentable {
        let markdown: String

        func makeNSView(context: Context) -> WKWebView { WKWebView() }

        func updateNSView(_ webView: WKWebView, context: Context) {
            let hash = markdown.hashValue
            if context.coordinator.lastHash == hash { return }
            context.coordinator.lastHash = hash

            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")

            let html = """
            <!DOCTYPE html><html><head><meta charset="UTF-8">
            <script src="https://cdn.jsdelivr.net/npm/markdown-it@13.0.1/dist/markdown-it.min.js"></script>
            <style>
                body { background:#1e1e1e; color:#d4d4d4; font-family:-apple-system,sans-serif; font-size:13px; padding:20px; line-height:1.6; }
                h1,h2,h3,h4 { color:#569cd6; border-bottom:1px solid #3c3c3c; padding-bottom:4px; }
                code { background:#252526; padding:2px 5px; border-radius:3px; font-family:Menlo,monospace; font-size:0.9em; }
                pre { background:#252526; padding:12px; border-radius:6px; overflow-x:auto; }
                pre code { background:transparent; padding:0; }
                a { color:#569cd6; }
                blockquote { border-left:3px solid #569cd6; padding-left:12px; color:#808080; }
                table { border-collapse:collapse; width:100%; }
                th,td { border:1px solid #3c3c3c; padding:6px 10px; }
                th { background:#252526; }
                ul,ol { padding-left:1.5em; }
                hr { border:none; border-top:1px solid #3c3c3c; }
            </style>
            </head><body>
            <div id="content"></div>
            <script>
                const md = window.markdownit({ html:true, breaks:true, linkify:true });
                document.getElementById('content').innerHTML = md.render(`\(escaped)`);
            </script>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        func makeCoordinator() -> Coordinator { Coordinator() }
        class Coordinator { var lastHash = 0 }
    }

    private func artifactIcon(_ kind: String) -> String {
        switch kind {
        case "description": return "text.alignleft"
        case "summary": return "doc.text"
        case "c4_diagram": return "chart.dots.scatter"
        case "adr": return "doc.badge.gearshape"
        default: return "doc"
        }
    }
}
