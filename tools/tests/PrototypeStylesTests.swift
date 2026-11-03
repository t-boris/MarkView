import Foundation

// Checks for BUG-050: the inventory the planner reads, the verbatim copy of the app's own stylesheets
// (MarkView/Models/PrototypeStyles.swift), and how the plan carries styles, widgets and hosts.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
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
    let themedRequirements = try PrototypeAI.Plan(structured: themed, mode: .requirements)
    check(themedRequirements.themes.isEmpty && themedRequirements.defaultTheme.isEmpty, "requirements mode ignores themes")
    check(plan.themes.isEmpty && plan.defaultTheme.isEmpty, "a plan without the fields has no themes")
    let props = PrototypeAI.planSchema["properties"] as? [String: Any] ?? [:]
    check(props["themes"] != nil && props["defaultTheme"] != nil, "the plan schema has themes and defaultTheme (required: the strict schema test above)")

    let requirements = try PrototypeAI.Plan(structured: object, mode: .requirements)
    check(requirements.styles.isEmpty && requirements.screens.allSatisfy { !$0.embedded && $0.hosts.isEmpty }, "requirements mode ignores styles, widgets and hosts")

    let many = planObject((0..<45).map { screen("s\($0)") }, styles: [])
    let code = try PrototypeAI.Plan(structured: many, mode: .code)
    check(code.screens.count == 40 && code.gaps.contains { $0.contains("only the first 40 are built") }, "code mode allows 40 screens and says what was cut")
    let req = try PrototypeAI.Plan(structured: many, mode: .requirements)
    check(req.screens.count == 10 && req.gaps.contains { $0.contains("only the first 10 are built") }, "requirements mode still stops at 10")
}

func Plan(_ object: [String: Any]) throws -> PrototypeAI.Plan { try PrototypeAI.Plan(structured: object, mode: .code) }

// MARK: - Schema and prompts

do {
    let schema = PrototypeAI.planSchema
    let top = schema["properties"] as? [String: Any] ?? [:]
    let required = Set(schema["required"] as? [String] ?? [])
    check(Set(top.keys) == required && required.contains("styles"), "every top-level property is required (strict schema), including styles")
    let items = ((top["screens"] as? [String: Any])?["items"] as? [String: Any]) ?? [:]
    let itemProperties = items["properties"] as? [String: Any] ?? [:]
    check(Set(itemProperties.keys) == Set(items["required"] as? [String] ?? []) && itemProperties["embedded"] != nil && itemProperties["hosts"] != nil,
          "every screen property is required, including embedded and hosts")

    check(PrototypeAI.originalStylesNote([]) == "", "no copied styles, no note")
    let note = PrototypeAI.originalStylesNote(["src/theme/variables.css", "src/topbar.css"])
    check(note.contains("already copied into the prototype unchanged") && note.contains("src/theme/variables.css, src/topbar.css")
          && note.contains("class names"), "the note names the copied files and asks for the original class names")
    let foundation = PrototypeAI.foundationPrompt(plan: "{}", failure: nil, mode: .code, originalStyles: ["a.css"])
    check(foundation.contains("already copied into the prototype unchanged"), "the code foundation prompt carries the note")
    check(!PrototypeAI.foundationPrompt(plan: "{}", failure: nil, mode: .requirements, originalStyles: ["a.css"]).contains("already copied"),
          "requirements mode never does")
    let widget = PrototypeAI.PlannedScreen(id: "w", name: "W", route: "/widgets/w", purpose: "", evidence: ["src/w.tsx"], components: [], embedded: true)
    let screenPrompt = PrototypeAI.screenPrompt(plan: "{}", screen: widget, foundation: [], failure: nil, mode: .code, originalStyles: ["a.css"])
    check(screenPrompt.contains("already copied into the prototype unchanged") && screenPrompt.contains("- src/w.tsx"), "the code screen prompt carries the note and the evidence")
    let system = PrototypeAI.codePlanSystem(language: "")
    for phrase in ["`styles`", "`themes`", "`defaultTheme`", "at most 40", "`embedded` true", "`hosts` lists", "Never merge several widgets or modals into one entry",
                   "never plan one you have not read", "more than one front end", "name the other front end in `gaps`", "the route `/modals/<id>`",
                   "Put small confirmation and alert dialogs inside the screen"] {
        check(system.contains(phrase), "code plan system says: \(phrase)")
    }
}

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL OK")
