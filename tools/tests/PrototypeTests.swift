import CryptoKit
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
check(PrototypeFiles.storageFolder == "docs/prototypes" && PrototypeFiles.legacyStorageFolder == ".dde/prototypes", "storage folders (DEC-006)")
check(folder.path == tmp.appendingPathComponent("docs/prototypes/demo").path, "a prototype lives in docs/prototypes/<slug>")
check(PrototypeFiles.storage(root: tmp).path == tmp.appendingPathComponent("docs/prototypes").path, "the storage folder")
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
                 "docs/prototypes/x/site/index.html", "docs/prototypes/x/site/screens/home.js", "docs/guide/page.html",
                 ".hidden/app.js", "server/api.py", "server/routes.js", "electron/preload.js"] {
        try put(path)
    }
    try put("src/big.js", String(repeating: "a", count: 2048))
    let whole = PrototypeFiles.inventory(root: proj, sources: [])
    let paths = whole.entries.map(\.path)
    check(paths == paths.sorted() && Set(paths).count == paths.count, "inventory is sorted and unique")
    for wanted in ["package.json", "index.html", "src/App.tsx", "src/app.css", "src/theme.scss", "src/Widget.vue", "src/Card.svelte",
                   "src/legacy.htm", "src/util.ts", "src/main.jsx", "src/less.less", "public/manifest.json", "server/routes.js",
                   "electron/preload.js", "src/big.js", "docs/guide/page.html"] {
        check(paths.contains(wanted), "inventory lists \(wanted)")
    }
    for unwanted in ["src/logo.png", "src/data.json", "README.md", "src/vendor.min.js", "src/.secret.js", "node_modules/react/index.js",
                     "dist/bundle.js", "build/app.js", ".git/config.js", ".dde/prototypes/x/site/index.html", ".hidden/app.js",
                     "server/api.py", "docs/prototypes/x/site/index.html", "docs/prototypes/x/site/screens/home.js"] {
        check(!paths.contains(unwanted), "inventory skips \(unwanted)")
    }
    check(whole.entries.first { $0.path == "src/big.js" }?.bytes == 2048, "inventory carries the file size")
    check(whole.omitted == 0 && !whole.lines.contains { $0.hasPrefix("+") }, "no marker under the cap")
    check(whole.lines.contains("- big.js (2048 bytes)") && whole.lines.contains { $0.hasPrefix("src/ (") },
          "inventory lists a block per folder with each file and its size")

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

// MARK: - Previews from Existing Code (code mode)

// Requirements mode keeps its prompts byte for byte: these SHA-256 digests were taken from the prompts
// before code mode existed. A pinned digest changes only when a requirements-mode prompt is changed on purpose.
func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
do {
    let screen = PrototypeAI.PlannedScreen(id: "home", name: "Home", route: "/home", purpose: "p")
    let files = [PrototypeFiles.File(path: "app.js", content: "x")]
    let pinned: [(String, String, String)] = [
        ("planSystem", PrototypeAI.planSystem(language: ""), "5e396efba058a77fb33e1a8bb28feb31569dc9ff1edcc9a98410095289d4809e"),
        ("planSystem with language", PrototypeAI.planSystem(language: " Answer in French."), "e036ad8be91345ed6de6bd6c7c12d4c1b347d1cdec1a1cb2ad5dc9d2b63fbe79"),
        ("planPrompt whole project", PrototypeAI.planPrompt(brief: "", sources: []), "fd70176cc8d68cf232da0df9f162179932ffba6cb13b7f9b01404975de9e9e90"),
        ("planPrompt sources", PrototypeAI.planPrompt(brief: "Only tickets", sources: ["docs/a.md", "docs/b"]), "e30e91fc3a3ce128b2f507a0b2ffb392f1ae719b703eec58c4b69e75245bf263"),
        ("dataSystem", PrototypeAI.dataSystem(language: ""), "0831ffa248985aa5ccec0515fee43ccc22c1b6a3c4ca31660920a99bd0400fee"),
        ("shellSystem", PrototypeAI.shellSystem(language: ""), "8222f48f1287ffd53a754ab368d241ed1658ab087ab5296e815f2f6ebcda505e"),
        ("stylesSystem", PrototypeAI.stylesSystem(language: ""), "1826c6bd4ce96575b11ba81605f33840b08ae65021905f22c395226f92b1a0ee"),
        // Changed on purpose by BUG-053: the sentence on what the callback of App.load returns.
        ("screenSystem", PrototypeAI.screenSystem(language: ""), "65b10d41921495bb31e3bfc4cb5945cbdd15d6f85a1bfd8d0f36503a500c321b"),
        // Changed on purpose by BUG-051: the `remaining` paragraph (a request for many files is revised file by file).
        ("reviseSystem", PrototypeAI.reviseSystem(language: ""), "31abde9e8392f5063365002697bd0b3e5a3dbb15da99b00c5bf9edd944bf6023"),
        ("foundationPrompt", PrototypeAI.foundationPrompt(plan: "{plan}", failure: "bad"), "97fed5ee5fa21774cd81a51a96520b245e334c98258563edc5dc71cfbe4a1e0e"),
        ("screenPrompt", PrototypeAI.screenPrompt(plan: "{plan}", screen: screen, foundation: files, failure: "bad"), "f7fdd93d414cdeb3b3b13ad41ac08f939988dfb430620eb3ce11cacb1547f228"),
        ("revisePrompt", PrototypeAI.revisePrompt(instruction: "do", pick: nil, siteRelative: ".dde/prototypes/x/site", files: files,
                                                  runtimeErrors: ["e"], priorFailure: "pf", attachments: [.init(path: "a.png", note: "n")]),
         "eb7e24aa369b6d4d2b7b4f9edd7459c26172314336f583a1a12460b7c69e0c0e"),
        ("specSystem", PrototypeAI.specSystem, "286eaf7fb14e6cd7eafdc948900374470d1135d0459ddbbde101e0852e8c1e51"),
    ]
    for (name, text, digest) in pinned { check(sha(text) == digest, "requirements-mode \(name) is unchanged") }

    // The spec request and the README of requirements mode, pinned as text.
    var m = PrototypeFiles.Manifest(title: "Desk", slug: "desk", brief: "", sources: ["docs/req.md"])
    m.version = 2
    m.assumptions = ["Tickets have one owner"]
    m.history = [.init(version: 1, instruction: "", summary: "Built", date: Date()), .init(version: 2, instruction: "Add filters", summary: "Filters added", date: Date())]
    let expectedSpec = """
    Write SPEC.md for the approved prototype "Desk" (version 2). The prototype files are in `.dde/prototypes/desk/site/`; the requirement sources are:
    - docs/req.md

    Sections, in this order:
    1. Purpose and users (from the requirements).
    2. Screens: for each, its route, purpose, the data it shows, every control and what it does, and its empty, loading, error and permission states.
    3. Navigation and flows: the transitions between screens as a table (from, trigger, to, condition).
    4. Data model: entities, fields, types, relations, validation rules and the sample data shape used by data.js.
    5. Business rules and behaviours the prototype demonstrates (numbered, testable statements).
    6. Requirements traceability: a table of requirement (quote or reference to the source) → screens and rules that satisfy it, and requirements not covered.
    7. Decisions made during review (below), and assumptions the requirements did not settle.
    8. Out of scope for the prototype, and what the real implementation must add (authentication, persistence, integrations).

    Decisions made during review:
    - v1: initial build → Built
    - v2: Add filters → Filters added

    Assumptions recorded at the first build:
    - Tickets have one owner
    """
    check(PrototypeAI.specPrompt(manifest: m, siteRelative: ".dde/prototypes/desk/site", language: "") == expectedSpec, "requirements-mode spec prompt is unchanged")
    let expectedReadme = """
    # Desk — approved prototype (v2)

    - `prototype/index.html` — open it in a browser; it is self-contained and needs no server.
    - `SPEC.md` — screens, states, flows, data, rules and requirement traceability.
    - `CHANGES.md` — the review requests that shaped this version.

    The prototype is the agreed behaviour and look. Implement the product to match it; where the prototype and SPEC.md differ, ask before choosing.

    """
    check(PrototypeAI.readme(manifest: m) == expectedReadme, "requirements-mode README is unchanged")
}

