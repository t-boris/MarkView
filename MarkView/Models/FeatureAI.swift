import Foundation

/// A result shown in the Feature tab: an answer to a contextual action or a chat turn, with
/// what can be done with it.
struct FeatureResult: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var pending: Bool
    var feature: String?
    /// A Mermaid diagram that can be saved into the feature.
    var diagram: String?
    /// The discussion looks like it reached a decision (spec §16).
    var decision: DecisionCandidate?
}

struct DecisionCandidate: Hashable {
    var title: String
    var context: String
    var alternatives: [String]
    var decision: String
    var reason: String
}

/// Contextual actions on selected text (spec §8).
enum FeatureAction: String, CaseIterable {
    case ask, challenge, expand, research, edgeCases, contradictions, related, explain, diagram
    case requirement, decision, question

    var title: String {
        switch self {
        case .ask: return "Ask AI"
        case .challenge: return "Challenge"
        case .expand: return "Expand"
        case .research: return "Research"
        case .edgeCases: return "Find Edge Cases"
        case .contradictions: return "Find Contradictions"
        case .related: return "Find Related Documentation"
        case .explain: return "Explain"
        case .diagram: return "Generate Diagram"
        case .requirement: return "Turn Into Requirement"
        case .decision: return "Create Decision"
        case .question: return "Create Question"
        }
    }

    var instruction: String {
        switch self {
        case .ask: return "Answer the user's question about the selected text."
        case .challenge: return "Challenge the selected text: question its assumptions, point out weak reasoning and risks, and say what evidence would settle each point."
        case .expand: return "Expand the selected text into fuller specification prose: cover what it leaves implicit (actors, conditions, data, errors). Keep its intent."
        case .research: return "Research the selected topic."
        case .edgeCases: return "List the edge cases the selected text does not cover, most impactful first, each with the expected behaviour to specify."
        case .contradictions: return "Find contradictions between the selected text and the feature's requirements, decisions and the project's documentation. Quote both sides."
        case .related: return "Point out which project documents and feature objects relate to the selected text and how."
        case .explain: return "Explain the selected text clearly for someone new to the project."
        case .diagram: return "Draw the selected content as a Mermaid diagram (flowchart, sequence or ER — whichever fits). Answer with a short note and one ```mermaid block."
        case .requirement, .decision, .question: return ""
        }
    }
}

/// The AI side of feature workspaces: guided discovery, review, resolution, research,
/// contextual actions and implementation planning. Every answer is structured (JSON schema),
/// and what is kept is written to the feature's Markdown files by `FeatureStore`.
@MainActor
final class FeatureAssistant: ObservableObject {
    unowned let store: FeatureStore

    /// Running jobs, e.g. "explore:<slug>", "answer:Q-003", "review:<slug>".
    @Published private(set) var running: Set<String> = []
    @Published var results: [FeatureResult] = []
    @Published var error: String?

    /// Voice notes for sources; owned here so a recording survives switching panels.
    let voice = WhisperClient()

    /// Wired by WorkspaceManager.
    var database: () -> SemanticDatabase? = { nil }
    var gitHubClient: () -> GitHubClient? = { nil }

    init(store: FeatureStore) {
        self.store = store
    }

    func isRunning(_ key: String) -> Bool { running.contains(key) || preparing.contains(key) }

    /// Steps being prepared (context, files) before their AI call — shown as running at once.
    @Published private(set) var preparing: Set<String> = []

    // MARK: - Running a request

    /// The facilitator's instructions. Conversation (questions, options, explanations, replies)
    /// is in the user's AI language; the specification's own text stays English (user decision).
    private static var system: String {
        let language = ActionOutputLanguage.current
        let conversation = language == ActionOutputLanguage.documentLanguage
            ? "the language the user writes in (the project's documents' language when unclear)" : language
        return """
        You are the facilitator of a documentation-driven workspace. The team specifies features in \
        Markdown before building them: ideas become questions, decisions and requirements. Your job is \
        convergence toward an implementation-ready specification — find what is missing, ask the most \
        useful question, propose alternatives, challenge assumptions, spot contradictions and edge cases. \
        Never present an inference as a fact: keep project facts, external facts, AI inferences, user \
        decisions and open assumptions apart. Be concise. You may read the project's files (read-only) \
        to check what already exists.

        Language: write what you say to the user — questions, their "why", options with pros and cons, \
        understanding notes, suggestions, replies, explanations, resolution questions and options — in \
        \(conversation). Write \
        the specification itself — requirement titles, statements and acceptance criteria, decision \
        texts, finding titles and details, research claims and summaries, source summaries and facts — \
        in English. Keep JSON enum values exactly as specified.
        """
    }

