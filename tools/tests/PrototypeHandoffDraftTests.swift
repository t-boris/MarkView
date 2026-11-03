import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
}

let entries = [PrototypeFiles.Entry(version: 5, instruction: "Bigger trade button", summary: "The button is larger.", date: Date()),
               PrototypeFiles.Entry(version: 6, instruction: "Show strikes in a column", summary: "", date: Date())]
let trade = PrototypeHandoff.Item(id: "trade", name: "Trade", kind: .screen, files: ["screens/trade.js"], components: ["src/Trade.tsx"], alsoChangedInCode: ["src/Trade.tsx"])
let shell = PrototypeHandoff.Item(id: "shell", name: "Shell", kind: .foundation, files: ["styles.css"], components: [], alsoChangedInCode: [])
let badge = PrototypeHandoff.Item(id: "src/ui/Badge.tsx", name: "Badge", kind: .component, files: ["components/badge.html"], components: [], alsoChangedInCode: [])
let changes = PrototypeHandoff.Changes(baselineVersion: 3, items: [trade, shell, badge], history: entries, codeChanged: ["src/Trade.tsx"])

// The draft: one unit per change, the fallback text, nothing without a baseline or changes.
let draft = PrototypeHandoff.draft(prototypeTitle: "Shop", slug: "shop", version: 7, changes: changes)!
check(draft.units.map(\.id) == ["trade", "shell", "src/ui/Badge.tsx"] && draft.baselineVersion == 3 && draft.version == 7, "a unit per changed screen, component and the shell")
check(draft.units.allSatisfy { !$0.described && $0.before == .pending && $0.after == .pending }, "nothing is described or photographed yet")
check(draft.units[0].changes.count == 3 && draft.units[0].changes[0].contains("screens/trade.js")
      && draft.units[0].changes[1] == "Requested in the prototype (v5): Bigger trade button Result: The button is larger."
      && draft.units[0].changes[2] == "Requested in the prototype (v6): Show strikes in a column", "the fallback names the files and every request since the baseline")
check(PrototypeHandoff.draft(prototypeTitle: "Shop", slug: "shop", version: 7, changes: .init(baselineVersion: nil, items: [trade], history: [], codeChanged: [])) == nil, "no baseline, no draft")
check(PrototypeHandoff.draft(prototypeTitle: "Shop", slug: "shop", version: 7, changes: .init(baselineVersion: 3, items: [], history: [], codeChanged: [])) == nil, "nothing changed, no draft")

// What to render and what to call the file.
check(PrototypeHandoff.shotTarget(of: draft.units[0], componentPage: nil) == (screen: "trade", page: nil), "a screen is shown by its id")
check(PrototypeHandoff.shotTarget(of: draft.units[1], componentPage: nil) == (screen: nil, page: nil), "the shell shows the first screen")
check(PrototypeHandoff.shotTarget(of: draft.units[2], componentPage: "components/badge.html") == (screen: nil, page: "components/badge.html"), "a component is shown by its page")
check(PrototypeHandoff.shotFileName(unitID: draft.units[2].id, side: "before") == "src-ui-badge-tsx-before.png" && PrototypeHandoff.shotFileName(unitID: draft.units[0].id, side: "after") == "trade-after.png", "file names are safe and apart")
var odd = draft.units[0]; odd.id = "../../Ünï/ ??"
check(PrototypeHandoff.shotFileName(unitID: odd.id, side: "after") == "ünï-after.png" || PrototypeHandoff.shotFileName(unitID: odd.id, side: "after") == "n-after.png", "an unsafe id stays inside the folder: \(PrototypeHandoff.shotFileName(unitID: odd.id, side: "after"))")
odd.id = "///"
check(PrototypeHandoff.shotFileName(unitID: odd.id, side: "before") == "unit-before.png", "an id with no letters still gets a name")