// The plan schema is additive: gaps at the top, evidence per screen, both required so Codex's strict schema is the same.
do {
    let props = PrototypeAI.planSchema["properties"] as? [String: Any] ?? [:]
    let screenItem = (props["screens"] as? [String: Any])?["items"] as? [String: Any] ?? [:]
    let screenProps = screenItem["properties"] as? [String: Any] ?? [:]
    check(props["gaps"] != nil && (PrototypeAI.planSchema["required"] as? [String] ?? []).contains("gaps"), "plan schema has gaps")
    check(screenProps["evidence"] != nil && (screenItem["required"] as? [String] ?? []).contains("evidence"), "plan schema has evidence per screen")
    check(props["assumptions"] != nil && screenProps["requirements"] != nil, "plan schema keeps the old keys")
    // The code-mode fields tell the planner of requirements mode to leave them empty.
    for (name, field) in [("gaps", props["gaps"]), ("evidence", screenProps["evidence"]), ("components", screenProps["components"])] {
        let description = (field as? [String: Any])?["description"] as? String ?? ""
        check(description.contains("empty unless reconstructing existing code"), "plan schema describes \(name) as empty outside code mode: \(description)")
    }
    check(((props["assumptions"] as? [String: Any])?["description"]) == nil, "the other list fields carry no description")
}

// The plan carries gaps and evidence in code mode; a plan cut at the cap records the dropped screens as a gap in any mode.
do {
    let answer: [String: Any] = ["title": "Shop", "summary": "s", "assumptions": [], "gaps": ["Checkout posts to /api/orders (src/checkout.js).", "  "],
        "screens": [["id": "cart", "name": "Cart", "route": "/cart", "purpose": "p", "evidence": ["src/Cart.vue", " src/cart.css ", ""]],
                    ["id": "home", "name": "Home", "route": "/", "purpose": "p"]]]
    let plan = try PrototypeAI.Plan(structured: answer, mode: .code)
    check(plan.gaps == ["Checkout posts to /api/orders (src/checkout.js)."], "plan keeps the non-empty gaps")
    check(plan.screens[0].evidence == ["src/Cart.vue", "src/cart.css"] && plan.screens[1].evidence.isEmpty, "plan keeps trimmed evidence per screen")
    // JSONSerialization writes "/" as "\/", so look for the words.
    check(plan.json.contains("Cart.vue") && plan.json.contains("\"evidence\"") && plan.json.contains("\"gaps\"") && plan.json.contains("orders"),
          "plan json carries evidence and gaps for the later runs")
    let old = try PrototypeAI.Plan(structured: ["screens": [["id": "a", "name": "A"]]], mode: .code)
    check(old.gaps.isEmpty, "a plan without gaps has none")
    // Requirements mode: the schema makes the planner fill `gaps` anyway; nothing of it may surface as a known gap.
    let designed = try PrototypeAI.Plan(structured: answer)
    check(designed.gaps.isEmpty && designed.screens.count == 2, "requirements mode drops the planner's gaps")
    check(!designed.json.contains("orders") && designed.json.contains("\"gaps\""), "the requirements-mode plan json keeps the key for the writers, without the text")
    var tooMany = answer
    tooMany["screens"] = (1...11).map { ["id": "s\($0)", "name": "Screen \($0)"] as [String: Any] }
    let cutDesigned = try PrototypeAI.Plan(structured: tooMany)
    check(cutDesigned.gaps.count == 1 && cutDesigned.gaps[0].contains("11 screens"), "requirements mode keeps the screen-cap gap only: \(cutDesigned.gaps)")
    let many: [String: Any] = ["screens": (1...12).map { ["id": "s\($0)", "name": "Screen \($0)"] as [String: Any] }]
    let cut = try PrototypeAI.Plan(structured: many)
    check(cut.screens.count == 10 && cut.gaps.count == 1 && cut.gaps[0].contains("12 screens") && cut.gaps[0].contains("Screen 11, Screen 12"),
          "a plan past the cap records the dropped screens as a gap")
}

// Code mode: the planner is told that the code is the reference and what it must return.
do {
    let system = PrototypeAI.codePlanSystem(language: " Answer in German.")
    for phrase in ["reconstructs an EXISTING web interface", "`evidence`", "`gaps`", "`ipcRenderer`", "at most 40",
                   "Every screen maps to a real route", "do not add screens, controls or features the code does not have", "Answer in German."] {
        check(system.contains(phrase), "code plan system says: \(phrase)")
    }
    let inventory = PrototypeFiles.Inventory(entries: [.init(path: "web/src/App.tsx", bytes: 1200), .init(path: "web/src/app.css", bytes: 300)], omitted: 7)
    let scope = PrototypeAI.CodeScope(apps: [.init(path: "web", label: "web", isElectron: false),
                                             .init(path: "apps/desktop", label: "desktop", isElectron: true)])
    let prompt = PrototypeAI.codePlanPrompt(brief: "", sources: ["web/src", "web/index.html"], scope: scope, inventory: inventory)
    for phrase in ["Reconstruct the existing web interface", "- web/src\n", "- web/index.html\n", "read them with your tools",
                   "Web applications detected", "- web (web) — web application",
                   "- apps/desktop (desktop) — Electron renderer: only the browser part is in scope; `window.electron`/`ipcRenderer` calls must be simulated and listed as gaps",
                   "Web-interface files in the scope (2 listed", "web/src/ (2 files, 1 KB)", "- App.tsx (1200 bytes)", "+7 more files not listed",
                   "A faithful reconstruction of everything the sources implement."] {
        check(prompt.contains(phrase), "code plan prompt says: \(phrase)")
    }
    check(!prompt.contains("requirement"), "code plan prompt never calls the sources requirements")
    let whole = PrototypeAI.codePlanPrompt(brief: "Only the cart", sources: [], scope: PrototypeAI.CodeScope(), inventory: PrototypeFiles.Inventory())
    check(whole.contains("the whole project folder: find the web interface in it yourself") && !whole.contains("Web applications detected")
          && whole.contains("No web-interface files") && whole.hasSuffix("Only the cart"), "code plan prompt: whole project, no hints, empty inventory, brief")

    // The foundation and each screen are pointed at the original sources.
    let foundation = PrototypeAI.foundationPrompt(plan: "{plan}", failure: nil, mode: .code)
    check(foundation.hasPrefix("The plan of the prototype:\n{plan}") && foundation.contains("reproduce the original design tokens"),
          "code-mode foundation prompt keeps the plan and asks for the original tokens")
    let screen = PrototypeAI.PlannedScreen(id: "cart", name: "Cart", route: "/cart", purpose: "p", evidence: ["web/src/Cart.vue", "web/src/cart.css"])
    let screenPrompt = PrototypeAI.screenPrompt(plan: "{plan}", screen: screen, foundation: [], failure: "bad", mode: .code)
    check(screenPrompt.contains("- web/src/Cart.vue\n- web/src/cart.css\n") && screenPrompt.contains("CSS tokens")
          && screenPrompt.contains("no network request") && screenPrompt.hasSuffix("Your previous answer was not usable:\nbad"),
          "code-mode screen prompt lists the evidence and keeps the standalone rule and the failure")
    let noEvidence = PrototypeAI.screenPrompt(plan: "{plan}", screen: PrototypeAI.PlannedScreen(id: "a", name: "A", route: "/a", purpose: ""),
                                              foundation: [], failure: nil, mode: .code)
    check(noEvidence.contains("find its source files with your tools"), "code-mode screen prompt without evidence asks the writer to find the sources")

    // Revisions name the sources instead of the project's documents.
    let revise = PrototypeAI.revisePrompt(instruction: "Bigger button", pick: nil, siteRelative: "site", files: [], runtimeErrors: [],
                                          priorFailure: nil, mode: .code, sources: ["web/src"])
    check(revise.contains("reconstruction of the existing interface implemented in the project's source code in `web/src`")
          && !revise.contains("requirements come from the project's documents") && revise.hasSuffix("Reviewer's request:\nBigger button"),
          "code-mode revise prompt names the sources")
    check(PrototypeAI.revisePrompt(instruction: "x", pick: nil, siteRelative: "site", files: [], runtimeErrors: [], priorFailure: nil, mode: .code)
            .contains("implemented in the project's own source code;"), "code-mode revise prompt without sources names the project")

    // The specification and the README disclose the reconstruction and its gaps.
    var m = PrototypeFiles.Manifest(title: "Shop", slug: "shop", brief: "", sources: ["web/src"], mode: .code,
                                    gaps: ["Checkout posts to /api/orders; the prototype confirms locally."])
    m.version = 1
    let spec = PrototypeAI.specPrompt(manifest: m, siteRelative: "site", language: "")
    for phrase in ["reconstruction of the existing interface implemented in these sources", "- web/src", "Source traceability",
                   "Reconstruction: sources, evidence, known gaps", "do not present it as verified reproduction",
                   "Known gaps recorded at the first build:\n- Checkout posts to /api/orders; the prototype confirms locally."] {
        check(spec.contains(phrase), "code-mode spec prompt says: \(phrase)")
    }
    check(!spec.contains("Requirements traceability"), "code-mode spec prompt traces to sources, not requirements")
    check(PrototypeAI.codeSpecSystem.contains("never present simulated behaviour as a verified reproduction"), "code-mode spec system forbids fake verification")
    let readme = PrototypeAI.readme(manifest: m)
    check(readme.contains("reconstruction of the project's existing web interface in `web/src`") && readme.contains("Known reconstruction gaps")
          && readme.contains("- Checkout posts to /api/orders; the prototype confirms locally.\n"), "code-mode README discloses the reconstruction and its gaps")
    m.gaps = []
    check(PrototypeAI.readme(manifest: m).contains("No reconstruction gaps were recorded"), "code-mode README says when no gaps were recorded")
}

