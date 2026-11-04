// A real UI Studio session (StudioSession) against a real development server (python3 -m http.server) in a git project:
// readiness, simulated shared state and Reset, selection that finds the source, a read-only question, a verified source
// change, selective undo with an independent and an overlapping later edit, a change that breaks the build and leaves a
// stale preview, preparation of an unknown request, captures and their comparison, feature export with package
// revalidation, and the server ownership rules on close. The assistant is answered by this harness
// (UIStudioSessionStubs.swift); everything else is the app's code.
import AppKit
import WebKit

// CI runners give no clue when a windowed WebKit test hangs: print every line at once and stop with the last step reached.
setvbuf(stdout, nil, _IONBF, 0)
final class Watchdog: @unchecked Sendable {
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
let watchdog = Watchdog(seconds: 480)

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok  \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

func shell(_ command: String, in folder: URL) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = folder
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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

func edit(_ id: String, _ search: String, _ replace: String, path: String = "web/index.html") -> [String: Any] {
    ["scope": "instance", "scopeNote": "Only this element.", "needsClarification": false, "summary": "Edit \(id)",
     "edits": [["path": path, "search": search, "replace": replace]]]
}

/// What the stand-in assistant answers next, by request label.
final class Assistant: @unchecked Sendable {
    let lock = NSLock()
    var edits: [[String: Any]] = []
    var proposal: [String: Any] = [:]

    func respond(_ request: CLICompletion.Request) -> CLICompletion.Result {
        lock.withLock {
            switch request.label {
            case "ui-studio:question":
                return CLICompletion.Result(text: "This is the Add button; it posts a new item.", structured: nil, inputTokens: 10, outputTokens: 5, costUSD: 0)
            case "ui-studio:edit":
                let next = edits.isEmpty ? [:] : edits.removeFirst()
                return CLICompletion.Result(text: "", structured: next, inputTokens: 10, outputTokens: 5, costUSD: 0)
            default:
                return CLICompletion.Result(text: "", structured: proposal, inputTokens: 10, outputTokens: 5, costUSD: 0)
            }
        }
    }
}

let indexHTML = """
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Items</title><link rel="stylesheet" href="app.css"></head>
<body>
<h1 class="title">Items</h1>
<p class="intro">Everything the team is working on.</p>
<ul id="list"></ul>
<section class="filler">
  <p>One</p>
  <p>Two</p>
  <p>Three</p>
  <p>Four</p>
</section>
<button id="add" class="primary">Add item</button>
<script src="app.js"></script>
</body>
</html>

"""
/// BUG-068: a page whose consent banner (kept in localStorage) is inserted before the content until it is accepted, so a
/// positional path to the card's button points at the banner's button once storage is cleared.
let consentHTML = """
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Consent</title></head>
<body>
<section class="cards"><div class="card"><button class="cta">Plan with us</button></div></section>
<script>
if (!localStorage.getItem('consent')) {
  const banner = document.createElement('section');
  banner.className = 'consent';
  banner.innerHTML = '<div class="note"><button class="accept">Accept all</button></div>';
  document.body.insertBefore(banner, document.body.firstChild);
  banner.querySelector('.accept').addEventListener('click', () => { localStorage.setItem('consent', 'yes'); banner.remove(); });
}
</script>
</body>
</html>

"""
let appJS = """
async function render() {
  const items = await (await fetch('/api/items')).json();
  document.getElementById('list').innerHTML = items.map(i => '<li>' + i.name + '</li>').join('');
}
document.getElementById('add').addEventListener('click', async () => {
  await fetch('/api/items', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: 'New' }) });
  await render();
});
render();

"""

@MainActor
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

@MainActor
func run() async {
    guard let runtime = CommandLine.arguments.dropFirst().first else {
        print("usage: ui-studio-session-harness <markview-ui-studio.js>")
        exit(2)
    }
    StudioSession.runtimeURL = URL(fileURLWithPath: runtime)
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-session-\(UUID().uuidString)").resolvingSymlinksInPath()
    let web = root.appendingPathComponent("web")
    try? fm.createDirectory(at: web, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? indexHTML.write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try? appJS.write(to: web.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
    try? ".primary { color: #333; }\n".write(to: web.appendingPathComponent("app.css"), atomically: true, encoding: .utf8)
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "items", fields: [StudioField(name: "name", type: "string", required: true)])]
    spec.seed = ["items": [.object(["id": .number(1), "name": .string("Alpha")]), .object(["id": .number(2), "name": .string("Beta")])]]
    spec.rules = [StudioRule(id: "list-items", method: "GET", path: "/api/items", operation: .list, entity: "items"),
                  StudioRule(id: "create-item", method: "POST", path: "/api/items", operation: .create, entity: "items")]
    try? StudioStore.saveEnvironment(spec, root: root)
    _ = shell("git init -q && git add -A && git -c user.email=t@example.com -c user.name=Test commit -qm init", in: root)

    let assistant = Assistant()
    CLICompletion.answer = { request in assistant.respond(request) }
    let store = FeatureStore(folder: root.appendingPathComponent("docs/features"))

    let session = StudioSession(root: root)
    session.featureStore = { store }
    let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 1100, height: 860), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    let host = StudioPreviewScrollView(webView: session.webView)
    host.frame = window.contentView!.bounds
    host.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(host)
    host.viewport = CGSize(width: session.viewport.width, height: session.viewport.height)
    host.zoom = 0.75
    window.orderFrontRegardless()

