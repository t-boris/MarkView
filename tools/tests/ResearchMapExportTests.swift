// Checks the Markdown report of a research map (MarkView/Models/ResearchMapExport.swift) against REQ-007 and DEC-010.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
typealias M = ResearchMap

var map = M.new(id: "x", question: "How should we cache?\nSecond line.", created: "2026-11-04", targets: [], attachments: [])
try! map.update(id: "n1", title: "Caching strategy", description: "The short answer.\n\n# Heading inside\nBody.")
let a = try! map.addChild(parent: "n1", title: "Memory cache")
let aa = try! map.addChild(parent: a, title: "Eviction")
let b = try! map.addChild(parent: "n1", title: "Disk cache")
try! map.update(id: a, tags: ["perf", "ram"], description: "Fast but small.")
map.nodes[map.index(of: a)!].evidence = [
    M.Evidence(label: .projectFact, text: "The cache is a dictionary.", source: "src/cache.swift:12"),
    M.Evidence(label: .externalFact, text: "LRU is common.", source: "https://example.com/lru(1)"),
    M.Evidence(label: .aiInference, text: "Likely enough\nfor us.", source: ""),
]
try! map.link(aa, b)
map.addWebQueries(["lru cache swift", "disk cache trade-offs"])
map.markComplete()

let report = map.report(mapName: "map.md")
let lines = report.components(separatedBy: "\n")

check("the report starts with the root as the only H1", lines[0] == "# Caching strategy" && lines.filter { $0.hasPrefix("# ") }.count == 1)
check("the question follows as a quote, every line", lines.contains("> How should we cache?") && lines.contains("> Second line."))
check("branches are numbered headings in map order", lines.contains("## 1 Memory cache") && lines.contains("### 1.1 Eviction") && lines.contains("## 2 Disk cache")
      && lines.firstIndex(of: "## 1 Memory cache")! < lines.firstIndex(of: "### 1.1 Eviction")! && lines.firstIndex(of: "### 1.1 Eviction")! < lines.firstIndex(of: "## 2 Disk cache")!)
check("the root's description is kept and its own headings cannot break the outline", report.contains("The short answer.") && report.contains("**Heading inside**") && !lines.contains("# Heading inside"))
check("tags are listed", report.contains("Tags: `perf`, `ram`"))
check("findings carry their label", report.contains("- **Project fact**: The cache is a dictionary. (`src/cache.swift:12`)") && report.contains("- **AI inference**: Likely enough for us."))
check("a web source is a link, brackets kept valid", report.contains("([source](https://example.com/lru(1%29))") || report.contains("([source](https://example.com/lru(1%29)))"))
check("connections are written as See also on both ends", report.contains("See also: 2 Disk cache") && report.contains("See also: 1.1 Eviction"))
check("web searches are numbered", report.contains("1. lru cache swift") && report.contains("2. disk cache trade-offs"))
check("the report names the map and counts the nodes", report.contains("4 nodes") && report.contains("`map.md`"))
check("a complete research has no incomplete note", !report.contains("Incomplete research"))

var incomplete = map
incomplete.markIncomplete("stopped")
check("an incomplete run is noted at the top", incomplete.report(mapName: "m.md").contains("**Incomplete research:** stopped."))
var running = map
running.markResearching()
check("a running research is noted", running.report(mapName: "m.md").contains("still running"))

var deep = M.new(id: "d", question: "Q", created: "2026-11-04", targets: [], attachments: [])
var parent = "n1"
for level in 1...8 { parent = try! deep.addChild(parent: parent, title: "L\(level)") }
check("heading levels stop at six", deep.report(mapName: "d.md").components(separatedBy: "\n").allSatisfy { !$0.hasPrefix("#######") })

check("folding is not a concept of the report: every node is there", map.nodes.allSatisfy { report.contains($0.title) })
check("a fenced block inside a description keeps its hash lines", {
    var m = M.new(id: "f", question: "Q", created: "2026-11-04", targets: [], attachments: [])
    try! m.update(id: "n1", description: "```\n# comment\n```")
    return m.report(mapName: "f.md").contains("\n# comment\n")
}())
check("the report file sits next to the map", M.reportURL(forMap: URL(fileURLWithPath: "/p/docs/research/2026-11-05-why.md")).path == "/p/docs/research/2026-11-05-why-report.md")
check("exporting does not change the map", map.report(mapName: "map.md") == report)

// MARK: Icons and numbers in the report (REQ-008)

var badged = M.new(id: "i", question: "Q", created: "2026-11-04", targets: [], attachments: [])
let plan = try! badged.addChild(parent: "n1", title: "Plan")
let fire = try! badged.addChild(parent: "n1", title: "Fix")
try! badged.update(id: "n1", icon: "target")
try! badged.update(id: plan, tags: ["x"], icon: "bug", number: .some(1))
try! badged.update(id: fire, icon: "🔥", number: .some(2))
let badgedLines = badged.report(mapName: "i.md").components(separatedBy: "\n")
check("a built-in icon is written as its name in brackets before the title", badgedLines.contains("## 1 [bug] Plan") && badgedLines[0] == "# [target] Q" || badgedLines[0].hasPrefix("# [target] "))
check("an emoji icon is written as it is", badgedLines.contains("## 2 🔥 Fix"))
check("the number is a fact line, with the tags when there are some", badgedLines.contains("Number: 1 · Tags: `x`") && badgedLines.contains("Number: 2"))

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
