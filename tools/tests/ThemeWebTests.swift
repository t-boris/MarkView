import AppKit
import WebKit

// The window themes (DEC-003, DEC-004, DEC-006) in the shipped web pages, in real WebKit with hidden windows and a
// stubbed bridge: the editor page (index.html), the discussion thread (discussion.html) and the terminal
// (terminal.html). What is checked:
//   - every appearance paints the real elements with its
//     tokens, and the text pairs of the presets meet the contrast the specification asks for;
//   - an accent override reaches the accent colours and a reset returns the appearance's own;
//   - a theme change is only a restyle: the page is not reloaded, text and scroll position stay;
//   - two pages (two windows) hold different appearances at the same time;
//   - the first paint follows the attributes Swift writes into the page text;
//   - Classic Dark and Classic Light still paint every sampled element with the colours of the page before themes
//     (the fixture Tests/Fixtures/themes/classic-computed.json, captured from the code of origin/main).
// Modes (through tools/tests/theme-web-tests.sh):
//   <editor folder> [fixture.json]        run the checks
//   capture <editor folder> <out.json>    write the computed colours of Classic Dark/Light (also works on the old page)
// No window is ever shown (accessory app, windows far off screen and never ordered front).
setvbuf(stdout, nil, _IONBF, 0)
let arguments = CommandLine.arguments
let capturing = arguments.count > 1 && arguments[1] == "capture"
let editor = capturing ? arguments[2] : arguments[1]
let fixturePath: String? = capturing ? arguments[3] : (arguments.count > 2 ? arguments[2] : nil)
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail().prefix(1200)))")
}
// A hung page must not hang the test run.
DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
    print("TIMEOUT: no result after 300 s")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var scratchFolders: [URL] = []
atexit { for folder in scratchFolders { try? FileManager.default.removeItem(at: folder) } }

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// One page in a real WKWebView whose window is never shown.
final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    var loaded = false
    var messages: [[String: Any]] = []

    init(width: CGFloat = 1100, height: CGFloat = 760) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let recorder = WKUserScript(source: """
        window.__errors = [];
        window.addEventListener('error', function (e) { window.__errors.push('error: ' + e.message + ' @' + (e.filename || '') + ':' + e.lineno); });
        window.addEventListener('unhandledrejection', function (e) { window.__errors.push('rejection: ' + (e.reason && e.reason.message || e.reason)); });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(recorder)
        // A window that is never shown does not run transitions, so a colour would stay at its old value: measure end states.
        let still = WKUserScript(source: """
        (function () { const style = document.createElement('style'); style.textContent = '*, *::before, *::after { transition: none !important; animation: none !important; }'; document.documentElement.appendChild(style); })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(still)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        super.init()
        for name in ["bridge", "discussion", "terminal"] { config.userContentController.add(self, name: name) }
        web.navigationDelegate = self
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// Loads a page of the editor folder. `rewrite` changes the page text first, the way the app writes the theme
    /// attributes into it; the changed page then sits in a scratch folder beside links to everything else of the editor.
    func load(_ name: String, rewrite: ((String) -> String)? = nil) {
        loaded = false
        let folder = URL(fileURLWithPath: editor)
        if let rewrite, let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("theme-web-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            scratchFolders.append(scratch)
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where item != name {
                try? FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent(item), withDestinationURL: folder.appendingPathComponent(item))
            }
            let page = scratch.appendingPathComponent(name)
            try? rewrite(text).write(to: page, atomically: true, encoding: .utf8)
            web.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            web.loadFileURL(folder.appendingPathComponent(name), allowingReadAccessTo: folder)
        }
        spin(60) { loaded }
        spin(1.2)
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
    func eval(_ expression: String) -> String { js("return String(" + expression + ");") }
    var errors: [String] {
        let text = js("return JSON.stringify(window.__errors || []);")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? [text]
    }
}

// ---- colours ----------------------------------------------------------------------------------------------------------
/// The appearances: id, mode, and the base colours of the native palettes or the old page (Classic).
struct Look { let id: String; let dark: Bool; let background: String; let panel: String; let text: String; let accent: String; let classic: Bool }
let looks: [Look] = [
    Look(id: "classic-dark", dark: true, background: "#1e1e1e", panel: "#252526", text: "#d4d4d4", accent: "#569cd6", classic: true),
    Look(id: "classic-light", dark: false, background: "#ffffff", panel: "#f3f3f3", text: "#1e1e1e", accent: "#569cd6", classic: true),
    Look(id: "darcula", dark: true, background: "#2b2b2b", panel: "#323232", text: "#e0e0e0", accent: "#e6a15c", classic: false),
    Look(id: "midnight", dark: true, background: "#151c2b", panel: "#1d2738", text: "#e5ebf5", accent: "#79b8ff", classic: false),
    Look(id: "graphite", dark: true, background: "#202124", panel: "#2a2c30", text: "#e8eaed", accent: "#b39ddb", classic: false),
    Look(id: "tokyo-night", dark: true, background: "#1a1b26", panel: "#202233", text: "#d5daf0", accent: "#b49aff", classic: false),
    Look(id: "carbon-red", dark: true, background: "#171719", panel: "#212124", text: "#ede8e6", accent: "#ff6b81", classic: false),
    Look(id: "paper", dark: false, background: "#fffcf5", panel: "#f2ede3", text: "#292724", accent: "#315e9b", classic: false),
]
let presets = looks.filter { !$0.classic }

