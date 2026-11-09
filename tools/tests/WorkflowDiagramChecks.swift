import CoreGraphics
import Foundation

// BUG-112: the state diagram of a transition table. Run through tools/tests/workflow-diagram-tests.sh.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

let standard = ProjectWorkflow.standard
let feature = standard.feature, bug = standard.bug
let diagram = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: 920)

// MARK: Lanes and states

check(diagram.lanes.map(\.role) == [.notStarted, .active, .completed, .cancelled], "a feature has four lanes, in the order of a piece of work's life",
      "\(diagram.lanes.map(\.role))")
check(diagram.nodes.count == feature.statuses.count, "every status is a state (\(diagram.nodes.count) of \(feature.statuses.count))")
check(diagram.size.width <= 920 + 0.5, "the diagram fits the width it was given (\(Int(diagram.size.width)) of 920)")
let frames = diagram.nodes.map(\.frame)
var overlaps = 0
for i in frames.indices { for j in frames.indices where j > i && frames[i].intersects(frames[j]) { overlaps += 1 } }
check(overlaps == 0, "no two states overlap")
check(diagram.nodes.allSatisfy { node in diagram.lanes.first { $0.role == node.role }?.frame.contains(node.frame) == true },
      "every state lies inside the frame of its lane")
var laneOverlaps = 0
for i in diagram.lanes.indices { for j in diagram.lanes.indices where j > i && diagram.lanes[i].frame.intersects(diagram.lanes[j].frame) { laneOverlaps += 1 } }
check(laneOverlaps == 0, "no two lanes overlap")
let order = feature.statuses.filter { $0.role == .notStarted }.map(\.id)
let stacked = diagram.nodes.filter { $0.role == .notStarted }.map(\.id)
check(order == stacked, "the states of a lane keep the order of the statuses", "\(stacked)")
let spec = diagram.nodes.filter { $0.role == .notStarted }.sorted { $0.frame.minY < $1.frame.minY }
check(spec.map(\.id) == order, "…from top to bottom")

// MARK: Arrows

check(diagram.arrows.count == feature.rules.count && diagram.unattached.isEmpty, "every rule is one arrow (\(diagram.arrows.count) of \(feature.rules.count))")
let allPoints = diagram.arrows.flatMap { $0.branches.flatMap { $0.tails.flatMap { $0 } + $0.stub } }
check(allPoints.allSatisfy { $0.x >= -40 && $0.y >= -40 && $0.x <= diagram.size.width + 40 && $0.y <= diagram.size.height + 40 },
      "no arrow leaves the drawing")

let specLane = diagram.lanes[0]
check(specLane.entryRules.count == 6 && specLane.bar != nil && specLane.isClique, "the six specification stages are entered from one bar (\"any order\")",
      "\(specLane.entryRules)")
let entryArrows = diagram.arrows.filter { specLane.entryRules.contains($0.rule) }
check(entryArrows.allSatisfy { $0.branches.count == 1 && $0.branches[0].isEntry && $0.branches[0].tails.isEmpty },
      "…each by a short arrow without tails (30 curves would be unreadable)")

func arrow(_ kind: TransitionKind, to: String, in rules: [LifecycleRule] = feature.rules, drawn: WorkflowDiagram = diagram) -> WorkflowDiagram.Arrow? {
    guard let index = rules.firstIndex(where: { $0.kind == kind && $0.to == to }) else { return nil }
    return drawn.arrows.first { $0.rule == index }
}
if let cancel = arrow(.cancellation, to: "archived") {
    check(cancel.branches.count == 1 && cancel.branches[0].tails.count == 3,
          "the cancellation from every status has one tail from the specification lane, one from the completed lane and one from the active state",
          "\(cancel.branches.map(\.tails.count))")
} else { check(false, "the cancellation arrow exists") }
if let start = arrow(.start, to: "implementing") {
    check(start.branches.count == 1 && start.branches[0].tails.count == 5 && start.branches[0].pointsRight,
          "the start from five specification stages is one arrow with five tails, entering from the left")
} else { check(false, "the start arrow exists") }
if let reopen = arrow(.reopen, to: "implementing") {
    check(reopen.branches.count == 1 && !reopen.branches[0].pointsRight && reopen.branches[0].tails.count == 1,
          "reopening a completed feature enters the active state from the right, from one tail that stands for the two completed states")
} else { check(false, "the reopen arrow exists") }
let ready = diagram.nodes.first { $0.id == "ready" }!
let rightTips = diagram.arrows.flatMap(\.branches).filter { !$0.pointsRight && abs($0.tip.x - ready.frame.maxX) < 0.01 && ready.frame.contains(CGPoint(x: ready.frame.midX, y: $0.tip.y)) }.map(\.tip)
check(rightTips.count == 2 && Set(rightTips.map { Int($0.y.rounded()) }).count == 2,
      "two arrows that end on the right side of one state end at different heights", "\(rightTips)")

