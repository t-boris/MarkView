import Foundation

/// Research documents (feature new-research-repository-grounded-analysis): the file format,
/// its path, the fact/inference label check and the section bookkeeping for follow-ups,
/// retries and comments. Pure (Foundation + FrontMatter) so `tools/tests` can compile it alone.
///
/// Layout (DEC-008): front matter (`type: research`, id, title, question, created, status,
/// web_queries), `# title`, `## Question`, `## Summary`, `## Findings` (every item starts with
/// one label), `## Recommendations`, `## Sources`. Each follow-up is appended after a `---` line
/// as `## Follow-up N: <question> (<date>)`. `> ⚠️ Incomplete: <what failed>` at the top of a
/// section marks it incomplete.
enum ResearchDocument {
    static let folder = "docs/research"
    static let incompletePrefix = "> ⚠️ Incomplete:"

    enum Label: String, CaseIterable {
        case projectFact = "Project fact"
        case externalFact = "External fact"
        case aiInference = "AI inference"
        case openAssumption = "Open assumption"
    }

    // MARK: - Path (DEC-006)

    /// A file-name slug of the question: Latin letters and digits, at most 8 words and 60
    /// characters. Other scripts are transliterated; "research" when nothing is left.
    static func slug(_ question: String) -> String {
        let latin = question.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? question
        let mapped = latin.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var slug = String(mapped).split(separator: "-").prefix(8).joined(separator: "-")
        if slug.count > 60 {
            slug = String(slug.prefix(60))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "research" : slug
    }

    /// `docs/research/<date>-<slug>.md`, with `-2`, `-3`, … when `exists` reports the path taken.
    static func relativePath(question: String, date: String, exists: (String) -> Bool) -> String {
        let base = "\(folder)/\(date)-\(slug(question))"
        if !exists(base + ".md") { return base + ".md" }
        var n = 2
        while exists("\(base)-\(n).md") { n += 1 }
        return "\(base)-\(n).md"
    }

    /// The document id: its file name without the extension.
    static func id(forPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Detection (DEC-007)

    /// True for any Markdown whose front matter says `type: research`, wherever it lives.
    static func isResearch(_ text: String) -> Bool {
        FrontMatter.split(text).0.string("type") == "research"
    }

    // MARK: - The AI's answer

    /// The sections the AI writes; the app adds the front matter, title, question and sources.
    struct Answer: Equatable {
        var summary = ""
        var findings: [String] = []
        var recommendations = ""
    }

    /// Reads `Summary`, `Findings` and `Recommendations` headings (any level) from the answer.
    /// Text before the first of them is the agent's narration and is dropped; an answer without
    /// any of them (e.g. cut off early) counts as a summary.
    static func parseAnswer(_ markdown: String) -> Answer {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var parts: [String: [String]] = [:]
        var current: String?
        var sawHeading = false
        for line in lines {
            if let key = answerHeading(line) {
                current = key
                sawHeading = true
                continue
            }
            if let current { parts[current, default: []].append(line) }
        }
        func text(_ key: String) -> String {
            (parts[key] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard sawHeading else {
            return Answer(summary: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Answer(summary: text("summary"), findings: listItems(text("findings")),
                      recommendations: text("recommendations"))
    }

    private static func answerHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
        for key in ["summary", "findings", "recommendations", "sources"] where title == key || title.hasPrefix(key + " ") || title.hasPrefix(key + ":") {
            return key
        }
        return nil
    }

    /// Items of a Markdown list; lines that are not item starts continue the previous item,
    /// and a paragraph before the first item becomes an item of its own.
    static func listItems(_ markdown: String) -> [String] {
        var items: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent < 2, let content = itemContent(trimmed) {
                items.append(content)
            } else if items.isEmpty {
                items.append(trimmed)
            } else {
                items[items.count - 1] += "\n  " + trimmed
            }
        }
        return items
    }

    private static func itemContent(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        let digits = trimmed.prefix { $0.isNumber }
        let rest = trimmed.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        return nil
    }

    // MARK: - Label check (REQ-004)

    /// One finding after the check: exactly one label at the start; a project fact cites an
    /// existing repository path, an external fact a URL. Anything else becomes an AI inference,
    /// with a short note saying why.
    static func checkedFinding(_ item: String, pathExists: (String) -> Bool) -> (text: String, relabelled: Bool) {
        var rest = Substring(item.trimmingCharacters(in: .whitespaces))
        var labels: [Label] = []
        while let (label, after) = leadingLabel(rest) {
            labels.append(label)
            rest = after
        }
        let body = rest.trimmingCharacters(in: .whitespaces)
        let note: String?
        switch labels.count == 1 ? labels[0] : nil {
        case .projectFact?:
            note = citedPaths(body, pathExists: pathExists).isEmpty ? "no repository file cited" : nil
        case .externalFact?:
            note = citedURLs(body).isEmpty ? "no source URL cited" : nil
        case .aiInference?, .openAssumption?:
            note = nil
        case nil:
            note = labels.isEmpty ? "no label given" : "more than one label given"
        }
        guard let note else { return ("[\(labels[0].rawValue)] \(body)", false) }
        return ("[\(Label.aiInference.rawValue)] \(body) *(labelled as inference: \(note))*", true)
    }

    /// The label at the start of `text` (also `**[Label]**`), and the text after it.
    private static func leadingLabel(_ text: Substring) -> (Label, Substring)? {
        var s = text.drop { $0 == " " }
        let bold = s.hasPrefix("**")
        if bold { s = s.dropFirst(2) }
        guard s.hasPrefix("[") else { return nil }
        for label in Label.allCases {
            let token = "[" + label.rawValue + "]"
            guard s.lowercased().hasPrefix(token.lowercased()) else { continue }
            var after = s.dropFirst(token.count)
            if bold, after.hasPrefix("**") { after = after.dropFirst(2) }
            if after.hasPrefix(":") { after = after.dropFirst() }
            return (label, after.drop { $0 == " " })
        }
        return nil
    }

    /// Repository paths cited in `text` (plain, in backticks or as link targets), `:line` removed,
    /// kept only when `pathExists` confirms them.
    static func citedPaths(_ text: String, pathExists: (String) -> Bool) -> [String] {
        var found: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-/@+~"))
        var token = ""
        func flush() {
            var candidate = token
            token = ""
            while candidate.hasPrefix("./") { candidate.removeFirst(2) }
            while let last = candidate.last, ".-/".contains(last) { candidate.removeLast() }
            guard candidate.contains("/") || candidate.contains("."), !candidate.contains("://"),
                  !found.contains(candidate), pathExists(candidate) else { return }
            found.append(candidate)
        }
        for scalar in text.unicodeScalars {
            if allowed.contains(scalar) { token.unicodeScalars.append(scalar) } else { flush() }
        }
        flush()
        return found
    }

    /// `http(s)://` URLs in `text`, without trailing punctuation.
    static func citedURLs(_ text: String) -> [String] {
        var urls: [String] = []
        for word in text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'"))) {
            guard let start = word.range(of: "https://") ?? word.range(of: "http://") else { continue }
            var url = String(word[start.lowerBound...])
            while let last = url.last, ".,;:)]*`".contains(last) {
                if last == ")", url.filter({ $0 == "(" }).count >= url.filter({ $0 == ")" }).count { break }
                url.removeLast()
            }
            if url.count > 10, !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    /// Checks every list item under a Findings heading in `markdown` (a revised section), and
    /// every other item that starts with a label; unlabelled items outside Findings stay as they are.
    static func checkingLabels(in markdown: String, pathExists: (String) -> Bool) -> String {
        var out: [String] = []
        var inFindings = false
        var pending: [String] = []
        func flushItem() {
            guard let first = pending.first else { return }
            let indent = String(first.prefix { $0 == " " })
            let marker = itemMarker(first.trimmingCharacters(in: .whitespaces)) ?? "- "
            let joined = ([String(first.trimmingCharacters(in: .whitespaces).dropFirst(marker.count))]
                + pending.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: "\n  ")
            let labelled = leadingLabel(Substring(joined)) != nil
            if inFindings || labelled {
                out.append(indent + marker + checkedFinding(joined, pathExists: pathExists).text)
            } else {
                out.append(contentsOf: pending)
            }
            pending = []
        }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flushItem()
                inFindings = answerHeading(line) == "findings"
                out.append(line)
            } else if line.prefix(while: { $0 == " " }).count < 2, itemMarker(trimmed) != nil {
                flushItem()
                pending = [line]
            } else if !pending.isEmpty, !trimmed.isEmpty {
                pending.append(line)
            } else {
                flushItem()
                out.append(line)
            }
        }
        flushItem()
        return out.joined(separator: "\n")
    }

    private static func itemMarker(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) { return marker }
        let digits = trimmed.prefix { $0.isNumber }
        let rest = trimmed.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(digits) + String(rest.prefix(2)) }
        return nil
    }

    // MARK: - Rendering

    /// What one run produced, ready to be written as a document or a follow-up section.
    struct Run {
        var question: String
        var answer: Answer
        /// Why the run is incomplete (cancelled, failed, timed out, no web search); nil when it finished.
        var incomplete: String?
        var targets: [String] = []
        /// Workspace-relative files the agent read.
        var filesRead: [String] = []
        var urlsFetched: [String] = []
        var webQueries: [String] = []
        var attachments: [String] = []
        /// "Web search: disabled for this repository." and similar notes for Sources.
        var notes: [String] = []
        /// No eligible project files: the Summary says so (DEC-016).
        var noProjectFiles = false
    }

    /// A new research document (front matter + body).
    static func newDocument(id: String, title: String, created: String, run: Run, pathExists: (String) -> Bool) -> String {
        var front = FrontMatter()
        front.set("type", "research")
        front.set("id", id)
        front.set("title", title)
        front.set("question", run.question)
        front.set("created", created)
        front.set("status", run.incomplete == nil ? "complete" : "incomplete")
        front.set("web_queries", list: run.webQueries)
        if !run.targets.isEmpty { front.set("targets", list: run.targets) }
        var body = "# \(title)\n\n"
        if let why = run.incomplete { body += "\(incompletePrefix) \(why)\n\n" }
        body += "## Question\n\n\(run.question)\n\n"
        if !run.targets.isEmpty {
            body += "Target documents: " + run.targets.map { "`\($0)`" }.joined(separator: ", ") + "\n\n"
        }
        body += content(run, level: 2, withSummaryHeading: true, pathExists: pathExists)
        return front.join(body: body)
    }

    /// `## Follow-up N: <question> (<date>)` with its answer, Findings, Recommendations and Sources.
    /// `retryOf` names the incomplete section it retries ("original research" or "Follow-up 2").
    static func followUpSection(number: Int, date: String, retryOf: String?, run: Run, pathExists: (String) -> Bool) -> String {
        let question = run.question.replacingOccurrences(of: "\n", with: " ")
        var section = "## Follow-up \(number): \(question) (\(date))\n\n"
        if let why = run.incomplete { section += "\(incompletePrefix) \(why)\n\n" }
        if let retryOf { section += "*Retry of the incomplete \(retryOf).*\n\n" }
        if run.question.contains("\n") { section += "> " + run.question.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
        section += content(run, level: 3, withSummaryHeading: false, pathExists: pathExists)
        return section
    }

    private static func content(_ run: Run, level: Int, withSummaryHeading: Bool, pathExists: (String) -> Bool) -> String {
        let h = String(repeating: "#", count: level)
        var out = ""
        var summary = run.answer.summary
        if run.noProjectFiles {
            summary = "No project facts were available: the repository has no files in the analysis scope."
                + (summary.isEmpty ? "" : "\n\n" + summary)
        }
        if withSummaryHeading { out += "\(h) Summary\n\n" }
        out += (summary.isEmpty ? "*No summary was produced.*" : summary) + "\n\n"
        out += "\(h) Findings\n\n"
        let findings = run.answer.findings.map { checkedFinding($0, pathExists: pathExists).text }
        out += findings.isEmpty ? "*No findings were produced.*\n\n" : findings.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        out += "\(h) Recommendations\n\n"
        out += (run.answer.recommendations.isEmpty ? "*No recommendations were produced.*" : run.answer.recommendations) + "\n\n"
        out += "\(h) Sources\n\n" + sources(run, pathExists: pathExists)
        return out
    }

    /// Files and URLs cited anywhere in the answer, plus what the agent read, fetched and searched.
    private static func sources(_ run: Run, pathExists: (String) -> Bool) -> String {
        let answerText = ([run.answer.summary] + run.answer.findings + [run.answer.recommendations]).joined(separator: "\n")
        var files: [String] = []
        for path in run.targets + citedPaths(answerText, pathExists: pathExists) + run.filesRead where !files.contains(path) {
            files.append(path)
        }
        var urls: [String] = []
        for url in citedURLs(answerText) + run.urlsFetched where !urls.contains(url) { urls.append(url) }
        var out = ""
        if !files.isEmpty { out += "Project files:\n\n" + files.map { "- `\($0)`" }.joined(separator: "\n") + "\n\n" }
        if !run.attachments.isEmpty { out += "Attachments:\n\n" + run.attachments.map { "- `\($0)`" }.joined(separator: "\n") + "\n\n" }
        if !urls.isEmpty { out += "Web pages:\n\n" + urls.map { "- <\($0)>" }.joined(separator: "\n") + "\n\n" }
        if !run.webQueries.isEmpty { out += "Web searches:\n\n" + run.webQueries.map { "- \"\($0)\"" }.joined(separator: "\n") + "\n\n" }
        for note in run.notes { out += note + "\n\n" }
        return out.isEmpty ? "*No sources were used.*\n" : out
    }

    // MARK: - Sections, follow-ups, status (DEC-013, DEC-014)

    struct Section: Equatable {
        /// "original research" or "Follow-up N".
        var name: String
        var number: Int
        var question: String
        var incomplete: Bool
        /// The section this one retries ("original research" / "Follow-up N").
        var retryOf: String?
        /// The section's text, for a retry's context.
        var text: String
    }

    /// The original research and each follow-up of a document body (front matter removed).
    static func sections(_ text: String) -> [Section] {
        let (front, body) = FrontMatter.split(text)
        let lines = body.components(separatedBy: "\n")
        var starts: [(line: Int, number: Int, question: String)] = []
        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("## Follow-up "), let colon = line.firstIndex(of: ":") else { continue }
            let number = Int(line.dropFirst("## Follow-up ".count).prefix { $0.isNumber }) ?? 0
            var question = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if question.hasSuffix(")"), let open = question.range(of: " (", options: .backwards) {
                question = String(question[..<open.lowerBound])
            }
            starts.append((i, number, question))
        }
        func make(_ name: String, _ number: Int, _ question: String, _ range: Range<Int>) -> Section {
            let part = Array(lines[range])
            let text = part.joined(separator: "\n").trimmingCharacters(in: .newlines)
            var retry: String?
            for line in part {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("*Retry of the incomplete "), t.hasSuffix(".*") {
                    retry = String(t.dropFirst("*Retry of the incomplete ".count).dropLast(2))
                }
            }
            return Section(name: name, number: number, question: question,
                           incomplete: part.contains { $0.hasPrefix(incompletePrefix) }, retryOf: retry, text: text)
        }
        var result = [make("original research", 0, front.string("question"), 0..<(starts.first?.line ?? lines.count))]
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].line : lines.count
            result.append(make("Follow-up \(start.number)", start.number, start.question, start.line..<end))
        }
        return result
    }

    /// A section counts as resolved when it finished, or a later retry of it is resolved.
    static func unresolved(_ sections: [Section]) -> [Section] {
        func resolved(_ index: Int) -> Bool {
            let section = sections[index]
            if !section.incomplete { return true }
            return sections.indices.contains { $0 > index && sections[$0].retryOf == section.name && resolved($0) }
        }
        return sections.indices.filter { !resolved($0) }.map { sections[$0] }
    }

    static func status(_ text: String) -> String {
        unresolved(sections(text)).isEmpty ? "complete" : "incomplete"
    }

    static func nextFollowUpNumber(_ text: String) -> Int {
        (sections(text).map(\.number).max() ?? 0) + 1
    }

    /// Appends a follow-up section to the document as it is now (DEC-014): earlier content
    /// stays; only front matter `status` and `web_queries` change. Nil when the front matter
    /// cannot be written back without loss.
    static func appending(_ section: String, to text: String, webQueries: [String]) -> String? {
        let (front, body) = FrontMatter.split(text)
        guard front.isLossless else { return nil }
        let appended = body.trimmingCharacters(in: .newlines) + "\n\n---\n\n" + section
        return updatingFront(front, body: appended, webQueries: webQueries)
    }

    /// Replaces `range` of `text` (a section found by `enclosingSection`) with `revised` (DEC-017),
    /// updating status and web queries the same way. Nil when the front matter is not lossless.
    static func replacing(_ range: Range<String.Index>, in text: String, with revised: String, webQueries: [String]) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let (front, _) = FrontMatter.split(normalized)
        guard front.isLossless else { return nil }
        var replaced = normalized
        let tail = normalized[range.upperBound...]
        replaced.replaceSubrange(range, with: revised.trimmingCharacters(in: .newlines) + (tail.isEmpty ? "\n" : "\n\n"))
        let (_, body) = FrontMatter.split(replaced)
        return updatingFront(front, body: body, webQueries: webQueries)
    }

    private static func updatingFront(_ front: FrontMatter, body: String, webQueries: [String]) -> String {
        var front = front
        var queries = front.strings("web_queries")
        for query in webQueries where !queries.contains(query) { queries.append(query) }
        front.set("web_queries", list: queries)
        let draft = front.join(body: body)
        front.set("status", status(draft))
        return front.join(body: body)
    }

    // MARK: - Comments (DEC-017)

    /// The smallest heading-bounded section of `text` whose text contains `passage` (compared
    /// without Markdown syntax, case and spacing, since the selection comes from the rendered
    /// view). The range runs from the heading line to the next heading of the same or a higher
    /// level; front matter is never part of it.
    static func enclosingSection(of passage: String, in text: String) -> Range<String.Index>? {
        let needle = plain(passage)
        guard !needle.isEmpty else { return nil }
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lineStarts: [String.Index] = []
        var index = text.startIndex
        lineStarts.append(index)
        while let newline = text[index...].firstIndex(of: "\n") {
            index = text.index(after: newline)
            lineStarts.append(index)
        }
        func line(_ i: Int) -> Substring {
            let end = i + 1 < lineStarts.count ? text.index(before: lineStarts[i + 1]) : text.endIndex
            return text[lineStarts[i]..<end]
        }
        // Skip front matter.
        var first = 0
        if line(0).trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lineStarts.count, line(i).trimmingCharacters(in: .whitespaces) != "---" { i += 1 }
            first = min(i + 1, lineStarts.count)
        }
        var headings: [(line: Int, level: Int)] = []
        var inFence = false
        for i in first..<lineStarts.count {
            let l = line(i)
            if l.hasPrefix("```") { inFence.toggle() }
            guard !inFence, l.hasPrefix("#") else { continue }
            let level = l.prefix { $0 == "#" }.count
            if level <= 6, l.dropFirst(level).hasPrefix(" ") { headings.append((i, level)) }
        }
        var best: Range<String.Index>?
        for (k, heading) in headings.enumerated() {
            let endLine = headings[(k + 1)...].first { $0.level <= heading.level }?.line
            let end = endLine.map { lineStarts[$0] } ?? text.endIndex
            let range = lineStarts[heading.line]..<end
            guard plain(String(text[range])).contains(needle) else { continue }
            if best == nil || text.distance(from: range.lowerBound, to: range.upperBound)
                < text.distance(from: best!.lowerBound, to: best!.upperBound) {
                best = range
            }
        }
        return best
    }

    /// Text without Markdown link targets, emphasis/heading/list/quote syntax, case and extra spacing.
    static func plain(_ markdown: String) -> String {
        var s = markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return "" }
            return itemMarker(trimmed).map { String(trimmed.dropFirst($0.count)) } ?? trimmed
        }.joined(separator: "\n")
        while let open = s.range(of: "]("), let close = s[open.upperBound...].firstIndex(of: ")") {
            s.replaceSubrange(open.lowerBound...close, with: "]")
        }
        // The rendered view shows typographic punctuation for the source's plain one.
        for (fancy, simple) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("…", "..."), ("\u{00A0}", " ")] {
            s = s.replacingOccurrences(of: fancy, with: simple)
        }
        // Inline markers vanish ("[app]." stays "app."), block markers separate words.
        let inline = CharacterSet(charactersIn: "*_`[]"), block = CharacterSet(charactersIn: "#>|")
        s = String(String.UnicodeScalarView(s.unicodeScalars.compactMap { inline.contains($0) ? nil : block.contains($0) ? " " : $0 }))
        return s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
