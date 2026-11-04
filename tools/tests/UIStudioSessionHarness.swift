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

/// The answer of a request the assistant chose to answer (DEC-010): nothing changes.
func answerPlan(_ text: String) -> [String: Any] {
    ["kind": "answer", "answer": text, "scope": "unknown", "scopeNote": "", "needsClarification": false, "question": "", "options": [],
     "summary": "", "edits": [], "context": [:]]
}

/// A context change as the assistant returns it (REQ-013): the whole strict answer with kind `context`. `edits` are stray
/// edits a confused assistant might add; a context change never writes them.
func contextPlan(name: String, data: String = "", addData: String = "", steps: [[String: Any]] = [], unsupported: [String] = [],
                 edits: [[String: Any]] = []) -> [String: Any] {
    ["kind": "context", "answer": "", "scope": "unknown", "scopeNote": "", "needsClarification": false, "question": "", "options": [],
     "summary": "Context: \(name)", "edits": edits,
     "context": ["name": name, "description": "", "route": "", "data": data, "addData": addData, "userJSON": "", "overrides": [],
                 "steps": steps, "testTime": "", "locale": "", "timeZone": "", "theme": "", "unsupported": unsupported]]
}

/// What the stand-in assistant answers next, by request label. A request with nothing queued is answered (DEC-010).
final class Assistant: @unchecked Sendable {
    let lock = NSLock()
    var edits: [[String: Any]] = []
    var proposal: [String: Any] = [:]

