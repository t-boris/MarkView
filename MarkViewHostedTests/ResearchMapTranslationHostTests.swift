import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

final class ResearchMapTranslationHostTests: XCTestCase {
    func testTranslation() {
var failures = 0
var checks = 0
func check(_ name: String, _ condition: Bool) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
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
let realPath = ProcessInfo.processInfo.environment["RESEARCH_MAP_REAL"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/research/2026-11-05-issues-management.md").path
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


        print("Research map translation hosted checks: \(checks)")
        XCTAssertEqual(failures, 0)
    }
}

@MainActor
private final class ResearchMapFixtureWindow: ResearchHost {
    struct Tab {
        let id = UUID()
        var url: URL
        var text: String
        var modified: Bool
    }

    var tabs: [Tab] = []
    var selected = 0
    var events: [String] = []
    var opened: [(url: URL, line: Int?, endLine: Int?)] = []

    func tab(_ file: URL) -> Tab? { tabs.first { $0.url.standardizedFileURL == file.standardizedFileURL } }

    func researchTab(for file: URL) -> ResearchTabText? {
        tab(file).map { ResearchTabText(text: $0.text, isModified: $0.modified) }
    }

    func researchTabSaved(_ file: URL, text: String) {
        guard let index = tabs.firstIndex(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) else { return }
        tabs[index].text = text
        tabs[index].modified = false
        events.append("saved")
    }

    func researchEditorFile(documentID: UUID?, event: String) -> URL? {
        if let documentID { return tabs.first { $0.id == documentID }?.url }
        return tabs.indices.contains(selected) ? tabs[selected].url : nil
    }

    func researchWatchOpenFiles() { events.append("watch") }
    func openFile(_ url: URL) { opened.append((url, nil, nil)) }
    func openFile(_ url: URL, line: Int?, endLine: Int?) { opened.append((url, line, endLine)) }
    func refreshFileTree() { events.append("refresh") }
    func saveBeforeResearch(_ file: URL, action: String) -> Bool { true }
    func researchDocumentChanged(_ file: URL, content: String, applyToEdited: (String) -> String?) -> Bool { true }
    func exportResearchPDF(_ markdown: String, fileName: String, near mapFile: URL) { events.append("pdf:\(fileName)") }
}


extension EditorHostTests {
    @MainActor func testResearchMapControllerRules() async {
        func check(_ condition: Bool, _ label: String, line: UInt = #line) {
            XCTAssertTrue(condition, label, line: line)
        }
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("research-map-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        func write(_ text: String, to url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        func parsed(_ text: String) -> ResearchMap? {
            if case .success(let map) = ResearchMap.parse(text) { return map }
            return nil
        }

        func snapshot(_ reply: ResearchMapController.Reply?) -> [String: Any] {
            guard let reply, let object = try? JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any] else { return [:] }
            return object
        }

        func waitUntil(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return await condition()
        }

        /// A map in a fresh project: the root node and the `docs/notes.md` the sources point at.
        @MainActor
        func makeProject(_ name: String, complete: Bool = true) -> (project: URL, map: URL, window: ResearchMapFixtureWindow, controller: ResearchMapController, tasks: TaskBag) {
            let project = sandbox.appendingPathComponent(name, isDirectory: true)
            let map = project.appendingPathComponent("docs/research/map.md")
            var model = ResearchMap.new(id: "map-\(name)", question: "How does login work?", created: "2026-01-01", targets: [], attachments: [])
            if complete { model.markComplete() }
            write(model.markdown(), to: map)
            write("line 1\nline 2\nline 3\nline 4\nline 5\n", to: project.appendingPathComponent("docs/notes.md"))
            let window = ResearchMapFixtureWindow()
            let context = StubProject(aiProjectTracksRoot: true)
            context.root = project
            let tasks = TaskBag()
            return (project, map, window, ResearchMapController(host: window, project: context, tasks: tasks), tasks)
        }

        @MainActor
        func run() async {
            print("=== Research maps of a window (AR-14 step 3) ===")

            // 1. The single writer of a map file.
            print("\n-- the map file")
            do {
                let env = makeProject("writer")
                check(env.controller.text(of: env.map) == read(env.map), "with no tab the map's text is the disk's")
                let added = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "Sessions") }
                var text = ""
                if case .done(let done) = added { text = done }
                check(text == read(env.map) && parsed(text)?.nodes.contains { $0.title == "Sessions" } == true, "a change is written to the file at once and reported as done")
                check(env.window.events.isEmpty, "with no tab open no tab is told anything")

