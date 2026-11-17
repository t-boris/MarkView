import AppKit
import CryptoKit
import os
import Darwin
import WebKit
import XCTest
@testable import MarkView

/// Runs the session lifetime scenarios in the app host, with no live provider.
final class UIStudioLifetimeHostTests: XCTestCase {
    func testAssistantBoundaryFailsClosed() async {
        AIAssistantRunner.setTestRunner(nil)
        do {
            _ = try await AIAssistantRunner.run(CLICompletion.Request(project: nil, prompt: "fixture"), nil, nil)
            XCTFail("An unconfigured app-host test must not start an assistant.")
        } catch is AIAssistantRunner.MissingTestRunner {
            // Expected: the test host rejects requests until a fixture is installed.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    func testAssistantFixtureRecordsRealRequests() async throws {
        let fixture = UIStudioAssistantFixture()
        fixture.answer = { _ in
            try CLICompletion.Result(text: "fixture answer", structured: nil, inputTokens: 1, outputTokens: 2, costUSD: nil)
        }
        var normal = CLICompletion.Request(project: nil, prompt: "question")
        normal.label = "ui-studio:edit"
        var map = CLICompletion.Request(project: nil, prompt: "map")
        map.label = "ui-studio:map"
        let answer = try await fixture.run(normal, nil, nil)
        let mapping = try await fixture.run(map, nil, nil)
        XCTAssertEqual(answer.text, "fixture answer")
        XCTAssertEqual(fixture.requests.map(\.label), ["ui-studio:edit"])
        XCTAssertEqual(fixture.mapRequests.map(\.label), ["ui-studio:map"])
        XCTAssertEqual((mapping.structured as? [String: Any])?["services"] as? [String], [])
    }
    @MainActor func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        XCTAssertTrue(condition, name + " " + detail())
    }
    func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    func shell(_ command: String, in folder: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try? process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
    }
    @MainActor func waitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
    @MainActor func hostPageInvisibly(_ session: StudioSession) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 1100, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = StudioPreviewScrollView(webView: session.webView)
        host.frame = window.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(host)
        host.viewport = CGSize(width: session.viewport.width, height: session.viewport.height)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
final class Gate: @unchecked Sendable {   // unchecked Sendable: `lock` guards every field
    private let lock = NSLock()
    private var entered = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many calls reached the gate.
    var inFlight: Int { lock.withLock { entered } }

    func release() {
        let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        parked.forEach { $0.resume() }
    }

    func wait(cancellable: Bool) async throws {
        lock.withLock { entered += 1 }
        guard cancellable else { return await park() }
        try await withTaskCancellationHandler {
            await park()
            try Task.checkCancellation()
        } onCancel: {
            release()
        }
    }

    private func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}



/// The assistant answers `label` through `gate`, with `structured`; every other call gets an empty answer at once.
func standIn(label: String?, gate: Gate, cancellable: Bool, structured: [String: Any]? = nil) -> UIStudioAssistantFixture {
    let json = structured.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    let fixture = UIStudioAssistantFixture()
    fixture.answer = { request in
        guard let label, request.label == label else {
            return try CLICompletion.Result(text: "", structured: ["rules": [], "assumptions": []], inputTokens: 1, outputTokens: 1, costUSD: 0)
        }
        try await gate.wait(cancellable: cancellable)
        let answer = json.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return try CLICompletion.Result(text: "", structured: answer, inputTokens: 10, outputTokens: 5, costUSD: 0)
    }
    AIAssistantRunner.setTestRunner(fixture.run)
    return fixture
}

// MARK: - Fixtures

/// A page whose code knows two bundle statuses and fails on the simulated `draft` (the vivaa case, BUG-080).
let dataPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Bundles</title></head><body>
<ul id="list"></ul>
<script>
const LABELS = { editable: 'Editable', locked: 'Locked' };
(async () => {
  const bundles = await (await fetch('/api/bundles')).json();
  document.getElementById('list').innerHTML = bundles.map(b => '<li>' + LABELS[b.status].toUpperCase() + '</li>').join('');
})();
</script></body></html>
"""

/// A page that asks for an endpoint nothing simulates, so the assistant is asked to prepare its rule.
let requestPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Reports</title></head><body>
<p id="out">waiting</p>
<script>
fetch('/api/reports').then(r => r.json()).then(d => { document.getElementById('out').textContent = JSON.stringify(d); })
  .catch(() => { document.getElementById('out').textContent = 'failed'; });
</script></body></html>
"""

struct Fixture {
    let root: URL
    let port: Int
    var target: WebAppTarget {
        WebAppTarget(folder: root, label: "page", command: "python3 -m http.server \(port) --bind 127.0.0.1", ports: [port])
    }
}

func makeFixture(_ name: String, page: String, autoRepair: Bool) -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-ui-studio-lifetime-\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? page.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    func bundle(_ id: Int, _ name: String) -> StudioJSON { .object(["id": .number(Double(id)), "name": .string(name), "status": .string("draft")]) }
    var env = StudioEnvironmentSpec()
    env.entities = [StudioEntity(name: "bundles", fields: [StudioField(name: "name", type: "string", required: true), StudioField(name: "status", type: "string")])]
    env.rules = [StudioRule(id: "list-bundles", method: "GET", path: "/api/bundles", operation: .list, entity: "bundles")]
    env.seed = ["bundles": [bundle(1, "One"), bundle(2, "Two"), bundle(3, "Three")]]
    env.map = StudioEnvironmentMap(status: .complete, appFolder: ".", inventoried: true)
    env.autoRepair = autoRepair
    env.prepareScreens = false
    try? StudioStore.saveEnvironment(env, root: root)
    shell("git init -q && git add -A && git -c user.email=t@example.com -c user.name=Test commit -qm init", in: root)
    return Fixture(root: root, port: freePort())
}

/// Every file of the project with its size and modification time, apart from the repository's own folder: a file written after
/// the first listing shows as a difference.
func listing(_ root: URL) -> [String] {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
    var lines: [String] = []
    for case let url as URL in files {
        let relative = String(url.path.dropFirst(root.path.count))
        if relative.hasPrefix("/.git") { continue }
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isDirectory == true { continue }
        lines.append("\(relative) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
    }
    return lines.sorted()
}

/// The session log as written so far (`.dde/studio/session.log`), to say what was logged after close.
func sessionLog(_ root: URL) -> String {
    (try? String(contentsOf: root.appendingPathComponent(".dde/studio/session.log"), encoding: .utf8)) ?? ""
}

// MARK: - One scenario

/// Opens a session on a fixture, starts one long path with `begin`, waits until it is in flight, closes the session and drops
/// every reference to it, then lets the assistant answer (or find itself cancelled) and checks what the work did.
@MainActor
func scenario(_ name: String, page: String, autoRepair: Bool, label: String? = nil, cancellable: Bool, answer: [String: Any]? = nil,
              inFlight: ((StudioSession, Gate) -> Bool)? = nil, begin: (StudioSession) async -> Void = { _ in }) async {
    // Names after the Editor/js folder pick scenarios by a part of their name; none runs them all.
    let filters = ProcessInfo.processInfo.environment["MARKVIEW_STUDIO_LIFETIME_FILTER", default: ""].split(separator: "\n").map(String.init)
    guard filters.isEmpty || filters.contains(where: { name.contains($0) }) else { return }
    print("--  \(name)")
    let fixture = makeFixture("scenario", page: page, autoRepair: autoRepair)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gate = Gate()
    let assistant = standIn(label: label, gate: gate, cancellable: cancellable, structured: answer)
    weak var probe: StudioSession?
    var io: DispatchQueue?
    var hosting: NSWindow?
    var reached = false
    var opened = false
    var before: [String] = []
    var logBefore = ""
    var stateAfterClose: StudioSessionState?
    // The only strong references to the session are in this scope; the work the session started holds the rest.
    do {
        let session = StudioSession(root: fixture.root)
        probe = session
        io = session.io
        hosting = hostPageInvisibly(session)
        session.start(fixture.target)
        opened = await waitUntil(90) { session.appURL != nil }
        await begin(session)
        reached = await waitUntil(60) { inFlight?(session, gate) ?? (gate.inFlight > 0) }
        await session.close()
        stateAfterClose = session.state
        io?.sync {}
        before = listing(fixture.root)
        logBefore = sessionLog(fixture.root)
    }
    hosting?.close()
    hosting = nil
    check("\(name): the session opened and its work was in flight when it was closed", opened && reached, "opened \(opened) in flight \(reached)")
    check("\(name): the session was closed", stateAfterClose == .stopped, "\(String(describing: stateAfterClose))")
    gate.release()
    let released = await waitUntil(40) { probe == nil }
    io?.sync {}
    let after = listing(fixture.root)
    check("\(name): the work ended and the session was released", released)
    let logAfter = sessionLog(fixture.root)
    check("\(name): nothing was written after close", before == after,
          Set(before).symmetricDifference(Set(after)).sorted().joined(separator: "; ") + "\n" + logAfter.dropFirst(logBefore.count))
    if label != nil {
        let asked = assistant.requests.filter { $0.label == label }.count
        check("\(name): the assistant was asked once and not again", asked == 1, "\(asked)")
    }
}

@MainActor
func testLifetime() async {
    let oldTimeout = StudioSession.expectedStateTimeout
    StudioSession.expectedStateTimeout = 1
    defer { StudioSession.expectedStateTimeout = oldTimeout; AIAssistantRunner.setTestRunner(nil) }

    // The automatic repair looks at the settled page by itself (REQ-020): its task waits for the repair's work, which the real
    // assistant runner ends when the session closes. This is the crash of 6.27.0 (the task read its session after it was gone).
    await scenario("automatic repair, cancelled by close", page: dataPage, autoRepair: true, label: "ui-studio:fix-data", cancellable: true)
    await scenario("automatic repair, answered after close", page: dataPage, autoRepair: true, label: "ui-studio:fix-data", cancellable: false,
                   answer: ["kind": "data", "summary": "The code knows editable.", "codePointer": "",
                            "changes": ["1", "2", "3"].map { ["entity": "bundles", "id": $0, "field": "status", "valueJSON": "\"editable\"", "reason": "app.js reads LABELS[status]"] }])

    // The person's click on Fix data.
    await scenario("data fix on the click, answered after close", page: dataPage, autoRepair: false, label: "ui-studio:fix-data", cancellable: false,
                   answer: ["kind": "not_data", "summary": "Nothing to correct.", "codePointer": "", "changes": []],
                   begin: { session in
        _ = await waitUntil(30) { !session.repair.fixableErrors.isEmpty }
        session.repair.fixData()
    })

    // A request of the request box: the assistant is reading the project when the session closes.
    await scenario("request box, cancelled by close", page: dataPage, autoRepair: false, label: "ui-studio:edit", cancellable: true,
                   begin: { session in session.change("Make the heading larger") })

    // A request of the page that no rule answers: the assistant prepares the rule when the session closes.
    await scenario("page request preparing a rule, answered after close", page: requestPage, autoRepair: false, label: "ui-studio:prepare", cancellable: false)

    // A capture and a pick, with no assistant: the work is the page's.
    await scenario("capture, closed while it runs", page: dataPage, autoRepair: false, cancellable: true,
                   inFlight: { session, _ in session.busy != nil }, begin: { session in session.captureNow() })
    await scenario("pick, closed while it waits for the page", page: dataPage, autoRepair: false, cancellable: true,
                   inFlight: { session, _ in session.elementPicker.pickTask != nil }, begin: { session in
        session.setMode(.select)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    })

}

}

