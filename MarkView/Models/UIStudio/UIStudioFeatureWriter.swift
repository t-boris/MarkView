import Foundation

/// Writes the feature a UI Studio package creates (CAP-05), through the feature store like the prototype hand-off: the
/// overview carries the evidence, small captures are attached as sources, and each change becomes a requirement.
@MainActor
enum StudioFeatureWriter {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func write(_ package: StudioPackage, operations: [StudioOperation], root: URL, redactor: StudioRedactor,
                      into store: FeatureStore) async throws -> String {
        guard let slug = store.createFeature(title: package.title, idea: package.summary) else {
            throw Failure(message: store.lastError ?? "The feature could not be created.")
        }
        let provenance = "Exported from MarkView UI Studio"
        store.updateFeature(slug) { front, body in
            front.set("provenance", provenance)
            front.set("intake", "ui-studio")
            front.set("questions_left", "0")
            body = package.overview(redactor: redactor)
        }
        // The package hands the work to implementation: a specification stage, then the hand-off as start evidence.
        store.moveFeature(slug, to: "draft", by: .system("UI Studio"))
        store.markImplementing(slug, handoff: "UI Studio")
        var sources: [String] = []
        for picture in package.pictures where picture.inFeature {
            guard let source = store.create(.source, in: slug, title: picture.label,
                                            fields: [("origin", .string("ui-studio")), ("file", .string("")),
                                                     ("role", .string("screenshot")), ("facts", .list([]))],
                                            body: "## Origin\n\nCapture \(picture.captureId) from MarkView UI Studio.\n",
                                            provenance: provenance) else { continue }
            let name = "\(source.id)-\(picture.captureId).png"
            let copy = source.url.deletingLastPathComponent().appendingPathComponent(name)
            let from = root.appendingPathComponent(picture.file)
            let copied = await Task.detached { (try? FileManager.default.copyItem(at: from, to: copy)) != nil }.value
            guard copied else { _ = store.deleteObjects(slug, ids: [source.id]); continue }
            store.update(source.id, in: slug) { front, body in
                front.set("file", name)
                body += "\nFile: [\(name)](\(name))\n"
            }
            sources.append(source.id)
        }
        for operation in operations {
            let criteria = operation.checks.map { "\($0.name)" + ($0.passed ? "" : " (failed when exported)") }
            let statement = redactor.redact(text: operation.summary.isEmpty ? operation.request : operation.summary)
            let body = ProjectAgentTools.requirementBody(statement: statement,
                                                         criteria: ["Request: " + redactor.redact(text: operation.request)] + criteria)
                + (operation.patch.isEmpty ? "" : "\n## Code changes\n\n```diff\n" + redactor.redact(text: operation.patch) + "```\n")
            _ = store.create(.requirement, in: slug, title: String(operation.request.prefix(80)),
                             fields: [("status", .string("approved")), ("req_type", .string("functional")),
                                      ("depends_on", .list([])), ("decisions", .list([])),
                                      ("sources", .list(sources.map { .string($0) })), ("issues", .list([]))],
                             body: body, provenance: provenance)
        }
        store.reloadSync(slug)
        return slug
    }
}
