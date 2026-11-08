import AppKit
import WebKit

// The shipping X-Ray page in WebKit, fed a comparison of the working copy with an earlier commit
// (feature x-ray-comparison-by-date, REQ-001, REQ-003, REQ-004). Run through tools/tests/xray-comparison-web-tests.sh.
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
        mode: opts.project ? undefined : 'pr', root: '/tmp/project', busy: false, filters: [], describing: [], outlining: [],
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

// MARK: Focused map (the default of the PR X-Ray)
var text = js("""
window.showArchitecture(window.make());
await window.settle(5);
const ids = window.cyNow().nodes().map(n => n.id()).sort();
return JSON.stringify({ ids, overlay: document.getElementById('arch-overlay').value, overlayShown: !document.getElementById('arch-overlay').hidden,
    map: document.getElementById('arch-pr-map').hidden ? 'hidden' : document.querySelector('#arch-pr-map .on').dataset.archPrMap,
    date: !document.getElementById('arch-pr-date').hidden, views: document.querySelector('[data-arch-view]').parentElement.hidden });
""")
var focused: [String: Any] = [:]
if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { focused = object }
let focusedIds = focused["ids"] as? [String] ?? []
check(!focusedIds.isEmpty, "the focused map is drawn", text)
check(focusedIds.contains("l:f:src/core/engine.js") && focusedIds.contains("l:f:src/ui/view.js") && focusedIds.contains("l:f:src/core/fresh.js"),
      "focused: the changed and the new files are nodes", "\(focusedIds)")
check(!focusedIds.contains("l:f:src/core/util.js") && !focusedIds.contains("l:f:src/ui/panel.js"), "focused: untouched files are left out", "\(focusedIds)")
check(focusedIds.contains("l:f:src/ui/old-panel.js") && focusedIds.contains("l:f:src/legacy/old.js"),
      "focused: removed files are nodes (REQ-003, DEC-006)", "\(focusedIds)")
check(focused["map"] as? String == "focused", "the PR X-Ray opens on the focused map", text)
check(focused["overlay"] as? String == "pr" && focused["overlayShown"] as? Bool == true, "the overlay menu is shown, starting on the change's own colours", text)
check(focused["date"] as? Bool == true && focused["views"] as? Bool == true, "the date button is shown, the view tabs stay hidden", text)

text = js("""
return JSON.stringify({ gone: window.info('l:f:src/legacy/old.js'), ui: window.info('l:f:src/ui/old-panel.js'), changed: window.info('l:f:src/core/engine.js') });
""")
func parse(_ text: String) -> [String: [String: Any]] {
    guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
    return object
}
var facts = parse(text)
check(facts["gone"]?["removed"] as? Int == 1 && (facts["gone"]?["label"] as? String ?? "").hasPrefix("✕ old.js"),
      "focused: a removed file is marked (cross in its name, removed flag)", text)
check(facts["gone"]?["border"] as? String == "dashed" && (facts["gone"]?["halo"] as? Double ?? 0) > 0, "focused: a removed file has a dashed outline and a halo", text)
check((facts["gone"]?["label"] as? String ?? "").contains("removed −40"), "focused: a removed file says how many lines went", text)
check(facts["gone"]?["parent"] as? String == "l:c:core", "focused: a file whose folder is gone stays in the nearest component that is still there (context)", text)
check(facts["ui"]?["parent"] as? String == "l:c:ui", "focused: a file removed from an existing folder stays in that folder's component (context)", text)
check(facts["changed"]?["changed"] as? Int == 1 && (facts["changed"]?["halo"] as? Double ?? 0) > 0 && facts["changed"]?["removed"] as? Int == 0,
      "focused: a changed file carries the change halo, not the removed outline", text)
check((facts["changed"]?["label"] as? String ?? "").contains("+10 −2"), "focused: a changed file counts its lines", text)

