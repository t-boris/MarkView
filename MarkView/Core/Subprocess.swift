import Darwin
import Foundation

/// Specification for running an external child process (`AR-25`).
public struct SubprocessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: URL?
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

/// Unified subprocess runner with concurrent stdout/stderr draining, output caps,
/// SIGTERM -> SIGKILL escalation on timeout, and task cancellation (`AR-25`).
public enum Subprocess {
    public static let defaultSearchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// Resolves an executable name or path against explicit search paths.
    public static func resolveExecutable(_ nameOrPath: String, searchPaths: [String] = defaultSearchPaths) -> String? {
        let trimmed = nameOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fm = FileManager.default
        if trimmed.contains("/") {
            return fm.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(trimmed)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `spec` off the caller's actor, draining stdout/stderr concurrently to avoid pipe deadlocks.
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

    /// Synchronous helper strictly for non-async callers (`@available(*, noasync)` per `AR-25`).
    @available(*, noasync, message: "Use await Subprocess.run(_:) in async contexts (AR-25)")
    public static func runBlocking(_ spec: SubprocessSpec) -> SubprocessResult {
        executeSynchronously(spec, box: ProcessBox())
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func attach(_ proc: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            process = proc
            return true
        }

        func terminateWithEscalation() {
            let proc: Process? = {
                lock.lock()
                defer { lock.unlock() }
                cancelled = true
                return process
            }()
            guard let proc, proc.isRunning else { return }
            let pid = proc.processIdentifier
            proc.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning && pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private(set) var truncated = false
        private let maxBytes: Int

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

        func snapshot() -> (String, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (String(decoding: data, as: UTF8.self), truncated)
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
        if let env = spec.environment {
            process.environment = env
        }

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
        let drainGroup = DispatchGroup()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outCollector.append(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errCollector.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return SubprocessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false,
                truncated: false,
                durationMs: 0
            )
        }

        if let inputData = spec.stdin, let inPipe {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: inputData)
                try? inPipe.fileHandleForWriting.close()
                drainGroup.leave()
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
        _ = drainGroup.wait(timeout: .now() + 1.0)

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())

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
