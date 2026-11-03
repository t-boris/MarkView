import AppKit
import Foundation
import WebKit

// Checks for PrototypeRuntime (BUG-056) in a real WKWebView: what the screen writers are promised must hold.
// Arguments: <path of the error listener extracted from PrototypeStudioView.swift>

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mvruntime-tests-\(UUID().uuidString)")
let site = work.appendingPathComponent("site")
defer { try? fm.removeItem(at: work) }
func write(_ path: String, _ text: String) {
    let url = site.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

let plan = try! PrototypeAI.Plan(structured: [
    "title": "Help desk", "summary": "", "assumptions": [], "gaps": [], "roles": ["Agent — answers tickets", "Admin: everything"],
    "entities": [], "styles": [], "themes": [], "defaultTheme": "",
    "screens": [
        ["id": "tickets", "name": "Tickets", "route": "/tickets", "purpose": ""],
        ["id": "ticket", "name": "Ticket", "route": "/tickets/:id", "purpose": ""],
        ["id": "reports", "name": "Reports", "route": "/reports", "purpose": ""],
        ["id": "broken", "name": "Broken", "route": "/broken", "purpose": ""],
    ]] as [String: Any])
let roles = PrototypeRuntime.roleNames(["Agent — answers tickets", "Admin: everything"])
check(roles == ["Agent", "Admin"], "role names are cut from the plan's descriptions: \(roles)")
for file in PrototypeRuntime.files(plan: plan, key: "desk", roles: roles) { write(file.path, file.content) }
write("seed.js", """
DB.seed({ "Ticket": [
  { id: "t-1", title: "Printer jams", status: "Open", opened: DB.days(-2) },
  { id: "t-2", title: "VPN drops", status: "Closed", opened: DB.days(-9) },
  { id: "t-3", title: "New laptop", status: "Open", opened: DB.days(-1) }
] });
""")
write("screens/tickets.js", """
App.allow('Admin', ['ticket.delete']);
App.register({ id: 'tickets', route: '/tickets', title: 'Tickets', render: function (ctx) {
  return App.load(function () {
    var page = DB.list('ticket', { filter: { status: ctx.query.status || '' }, sort: 'title' });
    if (!page.total) return App.empty({ title: 'No tickets' });
    return App.h('table', { class: 'table' }, page.items.map(function (t) {
      return App.h('tr', null, App.h('td', null, App.h('a', { href: '#/tickets/' + t.id }, t.title)), App.h('td', null, t.status),
        App.can('ticket.delete') ? App.h('td', { class: 'can-delete' }, 'x') : null);
    }));
  });
} });
""")
write("screens/ticket.js", """
App.register({ id: 'ticket', route: '/tickets/:id', render: function (ctx) {
  var t = DB.get('Ticket', ctx.params.id);
  return App.h('div', { class: 'card' }, App.h('h1', null, t ? t.title : 'Missing'), App.h('select', { class: 'status', value: t && t.status },
    App.h('option', { value: 'Open' }, 'Open'), App.h('option', { value: 'Closed' }, 'Closed')));
} });
""")
write("screens/broken.js", """
App.register({ id: 'broken', route: '/broken', render: function () {
  return missingHelper();
} });
""")
// screens/reports.js is not written: its route must say it is still being built.

let listener = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)

final class Page: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var messages: [String] = []
    var finished = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { messages.append("\(m.body)") }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finished = true }
}