// Code mode progress lines read the code, not the requirements.
do {
    let lines = Lines()
    let tracker = PrototypeAI.ProgressTracker(root: URL(fileURLWithPath: "/proj"), reading: "the code", emit: { event in
        if case .status(let t) = event { lines.statuses.append(t) }
    })
    tracker.handle(.read("/proj/web/src/App.tsx"))
    check(lines.statuses == ["Reading the code (1 file so far)"], "progress: code-mode read counter")
}

// Legacy prototypes move from .dde/prototypes to docs/prototypes once; a conflict stays; nothing is deleted (DEC-006).
do {
    let proj = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: proj) }
    let fm = FileManager.default
    func put(_ path: String, _ content: String = "x") throws {
        let url = proj.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    check(PrototypeFiles.migrateLegacy(root: proj) == PrototypeFiles.MigrationReport(), "no legacy folder: nothing to do")
    check(PrototypeFiles.MigrationReport().summary == "nothing to migrate" && PrototypeFiles.MigrationReport().isEmpty, "empty report")
    try put(".dde/prototypes/shop/prototype.json", "{\"title\":\"Shop\",\"slug\":\"shop\"}")
    try put(".dde/prototypes/shop/site/index.html", "<h1>shop</h1>")
    try put(".dde/prototypes/shop/versions/v1/index.html", "<h1>shop</h1>")
    // The implementation ZIPs an earlier app wrote inside the prototype must not be committed with it (DEC-006).
    try put(".dde/prototypes/shop/export/shop-v1.zip", "PK1")
    try put(".dde/prototypes/shop/export/shop-v2.zip", "PK2")
    try put(".dde/prototypes/shop/export/.DS_Store", "")
    try put(".dde/prototypes/desk/prototype.json", "{\"title\":\"Desk\",\"slug\":\"desk\"}")
    try put(".dde/prototypes/desk/site/index.html", "<h1>legacy desk</h1>")
    try put(".dde/prototypes/.DS_Store", "")
    try put(".dde/prototypes/stray.txt", "not a prototype")
    try put("docs/prototypes/desk/prototype.json", "{\"title\":\"Desk\",\"slug\":\"desk\"}")
    try put("docs/prototypes/desk/site/index.html", "<h1>new desk</h1>")
    // A ZIP whose name is already taken in the exports folder cannot move: its prototype stays and is reported.
    try put(".dde/prototypes/blog/prototype.json", "{\"title\":\"Blog\",\"slug\":\"blog\"}")
    try put(".dde/prototypes/blog/site/index.html", "<h1>blog</h1>")
    try put(".dde/prototypes/blog/export/blog-v1.zip", "PKold")
    try put(".dde/exports/prototypes/blog-v1.zip", "PKnew")
    let first = PrototypeFiles.migrateLegacy(root: proj)
    check(first == PrototypeFiles.MigrationReport(moved: ["shop"], conflicts: ["desk"],
                                                  failed: ["blog: .dde/exports/prototypes/blog-v1.zip already exists"],
                                                  exports: ["shop-v1.zip", "shop-v2.zip"]), "moves shop and its archives, leaves desk and blog: \(first)")
    check(first.summary == "moved shop to docs/prototypes; moved export archives to .dde/exports/prototypes: shop-v1.zip, shop-v2.zip; "
          + "left in .dde/prototypes (slug already in docs/prototypes): desk; could not move: blog: .dde/exports/prototypes/blog-v1.zip already exists",
          "report summary: \(first.summary)")
    check(fm.fileExists(atPath: proj.appendingPathComponent("docs/prototypes/shop/versions/v1/index.html").path)
          && fm.fileExists(atPath: proj.appendingPathComponent("docs/prototypes/shop/site/index.html").path)
          && !fm.fileExists(atPath: proj.appendingPathComponent(".dde/prototypes/shop").path), "the whole folder moved")
    check((try? String(contentsOf: proj.appendingPathComponent(".dde/exports/prototypes/shop-v1.zip"), encoding: .utf8)) == "PK1"
          && (try? String(contentsOf: proj.appendingPathComponent(".dde/exports/prototypes/shop-v2.zip"), encoding: .utf8)) == "PK2",
          "the archives are in .dde/exports/prototypes")
    check(!fm.fileExists(atPath: proj.appendingPathComponent("docs/prototypes/shop/export").path), "no export folder reaches docs/prototypes")
    check((try? String(contentsOf: proj.appendingPathComponent("docs/prototypes/desk/site/index.html"), encoding: .utf8)) == "<h1>new desk</h1>"
          && (try? String(contentsOf: proj.appendingPathComponent(".dde/prototypes/desk/site/index.html"), encoding: .utf8)) == "<h1>legacy desk</h1>",
          "a conflict is left in place: neither copy is touched")
    check(fm.fileExists(atPath: proj.appendingPathComponent(".dde/prototypes/stray.txt").path), "files in the legacy folder are not moved or deleted")
    check(fm.fileExists(atPath: proj.appendingPathComponent(".dde/prototypes/blog/export/blog-v1.zip").path)
          && !fm.fileExists(atPath: proj.appendingPathComponent("docs/prototypes/blog").path)
          && (try? String(contentsOf: proj.appendingPathComponent(".dde/exports/prototypes/blog-v1.zip"), encoding: .utf8)) == "PKnew",
          "a prototype whose archive cannot move stays in .dde/prototypes with it; the existing archive is untouched")
    check(PrototypeFiles.existingSlugs(root: proj) == ["desk", "shop"], "the new storage lists both")
    let second = PrototypeFiles.migrateLegacy(root: proj)
    check(second == PrototypeFiles.MigrationReport(conflicts: ["desk"], failed: ["blog: .dde/exports/prototypes/blog-v1.zip already exists"]),
          "a second run moves nothing and reports the conflict and the failure again: \(second)")
    check(fm.fileExists(atPath: proj.appendingPathComponent("docs/prototypes/shop/site/index.html").path), "idempotent: shop stays")
}

