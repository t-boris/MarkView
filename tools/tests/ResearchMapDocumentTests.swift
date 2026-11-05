// Checks the research map format and rules (MarkView/Models/ResearchMapDocument.swift) against
// REQ-001, REQ-003, REQ-004, DEC-003, DEC-005, DEC-006, DEC-007 and DEC-009.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func rejected(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let r as ResearchMap.Rejection { return r.message } catch { return "other" }
}
typealias M = ResearchMap

func parsed(_ text: String) -> M? {
    if case .success(let map) = M.parse(text) { return map }
    return nil
}

// MARK: A new map

var map = M.new(id: "2026-11-04-docs", question: "How do we make the docs easier?\nSecond line", created: "2026-11-04",
                targets: ["docs/a.md"], attachments: [])
check("new map has one root", map.nodes.count == 1 && map.nodes[0].id == "n1" && map.nodes[0].parent.isEmpty)
check("root titled by the first line of the question", map.title == "How do we make the docs easier?")
check("new map is researching", map.status == .researching)
check("blank question gets a title", M.new(id: "x", question: "  ", created: "d", targets: [], attachments: []).title == "Research")

// MARK: Operations: adding

let nav = try! map.addChild(parent: "n1", title: "Navigation")
let search = try! map.addChild(parent: "n1", title: "Search")
let large = try! map.addChild(parent: nav, title: "Large repositories")
check("ids count up", nav == "n2" && search == "n3" && large == "n4")
check("outline order keeps a branch together", map.nodes.map(\.id) == ["n1", "n2", "n4", "n3"])
check("empty title refused", rejected { try map.addChild(parent: "n1", title: "   ") } != nil)
check("unknown parent refused", rejected { try map.addChild(parent: "n99", title: "x") } != nil)
check("title cut to 120", { var m = map; let id = try! m.addChild(parent: "n1", title: String(repeating: "a", count: 300)); return m.node(id)!.title.count == 120 }())
check("depth", map.depth(of: large) == 2 && map.depth(of: "n1") == 0)
check("descendants", map.descendants(of: "n2") == ["n4"] && map.descendants(of: "n1").count == 3)

// MARK: Operations: properties

try! map.update(id: nav, title: "Project navigation", tags: ["ux", "UX", " docs ", ""], color: "#AABBCC", description: "Find things fast.\n")
check("update title", map.node(nav)!.title == "Project navigation")
check("tags are trimmed and deduplicated", map.node(nav)!.tags == ["ux", "docs"])
check("colour lower-cased", map.node(nav)!.color == "#aabbcc")
check("description trimmed", map.node(nav)!.description == "Find things fast.")
check("bad colour refused", rejected { try map.update(id: nav, color: "red") } != nil)
check("empty colour clears", { var m = map; try! m.update(id: nav, color: ""); return m.node(nav)!.color.isEmpty }())
check("empty title refused on update", rejected { try map.update(id: nav, title: " ") } != nil)
check("root rename renames the map", { var m = map; try! m.update(id: "n1", title: "Docs"); return m.title == "Docs" }())
check("oversized description refused", rejected { try map.update(id: nav, description: String(repeating: "x", count: M.descriptionLimit + 1)) } != nil)

// MARK: Operations: moving (a node moves visually only; there is no move to another branch, DEC-010)

try! map.moveVisual(id: search, x: 120, y: -40)
check("visual move keeps the parent", map.node(search)!.parent == "n1" && map.node(search)!.x == 120 && map.node(search)!.y == -40)
check("visual move outside the map refused", rejected { try map.moveVisual(id: search, x: 5_000_000, y: 0) } != nil)

// MARK: Operations: connections

try! map.link(nav, search)
check("connection added", map.links == [M.Link(from: nav, to: search)])
check("same pair refused", rejected { try map.link(nav, search) } == "This connection already exists.")
check("reverse pair refused", rejected { try map.link(search, nav) } == "This connection already exists.")
check("self connection refused", rejected { try map.link(nav, nav) } != nil)
check("connection to a missing node refused", rejected { try map.link(nav, "n44") } != nil)
check("unlink either direction", { var m = map; m.unlink(search, nav); return m.links.isEmpty }())

// MARK: Operations: delete

