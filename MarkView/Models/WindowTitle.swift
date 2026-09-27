import Foundation

/// Title of a workspace window: "MarkView 2.18.0 — my-project", or "MarkView 2.18.0" without
/// a folder (issue #25). Foundation only, so tools/tests/window-title-tests.sh compiles it alone.
enum WindowTitle {
    /// Parts that are empty are left out, so there is never a double or dangling separator.
    static func text(version: String, folderName: String?) -> String {
        var title = "MarkView"
        if !version.isEmpty { title += " " + version }
        if let folderName, !folderName.isEmpty { title += " — " + folderName }
        return title
    }

    /// The folder as Finder names it (localized, volume name for "/"), else its last path component.
    static func folderName(of url: URL) -> String {
        let display = FileManager.default.displayName(atPath: url.path)
        return display.isEmpty ? url.lastPathComponent : display
    }
}
