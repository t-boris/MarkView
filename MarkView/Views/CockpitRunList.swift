import SwiftUI

/// Where a run stands, in words the person acts on.
enum CockpitRunPhase: Equatable {
    case running, needsYou, paused, interrupted, stopped, finished

    /// `coordinator` is the live runtime's status when this run is the one running now.
    init(run: CockpitRun, coordinator: String?) {
        let failed = run.currentIndex.map { run.steps.indices.contains($0) && run.steps[$0].status == .failed } ?? false
        let interrupted = run.steps.contains { $0.status == .interrupted }
        switch coordinator ?? run.status.rawValue {
        case "running": self = .running
        case "finished": self = .finished
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
        }
    }

    func tint(_ palette: AppPalette) -> Color {
        switch self {
        case .running: return palette.accent
        case .needsYou: return palette.red
        case .paused, .interrupted: return palette.orange
        case .stopped: return palette.textDim
        case .finished: return palette.green
        }
    }

    /// A run that waits for the person comes before one that is only history.
    var needsAttention: Bool { self == .needsYou || self == .paused || self == .interrupted }
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
            Button { session.screen = .plan } label: {
                Label("New plan", systemImage: "plus").uiFont(size: 12, weight: .semibold).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).padding(10).background(session.screen == .plan ? palette.bgActive : Color.clear)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty { Text("Runs appear here after you approve a plan.").uiFont(size: 11).foregroundColor(palette.textDim).padding(10) }
                    ForEach(entries, id: \.id) { run in row(run) }
                    if !session.savedQAResults.isEmpty { evidence }
                }
            }
        }
        .background(palette.bgSidebar)
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
                Text(CockpitFormat.firstLine(run.plan.goal)).uiFont(size: 12, weight: .medium).lineLimit(2).multilineTextAlignment(.leading)
                Text(detail(run, phase: phase)).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
            .background(isSelected(run) ? palette.bgActive : Color.clear)
        }.buttonStyle(.plain)
    }

    private func detail(_ run: CockpitRun, phase: CockpitRunPhase) -> String {
        let total = run.steps.count
        let position = run.currentIndex.map { "Step \($0 + 1) of \(total)" } ?? (phase == .finished ? "\(total) of \(total) steps" : "\(total) steps")
        guard let began = run.began else { return position }
        let end = phase == .running ? Date() : (run.lastKnownActivity ?? began)
        return position + " · " + CockpitFormat.duration(end.timeIntervalSince(began))
    }

    private var evidence: some View {
        DisclosureGroup("QA evidence (\(session.savedQAResults.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.savedQAResults) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(item.result.outcome) · \(CockpitFormat.firstLine(item.result.plan.goal))").uiFont(size: 10).lineLimit(2)
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
