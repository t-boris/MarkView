import Foundation

/// The Book X-Ray's skeleton, built from a folder's text documents without any AI: the folders
/// are the book's parts, the documents its chapters, the headings its sections (nested by level,
/// each with the lines it spans), and the links in the text its cross-references, resolved down
/// to the section they point at. `BookAnnotator` later adds what the AI writes (summaries,
/// related sections, the items a large chapter is made of); nothing here depends on it.
///
/// Foundation only: `tools/tests/book-xray-tests.sh` compiles this file on its own.
enum BookBuilder {

    // MARK: - Text documents

    enum Format: String {
        case markdown, asciidoc, rst, org, plain
    }

    /// Extensions of the documents that become chapters. Markdown is listed here as well as in
    /// `FileType.markdownExtensions` so this module stays self-contained.
    private static let formats: [String: Format] = [
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "adoc": .asciidoc, "asciidoc": .asciidoc,
        "rst": .rst,
        "org": .org,
        "txt": .plain, "text": .plain,
    ]

    /// Extensions tried, in this order, when a link names a document without one.
    static let linkExtensions = ["md", "markdown", "mdown", "mkd", "adoc", "asciidoc", "rst", "org", "txt", "text"]

    /// The format of a text document, or nil when `path` is not one. Build and tooling files
    /// that happen to end in `.txt` are not chapters.
    static func format(of path: String) -> Format? {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard let format = formats[ext] else { return nil }
        if format == .plain {
            let lower = name.lowercased()
            if lower == "cmakelists.txt" || lower == "robots.txt" || lower.hasPrefix("requirements")
                || lower.hasPrefix("manifest") || lower.hasPrefix("cname") { return nil }
        }
        return format
    }

    static func isTextDocument(_ path: String) -> Bool { format(of: path) != nil }

    // MARK: - Headings

    struct Heading: Equatable {
        var level: Int
        var title: String
        /// 1-based.
        var line: Int
    }

    /// Headings of a document in reading order, with 1-based lines. Markdown: ATX (`## x`) and
    /// Setext (`===`/`---` underlines) outside fences and front matter. AsciiDoc: `== x`.
    /// reStructuredText: under- and overlined titles, levels by first-seen adornment. Org: `** x`.
    static func headings(of text: String, format: Format) -> [Heading] {
        let lines = text.editorLines.map(String.init)
        switch format {
        case .markdown: return markdownHeadings(lines)
        case .asciidoc: return asciidocHeadings(lines)
        case .rst: return rstHeadings(lines)
        case .org: return orgHeadings(lines)
        case .plain: return []
        }
    }