    let port = freePort()
    let target = WebAppTarget(folder: web, label: "web", command: "python3 -m http.server \(port) --bind 127.0.0.1", ports: [port])

    func text(_ script: String) async -> String? { (try? await session.call(script)) as? String }
    func idle() async -> Bool { await waitUntil(120) { session.busy == nil } }
    func file() -> String { (try? String(contentsOf: web.appendingPathComponent("index.html"), encoding: .utf8)) ?? "" }
    // A click through the page's own event dispatch, so the check does not depend on which window has the focus. Native
    // clicks under zoom are checked by ui-studio-web-tests.sh.
    func clickElement(_ selector: String) async {
        _ = try? await session.call("document.querySelector(s).dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true })); return true;",
                                    ["s": selector])
    }

    // Launch: the session starts the server it needs and reaches Ready (REQ-001).
    watchdog.reached("Launch")
    session.start(target)
    let ready = await waitUntil(90) { session.state == .ready || session.state == .failed }
    check("AC-01 the session starts the development server and becomes ready", ready && session.state == .ready,
          "\(session.state) \(session.stateDetail) \(session.serverLog.suffix(400))")
    check("AC-18 the session owns the server it started", session.ownsServer)
    _ = await waitUntil(10) { (session.requests.contains { $0.contract == "GET /api/items" && $0.outcome == "simulated" }) }
    let listed = await text("return Array.from(document.querySelectorAll('#list li')).map(l => l.textContent).join(',');")
    check("AC-02 the real page renders the simulated list", listed == "Alpha,Beta", listed ?? "nil")
    check("AC-02 requests are answered by the simulation", session.requests.contains { $0.contract == "GET /api/items" && $0.outcome == "simulated" })
    let styled = await text("return getComputedStyle(document.querySelector('#add')).color;")
    check("AC-16 the page's own files load from the development server", styled == "rgb(51, 51, 51)", styled ?? "nil")

    // Shared state across requests, and Reset back to the baseline (AC-03, AC-04).
    watchdog.reached("Shared state across requests, and Reset back to the baseline")
    await clickElement("#add")
    _ = await waitUntil(5) { session.requests.contains { $0.contract == "POST /api/items" } }
    try? await Task.sleep(nanoseconds: 500_000_000)
    let added = await text("return String(document.querySelectorAll('#list li').length);")
    check("AC-03 a created record appears in the list", added == "3", added ?? "nil")
    session.reset()
    _ = await idle()
    let afterReset = await text("return String(document.querySelectorAll('#list li').length);")
    check("AC-04 Reset restores the scenario's baseline", afterReset == "2", afterReset ?? "nil")

