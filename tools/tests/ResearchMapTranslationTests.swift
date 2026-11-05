// Checks the pure part of translating a research map (MarkView/Models/ResearchMapTranslation.swift) against REQ-014 and DEC-015.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
typealias M = ResearchMap
typealias T = ResearchMapTranslation

func parsed(_ text: String) -> M? {
    if case .success(let map) = M.parse(text) { return map }
    return nil
}

// MARK: Fixtures and a fake translator

/// A fake "translation": every prose line gets " (EN)"; code blocks stay; the label text of a Mermaid block gets " EN".
func fakeMermaidLine(_ line: String) -> String {
    if line.trimmingCharacters(in: .whitespaces).hasPrefix("%%") { return line }
    var text = line
    for (pattern, template) in [("\"([^\"]*)\"", "\"$1 EN\""), ("\\|([^|]*)\\|", "|$1 EN|"), ("( as )(.+)$", "$1$2 EN"), ("(: )(.+)$", "$1$2 EN")] {
        text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return text
}
func fakeText(_ text: String) -> String {
    var inFence: String?
    var out: [String] = []
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inFence = inFence == nil ? trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() : nil
            out.append(line)
        } else if let language = inFence {
            out.append(language == "mermaid" ? fakeMermaidLine(line) : line)
        } else {
            out.append(trimmed.isEmpty ? line : line + " (EN)")
        }
    }
    return out.joined(separator: "\n")
}
func fakeAnswer(_ map: M, ids: [String]) -> T.Answer {
    T.Answer(title: map.title + " (EN)", question: map.question + " (EN)", nodes: ids.compactMap { map.node($0) }.map { node in
        T.Answer.Node(id: node.id, title: node.title + " (EN)", tags: node.tags.map { $0 + " en" }, description: fakeText(node.description),
                      evidence: node.evidence.map { $0.text + " (EN)" })
    })
}
/// Translates a whole map the way the job does: batch by batch.
func translateAll(_ map: M, size: Int = 20) -> (map: M, applied: [T.Applied]) {
    var result = map
    var all: [T.Applied] = []
    for ids in T.batches(of: map, size: size) { all.append(T.apply(answer: fakeAnswer(result, ids: ids), to: &result, ids: ids)) }
    return (result, all)
}
/// Everything of a map that is not text to translate, as comparable lines.
func structure(_ map: M) -> [String] {
    var lines: [String] = ["id=\(map.id)", "created=\(map.created)", "status=\(map.status.rawValue)", "targets=\(map.targets)", "attachments=\(map.attachments)",
                           "queries=\(map.webQueries)", "extra=\(map.extraSections)", "links=\(map.links.map { "\($0.from)>\($0.to)" })"]
    for n in map.nodes {
        lines.append("\(n.id)|\(n.parent)|\(n.color)|\(n.icon)|\(n.number.map(String.init) ?? "")|\(n.shape)|\(n.width.map(String.init) ?? "")|\(n.height.map(String.init) ?? "")|\(n.visual)|\(n.layout)|\(n.x.map(String.init) ?? "")|\(n.y.map(String.init) ?? "")")
        for e in n.evidence { lines.append("  ev \(e.label.rawValue)|\(e.source)") }
    }
    // The file's own non-text lines: the property lines and the node headings' ids.
    let prefixes = ["- color:", "- icon:", "- number:", "- shape:", "- width:", "- height:", "- visual:", "- layout:", "- position:"]
    for line in map.markdown().components(separatedBy: "\n") {
        if prefixes.contains(where: { line.hasPrefix($0) }) { lines.append(line) }
        if line.hasPrefix("### "), let open = line.range(of: "{#", options: .backwards) { lines.append(String(line[open.lowerBound...])) }
        if line.hasPrefix("## ") || line.hasPrefix("type:") || line.hasPrefix("id:") || line.hasPrefix("created:") || line.hasPrefix("status:") { lines.append(line) }
    }
    return lines
}

