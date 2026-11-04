import Foundation

/// The bounds of automatic preparation (§12): one deadline per contract, at most two attempts, a few at a time, and a budget
/// per session, after which the problem is shown instead of asking the model again.
struct StudioPreparationLimits: Equatable {
    var deadline: TimeInterval = 30
    var maxAttempts = 2
    var maxConcurrent = 2
    var maxContracts = 40
}

/// What the agent is given for one unknown request. Bodies and headers are already redacted.
struct StudioPreparationContext: Sendable, Equatable {
    var contract: String
    var method: String
    var url: String
    var headers: [String: String]
    var body: String?
    var attempt: Int
    /// Why the previous attempt was refused (validation problems), for the second attempt.
    var problems: [String]
}

/// Prepares rules for unknown requests (the environment agent). The app's implementation asks the project's assistant
/// with read-only access; tests use stand-ins.
protocol StudioRulePreparing: Sendable {
    func prepare(_ context: StudioPreparationContext) async throws -> StudioProposal
}

enum StudioPreparationOutcome: Equatable {
    case registered(rules: [String])
    case failed(String)
    case timedOut
    case cancelled
    case unsupported(String)
    /// The session moved on (Reset, another scenario) while the agent worked: its result was dropped.
    case stale
    case limitReached
}

/// Unknown requests and their preparation (SIM-07, SIM-08, SIM-10; plan I-4). One task per contract however many requests
/// wait for it; a result is registered only while its session generation is current, before its deadline and when it passes
/// validation, all at once (no partial state).
@MainActor
final class StudioPreparationQueue: ObservableObject {
    struct Record: Identifiable, Equatable {
        enum Status: String { case waiting, preparing, registered, failed, timedOut, cancelled, unsupported, stale, limit }
        var id: String { contract }
        var contract: String
        var generation: Int
        var status: Status
        var attempts = 0
        var started = Date()
        var finished: Date?
        var message = ""
        var requests = 1
    }

    let limits: StudioPreparationLimits
    @Published private(set) var records: [String: Record] = [:]
    private var running: [String: Task<StudioPreparationOutcome, Never>] = [:]
    private var active = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    /// Model calls made, for the "0 calls for registered rules" check (§12).
    private(set) var modelCalls = 0

    init(limits: StudioPreparationLimits = StudioPreparationLimits()) {
        self.limits = limits
    }

    var ordered: [Record] { records.values.sorted { $0.started > $1.started } }
    var isBusy: Bool { !running.isEmpty }

    /// Waits for the rule of `context.contract`. `commit` validates and registers a proposal and returns its problems (empty
    /// = registered); it is called on the main actor only while `currentGeneration()` still equals `generation` and before
    /// the deadline. A contract that failed is not prepared again until `retry` (bounded attempts).
    func resolve(_ context: StudioPreparationContext, generation: Int, preparer: StudioRulePreparing,
                 currentGeneration: @escaping @MainActor () -> Int,
                 commit: @escaping @MainActor (StudioProposal) -> [String]) async -> StudioPreparationOutcome {
        let contract = context.contract
        if let task = running[contract] {
            records[contract]?.requests += 1
            return await task.value
        }
        if let record = records[contract], record.generation == generation {
            switch record.status {
            case .failed: return .failed(record.message)
            case .timedOut: return .timedOut
            case .unsupported: return .unsupported(record.message)
            case .limit: return .limitReached
            default: break
            }
        }
        let prepared = records.values.filter { $0.generation == generation && $0.status != .cancelled && $0.status != .stale }.count
        if prepared >= limits.maxContracts {
            records[contract] = Record(contract: contract, generation: generation, status: .limit,
                                       message: "The preparation budget of this session is used up (\(limits.maxContracts) contracts).")
            return .limitReached
        }
        records[contract] = Record(contract: contract, generation: generation, status: .waiting)
        let deadline = Date().addingTimeInterval(limits.deadline)
        let task = Task { @MainActor [weak self] () -> StudioPreparationOutcome in
            guard let self else { return .cancelled }
            return await self.run(context, generation: generation, deadline: deadline, preparer: preparer,
                                  currentGeneration: currentGeneration, commit: commit)
        }
        running[contract] = task
        let outcome = await task.value
        running[contract] = nil
        finish(contract, generation: generation, outcome: outcome)
        return outcome
    }

    /// Ends every preparation (Reset, another scenario, Stop): late answers are dropped (SIM-10, AC-07).
    func cancelAll() {
        for task in running.values { task.cancel() }
        for waiter in slotWaiters { waiter.resume() }
        slotWaiters = []
    }