// Entries into only some states of a lane are not "any order".
let some = [LifecycleRule(from: ["idea", "draft", "review", "resolving", "exploring"], to: "ready", kind: .spec, needs: [.human: []])]
let someDiagram = WorkflowDiagram(statuses: feature.statuses, rules: some, width: 920)
check(someDiagram.lanes[0].bar != nil && !someDiagram.lanes[0].isClique, "a bar with an entry into one state only is not marked \"any order\"")
// Room right of the last lane is kept when an arrow meets a state of it on that side (the bug workflow's acceptance, within its completed lane).
let bugOnly = WorkflowDiagram(statuses: bug.statuses, rules: bug.rules, width: 760)
let bugOutermost = bugOnly.nodes.map(\.frame.maxX).max() ?? 0
check(bugOnly.size.width - bugOutermost >= 60, "there is room right of the last lane for the curves on that side (\(Int(bugOnly.size.width - bugOutermost)) pt)")
let outermost = diagram.nodes.map(\.frame.maxX).max() ?? 0
check(diagram.size.width - outermost < 30, "…and none where no arrow needs it (\(Int(diagram.size.width - outermost)) pt)")

// A rule whose sources are on both sides of its target is two branches of one arrow.
let mixed = [LifecycleRule(from: ["draft", "verified"], to: "implementing", kind: .spec, needs: [.human: []])]
let mixedDiagram = WorkflowDiagram(statuses: feature.statuses, rules: mixed, width: 920)
check(mixedDiagram.arrows.first?.branches.count == 2, "sources on both sides of the target make two branches of one arrow",
      "\(mixedDiagram.arrows.first?.branches.count ?? -1)")

// A rule that cannot be drawn is not lost.
let broken = [LifecycleRule(from: [], to: "ready", kind: .spec, needs: [:]),
              LifecycleRule(from: ["draft"], to: "gone", kind: .spec, needs: [:]),
              LifecycleRule(from: ["draft"], to: "ready", kind: .spec, needs: [.human: []])]
let brokenDiagram = WorkflowDiagram(statuses: feature.statuses, rules: broken, width: 920)
check(brokenDiagram.unattached == [0, 1] && brokenDiagram.arrows.map(\.rule) == [2], "a rule without a source or with an unknown status is listed apart",
      "\(brokenDiagram.unattached) \(brokenDiagram.arrows.map(\.rule))")

// MARK: Bugs, narrow and wide

let bugDiagram = WorkflowDiagram(statuses: bug.statuses, rules: bug.rules, width: 760)
check(bugDiagram.lanes.map(\.role) == [.notStarted, .active, .completed], "a bug has three lanes, no cancelled one (closed is a completed status)",
      "\(bugDiagram.lanes.map(\.role))")
