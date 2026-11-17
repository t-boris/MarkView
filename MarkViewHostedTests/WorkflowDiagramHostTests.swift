import CoreGraphics
import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

extension EditorHostTests {
    func testWorkflowDiagramGeometry() {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
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
    }
}

extension EditorHostTests {
    func testWorkflowCompletionRules() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let standard = ProjectWorkflow.standard
        let feature = standard.variant(StandardWorkflow.featureVariantID)!
        let bug = standard.variant(StandardWorkflow.bugVariantID)!
        func mark(_ done: WorkflowDone, _ name: String) -> WorkflowDone.Mark { done.marks.first { $0.name == name }! }

        // MARK: What done means

        let featureDone = WorkflowDone.make(feature, definition: nil)
        check(!mark(featureDone, "Pull request").required && !mark(featureDone, "CI checks").required && !mark(featureDone, "Release").required,
              "the standard feature process requires no pull request, no checks and no release")
        check(featureDone.sentence == "Done here means the work on the default branch, then accepted by a person or an AI with evidence.",
              "…and says so in one sentence", featureDone.sentence)

        let bugDone = WorkflowDone.make(bug, definition: nil)
        check(mark(bugDone, "Pull request").required && mark(bugDone, "CI checks").required, "the standard bug process requires a pull request and passing checks")
        check(bugDone.sentence == "Done here means a merged pull request and passing checks, then accepted by a person or an AI with evidence.", "…in one sentence", bugDone.sentence)

        let strict = RuleVariant(id: "strict", name: "Strict", kind: .feature, integration: .pullRequest, checks: true, delivery: .githubRelease, acceptance: .humanOnly)
        let strictDone = WorkflowDone.make(strict, definition: nil)
        check(strictDone.sentence == "Done here means a merged pull request, passing checks and a published GitHub release, then accepted by a person.",
              "a pull request, checks, a release and a person's acceptance are all named", strictDone.sentence)
        check(mark(strictDone, "Release").required && mark(strictDone, "Acceptance").detail == "Only a person accepts", "…each mark has its detail")

        let confirmed = RuleVariant(id: "installed", name: "Installed", kind: .feature, integration: .directToMain, checks: false,
                                    delivery: .humanConfirmed(name: "installed on the other Mac"))
        let confirmedDone = WorkflowDone.make(confirmed, definition: nil)
        check(mark(confirmedDone, "Delivery event").detail == "A person confirms: installed on the other Mac" && confirmedDone.sentence.contains("a person's confirmation: installed on the other Mac"),
              "an event a person confirms is named", confirmedDone.sentence)

        var byAI = confirmed
        byAI.confirmer = .personOrAI
        let byAIDone = WorkflowDone.make(byAI, definition: nil)
        check(mark(byAIDone, "Delivery event").detail == "A person, or an AI with its evidence, confirms: installed on the other Mac"
              && byAIDone.sentence.contains("a confirmation by a person or an AI with evidence: installed on the other Mac"),
              "an event that an AI may confirm says so", byAIDone.sentence)

        // A flow whose only completed status is Done has no acceptance step.
        let noStep = WorkflowDone.make(feature, definition: nil, acceptanceStep: false)
        check(!mark(noStep, "Acceptance").required && noStep.sentence == "Done here means the work on the default branch.",
              "without an acceptance step nobody accepts afterwards", noStep.sentence)

        // MARK: Where the Definition of Done disagrees

        let checklist = DefinitionOfDone.standard   // a pull request and green CI required, merge asked, deploy skipped
        check(WorkflowDone.make(feature, definition: checklist).warnings.count == 2,
              "the standard checklist requires a pull request and CI, the standard feature process does not: two warnings",
              "\(WorkflowDone.make(feature, definition: checklist).warnings)")
        check(WorkflowDone.make(bug, definition: checklist).warnings.isEmpty, "…and the standard bug process agrees with it")
        check(WorkflowDone.make(feature, definition: nil).warnings.isEmpty, "no checklist, no warning")

        var relaxed = DefinitionOfDone.standard
        for index in relaxed.items.indices where ["pr", "ci"].contains(relaxed.items[index].id) { relaxed.items[index].mode = .skip }
        check(WorkflowDone.make(strict, definition: relaxed).warnings.count == 2, "a checklist that skips a pull request and CI disagrees with a process that requires them",
              "\(WorkflowDone.make(strict, definition: relaxed).warnings)")
        for index in relaxed.items.indices where ["pr", "ci"].contains(relaxed.items[index].id) { relaxed.items[index].mode = .ask }
        check(WorkflowDone.make(feature, definition: relaxed).warnings.isEmpty, "'ask me' is a question, not a requirement either way")
        var deploy = DefinitionOfDone.standard
        for index in deploy.items.indices where deploy.items[index].id == "deploy" { deploy.items[index].mode = .require }
        check(WorkflowDone.make(bug, definition: deploy).warnings == ["The Definition of Done requires a build and deploy, but this process has no delivery event."],
              "a required deploy against a process without a delivery event", "\(WorkflowDone.make(bug, definition: deploy).warnings)")

        // MARK: Where in the transitions

