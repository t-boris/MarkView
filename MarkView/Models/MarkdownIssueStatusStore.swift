import Foundation

// The stored statuses of features and bugs as the lifecycle service reads and writes them: the `status` line of
// docs/features/<slug>/overview.md and of docs/bugs/BUG-nnn-*.md (issue-lifecycle-management, plan I-2, DEC-014).
// The service guards a write with a compare-and-set, so the file is read again immediately before it is written
// and nothing is written when another writer (another window, git, an editor) changed the status meanwhile.
// Foundation only (with FrontMatter.swift), so it can be checked on its own.

final class MarkdownIssueStatusStore: LifecycleStatusStore, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()

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
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bugsFolder.path)) ?? []
        let candidates = names.filter { $0.hasSuffix(".md") && $0.uppercased().hasPrefix(wanted) }
        for name in candidates.sorted() {
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
        let (parsed, body) = FrontMatter.split(text)
        var front = parsed
        guard front.isLossless else { throw Failure(message: "\(url.lastPathComponent) has YAML the app cannot rewrite safely — change it in the editor.") }
        let current = front.string("status").isEmpty ? (kind == .feature ? "idea" : "open") : front.string("status")
        guard LifecycleVocabulary.normalize(current) == LifecycleVocabulary.normalize(expected) else { return false }
        front.set("status", to)
        try front.join(body: body).write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