var cascade = map
try! cascade.link(large, "n1")
let removed = try! cascade.delete(id: nav)
check("delete removes the branch", removed == 2 && cascade.nodes.map(\.id) == ["n1", "n3"])
check("delete removes the connections of removed nodes", cascade.links.isEmpty)
check("root cannot be deleted", rejected { try map.delete(id: "n1") } != nil)
check("delete keeps other connections", { var m = map; try! m.link(search, "n1"); try! m.delete(id: large); return m.links.count == 2 }())

// MARK: Operations: layouts (DEC-005, DEC-007)

var layouts = map
try! layouts.applyLayout(id: nav, layout: "radial")
try! layouts.moveVisual(id: large, x: 1, y: 1)
try! layouts.applyLayout(id: large, layout: "down")
try! layouts.applyLayout(id: "n1", layout: "right")
check("layout stored on the branch", layouts.node("n1")!.layout == "right")
check("layout of nested branches replaced", layouts.node(nav)!.layout.isEmpty && layouts.node(large)!.layout.isEmpty)
check("manual positions below the branch removed", layouts.node(large)!.x == nil && layouts.node(search)!.x == nil)
check("the branch node keeps its own position", { var m = map; try! m.moveVisual(id: nav, x: 5, y: 6); try! m.applyLayout(id: nav, layout: "up"); return m.node(nav)!.x == 5 }())
check("layout does not touch siblings", { var m = map; try! m.applyLayout(id: nav, layout: "up"); return m.node(search)!.x == 120 }())
check("unknown layout refused", rejected { try layouts.applyLayout(id: nav, layout: "zigzag") } != nil)
check("empty layout clears", { var m = layouts; try! m.applyLayout(id: "n1", layout: ""); return m.node("n1")!.layout.isEmpty }())
check("seven presets", M.layouts.count == 7 && Set(M.layouts.map(\.id)) == ["balanced", "right", "left", "down", "up", "radial", "outline"])

// MARK: Round trip (REQ-001, REQ-003, REQ-004)

var rich = map
try! rich.update(id: nav, description: "Intro paragraph.\n\n## A heading in the description\n### Another {#n2}\n#### Evidence\n\n```sh\n## not structure inside a fence\n```\n\nEnd.")
rich.nodes[rich.index(of: nav)!].evidence = [
    M.Evidence(label: .projectFact, text: "The tree is built here.", source: "src/tree.swift:42"),
    M.Evidence(label: .externalFact, text: "Mind maps have a centre.", source: "https://example.com/mind-maps"),
    M.Evidence(label: .aiInference, text: "Probably useful, maybe", source: ""),
    M.Evidence(label: .openAssumption, text: "Users have large repos.", source: ""),
]
try! rich.applyLayout(id: search, layout: "outline")
try! rich.update(id: search, title: "Search [and] filters")
try! rich.moveVisual(id: large, x: -30, y: 70)
rich.addWebQueries(["mind map research", "mind map research", "docs navigation"])
rich.markIncomplete("timed out after 20 min")
rich.question = "How do we make the docs easier?\nSecond line"
rich.targets = ["docs/a.md"]
rich.attachments = ["docs/research/assets/x/y.png"]
rich.created = "2026-11-04"
rich.id = "2026-11-04-docs"
let text = rich.markdown()
let again = parsed(text)
check("written map is a map", M.isMap(text))
check("round trip equal", again == rich)
check("round trip is stable", again?.markdown() == text)
check("round trip keeps the structural lines of a description", again?.node(nav)?.description == rich.node(nav)!.description)
check("round trip keeps evidence", again?.node(nav)?.evidence == rich.node(nav)!.evidence)
check("round trip keeps titles with brackets", again?.node(search)?.title == "Search [and] filters")
check("round trip keeps status and reason", again?.status == .incomplete && again?.incompleteReason == "timed out after 20 min")
check("round trip keeps queries once", again?.webQueries == ["mind map research", "docs navigation"])
check("round trip keeps positions and layouts", again?.node(large)?.x == -30 && again?.node(search)?.layout == "outline")
check("front matter has the map type", text.hasPrefix("---\ntype: research-map\n"))
check("outline is a nested list with anchors", text.contains("- [How do we make the docs easier?](#n1)\n  - [Project navigation](#n2)\n    - [Large repositories](#n4)\n  - [Search \\[and\\] filters](#n3)"))
check("connection written with both anchors", text.contains("- [Project navigation](#n2) ↔ [Search \\[and\\] filters](#n3)"))
check("evidence written with its labels and sources", text.contains("- [Project fact] The tree is built here. — `src/tree.swift:42`") && text.contains("— <https://example.com/mind-maps>"))
check("a dash in evidence without a source is normalised", { var m = rich; m.nodes[1].evidence = [M.Evidence(label: .aiInference, text: "a — b", source: "")]; return parsed(m.markdown())?.nodes[1].evidence.first?.text == "a – b" }())
check("a dash inside the text of a sourced finding survives", { var m = rich; m.nodes[1].evidence = [M.Evidence(label: .projectFact, text: "a — b — c", source: "src/tree.swift:1")]; return parsed(m.markdown())?.nodes[1].evidence == m.nodes[1].evidence }())
check("empty connection section omitted", !M(front: FrontMatter(), nodes: [M.Node(id: "n1", parent: "", title: "A")]).markdown().contains("## Connections"))

