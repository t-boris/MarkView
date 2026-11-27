import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Steps that run at the same time (cockpit-runs-independent-plan-steps-side-by-side): which steps a plan may group, the planner's
/// labels, the edits, the managed run's two reviews, the run record of a group, its quiet time, its audit and its processes.
@MainActor
final class CockpitParallelStepsHostTests: XCTestCase {
    private func step(_ title: String, group: String? = nil, prerequisite: Bool = false) -> CockpitStep {
        var step = CockpitStep(title: title, agent: "Codex", assignment: "Inspect \(title)", completionCondition: "\(title) inspected",
                               isPrerequisite: prerequisite)
        step.parallelGroup = group
        return step
    }

    /// first, then `members` with the label "checks", then last.
    private func plan(_ members: [CockpitStep], parallel: Bool = true) -> CockpitPlan {
        var controls = CockpitControls()
        controls.parallelSteps = parallel
        var plan = CockpitPlan(goal: "Inspect", controls: controls, scenarios: [], steps: [step("First")] + members + [step("Last")],
                               successCriteria: ["Inspected"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        plan.normalizeGroups()
        return plan
    }

    private func encoded(_ plan: CockpitPlan) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(plan), as: UTF8.self)
    }

    private func started(_ plan: CockpitPlan, at index: Int = 0) throws -> CockpitRun {
        let approval = try XCTUnwrap(CockpitApproval(plan: plan, productionConfirmed: false), "\(plan.approvalBlockers(productionConfirmed: false))")
        var run = CockpitRun(plan: plan)
        XCTAssertTrue(run.start(approval: approval, at: index, now: Date(timeIntervalSince1970: 0)))
        return run
    }

    // MARK: The plan

    func testAPlanKeepsOnlyGroupsWhoseStepsMayRunTogether() {
        let kept = plan([step("A", group: "checks"), step("B", group: "checks")])
        XCTAssertEqual(kept.group(containing: 1), 1..<3)
        XCTAssertEqual(kept.parallelGroups, [1..<3])
        XCTAssertEqual(kept.members(from: 2), 2..<3, "a run that starts inside a group runs the members from there")
        XCTAssertEqual(kept.group(containing: 0), 0..<1)

        let three = plan([step("A", group: "checks"), step("B", group: "checks"), step("C", group: "checks")])
        XCTAssertEqual(three.parallelGroups, [1..<4])
        let four = plan((1...4).map { step("S\($0)", group: "checks") })
        XCTAssertTrue(four.parallelGroups.isEmpty && four.steps.allSatisfy { $0.parallelGroup == nil }, "more than \(CockpitPlan.groupLimit) steps never run together")
        let prerequisite = plan([step("A", group: "checks", prerequisite: true), step("B", group: "checks")])
        XCTAssertTrue(prerequisite.parallelGroups.isEmpty, "a prerequisite of a plain plan runs on its own")
        var withRecovery = [step("A", group: "checks"), step("B", group: "checks")]
        withRecovery[0].recovery = CockpitStepRecovery(assignment: "Try again", maxAttempts: 1)
        XCTAssertTrue(plan(withRecovery).parallelGroups.isEmpty, "a step with a recovery runs on its own")
        var withScenario = [step("A", group: "checks"), step("B", group: "checks")]
        withScenario[1].qaScenarioID = "s1"
        XCTAssertTrue(plan(withScenario).parallelGroups.isEmpty, "a QA scenario step runs on its own")
        var last = plan([])
        last.steps += [step("A", group: "checks"), step("B", group: "checks")]
        last.normalizeGroups()
        XCTAssertTrue(last.parallelGroups.isEmpty, "the plan's last step never runs in a group")
        let lone = plan([step("A", group: "checks"), step("B")])
        XCTAssertNil(lone.steps[1].parallelGroup, "one step with a label is no group")
        let off = plan([step("A", group: "checks"), step("B", group: "checks")], parallel: false)
        XCTAssertTrue(off.parallelGroups.isEmpty && off.steps.allSatisfy { $0.parallelGroup == nil }, "with the switch off no step runs beside another")
    }

