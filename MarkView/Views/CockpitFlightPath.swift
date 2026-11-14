import SwiftUI

extension CockpitRun.StepStatus {
    func tint(_ palette: AppPalette) -> Color {
        switch self {
        case .running: return palette.accent
        case .passed: return palette.green
        case .failed: return palette.red
        case .interrupted: return palette.orange
        case .skipped, .waiting: return palette.textDim
        }
    }

    var icon: String {
        switch self {
        case .running: return "play.circle.fill"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "bolt.circle.fill"
        case .skipped: return "arrow.right.circle"
        case .waiting: return "circle"
        }
    }
}

/// The plan as a route: a waypoint for every step, the leg behind a finished step drawn solid, and a plane above the step being flown.
/// Choosing a waypoint filters the timeline to that step, as the chips of the flow strip did.
struct CockpitFlightPath: View {
    @Environment(\.palette) private var palette
    let run: CockpitRun
    /// The colour of the plane: the run's state.
    let tint: Color
    @Binding var selectedStepID: String?

    private static let cell: CGFloat = 116

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(run.plan.steps.enumerated()), id: \.element.id) { index, plan in waypoint(index, plan) }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route of the plan")
    }

    private func flown(_ index: Int) -> Bool {
        guard run.steps.indices.contains(index) else { return false }
        return run.steps[index].status == .passed || run.steps[index].status == .skipped
    }

    private func waypoint(_ index: Int, _ plan: CockpitStep) -> some View {
        let status = run.steps.indices.contains(index) ? run.steps[index].status : .waiting
        let current = run.currentIndex == index
        let selected = selectedStepID == plan.id.uuidString
        let color = status.tint(palette)
        let last = index == run.plan.steps.count - 1
        return VStack(spacing: 4) {
            Image(systemName: "airplane").font(.system(size: 15, weight: .semibold)).foregroundColor(tint).opacity(current ? 1 : 0)
                .accessibilityHidden(true)
            ZStack {
                HStack(spacing: 0) {
                    leg(visible: index > 0, flown: flown(index - 1))
                    leg(visible: !last, flown: flown(index))
                }
                Button { selectedStepID = selected ? nil : plan.id.uuidString } label: {
                    ZStack {
                        Circle().fill(status == .passed ? color : palette.bgInput)
                        Circle().stroke(selected ? palette.accent : color, lineWidth: current || selected ? 2.5 : 1.5)
                        if status == .passed {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color.black.opacity(0.8))
                        } else if status == .failed || status == .interrupted {
                            Image(systemName: status == .failed ? "xmark" : "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundColor(color)
                        } else {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(current ? palette.accent : palette.textDim)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(plan.assignment)
                .accessibilityLabel("Step \(index + 1): \(plan.title)")
                .accessibilityValue(status.rawValue)
            }
            .frame(height: 26)
            Text(plan.title).uiFont(size: 10, weight: current ? .semibold : .regular).foregroundColor(current ? palette.text : palette.textDim)
                .multilineTextAlignment(.center).lineLimit(2).frame(width: 100, height: 28, alignment: .top)
        }
        .frame(width: Self.cell)
    }

    /// Half of the line between two waypoints: solid once the step behind it is done.
    private func leg(visible: Bool, flown: Bool) -> some View {
        Rectangle()
            .fill(visible ? (flown ? palette.green : palette.border) : Color.clear)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .opacity(visible && !flown ? 0.8 : 1)
    }
}

/// Who is flying the current step: its agent and model, how long it has worked and when it last showed it was alive.
struct CockpitFlightStrip: View {
    @Environment(\.palette) private var palette
    let run: CockpitRun
    let now: Date
    /// The latest sign of life of a run that is going; for a saved run, the one the record kept.
    let lastSignal: Date?
    let activeNow: Bool
    let showTerminal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "cpu").foregroundColor(palette.accent)
            if let index = run.currentIndex, run.plan.steps.indices.contains(index), run.steps.indices.contains(index) {
                let plan = run.plan.steps[index], record = run.steps[index]
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Step \(index + 1) of \(run.steps.count) · \(plan.title)").uiFont(size: 12, weight: .semibold).lineLimit(1)
                        CockpitChip(text: "\(plan.agent) · \(plan.chosenModel ?? "default model")", icon: "cpu")
                    }
                    HStack(spacing: 12) {
                        if record.status == .running, let started = record.startedAt {
                            Text("Working for \(CockpitFormat.duration(now.timeIntervalSince(started)))").uiFont(size: 11)
                        }
                        if let signal = lastSignal {
                            Text("Last sign of life \(CockpitFormat.duration(now.timeIntervalSince(signal))) ago").uiFont(size: 11).foregroundColor(palette.textDim)
                        }
                    }
                }
                Spacer(minLength: 8)
                if activeNow && record.status == .running {
                    Button("Show agent terminal", action: showTerminal).buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text(run.status == .finished ? "No step is running; the run finished." : "No step is running.").uiFont(size: 12).foregroundColor(palette.textDim)
                Spacer(minLength: 0)
            }
        }
        .cockpitCard(padding: 10)
    }
}