_ = NSApplication.shared
let page = Page()
let configuration = WKWebViewConfiguration()
configuration.setURLSchemeHandler(PrototypeSchemeHandler(root: site), forURLScheme: PrototypeSchemeHandler.scheme)
configuration.userContentController.add(page, name: "mvError")
configuration.userContentController.addUserScript(WKUserScript(source: listener, injectionTime: .atDocumentStart, forMainFrameOnly: true))
configuration.userContentController.addUserScript(WKUserScript(source: PrototypeAudit.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
view.navigationDelegate = page

func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func js(_ source: String, wait: TimeInterval = 0) -> Any? {
    var result: Any?, done = false
    view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { outcome in
        if case .success(let value) = outcome { result = value } else if case .failure(let error) = outcome { result = "ERROR \(error)" }
        done = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !done && Date() < deadline { spin(0.05) }
    if wait > 0 { spin(wait) }
    return result
}
func go(_ route: String) { _ = js("location.hash = '\(route)'"); spin(0.8) }
func text(_ selector: String = ".app-main") -> String { js("var e = document.querySelector('\(selector)'); return e ? e.innerText : ''") as? String ?? "" }

view.load(URLRequest(url: PrototypeSchemeHandler.address(of: "index.html")!))
let deadline = Date().addingTimeInterval(15)
while !page.finished && Date() < deadline { spin(0.05) }
spin(1.0)
check(page.finished, "the page loads")

check(js("return location.hash") as? String == "#/tickets", "an empty route goes to the first screen")
check(js("return [].map.call(document.querySelectorAll('.app-nav a'), a => a.textContent).join(',')") as? String == "Tickets,Reports,Broken",
      "the navigation lists the plan's screens without parameters")
check(js("return document.querySelector('.app-nav a.is-active').textContent") as? String == "Tickets", "the current screen is highlighted")
check(text().contains("New laptop") && text().contains("VPN drops"), "the screen renders the seeded records through App.load")
check(js("return document.querySelectorAll('.can-delete').length") as? Int == 0, "the first role lacks a permission granted to another")
check(js("return document.querySelector('.app-role select').value") as? String == "Agent", "the role switch shows the first role")

_ = js("App.setRole('Admin')"); spin(0.8)
check(js("return document.querySelectorAll('.can-delete').length") as? Int == 3, "switching the role re-renders with its permissions")

go("/tickets?status=Closed")
check(text().contains("VPN drops") && !text().contains("New laptop"), "query parameters reach ctx.query")

go("/tickets/t-2")
check(text().contains("VPN drops"), "route parameters reach ctx.params")
check(js("return document.querySelector('select.status').value") as? String == "Closed", "App.h sets a select's value after its options")
check(js("return document.querySelector('.app-nav a.is-active').textContent") as? String == "Tickets", "a detail route highlights its list")

go("/reports")
check(text().contains("still being built"), "a planned screen that is not written says so")

let before = page.messages.count
go("/broken")
check(text().contains("failed to render"), "a screen that throws shows a failure card")
let reported = page.messages.dropFirst(before).joined(separator: " | ")
print("     reported: \(reported)")
check(reported.contains("missingHelper") && reported.contains("screens/broken.js:2"), "the error reaches the Studio with the screen's file and line")

go("/nowhere")
check(js("return location.hash") as? String == "#/tickets", "an unknown route goes to the first screen")

let created = js("var r = DB.create('Ticket', { title: 'Fresh', status: 'Open' }); return r.id + '|' + DB.count('Ticket')") as? String ?? ""
check(created.hasSuffix("|4") && !created.hasPrefix("|"), "DB.create adds a record with an id: \(created)")
_ = js("location.reload()", wait: 1.5)
check(js("return DB.count('Ticket')") as? Int == 4, "changes survive a reload")
check(js("return localStorage.getItem('mv-proto-db:desk') !== null") as? Bool == true, "the data is stored under the prototype's key")
_ = js("DB.reset()")
check(js("return DB.count('Ticket')") as? Int == 3, "DB.reset restores the seed")
check(js("return DB.list('Ticket', { q: 'vpn' }).total") as? Int == 1, "text search")
check(js("return DB.list('Ticket', { sort: 'title', dir: 'desc', page: 2, pageSize: 2 }).items.map(t => t.title).join(',')") as? String == "New laptop",
      "sorting and pages")

_ = js("document.querySelector('.app-proto-empty').click()"); spin(0.8)
check(text().contains("No tickets"), "Force empty state empties the lists")
_ = js("document.querySelector('.app-proto-empty').click(); document.querySelector('.app-proto-error').click()"); spin(0.8)
check(js("return !!document.querySelector('.app-main [role=alert]')") as? Bool == true && text().contains("Retry"), "Force error state shows the error card")
_ = js("document.querySelector('.app-proto-error').click()"); spin(0.8)

check(js("var e = App.renderScreen('ticket', { params: { id: 't-1' } }); return e instanceof Element") as? Bool == true, "renderScreen returns an element")
check(js("return App.renderScreen('reports').textContent") as? String == "ReportsThis part is still being built.", "renderScreen of a missing screen is a panel")

_ = js("App.toast('Saved', 'success')")
check(js("return !!document.querySelector('.app-toasts .toast.toast-success')") as? Bool == true, "toasts use the documented classes")
let confirmed = js("var p = App.confirm('Delete?', { danger: true }); document.querySelector('.modal .btn-danger').click(); return await p") as? Bool
check(confirmed == true && js("return document.querySelectorAll('.modal').length") as? Int == 0, "confirm resolves and closes")

go("/tickets")
let audit = js("return await window.__mvAudit()") as? [String: Any]
let report = PrototypeAudit.report(from: audit)
let kinds = Dictionary(uniqueKeysWithValues: (report?.findings ?? []).map { ($0.id, $0.kind) })
print("     audit: \(String(describing: report))")
check(report?.checked == 3, "the audit opens the three routes without parameters")
check(kinds["tickets"] == nil, "the audit finds the working screen fine (the shell is chrome)")
check(kinds["reports"] == .unbuilt, "the audit reports the unwritten screen")
check(kinds["broken"] == .error, "the audit reports the failing screen")

check(PrototypeRuntime.seedProblem("DB.seed({ \"A\": [{ id: \"a\", note: \"say \"hi\"\" }] });")?.contains("does not run") == true,
      "an unescaped quote in seed.js is caught")
check(PrototypeRuntime.seedProblem("DB.seed({ \"A\": [{ id: \"a\", at: DB.days(-1) }] });") == nil, "a valid seed passes")
check(PrototypeRuntime.seedProblem("DB.seed({});")?.contains("no entity") == true, "an empty seed is refused")
check(PrototypeRuntime.seedProblem("var x = 1;")?.contains("must call") == true, "a file without DB.seed is refused")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
