import Foundation
import Darwin

struct CockpitHostStep: Codable, Sendable { var id: String; var agent: String; var assignment: String; var prerequisite: Bool }
struct CockpitHostResult: Codable, Sendable { var passed: Bool; var detail: String; var build: String }
struct CockpitHostEntry: Codable, Sendable { var stepID: String; var result: CockpitHostResult }
struct CockpitHostTask: Codable, Sendable {
    var step: CockpitHostStep
    var planFingerprint: String
    var goal: String
    var controls: String
    var successCriteria: [String]
    var priorResults: [CockpitHostEntry]
}
struct CockpitHostReply: Codable, Sendable { var result: CockpitHostResult; var error: String }

/// Private per-window IPC. Closing a connection cancels its handler, so a dead worker cannot leave an agent running.
final class CockpitHostBridge: @unchecked Sendable {
    enum Failure: Error { case socket }
    let path: String
    private let directory: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var clients: [Int32: Connection] = [:]
    private let handler: @Sendable (CockpitHostTask) async -> CockpitHostReply

    init(handler: @escaping @Sendable (CockpitHostTask) async -> CockpitHostReply) throws {
        self.handler = handler
        directory = "/tmp/mvc-" + UUID().uuidString.lowercased()
        guard mkdir(directory, 0o700) == 0 else { throw Failure.socket }
        path = directory + "/host.sock"
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { rmdir(directory); throw Failure.socket }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, b) in bytes.enumerated() { buffer[i] = b }
            buffer[bytes.count] = 0
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { rmdir(directory); throw Failure.socket }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            close(listener); unlink(path); rmdir(directory); throw Failure.socket
        }
        let fd = listener
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
        guard let data = Self.readLine(client.fd), let request = try? JSONDecoder().decode(CockpitHostTask.self, from: data) else {
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
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 1_048_576 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            if let end = buffer[..<n].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end])
                return data.count <= 1_048_576 ? data : nil
            }
            data.append(contentsOf: buffer[..<n])
        }
        return nil
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
        Darwin.shutdown(listener, SHUT_RDWR); close(listener); unlink(path); rmdir(directory)
        active.forEach { $0.cancel(); $0.shutdown() }
    }
    deinit { stop() }

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
