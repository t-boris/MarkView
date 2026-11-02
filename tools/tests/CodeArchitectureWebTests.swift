import AppKit
import WebKit

// Exercise the shipped X-Ray DOM, Cytoscape layout and Mermaid in WKWebView.
let editor = CommandLine.arguments[1]
let payload = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(600)))")
}
final class Bridge: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
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

/// Run `body` (an async function body) in the page and return its string result.
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


spin(20) { loaded.done }
check(loaded.done, "shipping editor loaded")
var text = js("""
window.testPayload = \(payload);
window.showArchitecture(window.testPayload);
for (let i = 0; i < 200; i++) {
    if (document.getElementById('arch-graph').querySelector('canvas')) break;
    await new Promise(r => setTimeout(r, 50));
}
return document.querySelector('[data-arch-view].on').dataset.archView + '|' + document.getElementById('arch-details').innerText;
""")
check(text.hasPrefix("code|") && text.lowercased().contains("trace a scenario"), "code folders open the Code map with scenario controls", text)
text = js("""
await new Promise(r => setTimeout(r, 1000));
const cy = document.getElementById('arch-graph')._cyreg.cy;
return JSON.stringify({opaque:cy.nodes().every(n => Number(n.style('opacity')) === 1), nodes:cy.nodes().length, zoom:cy.zoom(), width:cy.width(), height:cy.height(), bb:cy.nodes().renderedBoundingBox()});
""")
print("viewport: \(text)")
if let snapshotPath = ProcessInfo.processInfo.environment["CODE_ARCHITECTURE_SNAPSHOT"] {
    let canvasImage = js("return document.getElementById('arch-graph')._cyreg.cy.png({full:false, scale:1});")
    if let comma = canvasImage.firstIndex(of: ","), let png = Data(base64Encoded: String(canvasImage[canvasImage.index(after: comma)...])) {
        try? png.write(to: URL(fileURLWithPath: snapshotPath + ".graph.png"))
    }
    var finished = false
    web.takeSnapshot(with: nil) { image, _ in
        if let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: snapshotPath))
        }
        finished = true
    }
    spin(10) { finished }
}
check(!text.contains("null") && text.contains("\"opaque\":true") && text.contains("\"nodes\":4"), "layer canvas has finite rendered geometry", text)
text=js("""
const cy=document.getElementById('arch-graph')._cyreg.cy;
const order=['presentation','application','domain','data'].map(role=>cy.getElementById('code:layer:'+role).position('y'));
return String(order.every((y,i)=>i===0 || order[i-1]<y))+'|'+String(cy.edges().every(e=>Number(e.style('opacity'))===0));
""")
check(text == "true|true", "overview layers stay in semantic order with dependencies revealed on selection", text)
text = js("""
const view=window.testPayload.snapshot.views.find(v=>v.id==='code');
view.nodes.push({id:'code:layer:tests',parent:'code:',kind:'layer',name:'Tests',role:'tests'},
    {id:'code:f:tests/order_test.py',parent:'code:layer:tests',kind:'file',name:'order_test.py',path:'tests/order_test.py',language:'python',tags:['tests']});
window.showArchitecture(window.testPayload);
await new Promise(r=>setTimeout(r,500));
const cy=document.getElementById('arch-graph')._cyreg.cy;
return document.getElementById('arch-hide').value+'|'+String(cy.getElementById('code:layer:tests').length);
""")
check(text == "tests|0", "Code defaults to a product map without test noise", text)
text=js("""
const picker=document.getElementById('arch-hide');picker.value='';picker.dispatchEvent(new Event('change'));
await new Promise(r=>setTimeout(r,400));
const cy=document.getElementById('arch-graph')._cyreg.cy;
return String(cy.getElementById('code:layer:tests').length);
""")
check(text == "1", "Show all restores the tests layer", text)
text=js("""
const picker=document.getElementById('arch-hide');picker.value='tests,config,build,generated';picker.dispatchEvent(new Event('change'));
await new Promise(r=>setTimeout(r,400));
return String(document.getElementById('arch-graph')._cyreg.cy.getElementById('code:layer:tests').length);
""")
check(text == "0", "Hide tests works without a Logical view", text)
text=js("""
window.architectureFocus('code:f:tests/order_test.py','code');
return document.getElementById('arch-hide').value+'|'+String(document.getElementById('arch-graph')._cyreg.cy.getElementById('code:f:tests/order_test.py').length);
""")
check(text == "|1", "revealing a filtered code file makes its source visible", text)
text=js("""
document.querySelector('[data-arch-view="code"]').click();
const cy = document.getElementById('arch-graph')._cyreg.cy;
cy.getElementById('code:layer:presentation').emit('tap');
const edge=cy.edges().filter(e => e.data('evidence').includes('web/app.js:2')).first();
if (Number(edge.style('opacity')) !== 1) return 'selected dependency is hidden';
edge.emit('tap');
return document.getElementById('arch-details').innerText;
""")
check(text.contains("source-backed dependency") && text.contains("web/app.js:2"), "component dependency explains its source evidence", text)
text = js("""
document.querySelector('[data-arch-view="code"]').click();
document.getElementById('arch-code-trace').click();
return String(!document.getElementById('arch-details').hidden && document.activeElement.classList.contains('arch-code-question'));
""")
check(text == "true", "Sequence toolbar action opens the composer even when details are hidden", text)
text = js("""
document.getElementById('arch-analyze').click();
return document.getElementById('arch-analyze').textContent;
""")
check(text == "Analyze code" && bridge.messages.contains { ($0["payload"] as? [String: Any])?["action"] as? String == "analyzeCode" }, "Analyze code sends the dedicated source analysis action", text)
text = js("""
window.architectureFocus('code:f:service.py');
await new Promise(r => setTimeout(r, 200));
return document.getElementById('arch-details').innerText;
""")
check(text.contains("service.py") && text.contains("Zoom out of this"), "file drill-down and its controls render", text)
text = js("""
const buttons = [...document.getElementById('arch-details').querySelectorAll('button')];
buttons.find(b => b.textContent === 'Zoom out of this').click();
await new Promise(r => setTimeout(r, 300));
window.architectureFocus('code:s:symbol:method');
await new Promise(r => setTimeout(r, 100));
return document.getElementById('arch-details').innerText;
""")
check(text.contains("place_order"), "drill-down reaches a symbol", text)
text = js("""
const buttons = [...document.getElementById('arch-details').querySelectorAll('button')];
const open = buttons.find(b => b.classList.contains('arch-path') && b.textContent === 'service.py:5');
if (open) open.click();
return buttons.map(b => b.textContent).join('|');
""")
check(bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "openFile" && p?["path"] as? String == "service.py" && p?["line"] as? Int == 5 }, "symbol opens the source at its line", text)
text = js("""
document.querySelector('[data-arch-view="code"]').click();
await new Promise(r => setTimeout(r, 200));
const input = document.querySelector('.arch-code-question');
input.value = 'How is an order saved?'; input.dispatchEvent(new Event('input'));
[...document.querySelectorAll('.arch-code-traces button')].find(b => b.textContent === 'Draw sequence').click();
return input.value;
""")
check(bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "traceCode" && p?["scope"] as? String == "code:" && p?["question"] as? String == "How is an order saved?" }, "scenario action contains the exact question and scope", text)
text = js("""
[...document.querySelectorAll('.arch-code-traces button')].find(b => b.textContent.includes('Place an order')).click();
for (let i = 0; i < 200; i++) {
    if (document.querySelector('#arch-code-sequence-svg svg')) break;
    await new Promise(r => setTimeout(r, 50));
}
return String(!!document.querySelector('#arch-code-sequence-svg svg')) + '|' + document.getElementById('arch-code-sequence').innerText;
""")
check(text.hasPrefix("true|") && text.contains("OrderService") && text.contains("1. place order"), "sequence renders with the bundled Mermaid library", text)
text = js("""
document.querySelector('#arch-code-sequence-sources button').click();
document.getElementById('arch-code-sequence-close').click();
return String(document.getElementById('arch-code-sequence').hidden);
""")
check(text == "true" && bridge.messages.contains { let p = $0["payload"] as? [String: Any]; return p?["action"] as? String == "openFile" && p?["path"] as? String == "api.py" && p?["line"] as? Int == 16 }, "sequence evidence opens the source and Back returns to layers", text)
text = js("""
window.testPayload.snapshot.views.find(v => v.id === 'modules').nodes.find(n => n.id === 'm:').signature = 'changed';
window.showArchitecture(window.testPayload);
return document.getElementById('arch-details').innerText;
""")
check(text.contains("Source changed") && text.contains("source changed"), "changed source marks both architecture and sequences stale", text)
text = js("""
document.querySelector('[data-arch-view="docs"]').click();
await new Promise(r => setTimeout(r, 100));
return String(document.getElementById('arch-code-sequence').hidden) + '|' + document.getElementById('arch-analyze').textContent;
""")
check(text == "true|Analyze", "switching views restores existing analysis action and hides sequence", text)
text = js("""
window.showArchitecture({root:'/docs-only', snapshot:{views:[{id:'modules',nodes:[{id:'m:',kind:'root',name:'Docs'}],edges:[]},{id:'code',nodes:[{id:'code:',kind:'root',name:'Code'}],edges:[]}],components:[],assignments:{},coverage:{},metrics:{},scannedAt:'2026-10-31T00:00:00Z'}, busy:false,filters:[],prSources:[]});
document.querySelector('[data-arch-view="code"]').click();
await new Promise(r => setTimeout(r, 200));
return document.getElementById('arch-empty').textContent + '|' + String(document.getElementById('arch-code-sequence').hidden);
""")
check(text.contains("No source code was found") && text.hasSuffix("|true"), "documents-only folders show an honest empty state", text)
text=js("""
window.testPayload.root='/tests-only';
const view=window.testPayload.snapshot.views.find(v=>v.id==='code');
view.nodes=[{id:'code:',kind:'root',name:'Tests'},{id:'code:layer:tests',parent:'code:',kind:'layer',name:'Tests',role:'tests'},
    {id:'code:f:test.py',parent:'code:layer:tests',kind:'file',name:'test.py',path:'test.py',language:'python',tags:['tests']}];
window.showArchitecture(window.testPayload);
document.querySelector('[data-arch-view="code"]').click();
await new Promise(r=>setTimeout(r,400));
return document.getElementById('arch-hide').value+'|'+String(document.getElementById('arch-graph')._cyreg.cy.getElementById('code:layer:tests').length);
""")
check(text == "|1", "a tests-only folder starts with its code visible", text)
text=js("""
const picker=document.getElementById('arch-hide');picker.value='tests';picker.dispatchEvent(new Event('change'));
return document.getElementById('arch-empty').textContent;
""")
check(text.contains("All source code is hidden"), "an explicit filter hiding every source file explains how to restore the map", text)

