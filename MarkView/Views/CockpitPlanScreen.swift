import SwiftUI

/// Screen one of the Cockpit: write the goal, choose who does what, see and edit the plan, approve it.
struct CockpitPlanScreen: View {
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
    @State private var expandedID: UUID?
    @State private var showingGuardNote = false
    /// The controls are what the plan was written for; once there is a plan they fold into one line so the plan comes first.
    @State private var showControls = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if session.recoveryRun != nil { recoveryBanner }
                goalCard
                rolesCard
                guardrailsCard
                if let error = session.error { Text(error).uiFont(size: 12).foregroundColor(palette.red).textSelection(.enabled) }
                if let plan = session.plan { planBody(plan) } else { emptyState }
            }
            .padding(20).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onChange(of: session.plan?.id) { id in if id != nil { showControls = false } }
        .onChange(of: session.goal) { _ in session.goalOrControlsChanged() }
        .onChange(of: session.controls) { _ in session.goalOrControlsChanged() }
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(session.recoveryRun != nil ? "Choose how to continue" : "Plan").uiFont(size: 20, weight: .semibold)
                Spacer()
                if let plan = session.plan { stateChip(plan) }
            }
            if let plan = session.plan { Text(summary(plan)).uiFont(size: 12).foregroundColor(palette.textDim) }
            else { Text("Describe the goal, choose who plans and who supervises, then let the Copilot propose steps you can edit.").uiFont(size: 12).foregroundColor(palette.textDim) }
        }
    }

    private func stateChip(_ plan: CockpitPlan) -> some View {
        let count = blockers(plan).blockers.count
        return Group {
            if session.planNeedsRecheck { CockpitChip(text: "Goal or controls changed", icon: "exclamationmark.triangle.fill", tint: palette.orange) }
            else if count == 0 { CockpitChip(text: "Ready to approve", icon: "checkmark.circle.fill", tint: palette.green) }
            else { CockpitChip(text: "\(count) to fix", icon: "exclamationmark.triangle.fill", tint: palette.orange) }
        }
    }

    private func summary(_ plan: CockpitPlan) -> String {
        var parts = ["\(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")"]
        let byAgent = Dictionary(grouping: plan.steps, by: \.agent).sorted { $0.key < $1.key }
        if !byAgent.isEmpty { parts.append(byAgent.map { "\($0.key) ×\($0.value.count)" }.joined(separator: ", ")) }
        if !plan.scenarios.isEmpty { parts.append("\(plan.scenarios.count) QA scenario\(plan.scenarios.count == 1 ? "" : "s")") }
        if let minutes = plan.controls.timeLimitMinutes { parts.append("\(CockpitFormat.duration(Double(minutes) * 60)) limit") }
        return parts.joined(separator: " · ")
    }

    private var recoveryBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Choose a step to continue from. Retrying an interrupted step may repeat partial actions; separately detached background processes may still be running.",
                  systemImage: "exclamationmark.triangle.fill").uiFont(size: 12).foregroundColor(palette.orange)
            Button("Cancel continuation") { session.cancelRecovery(); startingStep = 0 }.buttonStyle(.borderless).uiFont(size: 12)
        }.cockpitCard(outline: palette.orange)
    }

    // MARK: Goal

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            CockpitSectionTitle(title: "Goal", detail: "What the whole run should achieve, in your words.")
            DictationInput(text: $session.goal, isFocused: { goalFocused }) { voice in
                VStack(alignment: .leading) {
                    TextEditor(text: $session.goal).uiFont(size: 13).focused($goalFocused).frame(height: 84)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
                        .overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }
                    voice.status
                }
            }
        }.cockpitCard()
    }

    // MARK: Roles

    private var rolesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CockpitSectionTitle(title: "Who does what", detail: "Every role can use a different agent and model. The step agents are chosen per step below.")
            roleRow(icon: "wand.and.stars", title: "Planner", detail: "Writes the steps and proposes an agent and model for each.") {
                CockpitAgentMenu(agents: session.agents, agent: session.plannerAgent, model: session.plannerModel, inheritLabel: "Project's assistant") { agent, model in
                    session.plannerAgent = agent; session.plannerModel = model
                }
                planButtons
            }
            Divider()
            roleRow(icon: "person.badge.shield.checkmark", title: "Supervisor", detail: supervisorDetail) {
                if session.controls.supervisor {
                    CockpitAgentMenu(agents: session.agents, agent: session.controls.supervisorAgent, model: session.controls.supervisorModel, inheritLabel: "Project's assistant") { agent, model in
                        session.controls.supervisorAgent = agent; session.controls.supervisorModel = model
                    }
                }
                Toggle("Supervisor answers the agents' questions", isOn: $session.controls.supervisor).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider()
            roleRow(icon: "cpu", title: "Step agents", detail: "Each step starts its own agent terminal with the agent and model shown on its card.") {
                CockpitChip(text: "Chosen per step", icon: "arrow.down")
            }
        }.cockpitCard()
    }

    private var supervisorDetail: String {
        session.controls.supervisor
            ? "Answers the step agents' questions by its own judgment and waits for nobody. Anything outside this plan is answered \"do not\" and recorded as a blocker."
            : "Off: step agents cannot ask anything. They decide conservatively inside the controls or record a blocker."
    }

    private func roleRow<Trailing: View>(icon: String, title: String, detail: String, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(palette.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).uiFont(size: 13, weight: .semibold)
                Text(detail).uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing() }
        }
    }

    private var planButtons: some View {
        HStack(spacing: 8) {
            if session.busy { ProgressView().controlSize(.small); Button("Stop") { session.cancel() } }
            else {
                Button(session.plan == nil ? "Propose plan" : "Propose again") { session.generate() }
                    .buttonStyle(.borderedProminent).disabled(session.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Guardrails

    private var controlsSummary: String {
        let controls = session.controls
        var parts = [controls.fileBugs ? "Files bugs" : "No bug filing", controls.fixBugs ? "Fixes bugs" : "No bug fixing", controls.build ? "Builds" : "No builds"]
        parts.append("Deployment: \(controls.deployment)")
        parts.append(controls.timeLimitMinutes.map { "\(CockpitFormat.duration(Double($0) * 60)) limit" } ?? "No time limit")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var guardrailsCard: some View {
        if showControls { guardrailsDetail } else {
            Button { showControls = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").foregroundColor(palette.textDim)
                    Text("Controls").uiFont(size: 13, weight: .semibold)
                    Text(controlsSummary).uiFont(size: 11).foregroundColor(palette.textDim).lineLimit(1)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).cockpitCard(padding: 10)
        }
    }

    private var guardrailsDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CockpitSectionTitle(title: "Controls", detail: "What MarkView holds the agents to while the plan runs.")
                Spacer()
                Button { showingGuardNote.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).foregroundColor(palette.textDim)
                    .popover(isPresented: $showingGuardNote) {
                        Text("MarkView refuses the MarkView tools a control forbids, and starting other agents is always refused. The agent still has its own shell and editor with your full permissions: source files and scenarios changed against a control are detected after the step, but a build or a deployment run from the agent's own shell is neither stopped nor detected.")
                            .uiFont(size: 12).padding(12).frame(width: 340)
                    }
                if session.plan != nil { Button { showControls = false } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundColor(palette.textDim).help("Fold the controls") }
            }
            control("Create scenarios", note: "Checked after each step", tint: palette.blue) { Toggle("Create scenarios", isOn: $session.controls.createScenarios) }
            control("File bugs", note: "Enforced", tint: palette.green) { Toggle("File bugs", isOn: $session.controls.fileBugs) }
            control("Fix bugs", note: "Enforced; source changes checked", tint: palette.green) { Toggle("Fix bugs", isOn: $session.controls.fixBugs) }
            control("Build", note: "Instruction only", tint: palette.orange) { Toggle("Build", isOn: $session.controls.build) }
            control("Deployment environment", note: "Enforced", tint: palette.green) {
                TextField("Disabled", text: $session.controls.deployment).textFieldStyle(.roundedBorder).frame(width: 150).accessibilityLabel("Deployment environment")
            }
            control("Time limit, minutes", note: "Enforced", tint: palette.green) {
                TextField("none", value: $session.controls.timeLimitMinutes, format: .number).textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel("Time limit, minutes")
            }
            control("Fix cycle limit", note: "Enforced", tint: palette.green) {
                TextField("none", value: $session.controls.fixCycleLimit, format: .number).textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel("Fix cycle limit")
            }
            control("Extra checks", note: "Instruction only", tint: palette.orange) {
                TextField("Checks the agents should run", text: $session.controls.checks).textFieldStyle(.roundedBorder).frame(width: 260).accessibilityLabel("Extra checks")
            }
            if !session.controls.build {
                Text("Checks requiring a newly built version are unavailable while builds are disabled.").uiFont(size: 11).foregroundColor(palette.textDim)
            }
        }
        .cockpitCard()
        .onChange(of: session.controls.timeLimitMinutes) { value in if let value, value <= 0 { session.controls.timeLimitMinutes = nil } }
        .onChange(of: session.controls.fixCycleLimit) { value in if let value, value <= 0 { session.controls.fixCycleLimit = nil } }
    }

    private func control<Content: View>(_ title: String, note: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).uiFont(size: 12)
            Spacer(minLength: 8)
            content().labelsHidden().controlSize(.small)
            CockpitChip(text: note, tint: tint).frame(width: 190, alignment: .trailing)
        }
    }

    // MARK: Plan

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 28)).foregroundColor(palette.textDim)
            Text(session.busy ? "The Copilot is writing the plan…" : "No plan yet").uiFont(size: 13, weight: .semibold)
            Text("The plan appears here as steps you can read, edit, reorder and assign to an agent and model.").uiFont(size: 12).foregroundColor(palette.textDim)
        }.frame(maxWidth: .infinity).padding(30).cockpitCard()
    }

    private func readiness(_ plan: CockpitPlan) -> (prepared: CockpitPlan?, blockers: [CockpitPlan.Blocker], reason: String?) {
        do {
            let prepared = try session.preparedPlan(startingAt: startingStep)
            return (prepared, prepared.approvalBlockers(productionConfirmed: productionConfirmed), nil)
        } catch {
            let reason = plan.scenarios.isEmpty ? nil : error.localizedDescription
            return (nil, plan.structuralBlockers + (reason.map { [CockpitPlan.Blocker(stepID: nil, message: $0)] } ?? []), reason)
        }
    }

    private func blockers(_ plan: CockpitPlan) -> (blockers: [CockpitPlan.Blocker], prepared: CockpitPlan?, reason: String?) {
        let value = readiness(plan)
        return (value.blockers, value.prepared, value.reason)
    }

    @ViewBuilder private func planBody(_ plan: CockpitPlan) -> some View {
        let state = readiness(plan)
        if session.planNeedsRecheck { recheckBanner }
        VStack(alignment: .leading, spacing: 0) {
            CockpitSectionTitle(title: "Steps", detail: "Open a step to edit it. Changing a step, its agent or its model changes what you approve.").padding(.bottom, 10)
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                CockpitStepCard(session: session, plan: plan, index: index,
                                problems: state.blockers.filter { $0.stepID == step.id }.map(\.message), expandedID: $expandedID)
            }
            Button { addStep(plan) } label: { Label("Add a step", systemImage: "plus.circle.fill") }
                .buttonStyle(.plain).foregroundColor(palette.accent).uiFont(size: 12).padding(.top, 8).padding(.leading, 36)
        }
        CockpitTextList(title: "Success criteria", detail: "The run is judged against these; each needs evidence.", items: plan.successCriteria, addTitle: "Add a criterion") { items in
            session.editPlan { $0.successCriteria = items }
        }.cockpitCard()
        if !plan.unavailableOutcomes.isEmpty {
            CockpitTextList(title: "Unavailable outcomes", detail: "What the Copilot found it cannot deliver here.", items: plan.unavailableOutcomes, addTitle: "Add") { items in
                session.editPlan { $0.unavailableOutcomes = items }
            }.cockpitCard()
        }
        if !plan.alternatives.isEmpty {
            CockpitTextList(title: "Alternatives", detail: "What it proposes instead.", items: plan.alternatives, addTitle: "Add") { items in
                session.editPlan { $0.alternatives = items }
            }.cockpitCard()
        }
        if !plan.scenarios.isEmpty {
            CockpitQAPlanView(session: session, plan: plan, startingStep: startingStep, prepared: state.prepared, reason: state.reason, productionConfirmed: $productionConfirmed)
        }
        refineCard
        approvalBar(plan, state: state)
    }

    private var recheckBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.orange)
            Text("The goal or the controls changed after the plan was written. The steps were not re-checked against them; your edits are kept.")
                .uiFont(size: 12).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Revise with the Copilot") { session.refinement = "The goal or the controls changed. Adjust the steps to fit them."; session.generate(refining: true) }
                .disabled(session.busy)
        }.cockpitCard(outline: palette.orange)
    }

    private func addStep(_ plan: CockpitPlan) {
        let agent = plan.steps.last?.agent ?? session.agents.first?.name ?? ""
        let step = CockpitStep(title: "New step", agent: agent, assignment: "", completionCondition: "")
        session.editPlan { $0.insertStep(step, at: $0.steps.count) }
        expandedID = step.id
    }

    private var refineCard: some View {
        DisclosureGroup("Ask the Copilot to revise this plan") {
            VStack(alignment: .leading, spacing: 8) {
                DictationInput(text: $session.refinement, isFocused: { refinementFocused }) { voice in
                    VStack(alignment: .leading) {
                        TextEditor(text: $session.refinement).uiFont(size: 12).focused($refinementFocused).frame(height: 64)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
                            .overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }
                        voice.status
                    }
                }
                Button("Revise plan") { session.generate(refining: true) }
                    .disabled(session.busy || session.refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Your hand edits are sent along, so the Copilot revises what you see.").uiFont(size: 10).foregroundColor(palette.textDim)
            }.padding(.top, 6)
        }.uiFont(size: 12).cockpitCard()
    }

    // MARK: Approval

    @ViewBuilder private func approvalBar(_ plan: CockpitPlan, state: (prepared: CockpitPlan?, blockers: [CockpitPlan.Blocker], reason: String?)) -> some View {
        let general = state.blockers.filter { $0.stepID == nil }
        let active = session.execution?.isActive == true
        let mayRevise = active && ["running", "paused"].contains(session.execution?.state?.status ?? "") && session.runningPlan != state.prepared
        let canApprove = state.prepared.flatMap { CockpitApproval(plan: $0, productionConfirmed: productionConfirmed) } != nil
            && !session.busy && !session.startingExecution && !session.revisingExecution && (!active || mayRevise)
            && plan.steps.indices.contains(startingStep) && !session.planNeedsRecheck
            && (session.pendingPlan == nil || session.pendingPlan == state.prepared)
        VStack(alignment: .leading, spacing: 10) {
            if !general.isEmpty {
                ForEach(general, id: \.message) { Label($0.message, systemImage: "exclamationmark.triangle.fill").uiFont(size: 12).foregroundColor(palette.orange) }
            }
            if session.planNeedsRecheck { Label("Re-check the steps against the new goal or controls first.", systemImage: "arrow.triangle.2.circlepath").uiFont(size: 12).foregroundColor(palette.orange) }
            HStack(spacing: 12) {
                if !plan.steps.isEmpty {
                    Picker("Start from", selection: $startingStep) {
                        if session.recoveryRun != nil { Text("Choose a step").tag(-1) }
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in Text("\(index + 1). \(step.title)").tag(index) }
                    }.fixedSize()
                }
                Spacer()
                Button(mayRevise ? "Review and approve changes" : (session.recoveryRun != nil ? "Review and continue" : "Review and approve")) {
                    reviewedPlan = state.prepared
                    reviewedStep = startingStep
                    reviewedProduction = productionConfirmed
                    reviewingRevision = mayRevise
                    reviewingRecovery = session.recoveryRun != nil
                    approving = reviewedPlan != nil
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canApprove)
            }
        }.cockpitCard()
    }
}
