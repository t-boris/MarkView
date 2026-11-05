import Foundation

/// Translating a research map (REQ-014, DEC-015).
///
/// The AI never sees or writes the map file. It receives the texts of a batch of nodes keyed by node id and
/// answers with the same texts in the other language. This module builds that request, reads and checks the
/// answer, and applies the texts onto a copy of the parsed map, so that whatever the model answers, ids,
/// parents, order, links, numbers, colours, icons, shapes, sizes, positions, layout, `visual`, evidence labels
/// and evidence sources stay exactly as they were. Foundation only: no UI, no AI call, no file access.
///
/// The job does the rest: for each batch of `batches(of:)` it asks `prompt(map:ids:language:)`, `parse`s the
/// answer, `check`s it, asks again for `repairIds` with `repairPrompt` (twice at most), `merged` the repairs
/// into the answer and `apply`s it.
enum ResearchMapTranslation {

    // MARK: - Languages and file names

    /// The languages the app offers, in menu order; the person may also type another.
    static var languages: [(name: String, code: String)] { ResearchMap.languages.map { ($0.name, $0.code) } }

    /// Names the person may type (English or native) and the file-name code of each.
    private static let codeByName: [String: String] = [
        "english": "en", "английский": "en", "russian": "ru", "русский": "ru", "german": "de", "deutsch": "de", "немецкий": "de",
        "spanish": "es", "español": "es", "испанский": "es", "french": "fr", "français": "fr", "французский": "fr",
        "italian": "it", "italiano": "it", "portuguese": "pt", "português": "pt", "chinese": "zh", "japanese": "ja",
        "korean": "ko", "ukrainian": "uk", "українська": "uk", "polish": "pl", "polski": "pl", "dutch": "nl", "turkish": "tr",
    ]
    private static let knownCodes = Set(codeByName.values)

