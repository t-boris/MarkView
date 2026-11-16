import AppKit
import WebKit

// FU-26: the editor page's Content-Security-Policy takes a per-load nonce through EditorPage (the function EditorView calls), and
// the Insight view depends on it: a srcdoc frame inherits the page's policy, so its inline scripts run only when the page's
// script-src carries the nonce too. What is checked, in real WebKit with a hidden window and the shipped index.html:
//   - the page text EditorPage.prepare returns differs from index.html by the nonce token in script-src and by nothing else, and
//     WebKit reads that policy with the nonce, 'self' and 'wasm-unsafe-eval';
//   - the page loads the way the app loads it (loadHTMLString with the editor folder behind its base URL, the window's own preferences and
//     the nonce as user scripts): the page's scripts run, the preferences script answers from the window's own values and reports a
//     save, the nonce reaches the page, and the Insight frame built by the page's own buildInsightSrcdoc runs its scripts (it
//     reports that it is ready) while an inline script without the nonce does not run;
//   - the miss that used to be silent: the same page without the nonce in its policy leaves the frame inert;
//   - a page whose policy cannot take the nonce (no policy, no script-src, a changed directive) gets no nonce at all: prepare
//     returns the page untouched and nil, so the app installs no nonce script and the page builds the frame with script-src 'none'.
// Run through tools/tests/editor-page-csp-tests.sh.
setvbuf(stdout, nil, _IONBF, 0)
let editor = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath + "/MarkView/Resources/Editor"
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(900)))")
}
// A hung page must not hang the test run.
DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
    print("TIMEOUT: no result after 180 s")
    exit(1)
}

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class Bridge: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}
final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