        let steps = WorkflowDone.steps(in: standard.feature)
        check(steps.delivery == "Implementing → Implemented" && steps.acceptance == "Implemented → Verified",
              "delivery is judged at Implementing → Implemented and accepted at Implemented → Verified", "\(steps)")
        var noAcceptance = standard.feature
        noAcceptance.rules.removeAll { $0.kind == .acceptance }
        check(WorkflowDone.steps(in: noAcceptance).acceptance == nil, "a flow without an acceptance step names none")
        let bugSteps = WorkflowDone.steps(in: standard.bug)
        check(bugSteps.delivery == "Fixing → Fixed" && bugSteps.acceptance == "Fixed → Closed", "bugs: Fixing → Fixed, then Fixed → Closed", "\(bugSteps)")

        // MARK: GitHub (feature workflow-templates, REQ-004)

        let strictOff = WorkflowDone.make(strict, definition: nil, githubEnabled: false)
        check(strictOff.githubWarning != nil, "a process that needs GitHub warns while GitHub is not connected")
        check(strictOff.githubWarning?.contains("a merged pull request, passing checks and a published GitHub release") == true, "…naming everything it needs", strictOff.githubWarning ?? "")
        check(strictOff.githubWarning?.contains("Settings → GitHub") == true && strictOff.githubWarning?.contains("“Reaches the branch”, “Checks must pass” and “Delivery event”") == true,
              "…and both ways out: connect GitHub, or the controls that switch the requirements off", strictOff.githubWarning ?? "")
        check(WorkflowDone.make(strict, definition: nil, githubEnabled: true).githubWarning == nil, "no warning once GitHub is connected")
        check(WorkflowDone.make(strict, definition: nil).githubWarning == nil, "a caller that does not say whether GitHub is connected raises none")
        let checksOnly = RuleVariant(id: "checks", name: "Checks only", kind: .bug, integration: .directToMain, checks: true)
        check(WorkflowDone.make(checksOnly, definition: nil, githubEnabled: false).githubWarning?.contains("passing checks from GitHub") == true
              && WorkflowDone.make(checksOnly, definition: nil, githubEnabled: false).githubWarning?.contains("“Checks must pass”") == true,
              "only what is required is named")
        check(WorkflowDone.make(feature, definition: nil, githubEnabled: false).githubWarning == nil, "a process that needs nothing does not warn")
        check(WorkflowDone.make(confirmed, definition: nil, githubEnabled: false).githubWarning == nil, "a delivery event a person confirms needs no GitHub")
        check(WorkflowDone.githubNeeds(strict).map(\.control) == ["Reaches the branch", "Checks must pass", "Delivery event"], "each need names the control that switches it")

        check(featureDone.enableHint?.contains("Processes → Standard feature") == true && featureDone.enableHint?.contains("“Reaches the branch”, “Checks must pass” and “Delivery event”") == true
              && featureDone.enableHint?.contains("Settings → GitHub") == true, "a process that needs nothing says where to switch the requirements on", featureDone.enableHint ?? "")
        check(strictDone.enableHint == nil && bugDone.enableHint == nil, "…and a process that already needs GitHub does not")
    }
}

extension EditorHostTests {
    func testWorkflowFlowCatalogue() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let standard = ProjectWorkflow.standard

        // MARK: The catalogue

        check(WorkflowFlow.catalogue.map(\.id) == ["markview", "kanban", "scrum", "linear", "github-projects", "azure-agile", "shape-up", "kanban-triage"],
              "the Flow menu offers MarkView, Kanban, Scrum, Linear, GitHub Projects, Azure DevOps Agile, Shape Up and Kanban with bug triage")
        check(Set(WorkflowFlow.catalogue.map(\.id)).count == WorkflowFlow.catalogue.count && Set(WorkflowFlow.catalogue.map(\.title)).count == WorkflowFlow.catalogue.count,
              "ids and titles are different")
        for flow in WorkflowFlow.catalogue {
            let made = flow.applied(to: standard)
            let problems = made.validate().map(\.message)
            check(problems.isEmpty, "\(flow.title): the workflow it makes passes the workflow validation", problems.joined(separator: " | "))
            check(!flow.summary.isEmpty && !flow.origin.isEmpty, "\(flow.title): says what it is and where it comes from")
            for kind in [IssueKind.feature, .bug] {
                let roles = Set(flow.lifecycle(kind).statuses.map(\.role))
                check([LifecycleRole.notStarted, .active, .completed].allSatisfy(roles.contains), "\(flow.title): \(kind.rawValue) statuses have a waiting, a working and a finished state")
            }
        }

        // MARK: MarkView with specification is what every project had

        check(WorkflowFlow.markView.feature == standard.feature && WorkflowFlow.markView.bug == standard.bug, "the MarkView flow is the standard workflow, unchanged")
        check(WorkflowFlow.matching(standard)?.id == "markview", "a project on the standard workflow is recognised as MarkView with specification")

        // MARK: Kanban

