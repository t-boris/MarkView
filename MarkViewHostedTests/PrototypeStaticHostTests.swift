import Foundation
import JavaScriptCore
import XCTest
import MarkViewCore
@testable import MarkView

final class PrototypeStaticHostTests: XCTestCase {
    @MainActor func testEmbedded() throws {
var failures = 0
var checks = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    checks += 1
    if !ok { failures += 1 }
}

func screen(_ id: String, route: String? = nil, embedded: Bool = false, hosts: [String] = [], evidence: [String] = [],
            components: [String] = []) -> PrototypeAI.PlannedScreen {
    PrototypeAI.PlannedScreen(id: id, name: id.capitalized, route: route ?? "/" + id, purpose: "", evidence: evidence,
                              components: components, embedded: embedded, hosts: hosts)
}

// MARK: - Shell and styles contracts

do {
    let plain = PrototypePrompts.shellSystem(language: "")
    let widgets = PrototypePrompts.shellSystem(language: "", widgets: true)
    check(!plain.contains("renderScreen") && !plain.contains("embedded"), "a plan without widgets gets the shell prompt it always had")
    for phrase in ["`App.renderScreen(id, extra)`", "`embedded: true`", "`hosts`", "exactly one such screen exists", "no navigation list",
                   "never throws", "without `App.start()`", "accepts an element or an HTML string as `body`", "Visiting the route of an embedded screen"] {
        check(widgets.contains(phrase), "the widget shell prompt says: \(phrase)")
    }
    check(widgets.hasPrefix(plain.components(separatedBy: "Keep app.js under 60 KB").first ?? "?"), "the widget paragraph is added, nothing else changes before it")

    let design = PrototypePrompts.stylesSystem(language: "")
    let bridge = PrototypePrompts.stylesSystem(language: "", originals: true)
    check(design.contains("design tokens as CSS variables") && !design.contains("small bridge"), "without original styles styles.css is still a design system")
    for phrase in ["small bridge", "already copied into the prototype", "Do not write a design system", "`var(--…)`", "under 8 KB", "`app-header`"] {
        check(bridge.contains(phrase), "the bridge prompt says: \(phrase)")
    }
}

// MARK: - Screen prompts and effort

do {
    let host = screen("workspace", hosts: ["order-list", "settings"], evidence: ["src/Shell.tsx"])
    let widget = screen("order-list", route: "/widgets/order-list", embedded: true, evidence: ["src/OrderList.tsx"], components: ["src/OrderList.tsx"])
    let modal = screen("settings", route: "/modals/settings", embedded: true, evidence: ["src/Settings.tsx"])
    let page = screen("about", evidence: ["src/About.tsx"])
    check([host, widget, modal].allSatisfy { PrototypePrompts.screenEffort($0) == "medium" } && PrototypePrompts.screenEffort(page) == "low",
          "hosts, widgets and modals run at medium effort, an ordinary page at low")
    let large = PrototypePrompts.largeSourceBytes
    check([host, widget, modal].allSatisfy { PrototypePrompts.screenEffort($0, sourceBytes: large - 1) == "medium" && PrototypePrompts.screenEffort($0, sourceBytes: large) == "high" },
          "a host, widget or modal whose evidence is \(large) bytes or more runs at high effort (BUG-059)")
    check(PrototypePrompts.screenEffort(page, sourceBytes: 10 * large) == "low", "an ordinary page stays at low effort however large its source is")
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("effort-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? Data(count: 30_000).write(to: folder.appendingPathComponent("src/OrderList.tsx"))
        try? Data(count: 15_000).write(to: folder.appendingPathComponent("src/Extra.tsx"))
        let sized = screen("order-list", embedded: true, evidence: ["src/OrderList.tsx", "src/Extra.tsx", "src/Gone.tsx"])
        check(PrototypePrompts.evidenceBytes(sized, root: folder) == 45_000, "the evidence size adds up the files that exist and counts a missing one as nothing")
        check(PrototypePrompts.evidenceBytes(screen("about"), root: folder) == 0, "a screen without evidence has no size")
    }
    check(PrototypePrompts.isModal(modal) && !PrototypePrompts.isModal(widget) && !PrototypePrompts.isModal(host), "a modal is told by its route")

    func prompt(_ s: PrototypeAI.PlannedScreen, hosted: [PrototypeAI.PlannedScreen] = [], mode: PrototypeFiles.Mode = .code) -> String {
        PrototypePrompts.screenPrompt(plan: "{}", screen: s, foundation: [], failure: nil, mode: mode, originalStyles: ["a.css"], hosted: hosted)
    }
    let widgetPrompt = prompt(widget)
    for phrase in ["a widget rendered inside another screen", "`App.renderScreen('order-list')` in the host's panel", "register it with `embedded: true`",
                   "no page header", "Read the whole source file with your tools, not an excerpt", "every file of the same widget that it imports",
                   "- src/OrderList.tsx"] {
        check(widgetPrompt.contains(phrase), "the widget prompt says: \(phrase)")
    }
    check(!widgetPrompt.contains("HOST of the window"), "a widget is not told it is a host")
    check(prompt(modal).contains("a modal rendered inside another screen") && prompt(modal).contains("in the host's dialog"), "the modal prompt says dialog")
    let hostPrompt = prompt(host, hosted: [widget, modal])
    for phrase in ["HOST of the window", "- order-list — Order-List (/widgets/order-list)", "- settings — Settings (/modals/settings)",
                   "`App.renderScreen(id)` for each", "A docking library of the original is not available", "Do not re-implement a widget",
                   "`App.modal({title, body: App.renderScreen(id)})`", "registers with `embedded: false`"] {
        check(hostPrompt.contains(phrase), "the host prompt says: \(phrase)")
    }
    check(!prompt(page).contains("rendered inside another screen") && !prompt(page).contains("HOST of the window"), "an ordinary page gets neither")
    check(!prompt(widget, mode: .requirements).contains("rendered inside another screen"), "requirements mode never does")
}

// MARK: - The isolated page

do {
    let html = PrototypeEmbedded.page(screenID: "order-list", name: "Order <list> & \"co\"", componentPath: "src/Order \"List\".tsx",
                                      links: ["original/theme/vars.css", "original/my styles/a.css"])
    check(html.hasPrefix("<!doctype html>") && html.contains("<meta charset=\"utf-8\">") && html.contains("name=\"viewport\""), "a complete document")
    check(html.contains("<link rel=\"stylesheet\" href=\"../original/theme/vars.css\">\n<link rel=\"stylesheet\" href=\"../original/my%20styles/a.css\">\n<link rel=\"stylesheet\" href=\"../styles.css\">"),
          "the original stylesheets come first, one level up, before styles.css")
    let order = ["../data.js", "../app.js", "../screens/order-list.js", "App.renderScreen(\"order-list\")"].compactMap { html.range(of: $0)?.lowerBound }
    check(order.count == 4 && order == order.sorted(), "data, shell, the screen, then the mount")
    check(html.contains("<title>Order &lt;list&gt; &amp; &quot;co&quot; · src/Order &quot;List&quot;.tsx</title>")
          && html.contains("data-mv-component=\"src/Order &quot;List&quot;.tsx\""), "name and path are escaped")
    check(!html.contains("App.start()"), "the page never starts the shell")
    let hostile = PrototypeEmbedded.page(screenID: "x\"</script><b>", name: "n", componentPath: "p.tsx", links: [])
    check(hostile.contains("App.renderScreen(\"x\\\"<\\/script><b>\")") && !hostile.contains("</script><b>"), "an odd id cannot close the script")
    check(PrototypeEmbedded.page(screenID: "a", name: "n", componentPath: "p.tsx", links: []).contains("<link rel=\"stylesheet\" href=\"../styles.css\">\n</head>"),
          "no original styles, only styles.css")

    // It lands where the component scan expects an isolated page and is a path the writer may use.
    let site = FileManager.default.temporaryDirectory.appendingPathComponent("mv-embedded-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: site) }
    try FileManager.default.createDirectory(at: site.appendingPathComponent("screens"), withIntermediateDirectories: true)
    try "App.register({id:'a', render(){ return '<div data-mv-component=\"src/A.tsx\"></div>'; }});".write(to: site.appendingPathComponent("screens/a.js"), atomically: true, encoding: .utf8)
    let wanted = PrototypeFiles.componentPage(for: "src/A.tsx")
    _ = try PrototypeFiles.apply(PrototypeFiles.Change(files: [PrototypeFiles.File(path: wanted, content: PrototypeEmbedded.page(screenID: "a", name: "A", componentPath: "src/A.tsx", links: []))]), to: site)
    let found = PrototypeFiles.components(in: site, screens: [PrototypeFiles.ScreenRef(id: "a", name: "A")])
    check(found.count == 1 && found[0].path == "src/A.tsx" && found[0].page == wanted && found[0].screens == ["A"], "the component scan links the page: \(found)")
}

// MARK: - Coverage

do {
    func entry(_ path: String, _ bytes: Int) -> PrototypeFiles.InventoryEntry { .init(path: path, bytes: bytes) }
    let inventory = PrototypeFiles.Inventory(entries: [
        entry("src/Big.tsx", 14_000), entry("src/Mid.tsx", 6_000), entry("src/Small.ts", 2_048), entry("src/Tiny.tsx", 2_047),
        entry("src/a.css", 90_000), entry("src/data.json", 50_000), entry("src/page.html", 3_000), entry("src/util.js", 9_000),
    ])
    let screens = [screen("one", evidence: ["./src/Big.tsx", " src/page.html "], components: ["src/Mid.tsx"]), screen("two", evidence: ["src/missing.tsx"])]
    let cov = PrototypeEmbedded.coverage(inventory: inventory, screens: screens, read: ["src/util.js", "node_modules/x/index.js"])
    check(cov?.total == 5 && cov?.covered == 4, "UI source files of 2 KB or more only (css, json and tiny files are not counted): \(String(describing: cov))")
    check(cov?.uncovered.map(\.path) == ["src/Small.ts"] && cov?.coveredBytes == 32_000 && cov?.totalBytes == 34_048,
          "evidence, components and reads count, './' and spaces are ignored")
    check(cov?.percent == 80, "percent")
    check(cov?.sentence == "Coverage: the build named or read 4 of 5 UI source files of 2 KB or more (80%, 32 KB of 34 KB). Not covered, largest first: src/Small.ts (2 KB).",
          "the sentence: \(cov?.sentence ?? "nil")")

    var many: [PrototypeFiles.InventoryEntry] = []
    for n in 0..<12 { many.append(entry(String(format: "src/F%02d.tsx", n), 3_000 + n * 100)) }
    many.append(entry("src/Same.tsx", 3_000))
    let none = PrototypeEmbedded.coverage(inventory: PrototypeFiles.Inventory(entries: many), screens: [], read: [])
    check(none?.covered == 0 && none?.uncovered.first?.path == "src/F11.tsx" && none?.uncovered.last?.path == "src/Same.tsx"
          && none?.uncovered.dropLast().last?.path == "src/F00.tsx", "uncovered files are listed largest first, equal sizes by path")
    check(none?.sentence.contains("(src/F11.tsx (4 KB)") == false && none?.sentence.hasSuffix(", and 5 more.") == true
          && none?.sentence.contains("src/F04.tsx") == true && none?.sentence.contains("src/F03.tsx") == false, "eight files are named, the rest counted: \(none?.sentence ?? "nil")")
    check(PrototypeEmbedded.coverage(inventory: PrototypeFiles.Inventory(entries: [entry("a.css", 9_999), entry("b.tsx", 100)]), screens: [], read: []) == nil,
          "nothing to measure, no figure")
    check(PrototypeEmbedded.normalised("/proj/src/a.tsx", root: "/proj") == "src/a.tsx" && PrototypeEmbedded.normalised(" ./src/a.tsx ") == "src/a.tsx",
          "paths are normalised")
}

// MARK: - The read log

do {
    let log = PrototypeEmbedded.ReadLog()
    DispatchQueue.concurrentPerform(iterations: 400) { n in log.add("src/f\(n % 100).tsx") }
    check(log.all.count == 100, "the log is safe to share between side-by-side runs")

    let seen = PrototypeEmbedded.ReadLog()
    let tracker = PrototypeProgressTracker(root: URL(fileURLWithPath: "/proj"), reading: "the code", onRead: { seen.add($0) }, emit: { _ in })
    tracker.handle(.read("/proj/src/Widget.tsx"))
    tracker.handle(.read("/elsewhere/x.ts"))
    tracker.handle(.search("q"))
    check(seen.all == ["src/Widget.tsx", "/elsewhere/x.ts"], "the tracker reports what the assistant read, relative to the project: \(seen.all.sorted())")
}

        print("PrototypeEmbeddedTests hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
    @MainActor func testShellStructure() throws {
var failures = 0
var checks = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    checks += 1
    if !ok { failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mv-structure-tests-" + UUID().uuidString)
defer { try? fm.removeItem(at: work) }

func put(_ root: URL, _ path: String, _ content: String) throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

func text(_ root: URL, _ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

let shell = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <link rel="stylesheet" href="original/theme/variables.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <div id="app"></div>
  <script src="app.js"></script>
</body>
</html>
"""

// MARK: - The stylesheet

do {
    let rules = PrototypeShellStructure.css
        .replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    check(!rules.isEmpty && rules.allSatisfy { $0.hasPrefix(":where(") }, "every rule has zero specificity (:where), so any stylesheet overrides it")
    for selector in ["html, body", "body", "#app", ".app-main", ".app-main-single", ".app-screen-fill", ".app-load"] {
        check(rules.contains { $0.hasPrefix(":where(\(selector))") }, "a rule for \(selector)")
    }
    check(rules.contains { $0.hasPrefix(":where(html, body)") && $0.contains("height: 100%") }, "the page has a definite height")
    check(rules.contains { $0.hasPrefix(":where(#app)") && $0.contains("flex-direction: column") && $0.contains("height: 100%") }, "#app is a flex column as tall as the page")
    check(rules.contains { $0.hasPrefix(":where(.app-main)") && $0.contains("flex: 1 1 auto") && $0.contains("min-height: 0") }, "app-main takes the rest, with min-height 0")
    check(PrototypeShellStructure.href == "markview/structure.css", "the stylesheet lives in the folder MarkView owns")
}

// MARK: - The link

do {
    check(!PrototypeShellStructure.isLinked(shell), "a shell without the link is not linked")
    let linked = PrototypeShellStructure.linked(shell)
    check(linked != nil && PrototypeShellStructure.isLinked(linked!), "linked() links it")
    check(linked.map { $0.contains("<link rel=\"stylesheet\" href=\"markview/structure.css\">\n<link rel=\"stylesheet\" href=\"styles.css\">") } == true,
          "the link goes right before the shell's own stylesheet, after the originals")
    check(linked.map { PrototypeShellStructure.linked($0) == $0 } == true, "linking twice changes nothing")
    check(linked.map { PrototypeShellStructure.authored($0) == shell } == true, "authored() gives back the shell exactly as written")
    check(PrototypeShellStructure.authored(shell) == shell, "authored() leaves a shell without the link alone")
    let headOnly = "<html><head><title>x</title></head><body></body></html>"
    check(PrototypeShellStructure.linked(headOnly).map { $0.contains("markview/structure.css") && $0.range(of: "</head>") != nil } == true,
          "a head without a styles.css link gets it before </head>")
    check(PrototypeShellStructure.linked("<div></div>") == nil, "a page with neither place cannot be linked")
}

// MARK: - A site

do {
    let site = work.appendingPathComponent("site")
    try fm.createDirectory(at: site, withIntermediateDirectories: true)
    check(!PrototypeShellStructure.needsApplying(site: site), "no index.html: nothing to apply")
    check((try? PrototypeShellStructure.ensure(site: site)) == .unlinkable, "no index.html: unlinkable")

    try put(site, "index.html", shell)
    try put(site, "styles.css", ".app-main{flex:1}")
    check(PrototypeShellStructure.needsApplying(site: site), "a shell without the structure needs it")
    check((try? PrototypeShellStructure.ensure(site: site)) == .applied, "ensure applies it")
    check(text(site, "markview/structure.css") == PrototypeShellStructure.css, "the stylesheet is written")
    check(text(site, "index.html").map(PrototypeShellStructure.isLinked) == true, "index.html links it")
    check(text(site, "styles.css") == ".app-main{flex:1}", "the assistant's styles.css is untouched")
    check(!PrototypeShellStructure.needsApplying(site: site), "a shell with the structure does not need it")
    check((try? PrototypeShellStructure.ensure(site: site)) == .current, "ensure is idempotent")

    try put(site, "markview/structure.css", "/* edited */")
    check(PrototypeShellStructure.needsApplying(site: site), "an out-of-date copy needs it")
    check((try? PrototypeShellStructure.ensure(site: site)) == .applied && text(site, "markview/structure.css") == PrototypeShellStructure.css,
          "ensure writes it again")

    let dropped = work.appendingPathComponent("dropped")
    try fm.createDirectory(at: dropped, withIntermediateDirectories: true)
    try put(dropped, "index.html", shell)
    try PrototypeShellStructure.ensure(site: dropped)
    try put(dropped, "index.html", shell)   // a revision rewrote index.html without the link
    check(PrototypeShellStructure.needsApplying(site: dropped), "a revision that dropped the link needs it again")
    check((try? PrototypeShellStructure.ensure(site: dropped)) == .applied && text(dropped, "index.html").map(PrototypeShellStructure.isLinked) == true,
          "and gets it back")
}

// MARK: - Owned by MarkView, not by the assistant

do {
    let site = work.appendingPathComponent("owned")
    try fm.createDirectory(at: site, withIntermediateDirectories: true)
    try put(site, "index.html", shell)
    try put(site, "styles.css", "body{}")
    try PrototypeShellStructure.ensure(site: site)
    check(!PrototypeFiles.read(site: site).contains { $0.path.hasPrefix("markview/") }, "the assistant does not read the folder")
    check(PrototypeFiles.read(site: site).map(\.path) == ["index.html", "styles.css"], "its files are only the author's")
    check((try? PrototypeFiles.validate(path: "markview/structure.css")) == nil, "the assistant cannot write to it")
    check((try? PrototypeFiles.validate(path: "original/a.css")) == nil, "nor to original/")
    check((try? PrototypeFiles.validate(path: "screens/markview.js")) != nil, "a screen that merely has the name is fine")

    // Adding the structure is not an edit of the shell: the fingerprints do not move.
    let bare = work.appendingPathComponent("bare")
    try fm.createDirectory(at: bare, withIntermediateDirectories: true)
    try put(bare, "index.html", shell)
    try put(bare, "styles.css", "body{}")
    let before = PrototypeBaseline.siteFingerprints(site: bare)
    try PrototypeShellStructure.ensure(site: bare)
    check(PrototypeBaseline.siteFingerprints(site: bare) == before, "linking the structure does not change a fingerprint")
    try put(bare, "index.html", (text(bare, "index.html") ?? "") + "<!-- edited -->")
    check(PrototypeBaseline.siteFingerprints(site: bare)["index.html"] != before["index.html"], "a real edit of index.html still does")
}

// MARK: - What the writers are told

do {
    let contract = PrototypeShellStructure.contract
    for phrase in [PrototypeShellStructure.href, "`html`, `body` and `#app`", "`app-main`", "`app-main-single`", "`app-screen-fill`", "`app-load`", "zero specificity"] {
        check(contract.contains(phrase), "the contract says: \(phrase)")
    }
    check(PrototypePrompts.shellSystem(language: "", ownsStructure: true).contains(contract), "the shell prompt of a prototype from code carries it")
    check(PrototypePrompts.stylesSystem(language: "", ownsStructure: true).contains(contract), "the styles prompt carries it")
    check(PrototypePrompts.stylesSystem(language: "", originals: true, ownsStructure: true).contains(contract), "so does the bridge prompt")
    check(!PrototypePrompts.shellSystem(language: "").contains(PrototypeShellStructure.href)
          && !PrototypePrompts.stylesSystem(language: "").contains(PrototypeShellStructure.href)
          && !PrototypePrompts.stylesSystem(language: "", originals: true).contains(PrototypeShellStructure.href),
          "a prompt that does not ask for it says nothing about it")
    check(PrototypePrompts.shellSystem(language: "", widgets: true).contains("panel body"), "the widget contract still tells hosts to give a widget a box")
}

        print("PrototypeShellStructureTests hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
    @MainActor func testTailwind() throws {
var failures = 0
var checks = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    checks += 1
    if !ok { failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mv-tailwind-tests-" + UUID().uuidString)
defer { try? fm.removeItem(at: work) }

func put(_ root: URL, _ path: String, _ content: String) throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}
func text(_ root: URL, _ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

// The entry stylesheet of the vivaa client-web-app, condensed: what its first lines and rule kinds look like.
let globals = """
@import "tailwindcss";
@import "./base-elements.css";

@source '../../../packages/ui/src/**/*.{ts,tsx}';

@theme {
  --color-canvas: var(--vivaa-bg-canvas);
  --spacing-sp10: 40px;
}

@layer base {
  body { font-family: "Inter", sans-serif; }
}

@utility font-serif-display {
  font-family: "Fraunces", serif;
}
"""

// MARK: - Which stylesheets are Tailwind

check(PrototypeTailwind.isEntry(globals), "an entry that imports tailwindcss is found")
check(PrototypeTailwind.isEntry("@import 'tailwindcss/theme.css' layer(theme);"), "a single-quoted import of a Tailwind part is found")
check(PrototypeTailwind.isEntry("@import url(\"tailwindcss\");"), "an import written with url() is found")
check(!PrototypeTailwind.isEntry("@import \"./base-elements.css\";\nbody { color: red; }"), "a plain stylesheet is not an entry")
check(!PrototypeTailwind.isEntry("/* @import \"tailwind-like.css\" */ .a { color: red }"), "a name that only starts like Tailwind is not")

// MARK: - What the browser build can read

let ready = PrototypeTailwind.browserReady(globals, keepingTailwind: true)
check(ready.contains("@import \"tailwindcss\";"), "the Tailwind import stays in the first entry")
check(!ready.contains("base-elements") && !ready.contains("@source"), "the local import and @source are removed: \(ready.prefix(80))")
check(ready.contains("@theme {") && ready.contains("--spacing-sp10: 40px;") && ready.contains("@layer base {") && ready.contains("@utility font-serif-display {"),
      "the theme, layers and utilities are untouched")
let more = PrototypeTailwind.browserReady("@plugin \"./plugin.js\";\n@config \"./tailwind.config.js\";\n@import \"tailwindcss\";\n.a { color: red }", keepingTailwind: false)
check(!more.contains("@plugin") && !more.contains("@config") && !more.contains("tailwindcss"), "@plugin, @config and a repeated Tailwind import are removed: \(more)")
check(more.contains(".a { color: red }"), "the rules stay")

check(PrototypeTailwind.source(from: ["body { margin: 0 }", "@import \"./x.css\";"]) == nil, "no entry, no source")
let two = PrototypeTailwind.source(from: [globals, "@import \"tailwindcss\";\n.b { color: blue }"]) ?? ""
check(two.components(separatedBy: "@import \"tailwindcss\"").count == 2, "two entries share one Tailwind import")
check(two.contains(".b { color: blue }") && two.contains("@theme {"), "both entries' rules are kept")

// MARK: - The script that adds the style

let nasty = "a { content: \"x\\ny\"; }\n/* quote ' and </script> and \u{2028} */\nb::after { content: '\\201C'; }"
let context = JSContext()!
context.evaluateScript("""
var created = null;
var document = { createElement: function (tag) { return { tag: tag, attrs: {}, setAttribute: function (k, v) { this.attrs[k] = v; } }; },
                 head: { appendChild: function (el) { created = el; } } };
""")
context.evaluateScript(PrototypeTailwind.sourceScript(css: nasty))
check(context.exception == nil, "the script runs: \(String(describing: context.exception))")
check(context.evaluateScript("created && created.textContent").toString() == nasty, "the style carries the stylesheet exactly, quotes, backslashes and line breaks included")
check(context.evaluateScript("created.attrs.type").toString() == "text/tailwindcss", "the style is of type text/tailwindcss")

// MARK: - The lines of a page

let shell = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <link rel="stylesheet" href="markview/structure.css">
  <link rel="stylesheet" href="original/app/globals.css">
  <link rel="stylesheet" href="styles.css">
</head>
<body><div id="app"></div><script src="app.js"></script></body>
</html>
"""
let linked = PrototypeTailwind.linked(shell, prefix: "")
check(linked != nil && PrototypeTailwind.isLinked(linked!), "a shell gets the two lines")
check(linked?.contains("<script src=\"markview/tailwind-source.js\"></script>") == true && linked?.contains("<script src=\"markview/tailwind.js\"></script>") == true,
      "the lines name the files of the owned folder")
if let linked, let sources = linked.range(of: "tailwind-source.js"), let styles = linked.range(of: "href=\"styles.css\"") {
    check(sources.lowerBound < styles.lowerBound, "the lines come before styles.css, where its rules can still override Tailwind's")
}
check(PrototypeTailwind.linked(linked ?? "", prefix: "") == linked, "linking again changes nothing")
check(PrototypeTailwind.authored(linked ?? "") == shell, "authored returns the page as its author wrote it")
let page = "<html><head><title>x</title></head><body></body></html>"
let pageLinked = PrototypeTailwind.linked(page, prefix: "../")
check(pageLinked?.contains("src=\"../markview/tailwind.js\"") == true && pageLinked?.contains("src=\"../markview/tailwind-source.js\"") == true,
      "a page one folder down reaches the owned folder with ../")
check(PrototypeTailwind.authored(pageLinked ?? "") == page, "authored removes the lines of a nested page too")
check(PrototypeTailwind.linked("<p>no head</p>", prefix: "") == nil, "a page with no place for a script is left alone")
let half = shell.replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"styles.css\">", with: "<script src=\"markview/tailwind.js\"></script>\n<link rel=\"stylesheet\" href=\"styles.css\">")
check(!PrototypeTailwind.isLinked(half), "one line is not enough")
let repaired = PrototypeTailwind.linked(half, prefix: "") ?? ""
check(PrototypeTailwind.isLinked(repaired) && repaired.components(separatedBy: "tailwind.js").count == 2, "a page with one line gets both, none twice")
check(PrototypeTailwind.authored("<script src=\"markview/tailwind-mine.js\"></script>") == "<script src=\"markview/tailwind-mine.js\"></script>",
      "a script of the author's with a similar name stays")

// MARK: - A site

let script = Data("/* the browser build */ window.tailwindStub = true;\n".utf8)
let tailwindSite = work.appendingPathComponent("tailwind/site")
try put(tailwindSite, "index.html", shell)
try put(tailwindSite, "components/about.html", "<html><head><link rel=\"stylesheet\" href=\"../styles.css\"></head><body>About</body></html>")
try put(tailwindSite, "components/deep/widget.html", "<html><head></head><body>Widget</body></html>")
try put(tailwindSite, "original/app/globals.css", globals)
try put(tailwindSite, "original/app/base-elements.css", "button { cursor: pointer }")
try put(tailwindSite, "original/page.html", "<html><head></head><body>copy of a source file</body></html>")
try put(tailwindSite, "styles.css", ".x { color: red }")
try put(tailwindSite, "app.js", "App.start();")

let before = PrototypeBaseline.siteFingerprints(site: tailwindSite)
check(PrototypeTailwind.needsApplying(site: tailwindSite, vendor: { script }), "a site that imports Tailwind and has none needs it")
check(try PrototypeTailwind.ensure(site: tailwindSite, vendor: { script }) == .applied, "ensure applies it")
check(text(tailwindSite, "markview/tailwind.js") == String(decoding: script, as: UTF8.self), "the browser build is written")
check(text(tailwindSite, "markview/tailwind-source.js")?.contains("@theme {") == true && text(tailwindSite, "markview/tailwind-source.js")?.contains("@source") == false,
      "the source of the application's stylesheet is written without @source")
check(PrototypeTailwind.isLinked(text(tailwindSite, "index.html") ?? ""), "index.html links both")
check(text(tailwindSite, "components/about.html")?.contains("src=\"../markview/tailwind.js\"") == true, "a component page links them one folder up")
check(text(tailwindSite, "components/deep/widget.html")?.contains("src=\"../../markview/tailwind.js\"") == true, "a page two folders down links them two folders up")
check(text(tailwindSite, "original/page.html") == "<html><head></head><body>copy of a source file</body></html>", "a copy of a source page under original/ is not touched")
check(!PrototypeTailwind.needsApplying(site: tailwindSite, vendor: { script }), "nothing is missing afterwards")
check(try PrototypeTailwind.ensure(site: tailwindSite, vendor: { script }) == .current, "ensure is idempotent")
check(PrototypeBaseline.siteFingerprints(site: tailwindSite) == before, "the sync baseline sees no edit: index.html and the component pages hash as their authors wrote them")

try "x".write(to: tailwindSite.appendingPathComponent("markview/tailwind.js"), atomically: true, encoding: .utf8)
check(PrototypeTailwind.needsApplying(site: tailwindSite, vendor: { script }), "an out-of-date browser build is noticed")
check(try PrototypeTailwind.ensure(site: tailwindSite, vendor: { script }) == .applied && text(tailwindSite, "markview/tailwind.js") == String(decoding: script, as: UTF8.self),
      "and replaced")
let stripped = PrototypeTailwind.authored(text(tailwindSite, "index.html") ?? "")
try stripped.write(to: tailwindSite.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
check(PrototypeTailwind.needsApplying(site: tailwindSite, vendor: { script }), "a revision that dropped the lines is noticed")
check(try PrototypeTailwind.ensure(site: tailwindSite, vendor: { script }) == .applied && PrototypeTailwind.isLinked(text(tailwindSite, "index.html") ?? ""),
      "and the lines come back")
let changedCSS = globals.replacingOccurrences(of: "40px", with: "44px")
try put(tailwindSite, "original/app/globals.css", changedCSS)
check(PrototypeTailwind.needsApplying(site: tailwindSite, vendor: { script }), "a source stylesheet that changed at a sync is noticed")
check(try PrototypeTailwind.ensure(site: tailwindSite, vendor: { script }) == .applied && text(tailwindSite, "markview/tailwind-source.js")?.contains("44px") == true,
      "and the style follows it")

// A site that does not use Tailwind gets nothing; so does one asked outside the app, where the browser build is not carried.
let plainSite = work.appendingPathComponent("plain/site")
try put(plainSite, "index.html", shell)
try put(plainSite, "original/theme.css", "body { margin: 0 }")
check(!PrototypeTailwind.needsApplying(site: plainSite, vendor: { script }), "a site without a Tailwind entry needs nothing")
check(try PrototypeTailwind.ensure(site: plainSite, vendor: { script }) == .notNeeded, "ensure says so")
check(!fm.fileExists(atPath: plainSite.appendingPathComponent("markview").path) && text(plainSite, "index.html") == shell, "and writes nothing")
let bareSite = work.appendingPathComponent("bare/site")
try put(bareSite, "index.html", shell)
try put(bareSite, "original/app/globals.css", globals)
check(try PrototypeTailwind.ensure(site: bareSite, vendor: { nil }) == .unavailable, "without the browser build nothing is written")
check(text(bareSite, "index.html") == shell && !fm.fileExists(atPath: bareSite.appendingPathComponent("markview").path), "the site stays as it was")
check(!PrototypeTailwind.needsApplying(site: bareSite, vendor: { nil }), "and is not reported as needing what cannot be given")
let noPages = work.appendingPathComponent("nopages/site")
try put(noPages, "original/app/globals.css", globals)
check(try PrototypeTailwind.ensure(site: noPages, vendor: { script }) == .applied, "a site with no page still gets the files")

// The assistants never see the files: the owned folder is reserved.
check(!PrototypeFiles.read(site: tailwindSite).contains { $0.path.hasPrefix("markview/") }, "the files under markview/ are not part of what the assistants read")

// The bundled browser build is the one the app ships.
let shipped = try? Data(contentsOf: Bundle.main.url(forResource: "tailwind-browser", withExtension: "js", subdirectory: "Editor/vendor/js")!)
check((shipped?.count ?? 0) > 100_000, "the vendored browser build is in the repository")
check(String(decoding: (shipped ?? Data()).prefix(400), as: UTF8.self).contains("4.3.3"), "and is the pinned version")

        print("PrototypeTailwindTests hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
    @MainActor func testStyles() throws {
var failures = 0
var checks = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    checks += 1
    if !ok { failures += 1 }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mv-styles-tests-" + UUID().uuidString)
defer { try? fm.removeItem(at: work) }

func put(_ root: URL, _ path: String, _ content: String = "x") throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Inventory

do {
    let proj = work.appendingPathComponent("inventory")
    for path in ["app/src/widgets/OptionDesk.tsx", "app/src/widgets/PositionMonitor.tsx", "app/src/theme/variables.css",
                 "app/src/App.tsx",
                 // tests, stories, mocks and declarations: counted, never listed
                 "app/src/widgets/__tests__/OptionDesk.test.tsx", "app/src/widgets/OptionDesk.spec.ts", "app/src/types.d.ts",
                 "app/src/Button.stories.tsx", "app/tests/helper.ts", "app/src/__mocks__/api.ts", "app/src/data.mock.ts"] {
        try put(proj, path, String(repeating: "a", count: path.contains("widgets/") ? 4000 : 100))
    }
    let inv = PrototypeFiles.inventory(root: proj, sources: ["app"])
    check(Set(inv.entries.map(\.path)) == ["app/src/widgets/OptionDesk.tsx", "app/src/widgets/PositionMonitor.tsx",
                                             "app/src/theme/variables.css", "app/src/App.tsx"], "tests, stories, mocks and .d.ts files are not listed")
    check(inv.tests == 7, "they are counted (\(inv.tests))")
    check(inv.lines.contains("Tests, stories and mocks left out: 7 files."), "the listing says how many were left out")
    check(PrototypeFiles.isTestPath("src/a/__tests__/x.ts") && PrototypeFiles.isTestPath("src/x.test.tsx") && PrototypeFiles.isTestPath("e2e/login.ts")
          && !PrototypeFiles.isTestPath("src/widgets/Latest.tsx") && !PrototypeFiles.isTestPath("src/contest/Page.tsx"),
          "test paths are told from words that only contain 'test'")
    check(inv.lines.contains("app/src/widgets/ (2 files, 8 KB)") && inv.lines.contains("- OptionDesk.tsx (4000 bytes)"),
          "a block per folder, with the file count and size")
}

// The shape of the BUG-050 failure: hundreds of small files sort before the widgets and used to fill the cap.
do {
    let proj = work.appendingPathComponent("crowded")
    for n in 0..<300 { try put(proj, String(format: "src/components/C%03d.tsx", n), String(repeating: "a", count: 200)) }
    for n in 0..<12 { try put(proj, String(format: "src/widgets/W%02d.tsx", n), String(repeating: "a", count: 6000)) }
    for name in ["variables", "topbar", "dockview"] { try put(proj, "src/theme/\(name).css", String(repeating: "a", count: 300)) }
    let all = PrototypeFiles.inventory(root: proj, sources: ["src"], limit: 1000)
    check(all.entries.count == 315 && all.omitted == 0, "under the cap everything is listed")
    let capped = PrototypeFiles.inventory(root: proj, sources: ["src"], limit: 40)
    let widgets = capped.entries.filter { $0.path.contains("/widgets/") }.count
    let styles = capped.entries.filter { $0.path.hasSuffix(".css") }.count
    check(capped.entries.count == 40 && capped.omitted == 275, "the cap holds: \(capped.entries.count) listed, \(capped.omitted) omitted")
    check(widgets == 12 && styles == 3, "past the cap the alphabet decides nothing: all widgets (\(widgets)) and stylesheets (\(styles)) stay")
    check(capped.omittedByFolder == ["src/components": 275], "the dropped files are the smallest of the crowded folder: \(capped.omittedByFolder)")
    check(capped.lines.contains("(+275 smaller files of this folder not listed)") && capped.lines.last == "+275 more files not listed",
          "the listing says where files were dropped")
    let first = capped.lines.firstIndex { $0.hasPrefix("src/components/") }, later = capped.lines.firstIndex { $0.hasPrefix("src/widgets/") }
    check(first != nil && later != nil && first! < later!, "folders are listed in path order")
}

// MARK: - The original folder is the app's, not the assistant's

do {
    let site = work.appendingPathComponent("site")
    try put(site, "index.html", "<p>x</p>")
    try put(site, "original/theme/vars.css", ":root{--a:1}")
    check(PrototypeFiles.read(site: site).map(\.path) == ["index.html"], "the assistant is not shown the copied originals")
    var rejected = false
    do { _ = try PrototypeFiles.validate(path: "original/theme/vars.css") } catch { rejected = true }
    check(rejected, "the assistant cannot write into original/")
    check((try? PrototypeFiles.validate(path: "screens/original.js")) == "screens/original.js", "a file merely named original is fine")
}

// MARK: - References in a stylesheet

do {
    let css = """
    @import './base.css';
    @import url("https://fonts.example/f.css");
    @import url(other.css) screen;
    @font-face { src: url('./fonts/Open%20Sans.ttf?v=1#iefix') format('truetype'), url(fonts/a.woff2); }
    .a { background: url(../img/bg.png); background-image: url( "../img/two.png" ); }
    .b { background: url(data:image/png;base64,AAAA); cursor: url(#frag); width: var(--w); }
    .c { background: url(../img/bg.png); }
    """
    let found = PrototypeStyles.references(in: css)
    check(found == ["./base.css", "https://fonts.example/f.css", "other.css", "./fonts/Open%20Sans.ttf", "fonts/a.woff2", "../img/bg.png",
                    "../img/two.png"], "references, in order, without data:, fragments or repeats: \(found)")
    check(PrototypeStyles.isExternal("https://x/y.css") && PrototypeStyles.isExternal("//cdn/x.css") && !PrototypeStyles.isExternal("./x.css"),
          "network references are told from local ones")
}

// MARK: - Linking

do {
    let page = "<html><head><title>t</title><link rel=\"stylesheet\" href=\"styles.css\"></head><body></body></html>"
    let linked = PrototypeStyles.insertLinks(into: page, hrefs: ["original/theme/vars.css", "original/my styles/a.css"])
    check(linked == "<html><head><title>t</title><link rel=\"stylesheet\" href=\"original/theme/vars.css\">\n"
          + "<link rel=\"stylesheet\" href=\"original/my%20styles/a.css\">\n<link rel=\"stylesheet\" href=\"styles.css\"></head><body></body></html>",
          "links go before styles.css, in order, with spaces encoded")
    check(PrototypeStyles.insertLinks(into: "<head></head>", hrefs: ["original/a.css"]) == "<head><link rel=\"stylesheet\" href=\"original/a.css\">\n</head>",
          "without a styles.css link they go before </head>")
    check(PrototypeStyles.insertLinks(into: "<h1>x</h1>", hrefs: ["original/a.css"]) == nil, "a page with neither place is refused")
    check(PrototypeStyles.insertLinks(into: "<h1>x</h1>", hrefs: []) == "<h1>x</h1>", "nothing to link leaves the page alone")
}

// MARK: - The verbatim copy

do {
    let proj = work.appendingPathComponent("app")
    let site = work.appendingPathComponent("proto/site")
    let variables = """
    @import './base.css';
    @font-face { font-family: 'Open Sans'; src: url('./fonts/Open%20Sans.ttf?v=1') format('truetype'); }
    @font-face { font-family: 'Web'; src: url(https://fonts.example/web.woff2); }
    :root { --bg: #1e1f22; background: url(../img/bg.png); }
    .x { background: url(missing.png); } .y { background: url(/abs.png); } .z { background: url(data:image/png;base64,AAAA); }
    """
    try put(proj, "src/theme/variables.css", variables)
    try put(proj, "src/theme/base.css", "body { margin: 0; background: url(./fonts/Open Sans.ttf); }".replacingOccurrences(of: "Open Sans", with: "Open%20Sans"))
    try put(proj, "src/theme/fonts/Open Sans.ttf", "FONTBYTES")
    try put(proj, "src/img/bg.png", "PNGBYTES")
    try put(proj, "src/topbar.css", ".bar { color: red; }")
    try put(proj, "src/styles.scss", "$a: 1;")
    try put(proj, ".git/hooks.css", "x")
    try put(proj, "docs/prototypes/old/site/x.css", "x")
    try put(proj, "src/huge.css", String(repeating: "a", count: PrototypeStyles.maxStyleBytes + 1))
    let outside = work.appendingPathComponent("outside.css")
    try ".secret{}".write(to: outside, atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(at: proj.appendingPathComponent("src/link.css"), withDestinationURL: outside)
    try fm.createDirectory(at: site, withIntermediateDirectories: true)

    let copied = PrototypeStyles.copy(styles: ["./src/theme/variables.css", "src/theme/variables.css", "src/topbar.css", "../outside.css", "/etc/x.css",
                                               "src/nope.css", "src/styles.scss", ".git/hooks.css", "docs/prototypes/old/site/x.css",
                                               "src/huge.css", "src/link.css", "src/theme"], root: proj, site: site)
    let original = site.appendingPathComponent("original")
    func same(_ relative: String) -> Bool {
        (try? Data(contentsOf: original.appendingPathComponent(relative))) == (try? Data(contentsOf: proj.appendingPathComponent(relative)))
            && fm.fileExists(atPath: original.appendingPathComponent(relative).path)
    }
    check(same("src/theme/variables.css") && same("src/topbar.css"), "the listed stylesheets are copied byte for byte, at the same relative path")
    check(copied.links == ["original/src/theme/variables.css", "original/src/topbar.css"], "links, in the planner's order, once each: \(copied.links)")
    check(same("src/theme/base.css") && copied.stylesheets.contains("src/theme/base.css") && !copied.links.contains("original/src/theme/base.css"),
          "an @import is copied too, and left to the browser to load")
    check(same("src/theme/fonts/Open Sans.ttf") && same("src/img/bg.png") && Set(copied.assets) == ["src/theme/fonts/Open Sans.ttf", "src/img/bg.png"],
          "fonts and images are found through %20 and ../ and copied: \(copied.assets)")
    check(!fm.fileExists(atPath: original.appendingPathComponent("src/huge.css").path) && !fm.fileExists(atPath: original.appendingPathComponent("src/link.css").path)
          && !fm.fileExists(atPath: original.appendingPathComponent(".git").path) && !fm.fileExists(atPath: original.appendingPathComponent("docs").path)
          && !fm.fileExists(atPath: original.appendingPathComponent("src/styles.scss").path),
          "over-size, symlinked-out, hidden, prototype and non-CSS files are not copied")
    let gaps = copied.gaps.joined(separator: "\n")
    for (needle, what) in [("../outside.css named by the plan is not inside the project", "outside the project"),
                           ("src/nope.css named by the plan was not found", "missing file"),
                           ("src/styles.scss is not plain CSS", "scss"),
                           ("src/huge.css is", "over the size limit"),
                           ("src/link.css named by the plan is not inside the project", "a symlink out of the project"),
                           ("src/theme/variables.css loads 1 resource from the network", "a network font"),
                           ("src/theme/variables.css refers to 2 files that could not be found in the project (missing.png, /abs.png)", "unresolved references")] {
        check(gaps.contains(needle), "gap: \(what)")
    }
    check(!gaps.contains("data:"), "a data: URL is not a gap")

    // A site that is copied again replaces what was there (Sync from code clears it first, but a retry must not stack files).
    let again = PrototypeStyles.copy(styles: ["src/topbar.css"], root: proj, site: site)
    check(again.links == ["original/src/topbar.css"] && same("src/topbar.css"), "copying again overwrites")
    check(PrototypeStyles.copy(styles: [], root: proj, site: site).isEmpty, "no styles, nothing copied")
}

// A stylesheet of an installed package (pnpm layout) that a listed stylesheet imports by its bare name (Dockview's own CSS).
do {
    let proj = work.appendingPathComponent("packages")
    let site = work.appendingPathComponent("packages-site")
    try fm.createDirectory(at: site, withIntermediateDirectories: true)
    let store = proj.appendingPathComponent("app/node_modules/.pnpm/pkg@1.0.0/node_modules/pkg")
    try put(store, "dist/styles/pkg.css", "@import \"./sub.css\";\n.pkg { background: url(../img/i.png); }")
    try put(store, "dist/styles/sub.css", ".sub { color: red; }")
    try put(store, "dist/img/i.png", "PNG")
    try fm.createSymbolicLink(at: proj.appendingPathComponent("app/node_modules/pkg"), withDestinationURL: store)
    try put(proj, "app/src/theme/overrides.css", "@import 'pkg/dist/styles/pkg.css';\n@import \"~pkg/dist/styles/sub.css\";\n.mine { color: blue; }")
    try put(proj, "app/src/main.css", ".main { color: green; }")
    let outside = work.appendingPathComponent("outside-pkgs")
    try put(outside, "evil/evil.css", ".evil{}")
    try fm.createDirectory(at: proj.appendingPathComponent("app/node_modules"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: proj.appendingPathComponent("app/node_modules/evil"), withDestinationURL: outside.appendingPathComponent("evil"))
    try put(proj, "app/src/escape.css", "@import 'pkg/../../../outside.css';\n@import 'evil/evil.css';\n@import 'missing-pkg/x.css';")

    let copied = PrototypeStyles.copy(styles: ["app/src/theme/overrides.css", "app/src/main.css", "app/src/escape.css"], root: proj, site: site)
    let original = site.appendingPathComponent("original")
    func text(_ path: String) -> String? { try? String(contentsOf: original.appendingPathComponent(path), encoding: .utf8) }
    check(text("node_modules/pkg/dist/styles/pkg.css")?.contains(".pkg") == true, "a package stylesheet is copied under node_modules/<specifier>")
    check(text("node_modules/pkg/dist/styles/sub.css") == ".sub { color: red; }" && text("node_modules/pkg/dist/img/i.png") == "PNG",
          "what the package stylesheet imports and loads keeps the package's own layout, not the pnpm store path")
    check(copied.links == ["original/node_modules/pkg/dist/styles/pkg.css", "original/node_modules/pkg/dist/styles/sub.css",
                           "original/app/src/theme/overrides.css", "original/app/src/main.css", "original/app/src/escape.css"],
          "package stylesheets are linked before the listed one that imports them, once: \(copied.links)")
    check(!fm.fileExists(atPath: original.appendingPathComponent("app/node_modules").path) && !fm.fileExists(atPath: original.appendingPathComponent("evil").path)
          && !fm.fileExists(atPath: original.appendingPathComponent("node_modules/evil").path), "no store path is reproduced and a package linked out of the project is refused")
    check(copied.gaps.contains { $0.contains("app/src/escape.css refers to 3 files that could not be found") },
          "an escaping specifier, a package outside the project and a missing package are gaps: \(copied.gaps)")
    check(copied.gaps.count == 1 && copied.assets == ["node_modules/pkg/dist/img/i.png"], "nothing else is reported: \(copied.gaps)")
}

// Too many files stop at the limit, with one gap, not an error.
do {
    let proj = work.appendingPathComponent("many")
    let site = work.appendingPathComponent("many-site")
    try fm.createDirectory(at: site, withIntermediateDirectories: true)
    var css = ""
    for n in 0..<(PrototypeStyles.maxFiles + 20) {
        try put(proj, "img/i\(n).png", "p")
        css += ".i\(n){background:url(../img/i\(n).png)}\n"
    }
    try put(proj, "css/a.css", css)
    let copied = PrototypeStyles.copy(styles: ["css/a.css"], root: proj, site: site)
    check(copied.totalFiles == PrototypeStyles.maxFiles, "the copy stops at \(PrototypeStyles.maxFiles) files (copied \(copied.totalFiles))")
    check(copied.gaps.filter { $0.contains("stopped at its size limit") }.count == 1, "one gap names the limit")
}

// MARK: - The plan carries styles, widgets and hosts

func screen(_ id: String, embedded: Bool = false, hosts: [String] = [], components: [String] = []) -> [String: Any] {
    ["id": id, "name": id.capitalized, "route": "/" + id, "purpose": "p", "data": [], "actions": [], "states": [], "rules": [],
     "requirements": [], "evidence": ["src/\(id).tsx"], "components": components, "embedded": embedded, "hosts": hosts]
}
func planObject(_ screens: [[String: Any]], styles: [String]) -> [String: Any] {
    ["title": "T", "summary": "s", "assumptions": [], "gaps": ["g"], "roles": [], "entities": [], "screens": screens, "styles": styles]
}

do {
    let object = planObject([screen("workspace", hosts: ["option-desk", "ghost", "workspace", "option-desk", "Order Book"]),
                             screen("option-desk", embedded: true), screen("order-book", embedded: true)],
                            styles: ["src/theme/variables.css", " ", "src/theme/variables.css", "  src/topbar.css  "])
    let plan = try Plan(object)
    check(plan.styles == ["src/theme/variables.css", "src/topbar.css"], "styles are trimmed, de-duplicated and kept in order: \(plan.styles)")
    check(plan.screens.map(\.embedded) == [false, true, true], "embedded flags are kept in code mode")
    check(plan.screens[0].hosts == ["option-desk", "order-book"], "a host keeps real widget ids only, once, never itself: \(plan.screens[0].hosts)")
    check(plan.json.contains("\"styles\"") && plan.json.contains("\"embedded\" : true") && plan.json.contains("\"hosts\""), "the writers see styles, embedded and hosts in the plan")

    // The themes the planner read from the original (themes feature, REQ-001).
    var themed = object
    themed["themes"] = ["dark", " midnight ", "dark", "", "tastytrade"]
    themed["defaultTheme"] = "  tastytrade "
    let themedPlan = try Plan(themed)
    check(themedPlan.themes == ["dark", "midnight", "tastytrade"] && themedPlan.defaultTheme == "tastytrade",
          "theme ids are trimmed and de-duplicated, the default is trimmed: \(themedPlan.themes) \(themedPlan.defaultTheme)")
    check(themedPlan.json.contains("\"defaultTheme\" : \"tastytrade\""), "the writers see the themes in the plan")
    let themedRequirements = try PrototypePlan(structured: themed, mode: .requirements)
    check(themedRequirements.themes.isEmpty && themedRequirements.defaultTheme.isEmpty, "requirements mode ignores themes")
    check(plan.themes.isEmpty && plan.defaultTheme.isEmpty, "a plan without the fields has no themes")
    let props = PrototypeSchemas.planSchema["properties"] as? [String: Any] ?? [:]
    check(props["themes"] != nil && props["defaultTheme"] != nil, "the plan schema has themes and defaultTheme (required: the strict schema test above)")

    let requirements = try PrototypePlan(structured: object, mode: .requirements)
    check(requirements.styles.isEmpty && requirements.screens.allSatisfy { !$0.embedded && $0.hosts.isEmpty }, "requirements mode ignores styles, widgets and hosts")

    let many = planObject((0..<45).map { screen("s\($0)") }, styles: [])
    let code = try PrototypePlan(structured: many, mode: .code)
    check(code.screens.count == 40 && code.gaps.contains { $0.contains("only the first 40 are built") }, "code mode allows 40 screens and says what was cut")
    let req = try PrototypePlan(structured: many, mode: .requirements)
    check(req.screens.count == 10 && req.gaps.contains { $0.contains("only the first 10 are built") }, "requirements mode still stops at 10")
}

func Plan(_ object: [String: Any]) throws -> PrototypePlan { try PrototypePlan(structured: object, mode: .code) }

// MARK: - Schema and prompts

do {
    let schema = PrototypeSchemas.planSchema
    let top = schema["properties"] as? [String: Any] ?? [:]
    let required = Set(schema["required"] as? [String] ?? [])
    check(Set(top.keys) == required && required.contains("styles"), "every top-level property is required (strict schema), including styles")
    let items = ((top["screens"] as? [String: Any])?["items"] as? [String: Any]) ?? [:]
    let itemProperties = items["properties"] as? [String: Any] ?? [:]
    check(Set(itemProperties.keys) == Set(items["required"] as? [String] ?? []) && itemProperties["embedded"] != nil && itemProperties["hosts"] != nil,
          "every screen property is required, including embedded and hosts")

    check(PrototypePrompts.originalStylesNote([]) == "", "no copied styles, no note")
    let note = PrototypePrompts.originalStylesNote(["src/theme/variables.css", "src/topbar.css"])
    check(note.contains("already copied into the prototype unchanged") && note.contains("src/theme/variables.css, src/topbar.css")
          && note.contains("class names"), "the note names the copied files and asks for the original class names")
    let foundation = PrototypePrompts.foundationPrompt(plan: "{}", failure: nil, mode: .code, originalStyles: ["a.css"])
    check(foundation.contains("already copied into the prototype unchanged"), "the code foundation prompt carries the note")
    check(!PrototypePrompts.foundationPrompt(plan: "{}", failure: nil, mode: .requirements, originalStyles: ["a.css"]).contains("already copied"),
          "requirements mode never does")
    let widget = PrototypeAI.PlannedScreen(id: "w", name: "W", route: "/widgets/w", purpose: "", evidence: ["src/w.tsx"], components: [], embedded: true)
    let screenPrompt = PrototypePrompts.screenPrompt(plan: "{}", screen: widget, foundation: [], failure: nil, mode: .code, originalStyles: ["a.css"])
    check(screenPrompt.contains("already copied into the prototype unchanged") && screenPrompt.contains("- src/w.tsx"), "the code screen prompt carries the note and the evidence")
    let system = PrototypePrompts.codePlanSystem(language: "")
    for phrase in ["`styles`", "`themes`", "`defaultTheme`", "at most 40", "`embedded` true", "`hosts` lists", "Never merge several widgets or modals into one entry",
                   "never plan one you have not read", "more than one front end", "name the other front end in `gaps`", "the route `/modals/<id>`",
                   "Put small confirmation and alert dialogs inside the screen"] {
        check(system.contains(phrase), "code plan system says: \(phrase)")
    }
}

        print("PrototypeStylesTests hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
}