// BUG-037 / REQ-010: the Deployment details panel lists every project operation, grouped by kind.
let operationsSetup = """
const op = (id, label, kind, extra) => Object.assign({id, label, kind, command:'run ' + id, cwd:'.', origin:'discovered',
    confidence:'high', nodes:[], prerequisites:[], provenance:[], remoteTrigger:false, deleted:false}, extra || {});
window.testOperations = {
    // Five operations are "primary" in the payload (as the app still sends them); the panel must not depend on that.
    operations: [
        op('restart-web', 'Restart web', 'restart'), op('deploy-prod', 'Deploy prod', 'deploy', {environment:'prod', nodes:[{id:'d:api', name:'api'}]}),
        op('build-all', 'Build all', 'build'), op('clean-all', 'Clean', 'clean'), op('deploy-stage', 'Deploy stage', 'deploy', {environment:'stage', remoteTrigger:true}),
        op('install-deps', 'Install dependencies', 'install'), op('lint', 'Lint', 'other', {confidence:'low'}),
        op('build-docs', 'Build docs', 'build', {nodes:[{id:'gone', name:'db'}]}), op('seed', 'Seed data', 'seeding', {nodes:[{id:'x', name:'nothing'}]}),
        op('a-deploy', 'Add worker', 'deploy'),
    ],
    primary: ['deploy-prod', 'build-all', 'install-deps', 'clean-all', 'restart-web'],
    states: {'build-all': {state:'running'}}, unavailable: {}, hasFile: true, readOnly: false, sourcesChanged: false,
};
window.showArchitecture({root:'/ops', busy:false, filters:[], prSources:[], snapshot:{views:[
    {id:'modules', nodes:[{id:'m:', kind:'root', name:'Ops'}], edges:[]},
    {id:'deployment', nodes:[{id:'d:', kind:'root', name:'Deployment'}, {id:'d:api', parent:'d:', kind:'service', name:'api'},
        {id:'d:db', parent:'d:', kind:'database', name:'db'}, {id:'d:cache', parent:'d:', kind:'service', name:'cache'}], edges:[]}],
    components:[], assignments:{}, coverage:{}, metrics:{}, scannedAt:'2026-10-31T00:00:00Z'}});
window.setProjectOperations(window.testOperations);
document.querySelector('[data-arch-view="deployment"]').click();
await new Promise(r => setTimeout(r, 400));
const details = document.getElementById('arch-details');
// What the person can see: an element inside a [hidden] ancestor is not shown.
const shown = selector => [...details.querySelectorAll(selector)].filter(e => !e.closest('[hidden]'));
"""
text = js(operationsSetup + """
return JSON.stringify({
    headings: [...details.querySelectorAll('h5')].map(h => h.textContent),
    rows: shown('.arch-operation').map(r => r.querySelector('strong').textContent),
    controls: shown('button').map(b => b.textContent).filter(t => /show all|hide the list/i.test(t)).length,
    search: shown('input').length,
    badges: shown('.arch-badges span').map(s => s.textContent),
    buttons: shown('button').map(b => b.textContent),
});
""")
let noNode = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
let noNodeButtons = noNode["buttons"] as? [String] ?? []
let noNodeBadges = noNode["badges"] as? [String] ?? []
check(noNode["headings"] as? [String] == ["Project operations", "Deploy (3)", "Install (1)", "Build (2)", "Restart (1)", "Clean (1)", "Other (1)", "Seeding (1)"],
      "no node selected: one heading per kind in a fixed order, an unknown kind after the known ones", text)
