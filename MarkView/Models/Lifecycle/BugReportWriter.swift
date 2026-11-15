import Foundation

/// A new bug report for `docs/bugs/`, before it has an id.
struct BugReportDraft: Sendable {
    var title: String
    /// The Markdown after the front matter (`ProjectAgentTools.bugBody` for the markview tool).
    var body: String
    var status = "open"
    var severity = "medium"
    var reporter = ""
    var provenance: String
    /// More front matter after the standard keys, in this order (UI Studio links its bugs with `feature`).
    var fields: [(key: String, value: String)] = []
}

/// Writes new bug report files (`docs/bugs/BUG-NNN-<slug>.md`), the one writer of the `markview_create_bug` tool and of UI
/// Studio's change tracking (REQ-012), so both produce the same file. Numbering and reloading stay with `FeatureStore`.
enum BugReportWriter {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The report's file name: its id and at most 50 characters of the title's slug.
    static func fileName(id: String, slug: String) -> String { "\(id)-\(slug.prefix(50)).md" }

    /// The whole file: front matter (type, id, title, status, severity, reporter, created, provenance, then `fields`) and body.
    static func text(_ draft: BugReportDraft, id: String, created: String) -> String {
        var front = FrontMatter()
        front.set("type", "bug")
        front.set("id", id)
        front.set("title", draft.title)
        front.set("status", draft.status)
        front.set("severity", draft.severity)
        front.set("reporter", draft.reporter)
        front.set("created", created)
        front.set("provenance", draft.provenance)
        for field in draft.fields { front.set(field.key, field.value) }
        return front.join(body: draft.body)
    }

    /// Writes the report into `folder` (created when missing), never over an existing file. Returns the file.
    @discardableResult
    static func write(_ draft: BugReportDraft, id: String, slug: String, created: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(fileName(id: id, slug: slug))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text(draft, id: id, created: created).utf8).write(to: file, options: .withoutOverwriting)
        return file
    }
}
