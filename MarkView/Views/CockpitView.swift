import SwiftUI

struct CockpitView: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette
    @FocusState private var goalFocused: Bool
    @FocusState private var refinementFocused: Bool
    @State private var startingStep = 0
    @State private var approving = false
    @State private var reviewedPlan: CockpitPlan?
    @State private var productionConfirmed = false

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
                                        if let scenario = result.scenarioID, let id = result.qaRunID {
                                            if session.deletedQARuns.contains(id) { Text("QA run details deleted").foregroundColor(palette.orange) }
                                            else { Button("Open QA result") { session.openQAResult(scenarioID: scenario, runID: id) } }
                                        }
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
                if let execution = session.execution {
                    if session.startingExecution {
                        HStack { ProgressView("Starting local runtime…"); Button("Cancel startup") { session.cancelExecutionStartup() } }
                    }
                    if let state = execution.state {
                        Text("Execution: \(state.status)")
                        if !state.reason.isEmpty { Text(state.reason).foregroundColor(palette.orange) }
                        ForEach(Array(state.results.enumerated()), id: \.offset) { _, entry in
                            let title = session.runningPlan?.steps.first(where: { $0.id.uuidString == entry.stepID })?.title ?? entry.stepID
                            Text("\(title): \(entry.result.detail) · Build: \(entry.result.build)").textSelection(.enabled)
                            if let scenario = entry.result.scenarioID, let id = entry.result.qaRunID {
                                Button("Open QA result") { session.openQAResult(scenarioID: scenario, runID: id) }
                            }
                        }
                        HStack {
                            if state.status == "running" { Button("Pause") { session.control("pause") } }
                            if state.status == "paused", let running = session.runningPlan,
                               running.steps.indices.contains(state.current), running.steps[state.current].isPrerequisite {
                                Button("Retry prerequisite") { session.control("retry") }
                            }
                            if execution.isActive { Button("Stop") { session.control("stop") } }
                        }
                    }
                    if let error = execution.error { Text(error).foregroundColor(palette.red) }
                }
                if let plan = session.plan {
                    if !plan.scenarios.isEmpty {
                        Text("Selected scenarios").uiFont(size: 12, weight: .semibold)
                        ForEach(plan.scenarios, id: \.self) { id in
                            if let scenario = session.qaScenarios.first(where: { $0.id == id }) {
                                if plan.steps.dropFirst(startingStep).contains(where: { $0.qaScenarioID == id }) {
                                    Picker(scenario.title, selection: Binding(
                                        get: { session.qaTargets[id] ?? (scenario.targets.count == 1 ? scenario.targets[0].id : "") },
                                        set: { session.qaTargets[id] = $0 })) {
                                        Text("Choose environment").tag("")
                                        ForEach(scenario.targets) { target in Text("\(target.name) (\(target.kind.rawValue))").tag(target.id) }
                                    }
                                } else { Text("\(scenario.title) — skipped from this starting step") }
                            } else { Text("Scenario unavailable: " + id).foregroundColor(palette.red) }
                        }
                        if let reviewed = try? session.preparedPlan(startingAt: startingStep), let qa = reviewed.qaReviews {
                            ForEach(qa, id: \.scenarioID) { item in
                                GroupBox("Exact QA plan: \(item.scenarioID) · \(item.targetID)") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.exactPlan).textSelection(.enabled)
                                        if item.production && !item.dataChangingActions.isEmpty {
                                            Text("Actions that change or may change production data").foregroundColor(palette.orange)
                                            ForEach(item.dataChangingActions, id: \.self) { Text("• " + $0) }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                }
                            }
                        } else if plan.steps.dropFirst(startingStep).contains(where: { $0.qaScenarioID != nil }) {
                            Text("Choose a valid environment and resolve any blocking QA problems before approval.")
                                .foregroundColor(palette.orange)
                        }
                    }
                    GroupBox("Proposed flow") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(index + 1). \(step.title) · \(step.agent)").uiFont(size: 12, weight: .semibold)
                                    if session.runningPlan?.id == plan.id, let state = session.execution?.state {
                                        let result = state.results.last { $0.stepID == step.id.uuidString }
                                        Text(result.map { $0.result.passed ? "Passed" : "Failed" } ?? (state.current == index ? state.status : "Waiting"))
                                            .foregroundColor(palette.textDim)
                                    }
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
                    if !plan.steps.isEmpty {
                        Picker("Start from", selection: $startingStep) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                Text("\(index + 1). \(step.title)").tag(index)
                            }
                        }
                        if let prepared = try? session.preparedPlan(startingAt: startingStep),
                           prepared.qaReviews?.contains(where: \.productionConfirmationRequired) == true {
                            Toggle("I confirm production QA and that the listed data-changing actions will run in production", isOn: $productionConfirmed)
                        }
                        Button("Review and approve execution") { reviewedPlan = try? session.preparedPlan(startingAt: startingStep); approving = reviewedPlan != nil }
                            .disabled((try? session.preparedPlan(startingAt: startingStep)).flatMap { CockpitApproval(plan: $0, productionConfirmed: productionConfirmed) } == nil || session.busy || session.startingExecution || session.execution?.isActive == true || !plan.steps.indices.contains(startingStep))
                    }
                }
            }.padding(20).frame(maxWidth: 900, alignment: .leading)
        }
        .onChange(of: session.goal) { _ in session.invalidatePlan() }
        .onAppear { session.loadRuns() }
        .onChange(of: session.controls) { _ in session.invalidatePlan() }
        .onChange(of: session.qaTargets) { _ in productionConfirmed = false }
        .onChange(of: startingStep) { _ in productionConfirmed = false }
        .onChange(of: session.plan) { _ in productionConfirmed = false }
        .alert("Approve this plan?", isPresented: $approving) {
            Button("Approve and start") {
                if let reviewedPlan, (try? session.preparedPlan(startingAt: startingStep)) == reviewedPlan {
                    session.start(at: startingStep, reviewed: reviewedPlan, productionConfirmed: productionConfirmed)
                }
                reviewedPlan = nil
            }
            Button("Cancel", role: .cancel) { reviewedPlan = nil }
        } message: {
            Text("The selected step and all following steps may run with your full permissions. Controls are advisory. Detached background processes may continue after a pause or after MarkView closes.")
        }
    }
}
