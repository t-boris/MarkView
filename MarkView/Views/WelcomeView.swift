import SwiftUI
import AppKit

/// The screen a window shows while no file is open (feature welcome-screen-with-action-tiles-and-a-falling): action tiles over an
/// animated backdrop. It takes plain inputs, and what runs when a tile is pressed, so a check can host it without a workspace; the
/// list under the tiles ("Ready to resume", drafts and recent projects) comes in as `below`.
struct WelcomeScreen<Below: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.appFontScale) private var appFontScale
    /// The background of THIS window. The window's `PanelLayout` keeps it: a shared @AppStorage value would change the screen of every
    /// window at once (BUG-120).
    @Binding private var backdrop: WelcomeBackdrop
    /// Drawn once each time the screen appears: Shuffle must not change the scene while it is shown.
    @State private var shufflePick = Int.random(in: 0..<WelcomeBackdrop.animated.count)
    @State private var seed = UInt64.random(in: 1...UInt64.max)

    /// Name of the open folder; nil in a window without one.
    let projectName: String?
    let isGitRepo: Bool
    /// A still picture instead of the animation (a check looks at the scene).
    let still: Bool
    let perform: (WelcomeActionID) -> Void
    let below: Below

    init(projectName: String?, isGitRepo: Bool = false, backdrop: Binding<WelcomeBackdrop>, still: Bool = false,
         perform: @escaping (WelcomeActionID) -> Void, @ViewBuilder below: () -> Below) {
        self.projectName = projectName
        self.isGitRepo = isGitRepo
        _backdrop = backdrop
        self.still = still
        self.perform = perform
        self.below = below()
    }

    private var choice: Binding<WelcomeBackdrop> {
        Binding(get: { backdrop },
                set: { picked in
                    backdrop = picked
                    if picked == .shuffle { shufflePick = Int.random(in: 0..<WelcomeBackdrop.animated.count) }
                })
    }

    private var tileColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 235 * min(appFontScale, 1.4)), spacing: 10)]
    }

    var body: some View {
        ZStack {
            palette.bg
            let scene = choice.wrappedValue.scene(pick: shufflePick)
            if scene != .off {
                WelcomeBackdropView(kind: scene, colors: BackdropColors(palette), seed: seed, still: still)
                    .accessibilityHidden(true)
            }
            GeometryReader { proxy in
                ScrollView {
                    // As tall as the window at least, so a short column sits in the middle of it.
                    column
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                        // Beside the app icon, inside the scrolled column: a pill pinned to the window corner sat on the last row of
                        // tiles whenever the column was taller than the window (found in the running app, 5.53.0).
                        .overlay(alignment: .topTrailing) { backdropMenu.padding(.top, 24).padding(.trailing, 24) }
                }
            }
        }
        .clipped()
    }

    // MARK: - Content

    private var column: some View {
        VStack(spacing: 22) {
            header
            if projectName != nil {
                ForEach(WelcomeCatalogue.project(isGitRepo: isGitRepo), id: \.section) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.section.rawValue.uppercased())
                            .tracking(1.4)
                            .uiFont(size: 10, weight: .semibold)
                            .foregroundColor(palette.textDim)
                            .halo(palette.bg)
                        LazyVGrid(columns: tileColumns, spacing: 10) {
                            ForEach(group.actions) { action in WelcomeTile(action: action) { perform(action.id) } }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: tileColumns, spacing: 10) {
                    ForEach(WelcomeCatalogue.emptyWindow) { action in WelcomeTile(action: action) { perform(action.id) } }
                }
            }
            below
        }
        .frame(maxWidth: 760)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: palette.accent.opacity(0.55), radius: 18)
            // The words that have no card get a halo of the window colour, so the backdrop never lowers their legibility.
            Text(projectName ?? "MarkView")
                .uiFont(size: 28, weight: .bold)
                .foregroundColor(palette.textBright)
                .lineLimit(1)
                .truncationMode(.middle)
                .halo(palette.bg)
            Text(projectName == nil ? "Open a project to begin" : "No file is open. Pick where to start.")
                .uiFont(size: 13)
                .foregroundColor(palette.textDim)
                .halo(palette.bg)
        }
    }

    private var backdropMenu: some View {
        Menu {
            Picker("Background", selection: choice) {
                ForEach(WelcomeBackdrop.allCases) { backdrop in
                    Label(backdrop.title, systemImage: backdrop.symbol).tag(backdrop)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(choice.wrappedValue.title, systemImage: "wand.and.stars")
                .uiFont(size: 11)
                .foregroundColor(palette.textDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(palette.bgActive.opacity(0.9)))
        .overlay(Capsule().stroke(palette.border, lineWidth: 1))
        .help("Choose the animated background of this screen")
    }
}

/// One action: an icon, a title, a line of hint and the shortcut, on a card that is nearly opaque so a backdrop never costs legibility.
struct WelcomeTile: View {
    @Environment(\.palette) private var palette
    @Environment(\.appFontScale) private var appFontScale
    let action: WelcomeAction
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .uiFont(size: 15, weight: .semibold)
                    .foregroundColor(action.isProminent ? palette.onAccent : palette.accent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(action.isProminent ? palette.onAccent.opacity(0.18) : palette.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .uiFont(size: 13, weight: .semibold)
                        .foregroundColor(action.isProminent ? palette.onAccent : palette.textBright)
                        .lineLimit(1)
                    Text(action.hint)
                        .uiFont(size: 11)
                        .foregroundColor(action.isProminent ? palette.onAccent.opacity(0.85) : palette.textDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .uiFont(size: 10, weight: .medium, design: .monospaced)
                        .foregroundColor(action.isProminent ? palette.onAccent : palette.textDim)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .stroke(action.isProminent ? palette.onAccent.opacity(0.5) : palette.border, lineWidth: 1))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64 * min(appFontScale, 1.5), alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovering ? palette.accent : palette.border.opacity(0.8), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.hint)
    }

    private var fill: Color {
        if action.isProminent { return palette.accent.opacity(hovering ? 1 : 0.92) }
        return (hovering ? palette.bgHover : palette.bgActive).opacity(0.94)
    }
}

private extension View {
    /// A soft outline of `color` around text.
    func halo(_ color: Color) -> some View {
        shadow(color: color, radius: 4).shadow(color: color, radius: 8)
    }
}
