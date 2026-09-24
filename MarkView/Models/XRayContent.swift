import CryptoKit
import Foundation

/// What a file is made of, shown under its box in the Logical X-Ray: the collections of
/// like things it holds (issues, requirements, decisions, endpoints; types and functions
/// in code), each split into types, down to the single item and the line it starts on.
///
/// Documents and long code files are read by the assistant (one call per file, cached by
/// content) and split logically; short code is outlined locally from its declarations. Outlines are kept per file under
/// `.dde/cache/xray-content/` and dropped when the file changes.
enum XRayContent {
    struct Item: Codable, Hashable {
        var name: String
        /// 1-based line where the item starts.
        var line: Int
        var summary: String?
        /// Text of that line without markup, to find the item in rendered markdown.
        var anchor: String?
    }

    struct Group: Codable, Hashable {
        /// Type of the items ("Bug", "Feature"); empty when the collection has no types.
        var name: String
        var items: [Item]
    }

    struct Collection: Codable, Hashable {
        var name: String
        var summary: String?
        var groups: [Group]
    }

    struct Outline: Codable {
        /// Size and modification date of the file it was made from.
        var signature: String
        var collections: [Collection]
        /// "ai" (read by the assistant) or "structure" (code declarations).
        var source: String
        /// Output language setting it was written for (AI outlines).
        var language: String?
    }

    /// Files the assistant reads per analysis, longest first; the rest on request
    /// (details panel).
    static let filesPerAnalysis = 60
    /// Code files from this many lines are split logically by the assistant.
    static let longCodeLines = 250
    /// Most content nodes sent to the diagram at once.
    static let maxDrawnNodes = 20_000
    /// Parallel document calls.
    static let parallelCalls = 4
    /// Longest document text sent, in lines.
    static let maxLines = 2500

    // MARK: - Files

    static func isDocument(_ language: String?) -> Bool { language == "markdown" }

    /// Whether the assistant splits this file (documents, long code) rather than the
    /// local declaration outline.
    static func needsAssistant(language: String?, lines: Int) -> Bool {
        isDocument(language) || lines >= longCodeLines
    }

