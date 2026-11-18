import AppKit
import Foundation
import WebKit
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

extension ResearchMapTranslationHostTests {
    func testResearchMapDocumentRules() {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail(), line: line)
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

        // MARK: Operations: move a node under another parent (REQ-015, DEC-016)

        var reparent = map
        let grandchild = try! reparent.addChild(parent: large, title: "Grandchild")          // n5 under n4 under n2
        let sibling2 = try! reparent.addChild(parent: search, title: "Sibling two")        // n6 under n3
        try! reparent.moveVisual(id: nav, x: 10, y: 20)
        try! reparent.moveVisual(id: large, x: 30, y: 40)
        try! reparent.moveVisual(id: search, x: 50, y: 60)
        try! reparent.update(id: nav, color: "#112233")
        reparent.nodes[reparent.index(of: nav)!].evidence = [M.Evidence(label: .projectFact, text: "A fact.", source: "docs/a.md:3")]
        let before = reparent
        try! reparent.link(grandchild, sibling2)
        let linksBefore = reparent.links
        try! reparent.move(id: nav, to: search)
        check("a moved branch becomes the last child of the new parent, with its subtree", reparent.nodes.map(\.id) == ["n1", "n3", "n6", "n2", "n4", "n5"] && reparent.node(nav)!.parent == search)
        check("the descendants keep their parents", reparent.node(large)!.parent == nav && reparent.node(grandchild)!.parent == large)
        check("the moved nodes lose their hand-placed positions and the others keep theirs", reparent.node(nav)!.x == nil && reparent.node(large)!.y == nil && reparent.node(search)!.x == 50 && reparent.node("n1")!.x == nil)
        check("the other properties and the evidence stay", reparent.node(nav)!.color == "#112233" && reparent.node(nav)!.evidence.count == 1 && reparent.node(nav)!.title == "Project navigation")
        check("the logical connections stay", reparent.links == linksBefore)
        check("depth follows the new place", reparent.depth(of: nav) == 2 && reparent.depth(of: grandchild) == 4)
        check("the old parent keeps its other children in order", { var m = before; let a = try! m.addChild(parent: "n1", title: "A"); try! m.move(id: search, to: a); return m.children(of: "n1").map(\.id) == ["n2", a] }())
        check("a moved node is the last child, after the children the parent already has", reparent.children(of: search).map(\.id) == [sibling2, nav])
        check("moving a leaf under a branch puts it after the branch's subtree", { var m = before; try! m.move(id: search, to: nav); return m.nodes.map(\.id) == ["n1", "n2", "n4", "n5", "n3", "n6"] }())

        let unchanged = reparent
        check("the root cannot be moved", rejected { var m = reparent; try m.move(id: "n1", to: search) } == "The root node cannot be moved.")
        check("a node cannot become its own child", rejected { var m = reparent; try m.move(id: nav, to: nav) } == "A node cannot become its own child.")
        check("a node cannot be moved under its own descendant", rejected { var m = reparent; try m.move(id: nav, to: grandchild) } == "A node cannot be moved under one of its own descendants.")
        check("moving under the current parent is refused", rejected { var m = reparent; try m.move(id: nav, to: search) }?.contains("already the parent") == true)
        check("an unknown node or parent is refused", rejected { var m = reparent; try m.move(id: "n99", to: search) } != nil && rejected { var m = reparent; try m.move(id: nav, to: "n99") } != nil)
        check("a refused move changes nothing", { var m = reparent; _ = rejected { try m.move(id: nav, to: grandchild) }; return m == unchanged }())
        check("the new parent survives a file round trip", { if case .success(let again) = M.parse(reparent.markdown()) { return again.nodes.map(\.id) == reparent.nodes.map(\.id) && again.nodes.map(\.parent) == reparent.nodes.map(\.parent) && again.links == reparent.links } else { return false } }())

        // MARK: A picture beside the icon (REQ-017, DEC-018)

        var pictured = map
        try! pictured.update(id: nav, icon: "🧭", image: "images/nav.png")
        check("a node keeps both its icon and its picture", pictured.node(nav)!.icon == "🧭" && pictured.node(nav)!.image == "images/nav.png")
        check("the picture is one property line", pictured.markdown().contains("- image: images/nav.png"))
        check("a map without pictures writes no image line", !map.markdown().contains("- image:"))
        check("the picture survives a file round trip with the icon", { if case .success(let again) = M.parse(pictured.markdown()) { return again.node(nav)!.image == "images/nav.png" && again.node(nav)!.icon == "🧭" && again == pictured } else { return false } }())
        check("the picture is in the snapshot for the page", ((pictured.snapshot()["nodes"] as? [[String: Any]])?.first { ($0["id"] as? String) == nav }?["image"] as? String) == "images/nav.png")
        check("an https address is accepted", { var m = pictured; try! m.update(id: nav, image: "https://example.com/a.png"); return m.node(nav)!.image == "https://example.com/a.png" }())
        check("an empty value clears the picture and keeps the icon", { var m = pictured; try! m.update(id: nav, image: ""); return m.node(nav)!.image.isEmpty && m.node(nav)!.icon == "🧭" }())
        check("an absent value leaves the picture alone", { var m = pictured; try! m.update(id: nav, title: "Renamed"); return m.node(nav)!.image == "images/nav.png" }())
        for bad in ["../secret.png", "images/../../secret.png", "/etc/passwd", "~/a.png", "file:///etc/passwd", "http://example.com/a.png", "javascript:alert(1)", "data:image/png;base64,AAAA", "images\\a.png", "images//a.png", "images/a.png?x=1", "https://", String(repeating: "a", count: 400)] {
            check("a picture address is refused: \(bad.prefix(30))", rejected { var m = pictured; try m.update(id: nav, image: bad) } == "A picture is a file inside the project or an https address.")
        }
        check("a refused picture changes nothing", { var m = pictured; _ = rejected { try m.update(id: nav, title: "Changed", image: "../x.png") }; return m == pictured }())
        check("a hand-written bad address is dropped when the file is read", { let text = pictured.markdown().replacingOccurrences(of: "- image: images/nav.png", with: "- image: ../secret.png"); if case .success(let again) = M.parse(text) { return again.node(nav)!.image.isEmpty } else { return false } }())
        check("a path with a space is allowed", M.isImageAddress("images/my picture.png"))

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
    }
}

