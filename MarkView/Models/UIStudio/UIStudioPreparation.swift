import Foundation

/// The bounds of automatic preparation (§12): a deadline per attempt, at most two attempts, a few at a time, and a budget
/// per session, after which the problem is shown instead of asking the model again.
struct StudioPreparationLimits: Equatable {
    /// One attempt's time, counted from when it gets a slot: waiting in the queue does not use it up (BUG-074). An agent
    /// that reads a large project needs well over 30 s.
    var deadline: TimeInterval = 90
    /// A preparation ahead of a page covers every request the page makes, so it gets longer (BUG-076): Codex needed more than
    /// 90 s for vivaa's home page. The page waits for it once per route; the rules are saved.
    var aheadDeadline: TimeInterval = 240
    /// How long a preparation waits for a free slot before it ends as timed out.
    var queueWait: TimeInterval = 120
    var maxAttempts = 2
    var maxConcurrent = 2
    var maxContracts = 40

    /// One attempt's time for `context`: longer for a page's requests prepared ahead and for a group of the application's map.
    func deadline(for context: StudioPreparationContext) -> TimeInterval {
        context.ahead == nil && context.mapGroup == nil ? deadline : aheadDeadline
    }

    /// The agent CLI's own limit: a little after the attempt's deadline, so the queue ends the attempt as timed out (no
    /// retry). A fixed 95 s cut every preparation ahead of a page at 95 s, as a failure, and so twice (BUG-077).
    func cliTimeout(for context: StudioPreparationContext) -> TimeInterval { deadline(for: context) + 5 }
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
    /// The environment variable through which the development server made the request; nil for the page's requests (REQ-007).
    var serverVariable: String? = nil
    /// The service the request goes to (its origin). A request to a service that is being prepared waits for that
    /// preparation, which often registers its rule too (BUG-074).
    var group: String? = nil
    /// Set for a preparation ahead of the page instead of one unknown request.
    var ahead: StudioRouteAhead? = nil
    /// Set for a group of the application's map (REQ-014): its endpoints, prepared before any page asks for them.
    var mapGroup: String? = nil
    /// The route handler of the application's own server that serves the request, and the start of its text, found by
    /// reading the code's folders (BUG-089): the agent starts there instead of searching the project for it.
    var handlerFile: String? = nil
    var handlerText: String? = nil
}

/// The requests a page makes through the development server's simulated connections, prepared before the page loads
/// (BUG-074): an application gives its own server calls a deadline of a few seconds, far less than an agent needs, so a
/// rule prepared when the request arrives always comes too late for that render.
struct StudioRouteAhead: Sendable, Equatable {
    var route: String
    /// One line per simulated connection: `VARIABLE → address (first read at file:line)`.
    var connections: [String]
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
/// wait for it; a result is registered only while its session generation is current and when it passes validation, all at
/// once (no partial state). An agent that is still working at its attempt's deadline is cancelled.
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
    /// Preparations ahead of a page: they belong to the environment, not to a scenario's generation, so Reset and another
    /// scenario do not cancel them (rules are reusable, SIM-05); closing the session does.
    private var ahead: [String: Task<StudioPreparationOutcome, Never>] = [:]
    /// The service of each running preparation, request or ahead (`group`).
    private var groups: [String: Set<String>] = [:]
    /// Groups of the application's map being prepared (REQ-014). Apart from `ahead`, so Stop of the current work does not
    /// end them; the map's Cancel and closing the session do.
    private var mapTasks: [String: Task<StudioPreparationOutcome, Never>] = [:]
    private var active = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    /// Model calls made, for the "0 calls for registered rules" check (§12).
    private(set) var modelCalls = 0
    /// Called when a preparation starts (a new record, `finished` nil) and when it ends (`finished` set), for the session's
    /// log (REQ-011).
    var onRecord: (@MainActor (Record) -> Void)?

    init(limits: StudioPreparationLimits = StudioPreparationLimits()) {
        self.limits = limits
    }

    var ordered: [Record] { records.values.sorted { $0.started > $1.started } }
    var isBusy: Bool { !running.isEmpty || !ahead.isEmpty }

    /// The generation of preparations ahead of a page, which no scenario change makes stale.
    static let environmentGeneration = -1

