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

// ---- diagrams of a research map (REQ-012, REQ-013) -----------------------------------------------------------------------

// Plain Mermaid for the page renderer: no comment lines, edge labels quoted so brackets cannot break the parser.
let branching = spec(nodes: [node("a"), node("b")], edges: [.init(from: "a", to: "b", label: "ask (twice) \"now\"", evidence: "A.swift:1")])
let plain = DiagramAI.plainMermaid(branching, kind: .flowchart)
check(!plain.contains("%%") && !plain.contains("%%INTERACTIVE"), "plain Mermaid has no comment lines")
check(plain.contains("a -->|\"ask (twice) 'now'\"| b"), "plain Mermaid quotes the edge label and replaces quotes inside it: \(plain)")
check(plain.contains("  a[\"A\"]:::service") || plain.contains("a[\"A\"]:::service"), "plain Mermaid keeps the node lines")
check(DiagramAI.mermaid(branching).contains("a -->|ask (twice) \"now\"| b"), "the editor's own Mermaid keeps bare edge labels")

// The language of a node, and the check of a drawn diagram against it.
let english = "The explore run reads the project, writes its understanding and the open questions, and sets the feature status to exploring."
let russian = "Запуск исследования читает проект, записывает понимание и открытые вопросы и переводит feature в статус exploring."
check(DiagramAI.language(of: english)?.code == "en" && DiagramAI.language(of: english)?.name == "English", "English text is recognised")
check(DiagramAI.language(of: russian)?.code == "ru", "Russian text is recognised")
check(DiagramAI.language(of: "ok") == nil, "a short text has no language")
check(DiagramAI.mapLanguage(title: "Explore", nodeText: russian, evidence: [])?.code == "ru", "a node takes the language of its text")
func labelled(_ a: String, _ b: String, _ edge: String, _ note: String) -> DiagramSpec {
    var s = spec(nodes: [.init(id: "a", label: a, kind: "service", group: nil, source: nil, note: note),
                         .init(id: "b", label: b, kind: "service", group: nil, source: nil, note: note)],
                 edges: [.init(from: "a", to: "b", label: edge, evidence: nil)])
    s.title = a + " " + b; s.question = note; s.takeaway = note
    return s
}
let englishSpec = labelled("Explore trigger", "Store status", "writes the new status", "The run writes the new status of the feature after the exploration has finished.")
let germanSpec = labelled("Aufrufer", "Status speichern", "schreibt den neuen Status", "Der Lauf schreibt den neuen Status der Funktion, nachdem die Untersuchung abgeschlossen ist.")
check(DiagramAI.languageProblem(englishSpec, expected: "en") == nil, "labels in the expected language pass")
check(DiagramAI.languageProblem(germanSpec, expected: "en")?.contains("German") == true, "German labels are reported when English is expected")
check(DiagramAI.languageProblem(germanSpec, expected: nil) == nil, "no expected language, no check")

// `generate` asks again for a wrong language and for too many nodes, with the problem in the prompt.
func answer(_ s: DiagramSpec) -> CLICompletion.Result {
    let data = try! JSONEncoder().encode(s)
    return .init(text: "", structured: try! JSONSerialization.jsonObject(with: data), inputTokens: 0, outputTokens: 0)
}
func run(_ answers: [CLICompletion.Result], language: String?, maxNodes: Int?) -> (DiagramSpec?, Int, String) {
    CLICompletion.answers = answers
    CLICompletion.prompts = []
    var result: DiagramSpec?
    var failure = ""
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            result = try await DiagramAI.generate(prompt: "P", root: root, label: "t", expectedLanguage: language, maxNodes: maxNodes, onStage: { _ in }, record: { _ in })
        } catch { failure = "\(error)" }
        done.signal()
    }
    done.wait()
    return (result, CLICompletion.prompts.count, failure.isEmpty ? (CLICompletion.prompts.last ?? "") : failure)
}
let fixedLanguage = run([answer(germanSpec), answer(englishSpec)], language: "en", maxNodes: nil)
check(fixedLanguage.0 == englishSpec && fixedLanguage.1 == 2 && fixedLanguage.2.contains("German"), "a wrong language is sent back once and the corrected diagram is used")
let stubbornLanguage = run([answer(germanSpec)], language: "en", maxNodes: nil)
check(stubbornLanguage.0 == germanSpec && stubbornLanguage.1 == 3, "a language that cannot be fixed is accepted after the last round instead of failing the diagram")
let rightAtOnce = run([answer(englishSpec)], language: "en", maxNodes: 10)
check(rightAtOnce.0 == englishSpec && rightAtOnce.1 == 1, "a good diagram costs one run")
let chainOf = { (count: Int) -> DiagramSpec in
    spec(nodes: (0..<count).map { node("n\($0)", source: nil) },
         edges: (1..<count).map { DiagramSpec.Edge(from: "n\($0 - 1)", to: "n\($0)", label: "next", evidence: nil) })
}
let shrunk = run([answer(chainOf(14)), answer(chainOf(9))], language: nil, maxNodes: 10)
check(shrunk.0 == chainOf(9) && shrunk.1 == 2 && shrunk.2.contains("14 nodes") && shrunk.2.contains("at most 10"), "a diagram with more nodes than a page holds is sent back")
let tooBig = run([answer(chainOf(14))], language: nil, maxNodes: 10)
check(tooBig.0 == nil && tooBig.1 == 3, "a diagram that stays too big fails after three runs")
let unbounded = run([answer(chainOf(14))], language: nil, maxNodes: nil)
check(unbounded.0 == chainOf(14) && unbounded.1 == 1, "without a budget the usual limit applies")

if failures == 0 { print("diagram tests passed") } else { print("\(failures) failure(s)"); exit(1) }