check((noNode["rows"] as? [String])?.count == 10 && (noNode["rows"] as? [String]).map({ Set($0).count }) == 10,
      "no node selected: every project operation is listed once, not only the primary ones", text)
check((noNode["rows"] as? [String]).map({ Array($0.prefix(3)) }) == ["Add worker · deploy", "Deploy prod · prod · deploy", "Deploy stage · stage · deploy"],
      "operations inside a kind are ordered by label", text)
check((noNode["headings"] as? [String])?.contains("Main operations") == false && noNode["controls"] as? Int == 0 && noNode["search"] as? Int == 0,
      "the Main operations list, the Show all toggle and the search box are gone", text)
check(noNodeButtons.filter { $0 == "Open output" }.count == 1 && noNodeButtons.filter { $0 == "Run" }.count == 9
      && noNodeBadges.contains("running") && noNodeBadges.contains("Remote trigger") && noNodeBadges.contains("low"),
      "running, remote-trigger and low-confidence marks and the Run and Open output actions are kept", text)
text = js(operationsSetup + """
window.architectureFocus('d:api', 'deployment');
await new Promise(r => setTimeout(r, 300));
return JSON.stringify({
    headings: [...details.querySelectorAll('h5')].map(h => h.textContent),
    rows: shown('.arch-operation').map(r => r.className + '|' + r.querySelector('strong').textContent),
});
""")
let withNode = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
let nodeRows = withNode["rows"] as? [String] ?? []
check(withNode["headings"] as? [String] == ["Project operations", "Related to api", "Deploy (2)", "Install (1)", "Build (2)", "Restart (1)", "Clean (1)", "Other (1)", "Seeding (1)"],
      "node selected: related operations first, then the remaining ones by kind", text)
