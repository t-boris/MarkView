import Darwin
import Foundation

/// Where one of a child's output streams goes (`AR-25`).
public enum SubprocessRouting: Sendable, Equatable {
    /// A pipe the parent reads: collected by `Subprocess.run`, delivered in chunks by `Subprocess.start`.
    case capture
    /// `/dev/null`.
    case discard
    /// The child writes straight into this descriptor. The caller keeps ownership and closes its copy after the start.
    case descriptor(Int32)
    /// Standard error only: the same stream as standard output, interleaved as the child writes.
    case mergedWithStdout
}

/// How a child ended (`AR-25`).
public struct SubprocessExit: Sendable, Equatable {
    /// The exit code, or the signal number when a signal ended the child (what `Process.terminationStatus` reports).
    public let status: Int32
    /// A signal ended the child (`Process.terminationReason == .uncaughtSignal`).
    public let signaled: Bool
    /// `spec.timeout` ran out and the child was terminated for it.
    public let timedOut: Bool
    public let durationMs: Int

    public init(status: Int32, signaled: Bool, timedOut: Bool = false, durationMs: Int = 0) {
        self.status = status
        self.signaled = signaled
        self.timedOut = timedOut
        self.durationMs = durationMs
    }
}

/// The child could not be started.
public struct SubprocessLaunchError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    static func system(_ code: Int32, while action: String) -> SubprocessLaunchError {
        SubprocessLaunchError("\(action): \(String(cString: strerror(code)))")
    }
}

/// A running child process that leads its own process group (`AR-25`, `FU-22`).
///
/// `Subprocess.start` creates it with `posix_spawn`, so the child is the leader of a group of its own and a timeout,
/// cancellation or `terminate()` reaches its descendants too. The group is never the app's: a group is signalled only
/// when its id is the child's pid, and never the group of this process. Output is read on `queue` (one serial queue per
/// child unless the caller passes one), so the callbacks arrive in order: all output first, then the exit. An exit is
/// reported when the leader has ended and what it wrote is read; a descendant that still holds a pipe open does not
/// delay it. A child is retained until it has ended: dropping the handle neither stops nor loses it.
public final class SubprocessChild: @unchecked Sendable {
    public let pid: pid_t

    private let queue: DispatchQueue
    private let grace: TimeInterval
    private let timeout: TimeInterval
    private let startedAt = DispatchTime.now()

    private let lock = NSLock()
    private var inputFD: Int32?
    private var reaped = false
    private var groupGone = false
    private var terminationRequested = false
    private var timedOut = false
    private var exitResult: SubprocessExit?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    // Touched only on `queue`.
    private var readers: [PipeReader] = []
    private var processSource: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var onExit: (@Sendable (SubprocessChild, SubprocessExit) -> Void)?

    fileprivate init(pid: pid_t, input: Int32?, queue: DispatchQueue, grace: TimeInterval, timeout: TimeInterval) {
        self.pid = pid
        self.inputFD = input
        self.queue = queue
        self.grace = grace
        self.timeout = timeout
    }

    deinit {
        if let inputFD { close(inputFD) }
    }

