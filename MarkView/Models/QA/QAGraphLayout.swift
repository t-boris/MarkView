import CoreGraphics
import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): where each step and connection of a scenario is drawn. The main line runs left to right
// along the top; each fork continues on a row of its own below the step it forks from. Pure (Foundation and CoreGraphics), so
// tools/tests/qa-tests.sh compiles it on its own: nothing here draws.

struct QAGraphLayout {
    struct Metrics {
        var nodeWidth: CGFloat = 176
        var nodeHeight: CGFloat = 58
        var columnGap: CGFloat = 54
        var rowGap: CGFloat = 26
        var margin: CGFloat = 28
    }

    struct Node: Identifiable, Equatable {
        let id: String
        let frame: CGRect
        let column: Int
        let row: Int
        /// True for a step the start does not lead to; these are kept in rows below the graph.
        let loose: Bool
    }

    struct Edge: Identifiable, Equatable {
        let from: String
        let to: String
        let label: String?
        /// The start, the two control points and the end of one cubic curve.
        let curve: [CGPoint]
        let labelPoint: CGPoint
        var id: String { from + ">" + to }
    }

    let nodes: [Node]
    let edges: [Edge]
    let size: CGSize
    let metrics: Metrics

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    func node(at point: CGPoint) -> Node? { nodes.first { $0.frame.contains(point) } }

    /// The connection nearest to `point` within `tolerance`, for selecting it with a click.
    func edge(near point: CGPoint, tolerance: CGFloat = 8) -> Edge? {
        var best: (edge: Edge, distance: CGFloat)?
        for edge in edges {
            let line = QAGraphLayout.flatten(edge.curve)
            let distance = QAGraphLayout.distance(from: point, toPolyline: line)
            if distance <= tolerance, best == nil || distance < best!.distance { best = (edge, distance) }
        }
        return best?.edge
    }

