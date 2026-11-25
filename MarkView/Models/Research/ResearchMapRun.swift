import Foundation

/// The AI side of research maps (DEC-008): the prompts, the parser of the node lines the agent writes
/// while it works, and the guards that decide which nodes enter the map. The limits are enforced here,
/// in code, so the result does not depend on which model the person configured. Pure (Foundation and
/// ResearchMapDocument), so `tools/tests` can compile it alone.
enum ResearchMapPrompt {
    static func system(web: Bool, webRules: String, languageLine: String, singleNode: Bool = false) -> String {
        """
        You are a research analyst working inside a software repository, which may hold code, \
        documentation or both. You research an open question and build the answer as a mind map, \
        from the inside out: first the central subject, then the main branches, then finer topics. \
        Explore the repository with your file search and read tools; never assume what a file says \
        without reading it.

        Every finding you attach to a node starts with exactly one of these labels:
        - Project fact: something you read in a repository file. The source is its workspace-relative \
        path, with a line when useful, e.g. src/app/main.swift:42.
        - External fact: something from a web page or search result you actually opened. The source is \
        its URL.
        - AI inference: your own conclusion or general knowledge without a source you opened. \
        Knowledge from training is an inference, never an external fact.
        - Open assumption: a premise that is not verified and matters for the answer.

        \(web ? webRules : "Web search is not available for this research. Rely on the repository; label general knowledge as AI inference.")

        \(singleNode ? updateFormat : nodeFormat)

        \(languageLine)
        """
    }

    /// How the agent writes a map: one NODE line per node.
    private static let nodeFormat = """
        You write the map as lines, one node per line. A node line is the word NODE, one space, and a \
        JSON object on that same line (no line breaks inside the object, no code fence, no list marker):
        NODE {"ref":"short-label","parent":"root","title":"...","description":"...","tags":["..."],"number":1,"evidence":[{"label":"Project fact","text":"...","source":"path/file.ext:42"}]}
        - ref: a short label, unique in your answer. Later nodes name it as their parent.
        - parent: "root" (see the task for what that is), the ref of a node you wrote earlier, or the id \
        of an existing node when the task lists ids.
        - title: at most 8 words; a topic, not a sentence.
        - description: Markdown, one to four sentences or a short bullet list; what matters about the topic.
        - tags: zero to four short tags.
        - number: leave it out, unless the order of sibling nodes matters (steps, phases, a ranking); then \
        number those siblings 1, 2, 3 in that order. It is shown as a badge before the title.
        - evidence: the findings behind the description, each with label (exactly one of the four above), \
        text and source (empty for AI inference and Open assumption).
        Write each node as soon as you know it, not at the end. Anything you write that is not a node \
        line is ignored, so think aloud if you need to. Never modify files.
        """

    /// How the agent answers a task on one existing node (Expand description, Correct, Research): one UPDATE line.
    private static let updateFormat = """
        You change exactly one existing node of the map; you add no nodes. Answer with one line: the word UPDATE, \
        one space and a JSON object on that same line (no line breaks inside the object, no code fence, no list marker):
        UPDATE {"title":"...","description":"...","evidence":[{"label":"Project fact","text":"...","source":"path/file.ext:42"}]}
        - Write only the keys the task asks for; leave out the others.
        - description: Markdown, the whole new text of the node's description.
        - evidence: findings, each with label (exactly one of the four above), text and source (empty for AI \
        inference and Open assumption).
        Anything you write that is not the UPDATE line is ignored, so think aloud first if you need to, and write the \
        UPDATE line last. Never modify files and never write NODE or ROOT lines.
        """

