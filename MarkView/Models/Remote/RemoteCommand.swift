import Foundation
import Darwin

/// A work-computer command, independent of the home CLI's PTY. Pipes are drained while the process
/// runs, output is bounded, and polling never blocks the main thread or waits for EOF before draining.
final class RemoteCommand: @unchecked Sendable {
    struct Snapshot { let output: String; let exitCode: Int32? }
    private let process = Process()
    private let output = Pipe()
    private let input = Pipe()
    private let inputQueue = DispatchQueue(label: "MarkView.remote.command-input")
    private let inputWriter: PTYWriter
    private let lock = NSLock()
    private var buffer = Data()
    private var code: Int32?
    private var reachedEOF = false
    private var processGroup: pid_t?
    private var dropped = false
    private var inputClosed = false
    private let maxOutput = 1024 * 1024

    init(command: String, directory: URL) throws {
        let inputFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        inputWriter = PTYWriter(fd: inputFD, queue: inputQueue)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = directory.path
        env["TERM"] = "dumb"
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env[key] = nil }
        process.environment = env
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.markEOF()
            }
            else { self?.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            AgentProcesses.remove(process)
            guard let self else { return }
            self.lock.lock(); self.code = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus; self.lock.unlock()
        }
        AgentProcesses.add(process, stop: { [weak self] in self?.stop() })
        do {
            try process.run()
            if getpgid(process.processIdentifier) == process.processIdentifier { processGroup = process.processIdentifier }
        }
        catch { AgentProcesses.remove(process); output.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > maxOutput { buffer.removeFirst(buffer.count - maxOutput); dropped = true }
    }
    private func markEOF() { lock.lock(); reachedEOF = true; lock.unlock() }

    func wait(milliseconds: Int) async {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while Date() < deadline && !Task.isCancelled {
            if exited { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private var exited: Bool { lock.lock(); defer { lock.unlock() }; return code != nil && reachedEOF }

    func takeOutput() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let text = (dropped ? "[Earlier command output omitted]\n" : "") + String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true); dropped = false
        return Snapshot(output: text, exitCode: reachedEOF ? code : nil)
    }

    func write(_ text: String) throws {
        lock.lock(); let closed = inputClosed; lock.unlock()
        guard !closed, process.isRunning else { throw RemoteFailure.invalid("Command input is closed.") }
        if text == "\u{3}" { stop(); return }
        guard text.utf8.count <= 65536 else { throw RemoteFailure.invalid("Command input exceeds 64 KB.") }
        let data = Data(text.utf8)
        inputQueue.async { [weak self] in self?.inputWriter.write(data) }
    }
    func closeInput() {
        lock.lock(); let alreadyClosed = inputClosed; inputClosed = true; lock.unlock()
        guard !alreadyClosed else { return }
        inputQueue.async { [weak self] in self?.finishInput(deadline: Date().addingTimeInterval(2)) }
    }
    /// EOF follows queued bytes. A child that never reads cannot hold the tool executor hostage.
    private func finishInput(deadline: Date) {
        if inputWriter.pendingCount == 0 || Date() >= deadline {
            inputWriter.cancel(); try? input.fileHandleForWriting.close()
        } else {
            inputQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.finishInput(deadline: deadline) }
        }
    }
    func stop() {
        closeInput()
        if let processGroup { _ = kill(-processGroup, SIGTERM) }
        let pid = process.processIdentifier
        if process.isRunning { process.terminate() }
        let group = processGroup, process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // A child may outlive its shell or ignore SIGTERM. Retain the process handle, not the
            // workspace, until the entire group has had its grace period.
            if let group { _ = kill(-group, SIGKILL) }
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }
    deinit {
        AgentProcesses.remove(process)
        if let processGroup { _ = kill(-processGroup, SIGTERM) }
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        let writer = inputWriter, handle = input.fileHandleForWriting
        inputQueue.async { writer.cancel(); try? handle.close() }
    }
}
