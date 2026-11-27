import SwiftUI

/// One step of the plan on its timeline rail: what it is, who runs it with which model, and an inline editor.
struct CockpitStepCard: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette
    let plan: CockpitPlan
    let index: Int
    let problems: [String]
    @Binding var expandedID: UUID?

    private var step: CockpitStep { plan.steps[index] }
    private var expanded: Bool { expandedID == step.id }
    private var isLast: Bool { index == plan.steps.count - 1 }
    /// The steps this one runs at the same time as, itself included; one step when it runs on its own (REQ-002).
    private var group: Range<Int> { plan.group(containing: index) }
    private var inGroup: Bool { group.count > 1 }
    private var groupText: String {
        let others = group.filter { $0 != index }.map { "\($0 + 1)" }
        let noun = others.count == 1 ? "step" : "steps"
        return "Runs at the same time as \(noun) \(others.joined(separator: " and "))"
    }

    private enum Kind {
        case prerequisite, work, qa, verification
        var icon: String {
            switch self {
            case .prerequisite: return "checkmark.shield"
            case .work: return "hammer"
            case .qa: return "play.rectangle"
            case .verification: return "flag.checkered"
            }
        }
        var title: String {
            switch self {
            case .prerequisite: return "Prerequisite check"
            case .work: return "Work"
            case .qa: return "QA scenario"
            case .verification: return "Final verification"
            }
        }
    }

    private var kind: Kind {
        if step.isPrerequisite { return .prerequisite }
        if step.qaScenarioID != nil { return .qa }
        if isLast, !plan.scenarios.isEmpty, plan.steps.count > 1 { return .verification }
        return .work
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            rail
            VStack(alignment: .leading, spacing: 0) {
                card
                if !isLast { insertButton }
            }
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(problems.isEmpty ? palette.accent : palette.red).frame(width: 26, height: 26)
                Text("\(index + 1)").uiFont(size: 12, weight: .bold).foregroundColor(palette.onAccent)
            }
            if !isLast { Rectangle().fill(palette.border).frame(width: 2).frame(maxHeight: .infinity) }
        }.frame(width: 26)
    }

    private var insertButton: some View {
        Button { insertAfter() } label: { Label("Add a step here", systemImage: "plus") }
            .buttonStyle(.plain).uiFont(size: 11).foregroundColor(palette.textDim).padding(.vertical, 6).help("Insert a new step after this one")
    }

    private func insertAfter() {
        let new = CockpitStep(title: "New step", agent: step.agent, assignment: "", completionCondition: "", model: step.model)
        session.editPlan { $0.insertStep(new, at: index + 1) }
        expandedID = new.id
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !problems.isEmpty { problemList }
            if expanded { editor } else { summary }
        }
        .cockpitCard(outline: problems.isEmpty ? (expanded ? palette.accent : nil) : palette.red)
        .overlay(alignment: .leading) {
            // The members of a group share a bar at their left edge, so they read as one block of the plan.
            if inGroup { RoundedRectangle(cornerRadius: 2).fill(palette.blue).frame(width: 3).padding(.vertical, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { expandedID = step.id } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon).foregroundColor(palette.accent).frame(width: 18)
            Text(step.title.isEmpty ? "Untitled step" : step.title).uiFont(size: 13, weight: .semibold).lineLimit(1)
            Spacer(minLength: 8)
            agentMenu
            Button { expandedID = expanded ? nil : step.id } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(.plain).foregroundColor(palette.textDim).help(expanded ? "Collapse" : "Edit this step")
                .accessibilityLabel(expanded ? "Collapse step \(index + 1)" : "Edit step \(index + 1)")
        }
    }

    private var problemList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").uiFont(size: 11).foregroundColor(palette.red) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CockpitChip(text: kind.title, icon: kind.icon)
                if inGroup {
                    CockpitChip(text: groupText, icon: "arrow.triangle.branch", tint: palette.blue)
                        .help("These steps only inspect the project and start together; the run goes on when all of them have ended.")
                }
                if step.isPrerequisite, let recovery = step.recovery, recovery.isConfigured {
                    CockpitChip(text: "Auto-recovery ×\(recovery.boundedAttempts)", icon: "arrow.triangle.2.circlepath", tint: palette.blue)
                        .help("If this prerequisite fails, Cockpit attempts recovery up to \(recovery.boundedAttempts) time(s): \(recovery.assignment)")
                }
                if let id = step.qaScenarioID { CockpitChip(text: scenarioTitle(id), icon: "testtube.2", tint: palette.purple) }
                if let review = plan.qaReviews?.first(where: { $0.scenarioID == step.qaScenarioID }) {
                    CockpitChip(text: review.targetID, tint: review.production ? palette.orange : palette.green)
                }
            }
            if !step.assignment.isEmpty { Text(step.assignment).uiFont(size: 12).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
            if !step.completionCondition.isEmpty {
                Label(step.completionCondition, systemImage: "checkmark.circle").uiFont(size: 11).foregroundColor(palette.textDim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scenarioTitle(_ id: String) -> String { session.qaScenarios.first { $0.id == id }?.title ?? id }

    // MARK: Agent and model

    private var agentMenu: some View {
        CockpitAgentMenu(agents: session.agents, agent: step.agent, model: step.chosenModel, inheritLabel: nil) { agent, model in
            session.editPlan { plan in
                if let agent { plan.setAgent(agent, forStep: step.id) }
                plan.setModel(model, forStep: step.id)
            }
        }.help("The agent that runs this step and the model it starts with")
    }

    // MARK: Editor

    private func binding<Value>(_ path: WritableKeyPath<CockpitStep, Value>) -> Binding<Value> {
        Binding(get: { step[keyPath: path] }, set: { value in
            session.editPlan { plan in
                guard let i = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                plan.steps[i][keyPath: path] = value
            }
        })
    }

    private var prerequisiteBinding: Binding<Bool> {
        Binding(get: { step.isPrerequisite }, set: { enabled in
            session.editPlan { plan in
                guard let i = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                plan.steps[i].isPrerequisite = enabled
                if !enabled { plan.steps[i].recovery = nil }
            }
        })
    }

    private var recoveryEnabledBinding: Binding<Bool> {
        Binding(get: { step.recovery != nil }, set: { enabled in
            session.editPlan { plan in
                guard let i = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                plan.steps[i].recovery = enabled ? CockpitStepRecovery(assignment: "", maxAttempts: 1) : nil
            }
        })
    }

    private var recoveryAssignmentBinding: Binding<String> {
        Binding(get: { step.recovery?.assignment ?? "" }, set: { value in
            session.editPlan { plan in
                guard let i = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                var current = plan.steps[i].recovery ?? CockpitStepRecovery(assignment: "", maxAttempts: 1)
                current.assignment = value
                plan.steps[i].recovery = current
            }
        })
    }

    private var recoveryAttemptsBinding: Binding<Int> {
        Binding(get: { step.recovery?.boundedAttempts ?? 1 }, set: { value in
            session.editPlan { plan in
                guard let i = plan.steps.firstIndex(where: { $0.id == step.id }) else { return }
                var current = plan.steps[i].recovery ?? CockpitStepRecovery(assignment: "", maxAttempts: 1)
                current.maxAttempts = min(max(1, value), CockpitStepRecovery.maxAllowedAttempts)
                plan.steps[i].recovery = current
            }
        })
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Title") {
                TextField("", text: binding(\.title)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Step \(index + 1) title")
            }
            field("Assignment", hint: "What the agent is asked to do. This is the prompt the step starts with.") {
                editorText(binding(\.assignment), height: 90, label: "Step \(index + 1) assignment")
            }
            field("Complete when", hint: "What must be true for the step to count as done.") {
                editorText(binding(\.completionCondition), height: 56, label: "Step \(index + 1) completion condition")
            }
            Toggle("Prerequisite: the run does not go on until this passes", isOn: prerequisiteBinding).uiFont(size: 12)
            if step.isPrerequisite {
                Toggle("Bounded recovery on failure: attempt recovery and re-check before pausing", isOn: recoveryEnabledBinding).uiFont(size: 12)
                if step.recovery != nil {
                    field("Recovery assignment", hint: "Authorized action Cockpit runs when this prerequisite fails, then re-checks the prerequisite.") {
                        editorText(recoveryAssignmentBinding, height: 64, label: "Step \(index + 1) recovery assignment")
                    }
                    HStack(spacing: 8) {
                        Text("Max recovery attempts").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
                        Picker("Max recovery attempts", selection: recoveryAttemptsBinding) {
                            ForEach(1...CockpitStepRecovery.maxAllowedAttempts, id: \.self) { count in
                                Text("\(count) attempt\(count == 1 ? "" : "s")").tag(count)
                            }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
            field("QA scenario", hint: "Run an existing End-to-End QA scenario at the end of this step.") { scenarioPicker }
            Divider()
            HStack(spacing: 12) {
                Button { session.editPlan { $0.moveStep(at: index, by: -1) } } label: { Label("Up", systemImage: "arrow.up") }.disabled(index == 0)
                Button { session.editPlan { $0.moveStep(at: index, by: 1) } } label: { Label("Down", systemImage: "arrow.down") }.disabled(isLast)
                Button { session.editPlan { $0.duplicateStep(at: index) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                if inGroup {
                    Button { session.editPlan { $0.ungroupStep(step.id) } } label: { Label("Run on its own", systemImage: "arrow.down.to.line") }
                        .help("Take this step out of its group: it then runs after the steps it ran with")
                }
                Spacer()
                Button(role: .destructive) { remove() } label: { Label("Delete", systemImage: "trash") }
            }.buttonStyle(.borderless).uiFont(size: 12)
        }
    }

    private func remove() {
        session.editPlan { $0.removeStep(at: index) }
        expandedID = nil
    }

    private func field<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
            content()
            if let hint { Text(hint).uiFont(size: 10).foregroundColor(palette.textDim) }
        }
    }

    private func editorText(_ text: Binding<String>, height: CGFloat, label: String) -> some View {
        TextEditor(text: text).uiFont(size: 12).frame(height: height)
            .accessibilityLabel(label)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
    }

    private var scenarioPicker: some View {
        let used = Set(plan.steps.filter { $0.id != step.id }.compactMap(\.qaScenarioID))
        return Picker("", selection: binding(\.qaScenarioID)) {
            Text("None").tag(String?.none)
            ForEach(session.qaScenarios.filter { !used.contains($0.id) || $0.id == step.qaScenarioID }) { Text($0.title).tag(String?.some($0.id)) }
            if let id = step.qaScenarioID, !session.qaScenarios.contains(where: { $0.id == id }) { Text("Unavailable: \(id)").tag(String?.some(id)) }
        }.labelsHidden().frame(maxWidth: 320, alignment: .leading)
    }
}
