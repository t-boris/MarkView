import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func throwsFailure(_ body: () throws -> Void) -> PrototypeFiles.Failure? {
    do { try body(); return nil } catch let f as PrototypeFiles.Failure { return f } catch { return nil }
}

for bad in ["/etc/passwd", "../x.html", "a/../../x.html", ".hidden.html", "a/.git/x.js", "app.exe", "noext", "", "a\\b.js"] {
    check(throwsFailure { _ = try PrototypeFiles.validate(path: bad) } != nil, "rejects \(bad.debugDescription)")
}
check((try? PrototypeFiles.validate(path: "js//app.js")) == "js/app.js", "normalises double slash")
check((try? PrototypeFiles.validate(path: "index.HTML")) == "index.HTML", "extension case")

check(PrototypeFiles.slug(for: "Order Tracking — Admin!", existing: []) == "order-tracking-admin", "slug")
check(PrototypeFiles.slug(for: "???", existing: []) == "prototype", "slug fallback")
check(PrototypeFiles.slug(for: "Shop", existing: ["shop", "shop-2"]) == "shop-3", "slug unique")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proto-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
let folder = PrototypeFiles.folder(root: tmp, slug: "demo")
let site = PrototypeFiles.site(of: folder)
try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)

var change = PrototypeFiles.Change(files: [.init(path: "index.html", content: "<h1>Hello</h1><p>x</p>"),
                                           .init(path: "js/app.js", content: "var a = 1;")])
check((try? PrototypeFiles.apply(change, to: site)) == ["index.html", "js/app.js"], "writes files")
check(PrototypeFiles.read(site: site).map(\.path) == ["index.html", "js/app.js"], "reads files")

change = .init(edits: [.init(path: "index.html", find: "Hello", replace: "Hi")])
_ = try PrototypeFiles.apply(change, to: site)
check(PrototypeFiles.read(site: site)[0].content == "<h1>Hi</h1><p>x</p>", "edit applied")

// An edit that cannot apply must leave every file untouched, including the valid ones before it.
change = .init(files: [.init(path: "new.css", content: "a{}")],
               edits: [.init(path: "index.html", find: "Hi", replace: "Yo"),
                       .init(path: "index.html", find: "missing", replace: "z")])
let failure = throwsFailure { _ = try PrototypeFiles.apply(change, to: site) }
check(failure != nil, "unmatched edit fails")
check(!FileManager.default.fileExists(atPath: site.appendingPathComponent("new.css").path), "no partial write")
check(PrototypeFiles.read(site: site)[0].content == "<h1>Hi</h1><p>x</p>", "file unchanged after failure")

try "<b>b</b><b>b</b>".write(to: site.appendingPathComponent("two.html"), atomically: true, encoding: .utf8)
check(throwsFailure { _ = try PrototypeFiles.apply(.init(edits: [.init(path: "two.html", find: "<b>", replace: "")]), to: site) } != nil,
      "ambiguous edit fails")

check(throwsFailure { _ = try PrototypeFiles.apply(.init(files: [.init(path: "../escape.html", content: "x")]), to: site) } != nil,
      "path escape rejected")
check(throwsFailure { _ = try PrototypeFiles.apply(.init(files: [.init(path: "big.html", content: String(repeating: "a", count: 700_000))]), to: site) } != nil,
      "oversized file rejected")

_ = try PrototypeFiles.apply(.init(deletes: ["two.html"]), to: site)
check(!FileManager.default.fileExists(atPath: site.appendingPathComponent("two.html").path), "delete")

try PrototypeFiles.snapshot(folder: folder, version: 1)
_ = try PrototypeFiles.apply(.init(files: [.init(path: "index.html", content: "changed")]), to: site)
try PrototypeFiles.restore(folder: folder, version: 1)
check(PrototypeFiles.read(site: site).first { $0.path == "index.html" }?.content == "<h1>Hi</h1><p>x</p>", "restore version")
check(throwsFailure { try PrototypeFiles.restore(folder: folder, version: 9) } != nil, "restore missing version")

var manifest = PrototypeFiles.Manifest(title: "Demo", slug: "demo", brief: "b", sources: ["docs"])
manifest.history.append(.init(version: 1, instruction: "first", summary: "s", date: Date(timeIntervalSince1970: 1_700_000_000)))
try PrototypeFiles.saveManifest(manifest, in: folder)
check(PrototypeFiles.loadManifest(folder) == manifest, "manifest round trip")
check(PrototypeFiles.existingSlugs(root: tmp) == ["demo"], "existing slugs")

