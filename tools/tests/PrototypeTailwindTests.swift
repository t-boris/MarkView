import Foundation
import JavaScriptCore

// Checks for BUG-063: a prototype made from the code of a Tailwind v4 app carries Tailwind (MarkView/Models/PrototypeTailwind.swift).
// The source stylesheet is found among the copied originals, handed to the browser build as a style of type text/tailwindcss, linked from
// every page, kept out of the assistant's reach and out of the sync baseline, and written again only when something is missing.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
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
let shipped = try? Data(contentsOf: URL(fileURLWithPath: "MarkView/Resources/Editor/vendor/js/tailwind-browser.js"))
check((shipped?.count ?? 0) > 100_000, "the vendored browser build is in the repository")
check(String(decoding: (shipped ?? Data()).prefix(400), as: UTF8.self).contains("4.3.3"), "and is the pinned version")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("Prototype Tailwind: the source is found among the originals, carried into the prototype as a text/tailwindcss style with the browser build, linked from every page, outside the baseline, idempotent; sites without Tailwind are untouched.")