    func testAPlanWithoutGroupsEncodesAsBeforeAndAGroupChangesTheFingerprint() throws {
        let off = plan([step("A"), step("B")], parallel: false)
        let json = try encoded(off)
        XCTAssertFalse(json.contains("parallelGroup") || json.contains("parallelSteps"), json)
        XCTAssertTrue(try encoded(plan([step("A"), step("B")])).contains("\"parallelSteps\":true"))
        let grouped = plan([step("A", group: "checks"), step("B", group: "checks")])
        var ungrouped = grouped
        for index in ungrouped.steps.indices { ungrouped.steps[index].parallelGroup = nil }
        XCTAssertNotEqual(try CockpitTemporalPlan(grouped).fingerprint, try CockpitTemporalPlan(ungrouped).fingerprint, "the approval covers the grouping")
        let temporal = try CockpitTemporalPlan(grouped)
        XCTAssertEqual(temporal.steps.map(\.group), [nil, "checks", "checks", nil])

        XCTAssertTrue(CockpitControls.newPlan.parallelSteps, "every new plan starts with the switch on")
        XCTAssertFalse(CockpitControls(storedJSON: "{\"fileBugs\":true}").parallelSteps, "controls saved before the switch have it off")
        XCTAssertFalse(CockpitControls(storedJSON: "not json").parallelSteps)
        var controls = CockpitControls()
        let before = controls
        controls.parallelSteps = true
        XCTAssertTrue(controls.affectsSteps(comparedTo: before), "turning the switch changes the steps, so the plan is checked again")
    }

