import Foundation

extension WorkspaceManager {
    /// Applies a layout preset the person chose (`AR-33`, `DEC-002`) to this window and to no other: its panels, what the left and right
    /// panels show, and the tool tab the preset names. Nothing calls this by itself; the View menu and the toolbar's Layout menu do, on
    /// a click. The panels' visibility is this window's own (`chrome`, one per window), and `PanelLayout.apply` sets
    /// the tabs on this window's `layout`. A window without a folder has no panels to arrange and no tool to open.
    func applyLayoutPreset(_ preset: LayoutPreset) {
        guard rootNode != nil else { return }
        chrome.showFileTree = preset.panels.files
        chrome.showCenter = preset.panels.center
        chrome.terminalVisible = preset.panels.right
        chrome.agentsVisible = preset.panels.agents
        layout.apply(preset)
        // The preset's tool shows the center panel (a preset that hides it names no tool: `LayoutPreset.parse`).
        if let tool = preset.tool { openTool(tool) }
    }
}