    /// The task of a new research. `scope` is the analysis scope text (ResearchPrompt.scopeText).
    static func research(question: String, targets: [String], attachments: [String], scope: String, limits: ResearchMapRun.Limits) -> String {
        var prompt = "Research question:\n\n\(question)\n\n"
        if !targets.isEmpty {
            prompt += "Target documents (the primary focus; read them in full first, never modify them):\n"
                + targets.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !attachments.isEmpty {
            prompt += "Attachments provided by the user (read them):\n" + attachments.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        prompt += """
            Build the map from the inside out.
            1. First write one line ROOT {"title":"...","description":"...","tags":[],"evidence":[]} for the central \
            subject: what the research is about (title at most 8 words, never a copy of the question) and, in the \
            description, the answer in a nutshell.
            2. Then the main branches: 3 to 6 NODE lines with "parent":"root".
            3. Then, branch by branch, their topics (2 to 5 under each branch, parent = the branch's ref) and, where it \
            matters, one more level of detail. At most \(limits.depth) levels below the root, at most \(limits.children) \
            children under a node and \(limits.nodes) nodes in total.
            Write the main branches before any detail, so the person sees the map grow outward from the centre.


            """
        return prompt + scope
    }

    /// The task of developing one node in the direction the person gave.
    static func develop(map: ResearchMap, node: ResearchMap.Node, direction: String, scope: String, limits: ResearchMapRun.Limits) -> String {
        """
        The research map so far (id, title; indentation is depth):

        \(outline(map))

        The node to develop is \(node.id), "\(node.title)".
        \(detail(node))
        \(direction.isEmpty
            ? "The person gave no direction: choose the most useful sub-topics of this node yourself (3 to 6 children), so that the node's topic is covered."
            : "The person asks to develop it in this direction:\n\n\(direction)")

        Add new nodes under this node. Use "parent":"node" for its direct children, or the ref of a node you wrote \
        earlier for a deeper level (at most \(limits.depth) levels below the node, at most \(limits.children) children \
        under a node and \(limits.nodes) nodes in total). If the direction asks for options, alternatives or \
        variants, write each option as its own child node of the node, with its trade-offs in the description. Do not \
        repeat topics the map already has. Research the repository and, if allowed, the web, for the facts behind \
        each node.


        \(scope)
        """
    }

    /// Expand description: the node's description is rewritten and extended; nothing else changes.
    static func describe(map: ResearchMap, node: ResearchMap.Node, scope: String) -> String {
        """
        The research map (id, title; indentation is depth):

        \(outline(map))

        The node to expand is \(node.id), "\(node.title)".
        \(detail(node, descriptionLimit: 4000, findings: 12))
        Expand the description of this node. Keep what is correct and useful, and add what is missing: what the topic \
        is, how it works, why it matters for the research question "\(map.question)", trade-offs and concrete examples. \
        Write about two to four short paragraphs or a compact bullet list in Markdown, not an essay. Research the \
        repository and, if allowed, the web, for the facts behind the additions.

        Write the key "description" (the whole new text, which replaces the old one) and the key "evidence" (only the \
        NEW findings behind your additions; the existing findings stay). Do not write "title".


        \(scope)
        """
    }

    /// Correct: the person says what is wrong; the node is rewritten to fit the facts.
    static func correct(map: ResearchMap, node: ResearchMap.Node, note: String, scope: String) -> String {
        """
        The research map (id, title; indentation is depth):

        \(outline(map))

        The node to correct is \(node.id), "\(node.title)".
        \(detail(node, descriptionLimit: 4000, findings: 12))
        The person says this about the node:

        \(note)

        Check the claim against the repository and, if allowed, the web. Do not take it on faith and do not defend the \
        old text: if the person is right, fix the node; if the facts show otherwise, keep what is true and say in the \
        description why. Keep what is correct. Change only this node.

        Write the keys "title" (only if the title must change), "description" (the whole corrected text) and \
        "evidence" (the complete list of findings that support the corrected node; it replaces the old list, so \
        include the old findings that still hold).


        \(scope)
        """
    }

    /// Research: facts for one node, as evidence; the description and the children stay.
    static func investigate(map: ResearchMap, node: ResearchMap.Node, scope: String) -> String {
        """
        The research map (id, title; indentation is depth):

        \(outline(map))

        The node to research is \(node.id), "\(node.title)".
        \(detail(node, descriptionLimit: 3000, findings: 12))
        Research this node and nothing else: find the facts that confirm, qualify or contradict what it says, in the \
        repository and, if allowed, on the web. Prefer primary sources. Findings that repeat an existing one are of no use.

        Write only the key "evidence": the NEW findings (the existing ones stay). Label a finding that contradicts \
        the node's description as such in its text. Do not write "title" or "description".


        \(scope)
        """
    }

    /// The task of continuing a research that stopped early.
    static func continuation(map: ResearchMap, question: String, scope: String, limits: ResearchMapRun.Limits) -> String {
        let thin = map.nodes.filter { map.children(of: $0.id).isEmpty && map.depth(of: $0.id) < limits.depth }
            .map { "- \($0.id) \"\($0.title)\"" }.joined(separator: "\n")
        return """
            Research question:

            \(question)

            The research stopped before it was finished. This is the map so far (id, title; indentation is depth):

            \(outline(map))

            Continue the research: develop the branches that are missing detail, and add main branches the question needs \
            that the map does not have yet. Nodes that have no children yet:
            \(thin.isEmpty ? "(none)" : thin)

            Use "parent":"root" for a new main branch, the id of an existing node to add under it, or the ref of a node \
            you wrote earlier. At most \(limits.depth) levels below the root, at most \(limits.children) children under a \
            node and \(limits.nodes) new nodes in total. Do not repeat topics the map already has and do not write a ROOT \
            line.


            \(scope)
            """
    }

    /// The outline of the map for a prompt: one line per node, two spaces per level.
    static func outline(_ map: ResearchMap) -> String {
        map.nodes.prefix(200).map { String(repeating: "  ", count: map.depth(of: $0.id)) + "- \($0.id) \($0.title)" }.joined(separator: "\n")
    }

    // MARK: - Evidence-Backed Deep Research Map Prompts (REQ-008, I-5)

    struct InquiryPlan: Decodable, Sendable {
        struct Branch: Decodable, Sendable {
            var ref: String
            var title: String
            var angle: String
            var focus: String
            var needsWeb: Bool
        }
        var rootTitle: String
        var branches: [Branch]
    }

    static var inquiryPlanSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["rootTitle", "branches"],
            "properties": [
                "rootTitle": ["type": "string", "description": "Crisp central map title, at most 8 words, never a verbatim copy of the question."],
                "branches": [
                    "type": "array",
                    "minItems": 2,
                    "maxItems": 3,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["ref", "title", "angle", "focus", "needsWeb"],
                        "properties": [
                            "ref": ["type": "string", "description": "Short unique ASCII slug like arch, risks, alternatives."],
                            "title": ["type": "string", "description": "Branch title, at most 8 words."],
                            "angle": ["type": "string", "description": "One sentence explaining this distinct line of inquiry."],
                            "focus": ["type": "string", "description": "Specific repository files/modules or external topics this inquiry should verify."],
                            "needsWeb": ["type": "boolean", "description": "True only when web search is allowed and this branch requires external facts."],
                        ],
                    ],
                ],
            ],
        ]
    }

    static func inquiryPlanSystem(web: Bool, languageLine: String) -> String {
        """
        You are a research planner working inside a software repository. Decompose the research question into \
        2 to 3 distinct, non-overlapping lines of inquiry that together answer the question thoroughly without \
        duplicating effort. Do a quick, lightweight look at the targets and repository layout — do NOT do deep \
        reading yet (parallel inquiry agents will do the deep investigation next).
        \(web ? "Web search is permitted for branches that genuinely require external facts (set needsWeb: true only for those)." : "Web search is disabled or unavailable: set needsWeb to false for every branch.")
        \(languageLine)
        Never modify files. Answer with the JSON object only.
        """
    }

    static func inquiryPlanPrompt(question: String, targets: [String], attachments: [String], scope: String) -> String {
        var prompt = "Research question:\n\n\(question)\n\n"
        if !targets.isEmpty {
            prompt += "Target documents (primary focus):\n" + targets.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !attachments.isEmpty {
            prompt += "Attachments:\n" + attachments.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        prompt += """
            Produce 2 to 3 complementary, non-overlapping lines of inquiry (e.g., current codebase reality & constraints, \
            implementation/architectural options or root causes, verification/risks/gaps or external comparisons when web is allowed).

            """
        return prompt + scope
    }

    static func inquiryBranch(
        question: String,
        branchID: String,
        branch: InquiryPlan.Branch,
        otherBranches: [String],
        targets: [String],
        attachments: [String],
        scope: String,
        limits: ResearchMapRun.Limits,
        web: Bool
    ) -> String {
        var prompt = """
            Overall research question:
            \(question)

            Your assigned line of inquiry (branch node id: \(branchID), title: "\(branch.title)"):
            Angle: \(branch.angle)
            Focus: \(branch.focus)

            Other lines of inquiry running in parallel (do NOT duplicate them):
            \(otherBranches.isEmpty ? "(none)" : otherBranches.map { "- \($0)" }.joined(separator: "\n"))

            """
        if !targets.isEmpty {
            prompt += "Target documents:\n" + targets.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !attachments.isEmpty {
            prompt += "Attachments:\n" + attachments.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        prompt += """
            Investigate ONLY your assigned line of inquiry deeply using your permitted tools.
            - Focus tightly on your assigned `Focus` files/modules first; stop searching once your angle has direct primary-source evidence (do not crawl unrelated parts of the repository).
            - Read primary files before asserting any Project fact. ALWAYS cite the FULL workspace-relative path and exact line range from the Analysis scope in `source` (e.g. `MarkView/Models/AI/CLICompletion.swift:180-195`, NEVER a bare filename), and keep each evidence item atomic to the cited lines.
            - \(web ? "Use web search only for generic external facts and cite exact opened URLs in `source` for External fact." : "Web search is NOT available for this inquiry: never emit External fact; label general knowledge as AI inference and record missing external data as Open assumption.")
            - Write NODE lines ONLY (never write a ROOT line). Attach your direct findings to "parent":"\(branchID)" (2 to 4 children) and at most 1 deeper level where essential (at most \(limits.nodes) nodes total).
            - Include explicit Open assumption evidence when something important cannot be verified from available sources.

            """
        return prompt + scope
    }

    struct MapSynthesis: Decodable, Sendable {
        struct Connection: Decodable, Sendable {
            var from: String
            var to: String
        }
        var rootDescription: String
        var connections: [Connection]
        var gaps: [String]
        var verdicts: [ResearchClaimVerifier.Verdict]
    }

    static var mapSynthesisSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["rootDescription", "connections", "gaps", "verdicts"],
            "properties": [
                "rootDescription": ["type": "string", "description": "Concise 2-4 sentence Markdown synthesis integrating all lines of inquiry and concrete conclusions, grounded ONLY in supported evidence."],
                "connections": [
                    "type": "array",
                    "maxItems": 6,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["from", "to"],
                        "properties": [
                            "from": ["type": "string"],
                            "to": ["type": "string"],
                        ],
                    ],
                ],
                "gaps": [
                    "type": "array",
                    "maxItems": 4,
                    "items": ["type": "string"],
                    "description": "Concrete Open assumption gap notes for unverified premises, failed branches, or unavailable sources.",
                ],
                "verdicts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "status", "reason"],
                        "properties": [
                            "id": ["type": "string"],
                            "status": ["type": "string", "enum": ["supported", "unsupported"]],
                            "reason": ["type": "string"],
                        ],
                    ],
                ],
            ],
        ]
    }

    static func mapSynthesisPrompt(
        question: String,
        map: ResearchMap,
        checks: [ResearchClaimVerifier.ClaimCheck],
        branchGaps: [String]
    ) -> String {
        let nodeSummaries = map.nodes.dropFirst().prefix(45).map { node in
            let desc = String(node.description.replacingOccurrences(of: "\n", with: " ").prefix(240))
            return "- \(node.id) [parent: \(node.parent)] \(node.title): \(desc)"
        }.joined(separator: "\n")
        let claimsBlock = checks.filter { $0.deterministicFailure == nil }.map { check in
            """
            CLAIM \(check.id) [\(check.label.rawValue)]: \(check.claimText)
            SOURCES: \(check.sources.joined(separator: ", "))
            VERBATIM EXCERPTS:
            \(check.excerpts.isEmpty ? "(no excerpt available)" : check.excerpts)
            """
        }.joined(separator: "\n\n---\n\n")
        let gapsBlock = branchGaps.isEmpty ? "(none)" : branchGaps.map { "- \($0)" }.joined(separator: "\n")
        return """
            Research question:
            \(question)

            Map nodes collected across distinct lines of inquiry:
            \(nodeSummaries)

            Recorded branch / source gaps:
            \(gapsBlock)

            Tasks:
            1. Write `rootDescription`: a concise, evidence-backed synthesis answering the question across all lines of inquiry (relying only on supported claims).
            2. Propose up to 4 meaningful cross-branch `connections` using exact node ids (`n...`) linking related findings across DIFFERENT branches.
            3. Return one strict verdict per CLAIM id below, checking each factual claim strictly against its VERBATIM EXCERPTS.
            4. Add up to 3 concise `gaps` for remaining unverified premises or unavailable sources.

            \(claimsBlock.isEmpty ? "(no factual claims to verify)" : claimsBlock)
            """
    }

    private static func detail(_ node: ResearchMap.Node, descriptionLimit: Int = 1500, findings: Int = 8) -> String {
        var text = ""
        if !node.description.isEmpty { text += "Its description:\n\(String(node.description.prefix(descriptionLimit)))\n" }
        if !node.evidence.isEmpty {
            text += "Its findings:\n" + node.evidence.prefix(findings).map { "- [\($0.label.rawValue)] \(String($0.text.prefix(300)))" }.joined(separator: "\n") + "\n"
        }
        return text
    }
}

