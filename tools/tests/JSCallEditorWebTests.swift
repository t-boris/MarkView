import AppKit
import WebKit

// AR-04 on the editor bridge, in real WebKit (hidden window, the shipping index.html): every Swift-to-page command of the real
// WebViewBridge is sent hostile values (quotes, backslashes, U+2028/U+2029, `</script>`, code in a quote, a template literal,
// control characters, emoji, an empty and a 1 MB string) and the page must receive each value unchanged and run nothing.
//   - Document loaded the way the app loads it: the page's own contentChanged returns the markdown that was sent.
//   - Every other command: the page functions are replaced by recorders, the bridge command is called, and the recorded arguments
//     are compared in the page with what Swift sent. `window.__evil` counts any code that ran from a value.
// Run through tools/tests/js-call-web-tests.sh (argument 1: the bundled editor folder).
MainActor.assumeIsolated {
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

let delegate = RecordingDelegate()
let bridge = WebViewBridge(contract: contract)
bridge.delegate = delegate
let config = WKWebViewConfiguration()
config.userContentController.add(bridge.messages, name: "bridge")
config.userContentController.addUserScript(contract.userScript)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.alphaValue = 0
window.contentView = web
let loaded = Loaded()
web.navigationDelegate = loaded
web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

func page(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 30) -> String {
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

spin(30) { loaded.done }
check(loaded.done, "the shipping editor page loaded")
spin(2)

let hostile: [(name: String, value: String)] = [
    ("an apostrophe", "it's an o'brien folder"),
    ("double quotes", "say \"hi\" and \"\""),
    ("backslashes", "back\\slash and \\' and \\\" and trailing \\"),
    ("U+2028 and U+2029", "separators \u{2028} and \u{2029} inside"),
    ("a closing script tag", "</script><script>window.__evil++</script>"),
    ("code in a quote", "'); window.__evil++; ('"),
    ("code in a double quote", "\"); window.__evil++; (\""),
    ("a template literal", "`${window.__evil++}`"),
    ("control characters", "tab\there\u{1}\u{1F}\u{7F}"),
    ("emoji and a joiner", "emoji \u{1F600} and \u{1F468}\u{200D}\u{1F469}"),
    ("comment markers", "// comment /* block */ <!-- html comment -->"),
    ("a very long string", String(repeating: "ab'\"\\\u{2028}</script>", count: 70_000)),
    ("an empty string", ""),
]

// MARK: - A document loaded the way the app loads it

_ = page("window.__evil = 0; return 'ok';")
for item in hostile where !item.value.contains("\u{1}") && item.value != "" {
    let tab = UUID()
    delegate.lastContent = nil
    var completed = false
    bridge.loadContent(item.value, documentID: tab, into: web) { completed = true }
    spin(20) { completed && delegate.lastContent == item.value }
    check(delegate.lastContent == item.value && delegate.documentIDs.last == tab,
          "loadContent: \(item.name) comes back from the page as the same markdown", "\(delegate.lastContent?.count ?? -1) of \(item.value.count) characters")
}
check(page("return String(window.__evil);") == "0", "no markdown ran code in the page")

// MARK: - Every other command, against recorders

let commands = ["mvSetDocument", "setContent", "setCodeContent", "setStructuredContent", "setDocumentBase", "scrollToHeading", "setTheme",
                "updateInsightSection", "setInsightStatus", "setInsightError", "revealStructure", "documentGotoLine", "codeGotoLine",
                "mvResearchMapSet", "showArchitecture", "setArchitectureProgress", "setProjectOperations", "setCodeNotes", "onCodeNavEvent",
                "setDataContent", "loadInsightSkeleton", "releaseInsightBlobs"]
_ = page("""
window.__spy = [];
for (const name of names) {
  window[name] = function () { window.__spy.push({ name: name, args: Array.prototype.slice.call(arguments) }); };
}
return 'ok';
""", ["names": commands])

/// What the recorders hold, compared with `expected` (name and arguments, in order) inside the page. "ok" when equal.
func compare(_ expected: [[String: Any]]) -> String {
    page("""
    const canon = (v) => Array.isArray(v) ? v.map(canon) : (v && typeof v === 'object') ? Object.keys(v).sort().reduce((o, k) => { o[k] = canon(v[k]); return o; }, {}) : v;
    const same = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));
    const got = window.__spy; window.__spy = [];
    if (got.length !== expected.length) return 'count ' + got.length + ' of ' + expected.length + ': ' + got.map(g => g.name).join(',');
    for (let i = 0; i < got.length; i++) {
      if (got[i].name !== expected[i].name) return 'name ' + got[i].name + ' != ' + expected[i].name;
      if (!same(got[i].args, expected[i].args)) return 'args of ' + got[i].name + ': ' + JSON.stringify(got[i].args).slice(0, 300);
    }
    return 'ok';
    """, ["expected": expected])
}

let documentID = UUID()
for item in hostile {
    let text = item.value
    // A JSON text that holds the hostile value: the page parses it and must see the same value.
    let objectJSON = String(data: try! JSONSerialization.data(withJSONObject: ["title": text, "list": [text, 1, true]]), encoding: .utf8)!
    let url = URL(fileURLWithPath: "/tmp/" + text.prefix(200).replacingOccurrences(of: "/", with: "_") + "/")
    var base = url.absoluteString
    if !base.hasSuffix("/") { base += "/" }
    let skeleton = InsightSkeleton(title: text, suggestedTheme: nil, sections: [])

    bridge.loadCodeContent(text, language: text, fileName: text, returnLabel: text, documentID: documentID, into: web)
    bridge.loadStructuredContent(text, fileType: text, documentID: documentID, into: web) {}
    bridge.setDocumentBase(url, in: web)
    bridge.scrollToHeading(text, in: web)
    bridge.setTheme(WebThemeArguments(id: text, accent: text, payload: objectJSON), in: web)
    bridge.updateInsightSection(sessionId: text, sectionId: text, htmlChunk: text, into: web)
    bridge.setInsightStatus(sessionId: text, message: text, phase: text, into: web)
    bridge.setInsightError(sessionId: text, message: text, retryable: true, into: web)
    bridge.revealStructure(pathJSON: text, line: 7, in: web)
    bridge.setResearchMap(objectJSON, documentID: documentID, in: web)
    bridge.showArchitecture(objectJSON, in: web)
    bridge.setArchitectureProgress(objectJSON, in: web)
    bridge.setProjectOperations(objectJSON, in: web)
    bridge.setCodeNotes(objectJSON, in: web)
    bridge.sendCodeNavEvent(objectJSON, in: web)
    bridge.loadInsightSkeleton(skeleton: skeleton, sessionId: text, nodeId: text, breadcrumbs: [(text, text)], into: web)
    bridge.revealCodeLine(3, endLine: nil, in: web)
    bridge.revealDocumentLine(4, in: web)
    bridge.loadDataContent(url, fileType: text, reload: false, documentID: documentID, into: web)

    let parsed: [String: Any] = ["title": text, "list": [text, 1, true]]
    let docArgs: [String: Any] = ["name": "mvSetDocument", "args": [documentID.uuidString]]
    let source = DataFileSchemeHandler.address(of: url)
    let expected: [[String: Any]] = [
        docArgs, ["name": "setCodeContent", "args": [text, text, text, text]],
        docArgs, ["name": "setStructuredContent", "args": [text, text]],
        ["name": "setDocumentBase", "args": [base]],
        ["name": "scrollToHeading", "args": [text]],
        ["name": "setTheme", "args": [text, text, parsed]],
        ["name": "updateInsightSection", "args": [text, text, text]],
        ["name": "setInsightStatus", "args": [text, text, text]],
        ["name": "setInsightError", "args": [text, text, true]],
        ["name": "revealStructure", "args": [text, 7]],
        ["name": "mvResearchMapSet", "args": [documentID.uuidString, parsed]],
        ["name": "showArchitecture", "args": [parsed]],
        ["name": "setArchitectureProgress", "args": [parsed]],
        ["name": "setProjectOperations", "args": [parsed]],
        ["name": "setCodeNotes", "args": [parsed]],
        ["name": "onCodeNavEvent", "args": [parsed]],
        ["name": "loadInsightSkeleton", "args": [["title": text, "sections": []] as [String: Any], text, text, [["nodeId": text, "title": text]]]],
        ["name": "codeGotoLine", "args": [3, 3]],
        ["name": "documentGotoLine", "args": [4]],
        docArgs, ["name": "setDataContent", "args": [["src": source, "kind": text, "name": url.lastPathComponent, "reload": false] as [String: Any]]],
    ]
    spin(0.3) { false }   // the commands are queued in order; the next call of the page runs after all of them
    let result = compare(expected)
    check(result == "ok", "every bridge command passes \(item.name) unchanged", result)
}
check(page("return String(window.__evil);") == "0", "no value ran code in the page")

// Commands that take no value still reach the page.
bridge.releaseInsightBlobs(into: web)
bridge.clearDocument(in: web)
spin(0.5) { false }
check(compare([["name": "releaseInsightBlobs", "args": [] as [Any]], ["name": "mvSetDocument", "args": [""]]]) == "ok", "a command without a value is a plain call, and clearDocument names no tab")

print("\(failures) failures")
exit(failures == 0 ? 0 : 1)

}