check(bugDiagram.arrows.count == bug.rules.count && bugDiagram.lanes.allSatisfy { $0.bar == nil }, "its rules are all drawn, and none needs a bar")
// The diagram grows with the tab and is cut down to fit a narrow one: the zoom is what makes it fit.
for width in [320, 400, 760, 1100, 1500] as [CGFloat] {
    let zoom = WorkflowDiagram.zoom(statuses: feature.statuses, rules: feature.rules, available: width)
    let d = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: width, metrics: WorkflowDiagram.Metrics(zoom: zoom))
    let widest = d.nodes.map(\.frame.width).max() ?? 0
    check(zoom <= 0.4 + 0.001 || d.size.width <= width + 0.5, "at \(width) pt the zoom is \(String(format: "%.2f", zoom)) and the diagram is \(Int(d.size.width)) pt wide, \(Int(d.size.height)) tall")
    check(widest <= 168 * zoom + 0.01 && d.nodes.allSatisfy { $0.frame.height == 28 * zoom }, "…its states are \(Int(widest)) pt wide and 28 zoom-lengths tall")
}
let small = WorkflowDiagram.zoom(statuses: feature.statuses, rules: feature.rules, available: 700)
let large = WorkflowDiagram.zoom(statuses: feature.statuses, rules: feature.rules, available: 1400)
let huge = WorkflowDiagram.zoom(statuses: feature.statuses, rules: feature.rules, available: 6000)
check(small < 1 && large > 1.4 && large > small, "a wide tab draws the diagram larger than a narrow one (\(small) → \(large))")
check(huge <= 2.2 + 0.001 && WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: 6000, metrics: .init(zoom: huge)).size.height <= 700 + 0.5,
      "…but never larger than 2.2 times or taller than 700 pt (\(huge))")
let doubled = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: 1800, metrics: .init(zoom: 2))
let basic = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: 900, metrics: .init())
check(abs(doubled.nodes[0].frame.height - 2 * basic.nodes[0].frame.height) < 0.01
      && abs(doubled.lanes[0].frame.height - 2 * basic.lanes[0].frame.height) < 0.01
      && abs(doubled.arrows[0].branches[0].stub[0].x - doubled.arrows[0].branches[0].tip.x) > 1.9 * abs(basic.arrows[0].branches[0].stub[0].x - basic.arrows[0].branches[0].tip.x),
      "every length of the drawing grows with the zoom: states, lanes, the last piece of an arrow")
check(diagram.metrics.zoom == 1 && doubled.metrics.zoom == 2, "the diagram knows its zoom, for the text sizes and line widths drawn over it")
let gaps = zip(basic.nodes.filter { $0.role == .notStarted }, basic.nodes.filter { $0.role == .notStarted }.dropFirst()).map { $1.frame.minY - $0.frame.maxY }
check(gaps.allSatisfy { $0 >= 20 }, "the specification stages are at least 20 pt apart, where the curves fan out (\(gaps))")

// MARK: The widest workflow

var wide = feature
let ids = Set(wide.statuses.map(\.id))
wide.rules = wide.rules.map { var r = $0; r.from = ids.subtracting([r.to]); return r }
let wideDiagram = WorkflowDiagram(statuses: wide.statuses, rules: wide.rules, width: 920)
check(wideDiagram.arrows.count == wide.rules.count, "every transition from every status is still drawn, and once per rule")
let tailCount = wideDiagram.arrows.flatMap(\.branches).reduce(0) { $0 + $1.tails.count }
check(tailCount < wide.rules.count * 8, "…with lane tails instead of a curve per status (\(tailCount) curves for \(wide.rules.count) rules)")

// MARK: Hit testing

if let cancel = arrow(.cancellation, to: "archived") {
    let stub = cancel.branches[0].stub
    let middle = CGPoint(x: (stub[0].x + stub[1].x) / 2, y: (stub[0].y + stub[1].y) / 2)
    check(diagram.rule(near: middle) == cancel.rule, "a point on the last piece of an arrow hits its rule")
    let tail = cancel.branches[0].tails[1]
    check(diagram.rule(near: tail[tail.count / 2]) == cancel.rule, "…and so does a point on one of its curves")
    check(diagram.rule(near: CGPoint(x: middle.x, y: middle.y + 60)) == nil, "a point away from every arrow hits nothing")
}
if let node = diagram.nodes.first(where: { $0.id == "implementing" }) {
    check(diagram.node(at: CGPoint(x: node.frame.midX, y: node.frame.midY))?.id == "implementing", "a point inside a state hits the state")
    check(diagram.node(at: CGPoint(x: -5, y: -5)) == nil, "a point outside every state hits none")
}

