import Combine
import Foundation
import SwiftUI

// MARK: - Scoped Scroll & Heading Side Table (AR-15)

/// Per-tab scroll position and active heading side table (`AR-15`).
///
/// Scroll offsets are stored in a non-published dictionary so continuous WebView scroll
/// notifications never invalidate `WorkspaceManager` or re-render the window chrome.
/// Active heading changes publish only on `DocumentScrollSideTable`, allowing `TOCView`
/// to observe heading changes without invalidating unrelated views.
@MainActor
final class DocumentScrollSideTable: ObservableObject {
    /// Scroll positions keyed by `OpenTab.id` (not `@Published`, read on demand by session save/restore).
    private(set) var scrollPositions: [UUID: CGFloat] = [:]

    /// Active heading IDs keyed by `OpenTab.id` (`@Published` only to observers of this side table).
    @Published private(set) var activeHeadings: [UUID: String] = [:]

    func setScrollPosition(_ position: CGFloat, for tabID: UUID) {
        let sanitized = position.isFinite ? max(0, position) : 0
        scrollPositions[tabID] = sanitized
    }

    func scrollPosition(for tabID: UUID, fallback: CGFloat = 0) -> CGFloat {
        scrollPositions[tabID] ?? fallback
    }

    func setActiveHeading(_ headingID: String?, for tabID: UUID) {
        if activeHeadings[tabID] != headingID {
            activeHeadings[tabID] = headingID
        }
    }

    func activeHeading(for tabID: UUID, fallback: String? = nil) -> String? {
        activeHeadings[tabID] ?? fallback
    }

    func removeTab(_ tabID: UUID) {
        scrollPositions.removeValue(forKey: tabID)
        if activeHeadings[tabID] != nil {
            activeHeadings.removeValue(forKey: tabID)
        }
    }

    func reset() {
        scrollPositions.removeAll()
        if !activeHeadings.isEmpty {
            activeHeadings.removeAll()
        }
    }
}

// MARK: - Task Bag & Window Task Scheduler (AR-19)

/// Keyed and unkeyed cancellable task bag owned per window (`AR-19`).
///
/// Storing a task under an existing key automatically cancels the previous task for that key.
/// Calling `cancelAll()` on folder switch or window close cancels all tracked background work.
@MainActor
final class TaskBag {
    private var keyedTasks: [String: AnyCancellable] = [:]
    private var unkeyedTasks: [UUID: AnyCancellable] = [:]

    /// Store a `Task<Success, Never>` under `key`, cancelling any prior task with the same key.
    func store<Success>(_ task: Task<Success, Never>, for key: String) {
        keyedTasks[key]?.cancel()
        keyedTasks[key] = AnyCancellable { task.cancel() }
    }

    /// Store a throwing `Task<Success, Error>` under `key`, cancelling any prior task with the same key.
    func store<Success>(_ task: Task<Success, Error>, for key: String) {
        keyedTasks[key]?.cancel()
        keyedTasks[key] = AnyCancellable { task.cancel() }
    }

    /// Insert an unkeyed `Task<Success, Never>` into the bag and return its token.
    @discardableResult
    func insert<Success>(_ task: Task<Success, Never>) -> UUID {
        let id = UUID()
        unkeyedTasks[id] = AnyCancellable { task.cancel() }
        return id
    }

    /// Cancel and remove a specific keyed task.
    func cancel(key: String) {
        keyedTasks.removeValue(forKey: key)?.cancel()
    }

    /// Cancel and remove an unkeyed task by token.
    func cancel(id: UUID) {
        unkeyedTasks.removeValue(forKey: id)?.cancel()
    }

    /// Cancel and remove all tracked tasks.
    func cancelAll() {
        for (_, cancellable) in keyedTasks {
            cancellable.cancel()
        }
        keyedTasks.removeAll()
        for (_, cancellable) in unkeyedTasks {
            cancellable.cancel()
        }
        unkeyedTasks.removeAll()
    }

    var activeKeyedCount: Int { keyedTasks.count }
    var activeCount: Int { keyedTasks.count + unkeyedTasks.count }
    func contains(key: String) -> Bool { keyedTasks[key] != nil }
}

/// Pure structure-aware Markdown splitter and skeleton verifier extracted from `WorkspaceManager` (`AR-14`).
enum MarkdownDocumentChunker {
    /// One atomic unit of a Markdown document.
    struct Chunk: Equatable {
        var text: String
        var separator: String
        var isTranslatable: Bool
    }

    /// Structural fingerprint of a Markdown fragment.
    struct Skeleton: Equatable {
        var headingLevels: [Int] = []
        var tableRows: Int = 0
        var listItems: Int = 0
        var fences: Int = 0
        var quoteLines: Int = 0
    }

