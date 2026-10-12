import SwiftUI

/// Status dot of an assistant: green and pulsing while it works, red when its last step failed,
/// grey when it waits for the person.
struct AgentStatusDot: View {
    let state: AgentActivity.State
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state == .working ? VSDark.green : state == .failing ? Color.red : VSDark.textDim)
            .frame(width: 7, height: 7)
            .opacity(state != .idle && pulse ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

extension AgentActivity {
    /// The full account, for tooltips.
    var summary: String {
        var lines = [text]
        if let detail { lines.append("Step: \(detail)") }
        if let task { lines.append("Task: \(task)") }
        if let topic { lines.append("Session: \(topic)") }
        return lines.joined(separator: "\n")
    }
}

/// The dot on one terminal tab of the AI panel; nothing for a terminal without a readable log.
struct AgentTabDot: View {
    @ObservedObject var monitor: AgentActivityMonitor
    let terminalID: UUID

    var body: some View {
        if let entry = monitor.entries.first(where: { $0.id == terminalID }) {
            AgentStatusDot(state: entry.activity.state).help(entry.activity.summary)
        }
    }
}

/// Under the tab bar: what the shown terminal's assistant was asked and what it is doing now.
struct AgentActivityBanner: View {
    @ObservedObject var monitor: AgentActivityMonitor
    let terminalID: UUID?

    var body: some View {
        if let entry = monitor.entries.first(where: { $0.id == terminalID }) {
            let activity = entry.activity
            HStack(alignment: .top, spacing: 7) {
                AgentStatusDot(state: activity.state).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.text).uiFont(size: 11, weight: .medium)
                        .foregroundColor(activity.state == .idle ? VSDark.textDim : VSDark.text)
                        .lineLimit(2)
                    if let task = activity.task {
                        Text("Task: " + task).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VSDark.bgSidebar)
            .help(activity.summary)
        }
    }
}

/// The toolbar chip: the headline assistant of the window ("Running xcodebuild"); the panel shows
/// each terminal's own status. Click shows its terminal.
struct AgentActivityChip: View {
    @ObservedObject var monitor: AgentActivityMonitor
    @ObservedObject var workspaceManager: WorkspaceManager
    var compact: Bool

    var body: some View {
        if let entry = monitor.headline {
            let others = monitor.othersWorking
            Button {
                workspaceManager.activeAITerminalID = entry.id
                workspaceManager.showAIConsole()
            } label: {
                HStack(spacing: 6) {
                    AgentStatusDot(state: entry.activity.state)
                    if !compact {
                        Text(entry.activity.text + (others > 0 ? "  +\(others)" : ""))
                            .uiFont(size: 11, weight: .medium)
                            .foregroundColor(entry.activity.state == .idle ? VSDark.textDim : VSDark.text)
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
            .help(entry.name + "\n" + entry.activity.summary + (others > 0 ? "\n\(others) more working in this window" : "")
                  + "\nClick to show the terminal")
            .accessibilityLabel("\(entry.name): \(entry.activity.text)")
        }
    }
}
