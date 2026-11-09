import CoreGraphics
import Foundation

// The state diagram of one transition table (BUG-112): the statuses of a type as states, the transitions as arrows. This file is the
// pure part, Foundation and CoreGraphics only, so tools/tests/workflow-diagram-tests.sh compiles it on its own: where each state and
// arrow is drawn, which arrow a click hit, and what an arrow drawn between two states means as a transition. Nothing here is stored:
// the diagram is another view of the same `LifecycleRule` values that `.dde/workflow/workflow.json` holds.
//
// Layout. One column ("lane") per status role, in the order of a piece of work's life: not started, active, completed, cancelled.
// The states of a lane are stacked in the order of the statuses. One rule is one arrow: a curve from each of its sources to a
// junction just before the target, and one arrowhead, so a step that may start from five statuses reads as one step. Two shapes
// would be unreadable if every pair were drawn, so they are drawn once:
//   * a lane (of two or more states) that a rule covers completely is one tail from the lane's frame, not one per state (the
//     cancellation of a feature starts from every specification stage);
//   * the states of a lane that may each be entered from every other state of that lane (the specification stages) are entered
//     from a bar on the lane's left edge, one short arrow per state, and the lane is marked "any order".

struct WorkflowDiagram {
    struct Metrics {
        var nodeHeight: CGFloat = 28
        /// The vertical gap between the states of a lane: the curves between the lanes fan out in it.
        var nodeGap: CGFloat = 22
        var lanePadding: CGFloat = 12
        /// The left padding of a lane that has a bar for entries from its own states.
        var entryPadding: CGFloat = 26
        var laneHeader: CGFloat = 30
        var laneBottom: CGFloat = 12
        var gutter: CGFloat = 84
        /// Wider windows widen the gaps between the lanes, where the curves and their names need room, up to this.
        var maxGutter: CGFloat = 190
        /// The straight last piece of an arrow, from its junction to the state.
        var stub: CGFloat = 34
        var minNodeWidth: CGFloat = 108
        var maxNodeWidth: CGFloat = 168
        /// How far apart arrows that meet the same side of a state are.
        var slot: CGFloat = 10
        /// Room right of the last lane for the curves that leave and enter its states on that side, and for their names.
        var rightMargin: CGFloat = 70
        /// Where the bar of a lane's own entries stands, from the lane's left edge.
        var barInset: CGFloat = 7
        /// How many times larger than the basic size this is drawn: the lengths above already include it; drawing code that has
        /// lengths of its own (text sizes, line widths) multiplies them by it.
        var zoom: CGFloat = 1

        init() {}

        /// The metrics of a drawing `zoom` times as large: every length grows and nothing else changes.
        init(zoom: CGFloat) {
            nodeHeight *= zoom; nodeGap *= zoom; lanePadding *= zoom; entryPadding *= zoom; laneHeader *= zoom; laneBottom *= zoom
            gutter *= zoom; maxGutter *= zoom; stub *= zoom; minNodeWidth *= zoom; maxNodeWidth *= zoom; slot *= zoom
            rightMargin *= zoom; barInset *= zoom
            self.zoom = zoom
        }
    }

    struct Node: Identifiable, Equatable {
        let id: String
        let title: String
        let role: LifecycleRole
        let frame: CGRect
    }

    struct Lane: Identifiable, Equatable {
        let role: LifecycleRole
        let frame: CGRect
        /// The rules whose arrows enter a state of this lane from the lane's own bar.
        let entryRules: [Int]
        /// The vertical extent of that bar, when there is one.
        let bar: ClosedRange<CGFloat>?
        /// Every state of the lane is entered from the bar: the states may be taken in any order.
        let isClique: Bool
        var id: LifecycleRole { role }
    }

