import Foundation

/// What the AI adds to the Book X-Ray, and how its answers become nodes: per chapter one call
/// (windows for very long chapters) that writes what the chapter and every section say, marks
/// their importance, names related sections of the book, and — for large chapters and documents
/// without headings — lists the items a section is made of. A second small call writes the
/// parts' blurbs and the book's summary. The structure itself comes from `BookBuilder`; the AI
/// only writes texts, so every answer is checked against the ids it was given.
///
/// Foundation only, no app state: `tools/tests/book-xray-tests.sh` compiles this file on its own.
enum BookAnnotator {
    /// Part of the chapter's `summarySignature`: bump when the prompt changes what is asked.
    static let promptVersion = "v1"
    /// A chapter this long, or with this many sections, also gets its items listed.
    static let largeLines = 300
    static let largeSections = 12
    /// Longest text sent in one call, in lines; longer chapters are annotated in windows.
    static let windowLines = 2500
    /// Longest book index sent with a chapter, in lines.
    static let indexLines = 400
    static let levels = ["critical", "high", "normal", "low"]

    // MARK: - The book as the view holds it

    struct Section {
        var id: String
        var parent: String
        var title: String
        var line: Int
        var end: Int
        /// 0 for a section directly under the chapter.
        var depth: Int
    }

    struct Chapter {
        var id: String
        var path: String
        var title: String
        var partId: String
        var partName: String
        var lines: Int
        var signature: String?
        var summarySignature: String?
        var hasSummary: Bool
        var sections: [Section]
        /// The signature the chapter's annotations must carry to count as current.
        var expectedSignature: String

        var isLarge: Bool { lines > BookAnnotator.largeLines || sections.count > BookAnnotator.largeSections }
        var isCurrent: Bool { summarySignature == expectedSignature }
        var isFrontMatter: Bool {
            ["readme", "index"].contains((((path as NSString).lastPathComponent) as NSString).deletingPathExtension.lowercased())
        }
    }

    struct Book {
        var title: String
        var chapters: [Chapter]
        var language: String

        init(view: ArchView, language: String) {
            self.language = language
            title = view.nodes.first { $0.kind == "root" }?.name ?? "Book"
            let byId = Dictionary(view.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var sectionsByPath: [String: [Section]] = [:]
            for node in view.nodes where node.kind == "section" {
                guard let path = node.path, let parent = node.parent, let line = node.line else { continue }
                var depth = 0
                var up = byId[parent]
                while let p = up, p.kind == "section" { depth += 1; up = p.parent.flatMap { byId[$0] } }
                sectionsByPath[path, default: []].append(Section(id: node.id, parent: parent, title: node.name, line: line,
                                                                 end: node.endLine ?? line, depth: depth))
            }
            chapters = view.nodes.filter { $0.kind == "doc" }.compactMap { node in
                guard let path = node.path else { return nil }
                let part = node.parent.flatMap { byId[$0] }
                return Chapter(id: node.id, path: path, title: node.name, partId: part?.id ?? "d:",
                               partName: part?.path ?? "", lines: node.loc, signature: node.signature,
                               summarySignature: node.summarySignature, hasSummary: !(node.summary ?? "").isEmpty,
                               sections: sectionsByPath[path] ?? [],
                               expectedSignature: (node.signature ?? "") + "|" + language + "|" + promptVersion)
            }
        }
    }

    // MARK: - Windows

    struct Window {
        var index: Int
        var count: Int
        /// 1-based, inclusive.
        var start: Int
        var end: Int
        var sectionIds: [String]
    }

    struct Job {
        var chapter: Chapter
        var window: Window
    }

    /// One window for a chapter that fits; otherwise runs of top-level sections of at most
    /// `windowLines` lines each (a longer single section gets a window of its own and is cut).
    static func windows(for chapter: Chapter) -> [Window] {
        let all = chapter.sections
        func ids(_ start: Int, _ end: Int) -> [String] { all.filter { $0.line >= start && $0.line <= end }.map(\.id) }
        guard chapter.lines > windowLines else {
            return [Window(index: 0, count: 1, start: 1, end: max(1, chapter.lines), sectionIds: all.map(\.id))]
        }
        let top = all.filter { $0.depth == 0 }
        var ranges: [(Int, Int)] = []
        if top.isEmpty {
            var start = 1
            while start <= chapter.lines {
                ranges.append((start, min(start + windowLines - 1, chapter.lines)))
                start += windowLines
            }
        } else {
            var start = 1
            var end = top[0].line - 1
            for section in top {
                let sectionEnd = max(section.end, section.line)
                if end >= start, sectionEnd - start + 1 > windowLines, end >= top[0].line {
                    ranges.append((start, end))
                    start = section.line
                }
                end = sectionEnd
            }
            ranges.append((start, max(end, chapter.lines)))
        }
        return ranges.enumerated().map { index, range in
            Window(index: index, count: ranges.count, start: range.0, end: range.1, sectionIds: ids(range.0, range.1))
        }
    }

