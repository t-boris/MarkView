import Foundation

/// The narrative report of a research map (feature mind-map, REQ-013, DEC-014). The model writes the prose; this
/// module does everything that has to be exact, so the result does not depend on which model wrote it:
///
///  - `prompt` gives the model the map (every node id, the evidence and its numbered sources) and the answer format;
///  - `parse` reads the model's JSON answer;
///  - `check` finds what is wrong with it (a node not covered, a citation or a path or a link that is not in the map, a
///    node-by-node list instead of a story, a broken placeholder, HTML) and `repairPrompt` turns that into the next
///    request (the job allows two repair rounds);
///  - `assemble` expands the placeholders (the map's own diagrams and images, new diagrams the Graph Creator's
///    generator made), builds the Sources list from the evidence of the map and returns the final Markdown.
///
/// Pure (Foundation and ResearchMapDocument), so `tools/tests` can compile it alone.
enum ResearchMapReport {
    // MARK: Limits

    /// At most this many new diagrams can be requested for one report.
    static let maxDiagrams = 8
    static let minSections = 3
    /// The diagram kinds a request may name; they are the raw values of `DiagramKind` (DiagramAI.swift).
    static let diagramKinds = ["sequence", "flowchart", "dataflow", "architecture", "er", "deployment", "pipeline"]
    /// Lists must not carry more than this share of the prose (by characters), once they are longer than `listCharsFloor`.
    static let maxListShare = 0.5
    static let listCharsFloor = 300
    /// A map of at least `outlineMinHeadings` nodes is a node-by-node outline when the report has at least
    /// `max(outlineMinHeadings, outlineHeadingRatio × nodes)` headings (sections and the headings inside them).
    static let outlineMinHeadings = 7
    static let outlineHeadingRatio = 0.6
    /// A section with less prose than this is thin; more than `max(1, sections / 4)` thin sections is a list in disguise.
    static let thinSectionChars = 100
    /// The prose of the whole report is at least `min(proseCharsCap, proseCharsPerNode × nodes)` characters.
    static let proseCharsPerNode = 40
    static let proseCharsCap = 4000
    /// Longest description and evidence text given to the model.
    static let descriptionCap = 1200
    static let evidenceCap = 300
    static let maxListedIDs = 40

    // MARK: Types

    /// One numbered source of the report: a web address, or a project file (all the evidence that cites one of its lines).
    struct Source: Equatable {
        var number: Int
        /// A web address, or a project path without its `:line` suffix.
        var location: String
        var isWeb: Bool
        /// The lines or ranges the evidence names (`61`, `10-20`), ascending and without repeats.
        var lines: [String]
        /// The label of each piece of evidence that cites this source, in map order.
        var labels: [ResearchMap.Label]
    }

    struct Draft: Equatable {
        struct Section: Equatable {
            var heading: String
            var markdown: String
            /// The ids of the nodes the section accounts for.
            var covers: [String]
        }
        struct Diagram: Equatable {
            /// `d1`, `d2` …; placed in a section with `{{diagram:d1}}`.
            var id: String
            /// One of `diagramKinds`.
            var kind: String
            /// What the diagram must show; the generator's prompt.
            var what: String
        }
        var title: String
        var sections: [Section]
        var diagrams: [Diagram]
        /// The heading of the Sources list in the report's language (empty: "Sources").
        var sourcesHeading = ""
    }

    enum Failure: Error, Equatable {
        /// No JSON object with a `sections` list was found in the answer.
        case noJSON
        /// A JSON object was found, but a part of it has the wrong shape.
        case malformed(String)

        var message: String {
            switch self {
            case .noJSON: return "The answer contained no JSON object with a \"sections\" list."
            case .malformed(let why): return "The JSON answer has the wrong shape: \(why)"
            }
        }
    }

    struct Problem: Equatable {
        enum Code: String {
            case structure, missingNodes, unknownNodes, badCitation, badPlaceholder, badNodePlaceholder
            case badDiagramRequest, tooManyDiagrams, diagramNotPlaced, diagramPlacedTwice
            case nodeList, headingPerNode, thinProse, tooShort
            case unsafe, invented, rawDiagram, rawImage
        }
        var code: Code
        /// Written for the model: says what is wrong and what to do.
        var message: String
    }

    struct Assembled: Equatable {
        var markdown: String
        /// Requested diagrams that were not supplied (the generator failed) or that failed the safety scan: left out.
        var droppedDiagrams: [String]
        /// Visual nodes of the map whose diagram or image could not be read from their description: left out.
        var emptyVisuals: [String]
    }

    // MARK: Sources

