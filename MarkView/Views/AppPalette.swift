import AppKit
import SwiftUI

extension Color {
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}

extension NSColor {
    convenience init(_ color: ThemeColor) {
        self.init(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: 1)
    }
}

extension ThemeColor {
    /// The colour a person picked, in sRGB; nil when it cannot be converted.
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        self.init(byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent))
    }
}

/// The colours the views of one window draw with, as SwiftUI colours. Views read it from the environment
/// (`@Environment(\.palette)`), so two windows with different themes draw side by side.
struct AppPalette: Equatable {
    let model: ThemePalette

    let bg, bgSidebar, bgInput, bgHover, bgActive, bgBanner: Color
    let text, textDim, textBright: Color
    let border, selection, accent, onAccent, badge: Color
    let blue, green, orange, yellow, purple, red, cyan: Color

    init(_ model: ThemePalette) {
        self.model = model
        bg = Color(model.bg); bgSidebar = Color(model.bgSidebar); bgInput = Color(model.bgInput)
        bgHover = Color(model.bgHover); bgActive = Color(model.bgActive); bgBanner = Color(model.bgBanner)
        text = Color(model.text); textDim = Color(model.textDim); textBright = Color(model.textBright)
        border = Color(model.border); selection = Color(model.selection); accent = Color(model.accent)
        onAccent = Color(model.onAccent); badge = Color(model.badge)
        blue = Color(model.blue); green = Color(model.green); orange = Color(model.orange); yellow = Color(model.yellow)
        purple = Color(model.purple); red = Color(model.red); cyan = Color(model.cyan)
    }

    var theme: AppTheme { model.theme }
    var isDark: Bool { model.isDark }

    /// The same colour for AppKit drawing.
    func ns(_ color: ThemeColor) -> NSColor { NSColor(color) }
    var nsBackground: NSColor { NSColor(model.bg) }
    var nsText: NSColor { NSColor(model.text) }
    var nsSelection: NSColor { NSColor(model.selection) }
    var nsAccent: NSColor { NSColor(model.accent) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette(ThemePalette.make(.classicDark))
}

extension EnvironmentValues {
    /// The palette of the window that shows this view.
    var palette: AppPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Publishes a window's palette and theme to every view below it, and tints controls with its accent.
private struct WindowThemeRoot: ViewModifier {
    @ObservedObject var theme: WindowTheme

    func body(content: Content) -> some View {
        content
            .environment(\.palette, theme.palette)
            .environmentObject(theme)
            .tint(theme.palette.accent)
            .foregroundStyle(theme.palette.text)
    }
}

/// Renders `content` with the palette of `theme` and again whenever it changes, so a view that creates its own
/// workspace can read the palette in its own body.
struct WindowThemeHost<Content: View>: View {
    @ObservedObject var theme: WindowTheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().modifier(WindowThemeRoot(theme: theme))
    }
}

extension View {
    /// Give the views below this one the palette of `theme` (the root of a window or of a hosted view).
    func windowThemed(_ theme: WindowTheme) -> some View {
        modifier(WindowThemeRoot(theme: theme))
    }
}
