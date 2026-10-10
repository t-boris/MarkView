import SwiftUI

/// Document Contents panel. Legacy tabs remain for saved layouts and secondary routes.
struct TOCView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    /// This window's panel tabs (BUG-004: not @AppStorage, which every window observes).
    @ObservedObject var layout: PanelLayout
    var showTabs = true

    enum Tab: String, CaseIterable {
        case contents = "Contents"
        case search = "Search"
        case git = "Git"
        case terminal = "Terminal"
        case feature = "Feature"

        static let storageKey = "layout.navigatorTab"

        /// What the tab is called. The raw values are stored in saved layouts and stay as they were.
        var title: String {
            switch self {
            case .terminal: return "Agents"
            case .feature: return "Tasks"
            default: return rawValue
            }
        }
    }

    var body: some View {
        Group {
            if showTabs {
                TOCTabs(store: workspaceManager.features, selectedTab: $layout.navigatorTab) {
                    tabContent
                }
            } else {
                contentsList
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
            switch layout.navigatorTab == .feature && !workspaceManager.features.hasIssues ? .contents : layout.navigatorTab {
            case .contents: contentsList
            case .search: WorkspaceSearchView().environmentObject(workspaceManager)
            case .git: GitView(git: workspaceManager.gitClient, workspaceManager: workspaceManager)
            case .terminal: ModuleExplorerView().environmentObject(workspaceManager)
            case .feature:
                VStack(spacing: 0) {
                    if let tab = workspaceManager.activeTab,
                       let feature = workspaceManager.features.locate(tab.url)?.feature {
                        HandoffPanelView(feature: feature).environmentObject(workspaceManager)
                    }
                    FeaturePanelView(store: workspaceManager.features, layout: layout)
                }
            }
    }

    @ViewBuilder
    private var contentsList: some View {
        Group {
            if let idx = workspaceManager.activeTabIndex as Int?,
               idx >= 0, idx < workspaceManager.openTabs.count {
                let tab = workspaceManager.openTabs[idx]

                if tab.headings.isEmpty {
                    emptyState("No Headings")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tab.headings) { heading in
                                Button(action: {
                                    workspaceManager.updateActiveHeading(heading.id)
                                    NotificationCenter.default.post(name: .scrollToHeading, object: heading.id)
                                }) {
                                    HStack(spacing: 4) {
                                        if heading.level > 1 {
                                            Color.clear.frame(width: CGFloat(heading.level - 1) * 12)
                                        }
                                        Circle()
                                            .fill(heading.id == tab.activeHeadingId ? VSDark.blue : VSDark.textDim.opacity(0.4))
                                            .frame(width: 5, height: 5)
                                        Text(heading.text)
                                            .uiFont(size: 11)
                                            .foregroundColor(heading.id == tab.activeHeadingId ? VSDark.textBright : VSDark.text)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 8)
                                    .background(heading.id == tab.activeHeadingId ? VSDark.selection.opacity(0.3) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .background(VSDark.bgSidebar)
                }
            } else {
                emptyState("No File Open")
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .uiFont(size: 12)
                .foregroundColor(VSDark.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSDark.bgSidebar)
    }
}

/// The tab row of the right panel; "Feature" only when the project has docs/features.
private struct TOCTabs<Content: View>: View {
    @ObservedObject var store: FeatureStore
    @Binding var selectedTab: TOCView.Tab
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(TOCView.Tab.allCases.filter { $0 != .feature || store.hasIssues }, id: \.self) { tab in
                    VSDarkTabButton(title: tab.title, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(4).background(VSDark.bg)
            Divider().background(VSDark.border)
            content()
        }
        .background(VSDark.bgSidebar)
    }
}

/// Full-text search across the workspace index.
struct WorkspaceSearchView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var searchQuery = ""
    @State private var searchResults: [SemanticDatabase.SearchResult] = []

    var body: some View {
        VStack(spacing: 0) {
            // Search input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").uiFont(size: 11).foregroundColor(VSDark.textDim)
                TextField("Search all files...", text: $searchQuery, onCommit: { performSearch() })
                    .textFieldStyle(.plain).uiFont(size: 11).foregroundColor(VSDark.text)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; searchResults = [] }) {
                        Image(systemName: "xmark.circle.fill").uiFont(size: 10).foregroundColor(VSDark.textDim)
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
                                Text(r.title).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.blue)
                                Text(r.snippet.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: ""))
                                    .uiFont(size: 9).foregroundColor(VSDark.text).lineLimit(3)
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
        guard let root = workspaceManager.rootNode,
              let url = workspaceManager.fileURL(forDocumentId: result.documentId) ?? findFile(result.documentId, in: root.url) else { return }
        workspaceManager.openFile(url)
        // Extract search term from snippet for scroll
        let searchTerm = searchQuery.prefix(40).replacingOccurrences(of: "'", with: "\\'")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: .scrollToText, object: String(searchTerm))
        }
    }

    private func findFile(_ name: String, in dir: URL) -> URL? {
        // docIds are now workspace-relative paths → resolve directly first
        // (also handles a bare filename, which is a 1-component relative path).
        let direct = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Fallback by-name search: headings/entity names, or legacy filename docIds.
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        while let url = en.nextObject() as? URL { if url.lastPathComponent == name { return url } }
        return nil
    }
}

#Preview {
    let workspaceManager = WorkspaceManager()
    return TOCView(layout: workspaceManager.layout).environmentObject(workspaceManager)
}