    // MARK: - The chapter call

    struct Built {
        var system: String
        var prompt: String
        var schema: [String: Any]
    }

    static func summaryLanguage(_ language: String) -> String {
        language == ActionOutputLanguage.documentLanguage ? "the language of the document" : language
    }

    static func systemPrompt(large: Bool, headless: Bool, summaryLanguage: String) -> String {
        var text = """
        You annotate one chapter of a book assembled from a folder of documents, so a reader sees at a \
        glance what every part of it says without opening it. The book's structure (parts, chapters, \
        sections, their ids and line ranges) is fixed and listed below; you only write the texts.

        CHAPTER SUMMARY: 1–2 sentences that answer "what is this document for and what will I find in \
        it" — the concrete subject, decisions, names, numbers. State the content itself, never describe \
        the document ("this document describes…" is wrong; "Release flow: tag, notarize, publish DMG; \
        rollback by re-tagging" is right).

        For EVERY listed section (by its id) write SUMMARY: 1–2 sentences stating what the section \
        states, decides, lists or defines — the facts ("Tokens expire after 24 h; refresh via \
        /auth/refresh"), not what the section is about ("explains token expiry"). For a section that \
        only holds sub-sections, say what they cover together. IMPORTANCE: critical = the core claims, \
        decisions, interfaces or rules of the chapter; high = needed to understand the subject; normal = \
        supporting detail; low = boilerplate, templates, changelog noise.

        REFS: when a section clearly relies on, continues, specialises or contradicts another section or \
        chapter from the book index (by id), list it with WHY in at most 10 words. Only relations a \
        reader would want to follow next; explicit links in the text are already known — add a ref for \
        them only when the relation is not obvious. At most 4 refs per section; none is fine.
        """
        if large {
            text += """


            ITEMS: this chapter is long, so also list what each section is made of — every discrete thing \
            it enumerates: requirements, decisions, issues, steps, options, API endpoints, commands, \
            settings, terms, questions, risks, named tables or figures. For each item give NAME as written \
            (at most 10 words), TYPE (the category the document itself uses, else the most useful one; \
            2–8 types per section), LINE = the 1-based line where it starts (lines are numbered), SUMMARY \
            of at most 15 words. List every item of a kind — never sample or stop early. Prose paragraphs \
            are not items; leave ITEMS empty for a section with nothing to enumerate.
            """
        }
        if headless {
            text += """


            This document has no headings. Split it yourself into 3–12 SECTIONS in reading order: each \
            with a TITLE (at most 8 words, in the document's language), LINE = the 1-based line it starts \
            on (the first starts at the first line shown; sections do not overlap) and the fields above. \
            Leave id empty.
            """
        }
        text += """


        Titles and item names stay in the language of the document, as written. Write every summary and \
        why in \(summaryLanguage). Keep ids exactly as listed. Return only JSON matching the schema.
        """
        return text
    }

