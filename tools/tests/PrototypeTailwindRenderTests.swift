import AppKit
import Foundation
import WebKit

// BUG-063 in a real WKWebView, served the way the Prototype Studio preview serves a site (mvproto://): a site whose stylesheet is the
// Tailwind source has no rule for its utility classes until MarkView adds the browser build; after it they have, including a class the page
// adds later. Uses the browser build the app ships (MarkView/Resources/Editor/vendor/js/tailwind-browser.js), run from the repository root.

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mvtailwind-render-\(UUID().uuidString)")
let site = work.appendingPathComponent("site")
defer { try? fm.removeItem(at: work) }
func write(_ path: String, _ text: String) {
    let url = site.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

write("original/app/globals.css", """
@import "tailwindcss";
@import "./base.css";
@source '../ui/**/*.tsx';
@theme {
  --color-canvas: #fff8f4;
  --color-ink: #17202b;
  --color-coral: #d0345a;
  --spacing-sp3: 12px;
  --spacing-sp5: 20px;
  --spacing-sp10: 40px;
}
@utility tabular-nums { font-variant-numeric: tabular-nums; }
""")
write("original/app/base.css", "button { cursor: pointer; }")
write("styles.css", "#app { padding: 1px; }")
write("index.html", """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Tailwind render check</title>
<link rel="stylesheet" href="original/app/base.css">
<link rel="stylesheet" href="styles.css">
</head>
<body>
<div id="app">
  <main id="probe" class="flex items-center gap-sp3 mt-sp10 rounded-lg bg-canvas text-ink p-sp5 tabular-nums">Hello</main>
  <span id="late">later</span>
</div>
<script>
window.__errors = [];
window.addEventListener('error', function (e) { window.__errors.push(String(e.message)); });
setTimeout(function () { document.getElementById('late').className = 'mt-sp3 bg-coral block'; }, 400);
</script>
</body>
</html>
""")

final class Page: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finished = true }
}
_ = NSApplication.shared
let page = Page()
let configuration = WKWebViewConfiguration()
configuration.setURLSchemeHandler(PrototypeSchemeHandler(root: site), forURLScheme: PrototypeSchemeHandler.scheme)
let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
view.navigationDelegate = page
func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func js(_ source: String) -> Any? {
    var result: Any?, done = false
    view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { outcome in
        if case .success(let value) = outcome { result = value } else if case .failure(let error) = outcome { result = "ERROR \(error)" }
        done = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline { spin(0.05) }
    return result
}
func style(_ id: String, _ property: String) -> String { js("return getComputedStyle(document.getElementById('\(id)')).\(property)") as? String ?? "?" }
func open() {
    page.finished = false
    view.load(URLRequest(url: PrototypeSchemeHandler.address(of: "index.html")!))
    let deadline = Date().addingTimeInterval(15)
    while !page.finished && Date() < deadline { spin(0.05) }
    spin(1.5)
}

// Without Tailwind the utility classes have no rule: the control that shows the check can fail.
open()
check(page.finished, "the page loads")
check(style("probe", "display") == "block" && style("probe", "marginTop") == "0px", "before: the classes have no rule (display \(style("probe", "display")), margin-top \(style("probe", "marginTop")))")

// MarkView adds Tailwind, with the browser build the app ships.
let vendor = try! Data(contentsOf: URL(fileURLWithPath: "MarkView/Resources/Editor/vendor/js/tailwind-browser.js"))
check((try? PrototypeTailwind.ensure(site: site, vendor: { vendor })) == .applied, "ensure adds Tailwind to the site")
open()
check(style("probe", "display") == "flex", "after: flex is a rule (display \(style("probe", "display")))")
check(style("probe", "marginTop") == "40px", "the theme's spacing names work: mt-sp10 is \(style("probe", "marginTop"))")
check(style("probe", "paddingTop") == "20px" && style("probe", "columnGap") == "12px", "padding and gap come from the theme: \(style("probe", "paddingTop")), \(style("probe", "columnGap"))")
check(style("probe", "backgroundColor") == "rgb(255, 248, 244)", "bg-canvas takes the theme's colour: \(style("probe", "backgroundColor"))")
check(style("probe", "color") == "rgb(23, 32, 43)", "text-ink takes the theme's colour: \(style("probe", "color"))")
check(style("probe", "borderTopLeftRadius") != "0px", "rounded-lg rounds the corners: \(style("probe", "borderTopLeftRadius"))")
check(style("probe", "fontVariantNumeric") == "tabular-nums", "an @utility of the source is a rule: \(style("probe", "fontVariantNumeric"))")
check(style("late", "marginTop") == "12px" && style("late", "backgroundColor") == "rgb(208, 52, 90)",
      "a class the page adds later is compiled too: \(style("late", "marginTop")), \(style("late", "backgroundColor"))")
check(style("app", "paddingTop") == "1px", "the prototype's own styles.css still applies")
check((js("return window.__errors.length") as? Int) == 0, "the page raised no error: \(String(describing: js("return window.__errors.join(' | ')")))")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("Prototype Tailwind in WebKit: utility classes have no rule before MarkView adds Tailwind and the theme's rules after, for classes present at load and added later.")
