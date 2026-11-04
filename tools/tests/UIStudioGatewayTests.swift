// Runs UI Studio's loopback gateway against real clients: URLSession (ephemeral, no proxy) and raw BSD sockets.
// Run by tools/tests/ui-studio-gateway-tests.sh. The credentials below are test values, never real ones.
import Darwin
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("ok  \(name)") } else {
        failures += 1
        let more = detail()
        print("FAIL \(name)" + (more.isEmpty ? "" : "\n     \(more)"))
    }
}

signal(SIGPIPE, SIG_IGN)

// MARK: - Raw sockets

/// A connected TCP socket to `address:port`, or nil when the connection is refused or does not complete in time.
func connectSocket(_ port: UInt16, address: String = "127.0.0.1", timeout: TimeInterval = 2) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = port.bigEndian
    guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { close(fd); return nil }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let result = withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if result != 0 {
        guard errno == EINPROGRESS else { close(fd); return nil }
        var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&waiting, 1, Int32(timeout * 1000)) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) == 0,
              failure == 0 else { close(fd); return nil }
    }
    _ = fcntl(fd, F_SETFL, flags)
    return fd
}

func send(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var sent = 0
    while sent < bytes.count {
        let written = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written > 0 else { return }
        sent += written
    }
}

func readable(_ fd: Int32, within milliseconds: Int32) -> Bool {
    var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&waiting, 1, milliseconds) == 1
}

/// Reads until the peer closes, `marker` arrives or `timeout` passes. `closed` tells whether the peer closed.
func read(_ fd: Int32, until marker: String? = nil, timeout: TimeInterval = 5) -> (text: String, closed: Bool) {
    var data = Data()
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while Date() < deadline {
        let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
        guard readable(fd, within: left) else { break }
        let count = recv(fd, &buffer, buffer.count, 0)
        if count <= 0 { return (String(decoding: data, as: UTF8.self), true) }
        data.append(contentsOf: buffer[0..<count])
        if let marker, String(decoding: data, as: UTF8.self).contains(marker) { break }
    }
    return (String(decoding: data, as: UTF8.self), false)
}

/// Sends `text` on a new connection and returns what came back until the gateway closed the connection.
func exchange(_ port: UInt16, _ text: String, timeout: TimeInterval = 5) -> String {
    guard let fd = connectSocket(port) else { return "<refused>" }
    defer { close(fd) }
    send(fd, text)
    return read(fd, timeout: timeout).text
}

func status(_ response: String) -> Int? {
    let parts = response.prefix { $0 != "\r" }.split(separator: " ")
    return parts.count >= 2 && parts[0] == "HTTP/1.1" ? Int(parts[1]) : nil
}

func body(_ response: String) -> String {
    guard let range = response.range(of: "\r\n\r\n") else { return "" }
    return String(response[range.upperBound...])
}

/// The first IPv4 address of an interface that is up and is not loopback.
func nonLoopbackIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(entry.pointee.ifa_flags)
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        guard inet_ntop(AF_INET, &inet, &host, socklen_t(host.count)) != nil else { continue }
        let text = String(cString: host)
        if !text.hasPrefix("127.") { return text }
    }
    return nil
}

/// The TCP listening sockets of this process, as lsof prints them.
func listeningSockets() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP", "-sTCP:LISTEN"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "<lsof failed>" }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
}

// MARK: - Handler

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StudioGatewayRequest] = []
    func add(_ request: StudioGatewayRequest) { lock.withLock { items.append(request) } }
    var count: Int { lock.withLock { items.count } }
    func last(_ target: String) -> StudioGatewayRequest? { lock.withLock { items.last { $0.target == target } } }
    func hits(_ target: String) -> Int { lock.withLock { items.filter { $0.target == target }.count } }
}

