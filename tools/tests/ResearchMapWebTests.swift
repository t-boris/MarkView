import AppKit
import WebKit

// The research map view (DEC-009) in the shipped editor page: a type: research-map document shows the map instead of the
// text, a snapshot pushed through window.mvResearchMapSet is drawn, and every action the person takes reaches Swift as
// the exact "researchMap" message of the contract. The page runs in a real WKWebView whose window is never shown
// (accessory app, window far off screen and never ordered front), and the bridge is a stub that records messages.
// Run through tools/tests/research-map-web-tests.sh (needs the bundled editor folder as argument 1).
setvbuf(stdout, nil, _IONBF, 0)
let editor = CommandLine.arguments[1]
var failures = 0
var errorsSeen = 0
var errorProbe: (() -> Int)?
func check(_ ok: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail().prefix(900)))")
    // Say where a page error first shows up (the page's own diagnostics only report "Script error." for file URLs).
    if let probe = errorProbe {
        let count = probe()
        if count > errorsSeen { errorsSeen = count; print("info  page errors so far: \(count), first seen at the check above") }
    }
}
// A hung page must not hang the test run.
DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
    print("TIMEOUT: no result after 240 s")
    exit(1)
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
app.setActivationPolicy(.accessory)
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
let bridge = Bridge()
config.userContentController.add(bridge, name: "bridge")
// Every uncaught error and rejected promise of the page is recorded from the very start.
let recorder = WKUserScript(source: """
window.__errors = [];
window.addEventListener('error', function (e) { window.__errors.push('error: ' + e.message + ' @' + (e.filename || '') + ':' + e.lineno); });
window.addEventListener('unhandledrejection', function (e) { window.__errors.push('rejection: ' + (e.reason && e.reason.message || e.reason)); });
""", injectionTime: .atDocumentStart, forMainFrameOnly: true)
config.userContentController.addUserScript(recorder)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: config)
// Never visible: far off screen, borderless, and never ordered front.
let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
let loaded = Loaded()
web.navigationDelegate = loaded
web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// Runs a function body in the page; the result is a string (JSON for structures).
func js(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 20) -> String {
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
func json(_ body: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
    let text = js(body, arguments)
    guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["error": text] }
    return object
}
func eval(_ body: String, _ arguments: [String: Any] = [:]) -> String { js("return String(" + body + ");", arguments) }
func bool(_ expression: String) -> Bool { eval(expression) == "true" }
func number(_ expression: String) -> Double { Double(eval(expression)) ?? .nan }

// ---- messages from the page -----------------------------------------------------------------------------------------
var mark = 0
func newMark() { mark = bridge.messages.count }
func researchMessages(since: Int? = nil) -> [Message] { bridge.messages[(since ?? mark)...].filter { $0.type == "researchMap" } }
func describe(_ messages: [Message]) -> String {
    messages.map { m in
        let keys = m.payload.keys.sorted().map { "\($0)=\(m.payload[$0] ?? "")" }.joined(separator: ",")
        return "[\(m.doc.prefix(4)) \(keys)]"
    }.joined(separator: " ")
}
func equal(_ a: [String: Any], _ b: [String: Any]) -> Bool { (a as NSDictionary).isEqual(to: b) }

/// The page must send exactly this researchMap message (and name this document) after the last `newMark()`.
func expect(_ name: String, _ expected: [String: Any], doc: String? = nil, wait: TimeInterval = 4.5, count: Int = 1) {
    spin(wait) { researchMessages().filter { equal($0.payload, expected) }.count >= count }
    spin(0.15)
    let hits = researchMessages().filter { equal($0.payload, expected) }
    let named = doc.map { d in hits.allSatisfy { $0.doc == d } } ?? true
    check(hits.count == count && named, name, "wanted \(expected) x\(count) \(doc ?? "") got: \(describe(researchMessages()))")
}
func expectNone(_ name: String, action: String, wait: TimeInterval = 0.9) {
    spin(wait)
    let hits = researchMessages().filter { ($0.payload["action"] as? String) == action }
    check(hits.isEmpty, name, "unexpected: \(describe(hits))")
}

// ---- the page ---------------------------------------------------------------------------------------------------------
spin(40) { loaded.done }
check(loaded.done, "shipping editor page loaded")
spin(1.5)
// The shipping page raises one "Script error." of its own while loading; only errors after this point count.
let baselineErrors = Int(js("return String(window.__errors.length);")) ?? 0
let baselineReports = bridge.messages.filter { $0.type == "jsError" }.count
errorsSeen = baselineErrors
errorProbe = { Int(js("return String((window.__errors || []).length);", [:], timeout: 5)) ?? 0 }
print("info page errors before the test: \(baselineErrors) (already present without the research map scripts)")

let probe = json("""
const t0 = performance.now();
await new Promise(function (r) { setTimeout(r, 300); });
return JSON.stringify({ visibility: document.visibilityState, width: innerWidth, height: innerHeight, timer: Math.round(performance.now() - t0),
  layout: !!window.MVResearchMapLayout, view: !!window.MVResearchMap, leave: typeof window.leaveResearchMap, set: typeof window.mvResearchMapSet });
""")
print("info page: \(probe)")
check((probe["layout"] as? Bool) == true && (probe["view"] as? Bool) == true && (probe["leave"] as? String) == "function" && (probe["set"] as? String) == "function",
      "the layout engine and the map view are loaded and expose the API", "\(probe)")

