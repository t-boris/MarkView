import Foundation

/// The app side of `ProjectAgentTools`: performs one tool call against the project of one window
/// (its `FeatureStore`). Reads show the files as the app understands them; writes go through the
/// store, so ids, links and front matter are the ones the app itself would write. Nothing outside the
/// window's project is ever named by a tool: features are chosen by slug among the project's own.
@MainActor
enum ProjectToolRunner {
    static func run(_ tool: String, _ args: [String: Any], store: FeatureStore) -> BrowserAgentTools.Reply {
        guard let root = store.root else { return .error("This window has no project folder open.") }
        // The files may have changed since the app last looked (an agent, git, the user's editor).
        store.reloadSync()
        do {
            switch tool {
            case "markview_guide": return .init(text: ProjectAgentTools.guide(args["topic"] as? String))
            case "markview_project": return .init(text: project(store, root))
            case "markview_list_features": return .init(text: listFeatures(store, status: try ProjectAgentTools.text(args, "status")))
            case "markview_get_feature": return try getFeature(store, args)
            case "markview_list_bugs": return .init(text: listBugs(store, status: try ProjectAgentTools.text(args, "status")))
            case "markview_get_bug": return try getBug(store, args)
            case "markview_list_prototypes": return .init(text: listPrototypes(root))
            case "markview_get_prototype": return try getPrototype(root, args)
            case "markview_create_feature": return try createFeature(store, args)
            case "markview_add_requirement": return try addRequirement(store, args)
            case "markview_add_decision": return try addDecision(store, args)
            case "markview_add_question": return try addQuestion(store, args)
            case "markview_create_bug": return try createBug(store, args)
            case "markview_set_status": return try setStatus(store, args)
            default: return .error("Unknown tool \(tool).")
            }
        } catch let invalid as ProjectAgentTools.Invalid {
            return .error(invalid.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static let outputLimit = 40_000

    private static func clip(_ text: String) -> String {
        text.count <= outputLimit ? text : String(text.prefix(outputLimit)) + "\n… (cut: \(text.count - outputLimit) more characters)"
    }

    // MARK: - Reading

    private static func project(_ store: FeatureStore, _ root: URL) -> String {
        let statuses = Dictionary(grouping: store.features, by: \.status).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        return """
        Project folder: \(root.path)
        Features: \(store.features.count)\(statuses.isEmpty ? "" : " (\(statuses))")
        Bugs: \(store.bugs.count) (\(store.bugs.filter { $0.status != "closed" && $0.status != "fixed" }.count) not closed)
        Prototypes: \(PrototypeFiles.existingSlugs(root: root).count)
        Features folder: \(FeatureStore.folderName)/
        """
    }

    private static func listFeatures(_ store: FeatureStore, status: String) -> String {
        let features = store.features.filter { status.isEmpty || $0.status == status }
        guard !features.isEmpty else { return status.isEmpty ? "No features yet." : "No features with status \(status)." }
        return clip(features.map { f in
            let counts = FeatureObjectKind.allCases.compactMap { kind -> String? in
                let n = f.list(kind).count
                return n == 0 ? nil : "\(n) \(kind.prefix)"
            }.joined(separator: ", ")
            return "\(f.slug) — \(f.title) [\(f.status)] readiness \(f.readiness)%" + (counts.isEmpty ? "" : " · \(counts)")
        }.joined(separator: "\n"))
    }

    private static func featureNamed(_ store: FeatureStore, _ args: [String: Any]) throws -> Feature {
        let slug = try ProjectAgentTools.text(args, "feature", required: true)
        guard ProjectAgentTools.isPlainName(slug), let feature = store.feature(slug) else {
            let known = store.features.map(\.slug).prefix(30).joined(separator: ", ")
            throw ProjectAgentTools.Invalid(message: "No feature \"\(slug)\" in this project." + (known.isEmpty ? " There are no features yet." : " Features: \(known)"))
        }
        return feature
    }

    private static func getFeature(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let id = try ProjectAgentTools.text(args, "id")
        if !id.isEmpty {
            guard let object = feature.object(id) else { throw ProjectAgentTools.Invalid(message: "\(feature.slug) has no object \(id).") }
            return .init(text: clip(object.text()))
        }
        var out = "\(feature.slug) — \(feature.title) [\(feature.status)] readiness \(feature.readiness)%\n"
        let understanding = feature.understanding.map { "\($0.dimension): \($0.state)" }.joined(separator: ", ")
        if !understanding.isEmpty { out += "Understanding: \(understanding)\n" }
        out += "\n" + feature.overviewBody.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        for kind in FeatureObjectKind.allCases where !feature.list(kind).isEmpty {
            out += "\n## \(kind.title)\n"
            for object in feature.list(kind) {
                let links = object.links.map { "\($0.relation) \($0.target)" }.joined(separator: "; ")
                out += "- \(object.id) [\(object.status)] \(object.title)" + (links.isEmpty ? "" : " (\(links))") + "\n"
            }
        }
        return .init(text: clip(out))
    }

    private static func listBugs(_ store: FeatureStore, status: String) -> String {
        let bugs = store.bugs.filter { status.isEmpty || $0.status == status }
        guard !bugs.isEmpty else { return "No bug reports" + (status.isEmpty ? "." : " with status \(status).") }
        return clip(bugs.map { "\($0.key) — \($0.title) [\($0.status), \($0.severity)]" }.joined(separator: "\n"))
    }

    private static func getBug(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let id = try ProjectAgentTools.text(args, "id", required: true).uppercased()
        guard let bug = store.bugs.first(where: { $0.key.uppercased() == id }),
              let text = try? String(contentsOf: bug.url, encoding: .utf8) else {
            throw ProjectAgentTools.Invalid(message: "No bug report \(id).")
        }
        return .init(text: clip(text))
    }

    private static func listPrototypes(_ root: URL) -> String {
        let slugs = PrototypeFiles.existingSlugs(root: root)
        guard !slugs.isEmpty else { return "No prototypes yet. They are made in Prototype Studio (AI Tools → Prototype)." }
        return slugs.compactMap { slug -> String? in
            guard let m = PrototypeFiles.loadManifest(PrototypeFiles.folder(root: root, slug: slug)) else { return nil }
            return "\(slug) — \(m.title) v\(m.version)\(m.approved ? " (approved)" : "") · \(m.screens.count) screens: \(m.screens.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    private static func getPrototype(_ root: URL, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let slug = try ProjectAgentTools.text(args, "prototype", required: true)
        guard ProjectAgentTools.isPlainName(slug), PrototypeFiles.existingSlugs(root: root).contains(slug) else {
            throw ProjectAgentTools.Invalid(message: "No prototype \"\(slug)\". " + listPrototypes(root))
        }
        let folder = PrototypeFiles.folder(root: root, slug: slug)
        let site = PrototypeFiles.site(of: folder)
        let file = try ProjectAgentTools.text(args, "file")
        if !file.isEmpty {
            let path = try PrototypeFiles.validate(path: file)
            guard let text = try? String(contentsOf: site.appendingPathComponent(path), encoding: .utf8) else {
                throw ProjectAgentTools.Invalid(message: "The prototype has no file \(path).")
            }
            return .init(text: clip(text))
        }
        guard let m = PrototypeFiles.loadManifest(folder) else { throw ProjectAgentTools.Invalid(message: "The prototype has no manifest.") }
        var out = "\(slug) — \(m.title) v\(m.version)\(m.approved ? " (approved)" : " (not approved yet)")\n"
        if !m.brief.isEmpty { out += "\nBrief: \(m.brief)\n" }
        out += "Requirement sources: \(m.sources.isEmpty ? "the project folder" : m.sources.joined(separator: ", "))\n"
        out += "\nScreens: \(m.screens.joined(separator: ", "))\n"
        if !m.assumptions.isEmpty { out += "\nAssumptions:\n" + m.assumptions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !m.history.isEmpty {
            out += "\nReview history:\n" + m.history.map { "- v\($0.version): " + ($0.instruction.isEmpty ? "(build)" : $0.instruction) + " → " + $0.summary }.joined(separator: "\n") + "\n"
        }
        out += "\nFiles (read one with `file`):\n" + PrototypeFiles.read(site: site).map { "- \($0.path) (\($0.content.utf8.count) bytes)" }.joined(separator: "\n") + "\n"
        if let spec = try? String(contentsOf: folder.appendingPathComponent("SPEC.md"), encoding: .utf8) {
            out += "\n=== SPEC.md ===\n\(spec)"
        } else {
            out += "\nNo SPEC.md yet: the prototype was not exported. Work from the screens, files and review history."
        }
        return .init(text: clip(out))
    }

    // MARK: - Writing

    private static func provenance(_ source: String) -> String {
        "Created by an AI agent through MarkView" + (source.isEmpty ? "" : " from \(source)")
    }

    private static func createFeature(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let title = try ProjectAgentTools.text(args, "title", required: true)
        guard title.count <= 200 else { throw ProjectAgentTools.Invalid(message: "`title` is too long (200 characters at most).") }
        let idea = try ProjectAgentTools.text(args, "idea")
        let status = try ProjectAgentTools.choice(args, "status", in: ProjectAgentTools.agentFeatureStatuses, default: idea.isEmpty ? "idea" : "exploring")
        var states: [String: String] = [:]
        if let given = args["understanding"] as? [String: Any] {
            for (dimension, value) in given {
                guard FeatureVocabulary.understanding.contains(dimension) else {
                    throw ProjectAgentTools.Invalid(message: "Unknown understanding dimension \"\(dimension)\". Dimensions: \(FeatureVocabulary.understanding.joined(separator: ", ")).")
                }
                guard let state = (value as? String)?.lowercased(), FeatureVocabulary.understandingStates.contains(state) else {
                    throw ProjectAgentTools.Invalid(message: "`understanding.\(dimension)` must be one of: \(FeatureVocabulary.understandingStates.joined(separator: ", ")).")
                }
                states[dimension] = state
            }
        }
        let source = try ProjectAgentTools.text(args, "source")
        guard let slug = store.createFeature(title: title, idea: idea) else {
            return .error(store.lastError ?? "The feature could not be created.")
        }
        store.updateFeature(slug) { front, _ in
            front.set("status", status)
            front.set("provenance", provenance(source))
        }
        if !states.isEmpty { store.setUnderstanding(slug, states) }
        return .init(text: "Created feature \(slug) (\(FeatureStore.folderName)/\(slug)/overview.md), status \(status). Add requirements with markview_add_requirement.")
    }

    /// The ids that `key` lists must all exist in the feature as `kind`.
    private static func references(_ args: [String: Any], _ key: String, kind: FeatureObjectKind, in feature: Feature) throws -> [String] {
        let ids = try ProjectAgentTools.list(args, key)
        for id in ids where feature.list(kind).first(where: { $0.id == id }) == nil {
            throw ProjectAgentTools.Invalid(message: "`\(key)`: \(feature.slug) has no \(kind.rawValue) \(id).")
        }
        return ids
    }

    private static func addRequirement(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let title = try ProjectAgentTools.text(args, "title", required: true)
        let statement = try ProjectAgentTools.text(args, "statement", required: true)
        let criteria = try ProjectAgentTools.list(args, "acceptance_criteria")
        guard !criteria.isEmpty else { throw ProjectAgentTools.Invalid(message: "`acceptance_criteria` needs at least one testable criterion.") }
        let type = try ProjectAgentTools.choice(args, "req_type", in: FeatureVocabulary.requirementTypes, default: "functional")
        let status = try ProjectAgentTools.choice(args, "status", in: ["draft", "approved"], default: "draft")
        let depends = try references(args, "depends_on", kind: .requirement, in: feature)
        let decisions = try references(args, "decisions", kind: .decision, in: feature)
        if feature.list(.requirement).contains(where: { $0.title.lowercased() == title.lowercased() }) {
            throw ProjectAgentTools.Invalid(message: "\(feature.slug) already has a requirement titled \"\(title)\". Read it with markview_get_feature, or choose another title.")
        }
        let source = try ProjectAgentTools.text(args, "source")
        guard let object = store.create(.requirement, in: feature.slug, title: title,
                                        fields: [("status", .string(status)), ("req_type", .string(type)),
                                                 ("depends_on", .list(depends.map { .string($0) })), ("decisions", .list(decisions.map { .string($0) })),
                                                 ("sources", .list([])), ("issues", .list([]))],
                                        body: ProjectAgentTools.requirementBody(statement: statement, criteria: criteria),
                                        provenance: provenance(source)) else {
            return .error(store.lastError ?? "The requirement could not be written.")
        }
        return .init(text: "Added \(object.id) \"\(title)\" to \(feature.slug) [\(status), \(type)].")
    }

    private static func addDecision(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let title = try ProjectAgentTools.text(args, "title", required: true)
        let body = ProjectAgentTools.decisionBody(context: try ProjectAgentTools.text(args, "context"),
                                                  alternatives: try ProjectAgentTools.list(args, "alternatives"),
                                                  decision: try ProjectAgentTools.text(args, "decision", required: true),
                                                  reason: try ProjectAgentTools.text(args, "reason", required: true),
                                                  consequences: try ProjectAgentTools.text(args, "consequences"))
        let status = try ProjectAgentTools.choice(args, "status", in: ["proposed", "accepted"], default: "proposed")
        guard let object = store.create(.decision, in: feature.slug, title: title,
                                        fields: [("status", .string(status)), ("sources", .list([])), ("produces", .list([]))],
                                        body: body, provenance: provenance("")) else {
            return .error(store.lastError ?? "The decision could not be written.")
        }
        return .init(text: "Added \(object.id) \"\(title)\" to \(feature.slug) [\(status)].")
    }

    private static func addQuestion(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let text = try ProjectAgentTools.text(args, "question", required: true)
        let title = String(text.prefix(140))
        if feature.list(.question).contains(where: { $0.title.lowercased() == title.lowercased() }) {
            throw ProjectAgentTools.Invalid(message: "\(feature.slug) already has this question.")
        }
        let type = try ProjectAgentTools.choice(args, "q_type", in: FeatureVocabulary.questionTypes, default: "clarification")
        let options = (args["options"] as? [[String: Any]] ?? []).prefix(8).compactMap { option -> (label: String, text: String)? in
            let label = (option["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let text = (option["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty || text.isEmpty ? nil : (label, text)
        }
        let recommended = try ProjectAgentTools.text(args, "recommended")
        let fields: [(String, YAMLValue)] = [
            ("q_type", .string(type)), ("priority", .string(args["blocking"] as? Bool == true ? "blocking" : "normal")),
            ("origin", .string("agent")), ("dimension", .string("")), ("blocking", .list([])),
            ("options", .list(options.map { .map([("label", .string($0.label)), ("text", .string($0.text)), ("pros", .list([])), ("cons", .list([]))]) })),
        ] + (recommended.isEmpty ? [] : [("recommended", YAMLValue.string(recommended)), ("recommended_why", YAMLValue.string(""))])
        guard let object = store.create(.question, in: feature.slug, title: title, fields: fields,
                                        body: ProjectAgentTools.questionBody(question: text, why: try ProjectAgentTools.text(args, "why"),
                                                                             options: options, recommended: recommended),
                                        provenance: provenance("")) else {
            return .error(store.lastError ?? "The question could not be written.")
        }
        return .init(text: "Added \(object.id) to \(feature.slug) (open). The user answers it in MarkView's Explore.")
    }

    private static func createBug(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        guard let folder = store.bugsFolder else { return .error("This window has no project folder open.") }
        let title = try ProjectAgentTools.text(args, "title", required: true)
        guard title.count <= 200 else { throw ProjectAgentTools.Invalid(message: "`title` is too long (200 characters at most).") }
        let summary = try ProjectAgentTools.text(args, "summary", required: true)
        let severity = try ProjectAgentTools.choice(args, "severity", in: FeatureVocabulary.severities.filter { $0 != "blocker" } + ["critical"], default: "medium")
        let body = ProjectAgentTools.bugBody(title: title, summary: summary, steps: try ProjectAgentTools.list(args, "steps"),
                                             expected: try ProjectAgentTools.text(args, "expected"), actual: try ProjectAgentTools.text(args, "actual"),
                                             environment: try ProjectAgentTools.text(args, "environment"))
        let id = FeatureAssistant.nextNumbered("BUG", in: folder)
        let file = folder.appendingPathComponent("\(id)-\(featureSlug(title).prefix(50)).md")
        var front = FrontMatter()
        front.set("type", "bug")
        front.set("id", id)
        front.set("title", title)
        front.set("status", "open")
        front.set("severity", severity)
        front.set("reporter", store.defaultOwner)
        front.set("created", FeatureStore.today)
        front.set("provenance", provenance(""))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(front.join(body: body).utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            return .error("Could not write the bug report: \(error.localizedDescription)")
        }
        store.reloadSync()
        return .init(text: "Created \(id) \"\(title)\" [\(severity)] at docs/bugs/\(file.lastPathComponent).")
    }

    private static func setStatus(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let status = try ProjectAgentTools.text(args, "status", required: true).lowercased()
        let id = try ProjectAgentTools.text(args, "id")
        if id.isEmpty {
            guard ProjectAgentTools.agentFeatureStatuses.contains(status) else {
                throw ProjectAgentTools.Invalid(message: "A feature's status can be set to: \(ProjectAgentTools.agentFeatureStatuses.joined(separator: ", ")). The implementation stages are recorded by MarkView.")
            }
            store.updateFeature(feature.slug) { front, _ in front.set("status", status) }
            return .init(text: "\(feature.slug) is now \(status).")
        }
        guard feature.object(id) != nil else { throw ProjectAgentTools.Invalid(message: "\(feature.slug) has no object \(id).") }
        guard let allowed = ProjectAgentTools.statuses(forObjectID: id), allowed.contains(status) else {
            throw ProjectAgentTools.Invalid(message: "\(id) can be set to: \((ProjectAgentTools.statuses(forObjectID: id) ?? []).joined(separator: ", ")).")
        }
        store.setStatus(id, in: feature.slug, to: status)
        return .init(text: "\(id) is now \(status).")
    }
}