let flowSource = """
%%INTERACTIVE
flowchart LR
classDef service fill:#4ec9b026,stroke:#4ec9b0,stroke-width:1.5px
subgraph g1["Edge layer"]
  gw["API gateway"]:::service
end
auth["Auth service"]:::service
db["User store"]:::service
gw -->|validates token| auth
auth -->|reads user| db
%% src gw Sources/Gateway.swift
%% note gw Entry point of every request
"""
let sequenceSource = """
sequenceDiagram
participant p0 as Client
participant p1 as Auth service
p0->>p1: 1. send credentials
p1-->>p0: 2. return token
Note over p0,p1: the token expires in 10 minutes
loop every request
p0->>p1: 3. refresh
end
"""
func fenced(_ source: String) -> String { "```mermaid\n" + source + "\n```" }

var hand = M.new(id: "2026-11-05-auth", question: "How should login work?\nAnd what about sessions?", created: "2026-11-05", targets: ["docs/auth.md"], attachments: [])
try! hand.update(id: "n1", description: "Overview of the login design. See [the spec](https://example.com/spec) and `Session.start()`.")
let nFlow = try! hand.addNode(parent: "n1", draft: M.Draft(title: "Architecture", description: fenced(flowSource) + "\n\nThe gateway checks tokens.", tags: ["design", "Security"],
    evidence: [M.Evidence(label: .projectFact, text: "The gateway verifies the token before routing", source: "Sources/Gateway.swift:42"),
               M.Evidence(label: .externalFact, text: "OAuth 2.0 defines the token exchange", source: "https://www.rfc-editor.org/rfc/rfc6749")]))
let nSeq = try! hand.addNode(parent: "n1", draft: M.Draft(title: "Login flow", description: fenced(sequenceSource) + "\n\nTwo steps.\n\nSecond diagram:\n\n" + fenced(flowSource)))
let nImg = try! hand.addNode(parent: "n1", draft: M.Draft(title: "Screenshot", description: "The login screen.\n\n![Login screen](images/login.png)\n\n```swift\nlet token = try await login()\n```\n\nCall `login()` first.", tags: ["ui"]))
let nEmpty = try! hand.addNode(parent: "n1", draft: M.Draft(title: "Empty node"))
try! hand.update(id: nFlow, color: "#ff8800", icon: "shield", number: .some(2), shape: "diamond", width: .some(200), height: .some(80), visual: "diagram")
try! hand.update(id: nImg, visual: "image")
hand.nodes[hand.index(of: nSeq)!].x = 120
hand.nodes[hand.index(of: nSeq)!].y = -40
hand.nodes[hand.index(of: nSeq)!].layout = "right"
hand.links.append(M.Link(from: nFlow, to: nSeq))
let allIDs = hand.nodes.map(\.id)

// MARK: Batches

var big = M.new(id: "b", question: "Q", created: "d", targets: [], attachments: [])
for i in 1...24 { _ = try! big.addChild(parent: "n1", title: "Node \(i)") }
let bigBatches = T.batches(of: big, size: 10)
check("25 nodes in batches of 10 make 10, 10 and 5", bigBatches.map(\.count) == [10, 10, 5])
check("batches keep the map order and the first holds the root", bigBatches.flatMap { $0 } == big.nodes.map(\.id) && bigBatches[0][0] == "n1")
check("a batch size of zero is one node per batch, the default is 20", T.batches(of: big, size: 0).count == 25 && T.batches(of: big).map(\.count) == [20, 5])

// MARK: The request

let request = T.prompt(map: hand, ids: Array(allIDs.prefix(3)), language: "German")
check("the prompt names the language in the rules and in the input", request.system.contains("German") && request.user.contains("German"))
check("the prompt holds every id of the batch and none of the others", allIDs.prefix(3).allSatisfy { request.user.contains("\"id\":\"\($0)\"") } && !request.user.contains("\"id\":\"\(nImg)\""))
check("the first batch carries the title and the question of the map", request.user.contains("\"question\":") && request.user.contains("How should login work?") && request.user.contains("\"title\":\"How should login work?\""))
let later = T.prompt(map: hand, ids: [nImg, nEmpty], language: "German")
check("a later batch has no question and says so", !later.user.contains("How should login work?") && later.user.contains("not part of this input"))
check("evidence label and source are shown as context", request.user.contains("Project fact") && request.user.contains("Sources/Gateway.swift:42"))
check("the rules keep addresses, code and Mermaid structure and forbid summaries", request.system.contains("mermaid") && request.system.contains("web addresses") && request.system.contains("do not summarise"))
check("the schema asks for title, question and nodes with id, title, tags, description and evidence", {
    let required = (T.schema["required"] as? [String]) ?? []
    let node = (((T.schema["properties"] as? [String: Any])?["nodes"] as? [String: Any])?["items"] as? [String: Any])?["required"] as? [String] ?? []
    return Set(required) == ["title", "question", "nodes"] && Set(node) == ["id", "title", "tags", "description", "evidence"] && JSONSerialization.isValidJSONObject(T.schema)
}())

