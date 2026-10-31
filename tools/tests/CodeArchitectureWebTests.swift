import AppKit
import WebKit

// Exercise the shipped X-Ray DOM, Cytoscape layout and Mermaid in WKWebView.
let editor = CommandLine.arguments[1]
let payload = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(600)))")
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

let app = NSApplication.shared
let config = WKWebViewConfiguration()
let bridge = Bridge()
config.userContentController.add(bridge, name: "bridge")
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

/// Run `body` (an async function body) in the page and return its string result.
func js(_ body: String, timeout: TimeInterval = 20) -> String {
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


spin(20) { loaded.done }
check(loaded.done, "shipping editor loaded")
var text = js("""
window.testPayload = \(payload);
window.showArchitecture(window.testPayload);
for (let i = 0; i < 200; i++) {
    if (document.getElementById('arch-graph').querySelector('canvas')) break;
    await new Promise(r => setTimeout(r, 50));
}
return document.querySelector('[data-arch-view].on').dataset.archView + '|' + document.getElementById('arch-details').innerText;
""")
check(text.hasPrefix("code|") && text.lowercased().contains("trace a scenario"), "code folders open the Code map with scenario controls", text)
text = js("""
await new Promise(r => setTimeout(r, 1000));
const cy = document.getElementById('arch-graph')._cyreg.cy;
return JSON.stringify({opaque:cy.nodes().every(n => Number(n.style('opacity')) === 1), nodes:cy.nodes().length, zoom:cy.zoom(), width:cy.width(), height:cy.height(), bb:cy.nodes().renderedBoundingBox()});
""")
print("viewport: \(text)")
if let snapshotPath = ProcessInfo.processInfo.environment["CODE_ARCHITECTURE_SNAPSHOT"] {
    let canvasImage = js("return document.getElementById('arch-graph')._cyreg.cy.png({full:false, scale:1});")
    if let comma = canvasImage.firstIndex(of: ","), let png = Data(base64Encoded: String(canvasImage[canvasImage.index(after: comma)...])) {
        try? png.write(to: URL(fileURLWithPath: snapshotPath + ".graph.png"))
    }
    var finished = false
    web.takeSnapshot(with: nil) { image, _ in
        if let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: snapshotPath))
        }
        finished = true
    }
    spin(10) { finished }
}
check(!text.contains("null") && text.contains("\"opaque\":true") && text.contains("\"nodes\":4"), "layer canvas has finite rendered geometry", text)
text = js("""
const cy = document.getElementById('arch-graph')._cyreg.cy;
cy.edges().filter(e => e.data('evidence').includes('web/app.js:2')).first().emit('tap');
return document.getElementById('arch-details').innerText;
""")
check(text.contains("source-backed dependency") && text.contains("web/app.js:2"), "component dependency explains its source evidence", text)
text = js("""
document.querySelector('[data-arch-view="code"]').click();
document.getElementById('arch-code-trace').click();
return String(!document.getElementById('arch-details').hidden && document.activeElement.classList.contains('arch-code-question'));
""")
check(text == "true", "Sequence toolbar action opens the composer even when details are hidden", text)
text = js("""
document.getElementById('arch-analyze').click();
return document.getElementById('arch-analyze').textContent;
""")
check(text == "Analyze code" && bridge.messages.contains { ($0["payload"] as? [String: Any])?["action"] as? String == "analyzeCode" }, "Analyze code sends the dedicated source analysis action", text)
text = js("""
window.architectureFocus('code:f:service.py');
await new Promise(r => setTimeout(r, 200));
return document.getElementById('arch-details').innerText;
""")
check(text.contains("service.py") && text.contains("Zoom out of this"), "file drill-down and its controls render", text)
text = js("""
const buttons = [...document.getElementById('arch-details').querySelectorAll('button')];
buttons.find(b => b.textContent === 'Zoom out of this').click();
await new Promise(r => setTimeout(r, 300));
window.architectureFocus('code:s:symbol:method');
await new Promise(r => setTimeout(r, 100));
return document.getElementById('arch-details').innerText;
""")
check(text.contains("place_order"), "drill-down reaches a symbol", text)
text = js("""
const buttons = [...document.getElementById('arch-details').querySelectorAll('button')];
const open = buttons.find(b => b.classList.contains('arch-path') && b.textContent === 'service.py:5');
if (open) open.click();
return buttons.map(b => b.textContent).join('|');
""")
check(bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "openFile" && p?["path"] as? String == "service.py" && p?["line"] as? Int == 5 }, "symbol opens the source at its line", text)
text = js("""
document.querySelector('[data-arch-view="code"]').click();
await new Promise(r => setTimeout(r, 200));
const input = document.querySelector('.arch-code-question');
input.value = 'How is an order saved?'; input.dispatchEvent(new Event('input'));
[...document.querySelectorAll('.arch-code-traces button')].find(b => b.textContent === 'Draw sequence').click();
return input.value;
""")
check(bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "traceCode" && p?["scope"] as? String == "code:" && p?["question"] as? String == "How is an order saved?" }, "scenario action contains the exact question and scope", text)
text = js("""
[...document.querySelectorAll('.arch-code-traces button')].find(b => b.textContent.includes('Place an order')).click();
for (let i = 0; i < 200; i++) {
    if (document.querySelector('#arch-code-sequence-svg svg')) break;
    await new Promise(r => setTimeout(r, 50));
}
return String(!!document.querySelector('#arch-code-sequence-svg svg')) + '|' + document.getElementById('arch-code-sequence').innerText;
""")
check(text.hasPrefix("true|") && text.contains("OrderService") && text.contains("1. place order"), "sequence renders with the bundled Mermaid library", text)
text = js("""
document.querySelector('#arch-code-sequence-sources button').click();
document.getElementById('arch-code-sequence-close').click();
return String(document.getElementById('arch-code-sequence').hidden);
""")
check(text == "true" && bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "openFile" && p?["path"] as? String == "api.py" && p?["line"] as? Int == 16 }, "sequence evidence opens the source and Back returns to layers", text)
text = js("""
window.testPayload.snapshot.views.find(v => v.id === 'modules').nodes.find(n => n.id === 'm:').signature = 'changed';
window.showArchitecture(window.testPayload);
return document.getElementById('arch-details').innerText;
""")
check(text.contains("Source changed") && text.contains("source changed"), "changed source marks both architecture and sequences stale", text)
text = js("""
document.querySelector('[data-arch-view="docs"]').click();
await new Promise(r => setTimeout(r, 100));
return String(document.getElementById('arch-code-sequence').hidden) + '|' + document.getElementById('arch-analyze').textContent;
""")
check(text == "true|Analyze", "switching views restores existing analysis action and hides sequence", text)
text = js("""
window.showArchitecture({root:'/docs-only', snapshot:{views:[{id:'modules',nodes:[{id:'m:',kind:'root',name:'Docs'}],edges:[]},{id:'code',nodes:[{id:'code:',kind:'root',name:'Code'}],edges:[]}],components:[],assignments:{},coverage:{},metrics:{},scannedAt:'2026-10-31T00:00:00Z'}, busy:false,filters:[],prSources:[]});
document.querySelector('[data-arch-view="code"]').click();
await new Promise(r => setTimeout(r, 200));
return document.getElementById('arch-empty').textContent + '|' + String(document.getElementById('arch-code-sequence').hidden);
""")
check(text.contains("No source code was found") && text.hasSuffix("|true"), "documents-only folders show an honest empty state", text)
print("\(failures) WebKit failures")
exit(failures == 0 ? 0 : 1)
