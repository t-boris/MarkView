import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

extension CLITool {
    /// Per assistant and per Mac: give it MarkView's tool servers when it starts from the AI panel (default on). Off for an
    /// assistant whose organisation blocks MCP servers it does not list (BUG-025).
    var agentToolsKey: SettingsKey<Bool> { Setting.browserAgentTools(rawValue) }

    var agentToolsEnabled: Bool { Settings.standard.value(agentToolsKey) }
}