// MARK: Reading the answer

let json = #"{"title":"T","question":"Q?","nodes":[{"id":"n1","title":"A","tags":["x"],"description":"d","evidence":["e1","e2"]},{"id":"n2","title":"B","tags":[],"description":"","evidence":[]}]}"#
if case .success(let a) = T.parse(answer: json) {
    check("a bare JSON answer is read", a.title == "T" && a.question == "Q?" && a.nodes.map(\.id) == ["n1", "n2"] && a.nodes[0].evidence == ["e1", "e2"] && a.nodes[0].tags == ["x"])
} else { check("a bare JSON answer is read", false) }
check("a fenced JSON answer is read", { if case .success(let a) = T.parse(answer: "```json\n\(json)\n```") { return a.nodes.count == 2 }; return false }())
check("JSON between words is read", { if case .success(let a) = T.parse(answer: "Here is the translation:\n\(json)\nHope it helps!") { return a.nodes.count == 2 }; return false }())
check("a bare list of nodes is read", { if case .success(let a) = T.parse(answer: #"[{"id":"n1","title":"A"}]"#) { return a.nodes.count == 1 && a.title == nil }; return false }())
check("evidence given as objects with text is read", { if case .success(let a) = T.parse(answer: #"{"nodes":[{"id":"n1","title":"A","evidence":[{"text":"one"},"two"]}]}"#) { return a.nodes[0].evidence == ["one", "two"] }; return false }())
check("an empty title or question reads as nothing", { if case .success(let a) = T.parse(answer: #"{"title":"","question":" ","nodes":[{"id":"n1","title":"A"}]}"#) { return a.title == nil && a.question == nil }; return false }())
check("garbage is a failure with a message", { if case .failure(let f) = T.parse(answer: "I could not do that.") { return !f.message.isEmpty }; return false }())
check("JSON without nodes is a failure", { if case .failure = T.parse(answer: #"{"title":"x"}"#) { return true }; return false }())
check("nodes without ids are a failure", { if case .failure = T.parse(answer: #"{"nodes":[{"title":"x"}]}"#) { return true }; return false }())

// MARK: A perfect translation of the hand-built map

let handBefore = structure(hand)
let handDescriptions = hand.nodes.map(\.description)
var handTranslated = hand
let handAnswer = fakeAnswer(hand, ids: allIDs)
let handProblems = T.check(answer: handAnswer, map: hand, ids: allIDs)
check("a perfect translation has no problem that needs a repair", T.repairable(handProblems).isEmpty)
check("its only reports are warnings", handProblems.allSatisfy { $0.severity == .warning })
let handApplied = T.apply(answer: handAnswer, to: &handTranslated, ids: allIDs)
check("every node is translated and none is kept", handApplied.translatedCount == allIDs.count && handApplied.keptOriginal.isEmpty && handApplied.diagramKept.isEmpty && handApplied.ignored.isEmpty)
check("titles, tags and descriptions are in the new language", handTranslated.node(nFlow)!.title == "Architecture (EN)" && handTranslated.node(nFlow)!.tags == ["design en", "Security en"]
      && handTranslated.node(nImg)!.description.contains("The login screen. (EN)") && handTranslated.node("n1")!.description.contains("(EN)"))
check("evidence texts are translated, labels and sources are not", handTranslated.node(nFlow)!.evidence.map(\.text) == ["The gateway verifies the token before routing (EN)", "OAuth 2.0 defines the token exchange (EN)"]
      && handTranslated.node(nFlow)!.evidence.map(\.source) == ["Sources/Gateway.swift:42", "https://www.rfc-editor.org/rfc/rfc6749"]
      && handTranslated.node(nFlow)!.evidence.map(\.label) == [.projectFact, .externalFact])
check("the title of the map and its question are translated", handTranslated.title == hand.title + " (EN)" && handTranslated.question.hasSuffix("(EN)") && handApplied.titleTranslated && handApplied.questionTranslated)
check("the structure is the same afterwards: ids, parents, order, links, numbers, colours, icons, shapes, sizes, positions, layout, visual, evidence labels and sources", structure(handTranslated) == handBefore)
check("the translated map is still a map: it writes and reads back equal", parsed(handTranslated.markdown()) == handTranslated)
check("a Mermaid block with translated labels is taken as translated", handTranslated.node(nFlow)!.description.contains("\"API gateway EN\"") && handTranslated.node(nSeq)!.description.contains("as Client EN"))
check("the original map is untouched", hand.nodes.map(\.description) == handDescriptions && structure(hand) == handBefore)
check("a node without a description gets none from the answer", { var m = hand; var a = handAnswer; a.nodes[a.nodes.firstIndex { $0.id == nEmpty }!].description = "Invented text"; T.apply(answer: a, to: &m, ids: allIDs); return m.node(nEmpty)!.description.isEmpty }())
check("tags are not invented for a node without them", { var m = hand; var a = handAnswer; a.nodes[a.nodes.firstIndex { $0.id == nEmpty }!].tags = ["invented"]; T.apply(answer: a, to: &m, ids: allIDs); return m.node(nEmpty)!.tags.isEmpty }())
check("the answer's order does not matter", { var m = hand; var a = handAnswer; a.nodes.reverse(); let r = T.apply(answer: a, to: &m, ids: allIDs); return r.translatedCount == allIDs.count && m.node(nFlow)!.title == "Architecture (EN)" }())

// MARK: The real map

// A copy of a large real map, given by the environment (RESEARCH_MAP_REAL) or found in the project; the checks are skipped without one.
let realPath = ProcessInfo.processInfo.environment["RESEARCH_MAP_REAL"] ?? "docs/research/2026-11-05-issues-management.md"
if let text = try? String(contentsOfFile: realPath, encoding: .utf8), let real = parsed(text) {
    let (done, applied) = translateAll(real)
    check("the real map is translated batch by batch: every node counted once (\(real.nodes.count) nodes)", applied.map(\.translatedCount).reduce(0, +) == real.nodes.count && applied.allSatisfy { $0.keptOriginal.isEmpty })
    check("the real map keeps its whole structure", structure(done) == structure(real))
    check("the real map still writes and reads back equal", parsed(done.markdown()) == done)
    check("every node of the real map changed its title and its description", real.nodes.allSatisfy { n in done.node(n.id)!.title == n.title + " (EN)" && (n.description.isEmpty || done.node(n.id)!.description != n.description) })
} else {
    print("skip the real map (\(realPath) not found)")
}

// MARK: Missing and unknown nodes

do {
    var a = handAnswer
    a.nodes.removeAll { $0.id == nFlow }
    let problems = T.check(answer: a, map: hand, ids: allIDs)
    check("a node the answer leaves out is an error with the code missing", problems.contains { $0.node == nFlow && $0.code == "missing" && $0.severity == .error })
    var m = hand
    let r = T.apply(answer: a, to: &m, ids: allIDs)
    check("it keeps its original text and is counted", r.keptOriginal == [nFlow] && m.node(nFlow) == hand.node(nFlow) && r.translatedCount == allIDs.count - 1)
    check("the other nodes are translated", m.node(nImg)!.title == "Screenshot (EN)" && structure(m) == handBefore)
    check("repair asks for exactly that node", T.repairIds(problems) == [nFlow])
}
do {
    var a = handAnswer
    a.nodes.append(T.Answer.Node(id: "zz", title: "Ghost", tags: [], description: "", evidence: []))
    a.nodes.append(a.nodes[0])
    let problems = T.check(answer: a, map: hand, ids: allIDs)
    check("an unknown id and a double answer are warnings", problems.contains { $0.code == "unknown" && $0.node == "zz" && $0.severity == .warning } && problems.contains { $0.code == "duplicate" && $0.severity == .warning })
    var m = hand
    let r = T.apply(answer: a, to: &m, ids: allIDs)
    check("the unknown id is ignored and reported, nothing is added to the map", r.ignored == ["zz"] && m.nodes.count == hand.nodes.count && m.node("zz") == nil && r.translatedCount == allIDs.count)
    check("a node of another batch is not applied", { var m2 = hand; let r2 = T.apply(answer: handAnswer, to: &m2, ids: [nImg]); return r2.translatedCount == 1 && m2.node(nFlow) == hand.node(nFlow) && r2.ignored.count == allIDs.count - 1 }())
}

// MARK: Things that must come back unchanged

func broken(_ id: String, _ change: (inout T.Answer.Node) -> Void) -> (problems: [T.Problem], map: M, applied: T.Applied) {
    var a = handAnswer
    change(&a.nodes[a.nodes.firstIndex { $0.id == id }!])
    var m = hand
    let r = T.apply(answer: a, to: &m, ids: allIDs)
    return (T.check(answer: a, map: hand, ids: allIDs), m, r)
}
do {
    let url = broken("n1") { $0.description = $0.description.replacingOccurrences(of: "https://example.com/spec", with: "https://example.com/spec-ru") }
    check("a changed link target is an error and the node keeps its text", url.problems.contains { $0.node == "n1" && $0.code == "address" && $0.severity == .error } && url.map.node("n1")!.description == hand.node("n1")!.description && url.applied.keptOriginal == ["n1"])
    let image = broken(nImg) { $0.description = $0.description.replacingOccurrences(of: "images/login.png", with: "images/вход.png") }
    check("a changed image address is an error", image.problems.contains { $0.node == nImg && $0.code == "address" } && image.map.node(nImg) == hand.node(nImg))
    let lost = broken("n1") { $0.description = "Обзор. Спецификация и Session.start()." }
    check("a lost link is an error", lost.problems.contains { $0.node == "n1" && $0.code == "address" })
    let bare = broken(nFlow) { $0.evidence[1] = "OAuth 2.0 defines the exchange, see https://example.com/other" }
    check("a bare web address that changed is an error", bare.problems.contains { $0.node == nFlow && $0.code == "address" })
    let moved = broken("n1") { $0.description = "Overview. Spec: (https://example.com/spec) and `Session.start()`." }
    check("a link target written as a plain address instead is fine", !moved.problems.contains { $0.code == "address" })
    let code = broken("n1") { $0.description = $0.description.replacingOccurrences(of: "`Session.start()`", with: "`Session.begin()`") }
    check("changed inline code is an error", code.problems.contains { $0.node == "n1" && $0.code == "code" && $0.severity == .error } && code.map.node("n1")!.description == hand.node("n1")!.description)
    let block = broken(nImg) { $0.description = $0.description.replacingOccurrences(of: "try await login()", with: "try await anmelden()") }
    check("a changed fenced code block is an error", block.problems.contains { $0.node == nImg && $0.code == "code" } && block.map.node(nImg) == hand.node(nImg))
    let evidenceCount = broken(nFlow) { $0.evidence.removeLast() }
    check("a missing evidence text is an error and no evidence text of the node changes", evidenceCount.problems.contains { $0.node == nFlow && $0.code == "evidence" && $0.severity == .error } && evidenceCount.map.node(nFlow) == hand.node(nFlow))
    let emptyEvidence = broken(nFlow) { $0.evidence[0] = "  " }
    check("an empty evidence text is an error", emptyEvidence.problems.contains { $0.node == nFlow && $0.code == "evidence" })
    let emptyTitle = broken(nImg) { $0.title = "   " }
    check("an empty title is an error", emptyTitle.problems.contains { $0.node == nImg && $0.code == "title" && $0.severity == .error })
    let longTitle = broken(nImg) { $0.title = String(repeating: "word ", count: 30) }
    check("a title over the limit is an error", longTitle.problems.contains { $0.node == nImg && $0.code == "title" })
    let emptyDescription = broken(nImg) { $0.description = "" }
    check("an empty description for a described node is an error", emptyDescription.problems.contains { $0.node == nImg && $0.code == "description" })
    let noTags = broken(nImg) { $0.tags = [] }
    check("lost tags are an error", noTags.problems.contains { $0.node == nImg && $0.code == "tags" })
    check("an error on one node leaves the others translated", url.applied.translatedCount == allIDs.count - 1 && url.map.node(nFlow)!.title == "Architecture (EN)")
    check("repair is asked for the failing node only", T.repairIds(url.problems) == ["n1"])
}

// MARK: Mermaid

do {
    // Labels translated: fine (covered above). Structure changed: the original block comes back, the prose is translated.
    let changed = broken(nFlow) { $0.description = $0.description.replacingOccurrences(of: "auth -->|reads user EN| db\n", with: "") }
    let diagramProblem = changed.problems.first { $0.node == nFlow && $0.code == "diagram" }
    check("a Mermaid block that lost an edge is a diagram problem", diagramProblem != nil)
    check("a diagram problem asks for a repair but does not fail the node", diagramProblem.map { T.repairable([$0]).count == 1 && $0.severity == .warning } == true && !changed.problems.contains { $0.node == nFlow && $0.severity == .error })
    check("the original block comes back and the prose is still translated", changed.map.node(nFlow)!.description.contains(fenced(flowSource)) && changed.map.node(nFlow)!.description.hasSuffix("The gateway checks tokens. (EN)") && changed.map.node(nFlow)!.title == "Architecture (EN)")
    check("the node is counted as translated and as diagram-kept", changed.applied.diagramKept == [nFlow] && changed.applied.translated.contains(nFlow) && changed.applied.keptOriginal.isEmpty)
    check("the structure stays the same with a diagram kept", structure(changed.map) == handBefore)

    // Two blocks in one description: only the damaged one is restored.
    let second = broken(nSeq) { $0.description = $0.description.replacingOccurrences(of: "gw -->|validates token EN| auth", with: "gw -->|validates token EN| db") }
    let seqDescription = second.map.node(nSeq)!.description
    check("only the damaged one of two blocks is restored", seqDescription.contains("\"API gateway EN\"") == false || seqDescription.contains(fenced(flowSource)) == true)
    check("the undamaged block keeps its translation", seqDescription.contains("as Client EN") && seqDescription.contains(fenced(flowSource)) && second.applied.diagramKept == [nSeq])

    // Another number of blocks cannot be paired: the whole node keeps its text.
    let fewer = broken(nSeq) { $0.description = "```mermaid\n" + fakeMermaidLine(sequenceSource) + "\n```\n\nTwo steps. (EN)" }
    check("a different number of Mermaid blocks is an error and the node keeps its text", fewer.problems.contains { $0.node == nSeq && $0.code == "fences" && $0.severity == .error } && fewer.map.node(nSeq) == hand.node(nSeq))

    // Skeletons.
    let flowTranslated = flowSource.components(separatedBy: "\n").map(fakeMermaidLine).joined(separator: "\n")
    check("the skeleton of the flowchart DiagramAI writes ignores comments and label text", T.skeleton(ofMermaid: flowSource) == T.skeleton(ofMermaid: flowTranslated))
    check("the skeleton of the flowchart keeps the type, direction, ids, shapes, classes and arrows", T.skeleton(ofMermaid: flowSource).hasPrefix("flowchart LR\nclassDef service") && T.skeleton(ofMermaid: flowSource).contains("auth[_]:::service") && T.skeleton(ofMermaid: flowSource).contains("gw -->|_| auth") && T.skeleton(ofMermaid: flowSource).contains("subgraph g1[_]"))
    check("a changed id, arrow, direction or class changes the flowchart skeleton", [
        flowSource.replacingOccurrences(of: "gw -->|validates token| auth", with: "gw -->|validates token| db"),
        flowSource.replacingOccurrences(of: "gw -->|validates token| auth", with: "gw ---|validates token| auth"),
        flowSource.replacingOccurrences(of: "flowchart LR", with: "flowchart TB"),
        flowSource.replacingOccurrences(of: "auth[\"Auth service\"]:::service", with: "auth[\"Auth service\"]:::database"),
        flowSource.replacingOccurrences(of: "db[\"User store\"]:::service\n", with: ""),
    ].allSatisfy { T.skeleton(ofMermaid: $0) != T.skeleton(ofMermaid: flowSource) })
    check("brackets inside a quoted label do not confuse the skeleton", T.skeleton(ofMermaid: "flowchart LR\nA[\"Check (a) [b]\"]:::x") == T.skeleton(ofMermaid: "flowchart LR\nA[\"Проверка (а)\"]:::x"))
    let sequenceTranslated = sequenceSource.components(separatedBy: "\n").map(fakeMermaidLine).joined(separator: "\n")
    check("the skeleton of the sequence diagram CodeArchitecture writes ignores label text", T.skeleton(ofMermaid: sequenceSource) == T.skeleton(ofMermaid: sequenceTranslated) && sequenceTranslated != sequenceSource)
    check("the skeleton of a sequence diagram keeps participants, arrows, notes and loops", T.skeleton(ofMermaid: sequenceSource) == "sequenceDiagram\nparticipant p0 as _\nparticipant p1 as _\np0->>p1: _\np1-->>p0: _\nNote over p0,p1: _\nloop _\np0->>p1: _\nend")
    check("a changed arrow or participant changes the sequence skeleton", [
        sequenceSource.replacingOccurrences(of: "p1-->>p0", with: "p1->>p0"),
        sequenceSource.replacingOccurrences(of: "p0->>p1: 3. refresh", with: "p1->>p0: 3. refresh"),
        sequenceSource.replacingOccurrences(of: "participant p1 as Auth service\n", with: ""),
    ].allSatisfy { T.skeleton(ofMermaid: $0) != T.skeleton(ofMermaid: sequenceSource) })
    check("whitespace does not matter to the skeleton", T.skeleton(ofMermaid: "flowchart LR\n  A[\"x\"]   -->   B[\"y\"]") == T.skeleton(ofMermaid: "flowchart LR\nA[\"x\"] --> B[\"y\"]"))
    check("an entity-relationship diagram keeps entities and cardinality", T.skeleton(ofMermaid: "erDiagram\nUSER ||--o{ ORDER : places") == T.skeleton(ofMermaid: "erDiagram\nUSER ||--o{ ORDER : размещает") && T.skeleton(ofMermaid: "erDiagram\nUSER ||--o{ ORDER : places") != T.skeleton(ofMermaid: "erDiagram\nUSER ||--|{ ORDER : places"))
    check("an empty block has an empty skeleton", T.skeleton(ofMermaid: "") == "" && T.skeleton(ofMermaid: "%% only a comment") == "")
}

// MARK: Reports that do not ask for a repair

do {
    let same = broken(nImg) { $0.description = $0.description.replacingOccurrences(of: " (EN)", with: "") }
    let untranslated = same.problems.first { $0.node == nImg && $0.code == "untranslated" }
    check("an untranslated long description is only a warning and is applied", untranslated?.severity == .warning && same.applied.translated.contains(nImg) && T.repairIds(same.problems).isEmpty)
    var a = handAnswer
    a.nodes[a.nodes.firstIndex { $0.id == nFlow }!].evidence[0] = hand.node(nFlow)!.evidence[0].text
    check("an untranslated long evidence text is only a warning", T.check(answer: a, map: hand, ids: allIDs).contains { $0.node == nFlow && $0.code == "untranslated" && $0.severity == .warning })
    check("a node that is only a diagram is not reported as untranslated", !T.check(answer: T.Answer(title: nil, question: nil, nodes: [T.Answer.Node(id: "n1", title: "A", tags: [], description: fenced(flowSource), evidence: [])]),
          map: { var m = M.new(id: "q", question: "Q", created: "d", targets: [], attachments: []); try! m.update(id: "n1", title: "A", description: fenced(flowSource)); return m }(), ids: ["n1"]).contains { $0.code == "untranslated" })
}

// MARK: The title of the map

do {
    var a = handAnswer
    a.nodes.removeAll { $0.id == "n1" }
    var m = hand
    let r = T.apply(answer: a, to: &m, ids: allIDs)
    check("when the root is missing the answer's own title still translates the map's title", r.keptOriginal == ["n1"] && r.titleTranslated && m.title == hand.title + " (EN)" && m.node("n1")!.description == hand.node("n1")!.description)
    var b = handAnswer
    b.title = nil
    b.question = nil
    var m2 = hand
    let r2 = T.apply(answer: b, to: &m2, ids: allIDs)
    check("without a question in the answer the question stays", !r2.questionTranslated && m2.question == hand.question)
    var m3 = hand
    T.apply(answer: handAnswer, to: &m3, ids: [nImg])
    check("a batch without the root leaves the title and the question alone", m3.title == hand.title && m3.question == hand.question)
}

// MARK: Repair helpers

do {
    var a = handAnswer
    a.nodes.removeAll { $0.id == nImg }
    a.nodes[a.nodes.firstIndex { $0.id == nFlow }!].evidence.removeLast()
    a.nodes[a.nodes.firstIndex { $0.id == nSeq }!].description = a.nodes[a.nodes.firstIndex { $0.id == nSeq }!].description.replacingOccurrences(of: "p0->>p1: 1. send credentials EN", with: "p1->>p0: 1. send credentials EN")
    let problems = T.check(answer: a, map: hand, ids: allIDs)
    let ids = T.repairIds(problems)
    check("repair ids are the failing nodes in order, once each", ids == allIDs.filter { [nFlow, nSeq, nImg].contains($0) })
    let text = T.repairPrompt(problems: problems)
    check("the repair prompt lists each problem under its node and names the nodes to answer", ids.allSatisfy { text.contains("- \($0):") && text.contains($0) } && text.contains("ONLY the nodes"))
    let repair = T.Answer(title: nil, question: nil, nodes: fakeAnswer(hand, ids: ids).nodes)
    let merged = T.merged(a, with: repair)
    check("a repair answer replaces the nodes it holds and keeps the others", merged.nodes.count == allIDs.count && T.repairable(T.check(answer: merged, map: hand, ids: allIDs)).isEmpty && merged.title == a.title)
    var m = hand
    let r = T.apply(answer: merged, to: &m, ids: allIDs)
    check("after the repair the whole map is translated", r.translatedCount == allIDs.count && r.keptOriginal.isEmpty && structure(m) == handBefore)
}

// MARK: File names and languages

check("a translated map is named with the language code", T.translatedFileName(for: "plan.md", code: "en") == "plan-en.md")
check("a language code the name already ends with is replaced", T.translatedFileName(for: "plan-ru.md", code: "en") == "plan-en.md" && T.translatedFileName(for: "docs/plan-de.md", code: "fr") == "docs/plan-fr.md")
check("a hyphen that is not a language code stays", T.translatedFileName(for: "my-map.md", code: "ru") == "my-map-ru.md" && T.translatedFileName(for: "2026-11-05-issues.md", code: "en") == "2026-11-05-issues-en.md")
check("a name without an extension is named too", T.translatedFileName(for: "plan", code: "en") == "plan-en")
check("the backup name says it was made before the translation", T.backupFileName(for: "plan.md") == "plan-before-translation.md" && T.backupFileName(for: "docs/plan-ru.md") == "docs/plan-ru-before-translation.md")
check("the language code comes from its name", T.languageCode(for: "English") == "en" && T.languageCode(for: " Русский ") == "ru" && T.languageCode(for: "deutsch") == "de" && T.languageCode(for: "fr") == "fr")
check("an unknown language becomes a short slug and nothing becomes translated", T.languageCode(for: "Klingon") == "klingon" && T.languageCode(for: "Ελληνικά") == "translated" && T.languageCode(for: "") == "translated")
check("the app offers English, Russian, German, Spanish and French with their codes", T.languages.map(\.name) == ["English", "Russian", "German", "Spanish", "French"] && T.languages.allSatisfy { T.languageCode(for: $0.name) == $0.code })

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
