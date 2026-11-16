import SwiftUI

struct SmallButton: View {
    @Environment(\.palette) private var palette
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).uiFont(size: 9) }
                Text(title).uiFont(size: 10, weight: prominent ? .semibold : .regular)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundColor(prominent ? .white : palette.text)
            .background(prominent ? palette.badge : palette.bgInput)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}
