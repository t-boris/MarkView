import Foundation

/// Change tracking of a UI Studio session (REQ-012, DEC-008). A conversation that changes code or context is one feature,
/// titled from its first applied change; each applied change is a requirement of it, or a fixed bug report linked to it
/// when the assistant classified a code change as a repair. The change's turn shows where it went and can switch it between
/// requirement and bug; Undo marks the record reverted. Nothing is deleted, every text is redacted (`StudioTrackingText`),
/// and everything goes through the project's feature store, so it works without any GitHub integration.
extension StudioSession {
    /// The conversation's feature: the one its first recorded change created. Clear starts a new conversation, so the
    /// next change starts the next feature.
    var conversationFeature: String? {
        conversation.lazy.compactMap(\.tracking).first { $0.isRecorded }?.feature
    }

    /// Records an applied change as a requirement of the conversation's feature, or as a fixed bug linked to it when the
    /// assistant called it a repair. Call it after the change is verified and before the operation is stored again. A
    /// change that is not applied, or is recorded already, is left alone; when the store cannot write, the notice says so.
    func trackChange(_ operation: inout StudioOperation) async {
        guard operation.kind == .edit, operation.status == .applied, !operation.files.isEmpty,
              operation.tracking?.isRecorded != true, let store = featureStore() else { return }
        let text = trackingText()
        guard let feature = trackingFeature(for: operation, store: store, text: text) else { return }
        let base = await attachPictures(of: operation, to: feature, store: store, text: text)
        operation.tracking = operation.changeKind == .repair
            ? recordBug(operation, tracking: base, store: store, text: text)
            : recordRequirement(operation, tracking: base, store: store, text: text)
    }

    /// Records an applied context turn (REQ-013: a new saved scenario, no code) as a requirement of the conversation's
    /// feature, with the scenario it made and what changed; a context change is never a repair, so it is not classified.
    /// Call it once the new scenario is verified, before the operation is stored again; `trackUndo` marks its Undo.
    func trackContextChange(_ operation: inout StudioOperation) async {
        guard operation.kind == .context, operation.status == .applied, operation.context?.scenarioId.isEmpty == false,
              operation.tracking?.isRecorded != true, let store = featureStore() else { return }
        let text = trackingText()
        guard let feature = trackingFeature(for: operation, store: store, text: text) else { return }
        let base = await attachPictures(of: operation, to: feature, store: store, text: text)
        operation.tracking = recordRequirement(operation, tracking: base, store: store, text: text, context: true)
    }

    /// Marks an undone change's record reverted: a requirement becomes rejected and a bug closed, each with a note.
    /// Nothing is deleted. Call it once the undo is written.
    func trackUndo(_ operation: StudioOperation) {
        guard operation.status == .undone, let tracking = operation.tracking, tracking.isRecorded, let store = featureStore() else { return }
        let note = trackingText().revertNote(isBug: tracking.isBug, context: operation.kind == .context)
        mark(tracking, status: tracking.isBug ? "closed" : "rejected", note: note, store: store)
    }

    /// Moves a change's record between requirement and bug: the new record is written first, with the same pictures,
    /// then the old one is marked superseded (a requirement) or closed (a bug) with a note naming the new one.
    func switchTracking(_ id: String) {
        guard let operation = history.first(where: { $0.id == id }), operation.kind == .edit,
              operation.tracking?.isRecorded == true, [.applied, .kept].contains(operation.status), featureStore() != nil else { return }
        runWork("Moving the record") { session in
            guard var next = session.history.first(where: { $0.id == id }), let old = next.tracking, old.isRecorded,
                  let store = session.featureStore() else { return }
            let text = session.trackingText()
            next.changeKind = old.isBug ? .change : .repair
            var base = old
            base.id = ""
            base.file = ""
            let moved = old.isBug
                ? session.recordRequirement(next, tracking: base, store: store, text: text, movedFrom: old.id)
                : session.recordBug(next, tracking: base, store: store, text: text, movedFrom: old.id)
            guard let moved else { return }
            session.mark(old, status: old.isBug ? "closed" : "superseded", note: text.movedNote(to: moved), store: store)
            next.tracking = moved
            session.replace(next)
        }
    }

    // MARK: - Records

    private func trackingText() -> StudioTrackingText {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return StudioTrackingText(redactor: StudioRedactor(fields: spec.confidentialFields), hashes: sessionLog.secretHashes,
                                  date: formatter.string(from: Date()))
    }

    /// The conversation's feature, created with the first change that is recorded.
    private func trackingFeature(for operation: StudioOperation, store: FeatureStore, text: StudioTrackingText) -> String? {
        if let slug = conversationFeature, store.feature(slug) != nil { return slug }
        let title = text.featureTitle(operation)
        guard let slug = store.createFeature(title: title, idea: text.clean(operation.request)) else {
            notice = "The change was not tracked: " + (store.lastError ?? "the feature could not be created.")
            return nil
        }
        store.updateFeature(slug) { front, body in
            front.set("provenance", StudioTrackingText.provenance)
            front.set("status", "implementing")
            front.set("intake", "ui-studio")
            front.set("questions_left", "0")
            body = text.featureOverview(title: title, operation)
        }
        return slug
    }

