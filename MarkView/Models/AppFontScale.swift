import SwiftUI

/// Application-wide interface text scale (issue #40, docs/features/feature DEC-008/DEC-011).
/// A percentage applied to every interface text style's own base size, so the existing
/// typographic hierarchy stays proportional. Document text (editor, Markdown and code preview,
/// GitHub issue bodies) is owned by the editor slider and never reads this value (DEC-006/DEC-009).
enum AppFontScale {
    /// One UserDefaults value for all windows and workspaces, separate from the editor
    /// slider's `markview-font-size` in web localStorage.
    static let storageKey = "appFontScalePercent"
    static let defaultPercent = 100
    static let range = 80...200
    static let step = 10

    /// A stored value is used only when it is one of the offered steps; anything else
    /// (missing, out of range, off-step) falls back to 100%.
    static func validated(_ percent: Int) -> Int {
        range.contains(percent) && percent % step == 0 ? percent : defaultPercent
    }

    static func factor(percent: Int) -> CGFloat {
        CGFloat(validated(percent)) / 100
    }

    /// The saved scale, for code outside the SwiftUI environment (a web view's first load).
    static var storedFactor: CGFloat {
        factor(percent: UserDefaults.standard.object(forKey: storageKey) as? Int ?? defaultPercent)
    }

    /// macOS point sizes of the SwiftUI text styles the views use.
    static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }

    static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight {
        style == .headline ? .bold : .regular
    }
}

/// Swift's read-only copy of the editor slider's document text size. The slider keeps its own
/// value in web localStorage; this mirror lets native-hosted document text (the GitHub issue
/// body viewer) follow the same control.
enum EditorTextSize {
    static let mirrorKey = "editorTextSizeMirror"
    static let defaultSize = 13.0
    static let range = 10.0...20.0

    static func validated(_ size: Double) -> Double {
        range.contains(size) ? size : defaultSize
    }
}

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
