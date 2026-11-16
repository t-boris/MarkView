import AppKit
import WebKit

// FU-25: the cached and exported Insight page runs under a policy with no 'unsafe-inline' for scripts. The page the shipping
// InsightHTMLTemplate writes into a real InsightCache (nodes/<id>.html next to _assets/ with the real bundled libraries) is loaded
// the way a person opens an exported page, in real WebKit with a hidden window. What is checked:
//   - the page still renders: its bootstrap runs under the hash in the policy, Mermaid draws the diagram and Chart.js the chart
//     from the libraries it loads from 'self', and a click on an image opens the lightbox;
//   - a script, an event handler and a javascript: link that the assistant's section text (or a node label) carries do not run,
//     and WebKit reports the blocked script as a policy violation;
//   - the control: the same page with the old policy (inline scripts allowed) does run all of them, so "did not run" above is
//     a result of the policy and not of a page that cannot run anything.
// Run through tools/tests/insight-page-web-tests.sh.
setvbuf(stdout, nil, _IONBF, 0)
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

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done = true }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// The page's own text, exactly as the app writes it: the shipping template into a real cache.
let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("insight-page-web-tests-\(UUID().uuidString)", isDirectory: true)
let workspace = sandbox.appendingPathComponent("notes", isDirectory: true)
try! fm.createDirectory(at: workspace, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }
let cache = try! InsightCache(workspaceURL: workspace, sessionId: UUID(), pagePolicy: InsightHTMLTemplate.policyKey)

let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
func section(_ id: String, _ type: SectionType, _ title: String) -> InsightSection {
    InsightSection(id: id, type: type, title: title, scopeHint: nil, metadata: [:], deepDiveTopics: nil)
}
let skeleton = InsightSkeleton(title: "Notes <script>window.__title = 1</script>", suggestedTheme: nil, sections: [
    section("s1", .prose, "Hostile <script>window.__sectionTitle = 1</script>"),
    section("s2", .mermaidDiagram, "Diagram"),
    section("s3", .chartJsChart, "Chart"),
])
let states = [
    "s1": SectionState(buffer: """
        <p id="plain">plain text</p>
        <script>window.__injected = 1;</script>
        <img id="broken" src="missing.png" onerror="window.__handler = 1">
        <svg onload="window.__svg = 1" width="1" height="1"></svg>
        <a id="jslink" href="javascript:window.__link = 1">link</a>
        <img id="pic" src="\(pixel)" width="40" height="40">
        """, status: .ready),
    "s2": SectionState(buffer: "<pre><code class=\"language-mermaid\">graph TD\n  A[Start] --> B[End]</code></pre>", status: .ready),
    "s3": SectionState(buffer: "<canvas id=\"chart\" data-chart='{\"type\":\"bar\",\"data\":{\"labels\":[\"a\",\"b\"],\"datasets\":[{\"label\":\"n\",\"data\":[1,2]}]},\"options\":{\"animation\":false}}'></canvas>", status: .ready),
]
let crumbs: [(nodeId: String, title: String)] = [("ROOT", "Notes <script>window.__crumb = 1</script>")]
let page = InsightHTMLTemplate.html(skeleton: skeleton, sectionStates: states, breadcrumbs: crumbs, cache: cache)
let nodeId = UUID()
try! cache.writeNode(nodeId: nodeId, html: page)
// The control page: the same text with the policy of 6.27.x, which let every inline script run.
let olderPolicy = InsightHTMLTemplate.policy.replacingOccurrences(of: "script-src 'self' \(InsightHTMLTemplate.bootstrapHash)", with: "script-src 'self' 'unsafe-inline'")
let controlId = UUID()
try! cache.writeNode(nodeId: controlId, html: page.replacingOccurrences(of: InsightHTMLTemplate.policy, with: olderPolicy))
check(olderPolicy != InsightHTMLTemplate.policy, "the control page carries the older policy")

