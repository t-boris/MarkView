import Darwin
import Foundation

/// Specification for running an external child process (`AR-25`).
public struct SubprocessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: URL?
    /// Extra environment variables merged into the inherited process environment (and `settings.cli.extraPATH`).
    public var environment: [String: String]?
    public var stdin: Data?
    public var timeout: TimeInterval
    public var maxOutputBytes: Int

    public init(
        executable: String,
        arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 4 * 1024 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

/// Result of a completed or timed-out child process (`AR-25`).
public struct SubprocessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let truncated: Bool
    public let durationMs: Int

    public var succeeded: Bool { !timedOut && exitCode == 0 }

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        truncated: Bool = false,
        durationMs: Int = 0
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
        self.durationMs = durationMs
    }
}

/// Unified subprocess runner with concurrent stdout/stderr draining, bounded output caps,
/// merged environment + `settings.cli.extraPATH`, SIGTERM -> SIGKILL escalation, and cancellation (`AR-25`, `FU-04`).
public enum Subprocess {
    public static let extraPATHDefaultsKey = "settings.cli.extraPATH"

    public static let defaultSearchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// Reads configured extra PATH directories from UserDefaults (`settings.cli.extraPATH`).
    public static func configuredExtraPATHDirectories(defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.string(forKey: extraPATHDefaultsKey) else { return [] }
        return raw
            .split(whereSeparator: { $0 == ":" || $0 == "\n" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Combines explicit paths, `settings.cli.extraPATH`, inherited `PATH`, and `defaultSearchPaths` without duplicates.
    public static func effectiveSearchPaths(
        extra: [String] = configuredExtraPATHDirectories(),
        inheritedPATH: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            result.append(trimmed)
        }
        for p in extra { add(p) }
        if let inheritedPATH {
            for p in inheritedPATH.split(separator: ":") { add(String(p)) }
        }
        for p in defaultSearchPaths { add(p) }
        return result
    }

    /// Builds the child environment by merging `spec.environment` into inherited environment
    /// and including `settings.cli.extraPATH` in `PATH` (`FU-04`).
    public static func mergedEnvironment(
        overrides: [String: String]?,
        base: [String: String] = ProcessInfo.processInfo.environment,
        extraPATH: [String] = configuredExtraPATHDirectories()
    ) -> [String: String] {
        var env = base
        let basePATH = overrides?["PATH"] ?? base["PATH"]
        let combined = effectiveSearchPaths(extra: extraPATH, inheritedPATH: basePATH)
        if let overrides {
            for (key, value) in overrides {
                env[key] = value
            }
        }
        if !combined.isEmpty {
            env["PATH"] = combined.joined(separator: ":")
        }
        return env
    }

    /// Resolves an executable name or path against explicit search paths, `settings.cli.extraPATH`, inherited PATH, and default system paths.
    public static func resolveExecutable(_ nameOrPath: String, searchPaths: [String]? = nil) -> String? {
        let trimmed = nameOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fm = FileManager.default
        if trimmed.contains("/") {
            return fm.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        let paths = searchPaths ?? effectiveSearchPaths()
        for dir in paths {
            let candidate = (dir as NSString).appendingPathComponent(trimmed)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `spec` off the caller's actor, draining stdout/stderr concurrently with bounded output capture.
    public static func run(_ spec: SubprocessSpec) async -> SubprocessResult {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = executeSynchronously(spec, box: box)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            box.terminateWithEscalation()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var started = false
        private var cancelled = false

        func attach(_ proc: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            process = proc
            return true
        }

        func canLaunch() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !cancelled
        }

        func markStarted() {
            lock.lock()
            started = true
            let shouldTerminate = cancelled
            lock.unlock()
            if shouldTerminate {
                terminateWithEscalation()
            }
        }

        func terminateWithEscalation() {
            let target: (proc: Process, pid: pid_t)? = {
                lock.lock()
                defer { lock.unlock() }
                cancelled = true
                guard started, let proc = process, proc.isRunning else { return nil }
                return (proc, proc.processIdentifier)
            }()
            guard let (proc, pid) = target else { return }
            proc.terminate()
            if pid > 0, getpgid(pid) == pid {
                _ = kill(-pid, SIGTERM)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning && pid > 0 {
                    if getpgid(pid) == pid {
                        _ = kill(-pid, SIGKILL)
                    }
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var truncated = false
        let maxBytes: Int

        init(maxBytes: Int) {
            self.maxBytes = max(1024, maxBytes)
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = maxBytes - data.count
            if remaining <= 0 {
                truncated = true
                return
            }
            if chunk.count > remaining {
                data.append(chunk.prefix(remaining))
                truncated = true
            } else {
                data.append(chunk)
            }
        }

        var remainingCapacity: Int {
            lock.lock()
            defer { lock.unlock() }
            return max(0, maxBytes - data.count)
        }

        func snapshot() -> (String, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (String(decoding: data, as: UTF8.self), truncated)
        }
    }

    /// Reads any already-buffered bytes from a pipe handle without blocking if a descendant
    /// process inherited and kept the write end open (`FU-04`).
    private static func drainNonBlocking(handle: FileHandle, into collector: PipeCollector) {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let oldFlags = fcntl(fd, F_GETFL, 0)
        if oldFlags >= 0 {
            _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK)
        }
        defer {
            if oldFlags >= 0 {
                _ = fcntl(fd, F_SETFL, oldFlags)
            }
            try? handle.close()
        }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        var totalExtraRead = 0
        // Cap extra post-exit non-blocking read to avoid unbounded work if a child is actively flooding.
        let hardLimit = max(collector.maxBytes, 1024) + 16_384
        while totalExtraRead < hardLimit {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if n > 0 {
                totalExtraRead += n
                collector.append(Data(buffer[0..<n]))
                if collector.remainingCapacity == 0 {
                    // Drain up to a tiny bounded remainder to detect truncation, or stop if full.
                    break
                }
            } else {
                break
            }
        }
    }

    private static func executeSynchronously(_ spec: SubprocessSpec, box: ProcessBox) -> SubprocessResult {
        let start = DispatchTime.now()
        guard let resolvedPath = resolveExecutable(spec.executable) else {
            return SubprocessResult(
                exitCode: 127,
                stdout: "",
                stderr: "Executable not found: \(spec.executable)",
                timedOut: false,
                truncated: false,
                durationMs: 0
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = spec.arguments
        if let cwd = spec.cwd {
            process.currentDirectoryURL = cwd
        }
        process.environment = mergedEnvironment(overrides: spec.environment)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if spec.stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        guard box.attach(process) else {
            return SubprocessResult(exitCode: -1, stdout: "", stderr: "Cancelled", timedOut: false, truncated: false, durationMs: 0)
        }

        let outCollector = PipeCollector(maxBytes: spec.maxOutputBytes)
        let errCollector = PipeCollector(maxBytes: spec.maxOutputBytes)
        let eofGroup = DispatchGroup()

        let outFinishLock = NSLock()
        var outFinished = false
        let errFinishLock = NSLock()
        var errFinished = false

        eofGroup.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outFinishLock.lock()
                let shouldLeave = !outFinished
                outFinished = true
                outFinishLock.unlock()
                if shouldLeave { eofGroup.leave() }
            } else {
                outCollector.append(chunk)
            }
        }

        eofGroup.enter()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errFinishLock.lock()
                let shouldLeave = !errFinished
                errFinished = true
                errFinishLock.unlock()
                if shouldLeave { eofGroup.leave() }
            } else {
                errCollector.append(chunk)
            }
        }

        guard box.canLaunch() else {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return SubprocessResult(exitCode: -1, stdout: "", stderr: "Cancelled", timedOut: false, truncated: false, durationMs: 0)
        }

        let stdinGroup = DispatchGroup()
        do {
            try process.run()
            box.markStarted()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            outFinishLock.lock()
            if !outFinished { outFinished = true; eofGroup.leave() }
            outFinishLock.unlock()
            errFinishLock.lock()
            if !errFinished { errFinished = true; eofGroup.leave() }
            errFinishLock.unlock()
            return SubprocessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false,
                truncated: false,
                durationMs: 0
            )
        }

        // Close our copies of the write ends so EOF reflects only the child process.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        if let inputData = spec.stdin, let inPipe {
            stdinGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: inputData)
                try? inPipe.fileHandleForWriting.close()
                stdinGroup.leave()
            }
        }

        let stateLock = NSLock()
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        if spec.timeout > 0 {
            timer.schedule(deadline: .now() + spec.timeout)
            timer.setEventHandler {
                stateLock.lock()
                timedOut = true
                stateLock.unlock()
                box.terminateWithEscalation()
            }
            timer.resume()
        }

        process.waitUntilExit()
        if spec.timeout > 0 {
            timer.cancel()
        }
        _ = stdinGroup.wait(timeout: .now() + 1.0)
        // Wait briefly for readabilityHandlers to finish flushing buffered output after exit,
        // without blocking indefinitely if a background grandchild kept stdout/stderr open (`FU-04`).
        _ = eofGroup.wait(timeout: .now() + 0.15)

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        drainNonBlocking(handle: outPipe.fileHandleForReading, into: outCollector)
        drainNonBlocking(handle: errPipe.fileHandleForReading, into: errCollector)

        let (stdout, outTrunc) = outCollector.snapshot()
        let (stderr, errTrunc) = errCollector.snapshot()
        let wasTimedOut: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            return timedOut
        }()
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return SubprocessResult(
            exitCode: wasTimedOut ? -1 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: wasTimedOut,
            truncated: outTrunc || errTrunc,
            durationMs: Int(elapsedNs / 1_000_000)
        )
    }
}