    // Select mode finds the element's source without running its action (AC-08, AC-09).
    watchdog.reached("Select mode finds the element's source without running its action")
    let postsBefore = session.requests.filter { $0.contract == "POST /api/items" }.count
    session.setMode(.select)
    try? await Task.sleep(nanoseconds: 600_000_000)
    await clickElement("#add")
    _ = await waitUntil(10) { session.selection != nil }
    let selection = session.selection
    check("AC-08 select mode selects the element", selection?.tag.hasPrefix("button#add") == true, selection?.tag ?? "nil")
    check("AC-08 selecting does not run the element's action", session.requests.filter { $0.contract == "POST /api/items" }.count == postsBefore)
    check("AC-10 the source is found in the project", selection?.sourcePath == "web/index.html" && selection?.line == 14,
          "\(selection?.sourcePath ?? "nil"):\(selection?.line ?? 0)")
    check("AC-10 the selection carries a picture, the revision and the scenario",
          selection?.imagePath.map { fm.fileExists(atPath: $0) } == true && selection?.revision != nil && selection?.scenarioId == session.scenario.id)
    session.setMode(.interact)

    // A question changes nothing (AC-11).
    watchdog.reached("A question changes nothing")
    session.ask("What does this button do?")
    _ = await idle()
    let question = session.history.last
    check("AC-11 a question is answered", question?.kind == .question && question?.status == .answered && question?.answer.contains("Add button") == true)
    let status = shell("git status --porcelain", in: root).1
    check("AC-11 a question leaves the project unchanged", question?.checks.first?.passed == true && status.isEmpty, status)
    let questionRequest = CLICompletion.requests.last
    check("AC-17 the assistant gets read-only project access without the web",
          questionRequest?.readableFolder?.standardizedFileURL.path == root.standardizedFileURL.path && questionRequest?.allowWeb == false
          && questionRequest?.jsonSchema == nil, "\(questionRequest?.readableFolder?.path ?? "nil") \(questionRequest?.allowWeb ?? true)")

    // A change is applied, the app reloads, the scenario is restored and verified (AC-12, AC-13).
    watchdog.reached("A change is applied, the app reloads, the scenario is restored and verified")
    assistant.lock.withLock { assistant.edits = [edit("title", "<h1 class=\"title\">Items</h1>", "<h1 class=\"title\">All items</h1>")] }
    session.change("Rename the heading to All items")
    _ = await idle()
    guard let first = session.history.last else { check("AC-12 a change is recorded", false); return finish(session) }
    check("AC-12 a change edits the source", first.status == .applied && file().contains("All items") && first.files.map(\.path) == ["web/index.html"],
          "\(first.status) \(first.answer)")
    check("AC-13 the change records its scope, patch and revisions", first.scope == .instance && first.patch.contains("+<h1 class=\"title\">All items</h1>")
          && first.baseRevision != nil && first.finalRevision != nil && first.baseRevision?.id != first.finalRevision?.id)
    check("AC-15 the rebuilt application is verified in the restored scenario", !first.checks.isEmpty && first.checks.allSatisfy(\.passed),
          first.checks.map { "\($0.name)=\($0.passed) \($0.detail)" }.joined(separator: "; "))
    let heading = await text("return document.querySelector('h1').textContent;")
    check("AC-15 the preview shows the change", heading == "All items", heading ?? "nil")
    check("AC-19 before and after captures are linked to the change", first.beforeCapture != nil && first.afterCapture != nil)

    // An independent later edit stays when the change is undone (AC-14).
    watchdog.reached("An independent later edit stays when the change is undone")
    try? file().replacingOccurrences(of: "Add item</button>", with: "Add one item</button>").write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    session.undo(first.id)
    _ = await idle()
    check("AC-14 undo removes only that change", file().contains("<h1 class=\"title\">Items</h1>") && file().contains("Add one item"),
          file())
    check("AC-14 the undone change is marked", session.history.first { $0.id == first.id }?.status == .undone)

