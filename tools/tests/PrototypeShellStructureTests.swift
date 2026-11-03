import Foundation

// Checks for BUG-060: the page structure of a prototype from code is MarkView's (MarkView/Models/PrototypeShellStructure.swift).
// The stylesheet has zero-specificity rules for every box of the shell, it is linked from index.html in a folder the assistant
// cannot read or write, adding it is not an edit of the shell, and the shell writers are told it is not theirs.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
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
    check(PrototypeAI.shellSystem(language: "", ownsStructure: true).contains(contract), "the shell prompt of a prototype from code carries it")
    check(PrototypeAI.stylesSystem(language: "", ownsStructure: true).contains(contract), "the styles prompt carries it")
    check(PrototypeAI.stylesSystem(language: "", originals: true, ownsStructure: true).contains(contract), "so does the bridge prompt")
    check(!PrototypeAI.shellSystem(language: "").contains(PrototypeShellStructure.href)
          && !PrototypeAI.stylesSystem(language: "").contains(PrototypeShellStructure.href)
          && !PrototypeAI.stylesSystem(language: "", originals: true).contains(PrototypeShellStructure.href),
          "a prompt that does not ask for it says nothing about it")
    check(PrototypeAI.shellSystem(language: "", widgets: true).contains("panel body"), "the widget contract still tells hosts to give a widget a box")
}

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL OK")
