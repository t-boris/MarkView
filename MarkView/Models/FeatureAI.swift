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

    struct ActionState {
        enum Phase { case running, completed, stopped, failed }
        let key: String
        let title: String
        let scope: String
        let assistant: String
        let output: String
        let started: Date
        var stage: String
        var partial: String = ""
        var phase: Phase = .running
    }
    @Published private(set) var actions: [String: ActionState] = [:]
    private var actionTasks: [String: Task<CLICompletion.Result, Error>] = [:]
    private var stopRequested: Set<String> = []

    func stopAction(_ key: String) {
        stopRequested.insert(key)
        if var state = actions[key] {
            state.stage = "Stopping…"
            actions[key] = state
        }
        actionTasks[key]?.cancel()
    }
    func dismissAction(_ key: String) { actions.removeValue(forKey: key) }

    /// Voice notes for sources; owned here so a recording survives switching panels.
    let voice = WhisperClient()

    /// Wired by WorkspaceManager.
    var database: () -> SemanticDatabase? = { nil }
    var gitHubClient: () -> GitHubClient? = { nil }
    /// The store is a new-project draft (Start a Project from Scratch): the "feature" is the whole
    /// project, specified before its folder exists.
    var projectDiscovery = false

    init(store: FeatureStore) {
        self.store = store
    }

    func isRunning(_ key: String) -> Bool { running.contains(key) || preparing.contains(key) }

    /// "Decide all for me" progress per feature: findings done, total.
    @Published var decideProgress: [String: (done: Int, total: Int)] = [:]
    /// The settlement apply running per feature (`applyDecisions`).
    private var applying: [String: Task<Void, Never>] = [:]

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
        understanding notes, suggestions, replies, explanations, resolution questions and options, the \
        answer or resolution you chose when asked to decide yourself (`chosen`) — in \
        \(conversation). Write \
        the specification itself — requirement titles, statements and acceptance criteria, decision \
        texts, finding titles and details, research claims and summaries, source summaries and facts — \
        in English. Keep JSON enum values exactly as specified.
        """
    }

    /// Added to the facilitator's instructions for a new-project draft (DEC-007, DEC-016, DEC-021).
    private static let projectDiscoveryNote = """
    This workspace is a draft of a NEW project that does not exist yet: no folder, no code, no \
    repository. The "feature" you see is the whole project. Clarify what the user wants to build \
    until its intent is clear: the goal, who it is for, the core workflow, and a first direction for \
    the kind of project and its architecture. Record what is decided as decisions and requirements. \
    Mark a question blocking only when the project brief (its goal and what the first version must \
    do) cannot be confirmed without the answer; everything else is not blocking and may stay open \
    for later work. Do not choose technology the user has not asked for, and do not plan files, \
    templates or deployment. There are no project documents yet: "the language the user writes in" \
    is the language of the user's idea (the Original request source).
    """

    /// `effort`: "low" for the many small calls; "medium" where the answer shapes the specification
    /// (intake, discovery rounds) — a few slower calls instead of many shallow ones.
    private func run(_ key: String, prompt: String, schema: [String: Any]?, web: Bool = false, effort: String = "low",
                     timeout: TimeInterval = 400, onDelta: (@Sendable (String) -> Void)? = nil) async -> CLICompletion.Result? {
        guard !running.contains(key) else {
            error = "That is already running — wait for it to finish."
            return nil
        }
        running.insert(key)
        defer { running.remove(key) }
        // The answer belongs to this folder: dropped if another folder was opened meanwhile.
        let folder = store.root
        let system = projectDiscovery ? Self.system + "\n\n" + Self.projectDiscoveryNote : Self.system
        var request = CLICompletion.Request(project: store.root, prompt: prompt, systemPrompt: system,
                                            jsonSchema: schema, readableFolder: store.root)
        request.allowWeb = web
        request.effort = effort
        request.timeout = timeout
        request.label = key
        let model = request.model ?? AIAssistantPreferences.model(for: request.tool, project: request.project) ?? "default model"
        actions[key] = ActionState(key: key, title: Self.title(for: key),
                                   scope: folder?.path ?? "Selected text",
                                   assistant: "\(request.tool.displayName) · \(model)",
                                   output: folder.map { "Work · \($0.lastPathComponent)" } ?? "Work result",
                                   started: Date(), stage: "Starting")
        let task = Task {
            try await CLICompletion.run(request, onDelta: { [weak self] text in
                onDelta?(text)
                Task { @MainActor in
                    guard var state = self?.actions[key], state.phase == .running else { return }
                    state.partial += text
                    state.stage = "Writing answer"
                    self?.actions[key] = state
                }
            }, onActivity: { [weak self] activity in
                Task { @MainActor in
                    guard var state = self?.actions[key], state.phase == .running else { return }
                    switch activity {
                    case .read: state.stage = "Reading project files"
                    case .search: state.stage = "Searching project"
                    case .run: state.stage = "Inspecting project"
                    case .webSearch: state.stage = "Searching the web"
                    case .webFetch: state.stage = "Reading a web source"
                    case .thinking: state.stage = "Thinking"
                    case .writing, .answerDelta: state.stage = "Writing answer"
                    }
                    self?.actions[key] = state
                }
            })
        }
        actionTasks[key] = task
        defer {
            actionTasks.removeValue(forKey: key)
            stopRequested.remove(key)
        }
        do {
            let result = try await task.value
            if stopRequested.contains(key) {
                markStopped(key)
                return nil
            }
            guard store.root == folder else { return nil }
            result.record(in: database())
            error = nil
            // Successful work is available in its document or result. Keep only failed and
            // stopped cards so their error or partial output remains readable in Tasks.
            actions.removeValue(forKey: key)
            return result
        } catch is CancellationError {
            markStopped(key)
            return nil
        } catch {
            if stopRequested.contains(key) {
                markStopped(key)
                return nil
            }
            self.error = error.localizedDescription
            if var state = actions[key] {
                state.phase = .failed
                state.stage = error.localizedDescription
                actions[key] = state
            }
            return nil
        }
    }

    private func markStopped(_ key: String) {
        if var state = actions[key] {
            state.phase = .stopped
            state.stage = "Stopped · partial answer retained"
            actions[key] = state
        }
    }

    private static func title(for key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.first == "action", parts.count > 1 {
            return FeatureAction(rawValue: String(parts[1]))?.title ?? "Selected text"
        }
        switch parts.first {
        case "explore": return "Ask questions"
        case "answer": return "Process answers"
        case "review": return "Review feature"
        case "research": return "Research feature"
        case "chat": return "Discuss feature"
        case "discuss": return "Discuss bug"
        case "decompose": return "Plan implementation"
        case "consolidate": return "Consolidate requirements"
        case "resolveopts": return "Resolve finding"
        default: return parts.first.map { String($0).capitalized } ?? "AI action"
        }
    }

    /// A structured answer (the JSON object), or nil when it failed (see `error`).
    func structured(_ key: String, prompt: String, schema: [String: Any], web: Bool = false, effort: String = "low",
                    timeout: TimeInterval = 400) async -> [String: Any]? {
        await run(key, prompt: prompt, schema: schema, web: web, effort: effort, timeout: timeout)?.structured as? [String: Any]
    }

    // MARK: - Context (spec §31)

    /// The feature as the AI needs it for an operation on `focus`: overview, the user's own words,
    /// understanding, the focused objects in full with their linked objects, a digest of the rest
    /// (answered questions with their answers), accepted facts, the discussion, and related
    /// project documentation.
    func context(_ feature: Feature, focus: [String] = [], query: String = "", budget: Int = 45_000,
                 discussion: Bool = true) -> String {
        var out = "# Feature: \(feature.title) (\(feature.slug)) — status \(feature.status)\n\n"
        out += feature.overviewBody.prefix(6_000) + "\n\n"
        // What the user wrote, verbatim: later calls work from the request, not from its paraphrase.
        let original = feature.list(.source).filter { ["intake", "voice"].contains($0.front.string("origin")) }
        if !original.isEmpty {
            out += "## Original request (the user's own words)\n\n"
            var left = 10_000
            for source in original where left > 0 {
                let text = String(source.section("Content").prefix(left))
                guard !text.isEmpty else { continue }
                left -= text.count
                out += "### \(source.id) \(source.title)\n\n\(text)\n\n"
            }
        }
        // A feature's own documents (hand-written specs: requirements.md, design.md, …).
        var documentBudget = 20_000
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
            // Merged (superseded) requirements are history, not specification.
            let rest = feature.list(kind).filter { !seen.contains($0.id) && $0.status != "superseded" }
            guard !rest.isEmpty else { continue }
            out += "## \(kind.title)\n"
            for object in rest {
                var line = "- \(object.id) [\(object.status)] \(object.title)"
                if kind == .decision, !object.section("Decision").isEmpty { line += " — " + object.section("Decision").prefix(200) }
                if kind == .requirement { line += " — " + object.section("Statement").prefix(200) }
                // A closed finding carries how it was settled: what was settled is never reported again.
                if kind == .finding, !object.settlement.isEmpty { line += " — " + object.settlement.prefix(300) }
                // An answered question carries its answer: what was settled is never asked again.
                if kind == .question {
                    let answer = object.front.string("answer")
                    if object.status == "answered", !answer.isEmpty { line += " — answer: " + answer.prefix(300) }
                    if object.status == "open", !object.front.string("recommended").isEmpty { line += " — recommended: " + object.front.string("recommended").prefix(120) }
                }
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
        // The conversation so far (answers and chat): the AI's memory between stateless calls.
        if discussion {
            let transcript = store.discussion(feature.slug, limit: 6_000)
            if !transcript.isEmpty { out += "## Discussion so far\n\(transcript)\n\n" }
        }
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
        // After Explore, a requirement the resolution or a consolidation writes is approved at once.
        let status = store.feature(slug)?.isPastExplore == true ? "approved" : "draft"
        return store.create(.requirement, in: slug, title: r["title"] as? String ?? "Requirement",
                            fields: [("status", .string(status)), ("req_type", .string(r["req_type"] as? String ?? "functional")),
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

    /// Ask the next round of questions (0–3 Q files with options and a recommended answer) and
    /// update the understanding notes. Nothing is asked while a question is still open or when
    /// discovery is done.
    /// Requirements and decisions the team deleted since (`removed_since_explore`, "REQ-003 Title")
    /// are named in the prompt, so what they settled is asked again where the feature still needs
    /// it; the record is cleared once a round was asked. Returns whether a round was asked.
    @discardableResult
    func exploreNext(_ slug: String) async -> Bool {
        preparing.insert("explore:" + slug)
        defer { preparing.remove("explore:" + slug) }
        guard let feature = store.feature(slug) else { return false }
        // A question is still waiting for its answer: the Explore stage shows it; a new one
        // would repeat it (BUG-011).
        guard feature.openQuestions.isEmpty else { return false }
        // Done (nothing open, the AI expects no more): nothing to ask. "Ask more questions" or a
        // dimension marked partial or unknown by hand opens discovery again.
        if feature.isUnderstood, feature.questionsLeft == 0 {
            store.updateFeature(slug) { front, _ in front.set("questions_left", "1") }
        }

        let asked = feature.list(.question).map { "- \($0.id) [\($0.status)] \($0.title)" }.joined(separator: "\n")
        let removed = feature.front.strings("removed_since_explore")
        let prompt = context(feature) + """

        ## Questions already asked
        \(asked.isEmpty ? "(none)" : asked)

        \(removed.isEmpty ? "" : """
        ## Removed by the team
        These requirements and decisions were deleted, so what they settled is no longer specified:
        \(removed.map { "- " + $0 }.joined(separator: "\n"))
        Ask again about what they covered only where the feature still needs an answer; do not bring \
        them back by yourself.

        """)
        Task: \(Self.discoveryInstruction) Add up to 3 short suggestions (things to consider or add).
        """
        let schema = Self.object([
            "understanding": Self.understandingSchema,
            "questions": Self.array(Self.questionSchema),
            "questions_left": ["type": "integer"],
            "suggestions": Self.strings,
        ])
        guard let result = await run("explore:" + slug, prompt: prompt, schema: schema, effort: "medium"),
              let object = result.structured as? [String: Any] else { return false }
        applyDiscovery(object, to: slug)
        if !removed.isEmpty { store.updateFeature(slug) { front, _ in front["removed_since_explore"] = nil } }
        if feature.status == "idea" { store.updateFeature(slug) { front, _ in front.set("status", "exploring") } }
        let suggestions = object["suggestions"] as? [String] ?? []
        if !suggestions.isEmpty {
            results.insert(FeatureResult(title: "Suggestions", text: suggestions.map { "• " + $0 }.joined(separator: "\n"),
                                         pending: false, feature: slug), at: 0)
        }
        return true
    }

    /// After requirements or decisions were deleted: a question round about what they settled.
    /// While a question is open no round is asked (BUG-011); the next one covers the removals.
    func reexplore(_ slug: String) async {
        guard let feature = store.feature(slug) else { return }
        guard feature.openQuestions.isEmpty else {
            results.insert(FeatureResult(title: "Answer the open question first",
                                         text: "The next question round also covers what was removed.",
                                         pending: false, feature: slug), at: 0)
            return
        }
        if feature.questionsLeft == 0 { store.updateFeature(slug) { front, _ in front.set("questions_left", "1") } }
        await exploreNext(slug)
    }

    /// A question as discovery and the intake ask it: the text, why it matters, the dimension it
    /// clarifies, 2–4 options, and the answer the AI recommends (an option's label, or the answer
    /// itself for an open-ended question) with its reason.
    static let questionSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"], "why": ["type": "string"],
                       "dimension": ["type": "string", "enum": FeatureVocabulary.understanding],
                       "q_type": ["type": "string", "enum": FeatureVocabulary.questionTypes],
                       "blocking": ["type": "boolean"], "options": ["type": "array", "items": optionSchema],
                       "recommended": ["type": "string"], "recommended_why": ["type": "string"]],
        "required": ["text", "why", "dimension", "q_type", "blocking", "options", "recommended", "recommended_why"],
    ]

    /// How many questions one round may ask.
    static let questionsPerRound = 3

    static let discoveryInstruction = """
    Decide what still has to be asked. First establish what is already settled: by the original request \
    (the user's own words), the recorded answers and decisions, the requirements, and the project itself — \
    read its documents and code for existing behaviour, conventions and similar features. Nothing settled is \
    asked again, and what the project already does is stated as a fact, never asked. A question is worth \
    asking only when the product owner's answer changes the specification and cannot be found out otherwise. \
    Implementation details (formats, schemas, file layouts, naming, internal APIs) and the edge cases the \
    review covers are never asked; the implementer decides them. Ask the fewest questions needed — at most \
    \(questionsPerRound) in this round, independent of each other, the most important first; an empty list \
    when the specification can be written now. Each question: 2–4 concrete options (labelled A, B, C…) with \
    short pros and cons, unless it is open-ended (then no options); `recommended`: the option you would \
    choose for this feature and project (its label, or the answer itself when open-ended) and \
    `recommended_why` in one line; `blocking` true when requirements cannot be written without the answer; \
    `dimension`: the understanding dimension it clarifies most. `questions_left`: your honest estimate of \
    how many questions are still needed in all, including the ones asked now (0 when none). \
    Scope: stay inside the feature's idea and scope as written in its overview. Never grow the feature — \
    a question whose answer would add capabilities beyond the idea is out of scope. \
    `understanding`: rate every dimension (known / partial / unknown / n/a) with a short note of what is \
    known or missing, as a summary for the user; a partial or unknown dimension is not by itself a reason \
    to ask — many do not apply to a small feature.
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

    /// Understanding, the next round of questions and the estimate of questions left, from a
    /// discovery answer. Returns the questions created.
    @discardableResult
    private func applyDiscovery(_ object: [String: Any], to slug: String) -> [FeatureObject] {
        applyUnderstanding(object, to: slug)
        let asked = (object["questions"] as? [[String: Any]] ?? []).prefix(Self.questionsPerRound)
            .compactMap { makeQuestion($0, in: slug, provenance: "Generated by AI (guided discovery)") }
        // The estimate never says "none" while questions were just asked.
        let left = max(object["questions_left"] as? Int ?? 0, asked.count)
        store.updateFeature(slug) { front, _ in front.set("questions_left", String(max(0, left))) }
        return asked
    }

    /// A question file from an AI question. Nothing is created for an empty text or one already
    /// asked (same wording) — the AI cannot repeat a question by accident.
    @discardableResult
    func makeQuestion(_ q: [String: Any], in slug: String, provenance: String) -> FeatureObject? {
        let text = (q["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(text.prefix(140))
        guard !text.isEmpty, let feature = store.feature(slug),
              !feature.list(.question).contains(where: { $0.title.lowercased() == title.lowercased() }) else { return nil }
        let optionList = q["options"] as? [[String: Any]] ?? []
        let recommended = (q["recommended"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recommendedWhy = (q["recommended_why"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var body = "## Question\n\n\(text)\n\n## Why it matters\n\n\(q["why"] as? String ?? "")\n"
        if !optionList.isEmpty {
            body += "\n## Options\n\n" + optionList.map { "- **\($0["label"] as? String ?? "")**: \($0["text"] as? String ?? "")" }.joined(separator: "\n") + "\n"
        }
        if !recommended.isEmpty {
            body += "\n## Recommended\n\n\(recommended)" + (recommendedWhy.isEmpty ? "" : " — \(recommendedWhy)") + "\n"
        }
        var fields: [(String, YAMLValue)] = [
            ("q_type", .string(q["q_type"] as? String ?? "clarification")),
            ("priority", .string(q["blocking"] as? Bool == true ? "blocking" : "normal")),
            ("origin", .string("explore")), ("dimension", .string(q["dimension"] as? String ?? "")),
            ("blocking", .list([])), ("options", options(optionList)),
        ]
        if !recommended.isEmpty {
            fields.append(("recommended", .string(recommended)))
            fields.append(("recommended_why", .string(recommendedWhy)))
        }
        return store.create(.question, in: slug, title: title, fields: fields, body: body, provenance: provenance)
    }

    /// One answer of a round: the user's choice or own words, or "let the AI decide".
    struct QuestionAnswer {
        var id: String
        var answer: String
        var delegated = false
    }

    /// The user answered one question. See `answerBatch`.
    func answer(_ slug: String, question id: String, answer: String, next: Bool = true, delegated: Bool = false) async {
        await answerBatch(slug, answers: [QuestionAnswer(id: id, answer: answer, delegated: delegated)], next: next)
    }

    /// The user answered a round of questions (chose options, wrote answers, or let the AI decide
    /// some): one AI call records the answers, turns them into decisions where a real choice was made
    /// and into requirement changes, updates the understanding, and asks the next round.
    /// A delegated question with a recommended answer takes that answer; without one the AI chooses.
    /// Decisions from delegated answers are proposed (the user accepts or overrides them in Review).
    func answerBatch(_ slug: String, answers: [QuestionAnswer], next: Bool = true) async {
        let key = "answer:" + slug
        preparing.insert(key)
        defer { preparing.remove(key) }
        guard let feature = store.feature(slug) else { return }
        let items = answers.compactMap { a -> (given: QuestionAnswer, question: FeatureObject)? in
            guard let q = feature.object(a.id), q.kind == .question, q.status == "open" else { return nil }
            return (a, q)
        }
        guard !items.isEmpty else { return }
        let answeredIDs = Set(items.map(\.question.id))
        // Open questions are asked first (the intake's, or ones passed over); a new round only when
        // none is left, so the AI cannot ask again what is already open (BUG-011).
        let next = next && !feature.list(.question).contains { $0.status == "open" && !answeredIDs.contains($0.id) }
        // The delegated answers the AI must still choose (no recommendation recorded).
        var toChoose: [String] = []
        var block = ""
        for (given, question) in items {
            let options = (question.front["options"]?.list ?? []).map { "- \($0["label"]?.string ?? ""): \($0["text"]?.string ?? "")" }
            let recommended = question.front.string("recommended")
            block += "### \(question.id): \(question.section("Question").isEmpty ? question.title : question.section("Question"))\n"
            if !options.isEmpty { block += "Options:\n" + options.joined(separator: "\n") + "\n" }
            if given.delegated {
                if recommended.isEmpty {
                    toChoose.append(question.id)
                    block += "Answer: the user asked you to decide this yourself — choose as an experienced product owner would (one of the options or a better one) and state it in `chosen`.\n"
                } else {
                    block += "Answer (the user accepted your recommendation): \(Self.recommendedAnswer(question))\n"
                }
            } else {
                block += "Answer: \(given.answer)\n"
            }
            block += "\n"
        }
        let prompt = context(feature, focus: items.map(\.question.id)) + """

        ## The user answered \(items.count == 1 ? "a question" : "\(items.count) questions")

        \(block)
        Task: turn these answers into specification, keeping the specification small. Record a decision \
        only when an answer chose between real alternatives the specification must remember: one decision \
        per real choice (it settles several questions only when they are facets of the same choice; list \
        them in `answers`); a plain clarification needs no decision. First UPDATE the existing requirements the answers refine (requirement_updates: their \
        id, the new statement and acceptance criteria); create new requirements (0–3) only for what no \
        existing requirement covers. Never create a requirement that restates or splits an existing one. \
        \(toChoose.isEmpty ? "" : "In `chosen` give your answer for \(toChoose.joined(separator: ", ")) (one or two sentences each, in the conversation language). ")\
        \(next ? "Then, with these answers taken into account: " + Self.discoveryInstruction : "Update the understanding dimensions the answers change.")
        """
        var decisionItem = Self.decisionSchema["properties"] as? [String: Any] ?? [:]
        decisionItem["answers"] = Self.strings
        var properties: [String: Any] = [
            "decisions": Self.array(Self.object(decisionItem)),
            "requirements": Self.array(Self.requirementSchema),
            "requirement_updates": Self.array(Self.object(["id": Self.string, "statement": Self.string,
                                                           "acceptance_criteria": Self.strings])),
            "understanding": Self.understandingSchema,
        ]
        if next {
            // The next round comes in the same answer: one AI call per round instead of two.
            properties["questions"] = Self.array(Self.questionSchema)
            properties["questions_left"] = ["type": "integer"]
        }
        if !toChoose.isEmpty { properties["chosen"] = Self.array(Self.object(["id": Self.string, "answer": Self.string])) }
        guard let result = await run(key, prompt: prompt, schema: Self.object(properties), effort: "medium"),
              let object = result.structured as? [String: Any] else { return }

        let chosen = (object["chosen"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
            if let id = $1["id"] as? String, let answer = $1["answer"] as? String { $0[id] = answer }
        }
        var answerText: [String: String] = [:]
        for (given, question) in items {
            answerText[question.id] = given.delegated
                ? "AI: " + (chosen[question.id] ?? Self.recommendedAnswer(question))
                : given.answer
        }
        let delegatedIDs = Set(items.filter(\.given.delegated).map(\.question.id))
        // Decisions: each covers the questions it lists (all of the round when it lists none).
        var resolvedBy: [String: String] = [:]
        var made: [String] = []
        for d in (object["decisions"] as? [[String: Any]] ?? []).prefix(items.count) {
            let listed = (d["answers"] as? [String] ?? []).filter { answeredIDs.contains($0) && resolvedBy[$0] == nil }
            let sources = listed.isEmpty ? items.map(\.question.id).filter { resolvedBy[$0] == nil } : listed
            guard !sources.isEmpty else { continue }
            let delegated = sources.allSatisfy(delegatedIDs.contains)
            guard let decision = makeDecision(d, in: slug, status: delegated ? "proposed" : "accepted", sources: sources,
                                              provenance: (delegated ? "Chosen by AI (" : "Generated from discussion (") + sources.joined(separator: ", ") + ")")
            else { continue }
            for id in sources { resolvedBy[id] = decision.id }
            made.append(decision.id)
        }
        let produced = applyRequirementChanges(object, in: slug, sources: items.map(\.question.id), decisions: made)
        for decisionID in made { store.update(decisionID, in: slug) { front, _ in front.set("produces", list: produced) } }
        for (given, question) in items {
            let answer = answerText[question.id] ?? given.answer
            store.update(question.id, in: slug) { front, body in
                front.set("status", "answered")
                front.set("answer", answer)
                if given.delegated { front.set("answered_by", "ai") }
                if let decisionID = resolvedBy[question.id] { front.set("resolved_by", decisionID) }
                front.set("produces", list: produced)
                body += "\n## Answer\n\n\(answer)\n"
            }
            store.appendDiscussion(slug, speaker: "Answer to \(question.id)", text: "\(question.title)\n\n\(answer)")
        }
        if next { applyDiscovery(object, to: slug) } else { applyUnderstanding(object, to: slug) }
    }

    /// The recommended answer of a question as text: the recommended option ("A. …"), or the
    /// recommendation itself when it names no option.
    static func recommendedAnswer(_ question: FeatureObject) -> String {
        let recommended = question.front.string("recommended")
        let options = question.front["options"]?.list ?? []
        if let option = options.first(where: { ($0["label"]?.string ?? "").caseInsensitiveCompare(recommended) == .orderedSame }) {
            return "\(option["label"]?.string ?? ""). \(option["text"]?.string ?? "")"
        }
        return recommended
    }

    /// `requirement_updates` (refinements in place) and new `requirements` (at most 3) of an AI answer,
    /// linked to the questions (`sources`) and decisions they come from. Returns the requirement ids touched.
    private func applyRequirementChanges(_ object: [String: Any], in slug: String, sources: [String], decisions: [String]) -> [String] {
        var produced: [String] = []
        // Refinements of existing requirements, in place.
        for update in object["requirement_updates"] as? [[String: Any]] ?? [] {
            guard let rid = update["id"] as? String, let existing = store.feature(slug)?.object(rid), existing.kind == .requirement,
                  existing.status != "superseded" else { continue }
            let statement = update["statement"] as? String ?? ""
            let criteria = (update["acceptance_criteria"] as? [String] ?? []).map { "- [ ] \($0)" }.joined(separator: "\n")
            store.update(rid, in: slug) { front, body in
                if !statement.isEmpty || !criteria.isEmpty {
                    body = "## Statement\n\n\(statement.isEmpty ? existing.section("Statement") : statement)\n\n## Acceptance Criteria\n\n\(criteria.isEmpty ? existing.section("Acceptance Criteria") : criteria)\n"
                }
                front.set("sources", list: Array(Set(front.strings("sources") + sources)).sorted())
                if !decisions.isEmpty { front.set("decisions", list: Array(Set(front.strings("decisions") + decisions)).sorted()) }
            }
            produced.append(rid)
        }
        let origin = decisions.first ?? sources.first ?? "discussion"
        for r in (object["requirements"] as? [[String: Any]] ?? []).prefix(3) {
            if let req = makeRequirement(r, in: slug, sources: Array(Set(sources + decisions)).sorted(), decisions: decisions,
                                         provenance: "Derived from \(origin)") {
                produced.append(req.id)
            }
        }
        return produced
    }

    /// "Decide the rest and finish": the AI makes the remaining product-owner decisions itself (as
    /// proposed decisions), answers or defers the open discovery questions, and every dimension ends
    /// known or n/a — discovery is over.
    func decideRest(_ slug: String) async {
        let key = "decide:" + slug
        preparing.insert(key)
        defer { preparing.remove(key) }
        guard let feature = store.feature(slug) else { return }
        let open = feature.list(.question).filter { $0.status == "open" }
        let openList = open.map { q -> String in
            let options = (q.front["options"]?.list ?? []).map { "  - \($0["label"]?.string ?? ""): \($0["text"]?.string ?? "")" }
            return "- \(q.id) [\(q.front.string("dimension"))] \(q.title)" + (options.isEmpty ? "" : "\n" + options.joined(separator: "\n"))
        }.joined(separator: "\n")
        let prompt = context(feature) + """

        ## Dimensions still open
        \(feature.openDimensions.joined(separator: ", "))

        ## Open questions
        \(openList.isEmpty ? "(none)" : openList)

        Task: the product owner asked you to stop asking questions and decide the rest yourself. Make the \
        remaining decisions an experienced product owner would make for this feature, staying inside its \
        scope — one decision per real choice, as few as needed (at most 8), each with the alternatives and \
        the reason. For each decision list the open questions it answers (`answers`: their ids), UPDATE the \
        existing requirements it refines (requirement_updates) and add new requirements (0–2) only for what \
        no requirement covers. Implementation details stay with the implementer. Finally give every \
        understanding dimension its state — known or n/a — with a short note.
        """
        var itemProperties = Self.decisionSchema["properties"] as? [String: Any] ?? [:]
        itemProperties["answers"] = Self.strings
        itemProperties["requirements"] = Self.array(Self.requirementSchema)
        itemProperties["requirement_updates"] = Self.array(Self.object(["id": Self.string, "statement": Self.string,
                                                                        "acceptance_criteria": Self.strings]))
        let schema = Self.object(["decisions": Self.array(Self.object(itemProperties)), "understanding": Self.understandingSchema])
        guard let object = await structured(key, prompt: prompt, schema: schema, timeout: 900) else { return }
        let openIDs = Set(open.map(\.id))
        var answered: Set<String> = []
        var made: [String] = []
        for item in (object["decisions"] as? [[String: Any]] ?? []).prefix(8) {
            let answers = (item["answers"] as? [String] ?? []).filter { openIDs.contains($0) && !answered.contains($0) }
            guard let decision = makeDecision(item, in: slug, status: "proposed", sources: answers,
                                              provenance: "Decided by AI (discovery finished)") else { continue }
            let produced = applyRequirementChanges(item, in: slug, sources: answers, decisions: [decision.id])
            store.update(decision.id, in: slug) { front, _ in front.set("produces", list: produced) }
            for qid in answers {
                store.update(qid, in: slug) { front, body in
                    front.set("status", "answered")
                    front.set("answer", "AI: " + decision.title)
                    front.set("answered_by", "ai")
                    front.set("resolved_by", decision.id)
                    body += "\n## Answer\n\nDecided by AI — see \(decision.id): \(decision.title)\n"
                }
                answered.insert(qid)
            }
            made.append("\(decision.id): \(decision.title)")
        }
        // Open questions no decision answered are not needed any more.
        for question in open where !answered.contains(question.id) { store.setStatus(question.id, in: slug, to: "deferred") }
        applyUnderstanding(object, to: slug)
        // The user ended discovery: nothing stays open, whatever the assessment said.
        if let current = store.feature(slug), !current.openDimensions.isEmpty {
            store.setUnderstanding(slug, Dictionary(uniqueKeysWithValues: current.openDimensions.map { ($0, "known") }))
        }
        store.updateFeature(slug) { front, _ in front.set("questions_left", "0") }
        store.finishExplore(slug)
        let summary = made.isEmpty ? "No further decisions were needed." : made.map { "• " + $0 }.joined(separator: "\n")
        store.appendDiscussion(slug, speaker: "AI decided the rest", text: summary)
        results.insert(FeatureResult(title: "Discovery finished — AI decided \(made.count)",
                                     text: summary + "\n\nThese decisions are proposed: accept or change them in Review.",
                                     pending: false, feature: slug), at: 0)
    }

    /// Merge overlapping requirements into a small set (spec grew too large). The merged ones stay
    /// as files with status "superseded" and a link to the requirement that replaces them.
    func consolidateRequirements(_ slug: String) async {
        preparing.insert("consolidate:" + slug)
        defer { preparing.remove("consolidate:" + slug) }
        guard let feature = store.feature(slug) else { return }
        let active = feature.activeRequirements
        guard active.count > 3 else { return }
        let target = max(8, min(30, active.count / 5))
        var list = ""
        for r in active {
            let criteria = r.acceptanceCriteria.prefix(6).map { "  - \($0.text)" }.joined(separator: "\n")
            list += "### \(r.id) [\(r.status)] \(r.title)\n\(r.section("Statement").prefix(500))\n\(criteria)\n\n"
        }
        let prompt = """
        # Feature: \(feature.title)

        \(feature.overviewBody.prefix(4_000))

        ## Its \(active.count) requirements

        \(list.prefix(180_000))

        Task: the specification has grown far too large and repetitive. Rewrite it as at most \(target) \
        requirements that together keep every real, in-scope need: merge duplicates, refinements and \
        splits of the same need into one requirement with complete acceptance criteria; drop what is an \
        implementation detail or out of the feature's scope. For every new requirement list the ids it \
        replaces (merges). Every old id should appear in exactly one merges list, or in dropped.
        """
        let item = Self.object(["title": Self.string, "statement": Self.string,
                                "req_type": ["type": "string", "enum": FeatureVocabulary.requirementTypes],
                                "acceptance_criteria": Self.strings, "merges": Self.strings])
        let schema = Self.object(["requirements": Self.array(item), "dropped": Self.strings])
        guard let result = await run("consolidate:" + slug, prompt: prompt, schema: schema, timeout: 1200),
              let object = result.structured as? [String: Any] else { return }
        let activeIDs = Set(active.map(\.id))
        var replacedBy: [String: String] = [:]
        var created = 0
        for r in object["requirements"] as? [[String: Any]] ?? [] {
            let merges = (r["merges"] as? [String] ?? []).filter(activeIDs.contains)
            let decisions = Array(Set(merges.flatMap { feature.object($0)?.front.strings("decisions") ?? [] })).sorted()
            guard let new = makeRequirement(r, in: slug, sources: merges, decisions: decisions,
                                            provenance: "Consolidated from \(merges.count) requirements") else { continue }
            created += 1
            for old in merges { replacedBy[old] = new.id }
        }
        let dropped = (object["dropped"] as? [String] ?? []).filter { activeIDs.contains($0) && replacedBy[$0] == nil }
        store.updateMany(Array(replacedBy.keys) + dropped, in: slug) { id, front, _ in
            if let by = replacedBy[id] {
                front.set("status", "superseded")
                front.set("superseded_by", by)
            } else {
                front.set("status", "rejected")
                front.set("rejected_reason", "Dropped in consolidation (detail or out of scope)")
            }
        }
        results.insert(FeatureResult(title: "Requirements consolidated",
                                     text: "\(active.count) → \(created) requirements; \(replacedBy.count) merged, \(dropped.count) dropped. The old files stay (status superseded / rejected) for history.",
                                     pending: false, feature: slug), at: 0)
    }

    func skip(_ slug: String, question id: String) async {
        store.setStatus(id, in: slug, to: "deferred")
        await exploreNext(slug)
    }

    /// "Suggest another approach": more options for a question.
    func moreOptions(_ slug: String, question id: String) async {
        preparing.insert("options:" + id)
        defer { preparing.remove("options:" + id) }
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
        preparing.insert("pros:" + id)
        defer { preparing.remove("pros:" + id) }
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
        preparing.insert("research:" + slug)
        defer { preparing.remove("research:" + slug) }
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
        // Reviewing the whole specification after discovery leaves Explore.
        if focus == nil, store.feature(slug)?.discoveryDone == true { store.finishExplore(slug) }
        // Decisions not yet in the requirements are written there first: the review reads one
        // consistent specification instead of reporting each requirement against its decisions.
        await applyDecisions(slug)
        guard let feature = store.feature(slug) else { return }
        let scope = focus.map { "Review only \($0) and what it depends on." } ?? "Review the whole specification."
        let prompt = context(feature, focus: focus.map { [$0] } ?? feature.activeRequirements.map(\.id), budget: 70_000) + """

        Task: \(scope) Judge whether it is complete, consistent, understandable and implementation-ready. \
        Look through these perspectives internally — Product, UX, Architecture, Backend, Frontend, Security, \
        QA, Reliability, Operations, Data, Privacy, Business — but report unified findings. For each: a short \
        title, category, severity (blocker = cannot implement without resolving; high; medium; low), the \
        perspectives, the exact quote it is about and the object id or document path it is in, what is wrong, \
        and for ambiguities the possible interpretations. Check the project's other documentation for \
        contradictions and related material. Only real problems; no style remarks.

        Already settled — never report again, not even reworded or from another perspective: anything a \
        closed finding covers (resolved, risk accepted or dismissed; its settlement is given above), an \
        answered question, or a decision. Proposed decisions count as made: the team confirms them. The \
        status of requirements and decisions (draft, approved, proposed), sign-offs, and how records link \
        to each other (ids, `decisions` lists) are bookkeeping the app keeps — never a finding. Report only what blocks implementation or what the \
        product owner would decide differently from a competent implementer: details the implementer settles \
        while building — exact numbers, tolerances, limits, timeouts, test fixtures, wording, finer \
        permission or edge cases that follow from the stated rules — are not findings. Each decision adds \
        detail; do not answer it with requests for still more detail. A settled point is a problem again \
        only when the current text contradicts its settlement. Report only problems that are new. When the \
        specification is implementation-ready, return an empty list — that is the expected outcome of a \
        later review.
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
        // Settled findings too: a problem closed once is not opened again under the same title.
        var known = Set(store.feature(slug)?.list(.finding).map { $0.title.lowercased() } ?? [])
        var created = 0
        for f in findings {
            let title = f["title"] as? String ?? "Finding"
            guard known.insert(title.lowercased()).inserted else { continue }
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
            created += 1
        }
        if focus == nil {
            results.insert(FeatureResult(title: created == 0 ? "Review: nothing new" : "Review: \(created) new finding" + (created == 1 ? "" : "s"),
                                         text: created == 0 ? "No new problems. Confirm the AI's decisions under Before Build, then go to Build."
                                             : "Resolve them below; resolutions are written into the requirements, and the next review does not raise them again.",
                                         pending: false, feature: slug), at: 0)
        }
        if let feature = store.feature(slug), ["exploring", "draft", "idea"].contains(feature.status) {
            store.updateFeature(slug) { front, _ in front.set("status", "review") }
        }
    }

    /// Acceptance criteria for a requirement that has none (or more of them).
    func acceptanceCriteria(_ slug: String, requirement id: String) async {
        preparing.insert("criteria:" + id)
        defer { preparing.remove("criteria:" + id) }
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
        preparing.insert("resolveopts:" + id)
        defer { preparing.remove("resolveopts:" + id) }
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
    /// linked to the finding and the requirements it is about. `delegated`: "Decide for me" — the AI
    /// chooses the resolution itself and the decision is recorded as proposed.
    func resolve(_ slug: String, finding id: String, with choice: String, delegated: Bool = false) async {
        preparing.insert("resolve:" + id)
        defer { preparing.remove("resolve:" + id) }
        guard let feature = store.feature(slug), let finding = feature.object(id) else { return }
        let options = (finding.front["options"]?.list ?? []).compactMap { $0["text"]?.string }
        let task = delegated ? """
        \(id): \(finding.title)
        \(finding.front.string("resolution_question"))
        \(options.isEmpty ? "" : "Ways proposed so far: " + options.joined(separator: " | "))

        Task: the team asked you to decide this yourself. Choose the best resolution for this feature as \
        an experienced product owner would — one of the proposed ways or a better one — and state it in \
        `chosen` (one or two sentences). \(Self.findingDecisionRule)
        """ : """
        \(id): \(finding.title)
        The team chose: \(choice)
        Other options were: \(options.filter { $0 != choice }.joined(separator: " | "))

        Task: record this as a decision (context, alternatives, decision, reason, consequences).
        """
        var properties: [String: Any] = ["decision": Self.decisionSchema]
        if delegated {
            properties["chosen"] = Self.string
            properties["needs_decision"] = ["type": "boolean"]
        }
        guard let object = await structured("resolve:" + id, prompt: context(feature, focus: [id]) + "\n" + task,
                                            schema: Self.object(properties)) else { return }
        let decision = delegated && object["needs_decision"] as? Bool == false ? nil : object["decision"] as? [String: Any]
        closeFinding(finding, in: slug, decision: decision, choice: delegated ? "AI: " + (object["chosen"] as? String ?? "") : choice,
                     delegated: delegated)
        await applyDecisions(slug)
    }

    /// When an AI resolution of a finding is worth a decision file, and when the finding is
    /// simply closed with its resolution text.
    private static let findingDecisionRule = """
    Record it as a decision (context, alternatives, decision, reason, consequences; needs_decision true) only \
    when the resolution is a product choice the specification must remember. A finding settled by an \
    implementation detail the implementer decides anyway, a wording fix, or something an existing \
    requirement or decision already covers is closed with its resolution text alone (needs_decision false). \
    Settle the finding with the least new detail that resolves it: no new rules, numbers or cases beyond \
    what it asks; what the implementer decides while building stays with the implementer.
    """

    /// "Decide all for me": the AI resolves every open finding itself, a few per call; the decisions
    /// are proposed. `decideProgress` tells the view how far it got.
    func decideAllFindings(_ slug: String) async {
        let key = "decideall:" + slug
        preparing.insert(key)
        defer { preparing.remove(key); decideProgress[slug] = nil }
        guard let feature = store.feature(slug) else { return }
        let open = feature.list(.finding).filter { !$0.isClosed }
        var done = 0
        decideProgress[slug] = (0, open.count)
        let item = Self.object(["id": Self.string, "chosen": Self.string, "needs_decision": ["type": "boolean"],
                                "decision": Self.decisionSchema])
        for start in stride(from: 0, to: open.count, by: 8) {
            guard let current = store.feature(slug) else { return }
            // Findings closed meanwhile (by hand or another action) are skipped.
            let chunk = open[start..<min(start + 8, open.count)].compactMap { current.object($0.id) }.filter { !$0.isClosed }
            guard !chunk.isEmpty else { continue }
            let list = chunk.map { f -> String in
                let options = (f.front["options"]?.list ?? []).compactMap { $0["text"]?.string }
                return "### \(f.id) [\(f.front.string("severity"))] \(f.title)\n\(f.section("Finding").prefix(1_200))"
                    + (f.front.string("resolution_question").isEmpty ? "" : "\nQuestion: " + f.front.string("resolution_question"))
                    + (options.isEmpty ? "" : "\nWays proposed: " + options.joined(separator: " | "))
            }.joined(separator: "\n\n")
            let prompt = context(current, focus: chunk.map(\.id)) + """

            ## Findings to resolve
            \(list)

            Task: the team asked you to resolve these findings yourself. For each one choose the best \
            resolution for this feature as an experienced product owner would — a proposed way or a better \
            one, consistent with the other resolutions — and state it in `chosen` (one or two sentences). \
            \(Self.findingDecisionRule) One entry per finding, with its id.
            """
            if let object = await structured(key, prompt: prompt, schema: Self.object(["resolutions": Self.array(item)]), timeout: 900) {
                for entry in object["resolutions"] as? [[String: Any]] ?? [] {
                    guard let fid = entry["id"] as? String, let finding = chunk.first(where: { $0.id == fid }) else { continue }
                    let decision = entry["needs_decision"] as? Bool == false ? nil : entry["decision"] as? [String: Any]
                    closeFinding(finding, in: slug, decision: decision, choice: "AI: " + (entry["chosen"] as? String ?? ""), delegated: true)
                }
            } else {
                return
            }
            done += chunk.count
            decideProgress[slug] = (min(done, open.count), open.count)
        }
        await applyDecisions(slug)
        results.insert(FeatureResult(title: "AI resolved \(done) findings",
                                     text: "Their decisions are proposed and already written into the requirements: accept or reject them under Before Build.",
                                     pending: false, feature: slug), at: 0)
    }

    /// "Find outdated": decisions and open findings written against an older specification (before a
    /// consolidation) that no longer apply are marked — decisions superseded, findings dismissed — so
    /// the cleanup can remove them. Returns (decisions, findings) marked, nil when it failed.
    @discardableResult
    func markOutdated(_ slug: String) async -> (decisions: Int, findings: Int)? {
        let key = "outdated:" + slug
        preparing.insert(key)
        defer { preparing.remove(key) }
        guard let feature = store.feature(slug) else { return nil }
        let decisions = feature.list(.decision).filter { $0.status == "accepted" || $0.status == "proposed" }
        let findings = feature.list(.finding).filter { !$0.isClosed }
        guard !decisions.isEmpty || !findings.isEmpty else { return (0, 0) }
        let requirements = feature.activeRequirements.map { r in
            "### \(r.id) \(r.title)\n\(r.section("Statement").prefix(800))\n"
                + r.acceptanceCriteria.prefix(8).map { "- \($0.text)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let decisionList = decisions.map { "- \($0.id) [\($0.status)] \($0.title): \($0.section("Decision").prefix(300))" }.joined(separator: "\n")
        let findingList = findings.map { "- \($0.id) refs \($0.front.strings("refs").joined(separator: ",")): \($0.title). \($0.section("Finding").prefix(300))" }.joined(separator: "\n")
        let prompt = """
        # Feature: \(feature.title)

        \(feature.overviewBody.prefix(3_000))

        ## Current requirements
        \(requirements.prefix(60_000))

        ## Decisions
        \(decisionList.prefix(60_000))

        ## Open review findings
        \(findingList.prefix(40_000))

        Task: the specification was consolidated, so many decisions and findings were written against \
        older requirements. List the decisions that no longer apply to the current specification — \
        replaced by a later decision (give its id in replaced_by), about scope that was removed, or \
        contradicted by the current requirements — and the open findings that no longer apply — already \
        settled by the current requirement text, or about content that is gone. Give a short reason for \
        each. Keep everything that still matters to the current specification; when in doubt, keep it.
        """
        let decisionItem = Self.object(["id": Self.string, "reason": Self.string, "replaced_by": Self.string])
        let findingItem = Self.object(["id": Self.string, "reason": Self.string])
        let schema = Self.object(["decisions": Self.array(decisionItem), "findings": Self.array(findingItem)])
        guard let object = await structured(key, prompt: prompt, schema: schema, timeout: 1200) else { return nil }
        let decisionIDs = Set(decisions.map(\.id))
        let findingIDs = Set(findings.map(\.id))
        var outdatedDecisions: [String: (reason: String, by: String)] = [:]
        for item in object["decisions"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, decisionIDs.contains(id) else { continue }
            outdatedDecisions[id] = (item["reason"] as? String ?? "", item["replaced_by"] as? String ?? "")
        }
        var outdatedFindings: [String: String] = [:]
        for item in object["findings"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String, findingIDs.contains(id) else { continue }
            outdatedFindings[id] = item["reason"] as? String ?? ""
        }
        store.updateMany(Array(outdatedDecisions.keys) + Array(outdatedFindings.keys), in: slug) { id, front, _ in
            if let entry = outdatedDecisions[id] {
                front.set("status", "superseded")
                // Only a decision that stays can replace this one.
                if decisionIDs.contains(entry.by), outdatedDecisions[entry.by] == nil, entry.by != id { front.set("superseded_by", entry.by) }
                front.set("outdated_reason", entry.reason)
            } else if let reason = outdatedFindings[id] {
                front.set("status", "dismissed")
                front.set("dismissed_reason", reason)
            }
        }
        return (outdatedDecisions.count, outdatedFindings.count)
    }

    /// A finding resolved: closed with its resolution and, when the resolution is a product choice
    /// (`d` given), the decision that records it, linked to the finding's requirements.
    private func closeFinding(_ finding: FeatureObject, in slug: String, decision d: [String: Any]?, choice: String, delegated: Bool) {
        let id = finding.id
        let decision = d.flatMap {
            makeDecision($0, in: slug, status: delegated ? "proposed" : "accepted", sources: [id],
                         provenance: delegated ? "Chosen by AI (\(id))" : "Resolved \(id)")
        }
        if d != nil, decision == nil { return }
        store.update(id, in: slug) { front, body in
            front.set("status", "resolved")
            if let decision { front.set("resolved_by", decision.id) }
            if delegated { front.set("answered_by", "ai") }
            body += "\n## Resolution\n\n\(choice)" + (decision.map { " — see \($0.id)." } ?? "") + "\n"
        }
        guard let decision else { return }
        for target in finding.front.strings("refs") where FeatureObjectKind.of(id: target) == .requirement {
            store.update(target, in: slug) { front, _ in
                front.set("decisions", list: Array(Set(front.strings("decisions") + [decision.id])).sorted())
            }
        }
    }

    /// Write what was settled and not yet applied (`Feature.settlementsToApply`: decisions, and
    /// findings resolved by their text alone) into the requirements it changes, so the
    /// specification states what was decided (BUG-023). Without this, a resolved finding leaves
    /// the requirement text as it was, and the next review reports the requirement contradicting
    /// the resolution — every resolution produced the next finding.
    /// Two steps: one call maps each settlement to the requirements it changes, then each of those
    /// requirements is rewritten on its own (one requirement with its settlements in one call misses
    /// less than the whole specification at once). The settlements are marked `applied` once every
    /// rewrite is written; a failed call leaves them pending for the next resolution or review.
    /// One apply at a time per feature: a caller waits for a running one and then applies what is
    /// still pending, so a review never reads requirements half-way through being rewritten (BUG-024:
    /// a review started during the apply of a resolution reported the old text).
    func applyDecisions(_ slug: String) async {
        while let running = applying[slug] { await running.value }
        let task = Task {
            await self.applyPending(slug)
            self.applying[slug] = nil
        }
        applying[slug] = task
        await task.value
    }

    private func applyPending(_ slug: String) async {
        let key = "apply:" + slug
        guard let feature = store.feature(slug) else { return }
        let decisions = feature.settlementsToApply
        guard !decisions.isEmpty else { return }
        preparing.insert(key)
        defer { preparing.remove(key) }
        let requirements = feature.activeRequirements
        guard let targets = await decisionTargets(feature, decisions: decisions, requirements: requirements) else { return }
        var rewritten: [String] = []
        var failed = false
        // A few requirements at a time: each is one assistant process.
        let work = requirements.filter { targets[$0.id] != nil }
        for start in stride(from: 0, to: work.count, by: 4) {
            let batch = Array(work[start..<min(start + 4, work.count)])
            let outcomes = await withTaskGroup(of: (String, Bool).self) { group in
                for requirement in batch {
                    let ids = targets[requirement.id] ?? []
                    group.addTask { @MainActor in
                        (requirement.id, await self.rewriteRequirement(requirement, with: decisions.filter { ids.contains($0.id) }, in: feature))
                    }
                }
                var out: [(String, Bool)] = []
                for await outcome in group { out.append(outcome) }
                return out
            }
            for (id, ok) in outcomes { if ok { rewritten.append(id) } else { failed = true } }
        }
        if let ids = targets[Self.overviewTarget] {
            if let edits = await rewriteOverview(feature, with: decisions.filter { ids.contains($0.id) }) {
                if edits > 0 { rewritten.append("the overview") }
            } else {
                failed = true
            }
        }
        guard !failed else { return }
        markApplied(decisions, in: slug)
        if !rewritten.isEmpty {
            store.appendDiscussion(slug, speaker: "AI updated the requirements",
                                   text: "\(decisions.map(\.id).joined(separator: ", ")) written into "
                                       + rewritten.sorted().joined(separator: ", ") + ".")
        }
    }

    private func markApplied(_ decisions: [FeatureObject], in slug: String) {
        store.updateMany(decisions.map(\.id), in: slug) { _, front, _ in front.set("applied", FeatureStore.today) }
    }

    /// Which requirements each pending settlement changes: requirement id → settlement ids. Nil when
    /// the call failed.
    private func decisionTargets(_ feature: Feature, decisions: [FeatureObject],
                                 requirements: [FeatureObject]) async -> [String: [String]]? {
        let requirementList = requirements.map { r in
            "### \(r.id) \(r.title)\n\(r.section("Statement").prefix(1_500))\n"
                + r.acceptanceCriteria.map { "- \($0.text)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let prompt = """
        # Feature: \(feature.title)

        ## \(Self.overviewTarget) (the feature overview)
        \(feature.overviewBody.prefix(12_000))

        ## Requirements
        \(requirementList.prefix(90_000))

        ## Settled after the requirements were written
        \(Self.settlementList(decisions).prefix(50_000))

        Task: for every settlement (decision or finding resolution), list the requirements whose statement \
        or acceptance criteria it changes, extends, narrows or contradicts — wherever the requirement text \
        does not already say what the settlement says — and \(Self.overviewTarget) when the overview states \
        something it changes (e.g. lists as open what is now decided). Be thorough: one may touch several; \
        one about an implementation detail no requirement states touches none. `id`: the settlement's id.
        """
        let item = Self.object(["id": Self.string, "requirements": Self.strings])
        guard let object = await structured("apply:" + feature.slug, prompt: prompt,
                                            schema: Self.object(["changes": Self.array(item)]), timeout: 600) else { return nil }
        let requirementIDs = Set(requirements.map(\.id) + [Self.overviewTarget])
        let decisionIDs = Set(decisions.map(\.id))
        var targets: [String: [String]] = [:]
        for entry in object["changes"] as? [[String: Any]] ?? [] {
            guard let decision = entry["id"] as? String, decisionIDs.contains(decision) else { continue }
            for id in (entry["requirements"] as? [String] ?? []) where requirementIDs.contains(id) {
                targets[id, default: []].append(decision)
            }
        }
        return targets
    }

    /// Rewrite one requirement so it states what `decisions` (decisions and finding resolutions)
    /// settled. False when the call failed.
    private func rewriteRequirement(_ requirement: FeatureObject, with decisions: [FeatureObject], in feature: Feature) async -> Bool {
        let prompt = """
        # Feature: \(feature.title)

        \(feature.overviewBody.prefix(3_000))

        ## Requirement \(requirement.id): \(requirement.title)

        \(requirement.body.prefix(12_000))

        ## Settled — write into it (oldest first)
        \(Self.settlementList(decisions).prefix(40_000))

        Task: rewrite \(requirement.id) so that its statement and acceptance criteria state everything settled \
        above for it — every rule, number, limit, owner and exception — and nothing in it contradicts it any \
        more. What was settled overrides the current requirement text, and a later settlement overrides an \
        earlier one where they disagree. Keep everything else in the requirement as \
        it is, in its language. Acceptance criteria: complete, testable, one per line.
        """
        let schema = Self.object(["statement": Self.string, "acceptance_criteria": Self.strings])
        guard let object = await structured("apply:" + requirement.id, prompt: prompt, schema: schema, effort: "medium", timeout: 600),
              let statement = object["statement"] as? String,
              !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let criteria = object["acceptance_criteria"] as? [String] ?? []
        // Links to decisions that no longer exist (deleted by hand) are dropped on the way.
        let known = Set(store.feature(feature.slug)?.list(.decision).map(\.id) ?? [])
        store.update(requirement.id, in: feature.slug) { front, body in
            // A criterion already checked off stays checked when its text is kept.
            let done = Set(FeatureObject.acceptanceCriteria(in: body).filter(\.done).map { $0.text.lowercased() })
            body = FeatureObject.replacingSection("Statement", in: body, with: statement)
            if !criteria.isEmpty {
                let lines = criteria.map { "- [\(done.contains($0.lowercased()) ? "x" : " ")] \($0)" }
                body = FeatureObject.replacingSection("Acceptance Criteria", in: body, with: lines.joined(separator: "\n"))
            }
            let ids = decisions.filter { $0.kind == .decision }.map(\.id)
            front.set("decisions", list: Array(Set(front.strings("decisions") + ids)).filter(known.contains).sorted())
        }
        return true
    }

    /// The routing id that stands for the feature overview.
    private static let overviewTarget = "OVERVIEW"

    /// Bring the overview in line with what was settled, by exact passage edits so the author's
    /// text stays as it is everywhere else. Returns the number of edits made; nil when the call failed.
    private func rewriteOverview(_ feature: Feature, with settlements: [FeatureObject]) async -> Int? {
        let prompt = """
        # Feature overview: \(feature.title)

        \(feature.overviewBody.prefix(30_000))

        ## Settled — the overview must not contradict it (oldest first)
        \(Self.settlementList(settlements).prefix(30_000))

        Task: the overview is the author's brief. Change only the passages that contradict what was \
        settled or present as open what is now decided; leave everything else exactly as it is, in its \
        language. Return edits: `find` is a passage copied verbatim from the overview (unique, long enough \
        to occur once), `replace` its new text. No edits when nothing contradicts.
        """
        let edit = Self.object(["find": Self.string, "replace": Self.string])
        guard let object = await structured("apply:overview:" + feature.slug, prompt: prompt,
                                            schema: Self.object(["edits": Self.array(edit)]), effort: "medium", timeout: 600)
        else { return nil }
        let edits = (object["edits"] as? [[String: Any]] ?? []).compactMap { e -> (find: String, replace: String)? in
            guard let find = e["find"] as? String, let replace = e["replace"] as? String else { return nil }
            return (find, replace)
        }
        guard !edits.isEmpty else { return 0 }
        var applied = 0
        store.updateFeature(feature.slug) { _, body in
            let result = FeatureObject.applyingEdits(edits, to: body)
            body = result.text
            applied = result.applied
        }
        return applied
    }

    /// Settlements as the apply prompts list them, oldest first (by creation date, then id).
    private static func settlementList(_ items: [FeatureObject]) -> String {
        items.sorted { ($0.front.string("created"), $0.id) < ($1.front.string("created"), $1.id) }.map { item in
            if item.kind == .finding {
                return "### \(item.id) resolution of finding: \(item.title)\n\(item.section("Resolution").prefix(1_500))"
            }
            return "### \(item.id) [\(item.status)] \(item.title)\n"
                + "Decision: \(item.section("Decision").prefix(1_500))\nConsequences: \(item.section("Consequences").prefix(800))"
        }.joined(separator: "\n\n")
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
            let result = await run("action:\(action.rawValue):" + resultID.uuidString, prompt: prompt, schema: nil, onDelta: { text in
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
        preparing.insert("chat:" + slug)
        defer { preparing.remove("chat:" + slug) }
        guard let feature = store.feature(slug) else { return }
        store.appendDiscussion(slug, speaker: store.defaultOwner.isEmpty ? "User" : store.defaultOwner, text: message)
        var item = FeatureResult(title: "Discussion", text: "", pending: true, feature: slug)
        results.insert(item, at: 0)
        let prompt = context(feature, query: message) + """

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
        preparing.insert("decompose:" + slug)
        defer { preparing.remove("decompose:" + slug) }
        guard let feature = store.feature(slug) else { return }
        let approved = feature.activeRequirements.filter { $0.status == "approved" }
        let pool = approved.isEmpty ? feature.activeRequirements : approved
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
            store.markImplementing(slug)
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
