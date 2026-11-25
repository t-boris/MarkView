import XCTest
@testable import MarkViewCore

final class ProcessGraphTests: XCTestCase {
    private let source = ProcessGraph.Source(path: "src/handler.py", line: 2, endLine: 8)
    private let lines = ["src/handler.py": 40]

    private func node(_ id: String, parent: String? = nil, kind: ProcessGraph.Node.Kind = .action) -> ProcessGraph.Node {
        ProcessGraph.Node(id: id, parent: parent, kind: kind, title: id, explanation: "Handles \(id)",
                          input: "Request", output: "Result", sources: [source])
    }

    private func edge(_ from: String, _ to: String, kind: ProcessGraph.Edge.Kind = .next, id: String? = nil) -> ProcessGraph.Edge {
        ProcessGraph.Edge(id: id ?? from + "_" + to, from: from, to: to, kind: kind, label: "Pass result", sources: [source])
    }

    private func graph(nodes: [ProcessGraph.Node]? = nil, edges: [ProcessGraph.Edge]? = nil) -> ProcessGraph {
        ProcessGraph(title: "Request handling", question: "How is a request handled?", takeaway: "Checks join before execution.",
                     nodes: nodes ?? [node("start"), node("left"), node("right"), node("join", kind: .join)],
                     edges: edges ?? [edge("start", "left", kind: .parallel), edge("start", "right", kind: .parallel),
                                      edge("left", "join"), edge("right", "join")])
    }

    func testForkAndJoinKeepEveryConnection() throws {
        let value = graph()
        try value.validate(lineCounts: lines)
        XCTAssertEqual(value.level().edges.filter { $0.from == "start" }.count, 2)
        XCTAssertEqual(value.level().edges.filter { $0.to == "join" }.count, 2)
    }

    func testExplicitReturnDoesNotDestroyForwardOrdering() throws {
        var value = graph()
        value.edges.append(edge("join", "start", kind: .return))
        try value.validate(lineCounts: lines)
        XCTAssertEqual(value.level().edges.last?.kind, .return)
    }

    func testUnmarkedCycleIsRejected() {
        var value = graph()
        value.edges.append(edge("join", "start"))
        XCTAssertThrowsError(try value.validate(lineCounts: lines))
    }

    func testExplicitSelfReturnIsAllowed() throws {
        var value = graph()
        value.edges.append(edge("left", "left", kind: .return))
        try value.validate(lineCounts: lines)
        XCTAssertTrue(value.level().edges.contains { $0.from == "left" && $0.to == "left" })
    }

    func testParentCycleIsRejectedIndependentlyOfControlFlow() {
        let value = graph(nodes: [node("a", parent: "b"), node("b", parent: "a")], edges: [edge("a", "b")])
        XCTAssertThrowsError(try value.validate(lineCounts: lines))
    }

    func testMissingParentAndDuplicateIDsAreRejected() {
        for nodes in [[node("a", parent: "missing"), node("b")], [node("a"), node("a")]] {
            XCTAssertThrowsError(try graph(nodes: nodes, edges: [edge("a", "b")]).validate(lineCounts: lines))
        }
    }

    func testUnknownEndpointIsRejected() {
        XCTAssertThrowsError(try graph(edges: [edge("start", "unknown")]).validate(lineCounts: lines))
    }

    func testMissingEvidenceAndMissingFilesAreRejected() {
        var value = graph()
        value.nodes[0].sources = []
        XCTAssertThrowsError(try value.validate(lineCounts: lines))
        value = graph()
        value.edges[0].sources = []
        XCTAssertThrowsError(try value.validate(lineCounts: lines))
        XCTAssertThrowsError(try graph().validate(lineCounts: [:]))
    }

    func testOutsideAndNonCanonicalPathsAreRejectedEvenInLineIndex() {
        for path in ["/private/code.py", "../code.py", "src/../code.py", "src//code.py", "./code.py", "src\\code.py"] {
            var value = graph()
            value.nodes[0].sources = [.init(path: path, line: 1, endLine: 1)]
            XCTAssertThrowsError(try value.validate(lineCounts: lines.merging([path: 10], uniquingKeysWith: { first, _ in first })))
        }
    }

