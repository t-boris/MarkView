// Checks the narrative report of a research map (MarkView/Models/ResearchMapReport.swift) against REQ-013 and DEC-014:
// the request, the reading of the answer, the guards that do not depend on the model, and the assembly.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
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

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
