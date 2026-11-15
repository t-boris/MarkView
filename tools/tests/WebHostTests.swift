import AppKit
import WebKit

// AR-27 in real WebKit (hidden window, no page of the app): what WebHost.makeConfiguration and WebHost.makeWebView give a host.
//   - the settings a host names (data store, JavaScript, popups, user agent, inspector) are what the page then sees;
//   - handlers are registered weakly: a host whose handler owns its web view is released with it, which the same host
//     registered the way WebKit's own `add(_:name:)` does is not (the control proves the test would notice a cycle);
//   - a handler delivers in its content world only, a handler with a reply answers and, once its host is gone, rejects;
//   - user scripts run in the order given and a scheme handler serves its scheme.
// Run through tools/tests/web-host-tests.sh (argument 1: "debug" when the sources are compiled with -DDEBUG, else "release").
setvbuf(stdout, nil, _IONBF, 0)
let debugBuild = CommandLine.arguments[1] == "debug"
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(500)))")
}
DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
    print("TIMEOUT: no result after 90 s")
    exit(1)
}
NSApplication.shared.setActivationPolicy(.prohibited)

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

/// A web view in a hidden window that has loaded `html` (base `https://host.test/`, so that a page has an origin).
@MainActor func load(_ html: String, configuration: WKWebViewConfiguration, baseURL: URL? = URL(string: "https://host.test/")) -> (WKWebView, NSWindow) {
    let web = WebHost.makeWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.isReleasedWhenClosed = false
    window.contentView = web
    let loaded = Loaded()
    web.navigationDelegate = loaded
    web.loadHTMLString(html, baseURL: baseURL)
    spin(20) { loaded.done }
    web.navigationDelegate = nil
    check(loaded.done, "a page loaded")
    return (web, window)
}

@MainActor func evaluate(_ web: WKWebView, _ script: String) -> Any? {
    var out: Any?
    var finished = false
    web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
        if case .success(let value) = result { out = value } else { out = "JSERROR" }
        finished = true
    }
    spin(15) { finished }
    return out
}

// MARK: - Settings

@MainActor func settingsChecks() {
    let plain = WebHost.makeConfiguration()
    check(plain.websiteDataStore.isPersistent, "the default data store is WebKit's persistent one")
    check(plain.websiteDataStore === WKWebsiteDataStore.default(), "and it is the shared default store (the browser tabs' common sign-in)")
    check(plain.defaultWebpagePreferences.allowsContentJavaScript, "JavaScript is on by default")
    check(!plain.preferences.javaScriptCanOpenWindowsAutomatically, "a page cannot open windows by itself by default")
    check(!plain.preferences.isElementFullscreenEnabled, "element full screen is off by default")
    check(plain.userContentController.userScripts.isEmpty, "a plain configuration has no user script")

    let isolated = WebHost.makeConfiguration(dataStore: .nonPersistent)
    check(!isolated.websiteDataStore.isPersistent, ".nonPersistent leaves nothing on disk")
    check(isolated.websiteDataStore !== WebHost.makeConfiguration(dataStore: .nonPersistent).websiteDataStore, "and each one has a store of its own")

    let mine = WKWebsiteDataStore.nonPersistent()
    check(WebHost.makeConfiguration(dataStore: .store(mine)).websiteDataStore === mine, ".store uses the caller's store as is (a QA player's own)")

    let browser = WebHost.makeConfiguration(allowsPopups: true, allowsElementFullscreen: true, applicationName: "Version/17.0 Safari/605.1.15")
    check(browser.preferences.javaScriptCanOpenWindowsAutomatically && browser.preferences.isElementFullscreenEnabled, "a browser tab can open popups and go full screen")
    check(browser.applicationNameForUserAgent == "Version/17.0 Safari/605.1.15", "and names itself in the user agent")

    let off = WebHost.makeConfiguration(allowsJavaScript: false)
    check(!off.defaultWebpagePreferences.allowsContentJavaScript, "a preview can turn the page's JavaScript off")

    let (web, window) = load("<html><body><script>document.body.setAttribute('data-ran', 'yes')</script></body></html>", configuration: off)
    check(evaluate(web, "return document.body.getAttribute('data-ran') || 'no'") as? String == "no", "and the page's script does not run")
    window.contentView = nil

    let (agent, agentWindow) = load("<html><body></body></html>", configuration: browser)
    check((evaluate(agent, "return navigator.userAgent") as? String)?.hasSuffix("Version/17.0 Safari/605.1.15") == true, "the user agent the page sees ends with the name")
    if #available(macOS 13.3, *) {
        check(agent.isInspectable == debugBuild, "the web view is inspectable in a Debug build only (this one: \(debugBuild ? "Debug" : "Release"))", "\(agent.isInspectable)")
    }
    agentWindow.contentView = nil
}

// MARK: - User scripts and a scheme handler

