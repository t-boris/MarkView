import Foundation

/// AI diagram generation that runs inside a headless agent (`CLICompletion`) instead of pasting a
/// prompt into the interactive terminal. The agent reads the project with its own tools and answers
/// with a graph as JSON; this file validates that graph against the project, repairs it when it is
/// not usable, and writes it as a strict Mermaid subset that the editor lays out with ELK.
///
/// What makes a diagram useful, and so what the prompt and the validator enforce:
/// - it answers ONE question, stated in `question` and `takeaway`;
/// - it is small enough to read (a node budget); what was left out is said in `omitted`;
/// - every edge says what happens (a verb) and where it can be seen (`evidence`);
/// - every node points at the file that defines it, and a path that does not exist is rejected.
enum DiagramKind: String, CaseIterable {
    case architecture, dataflow, pipeline, sequence, er, deployment, flowchart, codemap, custom

    var title: String {
        switch self {
        case .architecture: return "System Architecture"
        case .dataflow: return "Data Flow"
        case .pipeline: return "Data Pipeline"
        case .sequence: return "Sequence Diagram"
        case .er: return "Entity-Relationship"
        case .deployment: return "Deployment"
        case .flowchart: return "Flowchart"
        case .codemap: return "Code Structure Map"
        case .custom: return "Custom"
        }
    }

    /// What the diagram of this kind must show; part of the agent's prompt.
    var guidance: String {
        switch self {
        case .architecture:
            return "A component diagram: the main parts of the system (services, modules, stores, external systems) and how they depend on or call each other. Group nodes by layer or domain; keep external systems in their own group. Direction: top to bottom, entry points first."
        case .dataflow:
            return "Where data comes from, how it is transformed and where it ends up. Nodes are sources, processing steps and stores; every edge names the data that moves (for example 'orders', 'auth token'). Direction: left to right."
        case .pipeline:
            return "The ordered stages data or work passes through. Nodes are stages in order; every edge names what is handed to the next stage. Branches only where the code really branches. Direction: left to right."
        case .sequence:
            return "The interactions of one scenario between components, in time order. Nodes are the participants (kind 'actor' for people or external callers); edges are the calls, and every edge label starts with its step number ('1. validate token', '2. load user'). Direction: left to right."
        case .er:
            return "The data model: entities (kind 'data') and their relationships. Edge labels state the relationship and cardinality ('has many', 'belongs to 1'). Include the key fields of an entity in its note. Direction: left to right."
        case .deployment:
            return "The runtime infrastructure: processes, servers, containers, databases and the services running on them, with the protocol or purpose on each link. Group by environment or host. Direction: top to bottom."
        case .flowchart:
            return "A process: actions and decisions (kind 'decision' for a branch). Edge labels on a branch state the condition ('yes', 'token expired'). Direction: top to bottom."
        case .codemap:
            return "The structure of the code base: its main modules or folders grouped by layer (entry points, application, domain, data, infrastructure), connected by the real import or call dependencies found in the code. One node per module or folder, never per file."
        case .custom:
            return "Whatever the instruction below asks for. Choose the direction that reads best."
        }
    }

    var defaultName: String { rawValue == "codemap" ? "code-structure-map" : "graph-\(rawValue)" }
}

/// A diagram as the agent describes it.
struct DiagramSpec: Codable, Equatable {
    struct Node: Codable, Equatable {
        var id: String
        var label: String
        var kind: String
        var group: String?
        /// Project-relative file that defines this node, optionally with ":line".
        var source: String?
        var note: String?
    }
    struct Edge: Codable, Equatable {
        var from: String
        var to: String
        var label: String
        /// Where the relation can be seen: "path/File.swift:42".
        var evidence: String?
    }
    var title: String
    /// The single question this diagram answers.
    var question: String
    /// What the reader should take away, one sentence.
    var takeaway: String
    /// "LR" or "TB".
    var direction: String
    var nodes: [Node]
    var edges: [Edge]
    /// What was left out to stay readable, and why. Empty when nothing was.
    var omitted: String?

    static let nodeKinds = ["service", "database", "api", "queue", "cache", "gateway", "worker", "ui",
                            "library", "external", "process", "data", "decision", "actor", "config"]
    static let maxNodes = 25
    static let maxGroups = 6
}

enum DiagramAI {
    // MARK: - Schema

