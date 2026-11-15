import Foundation
import Darwin
#if canImport(MarkViewCore)
import MarkViewCore
#endif

actor CockpitExitSignal {
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() { guard !done else { return }; done = true; let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
    func wait() async { if done { return }; await withCheckedContinuation { waiters.append($0) } }
}

/// A long-lived bundled helper. File handles are drained off the main thread; stdin is the app-lifetime lease.
// unchecked Sendable: `lock` guards the process, the pending continuation, the buffered output and the flags.
final class CockpitChild: @unchecked Sendable {
    enum Failure: LocalizedError {
        case launch, exited, timeout, responseTooLarge
        var errorDescription: String? {
            switch self {
            case .launch: return "The local cockpit component could not start."
            case .exited: return "The local cockpit component exited before it became ready."
            case .timeout: return "The local cockpit component did not become ready in time."
            case .responseTooLarge: return "The local cockpit component returned an invalid response."
            }
        }
    }
    private let lock = NSLock()
    private var child: SubprocessChild?
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var decided = false
    private var stopped = false
    private var current: SubprocessChild? { lock.lock(); defer { lock.unlock() }; return child }
    var isRunning: Bool { current?.isRunning ?? false }

    static func launch(executable: URL, arguments: [String], timeout: TimeInterval = 120,
                       ptyDescriptor: Int32? = nil, onExit: @escaping @Sendable () -> Void = {}) async throws -> (CockpitChild, Data) {
        let child = CockpitChild()
        let ready = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { child.start(executable: executable, arguments: arguments, timeout: timeout, ptyDescriptor: ptyDescriptor, onExit: onExit, continuation: continuation) }
            }
        } onCancel: { child.stop() }
        return (child, ready)
    }

    private func start(executable: URL, arguments: [String], timeout: TimeInterval, ptyDescriptor: Int32?, onExit: @escaping @Sendable () -> Void, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if stopped { lock.unlock(); if let ptyDescriptor { close(ptyDescriptor) }; onExit(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        // Standard input is the app-lifetime lease (closed by `stop`). Diagnostics go to the terminal's PTY when there is one and
        // are dropped otherwise: helper messages must not enter app logs.
        let spec = SubprocessSpec(
            executable: executable.path, arguments: arguments, timeout: 0,
            stderrRouting: ptyDescriptor.map { .descriptor($0) } ?? .discard, keepsInputOpen: true)
        let started: SubprocessChild
        do {
            started = try Subprocess.start(spec, onStdout: { [weak self] data in self?.read(data) },
                                           onExit: { [weak self] child, _ in
                onExit()
                AgentProcesses.remove(child)
                self?.finish(.failure(Failure.exited))
            })
        } catch {
            if let ptyDescriptor { close(ptyDescriptor) }
            onExit()
            finish(.failure(Failure.launch))
            return
        }
        if let ptyDescriptor { close(ptyDescriptor) }
        lock.lock(); self.child = started; lock.unlock()
        AgentProcesses.add(started, stop: { [weak self] in self?.stop() })
        if !started.isRunning { AgentProcesses.remove(started) }
        // Cancellation can arrive while the child is starting.
        lock.lock(); let shouldStop = stopped; lock.unlock()
        if shouldStop { stopInput() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(1, timeout)) { [weak self] in
            guard let self, self.finish(.failure(Failure.timeout)) else { return }
            self.stop()
        }
    }

    func waitForExit() async {
        await current?.waitForExit()
    }

    private func read(_ data: Data) {
        lock.lock()
        guard !decided else { lock.unlock(); return }
        buffer.append(data)
        if buffer.count > 1_048_576 { lock.unlock(); _ = finish(.failure(Failure.responseTooLarge)); stop(); return }
        guard let end = buffer.firstIndex(of: 10) else { lock.unlock(); return }
        let line = Data(buffer[..<end])
        lock.unlock()
        _ = finish(.success(line))
    }

    @discardableResult private func finish(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard !decided, let continuation else { lock.unlock(); return false }
        decided = true
        self.continuation = nil
        buffer.removeAll()
        lock.unlock()
        continuation.resume(with: result)
        return true
    }

    /// Closing stdin asks the helper to stop; a slow shutdown is escalated in the background.
    func stop() {
        lock.lock(); let wasStopped = stopped; stopped = true; lock.unlock()
        guard !wasStopped else { return }
        _ = finish(.failure(CancellationError()))
        stopInput()
    }

    private func stopInput() {
        let child = current
        child?.closeInput()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            guard let child, child.isRunning else { return }
            child.terminate()
        }
    }

    deinit { stop() }
}
