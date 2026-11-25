import Foundation
import Darwin
#if canImport(MarkViewCore)
import MarkViewCore
#endif

struct CockpitHostStep: Codable, Equatable, Sendable {
    var id: String; var title: String = ""; var agent: String; var assignment: String; var completionCondition: String = ""
    var prerequisite: Bool; var qaScenarioID: String? = nil; var recovery: CockpitStepRecovery? = nil
}
struct CockpitHostResult: Codable, Equatable, Sendable {
    var passed: Bool; var detail: String; var build: String; var scenarioID: String? = nil; var qaRunID: String? = nil
    var progress: CockpitProgress? = nil; var interrupted: Bool? = nil
    /// Specific input or decision needed from the person when `passed` is false.
    var neededInput: String? = nil
    /// Set to 1...N when this result came from an authorized bounded prerequisite recovery attempt.
    var recoveryAttempt: Int? = nil
    /// A managed run's step report (`CockpitManagedRun.absorb`): confirmed review findings, checks of findings, delegated work.
    var findings: [CockpitReportedFinding]? = nil
    var findingChecks: [CockpitFindingCheck]? = nil
    var delegates: [CockpitDelegatedWork]? = nil
}
struct CockpitHostEntry: Codable, Equatable, Sendable { var stepID: String; var result: CockpitHostResult; var planFingerprint: String? = nil }
struct CockpitHostTask: Codable, Equatable, Sendable {
    var step: CockpitHostStep
    var planFingerprint: String
    var goal: String
    var controls: String
    var successCriteria: [String]
    var priorResults: [CockpitHostEntry]
    var isFinalStep: Bool? = nil
    var recoveryAttempt: Int? = nil
}
struct CockpitHostReply: Codable, Sendable { var result: CockpitHostResult; var error: String }

/// The token a worker presents with its task (`PrivateSocket`, `AR-40`); read before the task is decoded.
private struct CockpitHostAuth: Decodable { let token: String? }

/// Private per-window IPC. A caller must be this user and present the token in `host.token` next to the socket;
/// closing a connection cancels its handler, so a dead worker cannot leave an agent running.
// unchecked Sendable: `lock` guards `stopped` and `clients`; every other stored property is a `let`.
final class CockpitHostBridge: @unchecked Sendable {
    enum Failure: Error { case socket }
    let path: String
    private let directory: String
    private let listener: PrivateSocket.Listener
    private let lock = NSLock()
    private var stopped = false
    private var clients: [Int32: Connection] = [:]
    private let handler: @Sendable (CockpitHostTask) async -> CockpitHostReply

    init(handler: @escaping @Sendable (CockpitHostTask) async -> CockpitHostReply) throws {
        self.handler = handler
        directory = "/tmp/mvc-" + UUID().uuidString.lowercased()
        guard mkdir(directory, 0o700) == 0 else { throw Failure.socket }
        path = directory + "/host.sock"
        do { listener = try PrivateSocket.open(at: path, backlog: 8) } catch { rmdir(directory); throw Failure.socket }
        let fd = listener.fd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                let connection = Connection(fd: client)
                guard self.add(connection) else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async { self.serve(connection) }
            }
        }
    }

    private func add(_ client: Connection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, clients.count < 8 else { return false }
        clients[client.fd] = client
        return true
    }

    private func serve(_ client: Connection) {
        var noSignal: Int32 = 1
        setsockopt(client.fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard PrivateSocket.peer(of: client.fd).isCurrentUser,
              let data = Self.readLine(client.fd),
              let auth = try? JSONDecoder().decode(CockpitHostAuth.self, from: data), listener.accepts(token: auth.token),
              let request = try? JSONDecoder().decode(CockpitHostTask.self, from: data) else {
            finish(client); return
        }
        let task = Task { [handler] in
            let reply = await handler(request)
            if !Task.isCancelled, let data = try? JSONEncoder().encode(reply) { client.write(data + Data([10])) }
            client.shutdown()
        }
        client.setTask(task)
        // The worker sends no more bytes. EOF or bridge shutdown interrupts a pending agent.
        var byte: UInt8 = 0
        while Darwin.read(client.fd, &byte, 1) < 0 && errno == EINTR {}
        client.cancel()
        finish(client)
    }

    private static func readLine(_ fd: Int32) -> Data? {
        let limit = 1_048_576
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // Read at most one byte past the limit so an unterminated request is rejected immediately.
            let n = Darwin.read(fd, &buffer, min(buffer.count, limit - data.count + 1))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            if let end = buffer[..<n].firstIndex(of: 10) {
                guard data.count + end <= limit else { return nil }
                data.append(contentsOf: buffer[..<end])
                return data
            }
            guard data.count + n <= limit else { return nil }
            data.append(contentsOf: buffer[..<n])
        }
    }

    private func finish(_ client: Connection) {
        lock.lock(); let owned = clients.removeValue(forKey: client.fd) != nil; lock.unlock()
        if owned { client.close() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let active = Array(clients.values)
        lock.unlock()
        listener.stop(); rmdir(directory)
        active.forEach { $0.cancel(); $0.shutdown() }
    }
    deinit { stop() }

    // unchecked Sendable: `lock` guards `closed` and `task`; `fd` is a `let`.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var closed = false
        private var task: Task<Void, Never>?
        init(fd: Int32) { self.fd = fd }
        func setTask(_ task: Task<Void, Never>) { lock.lock(); self.task = task; let done = closed; lock.unlock(); if done { task.cancel() } }
        func cancel() { lock.lock(); let task = self.task; lock.unlock(); task?.cancel() }
        func shutdown() { lock.lock(); if !closed { Darwin.shutdown(fd, SHUT_RDWR) }; lock.unlock() }
        func close() { lock.lock(); if !closed { closed = true; Darwin.close(fd) }; lock.unlock() }
        func write(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, MSG_DONTWAIT)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }
}