        let kanban = WorkflowFlow.kanban
        func rule(_ flow: WorkflowFlow, _ id: String, _ kind: IssueKind = .feature) -> LifecycleRule? { flow.lifecycle(kind).rules.first { $0.id == id } }
        check(kanban.feature.statuses.map(\.id) == ["backlog", "ready", "in-progress", "in-review", "done", "wont-do"], "Kanban: Backlog, Ready, In progress, In review, Done, Won't do")
        check(kanban.feature.statuses.map(\.role) == [.notStarted, .notStarted, .active, .active, .completed, .cancelled], "…waiting, waiting, working, working, finished, dropped")
        check(kanban.bug == kanban.feature, "…one board for features and bugs")
        let start = rule(kanban, "backlog+ready>in-progress")
        check(start?.kind == .start && start?.needs[.system] == [.startEvidence], "work starts from Backlog or Ready into In progress, on start evidence, and MarkView may do it")
        check(rule(kanban, "in-progress>in-review")?.kind == .spec && rule(kanban, "in-review>in-progress")?.kind == .rollback, "In progress → In review, and back")
        let completion = rule(kanban, "backlog+in-progress+in-review+ready>done")
        check(completion?.kind == .completion && completion?.needs.values.allSatisfy { $0 == [.deliveryEvidence] } == true, "delivery completes the work into Done from every state before it")
        check(!kanban.feature.rules.contains { $0.kind == .acceptance }, "a board whose only finished state is Done has no acceptance step")
        check(rule(kanban, "done>in-progress")?.kind == .reopen, "Done is reopened into In progress")
        check(rule(kanban, "backlog+done+in-progress+in-review+ready>wont-do")?.kind == .cancellation && rule(kanban, "wont-do>backlog")?.kind == .reopen,
              "anything can be dropped into Won't do, and brought back to Backlog")
        check(rule(kanban, "ready>backlog")?.kind == .spec && rule(kanban, "backlog>ready")?.kind == .spec, "Backlog and Ready are free to reorder")
        check(rule(kanban, "backlog>ready")?.needs[.system] != nil, "…also for the app's own steps (a quick feature goes to Ready)")

        // MARK: Two finished states: delivery, then acceptance

        let azure = WorkflowFlow.azureAgile
        check(rule(azure, "resolved>closed")?.kind == .acceptance && rule(azure, "closed>resolved")?.kind == .reopen, "Azure DevOps: Resolved is delivered, a person or an AI accepts it into Closed")
        check(azure.bug.statuses.map(\.id) == ["new", "active", "resolved", "closed"], "…a bug has no Removed state")
        check(!azure.bug.rules.contains { $0.kind == .cancellation }, "…so a bug has no cancellation")
        let steps = WorkflowDone.steps(in: azure.feature)
        check(steps.delivery == "Active → Resolved" && steps.acceptance == "Resolved → Closed", "…and the Done panel finds both steps", "\(steps)")
        check(WorkflowDone.steps(in: kanban.feature).delivery == "In progress, In review → Done" && WorkflowDone.steps(in: kanban.feature).acceptance == nil,
              "Kanban: delivery is judged at In progress, In review → Done; there is no acceptance")

        // MARK: Bugs that differ from features

        let triage = WorkflowFlow.kanbanTriage
        check(triage.feature == kanban.feature && triage.bug.statuses.map(\.id) == ["unconfirmed", "confirmed", "in-progress", "resolved", "verified", "invalid"],
              "Kanban with bug triage: features on the board, bugs Unconfirmed → Confirmed → In progress → Resolved → Verified")
        check(rule(triage, "confirmed>unconfirmed", .bug)?.kind == .spec && rule(triage, "resolved>verified", .bug)?.kind == .acceptance, "…triage is a stage change, Verified is the acceptance")
        check(WorkflowFlow.shapeUp.bug.statuses.map(\.id) == ["reported", "fixing", "fixed", "wont-fix"], "Shape Up: bugs are Reported, Fixing, Fixed")

        // MARK: Lane titles of the flows

        func lane(_ flow: WorkflowFlow, _ role: LifecycleRole) -> String { WorkflowDiagram.laneTitle(role, statuses: flow.feature.statuses, rules: flow.feature.rules) }
        check(lane(kanban, .notStarted) == "To do" && lane(kanban, .active) == "In progress" && lane(kanban, .completed) == "Done",
              "Kanban lanes: To do, In progress, Done")
        check(lane(WorkflowFlow.linear, .notStarted) == "Backlog & specification", "Linear: three waiting states joined by free moves form one backlog lane (Triage, Backlog, Todo)")
        check(lane(WorkflowFlow.markView, .notStarted) == "Backlog & specification" && lane(WorkflowFlow.shapeUp, .notStarted) == "Backlog & specification",
              "MarkView and Shape Up: the waiting lane is where work is specified or shaped")
        check(lane(WorkflowFlow.githubProjects, .notStarted) == "To do", "GitHub Projects: a single Todo is 'To do'")

        // MARK: What the picker shows

        check(kanban.outline(.feature) == "Backlog, Ready → In progress, In review → Done (dropped: Won't do)", "Kanban outline", kanban.outline(.feature))
        check(WorkflowFlow.markView.outline(.feature) == "Idea, Exploring, Draft, Review, Resolving, Ready → Implementing → Implemented, Verified (dropped: Archived)", "MarkView outline", WorkflowFlow.markView.outline(.feature))
        check(azure.outline(.bug) == "New → Active → Resolved, Closed", "a type without a dropped state has no dropped part", azure.outline(.bug))
        check(!kanban.bugsDiffer && triage.bugsDiffer && WorkflowFlow.markView.bugsDiffer && WorkflowFlow.shapeUp.bugsDiffer, "the picker shows the bug outline only when bugs have states of their own")

        // MARK: Applying a flow to a project

