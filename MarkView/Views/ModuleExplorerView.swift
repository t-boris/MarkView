import SwiftUI

/// Shared assistant terminal surface. The type keeps its historical name from
/// the removed Modules tab.
struct ModuleExplorerView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // Only the AI cost and the indexing progress give way when the panel is narrow. The agent usage
                // indicators live in the workspace top bar now (ContentView.workspaceHeader).
                let showStats = geometry.size.width >= 460 * max(1, fontScale)
                HStack(spacing: 6) {
                    Text("Agents").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if showStats {
                        if let db = workspaceManager.semanticDatabase {
                            let stats = db.getUsageStats()
                            if stats.totalJobs > 0 {
                                Text("$\(String(format: "%.2f", stats.totalCostDollars))")
                                    .uiFont(size: 9, weight: .bold).foregroundColor(palette.textDim)
                            }
                        }
                        if let progress = workspaceManager.indexingProgress {
                            ProgressView().scaleEffect(0.4)
                            Text(progress).uiFont(size: 8).foregroundColor(palette.blue).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 26 * min(1.5, max(1, fontScale)))
            .background(palette.bg)
            Divider().background(palette.border)

            AITerminalPanel().environmentObject(workspaceManager)
        }
    }
}