// A removed file's diff: selecting it shows its change in the details and opens its old text (REQ-003).
bridge.messages.removeAll()
text = js("""
window.node('l:f:src/legacy/old.js').emit('tap');
await new Promise(r => setTimeout(r, 400));
return document.getElementById('arch-details').innerText;
""")
check(text.contains("old.js"), "focused: selecting a removed file shows it in the details", text)
check(bridge.sent("prFileDiff").contains { $0["path"] as? String == "src/legacy/old.js" }, "focused: the diff of a removed file is asked for", "\(bridge.messages)")
check(bridge.sent("openFile").contains { $0["path"] as? String == "src/legacy/old.js" && $0["fromPR"] as? Bool == true },
      "focused: a removed file opens on its change (as it was)", "\(bridge.messages)")

// MARK: Full map
text = js("""
document.querySelector('[data-arch-pr-map="full"]').click();
await window.settle(8);
const ids = window.cyNow().nodes().map(n => n.id()).sort();
return JSON.stringify({ ids, map: document.querySelector('#arch-pr-map .on').dataset.archPrMap, engine: window.info('l:f:src/core/engine.js'),
    untouched: window.info('l:f:src/core/util.js'), gone: window.info('l:f:src/legacy/old.js'), ui: window.info('l:f:src/ui/old-panel.js'),
    fresh: window.info('l:f:src/core/fresh.js') });
""")
var full: [String: Any] = [:]
if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { full = object }
let fullIds = full["ids"] as? [String] ?? []
check(full["map"] as? String == "full", "the Full map switch is on", text)
check(fullIds.contains("l:f:src/core/util.js") && fullIds.contains("l:f:src/ui/panel.js"), "full: the whole architecture is there, also untouched files", "\(fullIds)")
check(fullIds.count > focusedIds.count, "full: more parts than the focused map (\(fullIds.count) > \(focusedIds.count))")
check(fullIds.contains("l:f:src/legacy/old.js") && fullIds.contains("l:f:src/ui/old-panel.js"), "full: removed files are nodes (REQ-003, DEC-006)", "\(fullIds)")
let fullGone = full["gone"] as? [String: Any] ?? [:]
check(fullGone["removed"] as? Int == 1 && fullGone["border"] as? String == "dashed" && (fullGone["label"] as? String ?? "").hasPrefix("✕ old.js"),
      "full: a removed file is clearly marked", text)
check(fullGone["parent"] as? String == "l:c:core", "full: a removed file stands in the nearest component that is still there", text)
check((full["engine"] as? [String: Any])?["changed"] as? Int == 1, "full: changed parts are highlighted", text)
check((full["fresh"] as? [String: Any])?["changed"] as? Int == 1, "full: a new file is highlighted", text)
check((full["untouched"] as? [String: Any])?["changed"] as? Int == 0 && (full["untouched"] as? [String: Any])?["dimmed"] as? Int == 1,
      "full: with the change's colours the untouched parts step back", text)

bridge.messages.removeAll()
text = js("""
window.node('l:f:src/ui/old-panel.js').emit('tap');
await new Promise(r => setTimeout(r, 400));
return document.getElementById('arch-details').innerText;
""")
check(bridge.sent("prFileDiff").contains { $0["path"] as? String == "src/ui/old-panel.js" } && text.contains("old-panel.js"),
      "full: the diff of a removed file is reachable too", text)