// Every policy violation the page reports, kept for the checks.
let recordViolations = WKUserScript(source: """
    window.__violations = [];
    document.addEventListener('securitypolicyviolation', function (e) { window.__violations.push(e.violatedDirective + ' ' + (e.blockedURI || '')); });
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true)

var keep: [AnyObject] = []   // windows and delegates live as long as the run
func open(_ id: UUID) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.userContentController.addUserScript(recordViolations)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1400), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.contentView = web
    let loaded = Loaded()
    web.navigationDelegate = loaded
    keep += [loaded, window]
    let url = cache.rootDirectory.appendingPathComponent("nodes/\(id.uuidString).html")
    web.loadFileURL(url, allowingReadAccessTo: cache.rootDirectory)
    spin(60) { loaded.done }
    return web
}

func js(_ web: WKWebView, _ body: String, timeout: TimeInterval = 60) -> String {
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

let probe = """
    const w = window;
    const seen = k => String(typeof w[k] === 'undefined' ? 'no' : w[k]);
    return JSON.stringify({
        injected: seen('__injected'), handler: seen('__handler'), svg: seen('__svg'), link: seen('__link'),
        title: seen('__title'), sectionTitle: seen('__sectionTitle'), crumb: seen('__crumb'),
        violations: w.__violations || [],
        mermaid: typeof w.mermaid, chart: typeof w.Chart
    });
    """
func state(_ web: WKWebView) -> [String: Any] {
    let text = js(web, probe)
    return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? ["error": text]
}

// 1. The page under the policy in force.
let web = open(nodeId)
spin(1)
let before = state(web)
check(before["mermaid"] as? String == "object" && before["chart"] as? String == "function",
      "the bundled libraries load from 'self' (Mermaid and Chart.js are defined)", "\(before)")

// The bootstrap runs: Mermaid draws the diagram, Chart.js the chart.
let drawn = js(web, """
    for (let i = 0; i < 200 && !document.querySelector('.mermaid svg'); i++) await new Promise(r => setTimeout(r, 100));
    const svg = document.querySelector('.mermaid svg');
    const chart = window.Chart && window.Chart.getChart(document.getElementById('chart'));
    return JSON.stringify({
        diagram: !!svg, labels: svg ? Array.from(svg.querySelectorAll('.nodeLabel, text')).map(e => e.textContent.trim()).filter(Boolean) : [],
        chart: !!chart, bars: chart ? chart.data.datasets[0].data.length : 0
    });
    """)
let drawnState = ((try? JSONSerialization.jsonObject(with: Data(drawn.utf8))) as? [String: Any]) ?? [:]
let labels = (drawnState["labels"] as? [String]) ?? []
check(drawnState["diagram"] as? Bool == true && labels.contains("Start") && labels.contains("End"), "the page draws the Mermaid diagram with its labels", drawn)
check(drawnState["chart"] as? Bool == true && drawnState["bars"] as? Int == 2, "the page draws the Chart.js chart from the section's data", drawn)

// The lightbox opens on a click on an image of a section.
let lightbox = js(web, """
    document.getElementById('pic').click();
    const lb = document.getElementById('lb');
    return JSON.stringify({ exists: !!lb, on: !!lb && lb.classList.contains('on'), content: !!lb && lb.querySelectorAll('.lb-content img').length });
    """)
check(lightbox.contains("\"on\":true") && lightbox.contains("\"content\":1"), "a click on an image opens the lightbox (the bootstrap's listeners work)", lightbox)

// Nothing the assistant's text or a label carries has run. Handlers fire asynchronously: wait for the broken image to report.
spin(1.5)
let after = state(web)
for (name, key) in [("an inline script in a section", "injected"), ("an onerror handler on an image", "handler"), ("an onload handler on an svg", "svg"),
                    ("a script in the page title", "title"), ("a script in a section title", "sectionTitle"), ("a script in a breadcrumb", "crumb")] {
    check(after[key] as? String == "no", "\(name) does not run", "\(after)")
}
let violations = (after["violations"] as? [String]) ?? []
check(violations.contains { $0.hasPrefix("script-src") && $0.hasSuffix("inline") }, "WebKit reports the injected inline script as a policy violation", "\(violations)")
check(violations.contains { $0.hasPrefix("script-src-attr") || $0.hasPrefix("script-src") }, "the inline handlers are blocked too", "\(violations)")
let clicked = js(web, """
    document.getElementById('jslink').click();
    await new Promise(r => setTimeout(r, 300));
    return String(typeof window.__link);
    """)
check(clicked == "undefined", "a javascript: link does not run when it is clicked", clicked)

// 2. The control: the older policy lets every one of them run.
let control = open(controlId)
spin(1.5)
let older = state(control)
_ = js(control, "document.getElementById('jslink').click(); await new Promise(r => setTimeout(r, 300)); return ''")
let olderAfterClick = state(control)
check(older["injected"] as? String == "1" && older["handler"] as? String == "1" && older["svg"] as? String == "1",
      "control: under the older policy the inline script, the onerror handler and the svg onload do run", "\(older)")
check(olderAfterClick["link"] as? String == "1", "control: under the older policy a javascript: link runs", "\(olderAfterClick)")
check((older["violations"] as? [String])?.isEmpty == true, "control: the older policy reports no violation", "\(older)")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
