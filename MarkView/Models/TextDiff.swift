import Foundation

/// One line of a diff: where it is in the old and in the new text, and whether it was added, removed or only shown for context.
struct DiffLine: Identifiable, Equatable {
    enum Kind { case context, added, removed }
    let id: Int
    let kind: Kind
    /// 1-based line number in the old text (nil for an added line) and in the new text (nil for a removed line).
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

/// A group of nearby changes with the unchanged lines around it: what a person reads as "one change".
struct DiffHunk: Identifiable, Equatable {
    let id: Int
    let lines: [DiffLine]
    /// The declaration or heading the change sits in (the nearest one above it), when the text has one.
    let section: String?

    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }

    /// The first and last line of the change itself in the new text (nil when it only removes lines) and in the old text.
    var newRange: ClosedRange<Int>? { Self.range(lines.filter { $0.kind == .added }.compactMap(\.newNumber)) }
    var oldRange: ClosedRange<Int>? { Self.range(lines.filter { $0.kind == .removed }.compactMap(\.oldNumber)) }

    /// Where the change is, in words: "lines 12–15", "line 7", or, for a pure removal, "removed from old lines 9–11".
    var location: String {
        if let range = newRange {
            let place = range.lowerBound == range.upperBound ? "line \(range.lowerBound)" : "lines \(range.lowerBound)–\(range.upperBound)"
            guard let old = oldRange else { return place }
            let was = old.lowerBound == old.upperBound ? "line \(old.lowerBound)" : "lines \(old.lowerBound)–\(old.upperBound)"
            return "\(place) (was \(was))"
        }
        if let old = oldRange {
            let place = old.lowerBound == old.upperBound ? "old line \(old.lowerBound)" : "old lines \(old.lowerBound)–\(old.upperBound)"
            let after = lines.last { $0.kind == .context && ($0.oldNumber ?? 0) < old.lowerBound }?.newNumber
            return "removed from \(place)" + (after.map { ", after line \($0)" } ?? "")
        }
        return ""
    }

    /// What happened, from the numbers alone: "Adds 4 lines", "Replaces 3 lines with 5", "Removes 2 lines".
    var summary: String {
        func lines(_ n: Int) -> String { n == 1 ? "1 line" : "\(n) lines" }
        if removed == 0 { return "Adds \(lines(added))" }
        if added == 0 { return "Removes \(lines(removed))" }
        return "Replaces \(lines(removed)) with \(added)"
    }

    private static func range(_ numbers: [Int]) -> ClosedRange<Int>? {
        guard let low = numbers.min(), let high = numbers.max() else { return nil }
        return low...high
    }
}

/// A line diff between two texts, grouped into hunks with their location (Myers' O(ND) algorithm). Pure: it reads nothing and
/// is used by the review of observed file changes.
enum TextDiff {
    /// The most edits the search looks for before it gives up and shows the differing middle as replaced as a whole; a rewrite of a
    /// large file would otherwise cost time and memory that grow with the square of the edits.
    static let maximumEdits = 2_000

    private enum Op { case equal, insert, delete }

    /// The hunks that turn `old` into `new`, each with `context` unchanged lines around it. A nil side is a file that did not exist.
    static func hunks(old: String?, new: String?, context: Int = 3) -> [DiffHunk] {
        let a = lines(of: old), b = lines(of: new)
        let entries = merge(a, b)
        return group(entries, old: a, new: b, context: context)
    }

    // MARK: Lines

