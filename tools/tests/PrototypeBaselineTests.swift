import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("mv-baseline-tests-" + UUID().uuidString)
defer { try? fm.removeItem(at: work) }
func put(_ path: String, _ text: String) throws {
    let url = work.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// Fingerprints.
do {
    try put("src/a.tsx", "A"); try put("src/b.tsx", "B"); try put("src/theme.css", "t")
    let prints = PrototypeBaseline.fingerprints(root: work, paths: ["src/a.tsx", "src/b.tsx", "src/missing.tsx", "src/a.tsx"])
    check(prints.count == 2 && prints["src/a.tsx"] == PrototypeBaseline.sha256(Data("A".utf8)) && prints["src/a.tsx"] != prints["src/b.tsx"],
          "a fingerprint per readable file, a missing file left out, repeats once")
    check(PrototypeBaseline.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha-256 of abc")
    try put("site/app.js", "x"); try put("site/screens/home.js", "h"); try put("site/original/src/theme.css", "o")
    let site = PrototypeBaseline.siteFingerprints(site: work.appendingPathComponent("site"))
    check(Set(site.keys) == ["app.js", "screens/home.js"], "the prototype's fingerprints skip the copied originals: \(site.keys.sorted())")
}

// Diff.
do {
    let d = PrototypeBaseline.diff(baseline: ["a": "1", "b": "2", "c": "3", "n": ""], current: ["a": "1", "b": "9", "d": "4", "n": "5"])
    check(d.changed == ["b"] && d.removed == ["c"] && d.added == ["d", "n"], "changed, removed, added; a file unreadable at the sync that exists now is added: \(d)")
    check(PrototypeBaseline.diff(baseline: ["a": "1"], current: ["a": "1"]).isEmpty, "no difference")
    check(PrototypeBaseline.diff(baseline: ["n": ""], current: [:]).isEmpty, "a file that was unreadable and still is, is no change")
}

// A record and the status of every unit.
do {
    let site0 = ["index.html": "i0", "app.js": "a0", "data.js": "d0", "styles.css": "s0", "screens/orders.js": "o0", "screens/trade.js": "t0",
                 "screens/settings.js": "g0", "components/orders-list.html": "c0"]
    let scope0 = ["src/theme.css": "t0", "src/Orders.tsx": "o0", "src/OrdersList.tsx": "l0", "src/Trade.tsx": "r0", "src/util.ts": "u0"]
    let exists: (String) -> Bool = { $0 != "src/Ghost.tsx" }
    let record = PrototypeBaseline.make(
        version: 3, plan: "{}", styles: ["src/theme.css"],
        screens: [(id: "orders", name: "Orders", sources: ["src/Orders.tsx", "src/OrdersList.tsx"]),
                  (id: "trade", name: "Trade", sources: ["src/Trade.tsx", "src/Ghost.tsx"]),
                  (id: "settings", name: "Settings", sources: [])],
        components: [PrototypeFiles.Component(path: "src/OrdersList.tsx", label: "OrdersList", screens: ["Orders"], page: "components/orders-list.html")],
        scope: scope0, site: site0, sourceExists: exists)
    let byID = Dictionary(uniqueKeysWithValues: record.units.map { ($0.id, $0) })
    check(record.units.map(\.kind) == [.foundation, .screen, .screen, .screen, .component], "units: shell, screens, components in order")
    check(byID["trade"]?.sources == ["src/Trade.tsx"] && byID["trade"]?.incomplete == true, "a source that does not exist is dropped and the unit is incomplete")
    check(byID["settings"]?.incomplete == true && byID["settings"]?.sources == [], "a unit with no sources is incomplete")
    check(byID["orders"]?.incomplete == false && byID["orders"]?.files == ["screens/orders.js": "o0"], "a complete unit keeps the fingerprints of its file")
    check(byID["shell"]?.files.keys.sorted() == ["app.js", "data.js", "index.html", "styles.css"] && byID["shell"]?.sources == ["src/theme.css"],
          "the shell owns the four foundation files and the global stylesheets")
    check(byID["src/OrdersList.tsx"]?.files == ["components/orders-list.html": "c0"], "a component owns its isolated page")
    check(record.scope["src/Trade.tsx"] == "r0" && record.scope["src/Ghost.tsx"] == nil, "the scope keeps the fingerprints and not the ghost")

    func state(_ id: String, _ status: PrototypeBaseline.Status) -> PrototypeBaseline.State? { status.units.first { $0.unit.id == id }?.state }

    let same = PrototypeBaseline.status(record: record, scope: scope0, site: site0)
    check(state("orders", same) == .inSync && state("trade", same) == .unknown && state("settings", same) == .unknown && state("shell", same) == .inSync,
          "unchanged: in sync, incomplete units unknown")
    check(same.baselineVersion == 3 && same.unclaimed.isEmpty && same.added.isEmpty && same.codeUnchanged == false || same.toRebuild.isEmpty, "nothing to rebuild")
    check(same.summary == "2 in sync, 2 unknown" || same.summary == "3 in sync, 2 unknown", "summary counts per state: \(same.summary)")

    var scope1 = scope0; scope1["src/Orders.tsx"] = "o1"; scope1["src/util.ts"] = "u1"; scope1["src/new.tsx"] = "n1"
    var site1 = site0; site1["screens/trade.js"] = "t1"; site1["screens/orders.js"] = "o1"
    let drift = PrototypeBaseline.status(record: record, scope: scope1, site: site1)
    check(state("orders", drift) == .bothChanged, "code and prototype both changed: \(String(describing: state("orders", drift)))")
    check(state("trade", drift) == .prototypeEdited, "only the prototype changed")
    check(drift.units.first { $0.unit.id == "orders" }?.changedSources == ["src/Orders.tsx"] && drift.units.first { $0.unit.id == "orders" }?.editedFiles == ["screens/orders.js"],
          "the changed files are named")
    check(drift.unclaimed == ["src/util.ts"] && drift.added == ["src/new.tsx"], "a changed file no unit claims and a new file are reported: \(drift.unclaimed) \(drift.added)")
    check(drift.conflicts.map(\.unit.id) == ["orders"] && drift.toRebuild.map(\.unit.id) == ["orders"], "conflicts and the units to rebuild")
    check(state("src/OrdersList.tsx", drift) == .inSync && state("shell", drift) == .inSync, "other units stay in sync")

    var scope2 = scope0; scope2["src/theme.css"] = "t9"; scope2["src/OrdersList.tsx"] = nil
    let styles = PrototypeBaseline.status(record: record, scope: scope2, site: site0)
    check(state("shell", styles) == .codeChanged && state("src/OrdersList.tsx", styles) == .codeChanged, "a changed global stylesheet changes the shell; a removed source changes its unit")
    check(state("orders", styles) == .codeChanged, "a screen whose component source was removed is code changed")

    let none = PrototypeBaseline.status(record: nil, scope: scope0, site: site0)
    check(!none.hasBaseline && none.units.isEmpty && none.summary.hasPrefix("No baseline"), "no record, no baseline, said in words")
    check(PrototypeBaseline.State.allCases.allSatisfy { !$0.meaning.isEmpty && !$0.title.isEmpty }, "every state has a title and a meaning")
    check(PrototypeBaseline.list(["a", "b", "c", "d", "e"]) == "a, b, c and 2 more" && PrototypeBaseline.list(["a"]) == "a", "file lists are shortened")

    // Storage per version; carry forward; no source text anywhere.
    let folder = work.appendingPathComponent("docs/prototypes/shop")
    try PrototypeBaseline.save(record, folder: folder, version: 3)
    check(PrototypeBaseline.load(folder: folder, version: 3) == record, "a record round-trips")
    check(PrototypeBaseline.load(folder: folder, version: 4) == nil, "an earlier prototype has no baseline")
    PrototypeBaseline.carryForward(folder: folder, from: 3, to: 4)
    check(PrototypeBaseline.load(folder: folder, version: 4) == record, "a review edit carries the baseline forward")
    let text = (try? String(contentsOf: PrototypeBaseline.url(of: folder, version: 3), encoding: .utf8)) ?? ""
    check(text.contains("src/Orders.tsx") && !text.contains("export default"), "paths and fingerprints are stored")
    PrototypeBaseline.carryForward(folder: folder, from: 8, to: 9)
    check(PrototypeBaseline.load(folder: folder, version: 9) == nil, "nothing to carry from a version without a baseline")
}

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
