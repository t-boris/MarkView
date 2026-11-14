import Foundation
import Darwin

actor CockpitExitSignal {
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() { guard !done else { return }; done = true; let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
    func wait() async { if done { return }; await withCheckedContinuation { waiters.append($0) } }
}

/// A long-lived bundled helper. File handles are drained off the main thread; stdin is the app-lifetime lease.
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
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var decided = false
    private var stopped = false
    var isRunning: Bool { process.isRunning }

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
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        let pty = ptyDescriptor.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
        if let pty { process.standardError = pty } else { process.standardError = errors }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.read(data) }
        }
        // Drain diagnostics without storing them: helper messages must not enter app logs.
        if pty == nil { errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData } }
        process.terminationHandler = { [weak self] process in
            onExit()
            AgentProcesses.remove(process)
            self?.finish(.failure(Failure.exited))
            self?.output.fileHandleForReading.readabilityHandler = nil
            self?.errors.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try process.run()
            try? pty?.close()
            AgentProcesses.add(process, stop: { [weak self] in self?.stop() })
            if !process.isRunning { AgentProcesses.remove(process) }
        } catch {
            try? pty?.close()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            onExit()
            finish(.failure(Failure.launch))
            return
        }
        // Cancellation can arrive while Process.run is starting.
        lock.lock(); let shouldStop = stopped; lock.unlock()
        if shouldStop { stopInput() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(1, timeout)) { [weak self] in
            guard let self, self.finish(.failure(Failure.timeout)) else { return }
            self.stop()
        }
    }

    func waitForExit() async {
        while process.isRunning {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
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
        try? input.fileHandleForWriting.close()
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            guard process.isRunning else { return }
            process.terminate()
        }
    }

    deinit { stop() }
}