    // An overlapping later edit is a conflict: nothing is written (AC-14).
    watchdog.reached("An overlapping later edit is a conflict")
    assistant.lock.withLock { assistant.edits = [edit("intro", "Everything the team is working on.", "What the team does.")] }
    session.change("Shorten the intro")
    _ = await idle()
    if let second = session.history.last, second.status == .applied {
        let mine = file().replacingOccurrences(of: "What the team does.", with: "What the whole team does.")
        try? mine.write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        session.undo(second.id)
        _ = await idle()
        check("AC-14 an overlapping undo is a conflict", session.history.first { $0.id == second.id }?.status == .conflict
              && session.undoConflicts[second.id] != nil)
        check("AC-14 a conflicting undo writes nothing", file() == mine)
    } else {
        check("AC-14 the second change applies", false, session.history.last?.answer ?? "nil")
    }

    // An edit the assistant gets wrong is retried once with the problem, then applied (EDIT-03).
    watchdog.reached("An edit the assistant gets wrong is retried once with the problem, then applied")
    assistant.lock.withLock {
        assistant.edits = [edit("missing", "<p>Five</p>", "<p>5</p>"), edit("fixed", "<p>Four</p>", "<p>4</p>")]
    }
    session.change("Use digits for the last paragraph")
    _ = await idle()
    let retried = session.history.last
    check("EDIT-03 an edit whose text is not found is retried once", retried?.status == .applied && file().contains("<p>4</p>"),
          "\(retried?.status.rawValue ?? "nil") \(retried?.answer ?? "")")
    let retryPrompt = CLICompletion.requests.last { $0.label == "ui-studio:edit" }?.prompt ?? ""
    check("EDIT-03 the retry tells the assistant what failed", retryPrompt.contains("<p>Five</p>") || retryPrompt.lowercased().contains("not found"))

    // A materially ambiguous request is clarified before anything is edited (REQ-004, EDIT-02).
    watchdog.reached("A materially ambiguous request is clarified before anything is edited")
    assistant.lock.withLock {
        assistant.edits = [["scope": "shared", "scopeNote": "The paragraphs share one style.", "needsClarification": true,
                            "question": "Only this paragraph, or every paragraph of the section?",
                            "options": ["Only this paragraph", "Every paragraph"], "summary": "", "edits": []],
                           edit("bold", "<p>One</p>", "<p><strong>One</strong></p>")]
    }
    let beforeClarification = file()
    session.change("Make the paragraph bold")
    _ = await idle()
    let asking = session.history.last
    check("REQ-004 an ambiguous request asks before editing", asking?.status == .clarification && asking?.options.count == 2
          && file() == beforeClarification, "\(asking?.status.rawValue ?? "nil")")
    if let asking {
        session.answerClarification(asking, choice: "Only this paragraph")
        _ = await idle()
        let clarified = session.history.last
        let clarifiedPrompt = CLICompletion.requests.last { $0.label == "ui-studio:edit" }?.prompt ?? ""
        check("REQ-004 the answer goes to the assistant and the change is applied", clarifiedPrompt.contains("Only this paragraph")
              && clarified?.status == .applied && file().contains("<p><strong>One</strong></p>"), "\(clarified?.status.rawValue ?? "nil")")
        check("REQ-004 the answered question is not left open", !session.history.contains { $0.status == .clarification })
    }

    // A change that breaks the build: the failure is visible and the previous preview is stale (AC-15).
    watchdog.reached("A change that breaks the build")
    assistant.lock.withLock {
        assistant.edits = [edit("broken", "<ul id=\"list\"></ul>", "<ul id=\"list\"></ul><vite-error-overlay>Failed to compile app.js</vite-error-overlay>")]
    }
    session.change("Break the build")
    _ = await idle()
    let broken = session.history.last
    check("AC-15 a build failure fails the verification", broken?.checks.first?.passed == false, broken?.checks.map(\.name).joined(separator: ",") ?? "nil")
    check("AC-15 the build error is shown and the previous preview is marked stale", session.buildError != nil && session.stalePreview != nil
          && session.state == .degraded, "\(session.buildError ?? "nil") \(session.state)")
    if let broken {
        session.undo(broken.id)
        _ = await idle()
        check("AC-15 undoing the breaking change clears the stale preview", session.buildError == nil && session.stalePreview == nil,
              session.buildError ?? "")
    }

