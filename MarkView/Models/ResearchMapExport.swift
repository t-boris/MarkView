import Foundation

/// The linear report of a research map (feature mind-map, REQ-007, DEC-010): the question, every node as nested
/// numbered headings in map order, descriptions, findings with their labels and sources, logical connections as
/// "See also", the web searches, and a note when the run is incomplete. Folded nodes are included: folding is view
/// state and never reaches Swift. Pure (Foundation and ResearchMapDocument), so `tools/tests` can compile it alone.
extension ResearchMap {
    /// The report file of a map: `<map name>-report.md` in the folder of the map (`<map name>-report-<code>.md` for a language chosen at export).
    static func reportURL(forMap file: URL, languageCode: String = "") -> URL {
        let name = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appendingPathComponent(name + "-report" + (languageCode.isEmpty ? "" : "-" + languageCode) + ".md")
    }

    /// The mechanical outline of the map (REQ-007): one numbered heading per node. The app no longer exports it (REQ-013, DEC-014:
    /// the report goes through the assistant and is a narrative); `ResearchMapReport` and its tests keep it as the example of
    /// an outline that the report checks must reject. `mapName` is the file name of the map, named in the closing line.
    func report(mapName: String) -> String {
        guard let root else { return "" }
        let numbers = outlineNumbers()
        var out: [String] = []
        out.append("# " + Self.iconMark(root.icon) + Self.heading(root.title))
        out.append("")
        if !question.isEmpty {
            out.append(contentsOf: question.components(separatedBy: "\n").map { "> " + $0 })
            out.append("")
        }
        if status == .incomplete {
            let why = incompleteReason.isEmpty ? "the research stopped early" : incompleteReason
            out.append("**Incomplete research:** " + Self.oneLine(why) + ".")
            out.append("")
        } else if status == .researching {
            out.append("**The research was still running when this report was made.**")
            out.append("")
        }
        for node in nodes {
            out.append(contentsOf: section(for: node, number: numbers[node.id] ?? "", numbers: numbers, isRoot: node.id == root.id))
        }
        if !webQueries.isEmpty {
            out.append("## Web searches")
            out.append("")
            for (index, query) in webQueries.enumerated() { out.append("\(index + 1). " + Self.oneLine(query)) }
            out.append("")
        }
        out.append("---")
        out.append("")
        out.append("*\(nodes.count) \(nodes.count == 1 ? "node" : "nodes") · made from the research map `\(mapName)`*")
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: Pieces

    private func section(for node: Node, number: String, numbers: [String: String], isRoot: Bool) -> [String] {
        var out: [String] = []
        if !isRoot {
            let level = min(depth(of: node.id) + 1, 6)
            out.append(String(repeating: "#", count: level) + " " + number + " " + Self.iconMark(node.icon) + Self.heading(node.title))
            out.append("")
        }
        var facts: [String] = []
        if let number = node.number { facts.append("Number: \(number)") }
        if !node.tags.isEmpty { facts.append("Tags: " + node.tags.map { "`" + $0.replacingOccurrences(of: "`", with: "'") + "`" }.joined(separator: ", ")) }
        if !facts.isEmpty {
            out.append(facts.joined(separator: " · "))
            out.append("")
        }
        let description = Self.demoted(node.description)
        if !description.isEmpty {
            out.append(description)
            out.append("")
        }
        if !node.evidence.isEmpty {
            out.append("**Findings**")
            out.append("")
            for item in node.evidence { out.append("- **\(item.label.rawValue)**: " + Self.oneLine(item.text) + Self.sourceSuffix(item.source)) }
            out.append("")
        }
        let related = links.compactMap { link -> String? in
            let other = link.from == node.id ? link.to : (link.to == node.id ? link.from : nil)
            guard let other, let target = self.node(other) else { return nil }
            let number = numbers[other].map { $0.isEmpty ? "" : $0 + " " } ?? ""
            return number + Self.heading(target.title)
        }
        if !related.isEmpty {
            out.append("See also: " + related.joined(separator: " · "))
            out.append("")
        }
        return out
    }

    /// "1", "1.1", "2" … per node; the root has none.
    private func outlineNumbers() -> [String: String] {
        var numbers: [String: String] = [:]
        var counters: [String: Int] = [:]
        for node in nodes where !node.parent.isEmpty {
            let next = (counters[node.parent] ?? 0) + 1
            counters[node.parent] = next
            let prefix = numbers[node.parent].flatMap { $0.isEmpty ? nil : $0 + "." } ?? ""
            numbers[node.id] = prefix + String(next)
        }
        numbers[nodes.first?.id ?? ""] = ""
        return numbers
    }

    /// A finding's source: a web address becomes a link, a project path a code span.
    private static func sourceSuffix(_ source: String) -> String {
        let text = oneLine(source)
        guard !text.isEmpty else { return "" }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            let safe = text.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20")
            return " ([source](\(safe)))"
        }
        return " (`" + text.replacingOccurrences(of: "`", with: "'") + "`)"
    }

    /// A description keeps its Markdown, but its own headings become bold lines so they cannot break the outline
    /// the report is built on (text in code fences is left alone).
    private static func demoted(_ description: String) -> String {
        var fenced = false
        var lines: [String] = []
        for raw in description.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            if !fenced, let match = raw.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                let title = raw[match.upperBound...].trimmingCharacters(in: .whitespaces)
                lines.append(title.isEmpty ? "" : "**" + title + "**")
            } else {
                lines.append(raw)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heading(_ title: String) -> String { oneLine(title) }

    /// A built-in icon is written as its name in brackets, an emoji as it is; the report is plain text.
    private static func iconMark(_ icon: String) -> String {
        if icon.isEmpty { return "" }
        return ResearchMap.iconIDs.contains(icon) ? "[\(icon)] " : icon + " "
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
