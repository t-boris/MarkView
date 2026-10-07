import Foundation

// Checks the validation and Mermaid output of DiagramAI (MarkView/Models/DiagramAI.swift).
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try! "x".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: root) }

func node(_ id: String, group: String? = nil, source: String? = "A.swift") -> DiagramSpec.Node {
    .init(id: id, label: id.uppercased(), kind: "service", group: group, source: source, note: "does \(id)")
}
func spec(nodes: [DiagramSpec.Node], edges: [DiagramSpec.Edge]) -> DiagramSpec {
    .init(title: "T", question: "Q?", takeaway: "A.", direction: "LR", nodes: nodes, edges: edges, omitted: nil)
}

// A good diagram passes untouched.
let good = spec(nodes: [node("a", group: "Core"), node("b", group: "Core"), node("c", source: nil)],
                edges: [.init(from: "a", to: "b", label: "calls", evidence: "A.swift:1"),
                        .init(from: "b", to: "c", label: "reads | writes", evidence: nil)])
let (cleaned, none) = DiagramAI.validate(good, root: root)
check(none.isEmpty, "a good diagram has no problems: \(none)")
check(cleaned.edges[1].label == "reads / writes", "a pipe in an edge label is replaced")

// Problems only the agent can fix are reported.
let bad = spec(nodes: [node("a"), node("a"), node("b", source: "Missing.swift"), node("lonely")],
               edges: [.init(from: "a", to: "zzz", label: "calls", evidence: nil),
                       .init(from: "a", to: "b", label: "", evidence: nil)])
let (_, problems) = DiagramAI.validate(bad, root: root)
check(problems.contains { $0.contains("used twice") }, "duplicate id")
check(problems.contains { $0.contains("does not exist") }, "invented source path")
check(problems.contains { $0.contains("not a node") }, "edge to unknown node")
check(problems.contains { $0.contains("no label") }, "unlabeled edge")
check(problems.contains { $0.contains("without any edge") }, "loose node")

// Too many nodes.
let many = (0..<30).map { node("n\($0)") }
let chain = (1..<30).map { DiagramSpec.Edge(from: "n\($0 - 1)", to: "n\($0)", label: "next", evidence: nil) }
check(DiagramAI.validate(spec(nodes: many, edges: chain), root: root).1.contains { $0.contains("at most 25") }, "node budget")

// Mermaid: strict subset the editor's canvas reads.
let mermaid = DiagramAI.mermaid(cleaned)
check(mermaid.hasPrefix("%%INTERACTIVE\nflowchart LR"), "interactive marker and direction")
check(mermaid.contains("subgraph g1[\"Core\"]"), "group")
check(mermaid.contains("  a[\"A\"]:::service"), "node line with class")
check(mermaid.contains("a -->|calls| b"), "edge line")
check(mermaid.contains("%% src a A.swift:1") == false && mermaid.contains("%% src a A.swift"), "source comment")
check(mermaid.contains("%% evidence a b A.swift:1"), "evidence comment")

// Markdown legend and free file names.
let md = DiagramAI.markdown(cleaned)
check(md.contains("**Question:** Q?") && md.contains("## Components"), "markdown sections")
let first = DiagramAI.freeURL(in: root, base: "graph-x")
try! "x".write(to: first, atomically: true, encoding: .utf8)
check(DiagramAI.freeURL(in: root, base: "graph-x").lastPathComponent == "graph-x-2.md", "existing file is not overwritten")

if failures == 0 { print("diagram tests passed") } else { print("\(failures) failure(s)"); exit(1) }
