import SwiftUI

/// AI panel (alternative to the Table of Contents side): per-document actions and
/// the AI discussion. Search and Git live next to the Table of Contents in `TOCView`.
/// (The type keeps its historical name from the removed Modules tab.)
struct ModuleExplorerView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    // Stored tag values predate the move of Search/Git; anything but Actions
    // (3, formerly Diagrams) opens the discussion.
    @AppStorage(WorkspaceManager.aiPanelTabKey) private var selectedTab = WorkspaceManager.aiPanelDiscussionTab

    var body: some View {
        let _ = workspaceManager.themeVersion // force re-render on theme change
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                VSDarkTabButton(title: "Actions", isSelected: showsActions) {
                    selectedTab = WorkspaceManager.aiPanelActionsTab
                }
                VSDarkTabButton(title: "Discussion", isSelected: !showsActions) {
                    selectedTab = WorkspaceManager.aiPanelDiscussionTab
                }
            }
            .padding(4).background(VSDark.bg)
            Divider().background(VSDark.border)

            // Stats
            if let db = workspaceManager.semanticDatabase {
                let stats = db.getUsageStats()
                if stats.totalJobs > 0 || workspaceManager.indexingProgress != nil {
                    HStack(spacing: 6) {
                        Spacer()
                        if stats.totalJobs > 0 {
                            Text("$\(String(format: "%.2f", stats.totalCostDollars))")
                                .font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textDim)
                        }
                        if let progress = workspaceManager.indexingProgress {
                            ProgressView().scaleEffect(0.4)
                            Text(progress)
                                .font(.system(size: 8)).foregroundColor(VSDark.blue).lineLimit(1)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 3).background(VSDark.bgSidebar)
                }
            }

            // Content
            if showsActions {
                ActionsView(store: workspaceManager.documentActions).environmentObject(workspaceManager)
            } else {
                AIConsoleView().environmentObject(workspaceManager)
            }
        }
        .frame(minWidth: 260, idealWidth: 340)
    }

    private var showsActions: Bool { selectedTab == WorkspaceManager.aiPanelActionsTab }
}
