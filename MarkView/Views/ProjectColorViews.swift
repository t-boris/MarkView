import SwiftUI

extension Color {
    init(_ projectColor: ProjectColor) {
        self.init(.sRGB, red: projectColor.red, green: projectColor.green, blue: projectColor.blue)
    }
}

/// The project-colored icon beside the window title (feature-2, DEC-007). It sits next to the
/// folder proxy icon, which keeps its own behavior; clicking it opens the palette (DEC-005).
/// Toolbar content does not get the window's environment objects, so everything is passed in.
struct ProjectColorButton: View {
    @ObservedObject var store: ProjectColorStore
    let projectKey: String
    @State private var choosing = false

    var body: some View {
        let current = store.color(forKey: projectKey)
        Button(action: { choosing.toggle() }) {
            Image(systemName: "circle.fill")
                .foregroundStyle(Color(current))
        }
        .help("Project color: \(current.name) — click to change")
        .accessibilityLabel("Project color: \(current.name)")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            ProjectColorPicker(selected: current) { color in
                store.set(color, forKey: projectKey)
                choosing = false
            }
        }
    }
}

/// The fixed palette (DEC-009) as swatches; the current color carries a check mark.
private struct ProjectColorPicker: View {
    let selected: ProjectColor
    let choose: (ProjectColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project Color").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 10), count: 4), spacing: 10) {
                ForEach(ProjectColor.palette) { color in
                    Button(action: { choose(color) }) {
                        Circle()
                            .fill(Color(color))
                            .frame(width: 24, height: 24)
                            .overlay {
                                if color == selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.name)
                    .accessibilityLabel(color.name)
                }
            }
            Text("Every window of this folder shows it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

/// A thin band in the project color below the toolbar; it spans the window, so the color stays
/// visible in Mission Control thumbnails, where the icon is only a dot (DEC-013).
struct ProjectColorBand: View {
    let color: ProjectColor

    var body: some View {
        Rectangle()
            .fill(Color(color))
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}
