import Foundation

/// Writes the feature that "Hand off to code" creates (feature "Prototype and code stay in step", REQ-016, REQ-017).
///
/// What is written is decided by `PrototypeHandoff.featurePlan`; this only applies the plan to the feature store: the feature with status
/// ready and the review's provenance, one source per screenshot (the PNG copied next to its source file under `references/`), and one
/// approved requirement per changed unit that links its screenshots. No assistant takes part and nothing outside the new feature's folder
/// is written. A screenshot that cannot be copied is left out and reported; it never stops the feature from being created.
@MainActor
enum PrototypeFeatureWriter {
    struct Created: Equatable {
        var slug: String
        var overview: URL
        var requirements: Int
        var pictures: Int
        /// Screenshots that could not be attached, in words.
        var skipped: [String]
    }

    struct Failure: Error, LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static func write(_ plan: PrototypeHandoff.FeaturePlan, into store: FeatureStore) async throws -> Created {
        guard let slug = store.createFeature(title: plan.title, idea: plan.idea) else {
            throw Failure(message: store.lastError ?? "The feature could not be created.")
        }
        store.updateFeature(slug) { front, body in
            front.set("provenance", plan.provenance)
            front.set("status", "ready")
            front.set("intake", "prototype")
            front.set("questions_left", "0")
            body = plan.overview
        }

        // Sources first: a requirement links the ids they were given.
        struct Attached { var id: String; var title: String; var link: String }
        var attached: [String: [Attached]] = [:]
        var skipped: [String] = []
        for picture in plan.pictures {
            let origin = "Screenshot of \"\(picture.title)\", taken by Prototype Studio from the prototype's saved files."
            guard let source = store.create(.source, in: slug, title: picture.title,
                                            fields: [("origin", .string("prototype")), ("file", .string("")),
                                                     ("role", .string("screenshot")), ("facts", .list([]))],
                                            body: "## Origin\n\n\(origin)\n", provenance: plan.provenance) else {
                skipped.append("\(picture.title): \(store.lastError ?? "the source could not be written")")
                continue
            }
            let name = "\(source.id)-\(PrototypeHandoff.shotFileName(unitID: picture.unitID, side: picture.side))"
            let copy = source.url.deletingLastPathComponent().appendingPathComponent(name)
            let from = URL(fileURLWithPath: picture.file)
            let copied = await Task.detached { () -> Bool in
                do { try FileManager.default.copyItem(at: from, to: copy); return true } catch { return false }
            }.value
            guard copied else {
                skipped.append("\(picture.title): the picture could not be copied")
                _ = store.deleteObjects(slug, ids: [source.id])
                continue
            }
            store.update(source.id, in: slug) { front, body in
                front.set("file", name)
                body += "\nFile: [\(name)](\(name))\n"
            }
            attached[picture.unitID, default: []].append(Attached(id: source.id, title: picture.title, link: "../\(FeatureObjectKind.source.folder)/\(name)"))
        }

        var written = 0
        for requirement in plan.requirements {
            let pictures = attached[requirement.unitID] ?? []
            let body = ProjectAgentTools.requirementBody(statement: requirement.statement, criteria: requirement.criteria)
                + PrototypeHandoff.screenshotsSection(pictures.map { (title: $0.title, link: $0.link) })
            if store.create(.requirement, in: slug, title: requirement.title,
                            fields: [("status", .string("approved")), ("req_type", .string("functional")),
                                     ("depends_on", .list([])), ("decisions", .list([])),
                                     ("sources", .list(pictures.map { .string($0.id) })), ("issues", .list([]))],
                            body: body, provenance: plan.provenance) != nil {
                written += 1
            }
        }
        guard written == plan.requirements.count else {
            throw Failure(message: "The feature \(slug) was created, but only \(written) of \(plan.requirements.count) requirements could be written: \(store.lastError ?? "unknown error").")
        }
        store.reloadSync(slug)
        guard let overview = store.feature(slug)?.overviewURL else { throw Failure(message: "The feature \(slug) was written but could not be read back.") }
        return Created(slug: slug, overview: overview, requirements: written, pictures: plan.pictures.count - skipped.count, skipped: skipped)
    }
}
