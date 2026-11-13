import Foundation

/// Persisted process state. The executor delivers step results; this value never runs an agent itself.
struct CockpitRun: Codable, Equatable {
    private(set) var id: UUID
    enum Status: String, Codable { case awaitingApproval, running, paused, stopped, finished }
    enum StepStatus: String, Codable { case waiting, running, interrupted, passed, failed, skipped }
    struct StepRecord: Codable, Equatable {
        var stepID: UUID
        var status: StepStatus = .waiting
        var detail: String = ""
    }
    struct StepResult: Codable, Equatable {
        var plan: CockpitPlan
        var stepID: UUID
        var passed: Bool
        var detail: String
        var build: String
    }

    private(set) var plan: CockpitPlan
    private(set) var status: Status = .awaitingApproval
    private(set) var steps: [StepRecord]
    private(set) var results: [StepResult] = []
    private(set) var currentIndex: Int?
    private(set) var waitingReason = ""
    private(set) var approval: CockpitApproval?

    init(plan: CockpitPlan) {
        id = UUID()
        self.plan = plan
        steps = plan.steps.map { StepRecord(stepID: $0.id) }
    }

    mutating func start(approval: CockpitApproval, at index: Int) -> Bool {
        guard status == .awaitingApproval || status == .stopped || status == .finished,
              approval.permits(plan), steps.indices.contains(index) else { return false }
        self.approval = approval
        for i in steps.indices { steps[i] = StepRecord(stepID: plan.steps[i].id, status: i < index ? .skipped : .waiting) }
        currentIndex = index; steps[index].status = .running; waitingReason = ""; status = .running
        return true
    }

    /// A failed prerequisite never advances; the user can retry after resolving the issue.
    mutating func completeCurrent(passed: Bool, detail: String, build: String) -> Bool {
        guard status == .running, let index = currentIndex, steps.indices.contains(index), steps[index].status == .running else { return false }
        results.append(StepResult(plan: plan, stepID: steps[index].stepID, passed: passed, detail: detail, build: build))
        steps[index].status = passed ? .passed : .failed
        steps[index].detail = detail
        if !passed {
            status = .paused; waitingReason = detail
        } else if index + 1 < steps.count {
            currentIndex = index + 1; steps[index + 1].status = .running
        } else {
            currentIndex = nil; status = .finished
        }
        return true
    }

    mutating func retryPrerequisite() -> Bool {
        guard status == .paused, let index = currentIndex, steps.indices.contains(index),
              plan.steps[index].isPrerequisite, steps[index].status == .failed,
              approval?.permits(plan) == true else { return false }
        steps[index].status = .running; waitingReason = ""; status = .running
        return true
    }

    /// Pausing requests a safe boundary; an in-flight agent must actually stop before its executor calls this.
    mutating func pauseAtBoundary(reason: String) {
        guard status == .running else { return }
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .running { steps[index].status = .waiting }
        status = .paused; waitingReason = reason
    }

    mutating func resumeAtBoundary() -> Bool {
        guard status == .paused, let index = currentIndex, steps.indices.contains(index),
              steps[index].status == .waiting, approval?.permits(plan) == true else { return false }
        steps[index].status = .running; status = .running; waitingReason = ""
        return true
    }

    mutating func stop() { status = .stopped; waitingReason = "" }

    /// A process recovered after the app exited must not run by itself. An in-flight step may
    /// have had partial effects, so its outcome remains unknown until recovery is decided.
    mutating func prepareAfterRestart() {
        guard status == .running else { return }
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .running {
            steps[index].status = .interrupted
        }
        status = .paused
        waitingReason = "The previous step was interrupted; its outcome is unknown. Separately detached background processes may still be running."
    }
}