    static var schema: [String: Any] {
        func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "question", "takeaway", "direction", "nodes", "edges", "omitted"],
            "properties": [
                "title": str("Short title of the diagram."),
                "question": str("The one question this diagram answers."),
                "takeaway": str("What the reader should take away, one sentence."),
                "direction": ["type": "string", "enum": ["LR", "TB"]],
                "nodes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "label", "kind", "group", "source", "note"],
                        "properties": [
                            "id": str("Unique, letters, digits and underscore only."),
                            "label": str("Name as it appears in the code or documents, 1-4 words."),
                            "kind": ["type": "string", "enum": DiagramSpec.nodeKinds],
                            "group": str("Layer or domain this node belongs to; empty when ungrouped."),
                            "source": str("Project-relative path of the file that defines this node, optionally ':line'; empty only for people and external systems."),
                            "note": str("One sentence: what it is responsible for."),
                        ],
                    ],
                ],
                "edges": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["from", "to", "label", "evidence"],
                        "properties": [
                            "from": str("Id of the calling, producing or depending node."),
                            "to": str("Id of the called, consuming or depended-on node."),
                            "label": str("A verb phrase of at most 4 words: what happens on this link."),
                            "evidence": str("'path/File.ext:line' where this relation is visible; empty only when the source is a document."),
                        ],
                    ],
                ],
                "omitted": str("What was left out to stay readable and why; empty when nothing was."),
            ],
        ]
    }

    // MARK: - Prompts

    static let system = """
    You draw diagrams that people use to understand a real system. A diagram is useful only when it \
    answers one question and can be trusted. Follow these rules without exception.

    1. ONE QUESTION. Decide what the reader must understand, write it as `question` and the answer \
    as `takeaway`. Everything in the diagram serves that question; anything else is left out.
    2. READABLE SIZE. Use 8 to 20 nodes; never more than \(DiagramSpec.maxNodes). When the system is \
    larger, show the level the question needs: merge details into one representative node, group nodes \
    (at most \(DiagramSpec.maxGroups) groups) and say what you left out in `omitted`. Leaving things out \
    is expected; a hairball with everything is useless.
    3. EVERY EDGE MEANS SOMETHING. Each edge points from the caller, producer or dependent to the \
    callee, consumer or dependency, and carries a verb phrase of at most 4 words ('publishes order', \
    'reads config'). No unlabeled edges. No node without at least one edge.
    4. GROUNDED IN THE SOURCE. You have Read, Grep and Glob. Before answering, open the files that \
    define the nodes and confirm each edge with Grep. `source` is the project-relative path of the file \
    that defines the node; `evidence` is 'path:line' where the relation is visible. Never invent a path, \
    a component or a relation; when you are not sure, leave it out. A diagram that is smaller and true \
    beats one that is bigger and guessed.
    5. NAMES FROM THE CODE. Labels use the names the code and documents use, 1 to 4 words, no sentences. \
    Put explanation in `note`, one sentence, in the language of the documents.
    6. KIND IS WHAT IT IS. Pick the node kind that matches what the component does, not what its name \
    contains: \(DiagramSpec.nodeKinds.joined(separator: ", ")).
    7. NO NOISE. Skip tests, logging, generic utilities and configuration unless the question is about them.
    Answer only with the JSON object of the schema.
    """

    static func prompt(kind: DiagramKind, instruction: String, sources: [(path: String, text: String)],
                       root: URL) -> String {
        var text = """
        Draw a "\(kind.title)" diagram of the project at \(root.path). Your tools read that folder.

        What this kind of diagram shows: \(kind.guidance)
        \(instruction.isEmpty ? "" : "\nThe user's instruction (it decides the question): \(instruction)\n")
        """
        if sources.isEmpty {
            text += "\nNo documents were selected: work from the code and its documents in the project folder.\n"
        } else {
            text += "\nStart from these documents (read the code they describe to confirm them):\n"
            var budget = 100_000
            for source in sources {
                let part = String(source.text.prefix(min(40_000, budget)))
                budget -= part.count
                text += "\n--- \(source.path)\(part.count < source.text.count ? " (truncated)" : "") ---\n\(part)\n"
                if budget <= 0 { text += "\n(further documents omitted for length; read them if needed)\n"; break }
            }
        }
        return text
    }

    static func editPrompt(instruction: String, currentMermaid: String) -> String {
        """
        Change this diagram as the instruction says and answer with the COMPLETE updated diagram.

        INSTRUCTION: \(instruction)

        CURRENT DIAGRAM (Mermaid; lines starting with '%% src' and '%% note' carry each node's source file and note, \
        keep them for nodes that stay):
        ```
        \(currentMermaid)
        ```

        Keep every node and edge the instruction does not mention, with its group, source and evidence. \
        Apply the rules of the system prompt to what you add: new nodes and edges are checked in the \
        code, so read the files before you add them.
        """
    }

    // MARK: - Run

    enum Failure: LocalizedError {
        case unusable([String])
        var errorDescription: String? {
            switch self {
            case .unusable(let problems):
                return "The assistant's diagram was not usable: " + problems.prefix(3).joined(separator: "; ")
            }
        }
    }

    /// Asks the agent for a diagram, validates it against the project and, when it has problems,
    /// asks again with the problems listed (twice at most). Returns the checked diagram.
    static func generate(prompt: String, root: URL, label: String,
                         onStage: @escaping @Sendable (String) -> Void,
                         record: @escaping @Sendable (CLICompletion.Result) -> Void) async throws -> DiagramSpec {
        var attempt = prompt
        var lastProblems: [String] = []
        for round in 0...2 {
            try Task.checkCancellation()
            var request = CLICompletion.Request(project: root, prompt: attempt, systemPrompt: system,
                                                jsonSchema: schema, readableFolder: root)
            request.effort = "medium"
            request.timeout = 600
            request.label = round == 0 ? label : "\(label):repair\(round)"
            onStage(round == 0 ? "Starting" : "Fixing the diagram (attempt \(round + 1))")
            let result = try await CLICompletion.run(request, onDelta: { _ in onStage("Writing the diagram") },
                                                     onActivity: { activity in
                switch activity {
                case .read: onStage("Reading project files")
                case .search: onStage("Checking relations in the code")
                case .run: onStage("Inspecting the project")
                case .thinking: onStage("Thinking")
                case .writing, .answerDelta: onStage("Writing the diagram")
                default: break
                }
            })
            record(result)
            guard let spec = decode(result) else {
                lastProblems = ["the answer was not a diagram in the required JSON format"]
                attempt = prompt + "\n\nYour previous answer was not the required JSON object. Answer with the JSON object only."
                continue
            }
            let (checked, problems) = validate(spec, root: root)
            if problems.isEmpty { return checked }
            lastProblems = problems
            let previous = (try? String(data: JSONEncoder().encode(spec), encoding: .utf8)) ?? ""
            attempt = prompt + """


            Your previous diagram had these problems; fix every one and answer with the complete corrected diagram:
            \(problems.prefix(20).map { "- \($0)" }.joined(separator: "\n"))

            Previous diagram:
            \(previous)
            """
        }
        throw Failure.unusable(lastProblems)
    }

    private static func decode(_ result: CLICompletion.Result) -> DiagramSpec? {
        let decoder = JSONDecoder()
        if let object = result.structured, JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let spec = try? decoder.decode(DiagramSpec.self, from: data) { return spec }
        // Plain text answer: the outermost JSON object in it.
        let text = result.text
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
           let spec = try? decoder.decode(DiagramSpec.self, from: Data(text[open...close].utf8)) { return spec }
        return nil
    }

    // MARK: - Validation

    /// Cleans trivial slips (stray quotes, empty strings, unknown kinds) and lists the problems that
    /// only the agent can fix. The list is empty when the diagram is usable.
    static func validate(_ input: DiagramSpec, root: URL) -> (DiagramSpec, [String]) {
        var spec = input
        var problems: [String] = []
        let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]*$")
        func isID(_ s: String) -> Bool { idPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "/")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        spec.title = clean(spec.title)
        spec.question = clean(spec.question)
        spec.takeaway = clean(spec.takeaway)
        spec.direction = spec.direction == "TB" ? "TB" : "LR"
        spec.omitted = spec.omitted.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        if spec.question.isEmpty { problems.append("`question` is empty: state the one question the diagram answers") }

        var seen = Set<String>()
        var kept: [DiagramSpec.Node] = []
        for var node in spec.nodes {
            node.label = clean(node.label)
            node.note = node.note.map(clean).flatMap { $0.isEmpty ? nil : $0 }
            node.group = node.group.map(clean).flatMap { $0.isEmpty ? nil : $0 }
            if !DiagramSpec.nodeKinds.contains(node.kind) { node.kind = "process" }
            if !isID(node.id) { problems.append("node id '\(node.id)' must be letters, digits and underscore, starting with a letter"); continue }
            if !seen.insert(node.id).inserted { problems.append("node id '\(node.id)' is used twice"); continue }
            if node.label.isEmpty { problems.append("node '\(node.id)' has no label"); continue }
            if let source = node.source.map(clean), !source.isEmpty {
                let path = source.split(separator: ":").first.map(String.init) ?? source
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                    node.source = source
                } else {
                    problems.append("node '\(node.id)': source '\(path)' does not exist in the project; give the real path or leave `source` empty for an external system")
                    node.source = nil
                }
            } else {
                node.source = nil
            }
            kept.append(node)
        }
        spec.nodes = kept
        let ids = Set(kept.map(\.id))

        var edges: [DiagramSpec.Edge] = []
        var seenEdges = Set<String>()
        for var edge in spec.edges {
            edge.label = clean(edge.label)
            edge.evidence = edge.evidence.map(clean).flatMap { $0.isEmpty ? nil : $0 }
            if !ids.contains(edge.from) || !ids.contains(edge.to) {
                problems.append("edge \(edge.from) -> \(edge.to) uses an id that is not a node")
                continue
            }
            if edge.from == edge.to { continue }
            if edge.label.isEmpty { problems.append("edge \(edge.from) -> \(edge.to) has no label: say what happens on it"); continue }
            if seenEdges.insert("\(edge.from)>\(edge.to)>\(edge.label)").inserted { edges.append(edge) }
        }
        spec.edges = edges

        if spec.nodes.count < 2 { problems.append("fewer than 2 usable nodes") }
        if spec.nodes.count > DiagramSpec.maxNodes {
            problems.append("\(spec.nodes.count) nodes: at most \(DiagramSpec.maxNodes). Merge details into representative nodes and note what was left out in `omitted`")
        }
        let groups = Set(spec.nodes.compactMap(\.group))
        if groups.count > DiagramSpec.maxGroups {
            problems.append("\(groups.count) groups: at most \(DiagramSpec.maxGroups)")
        }
        let connected = Set(spec.edges.flatMap { [$0.from, $0.to] })
        let loose = spec.nodes.filter { !connected.contains($0.id) }.map(\.id)
        if !loose.isEmpty { problems.append("nodes without any edge: \(loose.joined(separator: ", ")); connect them or remove them") }
        if !spec.nodes.isEmpty, spec.edges.count < spec.nodes.count - 1 {
            problems.append("only \(spec.edges.count) edges for \(spec.nodes.count) nodes: the diagram does not show how the parts relate")
        }
        return (spec, problems)
    }

    // MARK: - Mermaid

    private static let kindColors: [String: String] = [
        "service": "#4ec9b0", "database": "#c586c0", "api": "#569cd6", "queue": "#ce9178", "cache": "#d7ba7d",
        "gateway": "#dcdcaa", "worker": "#ce9178", "ui": "#9cdcfe", "library": "#808080", "external": "#f44747",
        "process": "#4ec9b0", "data": "#c586c0", "decision": "#d7ba7d", "actor": "#9cdcfe", "config": "#808080",
    ]

    /// The diagram in the strict Mermaid subset the editor's interactive canvas reads: one node per
    /// line, one edge per line, `:::kind` classes, `%% src` and `%% note` comment lines. Stock Mermaid
    /// renders it too.
    static func mermaid(_ spec: DiagramSpec) -> String {
        var lines = ["%%INTERACTIVE", "flowchart \(spec.direction)"]
        for kind in Set(spec.nodes.map(\.kind)).sorted() {
            let color = kindColors[kind] ?? "#808080"
            lines.append("classDef \(kind) fill:\(color)26,stroke:\(color),stroke-width:1.5px")
        }
        func nodeLine(_ n: DiagramSpec.Node, indent: String) -> String {
            "\(indent)\(n.id)[\"\(n.label)\"]:::\(n.kind)"
        }
        var groupNames: [String] = []
        for n in spec.nodes { if let g = n.group, !groupNames.contains(g) { groupNames.append(g) } }
        for (i, name) in groupNames.enumerated() {
            lines.append("subgraph g\(i + 1)[\"\(name)\"]")
            for n in spec.nodes where n.group == name { lines.append(nodeLine(n, indent: "  ")) }
            lines.append("end")
        }
        for n in spec.nodes where n.group == nil { lines.append(nodeLine(n, indent: "")) }
        for e in spec.edges { lines.append("\(e.from) -->|\(e.label)| \(e.to)") }
        for n in spec.nodes {
            if let s = n.source { lines.append("%% src \(n.id) \(s)") }
            if let note = n.note { lines.append("%% note \(n.id) \(note)") }
        }
        for e in spec.edges { if let ev = e.evidence { lines.append("%% evidence \(e.from) \(e.to) \(ev)") } }
        return lines.joined(separator: "\n")
    }

    /// The Markdown file: what the diagram answers, the diagram, and a legend that lists every
    /// component with its role and file, so the page is useful without the canvas.
    static func markdown(_ spec: DiagramSpec) -> String {
        var out = "# \(spec.title)\n\n**Question:** \(spec.question)\n\n**Takeaway:** \(spec.takeaway)\n\n"
        out += "```mermaid\n\(mermaid(spec))\n```\n\n## Components\n\n"
        for n in spec.nodes {
            out += "- **\(n.label)** (\(n.kind))"
            if let note = n.note { out += " — \(note)" }
            if let s = n.source { out += " — `\(s)`" }
            out += "\n"
        }
        if let omitted = spec.omitted { out += "\n## Left out\n\n\(omitted)\n" }
        return out
    }

    /// A file name that does not overwrite an existing file: graph-x.md, graph-x-2.md, ...
    static func freeURL(in folder: URL, base: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent("\(base).md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return url
    }
}