// MARK: Edits outside the map (DEC-006)

let edited = """
---
type: research-map
id: hand
title: Old title
created: 2026-11-04
status: complete
owner: boris
---

# Anything

Some intro text that is not a section.

## Question

Why?

## Map

- [Root](#n1)
  - [First](#n2)
  - A new idea typed by hand
    - [Deeper](#n7)
* [Second top level](#n9)
- [Clone of root](#n1)

## Notes

My own notes stay.

## Connections

- [First](#n2) ↔ [Deeper](#n7)
- [First](#n2) ↔ [First](#n2)
- [Deeper](#n7) ↔ [First](#n2)
- [First](#n2) ↔ [Ghost](#n55)
- plain text

## Nodes

### Root {#n1}

- tags: a, b
- color: #112233

Root text.

### First {#n2}

- layout: zigzag
- position: 10, nope

First text
### Plain heading
still First.

### Orphan {#n40}

Orphan text.
"""
let hand = parsed(edited)!
check("hand edit: root", hand.root?.id == "n1" && hand.root?.title == "Root")
check("hand edit: item without id gets a fresh id above every id in the file, orphan sections included", hand.nodes.contains { $0.title == "A new idea typed by hand" && $0.id == "n41" })
check("hand edit: nested under its parent", hand.node("n41")?.parent == "n1" && hand.node("n7")?.parent == "n41")
check("hand edit: second top-level item hangs under the root", hand.nodes.first { $0.title == "Second top level" }?.parent == "n1")
check("hand edit: repeated id gets a new one", hand.nodes.filter { $0.title == "Clone of root" }.count == 1 && hand.node("n1")?.title == "Root")
check("hand edit: outline order is a pre-order", hand.nodes.map(\.title) == ["Root", "First", "A new idea typed by hand", "Deeper", "Second top level", "Clone of root"])
check("hand edit: properties", hand.node("n1")?.tags == ["a", "b"] && hand.node("n1")?.color == "#112233")
check("hand edit: unknown layout ignored, bad position ignored", hand.node("n2")?.layout == "" && hand.node("n2")?.x == nil)
check("hand edit: a heading without an id stays in the description", hand.node("n2")?.description == "First text\n### Plain heading\nstill First.")
check("hand edit: orphan section dropped with its text", !hand.nodes.contains { $0.id == "n40" } && !hand.markdown().contains("Orphan text"))
check("hand edit: plain headings are not escaped on rewrite", hand.markdown().contains("\n### Plain heading\n"))
check("hand edit: only valid distinct connections", hand.links == [M.Link(from: "n2", to: "n7")])
check("hand edit: unknown section kept", hand.extraSections == ["## Notes\n\nMy own notes stay."])
check("hand edit: unknown front matter kept", hand.markdown().contains("owner: boris"))
check("hand edit: rewritten file reads back the same", parsed(hand.markdown()) == hand)
check("hand edit: question from its section", hand.question == "Why?")
check("hand edit: rewritten file keeps the note section", hand.markdown().contains("## Notes\n\nMy own notes stay."))

// MARK: Not a map

