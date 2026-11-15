import SwiftUI

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Interface text scale factor (1 = 100%), set once per window by `appFontScaled()`.
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

/// Reads the stored preference and publishes it to the window's view tree, together with a
/// scaled default font for text and controls that have no explicit font.
private struct AppFontScaleRoot: ViewModifier {
    @AppStorage(AppFontScale.storageKey) private var percent = AppFontScale.defaultPercent

    func body(content: Content) -> some View {
        let scale = AppFontScale.factor(percent: percent)
        content
            .font(.system(size: AppFontScale.pointSize(.body) * scale))
            .environment(\.appFontScale, scale)
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let italic: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        content.font(italic ? font.italic() : font)
    }
}

extension View {
    /// Apply at the root of every window (and hosting view) so its interface text follows the setting.
    func appFontScaled() -> some View {
        modifier(AppFontScaleRoot())
    }

    /// Interface font: `size` is the size at 100%; the application setting scales it.
    func uiFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                italic: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, italic: italic))
    }

    /// Interface font from a text style, at the style's macOS point size times the setting.
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        uiFont(size: AppFontScale.pointSize(style), weight: weight ?? AppFontScale.defaultWeight(style))
    }
}