    /// The part of an arrow that ends at one side of the target: the curves from its sources, the junction they meet in, and the
    /// last straight piece with the arrowhead.
    struct Branch: Equatable {
        let tails: [[CGPoint]]
        /// From the junction to the tip.
        let stub: [CGPoint]
        let tip: CGPoint
        /// Whether the arrow moves to the right at its tip (it enters the target from the left).
        let pointsRight: Bool
        /// A short arrow from the bar of the target's own lane (no tails).
        let isEntry: Bool
    }

    struct Arrow: Identifiable, Equatable {
        /// The index of the rule in the table.
        let rule: Int
        let kind: TransitionKind
        let branches: [Branch]
        var id: Int { rule }
    }

    let lanes: [Lane]
    let nodes: [Node]
    let arrows: [Arrow]
    /// Rules that cannot be drawn: no source, or a status the type does not have. They are still edited from the list under the diagram.
    let unattached: [Int]
    let size: CGSize
    let metrics: Metrics

    init(statuses: [WorkflowStatus], rules: [LifecycleRule], width: CGFloat, metrics: Metrics = Metrics()) {
        self = Self.build(statuses: statuses, rules: rules, width: width, m: metrics)
    }

    private init(lanes: [Lane], nodes: [Node], arrows: [Arrow], unattached: [Int], size: CGSize, metrics: Metrics) {
        self.metrics = metrics
        self.lanes = lanes
        self.nodes = nodes
        self.arrows = arrows
        self.unattached = unattached
        self.size = size
    }

    /// How many times larger than the basic size the diagram is drawn in a tab `available` wide: as large as fits the width (and not
    /// taller than `maxHeight`, or larger than `maxZoom` times), or smaller when the tab is narrower than the basic size.
    static func zoom(statuses: [WorkflowStatus], rules: [LifecycleRule], available: CGFloat, maxHeight: CGFloat = 700, maxZoom: CGFloat = 2.2) -> CGFloat {
        // Width 0 asks for the narrowest layout there is: the smallest states and gaps.
        let basic = WorkflowDiagram(statuses: statuses, rules: rules, width: 0)
        guard basic.size.width > 0, basic.size.height > 0 else { return 1 }
        return max(0.4, min(available / basic.size.width, maxHeight / basic.size.height, maxZoom))
    }

    // MARK: Hit testing

    func node(at point: CGPoint) -> Node? { nodes.first { $0.frame.contains(point) } }

    /// The rule of the arrow nearest to `point`, when one passes within `tolerance`.
    func rule(near point: CGPoint, tolerance: CGFloat = 6) -> Int? {
        var best: (rule: Int, distance: CGFloat)?
        for arrow in arrows {
            for branch in arrow.branches {
                for line in branch.tails + [branch.stub] {
                    let d = Self.distance(from: point, toPolyline: line)
                    if d <= tolerance, d < (best?.distance ?? .infinity) { best = (arrow.rule, d) }
                }
            }
        }
        return best?.rule
    }