    /// The leader has not ended yet.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !reaped
    }

    /// How the child ended; nil while it runs.
    public var exit: SubprocessExit? {
        lock.lock(); defer { lock.unlock() }
        return exitResult
    }

    // MARK: Input

    /// The write end of the child's standard input, nil unless the spec asked for an input pipe or it is closed. The
    /// descriptor stays owned by the child: use it for non-blocking writers, never close it (use `closeInput()`).
    public var inputFileDescriptor: Int32? {
        lock.lock(); defer { lock.unlock() }
        return inputFD
    }

    /// Writes all of `data` to the child's input (blocking; a child that ended gives an error, never a signal).
    public func writeInput(_ data: Data) throws {
        guard let fd = inputFileDescriptor else { throw SubprocessLaunchError("The input of the process is closed.") }
        try Subprocess.writeAll(data, to: fd)
    }

    /// Closes the child's input (EOF for the child). Safe to call again.
    public func closeInput() {
        lock.lock()
        let fd = inputFD
        inputFD = nil
        lock.unlock()
        if let fd { close(fd) }
    }

    // MARK: Ending the child

    /// Asks the child's whole group to stop (SIGTERM), then kills what is still alive after `grace` seconds
    /// (the spec's `terminationGrace` unless given). Safe to call again and after the child ended.
    public func terminate(grace overrideGrace: TimeInterval? = nil) {
        lock.lock()
        let first = !terminationRequested
        terminationRequested = true
        lock.unlock()
        signalGroup(SIGTERM)
        guard first else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (overrideGrace ?? grace)) { [self] in
            signalGroup(SIGKILL)
        }
    }

    /// SIGKILL to the child's whole group, at once.
    public func kill() {
        signalGroup(SIGKILL)
    }

    /// Returns when the leader has ended and its output was delivered (the exit callback has run).
    public func waitForExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exitResult != nil {
                lock.unlock()
                continuation.resume()
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// The group id to signal for a child with `pid`, nil when it must not be signalled: `pid` is not a real child
    /// process id, or it is the group of this process.
    static func signalTarget(forGroupOf pid: pid_t, ownGroup: pid_t = getpgrp()) -> pid_t? {
        guard pid > 1, pid != ownGroup else { return nil }
        return -pid
    }

    private func signalGroup(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // The leader, directly: it may have left its group (`setsid`, `setpgid`). Its pid cannot be reused before it is reaped.
        if !reaped { _ = Darwin.kill(pid, signal) }
        // The group: the leader's descendants. A group id is never reused while a member lives; once the group
        // is empty it is not signalled again.
        guard !groupGone, let target = Self.signalTarget(forGroupOf: pid) else { return }
        if Darwin.kill(target, signal) != 0, errno == ESRCH { groupGone = true }
    }

    // MARK: Wiring (called once, by `Subprocess.start`)

    fileprivate func attach(output: Int32?, error: Int32?,
                            onStdout: (@Sendable (Data) -> Void)?, onStderr: (@Sendable (Data) -> Void)?,
                            onExit: @escaping @Sendable (SubprocessChild, SubprocessExit) -> Void) {
        queue.async { [self] in
            self.onExit = onExit
            if let output { readers.append(PipeReader(fd: output, queue: queue) { data in onStdout?(data) }) }
            if let error { readers.append(PipeReader(fd: error, queue: queue) { data in onStderr?(data) }) }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [self] in handleExit() }
            processSource = source
            source.resume()
            if timeout > 0 {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [self] in
                    lock.lock()
                    timedOut = true
                    lock.unlock()
                    terminate()
                }
                self.timer = timer
                timer.resume()
            }
        }
    }

    /// Runs on `queue` when the leader has ended.
    private func handleExit() {
        var raw: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &raw, 0) } while result == -1 && errno == EINTR
        let signal = raw & 0x7f
        let signaled = result == pid && signal != 0
        let status: Int32 = result != pid ? -1 : (signaled ? signal : (raw >> 8) & 0xff)
        lock.lock()
        reaped = true
        // From here the pid is only a group id: with no member left, nothing is signalled any more.
        if Darwin.kill(-pid, 0) != 0 { groupGone = true }
        let didTimeOut = timedOut
        lock.unlock()

        // What the leader wrote is in the pipes already; a descendant that holds them open is not waited for.
        for reader in readers {
            reader.pump(maxReads: 256)
            reader.finish()
        }
        readers = []
        timer?.cancel()
        timer = nil
        processSource?.cancel()
        processSource = nil

        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        let exit = SubprocessExit(status: status, signaled: signaled, timedOut: didTimeOut, durationMs: Int(elapsed / 1_000_000))
        lock.lock()
        exitResult = exit
        lock.unlock()
        let callback = onExit
        onExit = nil
        callback?(self, exit)
        lock.lock()
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

/// Reads one pipe on `queue` until end of file.
private final class PipeReader {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private let deliver: (Data) -> Void
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private(set) var finished = false

