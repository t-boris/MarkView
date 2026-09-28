import SwiftUI

/// Shared assistant terminal surface. The type keeps its historical name from
/// the removed Modules tab.
struct ModuleExplorerView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.appFontScale) private var fontScale

    var body: some View {
        let _ = workspaceManager.themeVersion // force re-render on theme change
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let showStats = geometry.size.width >= 460 * max(1, fontScale)
                HStack(spacing: 6) {
                    Text("Terminal").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if showStats {
                        AgentUsageBar()
                        if let db = workspaceManager.semanticDatabase {
                            let stats = db.getUsageStats()
                            if stats.totalJobs > 0 {
                                Text("$\(String(format: "%.2f", stats.totalCostDollars))")
                                    .uiFont(size: 9, weight: .bold).foregroundColor(VSDark.textDim)
                            }
                        }
                        if let progress = workspaceManager.indexingProgress {
                            ProgressView().scaleEffect(0.4)
                            Text(progress).uiFont(size: 8).foregroundColor(VSDark.blue).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 26 * min(1.5, max(1, fontScale)))
            .background(VSDark.bg)
            Divider().background(VSDark.border)

            AITerminalPanel().environmentObject(workspaceManager)
        }
    }
}
