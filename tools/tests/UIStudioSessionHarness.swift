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
    // Mapped before (REQ-014), at the current version (REQ-016): this session does not map the application, so the
    // environment file stays as committed.
    spec.map = StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true)
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

    // BUG-089: a page's request whose rule takes long is answered "preparing" at once; the page is loaded again when the rule is ready.
    watchdog.reached("BUG-089 a slow rule is answered preparing, then the page is loaded again")
    let scenarioBeforeBug089 = session.scenario
    let provisionalBefore = StudioSession.provisionalAfter
    StudioSession.provisionalAfter = 0.6
    CLICompletion.answer = { request in
        if request.label == "ui-studio:prepare" { try await Task.sleep(nanoseconds: 2_500_000_000) }
        return assistant.respond(request)
    }
    assistant.lock.withLock {
        assistant.proposal = ["rules": [["id": "slow-stats", "method": "GET", "path": "/api/slow-stats", "operation": "respond",
                                         "responseStatus": 200, "responseBody": #"{"open":7}"#,
                                         "evidence": [["kind": "observation", "detail": "Requested by the page"]]]],
                              "assumptions": []]
    }
    let slowAsked = Date()
    let slow = await text("const r = await fetch('/api/slow-stats'); return r.status + ' ' + r.headers.get('x-markview-simulation');")
    let slowElapsed = Date().timeIntervalSince(slowAsked)
    check("BUG-089 the page's request is answered preparing long before its rule is ready", slow == "503 preparing" && slowElapsed < 2.0,
          "\(slow ?? "nil") after \(slowElapsed) s")
    let slowRegistered = await waitUntil(10) { StudioStore.loadEnvironment(root)?.rules.contains { $0.id == "slow-stats" } == true }
    check("BUG-089 the rule is still prepared and kept after the page was answered", slowRegistered)
    let reloaded = await waitUntil(10) { session.sessionLog.entries.contains { $0.text.contains("answered \"preparing\"; the page is loaded again once") } }
    _ = await waitUntil(10) { session.state == .ready || session.state == .degraded }
    let served = await text("const r = await fetch('/api/slow-stats'); return r.status + ' ' + await r.text();")
    check("BUG-089 the page is loaded again once the rule is ready, and then served from it", reloaded && served == "200 {\"open\":7}",
          "\(reloaded) \(served ?? "nil")")
    StudioSession.provisionalAfter = provisionalBefore
    CLICompletion.answer = { request in assistant.respond(request) }

    // BUG-089: switching the scenario does not throw away a rule that is being prepared.
    watchdog.reached("BUG-089 a rule in preparation survives a scenario switch")
    CLICompletion.answer = { request in
        if request.label == "ui-studio:prepare" { try await Task.sleep(nanoseconds: 2_000_000_000) }
        return assistant.respond(request)
    }
    assistant.lock.withLock {
        assistant.proposal = ["rules": [["id": "survives", "method": "GET", "path": "/api/survives", "operation": "respond",
                                         "responseStatus": 200, "responseBody": #"{"kept":true}"#,
                                         "evidence": [["kind": "observation", "detail": "Requested by the page"]]]],
                              "assumptions": []]
    }
    Task { _ = await text("const r = await fetch('/api/survives'); return String(r.status);") }
    _ = await waitUntil(5) { session.preparation.records["GET /api/survives"]?.status == .preparing }
    var other = session.scenario
    other.id = "survive-switch"
    other.name = "Survive switch"
    session.activate(other)
    _ = await idle()
    let survived = await waitUntil(10) { StudioStore.loadEnvironment(root)?.rules.contains { $0.id == "survives" } == true }
    check("BUG-089 the rule prepared while the scenario changed is registered, not cancelled", survived
          && session.preparation.records["GET /api/survives"]?.status == .registered,
          "\(session.preparation.records["GET /api/survives"]?.status.rawValue ?? "nil") \(session.preparation.records["GET /api/survives"]?.message ?? "")")
    CLICompletion.answer = { request in assistant.respond(request) }

    // BUG-088: a restore for the same test user keeps the sign-in cookies; consent and the like are cleared; another user starts signed out.
    watchdog.reached("BUG-088 sign-in cookies survive a restore for the same test user")
    _ = await text("document.cookie = 'sb-demo-auth-token=abc123; path=/'; document.cookie = 'cookie_consent=yes; path=/'; return document.cookie;")
    var sameUser = session.scenario
    sameUser.id = "same-user"
    sameUser.name = "Same user"
    session.activate(sameUser)
    _ = await idle()
    let cookiesAfterSwitch = await text("return document.cookie;") ?? ""
    check("BUG-088 the sign-in cookie stays after a switch to a scenario of the same user, the consent cookie does not",
          cookiesAfterSwitch.contains("sb-demo-auth-token=abc123") && !cookiesAfterSwitch.contains("cookie_consent"), cookiesAfterSwitch)
    session.reset()
    _ = await idle()
    let cookiesAfterReset089 = await text("return document.cookie;") ?? ""
    check("BUG-088 Reset starts signed out, as before", !cookiesAfterReset089.contains("sb-demo-auth-token"), cookiesAfterReset089)
    _ = await text("document.cookie = 'sb-demo-auth-token=abc123; path=/'; return document.cookie;")
    var stranger = session.scenario
    stranger.id = "another-user"
    stranger.name = "Another user"
    stranger.role.user = .object(["id": .string("someone-else")])
    session.activate(stranger)
    _ = await idle()
    let afterOther = await text("return document.cookie;") ?? ""
    check("BUG-088 a scenario of another test user starts signed out", !afterOther.contains("sb-demo-auth-token"), afterOther)
    session.activate(scenarioBeforeBug089)
    _ = await idle()

    // A WebSocket and a GraphQL field nothing answers yet are prepared like a request, then simulated (REQ-015).
    watchdog.reached("REQ-015 an unknown WebSocket and GraphQL field are prepared, then simulated")
    assistant.lock.withLock {
        assistant.proposal = ["rules": [], "assumptions": ["The page listens for live updates."], "graphql": "[]",
                              "channels": #"[{"id":"live","path":"/ws/live","protocol":"raw","onConnect":[{"data":{"type":"hello"}}],"onMessage":[{"match":{"type":"ping"},"reply":[{"data":{"type":"pong"}}]}],"evidence":[{"kind":"observation","detail":"Opened by the page"}]}]"#]
    }
    let live = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('/ws/live'); const log = [];
          ws.onmessage = e => { log.push(JSON.parse(e.data).type); if (log.length === 1) ws.send(JSON.stringify({ type: 'ping' })); else { ws.close(); resolve(log.join(',')); } };
          ws.onclose = e => { if (log.length < 2) resolve('closed ' + e.code); };
          setTimeout(() => resolve('timeout'), 30000);
        });
        """)
    check("REQ-015 an unknown WebSocket is prepared, then connects and answers", live == "hello,pong", live ?? "nil")
    let channelPrompt = CLICompletion.requests.last { $0.label == "ui-studio:prepare" }
    check("REQ-015 the preparation asks for a channel by its contract", channelPrompt?.prompt.contains("WS /ws/live") == true
          && channelPrompt?.prompt.contains("real-time connection") == true, channelPrompt.map { String($0.prompt.prefix(300)) } ?? "no prompt")
    check("REQ-015 the prepared channel is kept for later sessions", StudioStore.loadEnvironment(root)?.channels?.contains { $0.id == "live" } == true)
    assistant.lock.withLock {
        assistant.proposal = ["rules": [], "assumptions": ["The page shows its team."], "channels": "[]",
                              "graphql": #"[{"id":"q-team","kind":"query","field":"team","action":"respond","response":{"name":"Core","size":3}}]"#]
    }
    let team = await text("""
        const r = await fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: '{ team { name } }' }) });
        return r.status + ' ' + JSON.stringify(await r.json());
        """)
    check("REQ-015 an unknown GraphQL field is prepared and answered for its selection", team == #"200 {"data":{"team":{"name":"Core"}}}"#, team ?? "nil")
    check("REQ-015 the prepared operation is kept", StudioStore.loadEnvironment(root)?.graphQL?.contains { $0.id == "q-team" } == true)

    // The page cannot leave the application (AC-16): another site is a local stand-in page, and nothing is sent (REQ-010).
    watchdog.reached("The page cannot leave the application")
    _ = try? await session.call("location.href = 'https://example.org/elsewhere'; return true;")
    _ = await waitUntil(10) { session.webView.url?.host == "example.org" && !session.webView.isLoading }
    let standIn = await text("return document.getElementById('continue') ? document.title : '';")
    check("AC-16 the page cannot navigate away from the application",
          session.events.contains { $0.kind == .blocked && $0.detail.contains("example.org") } && standIn?.contains("nothing is sent") == true,
          standIn ?? "nil")
    _ = try? await session.call("document.getElementById('continue').click(); return true;")
    _ = await waitUntil(10) { session.webView.url?.port == port && !session.webView.isLoading }
    let stillHere = await text("return location.origin;")
    check("REQ-010 Continue as Test User without a return address goes back to the application", stillHere?.contains("\(port)") == true,
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
    // Tracking (REQ-012) writes its own features into the same store: look at the exported one.
    let exported = package?.featureSlug ?? "-"
    check("AC-21 the export creates a feature with requirements", package != nil && store.objects.contains { $0.slug == exported && $0.kind == .requirement },
          session.notice ?? "")
    check("AC-21 the package has revisions, scenario, rendering, patch and checks", package?.patch.isEmpty == false && package?.checks.isEmpty == false
          && package?.rendering != nil && package?.files.isEmpty == false)
    let overview = store.overviews[exported]?.body ?? ""
    check("AC-21 the feature overview carries scenario, revisions, rendering, requests and verification",
          ["Scenario:", "Baseline code revision", "Final code revision", "Rendering:", "Use digits for the last paragraph", "Verification"]
            .allSatisfy(overview.contains), String(overview.prefix(800)))
    check("AC-21 each change becomes a requirement with its code changes",
          store.objects.contains { $0.slug == exported && $0.kind == .requirement && $0.body.contains("```diff") && $0.body.contains("<p>4</p>") })
    check("AC-21 the captures are attached to the feature", store.objects.contains { $0.slug == exported && $0.kind == .source })
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

    await trackingChecks(session, store: store, assistant: assistant, root: root, idle: idle)

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
    contextTrackingChecks(session, store: store)
    await requestImageChecks(session, root: root, assistant: assistant, idle: idle)
    await browserChecks(session, web: web, root: root, text: text, idle: idle, clickElement: clickElement)
    finish(session, port: port)
}

/// REQ-005 in a real session: the images of the request box are saved under `.dde/studio/attachments/` (kept out of Git),
/// recorded on the turn, shown on the pending turn, given to the assistant as files and named in its prompt; a request of
/// images alone is allowed; an answered clarification keeps the images; a later turn only counts them; Clear leaves the
/// files; and a request whose images cannot be saved is not sent.
@MainActor
func requestImageChecks(_ session: StudioSession, root: URL, assistant: Assistant, idle: () async -> Bool) async {
    watchdog.reached("REQ-005 images in the request box")
    let fm = FileManager.default
    func makePNG(_ width: Int, _ height: Int, _ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return ImageAttachments.pngData(from: image) ?? Data()
    }
    func editRequests() -> [CLICompletion.Request] { CLICompletion.requests.filter { $0.label == "ui-studio:edit" } }
    func file(_ path: String) -> URL { root.appendingPathComponent(path) }
    func samePath(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }
    let blue = makePNG(120, 80, .systemBlue), red = makePNG(60, 40, .systemRed), green = makePNG(30, 30, .systemGreen)
    var box = ImageAttachmentList()
    box.add([blue, red])
    check("REQ-005 the request box holds the images", box.items.count == 2)

    // A request with two images and a text: the pending turn shows them, they are saved, recorded, given and named.
    session.clearConversation()
    let previousAnswer = CLICompletion.answer
    CLICompletion.answer = { request in
        if request.label == "ui-studio:edit" { try await Task.sleep(nanoseconds: 1_500_000_000) }
        return assistant.respond(request)
    }
    session.change("Make the page look like the mock-up", attachments: box.items)
    let shown = await waitUntil(10) { session.pendingTurn?.attachments.count == 2 && session.busy != nil }
    let pendingImages = session.pendingTurn?.attachments ?? []
    check("REQ-005 the pending turn shows the images of the request", shown && pendingImages.allSatisfy { fm.fileExists(atPath: file($0).path) },
          "\(pendingImages)")
    _ = await idle()
    CLICompletion.answer = previousAnswer
    guard let sent = session.history.last, sent.request == "Make the page look like the mock-up" else {
        check("REQ-005 the request with images is a turn", false, session.history.last?.request ?? "nil")
        return
    }
    let paths = sent.attachedImages
    check("REQ-005 the turn records the images as project-relative paths in .dde/studio/attachments",
          paths.count == 2 && paths.allSatisfy { StudioStore.isAttachmentPath($0) } && Set(paths).count == 2 && paths == pendingImages, "\(paths)")
    check("REQ-005 the images are written there as PNG files, as the box held them",
          paths.count == 2 && (try? Data(contentsOf: file(paths[0]))) == blue && (try? Data(contentsOf: file(paths[1]))) == red)
    check("REQ-005 the file names are eight hex digits", paths.allSatisfy { path in
        let name = (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? ""
        return name.count == 8 && name.allSatisfy { "0123456789abcdef".contains($0) }
    }, "\(paths)")
    check("REQ-005 the images stay out of Git", !shell("git status --porcelain", in: root).1.contains(".dde")
          && paths.allSatisfy { shell("git check-ignore -q \($0)", in: root).0 == 0 }, shell("git status --porcelain", in: root).1)
    let request = editRequests().last
    let imagePaths = request?.images ?? []
    check("REQ-005 the assistant gets the images with the request, after the page or element picture",
          paths.count == 2 && imagePaths.contains { samePath($0, file(paths[0])) } && imagePaths.contains { samePath($0, file(paths[1])) }
          && imagePaths.count >= 2 && samePath(imagePaths[imagePaths.count - 2], file(paths[0])) && samePath(imagePaths[imagePaths.count - 1], file(paths[1])),
          imagePaths.map(\.path).joined(separator: ", "))
    let prompt = request?.prompt ?? ""
    check("REQ-005 the prompt names the images, so an engine without an image option can open them",
          paths.count == 2 && prompt.contains("<attached_images>\n- \(paths[0])\n- \(paths[1])\n</attached_images>")
          && prompt.contains("open each with your tools") && prompt.hasSuffix("Request: Make the page look like the mock-up"), String(prompt.suffix(500)))
    check("REQ-005 the turn is answered and the pending turn is gone", sent.status == .answered && session.pendingTurn == nil)

    // A later request without images: the earlier turn says how many it had, never where they are.
    session.change("And what is the heading made of?")
    _ = await idle()
    let later = editRequests().last?.prompt ?? ""
    check("REQ-005 a later turn carries the count of the earlier images, not their paths",
          later.contains("2 images attached") && !later.contains(paths[0]) && !later.contains(paths[1]) && !later.contains("attached_images"),
          String(later.suffix(600)))
    check("REQ-005 a request without images has no attachments recorded", session.history.last?.attachments == nil)

    // Images alone are a request.
    let before = session.history.count
    session.change("   ", attachments: [])
    check("REQ-005 neither text nor images is no request", session.history.count == before && session.busy == nil && session.pendingTurn == nil)
    box.removeAll()
    box.add([green])
    session.change("", attachments: box.items)
    _ = await idle()
    let imageOnly = session.history.last
    check("REQ-005 a request of images alone is sent with the default text",
          imageOnly?.request == StudioPrompts.imageOnlyRequest && imageOnly?.attachedImages.count == 1 && imageOnly?.status == .answered
          && editRequests().last?.prompt.hasSuffix("Request: " + StudioPrompts.imageOnlyRequest) == true && editRequests().last?.images.contains {
              $0.lastPathComponent == (imageOnly?.attachedImages.first as NSString?)?.lastPathComponent } == true,
          "\(imageOnly?.request ?? "nil") \(imageOnly?.attachedImages ?? [])")

    // The assistant asks first: answering keeps the request's images and takes the ones added to the answer.
    box.removeAll()
    box.add([blue])
    assistant.lock.withLock {
        assistant.edits = [["scope": "shared", "scopeNote": "", "needsClarification": true, "question": "The whole page or this section?",
                            "options": ["The whole page", "This section"], "summary": "", "edits": []],
                           answerPlan("Noted: this section."), answerPlan("Noted again.")]
    }
    session.change("Use the colours of the picture", attachments: box.items)
    _ = await idle()
    let asking = session.history.last
    check("REQ-005 a request that is asked about keeps its images on the turn", asking?.status == .clarification && asking?.attachedImages.count == 1,
          "\(asking?.status.rawValue ?? "nil") \(asking?.attachedImages ?? [])")
    if let asking {
        box.removeAll()
        box.add([red])
        session.answerClarification(asking, choice: "This section", attachments: box.items)
        _ = await idle()
        let answered = session.history.last
        let answeredRequest = editRequests().last
        let answeredPrompt = answeredRequest?.prompt ?? ""
        let original = asking.attachedImages.first ?? "none"
        check("REQ-005 the answered turn keeps the request's image and takes the one added to the answer",
              answered?.id == asking.id && answered?.attachedImages.count == 2 && answered?.attachedImages.first == original
              && answered?.attachedImages.last != original, "\(answered?.attachedImages ?? [])")
        check("REQ-005 the answer sends the request's image again with the new one",
              answeredPrompt.contains("- \(original)") && answeredPrompt.contains("- \(answered?.attachedImages.last ?? "none")")
              && answeredPrompt.contains("This section") && answeredRequest?.images.count ?? 0 >= 2
              && answeredRequest?.images.contains { samePath($0, file(original)) } == true, String(answeredPrompt.suffix(500)))
        check("REQ-005 the answered question is not left open", !session.history.contains { $0.status == .clarification })
        // An answer made of an image alone.
        assistant.lock.withLock {
            assistant.edits = [["scope": "shared", "scopeNote": "", "needsClarification": true, "question": "Which section?",
                                "options": ["Top", "Bottom"], "summary": "", "edits": []], answerPlan("Done.")]
        }
        session.change("Match the colours", attachments: [])
        _ = await idle()
        if let second = session.history.last, second.status == .clarification {
            box.removeAll()
            box.add([green])
            session.answerClarification(second, choice: "", attachments: box.items)
            _ = await idle()
            check("REQ-005 an answer of an image alone is sent", editRequests().last?.prompt.contains("The person answered your question: "
                  + StudioPrompts.imageOnlyAnswer) == true && session.history.last?.attachedImages.count == 1)
        } else {
            check("REQ-005 an answer of an image alone is sent", false, session.history.last?.status.rawValue ?? "nil")
        }
    }

    // The history file holds the images of a turn, so they are shown again when the session is reopened.
    let stored = await waitUntil(5) { StudioStore.loadHistory(root).first { $0.id == sent.id }?.attachedImages == paths }
    check("REQ-005 the saved history keeps the images of the turn", stored, "\(StudioStore.loadHistory(root).first { $0.id == sent.id }?.attachedImages ?? [])")

    // Clear starts a new conversation and leaves the images where they are.
    session.clearConversation()
    check("REQ-005 Clear does not delete the images of the turns", session.conversation.isEmpty && paths.allSatisfy { fm.fileExists(atPath: file($0).path) })

    // When the images cannot be saved, the request is not sent: the turn says so.
    let folder = StudioStore.attachmentsFolder(root), aside = folder.deletingLastPathComponent().appendingPathComponent("attachments-aside")
    try? fm.moveItem(at: folder, to: aside)
    fm.createFile(atPath: folder.path, contents: Data("in the way".utf8))
    let requestsBefore = editRequests().count
    session.change("This one cannot be saved", attachments: [ImageAttachment(data: blue, image: NSImage(data: blue)!)])
    _ = await idle()
    let unsaved = session.history.last
    check("REQ-005 images that cannot be saved fail the turn and nothing is sent", unsaved?.request == "This one cannot be saved" && unsaved?.status == .failed
          && unsaved?.answer.contains("could not be saved") == true && unsaved?.attachments == nil && editRequests().count == requestsBefore
          && session.pendingTurn == nil, "\(unsaved?.status.rawValue ?? "nil") \(unsaved?.answer ?? "")")
    try? fm.removeItem(at: folder)
    try? fm.moveItem(at: aside, to: folder)
    check("REQ-005 the images saved before stay where they were", paths.allSatisfy { fm.fileExists(atPath: file($0).path) })
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
    // BUG-087: a new session for the project opens on the scenario this one ended on, with the data the person asked for.
    try? await Task.sleep(nanoseconds: 400_000_000)
    let reopened = StudioSession(root: root)
    check("BUG-087 a new session opens on the scenario the last one ended on", reopened.scenario.id == made
          && reopened.scenario.name == "Random numbers" && reopened.scenario.description == "Fill it with random numbers",
          "\(reopened.scenario.id) \(reopened.scenario.name)")
    await reopened.close()
    StudioStore.saveActiveScenarioID("deleted-scenario", root: root)
    let fallback = StudioSession(root: root)
    check("BUG-087 a scenario that no longer exists opens the built-in one", fallback.scenario.id == "builtin-populated", fallback.scenario.id)
    await fallback.close()
    StudioStore.saveActiveScenarioID(made, root: root)
    // Besides the scenario, only the turn's tracking records (REQ-012) are written; no source file.
    check("REQ-013 only the new scenario's file is written", changed.contains(".markview/studio/scenarios/")
          && changed.split(separator: "\n").allSatisfy { $0.contains(".markview/studio/scenarios/") || $0.contains("docs/features/") },
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

/// REQ-012 for the context turns that `contextChecks` made: an applied context change is a requirement of the
/// conversation's feature with the scenario it made, its Undo marks it rejected, and an answer or a refused change is not
/// recorded. Applied context changes can be exported, and nothing carries the test token.
@MainActor
func contextTrackingChecks(_ session: StudioSession, store: FeatureStore) {
    func turn(_ request: String) -> StudioOperation? { session.history.last { $0.request == request } }
    func object(_ tracking: StudioOperation.Tracking?) -> FeatureStore.Written? {
        tracking.flatMap { tracking in store.objects.first { $0.slug == tracking.feature && $0.id == tracking.id } }
    }
    let filled = turn("Fill it with random numbers"), dialog = turn("Show me the booking dialog")
    let filledRecord = object(filled?.tracking), dialogRecord = object(dialog?.tracking)
    check("REQ-012 an applied context change is a requirement of the conversation's feature", dialog?.tracking?.isRecorded == true
          && dialog?.tracking?.isBug == false && dialog?.tracking?.feature == filled?.tracking?.feature && dialog?.changeKind == nil
          && dialogRecord?.title == "Scenario: Show me the booking dialog" && dialogRecord?.front.string("status") == "approved"
          && dialogRecord?.body.contains("- New scenario: Booking dialog, made from Random numbers") == true
          && dialogRecord?.body.contains("- Steps: click [data-testid=open-booking]") == true
          && dialogRecord?.front.strings("sources").isEmpty == false, dialogRecord?.body ?? "\(dialog?.tracking.map { "\($0.id) \($0.feature)" } ?? "nil")")
    check("REQ-012 Undo of a context change marks its requirement rejected with a note", filled?.status == .undone
          && filledRecord?.front.string("status") == "rejected" && filledRecord?.body.contains("- Records: items 2 → 3") == true
          && filledRecord?.body.contains("## Reverted\n\nUndo in MarkView UI Studio returned to the scenario") == true,
          "\(filledRecord?.front.string("status") ?? "nil")\n\(filledRecord?.body ?? "")")
    check("REQ-012 an answer and a refused context change are not recorded",
          turn("Where do these items come from?")?.tracking == nil && turn("Add some users")?.tracking == nil)
    check("REQ-012 applied context changes can be exported with the code changes",
          session.exportableOperations.contains { $0.id == dialog?.id } && !session.exportableOperations.contains { $0.id == filled?.id })
    let records = store.objects.map { $0.title + "\n" + $0.front.join(body: $0.body) }
    check("REQ-012 no record carries the test token", records.allSatisfy { !$0.contains("markview-test-token") })
}

/// REQ-012 in a real session: the applied changes of a conversation are one feature with a requirement each and a repair
/// is a fixed bug linked to it, with the pictures; Switch moves a record and Undo marks it reverted, without deleting
/// anything; Clear starts the next feature; and the fake secret reaches no record.
@MainActor
func trackingChecks(_ session: StudioSession, store: FeatureStore, assistant: Assistant, root: URL, idle: () async -> Bool) async {
    watchdog.reached("REQ-012 every change is tracked as a requirement or a bug")
    let fm = FileManager.default
    let css = root.appendingPathComponent("web/track.css")
    // Rules apart from each other, so that undoing one change never overlaps the next.
    let filler = (1...4).map { "/* spacer \($0) */" }.joined(separator: "\n")
    try? [".a { color: red; }", ".b { color: green; }", ".c { color: blue; }", ".d { color: gray; }"].map { $0 + "\n" + filler }
        .joined(separator: "\n").appending("\n").write(to: css, atomically: true, encoding: .utf8)
    let fake = "sk-" + "mvfake" + "Q7x9K2p4L8z3W6r1"
    func plan(_ search: String, _ replace: String, kind: String = "change", reason: String = "A new look", summary: String = "Restyled a rule") -> [String: Any] {
        ["scope": "theme", "scopeNote": "", "needsClarification": false, "question": "", "options": [], "summary": summary,
         "edits": [["path": "web/track.css", "search": search, "replace": replace]], "changeKind": kind, "changeReason": reason]
    }
    func change(_ request: String, _ plan: [String: Any]) async -> StudioOperation? {
        assistant.lock.withLock { assistant.edits = [plan] }
        session.change(request)
        _ = await idle()
        return session.history.last { $0.request == request }
    }
    func operation(_ id: String?) -> StudioOperation? { session.history.first { $0.id == id } }
    func requirements(_ slug: String) -> [FeatureStore.Written] { store.objects.filter { $0.slug == slug && $0.kind == .requirement } }
    func object(_ slug: String, _ id: String?) -> FeatureStore.Written? { store.objects.first { $0.slug == slug && $0.id == id } }
    func bugFile(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        return store.bugFiles.first { $0.lastPathComponent.hasPrefix(id + "-") }.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    session.clearConversation()
    let featuresBefore = Set(store.overviews.keys)
    let first = await change("Make the first rule darker", plan(".a { color: red; }", ".a { color: darkred; }"))
    let feature = first?.tracking?.feature ?? ""
    let overview = store.overviews[feature]
    check("REQ-012 the first change of a conversation creates a feature titled from its request",
          first?.status == .applied && !feature.isEmpty && !featuresBefore.contains(feature) && session.conversationFeature == feature
          && overview?.front.string("title") == "UI Studio: Make the first rule darker",
          "\(first?.status.rawValue ?? "nil") \(feature) \(session.notice ?? "")")
    check("REQ-012 the feature is a UI Studio intake being implemented", overview?.front.string("intake") == "ui-studio"
          && overview?.front.string("status") == "implementing" && overview?.body.contains("## UI Studio conversation") == true)
    let req1 = object(feature, first?.tracking?.id)
    check("REQ-012 a change is an approved requirement with its request, element, scope, files, checks and patch",
          first?.tracking?.id == "REQ-001" && req1?.front.string("status") == "approved"
          && ["- [x] Application rebuilt and reloaded", "- Request: Make the first rule darker", "- Element: `button.cta",
              "- Scope: Shared theme", "- Files: `web/track.css`", "```diff", "+.a { color: darkred; }"].allSatisfy { req1?.body.contains($0) == true },
          req1?.body ?? "nil")
    let sources = req1?.front.strings("sources") ?? []
    check("REQ-012 the before and after captures are the requirement's sources", sources.count == 2
          && sources.allSatisfy { id in store.objects.contains { $0.slug == feature && $0.kind == .source && $0.id == id && !$0.front.string("file").isEmpty } }
          && first?.tracking?.pictures.count == 2 && first?.tracking?.pictures.allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) } == true,
          "\(sources) \(first?.tracking?.pictures ?? [])")

    let second = await change("Make the second rule lighter", plan(".b { color: green; }", ".b { color: lightgreen; }"))
    check("REQ-012 two changes make one feature with two requirements", second?.tracking?.feature == feature && second?.tracking?.id == "REQ-002"
          && requirements(feature).count == 2 && Set(store.overviews.keys).subtracting(featuresBefore) == [feature],
          "\(second?.tracking.map { "\($0.id) \($0.feature)" } ?? "nil") \(requirements(feature).count)")

    let third = await change("Fix the third rule; the debug key \(fake) shows over the price",
                             plan(".c { color: blue; }", ".c { color: blue; } /* api_key=\(fake) */", kind: "repair",
                                  reason: "The debug key \(fake) covered the price", summary: "Hid the key \(fake)"))
    let bugID = third?.tracking?.id
    let bug = bugFile(bugID)
    check("REQ-012 a repair is a fixed bug linked to the feature, not a requirement", third?.tracking?.isBug == true && third?.changeKind == .repair
          && bug.contains("status: fixed") && bug.contains("feature: \(feature)") && requirements(feature).count == 2, bug)
    let link = bug.range(of: #"\(\.\./[^)]+\.png\)"#, options: .regularExpression).map { String(bug[$0].dropFirst().dropLast()) }
    let linked = link.flatMap { store.bugsFolder?.appendingPathComponent($0).standardizedFileURL.path }
    check("REQ-012 the bug has steps, expected and actual from the request, and its pictures",
          ["## Steps to reproduce", "## Expected\n\nFix the third rule", "## Actual\n\nThe debug key", "![Before"].allSatisfy { bug.contains($0) }
          && linked.map { fm.fileExists(atPath: $0) } == true, "\(linked ?? "no picture link")\n\(bug)")

    session.switchTracking(third?.id ?? "")
    _ = await idle()
    let switched = operation(third?.id)
    let closedBug = bugFile(bugID)
    check("REQ-012 Switch moves a bug to a requirement and closes the bug with a note", switched?.tracking?.id == "REQ-003"
          && switched?.tracking?.feature == feature && switched?.changeKind == .change && closedBug.contains("status: closed")
          && closedBug.contains("Recorded as REQ-003 of \(feature) instead")
          && object(feature, "REQ-003")?.front.strings("sources") == third?.tracking?.sources
          && object(feature, "REQ-003")?.body.contains("Moved from \(bugID ?? "-")") == true,
          "\(switched?.tracking?.id ?? "nil") \(session.notice ?? "")\n\(closedBug)")
    session.switchTracking(second?.id ?? "")
    _ = await idle()
    let moved = operation(second?.id)
    let req2 = object(feature, "REQ-002")
    let movedBug = bugFile(moved?.tracking?.id)
    check("REQ-012 Switch moves a requirement to a bug and marks the requirement superseded", moved?.tracking?.isBug == true
          && req2?.front.string("status") == "superseded" && req2?.body.contains("Recorded as \(moved?.tracking?.id ?? "-") instead") == true
          && movedBug.contains("status: fixed") && movedBug.contains("Moved from REQ-002"), "\(moved?.tracking?.id ?? "nil")\n\(req2?.body ?? "")")
    let saved = await waitUntil(5) { StudioStore.loadHistory(root).first { $0.id == second?.id }?.tracking == moved?.tracking }
    check("REQ-012 the record ids are saved with the operation", saved && moved?.tracking != nil)

    session.undo(first?.id ?? "")
    _ = await idle()
    let req1After = object(feature, "REQ-001")
    check("REQ-012 Undo marks the requirement rejected with a note, and nothing is deleted",
          operation(first?.id)?.status == .undone && req1After?.front.string("status") == "rejected"
          && req1After?.body.contains("## Reverted") == true && requirements(feature).count == 3,
          "\(operation(first?.id)?.status.rawValue ?? "nil") \(req1After?.front.string("status") ?? "nil")")
    session.undo(second?.id ?? "")
    _ = await idle()
    let revertedBug = bugFile(moved?.tracking?.id)
    check("REQ-012 Undo marks the bug closed with a note, and nothing is deleted", operation(second?.id)?.status == .undone
          && revertedBug.contains("status: closed") && revertedBug.contains("## Reverted") && store.bugFiles.count == 2, revertedBug)

    session.clearConversation()
    check("REQ-012 Clear leaves the next change without a feature", session.conversationFeature == nil)
    let next = await change("Make the fourth rule bolder", plan(".d { color: gray; }", ".d { color: gray; font-weight: bold; }"))
    let nextFeature = next?.tracking?.feature ?? ""
    check("REQ-012 Clear followed by a change makes a new feature", !nextFeature.isEmpty && nextFeature != feature
          && next?.tracking?.id == "REQ-001" && store.overviews[nextFeature]?.front.string("title") == "UI Studio: Make the fourth rule bolder",
          "\(nextFeature) \(next?.tracking?.id ?? "nil")")

    let records = store.overviews.map { $0.key + "\n" + $0.value.front.join(body: $0.value.body) }
        + store.objects.map { $0.title + "\n" + $0.front.join(body: $0.body) }
        + store.bugFiles.map { $0.lastPathComponent + "\n" + ((try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    check("REQ-012 the fake secret appears in no record", !records.isEmpty && records.allSatisfy { !$0.contains("mvfake") },
          records.first { $0.contains("mvfake") }.map { String($0.prefix(600)) } ?? "")
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
            await environmentMapChecks()
            await routeMapChecks()
            await externalServerCheck()
            await serverRequestChecks()
            await lateRuleChecks()
            await serverClockChecks()
            await logChecks()
            await authChecks()
            await ipcSessionChecks()
        }
        targetChecks()
        print(failures == 0 ? "All UI Studio session checks passed." : "\(failures) UI Studio session check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Application map (REQ-014)

/// The map fixture's page: the application's own session at once, the catalog's categories a moment later (while their
/// group is being prepared), and the catalog's bundles on demand.
let mapPage = """
<!doctype html><html><head><meta charset="utf-8"><title>Map</title></head><body>
<p id="user"></p><p id="categories"></p>
<script src="app.js"></script>
</body></html>

