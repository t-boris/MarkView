import AppKit
import WebKit

// BUG-105: a Markdown document with many Mermaid diagrams froze the editor page for about a minute. Every diagram that is
// drawn puts a <style> element into the page and WebKit then recalculates the styles of every element, so the cost of a
// diagram grew with the size of the document. The page now draws the diagrams in chunks while the document body is hidden.
// The shipped editor page runs in real WebKit (the window is never shown).
// Run through tools/tests/editor-diagrams-tests.sh (needs the bundled editor folder as argument 1).
setvbuf(stdout, nil, _IONBF, 0)
let editor = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(600)))")
}

final class Bridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

let app = NSApplication.shared
let config = WKWebViewConfiguration()
config.userContentController.add(Bridge(), name: "bridge")
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = web
let loaded = Loaded()
web.navigationDelegate = loaded
web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}

func js(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval = 120) -> String {
    var out: String?
    web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value): out = value as? String ?? "\(String(describing: value))"
        case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }
    spin(timeout) { out != nil }
    return out ?? "TIMEOUT"
}

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

let flowchart = "graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]\n  D --> B"
func diagram(_ source: String = flowchart) -> String { "```mermaid\n\(source)\n```\n" }

/// Loads `markdown` the way the app does and waits until every diagram has its picture and its expand button.
/// Returns the longest time the page did not answer a timer while it worked, and how long the whole drawing took.
struct Drawn { var complete = false; var seconds = 0.0; var longestStall = 0.0; var diagrams = 0; var pictures = 0; var buttons = 0; var bodyDisplay = "" }
func open(_ markdown: String, id: String, expecting diagrams: Int, within limit: TimeInterval = 100) -> Drawn {
    _ = js("""
        window.__stall = { max: 0, last: performance.now(), on: true };
        (function tick() {
            const now = performance.now();
            window.__stall.max = Math.max(window.__stall.max, now - window.__stall.last);
            window.__stall.last = now;
            if (window.__stall.on) setTimeout(tick, 10);
        })();
        return 'ok';
        """)
    let started = Date()
    _ = js("window.mvSetDocument(id); window.setContent(markdown); return 'ok';", arguments: ["id": id, "markdown": markdown])
    var result = Drawn()
    while Date().timeIntervalSince(started) < limit {
        spin(0.25)
        let state = json(js("""
            const root = document.getElementById('editor-rendered');
            const nodes = Array.from(root.querySelectorAll('.mermaid'));
            return JSON.stringify({ diagrams: nodes.length, pictures: nodes.filter(n => n.querySelector('svg')).length,
                buttons: root.querySelectorAll('.mermaid-expand-btn').length,
                bodyDisplay: (root.querySelector('.markdown-body') || { style: {} }).style.display || '' });
            """))
        result.diagrams = state["diagrams"] as? Int ?? 0
        result.pictures = state["pictures"] as? Int ?? 0
        result.buttons = state["buttons"] as? Int ?? 0
        result.bodyDisplay = state["bodyDisplay"] as? String ?? ""
        if result.diagrams == diagrams, result.pictures == diagrams, result.buttons == diagrams {
            result.complete = true
            break
        }
    }
    result.seconds = Date().timeIntervalSince(started)
    spin(0.4) // a stalled page answers its timer only after the stall, so the longest gap is read after a moment
    result.longestStall = (Double(js("window.__stall.on = false; return String(Math.round(window.__stall.max));")) ?? -1) / 1000
    return result
}

spin(30) { loaded.done }
check(loaded.done, "shipping editor loaded")
spin(2)

// A large document: 150 sections of text, a table of 12 rows and a diagram.
var large = "# A large document\n\n"
for section in 0..<150 {
    large += "## Section \(section)\n\nParagraph \(section) of the market entry plan, long enough to be a realistic block of prose.\n\n"
    large += "| Item | Owner | Value | Note |\n|---|---|---|---|\n"
    for row in 0..<12 { large += "| row \(section).\(row) | team \(row) | \(row * 7) | note \(row) |\n" }
    large += "\n" + diagram() + "\n"
}
let big = open(large, id: UUID().uuidString, expecting: 150)
check(big.complete, "all 150 diagrams of a large document are drawn and have their expand button",
      "diagrams \(big.diagrams), pictures \(big.pictures), buttons \(big.buttons) after \(big.seconds) s")