    func respond(_ request: CLICompletion.Request) -> CLICompletion.Result {
        lock.withLock {
            switch request.label {
            case "ui-studio:edit":
                let next = edits.isEmpty ? answerPlan("This is the Add button; it posts a new item.") : edits.removeFirst()
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
/// BUG-069: a page built like Next.js 16 with Turbopack: the element is made by a bundled chunk under /_next/, its React
/// fiber carries only the stack captured where its JSX ran (line 3 of the chunk), and the chunk's indexed source map leads
/// that line to web/src/Card.tsx line 6.
let chunkHTML = """
<!doctype html><html><head><title>Chunk</title></head><body><div id="root"></div>
<script src="/_next/static/chunks/app_0abc._.js"></script></body></html>
"""
let chunkJS = """
(function () {
  function Card() {
    var stack = new Error('react-stack-top-frame');
    var el = document.createElement('div');
    el.className = 'card';
    el.textContent = 'Plan';
    el['__reactFiber$test'] = { type: 'div', _debugStack: stack, return: { type: Card } };
    return el;
  }
  document.getElementById('root').appendChild(Card());
})();
"""
let cardTSX = """
import React from 'react';

export function Card() {
  const title = 'Plan';
  return (
    <div className="card">
      {title}
    </div>
  );
}
"""

/// BUG-071: two pages joined by a plain link, so recording and replaying have to follow a full page load.
let recordHTML = """
<!doctype html><html><head><title>Start</title></head><body>
<button id="go" onclick="document.body.dataset.went = 'yes'">Go</button>
<a id="next" href="/rec-next.html">Next page</a>
</body></html>
"""
let recordNextHTML = """
<!doctype html><html><head><title>Next</title></head><body>
<input id="q"><button id="done" onclick="document.body.dataset.done = document.getElementById('q').value">Done</button>
</body></html>
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
    StudioSession.nodePreloadURL = URL(fileURLWithPath: runtime).deletingLastPathComponent().appendingPathComponent("markview-ui-studio-node.cjs")
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
    // A turn of an earlier session: shown in the thread, never sent as memory (BUG-068).
    var earlier = StudioOperation(id: "op-earlier", kind: .edit, request: "Make the consent banner smaller", status: .applied)
    earlier.selection = "div.consent-banner"
    try? StudioStore.saveHistory([earlier], root: root)

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

    // BUG-070: a framework's refresh/navigation payload request goes to the development server, not to rule preparation.
    let preparedBefore = CLICompletion.requests.filter { $0.label == "ui-studio:prepare" }.count
    let payload = await text("const r = await fetch('/?_rsc=abc', { headers: { rsc: '1' } }); return r.status + ' ' + (await r.text()).includes('<title>Items</title>');")
    check("BUG-070 a framework data request is answered by the development server", payload == "200 true", payload ?? "nil")
    check("BUG-070 a framework data request is not prepared as an unknown contract",
          CLICompletion.requests.filter { $0.label == "ui-studio:prepare" }.count == preparedBefore
          && session.requests.contains { $0.contract == "GET /" && $0.outcome == "allowed" })

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

    // An answer request changes nothing (AC-11, DEC-010): the one request box, answered by the assistant.
    watchdog.reached("An answer request changes nothing")
    session.change("What does this button do?")
    _ = await idle()
    let question = session.history.last
    check("AC-11 an answer request is answered", question?.kind == .question && question?.status == .answered && question?.answer.contains("Add button") == true)
    let status = shell("git status --porcelain", in: root).1
    check("AC-11 an answer request changes nothing", question?.checks.first?.passed == true && status.isEmpty
          && question?.context == nil && question?.files.isEmpty == true && question?.beforeCapture == nil, status)
    let questionRequest = CLICompletion.requests.last
    check("AC-17 the assistant gets read-only project access without the web",
          questionRequest?.readableFolder?.standardizedFileURL.path == root.standardizedFileURL.path && questionRequest?.allowWeb == false
          && questionRequest?.label == "ui-studio:edit" && questionRequest?.jsonSchema != nil,
          "\(questionRequest?.readableFolder?.path ?? "nil") \(questionRequest?.allowWeb ?? true)")
    check("the first question has no earlier conversation", questionRequest?.prompt.contains("previous_conversation") == false)
    check("BUG-075 a turn of an earlier session stays in History, not in the new conversation, and is not sent",
          session.history.first?.id == "op-earlier" && !session.conversation.contains { $0.id == "op-earlier" }
          && CLICompletion.requests.allSatisfy { !$0.prompt.contains("consent banner") })

    // The conversation is a thread with memory: the request being answered stays visible until its turn is in the
    // history, Stop leaves no pending turn behind, and the next question carries the earlier turns.
    watchdog.reached("The conversation keeps the pending turn and remembers the earlier turns")
    CLICompletion.answer = { request in
        if request.label == "ui-studio:edit" { try await Task.sleep(nanoseconds: 1_500_000_000) }
        return assistant.respond(request)
    }
    session.change("And why is it here?")
    let pendingShown = await waitUntil(5) { session.pendingTurn != nil && CLICompletion.requests.count > 0 && session.busy != nil }
    let pending = session.pendingTurn
    check("a request shows as a pending turn while the assistant works", pendingShown
          && pending?.request == "And why is it here?" && pending?.element.hasPrefix("button#add") == true
          && session.history.last?.id == question?.id, "\(String(describing: pending))")
    _ = await idle()
    check("the pending turn is gone once the answer is in the history", session.pendingTurn == nil
          && session.history.last?.request == "And why is it here?" && session.history.last?.status == .answered)
    let followUp = CLICompletion.requests.last { $0.label == "ui-studio:edit" }?.prompt ?? ""
    check("the next question carries the first turn's question and answer", followUp.contains("What does this button do?")
          && followUp.contains("This is the Add button; it posts a new item.") && followUp.contains("button#add"), String(followUp.suffix(900)))
    let answered = session.history.count
    session.change("Is it accessible?")
    _ = await waitUntil(5) { session.pendingTurn != nil }
    try? await Task.sleep(nanoseconds: 200_000_000)
    session.cancelWork()
    _ = await idle()
    check("Stop leaves no pending turn and adds no turn", session.pendingTurn == nil && session.history.count == answered,
          "\(String(describing: session.pendingTurn)) \(session.history.count)")
    CLICompletion.answer = { request in assistant.respond(request) }

    // Clear starts a new conversation: the thread empties, the assistant forgets it, History keeps every turn (BUG-075).
    check("BUG-075 the conversation holds this session's turns", session.conversation.map(\.request) == ["What does this button do?", "And why is it here?"],
          session.conversation.map(\.request).joined(separator: " | "))
    session.clearConversation()
    check("BUG-075 Clear empties the conversation and keeps History", session.conversation.isEmpty && session.history.count == answered)
    session.change("Where does it post?")
    _ = await idle()
    let fresh = CLICompletion.requests.last { $0.label == "ui-studio:edit" }?.prompt ?? ""
    check("BUG-075 after Clear the assistant gets no earlier turns", !fresh.contains("previous_conversation")
          && !fresh.contains("What does this button do?") && session.conversation.map(\.request) == ["Where does it post?"], String(fresh.suffix(400)))

    // A change is applied, the app reloads, the scenario is restored and verified (AC-12, AC-13).
    watchdog.reached("A change is applied, the app reloads, the scenario is restored and verified")
    assistant.lock.withLock { assistant.edits = [edit("title", "<h1 class=\"title\">Items</h1>", "<h1 class=\"title\">All items</h1>")] }
    session.change("Rename the heading to All items")
    let verifying = await waitUntil(30) { session.history.last?.request == "Rename the heading to All items" && session.busy != nil }
    check("a change being verified is a turn of the thread, not a pending turn as well", verifying && session.pendingTurn == nil,
          "\(verifying) \(String(describing: session.pendingTurn))")
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
    let changePrompt = CLICompletion.requests.last { $0.label == "ui-studio:edit" }?.prompt ?? ""
    check("a change request carries this conversation's question, not those before Clear", changePrompt.contains("Where does it post?")
          && !changePrompt.contains("What does this button do?"), String(changePrompt.suffix(900)))

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
        check("REQ-004 the answer reaches the assistant with the question it asked",
              clarifiedPrompt.contains("Only this paragraph, or every paragraph of the section?"), String(clarifiedPrompt.suffix(900)))
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

    // BUG-069: an element made by a bundled chunk is traced to its source file through the chunk's source map; a chunk
    // without a map falls back to searching for the component, offered as a candidate.
    watchdog.reached("A bundled chunk's element is traced to its source file")
    let chunks = web.appendingPathComponent("_next/static/chunks")
    try? fm.createDirectory(at: chunks, withIntermediateDirectories: true)
    try? fm.createDirectory(at: web.appendingPathComponent("src"), withIntermediateDirectories: true)
    try? chunkHTML.write(to: web.appendingPathComponent("chunk.html"), atomically: true, encoding: .utf8)
    try? chunkJS.write(to: chunks.appendingPathComponent("app_0abc._.js"), atomically: true, encoding: .utf8)
    try? cardTSX.write(to: web.appendingPathComponent("src/Card.tsx"), atomically: true, encoding: .utf8)
    let cardURL = web.appendingPathComponent("src/Card.tsx").absoluteString
    try? #"{"version":3,"sources":[],"sections":[{"offset":{"line":0,"column":0},"map":{"version":3,"sources":["\#(cardURL)"],"names":[],"mappings":"AAAA;AACA;AAIA;AACA"}}]}"#
        .write(to: chunks.appendingPathComponent("app_0abc._.js.map"), atomically: true, encoding: .utf8)
    var chunkScenario = session.scenario
    chunkScenario.id = "chunk"
    chunkScenario.name = "Chunk"
    chunkScenario.route = "/chunk.html"
    chunkScenario.steps = []
    session.activate(chunkScenario)
    _ = await idle()
    session.setMode(.select)
    try? await Task.sleep(nanoseconds: 600_000_000)
    await clickElement(".card")
    _ = await waitUntil(10) { session.selection?.tag.hasPrefix("div.card") == true }
    let traced = session.selection
    check("BUG-069 the element's source file and line come from the chunk's source map",
          traced?.sourcePath == "web/src/Card.tsx" && traced?.line == 6 && traced?.mapping == .exact,
          "\(traced?.sourcePath ?? "nil"):\(traced?.line ?? -1) \(traced.map { "\($0.mapping)" } ?? "nil")")
    session.setMode(.interact)
    let unmapped = StudioSelectionContext(["rect": ["x": 0, "y": 0, "width": 10, "height": 10], "tag": "div.card", "selector": "div.card",
                                           "source": ["framework": "react", "mapping": "component", "component": "Card",
                                                      "file": "http://127.0.0.1:\(port)/_next/static/chunks/missing_0x._.js",
                                                      "generatedLine": 3, "generatedColumn": 20, "generatedOwn": true]])!
    let fallback = StudioSourceResolution.resolve(unmapped, root: root, appFolder: web, tagName: "div")
    check("BUG-069 a chunk without a usable map falls back to the component's file as a candidate",
          fallback.path == "web/src/Card.tsx" && fallback.mapping == .candidate && fallback.line == 3,
          "\(fallback.path ?? "nil"):\(fallback.line ?? -1) \(fallback.mapping)")

    // BUG-071: recording keeps writing steps after the application loads another page, and Reset replays them across it.
    watchdog.reached("Recording follows the application to another page")
    try? recordHTML.write(to: web.appendingPathComponent("rec.html"), atomically: true, encoding: .utf8)
    try? recordNextHTML.write(to: web.appendingPathComponent("rec-next.html"), atomically: true, encoding: .utf8)
    var recordScenario = session.scenario
    recordScenario.id = "record"
    recordScenario.name = "Record"
    recordScenario.route = "/rec.html"
    recordScenario.steps = []
    session.activate(recordScenario)
    _ = await idle()
    session.setMode(.record)
    _ = await idle()
    check("BUG-071 recording starts", session.mode == .record, "\(session.mode)")
    await clickElement("#go")
    _ = await waitUntil(5) { session.recordedSteps.count == 1 }
    await clickElement("#next")
    var nextPath: String?
    for _ in 0..<100 {
        nextPath = await text("return document.getElementById('q') ? location.pathname : '';")
        if nextPath == "/rec-next.html" { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    check("BUG-071 the link loads the next page", nextPath == "/rec-next.html", nextPath ?? "nil")
    _ = try? await session.call("const q = document.getElementById('q'); q.value = 'milk'; q.dispatchEvent(new Event('change', { bubbles: true })); return true;")
    await clickElement("#done")
    _ = await waitUntil(5) { session.recordedSteps.count >= 4 }
    let recorded = session.recordedSteps.map { "\($0.action.rawValue) \($0.selector ?? "") \($0.text ?? "")".trimmingCharacters(in: .whitespaces) }
    check("BUG-071 the steps on the page the link loaded are recorded too",
          recorded == ["click #go", "click #next", "type #q milk", "click #done"], recorded.joined(separator: " | "))
    session.setMode(.interact)
    session.saveScenario(name: "Record trip", kind: .custom)
    session.reset()
    _ = await idle()
    let replayed = await text("return location.pathname + ' ' + (document.body.dataset.done || '');")
    check("BUG-071 Reset replays the steps across the page load", replayed == "/rec-next.html milk", replayed ?? "nil")
    check("BUG-071 the replay reports no failed step", !(session.notice ?? "").contains("restoration step failed"), session.notice ?? "")

    await contextChecks(session, web: web, root: root, assistant: assistant, text: text, idle: idle)
    await browserChecks(session, web: web, root: root, text: text, idle: idle, clickElement: clickElement)
    finish(session, port: port)
}

/// REQ-013 and DEC-010 in a real session: requests without a selection are about the page; a context change becomes a new
/// saved scenario that the page shows, with no source file written; a refused change is corrected once; Undo returns to
/// the scenario it was made from and keeps the new one; an answer changes nothing; a code change works without a selection.
@MainActor
func contextChecks(_ session: StudioSession, web: URL, root: URL, assistant: Assistant, text: (String) async -> String?,
                   idle: () async -> Bool) async {
    watchdog.reached("REQ-013 context changes from the one request box")
    let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Context</title></head><body>
    <ul id="items"></ul>
    <button id="book" data-testid="open-booking" onclick="document.getElementById('booking-dialog').hidden = false">Book</button>
    <div id="booking-dialog" hidden>Booking</div>
    <script>
    fetch('/api/items').then(r => r.json()).then(items => {
      document.getElementById('items').innerHTML = items.map(i => '<li>' + i.name + '</li>').join('');
    });
    </script>
    </body></html>

    """
    try? page.write(to: web.appendingPathComponent("context.html"), atomically: true, encoding: .utf8)
    // A clean tree, so that what a request writes is all that `git status` shows.
    _ = shell("git add -A && git -c user.email=t@example.com -c user.name=Test commit -qm context", in: root)
    func status() -> String { shell("git status --porcelain", in: root).1 }
    func items() async -> String? { await text("return Array.from(document.querySelectorAll('#items li')).map(l => l.textContent).join(',');") }
    func editRequests() -> [CLICompletion.Request] { CLICompletion.requests.filter { $0.label == "ui-studio:edit" } }
    var base = session.scenario
    base.id = "context-base"
    base.name = "Context base"
    base.route = "/context.html"
    base.steps = []
    base.overrides = []
    base.data = nil
    session.activate(base)
    _ = await idle()
    session.clearSelection()
    _ = await waitUntil(5) { true }
    let baseline = await items()
    check("REQ-013 the context page shows the baseline records", baseline == "Alpha,Beta" && session.selection == nil, baseline ?? "nil")
    let savedBefore = session.savedScenarios.count

    // An answer without a selection changes nothing: no scenario, no file, the same page.
    assistant.lock.withLock { assistant.edits = [answerPlan("The list shows the items from /api/items.")] }
    session.change("Where do these items come from?")
    _ = await idle()
    let answer = session.history.last
    let answerPrompt = editRequests().last?.prompt ?? ""
    let afterAnswer = await items()
    check("DEC-010 an answer request changes nothing", answer?.kind == .question && answer?.status == .answered
          && answer?.answer == "The list shows the items from /api/items." && session.scenario.id == base.id
          && session.savedScenarios.count == savedBefore && status().isEmpty && afterAnswer == "Alpha,Beta",
          "\(answer?.kind.rawValue ?? "nil") \(answer?.status.rawValue ?? "nil") \(status())")
    check("DEC-010 a request without a selection is about the page, with its picture", answerPrompt.hasPrefix("No element is selected")
          && answerPrompt.contains("Page route: /context.html") && answer?.selection == "page /context.html"
          && editRequests().last?.images.first.map { FileManager.default.fileExists(atPath: $0.path) } == true, String(answerPrompt.prefix(300)))
    check("REQ-013 the prompt lists the environment for a context change", answerPrompt.contains("- items (id field id, 2 records): name:string!")
          && answerPrompt.contains("Ids: 1, 2") && answerPrompt.contains("- list-items: GET /api/items → list items")
          && answerPrompt.contains("Current scenario \"Context base\"") && !answerPrompt.contains("markview-test-token"), answerPrompt)

    // A data request without a selection is a context change, not code edits: stray edits are never written.
    assistant.lock.withLock {
        assistant.edits = [contextPlan(name: "Random numbers", data: #"{"items":[{"id":1,"name":"417"},{"id":2,"name":"92"},{"id":3,"name":"3051"}]}"#,
                                       edits: [["path": "web/context.html", "search": "<title>Context</title>", "replace": "<title>Numbers</title>"]])]
    }
    session.change("Fill it with random numbers")
    _ = await idle()
    let filled = session.history.last
    let numbers = await items()
    let made = filled?.context?.scenarioId ?? ""
    let changed = status()
    check("DEC-010 a data request without a selection makes a context change, not code edits", filled?.kind == .context
          && filled?.status == .applied && filled?.files.isEmpty == true && filled?.patch.isEmpty == true
          && ((try? String(contentsOf: web.appendingPathComponent("context.html"), encoding: .utf8)) ?? "").contains("<title>Context</title>"),
          "\(filled?.kind.rawValue ?? "nil") \(filled?.status.rawValue ?? "nil") \(filled?.answer ?? "")")
    check("REQ-013 the context change is a new saved scenario, active, with the request as description", !made.isEmpty
          && session.scenario.id == made && session.scenario.name == "Random numbers" && session.scenario.description == "Fill it with random numbers"
          && session.savedScenarios.contains { $0.id == made } && filled?.context?.previousScenarioId == base.id
          && filled?.selection == "page /context.html", "\(made) \(session.scenario.id)")
    check("REQ-013 the page shows the new scenario's records", numbers == "417,92,3051", numbers ?? "nil")
    check("REQ-013 only the new scenario's file is written", !changed.isEmpty && changed.split(separator: "\n").allSatisfy { $0.contains(".markview/studio/scenarios/") },
          changed)
    check("REQ-013 the context change is verified and captured", filled?.checks.allSatisfy(\.passed) == true
          && filled?.checks.map(\.name) == ["Scenario saved", "Page loaded in the new scenario", "No runtime errors", "Project files unchanged"]
          && filled?.beforeCapture != nil && filled?.afterCapture != nil && filled?.context?.lines == ["Records: items 2 → 3"],
          filled?.checks.map { "\($0.name)=\($0.passed) \($0.detail)" }.joined(separator: "; ") ?? "nil")

    // Restoration steps open a page state; the new scenario is derived from the current one, its records included.
    assistant.lock.withLock {
        assistant.edits = [contextPlan(name: "Booking dialog", steps: [["action": "click", "selector": "[data-testid=open-booking]", "text": "", "ms": 0]])]
    }
    session.change("Show me the booking dialog")
    _ = await idle()
    let dialog = session.history.last
    let opened = await text("return String(document.getElementById('booking-dialog').hidden);")
    let dialogItems = await items()
    let dialogPrompt = editRequests().last?.prompt ?? ""
    check("REQ-013 restoration steps open the dialog in the new scenario", dialog?.status == .applied && opened == "false"
          && dialog?.context?.steps == ["click [data-testid=open-booking]"] && dialogItems == "417,92,3051"
          && dialog?.checks.contains { $0.name == "Restoration steps replayed" && $0.passed } == true,
          "\(opened ?? "nil") \(dialogItems ?? "nil") \(dialog?.checks.map { "\($0.name)=\($0.passed) \($0.detail)" } ?? [])")
    check("REQ-013 the next request remembers the context change", dialogPrompt.contains("(context change · page /context.html)")
          && dialogPrompt.contains("New scenario: Random numbers (made from Context base)"), String(dialogPrompt.suffix(1200)))

    // A refused change is sent back once with its problems; refused twice, nothing changes.
    let current = session.scenario.id, saved = session.savedScenarios.count, sent = editRequests().count
    assistant.lock.withLock {
        assistant.edits = [contextPlan(name: "Users", data: #"{"users":[{"id":1,"name":"Ann"}]}"#),
                           contextPlan(name: "Users", data: #"{"items":[{"id":"x"}]}"#)]
    }
    session.change("Add some users")
    _ = await idle()
    let refused = session.history.last
    let retry = editRequests().last?.prompt ?? ""
    check("REQ-013 an invalid context change is retried once with its problems", editRequests().count == sent + 2
          && retry.contains("Your previous context change was refused") && retry.contains("unknown entity users"), String(retry.suffix(600)))
    check("REQ-013 a context change refused twice changes nothing", refused?.kind == .context && refused?.status == .failed
          && refused?.answer.contains("was refused") == true && session.scenario.id == current && session.savedScenarios.count == saved,
          refused?.answer ?? "nil")

    // A refused change corrected on the retry is applied; added records join the current ones.
    assistant.lock.withLock {
        assistant.edits = [contextPlan(name: "One more", addData: #"{"items":[{"id":1,"name":"Again"}]}"#),
                           contextPlan(name: "One more", addData: #"{"items":[{"id":9,"name":"Nine"}]}"#)]
    }
    session.change("Add one more item")
    _ = await idle()
    let corrected = session.history.last
    let more = await items()
    check("REQ-013 a corrected context change is applied, and added records join the current ones", corrected?.status == .applied
          && more == "417,92,3051,Nine" && corrected?.context?.previousScenarioName == "Booking dialog", "\(more ?? "nil") \(corrected?.answer ?? "")")

    // Undo returns to the scenario the change was made from; the new scenario stays saved.
    if let filled {
        session.undo(filled.id)
        _ = await idle()
        let back = await items()
        check("REQ-013 Undo of a context change returns to the previous scenario", session.scenario.id == base.id && back == "Alpha,Beta"
              && session.history.first { $0.id == filled.id }?.status == .undone, "\(session.scenario.id) \(back ?? "nil")")
        check("REQ-013 Undo keeps the new scenario saved", session.savedScenarios.contains { $0.id == made }
              && FileManager.default.fileExists(atPath: StudioStore.scenariosFolder(root).appendingPathComponent(made + ".json").path)
              && (session.notice ?? "").contains("stays saved"), session.notice ?? "")
    }

    // A code change works without a selection too: the prompt has the page, the edit is written and verified.
    assistant.lock.withLock {
        assistant.edits = [edit("page", "<title>Context</title>", "<title>Context page</title>", path: "web/context.html")]
    }
    session.change("Rename the page title")
    _ = await idle()
    let code = session.history.last
    let codePrompt = editRequests().last?.prompt ?? ""
    check("DEC-010 a code change without a selection edits the source", code?.kind == .edit && code?.status == .applied
          && code?.files.map(\.path) == ["web/context.html"] && code?.selection == "page /context.html"
          && codePrompt.hasPrefix("No element is selected") && !codePrompt.contains("Selected element"), "\(code?.status.rawValue ?? "nil") \(code?.answer ?? "")")
    if let code {
        session.undo(code.id)
        _ = await idle()
    }
}

/// REQ-008 in a real session: the scenario's browser settings reach the page and its uses are listed; kept cookies
/// (httpOnly included) and localStorage survive Reset, the kept localStorage is written once per generation, and
/// confidential entries are not kept.
@MainActor
func browserChecks(_ session: StudioSession, web: URL, root: URL, text: (String) async -> String?, idle: () async -> Bool,
                   clickElement: (String) async -> Void) async {
    watchdog.reached("REQ-008 browser settings in a session")
    let selector = #selector(WKUIDelegate.webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:))
    check("REQ-008 the session answers WebKit's camera and microphone requests (with a denial)", session.responds(to: selector))
    try? keepHTML.write(to: web.appendingPathComponent("keep.html"), atomically: true, encoding: .utf8)
    var keepScenario = session.scenario
    keepScenario.id = "keep"
    keepScenario.name = "Keep"
    keepScenario.route = "/keep.html"
    keepScenario.steps = []
    session.activate(keepScenario)
    _ = await idle()
    let chicago = StudioBrowserProfile.Place(latitude: 41.8781, longitude: -87.6298, accuracy: 30, label: "Chicago")
    session.setBrowserProfile(StudioBrowserProfile(location: .place(chicago), clipboardText: "SAVE20"))
    _ = await idle()
    let located = await text("""
        const p = await new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(resolve, reject));
        await navigator.clipboard.writeText('private text');
        return p.coords.latitude + ',' + p.coords.longitude + ' ' + await navigator.clipboard.readText();
        """)
    check("REQ-008 the scenario's place and clipboard reach the page", located == "41.8781,-87.6298 private text", located ?? "nil")
    _ = await waitUntil(5) { session.dependencies.contains { $0.id == "browser:clipboard" } }
    check("REQ-008 the page's uses are listed as browser dependencies of the session",
          session.dependencies.contains { $0.id == "browser:geolocation" && $0.mode == .simulated && $0.note.contains("Chicago") }
          && session.dependencies.contains { $0.id == "browser:clipboard" }, session.dependencies.map(\.id).joined(separator: ", "))
    check("REQ-008 a clipboard write is shown in Studio without its contents",
          session.events.contains { $0.kind == .browser && $0.detail == "clipboard: write (12 chars)" }
          && !session.events.contains { $0.detail.contains("private text") })
    check("REQ-008 the browser settings stay with the scenario", session.scenario.browser?.location == .place(chicago))

    // The consent banner comes back after every restore until its answer is kept.
    watchdog.reached("REQ-008 kept cookies and storage survive Reset")
    let bannerShown = await text("return String(document.querySelector('.consent') !== null);")
    await clickElement(".accept")
    try? await Task.sleep(nanoseconds: 300_000_000)
    let host = session.appURL?.host ?? "127.0.0.1"
    let store = session.webView.configuration.websiteDataStore.httpCookieStore
    if let serverCookie = HTTPCookie(properties: [.name: "prefs", .value: "compact", .domain: host, .path: "/",
                                                  .expires: Date().addingTimeInterval(86_400), HTTPCookiePropertyKey("HttpOnly"): "TRUE"]) {
        await store.setCookie(serverCookie)
    }
    session.keepBrowserData()
    _ = await idle()
    let kept = session.spec.keptBrowserData
    check("REQ-008 the page's cookies, httpOnly ones too, and its localStorage are kept",
          kept?.cookies.map(\.name).sorted() == ["cookie_consent", "prefs"] && kept?.cookies.first { $0.name == "prefs" }?.httpOnly == true
          && kept?.localStorage.map(\.key) == ["consent"], "\(kept?.cookies.map(\.name) ?? []) \(kept?.localStorage.map(\.key) ?? [])")
    check("REQ-008 confidential entries are not kept and are listed",
          session.keptSkipped.contains { $0.hasPrefix("cookie session_id ") } && session.keptSkipped.contains { $0.hasPrefix("localStorage auth-token ") },
          session.keptSkipped.joined(separator: " | "))
    func environmentFile() -> String { (try? String(contentsOf: StudioStore.environmentURL(root), encoding: .utf8)) ?? "" }
    _ = await waitUntil(3) { environmentFile().contains("cookie_consent") }
    let file = environmentFile()
    check("REQ-008 the kept data is in environment.json, without the confidential values",
          file.contains("cookie_consent") && file.contains("\"consent\"") && !file.contains(keepSessionID) && !file.contains("eyJhbGciOiJIUzI1NiJ9"))
    session.reset()
    _ = await idle()
    // Cookie names and one comparison only: test output never holds cookie values.
    let afterReset = await text("""
        const names = document.cookie.split('; ').map(c => c.split('=')[0]).filter(Boolean).sort().join(',');
        return [String(document.querySelector('.consent') === null), String(window.consentAtStart),
                String(document.cookie.split('; ').includes('cookie_consent=accepted')), names].join(' ');
        """)
    check("REQ-008 the banner shown while nothing was kept is gone after Reset: the kept answer is there before the page's scripts",
          bannerShown == "true" && afterReset == "true yes true cookie_consent", afterReset ?? "nil")
    let restored = await store.allCookies()
    check("REQ-008 a kept httpOnly cookie is set again", restored.contains { $0.name == "prefs" && $0.isHTTPOnly && $0.value == "compact" },
          restored.map(\.name).joined(separator: ","))

    // Once per generation: a reload of the same generation keeps what the application changed; Reset writes it again.
    watchdog.reached("REQ-008 kept localStorage is written once per generation")
    _ = await text("localStorage.setItem('consent', 'later'); return 'ok';")
    session.reload()
    _ = await idle()
    let reloaded = await text("return String(window.consentAtStart);")
    session.reset()
    _ = await idle()
    let again = await text("return String(window.consentAtStart);")
    check("REQ-008 a reload in the same generation keeps what the application changed; Reset writes the kept entry again",
          reloaded == "later" && again == "yes", "\(reloaded ?? "nil") \(again ?? "nil")")

    // A scenario switch keeps them too; forgetting brings the question back.
    var other = session.scenario
    other.id = "keep-other"
    other.name = "Keep other"
    session.activate(other)
    _ = await idle()
    let switched = await text("return String(document.querySelector('.consent') === null);")
    check("REQ-008 kept data survives a scenario switch", switched == "true", switched ?? "nil")
    session.forgetKeptStorage("consent")
    session.reset()
    _ = await idle()
    let forgotten = await text("return String(document.querySelector('.consent') !== null);")
    check("REQ-008 a forgotten entry is no longer set again", switched == "true" && forgotten == "true"
          && session.spec.keptBrowserData?.localStorage.isEmpty != false
          && session.spec.keptBrowserData?.cookies.isEmpty == false, forgotten ?? "nil")
    session.forgetKeptBrowserData()
    let removed = await waitUntil(3) { !environmentFile().contains("cookie_consent") }
    check("REQ-008 forgetting everything removes the kept data", session.spec.keptBrowserData == nil && removed
          && StudioStore.loadEnvironment(root)?.keptBrowserData == nil)
}

let keepSessionID = "4f9a1c2e8b7d6a5f3e2d1c0b9a8f7e6d"
/// REQ-008: a consent banner shown until the answer is stored; accepting also stores a session cookie and a token, which
/// must not be kept.
let keepHTML = """
<!doctype html><html><head><meta charset="utf-8"><title>Keep</title></head><body>
<p class="content">Content</p>
<script>
window.consentAtStart = localStorage.getItem('consent');
if (!localStorage.getItem('consent')) {
  const banner = document.createElement('section');
  banner.className = 'consent';
  banner.innerHTML = '<button class="accept">Accept all</button>';
  document.body.insertBefore(banner, document.body.firstChild);
  banner.querySelector('.accept').addEventListener('click', () => {
    localStorage.setItem('consent', 'yes');
    localStorage.setItem('auth-token', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJlLXZhbHVlLWhlcmU');
    document.cookie = 'cookie_consent=accepted; path=/; max-age=31536000';
    document.cookie = 'session_id=\(keepSessionID); path=/';
    banner.remove();
  });
}
</script></body></html>
"""

@MainActor
func finish(_ session: StudioSession, port: Int? = nil) {
    Task { @MainActor in
        // Closing stops the server the session started (AC-18).
        await session.close()
        if let port {
            let answering = await WebAppPreview.firstAnswering([port], timeout: 1)
            check("AC-18 closing the session stops the server it started", answering == nil && session.state == .stopped)
            await externalServerCheck()
            await serverRequestChecks()
            await lateRuleChecks()
            await serverClockChecks()
            await logChecks()
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

/// REQ-007, DEC-006: a server-rendered target whose server calls another service itself. The server loads `.env.local` like
/// dotenv (the environment wins), calls `API_URL/rates` with `Bearer $API_SECRET` and renders the rate; it writes only booleans
/// about what it saw to `seen.json`. REQ-011: `/account` answers 307 to the sign-in page `/auth/login`, and with `verbose` the
/// server prints the file's real secret in the shapes a log line takes (alone, as a bearer value, in a query).
let ratesServer = #"""
import json, os, sys, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from_file = {}
for line in open('.env.local'):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        key, value = line.split('=', 1)
        from_file[key.strip()] = value.strip()
        os.environ.setdefault(key.strip(), value.strip())
if sys.argv[2:] == ['verbose']:
    real = from_file.get('API_SECRET', '')
    print('loaded the key ' + real + ' from .env.local', flush=True)
    print('Authorization: Bearer ' + real, flush=True)
    print('calling ' + from_file.get('API_URL', '') + '/rates?key=' + real, flush=True)
    print('Error: the rates service is not configured for ' + real, flush=True)
class Handler(BaseHTTPRequestHandler):
    def page(self, status, body, location=None):
        self.send_response(status)
        if location:
            self.send_header('Location', location)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith('/account'):
            return self.page(307, b'', '/auth/login')
        if self.path.startswith('/auth/login'):
            return self.page(200, b'<!doctype html><html><head><title>Sign in</title></head><body><p id="login">Sign in</p></body></html>')
        base = os.environ.get('API_URL', '')
        try:
            request = urllib.request.Request(base + '/rates', headers={'Authorization': 'Bearer ' + os.environ.get('API_SECRET', '')})
            with urllib.request.urlopen(request, timeout=3) as answer:
                rate = str(json.loads(answer.read()).get('rate'))
        except Exception:
            rate = 'error'
        with open('renders.log', 'a') as renders:
            renders.write(self.path + '\n')
        with open('seen.json', 'w') as seen:
            json.dump({'simulated': base.startswith('http://127.0.0.1:'), 'testSecret': os.environ.get('API_SECRET', '').startswith('markview-test-'),
                       'clock': bool(os.environ.get('MARKVIEW_STUDIO_CLOCK')), 'noProxy': '127.0.0.1' in os.environ.get('NO_PROXY', '')}, seen)
        body = ('<!doctype html><html><head><title>Rates</title></head><body><p id="rate">%s</p><p id="pid">%d</p></body></html>' % (rate, os.getpid())).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
"""#

/// The real value of the rates server's `API_SECRET` in its `.env.local`; it must reach no prompt, log or saved file.
let fakeServerSecret = "real-secret-do-not-leak-4711"

@MainActor
func serverRequestChecks() async {
    watchdog.reached("The development server's own requests are simulated")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-server-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let secret = fakeServerSecret
    try? ratesServer.write(to: root.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    try? "API_URL=http://rates.example.test/v2\nAPI_SECRET=\(secret)\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    let assistant = Assistant()
    assistant.proposal = ["rules": [["id": "rates", "method": "GET", "path": "http://rates.example.test/v2/rates", "operation": "respond",
                                     "responseStatus": 200, "responseBody": #"{"rate":1.23}"#,
                                     "evidence": [["kind": "observation", "detail": "Requested by the server"]]]],
                          "assumptions": ["The rates service returns a rate."]]
    // The agent needs longer than the server gives its call (3 s): a rule prepared when the request arrives comes too late
    // for that render, so the page must be prepared ahead (BUG-074).
    CLICompletion.answer = { request in
        try await Task.sleep(nanoseconds: 4_000_000_000)
        return assistant.respond(request)
    }
    let promptsBefore = CLICompletion.requests.count
    let port = freePort()
    let session = StudioSession(root: root)
    func text(_ script: String) async -> String? { (try? await session.call(script)) as? String }
    func seen() -> [String: Bool] {
        (try? Data(contentsOf: root.appendingPathComponent("seen.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Bool] } ?? [:]
    }
    session.start(WebAppTarget(folder: root, label: "rates", command: "python3 server.py \(port)", ports: [port]))
    _ = await waitUntil(90) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    check("REQ-007 the server MarkView starts is found and opened", session.ownsServer && session.appURL != nil, "\(session.state) \(session.stateDetail)")
    check("REQ-007 the service address is found in the env file", session.serverConnections.map(\.variable) == ["API_URL"]
          && session.serverConnections.first?.origin == "http://rates.example.test" && session.serverConnections.first?.basePath == "/v2",
          "\(session.serverConnections)")
    // The page's services were prepared before it loaded, so its first render is already simulated (BUG-074).
    let rate = await text("return document.getElementById('rate') ? document.getElementById('rate').textContent : '';")
    // The server was found listening: no probe rendered the page (and made its requests) before the first load (BUG-076).
    let renders = ((try? String(contentsOf: root.appendingPathComponent("renders.log"), encoding: .utf8)) ?? "").split(separator: "\n")
    check("BUG-076 the server is found without rendering the page: one render, the first load", renders.count == 1,
          renders.joined(separator: " "))
    check("BUG-074 the first render is simulated although the agent is slower than the server's own deadline", rate == "1.23", rate ?? "nil")
    let ahead = CLICompletion.requests.dropFirst(promptsBefore).filter { $0.label == "ui-studio:prepare" }
    check("BUG-074 the page is prepared ahead, with the service's address and variable", ahead.first?.prompt.contains("before it loads") == true
          && ahead.first?.prompt.contains("API_URL → http://rates.example.test/v2") == true, ahead.first.map { String($0.prompt.prefix(400)) } ?? "no prompt")
    check("BUG-074 the prepared route is saved, so later sessions do not ask again",
          StudioStore.loadEnvironment(root)?.preparedRoutes == ["/"], "\(String(describing: StudioStore.loadEnvironment(root)?.preparedRoutes))")
    let callsAfterStart = CLICompletion.requests.count
    session.reset()
    _ = await waitUntil(60) { session.busy == nil && [.ready, .degraded, .failed].contains(session.state) }
    check("BUG-074 a Reset does not prepare the page again", CLICompletion.requests.count == callsAfterStart,
          "\(CLICompletion.requests.count - callsAfterStart) more calls")
    let view = seen()
    check("REQ-007 the server ran with the gateway address, a test secret, no proxy and the clock file",
          view["simulated"] == true && view["testSecret"] == true && view["noProxy"] == true && view["clock"] == true, "\(view)")
    check("REQ-007 the request keeps the service's address and is shown as the server's",
          session.requests.contains { $0.transport == "server" && $0.contract == "GET http://rates.example.test/v2/rates" },
          session.requests.map { "\($0.transport) \($0.contract)" }.joined(separator: " | "))
    let prompts = CLICompletion.requests.dropFirst(promptsBefore).filter { $0.label == "ui-studio:prepare" }
    check("REQ-007 the assistant is told the server makes the requests", prompts.contains { $0.prompt.contains("The development server renders this page")
          && $0.prompt.contains("API_URL") }, prompts.last.map { String($0.prompt.prefix(300)) } ?? "no prompt")
    let environment = (try? String(contentsOf: StudioStore.environmentURL(root), encoding: .utf8)) ?? ""
    let everything = CLICompletion.requests.map(\.prompt).joined() + session.requests.map(\.url).joined() + session.serverLog + environment
        + session.serverNotes.joined() + "\(session.serverConnections)"
    check("REQ-007 the real secret appears in no prompt, log or saved file", !everything.contains(secret))

    // An error scenario reaches the server's request too.
    var failing = session.scenario
    failing.id = "rates-error"
    failing.name = "Rates fail"
    failing.overrides = [StudioOverride(ruleId: "rates", status: 500)]
    session.activate(failing)
    _ = await waitUntil(60) { session.busy == nil }
    let failed = await text("return document.getElementById('rate') ? document.getElementById('rate').textContent : '';")
    check("REQ-007 a scenario's error answers the server's request", failed == "error", failed ?? "nil")

    // Switching the address to Real restarts the server MarkView started, without the gateway.
    let oldPid = Int32(await text("return document.getElementById('pid').textContent;") ?? "") ?? 0
    session.setConnectionMode("API_URL", .real)
    _ = await waitUntil(90) { session.busy == nil && [.ready, .degraded, .failed].contains(session.state) }
    let newPid = Int32(await text("return document.getElementById('pid') ? document.getElementById('pid').textContent : '';") ?? "") ?? 0
    check("REQ-007 switching to Real restarts the server, and the old one is gone", oldPid > 0 && newPid > 0 && newPid != oldPid
          && kill(oldPid, 0) != 0, "\(oldPid) → \(newPid)")
    check("REQ-007 a real address is not redirected", seen()["simulated"] == false && session.state != .failed, "\(seen()) \(session.state)")
    check("REQ-007 the choice is kept in the environment", StudioStore.loadEnvironment(root)?.serverConnections?.first?.mode == .real)
    await session.close()
}

/// BUG-074: a server request the page ahead did not cover gets its rule after its page rendered without it (the server
/// gave up after 3 s); the rule is kept and the page reloads once by itself, so it shows the simulation without a Reset.
@MainActor
func lateRuleChecks() async {
    watchdog.reached("Rules that arrive after the server gave up reload the page")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-late-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? ratesServer.write(to: root.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    try? "API_URL=http://rates.example.test/v2\nAPI_SECRET=late-secret-4712\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    let rates: [String: Any] = ["rules": [["id": "rates", "method": "GET", "path": "http://rates.example.test/v2/rates", "operation": "respond",
                                           "responseStatus": 200, "responseBody": #"{"rate":4.56}"#,
                                           "evidence": [["kind": "observation", "detail": "Requested by the server"]]]], "assumptions": []]
    // The page ahead finds nothing; the request itself is prepared, slower than the server waits.
    CLICompletion.answer = { request in
        if request.prompt.contains("before it loads") {
            return CLICompletion.Result(text: "", structured: ["rules": [], "assumptions": []], inputTokens: 1, outputTokens: 1, costUSD: 0)
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        return CLICompletion.Result(text: "", structured: rates, inputTokens: 1, outputTokens: 1, costUSD: 0)
    }
    let promptsBefore = CLICompletion.requests.count
    let port = freePort()
    let session = StudioSession(root: root)
    func text(_ script: String) async -> String? { (try? await session.call(script)) as? String }
    session.start(WebAppTarget(folder: root, label: "rates", command: "python3 server.py \(port)", ports: [port]))
    _ = await waitUntil(90) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    var rate = ""
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        rate = await text("return document.getElementById('rate') ? document.getElementById('rate').textContent : '';") ?? ""
        if rate == "4.56" { break }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    check("BUG-074 a rule that arrives after the server gave up reloads the page, which then shows the simulation", rate == "4.56"
          && !session.rulesArrivedLate, "\(rate) \(session.state) \(session.stateDetail)")
    let prompts = CLICompletion.requests.dropFirst(promptsBefore).filter { $0.label == "ui-studio:prepare" }
    check("REQ-007 the assistant is told the server made the request", prompts.contains { $0.prompt.contains("Made by the development server")
          && $0.prompt.contains("API_URL") }, prompts.map { String($0.prompt.prefix(120)) }.joined(separator: " | "))
    check("BUG-074 the late rule is kept for later sessions", StudioStore.loadEnvironment(root)?.rules.contains { $0.id == "rates" } == true)
    await session.close()
}

/// DEC-006: a Node server MarkView starts renders with the scenario's clock, the same clock the page has, so a date it
/// renders (a footer's year) matches the page's and hydration does not fail.
let clockServer = #"""
const http = require('http');
http.createServer((req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.end('<!doctype html><title>Clock</title><p id="server">' + Date.now() + '</p><p id="year">' + new Date().getFullYear() + '</p>');
}).listen(Number(process.argv[2]), '127.0.0.1');
"""#

@MainActor
func serverClockChecks() async {
    let fm = FileManager.default
    guard shell("command -v node", in: fm.temporaryDirectory).0 == 0 else {
        print("skip DEC-006 server clock checks: node is not installed")
        return
    }
    watchdog.reached("The development server runs on the scenario's clock")
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-clock-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? clockServer.write(to: root.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)
    let port = freePort()
    let session = StudioSession(root: root)
    func number(_ script: String) async -> Double? { (try? await session.call(script)) as? Double }
    session.start(WebAppTarget(folder: root, label: "clock", command: "node server.js \(port)", ports: [port]))
    _ = await waitUntil(90) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    let testTime = session.scenario.testTime.timeIntervalSince1970 * 1000
    let server = await number("return Number(document.getElementById('server').textContent);") ?? 0
    let page = await number("return Date.now();") ?? 0
    check("DEC-006 the Node server renders with the scenario's test time", abs(server - testTime) < 120_000,
          "\(Int(server)) vs test \(Int(testTime)), \(session.state) \(session.stateDetail)")
    check("DEC-006 the server's clock and the page's clock agree", server > 0 && abs(page - server) < 30_000, "\(Int(page)) vs \(Int(server))")
    // A restore moves the server's clock back with the page's.
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    session.reset()
    _ = await waitUntil(60) { session.busy == nil }
    let again = await number("return Number(document.getElementById('server').textContent);") ?? 0
    check("DEC-006 a restore moves the server's clock back to the test time", again > 0 && again - testTime < server - testTime + 1_500,
          "\(Int(again - testTime)) after vs \(Int(server - testTime)) before")
    await session.close()
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
    check("REQ-001 server rendering is disclosed with what is simulated and what is not", nextNotes.contains { $0.contains("renders on the server")
          && $0.contains("Server connections") && $0.contains("not simulated") },
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
    check("REQ-001 server-rendered pages disclose that the database is not simulated and the clock follows only Node servers",
          djangoNotes.contains { $0.contains("its database is not") && $0.contains("only Node servers") }, djangoNotes.joined(separator: " | "))
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
application.run()

/// REQ-011: the session log shows what could not be seen before: a server redirect to the sign-in page, rule preparations that
/// ran out of time and the server's output, in the drawer and in `.dde/studio/session.log`, and never the project's real
/// secret, which the server prints.
@MainActor
func logChecks() async {
    watchdog.reached("The session log keeps redirects, preparations and server output, without the secret")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-log-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? ratesServer.write(to: root.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    try? "API_URL=http://rates.example.test/v2\nAPI_SECRET=\(fakeServerSecret)\n".write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    // The agent takes longer than the session's preparation deadline: the preparation ahead of the page and the one for the
    // server's request both time out.
    CLICompletion.answer = { _ in
        try await Task.sleep(nanoseconds: 4_000_000_000)
        return CLICompletion.Result(text: "", structured: ["rules": [], "assumptions": []], inputTokens: 1, outputTokens: 1, costUSD: 0)
    }
    let limits = StudioSession.preparationLimits
    StudioSession.preparationLimits = StudioPreparationLimits(deadline: 1, aheadDeadline: 1, queueWait: 10, maxAttempts: 1, maxConcurrent: 2, maxContracts: 40)
    let port = freePort()
    let session = StudioSession(root: root)
    StudioSession.preparationLimits = limits
    func logFile() -> String { (try? String(contentsOf: StudioStore.logURL(root), encoding: .utf8)) ?? "" }
    session.start(WebAppTarget(folder: root, label: "rates", command: "python3 server.py \(port) verbose", ports: [port]))
    _ = await waitUntil(90) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    check("REQ-011 the session with a slow agent opens", session.appURL != nil, "\(session.state) \(session.stateDetail)")
    // The first render ends when the server's request was answered without a rule.
    var rate = ""
    for _ in 0..<150 where rate.isEmpty {
        rate = ((try? await session.call("return document.getElementById('rate') ? document.getElementById('rate').textContent : '';")) as? String) ?? ""
        if rate.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
    }
    check("REQ-011 the page renders without the rule that timed out", rate == "error", rate)

    // The server sends the page elsewhere; the person sees only the sign-in page.
    let account = URL(string: "/account", relativeTo: session.appURL)?.absoluteString ?? ""
    _ = try? await session.call("location.href = target; return true;", ["target": account])
    let redirected = await waitUntil(30) { logFile().contains("Server redirect") }
    let redirect = logFile().split(separator: "\n").first { $0.contains("Server redirect") }.map(String.init) ?? ""
    check("REQ-011 the log file has the server redirect from the page to the sign-in page", redirected
          && redirect.contains("/account → ") && redirect.contains("/auth/login") && redirect.contains(StudioLogFormat.tag(.navigation, problem: true)), redirect)
    check("REQ-011 the drawer has the redirect, counted as a problem", session.sessionLog.entries.contains {
        $0.kind == .navigation && $0.problem && $0.text.contains("/auth/login") } && session.sessionLog.problems > 0)

    _ = await waitUntil(30) { logFile().contains("GET http://rates.example.test/v2/rates: timedOut") }
    let lines = logFile().split(separator: "\n").map(String.init)
    func tagged(_ kind: StudioLogEntry.Kind, _ problem: Bool, _ text: String) -> Bool {
        lines.contains { $0.contains(StudioLogFormat.tag(kind, problem: problem) + text) }
    }
    let ahead = lines.first { $0.contains("Page /: server requests: timedOut after") } ?? ""
    check("REQ-011 the log has the preparation ahead of the page timing out, with its message", ahead.contains(StudioLogFormat.tag(.preparation, problem: true))
          && ahead.contains("did not finish within 1 s"), lines.filter { $0.contains("preparation") }.joined(separator: "\n"))
    check("REQ-011 the log has the start of a preparation", tagged(.preparation, false, "Preparing Page /: server requests"))
    check("REQ-011 the log has the server request's preparation timing out",
          tagged(.preparation, true, "GET http://rates.example.test/v2/rates: timedOut after"))
    check("REQ-011 the log has the server's own request and how it was answered",
          tagged(.request, false, "GET http://rates.example.test/v2/rates · server · preparing"))
    check("REQ-011 the log has the page loads", tagged(.navigation, false, "Loading http://"))
    check("REQ-011 the log has the server's output, an error line as a problem", tagged(.server, false, "loaded the key ")
          && tagged(.server, true, "Error: the rates service is not configured"), lines.filter { $0.contains(" server ") }.joined(separator: "\n"))
    let everything = logFile() + session.sessionLog.entries.map(\.text).joined(separator: "\n")
    check("REQ-011 the real secret the server printed reaches neither the log file nor the drawer", !everything.contains(fakeServerSecret)
          && lines.contains { $0.contains("loaded the key [redacted:API_SECRET] from .env.local") }
          && lines.contains { $0.contains("/rates?key=[redacted:API_SECRET]") }, lines.filter { $0.contains("key") }.joined(separator: "\n"))
    await session.close()
}
