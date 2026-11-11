import AppKit
import WebKit

// End-to-End QA (feature end-to-end-qa, DEC-001, DEC-003, DEC-012): one player of a scenario in MarkView's own browser. Every player has a
// browser tab of its own with a cookie store of its own, so two players never share a sign-in. The tab sits in a window kept off every
// screen: the run view shows the player's pictures, and the page still gets real mouse and keyboard input, which needs a window.
// Everything the player does goes through the same page tools the agents' browser uses (`BrowserAgentExecutor`).

enum QAWebError: Error, LocalizedError {
    case failed(String)
    case outsideApp(String)
    case badAddress(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .outsideApp(let address): return "A request may only go to the application under test, not to \(address)."
        case .badAddress(let address): return "\(address) is not an address."
        }
    }
}

@MainActor
final class QAWebActor: QAActorDriver {
    static let viewport = NSSize(width: 1280, height: 800)

    let request: QADriverRequest
    let session: BrowserSession
    private let window: NSWindow
    private let origin: URL?
    private let credentials: QACredentials
    private var rules: [QAFault] = []
    private let faultHandler = QAFaultHandler()
    private var closed = false

    /// `credentials` are read by the factory off the main thread (a Keychain read can wait for the system), and go no further than this
    /// player: the assistant writes {{password}} and the real value goes straight into the field.
    init(request: QADriverRequest, credentials: QACredentials) {
        self.request = request
        origin = URL(string: request.address)
        session = BrowserSession(url: nil, dataStore: .nonPersistent())
        self.credentials = credentials
        let size = Self.viewport
        window = QAWebWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let web = session.webView
        web.frame = NSRect(origin: .zero, size: size)
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        window.orderBack(nil)
        faultHandler.owner = self
        web.configuration.userContentController.add(faultHandler, contentWorld: .page, name: QAFaultHandler.name)
    }

    // MARK: QAActorDriver

    func open(_ address: String) async throws {
        try await tool("browser_navigate", ["url": address])
    }

    func observe() async throws -> QAObservation {
        let text = try await tool("browser_snapshot", [:])
        var address = "", title = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(5) {
            if line.hasPrefix("URL: ") { address = String(line.dropFirst(5)) }
            if line.hasPrefix("Title: ") { title = String(line.dropFirst(7)) }
        }
        return QAObservation(address: address, title: title, snapshot: scrub(text))
    }

    func perform(_ action: QAAction) async throws -> String {
        switch action.kind {
        case .click:
            return scrub(try await tool("browser_click", ["ref": try reference(action)]))
        case .fill:
            let value = credentials.fill(action.text)
            if let missing = credentials.unfilled(action.text).first {
                throw QAWebError.failed("This player has no saved sign-in, so \(missing) cannot be filled in. Type what the step itself says, or answer blocked: the person has to choose a login for this player in Setup.")
            }
            return scrub(try await tool("browser_type", ["ref": try reference(action), "value": value]))
        case .select:
            let ref = try reference(action)
            return scrub(try await tool("browser_evaluate", ["script": Self.selectScript(ref: ref, option: action.text)]))
        case .scroll:
            let sign = action.direction.lowercased() == "up" ? "-" : ""
            return try await tool("browser_evaluate", ["script": "window.scrollBy(0, \(sign)Math.round(window.innerHeight * 0.8)); return 'scrolled';"])
        case .navigate:
            return scrub(try await tool("browser_navigate", ["url": try resolved(action.url).absoluteString]))
        case .key:
            return try await tool("browser_press_key", ["key": action.text])
        case .wait:
            return try await tool("browser_wait_for", ["timeout_ms": action.amount])
        case .http:
            return scrub(try await send(action))
        }
    }

    func screenshot() async -> Data? {
        let reply = await BrowserAgentExecutor.run("browser_screenshot", [:], in: session)
        return reply.isError ? nil : reply.pngBase64.flatMap { Data(base64Encoded: $0) }
    }

