import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Managed implementation runs (agent-aware-implementation-runs): the launch advice of Build, the plan MarkView composes from the
/// Definition of Done, where evidence starts a run, the review-finding and delegation rules, the feature drafts, and the rule of one
/// unfinished run per project.
@MainActor
final class CockpitManagedRunHostTests: XCTestCase {
    private func done(_ modes: [String: DoneMode] = [:]) -> DefinitionOfDone {
        var checklist = DefinitionOfDone(items: DefinitionOfDone.builtIn)
        for index in checklist.items.indices { if let mode = modes[checklist.items[index].id] { checklist.items[index].mode = mode } }
        return checklist
    }

    private func feature(_ done: DefinitionOfDone, mandatory: [String] = ["pr", "ci", "merge"]) -> CockpitFeatureContext {
        CockpitFeatureContext(slug: "sample", title: "Sample", folder: "docs/features/sample", branch: "feat/sample", done: done, mandatory: mandatory)
    }

    private func rules(pr: Bool = true, checks: Bool = true, release: Bool = false) -> DeliveryRules {
        DeliveryRules(integration: pr ? .pullRequest : .directToMain, checksRequired: checks, event: release ? .githubRelease : .none)
    }

    private func work(_ title: String = "Implement", agent: String = "Codex", delegate: Bool? = nil) -> CockpitStep {
        CockpitStep(title: title, agent: agent, assignment: "Do \(title)", completionCondition: "\(title) done", delegate: delegate)
    }

    private func managedPlan(_ checklist: DefinitionOfDone, work steps: [CockpitStep]? = nil) -> CockpitPlan {
        let context = feature(checklist)
        let composed = CockpitManagedRun.compose(work: steps ?? [work()], criteria: ["The feature works"], feature: context,
                                                 implementer: "Codex", reviewer: "Claude Code", delegation: ["Codex"])
        var plan = CockpitPlan(goal: "Implement", controls: CockpitControls(), scenarios: [], steps: composed.steps,
                               successCriteria: composed.criteria, unavailableOutcomes: [], alternatives: [], productionQA: nil)
        plan.feature = context
        return plan
    }

    // MARK: Build: the recommended mode and the conflicts with the project's rules

    func testBuildRecommendsCockpitForStagedWorkOrAReleaseAndTheTerminalOtherwise() {
        let staged = ImplementationLaunchAdvice.recommend(.init(planIssues: ["I-1", "I-2", "I-3"], approvedRequirements: 2), done: done())
        XCTAssertEqual(staged.recommended, .cockpit)
        XCTAssertTrue(staged.reasons.first?.contains("I-1, I-2, I-3") == true, staged.reasons.joined(separator: " | "))
        let release = ImplementationLaunchAdvice.recommend(.init(planIssues: [], approvedRequirements: 1), done: done(["deploy": .require]))
        XCTAssertEqual(release.recommended, .cockpit)
        XCTAssertTrue(release.reasons.contains { $0.contains("release") })
        let small = ImplementationLaunchAdvice.recommend(.init(planIssues: ["I-1"], approvedRequirements: 1), done: done())
        XCTAssertEqual(small.recommended, .direct)
        XCTAssertFalse(small.reasons.isEmpty)
    }

    func testChecklistThatSkipsWhatTheProjectRequiresIsAConflict() {
        let found = ImplementationDeliveryRules.conflicts(done: done(["pr": .skip, "ci": .skip, "merge": .skip, "deploy": .skip]),
                                                          rules: rules(release: true))
        XCTAssertEqual(found.map(\.itemID), ["pr", "ci", "merge", "deploy"])
        XCTAssertTrue(ImplementationDeliveryRules.conflicts(done: done(["deploy": .require]), rules: rules(release: true)).isEmpty)
        XCTAssertEqual(ImplementationDeliveryRules.mandatory(rules: rules(pr: false, checks: false)), ["merge"])
        // An unacknowledged conflict keeps the plan from being approved; acknowledging it lets it through.
        var plan = managedPlan(done())
        plan.feature?.conflicts = found
        XCTAssertNil(CockpitApproval(plan: plan, productionConfirmed: false))
        plan.feature?.conflictsAcknowledged = true
        XCTAssertNotNil(CockpitApproval(plan: plan, productionConfirmed: false))
    }