    private func run(_ key: String, prompt: String, schema: [String: Any]?, web: Bool = false,
                     timeout: TimeInterval = 400, onDelta: (@Sendable (String) -> Void)? = nil) async -> CLICompletion.Result? {
        guard !running.contains(key) else {
            error = "That is already running — wait for it to finish."
            return nil
        }
        running.insert(key)
        defer { running.remove(key) }
        // The answer belongs to this folder: dropped if another folder was opened meanwhile.
        let folder = store.root
        var request = CLICompletion.Request(prompt: prompt, systemPrompt: Self.system, jsonSchema: schema,
                                            readableFolder: store.root)
        request.allowWeb = web
        request.effort = "low"
        request.timeout = timeout
        do {
            let result = try await CLICompletion.run(request, onDelta: onDelta)
            guard store.root == folder else { return nil }
            result.record(in: database())
            error = nil
            return result
        } catch is CancellationError {
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// A structured answer (the JSON object), or nil when it failed (see `error`).
    func structured(_ key: String, prompt: String, schema: [String: Any], web: Bool = false,
                    timeout: TimeInterval = 400) async -> [String: Any]? {
        await run(key, prompt: prompt, schema: schema, web: web, timeout: timeout)?.structured as? [String: Any]
    }

    // MARK: - Context (spec §31)

    /// The feature as the AI needs it for an operation on `focus`: overview, understanding,
    /// the focused objects in full with their linked objects, a digest of the rest, accepted
    /// facts, and related project documentation.
    func context(_ feature: Feature, focus: [String] = [], query: String = "", budget: Int = 45_000) -> String {
        var out = "# Feature: \(feature.title) (\(feature.slug)) — status \(feature.status)\n\n"
        out += feature.overviewBody.prefix(6_000) + "\n\n"
        // A feature's own documents (hand-written specs: requirements.md, design.md, …).
        var documentBudget = 30_000
        for document in feature.documents where documentBudget > 0 {
            guard let text = try? String(contentsOf: document, encoding: .utf8) else { continue }
            let part = String(text.prefix(min(12_000, documentBudget)))
            documentBudget -= part.count
            out += "## Document \(document.lastPathComponent)\n\n\(part)\n\n"
        }
        out += "## Understanding\n" + feature.understanding.map { "- \($0.dimension): \($0.state)" }.joined(separator: "\n") + "\n\n"
        // Focus objects and one hop around them, in full.
        var full: [String] = []
        for id in focus {
            full.append(id)
            full += feature.outgoing(id).map(\.to.id)
            full += feature.incoming(id).map(\.from.id)
        }
        var seen = Set<String>()
        let fullObjects = full.compactMap { id -> FeatureObject? in
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            return feature.object(id)
        }
        if !fullObjects.isEmpty {
            out += "## In focus\n\n"
            for object in fullObjects { out += "### \(object.id)\n" + object.text().prefix(5_000) + "\n\n" }
        }
        // Digest of everything else.
        for kind in [FeatureObjectKind.requirement, .decision, .question, .finding, .research] {
            let rest = feature.list(kind).filter { !seen.contains($0.id) }
            guard !rest.isEmpty else { continue }
            out += "## \(kind.title)\n"
            for object in rest {
                var line = "- \(object.id) [\(object.status)] \(object.title)"
                if kind == .decision, !object.section("Decision").isEmpty { line += " — " + object.section("Decision").prefix(200) }
                if kind == .requirement { line += " — " + object.section("Statement").prefix(200) }
                out += line + "\n"
            }
            out += "\n"
        }
        // Accepted facts from sources (spec §10).
        let facts = feature.list(.source).flatMap { source in
            (source.front["facts"]?.list ?? []).filter { $0["status"]?.string == "accepted" }
                .compactMap { $0["text"]?.string.map { "- \($0) (\(source.id))" } }
        }
        if !facts.isEmpty { out += "## Accepted facts\n" + facts.joined(separator: "\n") + "\n\n" }
        // Related project documentation (search index).
        let related = relatedDocuments(query.isEmpty ? feature.title : query)
        if !related.isEmpty { out += "## Related project documentation\n" + related + "\n" }
        return String(out.prefix(budget))
    }

    private func relatedDocuments(_ query: String, limit: Int = 5) -> String {
        guard let db = database() else { return "" }
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 3 }.prefix(6).map(String.init)
        guard !terms.isEmpty else { return "" }
        let results = db.search(query: terms.joined(separator: " OR "))
            .filter { !$0.documentId.hasPrefix(FeatureStore.folderName + "/") }
            .prefix(limit)
        return results.map { "- \($0.documentId): " + $0.snippet.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: "") }
            .joined(separator: "\n")
    }

    // MARK: - Schemas

    private static let optionSchema: [String: Any] = [
        "type": "object",
        "properties": ["label": ["type": "string"], "text": ["type": "string"],
                       "pros": ["type": "array", "items": ["type": "string"]],
                       "cons": ["type": "array", "items": ["type": "string"]]],
        "required": ["label", "text", "pros", "cons"],
    ]

    /// Every dimension with its state and a short note: what is known, or what is still missing.
    private static let understandingSchema: [String: Any] = [
        "type": "array",
        "items": ["type": "object",
                  "properties": ["dimension": ["type": "string", "enum": FeatureVocabulary.understanding],
                                 "state": ["type": "string", "enum": FeatureVocabulary.understandingStates],
                                 "note": ["type": "string"]],
                  "required": ["dimension", "state", "note"]],
    ]

    private static let requirementSchema: [String: Any] = [
        "type": "object",
        "properties": ["title": ["type": "string"], "statement": ["type": "string"],
                       "req_type": ["type": "string", "enum": FeatureVocabulary.requirementTypes],
                       "acceptance_criteria": ["type": "array", "items": ["type": "string"]]],
        "required": ["title", "statement", "req_type", "acceptance_criteria"],
    ]

    private static let decisionSchema: [String: Any] = [
        "type": "object",
        "properties": ["title": ["type": "string"], "context": ["type": "string"],
                       "alternatives": ["type": "array", "items": ["type": "string"]],
                       "decision": ["type": "string"], "reason": ["type": "string"], "consequences": ["type": "string"]],
        "required": ["title", "context", "alternatives", "decision", "reason", "consequences"],
    ]

