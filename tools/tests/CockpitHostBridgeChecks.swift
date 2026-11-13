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
private func sendTask(_ fd: Int32) throws {
    let task = CockpitHostTask(step: CockpitHostStep(id: "one", agent: "Codex", assignment: "Inspect", prerequisite: false),
                               planFingerprint: "p1", goal: "Review", controls: "No deploy", successCriteria: ["Done"], priorResults: [])
    let data = try JSONEncoder().encode(task) + Data([10])
    let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard sent == data.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
private func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 3) == .success }
@main struct Checks {
    static func main() async throws {
        let bridge = try CockpitHostBridge { task in
            CockpitHostReply(result: CockpitHostResult(passed: task.controls == "No deploy", detail: task.step.id, build: "b1"), error: "")
        }
        let result = try await Task.detached { () throws -> CockpitHostReply in
            let fd = try connect(bridge.path); defer { Darwin.close(fd) }
            try sendTask(fd)
            var data = Data(), byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1 && byte != 10 { data.append(byte) }
            return try JSONDecoder().decode(CockpitHostReply.self, from: data)
        }.value
        guard result.result.passed && result.result.detail == "one" else { fatalError("wrong reply") }
        let mode = try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as? NSNumber
        guard mode?.intValue == 0o600 else { fatalError("socket is not private") }
        bridge.stop()
        guard !FileManager.default.fileExists(atPath: bridge.path) else { fatalError("socket remained after stop") }
        let started = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
        let pending = try CockpitHostBridge { _ in
            await withTaskCancellationHandler {
                started.signal()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "stopped")
            } onCancel: { cancelled.signal() }
        }
        let fd = try connect(pending.path)
        try sendTask(fd)
        guard await Task.detached(operation: { waitForSignal(started) }).value else { fatalError("handler did not start") }
        Darwin.close(fd)
        guard await Task.detached(operation: { waitForSignal(cancelled) }).value else { fatalError("disconnect did not cancel the handler") }
        pending.stop()
        print("Cockpit host bridge checks passed")
    }
}
