import AppKit
import WebKit

// Checks the data viewers and JSON/YAML editing (MarkView/Resources/Editor/vendor/js/markview-data.js,
// markview-structured.js) in a real WKWebView with the shipping editor page, the bundled libraries
// and a `markview-data:` handler like the app's. Compiled by tools/tests/data-viewers-tests.sh;
// needs a GUI session. Fixtures: tools/tests/fixtures/data.

let editor = CommandLine.arguments[1]
let fixtures = CommandLine.arguments[2]
var failures = 0
func check(_ condition: Bool, _ message: String, _ detail: String = "") {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) \(detail.prefix(400))") }
}

final class DataFiles: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: task.request.url!.path))) ?? Data()
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
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
config.setURLSchemeHandler(DataFiles(), forURLScheme: "markview-data")
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

/// Open a fixture in the data viewer and wait until its grid or log is shown.
func open(_ name: String, _ kind: String) -> String {
    let src = "markview-data://" + fixtures + "/" + name
    return js("""
    window.setDataContent({ src: \(String(reflecting: src)), kind: '\(kind)', name: '\(name)', reload: false });
    const c = document.getElementById('data-container');
    for (let i = 0; i < 200; i++) {
      if (c.querySelector('.dv-grid tbody tr[data-row], .dv-log .ln[data-pos], .dv-msg.error:not(:empty)')) break;
      await new Promise(r => setTimeout(r, 50));
    }
    return c.innerText;
    """)
}

spin(15) { loaded.done }
check(js("return typeof window.setDataContent") == "function", "the data viewers are on the page")

var text = open("plants.csv", "table")
check(text.contains("40 rows") && text.contains("height_cm") && text.contains("Basil"), "CSV: rows and header", text)
text = js("""
const c = document.getElementById('data-container');
c.querySelector('.dv-sqlbtn').click();
c.querySelector('.dv-sql textarea').value = 'SELECT plant, COUNT(*) AS n FROM data GROUP BY plant ORDER BY plant';
c.querySelector('.dv-run').click();
await new Promise(r => setTimeout(r, 300));
return c.querySelector('.dv-grid').innerText;
""")
check(text.contains("Basil\t10") && text.contains("Tomato\t10"), "CSV: SQL with GROUP BY", text)
_ = open("plants.csv", "table")
text = js("""
const c = document.getElementById('data-container');
const input = c.querySelectorAll('thead input')[2]; input.value = '>45'; input.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 200));
c.querySelectorAll('thead tr:first-child th[data-col]')[2].click(); await new Promise(r => setTimeout(r, 200));
c.querySelectorAll('thead tr:first-child th[data-col]')[2].click(); await new Promise(r => setTimeout(r, 200));
return c.querySelector('.dv-count').textContent + '|' + c.querySelector('tbody tr[data-row] td:nth-child(4)').textContent;
""")
check(text.hasPrefix("5 rows") && text.hasSuffix("|50"), "CSV: numeric filter >45 and descending sort", text)
text = js("""
const c = document.getElementById('data-container');
c.querySelectorAll('thead tr:first-child th[data-col]')[2].click();
await new Promise(r => setTimeout(r, 200));
c.querySelector('.dv-stats').click();
return c.querySelector('.dv-side').innerText;
""")
check(text.contains("Distinct") && text.contains("Max"), "CSV: column statistics", text)

text = open("plants.tsv", "table")
check(text.contains("5 rows") && text.contains("Mint"), "TSV", text)
text = open("events.jsonl", "table")
check(text.contains("meta.h") && text.contains("6 rows"), "JSON Lines: nested objects become dotted columns", text)
text = open("plants.parquet", "parquet")
check(text.contains("40 rows") && text.contains("Rosemary"), "Parquet (snappy)", text)
text = open("plants-zstd.parquet", "parquet")
check(text.contains("40 rows") && text.contains("Rosemary"), "Parquet (zstd)", text)
text = open("garden.sqlite", "sqlite")
check(text.contains("40 rows") && text.contains("height_cm"), "SQLite: first table", text)
text = js("""
const c = document.getElementById('data-container');
const s = c.querySelector('.dv-table'); s.value = 'tall'; s.dispatchEvent(new Event('change'));
await new Promise(r => setTimeout(r, 200));
return c.querySelector('.dv-count').textContent;
""")
check(text.hasPrefix("10 rows"), "SQLite: a view from the table list", text)
text = open("garden.xlsx", "table")
check(text.contains("2026-03-01") && text.contains("Basil") && text.contains("2 sheets"), "Excel: first sheet, dates read", text)
text = open("session.har", "table")
check(text.contains("GET") && text.contains("https://garden.example/api/plants") && text.contains("200"), "HAR: one row per request", text)

