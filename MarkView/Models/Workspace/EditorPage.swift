import Foundation
import Security
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The editor page as the app hands it to WebKit. Its Content-Security-Policy admits only the page's own scripts. The Insight
/// view builds a `srcdoc` frame, and such a frame inherits the policy of the page that holds it, so the frame's inline scripts
/// can only run when the page's `script-src` carries the same per-load nonce the frame uses (FU-10, FU-26).
enum EditorPage {
    /// A random token for one load of the page.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        var rng = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    /// `html` with `'nonce-<nonce>'` appended to the `script-src` directive of its Content-Security-Policy meta element, or nil when
    /// the page has no such directive to carry it (the page text changed) or the nonce is not a plain token.
    static func injectNonce(_ nonce: String, into html: String) -> String? {
        guard nonce.range(of: "^[A-Za-z0-9+/_=-]+$", options: .regularExpression) != nil,
              let meta = html.range(of: #"<meta\s[^>]*http-equiv\s*=\s*"Content-Security-Policy"[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
              let directive = html.range(of: #"script-src [^;">]+"#, options: .regularExpression, range: meta) else { return nil }
        return html.replacingCharacters(in: directive, with: String(html[directive]) + " 'nonce-\(nonce)'")
    }

    /// What the page loads with: its text, and the nonce its policy now accepts. A page whose policy cannot take the nonce is
    /// loaded as it is with no nonce at all, so the script that builds the Insight frame writes `script-src 'none'` for it (the
    /// frame stays inert) instead of a nonce the page would refuse and the Insight view going blank without a trace. The miss
    /// is logged; the page text never is.
    static func prepare(_ html: String) -> (html: String, nonce: String?) {
        let nonce = makeNonce()
        guard let page = injectNonce(nonce, into: html) else {
            AppLog.bridge.notice("The editor page's Content-Security-Policy has no script-src to carry the Insight nonce; the Insight view is disabled for this load.")
            return (html, nil)
        }
        return (page, nonce)
    }

    /// The script that tells the page its nonce, ahead of every other script.
    static func nonceScript(_ nonce: String) -> String {
        "window.__markviewInsightNonce = \"\(nonce)\";"
    }
}