    // MARK: The plan MarkView composes

    func testComposedPlanHasTheDeliveryStepsOfTheChecklistOmitsSkipAndWaitsForAskMe() throws {
        let plan = managedPlan(done(["version": .require, "deploy": .ask, "browser": .skip, "manual": .skip]))
        XCTAssertEqual(plan.steps.map { $0.kind ?? .work },
                       [.branch, .work, .tests, .review, .fix, .reverify, .version, .pullRequest, .checks, .merge, .release, .final])
        XCTAssertEqual(plan.steps.filter { $0.asksFirst == true }.map(\.doneItem), ["merge", "deploy"])
        XCTAssertTrue(plan.steps.filter { $0.kind != .work }.allSatisfy(\.isPrerequisite), "a gate must be retryable")
        // Require items that hold throughout are instructions of every step and success criteria; Skip items appear nowhere.
        XCTAssertTrue(plan.steps.allSatisfy { $0.assignment.contains("Commit all changes") })
        XCTAssertTrue(plan.successCriteria.contains("Definition of Done — Everything committed"))
        XCTAssertFalse(plan.successCriteria.contains { $0.contains("Manual test checklist") || $0.contains("browser tab") })
        XCTAssertFalse(plan.steps.contains { $0.doneItem == "browser" || $0.doneItem == "manual" })
        XCTAssertEqual(plan.steps.first { $0.kind == .review }?.agent, "Claude Code", "the review is independent of the implementer")
        // The plan saves and reloads with everything it carries.
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(CockpitPlan.self, from: data), plan)
    }

    func testDelegationIsKeptOnlyForAgentsWhoseProfileSupportsIt() {
        let plan = managedPlan(done(), work: [work("A", agent: "Codex", delegate: true), work("B", agent: "Cline", delegate: true)])
        XCTAssertEqual(plan.steps.filter { $0.kind == .work }.map(\.delegate), [true, nil])
        // The review, the fixes and the re-verification are lists of independent checks: their agent delegates when it can (Codex
        // here), never when it cannot (Claude Code is left out of the delegation set of this plan).
        XCTAssertEqual(plan.steps.first { $0.kind == .fix }?.delegate, true)
        XCTAssertNil(plan.steps.first { $0.kind == .review }?.delegate)
        XCTAssertNil(plan.steps.first { $0.kind == .reverify }?.delegate)
        XCTAssertNotNil(CLITool.allCases.first { $0.displayName == "Claude Code" }?.provider.parallelWork)
        XCTAssertNil(CLITool.allCases.first { $0.displayName == "Cline" }?.provider.parallelWork)
    }

    func testAPlainPlanDelegatesAMarkedStepOnlyWhenThePersonAllowsIt() throws {
        let claude = work("A", agent: "Claude Code", delegate: true), cline = work("B", agent: "Cline", delegate: true)
        let unmarked = work("C", agent: "Codex")
        var plan = CockpitPlan(goal: "Review", controls: CockpitControls(), scenarios: [], steps: [claude, cline, unmarked],
                               successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        XCTAssertNil(plan.feature)
        XCTAssertNil(plan.delegation(forStep: claude.id.uuidString), "with the switch off a marked step does not delegate")
        XCTAssertFalse(CockpitControls(storedJSON: "").allowDelegation, "controls that cannot be read keep delegation off")
        plan.controls.allowDelegation = true
        let mechanism = try XCTUnwrap(CLITool(rawValue: "claude")?.provider.parallelWork?.mechanism)
        XCTAssertEqual(plan.delegation(forStep: claude.id.uuidString), mechanism)
        XCTAssertTrue(mechanism.contains("the Agent tool"))
        XCTAssertNil(plan.delegation(forStep: cline.id.uuidString), "Cline has no mechanism")
        XCTAssertNil(plan.delegation(forStep: unmarked.id.uuidString), "a step the planner did not mark does not delegate")
        XCTAssertNil(plan.delegation(forStep: UUID().uuidString))
    }

    func testPlansWithoutManagedFieldsSaveAsBefore() throws {
        let plain = CockpitPlan(goal: "Review", controls: CockpitControls(), scenarios: [], steps: [work()], successCriteria: ["Done"],
                                unavailableOutcomes: [], alternatives: [], productionQA: nil)
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        for key in ["\"kind\"", "\"feature\"", "\"asksFirst\"", "\"delegate\"", "\"allowDelegation\"", "\"doneItem\""] {
            XCTAssertFalse(text.contains(key), "\(key) would change the fingerprint of an existing plan")
        }
    }

    // MARK: Where evidence starts a run

    func testRunStartsAtTheFirstStepEvidenceDoesNotSupport() {
        let plan = managedPlan(done())
        var delivery = CockpitDeliveryEvidence(head: "abc", currentBranch: "feat/sample", branchExists: true, github: true)
        XCTAssertEqual(CockpitManagedRun.firstUnsupported(plan: plan, results: [], managed: .init(), delivery: delivery).index, 1,
                       "the branch is checked out already")
        // Every step before the pull request passed at this revision, and the pull request exists: CI comes next.
        var managed = CockpitManagedState()
        let prIndex = plan.steps.firstIndex { $0.kind == .pullRequest }!
        let results = plan.steps.prefix(prIndex).map { CockpitRun.StepResult(plan: plan, stepID: $0.id, passed: true, detail: "", build: "") }
        for step in plan.steps.prefix(prIndex) { managed.revisions[step.id.uuidString] = "abc" }
        delivery.pullRequest = .init(number: 7, url: "https://example.invalid/7", state: "OPEN", headSHA: "abc", mergeCommit: nil)
        delivery.checks = .pending
        let next = CockpitManagedRun.firstUnsupported(plan: plan, results: Array(results), managed: managed, delivery: delivery)
        XCTAssertEqual(plan.steps[next.index].kind, .checks)
        XCTAssertTrue(next.skipped.contains { $0.contains("Pull request #7") })
        // A later commit means the tests and the re-verification no longer hold at the current revision.
        delivery.head = "def"
        XCTAssertEqual(plan.steps[CockpitManagedRun.firstUnsupported(plan: plan, results: Array(results), managed: managed, delivery: delivery).index].kind, .tests)
        // Without an answer from GitHub, the pull request's state is uncertain: the run does not skip it.
        delivery.head = "abc"
        delivery.github = false
        XCTAssertEqual(plan.steps[CockpitManagedRun.firstUnsupported(plan: plan, results: Array(results), managed: managed, delivery: delivery).index].kind, .pullRequest)
        guard case .uncertain = CockpitManagedRun.support(for: plan.steps[prIndex], feature: plan.feature!, results: [], managed: managed, delivery: delivery) else {
            return XCTFail("an unknown pull request must stay pending")
        }
    }

    func testStepsThatWriteTheChangeMayChangeSourceAndVerifiersMayNot() {
        let before = CockpitStepAudit.Snapshot(isGitRepository: true, head: "aaa", files: [:], scenarios: [])
        let after = CockpitStepAudit.Snapshot(isGitRepository: true, head: "bbb", files: ["src/app.py": "h1"], scenarios: [])
        let controls = CockpitControls()
        XCTAssertFalse(controls.fixBugs)
        XCTAssertEqual(CockpitStepAudit.violations(before: before, after: after, controls: controls).count, 2, "a source change and a commit")
        XCTAssertTrue(CockpitStepAudit.violations(before: before, after: after, controls: controls, changesAllowed: true).isEmpty)
        let kinds = Set(managedPlan(done()).steps.map { $0.kind ?? .work })
        for kind in kinds { XCTAssertEqual(kind.isVerification, [.tests, .review, .reverify, .checks, .final].contains(kind), kind.rawValue) }
        XCTAssertTrue(kinds.contains(.review) && kinds.contains(.work) && kinds.contains(.merge))
    }

    // BUG-129: the CI step of a managed run repairs a failing check through a bounded recovery that may write; the step itself only checks.
    func testCIStepRepairsFailedChecksThroughABoundedRecoveryThatMayWrite() {
        let plan = managedPlan(done())
        guard let ci = plan.steps.first(where: { $0.kind == .checks }) else { return XCTFail("the checklist asks for CI") }
        XCTAssertEqual(ci.recovery?.boundedAttempts, 2, "a failed CI step is repaired and re-checked before the run pauses")
        XCTAssertTrue(ci.recovery?.assignment.contains("feat/sample") == true, "the repair is on the feature branch")
        XCTAssertTrue(ci.assignment.contains("do not change files in this step"), "the step's instruction no longer says to fix inside a verification")
        XCTAssertTrue(plan.structuralBlockers.isEmpty, "the composed plan is valid with the recovery")
        XCTAssertFalse(CockpitManagedRun.changesAllowed(for: .checks, recoveryAttempt: nil), "the check itself stays independent (DEC-036)")
        XCTAssertTrue(CockpitManagedRun.changesAllowed(for: .checks, recoveryAttempt: 1), "its recovery attempt is the repair")
        XCTAssertTrue(CockpitManagedRun.changesAllowed(for: .work, recoveryAttempt: nil))
        XCTAssertFalse(CockpitManagedRun.changesAllowed(for: .review, recoveryAttempt: nil))
        XCTAssertEqual(plan.steps.filter { $0.recovery != nil }.count, 1, "no other managed step gets a recovery")
    }

    func testMergeDoneOutsideCockpitIsEvidenceAndIsNotRepeated() {
        let plan = managedPlan(done())
        let merge = plan.steps.first { $0.kind == .merge }!
        var delivery = CockpitDeliveryEvidence(head: "abc", currentBranch: "feat/sample", branchExists: true, github: true)
        delivery.pullRequest = .init(number: 9, url: "https://example.invalid/9", state: "OPEN", headSHA: "abc", mergeCommit: nil)
        guard case .unsupported = CockpitManagedRun.support(for: merge, feature: plan.feature!, results: [], managed: .init(), delivery: delivery) else {
            return XCTFail("an open pull request is not merged")
        }
        // An agent merged it through its terminal: the merge step is supported by GitHub's answer, so the gate skips the action.
        delivery.pullRequest = .init(number: 9, url: "https://example.invalid/9", state: "MERGED", headSHA: "abc", mergeCommit: "0123456789abcdef")
        guard case .supported(let evidence) = CockpitManagedRun.support(for: merge, feature: plan.feature!, results: [], managed: .init(), delivery: delivery) else {
            return XCTFail("a merged pull request is evidence of the merge")
        }
        XCTAssertEqual(evidence, "Pull request #9 is merged as 012345678.")
    }

    func testPullRequestAndChecksAreReadFromGitHub() throws {
        let json = """
        [{"number": 12, "url": "https://example.invalid/12", "state": "MERGED", "headRefOid": "abc", "mergeCommit": {"oid": "m1"},
          "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}, {"state": "SUCCESS"}]},
         {"number": 9, "url": "https://example.invalid/9", "state": "CLOSED", "headRefOid": "old", "statusCheckRollup": []}]
        """
        let read = try XCTUnwrap(CockpitDeliveryProbe.pullRequest(fromJSON: json))
        XCTAssertEqual(read.pullRequest.number, 12)
        XCTAssertEqual(read.pullRequest.mergeCommit, "m1")
        XCTAssertEqual(read.checks, .passed)
        XCTAssertEqual(CockpitDeliveryProbe.checks([["status": "IN_PROGRESS"], ["conclusion": "SUCCESS"]]), .pending)
        XCTAssertEqual(CockpitDeliveryProbe.checks([["conclusion": "FAILURE"], ["status": "QUEUED"]]), .failed)
        XCTAssertEqual(CockpitDeliveryProbe.checks([]), .none)
    }

    // MARK: Review findings block merge and release

    func testFindingsBlockDeliveryUntilVerifiedOrAcceptedForTheRevision() throws {
        var state = CockpitManagedState()
        state.addFindings([CockpitReportedFinding(title: "Missing check", detail: "d", basis: .criterion, reference: "REQ-001 criterion 3"),
                           CockpitReportedFinding(title: "Commits to main", detail: "d", basis: .rule, reference: "Never commit to main")], revision: "r1")
        XCTAssertEqual(state.findings.map(\.id), ["R1", "R2"])
        XCTAssertEqual(state.blockingFindings(at: "r1").count, 2)
        // DEC-032: risk acceptance only for a finding against an acceptance criterion, with a rationale and a revision.
        XCTAssertThrowsError(try state.acceptRisk("R2", rationale: "Fine", revision: "r1")) { XCTAssertEqual($0 as? CockpitManagedState.AcceptanceFailure, .notPermitted) }
        XCTAssertThrowsError(try state.acceptRisk("R1", rationale: "  ", revision: "r1")) { XCTAssertEqual($0 as? CockpitManagedState.AcceptanceFailure, .noRationale) }
        try state.acceptRisk("R1", rationale: "Covered by the follow-up", revision: "r1")
        XCTAssertEqual(state.findings[0].acceptance?.revision, "r1")
        // A fix counts once a re-verification checked it at the revision delivered.
        state.apply([CockpitFindingCheck(id: "R2", fixed: true, evidence: "Branch used")], revision: "r1", verified: false)
        XCTAssertEqual(state.blockingFindings(at: "r1").map(\.id), ["R2"])
        state.apply([CockpitFindingCheck(id: "R2", fixed: true, evidence: "Branch used")], revision: "r1", verified: true)
        XCTAssertTrue(state.blockingFindings(at: "r1").isEmpty)
        // A later revision needs re-verification: the acceptance and the verified fix were for r1 only.
        XCTAssertEqual(state.blockingFindings(at: "r2").map(\.id), ["R1", "R2"])
    }

    func testStepReportsAreAbsorbedAndOutstandingDelegatedWorkFailsTheStep() {
        let plan = managedPlan(done())
        let review = plan.steps.first { $0.kind == .review }!
        var state = CockpitManagedState()
        var reviewed = CockpitHostResult(passed: true, detail: "Reviewed", build: "",
                                         findings: [CockpitReportedFinding(title: "Gap", detail: "", basis: .criterion, reference: "AC 1")])
        CockpitManagedRun.absorb(&reviewed, step: review, revision: "r1", managed: &state)
        XCTAssertTrue(reviewed.passed)
        XCTAssertEqual(state.findings.first?.revision, "r1")
        XCTAssertEqual(state.revisions[review.id.uuidString], "r1")
        // Every plan, managed or not, judges what a step says it delegated.
        var outstanding = CockpitHostResult(passed: true, detail: "Done", build: "", delegates: [CockpitDelegatedWork(work: "Tests", outcome: .outstanding)])
        CockpitManagedRun.checkDelegates(&outstanding, allowed: true)
        XCTAssertFalse(outstanding.passed)
        XCTAssertTrue(outstanding.detail.contains("still outstanding"))
        var unasked = CockpitHostResult(passed: true, detail: "Done", build: "", delegates: [CockpitDelegatedWork(work: "Docs", outcome: .finished)])
        CockpitManagedRun.checkDelegates(&unasked, allowed: false)
        XCTAssertFalse(unasked.passed, "a step that may not delegate cannot succeed with delegated work")
        // The MCP tool reads the same report from the agent's call.
        let report = ProjectToolRunner.cockpitReport(["findings": [["title": "T", "detail": "D", "basis": "rule", "reference": "R"]],
                                                      "delegates": [["work": "W", "outcome": "stopped"]]])
        XCTAssertEqual(report?.findings?.first?.basis, .rule)
        XCTAssertEqual(report?.delegates?.first?.outcome, .stopped)
        XCTAssertNil(ProjectToolRunner.cockpitReport(["findings": [["title": "T", "basis": "maybe"]]]))
    }

    func testReverificationMustCheckEveryFixAtTheCurrentRevision() {
        let plan = managedPlan(done())
        let fix = plan.steps.first { $0.kind == .fix }!, reverify = plan.steps.first { $0.kind == .reverify }!
        var state = CockpitManagedState()
        state.addFindings([CockpitReportedFinding(title: "Gap", detail: "", basis: .criterion, reference: "AC 1")], revision: "r1")
        var fixed = CockpitHostResult(passed: true, detail: "Fixed", build: "", findingChecks: [CockpitFindingCheck(id: "R1", fixed: true, evidence: "Test added")])
        CockpitManagedRun.absorb(&fixed, step: fix, revision: "r2", managed: &state)
        XCTAssertEqual(state.findings[0].state, .fixed)
        XCTAssertNil(state.findings[0].verifiedRevision, "the implementer's own fix does not count until it is verified")
        var unchecked = CockpitHostResult(passed: true, detail: "Tests pass", build: "")
        CockpitManagedRun.absorb(&unchecked, step: reverify, revision: "r2", managed: &state)
        XCTAssertFalse(unchecked.passed)
        XCTAssertTrue(unchecked.detail.contains("R1"))
        XCTAssertNil(state.revisions[reverify.id.uuidString])
        var checked = CockpitHostResult(passed: true, detail: "Tests pass", build: "", findingChecks: [CockpitFindingCheck(id: "R1", fixed: true, evidence: "Verified")])
        CockpitManagedRun.absorb(&checked, step: reverify, revision: "r2", managed: &state)
        XCTAssertTrue(checked.passed)
        XCTAssertEqual(state.findings[0].verifiedRevision, "r2")
        XCTAssertTrue(state.blockingFindings(at: "r2").isEmpty)
    }

    // MARK: Partial delivery and success

    func testDeclinedMandatoryActionBlocksDeliveryAndSuccess() throws {
        let plan = managedPlan(done())
        let approval = try XCTUnwrap(CockpitApproval(plan: plan, productionConfirmed: false))
        var run = CockpitRun(plan: plan)
        XCTAssertTrue(run.start(approval: approval, at: 0))
        let merge = plan.steps.first { $0.kind == .merge }!
        run.updateManaged({ $0.decide(merge.id, approved: false) })
        let line = CockpitManagedRun.deliveryStatus(run).first { $0.stepID == merge.id }
        XCTAssertEqual(line?.state, .declined(blocking: true))
        XCTAssertFalse(CockpitManagedRun.deliveryComplete(run))
        run.updateManaged({ $0.external.append(CockpitExternalCompletion(stepID: merge.id, evidence: "PR #3 is merged", at: Date())) })
        XCTAssertEqual(CockpitManagedRun.deliveryStatus(run).first { $0.stepID == merge.id }?.state, .external("PR #3 is merged"))
    }

    func testPartialDeliveryShowsTheActionAReviewFindingBlocks() throws {
        let plan = managedPlan(done(["deploy": .require]))
        var run = CockpitRun(plan: plan)
        XCTAssertTrue(run.start(approval: try XCTUnwrap(CockpitApproval(plan: plan, productionConfirmed: false)), at: 0))
        let merge = try XCTUnwrap(plan.steps.firstIndex { $0.kind == .merge })
        for _ in 0..<merge { XCTAssertTrue(run.completeCurrent(passed: true, detail: "Done", build: "")) }
        XCTAssertTrue(run.completeCurrent(passed: false, detail: "Merge the pull request is blocked by review findings without a verified fix", build: ""))
        let lines = CockpitManagedRun.deliveryStatus(run)
        guard case .blocked(let reason)? = lines.first(where: { $0.stepID == plan.steps[merge].id })?.state else { return XCTFail("merge is not shown as blocked") }
        XCTAssertTrue(reason.contains("review findings"))
        XCTAssertEqual(plan.steps[merge + 1].kind, .release)
        XCTAssertEqual(lines.first { $0.stepID == plan.steps[merge + 1].id }?.state, .pending)
        XCTAssertFalse(CockpitManagedRun.deliveryComplete(run))
    }

    func testContinuationKeepsPassedStepsAndTheInterruptedAttempt() throws {
        let plan = managedPlan(done())
        let approval = try XCTUnwrap(CockpitApproval(plan: plan, productionConfirmed: false))
        var run = CockpitRun(plan: plan)
        XCTAssertTrue(run.start(approval: approval, at: 0))
        XCTAssertTrue(run.completeCurrent(passed: true, detail: "On the branch", build: ""))
        run.prepareAfterRestart(reason: "Time limit reached")
        XCTAssertTrue(run.isUnfinished)
        XCTAssertTrue(run.continueManaged(at: 1))
        XCTAssertEqual(run.steps[0].status, .passed)
        XCTAssertEqual(run.steps[1].status, .running)
        XCTAssertEqual(run.results.last?.interrupted, true)
        run.end()
        XCTAssertFalse(run.isUnfinished)
    }

    // MARK: Drafts and admission

    func testEachFeatureKeepsItsOwnDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-drafts-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = CockpitDraft(feature: feature(done()), goal: "One", controls: CockpitControls(), plan: managedPlan(done()), preparation: .ready,
                                 blocker: nil, approved: nil, runID: UUID(), updated: Date())
        var other = feature(done())
        other.slug = "other"
        let second = CockpitDraft(feature: other, goal: "Two", controls: CockpitControls(), plan: nil, preparation: .blocked,
                                  blocker: "No agent", approved: nil, runID: nil, updated: Date())
        try CockpitDraftStore.save(first, root: root)
        try CockpitDraftStore.save(second, root: root)
        first.goal = "One, revised"
        try CockpitDraftStore.save(first, root: root)
        let loaded = try CockpitDraftStore.loadAll(root: root)
        XCTAssertEqual(loaded.map(\.slug), ["other", "sample"])
        XCTAssertEqual(loaded.first { $0.slug == "other" }?.blocker, "No agent")
        XCTAssertEqual(loaded.first { $0.slug == "sample" }?.goal, "One, revised")
        XCTAssertEqual(loaded.first { $0.slug == "sample" }?.runID, first.runID)
        XCTAssertNil(CockpitDraftStore.url("../escape", root: root))
    }

    func testOneUnfinishedRunPerProject() throws {
        let root = URL(fileURLWithPath: "/tmp/cockpit-admission-" + UUID().uuidString)
        let windowA = NSObject(), windowB = NSObject()
        XCTAssertNil(CockpitAdmission.reserve(root: root, owner: windowA, title: "A", saved: []))
        let blocked = CockpitAdmission.reserve(root: root, owner: windowB, title: "B", saved: [])
        XCTAssertEqual(blocked?.title, "A", "a second start at the same time is refused and names the run")
        CockpitAdmission.release(root: root, owner: windowA)
        // A saved run that is still paused blocks too, unless it is the run being continued.
        let plan = managedPlan(done())
        var paused = CockpitRun(plan: plan)
        XCTAssertTrue(paused.start(approval: try XCTUnwrap(CockpitApproval(plan: plan, productionConfirmed: false)), at: 0))
        paused.prepareAfterRestart()
        XCTAssertEqual(CockpitAdmission.reserve(root: root, owner: windowB, title: "B", saved: [paused])?.runID, paused.id)
        XCTAssertNil(CockpitAdmission.reserve(root: root, owner: windowB, title: "B", saved: [paused], continuing: paused.id))
        CockpitAdmission.release(root: root, owner: windowB)
        paused.end()
        XCTAssertNil(CockpitAdmission.reserve(root: root, owner: windowA, title: "A", saved: [paused]))
        CockpitAdmission.release(root: root, owner: windowA)
    }

    func testCapabilitiesAreCheckedForTheLaunchProfile() throws {
        let plan = managedPlan(done())
        let problem = try XCTUnwrap(CockpitSession.capabilityProblem(plan: plan, agents: []))
        XCTAssertTrue(problem.contains("Codex") && problem.contains("Claude Code"), problem)
        let warning = CockpitSession.permissionWarning(plan: plan)
        XCTAssertTrue(warning.contains("--dangerously-bypass-approvals-and-sandbox"), warning)
        XCTAssertTrue(warning.contains("Merge the pull request"), "the warning names the Ask me actions an agent could still do itself")
    }

    // MARK: Processes of a step

    func testProcessesStartedUnderAShellAreFoundAndStopped() async throws {
        let child = try Subprocess.start(SubprocessSpec(executable: "/bin/sleep", arguments: ["30"], timeout: 60)) { _, _ in }
        defer { child.terminate() }
        var found: [CockpitProcessRecord] = []
        for _ in 0..<50 {
            found = CockpitDelegateWatch.descendants(of: getpid()).filter { $0.pid == child.pid }
            if !found.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(found.first?.command, "sleep")
        XCTAssertEqual(CockpitDelegateWatch.alive(found).count, 1)
        // A record whose start time differs is another process that reused the id.
        XCTAssertTrue(CockpitDelegateWatch.alive(found.map { CockpitProcessRecord(pid: $0.pid, started: $0.started - 100, command: $0.command) }).isEmpty)
        let remaining = await CockpitDelegateWatch.stop(found, grace: 1)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(CockpitDelegateWatch.alive(found).isEmpty)
    }
}
