import Darwin
import Foundation

/// Specification for running an external child process (`AR-25`).
public struct SubprocessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: URL?
    /// Extra environment variables merged into the inherited process environment (and `settings.cli.extraPATH`).
    public var environment: [String: String]?
    /// Written to the child's standard input, which is then closed. nil leaves the child `/dev/null`.
    public var stdin: Data?
    /// Seconds before the child's group is terminated; `<= 0` means no limit.
    public var timeout: TimeInterval
    /// Cap on what `run` keeps of each captured stream (the rest is read and dropped).
    public var maxOutputBytes: Int
    /// Where standard output and standard error go (`.capture`: read by the parent).
    public var stdoutRouting: SubprocessRouting
    public var stderrRouting: SubprocessRouting
    /// Gives the child an input pipe that stays open for `SubprocessChild.writeInput` (`Subprocess.start` only).
    public var keepsInputOpen: Bool
    /// Seconds between SIGTERM and SIGKILL when the child's group is terminated.
    public var terminationGrace: TimeInterval
    /// `run` ends the child as soon as a captured stream passes `maxOutputBytes` (`SubprocessResult.truncated`).
    public var terminateOnOverflow: Bool

    public init(
        executable: String,
        arguments: [String] = [],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        stdoutRouting: SubprocessRouting = .capture,
        stderrRouting: SubprocessRouting = .capture,
        keepsInputOpen: Bool = false,
        terminationGrace: TimeInterval = 0.5,
        terminateOnOverflow: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.stdoutRouting = stdoutRouting
        self.stderrRouting = stderrRouting
        self.keepsInputOpen = keepsInputOpen
        self.terminationGrace = terminationGrace
        self.terminateOnOverflow = terminateOnOverflow
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

/// The one way the app runs a child process (`AR-25`): `run` for a command that ends, `runBlocking` for code that owns
/// a background thread, `start` for a child that lives on. All of them share the spawn: a process group of its own so
/// that a timeout or cancellation reaches the grandchildren (`FU-22`), concurrent draining of the pipes with bounded
/// capture (`FU-04`), the merged environment with `settings.cli.extraPATH`, and SIGTERM then SIGKILL.
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

    /// Runs `spec` off the caller's actor and returns when the child has ended: pipes are drained concurrently with
    /// bounded capture, the child leads a process group of its own, and a timeout or the cancellation of the calling
    /// task ends the whole group (SIGTERM, then SIGKILL after `spec.terminationGrace`).
    public static func run(_ spec: SubprocessSpec) async -> SubprocessResult {
        let control = OneShotControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                launchOneShot(spec, control: control) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            control.cancel()
        }
    }

    /// `run` for code that already owns a background thread (a synchronous scanner, a detached task): it blocks the
    /// calling thread until the child has ended. Never call it from the main thread of the app; use `run` there.
    public static func runBlocking(_ spec: SubprocessSpec) -> SubprocessResult {
        let control = OneShotControl()
        let finished = DispatchSemaphore(value: 0)
        let box = ResultBox()
        launchOneShot(spec, control: control) {
            box.result = $0
            finished.signal()
        }
        finished.wait()
        return box.result
    }

    private static func launchOneShot(_ spec: SubprocessSpec, control: OneShotControl,
                                      completion: @escaping @Sendable (SubprocessResult) -> Void) {
        func failed(_ message: String, exitCode: Int32 = -1) -> SubprocessResult {
            SubprocessResult(exitCode: exitCode, stdout: "", stderr: message)
        }
        guard control.canLaunch() else { return completion(failed("Cancelled")) }
        guard resolveExecutable(spec.executable) != nil else {
            return completion(failed("Executable not found: \(spec.executable)", exitCode: 127))
        }

        let output = PipeCollector(maxBytes: spec.maxOutputBytes)
        let errors = PipeCollector(maxBytes: spec.maxOutputBytes)
        let terminateOnOverflow = spec.terminateOnOverflow
        let child: SubprocessChild
        do {
            child = try start(spec, onStdout: { data in
                output.append(data)
                if terminateOnOverflow, output.truncated { control.terminate() }
            }, onStderr: { data in
                errors.append(data)
                if terminateOnOverflow, errors.truncated { control.terminate() }
            }, onExit: { _, exit in
                let (stdout, outTruncated) = output.snapshot()
                let (stderr, errTruncated) = errors.snapshot()
                completion(SubprocessResult(
                    exitCode: exit.timedOut ? -1 : exit.status,
                    stdout: stdout,
                    stderr: stderr,
                    timedOut: exit.timedOut,
                    truncated: outTruncated || errTruncated,
                    durationMs: exit.durationMs
                ))
            })
        } catch {
            return completion(failed(error.localizedDescription))
        }
        control.attach(child)
    }

    private final class ResultBox: @unchecked Sendable {
        var result = SubprocessResult(exitCode: -1, stdout: "", stderr: "")
    }

    /// Lets the cancellation of a task and the output cap reach a child that is being started.
    private final class OneShotControl: @unchecked Sendable {
        private let lock = NSLock()
        private var child: SubprocessChild?
        private var cancelled = false

        func canLaunch() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !cancelled
        }

        /// Called once the child exists; a cancellation that came first ends it now.
        func attach(_ child: SubprocessChild) {
            lock.lock()
            self.child = child
            let stop = cancelled
            lock.unlock()
            if stop { child.terminate() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let target = child
            lock.unlock()
            target?.terminate()
        }

        func terminate() {
            lock.lock()
            let target = child
            lock.unlock()
            target?.terminate()
        }
    }

    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var cut = false
        private let maxBytes: Int

        init(maxBytes: Int) {
            self.maxBytes = max(1024, maxBytes)
        }

        var truncated: Bool {
            lock.lock(); defer { lock.unlock() }
            return cut
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = maxBytes - data.count
            if remaining <= 0 {
                cut = true
            } else if chunk.count > remaining {
                data.append(chunk.prefix(remaining))
                cut = true
            } else {
                data.append(chunk)
            }
        }

        func snapshot() -> (String, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: data, as: UTF8.self), cut)
        }
    }
}