    /// The code a translated map's file name carries for a language name: `en` for "English", `ru` for "Русский"; a name
    /// that is not known becomes its first ASCII letters ("Klingon" gives "klingon"), or "translated" when it has none.
    static func languageCode(for name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = codeByName[key] { return code }
        if knownCodes.contains(key) { return key }
        var slug = ""
        for scalar in key.unicodeScalars where scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) { slug.unicodeScalars.append(scalar) }
        slug = String(slug.prefix(12))
        return slug.isEmpty ? "translated" : slug
    }

    /// `plan.md` and "en" give `plan-en.md`; a language code the name already ends with is replaced
    /// (`plan-ru.md` and "en" give `plan-en.md`). The job picks a free name itself.
    static func translatedFileName(for file: String, code: String) -> String {
        let ns = file as NSString
        let ext = ns.pathExtension
        var stem = ns.deletingPathExtension
        if let dash = stem.lastIndex(of: "-"), dash != stem.startIndex {
            let suffix = String(stem[stem.index(after: dash)...]).lowercased()
            if knownCodes.contains(suffix) { stem = String(stem[..<dash]) }
        }
        return stem + "-" + code + (ext.isEmpty ? "" : "." + ext)
    }

    /// The copy written before a map is replaced by its translation: `plan.md` gives `plan-before-translation.md`.
    static func backupFileName(for file: String) -> String {
        let ns = file as NSString
        let ext = ns.pathExtension
        return ns.deletingPathExtension + "-before-translation" + (ext.isEmpty ? "" : "." + ext)
    }

    // MARK: - Batches

    static let batchSize = 20

    /// Node ids in map order, `size` at a time. The first batch holds the root, so it carries the title and the question.
    static func batches(of map: ResearchMap, size: Int = batchSize) -> [[String]] {
        let ids = map.nodes.map(\.id)
        let step = max(1, size)
        return stride(from: 0, to: ids.count, by: step).map { Array(ids[$0..<min($0 + step, ids.count)]) }
    }

    // MARK: - The request

    static func prompt(map: ResearchMap, ids: [String], language: String) -> (system: String, user: String) {
        let system = """
        You translate the texts of a research map into \(language). The map is a tree of nodes; you receive the \
        texts of some of them and answer with the same texts in \(language). Follow these rules without exception.

        1. TRANSLATE EVERYTHING THAT IS READ. Titles, tags, descriptions and evidence texts all become \(language). \
        Keep the meaning, the tone and the level of detail: do not summarise, shorten, merge, reorder or add anything. \
        Titles stay short (one line, at most \(ResearchMap.titleLimit) characters).
        2. KEEP UNCHANGED, character for character: web addresses, file paths, code identifiers, anything in `inline code` \
        or in a fenced code block, link and image addresses (the text of a link is translated, its address is not), numbers, \
        and the names of products, people and companies unless they have a standard form in \(language).
        3. KEEP THE MARKDOWN. Headings, lists, tables, emphasis, links and line breaks stay as they are; only the words change.
        4. MERMAID DIAGRAMS. A ```mermaid block keeps every line, every id, every arrow and every keyword; translate only \
        the readable label text (text in quotes, in brackets, on an arrow, after a colon, after `as`). Never add, remove \
        or reorder a line.
        5. EVIDENCE. `evidence` has exactly one translated text for each evidence item of the node, in the same order. The \
        label and the source shown with an item are context only: do not translate them and do not return them.
        6. If a text is already in \(language), return it as it is.
        Answer only with the JSON object of the schema, with one entry for every node you received.
        """

        let wanted = Set(ids)
        var payload: [String: Any] = [:]
        if let root = map.root, wanted.contains(root.id) {
            payload["title"] = root.title
            payload["question"] = map.question
        }
        payload["nodes"] = map.nodes.filter { wanted.contains($0.id) }.map { node -> [String: Any] in
            [
                "id": node.id,
                "title": node.title,
                "tags": node.tags,
                "description": node.description,
                "evidence": node.evidence.map { ["label": $0.label.rawValue, "source": $0.source, "text": $0.text] },
            ]
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var user = "Translate these texts into \(language).\n"
        if payload["title"] != nil {
            user += "The input has `title` and `question` of the whole map: translate them too (`title` is the title of the first node).\n"
        } else {
            user += "Answer with an empty string for `title` and `question`: they are not part of this input.\n"
        }
        user += "Answer with the node ids: \(ids.joined(separator: ", ")).\n\nINPUT (JSON):\n\(json)\n"
        return (system, user)
    }

    /// The JSON Schema of the answer, for `CLICompletion.Request.jsonSchema`.
    static var schema: [String: Any] {
        func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "question", "nodes"],
            "properties": [
                "title": str("The translated title of the map; an empty string when the input has none."),
                "question": str("The translated question of the map; an empty string when the input has none."),
                "nodes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "title", "tags", "description", "evidence"],
                        "properties": [
                            "id": str("The node id exactly as received."),
                            "title": str("The translated title."),
                            "tags": ["type": "array", "items": ["type": "string"], "description": "The translated tags."],
                            "description": str("The translated description, Markdown as received."),
                            "evidence": ["type": "array", "items": ["type": "string"],
                                         "description": "One translated text per evidence item, in the same order."],
                        ],
                    ],
                ],
            ],
        ]
    }

    // MARK: - The answer

    struct Answer: Equatable {
        struct Node: Equatable {
            var id: String
            var title: String
            var tags: [String]
            var description: String
            var evidence: [String]
        }
        var title: String?
        var question: String?
        var nodes: [Node]
    }

    struct Failure: Error, Equatable {
        var message: String
    }

    /// Reads the answer: a bare JSON object, a fenced one, or one inside other words. A missing field reads as empty.
    static func parse(answer: String) -> Result<Answer, Failure> {
        guard let value = jsonValue(in: answer) else { return .failure(Failure(message: "the answer was not JSON")) }
        let object: [String: Any]
        if let dictionary = value as? [String: Any] {
            object = dictionary
        } else if let list = value as? [Any] {
            object = ["nodes": list]
        } else {
            return .failure(Failure(message: "the answer was not a JSON object"))
        }
        guard let rawNodes = object["nodes"] as? [Any] else { return .failure(Failure(message: "the answer has no `nodes` list")) }
        func texts(_ value: Any?) -> [String] {
            (value as? [Any] ?? []).compactMap { item in
                if let text = item as? String { return text }
                if let dictionary = item as? [String: Any] { return dictionary["text"] as? String }
                return nil
            }
        }
        var nodes: [Answer.Node] = []
        for raw in rawNodes {
            guard let dictionary = raw as? [String: Any], let id = (dictionary["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { continue }
            nodes.append(Answer.Node(id: id, title: dictionary["title"] as? String ?? "", tags: texts(dictionary["tags"]),
                                     description: dictionary["description"] as? String ?? "", evidence: texts(dictionary["evidence"])))
        }
        guard !nodes.isEmpty else { return .failure(Failure(message: "the answer has no usable node")) }
        func optional(_ key: String) -> String? {
            let text = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        return .success(Answer(title: optional("title"), question: optional("question"), nodes: nodes))
    }

    private static func jsonValue(in text: String) -> Any? {
        var candidates = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        let lines = text.components(separatedBy: "\n")
        for fence in fences(in: lines) where fence.language == "json" || fence.language.isEmpty {
            candidates.append(lines[(fence.open + 1)..<fence.close].joined(separator: "\n"))
        }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            candidates.append(String(text[open...close]))
        }
        if let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close {
            candidates.append(String(text[open...close]))
        }
        for candidate in candidates where !candidate.isEmpty {
            if let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)), value is [String: Any] || value is [Any] { return value }
        }
        return nil
    }

    /// The answer for the nodes of `repair` replacing those of `base`; nodes only `base` has stay.
    static func merged(_ base: Answer, with repair: Answer) -> Answer {
        var result = base
        for node in repair.nodes {
            if let index = result.nodes.firstIndex(where: { $0.id == node.id }) { result.nodes[index] = node } else { result.nodes.append(node) }
        }
        result.title = repair.title ?? base.title
        result.question = repair.question ?? base.question
        return result
    }

    // MARK: - Checks

    struct Problem: Equatable {
        enum Severity { case error, warning }
        /// The node id, or empty for the map.
        var node: String
        /// missing, unknown, duplicate, title, tags, evidence, description, address, code, fences, diagram, untranslated.
        var code: String
        var severity: Severity
        var message: String
    }

    /// What is worth asking the model again: an `.error` (the node's translation is unusable) and a `diagram`
    /// (usable except for the Mermaid structure; if it stays wrong the original blocks are kept). Warnings only report.
    static func repairable(_ problems: [Problem]) -> [Problem] {
        problems.filter { $0.severity == .error || $0.code == "diagram" }
    }

    /// The node ids to ask for again, in order.
    static func repairIds(_ problems: [Problem]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for problem in repairable(problems) where !problem.node.isEmpty && seen.insert(problem.node).inserted { result.append(problem.node) }
        return result
    }

    /// What to add to the request when the answer is asked for again (for the nodes of `repairIds`).
    static func repairPrompt(problems: [Problem]) -> String {
        let items = repairable(problems).map { "- \($0.node.isEmpty ? "map" : $0.node): \($0.message)" }
        return """


        Your previous answer had these problems; fix every one. Answer with the JSON object of the same format \
        that contains ONLY the nodes listed here (ids: \(repairIds(problems).joined(separator: ", "))), each one complete:
        \(items.prefix(30).joined(separator: "\n"))
        """
    }

    /// Checks the answer for the nodes `ids` against the map as it is (before `apply`).
    static func check(answer: Answer, map: ResearchMap, ids: [String]) -> [Problem] {
        var problems: [Problem] = []
        let wanted = Set(ids)
        var seen = Set<String>()
        for node in answer.nodes {
            if !wanted.contains(node.id) || map.node(node.id) == nil {
                problems.append(Problem(node: node.id, code: "unknown", severity: .warning, message: "`\(node.id)` is not a node you were given; it is ignored"))
            } else if !seen.insert(node.id).inserted {
                problems.append(Problem(node: node.id, code: "duplicate", severity: .warning, message: "`\(node.id)` is answered twice; the first answer is used"))
            }
        }
        // One node after the other in the order asked, so that a repair asks for them in map order.
        for id in ids {
            guard let original = map.node(id) else { continue }
            if let node = answer.nodes.first(where: { $0.id == id }) {
                problems += check(node, against: original)
            } else {
                problems.append(Problem(node: id, code: "missing", severity: .error, message: "there is no entry for this node; translate it"))
            }
        }
        return problems
    }

    private static func check(_ node: Answer.Node, against original: ResearchMap.Node) -> [Problem] {
        var problems: [Problem] = []
        func add(_ code: String, _ severity: Problem.Severity, _ message: String) {
            problems.append(Problem(node: original.id, code: code, severity: severity, message: message))
        }
        // Title.
        let title = squeeze(node.title)
        if title.isEmpty { add("title", .error, "the title is empty") }
        else if title.count > ResearchMap.titleLimit { add("title", .error, "the title has \(title.count) characters; at most \(ResearchMap.titleLimit)") }
        // Tags.
        if !original.tags.isEmpty && ResearchMap.clean(tags: node.tags).isEmpty { add("tags", .error, "the node has tags (\(original.tags.joined(separator: ", "))); translate them") }
        // Evidence.
        if node.evidence.count != original.evidence.count {
            add("evidence", .error, "expected \(original.evidence.count) evidence text(s), got \(node.evidence.count); one translated text per evidence item, in order")
        } else if zip(original.evidence, node.evidence).contains(where: { !$0.text.isEmpty && squeeze($1).isEmpty }) {
            add("evidence", .error, "an evidence text is empty")
        }
        // Description.
        let description = ResearchMap.clean(description: node.description)
        if description.count > ResearchMap.descriptionLimit { add("description", .error, "the description is too long") }
        if !original.description.isEmpty && description.isEmpty { add("description", .error, "the description is empty; translate it") }

        guard !original.description.isEmpty || !original.evidence.isEmpty else { return problems }
        let translatedEvidence = node.evidence.count == original.evidence.count ? node.evidence : []
        let beforeTexts = [original.description] + original.evidence.map(\.text)
        let afterTexts = [description] + translatedEvidence
        if !translatedEvidence.isEmpty || original.evidence.isEmpty {
            // Addresses, inline code and code blocks must come back as they were.
            if addresses(in: beforeTexts) != addresses(in: afterTexts) {
                add("address", .error, "a web address, link target or image address was changed or lost; keep every address exactly as it is")
            }
            if inlineCode(in: beforeTexts) != inlineCode(in: afterTexts) {
                add("code", .error, "text in `inline code` was changed or lost; keep it exactly as it is")
            }
        }
        if !original.description.isEmpty && !description.isEmpty {
            if codeBlocks(in: original.description) != codeBlocks(in: description) {
                add("code", .error, "a fenced code block was changed or lost; keep it exactly as it is")
            }
            let before = mermaidBlocks(in: original.description), after = mermaidBlocks(in: description)
            if before.count != after.count {
                add("fences", .error, "the description has \(before.count) mermaid block(s); the answer has \(after.count). Keep every block")
            } else {
                for (index, pair) in zip(before, after).enumerated() where skeleton(ofMermaid: pair.0.source) != skeleton(ofMermaid: pair.1.source) {
                    add("diagram", .warning, "mermaid block \(index + 1) changed its structure; keep every line, id and arrow and translate only the label text")
                }
            }
            if prose(of: original.description) == prose(of: description), prose(of: original.description).count > 40 {
                add("untranslated", .warning, "the description looks untranslated")
            }
        }
        for (index, pair) in zip(original.evidence, translatedEvidence).enumerated() where pair.0.text == pair.1 && pair.0.text.count > 40 {
            add("untranslated", .warning, "evidence \(index + 1) looks untranslated")
        }
        return problems
    }

    // MARK: - Applying

    struct Applied: Equatable {
        /// Ids whose text was replaced (a node that kept only its diagrams is in here too).
        var translated: [String] = []
        /// Ids that kept their original text: missing from the answer, or failing the checks.
        var keptOriginal: [String] = []
        /// Ids translated except for the Mermaid blocks that changed structure, which kept their original.
        var diagramKept: [String] = []
        /// Ids in the answer that are not nodes of this batch.
        var ignored: [String] = []
        var titleTranslated = false
        var questionTranslated = false
        var translatedCount: Int { translated.count }
    }

    /// Puts the checked texts of the answer onto `map`. Only titles, tags, descriptions, evidence texts, the title and the
    /// question change; the answer is checked here again, so a caller cannot apply an answer that failed.
    @discardableResult
    static func apply(answer: Answer, to map: inout ResearchMap, ids: [String]) -> Applied {
        let problems = check(answer: answer, map: map, ids: ids)
        var applied = Applied()
        applied.ignored = problems.filter { $0.code == "unknown" }.map(\.node)
        for id in ids {
            guard let index = map.index(of: id) else { continue }
            let failing = problems.contains { $0.node == id && $0.severity == .error }
            guard !failing, let node = answer.nodes.first(where: { $0.id == id }) else {
                applied.keptOriginal.append(id)
                continue
            }
            let original = map.nodes[index]
            var description = original.description.isEmpty ? "" : ResearchMap.clean(description: node.description)
            if !original.description.isEmpty {
                let restored = restoringChangedDiagrams(in: description, from: original.description)
                if restored.changed { applied.diagramKept.append(id) }
                description = restored.text
            }
            let tags = original.tags.isEmpty ? [] : ResearchMap.clean(tags: node.tags)
            do {
                try map.update(id: id, title: node.title, tags: tags, description: description)
            } catch {
                map.nodes[index] = original   // a refused value leaves the node whole
                applied.keptOriginal.append(id)
                applied.diagramKept.removeAll { $0 == id }
                continue
            }
            if let at = map.index(of: id) {
                for (i, text) in node.evidence.enumerated() where i < map.nodes[at].evidence.count {
                    map.nodes[at].evidence[i].text = squeeze(text)
                }
            }
            applied.translated.append(id)
        }
        // The title of the map is the title of its root node: a translated root already carries it; otherwise the answer's own title is used.
        if let root = map.root, ids.contains(root.id) {
            if applied.translated.contains(root.id) {
                applied.titleTranslated = true
            } else if let title = answer.title.map(squeeze), !title.isEmpty, (try? map.update(id: root.id, title: title)) != nil {
                applied.titleTranslated = true
            }
        }
        // The question belongs to the first batch, the one with the root.
        if let root = map.root, ids.contains(root.id), let question = answer.question.map({ ResearchMap.clean(description: $0) }), !question.isEmpty {
            map.question = question
            applied.questionTranslated = true
        }
        return applied
    }

    /// The translated description with every Mermaid block whose structure differs from the original's replaced by the
    /// original block (the blocks pair up by position; `check` guarantees the counts are equal).
    private static func restoringChangedDiagrams(in translated: String, from original: String) -> (text: String, changed: Bool) {
        let before = mermaidBlocks(in: original), after = mermaidBlocks(in: translated)
        guard before.count == after.count, !before.isEmpty else { return (translated, false) }
        var lines = translated.components(separatedBy: "\n")
        var changed = false
        // From the last block to the first, so the line numbers of the earlier ones stay valid.
        for index in stride(from: after.count - 1, through: 0, by: -1)
        where skeleton(ofMermaid: before[index].source) != skeleton(ofMermaid: after[index].source) {
            lines.replaceSubrange(after[index].open...after[index].close, with: before[index].lines)
            changed = true
        }
        return (lines.joined(separator: "\n"), changed)
    }

    // MARK: - Mermaid

    /// A Mermaid block with its label text taken out, so that two blocks that differ only in label text compare equal.
    /// Kept: the diagram type line, ids, arrows, keywords, shapes and classes. Dropped: `%%` comments and the label text
    /// (in quotes, in `[]` `()` `{}`, between `|`, after the colon of a sequence message or note, after `as`, after
    /// `loop`/`alt`/`opt` and the like). Fits the flowchart that `DiagramAI.mermaid` writes and the sequence diagram
    /// that `CodeArchitecture.sequenceMermaid` writes; a diagram of another kind is compared by its quotes, brackets and bars.
    static func skeleton(ofMermaid source: String) -> String {
        var lines = source.components(separatedBy: "\n")
            .map { collapse($0) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let first = lines.first else { return "" }
        let kind = first.lowercased()
        let isSequence = kind.hasPrefix("sequencediagram")
        let isER = kind.hasPrefix("erdiagram")
        for i in lines.indices.dropFirst() {
            lines[i] = isSequence ? sequenceSkeleton(lines[i]) : (isER ? erSkeleton(lines[i]) : flowSkeleton(lines[i]))
        }
        return lines.joined(separator: "\n")
    }

    private static let sequenceBlocks = ["loop", "alt", "else", "opt", "par", "and", "critical", "option", "break", "rect", "title", "box"]

    private static func sequenceSkeleton(_ line: String) -> String {
        let lower = line.lowercased()
        // participant p0 as Label / actor A as Label
        for keyword in ["participant", "actor"] where lower.hasPrefix(keyword + " ") {
            let words = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            if words.count >= 4, words[2].lowercased() == "as" { return "\(words[0]) \(words[1]) as _" }
            return line
        }
        // loop text / alt text / else text ...
        for keyword in sequenceBlocks where lower == keyword || lower.hasPrefix(keyword + " ") { return keyword + " _" }
        // Note over A,B: text / a message `A->>B: text`
        if let colon = line.firstIndex(of: ":") { return String(line[..<colon]).trimmingCharacters(in: .whitespaces) + ": _" }
        return line
    }

    private static func erSkeleton(_ line: String) -> String {
        // ENTITY ||--o{ OTHER : label
        if let range = line.range(of: " : ") { return String(line[..<range.lowerBound]) + " : _" }
        return flowSkeleton(line)
    }

    private static func flowSkeleton(_ line: String) -> String {
        // Quoted text first (it may hold brackets), then the outer bracket groups, then the text on arrows.
        var text = replacing(line, pattern: "\"[^\"]*\"", with: "\"_\"")
        text = replacingBrackets(text)
        text = replacing(text, pattern: "\\|[^|]*\\|", with: "|_|")
        return collapse(text)
    }

    /// Every outermost `[...]`, `(...)` or `{...}` group becomes its first opener, `_` and its last closer.
    private static func replacingBrackets(_ line: String) -> String {
        let openers: Set<Character> = ["[", "(", "{"], closers: Set<Character> = ["]", ")", "}"]
        var result = "", depth = 0, group = "", lastCloser: Character = "]"
        for ch in line {
            if depth == 0 {
                if openers.contains(ch) { depth = 1; group = String(ch) } else { result.append(ch) }
            } else {
                if openers.contains(ch) { depth += 1 } else if closers.contains(ch) { depth -= 1; lastCloser = ch }
                group.append(ch)
                if depth == 0 { result += String(group.first!) + "_" + String(lastCloser); group = "" }
            }
        }
        return result + group   // an unbalanced rest stays as written, so a damaged line never compares equal by accident
    }

    private static func replacing(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
    }

    // MARK: - Reading Markdown

    private struct Fence {
        var open: Int
        var close: Int
        var language: String
    }

    /// Fenced blocks of a text as line ranges (an unclosed one runs to the end).
    private static func fences(in lines: [String]) -> [Fence] {
        var result: [Fence] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").first.map(String.init) ?? ""
                var j = i + 1
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("```") { j += 1 }
                result.append(Fence(open: i, close: min(j, lines.count - 1), language: language))
                i = j + 1
            } else {
                i += 1
            }
        }
        return result
    }

    private struct MermaidBlock {
        var open: Int
        var close: Int
        var lines: [String]
        var source: String
    }

    private static func mermaidBlocks(in text: String) -> [MermaidBlock] {
        let lines = text.components(separatedBy: "\n")
        return fences(in: lines).filter { $0.language == "mermaid" }.map { fence in
            let closed = fence.close > fence.open && lines[fence.close].trimmingCharacters(in: .whitespaces).hasPrefix("```")
            let body = lines[(fence.open + 1)..<(closed ? fence.close : lines.count)]
            return MermaidBlock(open: fence.open, close: closed ? fence.close : lines.count - 1, lines: Array(lines[fence.open...(closed ? fence.close : lines.count - 1)]),
                                source: body.joined(separator: "\n"))
        }
    }

    /// The fenced blocks that are not Mermaid, each with its fence lines.
    private static func codeBlocks(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        return fences(in: lines).filter { $0.language != "mermaid" }.map { lines[$0.open...$0.close].joined(separator: "\n") }
    }

    /// The lines outside fenced blocks.
    private static func prose(of text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var inside = Set<Int>()
        for fence in fences(in: lines) { inside.formUnion(fence.open...fence.close) }
        return lines.enumerated().filter { !inside.contains($0.offset) }.map(\.element).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Link and image targets and bare web addresses of the prose of `texts`, sorted. A link's target counts once, whether it is
    /// written as `[text](address)` or as an address in the text.
    private static func addresses(in texts: [String]) -> [String] {
        var found: [String] = []
        for text in texts.map(prose(of:)) {
            var rest = text
            if let regex = try? NSRegularExpression(pattern: "\\]\\(\\s*<?([^)\\s>]+)") {
                let ns = rest as NSString
                for match in regex.matches(in: rest, range: NSRange(location: 0, length: ns.length)).reversed() {
                    found.append(ns.substring(with: match.range(at: 1)))
                    rest = (rest as NSString).replacingCharacters(in: match.range, with: "] (")
                }
            }
            if let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'`)\\]]+") {
                let ns = rest as NSString
                for match in regex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                    var url = ns.substring(with: match.range)
                    while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
                    found.append(url)
                }
            }
        }
        return found.sorted()
    }

    /// The spans of `inline code` in the prose of `texts`, sorted.
    private static func inlineCode(in texts: [String]) -> [String] {
        var found: [String] = []
        guard let regex = try? NSRegularExpression(pattern: "`([^`\\n]+)`") else { return [] }
        for text in texts.map(prose(of:)) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) { found.append(ns.substring(with: match.range(at: 1))) }
        }
        return found.sorted()
    }

    /// One line, single spaces, trimmed: how a title or an evidence text is stored.
    private static func squeeze(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
