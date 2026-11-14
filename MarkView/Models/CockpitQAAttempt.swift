import Foundation

/// Runs only the exact QA scenario and target approved with this cockpit plan.
@MainActor
final class CockpitQAAttempt {
    private weak var workspace: WorkspaceManager?
    private let root: URL
    private let plan: CockpitPlan
    private let productionConfirmed: Bool
    private var activeQAID: String?

    init(workspace: WorkspaceManager, root: URL, plan: CockpitPlan, productionConfirmed: Bool) {
        self.workspace = workspace; self.root = root; self.plan = plan; self.productionConfirmed = productionConfirmed
    }

    func run(scenarioID: String, previous: CockpitHostReply) async -> CockpitHostReply {
        guard previous.error.isEmpty, previous.result.passed, let workspace,
              let review = plan.qaReviews?.first(where: { $0.scenarioID == scenarioID }),
              CockpitApproval(plan: plan, productionConfirmed: productionConfirmed)?.permits(plan) == true else {
            return failure("The selected QA plan is not approved or the agent step did not pass.")
        }
        let qa = workspace.qa
        guard qa.root == nil || qa.root?.standardizedFileURL == root.standardizedFileURL else { return failure("QA is attached to another project.") }
        qa.attach(root: root)
        guard let reservation = qa.reserveForCockpit() else { return failure("Another QA run is already active.") }
        defer { qa.releaseCockpitReservation(reservation) }
        do {
            try Task.checkCancellation()
            let listing = await Task.detached { QAStore.loadScenarios(self.root) }.value
            guard let diskScenario = listing.scenarios.first(where: { $0.id == scenarioID }) else { return failure("The approved QA scenario no longer exists.") }
            guard !qa.run.isRunning else { return failure("Another QA run is already active.") }
            qa.reload()
            for _ in 0..<100 {
                try Task.checkCancellation()
                if qa.scenarios.first(where: { $0.id == scenarioID }) == diskScenario { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !qa.run.isRunning else { return failure("Another QA run is already active.") }
            guard qa.scenarios.first(where: { $0.id == scenarioID }) == diskScenario else { return failure("The QA scenario could not be refreshed.") }
            qa.open(scenarioID)
            qa.targetID = review.targetID
            await qa.refreshSavedLogins()
            try Task.checkCancellation()
            guard let current = qa.current, current == diskScenario else { return failure("The QA scenario has unsaved or changed content; review the plan again.") }
            let logins = Set(qa.savedLogins.map { QALoginReference(host: $0.host, username: $0.username) })
            guard try CockpitQAReviewBuilder.make(scenario: current, targetID: review.targetID, savedLogins: logins) == review else {
                return failure("The approved QA plan changed; review and approve the new plan.")
            }
            guard qa.root?.standardizedFileURL == root.standardizedFileURL, !qa.run.isRunning else { return failure("The project changed or another QA run is already active.") }
            qa.withdrawApproval()
            qa.approve(acknowledgedProduction: productionConfirmed)
            guard qa.gate?.canPrepare == true, qa.gate?.approvedFingerprint == review.fingerprint else { return failure("The QA plan could not be approved.") }
            qa.startRun(cockpitToken: reservation)
            guard qa.run.isRunning else { return failure("QA could not start; check the scenario and application permissions.") }
            activeQAID = qa.run.activeRunID
            workspace.openQA()
            return try await withTaskCancellationHandler {
                while qa.run.isRunning {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                try Task.checkCancellation()
                guard let record = qa.run.record else { return failure("QA ended without a saved result.") }
                let passed = !record.lines.isEmpty && record.lines.allSatisfy { $0.outcome == .passed }
                let summary = "QA \(scenarioID), run \(record.id): \(record.lines.map { "\($0.branch): \($0.outcome?.rawValue ?? "uncovered")" }.joined(separator: "; "))"
                let result = CockpitResult(plan: plan, build: previous.result.build, outcome: summary, qaRunID: record.id)
                try await Task.detached { try CockpitResults.save(result, root: self.root) }.value
                return CockpitHostReply(result: CockpitHostResult(passed: passed, detail: previous.result.detail + "\n" + summary, build: previous.result.build,
                                                                 scenarioID: scenarioID, qaRunID: record.id), error: "")
            } onCancel: {
                Task { @MainActor [weak self] in
                    if let id = self?.activeQAID, qa.run.activeRunID == id { qa.run.stop() }
                }
            }
        } catch is CancellationError {
            if let id = activeQAID, qa.run.activeRunID == id { qa.run.stop() }
            return failure("QA was interrupted; review its known results before continuing.")
        } catch {
            return failure("QA could not complete or its evidence could not be saved: \(error.localizedDescription)")
        }
    }

    private func failure(_ message: String) -> CockpitHostReply {
        CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: message)
    }
}
