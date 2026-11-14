import Foundation

struct QALoginReference: Hashable { var host: String; var username: String }
struct SavedLogin { var host: String; var username: String }
struct QAScenario: Equatable { var id: String; var version: Int }
struct QAListing { var scenarios: [QAScenario] }
enum QAStore {
    static func loadScenarios(_ root: URL) -> QAListing { QAListing(scenarios: [QAScenario(id: "s", version: 1)]) }
}
enum CockpitQAReviewBuilder {
    static func make(scenario: QAScenario, targetID: String, savedLogins: Set<QALoginReference>) throws -> CockpitQAReview {
        CockpitQAReview(scenarioID: scenario.id, targetID: targetID, fingerprint: "v\(scenario.version)", production: true,
                        exactPlan: "plan \(scenario.version)", dataChangingActions: ["write"], productionConfirmationRequired: true)
    }
}
struct QAResultLine { var branch: String; var outcome: QAOutcome? }
enum QAOutcome: String { case passed, failed }
struct QARecord { var id: String; var lines: [QAResultLine] }
struct Gate { var canPrepare: Bool; var approvedFingerprint: String? }
@MainActor final class Run {
    var isRunning = false
    var activeRunID: String? { isRunning ? "run-1" : nil }
    var record: QARecord?
    var starts = 0
    func stop() { isRunning = false }
}
@MainActor final class QAModel {
    var root: URL?
    var scenarios: [QAScenario] = []
    var current: QAScenario?
    var targetID: String?
    var savedLogins: [SavedLogin] = []
    var gate: Gate?
    var run = Run()
    var reservation: UUID?
    var shouldHang = false
    func attach(root: URL) { self.root = root }
    func reserveForCockpit() -> UUID? { guard reservation == nil, !run.isRunning else { return nil }; let id = UUID(); reservation = id; return id }
    func releaseCockpitReservation(_ id: UUID) { if reservation == id { reservation = nil } }
    func reload() { scenarios = QAStore.loadScenarios(root!).scenarios }
    func open(_ id: String) { current = scenarios.first { $0.id == id } }
    func refreshSavedLogins() async {}
    func withdrawApproval() { gate = nil }
    func approve(acknowledgedProduction: Bool) { gate = Gate(canPrepare: acknowledgedProduction, approvedFingerprint: "v1") }
    func startRun(cockpitToken: UUID?) {
        guard reservation == cockpitToken, gate?.canPrepare == true else { return }
        run.starts += 1; run.isRunning = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: shouldHang ? 30_000_000_000 : 50_000_000)
            if run.isRunning { run.record = QARecord(id: "run-1", lines: [QAResultLine(branch: "b", outcome: .passed)]); run.isRunning = false }
        }
    }
}
@MainActor final class WorkspaceManager {
    let qa = QAModel()
    var opened = false
    func openQA() { opened = true }
}
struct CockpitHostResult: Codable { var passed: Bool; var detail: String; var build: String; var scenarioID: String? = nil; var qaRunID: String? = nil }
struct CockpitHostReply { var result: CockpitHostResult; var error: String }
struct CockpitResult { var plan: CockpitPlan; var build: String; var outcome: String; var qaRunID: String? }
enum CockpitResults {
    static func save(_ result: CockpitResult, root: URL) throws { try Data((result.qaRunID ?? "").utf8).write(to: root.appendingPathComponent("saved")) }
}

@main struct Checks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try CockpitQAReviewBuilder.make(scenario: QAScenario(id: "s", version: 1), targetID: "prod", savedLogins: [])
        let step = CockpitStep(title: "QA", agent: "Codex", assignment: "Prepare", completionCondition: "Pass", qaScenarioID: "s")
        var plan = CockpitPlan(goal: "Test", controls: CockpitControls(), scenarios: ["s"], steps: [step], successCriteria: ["Pass"], unavailableOutcomes: [], alternatives: [], productionQA: CockpitProductionQA(exactPlan: review.exactPlan, dataChangingActions: review.dataChangingActions))
        plan.qaReviews = [review]
        let previous = CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Prepared", build: "b1"), error: "")
        let workspace = WorkspaceManager()
        let denied = CockpitQAAttempt(workspace: workspace, root: root, plan: plan, productionConfirmed: false)
        let notApproved = await denied.run(scenarioID: "s", previous: previous)
        precondition(!notApproved.error.isEmpty && workspace.qa.run.starts == 0, "production must not run without confirmation")
        var stale = plan; stale.qaReviews?[0].fingerprint = "old"
        let changed = CockpitQAAttempt(workspace: workspace, root: root, plan: stale, productionConfirmed: true)
        let refused = await changed.run(scenarioID: "s", previous: previous)
        precondition(!refused.error.isEmpty && workspace.qa.run.starts == 0, "changed QA plan must not run")
        workspace.qa.run.isRunning = true
        let busy = await CockpitQAAttempt(workspace: workspace, root: root, plan: plan, productionConfirmed: true).run(scenarioID: "s", previous: previous)
        precondition(!busy.error.isEmpty && workspace.qa.run.isRunning && workspace.qa.run.starts == 0, "another QA run must not be interrupted")
        workspace.qa.run.isRunning = false
        let attempt = CockpitQAAttempt(workspace: workspace, root: root, plan: plan, productionConfirmed: true)
        let result = await attempt.run(scenarioID: "s", previous: previous)
        precondition(result.error.isEmpty && result.result.passed && result.result.qaRunID == "run-1" && workspace.opened, "approved QA should run and link its result")
        let saved = try String(contentsOf: root.appendingPathComponent("saved"), encoding: .utf8)
        precondition(saved == "run-1", "QA evidence should be retained")
        workspace.qa.shouldHang = true
        let stopping = CockpitQAAttempt(workspace: workspace, root: root, plan: plan, productionConfirmed: true)
        let task = Task { await stopping.run(scenarioID: "s", previous: previous) }
        for _ in 0..<100 where !workspace.qa.run.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(workspace.qa.run.isRunning, "interruptible QA must start")
        task.cancel()
        let stopped = await task.value
        precondition(!stopped.error.isEmpty && !workspace.qa.run.isRunning, "cancel must stop the cockpit's QA run")
        print("Cockpit QA approval and execution checks passed")
    }
}