// Screen scripts are inserted by the program at the marker.
let html = "<body>\n<script src=\"app.js\"></script>\n<!--SCREENS-->\n<script>App.start()</script>\n</body>"
let linked = PrototypeFiles.insertScreenScripts(into: html, ids: ["tickets", "dashboard"]) ?? ""
check(linked.contains("<script src=\"screens/tickets.js\"></script>\n<script src=\"screens/dashboard.js\"></script>"), "marker gets one script tag per screen")
check(linked.range(of: "screens/dashboard.js")!.lowerBound < linked.range(of: "App.start()")!.lowerBound, "screen scripts load before App.start()")
check(PrototypeFiles.insertScreenScripts(into: "<body></body>", ids: ["a"]) == nil, "missing marker is reported")

// The plan: ids become safe file names, unique, at most ten screens.
let planAnswer: [String: Any] = ["title": "Desk", "summary": "s", "assumptions": ["a"], "screens":
    [["id": "Tickets List!", "name": "Tickets", "route": "/tickets", "purpose": "p"],
     ["id": "tickets-list", "name": "Again", "route": "/again", "purpose": "p"],
     ["id": "../../etc", "name": "Evil", "route": "/e", "purpose": "p"],
     ["id": "", "name": "Дашборд", "route": "/d", "purpose": "p"]]]
let plan = try PrototypeAI.Plan(structured: planAnswer)
check(plan.screens.map(\.id) == ["tickets-list", "tickets-list-2", "etc", "screen-4"], "plan ids: safe, unique, never empty")
check(plan.screens.allSatisfy { (try? PrototypeFiles.validate(path: "screens/\($0.id).js")) != nil }, "plan ids make valid screen paths")
check(plan.json.contains("tickets-list-2"), "plan json carries the normalised ids")
let many: [String: Any] = ["screens": (1...14).map { ["id": "s\($0)", "name": "S\($0)"] as [String: Any] }]
check((try PrototypeAI.Plan(structured: many)).screens.count == 10, "plan is capped at ten screens")
var emptyPlanFails = false
do { _ = try PrototypeAI.Plan(structured: ["screens": []]) } catch { emptyPlanFails = true }
check(emptyPlanFails, "plan without screens is rejected")

let parsed = PrototypeFiles.change(from: ["files": [["path": "a.html", "content": "x"]],
                                          "edits": [["path": "a.html", "find": "x", "replace": "y"]], "delete": ["b.js"]])
check(parsed == PrototypeFiles.Change(files: [.init(path: "a.html", content: "x")],
                                      edits: [.init(path: "a.html", find: "x", replace: "y")], deletes: ["b.js"]), "parses an answer")
check(PrototypeFiles.change(from: "nonsense").isEmpty, "ignores a malformed answer")

// Progress lines: what the studio shows while the assistant works.
final class Lines: @unchecked Sendable {
    var logs: [String] = [], statuses: [String] = []
}
let lines = Lines()
let tracker = PrototypeAI.ProgressTracker(root: URL(fileURLWithPath: "/proj"), emit: { event in
    switch event {
    case .log(let t), .step(let t): lines.logs.append(t)
    case .status(let t): lines.statuses.append(t)
    default: break
    }
})
tracker.handle(.read("/proj/docs/req.md"))
tracker.handle(.read("/proj/docs/api.md"))
tracker.handle(.search("ticket status"))
tracker.handle(.thinking); tracker.handle(.thinking)
for chunk in ["{\"title\":\"X\",\"files\":[{\"pa", "th\":\"index.", "html\",\"content\":\"<h1>", "\"},{\"path\":\"app.js\",\"content\":\"x\"}"] {
    tracker.handle(.answerDelta(chunk))
}
check(lines.logs.contains("Reading docs/req.md"), "progress: read path is project-relative")
check(lines.statuses.contains("Reading the requirements (2 files so far)"), "progress: read counter")
check(lines.logs.contains("Searching for “ticket status”"), "progress: search")
check(lines.logs.filter { $0 == "Thinking" }.count == 1, "progress: repeated thinking logged once")
check(lines.logs.contains("Writing index.html"), "progress: file path split across chunks")
check(lines.logs.contains("Writing app.js"), "progress: second file")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
