import SwiftUI

/// The list of classic flows behind the Flow button of the Workflow tab (feature workflow-flows, REQ-003): each with where it comes
/// from, what it is for and its columns, so a person sees them before choosing. Choosing only loads the flow into the draft.
struct WorkflowFlowPicker: View {
    @Environment(\.palette) private var palette
    @ObservedObject var editor: WorkflowEditorModel
    let choose: (WorkflowFlow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a flow").uiFont(size: 13, weight: .semibold)
            Text("A flow replaces the states and transitions of features and bugs. The delivery settings of the processes stay as they are, and nothing is saved until you press Save.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(WorkflowFlow.catalogue) { flow in row(flow) }
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 520)
    }

    private func row(_ flow: WorkflowFlow) -> some View {
        let current = editor.currentFlow?.id == flow.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(flow.title).uiFont(size: 12, weight: .semibold)
                Text(flow.origin).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
                Spacer(minLength: 6)
                if current {
                    Text("In use").uiFont(size: 10, weight: .medium).foregroundColor(palette.green)
                } else {
                    Button("Use") { choose(flow) }.controlSize(.small)
                }
            }
            Text(flow.summary).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true)
            Text((flow.bugsDiffer ? "Features: " : "") + flow.outline(.feature)).uiFont(size: 10).foregroundColor(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if flow.bugsDiffer {
                Text("Bugs: " + flow.outline(.bug)).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? palette.green.opacity(0.6) : Color.clear))
    }
}
