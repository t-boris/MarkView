import SwiftUI

/// Left panel: the file tree, or — when the project has docs/features or docs/bugs — its issues:
/// features and bugs, each with its GitHub issue.
struct LeftPanelView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        LeftPanelContent(store: workspaceManager.flow.features, layout: workspaceManager.layout)
    }
}

private struct LeftPanelContent: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    /// This window's Files/Issues choice and open feature (BUG-004: not shared between windows).
    @ObservedObject var layout: PanelLayout
    @EnvironmentObject var workspaceManager: WorkspaceManager
    private var mode: String {
        get { layout.leftPanel }
        nonmutating set { layout.leftPanel = newValue }
    }
    /// The feature opened from the Issues list; kept so "New Feature" can open it.
    private var openFeature: String? {
        get { layout.issuesFeature.isEmpty ? nil : layout.issuesFeature }
        nonmutating set { layout.issuesFeature = newValue ?? "" }
    }

    var body: some View {
        let showingIssues = mode == "issues" && store.hasIssues
        VStack(spacing: 0) {
            if store.hasIssues {
                HStack(spacing: 4) {
                    sidebarButton("Files", symbol: "folder", selected: !showingIssues) { mode = "files" }
                    sidebarButton("Issues", symbol: "checklist", selected: showingIssues) { mode = "issues" }
                }
                .padding(6)
                Divider().background(palette.border)
            }
            if showingIssues {
                if let slug = openFeature, store.feature(slug) != nil {
                    FeatureNavigatorView(store: store, onBack: { openFeature = nil })
                } else {
                    IssuesListView(store: store, batch: workspaceManager.flow.bugBatch) { slug in
                        store.activeSlug = slug
                        openFeature = slug
                        workspaceManager.flow.showFeatureContext(slug)
                        if let feature = store.feature(slug) {
                            workspaceManager.openFile(feature.overviewURL)
                        }
                    }
                }
                // The basket stays in view while features are opened and closed (REQ-001).
                BugBasketView(batch: workspaceManager.flow.bugBatch, assistant: store.assistant)
            } else {
                FileTreeView()
            }
        }
        .background(palette.bgSidebar)
    }

    private func sidebarButton(_ title: String, symbol: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .uiFont(size: 11, weight: selected ? .semibold : .regular)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? palette.bgActive : Color.clear)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(title) sidebar")
    }
}
