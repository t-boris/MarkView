// UI Studio page runtime in a real WKWebView: requests answered by the simulator through the validated bridge, the seeded
// clock and random numbers, select mode that does not run the element's action, zoom that keeps the page's viewport and
// maps clicks correctly, replayed steps, and the build error overlay report.
// Compiled with the UI Studio models by tools/tests/ui-studio-web-tests.sh; it runs a windowed WebKit page.
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
let watchdog = Watchdog(seconds: 240)

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok  \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

@MainActor
final class Harness: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let token = "harness-session"
    let origin = StudioBridge.Origin(scheme: "http", host: "localhost", port: 5173)
    var simulator: StudioSimulator
    var events: [StudioBridge.Event] = []
    var rejected: [String] = []
    /// Simulated WebSocket and EventSource connections of the page (REQ-015), when a check sets it.
    var channelHub: StudioChannelHub?
    var channelMessages: [StudioBridge.Channel] = []
    var channelLog: [String] = []
    /// Calls of the Electron preload bridge (REQ-016), as they crossed the bridge.
    var ipcRequests: [StudioBridge.Request] = []
    var deliveries: Task<Void, Never>?
    var loaded: CheckedContinuation<Void, Never>?
    let window: NSWindow
    let host: StudioPreviewScrollView
    let webView: WKWebView
    let source: String

    init(source: String) {
        self.source = source
        var spec = StudioEnvironmentSpec()
        spec.entities = [StudioEntity(name: "items", fields: [StudioField(name: "name", type: "string", required: true)])]
        spec.seed = ["items": [.object(["id": .number(1), "name": .string("Alpha")]), .object(["id": .number(2), "name": .string("Beta")])]]
        spec.rules = [StudioRule(id: "list-items", method: "GET", path: "/api/items", operation: .list, entity: "items"),
                      StudioRule(id: "create-item", method: "POST", path: "/api/items", operation: .create, entity: "items")]
        simulator = StudioSimulator(spec: spec, scenario: StudioScenario(id: "populated", name: "Populated", kind: .populated),
                                    appOrigin: origin.text)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host = StudioPreviewScrollView(webView: webView)
        window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1000, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: StudioBridge.handlerName)
        webView.navigationDelegate = self
        host.frame = window.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(host)
        host.viewport = CGSize(width: 800, height: 600)
        host.zoom = 0.5
        window.orderFrontRegardless()
    }

    func load(_ html: String, seed: Int = 7, browser: StudioBrowserProfile = StudioBrowserProfile(),
              keptStorage: [[String: String]] = [], clockAnchor: Double? = nil, electronGlobals: [String]? = nil) async {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        // Stands in for the network under the runtime's own fetch, for requests the runtime passes through (BUG-070).
        // A check never reaches the Mac's location, camera, microphone or clipboard: these guards answer in their place
        // unless the runtime replaces them (REQ-008).
        controller.addUserScript(WKUserScript(source: """
            window.__NativeWebSocket = window.WebSocket; window.__NativeEventSource = window.EventSource;
            (function () { var real = window.fetch; window.__passed = [];
              window.fetch = function (input, init) { var r = new Request(input, init);
                if (r.url.indexOf('/__framework') < 0) return real.apply(this, arguments);
                window.__passed.push((r.headers.get('cache-control') || '') + '|' + (r.headers.get('rsc') || ''));
                return Promise.resolve(new Response('payload', { status: 200 })); }; })();
            (function () {
              var reached = function () { return Promise.reject(new DOMException('a real device API was reached', 'HarnessGuard')); };
              var geo = { getCurrentPosition: function (s, f) { if (f) f({ code: 99 }); }, watchPosition: function (s, f) { if (f) f({ code: 99 }); return 0; },
                clearWatch: function () {} };
              Object.defineProperty(Navigator.prototype, 'geolocation', { get: function () { return geo; }, configurable: true });
              if (navigator.mediaDevices) { navigator.mediaDevices.getUserMedia = reached; navigator.mediaDevices.enumerateDevices = reached; }
              if (navigator.clipboard) { navigator.clipboard.writeText = reached; navigator.clipboard.readText = reached; }
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        var settings: [String: Any] = ["session": token, "generation": simulator.generation, "seed": seed, "testTime": 1_767_225_600_000,
                                       "locale": "de-DE", "timeZone": "Europe/Berlin", "electron": electronGlobals != nil,
                                       "electronGlobals": electronGlobals ?? [], "browser": browser.runtimeConfig, "keptStorage": keptStorage,
                                       "redaction": ["fields": StudioRedactor.defaultConfidentialFields, "patterns": StudioRedactor.secretPatterns]]
        if let clockAnchor { settings["clockAnchor"] = clockAnchor }
        let config = String(decoding: try! JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        controller.addUserScript(WKUserScript(source: source.replacingOccurrences(of: "__MARKVIEW_STUDIO_CONFIG__", with: config),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "http://localhost:5173/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
        navigated?.resume(returning: nil)
        navigated = nil
    }

    var navigated: CheckedContinuation<NSError?, Never>?

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigated?.resume(returning: error as NSError)
        navigated = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigated?.resume(returning: error as NSError)
        navigated = nil
    }

    /// Loads `url` as the page and returns the error, if the load failed.
    func navigate(_ url: String) async -> NSError? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSError?, Never>) in
            navigated = continuation
            webView.load(URLRequest(url: URL(string: url)!, timeoutInterval: 8))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let security = message.frameInfo.securityOrigin
        let sender = StudioBridge.Origin(scheme: security.protocol, host: security.host, port: security.port == 0 ? 80 : security.port)
        let expected = StudioBridge.Expectation(session: token, generation: simulator.generation, origin: origin)
        switch StudioBridge.validate(message.body, isMainFrame: message.frameInfo.isMainFrame, origin: sender, expecting: expected) {
        case .failure(let rejection):
            rejected.append(rejection.description)
            replyHandler(nil, "rejected")
        case .success(.event(let event)):
            events.append(event)
            replyHandler(true, nil)
        case .success(.channel(let channel)):
            channelMessages.append(channel)
            handleChannel(channel, reply: replyHandler)
        case .success(.request(let request)):
            if request.transport == "ipc" { ipcRequests.append(request) }
            let http = StudioHTTPRequest(method: request.method, url: request.url, headers: request.headers, body: request.body,
                                         requestId: request.requestId)
            if request.url.path == "/__framework" {
                return replyHandler(StudioBridge.passThrough(adding: ["cache-control": "no-cache"]), nil)
            }
            if let hub = channelHub, hub.poll(http, source: "page", shown: http.url.absoluteString, reply: { replyHandler(StudioBridge.reply($0), nil) }) {
                return
            }
            let before = simulator.state
            let outcome = simulator.handle(http)
            channelHub?.entitiesChanged(StudioEntityChange.diff(before: before, after: simulator.state, spec: simulator.spec))
            if case .respond(let response, _) = outcome {
                replyHandler(StudioBridge.reply(response), nil)
            } else {
                replyHandler(StudioBridge.reply(.unresolved("\(request.method) \(request.url.path)", reason: "no rule")), nil)
            }
        }
    }

    func js(_ script: String, _ arguments: [String: Any] = [:]) async -> Any? {
        do {
            return try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            print("     script error: \(error.localizedDescription)")
            return nil
        }
    }

    /// The view a click at `point` (window coordinates) lands on, found by hit testing through the zoomed container, when it
    /// is the web view or inside it.
    private func target(at point: NSPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        let inSuperview = content.superview?.convert(point, from: nil) ?? point
        guard let view = content.hitTest(inSuperview), view === webView || view.isDescendant(of: webView) else {
            print("     a click at \(point) in the window does not reach the web view")
            return nil
        }
        return view
    }

    /// A click at a point of the page (CSS pixels): the point is mapped through the zoomed container to the window, hit
    /// tested there, and the events go to the view that was hit. They are not sent through `NSWindow.sendEvent`, which
    /// drops them on a CI runner where the test window never becomes key.
    func click(cssX x: CGFloat, y: CGFloat) {
        let point = webView.convert(NSPoint(x: x, y: y), to: nil)
        guard let view = target(at: point) else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    func move(cssX x: CGFloat, y: CGFloat) {
        let point = webView.convert(NSPoint(x: x, y: y), to: nil)
        guard let view = target(at: point),
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        view.mouseMoved(with: event)
    }

    func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

let page = """
<!doctype html><html><head><meta charset="utf-8"><title>Harness</title>
<style>body{margin:0;font:14px sans-serif} #buy{position:absolute;left:100px;top:100px;width:200px;height:50px}
#name{position:absolute;left:100px;top:200px;width:200px} .row{height:20px}
#far{position:absolute;left:100px;top:900px;width:200px;height:50px} #chart{position:absolute;left:400px;top:100px;width:100px;height:50px}
#spacer{position:absolute;left:0;top:0;width:1px;height:3000px}</style></head>
<body><button id="buy" data-testid="buy" onclick="window.bought=(window.bought||0)+1">Buy</button>
<input id="name" data-testid="name"><ul id="list"></ul>
<div id="spacer"></div><button id="far" onclick="window.farClicked=true">Far</button><canvas id="chart"></canvas>
<script>
window.loadedItems = fetch('/api/items').then(function (r) { return r.json(); });
</script></body></html>
"""

@MainActor
func run() async {
    guard let url = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:)),
          let source = try? String(contentsOf: url, encoding: .utf8) else {
        print("usage: ui-studio-web-harness <markview-ui-studio.js>")
        exit(2)
    }
    watchdog.reached("Open a window and load the page")
    let harness = Harness(source: source)
    await harness.load(page)
    await harness.settle()

    // Requests: fetch and XHR are answered by the simulator through the validated bridge (REQ-002, REQ-006).
    watchdog.reached("Requests")
    let items = await harness.js("const list = await window.loadedItems; return list.map(i => i.name).join(',');") as? String
    check("fetch is answered by the simulation", items == "Alpha,Beta", items ?? "nil")
    let xhr = await harness.js("""
        return await new Promise(resolve => { const x = new XMLHttpRequest(); x.open('POST', '/api/items');
          x.setRequestHeader('content-type', 'application/json'); x.onload = () => resolve(x.status + ' ' + JSON.parse(x.responseText).name);
          x.onerror = () => resolve('error'); x.send(JSON.stringify({name: 'Gamma'})); });
        """) as? String
    check("XHR writes go to the shared simulated state", xhr == "201 Gamma", xhr ?? "nil")
    let after = await harness.js("const r = await fetch('/api/items'); return (await r.json()).length;") as? NSNumber
    check("a created record appears in the list", after?.intValue == 3, "\(after ?? -1)")
    check("no message was rejected", harness.rejected.isEmpty, harness.rejected.joined(separator: "; "))
    let passed = await harness.js("""
        const r = await fetch('/__framework?_rsc=1', { headers: { rsc: '1' } });
        return (await r.text()) + ' ' + window.__passed.join(',');
        """) as? String
    check("BUG-070 a pass-through reaches the server with the headers MarkView adds and the page's own", passed == "payload no-cache|1",
          passed ?? "nil")

    // BUG-079: an Error the application logs is reported with its message and stack. An error of the page's handler that a
    // simulated XHR calls is surfaced with reportError: rethrown from the runtime, WebKit showed only "Script error.".
    watchdog.reached("Logged and hidden errors")
    var errorMark = harness.events.count
    _ = await harness.js("console.error('plain text only'); console.error('Failed:', new TypeError('settings is undefined')); return 1;")
    await harness.settle()
    let logged = harness.events.dropFirst(errorMark).filter { $0.kind == .logged }.map(\.detail)
    check("BUG-079 an Error passed to console.error is reported with its message",
          logged.contains { $0.hasPrefix("console.error: TypeError: settings is undefined") }, logged.joined(separator: " | "))
    check("BUG-079 console.error without an Error object is not reported", !logged.contains { $0.contains("plain text only") })
    errorMark = harness.events.count
    _ = await harness.js("""
        setTimeout(() => eval("console.error(new Error('render failed')); window.strikedeskMissing.settings.get();\\n//# sourceURL=webpack://shell/./src/renderer/App.tsx"), 0);
        return 1;
        """)
    await harness.settle(1.2)
    let thrown = harness.events.dropFirst(errorMark).filter { $0.kind == .runtimeError }.map(\.detail)
    check("BUG-079 an error of eval'd webpack:// code is reported with its message",
          thrown.contains { $0.contains("strikedeskMissing") }, thrown.joined(separator: " | "))

    errorMark = harness.events.count
    _ = await harness.js("""
        const x = new XMLHttpRequest(); x.open('GET', '/api/items');
        x.onload = () => { window.strikedeskMissing.backend.connect(); }; x.send(); return 1;
        """)
    await harness.settle(1.2)
    let fromHandler = harness.events.dropFirst(errorMark).filter { $0.kind == .runtimeError }.map(\.detail)
    check("BUG-079 an error of the page's handler of a simulated XHR keeps its message (it was \"Script error.\")",
          fromHandler.contains { $0.contains("strikedeskMissing.backend") }, fromHandler.joined(separator: " | "))

    // Reproducible conditions: seeded random numbers, the scenario's clock and locale.
    watchdog.reached("Reproducible conditions")
    let first = await harness.js("return [Math.random(), Math.random()].join(',');") as? String
    let now = await harness.js("return Date.now() >= 1767225600000 && Date.now() < 1767225600000 + 60000;") as? Bool
    let locale = await harness.js("return navigator.language + ' ' + new Intl.DateTimeFormat().resolvedOptions().timeZone;") as? String
    check("the clock starts at the scenario's test time", now == true)
    check("the locale and time zone follow the scenario", locale == "de-DE Europe/Berlin", locale ?? "nil")
    await harness.load(page)
    await harness.settle()
    let second = await harness.js("return [Math.random(), Math.random()].join(',');") as? String
    check("random numbers repeat for the same seed", first != nil && first == second, "\(first ?? "nil") vs \(second ?? "nil")")
    // DEC-006: the clock shows the test time at MarkView's anchor and runs on from it, across page loads.
    await harness.load(page, clockAnchor: Date().timeIntervalSince1970 * 1000 - 3_600_000)
    await harness.settle()
    let elapsed = await harness.js("return Date.now() - 1767225600000;") as? NSNumber
    check("DEC-006 a page loaded an hour after the anchor shows the test time plus an hour",
          elapsed.map { abs($0.doubleValue - 3_600_000) < 60_000 } == true, "\(elapsed ?? -1)")

    // Zoom keeps the application's viewport (PRE-03).
    watchdog.reached("Zoom keeps the application's viewport")
    let size = await harness.js("return innerWidth + 'x' + innerHeight;") as? String
    check("the page keeps its 800x600 viewport at 50 % zoom", size == "800x600", size ?? "nil")
    let shown = harness.webView.convert(harness.webView.bounds, to: nil).size
    check("the preview is drawn at half size", abs(shown.width - 400) < 1 && abs(shown.height - 300) < 1, "\(shown)")

    // Interact mode: a click reaches the element and runs its action.
    watchdog.reached("Interact mode")
    harness.click(cssX: 200, y: 125)
    await harness.settle()
    let bought = await harness.js("return window.bought || 0;") as? NSNumber
    check("a click in interact mode runs the element's action at 50 % zoom", bought?.intValue == 1, "\(bought ?? -1)")

    // Select mode: the click selects and does not run the action (PRE-01, PRE-02).
    watchdog.reached("Select mode")
    let picking = Task { @MainActor in await harness.js("return await Promise.race([window.__markviewStudio.pick(), new Promise(r => setTimeout(() => r(null), 8000))]);") }
    await harness.settle(0.3)
    harness.move(cssX: 200, y: 125)
    harness.click(cssX: 200, y: 125)
    let picked = await picking.value as? [String: Any]
    let boughtAfter = await harness.js("return window.bought || 0;") as? NSNumber
    check("select mode picks the element under the pointer", (picked?["tag"] as? String)?.hasPrefix("button#buy") == true,
          "\(picked?["tag"] ?? "nil")")
    check("select mode does not run the element's action", boughtAfter?.intValue == 1, "\(boughtAfter ?? -1)")
    let rect = picked?["rect"] as? [String: Any]
    check("the selection's geometry is in page pixels", (rect?["x"] as? NSNumber)?.intValue == 100 && (rect?["width"] as? NSNumber)?.intValue == 200,
          "\(rect ?? [:])")
    if let picked, let context = StudioSelectionContext(picked) {
        check("the selection is described for the assistant", context.selector.contains("buy") && context.instanceCount >= 1, context.selector)
    } else {
        check("the selection is described for the assistant", false)
    }
    let parent = await harness.js("return window.__markviewStudio.parent();") as? [String: Any]
    check("parent navigation selects the enclosing element", (parent?["tag"] as? String)?.hasPrefix("body") == true, "\(parent?["tag"] ?? "nil")")
    check("an element without development source metadata says so", (picked?["boundary"] as? String)?.contains("No development source metadata") == true,
          "\(picked?["boundary"] ?? "nil")")

    // A canvas has nothing inside it to select: the boundary is disclosed (PRE-07).
    watchdog.reached("A canvas has nothing inside it to select")
    let pickingCanvas = Task { @MainActor in await harness.js("return await Promise.race([window.__markviewStudio.pick(), new Promise(r => setTimeout(() => r(null), 8000))]);") }
    await harness.settle(0.3)
    harness.move(cssX: 450, y: 125)
    harness.click(cssX: 450, y: 125)
    let canvas = await pickingCanvas.value as? [String: Any]
    check("a canvas discloses that what it draws cannot be selected", (canvas?["boundary"] as? String)?.contains("canvas") == true,
          "\(canvas?["tag"] ?? "nil") \(canvas?["boundary"] ?? "nil")")

    // Scrolled page, still at 50 % zoom: the element under the pointer is selected and its geometry follows the scroll (PRE-02).
    watchdog.reached("Scrolled page, still at 50 % zoom")
    _ = await harness.js("window.scrollTo(0, 700); return scrollY;")
    await harness.settle(0.3)
    let pickingFar = Task { @MainActor in await harness.js("return await Promise.race([window.__markviewStudio.pick(), new Promise(r => setTimeout(() => r(null), 8000))]);") }
    await harness.settle(0.3)
    harness.move(cssX: 200, y: 225)
    harness.click(cssX: 200, y: 225)
    let far = await pickingFar.value as? [String: Any]
    let farRect = far?["rect"] as? [String: Any]
    check("a scrolled page selects the element under the pointer", (far?["tag"] as? String)?.hasPrefix("button#far") == true
          && (farRect?["y"] as? NSNumber)?.intValue == 200, "\(far?["tag"] ?? "nil") \(farRect ?? [:])")
    let farClicked = await harness.js("return window.farClicked === true;") as? Bool
    check("selecting on a scrolled page does not run the action", farClicked == false)
    _ = await harness.js("window.scrollTo(0, 800); return scrollY;")
    await harness.settle(0.3)
    let moved = (await harness.js("return window.__markviewStudio.selected();") as? [String: Any])?["rect"] as? [String: Any]
    check("the selection's geometry follows a later scroll", (moved?["y"] as? NSNumber)?.intValue == 100, "\(moved ?? [:])")
    _ = await harness.js("window.scrollTo(0, 0); return window.__markviewStudio.setSelecting(false);")

    // Restoration steps replay (SCN-02).
    watchdog.reached("Restoration steps replay")
    let replay = await harness.js("return await window.__markviewStudio.replay(steps);",
                                  ["steps": [["action": "type", "selector": "[data-testid=\"name\"]", "text": "Delta"],
                                             ["action": "click", "selector": "[data-testid=\"buy\"]"]]]) as? [String: Any]
    let typed = await harness.js("return document.getElementById('name').value + ' ' + window.bought;") as? String
    check("restoration steps replay", replay?["ok"] as? Bool == true && typed == "Delta 2", "\(replay ?? [:]) \(typed ?? "nil")")

    // A build error overlay of the dev server is reported (EDIT-08).
    watchdog.reached("A build error overlay of the dev server is reported")
    _ = await harness.js("document.body.appendChild(document.createElement('vite-error-overlay')).textContent = 'Failed to compile App.tsx'; return true;")
    await harness.settle(1.5)
    check("the dev server's build error overlay is reported", harness.events.contains { $0.kind == .buildError },
          harness.events.map(\.kind.rawValue).joined(separator: ","))

    // BUG-067: the overlay going away is reported (empty detail); Next.js shows every issue in one dialog
    // and only its "Build Error" is a build failure; the same build error coming back is reported again.
    watchdog.reached("Next.js issues are told apart from build errors")
    func buildEvents(since mark: Int) -> [String] { harness.events.dropFirst(mark).filter { $0.kind == .buildError }.map(\.detail) }
    var mark = harness.events.count
    _ = await harness.js("document.querySelector('vite-error-overlay').remove(); return true;")
    await harness.settle(1)
    check("a build error overlay going away is reported as cleared", buildEvents(since: mark) == [""], buildEvents(since: mark).joined(separator: "|"))
    mark = harness.events.count
    _ = await harness.js("""
        const portal = document.body.appendChild(document.createElement('nextjs-portal'));
        portal.attachShadow({ mode: 'open' });
        window.nextDialog = function (label) {
          portal.shadowRoot.innerHTML = label ? '<div data-nextjs-dialog><span id="nextjs__container_errors_label">' + label
            + '</span><p>[fx] rates unavailable in client-web-app: marketplace unreachable</p></div>' : '';
        };
        window.nextDialog('Console Error');
        return true;
        """)
    await harness.settle(1)
    _ = await harness.js("window.nextDialog('Runtime TypeError'); return true;")
    await harness.settle(1)
    check("a Next.js console or runtime error is not a build error", buildEvents(since: mark).isEmpty, buildEvents(since: mark).joined(separator: "|"))
    _ = await harness.js("window.nextDialog('Build Error'); return true;")
    await harness.settle(1)
    _ = await harness.js("window.nextDialog(''); return true;")
    await harness.settle(1)
    _ = await harness.js("window.nextDialog('Build Error'); return true;")
    await harness.settle(1)
    let next = buildEvents(since: mark)
    check("a Next.js build error is reported, cleared when its dialog closes, and reported again when it returns",
          next.count == 3 && next[0].hasPrefix("Next.js: Build Error") && next[1].isEmpty && next[2] == next[0], next.joined(separator: "|"))
    _ = await harness.js("document.querySelector('nextjs-portal').remove(); return true;")
    await harness.settle(1)

    await browserChecks(harness)
    await realtimeChecks(harness)
    await ipcChecks(harness)

    // Messages of an earlier generation are rejected after Reset (SIM-10).
    watchdog.reached("Messages of an earlier generation are rejected after Reset")
    harness.simulator.reset()
    _ = await harness.js("try { await fetch('/api/items'); } catch (e) {} return true;")
    await harness.settle()
    check("a message of the previous generation is rejected", harness.rejected.contains { $0.contains("earlier generation") },
          harness.rejected.joined(separator: "; "))

    // The application connection policy as a WebKit content rule list (REQ-006): it compiles, blocks other origins before
    // any network access and lets the development server and explicitly allowed addresses through.
    watchdog.reached("The application connection policy as a WebKit content rule list")
    let allowed = ["https://fonts.googleapis.com/*", "https://*.example.net/*"]
    let json = StudioConnectionPolicy.ruleListJSON(appOrigin: harness.origin, allowed: allowed)
    let list = await StudioConnectionPolicy.compile(identifier: "markview-ui-studio-harness", json: json)
    check("the connection policy compiles as a content rule list", list != nil, json)
    check("DEC-011 pictures of any address pass; documents, scripts and data of other origins stay blocked",
          json.contains(#""resource-type":["image"]"#) && json.components(separatedBy: "resource-type").count == 2, json)
    if let list {
        harness.webView.configuration.userContentController.add(list)
        harness.webView.configuration.userContentController.removeAllUserScripts()
        let blockedCode = 104 // WebKitErrorFrameLoadBlockedByContentBlocker
        let other = await harness.navigate("https://example.org/")
        check("another origin is blocked by the policy", other?.domain == "WebKitErrorDomain" && other?.code == blockedCode,
              "\(other?.domain ?? "loaded") \(other?.code ?? 0)")
        let subdomainOfAllowed = await harness.navigate("https://api.example.net/")
        check("a subdomain of an allowed wildcard is not blocked", subdomainOfAllowed?.code != blockedCode,
              "\(subdomainOfAllowed?.domain ?? "loaded") \(subdomainOfAllowed?.code ?? 0)")
        let lookalike = await harness.navigate("https://example.net.attacker.org/")
        check("a look-alike host is blocked", lookalike?.code == blockedCode, "\(lookalike?.domain ?? "loaded") \(lookalike?.code ?? 0)")
        let server = await harness.navigate("http://127.0.0.1:5173/")
        check("the development server is not blocked", server?.code != blockedCode, "\(server?.domain ?? "loaded") \(server?.code ?? 0)")
        let otherPort = await harness.navigate("http://localhost:5174/")
        check("another local port is blocked", otherPort?.code == blockedCode, "\(otherPort?.domain ?? "loaded") \(otherPort?.code ?? 0)")
        StudioConnectionPolicy.remove(identifier: "markview-ui-studio-harness")
    }

    print(failures == 0 ? "All UI Studio page checks passed." : "\(failures) UI Studio page check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

/// Location, permissions, clipboard, camera and microphone, and notifications answer from the scenario's browser settings
/// and are reported to Studio; the kept localStorage is written once per generation (REQ-008).
@MainActor
func browserChecks(_ harness: Harness) async {
    let browserPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Browser</title></head><body><p id="t">Browser</p>
    <script>window.consentAtStart = localStorage.getItem('consent');</script></body></html>
    """
    func browserEvents(since mark: Int) -> [String] { harness.events.dropFirst(mark).filter { $0.kind == .browser }.map(\.detail) }
    func text(_ script: String) async -> String { (await harness.js(script) as? String) ?? "nil" }
    let permissions = """
        const names = ['geolocation', 'notifications', 'camera', 'microphone', 'clipboard-read', 'clipboard-write'];
        const states = [];
        for (const name of names) { const status = await navigator.permissions.query({ name }); states.push(name + '=' + status.state); }
        return states.join(',');
        """

    // The default settings: everything denied, notifications not asked yet.
    watchdog.reached("REQ-008 browser features under the default settings")
    var mark = harness.events.count
    await harness.load(browserPage)
    await harness.settle(0.2)
    let denied = await text("""
        let calledNow = false;
        const answer = new Promise(resolve => navigator.geolocation.getCurrentPosition(() => { calledNow = true; resolve('position'); },
          e => { calledNow = true; resolve(e.code + ' ' + (e.code === e.PERMISSION_DENIED) + ' ' + (e instanceof GeolocationPositionError)); }));
        const synchronous = calledNow;
        return (await answer) + ' ' + synchronous;
        """)
    check("REQ-008 location denied answers PERMISSION_DENIED asynchronously", denied == "1 true true false", denied)
    let deniedStates = await text(permissions)
    let otherPermission = await text("try { await navigator.permissions.query({ name: 'no-such-permission' }); return 'resolved'; } catch (e) { return e.name; }")
    check("REQ-008 permissions.query answers the default settings and asks the browser about other names",
          deniedStates == "geolocation=denied,notifications=prompt,camera=denied,microphone=denied,clipboard-read=granted,clipboard-write=granted"
          && otherPermission == "TypeError", deniedStates + " " + otherPermission)
    let refused = await text("""
        try { await navigator.mediaDevices.getUserMedia({ video: true, audio: true }); return 'stream'; }
        catch (e) { return e.name + ' ' + (e instanceof DOMException); }
        """)
    check("REQ-008 camera and microphone denied answer NotAllowedError", refused == "NotAllowedError true", refused)
    let unlabelled = await text("const list = await navigator.mediaDevices.enumerateDevices(); return list.map(d => d.kind + ':' + d.label).join(',');")
    check("REQ-008 without permission the devices are listed without labels", unlabelled == "audioinput:,videoinput:,audiooutput:", unlabelled)
    let notAsked = await text("""
        const notification = new Notification('Hi', { body: 'There' });
        const event = await new Promise(resolve => { notification.onshow = () => resolve('show'); notification.onerror = () => resolve('error'); });
        const promised = await Notification.requestPermission();
        const called = await new Promise(resolve => Notification.requestPermission(resolve));
        return [Notification.permission, promised, called, event].join(',');
        """)
    check("REQ-008 notifications not asked yet: the permission is default and nothing is shown", notAsked == "default,default,default,error", notAsked)
    let deniedUses = browserEvents(since: mark)
    check("REQ-008 each use under the default settings is reported to Studio",
          ["geolocation: denied", "permissions: camera is denied", "media: camera and microphone denied", "media: devices listed",
           "notifications: not shown (permission default) \"Hi\" — There", "notifications: permission requested, answered default"]
            .allSatisfy(deniedUses.contains), deniedUses.joined(separator: " | "))

    // The clipboard is the page's own: reads give the scenario's text, writes are reported by size and never reach the Mac.
    watchdog.reached("REQ-008 the clipboard of the page")
    mark = harness.events.count
    let pasteboard = NSPasteboard.general.changeCount
    await harness.load(browserPage, browser: StudioBrowserProfile(clipboardText: "SAVE20"))
    await harness.settle(0.2)
    let clipboard = await text("""
        const first = await navigator.clipboard.readText();
        const written = await navigator.clipboard.writeText('hello there!').then(() => 'resolved', e => 'rejected ' + e.name);
        const again = await navigator.clipboard.readText();
        await navigator.clipboard.write([new ClipboardItem({ 'text/plain': new Blob(['abc'], { type: 'text/plain' }) })]);
        const range = document.createRange(); range.selectNodeContents(document.getElementById('t'));
        getSelection().removeAllRanges(); getSelection().addRange(range);
        const copied = document.execCommand('copy');
        const items = await navigator.clipboard.read();
        const pasted = await (await items[0].getType('text/plain')).text();
        return [first, written, again, copied, pasted].join('|');
        """)
    check("REQ-008 clipboard reads give the scenario's text, then what the page wrote; writes never throw",
          clipboard == "SAVE20|resolved|hello there!|true|Browser", clipboard)
    let clipboardUses = browserEvents(since: mark)
    check("REQ-008 clipboard writes are reported by size, never with their contents, and never reach the Mac's clipboard",
          ["clipboard: write (12 chars)", "clipboard: write (3 chars)", "clipboard: write (7 chars)", "clipboard: read (6 chars)"].allSatisfy(clipboardUses.contains)
          && !clipboardUses.contains { $0.contains("hello") || $0.contains("SAVE20") || $0.contains("abc") || $0.contains("Browser") }
          && NSPasteboard.general.changeCount == pasteboard, clipboardUses.joined(separator: " | "))

    // A place, a test stream and granted notifications.
    watchdog.reached("REQ-008 a place, a test stream and granted notifications")
    mark = harness.events.count
    let chicago = StudioBrowserProfile.Place(latitude: 41.8781, longitude: -87.6298, accuracy: 30, label: "Chicago")
    await harness.load(browserPage, browser: StudioBrowserProfile(location: .place(chicago), media: .testStream, notifications: .granted))
    await harness.settle(0.2)
    let position = await text("""
        const p = await new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(resolve, reject));
        const inClock = p.timestamp >= 1767225600000 && p.timestamp < 1767225600000 + 600000;
        return [p.coords.latitude, p.coords.longitude, p.coords.accuracy, inClock, p instanceof GeolocationPosition,
                JSON.stringify(p.toJSON().coords.latitude)].join(',');
        """)
    check("REQ-008 a place answers its coordinates at the session's test time", position == "41.8781,-87.6298,30,true,true,41.8781", position)
    let watched = await text("""
        let count = 0, cleared = 0;
        const id = navigator.geolocation.watchPosition(() => count++);
        const other = navigator.geolocation.watchPosition(() => cleared++);
        navigator.geolocation.clearWatch(other);
        await new Promise(resolve => setTimeout(resolve, 300));
        navigator.geolocation.clearWatch(id);
        return [id > 0, other !== id, count, cleared].join(',');
        """)
    check("REQ-008 watchPosition answers once and clearWatch stops a watch", watched == "true,true,1,0", watched)
    let grantedStates = await text(permissions)
    check("REQ-008 permissions.query answers the scenario's settings",
          grantedStates == "geolocation=granted,notifications=granted,camera=granted,microphone=granted,clipboard-read=granted,clipboard-write=granted",
          grantedStates)
    let stream = await text("""
        try {
          const s = await navigator.mediaDevices.getUserMedia({ video: { width: 320, height: 240 }, audio: true });
          const v = s.getVideoTracks(), a = s.getAudioTracks();
          return [v.length, a.length, v[0].readyState, a[0].readyState, v[0].label, a[0].label, s instanceof MediaStream].join(',');
        } catch (e) { return 'error ' + e.name + ' ' + e.message; }
        """)
    check("REQ-008 a test stream has a live video track and a live audio track",
          stream == "1,1,live,live,MarkView Test Camera,MarkView Test Microphone,true", stream)
    let devices = await text("const list = await navigator.mediaDevices.enumerateDevices(); return list.map(d => d.kind + ':' + d.label).join(',');")
    check("REQ-008 the devices listed are test devices",
          devices == "audioinput:MarkView Test Microphone,videoinput:MarkView Test Camera,audiooutput:MarkView Test Speakers", devices)
    let granted = await text("""
        const notification = new Notification('Order shipped', { body: 'Your order is on its way', tag: 'order' });
        const event = await new Promise(resolve => { notification.onshow = () => resolve('show'); notification.onerror = () => resolve('error'); });
        return [Notification.permission, await Notification.requestPermission(), event, notification.title, notification.tag].join(',');
        """)
    check("REQ-008 granted notifications are captured instead of shown", granted == "granted,granted,show,Order shipped,order", granted)
    let grantedUses = browserEvents(since: mark)
    check("REQ-008 the place, the stream and the notification are reported to Studio",
          ["geolocation: place \"Chicago\"", "media: test stream for the camera and microphone",
           "notifications: shown \"Order shipped\" — Your order is on its way"].allSatisfy(grantedUses.contains), grantedUses.joined(separator: " | "))

    // A location that cannot be found, and notifications the person denied.
    watchdog.reached("REQ-008 location unavailable and notifications denied")
    await harness.load(browserPage, browser: StudioBrowserProfile(location: .unavailable, notifications: .denied))
    await harness.settle(0.2)
    let unavailable = await text("""
        const code = await new Promise(resolve => navigator.geolocation.getCurrentPosition(() => resolve('position'), e => resolve(e.code)));
        const state = (await navigator.permissions.query({ name: 'geolocation' })).state;
        return [code, state, Notification.permission, await Notification.requestPermission()].join(',');
        """)
    check("REQ-008 location unavailable answers POSITION_UNAVAILABLE; denied notifications stay denied", unavailable == "2,granted,denied,denied", unavailable)

    // Kept localStorage is written before the application's scripts, once per generation.
    watchdog.reached("REQ-008 kept localStorage")
    let kept = [["key": "consent", "value": "yes"]]
    await harness.load(browserPage, keptStorage: kept)
    let atStart = await text("return String(window.consentAtStart);")
    check("REQ-008 a kept localStorage entry is there before the application's scripts run", atStart == "yes", atStart)
    _ = await harness.js("localStorage.setItem('consent', 'changed'); return true;")
    await harness.load(browserPage, keptStorage: kept)
    let sameGeneration = await text("return String(window.consentAtStart);")
    check("REQ-008 a later page of the same generation keeps what the application changed", atStart == "yes" && sameGeneration == "changed",
          sameGeneration)
    harness.simulator.reset()
    await harness.load(browserPage, keptStorage: kept)
    let nextGeneration = await text("return String(window.consentAtStart);")
    check("REQ-008 a new generation writes the kept entry again", nextGeneration == "yes", nextGeneration)
    check("REQ-008 browser events pass the bridge's validation", harness.rejected.isEmpty && harness.events.contains { $0.kind == .browser },
          harness.rejected.joined(separator: "; "))
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
application.run()

// MARK: - Real-time channels and GraphQL (REQ-015)

extension Harness {
    /// The session's channel handling, without preparation: an address no channel answers fails like a refused socket.
    func handleChannel(_ message: StudioBridge.Channel, reply: @escaping (Any?, String?) -> Void) {
        guard let hub = channelHub else { return reply(["ok": false, "code": 1006, "reason": "no channels"], nil) }
        let id = "page-" + message.id
        switch message.action {
        case .open:
            guard let url = message.url else { return reply(nil, "No URL.") }
            let pageID = message.id
            let sink: StudioChannelHub.Sink = { [weak self] frames in self?.deliver(pageID, frames) }
            // A callback of the preload bridge waits for its channel, as in the session (REQ-016).
            let opening = message.transport == .ipc
                ? hub.listen(id: id, url: url, transport: .ipc, source: "page", shown: url.absoluteString, sink: sink)
                : hub.open(id: id, url: StudioChannelRoute.httpURL(url), protocols: message.protocols,
                           transport: message.transport == .eventSource ? .eventSource : .webSocket, source: "page",
                           shown: url.absoluteString, sink: sink)
            switch opening {
            case .accepted(let chosen, let frames): reply(["ok": true, "protocol": chosen ?? "", "frames": frames.map(\.bridgeValue)], nil)
            case .unknown(let reason), .refused(let reason): reply(["ok": false, "code": 1006, "reason": reason], nil)
            }
        case .send:
            let frames = message.text.map { hub.receive(id: id, text: $0) } ?? message.binary.map { hub.receive(id: id, binary: $0) } ?? []
            reply(["frames": frames.map(\.bridgeValue)], nil)
        case .close:
            hub.close(id: id, code: message.code)
            reply(["ok": true], nil)
        }
    }

    /// Pushes frames to the page in order, as the session does.
    func deliver(_ pageID: String, _ frames: [StudioChannelFrame]) {
        guard !frames.isEmpty else { return }
        let values = frames.map(\.bridgeValue)
        let previous = deliveries
        deliveries = Task { @MainActor [weak self] in
            await previous?.value
            _ = await self?.js("return window.__markviewStudio.deliver(id, frames);", ["id": pageID, "frames": values])
        }
    }

    func makeChannelHub() -> StudioChannelHub {
        StudioChannelHub(environment: StudioChannelHub.Environment(
            spec: { [unowned self] in simulator.spec }, state: { [unowned self] in simulator.state }, appOrigin: { [unowned self] in origin.text },
            perform: { [unowned self] operation, entity, id, fields in
                let before = simulator.state
                let response = simulator.perform(operation, entity: entity, id: id, fields: fields)
                let changes = StudioEntityChange.diff(before: before, after: simulator.state, spec: simulator.spec)
                Task { @MainActor [weak self] in self?.channelHub?.entitiesChanged(changes) }
                return response
            },
            graphQL: { [unowned self] url, payload in
                let before = simulator.state
                let http = StudioHTTPRequest(method: "POST", url: url, headers: ["content-type": "application/json"], body: payload.text,
                                             requestId: UUID().uuidString)
                let outcome = simulator.handle(http)
                let changes = StudioEntityChange.diff(before: before, after: simulator.state, spec: simulator.spec)
                Task { @MainActor [weak self] in self?.channelHub?.entitiesChanged(changes) }
                if case .respond(let response, _) = outcome { return response.body.flatMap { StudioJSON(text: $0) } ?? .null }
                return .object(["errors": .array([StudioGraphQLExecutor.error("not simulated")])])
            },
            redact: { $0 }, log: { [unowned self] text, _ in channelLog.append(text) }))
    }
}

@MainActor
func realtimeChecks(_ harness: Harness) async {
    func text(_ script: String) async -> String { (await harness.js(script) as? String) ?? "nil" }
    func json(_ text: String) -> StudioJSON { StudioJSON(text: text) ?? .null }
    let saved = harness.simulator
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "messages", fields: [StudioField(name: "text", type: "string", required: true)]),
                     StudioEntity(name: "posts", fields: [StudioField(name: "title", type: "string", required: true)])]
    spec.seed = ["messages": [json(#"{"id":1,"text":"Hello"}"#)], "posts": [json(#"{"id":1,"title":"First"}"#), json(#"{"id":2,"title":"Second"}"#)]]
    spec.rules = [StudioRule(id: "messages-create", method: "POST", path: "/api/messages", operation: .create, entity: "messages")]
    spec.channels = [
        StudioChannel(id: "chat", path: "/ws/chat", wire: .raw, onConnect: [StudioChannelMessage(data: json(#"{"type":"welcome"}"#))],
                      onMessage: [StudioChannelReply(match: ["type": .string("ping")], reply: [StudioChannelMessage(data: json(#"{"type":"pong"}"#))]),
                                  StudioChannelReply(match: ["size": .number(3)], reply: [StudioChannelMessage(event: "binary", data: .string("{{message.binary}}"))])],
                      links: [StudioChannelLink(entity: "messages", on: [.create], message: StudioChannelMessage(data: json(#"{"type":"new","message":"{{record}}"}"#)))]),
        StudioChannel(id: "io", path: "/socket.io", wire: .socketio, onConnect: [StudioChannelMessage(event: "hello", data: json(#"{"user":"test"}"#))],
                      onMessage: [StudioChannelReply(match: ["event": .string("get-rooms")], reply: [StudioChannelMessage(data: json(#"["general","random"]"#))])]),
        StudioChannel(id: "realtime", path: "wss://abc.supabase.co/realtime/v1/websocket", wire: .phoenix),
        StudioChannel(id: "feed", path: "/api/stream", wire: .raw, onConnect: [StudioChannelMessage(event: "hello", data: json(#"{"ok":true}"#))]),
        StudioChannel(id: "gql", path: "/graphql", wire: .graphqlWS),
    ]
    spec.graphQL = [StudioGraphQLOperation(id: "q-posts", kind: .query, field: "posts", action: .list, entity: "posts"),
                    StudioGraphQLOperation(id: "m-post", kind: .mutation, field: "createPost", action: .create, entity: "posts"),
                    StudioGraphQLOperation(id: "s-post", kind: .subscription, field: "postAdded", action: .get, entity: "posts", on: [.create])]
    harness.simulator = StudioSimulator(spec: spec, scenario: StudioScenario(id: "live", name: "Live", kind: .populated), appOrigin: harness.origin.text)
    harness.channelHub = harness.makeChannelHub()
    let rejectedBefore = harness.rejected.count
    let realtimePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Live</title></head><body><ul id="posts"></ul>
    <script>
    window.postsShown = fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ query: 'query Posts { posts { id title } }' }) })
      .then(r => r.json()).then(body => { document.getElementById('posts').innerHTML = body.data.posts.map(p => '<li>' + p.title + '</li>').join(''); return true; });
    </script></body></html>
    """
    await harness.load(realtimePage)
    await harness.settle(0.3)

    // The development server's own sockets stay real; nothing about them crosses the bridge.
    watchdog.reached("REQ-015 hot reload sockets stay real")
    let openedBefore = harness.channelMessages.count
    let real = await text("""
        const sockets = [new WebSocket('ws://localhost:5173/_next/webpack-hmr'), new WebSocket('ws://localhost:5173/', 'vite-hmr'),
          new WebSocket('/ws'), new WebSocket('ws://localhost:5173/sockjs-node/123/abc/websocket'), new WebSocket('/some/dev/reload')];
        const kinds = sockets.map(s => Object.getPrototypeOf(s) === window.__NativeWebSocket.prototype ? 'real' : 'simulated');
        const source = new EventSource('/__dev/reload');
        kinds.push(Object.getPrototypeOf(source) === window.__NativeEventSource.prototype ? 'real' : 'simulated');
        kinds.push(String(sockets[0] instanceof WebSocket));
        sockets.forEach(s => s.close()); source.close();
        return kinds.join(',');
        """)
    await harness.settle(0.2)
    check("REQ-015 hot reload and other dev-server sockets keep the real WebSocket and EventSource", real == "real,real,real,real,real,real,true", real)
    check("REQ-015 a kept socket sends nothing over the bridge", harness.channelMessages.count == openedBefore,
          "\(harness.channelMessages.dropFirst(openedBefore).map { $0.url?.absoluteString ?? "" })")

    // A GraphQL query renders from the simulated state.
    watchdog.reached("REQ-015 GraphQL")
    let rendered = await text("await window.postsShown; return document.getElementById('posts').textContent;")
    check("REQ-015 a GraphQL query renders the simulated records", rendered == "FirstSecond", rendered)

    // A raw WebSocket: connect message, a reply, a close with code; a REST write pushed through the entity link.
    watchdog.reached("REQ-015 raw WebSocket")
    let raw = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:5173/ws/chat'); const log = ['state:' + ws.readyState];
          ws.onopen = () => { log.push('open:' + ws.readyState); ws.send(JSON.stringify({ type: 'ping' })); };
          ws.onmessage = e => { log.push(e.data); if (JSON.parse(e.data).type === 'pong') ws.close(4000, 'done'); };
          ws.onerror = () => log.push('error');
          ws.onclose = e => { log.push('close:' + e.code + ':' + e.reason + ':' + e.wasClean + ':' + ws.readyState); resolve(log.join('|')); };
          setTimeout(() => resolve('timeout ' + log.join('|')), 5000);
        });
        """)
    check("REQ-015 a simulated WebSocket connects, gets the connect message, sends and gets the reply, and closes",
          raw == #"state:0|open:1|{"type":"welcome"}|{"type":"pong"}|close:4000:done:true:3"#, raw)
    let pushed = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:5173/ws/chat');
          ws.onmessage = e => {
            const message = JSON.parse(e.data);
            if (message.type === 'welcome') fetch('/api/messages', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: 'Live' }) });
            if (message.type === 'new') { ws.close(); resolve(message.message.text + ' ' + message.message.id); }
          };
          setTimeout(() => resolve('timeout'), 5000);
        });
        """)
    check("REQ-015 a REST write is pushed to the open WebSocket", pushed == "Live 2", pushed)
    let binary = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:5173/ws/chat'); ws.binaryType = 'arraybuffer';
          ws.onopen = () => ws.send(new Uint8Array([1, 2, 3]));
          ws.onmessage = e => { if (e.data instanceof ArrayBuffer) { ws.close(); resolve(Array.from(new Uint8Array(e.data)).join(',')); } };
          setTimeout(() => resolve('timeout'), 5000);
        });
        """)
    check("REQ-015 binary messages travel as ArrayBuffer", binary == "1,2,3", binary)
    let errors = await text("""
        const ws = new WebSocket('ws://localhost:5173/ws/chat'); const out = [];
        try { ws.send('early'); } catch (e) { out.push(e.name); }
        try { ws.close(1006); } catch (e) { out.push(e.name); }
        try { new WebSocket('ftp://example.org/'); } catch (e) { out.push(e.name); }
        ws.close(); return out.join(',');
        """)
    check("REQ-015 the simulated WebSocket throws like the browser's", errors == "InvalidStateError,InvalidAccessError,SyntaxError", errors)
    let unknown = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:5173/api/nothing-here'); const log = [];
          ws.onerror = () => log.push('error'); ws.onclose = e => { log.push('close:' + e.code); resolve(log.join('|')); };
          setTimeout(() => resolve('timeout'), 5000);
        });
        """)
    check("REQ-015 a socket no channel answers fails like a refused connection", unknown == "error|close:1006", unknown)

    // Socket.IO over a WebSocket and over long-polling.
    watchdog.reached("REQ-015 Socket.IO")
    let socketIO = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:5173/socket.io/?EIO=4&transport=websocket'); const log = [];
          ws.onmessage = e => {
            const packet = String(e.data); log.push(packet.slice(0, 2));
            if (packet[0] === '0') ws.send('40');
            if (packet.startsWith('40')) ws.send('421["get-rooms"]');
            if (packet.startsWith('42')) log.push(packet);
            if (packet.startsWith('431')) { log.push(packet); ws.close(); resolve(log.join('|')); }
          };
          setTimeout(() => resolve('timeout ' + log.join('|')), 5000);
        });
        """)
    check("REQ-015 Socket.IO: open, connect, greeting and acknowledgement", socketIO == #"0{|40|42|42["hello",{"user":"test"}]|43|431[["general","random"]]"#, socketIO)
    let polling = await text("""
        const base = '/socket.io/?EIO=4&transport=polling';
        const open = await (await fetch(base + '&t=1')).text();
        const sid = JSON.parse(open.slice(1)).sid;
        const posted = await (await fetch(base + '&sid=' + sid, { method: 'POST', body: '40' })).text();
        const next = await (await fetch(base + '&sid=' + sid)).text();
        return [open.slice(0, 2), posted, next.split('\\u001e').map(p => p.slice(0, 2)).join('+')].join('|');
        """)
    check("REQ-015 Socket.IO long-polling from the page", polling == "0{|ok|40+42", polling)

    // Supabase Realtime: a join with postgres_changes, then a write pushed as a change.
    watchdog.reached("REQ-015 Supabase Realtime")
    let supabase = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('wss://abc.supabase.co/realtime/v1/websocket?apikey=test-key&vsn=1.0.0');
          ws.onopen = () => ws.send(JSON.stringify({ topic: 'realtime:public:messages', event: 'phx_join', ref: '1', join_ref: '1',
            payload: { config: { postgres_changes: [{ event: '*', schema: 'public', table: 'messages' }] } } }));
          ws.onmessage = e => {
            const m = JSON.parse(e.data);
            if (m.event === 'phx_reply' && m.ref === '1') fetch('/api/messages', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: 'Realtime' }) });
            if (m.event === 'postgres_changes') { ws.close(); resolve(m.payload.data.type + ' ' + m.payload.data.table + ' ' + m.payload.data.record.text); }
          };
          setTimeout(() => resolve('timeout'), 5000);
        });
        """)
    check("REQ-015 Supabase Realtime pushes a REST insert to the joined channel", supabase == "INSERT messages Realtime", supabase)

    // Server-sent events.
    watchdog.reached("REQ-015 EventSource")
    let events = await text("""
        return await new Promise(resolve => {
          const source = new EventSource('/api/stream'); const log = ['state:' + source.readyState];
          source.onopen = () => log.push('open:' + source.readyState);
          source.addEventListener('hello', e => { log.push(e.data); source.close(); log.push('closed:' + source.readyState); resolve(log.join('|')); });
          setTimeout(() => resolve('timeout ' + log.join('|')), 5000);
        });
        """)
    check("REQ-015 a simulated EventSource opens and receives named events", events == #"state:0|open:1|{"ok":true}|closed:2"#, events)

    // GraphQL subscriptions over graphql-ws, fed by a mutation over HTTP.
    watchdog.reached("REQ-015 graphql-ws")
    let subscription = await text("""
        return await new Promise(resolve => {
          const ws = new WebSocket('ws://localhost:5173/graphql', 'graphql-transport-ws'); const log = [ws.protocol || 'none'];
          ws.onopen = () => { log.push(ws.protocol); ws.send(JSON.stringify({ type: 'connection_init' })); };
          ws.onmessage = e => {
            const m = JSON.parse(e.data); log.push(m.type);
            if (m.type === 'connection_ack') {
              ws.send(JSON.stringify({ id: '1', type: 'subscribe', payload: { query: 'subscription { postAdded { id title } }' } }));
              // The mutation follows once the subscription is registered.
              setTimeout(() => fetch('/graphql', { method: 'POST', headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ query: 'mutation($t: String!) { createPost(input: { title: $t }) { id } }', variables: { t: 'Third' } }) }), 300);
            }
            if (m.type === 'next') { log.push(m.payload.data.postAdded.title); ws.close(); resolve(log.join('|')); }
          };
          setTimeout(() => resolve('timeout ' + log.join('|')), 5000);
        });
        """)
    check("REQ-015 a graphql-ws subscription receives a mutation's record", subscription == "none|graphql-transport-ws|connection_ack|next|Third", subscription)

    // A Reset closes the page's connections with a close frame.
    let resetClose = await text("""
        window.__resetClose = new Promise(resolve => { const ws = new WebSocket('ws://localhost:5173/ws/chat');
          ws.onopen = () => resolve(new Promise(done => { ws.onclose = e => done(e.code + ' ' + e.reason); })); });
        return 'started';
        """)
    await harness.settle(0.3)
    harness.channelHub?.closeAll(source: "page", code: 1012, reason: "The simulated service was reset.")
    let closedByReset = await text("return await (await window.__resetClose);")
    check("REQ-015 a Reset closes the page's sockets with 1012", resetClose == "started" && closedByReset == "1012 The simulated service was reset.", closedByReset)
    check("REQ-015 channel messages pass the bridge's validation", harness.rejected.count == rejectedBefore,
          harness.rejected.dropFirst(rejectedBefore).joined(separator: "; "))
    check("REQ-015 opens, messages and closes are logged", harness.channelLog.contains { $0.contains("open · raw channel chat") }
          && harness.channelLog.contains { $0.contains("→") } && harness.channelLog.contains { $0.contains("closed") }, harness.channelLog.joined(separator: "\n"))

    harness.channelHub?.closeAll()
    harness.channelHub = nil
    harness.simulator = saved
    await harness.load(page)
    await harness.settle()
}

// MARK: - Electron preload bridge (REQ-016)

/// An Electron renderer's preload bridge in a real page: calls are requests to http://electron.ipc answered by the
/// simulation over the shared state, callbacks listen to simulated channels, and the encoding is the one the map and the
/// prompts describe.
@MainActor
func ipcChecks(_ harness: Harness) async {
    func text(_ script: String) async -> String { (await harness.js(script) as? String) ?? "nil" }
    func json(_ text: String) -> StudioJSON { StudioJSON(text: text) ?? .null }
    let saved = harness.simulator
    let base = StudioIPC.origin + "/strikedesk/settings/"
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "brokers", fields: [StudioField(name: "name", type: "string", required: true)])]
    spec.seed = ["brokers": [json(#"{"id":"b1","name":"Alpaca"}"#)]]
    func respond(_ id: String, _ method: String, _ path: String, _ status: Int, _ body: StudioJSON?) -> StudioRule {
        StudioRule(id: id, method: method, path: path, operation: .respond, response: StudioFixedResponse(status: status, body: body ?? .null))
    }
    spec.rules = [
        respond("get-document", "GET", base + "getDocument", 200, json(#"{"theme":"dark","revision":3}"#)),
        StudioRule(id: "get-brokers", method: "GET", path: base + "getBrokers", operation: .list, entity: "brokers"),
        StudioRule(id: "save-broker", method: "PUT", path: base + "saveBroker", operation: .create, entity: "brokers"),
        StudioRule(id: "delete-broker", method: "DELETE", path: base + "deleteBroker/:id", operation: .delete, entity: "brokers"),
        respond("explode", "POST", base + "explode", 500, json(#"{"error":"internal","message":"The gateway is down"}"#)),
        respond("test-connection", "POST", base + "testConnection/:id", 200, json(#"{"ok":true}"#)),
        respond("get-invoked", "GET", StudioIPC.origin + "/electron/ipcRenderer/invoke/settings:get-document", 200, json(#"{"via":"invoke"}"#)),
    ]
    spec.channels = [
        StudioChannel(id: "broker-saved", path: base + "onBrokerSaved", wire: .raw,
                      links: [StudioChannelLink(entity: "brokers", on: [.create], message: StudioChannelMessage(data: .string("{{record}}")))]),
        StudioChannel(id: "status", path: StudioIPC.origin + "/electron/ipcRenderer/on/order:status-update", wire: .raw,
                      onConnect: [StudioChannelMessage(data: json(#"{"status":"filled"}"#))]),
    ]
    harness.simulator = StudioSimulator(spec: spec, scenario: StudioScenario(id: "desk", name: "Desk", kind: .populated), appOrigin: harness.origin.text)
    harness.channelHub = harness.makeChannelHub()
    harness.ipcRequests = []
    let rejectedBefore = harness.rejected.count
    await harness.load("<!doctype html><html><head><meta charset=\"utf-8\"><title>Desk</title></head><body></body></html>",
                       electronGlobals: ["strikedesk", "electron"])
    await harness.settle(0.2)

    watchdog.reached("REQ-016 bridge calls are simulated requests")
    let document = await text("return JSON.stringify(await window.strikedesk.settings.getDocument());")
    check("REQ-016 a bridge call resolves to the simulated answer's JSON", document == #"{"revision":3,"theme":"dark"}"#, document)
    let listed = await text("""
        const saved = await window.strikedesk.settings.saveBroker({ id: 'b2', name: 'Paper' });
        const list = await window.strikedesk.settings.getBrokers();
        return saved.name + ' ' + list.map(b => b.name).join(',');
        """)
    check("REQ-016 a save writes the shared state, and a later get returns it", listed == "Paper Alpaca,Paper", listed)
    let deleted = await text("""
        const answer = await window.strikedesk.settings.deleteBroker('b2');
        return String(answer) + ' ' + (await window.strikedesk.settings.getBrokers()).length;
        """)
    check("REQ-016 a delete with an id argument removes the record; its empty answer is undefined", deleted == "undefined 1", deleted)
    let failed = await text("""
        try { await window.strikedesk.settings.explode(); return 'resolved'; }
        catch (error) { return (error instanceof Error) + ' ' + error.message; }
        """)
    check("REQ-016 an answer of 400 or more rejects with an Error that carries its message",
          failed == "true Error invoking remote method 'strikedesk.settings.explode': Error: The gateway is down", failed)
    let unknown = await text("""
        try { await window.strikedesk.brokers.reconnectAll(); return 'resolved'; } catch (error) { return error.message; }
        """)
    check("REQ-016 a call nothing answers rejects with the simulation's message", unknown.contains("no simulation rule"), unknown)
    let invoked = await text("return JSON.stringify(await window.electron.ipcRenderer.invoke('settings:get-document', { scope: 'all' }));")
    check("REQ-016 ipcRenderer.invoke goes to its channel's address, with the verb its channel gives", invoked == #"{"via":"invoke"}"#, invoked)

    watchdog.reached("REQ-016 the request convention")
    harness.ipcRequests = []
    let encoded = await text("""
        const s = window.strikedesk.settings;
        const calls = [s.getBroker('b1'), s.testConnection('paper/live'), s.saveDocument({ theme: 'light' }, 4),
          s.mergeThings({ a: 1 }, [2], 'tag'), s.saveNote('x'.repeat(300)), s.getOptional(undefined, null, '', true, 7),
          s.fetchAiModels({ provider: 'openai', apiKey: 'plain-key-value', nested: { password: 'hunter2' } })];
        await Promise.allSettled(calls);
        return 'done';
        """)
    let calls = harness.ipcRequests.map { "\($0.method) \($0.url.absoluteString)" }
    func request(_ suffix: String) -> StudioBridge.Request? { harness.ipcRequests.first { $0.url.absoluteString.hasSuffix(suffix) } }
    check("REQ-016 scalar arguments are path segments in order; a slash stays inside its segment",
          encoded == "done" && calls.contains("GET \(base)getBroker/b1") && calls.contains("POST \(base)testConnection/paper%252Flive")
          && calls.contains("GET \(base)getOptional/true/7") && request("getBroker/b1")?.body == nil, calls.joined(separator: " | "))
    check("REQ-016 one object is the JSON body, several are a JSON array, a long string is the body",
          request("saveDocument/4")?.method == "PUT" && request("saveDocument/4")?.body == #"{"theme":"light"}"#
          && request("saveDocument/4")?.headers["content-type"] == "application/json"
          && request("mergeThings/tag")?.body == #"[{"a":1},[2]]"# && request("saveNote")?.body == "\"" + String(repeating: "x", count: 300) + "\"",
          calls.joined(separator: " | "))
    let argsHeader = request("fetchAiModels")?.headers[StudioIPC.argumentsHeader] ?? ""
    check("REQ-016 the arguments header lists every argument, redacted in the page",
          request("saveDocument/4")?.headers[StudioIPC.argumentsHeader] == #"[{"theme":"light"},4]"#
          && argsHeader.contains("openai") && !argsHeader.contains("plain-key-value") && !argsHeader.contains("hunter2")
          && argsHeader.contains("[redacted]") && request("getOptional/true/7")?.headers[StudioIPC.argumentsHeader] == #"[null,null,"",true,7]"#,
          argsHeader)
    harness.ipcRequests = []
    _ = await text("try { await window.strikedesk.settings.saveBlob({ data: 'y'.repeat(9000) }); } catch (e) {} return 'done';")
    let bounded = harness.ipcRequests.first?.headers[StudioIPC.argumentsHeader] ?? ""
    check("REQ-016 the arguments header is at most 4 KB", bounded.utf8.count <= 4096 && bounded.hasSuffix("…") && bounded.hasPrefix(#"[{"data":"yyy"#),
          "\(bounded.utf8.count) bytes")
    let names = ["getDocument", "listBrokers", "isConnected", "issue", "getter", "deleteBroker", "removeItem", "clearCache", "updateBroker",
                 "patchOrder", "saveBroker", "setTheme", "resetDocument", "importSettings", "testConnection", "GetAll", "constructor", "_internal"]
    harness.ipcRequests = []
    let channelNames = ["settings:get-document", "order:submit", "brokers.delete_broker"]
    _ = await harness.js("""
        const v = window.strikedesk.verbs;
        await Promise.allSettled(names.map(name => v[name]()));
        await Promise.allSettled(channels.map(channel => window.electron.ipcRenderer.invoke(channel)));
        return 'done';
        """, ["names": names, "channels": channelNames])
    let pageVerbs = Dictionary(harness.ipcRequests.map { ($0.url.lastPathComponent, $0.method) }, uniquingKeysWith: { first, _ in first })
    let disagree = (names + channelNames).filter { pageVerbs[$0] != StudioIPC.verb(of: $0) }
    check("REQ-016 the page and the map choose the same verb for every method and channel",
          disagree.isEmpty && pageVerbs.count == names.count + channelNames.count,
          disagree.map { "\($0): page \(pageVerbs[$0] ?? "none"), map \(StudioIPC.verb(of: $0))" }.joined(separator: ", ") + " \(pageVerbs.keys.sorted())")

    watchdog.reached("REQ-016 callbacks listen to simulated channels")
    let subscribed = await text("""
        window.__brokers = [];
        const off = window.strikedesk.settings.onBrokerSaved(broker => window.__brokers.push(broker.name));
        window.__off = off;
        return typeof off;
        """)
    await harness.settle(0.3)
    let pushed = await text("""
        await window.strikedesk.settings.saveBroker({ id: 'b3', name: 'Tasty' });
        await new Promise(r => setTimeout(r, 500));
        window.__off();
        await window.strikedesk.settings.saveBroker({ id: 'b4', name: 'Schwab' });
        await new Promise(r => setTimeout(r, 500));
        return window.__brokers.join(',');
        """)
    check("REQ-016 a callback argument returns its unsubscribe function at once", subscribed == "function", subscribed)
    check("REQ-016 a callback gets what its channel pushes for a write, and nothing after it unsubscribes", pushed == "Tasty", pushed)
    let withEvent = await text("""
        return await new Promise(resolve => {
          window.electron.ipcRenderer.on('order:status-update', (event, data) => resolve(typeof event + ' ' + ('sender' in event) + ' ' + data.status));
          setTimeout(() => resolve('timeout'), 3000);
        });
        """)
    check("REQ-016 an ipcRenderer listener gets the event and the data, like Electron's", withEvent == "object true filled", withEvent)
    let errorMark = harness.events.count
    _ = await text("""
        window.electron.ipcRenderer.once('order:status-update', () => { window.strikedeskMissing.handler.run(); });
        return 'ok';
        """)
    await harness.settle(1.0)
    let thrown = harness.events.dropFirst(errorMark).filter { $0.kind == .runtimeError }.map(\.detail)
    check("REQ-016 an error a callback throws surfaces with its message", thrown.contains { $0.contains("strikedeskMissing") },
          thrown.joined(separator: " | "))
    let ipcOpens = Set(harness.channelMessages.filter { $0.action == .open && $0.transport == .ipc }.map(\.id))
    let opened = ipcOpens.count
    let closed = harness.channelMessages.filter { $0.action == .close && ipcOpens.contains($0.id) }.count
    check("REQ-016 callbacks open and close channels with the ipc transport; once closes itself", opened == 3 && closed == 2,
          "\(opened) opened, \(closed) closed")
    let waiting = await text("""
        const off = window.strikedesk.settings.onDocumentApplied(() => {});
        return typeof off + ' ' + typeof off();
        """)
    await harness.settle(0.3)
    check("REQ-016 a callback no channel answers waits without an error", waiting == "function undefined"
          && harness.channelLog.contains { $0.contains("onDocumentApplied · page · listening") }, harness.channelLog.suffix(4).joined(separator: "\n"))

    watchdog.reached("REQ-016 reads of the bridge stay harmless")
    let reads = await text("""
        const s = window.strikedesk.settings;
        const awaited = await s;
        return [awaited === s, s === window.strikedesk.settings, String(window.strikedesk.platform), typeof s.getDocument,
          JSON.stringify({ v: window.strikedesk.versions }), [...window.strikedesk.list].length].join(' ');
        """)
    check("REQ-016 reading a property gives the bridge below it: awaitable, stable, empty as text", reads == "true true  function {} 0", reads)
    let eventsMark = harness.events.count
    let sync = await text("return String(window.electron.ipcRenderer.sendSync('settings:get-sync'));")
    await harness.settle(0.3)
    check("REQ-016 sendSync answers undefined at once and is reported", sync == "undefined"
          && harness.events.dropFirst(eventsMark).contains { $0.kind == .electron && $0.detail.contains("sendSync(\"settings:get-sync\")") }, sync)
    check("REQ-016 the bridge's messages pass validation", harness.rejected.count == rejectedBefore,
          harness.rejected.dropFirst(rejectedBefore).joined(separator: "; "))

    harness.channelHub?.closeAll()
    harness.channelHub = nil
    harness.simulator = saved
    await harness.load(page)
    await harness.settle()
}
