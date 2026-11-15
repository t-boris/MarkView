import SwiftUI

/// VS Code-style status bar at the bottom of the editor
struct DiagnosticsBarView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var tabs: TabsController

    var body: some View {
        HStack(spacing: 0) {
            // Left: active block info
            if let tab = tabs.activeTab, let activeId = tab.activeBlockId,
               let block = tab.blocks.first(where: { $0.id == activeId }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.text.square")
                        .uiFont(size: 9)
                        .foregroundColor(palette.blue)
                    Text("\(block.type.rawValue) L\(block.lineStart)")
                        .uiFont(size: 10)
                        .foregroundColor(palette.text)
                }
                .padding(.horizontal, 10)
            }

            // Indexing progress (out-of-process structural index)
            if let progress = workspaceManager.structuralIndexProgress {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                    Text(progress)
                        .uiFont(size: 10)
                        .foregroundColor(palette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
            }

            Spacer()

            Spacer()
        }
        .frame(height: 20)
        .background(palette.bgBanner)
        .overlay(Rectangle().frame(height: 1).foregroundColor(palette.border), alignment: .top)
    }
}
