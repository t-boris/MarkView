import SwiftUI

/// Globe-menu submenu for per-agent MCP service toggles (`mcp` feature, I-5).
struct MCPServicesMenuContent: View {
    @ObservedObject private var store = AgentMCPServicesStore.shared
    let isAgentRunning: (CLITool) -> Bool
    let onRestartAgent: (CLITool) -> Void
    let onOpenSettings: () -> Void
    let prompts: any UserPrompts

    var body: some View {
        Menu("MCP Services for Agents") {
            ForEach(AgentMCPServices.supportedAgents) { tool in
                agentSubmenu(for: tool)
            }
            Divider()
            Button("Manage MCP Services…") {
                store.refreshAll()
                onOpenSettings()
            }
            Text("Changes apply to each agent's own configuration on this Mac. Restart running agent sessions for changes to take effect.")
        }
    }

    @ViewBuilder
    private func agentSubmenu(for tool: CLITool) -> some View {
        let services = store.services(for: tool)
        let markviewServices = services.filter { $0.source == .markviewBuiltin || $0.source == .markviewControl }
        let externalServices = services.filter { $0.source == .agentConfig || $0.source == .agentBuiltin }
        Menu(tool.displayName) {
            ForEach(markviewServices) { service in
                serviceToggle(service, for: tool)
            }
            if !externalServices.isEmpty {
                Divider()
                ForEach(externalServices) { service in
                    serviceToggle(service, for: tool)
                }
            }
            Divider()
            Button("Refresh \(tool.displayName) Services") {
                store.refresh(for: tool)
            }
            if isAgentRunning(tool) {
                Text("\(tool.displayName) is running — restart its session for changes to take effect.")
            } else {
                Text("Applies to \(tool.displayName) launches inside and outside MarkView.")
            }
        }
    }

    private func serviceToggle(_ service: AgentMCPService, for tool: CLITool) -> some View {
        let title = service.canToggle ? service.name : "\(service.name) (read-only)"
        return Toggle(title, isOn: Binding(
            get: { service.isEnabled },
            set: { newValue in
                let running = isAgentRunning(tool)
                if let error = store.setEnabled(newValue, service: service.name, for: tool, sessionIsRunning: running) {
                    prompts.inform("Could not update \(service.name)", error)
                    return
                }
                if running {
                    let state = newValue ? "enabled" : "disabled"
                    let prompt = UserPrompt(
                        title: "Restart \(tool.displayName) to apply change?",
                        detail: "\"\(service.name)\" is now \(state) for \(tool.displayName) on this Mac. An already running \(tool.displayName) session must be restarted for this change to take effect.",
                        buttons: ["Restart \(tool.displayName)", "Later"]
                    )
                    if prompts.confirm(prompt, proceedingWith: 0) {
                        onRestartAgent(tool)
                    }
                }
            }
        ))
        .disabled(!service.canToggle)
    }
}

/// DDE Settings section for inspecting and independently toggling every available MCP service per agent (I-5).
struct MCPServicesSettingsSection: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var store = AgentMCPServicesStore.shared
    let isAgentRunning: (CLITool) -> Bool
    let onRestartAgent: (CLITool) -> Void

    @State private var selectedAgentID: String = AgentMCPServices.supportedAgents.first?.rawValue ?? ""

    private var selectedTool: CLITool? {
        AgentMCPServices.supportedAgents.first { $0.rawValue == selectedAgentID }
            ?? AgentMCPServices.supportedAgents.first
    }

    var body: some View {
        GroupBox("MCP Services (Per Agent)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("Agent", selection: $selectedAgentID) {
                        ForEach(AgentMCPServices.supportedAgents) { tool in
                            Text(tool.displayName).tag(tool.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if let tool = selectedTool {
                        let loading = store.loadingAgents.contains(tool.rawValue)
                        Button(loading ? "Refreshing…" : "Refresh") {
                            store.refresh(for: tool)
                        }
                        .disabled(loading)
                        .uiFont(.caption)
                    }
                }

                if let error = store.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .uiFont(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { store.clearError() }
                            .uiFont(.caption)
                    }
                    .padding(6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }

                if let tool = selectedTool {
                    let running = isAgentRunning(tool)
                    if running && store.agentsNeedingRestart.contains(tool.rawValue) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundColor(palette.blue)
                            Text("\(tool.displayName) is currently running. Restart its session for your MCP service changes to take effect.")
                                .uiFont(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Restart \(tool.displayName)") {
                                onRestartAgent(tool)
                            }
                            .uiFont(.caption)
                        }
                        .padding(6)
                        .background(palette.blue.opacity(0.1))
                        .cornerRadius(6)
                    }

                    let services = store.services(for: tool)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(services) { service in
                            serviceRow(service, for: tool)
                            if service.id != services.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text("Selections are saved per agent on this Mac and applied to each agent's own configuration, so disabled services do not connect inside or outside MarkView. Newly discovered services keep their agent-configured state until changed. Restart running agent sessions after a change. Organizational policies are never altered or bypassed.")
                    .uiFont(size: 9)
                    .foregroundColor(palette.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
        .onAppear {
            if selectedAgentID.isEmpty, let first = AgentMCPServices.supportedAgents.first {
                selectedAgentID = first.rawValue
            }
            if let tool = selectedTool {
                store.refresh(for: tool)
            }
        }
        .onChange(of: selectedAgentID) { _ in
            if let tool = selectedTool {
                store.refresh(for: tool)
            }
        }
    }

    private func serviceRow(_ service: AgentMCPService, for tool: CLITool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(
                get: { service.isEnabled },
                set: { newValue in
                    _ = store.setEnabled(
                        newValue,
                        service: service.name,
                        for: tool,
                        sessionIsRunning: isAgentRunning(tool)
                    )
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(service.name)
                            .uiFont(size: 11, weight: .semibold, design: .monospaced)
                        Text(service.source.badge)
                            .uiFont(size: 9)
                            .foregroundColor(palette.textDim)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.textDim.opacity(0.12))
                            .cornerRadius(4)
                    }
                    if let summary = service.summary {
                        Text("\(summary) · \(service.detail)")
                            .uiFont(size: 9)
                            .foregroundColor(palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(service.note.map { "\(service.detail) — \($0)" } ?? service.detail)
                            .uiFont(size: 9)
                            .foregroundColor(palette.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!service.canToggle)
            Spacer(minLength: 0)
        }
    }
}