        var tuned = standard
        tuned.revision = 7
        tuned.variants[1].integration = .pullRequest
        tuned.variants[1].delivery = .githubRelease
        let own = RuleVariant(id: "quick-feature", name: "Quick feature", kind: .feature, integration: .directToMain, checks: false,
                              rules: [LifecycleRule(from: ["ready"], to: "implementing", kind: .start, needs: [.human: [.startEvidence]])])
        tuned.variants.append(own)
        let moved = kanban.applied(to: tuned)
        check(moved.revision == 7 && moved.schema == tuned.schema, "applying a flow keeps the revision, so a save still notices that the file moved on")
        check(moved.name == "Kanban" && moved.feature == kanban.feature && moved.bug == kanban.bug, "…and sets the name, the statuses and the transitions")
        check(moved.variant("standard-bug")?.delivery == .githubRelease && moved.variant("standard-bug")?.integration == .pullRequest,
              "a process that follows the type keeps its settings (the bug process still needs a pull request and a release)")
        check(moved.variant("quick-feature") == nil, "a process with its own transitions is left out, they name the statuses of the old flow")
        check(moved.validate().isEmpty, "…and the result is valid", moved.validate().map(\.message).joined(separator: " | "))

        var bare = standard
        bare.variants.removeAll { $0.kind == .bug }
        let refilled = kanban.applied(to: bare)
        check(refilled.variants(for: .bug).map(\.id) == ["standard-bug"] && refilled.defaultBugVariant == "standard-bug" && refilled.validate().isEmpty,
              "a type left without a process takes the standard one")

        var lost = standard
        lost.variants.removeAll { $0.id == "standard-feature" }
        lost.variants.append(RuleVariant(id: "other-feature", name: "Other", kind: .feature, integration: .directToMain, checks: false))
        let redefaulted = kanban.applied(to: lost)
        check(redefaulted.defaultFeatureVariant == "other-feature" && redefaulted.validate().isEmpty, "a default process that no longer exists is replaced by another of its type")

        check(WorkflowFlow.matching(moved)?.id == "kanban" && WorkflowFlow.matching(WorkflowFlow.scrum.applied(to: standard))?.id == "scrum", "the flow in effect is recognised by its statuses")
        var edited = moved
        edited.feature.statuses[0].title = "Ideas"
        check(WorkflowFlow.matching(edited)?.id == "kanban", "a renamed state is still that flow (the ids and roles decide)" )

        // MARK: Flows without the specification stages

        let std = standard.feature
        check(std.hasSpecificationStages && !kanban.feature.hasSpecificationStages && !WorkflowFlow.linear.feature.hasSpecificationStages, "only the MarkView flow has the specification stages")
        check(std.entryStatus(preferring: "exploring") == "exploring" && std.entryStatus(preferring: "idea") == "idea" && std.entryStatus(preferring: "draft") == "draft",
              "a new feature keeps the stage the app asks for in the MarkView flow")
        check(kanban.feature.entryStatus(preferring: "exploring") == "backlog" && WorkflowFlow.linear.feature.entryStatus(preferring: "idea") == "triage"
              && WorkflowFlow.shapeUp.feature.entryStatus(preferring: "draft") == "raw-idea" && azure.feature.entryStatus(preferring: "exploring") == "new",
              "…and the first waiting state of a board otherwise (Backlog, Triage, Raw idea, New)")
        check(kanban.feature.entryStatus(preferring: "ready") == "ready", "a board that has the preferred state keeps it (Ready)")
        check(kanban.bug.entryStatus(preferring: "open") == "backlog" && triage.bug.entryStatus(preferring: "open") == "unconfirmed", "a new bug takes the entry of its flow")

        check(std.isPastExplore(status: "draft", requirementsApproved: true) == false && std.isPastExplore(status: "review", requirementsApproved: false) == true
              && std.isPastExplore(status: "implementing", requirementsApproved: false) == true, "with the stages, past Explore is the status, whatever the requirements")
        check(kanban.feature.isPastExplore(status: "backlog", requirementsApproved: false) == false, "Kanban: a feature in Backlog with draft requirements is still in Explore")
        check(kanban.feature.isPastExplore(status: "backlog", requirementsApproved: true) == true, "…and past it once every requirement is approved")
        check(kanban.feature.isPastExplore(status: "in-progress", requirementsApproved: false) == true && kanban.feature.isPastExplore(status: "done", requirementsApproved: false) == true,
              "…and always once work has started or is finished")
        check(kanban.feature.isPastExplore(status: "idea", requirementsApproved: false) == false, "…and a status the flow does not know is not past Explore")
    }
}

extension EditorHostTests {
    func testWorkflowTransitionStories() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let standard = ProjectWorkflow.standard
        let feature = standard.feature.rules, bug = standard.bug.rules
        func rule(_ rules: [LifecycleRule], _ kind: TransitionKind, to: String? = nil) -> LifecycleRule {
            rules.first { $0.kind == kind && (to == nil || $0.to == to) }!
        }
        func actor(_ story: TransitionStory, _ kind: LifecycleActorKind) -> TransitionStory.ActorLine { story.actors.first { $0.actor == kind }! }

        let pullRequest = RuleVariant(id: "pr", name: "Pull request, checks and a release", kind: .feature, integration: .pullRequest, checks: true,
                                      delivery: .githubRelease, acceptance: .humanOnly)
        let direct = RuleVariant(id: "direct", name: "Direct", kind: .feature, start: .agentOrNote, integration: .directToMain, checks: false)
        let installed = RuleVariant(id: "installed", name: "Installed", kind: .feature, integration: .directToMain, checks: false,
                                    delivery: .humanConfirmed(name: "installed on the other Mac"))