    /// The change's before and after captures as sources of the feature (small ones only, as in an export), so that the
    /// requirement or the bug can show them.
    private func attachPictures(of operation: StudioOperation, to feature: String, store: FeatureStore,
                                text: StudioTrackingText) async -> StudioOperation.Tracking {
        var tracking = StudioOperation.Tracking(feature: feature)
        for id in [operation.beforeCapture, operation.afterCapture].compactMap({ $0 }) {
            guard let capture = captures.first(where: { $0.id == id }) else { continue }
            let from = url(of: capture)
            let size = await Task.detached { (try? FileManager.default.attributesOfItem(atPath: from.path)[.size] as? Int) ?? 0 }.value
            // Titled from the redacted request: a capture's label cuts the raw request, which can leave part of a secret.
            let title = (id == operation.beforeCapture ? "Before: " : "After: ") + text.line(operation.request, limit: 60)
            guard size > 0, size <= StudioPackage.inFeatureLimit,
                  let source = store.create(.source, in: feature, title: title,
                                            fields: [("origin", .string("ui-studio")), ("file", .string("")),
                                                     ("role", .string("screenshot")), ("facts", .list([]))],
                                            body: "## Origin\n\nCapture \(capture.id) of a change made in MarkView UI Studio.\n",
                                            provenance: StudioTrackingText.provenance) else { continue }
            let name = "\(source.id)-\(capture.id).png"
            let copy = source.url.deletingLastPathComponent().appendingPathComponent(name)
            let copied = await Task.detached { (try? FileManager.default.copyItem(at: from, to: copy)) != nil }.value
            guard copied else {
                _ = store.deleteObjects(feature, ids: [source.id])
                continue
            }
            store.update(source.id, in: feature) { front, body in
                front.set("file", name)
                body += "\nFile: [\(name)](\(name))\n"
            }
            tracking.sources.append(source.id)
            tracking.pictures.append(trackingPath(copy) ?? "")
        }
        return tracking
    }

    private func trackingFacts(_ operation: StudioOperation, _ tracking: StudioOperation.Tracking,
                               movedFrom: String?) -> StudioTrackingText.Facts {
        let known = [scenario] + savedScenarios + presets
        let scenarioText = operation.scenarioId.map { id in known.first { $0.id == id }.map { "\($0.name) (route \($0.route))" } ?? id } ?? ""
        let pictures = zip(tracking.sources, tracking.pictures).map { source, file in
            let label = operation.beforeCapture.map { file.contains($0) } == true ? "Before"
                : operation.afterCapture.map { file.contains($0) } == true ? "After" : "Picture"
            return (label: label, source: source, file: file)
        }
        return StudioTrackingText.Facts(scenario: scenarioText, pictures: pictures, movedFrom: movedFrom)
    }

    private func recordRequirement(_ operation: StudioOperation, tracking: StudioOperation.Tracking, store: FeatureStore,
                                   text: StudioTrackingText, movedFrom: String? = nil, context: Bool = false) -> StudioOperation.Tracking? {
        let facts = trackingFacts(operation, tracking, movedFrom: movedFrom)
        guard let object = store.create(.requirement, in: tracking.feature,
                                        title: context ? text.contextTitle(operation) : text.requirementTitle(operation),
                                        fields: [("status", .string("approved")), ("req_type", .string("ux")),
                                                 ("depends_on", .list([])), ("decisions", .list([])),
                                                 ("sources", .list(tracking.sources.map { .string($0) })), ("issues", .list([]))],
                                        body: context ? text.contextBody(operation, facts: facts) : text.requirementBody(operation, facts: facts),
                                        provenance: StudioTrackingText.provenance) else {
            notice = "The change was not tracked: " + (store.lastError ?? "the requirement could not be written.")
            return nil
        }
        var next = tracking
        next.id = object.id
        next.file = trackingPath(object.url) ?? ""
        return next
    }

    private func recordBug(_ operation: StudioOperation, tracking: StudioOperation.Tracking, store: FeatureStore,
                           text: StudioTrackingText, movedFrom: String? = nil) -> StudioOperation.Tracking? {
        let facts = trackingFacts(operation, tracking, movedFrom: movedFrom)
        let folder = store.bugsFolder.flatMap(trackingPath) ?? "docs/bugs"
        let draft = text.bugDraft(operation, feature: tracking.feature, facts: facts, reporter: store.defaultOwner, folder: folder)
        do {
            let written = try store.createBug(draft)
            var next = tracking
            next.id = written.id
            next.file = trackingPath(written.url) ?? ""
            return next
        } catch {
            notice = "The repair was not tracked: \(error.localizedDescription)"
            return nil
        }
    }

    /// Sets a record's status and appends a note; a bug report is found by its file, which must be in the project.
    private func mark(_ tracking: StudioOperation.Tracking, status: String, note: String, store: FeatureStore) {
        guard tracking.isBug else {
            store.update(tracking.id, in: tracking.feature) { front, body in
                front.set("status", status)
                body += note
            }
            return
        }
        let marked = StudioChanges.validatedURL(tracking.file, root: root).map { url in
            url.pathExtension == "md" && store.updateBug(url) { front, body in
                front.set("status", status)
                body += note
            }
        } ?? false
        if !marked { notice = "\(tracking.id) could not be marked \(status): " + (store.lastError ?? "its report is not in the project.") }
    }

    /// `url` relative to the project root, or nil when it is outside it.
    private func trackingPath(_ url: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
}
