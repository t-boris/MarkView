import Foundation

/// One-use completion tickets bind an agent's report to the project and step that issued it.
@MainActor
enum CockpitAgentRegistry {
    private struct Pending {
        let root: URL
        let finish: (CockpitHostReply) -> Void
        let progress: (CockpitProgress) async throws -> Void
        /// The text the agent gets back for a question it asked the supervisor.
        let ask: (CockpitSupervisor.Question) async -> String
        let waitForShutdown: () async -> Void
    }
    private static var pending: [UUID: Pending] = [:]

    /// The restrictions of one running step and what the gate saw, bound to the shell of the step's terminal.
    /// Removed with the ticket, so a finished or cancelled step leaves no restriction behind.
    private struct StepGuard {
        let policy: CockpitStepPolicy
        /// What the person has switched off during the run, asked on every call so that a cut bites at the agent's next call.
        let cuts: () -> CockpitLiveSwitches
        let shell: pid_t
        let onFixCycle: (Int) -> Void
        /// Told of every call of the agent: the tool, and the reason when the call was refused (and kept for the step's report).
        let onActivity: (String, String?) -> Void
        var refusals: [String] = []
        var fixCycles = 0
    }
    private static var guards: [UUID: StepGuard] = [:]
    private static let refusalLimit = 50

    static func register(root: URL, progress: @escaping (CockpitProgress) async throws -> Void = { _ in },
                         ask: @escaping (CockpitSupervisor.Question) async -> String = { _ in CockpitSupervisor.disabledReply },
                         waitForShutdown: @escaping () async -> Void = {}, finish: @escaping (CockpitHostReply) -> Void) -> UUID {
        let token = UUID()
        pending[token] = Pending(root: root.standardizedFileURL, finish: finish, progress: progress, ask: ask, waitForShutdown: waitForShutdown)
        return token
    }

    /// The supervisor's answer to the step's question; nil when the ticket is not a running step of this project.
    static func ask(root: URL, token: UUID, question: CockpitSupervisor.Question) async -> String? {
        guard let item = pending[token], item.root == root.standardizedFileURL else { return nil }
        return await item.ask(question)
    }

    @discardableResult static func report(root: URL, token: UUID, progress: CockpitProgress) async -> Bool {
        guard (1...1_000).contains(progress.passNumber),
              [progress.scenarioCoverage, progress.bugs, progress.fixes, progress.blockers].allSatisfy({ $0.count <= 100 }),
              (progress.criteriaResults?.count ?? 0) <= 100,
              let data = try? JSONEncoder().encode(progress), data.count <= 16_000,
              let item = pending[token], item.root == root.standardizedFileURL else { return false }
        do { try await item.progress(progress); return true } catch { return false }
    }

    @discardableResult static func complete(root: URL, token: UUID, result: CockpitHostResult) -> Bool {
        guard result.detail.utf8.count <= 32_000, result.build.utf8.count <= 2_000,
              let item = pending[token], item.root == root.standardizedFileURL else { return false }
        pending[token] = nil
        item.finish(CockpitHostReply(result: result, error: ""))
        // After finish: the step's report still reads what the gate refused.
        guards[token] = nil
        return true
    }

    /// Binds the step's restrictions to the shell of its terminal. Calls made from processes under that shell go through `gate`.
    /// `onFixCycle` hears how many times the agent has moved a bug into fixing during this step; `onActivity` hears every call.
    static func restrict(_ token: UUID, policy: CockpitStepPolicy, cuts: @escaping () -> CockpitLiveSwitches = { CockpitLiveSwitches() },
                         shell: pid_t, onFixCycle: @escaping (Int) -> Void,
                         onActivity: @escaping (String, String?) -> Void = { _, _ in }) {
        guard pending[token] != nil, shell > 0 else { return }
        guards[token] = StepGuard(policy: policy, cuts: cuts, shell: shell, onFixCycle: onFixCycle, onActivity: onActivity)
    }

    /// The decision on one MarkView tool call, or nil when the caller is not the agent of a restricted step (a person's own
    /// terminal, another window). A refused call is remembered for the step's report; an allowed move of a bug into fixing is counted.
    static func gate(tool: String, arguments: [String: Any], ancestors: [Int32], isFixingStatus: (String) -> Bool,
                     environmentNames: (String) -> [String]) -> CockpitStepPolicy.Decision? {
        let among = Set(ancestors)
        guard let token = guards.first(where: { among.contains($0.value.shell) })?.key, var step = guards[token] else { return nil }
        let decision = step.policy.narrowed(by: step.cuts()).decision(tool: tool, arguments: arguments, isFixingStatus: isFixingStatus, environmentNames: environmentNames)
        switch decision {
        case .refuse(let reason):
            let kept = step.refusals.count < refusalLimit
            if kept { step.refusals.append("\(tool): \(reason)") }
            step.onActivity(tool, kept ? reason : nil)
        case .allow:
            step.onActivity(tool, nil)
            if CockpitStepPolicy.startsFixCycle(tool: tool, arguments: arguments, isFixingStatus: isFixingStatus) {
                step.fixCycles += 1
                step.onFixCycle(step.fixCycles)
            }
        }
        guards[token] = step
        return decision
    }

    static func refusals(_ token: UUID) -> [String] { guards[token]?.refusals ?? [] }
    static func fixCycles(_ token: UUID) -> Int { guards[token]?.fixCycles ?? 0 }

    static func cancel(_ token: UUID, reason: String) {
        guard let item = pending.removeValue(forKey: token) else { return }
        item.finish(CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: reason))
        guards[token] = nil
    }

    static func cancelAll(reason: String) {
        for token in Array(pending.keys) { cancel(token, reason: reason) }
    }

    static func cancelAllAndWait(reason: String) async {
        let items = pending
        for token in items.keys { cancel(token, reason: reason) }
        for item in items.values { await item.waitForShutdown() }
    }
}
