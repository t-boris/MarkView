import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// The stored statuses of features and bugs as the lifecycle service reads and writes them: the `status` line of
// docs/features/<slug>/overview.md and of docs/bugs/BUG-nnn-*.md (issue-lifecycle-management, plan I-2, DEC-014).
// The service guards a write with a compare-and-set, so the file is read again immediately before it is written
// and nothing is written when another writer (another window, git, an editor) changed the status meanwhile.
// Foundation only (with FrontMatter.swift), so it can be checked on its own.

// unchecked Sendable: `root` is a `let`; `lock` orders the read-modify-write of a status and `namesLock` guards the name cache.
final class MarkdownIssueStatusStore: LifecycleStatusStore, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private let namesLock = NSLock()
    private var namesSignature: String?
    private var namesByPrefix: [String: [String]] = [:]

    init(root: URL) { self.root = root }

    var featuresFolder: URL { root.appendingPathComponent("docs/features", isDirectory: true) }
    var bugsFolder: URL { root.appendingPathComponent("docs/bugs", isDirectory: true) }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    // MARK: Locating

    func fileURL(kind: IssueKind, issue: String) -> URL? {
        switch kind {
        case .feature:
            guard issue.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { return nil }
            let folder = featuresFolder.appendingPathComponent(issue, isDirectory: true)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            return folder.appendingPathComponent("overview.md")
        case .bug:
            return bugFile(key: issue)
        }
    }

    /// The report whose front matter `id` is `key`, else the one whose file name starts with it ("BUG-012-…").
    func bugFile(key: String) -> URL? {
        let wanted = key.uppercased()
        let path = bugsFolder.path
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let signature = "\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        namesLock.lock()
        if namesSignature != signature {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            var index: [String: [String]] = [:]
            for name in names where name.hasSuffix(".md") {
                let key = name.uppercased().split(separator: "-", maxSplits: 2).prefix(2).joined(separator: "-")
                index[key, default: []].append(name)
            }
            namesByPrefix = index.mapValues { $0.sorted() }
            namesSignature = signature
        }
        // Existing callers use IDs such as BUG-012. Preserve the prefix fallback for unusual IDs.
        let candidates = namesByPrefix.filter { $0.key.hasPrefix(wanted) }.values.flatMap { $0 }.sorted()
        namesLock.unlock()
        for name in candidates {
            let url = bugsFolder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let id = FrontMatter.split(text).0.string("id")
            if id.isEmpty ? name.uppercased().hasPrefix(wanted + "-") || name.uppercased() == wanted + ".MD" : id.uppercased() == wanted { return url }
        }
        return nil
    }

    // MARK: LifecycleStatusStore

    func status(kind: IssueKind, issue: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return readStatus(kind: kind, issue: issue)
    }

    private func readStatus(kind: IssueKind, issue: String) -> String? {
        guard let url = fileURL(kind: kind, issue: issue) else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // A feature folder without an overview is a hand-written feature: the app reads its status as draft.
            return kind == .feature ? "draft" : nil
        }
        let status = FrontMatter.split(text).0.string("status")
        if status.isEmpty { return kind == .feature ? "idea" : "open" }
        return status
    }

    func compareAndSet(kind: IssueKind, issue: String, expected: String, to: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let url = fileURL(kind: kind, issue: issue) else { throw Failure(message: "\(issue) has no file.") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(message: "\(url.lastPathComponent) of \(issue) could not be read.")
        }
        let (front, body) = FrontMatter.split(text)
        let stored = front.string("status")
        let current = stored.isEmpty ? (kind == .feature ? "idea" : "open") : stored
        guard LifecycleVocabulary.normalize(current) == LifecycleVocabulary.normalize(expected) else { return false }
        if front.isLossless {
            var updated = front
            updated.set("status", to)
            try updated.writeFile(body: body, to: url)
        } else {
            guard front.schemaVersion <= FrontMatter.currentSchema else {
                throw NewerSchemaFile(url: url, found: front.schemaVersion)
            }
            guard let updated = Self.replacingStatus(in: text, stored: stored, with: to) else {
                throw Failure(message: "\(url.lastPathComponent) has YAML the app cannot rewrite safely — change it in the editor.")
            }
            guard try String(contentsOf: url, encoding: .utf8).utf8.elementsEqual(text.utf8) else { return false }
            try AtomicFile.write(updated, to: url)
        }
        return true
    }

    private static let statusLine = try? NSRegularExpression(
        pattern: #"\Astatus[ \t]*:[ \t]+(['"]?)([A-Za-z0-9_ -]+?)\1(?:[ \t]+#[^\r]*)?[ \t]*\r?\z"#)
    private static let complexValue = try? NSRegularExpression(
        pattern: #"\A(?:-[ \t]+)?(?:[^:]+:[ \t]+)?(['"\[{&!].*)\z"#)
    private static let singleLineValue = #"\A(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|\[[^\[\]{}'"]*\]|\{[^\[\]{}'"]*\})(?:[ \t]+#.*)?\z"#

    /// Edit a single existing block-map field when the rest of the front matter cannot round-trip.
    /// A field under an unclosed quoted or flow value can look unindented, so require those values
    /// before the status to fit on one line. Keep ambiguous or multiline status fields untouched.
    private static func replacingStatus(in text: String, stored: String, with replacement: String) -> String? {
        guard let statusLine, let complexValue, !stored.isEmpty,
              replacement.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil else { return nil }
        var lines = text.components(separatedBy: "\n")
        func isDelimiter(_ line: String) -> Bool {
            line.hasPrefix("---") && line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }
        guard lines.first.map(isDelimiter) == true,
              let end = lines.dropFirst().firstIndex(where: isDelimiter) else { return nil }
        var statusIndex: Int?
        for index in 1..<end {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let listItem = trimmed == "-" || trimmed.hasPrefix("- ")
            if line.first?.isWhitespace == false, !listItem {
                guard let key = trimmed.range(of: #"\A[A-Za-z0-9_.-]+(?=[ \t]*:(?:[ \t]|\z))"#,
                                              options: .regularExpression) else { return nil }
                if trimmed[key] == "status" {
                    guard statusIndex == nil else { return nil }
                    statusIndex = index
                    continue
                }
            }
            if statusIndex == nil,
               let match = complexValue.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let value = Range(match.range(at: 1), in: trimmed),
               trimmed[value].range(of: singleLineValue, options: .regularExpression) == nil {
                return nil
            }
        }
        guard let index = statusIndex else { return nil }
        if let next = lines[(index + 1)..<end].first(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }), next.first?.isWhitespace == true || next == "-" || next.hasPrefix("- ") {
            return nil
        }
        let line = lines[index]
        guard let match = statusLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let value = Range(match.range(at: 2), in: line), line[value] == stored else { return nil }
        lines[index].replaceSubrange(value, with: replacement)
        return lines.joined(separator: "\n")
    }
}