check("other front matter is not a map", { if case .failure = M.parse("---\ntype: research\n---\n\n# T\n") { return true }; return false }())
check("no front matter is not a map", { if case .failure = M.parse("# T\n\n## Map\n\n- a\n") { return true }; return false }())
check("no map list is not a map", { if case .failure(let p) = M.parse("---\ntype: research-map\n---\n\n# T\n"), p.message.contains("Map") { return true }; return false }())
check("empty map list is not a map", { if case .failure = M.parse("---\ntype: research-map\n---\n\n## Map\n\nnothing\n") { return true }; return false }())
check("front matter with a comment is refused", { if case .failure = M.parse("---\ntype: research-map\n# comment\n---\n\n## Map\n\n- a\n") { return true }; return false }())
check("isMap only for the map type", !M.isMap("---\ntype: research\n---\n") && M.isMap("---\ntype: research-map\n---\n"))
check("CRLF files read", parsed("---\r\ntype: research-map\r\n---\r\n\r\n## Map\r\n\r\n- [A](#n1)\r\n  - [B](#n2)\r\n")?.nodes.count == 2)
check("tabs indent the outline", parsed("---\ntype: research-map\n---\n\n## Map\n\n- [A](#n1)\n\t- [B](#n2)\n")?.node("n2")?.parent == "n1")

// MARK: Evidence verification

let files: Set<String> = ["src/tree.swift"]
let exists: (String) -> Bool = { files.contains($0) }
check("project fact with an existing file stays", M.verified(label: .projectFact, text: "Built here", source: "src/tree.swift:3", pathExists: exists).label == .projectFact)
let ghost = M.verified(label: .projectFact, text: "Built there", source: "src/ghost.swift", pathExists: exists)
check("project fact with a missing file becomes inference", ghost.label == .aiInference && ghost.text.contains("labelled as inference"))
check("external fact without a URL becomes inference", M.verified(label: .externalFact, text: "It is so", source: "", pathExists: exists).label == .aiInference)
check("external fact with a URL stays", M.verified(label: .externalFact, text: "It is so", source: "https://example.com/a", pathExists: exists).label == .externalFact)
check("inference stays", M.verified(label: .aiInference, text: "I think", source: "", pathExists: exists).label == .aiInference)

// MARK: Snapshot for the page (DEC-009)

let snap = rich.snapshot(job: M.JobInfo(kind: "research", label: "Research: x", step: "Reading", startedAt: 5), created: "n4", notice: "hello")
let snapJSON = M.json(snap)
let back = try! JSONSerialization.jsonObject(with: Data(snapJSON.utf8)) as! [String: Any]
check("snapshot is ok with the title", back["ok"] as? Bool == true && back["title"] as? String == rich.title)
check("snapshot lists nodes in outline order", (back["nodes"] as? [[String: Any]])?.map { $0["id"] as! String } == rich.nodes.map(\.id))
check("snapshot nodes carry null positions", ((back["nodes"] as? [[String: Any]])?.first?["x"]) is NSNull)
check("snapshot carries evidence labels", ((back["nodes"] as? [[String: Any]])?.first { $0["id"] as? String == "n2" }?["evidence"] as? [[String: String]])?.first?["label"] == "Project fact")
check("snapshot carries links, layouts, queries", (back["links"] as? [Any])?.count == 1 && (back["layouts"] as? [Any])?.count == 7 && (back["webQueries"] as? [String])?.count == 2)
check("snapshot carries the job and the answer fields", (back["job"] as? [String: Any])?["step"] as? String == "Reading" && back["created"] as? String == "n4" && back["notice"] as? String == "hello")
check("snapshot without a job has null", (try! JSONSerialization.jsonObject(with: Data(M.json(rich.snapshot()).utf8)) as! [String: Any])["job"] is NSNull)
let bad = try! JSONSerialization.jsonObject(with: Data(M.json(M.unreadableSnapshot(problem: "No map")).utf8)) as! [String: Any]
check("unreadable snapshot says why", bad["ok"] as? Bool == false && bad["problem"] as? String == "No map")
check("line separators are escaped for JavaScript", !M.json(["a": "x\u{2028}y"]).contains("\u{2028}"))

// MARK: Status

var status = M.new(id: "x", question: "Q", created: "d", targets: [], attachments: [])
status.markIncomplete("cancelled\nafter 1:02")
check("incomplete keeps the reason on one line", status.status == .incomplete && status.incompleteReason == "cancelled after 1:02")
status.markResearching()
check("researching clears the reason", status.status == .researching && status.incompleteReason.isEmpty)
status.markComplete()
check("complete", status.status == .complete && parsed(status.markdown())?.status == .complete)