text = open("plants.feather", "table")
check(text.contains("3 rows") && text.contains("Kale") && text.contains("71.2"), "Arrow IPC / Feather", text)
text = open("plants.avro", "table")
check(text.contains("3 rows") && text.contains("Mint") && text.contains("2026-03-02") && text.contains("VEG") && text.contains("-3"),
      "Avro (null codec): records, enum, union, negative long, date", text)
text = open("plants-deflate.avro", "table")
check(text.contains("3 rows") && text.contains("spreads") && text.contains("[\"shade\",\"wet\"]"), "Avro (deflate codec): arrays and unions", text)
text = open("readings-snappy.avro", "table")
check(text.contains("2 rows") && text.contains("labels.bed") && text.contains("north") && text.contains("12.34") && text.contains("-2.5")
      && text.contains("2026-10-05T00:01:00.000Z"), "Avro (snappy codec): map, decimal, timestamp", text)
text = open("harvest.ods", "table")
check(text.contains("3 rows") && text.contains("Tomato") && text.contains("2026-08-01") && text.contains("Pepper"),
      "OpenDocument spreadsheet: repeated rows expanded, a million empty rows ignored", text)

text = open("app.log", "log")
check(text.contains("Error3") && text.contains("Warn1"), "Log: levels counted (stack trace and JSON line are errors)", text)
text = js("""
const c = document.getElementById('data-container');
const q = c.querySelector('.dv-q'); q.value = 'water'; q.dispatchEvent(new Event('input'));
await new Promise(r => setTimeout(r, 400));
c.querySelector('.dv-only').click();
await new Promise(r => setTimeout(r, 100));
return c.querySelector('.dv-mcount').textContent + '|' + c.querySelector('.dv-log').innerText;
""")
check(text.contains("failed to water") && !text.contains("slow disk"), "Log: search with only matching lines", text)

// JSON / YAML editing in the tree
let edit = """
const nodes = () => [...DOM.rendered.querySelectorAll('.struct-node[data-path]')];
const at = (p) => nodes().find(n => n.dataset.path === JSON.stringify(p));
at(['version']).querySelector('.struct-value').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
let input = DOM.rendered.querySelector('.struct-inline-input'); input.value = '2';
input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
await new Promise(r => setTimeout(r, 400));
at(['name']).querySelector('.struct-key').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
input = DOM.rendered.querySelector('.struct-inline-input'); input.value = 'title';
input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
await new Promise(r => setTimeout(r, 400));
at(['plants', 0]).querySelector('.struct-act[data-act=delete]').click();
await new Promise(r => setTimeout(r, 400));
return DOM.editor.value;
"""
func structured(_ name: String, _ type: String) {
    let content = try! String(contentsOfFile: fixtures + "/" + name, encoding: .utf8)
    let literal = String(data: try! JSONSerialization.data(withJSONObject: [content]), encoding: .utf8)!
    _ = js("window.setStructuredContent(\(literal)[0], '\(type)'); return 'ok';")
}
structured("config.json", "json")
text = js(edit)
check(text == "{\n    \"title\": \"garden\",\n    \"version\": 2,\n    \"plants\": [\n        \"mint\"\n    ]\n}\n",
      "JSON: edit a value, rename a key, delete an item; indentation kept", text)
structured("config.yaml", "yaml")
text = js(edit)
check(text.hasPrefix("# Garden config\ntitle: garden") && text.contains("# the project") && text.contains("version: 2") && !text.contains("basil"),
      "YAML: the same edits keep the comments", text)
structured("config.json", "json")
text = js("""
toggleStructMode();
const ok = document.getElementById('struct-source-status').textContent;
DOM.editor.value = '{ "broken": '; DOM.editor.dispatchEvent(new Event('input'));
await new Promise(r => setTimeout(r, 400));
return ok + '|' + document.getElementById('struct-source-status').className;
""")
check(text == "Valid JSON|struct-source-status bad", "JSON: the source view checks the syntax as you type", text)

