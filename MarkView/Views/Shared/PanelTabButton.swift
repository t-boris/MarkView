import SwiftUI

extension Color {
    /// A colour from 0xRRGGBB (labels coloured by GitHub).
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Segment in a side panel's tab bar.
struct PanelTabButton: View {
    @Environment(\.palette) private var palette
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).uiFont(size: 10, weight: isSelected ? .semibold : .regular)
                .frame(maxWidth: .infinity).padding(.vertical, 3)
                .foregroundColor(isSelected ? palette.textBright : palette.textDim)
                .background(isSelected ? palette.bgActive : Color.clear).cornerRadius(4)
        }.buttonStyle(.plain)
    }
}
