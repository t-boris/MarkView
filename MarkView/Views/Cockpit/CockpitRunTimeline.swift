import SwiftUI

/// What happened in a run, newest first. A run started before the timeline was recorded shows its saved results instead.
struct CockpitRunTimeline: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette
    let run: CockpitRun
    @Binding var selectedStepID: String?
    @State private var shown = 200

    private var events: [CockpitRunEvent] {
        let all = run.events ?? []
        return selectedStepID.map { id in all.filter { $0.stepID == id } } ?? all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let id = selectedStepID, let title = run.plan.steps.first(where: { $0.id.uuidString == id })?.title {
                HStack {
                    CockpitChip(text: "Only: \(title)", icon: "line.3.horizontal.decrease")
                    Button("Show all") { selectedStepID = nil }.buttonStyle(.borderless).uiFont(size: 11)
                }
            }
            if run.events == nil { legacy } else if events.isEmpty { Text("Nothing has happened yet.").uiFont(size: 12).foregroundColor(palette.textDim) }
            let latest = Array(events.suffix(shown).reversed())
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(latest.enumerated()), id: \.offset) { _, event in row(event) }
            }
            if events.count > shown { Button("Show earlier (\(events.count - shown))") { shown += 300 }.buttonStyle(.borderless).uiFont(size: 11) }
        }
    }

    private var legacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This run began before the timeline was recorded. Its saved results:").uiFont(size: 12).foregroundColor(palette.textDim)
            ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in
                Text("\(result.interrupted == true ? "Interrupted" : (result.passed ? "Passed" : "Failed")): \(result.detail)").uiFont(size: 12).textSelection(.enabled)
            }
        }
    }

    private func row(_ event: CockpitRunEvent) -> some View {
        let style = Self.style(event.kind, palette)
        return HStack(alignment: .top, spacing: 10) {
            Text(CockpitFormat.moment(event.at)).uiFont(size: 10).foregroundColor(palette.textDim).frame(width: 96, alignment: .leading)
            Image(systemName: style.icon).foregroundColor(style.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.text).uiFont(size: 12).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let id = event.stepID, let index = run.plan.steps.firstIndex(where: { $0.id.uuidString == id }) {
                    Text("Step \(index + 1) · \(run.plan.steps[index].title)").uiFont(size: 10).foregroundColor(palette.textDim)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
    }

    static func style(_ kind: CockpitRunEvent.Kind, _ palette: AppPalette) -> (icon: String, tint: Color) {
        switch kind {
        case .started: return ("flag", palette.accent)
        case .stepStarted: return ("play.circle", palette.accent)
        case .stepPassed: return ("checkmark.circle.fill", palette.green)
        case .stepFailed: return ("xmark.circle.fill", palette.red)
        case .report: return ("text.bubble", palette.textDim)
        case .question: return ("questionmark.bubble", palette.purple)
        case .bug: return ("ladybug", palette.red)
        case .fix: return ("wrench.and.screwdriver", palette.green)
        case .refusal: return ("hand.raised", palette.orange)
        case .limit: return ("hourglass", palette.orange)
        case .paused: return ("pause.circle", palette.orange)
        case .resumed: return ("play.circle", palette.accent)
        case .stopped: return ("stop.circle", palette.textDim)
        case .finished: return ("flag.checkered", palette.green)
        case .recovered: return ("arrow.counterclockwise.circle", palette.orange)
        case .revised: return ("arrow.triangle.2.circlepath", palette.blue)
        case .switched: return ("switch.2", palette.orange)
        case .note: return ("antenna.radiowaves.left.and.right", palette.blue)
        }
    }
}
