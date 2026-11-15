import Foundation

/// Which panels of one window are shown (`AR-14` step 6). Every window owns one, so opening the file tree in one window leaves the
/// others alone; the views that draw the panels observe it themselves, so a panel opening redraws the window frame and not what
/// shows the tabs, the file tree or Git.
///
/// UserDefaults gets the Contents column only as the STARTING value of the next new window (`WindowUIState` does the same for the
/// widths); the window keeps its own choice in its saved session.
@MainActor
final class WindowChrome: ObservableObject {
    static let contentsKey = "layout.showTOC.v3"

    /// The left panel. Every window starts with it closed, so a new window shows the center panel only.
    @Published var showFileTree = false
    /// The Contents column of the right panel.
    @Published var showTOC = false {
        didSet { defaults.set(showTOC, forKey: Self.contentsKey) }
    }
    /// The window is narrower than its full layout: panels give up the room they can.
    @Published var compactLayout = false
    @Published var showCenter = true
    /// The right panel (Contents, Tasks, Git).
    @Published var terminalVisible = false
    /// The floating agents panel.
    @Published var agentsVisible = false
    @Published var showGlobalSearch = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.contentsKey) != nil { showTOC = defaults.bool(forKey: Self.contentsKey) }
    }

    /// A toggle never hides the last panel: a window always shows something.
    func toggleNavigation() {
        guard !showFileTree || showCenter || terminalVisible else { return }
        showFileTree.toggle()
    }

    func toggleCenter() {
        guard !showCenter || showFileTree || terminalVisible else { return }
        showCenter.toggle()
    }

    func toggleRightPanel() {
        guard !terminalVisible || showFileTree || showCenter else { return }
        terminalVisible.toggle()
    }

    /// Hide the file tree and the agents panel of this window and leave the document, as for a file opened from Finder.
    /// The panels come back with their usual toggles.
    func showDocumentOnly() {
        showFileTree = false
        terminalVisible = false
        agentsVisible = false
        showCenter = true
    }

    /// The panels as the window session keeps them.
    func save(into panels: inout WorkspacePanelState) {
        panels.showFiles = showFileTree
        panels.showNavigator = showTOC
        panels.contentsVisible = showTOC
        panels.terminalVisible = terminalVisible
        panels.agentsVisible = agentsVisible
        panels.showCenter = showCenter
    }

    /// The panels of a saved session. Sessions saved before the agents panel and the Contents column were separate say less: the old
    /// navigator then decides what the right panel was.
    func restore(_ panels: WorkspacePanelState) {
        let navigator = NavigatorTab(rawValue: panels.navigator) ?? .contents
        let oldVisible = panels.terminalVisible ?? panels.showNavigator
        showFileTree = panels.showFiles
        showTOC = panels.contentsVisible ?? false
        showCenter = panels.showCenter ?? true
        agentsVisible = panels.agentsVisible ?? (navigator == .terminal && oldVisible)
        terminalVisible = panels.agentsVisible == nil && navigator == .terminal ? false : oldVisible
        if !showFileTree && !showCenter && !terminalVisible { showCenter = true }
    }
}