    // BUG-067: a build error overlay that goes away without a reload (fast refresh fixed it, the dialog was
    // closed) clears the build error and the stale preview.
    watchdog.reached("A build error overlay that goes away clears the stale preview")
    _ = try? await session.call("document.body.appendChild(document.createElement('vite-error-overlay')).textContent = 'Failed to compile app.js'; return true;")
    let overlayShown = await waitUntil(5) { session.buildError != nil && session.stalePreview != nil }
    _ = try? await session.call("document.querySelector('vite-error-overlay').remove(); return true;")
    let overlayCleared = await waitUntil(5) { session.buildError == nil && session.stalePreview == nil }
    check("BUG-067 the stale preview clears when the build error overlay goes away", overlayShown && overlayCleared,
          "\(overlayShown) \(session.buildError ?? "nil")")
    check("BUG-067 the clearing signal is not listed as an empty event", !session.events.contains { $0.kind == .buildError && $0.detail.isEmpty })

    // BUG-067: only compile and bundle failures in the dev server's log fail a change's rebuild check.
    let handled = """
        [fx] rates unavailable in client-web-app: Error: marketplace unreachable
            at fetchRates (lib/fx/server.ts:20:11)
         ⨯ Error: boom
            at Page (app/page.tsx:4:9)
        SyntaxError: Unexpected token < in JSON at position 0
        Error: connect ECONNREFUSED 127.0.0.1:5432
         GET /studio 200 in 1043ms
        """
    check("BUG-067 errors of an application that built are not build failures", StudioSession.buildFailure(in: handled) == nil,
          StudioSession.buildFailure(in: handled) ?? "")
    let failures = [
        " ⨯ ./app/page.tsx\nModule not found: Can't resolve './missing'",
        "Failed to compile.",
        " ⨯ ./app/page.tsx:3:7\nParsing ecmascript source code failed",
        "[vite] Internal server error: Transform failed with 1 error:",
        "[plugin:vite:react-babel] /src/App.tsx: Unexpected token (3:4)",
        "[vite] Pre-transform error: Failed to resolve import \"./x\" from \"src/App.tsx\". Does the file exist?",
        "✘ [ERROR] Expected \";\" but found \"x\"",
        "src/app.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.",
        "ERROR in ./src/index.js 3:7",
        "SyntaxError: /app/src/App.js: Unexpected token (3:4)",
        "Error: \n  x Expected ';', got 'foo'\nCaused by:\n    Syntax Error",
    ]
    let missed = failures.filter { StudioSession.buildFailure(in: handled + "\n" + $0) == nil }
    check("BUG-067 compile and bundle failures of common dev servers are build failures", missed.isEmpty, missed.joined(separator: " || "))

