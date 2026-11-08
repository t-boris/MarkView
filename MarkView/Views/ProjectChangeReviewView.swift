import SwiftUI

/// The strip under the project's content: how many files changed on disk since the project opened, and the way into their review.
struct ProjectChangeReviewBar: View {
    @Environment(\.palette) private var palette
    @ObservedObject var review: ProjectChangeReview
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").foregroundColor(palette.blue)
            if review.changes.isEmpty {
                Text("File changes: none observed").foregroundColor(palette.textDim)
            } else {
                Text("\(review.changes.count) observed file change\(review.changes.count == 1 ? "" : "s")")
                    .foregroundColor(palette.text)
            }
            Spacer(minLength: 0)
            if review.isScanning { ProgressView().controlSize(.mini) }
            Button { Task { await review.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh observed file changes")
                .accessibilityLabel("Refresh observed file changes")
            if !review.changes.isEmpty {
                // The review is a tab, not a sheet: a sheet could not be enlarged (BUG-109), a tab has the whole centre area.
                Button("Review") { workspaceManager.openChangeReview() }
            }
        }
        .uiFont(size: 10)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(palette.bgSidebar)
    }
}

/// The review of observed file changes, as a tab: the changed files on the left; on the right the selected file's changes one by
/// one, each with where it is, what lines it adds and removes, and, when asked, what it does, why and what it affects (BUG-109).
/// Not private so that tools/tests/project-change-review-layout-tests.sh can host the shipping view.
struct ProjectChangeReviewTab: View {
    @Environment(\.palette) private var palette
    @ObservedObject var review: ProjectChangeReview
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var selectedPath: String?
    @State private var hunks: [DiffHunk] = []
    @State private var computing = false
    @State private var focusedHunk: Int = 0

    /// A file with no captured text on a side that exists: binary, over the size limit or not UTF-8.
    private static func isUnreadable(_ change: ProjectChange) -> Bool {
        switch change.kind {
        case .added: return change.current == nil
        case .deleted: return change.before == nil
        case .modified: return change.before == nil || change.current == nil
        }
    }

    private var selected: ProjectChange? {
        review.changes.first { $0.path == selectedPath } ?? review.changes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Observed file changes").uiFont(.title3, weight: .semibold)
                Spacer()
                if review.isScanning { ProgressView().controlSize(.small) }
                Button { Task { await review.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button("Mark reviewed") { Task { await review.acknowledge() } }
                    .disabled(review.changes.isEmpty)
                    .help("Take the files as they are now as the new starting point. Nothing is applied or reverted.")
            }.padding(12)
            Text("Changes since this project opened. MarkView observes disk files; the source of each change is unknown. Original files remain on disk; reviewing does not apply or revert anything.")
                .uiFont(size: 10).foregroundColor(palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if review.changes.isEmpty {
                Text("No file changes observed since this project opened, or since you last marked them reviewed.")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    fileList
                    Divider()
                    if let selected { detail(selected) }
                }
            }
        }
        .background(palette.bg)
        .onAppear { if selectedPath == nil { selectedPath = review.changes.first?.path } }
    }

    private var fileList: some View {
        List(review.changes, selection: $selectedPath) { change in
            HStack(spacing: 6) {
                Image(systemName: change.kind == .added ? "plus.circle" :
                      change.kind == .deleted ? "minus.circle" : "pencil.circle")
                    .foregroundColor(change.kind == .added ? palette.green : change.kind == .deleted ? palette.red : palette.orange)
                Text(change.path).lineLimit(1).truncationMode(.head).help(change.path)
                Spacer(minLength: 4)
                Text(change.kind.rawValue.capitalized).foregroundColor(palette.textDim)
            }
            .uiFont(size: 10)
            .tag(change.path)
        }
        // The list names the file; the changes get the rest of the tab.
        // Without an upper bound the list and the changes, both flexible, shared the width (BUG-107); and at the narrowest a tab can be
        // (400 pt) the list must leave the changes about 220 pt.
        .frame(minWidth: 150, idealWidth: 220, maxWidth: 260)
    }

    // MARK: One file