        // MARK: Every rule of the standard workflow has a story

        var told = 0
        for rule in feature + bug {
            let story = TransitionStory.make(rule, processes: [])
            if !story.trigger.isEmpty && !story.label.isEmpty && story.actors.count == 3 { told += 1 }
        }
        check(told == feature.count + bug.count, "every rule of the standard workflow has a trigger, a label and a line for each actor (\(told) rules)")

        // MARK: Completion is the step MarkView makes by itself

        let completion = TransitionStory.make(rule(feature, .completion), processes: [pullRequest, direct, installed])
        check(completion.automatic, "the completion step is automatic: MarkView makes it once the delivery evidence is complete")
        check(completion.label == "Completion · automatic", "…and its arrow says so", completion.label)
        check(actor(completion, .system).text.contains("as soon as the delivery evidence is complete"), "MarkView's line names the event", actor(completion, .system).text)
        check(actor(completion, .ai).text.contains("project tools") && actor(completion, .ai).text.contains("delivery evidence"),
              "an AI may make it through the project tools, with delivery evidence", actor(completion, .ai).text)
        check(completion.parts == .delivery, "completion reads the delivery settings of a process only", "\(completion.parts)")
        check(completion.processes.count == 3, "every process that follows the type has its lines")

        let prLines = completion.processes.first { $0.id == "pr" }!.lines
        check(prLines.contains { $0.contains("pull request") && $0.contains("merged") }, "a pull-request process says every unit of work is a merged pull request", "\(prLines)")
        check(prLines.contains("The required checks passed"), "…that checks must pass")
        check(prLines.contains { $0.contains("GitHub release") }, "…and that a GitHub release counts as delivery")
        let directLines = completion.processes.first { $0.id == "direct" }!.lines
        check(directLines.contains { $0.contains("default branch") && !$0.contains("pull request that GitHub") }, "a direct process accepts work on the default branch", "\(directLines)")
        check(directLines.contains("No checks are required") && directLines.contains("No delivery event"), "…with no checks and no delivery event")
        check(completion.processes.first { $0.id == "installed" }!.lines.contains("A person confirms: installed on the other Mac"),
              "an event a person confirms is named")

        // MARK: Acceptance

        let acceptance = TransitionStory.make(rule(feature, .acceptance), processes: [pullRequest, direct])
        check(!acceptance.automatic && acceptance.label == "Acceptance · person or AI", "acceptance is made by a person or an AI, not automatically", acceptance.label)
        check(actor(acceptance, .ai).text.contains("acceptance evidence"), "an AI needs acceptance evidence", actor(acceptance, .ai).text)
        check(!actor(acceptance, .system).allowed && actor(acceptance, .system).text.contains("not make"), "MarkView does not accept by itself")
        check(acceptance.parts == .acceptance, "acceptance reads who may accept")
        check(acceptance.processes.first { $0.id == "pr" }!.lines == ["Only a person accepts"], "a process that lets only a person accept says so")
        check(acceptance.processes.first { $0.id == "direct" }!.lines.first?.contains("an AI with its evidence") == true, "…and one that lets an AI accept says that")

        // MARK: Start, reopening, cancellation

        let start = TransitionStory.make(rule(feature, .start), processes: [pullRequest, direct])
        check(start.automatic && start.parts == .start, "start is automatic on a hand-off and reads how a process starts work", "\(start.label) \(start.parts)")
        check(actor(start, .system).text.contains("handed to an agent"), "…MarkView names the hand-off", actor(start, .system).text)
        check(start.processes.first { $0.id == "direct" }!.lines == ["Work starts with an agent session or a person's note"], "a process may let a person's note start the work")

        let regression = TransitionStory.make(rule(feature, .reopen, to: "implementing"), processes: [])
        check(regression.automatic && actor(regression, .system).text.contains("regression"), "a regression reopens finished work by itself", actor(regression, .system).text)
        let manualReopen = TransitionStory.make(rule(feature, .reopen, to: "implemented"), processes: [])
        check(!manualReopen.automatic && manualReopen.label == "Reopening · person", "reopening a verified feature is a person's step", manualReopen.label)
        check(!actor(manualReopen, .ai).allowed && !actor(manualReopen, .system).allowed, "…an AI may not do it")
        check(actor(manualReopen, .human).text.contains("a reason"), "…and the person gives a reason", actor(manualReopen, .human).text)

        let cancel = TransitionStory.make(rule(bug, .cancellation), processes: [pullRequest, direct])
        check(cancel.label == "Cancellation · person or AI" && cancel.processes.isEmpty, "cancellation names no process settings: it reads none", "\(cancel.label) \(cancel.processes)")
        check(!cancel.automatic && actor(cancel, .system).allowed && actor(cancel, .system).text == "May make this step, with cancellation evidence.",
              "MarkView is allowed to cancel with evidence but nothing makes it do so by itself, so the arrow does not claim it", actor(cancel, .system).text)

        // MARK: The story follows edits