    /// The numbered sources of the map: the distinct web addresses and project files its evidence cites, numbered in
    /// map order. Citations in the report (`[3]`) refer to these numbers.
    static func sources(of map: ResearchMap) -> [Source] {
        var list: [Source] = []
        var index: [String: Int] = [:]
        for node in map.nodes {
            for item in node.evidence {
                let parts = splitSource(item.source)
                guard !parts.location.isEmpty else { continue }
                let at: Int
                if let known = index[parts.location] {
                    at = known
                } else {
                    at = list.count
                    index[parts.location] = at
                    list.append(Source(number: at + 1, location: parts.location, isWeb: parts.isWeb, lines: [], labels: []))
                }
                if let line = parts.lines, !list[at].lines.contains(line) { list[at].lines.append(line) }
                list[at].labels.append(item.label)
            }
        }
        for i in list.indices {
            // Lines read in ascending order, however the evidence is spread over the map.
            list[i].lines.sort { (Int($0.prefix { $0.isNumber }) ?? 0) < (Int($1.prefix { $0.isNumber }) ?? 0) }
        }
        return list
    }

    /// A source as the evidence stores it: a web address, or `path`, `path:61`, `path:10-20`.
    static func splitSource(_ source: String) -> (location: String, lines: String?, isWeb: Bool) {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") { return (text, nil, true) }
        if let range = text.range(of: #":\d+(-\d+)?$"#, options: .regularExpression) {
            return (String(text[..<range.lowerBound]), String(text[text.index(after: range.lowerBound)...]), false)
        }
        return (text, nil, false)
    }

    // MARK: The request

    /// The system prompt and the user prompt for the model. `language` is the language the person chose at export time
    /// ("English", "Русский" …); nil or empty: the report follows the language of the map's question.
    static func prompt(map: ResearchMap, mapName: String, language: String? = nil) -> (system: String, user: String) {
        (systemPrompt(language: language), userPrompt(map: map, mapName: mapName))
    }

    /// The instruction that fixes the language of the report.
    static func languageInstruction(_ language: String?) -> String {
        let name = oneLine(language ?? "")
        guard !name.isEmpty else { return "Write the whole report in the language of the question." }
        return "Write the whole report in \(name): the title, the section headings, the text and the heading of the Sources list. Keep node titles you quote, file paths, web addresses, Mermaid code and code identifiers exactly as they are; do not translate them."
    }

    static func systemPrompt(language: String?) -> String {
        var lines = [
            "You write a report from a research map. The map is the researcher's working structure: a tree of nodes with descriptions and evidence. The report is a document the researcher will share with people who have never seen the map.",
            "",
            "Write a narrative: connected prose that tells what was asked, what was found, how the findings fit together, what follows from them and what is still open.",
            "- Start with an introduction: the question and the answer in brief.",
            "- Then sections that follow the logic of the map's branches. A section groups related nodes into one story; it is not one heading per node.",
            "- Finish with the conclusions and with the open questions and assumptions.",
            "- Say how sure each claim is: facts come from the project or from external sources, inferences and open assumptions are said to be inferences and assumptions.",
            "",
            "NEVER write a node-by-node outline or a bullet per node. Do not mirror the tree. Paragraphs are the default; use a list only where the content is a real list (steps, options, a short set of criteria). Do not write node ids or the word \"node\" in the text.",
            "Every node of the map must be accounted for: its content is told in the section that covers it, and the section names it in \"covers\". A node that only supports a larger point is still listed in \"covers\" of the section that tells that point. Every node id must appear in the \"covers\" of at least one section.",
            "",
            "Sources: the user message numbers the sources of the map ([1], [2] …). Cite a claim by writing its number in square brackets after it, for example \"The vocabulary has ten values [3].\" Cite only numbers from that list. Never invent a source, a file path or a web address; mention only files and addresses that appear in the map.",
            "",
            "Pictures: some nodes are diagram or image nodes. Put one where it belongs by writing {{node:ID}} on a line of its own. Use it only for nodes marked as diagram or image nodes. Do not write Mermaid blocks, images or HTML yourself.",
            "Where a new diagram would help the reader (a process, a flow of decisions, a set of components), request it: add it to \"diagrams\" with an id (d1, d2 …), a kind and what it must show, and write {{diagram:d1}} on a line of its own where it belongs. At most \(maxDiagrams) diagrams, and only where they really help. Kinds: \(diagramKinds.joined(separator: ", ")). Place every requested diagram exactly once.",
            "Wrap code, file names and paths in backticks. Use no HTML.",
            "",
            "Answer with one JSON object and nothing else:",
            "{\"title\": \"report title\",",
            " \"sections\": [{\"heading\": \"...\", \"markdown\": \"...\", \"covers\": [\"n1\", \"n2\"]}],",
            " \"diagrams\": [{\"id\": \"d1\", \"kind\": \"flowchart\", \"what\": \"...\"}],",
            " \"sourcesHeading\": \"the word for Sources in the report's language\"}",
            "\"markdown\" is the text of the section without its heading. \"diagrams\" may be empty.",
        ]
        lines.append("")
        lines.append(languageInstruction(language))
        return lines.joined(separator: "\n")
    }