// MARK: What an arrow drawn between two states means

func kind(_ from: String, _ to: String, in lifecycle: IssueLifecycleDefinition = feature) -> TransitionKind {
    WorkflowDiagram.inferredKind(from: lifecycle.status(from)!, to: lifecycle.status(to)!, statuses: lifecycle.statuses)
}
check(kind("draft", "ready") == .spec, "specification stage to specification stage is a specification step")
check(kind("ready", "implementing") == .start, "not started to active starts the work")
check(kind("implementing", "implemented") == .completion, "active to completed completes it")
check(kind("draft", "implemented") == .completion, "…also from a stage that was never started")
check(kind("implemented", "verified") == .acceptance, "completed to a later completed status accepts it")
check(kind("verified", "implemented") == .reopen, "…and back to an earlier one reopens it")
check(kind("implemented", "implementing") == .reopen, "completed to active reopens")
check(kind("implementing", "ready") == .rollback, "active to not started steps back")
check(kind("verified", "archived") == .cancellation, "anything to a cancelled status cancels")
check(kind("archived", "draft") == .reopen, "a cancelled status to a living one reopens")

var rules = feature.rules
let before = rules.count
let merged = WorkflowDiagram.connect("idea", "implementing", statuses: feature.statuses, rules: &rules)
let startIndex = feature.rules.firstIndex { $0.kind == .start && $0.to == "implementing" }
check(merged == startIndex && rules.count == before && rules[startIndex!].from.contains("idea"),
      "an arrow of the same kind into the same state joins the rule that is there (idea now starts the work too)")
let again = WorkflowDiagram.connect("idea", "implementing", statuses: feature.statuses, rules: &rules)
check(again == startIndex && rules == { var r = feature.rules; r[startIndex!].from.insert("idea"); return r }(), "…and drawing it twice changes nothing more")
let added = WorkflowDiagram.connect("implementing", "draft", statuses: feature.statuses, rules: &rules)
check(added == rules.count - 1 && rules.count == before + 1 && rules[added!].kind == .rollback && rules[added!].needs[.human] == [.reason],
      "a step no rule has is a new rule, with a person and the evidence its kind needs")
check(WorkflowDiagram.connect("draft", "draft", statuses: feature.statuses, rules: &rules) == nil, "an arrow from a state to itself is no arrow")
check(WorkflowDiagram.connect("draft", "gone", statuses: feature.statuses, rules: &rules) == nil, "…nor one to a status the type does not have")
var edited = ProjectWorkflow.standard
var table = edited.feature.rules
WorkflowDiagram.connect("implementing", "implemented", statuses: edited.feature.statuses, rules: &table)
edited.feature.rules = table
check(edited.validate().isEmpty, "a workflow edited by drawing an existing arrow again is still valid", "\(edited.validate().map(\.message))")

// MARK: Lane titles (feature workflow-flows, REQ-002)

check(WorkflowDiagram.laneTitle(.notStarted, statuses: feature.statuses, rules: feature.rules) == "Backlog & specification",
      "the waiting lane of the MarkView feature flow, six states joined by stage changes, is the backlog and specification")
check(WorkflowDiagram.laneTitle(.notStarted, statuses: bug.statuses, rules: bug.rules) == "To do", "a bug's single waiting state is just 'To do'")
let kanbanWaiting = [WorkflowStatus(id: "backlog", role: .notStarted), WorkflowStatus(id: "ready", role: .notStarted), WorkflowStatus(id: "doing", role: .active)]
let kanbanRules = [LifecycleRule(from: ["backlog"], to: "ready", kind: .spec, needs: [.human: []]), LifecycleRule(from: ["ready"], to: "backlog", kind: .spec, needs: [.human: []])]
check(WorkflowDiagram.laneTitle(.notStarted, statuses: kanbanWaiting, rules: kanbanRules) == "To do", "two waiting states (Backlog, Ready) are 'To do', not a specification")
check(WorkflowDiagram.laneTitle(.active, statuses: feature.statuses, rules: feature.rules) == "In progress"
      && WorkflowDiagram.laneTitle(.completed, statuses: feature.statuses, rules: feature.rules) == "Done"
      && WorkflowDiagram.laneTitle(.cancelled, statuses: feature.statuses, rules: feature.rules) == "Cancelled", "active, completed and cancelled lanes are In progress, Done and Cancelled")