extension ResearchMapTranslationHostTests {
    func testResearchMapReportRules() {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail(), line: line)
        }
        typealias M = ResearchMap
        typealias R = ResearchMapReport

        func codes(_ problems: [R.Problem]) -> Set<String> { Set(problems.map { $0.code.rawValue }) }
        func has(_ problems: [R.Problem], _ code: R.Problem.Code) -> Bool { problems.contains { $0.code == code } }
        func message(_ problems: [R.Problem], _ code: R.Problem.Code) -> String { problems.first { $0.code == code }?.message ?? "" }
        func setNode(_ map: inout M, _ id: String, _ change: (inout M.Node) -> Void) {
            guard let i = map.nodes.firstIndex(where: { $0.id == id }) else { return }
            change(&map.nodes[i])
        }
        func repeated(_ text: String, _ times: Int) -> String { Array(repeating: text, count: times).joined(separator: " ") }

        // MARK: Fixture 1: a small hand-built map with a diagram node and an image node

        var small = M.new(id: "release", question: "How should we make releases safer?", created: "2026-11-05", targets: [], attachments: [])
        let nBuild = try! small.addChild(parent: "n1", title: "Build")
        let nTest = try! small.addChild(parent: "n1", title: "Test")
        let nFlow = try! small.addChild(parent: "n1", title: "Deploy flow")
        let nShot = try! small.addChild(parent: nFlow, title: "Staging screenshot")
        let nBack = try! small.addChild(parent: "n1", title: "Rollback")
        let nNotary = try! small.addChild(parent: nBuild, title: "Notarization")
        let nRisk = try! small.addChild(parent: "n1", title: "Open risks")
        let flowSource = "flowchart LR\n  A[Build] --> B[Test]\n  B --> C[Deploy]"
        setNode(&small, "n1") { $0.description = "Releases are built by one script and published by hand." }
        setNode(&small, nBuild) {
            $0.description = "The build script signs the app."
            $0.evidence = [M.Evidence(label: .projectFact, text: "The script signs the app with the developer identity.", source: "release.sh:12")]
        }
        setNode(&small, nTest) {
            $0.description = "Standalone suites run the pure modules."
            $0.evidence = [M.Evidence(label: .projectFact, text: "Suites live under tools/tests.", source: "tools/tests/run.sh:3"),
                           M.Evidence(label: .aiInference, text: "Coverage of the UI is thin.", source: "")]
        }
        setNode(&small, nFlow) {
            $0.visual = "diagram"
            $0.description = "```mermaid\n\(flowSource)\n```\n\nThe flow in short."
        }
        setNode(&small, nShot) {
            $0.visual = "image"
            $0.description = "![Staging dashboard](images/staging.png)"
        }
        setNode(&small, nBack) {
            $0.description = "A bad release must be undone quickly."
            $0.evidence = [M.Evidence(label: .externalFact, text: "Blue-green deployment allows an instant rollback.", source: "https://example.com/blue-green"),
                           M.Evidence(label: .projectFact, text: "The script can republish the previous build.", source: "release.sh:30")]
        }
        setNode(&small, nNotary) {
            $0.evidence = [M.Evidence(label: .projectFact, text: "Notarization is waited for.", source: "release.sh:45")]
        }
        setNode(&small, nRisk) {
            $0.evidence = [M.Evidence(label: .openAssumption, text: "The notary service stays available.", source: "")]
        }
        let smallIDs = small.nodes.map { $0.id }

        let smallDraft = R.Draft(
            title: "Safer releases",
            sections: [
                R.Draft.Section(heading: "Why releases need care", markdown: "Shipping the app is a chain of small steps that one person runs by hand, so a mistake in any of them reaches every user. This report follows the chain from the build to the way back after a bad release and says what is known and what is only assumed.", covers: ["n1"]),
                R.Draft.Section(heading: "Building and testing", markdown: "The build script signs the app with the developer identity and then waits for notarization [1]. The standalone suites under the test folder cover the pure modules [2], although the coverage of the interface looks thin, which is an inference and not something measured.", covers: [nBuild, nTest, nNotary]),
                R.Draft.Section(heading: "Deploying and going back", markdown: "The deployment runs in the order shown below, and a screenshot of the staging dashboard shows what a good run looks like.\n\n{{node:\(nFlow)}}\n\n{{node:\(nShot)}}\n\nIf a release turns out bad, the script can publish the previous build again [1], and a blue-green set-up would make that instant [3].\n\n{{diagram:d1}}", covers: [nFlow, nShot, nBack]),
                R.Draft.Section(heading: "What stays open", markdown: "Everything above assumes that the notary service stays available when a release is made. If it does not, the release waits, and nothing in the process says for how long. That risk is the main open question, and it should be settled before the process is called safe.", covers: [nRisk]),
            ],
            diagrams: [R.Draft.Diagram(id: "d1", kind: "flowchart", what: "The decision to roll back a bad release")])

        // MARK: Fixture 2: a larger generated map (6 branches, 61 nodes) and, when present, the real map of the project

        var big = M.new(id: "big", question: "What does the system do?", created: "2026-11-05", targets: [], attachments: [])
        var bigBranches: [String] = []
        for b in 1...6 {
            let branch = try! big.addChild(parent: "n1", title: "Branch \(b)")
            bigBranches.append(branch)
            setNode(&big, branch) { $0.description = "The \(b). branch." }
            for c in 1...3 {
                let child = try! big.addChild(parent: branch, title: "Topic \(b).\(c)")
                setNode(&big, child) {
                    $0.description = "What topic \(b).\(c) found."
                    $0.evidence = [M.Evidence(label: .projectFact, text: "Fact \(b).\(c)", source: "src/branch\(b)/file\(c).swift:\(c * 10)")]
                }
                for d in 1...2 {
                    let leaf = try! big.addChild(parent: child, title: "Detail \(b).\(c).\(d)")
                    setNode(&big, leaf) { $0.evidence = [M.Evidence(label: .aiInference, text: "Inference \(b).\(c).\(d)", source: "")] }
                }
            }
        }

        func subtree(_ map: M, _ id: String) -> [String] { [id] + map.children(of: id).flatMap { subtree(map, $0.id) } }

        /// A report in the shape of a story: an introduction, one section per branch of the root, a closing section.
        func narrative(_ map: M) -> R.Draft {
            let paragraph = "Эта часть карты собрана из нескольких связанных наблюдений, и вместе они показывают, как устроена соответствующая часть процесса: сначала описано нынешнее состояние, затем то, что из него следует, и наконец то, что остаётся неясным и требует проверки [1]. "
            var sections = [R.Draft.Section(heading: "Введение", markdown: repeated(paragraph, 4), covers: ["n1"])]
            for branch in map.children(of: "n1") {
                sections.append(R.Draft.Section(heading: branch.title, markdown: repeated(paragraph, 5) + "\n\n" + repeated(paragraph, 3), covers: subtree(map, branch.id)))
            }
            sections.append(R.Draft.Section(heading: "Выводы и открытые вопросы", markdown: repeated(paragraph, 4), covers: []))
            return R.Draft(title: "Отчёт", sections: sections, diagrams: [])
        }

        /// The old one-to-one report (ResearchMapExport.swift) reshaped into the answer format: a section per heading of the report.
        func reshaped(_ map: M) -> R.Draft {
            let lines = map.report(mapName: "map.md").components(separatedBy: "\n")
            var sections: [R.Draft.Section] = []
            var heading = "Question"
            var body: [String] = []
            var covers = ["n1"]
            var next = 1
            func flush() {
                sections.append(R.Draft.Section(heading: heading, markdown: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), covers: covers))
                body = []
            }
            for line in lines.dropFirst() {
                if line.hasPrefix("##") {
                    flush()
                    heading = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    covers = next < map.nodes.count ? [map.nodes[next].id] : []
                    next += 1
                } else {
                    body.append(line)
                }
            }
            flush()
            return R.Draft(title: map.title, sections: sections, diagrams: [])
        }

        // MARK: Sources

        let smallSources = R.sources(of: small)
        check("sources are the distinct files and addresses of the evidence, numbered in map order", smallSources.map { $0.location } == ["release.sh", "tools/tests/run.sh", "https://example.com/blue-green"] && smallSources.map { $0.number } == [1, 2, 3])
        check("a file keeps the lines that are cited, once each, ascending (the evidence is spread over the map in another order)", smallSources[0].lines == ["12", "30", "45"] && smallSources[2].lines.isEmpty)
        check("a source keeps the label of each piece of evidence", smallSources[0].labels == [.projectFact, .projectFact, .projectFact] && smallSources[2].labels == [.externalFact] && smallSources[2].isWeb && !smallSources[0].isWeb)
        check("evidence without a source is not a source", smallSources.count == 3)
        check("a line range is split off the path", R.splitSource("a/b.swift:10-20").location == "a/b.swift" && R.splitSource("a/b.swift:10-20").lines == "10-20" && R.splitSource("a/b.swift").lines == nil)
        check("a web address keeps its colons", R.splitSource("https://x.org:8080/a").location == "https://x.org:8080/a" && R.splitSource("https://x.org:8080/a").isWeb)

        // MARK: The request

        let smallPrompt = R.prompt(map: small, mapName: "release.md")
        check("the request names every node id", smallIDs.allSatisfy { smallPrompt.user.contains("NODE \($0) |") })
        let bigPrompt = R.prompt(map: big, mapName: "big.md")
        check("the request names every node id of a large map", big.nodes.allSatisfy { bigPrompt.user.contains("NODE \($0.id) |") })
        check("the request numbers the sources", smallPrompt.user.contains("[1] release.sh (lines 12, 30, 45)") && smallPrompt.user.contains("[3] https://example.com/blue-green"))
        check("evidence in the request says which source it cites", smallPrompt.user.contains("The script signs the app with the developer identity. [source 1]") && smallPrompt.user.contains("Coverage of the UI is thin.\n") )
        check("the request carries the question and the map's file name", smallPrompt.user.contains("How should we make releases safer?") && smallPrompt.user.contains("MAP FILE: release.md"))
        check("the request lists the diagram and image nodes for placeholders", smallPrompt.user.contains("\(nFlow) \"Deploy flow\" (diagram)") && smallPrompt.user.contains("\(nShot) \"Staging screenshot\" (image)"))
        check("the request does not hand over a diagram's source or an image's path", !smallPrompt.user.contains("flowchart LR") && !smallPrompt.user.contains("images/staging.png") && smallPrompt.user.contains("[the diagram]"))
        check("the system prompt forbids a node-by-node outline and a bullet per node", smallPrompt.system.contains("NEVER write a node-by-node outline or a bullet per node"))
        check("the system prompt asks for paragraphs, a conclusion and open questions", smallPrompt.system.contains("narrative") && smallPrompt.system.contains("open questions"))
        check("the system prompt names the placeholders, the diagram limit and the kinds", smallPrompt.system.contains("{{node:ID}}") && smallPrompt.system.contains("{{diagram:d1}}") && smallPrompt.system.contains("At most \(R.maxDiagrams) diagrams") && R.diagramKinds.allSatisfy { smallPrompt.system.contains($0) })
        check("the system prompt asks for citations by number and for JSON only", smallPrompt.system.contains("Cite only numbers from that list") && smallPrompt.system.contains("one JSON object and nothing else"))
        let russianPrompt = R.prompt(map: small, mapName: "release.md", language: "Русский")
        check("with no language chosen the report follows the language of the question", smallPrompt.system.contains("Write the whole report in the language of the question.") && !smallPrompt.system.contains("Write the whole report in Русский") && R.prompt(map: small, mapName: "m", language: "  ").system.contains("in the language of the question"))
        check("a language chosen at export time is the instruction, headings included, and what must not be translated is named", russianPrompt.system.contains("Write the whole report in Русский: the title, the section headings") && russianPrompt.system.contains("Keep node titles you quote, file paths, web addresses, Mermaid code and code identifiers exactly as they are") && !russianPrompt.system.contains("in the language of the question"))
        check("the language does not change the map part of the request", russianPrompt.user == smallPrompt.user)
        check("a map without sources tells the model to cite nothing", R.prompt(map: M.new(id: "e", question: "Q", created: "d", targets: [], attachments: []), mapName: "e.md").user.contains("write no citations"))
        check("an incomplete map says so in the request", { var m = small; m.markIncomplete("stopped"); return R.prompt(map: m, mapName: "x").user.contains("STATUS: incomplete (stopped)") }())
        check("a long description is cut", { var m = small; setNode(&m, nTest) { $0.description = String(repeating: "word ", count: 1000) }; let p = R.prompt(map: m, mapName: "x").user; return p.count < R.prompt(map: small, mapName: "x").user.count + 1500 && p.contains("…") }())
        check("connections are in the request", { var m = small; try! m.link(nBuild, nTest); let user = R.prompt(map: m, mapName: "x").user; return user.contains("CONNECTIONS") && user.contains("\(nBuild) \"Build\" <-> \(nTest) \"Test\"") }())
        check("a map without connections has no such block", !smallPrompt.user.contains("CONNECTIONS"))
        check("the answer schema is valid JSON Schema data", JSONSerialization.isValidJSONObject(R.answerSchema))

        // MARK: Reading the answer

        func json(_ draft: R.Draft) -> String {
            var object: [String: Any] = [
                "title": draft.title,
                "sections": draft.sections.map { ["heading": $0.heading, "markdown": $0.markdown, "covers": $0.covers] as [String: Any] },
                "diagrams": draft.diagrams.map { ["id": $0.id, "kind": $0.kind, "what": $0.what] },
            ]
            if !draft.sourcesHeading.isEmpty { object["sourcesHeading"] = draft.sourcesHeading }
            return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func parsedDraft(_ text: String) -> R.Draft? { if case .success(let d) = R.parse(text) { return d }; return nil }
        func failure(_ text: String) -> R.Failure? { if case .failure(let f) = R.parse(text) { return f }; return nil }

        let smallJSON = json(smallDraft)
        check("plain JSON is read back to the same draft", parsedDraft(smallJSON) == smallDraft)
        check("a fenced json block with prose around it is read", parsedDraft("Here is the report:\n\n```json\n\(smallJSON)\n```\n\nI hope it helps.") == smallDraft)
        check("prose with braces before the object does not hide it", parsedDraft("The {map} has {{x}} nodes. Answer: \(smallJSON)") == smallDraft)
        check("placeholders and braces inside strings do not end the object early", parsedDraft(smallJSON)?.sections[2].markdown.contains("{{diagram:d1}}") == true)
        check("garbage has no JSON", failure("no json at all") == .noJSON && failure("") == .noJSON && failure("{ \"title\": ") == .noJSON)
        check("an object without sections is not an answer", failure("{\"title\": \"x\"}") == .noJSON)
        check("empty sections are malformed", { if case .malformed? = failure("{\"sections\": []}") { return true }; return false }())
        check("a section of the wrong shape is malformed and says which", { if case .malformed(let why)? = failure("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\", \"covers\": []}, {\"heading\": 3}]}") { return why.contains("section 2") }; return false }())
        check("covers of the wrong type are malformed", { if case .malformed? = failure("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\", \"covers\": \"n1\"}]}") { return true }; return false }())
        check("a missing covers list is an empty one", parsedDraft("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\"}]}")?.sections.first?.covers == [])
        check("a diagram of the wrong shape is malformed", { if case .malformed? = failure("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\"}], \"diagrams\": [{\"id\": \"d1\"}]}") { return true }; return false }())
        check("the diagram kind is lower-cased and trimmed", parsedDraft("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\"}], \"diagrams\": [{\"id\": \" d1 \", \"kind\": \" Flowchart \", \"what\": \"x\"}]}")?.diagrams.first == R.Draft.Diagram(id: "d1", kind: "flowchart", what: "x"))
        check("a null diagrams list is none", parsedDraft("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\"}], \"diagrams\": null}")?.diagrams == [])
        check("the Sources heading is kept when it is plain and dropped when it is not", parsedDraft("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\"}], \"sourcesHeading\": \"Источники\"}")?.sourcesHeading == "Источники" && parsedDraft("{\"sections\": [{\"heading\": \"a\", \"markdown\": \"b\"}], \"sourcesHeading\": \"<b>Sources</b>\"}")?.sourcesHeading == "")
        check("a failure has a message for the repair round", R.Failure.noJSON.message.contains("JSON") && R.Failure.malformed("x").message.contains("x"))

        // MARK: Checks: a good narrative passes

        check("a narrative of the small map passes every check", R.check(draft: smallDraft, map: small).isEmpty)
        check("a narrative of the large map passes every check", R.check(draft: narrative(big), map: big).isEmpty)

        // MARK: Checks: the old one-to-one report is rejected

        let bigOutline = reshaped(big)
        check("the old numbered-heading report reshaped into the answer format is rejected as an outline", has(R.check(draft: bigOutline, map: big), .headingPerNode))
        check("the rejection says how many headings there are and what to do", message(R.check(draft: bigOutline, map: big), .headingPerNode).contains("61 nodes") && message(R.check(draft: bigOutline, map: big), .headingPerNode).contains("fewer sections"))
        var smallOutlineMap = small
        setNode(&smallOutlineMap, nFlow) { $0.visual = ""; $0.description = "How the deployment runs." }
        setNode(&smallOutlineMap, nShot) { $0.visual = ""; $0.description = "The staging dashboard." }
        let smallOutline = reshaped(smallOutlineMap)
        check("the old report of a small map reshaped the same way is rejected too", has(R.check(draft: smallOutline, map: smallOutlineMap), .headingPerNode))

        func bullets(_ count: Int) -> String { (1...count).map { "- Finding number \($0) is stated here as a short line of about eighty characters long" }.joined(separator: "\n") }
        let listDraft = R.Draft(title: "t", sections: [
            R.Draft.Section(heading: "Introduction", markdown: "This report lists what the map found about releases and how sure we are of each point in it.\n\n" + bullets(6), covers: ["n1", nBuild]),
            R.Draft.Section(heading: "Body", markdown: "The findings of the body of the map follow in the list below, one line each, in map order.\n\n" + bullets(8), covers: [nTest, nFlow, nShot]),
            R.Draft.Section(heading: "Conclusions", markdown: "The open points are listed here, and each of them needs a decision before the release process is changed.\n\n" + bullets(6), covers: [nBack, nNotary, nRisk]),
        ], diagrams: [])
        let listProblems = R.check(draft: listDraft, map: small)
        check("a draft that is mostly bullet points is rejected", has(listProblems, .nodeList) && !has(listProblems, .headingPerNode))
        check("the bullet rejection gives the share", message(listProblems, .nodeList).contains("% of the text is bullet points"))
        check("a short list inside a narrative is fine", { var d = smallDraft; d.sections[3].markdown += "\n\n- First, ask the notary service for its limits.\n- Second, decide how long a release may wait.\n- Third, write the answer into the process."; return R.check(draft: d, map: small).isEmpty }())
        check("a list continued on indented lines still counts as one list", { var d = listDraft; d.sections = d.sections.map { var s = $0; s.markdown = s.markdown.replacingOccurrences(of: "long", with: "long\n  and a second line of the same item"); return s }; return has(R.check(draft: d, map: small), .nodeList) }())

        let thinDraft = R.Draft(title: "t", sections: [
            R.Draft.Section(heading: "Introduction", markdown: "The question and the answer in brief, written in a couple of sentences so that the introduction has prose to start with.", covers: ["n1", nBuild, nTest]),
            R.Draft.Section(heading: "A", markdown: "Short.", covers: [nFlow]),
            R.Draft.Section(heading: "B", markdown: "Short.", covers: [nShot, nBack]),
            R.Draft.Section(heading: "C", markdown: "Short.", covers: [nNotary, nRisk]),
        ], diagrams: [])
        check("sections with almost no prose are rejected", has(R.check(draft: thinDraft, map: small), .thinProse))
        check("a report too short for its map is rejected", has(R.check(draft: thinDraft, map: small), .tooShort) && has({ var d = narrative(big); d.sections = d.sections.map { var s = $0; s.markdown = String(s.markdown.prefix(150)); return s }; return R.check(draft: d, map: big) }(), .tooShort))

        // MARK: Checks: structure and coverage

        check("fewer than three sections is rejected", has(R.check(draft: R.Draft(title: "t", sections: Array(smallDraft.sections.prefix(2)), diagrams: []), map: small), .structure))
        check("an empty introduction is rejected", { var d = smallDraft; d.sections[0].markdown = ""; return has(R.check(draft: d, map: small), .structure) }())
        check("a section without a heading is rejected", { var d = smallDraft; d.sections[1].heading = ""; return has(R.check(draft: d, map: small), .structure) }())
        check("a dropped node is reported with its id and title", { var d = smallDraft; d.sections[1].covers = [nBuild, nTest]; let p = R.check(draft: d, map: small); return has(p, .missingNodes) && message(p, .missingNodes).contains("\(nNotary) \"Notarization\"") && !message(p, .missingNodes).contains("\(nTest) \"Test\"") }())
        check("a node that is covered twice is fine", { var d = smallDraft; d.sections[3].covers.append(nBuild); return R.check(draft: d, map: small).isEmpty }())
        check("an id that is not a node is reported", { var d = smallDraft; d.sections[3].covers.append("n99"); let p = R.check(draft: d, map: small); return has(p, .unknownNodes) && message(p, .unknownNodes).contains("n99") }())
        check("a large map reports how many nodes are missing beyond the list", { var d = narrative(big); d.sections = [d.sections[0], d.sections[1]]; return message(R.check(draft: d, map: big), .missingNodes).contains("and 10 more") }())

        // MARK: Checks: citations

        check("a citation of a source the map does not have is reported", { var d = smallDraft; d.sections[1].markdown += " It was also said elsewhere [47]."; let p = R.check(draft: d, map: small); return has(p, .badCitation) && message(p, .badCitation).contains("[47]") && message(p, .badCitation).contains("[1] to [3]") }())
        check("citation [0] is reported", { var d = smallDraft; d.sections[1].markdown += " Zero [0]."; return has(R.check(draft: d, map: small), .badCitation) }())
        check("several citations in one bracket and ranges are checked one by one", { var d = smallDraft; d.sections[1].markdown += " Both [1, 2] and [1-3] are fine."; let ok = R.check(draft: d, map: small).isEmpty; d.sections[1].markdown += " But [2, 5] and [3-6] are not."; return ok && has(R.check(draft: d, map: small), .badCitation) }())
        check("the numbers of a citation are read from the text", R.citations(in: "A [1] b [2, 3] c [4-6] d [7](http://x.org) e `x[9]`") == [1, 2, 3, 4, 5, 6])
        check("code and links are not citations", { var d = smallDraft; d.sections[1].markdown += " The array `items[7]` and [8](https://example.com/blue-green) are no citations.\n\n```\nlet a = b[12]\n```"; return !has(R.check(draft: d, map: small), .badCitation) }())
        check("a map without sources allows no citation", { var d = smallDraft; d.sections[1].markdown = "Plain text without sources is fine and long enough to be prose for the check [1]."; return has(R.check(draft: d, map: M.new(id: "e", question: "Q", created: "d", targets: [], attachments: [])), .badCitation) }())

        // MARK: Checks: placeholders and diagrams

        func with(_ edit: (inout R.Draft) -> Void) -> [R.Problem] { var d = smallDraft; edit(&d); return R.check(draft: d, map: small) }
        check("a placeholder of an unknown kind is malformed", has(with { $0.sections[1].markdown += "\n\n{{picture:x}}" }, .badPlaceholder))
        check("a placeholder without an id is malformed", has(with { $0.sections[1].markdown += "\n\n{{node}}" }, .badPlaceholder))
        check("the old placeholder with a pipe is malformed", has(with { $0.sections[1].markdown += "\n\n{{diagram:flowchart|the flow}}" }, .badPlaceholder))
        check("a placeholder inside a sentence is malformed", has(with { $0.sections[1].markdown += " See {{node:\(nFlow)}} for the flow." }, .badPlaceholder))
        check("an unclosed placeholder is malformed", has(with { $0.sections[1].markdown += "\n\n{{node:\(nFlow)" }, .badPlaceholder))
        check("{{node:ID}} of a node without a picture is reported", { let p = with { $0.sections[1].markdown += "\n\n{{node:\(nTest)}}" }; return has(p, .badNodePlaceholder) && message(p, .badNodePlaceholder).contains(nTest) }())
        check("{{node:ID}} of a node that does not exist is reported", has(with { $0.sections[1].markdown += "\n\n{{node:n99}}" }, .badNodePlaceholder))
        check("{{node:ID}} of the same picture twice is allowed", with { $0.sections[2].markdown += "\n\n{{node:\(nFlow)}}" }.isEmpty)
        check("a diagram requested and not placed is reported", { let p = with { $0.sections[2].markdown = $0.sections[2].markdown.replacingOccurrences(of: "{{diagram:d1}}", with: "") }; return has(p, .diagramNotPlaced) && message(p, .diagramNotPlaced).contains("d1") }())
        check("a diagram placed twice is reported", { let p = with { $0.sections[3].markdown += "\n\n{{diagram:d1}}" }; return has(p, .diagramPlacedTwice) && message(p, .diagramPlacedTwice).contains("2 times") }())
        check("a placeholder for a diagram that was never requested is reported", has(with { $0.sections[3].markdown += "\n\n{{diagram:d7}}" }, .badDiagramRequest))
        check("a diagram with an unknown kind is reported", has(with { $0.diagrams[0].kind = "mindmap" }, .badDiagramRequest))
        check("a diagram with a bad id, no description or a repeated id is reported", has(with { $0.diagrams[0].id = "flow" }, .badDiagramRequest) && has(with { $0.diagrams[0].what = "" }, .badDiagramRequest) && has(with { $0.diagrams.append($0.diagrams[0]) }, .badDiagramRequest))
        check("every diagram kind that DiagramKind knows is accepted", R.diagramKinds.allSatisfy { kind in with { $0.diagrams[0].kind = kind }.isEmpty })
        check("more than the maximum of diagrams is reported", { let p = with { d in for n in 2...(R.maxDiagrams + 1) { d.diagrams.append(R.Draft.Diagram(id: "d\(n)", kind: "flowchart", what: "x")); d.sections[3].markdown += "\n\n{{diagram:d\(n)}}" } }; return has(p, .tooManyDiagrams) && R.maxDiagrams == 8 }())
        check("exactly the maximum is fine", with { d in for n in 2...R.maxDiagrams { d.diagrams.append(R.Draft.Diagram(id: "d\(n)", kind: "pipeline", what: "x")); d.sections[3].markdown += "\n\n{{diagram:d\(n)}}" } }.isEmpty)
        check("a placeholder inside a code block is not one", { let p = with { $0.sections[1].markdown += "\n\n```\n{{broken\n```" }; return !has(p, .badPlaceholder) }())

        // MARK: Checks: nothing the map does not contain

        check("an HTML tag is reported", has(with { $0.sections[1].markdown += " <div class=\"x\">boxed</div>" }, .unsafe))
        check("a script tag is reported", has(with { $0.sections[1].markdown += " <script>alert(1)</script>" }, .unsafe))
        check("a javascript: link is reported", has(with { $0.sections[1].markdown += " [click](javascript:alert(1))" }, .unsafe))
        check("a click directive is reported", has(with { $0.sections[1].markdown += "\n\nclick A href \"http://evil.example\"" }, .unsafe))
        check("HTML in a heading or in the title is reported", has(with { $0.sections[1].heading = "<b>Build</b>" }, .unsafe) && has(with { $0.title = "<img src=x>" }, .unsafe))
        check("an autolink, a comparison and code with angle brackets are fine", with { $0.sections[1].markdown += " See <https://example.com/blue-green> for it; 3 < 4 and a > b hold, and `List<Int>` is code." }.isEmpty)
        check("a Mermaid block written by the model is reported", has(with { $0.sections[1].markdown += "\n\n```mermaid\nflowchart LR\n A --> B\n```" }, .rawDiagram))
        check("an image written by the model is reported", has(with { $0.sections[1].markdown += "\n\n![x](images/x.png)" }, .rawImage))
        check("a link to an address that is not in the map is reported", { let p = with { $0.sections[1].markdown += " Read [this](https://invented.example/page)." }; return has(p, .invented) && message(p, .invented).contains("invented.example") }())
        check("a bare address that is not in the map is reported", has(with { $0.sections[1].markdown += " See https://invented.example/page." }, .invented))
        check("a file path that is not in the map is reported", { let p = with { $0.sections[1].markdown += " The code is in `Sources/Invented.swift:12`." }; return has(p, .invented) && message(p, .invented).contains("Sources/Invented.swift") }())
        check("an address and a path that the map names are fine", with { $0.sections[1].markdown += " See https://example.com/blue-green and `tools/tests/run.sh:3` and `release.sh`." }.isEmpty)
        check("a path that a description names is fine", { var m = small; setNode(&m, nTest) { $0.description = "Suites live in docs/features/slug/overview.md too." }; var d = smallDraft; d.sections[1].markdown += " See `docs/features/slug/overview.md`."; return R.check(draft: d, map: m).isEmpty }())

        // MARK: Repair

        let repairProblems = with { $0.sections[1].covers = [nBuild]; $0.sections[1].markdown += " <b>x</b>" }
        let repair = R.repairPrompt(problems: repairProblems, previousAnswer: "{\"old\": true}")
        check("the repair prompt lists every problem and the previous answer", repairProblems.count >= 2 && repairProblems.enumerated().allSatisfy { repair.contains("\($0.offset + 1). \($0.element.message)") } && repair.contains("YOUR PREVIOUS ANSWER:") && repair.contains("{\"old\": true}"))
        check("the repair prompt without a previous answer has no such block", !R.repairPrompt(problems: repairProblems).contains("PREVIOUS ANSWER"))

        // MARK: Assembly

        let supplied = ["d1": "flowchart TD\n  Bad[Bad release] --> Undo[Republish previous build]"]
        let built = R.assemble(draft: smallDraft, map: small, diagrams: supplied, mapName: "release.md", date: "2026-11-05")
        let text = built.markdown
        check("the report starts with the title and the byline", text.hasPrefix("# Safer releases\n\n*`release.md` · 2026-11-05*\n\n## Why releases need care\n"))
        check("every section has its heading in order", ["## Why releases need care", "## Building and testing", "## Deploying and going back", "## What stays open", "## Sources"].map { text.range(of: $0)?.lowerBound }.compactMap { $0 }.count == 5 && text.range(of: "## Why releases")! .lowerBound < text.range(of: "## What stays open")!.lowerBound)
        check("a diagram node is placed as its Mermaid block", text.contains("```mermaid\n\(flowSource)\n```"))
        check("an image node is placed as its image line", text.contains("![Staging dashboard](images/staging.png)"))
        check("a requested diagram is placed as a Mermaid block where the placeholder stood", text.contains("```mermaid\nflowchart TD\n  Bad[Bad release] --> Undo[Republish previous build]\n```") && text.contains("instant [3].\n\n```mermaid"))
        check("no placeholder is left in the report", !text.contains("{{") && !text.contains("}}") && built.droppedDiagrams.isEmpty && built.emptyVisuals.isEmpty)
        check("the pictures stand between the sentences they belong to", text.contains("what a good run looks like.\n\n```mermaid\nflowchart LR") && text.contains("```\n\n![Staging dashboard]"))
        check("the Sources list is built from the evidence", text.contains("## Sources\n\n- [1] `release.sh` (12, 30, 45) — Project fact ×3\n- [2] `tools/tests/run.sh` (3) — Project fact\n- [3] <https://example.com/blue-green> — External fact\n"))
        check("citations in the text stay as they are", text.contains("waiting for notarization [1]") || text.contains("waits for notarization [1]"))
        var lying = smallDraft
        lying.sections[3].markdown += "\n\n## Sources\n\n- [9] `invented/path.swift` — Project fact"
        let lied = R.assemble(draft: lying, map: small, diagrams: supplied).markdown
        let liedList = lied.components(separatedBy: "\n## Sources\n").last ?? ""
        check("a Sources list the model wrote is caught by the checks, and the final list comes from the evidence only", has(R.check(draft: lying, map: small), .invented) && liedList.hasPrefix("\n- [1] `release.sh` (12, 30, 45) — Project fact ×3\n") && !liedList.contains("[9]") && lied.components(separatedBy: "\n## Sources\n").count == 2)
        check("headings the model writes are kept below the section's own", { var d = smallDraft; d.sections[1].markdown += "\n\n# Big\n\n## Medium"; let t = R.assemble(draft: d, map: small, diagrams: supplied).markdown; return t.contains("\n### Big\n") && t.contains("\n### Medium\n") && !t.contains("\n# Big") && !t.contains("\n## Medium") }())
        check("a diagram that was not supplied is dropped quietly and reported", { let a = R.assemble(draft: smallDraft, map: small, diagrams: [:]); return a.droppedDiagrams == ["d1"] && !a.markdown.contains("Undo[") && !a.markdown.contains("{{") && !a.markdown.contains("\n\n\n") }())
        check("a supplied diagram that is empty or unsafe is dropped", { let a = R.assemble(draft: smallDraft, map: small, diagrams: ["d1": "  "]); let b = R.assemble(draft: smallDraft, map: small, diagrams: ["d1": "flowchart LR\n  A --> B\n  click A href \"http://x\""]); return a.droppedDiagrams == ["d1"] && b.droppedDiagrams == ["d1"] && !b.markdown.contains("click A") }())
        check("a supplied diagram that is already fenced is not fenced twice", { let a = R.assemble(draft: smallDraft, map: small, diagrams: ["d1": "```mermaid\nflowchart LR\n  A --> B\n```"]); return a.markdown.contains("```mermaid\nflowchart LR\n  A --> B\n```") && !a.markdown.contains("```mermaid\n```mermaid") && a.droppedDiagrams.isEmpty }())
        check("a picture the model did not place goes to the end of the section that covers it", { var d = smallDraft; d.sections[2].markdown = "The deployment runs in the order the map describes and a bad release can be undone [1]; a blue-green set-up would make that instant [3].\n\n{{diagram:d1}}"; let a = R.assemble(draft: d, map: small, diagrams: supplied).markdown; let at = a.range(of: "```mermaid\n\(flowSource)")?.lowerBound; let sec = a.range(of: "## Deploying and going back")!.lowerBound; let next = a.range(of: "## What stays open")!.lowerBound; return at != nil && at! > sec && at! < next && a.contains("![Staging dashboard](images/staging.png)") }())
        check("a picture is placed once even when the model names it twice", { var d = smallDraft; d.sections[2].markdown += "\n\n{{node:\(nFlow)}}"; let a = R.assemble(draft: d, map: small, diagrams: supplied).markdown; return a.components(separatedBy: "flowchart LR\n  A[Build]").count == 2 }())
        check("a visual node without content is left out and reported", { var m = small; setNode(&m, nFlow) { $0.description = "No diagram here." }; let a = R.assemble(draft: smallDraft, map: m, diagrams: supplied); return a.emptyVisuals == [nFlow] && !a.markdown.contains("flowchart LR\n  A[Build]") }())
        check("an empty title falls back to the map's and the byline is optional", { var d = smallDraft; d.title = " "; let t = R.assemble(draft: d, map: small, diagrams: supplied).markdown; return t.hasPrefix("# How should we make releases safer?\n\n## Why releases need care") }())
        check("the Sources heading is the one in the report's language", { var d = smallDraft; d.sourcesHeading = "Источники"; return R.assemble(draft: d, map: small, diagrams: supplied).markdown.contains("## Источники\n\n- [1]") }())
        check("a map without sources has no Sources section", { var m = small; for i in m.nodes.indices { m.nodes[i].evidence = [] }; return !R.assemble(draft: smallDraft, map: m, diagrams: supplied).markdown.contains("## Sources") }())
        check("the report ends with one newline and never has two blank lines in a row", text.hasSuffix("\n") && !text.hasSuffix("\n\n") && !text.contains("\n\n\n"))
        check("the assembled report passes the same text checks as the model's text", R.unsafeReason(text.replacingOccurrences(of: "<https://example.com/blue-green>", with: "")) == nil)
        check("an alt text cannot break out of the image syntax", { var m = small; setNode(&m, nShot) { $0.description = "![bad ] alt [x](y)](images/staging.png)" }; let line = R.assemble(draft: smallDraft, map: m, diagrams: supplied).markdown.components(separatedBy: "\n").first { $0.hasPrefix("![") } ?? ""; return line.range(of: #"^!\[[^\[\]]*\]\([^)]*\)$"#, options: .regularExpression) != nil }())
        let bigBuilt = R.assemble(draft: narrative(big), map: big, diagrams: [:])
        check("a narrative of the large map assembles with every branch and a Sources list", bigBuilt.markdown.contains("## Branch 6") && bigBuilt.markdown.contains("## Sources") && bigBuilt.markdown.contains("`src/branch1/file1.swift` (10)"))

        // MARK: The real map of the project, when its copy is present

        // A copy of a large real map, given by the environment (RESEARCH_MAP_REAL) or found in the project; the checks are skipped without one.
        let realPath = ProcessInfo.processInfo.environment["RESEARCH_MAP_REAL"] ?? "docs/research/2026-11-05-issues-management.md"
        if let realText = try? String(contentsOfFile: realPath, encoding: .utf8), case .success(let real) = M.parse(realText) {
            check("real map: the request names every node id", R.prompt(map: real, mapName: "real.md").user.contains("NODES: \(real.nodes.count)") && real.nodes.allSatisfy { R.prompt(map: real, mapName: "real.md").user.contains("NODE \($0.id) |") })
            check("real map: a story with a section per branch passes", R.check(draft: narrative(real), map: real).isEmpty)
            check("real map: the old report reshaped into sections is rejected", has(R.check(draft: reshaped(real), map: real), .headingPerNode))
            check("real map: a draft that drops a node is reported", { var d = narrative(real); d.sections[1].covers.removeLast(); return has(R.check(draft: d, map: real), .missingNodes) }())
            check("real map: the assembled report has a Sources list with the files of the project", R.assemble(draft: narrative(real), map: real, diagrams: [:]).markdown.contains("## Sources"))
        } else {
            print("skip  real map copy not found; the generated map stood in for it")
        }
    }
}

extension ResearchMapTranslationHostTests {
    func testResearchMapExportRules() {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail(), line: line)
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
    }
}

extension ResearchMapTranslationHostTests {
    func testResearchMapImagesRules() {
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail(), line: line)
        }
        typealias I = ResearchMapImages

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 40))
        let png2 = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 9, count: 40))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 1, count: 30))
        let gif = Data("GIF89a".utf8 + Array(repeating: 2, count: 30))
        let webp = Data("RIFF".utf8 + [0, 0, 0, 0] + "WEBP".utf8 + Array(repeating: 3, count: 20))
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".utf8)
        let html = Data("<html><body>hi</body></html>".utf8)

        check("PNG by its bytes", I.fileExtension(of: png) == "png")
        check("JPEG by its bytes", I.fileExtension(of: jpeg) == "jpg")
        check("GIF by its bytes", I.fileExtension(of: gif) == "gif")
        check("WebP by its bytes", I.fileExtension(of: webp) == "webp")
        check("SVG is refused (it can carry scripts)", I.fileExtension(of: svg) == nil)
        check("HTML is refused", I.fileExtension(of: html) == nil)
        check("an empty or tiny file is refused", I.fileExtension(of: Data()) == nil && I.fileExtension(of: Data([0x89])) == nil)

        check("a name is cut to a safe base", I.safeBase("My Screen Shot (1).PNG") == "My-Screen-Shot-1")
        check("a path in the name is dropped", I.safeBase("../../etc/passwd.png") == "passwd" && I.safeBase("C:\\Users\\a\\pic.jpg") == "pic")
        check("a name with nothing usable becomes image", I.safeBase("???.png") == "image" && I.safeBase("") == "image" && I.safeBase("...") == "image")
        check("a long name is cut", I.safeBase(String(repeating: "a", count: 200) + ".png").count == 48)
        check("non-ASCII letters do not reach the file system", I.safeBase("снимок экрана.png") == "image")

        check("a good picture decodes", { if case .success(let data) = I.decode(base64: png.base64EncodedString()) { return data == png } else { return false } }())
        check("text that is not Base64 is refused", { if case .failure(let f) = I.decode(base64: "%%% not base64 %%%") { return f.message == "The picture could not be read." } else { return false } }())
        check("other file types are refused", { if case .failure(let f) = I.decode(base64: svg.base64EncodedString()) { return f.message == "Use a PNG, JPEG, GIF or WebP picture." } else { return false } }())
        check("an oversized picture is refused", { if case .failure(let f) = I.decode(base64: (png + Data(repeating: 0, count: I.sizeLimit)).base64EncodedString()) { return f.message == "The picture is larger than 6 MB." } else { return false } }())
        check("an empty picture is refused", { if case .failure = I.decode(base64: "") { return true } else { return false } }())

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-images-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let map = root.appendingPathComponent("docs/research/map.md")
        try! FileManager.default.createDirectory(at: map.deletingLastPathComponent(), withIntermediateDirectories: true)
        func stored(_ data: Data, _ name: String) -> String {
            if case .success(let path) = I.store(base64: data.base64EncodedString(), suggestedName: name, besideMap: map) { return path }
            return "FAILED"
        }
        let first = stored(png, "Screen Shot.PNG")
        check("a picture is stored in images/ beside the map", first == "images/Screen-Shot.png" && FileManager.default.fileExists(atPath: map.deletingLastPathComponent().appendingPathComponent(first).path), first)
        check("the stored bytes are the picture", (try? Data(contentsOf: map.deletingLastPathComponent().appendingPathComponent(first))) == png)
        check("the same picture under the same name is reused", stored(png, "Screen Shot.PNG") == first)
        let second = stored(png2, "Screen Shot.png")
        check("a different picture with the same name gets a number", second == "images/Screen-Shot-2.png", second)
        check("…and the first is not overwritten", (try? Data(contentsOf: map.deletingLastPathComponent().appendingPathComponent(first))) == png)
        check("the kind comes from the bytes, not from the name", stored(jpeg, "photo.png") == "images/photo.jpg")
        check("a hostile name stays inside images/", stored(gif, "../../../outside.gif") == "images/outside.gif" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.gif").path))
        check("nothing was written outside images/", { let files = (try? FileManager.default.contentsOfDirectory(atPath: map.deletingLastPathComponent().path)) ?? []; return files == ["images"] }())
        check("a refused picture writes nothing", { if case .failure = I.store(base64: svg.base64EncodedString(), suggestedName: "x.svg", besideMap: map) { return !FileManager.default.fileExists(atPath: map.deletingLastPathComponent().appendingPathComponent("images/x.svg").path) } else { return false } }())

        // A folder that refuses the file: the picture is not stored, nothing partial stays and the earlier pictures keep their bytes.
        let imagesFolder = map.deletingLastPathComponent().appendingPathComponent("images")
        let imagesBefore = ((try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)) ?? []).sorted()
        chmod(imagesFolder.path, 0o555)
        let refused = I.store(base64: png2.base64EncodedString(), suggestedName: "Refused.png", besideMap: map)
        chmod(imagesFolder.path, 0o755)
        check("a folder that refuses the file gives no picture", { if case .failure(let f) = refused { return f.message == "The picture could not be saved next to the map." } else { return false } }())
        check("…and keeps what it held", ((try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)) ?? []).sorted() == imagesBefore
              && (try? Data(contentsOf: map.deletingLastPathComponent().appendingPathComponent(first))) == png)
    }
}