    private static func distance(from p: CGPoint, toPolyline line: [CGPoint]) -> CGFloat {
        guard line.count > 1 else { return line.first.map { hypot($0.x - p.x, $0.y - p.y) } ?? .infinity }
        var best = CGFloat.infinity
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            let t = length2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
            best = min(best, hypot(a.x + t * dx - p.x, a.y + t * dy - p.y))
        }
        return best
    }

    // MARK: Layout

    private enum Side: Hashable { case left, right }
    private struct Slot: Hashable { let key: String; let side: Side }
    private struct End { let key: String; let side: Side; let slot: Int }
    private struct BranchPlan { var tails: [End]; var head: End; var entry: Bool }

    private static func build(statuses all: [WorkflowStatus], rules: [LifecycleRule], width: CGFloat, m: Metrics) -> WorkflowDiagram {
        var seen = Set<String>()
        let statuses = all.filter { seen.insert($0.id).inserted }
        let order: [LifecycleRole] = [.notStarted, .active, .completed, .cancelled]
        var members: [LifecycleRole: [WorkflowStatus]] = [:]
        for status in statuses { members[status.role, default: []].append(status) }
        let roles = order.filter { !(members[$0] ?? []).isEmpty }
        guard !roles.isEmpty else { return WorkflowDiagram(lanes: [], nodes: [], arrows: [], unattached: Array(rules.indices), size: .zero, metrics: m) }
        var laneIndex: [LifecycleRole: Int] = [:]
        for (i, role) in roles.enumerated() { laneIndex[role] = i }
        var roleOf: [String: LifecycleRole] = [:]
        var statusIndex: [String: Int] = [:]
        for (i, status) in statuses.enumerated() { roleOf[status.id] = status.role; statusIndex[status.id] = i }

        // 1. What each rule is made of, and which side of which state or lane each of its ends meets.
        var counts: [Slot: Int] = [:]
        func take(_ key: String, _ side: Side) -> End {
            let slot = Slot(key: key, side: side)
            let index = counts[slot, default: 0]
            counts[slot] = index + 1
            return End(key: key, side: side, slot: index)
        }
        var plans: [(rule: Int, kind: TransitionKind, branches: [BranchPlan])] = []
        var unattached: [Int] = []
        var entries: [LifecycleRole: [(rule: Int, node: String)]] = [:]

        for (r, rule) in rules.enumerated() {
            guard let toRole = roleOf[rule.to], let toLane = laneIndex[toRole] else { unattached.append(r); continue }
            var sources = rule.from.filter { roleOf[$0] != nil && $0 != rule.to }
            if sources.isEmpty { unattached.append(r); continue }
            var barLanes: [LifecycleRole] = []
            var entry = false
            for role in roles {
                let ids = Set((members[role] ?? []).map(\.id))
                if role == toRole {
                    // Entries from the lane's own bar replace the curves of a clique, which starts at three states.
                    if ids.count >= 3, ids.subtracting([rule.to]).isSubset(of: sources) { entry = true; sources.subtract(ids) }
                } else if ids.count >= 2, ids.isSubset(of: sources) {
                    barLanes.append(role)
                    sources.subtract(ids)
                }
            }

            var branches: [BranchPlan] = []
            if entry {
                branches.append(BranchPlan(tails: [], head: take("n:" + rule.to, .left), entry: true))
                entries[toRole, default: []].append((r, rule.to))
            }
            // The tails, in the order of the lanes and statuses; a lane's own tail comes before the states of that lane.
            var tails: [(key: String, lane: Int, order: Int)] = barLanes.map { ("l:" + $0.rawValue, laneIndex[$0] ?? 0, -1) }
            for id in sources { tails.append(("n:" + id, laneIndex[roleOf[id] ?? toRole] ?? 0, statusIndex[id] ?? 0)) }
            tails.sort { ($0.lane, $0.order) < ($1.lane, $1.order) }
            // A source to the left enters from the left; a source to the right, or in the same lane, enters from the right.
            func headSide(_ lane: Int) -> Side { lane < toLane ? .left : .right }
            func outSide(_ lane: Int) -> Side { lane > toLane ? .left : .right }
            for side in [Side.left, .right] {
                let group = tails.filter { headSide($0.lane) == side }
                guard !group.isEmpty else { continue }
                branches.append(BranchPlan(tails: group.map { take($0.key, outSide($0.lane)) },
                                           head: take("n:" + rule.to, side), entry: false))
            }
            plans.append((r, rule.kind, branches))
        }

        // 2. Lanes and states. Room right of the last lane is kept only when an arrow meets a state of it on that side.
        let lastStates = Set((members[roles[roles.count - 1]] ?? []).map { "n:" + $0.id })
        let rightMargin = counts.keys.contains { $0.side == .right && lastStates.contains($0.key) } ? m.rightMargin : m.lanePadding
        func leftPadding(_ role: LifecycleRole) -> CGFloat { entries[role] == nil ? m.lanePadding : m.entryPadding }
        let totalPadding = roles.reduce(CGFloat(0)) { $0 + leftPadding($1) + m.lanePadding }
        let laneCount = CGFloat(roles.count)
        let nodeWidth = min(m.maxNodeWidth, max(m.minNodeWidth, (width - rightMargin - (laneCount - 1) * m.gutter - totalPadding) / laneCount))
        let spare = width - rightMargin - laneCount * nodeWidth - totalPadding
        let gutter = roles.count > 1 ? min(m.maxGutter, max(m.gutter, spare / (laneCount - 1))) : m.gutter
        let tallest = roles.map { members[$0]?.count ?? 0 }.max() ?? 1
        let content = CGFloat(tallest) * m.nodeHeight + CGFloat(tallest - 1) * m.nodeGap
        let laneHeight = m.laneHeader + content + m.laneBottom
        var rects: [String: CGRect] = [:]
        var nodes: [Node] = []
        var x: CGFloat = 0
        for (laneNumber, role) in roles.enumerated() {
            let list = members[role] ?? []
            let laneWidth = leftPadding(role) + nodeWidth + m.lanePadding
            rects["l:" + role.rawValue] = CGRect(x: x, y: 0, width: laneWidth, height: laneHeight)
            let stack = CGFloat(list.count) * m.nodeHeight + CGFloat(list.count - 1) * m.nodeGap
            // Each lane sits lower than the one before it, so the work reads from the top left to the bottom right and the arrows between
            // lanes are not drawn along one another (a lane's states all at the same height would put every arrow on one line).
            var y = m.laneHeader + (content - stack) * (roles.count > 1 ? CGFloat(laneNumber) / CGFloat(roles.count - 1) : 0.5)
            for status in list {
                let frame = CGRect(x: x + leftPadding(role), y: y, width: nodeWidth, height: m.nodeHeight)
                rects["n:" + status.id] = frame
                nodes.append(Node(id: status.id, title: status.title, role: role, frame: frame))
                y += m.nodeHeight + m.nodeGap
            }
            x += laneWidth + gutter
        }
        let size = CGSize(width: x - gutter + rightMargin, height: laneHeight + 2)

        // 3. Arrows.
        func point(_ end: End) -> CGPoint {
            let rect = rects[end.key] ?? .zero
            let n = max(1, counts[Slot(key: end.key, side: end.side)] ?? 1)
            let step = min(m.slot, max(2 * m.zoom, (rect.height - 6 * m.zoom) / CGFloat(n)))
            return CGPoint(x: end.side == .left ? rect.minX : rect.maxX,
                           y: rect.midY + (CGFloat(end.slot) - CGFloat(n - 1) / 2) * step)
        }
        var barYs: [LifecycleRole: [CGFloat]] = [:]
        var arrows: [Arrow] = []
        for plan in plans {
            var branches: [Branch] = []
            for branch in plan.branches {
                let tip = point(branch.head)
                if branch.entry {
                    let role = nodes.first { "n:" + $0.id == branch.head.key }?.role ?? .notStarted
                    let barX = (rects["l:" + role.rawValue]?.minX ?? 0) + m.barInset
                    let junction = CGPoint(x: barX, y: tip.y)
                    barYs[role, default: []].append(tip.y)
                    branches.append(Branch(tails: [], stub: [junction, tip], tip: tip, pointsRight: true, isEntry: true))
                    continue
                }
                let right = branch.head.side == .left
                let junction = CGPoint(x: tip.x + (right ? -m.stub : m.stub), y: tip.y)
                let tails = branch.tails.map { end -> [CGPoint] in
                    let start = point(end)
                    let away: CGFloat = end.side == .right ? 1 : -1
                    let arrive: CGFloat = right ? 1 : -1
                    let k = min(90 * m.zoom, max(24 * m.zoom, abs(junction.x - start.x) * 0.5))
                    return flatten(start, CGPoint(x: start.x + away * k, y: start.y), CGPoint(x: junction.x - arrive * k, y: junction.y), junction)
                }
                branches.append(Branch(tails: tails, stub: [junction, tip], tip: tip, pointsRight: right, isEntry: false))
            }
            arrows.append(Arrow(rule: plan.rule, kind: plan.kind, branches: branches))
        }

        let lanes = roles.map { role -> Lane in
            let ys = barYs[role] ?? []
            return Lane(role: role, frame: rects["l:" + role.rawValue] ?? .zero, entryRules: (entries[role] ?? []).map(\.rule),
                        bar: ys.isEmpty ? nil : ((ys.min() ?? 0) - 6 * m.zoom)...((ys.max() ?? 0) + 6 * m.zoom),
                        isClique: !ys.isEmpty && ys.count == (members[role] ?? []).count)
        }
        return WorkflowDiagram(lanes: lanes, nodes: nodes, arrows: arrows, unattached: unattached, size: size, metrics: m)
    }

    private static func flatten(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, steps: Int = 18) -> [CGPoint] {
        (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }
    }
}

