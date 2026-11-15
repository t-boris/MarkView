import AppKit
import WebKit

// FU-24 / FU-25: what the editor page does with untrusted style and untrusted values from files.
//   - Inline styles (every sanitiser profile and the Markdown path of the page): the filter reads what the browser's CSS parser
//     reports, not the raw text, so CSS escapes (`f\69xed`, `\75rl(`) and comments (`position:/**/fixed`) no longer pass; only
//     allow-listed properties survive; `position` is limited to static and relative; url() must stay inside the document or
//     carry a raster picture; `all: unset` (hundreds of longhands) is refused; ordinary styles (KaTeX offsets, flex and grid,
//     colours, fonts) are kept.
//   - A colour in a .canvas file cannot leave the style attribute of the properties panel (attribute injection, markup).
//   - A result kind from a code-navigation answer is shown as text in the list of definitions.
// The shipped editor page (index.html) runs in real WebKit with a hidden window and a stubbed bridge. Run through
// tools/tests/web-sinks-tests.sh (the editor folder is argument 1; run it on an older copy of the folder to see the checks fail).
setvbuf(stdout, nil, _IONBF, 0)
let editor = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath + "/MarkView/Resources/Editor"
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(900)))")
}
// A hung page must not hang the test run.
DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
    print("TIMEOUT: no result after 240 s")
    exit(1)
}

final class Bridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}
final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let config = WKWebViewConfiguration()
config.userContentController.add(Bridge(), name: "bridge")
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.alphaValue = 0
window.contentView = web
let loaded = Loaded()
web.navigationDelegate = loaded
web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

func js(_ body: String, timeout: TimeInterval = 120) -> String {
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

/// Runs one block of page script that returns a JSON array of {name, ok, detail} and prints every entry as a check.
func runChecks(_ title: String, _ body: String) {
    let answer = js(body)
    guard let data = answer.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        check(false, "\(title) returned results", answer)
        return
    }
    for entry in list { check(entry["ok"] as? Bool == true, entry["name"] as? String ?? title, entry["detail"] as? String ?? "") }
}

spin(30) { loaded.done }
check(loaded.done, "shipping editor page loaded")
spin(2)
let ready = js("return String(typeof window.setContent === 'function' && typeof window.mvKit === 'object' && typeof window.mermaid === 'object');")
check(ready == "true", "the page has setContent, mvKit and Mermaid", ready)