    func inputMark(for action: QAAction) async -> QAInputMark {
        var mark = QAInputMark(kind: action.kind, direction: action.direction)
        guard !closed else { return mark }
        let ref = action.ref.range(of: "^e[0-9]{1,6}$", options: .regularExpression) != nil ? action.ref : ""
        let usesTarget = [.click, .fill, .select].contains(action.kind)
        let script = """
        const el = \(usesTarget ? "document.querySelector('[data-mv-ref=\"\(ref)\"]')" : action.kind == .key ? "document.activeElement" : "null");
        if (!el || el === document.body || el === document.documentElement) return null;
        const parents = []; for (let p = el.parentElement; p; p = p.parentElement) parents.push([p, p.scrollTop, p.scrollLeft]);
        const before = el.getBoundingClientRect();
        \(usesTarget ? "el.scrollIntoView({block:'center',inline:'center',behavior:'instant'});" : "")
        const r = el.getBoundingClientRect();
        return {x:r.x,y:r.y,width:r.width,height:r.height,vw:innerWidth,vh:innerHeight,
          scroll:parents.some(([p,y,x])=>p.scrollTop!==y||p.scrollLeft!==x) ? (before.y > r.y ? 'down' : 'up') : null};
        """
        guard let value = try? await session.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page),
              let rect = value as? [String: Any], let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let width = rect["width"] as? Double, let height = rect["height"] as? Double,
              let vw = rect["vw"] as? Double, let vh = rect["vh"] as? Double else { return mark }
        mark.target = QAInputMark.normalized(CGRect(x: x, y: y, width: width, height: height), in: CGRect(x: 0, y: 0, width: vw, height: vh))
        mark.automaticScroll = rect["scroll"] as? String
        return mark
    }

    func arm(_ fault: QAFault) async throws {
        rules.append(fault)
        // Each arming adds a script that carries every rule so far; they run in order, so the last list wins and the wrapper is installed once.
        let source = Self.faultScript(rules)
        let controller = session.webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // The page that is open already meets the fault too.
        _ = try? await session.webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    func faultHits() async -> Int { hits }

    /// The page measured for the review. The script only reads layout and styles, never what a person typed.
    func measure() async -> QAPageEvidence? {
        guard !closed else { return nil }
        let value = try? await session.webView.evaluateJavaScript(QAPageEvidence.script)
        return QAPageEvidence.parse(value)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        let web = session.webView
        web.navigationDelegate = nil
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: QAFaultHandler.name, contentWorld: .page)
        window.contentView = nil
        window.close()
    }

    // MARK: Placeholders, credentials

    /// Nothing that comes back from the page or from a request may carry the password to the assistant, the run record or a log.
    private func scrub(_ text: String) -> String { credentials.scrub(text) }

    // MARK: Tools

    @discardableResult
    private func tool(_ name: String, _ arguments: [String: Any]) async throws -> String {
        if closed { throw CancellationError() }
        let reply = await BrowserAgentExecutor.run(name, arguments, in: session)
        if reply.isError { throw QAWebError.failed(scrub(reply.text)) }
        return reply.text
    }

    private func reference(_ action: QAAction) throws -> String {
        let ref = action.ref
        // A reference is `e` and a number; anything else would be script in a selector.
        guard ref.range(of: "^e[0-9]{1,6}$", options: .regularExpression) != nil else { throw QAWebError.failed("\"\(ref)\" is not an element of the page.") }
        return ref
    }

    private static func selectScript(ref: String, option: String) -> String {
        let wanted = literal(option)
        return """
        const el = document.querySelector('[data-mv-ref="\(ref)"]');
        if (!el) throw new Error('The element is not on the page any more.');
        if (el.tagName !== 'SELECT') throw new Error('The element is not a list of choices.');
        const wanted = \(wanted).trim().toLowerCase();
        const options = [...el.options];
        const option = options.find(o => o.text.trim().toLowerCase() === wanted || o.value.toLowerCase() === wanted)
          || options.find(o => o.text.trim().toLowerCase().includes(wanted));
        if (!option) throw new Error('There is no such choice. The choices are: ' + options.map(o => o.text.trim()).join(', '));
        el.value = option.value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return 'Chose ' + option.text.trim();
        """
    }

    private static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    // MARK: Requests of the runner's own (preparation only)

    /// An address inside the application under test: relative to it, or absolute on the same scheme, host and port.
    private func resolved(_ address: String) throws -> URL {
        guard let origin else { throw QAWebError.badAddress(request.address) }
        guard let url = URL(string: address, relativeTo: origin)?.absoluteURL else { throw QAWebError.badAddress(address) }
        guard url.scheme == origin.scheme, url.host == origin.host, (url.port ?? Self.defaultPort(url)) == (origin.port ?? Self.defaultPort(origin)) else {
            throw QAWebError.outsideApp(url.absoluteString)
        }
        return url
    }

    private static func defaultPort(_ url: URL) -> Int { url.scheme == "https" ? 443 : 80 }

    private func send(_ action: QAAction) async throws -> String {
        let url = try resolved(action.url)
        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        urlRequest.httpMethod = action.method.isEmpty ? "GET" : action.method
        if !action.text.isEmpty {
            urlRequest.httpBody = Data(action.text.utf8)
            let first = action.text.trimmingCharacters(in: .whitespacesAndNewlines).first
            urlRequest.setValue(first == "{" || first == "[" ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(600), as: UTF8.self)
        return "HTTP \(status)" + (body.isEmpty ? "" : ": " + body)
    }

    // MARK: Faults

    fileprivate var hits = 0

    /// Wraps `fetch` and `XMLHttpRequest` in the page: a request whose address holds a rule's pattern is delayed, fails, or gets the
    /// status of the rule. Every such request is counted, so a fault that was never met is told apart from one that held.
    static func faultScript(_ faults: [QAFault]) -> String {
        let list = faults.map { fault -> [String: Any] in
            var object: [String: Any] = ["pattern": fault.urlPattern, "mode": fault.mode.rawValue]
            object["status"] = fault.status ?? 500
            object["ms"] = fault.milliseconds ?? 0
            return object
        }
        let json = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function () {
          window.__qaRules = \(json);
          if (window.__qaInstalled) return;
          window.__qaInstalled = true;
          function rule(url) {
            var text = String(url);
            for (var i = 0; i < window.__qaRules.length; i++) { if (text.indexOf(window.__qaRules[i].pattern) >= 0) return window.__qaRules[i]; }
            return null;
          }
          function hit(r) { try { window.webkit.messageHandlers.\(QAFaultHandler.name).postMessage(r.pattern); } catch (e) {} }
          var realFetch = window.fetch;
          if (realFetch) {
            window.fetch = function (input, init) {
              var url = typeof input === 'string' ? input : (input && input.url) || String(input);
              var r = rule(url), self = this, args = arguments;
              if (!r) return realFetch.apply(self, args);
              hit(r);
              if (r.mode === 'delay') return new Promise(function (go) { setTimeout(go, r.ms); }).then(function () { return realFetch.apply(self, args); });
              if (r.mode === 'fail') return Promise.reject(new TypeError('Failed to fetch'));
              return Promise.resolve(new Response('', { status: r.status }));
            };
          }
          var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (method, url) { this.__qaUrl = url; return open.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function () {
            var r = rule(this.__qaUrl || ''), self = this, args = arguments;
            if (!r) return send.apply(self, args);
            hit(r);
            if (r.mode === 'delay') { setTimeout(function () { send.apply(self, args); }, r.ms); return; }
            setTimeout(function () {
              if (r.mode === 'status') {
                Object.defineProperty(self, 'readyState', { value: 4 });
                Object.defineProperty(self, 'status', { value: r.status });
                Object.defineProperty(self, 'responseText', { value: '' });
                self.dispatchEvent(new Event('readystatechange'));
                self.dispatchEvent(new ProgressEvent('load'));
              } else {
                self.dispatchEvent(new ProgressEvent('error'));
              }
              self.dispatchEvent(new ProgressEvent('loadend'));
            }, 0);
          };
        })();
        """
    }
}

/// Receives the page's report that a fault was met.
private final class QAFaultHandler: NSObject, WKScriptMessageHandler {
    static let name = "qaFault"
    weak var owner: QAWebActor?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { owner?.hits += 1 }
    }
}

/// Makes one browser player for every actor (and one for the session that prepares data).
@MainActor
final class QAWebDriverFactory: QADriverFactory {
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        var credentials = QACredentials(username: request.login?.username, password: nil)
        if let login = request.login {
            // The Keychain answers over a system service and may wait for the person: never on the main thread.
            credentials.password = await Task.detached(priority: .userInitiated) {
                BrowserPasswordStore.shared.password(host: login.host, username: login.username)
            }.value
        }
        return QAWebActor(request: request, credentials: credentials)
    }
}
