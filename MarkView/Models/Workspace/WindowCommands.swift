import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What a view asks of its window as a whole: the commands that cut across the window's parts (show a file in a tab with the panels that
/// go with it, open a tool's tab, delete the folder's metadata). A view that only issues one of these takes this and not the
/// `WorkspaceManager` that implements it (`AR-14`): the view does not observe the whole window. A few scoped services are also
/// exposed here when a command needs them; their own change signals stay separate.
///
/// The window puts itself in the environment of its views (`observingParts(of:)`). A view outside any window finds nothing there, and
/// its command does nothing.
@MainActor
protocol WindowCommands: ProjectOperationsPresenter {
    /// Show `url` in a tab, or return to its tab.
    func openFile(_ url: URL)
    /// Show `url` and, for code, reveal `line`…`endLine` in the code viewer.
    func openFile(_ url: URL, line: Int?, endLine: Int?)
    /// Show the PDF at `url` open at `page` (the reader scrolls there once the document is loaded).
    func openPDF(_ url: URL, page: Int)
    /// Show a key of a JSON / YAML file picked in the Contents panel: its tab comes forward and the viewer scrolls to the node.
    func revealStructure(_ url: URL, item: StructureOutline.Item)
    /// Open the tab of a tool of `ToolRegistry`, or return to it.
    func openTool(_ id: ToolID)
    /// Open `url` as this window's project (another working copy, a folder to browse as the project).
    func openFolder(_ url: URL)
    /// Open a terminal in `folder` as a tab of this window.
    func openTerminal(in folder: URL)
    /// Close the current project when its work permits it.
    @discardableResult func closeFolder() -> Bool
    /// Present the graph creator for a folder.
    func presentGraphCreator(for type: String, in folder: URL?)
    /// Present PDF-book export for the selected files or folders.
    func presentPDFBook(_ urls: [URL]?)
    /// File actions belonging to this window.
    var fileOperations: FileOperationsController { get }
    /// Open a local HTML file in this window’s browser.
    func openHTML(_ url: URL)
    /// Start Insight at a file or folder.
    func startInsight(at url: URL)
    /// Discuss a file or folder in this window.
    func discuss(about url: URL)
    /// The operations visible in this window's current project.
    var projectOperations: ProjectOperationsStore? { get }
    /// Open a local file and reveal its line fragment.
    func openFile(_ url: URL, lineFragment: String?)
    /// Open a wiki link in this window.
    func openWikiLink(note: String, heading: String?)
    /// Open a canvas file reference in this window.
    func openCanvasFileReference(_ path: String)
    /// Set the editor's code notes mode.
    func setNotesView(_ show: Bool, explain: Bool)
    /// Edit the graph currently shown in this window.
    func runGraphEdit(instruction: String, currentMermaid: String)
    /// Show the settings window for this window's project.
    func showSettings()
    /// Delete this folder's metadata after confirmation; with `recreate`, index the folder again.
    func removeMetadata(recreate: Bool)
}

extension WindowCommands {
    func openFile(_ url: URL, line: Int?) { openFile(url, line: line, endLine: nil) }
    func presentGraphCreator(in folder: URL?) { presentGraphCreator(for: "architecture", in: folder) }
    func presentGraphCreator(for type: String) { presentGraphCreator(for: type, in: nil) }
}

private struct WindowCommandsKey: EnvironmentKey {
    static var defaultValue: (any WindowCommands)? { nil }
}

extension EnvironmentValues {
    /// The window the view is in, as its commands; nil outside a window.
    var windowCommands: (any WindowCommands)? {
        get { self[WindowCommandsKey.self] }
        set { self[WindowCommandsKey.self] = newValue }
    }
}
