import SwiftUI

struct SelectionActionBar: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(workspaceManager.selectionActions.values.sorted { $0.started > $1.started }) { action in
                    VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: action.phase == .running ? "sparkle" :
                              action.phase == .completed ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundColor(action.phase == .failed ? VSDark.red : VSDark.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title).uiFont(size: 10, weight: .semibold)
                            Text("\(action.scope) · \(action.assistant) → Editor popup")
                                .uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(1)
                            Text(action.stage).uiFont(size: 9)
                                .foregroundColor(action.phase == .failed ? VSDark.red : VSDark.textDim)
                                .lineLimit(1)
                        }
                        if action.phase == .running {
                            TimelineView(.periodic(from: action.started, by: 1)) { context in
                                Text("\(Int(context.date.timeIntervalSince(action.started)))s")
                                    .uiFont(size: 9, design: .monospaced)
                            }
                            Button("Stop") { workspaceManager.stopSelectionAction(action.id) }
                        } else {
                            Button { workspaceManager.dismissSelectionAction(action.id) } label: {
                                Image(systemName: "xmark")
                            }
                            .help("Dismiss action status")
                            .accessibilityLabel("Dismiss action status")
                        }
                    }
                    if action.phase == .stopped || action.phase == .failed {
                        if !action.partial.isEmpty {
                            Text(action.partial.prefix(240))
                                .uiFont(size: 9)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text("Incomplete output").uiFont(size: 9).foregroundColor(VSDark.orange)
                        }
                        Text("Run the selection action again to retry.")
                            .uiFont(size: 9).foregroundColor(VSDark.textDim)
                    }
                    }
                    .padding(6)
                    .background(VSDark.bgActive)
                    .cornerRadius(5)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(VSDark.bgSidebar)
    }
}
