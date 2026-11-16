import SwiftUI

/// What a view asks of its window as a whole: the commands that cut across the window's parts (show a file in a tab with the panels that
/// go with it, open a tool's tab, delete the folder's metadata). A view that only issues one of these takes this and not the
/// `WorkspaceManager` that implements it (`AR-14`): it reads nothing of the window's other parts and is not redrawn when they change.
///
/// The window puts itself in the environment of its views (`observingParts(of:)`). A view outside any window finds nothing there, and
/// its command does nothing.
@MainActor
protocol WindowCommands: AnyObject {
    /// Show `url` in a tab, or return to its tab.
    func openFile(_ url: URL)
    /// Open the tab of a tool of `ToolRegistry`, or return to it.
    func openTool(_ id: ToolID)
    /// Delete this folder's metadata after confirmation; with `recreate`, index the folder again.
    func removeMetadata(recreate: Bool)
}

private struct WindowCommandsKey: EnvironmentKey {
    static let defaultValue: (any WindowCommands)? = nil
}

extension EnvironmentValues {
    /// The window the view is in, as its commands; nil outside a window.
    var windowCommands: (any WindowCommands)? {
        get { self[WindowCommandsKey.self] }
        set { self[WindowCommandsKey.self] = newValue }
    }
}
