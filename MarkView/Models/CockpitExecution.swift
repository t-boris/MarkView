import Foundation

struct CockpitExecutionState: Decodable {
    var status: String
    var current: Int
    var reason: String
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
    private var record: CockpitRun?
    var isActive: Bool { starting || worker != nil }
    var runID: UUID? { record?.id }

    init(root: URL, service: CockpitService, handler: @escaping @Sendable (CockpitHostTask) async -> CockpitHostReply) {
        self.root = root
        self.service = service
        self.handler = handler
    }

    func start(plan: CockpitPlan, approval: CockpitApproval, step: Int) async throws {
        try Task.checkCancellation()
        guard !starting, worker == nil else { throw Failure.alreadyRunning }
        guard approval.permits(plan), plan.steps.indices.contains(step) else { throw Failure.approval }
        starting = true
        shutdownRequested = false
        defer { starting = false }
        let temporalPlan = try CockpitTemporalPlan(plan)
        var initial = CockpitRun(plan: plan)
        guard initial.start(approval: approval, at: step) else { throw Failure.approval }
        try await save(initial)
        record = initial
        state = nil
        workflowID = "cockpit-" + UUID().uuidString.lowercased()
        queue = "cockpit-" + UUID().uuidString.lowercased()
        var approvalMayHaveBeenSent = false
        do {
            try Task.checkCancellation()
            let bridge = try CockpitHostBridge(handler: handler)
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
                        try await self.record(state)
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
                if approvalMayHaveBeenSent { record.prepareAfterRestart() } else { record.stop() }
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

    /// Closing a project must disconnect the host and stop its worker immediately.
    func shutdown() {
        shutdownRequested = true
        poll?.cancel(); poll = nil
        releaseWorker()
    }

    private func request(_ action: String, plan: CockpitTemporalPlan? = nil, approval: CockpitTemporalApproval? = nil, command: String? = nil) async throws -> Data {
        guard let endpoint else { throw Failure.unavailable }
        return try await service.request(CockpitTemporalRequest(address: endpoint.address, queue: queue, workflowID: workflowID,
            action: action, plan: plan, approval: approval, command: command, tls: endpoint.tls))
    }

    private func releaseWorker() {
        worker?.stop(); worker = nil
        bridge?.stop(); bridge = nil
    }

    private func save(_ record: CockpitRun) async throws {
        let root = root
        try await Task.detached { try CockpitRunStore.save(record, root: root) }.value
    }

    private func record(_ state: CockpitExecutionState) async throws {
        guard var next = record, state.results.count >= next.results.count else { throw Failure.unavailable }
        for entry in state.results.dropFirst(next.results.count) {
            if next.status == .paused { _ = next.retryPrerequisite() }
            guard let index = next.currentIndex, next.steps[index].stepID.uuidString == entry.stepID,
                  next.completeCurrent(passed: entry.result.passed, detail: entry.result.detail, build: entry.result.build,
                                       scenarioID: entry.result.scenarioID, qaRunID: entry.result.qaRunID) else { throw Failure.unavailable }
        }
        if state.status == "interrupted" { next.prepareAfterRestart() }
        if state.status == "stopped" { next.stop() }
        if next != record {
            do { try await save(next) }
            catch {
                // Do not continue unrecorded work when durable history cannot be written.
                _ = try? await request("control", command: "pause")
                throw error
            }
            record = next
        }
    }
}
