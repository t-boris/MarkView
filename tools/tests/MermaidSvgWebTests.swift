import AppKit
import WebKit

// FU-20: Mermaid keeps its whole theme in a <style> element inside every SVG it draws. The editor must show a diagram the
// way Mermaid drew it, and still neutralise what a hostile SVG carries. The shipped editor page (index.html) runs in real
// WebKit with a hidden window and a stubbed bridge; the checks run on the page's own path (setContent -> Mermaid ->
// mvKit.sanitizeMermaidSvg -> the page), not on a copy of the function.
//   - a real diagram has the colours and the labels Mermaid drew (computed fill, stroke and label colour equal those of the
//     same diagram inserted without the sanitiser, and are not the browser's default black);
//   - sixteen kinds of diagram keep every label and every style declaration (z-index, and the absolute position of the
//     tooltip and popup-menu overlays that are never inside the SVG, are the declarations the filter refuses);
//   - hostile SVG (script, handlers, foreignObject with script or iframe, javascript: links, @import, unscoped rules, url()
//     loads, CSS escapes, markup that breaks out of <style>, mutation-XSS payloads) executes nothing, adds no import rule,
//     no rule outside the SVG, no fixed position and no remote background, and its serialisation parses to the same thing;
//   - the Markdown, Book, Discussion and Insight profiles still forbid <style>.
// Run through tools/tests/mermaid-svg-tests.sh (the editor folder is argument 1; run it on an older copy of the folder to see
// the checks fail).
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
config.userContentController.addUserScript(MainActor.assumeIsolated { try! BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript })  // the page gets the bridge contract from the app (AR-28)
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

