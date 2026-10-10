import Cocoa
import WebKit

// Runs the real `window.revealStructure` of markview-structured.js against a tree shaped like the
// viewer's output, in a WKWebView.
var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let source = try String(contentsOfFile: "MarkView/Resources/Editor/vendor/js/markview-structured.js", encoding: .utf8)
guard let start = source.range(of: "window.revealStructure = function"), let end = source.range(of: "window.structFoldAll") else {
    print("FAIL revealStructure not found in markview-structured.js"); exit(1)
}
let function = String(source[start.lowerBound..<end.lowerBound])

func node(_ path: String, key: String, children: String? = nil, id: String = "") -> String {
    let attr = path.replacingOccurrences(of: "\"", with: "&quot;")
    if let children {
        return "<div class=\"struct-node\" id=\"\(id)\" data-path=\"\(attr)\"><div class=\"struct-line\"><span class=\"struct-toggle\" data-target=\"\(id)-children\">▼</span>\(key)</div>"
            + "<div class=\"struct-children collapsed\" id=\"\(id)-children\">\(children)</div></div>"
    }
    return "<div class=\"struct-node\" data-path=\"\(attr)\"><div class=\"struct-line\">\(key)</div></div>"
}
let tree = node("[]", key: "root", children:
    node("[\"name\"]", key: "name")
    + node("[\"services\"]", key: "services", children:
        node("[\"services\",\"web\"]", key: "web", children: node("[\"services\",\"web\",\"image\"]", key: "image"), id: "web"), id: "svc"), id: "root")

let html = """
<html><body><div id="rendered">\(tree)</div><script>
const state = { mode: 'structured' };
const DOM = { rendered: document.getElementById('rendered') };
window.__goto = null;
window.documentGotoLine = function(line) { window.__goto = line; };
\(function)
</script></body></html>
"""

final class Runner: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    func start() { web.navigationDelegate = self; web.loadHTMLString(html, baseURL: nil) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await run(); print(failures == 0 ? "All structure reveal checks passed." : "\(failures) structure reveal check(s) failed."); exit(failures == 0 ? 0 : 1) }
    }
    @MainActor func js(_ script: String) async -> Any? {
        await withCheckedContinuation { c in web.evaluateJavaScript(script) { value, _ in c.resume(returning: value) } }
    }
    @MainActor func run() async {
        let found = await js("window.revealStructure('[\"services\",\"web\",\"image\"]', 5)") as? Bool
        check(found == true, "a nested key is found")
        let svc = await js("document.getElementById('svc-children').classList.contains('collapsed')") as? Bool
        let web = await js("document.getElementById('web-children').classList.contains('collapsed')") as? Bool
        let root = await js("document.getElementById('root-children').classList.contains('collapsed')") as? Bool
        check(svc == false && web == false && root == false, "folded containers above it are opened")
        let flashed = await js("document.querySelectorAll('.struct-revealed').length") as? Int
        let flashedText = await js("document.querySelector('.struct-revealed').textContent") as? String
        check(flashed == 1 && flashedText == "image", "its row is flashed")
        let arrow = await js("document.querySelector('.struct-toggle[data-target=\"svc-children\"]').textContent") as? String
        check(arrow == "▼", "the toggle arrows follow")
        let missing = await js("window.revealStructure('[\"nope\"]', 9)") as? Bool
        check(missing == false, "an unknown path reports false")
        let jumped = await js("window.__goto")
        check(jumped == nil || jumped is NSNull, "no line jump while the tree is shown")
        _ = await js("state.mode = 'source'")
        let sourceShown = await js("window.revealStructure('[\"name\"]', 7)") as? Bool
        let line = await js("window.__goto") as? Int
        check(sourceShown == true && line == 7, "in a source view the line is selected instead")
    }
}

let app = NSApplication.shared
let runner = Runner()
runner.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("FAIL timeout"); exit(1) }
app.run()