                env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
                _ = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "Tokens") }
                check(env.window.tab(env.map)?.text == read(env.map) && env.window.tab(env.map)?.modified == false && env.window.events == ["saved"],
                      "the tab that holds the map takes the new text as saved")

                // A tab behind the disk (another editor saved less than two seconds ago): the change goes onto the disk text.
                var external = parsed(read(env.map))!
                _ = try? external.addChild(parent: "n1", title: "Saved elsewhere")
                write(external.markdown(), to: env.map)
                _ = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "After external") }
                let titles = parsed(read(env.map))?.nodes.map(\.title) ?? []
                check(titles.contains("Saved elsewhere") && titles.contains("After external"), "a tab behind the disk never overwrites what another editor saved")

                // A tab with unsaved edits: the change goes onto the text of the tab.
                var edited = parsed(read(env.map))!
                _ = try? edited.addChild(parent: "n1", title: "Typed in the editor")
                env.window.tabs[0].text = edited.markdown()
                env.window.tabs[0].modified = true
                check(env.controller.text(of: env.map) == edited.markdown(), "a tab with unsaved edits is the map's text")
                _ = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "Then by the AI") }
                let merged = parsed(read(env.map))?.nodes.map(\.title) ?? []
                check(merged.contains("Typed in the editor") && merged.contains("Then by the AI") && env.window.tab(env.map)?.modified == false,
                      "a change keeps what was typed in the tab, and the map is then saved")

                let before = read(env.map)
                let tabBefore = env.window.tab(env.map)?.text
                if case .rejected(let reason) = env.controller.update(env.map, { _ = try $0.delete(id: "no-such-node") }) {
                    check(!reason.isEmpty && read(env.map) == before && env.window.tab(env.map)?.text == tabBefore, "a refused change names the reason and leaves the file and the tab as they were")
                } else {
                    check(false, "a refused change is reported as rejected")
                }
                let eventsBefore = env.window.events.count
                if case .done(let same) = env.controller.update(env.map, { _ in }) {
                    check(same == before && read(env.map) == before && env.window.events.count == eventsBefore, "a change that changes nothing writes nothing")
                } else {
                    check(false, "a no-op change is done")
                }
                if case .unreadable = env.controller.update(sandbox.appendingPathComponent("missing.md"), { _ in }) {
                    check(true, "a map file that is gone is unreadable")
                } else {
                    check(false, "a map file that is gone is unreadable")
                }
                let notAMap = env.project.appendingPathComponent("notes-only.md")
                write("just text\n", to: notAMap)
                if case .unreadable(let why) = env.controller.update(notAMap, { _ in }) {
                    check(!why.isEmpty && read(notAMap) == "just text\n", "a file that is not a map is unreadable and untouched")
                } else {
                    check(false, "a file that is not a map is unreadable")
                }
            }

            // 2. The page.
            print("\n-- the page's actions")
            do {
                let env = makeProject("page")
                env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
                let documentID = env.window.tabs[0].id

                check(env.controller.handleAction("snapshot", payload: [:], documentID: UUID()) == nil, "an action for a tab that is closed is dropped")
                check(env.controller.handleAction("no-such-action", payload: [:], documentID: documentID) == nil, "an unknown action is dropped")
                check(env.window.events.contains("watch"), "an action asks the window to watch the open files for outside edits")

                let first = env.controller.handleAction("snapshot", payload: [:], documentID: documentID)
                let shot = snapshot(first)
                check(shot["ok"] as? Bool == true && (shot["nodes"] as? [[String: Any]])?.count == 1 && first?.content == read(env.map)
                      && (shot["markdown"] as? String) == read(env.map),
                      "the snapshot carries the nodes and the text of the tab for the Source view")

                let added = snapshot(env.controller.handleAction("addChild", payload: ["parent": "n1", "title": "Sessions"], documentID: documentID))
                let createdID = added["created"] as? String ?? ""
                check(!createdID.isEmpty && parsed(read(env.map))?.node(createdID)?.title == "Sessions", "Add child writes the node and tells the page which one to select")

                let updated = snapshot(env.controller.handleAction("update", payload: ["id": createdID, "tags": ["auth"], "description": "How sessions end."], documentID: documentID))
                let node = parsed(read(env.map))?.node(createdID)
                check(node?.tags == ["auth"] && node?.description == "How sessions end." && updated["notice"] as? String == "", "Update sets what the page sends and leaves the rest")

                let badPosition = snapshot(env.controller.handleAction("moveVisual", payload: ["id": createdID, "x": "left", "y": 1], documentID: documentID))
                check(badPosition["notice"] as? String == "That position is not valid.", "a position that is not a number is refused at the boundary")
                _ = env.controller.handleAction("moveVisual", payload: ["id": createdID, "x": 120, "y": 80], documentID: documentID)
                check(parsed(read(env.map))?.node(createdID)?.x == 120 && parsed(read(env.map))?.node(createdID)?.y == 80, "a position is stored on the node")

                _ = env.controller.handleAction("addChild", payload: ["parent": "n1", "title": "Tokens"], documentID: documentID)
                let tokens = parsed(read(env.map))?.nodes.first { $0.title == "Tokens" }?.id ?? ""
                let linked = snapshot(env.controller.handleAction("link", payload: ["from": createdID, "to": tokens], documentID: documentID))
                check((linked["links"] as? [[String: Any]])?.count == 1, "Link adds a connection to the snapshot")
                let unlinked = snapshot(env.controller.handleAction("unlink", payload: ["from": createdID, "to": tokens], documentID: documentID))
                check((unlinked["links"] as? [[String: Any]])?.isEmpty == true, "Unlink removes it")
                _ = env.controller.handleAction("move", payload: ["id": tokens, "parent": createdID], documentID: documentID)
                check(parsed(read(env.map))?.node(tokens)?.parent == createdID, "Move makes a node the child of the one the arrow ends on")
                let refused = snapshot(env.controller.handleAction("delete", payload: ["id": "nope"], documentID: documentID))
                check(!(refused["notice"] as? String ?? "").isEmpty, "a refused action shows its reason as the notice")
                _ = env.controller.handleAction("delete", payload: ["id": tokens], documentID: documentID)
                check(parsed(read(env.map))?.node(tokens) == nil, "Delete removes the node")
                check(env.window.tab(env.map)?.text == read(env.map) && env.window.tab(env.map)?.modified == false, "the tab holds the map as the actions left it")

                // Actions that would start an assistant refuse first, and start nothing.
                let nothing = { env.controller.jobs.jobs.isEmpty && env.tasks.activeCount == 0 }
                let noNote = snapshot(env.controller.handleAction("correct", payload: ["id": createdID, "note": "  "], documentID: documentID))
                check(noNote["notice"] as? String == "Say what is wrong with this node." && nothing(), "Correct without a note starts no job")
                let badExport = snapshot(env.controller.handleAction("export", payload: ["kind": "docx"], documentID: documentID))
                check(badExport["notice"] as? String == "Choose Markdown report or PDF." && nothing(), "an export that is not Markdown or PDF starts no job")
                let gone = snapshot(env.controller.handleAction("develop", payload: ["id": "n99", "direction": ""], documentID: documentID))
                check(gone["notice"] as? String == "That node no longer exists." && nothing(), "Expand topic on a node that is gone starts no job")
                let noLanguage = snapshot(env.controller.handleAction("translate", payload: ["language": " ", "mode": "copy"], documentID: documentID))
                check(noLanguage["notice"] as? String == "Choose a language." && nothing(), "Translate without a language starts no job")

                // Sources of findings.
                let traversal = snapshot(env.controller.handleAction("open", payload: ["source": "../outside.txt"], documentID: documentID))
                check(traversal["notice"] as? String == "Only files inside the project can be opened." && env.window.opened.isEmpty, "a source outside the project is not opened")
                let absolute = snapshot(env.controller.handleAction("open", payload: ["source": "/etc/hosts"], documentID: documentID))
                check(absolute["notice"] as? String == "Only files inside the project can be opened." && env.window.opened.isEmpty, "an absolute source path is not opened")
                let missing = snapshot(env.controller.handleAction("open", payload: ["source": "docs/missing.md"], documentID: documentID))
                check((missing["notice"] as? String ?? "").contains("does not exist in the project") && env.window.opened.isEmpty, "a source that is not a file says so")
                let badWeb = snapshot(env.controller.handleAction("open", payload: ["source": "http://not a url"], documentID: documentID))
                check(badWeb["notice"] as? String == "That web address is not valid.", "a web address that is not valid is refused")
                let okay = snapshot(env.controller.handleAction("open", payload: ["source": "docs/notes.md:2-4"], documentID: documentID))
                check(okay["notice"] as? String == "" && env.window.opened.count == 1 && env.window.opened[0].url.lastPathComponent == "notes.md"
                      && env.window.opened[0].line == 2 && env.window.opened[0].endLine == 4, "a project file with a line range opens at that range")
            }

            // 3. What a job hands to the next snapshot.
            print("\n-- notes from the jobs")
            do {
                let env = makeProject("notes")
                let key = env.map.standardizedFileURL.path
                env.controller.jobCreated[key] = "n2"
                env.controller.jobNotice[key] = "Report saved."
                func shot(_ text: String) -> [String: Any] {
                    (try? JSONSerialization.jsonObject(with: Data(env.controller.snapshotJSON(text: text, file: env.map).utf8)) as? [String: Any]) ?? [:]
                }
                let first = shot(read(env.map))
                let second = shot(read(env.map))
                check(first["created"] as? String == "n2" && first["notice"] as? String == "Report saved.", "the next snapshot carries the node and the notice a job left")
                check(second["created"] as? String == "" && second["notice"] as? String == "", "and only that one: they are used up")
                check(shot("not a map")["ok"] as? Bool == false, "text that is not a map gets the page's unreadable snapshot")
            }

            // 4. A map the app left researching.
            print("\n-- an interrupted map")
            do {
                let env = makeProject("interrupted", complete: false)
                env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
                let id = env.window.tabs[0].id
                check(parsed(read(env.map))?.status == .researching, "a new map says it is researching")
                let reply = snapshot(env.controller.handleAction("snapshot", payload: [:], documentID: id))
                check(parsed(read(env.map))?.status == .incomplete && reply["status"] as? String == "incomplete"
                      && (reply["incomplete"] as? String) == "the research was interrupted", "with no job working on it the map becomes incomplete, so Continue is offered")

                let stopped = makeProject("stopped", complete: false)
                stopped.window.tabs = [.init(url: stopped.map, text: read(stopped.map), modified: false)]
                _ = stopped.controller.handleAction("cancel", payload: [:], documentID: stopped.window.tabs[0].id)
                check(parsed(read(stopped.map))?.incompleteReason == "stopped", "Stop on a map no job works on says it was stopped")

                // With a job working on the map, nothing is settled.
                let running = makeProject("running", complete: false)
                running.window.tabs = [.init(url: running.map, text: read(running.map), modified: false)]
                running.controller.jobs.launch(kind: .mapDevelop, file: running.map, title: "Expand topic: x") { job in
                    job.update("Writing the map")
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    return nil
                }
                _ = await waitUntil { running.controller.jobs.mapJobInfo(for: running.map)?.step == "Writing the map" }
                let shot = snapshot(running.controller.handleAction("snapshot", payload: [:], documentID: running.window.tabs[0].id))
                check(parsed(read(running.map))?.status == .researching && (shot["job"] as? [String: Any])?["kind"] as? String == "develop"
                      && (shot["job"] as? [String: Any])?["step"] as? String == "Writing the map", "while a job works on it the map stays researching and the snapshot names the job and its step")
                running.tasks.cancelAll()
                _ = await waitUntil { running.controller.jobs.jobs.isEmpty }
            }

            // 5. A picture for a node.
            print("\n-- a picture for a node")
            do {
                let env = makeProject("picture")
                env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
                let id = env.window.tabs[0].id
                let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
                let failure = await env.controller.attachImage(["id": "n1", "name": "pic.png", "data": png], documentID: id)
                let node = parsed(read(env.map))?.node("n1")
                check(failure == "" && node?.image == "images/pic.png"
                      && fm.fileExists(atPath: env.map.deletingLastPathComponent().appendingPathComponent("images/pic.png").path),
                      "a picture is saved into images/ beside the map and set on the node")
                check(env.window.tab(env.map)?.text == read(env.map), "and the tab shows the node with it")
                let unreadable = await env.controller.attachImage(["id": "n1", "name": "x.png", "data": "!!!"], documentID: id)
                check(unreadable == "The picture could not be read.", "data that is not a picture is refused with the reason")
                let notPicture = await env.controller.attachImage(["id": "n1", "name": "x.png", "data": Data("hello".utf8).base64EncodedString()], documentID: id)
                check(notPicture == "Use a PNG, JPEG, GIF or WebP picture.", "a file of another kind is refused")
                let noNode = await env.controller.attachImage(["id": "", "name": "x.png", "data": png], documentID: id)
                check(noNode == "That node no longer exists.", "a picture for no node is refused")
                let closed = await env.controller.attachImage(["id": "n1", "name": "y.png", "data": png], documentID: UUID())
                check(closed == "" && parsed(read(env.map))?.node("n1")?.image == "images/pic.png", "a picture for a tab that is closed changes nothing")
            }

            // 6. The jobs' tasks belong to the window.
            print("\n-- jobs and the window's task bag")
            do {
                let env = makeProject("jobs")
                let jobs = env.controller.jobs
                var finished: [String] = []
                jobs.launch(kind: .mapDevelop, file: env.map, title: "Expand topic: a") { job in
                    job.update("Thinking")
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    finished.append("first")
                    return "Developing the branch stopped."
                }
                jobs.launch(kind: .mapDescribe, file: env.map, title: "Expand description: b") { _ in
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    finished.append("second")
                    return nil
                }
                let ids = jobs.jobs.map(\.id)
                check(ids.count == 2 && jobs.isRunning(on: env.map) && ids.allSatisfy { env.tasks.contains(key: "research.job.\($0)") },
                      "every job's task is in the window's bag")
                check(jobs.mapJobInfo(for: env.map)?.kind == "develop" && jobs.mapJobInfo(for: env.map)?.label == "Expand topic: a", "the map view is told about the first job on the map")
                let busy = jobs.developMap(file: env.map, node: "n1", direction: "")
                check(busy == "An AI job is already working on this map; develop the branch when it has finished.", "a second action on a map a job works on is refused")

                // The person's own Stop (the jobs bar): one job.
                jobs.cancel(ids[0])
                check(await waitUntil { jobs.jobs.count == 1 } && finished == ["first"] && jobs.message == "Developing the branch stopped.",
                      "Cancel in the jobs bar ends that job only, and its message is shown")
                // Closing the folder or the window: everything.
                env.tasks.cancelAll()
                check(await waitUntil { jobs.jobs.isEmpty } && finished.sorted() == ["first", "second"], "cancelling the window's bag stops every job that is left")
                check(!jobs.isRunning(on: env.map), "and the map is free for the next action")

                let again = makeProject("again")
                again.controller.jobs.launch(kind: .mapDevelop, file: again.map, title: "one") { _ in
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    return nil
                }
                again.controller.jobs.launch(kind: .mapDescribe, file: again.map, title: "two") { _ in
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    return nil
                }
                again.controller.jobs.cancelJobs(on: again.map)
                check(await waitUntil { again.controller.jobs.jobs.isEmpty }, "Stop on a map ends every job working on it")
                again.tasks.cancelAll()
            }

            // 7. The files a research reads.
            print("\n-- the files a research reads")
            do {
                let project = sandbox.appendingPathComponent("scope", isDirectory: true)
                let outside = sandbox.appendingPathComponent("scope-outside", isDirectory: true)
                write("# a", to: project.appendingPathComponent("docs/a.md"))
                write("let x = 1", to: project.appendingPathComponent("docs/sub/b.swift"))
                write("secret", to: outside.appendingPathComponent("secret.md"))
                try? Data([0x00, 0x01, 0x02, 0x00]).write(to: project.appendingPathComponent("docs/blob.bin"))
                try? fm.createSymbolicLink(at: project.appendingPathComponent("docs/escape.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
                let found = await ResearchScope.targetFiles(root: project, targets: [project.appendingPathComponent("docs")])
                check(found == ["docs/a.md", "docs/sub/b.swift"], "a folder target expands to its readable text files, never a binary or a link out of the project (found: \(found))")
                let single = await ResearchScope.targetFiles(root: project, targets: [project.appendingPathComponent("docs/a.md"), outside.appendingPathComponent("secret.md")])
                check(single == ["docs/a.md"], "a file target is kept, one outside the project is not")
                let listed = await ResearchScope.files(root: project, always: ["docs/a.md", "attached.md"])
                check(listed.contains("docs/a.md") && listed.contains("attached.md") && listed.filter { $0 == "docs/a.md" }.count == 1,
                      "the files of a research always include its targets and attachments, once")
            }
        }
        await run()
    }
}

extension ResearchMapTranslationHostTests {
    func testResearchMapStreamAndPrompts() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
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
    }
}