    private static func markdownHeadings(_ lines: [String]) -> [Heading] {
        var result: [Heading] = []
        var fence: Character?
        var index = 0
        // YAML front matter: a `---` on the first line up to the next `---`.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                index = close + 1
            }
        }
        var previous = ""   // the line before, for Setext underlines
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            defer { previous = trimmed; index += 1 }
            if let marker = trimmed.first, marker == "`" || marker == "~",
               trimmed.count >= 3, trimmed.prefix(3).allSatisfy({ $0 == marker }) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            guard fence == nil else { continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.count > hashes, trimmed.dropFirst(hashes).first == " " {
                let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                if !title.isEmpty { result.append(Heading(level: hashes, title: title, line: index + 1)) }
                continue
            }
            // Setext: a run of = or - under a plain text line.
            if trimmed.count >= 3, let marker = trimmed.first, marker == "=" || marker == "-",
               trimmed.allSatisfy({ $0 == marker }), !previous.isEmpty, isSetextText(previous) {
                result.append(Heading(level: marker == "=" ? 1 : 2, title: previous, line: index))
            }
        }
        return result
    }

    /// A line that can carry a Setext underline: not a list item, table row, heading, quote or rule.
    private static func isSetextText(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if "#>|-*+=`~".contains(first) { return false }
        if line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func asciidocHeadings(_ lines: [String]) -> [Heading] {
        var result: [Heading] = []
        var block: String?
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // Listing, literal and fenced blocks: `----`, `....`, ```` ``` ````.
            if trimmed.count >= 3, let marker = trimmed.first, "-.`".contains(marker), trimmed.allSatisfy({ $0 == marker }) {
                if block == nil { block = trimmed } else if block == trimmed { block = nil }
                continue
            }
            guard block == nil else { continue }
            let equals = trimmed.prefix(while: { $0 == "=" }).count
            guard (1...6).contains(equals), trimmed.count > equals, trimmed.dropFirst(equals).first == " " else { continue }
            let title = trimmed.dropFirst(equals).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { result.append(Heading(level: equals, title: title, line: index + 1)) }
        }
        return result
    }

    private static func rstHeadings(_ lines: [String]) -> [Heading] {
        var result: [Heading] = []
        var levels: [String] = []   // adornment keys in order of first appearance
        let adornment = CharacterSet(charactersIn: "=-`:'\"~^_*+#<>")
        func isAdornment(_ line: String) -> Character? {
            guard line.count >= 3, let first = line.first, first.unicodeScalars.allSatisfy(adornment.contains),
                  line.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            // Title with an underline on the next line (optionally an overline on the one before).
            if !trimmed.isEmpty, isAdornment(trimmed) == nil, index + 1 < lines.count,
               let marker = isAdornment(lines[index + 1].trimmingCharacters(in: .whitespaces)),
               lines[index + 1].trimmingCharacters(in: .whitespaces).count >= trimmed.count {
                let over = index > 0 && isAdornment(lines[index - 1].trimmingCharacters(in: .whitespaces)) == marker
                let key = (over ? "over" : "") + String(marker)
                if !levels.contains(key) { levels.append(key) }
                result.append(Heading(level: levels.firstIndex(of: key)! + 1, title: trimmed, line: index + 1))
                index += 2
                continue
            }
            index += 1
        }
        return result
    }

    private static func orgHeadings(_ lines: [String]) -> [Heading] {
        var result: [Heading] = []
        var inBlock = false
        for (index, raw) in lines.enumerated() {
            let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if upper.hasPrefix("#+BEGIN_") { inBlock = true; continue }
            if upper.hasPrefix("#+END_") { inBlock = false; continue }
            guard !inBlock else { continue }
            let stars = raw.prefix(while: { $0 == "*" }).count
            guard (1...6).contains(stars), raw.count > stars, raw.dropFirst(stars).first == " " else { continue }
            let title = raw.dropFirst(stars).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { result.append(Heading(level: stars, title: title, line: index + 1)) }
        }
        return result
    }

    // MARK: - Slugs

    /// A heading as plain text: links keep their text, code spans their code; emphasis, HTML tags
    /// and trailing hashes go.
    static func plainTitle(_ title: String) -> String {
        var text = title
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]"#, with: "$1", options: .regularExpression)
        // HTML tags go; placeholders like `<version>` are text.
        text = text.replacingOccurrences(of: #"</?(?:a|b|i|u|s|q|em|strong|code|kbd|sup|sub|span|div|p|br|hr|img|small|big|del|ins|mark|abbr|cite|dfn|var|samp|tt|font|center|details|summary|table|tr|td|th|thead|tbody|ul|ol|li|dl|dt|dd|h[1-6]|pre|blockquote|section|article|nav|header|footer|figure|figcaption|picture|source|video|audio|iframe|input|button|label|select|option|form)\b[^>]*>|<!--.*?-->"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(^|\s)_+|_+(\s|$)"#, with: "$1$2", options: .regularExpression)
        text = text.filter { !"*`~".contains($0) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// GitHub's heading anchor: lowercase, letters, digits, `-` and `_` kept from any script
    /// (so "Сборка и релиз" → "сборка-и-релиз"), spaces → `-`, everything else dropped.
    static func slug(_ title: String) -> String {
        var out = ""
        for character in plainTitle(title).lowercased() {
            if character == " " { out.append("-") }
            else if character == "-" || character == "_" || character.isLetter || character.isNumber { out.append(character) }
        }
        return out
    }

    /// Slugs made unique the way GitHub does: the second "setup" is "setup-1", the third "setup-2".
    static func uniqueSlugs(_ slugs: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return slugs.map { slug in
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            return count == 0 ? slug : "\(slug)-\(count)"
        }
    }

    // MARK: - Chapters and sections

    /// Most section nodes a chapter gets; deeper levels are dropped first beyond it.
    static let maxSections = 300

    struct Section: Equatable {
        var id: String
        var parent: String
        var title: String
        var slug: String
        var level: Int
        /// 1-based first and last line.
        var start: Int
        var end: Int
        var anchor: String?
        /// The section's first paragraph, as a provisional description until the AI writes one.
        var lead: String?

        var loc: Int { max(1, end - start + 1) }
    }

    struct Chapter {
        var id: String
        var path: String
        var title: String
        /// Folder path, "" at the root.
        var part: String
        var format: Format
        var lines: Int
        /// SHA-256 of the text (24 hex): the AI's annotations are keyed by it.
        var signature: String
        /// Depth-first, in document order; `parent` is a section id or the chapter id.
        var sections: [Section]
        /// Every heading slug (kept or dropped by the cap) → the node a link to it lands on.
        var anchors: [String: String]
        var hasHeadings: Bool
        /// The links the text makes, with their lines.
        var links: [Link] = []
        /// The document's first paragraph (or its front matter summary): a provisional description.
        var lead: String?

        /// The innermost section that contains `line`, or nil when none does.
        func section(containing line: Int) -> Section? {
            sections.filter { $0.start <= line && line <= $0.end }.max { a, b in
                a.start != b.start ? a.start < b.start : a.level < b.level
            }
        }
    }

    static func chapterId(_ path: String) -> String { "d:" + path }
    static func partId(_ dir: String) -> String { dir.isEmpty ? "d:" : "d:" + dir + "/" }

    /// A document as a chapter: its title, its sections nested by heading level with the lines
    /// they span, and where each heading slug leads.
    static func chapter(path: String, text: String) -> Chapter {
        let format = Self.format(of: path) ?? .markdown
        let lines = text.editorLines.map(String.init)
        let lineCount = lines.count
        let headings = Self.headings(of: text, format: format)
        let id = chapterId(path)
        let fileTitle = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var chapter = Chapter(id: id, path: path, title: fileTitle, part: (path as NSString).deletingLastPathComponent,
                              format: format, lines: lineCount, signature: String(ContentHash.of(text).prefix(24)),
                              sections: [], anchors: [:], hasHeadings: !headings.isEmpty)
        let slugs = uniqueSlugs(headings.map { slug($0.title) })
        let front = format == .markdown ? frontMatter(lines) : (fields: [:], end: 0)

        // A single leading H1 is the document's title, not a section; else the front matter's title.
        var titleIndex: Int?
        if let first = headings.first, first.level == 1, headings.filter({ $0.level == 1 }).count == 1 {
            titleIndex = 0
            chapter.title = plainTitle(first.title)
            chapter.anchors[slugs[0]] = id
        } else if let title = front.fields["title"], !title.isEmpty {
            chapter.title = title
        }

        // Levels beyond the cap are dropped, deepest first.
        var kept = Set(headings.indices.filter { $0 != titleIndex })
        var maxLevel = headings.map(\.level).max() ?? 0
        while kept.count > maxSections, maxLevel > 1 {
            kept = kept.filter { headings[$0].level < maxLevel }
            maxLevel -= 1
        }

        var stack: [(level: Int, id: String)] = []
        var sections: [Section] = []
        for (index, heading) in headings.enumerated() {
            if index == titleIndex { continue }
            let next = headings[(index + 1)...].first { $0.level <= heading.level }
            let end = (next?.line ?? lineCount + 1) - 1
            while let top = stack.last, top.level >= heading.level { stack.removeLast() }
            let parent = stack.last?.id ?? id
            guard kept.contains(index) else {
                // A dropped heading leads to the nearest kept ancestor.
                chapter.anchors[slugs[index]] = parent
                continue
            }
            let sectionId = id + "#" + slugs[index]
            sections.append(Section(id: sectionId, parent: parent, title: plainTitle(heading.title), slug: slugs[index],
                                    level: heading.level, start: heading.line, end: max(heading.line, end),
                                    anchor: anchorText(heading.title), lead: lead(lines, from: heading.line + 1, to: end)))
            chapter.anchors[slugs[index]] = sectionId
            stack.append((heading.level, sectionId))
        }
        chapter.sections = sections
        chapter.links = links(in: text, format: format)
        // What the document says, before the AI: its front matter summary, else its first paragraph,
        // else the first paragraph of its first section.
        let firstSection = sections.first?.start ?? (lineCount + 1)
        chapter.lead = front.fields["summary"] ?? front.fields["description"]
            ?? lead(lines, from: front.end + 1, to: firstSection - 1)
            ?? sections.first?.lead
        return chapter
    }

    /// `key: value` fields of a leading YAML front matter block and the 1-based line of its closing
    /// `---` (0 when there is none). Values keep their text; quotes are dropped.
    static func frontMatter(_ lines: [String]) -> (fields: [String: String], end: Int) {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], 0)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return (fields, close + 1)
    }

    /// The first paragraph of prose between `start` and `end` (1-based, inclusive): headings,
    /// fences, tables, images and comments skipped, list markers and markup removed, cut at `limit`.
    static func lead(_ lines: [String], from start: Int, to end: Int, limit: Int = 200) -> String? {
        var paragraph: [String] = []
        var fence: Character?
        var index = max(1, start)
        while index <= min(end, lines.count) {
            let trimmed = lines[index - 1].trimmingCharacters(in: .whitespaces)
            index += 1
            if let marker = trimmed.first, marker == "`" || marker == "~",
               trimmed.count >= 3, trimmed.prefix(3).allSatisfy({ $0 == marker }) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                if !paragraph.isEmpty { break }
                continue
            }
            guard fence == nil else { continue }
            if trimmed.isEmpty { if paragraph.isEmpty { continue } else { break } }
            let skip = trimmed.hasPrefix("#") || trimmed.hasPrefix("|") || trimmed.hasPrefix("<!--") || trimmed.hasPrefix("![")
                || trimmed.hasPrefix("<") || trimmed.allSatisfy({ "=-*_".contains($0) })
            if skip { if paragraph.isEmpty { continue } else { break } }
            var text = trimmed.replacingOccurrences(of: #"^(?:[-*+]|\d+[.)]|>)\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            text = plainTitle(text).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { paragraph.append(text) }
            if paragraph.joined(separator: " ").count >= limit { break }
        }
        let joined = paragraph.joined(separator: " ")
        guard joined.count >= 3 else { return nil }
        if joined.count <= limit { return joined }
        var cut = String(joined.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 { cut = String(cut[..<space]) }
        return cut + "…"
    }

    /// The heading as rendered, to find it in a preview (`scrollToText`).
    static func anchorText(_ title: String) -> String? {
        let text = plainTitle(title).filter { !"|>".contains($0) }.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { return nil }
        return String(text.prefix(60))
    }

    // MARK: - Links

    struct Link: Equatable {
        /// 1-based line the link is on.
        var line: Int
        /// Path as written (percent-decoded), "" for a link within the same document.
        var target: String
        /// The `#fragment`, or a wiki-link's heading, without the `#`.
        var fragment: String?
        /// `[[Note]]`: resolved from the book root or by file name, not relative to the document.
        var wiki: Bool
    }

    private static let inlineLink = try! NSRegularExpression(pattern: #"(!?)\[[^\]]*\]\(\s*<?([^)\s>]*)>?(?:\s+"[^"]*")?\s*\)"#)
    private static let referenceUse = try! NSRegularExpression(pattern: #"(!?)\[([^\]]+)\]\[([^\]]*)\]"#)
    private static let referenceDefinition = try! NSRegularExpression(pattern: #"^\s{0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s|$)"#)
    private static let wikiLink = try! NSRegularExpression(pattern: #"\[\[([^\]|#]*)(?:#([^\]|]+))?(?:\|[^\]]*)?\]\]"#)
    private static let asciidocLink = try! NSRegularExpression(pattern: #"(?:xref|link):([^\[\s]+)\["#)
    private static let rstLink = try! NSRegularExpression(pattern: #"<([^>\s]+)>`_"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"`[^`]*`"#)

    /// The links a document makes, with the line each is on. Images, code spans, fenced blocks
    /// and external targets (`http:`, `mailto:`) are left out.
    static func links(in text: String, format: Format) -> [Link] {
        let lines = text.editorLines.map(String.init)
        var definitions: [String: String] = [:]
        if format == .markdown {
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                if let match = referenceDefinition.firstMatch(in: line, range: range),
                   let idRange = Range(match.range(at: 1), in: line), let urlRange = Range(match.range(at: 2), in: line) {
                    definitions[line[idRange].lowercased()] = String(line[urlRange])
                }
            }
        }
        var result: [Link] = []
        var fence: Character?
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~",
               trimmed.count >= 3, trimmed.prefix(3).allSatisfy({ $0 == marker }) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            guard fence == nil else { continue }
            let line = codeSpan.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            let range = NSRange(line.startIndex..., in: line)
            func add(_ rawTarget: String, wiki: Bool) {
                guard let link = parse(rawTarget, line: index + 1, wiki: wiki) else { return }
                result.append(link)
            }
            for match in wikiLink.matches(in: line, range: range) {
                let note = Range(match.range(at: 1), in: line).map { String(line[$0]) } ?? ""
                let heading = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                var target = note.trimmingCharacters(in: .whitespaces)
                if target.hasPrefix("file:") { target.removeFirst(5) }
                guard !target.isEmpty || heading != nil else { continue }
                result.append(Link(line: index + 1, target: target, fragment: heading?.trimmingCharacters(in: .whitespaces), wiki: true))
            }
            switch format {
            case .markdown:
                for match in inlineLink.matches(in: line, range: range) where match.range(at: 1).length == 0 {
                    if let targetRange = Range(match.range(at: 2), in: line) { add(String(line[targetRange]), wiki: false) }
                }
                for match in referenceUse.matches(in: line, range: range) where match.range(at: 1).length == 0 {
                    let text = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
                    let ref = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
                    if let url = definitions[(ref.isEmpty ? text : ref).lowercased()] { add(url, wiki: false) }
                }
            case .asciidoc:
                for match in asciidocLink.matches(in: line, range: range) {
                    if let targetRange = Range(match.range(at: 1), in: line) { add(String(line[targetRange]), wiki: false) }
                }
            case .rst:
                for match in rstLink.matches(in: line, range: range) {
                    if let targetRange = Range(match.range(at: 1), in: line) { add(String(line[targetRange]), wiki: false) }
                }
            case .org, .plain:
                break
            }
        }
        return result
    }

    /// `path#fragment` as written → a link, or nil for external and empty targets.
    private static func parse(_ rawTarget: String, line: Int, wiki: Bool) -> Link? {
        var target = rawTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("://"), !target.lowercased().hasPrefix("mailto:") else { return nil }
        var fragment: String?
        if let hash = target.firstIndex(of: "#") {
            fragment = String(target[target.index(after: hash)...])
            target = String(target[..<hash])
        }
        target = target.removingPercentEncoding ?? target
        fragment = fragment?.removingPercentEncoding ?? fragment
        if let f = fragment, f.isEmpty { fragment = nil }
        guard !target.isEmpty || fragment != nil else { return nil }
        return Link(line: line, target: target, fragment: fragment, wiki: wiki)
    }

    /// Resolve `a/./b/../c` without touching the file system.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// The chapters of a book by path and by lower-cased file name, for link resolution.
    struct Index {
        var byPath: [String: Chapter] = [:]
        var byName: [String: [String]] = [:]

        init(_ chapters: [Chapter]) {
            for chapter in chapters {
                byPath[chapter.path] = chapter
                byName[(chapter.path as NSString).lastPathComponent.lowercased(), default: []].append(chapter.path)
            }
        }

        /// A chapter path for `target`, tried as written and with each text extension appended.
        func chapterPath(_ target: String) -> String? {
            if byPath[target] != nil { return target }
            for ext in BookBuilder.linkExtensions where byPath[target + "." + ext] != nil { return target + "." + ext }
            return nil
        }
    }

    /// The node a link lands on: the section its fragment names, else the chapter; nil when the
    /// target is not a chapter of this book.
    static func resolve(_ link: Link, from chapter: Chapter, index: Index) -> String? {
        var targetPath: String?
        if link.target.isEmpty {
            targetPath = chapter.path
        } else {
            let written = link.target.hasPrefix("./") ? String(link.target.dropFirst(2)) : link.target
            if link.wiki {
                if written.contains("/") { targetPath = index.chapterPath(normalize(written)) }
            } else {
                let base = (chapter.path as NSString).deletingLastPathComponent
                targetPath = index.chapterPath(normalize(base.isEmpty ? written : base + "/" + written))
                    ?? index.chapterPath(normalize(written))
            }
            if targetPath == nil, !written.contains("/") {
                // By file name, the way wiki-links are found: the document's own folder first.
                let name = (written as NSString).lastPathComponent.lowercased()
                let candidates = linkExtensions.map { name + "." + $0 }.flatMap { index.byName[$0] ?? [] }
                    + (index.byName[name] ?? [])
                targetPath = WikiLinkResolver.choose(candidates: candidates, from: (chapter.path as NSString).deletingLastPathComponent)
            }
        }
        guard let targetPath, let target = index.byPath[targetPath] else { return nil }
        guard let fragment = link.fragment else { return target.id }
        // `#L12` / `#L12-L20`: the section that holds the line.
        if let match = fragment.range(of: #"^L(\d+)"#, options: .regularExpression),
           let line = Int(fragment[match].dropFirst()) {
            return target.section(containing: line)?.id ?? target.id
        }
        let lowered = fragment.lowercased()
        return target.anchors[fragment] ?? target.anchors[lowered] ?? target.anchors[slug(fragment)] ?? target.id
    }

    // MARK: - Order

    /// Reading order of two paths: component by component, README and index files first in a
    /// folder, then numbers in names compared as numbers (`2-setup` before `10-api`), then letters.
    static func bookOrder(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: "/"), right = b.split(separator: "/")
        for (index, (x, y)) in zip(left, right).enumerated() where x != y {
            let lastLeft = index == left.count - 1, lastRight = index == right.count - 1
            if lastLeft != lastRight { return lastLeft }   // a file before the folders beside it
            if lastLeft {
                let xFront = isFrontMatter(String(x)), yFront = isFrontMatter(String(y))
                if xFront != yFront { return xFront }
            }
            return naturalLess(String(x), String(y))
        }
        return left.count < right.count
    }

    private static func isFrontMatter(_ name: String) -> Bool {
        ["readme", "index"].contains(((name as NSString).deletingPathExtension).lowercased())
    }

    private static func naturalLess(_ a: String, _ b: String) -> Bool {
        let order = a.compare(b, options: [.caseInsensitive, .numeric])
        return order == .orderedSame ? a < b : order == .orderedAscending
    }

    // MARK: - The book

    /// Nodes and explicit cross-reference edges of the Book view for `chapters`, in reading
    /// order. `rootName` names the book when no root README/index gives it a title.
    static func build(chapters: [Chapter], rootName: String) -> (nodes: [ArchNode], edges: [ArchEdge]) {
        let ordered = chapters.sorted { bookOrder($0.path, $1.path) }
        let index = Index(ordered)

        var nodes: [ArchNode] = []
        var partIds: Set<String> = []
        var root = ArchNode(id: "d:", parent: nil, kind: "root", name: rootName, path: "")
        if let opener = ordered.first(where: { $0.part.isEmpty && isFrontMatter($0.path) }),
           opener.title != ((opener.path as NSString).lastPathComponent as NSString).deletingPathExtension {
            root.name = opener.title
        }
        nodes.append(root)
        partIds.insert("d:")
        func ensurePart(_ dir: String) -> String {
            let id = partId(dir)
            if !partIds.contains(id) {
                let parent = ensurePart((dir as NSString).deletingLastPathComponent)
                nodes.append(ArchNode(id: id, parent: parent, kind: "dir", name: (dir as NSString).lastPathComponent, path: dir))
                partIds.insert(id)
            }
            return id
        }

        var parentOf: [String: String] = [:]
        for chapter in ordered {
            var node = ArchNode(id: chapter.id, parent: ensurePart(chapter.part), kind: "doc", name: chapter.title,
                                path: chapter.path, language: chapter.format.rawValue, loc: chapter.lines, files: 1)
            node.signature = chapter.signature
            node.summary = chapter.lead
            nodes.append(node)
            parentOf[chapter.id] = node.parent
            for section in chapter.sections {
                var sectionNode = ArchNode(id: section.id, parent: section.parent, kind: "section", name: section.title,
                                           path: chapter.path, loc: section.loc)
                sectionNode.summary = section.lead
                sectionNode.line = section.start
                sectionNode.endLine = section.end
                sectionNode.anchor = section.anchor
                nodes.append(sectionNode)
                parentOf[section.id] = section.parent
            }
        }

        func isAncestor(_ a: String, of b: String) -> Bool {
            var current = parentOf[b]
            while let c = current { if c == a { return true }; current = parentOf[c] }
            return false
        }
        var edges: [String: ArchEdge] = [:]
        var order: [String] = []
        for chapter in ordered {
            for link in chapter.links {
                guard let target = resolve(link, from: chapter, index: index) else { continue }
                let source = chapter.section(containing: link.line)?.id ?? chapter.id
                guard source != target, !isAncestor(source, of: target), !isAncestor(target, of: source) else { continue }
                let key = source + "→" + target
                if edges[key] == nil {
                    edges[key] = ArchEdge(source: source, target: target, kind: "links")
                    order.append(key)
                } else {
                    edges[key]!.weight += 1
                }
            }
        }

        // Folder sizes.
        let partParent = Dictionary(nodes.filter { $0.kind == "dir" || $0.kind == "root" }.map { ($0.id, $0.parent) },
                                    uniquingKeysWith: { a, _ in a })
        var counts: [String: (files: Int, loc: Int)] = [:]
        for chapter in ordered {
            var parent: String? = partId(chapter.part)
            while let p = parent {
                counts[p, default: (0, 0)].files += 1
                counts[p, default: (0, 0)].loc += chapter.lines
                parent = partParent[p] ?? nil
            }
        }
        for i in nodes.indices where nodes[i].kind == "dir" || nodes[i].kind == "root" {
            nodes[i].files = counts[nodes[i].id]?.files ?? 0
            nodes[i].loc = counts[nodes[i].id]?.loc ?? 0
        }
        return (nodes, order.compactMap { edges[$0] })
    }
}
