import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Application-wide interface text scale (issue #40, docs/features/feature DEC-008/DEC-011).
/// A percentage applied to every interface text style's own base size, so the existing
/// typographic hierarchy stays proportional. Document text (editor, Markdown and code preview,
/// GitHub issue bodies) is owned by the editor slider and never reads this value (DEC-006/DEC-009).
enum AppFontScale {
    /// One stored value (`Setting.fontScalePercent`) for all windows and workspaces, separate from the editor
    /// slider's `markview-font-size` in web localStorage.
    static let defaultPercent = Setting.fontScalePercent.defaultValue
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
    static var storedFactor: CGFloat { storedFactor(read: { Settings.standard.value(Setting.fontScalePercent) }) }

    static func storedFactor(read: () -> Int) -> CGFloat {
        factor(percent: read())
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
    static let defaultSize = Setting.editorTextSizeMirror.defaultValue
    static let range = 10.0...20.0

    static func validated(_ size: Double) -> Double {
        range.contains(size) ? size : defaultSize
    }
}