// MARK: Overlays alongside the change (REQ-004), on both maps
for map in ["full", "focused"] {
    text = js("""
    document.querySelector('[data-arch-pr-map="\(map)"]').click();
    await window.settle(5);
    const select = document.getElementById('arch-overlay');
    const out = {};
    for (const overlay of ['complexity', 'size', 'none']) {
        select.value = overlay;
        select.dispatchEvent(new Event('change'));
        await new Promise(r => setTimeout(r, 900));
        out[overlay] = { engine: window.info('l:f:src/core/engine.js'), view: window.info('l:f:src/ui/view.js'), gone: window.info('l:f:src/legacy/old.js'),
            legend: document.getElementById('arch-legend').innerText };
    }
    return JSON.stringify(out);
    """)
    let overlays = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: Any]]) ?? [:]
    for overlay in ["complexity", "size", "none"] {
        let engine = overlays[overlay]?["engine"] as? [String: Any] ?? [:]
        let gone = overlays[overlay]?["gone"] as? [String: Any] ?? [:]
        check(engine["changed"] as? Int == 1 && (engine["halo"] as? Double ?? 0) > 0, "\(map)/\(overlay): a changed part is still marked", text)
        check((engine["label"] as? String ?? "").contains("+10 −2"), "\(map)/\(overlay): its lines still show in the label", text)
        check(gone["removed"] as? Int == 1 && gone["border"] as? String == "dashed", "\(map)/\(overlay): a removed file is still marked", text)
        check(engine["dimmed"] as? Int == 0, "\(map)/\(overlay): nothing is dimmed, the overlay stays readable", text)
        check((overlays[overlay]?["legend"] as? String ?? "").contains("Halo = changed"), "\(map)/\(overlay): the legend explains the marks", text)
    }
    let complexity = overlays["complexity"]?["engine"] as? [String: Any] ?? [:]
    let calm = overlays["complexity"]?["view"] as? [String: Any] ?? [:]
    check(!(complexity["fill"] as? String ?? "").isEmpty && complexity["fill"] as? String != calm["fill"] as? String,
          "\(map)/complexity: the overlay colours the parts (engine.js is more complex than view.js)", text)
    let sizeEngine = overlays["size"]?["engine"] as? [String: Any] ?? [:]
    let sizeView = overlays["size"]?["view"] as? [String: Any] ?? [:]
    check((sizeView["w"] as? Double ?? 0) > (sizeEngine["w"] as? Double ?? 0), "\(map)/size: boxes grow with their lines (view.js is longer than engine.js)", text)
}
// back to the change's own colours
_ = js("""
const select = document.getElementById('arch-overlay'); select.value = 'pr'; select.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 600)); return 'ok';
""")


// MARK: Tapping a file on the full map (REQ-003)
bridge.messages.removeAll()
_ = js("""
window.showArchitecture(window.make());
document.querySelector('[data-arch-pr-map="full"]').click();
await window.settle(8);
window.node('l:f:src/core/util.js').emit('tap');
await new Promise(r => setTimeout(r, 300));
return 'ok';
""")
check(!bridge.sent("openFile").contains { $0["path"] as? String == "src/core/util.js" },
      "full: selecting an untouched file reads it here, it does not leave the map", "\(bridge.messages)")
_ = js("""
window.node('l:f:src/core/engine.js').emit('tap');
await new Promise(r => setTimeout(r, 300));
return 'ok';
""")
check(bridge.sent("openFile").contains { $0["path"] as? String == "src/core/engine.js" && $0["fromPR"] as? Bool == true },
      "full: selecting a file of the change opens it on its change", "\(bridge.messages)")

// MARK: The risk colour belongs to the change's own colours (REQ-004)
text = js("""
window.showArchitecture(window.make({ analysis: true }));
await window.settle(5);
const select = document.getElementById('arch-overlay');
const out = {};
for (const overlay of ['pr', 'complexity']) {
    select.value = overlay; select.dispatchEvent(new Event('change'));
    await new Promise(r => setTimeout(r, 900));
    out[overlay] = window.info('l:c:core');
}
select.value = 'pr'; select.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 600));
return JSON.stringify(out);
""")
facts = parse(text)
check((facts["pr"]?["label"] as? String ?? "").contains("risk"), "with the change's colours a component shows the risk the analysis gave it", text)
check(!(facts["complexity"]?["label"] as? String ?? "").contains("risk") && facts["complexity"]?["fill"] as? String != facts["pr"]?["fill"] as? String,
      "with another overlay the component is coloured by that overlay, not by the risk", text)

