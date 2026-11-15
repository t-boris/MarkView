import AppKit
import WebKit

/// A `window.open` popup (sign-in with Google or Firebase, OAuth consent): a small window whose
/// page keeps its link to the opener, so `window.opener`, `postMessage` and `window.close()` work.
/// Without it `window.open` returns null and the page reports a blocked popup.
@MainActor
final class BrowserPopup: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let window: NSWindow
    let webView: WKWebView
    var onClose: ((BrowserPopup) -> Void)?
    private var closed = false

    /// The popup features that make a `window.open` a real popup instead of a new tab.
    static func isPopup(_ features: WKWindowFeatures) -> Bool {
        features.width != nil || features.height != nil
    }

    /// `configuration` is the one WebKit passes to `createWebViewWith`; it must be used as is
    /// for the page to stay connected to its opener.
    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        let width = min(max(CGFloat(features.width?.doubleValue ?? 500), 320), 900)
        let height = min(max(CGFloat(features.height?.doubleValue ?? 640), 320), 900)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.window.title = view.title ?? "" }
        }.store(in: self)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !closed else { return }
        closed = true
        window.delegate = nil
        window.close()
        onClose?(self)
    }

    // MARK: - Delegates

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        onClose?(self)
    }

    /// `window.close()` from the page, as the sign-in page does when it is done.
    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    /// A popup inside a popup loads in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }
}

private extension NSKeyValueObservation {
    /// Ties the observation's life to `owner`.
    func store(in owner: AnyObject) {
        objc_setAssociatedObject(owner, Unmanaged.passUnretained(self).toOpaque(), self, .OBJC_ASSOCIATION_RETAIN)
    }
}
