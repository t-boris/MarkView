import SwiftUI

/// Where a UI Studio change is recorded (REQ-012): "Tracked as REQ-003 of ui-studio-…" or "Tracked as BUG-079, linked to
/// …", which opens the record, and the switch between requirement and bug. Shown on a change's turn and in History.
struct UIStudioTrackingLine: View {
    @ObservedObject var session: StudioSession
    let operation: StudioOperation
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        if let tracking = operation.tracking, tracking.isRecorded {
            HStack(spacing: 6) {
                Image(systemName: tracking.isBug ? "ladybug" : "checklist").uiFont(size: 10).foregroundColor(VSDark.textDim)
                Button {
                    if let url = StudioChanges.validatedURL(tracking.file, root: session.root) { workspaceManager.openFile(url) }
                } label: {
                    Text(StudioTrackingText.label(tracking, reverted: operation.status == .undone))
                        .uiFont(size: 10).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).foregroundColor(VSDark.blue)
                .help(help(tracking))
                Spacer(minLength: 4)
                if operation.kind == .edit, [.applied, .kept].contains(operation.status) {
                    Button(tracking.isBug ? "Switch to requirement" : "Switch to bug") { session.switchTracking(operation.id) }
                        .controlSize(.small).disabled(session.busy != nil)
                        .help(tracking.isBug
                              ? "Record this change as a requirement of the feature instead; the bug report is closed with a note"
                              : "Record this change as a fixed bug linked to the feature instead; the requirement is marked superseded")
                }
            }
        }
    }

    private func help(_ tracking: StudioOperation.Tracking) -> String {
        var lines = ["Open \(tracking.file)"]
        if let kind = operation.changeKind {
            lines.append("The assistant classified it as a \(kind.rawValue)" + (operation.changeReason.map { ": " + $0 } ?? "."))
        }
        if operation.status == .undone {
            lines.append(tracking.isBug ? "Undo closed the bug report with a note." : "Undo marked the requirement rejected with a note.")
        }
        return lines.joined(separator: "\n")
    }
}