// MARK: - What an arrow drawn between two states means

extension WorkflowDiagram {
    /// The kind of transition a person means by an arrow from `source` to `target`, from the roles of the two statuses and, between
    /// two completed ones, from their order (implemented → verified is acceptance, verified → implemented reopens).
    static func inferredKind(from source: WorkflowStatus, to target: WorkflowStatus, statuses: [WorkflowStatus]) -> TransitionKind {
        switch (source.role, target.role) {
        case (_, .cancelled): return source.role == .cancelled ? .spec : .cancellation
        case (.cancelled, _): return .reopen
        case (.completed, .completed):
            let order = statuses.map(\.id)
            return (order.firstIndex(of: target.id) ?? 0) > (order.firstIndex(of: source.id) ?? 0) ? .acceptance : .reopen
        case (.completed, _): return .reopen
        case (_, .completed): return .completion
        case (.notStarted, .active): return .start
        case (.active, .notStarted): return .rollback
        default: return .spec
        }
    }

    /// What a new arrow of `kind` asks for by default: a person may make the step, with the evidence its kind needs.
    static func defaultNeeds(for kind: TransitionKind) -> [LifecycleActorKind: [LifecycleCondition]] {
        switch kind {
        case .start: return [.human: [.startEvidence]]
        case .completion: return [.human: [.deliveryEvidence]]
        case .reopen, .rollback: return [.human: [.reason]]
        default: return [.human: []]
        }
    }

