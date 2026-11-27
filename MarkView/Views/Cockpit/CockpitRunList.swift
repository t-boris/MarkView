import SwiftUI

/// Where a run stands, in words the person acts on.
enum CockpitRunPhase: Equatable {
    case running, needsYou, paused, interrupted, stopped, finished
    /// Finished, but some steps failed and the run went on past them (BUG-130): not a success.
    case finishedWithFailures

    /// `coordinator` is the live runtime's status when this run is the one running now.
    init(run: CockpitRun, coordinator: String?) {
        let failed = run.currentMembers.contains { run.steps[$0].status == .failed }
        let interrupted = run.steps.contains { $0.status == .interrupted }
        switch coordinator ?? run.status.rawValue {
        case "running": self = .running
        case "finished": self = run.failedStepTitles.isEmpty ? .finished : .finishedWithFailures
        case "stopped": self = interrupted ? .interrupted : .stopped
        case "interrupted": self = .interrupted
        case "paused": self = failed ? .needsYou : (interrupted ? .interrupted : .paused)
        default: self = run.status == .awaitingApproval ? .paused : .paused
        }
    }

    var title: String {
        switch self {
        case .running: return "Running"
        case .needsYou: return "Needs you"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .stopped: return "Stopped"
        case .finished: return "Finished"
        case .finishedWithFailures: return "Finished with failures"
        }
    }

    var icon: String {
        switch self {
        case .running: return "play.circle.fill"
        case .needsYou: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .interrupted: return "bolt.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .finishedWithFailures: return "exclamationmark.triangle.fill"
        }
    }

    func tint(_ palette: AppPalette) -> Color {
        switch self {
        case .running: return palette.accent
        case .needsYou: return palette.red
        case .paused, .interrupted, .finishedWithFailures: return palette.orange
        case .stopped: return palette.textDim
        case .finished: return palette.green
        }
    }

    /// A run that waits for the person comes before one that is only history.
    var needsAttention: Bool { self == .needsYou || self == .paused || self == .interrupted }
    var isFinished: Bool { self == .finished || self == .finishedWithFailures }
}

/// The left column of the Cockpit: a new plan, and the runs of this project.
struct CockpitRunList: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette

    private var live: CockpitRun? { session.execution?.record }

    /// The live run, then runs that wait for the person, then the rest; newest first inside each group.
    private var entries: [CockpitRun] {
        let saved = session.savedRuns.filter { $0.id != live?.id }
        let waiting = saved.filter { CockpitRunPhase(run: $0, coordinator: nil).needsAttention }
        let rest = saved.filter { !CockpitRunPhase(run: $0, coordinator: nil).needsAttention }
        return (live.map { [$0] } ?? []) + waiting + rest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { session.leaveDraft() } label: {
                Label("New plan", systemImage: "plus").uiFont(size: 12, weight: .semibold).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).padding(10).background(session.screen == .plan && session.draft == nil ? palette.bgActive : Color.clear)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !session.drafts.isEmpty { drafts }
                    if entries.isEmpty { Text("Runs appear here after you approve a plan.").uiFont(size: 11).foregroundColor(palette.textDim).padding(10) }
                    ForEach(entries, id: \.id) { run in row(run) }
                    if !session.savedQAResults.isEmpty { evidence }
                }
            }
        }
        .background(palette.bgSidebar)
    }

    /// One draft per feature prepared from Build (REQ-001): opening one keeps the others and their runs.
    private var drafts: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FEATURES").uiFont(size: 10, weight: .semibold).foregroundColor(palette.textDim).padding(.horizontal, 10).padding(.top, 8)
            ForEach(session.drafts.sorted { $0.updated > $1.updated }) { draft in
                let selected = session.screen == .plan && session.draft?.slug == draft.slug
                Button { session.openDraft(draft.slug) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.feature.title).uiFont(size: 12, weight: .medium).lineLimit(2).multilineTextAlignment(.leading)
                        Text(draftState(draft)).uiFont(size: 10).foregroundColor(draft.preparation == .blocked ? palette.red : palette.textDim).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                    .background(selected ? palette.bgActive : Color.clear)
                }.buttonStyle(.plain)
            }
            Divider()
        }
    }

    private func draftState(_ draft: CockpitDraft) -> String {
        if let id = draft.runID, let run = (session.execution?.record.map { [$0] } ?? []).first(where: { $0.id == id }) ?? session.savedRuns.first(where: { $0.id == id }) {
            return "Run: " + CockpitRunPhase(run: run, coordinator: session.execution?.runID == id ? session.execution?.state?.status : nil).title
        }
        switch draft.preparation {
        case .preparing: return "Preparing the plan…"
        case .blocked: return "Blocked: " + CockpitText.firstLine(draft.blocker ?? "")
        case .ready: return draft.approved != nil ? "Approved — ready to start" : "Ready to review"
        }
    }

    private func isSelected(_ run: CockpitRun) -> Bool {
        switch session.screen {
        case .plan: return false
        case .live: return run.id == live?.id
        case .saved(let id): return run.id == id
        }
    }

    private func row(_ run: CockpitRun) -> some View {
        let isLive = run.id == live?.id
        let phase = CockpitRunPhase(run: run, coordinator: isLive ? session.execution?.state?.status : nil)
        return Button { session.screen = isLive ? .live : .saved(run.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: phase.icon).foregroundColor(phase.tint(palette)).font(.system(size: 12))
                    Text(phase.title).uiFont(size: 11, weight: .semibold).foregroundColor(phase.tint(palette))
                }
                Text(run.plan.displayTitle).uiFont(size: 12, weight: .medium).lineLimit(2).multilineTextAlignment(.leading)
                Text(detail(run, phase: phase)).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
            .background(isSelected(run) ? palette.bgActive : Color.clear)
        }.buttonStyle(.plain)
    }

    private func detail(_ run: CockpitRun, phase: CockpitRunPhase) -> String {
        let total = run.steps.count
        // A group's members are all where the run stands (REQ-004).
        let members = run.currentMembers
        let position = run.currentIndex.map { index in
            members.count > 1 ? "Steps \(members.lowerBound + 1)–\(members.upperBound) of \(total), together" : "Step \(index + 1) of \(total)"
        } ?? (phase.isFinished ? "\(total) of \(total) steps" : "\(total) steps")
        guard let began = run.began else { return position }
        let end = phase == .running ? Date() : (run.lastKnownActivity ?? began)
        return position + " · " + CockpitFormat.duration(end.timeIntervalSince(began))
    }

    private var evidence: some View {
        DisclosureGroup("QA evidence (\(session.savedQAResults.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.savedQAResults) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.result.outcome) · \(item.result.plan.displayTitle)").uiFont(size: 10).lineLimit(2)
                        if item.detailsDeleted { Text("Details deleted").uiFont(size: 10).foregroundColor(palette.orange) }
                        else if let scenario = item.result.scenarioID, let id = item.result.qaRunID {
                            Button("Open QA result") { session.openQAResult(scenarioID: scenario, runID: id) }.buttonStyle(.borderless).uiFont(size: 10)
                        }
                    }
                }
            }.padding(.top, 4)
        }.uiFont(size: 11).padding(10)
    }
}