// All text-file viewers use the same Explain request and line-aligned notes.
bridge.messages.removeAll()
structured("config.yaml", "yaml")
_ = js("document.querySelector('.doc-explain-btn').click(); return 'ok';")
spin(0.2)
var request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
check(request?["action"] as? String == "notesView" && request?["show"] as? Bool == true && request?["explain"] as? Bool == true,
      "YAML: Explain requests its own source notes and starts AI")
text = js("""
window.setCodeContent('server:\\n  port: 8080\\ndatabase:\\n  pool: 5', 'yaml', 'config.yaml', 'Viewer');
for (let i = 0; i < 100 && !document.querySelector('.code-main .cm-content'); i++) await new Promise(r => setTimeout(r, 30));
window.setCodeNotes({ explanation: { summary: 'Service settings', sections: [
  { startLine: 1, endLine: 2, title: 'HTTP listener', explanation: 'Sets the server port.', importance: 'high' },
  { startLine: 3, endLine: 4, title: 'Database pool', explanation: 'Sets the connection pool size.', importance: 'normal' }
] }, filters: [] });
await new Promise(r => setTimeout(r, 150));
return [document.getElementById('status-mode').textContent, document.querySelector('.code-document-btn').textContent,
        document.querySelector('.code-edit-btn').hidden, document.querySelector('.code-notes-track').textContent,
        document.querySelectorAll('.code-main .cm-line').length].join('|');
""")
check(text.contains("YAML|← Viewer|true") && text.contains("HTTP listener") && text.contains("Database pool") && text.hasSuffix("|4"),
      "YAML: highlighted source, line-aligned section notes and return to viewer", text)
text = js("""
document.querySelector('.code-notes-close').click();
const hiddenBefore = document.querySelector('.code-notes').hidden;
window.explainCurrentFile();
window.setCodeContent('server: 8080', 'yaml', 'reopened.yaml', 'Viewer');
window.setCodeNotes({ explanation: { summary: 'Server settings', sections: [
  { startLine: 1, endLine: 1, title: 'Server', explanation: 'Port setting.', importance: 'normal' }
] }, filters: [] });
return hiddenBefore + '|' + document.querySelector('.code-notes').hidden;
""")
check(text == "true|false", "Explain from source/data reopens notes after they were hidden", text)
bridge.messages.removeAll()
_ = js("document.querySelector('.code-document-btn').click(); return 'ok';")
spin(0.1)
request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
check(request?["action"] as? String == "notesView" && request?["show"] as? Bool == false, "notes return to the dedicated viewer")
text = js("""
window.setCodeContent('# just text\\nkey=value', '', 'anything.mystery');
await new Promise(r => setTimeout(r, 150));
return [document.getElementById('status-mode').textContent, document.querySelector('.code-main .cm-content').textContent,
        document.querySelector('.code-edit-btn').hidden, document.querySelector('.code-document-btn').hidden].join('|');
""")
check(text.hasPrefix("TEXT|# just textkey=value|false|true"), "unknown files are plain editable text with Explain", text)
bridge.messages.removeAll()
_ = js("document.querySelector('.code-main .code-explain-btn').click(); return 'ok';")
spin(0.1)
request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
check(request?["action"] as? String == "explain", "plain text Explain reaches the shared AI action")
structured("config.json", "json")
_ = js("toggleStructMode(); document.querySelector('#editor-pane .code-explain-btn').click(); return 'ok';")
spin(0.1)
request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
check(request?["action"] as? String == "notesView" && request?["explain"] as? Bool == true, "structured source mode also exposes Explain")
_ = open("plants.csv", "table")
bridge.messages.removeAll()
text = js("const b = document.querySelector('.dv-explain'); if (b) b.click(); return String(!!b);")
spin(0.1)
request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
check(text == "true" && request?["explain"] as? Bool == true, "CSV: Explain opens the original textual source")
_ = open("app.log", "log")
check(js("return String(!!document.querySelector('.dv-explain'))") == "true", "logs expose Explain")
_ = open("plants.parquet", "parquet")
check(js("return String(!!document.querySelector('.dv-explain'))") == "false", "binary data is not offered as textual source")

print(failures == 0 ? "All data viewer checks passed." : "\(failures) data viewer check(s) failed.")
exit(failures == 0 ? 0 : 1)