// 1. A real diagram, drawn and inserted by the page itself.
runChecks("the real diagram", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    const source = 'graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]';
    window.mvSetDocument('mermaid-svg-test');
    window.setContent('# Diagram\n\n```mermaid\n' + source + '\n```\n');
    for (let i = 0; i < 100 && !document.querySelector('#editor-rendered .mermaid svg'); i++) await new Promise(r => setTimeout(r, 100));
    const shown = document.querySelector('#editor-rendered .mermaid svg');
    note('the page draws the diagram', !!shown);
    if (!shown) return JSON.stringify(results);
    function probe(svg) {
        const rect = svg.querySelector('.node rect, .node polygon');
        const label = svg.querySelector('.nodeLabel');
        const edge = svg.querySelector('.flowchart-link');
        return {
            fill: rect ? getComputedStyle(rect).fill : 'none',
            stroke: rect ? getComputedStyle(rect).stroke : 'none',
            labelColor: label ? getComputedStyle(label).color : 'none',
            edgeStroke: edge ? getComputedStyle(edge).stroke : 'none',
            labels: Array.from(svg.querySelectorAll('.nodeLabel')).map(e => e.textContent.trim()).filter(Boolean)
        };
    }
    // The same source drawn by Mermaid and inserted with no sanitiser: this is what the theme looks like.
    const drawn = await mermaid.render('mermaid-svg-expected', source);
    const scratch = document.createElement('div');
    scratch.innerHTML = drawn.svg;
    document.body.appendChild(scratch);
    const expected = probe(scratch.querySelector('svg'));
    const actual = probe(shown);
    scratch.remove();
    note('Mermaid theme fill is not the default black', expected.fill !== 'rgb(0, 0, 0)' && expected.fill !== 'none', JSON.stringify(expected));
    note('the node fill on the page is the fill Mermaid drew', actual.fill === expected.fill, 'page ' + actual.fill + ' expected ' + expected.fill);
    note('the node outline on the page is the outline Mermaid drew', actual.stroke === expected.stroke && actual.stroke !== 'none', 'page ' + actual.stroke + ' expected ' + expected.stroke);
    note('the label colour on the page is the one Mermaid drew', actual.labelColor === expected.labelColor, 'page ' + actual.labelColor + ' expected ' + expected.labelColor);
    note('the edge colour on the page is the one Mermaid drew', actual.edgeStroke === expected.edgeStroke && actual.edgeStroke !== 'none', 'page ' + actual.edgeStroke + ' expected ' + expected.edgeStroke);
    note('every label of the diagram is on the page', expected.labels.length >= 4 && JSON.stringify(actual.labels) === JSON.stringify(expected.labels), 'page ' + JSON.stringify(actual.labels) + ' expected ' + JSON.stringify(expected.labels));
    const style = shown.querySelector('style');
    const id = shown.getAttribute('id');
    const sheet = style ? Array.from(document.styleSheets).find(s => s.ownerNode === style) : null;
    const rules = sheet ? Array.from(sheet.cssRules) : [];
    note('the diagram keeps its own stylesheet', rules.length > 10, 'rules: ' + rules.length);
    note('every rule of that stylesheet starts at the diagram id', rules.length > 0 && rules.every(r => r.type === 1 && r.selectorText.split(',').every(s => s.trim().indexOf('#' + id) === 0)), id);
    return JSON.stringify(results);
    """#)

// 2. Sixteen kinds of diagram: nothing Mermaid draws is lost.
runChecks("diagram kinds", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    const kinds = {
      flowchart: 'graph TD\n A[Start]-->B{Choice}\n B-->|yes|C[Done]\n classDef big fill:#f9f,stroke:#333,stroke-width:4px\n class A big\n style C fill:#bbf,stroke:#f66,stroke-dasharray: 5 5',
      sequence: 'sequenceDiagram\n participant Alice\n Alice->>Bob: Hello\n Bob-->>Alice: Hi\n Note over Alice,Bob: note\n loop L\n Alice->>Bob: x\n end',
      class: 'classDiagram\n class Animal{+int age\n +eat()}\n Animal <|-- Dog\n Animal : +String name',
      state: 'stateDiagram-v2\n [*] --> Still\n Still --> Moving\n Moving --> [*]\n state Moving {\n  [*] --> A\n }',
      er: 'erDiagram\n CUSTOMER ||--o{ ORDER : places\n CUSTOMER { string name }',
      gantt: 'gantt\n title T\n dateFormat YYYY-MM-DD\n section S\n A :a1, 2024-01-01, 3d\n B :after a1, 2d',
      pie: 'pie title Pets\n "Dogs" : 386\n "Cats" : 85',
      mindmap: 'mindmap\n root((mind))\n  A\n  B',
      journey: 'journey\n title J\n section S\n  Task: 5: Me',
      git: 'gitGraph\n commit\n branch dev\n commit\n checkout main\n merge dev',
      timeline: 'timeline\n title T\n 2002 : A',
      quadrant: 'quadrantChart\n title Q\n x-axis Low --> High\n y-axis Low --> High\n quadrant-1 A\n Campaign A: [0.3, 0.6]',
      xy: 'xychart-beta\n title "S"\n x-axis [a, b]\n bar [1, 2]',
      c4: 'C4Context\n title T\n Person(a, "A")',
      sankey: 'sankey-beta\n a,b,1',
      requirement: 'requirementDiagram\n requirement test_req {\n id: 1\n text: the test text.\n risk: high\n verifymethod: test\n }'
    };
    const parser = document.implementation.createHTMLDocument('');
    function declarations(svgMarkup) {
        const doc = new DOMParser().parseFromString(svgMarkup, 'text/html');
        const list = [];
        doc.querySelectorAll('style').forEach(el => {
            const s = parser.createElement('style');
            s.textContent = el.textContent;
            parser.head.appendChild(s);
            Array.from(s.sheet.cssRules).forEach(rule => {
                for (const property of rule.style) list.push(rule.selectorText.replace(/#[A-Za-z0-9_-]+/, '#ID') + '|' + property + ':' + rule.style.getPropertyValue(property));
            });
            s.remove();
        });
        return list;
    }
    function text(svgMarkup) {
        const doc = new DOMParser().parseFromString(svgMarkup, 'text/html');
        doc.querySelectorAll('style').forEach(s => s.remove());
        return doc.body.textContent.replace(/\s+/g, ' ').trim();
    }
    let serial = 0;
    for (const [kind, source] of Object.entries(kinds)) {
        let drawn;
        try { drawn = await mermaid.render('kind-' + (++serial), source); } catch (e) { note(kind + ': Mermaid draws the sample', false, e); continue; }
        const clean = window.mvKit.sanitizeMermaidSvg(drawn.svg);
        const before = declarations(drawn.svg), after = new Set(declarations(clean));
        // The two declarations the filter refuses on purpose: z-index, and position:absolute on the HTML overlays Mermaid adds
        // to the page body for click callbacks (tooltip, sequence-diagram popup menu), which never sit inside the returned SVG.
        const overlay = /\.(?:mermaidTooltip|actorPopupMenu|actorPopupMenuPanel)\|position:absolute$/;
        const lost = before.filter(d => !after.has(d)).filter(d => d.indexOf('|z-index:') < 0 && !overlay.test(d));
        note(kind + ': every label is kept', text(drawn.svg) === text(clean), text(drawn.svg).slice(0, 80) + ' / ' + text(clean).slice(0, 80));
        note(kind + ': every style declaration is kept', before.length > 0 && lost.length === 0, 'declarations ' + before.length + ', lost: ' + lost.slice(0, 3).join(' ; '));
    }
    return JSON.stringify(results);
    """#)

// 3. Hostile SVG.
runChecks("hostile SVG", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    window.__pwn = 0;
    const corpus = {
      'a script element': '<svg id="a1"><script>window.__pwn = 1</script><rect/></svg>',
      'event handlers': '<svg id="a2" onload="window.__pwn = 2"><rect onclick="window.__pwn = 2" onmouseover="window.__pwn = 2"/></svg>',
      'a script and a handler in foreignObject': '<svg id="a3"><foreignObject><script>window.__pwn = 3</script><div onclick="window.__pwn = 3">x</div></foreignObject></svg>',
      'an iframe, a form, an object and an embed in foreignObject': '<svg id="a4"><foreignObject><iframe srcdoc="<script>parent.__pwn = 4</script>"></iframe><form action="https://evil.invalid"></form><object data="x"></object><embed src="x"></foreignObject></svg>',
      'javascript: links': '<svg id="a5"><a href="javascript:window.__pwn = 5"><text>x</text></a><a xlink:href="javascript:window.__pwn = 5"><text>y</text></a></svg>',
      'an @import': '<svg id="a6"><style>@import url(https://evil.invalid/x.css); @import "https://evil.invalid/y.css";</style><rect/></svg>',
      'rules outside the diagram': '<svg id="a7"><style>body{display:none} p{color:red} #a7 rect{fill:red} #a7 ~ p{color:blue} #a7 + p{color:blue}</style><rect/></svg>',
      'remote loads from CSS': '<svg id="a8"><style>#a8 rect{background:url(https://evil.invalid/p.png);list-style-image:url(https://evil.invalid/q.png);cursor:url(https://evil.invalid/c.png),auto;filter:url(https://evil.invalid/f.svg#x)}</style><rect/></svg>',
      'CSS escapes and comments': '<svg id="a9"><style>#a9 rect{position:f\\69xed;background:\\75rl(https://evil.invalid/p.png);z-index:9;color:/**/red;-moz-binding:url(x);behavior:url(x)}</style><rect/></svg>',
      'a CSS expression': '<svg id="b1"><style>#b1 rect{width:expression(window.__pwn = 6);fill:red}</style><rect/></svg>',
      'markup in a CSS string': '<svg id="b2"><style>#b2 a{content:"</style><img src=x onerror=window.__pwn=7>"}</style></svg>',
      'a mutation payload with </p>': '<svg></p><style><a id="</style><img src=1 onerror=window.__pwn=8>">',
      'a mutation payload with mglyph': '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=window.__pwn=9&gt;">',
      'a mutation payload in foreignObject': '<svg id="b3"><foreignObject><p><svg><desc><style><a id="</style><img src=1 onerror=window.__pwn=10>"></style></desc></svg></p></foreignObject></svg>',
      'a style in foreignObject': '<svg id="b4"><foreignObject><style>body{display:none}</style><style><img src=x onerror=window.__pwn=11></style><div>y</div></foreignObject></svg>',
      'a comment that closes a style': '<svg id="b5"><style><!--</style><img src=x onerror=window.__pwn=12>--></style></svg>',
      'nested foreignObject': '<svg id="b6"><foreignObject><svg><foreignObject><img src=x onerror=window.__pwn=13></foreignObject></svg></foreignObject></svg>',
      'a hostile style attribute': '<svg id="b7"><rect style="position:fixed;background:url(https://evil.invalid/p.png);fill:blue" width="5" height="5"/></svg>'
    };
    const host = document.createElement('div');
    document.body.appendChild(host);
    const bodyBefore = getComputedStyle(document.body).display;
    for (const [name, raw] of Object.entries(corpus)) {
        const clean = window.mvKit.sanitizeMermaidSvg(raw);
        host.innerHTML = clean;
        const once = host.innerHTML;
        host.innerHTML = once;
        await new Promise(r => setTimeout(r, 40));
        const all = Array.from(host.querySelectorAll('*'));
        const handlers = all.filter(e => Array.from(e.attributes).some(a => /^on/i.test(a.name))).length;
        const jsLinks = all.filter(e => Array.from(e.attributes).some(a => /javascript:/i.test(a.value))).length;
        const imports = Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules)).filter(r => r.type === 3).length;
        const outside = Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules))
            .filter(r => r.type === 1 && !r.selectorText.split(',').every(sel => /^#(a\d|b\d)(?![\w-])/.test(sel.trim()))).length;
        const loads = all.filter(e => /url\(\s*["']?https?:/i.test(e.getAttribute('style') || '')).length +
            Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules)).filter(r => /url\(\s*["']?https?:/i.test(r.cssText)).length;
        const fixed = all.filter(e => getComputedStyle(e).position === 'fixed').length;
        const rect = host.querySelector('rect');
        const background = rect ? getComputedStyle(rect).backgroundImage : 'none';
        note('hostile SVG neutralised: ' + name,
             host.querySelectorAll('script').length === 0 && handlers === 0 && jsLinks === 0 && imports === 0 && outside === 0 && loads === 0 &&
             fixed === 0 && background === 'none' && once === host.innerHTML && window.__pwn === 0 && getComputedStyle(document.body).display === bodyBefore,
             JSON.stringify({ clean: clean.slice(0, 200), handlers, jsLinks, imports, outside, loads, fixed, background, pwn: window.__pwn }));
        host.innerHTML = '';
    }
    await new Promise(r => setTimeout(r, 300));
    note('nothing the hostile SVG carried ran', window.__pwn === 0, window.__pwn);
    host.remove();
    return JSON.stringify(results);
    """#)

// 4. <style> stays forbidden everywhere else.
runChecks("other profiles", #"""
    const results = [];
    const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
    for (const profile of ['markdown', 'book', 'discussion', 'insight']) {
        const clean = window.mvKit.sanitizeHtml('<p>kept</p><style>body{display:none}</style><svg id="x"><style>#x rect{fill:red}</style><rect/></svg>', profile);
        note('the ' + profile + ' profile still drops <style>', clean.indexOf('kept') >= 0 && clean.toLowerCase().indexOf('<style') < 0, clean);
    }
    return JSON.stringify(results);
    """#)

print(failures == 0 ? "All Mermaid SVG checks passed" : "\(failures) Mermaid SVG check(s) failed")
exit(failures == 0 ? 0 : 1)
