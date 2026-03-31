import SwiftUI

/// VS Code-style status bar at the bottom of the editor
struct DiagnosticsBarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack(spacing: 0) {
            // Left: active block info
            if let tab = activeTab, let activeId = tab.activeBlockId,
               let block = tab.blocks.first(where: { $0.id == activeId }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.text.square")
                        .font(.system(size: 9))
                        .foregroundColor(VSDark.blue)
                    Text("\(block.type.rawValue) L\(block.lineStart)")
                        .font(.system(size: 10))
                        .foregroundColor(VSDark.text)
                }
                .padding(.horizontal, 10)
            }

            Spacer()

            // Center: just show token stats (no duplicate progress)
            if let compiler = workspaceManager.incrementalCompiler {
                let orch = compiler.orchestrator
                if orch.isDisabled {
                    Text("AI Offline")
                        .font(.system(size: 10))
                        .foregroundColor(VSDark.red)
                        .padding(.horizontal, 8)
                }

                let totalTk = orch.totalInputTokens + orch.totalOutputTokens
                if totalTk > 0 {
                    let cost = Double(orch.totalInputTokens) * 0.000003 + Double(orch.totalOutputTokens) * 0.000015
                    Text("\(orch.completedJobCount) jobs · \(formatTokens(totalTk)) · $\(String(format: "%.3f", cost))")
                        .font(.system(size: 10))
                        .foregroundColor(VSDark.textDim)
                        .padding(.horizontal, 8)
                }
            }

            Spacer()

            // Right: counts
            if let compiler = workspaceManager.incrementalCompiler {
                let ent = compiler.orchestrator.extractedEntities.count
                let clm = compiler.orchestrator.extractedClaims.count
                let errs = compiler.diagnostics.filter { $0.severity == .error }.count
                let warns = compiler.diagnostics.filter { $0.severity == .warning }.count

                HStack(spacing: 10) {
                    if errs > 0 {
                        Label("\(errs)", systemImage: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(VSDark.red)
                    }
                    if warns > 0 {
                        Label("\(warns)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(VSDark.orange)
                    }
                    Label("\(ent)", systemImage: "cube")
                        .font(.system(size: 10))
                        .foregroundColor(VSDark.green)
                    Label("\(clm)", systemImage: "text.badge.checkmark")
                        .font(.system(size: 10))
                        .foregroundColor(VSDark.blue)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(height: 24)
        .background(VSDark.bgBanner)
        .overlay(Rectangle().frame(height: 1).foregroundColor(VSDark.border), alignment: .top)
    }

    private func formatTokens(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k tk" : "\(n) tk"
    }

    private var activeTab: OpenTab? {
        guard workspaceManager.activeTabIndex >= 0,
              workspaceManager.activeTabIndex < workspaceManager.openTabs.count else { return nil }
        return workspaceManager.openTabs[workspaceManager.activeTabIndex]
    }
}