// The feature text.
let idea = PrototypeHandoff.featureIdea(draft)
check(idea.contains("\"Shop\" prototype (v7)") && idea.contains("(v3)") && idea.contains("do not copy the prototype's markup") && idea.contains("Sync from code")
      && idea.contains("v5 \"Bigger trade button\"; v6 \"Show strikes in a column\""), "the idea says where it comes from, how to build and the way back")
check(PrototypeHandoff.requirementTitle(draft.units[0]) == "Trade matches the prototype" && PrototypeHandoff.requirementTitle(draft.units[1]) == "The application shell matches the prototype"
      && PrototypeHandoff.requirementTitle(draft.units[2]) == "Badge component matches the prototype", "a title per kind of unit")
check(PrototypeHandoff.requirementStatement(draft.units[0], draft: draft) == "The application shall show Trade as the \"Shop\" prototype v7 does, in the source component `src/Trade.tsx`.", "the statement names the component")
check(PrototypeHandoff.requirementStatement(draft.units[1], draft: draft) == "The application shall show its shell as the \"Shop\" prototype v7 does.", "the shell statement has no component")

// Criteria: the changes, the picture check when there is a picture, the conflict.
var unit = draft.units[0]
unit.changes = ["  Strikes: show them in a column. Check: five rows.  ", "", "Button: larger."]
unit.after = .taken("docs/features/x/references/SRC-001-trade-after.png")
let criteria = PrototypeHandoff.requirementCriteria(unit)
check(criteria.count == 4 && criteria[0] == "Strikes: show them in a column. Check: five rows." && criteria[1] == "Button: larger."
      && criteria[2].contains("\"after\" picture of Trade") && criteria[3].contains("`src/Trade.tsx`") && criteria[3].contains("reconcile"), "criteria: trimmed changes, picture check, conflict: \(criteria)")
unit.after = .skipped("no screen"); unit.alsoChangedInCode = []
check(PrototypeHandoff.requirementCriteria(unit).count == 2, "no picture and no conflict: only the changes")
unit.changes = []
check(PrototypeHandoff.requirementCriteria(unit).isEmpty, "a unit with nothing to say has no criteria (the writer must handle that)")

// The brief carries the draft.
var drawn = draft
drawn.units[0].changes = ["Strikes: show them in a column."]
drawn.units[0].before = .taken("docs/f/before.png"); drawn.units[0].after = .taken("docs/f/after.png")
let plain = PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: changes)
let rich = PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: changes, draft: drawn)
check(rich.contains("  - Strikes: show them in a column.\n") && rich.contains("  - Pictures: before: `docs/f/before.png`, after: `docs/f/after.png`\n"), "the brief lists what to change and the pictures")
check(plain == PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: changes, draft: nil)
      && rich.count > plain.count, "no draft: the brief is as before")

// The description: schema, prompt, parser.
check((PrototypeHandoff.describeSchema["required"] as? [String]) == ["changes"], "the schema asks for the changes")
let prompt = PrototypeHandoff.describePrompt(unit: drawn.units[0], draft: drawn, beforeFiles: ["docs/p/versions/v3/screens/trade.js"], afterFiles: ["docs/p/site/screens/trade.js"], diff: "- a\n+ b\n")
check(prompt.contains("Trade") && prompt.contains("v3") && prompt.contains("v7") && prompt.contains("src/Trade.tsx") && prompt.contains("v5: Bigger trade button")
      && prompt.contains("`docs/p/versions/v3/screens/trade.js`") && prompt.contains("Picture before: `docs/f/before.png`") && prompt.contains("```diff\n- a\n+ b\n\n```"), "the prompt names the unit, versions, requests, files, pictures and the difference")
let fresh = PrototypeHandoff.describePrompt(unit: drawn.units[1], draft: drawn, beforeFiles: [], afterFiles: ["docs/p/site/styles.css"], diff: "")
check(fresh.contains("none (the unit is new)") && fresh.contains("(no textual difference)") && fresh.contains("The shell"), "a new unit and an empty difference are said")
let answer: [String: Any] = ["changes": [["where": "Chain header", "what": "Add a Strike column between the sides.", "check": "The strike is in the middle."],
                                         ["where": "", "what": "Rename GO to Trade.", "check": ""], ["where": "x", "what": "  ", "check": "y"]]]
