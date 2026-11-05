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

// MARK: Operations: moving

try! map.moveVisual(id: search, x: 120, y: -40)
check("visual move keeps the parent", map.node(search)!.parent == "n1" && map.node(search)!.x == 120 && map.node(search)!.y == -40)
check("visual move outside the map refused", rejected { try map.moveVisual(id: search, x: 5_000_000, y: 0) } != nil)

var moved = map
try! moved.reparent(id: nav, to: search)
check("reparent moves the branch", moved.node(nav)!.parent == search && moved.node(large)!.parent == nav)
check("reparent keeps the outline in order", moved.nodes.map(\.id) == ["n1", "n3", "n2", "n4"])
check("reparent clears the manual position of the moved node", { var m = map; try! m.moveVisual(id: nav, x: 1, y: 2); try! m.reparent(id: nav, to: search); return m.node(nav)!.x == nil }())
check("reparent keeps the descendants' positions", { var m = map; try! m.moveVisual(id: large, x: 7, y: 8); try! m.reparent(id: nav, to: search); return m.node(large)!.x == 7 }())
check("cannot move a branch under itself", rejected { try map.reparent(id: nav, to: nav) } != nil)
check("cannot move a branch under its own descendant", rejected { try map.reparent(id: nav, to: large) } != nil)
check("root cannot move", rejected { try map.reparent(id: "n1", to: search) } != nil)
check("reparent to the same parent is a no-op", { var m = map; try! m.reparent(id: nav, to: "n1"); return m == map }())
check("reparent to a missing node refused", rejected { try map.reparent(id: nav, to: "n77") } != nil)

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

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
