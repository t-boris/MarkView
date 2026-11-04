import Darwin
import Foundation

/// The development server a UI Studio session started itself (REQ-006, AC-18). It runs in a process group of its own, so
/// closing the session stops the server and everything it started — and nothing else. A server that was already running
/// when the session opened is used but never stopped: the session does not own it.
///
/// The project is trusted local code: the server runs with the user's permissions (the interface says so). It does not
/// inherit production secrets of MarkView's environment, and the shell's startup files only contribute `PATH`.
final class StudioDevServer: @unchecked Sendable {
    let command: String
    let folder: URL
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exited: Int32?
    private var buffer = ""
    private var handle: FileHandle?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called on a background queue with every piece of output and once when the process ends.
    var onOutput: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    init(command: String, folder: URL) {
        self.command = command
        self.folder = folder
    }

    var processID: pid_t { lock.withLock { pid } }
    var exitStatus: Int32? { lock.withLock { exited } }
    var isRunning: Bool { lock.withLock { pid != 0 && exited == nil } }

    /// The last output, at most 64 KB.
    var output: String { lock.withLock { buffer } }

    enum Failure: LocalizedError {
        case spawn(Int32)
        var errorDescription: String? {
            switch self {
            case .spawn(let code): return "The development server could not be started (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Starts `/bin/sh -c <command>` in `folder`, in a new process group, with `environment`. The shell stays the group's
    /// leader (no `exec`): a command may be compound, such as `cd web && npm run dev`.
    func start(environment: [String: String]) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw Failure.spawn(errno) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A process group of its own; no other descriptor of MarkView leaks into the project's processes.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        // The shell changes into the folder itself (posix_spawn's chdir action is not in every supported SDK); the folder
        // is an argument, never part of the script.
        let arguments = ["/bin/sh", "-c", "cd -- \"$1\" || exit 127\n" + command, "markview-ui-studio", folder.path]
        let environmentList = environment.map { "\($0.key)=\($0.value)" }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environmentList.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, &argv, &envp)
        close(fds[1])
        guard status == 0 else {
            close(fds[0])
            throw Failure.spawn(status)
        }
        lock.withLock { pid = child }

        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        handle = reader
        reader.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard let self else { return }
            if data.isEmpty {
                file.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock {
                self.buffer += text
                if self.buffer.utf8.count > 65_536 { self.buffer = String(self.buffer.suffix(48_000)) }
            }
            self.onOutput?(text)
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var code: Int32 = 0
            while waitpid(child, &code, 0) == -1 && errno == EINTR {}
            // The leader ended (npm, pnpm…): what it started may still run in the group. The group is still ours at this
            // moment, so it is ended now; later the group id could belong to someone else.
            Self.endGroup(child)
            guard let self else { return }
            let status = (code & 0x7f) == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f)
            let waiters: [CheckedContinuation<Void, Never>] = self.lock.withLock {
                self.exited = status
                let list = self.exitWaiters
                self.exitWaiters = []
                return list
            }
            waiters.forEach { $0.resume() }
            self.onExit?(status)
        }
    }

    /// Ends the server: SIGTERM to its group, SIGKILL to what is left after `grace` seconds.
    func stop(grace: TimeInterval = 3) async {
        let (leader, done) = lock.withLock { (pid, exited != nil) }
        guard leader > 0, !done else { return }
        killpg(leader, SIGTERM)
        let ended = await waitForExit(timeout: grace)
        if !ended { killpg(leader, SIGKILL) }
        _ = await waitForExit(timeout: 2)
    }

    /// Whether the leader ended within `timeout`.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        if lock.withLock({ exited != nil }) { return true }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                let list = exitWaiters
                exitWaiters = []
                return list
            }
            waiters.forEach { $0.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if exited != nil { return true }
                exitWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        timer.cancel()
        return lock.withLock { exited != nil }
    }

    private static let registry = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: StudioDevServer] = [:]

    /// Servers sessions started, so that quitting MarkView ends them too.
    static func track(_ server: StudioDevServer) {
        registry.withLock { running[ObjectIdentifier(server)] = server }
    }

    static func untrack(_ server: StudioDevServer) {
        registry.withLock { running[ObjectIdentifier(server)] = nil }
    }

    /// Ends every tracked server synchronously (MarkView is quitting): SIGTERM, then SIGKILL for what is left after 1.5 s.
    static func stopAllNow() {
        let servers = registry.withLock { () -> [StudioDevServer] in
            let list = Array(running.values)
            running = [:]
            return list
        }
        let groups = servers.compactMap { server -> pid_t? in
            let (leader, done) = server.lock.withLock { (server.pid, server.exited != nil) }
            return leader > 0 && !done ? leader : nil
        }
        guard !groups.isEmpty else { return }
        groups.forEach { killpg($0, SIGTERM) }
        for _ in 0..<15 {
            if groups.allSatisfy({ killpg($0, 0) != 0 }) { return }
            usleep(100_000)
        }
        groups.forEach { killpg($0, SIGKILL) }
    }

    private static func endGroup(_ group: pid_t) {
        guard killpg(group, 0) == 0 else { return }
        killpg(group, SIGTERM)
        for _ in 0..<20 {
            usleep(100_000)
            if killpg(group, 0) != 0 { return }
        }
        killpg(group, SIGKILL)
    }
}