// DEC-003: a web interface is detected when the discovery found an app in the scope or the scope holds web-interface files.
do {
    let files = PrototypeFiles.Inventory(entries: [.init(path: "index.html", bytes: 10)])
    check(PrototypeFiles.hasWebInterface(inventory: files, apps: [String]()), "web-interface files alone count (a static site)")
    check(PrototypeFiles.hasWebInterface(inventory: PrototypeFiles.Inventory(), apps: ["web"]), "a detected app alone counts")
    check(PrototypeFiles.hasWebInterface(inventory: files, apps: ["web"]), "both count")
    check(!PrototypeFiles.hasWebInterface(inventory: PrototypeFiles.Inventory(), apps: [String]()), "neither: refused")
    check(PrototypeFiles.hasWebInterface(inventory: PrototypeFiles.Inventory(entries: [], omitted: 3), apps: [String]()) == false,
          "an inventory with nothing listed is empty")
}

// Code mode scope (DEC-003): nothing selected is the whole project; otherwise an app is in scope when it holds a
// selected source or sits inside a selected folder.
do {
    check(PrototypeFiles.isInScope(appPath: "", sources: []) && PrototypeFiles.isInScope(appPath: "web", sources: []), "nothing selected: every app")
    check(PrototypeFiles.isInScope(appPath: "web", sources: ["web"]), "the selected folder is the app")
    check(PrototypeFiles.isInScope(appPath: "web", sources: ["web/"]) && PrototypeFiles.isInScope(appPath: "web/", sources: ["./web"]), "slashes and ./ are ignored")
    check(PrototypeFiles.isInScope(appPath: "web", sources: ["web/src/App.tsx"]), "a selected file inside the app")
    check(PrototypeFiles.isInScope(appPath: "apps/site", sources: ["apps"]), "an app inside the selected folder")
    check(PrototypeFiles.isInScope(appPath: "", sources: ["src/App.tsx"]), "the root app holds every selection")
    check(!PrototypeFiles.isInScope(appPath: "web", sources: ["server"]), "another folder is out of scope")
    check(!PrototypeFiles.isInScope(appPath: "web", sources: ["webapp"]), "a prefix that is not a folder is out of scope")
    check(!PrototypeFiles.isInScope(appPath: "web", sources: ["README.md", "docs"]), "files elsewhere are out of scope")
    check(PrototypeFiles.isInScope(appPath: "web", sources: ["server", "web/index.html"]), "one matching source is enough")
    check(PrototypeFiles.isInScope(appPath: "web", sources: [" ", ""]), "blank sources count as nothing selected")
}

// MARK: - Components (REQ-007, DEC-005)

// Component paths, labels and isolated page names.
do {
    check(PrototypeFiles.componentPath(" ./src/components/OrderList.vue ") == "src/components/OrderList.vue", "component path is trimmed and loses ./")
    check(PrototypeFiles.componentPath("src//a.tsx") == "src/a.tsx", "component path loses a doubled slash")
    for bad in ["", "   ", "/abs/x.vue", "../x.vue", "src/../x.vue", "src/./x.vue", "src/${name}.vue", "src/a b.vue", "a\\b.vue"] {
        check(PrototypeFiles.componentPath(bad) == nil, "component path rejects \(bad.debugDescription)")
    }
    check(PrototypeFiles.componentLabel("src/components/OrderList.vue") == "OrderList", "component label is the file name without extension")
    check(PrototypeFiles.componentLabel("templates/index.html") == "index" && PrototypeFiles.componentLabel("Makefile") == "Makefile", "label without extension")
    check(PrototypeFiles.componentPage(for: "src/components/OrderList.vue") == "components/src-components-orderlist-vue.html", "isolated page name")
    check(PrototypeFiles.componentPage(for: "Äpp/Главная.svelte") == "components/pp-svelte.html", "isolated page name is ASCII only")
    check((try? PrototypeFiles.validate(path: PrototypeFiles.componentPage(for: "src/A.tsx"))) != nil, "isolated page is a valid site path")
    check(PrototypeFiles.componentMarker == "data-mv-component", "the marker attribute")
}

// A component link must name a regular file of the sources (REQ-007: no link is invented).
do {
    let proj = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: proj) }
    let file = proj.appendingPathComponent("src/components/OrderList.vue")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "<template/>".write(to: file, atomically: true, encoding: .utf8)
    check(PrototypeFiles.isSourceFile(root: proj, path: "src/components/OrderList.vue"), "an existing file")
    check(PrototypeFiles.isSourceFile(root: proj, path: "./src/components/OrderList.vue"), "the path is normalised first")
    check(!PrototypeFiles.isSourceFile(root: proj, path: "src/components/Missing.vue"), "a missing file")
    check(!PrototypeFiles.isSourceFile(root: proj, path: "src/components"), "a folder is not a component file")
    check(!PrototypeFiles.isSourceFile(root: proj, path: "../\(proj.lastPathComponent)/src/components/OrderList.vue")
          && !PrototypeFiles.isSourceFile(root: proj, path: file.path), "paths that climb out or are absolute")
}

// Markers are read from HTML and from the scripts that build it, in every form the screen writers use.
do {
    let text = """
    <div data-mv-component="src/Header.vue"><span data-mv-component='src/Logo.vue'></span></div>
    App.h('section', {'data-mv-component': 'src/OrderList.vue'}, rows)
    el.setAttribute("data-mv-component", "src/Footer.vue"); x.setAttribute('data-mv-component', `src/${name}.vue`)
    <p data-mv-component="src/Header.vue">again</p> <b data-mv-component="../etc/passwd">bad</b>
    """
    check(PrototypeFiles.componentMarkers(in: text) == ["src/Header.vue", "src/Logo.vue", "src/OrderList.vue", "src/Footer.vue"],
          "markers: attribute, single quotes, attribute object, setAttribute; duplicates once; template and escapes skipped")
    check(PrototypeFiles.componentMarkers(in: "<div class=\"x\">no markers</div>").isEmpty, "no markers")
}