// Helpers that drive the page the way a person would (clicks, pointer drags, typing, keys, wheel).
let helpers = #"""
const q = function (s) { return document.querySelector(s); };
const qa = function (s) { return Array.from(document.querySelectorAll(s)); };
const fire = function (type, target, x, y) {
  return target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, pointerId: 7, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: x, clientY: y }));
};
const centre = function (e) { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; };
window.__t = {
  q: q, qa: qa,
  wrap: function (id) { return q('.rm-node-wrap[data-id="' + id + '"]'); },
  btn: function (id) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-node'); },
  pos: function (id) { const w = q('.rm-node-wrap[data-id="' + id + '"]'); return { x: parseFloat(w.style.left), y: parseFloat(w.style.top) }; },
  select: function (id) { q('.rm-node-wrap[data-id="' + id + '"] .rm-node').click(); },
  menu: function (id) { q('.rm-node-wrap[data-id="' + id + '"] .rm-tri').click(); },
  fold: function (id) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-fold'); },
  shown: function (id) { const w = q('.rm-node-wrap[data-id="' + id + '"]'); return !w.hidden; },
  act: function (name) { q('.rm-actions [data-act="' + name + '"]').click(); },
  dialogButton: function (text) { const b = qa('.rm-dialog-actions button').find(function (x) { return x.textContent.trim() === text; }); if (!b) throw new Error('no dialog button ' + text); b.click(); },
  type: function (el, value) { el.focus(); el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); },
  key: function (el, key, opts) { return el.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ key: key, bubbles: true, cancelable: true }, opts || {}))); },
  dragStart: function (id) { const b = this.btn(id), c = centre(b); window.__drag = { id: id, x: c.x, y: c.y, el: b }; fire('pointerdown', b, c.x, c.y); },
  dragTo: function (dx, dy) { const d = window.__drag; fire('pointermove', d.el, d.x + dx, d.y + dy); },
  dragEnd: function (dx, dy, click) { const d = window.__drag; fire('pointerup', d.el, d.x + dx, d.y + dy); if (click) d.el.click(); },
  wheel: function (x, y, deltaY) { const e = new WheelEvent('wheel', { bubbles: true, cancelable: true, clientX: x, clientY: y, deltaY: deltaY }); q('.rm-viewport').dispatchEvent(e); return e.defaultPrevented; },
  view: function () { const m = /translate\(([-\d.e]+)px,\s*([-\d.e]+)px\)\s*scale\(([-\d.e]+)\)/.exec(q('.rm-world').style.transform); return { x: parseFloat(m[1]), y: parseFloat(m[2]), scale: parseFloat(m[3]) }; },
  panning: function (dx, dy) { const v = q('.rm-viewport'), r = v.getBoundingClientRect(), x = r.left + 8, y = r.bottom - 8; fire('pointerdown', v, x, y); fire('pointermove', v, x + dx, y + dy); fire('pointerup', v, x + dx, y + dy); },
  deliver: function (snapshot) { window.mvResearchMapSet(window.mvDocumentId, snapshot); },
  snap: function (over) {
    const node = function (id, parent, title, extra) { return Object.assign({ id: id, parent: parent, title: title, tags: [], color: '', icon: '', number: null, shape: '', width: null, height: null, description: '', layout: '', x: null, y: null, evidence: [] }, extra || {}); };
    const nodes = [
      node('n1', '', 'Why do builds get slow?', { tags: ['question'], description: 'The central question.' }),
      node('n2', 'n1', 'Dependencies', { tags: ['deps', 'build'], description: 'Notes on the dependency graph.', evidence: [
        { label: 'Project fact', text: 'Package.swift lists 14 targets.', source: 'Package.swift:12' },
        { label: 'External fact', text: 'SwiftPM resolves packages in parallel.', source: 'https://swift.org/package-manager' },
        { label: 'AI inference', text: 'Resolution is probably cached.', source: '' },
        { label: 'Open assumption', text: 'CI starts from a cold cache.', source: '' }] }),
      node('n3', 'n1', 'Compiler'), node('n4', 'n1', 'Linking'), node('n5', 'n1', 'Caching'),
      node('n6', 'n2', 'Module graph'), node('n7', 'n2', 'Version pins'),
      node('n8', 'n3', 'Incremental builds'), node('n9', 'n3', 'Whole module optimisation'),
      node('n10', 'n4', 'Static libraries'), node('n11', 'n4', 'Dynamic libraries'), node('n12', 'n5', 'Remote cache')];
    const layouts = ['balanced', 'right', 'left', 'down', 'up', 'radial', 'outline'].map(function (id) { return { id: id, name: id.charAt(0).toUpperCase() + id.slice(1) }; });
    return Object.assign({ ok: true, problem: '', id: '2026-11-04-builds', title: 'Why do builds get slow?', question: 'Why do builds get slow?', status: 'complete', incomplete: '', job: null,
      webQueries: ['swiftpm resolution time', 'xcode build cache'], nodes: nodes, links: [{ from: 'n6', to: 'n8' }, { from: 'n2', to: 'n5' }], layouts: layouts, created: '', notice: '',
      shapes: [['rounded', 'Rounded'], ['rectangle', 'Rectangle'], ['pill', 'Pill'], ['ellipse', 'Ellipse'], ['diamond', 'Diamond']].map(function (s) { return { id: s[0], name: s[1] }; }),
      sizeLimits: { width: [60, 800], height: [28, 600] } }, over || {});
  },
  /** A snapshot where the given nodes carry extra fields: extras maps a node id to an object of fields. */
  look: function (extras) {
    const s = this.snap();
    s.nodes.forEach(function (n) { if (extras[n.id]) Object.assign(n, extras[n.id]); });
    return s;
  },
  handle: function (id, dir) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-handle[data-h="' + dir + '"]'); },
  resizeStart: function (id, dir) { const hd = this.handle(id, dir), c = centre(hd); window.__drag = { id: id, x: c.x, y: c.y, el: hd }; fire('pointerdown', hd, c.x, c.y); },
  box: function (id) { const r = this.btn(id).getBoundingClientRect(), s = window.MVResearchMap.viewState().scale; return { w: Math.round(r.width / s), h: Math.round(r.height / s), l: r.left, t: r.top, r: r.right, b: r.bottom, cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; }
};
return 'installed';
"""#
check(js(helpers) == "installed", "test helpers installed in the page")

let tabP = UUID().uuidString, tabM = UUID().uuidString, tabN = UUID().uuidString
let mapText = "---\ntype: research-map\nid: 2026-11-04-builds\ntitle: Why do builds get slow?\nstatus: complete\n---\n\n# Why do builds get slow?\n\n## Map\n\n- [Why do builds get slow?](#n1)\n"
func loadDocument(_ id: String, _ text: String) -> String {
    js("window.mvSetDocument(id); window.setContent(text); return 'ok';", ["id": id, "text": text])
}
func deliver(_ overrides: String = "{}", doc: String? = nil) {
    _ = js("window.mvResearchMapSet(doc || window.mvDocumentId, window.__t.snap(\(overrides))); return 'ok';", ["doc": doc ?? ""])
    spin(0.2)
}
func visible(_ selector: String) -> Bool { bool("(function(){ const e = document.querySelector('\(selector)'); return !!e && getComputedStyle(e).display !== 'none'; })()") }

// ---- a plain document first -----------------------------------------------------------------------------------------------
check(loadDocument(tabP, "# Plain document\n\nnothing to see") == "ok", "a plain document loads")
check(!visible("#research-map-container"), "a plain document does not show the map")
check(visible("#preview-pane"), "a plain document shows the usual preview")

// ---- a research map document ------------------------------------------------------------------------------------------------
newMark()
check(loadDocument(tabM, mapText) == "ok", "a research map document loads")
check(visible("#research-map-container"), "the map view is shown")
check(eval("document.getElementById('status-mode').textContent") == "MAP", "the status bar names the mode", eval("document.getElementById('status-mode').textContent"))
check(!visible("#preview-pane") && !visible("#editor-pane"), "the document text is hidden behind the map")
check(!visible("#wysiwyg-toolbar"), "the formatting bar is hidden while the map is shown")
expect("entering the map asks Swift for a snapshot, naming the document", ["action": "snapshot"], doc: tabM)
check(bool("document.querySelectorAll('.rm-node').length === 0"), "no nodes before the snapshot arrives")

deliver()
let nodeCount = number("document.querySelectorAll('.rm-node').length")
check(nodeCount == 12, "the snapshot draws all 12 nodes", "\(nodeCount)")
check(number("document.querySelectorAll('.rm-node.root').length") == 1 && bool("__t.btn('n1').classList.contains('root')"), "exactly one root node, the first")
check(number("document.querySelectorAll('.rm-node.branch').length") == 4, "the root's direct children are branch nodes")
check(number("document.querySelectorAll('path[data-line=tree]').length") == 11, "11 hierarchy lines")
check(number("document.querySelectorAll('path[data-line=link]').length") == 2 && bool("__t.q('path[data-line=link]').getAttribute('stroke-dasharray') !== null && getComputedStyle(__t.q('path[data-line=link]')).stroke === 'rgb(128, 128, 128)'"),
      "2 dashed logical connections in the application's secondary text colour")
check(eval("__t.q('.rm-heading strong').textContent") == "Why do builds get slow?", "the toolbar shows the map title")
check(eval("__t.q('.rm-zoom').textContent") == "100%", "the initial zoom is 100%")
let rootBox = json("const r = __t.btn('n1').getBoundingClientRect(), v = __t.q('.rm-viewport').getBoundingClientRect(); return JSON.stringify({ dx: (r.left + r.width / 2) - (v.left + v.width / 2), dy: (r.top + r.height / 2) - (v.top + v.height / 2), w: v.width, h: v.height });")
check(abs((rootBox["dx"] as? Double) ?? 999) < 3 && abs((rootBox["dy"] as? Double) ?? 999) < 3, "with no saved view the root sits at the centre of the canvas", "\(rootBox)")
check(((rootBox["w"] as? Double) ?? 0) > 500, "the canvas has a real size in the hidden window", "\(rootBox)")

// Node look: translucent menu button (an ellipsis, not a fold arrow) inside the node, in its top right corner.
let triangle = json("""
const n = __t.btn('n3').getBoundingClientRect(), t = __t.q('.rm-node-wrap[data-id="n3"] .rm-tri').getBoundingClientRect(), s = getComputedStyle(__t.q('.rm-node-wrap[data-id="n3"] .rm-tri'));
return JSON.stringify({ inside: t.left >= n.left && t.right <= n.right + 0.5 && t.top >= n.top && t.bottom <= n.bottom, topRight: (n.right - t.right) < 14 && (t.top - n.top) < 14, opacity: parseFloat(s.opacity), text: __t.q('.rm-node-wrap[data-id="n3"] .rm-tri').textContent });
""")
check((triangle["inside"] as? Bool) == true && (triangle["topRight"] as? Bool) == true, "the menu triangle sits inside the node, in its top right corner", "\(triangle)")
check(((triangle["opacity"] as? Double) ?? 1) < 0.8, "the menu button is translucent", "\(triangle)")
check((triangle["text"] as? String) == "⋯", "the menu button is an ellipsis, so it cannot be mistaken for a fold toggle (BUG-092)", "\(triangle)")
let looks = json("""
const root = getComputedStyle(__t.btn('n1')), node = getComputedStyle(__t.btn('n3')), view = getComputedStyle(__t.q('.rm-viewport'));
return JSON.stringify({ rootBg: root.backgroundColor, rootRadius: root.borderTopLeftRadius, nodeBorder: node.borderTopWidth, nodeRadius: node.borderTopLeftRadius, nodeBg: node.backgroundColor, viewBg: view.backgroundColor, dots: view.backgroundImage.indexOf('radial-gradient') >= 0, size: view.backgroundSize });
""")
check((looks["rootBg"] as? String) == "rgb(45, 45, 48)" && (looks["rootRadius"] as? String) == "8px", "dark theme: the root uses the application's --bg-tertiary (#2d2d30)", "\(looks)")
check((looks["nodeBg"] as? String) == "rgb(37, 37, 38)" && (looks["nodeRadius"] as? String) == "6px" && (looks["nodeBorder"] as? String) == "1px", "dark theme: nodes use --bg-secondary (#252526), a 6px radius and a 1px border like the application's cards", "\(looks)")
check((looks["viewBg"] as? String) == "rgb(30, 30, 30)" && (looks["dots"] as? Bool) == true && (looks["size"] as? String) == "24px 24px", "dark theme: the canvas is --bg-primary (#1e1e1e) with the application's dot grid (BUG-091)", "\(looks)")
let noGlow = json("const n = getComputedStyle(__t.btn('n3')), r = getComputedStyle(__t.btn('n1')); return JSON.stringify({ node: n.boxShadow, root: r.boxShadow, accent: n.borderLeftColor });")
check(!((noGlow["root"] as? String) ?? "").contains("rgb(62, 49, 120)") && !((noGlow["root"] as? String) ?? "").contains("0px 8px 0px"), "the prototype's 3D root shadow is gone", "\(noGlow)")
check((noGlow["accent"] as? String) == "rgb(78, 201, 176)", "a branch node carries its branch accent (#4ec9b0, the application's teal) on its left edge", "\(noGlow)")

// Selection and the properties panel.
check(bool("__t.btn('n1').getAttribute('aria-pressed') === 'true'"), "the root is selected first")
check(eval("__t.q('.rm-title-input').value") == "Why do builds get slow?", "the panel shows the selected node's title")
newMark()
_ = js("__t.select('n2'); return 'ok';")
check(bool("__t.btn('n2').getAttribute('aria-pressed') === 'true' && __t.btn('n1').getAttribute('aria-pressed') === 'false'"), "clicking a node selects it")
check(eval("__t.q('.rm-title-input').value") == "Dependencies", "the panel follows the selection")
check(number("document.querySelectorAll('.rm-tag').length") == 2 && eval("__t.qa('.rm-tag').map(function(t){return t.dataset.tag;}).join()") == "deps,build", "tags are listed")
check(eval("__t.q('.rm-desc').value") == "Notes on the dependency graph.", "the description fills the textarea")
check(number("document.querySelectorAll('.rm-ev-row').length") == 4, "four evidence rows")
check(eval("__t.qa('.rm-ev-chip').map(function(c){return c.textContent;}).join('|')") == "Project fact|External fact|AI inference|Open assumption", "each finding shows its label chip")
check(eval("__t.q('.rm-ev-row .rm-ev-text').textContent") == "Package.swift lists 14 targets.", "the finding's text is shown")
check(number("document.querySelectorAll('.rm-ev-source').length") == 2, "only findings with a source show a source link")
let chipColours = json("return JSON.stringify({ colours: __t.qa('.rm-ev-chip').map(function (c) { return getComputedStyle(c).backgroundColor; }) });")
check(Set((chipColours["colours"] as? [String]) ?? []).count == 4, "the four labels have four different chip colours", "\(chipColours)")
// Light theme (prototype v9) switches on html[data-theme="light"].
_ = js("document.documentElement.setAttribute('data-theme', 'light'); return 'ok';")
let light = json("""
const root = getComputedStyle(__t.btn('n1')), node = getComputedStyle(__t.btn('n3')), view = getComputedStyle(__t.q('.rm-viewport')), panel = getComputedStyle(__t.q('.rm-panel'));
return JSON.stringify({ rootBg: root.backgroundColor, nodeBg: node.backgroundColor, nodeInk: node.color, nodeAccent: node.borderLeftColor, viewBg: view.backgroundColor, panelBg: panel.backgroundColor });
""")
check((light["rootBg"] as? String) == "rgb(232, 232, 232)" && (light["viewBg"] as? String) == "rgb(255, 255, 255)" && (light["panelBg"] as? String) == "rgb(243, 243, 243)", "light theme: root, canvas and panel use the application's light tokens", "\(light)")
check((light["nodeBg"] as? String) == "rgb(243, 243, 243)" && (light["nodeAccent"] as? String) == "rgb(34, 134, 58)", "light theme: a branch node keeps the card fill and takes the darker branch accent", "\(light)")
_ = js("document.documentElement.removeAttribute('data-theme'); return 'ok';")
let evidenceBelow = bool("__t.q('.rm-desc').getBoundingClientRect().bottom <= __t.q('.rm-ev-row').getBoundingClientRect().top + 1")
check(evidenceBelow, "the evidence list sits under the description")
// BUG-096: the resize grip of the description field sets an inline height; the field has to follow it.
let descSizes = json("""
const d = __t.q('.rm-desc'), height = function () { return Math.round(d.getBoundingClientRect().height); };
const natural = height();
d.style.height = '360px'; const tall = height();
const below = d.getBoundingClientRect().bottom <= __t.q('.rm-ev-row').getBoundingClientRect().top + 1;
const panel = __t.q('.rm-panel'), scrolls = panel.scrollHeight > panel.clientHeight;
d.style.height = '170px'; const short = height();
d.style.height = '';
return JSON.stringify({ natural: natural, tall: tall, short: short, below: below, scrolls: scrolls });
""")
check((descSizes["tall"] as? Int) == 360 && (descSizes["short"] as? Int) == 170, "the description field follows the height its resize grip sets", "\(descSizes)")
check((descSizes["below"] as? Bool) == true && (descSizes["scrolls"] as? Bool) == true, "a tall description pushes the evidence down and the panel scrolls", "\(descSizes)")
check(number("document.querySelectorAll('.rm-conn-row').length") == 1 && eval("__t.q('.rm-conn-row .rm-conn-name').textContent").contains("Caching"), "the node's logical connection is listed")

_ = js("__t.q('.rm-ev-source[data-source=\"Package.swift:12\"]').click(); return 'ok';")
expect("a path source sends open with the text as written", ["action": "open", "source": "Package.swift:12"], doc: tabM)
newMark()
_ = js("__t.q('.rm-ev-source[data-source=\"https://swift.org/package-manager\"]').click(); return 'ok';")
expect("a URL source sends open", ["action": "open", "source": "https://swift.org/package-manager"], doc: tabM)
newMark()
_ = js("__t.q('.rm-conn-row .rm-x').click(); return 'ok';")
expect("the × on a connection sends unlink with the pair", ["action": "unlink", "from": "n2", "to": "n5"], doc: tabM)

// An empty selection.
newMark()
_ = js("__t.panning(0, 0); return 'ok';")
check(bool("__t.btn('n2').getAttribute('aria-pressed') === 'false'") && eval("__t.q('.rm-empty').textContent") == "Select a node on the map" && !visible(".rm-panel-body"),
      "clicking the background clears the selection: the panel says to select a node")
_ = js("__t.select('n2'); return 'ok';")

// ---- toolbar status ---------------------------------------------------------------------------------------------------------------
check(!visible(".rm-status"), "a complete map shows no status chip")
let started = Int(Date().timeIntervalSince1970) - 75
deliver("{ status: 'researching', job: { kind: 'research', label: 'Researching the question', step: 'Reading Package.swift', startedAt: \(started) } }")
check(visible(".rm-status") && eval("__t.q('.rm-status').textContent").contains("Reading Package.swift") && eval("__t.q('.rm-status').textContent").contains("Researching the question"),
      "researching: the chip shows the job and its current step", eval("__t.q('.rm-status').textContent"))
check(eval("__t.q('.rm-elapsed').textContent").range(of: #"^1:1\d$"#, options: .regularExpression) != nil, "researching: the elapsed time counts from startedAt", eval("__t.q('.rm-elapsed').textContent"))
check(bool("!!__t.q('.rm-status .rm-spin')"), "researching: a spinner")
newMark()
_ = js("__t.q('.rm-status [data-act=stop]').click(); return 'ok';")
expect("Stop sends cancel", ["action": "cancel"], doc: tabM)
deliver("{ status: 'incomplete', incomplete: 'Stopped after 60 nodes.' }")
check(visible(".rm-status") && eval("__t.q('.rm-status').textContent").contains("Stopped after 60 nodes.") && !bool("!!__t.q('.rm-status .rm-spin')"), "incomplete: the chip shows the reason, no spinner", eval("__t.q('.rm-status').textContent"))
newMark()
_ = js("__t.q('.rm-status [data-act=continue]').click(); return 'ok';")
expect("Continue sends continue", ["action": "continue"], doc: tabM)
deliver()
check(!visible(".rm-status"), "complete again: the chip goes away")
check(visible("[data-act=queries]") && eval("__t.q('[data-act=queries] .rm-count').textContent") == "2", "the web-queries button shows how many searches ran")
_ = js("__t.q('[data-act=queries]').click(); return 'ok';")
check(visible(".rm-popover") && eval("__t.qa('.rm-popover li').map(function(l){return l.textContent;}).join('|')") == "swiftpm resolution time|xcode build cache", "the popover lists the web queries")
_ = js("__t.q('[data-act=queries]').click(); return 'ok';")
check(!visible(".rm-popover"), "the popover closes")

// ---- the node menu and its dialogs ---------------------------------------------------------------------------------------------------
newMark()
_ = js("__t.menu('n3'); return 'ok';")
check(eval("__t.qa('.rm-actions [data-act]').map(function(b){return b.dataset.act;}).join()") == "describe,develop,correct,investigate,add,link,edit,icon,number-children,focus,arrange,delete", "the menu holds the four AI actions first, then add, connect, edit, icon, number children, focus, arrange and delete; there is no move to another branch (BUG-093)")
check(eval("__t.qa('.rm-actions [data-act]').map(function(b){return b.textContent.trim();}).join('|')") == "Expand description|Expand topic…|Correct…|Research|Add child node…|Add logical connection…|Edit title…|Icon…|Number children 1, 2, 3…|Focus on this node|Arrange branch▾|Delete node…", "every action has a visible label (BUG-092/093: icons alone were not enough)")
check(bool("__t.qa('.rm-actions [data-act]').every(function (b) { return !!b.querySelector('svg') && b.title && b.getAttribute('aria-label'); })"), "…and an icon and a tooltip")
check(bool("!__t.q('.rm-actions').closest('.rm-world')"), "the menu is drawn at screen size, outside the zoomed map")
check(bool("(function () { const m = __t.q('.rm-actions').getBoundingClientRect(), l = __t.q('.rm-left').getBoundingClientRect(); return m.left >= l.left && m.right <= l.right + 0.5 && m.top >= l.top && m.bottom <= l.bottom + 0.5; })()"), "the menu stays inside the map area")
let ordinary = json("return JSON.stringify({ off: __t.qa('.rm-actions button').filter(function (b) { return b.disabled; }).map(function (b) { return b.dataset.act; }) });")
check(((ordinary["off"] as? [String]) ?? ["x"]).isEmpty, "an ordinary node has every action enabled", "\(ordinary)")
_ = js("__t.menu('n3'); return 'ok';")
check(!visible(".rm-actions"), "the triangle closes its menu")
_ = js("__t.menu('n1'); return 'ok';")
let rootMenu = json("return JSON.stringify({ off: __t.qa('.rm-actions button').filter(function (b) { return b.disabled; }).map(function (b) { return b.dataset.act; }) });")
check((rootMenu["off"] as? [String]) == ["delete"], "the root cannot be deleted", "\(rootMenu)")
_ = js("document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); return 'ok';")
check(!visible(".rm-actions"), "a click elsewhere closes the menu")

_ = js("__t.menu('n3'); __t.act('add'); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog h2').textContent") == "Add child node" && eval("__t.q('.rm-dialog').textContent").contains("Parent node: Compiler"), "Add child opens a dialog naming the parent")
_ = js("__t.dialogButton('Add'); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog .rm-error').textContent") == "Enter a node name.", "an empty name is refused inside the dialog")
expectNone("…and nothing is sent", action: "addChild", wait: 0.3)
_ = js("__t.type(__t.q('.rm-dialog input'), '  Cache layers '); __t.dialogButton('Add'); return 'ok';")
expect("Add sends addChild with the parent and the trimmed title", ["action": "addChild", "parent": "n3", "title": "Cache layers"], doc: tabM)
check(!visible(".rm-dialog"), "the dialog closes after Add")

newMark()
_ = js("__t.menu('n3'); __t.act('develop'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Expand topic", "Expand topic opens its dialog")
_ = js("__t.dialogButton('Expand'); return 'ok';")
expect("an empty direction is allowed: the AI chooses the sub-topics", ["action": "develop", "id": "n3", "direction": ""], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('develop'); __t.type(__t.q('.rm-dialog input'), 'compare the options'); __t.dialogButton('Expand'); return 'ok';")
expect("Expand topic sends the direction in words", ["action": "develop", "id": "n3", "direction": "compare the options"], doc: tabM)

newMark()
_ = js("__t.menu('n3'); __t.act('edit'); return 'ok';")
check(eval("__t.q('.rm-dialog input').value") == "Compiler", "Edit opens a dialog with the current title")
_ = js("__t.type(__t.q('.rm-dialog input'), 'Compiler front end'); __t.dialogButton('Save'); return 'ok';")
expect("Edit sends update with the new title", ["action": "update", "id": "n3", "title": "Compiler front end"], doc: tabM)

newMark()
_ = js("__t.menu('n6'); __t.act('link'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Add logical connection" && eval("__t.q('.rm-dialog select[aria-label=\"First node\"]').value") == "n6", "the connection dialog starts from the node it was opened on")
_ = js("__t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n6'; __t.dialogButton('Add'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "Select two different nodes.", "a connection to itself is refused")
_ = js("__t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n8'; __t.dialogButton('Add'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "This connection already exists.", "a repeated connection is refused")
_ = js("__t.q('.rm-dialog select[aria-label=\"First node\"]').value = 'n8'; __t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n6'; __t.dialogButton('Add'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "This connection already exists.", "…also in the other direction")
expectNone("…nothing was sent so far", action: "link", wait: 0.3)
_ = js("__t.q('.rm-dialog select[aria-label=\"First node\"]').value = 'n4'; __t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n5'; __t.dialogButton('Add'); return 'ok';")
expect("Add sends link with both ends", ["action": "link", "from": "n4", "to": "n5"], doc: tabM)

newMark()
_ = js("__t.menu('n2'); return 'ok';")
check(!bool("!!__t.q('.rm-actions [data-act=move]')"), "there is no Move to another branch action any more (DEC-010)")
_ = js("__t.menu('n2'); return 'ok';")

// ---- AI actions on a node (REQ-006) -------------------------------------------------------------------------------------------------
newMark()
_ = js("__t.menu('n3'); __t.act('describe'); return 'ok';")
expect("Expand description sends describe at once, with the node", ["action": "describe", "id": "n3"], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('investigate'); return 'ok';")
expect("Research sends investigate at once, with the node", ["action": "investigate", "id": "n3"], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('correct'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Correct node" && bool("__t.q('.rm-dialog textarea') !== null"), "Correct opens a dialog with a text area for the person's note")
_ = js("__t.dialogButton('Correct'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "Say what is wrong with this node.", "an empty note is refused")
expectNone("…and nothing is sent", action: "correct", wait: 0.3)
_ = js("__t.type(__t.q('.rm-dialog textarea'), 'The cache is not LRU'); __t.dialogButton('Correct'); return 'ok';")
expect("Correct sends the note", ["action": "correct", "id": "n3", "note": "The cache is not LRU"], doc: tabM)

_ = js("__t.select('n2'); return 'ok';")
check(eval("__t.qa('.rm-ai [data-act]').map(function(b){return b.textContent.trim();}).join('|')") == "Expand description|Expand topic|Correct|Research", "the properties panel shows the four AI actions as labelled buttons")
newMark()
_ = js("__t.q('.rm-ai [data-act=describe]').click(); return 'ok';")
expect("the panel's Expand description acts on the selected node", ["action": "describe", "id": "n2"], doc: tabM)
newMark()
_ = js("__t.q('.rm-ai [data-act=investigate]').click(); return 'ok';")
expect("the panel's Research acts on the selected node", ["action": "investigate", "id": "n2"], doc: tabM)
newMark()
_ = js("__t.q('.rm-ai [data-act=develop]').click(); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Expand topic", "the panel's Expand topic opens the same dialog")
_ = js("__t.dialogButton('Cancel'); return 'ok';")
deliver("{ status: 'researching', job: { kind: 'describe', label: 'Expand description: Dependencies', step: 'Reading', startedAt: \(Int(Date().timeIntervalSince1970)) } }")
check(bool("__t.qa('.rm-ai-btn').every(function (b) { return b.disabled; })") && eval("__t.q('.rm-ai-note').textContent").contains("already working"), "while a job runs, the AI buttons are off and say why")
_ = js("__t.menu('n3'); return 'ok';")
check(bool("__t.qa('.rm-actions .rm-item.ai').every(function (b) { return b.disabled; })"), "…and so are the AI items of the node menu")
_ = js("__t.menu('n3'); return 'ok';")
deliver()
check(bool("__t.qa('.rm-ai-btn').every(function (b) { return !b.disabled; })"), "when the job is over the buttons are back")

// ---- icons and numbers on a node (REQ-008, DEC-011) -------------------------------------------------------------------------------
let swiftSource = (try? String(contentsOfFile: editor + "/../../Models/ResearchMapDocument.swift", encoding: .utf8)) ?? ""
let swiftIcons: [String] = {
    guard let start = swiftSource.range(of: "static let iconIDs = ["), let end = swiftSource.range(of: "]", range: start.upperBound..<swiftSource.endIndex) else { return [] }
    return swiftSource[start.upperBound..<end.lowerBound].components(separatedBy: CharacterSet(charactersIn: ", \n\"")).filter { !$0.isEmpty }
}()
check(swiftIcons.count == 41, "the built-in icon ids were read from ResearchMapDocument.swift", "\(swiftIcons)")
let pageIcons = (try? JSONSerialization.jsonObject(with: Data(eval("JSON.stringify(window.MVResearchMap.iconIDs())").utf8)) as? [String]) ?? []
check(pageIcons == swiftIcons, "the page draws exactly the icons Swift accepts, in the same order", "swift \(swiftIcons) page \(pageIcons)")

newMark()
check(bool("__t.qa('.rm-lead').every(function (l) { return l.hidden; })") && bool("__t.qa('.rm-badge, .rm-glyph').every(function (e) { return e.hidden; })"), "a node without icon and number shows neither")
deliver("{ nodes: (function () { const s = __t.snap(); const set = function (id, extra) { Object.assign(s.nodes.find(function (n) { return n.id === id; }), extra); }; set('n3', { number: 3, icon: 'bug' }); set('n4', { number: 12 }); set('n5', { icon: '🔥' }); set('n2', { number: 1, icon: 'rocket', color: '#ffee88' }); return s.nodes; })() }")
func nodeLead(_ id: String) -> [String: Any] { json("const e = __t.btn('\(id)'); const l = e.querySelector('.rm-lead'), b = e.querySelector('.rm-badge'), g = e.querySelector('.rm-glyph'); return JSON.stringify({ lead: !l.hidden, badge: b.hidden ? '' : b.textContent, glyph: g.hidden ? '' : (g.querySelector('svg') ? 'svg' : g.textContent), label: e.querySelector('.rm-label').textContent, aria: e.getAttribute('aria-label') });") }
let leadBoth = nodeLead("n3"), leadNumber = nodeLead("n4"), leadEmoji = nodeLead("n5")
check((leadBoth["badge"] as? String) == "3" && (leadBoth["glyph"] as? String) == "svg" && (leadBoth["label"] as? String) == "Compiler", "a node shows its number badge and icon before the title", "\(leadBoth)")
check((leadNumber["badge"] as? String) == "12" && (leadNumber["glyph"] as? String) == "", "a number alone shows only the badge", "\(leadNumber)")
check((leadEmoji["badge"] as? String) == "" && (leadEmoji["glyph"] as? String) == "🔥", "an emoji icon is drawn as text", "\(leadEmoji)")
check(((leadBoth["aria"] as? String) ?? "").hasPrefix("Number 3. bug icon. Compiler"), "a screen reader hears the number and the icon first", "\(leadBoth)")
check(eval("__t.btn('n3').querySelector('.rm-glyph svg path').getAttribute('d')").hasPrefix("M9 7a3 3 0 0 1 6 0"), "a built-in icon is its own drawing")
let badgeLook = json("const b = getComputedStyle(__t.btn('n3').querySelector('.rm-badge')), g = getComputedStyle(__t.btn('n3').querySelector('.rm-glyph')), c = getComputedStyle(__t.btn('n2').querySelector('.rm-badge')); return JSON.stringify({ bg: b.backgroundColor, ink: b.color, glyph: g.color, customBg: c.backgroundColor, customInk: c.color });")
check((badgeLook["bg"] as? String) == "rgb(78, 201, 176)" && (badgeLook["ink"] as? String) == "rgb(30, 30, 30)" && (badgeLook["glyph"] as? String) == "rgb(78, 201, 176)", "the badge and the icon take the branch colour; the badge text is dark on it (dark theme)", "\(badgeLook)")
check((badgeLook["customBg"] as? String) == "rgb(255, 238, 136)" && (badgeLook["customInk"] as? String) == "rgb(30, 30, 30)", "on a node with its own light colour the badge is that colour with dark text", "\(badgeLook)")
_ = js("document.documentElement.setAttribute('data-theme', 'light'); return 'ok';")
check(eval("getComputedStyle(__t.btn('n3').querySelector('.rm-badge')).color") == "rgb(255, 255, 255)", "light theme: white text on the darker branch colour")
_ = js("document.documentElement.removeAttribute('data-theme'); return 'ok';")
check(bool("(function () { const b = __t.btn('n3'), l = b.querySelector('.rm-lead').getBoundingClientRect(), r = b.getBoundingClientRect(); return l.left >= r.left && l.right <= r.right && l.top >= r.top && l.bottom <= r.bottom; })()"), "the badge and icon sit inside the node card")
check(bool("(function () { const b = __t.btn('n3'), t = b.querySelector('.rm-label').getBoundingClientRect(), l = b.querySelector('.rm-lead').getBoundingClientRect(); return l.right <= t.left + 1; })()"), "they come before the title, not over it")

// The panel: icon button, number field.
_ = js("__t.select('n3'); return 'ok';")
check(eval("__t.q('.rm-icon-pick').textContent.trim()") == "Bug" && bool("!__t.q('[data-act=icon-clear]').hidden") && eval("__t.q('.rm-number-input').value") == "3", "the panel shows the node's icon name and number")
_ = js("__t.select('n5'); return 'ok';")
check(eval("__t.q('.rm-icon-pick').textContent.trim()").hasSuffix("Emoji") && eval("__t.q('.rm-number-input').value") == "", "an emoji icon shows as Emoji; no number shows an empty field")
_ = js("__t.select('n6'); return 'ok';")
check(eval("__t.q('.rm-icon-pick').textContent.trim()") == "None" && bool("__t.q('[data-act=icon-clear]').hidden"), "a node without an icon says None and offers no remove button")
newMark()
_ = js("__t.type(__t.q('.rm-number-input'), '5'); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("typing a number sends update with the integer", ["action": "update", "id": "n6", "number": 5], doc: tabM)
newMark()
_ = js("__t.select('n3'); __t.type(__t.q('.rm-number-input'), ''); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("emptying the field removes the number (null)", ["action": "update", "id": "n3", "number": NSNull()], doc: tabM)
newMark()
_ = js("__t.type(__t.q('.rm-number-input'), '0'); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expectNone("0 is not sent", action: "update", wait: 0.5)
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent").contains("between 1 and 999") && eval("__t.q('.rm-number-input').value") == "3", "…the person is told, and the field shows the stored number again")
newMark()
_ = js("__t.type(__t.q('.rm-number-input'), '1000'); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expectNone("1000 is not sent either", action: "update", wait: 0.5)

// The icon dialog.
newMark()
_ = js("__t.q('[data-act=icon]').click(); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent").hasPrefix("Icon for") && number("document.querySelectorAll('.rm-icongrid button').length") == 41, "the icon button opens a dialog with the 41 built-in icons")
check(bool("__t.q('.rm-icongrid button[data-icon=bug]').getAttribute('aria-pressed') === 'true' && __t.qa('.rm-icongrid button[aria-pressed=true]').length === 1"), "the node's current icon is marked in the grid")
check(bool("__t.qa('.rm-icongrid button').every(function (b) { return !!b.querySelector('svg path') && b.title && b.getAttribute('aria-label'); })"), "every icon has a drawing and a name")
_ = js("__t.q('.rm-icongrid button[data-icon=lock]').click(); return 'ok';")
expect("choosing an icon sends update with its id and closes the dialog", ["action": "update", "id": "n3", "icon": "lock"], doc: tabM)
check(!visible(".rm-dialog"), "the dialog is closed")
newMark()
_ = js("__t.q('[data-act=icon]').click(); __t.type(__t.q('.rm-dialog input'), 'ab'); __t.dialogButton('Use emoji'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent").contains("one emoji"), "text that is not an emoji is refused in the dialog")
expectNone("…and not sent", action: "update", wait: 0.4)
_ = js("__t.type(__t.q('.rm-dialog input'), '🔥'); __t.dialogButton('Use emoji'); return 'ok';")
expect("an emoji is sent as it is", ["action": "update", "id": "n3", "icon": "🔥"], doc: tabM)
newMark()
_ = js("__t.q('[data-act=icon]').click(); __t.dialogButton('Remove icon'); return 'ok';")
expect("Remove icon in the dialog clears it", ["action": "update", "id": "n3", "icon": ""], doc: tabM)
newMark()
_ = js("__t.q('[data-act=icon-clear]').click(); return 'ok';")
expect("the × beside the icon clears it too", ["action": "update", "id": "n3", "icon": ""], doc: tabM)

// The node menu: Icon… and Number children.
newMark()
_ = js("__t.menu('n6'); return 'ok';")
check(bool("__t.q('.rm-actions [data-act=number-children]').disabled"), "Number children is off for a node without children")
_ = js("__t.menu('n6'); return 'ok';")
newMark()
_ = js("__t.menu('n1'); __t.act('number-children'); return 'ok';")
expect("Number children sends numberChildren for the node", ["action": "numberChildren", "id": "n1", "clear": false], doc: tabM)
deliver("{ nodes: (function () { const s = __t.snap(); ['n2', 'n3', 'n4', 'n5'].forEach(function (id, i) { s.nodes.find(function (n) { return n.id === id; }).number = i + 1; }); return s.nodes; })() }")
_ = js("__t.menu('n1'); return 'ok';")
check(eval("__t.q('.rm-actions [data-act=number-children]').textContent.trim()") == "Remove numbers from children", "when the children are numbered 1…n the action offers to remove the numbers")
newMark()
_ = js("__t.act('number-children'); return 'ok';")
expect("…and sends clear", ["action": "numberChildren", "id": "n1", "clear": true], doc: tabM)
newMark()
_ = js("__t.menu('n6'); __t.act('icon'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent").hasPrefix("Icon for") && bool("__t.btn('n6').getAttribute('aria-pressed') === 'true'"), "Icon… in the node menu selects the node and opens the dialog")
_ = js("__t.dialogButton('Cancel'); return 'ok';")
deliver()

// ---- shape and size of a node (REQ-009, DEC-012) -------------------------------------------------------------------------------------
// Editing a title in the panel must not rebuild the node card: the badge and the icon stay (a 5.31.0 regression).
deliver("{ nodes: __t.look({ n3: { number: 3, icon: 'bug' } }).nodes }")
_ = js("__t.select('n3'); __t.type(__t.q('.rm-title-input'), 'Compiler flags'); return 'ok';")
check(bool("(function () { const b = __t.btn('n3'); return b.querySelector('.rm-label').textContent === 'Compiler flags' && b.querySelector('.rm-badge').textContent === '3' && !b.querySelector('.rm-glyph').hidden && !b.querySelector('.rm-lead').hidden; })()"), "editing a title keeps the node's number badge and icon (5.31.0 regression)", eval("__t.btn('n3').outerHTML"))
_ = js("__t.select('n6'); return 'ok';")
deliver()

let swiftShapes: [String] = {
    guard let start = swiftSource.range(of: "static let shapes: [(id: String, name: String)] = ["), let end = swiftSource.range(of: "]", range: start.upperBound..<swiftSource.endIndex) else { return [] }
    return swiftSource[start.upperBound..<end.lowerBound].components(separatedBy: "(\"").dropFirst().map { String($0.prefix(while: { $0 != "\"" })) }
}()
let pageShapes = (try? JSONSerialization.jsonObject(with: Data(eval("JSON.stringify(window.MVResearchMap.shapeIDs())").utf8)) as? [String]) ?? []
check(swiftShapes.count == 5 && pageShapes == swiftShapes, "the page draws exactly the shapes Swift accepts, in the same order", "swift \(swiftShapes) page \(pageShapes)")
check(swiftSource.contains("widthRange = 60...800") && swiftSource.contains("heightRange = 28...600") && eval("JSON.stringify(window.MVResearchMap.sizeLimits())") == "{\"width\":[60,800],\"height\":[28,600]}", "the page's default limits equal Swift's")
deliver("{ sizeLimits: { width: [50, 700], height: [20, 500] } }")
check(eval("JSON.stringify(window.MVResearchMap.sizeLimits())") == "{\"width\":[50,700],\"height\":[20,500]}", "the limits of the snapshot replace the page's defaults")
deliver()
check(eval("JSON.stringify(window.MVResearchMap.sizeLimits())") == "{\"width\":[60,800],\"height\":[28,600]}", "…and the next snapshot restores them")

// The panel: five shapes, Auto/S/M/L, Width and Height.
_ = js("__t.select('n3'); return 'ok';")
check(eval("__t.qa('.rm-seg [data-shape]').map(function (b) { return b.getAttribute('data-shape'); }).join()") == "rounded,rectangle,pill,ellipse,diamond", "the panel offers the five shapes in order")
check(eval("__t.qa('.rm-seg [data-shape][aria-pressed=true]').map(function (b) { return b.getAttribute('data-shape'); }).join()") == "rounded" && bool("__t.qa('.rm-seg [data-shape]').every(function (b) { return !!b.querySelector('svg path') && b.title && b.getAttribute('aria-label'); })"), "a plain node shows Rounded as its shape; every shape button has a drawing and a name")
check(bool("__t.q('[data-size=auto]').getAttribute('aria-pressed') === 'true' && __t.q('[data-dim=width]').value === '' && __t.q('[data-dim=height]').value === '' && __t.q('[data-dim=width]').placeholder === 'Auto'"), "a plain node shows Auto with empty Width and Height fields")
newMark()
_ = js("__t.q('[data-shape=ellipse]').click(); return 'ok';")
expect("choosing a shape sends update with its id", ["action": "update", "id": "n3", "shape": "ellipse"], doc: tabM)
newMark()
_ = js("__t.q('[data-shape=rounded]').click(); return 'ok';")
expect("choosing the rounded rectangle sends an empty shape (the default is never stored)", ["action": "update", "id": "n3", "shape": ""], doc: tabM)
for (preset, w, h) in [("s", 140, 44), ("m", 220, 64), ("l", 320, 96)] {
    newMark()
    _ = js("__t.q('[data-size=\(preset)]').click(); return 'ok';")
    expect("the \(preset.uppercased()) preset sends its width and height", ["action": "update", "id": "n3", "width": w, "height": h], doc: tabM)
}
newMark()
_ = js("__t.q('[data-size=auto]').click(); return 'ok';")
expect("Auto clears the width and the height (null)", ["action": "update", "id": "n3", "width": NSNull(), "height": NSNull()], doc: tabM)
newMark()
_ = js("__t.type(__t.q('[data-dim=width]'), '300'); __t.q('[data-dim=width]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("typing a width sends only the width", ["action": "update", "id": "n3", "width": 300], doc: tabM)
newMark()
_ = js("__t.type(__t.q('[data-dim=height]'), '90'); __t.q('[data-dim=height]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("typing a height sends only the height", ["action": "update", "id": "n3", "height": 90], doc: tabM)
for (field, value) in [("width", "59"), ("width", "801"), ("width", "0"), ("height", "27"), ("height", "601")] {
    newMark()
    _ = js("__t.type(__t.q('[data-dim=\(field)]'), '\(value)'); __t.q('[data-dim=\(field)]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
    expectNone("a \(field) of \(value) is not sent", action: "update", wait: 0.3)
}
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent") == "A height is between 28 and 600." && eval("__t.q('[data-dim=height]').value") == "", "…the person is told the limits, and the field shows the stored value again")
deliver("{ nodes: __t.look({ n3: { width: 300 } }).nodes }")
newMark()
_ = js("__t.type(__t.q('[data-dim=width]'), ''); __t.q('[data-dim=width]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("emptying the width field makes the width automatic (null)", ["action": "update", "id": "n3", "width": NSNull()], doc: tabM)
_ = js("document.activeElement.blur(); return 'ok';")
deliver("{ nodes: __t.look({ n3: { width: 140, height: 44 }, n4: { width: 220, height: 64 } }).nodes }")
check(bool("__t.q('[data-size=s]').getAttribute('aria-pressed') === 'true' && __t.q('[data-size=auto]').getAttribute('aria-pressed') === 'false' && __t.q('[data-dim=width]').value === '140' && __t.q('[data-dim=height]').value === '44'"), "a node that has a preset's size shows that preset and the numbers")
_ = js("__t.select('n4'); return 'ok';")
check(bool("__t.q('[data-size=m]').getAttribute('aria-pressed') === 'true'"), "…and another node shows its own")
deliver()

// What the cards look like.
let longEllipse = "Whole module optimisation of everything in the project"
let longDiamond = "Incremental builds with a rather long name"
deliver("{ nodes: __t.look({ n2: { shape: 'diamond' }, n3: { shape: 'ellipse', width: 260 }, n4: { shape: 'pill' }, n5: { shape: 'rectangle', height: 120 }, n6: { width: 300 }, n7: { height: 90 }, n9: { shape: 'ellipse', title: '\(longEllipse)' }, n8: { shape: 'diamond', title: '\(longDiamond)' }, n10: { width: 100, height: 28, title: 'A title that needs several lines' } }).nodes }")
check(eval("['n1','n2','n3','n4','n5','n6','n7','n8','n9','n10','n11','n12'].map(function (id) { return __t.wrap(id).className.split(' ').filter(function (c) { return c.indexOf('shape-') === 0; }).join('') || '-'; }).join()") == "-,shape-diamond,shape-ellipse,shape-pill,shape-rectangle,-,-,shape-diamond,shape-ellipse,-,-,-", "each node's wrap names its shape; a rounded rectangle has no shape class")
let shapeLook = json("""
const radius = function (id) { return getComputedStyle(__t.btn(id)).borderTopLeftRadius; };
const dia = __t.btn('n2');
return JSON.stringify({ ellipse: radius('n3'), pill: radius('n4'), rect: radius('n5'), rounded: radius('n11'),
  polygon: !!dia.querySelector('.rm-shape polygon'), diaBg: getComputedStyle(dia).backgroundColor, diaBorder: getComputedStyle(dia).borderTopWidth, diaShadow: getComputedStyle(dia).boxShadow,
  stroke: getComputedStyle(dia.querySelector('polygon')).stroke, fill: getComputedStyle(dia.querySelector('polygon')).fill, rectBorder: getComputedStyle(__t.btn('n5')).borderLeftWidth, ellBorder: getComputedStyle(__t.btn('n3')).borderTopWidth, ellColour: getComputedStyle(__t.btn('n3')).borderTopColor,
  noSvg: !__t.btn('n3').querySelector('.rm-shape') });