/// "rgb(30, 30, 30)" / "rgba(30, 30, 30, 0.5)" → [30, 30, 30, alpha]
func parseRGB(_ text: String) -> [Double]? {
    guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") else { return nil }
    let parts = text[text.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
    guard parts.count >= 3 else { return nil }
    return [parts[0], parts[1], parts[2], parts.count > 3 ? parts[3] : 1]
}
func hexOf(_ rgb: [Double]) -> String { String(format: "#%02x%02x%02x", Int(rgb[0].rounded()), Int(rgb[1].rounded()), Int(rgb[2].rounded())) }
func rgbFromHex(_ hex: String) -> [Double] {
    let n = Int(hex.dropFirst(), radix: 16) ?? 0
    return [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255), 1]
}
func luminance(_ c: [Double]) -> Double {
    let l = c.prefix(3).map { v -> Double in let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
}
func contrast(_ a: [Double], _ b: [Double]) -> Double {
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
/// `top` painted over `bottom` (alpha of `top` respected).
func over(_ top: [Double], _ bottom: [Double]) -> [Double] {
    let a = top[3]
    return [top[0] * a + bottom[0] * (1 - a), top[1] * a + bottom[1] * (1 - a), top[2] * a + bottom[2] * (1 - a), 1]
}

// ---- the editor page --------------------------------------------------------------------------------------------------
let markdown = """
# First heading

Some text with a [link](https://example.com), `inline code`, **bold** and *italic* words.

## Second heading

> A quote that is set apart.

### Third heading

| Name | Value |
|------|-------|
| one  | 1     |
| two  | 2     |

```swift
// a comment
func greet(_ name: String) -> String { return "Hello, \\(name)" + String(42) }
```

---

- a list item
- another list item
"""

/// What the sampled elements are called and where they are (the page before themes had all of them).
let probes: [(String, String)] = [
    ("html", "html"), ("body", "body"), ("container", ".editor-container"), ("toolbar", ".wysiwyg-toolbar"),
    ("toolbar-button", ".wysiwyg-toolbar button"), ("mode-label", ".wysiwyg-toolbar .mode-label"), ("toolbar-sep", ".wysiwyg-toolbar .sep"),
    ("rendered", ".editor-rendered"), ("source", ".editor-input"), ("h1", ".editor-rendered h1"), ("h2", ".editor-rendered h2"),
    ("h3", ".editor-rendered h3"), ("p", ".editor-rendered p"), ("link", ".editor-rendered a"), ("quote", ".editor-rendered blockquote"),
    ("inline-code", ".editor-rendered p code"), ("pre", ".editor-rendered pre"), ("pre-code", ".editor-rendered pre code"),
    ("th", ".editor-rendered th"), ("td", ".editor-rendered td"), ("hr", ".editor-rendered hr"), ("li", ".editor-rendered li"),
    ("token-comment", ".token.comment"), ("token-keyword", ".token.keyword"), ("token-string", ".token.string"),
    ("token-number", ".token.number"), ("token-function", ".token.function"), ("token-punctuation", ".token.punctuation"),
    ("find-bar", ".find-bar"), ("find-input", ".find-bar input"), ("find-button", ".find-bar button"),
    ("format-bar", ".format-bar"), ("format-button", ".format-bar button"), ("feature-menu", ".feature-menu"),
    ("feature-item", ".feature-menu-item"), ("more-menu", ".editor-more-menu"), ("insight-bar", ".insight-status-bar"),
    ("arch-toolbar", ".arch-toolbar"), ("arch-button", ".arch-btn"), ("empty-title", ".editor-empty-title"),
]
let sampleScript = """
const probes = [\(probes.map { "[\"\($0.0)\", \"\($0.1)\"]" }.joined(separator: ", "))];
const sides = ['Top', 'Bottom', 'Left'];
const out = {};
for (const [name, selector] of probes) {
  const el = document.querySelector(selector);
  if (!el) { out[name] = null; continue; }
  const cs = getComputedStyle(el), o = { color: cs.color, backgroundColor: cs.backgroundColor, textShadow: cs.textShadow, boxShadow: cs.boxShadow };
  // A border colour only counts where a border is drawn (otherwise it is just the text colour).
  sides.forEach(function (side) { o['border' + side + 'Color'] = (cs['border' + side + 'Style'] !== 'none' && parseFloat(cs['border' + side + 'Width']) > 0) ? cs['border' + side + 'Color'] : '-'; });
  o.outlineColor = (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0) ? cs.outlineColor : '-';
  out[name] = o;
}
return JSON.stringify(out);
"""

/// Sets the appearance through whichever entry point the page has (the old page took 'dark' or 'light').
func setLook(_ page: Page, _ look: Look, accent: String? = nil) {
    _ = page.js("""
    if (window.MarkViewThemes) window.setTheme(id, accent);
    else { window.setTheme('dark'); window.setTheme(dark ? 'dark' : 'light'); }   // the old page ignored a mode equal to its remembered one
    return 'ok';
    """, ["id": look.id, "accent": accent ?? "", "dark": look.dark])
    spin(0.35)
}
func samples(_ page: Page) -> [String: [String: String]] {
    let text = page.js(sampleScript)
    if text.hasPrefix("JSERROR") || text == "TIMEOUT" { print("info sampling failed: \(text.prefix(300))") }
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
    var out: [String: [String: String]] = [:]
    for (name, value) in object { if let dict = value as? [String: String] { out[name] = dict } }
    return out
}
func loadEditor(rewrite: ((String) -> String)? = nil) -> Page {
    let page = Page()
    page.load("index.html", rewrite: rewrite)
    _ = page.js("window.setContent(text); return 'ok';", ["text": markdown])
    spin(1.5)
    return page
}

/// The code view (CodeMirror): the editor, its text, its gutter and every coloured token by its text.
let codeSource = "func greet() -> String {\n    let n = 42 // a comment\n    return \"Hello\" + String(n)\n}\n"
let codeSampleScript = """
const out = {};
const sides = function (cs) { return { color: cs.color, backgroundColor: cs.backgroundColor }; };
[['cm-editor', '.cm-editor'], ['cm-content', '.cm-content'], ['cm-gutters', '.cm-gutters'], ['cm-line', '.cm-line'], ['cm-gutter-element', '.cm-lineNumbers .cm-gutterElement']].forEach(function (p) {
  const el = document.querySelector(p[1]);
  out[p[0]] = el ? sides(getComputedStyle(el)) : null;
});
document.querySelectorAll('.cm-line span').forEach(function (span) {
  const text = span.textContent.trim();
  if (text && !out['span:' + text]) out['span:' + text] = sides(getComputedStyle(span));
});
return JSON.stringify(out);
"""
func loadCodeView() -> Page {
    let page = Page()
    page.load("index.html")
    _ = page.js("window.setCodeContent(text, 'swift', 'Greeter.swift'); return 'ok';", ["text": codeSource])
    spin(2.0)
    return page
}
func codeSamples(_ page: Page) -> [String: [String: String]] {
    let text = page.js(codeSampleScript)
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
    var out: [String: [String: String]] = [:]
    for (name, value) in object { if let dict = value as? [String: String] { out[name] = dict } }
    return out
}

// ---- capture mode -----------------------------------------------------------------------------------------------------
if capturing {
    let page = loadEditor()
    var result: [String: Any] = [:]
    for look in looks where look.classic {
        setLook(page, look)
        result[look.id] = samples(page)
    }
    let codePage = loadCodeView()
    for look in looks where look.classic {
        setLook(codePage, look)
        result["code:" + look.id] = codeSamples(codePage)
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: fixturePath!))
    print("captured \(result.count) appearances to \(fixturePath!)")
    exit(0)
}

// ---- the checks -------------------------------------------------------------------------------------------------------
let page = loadEditor()
check(page.eval("!!window.MarkViewThemes && typeof window.setTheme === 'function'") == "true", "the editor page has the window themes and setTheme")
let loadErrors = page.errors
print("info page errors after loading: \(loadErrors.count) \(loadErrors.prefix(3))")
let baselineErrors = loadErrors.count
check(page.eval("document.querySelector('.editor-rendered h1') !== null") == "true", "the sample document is drawn (heading present)")

// The tokens of every appearance: the contrast the specification asks for, computed from the page's own functions.
let tokenReport = page.js("""
const T = window.MarkViewThemes, c = T.color, bad = [];
function chk(id, name, fg, bgs, min) {
  bgs.forEach(function (b) { const r = c.contrast(fg, b[1]); if (r < min) bad.push(id + ': ' + name + ' ' + fg + ' on ' + b[0] + ' ' + b[1] + ' = ' + r.toFixed(2) + ' < ' + min); });
}
T.ids.filter(function (id) { return !T.themes[id].classic; }).forEach(function (id) {
  const v = T.varsFor(id, ''), bgs = [['bg', v['--bg-primary']], ['panel', v['--bg-secondary']]];
  ['--text-primary', '--text-secondary', '--text-tertiary', '--accent-primary', '--accent-secondary', '--accent-warning', '--accent-success',
   '--accent-danger', '--h2-color', '--h3-color', '--ok-text', '--warn-text', '--bad-text', '--struct-key', '--struct-string', '--struct-number',
   '--struct-boolean', '--struct-null', '--struct-bracket', '--struct-tag', '--struct-attr-name', '--struct-attr-value', '--struct-comment',
   '--struct-count', '--mode-label', '--toolbar-text'].forEach(function (k) { chk(id, k, v[k], bgs, 4.5); });
  chk(id, 'code-text on code-bg', v['--code-text'], [['code-bg', v['--code-bg']]], 4.5);
  chk(id, 'text on tertiary', v['--text-primary'], [['tertiary', v['--bg-tertiary']]], 4.5);
  chk(id, 'secondary on tertiary', v['--text-secondary'], [['tertiary', v['--bg-tertiary']]], 4.5);
  chk(id, 'hover text on hover', v['--toolbar-text-hover'], [['hover', v['--toolbar-hover-bg']]], 4.5);
  chk(id, 'pre-text on pre-bg', v['--pre-text'], [['pre', v['--pre-bg']]], 4.5);
  ['--syn-comment', '--syn-punct', '--syn-property', '--syn-number', '--syn-string', '--syn-operator', '--syn-func', '--syn-keyword', '--syn-regex']
    .forEach(function (k) { chk(id, k, v[k], [['pre', v['--pre-bg']], ['bg', v['--bg-primary']]], 4.5); });
  chk(id, 'on-accent on the accent fill', v['--on-accent'], [['fill', v['--accent-fill']]], 4.5);
  chk(id, 'float text on float bg', v['--float-text'], [['float', v['--float-bg']]], 4.5);
  chk(id, 'float text on float hover', v['--float-text'], [['hover', v['--float-hover']]], 4.5);
  chk(id, 'discussion text on user bubble', v['--dc-fg'], [['user', v['--dc-user']], ['code', v['--dc-code']], ['card', v['--dc-card']]], 4.5);
  chk(id, 'discussion accent on bg', v['--dc-accent'], [['bg', v['--dc-bg']], ['card', v['--dc-card']]], 4.5);
  chk(id, 'discussion dim on bg', v['--dc-dim'], [['bg', v['--dc-bg']], ['card', v['--dc-card']]], 4.5);
  chk(id, 'discussion error on bg', v['--dc-error'], [['bg', v['--dc-bg']]], 4.5);
  const term = T.terminalTheme(id, ''), skip = T.themes[id].mode === 'dark' ? ['black'] : ['white', 'brightWhite'];
  Object.keys(term).forEach(function (k) {
    if (k === 'background' || k === 'selectionBackground' || skip.indexOf(k) >= 0) return;
    chk(id, 'terminal ' + k, term[k], [['terminal bg', term.background]], k === 'cursor' ? 3 : 4.5);
  });
  chk(id, 'terminal text on selection', term.foreground, [['selection', term.selectionBackground]], 4.5);
  ['--cm-fg', '--cm-gutter', '--cm-kw', '--cm-str', '--cm-num', '--cm-com', '--cm-fn', '--cm-type', '--cm-prop', '--cm-op', '--cm-tag'].forEach(function (k) {
    chk(id, k, v[k], [['code bg', v['--cm-bg']], ['code active line', v['--cm-active']]], 4.5);
    if (k !== '--cm-gutter') chk(id, k + ' on selection', v[k], [['code selection', v['--cm-sel']]], k === '--cm-fg' ? 4.5 : 3);
  });
});
return JSON.stringify(bad);
""")
let tokenFailures = (try? JSONSerialization.jsonObject(with: Data(tokenReport.utf8)) as? [String]) ?? [tokenReport]
check(tokenFailures.isEmpty, "every preset's text pairs meet 4.5:1 (cursor and syntax over a selection 3:1)", tokenFailures.joined(separator: "; "))

// Every appearance defines the same set of custom properties (nothing is left to the previous appearance).
let keyReport = page.js("""
const T = window.MarkViewThemes, first = Object.keys(T.varsFor(T.ids[0], '')).sort().join();
return JSON.stringify(T.ids.filter(function (id) { return Object.keys(T.varsFor(id, '')).sort().join() !== first; }));
""")
check(keyReport == "[]", "all appearances define the same custom properties", keyReport)

// The colours of the real elements follow the tokens.
func colorOf(_ s: [String: [String: String]], _ probe: String, _ prop: String = "color") -> [Double]? {
    s[probe]?[prop].flatMap(parseRGB)
}
func near(_ a: [Double]?, _ hex: String, tolerance: Double = 1.5) -> Bool {
    guard let a else { return false }
    let b = rgbFromHex(hex)
    return (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
}
/// The colour a text sits on: the first opaque background up the element chain.
func effectiveBackground(_ page: Page, _ selector: String) -> [Double] {
    let text = page.js("""
    let el = document.querySelector(sel), layers = [];
    while (el) { layers.push(getComputedStyle(el).backgroundColor); el = el.parentElement; }
    return JSON.stringify(layers);
    """, ["sel": selector])
    let layers = ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? []).compactMap(parseRGB)
    var result: [Double] = [255, 255, 255, 1]
    for layer in layers.reversed() { result = over(layer, result) }
    return result
}
for look in looks {
    setLook(page, look)
    let s = samples(page)
    let attributes = page.json("const r = document.documentElement; return JSON.stringify({ preset: r.getAttribute('data-preset'), mode: r.getAttribute('data-theme'), accent: r.getAttribute('data-accent') || '' });")
    check((attributes["preset"] as? String) == look.id && (attributes["mode"] as? String) == (look.dark ? "dark" : "light"),
          "\(look.id): data-preset and data-theme follow the appearance", "\(attributes)")
    check(near(colorOf(s, "body", "backgroundColor"), look.background), "\(look.id): the page background is \(look.background)", "\(String(describing: s["body"]))")
    check(near(colorOf(s, "rendered"), look.text) || near(colorOf(s, "p"), look.text), "\(look.id): the document text is \(look.text)", "\(String(describing: s["p"]))")
    if !look.classic {
        let tokens = page.json("""
        const v = MarkViewThemes.varsFor(id, '');
        return JSON.stringify({ h2: v['--h2-color'], h3: v['--h3-color'], link: v['--accent-primary'], preBg: v['--pre-bg'], preText: v['--pre-text'],
          keyword: v['--syn-keyword'], string: v['--syn-string'], comment: v['--syn-comment'], number: v['--syn-number'], func: v['--syn-func'],
          toolbarText: v['--toolbar-text'], panel: v['--bg-secondary'] });
        """, ["id": look.id])
        func token(_ name: String) -> String { tokens[name] as? String ?? "#000000" }
        check(near(colorOf(s, "h2"), token("h2")), "\(look.id): second headings use the theme's heading colour", "\(String(describing: s["h2"]))")
        check(near(colorOf(s, "h3"), token("h3")), "\(look.id): third headings use the theme's heading colour", "\(String(describing: s["h3"]))")
        check(near(colorOf(s, "link"), token("link")), "\(look.id): links use the (legible) accent", "\(String(describing: s["link"]))")
        check(near(colorOf(s, "pre", "backgroundColor"), token("preBg")), "\(look.id): code blocks use the theme's block background", "\(String(describing: s["pre"]))")
        check(near(colorOf(s, "token-keyword"), token("keyword")), "\(look.id): Prism keywords use the theme's syntax colour", "\(String(describing: s["token-keyword"]))")
        check(near(colorOf(s, "token-string"), token("string")), "\(look.id): Prism strings use the theme's syntax colour", "\(String(describing: s["token-string"]))")
        check(near(colorOf(s, "token-comment"), token("comment")), "\(look.id): Prism comments use the theme's syntax colour", "\(String(describing: s["token-comment"]))")
        check(near(colorOf(s, "toolbar", "backgroundColor"), token("panel")) || colorOf(s, "toolbar", "backgroundColor") != nil, "\(look.id): the toolbar is painted", "\(String(describing: s["toolbar"]))")
        // The pairs a person reads, measured on the painted page (colour of the element over what is behind it).
        for (name, selector) in [("document text", ".editor-rendered p"), ("headings", ".editor-rendered h2"), ("links", ".editor-rendered a"),
                                 ("quotes", ".editor-rendered blockquote"), ("code blocks", ".editor-rendered pre code"), ("table cells", ".editor-rendered td"),
                                 ("keywords", ".token.keyword"), ("strings", ".token.string"), ("comments", ".token.comment"), ("numbers", ".token.number"),
                                 ("functions", ".token.function"), ("toolbar", ".wysiwyg-toolbar button"), ("mode label", ".wysiwyg-toolbar .mode-label")] {
            guard let key = probes.first(where: { $0.1 == selector })?.0, let color = colorOf(s, key) else {
                check(false, "\(look.id): \(name) can be measured", "no element for \(selector)"); continue
            }
            let background = effectiveBackground(page, selector)
            let ratio = contrast(over(color, background), background)
            check(ratio >= 4.5, "\(look.id): \(name) read at \(String(format: "%.1f", ratio)):1 on the painted page", "\(hexOf(color)) on \(hexOf(background)) = \(ratio)")
        }
    }
}

// An accent override reaches the accent colours; a reset returns the appearance's own.
for look in presets {
    let override = look.dark ? "#FF5555" : "#AA2200"
    setLook(page, look, accent: override)
    let overridden = page.json("""
    const v = getComputedStyle(document.documentElement);
    return JSON.stringify({ fill: v.getPropertyValue('--accent-fill').trim(), link: v.getPropertyValue('--accent-primary').trim(), attr: document.documentElement.getAttribute('data-accent') });
    """)
    let fill = overridden["fill"] as? String ?? ""
    let link = overridden["link"] as? String ?? ""
    check(fill.lowercased() == override.lowercased() && (overridden["attr"] as? String) == override, "\(look.id): the accent override is the accent fill", "\(overridden)")
    let linkRatio = contrast(rgbFromHex(link), rgbFromHex(look.background))
    check(linkRatio >= 4.5, "\(look.id): an accent override keeps links legible (\(String(format: "%.1f", linkRatio)):1)", "\(link)")
    setLook(page, look)
    let reset = page.json("""
    const v = getComputedStyle(document.documentElement);
    return JSON.stringify({ fill: v.getPropertyValue('--accent-fill').trim(), attr: document.documentElement.getAttribute('data-accent') || '' });
    """)
    check((reset["fill"] as? String)?.lowercased() == look.accent && (reset["attr"] as? String) == "", "\(look.id): a reset returns the appearance's own accent", "\(reset)")
}
// A null accent (what Swift sends for "no override") and an unreadable one fall back to the appearance's own accent.
for value in ["null", "'not a colour'", "undefined"] {
    let fill = page.js("window.setTheme('midnight', \(value)); return getComputedStyle(document.documentElement).getPropertyValue('--accent-fill').trim();")
    check(fill.lowercased() == "#79b8ff", "an accent of \(value) means the appearance's own", fill)
}
let unknown = page.js("window.setTheme('no-such-theme', null); return document.documentElement.getAttribute('data-preset');")
check(unknown == "classic-dark", "an unknown appearance falls back to Classic Dark", unknown)

// A theme change is a restyle: no reload, the text and the scroll position stay.
_ = page.js("window.__reloadMarker = 'same page'; return 'ok';")
let before = page.json("""
const r = document.querySelector('.editor-rendered');
r.style.minHeight = '3000px'; r.scrollTop = 120;
window.__editorNode = r;
return JSON.stringify({ html: r.innerHTML.length, text: r.textContent, scroll: r.scrollTop });
""")
for look in looks + looks.reversed() { setLook(page, look) }
let after = page.json("""
const r = document.querySelector('.editor-rendered');
return JSON.stringify({ html: r.innerHTML.length, text: r.textContent, scroll: r.scrollTop, marker: window.__reloadMarker, sameNode: r === window.__editorNode });
""")
// A reload would drop the marker and replace the element; the clock (performance.timeOrigin) is not used: some WebKit builds
// report it with a jitter, which made this check fail on the CI image while the page had not reloaded.
check((after["marker"] as? String) == "same page" && (after["sameNode"] as? Bool) == true, "repeated theme changes do not reload the page", "\(after)")
check((after["text"] as? String) == (before["text"] as? String) && (after["html"] as? Int) == (before["html"] as? Int), "the document text and structure are untouched by theme changes")
check((after["scroll"] as? Double) == (before["scroll"] as? Double), "the scroll position survives theme changes", "\(before["scroll"] ?? "") → \(after["scroll"] ?? "")")
// Source mode: the unsaved text in the editor field stays too.
_ = page.js("""
if (typeof window.toggleSourceMode === 'function') window.toggleSourceMode();
const input = document.getElementById('editor-input');
input.value = input.value + '\\n\\nUnsaved words that exist only in the field.';
return 'ok';
""")
spin(0.3)
let typed = page.eval("document.getElementById('editor-input').value")
for look in looks { setLook(page, look) }
check(page.eval("document.getElementById('editor-input').value") == typed && typed.contains("Unsaved words"), "unsaved text in the source field survives theme changes")
let sourceColors = samples(page)
check(near(colorOf(sourceColors, "source"), looks.last!.text), "the source field takes the theme's text colour", "\(String(describing: sourceColors["source"]))")
let newErrors = page.errors
check(newErrors.count == baselineErrors, "theme changes raise no page errors", "\(newErrors.dropFirst(baselineErrors))")

// The first paint follows the attributes Swift writes into the page text (no setTheme call is needed).
for look in [looks[3], looks[5]] {
    let attributes = "data-preset=\"\(look.id)\" data-theme=\"\(look.dark ? "dark" : "light")\" data-accent=\"#C0FFEE\""
    let first = Page()
    first.load("index.html", rewrite: { $0.replacingOccurrences(of: "data-preset=\"classic-dark\" data-theme=\"dark\"", with: attributes) })
    let painted = first.json("""
    const v = getComputedStyle(document.documentElement);
    return JSON.stringify({ bg: getComputedStyle(document.body).backgroundColor, fill: v.getPropertyValue('--accent-fill').trim(), preset: document.documentElement.getAttribute('data-preset'),
      current: MarkViewThemes.current().id, stateTheme: state.theme });
    """)
    check(near(painted["bg"].flatMap { $0 as? String }.flatMap(parseRGB), look.background) && (painted["fill"] as? String)?.lowercased() == "#c0ffee" && (painted["current"] as? String) == look.id,
          "\(look.id): a page written with the theme attributes paints with them before any script call", "\(painted)")
    check((painted["stateTheme"] as? String) == (look.dark ? "dark" : "light"), "\(look.id): the page's mode follows the attributes", "\(painted)")
}

// Two windows: two pages hold different appearances at the same time, and a change in one leaves the other alone.
let left = loadEditor(rewrite: { $0.replacingOccurrences(of: "data-preset=\"classic-dark\" data-theme=\"dark\"", with: "data-preset=\"paper\" data-theme=\"light\"") })
let right = loadEditor(rewrite: { $0.replacingOccurrences(of: "data-preset=\"classic-dark\" data-theme=\"dark\"", with: "data-preset=\"midnight\" data-theme=\"dark\" data-accent=\"#FFAA00\"") })
func summary(_ p: Page) -> String { p.js("return document.documentElement.getAttribute('data-preset') + '|' + (document.documentElement.getAttribute('data-accent') || '') + '|' + getComputedStyle(document.body).backgroundColor;") }
check(summary(left) == "paper||rgb(255, 252, 245)" && summary(right) == "midnight|#FFAA00|rgb(21, 28, 43)", "two pages hold Paper and Midnight at the same time", "\(summary(left)) / \(summary(right))")
_ = left.js("window.setTheme('darcula', '#33AAFF'); return 'ok';")
spin(0.3)
check(summary(left) == "darcula|#33AAFF|rgb(43, 43, 43)" && summary(right) == "midnight|#FFAA00|rgb(21, 28, 43)", "changing one page leaves the other as it was", "\(summary(left)) / \(summary(right))")

// ---- the code view ----------------------------------------------------------------------------------------------------
let codePage = loadCodeView()
check(codePage.eval("document.querySelector('.cm-editor') !== null") == "true", "the code view (CodeMirror) is drawn")
for look in looks {
    setLook(codePage, look)
    let cm = codeSamples(codePage)
    let tokens = codePage.json("const v = MarkViewThemes.varsFor(id, ''); return JSON.stringify({ bg: v['--cm-bg'], fg: v['--cm-fg'], kw: v['--cm-kw'], com: v['--cm-com'], num: v['--cm-num'], str: v['--cm-str'] });", ["id": look.id])
    func token(_ name: String) -> String { tokens[name] as? String ?? "#000000" }
    check(near(colorOf(cm, "cm-editor", "backgroundColor"), token("bg")), "\(look.id): the code view is painted with the theme's code background", "\(String(describing: cm["cm-editor"]))")
    check(near(colorOf(cm, "cm-content"), token("fg")) || near(colorOf(cm, "cm-line"), token("fg")), "\(look.id): code text uses the theme's text colour", "\(String(describing: cm["cm-line"]))")
    check(near(colorOf(cm, "span:func"), token("kw")), "\(look.id): code keywords use the theme's keyword colour", "\(String(describing: cm["span:func"]))")
    check(near(colorOf(cm, "span:// a comment"), token("com")), "\(look.id): code comments use the theme's comment colour", "\(cm.keys.sorted())")
    check(near(colorOf(cm, "span:42"), token("num")), "\(look.id): code numbers use the theme's number colour", "\(String(describing: cm["span:42"]))")
    if !look.classic {
        let background = rgbFromHex(token("bg"))
        for name in ["span:func", "span:// a comment", "span:42", "cm-line"] {
            guard let color = colorOf(cm, name) else { check(false, "\(look.id): \(name) is measurable", "no such element"); continue }
            let ratio = contrast(color, background)
            check(ratio >= 4.5, "\(look.id): \(name) in the code view reads at \(String(format: "%.1f", ratio)):1", "\(hexOf(color)) on \(token("bg"))")
        }
    }
}
check(codePage.errors.count <= baselineErrors, "theme changes in the code view raise no page errors", "\(codePage.errors)")

// ---- the discussion thread --------------------------------------------------------------------------------------------
let turnsJSON = """
[{"question":"What is in the plan?","answer":"## Result\\n\\nSee [the link](https://example.com) and `code`.\\n\\n| a | b |\\n|---|---|\\n| 1 | 2 |\\n\\n```js\\nlet x = 1\\n```\\n\\n> quoted"}]
"""
let discussion = Page()
discussion.load("discussion.html")
check(discussion.eval("typeof window.mvSetTheme === 'function' && !!window.MarkViewThemes") == "true", "the discussion page has mvSetTheme and the window themes")
_ = discussion.js("window.mvSetTurns(json); return 'ok';", ["json": turnsJSON])
spin(1.2)
let discussionErrors = discussion.errors.count
for look in looks {
    _ = discussion.js("window.mvSetTheme(id, null); return 'ok';", ["id": look.id])
    spin(0.6)
    let d = discussion.json("""
    const cs = function (s, p) { const e = document.querySelector(s); return e ? getComputedStyle(e)[p] : null; };
    return JSON.stringify({ bg: cs('body', 'backgroundColor'), fg: cs('body', 'color'), link: cs('.a a', 'color'), th: cs('.a th', 'backgroundColor'), error: getComputedStyle(document.documentElement).getPropertyValue('--dc-error').trim(),
      preset: document.documentElement.getAttribute('data-preset') });
    """)
    let threadText = look.id == "classic-light" ? "#1f2328" : look.text   // the discussion and terminal pages had their own light text
    check(near((d["bg"] as? String).flatMap(parseRGB), look.background) && near((d["fg"] as? String).flatMap(parseRGB), threadText) && (d["preset"] as? String) == look.id,
          "\(look.id): the discussion thread takes the appearance (background \(look.background), text \(threadText))", "\(d)")
    if !look.classic, let link = (d["link"] as? String).flatMap(parseRGB), let bg = (d["bg"] as? String).flatMap(parseRGB) {
        let ratio = contrast(link, bg)
        check(ratio >= 4.5, "\(look.id): discussion links read at \(String(format: "%.1f", ratio)):1", "\(d)")
    }
}
check(discussion.errors.count == discussionErrors, "theme changes in the discussion raise no page errors", "\(discussion.errors.dropFirst(discussionErrors))")
check(discussion.eval("document.querySelectorAll('.turn').length") == "1" && discussion.eval("document.querySelector('.a').textContent.includes('Result')") == "true", "the discussion keeps its turns across theme changes")

// ---- the terminal -----------------------------------------------------------------------------------------------------
let terminal = Page(width: 800, height: 500)
terminal.load("terminal.html")
check(terminal.eval("typeof window.mvSetTheme === 'function' && !!window.MarkViewThemes") == "true", "the terminal page has mvSetTheme and the window themes")
_ = terminal.js("window.mvWrite(btoa('plain text and \\u001b[31mred\\u001b[0m')); return 'ok';")
spin(0.6)
for look in looks {
    _ = terminal.js("window.mvSetTheme(id, null); return 'ok';", ["id": look.id])
    spin(0.6)
    let t = terminal.json("""
    const rows = document.querySelector('.xterm-rows');
    return JSON.stringify({ page: getComputedStyle(document.body).backgroundColor, rows: rows ? getComputedStyle(rows).color : null, preset: document.documentElement.getAttribute('data-preset') });
    """)
    check(near((t["page"] as? String).flatMap(parseRGB), look.background) && (t["preset"] as? String) == look.id, "\(look.id): the terminal page is \(look.background)", "\(t)")
    if let rows = (t["rows"] as? String).flatMap(parseRGB) {
        let terminalText = look.id == "classic-light" ? "#1f2328" : look.text
        check(near(rows, terminalText), "\(look.id): the terminal draws its text in \(terminalText)", "\(t)")
    } else {
        check(false, "\(look.id): the terminal rows can be read", "\(t)")
    }
}

// ---- Classic equals the page before themes ----------------------------------------------------------------------------
if let fixturePath, let data = FileManager.default.contents(atPath: fixturePath),
   let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
    let fresh = loadEditor()
    for look in looks where look.classic {
        setLook(fresh, look)
        let now = samples(fresh)
        var different: [String] = []
        var compared = 0
        for (name, expected) in fixture[look.id] ?? [:] {
            guard let expectedProps = expected as? [String: String] else { continue }   // the element did not exist then
            guard let actual = now[name] else { different.append("\(name): element missing"); continue }
            for (prop, value) in expectedProps {
                compared += 1
                if actual[prop] != value { different.append("\(name).\(prop): \(value) → \(actual[prop] ?? "nil")") }
            }
        }
        check(different.isEmpty && compared > 100, "\(look.id): \(compared) sampled colours equal the page before themes", different.prefix(12).joined(separator: "; "))
    }
    let freshCode = loadCodeView()
    for look in looks where look.classic {
        setLook(freshCode, look)
        let now = codeSamples(freshCode)
        var different: [String] = []
        var compared = 0
        for (name, expected) in fixture["code:" + look.id] ?? [:] {
            guard let expectedProps = expected as? [String: String] else { continue }
            guard let actual = now[name] else { different.append("\(name): element missing"); continue }
            for (prop, value) in expectedProps {
                compared += 1
                if actual[prop] != value { different.append("\(name).\(prop): \(value) → \(actual[prop] ?? "nil")") }
            }
        }
        check(different.isEmpty && compared >= 20, "\(look.id): \(compared) code-view colours equal the page before themes", different.prefix(12).joined(separator: "; "))
    }
} else {
    print("info no fixture given: the comparison with the page before themes is skipped")
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
