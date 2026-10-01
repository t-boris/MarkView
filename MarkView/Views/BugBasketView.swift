import SwiftUI

/// The bug basket under the Issues list (issue #31): the bugs collected from the list, what left
/// it, the AI's similar-bug suggestions, and the one "Fix with AI" for all of them.
struct BugBasketView: View {
    @ObservedObject var batch: BugBatch
    @ObservedObject var assistant: FeatureAssistant
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var expanded = true

    var body: some View {
        if !batch.basket.isEmpty || batch.notice != nil {
            VStack(alignment: .leading, spacing: 4) {
                header
                if let notice = batch.notice { noticeRow(notice) }
                if expanded && !batch.basket.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(batch.items, id: \.path) { itemRow($0) }
                            suggestionsSection
                        }
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    footer
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(VSDark.bg)
            .overlay(Rectangle().frame(height: 1).foregroundColor(VSDark.border), alignment: .top)
        }
    }

    private var suggesting: Bool { assistant.isRunning(BugBatch.suggestKey) }

    private var header: some View {
        HStack(spacing: 5) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").uiFont(size: 8)
                        .foregroundColor(VSDark.textDim).frame(width: 10)
                    Image(systemName: "basket.fill").uiFont(size: 9).foregroundColor(VSDark.blue)
                    Text("BASKET").uiFont(size: 9, weight: .bold).foregroundColor(VSDark.textDim)
                    Text("\(batch.basket.count)").uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if !batch.basket.isEmpty {
                Button(action: { Task { await batch.suggestSimilar(using: assistant) } }) {
                    Image(systemName: "sparkles").uiFont(size: 10)
                        .foregroundColor(suggesting ? VSDark.textDim : VSDark.text)
                }
                .buttonStyle(.plain).disabled(suggesting)
                .help("Suggest similar: the AI looks for open bugs like these; you add the ones you want")
                Button(action: { batch.clear() }) {
                    Image(systemName: "trash").uiFont(size: 9).foregroundColor(VSDark.textDim)
                }
                .buttonStyle(.plain).help("Empty the basket")
            }
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "info.circle").uiFont(size: 9).foregroundColor(VSDark.yellow)
            Text(text).uiFont(size: 10).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button(action: { batch.notice = nil }) {
                Image(systemName: "xmark").uiFont(size: 8).foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain).help("Dismiss")
        }
    }

    private func itemRow(_ bug: BasketBug) -> some View {
        let fixing = BugBasket.isBeingFixed(bug)
        return HStack(spacing: 5) {
            Button(action: { open(bug.path) }) {
                HStack(spacing: 5) {
                    Text(bug.key).uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                    Text(bug.title).uiFont(size: 11).foregroundColor(fixing ? VSDark.textDim : VSDark.text).lineLimit(1)
                    if !bug.feature.isEmpty {
                        Text(bug.feature).uiFont(size: 9).foregroundColor(VSDark.blue).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if fixing {
                        Text("being fixed").uiFont(size: 9, weight: .medium).foregroundColor(VSDark.yellow)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(bug.title + "\n" + (fixing ? "\(bug.path) — already being fixed: left out of the batch" : bug.path))
            Button(action: { batch.remove(bug.path) }) {
                Image(systemName: "xmark").uiFont(size: 8).foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain).help("Remove from the basket")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var suggestionsSection: some View {
        if suggesting {
            Working(text: "Looking for similar open bugs…").padding(.top, 4)
        } else if let error = batch.suggestionError {
            Text(error).uiFont(size: 10).foregroundColor(VSDark.red)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        } else if batch.noSuggestions {
            Text("No similar open bugs found; the basket is unchanged.").uiFont(size: 10)
                .foregroundColor(VSDark.textDim).padding(.top, 4)
        } else if !batch.suggestions.isEmpty {
            Text("SIMILAR").uiFont(size: 9, weight: .bold).foregroundColor(VSDark.textDim).padding(.top, 6)
            ForEach(batch.suggestions, id: \.path) { suggestionRow($0) }
        }
    }

    private func suggestionRow(_ suggestion: SimilarBugs.Suggestion) -> some View {
        let bug = batch.bugs.first { $0.path == suggestion.path }
        return HStack(alignment: .top, spacing: 5) {
            Button(action: { batch.add(suggestion) }) {
                Image(systemName: "plus.circle.fill").uiFont(size: 10).foregroundColor(VSDark.blue)
            }
            .buttonStyle(.plain).help("Add to the basket")
            Button(action: { open(suggestion.path) }) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(bug?.key ?? "").uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                        Text(bug?.title ?? suggestion.path).uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(1)
                    }
                    if !suggestion.reason.isEmpty {
                        Text(suggestion.reason).uiFont(size: 10).foregroundColor(VSDark.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help((bug?.title).map { $0 + "\n" } ?? "" + suggestion.path)
            Button(action: { batch.dismiss(suggestion) }) {
                Image(systemName: "xmark").uiFont(size: 8).foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain).help("Not this one")
        }
        .padding(.vertical, 2)
    }

    /// The batch button; re-checked every second, since the terminal's activity is not observed.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let eligible = batch.eligible
            let busy = workspaceManager.assistantIsBusy
            VStack(alignment: .leading, spacing: 4) {
                if eligible.count == 1, let only = eligible.first {
                    HStack(spacing: 4) {
                        Text("One bug is not a batch: add another, or fix it on its own.")
                            .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                        SmallButton(title: "Open \(only.key)") { open(only.path) }
                            .help("Its panel has Fix with AI for a single bug")
                    }
                }
                SmallButton(title: "Fix \(eligible.count) with AI", icon: "hammer", prominent: true) { workspaceManager.fixBasketWithAI() }
                    .disabled(eligible.count < BugBasket.minimumBatch || busy)
                    .opacity(eligible.count < BugBasket.minimumBatch || busy ? 0.5 : 1)
                    .help(fixHelp(eligible: eligible.count, busy: busy))
            }
        }
    }

    private func fixHelp(eligible: Int, busy: Bool) -> String {
        if eligible < BugBasket.minimumBatch { return "A batch needs at least \(BugBasket.minimumBatch) open bugs" }
        if busy { return "The AI terminal is working — wait until it finishes" }
        return "One run in the Terminal tab: the AI makes a branch, fixes each bug with its own commit and marks it fixed "
            + "(or back to open with the reason). The bugs become Fixing and the basket is emptied."
    }

    /// The report in the editor, with its Bug panel in the Feature tab.
    private func open(_ path: String) {
        guard let url = batch.url(path) else { return }
        workspaceManager.openFile(url)
        workspaceManager.showTOC = true
        workspaceManager.layout.navigatorTab = .feature
    }
}
