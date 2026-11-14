import SwiftUI

/// A switch that looks like one: a track with a knob that slides, lit when it is on.
struct CockpitSwitchStyle: ToggleStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(CockpitGlass.face)
                    Capsule().stroke(configuration.isOn ? tint : CockpitGlass.line, lineWidth: 1.5)
                    Circle().fill(configuration.isOn ? tint : CockpitGlass.dim).frame(width: 16, height: 16).padding(3)
                        .shadow(color: configuration.isOn ? tint.opacity(0.7) : .clear, radius: 4)
                }
                .frame(width: 44, height: 22)
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

/// A push button for the dark panel.
private struct CockpitPanelButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(size: 12, weight: .semibold)
            .foregroundColor(enabled ? tint : CockpitGlass.dim.opacity(0.6))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(configuration.isPressed ? 0.3 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(enabled ? tint.opacity(0.6) : CockpitGlass.line, lineWidth: 1))
    }
}

/// The dark glass that holds the levers and the radio: always dark, like the instrument panel above it.
private struct CockpitGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [CockpitGlass.bezelEdge, CockpitGlass.bezel], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    fileprivate func cockpitGlassPanel() -> some View { modifier(CockpitGlassPanel()) }
}

// MARK: Levers

/// What the person may switch off while the run goes (DEC-028), and the run's Pause and Stop. A lever can only be switched off or put
/// back up as far as the approved plan allows; what the plan has off shows locked, and what only a revised plan changes shows as fixed.
struct CockpitLeverPanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: CockpitSession
    let run: CockpitRun
    /// The run is going now: the levers work.
    let live: Bool
    let cuts: CockpitLiveSwitches
    /// The coordinator's state in words, and whether Pause is offered.
    let coordinatorLine: String
    let canPause: Bool

    private struct Lever: Identifiable {
        let id: String
        let title: String
        let detail: String
        let allowedByPlan: Bool
        let cut: WritableKeyPath<CockpitLiveSwitches, Bool>
    }

    private var levers: [Lever] {
        let controls = run.plan.controls
        let deploying = !CockpitStepPolicy.isDeploymentDisabled(controls.deployment)
        return [
            Lever(id: "fileBugs", title: "File bugs", detail: "Agents may file bug reports", allowedByPlan: controls.fileBugs, cut: \.fileBugsCut),
            Lever(id: "fixBugs", title: "Fix bugs", detail: "Agents may move a bug into fixing", allowedByPlan: controls.fixBugs, cut: \.fixBugsCut),
            Lever(id: "deployment", title: "Deploy",
                  detail: deploying ? "Only to \(controls.deployment.trimmingCharacters(in: .whitespacesAndNewlines))" : "No deployment",
                  allowedByPlan: deploying, cut: \.deploymentCut),
            Lever(id: "supervisor", title: "Supervisor answers", detail: "Answers the agents' questions", allowedByPlan: controls.supervisor, cut: \.supervisorCut),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SWITCHES").uiFont(size: 10, weight: .semibold, design: .monospaced).tracking(1.4).foregroundColor(CockpitGlass.dim)
            ForEach(levers) { lever in row(lever) }
            Divider().overlay(CockpitGlass.line)
            HStack(spacing: 8) {
                if live && canPause { Button { session.control("pause") } label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(CockpitPanelButtonStyle(tint: palette.orange)) }
                if live { Button { session.control("stop") } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(CockpitPanelButtonStyle(tint: palette.red)) }
            }
            Text(coordinatorLine).uiFont(size: 11).foregroundColor(CockpitGlass.dim).fixedSize(horizontal: false, vertical: true)
            if live && canPause {
                Text("Pause interrupts the running step. You then choose which step to continue from.").uiFont(size: 10).foregroundColor(CockpitGlass.dim)
            }
            Divider().overlay(CockpitGlass.line)
            footer
        }
        .cockpitGlassPanel()
    }

    private func row(_ lever: Lever) -> some View {
        let on = lever.allowedByPlan && !cuts[keyPath: lever.cut]
        let binding = Binding<Bool>(get: { on }, set: { newValue in
            var next = cuts
            next[keyPath: lever.cut] = !newValue
            session.execution?.setLiveCuts(next)
        })
        let locked = !lever.allowedByPlan
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: binding) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lever.title).uiFont(size: 12, weight: .semibold).foregroundColor(CockpitGlass.text)
                    Text(locked ? "Off in the plan; only a revised plan can turn it on" : lever.detail).uiFont(size: 10).foregroundColor(CockpitGlass.dim)
                }
            }
            .toggleStyle(CockpitSwitchStyle(tint: palette.green))
            .disabled(locked || !live)
            .opacity(locked ? 0.55 : 1)
            .accessibilityLabel(lever.title)
            .help(locked ? "The approved plan has this off. Switching on what the plan has off needs a revised and approved plan."
                         : "Switch off: it applies at the agent's next call, even in the middle of a step. Switch on again: back to what the plan allows.")
        }
    }

    /// What is not a lever: what the gate refuses under the controls now, and what only a revised plan changes.
    private var footer: some View {
        let refusals = (run.events ?? []).filter { $0.kind == .refusal }.count
        let policy = CockpitStepPolicy(controls: run.plan.controls.narrowed(by: cuts))
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(refusals) call\(refusals == 1 ? "" : "s") refused so far").uiFont(size: 11).foregroundColor(CockpitGlass.text)
            Text("MarkView refuses: " + policy.enforced.joined(separator: " · ")).uiFont(size: 10).foregroundColor(CockpitGlass.dim).fixedSize(horizontal: false, vertical: true)
            Text(fixedByPlan).uiFont(size: 10).foregroundColor(CockpitGlass.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fixedByPlan: String {
        let controls = run.plan.controls
        var parts = ["create scenarios " + (controls.createScenarios ? "on" : "off"), "build " + (controls.build ? "on" : "off")]
        let checks = controls.checks.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(checks.isEmpty ? "no checks" : "checks: " + CockpitSupervisor.clip(checks, to: 60))
        parts.append(controls.timeLimitMinutes.map { "\(CockpitFormat.duration(Double($0) * 60)) of agent time" } ?? "no time limit")
        parts.append(controls.fixCycleLimit.map { "\($0) fix cycle\($0 == 1 ? "" : "s")" } ?? "no fix cycle limit")
        return "Fixed by the plan (a revised plan changes them): " + parts.joined(separator: " · ")
    }
}

// MARK: Radio

/// The line to the supervisor: what it has been asked and answered, and a note the person can send it (DEC-028). A note is heard from the
/// supervisor's next answer on and is in the briefing of the next step; it never interrupts the agent that is working now.
struct CockpitRadioPanel: View {
    @Environment(\.palette) private var palette
    @ObservedObject var session: CockpitSession
    let run: CockpitRun
    let live: Bool
    let cuts: CockpitLiveSwitches
    /// The notes of a run that is going come from the execution, which has them before the record does.
    let notes: [CockpitCuratorNote]
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var supervisorOn: Bool { run.plan.controls.narrowed(by: cuts).supervisor }
    private var canSend: Bool { live && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RADIO · SUPERVISOR").uiFont(size: 10, weight: .semibold, design: .monospaced).tracking(1.4).foregroundColor(CockpitGlass.dim)
            status
            Divider().overlay(CockpitGlass.line)
            composer
            noteList
        }
        .cockpitGlassPanel()
    }

    @ViewBuilder private var status: some View {
        let log = run.exchanges ?? []
        let controls = run.plan.controls
        if supervisorOn {
            Text("\(controls.supervisorAgent ?? "Project's assistant") · \(controls.supervisorModel ?? "default model")").uiFont(size: 11).foregroundColor(CockpitGlass.dim)
            Text("\(log.count) asked · \(log.filter(\.outOfScope).count) outside the plan · \(log.filter(\.failed).count) unanswered")
                .uiFont(size: 11).foregroundColor(CockpitGlass.text)
            if let last = log.last {
                Text("Last: \(last.question)").uiFont(size: 11).lineLimit(2).foregroundColor(CockpitGlass.dim)
                Text("→ \(last.answer)").uiFont(size: 11).lineLimit(2).foregroundColor(last.outOfScope || last.failed ? palette.orange : CockpitGlass.dim)
            }
        } else {
            Text(controls.supervisor ? "Off. Step agents cannot ask anything; you switched the supervisor off. They decide inside the controls or record a blocker."
                                     : "Off. Step agents cannot ask anything; they decide inside the controls or record a blocker.")
                .uiFont(size: 11).foregroundColor(CockpitGlass.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            DictationInput(text: $draft, isFocused: { draftFocused }, resetOn: run.id) { voice in
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $draft).uiFont(size: 12).focused($draftFocused).scrollContentBackground(.hidden)
                        .foregroundColor(CockpitGlass.text).padding(4).frame(height: 62)
                        .accessibilityLabel("Note to the supervisor")
                        .background(RoundedRectangle(cornerRadius: 6).fill(CockpitGlass.face))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitGlass.line))
                        .overlay(alignment: .bottomTrailing) { voice.mic(compact: true).padding(6) }
                    voice.status
                }
            }
            HStack(spacing: 8) {
                Button("Send note") {
                    session.execution?.sendNote(draft)
                    draft = ""
                }
                .buttonStyle(CockpitPanelButtonStyle(tint: palette.blue)).disabled(!canSend)
                Text(live ? "Read by the supervisor in its later answers and added to the next step's briefing. It does not interrupt the agent that is working now."
                          : "Notes can be sent while the run is going.")
                    .uiFont(size: 10).foregroundColor(CockpitGlass.dim).fixedSize(horizontal: false, vertical: true)
            }
            if live && !supervisorOn {
                Text("The supervisor is off, so only the next step's briefing carries a note.").uiFont(size: 10).foregroundColor(palette.yellow)
            }
        }
    }

    @ViewBuilder private var noteList: some View {
        if !notes.isEmpty {
            Divider().overlay(CockpitGlass.line)
            ForEach(Array(notes.suffix(5).reversed())) { note in
                let delivery = run.delivery(of: note)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(CockpitFormat.moment(note.at)).uiFont(size: 10).foregroundColor(CockpitGlass.dim)
                        CockpitLamp(text: delivery.isQueued ? "QUEUED" : "DELIVERED", lit: true, tint: delivery.isQueued ? palette.yellow : palette.green)
                        if delivery.answersAfter > 0 {
                            Text("heard in \(delivery.answersAfter) answer\(delivery.answersAfter == 1 ? "" : "s")").uiFont(size: 10).foregroundColor(CockpitGlass.dim)
                        }
                        if let step = delivery.briefedStep {
                            Text("in the briefing of step \(step)").uiFont(size: 10).foregroundColor(CockpitGlass.dim)
                        }
                    }
                    Text(note.text).uiFont(size: 11).foregroundColor(CockpitGlass.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
