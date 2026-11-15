import Foundation

/// The app side of `ProjectAgentTools`: performs one tool call against the project of one window
/// (its `FeatureStore`). Reads show the files as the app understands them; writes go through the
/// store, so ids, links and front matter are the ones the app itself would write. Nothing outside the
/// window's project is ever named by a tool: features are chosen by slug among the project's own.
@MainActor
enum ProjectToolRunner {
    static func reportCockpitProgress(_ args: [String: Any], store: FeatureStore) async -> BrowserAgentTools.Reply {
        guard let root = store.root else { return .error("This window has no project folder open.") }
        guard let raw = args["ticket"] as? String, let ticket = UUID(uuidString: raw), let pass = args["passNumber"] as? Int,
              let coverage = args["scenarioCoverage"] as? [String] ?? (args["scenarioCoverage"] == nil ? [] : nil),
              let bugs = args["bugs"] as? [String] ?? (args["bugs"] == nil ? [] : nil),
              let fixes = args["fixes"] as? [String] ?? (args["fixes"] == nil ? [] : nil),
              let blockers = args["blockers"] as? [String] ?? (args["blockers"] == nil ? [] : nil),
              let rawCriteria = args["criteriaResults"] as? [[String: Any]] ?? (args["criteriaResults"] == nil ? [] : nil) else {
            return .error("A valid ticket, pass number and string lists are required.")
        }
        var criteria: [CockpitCriterionResult] = []
        for item in rawCriteria {
            guard let criterion = item["criterion"] as? String, let met = item["met"] as? Bool, let evidence = item["evidence"] as? String else {
                return .error("Each criterion needs text, a result and evidence.")
            }
            criteria.append(CockpitCriterionResult(criterion: criterion, met: met, evidence: evidence))
        }
        let progress = CockpitProgress(passNumber: pass, activity: args["activity"] as? String ?? "", scenarioCoverage: coverage,
                                       bugs: bugs, fixes: fixes, latestChange: args["latestChange"] as? String ?? "",
                                       blockers: blockers, buildLogPath: args["buildLogPath"] as? String, criteriaResults: criteria)
        guard await CockpitAgentRegistry.report(root: root, token: ticket, progress: progress) else {
            return .error("The ticket or progress is invalid, expired, belongs to another project, or could not be saved.")
        }
        return .init(text: "Cockpit progress saved.")
    }