        var edited = rule(feature, .completion)
        edited.needs[.system] = nil
        let noSystem = TransitionStory.make(edited, processes: [])
        check(!noSystem.automatic && noSystem.label == "Completion · person or AI", "taking MarkView off a step takes 'automatic' off its arrow", noSystem.label)
        edited.needs[.human] = [.deliveryEvidence, .reason]
        check(actor(TransitionStory.make(edited, processes: []), .human).text == "May make this step, with delivery evidence and a reason.", "conditions are listed in words")
        edited.needs = [:]
        let nobody = TransitionStory.make(edited, processes: [pullRequest])
        check(nobody.label == "Completion" && nobody.processes.isEmpty && nobody.actors.allSatisfy { !$0.allowed },
              "a step nobody may make has a plain label and no process lines", nobody.label)

        // MARK: Events and who confirms

        let onStart = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: [], .ai: [], .system: []], event: .workStarted)
        let onStartStory = TransitionStory.make(onStart, processes: [])
        check(onStartStory.trigger == "When work is started", "a rule with an event says when it happens", onStartStory.trigger)
        check(onStartStory.automatic && onStartStory.label.hasSuffix("· automatic"), "a rule with an event is automatic", onStartStory.label)
        check(actor(onStartStory, .system).text == "Makes this step by itself as soon as work is started.", "MarkView is said to take the step when the event happens", actor(onStartStory, .system).text)
        let noEvent = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: [], .ai: [], .system: []])
        check(!TransitionStory.make(noEvent, processes: []).automatic && TransitionStory.make(noEvent, processes: []).trigger == TransitionStory.triggerWords(for: .spec),
              "the same rule without an event is not automatic", TransitionStory.make(noEvent, processes: []).trigger)
        let eventClosed = LifecycleRule(from: ["in-progress"], to: "in-review", kind: .spec, needs: [.human: []], event: .workStarted)
        check(!TransitionStory.make(eventClosed, processes: []).automatic, "an event without a MarkView entry does not make the step automatic")
        let eventWithEvidence = LifecycleRule(from: ["in-progress"], to: "done", kind: .completion, needs: [.system: [.deliveryEvidence]], event: .pullRequestMerged)
        check(actor(TransitionStory.make(eventWithEvidence, processes: []), .system).text == "Makes this step by itself as soon as a pull request is merged and the delivery evidence is complete.",
              "an event and a condition are both named", actor(TransitionStory.make(eventWithEvidence, processes: []), .system).text)

        var installedByAI = installed
        installedByAI.confirmer = .personOrAI
        check(TransitionStory.processLines(installedByAI, parts: .delivery).contains("A person, or an AI with its evidence, confirms: installed on the other Mac"),
              "the process line says that an AI may confirm", "\(TransitionStory.processLines(installedByAI, parts: .delivery))")
        check(TransitionStory.processLines(installed, parts: .delivery).contains("A person confirms: installed on the other Mac"), "and a person only otherwise")
    }
}

extension EditorHostTests {
    func testWorkflowTemplateStorage() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory.appendingPathComponent("mv-template-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temp) }
        let folder = temp.appendingPathComponent("WorkflowTemplates", isDirectory: true)
        let store = WorkflowTemplateStore(folder: folder)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)

        /// Boris's setup: Kanban with the pull request, the checks and the release switched on for both types.
        func configured() -> ProjectWorkflow {
            var workflow = WorkflowFlow.kanban.applied(to: .standard)
            workflow.revision = 7
            for index in workflow.variants.indices {
                workflow.variants[index].integration = .pullRequest
                workflow.variants[index].checks = true
                workflow.variants[index].delivery = .githubRelease
            }
            return workflow
        }

        // MARK: Ids

        check(WorkflowTemplateStore.slug("My Kanban (no CI)") == "my-kanban-no-ci", "a name becomes a file-name id")
        check(WorkflowTemplateStore.slug("  ../../etc/passwd ") == "etc-passwd", "a name with path characters cannot make an id that leaves the folder")
        check(WorkflowTemplateStore.slug("Мой процесс") == "template", "a name with no ASCII letters falls back to 'template'")
        check(WorkflowTemplateStore.isValid(id: "kanban-2") && !WorkflowTemplateStore.isValid(id: "../x") && !WorkflowTemplateStore.isValid(id: "A")
              && !WorkflowTemplateStore.isValid(id: "") && !WorkflowTemplateStore.isValid(id: "default"), "only lower-case words with hyphens are ids; 'default' is reserved for the pointer")

        // MARK: Empty folder

        let empty = store.list()
        check(empty.templates.isEmpty && empty.unusable.isEmpty && empty.defaultID == nil && empty.defaultTemplate == nil, "a folder that does not exist is an empty library")

        // MARK: Save and read back (REQ-001)

        let source = configured()
        let saved = try! store.save(name: "Kanban with GitHub", note: "PR, CI and release on", workflow: source, now: moment)
        check(saved.id == "kanban-with-github" && saved.name == "Kanban with GitHub", "saving gives the template its own id")
        check(fileManager.fileExists(atPath: folder.appendingPathComponent("kanban-with-github.json").path), "one JSON file per template in the folder")
        let listed = store.list()
        check(listed.templates.count == 1 && listed.templates[0] == saved, "the template is read back exactly as it was saved")
        check(listed.templates[0].workflow.feature == source.feature && listed.templates[0].workflow.bug == source.bug
              && listed.templates[0].workflow.variants == source.variants && listed.templates[0].workflow.defaultBugVariant == source.defaultBugVariant,
              "it keeps the states, the transitions, every process with its delivery settings and the defaults")
        check(saved.workflow.revision == 1 && saved.workflow.name == "Kanban with GitHub", "the stored workflow starts at revision 1 and carries the template's name")
        check(saved.needsGitHub, "a template whose processes need a pull request, checks and a release says it needs GitHub")
        check(!(try! store.save(name: "Plain", workflow: WorkflowFlow.kanban.applied(to: StandardWorkflow.make(bug: .init(pullRequestRequired: false, checksRequired: false, releaseRequired: false))))).needsGitHub,
              "a template whose processes require nothing does not")
        check(try! store.list().templates.map(\.name) == ["Kanban with GitHub", "Plain"], "templates are listed by name")