// The component scan: plan and markup together, screens attributed by file, pages linked only when they exist.
do {
    let proj = FileManager.default.temporaryDirectory.appendingPathComponent("comp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: proj) }
    let site = PrototypeFiles.site(of: PrototypeFiles.folder(root: proj, slug: "shop"))
    try PrototypeFiles.apply(.init(files: [
        .init(path: "index.html", content: "<header data-mv-component=\"src/Shell.vue\"></header>\n<!--SCREENS-->"),
        .init(path: "app.js", content: "window.App = {};"),
        .init(path: "screens/orders.js", content: "App.register({render(){ return '<div data-mv-component=\"src/OrderList.vue\"><i data-mv-component=\"src/Badge.vue\"></i></div>'; }})"),
        .init(path: "screens/cart.js", content: "App.h('div', {'data-mv-component': 'src/Badge.vue'})"),
        .init(path: "components/src-orderlist-vue.html", content: "<main data-mv-component=\"src/OrderList.vue\"></main>"),
        .init(path: "components/src-stray-vue.html", content: "<main data-mv-component=\"src/Stray.vue\"></main>"),
    ]), to: site)
    let screens = [PrototypeFiles.ScreenRef(id: "orders", name: "Orders", components: ["src/OrderList.vue", "src/Planned.vue"]),
                   PrototypeFiles.ScreenRef(id: "cart", name: "Cart", components: ["./src/Planned.vue"])]
    let found = PrototypeFiles.components(in: site, screens: screens)
    check(found.map(\.path) == ["src/OrderList.vue", "src/Planned.vue", "src/Shell.vue", "src/Badge.vue"],
          "components: plan first in plan order, then markers in file order, each once: \(found.map(\.path))")
    check(found[0] == .init(path: "src/OrderList.vue", label: "OrderList", screens: ["Orders"], page: "components/src-orderlist-vue.html"),
          "a planned component gets its screens and its isolated page")
    check(found[1] == .init(path: "src/Planned.vue", label: "Planned", screens: ["Orders", "Cart"], page: nil),
          "a planned component without markup keeps both screens and has no page")
    check(found[2] == .init(path: "src/Shell.vue", label: "Shell", screens: [], page: nil), "a shell marker counts for no screen")
    check(found[3] == .init(path: "src/Badge.vue", label: "Badge", screens: ["Cart", "Orders"], page: nil),
          "a marker in two screen scripts lists both screens (file order)")
    check(!found.contains { $0.path == "src/Stray.vue" }, "a marker only in an isolated page is not a component")
    check(PrototypeFiles.components(in: site.appendingPathComponent("missing"), screens: []).isEmpty, "no site, no components")
    check(PrototypeFiles.components(in: site, screens: [.init(id: "x", name: "X", components: ["../out.vue", " "])]).map(\.path)
            == ["src/Shell.vue", "src/Badge.vue", "src/OrderList.vue"], "bad plan paths are dropped; markers stay in file order")

    // A restored version is scanned again: the manifest's screens and order are kept for what the files still mark,
    // a component the files no longer mention goes unless its isolated page is there, a new marker joins with no screens.
    let known: [PrototypeFiles.Component] = [
        .init(path: "src/Badge.vue", label: "Badge", screens: ["Cart", "Orders"]),
        .init(path: "src/Gone.vue", label: "Gone", screens: ["Orders"]),
        .init(path: "src/OrderList.vue", label: "OrderList", screens: ["Orders"], page: "components/src-orderlist-vue.html"),
        .init(path: "src/Planned.vue", label: "Planned", screens: ["Orders", "Cart"]),
    ]
    _ = try PrototypeFiles.apply(.init(files: [.init(path: "components/src-planned-vue.html", content: "<main data-mv-component=\"src/Planned.vue\"></main>")]), to: site)
    let rescanned = PrototypeFiles.rescanComponents(in: site, known: known)
    check(rescanned == [
        .init(path: "src/Badge.vue", label: "Badge", screens: ["Cart", "Orders"]),
        .init(path: "src/OrderList.vue", label: "OrderList", screens: ["Orders"], page: "components/src-orderlist-vue.html"),
        .init(path: "src/Planned.vue", label: "Planned", screens: ["Orders", "Cart"], page: "components/src-planned-vue.html"),
        .init(path: "src/Shell.vue", label: "Shell", screens: []),
    ], "rescan after a restore: \(rescanned)")
    check(PrototypeFiles.rescanComponents(in: site.appendingPathComponent("missing"), known: known).isEmpty, "no files, no components, whatever was known")
}

// The manifest carries the components; an older prototype.json decodes with none.
do {
    let proj = FileManager.default.temporaryDirectory.appendingPathComponent("cman-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: proj) }
    let folder = PrototypeFiles.folder(root: proj, slug: "shop")
    var m = PrototypeFiles.Manifest(title: "Shop", slug: "shop", brief: "", sources: ["web"], mode: .code)
    m.components = [.init(path: "web/src/A.vue", label: "A", screens: ["Home"], page: "components/web-src-a-vue.html"),
                    .init(path: "web/src/B.vue", label: "B")]
    try PrototypeFiles.saveManifest(m, in: folder)
    let loaded = PrototypeFiles.loadManifest(folder)
    check(loaded == m && loaded?.components.count == 2 && loaded?.components[1].page == nil, "manifest round trip keeps the components")
    let text = String(decoding: try Data(contentsOf: PrototypeFiles.manifestURL(of: folder)), as: UTF8.self)
    check(text.contains("\"components\"") && text.contains("\"page\" : \"components\\/web-src-a-vue.html\""), "components are stored under their key")
    try "{\"title\":\"Old\",\"slug\":\"shop\",\"mode\":\"code\",\"gaps\":[\"g\"]}".write(to: PrototypeFiles.manifestURL(of: folder), atomically: true, encoding: .utf8)
    let old = PrototypeFiles.loadManifest(folder)
    check(old?.components == [] && old?.gaps == ["g"] && old?.mode == .code, "a manifest without components decodes with none")
}

// The implementation ZIP lives outside the committed prototype folder (DEC-006).
do {
    let root = URL(fileURLWithPath: "/proj")
    check(PrototypeFiles.exportsFolder == ".dde/exports/prototypes", "exports folder")
    check(PrototypeFiles.exportArchive(root: root, slug: "shop", version: 3).path == "/proj/.dde/exports/prototypes/shop-v3.zip", "export archive path")
    check(!PrototypeFiles.exportArchive(root: root, slug: "shop", version: 3).path.hasPrefix(PrototypeFiles.storage(root: root).path), "the archive is not under docs/prototypes")
}

// The scope mapping the creator sheet and "Sync from code" share (REQ-006).
do {
    let root = URL(fileURLWithPath: "/proj")
    let detected: [PrototypeAI.CodeScope.Detected] = [
        (URL(fileURLWithPath: "/proj"), "proj", false),
        (URL(fileURLWithPath: "/proj/web/"), "web", false),
        (URL(fileURLWithPath: "/proj/apps/desktop"), "desktop", true),
        (URL(fileURLWithPath: "/elsewhere/app"), "stray", false),
    ]
    let whole = PrototypeAI.CodeScope(root: root, sources: [], detected: detected)
    check(whole.apps == [.init(path: "", label: "proj", isElectron: false), .init(path: "web", label: "web", isElectron: false),
                         .init(path: "apps/desktop", label: "desktop", isElectron: true)], "whole project: every app inside the root, relative paths: \(whole.apps)")
    let scoped = PrototypeAI.CodeScope(root: root, sources: ["apps"], detected: detected)
    check(scoped.apps.map(\.path) == ["", "apps/desktop"], "sources keep the root app and the apps inside them: \(scoped.apps.map(\.path))")
    check(PrototypeAI.CodeScope(root: root, sources: ["server"], detected: detected).apps.map(\.path) == [""], "only the root app holds an unrelated source")
    check(PrototypeAI.CodeScope(apps: []).apps.isEmpty && PrototypeAI.CodeScope().apps.isEmpty, "the plain initialisers stay")
}

// The plan schema and parsing carry the components of each screen.
do {
    let props = PrototypeAI.planSchema["properties"] as? [String: Any] ?? [:]
    let screenItem = (props["screens"] as? [String: Any])?["items"] as? [String: Any] ?? [:]
    let screenProps = screenItem["properties"] as? [String: Any] ?? [:]
    check(screenProps["components"] != nil && (screenItem["required"] as? [String] ?? []).contains("components"), "plan schema has components per screen")
    let answer: [String: Any] = ["screens": [["id": "orders", "name": "Orders", "components": [" ./src/OrderList.vue", "src/OrderList.vue", "../x.vue", ""]],
                                             ["id": "home", "name": "Home"]]]
    let plan = try PrototypeAI.Plan(structured: answer, mode: .code)
    check(plan.screens[0].components == ["src/OrderList.vue"] && plan.screens[1].components.isEmpty, "plan components are normalised and unique")
    check(plan.json.contains("\"components\"") && plan.json.contains("OrderList.vue") && !plan.json.contains("x.vue"), "plan json carries the normalised components")
    check(try PrototypeAI.Plan(structured: answer).screens[0].components.isEmpty, "requirements mode has no components to link")

    // A plan component without a source file is not linked: it is a gap, once, and the writers never see it (REQ-007).
    let ghosts: [String: Any] = ["gaps": ["Posts to /api"], "screens": [
        ["id": "orders", "name": "Orders", "components": ["src/OrderList.vue", "src/Ghost.vue"]],
        ["id": "cart", "name": "Cart", "components": ["src/Ghost.vue", "src/Cart.vue"]]]]
    let checked = try PrototypeAI.Plan(structured: ghosts, mode: .code, sourceExists: { $0 != "src/Ghost.vue" })
    check(checked.screens.map(\.components) == [["src/OrderList.vue"], ["src/Cart.vue"]], "components without a file are dropped from every screen")
    check(checked.gaps == ["Posts to /api", "Component src/Ghost.vue named by the plan was not found in the sources"], "one gap per missing component: \(checked.gaps)")
    check(!checked.json.contains("Ghost"), "the plan json the writers see does not name it")
}

// BUG-049: the shell is written in two parts, so no single answer has to carry index.html, app.js
// and styles.css at once. Each part must know the other's contract and stay out of its files.
do {
    let shell = PrototypeAI.shellSystem(language: "")
    let styles = PrototypeAI.stylesSystem(language: "")
    check(shell.contains("exactly two files: index.html and app.js") && shell.contains("not styles.css"),
          "the shell part writes index.html and app.js only")
    check(styles.contains("exactly one file: styles.css") && styles.contains("Write only styles.css"),
          "the styles part writes styles.css only")
    for part in [shell, styles] {
        check(part.contains("`card-header`") && part.contains("`field-error`") && part.contains("`pagination`"),
              "both parts share the same class contract")
    }
    check(shell.contains("<!--SCREENS-->") && shell.contains("App.register({id, route, title, render(ctx)})"),
          "the shell part still carries the screen-script marker and the App API")
    check(styles.contains("tokens as CSS variables") && styles.contains("under 20 KB"),
          "the styles part still carries the design system and its budget")
}

// Code-mode prompts carry the marker rule; requirements mode stays pinned above.
do {
    check(PrototypeAI.codePlanSystem(language: "").contains("`components` (the component files among the evidence"), "code plan system asks for the components")
    check(PrototypeAI.componentRule.contains("data-mv-component=\"<path>\"") && PrototypeAI.componentRule.contains("never invent a marker"),
          "the marker rule names the attribute and forbids invented markers")
    check(PrototypeAI.foundationPrompt(plan: "{plan}", failure: nil, mode: .code).contains(PrototypeAI.componentRule), "code-mode foundation prompt carries the marker rule")
    check(!PrototypeAI.foundationPrompt(plan: "{plan}", failure: nil).contains("data-mv-component"), "requirements-mode foundation prompt has no marker rule")
    let screen = PrototypeAI.PlannedScreen(id: "orders", name: "Orders", route: "/orders", purpose: "p", evidence: ["src/Orders.vue"],
                                           components: ["src/Orders.vue", "src/Badge.vue"])
    let prompt = PrototypeAI.screenPrompt(plan: "{plan}", screen: screen, foundation: [], failure: nil, mode: .code)
    check(prompt.contains(PrototypeAI.componentRule) && prompt.contains("as the plan names them:\n- src/Orders.vue\n- src/Badge.vue\n"),
          "code-mode screen prompt carries the rule and the screen's components")
    check(!PrototypeAI.screenPrompt(plan: "{plan}", screen: screen, foundation: [], failure: nil).contains("data-mv-component"), "requirements-mode screen prompt has no markers")
    let system = PrototypeAI.componentSystem(language: " In French.")
    for phrase in ["isolated view of a source component", "`../styles.css`", "does not call `App.start()`", "<main id=\"component\">",
                   "data-mv-component", "Do not edit other files", "In French."] {
        check(system.contains(phrase), "component system says: \(phrase)")
    }
    let isolated = PrototypeAI.componentPrompt(plan: "{plan}", component: "src/Badge.vue", page: "components/src-badge-vue.html",
                                               screens: [screen], foundation: [.init(path: "app.js", content: "x")], failure: "bad")
    for phrase in ["{plan}", "=== app.js ===\nx", "component `src/Badge.vue` as `components/src-badge-vue.html`",
                   "- Orders: screens/orders.js\n", "Read the component's source file `src/Badge.vue`", "Your previous answer was not usable:\nbad"] {
        check(isolated.contains(phrase), "component prompt says: \(phrase)")
    }
    check(PrototypeAI.componentPrompt(plan: "{plan}", component: "src/X.vue", page: "components/x.html", screens: [], foundation: [], failure: nil)
            .contains("No screen script names it"), "component prompt without screens sends the writer to the source")
    let pick = PrototypeAI.Pick(selector: "div", tag: "div", text: "t", html: "<div/>", screen: "#/orders", component: "src/Badge.vue")
    let revise = PrototypeAI.revisePrompt(instruction: "x", pick: pick, siteRelative: "site", files: [], runtimeErrors: [], priorFailure: nil, mode: .code)
    check(revise.contains("html: <div/>\nsource component: src/Badge.vue (the element"), "revise prompt names the picked element's component")
    var plain = pick
    plain.component = nil
    check(!PrototypeAI.revisePrompt(instruction: "x", pick: plain, siteRelative: "site", files: [], runtimeErrors: [], priorFailure: nil)
            .contains("source component"), "no component, no component line")
}

// BUG-051: a request for many files is revised file by file.
do {
    // `applying` is `apply` without the disk: the same rules, the same exactly-once edits, nothing written.
    let state = ["a.js": "one two", "b.js": "x"]
    let ok = try? PrototypeFiles.applying(.init(files: [.init(path: "c.css", content: "c")], edits: [.init(path: "a.js", find: "one", replace: "1")],
                                                deletes: ["b.js"]), to: state)
    check(ok?.state == ["a.js": "1 two", "c.css": "c"] && ok?.touched == ["a.js", "c.css"] && ok?.removed == ["b.js"], "applying patches, adds and deletes in memory")
    check(state == ["a.js": "one two", "b.js": "x"], "applying leaves its input alone")
    do {
        _ = try PrototypeFiles.applying(.init(edits: [.init(path: "a.js", find: "o", replace: "0")]), to: state)
        check(false, "an edit whose text occurs twice is refused in memory")
    } catch let error as PrototypeFiles.Failure {
        check(error.localizedDescription.contains("occurs 2 times"), "an edit whose text occurs twice is refused in memory")
    } catch { check(false, "unexpected error \(error)") }
    do {
        _ = try PrototypeFiles.applying(.init(files: [.init(path: "../x.js", content: "")]), to: state)
        check(false, "a path outside the site is refused in memory")
    } catch { check(true, "a path outside the site is refused in memory") }

    // The files a first answer leaves in `remaining`: existing, not changed by the answer itself, once each, the prototype folder stripped.
    let targets = PrototypeAI.sweepTargets(["a.js", " b.js ", "a.js", "p/site/c.css", "ghost.js", "../d.js", "e.js", 7] as [Any],
                                           siteRelative: "p/site", existing: ["a.js", "b.js", "c.css", "e.js"], touched: ["e.js"])
    check(targets == ["a.js", "b.js", "c.css"], "sweep targets: existing files once each, in order: \(targets)")
    check(PrototypeAI.sweepTargets(nil, siteRelative: "p", existing: ["a"], touched: []).isEmpty
          && PrototypeAI.sweepTargets("a.js", siteRelative: "p", existing: ["a.js"], touched: []).isEmpty, "no list, no targets")
    let file = PrototypeFiles.File(path: "screens/x.js", content: "const t = 'Привет';")
    let one = PrototypeAI.sweepPrompt(instruction: "Translate", siteRelative: "p/site", file: file, priorFailure: nil)
    check(one.contains("this run revises one file of it, `screens/x.js`") && one.contains("=== screens/x.js ===\nconst t = 'Привет';\n")
          && one.hasSuffix("Reviewer's request:\nTranslate") && !one.contains("could not be applied"), "sweep prompt names the file and carries it whole")
    check(PrototypeAI.sweepPrompt(instruction: "T", siteRelative: "p", file: file, priorFailure: "x: bad").contains("Your previous answer could not be applied:\nx: bad"),
          "sweep prompt carries the reason of a failed answer")
    // The reply to an empty answer is not the edits advice, and the default retry text is unchanged.
    let empty = PrototypeAI.revisePrompt(instruction: "x", pick: nil, siteRelative: "site", files: [], runtimeErrors: [], priorFailure: "no summary.", priorEmpty: true)
    check(empty.contains("Your previous answer was empty: no summary.") && !empty.contains("`find` text"), "retry text of an empty answer")
    check(PrototypeAI.reviseSchema["required"] as? [String] == ["summary", "screens", "files", "edits", "delete", "remaining"], "the schema requires remaining")
}

// BUG-052: a prototype made from code keeps the labels of the original and is not translated.
do {
    let rule = PrototypeAI.sourceLanguageRule
    check(PrototypeAI.languageNote(explicit: "", mode: .code) == rule, "code mode on Document language gets the keep-the-source-language rule")
    check(PrototypeAI.languageNote(explicit: "", mode: .requirements).isEmpty, "requirements mode on Document language gets nothing")
    // BUG-057: the global output language (Russian in Boris's settings) must not translate the labels of a reconstruction.
    let explicit = "\n\nWrite every label, text and message in the prototype in Russian."
    check(PrototypeAI.languageNote(explicit: explicit, mode: .code) == rule, "an explicit output language does not replace the rule in code mode")
    check(PrototypeAI.languageNote(explicit: explicit, mode: .requirements) == explicit, "an explicit output language still applies to a requirements prototype")
    check(!PrototypeAI.languageNote(explicit: explicit, mode: .code).contains("Russian"), "the code-mode note never carries the chosen language")
    check(rule.hasPrefix("\n\n") && rule.contains("never translate them") && rule.contains("`lang` attribute of index.html")
          && rule.contains("`summary`, `assumptions`, `gaps`") && rule.contains("asks for another language overrides"),
          "the rule says what to copy, the lang attribute, the English summaries and that the reviewer can override it")
    // It reaches every prompt that writes visible text or saved prose: plan, foundation, screens, components and revisions.
    let note = PrototypeAI.languageNote(explicit: "", mode: .code)
    let prompts: [(String, String)] = [
        ("code plan", PrototypeAI.codePlanSystem(language: note)), ("data", PrototypeAI.dataSystem(language: note)),
        ("shell", PrototypeAI.shellSystem(language: note)), ("screen", PrototypeAI.screenSystem(language: note)),
        ("component", PrototypeAI.componentSystem(language: note)), ("revise", PrototypeAI.reviseSystem(language: note)),
    ]
    for (name, text) in prompts { check(text.hasSuffix(rule), "the \(name) prompt ends with the language rule") }
    // Without a note the prompts are what they were (the pinned digests above stay valid).
    check(PrototypeAI.screenSystem(language: PrototypeAI.languageNote(explicit: "", mode: .requirements)) == PrototypeAI.screenSystem(language: ""),
          "a requirements prototype's prompts are unchanged")
}

// BUG-053: a stub or blank screen is not accepted and the preview audit reports what it finds.
do {
    // The stub of the strikedesk Settings screen: only a comment, 255 bytes, no App.register.
    let comment = "/* Экран настроек не реализован: требуется полностью изучить дочерние формы, их зависимости и правила сохранения. */"
    check(PrototypeAudit.stubProblem(id: "settings", content: comment) == "the file has no code, only comments or nothing", "a comment-only file is a stub")
    check(PrototypeAudit.stubProblem(id: "settings", content: "") != nil && PrototypeAudit.stubProblem(id: "settings", content: "  \n ") != nil,
          "an empty file is a stub")
    check(PrototypeAudit.stubProblem(id: "x", content: "const a = 1; // App.register({id: 'x', render() {}})")?.contains("never calls App.register") == true,
          "App.register inside a comment does not count")
    check(PrototypeAudit.stubProblem(id: "x", content: "App.register({id: 'x', route: '/x'});")?.contains("no render function") == true,
          "a screen without render is refused")
    check(PrototypeAudit.stubProblem(id: "x", content: "App.register({id: 'x', render() { return 'Not implemented yet'; }});")?.contains("placeholder") == true,
          "a short screen whose text says it is not implemented is a placeholder")
    check(PrototypeAudit.stubProblem(id: "x", content: "App.register({id: 'x', render() { return 'TODO'; }});") != nil, "TODO is a placeholder")
    check(PrototypeAudit.stubProblem(id: "home", content: "App.register({id: 'home', render() { return 'Home'; }});") == nil,
          "a short but real screen passes")
    let long = "App.register({id: 'big', render() { return '<input placeholder=\"Search\">' + " + String(repeating: "'<p>row</p>' + ", count: 40) + "''; }});"
    check(long.count > PrototypeAudit.placeholderLimit && PrototypeAudit.stubProblem(id: "big", content: long) == nil,
          "the word placeholder in a long screen is an attribute, not a stub")
    check(PrototypeAudit.stubProblem(id: "x", content: "// TODO later\nApp.register({id: 'x', render() { return 'Orders'; }});") == nil,
          "a TODO in a comment does not make a screen a stub")
    check(PrototypeAudit.withoutComments("a = 'http://x.y'; // c\nb = \"/* not a comment */\"; /* gone */ c") == "a = 'http://x.y'; \nb = \"/* not a comment */\";   c",
          "comments are removed and strings are kept")

    // The report the page posts.
    let payload: [String: Any] = ["checked": 5, "skipped": 1, "problems": [
        ["id": "trade", "name": "Trade", "route": "/widgets/trade", "kind": "blank", "sample": ""],
        ["id": "settings", "name": "Settings", "route": "/settings", "kind": "error", "sample": "Не удалось загрузить данные."],
        ["id": "bad", "name": "Bad", "route": "/bad", "kind": "nonsense", "sample": ""]]]
    let report = PrototypeAudit.report(from: payload)
    check(report?.checked == 5 && report?.findings.map(\.id) == ["trade", "settings"], "unknown kinds are dropped: \(String(describing: report))")
    check(PrototypeAudit.report(from: ["error": "boom"]) == nil && PrototypeAudit.report(from: "text") == nil, "an error payload is no report")
    let blank = PrototypeAudit.message(for: report!.findings[0])
    check(blank.hasPrefix("Screen \"Trade\" (#/widgets/trade, screens/trade.js) renders nothing") && blank.contains("callback of App.load"), blank)
    check(PrototypeAudit.message(for: report!.findings[1]).contains("error card (\"Не удалось загрузить данные.\")"), "the error card message quotes the card")
    check(PrototypeAudit.message(for: PrototypeAudit.Finding(id: "a", name: "", route: "/a", kind: .loading, sample: "")).hasPrefix("Screen \"a\""),
          "a screen without a name is named by its id")
    check(PrototypeAudit.script.contains("window.__mvAudit") && PrototypeAudit.script.contains("App.plan") && PrototypeAudit.script.contains("/modals/"),
          "the script defines __mvAudit over App.plan and skips modal routes")
    // BUG-056: a screen whose content is in the page but clipped to zero height.
    let clipPayload: [String: Any] = ["checked": 2, "skipped": 0, "problems": [
        ["id": "option-desk", "name": "Option desk", "route": "/widgets/option-desk", "kind": "clipped", "sample": "Calls",
         "detail": "div.sd-option-desk__surface 0px < div.sd-option-desk 88px < div 88px < main#app-main 141px"]]]
    let clipReport = PrototypeAudit.report(from: clipPayload)
    check(clipReport?.findings.first?.kind == .clipped && clipReport?.findings.first?.detail.hasPrefix("div.sd-option-desk__surface 0px") == true,
          "the clipped kind and its heights are read from the report: \(String(describing: clipReport))")
    let clipped = PrototypeAudit.message(for: clipReport!.findings[0])
    check(clipped.hasPrefix("Screen \"Option desk\" (#/widgets/option-desk, screens/option-desk.js) has content that is in the page but cannot be seen")
          && clipped.contains("(\"Calls\")") && clipped.contains("div.sd-option-desk__surface 0px < div.sd-option-desk 88px")
          && clipped.contains("definite height") && clipped.contains("Keep the content"), clipped)
    check(!PrototypeAudit.message(for: PrototypeAudit.Finding(id: "a", name: "A", route: "/a", kind: .clipped, sample: "")).contains("Heights from"),
          "a clipped finding without heights does not print an empty list")
    check(PrototypeAudit.report(from: ["checked": 1, "problems": [["id": "x", "kind": "clipped", "detail": String(repeating: "x", count: 900)]]])?
        .findings.first?.detail.count == 300, "the heights are capped at 300 characters")
    check(PrototypeAudit.script.contains("function collapsed(") && PrototypeAudit.script.contains("kind = 'clipped'"),
          "the script measures collapsed boxes and reports clipped screens")
    // The shell and host rules for widgets that size themselves with flex:1 or height:100%.
    check(PrototypeAI.embeddedShellContract.contains("always has a definite height") && PrototypeAI.embeddedShellContract.contains("collapses to 0 px"),
          "the embedded shell contract demands a definite height for the box that holds a widget")
    let hostPrompt = PrototypeAI.screenPrompt(plan: "{}", screen: PrototypeAI.PlannedScreen(id: "desk", name: "Desk", route: "/", purpose: "", embedded: false),
                                              foundation: [], failure: nil, mode: .code, hosted: [PrototypeAI.PlannedScreen(id: "w", name: "W", route: "/w", purpose: "", embedded: true)])
    check(hostPrompt.contains("Give every panel that receives a widget a definite height"), "the host prompt asks for panels with a definite height")
    // The screen prompt tells the writer what made the strikedesk Trade screen blank.
    check(PrototypeAI.screenSystem(language: "").contains("never the container that `App.load` returned"), "the screen prompt carries the App.load rule")
}

// REQ-008: the target of a request.
do {
    let screen = PrototypeAI.Target.screen(id: "trade", name: "Trade")
    let component = PrototypeAI.Target.component(path: "src/Badge.tsx", label: "Badge", page: "components/src-badge-tsx.html", screens: ["Trade", "Orders"])
    check(screen.kind == "Screen" && screen.name == "Trade" && screen.detail == nil, "a screen target has a kind and a name")
    check(component.kind == "Component" && component.name == "Badge" && component.detail == "src/Badge.tsx", "a component target shows its source path")
    func prompt(_ target: PrototypeAI.Target?, mode: PrototypeFiles.Mode = .code) -> String {
        PrototypeAI.revisePrompt(instruction: "Bigger", pick: nil, siteRelative: "docs/prototypes/x/site", files: [], runtimeErrors: [],
                                 priorFailure: nil, mode: mode, target: target)
    }
    let aimedScreen = prompt(screen)
    check(aimedScreen.contains("aimed this request at one screen: \"Trade\", implemented in `docs/prototypes/x/site/screens/trade.js`")
          && aimedScreen.contains("Limit the change to that screen's script") && aimedScreen.hasSuffix("Reviewer's request:\nBigger"),
          "a screen target names the file and limits the change, before the request")
    let aimedComponent = prompt(component)
    check(aimedComponent.contains("`src/Badge.tsx`") && aimedComponent.contains("data-mv-component=\"src/Badge.tsx\"")
          && aimedComponent.contains("in the screens \"Trade\", \"Orders\"") && aimedComponent.contains("docs/prototypes/x/site/components/src-badge-tsx.html")
          && aimedComponent.contains("nothing else unless the request says otherwise") && aimedComponent.contains("read it when the request touches"),
          "a component target names the source, the markers, the screens and the isolated view")
    check(!prompt(PrototypeAI.Target.component(path: "src/Badge.tsx", label: "Badge", page: nil, screens: []), mode: .requirements).contains("Its source file")
          && !prompt(PrototypeAI.Target.component(path: "src/Badge.tsx", label: "Badge", page: nil, screens: [])).contains("isolated view"),
          "without a page there is no isolated view; a requirements prototype has no source file to read")
    check(!prompt(nil).contains("aimed this request"), "no target, no scope paragraph: the request is about the whole prototype")
    check(prompt(nil) == PrototypeAI.revisePrompt(instruction: "Bigger", pick: nil, siteRelative: "docs/prototypes/x/site", files: [], runtimeErrors: [], priorFailure: nil, mode: .code),
          "the prompt without a target is what it was before targets existed")
}

// REQ-010: the update note of a screen rebuilt after a code change.
do {
    let screen = PrototypeAI.PlannedScreen(id: "orders", name: "Orders", route: "/orders", purpose: "", evidence: ["src/a.ts"], components: [], embedded: false, hosts: [])
    let update = PrototypeAI.ScreenUpdate(changed: ["src/a.ts"], removed: ["src/gone.ts"], current: "docs/prototypes/x/site/screens/orders.js")
    let withUpdate = PrototypeAI.screenPrompt(plan: "{}", screen: screen, foundation: [], failure: nil, mode: .code, update: update)
    check(withUpdate.contains("UPDATE of a screen that already exists") && withUpdate.contains("read them first:\n- src/a.ts\n")
          && withUpdate.contains("no longer exist; drop what depended only on them:\n- src/gone.ts\n")
          && withUpdate.contains("`docs/prototypes/x/site/screens/orders.js`") && withUpdate.contains("not a patch")
          && withUpdate.contains("define it inside this screen's script"), "the update note names the changed and removed files, the current screen and the data rule")
    check(!PrototypeAI.screenPrompt(plan: "{}", screen: screen, foundation: [], failure: nil, mode: .code).contains("UPDATE of a screen"), "a first build has no update note")
    check(!PrototypeAI.screenPrompt(plan: "{}", screen: screen, foundation: [], failure: nil, mode: .requirements, update: update).contains("UPDATE of a screen"),
          "requirements mode has nothing to update from")
}

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