// MARK: Hopping between the project X-Ray and the change
text = js("""
window.showArchitecture(window.make());
document.querySelector('[data-arch-pr-map="full"]').click();
await window.settle(8);
const inChange = window.node('l:f:src/core/engine.js').length;
window.showArchitecture(window.make({ project: true, noChange: true }));
await window.settle(2);
const inProject = window.node('l:f:src/core/engine.js').length;
const other = window.make({ project: true, noChange: true }); other.root = '/tmp/other';
window.showArchitecture(other);
await window.settle(2);
window.showArchitecture(window.make());
await window.settle(8);
const back = window.node('l:f:src/core/engine.js').length;
const selected = document.getElementById('arch-details').innerText;
return JSON.stringify({ inChange, inProject, back, map: document.querySelector('#arch-pr-map .on').dataset.archPrMap, selected });
""")
let hop = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
check(hop["inChange"] as? Int == 1, "hop: the full map of the change shows its changed file", text)
check(hop["inProject"] as? Int == 0, "hop: what the change opened is not open in the project's own view", text)
check(hop["back"] as? Int == 1 && hop["map"] as? String == "full", "hop: back from another project the full map opens the changed parts again", text)

// What was switched on in the project X-Ray (only flagged) does not hide parts of a change, which has no such control.
text = js("""
window.showArchitecture(window.make({ project: true, noChange: true }));
await window.settle(2);
const select = document.getElementById('arch-overlay');
select.value = 'complexity'; select.dispatchEvent(new Event('change'));
const flagged = document.getElementById('arch-flagged');
flagged.checked = true; flagged.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 600));
window.showArchitecture(window.make());
document.querySelector('[data-arch-pr-map="focused"]').click();
await window.settle(5);
const select2 = document.getElementById('arch-overlay');
select2.value = 'complexity'; select2.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 900));
const shown = window.cyNow().nodes().map(n => n.id());
flagged.checked = false; flagged.dispatchEvent(new Event('change'));
return JSON.stringify({ shown });
""")
let flaggedHop = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
let flaggedShown = flaggedHop["shown"] as? [String] ?? []
check(flaggedShown.contains("l:f:src/ui/view.js") && flaggedShown.contains("l:f:src/core/fresh.js"),
      "\"Only flagged\" from the project X-Ray does not hide the changed files of a change", text)

// MARK: The source list
bridge.messages.removeAll()
_ = js("""
const select = document.getElementById('arch-pr-source');
select.value = 'at:' + 'a'.repeat(40); select.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 200));
select.value = 'local'; select.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 200));
return 'ok';
""")
check(bridge.sent("showPR").contains { ($0["source"] as? String)?.hasPrefix("at:") == true } && !bridge.sent("openPRXRay").contains { ($0["source"] as? String)?.hasPrefix("at:") == true },
      "choosing a comparison with an earlier commit shows it without starting an AI analysis", "\(bridge.messages)")
check(bridge.sent("openPRXRay").contains { $0["source"] as? String == "local" }, "other sources behave as before", "\(bridge.messages)")

// MARK: The date picker (REQ-001)
bridge.messages.removeAll()
text = js("""
window.showArchitecture(window.make());
await window.settle(5);
const day = document.getElementById('arch-history-day');
const hidden0 = document.getElementById('arch-history').hidden;
document.getElementById('arch-pr-date').click();
await new Promise(r => setTimeout(r, 200));
const pad = n => String(n).padStart(2, '0'); const now = new Date();
const today = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate());
return JSON.stringify({ hidden0, open: !document.getElementById('arch-history').hidden, value: day.value, today, max: day.max,
    note: document.getElementById('arch-history-list').innerText });
""")
var picker = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
check(picker["hidden0"] as? Bool == true && picker["open"] as? Bool == true, "the date picker opens from the toolbar", text)
check(picker["value"] as? String == picker["today"] as? String && picker["max"] as? String == picker["today"] as? String, "it starts on today and offers no later day", text)
check(bridge.sent("historyCommits").contains { $0["day"] as? String == picker["today"] as? String }, "opening it asks for the commits of that day", "\(bridge.messages)")
check((picker["note"] as? String ?? "").contains("Reading the history"), "until the answer comes it says it is reading", text)