    // An unknown request is prepared once, validated, registered and then served without the model (AC-05, AC-06).
    watchdog.reached("An unknown request is prepared once, validated, registered and then served without the model")
    assistant.lock.withLock {
        assistant.proposal = ["rules": [["id": "stats", "method": "GET", "path": "/api/stats", "operation": "respond",
                                         "responseStatus": 200, "responseBody": #"{"open":2}"#,
                                         "evidence": [["kind": "observation", "detail": "Requested by the page"]]]],
                              "assumptions": ["The stats endpoint returns counts."]]
    }
    let callsBefore = CLICompletion.requests.filter { $0.label == "ui-studio:prepare" }.count
    let stats = await text("const r = await fetch('/api/stats'); return r.status + ' ' + await r.text();")
    check("AC-05 an unknown request is prepared and answered", stats == "200 {\"open\":2}", stats ?? "nil")
    let again = await text("const r = await fetch('/api/stats'); return String(r.status);")
    let callsAfter = CLICompletion.requests.filter { $0.label == "ui-studio:prepare" }.count
    check("AC-06 a registered rule serves later requests without the model", again == "200" && callsAfter == callsBefore + 1,
          "\(again ?? "nil") \(callsAfter - callsBefore)")
    check("SIM-05 the prepared rule is kept for later sessions", StudioStore.loadEnvironment(root)?.rules.contains { $0.id == "stats" } == true)
    let prepareRequest = CLICompletion.requests.last { $0.label == "ui-studio:prepare" }
    check("AC-17 preparation is read-only and has no web access", prepareRequest?.allowWeb == false
          && prepareRequest?.readableFolder?.standardizedFileURL.path == root.standardizedFileURL.path)
    check("AC-17 the model never sees confidential values", !(prepareRequest?.prompt.contains("markview-test-token") ?? true))
    assistant.lock.withLock { assistant.proposal = ["rules": [["id": "bad", "method": "GET", "path": "/api/broken", "operation": "list", "entity": "nothing"]]] }
    let invalid = await text("const r = await fetch('/api/broken'); return String(r.status);")
    check("AC-07 an invalid proposal ends in a controlled error", invalid == "503", invalid ?? "nil")
    check("AC-07 an invalid proposal changes nothing", StudioStore.loadEnvironment(root)?.rules.contains { $0.id == "bad" } != true)

    // The page cannot leave the application (AC-16).
    watchdog.reached("The page cannot leave the application")
    _ = try? await session.call("location.href = 'https://example.org/elsewhere'; return true;")
    _ = await waitUntil(5) { session.events.contains { $0.kind == .blocked && $0.detail.contains("example.org") } }
    let stillHere = await text("return location.origin;")
    check("AC-16 the page cannot navigate away from the application",
          session.events.contains { $0.kind == .blocked && $0.detail.contains("example.org") } && stillHere?.contains("\(port)") == true,
          stillHere ?? "nil")

    // Captures and their comparison (AC-19, AC-20).
    watchdog.reached("Captures and their comparison")
    let before = session.history.first { $0.beforeCapture != nil && $0.afterCapture != nil }
    if let before, let a = before.beforeCapture, let b = before.afterCapture {
        session.compare(a, b)
        _ = await waitUntil(10) { session.comparison != nil }
        let comparison = session.comparison
        check("AC-20 captures of the same scenario are comparable", comparison?.reasons.isEmpty == true, comparison?.reasons.joined(separator: "; ") ?? "nil")
        check("AC-20 the difference image shows the change", comparison?.diffFile.map { fm.fileExists(atPath: $0.path) } == true
              && (comparison?.changedRatio ?? 0) > 0)
        let capture = session.captures.first { $0.id == a }
        check("AC-19 a capture records revision, scenario and rendering", capture?.rendering.viewport.width == session.viewport.width
              && capture?.rendering.engine.hasPrefix("WebKit") == true && capture?.scenarioId == session.scenario.id)
    } else {
        check("AC-20 a change with captures exists", false)
    }
    session.captureNow()
    _ = await idle()
    check("BUG-067 the capture notice names the scenario once", session.notice == "Saved a capture of \(session.scenario.name).",
          session.notice ?? "nil")

    // Feature export and revalidation (AC-21, AC-22).
    watchdog.reached("Feature export and revalidation")
    let exportable = session.exportableOperations.map(\.id)
    session.exportFeature(title: "Digits in the list", summary: "Paragraph numbers as digits.", operations: exportable)
    _ = await idle()
    let package = session.packages.first
    check("AC-21 the export creates a feature with requirements", package != nil && store.objects.contains { $0.kind == .requirement },
          session.notice ?? "")
    check("AC-21 the package has revisions, scenario, rendering, patch and checks", package?.patch.isEmpty == false && package?.checks.isEmpty == false
          && package?.rendering != nil && package?.files.isEmpty == false)
    let overview = store.overviews.values.first?.body ?? ""
    check("AC-21 the feature overview carries scenario, revisions, rendering, requests and verification",
          ["Scenario:", "Baseline code revision", "Final code revision", "Rendering:", "Use digits for the last paragraph", "Verification"]
            .allSatisfy(overview.contains), String(overview.prefix(800)))
    check("AC-21 each change becomes a requirement with its code changes",
          store.objects.contains { $0.kind == .requirement && $0.body.contains("```diff") && $0.body.contains("<p>4</p>") })
    check("AC-21 the captures are attached to the feature", store.objects.contains { $0.kind == .source })
    try? (file() + "<!-- later -->\n").write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    await session.revalidatePackages()
    check("AC-22 a later change of the files marks the package for revalidation", session.packages.first?.status == .revalidationRequired
          && session.packages.first?.changedSince == ["web/index.html"])