final class Scheme: NSObject, WKURLSchemeHandler {
    var served: [String] = []
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        served.append(task.request.url?.path ?? "")
        let body = Data("<html><head><title>from the scheme</title></head><body>ok</body></html>".utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8"))
        task.didReceive(body)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor func schemeChecks() {
    func script(_ code: String, _ time: WKUserScriptInjectionTime = .atDocumentStart) -> WKUserScript {
        WKUserScript(source: code, injectionTime: time, forMainFrameOnly: true)
    }
    let scheme = Scheme()
    let configuration = WebHost.makeConfiguration(
        userScripts: [script("window.__order = ['first'];"), script("window.__order.push('second');"), script("window.__order.push('end');", .atDocumentEnd)],
        urlSchemeHandlers: [("host-test", scheme)])
    let web = WebHost.makeWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.contentView = web
    let loaded = Loaded()
    web.navigationDelegate = loaded
    web.load(URLRequest(url: URL(string: "host-test:///page.html")!))
    spin(20) { loaded.done }
    let title = evaluate(web, "return document.title") as? String
    check(loaded.done && title == "from the scheme", "a page of a scheme the host registered loads through its handler", "\(loaded.done) \(title ?? "nil")")
    check(scheme.served == ["/page.html"], "and the handler served exactly that request", "\(scheme.served)")
    check(evaluate(web, "return JSON.stringify(window.__order)") as? String == "[\"first\",\"second\",\"end\"]", "user scripts run in the order given")
    window.contentView = nil
}

// MARK: - Handlers deliver in their world, with a reply, and weakly

final class Recorder: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    var received: [(name: String, body: String, isClient: Bool)] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        received.append((message.name, "\(message.body)", message.world != .page))
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        replyHandler("pong:\(message.body)", nil)
    }
}

@MainActor func handlerChecks() {
    let recorder = Recorder()
    let client = Recorder()
    let replies = Recorder()
    let configuration = WebHost.makeConfiguration(
        handlers: [.message("alpha", recorder), .message("beta", client, in: .defaultClient), .reply("gamma", replies)],
        userScripts: [WKUserScript(source: "window.webkit.messageHandlers.beta.postMessage('from the client world')",
                                   injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)])
    let (web, window) = load("<html><body></body></html>", configuration: configuration)
    _ = evaluate(web, "window.webkit.messageHandlers.alpha.postMessage('hello'); return 'sent'")
    spin(10) { !recorder.received.isEmpty && !client.received.isEmpty }
    check(recorder.received.count == 1 && recorder.received[0].name == "alpha" && recorder.received[0].body == "hello" && !recorder.received[0].isClient,
          "a message handler receives the page's message in the page world", "\(recorder.received)")
    check(client.received.count == 1 && client.received[0].body == "from the client world" && client.received[0].isClient,
          "a handler of the client world receives the client world's message", "\(client.received)")
    check(evaluate(web, "return String(window.webkit.messageHandlers.beta)") as? String == "undefined", "and the page world has no such handler")
    check(evaluate(web, "return await window.webkit.messageHandlers.gamma.postMessage('ping')") as? String == "pong:ping", "a handler with a reply answers the page's promise")

    // The host is gone: the page's promise is rejected with a reason, not left waiting.
    var gone: Recorder? = Recorder()
    let configuration2 = WebHost.makeConfiguration(handlers: [.reply("gamma", gone!)])
    let (web2, window2) = load("<html><body></body></html>", configuration: configuration2)
    gone = nil
    check(evaluate(web2, "try { return await window.webkit.messageHandlers.gamma.postMessage('ping') } catch (e) { return 'rejected: ' + e.message }") as? String
          == "rejected: The page's host is closed.", "a handler with a reply whose host is gone rejects the page's promise")
    window.contentView = nil
    window2.contentView = nil
}

// MARK: - A host that owns its web view is released with it

/// A coordinator as the app has them: it is the page's message handler and keeps its web view (a cycle through the content controller
/// if the controller retains it).
final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    var web: WKWebView?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) { replyHandler(nil, nil) }
}

func gone(_ weakRefs: [() -> AnyObject?], within seconds: TimeInterval = 8) -> Bool {
    spin(seconds) { weakRefs.allSatisfy { $0() == nil } }
    return weakRefs.allSatisfy { $0() == nil }
}

@MainActor func releaseTest(_ name: String, register: (Coordinator) -> WKWebViewConfiguration, expectReleased: Bool) {
    weak var weakCoordinator: Coordinator?
    weak var weakWeb: WKWebView?
    autoreleasepool {
        let coordinator = Coordinator()
        weakCoordinator = coordinator
        let (web, window) = load("<html><body>page</body></html>", configuration: register(coordinator))
        coordinator.web = web
        weakWeb = web
        window.contentView = nil
    }
    let released = gone([{ weakCoordinator }, { weakWeb }], within: expectReleased ? 10 : 3)
    check(released == expectReleased, name, "coordinator alive: \(weakCoordinator != nil), web view alive: \(weakWeb != nil)")
    if !released {
        // The control only: break the cycle by hand so the process ends clean.
        weakWeb?.configuration.userContentController.removeAllScriptMessageHandlers()
        weakCoordinator?.web = nil
    }
}

@MainActor func releaseChecks() {
releaseTest("through WebHost a message handler that owns its web view is released with it",
            register: { WebHost.makeConfiguration(handlers: [.message("host", $0)]) }, expectReleased: true)
releaseTest("through WebHost a handler with a reply that owns its web view is released with it",
            register: { WebHost.makeConfiguration(handlers: [.reply("host", $0)]) }, expectReleased: true)
releaseTest("through WebHost the same handler in the client world is released with its web view",
            register: { WebHost.makeConfiguration(handlers: [.message("host", $0, in: .defaultClient)]) }, expectReleased: true)
releaseTest("control: the same host registered with WebKit's own add(_:name:) is NOT released (the cycle the factory prevents)",
            register: { coordinator in
                let configuration = WKWebViewConfiguration()
                configuration.userContentController.add(coordinator, name: "host")
                return configuration
            }, expectReleased: false)
}

MainActor.assumeIsolated {
    settingsChecks()
    schemeChecks()
    handlerChecks()
    releaseChecks()
}
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