        // Same name, own file; replacing keeps the id
        let second = try! store.save(name: "Kanban with GitHub", workflow: source, now: moment)
        check(second.id == "kanban-with-github-2", "a name that is taken gets its own file and does not overwrite")
        var changed = source
        changed.name = "x"
        changed.bug.statuses[0].title = "Renamed first state"
        let replaced = try! store.save(name: "Kanban with GitHub", note: "again", workflow: changed, replacing: saved.id, now: moment.addingTimeInterval(60))
        check(replaced.id == saved.id && store.list().templates.first { $0.id == saved.id }?.note == "again", "replacing writes over the same file and keeps the id")
        check((try? store.save(name: "Gone", workflow: source, replacing: "nope")) == nil, "replacing a template that is not there is refused")

        // Invalid input is refused
        check((try? store.save(name: "   ", workflow: source)) == nil, "a template needs a name")
        var broken = source
        broken.feature.rules[0].to = "no-such-status"
        do { _ = try store.save(name: "Broken", workflow: broken); check(false, "an invalid workflow cannot be saved as a template") }
        catch let error as WorkflowTemplateError { check({ if case .invalid = error { return true } else { return false } }(), "an invalid workflow cannot be saved as a template", error.localizedDescription) }
        catch { check(false, "an invalid workflow cannot be saved as a template", "\(error)") }
        check(!store.list().templates.contains { $0.name == "Broken" }, "…and nothing was written for it")

        // MARK: Apply (REQ-002)

        var other = WorkflowFlow.linear.applied(to: .standard)
        other.revision = 12
        let applied = saved.applied(to: other)
        check(applied.revision == 12, "applying keeps the revision of the project that takes it, so a save still notices a newer file")
        check(applied.feature == saved.workflow.feature && applied.bug == saved.workflow.bug && applied.variants == saved.workflow.variants
              && applied.defaultFeatureVariant == saved.workflow.defaultFeatureVariant && applied.name == saved.name, "applying replaces the whole workflow: states, transitions, processes")
        check(applied.validate().isEmpty, "the result passes the workflow validation")
        check(saved.matches(applied) && !saved.matches(other), "the draft is recognised as this template until it is changed")
        var edited = applied
        edited.variants[0].checks.toggle()
        check(!saved.matches(edited), "…and not after a process is edited")
        // A template is a copy: editing the project it came from, or the one that took it, never changes the file.
        var after = applied
        after.feature.statuses[0].title = "Edited in the project that took it"
        check(store.list().templates.first { $0.id == saved.id }?.workflow.feature.statuses[0].title != after.feature.statuses[0].title, "a template is a copy: editing a project that took it does not change the file")

        // MARK: The default for new projects (REQ-003)

        check(store.defaultTemplate() == nil, "nothing is chosen at first")
        try! store.setDefault(saved.id)
        check(store.defaultTemplate()?.id == saved.id && store.list().defaultID == saved.id, "a saved template can be chosen for new projects")
        check(fileManager.fileExists(atPath: folder.appendingPathComponent("default.json").path) && store.list().templates.allSatisfy { $0.id != "default" },
              "the choice is a small default.json in the same folder and is never listed as a template")
        check((try? store.setDefault("missing")) == nil && store.list().defaultID == saved.id, "choosing a template that is not there is refused and keeps the old choice")
        try! store.setDefault(nil)
        check(store.defaultTemplate() == nil && !fileManager.fileExists(atPath: folder.appendingPathComponent("default.json").path), "the built-in default can be chosen again")
        try! store.setDefault(saved.id)
        try! store.delete(saved.id)
        check(store.defaultTemplate() == nil && store.list().defaultID == nil && !fileManager.fileExists(atPath: folder.appendingPathComponent("kanban-with-github.json").path),
              "deleting the chosen template removes the choice with it")
        check((try? store.delete("../../x")) == nil, "a delete cannot reach outside the folder")

        // MARK: Files that cannot be used are named and left alone (REQ-001)

