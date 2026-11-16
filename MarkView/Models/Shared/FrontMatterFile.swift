import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The schema of the Markdown files that the app and the people of a project both write: features, requirements, questions,
/// decisions, findings, plans and bug reports (`AR-39`).
///
/// A file says which version of the app's file format wrote it in its front matter (`schema: 1`). The file stays plain Markdown that a
/// person edits and commits:
/// - A file without the key was written before the schema existed (version 0). It loads unchanged and gets the key on the next write.
/// - A file whose schema is newer than this build knows is never rewritten: a newer MarkView may have added fields or meanings that
///   this build would drop, so the write is refused (`NewerSchemaFile`) and the caller shows why.
/// - A file that cannot be read is never replaced.
///
/// Locking: nothing here locks the file between the check and the write, and no other store in the app does (the only lock helper is
/// `CockpitResults.withLock`, for the cockpit's own result files). `AtomicFile` makes a reader see the old file or the new one; two
/// writers at once (two windows, an editor and the app) still end with the last one. A project-wide scheme for that is a design
/// decision of its own and is not made here.
extension FrontMatter {
    /// The version of the file format this build writes.
    static let currentSchema = 1
    static let schemaKey = "schema"

    /// The schema the front matter carries; 0 for a file written before the schema existed.
    var schemaVersion: Int { Int(string(Self.schemaKey)) ?? 0 }

    /// Puts the current schema in the front matter when it has none or an older one. A newer one is never lowered.
    mutating func stampSchema() {
        if schemaVersion < Self.currentSchema { set(Self.schemaKey, String(Self.currentSchema)) }
    }

    /// Writes the file: this front matter (stamped with the current schema) and `body`, in place and atomically. Throws
    /// `NewerSchemaFile` and leaves the file alone when the file on disk was written by a newer MarkView; throws and leaves the file
    /// alone when it exists and cannot be read.
    func writeFile(body: String, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            let found = FrontMatter.split(existing).0.schemaVersion
            if found > Self.currentSchema {
                AppLog.store.error("\(url.lastPathComponent): written by a newer MarkView (schema \(found)); it is not rewritten")
                throw NewerSchemaFile(url: url, found: found)
            }
        }
        var stamped = self
        stamped.stampSchema()
        try AtomicFile.write(stamped.join(body: body), to: url)
    }
}

struct NewerSchemaFile: LocalizedError, Equatable {
    let url: URL
    let found: Int

    var errorDescription: String? {
        "\(url.lastPathComponent) was written by a newer MarkView (schema \(found); this one writes \(FrontMatter.currentSchema)). It is left untouched: update MarkView to change it."
    }
}
