import SwiftUI

/// The Sync button of the Issues list (issue #36): runs at once, no preview (REQ-001); disabled
/// with its progress while a run is under way (DEC-009). Not shown while the GitHub integration
/// is off, which never runs `gh`.
struct IssueSyncButton: View {
    @ObservedObject var sync: IssueSyncRun
    let start: () -> Void
    @AppStorage(GitHubSettings.enabledKey) private var gitHubEnabled = false

    var body: some View {
        if !gitHubEnabled {
            EmptyView()
        } else if let phase = sync.phase {
            ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                .help("Syncing with GitHub: \(phase)")
        } else {
            Button(action: start) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sync to GitHub")
            .foregroundColor(VSDark.textDim)
            .padding(2)
            .help("Sync to GitHub — close the linked issues of implemented features and fixed bugs")
        }
    }
}

/// Progress of the active run, then the report of the last one (REQ-004): the summary counts
/// unique issues; the rows show each item–issue pair with its outcome and reason.
struct IssueSyncReportView: View {
    @ObservedObject var sync: IssueSyncRun
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var expanded = true
    @State private var showUnlinked = false
    /// Items changed from this report: their rows say so until Sync runs again.
    @State private var changed: Set<String> = []
    /// Height of the rows: the report takes only what it needs, up to 220 points.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        if let phase = sync.phase {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").uiFont(size: 9).foregroundColor(VSDark.blue)
                Text("Sync: \(phase)").uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
        } else if let report = sync.report {
            VStack(alignment: .leading, spacing: 2) {
                header(report)
                if let error = report.error {
                    Text(error).uiFont(size: 10).foregroundColor(VSDark.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if expanded, !report.rows.isEmpty {
                    Text("Sync closes a GitHub issue once every feature (implemented) and bug (fixed) linked to it is done. It never reopens an issue.")
                        .uiFont(size: 9).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(report.linkedRows) { row($0, report: report) }
                            unlinked(report)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            Color.clear.onAppear { rowsHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { rowsHeight = $0 }
                        })
                    }
                    .frame(height: min(max(rowsHeight, 1), 220))
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 5)
        }
    }

    private func header(_ report: IssueSyncReport) -> some View {
        HStack(spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: report.error != nil ? "exclamationmark.triangle.fill"
                          : (expanded ? "chevron.down" : "chevron.right"))
                        .uiFont(size: 8).foregroundColor(report.error != nil ? VSDark.orange : VSDark.textDim).frame(width: 10)
                    Text(report.error != nil ? "Sync stopped, nothing changed" : "Sync: \(report.summary)")
                        .uiFont(size: 10, weight: .medium).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
            .help(report.error ?? "\(report.summary) — \(report.origin), \(report.finished.formatted(date: .omitted, time: .shortened))")
            Spacer(minLength: 2)
            Button(action: { sync.report = nil }) {
                Image(systemName: "xmark.circle.fill").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain).help("Hide the sync report")
        }
    }

    private func row(_ row: IssueSyncReport.Row, report: IssueSyncReport) -> some View {
        let target = row.target!
        let inProject = target.repo == report.origin.lowercased()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon(row.outcome.kind)).uiFont(size: 9).foregroundColor(color(row.outcome.kind)).frame(width: 12)
                Button(target.label(origin: report.origin)) { open(target, inProject: inProject) }
                    .buttonStyle(.plain)
                    .uiFont(size: 9, weight: .medium, design: .monospaced)
                    .foregroundColor(VSDark.blue)
                    .fixedSize()
                    .help("Open \(target.repo)#\(target.number) on GitHub")
                Button(row.item.kind == .bug ? row.item.id : row.item.title) { openItem(row.item) }
                    .buttonStyle(.plain)
                    .uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.tail)
                    .help("Open \(row.item.id) · \(row.item.status.isEmpty ? "no status" : row.item.status)")
            }
            Text(row.outcome.detail).uiFont(size: 9).foregroundColor(VSDark.textDim)
                .lineLimit(2).padding(.leading, 16)
                .help(row.outcome.detail)
            if row.outcome.kind == .skipped, !row.item.isDone {
                actionLine(row.item, button: row.item.kind == .bug ? "Mark fixed" : "Mark implemented",
                           help: "Set the status so the next Sync can close the issue") { markDone(row.item) }
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private func unlinked(_ report: IssueSyncReport) -> some View {
        let rows = report.unlinkedRows
        if !rows.isEmpty {
            Button(action: { showUnlinked.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: showUnlinked ? "chevron.down" : "chevron.right").uiFont(size: 8).frame(width: 12)
                    Text("\(rows.count) without an explicit issue link").uiFont(size: 9)
                }
                .foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .help("Only issue, issues and github fields and full issue URLs count; \"issue #n\" in text does not")
            if showUnlinked {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        Button(row.item.kind == .bug ? "\(row.item.id) \(row.item.title)" : row.item.title) { openItem(row.item) }
                            .buttonStyle(.plain).uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(1)
                        actionLine(row.item, button: "Link issue…", help: "Write the GitHub issue's number into this item") { linkIssue(row.item) }
                    }.padding(.leading, 16)
                }
            }
        }
    }

    /// A small button under a row, or the note that the item was changed.
    @ViewBuilder private func actionLine(_ item: IssueSyncItem, button: String, help: String, action: @escaping () -> Void) -> some View {
        if changed.contains(item.id) {
            Text("Changed. Run Sync again.").uiFont(size: 9).foregroundColor(VSDark.green).padding(.leading, 16)
        } else {
            Button(button, action: action)
                .buttonStyle(.plain).uiFont(size: 9, weight: .medium).foregroundColor(VSDark.blue)
                .padding(.leading, 16).help(help)
        }
    }

    /// The feature in the Issues panel, or the bug report in the editor.
    private func openItem(_ item: IssueSyncItem) {
        let store = workspaceManager.features
        switch item.kind {
        case .feature:
            guard store.feature(item.id) != nil else { return }
            workspaceManager.layout.leftPanel = "issues"
            workspaceManager.layout.issuesFeature = item.id
            store.activeSlug = item.id
        case .bug:
            if let bug = store.bugs.first(where: { $0.key == item.id }) { workspaceManager.openFile(bug.url) }
        }
    }

    /// Set the status that counts as done: a feature implemented, a bug fixed.
    private func markDone(_ item: IssueSyncItem) {
        let store = workspaceManager.features
        switch item.kind {
        case .feature: store.updateFeature(item.id) { front, _ in front.set("status", "implemented") }
        case .bug:
            guard let bug = store.bugs.first(where: { $0.key == item.id }) else { return }
            store.updateBug(bug.url) { front, _ in front.set("status", "fixed") }
        }
        changed.insert(item.id)
    }

    /// Ask for the GitHub issue (a number or its URL) and write it into the item's `issues`.
    private func linkIssue(_ item: IssueSyncItem) {
        let alert = NSAlert()
        alert.messageText = "Link a GitHub issue to \(item.kind == .bug ? item.id : item.title)"
        alert.informativeText = "The number or the URL of the issue. It is written into the item's issues field."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "123 or https://github.com/…/issues/123"
        alert.accessoryView = field
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let digits = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { !$0.isNumber }).last
        guard let number = digits.flatMap({ Int($0) }), number > 0 else { return }
        let store = workspaceManager.features
        let add: (inout FrontMatter) -> Void = { front in
            let existing = front.strings("issues") + front.strings("issue")
            let known = existing.compactMap { Int($0.filter(\.isNumber)) }
            if !known.contains(number) { front.set("issues", list: front.strings("issues") + ["#\(number)"]) }
        }
        switch item.kind {
        case .feature: store.updateFeature(item.id) { front, _ in add(&front) }
        case .bug:
            guard let bug = store.bugs.first(where: { $0.key == item.id }) else { return }
            store.updateBug(bug.url) { front, _ in add(&front) }
        }
        changed.insert(item.id)
    }

    private func open(_ target: IssueSyncTarget, inProject: Bool) {
        if inProject {
            workspaceManager.openGitHubIssue(target.number)
        } else if let url = URL(string: "https://github.com/\(target.repo)/issues/\(target.number)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func icon(_ kind: IssueSyncOutcome.Kind) -> String {
        switch kind {
        case .updated: return "checkmark.circle.fill"
        case .unchanged: return "equal.circle"
        case .skipped: return "arrow.uturn.right.circle"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(_ kind: IssueSyncOutcome.Kind) -> Color {
        switch kind {
        case .updated: return VSDark.green
        case .unchanged: return VSDark.textDim
        case .skipped: return VSDark.yellow
        case .failed: return VSDark.red
        }
    }
}
