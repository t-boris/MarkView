import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

extension CLITool {
    /// Legacy agent-wide MarkView tools switch (`browser.agentTools.<assistant>`), retained for one-time migration
    /// into per-service MCP selections (`AgentMCPServices`).
    var agentToolsKey: SettingsKey<Bool> { Setting.browserAgentTools(rawValue) }

    /// True when at least one MarkView launch MCP service (`markview` or `markview-browser`) is enabled for this assistant.
    var agentToolsEnabled: Bool {
        AgentMCPServices.isEnabled(AgentMCPServer.markviewName, for: self)
            || AgentMCPServices.isEnabled(AgentMCPServer.markviewBrowserName, for: self)
    }

    /// True when a specific MCP service (`markview`, `markview-browser`, `markview-control`, or third-party) is enabled for this assistant.
    func isMCPServiceEnabled(_ serviceName: String) -> Bool {
        AgentMCPServices.isEnabled(serviceName, for: self)
    }
}