    /// Strip a wrapping top-level code fence from a translated Markdown chunk.
    static func normalizeTranslation(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 2,
           let first = lines.first?.trimmingCharacters(in: .whitespaces),
           let last = lines.last?.trimmingCharacters(in: .whitespaces),
           first.hasPrefix("```"), last == "```",
           !lines.dropFirst().dropLast().contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .newlines)
    }

    /// Split Markdown into translation chunks without cutting through tables, lists, block quotes, or code blocks.
    static func splitForTranslation(_ markdown: String, maxChars: Int = 4000) -> (prefix: String, chunks: [Chunk]) {
        let (prefix, blocks) = tokenizeMarkdown(markdown)
        var chunks: [Chunk] = []
        var current: [Chunk] = []

        func flush() {
            guard !current.isEmpty else { return }
            var text = ""
            for (i, block) in current.enumerated() {
                text += block.text
                if i < current.count - 1 { text += block.separator }
            }
            chunks.append(Chunk(text: text, separator: current[current.count - 1].separator, isTranslatable: true))
            current = []
        }

        for block in blocks {
            guard block.isTranslatable else {
                flush()
                chunks.append(block)
                continue
            }
            let currentLength = current.reduce(0) { $0 + $1.text.count + $1.separator.count }
            if !current.isEmpty && currentLength + block.text.count > maxChars {
                flush()
            }
            current.append(block)
        }
        flush()
        return (prefix, chunks)
    }

    /// Break Markdown into atomic blocks; YAML front matter and fenced code blocks are marked non-translatable.
    static func tokenizeMarkdown(_ markdown: String) -> (prefix: String, blocks: [Chunk]) {
        let lines = markdown.components(separatedBy: "\n")
        let pieces: [String] = lines.enumerated().map { i, line in
            i < lines.count - 1 ? line + "\n" : line
        }
        let n = lines.count

        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespacesAndNewlines) }
        func isBlank(_ i: Int) -> Bool { trimmed(i).isEmpty }
        func isHeading(_ i: Int) -> Bool { trimmed(i).range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil }
        func isListItem(_ i: Int) -> Bool { lines[i].range(of: #"^\s{0,3}([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil }
        func isQuote(_ i: Int) -> Bool { trimmed(i).hasPrefix(">") }
        func isIndented(_ i: Int) -> Bool { lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") }
        func fenceMarker(_ i: Int) -> (char: Character, count: Int)? {
            let t = trimmed(i)
            guard let first = t.first, first == "`" || first == "~" else { return nil }
            let count = t.prefix(while: { $0 == first }).count
            return count >= 3 ? (first, count) : nil
        }
        func isTableDelimiter(_ i: Int) -> Bool {
            let t = trimmed(i)
            guard t.contains("-"), t.contains("|") else { return false }
            return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
        }
        func isTableStart(_ i: Int) -> Bool {
            lines[i].contains("|") && i + 1 < n && isTableDelimiter(i + 1)
        }
        func startsNewBlock(_ i: Int) -> Bool {
            fenceMarker(i) != nil || isHeading(i) || isListItem(i) || isQuote(i) || isTableStart(i)
        }

        var ranges: [(start: Int, end: Int, translatable: Bool)] = []
        var i = 0

        if n > 1, trimmed(0) == "---" {
            var j = 1
            while j < n, trimmed(j) != "---" { j += 1 }
            if j < n {
                ranges.append((0, j + 1, false))
                i = j + 1
            }
        }

        while i < n {
            if isBlank(i) { i += 1; continue }
            let start = i

            if let fence = fenceMarker(i) {
                i += 1
                while i < n {
                    if let close = fenceMarker(i), close.char == fence.char, close.count >= fence.count { break }
                    i += 1
                }
                if i < n { i += 1 }
                ranges.append((start, i, false))
            } else if isTableStart(i) {
                i += 2
                while i < n, !isBlank(i), lines[i].contains("|") { i += 1 }
                ranges.append((start, i, true))
            } else if isListItem(i) || isQuote(i) {
                i += 1
                while i < n {
                    if isBlank(i) {
                        var j = i
                        while j < n, isBlank(j) { j += 1 }
                        if j < n, isListItem(j) || isQuote(j) || isIndented(j) { i = j } else { break }
                    } else if isListItem(i) || isQuote(i) || isIndented(i) || !startsNewBlock(i) {
                        i += 1
                    } else {
                        break
                    }
                }
                ranges.append((start, i, true))
            } else if isHeading(i) {
                i += 1
                ranges.append((start, i, true))
            } else {
                i += 1
                while i < n, !isBlank(i), !startsNewBlock(i) { i += 1 }
                ranges.append((start, i, true))
            }
        }

        guard let firstRange = ranges.first else {
            return (markdown, [])
        }

        let prefix = pieces[0..<firstRange.start].joined()
        var blocks: [Chunk] = []
        for (idx, range) in ranges.enumerated() {
            var text = pieces[range.start..<range.end].joined()
            var separator = ""
            if text.hasSuffix("\r\n") {
                text.removeLast()
                separator = "\r\n"
            } else if text.hasSuffix("\n") {
                text.removeLast()
                separator = "\n"
            }
            let nextStart = idx + 1 < ranges.count ? ranges[idx + 1].start : n
            separator += pieces[range.end..<nextStart].joined()
            blocks.append(Chunk(text: text, separator: separator, isTranslatable: range.translatable))
        }
        return (prefix, blocks)
    }

    /// Compute the structural skeleton of a Markdown fragment.
    static func skeleton(of text: String) -> Skeleton {
        var result = Skeleton()
        var insideFence = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                result.fences += 1
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if line.isEmpty { continue }
            if let match = line.range(of: #"^#{1,6}(?=\s)"#, options: .regularExpression) {
                result.headingLevels.append(line.distance(from: line.startIndex, to: match.upperBound))
            } else if line.hasPrefix(">") {
                result.quoteLines += 1
            } else if line.contains("|") {
                result.tableRows += 1
            } else if rawLine.range(of: #"^\s{0,3}([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil {
                result.listItems += 1
            }
        }
        return result
    }
}
