import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Document Contents panel. Legacy tabs remain for saved layouts and secondary routes.
struct TOCView: View {
    @Environment(\.palette) private var palette
    @Environment(\.windowCommands) private var window
    @EnvironmentObject private var tabs: TabsController
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @EnvironmentObject private var codeXRay: CodeAndXRayCoordinator
    @EnvironmentObject private var requests: WindowRequests
    @EnvironmentObject private var git: GitClient
    /// This window's panel tabs (BUG-004: not @AppStorage, which every window observes).
    @ObservedObject var layout: PanelLayout
    /// The window's terminals, for the facts of a terminal tab in the Contents panel.
    let terminals: AITerminalsController
    var showTabs = true

    typealias Tab = NavigatorTab

    var body: some View {
        Group {
            if showTabs {
                TOCTabs(store: flow.features, selectedTab: $layout.navigatorTab) {
                    tabContent
                }
            } else {
                contentsList
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
            switch layout.navigatorTab == .feature && !flow.features.hasIssues ? .contents : layout.navigatorTab {
            case .contents: contentsList
            case .search: WorkspaceSearchView()
            case .git: GitView(git: git, flow: flow, codeXRay: codeXRay, requests: requests, layout: layout, window: window)
            case .terminal: contentsList
            case .feature:
                VStack(spacing: 0) {
                    if let tab = tabs.activeTab,
                       let feature = flow.features.locate(tab.url)?.feature {
                        HandoffPanelView(feature: feature)
                    }
                    FeaturePanelView(store: flow.features, layout: layout)
                }
            }
    }

    private var contentsList: some View {
        Group {
            if let tab = tabs.activeTab {
                ContentsPanelView(tab: tab, terminals: terminals) { headingsList(tab) }
            } else {
                emptyState("No File Open")
            }
        }
    }

    /// The headings of a Markdown document; a click scrolls to one.
    private func headingsList(_ tab: OpenTab) -> some View {
        TOCHeadingsListView(tab: tab, scrollState: tabs.scroll) { headingID in
            tabs.updateActiveHeading(headingID)
            if let window { NotificationCenter.default.post(.scrollToHeading, for: window, object: headingID) }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .uiFont(size: 12)
                .foregroundColor(palette.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bgSidebar)
    }
}

/// Scoped observer for active heading updates via `DocumentScrollSideTable` (`AR-15`).
struct TOCHeadingsListView: View {
    @Environment(\.palette) private var palette
    let tab: OpenTab
    @ObservedObject var scrollState: DocumentScrollSideTable
    let onSelectHeading: (String) -> Void

    var body: some View {
        let activeID = scrollState.activeHeading(for: tab.id)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tab.headings) { heading in
                    Button(action: { onSelectHeading(heading.id) }) {
                        HStack(spacing: 4) {
                            if heading.level > 1 {
                                Color.clear.frame(width: CGFloat(heading.level - 1) * 12)
                            }
                            Circle()
                                .fill(heading.id == activeID ? palette.blue : palette.textDim.opacity(0.4))
                                .frame(width: 5, height: 5)
                            Text(heading.text)
                                .uiFont(size: 11)
                                .foregroundColor(heading.id == activeID ? palette.textBright : palette.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(heading.id == activeID ? palette.selection.opacity(0.3) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityRepresentation {
            VStack {
                ForEach(tab.headings) { heading in
                    Button(heading.text) { onSelectHeading(heading.id) }
                        .accessibilityValue(heading.id == activeID ? "Current" : "")
                }
            }
        }
        .background(palette.bgSidebar)
    }
}

/// The tab row of the right panel; "Feature" only when the project has docs/features.
private struct TOCTabs<Content: View>: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    @Binding var selectedTab: TOCView.Tab
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(TOCView.Tab.allCases.filter { ![.terminal, .git, .search].contains($0) && ($0 != .feature || store.hasIssues) }, id: \.self) { tab in
                    PanelTabButton(title: tab.title, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(4).background(palette.bg)
            Divider().background(palette.border)
            content()
        }
        .background(palette.bgSidebar)
    }
}

/// Full-text search across the workspace index.
/// The meaning search of the project's Markdown documents (the semantic index): the Documents mode of the Search tab.
struct DocumentSearchView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var project: ProjectContext
    @Environment(\.windowCommands) private var window
    @State private var searchQuery = ""
    @State private var searchResults: [SemanticDatabase.SearchResult] = []
    /// The search and the opening of a result this panel started: they end with the panel, and a new one replaces its own kind (`AR-19`).
    @State private var tasks = TaskBag()

    var body: some View {
        VStack(spacing: 0) {
            // Search input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").uiFont(size: 11).foregroundColor(palette.textDim)
                TextField("Search all files...", text: $searchQuery, onCommit: { performSearch() })
                    .textFieldStyle(.plain).uiFont(size: 11).foregroundColor(palette.text)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; searchResults = [] }) {
                        Image(systemName: "xmark.circle.fill").uiFont(size: 10).foregroundColor(palette.textDim)
                    }.buttonStyle(.plain)
                }
            }.padding(8).background(palette.bgInput)

            // Results
            if searchResults.isEmpty {
                VStack { Spacer(); Text(searchQuery.isEmpty ? "Type to search" : "No results").foregroundColor(palette.textDim); Spacer() }
                    .frame(maxWidth: .infinity).background(palette.bgSidebar)
            } else {
                List {
                    ForEach(searchResults.indices, id: \.self) { i in
                        let r = searchResults[i]
                        Button(action: { openSearchResult(r) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).uiFont(size: 11, weight: .medium).foregroundColor(palette.blue)
                                Text(r.snippet.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: ""))
                                    .uiFont(size: 9).foregroundColor(palette.text).lineLimit(3)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden).background(palette.bgSidebar)
            }
        }
    }

    private func performSearch() {
        guard let db = project.database, !searchQuery.isEmpty else { return }
        let query = searchQuery
        // The query runs on the database actor; an answer to an older query never replaces a newer one.
        tasks.store(Task {
            let found = await db.search(query: query)
            guard query == searchQuery, !Task.isCancelled else { return }
            searchResults = found
        }, for: "search")
    }

    private func openSearchResult(_ result: SemanticDatabase.SearchResult) {
        guard let root = project.rootNode, let window else { return }
        let term = searchQuery
        tasks.store(Task {
            // docIds are workspace-relative paths (or `@linked/...`): resolved directly, which is one file check.
            var url = project.fileURL(forDocumentId: result.documentId)
            if url == nil {
                // Fallback by-name search: headings/entity names, or legacy filename docIds. A tree walk, so off the main thread.
                let name = result.documentId, folder = root.url
                url = await Task.detached(priority: .userInitiated) { BackgroundFileScans.firstFile(named: name, in: folder) }.value
            }
            guard let url, !Task.isCancelled else { return }
            window.openFile(url)
            // Extract search term from snippet for scroll
            let searchTerm = term.prefix(40).replacingOccurrences(of: "'", with: "\\'")
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(.scrollToText, for: window, object: String(searchTerm))
        }, for: "open")
    }
}

#Preview {
    let workspaceManager = WorkspaceManager(prompts: AlertPrompts())
    return TOCView(layout: workspaceManager.layout, terminals: workspaceManager.terminals).observingParts(of: workspaceManager)
}