func historyText(_ history: String) -> String {
    js("""
    const p = window.make({ history: \(history) });
    window.showArchitecture(p);
    await new Promise(r => setTimeout(r, 300));
    return document.getElementById('arch-history-list').innerText;
    """)
}
let today = picker["today"] as? String ?? ""
let empty = historyText("{ day: '\(today)', state: 'ready', commits: [] }")
check(empty.contains("No commits were made on this day."), "a day without commits says so (REQ-001)", empty)
check(historyText("{ day: '\(today)', state: 'unavailable', commits: [] }").contains("could not be read"), "an unreadable history says so")
check(historyText("{ day: '1999-01-01', state: 'ready', commits: [] }").contains("Reading the history"), "an answer for another day than the chosen one is not shown")
let listed = historyText("""
{ day: '\(today)', state: 'ready', commits: [
  { sha: '\(String(repeating: "b", count: 40))', short: 'bbbbbbbb', subject: 'Add the engine', author: 'Ada', time: \(Date().timeIntervalSince1970 - 3600) },
  { sha: '\(String(repeating: "c", count: 40))', short: 'cccccccc', subject: 'Fix the panel', author: 'Grace', time: \(Date().timeIntervalSince1970 - 7200) }] }
""")
check(listed.contains("Add the engine") && listed.contains("bbbbbbbb") && listed.contains("Ada") && listed.contains("Fix the panel"),
      "the commits of the day are listed with their name, subject and author", listed)
bridge.messages.removeAll()
text = js("""
document.querySelectorAll('.arch-history-row')[1].click();
await new Promise(r => setTimeout(r, 200));
return String(document.getElementById('arch-history').hidden) + '|' + document.querySelectorAll('.arch-history-row').length;
""")
check(bridge.sent("compareWithCommit").map { $0["sha"] as? String } == [String(repeating: "c", count: 40)], "choosing a commit asks to compare with exactly that commit", "\(bridge.messages)")
check(text.hasPrefix("true|"), "the picker closes once a commit is chosen", text)

bridge.messages.removeAll()
_ = js("""
document.getElementById('arch-pr-date').click();
const day = document.getElementById('arch-history-day');
day.value = '2026-11-05'; day.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 200));
return 'ok';
""")
check(bridge.sent("historyCommits").last?["day"] as? String == "2026-11-05", "changing the date asks for the commits of the new day", "\(bridge.messages)")
text = js("""
document.getElementById('arch-history').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
await new Promise(r => setTimeout(r, 100));
return String(document.getElementById('arch-history').hidden);
""")
check(text == "true", "Escape closes the picker", text)

// MARK: The project X-Ray is unchanged
text = js("""
window.showArchitecture(window.make({ project: true, noChange: true }));
await window.settle(2);
return JSON.stringify({ map: document.getElementById('arch-pr-map').hidden, date: document.getElementById('arch-pr-date').hidden,
    history: document.getElementById('arch-history').hidden, views: document.querySelector('[data-arch-view]').parentElement.hidden,
    ai: !!document.querySelector('#arch-overlay optgroup[data-ai]') });
""")
let project = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
check(project["map"] as? Bool == true && project["date"] as? Bool == true && project["history"] as? Bool == true, "the project X-Ray has neither the map switch nor the date picker", text)
check(project["views"] as? Bool == false && project["ai"] as? Bool == true, "the project X-Ray keeps its view tabs and AI filters", text)

print(failures == 0 ? "All X-Ray comparison web checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
