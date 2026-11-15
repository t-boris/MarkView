import Foundation
import Darwin

private func connect(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (i, byte) in bytes.enumerated() { buffer[i] = byte }; buffer[bytes.count] = 0 }
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if result != 0 { Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return fd
}
/// A request as the Go worker sends it: the task's own fields with the host socket's token next to them.
private func sendTask(_ fd: Int32, token: String?) throws {
    let task = CockpitHostTask(step: CockpitHostStep(id: "one", agent: "Codex", assignment: "Inspect", prerequisite: false),
                               planFingerprint: "p1", goal: "Review", controls: "No deploy", successCriteria: ["Done"], priorResults: [])
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
    if let token { object["token"] = token }
    let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
    let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard sent == data.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
/// Whether the bridge closed the connection without a reply (it read nothing before EOF or a 3 s timeout).
private func closedWithoutReply(_ fd: Int32) -> Bool {
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var byte: UInt8 = 0
    return Darwin.read(fd, &byte, 1) == 0
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 3) == .success }
@main struct Checks {
    static func main() async throws {
        let handled = Counter()
        let bridge = try CockpitHostBridge { task in
            handled.increment()
            return CockpitHostReply(result: CockpitHostResult(passed: task.controls == "No deploy", detail: task.step.id, build: "b1"), error: "")
        }
        guard let token = PrivateSocket.readToken(forSocket: bridge.path), token.count == 64 else { fatalError("the host socket has no 256-bit token file") }
        let tokenMode = try FileManager.default.attributesOfItem(atPath: PrivateSocket.tokenPath(forSocket: bridge.path))[.posixPermissions] as? NSNumber
        guard tokenMode?.intValue == 0o600 else { fatalError("token file is not private") }
        // Without the token, or with another one, the worker's task never reaches the handler.
        for rejected in [nil, "wrong-token", String(token.reversed())] as [String?] {
            try await Task.detached {
                let fd = try connect(bridge.path); defer { Darwin.close(fd) }
                try sendTask(fd, token: rejected)
                guard closedWithoutReply(fd) else { fatalError("a request with token \(rejected ?? "none") was answered") }
            }.value
        }
        try await Task.detached {
            let fd = try connect(bridge.path); defer { Darwin.close(fd) }
            let unparsable = Data("not json\n".utf8)
            _ = unparsable.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            guard closedWithoutReply(fd) else { fatalError("an unparsable request was answered") }
        }.value
        guard handled.count == 0 else { fatalError("the handler ran for a request without the token") }
        let result = try await Task.detached { () throws -> CockpitHostReply in
            let fd = try connect(bridge.path); defer { Darwin.close(fd) }
            try sendTask(fd, token: token)
            var data = Data(), byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1 && byte != 10 { data.append(byte) }
            return try JSONDecoder().decode(CockpitHostReply.self, from: data)
        }.value
        guard result.result.passed && result.result.detail == "one" && handled.count == 1 else { fatalError("wrong reply") }
        let mode = try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as? NSNumber
        guard mode?.intValue == 0o600 else { fatalError("socket is not private") }
        try await Task.detached {
            let oversized = try connect(bridge.path); defer { Darwin.close(oversized) }
            var noSignal: Int32 = 1
            setsockopt(oversized, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let bytes = [UInt8](repeating: 65, count: 1_048_577)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(oversized, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                guard n > 0 else { break }
                offset += n
            }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(oversized, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            guard Darwin.read(oversized, &byte, 1) == 0 else { fatalError("oversized request was not closed without a newline") }
        }.value
        bridge.stop()
        guard !FileManager.default.fileExists(atPath: bridge.path) else { fatalError("socket remained after stop") }
        guard PrivateSocket.readToken(forSocket: bridge.path) == nil else { fatalError("token file remained after stop") }
        let started = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
        let pending = try CockpitHostBridge { _ in
            await withTaskCancellationHandler {
                started.signal()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "stopped")
            } onCancel: { cancelled.signal() }
        }
        let pendingToken = PrivateSocket.readToken(forSocket: pending.path)
        let fd = try connect(pending.path)
        try sendTask(fd, token: pendingToken)
        guard await Task.detached(operation: { waitForSignal(started) }).value else { fatalError("handler did not start") }
        Darwin.close(fd)
        guard await Task.detached(operation: { waitForSignal(cancelled) }).value else { fatalError("disconnect did not cancel the handler") }
        pending.stop()
        print("Cockpit host bridge checks passed")
    }
}