    private func detail(_ change: ProjectChange) -> some View {
        let key = ProjectChangeReview.explanationKey(change)
        let explanation = review.explanations[key]
        return VStack(spacing: 0) {
            header(change, key: key, explanation: explanation)
            Divider()
            if computing {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if Self.isUnreadable(change) {
                note("No readable text is available for this file, so its changes cannot be shown line by line. It is a binary file or a large one; MarkView only knows that it changed.")
            } else if hunks.isEmpty {
                note("The text of this file is the same; only its date or line endings changed.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if let explanation, !explanation.summary.isEmpty {
                                Text(explanation.summary).uiFont(size: 11)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgActive))
                            }
                            ForEach(hunks) { hunk in
                                hunkCard(hunk, count: hunks.count, explanation: explanation?.hunks[hunk.id]).id(hunk.id)
                            }
                        }.padding(12)
                    }
                    .onChange(of: focusedHunk) { index in
                        withAnimation { proxy.scrollTo(index, anchor: .top) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The changes of the selected file, computed off the main thread and again when its text changes.
        .task(id: key) {
            computing = true
            focusedHunk = 0
            let before = change.before, current = change.current
            hunks = Self.isUnreadable(change) ? [] : await Task.detached(priority: .userInitiated) { TextDiff.hunks(old: before, new: current) }.value
            computing = false
        }
    }

    private func header(_ change: ProjectChange, key: String, explanation: ChangeExplanation?) -> some View {
        let added = hunks.reduce(0) { $0 + $1.added }, removed = hunks.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(change.path).uiFont(size: 12, weight: .semibold).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(change.path)
                Spacer(minLength: 8)
                if change.kind != .deleted, let root = workspaceManager.rootNode?.url {
                    Button("Open in Files") { workspaceManager.openFile(root.appendingPathComponent(change.path)) }
                }
            }
            // The counts and the buttons share a row when there is room, and take two when the tab is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    stats(change, added: added, removed: removed)
                    Spacer(minLength: 8)
                    controls(change, key: key, explanation: explanation)
                }
                VStack(alignment: .leading, spacing: 6) {
                    stats(change, added: added, removed: removed)
                    HStack(spacing: 10) { controls(change, key: key, explanation: explanation); Spacer(minLength: 0) }
                }
            }
            .uiFont(size: 10)
        }
        .padding(10)
    }

    private func stats(_ change: ProjectChange, added: Int, removed: Int) -> some View {
        HStack(spacing: 10) {
            Text(change.kind.rawValue.capitalized).foregroundColor(palette.textDim)
            if !hunks.isEmpty {
                Text("\(hunks.count) change\(hunks.count == 1 ? "" : "s")").foregroundColor(palette.text)
                Text("+\(added)").foregroundColor(palette.green)
                Text("−\(removed)").foregroundColor(palette.red)
            }
        }
        .lineLimit(1)
    }

    private func controls(_ change: ProjectChange, key: String, explanation: ChangeExplanation?) -> some View {
        HStack(spacing: 10) {
            if hunks.count > 1 {
                Button { focusedHunk = max(0, focusedHunk - 1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous change").disabled(focusedHunk == 0)
                Button { focusedHunk = min(hunks.count - 1, focusedHunk + 1) } label: { Image(systemName: "chevron.down") }
                    .help("Next change").disabled(focusedHunk >= hunks.count - 1)
            }
            explainControl(change, key: key, explanation: explanation)
        }
    }

    @ViewBuilder
    private func explainControl(_ change: ProjectChange, key: String, explanation: ChangeExplanation?) -> some View {
        if review.explaining.contains(key) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Explaining…").foregroundColor(palette.textDim)
            }
        } else if explanation == nil && !hunks.isEmpty {
            Button {
                review.explain(change, hunks: hunks)
            } label: { Label("Explain changes", systemImage: "sparkles") }
                .help("Ask the project's AI assistant what each change does, why it was probably made and what it affects. This sends this file's changes to the assistant, which may also read the project.")
        }
        if let failure = review.explanationFailures[key] {
            Text(failure).foregroundColor(palette.red).lineLimit(2).help(failure)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).uiFont(size: 11).foregroundColor(palette.textDim)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: One change

    private func hunkCard(_ hunk: DiffHunk, count: Int, explanation: HunkExplanation?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Change \(hunk.id + 1) of \(count)").uiFont(size: 11, weight: .semibold)
                    Text(hunk.location).uiFont(size: 10).foregroundColor(palette.textDim)
                    Spacer(minLength: 8)
                    Text("+\(hunk.added)").foregroundColor(palette.green)
                    Text("−\(hunk.removed)").foregroundColor(palette.red)
                }
                .uiFont(size: 10)
                if let section = hunk.section {
                    Text("in \(section)").uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim)
                        .lineLimit(1).truncationMode(.tail).help(section)
                }
                if let explanation {
                    explanationRows(explanation)
                } else {
                    Text(hunk.summary).uiFont(size: 11)
                }
            }
            .padding(10)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines) { line in lineRow(line) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgInput))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func explanationRows(_ explanation: HunkExplanation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labelled("What", explanation.what)
            if !explanation.why.isEmpty { labelled("Why", explanation.why) }
            if !explanation.impact.isEmpty { labelled("Affects", explanation.impact) }
        }
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textDim).frame(width: 46, alignment: .leading)
            Text(text).uiFont(size: 11).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lineRow(_ line: DiffLine) -> some View {
        let marker = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
        let tint: Color = line.kind == .added ? palette.green : line.kind == .removed ? palette.red : .clear
        return HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
            Text(marker).frame(width: 18).foregroundColor(line.kind == .context ? palette.textDim : tint)
            Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .uiFont(size: 10, design: .monospaced)
        .foregroundColor(line.kind == .context ? palette.textDim : palette.text)
        .padding(.vertical, 1).padding(.trailing, 8)
        .background(tint.opacity(line.kind == .context ? 0 : 0.16))
    }
}
