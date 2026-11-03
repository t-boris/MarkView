import AppKit
import Foundation
import WebKit

// Checks for PrototypeSchemeHandler (BUG-047): the path rules, and an end-to-end run in a real WKWebView
// that the real error text reaches the preview's own error listener (extracted from PrototypeStudioView.swift).
// Arguments: <path of the extracted error listener script>

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mvproto-tests-\(UUID().uuidString)")
let site = work.appendingPathComponent("site")
func write(_ path: String, _ text: String) {
    let url = site.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
defer { try? fm.removeItem(at: work) }

write("index.html", """
<!doctype html><html><head><meta charset="utf-8"></head><body><div id="app"></div>
<script src="data.js"></script>
<script src="app.js"></script>
<script src="screens/home.js"></script>
<script src="screens/broken.js"></script>
<script>App.start()</script>
</body></html>
""")
write("data.js", "var DB = {items:[1,2,3]};")
write("app.js", "var App = {screens:[], register:function(s){this.screens.push(s)}, start:function(){document.getElementById('app').textContent='started '+this.screens.length}};")
write("screens/home.js", "App.register({id:'home'});")
write("screens/broken.js", "App.register({id:'broken'});\nundefinedFunction();\n")
write("components/card.html", "<!doctype html><title>card</title>")
write("my file.js", "window.spaced = true;")
write("data.json", "{\"ok\":true}")
write("fetcher.html", """
<!doctype html><html><body><script>
fetch('data.json').then(r => r.json()).then(j => window.webkit.messageHandlers.mvError.postMessage('FETCHED ' + j.ok))
  .catch(e => window.webkit.messageHandlers.mvError.postMessage('FETCH FAILED ' + e));
</script></body></html>
""")
let secret = work.appendingPathComponent("secret.txt")
try! "secret".write(to: secret, atomically: true, encoding: .utf8)
try! fm.createSymbolicLink(at: site.appendingPathComponent("escape.txt"), withDestinationURL: secret)
try! fm.createSymbolicLink(at: site.appendingPathComponent("inside.js"), withDestinationURL: site.appendingPathComponent("data.js"))

// MARK: Path rules

func file(_ path: String) -> String? {
    if case .file(let url) = PrototypeSchemeHandler.lookup(path: path, in: site) { return url.lastPathComponent }
    return nil
}
check(file("/") == "index.html", "root serves index.html")
check(file("") == "index.html", "empty path serves index.html")
check(file("/index.html") == "index.html", "index.html by name")
check(file("/screens/broken.js") == "broken.js", "screen script")
check(file("/components/card.html") == "card.html", "component page")
check(file("/my%20file.js") == "my file.js", "percent-encoded name")
check(file("/inside.js") == "data.js", "symlink that stays inside is served")
check(PrototypeSchemeHandler.lookup(path: "/../secret.txt", in: site) == .forbidden, "parent traversal is forbidden")
check(PrototypeSchemeHandler.lookup(path: "/%2e%2e/secret.txt", in: site) == .forbidden, "encoded parent traversal is forbidden")
check(PrototypeSchemeHandler.lookup(path: "/screens/../app.js", in: site) == .forbidden, "inner .. is forbidden")
check(PrototypeSchemeHandler.lookup(path: "/escape.txt", in: site) == .forbidden, "symlink out of the site is forbidden")
check(PrototypeSchemeHandler.lookup(path: "/a%00b", in: site) == .forbidden, "NUL byte is forbidden")
check(PrototypeSchemeHandler.lookup(path: "/nope.js", in: site) == .missing, "missing file")
check(PrototypeSchemeHandler.lookup(path: "/screens", in: site) == .missing, "directory without index.html")
check(PrototypeSchemeHandler.address(of: "index.html")?.absoluteString == "mvproto://site/index.html", "address of the index")
check(PrototypeSchemeHandler.address(of: "components/card.html", fragment: "#home")?.absoluteString
      == "mvproto://site/components/card.html#home", "address with a fragment")
check(PrototypeSchemeHandler.address(of: "my file.js")?.absoluteString == "mvproto://site/my%20file.js", "address encodes a space")
check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/app.js")) == "text/javascript; charset=utf-8", "js type")
check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/index.html")) == "text/html; charset=utf-8", "html type")
check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/styles.css")) == "text/css; charset=utf-8", "css type")
check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/logo.png")) == "image/png", "png type")
check(PrototypeSchemeHandler.contentType(of: URL(fileURLWithPath: "/a/x.zzzunknown")) == "application/octet-stream", "unknown type")

// MARK: End to end in WebKit

let listener = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
check(listener.contains("addEventListener('error'"), "the preview's error listener was extracted")

final class Page: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var messages: [String] = []
    var finished = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { messages.append("\(m.body)") }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finished = true }
}

_ = NSApplication.shared
let handler = PrototypeSchemeHandler(root: site)

func run(_ name: String, settle: TimeInterval = 1.0, _ load: (WKWebView) -> Void) -> [String] {
    let page = Page()
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(handler, forURLScheme: PrototypeSchemeHandler.scheme)
    configuration.userContentController.add(page, name: "mvError")
    configuration.userContentController.addUserScript(WKUserScript(source: listener, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    view.navigationDelegate = page
    load(view)
    let deadline = Date().addingTimeInterval(15)
    while !page.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.current.run(until: Date().addingTimeInterval(settle))
    if !page.finished { print("FAIL \(name): page did not finish loading"); failures += 1 }
    return page.messages
}

let served = run("scheme") { $0.load(URLRequest(url: PrototypeSchemeHandler.address(of: "index.html")!)) }
print("     reported through mvproto://: \(served)")
check(served.count == 1, "one error reported through the scheme")
check(served.first?.contains("undefinedFunction") == true, "the real error text arrives, not 'Script error.'")
check(served.first?.contains("screens/broken.js:2") == true, "the error names the screen file and line")

let fetched = run("fetch") { $0.load(URLRequest(url: PrototypeSchemeHandler.address(of: "fetcher.html")!)) }
check(fetched == ["FETCHED true"], "a page can fetch its own data file")

let baseline = run("file") { $0.loadFileURL(site.appendingPathComponent("index.html"), allowingReadAccessTo: site) }
print("     reported through file:// (the old way): \(baseline)")
check(baseline.first?.contains("undefinedFunction") == false, "baseline: file:// hides the text (the cause of BUG-047)")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
