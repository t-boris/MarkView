import SwiftUI

/// The notice in the Workflow tab when an assistant has proposed a change of the workflow through MCP (feature
/// assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-003, DEC-001). It says who proposed what and why, lists the
/// differences in words, and offers "Review in the draft", which loads the proposal into the draft like a template does, and
/// "Dismiss". Nothing is saved from here: the person presses Save, which keeps its checks, its questions about the items that use a
/// removed status or process, and its guard against a file that changed meanwhile. A proposal made on an older revision is shown as
/// outdated and cannot be loaded.
struct WorkflowProposalBanner: View {
    @Environment(\.palette) private var palette
    let proposal: WorkflowProposal
    let current: ProjectWorkflow
    /// The draft has edits that are not saved: loading the proposal replaces them.
    let draftHasEdits: Bool
    let review: () -> Void
    let dismiss: () -> Void

    @State private var showAll = false
    private static let shown = 8

    private var outdated: Bool { proposal.isOutdated(against: current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(outdated ? palette.textDim : palette.accent)
                Text("\(proposal.proposedBy) proposes a change of this workflow").uiFont(size: 12, weight: .semibold)
                Spacer(minLength: 8)
                Text(proposal.at, style: .time).uiFont(size: 10).foregroundColor(palette.textDim)
            }
            Text(proposal.summary).uiFont(size: 11).fixedSize(horizontal: false, vertical: true)
            if outdated {
                Text("The workflow has changed since (it is revision \(current.revision) now, the proposal was made on revision \(proposal.workflow.revision)), "
                     + "so it cannot be loaded. Ask the assistant to propose it again.")
                    .uiFont(size: 11).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array((showAll ? proposal.differences : Array(proposal.differences.prefix(Self.shown))).enumerated()), id: \.offset) { _, line in
                    Text("\u{2022} " + line).uiFont(size: 11).foregroundColor(outdated ? palette.textDim : palette.text).fixedSize(horizontal: false, vertical: true)
                }
                if proposal.differences.count > Self.shown {
                    Button(showAll ? "Show fewer" : "Show all \(proposal.differences.count) changes") { showAll.toggle() }
                        .buttonStyle(.link).uiFont(size: 11)
                }
            }
            HStack(spacing: 8) {
                Button(draftHasEdits ? "Replace my draft with it" : "Review in the draft", action: review)
                    .controlSize(.small).disabled(outdated)
                    .help("Loads the proposal into the draft. Nothing is saved until you press Save.")
                Button("Dismiss", action: dismiss).controlSize(.small)
                if draftHasEdits && !outdated {
                    Text("Your unsaved edits in the draft are replaced.").uiFont(size: 10).foregroundColor(palette.textDim)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgBanner))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(outdated ? palette.border : palette.accent.opacity(0.6)))
    }
}
