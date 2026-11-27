import Foundation

/// What a cockpit-run QA scenario needs of the window: the QA model and the QA tab.
@MainActor
protocol CockpitQAWindow: AnyObject {
    var qa: QAModel { get }
    /// Brings the QA tool's tab forward.
    func showQATool()
}

/// Runs only the exact QA scenario and target approved with this cockpit plan.
@MainActor
final class CockpitQAAttempt {
    private weak var workspace: (any CockpitQAWindow)?
    private let root: URL
    private let plan: CockpitPlan
    private let productionConfirmed: Bool
    private let onProgress: (String, [String], [String]) async throws -> Void
    private var activeQAID: String?

    init(workspace: any CockpitQAWindow, root: URL, plan: CockpitPlan, productionConfirmed: Bool,
         onProgress: @escaping (String, [String], [String]) async throws -> Void = { _, _, _ in }) {
        self.workspace = workspace; self.root = root; self.plan = plan; self.productionConfirmed = productionConfirmed
        self.onProgress = onProgress
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
            workspace.showQATool()
            return try await withTaskCancellationHandler {
                var previousActivity = "", previousCoverage: [String] = [], previousBlockers: [String] = []
                var finalProgress = previous.result.progress ?? CockpitProgress(passNumber: 1, activity: "", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
                while qa.run.isRunning {
                    try Task.checkCancellation()
                    let activity = "QA \(scenarioID): " + (qa.run.currentNode ?? qa.run.currentBranch ?? "preparing")
                    let coverage = qa.run.results.map { "\(scenarioID)/\($0.branch): \($0.verdict.outcome.rawValue)" }
                    let blockers = qa.run.question.map { ["Waiting for confirmation: " + $0.title] } ?? []
                    if activity != previousActivity || coverage != previousCoverage || blockers != previousBlockers {
                        try await self.onProgress(activity, coverage, blockers)
                        finalProgress.activity = activity; finalProgress.scenarioCoverage = coverage; finalProgress.blockers = blockers
                        previousActivity = activity; previousCoverage = coverage; previousBlockers = blockers
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                try Task.checkCancellation()
                guard let record = qa.run.record else { return failure("QA ended without a saved result.") }
                let passed = !record.lines.isEmpty && record.lines.allSatisfy { $0.outcome == .passed }
                let filed = qa.run.filedBugIDs
                finalProgress.activity = "QA \(scenarioID) finished"
                finalProgress.scenarioCoverage = record.lines.map { "\(scenarioID)/\($0.branch): \($0.outcome?.rawValue ?? "uncovered")" }
                finalProgress.blockers += record.lines.filter { $0.outcome != .passed }.map { "\($0.branch): \($0.reason ?? "not passed")" }
                finalProgress.bugs += filed.filter { !finalProgress.bugs.contains($0) }
                try await self.onProgress(finalProgress.activity, finalProgress.scenarioCoverage, finalProgress.blockers)
                let summary = CockpitQAReport.summary(scenarioID: scenarioID, record: record)
                let failures = CockpitQAReport.failures(record: record, scenario: current)
                let result = CockpitResult(plan: plan, build: previous.result.build, outcome: summary, qaRunID: record.id, scenarioID: scenarioID)
                try await Task.detached { try CockpitResults.save(result, root: self.root) }.value
                return CockpitHostReply(result: CockpitHostResult(passed: passed, detail: CockpitQAReport.detail(summary: summary, failures: failures, filed: filed, agentDetail: previous.result.detail),
                                                                 build: previous.result.build, scenarioID: scenarioID, qaRunID: record.id, progress: finalProgress,
                                                                 neededInput: passed ? previous.result.neededInput : CockpitQAReport.neededInput(failures: failures, filed: filed)), error: "")
            } onCancel: {
                Task { @MainActor [weak self] in
                    if let id = self?.activeQAID, qa.run.activeRunID == id { qa.run.stop() }
                }
            }
        } catch is CancellationError {
            if let id = activeQAID, qa.run.activeRunID == id { qa.run.stop() }
            return failure("QA was interrupted; review its known results before continuing.")
        } catch {
            if let id = activeQAID, qa.run.activeRunID == id { qa.run.stop() }
            return failure("QA could not complete or its evidence could not be saved: \(error.localizedDescription)")
        }
    }

    private func failure(_ message: String) -> CockpitHostReply {
        CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: message)
    }
}

/// What a finished QA run puts into its Cockpit step's result (BUG-130): the outcome of each branch first, then where and why each
/// branch that did not pass stopped, and the bugs the run filed, so the timeline, the notice and the next steps read them first.
enum CockpitQAReport {
    static func summary(scenarioID: String, record: QARunRecord) -> String {
        "QA \(scenarioID), run \(record.id): " + record.lines.map { "\($0.branch): \($0.outcome?.rawValue ?? "uncovered")" }.joined(separator: "; ")
    }

    /// One sentence for each selected branch that did not pass, in the order of the run; empty when every branch passed.
    static func failures(record: QARunRecord, scenario: QAScenario?) -> [String] {
        record.selected.compactMap { id in
            let verdict = record.results.first { $0.branch == id }?.verdict
            if verdict?.outcome == .passed { return nil }
            let branch = QABranch(nodes: id.split(separator: ">").map(String.init))
            var text = scenario.map { scenario in branch.nodes.allSatisfy { scenario.node($0) != nil } ? scenario.label(of: branch) : id } ?? id
            guard let verdict else { return text + ": not run." }
            text += ": " + verdict.outcome.rawValue
            if let node = verdict.node { text += " at step " + (scenario?.node(node).map { "\u{201C}\($0.title)\u{201D} (\(node))" } ?? node) }
            if let reason = verdict.blockReason { text += ", " + QABugDrafts.words(reason) }
            let why = verdict.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return text + (why.isEmpty ? "." : ": " + why)
        }
    }

    static func detail(summary: String, failures: [String], filed: [String], agentDetail: String) -> String {
        let head = [summary] + failures + (filed.isEmpty ? [] : ["Bugs filed by QA: " + filed.joined(separator: ", ") + "."])
        let agent = agentDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.joined(separator: "\n") + (agent.isEmpty ? "" : "\n\nThe agent's report before QA:\n" + agent)
    }

    /// What the step asks of the person when QA did not pass: where and why it stopped, and what QA filed.
    static func neededInput(failures: [String], filed: [String]) -> String? {
        guard !failures.isEmpty else { return nil }
        return "QA did not pass. " + failures.joined(separator: " ") + (filed.isEmpty ? "" : " Bugs filed: " + filed.joined(separator: ", ") + ".")
    }
}