    static func lines(of text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        // A final newline ends the last line; it does not start another one.
        if result.last == "" { result.removeLast() }
        return result.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    // MARK: Diff

    private struct Entry { let kind: DiffLine.Kind; let old: Int?; let new: Int?; let text: String }

    private static func merge(_ a: [String], _ b: [String]) -> [Entry] {
        // The unchanged beginning and end are matched at once: most edits are small and the search runs on what is left.
        var head = 0
        while head < a.count && head < b.count && a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head && tail < b.count - head && a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let midA = Array(a[head..<(a.count - tail)]), midB = Array(b[head..<(b.count - tail)])

        var ids: [String: Int] = [:]
        func id(_ line: String) -> Int {
            if let known = ids[line] { return known }
            ids[line] = ids.count
            return ids.count - 1
        }
        let ops = edits(midA.map(id), midB.map(id)) ?? (Array(repeating: .delete, count: midA.count) + Array(repeating: .insert, count: midB.count))

        var entries: [Entry] = []
        entries.reserveCapacity(a.count + b.count)
        var x = 0, y = 0
        for i in 0..<head { entries.append(Entry(kind: .context, old: i + 1, new: i + 1, text: a[i])) }
        x = head; y = head
        for op in ops {
            switch op {
            case .equal: entries.append(Entry(kind: .context, old: x + 1, new: y + 1, text: a[x])); x += 1; y += 1
            case .delete: entries.append(Entry(kind: .removed, old: x + 1, new: nil, text: a[x])); x += 1
            case .insert: entries.append(Entry(kind: .added, old: nil, new: y + 1, text: b[y])); y += 1
            }
        }
        for _ in 0..<tail { entries.append(Entry(kind: .context, old: x + 1, new: y + 1, text: a[x])); x += 1; y += 1 }
        return entries
    }

    /// The shortest edit script from `a` to `b` (Myers 1986), or nil when it needs more than `maximumEdits` edits.
    private static func edits(_ a: [Int], _ b: [Int]) -> [Op]? {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let limit = min(n + m, maximumEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        // trace[d] is v as it was before round d, restricted to the diagonals round d reads: -d-1 ... d+1.
        var trace: [[Int]] = []
        var found = -1
        search: for d in 0...limit {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = d; break search }
            }
        }
        guard found >= 0 else { return nil }

        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: found, to: 0, by: -1) {
            let before = trace[d]
            func previous(_ k: Int) -> Int { before[k + d + 1] }
            let k = x - y
            let insertion = k == -d || (k != d && previous(k - 1) < previous(k + 1))
            let prevK = insertion ? k + 1 : k - 1
            let prevX = previous(prevK), prevY = prevX - prevK
            // The edit lands on (prevX, prevY + 1) for an insertion and on (prevX + 1, prevY) for a deletion; what follows is a run of equal lines.
            let midX = insertion ? prevX : prevX + 1, midY = insertion ? prevY + 1 : prevY
            while x > midX && y > midY { ops.append(.equal); x -= 1; y -= 1 }
            ops.append(insertion ? .insert : .delete)
            x = prevX; y = prevY
        }
        while x > 0 && y > 0 { ops.append(.equal); x -= 1; y -= 1 }
        return ops.reversed()
    }

    // MARK: Hunks

    private static func group(_ entries: [Entry], old: [String], new: [String], context: Int) -> [DiffHunk] {
        let changed = entries.indices.filter { entries[$0].kind != .context }
        guard let first = changed.first else { return [] }
        // Changes closer together than their context would overlap share one hunk.
        var ranges: [(start: Int, end: Int)] = []
        var start = first, end = first
        for index in changed.dropFirst() {
            if index - end <= 2 * context + 1 { end = index } else { ranges.append((start, end)); start = index; end = index }
        }
        ranges.append((start, end))

        return ranges.enumerated().map { number, range in
            let low = max(0, range.start - context), high = min(entries.count - 1, range.end + context)
            let lines = (low...high).map { i in
                DiffLine(id: i, kind: entries[i].kind, oldNumber: entries[i].old, newNumber: entries[i].new, text: entries[i].text)
            }
            // The section is looked up above the first changed line, in the new text, or in the old one when the change only removes.
            let anchor = entries[range.start]
            let section = anchor.new.flatMap { Self.section(in: new, above: $0 - 1) } ?? anchor.old.flatMap { Self.section(in: old, above: $0 - 1) }
            return DiffHunk(id: number, lines: lines, section: section)
        }
    }

    // MARK: Section

    private static let modifiers: Set<String> = ["private", "fileprivate", "internal", "public", "open", "static", "final", "override", "async",
                                                 "export", "default", "pub", "mutating", "nonisolated", "@MainActor", "abstract", "protected",
                                                 "private(set)", "lazy", "convenience", "required", "unsafe", "const", "inline", "extern"]
    private static let keywords = ["func ", "class ", "struct ", "enum ", "extension ", "protocol ", "actor ", "init(", "init?(", "deinit", "def ", "function ",
                                   "interface ", "type ", "fn ", "impl ", "trait ", "mod ", "namespace ", "module ", "subscript(", "describe("]

    /// The nearest declaration or Markdown heading at or above `index` (0-based), up to 600 lines up: "func startNew()", "## Install".
    static func section(in lines: [String], above index: Int) -> String? {
        guard !lines.isEmpty else { return nil }
        var i = min(index, lines.count - 1)
        let floor = max(0, i - 600)
        while i >= floor {
            if let name = heading(of: lines[i]) { return name }
            i -= 1
        }
        return nil
    }

    private static func heading(of raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("#") {
            let marks = line.prefix { $0 == "#" }.count
            // "# comment" in a shell script is told from a heading by the unindented level-1..6 form, which is all that is accepted.
            if marks <= 6, raw.hasPrefix("#"), line.dropFirst(marks).hasPrefix(" ") { return clip(line) }
            return nil
        }
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let first = words.first, modifiers.contains(first) { words.removeFirst() }
        let rest = words.joined(separator: " ")
        guard keywords.contains(where: { rest.hasPrefix($0) }) else { return nil }
        return clip(rest)
    }

    private static func clip(_ line: String) -> String {
        var text = line
        if let brace = text.firstIndex(of: "{") { text = String(text[..<brace]) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 90 ? String(text.prefix(89)) + "…" : text
    }
}
