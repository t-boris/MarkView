// Checks the AI side of research maps (MarkView/Models/ResearchMapRun.swift) against REQ-002,
// REQ-004, DEC-004 and DEC-008: the node-line parser, the guards and the prompts.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
typealias M = ResearchMap
typealias Run = ResearchMapRun

let files: Set<String> = ["src/tree.swift", "docs/guide.md"]
let exists: (String) -> Bool = { files.contains($0) }

func map() -> M { M.new(id: "x", question: "How do we do it?", created: "2026-11-04", targets: [], attachments: []) }
func line(_ ref: String, _ parent: String, _ title: String, extra: String = "") -> String {
    "NODE {\"ref\":\"\(ref)\",\"parent\":\"\(parent)\",\"title\":\"\(title)\"\(extra)}\n"
}

// MARK: Parsing

var run = Run(mode: .research)
let stream = """
I will start by reading the repository.
ROOT {"title":"Docs navigation","description":"Short answer.","tags":["docs"],"evidence":[{"label":"Project fact","text":"The tree is built here.","source":"src/tree.swift:3"}]}
Some narration between nodes.
NODE {"ref":"a","parent":"root","title":"Navigation","description":"d","tags":"ux, search"}
- NODE {"ref":2,"parent":"a","title":"Large repositories","evidence":[{"label":"external fact","text":"Seen elsewhere","source":"https://example.com/x"},{"label":"Bogus","text":"No label","source":""},{"label":"Project fact","text":""}]}
`NODE {"ref":"c","parent":"root","title":"Search"}`
NODE {"ref":"bad","parent":"root"}
NODE {broken json
NODE {"ref":"d","parent":"root","title":"
"""
let whole = run.feed(stream + "\n")
check("narration is ignored", whole.count == 4)
check("root line parsed", { if case .root(let d) = whole[0] { return d.title == "Docs navigation" && d.tags == ["docs"] && d.evidence.count == 1 }; return false }())
check("tags may be a comma string", { if case .node(_, _, let d) = whole[1] { return d.tags == ["ux", "search"] }; return false }())
check("list marker and numeric ref accepted", { if case .node(let ref, let parent, let d) = whole[2] { return ref == "2" && parent == "a" && d.title == "Large repositories" }; return false }())
check("evidence label case ignored, unknown label becomes inference, empty text dropped", { if case .node(_, _, let d) = whole[2] { return d.evidence.map(\.label) == [.externalFact, .aiInference] }; return false }())
check("backticks around a line accepted", { if case .node(let ref, _, _) = whole[3] { return ref == "c" }; return false }())
check("lines without a title or with broken JSON are counted", run.malformedLines == 3)

var chunked = Run(mode: .research)
var events: [Run.Event] = []
for ch in (stream + "\n") { events += chunked.feed(String(ch)) }
check("any chunking gives the same events", events == whole)

