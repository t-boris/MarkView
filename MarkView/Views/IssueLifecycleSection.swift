import SwiftUI

/// The Lifecycle section of a feature or a bug (issue-lifecycle-management, REQ-001, REQ-004, REQ-005): where the issue stands, what
/// the history says about every change (who, when, why, on what evidence), which requests were refused and why, what differs
/// from the observed work, and how the GitHub writes ended. A person can accept or reopen from here and ask MarkView to check the
/// delivery evidence; the status menus of the panels cover the other changes.
struct IssueLifecycleSection: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    let kind: IssueKind
    let issue: String
    let status: String

    @State private var model: IssueLifecycleDisplay?
    @State private var delivery: DeliveryVerdict?
    @State private var checkNote: String?
    @State private var checking = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded, let model {
                actions(model)
                if let delivery { deliveryBlock(delivery) }
                if !model.discrepancies.isEmpty { discrepancyBlock(model.discrepancies) }
                rows("History", model.history, empty: "No change recorded yet.")
                if !model.blocked.isEmpty { rows("Blocked requests", model.blocked, empty: "") }
                if !model.github.isEmpty { rows("GitHub", model.github, empty: "") }
            }
        }
        // A verdict and its note belong to the status they were read for; the caller gives each issue its own identity, so the
        // state of another issue is never shown here.
        .task(id: status) {
            delivery = nil
            checkNote = nil
            reload()
        }
    }

    private func reload() {
        model = store.lifecycle.display(kind, issue, delivery: delivery)
    }

    // MARK: Header

    private var header: some View {
        Button(action: { expanded.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").uiFont(size: 8).foregroundColor(palette.textDim).frame(width: 10)
                Text("LIFECYCLE").uiFont(size: 9, weight: .bold).foregroundColor(palette.textDim)
                if let model {
                    Text(model.completion).uiFont(size: 9).foregroundColor(palette.textDim).lineLimit(1)
                    if !model.discrepancies.isEmpty {
                        Text("· \(model.discrepancies.count) to reconcile").uiFont(size: 9, weight: .semibold).foregroundColor(palette.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Status history, evidence, blocked requests and differences between the status and the observed work")
    }

    // MARK: Actions

    private func actions(_ model: IssueLifecycleDisplay) -> some View {
        FlowButtons {
            if model.canCheckEvidence || LifecycleVocabulary.isActiveStatus(kind, model.status) {
                SmallButton(title: checking ? "Checking…" : "Check evidence", icon: "checkmark.seal") { check() }
                    .disabled(checking)
                    .help("Reads git and, with the GitHub integration on, GitHub: merge, checks and the required release. A completed status that the evidence backs is confirmed.")
            }
            if let target = model.acceptTarget {
                SmallButton(title: "Accept", icon: "checkmark.circle") {
                    Task { if await LifecycleStatusChange.perform(store: store, kind: kind, issue: issue, to: target) { reload() } }
                }
                .help(kind == .feature ? "Mark the feature verified: you checked that it works" : "Close the bug: you checked that the fix works")
            }
            if let target = model.reopenTarget {
                SmallButton(title: "Reopen…", icon: "arrow.uturn.backward") {
                    Task { if await LifecycleStatusChange.reopen(store: store, kind: kind, issue: issue, to: target) { reload() } }
                }
                .help("The work came back: it goes back to \(target). Asks for a reason, which the history keeps.")
            }
            SmallButton(title: "Refresh", icon: "arrow.clockwise") { reload() }
                .help("Read the history again")
        }
    }

    private func check() {
        checking = true
        Task {
            let result = await store.lifecycle.checkEvidence(kind, issue)
            delivery = result.verdict
            checkNote = result.confirmed ? "The evidence backs the status: it is now confirmed." : nil
            checking = false
            reload()
        }
    }

    // MARK: Blocks

    private func deliveryBlock(_ verdict: DeliveryVerdict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Delivery evidence: \(verdict.label)").uiFont(size: 10, weight: .semibold)
                .foregroundColor(verdict.isComplete ? palette.green : palette.orange)
            if let checkNote { Text(checkNote).uiFont(size: 10).foregroundColor(palette.green) }
            ForEach(Array(verdict.lines.enumerated()), id: \.offset) { _, line in
                Text("• " + line).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
            }
            if case .unknown = verdict {
                Text("Unknown is never completion: MarkView does not record it as done.").uiFont(size: 9).foregroundColor(palette.textDim)
            }
        }
        .textSelection(.enabled)
    }

    private func discrepancyBlock(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("To reconcile").uiFont(size: 10, weight: .semibold).foregroundColor(palette.orange)
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Text("• " + note).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.orange.opacity(0.08)).cornerRadius(5)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func rows(_ title: String, _ rows: [LifecycleRow], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textDim)
            if rows.isEmpty {
                Text(empty).uiFont(size: 10).foregroundColor(palette.textDim)
            }
            ForEach(rows) { row in LifecycleRowView(row: row) }
        }
    }
}

/// One history, blocked or GitHub row: the headline, who and when, then the reason, evidence and bypassed conditions.
private struct LifecycleRowView: View {
    @Environment(\.palette) private var palette
    let row: LifecycleRow

    private var color: Color {
        switch row.tone {
        case .normal: return palette.textBright
        case .success: return palette.green
        case .override, .external, .unconfirmed: return palette.orange
        case .blocked, .failure: return palette.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.headline).uiFont(size: 10, weight: .semibold).foregroundColor(color)
            Text("\(IssueLifecycleDisplay.stamp(row.time)) · \(row.actor)").uiFont(size: 9).foregroundColor(palette.textDim)
            ForEach(Array(row.notes.enumerated()), id: \.offset) { _, note in
                Text(note).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.6)).frame(width: 2) }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