    /// Adds the arrow a person drew from `source` to `target`. A step of the same kind into the same target already has a rule: the
    /// source joins it (the arrow now starts there too); otherwise a rule is added. Returns the index of the rule that holds the
    /// arrow, or nil when it is no arrow (the same state, or a status the type does not have).
    @discardableResult
    static func connect(_ source: String, _ target: String, statuses: [WorkflowStatus], rules: inout [LifecycleRule]) -> Int? {
        guard source != target,
              let from = statuses.first(where: { $0.id == source }), let to = statuses.first(where: { $0.id == target }) else { return nil }
        let kind = inferredKind(from: from, to: to, statuses: statuses)
        if let index = rules.firstIndex(where: { $0.to == target && $0.kind == kind }) {
            rules[index].from.insert(source)
            return index
        }
        rules.append(LifecycleRule(from: [source], to: target, kind: kind, needs: defaultNeeds(for: kind)))
        return rules.count - 1
    }
}

extension TransitionKind {
    /// The name the editor shows for a kind of step.
    var editorTitle: String {
        switch self {
        case .spec: return "Specification"
        case .start: return "Start"
        case .completion: return "Completion"
        case .acceptance: return "Acceptance"
        case .reopen: return "Reopening"
        case .rollback: return "Step back"
        case .cancellation: return "Cancellation"
        default: return rawValue
        }
    }
}