    static func userPrompt(map: ResearchMap, mapName: String) -> String {
        let all = sources(of: map)
        var numbers: [String: Int] = [:]
        for source in all { numbers[source.location] = source.number }
        var out: [String] = []
        out.append("MAP FILE: \(mapName)")
        out.append("STATUS: \(map.status.rawValue)" + (map.status == .incomplete && !map.incompleteReason.isEmpty ? " (\(oneLine(map.incompleteReason)))" : ""))
        if map.status != .complete { out.append("The research is not complete: say so in the report and what it means for the conclusions.") }
        out.append("NODES: \(map.nodes.count)")
        out.append("")
        out.append("QUESTION:")
        out.append(map.question.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("")
        out.append("SOURCES (cite by number):")
        if all.isEmpty { out.append("(none: the map cites no file or web address, so write no citations)") }
        for source in all {
            let lines = source.lines.isEmpty ? "" : " (lines " + source.lines.joined(separator: ", ") + ")"
            out.append("[\(source.number)] \(source.location)\(lines)")
        }
        out.append("")
        out.append("NODES, parents first:")
        for node in map.nodes {
            out.append("")
            out.append(nodeHeader(node))
            let description = describedText(node)
            if !description.isEmpty { out.append("  description: " + cap(description, descriptionCap)) }
            if !node.evidence.isEmpty { out.append("  evidence:") }
            for item in node.evidence {
                let parts = splitSource(item.source)
                let cite = numbers[parts.location].map { " [source \($0)]" } ?? ""
                out.append("    - [\(item.label.rawValue)] \(cap(oneLine(item.text), evidenceCap))\(cite)")
            }
        }
        let links = map.links.compactMap { link -> String? in
            guard let a = map.node(link.from), let b = map.node(link.to) else { return nil }
            return "\(a.id) \"\(oneLine(a.title))\" <-> \(b.id) \"\(oneLine(b.title))\""
        }
        if !links.isEmpty {
            out.append("")
            out.append("CONNECTIONS (the researcher linked these nodes as related):")
            out.append(contentsOf: links)
        }
        let visual = map.nodes.filter { !$0.visual.isEmpty }
        if !visual.isEmpty {
            out.append("")
            out.append("DIAGRAM AND IMAGE NODES (place with {{node:ID}} on a line of its own, next to the text about it):")
            for node in visual { out.append("\(node.id) \"\(oneLine(node.title))\" (\(node.visual))") }
        }
        out.append("")
        out.append("Write the report now. Answer with the JSON object only.")
        return out.joined(separator: "\n")
    }

    private static func nodeHeader(_ node: ResearchMap.Node) -> String {
        var line = "NODE \(node.id) | " + (node.parent.isEmpty ? "root" : "parent \(node.parent)") + " | \"\(oneLine(node.title))\""
        if !node.tags.isEmpty { line += " | tags: " + node.tags.joined(separator: ", ") }
        if !node.visual.isEmpty { line += " | \(node.visual) node" }
        return line
    }

    /// The description as the model should read it: a visual node's own diagram or image is replaced by a marker, so the
    /// model neither copies the diagram's source nor the image's path.
    private static func describedText(_ node: ResearchMap.Node) -> String {
        var text = node.description
        if node.visual == "diagram", let source = ResearchMap.diagramSource(in: text) {
            text = text.replacingOccurrences(of: "```mermaid\n" + source + "\n```", with: "[the diagram]")
        }
        if node.visual == "image", let image = ResearchMap.imageSource(in: text) {
            text = text.replacingOccurrences(of: "![\(image.alt)](\(image.src))", with: "[the image: \(image.alt)]")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n    ")
    }

    /// The JSON Schema of the answer, for `CLICompletion.Request.jsonSchema`.
    static var answerSchema: [String: Any] {
        let text: [String: Any] = ["type": "string"]
        return [
            "type": "object",
            "properties": [
                "title": text,
                "sections": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["heading": text, "markdown": text, "covers": ["type": "array", "items": text]],
                    "required": ["heading", "markdown", "covers"],
                ] as [String: Any]] as [String: Any],
                "diagrams": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["id": text, "kind": ["type": "string", "enum": diagramKinds] as [String: Any], "what": text],
                    "required": ["id", "kind", "what"],
                ] as [String: Any]] as [String: Any],
                "sourcesHeading": text,
            ] as [String: Any],
            "required": ["title", "sections", "diagrams"],
        ]
    }

    /// The next request after a failed check: what is wrong, and the previous answer when the job passes it in.
    static func repairPrompt(problems: [Problem], previousAnswer: String? = nil) -> String {
        var out = ["Your report did not pass these checks. Fix every one of them and answer again with the complete JSON object in the same format (all sections, not only the changed ones)."]
        out.append("")
        for (index, problem) in problems.enumerated() { out.append("\(index + 1). \(problem.message)") }
        if let previousAnswer, !previousAnswer.isEmpty {
            out.append("")
            out.append("YOUR PREVIOUS ANSWER:")
            out.append(previousAnswer)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Reading the answer

    /// Reads the model's answer: the first JSON object with a `sections` list, wherever it stands in the text (a fenced
    /// block and prose around it are tolerated).
    static func parse(_ answer: String) -> Result<Draft, Failure> {
        let bytes = Array(answer.utf8)
        var attempts = 0
        var start = 0
        while start < bytes.count, attempts < 60 {
            guard bytes[start] == 0x7B else { start += 1; continue }
            attempts += 1
            if let end = balancedEnd(bytes, from: start),
               let object = try? JSONSerialization.jsonObject(with: Data(bytes[start...end])) as? [String: Any],
               object["sections"] != nil {
                return decode(object)
            }
            start += 1
        }
        return .failure(.noJSON)
    }

    /// The index of the `}` that closes the `{` at `start`, ignoring braces inside JSON strings.
    private static func balancedEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    private static func decode(_ object: [String: Any]) -> Result<Draft, Failure> {
        guard let rawSections = object["sections"] as? [Any], !rawSections.isEmpty else {
            return .failure(.malformed("\"sections\" must be a non-empty list."))
        }
        var sections: [Draft.Section] = []
        for (index, raw) in rawSections.enumerated() {
            guard let item = raw as? [String: Any], let heading = item["heading"] as? String, let markdown = item["markdown"] as? String else {
                return .failure(.malformed("section \(index + 1) needs a text \"heading\" and a text \"markdown\"."))
            }
            var covers: [String] = []
            if let list = item["covers"] {
                guard let ids = list as? [String] else { return .failure(.malformed("\"covers\" of section \(index + 1) must be a list of node ids.")) }
                covers = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            sections.append(Draft.Section(heading: heading.trimmingCharacters(in: .whitespacesAndNewlines),
                                          markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines), covers: covers))
        }
        var diagrams: [Draft.Diagram] = []
        if let list = object["diagrams"], !(list is NSNull) {
            guard let items = list as? [Any] else { return .failure(.malformed("\"diagrams\" must be a list.")) }
            for (index, raw) in items.enumerated() {
                guard let item = raw as? [String: Any], let id = item["id"] as? String, let kind = item["kind"] as? String,
                      let what = item["what"] as? String else {
                    return .failure(.malformed("diagram \(index + 1) needs a text \"id\", \"kind\" and \"what\"."))
                }
                diagrams.append(Draft.Diagram(id: id.trimmingCharacters(in: .whitespacesAndNewlines),
                                              kind: kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                                              what: what.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        var draft = Draft(title: (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                          sections: sections, diagrams: diagrams)
        draft.sourcesHeading = cleanHeading(object["sourcesHeading"] as? String)
        return .success(draft)
    }

    /// A one-line heading of at most 40 characters without markup, or empty.
    private static func cleanHeading(_ text: String?) -> String {
        let line = oneLine(text ?? "")
        guard !line.isEmpty, line.count <= 40, line.range(of: #"[<>`#\[\]{}]"#, options: .regularExpression) == nil else { return "" }
        return line
    }

    // MARK: Checks

    /// What is wrong with the draft, in the order a repair should read it. Empty: the draft can be assembled.
    static func check(draft: Draft, map: ResearchMap) -> [Problem] {
        var problems: [Problem] = []
        problems += structureProblems(draft)
        problems += coverageProblems(draft, map: map)
        problems += citationProblems(draft, sourceCount: sources(of: map).count)
        problems += placeholderProblems(draft, map: map)
        problems += shapeProblems(draft, map: map)
        problems += safetyProblems(draft, map: map)
        return problems
    }

    private static func structureProblems(_ draft: Draft) -> [Problem] {
        var problems: [Problem] = []
        if draft.sections.count < minSections {
            problems.append(Problem(code: .structure, message: "The report has \(draft.sections.count) section(s); write at least \(minSections): an introduction, the body, and the conclusions with the open questions."))
        }
        if let first = draft.sections.first, proseCharacters(first.markdown) == 0 {
            problems.append(Problem(code: .structure, message: "The first section is the introduction and needs prose: the question and the answer in brief."))
        }
        if draft.sections.contains(where: { $0.heading.isEmpty }) {
            problems.append(Problem(code: .structure, message: "Every section needs a heading."))
        }
        return problems
    }

    private static func coverageProblems(_ draft: Draft, map: ResearchMap) -> [Problem] {
        let known = Set(map.nodes.map { $0.id })
        let covered = Set(draft.sections.flatMap { $0.covers })
        var problems: [Problem] = []
        let missing = map.nodes.filter { !covered.contains($0.id) }
        if !missing.isEmpty {
            let listed = missing.prefix(maxListedIDs).map { "\($0.id) \"\(oneLine($0.title))\"" }.joined(separator: "; ")
            let more = missing.count > maxListedIDs ? " and \(missing.count - maxListedIDs) more" : ""
            problems.append(Problem(code: .missingNodes, message: "These nodes are not covered by any section: \(listed)\(more). Tell their content in the section where it belongs and add their ids to that section's \"covers\"."))
        }
        let unknown = Array(Set(draft.sections.flatMap { $0.covers }.filter { !known.contains($0) })).sorted()
        if !unknown.isEmpty {
            problems.append(Problem(code: .unknownNodes, message: "\"covers\" names ids that are not nodes of the map: \(unknown.prefix(maxListedIDs).joined(separator: ", ")). Use only the node ids given."))
        }
        return problems
    }

    private static func citationProblems(_ draft: Draft, sourceCount: Int) -> [Problem] {
        var bad = Set<Int>()
        for section in draft.sections {
            for number in citations(in: section.markdown) where number < 1 || number > sourceCount { bad.insert(number) }
        }
        guard !bad.isEmpty else { return [] }
        let range = sourceCount == 0 ? "The map has no sources, so the report must contain no citations." : "The sources are numbered [1] to [\(sourceCount)]."
        let listed = bad.sorted().prefix(maxListedIDs).map { "[\($0)]" }.joined(separator: ", ")
        return [Problem(code: .badCitation, message: "These citations do not exist: \(listed). \(range) If you mean an array index or similar, put it in backticks.")]
    }

    /// The source numbers cited in a section: `[3]`, `[3, 5]`, `[3-5]`. Code and links are left alone.
    static func citations(in markdown: String) -> [Int] {
        let text = withoutCode(markdown)
        var numbers: [Int] = []
        for match in matches(#"\[(\d[\d,;\s\-–]*)\](?!\()"#, in: text) {
            for part in match[1].split(whereSeparator: { ",; ".contains($0) }) {
                let bounds = part.split(whereSeparator: { "-–".contains($0) }).compactMap { Int($0) }
                if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] <= 200 {
                    numbers.append(contentsOf: bounds[0]...bounds[1])
                } else {
                    numbers.append(contentsOf: bounds)
                }
            }
        }
        return numbers
    }

    // MARK: Placeholders

    private enum Placeholder: Equatable {
        case node(String)
        case diagram(String)
    }

    /// The placeholders of a section on lines of their own, and a description of every malformed one.
    private static func placeholders(in markdown: String) -> (found: [Placeholder], malformed: [String]) {
        var found: [Placeholder] = []
        var malformed: [String] = []
        for line in classify(markdown) where line.kind != .code {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if line.kind == .placeholder {
                let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("node:"), isIdentifier(String(inner.dropFirst(5))) {
                    found.append(.node(String(inner.dropFirst(5))))
                } else if inner.hasPrefix("diagram:"), isIdentifier(String(inner.dropFirst(8))) {
                    found.append(.diagram(String(inner.dropFirst(8))))
                } else {
                    malformed.append("{{\(inner)}} is not a placeholder: write {{node:ID}} or {{diagram:dN}} with an id and nothing else")
                }
            } else if trimmed.contains("{{") || trimmed.contains("}}") {
                malformed.append("\"\(cap(trimmed, 60))\" has a placeholder inside a line: a placeholder stands on a line of its own")
            }
        }
        return (found, malformed)
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func placeholderProblems(_ draft: Draft, map: ResearchMap) -> [Problem] {
        var problems: [Problem] = []
        let requested = draft.diagrams
        if requested.count > maxDiagrams {
            problems.append(Problem(code: .tooManyDiagrams, message: "\(requested.count) diagrams are requested; ask for at most \(maxDiagrams), only where they really help."))
        }
        var seen = Set<String>()
        for diagram in requested {
            var why: String?
            if diagram.id.range(of: #"^d\d+$"#, options: .regularExpression) == nil { why = "the id must be d1, d2 …" }
            else if !seen.insert(diagram.id).inserted { why = "the id is used twice" }
            else if !diagramKinds.contains(diagram.kind) { why = "the kind must be one of \(diagramKinds.joined(separator: ", "))" }
            else if diagram.what.isEmpty { why = "\"what\" must say what the diagram shows" }
            if let why { problems.append(Problem(code: .badDiagramRequest, message: "Diagram \"\(diagram.id)\": \(why).")) }
        }
        var malformed: [String] = []
        var badNodes: [String] = []
        var strayDiagrams: [String] = []
        var counts: [String: Int] = [:]
        for section in draft.sections {
            let scan = placeholders(in: section.markdown)
            malformed += scan.malformed
            for placeholder in scan.found {
                switch placeholder {
                case .node(let id):
                    if map.node(id).map({ $0.visual.isEmpty }) ?? true { badNodes.append(id) }
                case .diagram(let id):
                    if requested.contains(where: { $0.id == id }) { counts[id, default: 0] += 1 } else { strayDiagrams.append(id) }
                }
            }
        }
        if !malformed.isEmpty {
            problems.append(Problem(code: .badPlaceholder, message: "Malformed placeholders: " + malformed.prefix(5).joined(separator: "; ") + "."))
        }
        if !badNodes.isEmpty {
            problems.append(Problem(code: .badNodePlaceholder, message: "{{node:ID}} is for diagram and image nodes only; these are not: \(Array(Set(badNodes)).sorted().joined(separator: ", ")). Tell their content in prose instead."))
        }
        if !strayDiagrams.isEmpty {
            problems.append(Problem(code: .badDiagramRequest, message: "{{diagram:…}} names diagrams that are not in \"diagrams\": \(Array(Set(strayDiagrams)).sorted().joined(separator: ", ")). Add them to \"diagrams\" or remove the placeholders."))
        }
        for diagram in requested where seen.contains(diagram.id) {
            let count = counts[diagram.id, default: 0]
            if count == 0 {
                problems.append(Problem(code: .diagramNotPlaced, message: "Diagram \(diagram.id) is requested but not placed: write {{diagram:\(diagram.id)}} on a line of its own where it belongs, or drop the request."))
            } else if count > 1 {
                problems.append(Problem(code: .diagramPlacedTwice, message: "Diagram \(diagram.id) is placed \(count) times; place it exactly once."))
            }
        }
        return problems
    }

    // MARK: Shape: a story, not an outline

    private static func shapeProblems(_ draft: Draft, map: ResearchMap) -> [Problem] {
        var problems: [Problem] = []
        let nodes = map.nodes.count
        var headings = draft.sections.count
        var listChars = 0
        var proseChars = 0
        var thin = 0
        for section in draft.sections {
            var sectionProse = 0
            for line in classify(section.markdown) {
                switch line.kind {
                case .heading: headings += 1
                case .bullet: listChars += line.text.count
                case .paragraph: sectionProse += line.text.count
                default: break
                }
            }
            proseChars += sectionProse
            if sectionProse < thinSectionChars { thin += 1 }
        }
        if nodes >= outlineMinHeadings, Double(headings) >= max(Double(outlineMinHeadings), (outlineHeadingRatio * Double(nodes)).rounded(.up)) {
            problems.append(Problem(code: .headingPerNode, message: "The report has \(headings) headings for \(nodes) nodes: that is an outline that follows the tree. Merge the nodes into fewer sections, one story per section (roughly one section per branch, not per node), and tell how the findings connect."))
        }
        let total = listChars + proseChars
        if listChars > listCharsFloor, total > 0, Double(listChars) / Double(total) > maxListShare {
            let percent = Int((Double(listChars) / Double(total) * 100).rounded())
            problems.append(Problem(code: .nodeList, message: "\(percent)% of the text is bullet points. Rewrite the lists as connected paragraphs; keep a list only where the content really is a list."))
        }
        if thin > max(1, draft.sections.count / 4) {
            problems.append(Problem(code: .thinProse, message: "\(thin) of \(draft.sections.count) sections have almost no prose (under \(thinSectionChars) characters outside lists). Write each section as paragraphs."))
        }
        let wanted = min(proseCharsCap, proseCharsPerNode * nodes)
        if proseChars < wanted {
            problems.append(Problem(code: .tooShort, message: "The report has \(proseChars) characters of prose for \(nodes) nodes; it needs at least \(wanted) to account for everything the map found. Tell the findings, not only that they exist."))
        }
        return problems
    }

    // MARK: Safety: nothing the map does not contain

    private static func safetyProblems(_ draft: Draft, map: ResearchMap) -> [Problem] {
        var problems: [Problem] = []
        let known = knownText(map)
        var unsafe: [String] = []
        var invented: [String] = []
        var rawDiagram = false
        var rawImage = false
        let texts = [draft.title, draft.sourcesHeading] + draft.sections.map { $0.heading } + draft.sections.map { $0.markdown }
        for text in texts {
            if let reason = unsafeReason(text) { unsafe.append(reason) }
        }
        for section in draft.sections {
            if section.markdown.range(of: #"(?m)^\s*(```|~~~)\s*mermaid"#, options: [.regularExpression, .caseInsensitive]) != nil { rawDiagram = true }
            let plain = withoutFences(section.markdown)
            if plain.contains("![") { rawImage = true }
            invented += inventedTargets(in: plain, known: known)
        }
        if let first = unsafe.first {
            problems.append(Problem(code: .unsafe, message: "The text contains \(first). Use plain Markdown only: no HTML, no scripts, no javascript: links, no click directives."))
        }
        if rawDiagram {
            problems.append(Problem(code: .rawDiagram, message: "Do not write Mermaid blocks. Request a diagram in \"diagrams\" and place it with {{diagram:dN}}."))
        }
        if rawImage {
            problems.append(Problem(code: .rawImage, message: "Do not write images. Images of the map are placed with {{node:ID}}."))
        }
        if !invented.isEmpty {
            let listed = Array(Set(invented)).sorted().prefix(8).joined(separator: ", ")
            problems.append(Problem(code: .invented, message: "These links or file paths are not in the map: \(listed). Mention only files and addresses that the map itself names, and cite sources by number."))
        }
        return problems
    }

    /// What is unsafe in a piece of model text, or nil.
    static func unsafeReason(_ text: String) -> String? {
        if text.range(of: #"(?i)javascript\s*:|\]\(\s*(vbscript|data)\s*:"#, options: .regularExpression) != nil {
            return "a javascript:, vbscript: or data: link"
        }
        let plain = withoutCode(text)
        if plain.range(of: #"(?i)<\s*script"#, options: .regularExpression) != nil { return "a <script> tag" }
        if plain.range(of: #"<\/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?\/?>|<!--"#, options: .regularExpression) != nil { return "HTML tags (put code in backticks)" }
        if text.range(of: #"(?m)^\s*click\s+\S+\s+(href|call|callback)\b"#, options: .regularExpression) != nil { return "a click directive" }
        return nil
    }

    /// Links, web addresses and file paths in the text that the map does not contain.
    private static func inventedTargets(in markdown: String, known: String) -> [String] {
        var invented: [String] = []
        let prose = withoutInlineCode(markdown)
        for match in matches(#"\[[^\]]*\]\(\s*([^)\s]+)[^)]*\)"#, in: prose) where !known.contains(match[1]) { invented.append(match[1]) }
        for match in matches(#"https?://[^\s)<>\]]+"#, in: prose) {
            let url = match[0].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\""))
            if !known.contains(url) { invented.append(url) }
        }
        for match in matches(#"`([^`\s*<>{}]+/[^`\s*<>{}]*\.[A-Za-z0-9]{1,8})(:[0-9]+(-[0-9]+)?)?`"#, in: markdown) where !known.contains(match[1]) {
            invented.append(match[1])
        }
        return invented
    }

    /// Everything the map says, in one string: a path or an address in the report must occur in it.
    private static func knownText(_ map: ResearchMap) -> String {
        var parts = [map.question, map.title]
        for node in map.nodes {
            parts.append(node.title)
            parts.append(node.description)
            for item in node.evidence {
                parts.append(item.text)
                parts.append(splitSource(item.source).location)
            }
        }
        parts.append(contentsOf: map.targets)
        parts.append(contentsOf: map.attachments)
        return parts.joined(separator: "\n")
    }

    // MARK: Assembling

    /// The final Markdown: title, the sections with their placeholders expanded, and the Sources list. `diagrams` maps a
    /// requested diagram id to its Mermaid source (or a fenced block); an id that is missing is dropped from the text and
    /// reported. A visual node the model did not place is put at the end of the first section that covers it.
    static func assemble(draft: Draft, map: ResearchMap, diagrams: [String: String],
                         mapName: String = "", date: String = "") -> Assembled {
        var dropped: [String] = []
        var empty: [String] = []
        var placedNodes = Set<String>()
        let referenced = Set(draft.sections.flatMap { section in
            placeholders(in: section.markdown).found.compactMap { placeholder -> String? in
                if case .node(let id) = placeholder { return id }
                return nil
            }
        })
        var unplaced = map.nodes.filter { !$0.visual.isEmpty && !referenced.contains($0.id) }.map { $0.id }
        var out: [String] = []
        let title = oneLine(draft.title).isEmpty ? oneLine(map.title) : oneLine(draft.title)
        out.append("# " + title)
        out.append("")
        let byline = [mapName.isEmpty ? "" : "`" + mapName.replacingOccurrences(of: "`", with: "'") + "`", date].filter { !$0.isEmpty }
        if !byline.isEmpty {
            out.append("*" + byline.joined(separator: " · ") + "*")
            out.append("")
        }
        for (index, section) in draft.sections.enumerated() {
            out.append("## " + oneLine(section.heading))
            out.append("")
            var body = expand(section.markdown, map: map, diagrams: diagrams, placedNodes: &placedNodes, dropped: &dropped, empty: &empty)
            let mine = unplaced.filter { id in section.covers.contains(id) || (index == draft.sections.count - 1 && !draft.sections.contains { $0.covers.contains(id) }) }
            for id in mine {
                if let block = visualBlock(map.node(id), empty: &empty) { body += ["", block] }
                placedNodes.insert(id)
            }
            unplaced.removeAll { mine.contains($0) }
            out.append(contentsOf: body)
            out.append("")
        }
        out.append(contentsOf: sourcesSection(map, heading: draft.sourcesHeading))
        return Assembled(markdown: tidy(out), droppedDiagrams: dropped, emptyVisuals: empty)
    }

    /// One section's Markdown with its placeholder lines expanded and its headings kept below the section's own.
    private static func expand(_ markdown: String, map: ResearchMap, diagrams: [String: String], placedNodes: inout Set<String>,
                               dropped: inout [String], empty: inout [String]) -> [String] {
        var out: [String] = []
        for line in classify(markdown) {
            switch line.kind {
            case .placeholder:
                let inner = String(line.text.trimmingCharacters(in: .whitespaces).dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("node:") {
                    let id = String(inner.dropFirst(5))
                    guard !placedNodes.contains(id) else { continue }
                    placedNodes.insert(id)
                    if let block = visualBlock(map.node(id), empty: &empty) { out += ["", block, ""] }
                } else if inner.hasPrefix("diagram:") {
                    let id = String(inner.dropFirst(8))
                    if let source = diagramSource(diagrams[id]) { out += ["", "```mermaid", source, "```", ""] } else { dropped.append(id) }
                }
            case .heading:
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                let level = trimmed.prefix { $0 == "#" }.count
                out.append(String(repeating: "#", count: min(6, max(3, level))) + trimmed.dropFirst(level))
            default:
                out.append(line.text)
            }
        }
        return out
    }

    /// The Mermaid source of a supplied diagram (a bare source or a fenced block), or nil when it is empty or unsafe.
    private static func diagramSource(_ text: String?) -> String? {
        guard var source = text?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else { return nil }
        if source.hasPrefix("```") {
            var lines = source.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !source.isEmpty, unsafeReason(source) == nil, !source.contains("```") else { return nil }
        return source
    }

    /// The diagram fence or the image line of a visual node, or nil (and its id in `empty`) when its description has none.
    private static func visualBlock(_ node: ResearchMap.Node?, empty: inout [String]) -> String? {
        guard let node, !node.visual.isEmpty else { return nil }
        if node.visual == "diagram", let source = ResearchMap.diagramSource(in: node.description), diagramSource(source) != nil {
            return "```mermaid\n" + source + "\n```"
        }
        if node.visual == "image", let image = ResearchMap.imageSource(in: node.description),
           !image.src.lowercased().hasPrefix("javascript:"), !image.src.lowercased().hasPrefix("data:") {
            let alt = oneLine(image.alt.isEmpty ? node.title : image.alt).replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            return "![\(alt)](\(image.src))"
        }
        empty.append(node.id)
        return nil
    }

    /// The Sources list, built from the evidence of the map only: every source with its number, where it is cited and how
    /// the evidence that cites it is labelled.
    private static func sourcesSection(_ map: ResearchMap, heading: String) -> [String] {
        let all = sources(of: map)
        guard !all.isEmpty else { return [] }
        var out = ["## " + (heading.isEmpty ? "Sources" : heading), ""]
        for source in all {
            let place = source.isWeb ? "<\(source.location)>" : "`" + source.location.replacingOccurrences(of: "`", with: "'") + "`"
            var line = "- [\(source.number)] " + place
            if !source.lines.isEmpty { line += " (" + source.lines.joined(separator: ", ") + ")" }
            line += " — " + labelSummary(source.labels)
            out.append(line)
        }
        out.append("")
        return out
    }

    private static func labelSummary(_ labels: [ResearchMap.Label]) -> String {
        ResearchMap.Label.allCases.compactMap { label -> String? in
            let count = labels.filter { $0 == label }.count
            return count == 0 ? nil : (count == 1 ? label.rawValue : "\(label.rawValue) ×\(count)")
        }.joined(separator: ", ")
    }

    /// Joins the lines and collapses runs of blank lines to one.
    private static func tidy(_ lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.isEmpty == true { continue }
            out.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Markdown lines

    private enum LineKind { case blank, heading, bullet, paragraph, placeholder, table, code }

    /// The lines of a Markdown text with what each one is. Lines inside fenced blocks are `code`; an indented line right
    /// after a bullet belongs to the bullet.
    private static func classify(_ markdown: String) -> [(kind: LineKind, text: String)] {
        var out: [(LineKind, String)] = []
        var fence: String?
        var inBullet = false
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                out.append((.code, raw))
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                inBullet = false
                out.append((.code, raw))
                continue
            }
            if trimmed.isEmpty { inBullet = false; out.append((.blank, raw)); continue }
            if trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil { inBullet = false; out.append((.heading, raw)); continue }
            if trimmed.range(of: #"^\{\{[^{}]*\}\}$"#, options: .regularExpression) != nil { inBullet = false; out.append((.placeholder, raw)); continue }
            if trimmed.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil { inBullet = true; out.append((.bullet, raw)); continue }
            if trimmed.hasPrefix("|") { inBullet = false; out.append((.table, raw)); continue }
            if inBullet, raw.hasPrefix("  ") || raw.hasPrefix("\t") { out.append((.bullet, raw)); continue }
            inBullet = false
            out.append((.paragraph, raw))
        }
        return out
    }

    /// Characters of running prose in a Markdown text (no lists, headings, tables, code or placeholders).
    private static func proseCharacters(_ markdown: String) -> Int {
        classify(markdown).filter { $0.kind == .paragraph }.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespaces).count }
    }

    private static func withoutFences(_ markdown: String) -> String {
        classify(markdown).filter { $0.kind != .code }.map { $0.text }.joined(separator: "\n")
    }

    private static func withoutInlineCode(_ text: String) -> String {
        text.replacingOccurrences(of: #"`[^`\n]*`"#, with: "", options: .regularExpression)
    }

    private static func withoutCode(_ markdown: String) -> String { withoutInlineCode(withoutFences(markdown)) }

    // MARK: Small helpers

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func cap(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Every match of `pattern` in `text` as its capture groups (index 0 is the whole match).
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: whole).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
