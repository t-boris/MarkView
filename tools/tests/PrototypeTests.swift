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
check(manifest.mode == .requirements && manifest.gaps.isEmpty, "manifest defaults to requirements mode without gaps")

// A prototype.json written before `mode` and `gaps` existed still opens, with the defaults.
do {
    let old = """
    {"approved":false,"assumptions":["a"],"brief":"b","history":[{"date":"2023-11-14T22:13:20Z","instruction":"first","summary":"s","version":1}],
     "screens":["Home"],"slug":"old","sources":["docs"],"title":"Old","version":1}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try? decoder.decode(PrototypeFiles.Manifest.self, from: Data(old.utf8))
    check(decoded?.mode == .requirements && decoded?.gaps == [] && decoded?.title == "Old" && decoded?.history.count == 1
          && decoded?.assumptions == ["a"], "old manifest decodes with mode and gaps defaults")
    let minimal = try? decoder.decode(PrototypeFiles.Manifest.self, from: Data("{\"title\":\"T\",\"slug\":\"t\"}".utf8))
    check(minimal?.sources == [] && minimal?.version == 0 && minimal?.brief == "", "minimal manifest decodes with every default")
    let unknownMode = try? decoder.decode(PrototypeFiles.Manifest.self,
                                          from: Data("{\"title\":\"T\",\"slug\":\"t\",\"mode\":\"hologram\"}".utf8))
    check(unknownMode?.mode == .requirements, "unknown mode falls back to requirements")
    check((try? decoder.decode(PrototypeFiles.Manifest.self, from: Data("{\"slug\":\"t\"}".utf8))) == nil, "manifest without a title is rejected")
}

// Code mode and its gaps round-trip through prototype.json.
do {
    var code = PrototypeFiles.Manifest(title: "Shop", slug: "shop", brief: "", sources: ["web/src"], mode: .code,
                                       gaps: ["Checkout posts to /api/orders; the prototype confirms locally."])
    code.assumptions = ["Prices in EUR"]
    try PrototypeFiles.saveManifest(code, in: PrototypeFiles.folder(root: tmp, slug: "shop"))
    let loaded = PrototypeFiles.loadManifest(PrototypeFiles.folder(root: tmp, slug: "shop"))
    check(loaded == code && loaded?.mode == .code && loaded?.gaps.count == 1, "code-mode manifest round trip keeps mode and gaps")
    let text = String(decoding: try Data(contentsOf: PrototypeFiles.manifestURL(of: PrototypeFiles.folder(root: tmp, slug: "shop"))), as: UTF8.self)
    check(text.contains("\"mode\" : \"code\"") && text.contains("\"gaps\""), "mode is stored as its raw string")
}

// The inventory of a reconstruction scope: web-interface files only, noise folders skipped, capped.
do {
    let proj = FileManager.default.temporaryDirectory.appendingPathComponent("inv-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: proj) }
    func put(_ path: String, _ content: String = "x") throws {
        let url = proj.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    for path in ["package.json", "index.html", "src/App.tsx", "src/app.css", "src/theme.scss", "src/Widget.vue", "src/Card.svelte",
                 "src/legacy.htm", "src/util.ts", "src/main.jsx", "src/less.less", "public/manifest.json",
                 "src/logo.png", "src/data.json", "README.md", "src/vendor.min.js", "src/.secret.js",
                 "node_modules/react/index.js", "dist/bundle.js", "build/app.js", ".git/config.js", ".dde/prototypes/x/site/index.html",
                 ".hidden/app.js", "server/api.py", "server/routes.js", "electron/preload.js"] {
        try put(path)
    }
    try put("src/big.js", String(repeating: "a", count: 2048))
    let whole = PrototypeFiles.inventory(root: proj, sources: [])
    let paths = whole.entries.map(\.path)
    check(paths == paths.sorted() && Set(paths).count == paths.count, "inventory is sorted and unique")
    for wanted in ["package.json", "index.html", "src/App.tsx", "src/app.css", "src/theme.scss", "src/Widget.vue", "src/Card.svelte",
                   "src/legacy.htm", "src/util.ts", "src/main.jsx", "src/less.less", "public/manifest.json", "server/routes.js",
                   "electron/preload.js", "src/big.js"] {
        check(paths.contains(wanted), "inventory lists \(wanted)")
    }
    for unwanted in ["src/logo.png", "src/data.json", "README.md", "src/vendor.min.js", "src/.secret.js", "node_modules/react/index.js",
                     "dist/bundle.js", "build/app.js", ".git/config.js", ".dde/prototypes/x/site/index.html", ".hidden/app.js",
                     "server/api.py"] {
        check(!paths.contains(unwanted), "inventory skips \(unwanted)")
    }
    check(whole.entries.first { $0.path == "src/big.js" }?.bytes == 2048, "inventory carries the file size")
    check(whole.omitted == 0 && !whole.lines.contains { $0.hasPrefix("+") }, "no marker under the cap")
    check(whole.lines.contains("- src/big.js (2048 bytes)"), "inventory line format")

    let scoped = PrototypeFiles.inventory(root: proj, sources: ["src", "index.html", "missing", "../etc", "src/logo.png"])
    let scopedPaths = scoped.entries.map(\.path)
    check(scopedPaths.contains("src/App.tsx") && scopedPaths.contains("index.html"), "scoped inventory lists the selected folder and file")
    check(!scopedPaths.contains("package.json") && !scopedPaths.contains("server/routes.js"), "scoped inventory leaves other folders out")
    check(!scopedPaths.contains("src/logo.png"), "a selected file still passes the extension filter")
    check(PrototypeFiles.inventory(root: proj, sources: ["src", "src/App.tsx"]).entries.filter { $0.path == "src/App.tsx" }.count == 1,
          "a file inside a selected folder is listed once")

    let capped = PrototypeFiles.inventory(root: proj, sources: [], limit: 3)
    check(capped.entries.count == 3 && capped.omitted == whole.entries.count - 3, "inventory is capped")
    check(capped.lines.last == "+\(whole.entries.count - 3) more files not listed", "cap marker names the omitted count")
    check(PrototypeFiles.inventory(root: proj, sources: ["server/api.py"]).isEmpty, "a non-web scope gives an empty inventory")
}

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

// Images sent with a request are named in the prompt, by project-relative path.
let withImages = PrototypeAI.revisePrompt(instruction: "make it like this", pick: nil, siteRelative: "site", files: [],
    runtimeErrors: [], priorFailure: nil,
    attachments: [.init(path: ".dde/prototypes/x/attachments/a1.png", note: "image 1 from the reviewer")])
check(withImages.contains(".dde/prototypes/x/attachments/a1.png: image 1 from the reviewer") && withImages.contains("Read tool"),
      "prompt lists the images and tells the assistant to open them")
check(!PrototypeAI.revisePrompt(instruction: "x", pick: nil, siteRelative: "site", files: [], runtimeErrors: [], priorFailure: nil)
        .contains("Images the reviewer sent"), "no images, no image section")

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let saved = [PrototypeFiles.StoredMessage(role: "user", text: "Hi", images: ["a.png"]),
                 PrototypeFiles.StoredMessage(role: "error", text: "Timed out")]
    check(PrototypeFiles.loadConversation(dir) == nil, "no conversation file yet")
    PrototypeFiles.saveConversation(saved, in: dir)
    check(PrototypeFiles.loadConversation(dir) == saved, "conversation round-trips")
}

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