/// One AI run over a map: parses the agent's stream line by line and applies the nodes that pass the
/// guards. A value of this type belongs to one run.
struct ResearchMapRun {
    enum Mode: Equatable {
        case research
        /// Expand topic: add children under the node with this id.
        case develop(node: String)
        case continuation
        /// Expand description: rewrite and extend the description of this node (REQ-006).
        case describe(node: String)
        /// Correct: rewrite this node after what the person said is wrong.
        case correct(node: String)
        /// Research: add findings to this node.
        case investigate(node: String)

        /// The one node an action on a single node may change; nil for the runs that add nodes.
        var singleNode: String? {
            switch self {
            case .describe(let node), .correct(let node), .investigate(let node): return node
            case .research, .develop, .continuation: return nil
            }
        }
    }

    struct Limits: Equatable {
        /// New nodes in total.
        var nodes: Int
        /// Levels below the root (research, continuation) or below the developed node.
        var depth: Int
        /// Children under one node.
        var children: Int
    }

    static func limits(for mode: Mode) -> Limits {
        switch mode {
        case .research: return Limits(nodes: 60, depth: 3, children: 12)
        case .develop: return Limits(nodes: 24, depth: 2, children: 12)
        case .continuation: return Limits(nodes: 40, depth: 3, children: 12)
        case .describe, .correct, .investigate: return Limits(nodes: 0, depth: 0, children: 0)
        }
    }