"""
let mapAppJS = """
fetch('/api/session').then(r => r.json()).then(s => { document.getElementById('user').textContent = s.user; });
setTimeout(() => fetch('http://catalog.example.test/v1/categories').then(r => r.json()).then(list => {
  document.getElementById('categories').textContent = list.map(c => c.name).join(',');
}), 1500);
function bundles(category) { return fetch('http://catalog.example.test/v1/bundles/search?categoryId=' + category).then(r => r.json()); }
function bundle(id) { return fetch('http://catalog.example.test/v1/bundles/' + id).then(r => r.json()); }
function orders() { return fetch('http://catalog.example.test/v1/orders').then(r => r.json()); }

"""
/// Server code of the fixture: read by the inventory, not run by the static server.
let mapServerJS = """
export async function cities() {
  const response = await fetch(`${process.env.CATALOG_URL}/cities`);
  return response.json();
}

"""

/// A project with browser and server call sites; returns its application folder.
func mapFixture(_ root: URL) -> URL {
    let web = root.appendingPathComponent("web")
    try? FileManager.default.createDirectory(at: web.appendingPathComponent("server"), withIntermediateDirectories: true)
    try? mapPage.write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try? mapAppJS.write(to: web.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
    try? mapServerJS.write(to: web.appendingPathComponent("server/catalog.js"), atomically: true, encoding: .utf8)
    return web
}

/// The inventory of the fixture: groups of two give catalog/bundles, catalog/categories+cities, catalog/orders and app/session.
let mapInventory: [String: Any] = [
    "services": [["name": "catalog", "baseURL": "http://catalog.example.test/v1", "variable": "CATALOG_URL", "side": "both"],
                 ["name": "app", "baseURL": "", "variable": "", "side": "browser"]],
    "endpoints": [
        ["service": "catalog", "resource": "categories", "method": "GET", "path": "/categories", "callSite": "web/app.js:2", "side": "browser"],
        ["service": "catalog", "resource": "cities", "method": "GET", "path": "${process.env.CATALOG_URL}/cities", "callSite": "web/server/catalog.js:2",
         "side": "server"],
        ["service": "catalog", "resource": "bundles", "method": "GET", "path": "/bundles/search?categoryId=${category}", "callSite": "web/app.js:5",
         "side": "browser"],
        ["service": "catalog", "resource": "bundles", "method": "GET", "path": "/bundles/${id}", "callSite": "web/app.js:6", "side": "browser"],
        ["service": "catalog", "resource": "orders", "method": "GET", "path": "/orders", "callSite": "web/app.js:7", "side": "browser"],
        ["service": "app", "resource": "session", "method": "GET", "path": "/api/session", "callSite": "web/app.js:1", "side": "browser"]],
    "notes": ["The server reads CATALOG_URL from the environment."],
    // Like vivaa's backend for frontend, which accepts only its own roles, not the default test user's `member`.
    "userRoles": ["names": ["customer", "master", "admin"], "ordinary": "customer"]]

/// A group's answer in the preparation schema. The bundles all fall in one category and one is in a city that does not
/// exist, like vivaa's first seed: the coherence check finds both.
func mapGroupAnswer(_ id: String) -> [String: Any] {
    let base = "http://catalog.example.test/v1"
    func entity(_ name: String, _ fields: [[String: Any]]) -> [String: Any] { ["name": name, "idField": "id", "fields": fields] }
    func field(_ name: String, references: String = "") -> [String: Any] {
        ["name": name, "type": "string", "required": false, "enumValues": [], "references": references]
    }
    func rule(_ id: String, _ path: String, _ operation: String, entity: String = "", filters: [String] = [], body: String = "") -> [String: Any] {
        ["id": id, "method": "GET", "path": path, "operation": operation, "entity": entity, "envelope": "", "filters": filters, "include": [],
         "responseStatus": 200, "responseBody": body, "evidence": [["kind": "observation", "detail": "Called by the fixture"]]]
    }
    switch id {
    case "catalog/categories+cities":
        return ["entities": [entity("categories", [field("name")]), entity("cities", [field("name")])],
                "records": [["entity": "categories", "json": #"[{"id":"c1","name":"Spa"},{"id":"c2","name":"Food"},{"id":"c3","name":"Tours"}]"#],
                            ["entity": "cities", "json": #"[{"id":"tlv","name":"Tel Aviv"},{"id":"jlm","name":"Jerusalem"}]"#]],
                "rules": [rule("list-categories", base + "/categories", "list", entity: "categories"),
                          rule("list-cities", base + "/cities", "list", entity: "cities")],
                "unsupported": false, "reason": "", "assumptions": []]
    case "catalog/bundles":
        let bundles = (1...4).map { #"{"id":"b\#($0)","name":"Bundle \#($0)","categoryId":"c1","cityId":"\#($0 == 4 ? "haifa" : "tlv")"}"# }
        return ["entities": [entity("bundles", [field("name"), field("categoryId", references: "categories"), field("cityId")]),
                             entity("categories", [field("name")])],
                "records": [["entity": "categories", "json": #"[{"id":"c1","name":"Spa"}]"#],
                            ["entity": "bundles", "json": "[" + bundles.joined(separator: ",") + "]"]],
                "rules": [rule("search-bundles", base + "/bundles/search", "list", entity: "bundles", filters: ["categoryId", "limit"]),
                          rule("get-bundle", base + "/bundles/:id", "get", entity: "bundles")],
                "unsupported": false, "reason": "", "assumptions": []]
    case "catalog/orders":
        return ["entities": [entity("orders", [field("cityId", references: "cities")])],
                "records": [["entity": "orders", "json": #"[{"id":"o1","cityId":"tlv"},{"id":"o2","cityId":"jlm"}]"#]],
                "rules": [rule("list-orders", base + "/orders", "list", entity: "orders")],
                "unsupported": false, "reason": "", "assumptions": []]
    default:
        return ["entities": [], "records": [], "rules": [rule("session", "/api/session", "respond", body: #"{"user":"Dana"}"#)],
                "unsupported": false, "reason": "", "assumptions": []]
    }
}

/// New records of the entity a refill asks for: the bundles spread over every category and existing cities.
func mapRefillAnswer(_ prompt: String) -> [String: Any] {
    var json = "[]"
    if prompt.contains("entity `bundles`") {
        json = "[" + ["c1", "c1", "c2", "c2", "c3", "c3"].enumerated().map { index, category in
            #"{"id":"b\#(index + 1)","name":"Bundle \#(index + 1)","categoryId":"\#(category)","cityId":"\#(index % 2 == 0 ? "tlv" : "jlm")"}"#
        }.joined(separator: ",") + "]"
    } else if prompt.contains("entity `categories`") {
        json = #"[{"id":"c1","name":"Spa days"},{"id":"c2","name":"Food tours"},{"id":"c3","name":"City tours"}]"#
    } else if prompt.contains("entity `cities`") {
        json = #"[{"id":"tlv","name":"Tel Aviv"},{"id":"jlm","name":"Jerusalem"}]"#
    } else if prompt.contains("entity `orders`") {
        json = #"[{"id":"o1","cityId":"tlv"},{"id":"o2","cityId":"jlm"},{"id":"o3","cityId":"tlv"}]"#
    }
    return ["json": json, "assumptions": ["Realistic catalog data."]]
}

/// The application map's stand-in assistant: the inventory, each group by the id its prompt names, and refills.
final class MapAssistant: @unchecked Sendable {
    let lock = NSLock()
    /// Seconds a group takes, by id; others take `groupDelay`.
    var delays: [String: Double] = [:]
    var groupDelay = 0.2
    private(set) var groupCalls: [String] = []
    private(set) var groupPrompts: [String: String] = [:]
    /// The inventory call fails, as when the assistant does not finish within its deadline.
    var inventoryFails = false

    static func groupID(_ prompt: String) -> String {
        prompt.components(separatedBy: "\n").first { $0.hasPrefix("Group: ") }.map { String($0.dropFirst(7)) } ?? ""
    }

    func respond(_ request: CLICompletion.Request) async throws -> CLICompletion.Result {
        var structured: [String: Any]
        switch request.label {
        case "ui-studio:map":
            if lock.withLock({ inventoryFails }) { throw NSError(domain: "map", code: 1, userInfo: [NSLocalizedDescriptionKey: "no inventory"]) }
            structured = mapInventory
        case "ui-studio:map-group":
            let id = Self.groupID(request.prompt)
            let delay = lock.withLock { () -> Double in
                groupCalls.append(id)
                groupPrompts[id] = request.prompt
                return delays[id] ?? groupDelay
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            structured = mapGroupAnswer(id)
        default:
            structured = mapRefillAnswer(request.prompt)
        }
        return CLICompletion.Result(text: "", structured: structured, inputTokens: 10, outputTokens: 5, costUSD: 0)
    }

    func calls() -> [String] { lock.withLock { groupCalls } }
    func prompt(_ id: String) -> String { lock.withLock { groupPrompts[id] ?? "" } }
    func set(_ delays: [String: Double], other: Double = 0.2) { lock.withLock { self.delays = delays; groupDelay = other } }
}

/// REQ-014 in real sessions: the application is mapped once, in the background, from one inventory call; every group is
/// prepared and registered, with progress; the page works meanwhile; the coherence check's gaps are logged and refilled;
/// the map is saved and not redone; a closed session's map resumes; Cancel stops it; Map Again and Refill Data work.
@MainActor
func environmentMapChecks() async {
    watchdog.reached("REQ-014 the application is mapped in the background")
    let fm = FileManager.default
    let previousAnswer = CLICompletion.answer
    defer {
        CLICompletion.mapAnswer = nil
        CLICompletion.answer = previousAnswer
    }
    let assistant = MapAssistant()
    CLICompletion.mapAnswer = { request in try await assistant.respond(request) }
    // The page's own requests are prepared one by one: /api/session comes before its group's turn.
    CLICompletion.answer = { _ in
        try await Task.sleep(nanoseconds: 300_000_000)
        return CLICompletion.Result(text: "", structured: mapGroupAnswer("app/session"), inputTokens: 10, outputTokens: 5, costUSD: 0)
    }
    func mapCalls(since start: Int, _ label: String) -> [CLICompletion.Request] {
        CLICompletion.mapRequests.dropFirst(start).filter { $0.label == label }
    }
    func open(_ root: URL, web: URL) -> StudioSession {
        let session = StudioSession(root: root)
        session.mapping.limits.groupSize = 2
        let port = freePort()
        session.start(WebAppTarget(folder: web, label: "map", command: "python3 -m http.server \(port) --bind 127.0.0.1", ports: [port]))
        return session
    }
    func logText(_ session: StudioSession) -> [String] { session.sessionLog.entries.filter { $0.kind == .preparation }.map(\.text) }
    func done(_ session: StudioSession) -> Bool { session.mapping.map?.status == .complete && !session.mapping.isRunning }

    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-map-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let web = mapFixture(root)
    assistant.set(["catalog/bundles": 4, "catalog/categories+cities": 2, "catalog/orders": 0.5])
    let mapsBefore = CLICompletion.mapRequests.count
    let preparesBefore = CLICompletion.requests.count
    let session = open(root, web: web)
    func text(_ id: String) async -> String {
        ((try? await session.call("return document.getElementById('\(id)').textContent;")) as? String) ?? ""
    }
    var progress: [String] = []
    _ = await waitUntil(60) {
        if session.mapping.phase == .groups, progress.last != session.mapping.progressText { progress.append(session.mapping.progressText) }
        return [.ready, .degraded, .failed].contains(session.state) && session.busy == nil
    }
    let mappingWhileReady = session.mapping.isRunning
    var user = ""
    for _ in 0..<30 where user != "Dana" {
        user = await text("user")
        if user != "Dana" { try? await Task.sleep(nanoseconds: 200_000_000) }
    }
    check("REQ-014 the page works while the application is mapped: it is ready and its first request is prepared one by one",
          mappingWhileReady && user == "Dana", "mapping=\(mappingWhileReady) user=\(user) \(session.state) \(session.stateDetail)")
    _ = await waitUntil(40) {
        if session.mapping.phase == .groups, progress.last != session.mapping.progressText { progress.append(session.mapping.progressText) }
        return done(session)
    }
    let categories = await text("categories")
    let prepares = CLICompletion.requests.dropFirst(preparesBefore).filter { $0.label == "ui-studio:prepare" }
    check("REQ-014 a request whose group is being prepared waits for it and is answered by its rule, with no call of its own",
          categories == "Spa,Food,Tours"
          && !prepares.contains { $0.prompt.contains("Unknown request seen by MarkView UI Studio: GET http://catalog.example.test/v1/categories") }
          && prepares.contains { $0.prompt.contains("/api/session") },
          "categories=\(categories) prepares=\(prepares.map { String($0.prompt.prefix(90)) })")
    let inventories = mapCalls(since: mapsBefore, "ui-studio:map")
    check("REQ-014 one inventory call, read-only and structured, for browser and server code and the project's own clients",
          inventories.count == 1 && inventories.first?.jsonSchema != nil && inventories.first?.allowWeb == false
          && inventories.first?.prompt.contains("`web`") == true && inventories.first?.systemPrompt?.contains("serviceFetch") == true
          && inventories.first?.systemPrompt?.contains("route handlers") == true, "\(inventories.count) calls")
    let environment = StudioStore.loadEnvironment(root)
    check("REQ-014 the test user gets the ordinary role the code checks, saved in the environment and logged",
          session.spec.testUserRole == "customer" && environment?.testUserRole == "customer" && session.scenario.role.roleName == "customer"
          && session.mapping.map?.userRoles == ["customer", "master", "admin"]
          && logText(session).contains { $0.hasPrefix("The test user's role member is not one the application checks (customer, master, admin)") }
          && assistant.prompt("catalog/orders").contains("User roles the code checks: customer, master, admin. The scenario's test user has the role customer"),
          "role=\(String(describing: session.spec.testUserRole)) scenario=\(session.scenario.role.roleName ?? "nil")")
    let map = session.mapping.map
    check("REQ-014 the inventory is split into groups that are all prepared",
          map?.groups.map(\.id) == ["catalog/bundles", "catalog/categories+cities", "catalog/orders", "app/session"]
          && map?.groups.allSatisfy { $0.status == .done } == true && map?.status == .complete,
          "\(map?.groups.map { "\($0.id) \($0.status) \($0.message)" } ?? [])")
    let uncovered = (map?.groups ?? []).flatMap { group in
        group.endpoints.filter { !StudioMapPlanner.isCovered($0, service: map?.service(group.service), rules: session.spec.rules) }
            .map { "\($0.method) \($0.path)" }
    }
    check("REQ-014 every endpoint of the map has a registered rule", uncovered.isEmpty
          && ["search-bundles", "get-bundle", "list-categories", "list-cities", "list-orders", "session"].allSatisfy { id in
              session.spec.rules.contains { $0.id == id } },
          "uncovered: \(uncovered) rules: \(session.spec.rules.map(\.id))")
    check("REQ-014 a group whose endpoints got their rules meanwhile asks nothing",
          assistant.calls() == ["catalog/bundles", "catalog/categories+cities", "catalog/orders"], "\(assistant.calls())")
    let ordersPrompt = assistant.prompt("catalog/orders")
    check("REQ-014 a group's prompt lists the entities other groups registered, with their records' ids",
          ordersPrompt.contains("categories (id id)") && ordersPrompt.contains("c2 \"Food\"") && ordersPrompt.contains("tlv \"Tel Aviv\"")
          && ordersPrompt.contains("rule path `http://catalog.example.test/v1/orders`") && ordersPrompt.contains("2-4 records"),
          String(ordersPrompt.prefix(600)))
    let log = logText(session)
    check("REQ-014 the progress is shown and logged group by group",
          progress.contains { $0.hasPrefix("Mapping the application's APIs: ") && $0.hasSuffix(" of 4 groups") }
          && log.contains { $0.hasPrefix("Inventory after") && $0.contains("2 services, 6 endpoints in 4 groups") }
          && log.contains { $0.hasPrefix("Map group catalog/categories+cities: 2 rules after") && $0.hasSuffix("of 4 groups") }
          && log.contains { $0.hasPrefix("Map group app/session: every endpoint already had a rule") },
          "progress=\(progress) log=\(log)")
    check("REQ-014 the coherence check's gaps are logged",
          log.contains { $0.hasPrefix("Coherence check: 2 gaps") } && log.contains { $0.contains("bundles.cityId points at cities that do not exist: haifa") }
          && log.contains { $0.contains("No bundles with categoryId c2 (Food), c3 (Tours)") }, log.joined(separator: "\n"))
    let bundles = session.spec.seed["bundles"] ?? []
    check("REQ-014 the entity with gaps is refilled once and the check is clean after it",
          mapCalls(since: mapsBefore, "ui-studio:map-refill").count == 1 && log.contains { $0.hasPrefix("Refilled bundles: 6 records") }
          && log.contains { $0.hasPrefix("Coherence check after the refill: no gaps") }
          && Set(bundles.compactMap { $0["categoryId"]?.stringValue }) == ["c1", "c2", "c3"] && session.notice?.contains("Reset shows it") == true,
          "\(log.suffix(6)) notice=\(session.notice ?? "nil")")
    _ = await waitUntil(5) { StudioStore.loadEnvironment(root)?.map?.status == .complete }
    let saved = StudioStore.loadEnvironment(root)?.map
    check("REQ-014 the map is saved in the environment", saved?.status == .complete && saved?.groups.count == 4 && saved?.gaps.isEmpty == true
          && saved?.inventoryAttempts == 1 && saved?.services.first { $0.name == "catalog" }?.address == "http://catalog.example.test/v1",
          "\(String(describing: saved))")

    watchdog.reached("REQ-014 Map Again and Refill Data")
    let againStart = CLICompletion.mapRequests.count
    assistant.set([:], other: 0.3)
    session.mapAgain()
    let removed = !session.spec.rules.contains { $0.id == "search-bundles" } && session.spec.map == nil
    _ = await waitUntil(40) { done(session) && session.busy == nil }
    check("REQ-014 Map Again removes the prepared rules and maps from the start", removed
          && mapCalls(since: againStart, "ui-studio:map").count == 1 && session.mapping.map?.groups.allSatisfy { $0.status == .done } == true
          && session.spec.rules.contains { $0.id == "search-bundles" } && logText(session).contains { $0.hasPrefix("Mapping the application again:") },
          "removed=\(removed) \(session.mapping.map?.groups.map { "\($0.id) \($0.status)" } ?? [])")
    let refillStart = CLICompletion.mapRequests.count
    session.refillData()
    _ = await waitUntil(40) { !session.mapping.isRunning && session.busy == nil }
    let refills = mapCalls(since: refillStart, "ui-studio:map-refill")
    let names = (session.spec.seed["categories"] ?? []).compactMap { $0["name"]?.stringValue }
    check("REQ-014 Refill Data writes new records for every entity, keeps the rules and resets the scenario",
          refills.count == 4 && names == ["Spa days", "Food tours", "City tours"] && session.spec.rules.contains { $0.id == "search-bundles" }
          && logText(session).contains { $0.contains("The scenario is reset to show the refilled data") },
          "\(refills.count) calls, categories \(names), log \(logText(session).suffix(5))")
    await session.close()

    watchdog.reached("REQ-014 a completed map is not redone")
    let secondStart = CLICompletion.mapRequests.count
    let second = open(root, web: web)
    _ = await waitUntil(60) { [.ready, .degraded, .failed].contains(second.state) && second.busy == nil }
    try? await Task.sleep(nanoseconds: 500_000_000)
    check("REQ-014 a second session does not map the application again, and its test user starts with the saved role",
          CLICompletion.mapRequests.count == secondStart && !second.mapping.isRunning && second.mapping.map?.status == .complete
          && second.scenario.role.roleName == "customer",
          "\(CLICompletion.mapRequests.count - secondStart) map calls, \(String(describing: second.mapping.map?.status))")
    await second.close()

    watchdog.reached("REQ-014 a restart resumes the unfinished groups")
    let resumeRoot = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-map-resume-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: resumeRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: resumeRoot) }
    let resumeWeb = mapFixture(resumeRoot)
    assistant.set(["catalog/bundles": 60], other: 0.3)
    let interrupted = open(resumeRoot, web: resumeWeb)
    _ = await waitUntil(40) {
        let groups = interrupted.mapping.map?.groups ?? []
        return groups.count == 4 && groups.filter { $0.status == .done }.count == 3 && groups.first?.status == .preparing
    }
    _ = await waitUntil(5) { StudioStore.loadEnvironment(resumeRoot)?.map?.groups.filter { $0.status == .done }.count == 3 }
    await interrupted.close()
    let left = StudioStore.loadEnvironment(resumeRoot)?.map
    check("REQ-014 a session that closes while mapping leaves the map to resume",
          left?.status == .mapping && left?.inventoried == true && left?.groups.first?.status == .preparing
          && left?.groups.dropFirst().allSatisfy { $0.status == .done } == true, "\(left?.groups.map { "\($0.id) \($0.status)" } ?? [])")
    let resumeStart = CLICompletion.mapRequests.count
    let callsBefore = assistant.calls().count
    assistant.set([:], other: 0.3)
    let resumed = open(resumeRoot, web: resumeWeb)
    _ = await waitUntil(40) { done(resumed) }
    check("REQ-014 a restart resumes only the unfinished groups, without a new inventory",
          mapCalls(since: resumeStart, "ui-studio:map").isEmpty && Array(assistant.calls().dropFirst(callsBefore)) == ["catalog/bundles"]
          && resumed.mapping.map?.groups.allSatisfy { $0.status == .done } == true
          && logText(resumed).contains { $0.hasPrefix("Resuming the application's map of web: 1 of 4 groups left") },
          "\(Array(assistant.calls().dropFirst(callsBefore))) \(logText(resumed).prefix(3))")
    await resumed.close()

    watchdog.reached("REQ-014 Cancel stops mapping")
    let cancelRoot = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-map-cancel-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: cancelRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: cancelRoot) }
    let cancelWeb = mapFixture(cancelRoot)
    assistant.set(["catalog/bundles": 60, "catalog/categories+cities": 60], other: 0.3)
    let cancelled = open(cancelRoot, web: cancelWeb)
    _ = await waitUntil(40) { (cancelled.mapping.map?.groups ?? []).filter { $0.status == .preparing }.count == 2 }
    let banner = cancelled.mapping.progressText
    let callsAtCancel = assistant.calls().count
    cancelled.cancelMapping()
    _ = await waitUntil(10) { !cancelled.mapping.isRunning }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let stopped = StudioStore.loadEnvironment(cancelRoot)?.map
    check("REQ-014 Cancel stops mapping: no group is prepared after it, and the map waits for Resume",
          banner == "Mapping the application's APIs: 0 of 4 groups" && !cancelled.mapping.isRunning && assistant.calls().count == callsAtCancel
          && stopped?.status == .cancelled && stopped?.groups.allSatisfy { $0.status == .pending } == true && cancelled.mapping.canResume
          && logText(cancelled).contains { $0.hasPrefix("Mapping cancelled: 0 of 4 groups are prepared") },
          "banner=\(banner) calls=\(assistant.calls().count - callsAtCancel) \(stopped?.groups.map { "\($0.id) \($0.status)" } ?? [])")
    assistant.set([:], other: 0.2)
    cancelled.resumeMapping()
    _ = await waitUntil(40) { done(cancelled) }
    _ = await waitUntil(5) { StudioStore.loadEnvironment(cancelRoot)?.map?.status == .complete }
    check("REQ-014 Resume prepares the groups that were left", cancelled.mapping.map?.groups.allSatisfy { $0.status == .done } == true
          && StudioStore.loadEnvironment(cancelRoot)?.map?.status == .complete, "\(cancelled.mapping.map?.groups.map { "\($0.id) \($0.status)" } ?? [])")
    await cancelled.close()
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
    check("REQ-016 the main process and preload are disclosed as not running, their bridge as simulated, synchronous IPC as not",
          electronNotes.contains { $0.contains("main process, preload scripts and native modules do not run")
              && $0.contains("simulated like any other API") && $0.contains("http://electron.ipc/") && $0.contains("(sendSync) and native modules are not simulated") },
          electronNotes.joined(separator: " | "))
    check("REQ-016 the preload's globals are simulated under their real names", StudioTargetLimits.electronGlobals(in: electron) == ["desktop"])

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

// MARK: - Electron preload bridge (REQ-016)

/// An Electron renderer in a real session: its completed map of version 1 is extended with the preload bridge (only the
/// new endpoints are prepared), a bridge call the map did not list is prepared like an unknown request, and a callback the
/// page registered before its channel existed gets the record a later save writes.
@MainActor
func ipcSessionChecks() async {
    watchdog.reached("REQ-016 an older map of an Electron renderer is extended with its preload bridge")
    let fm = FileManager.default
    let previousAnswer = CLICompletion.answer
    defer {
        CLICompletion.mapAnswer = nil
        CLICompletion.answer = previousAnswer
    }
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-ipc-\(UUID().uuidString)").resolvingSymlinksInPath()
    let web = root.appendingPathComponent("web")
    try? fm.createDirectory(at: web.appendingPathComponent("src"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? "<!doctype html><html><head><meta charset=\"utf-8\"><title>Desk</title></head><body><p id=\"desk\">Desk</p></body></html>\n"
        .write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try? """
        import { contextBridge, ipcRenderer } from 'electron'
        contextBridge.exposeInMainWorld('desk', {
          settings: {
            getDocument: () => ipcRenderer.invoke('settings:get-document'),
            saveDocument: (doc) => ipcRenderer.invoke('settings:save-document', doc),
            getBrokers: () => ipcRenderer.invoke('settings:get-brokers'),
            onDocumentApplied: (cb) => { const h = (_e, d) => cb(d); ipcRenderer.on('settings:document-applied', h); return () => ipcRenderer.removeListener('settings:document-applied', h) },
          },
        })

        """.write(to: web.appendingPathComponent("src/preload.js"), atomically: true, encoding: .utf8)
    // The map made before REQ-016: complete, without a version, its group and rule kept.
    var spec = StudioEnvironmentSpec()
    spec.rules = [StudioRule(id: "session", method: "GET", path: "/api/session", operation: .respond,
                             response: StudioFixedResponse(status: 200, body: .object(["user": .string("Dana")])))]
    spec.map = StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, inventoryAttempts: 1,
                                    services: [StudioMapService(name: "app", address: "")],
                                    groups: [StudioMapGroup(id: "app/session", service: "app", resource: "session",
                                                            endpoints: [StudioMapEndpoint(method: "GET", path: "/api/session", resource: "session")],
                                                            status: .done, rules: ["session"])],
                                    version: 1)
    try? StudioStore.saveEnvironment(spec, root: root)

    let brokers = #"[{"id":"b1","name":"Alpaca"},{"id":"b2","name":"Tastytrade"}]"#
    CLICompletion.mapAnswer = { request in
        let structured: [String: Any]
        switch request.label {
        case "ui-studio:map":
            structured = ["services": [["name": "app", "baseURL": "", "variable": "", "side": "browser"],
                                       ["name": "electron-ipc", "baseURL": "http://electron.ipc", "variable": "", "side": "browser"]],
                          "endpoints": [["service": "app", "resource": "session", "method": "GET", "path": "/api/session", "callSite": "web/app.js:1", "side": "browser"],
                                        ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/getBrokers",
                                         "callSite": "web/src/preload.js:6", "side": "browser"]],
                          "notes": ["onDocumentApplied(cb) is a subscription"], "userRoles": ["names": [], "ordinary": ""]]
        case "ui-studio:map-group":
            structured = ["entities": [["name": "brokers", "idField": "id", "fields": [["name": "name", "type": "string", "required": true,
                                                                                         "enumValues": [], "references": ""]]]],
                          "records": [["entity": "brokers", "json": brokers]],
                          "rules": [["id": "get-brokers", "method": "GET", "path": "http://electron.ipc/desk/settings/getBrokers", "operation": "list",
                                     "entity": "brokers", "envelope": "", "filters": [], "include": [], "responseStatus": 200, "responseBody": "",
                                     "evidence": [["kind": "contract", "detail": "ipcMain.handle('settings:get-brokers')"]]]],
                          "unsupported": false, "reason": "", "assumptions": []]
        default:
            structured = ["json": "[]", "assumptions": []]
        }
        return CLICompletion.Result(text: "", structured: structured, inputTokens: 10, outputTokens: 5, costUSD: 0)
    }
    CLICompletion.answer = { request in
        var structured: [String: Any] = ["rules": [], "assumptions": [], "channels": "[]", "graphql": "[]"]
        if request.prompt.contains("seen by MarkView UI Studio: GET http://electron.ipc/desk/settings/getDocument") {
            structured["rules"] = [["id": "get-document", "method": "GET", "path": "http://electron.ipc/desk/settings/getDocument", "operation": "respond",
                                    "responseStatus": 200, "responseBody": #"{"theme":"dark"}"#,
                                    "evidence": [["kind": "contract", "detail": "ipcMain.handle('settings:get-document')"]]]]
        } else if request.prompt.contains("seen by MarkView UI Studio: PUT http://electron.ipc/desk/settings/saveDocument") {
            structured["entities"] = [["name": "documents", "idField": "id", "fields": [["name": "theme", "type": "string", "required": false,
                                                                                          "enumValues": [], "references": ""]]]]
            structured["rules"] = [["id": "save-document", "method": "PUT", "path": "http://electron.ipc/desk/settings/saveDocument", "operation": "create",
                                    "entity": "documents", "evidence": [["kind": "contract", "detail": "ipcMain.handle('settings:save-document')"]]]]
            structured["channels"] = #"[{"id":"document-applied","path":"http://electron.ipc/desk/settings/onDocumentApplied","protocol":"raw","links":[{"entity":"documents","on":["create"],"message":{"data":"{{record}}"}}],"evidence":[{"kind":"contract","detail":"webContents.send('settings:document-applied')"}]}]"#
        }
        return CLICompletion.Result(text: "", structured: structured, inputTokens: 10, outputTokens: 5, costUSD: 0)
    }

    let mapsBefore = CLICompletion.mapRequests.count
    let preparesBefore = CLICompletion.requests.count
    let session = StudioSession(root: root)
    let port = freePort()
    session.start(WebAppTarget(folder: web, label: "desk (web only)", command: "python3 -m http.server \(port) --bind 127.0.0.1", ports: [port],
                               isElectron: true))
    _ = await waitUntil(90) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    check("REQ-016 the Electron renderer's session opens", session.appURL != nil, "\(session.state) \(session.stateDetail)")
    _ = await waitUntil(60) { session.mapping.map?.status == .complete && !session.mapping.isRunning }
    let maps = CLICompletion.mapRequests.dropFirst(mapsBefore)
    let inventory = maps.filter { $0.label == "ui-studio:map" }
    let groupCalls = maps.filter { $0.label == "ui-studio:map-group" }
    check("REQ-016 a completed map of version 1 is inventoried again, asking for the preload bridge",
          inventory.count == 1 && inventory.first?.prompt.contains("This is an Electron renderer") == true
          && inventory.first?.systemPrompt?.contains("`electron-ipc`") == true, "\(inventory.count) inventories")
    let map = session.mapping.map
    check("REQ-016 the extended map keeps its old group and prepares only the bridge's new endpoints",
          map?.version == StudioEnvironmentMap.currentVersion && map?.groups.map(\.id) == ["app/session", "electron-ipc/brokers"]
          && map?.groups.allSatisfy { $0.status == .done } == true && groupCalls.count == 1
          && groupCalls.first?.prompt.contains("http://electron.ipc/desk/settings/getBrokers") == true
          && session.spec.rules.contains { $0.id == "session" } && session.spec.rules.contains { $0.id == "get-brokers" },
          "\(map?.groups.map { "\($0.id) \($0.status)" } ?? []) \(groupCalls.count) group calls")
    _ = await waitUntil(5) { StudioStore.loadEnvironment(root)?.map?.version == StudioEnvironmentMap.currentVersion }
    check("REQ-016 the extended map is saved with the current version", StudioStore.loadEnvironment(root)?.map?.version == StudioEnvironmentMap.currentVersion)

    watchdog.reached("REQ-016 bridge calls in the session")
    func text(_ script: String) async -> String { ((try? await session.call(script)) as? String) ?? "nil" }
    let listed = await text("return (await window.desk.settings.getBrokers()).map(b => b.name).join(',');")
    check("REQ-016 a bridge method the map prepared is answered by its rule without a preparation",
          listed == "Alpaca,Tastytrade" && CLICompletion.requests.dropFirst(preparesBefore).filter { $0.label == "ui-studio:prepare" }.isEmpty, listed)
    let document = await text("return JSON.stringify(await window.desk.settings.getDocument());")
    let prepares = CLICompletion.requests.dropFirst(preparesBefore).filter { $0.label == "ui-studio:prepare" }
    check("REQ-016 an unknown bridge call is prepared like an unknown request, then answered", document == #"{"theme":"dark"}"#
          && prepares.count == 1 && prepares.first?.prompt.contains("Unknown request seen by MarkView UI Studio: GET http://electron.ipc/desk/settings/getDocument") == true
          && prepares.first?.prompt.contains("A call of the Electron preload bridge") == true
          && prepares.first?.prompt.contains(StudioIPC.argumentsHeader + ": []") == true
          && prepares.first?.systemPrompt?.contains("ipcMain.handle") == true, document + " " + (prepares.first.map { String($0.prompt.prefix(400)) } ?? "no prompt"))
    let again = await text("return JSON.stringify(await window.desk.settings.getDocument());")
    check("REQ-016 the prepared bridge method serves later calls without the model", again == document
          && CLICompletion.requests.dropFirst(preparesBefore).filter { $0.label == "ui-studio:prepare" }.count == 1)
    check("REQ-016 the bridge's calls are in the request log", session.requests.contains { $0.url == "http://electron.ipc/desk/settings/getDocument"
          && $0.outcome == "simulated" && $0.status == 200 })

    let subscribed = await text("""
        window.__applied = [];
        window.__off = window.desk.settings.onDocumentApplied(doc => window.__applied.push(doc.theme));
        return typeof window.__off;
        """)
    _ = await waitUntil(5) { session.sessionLog.entries.contains { $0.text.contains("onDocumentApplied · page · listening") } }
    let applied = await text("""
        const saved = await window.desk.settings.saveDocument({ id: 'current', theme: 'light' });
        for (let i = 0; i < 40 && !window.__applied.length; i++) await new Promise(r => setTimeout(r, 100));
        return saved.theme + ' ' + window.__applied.join(',');
        """)
    check("REQ-016 a callback registered before its channel existed gets the record a later save writes",
          subscribed == "function" && applied == "light light", "\(subscribed) \(applied)")
    check("REQ-016 the Environment panel shows the bridge as simulated, with its methods",
          StudioIPC.summary(session.spec, globals: session.electronGlobals) == "simulated (4 methods) · window.desk"
          && session.disclosures.contains { $0.contains("simulated like any other API") },
          StudioIPC.summary(session.spec, globals: session.electronGlobals))
    await session.close()
}


/// BUG-090: the application's own route handlers are read from its code, so the map has them when the assistant's inventory fails.
@MainActor
func routeMapChecks() async {
    watchdog.reached("BUG-090 the map is made of the route handlers read from the code when the assistant's inventory fails")
    let fm = FileManager.default
    let previousAnswer = CLICompletion.answer
    defer {
        CLICompletion.mapAnswer = nil
        CLICompletion.answer = previousAnswer
    }
    let assistant = MapAssistant()
    assistant.lock.withLock { assistant.inventoryFails = true }
    assistant.set([:], other: 0.1)
    CLICompletion.mapAnswer = { request in try await assistant.respond(request) }
    CLICompletion.answer = { _ in
        try await Task.sleep(nanoseconds: 100_000_000)
        return CLICompletion.Result(text: "", structured: mapGroupAnswer("app/session"), inputTokens: 10, outputTokens: 5, costUSD: 0)
    }
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-routes-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let web = mapFixture(root)
    func write(_ path: String, _ text: String) {
        let url = web.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    write("app/api/admin/work/queue/route.ts", "export async function GET() { return Response.json([]) }\n")
    write("app/api/admin/users/[id]/route.ts", "export async function PATCH() {}\nexport async function DELETE() {}\n")
    write("app/api/v1/[...path]/route.ts", "export async function GET() {}\n")
    let session = StudioSession(root: root)
    session.mapping.limits.groupSize = 2
    let port = freePort()
    session.start(WebAppTarget(folder: web, label: "routes", command: "python3 -m http.server \(port) --bind 127.0.0.1", ports: [port]))
    let finished = await waitUntil(90) { session.mapping.map?.status == .complete && !session.mapping.isRunning }
    let endpoints = (session.mapping.map?.groups ?? []).flatMap(\.endpoints).map { $0.method + " " + $0.path }
    check("BUG-090 the map is complete although the assistant's inventory failed", finished && session.mapping.map?.inventoried == true,
          "\(session.mapping.map?.status.rawValue ?? "nil") \(session.mapping.map?.message ?? "")")
    check("BUG-090 every route handler of the code is an endpoint of the map, the catch-all proxy is not",
          Set(endpoints) == ["GET /api/admin/work/queue", "PATCH /api/admin/users/:id", "DELETE /api/admin/users/:id"], endpoints.joined(separator: ", "))
    check("BUG-090 the log says the list was read from the code", session.sessionLog.entries.contains { $0.text.contains("route handlers from its code") }
          && session.sessionLog.entries.contains { $0.text.contains("endpoints read from the code") })
    await session.close()
}