    // BUG-068: a change restores the scenario first, and the restored page can be laid out differently (here a consent
    // banner comes back because storage is cleared). The change must still go to the element the person selected, never
    // to whatever now sits at its old position.
    watchdog.reached("A change goes to the selected element when the restored page is laid out differently")
    try? consentHTML.write(to: web.appendingPathComponent("consent.html"), atomically: true, encoding: .utf8)
    var consentScenario = session.scenario
    consentScenario.id = "consent"
    consentScenario.name = "Consent"
    consentScenario.route = "/consent.html"
    consentScenario.steps = []
    session.activate(consentScenario)
    _ = await idle()
    await clickElement(".accept")
    _ = await waitUntil(5) { true }
    let bannerGone = await text("return String(document.querySelector('.consent') === null);")
    check("BUG-068 accepting removes the banner", bannerGone == "true", bannerGone ?? "nil")
    session.setMode(.select)
    try? await Task.sleep(nanoseconds: 600_000_000)
    await clickElement(".cta")
    _ = await waitUntil(10) { session.selection?.tag.hasPrefix("button.cta") == true }
    check("BUG-068 the card's button is selected", session.selection?.tag.hasPrefix("button.cta") == true, session.selection?.tag ?? "nil")
    session.setMode(.interact)
    let editsBefore = CLICompletion.requests.filter { $0.label == "ui-studio:edit" }.count
    assistant.lock.withLock { assistant.edits = [edit("cta", "Plan with us", "Plan it with us", path: "web/consent.html")] }
    session.change("Make this button friendlier")
    _ = await idle()
    let editRequests = CLICompletion.requests.filter { $0.label == "ui-studio:edit" }
    let editPrompt = editRequests.count > editsBefore ? editRequests.last?.prompt ?? "" : ""
    check("BUG-068 the assistant is given the selected element, not the banner's button",
          editPrompt.contains("button.cta") && !editPrompt.contains("button.accept"), String(editPrompt.prefix(300)))
    check("BUG-068 the change records the selected element", session.history.last?.selection.hasPrefix("button.cta") == true,
          session.history.last?.selection ?? "nil")

    finish(session, port: port)
}