// MARK: Icons and numbers (REQ-008, DEC-011)

var badges = M.new(id: "b", question: "Q", created: "d", targets: [], attachments: [])
let stepA = try! badges.addChild(parent: "n1", title: "Plan")
let stepB = try! badges.addChild(parent: "n1", title: "Build")
let stepC = try! badges.addChild(parent: "n1", title: "Ship")
let deep = try! badges.addChild(parent: stepB, title: "Compile")
check("a new node has no icon and no number", badges.node(stepA)!.icon.isEmpty && badges.node(stepA)!.number == nil)
try! badges.update(id: stepA, icon: "bug", number: .some(1))
check("a built-in icon and a number are set", badges.node(stepA)!.icon == "bug" && badges.node(stepA)!.number == 1)
try! badges.update(id: stepB, icon: "🔥")
check("one emoji is an icon", badges.node(stepB)!.icon == "🔥")
for emoji in ["❤️", "👩‍💻", "🇩🇪", "1️⃣"] { check("\(emoji) is accepted as one emoji", M.isIcon(emoji)) }
for bad in ["", "a", "1", "ab", "🔥🔥", "nonsense", "<b>", "🔥 x", "bug icon"] { check("'\(bad)' is not an icon", !M.isIcon(bad)) }
check("an unknown icon is refused with a message", rejected { try badges.update(id: stepC, icon: "nonsense") } != nil && badges.node(stepC)!.icon.isEmpty)
check("an icon is trimmed", { var m = badges; try! m.update(id: stepC, icon: "  star \n"); return m.node(stepC)!.icon == "star" }())
try! badges.update(id: stepA, icon: "")
check("an empty icon clears it", badges.node(stepA)!.icon.isEmpty && badges.node(stepA)!.number == 1)
check("a number outside 1…999 is refused", rejected { try badges.update(id: stepA, number: .some(0)) } != nil && rejected { try badges.update(id: stepA, number: .some(1000)) } != nil && rejected { try badges.update(id: stepA, number: .some(-3)) } != nil && badges.node(stepA)!.number == 1)
try! badges.update(id: stepA, number: .some(nil))
check("a nil number clears it", badges.node(stepA)!.number == nil)
try! badges.update(id: stepA, title: "Plan it")
check("leaving icon and number out changes neither", badges.node(stepB)!.icon == "🔥" && { var m = badges; try! m.update(id: stepB, number: .some(7)); try! m.update(id: stepB, title: "Build it"); return m.node(stepB)!.number == 7 }())

let changed = try! badges.numberChildren(of: "n1")
check("Number children numbers the children 1, 2, 3 in map order and nothing deeper", changed == 3 && [stepA, stepB, stepC].map { badges.node($0)!.number } == [1, 2, 3] && badges.node(deep)!.number == nil && badges.node("n1")!.number == nil)
check("numbering again changes nothing", try! badges.numberChildren(of: "n1") == 0)
try! badges.update(id: stepC, number: .some(9))
check("a hand-set number is renumbered by the action", try! badges.numberChildren(of: "n1") == 1 && badges.node(stepC)!.number == 3)
check("Remove numbers clears only the children", try! badges.numberChildren(of: "n1", clear: true) == 3 && [stepA, stepB, stepC].allSatisfy { badges.node($0)!.number == nil })
check("numbering a node that is gone is refused", rejected { _ = try badges.numberChildren(of: "zz") } != nil)

