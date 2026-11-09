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
let outermost = diagram.nodes.map(\.frame.maxX).max() ?? 0
check(diagram.size.width - outermost >= 60, "there is room right of the last lane for the curves on that side (\(Int(diagram.size.width - outermost)) pt)")

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
for width in [320, 400, 760, 1100] as [CGFloat] {
    let d = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: width)
    let narrowest = d.nodes.map(\.frame.width).min() ?? 0
    check(narrowest >= 96 - 0.01 && narrowest <= 150 + 0.01 && (width < 800 || d.size.width <= width + 0.5),
          "at \(Int(width)) pt a state is \(Int(narrowest)) pt wide and the diagram is \(Int(d.size.width)) pt")
}

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

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
