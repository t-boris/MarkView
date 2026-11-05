import Foundation

/// The AI side of research maps (DEC-008): the prompts, the parser of the node lines the agent writes
/// while it works, and the guards that decide which nodes enter the map. The limits are enforced here,
/// in code, so the result does not depend on which model the person configured. Pure (Foundation and
/// ResearchMapDocument), so `tools/tests` can compile it alone.
enum ResearchMapPrompt {
    static func system(web: Bool, webRules: String, languageLine: String) -> String {
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

        You write the map as lines, one node per line. A node line is the word NODE, one space, and a \
        JSON object on that same line (no line breaks inside the object, no code fence, no list marker):
        NODE {"ref":"short-label","parent":"root","title":"...","description":"...","tags":["..."],"evidence":[{"label":"Project fact","text":"...","source":"path/file.ext:42"}]}
        - ref: a short label, unique in your answer. Later nodes name it as their parent.
        - parent: "root" (see the task for what that is), the ref of a node you wrote earlier, or the id \
        of an existing node when the task lists ids.
        - title: at most 8 words; a topic, not a sentence.
        - description: Markdown, one to four sentences or a short bullet list; what matters about the topic.
        - tags: zero to four short tags.
        - evidence: the findings behind the description, each with label (exactly one of the four above), \
        text and source (empty for AI inference and Open assumption).
        Write each node as soon as you know it, not at the end. Anything you write that is not a node \
        line is ignored, so think aloud if you need to. Never modify files.

        \(languageLine)
        """
    }

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
        The person asks to develop it in this direction:

        \(direction)

        Add new nodes under this node. Use "parent":"node" for its direct children, or the ref of a node you wrote \
        earlier for a deeper level (at most \(limits.depth) levels below the node, at most \(limits.children) children \
        under a node and \(limits.nodes) nodes in total). If the direction asks for options, alternatives or \
        variants, write each option as its own child node of the node, with its trade-offs in the description. Do not \
        repeat topics the map already has. Research the repository and, if allowed, the web, for the facts behind \
        each node.


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

    private static func detail(_ node: ResearchMap.Node) -> String {
        var text = ""
        if !node.description.isEmpty { text += "Its description:\n\(String(node.description.prefix(1500)))\n" }
        if !node.evidence.isEmpty {
            text += "Its findings:\n" + node.evidence.prefix(8).map { "- [\($0.label.rawValue)] \(String($0.text.prefix(300)))" }.joined(separator: "\n") + "\n"
        }
        return text
    }
}

/// One AI run over a map: parses the agent's stream line by line and applies the nodes that pass the
/// guards. A value of this type belongs to one run.
struct ResearchMapRun {
    enum Mode: Equatable {
        case research
        /// Develop the node with this id.
        case develop(node: String)
        case continuation
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
        }
    }

    enum Event: Equatable {
        case root(Draft)
        case node(ref: String, parent: String, draft: Draft)
    }

    /// A parsed node, before the guards.
    struct Draft: Equatable {
        var title: String
        var description: String
        var tags: [String]
        var evidence: [Evidence]
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
    /// Nodes the guards refused (unknown parent, too deep, too many, repeated).
    private(set) var refused = 0
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
                          evidence: Self.evidence(object["evidence"]))
        if isRoot { return .root(draft) }
        let ref = Self.text(object["ref"])
        let parent = Self.text(object["parent"])
        return .node(ref: ref, parent: parent, draft: draft)
    }

    private static func text(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
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
    /// repository files the agent cited (a finding without a real file or URL becomes an inference).
    mutating func apply(_ events: [Event], to map: inout ResearchMap, pathExists: (String) -> Bool) -> [String] {
        var created: [String] = []
        let rootID = map.root?.id ?? "n1"
        for event in events {
            switch event {
            case .root(let draft):
                guard mode == .research, let root = map.root else { continue }
                var edit = root
                edit.title = ResearchMap.clean(title: draft.title)
                edit.description = ResearchMap.clean(description: draft.description)
                edit.tags = ResearchMap.clean(tags: draft.tags)
                edit.evidence = verified(draft.evidence, pathExists: pathExists)
                if let i = map.index(of: root.id) { map.nodes[i] = edit }
                refs["root"] = root.id
            case .node(let ref, let parent, let draft):
                guard let parentID = resolve(parent, in: map, rootID: rootID) else { refused += 1; continue }
                guard added < limits.nodes, map.children(of: parentID).count < limits.children,
                      depthBelowBase(of: parentID, in: map, rootID: rootID) + 1 <= limits.depth else { refused += 1; continue }
                let title = ResearchMap.clean(title: draft.title)
                if map.children(of: parentID).contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) { refused += 1; continue }
                var node = ResearchMap.Draft(title: title, description: draft.description, tags: draft.tags)
                node.evidence = verified(draft.evidence, pathExists: pathExists)
                guard let id = try? map.addNode(parent: parentID, draft: node) else { refused += 1; continue }
                added += 1
                created.append(id)
                if !ref.isEmpty { refs[ref] = id }
            }
        }
        return created
    }

    private func verified(_ evidence: [Evidence], pathExists: (String) -> Bool) -> [ResearchMap.Evidence] {
        evidence.map { ResearchMap.verified(label: $0.label, text: $0.text, source: $0.source, pathExists: pathExists) }
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
        }
    }

    private func depthBelowBase(of id: String, in map: ResearchMap, rootID: String) -> Int {
        switch mode {
        case .develop(let node): return map.depth(of: id) - map.depth(of: node)
        case .research, .continuation: return map.depth(of: id)
        }
    }
}