try! badges.update(id: stepA, icon: "rocket", number: .some(1))
try! badges.update(id: stepB, icon: "🔥", number: .some(2))
let stored = badges.markdown()
check("the file stores the icon and the number as properties", stored.contains("- icon: rocket") && stored.contains("- number: 1") && stored.contains("- icon: 🔥") && stored.contains("- number: 2"))
let badgeBack = parsed(stored)
check("icons and numbers survive a rewrite", badgeBack?.node(stepA)?.icon == "rocket" && badgeBack?.node(stepA)?.number == 1 && badgeBack?.node(stepB)?.icon == "🔥" && badgeBack?.node(stepB)?.number == 2 && badgeBack == badges)
check("a node without them writes neither line", !stored.components(separatedBy: "\n").contains { $0.hasPrefix("- icon: ") && $0.contains("star") })
let hostile = stored.replacingOccurrences(of: "- icon: rocket", with: "- icon: <script>").replacingOccurrences(of: "- number: 2", with: "- number: 99999")
let sanitised = parsed(hostile)
check("a bad icon or number in a hand-edited file is dropped on read, the rest is kept", sanitised?.node(stepA)?.icon == "" && sanitised?.node(stepB)?.number == nil && sanitised?.node(stepA)?.number == 1 && sanitised?.node(stepB)?.icon == "🔥")
check("a map written before icons existed reads as it did", { var m = badges; for i in m.nodes.indices { m.nodes[i].icon = ""; m.nodes[i].number = nil }; let text = m.markdown(); return !text.contains("- icon:") && !text.contains("- number:") && parsed(text) == m }())
let badgeSnap = badges.snapshot()
let snapNodes = badgeSnap["nodes"] as? [[String: Any]] ?? []
check("the snapshot carries icon and number (null when there is none)", snapNodes.first { ($0["id"] as? String) == stepA }?["number"] as? Int == 1 && snapNodes.first { ($0["id"] as? String) == stepA }?["icon"] as? String == "rocket" && snapNodes.first { ($0["id"] as? String) == "n1" }?["number"] is NSNull)
check("the snapshot lists the built-in icon ids", (badgeSnap["icons"] as? [String]) == M.iconIDs && Set(M.iconIDs).count == M.iconIDs.count && M.iconIDs.count == 41)
check("a draft with a number sets it; an invalid one is dropped", { var m = badges; let a = try! m.addNode(parent: "n1", draft: M.Draft(title: "A", number: 4)); let b = try! m.addNode(parent: "n1", draft: M.Draft(title: "B", number: 0)); return m.node(a)!.number == 4 && m.node(b)!.number == nil }())
check("deleting a node takes its icon and number with it", { var m = badges; _ = try! m.delete(id: stepA); return m.node(stepA) == nil && m.nodes.count == badges.nodes.count - 1 }())

// MARK: Shape and size (REQ-009, DEC-012)

var boxes = M.new(id: "s", question: "Q", created: "d", targets: [], attachments: [])
let boxA = try! boxes.addChild(parent: "n1", title: "Decide")
let boxB = try! boxes.addChild(parent: "n1", title: "Build")
check("a new node has the default shape and an automatic size", boxes.node(boxA)!.shape.isEmpty && boxes.node(boxA)!.width == nil && boxes.node(boxA)!.height == nil)
check("the shape list starts with the default and has five shapes with distinct ids", M.shapes.first?.id == M.defaultShape && M.shapes.count == 5 && Set(M.shapes.map { $0.id }).count == 5)
try! boxes.update(id: boxA, shape: "diamond", width: .some(240), height: .some(120))
check("a shape, a width and a height are set", boxes.node(boxA)!.shape == "diamond" && boxes.node(boxA)!.width == 240 && boxes.node(boxA)!.height == 120)
for id in M.shapes.map({ $0.id }) where id != M.defaultShape {
    check("\(id) is stored as it is", { var m = boxes; try! m.update(id: boxB, shape: id); return m.node(boxB)!.shape == id }())
}
check("the default shape is stored as empty", { var m = boxes; try! m.update(id: boxA, shape: "rounded"); return m.node(boxA)!.shape.isEmpty }())
check("an empty shape restores the default", { var m = boxes; try! m.update(id: boxA, shape: ""); return m.node(boxA)!.shape.isEmpty }())
check("a shape is trimmed and case-insensitive", { var m = boxes; try! m.update(id: boxB, shape: "  Ellipse \n"); return m.node(boxB)!.shape == "ellipse" }())
check("an unknown shape is refused with a message", rejected { try boxes.update(id: boxA, shape: "star") } != nil && boxes.node(boxA)!.shape == "diamond")
check("a width outside \(M.widthRange) is refused", rejected { try boxes.update(id: boxA, width: .some(59)) } != nil && rejected { try boxes.update(id: boxA, width: .some(801)) } != nil && rejected { try boxes.update(id: boxA, width: .some(0)) } != nil && boxes.node(boxA)!.width == 240)
check("a height outside \(M.heightRange) is refused", rejected { try boxes.update(id: boxA, height: .some(27)) } != nil && rejected { try boxes.update(id: boxA, height: .some(601)) } != nil && boxes.node(boxA)!.height == 120)
check("the limits themselves are accepted", { var m = boxes; try! m.update(id: boxB, width: .some(60), height: .some(28)); try! m.update(id: boxB, width: .some(800), height: .some(600)); return m.node(boxB)!.width == 800 && m.node(boxB)!.height == 600 }())
check("a refused value changes none of shape, width and height", { var m = boxes; _ = rejected { try m.update(id: boxA, shape: "ellipse", width: .some(300), height: .some(5)) }; return m.node(boxA) == boxes.node(boxA) }())
try! boxes.update(id: boxA, width: .some(nil))
check("a nil width clears only the width", boxes.node(boxA)!.width == nil && boxes.node(boxA)!.height == 120 && boxes.node(boxA)!.shape == "diamond")
try! boxes.update(id: boxA, title: "Decide now")
check("leaving shape and size out changes neither", boxes.node(boxA)!.shape == "diamond" && boxes.node(boxA)!.height == 120)
try! boxes.update(id: boxA, width: .some(240))
try! boxes.update(id: boxB, shape: "pill", height: .some(90))

