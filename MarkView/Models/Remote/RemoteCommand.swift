import Foundation
import Darwin
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// A work-computer command, independent of the home CLI's PTY. Pipes are drained while the process
/// runs, output is bounded, and polling never blocks the main thread or waits for EOF before draining.
// unchecked Sendable: `lock` guards the process state and output; `RemoteCommandInput` owns serial input access.
final class RemoteCommand: @unchecked Sendable {
    struct Snapshot { let output: String; let exitCode: Int32? }
    private let lock = NSLock()
    private var child: SubprocessChild?
    private var input: RemoteCommandInput?
    private var buffer = Data()
    private var code: Int32?
    private var dropped = false
    private var inputClosed = false
    private let maxOutput = 1024 * 1024

    init(command: String, directory: URL) throws {
        let environment = ["PWD": directory.path, "TERM": "dumb"]
        // The agent that started MarkView must not leak its own markers into the command.
        let inherited = ProcessInfo.processInfo.environment.keys.filter { $0 == "CLAUDECODE" || $0.hasPrefix("CLAUDE_CODE_") }
        let spec = SubprocessSpec(
            executable: "/bin/zsh", arguments: ["-l", "-c", command], cwd: directory, environment: environment,
            removedEnvironment: Set(inherited), timeout: 0, stderrRouting: .mergedWithStdout, keepsInputOpen: true, terminationGrace: 2)
        // Output arrives in chunks while the command runs, and the exit follows the last chunk: polling never waits for EOF,
        // so a background process that keeps the pipe open does not hold the command's answer back.
        let started = try Subprocess.start(spec, onStdout: { [weak self] data in
            self?.append(data)
        }, onExit: { [weak self] child, exit in
            AgentProcesses.remove(child)
            guard let self else { return }
            self.lock.lock(); self.code = exit.signaled ? 128 + exit.status : exit.status; self.lock.unlock()
        })
        child = started
        if let inputFD = started.inputFileDescriptor {
            _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
            input = RemoteCommandInput(fd: inputFD, child: started)
        }
        AgentProcesses.add(started, stop: { [weak self] in self?.stop() })
        if !started.isRunning { AgentProcesses.remove(started) }
    }

    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > maxOutput { buffer.removeFirst(buffer.count - maxOutput); dropped = true }
    }

    func wait(milliseconds: Int) async {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while Date() < deadline && !Task.isCancelled {
            if exited { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private var exited: Bool { lock.lock(); defer { lock.unlock() }; return code != nil }

    func takeOutput() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let text = (dropped ? "[Earlier command output omitted]\n" : "") + String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true); dropped = false
        return Snapshot(output: text, exitCode: code)
    }

    func write(_ text: String) throws {
        lock.lock(); let closed = inputClosed; lock.unlock()
        guard !closed, child?.isRunning == true else { throw RemoteFailure.invalid("Command input is closed.") }
        if text == "\u{3}" { stop(); return }
        guard text.utf8.count <= 65536 else { throw RemoteFailure.invalid("Command input exceeds 64 KB.") }
        input?.write(Data(text.utf8))
    }
    func closeInput() {
        lock.lock(); let alreadyClosed = inputClosed; inputClosed = true; lock.unlock()
        guard !alreadyClosed else { return }
        input?.close()
    }
    /// SIGTERM to the command's whole group (its own, never the app's), SIGKILL two seconds later for what ignores it.
    func stop() {
        closeInput()
        child?.terminate()
    }
    deinit {
        if let child { AgentProcesses.remove(child); child.terminate() }
        input?.cancel()
    }
}

/// All writer access is confined to its queue, including cancellation after the command is released.
// unchecked Sendable: `writer` is accessed only on `queue` after initialization; `child` is Sendable.
private final class RemoteCommandInput: @unchecked Sendable {
    private let queue: DispatchQueue
    private let child: SubprocessChild
    private let writer: PTYWriter

    init(fd: Int32, child: SubprocessChild) {
        let queue = DispatchQueue(label: "MarkView.remote.command-input")
        self.queue = queue
        self.child = child
        self.writer = PTYWriter(fd: fd, queue: queue)
    }

    func write(_ data: Data) {
        queue.async { [self] in writer.write(data) }
    }

    func close() {
        queue.async { [self] in finish(deadline: Date().addingTimeInterval(2)) }
    }

    /// EOF follows queued bytes; the deadline bounds a child that never reads.
    private func finish(deadline: Date) {
        if writer.pendingCount == 0 || Date() >= deadline {
            writer.cancel()
            child.closeInput()
        } else {
            // task: the queue-owned drain loop ends when the deadline expires or pending input is sent.
            queue.asyncAfter(deadline: .now() + 0.02) { [self] in finish(deadline: deadline) }
        }
    }

    func cancel() {
        queue.async { [self] in
            writer.cancel()
            child.closeInput()
        }
    }
}