    private static func object(_ properties: [String: Any], required: [String]? = nil) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required ?? Array(properties.keys)]
    }

    private static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    private static let string: [String: Any] = ["type": "string"]
    private static let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]

    // MARK: - Writing objects from answers

    private func options(_ list: [[String: Any]]) -> YAMLValue {
        .list(list.map { option in
            .map([("label", .string(option["label"] as? String ?? "")), ("text", .string(option["text"] as? String ?? "")),
                  ("pros", .list((option["pros"] as? [String] ?? []).map { .string($0) })),
                  ("cons", .list((option["cons"] as? [String] ?? []).map { .string($0) }))])
        })
    }

    @discardableResult
    private func makeRequirement(_ r: [String: Any], in slug: String, sources: [String], decisions: [String],
                                 provenance: String) -> FeatureObject? {
        let criteria = (r["acceptance_criteria"] as? [String] ?? []).map { "- [ ] \($0)" }.joined(separator: "\n")
        let body = "## Statement\n\n\(r["statement"] as? String ?? "")\n\n## Acceptance Criteria\n\n\(criteria)\n"
        return store.create(.requirement, in: slug, title: r["title"] as? String ?? "Requirement",
                            fields: [("req_type", .string(r["req_type"] as? String ?? "functional")),
                                     ("depends_on", .list([])), ("decisions", .list(decisions.map { .string($0) })),
                                     ("sources", .list(sources.map { .string($0) })), ("issues", .list([]))],
                            body: body, provenance: provenance)
    }

    @discardableResult
    private func makeDecision(_ d: [String: Any], in slug: String, status: String, sources: [String],
                              provenance: String) -> FeatureObject? {
        let alternatives = (d["alternatives"] as? [String] ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let body = """
        ## Context

        \(d["context"] as? String ?? "")

        ## Alternatives

        \(alternatives)

        ## Decision

        \(d["decision"] as? String ?? "")

        ## Reason

        \(d["reason"] as? String ?? "")

        ## Consequences

        \(d["consequences"] as? String ?? "")
        """
        return store.create(.decision, in: slug, title: d["title"] as? String ?? "Decision",
                            fields: [("status", .string(status)), ("sources", .list(sources.map { .string($0) })),
                                     ("produces", .list([]))],
                            body: body, provenance: provenance)
    }

    // MARK: - Explore: guided discovery (spec §6–7)

    /// Update the understanding model and ask the most useful next question (a Q file with
    /// options). Nothing is asked when the feature is well understood.
    func exploreNext(_ slug: String) async {
        preparing.insert("explore:" + slug)
        defer { preparing.remove("explore:" + slug) }
        guard let feature = store.feature(slug) else { return }
        let asked = feature.list(.question).map { "- \($0.id) [\($0.status)] \($0.title)" }.joined(separator: "\n")
        let prompt = context(feature) + """

        ## Questions already asked
        \(asked.isEmpty ? "(none)" : asked)

        Task: \(Self.discoveryInstruction) Add up to 3 short suggestions (things to consider or add).
        """
        let schema = Self.object([
            "understanding": Self.understandingSchema,
            "has_question": ["type": "boolean"],
            "question": Self.questionSchema,
            "questions_left": ["type": "integer"],
            "suggestions": Self.strings,
        ])
        guard let result = await run("explore:" + slug, prompt: prompt, schema: schema),
              let object = result.structured as? [String: Any] else { return }
        applyDiscovery(object, to: slug)
        if feature.status == "idea" { store.updateFeature(slug) { front, _ in front.set("status", "exploring") } }
        let suggestions = object["suggestions"] as? [String] ?? []
        if !suggestions.isEmpty {
            results.insert(FeatureResult(title: "Suggestions", text: suggestions.map { "• " + $0 }.joined(separator: "\n"),
                                         pending: false, feature: slug), at: 0)
        }
    }

    private static let questionSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"], "why": ["type": "string"],
                       "q_type": ["type": "string", "enum": FeatureVocabulary.questionTypes],
                       "blocking": ["type": "boolean"], "options": ["type": "array", "items": optionSchema]],
        "required": ["text", "why", "q_type", "blocking", "options"],
    ]

    private static let discoveryInstruction = """
    Assess how well each understanding dimension is specified (known / partial / unknown / n/a). Then \
    choose the ONE next question with the highest impact on the specification that has not been asked. \
    Offer 2–4 concrete options (label them A, B, C…) with short pros and cons, unless the question is \
    open-ended (then no options). Mark it blocking when requirements cannot be written without it. Set \
    has_question false only when the feature is ready to be specified. questions_left: your honest \
    estimate of how many more questions are needed before a first implementation-ready specification \
    (0 when ready) — ask only what really changes the specification.
    """

    /// States and notes of the understanding dimensions from an answer.
    private func applyUnderstanding(_ object: [String: Any], to slug: String) {
        let items = object["understanding"] as? [[String: Any]] ?? []
        let states = items.reduce(into: [String: String]()) {
            if let d = $1["dimension"] as? String, let s = $1["state"] as? String { $0[d] = s }
        }
        store.setUnderstanding(slug, states)
        let notes = items.compactMap { item -> (String, YAMLValue)? in
            guard let d = item["dimension"] as? String, let n = item["note"] as? String, !n.isEmpty else { return nil }
            return (d, .string(n))
        }
        if !notes.isEmpty {
            store.updateFeature(slug) { front, _ in
                var current = front["understanding_notes"]?.entries ?? []
                for (dimension, note) in notes {
                    if let i = current.firstIndex(where: { $0.key == dimension }) { current[i].value = note }
                    else { current.append((dimension, note)) }
                }
                front["understanding_notes"] = .map(current)
            }
        }
    }

    /// Understanding, the next question and the estimate of questions left, from a discovery answer.
    private func applyDiscovery(_ object: [String: Any], to slug: String) {
        applyUnderstanding(object, to: slug)
        if let left = object["questions_left"] as? Int {
            store.updateFeature(slug) { front, _ in front.set("questions_left", String(max(0, left))) }
        }
        guard object["has_question"] as? Bool == true, let q = object["question"] as? [String: Any] else { return }
        let text = q["text"] as? String ?? ""
        guard !text.isEmpty else { return }
        let optionList = q["options"] as? [[String: Any]] ?? []
        var body = "## Question\n\n\(text)\n\n## Why it matters\n\n\(q["why"] as? String ?? "")\n"
        if !optionList.isEmpty {
            body += "\n## Options\n\n" + optionList.map { "- **\($0["label"] as? String ?? "")**: \($0["text"] as? String ?? "")" }.joined(separator: "\n") + "\n"
        }
        store.create(.question, in: slug, title: String(text.prefix(140)),
                     fields: [("q_type", .string(q["q_type"] as? String ?? "clarification")),
                              ("priority", .string(q["blocking"] as? Bool == true ? "blocking" : "normal")),
                              ("origin", .string("explore")), ("blocking", .list([])),
                              ("options", options(optionList))],
                     body: body, provenance: "Generated by AI (guided discovery)")
    }

    /// The user answered a question (chose an option or wrote an answer): record it, turn it into
    /// a decision and candidate requirements, update the understanding, and ask the next question.
    func answer(_ slug: String, question id: String, answer: String, next: Bool = true) async {
        preparing.insert("answer:" + id)
        defer { preparing.remove("answer:" + id) }
        guard let feature = store.feature(slug), let question = feature.object(id) else { return }
        let prompt = context(feature, focus: [id]) + """

        ## The user answered \(id)
        Question: \(question.title)
        Answer: \(answer)

        Task: turn this answer into specification. If it settles a choice, write the decision (with the \
        alternatives that were considered). Derive the requirements it implies (0–4), each with acceptance \
        criteria. \(next ? "Then, with this answer taken into account: " + Self.discoveryInstruction : "Update the understanding dimensions it changes.")
        """
        var properties: [String: Any] = [
            "has_decision": ["type": "boolean"],
            "decision": Self.decisionSchema,
            "requirements": Self.array(Self.requirementSchema),
            "understanding": Self.understandingSchema,
        ]
        if next {
            // The next question comes in the same answer: one AI call per answer instead of two.
            properties["has_question"] = ["type": "boolean"]
            properties["question"] = Self.questionSchema
            properties["questions_left"] = ["type": "integer"]
        }
        let schema = Self.object(properties)
        guard let result = await run("answer:" + id, prompt: prompt, schema: schema),
              let object = result.structured as? [String: Any] else { return }
        var decisionID: String?
        if object["has_decision"] as? Bool == true, let d = object["decision"] as? [String: Any] {
            decisionID = makeDecision(d, in: slug, status: "accepted", sources: [id],
                                      provenance: "Generated from discussion (\(id))")?.id
        }
        var produced: [String] = []
        for r in object["requirements"] as? [[String: Any]] ?? [] {
            if let req = makeRequirement(r, in: slug, sources: [id] + (decisionID.map { [$0] } ?? []),
                                         decisions: decisionID.map { [$0] } ?? [],
                                         provenance: "Derived from \(decisionID ?? id)") {
                produced.append(req.id)
            }
        }
        if let decisionID { store.update(decisionID, in: slug) { front, _ in front.set("produces", list: produced) } }
        store.update(id, in: slug) { front, body in
            front.set("status", "answered")
            front.set("answer", answer)
            if let decisionID { front.set("resolved_by", decisionID) }
            front.set("produces", list: produced)
            body += "\n## Answer\n\n\(answer)\n"
        }
        store.appendDiscussion(slug, speaker: "Answer to \(id)", text: "\(question.title)\n\n\(answer)")
        if next { applyDiscovery(object, to: slug) } else { applyUnderstanding(object, to: slug) }
    }

    func skip(_ slug: String, question id: String) async {
        store.setStatus(id, in: slug, to: "deferred")
        await exploreNext(slug)
    }

    /// "Suggest another approach": more options for a question.
    func moreOptions(_ slug: String, question id: String) async {
        guard let feature = store.feature(slug), let question = feature.object(id) else { return }
        let existing = (question.front["options"]?.list ?? []).map { "\($0["label"]?.string ?? ""): \($0["text"]?.string ?? "")" }
        let prompt = context(feature, focus: [id]) + """

        Question \(id): \(question.title)
        Options so far:
        \(existing.joined(separator: "\n"))

        Task: propose 1–3 further, genuinely different approaches, labelled after the existing ones.
        """
        let schema = Self.object(["options": Self.array(Self.optionSchema)])
        guard let result = await run("options:" + id, prompt: prompt, schema: schema),
              let list = (result.structured as? [String: Any])?["options"] as? [[String: Any]] else { return }
        store.update(id, in: slug) { front, _ in
            front["options"] = .list((front["options"]?.list ?? []) + options(list).list)
        }
    }

    /// "Show pros/cons": fill in pros and cons of every option.
    func prosAndCons(_ slug: String, question id: String) async {
        guard let feature = store.feature(slug), let question = feature.object(id) else { return }
        let existing = (question.front["options"]?.list ?? []).map { "\($0["label"]?.string ?? ""): \($0["text"]?.string ?? "")" }
        let prompt = context(feature, focus: [id]) + """

        Question \(id): \(question.title)
        Options:
        \(existing.joined(separator: "\n"))

        Task: for every option give 2–4 concrete pros and cons for this feature and project.
        """
        let schema = Self.object(["options": Self.array(Self.optionSchema)])
        guard let result = await run("pros:" + id, prompt: prompt, schema: schema),
              let list = (result.structured as? [String: Any])?["options"] as? [[String: Any]] else { return }
        store.update(id, in: slug) { front, _ in
            var current = front["options"]?.list ?? []
            for option in list {
                guard let label = option["label"] as? String,
                      let index = current.firstIndex(where: { $0["label"]?.string == label }) else { continue }
                var entries = current[index].entries.filter { $0.key != "pros" && $0.key != "cons" }
                entries.append(("pros", .list((option["pros"] as? [String] ?? []).map { .string($0) })))
                entries.append(("cons", .list((option["cons"] as? [String] ?? []).map { .string($0) })))
                current[index] = .map(entries)
            }
            front["options"] = .list(current)
        }
    }

    // MARK: - Research (spec §11)

    /// Research a topic (web, project, code) and keep the claims with their kinds and sources.
    @discardableResult
    func research(_ slug: String, topic: String, for linked: String? = nil) async -> FeatureObject? {
        guard let feature = store.feature(slug) else { return nil }
        let prompt = context(feature, focus: linked.map { [$0] } ?? [], query: topic) + """

        ## Research topic
        \(topic)

        Task: research this for the feature. Search the web when external knowledge helps (standards, \
        APIs, vendor limits, prior art) and read the project's documents and code for what already exists. \
        Report claims, each labelled with its kind — project-fact (seen in this repository), external-fact \
        (from a cited web source), ai-inference, user-decision or open-assumption — and its source (URL or \
        project path; empty for inferences). End with open questions the research raised.
        """
        let claimSchema = Self.object(["text": Self.string,
                                       "kind": ["type": "string", "enum": FeatureVocabulary.claimKinds],
                                       "source": Self.string])
        let schema = Self.object(["title": Self.string, "summary": Self.string,
                                  "claims": Self.array(claimSchema), "open_questions": Self.strings])
        guard let result = await run("research:" + slug, prompt: prompt, schema: schema, web: true, timeout: 900),
              let object = result.structured as? [String: Any] else { return nil }
        let claims = object["claims"] as? [[String: Any]] ?? []
        var body = "## Topic\n\n\(topic)\n\n## Summary\n\n\(object["summary"] as? String ?? "")\n\n## Claims\n\n"
        body += claims.map { c in
            let source = (c["source"] as? String ?? "").isEmpty ? "" : " — \(c["source"] as? String ?? "")"
            return "- `\(c["kind"] as? String ?? "ai-inference")` \(c["text"] as? String ?? "")\(source)"
        }.joined(separator: "\n")
        let openQuestions = object["open_questions"] as? [String] ?? []
        if !openQuestions.isEmpty { body += "\n\n## Open questions\n\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n") }
        let claimValues: [YAMLValue] = claims.map { c in
            .map([("text", .string(c["text"] as? String ?? "")), ("kind", .string(c["kind"] as? String ?? "ai-inference")),
                  ("source", .string(c["source"] as? String ?? ""))])
        }
        let note = store.create(.research, in: slug, title: object["title"] as? String ?? topic,
                                fields: [("topic", .string(topic)), ("related", .list(linked.map { [.string($0)] } ?? [])),
                                         ("claims", .list(claimValues))],
                                body: body, provenance: "Generated by AI (research)")
        if let linked, let note {
            store.update(linked, in: slug) { front, _ in
                front.set("related", list: front.strings("related") + [note.id])
            }
        }
        return note
    }

    // MARK: - Review (spec §12–14)

    /// Review the feature from all perspectives; new findings become F files.
    func review(_ slug: String, focus: String? = nil) async {
        preparing.insert("review:" + slug)
        defer { preparing.remove("review:" + slug) }
        guard let feature = store.feature(slug) else { return }
        let scope = focus.map { "Review only \($0) and what it depends on." } ?? "Review the whole specification."
        let prompt = context(feature, focus: focus.map { [$0] } ?? feature.list(.requirement).map(\.id), budget: 70_000) + """

        Task: \(scope) Judge whether it is complete, consistent, understandable and implementation-ready. \
        Look through these perspectives internally — Product, UX, Architecture, Backend, Frontend, Security, \
        QA, Reliability, Operations, Data, Privacy, Business — but report unified findings. For each: a short \
        title, category, severity (blocker = cannot implement without resolving; high; medium; low), the \
        perspectives, the exact quote it is about and the object id or document path it is in, what is wrong, \
        and for ambiguities the possible interpretations. Check the project's other documentation for \
        contradictions and related material. Only real problems; no style remarks.
        """
        let findingSchema = Self.object([
            "title": Self.string, "category": ["type": "string", "enum": FeatureVocabulary.findingCategories],
            "severity": ["type": "string", "enum": FeatureVocabulary.severities],
            "perspectives": Self.strings, "quote": Self.string, "target": Self.string,
            "detail": Self.string, "interpretations": Self.strings,
        ])
        let schema = Self.object(["findings": Self.array(findingSchema)])
        guard let result = await run("review:" + slug, prompt: prompt, schema: schema, timeout: 900),
              let findings = (result.structured as? [String: Any])?["findings"] as? [[String: Any]] else { return }
        let openTitles = Set(store.feature(slug)?.list(.finding).filter { !$0.isClosed }.map { $0.title.lowercased() } ?? [])
        for f in findings {
            let title = f["title"] as? String ?? "Finding"
            guard !openTitles.contains(title.lowercased()) else { continue }
            let interpretations = f["interpretations"] as? [String] ?? []
            var body = "## Finding\n\n\(f["detail"] as? String ?? "")\n"
            if let quote = f["quote"] as? String, !quote.isEmpty { body += "\n> \(quote)\n" }
            if !interpretations.isEmpty { body += "\n## Possible interpretations\n\n" + interpretations.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            let target = f["target"] as? String ?? ""
            store.create(.finding, in: slug, title: title,
                         fields: [("category", .string(f["category"] as? String ?? "completeness")),
                                  ("severity", .string(f["severity"] as? String ?? "medium")),
                                  ("perspectives", .list((f["perspectives"] as? [String] ?? []).map { .string($0) })),
                                  ("refs", .list(target.isEmpty ? [] : [.string(target)])),
                                  ("quote", .string(f["quote"] as? String ?? "")),
                                  ("interpretations", .list(interpretations.map { .string($0) }))],
                         body: body, provenance: "Generated by AI (review)")
        }
        if let feature = store.feature(slug), ["exploring", "draft", "idea"].contains(feature.status) {
            store.updateFeature(slug) { front, _ in front.set("status", "review") }
        }
    }

    /// Acceptance criteria for a requirement that has none (or more of them).
    func acceptanceCriteria(_ slug: String, requirement id: String) async {
        guard let feature = store.feature(slug), let requirement = feature.object(id) else { return }
        let prompt = context(feature, focus: [id]) + """

        Task: write testable acceptance criteria for \(id) (\(requirement.title)). Keep the ones it has; \
        add what is missing. Each criterion one line, observable, unambiguous.
        """
        let schema = Self.object(["criteria": Self.strings])
        guard let result = await run("criteria:" + id, prompt: prompt, schema: schema),
              let criteria = (result.structured as? [String: Any])?["criteria"] as? [String] else { return }
        let existing = Set(requirement.acceptanceCriteria.map { $0.text.lowercased() })
        let added = criteria.filter { !existing.contains($0.lowercased()) }
        guard !added.isEmpty else { return }
        store.update(id, in: slug) { _, body in
            let lines = added.map { "- [ ] \($0)" }.joined(separator: "\n")
            if body.lowercased().contains("## acceptance criteria") {
                body = body.trimmingCharacters(in: .newlines) + "\n" + lines + "\n"
            } else {
                body += "\n## Acceptance Criteria\n\n\(lines)\n"
            }
        }
    }

    // MARK: - Resolve (spec §17)

    /// Resolution options for a finding (conflict, ambiguity…), kept on the finding.
    func resolutionOptions(_ slug: String, finding id: String) async {
        guard let feature = store.feature(slug), let finding = feature.object(id) else { return }
        let prompt = context(feature, focus: [id]) + """

        Task: \(id) (\(finding.title)) must be resolved. Phrase the decision the team has to make as one \
        question, and give 2–4 concrete ways to resolve it (short button labels plus what each means and its \
        consequence for the requirements).
        """
        let optionSchema = Self.object(["label": Self.string, "text": Self.string, "consequence": Self.string])
        let schema = Self.object(["question": Self.string, "options": Self.array(optionSchema)])
        guard let result = await run("resolveopts:" + id, prompt: prompt, schema: schema),
              let object = result.structured as? [String: Any] else { return }
        let list = object["options"] as? [[String: Any]] ?? []
        store.update(id, in: slug) { front, _ in
            front.set("status", "discussing")
            front.set("resolution_question", object["question"] as? String ?? "")
            front["options"] = .list(list.map { o in
                .map([("label", .string(o["label"] as? String ?? "")), ("text", .string(o["text"] as? String ?? "")),
                      ("consequence", .string(o["consequence"] as? String ?? ""))])
            })
        }
    }

    /// Resolve a finding with one of its options (or the user's own text): an accepted decision
    /// linked to the finding and the requirements it is about.
    func resolve(_ slug: String, finding id: String, with choice: String) async {
        guard let feature = store.feature(slug), let finding = feature.object(id) else { return }
        let others = (finding.front["options"]?.list ?? []).compactMap { $0["text"]?.string }.filter { $0 != choice }
        let prompt = context(feature, focus: [id]) + """

        \(id): \(finding.title)
        The team chose: \(choice)
        Other options were: \(others.joined(separator: " | "))

        Task: record this as a decision (context, alternatives, decision, reason, consequences).
        """
        let schema = Self.object(["decision": Self.decisionSchema])
        guard let result = await run("resolve:" + id, prompt: prompt, schema: schema),
              let d = (result.structured as? [String: Any])?["decision"] as? [String: Any],
              let decision = makeDecision(d, in: slug, status: "accepted", sources: [id], provenance: "Resolved \(id)") else { return }
        store.update(id, in: slug) { front, body in
            front.set("status", "resolved")
            front.set("resolved_by", decision.id)
            body += "\n## Resolution\n\n\(choice) — see \(decision.id).\n"
        }
        for target in finding.front.strings("refs") where FeatureObjectKind.of(id: target) == .requirement {
            store.update(target, in: slug) { front, _ in
                front.set("decisions", list: Array(Set(front.strings("decisions") + [decision.id])).sorted())
                if front.string("status") == "approved" { front.set("status", "review") }
            }
        }
    }

    // MARK: - Contextual actions (spec §8)

    /// An action on text selected in a document. Answers appear in the Feature tab; the
    /// object actions create the object in the feature.
    func perform(_ action: FeatureAction, selection: String, document: String?, question: String = "", feature slug: String?) async {
        let feature = slug.flatMap { store.feature($0) }
        let where_ = document.map { " (in \($0))" } ?? ""
        let base = (feature.map { context($0, query: selection) } ?? "") + "\n\n## Selected text\(where_)\n\n\(selection.prefix(12_000))\n"
        switch action {
        case .requirement, .decision, .question:
            guard let slug, feature != nil else {
                error = "Open or create a feature first: the object is stored in a feature."
                return
            }
            await createFromSelection(action, base: base, selection: selection, document: document, slug: slug)
        case .research:
            guard let slug else { error = "Open or create a feature first."; return }
            if let note = await research(slug, topic: selection) {
                results.insert(FeatureResult(title: "Research: \(note.title)", text: note.section("Summary"), pending: false, feature: slug), at: 0)
            }
        default:
            let prompt = base + "\n" + action.instruction + (question.isEmpty ? "" : "\n\nThe user's question: \(question)")
                + "\n\nAnswer in Markdown, concisely."
            var item = FeatureResult(title: action.title, text: "", pending: true, feature: slug)
            results.insert(item, at: 0)
            let resultID = item.id
            var streamed = ""
            let result = await run("action:" + resultID.uuidString, prompt: prompt, schema: nil, onDelta: { text in
                Task { @MainActor in
                    streamed += text
                    self.updateResult(resultID) { $0.text = streamed }
                }
            })
            item.text = result?.text ?? streamed
            updateResult(resultID) { r in
                r.text = result.map { $0.text.isEmpty ? streamed : $0.text } ?? (streamed.isEmpty ? (self.error ?? "Failed") : streamed)
                r.pending = false
                if action == .diagram, let mermaid = Self.mermaidBlock(r.text) { r.diagram = mermaid }
            }
        }
    }

    private func updateResult(_ id: UUID, _ change: (inout FeatureResult) -> Void) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        change(&results[index])
    }

    private func createFromSelection(_ action: FeatureAction, base: String, selection: String, document: String?, slug: String) async {
        let provenance = "Created from selection" + (document.map { " in \($0)" } ?? "")
        switch action {
        case .requirement:
            let prompt = base + "\nTask: turn the selected text into one well-formed requirement with acceptance criteria."
            guard let result = await run("create-req:" + slug, prompt: prompt, schema: Self.object(["requirement": Self.requirementSchema])),
                  let r = (result.structured as? [String: Any])?["requirement"] as? [String: Any] else { return }
            if let req = makeRequirement(r, in: slug, sources: document.map { [$0] } ?? [], decisions: [], provenance: provenance) {
                results.insert(FeatureResult(title: "Created \(req.id)", text: req.title, pending: false, feature: slug), at: 0)
            }
        case .decision:
            let prompt = base + "\nTask: write the decision the selected text states or implies (context, alternatives, decision, reason, consequences)."
            guard let result = await run("create-dec:" + slug, prompt: prompt, schema: Self.object(["decision": Self.decisionSchema])),
                  let d = (result.structured as? [String: Any])?["decision"] as? [String: Any] else { return }
            if let decision = makeDecision(d, in: slug, status: "proposed", sources: document.map { [$0] } ?? [], provenance: provenance) {
                results.insert(FeatureResult(title: "Created \(decision.id)", text: decision.title, pending: false, feature: slug), at: 0)
            }
        case .question:
            let prompt = base + "\nTask: phrase the open question the selected text raises, with 0–4 options."
            let schema = Self.object(["question": Self.object(["text": Self.string, "why": Self.string,
                                                               "q_type": ["type": "string", "enum": FeatureVocabulary.questionTypes],
                                                               "options": Self.array(Self.optionSchema)])])
            guard let result = await run("create-q:" + slug, prompt: prompt, schema: schema),
                  let q = (result.structured as? [String: Any])?["question"] as? [String: Any] else { return }
            let text = q["text"] as? String ?? ""
            let body = "## Question\n\n\(text)\n\n## Why it matters\n\n\(q["why"] as? String ?? "")\n\n> \(selection.prefix(600))\n"
            if let question = store.create(.question, in: slug, title: String(text.prefix(140)),
                                           fields: [("q_type", .string(q["q_type"] as? String ?? "clarification")),
                                                    ("priority", .string("normal")), ("blocking", .list([])),
                                                    ("refs", .list(document.map { [.string($0)] } ?? [])),
                                                    ("options", options(q["options"] as? [[String: Any]] ?? []))],
                                           body: body, provenance: provenance) {
                results.insert(FeatureResult(title: "Created \(question.id)", text: question.title, pending: false, feature: slug), at: 0)
            }
        default: break
        }
    }

    static func mermaidBlock(_ text: String) -> String? {
        guard let start = text.range(of: "```mermaid") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "```") else { return nil }
        return rest[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save a generated diagram into the feature (diagrams/<name>.md) and return its file.
    func saveDiagram(_ mermaid: String, title: String, in slug: String) -> URL? {
        guard let feature = store.feature(slug) else { return nil }
        let name = featureSlug(title).isEmpty ? "diagram" : featureSlug(title)
        var url = feature.folder.appendingPathComponent("diagrams/\(name).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = feature.folder.appendingPathComponent("diagrams/\(name)-\(n).md"); n += 1 }
        let text = "# \(title)\n\n```mermaid\n\(mermaid)\n```\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)).map { url }
    }

    // MARK: - Discussion (free-form chat, with decision detection — spec §16, §32)

    func chat(_ slug: String, message: String) async {
        guard let feature = store.feature(slug) else { return }
        store.appendDiscussion(slug, speaker: store.defaultOwner.isEmpty ? "User" : store.defaultOwner, text: message)
        var item = FeatureResult(title: "Discussion", text: "", pending: true, feature: slug)
        results.insert(item, at: 0)
        let prompt = context(feature, query: message) + """

        ## Discussion so far
        \(store.discussion(slug))

        ## New message
        \(message)

        Task: reply as the facilitator (Markdown, concise; ask back when something is unclear). Then judge \
        whether the discussion has reached a decision worth recording; if so, draft it.
        """
        let schema = Self.object(["reply": Self.string, "has_decision": ["type": "boolean"], "decision": Self.decisionSchema])
        let result = await run("chat:" + slug, prompt: prompt, schema: schema)
        let object = result?.structured as? [String: Any] ?? [:]
        item.text = object["reply"] as? String ?? (error ?? "No answer")
        item.pending = false
        if object["has_decision"] as? Bool == true, let d = object["decision"] as? [String: Any] {
            item.decision = DecisionCandidate(title: d["title"] as? String ?? "", context: d["context"] as? String ?? "",
                                              alternatives: d["alternatives"] as? [String] ?? [],
                                              decision: d["decision"] as? String ?? "", reason: d["reason"] as? String ?? "")
        }
        let resultID = item.id
        updateResult(resultID) { $0 = item }
        store.appendDiscussion(slug, speaker: "AI", text: item.text)
    }

    /// "Create Decision" on a detected decision.
    func saveDecision(_ candidate: DecisionCandidate, in slug: String, from resultID: UUID) {
        let d: [String: Any] = ["title": candidate.title, "context": candidate.context, "alternatives": candidate.alternatives,
                                "decision": candidate.decision, "reason": candidate.reason, "consequences": ""]
        if let decision = makeDecision(d, in: slug, status: "accepted", sources: ["discussion"], provenance: "Generated from discussion") {
            updateResult(resultID) { $0.decision = nil; $0.text += "\n\n→ Saved as \(decision.id)." }
        }
    }

    func dismissResult(_ id: UUID) { results.removeAll { $0.id == id } }

    /// "Continue Discussion": keep talking, drop the decision proposal.
    func dismissDecision(_ id: UUID) { updateResult(id) { $0.decision = nil } }

    // MARK: - Build (spec §24–26)

    /// Propose implementation issues covering the approved requirements.
    func decompose(_ slug: String) async {
        guard let feature = store.feature(slug) else { return }
        let approved = feature.list(.requirement).filter { $0.status == "approved" }
        let pool = approved.isEmpty ? feature.list(.requirement).filter { $0.status != "rejected" } : approved
        let prompt = context(feature, focus: pool.map(\.id), budget: 70_000) + """

        Task: decompose the requirements \(pool.map(\.id).joined(separator: ", ")) into implementation issues \
        (an epic of 2–10 issues), each a coherent, independently reviewable piece of work: title, one-paragraph \
        summary, the requirement ids it implements and the decision ids it follows. Every listed requirement \
        must be covered by at least one issue. Do not write code.
        """
        let issueSchema = Self.object(["title": Self.string, "summary": Self.string,
                                       "requirements": Self.strings, "decisions": Self.strings])
        let schema = Self.object(["epic_title": Self.string, "issues": Self.array(issueSchema)])
        guard let result = await run("decompose:" + slug, prompt: prompt, schema: schema, timeout: 600),
              let object = result.structured as? [String: Any] else { return }
        let issues = (object["issues"] as? [[String: Any]] ?? []).enumerated().map { index, i in
            PlannedIssue(id: "I-\(index + 1)", title: i["title"] as? String ?? "Issue \(index + 1)",
                         summary: i["summary"] as? String ?? "", requirements: i["requirements"] as? [String] ?? [],
                         decisions: i["decisions"] as? [String] ?? [])
        }
        store.savePlan(slug, title: object["epic_title"] as? String ?? feature.title, issues: issues, epic: nil)
    }

    /// Create the GitHub issues of the plan (and the epic), keeping requirement and decision
    /// references both in the issues and in the requirement files.
    func createIssues(_ slug: String) async {
        guard let feature = store.feature(slug) else { return }
        guard let client = gitHubClient() else {
            error = "Turn on the GitHub integration (Settings → GitHub) in a folder with a GitHub remote."
            return
        }
        guard !running.contains("issues:" + slug) else { return }
        running.insert("issues:" + slug)
        defer { running.remove("issues:" + slug) }
        var issues = feature.planIssues
        let title = feature.planFront.string("title").isEmpty ? feature.title : feature.planFront.string("title")
        do {
            for index in issues.indices where issues[index].github == nil {
                let issue = issues[index]
                var body = issue.summary + "\n\n### Requirements\n\n"
                body += issue.requirements.map { id in
                    let req = feature.object(id)
                    return "- **\(id)** \(req?.title ?? "")" + (req.map { " — `\(store.relativePath($0.url))`" } ?? "")
                }.joined(separator: "\n")
                if !issue.decisions.isEmpty {
                    body += "\n\n### Decisions\n\n" + issue.decisions.map { id in
                        "- **\(id)** \(feature.object(id)?.title ?? "")"
                    }.joined(separator: "\n")
                }
                body += "\n\n_Feature: `\(store.relativePath(feature.folder))` · generated from the specification._"
                let url = try await client.createIssue(title: issue.title, body: body)
                guard let number = Int(url.split(separator: "/").last ?? "") else {
                    // Created, but its number is unknown: stop rather than create it again on retry.
                    throw GitHubError(message: "Created \"\(issue.title)\" but could not read its number from \(url); add it to the plan by hand.")
                }
                issues[index].github = number
                for id in issue.requirements {
                    store.update(id, in: slug) { front, _ in
                        front.set("issues", list: Array(Set(front.strings("issues") + ["#\(number)"])).sorted())
                    }
                }
                store.savePlan(slug, title: title, issues: issues, epic: feature.epic)
            }
            var epic = feature.epic
            if epic == nil {
                let list = issues.compactMap { i in i.github.map { "- [ ] #\($0) \(i.title)" } }.joined(separator: "\n")
                let url = try await client.createIssue(title: "Epic: \(title)",
                                                       body: "Implementation of `\(store.relativePath(feature.folder))`.\n\n\(list)\n")
                epic = Int(url.split(separator: "/").last ?? "")
            }
            store.savePlan(slug, title: title, issues: issues, epic: epic)
            store.updateFeature(slug) { front, _ in
                if ["ready", "resolving", "review", "draft", "exploring"].contains(front.string("status")) { front.set("status", "implementing") }
            }
        } catch {
            store.savePlan(slug, title: title, issues: issues, epic: feature.epic)
            self.error = "Creating issues: \(error.localizedDescription)"
        }
    }

    /// Pull requests that close a GitHub issue (traceability: requirement → issue → PR).
    func pullRequests(closing issue: Int) async -> [(number: Int, title: String, url: String)] {
        guard let client = gitHubClient(),
              let text = try? await client.gh(["issue", "view", String(issue), "-R", client.repo.slug,
                                               "--json", "closedByPullRequestsReferences"]),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        return (object["closedByPullRequestsReferences"] as? [[String: Any]] ?? []).compactMap { pr in
            guard let number = pr["number"] as? Int else { return nil }
            return (number, pr["title"] as? String ?? "", pr["url"] as? String ?? "")
        }
    }

    /// Files changed by a pull request (impact: potentially affected code).
    func files(of pullRequest: Int) async -> [String] {
        guard let client = gitHubClient(),
              let text = try? await client.gh(["pr", "view", String(pullRequest), "-R", client.repo.slug, "--json", "files", "-q", ".files[].path"])
        else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
