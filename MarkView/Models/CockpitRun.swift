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
        var progress: CockpitProgress? = nil
    }
    struct StepResult: Codable, Equatable {
        var plan: CockpitPlan
        var stepID: UUID
        var passed: Bool
        var detail: String
        var build: String
        var scenarioID: String? = nil
        var qaRunID: String? = nil
        var progress: CockpitProgress? = nil
        var interrupted: Bool? = nil
    }
    struct Revision: Codable, Equatable {
        var plan: CockpitPlan
        var approval: CockpitApproval
        var step: Int
        var fingerprint: String
    }

    private(set) var plan: CockpitPlan
    private(set) var status: Status = .awaitingApproval
    private(set) var steps: [StepRecord]
    private(set) var results: [StepResult] = []
    private(set) var currentIndex: Int?
    private(set) var waitingReason = ""
    private(set) var approval: CockpitApproval?
    private(set) var pendingRevision: Revision?
    /// Seconds the run's agents have worked, across interruptions: what the time limit is measured against. Absent in older runs.
    private(set) var activeSeconds: Double? = nil
    /// Fix cycles the run's steps have used: what the fix cycle limit is measured against. Absent in older runs.
    private(set) var fixCyclesUsed: Int? = nil

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
    mutating func completeCurrent(passed: Bool, detail: String, build: String, scenarioID: String? = nil, qaRunID: String? = nil, progress: CockpitProgress? = nil) -> Bool {
        guard status == .running, let index = currentIndex, steps.indices.contains(index), steps[index].status == .running else { return false }
        results.append(StepResult(plan: plan, stepID: steps[index].stepID, passed: passed, detail: detail, build: build, scenarioID: scenarioID, qaRunID: qaRunID, progress: progress))
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

    /// A stop keeps the reason of an interrupted step (a limit that was reached), which the person needs to read afterwards.
    mutating func stop() {
        status = .stopped
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .interrupted { return }
        waitingReason = ""
    }

    mutating func addUsage(seconds: Double, fixCycles: Int) {
        activeSeconds = (activeSeconds ?? 0) + max(0, seconds)
        fixCyclesUsed = (fixCyclesUsed ?? 0) + max(0, fixCycles)
    }

    mutating func recordProgress(_ progress: CockpitProgress, stepID: UUID) -> Bool {
        guard status == .running, let index = currentIndex, steps.indices.contains(index), steps[index].stepID == stepID,
              steps[index].status == .running else { return false }
        steps[index].progress = progress
        return true
    }

    /// The user explicitly chose a starting point after reviewing an interrupted step's known evidence.
    mutating func continueAfterInterruption(plan newPlan: CockpitPlan, approval: CockpitApproval, at index: Int) -> Bool {
        guard (status == .paused || status == .stopped), let oldIndex = currentIndex, steps.indices.contains(oldIndex), steps[oldIndex].status == .interrupted,
              approval.permits(newPlan), newPlan.steps.indices.contains(index) else { return false }
        let partial = steps[oldIndex]
        results.append(StepResult(plan: plan, stepID: partial.stepID, passed: false,
                                  detail: "Interrupted; effects may be incomplete. " + partial.detail, build: "",
                                  progress: partial.progress, interrupted: true))
        plan = newPlan
        self.approval = approval
        steps = newPlan.steps.enumerated().map { StepRecord(stepID: $0.element.id, status: $0.offset < index ? .skipped : .waiting) }
        currentIndex = index
        steps[index].status = .running
        status = .running
        waitingReason = ""
        pendingRevision = nil
        return true
    }

    mutating func discardPendingRevision(reason: String) {
        guard pendingRevision != nil else { return }
        pendingRevision = nil
        waitingReason = reason
    }

    /// Record the person's approved revision before sending it to the coordinator.
    mutating func queueRevision(plan: CockpitPlan, approval: CockpitApproval, at index: Int, fingerprint: String) -> Bool {
        guard pendingRevision == nil, (status == .running || status == .paused), approval.permits(plan), plan.steps.indices.contains(index), !fingerprint.isEmpty else { return false }
        pendingRevision = Revision(plan: plan, approval: approval, step: index, fingerprint: fingerprint)
        return true
    }

    /// A coordinator may adopt a revision only at a boundary; prior results keep their original plans.
    mutating func applyRevision(fingerprint: String) -> Bool {
        guard let revision = pendingRevision, revision.fingerprint == fingerprint, revision.approval.permits(revision.plan) else { return false }
        plan = revision.plan
        approval = revision.approval
        steps = plan.steps.enumerated().map { StepRecord(stepID: $0.element.id, status: $0.offset < revision.step ? .skipped : .waiting) }
        currentIndex = revision.step
        steps[revision.step].status = .running
        status = .running
        waitingReason = ""
        pendingRevision = nil
        return true
    }

    /// A process recovered after the app exited must not run by itself. An in-flight step may
    /// have had partial effects, so its outcome remains unknown until recovery is decided.
    /// `reason` replaces the standard text when the step was stopped on purpose, for example because a limit was reached.
    mutating func prepareAfterRestart(reason: String? = nil) {
        guard status == .running else { return }
        if let index = currentIndex, steps.indices.contains(index), steps[index].status == .running {
            steps[index].status = .interrupted
        }
        status = .paused
        waitingReason = reason ?? "The previous step was interrupted; its outcome is unknown. Separately detached background processes may still be running."
    }
}
