import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
}

// Themes found in copied stylesheets (feature "Themes in a prototype made from code", REQ-001).
do {
    let strikedesk = """
    :root { --bg: #111; }
    /* the first theme */
    [data-theme="dark"] { --bg: #000; }
    [data-theme='midnight'], html[data-theme=midnight] .panel { --bg: #001; }
    @media (min-width: 800px) { :root[data-theme="terminal"] { --bg: #020; } }
    body[data-theme="tastytrade"] { --bg: #123; }
    [data-theme="dark"] .card { color: red; }
    """
    let found = PrototypeThemes.scan(stylesheets: [strikedesk])
    check(found?.attribute == "data-theme" && found?.ids == ["dark", "midnight", "terminal", "tastytrade"],
          "ids in order of first appearance, root forms and bare attribute, without repeats: \(String(describing: found))")
    check(PrototypeThemes.scan(stylesheets: [":root { --a: 1 } .card { color: red }"]) == nil, "no theme selector, no theme")
    check(PrototypeThemes.scan(stylesheets: ["[data-theme=\"dark\"] { color: #fff }"]) == nil, "an attribute that selects one value is not a theme switch")
    check(PrototypeThemes.scan(stylesheets: [".card[data-theme=\"a\"] {} .box[data-theme=\"b\"] {} main [data-theme=\"c\"] {}"]) == nil,
          "an attribute on a component or below the root is not a root theme")
    check(PrototypeThemes.scan(stylesheets: ["/* [data-theme=\"a\"] {} [data-theme=\"b\"] {} */ .x { y: z }"]) == nil, "selectors in comments do not count")
    check(PrototypeThemes.scan(stylesheets: ["[data-theme=\"a\"] {}", "[data-theme=\"b\"] {} [data-theme=\"a\"] {}"])?.ids == ["a", "b"],
          "themes are collected across stylesheets")
    let mixed = PrototypeThemes.scan(stylesheets: ["[data-density=\"compact\"] {} [data-density=\"roomy\"] {} [data-color-scheme=\"light\"] {} [data-color-scheme=\"dark\"] {} [data-color-scheme=\"sepia\"] {}"])
    check(mixed?.attribute == "data-color-scheme" && mixed?.ids == ["light", "dark", "sepia"], "only theme-like attributes count, the one with most values wins: \(String(describing: mixed))")
    check(PrototypeThemes.scan(stylesheets: ["[data-bs-theme=\"light\"] {} [data-bs-theme=\"dark\"] {}"])?.attribute == "data-bs-theme", "data-bs-theme is a theme attribute")

    // The record keeps what is still valid.
    let ids = (attribute: "data-theme", ids: ["dark", "midnight", "tastytrade"])
    let fresh = PrototypeThemes.record(found: ids, defaultID: "tastytrade", previous: nil)
    check(fresh == PrototypeFiles.ThemeRecord(attribute: "data-theme", ids: ids.ids, defaultID: "tastytrade", chosen: nil) && fresh?.effective == "tastytrade",
          "the default the build recorded is the effective theme before any choice")
    check(PrototypeThemes.record(found: ids, defaultID: nil, previous: nil)?.effective == nil, "no recorded default and no choice keeps the prototype's own look")
    check(PrototypeThemes.record(found: ids, defaultID: "neon", previous: nil)?.defaultID == nil, "a default that is not among the themes is dropped")
    var chosen = fresh!; chosen.chosen = "midnight"
    check(chosen.effective == "midnight", "the choice wins over the default")
    let after = PrototypeThemes.record(found: ids, defaultID: nil, previous: chosen)
    check(after?.chosen == "midnight" && after?.defaultID == "tastytrade", "a sync keeps the choice and the earlier default: \(String(describing: after))")
    let gone = PrototypeThemes.record(found: (attribute: "data-theme", ids: ["dark", "light"]), defaultID: nil, previous: chosen)
    check(gone?.chosen == nil && gone?.defaultID == nil && gone?.effective == nil, "a choice that no longer exists is dropped")
    check(PrototypeThemes.record(found: (attribute: "data-mode", ids: ["a", "b"]), defaultID: nil, previous: chosen)?.chosen == nil,
          "a choice for another attribute is dropped")
    check(PrototypeThemes.record(found: nil, defaultID: "x", previous: chosen) == nil, "no themes found, no record")

    // StrikeDesk: `dark` is the base look with no selector, so the planner's ids add it and give the order.
    let scanned3 = (attribute: "data-theme", ids: ["midnight", "tastytrade", "terminal"])
    let planned = PrototypeThemes.record(found: scanned3, planned: ["dark", "midnight", "terminal", "tastytrade"], defaultID: "tastytrade", previous: nil)
    check(planned?.ids == ["dark", "midnight", "terminal", "tastytrade"] && planned?.effective == "tastytrade", "the planner adds the base theme and the order: \(String(describing: planned))")
    check(PrototypeThemes.record(found: scanned3, planned: ["dark"], defaultID: nil, previous: nil)?.ids == ["dark", "midnight", "tastytrade", "terminal"],
          "ids the planner did not list still come from the stylesheets")
    check(PrototypeThemes.record(found: nil, planned: ["a", "b"], defaultID: "a", previous: nil) == nil, "the planner alone cannot create a picker")
    var original = planned!; original.chosen = ""
    check(original.effective == nil, "the empty choice is the original look: no attribute")
    check(PrototypeThemes.record(found: scanned3, planned: ["dark"], defaultID: nil, previous: original)?.chosen == "", "a sync keeps the original-look choice")

    // The scripts never paste text raw.
    let hostile = PrototypeThemes.startScript(attribute: "data-theme", id: "a\"); alert(1); (\"")
    check(!hostile.contains("alert(1); (\"") || hostile.contains("\\\"); alert(1); (\\\""), "ids are JSON-escaped in the start script: \(hostile)")
    check(PrototypeThemes.applyScript(attribute: "data-theme", id: nil) == "document.documentElement.removeAttribute(\"data-theme\");", "no id removes the attribute")
    check(PrototypeThemes.applyScript(attribute: "data-theme", id: "dark") == "document.documentElement.setAttribute(\"data-theme\", \"dark\");", "an id sets the attribute")

    // Codable: an old manifest has no themes.
    let old = #"{"title":"T","slug":"t","brief":"","sources":[]}"#.data(using: .utf8)!
    let manifest = try? JSONDecoder().decode(PrototypeFiles.Manifest.self, from: old)
    check(manifest != nil && manifest?.themes == nil, "a manifest without themes still decodes")
    if var m = manifest {
        m.themes = fresh
        let round = (try? JSONEncoder().encode(m)).flatMap { try? JSONDecoder().decode(PrototypeFiles.Manifest.self, from: $0) }
        check(round?.themes == fresh, "the record round-trips through the manifest")
    }

    // Reading a site: the stylesheets linked from index.html come first, the rest by path.
    let fm = FileManager.default
    let site = fm.temporaryDirectory.appendingPathComponent("mv-themes-" + UUID().uuidString)
    defer { try? fm.removeItem(at: site) }
    func put(_ path: String, _ text: String) throws {
        let url = site.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try put("index.html", "<link rel=\"stylesheet\" href=\"original/b/second.css\"><link rel=\"stylesheet\" href=\"original/a/first.css\"><link rel=\"stylesheet\" href=\"styles.css\">")
    try put("original/a/first.css", "[data-theme=\"two\"] {}")
    try put("original/b/second.css", "[data-theme=\"one\"] {}")
    try put("original/c/unlinked.css", "[data-theme=\"three\"] {}")
    try put("original/fonts/f.woff2", "x")
    try put("styles.css", "[data-theme=\"never\"] {}")
    let scanned = PrototypeThemes.scan(site: site)
    check(scanned?.ids == ["one", "two", "three"], "linked stylesheets first in link order, then the rest; styles.css is not an original: \(String(describing: scanned))")
    check(PrototypeThemes.scan(site: site.appendingPathComponent("nowhere")) == nil, "a site without originals has no themes")
}

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
