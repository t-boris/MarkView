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
    @State private var reviewedStep = 0
    @State private var reviewedProduction = false
    @State private var reviewingRevision = false
    @State private var reviewingRecovery = false

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
                                    ForEach(run.steps.filter { $0.status == .interrupted }, id: \.stepID) { step in
                                        Text("Interrupted step: its effects may be incomplete.").foregroundColor(palette.orange)
                                        if let progress = step.progress { progressDetails(progress) }
                                        else { Text("No step evidence was recorded.").foregroundColor(palette.textDim) }
                                    }
                                    ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in
                                        Text("\(result.interrupted == true ? "Interrupted" : (result.passed ? "Passed" : "Failed")): \(result.detail) · Plan: \(result.plan.goal) · Build: \(result.build)")
                                            .textSelection(.enabled)
                                        if let progress = result.progress { progressDetails(progress) }
                                        if let scenario = result.scenarioID, let id = result.qaRunID {
                                            if session.deletedQARuns.contains(id) { Text("QA run details deleted").foregroundColor(palette.orange) }
                                            else { Button("Open QA result") { session.openQAResult(scenarioID: scenario, runID: id) } }
                                        }
                                    }
                                    if (run.status == .paused || run.status == .stopped), run.steps.contains(where: { $0.status == .interrupted }) {
                                        Button("Choose how to continue") { session.prepareRecovery(run) }
                                            .disabled(session.loadingRecovery || session.execution?.isActive == true)
                                        if let pending = run.pendingRevision {
                                            Text("An approved change was pending when last saved and may already have been applied: \(pending.plan.goal)").foregroundColor(palette.orange)
                                            Button("Review the pending plan") { session.prepareRecovery(run, usePending: true) }
                                                .disabled(session.loadingRecovery || session.execution?.isActive == true)
                                        }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if !session.savedQAResults.isEmpty {
                    GroupBox("Retained QA evidence") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.savedQAResults) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(item.result.outcome) · Plan: \(item.result.plan.goal) · Build: \(item.result.build)").textSelection(.enabled)
                                    if item.detailsDeleted { Text("QA run details deleted").foregroundColor(palette.orange) }
                                    else if let scenario = item.result.scenarioID, let id = item.result.qaRunID {
                                        Button("Open QA result") { session.openQAResult(scenarioID: scenario, runID: id) }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                Text("Goal").uiFont(size: 12, weight: .semibold)
                if session.recoveryRun != nil {
                    Text("Choose a step to continue. Retrying an interrupted step may repeat partial actions; separately detached background processes may still be running.")
                        .foregroundColor(palette.orange)
                    Button("Cancel continuation") { session.cancelRecovery(); startingStep = 0 }
                }
                DictationInput(text: $session.goal, isFocused: { goalFocused }) { voice in
                    VStack(alignment: .leading) {
                        TextEditor(text: $session.goal).focused($goalFocused).frame(height: 90)
                            .overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }
                        voice.status
                    }
                }
                GroupBox("Controls") {
                    VStack(alignment: .leading, spacing: 6) {
                        controlRow("Checked after each step") { Toggle("Create scenarios", isOn: $session.controls.createScenarios) }
                        controlRow("Instruction only") { TextField("Checks", text: $session.controls.checks) }
                        controlRow("Enforced") { Toggle("File bugs", isOn: $session.controls.fileBugs) }
                        controlRow("Enforced, source changes checked") { Toggle("Fix bugs", isOn: $session.controls.fixBugs) }
                        controlRow("Instruction only") { Toggle("Build", isOn: $session.controls.build) }
                        controlRow("Enforced") { TextField("Deployment environment (Disabled for none)", text: $session.controls.deployment) }
                        controlRow("Enforced") {
                            TextField("Time limit, minutes (empty: none)", value: $session.controls.timeLimitMinutes, format: .number)
                        }
                        controlRow("Enforced") {
                            TextField("Fix cycle limit (empty: none)", value: $session.controls.fixCycleLimit, format: .number)
                        }
                        controlRow("Answers by its own judgment, waits for nobody") {
                            Toggle("Supervisor answers the agents' questions", isOn: $session.controls.supervisor)
                        }
                    }.padding(6)
                }
                .onChange(of: session.controls.timeLimitMinutes) { value in
                    if let value, value <= 0 { session.controls.timeLimitMinutes = nil }
                }
                .onChange(of: session.controls.fixCycleLimit) { value in
                    if let value, value <= 0 { session.controls.fixCycleLimit = nil }
                }
                Text("MarkView refuses the MarkView tools a control forbids, and starting other agents is always refused. The agent still has its own shell and editor with your full permissions: source files and scenarios changed against a control are detected after the step, but a build or a deployment run from the agent's own shell is neither stopped nor detected.")
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
                        // The clock runs between publishes of the run's state, so the line refreshes on its own.
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            if let usage = Self.usageLine(execution: execution, controls: session.runningPlan?.controls) {
                                Text(usage).foregroundColor(palette.textDim)
                            }
                        }
                        if let notice = execution.limitNotice { Text(notice).foregroundColor(palette.orange) }
                        supervisorLog(execution.supervisorLog)
                        if state.status == "finished", let running = session.runningPlan {
                            switch CockpitOutcome.evaluate(criteria: running.successCriteria, progress: state.results.last?.result.progress) {
                            case .success: Text("Outcome: success against the stated criteria")
                            case .blocked: Text("Outcome: remaining blockers").foregroundColor(palette.orange)
                            case .unverified: Text("Outcome: finished, but success criteria lack complete evidence").foregroundColor(palette.orange)
                            }
                        }
                        if let progress = session.currentProgress { progressDetails(progress) }
                        if let running = session.runningPlan, running.steps.indices.contains(state.current) {
                            Text("Current step: \(running.steps[state.current].title)")
                        }
                        if let running = session.runningPlan, running.id != session.plan?.id {
                            GroupBox("Active flow") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(running.steps.enumerated()), id: \.element.id) { index, step in
                                        let result = state.results.last { $0.stepID == step.id.uuidString }
                                        Text("\(index + 1). \(step.title) — \(result.map { $0.result.passed ? "Passed" : "Failed" } ?? execution.stepStatus(step.id) ?? "waiting")")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                        if let pending = session.pendingPlan {
                            let fingerprint = try? CockpitTemporalPlan(pending).fingerprint
                            Text(fingerprint == state.pendingFingerprint ? "Approved changes will apply after the current step." : "Waiting for the coordinator to confirm the approved changes.")
                                .foregroundColor(palette.orange)
                        }
                        if !state.reason.isEmpty { Text(state.reason).foregroundColor(palette.orange) }
                        if state.status == "interrupted" { Text("Stop this coordinator before choosing how to continue.").foregroundColor(palette.orange) }
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
                                if plan.steps.dropFirst(max(0, startingStep)).contains(where: { $0.qaScenarioID == id }) {
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
                        } else if plan.steps.dropFirst(max(0, startingStep)).contains(where: { $0.qaScenarioID != nil }) {
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
                                        Text(result.map { $0.result.passed ? "Passed" : "Failed" } ?? session.execution?.stepStatus(step.id) ?? "waiting")
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
                    Text("During every step MarkView refuses").uiFont(size: 12, weight: .semibold)
                    ForEach(CockpitStepPolicy(controls: plan.controls).enforced, id: \.self) { Text("• " + $0) }
                    Text(Self.limitsLine(plan.controls)).foregroundColor(palette.textDim)
                    Text(plan.controls.supervisor
                         ? "Supervisor on: the Copilot answers the step agents' questions by its own judgment and waits for nobody. What is outside this plan and its controls is answered \"do not\" and recorded as a blocker. Its answers are advice; only the refusals above are enforced."
                         : "Supervisor off: step agents cannot ask anything. They decide conservatively inside the controls or record a blocker.")
                        .foregroundColor(palette.textDim)
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
                            if session.recoveryRun != nil { Text("Choose a step").tag(-1) }
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                Text("\(index + 1). \(step.title)").tag(index)
                            }
                        }
                        if let prepared = try? session.preparedPlan(startingAt: startingStep),
                           prepared.qaReviews?.contains(where: \.productionConfirmationRequired) == true {
                            Toggle("I confirm production QA and that the listed data-changing actions will run in production", isOn: $productionConfirmed)
                        }
                        let active = session.execution?.isActive == true
                        let mayRevise = active && ["running", "paused"].contains(session.execution?.state?.status ?? "") && session.runningPlan != (try? session.preparedPlan(startingAt: startingStep))
                        Button(mayRevise ? "Review and approve changes" : (session.recoveryRun != nil ? "Review and continue" : "Review and approve execution")) {
                            reviewedPlan = try? session.preparedPlan(startingAt: startingStep)
                            reviewedStep = startingStep
                            reviewedProduction = productionConfirmed
                            reviewingRevision = mayRevise
                            reviewingRecovery = session.recoveryRun != nil
                            approving = reviewedPlan != nil
                        }
                        .disabled((try? session.preparedPlan(startingAt: startingStep)).flatMap { CockpitApproval(plan: $0, productionConfirmed: productionConfirmed) } == nil || session.busy || session.startingExecution || session.revisingExecution || (active && !mayRevise) || !plan.steps.indices.contains(startingStep) || (session.pendingPlan != nil && session.pendingPlan != (try? session.preparedPlan(startingAt: startingStep))))
                    }
                }
            }.padding(20).frame(maxWidth: 900, alignment: .leading)
        }
        .onChange(of: session.goal) { value in if session.plan?.goal != value { session.invalidatePlan() } }
        .onAppear { session.loadRuns() }
        .onChange(of: session.controls) { value in if session.plan?.controls != value { session.invalidatePlan() } }
        .onChange(of: session.recoveryRun?.id) { id in if id != nil { startingStep = -1 } }
        .onChange(of: session.qaTargets) { _ in productionConfirmed = false }
        .onChange(of: startingStep) { _ in productionConfirmed = false }
        .onChange(of: session.plan) { _ in productionConfirmed = false }
        .alert(reviewingRevision ? "Approve these changes?" : "Approve this plan?", isPresented: $approving) {
            Button(reviewingRevision ? "Approve changes" : "Approve and start") {
                if let reviewedPlan, (try? session.preparedPlan(startingAt: reviewedStep)) == reviewedPlan {
                    if reviewingRevision { session.applyRevision(at: reviewedStep, reviewed: reviewedPlan, productionConfirmed: reviewedProduction) }
                    else { session.start(at: reviewedStep, reviewed: reviewedPlan, productionConfirmed: reviewedProduction) }
                }
                reviewedPlan = nil
            }
            Button("Cancel", role: .cancel) { reviewedPlan = nil }
        } message: {
            Text(reviewingRecovery ? "Your chosen step and all following steps may run with your full permissions. Repeating a step may repeat partial actions, and detached background processes may still be running." : "The selected step and all following steps may run with your full permissions. Controls are advisory. Detached background processes may continue after a pause or after MarkView closes.")
        }
    }

    /// One control with a note on how far MarkView holds the agent to it.
    private func controlRow<Content: View>(_ note: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
            Spacer(minLength: 8)
            Text(note).uiFont(size: 10).foregroundColor(palette.textDim)
        }
    }

    static func limitsLine(_ controls: CockpitControls) -> String {
        var parts: [String] = []
        if let minutes = controls.timeLimitMinutes { parts.append("\(minutes) min of agent time") }
        if let cycles = controls.fixCycleLimit { parts.append("\(cycles) fix cycle\(cycles == 1 ? "" : "s")") }
        return parts.isEmpty ? "No time or fix cycle limit." : "Limits: " + parts.joined(separator: ", ") + ". A step that reaches one is stopped and the run pauses."
    }

    /// What the supervisor was asked and said, latest first.
    @ViewBuilder private func supervisorLog(_ log: [CockpitSupervisorExchange]) -> some View {
        if !log.isEmpty {
            let outside = log.filter(\.outOfScope).count, unanswered = log.filter(\.failed).count
            DisclosureGroup("Supervisor: \(log.count) question\(log.count == 1 ? "" : "s")"
                            + (outside > 0 ? ", \(outside) outside the plan" : "") + (unanswered > 0 ? ", \(unanswered) unanswered" : "")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(log.suffix(30).reversed().enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Q: " + item.question).textSelection(.enabled)
                            Text("A: " + item.answer).textSelection(.enabled)
                                .foregroundColor(item.outOfScope || item.failed ? palette.orange : palette.textDim)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
        }
    }

    /// What the run has used of its limits, shown only when it has any.
    static func usageLine(execution: CockpitExecution, controls: CockpitControls?) -> String? {
        guard let controls else { return nil }
        var parts: [String] = []
        if let minutes = controls.timeLimitMinutes { parts.append("Agent time \(Int(execution.usedSeconds / 60)) of \(minutes) min") }
        if let cycles = controls.fixCycleLimit { parts.append("Fix cycles \(execution.usedFixCycles) of \(cycles)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func progressDetails(_ progress: CockpitProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pass \(progress.passNumber) · \(progress.activity)")
            if !progress.scenarioCoverage.isEmpty { Text("Scenario coverage: " + progress.scenarioCoverage.joined(separator: ", ")) }
            if !progress.latestChange.isEmpty { Text("Latest change: " + progress.latestChange) }
            if !progress.fixes.isEmpty { Text("Confirmed fixes: " + progress.fixes.joined(separator: ", ")) }
            if !progress.blockers.isEmpty { Text("Blockers: " + progress.blockers.joined(separator: ", ")).foregroundColor(palette.orange) }
            ForEach(Array((progress.criteriaResults ?? []).enumerated()), id: \.offset) { _, result in
                Text("\(result.met ? "Met" : "Unmet"): \(result.criterion) — \(result.evidence)")
            }
            ForEach(Array(progress.bugs.enumerated()), id: \.offset) { _, bug in
                Button("Open \(bug)") { session.openBug(bug) }
            }
            if let path = progress.buildLogPath, !path.isEmpty { Button("Open build log") { session.openBuildLog(path) } }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
