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

    func load(_ html: String, seed: Int = 7) async {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        // Stands in for the network under the runtime's own fetch, for requests the runtime passes through (BUG-070).
        controller.addUserScript(WKUserScript(source: """
            (function () { var real = window.fetch; window.__passed = [];
              window.fetch = function (input, init) { var r = new Request(input, init);
                if (r.url.indexOf('/__framework') < 0) return real.apply(this, arguments);
                window.__passed.push((r.headers.get('cache-control') || '') + '|' + (r.headers.get('rsc') || ''));
                return Promise.resolve(new Response('payload', { status: 200 })); }; })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let config = "{\"session\":\"\(token)\",\"generation\":\(simulator.generation),\"seed\":\(seed),\"testTime\":1767225600000,"
            + "\"locale\":\"de-DE\",\"timeZone\":\"Europe/Berlin\",\"electron\":false,\"electronGlobals\":[]}"
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
        case .success(.request(let request)):
            let http = StudioHTTPRequest(method: request.method, url: request.url, headers: request.headers, body: request.body,
                                         requestId: request.requestId)
            if request.url.path == "/__framework" {
                return replyHandler(StudioBridge.passThrough(adding: ["cache-control": "no-cache"]), nil)
            }
            if case .respond(let response, _) = simulator.handle(http) {
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

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
application.run()
