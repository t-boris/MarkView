import AppKit
import WebKit

// AR-28 in real WebKit (hidden window): the shipped pages send through mvBridge, the typed handlers take what the contract allows
// and refuse what it does not.
//   - The editor page (index.html) with the real WebViewBridge: a document loaded the way the app loads it makes the page itself send
//     contentChanged and headingsUpdated, and the delegate gets them; a message the contract allows reaches its handler; a message
//     that is mistyped or undeclared is refused by the page (console, nothing posted) and, when posted around mvBridge, by the app
//     (logged by type and field name, never by value); a top-frame-only message from a sub-frame is refused.
//   - The discussion page (discussion.html) with the real coordinator: the page's own `ready` message reaches its typed handler,
//     which sends the turns, and they appear in the page.
// Run through tools/tests/bridge-contract-web-tests.sh (argument 1: the bundled editor folder).
setvbuf(stdout, nil, _IONBF, 0)
let editor = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(700)))")
}
DispatchQueue.global().asyncAfter(deadline: .now() + 150) {
    print("TIMEOUT: no result after 150 s")
    exit(1)
}

NSApplication.shared.setActivationPolicy(.prohibited)
BridgeContract.bundledURL = URL(fileURLWithPath: editor + "/js/bridge-contract.json")
let contract = try! BridgeContract(contentsOf: BridgeContract.bundledURL!)

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

/// A hidden window around a web view; the page is `file` of the editor folder.
final class Page {
    let web: WKWebView
    let window: NSWindow
    let loaded = Loaded()
    init(file: String, handlerName: String, handler: WKScriptMessageHandler, contract: BridgeContract) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(handler, name: handlerName)
        config.userContentController.addUserScript(contract.userScript)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.contentView = web
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/" + file), allowingReadAccessTo: URL(fileURLWithPath: editor))
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
}

// MARK: - The editor page

let delegate = RecordingDelegate()
let bridge = WebViewBridge(contract: contract)
bridge.delegate = delegate
var refusals: [String] = []
bridge.messages.reject = { refusals.append($0) }
let editorPage = Page(file: "index.html", handlerName: "bridge", handler: bridge.messages, contract: contract)
spin(30) { editorPage.loaded.done }
check(editorPage.loaded.done, "the shipping editor page loaded")
spin(2)
check(editorPage.js("return typeof window.mvBridgeContract + ':' + typeof mvBridge.send;") == "object:function", "the page has the contract and mvBridge.send before its own scripts run")

// The app loads a document and names its tab in the same script; the page then sends what it was given.
let tab = UUID()
delegate.calls.removeAll(); delegate.documentIDs.removeAll()
_ = editorPage.js("window.mvSetDocument(\"\(tab.uuidString)\"); window.setContent('# Contract title\\n\\nSome text.'); return 'ok';")
spin(5) { delegate.calls.contains("didUpdateContent") && delegate.calls.contains("didExtractHeadings") }
check(delegate.calls.contains("didUpdateContent") && delegate.documentIDs.contains(tab), "the page's contentChanged reaches the delegate and names the tab", "\(delegate.calls) \(delegate.documentIDs)")
check(delegate.lastHeadings.map { $0.text } == ["Contract title"], "the page's headingsUpdated array reaches the delegate", "\(delegate.lastHeadings)")
check(refusals.isEmpty, "nothing the page sent while it rendered was refused", "\(refusals)")

// A message the contract allows, sent by hand through mvBridge.
delegate.calls.removeAll()
var sentOK = editorPage.js("return String(mvBridge.send('insightRequestSave', { sessionId: 'session-1' }, 'bridge'));")
spin(2) { delegate.calls.contains("bridgeRequestInsightSave") }
check(sentOK == "true" && delegate.calls.contains("bridgeRequestInsightSave"), "a contract-valid message reaches its handler", "\(sentOK) \(delegate.calls)")
sentOK = editorPage.js("return String(mvBridge.send('code', { action: 'navBack' }, 'bridge')) + String(mvBridge.send('arch', { action: 'rescan' }, 'bridge'));")
spin(2) { delegate.calls.contains("didReceiveCodeAction") && delegate.calls.contains("didReceiveArchitectureAction") }
check(delegate.calls.contains("didReceiveCodeAction") && delegate.calls.contains("didReceiveArchitectureAction"), "the code and X-Ray messages reach their handlers", "\(sentOK) \(delegate.calls)")

