import SwiftUI

/// Semantic panel — question-driven views over extracted data
struct SemanticPanelView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabBtn("Deps", tag: 0)
                tabBtn("Entities", tag: 1)
                tabBtn("Decisions", tag: 2)
                tabBtn("Gaps", tag: 3)
                tabBtn("Data Flow", tag: 4)
                tabBtn("Arch", tag: 5)
            }
            .padding(4).background(VSDark.bg)
            Divider().background(VSDark.border)

            // Stats
            statsBar

            // Content
            switch selectedTab {
            case 0: DependenciesView(db: workspaceManager.semanticDatabase)
            case 1: EntitiesView(db: workspaceManager.semanticDatabase)
            case 2: DecisionsView(db: workspaceManager.semanticDatabase)
            case 3: GapsView(db: workspaceManager.semanticDatabase, compiler: workspaceManager.incrementalCompiler)
            case 4: DataFlowView(db: workspaceManager.semanticDatabase)
            case 5: EntityGraphView().environmentObject(workspaceManager)
            default: DependenciesView(db: workspaceManager.semanticDatabase)
            }
        }
        .frame(minWidth: 260, idealWidth: 340)
    }

    private func tabBtn(_ title: String, tag: Int) -> some View {
        Button(action: { selectedTab = tag }) {
            Text(title).font(.system(size: 9, weight: selectedTab == tag ? .bold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .foregroundColor(selectedTab == tag ? VSDark.textBright : VSDark.textDim)
                .background(selectedTab == tag ? VSDark.bgActive : Color.clear).cornerRadius(4)
        }.buttonStyle(.plain)
    }

    private var statsBar: some View {
        Group {
            if let db = workspaceManager.semanticDatabase {
                let stats = db.getUsageStats()
                HStack(spacing: 8) {
                    Text("\(db.entityCount()) entities").font(.system(size: 9)).foregroundColor(VSDark.green)
                    Text("\(db.claimCount()) claims").font(.system(size: 9)).foregroundColor(VSDark.blue)
                    Spacer()
                    if stats.totalJobs > 0 {
                        Text("$\(String(format: "%.2f", stats.totalCostDollars))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(stats.totalCostDollars > 0.5 ? VSDark.red : VSDark.textDim)
                    }
                    if workspaceManager.analysisStage != nil || workspaceManager.incrementalCompiler?.orchestrator.isProcessing == true {
                        ProgressView().scaleEffect(0.4)
                        if let file = workspaceManager.incrementalCompiler?.orchestrator.currentFile {
                            Text(file).font(.system(size: 8)).foregroundColor(VSDark.orange).lineLimit(1)
                        }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 3).background(VSDark.bgSidebar)
            }
        }
    }
}

private func semanticFileLabel(_ filePath: String?) -> String? {
    guard let filePath, !filePath.isEmpty else { return nil }
    return URL(fileURLWithPath: filePath).lastPathComponent
}

// MARK: - Dependencies: "What does each service depend on?"

struct DependenciesView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let db: SemanticDatabase?
    @State private var groups: [(name: String, items: [SemanticDatabase.DependencyRow])] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack { Spacer(); Text(loaded ? "No dependencies found" : "Loading...").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                List {
                    ForEach(groups, id: \.name) { g in
                        Section(header: Text(g.name).font(.system(size: 11, weight: .bold)).foregroundColor(VSDark.green)) {
                            ForEach(g.items.indices, id: \.self) { i in
                                let item = g.items[i]
                                Button {
                                    workspaceManager.navigateToText(
                                        filePath: item.filePath,
                                        searchText: item.sourceText.isEmpty ? item.dependsOn : item.sourceText
                                    )
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("→").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(item.dependsOn).font(.system(size: 11)).foregroundColor(VSDark.text).lineLimit(1)
                                                if !item.targetType.isEmpty {
                                                    Text(item.targetType).font(.system(size: 8)).foregroundColor(VSDark.textDim)
                                                }
                                            }
                                            if let fileLabel = semanticFileLabel(item.filePath) {
                                                Text(fileLabel).font(.system(size: 8)).foregroundColor(VSDark.textDim)
                                            }
                                        }
                                        Spacer()
                                        Text(item.relation).font(.system(size: 8)).foregroundColor(VSDark.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
            }
        }
        .onAppear { load() }
        .onChange(of: workspaceManager.semanticRefreshVersion) { _ in load() }
    }

    private func load() {
        guard let db = db else {
            loaded = true
            groups = []
            return
        }
        let rows = db.serviceDependencies()
        let grouped = Dictionary(grouping: rows, by: { $0.serviceName })
        groups = grouped.map { (name: $0.key, items: $0.value) }
            .sorted { $0.name < $1.name }
        loaded = true
    }
}

// MARK: - Entities: "Where is this entity mentioned?"

struct EntitiesView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let db: SemanticDatabase?
    @State private var groups: [(type: String, items: [SemanticDatabase.EntityEvidenceRow])] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack { Spacer(); Text(loaded ? "No entities found" : "Loading...").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                List {
                    ForEach(groups, id: \.type) { g in
                        Section(header: HStack {
                            Text(g.type).font(.system(size: 10, weight: .bold)).foregroundColor(VSDark.green)
                            Spacer()
                            Text("\(g.items.count)").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                        }) {
                            ForEach(g.items.indices, id: \.self) { i in
                                let item = g.items[i]
                                Button {
                                    workspaceManager.navigateToText(
                                        filePath: item.filePath,
                                        searchText: item.snippet.isEmpty ? item.name : item.snippet
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.name).font(.system(size: 11, weight: .medium)).foregroundColor(VSDark.text)
                                            Text(item.canonicalName).font(.system(size: 8)).foregroundColor(VSDark.blue)
                                        }
                                        Text(item.snippet).font(.system(size: 9)).foregroundColor(VSDark.textDim).lineLimit(2)
                                        if let fileLabel = semanticFileLabel(item.filePath) {
                                            Text(fileLabel).font(.system(size: 8)).foregroundColor(VSDark.textDim.opacity(0.8))
                                        }
                                    }
                                    .padding(.vertical, 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
            }
        }
        .onAppear { load() }
        .onChange(of: workspaceManager.semanticRefreshVersion) { _ in load() }
    }

    private func load() {
        guard let db = db else {
            loaded = true
            groups = []
            return
        }

        let rows = db.entityEvidenceRows()
        let grouped = Dictionary(grouping: rows, by: { $0.type })
        let preferredOrder = ["System", "Service", "Component", "API", "Database", "Queue", "Event", "Team", "Environment", "Phase"]
        let orderedGroups = preferredOrder.compactMap { type -> (String, [SemanticDatabase.EntityEvidenceRow])? in
            guard let items = grouped[type], !items.isEmpty else { return nil }
            return (type, items)
        }
        let remainingGroups = grouped.keys
            .filter { !preferredOrder.contains($0) }
            .sorted()
            .compactMap { type -> (String, [SemanticDatabase.EntityEvidenceRow])? in
                guard let items = grouped[type], !items.isEmpty else { return nil }
                return (type, items)
            }

        groups = orderedGroups + remainingGroups
        loaded = true
    }
}

// MARK: - Decisions: "What decisions were made and why?"

struct DecisionsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let db: SemanticDatabase?
    @State private var groups: [(type: String, items: [SemanticDatabase.DecisionRow])] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if groups.isEmpty {
                VStack { Spacer(); Text(loaded ? "No decisions found" : "Loading...").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                List {
                    ForEach(groups, id: \.type) { g in
                        Section(header: HStack {
                            Text(g.type).font(.system(size: 10, weight: .bold)).foregroundColor(colorFor(g.type))
                            Spacer()
                            Text("\(g.items.count)").font(.system(size: 9)).foregroundColor(VSDark.textDim)
                        }) {
                            ForEach(g.items.indices, id: \.self) { i in
                                let item = g.items[i]
                                Button {
                                    workspaceManager.navigateToText(
                                        filePath: item.filePath,
                                        searchText: item.decision
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.decision).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(3)
                                        HStack(spacing: 4) {
                                            if !item.entityName.isEmpty {
                                                Text(item.entityName).font(.system(size: 8, weight: .medium)).foregroundColor(VSDark.green)
                                            }
                                            if let fileLabel = semanticFileLabel(item.filePath) {
                                                Text(fileLabel).font(.system(size: 8)).foregroundColor(VSDark.textDim)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
            }
        }
        .onAppear { load() }
        .onChange(of: workspaceManager.semanticRefreshVersion) { _ in load() }
    }

    private func load() {
        guard let db = db else {
            // Don't set loaded=true if db is nil — wait for it
            return
        }
        let rows = db.decisionsWithContext()
        NSLog("[DecisionsView] Loaded \(rows.count) rows")
        let grouped = Dictionary(grouping: rows, by: { $0.claimType })
        let order = ["Decision", "Risk", "Constraint", "Assumption", "Requirement"]
        groups = order.compactMap { type in
            guard let items = grouped[type], !items.isEmpty else { return nil }
            // Dedup
            var seen = Set<String>()
            let unique = items.filter { r in
                let k = String(r.decision.prefix(50)).lowercased()
                if seen.contains(k) { return false }; seen.insert(k); return true
            }
            return (type: type, items: unique)
        }
        loaded = true
    }

    private func colorFor(_ type: String) -> Color {
        switch type {
        case "Decision": return VSDark.green
        case "Risk": return VSDark.red
        case "Constraint": return VSDark.orange
        case "Assumption": return VSDark.yellow
        case "Requirement": return VSDark.purple
        default: return VSDark.textDim
        }
    }
}

// MARK: - Gaps: "Where are the holes?"

struct GapsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let db: SemanticDatabase?
    let compiler: IncrementalCompiler?
    @State private var gaps: [(icon: String, color: Color, message: String, file: String?)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if gaps.isEmpty {
                VStack { Spacer(); Text(loaded ? "No gaps detected" : "Loading...").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                List {
                    ForEach(gaps.indices, id: \.self) { i in
                        let g = gaps[i]
                        HStack(spacing: 6) {
                            Image(systemName: g.icon).font(.system(size: 10)).foregroundColor(g.color)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.message).font(.system(size: 10)).foregroundColor(VSDark.text).lineLimit(2)
                                if let f = g.file { Text(f).font(.system(size: 8)).foregroundColor(VSDark.textDim) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
            }
        }
        .onAppear { load() }
        .onChange(of: workspaceManager.semanticRefreshVersion) { _ in load() }
    }

    private func load() {
        guard let db = db else {
            loaded = true
            gaps = []
            return
        }
        var result: [(icon: String, color: Color, message: String, file: String?)] = []

        // Use SQL to find decisions without rationale (most common gap)
        let rows = db.decisionsWithContext()
        let decisions = rows.filter { $0.claimType == "Decision" }
        let assumptions = Set(rows.filter { $0.claimType == "Assumption" }.map { $0.entityName.lowercased() })

        for d in decisions {
            if !assumptions.contains(d.entityName.lowercased()) {
                result.append(("doc.questionmark", VSDark.yellow,
                    "Decision lacks rationale: \(d.decision.prefix(60))", d.filePath))
            }
        }

        // Compiler diagnostics
        if let diags = compiler?.diagnostics {
            for d in diags {
                result.append((
                    d.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill",
                    d.severity == .error ? VSDark.red : VSDark.orange,
                    d.message, d.documentId
                ))
            }
        }

        // Entities with no claims at all
        let entities = db.uniqueEntities()
        let deps = db.serviceDependencies()
        let hasData = Set(deps.map { $0.serviceName.lowercased() })
        for e in entities where e.type == "Service" || e.type == "System" {
            if !hasData.contains(e.canonicalName.lowercased()) {
                result.append(("questionmark.circle", VSDark.orange,
                    "\(e.type) '\(e.name)' — no documented dependencies", e.sourceFile))
            }
        }

        gaps = result
        loaded = true
    }
}

// MARK: - Data Flow: "How does data move?"

struct DataFlowView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let db: SemanticDatabase?
    @State private var flows: [SemanticDatabase.DataFlowRow] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if flows.isEmpty {
                VStack { Spacer(); Text(loaded ? "No data flows found" : "Loading...").foregroundColor(VSDark.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(VSDark.bgSidebar)
            } else {
                List {
                    ForEach(flows.indices, id: \.self) { i in
                        let f = flows[i]
                        Button {
                            workspaceManager.navigateToText(
                                filePath: f.filePath,
                                searchText: f.sourceText.isEmpty ? "\(f.from) \(f.to)" : f.sourceText
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(f.from).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.green).lineLimit(1)
                                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                                    Text(f.to).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.blue).lineLimit(1)
                                    Spacer()
                                    if !f.predicate.isEmpty {
                                        Text(f.predicate).font(.system(size: 8)).foregroundColor(VSDark.orange)
                                    }
                                }
                                if !f.sourceText.isEmpty {
                                    Text(f.sourceText).font(.system(size: 8)).foregroundColor(VSDark.textDim).lineLimit(2)
                                }
                                if let fileLabel = semanticFileLabel(f.filePath) {
                                    Text(fileLabel).font(.system(size: 8)).foregroundColor(VSDark.textDim.opacity(0.8))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).background(VSDark.bgSidebar)
            }
        }
        .onAppear { load() }
        .onChange(of: workspaceManager.semanticRefreshVersion) { _ in load() }
    }

    private func load() {
        guard let db = db else {
            loaded = true
            flows = []
            return
        }

        let rows = db.dataFlowRows()
        var result: [SemanticDatabase.DataFlowRow] = []
        var seen = Set<String>()

        for row in rows {
            let key = "\(row.from)→\(row.to)→\(row.predicate)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(row)
        }

        flows = result
        loaded = true
    }
}