    /// A step agent's question for the supervisor. The reply is the answer, or the instruction to decide alone.
    static func askCockpitSupervisor(_ args: [String: Any], store: FeatureStore) async -> BrowserAgentTools.Reply {
        guard let root = store.root else { return .error("This window has no project folder open.") }
        guard let raw = args["ticket"] as? String, let ticket = UUID(uuidString: raw),
              let text = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .error("A valid ticket and a question are required.")
        }
        let question = CockpitSupervisor.Question(
            text: CockpitSupervisor.clip(text, to: 3_000),
            options: Array(((args["options"] as? [String]) ?? []).prefix(10)),
            proposed: ((args["proposed"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard let reply = await CockpitAgentRegistry.ask(root: root, token: ticket, question: question) else {
            return .error("The ticket is invalid, expired, or belongs to another project.")
        }
        return .init(text: reply)
    }

    static func run(_ tool: String, _ args: [String: Any], store: FeatureStore) -> BrowserAgentTools.Reply {
        guard let root = store.root else { return .error("This window has no project folder open.") }
        // The files may have changed since the app last looked (an agent, git, the user's editor).
        if tool != "markview_cockpit_report_progress" && tool != "markview_cockpit_complete_step" { store.reloadSync() }
        do {
            switch tool {
            case "markview_cockpit_complete_step":
                guard let raw = args["ticket"] as? String, let ticket = UUID(uuidString: raw),
                      let passed = args["passed"] as? Bool, let detail = args["detail"] as? String else {
                    return .error("A valid ticket, result and detail are required.")
                }
                let result = CockpitHostResult(passed: passed, detail: detail, build: args["build"] as? String ?? "")
                guard CockpitAgentRegistry.complete(root: root, token: ticket, result: result) else {
                    return .error("The ticket is invalid, expired, belongs to another project, or the result is too long.")
                }
                return .init(text: "The Cockpit step result was recorded.")
            case "markview_guide": return .init(text: ProjectAgentTools.guide(args["topic"] as? String, workflow: store.lifecycle.workflow))
            case "markview_project": return .init(text: project(store, root))
            case "markview_get_workflow": return getWorkflow(store)
            case "markview_propose_workflow": return try proposeWorkflow(store, args)
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
            case "markview_set_status": return try setObjectStatus(store, args)
            case "markview_update_feature": return try updateFeature(store, args)
            case "markview_update_object": return try updateObject(store, args)
            case "markview_answer_question": return try answerQuestion(store, args)
            case "markview_add_source": return try addSource(store, args)
            case "markview_add_discussion_note": return try addDiscussionNote(store, args)
            case "markview_update_bug": return try updateBug(store, args)
            case "markview_answer_bug_question": return try answerBugQuestion(store, args)
            case "markview_link_issue": return try linkIssue(store, args)
            case "markview_open_questions": return try openQuestions(store, args)
            default: return .error("Unknown tool \(tool).")
            }
        } catch let invalid as ProjectAgentTools.Invalid {
            return .error(invalid.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// The workflow of the project, as the file and in words (feature assistants-confirm-delivery-with-evidence-and-propose-workflow, REQ-002).
    private static func getWorkflow(_ store: FeatureStore) -> BrowserAgentTools.Reply {
        let load = store.lifecycle.workflowLoad
        guard load.isEditable else {
            return .error((load.problem ?? "The workflow file of this project cannot be used.") + " It has to be repaired by the person before it can be read or changed.")
        }
        let workflow = store.lifecycle.workflow
        var parts = [clip(WorkflowDescription.describe(workflow)),
                     "The file (.dde/workflow/workflow.json), revision \(workflow.revision):\n" + ProjectWorkflowStore.text(of: workflow),
                     "To change it, learn the format from markview_guide topic workflow-format, then send the whole changed workflow to markview_propose_workflow."]
        if let waiting = store.lifecycle.workflowProposal {
            parts.insert("A proposal by \(waiting.proposedBy) is already waiting for the person: \u{201C}\(waiting.summary)\u{201D}. A new proposal replaces it.", at: 0)
        }
        return .init(text: parts.joined(separator: "\n\n"))
    }

    /// An assistant proposes a changed workflow: checked, held for the person, never saved (REQ-003, DEC-001).
    private static func proposeWorkflow(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let summary = try ProjectAgentTools.text(args, "summary", required: true)
        let tool = try ProjectAgentTools.text(args, "tool")
        switch store.lifecycle.proposeWorkflow(args["workflow"], summary: summary, by: tool.isEmpty ? "An assistant" : tool) {
        case .failure(let refusal):
            return .error("The proposal was not accepted; nothing was changed.\n" + refusal.problems.map { "- " + $0 }.joined(separator: "\n"))
        case .success(let proposal):
            let impact = store.lifecycle.workflowImpact(of: proposal.workflow)
            return .init(text: clip(WorkflowProposalChecker.reply(proposal, needsReplacement: WorkflowProposalChecker.replacementLines(impact))))
        }
    }

    static let outputLimit = 40_000

    static func clip(_ text: String) -> String {
        text.count <= outputLimit ? text : String(text.prefix(outputLimit)) + "\n… (cut: \(text.count - outputLimit) more characters)"
    }

    // MARK: - Reading

    private static func project(_ store: FeatureStore, _ root: URL) -> String {
        let statuses = Dictionary(grouping: store.features, by: \.status).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        return """
        Project folder: \(root.path)
        Features: \(store.features.count)\(statuses.isEmpty ? "" : " (\(statuses))")
        Bugs: \(store.bugs.count) (\(store.bugs.filter { !store.lifecycle.workflow.isFinished(.bug, IssueStatus.normalize($0.status)) }.count) not closed)
        Prototypes: \(PrototypeFiles.existingSlugs(root: root).count)
        Discussions: \(((try? FileManager.default.contentsOfDirectory(atPath: DiscussionStore.base(root: root).path)) ?? []).filter { !$0.hasPrefix(".") }.count) (markview_discussions)
        Deployments: markview_deployments
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

    static func featureNamed(_ store: FeatureStore, _ args: [String: Any]) throws -> Feature {
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
        switch try ProjectAgentTools.text(args, "section") {
        case "plan":
            let plan = feature.planFront.entries.isEmpty && feature.planBody.isEmpty ? "No implementation plan yet." : feature.planFront.join(body: feature.planBody)
            return .init(text: clip(plan))
        case "discussion":
            let log = store.discussion(feature.slug, limit: outputLimit)
            return .init(text: log.isEmpty ? "No discussion log yet." : clip(log))
        case "lifecycle":
            return .init(text: clip(CycleTimeBuilder.describe(store, kind: .feature, issue: feature.slug)))
        case "readiness":
            return .init(text: readinessReport(feature))
        default: break
        }
        var out = "\(feature.slug) — \(feature.title) [\(feature.status)] readiness \(feature.readiness)%\n"
        let owner = feature.front.string("owner"), created = feature.front.string("created"), updated = feature.front.string("updated")
        out += "Owner: \(owner.isEmpty ? "-" : owner) · created \(created.isEmpty ? "-" : created) · updated \(updated.isEmpty ? "-" : updated)\n"
        if !feature.issueNumbers.isEmpty { out += "GitHub issues: " + feature.issueNumbers.map { "#\($0)" }.joined(separator: " ") + (feature.epic.map { " (epic #\($0))" } ?? "") + "\n" }
        if !feature.planIssues.isEmpty { out += "Plan: \(feature.planIssues.count) issues (section plan)\n" }
        if let left = feature.questionsLeft { out += "Questions the AI still expects: \(left)\n" }
        out += readinessReport(feature) + "\n"
        let understanding = feature.understanding.map { "\($0.dimension): \($0.state)" }.joined(separator: ", ")
        if !understanding.isEmpty { out += "Understanding: \(understanding)\n" }
        out += "\n" + feature.overviewBody.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        for kind in FeatureObjectKind.allCases where !feature.list(kind).isEmpty {
            out += "\n## \(kind.title)\n"
            for object in feature.list(kind) {
                let links = object.links.map { "\($0.relation) \($0.target)" }.joined(separator: "; ")
                out += "- \(object.id) [\(object.status)] \(object.title)" + (links.isEmpty ? "" : " (\(links))") + "\n"
                if args["full"] as? Bool == true { out += object.body.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n" }
            }
        }
        return .init(text: clip(out))
    }

    private static func listBugs(_ store: FeatureStore, status: String) -> String {
        let bugs = store.bugs.filter { status.isEmpty || $0.status == status }
        guard !bugs.isEmpty else { return "No bug reports" + (status.isEmpty ? "." : " with status \(status).") }
        return clip(bugs.map { bug in
            var line = "\(bug.key) — \(bug.title) [\(bug.status), \(bug.severity)]"
            if !bug.feature.isEmpty { line += " · feature \(bug.feature)" }
            if !bug.issueNumbers.isEmpty { line += " · issues " + bug.issueNumbers.map { "#\($0)" }.joined(separator: " ") }
            if !bug.duplicateOf.isEmpty { line += " · duplicate of \(bug.duplicateOf)" }
            if bug.readyToFix { line += " · ready to fix" }
            if !bug.openQuestions.isEmpty { line += " · \(bug.openQuestions.count) open question(s)" }
            return line
        }.joined(separator: "\n"))
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
        let rows = slugs.compactMap { slug -> String? in
            guard let m = PrototypeFiles.loadManifest(PrototypeFiles.folder(root: root, slug: slug)) else { return nil }
            let approved = m.approved ? " (approved)" : ""
            let historical = m.mode == .code ? " · historical reconstruction of existing code (the current interface opens in UI Studio)" : ""
            var row = "\(slug) — \(m.title) v\(m.version)\(approved)\(historical) · \(m.screens.count) screens: \(m.screens.joined(separator: ", "))"
            row += " · \(PrototypeReference.string(slug: slug))"
            return row
        }
        return rows.joined(separator: "\n")
    }

    /// "Changes since the last sync" of a prototype made from code (REQ-013): the prototype files that differ from the baseline, the
    /// source components they reproduce, the review requests since then, and whether the components named in the result changed in the
    /// code. Reading changes nothing on disk.
    private static func changesSection(root: URL, folder: URL, site: URL, manifest m: PrototypeFiles.Manifest) -> String {
        var status = PrototypeBaseline.status(record: nil, scope: [:], site: [:])
        if let record = PrototypeBaseline.load(folder: folder, version: m.version) {
            let inventory = PrototypeFiles.inventory(root: root, sources: m.sources)
            let paths = Array(Set(record.scope.keys).union(inventory.entries.map(\.path)))
            status = PrototypeBaseline.status(record: record, scope: PrototypeBaseline.fingerprints(root: root, paths: paths),
                                              site: PrototypeBaseline.siteFingerprints(site: site))
        }
        let changes = PrototypeHandoff.changes(status: status, history: m.history, markers: { path in
            guard let text = try? String(contentsOf: site.appendingPathComponent(path), encoding: .utf8) else { return [] }
            return PrototypeFiles.componentMarkers(in: text)
        })
        return PrototypeHandoff.section(changes, componentPaths: m.components.map(\.path))
    }

    private static func getPrototype(_ root: URL, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        // `prototype` is a slug or a reference in any form PrototypeReference reads; the slug it names must be listed.
        let given = try ProjectAgentTools.text(args, "prototype", required: true)
        guard let reference = PrototypeReference.components(given), ProjectAgentTools.isPlainName(reference.slug),
              PrototypeFiles.existingSlugs(root: root).contains(reference.slug) else {
            var message = "No prototype \"\(given)\". "
            if PrototypeReference.parse(given) == nil {
                message += "Name a prototype by its slug or its reference \(PrototypeReference.string(slug: "<slug>")). "
            }
            throw ProjectAgentTools.Invalid(message: message + listPrototypes(root))
        }
        let slug = reference.slug
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
        let approval = m.approved ? " (approved)" : " (not approved yet)"
        var out = "\(slug) — \(m.title) v\(m.version)\(approval)\n"
        out += "Reference: \(PrototypeReference.string(slug: slug)) (resolves to the latest saved version in this project checkout)\n"
        if let asked = reference.version {
            out += "Note: references always resolve to the latest version (v\(m.version)); the versions/v\(asked) folder in the reference was ignored.\n"
        }
        out += "Mode: \(m.mode.rawValue)"
            + (m.mode == .code ? " (historical reconstruction saved before UI Studio; it is not the current application)" : "") + "\n"
        if !m.brief.isEmpty { out += "\nBrief: \(m.brief)\n" }
        // The sources are requirement documents, or in code mode the implementation that was reconstructed.
        let sourcesLabel = m.mode == .code ? "Reconstruction sources" : "Requirement sources"
        out += "\(sourcesLabel): \(m.sources.isEmpty ? "the project folder" : m.sources.joined(separator: ", "))\n"
        out += "\nScreens: \(m.screens.joined(separator: ", "))\n"
        if !m.assumptions.isEmpty {
            let assumptions = m.assumptions.map { "- \($0)" }
            out += "\nAssumptions:\n\(assumptions.joined(separator: "\n"))\n"
        }
        if !m.gaps.isEmpty {
            let gaps = m.gaps.map { "- \($0)" }
            out += "\nKnown gaps:\n\(gaps.joined(separator: "\n"))\n"
        }
        if !m.components.isEmpty {
            // Source component → the screens that reproduce it, and its isolated page (REQ-007). Built with
            // `+=` so the Swift 6.0 compiler (CI) type-checks it in reasonable time.
            var lines: [String] = []
            for component in m.components {
                var line = "- \(component.path) → "
                line += component.screens.isEmpty ? "no screen named" : component.screens.joined(separator: ", ")
                if let page = component.page { line += "; isolated page \(page)" }
                lines.append(line)
            }
            out += "\nComponents (source files the prototype reproduces; elements carry \(PrototypeFiles.componentMarker)=\"<path>\"):\n"
            out += lines.joined(separator: "\n") + "\n"
        }
        if m.mode == .code, m.version > 0 {
            // Changes since the sync baseline (REQ-013): read only, computed from the files as they are now.
            out += "\n" + changesSection(root: root, folder: folder, site: site, manifest: m) + "\n"
        }
        if !m.history.isEmpty {
            // Split up: the Swift 6.0 compiler (CI) cannot type-check this as one concatenation in reasonable time.
            let entries = m.history.map { entry -> String in
                let instruction = entry.instruction.isEmpty ? "(build)" : entry.instruction
                return "- v\(entry.version): \(instruction) → \(entry.summary)"
            }
            out += "\nReview history:\n\(entries.joined(separator: "\n"))\n"
        }
        let files = PrototypeFiles.read(site: site).map { "- \($0.path) (\($0.content.utf8.count) bytes)" }
        out += "\nFiles (read one with `file`):\n\(files.joined(separator: "\n"))\n"
        if let spec = try? String(contentsOf: folder.appendingPathComponent("SPEC.md"), encoding: .utf8) {
            out += "\n=== SPEC.md ===\n\(spec)"
        } else {
            out += "\nNo SPEC.md yet: the prototype was not exported. Work from the screens, files and review history."
        }
        return .init(text: clip(out))
    }

    // MARK: - Writing

    static func provenance(_ source: String) -> String {
        "Created by an AI agent through MarkView" + (source.isEmpty ? "" : " from \(source)")
    }

    private static func createFeature(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let title = try ProjectAgentTools.text(args, "title", required: true)
        guard title.count <= 200 else { throw ProjectAgentTools.Invalid(message: "`title` is too long (200 characters at most).") }
        let idea = try ProjectAgentTools.text(args, "idea")
        let requested = try ProjectAgentTools.choice(args, "status", in: ProjectAgentTools.agentFeatureStatuses, default: idea.isEmpty ? "idea" : "exploring")
        // A project on a board has no idea or exploring stage: the feature starts where the board lets work wait (REQ-004).
        let status = store.entryFeatureStatus(preferring: requested)
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
        let related = try issueReference(store, args, "related")
        guard let slug = store.createFeature(title: title, idea: idea) else {
            return .error(store.lastError ?? "The feature could not be created.")
        }
        store.updateFeature(slug) { front, _ in
            front.set("provenance", provenance(source))
            if let related, !related.isEmpty { front.set("related", related) }
        }
        if let created = store.feature(slug), created.status != status {
            store.moveFeature(slug, to: status, by: .ai("AI agent"), surface: false)
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
        guard store.bugsFolder != nil else { return .error("This window has no project folder open.") }
        let title = try ProjectAgentTools.text(args, "title", required: true)
        guard title.count <= 200 else { throw ProjectAgentTools.Invalid(message: "`title` is too long (200 characters at most).") }
        let summary = try ProjectAgentTools.text(args, "summary", required: true)
        let severity = try ProjectAgentTools.choice(args, "severity", in: FeatureVocabulary.severities.filter { $0 != "blocker" } + ["critical"], default: "medium")
        let body = ProjectAgentTools.bugBody(title: title, summary: summary, steps: try ProjectAgentTools.list(args, "steps"),
                                             expected: try ProjectAgentTools.text(args, "expected"), actual: try ProjectAgentTools.text(args, "actual"),
                                             environment: try ProjectAgentTools.text(args, "environment"))
        guard let initial = store.bugStatus(role: .notStarted) else {
            return .error("This project's bug workflow has no status with the role \"Not started\", so a new bug has no status to start in.")
        }
        var draft = BugReportDraft(title: title, body: body, status: initial, severity: severity, reporter: store.defaultOwner,
                                   provenance: provenance(""))
        for key in ["regression_of", "related"] {
            if let target = try issueReference(store, args, key), !target.isEmpty { draft.fields.append((key: key, value: target)) }
        }
        let written: (id: String, url: URL)
        do {
            written = try store.createBug(draft)
        } catch {
            return .error("Could not write the bug report: \(error.localizedDescription)")
        }
        return .init(text: "Created \(written.id) \"\(title)\" [\(severity)] at docs/bugs/\(written.url.lastPathComponent).")
    }

    /// The status of one object of a feature. A feature's own status (no `id`) is the lifecycle's: LifecycleToolRunner.
    private static func setObjectStatus(_ store: FeatureStore, _ args: [String: Any]) throws -> BrowserAgentTools.Reply {
        let feature = try featureNamed(store, args)
        let status = try ProjectAgentTools.text(args, "status", required: true).lowercased()
        let id = try ProjectAgentTools.text(args, "id", required: true)
        guard feature.object(id) != nil else { throw ProjectAgentTools.Invalid(message: "\(feature.slug) has no object \(id).") }
        guard let allowed = ProjectAgentTools.statuses(forObjectID: id), allowed.contains(status) else {
            throw ProjectAgentTools.Invalid(message: "\(id) can be set to: \((ProjectAgentTools.statuses(forObjectID: id) ?? []).joined(separator: ", ")).")
        }
        if ProjectAgentTools.personsStatuses.contains(status), args["by_user"] as? Bool != true {
            throw ProjectAgentTools.Invalid(message: "\(status) records the person's decision. Ask them, and call again with by_user: true only when they said so in the conversation.")
        }
        if status == "rejected", id.hasPrefix("DEC-") {
            store.rejectDecision(id, in: feature.slug)
        } else {
            store.setStatus(id, in: feature.slug, to: status)
        }
        return .init(text: "\(id) is now \(status).")
    }
}