// What the page refuses: the console says why, nothing is posted, the app hears nothing.
delegate.calls.removeAll(); refusals.removeAll()
let pageRefusal = editorPage.js("""
window.__errors = [];
console.error = function(m) { window.__errors.push(String(m)); };
const results = [
  mvBridge.send('contentChanged', { markdown: 7 }, 'bridge'),
  mvBridge.send('linkClicked', {}, 'bridge'),
  mvBridge.send('no-such-type', { secret: 'TOPSECRET-1' }, 'bridge'),
  mvBridge.send('arch', { action: 'no-such-action' }, 'bridge'),
  mvBridge.send('insightBreadcrumbClicked', { sessionId: 's', nodeId: 'not-a-uuid' }, 'bridge'),
  mvBridge.send('ready', {}, 'no-such-channel'),
];
return JSON.stringify({ results: results, errors: window.__errors });
""")
spin(1)
let refused = (try? JSONSerialization.jsonObject(with: Data(pageRefusal.utf8))) as? [String: Any] ?? [:]
check((refused["results"] as? [Bool]) == Array(repeating: false, count: 6), "the page refuses a mistyped field, a missing field, an undeclared type, an undeclared action, a bad UUID and an undeclared channel", pageRefusal)
let errors = (refused["errors"] as? [String]) ?? []
check(errors.count == 6 && errors[0].contains("contentChanged") && errors[0].contains("payload.markdown") && !errors.joined().contains("TOPSECRET"),
      "each refusal is on the console with the type and the field name, without a value", "\(errors)")
check(delegate.calls.isEmpty && refusals.isEmpty, "a refused message never leaves the page", "\(delegate.calls) \(refusals)")

// What the app refuses when a message is posted around mvBridge.
let raw = editorPage.js("""
const post = (m) => window.webkit.messageHandlers.bridge.postMessage(m);
post({ type: 'linkClicked', payload: { href: 42, note: 'TOPSECRET-2' }, doc: '' });
post({ type: 'no-such-type', payload: { note: 'TOPSECRET-2' }, doc: '' });
post({ type: 'scrollPosition', doc: '' });
post('not a message');
post({ type: 'ready', payload: {}, doc: '' });
return 'posted';
""")
spin(3) { refusals.count >= 4 && delegate.calls.contains("bridgeEditorReady") }
check(raw == "posted" && refusals.count == 4, "the app refuses a mistyped, an undeclared, a payload-less and a malformed message posted around mvBridge", "\(refusals)")
check(!refusals.joined().contains("TOPSECRET") && !refusals.joined().contains("42"), "the app's log names types and fields, never values", "\(refusals)")
check(delegate.calls == ["bridgeEditorReady"], "only the valid one of them reached the delegate", "\(delegate.calls)")

// A message only the top frame may send, posted from a frame inside the page.
delegate.calls.removeAll(); refusals.removeAll()
_ = editorPage.js("""
const frame = document.createElement('iframe');
document.body.appendChild(frame);
frame.contentWindow.webkit.messageHandlers.bridge.postMessage({ type: 'insightRequestSave', payload: { sessionId: 's' }, doc: '' });
frame.contentWindow.webkit.messageHandlers.bridge.postMessage({ type: 'linkClicked', payload: { href: 'https://example.com' }, doc: '' });
return 'posted';
""")
spin(3) { delegate.calls.contains("didClickLink") }
check(refusals.count == 1 && refusals[0].contains("insightRequestSave") && refusals[0].contains("top frame"), "a top-frame-only message from a frame is refused", "\(refusals)")
check(delegate.calls == ["didClickLink"], "a message any frame may send is taken from a frame", "\(delegate.calls)")

// MARK: - The discussion page

let coordinator = DiscussionThreadView.Coordinator()
let discussion = Page(file: "discussion.html", handlerName: "discussion", handler: coordinator.messages, contract: contract)
coordinator.view = discussion.web
coordinator.update(turns: [DiscussionTurn(question: "Which contract?", answer: "The one in bridge-contract.json.")], live: nil, theme: "'classic-dark', null")
var discussionRefusals: [String] = []
coordinator.messages.reject = { discussionRefusals.append($0) }
spin(30) { discussion.loaded.done }
check(discussion.loaded.done, "the shipping discussion page loaded")
// The page's own `ready` reached the typed handler, which sent the turns.
spin(10) { discussion.js("return document.getElementById('thread').textContent;").contains("Which contract?") }
let thread = discussion.js("return document.getElementById('thread').textContent;")
check(thread.contains("Which contract?") && thread.contains("bridge-contract.json"), "the discussion page's ready message reaches its handler, which sends the turns", thread)
check(discussionRefusals.isEmpty, "nothing the discussion page sent was refused", "\(discussionRefusals)")
let refusedByPage = discussion.js("window.__errors = []; console.error = function(m) { window.__errors.push(String(m)); }; return String(mvBridge.send('copy', { text: '' }, 'discussion')) + ':' + String(mvBridge.send('save', { name: 'a' }, 'discussion')) + ':' + window.__errors.length;")
check(refusedByPage == "false:false:2", "the discussion page refuses an empty copy and a save without data", refusedByPage)

print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