let boxText = boxes.markdown()
check("the file stores the shape, the width and the height as properties", boxText.contains("- shape: diamond") && boxText.contains("- width: 240") && boxText.contains("- height: 120") && boxText.contains("- shape: pill") && boxText.contains("- height: 90"))
let boxBack = parsed(boxText)
check("shape and size survive a rewrite", boxBack?.node(boxA)?.shape == "diamond" && boxBack?.node(boxA)?.width == 240 && boxBack?.node(boxA)?.height == 120 && boxBack?.node(boxB)?.shape == "pill" && boxBack?.node(boxB)?.width == nil && boxBack == boxes)
check("a node with the default look writes none of the lines", !boxText.components(separatedBy: "\n").contains("- shape: rounded") && { var m = boxes; for i in m.nodes.indices { m.nodes[i].shape = ""; m.nodes[i].width = nil; m.nodes[i].height = nil }; let t = m.markdown(); return !t.contains("- shape:") && !t.contains("- width:") && !t.contains("- height:") && parsed(t) == m }())
let boxHostile = boxText.replacingOccurrences(of: "- shape: diamond", with: "- shape: <script>").replacingOccurrences(of: "- width: 240", with: "- width: 99999").replacingOccurrences(of: "- height: 90", with: "- height: ten")
let boxClean = parsed(boxHostile)
check("a bad shape, width or height in a hand-edited file is dropped on read, the rest is kept", boxClean?.node(boxA)?.shape == "" && boxClean?.node(boxA)?.width == nil && boxClean?.node(boxA)?.height == 120 && boxClean?.node(boxB)?.height == nil && boxClean?.node(boxB)?.shape == "pill")
check("the default shape written by hand reads as the default", parsed(boxText.replacingOccurrences(of: "- shape: pill", with: "- shape: rounded"))?.node(boxB)?.shape == "")
let boxSnap = boxes.snapshot()
let boxNodes = boxSnap["nodes"] as? [[String: Any]] ?? []
let boxNodeA = boxNodes.first { ($0["id"] as? String) == boxA }
check("the snapshot carries shape, width and height (null when automatic)", boxNodeA?["shape"] as? String == "diamond" && boxNodeA?["width"] as? Int == 240 && boxNodeA?["height"] as? Int == 120 && boxNodes.first { ($0["id"] as? String) == "n1" }?["width"] is NSNull && boxNodes.first { ($0["id"] as? String) == boxB }?["width"] is NSNull)
check("the snapshot lists the shapes and the size limits", (boxSnap["shapes"] as? [[String: String]])?.map { $0["id"] ?? "" } == M.shapes.map { $0.id } && ((boxSnap["sizeLimits"] as? [String: Any])?["width"] as? [Int]) == [60, 800] && ((boxSnap["sizeLimits"] as? [String: Any])?["height"] as? [Int]) == [28, 600])
check("a node the AI adds has the default look", { var m = boxes; let a = try! m.addNode(parent: "n1", draft: M.Draft(title: "AI")); return m.node(a)!.shape.isEmpty && m.node(a)!.width == nil && m.node(a)!.height == nil }())
check("an update that names no shape or size leaves a node's look alone", { var m = boxes; try! m.update(id: boxA, title: "Renamed", tags: ["x"], description: "d"); return m.node(boxA)!.shape == "diamond" && m.node(boxA)!.width == 240 && m.node(boxA)!.height == 120 }())
check("deleting a node takes its shape and size with it", { var m = boxes; _ = try! m.delete(id: boxA); return m.node(boxA) == nil }())

