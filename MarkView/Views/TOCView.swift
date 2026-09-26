import SwiftUI

/// The right panel: table of contents, workspace search, Git and the AI terminals.
struct TOCView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @AppStorage(Tab.storageKey) private var selectedTab = Tab.contents

    enum Tab: String, CaseIterable {
        case contents = "Contents"
        case search = "Search"
        case git = "Git"
        case terminal = "Terminal"

        static let storageKey = "layout.navigatorTab"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    VSDarkTabButton(title: tab.rawValue, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(4).background(VSDark.bg)
            Divider().background(VSDark.border)

            switch selectedTab {
            case .contents: contentsList
            case .search: WorkspaceSearchView().environmentObject(workspaceManager)
            case .git: GitView(git: workspaceManager.gitClient, workspaceManager: workspaceManager)
            case .terminal: ModuleExplorerView().environmentObject(workspaceManager)
            }
        }
        .background(VSDark.bgSidebar)
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
                                            .font(.system(size: 12))
                                            .foregroundColor(heading.id == tab.activeHeadingId ? VSDark.textBright : VSDark.text)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 4)
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
                .font(.system(size: 12))
                .foregroundColor(VSDark.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        guard let root = workspaceManager.rootNode,
              let url = findFile(result.documentId, in: root.url) else { return }
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
    TOCView().environmentObject(WorkspaceManager())
}
