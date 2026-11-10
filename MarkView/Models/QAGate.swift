import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-002): the run's own gate. Nothing is prepared or executed before the person approved the
// plan; on production every action that may change data also needs a yes of its own; the person can stop the run at any time. The
// gate belongs to one run and keeps no memory of earlier runs: an approval or a confirmation never carries over. Foundation only.

struct QAGate: Equatable {
    enum State: Equatable {
        case needsApproval
        case approved
        case stopped
    }

    /// What may happen to one thing the run wants to do.
    enum Decision: Equatable {
        case allowed
        /// Production: the person has to say yes to this one first.
        case needsConfirmation(QAConfirmation)
        case refused(String)
    }

    private(set) var state: State = .needsApproval
    private(set) var approvedFingerprint: String?
    private(set) var approvedAt: Date?
    private(set) var confirmed: Set<String> = []
    private(set) var plan: QAExecutionPlan

    init(plan: QAExecutionPlan) { self.plan = plan }

    /// Approves the plan as it is now. A plan with blocking problems cannot be approved, and a production plan is approved only when the
    /// person acknowledged that it changes data on production. Returns whether the approval was given.
    @discardableResult
    mutating func approve(acknowledgedProduction: Bool, at time: Date = Date()) -> Bool {
        guard state != .stopped, plan.canBeApproved else { return false }
        if plan.isProduction && !plan.confirmations.isEmpty && !acknowledgedProduction { return false }
        state = .approved
        approvedFingerprint = plan.fingerprint
        approvedAt = time
        return true
    }

    /// Gives the gate the plan as the scenario is now. An approval was given for one plan: any other plan has to be approved again,
    /// and what was confirmed for the old one is forgotten.
    mutating func update(plan newPlan: QAExecutionPlan) {
        guard newPlan != plan else { return }
        plan = newPlan
        if state == .approved && approvedFingerprint != newPlan.fingerprint {
            state = .needsApproval
            approvedFingerprint = nil
            approvedAt = nil
            confirmed = []
        }
    }

    /// Preparation (sign-ins, accounts, baselines, conditions) may begin. An approved gate always holds the plan it was approved for:
    /// `update` takes the approval back as soon as the plan changes.
    var canPrepare: Bool { state == .approved }

    /// May the run do the step `id` of the preparation, or (as `node:<id>`) the action of a scenario step?
    func decision(for id: String) -> Decision {
        switch state {
        case .stopped: return .refused("The run was stopped.")
        case .needsApproval: return .refused("The plan is not approved.")
        case .approved: break
        }
        if let confirmation = plan.confirmations.first(where: { $0.id == id }), !confirmed.contains(id) { return .needsConfirmation(confirmation) }
        return .allowed
    }

    /// The person said yes to one thing that changes data on production.
    mutating func confirm(_ id: String) {
        guard state == .approved, plan.confirmations.contains(where: { $0.id == id }) else { return }
        confirmed.insert(id)
    }

    /// The person said yes to everything that is still waiting for it. This is explicit too: it is one answer to a question that lists them.
    mutating func confirmAllRemaining() {
        guard state == .approved else { return }
        for confirmation in plan.confirmations { confirmed.insert(confirmation.id) }
    }

    /// The person stopped the run. It cannot be resumed with the same gate.
    mutating func stop() { state = .stopped }

    var isStopped: Bool { state == .stopped }
}
