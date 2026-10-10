import Foundation
import SwiftUI

/// One command asked for, waiting for the person's yes.
struct DeploymentApproval: Identifiable {
    let id = UUID()
    let environment: DeploymentEnvironment
    let command: String
    /// Why it is not run unattended.
    let reason: String
    /// "You" or "The assistant".
    let origin: String
    /// What the asker says it is for.
    let purpose: String
    fileprivate let answer: (Bool) -> Void
}

struct CommandLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Date
    var environment: String
    var command: String
    var origin: String
    /// ran, denied, blocked
    var outcome: String
    var status: Int32?
}

enum DeploymentRunOutcome {
    case ran(CommandResult)
    case denied
    case blocked(String)
    case unavailable(String)

    /// For a person or an assistant to read.
    var summary: String {
        switch self {
        case .ran(let r):
            var text = r.stdout
            if !r.stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + r.stderr }
            if r.timedOut { text += "\n[timed out]" }
            if r.truncated { text += "\n[output cut]" }
            return "exit \(r.status)\n" + text
        case .denied: return "The person did not approve this command. It was not run."
        case .blocked(let why): return "Blocked: " + why
        case .unavailable(let why): return why
        }
    }
}

/// The environments of a project and what is known about them. One per window; the file is
/// `.dde/deployments.json` (no secrets), the commands that ran are noted in `.dde/deployments-log.jsonl`.
@MainActor
final class DeploymentStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, failed }
    struct Sample: Equatable { let time: Date; let load: Double; let memory: Double; let disk: Int }
    struct CloudOutput: Equatable { let command: String; let result: CommandResult; let at: Date }
    struct State: Equatable {
        var phase = Phase.idle
        var snapshot: SystemSnapshot?
        var held: [DeploymentCheck] = []
        var problem: ConnectionProblem?
        var cloud: [String: CloudOutput] = [:]
        var history: [Sample] = []
        var updated: Date?
        var note: String?
    }

    @Published private(set) var environments: [DeploymentEnvironment] = []
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var suggestions: [DeploymentSuggestion] = []
    @Published private(set) var scanning = false
    @Published private(set) var log: [CommandLogEntry] = []
    @Published var approval: DeploymentApproval?
    @Published var selected: String?
    @Published var autoRefresh = false { didSet { restartAuto() } }
    @Published var lastError: String?

    /// Seconds a request waits for the person before it counts as no (a test sets it short).
    static var approvalTimeout: TimeInterval = 180
    private(set) var root: URL?
    private(set) var hasScanned = false
    /// Asked to bring the Deployments tab forward (an approval is waiting).
    var onNeedsAttention: (() -> Void)?
    private var autoTask: Task<Void, Never>?
    private var queue: [DeploymentApproval] = []

    // MARK: Files

    private var folder: URL? { root?.appendingPathComponent(".dde", isDirectory: true) }
    private var file: URL? { folder?.appendingPathComponent("deployments.json") }
    private var logFile: URL? { folder?.appendingPathComponent("deployments-log.jsonl") }

    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        autoTask?.cancel()
        root = url
        environments = []; states = [:]; suggestions = []; log = []; selected = nil; hasScanned = false
        guard let file, let data = try? Data(contentsOf: file), let decoded = DeploymentsFile.decode(data) else { loadLog(); return }
        environments = decoded.environments
        selected = environments.first?.id
        loadLog()
    }

    private func save() {
        guard let folder, let file else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DeploymentsFile(environments: environments).encoded().write(to: file, options: .atomic)
        } catch { lastError = "Could not save the environments: \(error.localizedDescription)" }
    }

    private func loadLog() {
        guard let logFile, let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        log = text.split(separator: "\n").suffix(200).compactMap { try? decoder.decode(CommandLogEntry.self, from: Data($0.utf8)) }
    }

    private func note(_ entry: CommandLogEntry) {
        log.append(entry)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        guard let folder, let logFile else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile(); handle.write(data); handle.write(Data("\n".utf8)); try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: logFile)
        }
    }

    // MARK: Editing

    func environment(_ id: String) -> DeploymentEnvironment? { environments.first { $0.id == id } }

    func add(_ env: DeploymentEnvironment) {
        var env = env
        env.id = DeploymentEnvironment.slug(env.name, existing: Set(environments.map(\.id)))
        environments.append(env)
        selected = env.id
        save()
    }

    func update(_ env: DeploymentEnvironment) {
        guard let index = environments.firstIndex(where: { $0.id == env.id }) else { return }
        environments[index] = env
        save()
    }

    func remove(_ id: String) {
        environments.removeAll { $0.id == id }
        states[id] = nil
        if selected == id { selected = environments.first?.id }
        save()
    }

    /// Replace the whole list (an assistant proposed environments and the person accepted them).
    func accept(_ suggestion: DeploymentSuggestion) {
        add(suggestion.makeEnvironment(existing: Set(environments.map(\.id))))
        suggestions.removeAll { $0.id == suggestion.id }
    }

    // MARK: Finding

    /// Look through the project's files and ~/.ssh/config for places it runs.
    func scan() {
        guard let root, !scanning else { return }
        scanning = true
        hasScanned = true
        let configText = try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)
        Task {
            let found = await Task.detached(priority: .userInitiated) { DeploymentDiscovery.scan(root: root, sshConfig: configText) }.value
            let known = Set(environments.map { $0.host.isEmpty ? $0.provider : $0.host })
            suggestions = found.filter { !known.contains($0.host.isEmpty ? $0.provider : $0.host) }
            scanning = false
        }
    }

    /// The logs of an environment: its own sources, then what the machine and the last look suggest.
    func logSources(_ id: String) -> [LogSource] {
        guard let env = environment(id) else { return [] }
        return DeploymentLogs.all(for: env, snapshot: states[id]?.snapshot)
    }

    // MARK: Looking

    private func executor(for env: DeploymentEnvironment) -> DeploymentExecutor { DeploymentExecutors.make(for: env, projectRoot: root) }

    func refreshAll() { for env in environments { Task { await refresh(env.id) } } }

    func refresh(_ id: String) async {
        guard let env = environment(id) else { return }
        var state = states[id] ?? State()
        if let problem = env.problems.first { state.phase = .failed; state.problem = .other(problem); states[id] = state; return }
        state.phase = .loading
        states[id] = state
        let exec = executor(for: env)
        let (run, held) = SystemProbe.runnable(env.checks)
        var result = State(phase: .loaded, held: held, cloud: state.cloud, history: state.history)

        if env.kind == .cloud {
            result.snapshot = nil
            if !run.isEmpty {
                let probe = await exec.run("sh -s", stdin: SystemProbe.script(checks: run, includeSystem: false), timeout: 40)
                var snap = SystemProbe.parse(probe.stdout); snap.os = "cloud"
                result.snapshot = snap
            }
            for command in env.cloudCommands where CommandPolicy.classify(command.command).isReadOnly {
                let output = await exec.run(command.command, stdin: nil, timeout: 60)
                result.cloud[command.id] = CloudOutput(command: command.command, result: output, at: Date())
                note(CommandLogEntry(time: Date(), environment: env.id, command: command.command, origin: "Refresh", outcome: "ran", status: output.status))
            }
        } else {
            let probe = await exec.run("sh -s", stdin: SystemProbe.script(checks: run), timeout: 45)
            if env.kind == .ssh, let problem = ConnectionProblem.from(probe) { result.phase = .failed; result.problem = problem }
            else if probe.stdout.isEmpty { result.phase = .failed; result.problem = .other(probe.stderr.isEmpty ? "The machine did not answer." : probe.stderr) }
            else {
                var snap = SystemProbe.parse(probe.stdout)
                snap.collectedAt = Date()
                result.snapshot = snap
                result.history.append(Sample(time: Date(), load: snap.loadPerCPU, memory: snap.memUsedFraction, disk: snap.disks.map(\.percent).max() ?? 0))
                if result.history.count > 120 { result.history.removeFirst(result.history.count - 120) }
            }
        }
        result.updated = Date()
        states[id] = result
    }

    private func restartAuto() {
        autoTask?.cancel()
        guard autoRefresh else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.refreshAll()
            }
        }
    }

    func stopAuto() { autoTask?.cancel() }

    // MARK: Running commands

    /// Run `command` on an environment. A read-only command runs at once; anything else only after the
    /// person says yes to that exact command; a blocked one never runs.
    func run(_ command: String, on id: String, origin: String, purpose: String = "", timeout: TimeInterval = 60) async -> DeploymentRunOutcome {
        guard let env = environment(id) else { return .unavailable("There is no environment \(id).") }
        guard env.problems.isEmpty else { return .unavailable("The environment is not set up properly: " + env.problems.joined(separator: " ")) }
        let risk = CommandPolicy.classify(command)
        switch risk {
        case .blocked(let why):
            note(CommandLogEntry(time: Date(), environment: id, command: command, origin: origin, outcome: "blocked", status: nil))
            return .blocked(why)
        case .needsConfirmation(let why):
            let approved = await ask(env: env, command: command, reason: why, origin: origin, purpose: purpose)
            guard approved else {
                note(CommandLogEntry(time: Date(), environment: id, command: command, origin: origin, outcome: "denied", status: nil))
                return .denied
            }
        case .readOnly: break
        }
        let result = await executor(for: env).run(command, stdin: nil, timeout: timeout)
        note(CommandLogEntry(time: Date(), environment: id, command: command, origin: origin, outcome: "ran", status: result.status))
        return .ran(result)
    }

    private func ask(env: DeploymentEnvironment, command: String, reason: String, origin: String, purpose: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = DeploymentApproval(environment: env, command: command, reason: reason, origin: origin, purpose: purpose) { [weak self] yes in
                continuation.resume(returning: yes)
                Task { @MainActor in self?.next() }
            }
            if approval == nil { approval = request } else { queue.append(request) }
            onNeedsAttention?()
            // Nobody at the screen: after three minutes the answer is no.
            let id = request.id
            let wait = Self.approvalTimeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self?.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        if approval?.id == id { answer(false) }
        else if let index = queue.firstIndex(where: { $0.id == id }) { queue.remove(at: index).answer(false) }
    }

    /// The person's answer to the request on screen.
    func answer(_ yes: Bool) {
        guard let current = approval else { return }
        approval = nil
        current.answer(yes)
    }

    private func next() {
        if approval == nil, !queue.isEmpty { approval = queue.removeFirst() }
    }

    /// An assistant proposed a place; it waits for the person under "Found in the project".
    func propose(_ suggestion: DeploymentSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        suggestions.insert(suggestion, at: 0)
        onNeedsAttention?()
    }

    // MARK: What an assistant is told

    /// The environments and what is known of each, as text.
    func report() -> String { report(environments: environments) }

    func report(for id: String) -> String { report(environments: environments.filter { $0.id == id }) }

    private func report(environments: [DeploymentEnvironment]) -> String {
        guard !environments.isEmpty else { return "No environments are set up for this project yet." }
        return environments.map { env in
            var lines = ["\(env.name) (\(env.id)) — \(env.kind.rawValue)" + (env.kind == .ssh ? " \(env.destination):\(env.port)" : env.provider.isEmpty ? "" : " \(env.provider)")]
            if let state = states[env.id] {
                if let problem = state.problem { lines.append("  cannot connect: \(problem.message)") }
                if let snap = state.snapshot, snap.os != "cloud" {
                    lines.append("  health: \(snap.health == .ok ? "ok" : snap.health == .warning ? "warning" : "critical"); up \(SystemProbe.uptimeText(snap.uptimeSeconds)); load \(snap.load.map { String(format: "%.2f", $0) }.joined(separator: " ")) on \(snap.cpus) CPUs; memory \(Int(snap.memUsedFraction * 100)) % used")
                    for disk in snap.disks { lines.append("  disk \(disk.mount): \(disk.percent) %") }
                    for reason in snap.reasons { lines.append("  ! \(reason)") }
                    for container in snap.containers { lines.append("  container \(container.name): \(container.status)") }
                }
                for check in state.snapshot?.checks ?? [] { lines.append("  check \(check.id): \(check.status.rawValue)\(check.detail.isEmpty ? "" : " (\(check.detail))")") }
                if let updated = state.updated { lines.append("  looked at \(updated.formatted(date: .omitted, time: .standard))") }
            } else { lines.append("  not looked at yet") }
            for source in logSources(env.id) { lines.append("  log source \(source.id): \(source.title)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