    /// Forgets a failed contract so the next request prepares it again (the user's "Retry").
    func retry(_ contract: String) {
        guard running[contract] == nil else { return }
        records[contract] = nil
    }

    func clear() {
        cancelAll()
        records = [:]
    }

    // MARK: Running

    private func run(_ context: StudioPreparationContext, generation: Int, deadline: Date, preparer: StudioRulePreparing,
                     currentGeneration: @escaping @MainActor () -> Int,
                     commit: @escaping @MainActor (StudioProposal) -> [String]) async -> StudioPreparationOutcome {
        guard await acquireSlot(until: deadline) else {
            return Task.isCancelled ? .cancelled : .timedOut
        }
        defer { releaseSlot() }
        records[context.contract]?.status = .preparing
        var problems: [String] = []
        for attempt in 1...max(1, limits.maxAttempts) {
            if Task.isCancelled { return .cancelled }
            if currentGeneration() != generation { return .stale }
            records[context.contract]?.attempts = attempt
            var attemptContext = context
            attemptContext.attempt = attempt
            attemptContext.problems = problems
            let request = attemptContext
            modelCalls += 1
            let answer = await Self.withDeadline(deadline) { try await preparer.prepare(request) }
            // Every check happens here, on the main actor, right before the state could change.
            if Task.isCancelled { return .cancelled }
            if currentGeneration() != generation { return .stale }
            switch answer {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            case .failed(let message):
                problems = [message]
                if attempt == limits.maxAttempts { return .failed(message) }
            case .value(let proposal):
                if Date() >= deadline { return .timedOut }
                if proposal.unsupported { return .unsupported(proposal.reason.isEmpty ? "a dependency outside the first release" : proposal.reason) }
                let refused = commit(proposal)
                if refused.isEmpty { return .registered(rules: proposal.rules.map(\.id)) }
                problems = refused
                if attempt == limits.maxAttempts {
                    return .failed("The proposed rule was not valid: " + refused.prefix(4).joined(separator: "; "))
                }
            }
        }
        return .failed(problems.first ?? "No rule was prepared.")
    }

    private func finish(_ contract: String, generation: Int, outcome: StudioPreparationOutcome) {
        guard var record = records[contract], record.generation == generation else { return }
        record.finished = Date()
        switch outcome {
        case .registered(let rules): record.status = .registered; record.message = "Registered " + rules.joined(separator: ", ")
        case .failed(let message): record.status = .failed; record.message = message
        case .timedOut: record.status = .timedOut; record.message = "The agent did not finish within \(Int(limits.deadline)) s."
        case .cancelled: record.status = .cancelled; record.message = "Cancelled."
        case .unsupported(let reason): record.status = .unsupported; record.message = reason
        case .stale: record.status = .stale; record.message = "The session was reset while the agent worked; its answer was dropped."
        case .limitReached: record.status = .limit; record.message = "The preparation budget is used up."
        }
        records[contract] = record
    }

    // MARK: Concurrency and deadline

    private func acquireSlot(until deadline: Date) async -> Bool {
        while active >= limits.maxConcurrent {
            if Task.isCancelled || Date() >= deadline { return false }
            // Woken when a slot frees or at the deadline, whichever comes first; a spurious wake only checks again.
            let wake = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000) + 1_000_000)
                self?.wakeWaiters()
            }
            await withCheckedContinuation { slotWaiters.append($0) }
            wake.cancel()
        }
        if Task.isCancelled || Date() >= deadline { return false }
        active += 1
        return true
    }

    private func releaseSlot() {
        active -= 1
        if !slotWaiters.isEmpty { slotWaiters.removeFirst().resume() }
    }

    private func wakeWaiters() {
        let waiters = slotWaiters
        slotWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    enum Answer<Value: Sendable>: Sendable {
        case value(Value), failed(String), timedOut, cancelled
    }

    /// Runs `work` until `deadline`; the work is cancelled when the deadline comes first (its CLI process ends with it).
    static func withDeadline<Value: Sendable>(_ deadline: Date, _ work: @escaping @Sendable () async throws -> Value) async -> Answer<Value> {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else { return .timedOut }
        return await withTaskGroup(of: Answer<Value>.self) { group in
            group.addTask {
                do { return .value(try await work()) } catch is CancellationError { return .cancelled } catch { return .failed(error.localizedDescription) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return Task.isCancelled ? .cancelled : .timedOut
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            if case .cancelled = first, Task.isCancelled { return .cancelled }
            return first
        }
    }
}