    static func make(_ scenario: QAScenario, metrics m: Metrics = Metrics()) -> QAGraphLayout {
        let known = Set(scenario.nodes.map(\.id))
        var next: [String: [String]] = [:]
        for edge in scenario.edges where known.contains(edge.from) && known.contains(edge.to) && edge.from != edge.to {
            if !(next[edge.from] ?? []).contains(edge.to) { next[edge.from, default: []].append(edge.to) }
        }

        // Depth first from the start in the order the connections are written: the order of the rows, and the edges that close a loop.
        var order: [String] = []
        var state: [String: Int] = [:]
        var back = Set<String>()   // "from>to" of an edge that leads back to a step on the current line
        func visit(_ id: String) {
            state[id] = 1
            order.append(id)
            for child in next[id] ?? [] {
                if state[child] == 1 { back.insert(id + ">" + child) } else if state[child] == nil { visit(child) }
            }
            state[id] = 2
        }
        if let start = scenario.start, known.contains(start) { visit(start) }
        let reached = Set(order)

        // Column: the longest line from the start, loops ignored.
        var column: [String: Int] = [:]
        for id in order { column[id] = 0 }
        var changed = true
        var rounds = 0
        while changed && rounds <= scenario.nodes.count {
            changed = false
            rounds += 1
            for id in order {
                for child in next[id] ?? [] where !back.contains(id + ">" + child) && reached.contains(child) {
                    if (column[child] ?? 0) < (column[id] ?? 0) + 1 { column[child] = (column[id] ?? 0) + 1; changed = true }
                }
            }
        }

        // Row: a step continues the row of the first line out of its parent; every other line starts a new row.
        // A row is one chain: it starts at a step that gets a fresh row, and only the first unplaced child of a step continues the
        // step's row. Every step on the chain has a larger column than its parent (back edges are ignored), so no two steps share a cell.
        var row: [String: Int] = [:]
        var lastRow = -1
        func place(_ id: String, preferred: Int) {
            row[id] = preferred
            lastRow = max(lastRow, preferred)
        }
        func descend(_ id: String) {
            var first = true
            for child in next[id] ?? [] where !back.contains(id + ">" + child) && row[child] == nil {
                place(child, preferred: first ? (row[id] ?? 0) : lastRow + 1)
                first = false
                descend(child)
            }
        }
        if let start = scenario.start, reached.contains(start) {
            place(start, preferred: 0)
            descend(start)
        }

        func frame(column: Int, row: Int) -> CGRect {
            CGRect(x: m.margin + CGFloat(column) * (m.nodeWidth + m.columnGap), y: m.margin + CGFloat(row) * (m.nodeHeight + m.rowGap),
                   width: m.nodeWidth, height: m.nodeHeight)
        }
        var nodes: [Node] = []
        for step in scenario.nodes where reached.contains(step.id) {
            nodes.append(Node(id: step.id, frame: frame(column: column[step.id] ?? 0, row: row[step.id] ?? 0), column: column[step.id] ?? 0, row: row[step.id] ?? 0, loose: false))
        }
        // Steps nothing leads to: rows below the graph, side by side, so they can still be picked and connected.
        let looseRow = lastRow + 1
        var looseColumn = 0
        for step in scenario.nodes where !reached.contains(step.id) && !nodes.contains(where: { $0.id == step.id }) {
            nodes.append(Node(id: step.id, frame: frame(column: looseColumn, row: looseRow + 1), column: looseColumn, row: looseRow + 1, loose: true))
            looseColumn += 1
        }

        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var edges: [Edge] = []
        var drawn = Set<String>()
        for edge in scenario.edges {
            guard let from = byID[edge.from], let to = byID[edge.to], edge.from != edge.to, drawn.insert(edge.from + ">" + edge.to).inserted else { continue }
            let back = from.frame.maxX > to.frame.minX
            let p0 = CGPoint(x: back ? from.frame.midX : from.frame.maxX, y: back ? from.frame.maxY : from.frame.midY)
            let p3 = CGPoint(x: back ? to.frame.midX : to.frame.minX, y: back ? to.frame.maxY : to.frame.midY)
            let reach = max(abs(p3.x - p0.x) * 0.5, 24)
            let curve = back
                ? [p0, CGPoint(x: p0.x, y: p0.y + 40), CGPoint(x: p3.x, y: p3.y + 40), p3]
                : [p0, CGPoint(x: p0.x + reach, y: p0.y), CGPoint(x: p3.x - reach, y: p3.y), p3]
            let middle = QAGraphLayout.point(on: curve, at: 0.5)
            edges.append(Edge(from: edge.from, to: edge.to, label: edge.label, curve: curve, labelPoint: middle))
        }

        let width = (nodes.map(\.frame.maxX).max() ?? 0) + m.margin
        let height = (nodes.map(\.frame.maxY).max() ?? 0) + m.margin + 44
        return QAGraphLayout(nodes: nodes, edges: edges, size: CGSize(width: max(width, 2 * m.margin), height: max(height, 2 * m.margin)), metrics: m)
    }

    // MARK: Curves

    static func point(on curve: [CGPoint], at t: CGFloat) -> CGPoint {
        guard curve.count == 4 else { return curve.first ?? .zero }
        let u = 1 - t
        let x = u * u * u * curve[0].x + 3 * u * u * t * curve[1].x + 3 * u * t * t * curve[2].x + t * t * t * curve[3].x
        let y = u * u * u * curve[0].y + 3 * u * u * t * curve[1].y + 3 * u * t * t * curve[2].y + t * t * t * curve[3].y
        return CGPoint(x: x, y: y)
    }

    static func flatten(_ curve: [CGPoint], steps: Int = 18) -> [CGPoint] {
        (0...steps).map { point(on: curve, at: CGFloat($0) / CGFloat(steps)) }
    }

    static func distance(from p: CGPoint, toPolyline line: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<max(line.count - 1, 0) {
            let a = line[index], b = line[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }
}