let recorder = Recorder()
let handler: StudioGateway.Handler = { request, reply in
    recorder.add(request)
    switch request.target {
    case "/hang":
        reply(StudioGatewayResponse(status: 200, headers: [:], hang: true))
    case "/slow":
        reply(StudioGatewayResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("slow".utf8), delayMs: 600))
    case "/twice":
        DispatchQueue.global().async { reply(StudioGatewayResponse(status: 202, headers: [:], body: Data("first".utf8))) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            reply(StudioGatewayResponse(status: 500, headers: [:], body: Data("second".utf8)))
        }
    default:
        let echo = "\(request.variable) \(request.method) \(request.target) \(request.body?.count ?? 0)"
        reply(StudioGatewayResponse(status: 201, headers: ["Content-Type": "text/plain", "Connection": "keep-alive",
                                                           "Content-Length": "999", "X-Variable": request.variable],
                                    body: Data(echo.utf8)))
    }
}

func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: - Checks

func gatewayChecks() async {
    let gateway = StudioGateway(handler: handler)
    let ports: [String: UInt16]
    do {
        ports = try await gateway.open(["MARKETPLACE_CORE_URL", "PAYMENTS_URL", "MARKETPLACE_CORE_URL"])
    } catch {
        check("the gateway opens", false, "\(error)")
        return
    }
    let core = ports["MARKETPLACE_CORE_URL"] ?? 0, payments = ports["PAYMENTS_URL"] ?? 0
    check("the gateway opens one port per variable", ports.count == 2 && core > 0 && payments > 0 && core != payments, "\(ports)")
    check("ports lists the open ports", gateway.ports == ports, "\(gateway.ports)")
    do {
        _ = try await gateway.open(["OTHER_URL"])
        check("opening an open gateway is refused", false)
    } catch {
        check("opening an open gateway is refused", error as? StudioGatewayError == .alreadyOpen, "\(error)")
    }
    let sockets = listeningSockets()
    check("the listeners are bound to 127.0.0.1 only", sockets.contains("127.0.0.1:\(core) (LISTEN)")
          && sockets.contains("127.0.0.1:\(payments) (LISTEN)") && !sockets.contains("*:\(core)") && !sockets.contains("[::"), sockets)

    // A normal request through URLSession reaches the handler and gets its answer.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: false, kCFNetworkProxiesHTTPSEnable as String: false]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: configuration)
    var post = URLRequest(url: URL(string: "http://127.0.0.1:\(core)/api/v1/core/fx/rates?base=EUR")!)
    post.httpMethod = "POST"
    post.setValue("Bearer test-token-not-real", forHTTPHeaderField: "Authorization")
    post.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload = Data(#"{"pairs":["EURUSD"]}"#.utf8)
    post.httpBody = payload
    do {
        let (data, response) = try await session.data(for: post)
        let http = response as? HTTPURLResponse
        check("URLSession gets the handler's answer", http?.statusCode == 201
              && String(decoding: data, as: UTF8.self) == "MARKETPLACE_CORE_URL POST /api/v1/core/fx/rates?base=EUR \(payload.count)",
              "\(http?.statusCode ?? -1) \(String(decoding: data, as: UTF8.self))")
        check("the answer is marked as simulated and closes the connection",
              http?.value(forHTTPHeaderField: "x-markview-simulation") == "1" && http?.value(forHTTPHeaderField: "connection") == "close"
              && http?.value(forHTTPHeaderField: "x-variable") == "MARKETPLACE_CORE_URL"
              && http?.value(forHTTPHeaderField: "content-length") == "\(data.count)", "\(http?.allHeaderFields ?? [:])")
    } catch {
        check("URLSession gets the handler's answer", false, "\(error)")
    }
    let seen = recorder.last("/api/v1/core/fx/rates?base=EUR")
    check("the handler gets the variable, method and target", seen?.variable == "MARKETPLACE_CORE_URL" && seen?.method == "POST",
          "\(String(describing: seen?.variable)) \(String(describing: seen?.method))")
    check("the handler gets the headers with lowercased names", seen?.headers["authorization"] == "Bearer test-token-not-real"
          && seen?.headers["content-type"] == "application/json" && seen?.headers["host"] == "127.0.0.1:\(core)",
          seen?.headers.keys.sorted().joined(separator: ",") ?? "nil")
    check("the handler gets the body", seen?.body == payload)

    do {
        let (data, response) = try await session.data(from: URL(string: "http://localhost:\(payments)/v2/charges/7")!)
        check("a request to localhost:<port> reaches the other variable", (response as? HTTPURLResponse)?.statusCode == 201
              && String(decoding: data, as: UTF8.self) == "PAYMENTS_URL GET /v2/charges/7 0", String(decoding: data, as: UTF8.self))
        check("the localhost request keeps its Host", recorder.last("/v2/charges/7")?.headers["host"] == "localhost:\(payments)")
    } catch {
        check("a request to localhost:<port> reaches the other variable", false, "\(error)")
    }

    // Guards, answered without the handler.
    let before = recorder.count
    let wrongHost = exchange(core, "GET /api HTTP/1.1\r\nHost: evil.example\r\n\r\n")
    check("a wrong Host is 421", status(wrongHost) == 421 && wrongHost.contains("content-type: text/plain"), wrongHost)
    check("another listener's port in Host is 421", status(exchange(core, "GET /api HTTP/1.1\r\nHost: 127.0.0.1:\(payments)\r\n\r\n")) == 421)
    check("a request without Host is 421", status(exchange(core, "GET /api HTTP/1.0\r\n\r\n")) == 421)
    check("sec-fetch-site from a browser is 403",
          status(exchange(core, "GET /api HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\nSec-Fetch-Site: cross-site\r\n\r\n")) == 403)
    check("an Origin header is 403",
          status(exchange(core, "POST /api HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\nOrigin: https://evil.example\r\nContent-Length: 0\r\n\r\n")) == 403)
    let started = Date()
    let early = exchange(core, "POST /api HTTP/1.1\r\nHost: evil.example\r\nContent-Length: 1000000\r\n\r\n", timeout: 3)
    check("a refused request is answered before its body", status(early) == 421 && Date().timeIntervalSince(started) < 2, early)
    let absolute = exchange(core, "GET http://127.0.0.1:\(core)/api HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\n\r\n")
    check("a parser failure is answered with its status and a short text", status(absolute) == 400 && body(absolute).contains("origin-form"), absolute)
    check("refused requests never reach the handler", recorder.count == before, "\(recorder.count - before) reached it")

    // HEAD, 100-continue and chunked bodies over a real connection.
    let head = exchange(core, "HEAD /items HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\n\r\n")
    check("HEAD gets the head with its length and no body", status(head) == 201 && head.contains("content-length: \("MARKETPLACE_CORE_URL HEAD /items 0".utf8.count)\r\n") && body(head).isEmpty, head)
    if let fd = connectSocket(core) {
        send(fd, "PUT /upload HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
        let interim = read(fd, until: "\r\n\r\n", timeout: 3).text
        check("Expect: 100-continue gets 100 Continue once", interim == "HTTP/1.1 100 Continue\r\n\r\n", interim)
        send(fd, "hello")
        let final = read(fd, timeout: 3).text
        check("the body sent after 100 Continue is answered", status(final) == 201 && body(final) == "MARKETPLACE_CORE_URL PUT /upload 5", final)
        close(fd)
    }
    let chunked = exchange(core, "POST /chunks HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\nTransfer-Encoding: chunked\r\n\r\n4;x=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-T: 1\r\n\r\n")
    check("a chunked body reaches the handler decoded", status(chunked) == 201 && recorder.last("/chunks")?.body == Data("Wikipedia".utf8), chunked)

    // A held answer stays open until Reset answers it with 503.
    if let fd = connectSocket(core) {
        send(fd, "GET /hang HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\n\r\n")
        let reached = await waitFor { recorder.last("/hang") != nil }
        check("a held request reaches the handler", reached)
        check("a held request is not answered", !readable(fd, within: 400))
        gateway.releaseHeld()
        let released = read(fd, timeout: 3)
        check("releaseHeld answers a held request with 503 and closes it", status(released.text) == 503 && released.closed, released.text)
        close(fd)
    }

    // delayMs is honoured, and a delayed answer does not hold up other requests.
    let slowStart = Date()
    async let slow = session.data(from: URL(string: "http://127.0.0.1:\(core)/slow")!)
    try? await Task.sleep(nanoseconds: 100_000_000)
    let quickStart = Date()
    let quick = exchange(payments, "GET /quick HTTP/1.1\r\nHost: 127.0.0.1:\(payments)\r\n\r\n")
    check("another request is answered during a delay", status(quick) == 201 && Date().timeIntervalSince(quickStart) < 0.4)
    do {
        let (data, response) = try await slow
        let elapsed = Date().timeIntervalSince(slowStart)
        check("delayMs delays the answer", (response as? HTTPURLResponse)?.statusCode == 200 && String(decoding: data, as: UTF8.self) == "slow"
              && elapsed >= 0.55 && elapsed < 5, "\(elapsed)")
    } catch {
        check("delayMs delays the answer", false, "\(error)")
    }

    // The reply closure takes effect once.
    let twice = exchange(core, "GET /twice HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\n\r\n")
    check("only the first reply is sent", status(twice) == 202 && body(twice) == "first", twice)
    try? await Task.sleep(nanoseconds: 100_000_000)

    // At most 64 connections: the next one is closed at once; closed clients free their slots.
    var idle: [Int32] = []
    for _ in 0..<StudioGateway.maxConnections { if let fd = connectSocket(core) { idle.append(fd) } }
    try? await Task.sleep(nanoseconds: 400_000_000)
    if let extra = connectSocket(core) {
        let outcome = read(extra, timeout: 2)
        check("a connection over the limit is closed at once", idle.count == StudioGateway.maxConnections && outcome.closed && outcome.text.isEmpty,
              "\(idle.count) open, closed \(outcome.closed) \(outcome.text)")
        close(extra)
    } else {
        check("a connection over the limit is closed at once", true)
    }
    idle.forEach { close($0) }
    try? await Task.sleep(nanoseconds: 400_000_000)
    check("slots are free again once clients close", status(exchange(core, "GET /again HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\n\r\n")) == 201)

    // No listener on other interfaces.
    if let address = nonLoopbackIPv4() {
        let fd = connectSocket(core, address: address)
        check("the gateway port is not reachable on \(address)", fd == nil)
        if let fd { close(fd) }
    } else {
        print("skip the gateway port on another interface: this Mac has no non-loopback IPv4 address")
    }

    // close() closes held connections and the ports; the gateway can be opened again.
    let hangs = recorder.hits("/hang")
    let held = connectSocket(core)
    if let held { send(held, "GET /hang HTTP/1.1\r\nHost: 127.0.0.1:\(core)\r\n\r\n") }
    check("a second held request reaches the handler", await waitFor { recorder.hits("/hang") > hangs })
    gateway.close()
    if let held {
        let outcome = read(held, timeout: 2)
        check("close() closes a held connection without an answer", outcome.closed && outcome.text.isEmpty, outcome.text)
        close(held)
    }
    let refused = await waitFor({
        guard let fd = connectSocket(core) else { return true }
        close(fd)
        return false
    }, timeout: 2)
    check("after close() the port refuses connections", refused && connectSocket(payments) == nil)
    gateway.close()
    check("close() is idempotent and clears the ports", gateway.ports.isEmpty)
    do {
        let again = try await gateway.open(["NEW_URL"])
        let port = again["NEW_URL"] ?? 0
        check("the gateway opens again after close()", again.count == 1 && port > 0
              && status(exchange(port, "GET /new HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n")) == 201)
    } catch {
        check("the gateway opens again after close()", false, "\(error)")
    }
    gateway.close()
    check("an empty set opens nothing", ((try? await gateway.open([])) ?? ["x": 1]).isEmpty && gateway.ports.isEmpty)

    // The request must arrive in time.
    let impatient = StudioGateway(handler: handler, requestTimeout: 0.5)
    if let port = (try? await impatient.open(["SLOW_CLIENT_URL"]))?["SLOW_CLIENT_URL"], let fd = connectSocket(port) {
        let begin = Date()
        send(fd, "GET /late HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n")
        let outcome = read(fd, timeout: 3)
        let elapsed = Date().timeIntervalSince(begin)
        check("a head that does not arrive in time is 408", status(outcome.text) == 408 && outcome.closed && elapsed >= 0.4 && elapsed < 2.5,
              "\(elapsed) \(outcome.text)")
        close(fd)
    } else {
        check("a head that does not arrive in time is 408", false, "the gateway did not open")
    }
    impatient.close()
}

// MARK: - Streams (REQ-015): WebSocket and server-sent events through the gateway

final class StreamLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

func sendData(_ fd: Int32, _ data: Data) {
    let bytes = [UInt8](data)
    var sent = 0
    while sent < bytes.count {
        let written = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written > 0 else { return }
        sent += written
    }
}

/// A WebSocket client on a raw socket: the handshake, then frames read with the codec (server frames are not masked).
final class SocketClient {
    let fd: Int32
    var head = ""
    var decoder = StudioWebSocketCodec.Decoder()
    var outputs: [StudioWebSocketCodec.Decoder.Output] = []
    var closed = false
    private var pending = Data()

    init?(_ port: UInt16, target: String = "/ws", protocols: String? = nil, version: String = "13", extra: Data = Data()) {
        guard let fd = connectSocket(port) else { return nil }
        self.fd = fd
        decoder.requireMask = false
        var request = "GET \(target) HTTP/1.1\r\nHost: localhost:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: \(version)\r\n"
        if let protocols { request += "Sec-WebSocket-Protocol: \(protocols)\r\n" }
        sendData(fd, Data((request + "\r\n").utf8) + extra)
        var data = Data()
        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while Date() < deadline, data.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard readable(fd, within: Int32(max(1, deadline.timeIntervalSinceNow * 1000))) else { break }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { closed = true; break }
            data.append(contentsOf: buffer[0..<count])
        }
        if let end = data.range(of: Data("\r\n\r\n".utf8)) {
            head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            pending = Data(data[end.upperBound...])
        } else {
            head = String(decoding: data, as: UTF8.self)
        }
    }

    func send(_ opcode: StudioWebSocketCodec.Opcode, _ payload: Data, masked: Bool = true, fin: Bool = true) {
        sendData(fd, StudioWebSocketCodec.frame(opcode, payload, masked: masked, fin: fin))
    }

    /// Reads frames until `count` have arrived (in all), the server closes the connection or `timeout` passes.
    @discardableResult
    func read(_ count: Int, timeout: TimeInterval = 3) -> [StudioWebSocketCodec.Decoder.Output] {
        if !pending.isEmpty {
            outputs += (try? decoder.feed(pending)) ?? []
            pending = Data()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while outputs.count < count, !closed, Date() < deadline {
            guard readable(fd, within: Int32(max(1, deadline.timeIntervalSinceNow * 1000))) else { break }
            let received = recv(fd, &buffer, buffer.count, 0)
            if received <= 0 { closed = true; break }
            outputs += (try? decoder.feed(Data(buffer[0..<received]))) ?? []
        }
        return outputs
    }

    /// Waits until the server closes the TCP connection.
    func waitClosed(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !closed, Date() < deadline {
            guard readable(fd, within: Int32(max(1, deadline.timeIntervalSinceNow * 1000))) else { break }
            let received = recv(fd, &buffer, buffer.count, 0)
            if received <= 0 { closed = true } else { outputs += (try? decoder.feed(Data(buffer[0..<received]))) ?? [] }
        }
        return closed
    }

    deinit { Darwin.close(fd) }
}

func streamChecks() async {
    let log = StreamLog()
    let gateway = StudioGateway(handler: handler)
    let plainGateway = StudioGateway(handler: handler)
    gateway.setStreamHandler { [gateway] event in
        switch event {
        case .open(let id, .webSocket(let protocols), let request):
            log.add("open \(request.target) \(protocols.joined(separator: ","))")
            if request.target == "/refuse" { return gateway.refuseStream(id, status: 404, "No channel answers this address.") }
            gateway.acceptStream(id, protocol: protocols.first)
            gateway.sendStream(id, .text("welcome"))
        case .open(let id, .eventSource, let request):
            log.add("sse \(request.target)")
            gateway.acceptStream(id, protocol: nil)
            gateway.sendStream(id, .event(name: "tick", data: "a\nb", id: "1"))
            gateway.sendStream(id, .text("plain"))
            if request.target == "/events/once" { gateway.sendStream(id, .close(code: 1000, reason: "")) }
        case .text(let id, let text):
            log.add("text \(text.count)")
            if text == "bye" { gateway.sendStream(id, .close(code: 1000, reason: "done")) } else { gateway.sendStream(id, .text("echo:" + text)) }
        case .binary(let id, let data):
            gateway.sendStream(id, .binary(Data(data.reversed())))
        case .closed(_, let code):
            log.add("closed \(code.map(String.init) ?? "none")")
        }
    }
    guard let port = (try? await gateway.open(["REALTIME_URL"]))?["REALTIME_URL"],
          let plainPort = (try? await plainGateway.open(["PLAIN_URL"]))?["PLAIN_URL"] else {
        check("streams: the gateways open", false)
        return
    }

    // The handshake: 101, the RFC 6455 accept key, the chosen subprotocol and the first message.
    if let client = SocketClient(port, protocols: "graphql-transport-ws, graphql-ws") {
        let lines = client.head.lowercased()
        check("streams: the WebSocket handshake answers 101 with the accept key", client.head.hasPrefix("HTTP/1.1 101")
              && lines.contains("sec-websocket-accept: s3pplmbitxaq9kygzzhzrbk+xoo=") && lines.contains("upgrade: websocket"), client.head)
        check("streams: the first offered subprotocol is chosen", lines.contains("sec-websocket-protocol: graphql-transport-ws"), client.head)
        check("streams: the server's first message arrives unmasked", client.read(1) == [.text("welcome")], "\(client.outputs)")

        // A masked frame split over two writes, then a fragmented message with a ping between its fragments.
        let frame = StudioWebSocketCodec.frame(.text, Data("hello".utf8), masked: true)
        sendData(client.fd, frame.prefix(4))
        try? await Task.sleep(nanoseconds: 50_000_000)
        sendData(client.fd, frame.dropFirst(4))
        check("streams: a masked frame in two pieces is one message", client.read(2).last == .text("echo:hello"), "\(client.outputs)")
        client.send(.text, Data("frag".utf8), fin: false)
        client.send(.ping, Data("p1".utf8))
        client.send(.continuation, Data("ment".utf8))
        let answers = Array(client.read(4).dropFirst(2))
        check("streams: a ping between fragments is answered with a pong, then the message", answers == [.pong(Data("p1".utf8)), .text("echo:fragment")],
              "\(answers)")
        let long = String(repeating: "x", count: 70_000)
        client.send(.text, Data(long.utf8))
        check("streams: a 64-bit length frame is read and answered", client.read(5).last == .text("echo:" + long))
        client.send(.binary, Data([1, 2, 3]))
        check("streams: binary messages travel both ways", client.read(6).last == .binary(Data([3, 2, 1])), "\(client.outputs.last.map { "\($0)" } ?? "")")

        // The client closes: the server echoes the close and tells the channel handler.
        sendData(client.fd, StudioWebSocketCodec.frame(.close, Data([0x03, 0xE8]) + Data("leaving".utf8), masked: true))
        check("streams: a client close is echoed and ends the connection", client.read(7).last == .close(1000, "") && client.waitClosed())
        check("streams: the channel handler hears the close", await waitFor({ log.all.contains("closed 1000") }), "\(log.all)")
    } else { check("streams: a WebSocket connects", false) }

    // Frame bytes sent together with the handshake are kept for after the accept.
    let early = StudioWebSocketCodec.frame(.text, Data("early".utf8), masked: true)
    if let client = SocketClient(port, extra: early) {
        check("streams: a frame sent with the handshake is answered after it", client.read(2) == [.text("welcome"), .text("echo:early")],
              "\(client.outputs)")
    } else { check("streams: early frame", false) }

    // The server closes with a code and reason.
    if let client = SocketClient(port) {
        client.send(.text, Data("bye".utf8))
        check("streams: the server closes with its code and reason", client.read(2).last == .close(1000, "done") && client.waitClosed(), "\(client.outputs)")
    } else { check("streams: server close", false) }

    // Protocol violations close the connection with the RFC 6455 codes.
    if let client = SocketClient(port) {
        client.read(1)
        client.send(.text, Data("unmasked".utf8), masked: false)
        check("streams: an unmasked client frame closes with 1002", client.read(2).last == .close(1002, "Client frames must be masked") && client.waitClosed(),
              "\(client.outputs)")
    } else { check("streams: unmasked", false) }
    if let client = SocketClient(port) {
        client.read(1)
        sendData(client.fd, Data([0x82, 0xFF, 0, 0, 0, 0, 0, 0x20, 0, 0]))
        check("streams: a frame over the size limit closes with 1009", client.read(2).last == .close(1009, "The frame is too large") && client.waitClosed(),
              "\(client.outputs)")
    } else { check("streams: too large", false) }
    if let client = SocketClient(port) {
        client.read(1)
        client.send(.text, Data([0xFF, 0xFE, 0x41, 0x42, 0x43]))
        check("streams: text that is not UTF-8 closes with 1007", client.read(2).last == .close(1007, "The text is not UTF-8") && client.waitClosed(),
              "\(client.outputs)")
    } else { check("streams: invalid UTF-8", false) }

    // Refusals.
    if let client = SocketClient(port, version: "8") {
        check("streams: another WebSocket version is 426 with the supported one", status(client.head) == 426
              && client.head.lowercased().contains("sec-websocket-version: 13"), client.head)
    } else { check("streams: version", false) }
    if let client = SocketClient(port, target: "/refuse") {
        check("streams: an address no channel answers gets a plain answer", status(client.head) == 404, client.head)
    } else { check("streams: refused", false) }
    if let client = SocketClient(plainPort) {
        check("streams: without a stream handler an upgrade is an ordinary request", status(client.head) == 201, client.head)
    } else { check("streams: plain gateway", false) }

    // Server-sent events: the stream is held open, events are framed, a close ends it.
    if let fd = connectSocket(port) {
        send(fd, "GET /events/once HTTP/1.1\r\nHost: localhost:\(port)\r\nAccept: text/event-stream\r\n\r\n")
        let outcome = read(fd, timeout: 3)
        check("streams: an event stream answers text/event-stream with framed events",
              outcome.text.hasPrefix("HTTP/1.1 200") && outcome.text.lowercased().contains("content-type: text/event-stream")
              && outcome.text.hasSuffix("\r\n\r\nevent: tick\ndata: a\ndata: b\nid: 1\n\ndata: plain\n\n") && outcome.closed, outcome.text)
        close(fd)
    } else { check("streams: event stream", false) }
    if let fd = connectSocket(port) {
        send(fd, "GET /events/live HTTP/1.1\r\nHost: localhost:\(port)\r\nAccept: text/event-stream\r\n\r\n")
        let first = read(fd, until: "data: plain\n\n", timeout: 3)
        let later = read(fd, timeout: 0.5)
        check("streams: an event stream stays open until the channel ends it", first.text.contains("data: plain") && !first.closed && !later.closed,
              first.text)
        close(fd)
        check("streams: a client that leaves an event stream is heard", await waitFor({ log.all.filter { $0 == "closed none" }.count >= 1 }), "\(log.all)")
    } else { check("streams: live event stream", false) }

    gateway.close()
    plainGateway.close()
}

// MARK: - Run

let done = DispatchSemaphore(value: 0)
Task { @MainActor in
    await gatewayChecks()
    await streamChecks()
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
print(failures == 0 ? "All UI Studio gateway checks passed." : "\(failures) UI Studio gateway check(s) failed.")
exit(failures == 0 ? 0 : 1)
