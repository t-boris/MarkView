import SwiftUI

struct CockpitView: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette
    @FocusState private var goalFocused: Bool
    @FocusState private var refinementFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Copilot Cockpit").uiFont(size: 18, weight: .semibold)
                if !session.savedRuns.isEmpty {
                    GroupBox("Saved runs") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.savedRuns, id: \.id) { run in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(run.plan.goal).uiFont(size: 12, weight: .semibold)
                                    Text("Status: \(run.status.rawValue)")
                                    if !run.waitingReason.isEmpty { Text(run.waitingReason).foregroundColor(palette.orange) }
                                    ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in
                                        Text("\(result.passed ? "Passed" : "Failed"): \(result.detail) · Build: \(result.build)")
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                Text("Goal").uiFont(size: 12, weight: .semibold)
                DictationInput(text: $session.goal, isFocused: { goalFocused }) { voice in
                    VStack(alignment: .leading) {
                        TextEditor(text: $session.goal).focused($goalFocused).frame(height: 90)
                            .overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }
                        voice.status
                    }
                }
                GroupBox("Advisory controls") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Create scenarios", isOn: $session.controls.createScenarios)
                        TextField("Checks", text: $session.controls.checks)
                        Toggle("File bugs", isOn: $session.controls.fileBugs)
                        Toggle("Fix bugs", isOn: $session.controls.fixBugs)
                        Toggle("Build", isOn: $session.controls.build)
                        TextField("Deployment environment (Disabled for none)", text: $session.controls.deployment)
                        TextField("Time limit", text: $session.controls.timeLimit)
                        TextField("Budget limit", text: $session.controls.budgetLimit)
                        TextField("Fix cycle limit", text: $session.controls.fixCycleLimit)
                    }.padding(6)
                }
                Text("The agent runs in a terminal with your full permissions. These controls are instructions, not enforced restrictions; disabling fixes or deployment does not guarantee they will not happen.")
                    .uiFont(size: 11).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
                if !session.controls.build {
                    Text("Checks requiring a newly built version are unavailable while builds are disabled.")
                        .uiFont(size: 11).foregroundColor(palette.textDim)
                }
                HStack {
                    Button("Propose plan") { session.generate() }.disabled(session.busy || session.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if session.busy { ProgressView().controlSize(.small); Button("Stop planning") { session.cancel() } }
                }
                if let error = session.error { Text(error).foregroundColor(palette.red).textSelection(.enabled) }
                if let plan = session.plan {
                    if !plan.scenarios.isEmpty {
                        Text("Selected scenarios").uiFont(size: 12, weight: .semibold)
                        ForEach(plan.scenarios, id: \.self) { Text("• " + $0) }
                    }
                    GroupBox("Proposed flow") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(index + 1). \(step.title) · \(step.agent)").uiFont(size: 12, weight: .semibold)
                                    Text(step.assignment).textSelection(.enabled)
                                    Text("Complete when: \(step.completionCondition)").foregroundColor(palette.textDim)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.border))
                                if index < plan.steps.count - 1 { Image(systemName: "arrow.down").foregroundColor(palette.textDim) }
                            }
                        }.padding(6)
                    }
                    Text("Success criteria").uiFont(size: 12, weight: .semibold)
                    ForEach(plan.successCriteria, id: \.self) { Text("• " + $0) }
                    if !plan.unavailableOutcomes.isEmpty {
                        Text("Unavailable outcomes").uiFont(size: 12, weight: .semibold)
                        ForEach(plan.unavailableOutcomes, id: \.self) { Text("• " + $0) }
                    }
                    if !plan.alternatives.isEmpty {
                        Text("Alternatives").uiFont(size: 12, weight: .semibold)
                        ForEach(plan.alternatives, id: \.self) { Text("• " + $0) }
                    }
                    DictationInput(text: $session.refinement, isFocused: { refinementFocused }) { voice in
                        VStack(alignment: .leading) {
                            TextEditor(text: $session.refinement).focused($refinementFocused).frame(height: 70)
                                .overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }
                            voice.status
                        }
                    }
                    Button("Revise plan") { session.generate(refining: true) }
                        .disabled(session.busy || session.refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(maxWidth: 900, alignment: .leading)
        }
        .onChange(of: session.goal) { _ in session.invalidatePlan() }
        .onChange(of: session.controls) { _ in session.invalidatePlan() }
    }
}