    func testSourceRangesAreCheckedAtBothEnds() {
        for (start, end) in [(0, 1), (5, 4), (1, 41), (-2, 3)] {
            var value = graph()
            value.nodes[0].sources = [.init(path: source.path, line: start, endLine: end)]
            XCTAssertThrowsError(try value.validate(lineCounts: lines))
        }
    }

    func testCollapsedGroupsLiftEdgesAndKeepBoundaryLinksOnDrillDown() throws {
        let nodes = [node("entry"), node("checks", kind: .group), node("a", parent: "checks"),
                     node("b", parent: "checks"), node("done")]
        let value = graph(nodes: nodes, edges: [edge("entry", "a"), edge("a", "b"), edge("b", "done")])
        try value.validate(lineCounts: lines)
        let overview = value.level()
        XCTAssertEqual(overview.nodes.map(\.id), ["entry", "checks", "done"])
        XCTAssertEqual(overview.edges.map(\.from), ["entry", "checks"])
        XCTAssertEqual(overview.edges.map(\.to), ["checks", "done"])
        let inside = value.level(parent: "checks")
        XCTAssertEqual(inside.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(inside.edges.map(\.id), ["a_b"])
        XCTAssertEqual(inside.boundary.map(\.id), ["entry_a", "b_done"])
    }

    func testNestedGroupsDoNotLeakDescendantsIntoTheOverview() throws {
        let value = graph(nodes: [node("entry"), node("group"), node("nested", parent: "group"),
                                  node("leaf", parent: "nested")], edges: [edge("entry", "leaf")])
        try value.validate(lineCounts: lines)
        XCTAssertEqual(value.level().edges.first?.to, "group")
        XCTAssertEqual(value.level(parent: "group").nodes.map(\.id), ["nested"])
        XCTAssertEqual(value.level(parent: "group").boundary.count, 1)
    }

    func testLargeProcessesNeedGroupsAtEachLevel() {
        let nodes = (0...ProcessGraph.maxSiblings).map { node("n\($0)") }
        let edges = (1..<nodes.count).map { edge("n\($0 - 1)", "n\($0)") }
        XCTAssertThrowsError(try graph(nodes: nodes, edges: edges).validate(lineCounts: lines))
    }

    func testSixtyBlocksRemainNavigableThroughGroups() throws {
        let groups = (0..<10).map { node("g\($0)", kind: .group) }
        let children = groups.flatMap { group in (0..<6).map { node(group.id + "_\($0)", parent: group.id) } }
        let links = (1..<groups.count).map { edge("g\($0 - 1)", "g\($0)") }
        let value = graph(nodes: groups + children, edges: links)
        try value.validate(lineCounts: lines)
        XCTAssertEqual(value.level().nodes.count, 10)
        XCTAssertEqual(groups.reduce(0) { $0 + value.level(parent: $1.id).nodes.count }, 60)
    }

    func testEvidenceIsDeduplicatedAndRoundTrips() throws {
        let value = graph()
        XCTAssertEqual(value.sources, [source])
        XCTAssertEqual(try JSONDecoder().decode(ProcessGraph.self, from: JSONEncoder().encode(value)), value)
    }

    func testScenarioStalenessOnlyDependsOnCitedFiles() throws {
        let value = ProcessScenario(id: "scenario", graph: graph(), signatures: [source.path: "old"], sourceHashes: [:])
        XCTAssertFalse(value.isStale(currentSignatures: [source.path: "old", "other.py": "new"]))
        XCTAssertTrue(value.isStale(currentSignatures: [source.path: "new"]))
        XCTAssertTrue(value.isStale(currentSignatures: [:]))
        XCTAssertEqual(try JSONDecoder().decode(ProcessScenario.self, from: JSONEncoder().encode(value)), value)
    }
}