check(TransitionKind.spec.editorTitle == "Stage change", "the step between stages is a 'Stage change', which also fits a flow without a specification")

// MARK: Names of the arrows (BUG-116)

var lifecycles: [(String, IssueLifecycleDefinition)] = [("standard feature", ProjectWorkflow.standard.feature), ("standard bug", ProjectWorkflow.standard.bug)]
for flow in WorkflowFlow.catalogue where flow.id != "markview" {
    lifecycles.append((flow.title + " features", flow.feature))
    if flow.bugsDiffer { lifecycles.append((flow.title + " bugs", flow.bug)) }
}
for (name, definition) in lifecycles {
    for width in [368, 640, 920] as [CGFloat] {
        let drawn = WorkflowDiagram(statuses: definition.statuses, rules: definition.rules, width: width)
        let bounds = CGRect(origin: .zero, size: drawn.size)
        let branches = drawn.arrows.flatMap(\.branches).filter { !$0.isEntry }.count
        var onNode = 0, together = 0, outside = 0, offLine = 0, onHead = 0
        for (i, label) in drawn.labels.enumerated() {
            if drawn.nodes.contains(where: { $0.frame.intersects(label.frame) }) { onNode += 1 }
            if !bounds.contains(label.frame) { outside += 1 }
            for other in drawn.labels[(i + 1)...] where other.frame.insetBy(dx: -3, dy: -3).intersects(label.frame) { together += 1 }
            if drawn.arrows.contains(where: { $0.branches.contains { abs($0.tip.x - label.anchor.x) < 8 && abs($0.tip.y - label.anchor.y) < 8 } }) { onHead += 1 }
            let line = drawn.arrows.first { $0.rule == label.rule }?.branches.flatMap { $0.tails + [$0.stub] }
            // The anchor is a point of its own arrow: a point of a curve, or of a straight piece between two of its points.
            let near = line?.contains { piece in
                piece.indices.contains { j in
                    j > 0 ? WorkflowDiagram.distance(from: label.anchor, toPolyline: [piece[j - 1], piece[j]]) < 0.5 : false
                }
            } ?? false
            if !near { offLine += 1 }
        }
        check(drawn.labels.count == branches, "\(name) @ \(Int(width)): every branch of every arrow has its name", "\(drawn.labels.count) of \(branches)")
        check(onNode == 0, "\(name) @ \(Int(width)): no name lies on a state", "\(onNode)")
        check(together == 0, "\(name) @ \(Int(width)): no two names lie on or touch one another", "\(together)")
        check(outside == 0, "\(name) @ \(Int(width)): every name is inside the drawing", "\(outside)")
        check(offLine == 0, "\(name) @ \(Int(width)): every name is centred on its own arrow", "\(offLine)")
        check(onHead == 0, "\(name) @ \(Int(width)): no name covers an arrowhead", "\(onHead)")
    }
}
let sparse = WorkflowDiagram(statuses: ProjectWorkflow.standard.bug.statuses, rules: [], width: 920)
let busy = WorkflowFlow.kanban.feature
let kanbanDiagram = WorkflowDiagram(statuses: busy.statuses, rules: busy.rules, width: 920)
let noRules = WorkflowDiagram(statuses: busy.statuses, rules: [], width: 920)
check(kanbanDiagram.size.height > noRules.size.height + 60, "the same states are drawn taller when ten transitions run between them",
      "\(Int(noRules.size.height)) → \(Int(kanbanDiagram.size.height))")
check(sparse.labels.isEmpty, "a diagram without transitions has no names")
check(kanbanDiagram.size.height >= 280, "Kanban gives its ten transitions room (\(Int(kanbanDiagram.size.height)) pt)")
check(kanbanDiagram.size.height < 420, "…but not absurdly tall (Kanban, \(Int(kanbanDiagram.size.height)) pt)")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
