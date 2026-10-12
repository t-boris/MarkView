import AppKit
import WebKit

// Drives a page that opens a sign-in style popup: the popup must keep window.opener, post a
// message back and close itself with window.close().
@MainActor
final class Host: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var popup: BrowserPopup?
    var closed = false
    var received: String?
    var openResult: String?

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures f: WKWindowFeatures) -> WKWebView? {
        guard BrowserPopup.isPopup(f) else { return nil }
        let p = BrowserPopup(configuration: c, features: f)
        p.onClose = { [weak self] _ in self?.closed = true }
        popup = p
        return p.webView
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        w.evaluateJavaScript("""
        window.addEventListener('message', e => window.webkit.messageHandlers.t.postMessage('msg:' + e.data));
        var p = window.open('about:blank', 'auth', 'width=500,height=600');
        if (p) { p.document.write('<script>window.opener.postMessage("signed-in", "*"); window.close();<\\/script>'); p.document.close(); }
        String(p !== null)
        """) { r, _ in self.openResult = r as? String }
    }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { received = m.body as? String }
}

@MainActor func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { exit(1) }
}

MainActor.assumeIsolated {
let app = NSApplication.shared
let host = Host()
let cfg = WKWebViewConfiguration()
cfg.userContentController.add(host, name: "t")
let view = WKWebView(frame: .init(x: 0, y: 0, width: 300, height: 300), configuration: cfg)
view.uiDelegate = host
view.navigationDelegate = host
view.loadHTMLString("<html><body>x</body></html>", baseURL: URL(string: "https://example.com"))

var features: WKWindowFeatures { WKWindowFeatures() }
check(!BrowserPopup.isPopup(features), "no size means a new tab, not a popup")

DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated {
    check(host.openResult == "true", "window.open returns a window")
    check(host.received == "msg:signed-in", "popup reaches the opener through postMessage")
    check(host.closed, "window.close() closes the popup")
    print("all passed")
    exit(0)
} }
app.run()
}
