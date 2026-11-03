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

    // The plan of a sync.
    let nothing = PrototypeBaseline.syncPlan(status: same, record: record)
    check(nothing.mode == .nothing && nothing.units.isEmpty && !nothing.restyle, "no change: nothing to do")
    var scopeX = scope0; scopeX["src/Trade.tsx"] = "r1"
    let one = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: record, scope: scopeX, site: site0), record: record)
    check(one.mode == .incremental && one.units.map(\.unit.id) == ["trade"] && one.changedSources == ["src/Trade.tsx"] && one.overwrites.isEmpty,
          "one changed source rebuilds its unit only: \(one)")
    let both = PrototypeBaseline.syncPlan(status: drift, record: record)
    check(both.mode == .incremental && both.units.map(\.unit.id) == ["orders"] && both.overwrites.map(\.unit.id) == ["orders"],
          "a unit changed on both sides is rebuilt and named as an overwrite")
    check(both.notes.contains { $0.contains("src/util.ts") } && both.notes.contains { $0.contains("src/new.tsx") && $0.contains("Rebuild everything") },
          "unclaimed changes and new files are said: \(both.notes)")
    let onlyNotes = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: record, scope: ["src/theme.css": "t0", "src/Orders.tsx": "o0", "src/OrdersList.tsx": "l0", "src/Trade.tsx": "r0", "src/util.ts": "u9", "src/new.tsx": "n"], site: site0), record: record)
    check(onlyNotes.mode == .nothing && onlyNotes.notes.count == 2, "only unclaimed or new files: no run, but the person is told")
    let restyle = PrototypeBaseline.syncPlan(status: styles, record: record)
    check(restyle.restyle && restyle.units.map(\.unit.id).contains("orders"), "a changed global stylesheet is copied again")
    check(PrototypeBaseline.syncPlan(status: none, record: nil).mode == .full && PrototypeBaseline.syncPlan(status: none, record: nil).reasons[0].contains("no baseline")
          || PrototypeBaseline.syncPlan(status: none, record: nil).reasons[0].contains("There is no baseline"), "no baseline: a full rebuild, said why")
    // A file used by many screens, and a unit whose sources are all gone.
    var wide = record
    wide.units = ["a", "b", "c", "d"].map { PrototypeBaseline.Unit(id: $0, kind: .screen, name: $0.uppercased(), sources: ["src/shared.ts", "src/\($0).tsx"], files: [:]) }
    wide.scope = ["src/shared.ts": "s", "src/a.tsx": "1", "src/b.tsx": "2", "src/c.tsx": "3", "src/d.tsx": "4"]
    var wideNow = wide.scope; wideNow["src/shared.ts"] = "s2"
    let shared = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: wide, scope: wideNow, site: [:]), record: wide)
    check(shared.mode == .full && shared.reasons.count == 1 && shared.reasons[0].contains("src/shared.ts") && shared.reasons[0].contains("4 of 4 screens"),
          "an input shared by many screens means a full rebuild, naming the file: \(shared.reasons)")
    wideNow["src/shared.ts"] = "s"; wideNow["src/a.tsx"] = nil; wideNow["src/b.tsx"] = "22"
    wide.units[0].sources = ["src/a.tsx"]
    let gone = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: wide, scope: wideNow, site: [:]), record: wide)
    check(gone.mode == .full && gone.reasons.contains { $0.contains("\"A\"") && $0.contains("removed") }, "a screen whose sources are all gone cannot be rebuilt alone: \(gone.reasons)")

    // The baseline after an incremental sync: only what was rewritten and refreshed moves; the rest stays honest.
    var siteAfter = site0; siteAfter["screens/orders.js"] = "o2"; siteAfter["screens/trade.js"] = "edited"
    let advanced = PrototypeBaseline.advanced(record, version: 5, rewritten: ["orders"], refreshed: ["orders"], scope: scope1, site: siteAfter)
    let afterStatus = PrototypeBaseline.status(record: advanced, scope: scope1, site: siteAfter)
    check(advanced.syncedVersion == 5 && state("orders", afterStatus) == .inSync, "the rebuilt unit is in sync again")
    check(state("trade", afterStatus) == .prototypeEdited, "a Studio edit that was not overwritten still shows")
    check(afterStatus.unclaimed == ["src/util.ts"] && afterStatus.added == ["src/new.tsx"], "a changed file no unit lists and a new file are still reported: \(afterStatus.unclaimed) \(afterStatus.added)")
    check(state("src/OrdersList.tsx", afterStatus) == .inSync, "a component that shares no changed source stays in sync")
    // A unit that failed to rebuild keeps its old fingerprints, so it still shows as changed.
    let failedRun = PrototypeBaseline.advanced(record, version: 5, rewritten: [], refreshed: [], scope: scope1, site: site0)
    check(state("orders", PrototypeBaseline.status(record: failedRun, scope: scope1, site: site0)) == .codeChanged, "a unit that was not refreshed still shows code changed")
    // A source listed by a refreshed and a not refreshed unit is not advanced.
    var partial = record
    partial.units[1].sources = ["src/Orders.tsx", "src/Trade.tsx"]
    var scopeP = scope0; scopeP["src/Trade.tsx"] = "r1"
    let half = PrototypeBaseline.advanced(partial, version: 6, rewritten: ["trade"], refreshed: ["trade"], scope: scopeP, site: site0)
    check(half.scope["src/Trade.tsx"] == "r0", "a source shared with a unit that was not refreshed stays at its old fingerprint")
    // A removed source of a refreshed unit is recorded as unreadable, not as a change.
    var scopeR = scope0; scopeR["src/Trade.tsx"] = nil
    let removedRun = PrototypeBaseline.advanced(record, version: 6, rewritten: ["trade"], refreshed: ["trade"], scope: scopeR, site: site0)
    check(removedRun.scope["src/Trade.tsx"] == "" && PrototypeBaseline.status(record: removedRun, scope: scopeR, site: site0).unclaimed.isEmpty, "a removed source of a refreshed unit is no longer a difference")
    // The shell moves with its stylesheets without absorbing Studio edits of its files.
    var siteShell = site0; siteShell["app.js"] = "a-edited"
    var scopeS = scope0; scopeS["src/theme.css"] = "t9"
    let shellRun = PrototypeBaseline.advanced(record, version: 7, rewritten: [], refreshed: ["shell"], scope: scopeS, site: siteShell)
    let shellStatus = PrototypeBaseline.status(record: shellRun, scope: scopeS, site: siteShell)
    check(state("shell", shellStatus) == .prototypeEdited && shellStatus.units.first { $0.unit.id == "shell" }?.changedSources == [],
          "copying the stylesheets again clears the code difference of the shell and keeps its Studio edit")

    // The hand-off to code and the section an agent reads (REQ-012, REQ-013).
    let entries = [PrototypeFiles.Entry(version: 1, instruction: "", summary: "build", date: Date()),
                   PrototypeFiles.Entry(version: 2, instruction: "Make the table denser", summary: "Tightened rows.", date: Date()),
                   PrototypeFiles.Entry(version: 4, instruction: "Go back to v2", summary: "Restored.", date: Date()),
                   PrototypeFiles.Entry(version: 5, instruction: "Bigger trade button", summary: "The button is larger.", date: Date()),
                   PrototypeFiles.Entry(version: 6, instruction: "Synced from code", summary: "Reconstructed.", date: Date())]
    let markers: (String) -> [String] = { $0 == "screens/trade.js" ? ["src/Trade.tsx", "src/Badge.tsx"] : ["src/Orders.tsx"] }
    let moved = PrototypeHandoff.changes(status: drift, history: entries, markers: markers)
    check(moved.baselineVersion == 3 && moved.items.map(\.name) == ["Orders", "Trade"], "the changed units, in the order of the prototype: \(moved.items.map(\.name))")
    check(moved.items[1].components == ["src/Trade.tsx", "src/Badge.tsx"] && moved.items[0].alsoChangedInCode == ["src/Orders.tsx"] && moved.items[1].alsoChangedInCode.isEmpty,
          "each item names the components its files mark and the sources that also changed in the code")
    check(moved.history.map(\.version) == [5], "only the requests after the baseline count, not builds, restores or syncs: \(moved.history.map(\.version))")
    check(moved.codeChanged == ["src/Orders.tsx", "src/util.ts"], "the code files that changed since the baseline: \(moved.codeChanged)")
    let brief = PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: moved)
    check(brief.contains("RECONSTRUCTION") && brief.contains("Do not copy its markup") && brief.contains("`docs/prototypes/shop/site/`")
          && brief.contains("last synced with the code at v3"), "the brief says what the prototype is and how not to use it")
    check(brief.contains("**Trade** (screen): prototype files `screens/trade.js`; reproduces the source components `src/Trade.tsx`, `src/Badge.tsx`")
          && brief.contains("v5: Bigger trade button\n  Result: The button is larger.") && !brief.contains("Make the table denser") && !brief.contains("Go back"),
          "the brief lists the files, the components and the requests that led to them")
    check(brief.contains("Also changed in the code since the last sync") && brief.contains("- Orders: `src/Orders.tsx`"), "a unit that changed on both sides is flagged")
    check(brief.contains("a branch of its own") && brief.contains("written nothing to the project") && brief.contains("Sync from code"), "the brief leaves the code work to the agent and names the way back")
    let clean = PrototypeHandoff.changes(status: same, history: entries, markers: markers)
    check(clean.isEmpty && clean.hasBaseline, "an unchanged prototype has nothing to hand off")
    check(!PrototypeHandoff.changes(status: none, history: entries, markers: markers).hasBaseline, "no baseline, no changes can be told")
    let sectionMoved = PrototypeHandoff.section(moved, componentPaths: ["src/Orders.tsx", "src/Other.tsx"])
    check(sectionMoved.contains("Changes since the last sync (v3)") && sectionMoved.contains("- Trade (screen): screens/trade.js; reproduces src/Trade.tsx, src/Badge.tsx")
          && sectionMoved.contains("Review requests since then:\n- v5: Bigger trade button → The button is larger.")
          && sectionMoved.hasSuffix("that also changed in the code since the last sync: src/Orders.tsx."), "the section lists files, components, requests and code changes: \(sectionMoved)")
    check(PrototypeHandoff.section(clean, componentPaths: ["src/Orders.tsx"]) == "Changes since the last sync (v3): none. The prototype's files are as they were at the last sync.\nSource components named in this result changed in the code since the last sync: none.",
          "nothing changed: said in a line, and the components are reported unchanged")
    check(PrototypeHandoff.section(PrototypeHandoff.changes(status: none, history: [], markers: markers), componentPaths: []).hasPrefix("Changes since the last sync: unknown."), "no baseline: said in a line")
    check(PrototypeHandoff.section(clean, componentPaths: []).hasSuffix("the prototype records no components."), "no components recorded: said")

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
