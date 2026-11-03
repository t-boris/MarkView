import Foundation

// Checks for BUG-050, steps 4 to 6: widgets and modals as screens of their own, the host that lays them out, the
// isolated page that needs no assistant, and the coverage figure.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func screen(_ id: String, route: String? = nil, embedded: Bool = false, hosts: [String] = [], evidence: [String] = [],
            components: [String] = []) -> PrototypeAI.PlannedScreen {
    PrototypeAI.PlannedScreen(id: id, name: id.capitalized, route: route ?? "/" + id, purpose: "", evidence: evidence,
                              components: components, embedded: embedded, hosts: hosts)
}

// MARK: - Shell and styles contracts

do {
    let plain = PrototypeAI.shellSystem(language: "")
    let widgets = PrototypeAI.shellSystem(language: "", widgets: true)
    check(!plain.contains("renderScreen") && !plain.contains("embedded"), "a plan without widgets gets the shell prompt it always had")
    for phrase in ["`App.renderScreen(id, extra)`", "`embedded: true`", "`hosts`", "exactly one such screen exists", "no navigation list",
                   "never throws", "without `App.start()`", "accepts an element or an HTML string as `body`", "Visiting the route of an embedded screen"] {
        check(widgets.contains(phrase), "the widget shell prompt says: \(phrase)")
    }
    check(widgets.hasPrefix(plain.components(separatedBy: "Keep app.js under 60 KB").first ?? "?"), "the widget paragraph is added, nothing else changes before it")

    let design = PrototypeAI.stylesSystem(language: "")
    let bridge = PrototypeAI.stylesSystem(language: "", originals: true)
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
    check([host, widget, modal].allSatisfy { PrototypeAI.screenEffort($0) == "medium" } && PrototypeAI.screenEffort(page) == "low",
          "hosts, widgets and modals run at medium effort, an ordinary page at low")
    let large = PrototypeAI.largeSourceBytes
    check([host, widget, modal].allSatisfy { PrototypeAI.screenEffort($0, sourceBytes: large - 1) == "medium" && PrototypeAI.screenEffort($0, sourceBytes: large) == "high" },
          "a host, widget or modal whose evidence is \(large) bytes or more runs at high effort (BUG-059)")
    check(PrototypeAI.screenEffort(page, sourceBytes: 10 * large) == "low", "an ordinary page stays at low effort however large its source is")
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("effort-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? Data(count: 30_000).write(to: folder.appendingPathComponent("src/OrderList.tsx"))
        try? Data(count: 15_000).write(to: folder.appendingPathComponent("src/Extra.tsx"))
        let sized = screen("order-list", embedded: true, evidence: ["src/OrderList.tsx", "src/Extra.tsx", "src/Gone.tsx"])
        check(PrototypeAI.evidenceBytes(sized, root: folder) == 45_000, "the evidence size adds up the files that exist and counts a missing one as nothing")
        check(PrototypeAI.evidenceBytes(screen("about"), root: folder) == 0, "a screen without evidence has no size")
    }
    check(PrototypeAI.isModal(modal) && !PrototypeAI.isModal(widget) && !PrototypeAI.isModal(host), "a modal is told by its route")

    func prompt(_ s: PrototypeAI.PlannedScreen, hosted: [PrototypeAI.PlannedScreen] = [], mode: PrototypeFiles.Mode = .code) -> String {
        PrototypeAI.screenPrompt(plan: "{}", screen: s, foundation: [], failure: nil, mode: mode, originalStyles: ["a.css"], hosted: hosted)
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
    let tracker = PrototypeAI.ProgressTracker(root: URL(fileURLWithPath: "/proj"), reading: "the code", onRead: { seen.add($0) }, emit: { _ in })
    tracker.handle(.read("/proj/src/Widget.tsx"))
    tracker.handle(.read("/elsewhere/x.ts"))
    tracker.handle(.search("q"))
    check(seen.all == ["src/Widget.tsx", "/elsewhere/x.ts"], "the tracker reports what the assistant read, relative to the project: \(seen.all.sorted())")
}

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL OK")
