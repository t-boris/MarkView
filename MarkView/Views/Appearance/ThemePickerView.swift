import SwiftUI

/// The theme picker of a window: System and the themes of the catalog (Classic while it is active), the accent of the
/// chosen appearance, and what is wrong with the themes (files ignored, a chosen theme that is gone). Opened from the header
/// button and from View > Theme (Shift-Cmd-T). Everything it changes belongs to the window that opened it.
struct ThemePickerView: View {
    @EnvironmentObject var theme: WindowTheme
    @Environment(\.palette) private var palette
    var project: URL? = nil
    @ObservedObject private var transparencyStore = ProjectTransparencyStore.shared
    private var workspaceTransparency: Double { transparencyStore.value(for: project) }

    /// Accents offered next to the appearance's own; any other colour comes from the colour well.
    private static let swatches: [(name: String, color: ThemeColor)] = [
        ("Blue", ThemeColor(0x4C8DFF)), ("Teal", ThemeColor(0x2BB5A6)), ("Green", ThemeColor(0x4CAF50)),
        ("Yellow", ThemeColor(0xE0B422)), ("Orange", ThemeColor(0xE6A15C)), ("Red", ThemeColor(0xE5534B)),
        ("Pink", ThemeColor(0xE35D9B)), ("Violet", ThemeColor(0x9B7BE0)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Theme").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim).textCase(.uppercase)
            VStack(spacing: 2) {
                ForEach(theme.catalog.library.choices(current: theme.settings.theme)) { choice in
                    row(choice)
                }
            }
            ThemeNotices(catalog: theme.catalog)
            Divider().overlay(palette.border)
            accentSection
            Divider().overlay(palette.border)
            HStack {
                Text("Workspace transparency").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
                Spacer()
                Text("\(Int(workspaceTransparency * 100))% ").uiFont(size: 11).foregroundColor(palette.text)
            }
            Slider(value: transparencyStore.binding(for: project), in: 0...0.7, step: 0.05)
                .disabled(project == nil)
                .accessibilityLabel("Workspace transparency")
                .help("Show this project’s welcome background behind its panels")
        }
        .padding(14)
        .frame(width: 320)
        .background(palette.bgSidebar)
        // A theme file added while the app runs shows up the next time the picker opens.
        .task { await theme.catalog.reload() }
    }

    private func row(_ choice: ThemeLibrary.Choice) -> some View {
        let selected = theme.settings.theme == choice.theme
        let preview = theme.previewPalette(for: choice.theme)
        return Button { theme.select(choice.theme) } label: {
            HStack(spacing: 10) {
                ThemePreview(palette: preview)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).uiFont(size: 12, weight: .medium).foregroundColor(palette.textBright)
                    Text(choice.summary).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").uiFont(size: 11, weight: .semibold).foregroundColor(palette.blue) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? palette.bgActive : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var themeName: String { theme.catalog.library.name(of: theme.settings.theme) }

    private var accentSection: some View {
        let override = theme.settings.activeOverride
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accent").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim).textCase(.uppercase)
                Spacer()
                Button("Reset") { theme.setAccent(nil) }
                    .buttonStyle(.plain).uiFont(size: 11)
                    .foregroundColor(override == nil ? palette.textDim : palette.blue)
                    .disabled(override == nil)
                    .help("Use the accent of \(themeName)")
            }
            HStack(spacing: 7) {
                swatch(name: "\(themeName) default",
                       color: theme.defaultAccent, selected: override == nil) { theme.setAccent(nil) }
                ForEach(Self.swatches, id: \.name) { item in
                    swatch(name: item.name, color: item.color, selected: override == item.color) { theme.setAccent(item.color) }
                }
            }
            ColorPicker("Custom colour", selection: Binding(
                get: { Color(theme.effectiveAccent) },
                set: { picked in if let color = ThemeColor(NSColor(picked)) { theme.setAccent(color) } }
            ), supportsOpacity: false)
            .uiFont(size: 11).foregroundColor(palette.text)
            Text("Each theme remembers its own accent in this window.")
                .uiFont(size: 10).foregroundColor(palette.textDim)
        }
    }

    private func swatch(name: String, color: ThemeColor, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(Color(color)).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(palette.textBright, lineWidth: selected ? 2 : 0).padding(-3))
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("\(name) accent")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What is wrong with the themes, said where a person picks one: theme files that could not be used and why, a theme that is
/// chosen in some window but gone, and the way to the folder for their own themes.
private struct ThemeNotices: View {
    @ObservedObject var catalog: ThemeCatalog
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(catalog.missing, id: \.self) { id in
                Text("Theme “\(id)” was not found; Classic Dark is shown instead.")
                    .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
            let ignored = catalog.library.ignored
            if !ignored.isEmpty {
                Text(ignored.count == 1 ? "1 custom theme ignored" : "\(ignored.count) custom themes ignored")
                    .uiFont(size: 10, weight: .semibold).foregroundColor(palette.orange)
                ForEach(ignored) { item in
                    Text("\(item.file): \(item.reason)")
                        .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Button("Open themes folder") { Self.revealFolder() }
                .buttonStyle(.plain).uiFont(size: 10).foregroundColor(palette.blue)
                .help("Put your own theme files (JSON) here")
        }
        .padding(.top, 2)
    }

    /// The folder for a person's own themes, made when it is first asked for; nothing else is ever written there.
    private static func revealFolder() {
        let folder = ThemeCatalog.userFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// A miniature of a window in a theme: background, panel, a line of text and the accent.
private struct ThemePreview: View {
    let palette: AppPalette

    var body: some View {
        HStack(spacing: 0) {
            palette.bgSidebar.frame(width: 14)
            ZStack(alignment: .topLeading) {
                palette.bg
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(palette.accent).frame(width: 16, height: 3)
                    RoundedRectangle(cornerRadius: 1).fill(palette.text).frame(width: 24, height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(palette.textDim).frame(width: 18, height: 2)
                }
                .padding(5)
            }
        }
        .frame(width: 46, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Presents the picker as a popover of `theme.showsPicker`, so the header button and the View menu open the same one.
private struct ThemePickerPresenter: ViewModifier {
    @ObservedObject var theme: WindowTheme
    var project: URL?

    func body(content: Content) -> some View {
        content.popover(isPresented: $theme.showsPicker, arrowEdge: .bottom) {
            ThemePickerView(project: project)
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
    }
}

extension View {
    /// Attach the theme picker of `theme` to this view.
    func themePicker(_ theme: WindowTheme, project: URL? = nil) -> some View {
        modifier(ThemePickerPresenter(theme: theme, project: project))
    }
}