check(PrototypeHandoff.parseDescription(answer) == ["Chain header: Add a Strike column between the sides. Check: The strike is in the middle.", "Rename GO to Trade."],
      "an answer becomes lines; an entry with no change is dropped: \(String(describing: PrototypeHandoff.parseDescription(answer)))")
check(PrototypeHandoff.parseDescription(["changes": []]) == [] && PrototypeHandoff.parseDescription(["nope": 1]) == nil && PrototypeHandoff.parseDescription(nil) == nil, "empty is empty, a wrong shape is nil")

// The line difference.
check(PrototypeHandoff.lineDiff(before: "a\nb\nc", after: "a\nb\nc").isEmpty, "equal texts: no difference")
let diff = PrototypeHandoff.lineDiff(before: "1\n2\n3\n4\n5\n6\n7\n8\n9\n10", after: "1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n10", context: 1)
check(diff == "…\n  4\n- 5\n+ FIVE\n  6\n", "one changed line with one line of context each side: \(diff.debugDescription)")
let added = PrototypeHandoff.lineDiff(before: "a", after: "a\nb\nc", context: 0)
check(added == "+ b\n+ c\n" || added == "…\n+ b\n+ c\n", "added lines: \(added.debugDescription)")
let big = PrototypeHandoff.lineDiff(before: "", after: (0..<5000).map { "line \($0)" }.joined(separator: "\n"), limit: 500)
check(big.count < 600 && big.hasSuffix("… (cut)"), "a long difference is cut")

// The plan for the feature.
var planned = drawn
planned.units[1].changes = []
let plan = PrototypeHandoff.featurePlan(planned)
check(plan.title == "Match the code to the Shop prototype" && plan.provenance == "Created from prototype shop v7" && plan.requirements.count == 3, "the plan: title, provenance, a requirement per unit")
check(plan.requirements[0].criteria.count == 3 && plan.requirements[1].criteria == ["The application shell in the application matches the prototype (v7)."]
      && !plan.requirements[2].criteria.isEmpty, "a requirement always has a criterion, even when nothing was described: \(plan.requirements[1].criteria)")
check(plan.pictures.count == 2 && plan.pictures[0] == .init(unitID: "trade", side: "before", title: "Trade before (prototype v3)", file: "docs/f/before.png")
      && plan.pictures[1].title == "Trade after (prototype v7)", "a picture per taken shot, titled with the prototype version it shows")
check(plan.overview.hasPrefix("# Match the code to the Shop prototype\n\n## Idea\n\n") && plan.overview.contains("- Trade (screen): also changed in the code since the sync, reconcile\n")
      && plan.overview.contains("- Shell (shell)\n") && plan.overview.contains("- Badge (component)\n"), "the overview lists the units and the conflict")
check(PrototypeHandoff.screenshotsSection([]) == "" && PrototypeHandoff.screenshotsSection([(title: "T before", link: "../references/SRC-001-t.png")]) == "\n## Screenshots\n\n**T before**\n\n![T before](../references/SRC-001-t.png)\n", "the screenshots section")

// The files of a unit.
let files = ["a.js": ("1\n2", "1\nTWO"), "gone.js": ("x", nil as String?), "same.js": ("s", "s")]
let fileDiff = PrototypeHandoff.unitDiff(files: ["same.js", "a.js", "gone.js", "new.js", "nothing.js"],
                                         before: { files[$0]?.0 ?? ($0 == "new.js" ? nil : nil) },
                                         after: { $0 == "new.js" ? "n" : ($0 == "same.js" ? "s" : files[$0]?.1 ?? nil) })
check(fileDiff == "--- a.js\n  1\n- 2\n+ TWO\n--- gone.js\n(removed)\n- x\n--- new.js\n(new file)\n+ n\n", "a changed, a removed and a new file are told apart; an equal and a missing one are skipped: \(fileDiff.debugDescription)")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
