import SwiftUI

/// AI panel (alternative to the Table of Contents side): the terminals where the
/// assistants (claude, codex) run, with ready-made prompts. Search and Git live next to
/// the Table of Contents in `TOCView`. (The type keeps its historical name from the
/// removed Modules tab.)
struct ModuleExplorerView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        let _ = workspaceManager.themeVersion // force re-render on theme change
        VStack(spacing: 0) {
            // Title and stats
            HStack(spacing: 6) {
                Text("Terminal").font(.system(size: 11, weight: .semibold)).foregroundColor(VSDark.text)
                Spacer()
                if let db = workspaceManager.semanticDatabase {
                    let stats = db.getUsageStats()
                    if stats.totalJobs > 0 {
                        Text("$\(String(format: "%.2f", stats.totalCostDollars))")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(VSDark.textDim)
                    }
                }
                if let progress = workspaceManager.indexingProgress {
                    ProgressView().scaleEffect(0.4)
                    Text(progress).font(.system(size: 8)).foregroundColor(VSDark.blue).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(VSDark.bg)
            Divider().background(VSDark.border)

            AITerminalPanel().environmentObject(workspaceManager)
        }
        .frame(minWidth: 260, idealWidth: 340)
    }
}