// Independent watchdog: the host process is isolated to this suite.
private final class ResearchMapWebProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    let started = Date()
    func reached() { lock.lock(); last = Date(); lock.unlock() }
    func elapsed() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}

final class ResearchMapWebHostTests: XCTestCase {
    @MainActor func testResearchMapWeb() throws {
        let editor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MarkView/Resources/Editor").path
        let progress = ResearchMapWebProgress()
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 5, repeating: 5)
        watchdog.setEventHandler {
            if progress.elapsed() > 120 || Date().timeIntervalSince(progress.started) > 1200 {
                FileHandle.standardError.write(Data("TIMEOUT: research-map WebKit test stopped making progress\n".utf8))
                exit(1)
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        var errorsSeen = 0
        var errorProbe: (() -> Int)?
        var checksCompleted = 0
        func check(_ ok: Bool, _ message: String, _ detail: @autoclosure () -> String = "") {
            progress.reached()
            checksCompleted += 1
            if checksCompleted.isMultiple(of: 50) {
                FileHandle.standardError.write(Data("research-map WebKit: \(checksCompleted) checks; latest: \(message)\n".utf8))
            }
            if !ok { XCTFail("\(message): \(String(detail().prefix(900)))") }
            if let probe = errorProbe {
                let count = probe()
                if count > errorsSeen { errorsSeen = count; print("info: page error first observed at \(message)") }
            }
        }
struct Message { let type: String; let doc: String; let payload: [String: Any] }
final class Bridge: NSObject, WKScriptMessageHandler {
    var messages: [Message] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        messages.append(Message(type: type, doc: body["doc"] as? String ?? "<missing>", payload: body["payload"] as? [String: Any] ?? [:]))
    }
}
final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}

_ = NSApplication.shared
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
let bridge = Bridge()
config.userContentController.add(bridge, name: "bridge")
config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)  // the page gets the bridge contract from the app (AR-28)
// Every uncaught error and rejected promise of the page is recorded from the very start.
let recorder = WKUserScript(source: """
window.__errors = [];
function recordTestError(message) {
  window.__errors.push(message);
  window.webkit.messageHandlers.bridge.postMessage({type: 'testPageError', payload: {message: message}});
}
window.addEventListener('error', function (e) { recordTestError('error: ' + e.message + ' @' + (e.filename || '') + ':' + e.lineno); });
window.addEventListener('unhandledrejection', function (e) { recordTestError('rejection: ' + (e.reason && e.reason.message || e.reason)); });
""", injectionTime: .atDocumentStart, forMainFrameOnly: true)
config.userContentController.addUserScript(recorder)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: config)
// Keep the test outside every display and behind other windows, while allowing WebKit's rendering clock to advance.
let window = QAWebWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.ignoresMouseEvents = true
window.contentView = web
window.orderBack(nil)
check(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }, "research-map host stays outside every display")
check(!window.isKeyWindow && !window.isMainWindow, "research-map host does not take focus")
defer { web.stopLoading(); web.navigationDelegate = nil; config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.contentView = nil; window.close() }
let loaded = Loaded()
web.navigationDelegate = loaded
web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// Runs a function body in the page; the result is a string (JSON for structures).
func js(_ body: String, _ arguments: [String: Any] = [:], timeout: TimeInterval = 20) -> String {
    var out: String?
    web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value): out = value as? String ?? "\(String(describing: value))"
        case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }
    spin(timeout) { out != nil }
    return out ?? "TIMEOUT"
}
func json(_ body: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
    let text = js(body, arguments)
    guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["error": text] }
    return object
}
func eval(_ body: String, _ arguments: [String: Any] = [:]) -> String { js("return String(" + body + ");", arguments) }
func bool(_ expression: String) -> Bool { eval(expression) == "true" }
func number(_ expression: String) -> Double { Double(eval(expression)) ?? .nan }

// ---- messages from the page -----------------------------------------------------------------------------------------
var mark = 0
func newMark() { mark = bridge.messages.count }
func researchMessages(since: Int? = nil) -> [Message] { bridge.messages[(since ?? mark)...].filter { $0.type == "researchMap" } }
func describe(_ messages: [Message]) -> String {
    messages.map { m in
        let keys = m.payload.keys.sorted().map { "\($0)=\(m.payload[$0] ?? "")" }.joined(separator: ",")
        return "[\(m.doc.prefix(4)) \(keys)]"
    }.joined(separator: " ")
}
func equal(_ a: [String: Any], _ b: [String: Any]) -> Bool { (a as NSDictionary).isEqual(to: b) }

/// The page must send exactly this researchMap message (and name this document) after the last `newMark()`.
func expect(_ name: String, _ expected: [String: Any], doc: String? = nil, wait: TimeInterval = 4.5, count: Int = 1) {
    spin(wait) { researchMessages().filter { equal($0.payload, expected) }.count >= count }
    spin(0.15)
    let hits = researchMessages().filter { equal($0.payload, expected) }
    let named = doc.map { d in hits.allSatisfy { $0.doc == d } } ?? true
    check(hits.count == count && named, name, "wanted \(expected) x\(count) \(doc ?? "") got: \(describe(researchMessages()))")
}
func expectNone(_ name: String, action: String, wait: TimeInterval = 0.9) {
    spin(wait)
    let hits = researchMessages().filter { ($0.payload["action"] as? String) == action }
    check(hits.isEmpty, name, "unexpected: \(describe(hits))")
}

// ---- the page ---------------------------------------------------------------------------------------------------------
spin(40) { loaded.done }
check(loaded.done, "shipping editor page loaded")

// The page holds no colours of its own: the app sends it the definition of the window's theme with every change, so this host does the
// same, from the Themes folder next to the program (AR-32). A window starts as Classic Dark.
let themeLibrary = ThemeLibrary.load(builtInFolder: ThemeCatalog.bundledFolder, userFolder: nil)
func setThemeCall(_ id: String) -> String {
    "window.setTheme('\(id)', null, \(themeLibrary.resolve(AppTheme(id), systemIsDark: true).definition.webPayload)); return 'ok';"
}
_ = js(setThemeCall("classic-dark"))
spin(1.5)
// The shipping page raises one "Script error." of its own while loading; only errors after this point count.
let baselineErrors = Int(js("return String(window.__errors.length);")) ?? 0
let baselineReports = bridge.messages.filter { $0.type == "jsError" }.count
errorsSeen = bridge.messages.filter { $0.type == "testPageError" }.count
errorProbe = { bridge.messages.filter { $0.type == "testPageError" }.count }
print("info page errors before the test: \(baselineErrors) (already present without the research map scripts)")

let probe = json("""
const t0 = performance.now();
await new Promise(function (r) { setTimeout(r, 300); });
return JSON.stringify({ visibility: document.visibilityState, width: innerWidth, height: innerHeight, timer: Math.round(performance.now() - t0),
  layout: !!window.MVResearchMapLayout, view: !!window.MVResearchMap, leave: typeof window.leaveResearchMap, set: typeof window.mvResearchMapSet });
""")
print("info page: \(probe)")
check((probe["visibility"] as? String) == "visible", "the off-screen page runs with a visible rendering clock", "\(probe)")
check((probe["layout"] as? Bool) == true && (probe["view"] as? Bool) == true && (probe["leave"] as? String) == "function" && (probe["set"] as? String) == "function",
      "the layout engine and the map view are loaded and expose the API", "\(probe)")