    func testThePlannersLabelsCountOnlyWithTheSwitchOn() throws {
        func answer(_ groups: [String]) -> [String: Any] {
            ["title": "Inspect", "scenarios": [String](), "successCriteria": ["Inspected"], "unavailableOutcomes": [String](), "alternatives": [String](),
             "steps": groups.enumerated().map { index, group in
                 ["title": "S\(index)", "agent": "Codex", "model": "", "assignment": "Inspect", "completionCondition": "Done",
                  "isPrerequisite": false, "qaScenarioID": "", "group": group] as [String: Any]
             }]
        }
        var on = CockpitControls(); on.parallelSteps = true
        let grouped = try CockpitPlanning.parse(answer(["", "reviews", "reviews", ""]), goal: "Inspect", controls: on, availableAgents: ["Codex"])
        XCTAssertEqual(grouped.parallelGroups, [1..<3])
        let off = try CockpitPlanning.parse(answer(["", "reviews", "reviews", ""]), goal: "Inspect", controls: CockpitControls(), availableAgents: ["Codex"])
        XCTAssertTrue(off.steps.allSatisfy { $0.parallelGroup == nil })
        let invalid = try CockpitPlanning.parse(answer(["", "", "reviews", "reviews"]), goal: "Inspect", controls: on, availableAgents: ["Codex"])
        XCTAssertTrue(invalid.parallelGroups.isEmpty && invalid.steps.allSatisfy { $0.parallelGroup == nil },
                      "a group that may not run together is dropped and the plan is still accepted")
        let properties = (CockpitPlanning.schema["properties"] as? [String: Any])?["steps"] as? [String: Any]
        let stepProperties = (properties?["items"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertNotNil(stepProperties?["group"])
        XCTAssertTrue(CockpitPlanning.groupRule.contains("\(CockpitPlan.groupLimit)"))
    }

    func testEditsKeepAGroupValidAndAStepCanBeTakenOutOfIt() {
        var three = plan([step("A", group: "checks"), step("B", group: "checks"), step("C", group: "checks")])
        let b = three.steps[2].id
        three.ungroupStep(b)
        XCTAssertEqual(three.steps.map(\.title), ["First", "A", "C", "B", "Last"], "the step runs after the members it ran with")
        XCTAssertEqual(three.parallelGroups, [1..<3])
        XCTAssertNil(three.steps[3].parallelGroup)

        var pair = plan([step("A", group: "checks"), step("B", group: "checks")])
        pair.ungroupStep(pair.steps[1].id)
        XCTAssertTrue(pair.parallelGroups.isEmpty && pair.steps.allSatisfy { $0.parallelGroup == nil }, "a group left with one member is no group")

        var moved = plan([step("A", group: "checks"), step("B", group: "checks")])
        XCTAssertTrue(moved.moveStep(at: 2, by: 1))
        XCTAssertTrue(moved.parallelGroups.isEmpty && moved.steps.allSatisfy { $0.parallelGroup == nil }, "members that are no longer adjacent are no group")

        var duplicated = plan([step("A", group: "checks"), step("B", group: "checks")])
        let copy = duplicated.duplicateStep(at: 1)
        XCTAssertEqual(duplicated.steps.firstIndex { $0.id == copy }, 3, "the copy goes after the group")
        XCTAssertEqual(duplicated.parallelGroups, [1..<3])
        XCTAssertNil(duplicated.steps[3].parallelGroup)

        var removed = plan([step("A", group: "checks"), step("B", group: "checks"), step("C", group: "checks")])
        XCTAssertTrue(removed.removeStep(at: 1))
        XCTAssertEqual(removed.parallelGroups, [1..<3])
        XCTAssertTrue(removed.removeStep(at: 1))
        XCTAssertTrue(removed.parallelGroups.isEmpty)
    }

    // MARK: A managed run's reviews

    private func managed(secondReviewer: String?, parallel: Bool = true) -> CockpitPlan {
        let context = CockpitFeatureContext(slug: "sample", title: "Sample", folder: "docs/features/sample", branch: "feat/sample",
                                            done: DefinitionOfDone(items: DefinitionOfDone.builtIn), mandatory: ["pr", "ci", "merge"])
        let work = CockpitStep(title: "Implement", agent: "Codex", assignment: "Do it", completionCondition: "Done")
        let composed = CockpitManagedRun.compose(work: [work], criteria: ["The feature works"], feature: context, implementer: "Codex",
                                                 reviewer: "Claude Code", secondReviewer: secondReviewer, delegation: [])
        var controls = CockpitControls()
        controls.parallelSteps = parallel
        var plan = CockpitPlan(goal: "Implement", controls: controls, scenarios: [], steps: composed.steps, successCriteria: composed.criteria,
                               unavailableOutcomes: [], alternatives: [], productionQA: nil)
        plan.feature = context
        plan.normalizeGroups()
        return plan
    }

    func testAManagedRunReviewsWithTwoAgentsAtOnce() throws {
        let plan = managed(secondReviewer: "Antigravity")
        let reviews = plan.steps.indices.filter { plan.steps[$0].kind == .review }
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(reviews[1], reviews[0] + 1)
        XCTAssertEqual(reviews.map { plan.steps[$0].agent }, ["Claude Code", "Antigravity"], "the first review is the chosen reviewer's")
        XCTAssertTrue(reviews.allSatisfy { plan.steps[$0].isPrerequisite })
        XCTAssertEqual(plan.parallelGroups, [reviews[0]..<(reviews[1] + 1)], "the reviews are the managed run's only group")
        XCTAssertTrue(plan.steps.first { $0.kind == .fix }?.assignment.contains("from every review") == true)

        XCTAssertEqual(managed(secondReviewer: nil).steps.filter { $0.kind == .review }.count, 1, "one agent besides the implementer reviews once")
        XCTAssertEqual(managed(secondReviewer: "Codex").steps.filter { $0.kind == .review }.count, 1, "the implementer never reviews its own change")
        var off = plan
        off.controls.parallelSteps = false
        CockpitManagedRun.keepOneReview(&off.steps)
        off.normalizeGroups()
        XCTAssertEqual(off.steps.filter { $0.kind == .review }.map(\.agent), ["Claude Code"], "with the switch off the managed run reviews once")
        XCTAssertTrue(off.steps.allSatisfy { $0.parallelGroup == nil })

        // A work step the planner labelled never runs beside another: it writes.
        var labelled = plan
        let workIndex = try XCTUnwrap(labelled.steps.firstIndex { $0.kind == .work })
        labelled.steps[workIndex].parallelGroup = "review"
        labelled.normalizeGroups()
        XCTAssertNil(labelled.steps[workIndex].parallelGroup)
    }

    // MARK: The run record

    func testAGroupsMembersStartTogetherAndTheirResultsGoInPlanOrder() throws {
        let plan = plan([step("A", group: "checks"), step("B", group: "checks")])
        var run = try started(plan, at: 1)
        let (a, b, last) = (plan.steps[1].id, plan.steps[2].id, plan.steps[3].id)
        XCTAssertEqual(run.currentMembers, 1..<3)
        XCTAssertEqual(run.steps.map(\.status), [.skipped, .running, .running, .waiting])

        XCTAssertTrue(run.complete(stepID: b, passed: true, detail: "B is fine", build: "", now: Date(timeIntervalSince1970: 5)))
        XCTAssertTrue(run.results.isEmpty, "a member's result waits for the rest of its group")
        XCTAssertEqual(run.allResults.map(\.stepID), [b])
        XCTAssertEqual(run.steps[2].status, .passed)
        XCTAssertEqual(run.currentIndex, 1, "the run stands at the group until every member has ended")
        XCTAssertFalse(run.complete(stepID: b, passed: true, detail: "again", build: ""), "a member ends once")
        XCTAssertFalse(run.complete(stepID: last, passed: true, detail: "too early", build: ""), "a step after the group cannot end first")

        XCTAssertTrue(run.complete(stepID: a, passed: false, detail: "A found a problem", build: "", continuedAfterFailure: true,
                                   now: Date(timeIntervalSince1970: 7)))
        XCTAssertEqual(run.results.map(\.stepID), [a, b], "the group's results are recorded in plan order")
        XCTAssertEqual(run.results.first?.continuedAfterFailure, true)
        XCTAssertNil(run.groupResults)
        XCTAssertEqual(run.status, .running, "a failed member that is not a prerequisite lets the run go on")
        XCTAssertEqual(run.currentIndex, 3)
        XCTAssertEqual(run.steps[3].status, .running)
    }

    func testAFailedReviewOfAManagedGroupPausesAndRetryRunsOnlyTheFailedOne() throws {
        let plan = managed(secondReviewer: "Antigravity")
        let first = try XCTUnwrap(plan.steps.firstIndex { $0.kind == .review })
        var run = try started(plan, at: first)
        let (claude, antigravity) = (plan.steps[first].id, plan.steps[first + 1].id)
        XCTAssertTrue(run.complete(stepID: antigravity, passed: false, detail: "The review could not run", build: "", neededInput: "Sign in"))
        XCTAssertEqual(run.status, .running, "the other member still runs")
        XCTAssertTrue(run.complete(stepID: claude, passed: true, detail: "Reviewed", build: ""))
        XCTAssertEqual(run.status, .paused, "a failed prerequisite member pauses the run after the group")
        XCTAssertTrue(run.isPausedOnFailedPrerequisite)
        XCTAssertEqual(run.failedStepNeededInput, "Sign in")
        XCTAssertEqual(run.waitingReason, "The review could not run")
        XCTAssertEqual(run.results.map(\.stepID), [claude, antigravity])

        XCTAssertTrue(run.retryFailedStep())
        XCTAssertEqual(run.steps[first].status, .passed, "the passed review does not run again")
        XCTAssertEqual(run.steps[first + 1].status, .running)
        XCTAssertTrue(run.complete(stepID: antigravity, passed: true, detail: "Reviewed", build: ""))
        XCTAssertEqual(run.currentIndex, first + 2, "the run goes on after the group")
        XCTAssertEqual(run.results.map(\.stepID), [claude, antigravity, antigravity])
    }

    func testAnInterruptedGroupContinuesWithItsUnfinishedMembersAndKeepsThePassedOnes() throws {
        let plan = plan([step("A", group: "checks"), step("B", group: "checks"), step("C", group: "checks")])
        var run = try started(plan, at: 1)
        let (a, b, c) = (plan.steps[1].id, plan.steps[2].id, plan.steps[3].id)
        XCTAssertTrue(run.complete(stepID: b, passed: true, detail: "B passed", build: ""))
        run.prepareAfterRestart()
        XCTAssertEqual(run.steps[1...3].map(\.status), [.interrupted, .passed, .interrupted], "every member that was running is interrupted")
        XCTAssertEqual(run.status, .paused)

        let approval = try XCTUnwrap(CockpitApproval(plan: plan, productionConfirmed: false))
        XCTAssertTrue(run.continueAfterInterruption(plan: plan, approval: approval, at: 1))
        XCTAssertEqual(run.steps[1...3].map(\.status), [.running, .passed, .running])
        XCTAssertEqual(run.keptMembers, [b.uuidString], "the workflow is told which member passed")
        XCTAssertEqual(run.results.map(\.stepID), [a, b, c])
        XCTAssertEqual(run.results.map(\.interrupted), [true, nil, true])
        XCTAssertTrue(run.complete(stepID: c, passed: true, detail: "C passed", build: ""))
        XCTAssertTrue(run.complete(stepID: a, passed: true, detail: "A passed", build: ""))
        XCTAssertEqual(run.currentIndex, 4)
        XCTAssertEqual(run.results.suffix(2).map(\.stepID), [a, c])

        // A continuation from a changed plan keeps nothing: what passed was approved under another plan.
        var other = try started(plan, at: 1)
        XCTAssertTrue(other.complete(stepID: b, passed: true, detail: "B passed", build: ""))
        other.prepareAfterRestart()
        var changed = plan
        changed.steps[1].assignment = "Inspect A more closely"
        let changedApproval = try XCTUnwrap(CockpitApproval(plan: changed, productionConfirmed: false))
        XCTAssertTrue(other.continueAfterInterruption(plan: changed, approval: changedApproval, at: 1))
        XCTAssertEqual(other.steps[1...3].map(\.status), [.running, .running, .running])
        XCTAssertTrue(other.keptMembers.isEmpty)
    }

    func testEachMemberIsQuietOnItsOwnAndTheWarningNamesTheQuietestOne() throws {
        let plan = plan([step("A", group: "checks"), step("B", group: "checks")])
        var run = try started(plan, at: 1)
        let at = { (seconds: Double) in Date(timeIntervalSince1970: seconds) }
        let report = CockpitProgress(passNumber: 1, activity: "Reading", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: [], buildLogPath: nil)
        XCTAssertTrue(run.recordProgress(report, stepID: plan.steps[1].id, now: at(200)))
        let quietest = try XCTUnwrap(run.quietestStep(now: at(300)))
        XCTAssertEqual(quietest.index, 2, "B has said nothing since it began")
        XCTAssertEqual(quietest.seconds, 300)
        XCTAssertEqual(run.quietSeconds(now: at(300)), 300, "A's report is no sign of life of B")
        XCTAssertEqual(run.quietSeconds(now: at(300), stepActivity: [plan.steps[2].id: at(250)]), 100, "B's own tool call is")
        let notice = try XCTUnwrap(CockpitNotice.silence(of: run, minutes: 5, step: quietest.index))
        XCTAssertTrue(notice.body.hasPrefix("B:"), notice.body)
        run.noteRefusal("markview_create_bug refused", stepID: plan.steps[2].id, now: at(310))
        XCTAssertEqual(run.events?.last?.stepID, plan.steps[2].id.uuidString, "a refusal is attributed to the member whose agent made the call")
    }

    // MARK: The audit and the processes

    func testGroupMembersMayChangeNothingWhateverTheControlsSay() {
        var controls = CockpitControls()
        controls.fixBugs = true
        controls.createScenarios = true
        let before = CockpitStepAudit.Snapshot(isGitRepository: true, head: "aaaaaaa1", files: [:], scenarios: ["s1"])
        let after = CockpitStepAudit.Snapshot(isGitRepository: true, head: "bbbbbbb2", files: ["Sources/App.swift": "h1", "docs/note.md": "h2"],
                                              scenarios: ["s1", "s2"])
        XCTAssertTrue(CockpitStepAudit.violations(before: before, after: after, controls: controls).isEmpty, "a step on its own may, with these controls")
        let found = CockpitStepAudit.violations(before: before, after: after, controls: controls, changes: .group)
        XCTAssertEqual(found.count, 3, found.joined(separator: " | "))
        XCTAssertTrue(found.allSatisfy { $0.hasPrefix("This step runs at the same time as other steps") }, found.joined(separator: " | "))
        XCTAssertTrue(found[0].contains("Sources/App.swift") && !found[0].contains("docs/note.md"))
        XCTAssertTrue(found[2].contains("s2"))
    }

    func testAGroupIsPicturedOnceBeforeItAndOnceAfterItsLastMember() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-group-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func task(_ id: String, members: [String]?) -> CockpitHostTask {
            CockpitHostTask(step: CockpitHostStep(id: id, agent: "Codex", assignment: "Inspect", prerequisite: false), planFingerprint: "p1",
                            goal: "Inspect", controls: "{}", successCriteria: [], priorResults: [], groupMembers: members)
        }
        let audits = CockpitGroupAudit(root: root)
        XCTAssertNil(audits.member(for: task("a", members: nil)), "a step on its own has no group pass")
        let a = try XCTUnwrap(audits.member(for: task("a", members: ["a", "b", "c"])))
        let b = try XCTUnwrap(audits.member(for: task("b", members: ["a", "b", "c"])))
        let c = try XCTUnwrap(audits.member(for: task("c", members: ["a", "b", "c"])))
        _ = await a.before()
        let order = Order()
        let first = Task { @MainActor in let picture = await a.after(); await order.note("a"); return picture }
        try await Task.sleep(nanoseconds: 200_000_000)
        let seenEarly = await order.events
        XCTAssertTrue(seenEarly.isEmpty, "a member that ended waits for the rest of its group")
        c.abandon()
        try await Task.sleep(nanoseconds: 200_000_000)
        let seenAfterAbandon = await order.events
        XCTAssertTrue(seenAfterAbandon.isEmpty, "a member that gave up does not end the wait for the others")
        let last = await b.after()
        let picture = await first.value
        XCTAssertNotNil(last)
        XCTAssertEqual(picture, last, "the members share one picture taken after the last of them")
        let abandoned = await c.after()
        XCTAssertNil(abandoned, "a member that gave up is not audited")
    }

    func testAMembersSurvivingProcessesDoNotReplaceTheOtherMembers() {
        var state = CockpitManagedState()
        let one = CockpitProcessRecord(pid: 11, started: 1, command: "agent-a")
        let two = CockpitProcessRecord(pid: 22, started: 2, command: "agent-b")
        state.setDelegates([one], of: "a", group: ["a", "b"])
        state.setDelegates([two], of: "b", group: ["a", "b"])
        XCTAssertEqual(state.delegates.map(\.pid), [11, 22])
        XCTAssertEqual(state.delegates.map(\.step), ["a", "b"])
        state.setDelegates([], of: "b", group: ["a", "b"])
        XCTAssertEqual(state.delegates.map(\.pid), [11])
        state.setDelegates([], of: "next", group: nil)
        XCTAssertTrue(state.delegates.isEmpty, "a step on its own replaces what was recorded, as before")
    }
}

private actor Order {
    private(set) var events: [String] = []
    func note(_ event: String) { events.append(event) }
}
