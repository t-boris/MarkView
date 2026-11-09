import SwiftUI

/// What "done" means for the processes behind a transition table (feature workflow-flows, REQ-001): under the diagram, for each
/// process, whether a pull request, passing checks, a release or a confirmed event and an acceptance are required, the steps where
/// delivery is judged and the result accepted, and where the project's Definition of Done says something else. It reads the draft, so
/// it follows every edit of a process; it changes nothing (DEC-003).
struct WorkflowDonePanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var editor: WorkflowEditorModel
    let scope: WorkflowScope
    /// Whether GitHub is connected; read live, so connecting it in Settings clears the warning without reopening the tab.
    @AppStorage(GitHubSettings.enabledKey) private var githubEnabled = false

    private var kind: IssueKind {
        switch scope {
        case .type(let kind): return kind
        case .process(let id): return editor.draft.variant(id)?.kind ?? .feature
        }
    }

    private var lifecycle: IssueLifecycleDefinition {
        switch scope {
        case .type(let kind): return editor.draft.lifecycle(kind)
        case .process(let id): return editor.draft.lifecycle(kind, variant: id)
        }
    }

    var body: some View {
        let processes = editor.followers(of: scope)
        let steps = WorkflowDone.steps(in: lifecycle)
        return VStack(alignment: .leading, spacing: 6) {
            Text("What “done” means here").uiFont(size: 10, weight: .semibold).foregroundColor(palette.textDim)
            if processes.isEmpty {
                Text("No process follows these transitions, so nothing says what delivery needs.").uiFont(size: 10).foregroundColor(palette.textDim)
            }
            ForEach(processes) { process in
                card(WorkflowDone.make(process, definition: editor.checklist, acceptanceStep: steps.acceptance != nil, githubEnabled: githubEnabled), steps: steps)
            }
        }
    }

    private func card(_ done: WorkflowDone, steps: WorkflowDone.Steps) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(done.processName).uiFont(size: 11, weight: .semibold)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(done.marks, id: \.name) { mark in chip(mark) }
            }
            Text(done.sentence).uiFont(size: 10.5).fixedSize(horizontal: false, vertical: true)
            Text(stepsLine(steps)).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            if let github = done.githubWarning {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(palette.orange)
                    Text(github).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let hint = done.enableHint {
                Text(hint).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(done.warnings, id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(palette.orange)
                    Text(warning).uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
    }

    private func chip(_ mark: WorkflowDone.Mark) -> some View {
        let color = mark.required ? palette.green : palette.textDim
        return HStack(spacing: 4) {
            Image(systemName: mark.required ? "checkmark.circle.fill" : "minus.circle").font(.system(size: 10))
            Text(mark.name + (mark.required ? "" : ": not required")).uiFont(size: 10, weight: .medium).lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(mark.required ? 0.16 : 0.08)))
        .help(mark.detail)
    }

    private func stepsLine(_ steps: WorkflowDone.Steps) -> String {
        var parts: [String] = []
        if let delivery = steps.delivery { parts.append("Delivery is judged at \(delivery).") } else { parts.append("These transitions have no completion step.") }
        if let acceptance = steps.acceptance { parts.append("Accepted at \(acceptance).") } else { parts.append("There is no acceptance step.") }
        return parts.joined(separator: " ")
    }
}