// Helpers that drive the page the way a person would (clicks, pointer drags, typing, keys, wheel).
let helpers = #"""
const q = function (s) { return document.querySelector(s); };
const qa = function (s) { return Array.from(document.querySelectorAll(s)); };
const fire = function (type, target, x, y) {
  return target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, pointerId: 7, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: x, clientY: y }));
};
const centre = function (e) { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; };
window.__t = {
  q: q, qa: qa,
  wrap: function (id) { return q('.rm-node-wrap[data-id="' + id + '"]'); },
  btn: function (id) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-node'); },
  pos: function (id) { const w = q('.rm-node-wrap[data-id="' + id + '"]'); return { x: parseFloat(w.style.left), y: parseFloat(w.style.top) }; },
  select: function (id) { q('.rm-node-wrap[data-id="' + id + '"] .rm-node').click(); },
  menu: function (id) { q('.rm-node-wrap[data-id="' + id + '"] .rm-tri').click(); },
  fold: function (id) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-fold'); },
  shown: function (id) { const w = q('.rm-node-wrap[data-id="' + id + '"]'); return !w.hidden; },
  act: function (name) { q('.rm-actions [data-act="' + name + '"]').click(); },
  dialogButton: function (text) { const b = qa('.rm-dialog-actions button').find(function (x) { return x.textContent.trim() === text; }); if (!b) throw new Error('no dialog button ' + text); b.click(); },
  type: function (el, value) { el.focus(); el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); },
  key: function (el, key, opts) { return el.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ key: key, bubbles: true, cancelable: true }, opts || {}))); },
  dragStart: function (id) { const b = this.btn(id), c = centre(b); window.__drag = { id: id, x: c.x, y: c.y, el: b }; fire('pointerdown', b, c.x, c.y); },
  dragTo: function (dx, dy) { const d = window.__drag; fire('pointermove', d.el, d.x + dx, d.y + dy); },
  dragEnd: function (dx, dy, click) { const d = window.__drag; fire('pointerup', d.el, d.x + dx, d.y + dy); if (click) d.el.click(); },
  wheel: function (x, y, deltaY) { const e = new WheelEvent('wheel', { bubbles: true, cancelable: true, clientX: x, clientY: y, deltaY: deltaY }); q('.rm-viewport').dispatchEvent(e); return e.defaultPrevented; },
  view: function () { const m = /translate\(([-\d.e]+)px,\s*([-\d.e]+)px\)\s*scale\(([-\d.e]+)\)/.exec(q('.rm-world').style.transform); return { x: parseFloat(m[1]), y: parseFloat(m[2]), scale: parseFloat(m[3]) }; },
  panning: function (dx, dy) { const v = q('.rm-viewport'), r = v.getBoundingClientRect(), x = r.left + 8, y = r.bottom - 8; fire('pointerdown', v, x, y); fire('pointermove', v, x + dx, y + dy); fire('pointerup', v, x + dx, y + dy); },
  deliver: function (snapshot) { window.mvResearchMapSet(window.mvDocumentId, snapshot); },
  snap: function (over) {
    const node = function (id, parent, title, extra) { return Object.assign({ id: id, parent: parent, title: title, tags: [], color: '', icon: '', number: null, shape: '', width: null, height: null, description: '', layout: '', x: null, y: null, evidence: [] }, extra || {}); };
    const nodes = [
      node('n1', '', 'Why do builds get slow?', { tags: ['question'], description: 'The central question.' }),
      node('n2', 'n1', 'Dependencies', { tags: ['deps', 'build'], description: 'Notes on the dependency graph.', evidence: [
        { label: 'Project fact', text: 'Package.swift lists 14 targets.', source: 'Package.swift:12' },
        { label: 'External fact', text: 'SwiftPM resolves packages in parallel.', source: 'https://swift.org/package-manager' },
        { label: 'AI inference', text: 'Resolution is probably cached.', source: '' },
        { label: 'Open assumption', text: 'CI starts from a cold cache.', source: '' }] }),
      node('n3', 'n1', 'Compiler'), node('n4', 'n1', 'Linking'), node('n5', 'n1', 'Caching'),
      node('n6', 'n2', 'Module graph'), node('n7', 'n2', 'Version pins'),
      node('n8', 'n3', 'Incremental builds'), node('n9', 'n3', 'Whole module optimisation'),
      node('n10', 'n4', 'Static libraries'), node('n11', 'n4', 'Dynamic libraries'), node('n12', 'n5', 'Remote cache')];
    const layouts = ['balanced', 'right', 'left', 'down', 'up', 'radial', 'outline'].map(function (id) { return { id: id, name: id.charAt(0).toUpperCase() + id.slice(1) }; });
    return Object.assign({ ok: true, problem: '', id: '2026-11-04-builds', title: 'Why do builds get slow?', question: 'Why do builds get slow?', status: 'complete', incomplete: '', job: null,
      webQueries: ['swiftpm resolution time', 'xcode build cache'], nodes: nodes, links: [{ from: 'n6', to: 'n8' }, { from: 'n2', to: 'n5' }], layouts: layouts, created: '', notice: '',
      shapes: [['rounded', 'Rounded'], ['rectangle', 'Rectangle'], ['pill', 'Pill'], ['ellipse', 'Ellipse'], ['diamond', 'Diamond']].map(function (s) { return { id: s[0], name: s[1] }; }),
      drawKinds: [['sequence', 'Sequence'], ['flowchart', 'Flowchart'], ['dataflow', 'Data flow'], ['architecture', 'Architecture'], ['er', 'Entity-relationship'], ['deployment', 'Deployment'], ['pipeline', 'Pipeline'], ['custom', 'Custom']].map(function (k) { return { id: k[0], name: k[1], hint: k[1] + ' diagram' }; }),
      languages: [['en', 'English'], ['ru', 'Russian']].map(function (l) { return { code: l[0], name: l[1] }; }),
      sizeLimits: { width: [60, 800], height: [28, 600] } }, over || {});
  },
  /** A snapshot where the given nodes carry extra fields: extras maps a node id to an object of fields. */
  look: function (extras) {
    const s = this.snap();
    s.nodes.forEach(function (n) { if (extras[n.id]) Object.assign(n, extras[n.id]); });
    return s;
  },
  handle: function (id, dir) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-handle[data-h="' + dir + '"]'); },
  resizeStart: function (id, dir) { const hd = this.handle(id, dir), c = centre(hd); window.__drag = { id: id, x: c.x, y: c.y, el: hd }; fire('pointerdown', hd, c.x, c.y); },
  box: function (id) { const r = this.btn(id).getBoundingClientRect(), s = window.MVResearchMap.viewState().scale; return { w: Math.round(r.width / s), h: Math.round(r.height / s), l: r.left, t: r.top, r: r.right, b: r.bottom, cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; }
};
return 'installed';
"""#
check(js(helpers) == "installed", "test helpers installed in the page")

let tabP = UUID().uuidString, tabM = UUID().uuidString, tabN = UUID().uuidString
let mapText = "---\ntype: research-map\nid: 2026-11-04-builds\ntitle: Why do builds get slow?\nstatus: complete\n---\n\n# Why do builds get slow?\n\n## Map\n\n- [Why do builds get slow?](#n1)\n"
func loadDocument(_ id: String, _ text: String) -> String {
    js("window.mvSetDocument(id); window.setContent(text); return 'ok';", ["id": id, "text": text])
}
func deliver(_ overrides: String = "{}", doc: String? = nil) {
    _ = js("window.mvResearchMapSet(doc || window.mvDocumentId, window.__t.snap(\(overrides))); return 'ok';", ["doc": doc ?? ""])
    spin(0.2)
}
func visible(_ selector: String) -> Bool { bool("(function(){ const e = document.querySelector('\(selector)'); return !!e && getComputedStyle(e).display !== 'none'; })()") }

// ---- a plain document first -----------------------------------------------------------------------------------------------
check(loadDocument(tabP, "# Plain document\n\nnothing to see") == "ok", "a plain document loads")
check(!visible("#research-map-container"), "a plain document does not show the map")
check(visible("#preview-pane"), "a plain document shows the usual preview")

// ---- a research map document ------------------------------------------------------------------------------------------------
newMark()
check(loadDocument(tabM, mapText) == "ok", "a research map document loads")
check(visible("#research-map-container"), "the map view is shown")
check(eval("document.getElementById('status-mode').textContent") == "MAP", "the status bar names the mode", eval("document.getElementById('status-mode').textContent"))
check(!visible("#preview-pane") && !visible("#editor-pane"), "the document text is hidden behind the map")
check(!visible("#wysiwyg-toolbar"), "the formatting bar is hidden while the map is shown")
expect("entering the map asks Swift for a snapshot, naming the document", ["action": "snapshot"], doc: tabM)
check(bool("document.querySelectorAll('.rm-node').length === 0"), "no nodes before the snapshot arrives")

deliver()
let nodeCount = number("document.querySelectorAll('.rm-node').length")
check(nodeCount == 12, "the snapshot draws all 12 nodes", "\(nodeCount)")
check(number("document.querySelectorAll('.rm-node.root').length") == 1 && bool("__t.btn('n1').classList.contains('root')"), "exactly one root node, the first")
check(number("document.querySelectorAll('.rm-node.branch').length") == 4, "the root's direct children are branch nodes")
check(number("document.querySelectorAll('path[data-line=tree]').length") == 11, "11 hierarchy lines")
check(number("document.querySelectorAll('path[data-line=link]').length") == 2 && bool("__t.q('path[data-line=link]').getAttribute('stroke-dasharray') !== null && getComputedStyle(__t.q('path[data-line=link]')).stroke === 'rgb(128, 128, 128)'"),
      "2 dashed logical connections in the application's secondary text colour")
check(eval("__t.q('.rm-heading strong').textContent") == "Why do builds get slow?", "the toolbar shows the map title")
check(eval("__t.q('.rm-zoom').textContent") == "100%", "the initial zoom is 100%")
let rootBox = json("const r = __t.btn('n1').getBoundingClientRect(), v = __t.q('.rm-viewport').getBoundingClientRect(); return JSON.stringify({ dx: (r.left + r.width / 2) - (v.left + v.width / 2), dy: (r.top + r.height / 2) - (v.top + v.height / 2), w: v.width, h: v.height });")
check(abs((rootBox["dx"] as? Double) ?? 999) < 3 && abs((rootBox["dy"] as? Double) ?? 999) < 3, "with no saved view the root sits at the centre of the canvas", "\(rootBox)")
check(((rootBox["w"] as? Double) ?? 0) > 500, "the canvas has a real size in the hidden window", "\(rootBox)")

// Node look: translucent menu button (an ellipsis, not a fold arrow) inside the node, in its top right corner.
let triangle = json("""
const n = __t.btn('n3').getBoundingClientRect(), t = __t.q('.rm-node-wrap[data-id="n3"] .rm-tri').getBoundingClientRect(), s = getComputedStyle(__t.q('.rm-node-wrap[data-id="n3"] .rm-tri'));
return JSON.stringify({ inside: t.left >= n.left && t.right <= n.right + 0.5 && t.top >= n.top && t.bottom <= n.bottom, topRight: (n.right - t.right) < 14 && (t.top - n.top) < 14, opacity: parseFloat(s.opacity), text: __t.q('.rm-node-wrap[data-id="n3"] .rm-tri').textContent });
""")
check((triangle["inside"] as? Bool) == true && (triangle["topRight"] as? Bool) == true, "the menu triangle sits inside the node, in its top right corner", "\(triangle)")
check(((triangle["opacity"] as? Double) ?? 1) < 0.8, "the menu button is translucent", "\(triangle)")
check((triangle["text"] as? String) == "⋯", "the menu button is an ellipsis, so it cannot be mistaken for a fold toggle (BUG-092)", "\(triangle)")
let looks = json("""
const root = getComputedStyle(__t.btn('n1')), node = getComputedStyle(__t.btn('n3')), view = getComputedStyle(__t.q('.rm-viewport'));
return JSON.stringify({ rootBg: root.backgroundColor, rootRadius: root.borderTopLeftRadius, nodeBorder: node.borderTopWidth, nodeRadius: node.borderTopLeftRadius, nodeBg: node.backgroundColor, viewBg: view.backgroundColor, dots: view.backgroundImage.indexOf('radial-gradient') >= 0, size: view.backgroundSize });
""")
check((looks["rootBg"] as? String) == "rgb(45, 45, 48)" && (looks["rootRadius"] as? String) == "8px", "dark theme: the root uses the application's --bg-tertiary (#2d2d30)", "\(looks)")
check((looks["nodeBg"] as? String) == "rgb(37, 37, 38)" && (looks["nodeRadius"] as? String) == "6px" && (looks["nodeBorder"] as? String) == "1px", "dark theme: nodes use --bg-secondary (#252526), a 6px radius and a 1px border like the application's cards", "\(looks)")
check((looks["viewBg"] as? String) == "rgb(30, 30, 30)" && (looks["dots"] as? Bool) == true && (looks["size"] as? String) == "24px 24px", "dark theme: the canvas is --bg-primary (#1e1e1e) with the application's dot grid (BUG-091)", "\(looks)")
let noGlow = json("const n = getComputedStyle(__t.btn('n3')), r = getComputedStyle(__t.btn('n1')); return JSON.stringify({ node: n.boxShadow, root: r.boxShadow, accent: n.borderLeftColor });")
check(!((noGlow["root"] as? String) ?? "").contains("rgb(62, 49, 120)") && !((noGlow["root"] as? String) ?? "").contains("0px 8px 0px"), "the prototype's 3D root shadow is gone", "\(noGlow)")
check((noGlow["accent"] as? String) == "rgb(78, 201, 176)", "a branch node carries its branch accent (#4ec9b0, the application's teal) on its left edge", "\(noGlow)")

// Selection and the properties panel.
check(bool("__t.btn('n1').getAttribute('aria-pressed') === 'true'"), "the root is selected first")
check(eval("__t.q('.rm-title-input').value") == "Why do builds get slow?", "the panel shows the selected node's title")
newMark()
_ = js("__t.select('n2'); return 'ok';")
check(bool("__t.btn('n2').getAttribute('aria-pressed') === 'true' && __t.btn('n1').getAttribute('aria-pressed') === 'false'"), "clicking a node selects it")
check(eval("__t.q('.rm-title-input').value") == "Dependencies", "the panel follows the selection")
check(number("document.querySelectorAll('.rm-tag').length") == 2 && eval("__t.qa('.rm-tag').map(function(t){return t.dataset.tag;}).join()") == "deps,build", "tags are listed")
check(eval("__t.q('.rm-desc').value") == "Notes on the dependency graph.", "the description fills the textarea")
check(number("document.querySelectorAll('.rm-ev-row').length") == 4, "four evidence rows")
check(eval("__t.qa('.rm-ev-chip').map(function(c){return c.textContent;}).join('|')") == "Project fact|External fact|AI inference|Open assumption", "each finding shows its label chip")
check(eval("__t.q('.rm-ev-row .rm-ev-text').textContent") == "Package.swift lists 14 targets.", "the finding's text is shown")
check(number("document.querySelectorAll('.rm-ev-source').length") == 2, "only findings with a source show a source link")
let chipColours = json("return JSON.stringify({ colours: __t.qa('.rm-ev-chip').map(function (c) { return getComputedStyle(c).backgroundColor; }) });")
check(Set((chipColours["colours"] as? [String]) ?? []).count == 4, "the four labels have four different chip colours", "\(chipColours)")
// Light theme (prototype v9): the window theme Classic Light sets html[data-theme="light"] and the light tokens.
_ = js(setThemeCall("classic-light"))
let light = json("""
const root = getComputedStyle(__t.btn('n1')), node = getComputedStyle(__t.btn('n3')), view = getComputedStyle(__t.q('.rm-viewport')), panel = getComputedStyle(__t.q('.rm-panel'));
return JSON.stringify({ rootBg: root.backgroundColor, nodeBg: node.backgroundColor, nodeInk: node.color, nodeAccent: node.borderLeftColor, viewBg: view.backgroundColor, panelBg: panel.backgroundColor });
""")
check((light["rootBg"] as? String) == "rgb(232, 232, 232)" && (light["viewBg"] as? String) == "rgb(255, 255, 255)" && (light["panelBg"] as? String) == "rgb(243, 243, 243)", "light theme: root, canvas and panel use the application's light tokens", "\(light)")
check((light["nodeBg"] as? String) == "rgb(243, 243, 243)" && (light["nodeAccent"] as? String) == "rgb(34, 134, 58)", "light theme: a branch node keeps the card fill and takes the darker branch accent", "\(light)")
_ = js(setThemeCall("classic-dark"))
let evidenceBelow = bool("__t.q('.rm-desc').getBoundingClientRect().bottom <= __t.q('.rm-ev-row').getBoundingClientRect().top + 1")
check(evidenceBelow, "the evidence list sits under the description")
// BUG-096: the resize grip of the description field sets an inline height; the field has to follow it.
let descSizes = json("""
const d = __t.q('.rm-desc'), height = function () { return Math.round(d.getBoundingClientRect().height); };
const natural = height();
d.style.height = '360px'; const tall = height();
const below = d.getBoundingClientRect().bottom <= __t.q('.rm-ev-row').getBoundingClientRect().top + 1;
const panel = __t.q('.rm-panel'), scrolls = panel.scrollHeight > panel.clientHeight;
d.style.height = '170px'; const short = height();
d.style.height = '';
return JSON.stringify({ natural: natural, tall: tall, short: short, below: below, scrolls: scrolls });
""")
check((descSizes["tall"] as? Int) == 360 && (descSizes["short"] as? Int) == 170, "the description field follows the height its resize grip sets", "\(descSizes)")
check((descSizes["below"] as? Bool) == true && (descSizes["scrolls"] as? Bool) == true, "a tall description pushes the evidence down and the panel scrolls", "\(descSizes)")
check(number("document.querySelectorAll('.rm-conn-row').length") == 1 && eval("__t.q('.rm-conn-row .rm-conn-name').textContent").contains("Caching"), "the node's logical connection is listed")

_ = js("__t.q('.rm-ev-source[data-source=\"Package.swift:12\"]').click(); return 'ok';")
expect("a path source sends open with the text as written", ["action": "open", "source": "Package.swift:12"], doc: tabM)
newMark()
_ = js("__t.q('.rm-ev-source[data-source=\"https://swift.org/package-manager\"]').click(); return 'ok';")
expect("a URL source sends open", ["action": "open", "source": "https://swift.org/package-manager"], doc: tabM)
newMark()
_ = js("__t.q('.rm-conn-row .rm-x').click(); return 'ok';")
expect("the × on a connection sends unlink with the pair", ["action": "unlink", "from": "n2", "to": "n5"], doc: tabM)

// An empty selection.
newMark()
_ = js("__t.panning(0, 0); return 'ok';")
check(bool("__t.btn('n2').getAttribute('aria-pressed') === 'false'") && eval("__t.q('.rm-empty').textContent") == "Select a node on the map" && !visible(".rm-panel-body"),
      "clicking the background clears the selection: the panel says to select a node")
_ = js("__t.select('n2'); return 'ok';")

// ---- toolbar status ---------------------------------------------------------------------------------------------------------------
check(!visible(".rm-status"), "a complete map shows no status chip")
// 75 s ago; the page is read a few seconds later, and a slow runner needs up to about 30 s for it, so any 1:1x to 1:3x is right
let started = Int(Date().timeIntervalSince1970) - 75
deliver("{ status: 'researching', job: { kind: 'research', label: 'Researching the question', step: 'Reading Package.swift', startedAt: \(started) } }")
check(visible(".rm-status") && eval("__t.q('.rm-status').textContent").contains("Reading Package.swift") && eval("__t.q('.rm-status').textContent").contains("Researching the question"),
      "researching: the chip shows the job and its current step", eval("__t.q('.rm-status').textContent"))
check(eval("__t.q('.rm-elapsed').textContent").range(of: #"^1:[1-3]\d$"#, options: .regularExpression) != nil, "researching: the elapsed time counts from startedAt", eval("__t.q('.rm-elapsed').textContent"))
check(bool("!!__t.q('.rm-status .rm-spin')"), "researching: a spinner")
newMark()
_ = js("__t.q('.rm-status [data-act=stop]').click(); return 'ok';")
expect("Stop sends cancel", ["action": "cancel"], doc: tabM)
deliver("{ status: 'incomplete', incomplete: 'Stopped after 60 nodes.' }")
check(visible(".rm-status") && eval("__t.q('.rm-status').textContent").contains("Stopped after 60 nodes.") && !bool("!!__t.q('.rm-status .rm-spin')"), "incomplete: the chip shows the reason, no spinner", eval("__t.q('.rm-status').textContent"))
newMark()
_ = js("__t.q('.rm-status [data-act=continue]').click(); return 'ok';")
expect("Continue sends continue", ["action": "continue"], doc: tabM)
deliver()
check(!visible(".rm-status"), "complete again: the chip goes away")
check(visible("[data-act=queries]") && eval("__t.q('[data-act=queries] .rm-count').textContent") == "2", "the web-queries button shows how many searches ran")
_ = js("__t.q('[data-act=queries]').click(); return 'ok';")
check(visible(".rm-popover") && eval("__t.qa('.rm-popover li').map(function(l){return l.textContent;}).join('|')") == "swiftpm resolution time|xcode build cache", "the popover lists the web queries")
_ = js("__t.q('[data-act=queries]').click(); return 'ok';")
check(!visible(".rm-popover"), "the popover closes")

// ---- the node menu and its dialogs ---------------------------------------------------------------------------------------------------
newMark()
_ = js("__t.menu('n3'); return 'ok';")
check(eval("__t.qa('.rm-actions [data-act]').map(function(b){return b.dataset.act;}).join()") == "describe,develop,correct,investigate,draw,add,link,edit,icon,image,number-children,focus,arrange,delete", "the menu holds the four AI actions and Draw first, then add, connect, edit, icon, image, number children, focus, arrange and delete; there is no move to another branch (BUG-093)")
check(eval("__t.qa('.rm-actions [data-act]').map(function(b){return b.textContent.trim();}).join('|')") == "Expand description|Expand topic…|Correct…|Research|Draw▾|Add child node…|Add logical connection…|Edit title…|Icon…|Image…|Number children 1, 2, 3…|Focus on this node|Arrange branch▾|Delete node…", "every action has a visible label (BUG-092/093: icons alone were not enough)")
check(bool("__t.qa('.rm-actions [data-act]').every(function (b) { return !!b.querySelector('svg') && b.title && b.getAttribute('aria-label'); })"), "…and an icon and a tooltip")
check(bool("!__t.q('.rm-actions').closest('.rm-world')"), "the menu is drawn at screen size, outside the zoomed map")
check(bool("(function () { const m = __t.q('.rm-actions').getBoundingClientRect(), l = __t.q('.rm-left').getBoundingClientRect(); return m.left >= l.left && m.right <= l.right + 0.5 && m.top >= l.top && m.bottom <= l.bottom + 0.5; })()"), "the menu stays inside the map area")
let ordinary = json("return JSON.stringify({ off: __t.qa('.rm-actions button').filter(function (b) { return b.disabled; }).map(function (b) { return b.dataset.act; }) });")
check(((ordinary["off"] as? [String]) ?? ["x"]).isEmpty, "an ordinary node has every action enabled", "\(ordinary)")
_ = js("__t.menu('n3'); return 'ok';")
check(!visible(".rm-actions"), "the triangle closes its menu")
_ = js("__t.menu('n1'); return 'ok';")
let rootMenu = json("return JSON.stringify({ off: __t.qa('.rm-actions button').filter(function (b) { return b.disabled; }).map(function (b) { return b.dataset.act; }) });")
check((rootMenu["off"] as? [String]) == ["delete"], "the root cannot be deleted", "\(rootMenu)")
_ = js("document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); return 'ok';")
check(!visible(".rm-actions"), "a click elsewhere closes the menu")

_ = js("__t.menu('n3'); __t.act('add'); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog h2').textContent") == "Add child node" && eval("__t.q('.rm-dialog').textContent").contains("Parent node: Compiler"), "Add child opens a dialog naming the parent")
_ = js("__t.dialogButton('Add'); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog .rm-error').textContent") == "Enter a node name.", "an empty name is refused inside the dialog")
expectNone("…and nothing is sent", action: "addChild", wait: 0.3)
_ = js("__t.type(__t.q('.rm-dialog input'), '  Cache layers '); __t.dialogButton('Add'); return 'ok';")
expect("Add sends addChild with the parent and the trimmed title", ["action": "addChild", "parent": "n3", "title": "Cache layers"], doc: tabM)
check(!visible(".rm-dialog"), "the dialog closes after Add")

newMark()
_ = js("__t.menu('n3'); __t.act('develop'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Expand topic", "Expand topic opens its dialog")
_ = js("__t.dialogButton('Expand'); return 'ok';")
expect("an empty direction is allowed: the AI chooses the sub-topics", ["action": "develop", "id": "n3", "direction": ""], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('develop'); __t.type(__t.q('.rm-dialog input'), 'compare the options'); __t.dialogButton('Expand'); return 'ok';")
expect("Expand topic sends the direction in words", ["action": "develop", "id": "n3", "direction": "compare the options"], doc: tabM)

newMark()
_ = js("__t.menu('n3'); __t.act('edit'); return 'ok';")
check(eval("__t.q('.rm-dialog input').value") == "Compiler", "Edit opens a dialog with the current title")
_ = js("__t.type(__t.q('.rm-dialog input'), 'Compiler front end'); __t.dialogButton('Save'); return 'ok';")
expect("Edit sends update with the new title", ["action": "update", "id": "n3", "title": "Compiler front end"], doc: tabM)

newMark()
_ = js("__t.menu('n6'); __t.act('link'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Add logical connection" && eval("__t.q('.rm-dialog select[aria-label=\"First node\"]').value") == "n6", "the connection dialog starts from the node it was opened on")
_ = js("__t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n6'; __t.dialogButton('Add'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "Select two different nodes.", "a connection to itself is refused")
_ = js("__t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n8'; __t.dialogButton('Add'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "This connection already exists.", "a repeated connection is refused")
_ = js("__t.q('.rm-dialog select[aria-label=\"First node\"]').value = 'n8'; __t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n6'; __t.dialogButton('Add'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "This connection already exists.", "…also in the other direction")
expectNone("…nothing was sent so far", action: "link", wait: 0.3)
_ = js("__t.q('.rm-dialog select[aria-label=\"First node\"]').value = 'n4'; __t.q('.rm-dialog select[aria-label=\"Second node\"]').value = 'n5'; __t.dialogButton('Add'); return 'ok';")
expect("Add sends link with both ends", ["action": "link", "from": "n4", "to": "n5"], doc: tabM)

newMark()
_ = js("__t.menu('n2'); return 'ok';")
check(!bool("!!__t.q('.rm-actions [data-act=move]')"), "there is no Move to another branch action any more (DEC-010)")
_ = js("__t.menu('n2'); return 'ok';")

// ---- AI actions on a node (REQ-006) -------------------------------------------------------------------------------------------------
newMark()
_ = js("__t.menu('n3'); __t.act('describe'); return 'ok';")
expect("Expand description sends describe at once, with the node", ["action": "describe", "id": "n3"], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('investigate'); return 'ok';")
expect("Research sends investigate at once, with the node", ["action": "investigate", "id": "n3"], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('correct'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Correct node" && bool("__t.q('.rm-dialog textarea') !== null"), "Correct opens a dialog with a text area for the person's note")
_ = js("__t.dialogButton('Correct'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "Say what is wrong with this node.", "an empty note is refused")
expectNone("…and nothing is sent", action: "correct", wait: 0.3)
_ = js("__t.type(__t.q('.rm-dialog textarea'), 'The cache is not LRU'); __t.dialogButton('Correct'); return 'ok';")
expect("Correct sends the note", ["action": "correct", "id": "n3", "note": "The cache is not LRU"], doc: tabM)

_ = js("__t.select('n2'); return 'ok';")
check(eval("__t.qa('.rm-ai [data-act]').map(function(b){return b.textContent.trim();}).join('|')") == "Expand description|Expand topic|Correct|Research|Draw▾", "the properties panel shows the four AI actions and Draw as labelled buttons")
newMark()
_ = js("__t.q('.rm-ai [data-act=describe]').click(); return 'ok';")
expect("the panel's Expand description acts on the selected node", ["action": "describe", "id": "n2"], doc: tabM)
newMark()
_ = js("__t.q('.rm-ai [data-act=investigate]').click(); return 'ok';")
expect("the panel's Research acts on the selected node", ["action": "investigate", "id": "n2"], doc: tabM)
newMark()
_ = js("__t.q('.rm-ai [data-act=develop]').click(); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent") == "Expand topic", "the panel's Expand topic opens the same dialog")
_ = js("__t.dialogButton('Cancel'); return 'ok';")
deliver("{ status: 'researching', job: { kind: 'describe', label: 'Expand description: Dependencies', step: 'Reading', startedAt: \(Int(Date().timeIntervalSince1970)) } }")
check(bool("__t.qa('.rm-ai-btn').every(function (b) { return b.disabled; })") && eval("__t.q('.rm-ai-note').textContent").contains("already working"), "while a job runs, the AI buttons are off and say why")
_ = js("__t.menu('n3'); return 'ok';")
check(bool("__t.qa('.rm-actions .rm-item.ai').every(function (b) { return b.disabled; })"), "…and so are the AI items of the node menu")
_ = js("__t.menu('n3'); return 'ok';")
deliver()
check(bool("__t.qa('.rm-ai-btn').every(function (b) { return !b.disabled; })"), "when the job is over the buttons are back")

// ---- icons and numbers on a node (REQ-008, DEC-011) -------------------------------------------------------------------------------
let swiftSource = (try? String(contentsOfFile: editor + "/../../Models/Research/ResearchMapDocument.swift", encoding: .utf8)) ?? ""
let swiftIcons: [String] = {
    guard let start = swiftSource.range(of: "static let iconIDs = ["), let end = swiftSource.range(of: "]", range: start.upperBound..<swiftSource.endIndex) else { return [] }
    return swiftSource[start.upperBound..<end.lowerBound].components(separatedBy: CharacterSet(charactersIn: ", \n\"")).filter { !$0.isEmpty }
}()
check(swiftIcons.count == 41, "the built-in icon ids were read from ResearchMapDocument.swift", "\(swiftIcons)")
let pageIcons = (try? JSONSerialization.jsonObject(with: Data(eval("JSON.stringify(window.MVResearchMap.iconIDs())").utf8)) as? [String]) ?? []
check(pageIcons == swiftIcons, "the page draws exactly the icons Swift accepts, in the same order", "swift \(swiftIcons) page \(pageIcons)")

newMark()
check(bool("__t.qa('.rm-lead').every(function (l) { return l.hidden; })") && bool("__t.qa('.rm-badge, .rm-glyph').every(function (e) { return e.hidden; })"), "a node without icon and number shows neither")
deliver("{ nodes: (function () { const s = __t.snap(); const set = function (id, extra) { Object.assign(s.nodes.find(function (n) { return n.id === id; }), extra); }; set('n3', { number: 3, icon: 'bug' }); set('n4', { number: 12 }); set('n5', { icon: '🔥' }); set('n2', { number: 1, icon: 'rocket', color: '#ffee88' }); return s.nodes; })() }")
func nodeLead(_ id: String) -> [String: Any] { json("const e = __t.btn('\(id)'); const l = e.querySelector('.rm-lead'), b = e.querySelector('.rm-badge'), g = e.querySelector('.rm-glyph'); return JSON.stringify({ lead: !l.hidden, badge: b.hidden ? '' : b.textContent, glyph: g.hidden ? '' : (g.querySelector('svg') ? 'svg' : g.textContent), label: e.querySelector('.rm-label').textContent, aria: e.getAttribute('aria-label') });") }
let leadBoth = nodeLead("n3"), leadNumber = nodeLead("n4"), leadEmoji = nodeLead("n5")
check((leadBoth["badge"] as? String) == "3" && (leadBoth["glyph"] as? String) == "svg" && (leadBoth["label"] as? String) == "Compiler", "a node shows its number badge and icon before the title", "\(leadBoth)")
check((leadNumber["badge"] as? String) == "12" && (leadNumber["glyph"] as? String) == "", "a number alone shows only the badge", "\(leadNumber)")
check((leadEmoji["badge"] as? String) == "" && (leadEmoji["glyph"] as? String) == "🔥", "an emoji icon is drawn as text", "\(leadEmoji)")
check(((leadBoth["aria"] as? String) ?? "").hasPrefix("Number 3. bug icon. Compiler"), "a screen reader hears the number and the icon first", "\(leadBoth)")
check(eval("__t.btn('n3').querySelector('.rm-glyph svg path').getAttribute('d')").hasPrefix("M9 7a3 3 0 0 1 6 0"), "a built-in icon is its own drawing")
let badgeLook = json("const b = getComputedStyle(__t.btn('n3').querySelector('.rm-badge')), g = getComputedStyle(__t.btn('n3').querySelector('.rm-glyph')), c = getComputedStyle(__t.btn('n2').querySelector('.rm-badge')); return JSON.stringify({ bg: b.backgroundColor, ink: b.color, glyph: g.color, customBg: c.backgroundColor, customInk: c.color });")
check((badgeLook["bg"] as? String) == "rgb(78, 201, 176)" && (badgeLook["ink"] as? String) == "rgb(30, 30, 30)" && (badgeLook["glyph"] as? String) == "rgb(78, 201, 176)", "the badge and the icon take the branch colour; the badge text is dark on it (dark theme)", "\(badgeLook)")
check((badgeLook["customBg"] as? String) == "rgb(255, 238, 136)" && (badgeLook["customInk"] as? String) == "rgb(30, 30, 30)", "on a node with its own light colour the badge is that colour with dark text", "\(badgeLook)")
_ = js(setThemeCall("classic-light"))
check(eval("getComputedStyle(__t.btn('n3').querySelector('.rm-badge')).color") == "rgb(255, 255, 255)", "light theme: white text on the darker branch colour")
_ = js(setThemeCall("classic-dark"))
check(bool("(function () { const b = __t.btn('n3'), l = b.querySelector('.rm-lead').getBoundingClientRect(), r = b.getBoundingClientRect(); return l.left >= r.left && l.right <= r.right && l.top >= r.top && l.bottom <= r.bottom; })()"), "the badge and icon sit inside the node card")
check(bool("(function () { const b = __t.btn('n3'), t = b.querySelector('.rm-label').getBoundingClientRect(), l = b.querySelector('.rm-lead').getBoundingClientRect(); return l.right <= t.left + 1; })()"), "they come before the title, not over it")

// The panel: icon button, number field.
_ = js("__t.select('n3'); return 'ok';")
check(eval("__t.q('.rm-icon-pick').textContent.trim()") == "Bug" && bool("!__t.q('[data-act=icon-clear]').hidden") && eval("__t.q('.rm-number-input').value") == "3", "the panel shows the node's icon name and number")
_ = js("__t.select('n5'); return 'ok';")
check(eval("__t.q('.rm-icon-pick').textContent.trim()").hasSuffix("Emoji") && eval("__t.q('.rm-number-input').value") == "", "an emoji icon shows as Emoji; no number shows an empty field")
_ = js("__t.select('n6'); return 'ok';")
check(eval("__t.q('.rm-icon-pick').textContent.trim()") == "None" && bool("__t.q('[data-act=icon-clear]').hidden"), "a node without an icon says None and offers no remove button")
newMark()
_ = js("__t.type(__t.q('.rm-number-input'), '5'); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("typing a number sends update with the integer", ["action": "update", "id": "n6", "number": 5], doc: tabM)
newMark()
_ = js("__t.select('n3'); __t.type(__t.q('.rm-number-input'), ''); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("emptying the field removes the number (null)", ["action": "update", "id": "n3", "number": NSNull()], doc: tabM)
newMark()
_ = js("__t.type(__t.q('.rm-number-input'), '0'); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expectNone("0 is not sent", action: "update", wait: 0.5)
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent").contains("between 1 and 999") && eval("__t.q('.rm-number-input').value") == "3", "…the person is told, and the field shows the stored number again")
newMark()
_ = js("__t.type(__t.q('.rm-number-input'), '1000'); __t.q('.rm-number-input').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expectNone("1000 is not sent either", action: "update", wait: 0.5)

// The icon dialog.
newMark()
_ = js("__t.q('[data-act=icon]').click(); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent").hasPrefix("Icon for") && number("document.querySelectorAll('.rm-icongrid button').length") == 41, "the icon button opens a dialog with the 41 built-in icons")
check(bool("__t.q('.rm-icongrid button[data-icon=bug]').getAttribute('aria-pressed') === 'true' && __t.qa('.rm-icongrid button[aria-pressed=true]').length === 1"), "the node's current icon is marked in the grid")
check(bool("__t.qa('.rm-icongrid button').every(function (b) { return !!b.querySelector('svg path') && b.title && b.getAttribute('aria-label'); })"), "every icon has a drawing and a name")
_ = js("__t.q('.rm-icongrid button[data-icon=lock]').click(); return 'ok';")
expect("choosing an icon sends update with its id and closes the dialog", ["action": "update", "id": "n3", "icon": "lock"], doc: tabM)
check(!visible(".rm-dialog"), "the dialog is closed")
newMark()
_ = js("__t.q('[data-act=icon]').click(); __t.type(__t.q('.rm-dialog input'), 'ab'); __t.dialogButton('Use emoji'); return 'ok';")
check(eval("__t.q('.rm-dialog .rm-error').textContent").contains("one emoji"), "text that is not an emoji is refused in the dialog")
expectNone("…and not sent", action: "update", wait: 0.4)
_ = js("__t.type(__t.q('.rm-dialog input'), '🔥'); __t.dialogButton('Use emoji'); return 'ok';")
expect("an emoji is sent as it is", ["action": "update", "id": "n3", "icon": "🔥"], doc: tabM)
newMark()
_ = js("__t.q('[data-act=icon]').click(); __t.dialogButton('Remove icon'); return 'ok';")
expect("Remove icon in the dialog clears it", ["action": "update", "id": "n3", "icon": ""], doc: tabM)
newMark()
_ = js("__t.q('[data-act=icon-clear]').click(); return 'ok';")
expect("the × beside the icon clears it too", ["action": "update", "id": "n3", "icon": ""], doc: tabM)

// The node menu: Icon… and Number children.
newMark()
_ = js("__t.menu('n6'); return 'ok';")
check(bool("__t.q('.rm-actions [data-act=number-children]').disabled"), "Number children is off for a node without children")
_ = js("__t.menu('n6'); return 'ok';")
newMark()
_ = js("__t.menu('n1'); __t.act('number-children'); return 'ok';")
expect("Number children sends numberChildren for the node", ["action": "numberChildren", "id": "n1", "clear": false], doc: tabM)
deliver("{ nodes: (function () { const s = __t.snap(); ['n2', 'n3', 'n4', 'n5'].forEach(function (id, i) { s.nodes.find(function (n) { return n.id === id; }).number = i + 1; }); return s.nodes; })() }")
_ = js("__t.menu('n1'); return 'ok';")
check(eval("__t.q('.rm-actions [data-act=number-children]').textContent.trim()") == "Remove numbers from children", "when the children are numbered 1…n the action offers to remove the numbers")
newMark()
_ = js("__t.act('number-children'); return 'ok';")
expect("…and sends clear", ["action": "numberChildren", "id": "n1", "clear": true], doc: tabM)
newMark()
_ = js("__t.menu('n6'); __t.act('icon'); return 'ok';")
check(eval("__t.q('.rm-dialog h2').textContent").hasPrefix("Icon for") && bool("__t.btn('n6').getAttribute('aria-pressed') === 'true'"), "Icon… in the node menu selects the node and opens the dialog")
_ = js("__t.dialogButton('Cancel'); return 'ok';")
deliver()

// ---- shape and size of a node (REQ-009, DEC-012) -------------------------------------------------------------------------------------
// Editing a title in the panel must not rebuild the node card: the badge and the icon stay (a 5.31.0 regression).
deliver("{ nodes: __t.look({ n3: { number: 3, icon: 'bug' } }).nodes }")
_ = js("__t.select('n3'); __t.type(__t.q('.rm-title-input'), 'Compiler flags'); return 'ok';")
check(bool("(function () { const b = __t.btn('n3'); return b.querySelector('.rm-label').textContent === 'Compiler flags' && b.querySelector('.rm-badge').textContent === '3' && !b.querySelector('.rm-glyph').hidden && !b.querySelector('.rm-lead').hidden; })()"), "editing a title keeps the node's number badge and icon (5.31.0 regression)", eval("__t.btn('n3').outerHTML"))
_ = js("__t.select('n6'); return 'ok';")
deliver()

let swiftShapes: [String] = {
    guard let start = swiftSource.range(of: "static let shapes: [(id: String, name: String)] = ["), let end = swiftSource.range(of: "]", range: start.upperBound..<swiftSource.endIndex) else { return [] }
    return swiftSource[start.upperBound..<end.lowerBound].components(separatedBy: "(\"").dropFirst().map { String($0.prefix(while: { $0 != "\"" })) }
}()
let pageShapes = (try? JSONSerialization.jsonObject(with: Data(eval("JSON.stringify(window.MVResearchMap.shapeIDs())").utf8)) as? [String]) ?? []
check(swiftShapes.count == 5 && pageShapes == swiftShapes, "the page draws exactly the shapes Swift accepts, in the same order", "swift \(swiftShapes) page \(pageShapes)")
check(swiftSource.contains("widthRange = 60...800") && swiftSource.contains("heightRange = 28...600") && eval("JSON.stringify(window.MVResearchMap.sizeLimits())") == "{\"width\":[60,800],\"height\":[28,600]}", "the page's default limits equal Swift's")
deliver("{ sizeLimits: { width: [50, 700], height: [20, 500] } }")
check(eval("JSON.stringify(window.MVResearchMap.sizeLimits())") == "{\"width\":[50,700],\"height\":[20,500]}", "the limits of the snapshot replace the page's defaults")
deliver()
check(eval("JSON.stringify(window.MVResearchMap.sizeLimits())") == "{\"width\":[60,800],\"height\":[28,600]}", "…and the next snapshot restores them")

// The panel: five shapes, Auto/S/M/L, Width and Height.
_ = js("__t.select('n3'); return 'ok';")
check(eval("__t.qa('.rm-seg [data-shape]').map(function (b) { return b.getAttribute('data-shape'); }).join()") == "rounded,rectangle,pill,ellipse,diamond", "the panel offers the five shapes in order")
check(eval("__t.qa('.rm-seg [data-shape][aria-pressed=true]').map(function (b) { return b.getAttribute('data-shape'); }).join()") == "rounded" && bool("__t.qa('.rm-seg [data-shape]').every(function (b) { return !!b.querySelector('svg path') && b.title && b.getAttribute('aria-label'); })"), "a plain node shows Rounded as its shape; every shape button has a drawing and a name")
check(bool("__t.q('[data-size=auto]').getAttribute('aria-pressed') === 'true' && __t.q('[data-dim=width]').value === '' && __t.q('[data-dim=height]').value === '' && __t.q('[data-dim=width]').placeholder === 'Auto'"), "a plain node shows Auto with empty Width and Height fields")
newMark()
_ = js("__t.q('[data-shape=ellipse]').click(); return 'ok';")
expect("choosing a shape sends update with its id", ["action": "update", "id": "n3", "shape": "ellipse"], doc: tabM)
newMark()
_ = js("__t.q('[data-shape=rounded]').click(); return 'ok';")
expect("choosing the rounded rectangle sends an empty shape (the default is never stored)", ["action": "update", "id": "n3", "shape": ""], doc: tabM)
for (preset, w, h) in [("s", 140, 44), ("m", 220, 64), ("l", 320, 96)] {
    newMark()
    _ = js("__t.q('[data-size=\(preset)]').click(); return 'ok';")
    expect("the \(preset.uppercased()) preset sends its width and height", ["action": "update", "id": "n3", "width": w, "height": h], doc: tabM)
}
newMark()
_ = js("__t.q('[data-size=auto]').click(); return 'ok';")
expect("Auto clears the width and the height (null)", ["action": "update", "id": "n3", "width": NSNull(), "height": NSNull()], doc: tabM)
newMark()
_ = js("__t.type(__t.q('[data-dim=width]'), '300'); __t.q('[data-dim=width]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("typing a width sends only the width", ["action": "update", "id": "n3", "width": 300], doc: tabM)
newMark()
_ = js("__t.type(__t.q('[data-dim=height]'), '90'); __t.q('[data-dim=height]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("typing a height sends only the height", ["action": "update", "id": "n3", "height": 90], doc: tabM)
for (field, value) in [("width", "59"), ("width", "801"), ("width", "0"), ("height", "27"), ("height", "601")] {
    newMark()
    _ = js("__t.type(__t.q('[data-dim=\(field)]'), '\(value)'); __t.q('[data-dim=\(field)]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
    expectNone("a \(field) of \(value) is not sent", action: "update", wait: 0.3)
}
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent") == "A height is between 28 and 600." && eval("__t.q('[data-dim=height]').value") == "", "…the person is told the limits, and the field shows the stored value again")
deliver("{ nodes: __t.look({ n3: { width: 300 } }).nodes }")
newMark()
_ = js("__t.type(__t.q('[data-dim=width]'), ''); __t.q('[data-dim=width]').dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("emptying the width field makes the width automatic (null)", ["action": "update", "id": "n3", "width": NSNull()], doc: tabM)
_ = js("document.activeElement.blur(); return 'ok';")
deliver("{ nodes: __t.look({ n3: { width: 140, height: 44 }, n4: { width: 220, height: 64 } }).nodes }")
check(bool("__t.q('[data-size=s]').getAttribute('aria-pressed') === 'true' && __t.q('[data-size=auto]').getAttribute('aria-pressed') === 'false' && __t.q('[data-dim=width]').value === '140' && __t.q('[data-dim=height]').value === '44'"), "a node that has a preset's size shows that preset and the numbers")
_ = js("__t.select('n4'); return 'ok';")
check(bool("__t.q('[data-size=m]').getAttribute('aria-pressed') === 'true'"), "…and another node shows its own")
deliver()

// What the cards look like.
let longEllipse = "Whole module optimisation of everything in the project"
let longDiamond = "Incremental builds with a rather long name"
deliver("{ nodes: __t.look({ n2: { shape: 'diamond' }, n3: { shape: 'ellipse', width: 260 }, n4: { shape: 'pill' }, n5: { shape: 'rectangle', height: 120 }, n6: { width: 300 }, n7: { height: 90 }, n9: { shape: 'ellipse', title: '\(longEllipse)' }, n8: { shape: 'diamond', title: '\(longDiamond)' }, n10: { width: 100, height: 28, title: 'A title that needs several lines' } }).nodes }")
check(eval("['n1','n2','n3','n4','n5','n6','n7','n8','n9','n10','n11','n12'].map(function (id) { return __t.wrap(id).className.split(' ').filter(function (c) { return c.indexOf('shape-') === 0; }).join('') || '-'; }).join()") == "-,shape-diamond,shape-ellipse,shape-pill,shape-rectangle,-,-,shape-diamond,shape-ellipse,-,-,-", "each node's wrap names its shape; a rounded rectangle has no shape class")
let shapeLook = json("""
const radius = function (id) { return getComputedStyle(__t.btn(id)).borderTopLeftRadius; };
const dia = __t.btn('n2');
return JSON.stringify({ ellipse: radius('n3'), pill: radius('n4'), rect: radius('n5'), rounded: radius('n11'),
  polygon: !!dia.querySelector('.rm-shape polygon'), diaBg: getComputedStyle(dia).backgroundColor, diaBorder: getComputedStyle(dia).borderTopWidth, diaShadow: getComputedStyle(dia).boxShadow,
  stroke: getComputedStyle(dia.querySelector('polygon')).stroke, fill: getComputedStyle(dia.querySelector('polygon')).fill, rectBorder: getComputedStyle(__t.btn('n5')).borderLeftWidth, ellBorder: getComputedStyle(__t.btn('n3')).borderTopWidth, ellColour: getComputedStyle(__t.btn('n3')).borderTopColor,
  noSvg: !__t.btn('n3').querySelector('.rm-shape') });