        let good = try! store.save(name: "Good", workflow: source, now: moment)
        func write(_ name: String, _ text: String) { try! Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        write("not-json.json", "this is not json")
        write("no-schema.json", "{\"id\": \"x\"}")
        write("newer.json", "{\"schema\": 99, \"id\": \"newer\"}")
        write("wrong-shape.json", "{\"schema\": 1, \"id\": \"wrong-shape\"}")
        let valid = try! Data(contentsOf: folder.appendingPathComponent("good.json"))
        var invalidObject = try! JSONSerialization.jsonObject(with: valid) as! [String: Any]
        var workflowObject = invalidObject["workflow"] as! [String: Any]
        var feature = workflowObject["feature"] as! [String: Any]
        var rules = feature["rules"] as! [[String: Any]]
        rules[0]["to"] = "no-such-status"
        feature["rules"] = rules
        workflowObject["feature"] = feature
        invalidObject["workflow"] = workflowObject
        try! JSONSerialization.data(withJSONObject: invalidObject).write(to: folder.appendingPathComponent("invalid-workflow.json"))
        write("Bad Name.json", "{}")
        write("notes.txt", "not a template")
        let mixed = store.list()
        check(mixed.templates.map(\.id).contains(good.id), "a good template is listed next to the bad files")
        let reasons = Dictionary(uniqueKeysWithValues: mixed.unusable.map { ($0.file, $0.reason) })
        check(Set(reasons.keys) == ["not-json.json", "no-schema.json", "newer.json", "wrong-shape.json", "invalid-workflow.json", "Bad Name.json"],
              "every file that cannot be used is listed, and nothing else", reasons.keys.sorted().joined(separator: ", "))
        check(reasons["newer.json"]?.contains("newer") == true, "a template from a newer app says so")
        check(reasons["invalid-workflow.json"]?.contains("invalid") == true, "an invalid workflow says what is wrong")
        check(try! String(contentsOf: folder.appendingPathComponent("not-json.json")) == "this is not json", "an unusable file is left exactly as it was")
        try! store.setDefault(good.id)
        try! Data("{\"template\": \"not-json\"}".utf8).write(to: folder.appendingPathComponent("default.json"))
        check(store.defaultTemplate() == nil && store.list().defaultID == "not-json", "a choice that names an unusable template gives no default (new projects use the built-in one)")
        try! Data("garbage".utf8).write(to: folder.appendingPathComponent("default.json"))
        check(store.defaultTemplate() == nil && store.list().defaultID == nil, "a damaged pointer file gives no default")
    }
}

extension EditorHostTests {
    @MainActor func testWorkflowTemplateLibraryLifecycle() async {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        @MainActor
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }

        @MainActor
        func makeLibrary() -> (WorkflowTemplateLibrary, URL) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mv-template-library-\(UUID().uuidString)", isDirectory: true)
            return (WorkflowTemplateLibrary(store: WorkflowTemplateStore(folder: folder)), folder)
        }

        @MainActor
        func changes() async {
            print("-- save, choose, delete")
            let (library, folder) = makeLibrary()
            defer { try? FileManager.default.removeItem(at: folder) }
            let workflow = WorkflowFlow.kanban.applied(to: .standard)

            var saved: [String] = []
            library.startSave(name: "Kanban", note: "n", workflow: workflow, replacing: nil) { result in
                if case .success(let template) = result { saved.append(template.id) }
            }
            check(library.templates.isEmpty, "a save returns at once, before the folder is written")
            check(await waitUntil { saved == ["kanban"] }, "the answer comes with the template")
            check(library.templates.map(\.id) == ["kanban"] && library.loaded, "and the list was read again before it came")

            var chosen: [String?] = []
            library.startSetDefault("kanban") { chosen.append($0) }
            check(await waitUntil { chosen.count == 1 } && chosen == [nil] && library.listing.defaultID == "kanban", "the template for new projects is chosen and the list shows it")
            library.startSetDefault("nothing-here") { chosen.append($0) }
            check(await waitUntil { chosen.count == 2 } && chosen[1] != nil && library.listing.defaultID == "kanban", "a template that is not there is refused with a reason that a person reads")

            var deleted: [String?] = []
            library.startDelete("kanban") { deleted.append($0) }
            check(await waitUntil { deleted.count == 1 } && deleted == [nil] && library.templates.isEmpty && library.listing.defaultID == nil,
                  "a deleted template leaves the list, and the choice for new projects goes with it")
            library.startDelete("kanban") { deleted.append($0) }
            check(await waitUntil { deleted.count == 2 } && deleted[1] != nil, "deleting what is gone says why")
        }

        @MainActor
        func replacing() async {
            print("-- a change asked for while one is under way")
            let (library, folder) = makeLibrary()
            defer { try? FileManager.default.removeItem(at: folder) }
            let workflow = WorkflowFlow.kanban.applied(to: .standard)
            var answers: [String] = []
            library.startSave(name: "First", note: "", workflow: workflow, replacing: nil) { result in
                if case .success(let template) = result { answers.append(template.name) }
            }
            library.startSave(name: "Second", note: "", workflow: workflow, replacing: nil) { result in
                if case .success(let template) = result { answers.append(template.name) }
            }
            check(await waitUntil { !answers.isEmpty }, "the later save is answered")
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(answers == ["Second"], "the answer of the replaced save is dropped: it is not shown after the newer one")
            check(await waitUntil { Set(library.templates.map(\.name)) == ["First", "Second"] }, "the file the replaced save had started still lands whole, and the list shows both")
        }

        @MainActor
        func closing() async {
            print("-- the library goes away")
            var answers = 0
            do {
                let (library, folder) = makeLibrary()
                defer { try? FileManager.default.removeItem(at: folder) }
                library.startSave(name: "Late", note: "", workflow: WorkflowFlow.kanban.applied(to: .standard), replacing: nil) { _ in answers += 1 }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            check(answers == 0, "a library that was released answers nobody")
        }
        await changes()
        await replacing()
        await closing()
    }
}