    static var schema: [String: Any] {
        let importance: [String: Any] = ["type": "string", "enum": levels]
        return [
            "type": "object",
            "properties": [
                "chapter": [
                    "type": "object",
                    "properties": ["summary": ["type": "string"], "importance": importance],
                    "required": ["summary", "importance"],
                ],
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Section id from the list; empty when the document has no headings."],
                            "title": ["type": "string", "description": "Only for documents without headings."],
                            "line": ["type": "integer", "description": "Only for documents without headings: 1-based start line."],
                            "summary": ["type": "string"],
                            "importance": importance,
                            "refs": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": ["target": ["type": "string"], "why": ["type": "string"]],
                                    "required": ["target", "why"],
                                ],
                            ],
                            "items": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "name": ["type": "string"], "type": ["type": "string"],
                                        "line": ["type": "integer"], "summary": ["type": "string"],
                                    ],
                                    "required": ["name", "line"],
                                ],
                            ],
                        ],
                        "required": ["summary", "importance", "refs"],
                    ],
                ],
            ],
            "required": ["sections"],
        ]
    }

    /// The prompt for one window of a chapter: the book, the chapter's sections with their lines,
    /// the book index for refs (chapters everywhere; sections of the same part and of the chapters
    /// this one links to, within `indexLines`), then the numbered text.
    static func request(job: Job, book: Book, lines: [String], linked: Set<String> = []) -> Built {
        let chapter = job.chapter
        let window = job.window
        let headless = chapter.sections.isEmpty
        let large = chapter.isLarge || headless
        let partCount = Set(book.chapters.map(\.partId)).count
        var prompt = "Book: \(book.title) — \(book.chapters.count) chapters in \(partCount) parts\n"
        prompt += "Chapter: \(chapter.path) (part: \(chapter.partName.isEmpty ? "(root)" : chapter.partName), \(chapter.lines) lines)\n"
        if window.count > 1 {
            prompt += "Window \(window.index + 1) of \(window.count): lines \(window.start)–\(window.end)."
            prompt += window.index == 0 ? "\n" : " The chapter summary is already written; annotate the listed sections only.\n"
        }
        if headless {
            prompt += "This document has no headings: split it into sections yourself.\n"
        } else {
            prompt += "Sections of this chapter (id | heading | lines), nested by indentation:\n"
            let shown = Set(window.sectionIds)
            for section in chapter.sections where shown.contains(section.id) {
                prompt += String(repeating: "  ", count: section.depth) + "- \(section.id) | \(section.title) | \(section.line)–\(section.end)\n"
            }
        }
        prompt += "\nBook index for REFS (id | title):\n"
        var index: [String] = book.chapters.map { "- \($0.id) | \($0.title)" }
        if index.count > indexLines { index = Array(index.prefix(indexLines)) }
        var budget = indexLines - index.count
        var expanded: [String] = []
        for other in book.chapters where other.id != chapter.id && (other.partId == chapter.partId || linked.contains(other.id)) {
            guard budget > 0, let position = index.firstIndex(of: "- \(other.id) | \(other.title)") else { continue }
            let rows = other.sections.prefix(budget).map { String(repeating: "  ", count: $0.depth + 1) + "- \($0.id) | \($0.title)" }
            budget -= rows.count
            expanded.append(index[position])
            index.replaceSubrange(position...position, with: [index[position]] + rows)
        }
        prompt += index.joined(separator: "\n") + "\n"
        prompt += "\nDocument text (lines are numbered):\nFile: \(chapter.path) (\(chapter.lines) lines)\n"
        let first = max(1, window.start), last = min(lines.count, window.end)
        if first <= last {
            for number in first...min(last, first + windowLines - 1) { prompt += "\(number)| \(lines[number - 1])\n" }
            if last - first + 1 > windowLines { prompt += "… (\(last - first + 1 - windowLines) more lines not shown)\n" }
        }
        return Built(system: systemPrompt(large: large, headless: headless, summaryLanguage: summaryLanguage(book.language)),
                     prompt: prompt, schema: schema)
    }

    /// Whether an answer is worth keeping: the chapter summary (first window) and summaries for
    /// at least half of the listed sections; for a document without headings, at least one
    /// section with a title, a line and a summary (a short one may get the chapter summary only).
    static func isUsable(_ answer: [String: Any], job: Job) -> Bool {
        func clean(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let chapterSummary = clean((answer["chapter"] as? [String: Any])?["summary"])
        if job.window.index == 0, chapterSummary.isEmpty { return false }
        let entries = answer["sections"] as? [[String: Any]] ?? []
        let wanted = Set(job.window.sectionIds)
        if wanted.isEmpty {
            if job.chapter.sections.isEmpty, job.chapter.lines < 40 { return true }
            if job.chapter.sections.isEmpty {
                return entries.contains { !clean($0["title"]).isEmpty && ($0["line"] as? Int ?? 0) >= 1 && !clean($0["summary"]).isEmpty }
            }
            return true
        }
        let answered = Set(entries.compactMap { entry -> String? in
            let id = clean(entry["id"])
            return wanted.contains(id) && !clean(entry["summary"]).isEmpty ? id : nil
        })
        return answered.count * 2 >= wanted.count
    }

    // MARK: - Applying the chapter answer

    struct Applied {
        var view: ArchView
        /// Importance levels by rating key (`p:<path>` for the chapter, section ids for sections).
        var importance: [String: String]
    }

    /// The answer written into the view: summaries, importance, related edges, AI sections for a
    /// document without headings, and items under sections. Unknown ids, self references and
    /// references up or down the same branch are dropped; item lines are clamped into their section.
    static func apply(_ answer: [String: Any], job: Job, to view: ArchView, lines: [String]) -> Applied {
        func clean(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let chapter = job.chapter
        var nodes = view.nodes
        var edges = view.edges
        var importance: [String: String] = [:]
        var position = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func reindex() { position = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        func level(_ value: Any?) -> String? { levels.contains(clean(value)) ? clean(value) : nil }

        // The chapter itself (first window).
        if job.window.index == 0, let i = position[chapter.id] {
            if let object = answer["chapter"] as? [String: Any] {
                let summary = clean(object["summary"])
                if !summary.isEmpty { nodes[i].summary = summary }
                if let value = level(object["importance"]) { importance["p:" + chapter.path] = value }
            }
            nodes[i].summarySignature = chapter.expectedSignature
        }

        let entries = answer["sections"] as? [[String: Any]] ?? []
        var sectionIds = Set(job.window.sectionIds)
        var ranges: [String: (Int, Int)] = Dictionary(chapter.sections.map { ($0.id, ($0.line, $0.end)) }, uniquingKeysWith: { a, _ in a })
        var entryBySection: [String: [String: Any]] = [:]

        if chapter.sections.isEmpty {
            // A document without headings: the AI's sections replace any earlier ones.
            let old = Set(nodes.filter { $0.path == chapter.path && $0.kind != "doc" }.map(\.id))
            nodes.removeAll { old.contains($0.id) }
            edges.removeAll { old.contains($0.source) || old.contains($0.target) }
            var proposed = entries.compactMap { entry -> (title: String, line: Int, entry: [String: Any])? in
                let title = clean(entry["title"])
                guard !title.isEmpty, let line = entry["line"] as? Int else { return nil }
                return (title, min(max(line, 1), max(lines.count, 1)), entry)
            }.sorted { $0.line < $1.line }
            var seen: Set<Int> = []
            proposed = proposed.filter { seen.insert($0.line).inserted }
            let slugs = BookBuilder.uniqueSlugs(proposed.map { BookBuilder.slug($0.title) })
            for (index, item) in proposed.enumerated() {
                let end = index + 1 < proposed.count ? proposed[index + 1].line - 1 : max(lines.count, item.line)
                var node = ArchNode(id: chapter.id + "#" + slugs[index], parent: chapter.id, kind: "section", name: item.title,
                                    path: chapter.path, loc: max(1, end - item.line + 1))
                node.line = item.line
                node.endLine = max(item.line, end)
                node.anchor = lines.indices.contains(item.line - 1) ? XRayContent.anchor(lines[item.line - 1]) : nil
                nodes.append(node)
                sectionIds.insert(node.id)
                ranges[node.id] = (item.line, node.endLine ?? item.line)
                entryBySection[node.id] = item.entry
            }
            reindex()
        } else {
            for entry in entries {
                let id = clean(entry["id"])
                if sectionIds.contains(id) { entryBySection[id] = entry }
            }
        }

        // Earlier AI work on these sections goes: related edges from them and items under them.
        edges.removeAll { $0.kind == "related" && sectionIds.contains($0.source) }
        nodes.removeAll { node in sectionIds.contains { node.id.hasPrefix($0 + "/") } }
        reindex()

        var parentOf = Dictionary(nodes.compactMap { node in node.parent.map { (node.id, $0) } }, uniquingKeysWith: { a, _ in a })
        func isAncestor(_ a: String, of b: String) -> Bool {
            var current = parentOf[b]
            while let c = current { if c == a { return true }; current = parentOf[c] }
            return false
        }

        var added: [ArchNode] = []
        for (sectionId, entry) in entryBySection {
            guard let i = position[sectionId] else { continue }
            let summary = clean(entry["summary"])
            if !summary.isEmpty { nodes[i].summary = summary }
            if let value = level(entry["importance"]) { importance[sectionId] = value }
            for ref in entry["refs"] as? [[String: Any]] ?? [] {
                let target = clean(ref["target"])
                guard position[target] != nil, target != sectionId, !isAncestor(target, of: sectionId), !isAncestor(sectionId, of: target),
                      !edges.contains(where: { $0.source == sectionId && $0.target == target }) else { continue }
                let why = String(clean(ref["why"]).prefix(120))
                edges.append(ArchEdge(source: sectionId, target: target, kind: "related", weight: 1, label: why.isEmpty ? nil : why))
            }
            // Items: only when there are enough to be worth a level.
            let rawItems = entry["items"] as? [[String: Any]] ?? []
            guard rawItems.count >= 4, let range = ranges[sectionId] else { continue }
            var groups: [String: [XRayContent.Item]] = [:]
            var order: [String] = []
            for raw in rawItems {
                let name = clean(raw["name"])
                guard !name.isEmpty else { continue }
                let line = min(max((raw["line"] as? Int) ?? range.0, range.0), max(range.0, range.1))
                let type = clean(raw["type"])
                if groups[type] == nil { order.append(type) }
                let summaryText = clean(raw["summary"])
                groups[type, default: []].append(XRayContent.Item(name: name, line: line, summary: summaryText.isEmpty ? nil : summaryText,
                                                                  anchor: lines.indices.contains(line - 1) ? XRayContent.anchor(lines[line - 1]) : nil))
            }
            let outline = XRayContent.Outline(signature: "", collections: [
                XRayContent.Collection(name: "Items", summary: nil, groups: order.map { XRayContent.Group(name: $0, items: groups[$0] ?? []) }),
            ], source: "ai")
            added += XRayContent.nodes(for: outline, path: chapter.path, fileId: sectionId, idBase: sectionId + "/")
        }
        nodes += added
        for node in added { if let parent = node.parent { parentOf[node.id] = parent } }
        return Applied(view: ArchView(id: view.id, nodes: nodes, edges: edges), importance: importance)
    }

    // MARK: - Parts and the book

    static let partsPerCall = 35

    /// Calls describing the parts (folders) from their chapters' summaries, and the book from
    /// the parts; none when no chapter has a summary yet.
    static func partsRequests(view: ArchView, language: String) -> [Built] {
        let chapters = view.nodes.filter { $0.kind == "doc" }
        guard chapters.contains(where: { !($0.summary ?? "").isEmpty }) else { return [] }
        let title = view.nodes.first { $0.kind == "root" }?.name ?? "Book"
        let byParent = Dictionary(grouping: chapters, by: { $0.parent ?? "d:" })
        let parts = view.nodes.filter { $0.kind == "dir" || $0.kind == "root" }
        var lines: [String] = []
        for part in parts {
            let own = byParent[part.id] ?? []
            let subParts = view.nodes.filter { $0.kind == "dir" && $0.parent == part.id }.map(\.name)
            guard !own.isEmpty || !subParts.isEmpty else { continue }
            var line = "- \(part.id) (\(own.count) chapters"
            if !subParts.isEmpty { line += ", sub-parts: " + subParts.prefix(12).joined(separator: ", ") }
            line += "): "
            line += own.prefix(40).map { chapter -> String in
                let summary = (chapter.summary ?? "").split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? ""
                return "\"\(chapter.name)\"" + (summary.isEmpty ? "" : " — " + summary)
            }.joined(separator: "; ")
            lines.append(line)
        }
        guard !lines.isEmpty else { return [] }
        let chunks = stride(from: 0, to: lines.count, by: partsPerCall).map { Array(lines[$0..<min($0 + partsPerCall, lines.count)]) }
        return chunks.enumerated().map { index, chunk in
            let first = index == 0
            let system = """
            You write the blurb of each PART of a book assembled from a folder of documents: one sentence \
            saying what the documents in that folder establish and when a reader opens it — facts, not \
            "this folder contains". \(first ? "Then the BOOK itself: 2–3 sentences on what the whole documentation covers, for whom, and where to start. " : "")\
            Write in \(summaryLanguage(language)). Keep ids exactly as listed. Return only JSON.
            """
            var properties: [String: Any] = [
                "parts": [
                    "type": "array",
                    "items": ["type": "object", "properties": ["id": ["type": "string"], "summary": ["type": "string"]],
                              "required": ["id", "summary"]],
                ],
            ]
            var required = ["parts"]
            if first {
                properties["book"] = ["type": "object", "properties": ["summary": ["type": "string"]], "required": ["summary"]]
                required.append("book")
            }
            return Built(system: system, prompt: "Book: \(title)\n\nParts:\n" + chunk.joined(separator: "\n"),
                         schema: ["type": "object", "properties": properties, "required": required])
        }
    }

    static func applyParts(_ answer: [String: Any], to view: ArchView) -> ArchView {
        func clean(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var next = view
        var summaries: [String: String] = [:]
        for part in answer["parts"] as? [[String: Any]] ?? [] {
            let id = clean(part["id"]), summary = clean(part["summary"])
            if !id.isEmpty, !summary.isEmpty { summaries[id] = summary }
        }
        let book = clean((answer["book"] as? [String: Any])?["summary"])
        for i in next.nodes.indices {
            if next.nodes[i].kind == "dir", let summary = summaries[next.nodes[i].id] { next.nodes[i].summary = summary }
            if next.nodes[i].kind == "root" {
                if let summary = summaries[next.nodes[i].id] { next.nodes[i].summary = summary }
                if !book.isEmpty { next.nodes[i].summary = book }
            }
        }
        return next
    }
}
