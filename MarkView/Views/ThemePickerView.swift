import SwiftUI

/// The theme picker of a window: System and the four presets (Classic while it is active), and the accent of the
/// chosen appearance. Opened from the header button and from View > Theme (Shift-Cmd-T). Everything it changes
/// belongs to the window that opened it.
struct ThemePickerView: View {
    @EnvironmentObject var theme: WindowTheme
    @Environment(\.palette) private var palette

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
                ForEach(AppTheme.pickerChoices(current: theme.settings.theme), id: \.self) { choice in
                    row(choice)
                }
            }
            Divider().overlay(palette.border)
            accentSection
        }
        .padding(14)
        .frame(width: 320)
        .background(palette.bgSidebar)
    }

    private func row(_ choice: AppTheme) -> some View {
        let selected = theme.settings.theme == choice
        let preview = theme.previewPalette(for: choice)
        return Button { theme.select(choice) } label: {
            HStack(spacing: 10) {
                ThemePreview(palette: preview)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.displayName).uiFont(size: 12, weight: .medium).foregroundColor(palette.textBright)
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
        .accessibilityLabel("\(choice.displayName) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

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
                    .help("Use the accent of \(theme.settings.theme.displayName)")
            }
            HStack(spacing: 7) {
                swatch(name: "\(theme.settings.theme.displayName) default",
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

    func body(content: Content) -> some View {
        content.popover(isPresented: $theme.showsPicker, arrowEdge: .bottom) {
            ThemePickerView()
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
    }
}

extension View {
    /// Attach the theme picker of `theme` to this view.
    func themePicker(_ theme: WindowTheme) -> some View {
        modifier(ThemePickerPresenter(theme: theme))
    }
}
