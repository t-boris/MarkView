import AppKit
import WebKit

// BUG-111: the shipping X-Ray page in WebKit. The Logical view of a project whose components are linked in a long chain used to open
// as a thin strip (laid out to the right, as wide as the chain is long) that the fit shrank to unreadable labels on a canvas nearly as
// tall as it is wide. The top level now flows to the right or downwards, whichever can be shown larger.
// Run through tools/tests/xray-layout-web-tests.sh.
let editor = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(700)))")
}
final class Bridge: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
    /// The payloads the page posted for one X-Ray action.
    func sent(_ action: String) -> [[String: Any]] {
        messages.compactMap { $0["payload"] as? [String: Any] }.filter { $0["action"] as? String == action }
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
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900), configuration: config)
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
func js(_ body: String, timeout: TimeInterval = 30) -> String {
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

// A small project (Logical and Structure views), and a comparison with an earlier commit: two changed files, one new file,
// and two removed ones - one in a folder that still exists (src/ui) and one in a folder that is gone (src/legacy).
let prelude = """
window.make = function(opts) {
    opts = opts || {};
    const sha = 'a'.repeat(40);
    const sizes = { 'src/core/engine.js': 120, 'src/core/util.js': 40, 'src/core/fresh.js': 30, 'src/ui/view.js': 200, 'src/ui/panel.js': 80 };
    const owner = path => path.startsWith('src/core') ? 'core' : 'ui';
    const modules = [{ id: 'm:', kind: 'root', name: 'project', files: 5, loc: 470 },
        { id: 'm:src', parent: 'm:', kind: 'dir', name: 'src', path: 'src', files: 5 },
        { id: 'm:src/core', parent: 'm:src', kind: 'dir', name: 'core', path: 'src/core', files: 3 },
        { id: 'm:src/ui', parent: 'm:src', kind: 'dir', name: 'ui', path: 'src/ui', files: 2 }];
    const logical = [{ id: 'l:', kind: 'root', name: 'project' },
        { id: 'l:c:core', parent: 'l:', kind: 'component', name: 'Core', files: 3 },
        { id: 'l:c:ui', parent: 'l:', kind: 'component', name: 'UI', files: 2 }];
    const metrics = {};
    Object.keys(sizes).forEach(path => {
        modules.push({ id: 'm:' + path, parent: 'm:src/' + path.split('/')[1], kind: 'file', name: path.split('/').pop(), path, language: 'javascript', loc: sizes[path], files: 1 });
        logical.push({ id: 'l:f:' + path, parent: 'l:c:' + owner(path), kind: 'file', name: path.split('/').pop(), path, language: 'javascript', loc: sizes[path], files: 1 });
        metrics['m:' + path] = { loc: sizes[path], complexity: 10, commits: 3, bugfixes: 0, isTest: false, tested: true, testFiles: [], lastChanged: 1790000000,
            functions: 4, maxFunctionComplexity: path.includes('engine') ? 25 : 3, maxFunctionName: 'run', complexFunctions: path.includes('engine') ? 1 : 0 };
    });
    const files = [
        { path: 'src/core/engine.js', additions: 10, deletions: 2, ranges: [[5, 14]] },
        { path: 'src/ui/view.js', additions: 3, deletions: 1, ranges: [[20, 22]] },
        { path: 'src/core/fresh.js', additions: 30, deletions: 0, ranges: [[1, 30]] },
        { path: 'src/ui/old-panel.js', additions: 0, deletions: 60, ranges: [], deleted: true },
        { path: 'src/legacy/old.js', additions: 0, deletions: 40, ranges: [], deleted: true }];
    const payload = {
        mode: opts.folder ? 'folder' : opts.project ? undefined : 'pr', root: '/tmp/project', busy: false, filters: [], describing: [], outlining: [],
        searchSummaries: {}, searchAnswers: {}, understandingAnswers: {}, edgeNotes: {}, codeSequenceDiagrams: [], codeSequenceInfo: [],
        automaticState: {}, automaticAnalysis: true,
        snapshot: { views: [{ id: 'modules', nodes: modules, edges: [] }, { id: 'logical', nodes: logical, edges: [{ source: 'l:f:src/ui/view.js', target: 'l:f:src/core/engine.js', kind: 'imports', weight: 1 }] }],
            coverage: {}, metrics, deploymentHints: [], scannedAt: '2026-11-08T10:00:00Z',
            components: [{ id: 'core', name: 'Core', purpose: 'The engine' }, { id: 'ui', name: 'UI', purpose: 'The screens' }],
            assignments: { 'src/core': { component: 'core' }, 'src/ui': { component: 'ui' }, 'src': { component: 'core' } }, overrides: {} },
        prSources: [{ id: 'local', title: 'All changes vs main' }, { id: 'at:' + sha, title: 'Working copy vs aaaaaaaa (2026-11-05 14:32) Fix it' }],
        pr: opts.noChange ? undefined : { source: { id: 'at:' + sha, title: 'Working copy vs aaaaaaaa (2026-11-05 14:32) Fix it' }, files, reviewed: false, dependencies: [], chat: [],
            analysis: opts.analysis ? { summary: 'Touches the engine', verdict: 'attention', impact: [{ component: 'core', risk: 'low', note: 'Small and covered' }], risks: [], checks: [] } : undefined },
        history: opts.history };
    return JSON.parse(JSON.stringify(payload));
};
window.cyNow = () => document.getElementById('arch-graph')._cyreg.cy;
window.settle = async function(minNodes) {
    for (let i = 0; i < 300; i++) {
        const g = document.getElementById('arch-graph')._cyreg;
        if (g && g.cy && g.cy.nodes().length >= (minNodes || 1)) break;
        await new Promise(r => setTimeout(r, 50));
    }
    await new Promise(r => setTimeout(r, 900));
};
window.node = id => window.cyNow().getElementById(id);
window.info = id => { const n = window.node(id); return n.length ? { label: n.data('label'), changed: n.data('changed'), removed: n.data('removed'), dimmed: n.data('dimmed'),
    fill: n.data('fill'), parent: n.parent().length ? n.parent().id() : '', border: n.style('border-style'), halo: Number(n.style('underlay-opacity')), w: n.data('w') } : null; };
"""
_ = js(prelude + "return 'ready';")


/// The Logical view of eight components linked as in the report (CLI -> Desktop -> Trading -> Brokers -> Docs, all to External).
let fixture = """
window.fixture = function(extra) {
    const comps = [['Installer and Deploy', 31, 6100], ['CLI and Control Plane', 401, 103000], ['StrikeDesk Desktop', 1200, 302000], ['Trading Core', 64, 13000],
        ['Brokers and Contracts', 288, 109000], ['Ops Tooling', 21, 3600], ['Documentation', 1800, 183000]];
    const logical = [{ id: 'l:', kind: 'root', name: 'project' }];
    comps.forEach((c, i) => logical.push({ id: 'l:c:' + i, parent: 'l:', kind: 'component', name: c[0], purpose: 'Purpose of the component ' + i + ' that wraps over a couple of lines', files: c[1], loc: c[2] }));
    if (extra) logical.push({ id: 'l:c:extra', parent: 'l:', kind: 'component', name: 'Extra', purpose: 'One more', files: 3, loc: 300 });
    logical.push({ id: 'l:ext', parent: 'l:', kind: 'externalGroup', name: 'External' });
    const ids = i => i === 'x' ? 'l:ext' : 'l:c:' + i;
    const links = [[1,2],[1,3],[1,4],[1,5],[1,6],[1,'x'],[2,3],[2,4],[2,6],[2,'x'],[3,4],[3,6],[3,'x'],[4,6],[4,'x'],[0,1],[0,'x'],[5,'x'],[6,'x'],[2,5],[3,5]];
    const edges = links.map(l => ({ source: ids(l[0]), target: ids(l[1]), kind: 'imports', weight: 3 }));
    const p = window.make({ project: true, noChange: true });
    p.snapshot.views = [{ id: 'logical', nodes: logical, edges }, p.snapshot.views[0]];
    return p;
};
window.shape = function() {
    const cy = window.cyNow(), box = cy.nodes().boundingBox({ includeLabels: false });
    // The zoom the page's fit gives it (28 px of padding): the page is off screen here, where its animations never run, so the
    // fit itself is computed instead of read.
    const fit = Math.min((cy.width() - 56) / Math.max(1, box.w), (cy.height() - 56) / Math.max(1, box.h));
    return { canvas: [cy.width(), cy.height()], graph: [Math.round(box.w), Math.round(box.h)], zoom: Number(fit.toFixed(2)),
        shown: [Math.round(box.w * fit), Math.round(box.h * fit)] };
};
return 'ready';
"""
_ = js(fixture)

func shape(_ text: String) -> (canvas: [Double], graph: [Double], zoom: Double, shown: [Double]) {
    let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    return (o["canvas"] as? [Double] ?? [0, 0], o["graph"] as? [Double] ?? [0, 0], o["zoom"] as? Double ?? 0, o["shown"] as? [Double] ?? [0, 0])
}

// MARK: A canvas nearly as tall as it is wide: the chain flows downwards and is shown larger (the report: 0.77 as a strip)
var text = js("""
window.showArchitecture(window.fixture());
document.querySelector('[data-arch-view="logical"]').click();
await window.settle(8);
return JSON.stringify(window.shape());
""")
var s = shape(text)
check(s.canvas[0] > 900 && s.canvas[1] > 600, "the canvas is 'wide and tall' as in the report", text)
check(s.zoom >= 1.0, "the Logical graph is fitted at its own size or larger (0.77 as a strip)", text)
check(s.graph[1] > s.graph[0] * 0.8, "the components are placed in rows that fill the height, not in one thin strip", text)
check(s.shown[1] >= s.canvas[1] * 0.6, "the graph fills most of the canvas height (it filled a quarter of it)", text)

// MARK: A canvas that is wide and low: the chain still flows to the right
text = js("""
document.getElementById('arch-graph').style.height = '280px';
window.cyNow().resize();
window.showArchitecture(window.fixture(true));
await window.settle(9);
return JSON.stringify(window.shape());
""")
s = shape(text)
check(s.canvas[1] < 400, "the canvas is now wide and low", text)
check(s.graph[0] > s.graph[1] * 2.5, "a wide, low canvas keeps the rightward flow, which fits it", text)
check(s.zoom >= 0.68, "and the labels there stay as large as before (0.69 with the rightward flow)", text)

print(failures == 0 ? "All X-Ray layout web checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
