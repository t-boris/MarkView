import Foundation
import Darwin

/// A private, per-session socket joins the CLI's stdio MCP child to the home MarkView's encrypted
/// connection. The descriptor is closed on stop; neither pairing secrets nor provider credentials
/// appear in child arguments or MCP configuration.
final class RemoteToolBridge: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var clients: Set<Int32> = []
    private let handler: @Sendable (UUID, String, RemoteJSON) async -> RemoteJSON

    init(handler: @escaping @Sendable (UUID, String, RemoteJSON) async -> RemoteJSON) throws {
        self.handler = handler
        path = FileManager.default.temporaryDirectory.appendingPathComponent("mvr-" + UUID().uuidString.prefix(16) + ".sock").path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0, var address = RemoteUnixRPC.address(path) else { throw RemoteFailure.invalid("Could not create the workspace bridge.") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(listener); unlink(path); throw RemoteFailure.invalid("Could not start the workspace bridge: \(reason).")
        }
        let fd = listener
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard let self, self.add(client) else { close(client); return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
            }
        }
    }

    private func add(_ client: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, clients.count < 32 else { return false }
        clients.insert(client); return true
    }

    private func serve(_ client: Int32) {
        RemoteUnixRPC.configure(client)
        guard let data = RemoteUnixRPC.readLine(client), let request = try? JSONDecoder().decode(RemoteMessage.self, from: data),
              let name = request.payload["name"].string, RemoteWorkspaceTools.names.contains(name) else { finish(client); return }
        Task {
            let result = await handler(request.id, name, request.payload["arguments"])
            if let data = try? JSONEncoder().encode(result) { _ = RemoteUnixRPC.write(client, data + Data([10])) }
            finish(client)
        }
    }

    private func finish(_ client: Int32) {
        lock.lock(); let owned = clients.remove(client) != nil; lock.unlock()
        if owned { close(client) }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let clients = self.clients
        lock.unlock()
        shutdown(listener, SHUT_RDWR); close(listener); unlink(path)
        // A pending handler still owns its descriptor. Shutdown wakes readers without letting a
        // newly allocated descriptor reuse the number before that handler finishes.
        for fd in clients { shutdown(fd, SHUT_RDWR) }
    }
    deinit { stop() }
}

enum RemoteUnixRPC {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }
    static func configure(_ fd: Int32) {
        var noSignal: Int32 = 1, timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while data.count <= RemoteMessage.maxBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let end = buffer[..<count].firstIndex(of: 10) { data.append(contentsOf: buffer[..<end]); return data }
            data.append(contentsOf: buffer[..<count])
        }
        return nil
    }
    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
    static func call(socket path: String, id: UUID, name: String, arguments: RemoteJSON) -> RemoteJSON {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .textResult("Workspace bridge unavailable.", error: true) }
        defer { close(fd) }
        configure(fd)
        guard var address = address(path) else { return .textResult("Invalid bridge address.", error: true) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        let request = RemoteMessage("toolCall", .object(["name": .string(name), "arguments": arguments]), id: id)
        guard connected == 0, let data = try? JSONEncoder().encode(request), write(fd, data + Data([10])),
              let response = readLine(fd), let result = try? JSONDecoder().decode(RemoteJSON.self, from: response) else {
            return .textResult("The work computer did not answer. Reconnect in MarkView.", error: true)
        }
        return result
    }

    static func runMCP(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--socket"), i + 1 < arguments.count else { exit(64) }
        let path = arguments[i + 1]
        while let line = Swift.readLine() {
            guard line.utf8.count <= RemoteMessage.maxBytes,
                  let request = try? JSONDecoder().decode(RemoteJSON.self, from: Data(line.utf8)) else { continue }
            let result = RemoteWorkspaceTools.response(to: request) { call(socket: path, id: $0, name: $1, arguments: $2) }
            if let result, let data = try? JSONEncoder().encode(result) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
        exit(0)
    }

    /// Both CLIs use the same fail-closed guard. A model can never silently fall back to the home disk.
    static func runGuard() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = try? JSONDecoder().decode(RemoteJSON.self, from: data)
        let name = input?["tool_name"].string ?? ""
        let allowed = name.hasPrefix("mcp__work__") || ["AskUserQuestion", "TodoWrite", "update_plan", "request_user_input"].contains(name)
        let output: RemoteJSON = .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"), "permissionDecision": .string(allowed ? "allow" : "deny"),
            "permissionDecisionReason": .string(allowed ? "Work-computer tool." : "This native tool would act on the home computer. Use the work MCP workspace tools instead.")])])
        if let data = try? JSONEncoder().encode(output) { FileHandle.standardOutput.write(data + Data([10])) }
        exit(0)
    }
}