""")
check((shapeLook["ellipse"] as? String) == "50%" && ((shapeLook["pill"] as? String) ?? "").hasPrefix("999") && (shapeLook["rect"] as? String) == "0px" && (shapeLook["rounded"] as? String) == "6px", "ellipse, pill, rectangle and rounded have their corners", "\(shapeLook)")
check((shapeLook["polygon"] as? Bool) == true && (shapeLook["diaBg"] as? String) == "rgba(0, 0, 0, 0)" && (shapeLook["diaBorder"] as? String) == "0px" && (shapeLook["noSvg"] as? Bool) == true, "a diamond is an SVG polygon on a transparent card; no other shape has one", "\(shapeLook)")
check((shapeLook["stroke"] as? String) == "rgb(86, 156, 214)" && (shapeLook["fill"] as? String) == "rgb(37, 37, 38)" && (shapeLook["rectBorder"] as? String) == "3px" && ["1px", "1.5px"].contains((shapeLook["ellBorder"] as? String) ?? "") && (shapeLook["ellColour"] as? String) == "rgb(78, 201, 176)", "the diamond is outlined in its branch colour on the card colour; the rectangle keeps the 3px branch stripe; the ellipse is outlined in its branch colour", "\(shapeLook)")
check(bool("__t.box('n3').w === 260") && bool("__t.box('n6').w === 300") && bool("__t.box('n5').h === 120") && bool("__t.box('n7').h === 90"), "a given width is exact and a given height is the height of a short title's card", eval("JSON.stringify(['n3','n6','n5','n7'].map(function (id) { return __t.box(id); }))"))
check(bool("(function () { const b = __t.btn('n10'), body = b.querySelector('.rm-body'); return __t.box('n10').w === 100 && __t.box('n10').h > 28 && body.getBoundingClientRect().height <= b.clientHeight + 1 && b.scrollHeight <= b.clientHeight + 1; })()"), "a height below the title's is a floor: the card grows and nothing is cut", eval("JSON.stringify(__t.box('n10'))"))
let inscribed = json("""
const inside = function (id, kind) {
  const b = __t.btn(id).getBoundingClientRect(), t = __t.btn(id).querySelector('.rm-body').getBoundingClientRect();
  const a = b.width / 2, c = b.height / 2, cx = b.left + a, cy = b.top + c;
  return [[t.left, t.top], [t.right, t.top], [t.left, t.bottom], [t.right, t.bottom]].map(function (p) {
    const dx = Math.abs(p[0] - cx) / a, dy = Math.abs(p[1] - cy) / c;
    return kind === 'ellipse' ? dx * dx + dy * dy : dx + dy;
  }).reduce(function (m, v) { return Math.max(m, v); }, 0);
};
return JSON.stringify({ ellipse: inside('n9', 'ellipse'), diamond: inside('n8', 'diamond'), shortEllipse: inside('n3', 'ellipse'), shortDiamond: inside('n2', 'diamond') });
""")
check(((inscribed["ellipse"] as? Double) ?? 9) <= 1.03 && ((inscribed["diamond"] as? Double) ?? 9) <= 1.03 && ((inscribed["shortEllipse"] as? Double) ?? 9) <= 1.03 && ((inscribed["shortDiamond"] as? Double) ?? 9) <= 1.03, "in an ellipse and a diamond the whole title lies inside the outline", "\(inscribed)")
check(bool("__t.box('n9').h > 60 && __t.box('n8').h > 90"), "a long title makes a bigger ellipse and diamond (it wraps, it is not squeezed)", eval("JSON.stringify([__t.box('n9'), __t.box('n8')])"))
let overlaps = json("""
const ids = Array.from(document.querySelectorAll('.rm-node-wrap')).filter(function (w) { return !w.hidden; }).map(function (w) { return w.getAttribute('data-id'); });
const boxes = ids.map(function (id) { return Object.assign({ id: id }, __t.box(id)); });
const bad = [];
for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
  const a = boxes[i], b = boxes[j];
  if (a.l < b.r - 0.5 && b.l < a.r - 0.5 && a.t < b.b - 0.5 && b.t < a.b - 0.5) bad.push(a.id + '/' + b.id);
}
return JSON.stringify({ count: ids.length, bad: bad });
""")
check((overlaps["count"] as? Int) == 12 && ((overlaps["bad"] as? [String]) ?? ["?"]).isEmpty, "with ellipses, diamonds, pills and sized cards among them no two nodes overlap", "\(overlaps)")
let tri = json("""
const near = function (id, kind) {
  const b = __t.btn(id).getBoundingClientRect(), t = __t.q('.rm-node-wrap[data-id="' + id + '"] .rm-tri').getBoundingClientRect();
  const a = b.width / 2, c = b.height / 2, dx = Math.abs(t.left + t.width / 2 - (b.left + a)) / a, dy = Math.abs(t.top + t.height / 2 - (b.top + c)) / c;
  return kind === 'ellipse' ? dx * dx + dy * dy : (kind === 'diamond' ? dx + dy : 0);
};
return JSON.stringify({ ellipse: near('n3', 'ellipse'), diamond: near('n2', 'diamond') });
""")
check(((tri["ellipse"] as? Double) ?? 9) <= 1.05 && ((tri["diamond"] as? Double) ?? 9) <= 1.05, "the ⋯ button of an ellipse and of a diamond sits on the shape, not in the empty corner of its box", "\(tri)")
check(bool("(function () { const f = __t.fold('n2').getBoundingClientRect(), b = __t.btn('n2').getBoundingClientRect(); return !__t.fold('n2').hidden && Math.abs((f.left + f.width / 2) - (b.left + b.width / 2)) < 2 && f.top < b.bottom + 1 && f.bottom > b.bottom - 1; })()"), "the fold toggle sits on the bottom corner of a diamond")
_ = js("__t.menu('n3'); return 'ok';")
check(visible(".rm-actions") && bool("__t.qa('.rm-actions [data-act]').length > 5"), "the node menu opens from an ellipse")
_ = js("__t.menu('n3'); return 'ok';")
check(!visible(".rm-actions"), "…and closes again")
// Handles.
_ = js("__t.select('n3'); return 'ok';")
check(number("document.querySelectorAll('.rm-handle:not([hidden])').length") == 8 && bool("__t.qa('.rm-handle:not([hidden])').every(function (h) { return h.parentNode === __t.wrap('n3'); })"), "the selected node shows eight resize handles and no other node does")
check(bool("['nw','n','ne','e','se','s','sw','w'].every(function (d) { return !!__t.handle('n3', d); })"), "…at the four corners and the four edges")
_ = js("__t.select('n4'); return 'ok';")
check(number("document.querySelectorAll('.rm-handle:not([hidden])').length") == 8 && bool("__t.qa('.rm-handle:not([hidden])').every(function (h) { return h.parentNode === __t.wrap('n4'); })"), "selecting another node moves the handles to it")

// Dragging a handle: live, around the centre, one update on release.
func shapedLook(n3: String = "shape: 'ellipse', width: 260", n5: String = "shape: 'rectangle', height: 120", n6: String = "width: 300") -> String {
    "{ nodes: __t.look({ n2: { shape: 'diamond' }, n3: { \(n3) }, n4: { shape: 'pill' }, n5: { \(n5) }, n6: { \(n6) } }).nodes }"
}
_ = js("__t.select('n3'); return 'ok';")
newMark()
let handleViewBefore = js("return JSON.stringify(__t.view());")
_ = js("__t.resizeStart('n3', 'e'); __t.dragTo(40, 0); return 'ok';")
check(bool("__t.box('n3').w === 340"), "dragging the east handle by 40 px makes the node 80 px wider (it grows around its centre)", eval("JSON.stringify(__t.box('n3'))"))
check(eval("__t.q('.rm-readout').textContent").hasPrefix("w 340") && visible(".rm-readout"), "a readout shows the size while dragging", eval("__t.q('.rm-readout').textContent"))
expectNone("nothing is sent while the handle moves", action: "update", wait: 0.3)
_ = js("__t.dragEnd(40, 0); return 'ok';")
expect("releasing sends one update with the width", ["action": "update", "id": "n3", "width": 340], doc: tabM)
expectNone("a handle never moves the node", action: "moveVisual", wait: 0.2)
check(js("return JSON.stringify(__t.view());") == handleViewBefore && !visible(".rm-readout"), "…nor pans the map; the readout is gone")
check(bool("__t.box('n3').w === 340"), "until Swift answers the node keeps the new size")
deliver(shapedLook(n3: "shape: 'ellipse', width: 340"))
check(bool("__t.box('n3').w === 340") && eval("__t.q('[data-dim=width]').value") == "340", "…and the snapshot confirms it in the card and in the Width field")
newMark()
_ = js("__t.resizeStart('n3', 'w'); __t.dragTo(-30, 0); return 'ok';")
check(bool("__t.box('n3').w === 400"), "dragging the west handle outwards grows the node too", eval("JSON.stringify(__t.box('n3'))"))
_ = js("__t.dragEnd(-30, 0); return 'ok';")
expect("…and sends the width", ["action": "update", "id": "n3", "width": 400], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400"))
newMark()
_ = js("__t.resizeStart('n3', 'e'); __t.dragTo(5000, 0); return 'ok';")
check(bool("__t.box('n3').w === 800"), "a width cannot go above the limit", eval("JSON.stringify(__t.box('n3'))"))
_ = js("__t.dragTo(-5000, 0); return 'ok';")
check(bool("__t.box('n3').w >= 60 && __t.box('n3').w < 100"), "…nor below the limit (the node is as narrow as its title allows)", eval("JSON.stringify(__t.box('n3'))"))
_ = js("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); __t.dragEnd(-5000, 0); return 'ok';")
check(bool("__t.box('n3').w === 400"), "Esc during the drag puts the size back")
expectNone("…and sends nothing", action: "update", wait: 0.3)
_ = js("__t.resizeStart('n3', 'e'); __t.dragEnd(1, 1); return 'ok';")
expectNone("a click on a handle (no movement) sends nothing", action: "update", wait: 0.3)

// Height: a floor, and a height at or below the title's is automatic.
_ = js("__t.select('n5'); return 'ok';")
newMark()
_ = js("__t.resizeStart('n5', 's'); __t.dragTo(0, 40); return 'ok';")
check(bool("__t.box('n5').h === 200"), "dragging the south handle by 40 px makes a node 80 px taller", eval("JSON.stringify(__t.box('n5'))"))
_ = js("__t.dragEnd(0, 40); return 'ok';")
expect("…and sends the height", ["action": "update", "id": "n5", "height": 200], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400", n5: "shape: 'rectangle', height: 200"))
newMark()
_ = js("__t.resizeStart('n5', 'n'); __t.dragTo(0, 500); return 'ok';")
check(bool("__t.box('n5').h < 60"), "dragging the north handle down shrinks the node to the height of its title, no further", eval("JSON.stringify(__t.box('n5'))"))
_ = js("__t.dragEnd(0, 500); return 'ok';")
expect("a height at or below the title's is sent as automatic (null)", ["action": "update", "id": "n5", "height": NSNull()], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400", n5: "shape: 'rectangle'"))
// A corner changes both.
_ = js("__t.select('n6'); return 'ok';")
newMark()
let n6Before = json("return JSON.stringify(__t.box('n6'));")
_ = js("__t.resizeStart('n6', 'se'); __t.dragTo(20, 30); __t.dragEnd(20, 30); return 'ok';")
let expectedHeight = Int((n6Before["h"] as? Double) ?? 0) + 60
expect("a corner handle sends the width and the height", ["action": "update", "id": "n6", "width": 340, "height": expectedHeight], doc: tabM)
deliver(shapedLook(n3: "shape: 'ellipse', width: 400", n5: "shape: 'rectangle'", n6: "width: 340, height: \(expectedHeight)"))
// A double click on a handle makes the size automatic.
newMark()
_ = js("__t.handle('n6', 'e').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return 'ok';")
expect("a double click on a handle sends automatic width and height", ["action": "update", "id": "n6", "width": NSNull(), "height": NSNull()], doc: tabM)
check(bool("__t.box('n6').w < 200"), "…and the card is automatic at once")
deliver()
newMark()
_ = js("__t.handle('n6', 'e').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return 'ok';")
expectNone("a double click on a node that is already automatic sends nothing", action: "update", wait: 0.3)
// Zoom: the handles keep their size on the screen.
_ = js("for (let i = 0; i < 3; i++) __t.q('[data-act=zoom-out]').click(); return 'ok';")
check(bool("(function () { const s = window.MVResearchMap.viewState().scale, h = __t.handle('n6', 'se').getBoundingClientRect(); return s < 0.8 && Math.abs(h.width - 10) < 1.5; })()"), "the corner handles stay 10 px on the screen when the map is zoomed out")
_ = js("__t.q('[data-act=centre]').click(); return 'ok';")
// Light theme: the diamond follows the theme.
deliver("{ nodes: __t.look({ n2: { shape: 'diamond' } }).nodes }")
_ = js(setThemeCall("classic-light"))
check(eval("getComputedStyle(__t.btn('n2').querySelector('polygon')).fill") != "rgb(37, 37, 38)", "light theme: the diamond is not drawn in the dark card colour", eval("getComputedStyle(__t.btn('n2').querySelector('polygon')).fill"))
_ = js(setThemeCall("classic-dark"))
// A node can go back to the plain look.
deliver()
check(bool("!__t.btn('n2').querySelector('.rm-shape') && __t.qa('.rm-node-wrap').every(function (w) { return w.className.indexOf('shape-') < 0 && !w.style.width; }) && __t.qa('.rm-node').every(function (b) { return !b.style.minHeight; })"), "a snapshot without shapes and sizes restores the plain cards")
deliver("{ nodes: __t.look({ n1: { shape: 'pill', width: 320 } }).nodes }")
check(bool("__t.wrap('n1').classList.contains('shape-pill') && __t.btn('n1').classList.contains('root') && __t.box('n1').w === 320"), "the root can have a shape and a size too")
deliver()
_ = js("__t.select('n6'); return 'ok';")

// ---- folding (BUG-092, DEC-010) ------------------------------------------------------------------------------------------------------
newMark()
check(bool("__t.fold('n1').hidden") && bool("__t.fold('n6').hidden") && !bool("__t.fold('n2').hidden"), "a node with children has a fold toggle; a leaf and the root have none")
check(bool("__t.shown('n6') && __t.shown('n7')"), "everything is shown at first")
_ = js("__t.fold('n2').click(); return 'ok';")
check(bool("!__t.shown('n6') && !__t.shown('n7') && __t.shown('n2') && __t.shown('n3')"), "folding a node hides its children and nothing else")
check(eval("__t.fold('n2').textContent") == "+2" && bool("__t.fold('n2').getAttribute('aria-expanded') === 'false'") && bool("__t.fold('n2').classList.contains('folded')"), "a folded node says how many nodes it hides")
check(number("document.querySelectorAll('path[data-line=tree]').length") == 9, "the lines into hidden nodes are gone")
check(number("document.querySelectorAll('path[data-line=link]').length") == 1, "a logical connection to a hidden node is hidden too; the other stays")
check(bool("(function () { const a = __t.pos('n2'), b = __t.pos('n3'); return isFinite(a.x) && isFinite(b.x); })()"), "the remaining nodes are laid out")
check(eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[\"n2\"]", "the fold state is kept as view state")
newMark()
_ = js("__t.fold('n2').click(); return 'ok';")
check(bool("__t.shown('n6') && __t.shown('n7')") && number("document.querySelectorAll('path[data-line=tree]').length") == 11 && number("document.querySelectorAll('path[data-line=link]').length") == 2, "folding again shows them")
expectNone("folding sends nothing to Swift", action: "update", wait: 0.3)
_ = js("__t.select('n8'); __t.fold('n3').click(); return 'ok';")
check(bool("__t.btn('n3').getAttribute('aria-pressed') === 'true'") && eval("__t.q('.rm-title-input').value") == "Compiler", "folding the branch of the selected node selects the branch")
_ = js("__t.fold('n3').click(); return 'ok';")
_ = js("__t.q('[data-act=collapse-all]').click(); return 'ok';")
check(bool("['n1', 'n2', 'n3', 'n4', 'n5'].every(function (id) { return __t.shown(id); }) && ['n6', 'n7', 'n8', 'n9', 'n10', 'n11', 'n12'].every(function (id) { return !__t.shown(id); })"), "Collapse all leaves the root and its main branches")
check(eval("['n2', 'n3', 'n4', 'n5'].map(function (id) { return __t.fold(id).textContent; }).join()") == "+2,+2,+2,+1", "…each folded branch shows its hidden count")
_ = js("__t.q('[data-act=expand-all]').click(); return 'ok';")
check(bool("['n1','n2','n3','n4','n5','n6','n7','n8','n9','n10','n11','n12'].every(function (id) { return __t.shown(id); })") && eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[]", "Expand all shows every node")
// A node the person adds under a folded branch is shown (it is selected).
_ = js("__t.fold('n3').click(); return 'ok';")
deliver("{ created: 'n13', nodes: (function () { const s = __t.snap(); s.nodes.splice(8, 0, { id: 'n13', parent: 'n3', title: 'Fresh', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })() }")
check(bool("__t.shown('n13') && __t.shown('n8')") && bool("__t.btn('n13').getAttribute('aria-pressed') === 'true'"), "a created node under a folded branch unfolds the branch and is selected")
deliver()

// ---- focus (REQ-011) -------------------------------------------------------------------------------------------------------------------
// A third level (n14 under n8) shows that the children of a focused node's children stay folded.
let deepNodes = "{ nodes: (function () { const s = __t.snap(); s.nodes.push({ id: 'n14', parent: 'n8', title: 'Cache keys', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })() }"
deliver(deepNodes)
_ = js("__t.q('[data-act=expand-all]').click(); __t.select('n12'); __t.menu('n3'); return 'ok';")
check(bool("!!__t.q('.rm-actions [data-act=focus]')"), "the node menu offers Focus")
newMark()
_ = js("__t.act('focus'); return 'ok';")
check(bool("['n1', 'n2', 'n3', 'n4', 'n5', 'n8', 'n9'].every(function (id) { return __t.shown(id); }) && ['n6', 'n7', 'n10', 'n11', 'n12', 'n14'].every(function (id) { return !__t.shown(id); })"),
      "Focus shows the path from the root, the siblings along it and the node's children, and folds the rest")
check(eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[\"n2\",\"n4\",\"n5\",\"n8\"]", "…the other branches and the focused node's children are folded; the path and the node are not", eval("JSON.stringify(window.MVResearchMap.collapsed())"))
check(eval("__t.fold('n8').textContent") == "+1" && bool("__t.fold('n3').getAttribute('aria-expanded') === 'true'"), "…a child of the focused node says what it hides; the focused node is open")
check(bool("__t.btn('n3').getAttribute('aria-pressed') === 'true'") && eval("__t.q('.rm-title-input').value") == "Compiler", "the focused node is selected, even though the selection was on a node that is now hidden")
let focusAt = json("const n = __t.btn('n3').getBoundingClientRect(), v = __t.q('.rm-viewport').getBoundingClientRect(); return JSON.stringify({ dx: Math.round((n.left + n.width / 2) - (v.left + v.width / 2)), dy: Math.round((n.top + n.height / 2) - (v.top + v.height / 2)) });")
check(abs((focusAt["dx"] as? Int) ?? 999) <= 2 && abs((focusAt["dy"] as? Int) ?? 999) <= 2, "the focused node is brought to the middle of the map", "\(focusAt)")
expectNone("Focus sends nothing to Swift: the file does not change", action: "update", wait: 0.3)
// A leaf at the third level: its whole path is open.
_ = js("__t.menu('n14'); __t.act('focus'); return 'ok';")
check(bool("['n1', 'n2', 'n3', 'n4', 'n5', 'n8', 'n9', 'n14'].every(function (id) { return __t.shown(id); }) && ['n6', 'n7', 'n10', 'n11', 'n12'].every(function (id) { return !__t.shown(id); })") && eval("JSON.stringify(window.MVResearchMap.collapsed())") == "[\"n2\",\"n4\",\"n5\"]", "Focus on a leaf opens its path and folds the other branches")
// The root: the same as Collapse all.
_ = js("__t.menu('n1'); __t.act('focus'); return 'ok';")
let focusRoot = eval("JSON.stringify(window.MVResearchMap.collapsed())")
check(bool("__t.btn('n1').getAttribute('aria-pressed') === 'true'"), "Focus on the root selects the root")
_ = js("__t.q('[data-act=expand-all]').click(); __t.q('[data-act=collapse-all]').click(); return 'ok';")
check(focusRoot == eval("JSON.stringify(window.MVResearchMap.collapsed())"), "Focus on the root folds the map like Collapse all", focusRoot)
_ = js("__t.q('[data-act=expand-all]').click(); return 'ok';")
check(bool("['n1','n2','n3','n4','n5','n6','n7','n8','n9','n10','n11','n12','n14'].every(function (id) { return __t.shown(id); })"), "Expand all undoes a Focus")
deliver()

// A long title is never cut: the title field wraps.
_ = js("__t.select('n2'); return 'ok';")
deliver("{ nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n2'; }).title = 'Мне нужно сделать deep research, так сказать, узнать полностью всё о том, как происходят финансы в нашей системе внутри'; return s.nodes; })() }")
let titleBox = json("const t = __t.q('.rm-title-input'); return JSON.stringify({ tag: t.tagName, offset: t.offsetHeight, scroll: t.scrollHeight, client: t.clientHeight, width: t.offsetWidth, value: t.value.length, style: t.style.height });")
check((titleBox["tag"] as? String) == "TEXTAREA" && ((titleBox["offset"] as? Double) ?? 0) > 44 && ((titleBox["scroll"] as? Double) ?? 1) <= ((titleBox["client"] as? Double) ?? 0) + 1, "a long title wraps in the panel instead of being cut (BUG-091)", "\(titleBox)")
deliver()

// ---- diagram and image nodes, Draw (REQ-012, DEC-013) --------------------------------------------------------------------------
func until(_ expression: String, _ seconds: TimeInterval = 25) -> Bool { spin(seconds) { bool(expression) }; return bool(expression) }
let flowSource = "sequenceDiagram\n  participant A as Client\n  participant B as Server\n  A->>B: sign in\n  B-->>A: token"
let imageSVG = "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'><rect width='120' height='60' fill='#4a8'/></svg>"
let imageData = "data:image/svg+xml;base64," + Data(imageSVG.utf8).base64EncodedString()
let flowText = "```mermaid\n\(flowSource)\n```\n\nNote"
_ = js("window.__v = { flow: flow, bad: bad, img: img }; return 'ok';", ["flow": flowText, "bad": "```mermaid\nthis is not a diagram at all (\n```", "img": "![Cache layer](\(imageData))"])
let theme0 = js("return document.documentElement.getAttribute('data-preset') || 'classic-dark';")
_ = js("window.mvResearchMapSet(window.mvDocumentId, window.__t.look({ n3: { visual: 'diagram', description: __v.flow }, n4: { visual: 'diagram', description: __v.bad }, n5: { visual: 'image', description: __v.img }, n12: { visual: 'diagram', description: 'no fence here' } })); return 'ok';")
let card3 = ".rm-node-wrap[data-id=\"n3\"] .rm-vis"
check(until("!!__t.q('\(card3) svg')"), "a diagram node draws its Mermaid on the card")
check(bool("__t.btn('n3').classList.contains('is-visual') && __t.wrap('n3').classList.contains('visual')"), "…and the card is a visual card")
check(eval("getComputedStyle(__t.btn('n3').querySelector('.rm-label')).display") == "none" && eval("__t.btn('n3').getAttribute('title')") == "Compiler", "…the title is hidden but stays as the tooltip")
check(eval("__t.btn('n3').getAttribute('aria-label')").contains("Compiler"), "…and in the accessible name")
check(number("parseFloat(__t.q('\(card3) svg').getAttribute('width'))") <= 280 && number("__t.box('n3').w") <= 330 && number("__t.box('n3').h") > 40, "…scaled to the card, not wider than the card limit")
check(!bool("__t.btn('n2').classList.contains('is-visual')") && eval("getComputedStyle(__t.btn('n2').querySelector('.rm-label')).display") != "none", "a text node is unchanged")
check(until("!!__t.q('.rm-node-wrap[data-id=\"n4\"] .rm-vis.error')") && eval("__t.q('.rm-node-wrap[data-id=\"n4\"] .rm-vis-note').textContent") == "This diagram could not be drawn" && number("__t.box('n4').h") > 20,
      "a diagram that cannot be drawn shows an error state, never an empty card")
check(!bool("__t.btn('n12').classList.contains('is-visual')") && eval("__t.btn('n12').querySelector('.rm-label').textContent") == "Remote cache", "a diagram node with no Mermaid block shows its title")
check(until("(function(){ const i = __t.q('.rm-node-wrap[data-id=\"n5\"] .rm-vis img'); return !!i && i.naturalWidth === 120; })()"), "an image node shows its picture on the card")
check(bool("__t.btn('n5').classList.contains('is-visual')") && number("__t.box('n5').w") <= 330, "…in a visual card")
let sizeSeen = js("return JSON.stringify(Object.keys(window.__t.snap().nodes).length);")
check(sizeSeen != "0", "the map still draws all its nodes")

// The panel: Content row, preview, source, Expand.
_ = js("__t.select('n3'); return 'ok';")
spin(0.3)
check(eval("__t.q('[data-visual=\"diagram\"]').getAttribute('aria-pressed')") == "true" && eval("__t.q('[data-visual=\"text\"]').getAttribute('aria-pressed')") == "false", "the Content row says Diagram for a diagram node")
check(visible(".rm-visual-pane") && until("!!__t.q('.rm-vis-panel svg')"), "…the panel shows the diagram larger")
check(eval("__t.q('.rm-vis-source').value") == flowSource && visible(".rm-vis-source") && !visible(".rm-image-input"), "…with its Mermaid source to edit")
check(bool("__t.q('[data-shape=\"rounded\"]').closest('.rm-look-row').hidden"), "…and no shape row, the card ignores shapes")
_ = js("__t.q('.rm-visual-pane .rm-chip-btn').click(); return 'ok';")
check(until("!!document.querySelector('.diagram-viewer.visible svg')", 5), "Expand opens the full-screen viewer with the diagram")
check(number("document.querySelectorAll('.diagram-viewer.visible .diagram-viewer-toolbar button').length") >= 4, "…with its zoom controls")
_ = js("document.querySelector('.diagram-viewer button[data-action=\"close\"]').click(); return 'ok';")
check(!bool("!!document.querySelector('.diagram-viewer.visible')"), "…and it closes")
_ = js("__t.btn('n3').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return 'ok';")
check(until("!!document.querySelector('.diagram-viewer.visible svg')", 5), "a double click on the card opens the viewer too")
_ = js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return 'ok';")
check(!bool("!!document.querySelector('.diagram-viewer.visible')"), "…and Esc closes it")
_ = js("__t.btn('n12').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true })); return 'ok';")
spin(0.3)
check(!bool("!!document.querySelector('.diagram-viewer.visible')"), "a double click on a text card opens nothing")

// Content row and source: they edit the node's visual and its description.
newMark()
_ = js("__t.q('[data-visual=\"text\"]').click(); return 'ok';")
expect("Text sends visual '' and keeps the description", ["action": "update", "id": "n3", "visual": ""])
newMark()
_ = js("__t.type(__t.q('.rm-vis-source'), 'flowchart LR\\n  A --> B'); return 'ok';")
expect("typing Mermaid replaces the first fence and keeps the rest of the description", ["action": "update", "id": "n3", "description": "```mermaid\nflowchart LR\n  A --> B\n```\n\nNote"])
newMark()
_ = js("__t.select('n2'); __t.q('[data-visual=\"diagram\"]').click(); return 'ok';")
expect("Diagram on a text node sends visual diagram", ["action": "update", "id": "n2", "visual": "diagram"])
newMark()
_ = js("__t.select('n5'); return 'ok';")
spin(0.3)
check(eval("__t.q('[data-visual=\"image\"]').getAttribute('aria-pressed')") == "true" && visible(".rm-image-input") && !visible(".rm-vis-source") && eval("__t.q('.rm-image-input').value") == imageData, "an image node shows the picture address in the panel")
_ = js("__t.type(__t.q('.rm-image-input'), 'images/cache.png'); return 'ok';")
expect("typing an address replaces the first picture, keeping its alternative text", ["action": "update", "id": "n5", "description": "![Cache layer](images/cache.png)"])
let helperOut = js("const V = window.MVResearchMap.visual; return JSON.stringify([V.withDiagram('text only', 'graph TD\\n  A-->B'), V.withDiagram('```mermaid\\nx\\n```\\nafter', ''), V.withImage('', 'My pic', 'a b.png'), V.withImage('![x](y.png) tail', 'x', ''), V.imageOf('intro ![Login screen](images/login.png \"a title\") and ![second](b.png)').src, V.diagramSourceOf('```mermaid\\n```'), V.diagramSourceOf('```mermaid\\nflowchart LR')]);")
check(helperOut == "[\"```mermaid\\ngraph TD\\n  A-->B\\n```\\n\\ntext only\",\"after\",\"![My pic](a%20b.png)\",\" tail\",\"images/login.png\",null,null]", "the page's Mermaid and picture helpers behave like the Swift ones", helperOut)

// The theme: a diagram is drawn again in the colours of the new theme.
let drawnDark = eval("__t.q('\(card3)')._vk")
_ = js(setThemeCall("classic-light"))
check(until("(__t.q('\(card3)')._vk || '').endsWith('\\nclassic-light|') && !!__t.q('\(card3) svg')"), "a theme change draws the diagram again", drawnDark)
_ = js(setThemeCall("midnight"))
check(until("(__t.q('\(card3)')._vk || '').endsWith('\\nmidnight|') && !!__t.q('\(card3) svg')"), "…a change between two dark themes too")
_ = js(setThemeCall("classic-dark"))
check(until("(__t.q('\(card3)')._vk || '').endsWith('\\nclassic-dark|') && !!__t.q('\(card3) svg')"), "…and back")
_ = js(setThemeCall(theme0))

// Draw: in the node menu and in the panel.
_ = js("__t.select('n3'); __t.menu('n3'); return 'ok';")
check(bool("!!__t.q('.rm-actions [data-act=\"draw\"]')") && !bool("__t.q('.rm-actions [data-act=\"draw\"]').disabled"), "the node menu has Draw")
_ = js("__t.act('draw'); return 'ok';")
check(eval("__t.qa('.rm-draw-menu button').map(function (b) { return b.getAttribute('data-kind'); }).join()") == "sequence,flowchart,dataflow,architecture,er,deployment,pipeline,custom", "Draw lists the Graph Creator's types")
newMark()
_ = js("__t.q('.rm-draw-menu [data-kind=\"sequence\"]').click(); return 'ok';")
expect("a type sends draw with the node and the type", ["action": "draw", "id": "n3", "kind": "sequence"])
check(!bool("!!__t.q('.rm-actions')"), "…and closes the menu")
_ = js("__t.menu('n3'); __t.act('draw'); __t.q('.rm-draw-menu [data-kind=\"custom\"]').click(); return 'ok';")
check(visible(".rm-dialog"), "Custom asks what the diagram should show")
newMark()
_ = js("__t.dialogButton('Draw'); return 'ok';")
expectNone("…an empty instruction sends nothing", action: "draw")
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "Say what the diagram should show.", "…and says why")
_ = js("__t.type(__t.q('.rm-dialog textarea'), 'the retry rules'); __t.dialogButton('Draw'); return 'ok';")
expect("…and the typed instruction goes with the type", ["action": "draw", "id": "n3", "kind": "custom", "instruction": "the retry rules"])
newMark()
_ = js("__t.q('.rm-ai-btn[data-act=\"draw\"]').click(); return 'ok';")
check(number("__t.qa('.rm-draw-list button').length") == 8 && visible(".rm-draw-list"), "the panel has a Draw button with the same types")
_ = js("__t.q('.rm-draw-list [data-kind=\"flowchart\"]').click(); return 'ok';")
expect("…and a type sends draw", ["action": "draw", "id": "n3", "kind": "flowchart"])
check(!visible(".rm-draw-list"), "…and closes the list")
_ = js("window.mvResearchMapSet(window.mvDocumentId, window.__t.look({ n3: { visual: 'diagram', description: __v.flow } }) && Object.assign(window.__t.look({ n3: { visual: 'diagram', description: __v.flow } }), { job: { kind: 'draw', label: 'Draw sequence: Compiler', step: 'Thinking', startedAt: Date.now() / 1000 } })); __t.menu('n3'); return 'ok';")
check(bool("__t.q('.rm-actions [data-act=\"draw\"]').disabled") && bool("__t.q('.rm-ai-btn[data-act=\"draw\"]').disabled"), "Draw is off while an AI job works on the map")
_ = js("window.__t.deliver(window.__t.snap()); return 'ok';")
spin(0.3)
deliver("{}")
_ = js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return 'ok';")

// ---- export and translate (REQ-013, REQ-014) ------------------------------------------------------------------------------------------
newMark()
check(!visible(".rm-exportmenu"), "the export menu is closed at first")
_ = js("localStorage.removeItem('mvMapLang:export'); localStorage.removeItem('mvMapLang:translate'); __t.q('[data-act=export]').click(); return 'ok';")
check(visible(".rm-exportmenu") && eval("__t.qa('.rm-exportmenu [data-act]').map(function(b){return b.textContent.trim();}).join('|')") == "Markdown report…|PDF…|Translate map…", "Export opens a menu: Markdown report, PDF and Translate map")
_ = js("__t.q('[data-act=export-markdown]').click(); return 'ok';")
check(!visible(".rm-exportmenu") && visible(".rm-dialog"), "choosing the report closes the menu and asks for the language")
check(eval("__t.qa('.rm-dialog select option').map(function(o){return o.textContent;}).join('|')") == "The language of the map|English|Russian|Other…" && eval("__t.q('.rm-dialog select').value") == "", "the dialog offers the map's own language first, then the languages of the snapshot, then Other…")
check(!bool("!!__t.qa('.rm-dialog input').find(function (i) { return !i.hidden; })"), "…and no name field until Other… is chosen")
_ = js("__t.dialogButton('Cancel'); return 'ok';")
expectNone("Cancel sends nothing", action: "export", wait: 0.3)
_ = js("__t.q('[data-act=export]').click(); __t.q('[data-act=export-markdown]').click(); __t.dialogButton('Export'); return 'ok';")
expect("the report with the map's own language sends export with an empty language", ["action": "export", "kind": "markdown", "language": ""], doc: tabM)
newMark()
_ = js("__t.q('[data-act=export]').click(); __t.q('[data-act=export-pdf]').click(); const s = __t.q('.rm-dialog select'); s.value = 'English'; s.dispatchEvent(new Event('change', { bubbles: true })); __t.dialogButton('Export…'); return 'ok';")
expect("PDF with English sends export with kind pdf and the language", ["action": "export", "kind": "pdf", "language": "English"], doc: tabM)
check(js("return localStorage.getItem('mvMapLang:export') || '';") == "English", "the last choice is remembered")
_ = js("__t.q('[data-act=export]').click(); __t.q('[data-act=export-markdown]').click(); return 'ok';")
check(eval("__t.q('.rm-dialog select').value") == "English", "…and is the default next time")
newMark()
_ = js("const s = __t.q('.rm-dialog select'); s.value = '__other'; s.dispatchEvent(new Event('change', { bubbles: true })); __t.dialogButton('Export'); return 'ok';")
expectNone("Other… with no name sends nothing", action: "export", wait: 0.3)
check(eval("__t.q('.rm-dialog .rm-error').textContent") == "Type the name of the language.", "…and says why")
_ = js("const i = __t.qa('.rm-dialog input').find(function (x) { return !x.hidden; }); __t.type(i, 'Japanese'); __t.dialogButton('Export'); return 'ok';")
expect("a typed language is sent as typed", ["action": "export", "kind": "markdown", "language": "Japanese"], doc: tabM)
newMark()
_ = js("__t.q('[data-act=export]').click(); __t.q('[data-act=translate]').click(); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog h2').textContent") == "Translate map", "Translate map opens its dialog")
check(eval("__t.qa('.rm-dialog select')[0].textContent.replace(/\\s+/g, ' ')") == "EnglishRussianOther…" && eval("__t.qa('.rm-dialog select')[1].value") == "copy", "…with the languages and the result, a new map by default")
_ = js("const s = __t.qa('.rm-dialog select'); s[0].value = 'Russian'; s[0].dispatchEvent(new Event('change', { bubbles: true })); __t.dialogButton('Translate'); return 'ok';")
expect("Translate sends the language and the mode", ["action": "translate", "language": "Russian", "mode": "copy"], doc: tabM)
newMark()
_ = js("__t.q('[data-act=export]').click(); __t.q('[data-act=translate]').click(); const s = __t.qa('.rm-dialog select'); s[1].value = 'replace'; __t.dialogButton('Translate'); return 'ok';")
expect("replacing is a choice of its own", ["action": "translate", "language": "Russian", "mode": "replace"], doc: tabM)
_ = js("window.mvResearchMapSet(window.mvDocumentId, Object.assign(window.__t.snap(), { job: { kind: 'translate', label: 'Translate to Russian: x', step: 'Translating nodes 1-12 of 12', startedAt: Date.now() / 1000 } })); __t.q('[data-act=export]').click(); __t.q('[data-act=translate]').click(); return 'ok';")
check(!visible(".rm-dialog"), "no export or translate dialog opens while an AI job works on the map")
deliver()
_ = js("__t.q('[data-act=export]').click(); return 'ok';")
_ = js("document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })); return 'ok';")
check(!visible(".rm-exportmenu"), "a click elsewhere closes the export menu")

newMark()
_ = js("__t.menu('n3'); __t.act('arrange'); return 'ok';")
check(number("document.querySelectorAll('.rm-layouts button').length") == 7 && eval("__t.qa('.rm-layouts button').map(function(b){return b.dataset.layout;}).join()") == "balanced,right,left,down,up,radial,outline", "Arrange lists the snapshot's layouts in order")
check(eval("__t.qa('.rm-layouts button[aria-checked=true]').map(function(b){return b.dataset.layout;}).join()") == "balanced", "the root's default layout is marked as the current one")
_ = js("__t.q('.rm-layouts button[data-layout=radial]').click(); return 'ok';")
expect("choosing a layout sends layout", ["action": "layout", "id": "n3", "layout": "radial"], doc: tabM)
check(!visible(".rm-actions"), "the menu closes after choosing")
let nestedSnapshot = "{ nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n3'; }).layout = 'down'; return s.nodes; })() }"
deliver(nestedSnapshot)
_ = js("__t.menu('n8'); __t.act('arrange'); return 'ok';")
check(eval("__t.qa('.rm-layouts button[aria-checked=true]').map(function(b){return b.dataset.layout;}).join()") == "down", "a node without its own layout shows the nearest ancestor's layout as current")
_ = js("__t.menu('n8'); return 'ok';")
deliver()

newMark()
_ = js("__t.menu('n2'); __t.act('delete'); return 'ok';")
check(eval("__t.q('.rm-dialog').textContent").contains("Delete node “Dependencies” and its child nodes (2)"), "Delete asks first and states the number of descendants", eval("__t.q('.rm-dialog').textContent"))
_ = js("__t.dialogButton('Cancel'); return 'ok';")
expectNone("Cancel sends nothing", action: "delete", wait: 0.3)
_ = js("__t.menu('n2'); __t.act('delete'); __t.dialogButton('Delete'); return 'ok';")
expect("confirming sends delete", ["action": "delete", "id": "n2"], doc: tabM)
_ = js("__t.menu('n7'); __t.act('delete'); return 'ok';")
check(!eval("__t.q('.rm-dialog').textContent").contains("child nodes"), "a leaf's delete dialog has no descendant count", eval("__t.q('.rm-dialog').textContent"))
_ = js("__t.q('.rm-btn[data-kind=ghost]').click(); return 'ok';")
_ = js("__t.menu('n7'); __t.act('add'); return 'ok';")
_ = js("document.querySelector('.rm-root').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return 'ok';")
check(!visible(".rm-dialog"), "Escape closes a dialog")

// ---- editing in the properties panel ------------------------------------------------------------------------------------------------------
_ = js("__t.select('n2'); return 'ok';")
newMark()
_ = js("const i = __t.q('.rm-title-input'); __t.type(i, 'D'); __t.type(i, 'De'); __t.type(i, 'Dependencies v2'); return 'ok';")
spin(0.12)
check(researchMessages().isEmpty, "typing a title sends nothing yet (debounced)", describe(researchMessages()))
check(eval("__t.btn('n2').textContent") == "Dependencies v2", "the node on the map follows the typing at once")
expect("one update with the final title after the pause", ["action": "update", "id": "n2", "title": "Dependencies v2"], doc: tabM)
newMark()
_ = js("__t.type(__t.q('.rm-title-input'), '   '); return 'ok';")
check(eval("__t.q('.rm-error').textContent") == "Enter a node name.", "an empty title shows an inline error")
expectNone("…and is not sent", action: "update", wait: 0.6)
_ = js("__t.q('.rm-title-input').blur(); return 'ok';")
check(eval("__t.q('.rm-title-input').value") == "Dependencies" && eval("__t.q('.rm-error').textContent") == "", "leaving the field restores the saved title", eval("__t.q('.rm-title-input').value"))
deliver()

newMark()
_ = js("const i = __t.q('.rm-tag-input'); i.focus(); i.value = 'New Tag'; __t.key(i, 'Enter'); return 'ok';")
expect("Enter adds a tag: update with the whole tag list", ["action": "update", "id": "n2", "tags": ["deps", "build", "New Tag"]], doc: tabM)
newMark()
_ = js("const i = __t.q('.rm-tag-input'); i.focus(); i.value = 'DEPS'; __t.key(i, 'Enter'); return 'ok';")
expectNone("a tag that differs only in case is not added", action: "update", wait: 0.5)
check(eval("__t.q('.rm-tag-input').value") == "", "the tag field is cleared")
newMark()
_ = js("__t.q('.rm-tag[data-tag=deps] button').click(); return 'ok';")
expect("× removes a tag", ["action": "update", "id": "n2", "tags": ["build"]], doc: tabM)

newMark()
_ = js("const c = __t.q('.rm-color-input'); c.value = '#aa5500'; c.dispatchEvent(new Event('change', { bubbles: true })); return 'ok';")
expect("the colour input sends update with the colour", ["action": "update", "id": "n2", "color": "#aa5500"], doc: tabM)
deliver("{ nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n2'; }).color = '#aa5500'; return s.nodes; })() }")
let tinted = json("const s = getComputedStyle(__t.btn('n2')); return JSON.stringify({ border: s.borderLeftColor, width: s.borderLeftWidth });")
check((tinted["border"] as? String) == "rgb(170, 85, 0)", "a node with its own colour takes it as its accent edge", "\(tinted)")
let lineColours = json("return JSON.stringify({ paths: __t.qa('path[data-line=tree]').map(function (p) { return getComputedStyle(p).stroke; }) });")
check(((lineColours["paths"] as? [String]) ?? []).contains("rgb(170, 85, 0)"), "the line into a node with its own colour takes that colour (Q-007 A)", "\(lineColours)")
check(((lineColours["paths"] as? [String]) ?? []).contains("rgb(78, 201, 176)"), "other lines keep their branch colour", "\(lineColours)")
newMark()
_ = js("__t.q('.rm-color-row .rm-x').click(); return 'ok';")
expect("the reset button sends an empty colour", ["action": "update", "id": "n2", "color": ""], doc: tabM)
deliver()

newMark()
_ = js("const d = __t.q('.rm-desc'); __t.type(d, 'hello world'); d.setSelectionRange(0, 5); __t.q('[data-fmt=bold]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "**hello** world", "Bold wraps the selection in Markdown", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = 'one'; d.setSelectionRange(0, 3); __t.q('[data-fmt=italic]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "*one*", "Italic wraps the selection", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = ''; d.setSelectionRange(0, 0); __t.q('[data-fmt=link]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "[text](url)", "Link inserts a link around a placeholder", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = ''; d.setSelectionRange(0, 0); __t.q('[data-fmt=image]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "![description](image url)", "Image inserts Markdown image syntax", eval("__t.q('.rm-desc').value"))
_ = js("const d = __t.q('.rm-desc'); d.value = 'item'; d.setSelectionRange(0, 4); __t.q('[data-fmt=list]').click(); return 'ok';")
check(eval("__t.q('.rm-desc').value") == "- item", "List prefixes the selection", eval("__t.q('.rm-desc').value"))
expect("the description is sent once, after the pause", ["action": "update", "id": "n2", "description": "- item"], doc: tabM)
deliver()

// ---- dragging, keyboard moves and view ---------------------------------------------------------------------------------------------------
let before = json("return JSON.stringify({ n4: __t.pos('n4'), n10: __t.pos('n10'), n3: __t.pos('n3') });")
let n4 = before["n4"] as? [String: Double] ?? [:], n10 = before["n10"] as? [String: Double] ?? [:], n3 = before["n3"] as? [String: Double] ?? [:]
newMark()
_ = js("__t.dragStart('n4'); __t.dragTo(1, 1); return 'ok';")
check(bool("__t.btn('n4').getAttribute('aria-pressed') === 'false'") && visible(".rm-readout") == false, "a movement under the threshold is not a drag")
_ = js("__t.dragTo(60, 30); return 'ok';")
check(visible(".rm-readout") && eval("__t.q('.rm-readout').textContent").hasPrefix("x "), "dragging shows the live position", eval("__t.q('.rm-readout').textContent"))
let live = json("return JSON.stringify({ n4: __t.pos('n4'), n10: __t.pos('n10'), n3: __t.pos('n3') });")
let liveN4 = live["n4"] as? [String: Double] ?? [:], liveN10 = live["n10"] as? [String: Double] ?? [:], liveN3 = live["n3"] as? [String: Double] ?? [:]
check(liveN4["x"] == (n4["x"] ?? 0) + 60 && liveN4["y"] == (n4["y"] ?? 0) + 30, "the node follows the pointer while dragging", "\(live)")
check(liveN10["x"] == (n10["x"] ?? 0) + 60 && liveN10["y"] == (n10["y"] ?? 0) + 30, "its branch follows it (the layout travels with the node)", "\(live)")
check(liveN3 == n3, "other branches stay where they are", "\(live)")
expectNone("nothing is sent while dragging", action: "moveVisual", wait: 0.3)
_ = js("__t.dragEnd(60, 30, true); return 'ok';")
expect("releasing sends moveVisual with the node's centre", ["action": "moveVisual", "id": "n4", "x": Int((n4["x"] ?? 0) + 60), "y": Int((n4["y"] ?? 0) + 30)], doc: tabM)
check(!visible(".rm-readout"), "the live readout goes away on release")
check(bool("__t.btn('n4').getAttribute('aria-pressed') === 'false'"), "the click that ends a drag does not select the node")
let after = json("return JSON.stringify({ n4: __t.pos('n4') });")
check((after["n4"] as? [String: Double])?["x"] == (n4["x"] ?? 0) + 60, "the node stays at the dropped place until Swift answers")
// Swift's answer carries the position.
deliver("{ nodes: (function () { const s = __t.snap(); const n = s.nodes.find(function (m) { return m.id === 'n4'; }); n.x = \(Int((n4["x"] ?? 0) + 60)); n.y = \(Int((n4["y"] ?? 0) + 30)); return s.nodes; })() }")
let manual = json("return JSON.stringify({ n4: __t.pos('n4'), n10: __t.pos('n10') });")
check((manual["n4"] as? [String: Double])?["x"] == (n4["x"] ?? 0) + 60 && (manual["n10"] as? [String: Double])?["x"] == (n10["x"] ?? 0) + 60,
      "a snapshot with x and y places the node exactly there and its descendants relative to it", "\(manual)")
deliver()

// A click with a tiny movement is a click.
newMark()
_ = js("__t.dragStart('n5'); __t.dragTo(2, 1); __t.dragEnd(2, 1, true); return 'ok';")
check(bool("__t.btn('n5').getAttribute('aria-pressed') === 'true'"), "a click with 2px of jitter still selects")
expectNone("…and does not move the node", action: "moveVisual", wait: 0.4)

// Keyboard moves: arrows 10, shift 40; one message after the last key.
let key0 = json("return JSON.stringify({ n5: __t.pos('n5') });")
let n5 = key0["n5"] as? [String: Double] ?? [:]
newMark()
_ = js("const i = __t.q('.rm-title-input'); i.focus(); __t.key(i, 'ArrowLeft'); document.body.focus(); __t.key(document.body, 'ArrowRight'); __t.key(document.body, 'ArrowDown', { shiftKey: true }); return 'ok';")
check((json("return JSON.stringify({ n5: __t.pos('n5') });")["n5"] as? [String: Double])?["x"] == (n5["x"] ?? 0) + 10, "an arrow key moves the selected node by 10 at once (also with no node focused), and not while typing in a field")
expect("keyboard moves are sent once, together", ["action": "moveVisual", "id": "n5", "x": Int((n5["x"] ?? 0) + 10), "y": Int((n5["y"] ?? 0) + 40)], doc: tabM)
deliver()

// Wheel zoom (never pans), buttons, limits, pan, centre.
let wheelBefore = json("return JSON.stringify(__t.view());")
let vbox = json("const r = __t.q('.rm-viewport').getBoundingClientRect(); return JSON.stringify({ left: r.left, top: r.top });")
let originX = (vbox["left"] as? Double ?? 0) + (wheelBefore["x"] as? Double ?? 0), originY = (vbox["top"] as? Double ?? 0) + (wheelBefore["y"] as? Double ?? 0)
let prevented = js("return String(__t.wheel(\(originX), \(originY), -100));")
let wheelAfter = json("return JSON.stringify(__t.view());")
check(prevented == "true", "the wheel is captured by the canvas (the page does not scroll)")
check(abs((wheelAfter["scale"] as? Double ?? 0) - 1.1) < 0.001, "a wheel notch up zooms in by 1.1", "\(wheelAfter)")
check(abs((wheelAfter["x"] as? Double ?? 0) - (wheelBefore["x"] as? Double ?? 0)) < 1 && abs((wheelAfter["y"] as? Double ?? 0) - (wheelBefore["y"] as? Double ?? 0)) < 1, "zooming around the pointer does not pan (the world point under the pointer stays put)", "\(wheelBefore) \(wheelAfter)")
_ = js("__t.wheel(10, 10, 100); return 'ok';")
check(abs((json("return JSON.stringify(__t.view());")["scale"] as? Double ?? 0) - 1.0) < 0.001, "a wheel notch down zooms out")
_ = js("__t.wheel(300, 300, 40); __t.wheel(300, 300, 40); return 'ok';")
check(number("__t.view().scale") < 0.85, "the plain wheel only ever zooms")
_ = js("__t.q('[data-act=centre]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "100%", "Centre returns to 100%")
_ = js("__t.q('[data-act=zoom-in]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "120%", "the zoom button multiplies by 1.2", eval("__t.q('.rm-zoom').textContent"))
_ = js("for (let i = 0; i < 12; i++) __t.q('[data-act=zoom-in]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "200%", "zoom stops at 200%", eval("__t.q('.rm-zoom').textContent"))
_ = js("for (let i = 0; i < 25; i++) __t.q('[data-act=zoom-out]').click(); return 'ok';")
check(eval("__t.q('.rm-zoom').textContent") == "40%", "zoom stops at 40%", eval("__t.q('.rm-zoom').textContent"))
_ = js("__t.q('[data-act=centre]').click(); return 'ok';")
let panBefore = json("return JSON.stringify(__t.view());")
_ = js("__t.panning(50, 20); return 'ok';")
let panAfter = json("return JSON.stringify(__t.view());")
check((panAfter["x"] as? Double ?? 0) - (panBefore["x"] as? Double ?? 0) == 50 && (panAfter["y"] as? Double ?? 0) - (panBefore["y"] as? Double ?? 0) == 20, "dragging the background pans the map", "\(panBefore) \(panAfter)")
spin(1.2)
let stored = json("return JSON.stringify(JSON.parse(localStorage.getItem('mvMap:2026-11-04-builds') || '{}'));")
check((stored["scale"] as? Double) == 1 && (stored["x"] as? Double) == panAfter["x"] as? Double && (stored["selected"] as? String) == "n5" && (stored["panel"] as? Double) == 320,
      "pan, zoom, panel width and selection are kept per map id in localStorage", "\(stored)")

// The panel divider.
let width0 = number("__t.q('.rm-panel').getBoundingClientRect().width")
check(width0 == 320, "the panel starts at 320px", "\(width0)")
_ = js("__t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true })); return 'ok';")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 340, "ArrowLeft on the divider widens the panel by 20")
_ = js("for (let i = 0; i < 40; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })); return 'ok';")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 240, "the panel is at least 240px")
_ = js("for (let i = 0; i < 60; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true })); return 'ok';")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 600, "the panel is at most 600px", eval("__t.q('.rm-panel').getBoundingClientRect().width"))
_ = js("""
const d = __t.q('.rm-divider'), r = d.getBoundingClientRect();
const f = function (type, x) { d.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 9, pointerType: 'mouse', button: 0, clientX: x, clientY: r.top + 40 })); };
f('pointerdown', r.left + 4); f('pointermove', r.left + 4 + 100); f('pointerup', r.left + 4 + 100);
return 'ok';
""")
check(number("__t.q('.rm-panel').getBoundingClientRect().width") == 500, "dragging the divider resizes the panel", eval("__t.q('.rm-panel').getBoundingClientRect().width"))
_ = js("__t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })); for (let i = 0; i < 9; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true })); return 'ok';")
_ = js("for (let i = 0; i < 9; i++) __t.q('.rm-divider').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true })); return 'ok';")

// ---- snapshots from Swift ----------------------------------------------------------------------------------------------------------------------
let titleBefore = eval("__t.q('.rm-heading strong').textContent")
let countBefore = number("document.querySelectorAll('.rm-node').length")
_ = js("window.mvResearchMapSet('some-other-tab', __t.snap({ title: 'Stale', nodes: [{ id: 'z1', parent: '', title: 'Stale root', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }] })); return 'ok';")
spin(0.2)
check(eval("__t.q('.rm-heading strong').textContent") == titleBefore && number("document.querySelectorAll('.rm-node').length") == countBefore, "a snapshot for another document is ignored")

deliver("{ notice: 'This connection already exists.' }")
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent") == "This connection already exists.", "a notice shows as a transient toast")
deliver()

deliver("{ nodes: (function () { const s = __t.snap(); s.nodes.push({ id: 'n13', parent: 'n3', title: 'Fresh node', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })(), created: 'n13' }")
check(bool("__t.btn('n13') !== null && __t.btn('n13').getAttribute('aria-pressed') === 'true'") && eval("__t.q('.rm-title-input').value") == "Fresh node", "the node an action created is selected")

// An unsolicited snapshot (an AI job adds nodes) keeps the view and what the person is typing.
_ = js("__t.select('n2'); return 'ok';")
// The mark goes before the typing: the page sends the typed text after its 300 ms pause, which on a slow machine can be
// before the lines below have run.
newMark()
_ = js("__t.q('[data-act=zoom-in]').click(); const d = __t.q('.rm-desc'); d.focus(); d.value = 'typing in progress'; d.dispatchEvent(new Event('input', { bubbles: true })); d.setSelectionRange(3, 5); return 'ok';")
let viewBefore = json("return JSON.stringify(Object.assign(__t.view(), { panel: __t.q('.rm-panel').getBoundingClientRect().width }));")
deliver("{ status: 'researching', job: { kind: 'develop', label: 'Developing', step: 'Adding nodes', startedAt: \(Int(Date().timeIntervalSince1970)) }, nodes: (function () { const s = __t.snap(); s.nodes.find(function (n) { return n.id === 'n2'; }).description = 'changed by the AI'; s.nodes.push({ id: 'n14', parent: 'n2', title: 'Added while typing', tags: [], color: '', description: '', layout: '', x: null, y: null, evidence: [] }); return s.nodes; })() }")
let keep = json("const d = __t.q('.rm-desc'); const v = __t.view(); return JSON.stringify({ active: document.activeElement === d, value: d.value, from: d.selectionStart, to: d.selectionEnd, selected: __t.btn('n2').getAttribute('aria-pressed'), nodes: document.querySelectorAll('.rm-node').length, scale: v.scale, vx: v.x, vy: v.y, panel: __t.q('.rm-panel').getBoundingClientRect().width });")
check((keep["active"] as? Bool) == true && (keep["value"] as? String) == "typing in progress" && (keep["from"] as? Int) == 3 && (keep["to"] as? Int) == 5, "an unsolicited snapshot does not overwrite the field being typed in, nor its caret", "\(keep)")
check((keep["selected"] as? String) == "true" && (keep["nodes"] as? Int) == 13, "…keeps the selection and adds the new node", "\(keep)")
check((keep["scale"] as? Double) == viewBefore["scale"] as? Double && (keep["vx"] as? Double) == viewBefore["x"] as? Double && (keep["vy"] as? Double) == viewBefore["y"] as? Double && (keep["panel"] as? Double) == viewBefore["panel"] as? Double, "…keeps pan, zoom and panel width", "\(keep) \(viewBefore)")
expect("the typed description is still sent", ["action": "update", "id": "n2", "description": "typing in progress"], doc: tabM)
_ = js("__t.q('.rm-desc').blur(); return 'ok';")
deliver()
check(eval("__t.q('.rm-desc').value") == "Notes on the dependency graph.", "once the field is left, the snapshot's text shows")

// ---- leaving and returning ---------------------------------------------------------------------------------------------------------------------
// Edits that wait for the pause are handed over before the document changes, under the old document's id.
newMark()
_ = js("__t.select('n2'); __t.type(__t.q('.rm-title-input'), 'Dependencies final'); window.mvSetDocument(window.__other = ids); return 'ok';", ["ids": tabN])
let handed = researchMessages().filter { ($0.payload["action"] as? String) == "update" }
check(handed.count == 1 && handed[0].doc == tabM && (handed[0].payload["title"] as? String) == "Dependencies final", "switching documents hands the waiting edit over, under the old document's id", describe(researchMessages()))
_ = js("window.mvSetDocument(old); return 'ok';", ["old": tabM])

newMark()
_ = js("__t.type(__t.q('.rm-title-input'), 'Dependencies again'); window.switchToSource(); return 'ok';")
let flushed = researchMessages().filter { ($0.payload["action"] as? String) == "update" }
check(flushed.count == 1 && flushed[0].doc == tabM && (flushed[0].payload["title"] as? String) == "Dependencies again", "leaving the map sends the waiting edit at once", describe(researchMessages()))
deliver()

// Map | View | Source (REQ-010): map -> Source (switch) -> top-bar toggle -> map.
newMark()
_ = js("window.setContent(text); return 'ok';", ["text": mapText])
check(visible("#research-map-container"), "loading the same document again shows the map")
check(number("document.querySelectorAll('.rm-node').length") == 12, "…with the nodes it had, at once (no blank map while Swift answers)", eval("document.querySelectorAll('.rm-node').length"))
expect("…and asks Swift for a fresh snapshot", ["action": "snapshot"], doc: tabM)
newMark()
_ = js("__t.q('.rm-toolbar [data-view=source]').click(); return 'ok';")
check(!visible("#research-map-container"), "Source in the switch leaves the map")
check(visible("#editor-pane") && !visible("#preview-pane"), "…and shows the Markdown source")
check(eval("document.getElementById('status-mode').textContent") == "Source", "…with Source in the status bar", eval("document.getElementById('status-mode').textContent"))
check(visible("#wysiwyg-toolbar") && visible("#wysiwyg-toolbar .mv-modes") && !visible("#mode-toggle"), "…and the top bar has the switch instead of the single mode label")
check(eval("__t.qa('#wysiwyg-toolbar [data-view]').map(function(b){return b.dataset.view + ':' + b.getAttribute('aria-pressed');}).join()") == "map:false,view:false,source:true", "…with Source marked", eval("__t.qa('#wysiwyg-toolbar [data-view]').map(function(b){return b.dataset.view + ':' + b.getAttribute('aria-pressed');}).join()"))
check(eval("document.getElementById('editor-input').value").contains("type: research-map"), "…the source is the document's text")
// In the Source view of the map document the text follows the file (an AI job adds nodes, another editor saves).
deliver("{ markdown: '---\\ntype: research-map\\n---\\n\\n## Map\\n\\n- [Changed elsewhere](#n1)\\n' }")
check(eval("document.getElementById('editor-input').value").contains("Changed elsewhere"), "a snapshot refreshes the Source text of the map document")
_ = js("const e = document.getElementById('editor-input'); e.value = e.value + ' typed'; return 'ok';")
deliver("{ markdown: '---\\ntype: research-map\\n---\\n\\n## Map\\n\\n- [Overwrites typing](#n1)\\n' }")
check(!eval("document.getElementById('editor-input').value").contains("Overwrites typing"), "…but not while the person is typing in it")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#research-map-container") && !visible("#editor-pane"), "the top-bar toggle (Source in the cycle) returns to the map")
expect("…and asks for the current snapshot", ["action": "snapshot"], doc: tabM)
check(eval("document.getElementById('status-mode').textContent") == "MAP", "…with MAP in the status bar")

newMark()
_ = js("window.switchToPreview(); return 'ok';")
check(!visible("#research-map-container") && visible("#preview-pane"), "Preview hides the map")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#editor-pane") && !visible("#research-map-container"), "Preview → toggle → Source")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#research-map-container"), "Source → toggle → back to the map")
_ = js("window.toggleSourceMode(); return 'ok';")
check(visible("#preview-pane") && !visible("#editor-pane") && !visible("#research-map-container"), "the shortcut cycle goes from the map to View (Swift's toggleSourceMode too)")
_ = js("window.toggleSourceMode(); return 'ok';")
check(visible("#editor-pane") && !visible("#research-map-container"), "…then to Source")
_ = js("window.toggleSourceMode(); return 'ok';")
check(visible("#research-map-container"), "…and back to the map")

// The switch itself (REQ-010).
check(eval("__t.qa('.rm-toolbar [data-view]').map(function(b){return b.textContent + ':' + b.getAttribute('aria-pressed');}).join()") == "Map:true,View:false,Source:false", "the map toolbar has Map | View | Source with Map marked", eval("__t.qa('.rm-toolbar [data-view]').map(function(b){return b.textContent + ':' + b.getAttribute('aria-pressed');}).join()"))
check(!visible("[data-act=source]"), "the lone Source button is gone")
// A trip through View and Source and back keeps the map as it was and leaves the text alone.
_ = js("window.setContent(text); return 'ok';", ["text": mapText])
deliver()
_ = js("__t.select('n3'); __t.fold('n2').click(); __t.q('[data-act=zoom-in]').click(); return 'ok';")
let beforeTrip = json("const v = window.MVResearchMap.viewState(); return JSON.stringify({ scale: v.scale, x: v.x, y: v.y, selected: v.selected, collapsed: window.MVResearchMap.collapsed(), text: document.getElementById('editor-input').value });")
check((beforeTrip["text"] as? String) == mapText, "the document text is the file's text while the map is shown", "\(beforeTrip["text"] ?? "")")
newMark()
_ = js("__t.q('.rm-toolbar [data-view=view]').click(); return 'ok';")
check(visible("#preview-pane") && !visible("#editor-pane") && !visible("#research-map-container"), "View shows the file as ordinary Markdown")
check(eval("document.getElementById('editor-rendered').innerText").contains("Why do builds get slow?"), "…the rendered page holds the map's text")
check(eval("document.getElementById('editor-rendered').contentEditable") == "false", "…and is not edited (the page's converter cannot write a map file back)")
check(visible("#wysiwyg-toolbar .mv-modes") && !visible("#mode-toggle") && eval("__t.qa('#wysiwyg-toolbar [data-view]').map(function(b){return b.getAttribute('aria-pressed');}).join()") == "false,true,false", "…the top bar has the switch with View marked")
check(!visible("#wysiwyg-toolbar > button[onclick^=fmt]"), "…and no formatting buttons")
_ = js("__t.q('#wysiwyg-toolbar [data-view=source]').click(); return 'ok';")
check(visible("#editor-pane") && !visible("#preview-pane") && eval("document.getElementById('editor-input').value") == mapText, "Source from View shows the same text")
check(eval("document.getElementById('editor-rendered').contentEditable") == "true", "…and ordinary editing is back")
_ = js("__t.q('#wysiwyg-toolbar [data-view=map]').click(); return 'ok';")
check(visible("#research-map-container") && !visible("#editor-pane"), "Map in the top bar returns to the map")
expect("…and asks for the current snapshot", ["action": "snapshot"], doc: tabM)
let afterTrip = json("const v = window.MVResearchMap.viewState(); return JSON.stringify({ scale: v.scale, x: v.x, y: v.y, selected: v.selected, collapsed: window.MVResearchMap.collapsed(), text: document.getElementById('editor-input').value });")
check((afterTrip["scale"] as? Double) == (beforeTrip["scale"] as? Double) && (afterTrip["x"] as? Double) == (beforeTrip["x"] as? Double) && (afterTrip["y"] as? Double) == (beforeTrip["y"] as? Double) && (afterTrip["selected"] as? String) == (beforeTrip["selected"] as? String) && "\(afterTrip["collapsed"] ?? "")" == "\(beforeTrip["collapsed"] ?? "")",
      "zoom, position, selection and folds survive the trip", "\(beforeTrip) -> \(afterTrip)")
check((afterTrip["text"] as? String) == mapText, "…and the text is byte for byte the file's text")
expectNone("…and nothing was written to the map", action: "update", wait: 0.3)
// Another kind of document has no switch, only its own mode label.
_ = js("window.mvSetDocument(id); window.setContent('# Plain notes'); return 'ok';", ["id": tabP])
check(visible("#mode-toggle") && !visible("#wysiwyg-toolbar .mv-modes"), "an ordinary document keeps the single mode label and has no switch")
_ = js("window.toggleModeWrapper(); return 'ok';")
check(visible("#editor-pane") && !visible("#preview-pane"), "…and its toggle still flips Preview and Source")
_ = js("window.mvSetDocument(id); window.setContent(text); return 'ok';", ["id": tabM, "text": mapText])
deliver()

// A text that is no longer a research map does not come back as one.
_ = js("window.switchToSource(); document.getElementById('editor-input').value = '# Just notes'; window.toggleModeWrapper(); return 'ok';")
check(!visible("#research-map-container") && visible("#preview-pane"), "a Source text without the research-map front matter toggles to the preview, not the map")

// A problem snapshot: a one-line notice and the Source view.
newMark()
_ = js("window.setContent(text); return 'ok';", ["text": mapText])
deliver("{ ok: false, problem: 'The file has no \"## Map\" list.' }")
check(!visible("#research-map-container") && visible("#editor-pane"), "a snapshot with ok false falls back to the Source view")
check(visible("#research-map-problem") && eval("document.getElementById('research-map-problem').textContent").contains("The file has no \"## Map\" list."), "…with a one-line notice giving the reason", eval("document.getElementById('research-map-problem').textContent"))
_ = js("window.mvSetDocument(id); window.setContent('# Plain again'); return 'ok';", ["id": tabP])
check(!visible("#research-map-problem") && !visible("#research-map-container") && visible("#preview-pane"), "a plain document clears the notice and leaves the map")
check(eval("document.getElementById('status-mode').textContent") == "WYSIWYG", "…and the usual status text returns")

// Other views take over.
check(loadDocument(tabM, mapText) == "ok" && visible("#research-map-container"), "back on the map document")
deliver()
// ---- an arrow on each node moves it under another parent; a logical connection is removed from its line (REQ-015, DEC-016) --------
_ = js("""
const q = function (s) { return document.querySelector(s); };
const fire = function (type, target, x, y) {
  return target.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, pointerId: 9, pointerType: 'mouse', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: x, clientY: y }));
};
const centre = function (e) { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; };
Object.assign(window.__t, {
  arrow: function (id) { return q('.rm-node-wrap[data-id="' + id + '"] .rm-arrow'); },
  connectStart: function (id) { const a = this.arrow(id), c = centre(a); window.__link = { el: a, x: c.x, y: c.y }; fire('pointerdown', a, c.x, c.y); },
  connectTo: function (id) { const c = centre(this.btn(id)); fire('pointermove', this.btn(id), c.x, c.y); },
  connectToEmpty: function () { const v = q('.rm-viewport'), r = v.getBoundingClientRect(); fire('pointermove', v, r.left + 6, r.bottom - 6); },
  connectEnd: function (id) { const t = id ? this.btn(id) : q('.rm-viewport'), c = id ? centre(t) : { x: t.getBoundingClientRect().left + 6, y: t.getBoundingClientRect().bottom - 6 }; fire('pointerup', t, c.x, c.y); },
  hit: function (from, to) { return q('path[data-line="link-hit"][data-from="' + from + '"][data-to="' + to + '"]'); },
  hitClick: function (from, to) { const h = this.hit(from, to), c = centre(h); fire('pointerdown', h, c.x, c.y); fire('pointerup', h, c.x, c.y); }
});
return 'installed';
""")
deliver()
// Every node shown, the map centred at 100%, so that every node can be reached by the pointer.
_ = js("__t.q('[data-act=expand-all]').click(); __t.q('[data-act=centre]').click(); __t.select('n3'); __t.panning(-300, 0); return 'ok';")
spin(0.3)
check(number("document.querySelectorAll('.rm-arrow').length") == 12, "every node has an arrow")
check(bool("__t.qa('.rm-node-wrap').every(function (w) { return w.querySelector('.rm-arrow').parentNode === w; })"), "…inside its own node")
check(bool("__t.wrap('n3').classList.contains('arrow-left') === (__t.pos('n3').x < __t.pos('n1').x) && __t.wrap('n2').classList.contains('arrow-left') === (__t.pos('n2').x < __t.pos('n1').x)"), "the arrow sits on the outer edge: left for a node left of its parent, right otherwise")
check(bool("__t.qa('.rm-node-wrap').some(function (w) { return w.classList.contains('arrow-left'); }) && __t.qa('.rm-node-wrap').some(function (w) { return !w.classList.contains('arrow-left'); })"), "…both kinds occur on a balanced map")
check(bool("__t.wrap('n1').classList.contains('arrow-left') === false"), "the root's arrow is on the right")
check(bool("(function(){ const a = __t.arrow('n2').getBoundingClientRect(), b = __t.btn('n2').getBoundingClientRect(); return a.left >= b.right || a.right <= b.left; })()"), "the arrow lies outside the node, clear of the menu button and the fold toggle")

// A drag from the arrow of n2 over n4: the line follows the pointer and n4 is marked as a valid target.
newMark()
let mapViewBefore = js("return JSON.stringify(__t.view());")
_ = js("__t.connectStart('n2'); __t.connectTo('n4'); return 'ok';")
check(bool("document.querySelector('.rm-viewport').classList.contains('is-connecting')") && number("document.querySelectorAll('path[data-line=connect]').length") == 1, "dragging the arrow draws a line from the node to the pointer")
check(bool("__t.wrap('n4').classList.contains('connect-ok')") && bool("__t.wrap('n2').classList.contains('connect-from')"), "…marks the node under the pointer as a valid target, and the node it starts from")
_ = js("__t.connectTo('n6'); return 'ok';")
check(bool("__t.wrap('n6').classList.contains('connect-no') && !__t.wrap('n4').classList.contains('connect-ok')"), "a node that is already a child of this one is marked as not allowed")
_ = js("__t.connectTo('n2'); return 'ok';")
check(bool("__t.wrap('n2').classList.contains('connect-no')"), "so is the node itself")
_ = js("__t.connectTo('n1'); return 'ok';")
check(bool("__t.wrap('n1').classList.contains('connect-no')"), "…and the root")
expectNone("nothing is sent while the arrow moves", action: "move", wait: 0.3)
_ = js("__t.connectTo('n4'); return 'ok';")
_ = js("__t.connectEnd('n4'); return 'ok';")
expect("releasing on n4 sends one move: n4 goes under n2", ["action": "move", "id": "n4", "parent": "n2"], doc: tabM)
check(!bool("document.querySelector('.rm-viewport').classList.contains('is-connecting')") && number("document.querySelectorAll('path[data-line=connect]').length") == 0 && number("document.querySelectorAll('.connect-ok, .connect-no, .connect-from').length") == 0, "the line and the marks are gone afterwards")
check(js("return JSON.stringify(__t.view());") == mapViewBefore, "…and the map did not pan")
expectNone("the node itself is not moved on the canvas", action: "moveVisual", wait: 0.2)

// Refusals: a toast and no message.
func refused(_ name: String, from: String, to: String, toast text: String) {
    newMark()
    _ = js("__t.connectStart('\(from)'); __t.connectTo('\(to)'); __t.connectEnd('\(to)'); return 'ok';")
    expectNone(name + ": nothing is sent", action: "move", wait: 0.3)
    check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent").contains(text), name + ": a toast says why", eval("__t.q('.rm-toast').textContent"))
}
refused("onto its own child", from: "n2", to: "n6", toast: "already the parent")
refused("onto itself", from: "n2", to: "n2", toast: "its own child")
refused("onto the root", from: "n2", to: "n1", toast: "root")
refused("onto an ancestor", from: "n6", to: "n2", toast: "descendants")

// Cancel: Esc, empty canvas, a click without movement.
newMark()
_ = js("__t.connectStart('n2'); __t.connectTo('n4'); window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); __t.connectEnd('n4'); return 'ok';")
expectNone("Esc during the drag cancels it", action: "move", wait: 0.3)
check(number("document.querySelectorAll('path[data-line=connect]').length") == 0 && number("document.querySelectorAll('.connect-ok, .connect-no, .connect-from').length") == 0, "…and clears the line and the marks")
_ = js("__t.connectStart('n2'); __t.connectTo('n4'); __t.connectToEmpty(); __t.connectEnd(''); return 'ok';")
expectNone("releasing on the empty canvas changes nothing", action: "move", wait: 0.3)
_ = js("__t.connectStart('n2'); __t.connectEnd('n2'); return 'ok';")
expectNone("a click on the arrow without movement changes nothing", action: "move", wait: 0.3)
expectNone("…nor does any of it send anything else", action: "unlink", wait: 0.1)

// Logical connections: a wide invisible line, selected by a click, removed by the cross or the Delete key.
check(number("document.querySelectorAll('path[data-line=link-hit]').length") == 2 && number("document.querySelectorAll('path[data-line=link]').length") == 2, "every logical connection has an invisible hit line over it")
check(number("document.querySelectorAll('path[data-line=link-hit]').length") == number("document.querySelectorAll('path[data-line=link]').length") && bool("getComputedStyle(__t.hit('n6', 'n8')).pointerEvents !== 'none' && parseFloat(getComputedStyle(__t.hit('n6', 'n8')).strokeWidth) >= 10"), "…at least ten pixels wide and able to take the pointer")
check(bool("__t.qa('path[data-line=tree]').length === 11 && __t.qa('path[data-line=tree]').every(function (p) { return getComputedStyle(p).pointerEvents === 'none'; })"), "the hierarchy lines take no pointer at all: they cannot be selected or removed")
check(number("document.querySelectorAll('.rm-linkx').length") == 0, "no cross before a connection is chosen")
newMark()
_ = js("__t.hitClick('n6', 'n8'); return 'ok';")
check(number("document.querySelectorAll('.rm-linkx').length") == 1 && eval("__t.q('.rm-linkx').dataset.from + '>' + __t.q('.rm-linkx').dataset.to") == "n6>n8", "a click on the connection shows a cross on it")
check(bool("(function(){ const x = __t.q('.rm-linkx'), a = __t.pos('n6'), b = __t.pos('n8'); return Math.abs(parseFloat(x.style.left) - (a.x + b.x) / 2) <= 1 && Math.abs(parseFloat(x.style.top) - (a.y + b.y) / 2) <= 1; })()"), "…in the middle of the line")
check(bool("__t.q('path[data-line=link][stroke-width=\"2.5\"]') !== null") && number("document.querySelectorAll('.rm-node-wrap.selected').length") == 0, "the chosen line is drawn heavier, and no node stays selected")
expectNone("choosing a connection sends nothing", action: "unlink", wait: 0.2)
_ = js("__t.q('.rm-linkx').click(); return 'ok';")
expect("the cross removes the connection", ["action": "unlink", "from": "n6", "to": "n8"], doc: tabM)
deliver("{ links: [{ from: 'n2', to: 'n5' }] }")
check(number("document.querySelectorAll('.rm-linkx').length") == 0 && number("document.querySelectorAll('path[data-line=link-hit]').length") == 1, "once the snapshot drops it, the line and the cross are gone")
newMark()
_ = js("__t.hitClick('n2', 'n5'); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true, cancelable: true })); return 'ok';")
expect("the Delete key removes the chosen connection", ["action": "unlink", "from": "n2", "to": "n5"], doc: tabM)
deliver()
newMark()
_ = js("__t.hitClick('n6', 'n8'); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); return 'ok';")
check(number("document.querySelectorAll('.rm-linkx').length") == 0, "Esc lets go of the connection")
_ = js("__t.hitClick('n6', 'n8'); __t.select('n3'); return 'ok';")
check(number("document.querySelectorAll('.rm-linkx').length") == 0 && number("document.querySelectorAll('.rm-node-wrap.selected').length") == 1, "choosing a node lets go of the connection")
_ = js("__t.hitClick('n6', 'n8'); __t.panning(0, 0); return 'ok';")
check(number("document.querySelectorAll('.rm-linkx').length") == 0, "a click on the empty canvas lets go of it too")
_ = js("__t.hitClick('n6', 'n8'); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true, cancelable: true })); return 'ok';")
expect("Backspace removes it as well", ["action": "unlink", "from": "n6", "to": "n8"], doc: tabM)
deliver()
expectNone("none of this ever sends a delete of a node", action: "delete", wait: 0.2)
check(js("return JSON.stringify(__t.view());") == mapViewBefore, "the map was not panned or zoomed by any of it")

// ---- a picture on a node, beside its icon (REQ-017, DEC-018) ---------------------------------------------------------------------------------------
let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
_ = js("""
Object.assign(window.__t, {
  withPicture: function (id, extra) { const s = this.snap(); s.nodes.forEach(function (n) { if (n.id === id) Object.assign(n, extra); }); window.mvResearchMapSet(window.mvDocumentId, s); },
  file: function (name, type, bytes) { const dt = new DataTransfer(); dt.items.add(new File([new Uint8Array(bytes)], name, { type: type })); return dt; },
  choose: function (dt) { const input = document.querySelector('.rm-dropzone input[type=file]'); input.files = dt.files; input.dispatchEvent(new Event('change', { bubbles: true })); },
  dropOn: function (id, dt) { const target = id ? this.btn(id) : document.querySelector('.rm-viewport'); const e = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }); target.dispatchEvent(e); return e.defaultPrevented; },
  overNode: function (id, dt) { const e = new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }); this.btn(id).dispatchEvent(e); return e.defaultPrevented; }
});
return 'installed';
""")
_ = js("__t.withPicture('n2', { image: 'data:image/png;base64,\(tinyPNG)', icon: '🔥' }); return 'ok';")
spin(0.4)
check(bool("!__t.q('.rm-node-wrap[data-id=n2] .rm-thumb').hidden"), "a node with a picture shows a thumbnail on its card")
check(bool("(function(){ const lead = __t.q('.rm-node-wrap[data-id=n2] .rm-lead'); return !lead.hidden && lead.contains(__t.q('.rm-node-wrap[data-id=n2] .rm-glyph')) && lead.contains(__t.q('.rm-node-wrap[data-id=n2] .rm-thumb')) && !__t.q('.rm-node-wrap[data-id=n2] .rm-glyph').hidden; })()"), "…beside its icon, which stays")
check(bool("(function(){ const w = __t.q('.rm-node-wrap[data-id=n2] .rm-thumb').getBoundingClientRect(); return w.width >= 24 && w.width <= 40 && w.height >= 24 && w.height <= 40; })()"), "…small enough to sit before the title")
check(bool("__t.q('.rm-node-wrap[data-id=n3] .rm-thumb').hidden && __t.q('.rm-node-wrap[data-id=n3] .rm-lead').hidden"), "a node without a picture shows none and keeps no gap")
check(eval("__t.btn('n2').getAttribute('aria-label')").contains("With a picture."), "…and the picture is announced")
_ = js("__t.select('n2'); return 'ok';")
check(bool("!__t.q('.rm-picture-thumb').hidden && !__t.q('[data-act=image-clear]').hidden"), "the panel shows the picture of the selected node and a cross")
newMark()
_ = js("__t.q('[data-act=image-clear]').click(); return 'ok';")
expect("the cross removes the picture with one update", ["action": "update", "id": "n2", "image": ""], doc: tabM)
deliver()
_ = js("__t.select('n3'); return 'ok';")
check(bool("__t.q('.rm-picture-thumb').hidden && __t.q('[data-act=image-clear]').hidden") && eval("__t.q('[data-act=image] span').textContent") == "None", "a node without a picture says None and has no cross")

// The dialog: choose, paste, drop; refusals stay in the dialog.
_ = js("__t.menu('n3'); __t.act('image'); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog h2').textContent") == "Picture for “Compiler”" && number("document.querySelectorAll('.rm-dropzone').length") == 1, "Image… in the node menu opens the picture dialog")
check(number("document.querySelectorAll('.rm-dialog-actions button').length") == 1, "…with no Remove button while the node has no picture")
newMark()
_ = js("__t.choose(__t.file('notes.txt', 'text/plain', [104, 105])); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog .rm-error').textContent") == "Use a PNG, JPEG, GIF or WebP picture.", "a file of another kind is refused in the dialog")
_ = js("const big = new File([new Uint8Array(6000001)], 'big.png', { type: 'image/png' }); const dt = new DataTransfer(); dt.items.add(big); __t.choose(dt); return 'ok';")
check(visible(".rm-dialog") && eval("__t.q('.rm-dialog .rm-error').textContent") == "The picture is larger than 6 MB.", "a picture over 6 MB is refused in the dialog")
spin(0.3)
let pngBytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]
let pngBase64 = Data(pngBytes).base64EncodedString()
expectNone("nothing was sent for the refused files", action: "attachImage", wait: 0.2)
_ = js("__t.choose(__t.file('shot.png', 'image/png', [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4])); return 'ok';")
expect("a chosen picture is sent whole, with its name, for this node", ["action": "attachImage", "id": "n3", "name": "shot.png", "data": pngBase64], doc: tabM)
check(!visible(".rm-dialog"), "…and the dialog closes")
newMark()
_ = js("__t.menu('n3'); __t.act('image'); const dt = __t.file('pasted.png', 'image/png', [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]); __t.q('.rm-dialog').dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt })); return 'ok';")
expect("a pasted picture is sent the same way", ["action": "attachImage", "id": "n3", "name": "pasted.png", "data": pngBase64], doc: tabM)
newMark()
_ = js("__t.menu('n3'); __t.act('image'); const z = __t.q('.rm-dropzone'); const dt = __t.file('dropped.png', 'image/png', [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]); z.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt })); return 'ok';")
expect("a picture dropped in the dialog is sent too", ["action": "attachImage", "id": "n3", "name": "dropped.png", "data": pngBase64], doc: tabM)

// Dropped on a node of the canvas.
newMark()
check(bool("__t.overNode('n4', __t.file('x.png', 'image/png', [1]))") && bool("__t.wrap('n4').classList.contains('picture-drop')"), "a file dragged over a node marks it as the target")
check(bool("__t.dropOn('n4', __t.file('canvas.png', 'image/png', [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]))"), "…and the drop is taken (the page does not navigate to the file)")
expect("a picture dropped on a node is sent for that node", ["action": "attachImage", "id": "n4", "name": "canvas.png", "data": pngBase64], doc: tabM)
check(!bool("__t.wrap('n4').classList.contains('picture-drop')"), "the mark is gone after the drop")
newMark()
_ = js("__t.dropOn('', __t.file('empty.png', 'image/png', [1, 2])); return 'ok';")
expectNone("a drop on the empty canvas is left alone", action: "attachImage", wait: 0.3)
_ = js("__t.dropOn('n4', __t.file('doc.txt', 'text/plain', [1, 2])); return 'ok';")
expectNone("a file of another kind dropped on a node sends nothing", action: "attachImage", wait: 0.3)
check(visible(".rm-toast") && eval("__t.q('.rm-toast').textContent") == "Use a PNG, JPEG, GIF or WebP picture.", "…and a toast says why")

// A node that has a picture: the dialog previews it and offers Remove.
_ = js("__t.withPicture('n3', { image: 'data:image/png;base64,\(tinyPNG)' }); __t.menu('n3'); __t.act('image'); return 'ok';")
spin(0.3)
check(bool("!__t.q('.rm-picture-preview').hidden") && number("document.querySelectorAll('.rm-dialog-actions button').length") == 2, "the dialog previews the current picture and offers Remove picture")
newMark()
_ = js("__t.dialogButton('Remove picture'); return 'ok';")
expect("Remove picture sends the same update as the cross", ["action": "update", "id": "n3", "image": ""], doc: tabM)
deliver()
check(number("document.querySelectorAll('.rm-thumb:not([hidden])').length") == 0, "a snapshot without pictures leaves no thumbnail")

_ = js("window.setStructuredContent('{\"a\": 1}', 'json'); return 'ok';")
check(!visible("#research-map-container"), "structured content leaves the map")
check(loadDocument(tabM, mapText) == "ok" && visible("#research-map-container"), "the map comes back with its document")
_ = js("window.leaveResearchMap(); return 'ok';")
check(!visible("#research-map-container"), "window.leaveResearchMap hides the map")

// A second map keeps its own view state.
let firstBefore = js("return localStorage.getItem('mvMap:2026-11-04-builds') || '';")
let secondText = mapText.replacingOccurrences(of: "2026-11-04-builds", with: "2026-11-05-other")
check(loadDocument(tabN, secondText) == "ok" && visible("#research-map-container"), "a second map document loads")
check(number("document.querySelectorAll('.rm-node').length") == 0, "…and starts empty, not with the first map's nodes")
deliver("{ id: '2026-11-05-other', title: 'Other map', question: 'Other?' }")
check(eval("__t.q('.rm-heading strong').textContent") == "Other map" && eval("__t.q('.rm-zoom').textContent") == "100%", "…with its own title and a fresh view")
_ = js("__t.q('[data-act=zoom-in]').click(); return 'ok';")
spin(1.0)
let keys = js("return Object.keys(localStorage).filter(function (k) { return k.indexOf('mvMap:') === 0; }).sort().join();")
check(keys == "mvMap:2026-11-04-builds,mvMap:2026-11-05-other", "each map keeps its own view under its own key", keys)
let secondStored = json("return JSON.stringify(JSON.parse(localStorage.getItem('mvMap:2026-11-05-other') || '{}'));")
let firstAfter = js("return localStorage.getItem('mvMap:2026-11-04-builds') || '';")
check((secondStored["scale"] as? Double) == 1.2 && !firstBefore.isEmpty && firstBefore == firstAfter, "…and zooming the second map did not touch the first", "\(firstBefore) | \(firstAfter) | \(secondStored)")

// ---- no errors anywhere -----------------------------------------------------------------------------------------------------------------------------
spin(0.5)
let errors = js("return JSON.stringify(window.__errors.slice(\(baselineErrors)));")
check(errors == "[]", "no error or unhandledrejection event in the page since the test began", errors)
let reported = Array(bridge.messages.filter { $0.type == "jsError" }.dropFirst(baselineReports))
check(reported.isEmpty, "the page reported no jsError to Swift since the test began", reported.map { String(describing: $0.payload["message"] ?? "") }.joined(separator: " | "))


    }
}