print("    drawn in \(String(format: "%.1f", big.seconds)) s, longest time the page did not answer: \(String(format: "%.1f", big.longestStall)) s")
check(big.longestStall < 5, "the page answers within 5 s while the diagrams of a large document are drawn", "stalled \(big.longestStall) s")
check(big.bodyDisplay == "", "the document body is shown again once the diagrams are drawn", big.bodyDisplay)

// A broken diagram is shown by Mermaid itself and the diagrams around it are still drawn.
let mixed = open("# Mixed\n\n" + diagram() + "\n" + diagram("graph TD\n  A --> ;;; [[[ broken") + "\n" + diagram(), id: UUID().uuidString, expecting: 3)
check(mixed.complete, "a broken diagram is drawn by Mermaid and the diagrams around it are drawn", "pictures \(mixed.pictures) of \(mixed.diagrams)")
let marked = Int(js("return String(document.querySelectorAll('#editor-rendered .mermaid[data-processed]').length);")) ?? -1
check(marked == 3, "every diagram is marked as processed, as Mermaid's own run marks them", "\(marked) of 3")

// A document that replaces another while its diagrams are still being drawn leaves only its own diagrams.
var many = "# First\n\n"
for _ in 0..<60 { many += diagram() + "\nText\n\n" }
_ = js("window.mvSetDocument('first'); window.setContent(markdown); setTimeout(() => window.setContent('# Second\\n\\n' + diagram), 700); return 'ok';",
       arguments: ["markdown": many, "diagram": diagram()])
spin(8)
let replaced = json(js("""
    const nodes = Array.from(document.querySelectorAll('#editor-rendered .mermaid'));
    return JSON.stringify({ diagrams: nodes.length, pictures: nodes.filter(n => n.querySelector('svg')).length,
        title: (document.querySelector('#editor-rendered h1') || {}).textContent || '' });
    """))
check(replaced["title"] as? String == "Second" && replaced["diagrams"] as? Int == 1 && replaced["pictures"] as? Int == 1,
      "a document that replaces another while it is being drawn shows only its own diagram", "\(replaced)")

// The reading position survives the hiding of the body.
var long = "# Long\n\n"
for index in 0..<400 { long += "Paragraph \(index) of filler text that makes the page tall enough to scroll.\n\n" }
long += many
_ = js("window.mvSetDocument('scroll'); window.setContent(markdown); return 'ok';", arguments: ["markdown": long])
spin(0.3)
_ = js("document.getElementById('editor-rendered').scrollTop = 3000; return 'ok';")
spin(8)
let scrolled = js("return String(document.getElementById('editor-rendered').scrollTop);")
check(scrolled == "3000", "the reading position is kept while the diagrams are drawn", scrolled)

// A document without diagrams is not touched.
_ = js("window.mvSetDocument('plain'); window.setContent('# Plain\\n\\nNo diagrams here.'); return 'ok';")
spin(1)
let plain = json(js("""
    const root = document.getElementById('editor-rendered');
    return JSON.stringify({ title: (root.querySelector('h1') || {}).textContent || '', diagrams: root.querySelectorAll('.mermaid').length,
        bodyDisplay: (root.querySelector('.markdown-body') || { style: {} }).style.display || '' });
    """))
check(plain["title"] as? String == "Plain" && plain["diagrams"] as? Int == 0 && plain["bodyDisplay"] as? String == "",
      "a document without diagrams renders as before", "\(plain)")

print(failures == 0 ? "All editor diagram checks passed" : "\(failures) editor diagram check(s) failed")
exit(failures == 0 ? 0 : 1)