// Real loopback gateway clients; each socket disables SIGPIPE without changing the host process.
private func connectSocket(_ port: UInt16, address: String = "127.0.0.1", timeout: TimeInterval = 2) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(fd); return nil }
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

private func send(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var sent = 0
    while sent < bytes.count {
        let written = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written > 0 else { return }
        sent += written
    }
}

private func readable(_ fd: Int32, within milliseconds: Int32) -> Bool {
    var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&waiting, 1, milliseconds) == 1
}

/// Reads until the peer closes, `marker` arrives or `timeout` passes. `closed` tells whether the peer closed.
private func read(_ fd: Int32, until marker: String? = nil, timeout: TimeInterval = 5) -> (text: String, closed: Bool) {
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
private func exchange(_ port: UInt16, _ text: String, timeout: TimeInterval = 5) -> String {
    guard let fd = connectSocket(port) else { return "<refused>" }
    defer { close(fd) }
    send(fd, text)
    return read(fd, timeout: timeout).text
}

private func status(_ response: String) -> Int? {
    let parts = response.prefix { $0 != "\r" }.split(separator: " ")
    return parts.count >= 2 && parts[0] == "HTTP/1.1" ? Int(parts[1]) : nil
}

private func body(_ response: String) -> String {
    guard let range = response.range(of: "\r\n\r\n") else { return "" }
    return String(response[range.upperBound...])
}

/// The first IPv4 address of an interface that is up and is not loopback.
private func nonLoopbackIPv4() -> String? {
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
private func listeningSockets() -> String {
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


private func sendData(_ fd: Int32, _ data: Data) {
    let bytes = [UInt8](data)
    var sent = 0
    while sent < bytes.count {
        let written = bytes[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written > 0 else { return }
        sent += written
    }
}


extension UIStudioLifetimeHostTests {
    @MainActor func testGatewayIntegration() async {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { XCTFail("\(name): \(detail())") }
        }
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
    defer { gateway.close() }
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
    let gatewaySockets = sockets.split(separator: "\n").filter { $0.contains(":\(core) (LISTEN)") || $0.contains(":\(payments) (LISTEN)") }.joined(separator: "\n")
    check("the listeners are bound to 127.0.0.1 only", gatewaySockets.contains("127.0.0.1:\(core) (LISTEN)")
          && gatewaySockets.contains("127.0.0.1:\(payments) (LISTEN)") && !gatewaySockets.contains("*:") && !gatewaySockets.contains("[::"), gatewaySockets)

    // A normal request through URLSession reaches the handler and gets its answer.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: false, kCFNetworkProxiesHTTPSEnable as String: false]
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
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
    let unexpectedPaymentConnection = connectSocket(payments)
    if let unexpectedPaymentConnection { close(unexpectedPaymentConnection) }
    check("after close() the port refuses connections", refused && unexpectedPaymentConnection == nil)
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
    defer { impatient.close() }
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
    defer { gateway.close(); plainGateway.close() }
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


        await gatewayChecks()
        await streamChecks()
    }
}

extension UIStudioLifetimeHostTests {
    @MainActor func testRepairPolicy() {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { XCTFail("\(name): \(detail())") }
        }

    func url(_ text: String) -> URL { URL(string: text)! }

    // A hash-routed application: the address differs only by its fragment, so WebKit would keep the old page and its old generation.
    check("REQ-020 /#/attention → /#/accounts is a navigation inside the page",
          StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/#/attention"), to: url("http://localhost:5173/#/accounts")))
    check("REQ-020 the same address with the same fragment is too",
          StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/#/accounts"), to: url("http://localhost:5173/#/accounts")))
    check("REQ-020 another path is a new page",
          !StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/a#/x"), to: url("http://localhost:5173/b#/x")))
    check("REQ-020 another query is a new page",
          !StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/?a=1#/x"), to: url("http://localhost:5173/#/x")))
    check("REQ-020 a target without a fragment is always a new page",
          !StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/#/x"), to: url("http://localhost:5173/")))
    check("REQ-020 with no page yet it is a new page", !StudioPageLoad.isFragmentNavigation(from: nil, to: url("http://localhost:5173/#/x")))

    // The classification of a row of the Log.
    let stale = "Rejected: a message of an earlier generation (20)."
    let errorText = "runtimeError: Unhandled rejection: Error: Cannot read properties of undefined (reading 'label')"
    let key = StudioDataFix.key(of: "Unhandled rejection: Error: Cannot read properties of undefined (reading 'label')")
    func kind(_ kind: StudioLogEntry.Kind, _ problem: Bool, _ text: String, key: String? = nil, notData: Set<String> = []) -> StudioProblem.Kind {
        StudioProblem.classify(kind: kind, problem: problem, text: text, errorKey: key, notData: notData)
    }
    check("REQ-019 a message of an earlier generation is noise, even as a problem",
          kind(.server, true, "[console.warn] MarkView UI Studio: http://electron.ipc/ppd/onEvent: " + stale) == .noise
            && kind(.page, true, "runtimeError: TypeError: Failed to fetch (MarkView UI Studio: " + stale + ")", key: "x") == .noise)
    check("REQ-019 a page error that data may have caused is a data error", kind(.page, true, errorText, key: key) == .dataError)
    check("REQ-019 the same error judged not data is not offered again", kind(.page, true, errorText, key: key, notData: [key]) == .notData)
    check("REQ-019 a redirect to a sign-in page is a sign-in problem",
          kind(.navigation, true, "Server redirect http://localhost:3101/ → http://localhost:3101/login (a sign-in page)") == .signInRedirect)
    check("REQ-019 a blocked third-party script and a Stripe.js failure are reported, not repaired",
          kind(.page, true, "blocked: script https://js.stripe.com/v3") == .blockedService
            && kind(.page, true, "runtimeError: Unhandled rejection: Error: Failed to load Stripe.js", key: "Error: Failed to load Stripe.js") == .blockedService)
    check("REQ-019 a failed or timed-out preparation, and requests without a rule, are missing rules",
          kind(.preparation, true, "GET http://electron.ipc/ppd/invoke/channels.list: timedOut after 90.0 s") == .missingRule
            && kind(.notice, true, "Degraded: 1 request without a simulation rule") == .missingRule)
    check("REQ-019 an error that says its rule is still being prepared is a missing rule, not a data error",
          kind(.page, true, "runtimeError: Error invoking remote method 'automation.get': MarkView UI Studio is still preparing the simulation rule for GET x",
               key: "k") == .missingRule)
    check("REQ-019 any other problem row has no action, and a row that is no problem is not classified as one",
          kind(.server, true, "ERROR in ./src/x.tsx") == .other && kind(.request, false, "GET http://x/ · simulated 200") == .other)
    check("REQ-019 every repairable kind has its action, the others none",
          StudioProblem.action(for: .dataError) == .fix && StudioProblem.action(for: .missingRule) == .prepare
            && StudioProblem.action(for: .signInRedirect) == .signIn
            && [StudioProblem.Kind.blockedService, .notData, .noise, .other].allSatisfy { StudioProblem.action(for: $0) == nil })

    // The order that helps: sign-in, rules, then data; items of one kind keep their order; what cannot be repaired is dropped.
    let items = [StudioProblem.Item(kind: .dataError, key: "a", text: "a"), StudioProblem.Item(kind: .blockedService, key: "s", text: "s"),
                 StudioProblem.Item(kind: .missingRule, key: "r", text: "r"), StudioProblem.Item(kind: .dataError, key: "b", text: "b"),
                 StudioProblem.Item(kind: .signInRedirect, key: "/login", text: "l")]
    check("REQ-020 sign-in first, then rules, then data in order; a blocked service is dropped",
          StudioProblem.ordered(items).map(\.key) == ["/login", "r", "a", "b"])

    // The limits: nothing loops.
    var ledger = StudioRepairLedger()
    let one = StudioRepairLedger.identity(kind: .dataError, scenario: "s1", key: "e1")
    let two = StudioRepairLedger.identity(kind: .dataError, scenario: "s1", key: "e2")
    let three = StudioRepairLedger.identity(kind: .dataError, scenario: "s1", key: "e3")
    check("REQ-020 a first automatic repair is allowed", ledger.mayRun(one, automatic: true))
    ledger.record(one, outcome: .fixed, automatic: true)
    check("REQ-020 an error that came back after a fix is tried once more", ledger.mayRun(one, automatic: true))
    ledger.record(one, outcome: .fixed, automatic: true)
    check("REQ-020 and not a third time", !ledger.mayRun(one, automatic: true))
    check("REQ-020 the person's own click always may", ledger.mayRun(one, automatic: false))
    ledger.record(two, outcome: .notData, automatic: true)
    check("REQ-020 an error the assistant judged not data is never repaired again by itself", !ledger.mayRun(two, automatic: true))
    check("REQ-020 and is listed as not data for its scenario only",
          ledger.notDataKeys(scenario: "s1") == ["e2"] && ledger.notDataKeys(scenario: "s2").isEmpty)
    check("REQ-020 three automatic repairs are the most of one open", ledger.automaticRuns == 3 && !ledger.mayRun(three, automatic: true))
    ledger.reset()
    check("REQ-020 a new open remembers nothing", ledger.mayRun(one, automatic: true) && ledger.mayRun(three, automatic: true) && ledger.automaticRuns == 0)
    var refused = StudioRepairLedger()
    refused.record(three, outcome: .refused, automatic: true)
    check("REQ-020 refused corrections are not repeated by itself", !refused.mayRun(three, automatic: true))
    var failed = StudioRepairLedger()
    failed.record(three, outcome: .failed, automatic: true)
    check("REQ-020 a run that failed gets one more try", failed.mayRun(three, automatic: true))
    check("REQ-020 a repair of another scenario is another repair",
          failed.mayRun(StudioRepairLedger.identity(kind: .dataError, scenario: "s2", key: "e3"), automatic: true))

    // Page errors of earlier pages of the same scenario keep their action, and Undo writes the old values back.
    let now = Date()
    let seen = [StudioDataFix.Seen(kind: .runtimeError, detail: "Unhandled rejection: Error: boom\n    at a (b.js:1:1)", generation: 3, date: now),
                StudioDataFix.Seen(kind: .route, detail: "/x", generation: 4, date: now)]
    check("REQ-019 the latest event of an error is found whatever its page generation",
          StudioDataFix.latest(seen, key: "Error: boom")?.key == "Error: boom" && StudioDataFix.latest(seen, key: "Error: other") == nil)

    func js(_ text: String) -> StudioJSON { StudioJSON(text: text)! }
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "bundles", fields: [StudioField(name: "name", type: "string"), StudioField(name: "status", type: "string")])]
    spec.seed = ["bundles": (1...3).map { js(#"{"id":\#($0),"name":"B\#($0)","status":"draft"}"#) }]
    let scenarioData = ["bundles": [js(#"{"id":1,"name":"B1","status":"draft"}"#)]]
    let fix = StudioDataFix.apply([StudioDataFix.Change(entity: "bundles", id: "1", field: "status", value: js(#""editable""#), reason: "the code expects editable"),
                                   StudioDataFix.Change(entity: "bundles", id: "2", field: "status", value: js(#""editable""#), reason: "the code expects editable")],
                                  spec: spec, scenarioData: scenarioData, redactor: StudioRedactor())
    check("REQ-020 the fixture fix applies", fix.ok && fix.applied.count == 2, fix.problems.joined(separator: "; "))
    check("REQ-020 the fix changed the seed and the scenario's own record",
          fix.seed["bundles"]?[0]["status"] == js(#""editable""#) && fix.scenarioData?["bundles"]?[0]["status"] == js(#""editable""#))
    let back = StudioDataFix.revert(fix.applied, spec: spec, seed: fix.seed, scenarioData: fix.scenarioData)
    check("REQ-020 Undo writes the old values back in the seed and in the scenario",
          back.seed == spec.seed && back.scenarioData == scenarioData)
    let withoutRecord = StudioDataFix.revert(fix.applied, spec: spec, seed: ["bundles": []], scenarioData: nil)
    check("REQ-020 Undo leaves alone what is no longer there", withoutRecord.seed == ["bundles": []] && withoutRecord.scenarioData == nil)

    // What a reload leaves behind is in the Log, but is not counted as a problem.
    let log = StudioLog(root: nil, redactor: StudioRedactor(), queue: DispatchQueue(label: "repair-checks"))
    log.add(.server, problem: true, "[console.warn] MarkView UI Studio: http://electron.ipc/ppd/onEvent: " + stale)
    log.add(.page, problem: true, "runtimeError: boom")
    check("REQ-019 a message of an earlier generation is kept but not counted", log.entries.count == 2 && log.problems == 1)

    // The environment file: older files have no switch and repair by themselves; the switch survives a round trip.
    var environment = StudioEnvironmentSpec()
    let plain = (try? JSONEncoder().encode(environment)) ?? Data()
    check("REQ-020 an environment without the switch has no field and repairs automatically",
          !String(decoding: plain, as: UTF8.self).contains("autoRepair") && environment.repairsAutomatically
            && ((try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: plain))?.repairsAutomatically ?? false))
    environment.autoRepair = false
    let off = (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: (try? JSONEncoder().encode(environment)) ?? Data()))
    check("REQ-020 the switch off survives a round trip", off?.autoRepair == false && off?.repairsAutomatically == false)

    }
}

extension UIStudioLifetimeHostTests {
    @MainActor func testAuthMock() throws {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { XCTFail("\(name): \(detail())") }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mv-studio-aux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
func verifiesWithTestKey(_ token: String) -> Bool {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    let mac = HMAC<SHA256>.authenticationCode(for: Data("\(parts[0]).\(parts[1])".utf8), using: SymmetricKey(data: Data(StudioTestJWT.key.utf8)))
    let signature = Data(mac).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return signature == parts[2]
}


    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let expectedDate = "2023-11-14T22:13:20Z"
    let dateErrors = OSAllocatedUnfairLock(initialState: 0)
    DispatchQueue.concurrentPerform(iterations: 200) { _ in
        if StudioAuthMock.iso(date) != expectedDate { dateErrors.withLock { $0 += 1 } }
    }
    check("concurrent auth responses format their dates consistently", dateErrors.withLock { $0 } == 0)
    let app = "http://localhost:3000"
    let connections = [
        StudioServerConnection(variable: "SUPABASE_INTERNAL_URL", origin: "http://kong:8000", basePath: "", mode: .simulated, foundIn: ".env"),
        StudioServerConnection(variable: "NEXT_PUBLIC_SUPABASE_URL", origin: "http://supabase.example.test", basePath: "", mode: .simulated, foundIn: ".env"),
        StudioServerConnection(variable: "API_URL", origin: "http://api.example.test", basePath: "/v1", mode: .simulated, foundIn: ".env"),
    ]
    let mock = StudioAuthMock(connections: connections)
    check("REQ-010 the mock answers every simulated Supabase address, the public one first",
          mock.bases == ["http://supabase.example.test/auth/v1", "http://kong:8000/auth/v1"] && mock.issuer == "http://supabase.example.test/auth/v1",
          "\(mock.bases)")

    let scenario = StudioScenario(id: "signed-in", name: "Signed in", kind: .populated)
    let testTime = scenario.testTime.timeIntervalSince1970
    var sim = StudioSimulator(spec: StudioEnvironmentSpec(), scenario: scenario, appOrigin: app)
    sim.authMock = mock
    var counter = 0
    func send(_ method: String, _ url: String, body: StudioJSON? = nil, headers: [String: String] = [:]) -> (StudioSimOutcome, StudioSimResponse?, StudioJSON?) {
        counter += 1
        let outcome = sim.handle(StudioHTTPRequest(method: method, url: URL(string: url)!, headers: headers, body: body?.text, requestId: "auth\(counter)"))
        guard case .respond(let response, _) = outcome else { return (outcome, nil, nil) }
        return (outcome, response, response.body.flatMap { StudioJSON(text: $0) })
    }
    let base = "http://supabase.example.test/auth/v1"

    // Sign-in with any input.
    let (signIn, signInResponse, session) = send("POST", base + "/token?grant_type=password",
                                                 body: .object(["email": .string("anyone@example.test"), "password": .string("wrong")]))
    let token = session?["access_token"]?.stringValue ?? ""
    let claims = StudioTestJWT.claims(of: token) ?? [:]
    check("REQ-010 a password sign-in with any e-mail and password signs in the scenario's test user",
          signInResponse?.status == 200 && session?["token_type"]?.stringValue == "bearer"
          && session?["user"]?["email"]?.stringValue == "tester@example.test" && session?["user"]?["id"]?.stringValue == "user-1"
          && session?["refresh_token"]?.stringValue == StudioAuthMock.refreshToken, "\(signInResponse?.body ?? "nil")")
    if case .respond(_, let rule) = signIn { check("REQ-010 the answer names the built-in mock-up", rule == StudioAuthMock.ruleID, rule) }
    check("REQ-010 the session is valid for a year from the test time", session?["expires_at"]?.identityKey == String(Int(testTime + 365 * 24 * 3600))
          && session?["expires_in"]?.identityKey == String(365 * 24 * 3600), "\(String(describing: session?["expires_at"]))")
    check("REQ-010 the access token is a JWT signed with the test key", verifiesWithTestKey(token), token)
    check("REQ-010 the access token carries Supabase's claims and the scenario's role in app_metadata",
          claims["sub"]?.stringValue == "user-1" && claims["role"]?.stringValue == "authenticated" && claims["aud"]?.stringValue == "authenticated"
          && claims["email"]?.stringValue == "tester@example.test" && claims["app_metadata"]?["role"]?.stringValue == "member"
          && claims["iss"]?.stringValue == base && claims["exp"]?.identityKey == String(Int(testTime + 365 * 24 * 3600)),
          "\(claims)")
    let (_, emptyResponse, emptySession) = send("POST", "http://kong:8000/auth/v1/token?grant_type=password",
                                                body: .object(["email": .string(""), "password": .string("")]))
    check("REQ-010 an empty form signs in too, at the server's own address, with the same token",
          emptyResponse?.status == 200 && emptySession?["access_token"]?.stringValue == token)
    let (_, refreshed, refreshSession) = send("POST", base + "/token?grant_type=refresh_token", body: .object(["refresh_token": .string("anything")]))
    check("REQ-010 a refresh with any refresh token gives the session again", refreshed?.status == 200
          && refreshSession?["access_token"]?.stringValue == token && refreshSession?["refresh_token"]?.stringValue == StudioAuthMock.refreshToken)
    let (_, exchanged, exchangedSession) = send("POST", base + "/token?grant_type=pkce",
                                                body: .object(["auth_code": .string("whatever"), "code_verifier": .string("v")]))
    check("REQ-010 an OAuth code exchange (PKCE) gives the session", exchanged?.status == 200 && exchangedSession?["user"]?["id"]?.stringValue == "user-1")
    let (_, idToken, _) = send("POST", base + "/token?grant_type=id_token", body: .object(["provider": .string("apple"), "id_token": .string("x")]))
    check("REQ-010 an ID-token sign-in passes", idToken?.status == 200)

    // The current user.
    let (_, noBearer, _) = send("GET", base + "/user")
    let anonKey = StudioConnections.testValue(for: "SUPABASE_ANON_KEY", real: StudioTestJWT.make(["role": .string("anon")]))
    let (_, anon, _) = send("GET", base + "/user", headers: ["authorization": "Bearer " + anonKey])
    let (_, signedIn, user) = send("GET", base + "/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 GET /user: 401 without a token, 403 with the API key, the user with the session's token",
          noBearer?.status == 401 && anon?.status == 403 && signedIn?.status == 200 && user?["email"]?.stringValue == "tester@example.test"
          && user?["aud"]?.stringValue == "authenticated" && user?["identities"]?.arrayValue?.count == 1,
          "\(noBearer?.status ?? 0) \(anon?.status ?? 0) \(signedIn?.status ?? 0)")

    // Sign-up data and profile changes last until Reset.
    let (_, signedUp, signUpSession) = send("POST", base + "/signup", body: .object(["email": .string("new@example.test"), "password": .string("x"),
                                                                                    "data": .object(["first_name": .string("Ann")])]))
    check("REQ-010 a sign-up is confirmed at once and keeps its data", signedUp?.status == 200
          && signUpSession?["access_token"]?.stringValue?.isEmpty == false
          && signUpSession?["user"]?["user_metadata"]?["first_name"]?.stringValue == "Ann")
    let (_, updated, updatedUser) = send("PUT", base + "/user", body: .object(["data": .object(["city": .string("Oslo")]), "password": .string("new")]),
                                         headers: ["authorization": "Bearer " + token])
    let (_, _, reread) = send("GET", base + "/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 PUT /user merges into the test user", updated?.status == 200 && updatedUser?["user_metadata"]?["city"]?.stringValue == "Oslo"
          && reread?["user_metadata"]?["first_name"]?.stringValue == "Ann" && reread?["user_metadata"]?["city"]?.stringValue == "Oslo")
    sim.reset()
    let (_, _, afterReset) = send("GET", base + "/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 Reset brings back the scenario's user", afterReset?["user_metadata"]?["first_name"] == nil
          && afterReset?["user_metadata"]?["full_name"]?.stringValue == "Test User")

    // Everything else of a sign-in flow.
    let (_, logout, _) = send("POST", base + "/logout?scope=global", headers: ["authorization": "Bearer " + token])
    check("REQ-010 sign-out answers 204", logout?.status == 204 && logout?.body == nil)
    let others = ["/otp", "/recover", "/magiclink", "/resend"].map { send("POST", base + $0, body: .object(["email": .string("a@b.test")])).1 }
    check("REQ-010 one-time codes, password reset, magic links and resends succeed",
          others.allSatisfy { $0?.status == 200 && $0?.body == "{}" }, "\(others.map { $0?.status ?? 0 })")
    let (_, settings, settingsBody) = send("GET", base + "/settings")
    check("REQ-010 the settings enable every provider and sign-up", settings?.status == 200
          && settingsBody?["external"]?["google"] == .bool(true) && settingsBody?["external"]?["email"] == .bool(true)
          && settingsBody?["disable_signup"] == .bool(false) && settingsBody?["mailer_autoconfirm"] == .bool(true))
    let (_, jwks, jwksBody) = send("GET", base + "/.well-known/jwks.json")
    check("REQ-010 the JWKS is empty: the HS256 tokens are checked through GET /user", jwks?.status == 200 && jwksBody?["keys"]?.arrayValue?.isEmpty == true)

    // OAuth: no provider is asked.
    let callback = app + "/auth/callback?next=%2Fdashboard"
    let encoded = callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let (_, authorize, _) = send("GET", base + "/authorize?provider=google&redirect_to=\(encoded)&code_challenge=abc&code_challenge_method=s256")
    check("REQ-010 /authorize redirects back to redirect_to with the test code", authorize?.status == 302
          && authorize?.headers["location"] == callback + "&code=" + StudioAuthMock.code, authorize?.headers["location"] ?? "no location")
    let (_, implicit, _) = send("GET", base + "/authorize?provider=github&redirect_to=\(encoded)")
    let fragment = implicit?.headers["location"].flatMap { URL(string: $0)?.fragment } ?? ""
    check("REQ-010 the implicit flow gets the tokens in the fragment", implicit?.status == 302 && fragment.contains("access_token=" + token)
          && fragment.contains("refresh_token=" + StudioAuthMock.refreshToken), fragment)
    let (_, bare, _) = send("GET", base + "/authorize?provider=google&code_challenge=abc")
    check("REQ-010 /authorize without redirect_to returns to the application", bare?.headers["location"] == app + "/?code=" + StudioAuthMock.code,
          bare?.headers["location"] ?? "none")
    let (_, verify, _) = send("GET", base + "/verify?token=pkce_abc&type=signup&redirect_to=\(encoded)")
    check("REQ-010 an e-mail confirmation link returns to the application with a code", verify?.status == 303
          && verify?.headers["location"] == callback + "&code=" + StudioAuthMock.code, verify?.headers["location"] ?? "none")

    // What the mock does not answer.
    let (admin, _, _) = send("GET", base + "/admin/users")
    if case .unknown = admin {} else { check("REQ-010 an endpoint the mock does not know goes to the rules", false, "\(admin)") }
    let (other, _, _) = send("GET", app + "/api/me")
    if case .unknown = other {} else { check("REQ-010 the application's own requests go to the rules", false, "\(other)") }
    let (_, hosted, _) = send("GET", "https://abcdefgh.supabase.co/auth/v1/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 hosted Supabase is answered too", hosted?.status == 200)
    var keptReal = connections
    keptReal.append(StudioServerConnection(variable: "SUPABASE_URL", origin: "https://abcdefgh.supabase.co", basePath: "", mode: .real, foundIn: ".env"))
    sim.authMock = StudioAuthMock(connections: keptReal)
    let (real, _, _) = send("GET", "https://abcdefgh.supabase.co/auth/v1/user")
    if case .unknown = real {} else { check("REQ-010 a Supabase address the person keeps real is not answered", false, "\(real)") }
    sim.authMock = nil
    let (off, _, _) = send("POST", base + "/token?grant_type=password")
    if case .unknown = off {} else { check("REQ-010 without the mock (no Supabase in the project) the request goes to the rules", false, "\(off)") }

    // Placeholders in fixed answers.
    var spec = StudioEnvironmentSpec()
    let fixed: StudioJSON = .object([
        "token": .string("{{studio.token}}"), "refresh": .string("{{ studio.refreshToken }}"), "user": .string("{{studio.user}}"),
        "email": .string("{{studio.user.email}}"), "greeting": .string("Hi {{studio.user.name}}, it is {{studio.now}}"),
        "expires": .string("{{studio.expiresAtSeconds}}"), "expiresAt": .string("{{studio.expiresAt}}"), "missing": .string("{{studio.user.nope}}"),
        "unknown": .string("{{studio.nope}}"), "list": .array([.string("{{studio.user.id}}")]),
    ])
    spec.rules = [
        StudioRule(id: "login", method: "POST", path: "/api/login", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: fixed, headers: ["X-Token": "Bearer {{studio.token}}"])),
        StudioRule(id: "items", method: "GET", path: "/api/items", operation: .list, entity: "items"),
    ]
    spec.seed = ["items": [.object(["id": .number(1), "name": .string("{{studio.token}}")])]]
    var placeholders = StudioSimulator(spec: spec, scenario: scenario, appOrigin: app)
    placeholders.authMock = mock
    guard case .respond(let login, _) = placeholders.handle(StudioHTTPRequest(method: "POST", url: URL(string: app + "/api/login")!, headers: [:],
                                                                                body: "{}", requestId: "p1")),
          let answer = login.body.flatMap({ StudioJSON(text: $0) }) else {
        return check("REQ-010 a fixed answer with placeholders is answered", false)
    }
    check("REQ-010 {{studio.token}} is the token the built-in Supabase Auth issues", answer["token"]?.stringValue == token
          && login.headers["x-token"] == "Bearer " + token, "\(answer)")
    check("REQ-010 {{studio.user}} is the scenario's user, {{studio.user.<field>}} one of its fields",
          answer["user"]?["name"]?.stringValue == "Test User" && answer["email"]?.stringValue == "tester@example.test"
          && answer["list"]?.arrayValue?.first?.stringValue == "user-1" && answer["missing"] == .null)
    check("REQ-010 times are the test time and a year after it", answer["greeting"]?.stringValue == "Hi Test User, it is 2026-01-15T12:00:00Z"
          && answer["expiresAt"]?.stringValue == "2027-01-15T12:00:00Z" && answer["expires"]?.identityKey == String(Int(testTime + 365 * 24 * 3600))
          && answer["refresh"]?.stringValue == StudioAuthMock.refreshToken, "\(answer)")
    check("REQ-010 an unknown placeholder is left as it is", answer["unknown"]?.stringValue == "{{studio.nope}}")
    guard case .respond(let items, _) = placeholders.handle(StudioHTTPRequest(method: "GET", url: URL(string: app + "/api/items")!, headers: [:],
                                                                                body: nil, requestId: "p2")) else {
        return check("REQ-010 records are answered", false)
    }
    check("REQ-010 records keep their own text: placeholders are for fixed answers", items.body?.contains("{{studio.token}}") == true, items.body ?? "nil")
    check("REQ-010 the preparation prompt names the placeholders", StudioPrompts.preparationSystem.contains("{{studio.user.<field>}}")
          && StudioPrompts.preparationSystem.contains("{{studio.token}}") && StudioPrompts.preparationSystem.contains("add no rules for it"))
    check("REQ-010 a placeholder in text that is not JSON is replaced too",
          StudioPlaceholders.substitute(text: "token={{studio.token}}&u={{studio.user.id}}", placeholders.placeholderValues) == "token=\(token)&u=user-1")

    // The external page returns where the request says.
    func returnURL(_ text: String) -> String? { StudioExternalPage.returnURL(for: URL(string: text)!, appOrigin: app)?.absoluteString }
    check("REQ-010 an OAuth request returns to redirect_uri with a code and its state",
          returnURL("https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fapi%2Fauth%2Fcallback%2Fgoogle"
                    + "&response_type=code&scope=openid%20email&state=s%20t%26u")
          == "http://localhost:3000/api/auth/callback/google?code=markview-test-code&state=s%20t%26u",
          returnURL("https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fcb&response_type=code&state=s%20t%26u") ?? "nil")
    check("REQ-010 the parameters are looked for in order", returnURL("https://idp.example/login?next=%2Fa&redirect_to=http%3A%2F%2Flocalhost%3A3000%2Fb")
          == "http://localhost:3000/b")
    check("REQ-010 a checkout returns to success_url as it is", returnURL("https://checkout.stripe.com/pay?success_url=http%3A%2F%2Flocalhost%3A3000%2Fthanks%3Fsession%3D1")
          == "http://localhost:3000/thanks?session=1")
    check("REQ-010 a path is the application's", returnURL("https://idp.example/login?returnTo=%2Fdashboard%3Ftab%3D2") == "http://localhost:3000/dashboard?tab=2"
          && returnURL("https://idp.example/login?callbackUrl=http%3A%2F%2Flocalhost%3A3000%2Fhome&response_type=code") == "http://localhost:3000/home?code=markview-test-code")
    check("REQ-010 no return address, or one that is not a web address, goes back",
          returnURL("https://idp.example/login") == nil && returnURL("https://idp.example/login?next=%2F%2Fevil.example") == nil
          && returnURL("https://idp.example/login?redirect_uri=javascript%3Aalert(1)") == nil && returnURL("https://idp.example/login?next=") == nil)
    let page = StudioExternalPage.html(for: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                                       returnTo: URL(string: "http://localhost:3000/cb?code=markview-test-code&state=a\"b"),
                                       user: .object(["email": .string("<b>tester</b>@example.test")]))
    check("REQ-010 the external page says nothing is sent and offers Continue as Test User",
          page.contains("Simulated sign-in / external page — nothing is sent") && page.contains(">Continue as Test User</a>")
          && page.contains("accounts.google.com") && page.contains("href=\"http://localhost:3000/cb?code=markview-test-code&amp;state=a%22b\""), page)
    check("REQ-010 the external page escapes what it shows", page.contains("&lt;b&gt;tester&lt;/b&gt;@example.test") && !page.contains("<b>tester"))
    check("REQ-010 without a return address Continue goes back", StudioExternalPage.html(for: URL(string: "https://example.org/pay")!, returnTo: nil,
                                                                                         user: .object([:])).contains("history.back()"))

    // Which projects get the mock, and the signing secret.
    let projects = tmp.appendingPathComponent("auth-projects")
    func write(_ path: String, _ json: [String: Any]) {
        let url = projects.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: json).write(to: url)
    }
    write("direct/package.json", ["dependencies": ["@supabase/ssr": "0.8.0", "next": "15.0.0"]])
    write("plain/package.json", ["dependencies": ["next": "15.0.0"]])
    write("mono/apps/web/package.json", ["dependencies": ["@acme/auth": "workspace:*"]])
    write("mono/packages/auth/package.json", ["name": "@acme/auth", "dependencies": ["@supabase/supabase-js": "2.99.3"]])
    check("REQ-010 a project that depends on @supabase/ is a Supabase project, directly or through a workspace package",
          StudioAuthMock.usesSupabase(appFolder: projects.appendingPathComponent("direct"), root: projects.appendingPathComponent("direct"))
          && !StudioAuthMock.usesSupabase(appFolder: projects.appendingPathComponent("plain"), root: projects.appendingPathComponent("plain"))
          && StudioAuthMock.usesSupabase(appFolder: projects.appendingPathComponent("mono/apps/web"), root: projects.appendingPathComponent("mono")))
    check("REQ-010 a JWT signing secret's test value is the test key, so a server verifies the mock's tokens",
          StudioConnections.testValue(for: "SUPABASE_JWT_SECRET", real: "a-real-secret") == StudioTestJWT.key
          && StudioConnections.testValue(for: "JWT_SECRET", real: nil) == StudioTestJWT.key
          && StudioConnections.testValue(for: "API_SECRET", real: "x") == "markview-test-api-secret")

    }
    @MainActor func testScreenBook() throws {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { XCTFail("\(name): \(detail())") }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mv-studio-aux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

    func screen(_ name: String, route: String = "/x", selector: String = "#x", source: String = "src/x.tsx: X", main: Bool? = nil) -> StudioScreen {
        StudioScreen(name: name, route: route, selector: selector, description: "The \(name) screen", instructions: "Open it.", source: source, main: main)
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = screen("Home", route: "/", selector: "#home", source: "src/Home.tsx: Home; src/api/home.ts", main: true)
    let accounts = screen("Accounts", route: "/accounts", selector: "#accounts", source: "src/pages/Accounts.tsx", main: true)
    let about = screen("About", route: "/about", selector: "#about", source: "src/About.tsx", main: false)

    var book = StudioScreenBook(appFolder: "web")
    book.merge(found: [home, accounts, about], now: now)
    check("REQ-021 a new listing makes an empty entry per screen", book.entries.count == 3 && book.discovered == now
          && book.entries.allSatisfy { $0.scenarioID == nil && $0.status == nil })
    check("REQ-021 the main screens are the marked ones, in order", book.main.map(\.screen.name) == ["Home", "Accounts"])
    var unmarked = StudioScreenBook()
    unmarked.merge(found: (1...12).map { screen("S\($0)", route: "/s\($0)", selector: "#s\($0)") }, now: now)
    check("REQ-021 without a mark the first eight are the main ones", unmarked.main.count == StudioScreenBook.mainLimit && unmarked.main.first?.screen.name == "S1")
    var marked = StudioScreenBook()
    marked.merge(found: (1...12).map { screen("S\($0)", route: "/s\($0)", selector: "#s\($0)", main: true) }, now: now)
    check("REQ-021 never more than eight are prepared ahead, whatever the assistant marked", marked.main.count == StudioScreenBook.mainLimit)

    // A scenario id is stable for a screen, a legal file name, never a built-in id and different for screens of one name.
    let id = StudioScreenBook.scenarioID(for: home)
    check("REQ-021 the scenario id of a screen is stable and a safe file name",
          id == StudioScreenBook.scenarioID(for: home) && id.hasPrefix("screen-home-") && id == StudioStore.safeID(id) && !id.hasPrefix("builtin"), id)
    check("REQ-021 two screens with one name get two scenario ids",
          StudioScreenBook.scenarioID(for: screen("Home", route: "/a")) != StudioScreenBook.scenarioID(for: screen("Home", route: "/b")))
    check("REQ-021 a long or odd name still gives a legal id", StudioStore.safeID(StudioScreenBook.scenarioID(for: screen("Счёт / Accounts: " + String(repeating: "x", count: 200)))) == StudioScreenBook.scenarioID(for: screen("Счёт / Accounts: " + String(repeating: "x", count: 200))))

    // The status the menu shows.
    func state(_ entry: StudioScreenBook.Entry, preparing: Set<String> = [], current: [String: String] = [:]) -> StudioScreenBook.State {
        book.state(of: entry, preparing: preparing, current: current)
    }
    let first = book.entries[0]
    check("REQ-021 a screen nothing was prepared for is not prepared", state(first) == .notPrepared)
    check("REQ-021 a screen being prepared says so", state(first, preparing: [first.id]) == .preparing)
    book.markPrepared(first.id, scenarioID: id, sources: ["src/Home.tsx": "aaa", "src/api/home.ts": "bbb"], now: now)
    check("REQ-021 a saved scenario nobody opened is prepared and opens at once",
          state(book.entries[0]) == .prepared && state(book.entries[0]).opensAtOnce && book.entries[0].preparedAt == now)
    book.markVerified(first.id, now: now)
    check("REQ-021 a scenario that reached its screen is ready", state(book.entries[0]) == .ready && book.entries[0].verifiedAt == now)
    check("REQ-021 unchanged sources keep it ready", state(book.entries[0], current: ["src/Home.tsx": "aaa", "src/api/home.ts": "bbb"]) == .ready)
    check("REQ-021 a changed source file makes it need a refresh", state(book.entries[0], current: ["src/Home.tsx": "zzz", "src/api/home.ts": "bbb"]) == .needsRefresh)
    check("REQ-021 a deleted source file does too", state(book.entries[0], current: ["src/Home.tsx": "aaa", "src/api/home.ts": "deleted"]) == .needsRefresh)
    check("REQ-021 hashes not read yet are not a change", state(book.entries[0], current: [:]) == .ready)
    book.markFailed(accounts.id, "The scenario was refused: x")
    check("REQ-021 a failed screen says so and does not open at once", state(book.entries[1]) == .failed && !state(book.entries[1]).opensAtOnce && book.entries[1].failure?.hasPrefix("The scenario was refused") == true)

    // What is prepared ahead: only the main ones nothing was prepared for or whose sources changed; a failure is not retried by itself.
    check("REQ-021 only the main screens that are not ready are prepared ahead",
          book.pending(preparing: [], current: [:]).isEmpty)
    check("REQ-021 a changed source puts a main screen back in the queue",
          book.pending(preparing: [], current: ["src/Home.tsx": "zzz"]).map(\.screen.name) == ["Home"])
    var fresh = StudioScreenBook()
    fresh.merge(found: [home, accounts, about], now: now)
    check("REQ-021 a fresh list queues its main screens, not the others", fresh.pending(preparing: [], current: [:]).map(\.screen.name) == ["Home", "Accounts"])
    check("REQ-021 a screen being prepared is not queued twice", fresh.pending(preparing: [fresh.entries[0].id], current: [:]).map(\.screen.name) == ["Accounts"])

    // A new listing keeps what is prepared and drops what is gone.
    var relisted = book
    let renamed = screen("Home", route: "/", selector: "#home", source: "src/Home.tsx: Home; src/api/home.ts", main: true)
    var changedText = renamed
    changedText.description = "The home screen, now with a banner"
    relisted.merge(found: [changedText, about, screen("Billing", route: "/billing", selector: "#billing", main: true)], now: now.addingTimeInterval(60))
    check("REQ-021 a new listing keeps the scenario of a screen that is still there", relisted.entries.first?.scenarioID == id)
    check("REQ-021 a screen whose description changed is no longer verified, its scenario stays",
          relisted.entries.first?.status == .prepared && relisted.entries.first?.verifiedAt == nil)
    check("REQ-021 screens that are gone are dropped and new ones are empty",
          relisted.entries.map(\.screen.name) == ["Home", "About", "Billing"] && relisted.entries[2].scenarioID == nil)
    var same = book
    same.merge(found: [home, accounts, about], now: now.addingTimeInterval(60))
    check("REQ-021 the same listing changes nothing but the date", same.entries == book.entries && same.discovered == now.addingTimeInterval(60))

    // The evidence a screen names.
    check("REQ-021 the source files are read from the evidence text",
          StudioScreenBook.sourcePaths(of: home) == ["src/Home.tsx", "src/api/home.ts"], "\(StudioScreenBook.sourcePaths(of: home))")
    check("REQ-021 a path outside the project is not hashed",
          StudioScreenBook.sourcePaths(of: screen("A", source: "/etc/passwd.json; ../../secret.ts; ~/key.json; web/ok.tsx")) == ["web/ok.tsx"],
          "\(StudioScreenBook.sourcePaths(of: screen("A", source: "/etc/passwd.json; ../../secret.ts; ~/key.json; web/ok.tsx")))")
    check("REQ-021 at most eight sources are followed", StudioScreenBook.sourcePaths(of: screen("A", source: (1...20).map { "src/f\($0).ts" }.joined(separator: ", "))).count == 8)
    check("REQ-021 evidence without a file name names no source, so the screen is never stale",
          StudioScreenBook.sourcePaths(of: screen("A", source: "the checkout component")).isEmpty
            && !StudioScreenBook.isStale(StudioScreenBook.Entry(screen: screen("A"), scenarioID: "s", status: .prepared, sources: [:]), current: ["x": "y"]))

    // The file: round trip, an older list without the new fields, a newer version, and where it lives.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = (try? encoder.encode(book)) ?? Data()
    check("REQ-021 the list survives a round trip", (try? decoder.decode(StudioScreenBook.self, from: data)) == book)
    let oldScreens = ##"{"version":1,"appFolder":"","entries":[{"screen":{"name":"Home","route":"/","selector":"#h","description":"d","instructions":"i","source":"s"}}]}"##
    let old = try? decoder.decode(StudioScreenBook.self, from: Data(oldScreens.utf8))
    check("REQ-021 a list written before main and the statuses still decodes", old?.entries.first?.screen.main == nil && old?.entries.first?.status == nil)

    let root = tmp.appendingPathComponent("screens-store")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    check("REQ-021 the project's own application has screens.json, another folder its own file",
          StudioStore.screensURL(root, appFolder: "").lastPathComponent == "screens.json"
            && StudioStore.screensURL(root, appFolder: ".").lastPathComponent == "screens.json"
            && StudioStore.screensURL(root, appFolder: "apps/web").lastPathComponent == "screens-apps-web.json"
            && StudioStore.screensURL(root, appFolder: "").deletingLastPathComponent().path.hasSuffix(".markview/studio"))
    try? StudioStore.saveScreenBook(book, root: root)
    let loaded = StudioStore.loadScreenBook(root, appFolder: "web")
    check("REQ-021 the saved list is read back", loaded?.entries.count == 3 && loaded?.entries.first?.scenarioID == id)
    check("REQ-021 another application folder does not see it", StudioStore.loadScreenBook(root, appFolder: "api") == nil)
    var newer = book
    newer.version = StudioScreenBook.currentVersion + 1
    try? StudioStore.saveScreenBook(newer, root: root)
    check("REQ-021 a list of a newer version is ignored, not misread", StudioStore.loadScreenBook(root, appFolder: "web") == nil)

    // The prompt and the schema ask for the main mark; a list without it still reads.
    let rows: [[String: Any]] = [["name": "Home", "route": "/", "selector": "#h", "description": "d", "instructions": "i", "source": "s", "main": true],
                                 ["name": "About", "route": "/about", "selector": "#a", "description": "d", "instructions": "i", "source": "s"]]
    let parsed = StudioPrompts.screens(from: ["screens": rows, "notes": ""])
    check("REQ-021 the main mark is read, and its absence is not an error", parsed.count == 2 && parsed[0].main == true && parsed[1].main == nil)
    let schema = StudioPrompts.screensSchema
    let properties = ((((schema["properties"] as? [String: Any])?["screens"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    check("REQ-021 the screens schema asks for the mark", properties["main"] != nil && StudioPrompts.screensSystem.contains("at most 8"))

    // A route with a placeholder names no page to load, so it is no page to expect.
    func screen(_ route: String) -> StudioScreen {
        StudioScreen(name: "S", route: route, selector: "#s", description: "d", instructions: "i", source: "s")
    }
    check("REQ-021 routes with a placeholder are told from concrete ones",
          ["/#/products/<productId>/sources", "/items/:id", "/post/{slug}", "/blog/[id]", "/#/accounts/<id>"].allSatisfy { screen($0).hasPlaceholderRoute && screen($0).expectedPath == nil }
            && ["/#/accounts", "/", "/index.html", "/a/b?x=1#top", "/#/products/prod-01/sources", "/tags/a:b"].allSatisfy { !screen($0).hasPlaceholderRoute && screen($0).expectedPath == $0 })

    // A prepared screen opens directly when its contracts are still the environment's; the records inside are not what decides it.
    var brokenSeed = StudioEnvironmentSpec()
    brokenSeed.entities = [StudioEntity(name: "items", fields: [StudioField(name: "name", type: "string", required: true)])]
    brokenSeed.seed = ["items": [.object(["id": .number(1)])]]
    var made = StudioScenario(id: "screen-home", name: "Home", kind: .custom)
    made.contractFingerprint = StudioScenarioCompatibility.fingerprint(made, spec: brokenSeed)
    check("REQ-021 a scenario made against the current contracts is current although the seed breaks its entity",
          StudioScenarioCompatibility.isCurrent(made, spec: brokenSeed) && !StudioScenarioCompatibility.problems(made, spec: brokenSeed).isEmpty)
    var changed = brokenSeed
    // The fingerprint covers the entities the scenario's data holds: making `name` optional is a changed contract.
    changed.entities = [StudioEntity(name: "items", fields: [StudioField(name: "name", type: "string", required: false)])]
    check("REQ-021 a scenario whose contracts changed is no longer current", !StudioScenarioCompatibility.isCurrent(made, spec: changed))
    made.contractFingerprint = ""
    check("REQ-021 a scenario saved without a fingerprint is treated as current", StudioScenarioCompatibility.isCurrent(made, spec: changed))

    }
    @MainActor func testEnvelopes() throws {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { XCTFail("\(name): \(detail())") }
        }

    let ipc = "http://electron.ipc/ppd/invoke/"
    let app = "http://localhost:5173"
    var counter = 0
    func call(_ method: String, _ url: String, body: String? = nil) -> StudioHTTPRequest {
        counter += 1
        return StudioHTTPRequest(method: method, url: URL(string: url)!, headers: [:], body: body, requestId: "envelope-\(counter)")
    }
    func answer(_ outcome: StudioSimOutcome) -> (status: Int, body: StudioJSON?) {
        guard case .respond(let response, _) = outcome else { return (-1, nil) }
        return (response.status, response.body.flatMap { StudioJSON(text: $0) })
    }
    func product(_ id: Int, _ name: String) -> StudioJSON { .object(["id": .number(Double(id)), "name": .string(name)]) }

    var spec = StudioEnvironmentSpec()
    spec.entities = [
        StudioEntity(name: "products", fields: [StudioField(name: "name", type: "string", required: true)]),
        StudioEntity(name: "agentQuestions", idField: "accountId", fields: [StudioField(name: "text", type: "string")]),
    ]
    spec.seed = [
        "products": [product(1, "Atlas"), product(2, "Beacon")],
        "agentQuestions": [.object(["accountId": .string("a1"), "text": .string("Solve the CAPTCHA")]),
                           .object(["accountId": .string("a2"), "text": .string("Confirm the email")])],
    ]
    spec.rules = [
        StudioRule(id: "products-list", method: "POST", path: ipc + "products.list", operation: .list, entity: "products", envelope: "result"),
        StudioRule(id: "products-get", method: "POST", path: ipc + "products.get", operation: .get, entity: "products", idParam: "id"),
        StudioRule(id: "products-create", method: "POST", path: ipc + "products.create", operation: .create, entity: "products"),
        StudioRule(id: "questions-list", method: "POST", path: ipc + "agent.questions", operation: .list, entity: "agentQuestions"),
        StudioRule(id: "agent-answer", method: "POST", path: ipc + "agent.answer", operation: .delete, entity: "agentQuestions", idParam: "accountId"),
        StudioRule(id: "engines", method: "POST", path: ipc + "engines.list", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": .array([.string("claude")])]))),
        StudioRule(id: "web-list", method: "GET", path: "/api/items", operation: .list, entity: "products"),
        StudioRule(id: "plain-list", method: "GET", path: "/other/items", operation: .list, entity: "products"),
    ]
    let ipcEnvelope = StudioEnvelope(prefix: ipc, resultKey: "result", successFields: ["ok": .bool(true)],
                                     failure: .object(["ok": .bool(false), "error": .object(["code": .string("E{{status}}"), "message": .string("{{message}}")])]))
    var enveloped = spec
    enveloped.envelopes = [ipcEnvelope,
                           StudioEnvelope(prefix: "/api/", resultKey: "data", successFields: ["success": .bool(true)])]
    func simulator(_ spec: StudioEnvironmentSpec, overrides: [StudioOverride] = []) -> StudioSimulator {
        var scenario = StudioScenario(id: "populated", name: "Populated", kind: .populated)
        scenario.overrides = overrides
        return StudioSimulator(spec: spec, scenario: scenario, appOrigin: app)
    }

    // The case of a real project: a list rule that says `envelope: "result"` answered {result: [...]} without `ok`.
    var plain = simulator(spec)
    let before = answer(plain.handle(call("POST", ipc + "products.list", body: "null")))
    check("DEC-015 without an envelope the list is wrapped only in its own key, with no ok", before.body?["ok"] == nil && before.body?["result"]?.arrayValue?.count == 2)

    var sim = simulator(enveloped)
    let list = answer(sim.handle(call("POST", ipc + "products.list", body: "null")))
    check("DEC-015 a list whose rule already holds it under the result key gains the fields, not a second wrapper",
          list.status == 200 && list.body?["ok"] == .bool(true) && list.body?["result"]?.arrayValue?.count == 2, "\(list)")
    let questions = answer(sim.handle(call("POST", ipc + "agent.questions")))
    check("DEC-015 a list with no key of its own goes under the result key", questions.body?["ok"] == .bool(true) && questions.body?["result"]?.arrayValue?.count == 2, "\(questions)")

    // An IPC call names its record in the body.
    let get = answer(sim.handle(call("POST", ipc + "products.get", body: #"{"id": 2}"#)))
    check("DEC-015 a get names its record in the body", get.body?["ok"] == .bool(true) && get.body?["result"]?["name"] == .string("Beacon"), "\(get)")
    let missing = answer(sim.handle(call("POST", ipc + "products.get", body: #"{"id": 9}"#)))
    check("DEC-015 a failure uses the failure template with the status and the message",
          missing.status == 404 && missing.body?["ok"] == .bool(false) && missing.body?["error"]?["code"] == .string("E404")
            && missing.body?["error"]?["message"]?.stringValue?.contains("was not found") == true, "\(missing)")
    let created = answer(sim.handle(call("POST", ipc + "products.create", body: #"{"name": "Comet"}"#)))
    check("DEC-015 a create is wrapped", created.status == 201 && created.body?["ok"] == .bool(true) && created.body?["result"]?["name"] == .string("Comet"), "\(created)")

    // A write that resolves what another request lists: the answer removes the question and the list shows it.
    let dismissed = answer(sim.handle(call("POST", ipc + "agent.answer", body: #"{"accountId": "a1", "answer": "done"}"#)))
    check("DEC-015 a delete has no body, so it answers ok with a null result and status 200",
          dismissed.status == 200 && dismissed.body?["ok"] == .bool(true) && dismissed.body?["result"]?.isNull == true, "\(dismissed)")
    let after = answer(sim.handle(call("POST", ipc + "agent.questions")))
    check("DEC-015 the answered question is gone from the list and the other stays",
          after.body?["result"]?.arrayValue?.count == 1 && after.body?["result"]?.arrayValue?.first?["accountId"] == .string("a2"), "\(after)")
    let again = answer(sim.handle(call("POST", ipc + "agent.answer", body: #"{"accountId": "a1", "answer": "done"}"#)))
    check("DEC-015 answering a question that is gone fails in the application's shape", again.body?["ok"] == .bool(false), "\(again)")

    // What is written as the application sees it stays as it is.
    let engines = answer(sim.handle(call("POST", ipc + "engines.list")))
    check("DEC-015 a fixed answer is never wrapped again", engines.body?["ok"] == .bool(true) && engines.body?["result"] == .array([.string("claude")]), "\(engines)")
    var overridden = simulator(enveloped, overrides: [StudioOverride(ruleId: "products-list", status: 500, body: .object(["boom": .bool(true)]))])
    let boom = answer(overridden.handle(call("POST", ipc + "products.list")))
    check("DEC-015 an override's body is verbatim", boom.status == 500 && boom.body == .object(["boom": .bool(true)]), "\(boom)")
    var emptied = simulator(enveloped, overrides: [StudioOverride(ruleId: "products-list", empty: true)])
    let none = answer(emptied.handle(call("POST", ipc + "products.list")))
    check("DEC-015 an empty list is wrapped too", none.body?["ok"] == .bool(true) && none.body?["result"] == .array([]), "\(none)")

    // Two services, the longest prefix, and a rule no envelope covers.
    let web = answer(sim.handle(call("GET", app + "/api/items")))
    check("DEC-015 another prefix has its own envelope", web.body?["success"] == .bool(true) && web.body?["data"]?.arrayValue?.count == 3, "\(web)")
    let other = answer(sim.handle(call("GET", app + "/other/items")))
    check("DEC-015 a rule outside every prefix answers plain", other.body?.arrayValue?.count == 3, "\(other)")
    var nested = enveloped
    nested.envelopes = (nested.envelopes ?? []) + [StudioEnvelope(prefix: ipc + "agent.", resultKey: "payload")]
    check("DEC-015 the longest matching prefix wins", nested.envelope(forPath: ipc + "agent.answer")?.resultKey == "payload"
          && nested.envelope(forPath: ipc + "products.list")?.resultKey == "result")

    // The path wins over the body, and a rule that names no parameter never reads the body.
    var routed = enveloped
    routed.envelopes = nil
    routed.rules = [StudioRule(id: "rename", method: "PATCH", path: "/api/projects/:id", operation: .update, entity: "products"),
                    StudioRule(id: "loose", method: "POST", path: "/api/loose", operation: .get, entity: "products")]
    var routedSim = simulator(routed)
    let renamed = answer(routedSim.handle(call("PATCH", app + "/api/projects/1", body: #"{"id": 2, "name": "Renamed"}"#)))
    check("DEC-015 a path parameter wins over the same name in the body", renamed.body?["name"] == .string("Renamed"), "\(renamed)")
    let loose = answer(routedSim.handle(call("POST", app + "/api/loose", body: #"{"id": 2}"#)))
    check("DEC-015 a rule with no idParam does not read the body", loose.status == 404, "\(loose)")

    // Files written before the field still open, and a damaged envelope is ignored, not fatal.
    func file(_ edit: (inout [String: Any]) -> Void) -> Data {
        var object = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(StudioEnvironmentSpec()))) as? [String: Any]) ?? [:]
        edit(&object)
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
    let oldFile = file { $0.removeValue(forKey: "envelopes") }
    let decoded = try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: oldFile)
    check("DEC-015 an environment without envelopes decodes as not looked at yet", decoded != nil && decoded?.envelopes == nil)
    let round = (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: JSONEncoder().encode(enveloped)))?.envelopes
    check("DEC-015 envelopes survive a round trip", round == enveloped.envelopes)
    let damaged = file { $0["envelopes"] = [["prefix": 5], ["prefix": "/api/", "resultKey": "data"]] }
    let lenient = try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: damaged)
    check("DEC-015 a damaged envelope is not usable and the others still read", lenient?.envelopes?.count == 2 && lenient?.envelopes?.first?.isUsable == false
          && lenient?.envelope(forPath: "/api/x")?.resultKey == "data")
    // The assistant's side: the answer is parsed, the validator refuses a template in `envelope`, and an envelope-only answer registers.
    let structured: [String: Any] = [
        "unsupported": false, "reason": "", "assumptions": [],
        "entities": [["name": "agentQuestions", "idField": "accountId", "fields": [["name": "text", "type": "string", "required": false, "enumValues": [], "references": ""]]]],
        "records": [],
        "rules": [["id": "agent-answer", "method": "POST", "path": ipc + "agent.answer", "operation": "delete", "entity": "agentQuestions", "envelope": "",
                   "idParam": "accountId", "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "contract", "detail": "api.ts"]]]],
        "envelopes": [["prefix": ipc, "resultKey": "result", "successFields": #"{"ok": true}"#,
                       "failure": #"{"ok": false, "error": {"code": "{{status}}", "message": "{{message}}"}}"#]],
    ]
    let parsed = StudioPrompts.proposal(from: structured)
    check("DEC-015 the assistant's answer carries the envelope and the id parameter",
          parsed?.envelopes?.first?.prefix == ipc && parsed?.envelopes?.first?.resultKey == "result"
            && parsed?.envelopes?.first?.successFields == ["ok": .bool(true)]
            && parsed?.envelopes?.first?.failure?["error"]?["code"] == .string("{{status}}") && parsed?.rules.first?.idParam == "accountId", "\(String(describing: parsed?.envelopes))")
    let properties = StudioPrompts.preparationSchema["properties"] as? [String: Any]
    let ruleProperties = (((properties?["rules"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    check("DEC-015 the schema offers envelopes and idParam", properties?["envelopes"] != nil && ruleProperties["idParam"] != nil)
    check("DEC-015 the prompt says what envelope means and where the transport's wrapper goes",
          StudioPrompts.preparationSystem.contains("`envelopes`") && StudioPrompts.preparationSystem.contains("never a template")
            && StudioPrompts.preparationSystem.contains("`idParam`") && StudioPrompts.preparationSystem.contains("Never answer such a list with a fixed"))

    var registry = simulator(StudioEnvironmentSpec())
    var templated = StudioProposal()
    templated.entities = [StudioEntity(name: "things", fields: [])]
    var listRule = StudioRule(id: "things", method: "POST", path: ipc + "things.list", operation: .list, entity: "things")
    listRule.envelope = #"{"ok":true,"result":{{data}}}"#
    templated.rules = [listRule]
    let refused = registry.register(templated)
    check("DEC-015 a template in `envelope` is refused with the way out", refused.contains { $0.contains("`envelopes`") }, "\(refused)")
    listRule.envelope = "result"
    templated.rules = [listRule]
    check("DEC-015 a plain key is accepted", registry.register(templated).isEmpty)
    var bodyID = StudioProposal()
    bodyID.rules = [StudioRule(id: "thing-get", method: "POST", path: ipc + "things.get", operation: .get, entity: "things", idParam: "thingId"),
                    StudioRule(id: "thing-drop", method: "POST", path: ipc + "things.drop", operation: .delete, entity: "things")]
    let noID = registry.register(bodyID)
    check("DEC-015 a get needs an id in the path or an idParam, and only the one without is refused",
          noID.count == 1 && noID[0].contains("thing-drop"), "\(noID)")
    var onlyEnvelope = StudioProposal()
    onlyEnvelope.envelopes = [ipcEnvelope]
    check("DEC-015 an answer that is only an envelope registers", registry.register(onlyEnvelope).isEmpty && registry.spec.envelopes == [ipcEnvelope])
    var replacement = StudioProposal()
    replacement.envelopes = [StudioEnvelope(prefix: ipc, resultKey: "data"), StudioEnvelope(prefix: "/api/", resultKey: "data")]
    _ = registry.register(replacement)
    check("DEC-015 an envelope with the same prefix is replaced, another added",
          registry.spec.envelopes?.count == 2 && registry.spec.envelope(forPath: ipc + "x")?.resultKey == "data")
    var nothing = StudioProposal()
    nothing.envelopes = []
    var looked = simulator(StudioEnvironmentSpec())
    check("DEC-015 \"none\" is an answer: an empty list is kept, so the review is not repeated",
          looked.register(nothing).isEmpty && looked.spec.envelopes == [])
    var badKey = StudioProposal()
    badKey.envelopes = [StudioEnvelope(prefix: "/api/", resultKey: #"{"a":1}"#)]
    check("DEC-015 a result key that is not a plain name is refused", !looked.register(badKey).isEmpty)

    var empty = StudioEnvironmentSpec()
    empty.envelopes = []
    check("DEC-015 an empty list means none and is kept", (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: JSONEncoder().encode(empty)))?.envelopes == [])
    }
    @MainActor func testEnvironmentReview() throws {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if !condition { XCTFail("\(name): \(detail())") }
        }

    let ipc = "http://electron.ipc/ppd/invoke/"
    func call(_ url: String, body: String? = nil) -> StudioHTTPRequest {
        StudioHTTPRequest(method: "POST", url: URL(string: url)!, headers: [:], body: body, requestId: UUID().uuidString)
    }
    func answer(_ outcome: StudioSimOutcome) -> StudioJSON? {
        guard case .respond(let response, _) = outcome else { return nil }
        return response.body.flatMap { StudioJSON(text: $0) }
    }
    let questions = StudioJSON.array([.object(["accountId": .string("a1"), "text": .string("Solve the CAPTCHA")]),
                                      .object(["accountId": .string("a2"), "text": .string("Confirm the email")])])
    // What a real project had: the pending questions as a fixed answer, the answer as a fixed answer, a list with a template in `envelope`.
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "products", fields: [StudioField(name: "name", type: "string")])]
    spec.seed = ["products": [.object(["id": .number(1), "name": .string("Atlas")])]]
    var templated = StudioRule(id: "products-list", method: "POST", path: ipc + "products.list", operation: .list, entity: "products")
    templated.envelope = #"{"ok":true,"result":{{data}}}"#
    spec.rules = [
        templated,
        StudioRule(id: "agent-questions", method: "POST", path: ipc + "agent.questions", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": questions]))),
        StudioRule(id: "agent-answer", method: "POST", path: ipc + "agent.answer", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": .null]))),
        StudioRule(id: "app-info", method: "POST", path: ipc + "app.info", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": .object(["version": .string("1.0")])]))),
    ]
    spec.channels = [StudioChannel(id: "ipc-events", path: ipc + "onEvent")]
    let simulator = StudioSimulator(spec: spec, scenario: StudioScenario(id: "populated", name: "Populated", kind: .populated), appOrigin: "http://localhost:5173")

    let prompt = StudioReview.prompt(spec: spec, appFolder: "")
    check("DEC-015 the review shows the rules, the start of a fixed body, the entities and the channels",
          prompt.contains("agent-questions") && prompt.contains("[fixed: ") && prompt.contains("Entities: products") && prompt.contains("ipc-events"))
    let required = StudioReview.schema["required"] as? [String] ?? []
    check("DEC-015 the review must answer envelopes, replaces, links and notes, so that nothing to correct is explicit",
          ["envelopes", "replaces", "links", "notes"].allSatisfy(required.contains))
    check("DEC-015 the review prompt carries the preparation rules and its own task",
          StudioReview.system.contains("`envelopes`") && StudioReview.system.contains("`replaces`") && StudioReview.system.contains("`links`"))

    // What a good answer is.
    let structured: [String: Any] = [
        "unsupported": false, "reason": "", "assumptions": [],
        "entities": [["name": "agentQuestions", "idField": "accountId", "fields": [["name": "text", "type": "string", "required": false, "enumValues": [], "references": ""]]]],
        "records": [["entity": "agentQuestions", "json": questions.text]],
        "rules": [["id": "agent-questions-list", "method": "POST", "path": ipc + "agent.questions", "operation": "list", "entity": "agentQuestions", "envelope": "",
                   "idParam": "", "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "contract", "detail": "api.ts"]]],
                  ["id": "agent-answer-delete", "method": "POST", "path": ipc + "agent.answer", "operation": "delete", "entity": "agentQuestions", "envelope": "",
                   "idParam": "accountId", "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "contract", "detail": "api.ts"]]]],
        "envelopes": [["prefix": ipc, "resultKey": "result", "successFields": #"{"ok": true}"#, "failure": ""]],
        "replaces": ["agent-questions", "agent-answer"],
        "links": [["channel": "ipc-events", "entity": "agentQuestions", "message": #"{"type": "changed", "scope": "accounts"}"#],
                  ["channel": "ipc-events", "entity": "agentQuestions", "message": "not json"]],
        "notes": "The questions are state.",
    ]
    guard let outcome = StudioReview.outcome(from: structured) else { check("DEC-015 the review answer is read", false); return }
    check("DEC-015 the review answer is read: rules, envelope, replaced ids, one good link and a note",
          outcome.proposal.rules.count == 2 && outcome.proposal.envelopes?.count == 1 && outcome.replaces == ["agent-questions", "agent-answer"]
            && outcome.links == [StudioReview.Link(channel: "ipc-events", entity: "agentQuestions",
                                                   message: .object(["type": .string("changed"), "scope": .string("accounts")]))]
            && outcome.notes == "The questions are state.")
    var withoutEnvelopes = structured
    withoutEnvelopes.removeValue(forKey: "envelopes")
    check("DEC-015 an answer with no envelopes field means none, never not looked at", StudioReview.outcome(from: withoutEnvelopes)?.proposal.envelopes == [])

    var reviewed = simulator
    let problems = StudioReview.apply(outcome, to: &reviewed)
    check("DEC-015 the review is applied", problems.isEmpty, "\(problems)")
    check("DEC-015 the replaced fixed rules are gone and the new ones stand in their place",
          !reviewed.spec.rules.contains { $0.id == "agent-questions" || $0.id == "agent-answer" }
            && reviewed.spec.rules.contains { $0.id == "agent-questions-list" } && reviewed.spec.rules.contains { $0.id == "app-info" })
    check("DEC-015 a template left in a rule's `envelope` is cleaned", reviewed.spec.rules.first { $0.id == "products-list" }?.envelope == nil)
    check("DEC-015 the environment now knows its envelope", reviewed.spec.envelopes?.first?.resultKey == "result")
    check("DEC-015 the event channel pushes the change when the entity is written",
          reviewed.spec.channels?.first?.links.first?.entity == "agentQuestions" && reviewed.spec.channels?.first?.links.first?.message != nil)

    // What the page sees: the dialog's list shrinks when its button's request is answered.
    var sim = reviewed
    let before = answer(sim.handle(call(ipc + "agent.questions")))
    check("DEC-015 the page lists both questions", before?["ok"] == .bool(true) && before?["result"]?.arrayValue?.count == 2, "\(String(describing: before))")
    let done = answer(sim.handle(call(ipc + "agent.answer", body: #"{"accountId": "a1", "answer": "done"}"#)))
    check("DEC-015 pressing I'm done is answered in the application's shape", done?["ok"] == .bool(true), "\(String(describing: done))")
    let after = answer(sim.handle(call(ipc + "agent.questions")))
    check("DEC-015 the answered question leaves the list", after?["result"]?.arrayValue?.count == 1 && after?["result"]?.arrayValue?.first?["accountId"] == .string("a2"))
    let table = answer(sim.handle(call(ipc + "products.list")))
    check("DEC-015 the list that had a template now answers in the envelope", table?["ok"] == .bool(true) && table?["result"]?.arrayValue?.count == 1, "\(String(describing: table))")
    let info = answer(sim.handle(call(ipc + "app.info")))
    check("DEC-015 a fixed answer that is truly static is untouched", info?["result"]?["version"] == .string("1.0") && info?["ok"] == .bool(true))

    // A refused review changes nothing.
    var broken = outcome
    broken.proposal.rules[0].method = "TRACE"
    var untouched = simulator
    let refused = StudioReview.apply(broken, to: &untouched)
    check("DEC-015 a refused review changes nothing", !refused.isEmpty && untouched.spec == simulator.spec)
    var noEntity = outcome
    noEntity.links = [StudioReview.Link(channel: "ipc-events", entity: "nothing", message: .object([:]))]
    var unlinked = simulator
    check("DEC-015 a link to an undefined entity refuses the review", !StudioReview.apply(noEntity, to: &unlinked).isEmpty && unlinked.spec == simulator.spec)
    var wrongChannel = outcome
    wrongChannel.links = [StudioReview.Link(channel: "no-such", entity: "agentQuestions", message: .object([:]))]
    var onlyChannel = simulator
    check("DEC-015 the application's only raw channel is used when the assistant names another",
          StudioReview.apply(wrongChannel, to: &onlyChannel).isEmpty && onlyChannel.spec.channels?.first?.links.count == 1)
    var two = simulator
    var more = two.spec
    more.channels = (more.channels ?? []) + [StudioChannel(id: "other", path: "/socket")]
    two.replaceSpec(more)
    check("DEC-015 with two raw channels a wrong name is refused", !StudioReview.apply(wrongChannel, to: &two).isEmpty)
    // A scenario naming requests no rule serves: the ones to prepare, once each, none of the served ones.
    let named = [StudioOverride(method: "post", path: ipc + "passport.get", status: 500), StudioOverride(method: "POST", path: ipc + "passport.get", status: 404),
                 StudioOverride(method: "POST", path: ipc + "products.list", empty: true), StudioOverride(ruleId: "app-info", status: 500),
                 StudioOverride(method: "GET", path: "/api/ghost", hang: true), StudioOverride(status: 500)]
    let unserved = StudioContextValidator.unservedRequests(named, spec: spec)
    check("DEC-015 the requests a scenario names without a rule are found once each, served ones and rule ids left out",
          unserved.map { "\($0.method) \($0.path)" } == ["POST " + ipc + "passport.get", "GET /api/ghost"], "\(unserved)")
    // A screen is shown with nothing in front of it.
    let screen = StudioScreen(name: "Products", route: "/#/products", selector: "[data-testid=products]", description: "The list", instructions: "Open it.", source: "src/App.tsx")
    check("DEC-015 the screen request asks for a screen without a blocking dialog in front of it",
          screen.request.contains("not covered by a blocking dialog") && screen.request.contains("unless this screen is that dialog"))
    check("DEC-015 the assistant is told to take a covering dialog away in the scenario",
          StudioPrompts.editSystem.contains("shown with nothing in front of it") && StudioPrompts.editSystem.contains("press the dialog's own button"))
    var empty = StudioReview.Outcome(proposal: StudioProposal(), replaces: [], links: [], notes: "")
    empty.proposal.envelopes = []
    var looked = simulator
    check("DEC-015 nothing to correct is applied and recorded as looked at", StudioReview.apply(empty, to: &looked).isEmpty && looked.spec.envelopes == [])

    }
}
