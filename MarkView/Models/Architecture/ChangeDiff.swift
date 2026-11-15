import Foundation

/// Reading a unified diff, with no git, no assistant and no state: the files and ranges a change touches, each file's own
/// part of it, how its lines map onto the file as it is now, and where in a file's X-Ray contents the changes fall.
/// The values it returns are in `ChangeReviewModel.swift`; the Pull request X-Ray (`ChangeReviewStore`) is its caller.
enum ChangeDiff {
    /// Added and removed lines of every file in a unified diff.
    static func lines(_ diff: String) -> [String: (added: String, removed: String)] {
        var out: [String: (added: String, removed: String)] = [:]
        var current: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                current = path == "/dev/null" ? nil : (path.hasPrefix("b/") ? String(path.dropFirst(2)) : path)
                if let current, out[current] == nil { out[current] = ("", "") }
            } else if line.hasPrefix("--- ") || line.hasPrefix("diff --git ") {
                continue
            } else if let path = current, line.hasPrefix("+") {
                out[path]!.added += line.dropFirst() + "\n"
            } else if let path = current, line.hasPrefix("-") {
                out[path]!.removed += line.dropFirst() + "\n"
            }
        }
        return out
    }

    /// Parse a unified diff into per-file line counts and touched new-file ranges.
    static func files(_ diff: String) -> [PRFileChange] {
        var files: [PRFileChange] = []
        var current: PRFileChange?
        var newLine = 0
        var rangeStart: Int?
        var oldPath: String?
        func closeRange(_ end: Int) {
            if let start = rangeStart, current != nil, current!.deleted != true { current!.ranges.append([start, max(start, end)]) }
            rangeStart = nil
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                closeRange(newLine - 1)
                if let file = current { files.append(file) }
                current = nil
                oldPath = nil
            } else if line.hasPrefix("--- ") && current == nil {
                let path = String(line.dropFirst(4))
                oldPath = path == "/dev/null" ? nil : (path.hasPrefix("a/") ? String(path.dropFirst(2)) : path)
            } else if line.hasPrefix("+++ ") && current == nil {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    current = PRFileChange(path: path.hasPrefix("b/") ? String(path.dropFirst(2)) : path,
                                           additions: 0, deletions: 0, ranges: [])
                } else if let oldPath {
                    // A removed file: kept, so it shows in the X-Ray and opens as it was.
                    current = PRFileChange(path: oldPath, additions: 0, deletions: 0, ranges: [], deleted: true)
                }
            } else if line.hasPrefix("@@") {
                closeRange(newLine - 1)
                // @@ -a,b +c,d @@
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if current != nil {
                if line.hasPrefix("+") {
                    current!.additions += 1
                    if rangeStart == nil { rangeStart = newLine }
                    newLine += 1
                } else if line.hasPrefix("-") {
                    current!.deletions += 1
                    if rangeStart == nil { rangeStart = newLine }
                } else {
                    closeRange(newLine - 1)
                    newLine += 1
                }
            }
        }
        closeRange(newLine - 1)
        if let file = current { files.append(file) }
        return files
    }

    /// Each file's part of a unified diff, keyed by its new path.
    static func split(_ diff: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var lines: [Substring] = []
        func flush() { if let current { out[current] = lines.joined(separator: "\n") }; lines = [] }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush(); current = nil; continue }
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                current = path == "/dev/null" ? current : (path.hasPrefix("b/") ? String(path.dropFirst(2)) : path)
                continue
            }
            if line.hasPrefix("--- ") {
                // A deleted file keeps its old path.
                let path = String(line.dropFirst(4))
                if path != "/dev/null" { current = path.hasPrefix("a/") ? String(path.dropFirst(2)) : path }
                continue
            }
            if line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") { continue }
            lines.append(line)
        }
        flush()
        return out
    }

    /// New-file line numbers of a diff → lines of the file as it is now, matched by
    /// content (longest common subsequence over the diff's new-side lines).
    struct LineMap {
        let inSync: Bool
        private let mapped: [Int: Int]
        private let known: [Int]   // sorted diff positions that were matched

        init(inSync: Bool, mapped: [Int: Int]) {
            self.inSync = inSync
            self.mapped = mapped
            self.known = mapped.keys.sorted()
        }

        /// The current line for a diff line: its match, else shifted like the nearest match.
        func line(_ position: Int) -> Int {
            if inSync { return position }
            if let exact = mapped[position] { return exact }
            guard !known.isEmpty else { return position }
            var low = 0, high = known.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if known[mid] <= position { low = mid } else { high = mid - 1 }
            }
            let anchor = known[low] <= position ? known[low] : known[0]
            return max(1, position + (mapped[anchor]! - anchor))
        }

        func exists(_ position: Int) -> Bool { inSync || mapped[position] != nil }
    }

    static func lineMap(diff: String, current: String) -> LineMap {
        // The diff's new side: positions and texts of context and added lines.
        var side: [(position: Int, text: Substring)] = []
        var newLine = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") || line.hasPrefix(" ") {
                side.append((newLine, line.dropFirst()))
                newLine += 1
            }
        }
        let lines = current.editorLines
        func same(_ a: Substring, _ b: Substring) -> Bool {
            a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
        }
        if side.allSatisfy({ $0.position >= 1 && $0.position <= lines.count && same(lines[$0.position - 1], $0.text) }) {
            return LineMap(inSync: true, mapped: [:])
        }
        let n = side.count, m = lines.count
        guard n > 0, m > 0, n * m <= 8_000_000 else { return LineMap(inSync: false, mapped: [:]) }
        let a = side.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let b = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        // LCS table (suffix lengths), then walk it forward.
        var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] &+ 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var mapped: [Int: Int] = [:]
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                mapped[side[i].position] = j + 1
                i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return LineMap(inSync: false, mapped: mapped)
    }

    /// Changed new-file line ranges of a file's diff: runs of added and removed lines
    /// (a removal alone marks the line where the text was).
    static func changedRanges(_ diff: String) -> [[Int]] {
        var ranges: [[Int]] = []
        var newLine = 0
        var run: [Int]?
        func close() { if let r = run { ranges.append(r) }; run = nil }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                close()
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") {
                run = [min(run?[0] ?? newLine, newLine), newLine]
                newLine += 1
            } else if line.hasPrefix("-") {
                let at = max(newLine, 1)
                run = [min(run?[0] ?? at, at), max(run?[1] ?? at, at)]
            } else if line.hasPrefix("\\") {
                continue
            } else {
                close()
                newLine += 1
            }
        }
        close()
        return ranges
    }

    /// Items of a file's X-Ray contents with the lines they cover (to the next item).
    static func itemSpans(_ outline: XRayContent.Outline?)
        -> [(part: String, name: String, start: Int, end: Int)] {
        guard let outline else { return [] }
        var items: [(part: String, name: String, start: Int)] = []
        for collection in outline.collections {
            for group in collection.groups {
                for item in group.items { items.append((collection.name, item.name, item.line)) }
            }
        }
        items.sort { $0.start < $1.start }
        return items.enumerated().map { index, item in
            let end = index + 1 < items.count ? max(item.start, items[index + 1].start - 1) : Int.max
            return (item.part, item.name, item.start, end)
        }
    }

    static func part(at line: Int, in spans: [(part: String, name: String, start: Int, end: Int)]) -> String? {
        spans.last { $0.start <= line }?.part
    }

    /// Changed ranges placed in the items they touch; outside any item, "Lines a–b".
    static func changeNotes(hunks: [[Int]],
                                                spans: [(part: String, name: String, start: Int, end: Int)]) -> [PRChangeNote] {
        var notes: [PRChangeNote] = []
        var index: [String: Int] = [:]
        for range in hunks {
            let (a, b) = (range[0], range[1])
            let touched = spans.filter { $0.start <= b && $0.end >= a }
            if touched.isEmpty {
                notes.append(PRChangeNote(part: nil, title: a == b ? "Line \(a)" : "Lines \(a)–\(b)", start: a, end: b))
                continue
            }
            for item in touched {
                let key = item.part + "\u{1}" + item.name
                let start = max(a, item.start), end = min(b, item.end)
                if let i = index[key] {
                    notes[i].start = min(notes[i].start, start)
                    notes[i].end = max(notes[i].end, end)
                } else {
                    index[key] = notes.count
                    notes.append(PRChangeNote(part: item.part, title: item.name, start: start, end: end))
                }
            }
            if notes.count >= 200 { break }
        }
        return notes
    }

    /// A file's diff with new-file line numbers on the left (clipped), for the prompt.
    static func numbered(_ diff: String, maxLines: Int = 1500) -> String {
        var out: [String] = []
        var newLine = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if out.count >= maxLines { out.append("… (diff clipped)"); break }
            if line.hasPrefix("@@") {
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                out.append(String(line))
            } else if line.hasPrefix("+") {
                out.append("\(newLine) + " + line.dropFirst()); newLine += 1
            } else if line.hasPrefix("-") {
                out.append("     - " + line.dropFirst())
            } else if !line.hasPrefix("\\") {
                out.append("\(newLine)   " + line.dropFirst()); newLine += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// What the code viewer shows of a change inside `file`: its logical changes placed at their current lines, the lines still
    /// added, the points where text was removed, and whether the file moved on since the diff was read (`remapped`). `overlay`
    /// carries the notes (see `ChangeReviewStore.withChangeNotes`); `focus` is set for a file opened from the Pull request X-Ray.
    static func fileNotes(overlay: PROverlay, file: PRFileChange, diff: String, content: String, focus: Bool) -> PRFileNotes {
        if file.deleted == true {
            // The whole file goes: every change is about the old text, from its first line.
            let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
            let body = lines.drop { !$0.hasPrefix("@@") }   // skip the file header ("--- a/…")
            let removedLines = body.filter { $0.hasPrefix("-") }.map(String.init)
            let count = max(content.editorLines.count, 1)
            let changes = (file.changes ?? []).map {
                PRFileNotes.Change(title: $0.title, start: 1, end: count, kind: $0.kind ?? "removed", why: $0.why,
                                   diff: Array(removedLines.prefix(60)))
            }
            return PRFileNotes(title: overlay.source.title, summary: file.changeSummary, explaining: file.explaining == true,
                               explained: file.changeSummary != nil, additions: 0, deletions: file.deletions,
                               changes: changes, added: [], removed: [], focus: focus,
                               remapped: false, diffKey: String(ContentHash.of(diff).prefix(12)),
                               reviewOutdated: overlay.reviewOutdated == true, deletedLines: count)
        }
        let map = ChangeDiff.lineMap(diff: diff, current: content)
        // Walk the diff once: added runs, removal points, and each line's new-file position.
        var added: [[Int]] = []
        var removed: [[Int]] = []
        var lines: [(position: Int, text: String)] = []
        var newLine = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    newLine = Int(plus.dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
            } else if line.hasPrefix("+") {
                if let last = added.last, last[1] == newLine - 1 { added[added.count - 1][1] = newLine } else { added.append([newLine, newLine]) }
                lines.append((newLine, String(line)))
                newLine += 1
            } else if line.hasPrefix("-") {
                let at = max(newLine, 1)
                if let last = removed.last, last[0] == at { removed[removed.count - 1][1] += 1 } else { removed.append([at, 1]) }
                lines.append((at, String(line)))
            } else if !line.hasPrefix("\\") {
                newLine += 1
            }
        }
        let changes = (file.changes ?? []).map { note -> PRFileNotes.Change in
            let own = lines.filter { $0.position >= note.start && $0.position <= note.end }.map(\.text)
            let start = map.line(note.start)
            return PRFileNotes.Change(title: note.title, start: start, end: max(start, map.line(note.end)),
                                      kind: note.kind, why: note.why, diff: Array(own.prefix(60)))
        }
        // Added lines still in the file, at their current lines; removal points shifted along.
        var current: [[Int]] = []
        for range in added {
            for position in range[0]...range[1] where map.exists(position) {
                let line = map.line(position)
                if let last = current.last, last[1] == line - 1 { current[current.count - 1][1] = line } else { current.append([line, line]) }
            }
        }
        return PRFileNotes(title: overlay.source.title, summary: file.changeSummary, explaining: file.explaining == true,
                           explained: file.changeSummary != nil, additions: file.additions, deletions: file.deletions,
                           changes: changes, added: current, removed: removed.map { [map.line($0[0]), $0[1]] },
                           focus: focus, remapped: !map.inSync,
                           diffKey: String(ContentHash.of(diff).prefix(12)), reviewOutdated: overlay.reviewOutdated == true,
                           deletedLines: nil)
    }
}