check(nodeRows.count == 10 && nodeRows.first == "arch-operation related|Deploy prod · prod · deploy"
      && nodeRows.dropFirst().allSatisfy { !$0.hasPrefix("arch-operation related") }, "node selected: only the related operation is highlighted and none is dropped or repeated", text)
text = js(operationsSetup + """
window.architectureFocus('d:db', 'deployment');
await new Promise(r => setTimeout(r, 300));
return JSON.stringify({headings: [...details.querySelectorAll('h5')].slice(0, 2).map(h => h.textContent), rows: shown('.arch-operation').length,
    related: [...details.querySelectorAll('.arch-operation.related strong')].map(r => r.textContent)});
""")
check(text.contains("\"headings\":[\"Project operations\",\"Related to db\"]") && text.contains("\"related\":[\"Build docs · build\"]") && text.contains("\"rows\":10"),
      "a relation whose node id is gone resolves by node name (DEC-027)", text)
text = js(operationsSetup + """
window.architectureFocus('d:cache', 'deployment');
await new Promise(r => setTimeout(r, 300));
return JSON.stringify({headings: [...details.querySelectorAll('h5')].slice(0, 2).map(h => h.textContent), rows: shown('.arch-operation').length,
    related: details.querySelectorAll('.arch-operation.related').length});
""")
check(text.contains("\"headings\":[\"Project operations\",\"Deploy (3)\"]") && text.contains("\"related\":0") && text.contains("\"rows\":10"),
      "node without related operations: every operation listed, none highlighted, a relation to an unknown node is ignored", text)
text = js(operationsSetup + """
window.setProjectOperations(Object.assign({}, window.testOperations, {operations: [], primary: []}));
await new Promise(r => setTimeout(r, 100));
return details.innerText;
""")
check(text.contains("No runnable procedure is known for this project.") && !text.contains("Deploy ("), "empty project: the empty-state text is unchanged and no group heading shows", text)
print("\(failures) WebKit failures")
exit(failures == 0 ? 0 : 1)
