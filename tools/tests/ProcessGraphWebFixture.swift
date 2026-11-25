import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

enum ProcessGraphWebFixture {
    static func json() throws -> String {
        let names = ["Intake", "Identity", "Context", "Input", "Access", "Plan", "Admission", "Dispatch",
                     "Quarantine", "Reject", "Code task", "Data task", "Assemble", "Response"]
        let counts = [4, 4, 4, 5, 5, 5, 4, 5, 3, 2, 4, 4, 4, 3]
        let first = ProcessGraph.Source(path: "flow.py", line: 2, endLine: 4, note: "The operation performed by this excerpt.")
        let second = ProcessGraph.Source(path: "rules.py", line: 10, endLine: 12, note: "The rule that guards this operation.")
        func node(_ id: String, title: String, parent: String? = nil, kind: ProcessGraph.Node.Kind = .action) -> ProcessGraph.Node {
            ProcessGraph.Node(id: id, parent: parent, kind: kind, title: title, symbol: "stage_" + id.replacingOccurrences(of: ".", with: "_"),
                              explanation: "Performs the work of " + title + ".", input: "Input for " + id,
                              output: "Result of " + id, sources: [first, second])
        }
        var nodes = names.enumerated().map { node(String($0.offset + 1), title: $0.element, kind: $0.offset == 0 ? .entry : .group) }
        var edges: [ProcessGraph.Edge] = []
        func connect(_ from: String, _ to: String, _ kind: ProcessGraph.Edge.Kind = .next, _ label: String = "Pass result") {
            edges.append(.init(id: "e" + String(edges.count), from: from, to: to, kind: kind, label: label, sources: [first]))
        }
        for target in ["2", "3", "4"] { connect("1", target, .parallel, "Start independent checks") }
        for pair in [("2", "5"), ("3", "5"), ("3", "6"), ("4", "6"), ("5", "7"), ("6", "7")] { connect(pair.0, pair.1) }
        connect("7", "8", .branch, "Allowed")
        connect("7", "9", .branch, "Needs review")
        connect("7", "10", .branch, "Denied")
        connect("8", "11", .parallel, "Analyze code")
        connect("8", "12", .parallel, "Analyze data")
        connect("11", "13"); connect("12", "13"); connect("13", "14")
        connect("13", "8", .return, "Temporary failure, retry at most twice")
        connect("13", "6", .return, "Plan must be recalculated")
        for (i, count) in counts.enumerated() {
            let parent = String(i + 1)
            for child in 1...count {
                let id = parent + "." + String(child)
                nodes.append(node(id, title: id == "11.2" ? "Imports" : names[i] + " part " + String(child), parent: parent))
                if child > 1 { connect(parent + "." + String(child - 1), id) }
            }
        }
        for i in 1...4 { nodes.append(node("11.2." + String(i), title: "Nested check " + String(i), parent: "11.2")) }
        connect("11.2.1", "11.2.2", .parallel, "Direct dependencies")
        connect("11.2.1", "11.2.3", .parallel, "Transitive dependencies")
        connect("11.2.2", "11.2.4"); connect("11.2.3", "11.2.4")
        let graph = ProcessGraph(title: "Complex request process", question: "How does this process branch, join and recover?",
                                 takeaway: "Parallel checks join before a conditional decision; recovery returns to earlier stages.",
                                 nodes: nodes, edges: edges)
        try graph.validate(lineCounts: ["flow.py": 200, "rules.py": 200])
        let scenario = ProcessScenario(id: "process-fixture", graph: graph, createdAt: Date(timeIntervalSince1970: 0),
                                       signatures: ["flow.py": "v1", "rules.py": "v1"], sourceHashes: [:])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        var levels: [String: Any] = [scenario.id + "|": try encoded(graph.level())]
        for parent in Set(nodes.compactMap(\.parent)) { levels[scenario.id + "|" + parent] = try encoded(graph.level(parent: parent)) }
        var snippets: [String: Any] = [:]
        for node in nodes {
            for (index, source) in node.sources.enumerated() {
                let key = scenario.id + "|" + node.id + "|" + String(index)
                snippets[key] = ["key": key, "path": source.path, "line": source.line, "endLine": source.endLine,
                    "requestedEndLine": source.endLine, "language": "python", "stale": false, "truncated": false,
                    "code": "def " + (index == 0 ? node.symbol : "guard_" + node.symbol) + "():\n    value = \"" + node.id + "\"\n    return value"]
            }
        }
        let modules: [String: Any] = ["id": "modules", "nodes": [
            ["id": "m:", "kind": "root", "name": "Fixture", "signature": "root-v1"],
            ["id": "m:flow.py", "parent": "m:", "kind": "file", "name": "flow.py", "path": "flow.py", "language": "python", "signature": "v1"],
            ["id": "m:rules.py", "parent": "m:", "kind": "file", "name": "rules.py", "path": "rules.py", "language": "python", "signature": "v1"]], "edges": []]
        let snapshot: [String: Any] = ["views": [modules], "coverage": [:], "metrics": [:], "components": [], "assignments": [:],
            "overrides": [:], "ratings": [:], "deploymentHints": [], "scannedAt": "1970-01-01T00:00:00Z", "processGraphs": [try encoded(scenario)]]
        let payload: [String: Any] = ["root": "/process-fixture", "snapshot": snapshot, "busy": false, "filters": [], "prSources": [],
            "processState": ["tracing": false, "snippets": [:], "errors": [:], "levels": [:]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["payload": payload, "levels": levels, "snippets": snippets]), as: UTF8.self)
    }
}
