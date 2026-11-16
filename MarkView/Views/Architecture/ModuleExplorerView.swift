import SwiftUI

/// Shared assistant terminal surface. The type keeps its historical name from
/// the removed Modules tab.
struct ModuleExplorerView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var project: ProjectContext
    /// The window's assistant terminals, which the panel shows.
    let terminals: AITerminalsController
    @Environment(\.appFontScale) private var fontScale
    /// AI spend of the project in dollars, read from the database actor; nil until the first answer or when nothing was spent.
    @State private var costDollars: Double?

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
                        if let costDollars {
                            Text("$\(String(format: "%.2f", costDollars))")
                                .uiFont(size: 9, weight: .bold).foregroundColor(palette.textDim)
                        }
                        if let progress = project.indexingProgress {
                            ProgressView().scaleEffect(0.4)
                            Text(progress).uiFont(size: 8).foregroundColor(palette.blue).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 26 * min(1.5, max(1, fontScale)))
            .background(palette.bg)
            Divider().background(palette.border)

            AITerminalPanel(terminals: terminals, folderOpen: project.rootNode != nil)
        }
        .task(id: project.database.map(ObjectIdentifier.init)) { await refreshCost() }
    }

    /// Re-read the spend every few seconds while the panel is on screen (the task ends with the view).
    private func refreshCost() async {
        guard let db = project.database else { costDollars = nil; return }
        while !Task.isCancelled {
            let stats = await db.getUsageStats()
            costDollars = stats.totalJobs > 0 ? stats.totalCostDollars : nil
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