""")
check((shapeLook["ellipse"] as? String) == "50%" && ((shapeLook["pill"] as? String) ?? "").hasPrefix("999") && (shapeLook["rect"] as? String) == "0px" && (shapeLook["rounded"] as? String) == "6px", "ellipse, pill, rectangle and rounded have their corners", "\(shapeLook)")
check((shapeLook["polygon"] as? Bool) == true && (shapeLook["diaBg"] as? String) == "rgba(0, 0, 0, 0)" && (shapeLook["diaBorder"] as? String) == "0px" && (shapeLook["noSvg"] as? Bool) == true, "a diamond is an SVG polygon on a transparent card; no other shape has one", "\(shapeLook)")
check((shapeLook["stroke"] as? String) == "rgb(86, 156, 214)" && (shapeLook["fill"] as? String) == "rgb(37, 37, 38)" && (shapeLook["rectBorder"] as? String) == "3px" && ["1px", "1.5px"].contains((shapeLook["ellBorder"] as? String) ?? "") && (shapeLook["ellColour"] as? String) == "rgb(78, 201, 176)", "the diamond is outlined in its branch colour on the card colour; the rectangle keeps the 3px branch stripe; the ellipse is outlined in its branch colour", "\(shapeLook)")
check(bool("__t.box('n3').w === 260") && bool("__t.box('n6').w === 300") && bool("__t.box('n5').h === 120") && bool("__t.box('n7').h === 90"), "a given width is exact and a given height is the height of a short title's card", eval("JSON.stringify(['n3','n6','n5','n7'].map(function (id) { return __t.box(id); }))"))
check(bool("(function () { const b = __t.btn('n10'), body = b.querySelector('.rm-body'); return __t.box('n10').w === 100 && __t.box('n10').h > 28 && body.getBoundingClientRect().height <= b.clientHeight + 1 && b.scrollHeight <= b.clientHeight + 1; })()"), "a height below the title's is a floor: the card grows and nothing is cut", eval("JSON.stringify(__t.box('n10'))"))
let inscribed = json("""
const inside = function (id, kind) {
  const b = __t.btn(id).getBoundingClientRect(), t = __t.btn(id).querySelector('.rm-body').getBoundingClientRect();
  const a = b.width / 2, c = b.height / 2, cx = b.left + a, cy = b.top + c;
  return [[t.left, t.top], [t.right, t.top], [t.left, t.bottom], [t.right, t.bottom]].map(function (p) {
    const dx = Math.abs(p[0] - cx) / a, dy = Math.abs(p[1] - cy) / c;
    return kind === 'ellipse' ? dx * dx + dy * dy : dx + dy;
  }).reduce(function (m, v) { return Math.max(m, v); }, 0);
};
return JSON.stringify({ ellipse: inside('n9', 'ellipse'), diamond: inside('n8', 'diamond'), shortEllipse: inside('n3', 'ellipse'), shortDiamond: inside('n2', 'diamond') });
""")
check(((inscribed["ellipse"] as? Double) ?? 9) <= 1.03 && ((inscribed["diamond"] as? Double) ?? 9) <= 1.03 && ((inscribed["shortEllipse"] as? Double) ?? 9) <= 1.03 && ((inscribed["shortDiamond"] as? Double) ?? 9) <= 1.03, "in an ellipse and a diamond the whole title lies inside the outline", "\(inscribed)")
check(bool("__t.box('n9').h > 60 && __t.box('n8').h > 90"), "a long title makes a bigger ellipse and diamond (it wraps, it is not squeezed)", eval("JSON.stringify([__t.box('n9'), __t.box('n8')])"))
let overlaps = json("""
const ids = Array.from(document.querySelectorAll('.rm-node-wrap')).filter(function (w) { return !w.hidden; }).map(function (w) { return w.getAttribute('data-id'); });
const boxes = ids.map(function (id) { return Object.assign({ id: id }, __t.box(id)); });
const bad = [];
for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
  const a = boxes[i], b = boxes[j];
  if (a.l < b.r - 0.5 && b.l < a.r - 0.5 && a.t < b.b - 0.5 && b.t < a.b - 0.5) bad.push(a.id + '/' + b.id);
}
return JSON.stringify({ count: ids.length, bad: bad });
""")
check((overlaps["count"] as? Int) == 12 && ((overlaps["bad"] as? [String]) ?? ["?"]).isEmpty, "with ellipses, diamonds, pills and sized cards among them no two nodes overlap", "\(overlaps)")
let tri = json("""
const near = function (id, kind) {
  const b = __t.btn(id).getBoundingClientRect(), t = __t.q('.rm-node-wrap[data-id="' + id + '"] .rm-tri').getBoundingClientRect();
  const a = b.width / 2, c = b.height / 2, dx = Math.abs(t.left + t.width / 2 - (b.left + a)) / a, dy = Math.abs(t.top + t.height / 2 - (b.top + c)) / c;
  return kind === 'ellipse' ? dx * dx + dy * dy : (kind === 'diamond' ? dx + dy : 0);
};
return JSON.stringify({ ellipse: near('n3', 'ellipse'), diamond: near('n2', 'diamond') });
""")
check(((tri["ellipse"] as? Double) ?? 9) <= 1.05 && ((tri["diamond"] as? Double) ?? 9) <= 1.05, "the ⋯ button of an ellipse and of a diamond sits on the shape, not in the empty corner of its box", "\(tri)")
check(bool("(function () { const f = __t.fold('n2').getBoundingClientRect(), b = __t.btn('n2').getBoundingClientRect(); return !__t.fold('n2').hidden && Math.abs((f.left + f.width / 2) - (b.left + b.width / 2)) < 2 && f.top < b.bottom + 1 && f.bottom > b.bottom - 1; })()"), "the fold toggle sits on the bottom corner of a diamond")
_ = js("__t.menu('n3'); return 'ok';")
check(visible(".rm-actions") && bool("__t.qa('.rm-actions [data-act]').length > 5"), "the node menu opens from an ellipse")
_ = js("__t.menu('n3'); return 'ok';")
check(!visible(".rm-actions"), "…and closes again")
// Handles.
_ = js("__t.select('n3'); return 'ok';")
check(number("document.querySelectorAll('.rm-handle:not([hidden])').length") == 8 && bool("__t.qa('.rm-handle:not([hidden])').every(function (h) { return h.parentNode === __t.wrap('n3'); })"), "the selected node shows eight resize handles and no other node does")
check(bool("['nw','n','ne','e','se','s','sw','w'].every(function (d) { return !!__t.handle('n3', d); })"), "…at the four corners and the four edges")
_ = js("__t.select('n4'); return 'ok';")
check(number("document.querySelectorAll('.rm-handle:not([hidden])').length") == 8 && bool("__t.qa('.rm-handle:not([hidden])').every(function (h) { return h.parentNode === __t.wrap('n4'); })"), "selecting another node moves the handles to it")

// Dragging a handle: live, around the centre, one update on release.
func shapedLook(n3: String = "shape: 'ellipse', width: 260", n5: String = "shape: 'rectangle', height: 120", n6: String = "width: 300") -> String {
    "{ nodes: __t.look({ n2: { shape: 'diamond' }, n3: { \(n3) }, n4: { shape: 'pill' }, n5: { \(n5) }, n6: { \(n6) } }).nodes }"
}
_ = js("__t.select('n3'); return 'ok';")
newMark()
let handleViewBefore = js("return JSON.stringify(__t.view());")
_ = js("__t.resizeStart('n3', 'e'); __t.dragTo(40, 0); return 'ok';")
check(bool("__t.box('n3').w === 340"), "dragging the east handle by 40 px makes the node 80 px wider (it grows around its centre)", eval("JSON.stringify(__t.box('n3'))"))
check(eval("__t.q('.rm-readout').textContent").hasPrefix("w 340") && visible(".rm-readout"), "a readout shows the size while dragging", eval("__t.q('.rm-readout').textContent"))
expectNone("nothing is sent while the handle moves", action: "update", wait: 0.3)
_ = js("__t.dragEnd(40, 0); return 'ok';")
expect("releasing sends one update with the width", ["action": "update", "id": "n3", "width": 340], doc: tabM)
expectNone("a handle never moves the node", action: "moveVisual", wait: 0.2)
check(js("return JSON.stringify(__t.view());") == handleViewBefore && !visible(".rm-readout"), "…nor pans the map; the readout is gone")
check(bool("__t.box('n3').w === 340"), "until Swift answers the node keeps the new size")
deliver(shapedLook(n3: "shape: 'ellipse', width: 340"))
check(bool("__t.box('n3').w === 340") && eval("__t.q('[data-dim=width]').value") == "340", "…and the snapshot confirms it in the card and in the Width field")
newMark()
_ = js("__t.resizeStart('n3', 'w'); __t.dragTo(-30, 0); return 'ok';")
check(bool("__t.box('n3').w === 400"), "dragging the west handle outwards grows the node too", eval("JSON.stringify(__t.box('n3'))"))
_ = js("__t.dragEnd(-30, 0); return 'ok';")
expect("…and sends the width", ["action": "update", "id": "n3", "width": 400], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400"))
newMark()
_ = js("__t.resizeStart('n3', 'e'); __t.dragTo(5000, 0); return 'ok';")
check(bool("__t.box('n3').w === 800"), "a width cannot go above the limit", eval("JSON.stringify(__t.box('n3'))"))
_ = js("__t.dragTo(-5000, 0); return 'ok';")
check(bool("__t.box('n3').w >= 60 && __t.box('n3').w < 100"), "…nor below the limit (the node is as narrow as its title allows)", eval("JSON.stringify(__t.box('n3'))"))
_ = js("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); __t.dragEnd(-5000, 0); return 'ok';")
check(bool("__t.box('n3').w === 400"), "Esc during the drag puts the size back")
expectNone("…and sends nothing", action: "update", wait: 0.3)
_ = js("__t.resizeStart('n3', 'e'); __t.dragEnd(1, 1); return 'ok';")
expectNone("a click on a handle (no movement) sends nothing", action: "update", wait: 0.3)

// Height: a floor, and a height at or below the title's is automatic.
_ = js("__t.select('n5'); return 'ok';")
newMark()
_ = js("__t.resizeStart('n5', 's'); __t.dragTo(0, 40); return 'ok';")
check(bool("__t.box('n5').h === 200"), "dragging the south handle by 40 px makes a node 80 px taller", eval("JSON.stringify(__t.box('n5'))"))
_ = js("__t.dragEnd(0, 40); return 'ok';")
expect("…and sends the height", ["action": "update", "id": "n5", "height": 200], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400", n5: "shape: 'rectangle', height: 200"))
newMark()
_ = js("__t.resizeStart('n5', 'n'); __t.dragTo(0, 500); return 'ok';")
check(bool("__t.box('n5').h < 60"), "dragging the north handle down shrinks the node to the height of its title, no further", eval("JSON.stringify(__t.box('n5'))"))
_ = js("__t.dragEnd(0, 500); return 'ok';")
expect("a height at or below the title's is sent as automatic (null)", ["action": "update", "id": "n5", "height": NSNull()], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400", n5: "shape: 'rectangle'"))
// A corner changes both.
_ = js("__t.select('n6'); return 'ok';")
newMark()
let n6Before = json("return JSON.stringify(__t.box('n6'));")
_ = js("__t.resizeStart('n6', 'se'); __t.dragTo(20, 30); __t.dragEnd(20, 30); return 'ok';")
let expectedHeight = Int((n6Before["h"] as? Double) ?? 0) + 60
expect("a corner handle sends the width and the height", ["action": "update", "id": "n6", "width": 340, "height": expectedHeight], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400", n5: "shape: 'rectangle'", n6: "width: 340, height: \(expectedHeight)"))
// A double click on a handle makes the size automatic.
newMark()
_ = js("__t.handle('n6', 'e').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return 'ok';")
expect("a double click on a handle sends automatic width and height", ["action": "update", "id": "n6", "width": NSNull(), "height": NSNull()], doc: tabM)
check(bool("__t.box('n6').w < 200"), "…and the card is automatic at once")
deliver()
newMark()
_ = js("__t.handle('n6', 'e').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return 'ok';")
expectNone("a double click on a node that is already automatic sends nothing", action: "update", wait: 0.3)
// Zoom: the handles keep their size on the screen.
_ = js("for (let i = 0; i < 3; i++) __t.q('[data-act=zoom-out]').click(); return 'ok';")
check(bool("(function () { const s = window.MVResearchMap.viewState().scale, h = __t.handle('n6', 'se').getBoundingClientRect(); return s < 0.8 && Math.abs(h.width - 10) < 1.5; })()"), "the corner handles stay 10 px on the screen when the map is zoomed out")
_ = js("__t.q('[data-act=centre]').click(); return 'ok';")
// Light theme: the diamond follows the theme.
deliver("{ nodes: __t.look({ n2: { shape: 'diamond' } }).nodes }")
_ = js("document.documentElement.setAttribute('data-theme', 'light'); return 'ok';")
check(eval("getComputedStyle(__t.btn('n2').querySelector('polygon')).fill") != "rgb(37, 37, 38)", "light theme: the diamond is not drawn in the dark card colour", eval("getComputedStyle(__t.btn('n2').querySelector('polygon')).fill"))
_ = js("document.documentElement.removeAttribute('data-theme'); return 'ok';")
// A node can go back to the plain look.
deliver()
check(bool("!__t.btn('n2').querySelector('.rm-shape') && __t.qa('.rm-node-wrap').every(function (w) { return w.className.indexOf('shape-') < 0 && !w.style.width; }) && __t.qa('.rm-node').every(function (b) { return !b.style.minHeight; })"), "a snapshot without shapes and sizes restores the plain cards")
deliver("{ nodes: __t.look({ n1: { shape: 'pill', width: 320 } }).nodes }")
check(bool("__t.wrap('n1').classList.contains('shape-pill') && __t.btn('n1').classList.contains('root') && __t.box('n1').w === 320"), "the root can have a shape and a size too")
deliver()
_ = js("__t.select('n6'); return 'ok';")

// ---- folding (BUG-092, DEC-010) ------------------------------------------------------------------------------------------------------
newMark()
check(bool("__t.fold('n1').hidden") && bool("__t.fold('n6').hidden") && !bool("__t.fold('n2').hidden"), "a node with children has a fold toggle; a leaf and the root have none")
check(bool("__t.shown('n6') && __t.shown('n7')"), "everything is shown at first")
_ = js("__t.fold('n2').click(); return 'ok';")
check(bool("!__t.shown('n6') && !__t.shown('n7') && __t.shown('n2') && __t.shown('n3')"), "folding a node hides its children and nothing else")
check(eval("__t.fold('n2').textContent") == "+2" && bool("__t.fold('n2').getAttribute('aria-expanded') === 'false'") && bool("__t.fold('n2').classList.contains('folded')"), "a folded node says how many nodes it hides")
check(number("document.querySelectorAll('path[data-line=tree]').length") == 9, "the lines into hidden nodes are gone")
check(number("document.querySelectorAll('path[data-line=link]').length") == 1, "a logical connection to a hidden node is hidden too; the other stays")
check(bool("(function () { const a = __t.pos('n2'), b = __t.pos('n3'); return isFinite(a.x) && isFinite(b.x); })()"), "the remaining nodes are laid out")
check(eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[\"n2\"]", "the fold state is kept as view state")
newMark()
_ = js("__t.fold('n2').click(); return 'ok';")
check(bool("__t.shown('n6') && __t.shown('n7')") && number("document.querySelectorAll('path[data-line=tree]').length") == 11 && number("document.querySelectorAll('path[data-line=link]').length") == 2, "folding again shows them")
expectNone("folding sends nothing to Swift", action: "update", wait: 0.3)
_ = js("__t.select('n8'); __t.fold('n3').click(); return 'ok';")
check(bool("__t.btn('n3').getAttribute('aria-pressed') === 'true'") && eval("__t.q('.rm-title-input').value") == "Compiler", "folding the branch of the selected node selects the branch")
_ = js("__t.fold('n3').click(); return 'ok';")
_ = js("__t.q('[data-act=collapse-all]').click(); return 'ok';")
check(bool("['n1', 'n2', 'n3', 'n4', 'n5'].every(function (id) { return __t.shown(id); }) && ['n6', 'n7', 'n8', 'n9', 'n10', 'n11', 'n12'].every(function (id) { return !__t.shown(id); })"), "Collapse all leaves the root and its main branches")
check(eval("['n2', 'n3', 'n4', 'n5'].map(function (id) { return __t.fold(id).textContent; }).join()") == "+2,+2,+2,+1", "…each folded branch shows its hidden count")
_ = js("__t.q('[data-act=expand-all]').click(); return 'ok';")
check(bool("['n1','n2','n3','n4','n5','n6','n7','n8','n9','n10','n11','n12'].every(function (id) { return __t.shown(id); })") && eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[]", "Expand all shows every node")
// A node the person adds under a folded branch is shown (it is selected).
_ = js("__t.fold('n3').click(); return 'ok';")
deliver("{ created: 'n13', nodes: (function () { const s = __t.snap(); s.nodes.splice(8, 0, { id: 'n13', parent: 'n3', title: 'Fresh', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })() }")
check(bool("__t.shown('n13') && __t.shown('n8')") && bool("__t.btn('n13').getAttribute('aria-pressed') === 'true'"), "a created node under a folded branch unfolds the branch and is selected")
deliver()

// ---- focus (REQ-011) -------------------------------------------------------------------------------------------------------------------
// A third level (n14 under n8) shows that the children of a focused node's children stay folded.
let deepNodes = "{ nodes: (function () { const s = __t.snap(); s.nodes.push({ id: 'n14', parent: 'n8', title: 'Cache keys', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })() }"
deliver(deepNodes)
_ = js("__t.q('[data-act=expand-all]').click(); __t.select('n12'); __t.menu('n3'); return 'ok';")
check(bool("!!__t.q('.rm-actions [data-act=focus]')"), "the node menu offers Focus")
newMark()
_ = js("__t.act('focus'); return 'ok';")
check(bool("['n1', 'n2', 'n3', 'n4', 'n5', 'n8', 'n9'].every(function (id) { return __t.shown(id); }) && ['n6', 'n7', 'n10', 'n11', 'n12', 'n14'].every(function (id) { return !__t.shown(id); })"),
      "Focus shows the path from the root, the siblings along it and the node's children, and folds the rest")
check(eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[\"n2\",\"n4\",\"n5\",\"n8\"]", "…the other branches and the focused node's children are folded; the path and the node are not", eval("JSON.stringify(window.MVResearchMap.collapsed())"))
check(eval("__t.fold('n8').textContent") == "+1" && bool("__t.fold('n3').getAttribute('aria-expanded') === 'true'"), "…a child of the focused node says what it hides; the focused node is open")
check(bool("__t.btn('n3').getAttribute('aria-pressed') === 'true'") && eval("__t.q('.rm-title-input').value") == "Compiler", "the focused node is selected, even though the selection was on a node that is now hidden")
let focusAt = json("const n = __t.btn('n3').getBoundingClientRect(), v = __t.q('.rm-viewport').getBoundingClientRect(); return JSON.stringify({ dx: Math.round((n.left + n.width / 2) - (v.left + v.width / 2)), dy: Math.round((n.top + n.height / 2) - (v.top + v.height / 2)) });")
check(abs((focusAt["dx"] as? Int) ?? 999) <= 2 && abs((focusAt["dy"] as? Int) ?? 999) <= 2, "the focused node is brought to the middle of the map", "\(focusAt)")
expectNone("Focus sends nothing to Swift: the file does not change", action: "update", wait: 0.3)
// A leaf at the third level: its whole path is open.
_ = js("__t.menu('n14'); __t.act('focus'); return 'ok';")
check(bool("['n1', 'n2', 'n3', 'n4', 'n5', 'n8', 'n9', 'n14'].every(function (id) { return __t.shown(id); }) && ['n6', 'n7', 'n10', 'n11', 'n12'].every(function (id) { return !__t.shown(id); })") && eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[\"n2\",\"n4\",\"n5\"]", "Focus on a leaf opens its path and folds the other branches")
// The root: the same as Collapse all.
_ = js("__t.menu('n1'); __t.act('focus'); return 'ok';")
let focusRoot = eval("JSON.stringify(window.MVResearchMap.collapsed())")
check(bool("__t.btn('n1').getAttribute('aria-pressed') === 'true'"), "Focus on the root selects the root")
_ = js("__t.q('[data-act=expand-all]').click(); __t.q('[data-act=collapse-all]').click(); return 'ok';")
check(focusRoot == eval("JSON.stringify(window.MVResearchMap.collapsed())"), "Focus on the root folds the map like Collapse all", focusRoot)
_ = js("__t.q('[data-act=expand-all]').click(); return 'ok';")
check(bool("['n1','n2','n3','n4','n5','n6','n7','n8','n9','n10','n11','n12','n14'].every(function (id) { return __t.shown(id); })"), "Expand all undoes a Focus")
deliver()

// A long title is never cut: the title field wraps.
_ = js("__t.select('n2'); return 'ok';")
deliver("{ nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n2'; }).title = 'Мне нужно сделать deep research, так сказать, узнать полностью всё о том, как происходят финансы в нашей системе внутри'; return s.nodes; })() }")
let titleBox = json("const t = __t.q('.rm-title-input'); return JSON.stringify({ tag: t.tagName, offset: t.offsetHeight, scroll: t.scrollHeight, client: t.clientHeight, width: t.offsetWidth, value: t.value.length, style: t.style.height });")
check((titleBox["tag"] as? String) == "TEXTAREA" && ((titleBox["offset"] as? Double) ?? 0) > 44 && ((titleBox["scroll"] as? Double) ?? 1) <= ((titleBox["client"] as? Double) ?? 0) + 1, "a long title wraps in the panel instead of being cut (BUG-091)", "\(titleBox)")
deliver()

// ---- export (REQ-007) ------------------------------------------------------------------------------------------------------------------
newMark()
check(!visible(".rm-exportmenu"), "the export menu is closed at first")
_ = js("__t.q('[data-act=export]').click(); return 'ok';")
check(visible(".rm-exportmenu") && eval("__t.qa('.rm-exportmenu [data-act]').map(function(b){return b.textContent.trim();}).join('|')") == "Markdown report|PDF…", "Export opens a menu: Markdown report and PDF")
_ = js("__t.q('[data-act=export-markdown]').click(); return 'ok';")
expect("Markdown report sends export with kind markdown", ["action": "export", "kind": "markdown"], doc: tabM)
check(!visible(".rm-exportmenu"), "the menu closes after choosing")
newMark()
_ = js("__t.q('[data-act=export]').click(); __t.q('[data-act=export-pdf]').click(); return 'ok';")
expect("PDF sends export with kind pdf", ["action": "export", "kind": "pdf"], doc: tabM)
_ = js("__t.q('[data-act=export]').click(); return 'ok';")
_ = js("document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); return 'ok';")
check(!visible(".rm-exportmenu"), "a click elsewhere closes the export menu")
let reportHTML = eval("window.MVResearchMap.reportHTML('# Title\\n\\n<script>alert(1)</script>\\n\\n- one')")
check(reportHTML.contains("<h1>Title</h1>") && reportHTML.contains("<li>one</li>") && !reportHTML.contains("<script"), "the report is rendered to HTML for the PDF, raw HTML in it is not passed through")

newMark()
_ = js("__t.menu('n3'); __t.act('arrange'); return 'ok';")
check(number("document.querySelectorAll('.rm-layouts button').length") == 7 && eval("__t.qa('.rm-layouts button').map(function(b){return b.dataset.layout;}).join()") == "balanced,right,left,down,up,radial,outline", "Arrange lists the snapshot's layouts in order")
check(eval("__t.qa('.rm-layouts button[aria-checked=true]').map(function(b){return b.dataset.layout;}).join()") == "balanced", "the root's default layout is marked as the current one")
_ = js("__t.q('.rm-layouts button[data-layout=radial]').click(); return 'ok';")
expect("choosing a layout sends layout", ["action": "layout", "id": "n3", "layout": "radial"], doc: tabM)
check(!visible(".rm-actions"), "the menu closes after choosing")
let nestedSnapshot = "{ nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n3'; }).layout = 'down'; return s.nodes; })() }"
deliver(nestedSnapshot)
_ = js("__t.menu('n8'); __t.act('arrange'); return 'ok';")
check(eval("__t.qa('.rm-layouts button[aria-checked=true]').map(function(b){return b.dataset.layout;}).join()") == "down", "a node without its own layout shows the nearest ancestor's layout as current")
_ = js("__t.menu('n8'); return 'ok';")
deliver()

newMark()
_ = js("__t.menu('n2'); __t.act('delete'); return 'ok';")
check(eval("__t.q('.rm-dialog').textContent").contains("Delete node “Dependencies” and its child nodes (2)"), "Delete asks first and states the number of descendants", eval("__t.q('.rm-dialog').textContent"))
_ = js("__t.dialogButton('Cancel'); return 'ok';")
expectNone("Cancel sends nothing", action: "delete", wait: 0.3)
_ = js("__t.menu('n2'); __t.act('delete'); __t.dialogButton('Delete'); return 'ok';")
expect("confirming sends delete", ["action": "delete", "id": "n2"], doc: tabM)
_ = js("__t.menu('n7'); __t.act('delete'); return 'ok';")
check(!eval("__t.q('.rm-dialog').textContent").contains("child nodes"), "a leaf's delete dialog has no descendant count", eval("__t.q('.rm-dialog').textContent"))
_ = js("__t.q('.rm-btn[data-kind=ghost]').click(); return 'ok';")
_ = js("__t.menu('n7'); __t.act('add'); return 'ok';")
_ = js("document.querySelector('.rm-root').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return 'ok';")
check(!visible(".rm-dialog"), "Escape closes a dialog")

// ---- editing in the properties panel ------------------------------------------------------------------------------------------------------
_ = js("__t.select('n2'); return 'ok';")
newMark()
_ = js("const i = __t.q('.rm-title-input'); __t.type(i, 'D'); __t.type(i, 'De'); __t.type(i, 'Dependencies v2'); return 'ok';")
spin(0.12)
check(researchMessages().isEmpty, "typing a title sends nothing yet (debounced)", describe(researchMessages()))
check(eval("__t.btn('n2').textContent") == "Dependencies v2", "the node on the map follows the typing at once")
expect("one update with the final title after the pause", ["action": "update", "id": "n2", "title": "Dependencies v2"], doc: tabM)
newMark()
_ = js("__t.type(__t.q('.rm-title-input'), '   '); return 'ok';")
check(eval("__t.q('.rm-error').textContent") == "Enter a node name.", "an empty title shows an inline error")
expectNone("…and is not sent", action: "update", wait: 0.6)
_ = js("__t.q('.rm-title-input').blur(); return 'ok';")
check(eval("__t.q('.rm-title-input').value") == "Dependencies" && eval("__t.q('.rm-error').textContent") == "", "leaving the field restores the saved title", eval("__t.q('.rm-title-input').value"))
deliver()

newMark()
_ = js("const i = __t.q('.rm-tag-input'); i.focus(); i.value = 'New Tag'; __t.key(i, 'Enter'); return 'ok';")
expect("Enter adds a tag: update with the whole tag list", ["action": "update", "id": "n2", "tags": ["deps", "build", "New Tag"]], doc: tabM)
newMark()
_ = js("const i = __t.q('.rm-tag-input'); i.focus(); i.value = 'DEPS'; __t.key(i, 'Enter'); return 'ok';")
expectNone("a tag that differs only in case is not added", action: "update", wait: 0.5)
check(eval("__t.q('.rm-tag-input').value") == "", "the tag field is cleared")
newMark()
_ = js("__t.q('.rm-tag[data-tag=deps] button').click(); return 'ok';")
expect("× removes a tag", ["action": "update", "id": "n2", "tags": ["build"]], doc: tabM)

newMark()
_ = js("const c = __t.q('.rm-color-input'); c.value = '#aa5500'; c.dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("the colour input sends update with the colour", ["action": "update", "id": "n2", "color": "#aa5500"], doc: tabM)
deliver("{ nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n2'; }).color = '#aa5500'; return s.nodes; })() }")
let tinted = json("const s = getComputedStyle(__t.btn('n2')); return JSON.stringify({ border: s.borderLeftColor, width: s.borderLeftWidth });")
check((tinted["border"] as? String) == "rgb(170, 85, 0)", "a node with its own colour takes it as its accent edge", "\(tinted)")
let lineColours = json("return JSON.stringify({ paths: __t.qa('path[data-line=tree]').map(function (p) { return getComputedStyle(p).stroke; }) });")
check(((lineColours["paths"] as? [String]) ?? []).contains("rgb(170, 85, 0)"), "the line into a node with its own colour takes that colour (Q-007 A)", "\(lineColours)")
check(((lineColours["paths"] as? [String]) ?? []).contains("rgb(78, 201, 176)"), "other lines keep their branch colour", "\(lineColours)")
newMark()
_ = js("__t.q('.rm-color-row .rm-x').click(); return 'ok';")
expect("the reset button sends an empty colour", ["action": "update", "id": "n2", "color": ""], doc: tabM)
deliver()

newMark()
_ = js("const d = __t.q('.rm-desc'); __t.type(d, 'hello world'); d.setSelectionRange(0, 5); __t.q('[data-fmt=bold]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "**hello** world", "Bold wraps the selection in Markdown", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = 'one'; d.setSelectionRange(0, 3); __t.q('[data-fmt=italic]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "*one*", "Italic wraps the selection", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = ''; d.setSelectionRange(0, 0); __t.q('[data-fmt=link]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "[text](url)", "Link inserts a link around a placeholder", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = ''; d.setSelectionRange(0, 0); __t.q('[data-fmt=image]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "![description](image url)", "Image inserts Markdown image syntax", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = 'item'; d.setSelectionRange(0, 4); __t.q('[data-fmt=list]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "- item", "List prefixes the selection", eval("__t.q('.rm-desc').value"))
expect("the description is sent once, after the pause", ["action": "update", "id": "n2", "description": "- item"], doc: tabM)
deliver()

// ---- dragging, keyboard moves and view ---------------------------------------------------------------------------------------------------
let before = json("return JSON.stringify({ n4: __t.pos('n4'), n10: __t.pos('n10'), n3: __t.pos('n3') });")
let n4 = before["n4"] as? [String: Double] ?? [:], n10 = before["n10"] as? [String: Double] ?? [:], n3 = before["n3"] as? [String: Double] ?? [:]
newMark()
_ = js("__t.dragStart('n4'); __t.dragTo(1, 1); return 'ok';")
check(bool("__t.btn('n4').getAttribute('aria-pressed') === 'false'") && visible(".rm-readout") == false, "a movement under the threshold is not a drag")
_ = js("__t.dragTo(60, 30); return 'ok';")
check(visible(".rm-readout") && eval("__t.q('.rm-readout').textContent").hasPrefix("x "), "dragging shows the live position", eval("__t.q('.rm-readout').textContent"))
let live = json("return JSON.stringify({ n4: __t.pos('n4'), n10: __t.pos('n10'), n3: __t.pos('n3') });")
let liveN4 = live["n4"] as? [String: Double] ?? [:], liveN10 = live["n10"] as? [String: Double] ?? [:], liveN3 = live["n3"] as? [String: Double] ?? [:]
check(liveN4["x"] == (n4["x"] ?? 0) + 60 && liveN4["y"] == (n4["y"] ?? 0) + 30, "the node follows the pointer while dragging", "\(live)")
check(liveN10["x"] == (n10["x"] ?? 0) + 60 && liveN10["y"] == (n10["y"] ?? 0) + 30, "its branch follows it (the layout travels with the node)", "\(live)")
check(liveN3 == n3, "other branches stay where they are", "\(live)")
expectNone("nothing is sent while dragging", action: "moveVisual", wait: 0.3)
_ = js("__t.dragEnd(60, 30, true); return 'ok';")
expect("releasing sends moveVisual with the node's centre", ["action": "moveVisual", "id": "n4", "x": Int((n4["x"] ?? 0) + 60), "y": Int((n4["y"] ?? 0) + 30)], doc: tabM)
check(!visible(".rm-readout"), "the live readout goes away on release")
check(bool("__t.btn('n4').getAttribute('aria-pressed') === 'false'"), "the click that ends a drag does not select the node")
let after = json("return JSON.stringify({ n4: __t.pos('n4') });")
check((after["n4"] as? [String: Double])?["x"] == (n4["x"] ?? 0) + 60, "the node stays at the dropped place until Swift answers")
// Swift's answer carries the position.
deliver("{ nodes: (function () { const s = __t.snap(); const n = s.nodes.find(function (m) { return m.id === 'n4'; }); n.x = \(Int((n4["x"] ?? 0) + 60)); n.y = \(Int((n4["y"] ?? 0) + 30)); return s.nodes; })() }")
let manual = json("return JSON.stringify({ n4: __t.pos('n4'), n10: __t.pos('n10') });")
check((manual["n4"] as? [String: Double])?["x"] == (n4["x"] ?? 0) + 60 && (manual["n10"] as? [String: Double])?["x"] == (n10["x"] ?? 0) + 60,
      "a snapshot with x and y places the node exactly there and its descendants relative to it", "\(manual)")
deliver()

// A click with a tiny movement is a click.
newMark()
_ = js("__t.dragStart('n5'); __t.dragTo(2, 1); __t.dragEnd(2, 1, true); return 'ok';")
check(bool("__t.btn('n5').getAttribute('aria-pressed') === 'true'"), "a click with 2px of jitter still selects")
expectNone("…and does not move the node", action: "moveVisual", wait: 0.4)

// Keyboard moves: arrows 10, shift 40; one message after the last key.
let key0 = json("return JSON.stringify({ n5: __t.pos('n5') });")
let n5 = key0["n5"] as? [String: Double] ?? [:]
newMark()
_ = js("const i = __t.q('.rm-title-input'); i.focus(); __t.key(i, 'ArrowLeft'); document.body.focus(); __t.key(document.body, 'ArrowRight'); __t.key(document.body, 'ArrowDown', { shiftKey: true }); return 'ok';")
check((json("return JSON.stringify({ n5: __t.pos('n5') });")["n5"] as? [String: Double])?["x"] == (n5["x"] ?? 0) + 10, "an arrow key moves the selected node by 10 at once (also with no node focused), and not while typing in a field")
expect("keyboard moves are sent once, together", ["action": "moveVisual", "id": "n5", "x": Int((n5["x"] ?? 0) + 10), "y": Int((n5["y"] ?? 0) + 40)], doc: tabM)
deliver()

// Wheel zoom (never pans), buttons, limits, pan, centre.
let wheelBefore = json("return JSON.stringify(__t.view());")
let vbox = json("const r = __t.q('.rm-viewport').getBoundingClientRect(); return JSON.stringify({ left: r.left, top: r.top });")
let originX = (vbox["left"] as? Double ?? 0) + (wheelBefore["x"] as? Double ?? 0), originY = (vbox["top"] as? Double ?? 0) + (wheelBefore["y"] as? Double ?? 0)
let prevented = js("return String(__t.wheel(\(originX), \(originY), -100));")
let wheelAfter = json("return JSON.stringify(__t.view());")
check(prevented == "true", "the wheel is captured by the canvas (the page does not scroll)")
check(abs((wheelAfter["scale"] as? Double ?? 0) - 1.1) < 0.001, "a wheel notch up zooms in by 1.1", "\(wheelAfter)")
check(abs((wheelAfter["x"] as? Double ?? 0) - (wheelBefore["x"] as? Double ?? 0)) < 1 && abs((wheelAfter["y"] as? Double ?? 0) - (wheelBefore["y"] as? Double ?? 0)) < 1, "zooming around the pointer does not pan (the world point under the pointer stays put)", "\(wheelBefore) \(wheelAfter)")
_ = js("__t.wheel(10, 10, 100); return 'ok';")
check(abs((json("return JSON.stringify(__t.view());")["scale"] as? Double ?? 0) - 1.0) < 0.001, "a wheel notch down zooms out")
_ = js("__t.wheel(300, 300, 40); __t.wheel(300, 300, 40); return 'ok';")
check(number("__t.view().scale") < 0.85, "the plain wheel only ever zooms")
_ = js("__t.q('[data-act=centre]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "100%", "Centre returns to 100%")
_ = js("__t.q('[data-act=zoom-in]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "120%", "the zoom button multiplies by 1.2", eval("__t.q('.rm-zoom').textContent"))
_ = js("for (let i = 0; i < 12; i++) __t.q('[data-act=zoom-in]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "200%", "zoom stops at 200%", eval("__t.q('.rm-zoom').textContent"))
_ = js("for (let i = 0; i < 25; i++) __t.q('[data-act=zoom-out]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "40%", "zoom stops at 40%", eval("__t.q('.rm-zoom').textContent"))
_ = js("__t.q('[data-act=centre]').click(); return 'ok';")
let panBefore = json("return JSON.stringify(__t.view());")
_ = js("__t.panning(50, 20); return 'ok';")
let panAfter = json("return JSON.stringify(__t.view());")
check((panAfter["x"] as? Double ?? 0) - (panBefore["x"] as? Double ?? 0) == 50 && (panAfter["y"] as? Double ?? 0) - (panBefore["y"] as? Double ?? 0) == 20, "dragging the background pans the map", "\(panBefore) \(panAfter)")
spin(1.2)
let stored = json("return JSON.stringify(JSON.parse(localStorage.getItem('mvMap:2026-11-04-builds') || '{}'));")
check((stored["scale"] as? Double) == 1 && (stored["x"] as? Double) == panAfter["x"] as? Double && (stored["selected"] as? String) == "n5" && (stored["panel"] as? Double) == 320,
      "pan, zoom, panel width and selection are kept per map id in localStorage", "\(stored)")

// The panel divider.
let width0 = number("__t.q('.rm-panel').getBoundingClientRect().width")
check(width0 == 320, "the panel starts at 320px", "\(width0)")
_ = js("__t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true })); return 'ok';")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 340, "ArrowLeft on the divider widens the panel by 20")
_ = js("for (let i = 0; i < 40; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })); return 'ok';")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 240, "the panel is at least 240px")
_ = js("for (let i = 0; i < 60; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true })); return 'ok';")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 600, "the panel is at most 600px", eval("__t.q('.rm-panel').getBoundingClientRect().width"))
_ = js("""
const d = __t.q('.rm-divider'), r = d.getBoundingClientRect();
const f = function (type, x) { d.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 9, pointerType: 'mouse', button: 0, clientX: x, clientY: r.top + 40 })); };
f('pointerdown', r.left + 4); f('pointermove', r.left + 4 + 100); f('pointerup', r.left + 4 + 100);
return 'ok';
""")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 500, "dragging the divider resizes the panel", eval("__t.q('.rm-panel').getBoundingClientRect().width"))
_ = js("__t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })); for (let i = 0; i < 9; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })); return 'ok';")
_ = js("for (let i = 0; i < 9; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true })); return 'ok';")

// ---- snapshots from Swift ----------------------------------------------------------------------------------------------------------------------
let titleBefore = eval("__t.q('.rm-heading strong').textContent")
let countBefore = number("document.querySelectorAll('.rm-node').length")
_ = js("window.mvResearchMapSet('some-other-tab', __t.snap({ title: 'Stale', nodes: [{ id: 'z1', parent: '', title: 'Stale root', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }] })); return 'ok';")
spin(0.2)
check(eval("__t.q('.rm-heading strong').textContent") == titleBefore && number("document.querySelectorAll('.rm-node').length") == countBefore, "a snapshot for another document is ignored")

deliver("{ notice: 'This connection already exists.' }")
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent") == "This connection already exists.", "a notice shows as a transient toast")
deliver()

deliver("{ nodes: (function () { const s = __t.snap(); s.nodes.push({ id: 'n13', parent: 'n3', title: 'Fresh node', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })(), created: 'n13' }")
check(bool("__t.btn('n13') !== null && __t.btn('n13').getAttribute('aria-pressed') === 'true'") && eval("__t.q('.rm-title-input').value") == "Fresh node", "the node an action created is selected")

// An unsolicited snapshot (an AI job adds nodes) keeps the view and what the person is typing.
_ = js("__t.select('n2'); return 'ok';")
// The mark goes before the typing: the page sends the typed text after its 300 ms pause, which on a slow machine can be
// before the lines below have run.
newMark()
_ = js("__t.q('[data-act=zoom-in]').click(); const d = __t.q('.rm-desc'); d.focus(); d.value = 'typing in progress'; d.dispatchEvent(new Event('input', { bubbles: true })); d.setSelectionRange(3, 5); return 'ok';")
let viewBefore = json("return JSON.stringify(Object.assign(__t.view(), { panel: __t.q('.rm-panel').getBoundingClientRect().width }));")
deliver("{ status: 'researching', job: { kind: 'develop', label: 'Developing', step: 'Adding nodes', startedAt: \(Int(Date().timeIntervalSince1970)) }, nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n2'; }).description = 'changed by the AI'; s.nodes.push({ id: 'n14', parent: 'n2', title: 'Added while typing', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })() }")
let keep = json("const d = __t.q('.rm-desc'); const v = __t.view(); return JSON.stringify({ active: document.activeElement === d, value: d.value, from: d.selectionStart, to: d.selectionEnd, selected: __t.btn('n2').getAttribute('aria-pressed'), nodes: document.querySelectorAll('.rm-node').length, scale: v.scale, vx: v.x, vy: v.y, panel: __t.q('.rm-panel').getBoundingClientRect().width });")
check((keep["active"] as? Bool) == true && (keep["value"] as? String) == "typing in progress" && (keep["from"] as? Int) == 3 && (keep["to"] as? Int) == 5, "an unsolicited snapshot does not overwrite the field being typed in, nor its caret", "\(keep)")
check((keep["selected"] as? String) == "true" && (keep["nodes"] as? Int) == 13, "…keeps the selection and adds the new node", "\(keep)")
check((keep["scale"] as? Double) == viewBefore["scale"] as? Double && (keep["vx"] as? Double) == viewBefore["x"] as? Double && (keep["vy"] as? Double) == viewBefore["y"] as? Double && (keep["panel"] as? Double) == viewBefore["panel"] as? Double, "…keeps pan, zoom and panel width", "\(keep) \(viewBefore)")
expect("the typed description is still sent", ["action": "update", "id": "n2", "description": "typing in progress"], doc: tabM)
_ = js("__t.q('.rm-desc').blur(); return 'ok';")
deliver()
check(eval("__t.q('.rm-desc').value") == "Notes on the dependency graph.", "once the field is left, the snapshot's text shows")

// ---- leaving and returning ---------------------------------------------------------------------------------------------------------------------
// Edits that wait for the pause are handed over before the document changes, under the old document's id.
newMark()
_ = js("__t.select('n2'); __t.type(__t.q('.rm-title-input'), 'Dependencies final'); window.mvSetDocument(window.__other = ids); return 'ok';", ["ids": tabN])
let handed = researchMessages().filter { ($0.payload["action"] as? String) == "update" }
check(handed.count == 1 && handed[0].doc == tabM && (handed[0].payload["title"] as? String) == "Dependencies final", "switching documents hands the waiting edit over, under the old document's id", describe(researchMessages()))
_ = js("window.mvSetDocument(old); return 'ok';", ["old": tabM])

newMark()
_ = js("__t.type(__t.q('.rm-title-input'), 'Dependencies again'); window.switchToSource(); return 'ok';")
let flushed = researchMessages().filter { ($0.payload["action"] as? String) == "update" }
check(flushed.count == 1 && flushed[0].doc == tabM && (flushed[0].payload["title"] as? String) == "Dependencies again", "leaving the map sends the waiting edit at once", describe(researchMessages()))
deliver()

// Map | View | Source (REQ-010): map -> Source (switch) -> top-bar toggle -> map.
newMark()
_ = js("window.setContent(text); return 'ok';", ["text": mapText])
check(visible("#research-map-container"), "loading the same document again shows the map")
check(number("document.querySelectorAll('.rm-node').length") == 12, "…with the nodes it had, at once (no blank map while Swift answers)", eval("document.querySelectorAll('.rm-node').length"))
expect("…and asks Swift for a fresh snapshot", ["action": "snapshot"], doc: tabM)
newMark()
_ = js("__t.q('.rm-toolbar [data-view=source]').click(); return 'ok';")
check(!visible("#research-map-container"), "Source in the switch leaves the map")
check(visible("#editor-pane") && !visible("#preview-pane"), "…and shows the Markdown source")
check(eval("document.getElementById('status-mode').textContent") == "Source", "…with Source in the status bar", eval("document.getElementById('status-mode').textContent"))
check(visible("#wysiwyg-toolbar") && visible("#wysiwyg-toolbar .mv-modes") && !visible("#mode-toggle"), "…and the top bar has the switch instead of the single mode label")
check(eval("__t.qa('#wysiwyg-toolbar [data-view]').map(function(b){return b.dataset.view + ':' + b.getAttribute('aria-pressed');}).join()") == "map:false,view:false,source:true", "…with Source marked", eval("__t.qa('#wysiwyg-toolbar [data-view]').map(function(b){return b.dataset.view + ':' + b.getAttribute('aria-pressed');}).join()"))
check(eval("document.getElementById('editor-input').value").contains("type: research-map"), "…the source is the document's text")
// In the Source view of the map document the text follows the file (an AI job adds nodes, another editor saves).
deliver("{ markdown: '---\\ntype: research-map\\n---\\n\\n## Map\\n\\n- [Changed elsewhere](#n1)\\n' }")
check(eval("document.getElementById('editor-input').value").contains("Changed elsewhere"), "a snapshot refreshes the Source text of the map document")
_ = js("const e = document.getElementById('editor-input'); e.value = e.value + ' typed'; return 'ok';")
deliver("{ markdown: '---\\ntype: research-map\\n---\\n\\n## Map\\n\\n- [Overwrites typing](#n1)\\n' }")
check(!eval("document.getElementById('editor-input').value").contains("Overwrites typing"), "…but not while the person is typing in it")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#research-map-container") && !visible("#editor-pane"), "the top-bar toggle (Source in the cycle) returns to the map")
expect("…and asks for the current snapshot", ["action": "snapshot"], doc: tabM)
check(eval("document.getElementById('status-mode').textContent") == "MAP", "…with MAP in the status bar")

newMark()
_ = js("window.switchToPreview(); return 'ok';")
check(!visible("#research-map-container") && visible("#preview-pane"), "Preview hides the map")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#editor-pane") && !visible("#research-map-container"), "Preview → toggle → Source")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#research-map-container"), "Source → toggle → back to the map")
_ = js("window.toggleSourceMode(); return 'ok';")
check(visible("#preview-pane") && !visible("#editor-pane") && !visible("#research-map-container"), "the shortcut cycle goes from the map to View (Swift's toggleSourceMode too)")
_ = js("window.toggleSourceMode(); return 'ok';")
check(visible("#editor-pane") && !visible("#research-map-container"), "…then to Source")
_ = js("window.toggleSourceMode(); return 'ok';")
check(visible("#research-map-container"), "…and back to the map")

// The switch itself (REQ-010).
check(eval("__t.qa('.rm-toolbar [data-view]').map(function(b){return b.textContent + ':' + b.getAttribute('aria-pressed');}).join()") == "Map:true,View:false,Source:false", "the map toolbar has Map | View | Source with Map marked", eval("__t.qa('.rm-toolbar [data-view]').map(function(b){return b.textContent + ':' + b.getAttribute('aria-pressed');}).join()"))
check(!visible("[data-act=source]"), "the lone Source button is gone")
// A trip through View and Source and back keeps the map as it was and leaves the text alone.
_ = js("window.setContent(text); return 'ok';", ["text": mapText])
deliver()
_ = js("__t.select('n3'); __t.fold('n2').click(); __t.q('[data-act=zoom-in]').click(); return 'ok';")
let beforeTrip = json("const v = window.MVResearchMap.viewState(); return JSON.stringify({ scale: v.scale, x: v.x, y: v.y, selected: v.selected, collapsed: window.MVResearchMap.collapsed(), text: document.getElementById('editor-input').value });")
check((beforeTrip["text"] as? String) == mapText, "the document text is the file's text while the map is shown", "\(beforeTrip["text"] ?? "")")
newMark()
_ = js("__t.q('.rm-toolbar [data-view=view]').click(); return 'ok';")
check(visible("#preview-pane") && !visible("#editor-pane") && !visible("#research-map-container"), "View shows the file as ordinary Markdown")
check(eval("document.getElementById('editor-rendered').innerText").contains("Why do builds get slow?"), "…the rendered page holds the map's text")
check(eval("document.getElementById('editor-rendered').contentEditable") == "false", "…and is not edited (the page's converter cannot write a map file back)")
check(visible("#wysiwyg-toolbar .mv-modes") && !visible("#mode-toggle") && eval("__t.qa('#wysiwyg-toolbar [data-view]').map(function(b){return b.getAttribute('aria-pressed');}).join()") == "false,true,false", "…the top bar has the switch with View marked")
check(!visible("#wysiwyg-toolbar > button[onclick^=fmt]"), "…and no formatting buttons")
_ = js("__t.q('#wysiwyg-toolbar [data-view=source]').click(); return 'ok';")
check(visible("#editor-pane") && !visible("#preview-pane") && eval("document.getElementById('editor-input').value") == mapText, "Source from View shows the same text")
check(eval("document.getElementById('editor-rendered').contentEditable") == "true", "…and ordinary editing is back")
_ = js("__t.q('#wysiwyg-toolbar [data-view=map]').click(); return 'ok';")
check(visible("#research-map-container") && !visible("#editor-pane"), "Map in the top bar returns to the map")
expect("…and asks for the current snapshot", ["action": "snapshot"], doc: tabM)
let afterTrip = json("const v = window.MVResearchMap.viewState(); return JSON.stringify({ scale: v.scale, x: v.x, y: v.y, selected: v.selected, collapsed: window.MVResearchMap.collapsed(), text: document.getElementById('editor-input').value });")
check((afterTrip["scale"] as? Double) == (beforeTrip["scale"] as? Double) && (afterTrip["x"] as? Double) == (beforeTrip["x"] as? Double) && (afterTrip["y"] as? Double) == (beforeTrip["y"] as? Double) && (afterTrip["selected"] as? String) == (beforeTrip["selected"] as? String) && "\(afterTrip["collapsed"] ?? "")" == "\(beforeTrip["collapsed"] ?? "")",
      "zoom, position, selection and folds survive the trip", "\(beforeTrip) -> \(afterTrip)")
check((afterTrip["text"] as? String) == mapText, "…and the text is byte for byte the file's text")
expectNone("…and nothing was written to the map", action: "update", wait: 0.3)
// Another kind of document has no switch, only its own mode label.
_ = js("window.mvSetDocument(id); window.setContent('# Plain notes'); return 'ok';", ["id": tabP])
check(visible("#mode-toggle") && !visible("#wysiwyg-toolbar .mv-modes"), "an ordinary document keeps the single mode label and has no switch")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#editor-pane") && !visible("#preview-pane"), "…and its toggle still flips Preview and Source")
_ = js("window.mvSetDocument(id); window.setContent(text); return 'ok';", ["id": tabM, "text": mapText])
deliver()

// A text that is no longer a research map does not come back as one.
_ = js("window.switchToSource(); document.getElementById('editor-input').value = '# Just notes'; window.toggleModeWrapper(); return 'ok';")
check(!visible("#research-map-container") && visible("#preview-pane"), "a Source text without the research-map front matter toggles to the preview, not the map")

// A problem snapshot: a one-line notice and the Source view.
newMark()
_ = js("window.setContent(text); return 'ok';", ["text": mapText])
deliver("{ ok: false, problem: 'The file has no \"## Map\" list.' }")
check(!visible("#research-map-container") && visible("#editor-pane"), "a snapshot with ok false falls back to the Source view")
check(visible("#research-map-problem") && eval("document.getElementById('research-map-problem').textContent").contains("The file has no \"## Map\" list."), "…with a one-line notice giving the reason", eval("document.getElementById('research-map-problem').textContent"))
_ = js("window.mvSetDocument(id); window.setContent('# Plain again'); return 'ok';", ["id": tabP])
check(!visible("#research-map-problem") && !visible("#research-map-container") && visible("#preview-pane"), "a plain document clears the notice and leaves the map")
check(eval("document.getElementById('status-mode').textContent") == "WYSIWYG", "…and the usual status text returns")

// Other views take over.
check(loadDocument(tabM, mapText) == "ok" && visible("#research-map-container"), "back on the map document")
deliver()
_ = js("window.setStructuredContent('{\"a\": 1}', 'json'); return 'ok';")
check(!visible("#research-map-container"), "structured content leaves the map")
check(loadDocument(tabM, mapText) == "ok" && visible("#research-map-container"), "the map comes back with its document")
_ = js("window.leaveResearchMap(); return 'ok';")
check(!visible("#research-map-container"), "window.leaveResearchMap hides the map")

// A second map keeps its own view state.
let firstBefore = js("return localStorage.getItem('mvMap:2026-11-04-builds') || '';")
let secondText = mapText.replacingOccurrences(of: "2026-11-04-builds", with: "2026-11-05-other")
check(loadDocument(tabN, secondText) == "ok" && visible("#research-map-container"), "a second map document loads")
check(number("document.querySelectorAll('.rm-node').length") == 0, "…and starts empty, not with the first map's nodes")
deliver("{ id: '2026-11-05-other', title: 'Other map', question: 'Other?' }")
check(eval("__t.q('.rm-heading strong').textContent") == "Other map" && eval("__t.q('.rm-zoom').textContent") == "100%", "…with its own title and a fresh view")
_ = js("__t.q('[data-act=zoom-in]').click(); return 'ok';")
spin(1.0)
let keys = js("return Object.keys(localStorage).filter(function (k) { return k.indexOf('mvMap:') === 0; }).sort().join();")
check(keys == "mvMap:2026-11-04-builds,mvMap:2026-11-05-other", "each map keeps its own view under its own key", keys)
let secondStored = json("return JSON.stringify(JSON.parse(localStorage.getItem('mvMap:2026-11-05-other') || '{}'));")
let firstAfter = js("return localStorage.getItem('mvMap:2026-11-04-builds') || '';")
check((secondStored["scale"] as? Double) == 1.2 && !firstBefore.isEmpty && firstBefore == firstAfter, "…and zooming the second map did not touch the first", "\(firstBefore) | \(firstAfter) | \(secondStored)")

// ---- no errors anywhere -----------------------------------------------------------------------------------------------------------------------------
spin(0.5)
let errors = js("return JSON.stringify(window.__errors.slice(\(baselineErrors)));")
check(errors == "[]", "no error or unhandledrejection event in the page since the test began", errors)
let reported = Array(bridge.messages.filter { $0.type == "jsError" }.dropFirst(baselineReports))
check(reported.isEmpty, "the page reported no jsError to Swift since the test began", reported.map { String(describing: $0.payload["message"] ?? "") }.joined(separator: " | "))

print("\(failures) WebKit failures")
exit(failures == 0 ? 0 : 1)
