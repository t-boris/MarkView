import SwiftUI

/// VS Code-style status bar at the bottom of the editor
struct DiagnosticsBarView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var project: ProjectContext

    var body: some View {
        HStack(spacing: 0) {
            // Indexing progress (out-of-process structural index)
            if let progress = project.structuralIndexProgress {
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