/// The environment of the processes a session starts (§11): MarkView's own environment without production secrets, with
/// the `PATH` of the user's login shell (version managers such as nvm add to it there) and with browsers kept closed.
/// Whether the development server may run on the scenario's clock (DEC-006). The Node preload moves the clock only while
/// a request is handled, but a webpack dev server compiles from inside the page's request and its file watcher compares
/// file times with the clock: a test time in the past makes every recent file look changed, so it would rebuild without
/// end. Such a server keeps the real clock; its time zone and language still follow the scenario. Turbopack, Vite and
/// the other bundlers do not compare file times with the clock.
enum StudioServerClock {
    static let webpackNote = "This server builds with webpack, whose file watcher compares file times with the clock, so it keeps the "
        + "real clock; its time zone and language follow the scenario. A date it renders can differ from the page's."

    /// Why the server keeps the real clock, or nil when it follows the scenario's.
    static func realClockReason(command: String, folder: URL) -> String? {
        let package = (try? Data(contentsOf: folder.appendingPathComponent("package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let scripts = (package["scripts"] as? [String: Any]) ?? [:]
        let dependencies = ((package["dependencies"] as? [String: Any]) ?? [:])
            .merging((package["devDependencies"] as? [String: Any]) ?? [:]) { first, _ in first }
        // `npm run dev`, `pnpm dev`, `yarn run dev`, `bun run dev`: what runs is the script's text.
        let words = command.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        var text = command
        if let manager = words.first, ["npm", "pnpm", "yarn", "bun"].contains(manager), let name = words.last,
           let script = scripts[name] as? String {
            text = script
        }
        return usesWebpack(script: text, dependencies: dependencies) ? webpackNote : nil
    }

    static func usesWebpack(script: String, dependencies: [String: Any]) -> Bool {
        let script = " " + script + " "
        if script.contains("--webpack") || script.contains("webpack serve") || script.contains("webpack-dev-server")
            || script.contains("vue-cli-service serve") || script.contains("react-scripts start") || script.contains("gatsby develop") {
            return true
        }
        guard script.contains("next dev") || script.contains("next-dev") || script.contains(" next ") else { return false }
        if script.contains("--turbo") { return false }
        // Next.js 16 builds with Turbopack unless told otherwise; earlier versions, and a version that cannot be read
        // (a tag or a workspace reference), are taken to use webpack.
        let version = (dependencies["next"] as? String) ?? ""
        let major = version.range(of: #"\d+"#, options: .regularExpression).flatMap { Int(version[$0]) } ?? 0
        return major < 16
    }
}

enum StudioLaunchEnvironment {
    private static let cache = NSLock()
    nonisolated(unsafe) private static var cachedPath: String?

    /// Names a session may never set for the server: they decide which programs and files it uses.
    static let protectedNames: Set<String> = ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES",
                                              "DYLD_LIBRARY_PATH", "LD_PRELOAD"]

    /// `overrides` (simulated service addresses, test secrets, the scenario's time zone and language) are applied after the
    /// rest, and `nodePreload` is added to `NODE_OPTIONS` (REQ-007, DEC-006). The gateway's address never goes through a proxy.
    /// Env files do not override what is set here: `@next/env`, Vite's `loadEnv` and dotenv keep existing variables.
    static func make(base: [String: String] = ProcessInfo.processInfo.environment, overrides: [String: String] = [:],
                     nodePreload: String? = nil) async -> (environment: [String: String], removed: [String], overridden: [String]) {
        var (environment, removed) = StudioRedactor.sanitizedEnvironment(base)
        for name in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "NO_COLOR", "FORCE_COLOR", "TERM_PROGRAM", "ELECTRON_RUN_AS_NODE"] {
            environment[name] = nil
        }
        environment["PATH"] = await loginPath(fallback: environment["PATH"])
        environment["BROWSER"] = "none"
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["NODE_ENV"] = environment["NODE_ENV"] ?? "development"
        var overridden: [String] = []
        for (name, value) in overrides.sorted(by: { $0.key < $1.key })
        where StudioConnections.isValidName(name) && !protectedNames.contains(name) && !value.contains("\0") {
            environment[name] = value
            overridden.append(name)
        }
        if !overrides.isEmpty {
            for name in ["NO_PROXY", "no_proxy"] {
                let existing = (environment[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                environment[name] = (existing.filter { !$0.isEmpty } + ["127.0.0.1", "localhost"].filter { !existing.contains($0) })
                    .joined(separator: ",")
            }
        }
        if let nodePreload, !nodePreload.contains("\""), !nodePreload.contains("\0") {
            let existing = environment["NODE_OPTIONS"].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            environment["NODE_OPTIONS"] = (existing.isEmpty ? "" : existing + " ") + "--require \"\(nodePreload)\""
        }
        return (environment, removed, overridden)
    }

    /// `PATH` as the user's interactive login shell sets it; read once per launch of MarkView.
    static func loginPath(fallback: String?) async -> String {
        if let cached = cache.withLock({ cachedPath }) { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let output = await StudioProcess.run(shell, ["-l", "-i", "-c", #"printf '__MV_PATH__%s__MV_END__' "$PATH""#], timeout: 10)
        var path = ""
        if let start = output.stdout.range(of: "__MV_PATH__"), let end = output.stdout.range(of: "__MV_END__", range: start.upperBound..<output.stdout.endIndex) {
            path = String(output.stdout[start.upperBound..<end.lowerBound])
        }
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (path.isEmpty ? (fallback ?? "") : path).split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) { parts.append(extra) }
        let result = parts.joined(separator: ":")
        cache.withLock { cachedPath = result }
        return result
    }
}