    enum Event: Equatable {
        case root(Draft)
        case node(ref: String, parent: String, draft: Draft)
        /// A change to the one node of a single-node run; a key the agent left out is nil.
        case update(Patch)
    }

    /// What an `UPDATE` line says about the node.
    struct Patch: Equatable {
        var title: String?
        var description: String?
        var evidence: [Evidence]?
    }

    /// A parsed node, before the guards.
    struct Draft: Equatable {
        var title: String
        var description: String
        var tags: [String]
        var evidence: [Evidence]
        /// Only when the order of siblings matters (a badge before the title).
        var number: Int? = nil
    }

    struct Evidence: Equatable {
        var label: ResearchMap.Label
        var text: String
        var source: String
    }

    let mode: Mode
    let limits: Limits
    /// Lines that started like a node but could not be read.
    private(set) var malformedLines = 0
    /// Nodes added to the map by this run.
    private(set) var added = 0
    /// Nodes the guards refused (unknown parent, too deep, too many, repeated) and updates that changed nothing.
    private(set) var refused = 0
    /// Single-node runs: 1 once the node was changed.
    private(set) var updated = 0
    private var buffer = ""
    private var refs: [String: String] = [:]

    init(mode: Mode) {
        self.mode = mode
        self.limits = Self.limits(for: mode)
    }

