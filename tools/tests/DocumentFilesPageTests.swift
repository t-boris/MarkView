import AppKit
import WebKit

// Standalone check of the page side of BUG-061 in a real WKWebView: the pictures of a rendered document get their
// markview-doc: addresses, and the author's own paths come back when the page is turned into Markdown again.
// Run with tools/tests/document-files-tests.sh; the argument is the path of markview-document-files.js.

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
}

@main
struct DocumentFilesPageTests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let script = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.done = continuation
            web.loadHTMLString("<html><body><div id=\"r\"></div></body></html>", baseURL: nil)
        }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
        }
        let test = script + """
        ;
        const base = 'file:///P/my%20q/';
        const r = document.getElementById('r');
        r.innerHTML = '<p><img src="a b.png" width="10"> <img src="https://x.test/w.png"> <img src="data:image/png;base64,AAAA">'
            + '<a href="notes/x.md">link</a>'
            + '<picture><source srcset="a.png 1x, b.png 2x"><img src="../up.png"></picture></p>';
        // what the renderer does to links
        r.querySelectorAll('a').forEach(function (a) { a.setAttribute('data-mv-href', a.getAttribute('href')); a.setAttribute('href', new URL(a.getAttribute('href'), base).href); });
        MarkViewDocumentFiles.resolvePictures(r, base);
        const shown = r.innerHTML;
        const restored = MarkViewDocumentFiles.withOriginalPaths(shown);
        return JSON.stringify({ shown: shown, restored: restored, original: '<p><img src="a b.png" width="10"> <img src="https://x.test/w.png"> <img src="data:image/png;base64,AAAA"><a href="notes/x.md">link</a><picture><source srcset="a.png 1x, b.png 2x"><img src="../up.png"></picture></p>' });
        """
        let raw = try? await web.callAsyncJavaScript(test, contentWorld: .page) as? String
        guard let raw, let data = raw.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let shown = result["shown"], let restored = result["restored"], let original = result["original"] else {
            print("FAIL the script did not run"); exit(1)
        }
        check("a local picture is shown at its markview-doc address", shown.contains("src=\"markview-doc:///P/my%20q/a%20b.png\""), shown)
        check("a parent-relative picture is shown at its address", shown.contains("src=\"markview-doc:///P/up.png\""), shown)
        check("a srcset is rewritten with its descriptors", shown.contains("markview-doc:///P/my%20q/a.png 1x, markview-doc:///P/my%20q/b.png 2x"), shown)
        check("a web picture and inline data stay as written", shown.contains("src=\"https://x.test/w.png\"") && shown.contains("src=\"data:image/png;base64,AAAA\""), shown)
        check("the width the author wrote is kept", shown.contains("width=\"10\""))
        check("the author's paths come back exactly", restored == original, "\n  got  \(restored)\n  want \(original)")
        check("no helper attribute is left after restoring", !restored.contains("data-mv-"), restored)
        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