// 1. The style filter on every profile.
runChecks("style attributes", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    const cases = [
      // [name, style, properties that must be gone, properties that must stay as {name: value}]
      ['a CSS escape in the position value', 'position:f\\69xed;color:red', ['position'], { color: 'red' }],
      ['a comment in the position value', 'position:/**/fixed;color:red', ['position'], { color: 'red' }],
      ['position fixed with !important', 'POSITION : FIXED !important;color:red', ['position'], { color: 'red' }],
      ['position sticky', 'position:sticky;top:0', ['position'], {}],
      ['position absolute', 'position:absolute;top:0', ['position'], {}],
      ['an escaped url() function', 'background:\\75rl(https://evil.invalid/x.png);color:red', ['background-image'], { color: 'red' }],
      ['a half-escaped url() function', 'background:u\\72l(https://evil.invalid/x.png)', ['background-image'], {}],
      ['a remote background', 'background:url(https://evil.invalid/x.png);color:red', ['background-image'], { color: 'red' }],
      ['a relative background address', 'background-image:url(local.png)', ['background-image'], {}],
      ['an SVG data picture', 'background:url("data:image/svg+xml,<svg onload=1>")', ['background-image'], {}],
      ['image-set with a remote address', 'background-image:image-set("https://evil.invalid/x.png" 1x)', ['background-image'], {}],
      ['a remote cursor', 'cursor:url(https://evil.invalid/c.cur), auto;color:red', ['cursor'], { color: 'red' }],
      ['a remote list marker', 'list-style-image:url(https://evil.invalid/l.png)', ['list-style-image'], {}],
      ['a remote filter', 'filter:url(https://evil.invalid/f.svg#x)', ['filter'], {}],
      ['a remote border image', 'border-image-source:url(https://evil.invalid/b.png)', ['border-image-source'], {}],
      ['a CSS expression', 'width:expression(window.__pwn = 1);color:red', ['width'], { color: 'red' }],
      ['z-index', 'z-index:9999;color:red', ['z-index'], { color: 'red' }],
      ['content', 'content:"x";color:red', ['content'], { color: 'red' }],
      ['behavior and -moz-binding', 'behavior:url(x);-moz-binding:url(x);color:red', ['behavior', '-moz-binding'], { color: 'red' }],
      ['a custom property that hides url() behind an escape', '--x:\\75rl(https://evil.invalid/x);color:red', ['--x'], { color: 'red' }],
      ['all: unset (hundreds of longhands)', 'all:unset;color:red', ['display', 'color'], {}],
      ['a property that is not on the list', 'zoom:3;appearance:none;pointer-events:none', ['zoom', 'appearance'], { 'pointer-events': 'none' }],
      ['KaTeX-style offsets', 'height:1.5em;top:-0.2em;vertical-align:-0.25em;margin-right:0.05em', [], { height: '1.5em', top: '-0.2em', 'vertical-align': '-0.25em', 'margin-right': '0.05em' }],
      ['relative position', 'position:relative;top:2px', [], { position: 'relative', top: '2px' }],
      ['a data picture, a gradient and a fragment reference', 'background-image:url(data:image/png;base64,AAA=);fill:url(#grad);filter:url(#blur)', [], { fill: 'url("#grad")', filter: 'url("#blur")' }],
      ['layout, text and colour', 'display:grid;grid-template-columns:repeat(2,1fr);gap:4px;color:#f00;font-weight:600;border:1px solid #333;transform:rotate(3deg)', [], { display: 'grid', gap: '4px', 'font-weight': '600', transform: 'rotate(3deg)' }],
      ['a custom property used as a colour', '--accent:#123;color:var(--accent)', [], { '--accent': '#123', color: 'var(--accent)' }]
    ];
    const html = cases.map((c, i) => '<p id="c' + i + '" style="' + c[1].replace(/"/g, '&quot;') + '">x</p>').join('');
    for (const profile of ['markdown', 'book', 'discussion', 'insight']) {
        const doc = new DOMParser().parseFromString(window.mvKit.sanitizeHtml(html, profile), 'text/html');
        cases.forEach((c, i) => {
            const el = doc.getElementById('c' + i);
            const style = el ? el.style : null;
            const gone = c[2].filter(p => style && style.getPropertyValue(p) !== '' && !(p === 'background-image' && style.getPropertyValue(p) === 'none'));
            const wrong = Object.entries(c[3]).filter(([p, v]) => !style || style.getPropertyValue(p) !== v && !(p === 'color' && style.getPropertyValue(p).replace(/\s/g, '') === 'rgb(255,0,0)'));
            note(profile + ' profile: ' + c[0], !!el && gone.length === 0 && wrong.length === 0, 'still set: ' + gone.join(',') + ' wrong: ' + wrong.map(w => w[0]).join(',') + ' style: ' + (el && el.getAttribute('style')));
        });
    }
    // The same on the page's own path: the page renders the document and asks the browser what it computed.
    window.__pwn = 0;
    window.mvSetDocument('web-sinks-style');
    window.setContent('# Styles\n\n<div id="live-fixed" style="position:f\\69xed;top:0;left:0;width:100vw;height:100vh;background:red">covers</div>\n\n<div id="live-url" style="background:\\75rl(https://evil.invalid/x.png) red;height:10px">x</div>\n');
    for (let i = 0; i < 50 && !document.getElementById('live-fixed'); i++) await new Promise(r => setTimeout(r, 100));
    const fixed = document.getElementById('live-fixed'), remote = document.getElementById('live-url');
    note('the page renders the document with the escaped fixed position', !!fixed);
    if (fixed) {
        const toolbar = document.getElementById('mode-toggle').getBoundingClientRect();
        const hit = document.elementFromPoint(toolbar.left + 3, toolbar.top + 3);
        note('an escaped position:fixed in a document does not cover the page toolbar', getComputedStyle(fixed).position === 'static' && hit && hit.id === 'mode-toggle', getComputedStyle(fixed).position + ' ' + (hit && (hit.id || hit.className)));
    }
    note('an escaped url() in a document loads no remote background', !!remote && getComputedStyle(remote).backgroundImage === 'none', remote && getComputedStyle(remote).backgroundImage);
    return JSON.stringify(results);
    """#)

// 2. A colour in a .canvas file.
runChecks("canvas colour", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    window.__pwn = 0;
    const breakout = 'red" onmouseover="window.__pwn = 1" data-x="';
    const canvas = JSON.stringify({ nodes: [
      { id: 'n1', type: 'text', text: 'a', x: 0, y: 0, width: 100, height: 60, color: breakout },
      { id: 'n2', type: 'text', text: 'b', x: 200, y: 0, width: 100, height: 60, color: '4' },
      { id: 'n3', type: 'text', text: 'c', x: 400, y: 0, width: 100, height: 60, color: '"><img src=x onerror=window.__pwn=2>' },
      { id: 'n4', type: 'text', text: 'd', x: 600, y: 0, width: 100, height: 60, color: 'rgb(1, 2, 3)' },
      { id: 'n5', type: 'text', text: 'e', x: 800, y: 0, width: 100, height: 60, color: 'url(https://evil.invalid/x.png)' },
      { id: 'n6', type: 'text', text: 'f', x: 1000, y: 0, width: 100, height: 60, color: 'tomato' }
    ], edges: [
      { id: 'e1', fromNode: 'n1', toNode: 'n2', color: breakout },
      { id: 'e2', fromNode: 'n2', toNode: 'n3', color: '#44cf6e' },
      { id: 'e3', fromNode: 'n3', toNode: 'n4', color: 'var(--x)' }
    ] });
    window.setStructuredContent(canvas, 'canvas');
    for (let i = 0; i < 50 && !document.querySelector('.canvas-node'); i++) await new Promise(r => setTimeout(r, 100));
    function pick(selector) {
        document.querySelector(selector).dispatchEvent(new MouseEvent('click', { bubbles: true }));
        const swatch = document.querySelector('.canvas-props .canvas-swatch');
        return { swatch, attrs: swatch ? Array.from(swatch.attributes).map(a => a.name).join(',') : '', imgs: document.querySelectorAll('.canvas-props img').length };
    }
    for (const id of ['n1', 'n3', 'n5']) {
        const p = pick('.canvas-node[data-node-id="' + id + '"]');
        note('node ' + id + ': a hostile colour adds no attribute and no element to the properties panel', !!p.swatch && p.attrs === 'class,style' && p.imgs === 0 && p.swatch.style.background === '', p.attrs + ' imgs ' + p.imgs);
    }
    for (const [id, painted] of [['n2', 'rgb(68, 207, 110)'], ['n4', 'rgb(1, 2, 3)'], ['n6', 'tomato']]) {
        const p = pick('.canvas-node[data-node-id="' + id + '"]');
        note('node ' + id + ': a preset, rgb() or a colour name still paints the swatch', !!p.swatch && p.swatch.style.background === painted, p.swatch && p.swatch.getAttribute('style'));
    }
    for (const id of ['e1', 'e3']) {
        const p = pick('.canvas-edge[data-edge-id="' + id + '"]');
        note('edge ' + id + ': a hostile colour adds no attribute and no element to the properties panel', !!p.swatch && p.attrs === 'class,style' && p.imgs === 0 && p.swatch.style.background === '', p.attrs);
        const line = document.querySelector('.canvas-edge[data-edge-id="' + id + '"] .canvas-edge-line');
        note('edge ' + id + ': the line keeps the default colour', line.style.stroke === 'var(--cv-edge-color)', line.style.stroke);
    }
    const good = pick('.canvas-edge[data-edge-id="e2"]');
    note('edge e2: a hex colour still paints the swatch', !!good.swatch && good.swatch.style.background === 'rgb(68, 207, 110)', good.swatch && good.swatch.getAttribute('style'));
    await new Promise(r => setTimeout(r, 300));
    note('nothing the colours carried ran', window.__pwn === 0, window.__pwn);
    return JSON.stringify(results);
    """#)

// 3. A result kind in the list of definitions.
runChecks("code peek", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    window.__pwn = 0;
    window.setCodeContent('const a = 1;\n', 'javascript', 'a.js');
    await new Promise(r => setTimeout(r, 500));
    window.onCodeNavEvent({ type: 'definitions', name: 'foo', results: [
        { path: 'src/a.js', line: 1, kind: '<img src=x onerror=window.__pwn=3>', text: 'function foo() {}' },
        { path: 'src/a.js', line: 2, kind: 'function', text: 'foo(<b>x</b>)' },
        { path: 'src/b.js', line: 3, kind: 'usage', text: 'foo()' }
    ] });
    await new Promise(r => setTimeout(r, 300));
    const rows = Array.from(document.querySelectorAll('.code-peek-row'));
    note('the list shows its three results', rows.length === 3, rows.length);
    note('a result kind with markup adds no element to the list', document.querySelectorAll('.code-peek img').length === 0 && document.querySelectorAll('.code-peek .tx b').length === 0, document.querySelectorAll('.code-peek img').length);
    note('the kind is shown as text', rows[0] && rows[0].querySelector('i') && rows[0].querySelector('i').textContent === '<img src=x onerror=window.__pwn=3>', rows[0] && rows[0].innerHTML);
    note('an ordinary kind is still shown before the line', rows[1] && rows[1].querySelector('i') && rows[1].querySelector('i').textContent === 'function', rows[1] && rows[1].innerHTML);
    note('a usage has no kind and the name is still marked', rows[2] && !rows[2].querySelector('i') && rows[2].querySelector('mark') && rows[2].querySelector('mark').textContent === 'foo', rows[2] && rows[2].innerHTML);
    await new Promise(r => setTimeout(r, 300));
    note('nothing the kind carried ran', window.__pwn === 0, window.__pwn);
    return JSON.stringify(results);
    """#)

print(failures == 0 ? "All web sink checks passed" : "\(failures) web sink check(s) failed")
exit(failures == 0 ? 0 : 1)
