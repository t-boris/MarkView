import SwiftUI

/// The toolbar chip that says what the window's assistant is doing ("Claude Code · Editing
/// BrowserSession.swift"). Click shows its terminal. Hidden while no assistant has a session log.
struct AgentActivityChip: View {
    @ObservedObject var monitor: AgentActivityMonitor
    @ObservedObject var workspaceManager: WorkspaceManager
    var compact: Bool
    @State private var pulse = false

    var body: some View {
        if let entry = monitor.headline {
            let working = entry.activity.state == .working
            let others = monitor.othersWorking
            Button {
                workspaceManager.activeAITerminalID = entry.id
                workspaceManager.showAIConsole()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(working ? VSDark.green : VSDark.textDim)
                        .frame(width: 7, height: 7)
                        .opacity(working && pulse ? 0.35 : 1)
                    if !compact {
                        Text(entry.activity.text + (others > 0 ? "  +\(others)" : ""))
                            .uiFont(size: 11, weight: .medium)
                            .foregroundColor(working ? VSDark.text : VSDark.textDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .frame(maxWidth: compact ? nil : 190, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .background(VSDark.bgActive)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .layoutPriority(2)
            .help(helpText(entry, others: others))
            .accessibilityLabel(helpText(entry, others: others))
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }

    private func helpText(_ entry: AgentActivityMonitor.Entry, others: Int) -> String {
        var text = "\(entry.name): \(entry.activity.text)"
        if let topic = entry.activity.topic { text += "\nSession: \(topic)" }
        if others > 0 { text += "\n\(others) more working in this window" }
        return text + "\nClick to show the terminal"
    }
}