var tail = Run(mode: .research)
check("no event before the newline", tail.feed(#"NODE {"ref":"z","parent":"root","title":"Last"}"#).isEmpty)
check("finish reads the last line", tail.finish().count == 1)
check("finish twice yields nothing", tail.finish().isEmpty)
check("a runaway line is discarded", { var r = Run(mode: .research); _ = r.feed(String(repeating: "x", count: 70_000)); return r.feed("\n").isEmpty }())
check("long description cut", { var r = Run(mode: .research); let e = r.feed(line("a", "root", "T", extra: ",\"description\":\"\(String(repeating: "d", count: 9000))\"")); if case .node(_, _, let d) = e[0] { return d.description.count == 4000 }; return false }())

// MARK: Research: applying

var m = map()
var r = Run(mode: .research)
var created = r.apply(whole, to: &m, pathExists: exists)
check("root renamed from the first line", m.root?.title == "Docs navigation" && m.root?.description == "Short answer.")
check("root evidence kept and verified", m.root?.evidence.first?.label == .projectFact)
check("nodes added in order", created.count == 3 && m.nodes.map(\.title) == ["Docs navigation", "Navigation", "Large repositories", "Search"])
check("refs resolve to ids", m.node(created[1])?.parent == created[0])
check("evidence without a real source is relabelled", m.node(created[1])?.evidence.map(\.label) == [.externalFact, .aiInference])
check("tags kept", m.node(created[0])?.tags == ["ux", "search"])
check("run counts what it added", r.added == 3 && r.refused == 0)

// Guards.
var g = map()
var gr = Run(mode: .research)
var chain = ""
for i in 1...5 { chain += line("l\(i)", i == 1 ? "root" : "l\(i - 1)", "Level \(i)") }
let gids = gr.apply(gr.feed(chain), to: &g, pathExists: exists)
check("at most three levels below the root", gids.count == 3 && g.nodes.map(\.title) == ["How do we do it?", "Level 1", "Level 2", "Level 3"])
check("deeper nodes are refused", gr.refused == 2)

var wide = map()
var wr = Run(mode: .research)
var fan = ""
for i in 1...20 { fan += line("w\(i)", "root", "Branch \(i)") }
_ = wr.apply(wr.feed(fan), to: &wide, pathExists: exists)
check("at most twelve children", wide.children(of: "n1").count == 12 && wr.refused == 8)

var many = map()
var mr = Run(mode: .research)
var text = ""
for b in 1...6 { text += line("b\(b)", "root", "B\(b)"); for s in 1...10 { text += line("s\(b)-\(s)", "b\(b)", "B\(b) topic \(s)") } }
_ = mr.apply(mr.feed(text), to: &many, pathExists: exists)
check("at most sixty new nodes", mr.added == 60 && many.nodes.count == 61)

var unknown = map()
var ur = Run(mode: .research)
_ = ur.apply(ur.feed(line("a", "nowhere", "Orphan") + line("b", "", "Default parent") + line("c", "n1", "By id")), to: &unknown, pathExists: exists)
check("unknown parent refused, empty parent is the root, an id works", unknown.nodes.map(\.title) == ["How do we do it?", "Default parent", "By id"] && ur.refused == 1)

var dup = map()
var dr = Run(mode: .research)
_ = dr.apply(dr.feed(line("a", "root", "Same") + line("b", "root", "same") + line("c", "a", "Same")), to: &dup, pathExists: exists)
check("a repeated sibling title is refused, the same title elsewhere is fine", dup.nodes.map(\.title) == ["How do we do it?", "Same", "Same"] && dr.refused == 1)

var nodeAfterDelete = map()
var ndr = Run(mode: .research)
let first = ndr.apply(ndr.feed(line("a", "root", "A")), to: &nodeAfterDelete, pathExists: exists)
try! nodeAfterDelete.delete(id: first[0])
check("a parent deleted while the run goes on drops the child", ndr.apply(ndr.feed(line("b", "a", "B")), to: &nodeAfterDelete, pathExists: exists).isEmpty)

// MARK: Develop (REQ-004)

var base = map()
let a = try! base.addChild(parent: "n1", title: "Alpha")
let b = try! base.addChild(parent: "n1", title: "Beta")
let aa = try! base.addChild(parent: a, title: "Alpha one")
var dev = Run(mode: .develop(node: a))
let options = line("o1", "node", "Option A", extra: ",\"description\":\"Fast.\"") + line("o2", "node", "Option B") + line("o3", "root", "Option C")
    + line("d1", "o1", "Detail of A") + line("d2", "d1", "Too deep") + line("x", b, "Outside the branch") + line("y", aa, "Under an existing child") + line("z", "n1", "At the root")
let devCreated = dev.apply(dev.feed(options), to: &base, pathExists: exists)
check("each option is its own child of the node", base.children(of: a).map(\.title) == ["Alpha one", "Option A", "Option B", "Option C"])
check("a ROOT line means nothing when developing", { var d = Run(mode: .develop(node: a)); var x = base; _ = d.apply(d.feed("ROOT {\"title\":\"Hijack\"}\n"), to: &x, pathExists: exists); return x.title != "Hijack" }())
check("two levels below the node at most", base.children(of: devCreated[3]).isEmpty && !base.nodes.contains { $0.title == "Too deep" })
check("details go under their option", base.node(devCreated[3])?.parent == devCreated[0])
check("nothing is added outside the branch", !base.nodes.contains { $0.title == "Outside the branch" || $0.title == "At the root" })
check("an existing child of the node is a valid parent", base.nodes.contains { $0.title == "Under an existing child" && $0.parent == aa })
check("develop allows twenty-four nodes", Run.limits(for: .develop(node: a)).nodes == 24 && Run.limits(for: .develop(node: a)).depth == 2)

// MARK: Continuation

var cont = map()
let c1 = try! cont.addChild(parent: "n1", title: "Existing")
var cr = Run(mode: .continuation)
let more = cr.apply(cr.feed("ROOT {\"title\":\"Hijack\"}\n" + line("n", c1, "More detail") + line("m", "root", "New main branch") + line("e", "root", "existing")), to: &cont, pathExists: exists)
check("continuation adds under existing ids and the root", more.count == 2 && cont.node(more[0])?.parent == c1 && cont.node(more[1])?.parent == "n1")
check("continuation never renames the root", cont.title == "How do we do it?")
check("continuation skips a topic the node already has", cr.refused == 1)

// MARK: Prompts

let limits = Run.limits(for: .research)
let system = ResearchMapPrompt.system(web: true, webRules: "WEB RULES HERE", languageLine: "LANG LINE")
check("system prompt carries the four labels", ["Project fact", "External fact", "AI inference", "Open assumption"].allSatisfy { system.contains($0) })
check("system prompt carries web rules and language when web is on", system.contains("WEB RULES HERE") && system.contains("LANG LINE"))
check("system prompt says web is off", ResearchMapPrompt.system(web: false, webRules: "WEB RULES HERE", languageLine: "L").contains("Web search is not available") && !ResearchMapPrompt.system(web: false, webRules: "WEB RULES HERE", languageLine: "L").contains("WEB RULES HERE"))
check("system prompt forbids modifying files and explains the line format", system.contains("Never modify files") && system.contains("NODE {"))
let task = ResearchMapPrompt.research(question: "Why?", targets: ["docs/a.md"], attachments: ["docs/research/assets/x/f.png"], scope: "SCOPE", limits: limits)
check("research task has the question, targets, attachments, scope", task.contains("Why?") && task.contains("- docs/a.md") && task.contains("f.png") && task.hasSuffix("SCOPE"))
check("research task states the limits", task.contains("3 levels") && task.contains("12 children") && task.contains("60 nodes"))
check("research task asks for the root first", task.contains("ROOT {"))
let developTask = ResearchMapPrompt.develop(map: base, node: base.node(a)!, direction: "Give me options for caching", scope: "SCOPE", limits: Run.limits(for: .develop(node: a)))
check("develop task names the node and the direction", developTask.contains("\(a), \"Alpha\"") && developTask.contains("Give me options for caching"))
check("develop task lists the outline with ids", developTask.contains("- n1 How do we do it?") && developTask.contains("    - \(aa) Alpha one"))
check("develop task asks for options as separate children", developTask.contains("each option as its own child"))
var thinMap = map()
let thinID = try! thinMap.addChild(parent: "n1", title: "Existing")
let contTask = ResearchMapPrompt.continuation(map: thinMap, question: "Why?", scope: "SCOPE", limits: Run.limits(for: .continuation))
check("continuation task lists nodes without children", contTask.contains("- \(thinID) \"Existing\""))
check("continuation task forbids a new ROOT", contTask.contains("do not write a ROOT"))

// MARK: Single-node runs (REQ-006): Expand description, Correct, Research

func single(_ mode: Run.Mode, _ text: String, on target: M) -> (M, Run) {
    var m = target
    var r = Run(mode: mode)
    let events = r.feed(text + "\n")
    _ = r.apply(events, to: &m, pathExists: exists)
    return (m, r)
}
var sm = map()
let sNode = try! sm.addChild(parent: "n1", title: "Caching")
let sKid = try! sm.addChild(parent: sNode, title: "Disk cache")
try! sm.update(id: sNode, tags: ["perf"], color: "#aa0000", description: "Old text.")
try! sm.moveVisual(id: sNode, x: 5, y: 6)
try! sm.update(id: sNode, shape: "diamond", width: .some(240), height: .some(120))
sm.nodes[sm.index(of: sNode)!].evidence = [M.Evidence(label: .projectFact, text: "Old finding", source: "src/tree.swift:1")]

check("single-node modes have no node budget", Run.limits(for: .describe(node: sNode)) == Run.Limits(nodes: 0, depth: 0, children: 0))
check("singleNode names the target only for the single-node modes", Run.Mode.describe(node: "a").singleNode == "a" && Run.Mode.develop(node: "a").singleNode == nil && Run.Mode.research.singleNode == nil)

let (described, dRun) = single(.describe(node: sNode),
    #"UPDATE {"description":"New, longer text.","evidence":[{"label":"Project fact","text":"New finding","source":"src/tree.swift:3"},{"label":"Project fact","text":"Old finding","source":"src/tree.swift:1"}]}"#, on: sm)
check("describe replaces the description", described.node(sNode)!.description == "New, longer text.")
check("describe adds new findings and keeps the old ones without repeating them", described.node(sNode)!.evidence.map(\.text) == ["Old finding", "New finding"])
check("describe keeps title, tags, colour, position and children", { let n = described.node(sNode)!; return n.title == "Caching" && n.tags == ["perf"] && n.color == "#aa0000" && n.x == 5 && n.y == 6 && described.node(sKid)?.parent == sNode }())
check("describe keeps shape and size (REQ-009)", { let n = described.node(sNode)!; return n.shape == "diamond" && n.width == 240 && n.height == 120 }())
check("describe adds no node", described.nodes.count == sm.nodes.count && dRun.added == 0 && dRun.updated == 1)
check("describe ignores a title the agent also wrote", single(.describe(node: sNode), #"UPDATE {"title":"Other","description":"x"}"#, on: sm).0.node(sNode)!.title == "Caching")
check("describe without a description changes nothing", single(.describe(node: sNode), #"UPDATE {"evidence":[{"label":"Project fact","text":"Only evidence","source":""}]}"#, on: sm).0 == sm)

let (corrected, cRun) = single(.correct(node: sNode),
    #"UPDATE {"title":"Caching layers","description":"Fixed.","evidence":[{"label":"AI inference","text":"Replaces the old list","source":""}]}"#, on: sm)
check("correct rewrites title and description", corrected.node(sNode)!.title == "Caching layers" && corrected.node(sNode)!.description == "Fixed.")
check("correct replaces the findings with the list it was given", corrected.node(sNode)!.evidence.map(\.text) == ["Replaces the old list"])
check("correct keeps tags, colour, position and children", { let n = corrected.node(sNode)!; return n.tags == ["perf"] && n.color == "#aa0000" && n.x == 5 && corrected.node(sKid) != nil }())
check("correct keeps shape and size (REQ-009)", { let n = corrected.node(sNode)!; return n.shape == "diamond" && n.width == 240 && n.height == 120 }())
check("correct counts one update", cRun.updated == 1)
check("correct keeps the findings when the list is empty or missing", single(.correct(node: sNode), #"UPDATE {"description":"Fixed.","evidence":[]}"#, on: sm).0.node(sNode)!.evidence.count == 1
      && single(.correct(node: sNode), #"UPDATE {"description":"Fixed."}"#, on: sm).0.node(sNode)!.evidence.count == 1)
check("correct keeps the title when the agent leaves it out or blank", single(.correct(node: sNode), #"UPDATE {"title":"  ","description":"Fixed."}"#, on: sm).0.node(sNode)!.title == "Caching")

let (investigated, iRun) = single(.investigate(node: sNode),
    #"UPDATE {"description":"Must not be written","title":"Nor this","evidence":[{"label":"External fact","text":"A source says so","source":"https://example.com/a"},{"label":"Project fact","text":"Invented","source":"src/missing.swift:9"}]}"#, on: sm)
check("research adds findings only", investigated.node(sNode)!.description == "Old text." && investigated.node(sNode)!.title == "Caching")
check("research keeps the old finding first and verifies new sources", investigated.node(sNode)!.evidence.count == 3
      && investigated.node(sNode)!.evidence[0].text == "Old finding" && investigated.node(sNode)!.evidence[2].label == .aiInference)
check("research counts one update", iRun.updated == 1)
check("research with no new findings changes nothing", single(.investigate(node: sNode), #"UPDATE {"evidence":[{"label":"Project fact","text":"Old finding","source":"src/tree.swift:1"}]}"#, on: sm).0 == sm)

let (twice, tRun) = single(.describe(node: sNode), "UPDATE {\"description\":\"First\"}\nUPDATE {\"description\":\"Second\"}", on: sm)
check("only the first update of a run is applied", twice.node(sNode)!.description == "First" && tRun.updated == 1 && tRun.refused == 1)
let (noNodes, nRun) = single(.describe(node: sNode), "NODE {\"ref\":\"x\",\"parent\":\"\(sNode)\",\"title\":\"Sneaky child\"}\nROOT {\"title\":\"Renamed\"}", on: sm)
check("a single-node run adds no node and renames nothing", noNodes == sm && nRun.added == 0 && nRun.refused == 1)
var plain = Run(mode: .research)
check("an UPDATE line means nothing in a run that adds nodes", plain.feed("UPDATE {\"description\":\"x\"}\n").isEmpty && plain.malformedLines == 0)
var bad = Run(mode: .correct(node: sNode))
check("a broken or empty UPDATE line is counted, not applied", bad.feed("UPDATE {oops\nUPDATE {}\n").isEmpty && bad.malformedLines == 2)
check("a node deleted during the run is not recreated", single(.describe(node: "n99"), #"UPDATE {"description":"x"}"#, on: sm).0 == sm)

// Prompts of the single-node runs
let sysSingle = ResearchMapPrompt.system(web: true, webRules: "WEB RULES HERE", languageLine: "LANG LINE", singleNode: true)
check("single-node system prompt asks for one UPDATE line and no nodes", sysSingle.contains("UPDATE {") && sysSingle.contains("add no nodes") && !sysSingle.contains("NODE {\"ref\""))
check("single-node system prompt keeps labels, web rules and language", sysSingle.contains("Project fact") && sysSingle.contains("WEB RULES HERE") && sysSingle.contains("LANG LINE"))
let describeTask = ResearchMapPrompt.describe(map: sm, node: sm.node(sNode)!, scope: "SCOPE")
check("describe task has the node, the old text and the scope", describeTask.contains("\(sNode), \"Caching\"") && describeTask.contains("Old text.") && describeTask.hasSuffix("SCOPE"))
check("describe task keeps the title and the old findings out of the answer", describeTask.contains("Do not write \"title\"") && describeTask.contains("existing findings stay"))
let correctTask = ResearchMapPrompt.correct(map: sm, node: sm.node(sNode)!, note: "The disk cache is not LRU", scope: "SCOPE")
check("correct task carries the person's note and says evidence replaces", correctTask.contains("The disk cache is not LRU") && correctTask.contains("replaces the old list"))
let researchTask = ResearchMapPrompt.investigate(map: sm, node: sm.node(sNode)!, scope: "SCOPE")
check("research task asks for evidence only", researchTask.contains("only the key \"evidence\"") && researchTask.contains("Old finding"))
let noDirection = ResearchMapPrompt.develop(map: sm, node: sm.node(sNode)!, direction: "", scope: "SCOPE", limits: Run.limits(for: .develop(node: sNode)))
check("develop without a direction asks the agent to choose the sub-topics", noDirection.contains("gave no direction") && !noDirection.contains("in this direction"))

// MARK: Numbers on AI nodes (REQ-008)

var numbered = Run(mode: .research)
var numberedMap = map()
let numberedEvents = numbered.feed(line("a", "root", "Plan", extra: ",\"number\":1") + line("b", "root", "Build", extra: ",\"number\":\"2\"") + line("c", "root", "Ship", extra: ",\"number\":0")
                                   + line("d", "root", "Review", extra: ",\"number\":5000") + line("e", "root", "Retro", extra: ",\"number\":2.5") + line("f", "root", "Close"))
_ = numbered.apply(numberedEvents, to: &numberedMap, pathExists: exists)
let byTitle = Dictionary(uniqueKeysWithValues: numberedMap.nodes.map { ($0.title, $0.number) })
check("a NODE line may carry a number; text numbers count", byTitle["Plan"] == .some(1) && byTitle["Build"] == .some(2))
check("zero, too large, fractional or missing numbers are ignored", byTitle["Ship"] == .some(nil) && byTitle["Review"] == .some(nil) && byTitle["Close"] == .some(nil))
check("the node format tells the agent when to number", Run.limits(for: .research).nodes > 0 && ResearchMapPrompt.system(web: false, webRules: "", languageLine: "", singleNode: false).contains("\"number\":1") && ResearchMapPrompt.system(web: false, webRules: "", languageLine: "", singleNode: false).contains("order of sibling nodes matters"))
check("the single-node format has no number", !ResearchMapPrompt.system(web: false, webRules: "", languageLine: "", singleNode: true).contains("\"number\""))

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