/// Serves the editor folder to the page under a custom scheme. The app loads the page text with `loadHTMLString` and the bundle
/// folder as its base, and the web content process may read the bundle but not an arbitrary folder, so a test (which runs from a
/// work folder) gives the page the same shape through a scheme handler instead: the page text still arrives as a string, every
/// other file is read from the editor folder.
final class EditorFolder: NSObject, WKURLSchemeHandler {
    static let scheme = "mvtest"
    static let base = URL(string: "mvtest://editor/")!
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "editor",
              let data = FileManager.default.contents(atPath: editor + url.path), !url.path.contains("..") else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let types = ["js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "html": "text/html", "json": "application/json",
                     "wasm": "application/wasm", "woff2": "font/woff2", "svg": "image/svg+xml", "png": "image/png"]
        let mime = types[url.pathExtension] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// The editor page loaded the way EditorView.loadEditorPage loads it: page text with a base URL, then the preferences script and
/// (when the page took one) the nonce script at document start.
@MainActor final class Page {
    let web: WKWebView
    let window: NSWindow
    let bridge = Bridge()
    let loaded = Loaded()
    let folder = EditorFolder()
    init(html: String, nonce: String?, own: [String: String] = [:]) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(folder, forURLScheme: EditorFolder.scheme)
        config.userContentController.add(bridge, name: "bridge")
        config.userContentController.addUserScript(try! BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)  // the page gets the bridge contract from the app (AR-28)
        config.userContentController.addUserScript(WKUserScript(source: EditorWindowPrefs.script(values: own), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let nonce {
            config.userContentController.addUserScript(WKUserScript(source: EditorPage.nonceScript(nonce), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = web
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: EditorFolder.base)
        spin(30) { loaded.done }
        spin(1.5)
    }
    func js(_ body: String, timeout: TimeInterval = 60) -> String {
        var out: String?
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): out = value as? String ?? "\(String(describing: value))"
            case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
            }
        }
        spin(timeout) { out != nil }
        return out ?? "TIMEOUT"
    }
}

MainActor.assumeIsolated {
_ = NSApplication.shared
NSApplication.shared.setActivationPolicy(.prohibited)
guard let original = try? String(contentsOfFile: editor + "/index.html", encoding: .utf8) else {
    check(false, "index.html can be read")
    exit(1)
}

// 1. The real function on the shipped page text.
let prepared = EditorPage.prepare(original)
check(prepared.nonce != nil, "EditorPage.prepare gives the shipped index.html a nonce")
let nonce = prepared.nonce ?? ""
check(prepared.html != original && prepared.html.replacingOccurrences(of: " 'nonce-\(nonce)'", with: "") == original,
      "the prepared page differs from index.html by the nonce token and by nothing else")

// 2. The page under that policy, loaded the way the app loads it.
let page = Page(html: prepared.html, nonce: prepared.nonce, own: ["markview-font-size": "17"])
check(page.js("return String(typeof window.setContent === 'function' && typeof window.buildInsightSrcdoc === 'function');") == "true",
      "the page's own scripts run under the prepared policy")
let policy = page.js("return document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content;")
let scriptSrc = policy.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("script-src") } ?? ""
check(scriptSrc == "script-src 'self' 'wasm-unsafe-eval' 'nonce-\(nonce)'", "WebKit reads script-src with 'self', 'wasm-unsafe-eval' and the nonce", scriptSrc)
check(page.js("return String(window.__markviewInsightNonce);") == nonce, "the page is told the same nonce")
check(page.js("return String(localStorage.getItem('markview-font-size'));") == "17", "the preferences script answers from the window's own value")
_ = page.js("localStorage.setItem('markview-font-size', 19); return 'ok';")
spin(0.5)
check(page.bridge.messages.contains { ($0["type"] as? String) == "editorWindowPref" && (($0["payload"] as? [String: Any])?["value"] as? String) == "19" },
      "and reports a save to the app through the bridge")

let frameProbe = #"""
    window.__frameMessages = [];
    window.addEventListener('message', ev => { if (ev.data && ev.data.type) window.__frameMessages.push(ev.data.type); if (ev.data && ev.data.evil) window.__frameMessages.push('evil'); });
    window.__inlineRan = false;
    const inline = document.createElement('script');
    inline.textContent = 'window.__inlineRan = true;';
    document.body.appendChild(inline);
    let srcdoc = await window.buildInsightSrcdoc({ title: 'T', sections: [] }, '');
    srcdoc = srcdoc.replace('</body>', '<script>parent.postMessage({ evil: true }, "*")</script></body>');
    const frame = document.createElement('iframe');
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.srcdoc = srcdoc;
    document.body.appendChild(frame);
    for (let i = 0; i < 40 && window.__frameMessages.indexOf('insightIframeReady') < 0; i++) await new Promise(r => setTimeout(r, 100));
    await new Promise(r => setTimeout(r, 400));
    return JSON.stringify({ ready: window.__frameMessages.indexOf('insightIframeReady') >= 0, evil: window.__frameMessages.indexOf('evil') >= 0, inline: window.__inlineRan,
        csp: (srcdoc.replace(/&#39;/g, "'").match(/script-src [^;"]+/) || [''])[0] });
    """#
func decode(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}
let withNonce = decode(page.js(frameProbe))
check(withNonce["ready"] as? Bool == true, "the Insight frame built by the page runs its nonce-gated script under the page's policy", "\(withNonce)")
check(withNonce["evil"] as? Bool == false && withNonce["inline"] as? Bool == false, "while a script without the nonce, in the page or in the frame, does not run", "\(withNonce)")
check((withNonce["csp"] as? String) == "script-src 'nonce-\(nonce)'", "and the frame asks for the same nonce", "\(withNonce)")

// 3. The miss that used to be silent: the page keeps its original policy but is told a nonce.
let missed = Page(html: original, nonce: nonce, own: [:])
let withoutPolicy = decode(missed.js(frameProbe, timeout: 60))
check(withoutPolicy["ready"] as? Bool == false, "a page whose policy lacks the nonce leaves the Insight frame inert (the failure EditorPage.prepare now reports)", "\(withoutPolicy)")

// 4. Pages whose policy cannot take the nonce fail closed.
let noScriptSrc = original.replacingOccurrences(of: "script-src 'self' 'wasm-unsafe-eval'; ", with: "")
let renamed = original.replacingOccurrences(of: "script-src ", with: "script-src-elem ")
let noPolicy = original.replacingOccurrences(of: "http-equiv=\"Content-Security-Policy\"", with: "http-equiv=\"refresh\"")
check(noScriptSrc != original && renamed != original && noPolicy != original, "the three broken pages differ from index.html")
for (name, broken) in [("no script-src", noScriptSrc), ("a renamed directive", renamed), ("no policy element", noPolicy)] {
    let result = EditorPage.prepare(broken)
    check(result.nonce == nil && result.html == broken, "a page with \(name) is loaded untouched and with no nonce", result.html.prefix(120).description)
}
check(EditorPage.injectNonce("bad nonce\"", into: original) == nil, "a nonce that is not a plain token is refused")
check(EditorPage.injectNonce(nonce, into: original) != nil, "and the same page takes a plain one")

let failClosed = Page(html: noScriptSrc, nonce: EditorPage.prepare(noScriptSrc).nonce, own: [:])
let closed = failClosed.js("""
    const srcdoc = await window.buildInsightSrcdoc({ title: 'T', sections: [] }, '');
    return JSON.stringify({ nonce: String(window.__markviewInsightNonce), csp: (srcdoc.replace(/&#39;/g, "'").match(/script-src [^;"]+/) || [''])[0] });
    """)
check(decode(closed)["nonce"] as? String == "undefined" && decode(closed)["csp"] as? String == "script-src 'none'",
      "a page that took no nonce builds the Insight frame with script-src 'none'", closed)

print(failures == 0 ? "All editor page policy checks passed" : "\(failures) editor page policy check(s) failed")
exit(failures == 0 ? 0 : 1)

}
