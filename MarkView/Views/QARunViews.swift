import AppKit
import SwiftUI

// End-to-End QA (feature end-to-end-qa, REQ-003, REQ-008, REQ-009): the run on screen. The players are side by side, each as its page looks
// now; beneath them is the live feed of what is being done and why (the same lines the video carries as subtitles) and of what the review
// finds, with a picture of the screen it is about; the end of every branch shows what it cost a person.

struct QALiveRunView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var run: QARunModel
    let onClose: () -> Void
    @State private var showUncovered = false
    var onRestart: (QAStartPoint) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            if let question = run.question {
                confirmation(question)
                Divider()
            }
            if run.scenario?.appKind != .api {
                players
                Divider()
            }
            feed
            if !run.results.isEmpty {
                Divider()
                results
            }
        }
        .background(palette.bg)
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            if run.isRunning {
                if !run.isPaused { ProgressView().controlSize(.small) }
                Text(statusText).uiFont(size: 11.5, weight: .medium).lineLimit(1)
                Spacer()
                if run.isPaused {
                    Button { run.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    Menu("Continue from step") {
                        ForEach(run.continuationSteps) { node in Button(node.title) { run.resume(at: node.id) } }
                    }.disabled(run.currentNode == nil)
                } else {
                    Button { run.pause() } label: { Label(run.pauseRequested ? "Pausing…" : "Pause", systemImage: "pause.fill") }
                        .disabled(run.pauseRequested)
                }
                Button(role: .destructive) { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }.uiFont(size: 11)
            } else {
                Image(systemName: "flag.checkered").foregroundColor(palette.textDim)
                Text(finishedText).uiFont(size: 11.5, weight: .medium).lineLimit(2)
                Spacer()
                restartMenu
                Button("Back to the scenario", action: onClose).uiFont(size: 11)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var restartMenu: some View {
        Menu("Run from step") {
            ForEach(run.restartBranches) { branch in
                Menu(run.labels[branch.id] ?? branch.id) {
                    ForEach(branch.nodes, id: \.self) { id in
                        Button(run.scenario?.node(id)?.title ?? id) { onRestart(QAStartPoint(branch: branch.id, node: id)) }
                    }
                }
            }
        }
    }

    private var statusText: String {
        guard let branch = run.currentBranch else { return "Starting…" }
        let label = run.labels[branch] ?? branch
        let number = run.results.count + 1
        return (run.isPaused ? "Paused · " : "") + "Branch \(min(number, max(run.branchCount, 1))) of \(run.branchCount): \(label)"
    }

    private var finishedText: String {
        let counts = Dictionary(grouping: run.results, by: { $0.verdict.outcome }).mapValues(\.count)
        let parts = [QAOutcome.passed, .failed, .blocked, .interrupted, .uncovered].compactMap { outcome in counts[outcome].map { "\($0) \(outcome.label.lowercased())" } }
        var text = parts.isEmpty ? "The run ended" : parts.joined(separator: " · ")
        if let cost = run.costUSD { text += String(format: " · $%.2f", cost) }
        return text
    }

    private func confirmation(_ question: QAConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(question.manual ? "This is for you to do" : "This needs your yes", systemImage: "hand.raised.fill").uiFont(size: 11.5, weight: .semibold).foregroundColor(palette.orange)
            Text(question.title).uiFont(size: 11.5, weight: .medium)
            if !question.reason.isEmpty { Text(question.reason).uiFont(size: 10.5).foregroundColor(palette.textDim) }
            HStack {
                Button(question.manual ? "It is done, go on" : "Yes, do it") { run.reply(true) }.buttonStyle(.borderedProminent)
                Button("No, skip this check") { run.reply(false) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.orange.opacity(0.12))
    }

    // MARK: Players

    private var players: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(run.players) { player in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill").uiFont(size: 10).foregroundColor(palette.textDim)
                            Text(player.name).uiFont(size: 11, weight: .semibold)
                            Spacer(minLength: 0)
                        }
                        Button { enlarge("player:\(player.id)") } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                                if let picture = player.picture {
                                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 5))
                                } else {
                                    Text("Waiting").uiFont(size: 10.5).foregroundColor(palette.textDim)
                                }
                            }
                            .aspectRatio(1280.0 / 800.0, contentMode: .fit)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(player.picture == nil)
                        .accessibilityLabel("Enlarge the page of \(player.name)")
                        .help(player.picture == nil ? "" : "Click to enlarge")
                        Text(player.title.isEmpty ? player.address : player.title).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
                    }
                    .frame(width: players2(run.players.count))
                }
            }
            .padding(10)
        }
        .frame(height: 210)
    }

    private func players2(_ count: Int) -> CGFloat { count <= 1 ? 320 : 260 }

    /// Opens the viewer on a picture of the run: a player's page now, or a screen from the feed.
    private func enlarge(_ start: String) {
        QAViewer.show(title: run.scenario?.title ?? "End-to-End QA", palette: palette) { QALiveViewer(run: run, start: start) }
    }

    // MARK: The feed

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if run.feed.isEmpty { Text("Nothing has happened yet.").uiFont(size: 11).foregroundColor(palette.textDim).padding(10) }
                    ForEach(run.feed) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: run.feed.count) { _ in
                if let last = run.feed.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func row(_ item: QARunModel.FeedItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(clock(item.time)).uiFont(size: 10).foregroundColor(palette.textDim).monospacedDigit().frame(width: 38, alignment: .trailing)
            Image(systemName: icon(item)).uiFont(size: 10.5).foregroundColor(color(item)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).textSelection(.enabled).uiFont(size: 11.5, weight: item.kind == .result || item.finding != nil ? .semibold : .regular).fixedSize(horizontal: false, vertical: true)
                if let shown = item.finding {
                    let finding = run.findings.first { $0.id == shown.id } ?? shown
                    Text(finding.detail).uiFont(size: 10.5).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    if !finding.proposal.isEmpty {
                        Text("Better: " + finding.proposal).uiFont(size: 10.5).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                    }
                    if run.phase == .finished {
                        QAFindingTriageBar(finding: finding) { state, note in run.mark(finding.id, state, note: note) }
                    }
                }
            }
            Spacer(minLength: 0)
            if let picture = item.picture, item.kind != .preparation {
                Button { enlarge("screen:\(item.screen)") } label: {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit).frame(width: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.textDim.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .disabled(item.screen == 0)
                .accessibilityLabel("Enlarge the screenshot")
                .help("Click to enlarge")
            }
        }
    }

    private func icon(_ item: QARunModel.FeedItem) -> String {
        if let finding = item.finding { return finding.isDefect ? "exclamationmark.bubble.fill" : "lightbulb.fill" }
        switch item.kind {
        case .preparation: return "gearshape"
        case .action: return "cursorarrow.click"
        case .observation: return "eye"
        case .result: return "flag.fill"
        }
    }

    private func color(_ item: QARunModel.FeedItem) -> Color {
        if let finding = item.finding { return finding.isDefect ? palette.red : palette.orange }
        return item.kind == .result ? palette.green : palette.textDim
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: The end of every branch

    private var results: some View {
        let completed = run.results.filter { $0.verdict.outcome != .uncovered }
        let uncovered = run.results.filter { $0.verdict.outcome == .uncovered }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Branch results").uiFont(size: 11, weight: .semibold)
                Text("\(run.results.count) / \(run.branchCount)").uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(completed) { resultRow($0) }
                    if !uncovered.isEmpty {
                        DisclosureGroup(isExpanded: $showUncovered) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(uncovered) { resultRow($0) }
                            }.padding(.top, 6)
                        } label: {
                            Text("Not executed (\(uncovered.count))").uiFont(size: 11, weight: .medium)
                        }
                    }
                    if let notice = run.notice { Text(notice).uiFont(size: 10.5).foregroundColor(palette.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.bgSidebar)
    }

    private func resultRow(_ result: QACheckResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.verdict.outcome.label).uiFont(size: 10.5, weight: .semibold).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(tint(result.verdict.outcome)))
                Text(run.labels[result.branch] ?? result.branch).uiFont(size: 11.5, weight: .medium).lineLimit(2)
                Spacer(minLength: 0)
                if result.verdict.outcome != .passed, let node = result.verdict.node ?? (result.verdict.outcome == .interrupted ? result.steps.last?.node : nil) {
                    Button("Retry from this step") { onRestart(QAStartPoint(branch: result.branch, node: node)) }
                        .buttonStyle(.borderless).uiFont(size: 10.5)
                }
                if let video = run.videos[result.branch] {
                    Button { NSWorkspace.shared.open(video) } label: { Label("Video", systemImage: "play.rectangle") }
                        .buttonStyle(.borderless).uiFont(size: 10.5)
                }
            }
            if !result.verdict.reason.isEmpty {
                Text(result.verdict.reason).uiFont(size: 10.5).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            if result.effort.interactions > 0 {
                Text(run.effortSummary(result)).uiFont(size: 10.5).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tint(_ outcome: QAOutcome) -> Color {
        switch outcome {
        case .passed: return palette.green
        case .failed: return palette.red
        case .blocked, .interrupted: return palette.orange
        case .uncovered: return palette.textDim
        }
    }
}
