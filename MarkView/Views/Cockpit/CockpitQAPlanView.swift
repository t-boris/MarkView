import AppKit
import SwiftUI

/// The QA part of a plan: for each selected scenario, where it runs and what exactly will be done there. What is drawn is decoded from
/// the same text the person approves (`CockpitQAReview.exactPlan`); that text stays available underneath.
struct CockpitQAPlanView: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette
    let plan: CockpitPlan
    let startingStep: Int
    let prepared: CockpitPlan?
    let reason: String?
    @Binding var productionConfirmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CockpitSectionTitle(title: "QA scenarios", detail: "Each scenario runs through MarkView's QA gate at the end of its step. What is listed here is what your approval covers.")
            ForEach(plan.scenarios, id: \.self) { id in scenarioCard(id) }
            if let reason, prepared == nil { Label(reason, systemImage: "exclamationmark.triangle.fill").uiFont(size: 11).foregroundColor(palette.orange) }
            if prepared?.qaReviews?.contains(where: \.productionConfirmationRequired) == true {
                Toggle("I confirm production QA and that the listed data-changing actions will run in production", isOn: $productionConfirmed)
                    .uiFont(size: 12).foregroundColor(palette.orange)
            }
        }
    }

    @ViewBuilder private func scenarioCard(_ id: String) -> some View {
        if let scenario = session.qaScenarios.first(where: { $0.id == id }) {
            let active = plan.steps.dropFirst(max(0, startingStep)).contains { $0.qaScenarioID == id }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(scenario.title, systemImage: "testtube.2").uiFont(size: 13, weight: .semibold)
                    Spacer()
                    if active { environmentPicker(scenario) } else { CockpitChip(text: "Skipped from this starting step") }
                }
                if active, let review = prepared?.qaReviews?.first(where: { $0.scenarioID == id }) { reviewBody(review) }
            }.cockpitCard()
        } else {
            Label("Scenario unavailable: \(id)", systemImage: "exclamationmark.triangle.fill").uiFont(size: 12).foregroundColor(palette.red).cockpitCard()
        }
    }

    private func environmentPicker(_ scenario: QAScenario) -> some View {
        Picker("Environment", selection: Binding(
            get: { session.qaTargets[scenario.id] ?? (scenario.targets.count == 1 ? scenario.targets[0].id : "") },
            set: { session.qaTargets[scenario.id] = $0 })) {
            Text("Choose environment").tag("")
            ForEach(scenario.targets) { Text("\($0.name) (\($0.kind.rawValue))").tag($0.id) }
        }.labelsHidden().fixedSize()
    }

    // MARK: What will run

    @ViewBuilder private func reviewBody(_ review: CockpitQAReview) -> some View {
        if let presented = CockpitQAPresented(exactPlan: review.exactPlan) {
            let scenario = presented.scenario
            HStack(spacing: 6) {
                CockpitChip(text: scenario.targets.first { $0.id == review.targetID }?.name ?? review.targetID, icon: "server.rack",
                            tint: review.production ? palette.orange : palette.green)
                CockpitChip(text: scenario.appKind.rawValue, icon: "app")
                ForEach(scenario.actors) { actor in CockpitChip(text: actor.name, icon: "person") }
            }
            ForEach(presented.selectedBranches, id: \.self) { branch in branchChain(branch, scenario: scenario) }
            if !presented.preparation.isEmpty { preparationList(presented.preparation, production: review.production) }
            if !presented.confirmations.isEmpty { confirmationList(presented.confirmations, production: review.production) }
            if review.production, !review.dataChangingActions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Actions that change or may change production data", systemImage: "exclamationmark.triangle.fill")
                        .uiFont(size: 11, weight: .semibold).foregroundColor(palette.orange)
                    ForEach(review.dataChangingActions, id: \.self) { Text("• " + $0).uiFont(size: 11).foregroundColor(palette.orange) }
                }
            }
        } else {
            Text("This plan could not be drawn; its exact text is below.").uiFont(size: 11).foregroundColor(palette.textDim)
        }
        DisclosureGroup("Exact JSON (what your approval covers)") {
            VStack(alignment: .leading, spacing: 4) {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(review.exactPlan, forType: .string) }
                    .buttonStyle(.borderless).uiFont(size: 11)
                Text(review.exactPlan).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.uiFont(size: 11).foregroundColor(palette.textDim)
    }

    private func branchChain(_ branch: String, scenario: QAScenario) -> some View {
        let ids = branch.split(separator: ">").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(ids.enumerated()), id: \.offset) { position, nodeID in
                    if position > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(palette.textDim) }
                    nodeChip(scenario.node(nodeID))
                }
            }
        }
    }

    private func nodeChip(_ node: QANode?) -> some View {
        guard let node else { return CockpitChip(text: "?", tint: palette.red) }
        let icon: String, tint: Color
        switch node.kind {
        case .action: (icon, tint) = ("hand.tap", palette.blue)
        case .check: (icon, tint) = ("checkmark.circle", palette.green)
        case .alternative: (icon, tint) = ("arrow.triangle.branch", palette.purple)
        case .failure: (icon, tint) = ("exclamationmark.octagon", palette.orange)
        }
        return CockpitChip(text: node.title, icon: icon, tint: tint)
    }

    private func preparationList(_ items: [CockpitQAPresented.Preparation], production: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Preparation").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
            ForEach(items, id: \.id) { item in
                HStack(spacing: 6) {
                    Text(item.title).uiFont(size: 11)
                    if item.manual { CockpitChip(text: "manual", icon: "hand.raised") }
                    if item.changesData != "no" { CockpitChip(text: item.changesData == "yes" ? "changes data" : "may change data", tint: production ? palette.orange : palette.textDim) }
                }
            }
        }
    }

    private func confirmationList(_ items: [CockpitQAPresented.Confirmation], production: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Confirmations").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
            ForEach(items, id: \.id) { item in
                Text("\(item.title) — \(item.reason)").uiFont(size: 11).foregroundColor(production ? palette.orange : palette.text)
            }
        }
    }
}
