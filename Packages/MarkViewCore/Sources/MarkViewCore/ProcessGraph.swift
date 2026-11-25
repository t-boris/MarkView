import Foundation

public struct ProcessGraph: Codable, Equatable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public var path: String
        public var line: Int
        public var endLine: Int

        public init(path: String, line: Int, endLine: Int) {
            self.path = path
            self.line = line
            self.endLine = endLine
        }
    }

    public struct Node: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case entry, action, decision, fork, join, exit, group, external
        }

        public var id: String
        public var parent: String?
        public var kind: Kind
        public var title: String
        public var symbol: String
        public var explanation: String
        public var input: String
        public var output: String
        public var sources: [Source]

        public init(id: String, parent: String? = nil, kind: Kind = .action, title: String,
                    symbol: String = "", explanation: String, input: String, output: String, sources: [Source]) {
            self.id = id
            self.parent = parent
            self.kind = kind
            self.title = title
            self.symbol = symbol
            self.explanation = explanation
            self.input = input
            self.output = output
            self.sources = sources
        }
    }

    public struct Edge: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case next, branch, parallel, `return`, error
        }

        public var id: String
        public var from: String
        public var to: String
        public var kind: Kind
        public var label: String
        public var sources: [Source]

        public init(id: String, from: String, to: String, kind: Kind = .next, label: String, sources: [Source]) {
            self.id = id
            self.from = from
            self.to = to
            self.kind = kind
            self.label = label
            self.sources = sources
        }
    }

    public struct Level: Equatable, Sendable {
        public var nodes: [Node]
        public var edges: [Edge]
        public var boundary: [Edge]
    }

    public struct ValidationError: LocalizedError, Equatable {
        public let problems: [String]
        public var errorDescription: String? { problems.prefix(20).joined(separator: "; ") }
    }

    public static let maxNodes = 400
    public static let maxEdges = 1200
    public static let maxSiblings = 24
    public static let maxDepth = 8

    public var version: Int
    public var title: String
    public var question: String
    public var takeaway: String
    public var omitted: String
    public var nodes: [Node]
    public var edges: [Edge]

    public init(title: String, question: String, takeaway: String, omitted: String = "",
                nodes: [Node], edges: [Edge], version: Int = 1) {
        self.version = version
        self.title = title
        self.question = question
        self.takeaway = takeaway
        self.omitted = omitted
        self.nodes = nodes
        self.edges = edges
    }

    public var sources: [Source] {
        Array(Set(nodes.flatMap(\.sources) + edges.flatMap(\.sources))).sorted {
            ($0.path, $0.line, $0.endLine) < ($1.path, $1.line, $1.endLine)
        }
    }

    public func validate(lineCounts: [String: Int]) throws {
        var problems: [String] = []
        if version != 1 { problems.append("Unsupported process graph version") }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 {
            problems.append("The process needs a title of at most 200 characters")
        }
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 4000 {
            problems.append("The process needs a question of at most 4000 characters")
        }
        if nodes.count < 2 || nodes.count > Self.maxNodes { problems.append("Invalid process node count") }
        if edges.isEmpty || edges.count > Self.maxEdges { problems.append("Invalid process edge count") }
        guard problems.isEmpty else { throw ValidationError(problems: problems) }

        var byID: [String: Node] = [:]
        for node in nodes {
            if !Self.validID(node.id) || byID[node.id] != nil { problems.append("Invalid or duplicate node id: \(node.id.prefix(96))") }
            byID[node.id] = node
            if node.title.isEmpty || node.title.count > 120 { problems.append("Invalid title for \(node.id)") }
            if node.explanation.isEmpty || node.explanation.count > 4000 || node.input.count > 2000 || node.output.count > 2000 {
                problems.append("Invalid explanation for \(node.id)")
            }
            if node.sources.count > 8 || (node.kind != .external && node.sources.isEmpty) {
                problems.append("Node \(node.id) needs 1-8 source ranges")
            }
        }
        for node in nodes {
            var cursor = node.parent
            var seen: Set<String> = [node.id]
            while let parent = cursor {
                guard seen.insert(parent).inserted else { problems.append("Parent cycle at \(node.id)"); break }
                guard let ancestor = byID[parent] else { problems.append("Missing parent of \(node.id)"); break }
                if seen.count > Self.maxDepth { problems.append("Hierarchy is too deep at \(node.id)"); break }
                cursor = ancestor.parent
            }
        }
        if Dictionary(grouping: nodes, by: { $0.parent ?? "<root>" }).values.contains(where: { $0.count > Self.maxSiblings }) {
            problems.append("A level has more than \(Self.maxSiblings) blocks; introduce source-grounded groups")
        }
        var edgeIDs = Set<String>()
        for edge in edges {
            if !Self.validID(edge.id) || !edgeIDs.insert(edge.id).inserted { problems.append("Invalid or duplicate edge id") }
            if byID[edge.from] == nil || byID[edge.to] == nil { problems.append("Edge \(edge.id) has an unknown endpoint") }
            if edge.from == edge.to && edge.kind != .return { problems.append("Self-transition \(edge.id) must be a return") }
            if edge.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || edge.label.count > 160 {
                problems.append("Edge \(edge.id) needs a short condition or handoff label")
            }
            if edge.sources.count > 8 || (edge.sources.isEmpty && byID[edge.from]?.kind != .external) {
                problems.append("Edge \(edge.id) needs source evidence")
            }
        }
        for source in sources {
            let parts = source.path.split(separator: "/", omittingEmptySubsequences: false)
            if source.path.isEmpty || source.path.hasPrefix("/") || source.path.contains("\\")
                || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                problems.append("Invalid project-relative source path")
            } else if let count = lineCounts[source.path], source.line > 0,
                      source.endLine >= source.line, source.endLine <= count {
                continue
            } else {
                problems.append("Missing source or invalid line range: \(source.path.prefix(200)):\(source.line)-\(source.endLine)")
            }
        }
        if problems.isEmpty && hasUnmarkedCycle() { problems.append("A cycle needs an explicit return transition") }
        if !problems.isEmpty { throw ValidationError(problems: problems) }
    }

    public func level(parent: String? = nil) -> Level {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = nodes.filter { $0.parent == parent }
        func representative(_ id: String) -> String? {
            var cursor = byID[id]
            var seen = Set<String>()
            while let node = cursor, seen.insert(node.id).inserted {
                if node.parent == parent { return node.id }
                cursor = node.parent.flatMap { byID[$0] }
            }
            return nil
        }
        var projected: [Edge] = []
        var boundary: [Edge] = []
        for edge in edges {
            let from = representative(edge.from), to = representative(edge.to)
            if let from, let to {
                guard from != to || (edge.from == edge.to && edge.from == from) else { continue }
                var lifted = edge
                lifted.from = from
                lifted.to = to
                projected.append(lifted)
            } else if from != nil || to != nil {
                boundary.append(edge)
            }
        }
        return Level(nodes: visible, edges: projected, boundary: boundary)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    private func hasUnmarkedCycle() -> Bool {
        var indegree = Dictionary(nodes.map { ($0.id, 0) }, uniquingKeysWith: { first, _ in first })
        var outgoing: [String: [String]] = [:]
        for edge in edges where edge.kind != .return {
            indegree[edge.to, default: 0] += 1
            outgoing[edge.from, default: []].append(edge.to)
        }
        var ready = indegree.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let id = ready.popLast() {
            visited += 1
            for target in outgoing[id] ?? [] {
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 { ready.append(target) }
            }
        }
        return visited != nodes.count
    }
}

public struct ProcessScenario: Codable, Equatable, Sendable {
    public var id: String
    public var graph: ProcessGraph
    public var createdAt: Date
    public var signatures: [String: String]
    public var sourceHashes: [String: String]

    public init(id: String = UUID().uuidString, graph: ProcessGraph, createdAt: Date = Date(),
                signatures: [String: String], sourceHashes: [String: String]) {
        self.id = id
        self.graph = graph
        self.createdAt = createdAt
        self.signatures = signatures
        self.sourceHashes = sourceHashes
    }

    public func isStale(currentSignatures: [String: String]) -> Bool {
        signatures.contains { path, signature in currentSignatures[path] != signature }
    }
}
