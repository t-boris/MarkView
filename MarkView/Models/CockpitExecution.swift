import Foundation

struct CockpitExecutionState: Decodable {
    var status: String
    var current: Int
    var reason: String
    var fingerprint: String
    var pendingFingerprint: String
    var results: [CockpitHostEntry]
}

/// Owns the worker and host connection for a single reviewed execution.
@MainActor
final class CockpitExecution: ObservableObject {
    enum Failure: LocalizedError {
        case alreadyRunning, approval, unavailable
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "An execution is already active."
            case .approval: return "The exact plan and selected starting step must be approved."
            case .unavailable: return "The execution is unavailable."
            }
        }
    }

    @Published private(set) var state: CockpitExecutionState?
    @Published private(set) var error: String?
    private let service: CockpitService
    private let root: URL
    private let handler: @Sendable (CockpitHostTask) async -> CockpitHostReply
    private var bridge: CockpitHostBridge?
    private var worker: CockpitChild?
    private var endpoint: CockpitEndpoint?
    private var workflowID = ""
    private var queue = ""
    private var poll: Task<Void, Never>?
    private var starting = false
    private var shutdownRequested = false
    private var mutatingRecord = false
    private var record: CockpitRun?
    var isActive: Bool { starting || worker != nil }
    var runID: UUID? { record?.id }
    func stepStatus(_ id: UUID) -> String? { record?.steps.first(where: { $0.stepID == id })?.status.rawValue }

    init(root: URL, service: CockpitService, handler: @escaping @Sendable (CockpitHostTask) async -> CockpitHostReply) {
        self.root = root
        self.service = service
        self.handler = handler
    }

    func start(plan: CockpitPlan, approval: CockpitApproval, step: Int, recovering: CockpitRun? = nil) async throws {
        try Task.checkCancellation()
        guard !starting, worker == nil else { throw Failure.alreadyRunning }
        guard approval.permits(plan), plan.steps.indices.contains(step) else { throw Failure.approval }
        starting = true
        shutdownRequested = false
        defer { starting = false }
        var initial = recovering ?? CockpitRun(plan: plan)
        if recovering != nil {
            guard initial.continueAfterInterruption(plan: plan, approval: approval, at: step) else { throw Failure.approval }
        } else {
            guard initial.start(approval: approval, at: step) else { throw Failure.approval }
        }
        let temporalPlan = try CockpitTemporalPlan(plan, prior: recovering == nil ? [] : initial.results)
        try await save(initial)
        record = initial
        state = nil
        workflowID = "cockpit-" + UUID().uuidString.lowercased()
        queue = "cockpit-" + UUID().uuidString.lowercased()
        var approvalMayHaveBeenSent = false
        do {
            try Task.checkCancellation()
            let handler = self.handler
            let bridge = try CockpitHostBridge { [weak self] task in
                let reply = await handler(task)
                guard reply.error.isEmpty else { return reply }
                guard let self, let stepID = UUID(uuidString: task.step.id) else {
                    return CockpitHostReply(result: reply.result, error: "The step result could not be saved.")
                }
                do {
                    try await self.saveHostResult(reply.result, stepID: stepID, planFingerprint: task.planFingerprint)
                    return reply
                } catch {
                    return CockpitHostReply(result: reply.result, error: "The step result could not be saved; execution was interrupted.")
                }
            }
            self.bridge = bridge
            endpoint = try await service.start()
            guard !shutdownRequested, !Task.isCancelled else { throw CancellationError() }
            worker = try await service.worker(socket: bridge.path, queue: queue)
            guard !shutdownRequested, !Task.isCancelled else { throw CancellationError() }
            _ = try await request("start", plan: temporalPlan)
            guard !shutdownRequested, !Task.isCancelled else { throw CancellationError() }
            approvalMayHaveBeenSent = true
            _ = try await request("approve", approval: CockpitTemporalApproval(fingerprint: temporalPlan.fingerprint, step: step))
            guard !shutdownRequested, !Task.isCancelled else { throw CancellationError() }
            error = nil
            poll = Task { [weak self] in
                while !Task.isCancelled, let self {
                    guard self.worker?.isRunning == true else {
                        self.error = "The local worker stopped; the current step may have been interrupted."
                        self.releaseWorker()
                        return
                    }
                    do {
                        let data = try await self.request("state")
                        let state = try JSONDecoder().decode(CockpitExecutionState.self, from: data)
                        guard try await self.record(state) else {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            continue
                        }
                        self.state = state
                        if state.status == "stopped" || state.status == "finished" { self.releaseWorker(); return }
                    } catch {
                        self.error = error.localizedDescription
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        } catch {
            if var record {
                if approvalMayHaveBeenSent { record.prepareAfterRestart() }
                else if let recovering { record = recovering }
                else { record.stop() }
                try? await save(record)
                self.record = record
            }
            releaseWorker()
            throw error
        }
    }

    func control(_ command: String) async throws {
        guard ["pause", "stop", "retry"].contains(command), worker != nil else { throw Failure.unavailable }
        _ = try await request("control", command: command)
    }

    func saveProgress(_ progress: CockpitProgress, stepID: UUID, planFingerprint: String) async throws {
        try await waitForRecord(planFingerprint: planFingerprint)
        mutatingRecord = true
        defer { mutatingRecord = false }
        guard var next = record, (try CockpitTemporalPlan(next.plan).fingerprint) == planFingerprint,
              next.recordProgress(progress, stepID: stepID) else { throw Failure.unavailable }
        do { try await save(next); record = next }
        catch {
            _ = try? await request("control", command: "pause")
            throw error
        }
    }

    /// Persist a finished step before acknowledging it to Temporal, so no later step can
    /// begin while its predecessor's known result exists only in workflow memory.
    func saveHostResult(_ result: CockpitHostResult, stepID: UUID, planFingerprint: String) async throws {
        try await waitForRecord(planFingerprint: planFingerprint)
        mutatingRecord = true
        defer { mutatingRecord = false }
        guard var next = record, (try CockpitTemporalPlan(next.plan).fingerprint) == planFingerprint,
              let index = next.currentIndex, next.steps.indices.contains(index), next.steps[index].stepID == stepID,
              next.completeCurrent(passed: result.passed, detail: result.detail, build: result.build,
                                   scenarioID: result.scenarioID, qaRunID: result.qaRunID, progress: result.progress) else { throw Failure.unavailable }
        try await save(next)
        record = next
    }

    private func waitForRecord(planFingerprint: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline, !shutdownRequested, worker?.isRunning == true else { throw Failure.unavailable }
            if !mutatingRecord, let record {
                let current = try CockpitTemporalPlan(record.plan).fingerprint
                if current == planFingerprint { break }
                if record.pendingRevision?.fingerprint != planFingerprint { throw Failure.unavailable }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func replan(_ plan: CockpitPlan, approval: CockpitApproval, step: Int) async throws {
        guard !mutatingRecord, worker?.isRunning == true, let state, ["running", "paused"].contains(state.status), var next = record,
              approval.permits(plan), plan.steps.indices.contains(step) else { throw Failure.unavailable }
        mutatingRecord = true
        defer { mutatingRecord = false }
        let current = try CockpitTemporalPlan(next.plan)
        let updated = try CockpitTemporalPlan(plan)
        guard current.fingerprint == state.fingerprint, updated.fingerprint != current.fingerprint else { throw Failure.approval }
        if let pending = next.pendingRevision {
            guard pending.plan == plan, pending.approval == approval, pending.step == step, pending.fingerprint == updated.fingerprint else { throw Failure.unavailable }
        } else {
            guard next.queueRevision(plan: plan, approval: approval, at: step, fingerprint: updated.fingerprint) else { throw Failure.approval }
            try await save(next)
            record = next
        }
        guard !shutdownRequested, !Task.isCancelled else { throw CancellationError() }
        _ = try await request("replan", revision: CockpitTemporalRevision(expectedFingerprint: current.fingerprint, plan: updated, step: step))
    }

    /// Closing a project must disconnect the host and stop its worker immediately.
    func shutdown() {
        shutdownRequested = true
        poll?.cancel(); poll = nil
        releaseWorker()
    }

    private func request(_ action: String, plan: CockpitTemporalPlan? = nil, approval: CockpitTemporalApproval? = nil, command: String? = nil, revision: CockpitTemporalRevision? = nil) async throws -> Data {
        guard let endpoint else { throw Failure.unavailable }
        return try await service.request(CockpitTemporalRequest(address: endpoint.address, queue: queue, workflowID: workflowID,
            action: action, plan: plan, approval: approval, command: command, tls: endpoint.tls, revision: revision))
    }

    private func releaseWorker() {
        worker?.stop(); worker = nil
        bridge?.stop(); bridge = nil
    }

    private func save(_ record: CockpitRun) async throws {
        let root = root
        try await Task.detached { try CockpitRunStore.save(record, root: root) }.value
    }

    private func record(_ state: CockpitExecutionState) async throws -> Bool {
        guard !mutatingRecord else { return false }
        mutatingRecord = true
        defer { mutatingRecord = false }
        guard var next = record else { throw Failure.unavailable }
        if state.results.count < next.results.count {
            if state.status == "interrupted" { next.prepareAfterRestart() }
            else if state.status == "stopped" { next.stop() }
            else { return false }
            try await save(next)
            record = next
            return true
        }
        for entry in state.results.dropFirst(next.results.count) {
            let current = try CockpitTemporalPlan(next.plan).fingerprint
            if let fingerprint = entry.planFingerprint, !fingerprint.isEmpty, fingerprint != current {
                guard next.applyRevision(fingerprint: fingerprint) else { throw Failure.unavailable }
            }
            if next.status == .paused { _ = next.retryPrerequisite() }
            guard let index = next.currentIndex, next.steps[index].stepID.uuidString == entry.stepID,
                  next.completeCurrent(passed: entry.result.passed, detail: entry.result.detail, build: entry.result.build,
                                       scenarioID: entry.result.scenarioID, qaRunID: entry.result.qaRunID, progress: entry.result.progress) else { throw Failure.unavailable }
        }
        if state.fingerprint != (try CockpitTemporalPlan(next.plan).fingerprint) {
            guard next.applyRevision(fingerprint: state.fingerprint) else { throw Failure.unavailable }
        }
        if state.status == "interrupted" { next.prepareAfterRestart() }
        if state.status == "stopped" { next.stop() }
        if ["finished", "stopped"].contains(state.status), next.pendingRevision != nil {
            next.discardPendingRevision(reason: "The run ended before the approved changes were applied.")
        }
        if next != record {
            do { try await save(next) }
            catch {
                // Do not continue unrecorded work when durable history cannot be written.
                _ = try? await request("control", command: "pause")
                throw error
            }
            record = next
        }
        return true
    }
}
