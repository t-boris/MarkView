// The lifetime of a real UI Studio session (StudioSession and its parts) against the work its parts started. A part of the
// session (the repair, the picker, the request path ...) holds its session `unowned` and starts tasks that go on after an
// `await`; this harness closes a session and drops every reference to it while such a task is still suspended, then lets the
// work end (cancelled, as the real assistant runner does, or answered late by a stand-in that ignores cancellation) and checks
// that nothing crashed, nothing was written after close, and the session was released once its work was over. The assistant
// is answered by this harness (UIStudioSessionStubs.swift); everything else is the app's code. The pages are hosted in a
// window nobody can see, as in the app.
import AppKit
import WebKit

setvbuf(stdout, nil, _IONBF, 0)
final class Watchdog: @unchecked Sendable {   // unchecked Sendable: `lock` guards `step`
    private let lock = NSLock()
    private var step = "start"
    init(seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            print("TIMEOUT: no result after \(Int(seconds)) s; last step: \(lock.withLock { step })")
            exit(1)
        }
    }
    func reached(_ name: String) {
        lock.withLock { step = name }
        print("--  \(name)")
    }
}
let watchdog = Watchdog(seconds: 420)

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok  \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

func freePort() -> Int {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
    return Int(UInt16(bigEndian: address.sin_port))
}

func shell(_ command: String, in folder: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = folder
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
}

@MainActor
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

/// The session's page in a window nobody can see or click, as in the app: a page with no window cannot be photographed.
@MainActor
func hostPageInvisibly(_ session: StudioSession) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 1100, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let host = StudioPreviewScrollView(webView: session.webView)
    host.frame = window.contentView!.bounds
    host.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(host)
    host.viewport = CGSize(width: session.viewport.width, height: session.viewport.height)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    // ARC owns the window: closing a window that is also released when closed would release it twice.
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    return window
}

// MARK: - The stand-in assistant

/// Holds the stand-in assistant's answer until the test opens it. A `cancellable` waiter is let go at once when its task is cancelled
/// and throws, as the real runner does (CLICompletion kills its child and throws); one that is not waits for the test and answers late.
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

let emptyAnswer: @Sendable () -> CLICompletion.Result = {
    CLICompletion.Result(text: "", structured: ["rules": [], "assumptions": []], inputTokens: 1, outputTokens: 1, costUSD: 0)
}

/// The assistant answers `label` through `gate`, with `structured`; every other call gets an empty answer at once.
func standIn(label: String?, gate: Gate, cancellable: Bool, structured: [String: Any]? = nil) {
    nonisolated(unsafe) let answer = structured
    CLICompletion.answer = { request in
        guard let label, request.label == label else { return emptyAnswer() }
        try await gate.wait(cancellable: cancellable)
        return CLICompletion.Result(text: "", structured: answer, inputTokens: 10, outputTokens: 5, costUSD: 0)
    }
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
    let only = CommandLine.arguments.dropFirst(2)
    guard only.isEmpty || only.contains(where: { name.contains($0) }) else { return }
    watchdog.reached(name)
    let fixture = makeFixture("scenario", page: page, autoRepair: autoRepair)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let gate = Gate()
    standIn(label: label, gate: gate, cancellable: cancellable, structured: answer)
    let askedBefore = CLICompletion.requests.count
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
        let asked = CLICompletion.requests.dropFirst(askedBefore).filter { $0.label == label }.count
        check("\(name): the assistant was asked once and not again", asked == 1, "\(asked)")
    }
}

@MainActor
func run() async {
    guard let runtime = CommandLine.arguments.dropFirst().first else {
        print("usage: ui-studio-lifetime-harness <Editor/js folder> [part of a scenario's name ...]")
        exit(2)
    }
    StudioSession.expectedStateTimeout = 1
    StudioSession.runtimeFolder = URL(fileURLWithPath: runtime)
    StudioSession.nodePreloadURL = URL(fileURLWithPath: runtime).appendingPathComponent("markview-ui-studio-node.cjs")

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

    print(failures == 0 ? "All UI Studio lifetime checks passed." : "\(failures) UI Studio lifetime check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
application.run()
