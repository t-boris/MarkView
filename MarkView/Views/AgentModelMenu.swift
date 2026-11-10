import SwiftUI

/// Model switch in the Agents header, for the shown assistant (BUG-048). Claude Code switches live:
/// `/model` is typed into the running session, so the conversation goes on, and the tab title and the
/// remembered model follow once the session's log confirms it. Other assistants start again with the
/// model, as a pick in the toolbar does.
struct AgentModelMenu: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: TerminalSession
    @ObservedObject var monitor: AgentActivityMonitor
    let pick: (String) -> Void
    @State private var options: [AIModelOption] = []

    private var isClaude: Bool { session.profile == .claude }

    /// Claude Code answering: `/model` typed now would queue behind the answer.
    private var working: Bool {
        isClaude && monitor.entries.contains { $0.id == session.id && $0.activity.state == .working }
    }

    /// The model the session runs, as a catalog id: Claude's pinned ids and display names map to their family.
    private var current: String {
        guard let model = session.model else { return "" }
        return isClaude ? (ClaudeSessionModel.family(of: model) ?? model) : model
    }

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(get: { current }, set: { pick($0) })) {
                ForEach(options) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "cpu").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(working || options.isEmpty)
        .help(working ? "The agent is answering — switch the model when it is idle"
              : options.isEmpty ? "No model list for this assistant yet. Open the assistant menu in the toolbar or Settings to load it."
              : isClaude ? "Switch this agent's model now; the conversation goes on"
              : "Start this assistant again with another model")
        .task(id: session.profile) {
            guard let tool = session.profile.tool else { return }
            // "Default" is the CLI's own choice and has no name to switch to.
            options = await AIToolbarMenu.loadOptions(for: tool).filter { !$0.id.isEmpty }
        }
    }
}
