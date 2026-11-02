import AppKit
import WebKit

// BUG-031: the shipped editor page names the tab whose document it shows in every message to Swift.
// BUG-043: edits typed in the WYSIWYG view are handed to the app, under the old id, when another document replaces them.
// Run through tools/tests/editor-document-routing-tests.sh (needs the bundled editor folder as argument 1).
let editor = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(600)))")
}

struct Message { let type: String; let doc: String; let payload: [String: Any] }
final class Bridge: NSObject, WKScriptMessageHandler {
    var messages: [Message] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        messages.append(Message(type: type, doc: body["doc"] as? String ?? "<missing>", payload: body["payload"] as? [String: Any] ?? [:]))
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

/// Messages of `type` that arrived since `mark`, after giving the page a moment to send them.
func messages(_ type: String, since mark: Int, wait: TimeInterval = 3) -> [Message] {
    spin(wait) { bridge.messages[mark...].contains { $0.type == type } }
    spin(0.2)
    return bridge.messages[mark...].filter { $0.type == type }
}

let tabA = UUID().uuidString, tabB = UUID().uuidString

spin(30) { loaded.done }
check(loaded.done, "shipping editor loaded")
spin(2)

// The app loads a document and names its tab in the same script (WebViewBridge.documentIDScript: mvSetDocument, then the load).
var mark = bridge.messages.count
var result = js("window.mvSetDocument(\"\(tabA)\"); window.setContent('# Alpha\\n\\nfirst document'); return 'ok';")
check(result == "ok", "document A loads", result)
var sent = messages("contentChanged", since: mark)
check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabA }, "text reported after loading A names tab A", sent.map { $0.doc }.joined(separator: ","))
check(sent.contains { ($0.payload["markdown"] as? String)?.contains("Alpha") == true }, "that text is document A's")

mark = bridge.messages.count
result = js("window.mvSetDocument(\"\(tabB)\"); window.setContent('# Beta\\n\\nsecond document'); return 'ok';")
sent = messages("contentChanged", since: mark)
check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabB }, "after switching to B, text names tab B", sent.map { $0.doc }.joined(separator: ","))

// The reported failure: the page still shows B, typed into, while the app believes another tab is selected.
// Cmd+S must send B's text and name B, so the app can write B's file and leave the selected tab alone.
mark = bridge.messages.count
result = js("""
const rendered = document.getElementById('editor-rendered');
rendered.querySelector('h1').textContent = 'Beta edited';
rendered.dispatchEvent(new Event('input', {bubbles: true}));
rendered.dispatchEvent(new KeyboardEvent('keydown', {key: 's', metaKey: true, bubbles: true, cancelable: true}));
return 'ok';
""")
check(result == "ok", "Cmd+S is sent from the WYSIWYG view", result)
let content = messages("contentChanged", since: mark)
let saves = messages("saveRequested", since: mark)
check(content.last.map { $0.doc == tabB && (($0.payload["markdown"] as? String) ?? "").contains("Beta edited") } == true,
      "Cmd+S sends the edited text of the shown document and names it", content.map { "\($0.doc):\($0.payload["markdown"] ?? "")" }.joined(separator: " | "))
check(saves.count == 1 && saves[0].doc == tabB, "the save request names the shown document", saves.map { $0.doc }.joined(separator: ","))
if let a = bridge.messages[mark...].firstIndex(where: { $0.type == "contentChanged" }),
   let b = bridge.messages[mark...].firstIndex(where: { $0.type == "saveRequested" }) {
    check(a < b, "the text arrives before the save request")
}

// No tab's document (the app clears the id for an insight or the X-Ray): messages carry an empty id.
mark = bridge.messages.count
result = js("window.mvSetDocument(''); window.setContent('# Loose'); return 'ok';")
sent = messages("contentChanged", since: mark)
check(!sent.isEmpty && sent.allSatisfy { $0.doc == "" }, "with the id cleared, messages name no document", sent.map { $0.doc }.joined(separator: ","))

// BUG-043: unsaved WYSIWYG edits survive a switch to another document.
let tabC = UUID().uuidString
func load(_ id: String, _ markdown: String) {
    let result = js("window.mvSetDocument(\"\(id)\"); window.setContent('\(markdown)'); return 'ok';")
    check(result == "ok", "document \(markdown.prefix(12)) loads", result)
}
func typeInWysiwyg(_ text: String) {
    let result = js("""
    const rendered = document.getElementById('editor-rendered');
    rendered.querySelector('h1').textContent = '\(text)';
    rendered.dispatchEvent(new Event('input', {bubbles: true}));
    return 'ok';
    """)
    check(result == "ok", "typing in the WYSIWYG view", result)
}
func markdown(_ message: Message) -> String { (message.payload["markdown"] as? String) ?? "" }

load(tabA, "# Alpha\\n\\nfirst document")
typeInWysiwyg("Alpha typed, not saved")
mark = bridge.messages.count
load(tabB, "# Beta\\n\\nsecond document")
sent = messages("contentChanged", since: mark)
check(sent.first.map { $0.doc == tabA && markdown($0).contains("Alpha typed, not saved") } == true,
      "switching documents first hands over the unsaved edits, under the old id", sent.map { "\($0.doc.prefix(4)):\(markdown($0).prefix(30))" }.joined(separator: " | "))
check(sent.dropFirst().allSatisfy { $0.doc == tabB && !markdown($0).contains("typed, not saved") },
      "what follows is the new document's own text, under the new id")
check(sent.contains { $0.doc == tabB && markdown($0).contains("Beta") }, "the new document is reported")

// Nothing was typed: no hand-over, the first message already belongs to the new document.
mark = bridge.messages.count
load(tabC, "# Gamma\\n\\nthird document")
sent = messages("contentChanged", since: mark)
check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC }, "without edits nothing is handed over for the old document", sent.map { $0.doc.prefix(4) }.joined(separator: ","))

// The same document loading again (a refresh from disk) keeps replacing the edits.
typeInWysiwyg("Gamma typed, then refreshed")
mark = bridge.messages.count
load(tabC, "# Gamma\\n\\nfresh from disk")
sent = messages("contentChanged", since: mark)
check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC && !markdown($0).contains("then refreshed") },
      "reloading the same document does not hand its edits over", sent.map { markdown($0).prefix(30) }.joined(separator: " | "))

// The edits were synced into the Source view and never sent: they still must not be lost.
load(tabA, "# Alpha\\n\\nfirst document")
typeInWysiwyg("Alpha typed, then Source")
_ = js("switchToSource(); return 'ok';")
mark = bridge.messages.count
load(tabB, "# Beta\\n\\nsecond document")
sent = messages("contentChanged", since: mark)
check(sent.first.map { $0.doc == tabA && markdown($0).contains("Alpha typed, then Source") } == true,
      "edits seen in the Source view are handed over too", sent.map { "\($0.doc.prefix(4)):\(markdown($0).prefix(30))" }.joined(separator: " | "))

// Edits are handed over once: coming back and leaving again without typing sends nothing for that document.
_ = js("switchToPreview(); return 'ok';")
mark = bridge.messages.count
load(tabC, "# Gamma\\n\\nthird document")
sent = messages("contentChanged", since: mark)
check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC }, "a second switch hands nothing over again", sent.map { $0.doc.prefix(4) }.joined(separator: ","))

print("\(failures) WebKit failures")
exit(failures == 0 ? 0 : 1)