    init(fd: Int32, queue: DispatchQueue, deliver: @escaping (Data) -> Void) {
        self.fd = fd
        self.deliver = deliver
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in pump(maxReads: 16) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Delivers what is buffered in the pipe. Stops when the pipe would block, at end of file, or after `maxReads` reads.
    func pump(maxReads: Int) {
        guard !finished else { return }
        for _ in 0..<maxReads {
            let count = buffer.withUnsafeMutableBytes { raw in
                raw.baseAddress.map { Darwin.read(fd, $0, raw.count) } ?? -1
            }
            if count > 0 {
                deliver(Data(buffer[0..<count]))
            } else if count == 0 {
                finish()
                return
            } else if errno == EINTR {
                continue
            } else {
                if errno != EAGAIN { finish() }
                return
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        source?.cancel()
        source = nil
    }
}

extension Subprocess {
    /// Starts `spec` and returns at once (`AR-25`). Output arrives in the callbacks on `queue`; `onExit` follows the last
    /// output. The child leads a process group of its own (see `SubprocessChild`), gets `/dev/null` for any stream not
    /// routed elsewhere, restored signal dispositions, and no descriptor of this process besides its three standard
    /// streams. `spec.timeout` (seconds, `<= 0` for none) ends it with `SubprocessChild.terminate()`; `spec.maxOutputBytes`
    /// does not apply, the callbacks see everything.
    public static func start(
        _ spec: SubprocessSpec,
        queue: DispatchQueue? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil,
        onExit: @escaping @Sendable (SubprocessChild, SubprocessExit) -> Void
    ) throws -> SubprocessChild {
        guard let path = resolveExecutable(spec.executable) else {
            throw SubprocessLaunchError("Executable not found: \(spec.executable)")
        }
        let spawned = try spawn(path: path, spec: spec)
        let child = SubprocessChild(
            pid: spawned.pid,
            input: spawned.input,
            queue: queue ?? DispatchQueue(label: "markview.subprocess.\(spawned.pid)", qos: .userInitiated),
            grace: spec.terminationGrace,
            timeout: spec.timeout
        )
        child.attach(output: spawned.output, error: spawned.error, onStdout: onStdout, onStderr: onStderr, onExit: onExit)
        if let data = spec.stdin {
            DispatchQueue.global(qos: .utility).async {
                try? child.writeInput(data)
                child.closeInput()
            }
        }
        return child
    }

    private struct Spawned {
        var pid: pid_t
        var input: Int32?
        var output: Int32?
        var error: Int32?
    }

    /// Both ends of a pipe, above the standard descriptors and close-on-exec, so that no other child inherits them.
    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SubprocessLaunchError.system(errno, while: "Could not create a pipe") }
        let read = fcntl(fds[0], F_DUPFD_CLOEXEC, 3)
        let write = read < 0 ? -1 : fcntl(fds[1], F_DUPFD_CLOEXEC, 3)
        let code = errno
        close(fds[0])
        close(fds[1])
        guard read >= 0, write >= 0 else {
            if read >= 0 { close(read) }
            throw SubprocessLaunchError.system(code, while: "Could not create a pipe")
        }
        return (read, write)
    }

    private static func spawn(path: String, spec: SubprocessSpec) throws -> Spawned {
        var parentEnds: [Int32] = []   // closed again if the start fails
        var childEnds: [Int32] = []    // closed in this process once the child has its copies
        func abandon(_ error: SubprocessLaunchError) -> SubprocessLaunchError {
            (parentEnds + childEnds).forEach { close($0) }
            return error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // A group of its own (`FU-22`), no inherited descriptors, and the default signal handling of a fresh process:
        // an ignored SIGPIPE of the app must not reach a shell pipeline.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        if let cwd = spec.cwd {
            let code = posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
            guard code == 0 else { throw abandon(.system(code, while: "Could not use the working folder")) }
        }

        do {
            // Standard input.
            var input: Int32?
            if spec.stdin != nil || spec.keepsInputOpen {
                let ends = try makePipe()
                childEnds.append(ends.read)
                parentEnds.append(ends.write)
                _ = fcntl(ends.write, F_SETNOSIGPIPE, 1)
                posix_spawn_file_actions_adddup2(&actions, ends.read, 0)
                input = ends.write
            } else {
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            }

            // Standard output.
            var output: Int32?
            var stdoutSource: Int32?   // the descriptor that becomes the child's standard output, for `.mergedWithStdout`
            switch spec.stdoutRouting {
            case .capture:
                let ends = try makePipe()
                childEnds.append(ends.write)
                parentEnds.append(ends.read)
                posix_spawn_file_actions_adddup2(&actions, ends.write, 1)
                output = ends.read
                stdoutSource = ends.write
            case .discard:
                posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            case .descriptor(let fd):
                posix_spawn_file_actions_adddup2(&actions, fd, 1)
                stdoutSource = fd
            case .mergedWithStdout:
                throw SubprocessLaunchError("Standard output cannot be merged into itself.")
            }

            // Standard error.
            var error: Int32?
            switch spec.stderrRouting {
            case .capture:
                let ends = try makePipe()
                childEnds.append(ends.write)
                parentEnds.append(ends.read)
                posix_spawn_file_actions_adddup2(&actions, ends.write, 2)
                error = ends.read
            case .discard:
                posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            case .descriptor(let fd):
                posix_spawn_file_actions_adddup2(&actions, fd, 2)
            case .mergedWithStdout:
                if let stdoutSource {
                    posix_spawn_file_actions_adddup2(&actions, stdoutSource, 2)
                } else {
                    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
                }
            }

            var argv: [UnsafeMutablePointer<CChar>?] = ([path] + spec.arguments).map { strdup($0) } + [nil]
            var environment = mergedEnvironment(overrides: spec.environment)
            for key in spec.removedEnvironment { environment[key] = nil }
            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            let code = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
            guard code == 0 else { throw SubprocessLaunchError.system(code, while: "Could not start \(spec.executable)") }
            childEnds.forEach { close($0) }
            return Spawned(pid: pid, input: input, output: output, error: error)
        } catch let failure as SubprocessLaunchError {
            throw abandon(failure)
        }
    }

    /// Writes all of `data` to `fd`, retrying interrupted and would-block writes.
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR || errno == EAGAIN {
                    if errno == EAGAIN { usleep(1_000) }
                } else {
                    throw SubprocessLaunchError.system(errno, while: "Could not write to the process")
                }
            }
        }
    }
}