@MainActor
func finish(_ session: StudioSession, port: Int? = nil) {
    Task { @MainActor in
        // Closing stops the server the session started (AC-18).
        await session.close()
        if let port {
            let answering = await WebAppPreview.firstAnswering([port], timeout: 1)
            check("AC-18 closing the session stops the server it started", answering == nil && session.state == .stopped)
            await externalServerCheck()
        }
        targetChecks()
        print(failures == 0 ? "All UI Studio session checks passed." : "\(failures) UI Studio session check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}

/// A server that was already running is used and left running (AC-18).
@MainActor
func externalServerCheck() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-external-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "<!doctype html><title>External</title><p>External</p>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let port = freePort()
    let external = Process()
    external.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    external.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
    external.currentDirectoryURL = root
    external.standardOutput = FileHandle.nullDevice
    external.standardError = FileHandle.nullDevice
    try? external.run()
    var answering = false
    for _ in 0..<80 where !answering {
        answering = await WebAppPreview.firstAnswering([port], timeout: 0.5) != nil
        if !answering { try? await Task.sleep(nanoseconds: 250_000_000) }
    }
    check("the external server answers before the session opens", answering)
    let session = StudioSession(root: root)
    session.start(WebAppTarget(folder: root, label: "external", command: "python3 -m http.server \(port)", ports: [port]))
    _ = await waitUntil(60) { [.ready, .degraded, .failed].contains(session.state) }
    check("AC-18 an already running server is used, not started again", session.appURL != nil && !session.ownsServer,
          "\(session.state) \(session.stateDetail) owns=\(session.ownsServer)")
    await session.close()
    let still = await WebAppPreview.firstAnswering([port], timeout: 1)
    check("AC-18 closing the session leaves an external server running", still != nil)
    external.terminate()
}

/// Which projects UI Studio opens and what it says it cannot simulate (REQ-001).
func targetChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-targets-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: base) }
    func project(_ name: String, _ package: [String: Any], files: [String: String] = [:]) -> URL {
        let folder = base.appendingPathComponent(name)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: package) { try? data.write(to: folder.appendingPathComponent("package.json")) }
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    let svelte = project("svelte-webpack", ["scripts": ["dev": "webpack serve --port 8085"],
                                            "dependencies": ["svelte": "^4.0.0"], "devDependencies": ["webpack": "^5.0.0"]])
    let svelteTarget = WebAppPreview.targets(root: svelte).first
    check("REQ-001 a project without React or Vite is opened (Svelte with webpack)",
          svelteTarget != nil && svelteTarget?.ports.first == 8085 && svelteTarget?.isElectron == false,
          "\(String(describing: svelteTarget))")
    check("REQ-001 a client-rendered target has nothing to disclose", svelteTarget.map(StudioTargetLimits.disclosures(for:))?.isEmpty == true)

    let next = project("next-app", ["scripts": ["dev": "next dev"], "dependencies": ["next": "15.0.0", "react": "19.0.0"]])
    let nextTarget = WebAppPreview.targets(root: next).first
    let nextNotes = nextTarget.map(StudioTargetLimits.disclosures(for:)) ?? []
    check("REQ-001 a framework that renders on the server is still opened", nextTarget != nil)
    check("REQ-001 server rendering is disclosed as not simulated", nextNotes.contains { $0.contains("renders on the server") && $0.contains("not simulated") },
          nextNotes.joined(separator: " | "))

    let electron = project("electron-app", ["main": "main.js", "scripts": ["dev": "electron .", "dev:web": "vite --port 5199"],
                                            "devDependencies": ["electron": "^33.0.0", "vite": "^6.0.0"]],
                           files: ["src/preload.ts": "import { contextBridge } from 'electron'\ncontextBridge.exposeInMainWorld('desktop', { open: () => 1 })\n"])
    let electronTarget = WebAppPreview.targets(root: electron).first
    let electronNotes = electronTarget.map(StudioTargetLimits.disclosures(for:)) ?? []
    check("REQ-001 an Electron app runs its renderer as a web page, without Electron",
          electronTarget?.isElectron == true && electronTarget?.command.contains("dev:web") == true
            && electronTarget?.command.contains("electron .") == false, "\(String(describing: electronTarget))")
    check("REQ-001 the main process, preload, IPC and native modules are disclosed as not running",
          electronNotes.contains { $0.contains("main process, preload scripts, IPC and native modules do not run") && $0.contains("not simulated") },
          electronNotes.joined(separator: " | "))
    check("REQ-001 the preload's globals get stand-ins under their real names", StudioTargetLimits.electronGlobals(in: electron) == ["desktop"])

    let django = base.appendingPathComponent("django")
    try? fm.createDirectory(at: django, withIntermediateDirectories: true)
    try? "".write(to: django.appendingPathComponent("manage.py"), atomically: true, encoding: .utf8)
    let djangoNotes = WebAppPreview.targets(root: django).first.map(StudioTargetLimits.disclosures(for:)) ?? []
    check("REQ-001 server-rendered pages disclose that the server's requests and database are not simulated",
          djangoNotes.contains { $0.contains("database are not simulated") })
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
application.run()