    /// Waits for the rule of `context.contract`. `commit` validates and registers a proposal and returns its problems (empty
    /// = registered); it is called on the main actor only while `currentGeneration()` still equals `generation`. A contract
    /// that failed is not prepared again until `retry` (bounded attempts).
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
            records[contract]?.finished = Date()
            report(contract)
            return .limitReached
        }
        records[contract] = Record(contract: contract, generation: generation, status: .waiting)
        report(contract)
        let task = Task { @MainActor [weak self] () -> StudioPreparationOutcome in
            guard let self else { return .cancelled }
            return await self.run(context, generation: generation, preparer: preparer, currentGeneration: currentGeneration, commit: commit)
        }
        running[contract] = task
        if let group = context.group { groups[contract] = [group] }
        let outcome = await task.value
        running[contract] = nil
        groups[contract] = nil
        finish(contract, generation: generation, outcome: outcome)
        return outcome
    }

    /// Prepares the requests of a page before it loads (BUG-074). One preparation per contract however many callers wait;
    /// its result is registered whatever the scenario's generation is by then, because rules belong to the environment.
    func prepareAhead(_ context: StudioPreparationContext, services: Set<String>, preparer: StudioRulePreparing,
                      commit: @escaping @MainActor (StudioProposal) -> [String]) async -> StudioPreparationOutcome {
        let contract = context.contract
        if let task = ahead[contract] {
            records[contract]?.requests += 1
            return await task.value
        }
        let generation = Self.environmentGeneration
        records[contract] = Record(contract: contract, generation: generation, status: .waiting)
        report(contract)
        let task = Task { @MainActor [weak self] () -> StudioPreparationOutcome in
            guard let self else { return .cancelled }
            return await self.run(context, generation: generation, preparer: preparer, currentGeneration: { generation }, commit: commit)
        }
        ahead[contract] = task
        groups[contract] = services
        let outcome = await task.value
        ahead[contract] = nil
        groups[contract] = nil
        finish(contract, generation: generation, outcome: outcome)
        return outcome
    }

    /// Waits until no preparation for `group` (a service's origin) is running, so a request to a service that is being
    /// prepared does not start a second model call for rules that are about to be registered.
    func waitForGroup(_ group: String) async {
        while let task = groups.first(where: { $0.value.contains(group) }).flatMap({ running[$0.key] ?? ahead[$0.key] }) {
            _ = await task.value
            // The task's own caller clears its entry after this resumes; give it the turn.
            await Task.yield()
        }
    }

    /// Ends every preparation of the scenario's requests (Reset, another scenario, Stop): late answers are dropped (SIM-10,
    /// AC-07). Preparations ahead of a page go on: their rules do not depend on the scenario.
    func cancelAll() {
        for task in running.values { task.cancel() }
        for waiter in slotWaiters { waiter.resume() }
        slotWaiters = []
    }

    /// Ends every preparation, those ahead of a page too (the session closes, or its connections change).
    func cancelEverything() {
        for task in ahead.values { task.cancel() }
        cancelAll()
    }

    /// Prepares one group of the application's map (REQ-014). Like a preparation ahead of a page, it belongs to the
    /// environment: neither Reset nor Stop cancels it, the map's Cancel and closing the session do. It takes none of the slots the page's own
    /// preparations use and makes no record: the map shows its own progress, and the session is not "Preparing" for as long
    /// as the application is mapped. It lists no service for `waitForGroup`, because a map prepares many groups of one
    /// service in turn: a request waits only for the group that has its endpoint (`StudioEnvironmentMapper.waitForEndpoint`).
    func prepareMapGroup(_ context: StudioPreparationContext, preparer: StudioRulePreparing,
                         commit: @escaping @MainActor (StudioProposal) -> [String]) async -> StudioPreparationOutcome {
        let contract = context.contract
        if let task = mapTasks[contract] { return await task.value }
        let generation = Self.environmentGeneration
        let task = Task { @MainActor [weak self] () -> StudioPreparationOutcome in
            guard let self else { return .cancelled }
            return await self.run(context, generation: generation, preparer: preparer, currentGeneration: { generation },
                                  commit: commit, usesSlot: false)
        }
        mapTasks[contract] = task
        let outcome = await task.value
        mapTasks[contract] = nil
        return outcome
    }

    /// Ends the map's group preparations of `contracts` (the person cancelled mapping, or the session closes).
    func cancelMapGroups(_ contracts: Set<String>) {
        for contract in contracts { mapTasks[contract]?.cancel() }
    }

    /// Forgets a failed contract so the next request prepares it again (the user's "Retry").
    func retry(_ contract: String) {
        guard running[contract] == nil else { return }
        records[contract] = nil
    }

    func clear() {
        cancelEverything()
        records = [:]
    }

    // MARK: Running

    private func run(_ context: StudioPreparationContext, generation: Int, preparer: StudioRulePreparing,
                     currentGeneration: @escaping @MainActor () -> Int,
                     commit: @escaping @MainActor (StudioProposal) -> [String],
                     usesSlot: Bool = true) async -> StudioPreparationOutcome {
        if usesSlot, !(await acquireSlot(until: Date().addingTimeInterval(limits.queueWait))) {
            return Task.isCancelled ? .cancelled : .timedOut
        }
        defer { if usesSlot { releaseSlot() } }
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
            let answer = await Self.withDeadline(Date().addingTimeInterval(limits.deadline(for: context))) { try await preparer.prepare(request) }
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
                // An answer that arrived is used even when the request that asked for it has given up: its rules serve
                // the next request (BUG-074). The deadline is enforced by cancelling the agent, not by dropping answers.
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
        case .timedOut:
            record.status = .timedOut
            let seconds = generation == Self.environmentGeneration ? limits.aheadDeadline : limits.deadline
            record.message = "The agent did not finish within \(Int(seconds)) s."
        case .cancelled: record.status = .cancelled; record.message = "Cancelled."
        case .unsupported(let reason): record.status = .unsupported; record.message = reason
        case .stale: record.status = .stale; record.message = "The session was reset while the agent worked; its answer was dropped."
        case .limitReached: record.status = .limit; record.message = "The preparation budget is used up."
        }
        records[contract] = record
        report(contract)
    }

    private func report(_ contract: String) {
        if let record = records[contract] { onRecord?(record) }
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