    // MARK: Parsing

    /// Text the agent streamed; returns the node lines completed by it.
    mutating func feed(_ text: String) -> [Event] {
        buffer += text
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if let event = parse(line) { events.append(event) }
        }
        // A runaway line without a break is not a node line.
        if buffer.count > 60_000 { buffer = "" }
        return events
    }

    /// The last line, when the stream ended without a final newline.
    mutating func finish() -> [Event] {
        let rest = buffer
        buffer = ""
        return parse(rest).map { [$0] } ?? []
    }

    private mutating func parse(_ raw: String) -> Event? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["- ", "* ", "> ", "`", "**"] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        while line.hasSuffix("`") { line.removeLast() }
        if line.hasPrefix("UPDATE ") { return parseUpdate(String(line.dropFirst(7))) }
        let isRoot = line.hasPrefix("ROOT ")
        guard isRoot || line.hasPrefix("NODE ") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard json.hasPrefix("{"), let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let title = (object["title"] as? String).map({ ResearchMap.clean(title: $0) }), !title.isEmpty else {
            malformedLines += 1
            return nil
        }
        let draft = Draft(title: title,
                          description: String(((object["description"] as? String) ?? "").prefix(4000)),
                          tags: Self.tags(object["tags"]),
                          evidence: Self.evidence(object["evidence"]),
                          number: Self.number(object["number"]))
        if isRoot { return .root(draft) }
        let ref = Self.text(object["ref"])
        let parent = Self.text(object["parent"])
        return .node(ref: ref, parent: parent, draft: draft)
    }

    /// An UPDATE line counts only in a single-node run; elsewhere it is not a node line.
    private mutating func parseUpdate(_ raw: String) -> Event? {
        guard mode.singleNode != nil else { return nil }
        let json = raw.trimmingCharacters(in: .whitespaces)
        guard json.hasPrefix("{"), let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            malformedLines += 1
            return nil
        }
        var patch = Patch()
        if let title = object["title"] as? String { patch.title = title }
        if let description = object["description"] as? String { patch.description = String(description.prefix(8000)) }
        if object["evidence"] is [[String: Any]] { patch.evidence = Self.evidence(object["evidence"]) }
        guard patch.title != nil || patch.description != nil || patch.evidence != nil else {
            malformedLines += 1
            return nil
        }
        return .update(patch)
    }

    private static func text(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// A badge number: an integer (or a whole number written as text) within the map's limit; anything else is ignored.
    private static func number(_ value: Any?) -> Int? {
        let parsed: Int?
        if let integer = value as? Int { parsed = integer } else if let text = value as? String { parsed = Int(text.trimmingCharacters(in: .whitespaces)) } else { parsed = nil }
        return parsed.flatMap { ResearchMap.isNumber($0) ? $0 : nil }
    }

    private static func tags(_ value: Any?) -> [String] {
        let items = (value as? [String]) ?? (value as? String)?.components(separatedBy: ",") ?? []
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func evidence(_ value: Any?) -> [Evidence] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.prefix(8).compactMap { item in
            let text = String((item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            guard !text.isEmpty else { return nil }
            let name = (item["label"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let label = ResearchMap.Label.allCases.first { $0.rawValue.lowercased() == name } ?? .aiInference
            return Evidence(label: label, text: text, source: (item["source"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Applying

    /// Applies events to the map; returns the ids of the nodes created. `pathExists` verifies the
    /// repository files the agent cited; when `root` is provided, also checks cited line ranges,
    /// cited symbols in file content, and web availability (REQ-008).
    mutating func apply(_ events: [Event], to map: inout ResearchMap, pathExists: (String) -> Bool,
                        root: URL? = nil, webAllowed: Bool = true) -> [String] {
        var created: [String] = []
        let rootID = map.root?.id ?? "n1"
        for event in events {
            switch event {
            case .root(let draft):
                guard mode == .research, let rootNode = map.root else { continue }
                var edit = rootNode
                edit.title = ResearchMap.clean(title: draft.title)
                edit.description = ResearchMap.clean(description: draft.description)
                edit.tags = ResearchMap.clean(tags: draft.tags)
                edit.evidence = verified(draft.evidence, pathExists: pathExists, root: root, webAllowed: webAllowed)
                if let i = map.index(of: rootNode.id) { map.nodes[i] = edit }
                refs["root"] = rootNode.id
            case .update(let patch):
                guard let target = mode.singleNode, updated == 0, let i = map.index(of: target) else { refused += 1; continue }
                var node = map.nodes[i]
                switch mode {
                case .describe:
                    guard let text = patch.description.map({ ResearchMap.clean(description: $0) }), !text.isEmpty else { refused += 1; continue }
                    node.description = text
                    node.evidence = Self.merged(node.evidence, verified(patch.evidence ?? [], pathExists: pathExists, root: root, webAllowed: webAllowed))
                case .correct:
                    if let title = patch.title.map({ ResearchMap.clean(title: $0) }), !title.isEmpty { node.title = title }
                    if let text = patch.description.map({ ResearchMap.clean(description: $0) }), !text.isEmpty { node.description = text }
                    // An empty list is not a replacement: the findings are never wiped by an answer that forgot them.
                    if let evidence = patch.evidence, !evidence.isEmpty {
                        node.evidence = verified(evidence, pathExists: pathExists, root: root, webAllowed: webAllowed)
                    }
                case .investigate:
                    node.evidence = Self.merged(node.evidence, verified(patch.evidence ?? [], pathExists: pathExists, root: root, webAllowed: webAllowed))
                case .research, .develop, .continuation:
                    refused += 1
                    continue
                }
                guard node != map.nodes[i] else { refused += 1; continue }
                map.nodes[i] = node
                updated += 1
            case .node(let ref, let parent, let draft):
                guard let parentID = resolve(parent, in: map, rootID: rootID) else { refused += 1; continue }
                guard added < limits.nodes, map.children(of: parentID).count < limits.children,
                      depthBelowBase(of: parentID, in: map, rootID: rootID) + 1 <= limits.depth else { refused += 1; continue }
                let title = ResearchMap.clean(title: draft.title)
                if map.children(of: parentID).contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) { refused += 1; continue }
                var node = ResearchMap.Draft(title: title, description: draft.description, tags: draft.tags)
                node.evidence = verified(draft.evidence, pathExists: pathExists, root: root, webAllowed: webAllowed)
                node.number = draft.number
                guard let id = try? map.addNode(parent: parentID, draft: node) else { refused += 1; continue }
                added += 1
                created.append(id)
                if !ref.isEmpty { refs[ref] = id }
            }
        }
        return created
    }

    private func verified(_ evidence: [Evidence], pathExists: (String) -> Bool, root: URL?, webAllowed: Bool) -> [ResearchMap.Evidence] {
        evidence.map {
            ResearchMap.verifiedContent(label: $0.label, text: $0.text, source: $0.source,
                                        root: root, pathExists: pathExists, webAllowed: webAllowed)
        }
    }

    /// The old findings followed by the new ones that say something the old ones do not.
    private static func merged(_ old: [ResearchMap.Evidence], _ new: [ResearchMap.Evidence]) -> [ResearchMap.Evidence] {
        var result = old
        for item in new where !result.contains(where: { $0.text.caseInsensitiveCompare(item.text) == .orderedSame && $0.source == item.source }) {
            result.append(item)
        }
        return result
    }

    /// The node id a parent reference names, if the run may add under it.
    private func resolve(_ parent: String, in map: ResearchMap, rootID: String) -> String? {
        let key = parent.lowercased()
        let id: String
        switch mode {
        case .develop(let node):
            if key.isEmpty || key == "root" || key == "node" || key == "selected" { id = node }
            else if let ref = refs[parent] { id = ref }
            else { id = parent }
            return map.node(id) != nil && map.isInSubtree(id, of: node) ? id : nil
        case .research, .continuation:
            if key.isEmpty || key == "root" { id = refs["root"] ?? rootID }
            else if let ref = refs[parent] { id = ref }
            else { id = parent }
            return map.node(id) != nil ? id : nil
        case .describe, .correct, .investigate:
            return nil   // these runs add no nodes
        }
    }

    private func depthBelowBase(of id: String, in map: ResearchMap, rootID: String) -> Int {
        switch mode {
        case .develop(let node): return map.depth(of: id) - map.depth(of: node)
        case .research, .continuation, .describe, .correct, .investigate: return map.depth(of: id)
        }
    }
}
