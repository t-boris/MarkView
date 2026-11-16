import Combine
import Foundation
import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

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

    /// What a cloud place runs, as a list of things with a state (see `CloudServices`).
    struct ServicesState: Equatable {
        var items: [CloudService] = []
        /// Why a part of the list is missing (signed out, a command failed).
        var problems: [String] = []
        var loading = false
        var updated: Date?
    }

    /// What the log reader, the "Run a command" box and the install button of one environment show. The store keeps it, so the command
    /// that fills it belongs to the store and ends with the window or the folder.
    struct ConsoleState: Equatable {
        /// A command of this environment is running (a second one waits for the first: the buttons are off meanwhile).
        var running = false
        /// What the command box and the install button last printed.
        var output: String?
        /// What the log reader last fetched.
        var log = ""
    }

    @Published private(set) var environments: [DeploymentEnvironment] = []
    @Published private(set) var servicesStates: [String: ServicesState] = [:]
    @Published private(set) var consoles: [String: ConsoleState] = [:]
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var suggestions: [DeploymentSuggestion] = []
    @Published private(set) var scanning = false
    @Published private(set) var log: [CommandLogEntry] = []
    @Published var databaseStates: [String: DatabaseState] = [:]
    @Published var approval: DeploymentApproval?
    @Published var selected: String?
    @Published var autoRefresh = false { didSet { restartAuto() } }
    @Published var lastError: String?

    /// Seconds a request waits for the person before it counts as no (a test sets it short).
    static var approvalTimeout: TimeInterval = 180
    private(set) var root: URL?
    private(set) var hasScanned = false
    /// Sent when the Deployments tab should come forward (an approval is waiting).
    let needsAttention = PassthroughSubject<Void, Never>()
    /// The 30 s refresh of every environment, a job of the app's scheduler (`AR-19`): paused while the app is in the background.
    private let autoKey = "deployments-auto-" + UUID().uuidString
    var polling = PollingScheduler.app
    /// The looks, the scan and the waits for an answer that are running, keyed so that a new one replaces the old; closing the window or
    /// opening another folder cancels them (`AR-19`).
    let tasks = TaskBag()
    private var queue: [DeploymentApproval] = []

    // MARK: Files

    private static let fileStore = SchemaVersionedStore<DeploymentsFile>()
    private var folder: URL? { root.map { ProjectPaths.localFolder($0) } }
    private var file: URL? { folder?.appendingPathComponent("deployments.json") }
    private var logFile: URL? { folder?.appendingPathComponent("deployments-log.jsonl") }

    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        polling.stop(key: autoKey)
        tasks.cancelAll()
        scanning = false
        root = url
        environments = []; states = [:]; servicesStates = [:]; consoles = [:]; databaseStates = [:]
        suggestions = []; log = []; selected = nil; hasScanned = false
        defer { loadLog() }
        guard let file else { return }
        // A file that cannot be read leaves the list empty and the file as it is: the next save copies it to a backup first.
        let result = Self.fileStore.load(from: file)
        lastError = result.problem
        guard let decoded = result.value else { return }
        environments = decoded.environments
        selected = environments.first?.id
    }

    private func save() {
        guard let file else { return }
        do { try Self.fileStore.save(DeploymentsFile(environments: environments), to: file) }
        catch { lastError = "Could not save the environments: \(error.localizedDescription)" }
    }

    private func loadLog() {
        guard let logFile, let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        log = JSONLinesFile.decode(CommandLogEntry.self, from: text, using: decoder, owner: "deployment command log", last: 200).records
    }

    func note(_ entry: CommandLogEntry) {
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
        for target in environment(id)?.databases ?? [] where target.source == .keychain { DatabaseKeychain.delete(account: (root?.path ?? "") + "|" + id + "|" + target.id) }
        environments.removeAll { $0.id == id }
        states[id] = nil
        databaseStates = databaseStates.filter { !$0.key.hasPrefix(id + "|") }
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
        tasks.store(Task {
            let found = await Task.detached(priority: .userInitiated) { DeploymentDiscovery.scan(root: root, sshConfig: configText) }.value
            guard !Task.isCancelled else { return }
            let known = Set(environments.map { $0.host.isEmpty ? $0.provider : $0.host })
            suggestions = found.filter { !known.contains($0.host.isEmpty ? $0.provider : $0.host) }
            scanning = false
        }, for: "scan")
    }

    /// The logs of an environment: its own sources, then what the machine and the last look suggest.
    func logSources(_ id: String) -> [LogSource] {
        guard let env = environment(id) else { return [] }
        return DeploymentLogs.all(for: env, snapshot: states[id]?.snapshot)
    }

    // MARK: Looking

    func executor(for env: DeploymentEnvironment) -> DeploymentExecutor { DeploymentExecutors.make(for: env, projectRoot: root) }

    /// Looks at every environment; a look still running at one is replaced by the new one.
    func refreshAll() {
        for env in environments { startRefresh(env.id) }
    }

    /// Looks at one environment; a look still running at it is replaced by this one.
    func startRefresh(_ id: String) {
        tasks.store(Task { await refresh(id) }, for: "refresh:" + id)
    }

    /// Reads the things a cloud place runs; a read still running for it is replaced by this one.
    func startServices(_ id: String) {
        tasks.store(Task { await loadServices(id) }, for: "services:" + id)
    }

    func refresh(_ id: String) async {
        // A look that was replaced, or whose window closed, before it began does not even mark the environment as being looked at.
        guard !Task.isCancelled, let env = environment(id) else { return }
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
                // A look that was replaced, or whose window closed, notes nothing and keeps nothing.
                guard !Task.isCancelled else { return }
                result.cloud[command.id] = CloudOutput(command: command.command, result: output, at: Date())
                note(CommandLogEntry(time: Date(), environment: env.id, command: command.command, origin: "Refresh", outcome: "ran", status: output.status))
            }
            await loadServices(id)
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
        // The window closed or the folder changed while the machine was being asked: the answer is of no one now.
        guard !Task.isCancelled else { return }
        result.updated = Date()
        states[id] = result
    }

    /// The things a cloud place runs: the provider's own list commands (read-only, JSON), then a reachability look at the
    /// public sites. The list keeps what it had while it loads.
    func loadServices(_ id: String) async {
        guard !Task.isCancelled, let env = environment(id), env.kind == .cloud, env.problems.isEmpty else { return }
        let scope = CloudServices.scope(of: env.cloudCommands)
        let queries = CloudServices.queries(provider: env.provider, scope: scope)
        guard !queries.isEmpty else { return }
        var current = servicesStates[id] ?? ServicesState()
        current.loading = true
        servicesStates[id] = current
        let exec = executor(for: env)
        var items: [CloudService] = [], problems: [String] = []
        for query in queries where CommandPolicy.classify(query.command).isReadOnly {
            let output = await exec.run(query.command, stdin: nil, timeout: 60)
            note(CommandLogEntry(time: Date(), environment: id, command: query.command, origin: "Services", outcome: "ran", status: output.status))
            let text = output.stderr + output.stdout
            if output.succeeded {
                let parsed = CloudServices.parse(query, provider: env.provider, scope: scope, output: output.stdout)
                if parsed.isEmpty, CloudServices.json(output.stdout) == nil, !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    problems.append("\(query.group): the answer of `\(query.command)` could not be read.")
                }
                items += parsed
            } else {
                let firstLine = text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { String($0.prefix(200)) } ?? "no answer"
                problems.append("\(query.group): " + (ProviderHints.advice(command: query.command, stderr: text, status: output.status) ?? firstLine))
            }
        }
        let probes = items.indices.filter { items[$0].probe }
        let answers = await withTaskGroup(of: (Int, Int?, Double).self) { group -> [(Int, Int?, Double)] in
            for index in probes {
                let address = items[index].openURL ?? ""
                group.addTask { let r = await Self.probe(address); return (index, r.code, r.seconds) }
            }
            var all: [(Int, Int?, Double)] = []
            for await answer in group { all.append(answer) }
            return all
        }
        for (index, code, seconds) in answers {
            let result = CloudServices.probeResult(code: code, seconds: seconds)
            items[index].level = result.level
            items[index].state = result.state
        }
        guard !Task.isCancelled else { return }
        servicesStates[id] = ServicesState(items: items, problems: problems, loading: false, updated: Date())
    }

    /// One look at a public address of the person's own: the status code and how long it took.
    nonisolated private static func probe(_ address: String) async -> (code: Int?, seconds: Double) {
        guard let url = URL(string: address), url.scheme == "https" else { return (nil, 0) }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        let started = Date()
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return (nil, Date().timeIntervalSince(started)) }
        return (http.statusCode, Date().timeIntervalSince(started))
    }

    private func restartAuto() {
        polling.stop(key: autoKey)
        guard autoRefresh else { return }
        let key = autoKey, polling = polling
        polling.every(30, key: key) { [weak self] in
            guard let self else { polling.stop(key: key); return }
            self.refreshAll()
        }
    }

    func stopAuto() { polling.stop(key: autoKey) }

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

    func ask(env: DeploymentEnvironment, command: String, reason: String, origin: String, purpose: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = DeploymentApproval(environment: env, command: command, reason: reason, origin: origin, purpose: purpose) { [weak self] yes in
                continuation.resume(returning: yes)
                // task: hops onto the main actor to show the next request; it holds nothing of its own
                Task { @MainActor in self?.next() }
            }
            if approval == nil { approval = request } else { queue.append(request) }
            needsAttention.send()
            // Nobody at the screen: after three minutes the answer is no.
            let id = request.id
            let wait = Self.approvalTimeout
            tasks.store(Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.expire(id)
            }, for: "expire:" + id.uuidString)
        }
    }

    private func expire(_ id: UUID) {
        if approval?.id == id { answer(false) }
        else if let index = queue.firstIndex(where: { $0.id == id }) { queue.remove(at: index).answer(false) }
    }

    // MARK: The command box, the log reader and the installer of an environment

    private func console(_ id: String, _ change: (inout ConsoleState) -> Void) {
        var state = consoles[id] ?? ConsoleState()
        change(&state)
        consoles[id] = state
    }

    private enum ConsoleFill { case log(String), output(String) }

    /// Starts one command of an environment's console. A command already running there is not replaced: the buttons are off while it runs
    /// (a replaced one would leave its approval waiting), so a second start is dropped. The answer fills the log or the output; a
    /// command that was not a read-only look, or an install, is followed by a look at the environment.
    private func startConsole(on id: String, clearOutput: Bool = false, _ work: @escaping () async -> (fill: ConsoleFill, thenRefresh: Bool)) {
        guard consoles[id]?.running != true else { return }
        console(id) { $0.running = true; if clearOutput { $0.output = nil } }
        tasks.store(Task { [weak self] in
            let (fill, thenRefresh) = await work()
            guard !Task.isCancelled, let self else { return }
            self.console(id) { state in
                state.running = false
                switch fill {
                case .log(let text): state.log = text
                case .output(let text): state.output = text
                }
            }
            if thenRefresh { self.startRefresh(id) }
        }, for: "console:" + id)
    }

    /// Fetches a log of an environment into its log reader (a read-only command, so it runs at once).
    func startLogFetch(_ command: String, on id: String) {
        startConsole(on: id) { [self] in
            (.log(await run(command, on: id, origin: "You").summary), false)
        }
    }

    /// Runs what the person typed in the command box; one that is not read-only waits for the person's yes and is followed by a look.
    func startCommand(_ command: String, on id: String) {
        startConsole(on: id, clearOutput: true) { [self] in
            (.output(await run(command, on: id, origin: "You").summary), CommandPolicy.classify(command).isReadOnly == false)
        }
    }

    /// Installs a provider's command-line tool after the person approved the exact command, then looks at the environment again.
    func startInstall(_ command: String, purpose: String, on id: String) {
        startConsole(on: id) { [self] in
            (.output(await run(command, on: id, origin: "You", purpose: purpose, timeout: 900).summary), true)
        }
    }

    /// Puts a line in the command box's output (what to do next after a sign-in command was copied).
    func showOutput(_ text: String, on id: String) { console(id) { $0.output = text } }

    /// The window closes: the auto-refresh, the looks, the scan and the waits end, and a command still waiting for a yes counts as no.
    func close() {
        polling.stop(key: autoKey)
        tasks.cancelAll()
        scanning = false
        let waiting = [approval].compactMap { $0 } + queue
        approval = nil
        queue = []
        for request in waiting { request.answer(false) }
    }

    /// The person's answer to the request on screen.
    func answer(_ yes: Bool) {
        guard let current = approval else { return }
        approval = nil
        tasks.cancel(key: "expire:" + current.id.uuidString)
        current.answer(yes)
    }

    private func next() {
        if approval == nil, !queue.isEmpty { approval = queue.removeFirst() }
    }

    /// An assistant proposed a place; it waits for the person under "Found in the project".
    func propose(_ suggestion: DeploymentSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        suggestions.insert(suggestion, at: 0)
        needsAttention.send()
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
            lines += databaseReport(for: env)
            for source in logSources(env.id) { lines.append("  log source \(source.id): \(source.title)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