// ---- diagram and image nodes (REQ-012, DEC-013) -------------------------------------------------------------------------------------
var vis = M.new(id: "v", question: "Q", created: "d", targets: [], attachments: [])
let visA = try! vis.addChild(parent: "n1", title: "Login flow")
let visB = try! vis.addChild(parent: "n1", title: "Screenshot")
let flowText = "```mermaid\nsequenceDiagram\n  participant U as User\n  participant S as Server\n  U->>S: sign in\n  S-->>U: token\n```\n\nThe flow in short."
check("a new node is a text node", vis.node(visA)!.visual.isEmpty)
try! vis.update(id: visA, description: flowText, visual: "diagram")
try! vis.update(id: visB, description: "![Login screen](images/login.png)", visual: " Image ")
check("a diagram and an image node are set (trimmed, case-insensitive)", vis.node(visA)!.visual == "diagram" && vis.node(visB)!.visual == "image")
check("an unknown visual is refused with a message and changes nothing", rejected { try vis.update(id: visA, visual: "video") } != nil && vis.node(visA)!.visual == "diagram")
check("an empty visual turns the node back into a text node and keeps its description", { var m = vis; try! m.update(id: visA, visual: ""); return m.node(visA)!.visual.isEmpty && m.node(visA)!.description == vis.node(visA)!.description }())
check("leaving visual out changes nothing", { var m = vis; try! m.update(id: visA, title: "Renamed"); return m.node(visA)!.visual == "diagram" }())
let visText = vis.markdown()
check("the file stores the property", visText.contains("- visual: diagram") && visText.contains("- visual: image"))
let visBack = parsed(visText)
check("the visual and the Mermaid fence survive a rewrite", visBack?.node(visA)?.visual == "diagram" && visBack?.node(visA)?.description == vis.node(visA)!.description && visBack == vis)
check("a text node writes no visual line", { var m = vis; for i in m.nodes.indices { m.nodes[i].visual = "" }; return !m.markdown().contains("- visual:") }())
check("a bad visual in a hand-edited file is dropped on read, the rest is kept", parsed(visText.replacingOccurrences(of: "- visual: diagram", with: "- visual: <b>"))?.node(visA)?.visual == "" && parsed(visText.replacingOccurrences(of: "- visual: diagram", with: "- visual: <b>"))?.node(visB)?.visual == "image")
check("the diagram source is the first mermaid fence", M.diagramSource(in: flowText) == "sequenceDiagram\n  participant U as User\n  participant S as Server\n  U->>S: sign in\n  S-->>U: token")
check("text without a mermaid fence has no diagram source, and neither has an unclosed or an empty one", M.diagramSource(in: "just text") == nil && M.diagramSource(in: "```mermaid\nflowchart LR") == nil && M.diagramSource(in: "```mermaid\n```") == nil && M.diagramSource(in: "```swift\nlet a = 1\n```") == nil)
check("the image source is the first Markdown image: alt and address, a title is cut off", M.imageSource(in: "intro ![Login screen](images/login.png \"a title\") and ![second](b.png)")?.alt == "Login screen" && M.imageSource(in: "intro ![Login screen](images/login.png \"a title\")")?.src == "images/login.png")
check("text without an image has no image source", M.imageSource(in: "no picture [link](x.png)") == nil && M.imageSource(in: "![](  )") == nil)
let visNodes = vis.snapshot()["nodes"] as? [[String: Any]] ?? []
check("the snapshot carries the visual", visNodes.first { ($0["id"] as? String) == visA }?["visual"] as? String == "diagram" && visNodes.first { ($0["id"] as? String) == "n1" }?["visual"] as? String == "")
check("the AI describing a text node's description keeps a visual node's kind", { var m = vis; try! m.update(id: visA, description: "A new description."); return m.node(visA)!.visual == "diagram" }())
check("a node the AI adds is a text node", { var m = vis; let a = try! m.addNode(parent: "n1", draft: M.Draft(title: "AI")); return m.node(a)!.visual.isEmpty }())

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