    /// Size and modification date: cheap to check, changes with every edit.
    static func signature(of file: URL) -> String? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "\(size)-\(Int(date.timeIntervalSince1970 * 1000))"
    }

    static func cacheDirectory(root: URL) -> URL {
        root.appendingPathComponent(".dde/cache/xray-content", isDirectory: true)
    }

    private static func cacheFile(root: URL, path: String) -> URL {
        let key = SHA256.hash(data: Data(root.appendingPathComponent(path).standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        return cacheDirectory(root: root).appendingPathComponent(key + ".json")
    }

    /// Stored outlines of `paths` that still match their files.
    static func loadFresh(root: URL, paths: [String]) -> [String: Outline] {
        var outlines: [String: Outline] = [:]
        let decoder = JSONDecoder()
        for path in paths {
            guard let data = try? Data(contentsOf: cacheFile(root: root, path: path)),
                  let outline = try? decoder.decode(Outline.self, from: data),
                  outline.signature == signature(of: root.appendingPathComponent(path)) else { continue }
            outlines[path] = outline
        }
        return outlines
    }

    static func save(_ outline: Outline, root: URL, path: String) {
        guard let data = try? JSONEncoder().encode(outline) else { return }
        let file = cacheFile(root: root, path: path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Code: declarations

    /// (kind, name) captures per language; nested declarations included.
    private static let codePatterns: [String: NSRegularExpression] = {
        func re(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
        let script = re(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?(function\*?|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)"#)
        return [
            "javascript": script, "typescript": script,
            "swift": re(#"^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|class|override|nonisolated|mutating|required|convenience|indirect|lazy)\s+)*(class|struct|enum|protocol|actor|extension|func)\s+([A-Za-z_][\w.]*)"#),
            "python": re(#"^\s*(class|def|async\s+def)\s+([A-Za-z_]\w*)"#),
            "go": re(#"^(func|type)\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)"#),
            "rust": re(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(fn|struct|enum|trait|impl|mod)\s+([A-Za-z_]\w*)"#),
            "java": re(#"^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*(class|interface|enum|record)\s+([A-Za-z_]\w*)"#),
            "kotlin": re(#"^\s*(?:(?:data|sealed|abstract|open|private|internal|public|override|suspend)\s+)*(class|interface|object|fun)\s+([A-Za-z_]\w*)"#),
            "csharp": re(#"^\s*(?:(?:public|private|protected|internal|static|abstract|sealed|partial)\s+)*(class|interface|enum|record|struct)\s+([A-Za-z_]\w*)"#),
            "ruby": re(#"^\s*(class|module|def)\s+([A-Za-z_][\w.:?!]*)"#),
            "php": re(#"^\s*(?:(?:abstract|final|public|private|protected|static)\s+)*(class|interface|trait|function)\s+([A-Za-z_]\w*)"#),
        ]
    }()

    private static func group(ofKeyword keyword: String) -> String {
        switch keyword {
        case "func", "function", "function*", "def", "async def", "fn", "fun": return "Functions"
        case "extension", "impl": return "Extensions"
        case "mod", "module": return "Modules"
        default: return "Types"
        }
    }

    /// Declarations of a code file grouped by kind, or nil when the language has no pattern.
    static func codeOutline(text: String, language: String?, signature: String) -> Outline? {
        guard let language, let regex = codePatterns[language] else { return nil }
        let lines = text.editorLines.map(String.init)
        var groups: [String: [Item]] = [:]
        var count = 0
        for (index, line) in lines.enumerated() where count < 300 {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let kindRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line) else { continue }
            let keyword = line[kindRange].replacingOccurrences(of: "  ", with: " ")
            let name = String(line[nameRange])
            groups[group(ofKeyword: keyword), default: []].append(Item(name: name, line: index + 1, summary: keyword))
            count += 1
        }
        // A file declaring one thing is described by its own box.
        guard count >= 2 else { return nil }
        let order = ["Types", "Extensions", "Modules", "Functions"]
        let collection = Collection(name: "Declarations", summary: nil,
                                    groups: order.compactMap { name in groups[name].map { Group(name: name, items: $0) } })
        return Outline(signature: signature, collections: [collection], source: "structure")
    }

    // MARK: - Documents: the assistant

    static let documentSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "collections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "summary": ["type": "string"],
                        "groups": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string"],
                                    "items": [
                                        "type": "array",
                                        "items": [
                                            "type": "object",
                                            "properties": [
                                                "name": ["type": "string"],
                                                "line": ["type": "integer"],
                                                "summary": ["type": "string"],
                                            ],
                                            "required": ["name", "line"],
                                        ],
                                    ],
                                ],
                                "required": ["name", "items"],
                            ],
                        ],
                    ],
                    "required": ["name", "groups"],
                ],
            ],
        ],
        "required": ["collections"],
    ]

    /// Labels drawn on the diagram follow the file's language (English for code); only the
    /// summaries follow the AI language setting.
    static func languageLine(summaries: String) -> String {
        "Every name — collections, parts, types and items — is a label on the diagram: write it in the "
            + "language the file itself is written in (English for code and for English documents), item names "
            + "as they appear in the file. Write only the summaries in \(summaries)."
    }

    static func codeSystemPrompt(languageLine: String) -> String {
        """
        You split a long source file logically, for a diagram that drills down from the file to         every function in it. Divide the file into its logical PARTS (3-12): areas of         responsibility a reader would name ("Terminal sessions", "Prompt buttons", "Persistence"),         not just "types" and "functions". Within each part, group its elements by TYPE — the role         they play (e.g. "Model", "Public API", "Event handlers", "Rendering", "Helpers",         "Networking"); use a single group with an empty name when a part is small. List EVERY type,         function, method and notable property of the part — never sample: its name as written in         the code, the 1-based line where it starts (lines are numbered), and what it does in at         most 12 words. Put each element in exactly one part, in file order. Return each PART as \
        one collection (name = the part, summary = what it is responsible for) whose groups are the \
        element types; never a single collection named after the file.
        \(languageLine)
        """
    }

    static func documentSystemPrompt(languageLine: String) -> String {
        """
        You map what a document is made of, for a diagram that drills down from the document to \
        every single thing it lists. Find the COLLECTIONS of like things the document holds — for \
        example issues, bugs, tasks, user stories, requirements, decisions, risks, open questions, \
        features, API endpoints, commands, settings, people, glossary terms, test cases, meetings, \
        chapters. For each collection give a short name ("Issues") and a one-line summary, and split \
        its items into TYPES: use the categories the document itself uses (labels, kind, severity, \
        priority, status, the heading they sit under); if it uses none, choose the most useful \
        classification (2-8 types). Use a single group with an empty name only when a collection is \
        too small to split. List EVERY item — never sample or stop early: its name as written in the \
        document (short, at most 10 words), the 1-based line number where it starts (lines are \
        numbered), and a summary of at most 15 words (leave summaries out when a collection has more \
        than 150 items). A document that is plain prose with no collection gets one collection \
        "Sections" whose items are its main sections, typed by the part of the document they belong to.
        \(languageLine)
        """
    }

    /// The document with line numbers (clipped to `maxLines`), for the prompt.
    static func numbered(_ text: String, name: String) -> String {
        let lines = text.editorLines.map(String.init)
        var out = "File: \(name) (\(lines.count) lines)\n\n"
        for (index, line) in lines.prefix(maxLines).enumerated() { out += "\(index + 1)| \(line)\n" }
        if lines.count > maxLines { out += "… (\(lines.count - maxLines) more lines not shown)\n" }
        return out
    }

    /// The assistant's answer as an outline; lines are clamped to the file and anchors read
    /// from it.
    static func assistantOutline(from object: [String: Any], text: String, signature: String, language: String) -> Outline {
        let lines = text.editorLines.map(String.init)
        func clean(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var collections: [Collection] = []
        for raw in object["collections"] as? [[String: Any]] ?? [] {
            var groups: [Group] = []
            for rawGroup in raw["groups"] as? [[String: Any]] ?? [] {
                let items = (rawGroup["items"] as? [[String: Any]] ?? []).compactMap { rawItem -> Item? in
                    let name = clean(rawItem["name"])
                    guard !name.isEmpty else { return nil }
                    let line = min(max((rawItem["line"] as? Int) ?? 1, 1), max(lines.count, 1))
                    let summary = clean(rawItem["summary"])
                    return Item(name: name, line: line, summary: summary.isEmpty ? nil : summary,
                                anchor: lines.indices.contains(line - 1) ? anchor(lines[line - 1]) : nil)
                }
                if !items.isEmpty { groups.append(Group(name: clean(rawGroup["name"]), items: items)) }
            }
            let name = clean(raw["name"])
            if !groups.isEmpty, !name.isEmpty {
                let summary = clean(raw["summary"])
                collections.append(Collection(name: name, summary: summary.isEmpty ? nil : summary, groups: groups))
            }
        }
        return Outline(signature: signature, collections: collections, source: "ai", language: language)
    }

    /// A markdown line as rendered text: list markers, heading hashes, emphasis and table
    /// pipes removed.
    static func anchor(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^(#{1,6}|[-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.filter { !"*_`|>".contains($0) }.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { return nil }
        return String(text.prefix(60))
    }

    // MARK: - Diagram nodes

    /// Nodes below the file box `fileId`: collection → type → item. A collection with one
    /// unnamed type holds its items directly.
    static func nodes(for outline: Outline, path: String, fileId: String) -> [ArchNode] {
        var nodes: [ArchNode] = []
        let base = "l:e:" + path + "#"
        for (ci, collection) in outline.collections.enumerated() {
            let collectionId = base + "\(ci)"
            nodes.append(ArchNode(id: collectionId, parent: fileId, kind: "collection", name: collection.name,
                                  path: path, files: collection.groups.reduce(0) { $0 + $1.items.count },
                                  summary: collection.summary))
            let flat = collection.groups.count == 1 && collection.groups[0].name.isEmpty
            for (gi, group) in collection.groups.enumerated() {
                let groupId = collectionId + ".\(gi)"
                var itemParent = collectionId
                if !flat {
                    nodes.append(ArchNode(id: groupId, parent: collectionId, kind: "group",
                                          name: group.name.isEmpty ? "Other" : group.name,
                                          path: path, files: group.items.count))
                    itemParent = groupId
                }
                for (ii, item) in group.items.enumerated() {
                    var node = ArchNode(id: groupId + ".\(ii)", parent: itemParent, kind: "entity", name: item.name,
                                        path: path, summary: item.summary)
                    node.line = item.line
                    node.anchor = item.anchor
                    nodes.append(node)
                }
            }
        }
        return nodes
    }
}
