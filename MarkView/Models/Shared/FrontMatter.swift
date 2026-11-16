import Foundation

/// A YAML value of the subset feature files use: scalars, lists and ordered maps.
indirect enum YAMLValue: Equatable, Sendable {
    case string(String)
    case list([YAMLValue])
    case map([(key: String, value: YAMLValue)])

    static func == (a: YAMLValue, b: YAMLValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.list(let x), .list(let y)): return x == y
        case (.map(let x), .map(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A list of strings (a single scalar counts as a one-element list).
    var strings: [String] {
        switch self {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .list(let items): return items.compactMap(\.string)
        case .map: return []
        }
    }

    var list: [YAMLValue] {
        if case .list(let items) = self { return items }
        return []
    }

    var entries: [(key: String, value: YAMLValue)] {
        if case .map(let entries) = self { return entries }
        return []
    }

    subscript(key: String) -> YAMLValue? {
        entries.first { $0.key == key }?.value
    }
}

/// Front matter (`---` YAML block) at the top of a Markdown file, kept in order so a file
/// written back changes only what was edited.
struct FrontMatter: Equatable, Sendable {
    var entries: [(key: String, value: YAMLValue)] = []
    /// False when reading dropped something (comments, lines the subset does not model):
    /// writing such front matter back would lose it, so the app refuses to.
    var isLossless = true

    static func == (a: FrontMatter, b: FrontMatter) -> Bool { YAMLValue.map(a.entries) == YAMLValue.map(b.entries) }

    subscript(key: String) -> YAMLValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    func string(_ key: String) -> String { self[key]?.string ?? "" }
    func strings(_ key: String) -> [String] { self[key]?.strings ?? [] }

    mutating func set(_ key: String, _ value: String?) {
        self[key] = value.map { .string($0) }
    }

    mutating func set(_ key: String, list: [String]) {
        self[key] = .list(list.map { .string($0) })
    }

    // MARK: Split and join

    /// Front matter and the Markdown after it. A file without one has empty front matter.
    static func split(_ text: String) -> (FrontMatter, String) {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return (FrontMatter(), text) }
        let yaml = Array(lines[1..<end])
        var body = lines[(end + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        var parser = YAMLParser(lines: yaml)
        var front = FrontMatter(entries: parser.parseMap(indent: 0))
        front.isLossless = !parser.lostSomething && parser.position >= parser.lines.count
        return (front, body)
    }

    /// The file: front matter block, a blank line, the body.
    func join(body: String) -> String {
        "---\n" + YAMLWriter.map(entries, indent: 0) + "---\n\n" + body.trimmingCharacters(in: .newlines) + "\n"
    }
}

// MARK: - Parser

private struct YAMLParser {
    /// Meaningful lines: (indent, text without indent). Comments and blank lines dropped.
    var lines: [(indent: Int, text: String)]
    var position = 0
    /// Comments or lines that were skipped: the front matter cannot be written back as is.
    var lostSomething = false

    init(lines: [String]) {
        var lost = false
        self.lines = lines.compactMap { raw in
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { lost = true; return nil }
            guard !trimmed.isEmpty else { return nil }
            return (line.prefix { $0 == " " }.count, trimmed)
        }
        lostSomething = lost
    }

    /// The lines of a block scalar (`key: |` or `key: >`) under `indent`.
    mutating func blockScalar(indent: Int, folded: Bool) -> String {
        var parts: [String] = []
        while position < lines.count, lines[position].indent > indent {
            parts.append(lines[position].text)
            position += 1
        }
        return parts.joined(separator: folded ? " " : "\n")
    }

    mutating func parseMap(indent: Int) -> [(key: String, value: YAMLValue)] {
        var entries: [(key: String, value: YAMLValue)] = []
        while position < lines.count {
            let line = lines[position]
            if line.indent < indent || line.text.hasPrefix("- ") || line.text == "-" { break }
            guard line.indent == indent, let (key, rest) = Self.keyValue(line.text) else {
                lostSomething = true
                position += 1
                continue
            }
            position += 1
            if rest.hasPrefix("|") || rest.hasPrefix(">") {
                entries.append((key, .string(blockScalar(indent: indent, folded: rest.hasPrefix(">")))))
            } else if !rest.isEmpty {
                entries.append((key, Self.scalarOrInline(rest)))
            } else if position < lines.count, lines[position].indent > indent
                        || (lines[position].indent == indent && lines[position].text.hasPrefix("-")) {
                let child = lines[position]
                if child.text.hasPrefix("-") {
                    entries.append((key, .list(parseList(indent: child.indent))))
                } else {
                    entries.append((key, .map(parseMap(indent: child.indent))))
                }
            } else {
                entries.append((key, .string("")))
            }
        }
        return entries
    }

    mutating func parseList(indent: Int) -> [YAMLValue] {
        var items: [YAMLValue] = []
        while position < lines.count {
            let line = lines[position]
            guard line.indent == indent, line.text.hasPrefix("-") else { break }
            let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
            position += 1
            if rest.isEmpty {
                if position < lines.count, lines[position].indent > indent {
                    let child = lines[position]
                    items.append(child.text.hasPrefix("-") ? .list(parseList(indent: child.indent))
                                                            : .map(parseMap(indent: child.indent)))
                } else {
                    items.append(.string(""))
                }
            } else if let (key, value) = Self.keyValue(rest), !Self.isQuoted(rest) {
                // "- key: value" starts a map; its other keys sit under the first one.
                let itemIndent = indent + 2
                var entries: [(key: String, value: YAMLValue)] = []
                if value.isEmpty, position < lines.count, lines[position].indent > indent {
                    let child = lines[position]
                    if child.text.hasPrefix("-") {
                        entries.append((key, .list(parseList(indent: child.indent))))
                    } else if child.indent > itemIndent {
                        entries.append((key, .map(parseMap(indent: child.indent))))
                    } else {
                        entries.append((key, .string("")))
                    }
                } else {
                    entries.append((key, Self.scalarOrInline(value)))
                }
                if position < lines.count, lines[position].indent == itemIndent, !lines[position].text.hasPrefix("-") {
                    entries += parseMap(indent: itemIndent)
                }
                items.append(.map(entries))
            } else {
                items.append(Self.scalarOrInline(rest))
            }
        }
        return items
    }

    static func isQuoted(_ text: String) -> Bool { text.hasPrefix("\"") || text.hasPrefix("'") }

    /// "key: value" → (key, value); nil when the text is not a key line.
    static func keyValue(_ text: String) -> (String, String)? {
        guard !isQuoted(text) else { return nil }
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text[..<index]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !key.contains(" ") || key.count < 40 else { return nil }
                    return (unquote(key), String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func scalarOrInline(_ text: String) -> YAMLValue {
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast()
            return .list(splitInline(String(inner)).map { .string(unquote($0)) })
        }
        if text == "[]" { return .list([]) }
        return .string(unquote(stripComment(text)))
    }

    /// Split "a, 'b, c', d" at top-level commas.
    static func splitInline(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let q = quote {
                current.append(character)
                if character == q { quote = nil }
            } else if (character == "\"" || character == "'") && current.trimmingCharacters(in: .whitespaces).isEmpty {
                // A quote opens a quoted item only at its start ("Doesn't scale" is plain).
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !parts.isEmpty { parts.append(last) }
        return parts.filter { !$0.isEmpty }
    }

    static func stripComment(_ text: String) -> String {
        guard !isQuoted(text), let range = text.range(of: " #") else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            // One left-to-right pass, so "\\n" stays a backslash and an n.
            var out = ""
            var escaping = false
            for character in t.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    out.append(character)
                }
            }
            return out
        }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return t
    }
}

// MARK: - Writer

private enum YAMLWriter {
    static func map(_ entries: [(key: String, value: YAMLValue)], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var out = ""
        for (key, value) in entries {
            switch value {
            case .string(let s):
                out += "\(pad)\(key): \(scalar(s))\n"
            case .list(let items):
                if items.isEmpty {
                    out += "\(pad)\(key): []\n"
                } else if items.allSatisfy({ ($0.string ?? "\n").count < 40 && !($0.string ?? "\n").contains("\n") }),
                          items.count <= 8 {
                    out += "\(pad)\(key): [" + items.compactMap(\.string).map { inlineScalar($0) }.joined(separator: ", ") + "]\n"
                } else {
                    out += "\(pad)\(key):\n" + list(items, indent: indent + 2)
                }
            case .map(let children):
                out += children.isEmpty ? "\(pad)\(key): {}\n" : "\(pad)\(key):\n" + map(children, indent: indent + 2)
            }
        }
        return out
    }

    static func list(_ items: [YAMLValue], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var out = ""
        for item in items {
            switch item {
            case .string(let s):
                out += "\(pad)- \(scalar(s))\n"
            case .list(let inner):
                out += "\(pad)-\n" + list(inner, indent: indent + 2)
            case .map(let entries):
                guard let first = entries.first else { out += "\(pad)- {}\n"; continue }
                // First key on the dash line, the rest aligned under it.
                let body = map(entries, indent: indent + 2)
                let firstLine = map([first], indent: indent + 2)
                out += "\(pad)- " + firstLine.dropFirst(indent + 2)
                out += String(body.dropFirst(firstLine.count))
            }
        }
        return out
    }

    static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s != s.trimmingCharacters(in: .whitespaces) { return true }
        if s.contains(": ") || s.hasSuffix(":") || s.contains(" #") || s.contains("\n") { return true }
        if let first = s.first, "[]{}#&*!|>'\"%@`-?,".contains(first) { return true }
        if ["true", "false", "null", "yes", "no", "~"].contains(s.lowercased()) { return false }
        return false
    }

    static func scalar(_ s: String) -> String {
        needsQuotes(s) ? quoted(s) : s
    }

    static func inlineScalar(_ s: String) -> String {
        needsQuotes(s) || s.contains(",") || s.contains("\"") || s.contains("'") || s.contains("[") || s.contains("]") ? quoted(s) : s
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
