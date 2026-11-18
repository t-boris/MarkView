import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor private final class CockpitAttemptTestWindow: CockpitQAWindow {
    let qa = QAModel()
    private(set) var shown = 0
    func showQATool() { shown += 1 }
}

private actor CockpitAttemptTestDriver: QAActorDriver, QAAPIExecuting {
    let waits: Bool
    private(set) var started = false
    private(set) var cancelled = false
    init(waits: Bool) { self.waits = waits }
    func open(_ address: String) async throws {}
    func observe() async throws -> QAObservation { QAObservation(address: "fixture", title: "Fixture", snapshot: "fixture") }
    func perform(_ action: QAAction) async throws -> String { "fixture" }
    func screenshot() async -> Data? { nil }
    func arm(_ fault: QAFault) async throws {}
    func faultHits() async -> Int { 0 }
    func close() async {}
    func execute(_ request: QAAPIRequest) async throws -> QAAPIResult {
        started = true
        if waits {
            do { try await Task.sleep(nanoseconds: 120_000_000_000) }
            catch { cancelled = true; throw error }
        }
        return QAAPIResult(passed: true, evidence: "fixture response")
    }
}

private actor CockpitAttemptTestFactory: QADriverFactory {
    let driver: CockpitAttemptTestDriver
    init(driver: CockpitAttemptTestDriver) { self.driver = driver }
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver { driver }
}

private final class CockpitAttemptNoAssistant: QAAssistant {
    func decide(system: String, prompt: String, schema: [String: Any], isolation: isolated (any Actor)?) async throws -> Any? {
        throw QAAPIError.invalid("The fixture must never invoke an assistant")
    }
}

extension EditorHostTests {
    @MainActor func testCockpitQAAttemptRefusesUnsafeStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-qa-host-" + UUID().uuidString)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let review = CockpitQAReview(scenarioID: "missing", targetID: "prod", fingerprint: "fixture", production: true,
                                     exactPlan: "fixture plan", dataChangingActions: ["fixture change"], productionConfirmationRequired: true)
        let step = CockpitStep(title: "QA", agent: "Test", assignment: "Prepare", completionCondition: "Done", qaScenarioID: "missing")
        let verification = CockpitStep(title: "Verify", agent: "Test", assignment: "Review", completionCondition: "Done")
        var plan = CockpitPlan(goal: "Test", controls: CockpitControls(), scenarios: ["missing"], steps: [step, verification],
                               successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [],
                               productionQA: CockpitProductionQA(exactPlan: review.exactPlan, dataChangingActions: review.dataChangingActions))
        plan.qaReviews = [review]
        XCTAssertNotNil(CockpitApproval(plan: plan, productionConfirmed: true))
        let passed = CockpitHostReply(result: CockpitHostResult(passed: true, detail: "ready", build: "fixture"), error: "")
        let failed = CockpitHostReply(result: CockpitHostResult(passed: false, detail: "failed", build: "fixture"), error: "failed")
        let window = CockpitAttemptTestWindow()
        defer { window.qa.run.stop(); window.qa.close() }
        let denied = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: false).run(scenarioID: "missing", previous: passed)
        XCTAssertFalse(denied.error.isEmpty, "Production QA needs its explicit confirmation")
        let unsuccessful = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: true).run(scenarioID: "missing", previous: failed)
        XCTAssertFalse(unsuccessful.error.isEmpty, "A failed agent step cannot start QA")
        XCTAssertNil(window.qa.root, "Rejected plans do not attach QA to a project")
        window.qa.attach(root: other)
        let wrongProject = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: true).run(scenarioID: "missing", previous: passed)
        XCTAssertTrue(wrongProject.error.contains("another project"))
        window.qa.attach(root: root)
        let reservation = try XCTUnwrap(window.qa.reserveForCockpit())
        let busy = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: true).run(scenarioID: "missing", previous: passed)
        XCTAssertTrue(busy.error.contains("already active"))
        window.qa.releaseCockpitReservation(reservation)
        let missing = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: true).run(scenarioID: "missing", previous: passed)
        XCTAssertTrue(missing.error.contains("no longer exists"))
        let next = try XCTUnwrap(window.qa.reserveForCockpit(), "The failed attempt releases its reservation")
        window.qa.releaseCockpitReservation(next)
        XCTAssertFalse(window.qa.run.isRunning)
        XCTAssertEqual(window.shown, 0, "No refused attempt opens the QA tool")
    }

    @MainActor func testCockpitQAAttemptExecutionAndCancellation() async throws {
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost" else {
            XCTFail("QA fixtures require the isolated app host")
            return
        }
        let originalVideo = Settings.standard.stored(Setting.qaRecordVideo)
        let originalDepth = Settings.standard.stored(Setting.qaReviewDepth)
        defer {
            Settings.standard.set(originalVideo, for: Setting.qaRecordVideo)
            Settings.standard.set(originalDepth, for: Setting.qaReviewDepth)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-qa-execution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let node = QANode(id: "check", kind: .check, title: "Fixture request", detail: "Check fixture response",
                          changesData: .no, api: QAAPIRequest(path: "/fixture"))
        var scenario = QAScenario(id: "fixture", title: "Fixture", goal: "Check fixture", appKind: .api,
            apps: [QAApp(id: "app", name: "Fixture")],
            targets: [QATarget(id: "local", kind: .local, name: "Local", locations: ["app": QALocation(url: "http://127.0.0.1:1")])],
            actors: [QAActor(id: "actor", name: "Fixture actor", app: "app")], nodes: [node], start: node.id,
            created: Date(timeIntervalSince1970: 1_800_000_000), updated: Date(timeIntervalSince1970: 1_800_000_000))
        scenario.selected = scenario.enumerateBranches().branches.map(\.id)
        scenario.summary = "Fixture summary"
        scenario.summarySource = QASummary.source(scenario)
        try QAStore.saveScenario(scenario, root: root)
        let persistedScenario = try XCTUnwrap(QAStore.loadScenarios(root).scenarios.first)
        guard QASummary.current(persistedScenario) != nil else {
            XCTFail("The fixture summary must be current so no assistant summary can start")
            return
        }
        let review = try CockpitQAReviewBuilder.make(scenario: scenario, targetID: "local", savedLogins: [])
        let step = CockpitStep(title: "QA", agent: "Test", assignment: "Check", completionCondition: "Done", qaScenarioID: scenario.id)
        let verify = CockpitStep(title: "Verify", agent: "Test", assignment: "Review", completionCondition: "Done")
        var plan = CockpitPlan(goal: "Check fixture", controls: CockpitControls(), scenarios: [scenario.id], steps: [step, verify],
                               successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        plan.qaReviews = [review]
        XCTAssertNotNil(CockpitApproval(plan: plan, productionConfirmed: false))
        let window = CockpitAttemptTestWindow()
        defer { window.qa.run.stop(); window.qa.close() }
        window.qa.testSavedLogins = []
        window.qa.run.recordVideo = false
        window.qa.run.reviewDepth = .off
        window.qa.run.testRunnerAssistant = CockpitAttemptNoAssistant()
        let passed = CockpitHostReply(result: CockpitHostResult(passed: true, detail: "ready", build: "fixture"), error: "")

        let completeDriver = CockpitAttemptTestDriver(waits: false)
        window.qa.run.testDriverFactory = CockpitAttemptTestFactory(driver: completeDriver)
        var stale = plan
        stale.qaReviews?[0].fingerprint += "-stale"
        let refused = await CockpitQAAttempt(workspace: window, root: root, plan: stale, productionConfirmed: false).run(scenarioID: scenario.id, previous: passed)
        XCTAssertTrue(refused.error.contains("plan changed"), refused.error)
        let refusedRequestStarted = await completeDriver.started
        XCTAssertFalse(refusedRequestStarted, "A changed review must never start the fixture")
        let complete = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: false).run(scenarioID: scenario.id, previous: passed)
        XCTAssertTrue(complete.error.isEmpty, complete.error)
        XCTAssertTrue(complete.result.passed)
        XCTAssertNotNil(complete.result.qaRunID)
        XCTAssertEqual(window.shown, 1)
        let evidence = try CockpitResults.loadAll(root: root)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.result.qaRunID, complete.result.qaRunID)
        XCTAssertFalse(evidence.first?.detailsDeleted ?? true, "The linked QA evidence remains on disk")
        let completedRequestStarted = await completeDriver.started
        XCTAssertTrue(completedRequestStarted)

        let waitingDriver = CockpitAttemptTestDriver(waits: true)
        window.qa.run.testDriverFactory = CockpitAttemptTestFactory(driver: waitingDriver)
        let attempt = CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: false)
        let running = Task { await attempt.run(scenarioID: scenario.id, previous: passed) }
        for _ in 0..<300 where !(await waitingDriver.started) { try await Task.sleep(nanoseconds: 10_000_000) }
        let waitingRequestStarted = await waitingDriver.started
        XCTAssertTrue(waitingRequestStarted, "The fixture request starts before cancellation")
        let concurrent = await CockpitQAAttempt(workspace: window, root: root, plan: plan, productionConfirmed: false).run(scenarioID: scenario.id, previous: passed)
        XCTAssertTrue(concurrent.error.contains("already active"))
        XCTAssertTrue(window.qa.run.isRunning, "A second attempt must not interrupt the active run")
        running.cancel()
        let stopped = await running.value
        XCTAssertFalse(stopped.error.isEmpty)
        for _ in 0..<300 where window.qa.run.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(window.qa.run.isRunning, "Cancelling the attempt stops its QA run")
        let waitingRequestCancelled = await waitingDriver.cancelled
        XCTAssertTrue(waitingRequestCancelled, "Cancellation reaches the fixture request")
    }

    @MainActor func testCockpitPolicyAndControls() async {
        func check(_ message: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func controls(_ edit: (inout CockpitControls) -> Void = { _ in }) -> CockpitControls {
            var value = CockpitControls()
            edit(&value)
            return value
        }

        let isFixing: (String) -> Bool = { $0.lowercased() == "fixing" }
        let namesOf: (String) -> [String] = { id in id == "prod" ? ["Production"] : [] }

        func decide(_ policy: CockpitStepPolicy, _ tool: String, _ arguments: [String: Any] = [:]) -> CockpitStepPolicy.Decision {
            policy.decision(tool: tool, arguments: arguments, isFixingStatus: isFixing, environmentNames: namesOf)
        }

        func allowed(_ policy: CockpitStepPolicy, _ tool: String, _ arguments: [String: Any] = [:]) -> Bool {
            if case .allow = decide(policy, tool, arguments) { return true }
            return false
        }

        // MARK: decisions

        let strict = CockpitStepPolicy(controls: controls { $0.fileBugs = false; $0.fixBugs = false; $0.deployment = "Disabled" })
        let open = CockpitStepPolicy(controls: controls { $0.fileBugs = true; $0.fixBugs = true; $0.deployment = "Production" })

        check("an unknown tool is refused", !allowed(open, "markview_invented"))
        check("browser tools stay open", allowed(strict, "browser_click") && allowed(strict, "browser_snapshot"))
        check("reports are always allowed", allowed(strict, "markview_cockpit_complete_step") && allowed(strict, "markview_cockpit_report_progress"))
        check("reads are always allowed", allowed(strict, "markview_list_bugs") && allowed(strict, "markview_deployments_logs") && allowed(strict, "markview_flow_status"))
        check("project records are allowed", allowed(strict, "markview_add_requirement") && allowed(strict, "markview_update_bug"))

        for tool in ["markview_agent_start", "markview_agent_send", "markview_agent_key", "markview_flow_new", "markview_flow_answer",
                     "markview_flow_run", "markview_flow_implement", "markview_flow_fix_bug", "markview_flow_stop"] {
            check("\(tool) is refused even when everything else is allowed", !allowed(open, tool))
        }

        check("create_bug follows File bugs", allowed(open, "markview_create_bug") && !allowed(strict, "markview_create_bug"))
        check("a bug may be reopened or closed with fixing off", allowed(strict, "markview_set_bug_status", ["status": "open"]) && allowed(strict, "markview_set_bug_status", ["status": "closed"]))
        check("a bug may not move into fixing with fixing off", !allowed(strict, "markview_set_bug_status", ["status": "fixing"]) && !allowed(strict, "markview_set_bug_status", ["status": "Fixing"]))
        check("a move to fixed is left to MarkView's own evidence rules", allowed(strict, "markview_set_bug_status", ["status": "fixed"]))
        check("a bug may move into fixing with fixing on", allowed(open, "markview_set_bug_status", ["status": "fixing"]))

        check("deployment Disabled refuses run, propose and delivery", ["markview_deployments_run", "markview_deployments_propose", "markview_confirm_delivery"].allSatisfy { !allowed(strict, $0, ["environment": "prod"]) })
        check("deployment Disabled still allows reading an environment", allowed(strict, "markview_deployments_status", ["environment": "prod"]))
        check("a named environment is accepted by id", allowed(CockpitStepPolicy(controls: controls { $0.deployment = "prod" }), "markview_deployments_run", ["environment": "prod", "command": "uptime"]))
        check("a named environment is accepted by name", allowed(open, "markview_deployments_run", ["environment": "prod", "command": "uptime"]))
        check("another environment is refused", !allowed(open, "markview_deployments_run", ["environment": "staging", "command": "uptime"]))
        check("a run without an environment is refused", !allowed(open, "markview_deployments_run", ["command": "uptime"]))
        for word in ["", "  ", "disabled", "None", "OFF", "no"] {
            check("deployment text \"\(word)\" means disabled", CockpitStepPolicy(controls: controls { $0.deployment = word }).deploymentTarget == nil)
        }

        check("a fix cycle starts with a move into fixing", CockpitStepPolicy.startsFixCycle(tool: "markview_set_bug_status", arguments: ["status": "fixing"], isFixingStatus: isFixing))
        check("other calls do not start a fix cycle", !CockpitStepPolicy.startsFixCycle(tool: "markview_set_bug_status", arguments: ["status": "open"], isFixingStatus: isFixing)
              && !CockpitStepPolicy.startsFixCycle(tool: "markview_create_bug", arguments: ["status": "fixing"], isFixingStatus: isFixing))

        check("the review lists what is refused", strict.enforced.contains { $0.contains("Deploy") || $0.contains("deployment") } && strict.enforced.contains { $0.contains("bug") })
        check("Build and Checks are reported as instruction only", CockpitStepPolicy.instructionOnly(controls { $0.build = false; $0.checks = "unit tests" }) == ["Build", "Checks"])
        check("nothing is instruction only when build is on and checks are empty", CockpitStepPolicy.instructionOnly(controls { $0.build = true }).isEmpty)

        // MARK: controls and their limits

        func decoded(_ json: String) -> CockpitControls? { try? JSONDecoder().decode(CockpitControls.self, from: Data(json.utf8)) }

        for (text, minutes) in [("90", 90), ("90 min", 90), ("2h", 120), ("1h30m", 90), ("1.5 hours", 90), ("45 minutes", 45), ("1h and 30m", 90), ("1h, 30m", 90)] as [(String, Int)] {
            check("\"\(text)\" is \(minutes) minutes", CockpitControls.minutes(in: text) == minutes)
        }
        for text in ["", "soon", "two hours", "5 months", "0", "about 2h"] {
            check("\"\(text)\" is no limit", CockpitControls.minutes(in: text) == nil)
        }

        let legacy = decoded(#"{"createScenarios":true,"checks":"smoke","fileBugs":false,"fixBugs":true,"build":true,"deployment":"Production","timeLimit":"2h","budgetLimit":"$20","fixCycleLimit":"3"}"#)
        check("a run saved with free-text limits still decodes", legacy != nil)
        check("its time limit becomes minutes", legacy?.timeLimitMinutes == 120)
        check("its fix cycle limit becomes a number", legacy?.fixCycleLimit == 3)
        check("its other controls are kept", legacy?.createScenarios == true && legacy?.checks == "smoke" && legacy?.fileBugs == false && legacy?.fixBugs == true && legacy?.build == true && legacy?.deployment == "Production")
        let blank = decoded(#"{"timeLimit":"","budgetLimit":"","fixCycleLimit":""}"#)
        check("blank legacy limits are no limit", blank?.timeLimitMinutes == nil && blank?.fixCycleLimit == nil)
        let vague = decoded(#"{"timeLimit":"a while","fixCycleLimit":"a few"}"#)
        check("vague legacy limits are no limit", vague?.timeLimitMinutes == nil && vague?.fixCycleLimit == nil)
        check("an empty object decodes to the defaults", decoded("{}") == CockpitControls())

        var typed = CockpitControls()
        typed.timeLimitMinutes = 90
        typed.fixCycleLimit = 2
        if let data = try? JSONEncoder().encode(typed) {
            check("typed limits round trip", (try? JSONDecoder().decode(CockpitControls.self, from: data)) == typed)
            check("the budget limit is not written", !(String(data: data, encoding: .utf8) ?? "").contains("budget"))
        } else { check("typed limits encode", false) }
        if let data = try? JSONEncoder().encode(CockpitControls()) {
            let text = String(data: data, encoding: .utf8) ?? ""
            check("no limit writes no limit keys", !text.contains("timeLimit") && !text.contains("fixCycleLimit"))
        }

        // MARK: audit after the step

        typealias Snap = CockpitStepAudit.Snapshot
        func snap(_ files: [String: String] = [:], head: String? = "aaaaaaa1", scenarios: Set<String> = [], git: Bool = true) -> Snap {
            Snap(isGitRepository: git, head: head, files: files, scenarios: scenarios)
        }
        let noFixing = controls { $0.fixBugs = false; $0.createScenarios = false }
        let fixing = controls { $0.fixBugs = true; $0.createScenarios = true }

        check("an untouched project has no violations", CockpitStepAudit.violations(before: snap(), after: snap(), controls: noFixing).isEmpty)
        let edited = CockpitStepAudit.violations(before: snap(), after: snap(["Sources/App.swift": "h1"]), controls: noFixing)
        check("a source file changed with fixing off is a violation that names it", edited.count == 1 && edited[0].contains("Sources/App.swift") && edited[0].contains("Fix bugs is off"))
        check("the same change is fine with fixing on", CockpitStepAudit.violations(before: snap(), after: snap(["Sources/App.swift": "h1"]), controls: fixing).isEmpty)
        check("a file that was already dirty and stayed as it was is not the step's", CockpitStepAudit.violations(before: snap(["a.swift": "h1"]), after: snap(["a.swift": "h1"]), controls: noFixing).isEmpty)
        check("a file that was dirty and changed again is detected", CockpitStepAudit.changedSources(before: snap(["a.swift": "h1"]), after: snap(["a.swift": "h2"])) == ["a.swift"])
        check("a dirty file put back to clean is detected", CockpitStepAudit.changedSources(before: snap(["a.swift": "h1"]), after: snap()) == ["a.swift"])
        check("a deleted file is detected", CockpitStepAudit.changedSources(before: snap(), after: snap(["a.swift": "deleted"])) == ["a.swift"])
        check("documentation and notes are not source", CockpitStepAudit.violations(before: snap(), after: snap(["docs/bugs/BUG-1.md": "h", "tasks/todo.md": "h", ".dde/qa/x.json": "h"]), controls: noFixing).isEmpty)
        check("a commit with fixing off is a violation", CockpitStepAudit.violations(before: snap(head: "aaaaaaa1"), after: snap(head: "bbbbbbb2"), controls: noFixing).contains { $0.contains("commit") })
        check("a commit with fixing on is fine", CockpitStepAudit.violations(before: snap(head: "aaaaaaa1"), after: snap(head: "bbbbbbb2"), controls: fixing).isEmpty)
        let many = Dictionary(uniqueKeysWithValues: (1...14).map { ("f\($0).swift", "h") })
        let longList = CockpitStepAudit.violations(before: snap(), after: snap(many), controls: noFixing)
        check("a long list of files is cut and counted", longList.count == 1 && longList[0].contains("14 source file") && longList[0].contains("and 4 more"))
        check("a new scenario with creating off is a violation", CockpitStepAudit.violations(before: snap(scenarios: ["a"]), after: snap(scenarios: ["a", "b"]), controls: noFixing).contains { $0.contains("scenario") && $0.contains("b") })
        check("a new scenario with creating on is fine", CockpitStepAudit.violations(before: snap(scenarios: ["a"]), after: snap(scenarios: ["a", "b"]), controls: fixing).isEmpty)
        check("a deleted scenario is not a creation", CockpitStepAudit.violations(before: snap(scenarios: ["a", "b"]), after: snap(scenarios: ["a"]), controls: noFixing).isEmpty)
        check("outside git nothing is claimed about sources", CockpitStepAudit.violations(before: snap(git: false), after: snap(["a.swift": "h"], git: false), controls: noFixing).isEmpty)
        check("outside git the audit says what it could not look at", CockpitStepAudit.limits(of: snap(git: false), controls: noFixing).count == 1)
        check("inside git it says nothing extra", CockpitStepAudit.limits(of: snap(), controls: noFixing).isEmpty)
        check("with fixing on it has nothing to excuse", CockpitStepAudit.limits(of: snap(git: false), controls: fixing).isEmpty)

        // MARK: step meter

        var meter = CockpitStepMeter(cycleLimit: 2, cyclesBefore: 0)
        check("a new step has used no fix cycle", meter.stepCycles == 0 && !meter.overCycleLimit)
        meter.noteGate(cycles: 1)
        meter.noteGate(cycles: 2)
        check("the gate count within the limit is not over", meter.stepCycles == 2 && !meter.overCycleLimit)
        meter.noteGate(cycles: 3)
        check("a cycle beyond the limit is over", meter.overCycleLimit)
        meter.noteGate(cycles: 1)
        check("the gate count never goes down", meter.stepCycles == 3)

        var reports = CockpitStepMeter(cycleLimit: 1, cyclesBefore: 0)
        reports.noteReport(pass: 1, fixes: [])
        check("a report without fixes is not a cycle", reports.stepCycles == 0)
        reports.noteReport(pass: 1, fixes: ["BUG-1"])
        check("a report with a new fix is a cycle", reports.stepCycles == 1 && !reports.overCycleLimit)
        reports.noteReport(pass: 2, fixes: ["BUG-1"])
        check("the same fix listed again is not another cycle", reports.stepCycles == 1)
        reports.noteReport(pass: 2, fixes: ["BUG-1", "BUG-2"])
        check("a cumulative list with one new fix is one more cycle", reports.stepCycles == 2 && reports.overCycleLimit)
        reports.noteReport(pass: 2, fixes: ["BUG-1", "BUG-2", "BUG-3"])
        check("two fixes in one pass are one cycle", reports.stepCycles == 2)

        var both = CockpitStepMeter(cycleLimit: nil, cyclesBefore: 5)
        both.noteGate(cycles: 1)
        both.noteReport(pass: 1, fixes: ["A"]); both.noteReport(pass: 2, fixes: ["B"]); both.noteReport(pass: 3, fixes: ["C"])
        check("the larger of the two counts wins", both.stepCycles == 3)
        check("earlier steps' cycles are added", both.totalCycles == 8)
        check("no limit is never over", !both.overCycleLimit)
        check("earlier cycles count against the limit", CockpitStepMeter(cycleLimit: 3, cyclesBefore: 3).overCycleLimit == false
              && { var m = CockpitStepMeter(cycleLimit: 3, cyclesBefore: 3); m.noteGate(cycles: 1); return m.overCycleLimit }())

        check("no time limit has no remaining seconds", CockpitStepMeter.remainingSeconds(limitMinutes: nil, used: 500) == nil)
        check("the remaining seconds are the limit less what was used", CockpitStepMeter.remainingSeconds(limitMinutes: 2, used: 30) == 90)
        check("used up time is zero or less", (CockpitStepMeter.remainingSeconds(limitMinutes: 1, used: 60) ?? 1) <= 0 && (CockpitStepMeter.remainingSeconds(limitMinutes: 1, used: 90) ?? 1) < 0)

        // MARK: supervisor

        check("the supervisor is on by default", CockpitControls().supervisor)
        let legacyControls = try! JSONDecoder().decode(CockpitControls.self, from: Data(#"{"createScenarios":false,"checks":"","fileBugs":true,"fixBugs":false,"build":false,"deployment":"Disabled"}"#.utf8))
        check("a run saved before the supervisor existed gets it on", legacyControls.supervisor)
        let offControls = try! JSONDecoder().decode(CockpitControls.self, from: JSONEncoder().encode(controls { $0.supervisor = false }))
        check("the supervisor control survives encoding", !offControls.supervisor)
        check("the supervisor is part of the approved plan's controls", controls { $0.supervisor = false } != controls())

        let supervised = CockpitHostTask(
            step: CockpitHostStep(id: "S1", title: "Explore checkout", agent: "Claude Code", assignment: "Run the checkout scenario and report findings.",
                                  completionCondition: "Findings reported", prerequisite: false),
            planFingerprint: "fp", goal: "Find checkout bugs", controls: #"{"fixBugs":false,"deployment":"Disabled"}"#,
            successCriteria: ["All findings filed"],
            priorResults: [CockpitHostEntry(stepID: "S0", result: CockpitHostResult(passed: true, detail: "Prerequisite ok", build: ""))])
        let askText = "Should I also look at the cart page?"
        let askPrompt = CockpitSupervisor.prompt(task: supervised, outline: ["Explore checkout (Claude Code)", "Report (Claude Code)"],
                                                 question: .init(text: askText, options: ["yes", "no"], proposed: "no"), progress: nil)
        for part in ["Find checkout bugs", #""fixBugs":false"#, "1. Explore checkout (Claude Code)", "2. Report (Claude Code)", "Run the checkout scenario",
                     "Findings reported", "All findings filed", "Prerequisite ok", askText, "- yes", "The answer it would give itself: no"] {
            check("the supervisor prompt contains: \(part)", askPrompt.contains(part))
        }
        check("the prompt has no progress line when none was reported", !askPrompt.contains("What the agent reported last"))
        let reported = CockpitProgress(passNumber: 2, activity: "Testing cart", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "", blockers: ["Login fails"])
        let withProgress = CockpitSupervisor.prompt(task: supervised, outline: [], question: .init(text: askText), progress: reported)
        check("the prompt carries the agent's last report and its blockers", withProgress.contains("pass 2, Testing cart") && withProgress.contains("Login fails"))
        check("a question without options or a proposal has neither line", !withProgress.contains("Options it sees") && !withProgress.contains("would give itself"))
        var greedy = supervised
        greedy.step.assignment = String(repeating: "a", count: 9_000)
        check("a long assignment is clipped in the prompt", CockpitSupervisor.prompt(task: greedy, outline: [], question: .init(text: askText), progress: nil).count < 6_000)
        var history = supervised
        history.priorResults = (0..<9).map { CockpitHostEntry(stepID: "P\($0)", result: CockpitHostResult(passed: true, detail: "detail-\($0)", build: "")) }
        let historyPrompt = CockpitSupervisor.prompt(task: history, outline: [], question: .init(text: askText), progress: nil)
        check("only the latest five earlier steps are sent", historyPrompt.contains("detail-8") && historyPrompt.contains("detail-4") && !historyPrompt.contains("detail-3"))
        check("the system prompt tells the model to decide and not to ask back", CockpitSupervisor.systemPrompt.contains("Decide; do not hand the question back"))
        check("the system prompt treats the question as data", CockpitSupervisor.systemPrompt.contains("data written by the agent"))

        check("a usable answer is parsed", CockpitSupervisor.parse(["answer": "  Skip the cart.  ", "outOfScope": false]) == .init(text: "Skip the cart.", outOfScope: false))
        check("a missing outOfScope means in scope", CockpitSupervisor.parse(["answer": "Yes."]) == .init(text: "Yes.", outOfScope: false))
        check("an out-of-scope answer is parsed", CockpitSupervisor.parse(["answer": "Do not.", "outOfScope": true])?.outOfScope == true)
        check("an empty answer is not usable", CockpitSupervisor.parse(["answer": "   ", "outOfScope": false]) == nil)
        check("a missing answer is not usable", CockpitSupervisor.parse(["outOfScope": true]) == nil)
        check("a value that is not an object is not usable", CockpitSupervisor.parse("answer") == nil && CockpitSupervisor.parse(nil) == nil)
        check("a very long answer is clipped", (CockpitSupervisor.parse(["answer": String(repeating: "x", count: 5_000)])?.text.count ?? 0) <= CockpitSupervisor.textLimit + 1)

        check("an answer reaches the agent as the supervisor's", CockpitSupervisor.reply(for: .init(text: "Skip it.", outOfScope: false)) == "Supervisor: Skip it.")
        let outside = CockpitSupervisor.reply(for: .init(text: "Use the staging key.", outOfScope: true))
        check("an out-of-scope answer tells the agent not to act and to record a blocker, in MarkView's own words",
              outside.contains("Do not act on the question") && outside.contains("blocker in your step report"))
        check("every fixed reply tells the agent not to wait", [CockpitSupervisor.disabledReply, CockpitSupervisor.exhaustedReply, CockpitSupervisor.failureReply("timed out")].allSatisfy { $0.contains("blocker") && !$0.lowercased().contains("wait for the person") })
        check("the disabled reply says there is no supervisor", CockpitSupervisor.disabledReply.contains("No supervisor"))
        check("the failure reply carries the reason", CockpitSupervisor.failureReply("timed out").contains("timed out"))

        var ledger = CockpitSupervisor.Ledger()
        check("a first question is asked", ledger.admit("May I read the logs?") == .ask)
        ledger.remember("May I read the logs?", reply: "Supervisor: yes")
        check("the same question again returns the first reply", ledger.admit("may  I read the LOGS?") == .repeated("Supervisor: yes"))
        check("a repeated question does not use up the cap", ledger.asked == 1)
        check("a failed question is asked again", ledger.admit("Question that failed") == .ask && ledger.admit("Question that failed") == .ask)
        var capped = CockpitSupervisor.Ledger()
        for index in 0..<CockpitSupervisor.questionsPerStep { check("question \(index + 1) of the cap is asked", capped.admit("question \(index)") == .ask) }
        check("the next distinct question is refused", capped.admit("one more") == .exhausted)
        capped.remember("question 3", reply: "Supervisor: ok")
        check("a question already answered is still answered after the cap", capped.admit("question 3") == .repeated("Supervisor: ok"))

        let exchange = { (number: Int) in CockpitSupervisorExchange(stepID: "S1", asked: Date(timeIntervalSince1970: Double(number)), question: "q\(number)", answer: "a", outOfScope: false, failed: false) }
        var log: [CockpitSupervisorExchange] = []
        for number in 0..<(CockpitSupervisor.logLimit + 20) { log = CockpitSupervisor.appending(exchange(number), to: log) }
        check("the run's log keeps only the latest exchanges", log.count == CockpitSupervisor.logLimit && log.first?.question == "q20" && log.last?.question == "q219")
        check("an exchange survives encoding", (try? JSONDecoder().decode(CockpitSupervisorExchange.self, from: JSONEncoder().encode(exchange(7)))) == exchange(7))
        check("text is clipped with an ellipsis", CockpitSupervisor.clip("abcdef", to: 3) == "abc…" && CockpitSupervisor.clip("abc", to: 3) == "abc")

        // MARK: gate in the registry

        @MainActor func registryChecks() async {
            let root = URL(fileURLWithPath: "/tmp/cockpit-registry-checks")
            func gate(_ tool: String, _ arguments: [String: Any] = [:], from ancestors: [Int32]) -> CockpitStepPolicy.Decision? {
                CockpitAgentRegistry.gate(tool: tool, arguments: arguments, ancestors: ancestors, isFixingStatus: isFixing, environmentNames: namesOf)
            }
            func refused(_ decision: CockpitStepPolicy.Decision?) -> Bool { if case .refuse? = decision { return true } else { return false } }
            func allows(_ decision: CockpitStepPolicy.Decision?) -> Bool { if case .allow? = decision { return true } else { return false } }

            var finished = 0
            let strictTicket = CockpitAgentRegistry.register(root: root) { _ in finished += 1 }
            CockpitAgentRegistry.restrict(strictTicket, policy: strict, shell: 4242) { _ in }

            check("a call from outside the step's shell is not gated", gate("markview_flow_fix_bug", from: [1, 99]) == nil)
            check("a call with no known ancestors is not gated", gate("markview_flow_fix_bug", from: []) == nil)
            check("a call from under the step's shell is refused", refused(gate("markview_flow_fix_bug", from: [10, 4242, 1])))
            check("an allowed call from under the shell is allowed", allows(gate("markview_list_bugs", from: [4242])))
            check("a refusal is remembered with the tool's name", CockpitAgentRegistry.refusals(strictTicket).count == 1 && CockpitAgentRegistry.refusals(strictTicket)[0].hasPrefix("markview_flow_fix_bug:"))
            check("an allowed call is not remembered as a refusal", CockpitAgentRegistry.refusals(strictTicket).count == 1)
            for _ in 0..<80 { _ = gate("markview_create_bug", from: [4242]) }
            check("the remembered refusals are capped", CockpitAgentRegistry.refusals(strictTicket).count == 50)

            var heard: [Int] = []
            let openTicket = CockpitAgentRegistry.register(root: root) { _ in }
            CockpitAgentRegistry.restrict(openTicket, policy: open, shell: 5151) { heard.append($0) }
            check("a move into fixing is allowed when fixing is on", allows(gate("markview_set_bug_status", ["status": "fixing"], from: [5151])))
            check("and another one", allows(gate("markview_set_bug_status", ["status": "fixing"], from: [5151])))
            check("each move into fixing is reported with the running count", heard == [1, 2] && CockpitAgentRegistry.fixCycles(openTicket) == 2)
            check("other status moves are not fix cycles", allows(gate("markview_set_bug_status", ["status": "open"], from: [5151])) && heard == [1, 2])
            check("the two steps' shells do not mix", refused(gate("markview_flow_new", from: [5151])) && CockpitAgentRegistry.fixCycles(strictTicket) == 0)

            check("a result for another project is not accepted", !CockpitAgentRegistry.complete(root: URL(fileURLWithPath: "/tmp/elsewhere"), token: strictTicket, result: CockpitHostResult(passed: true, detail: "ok", build: "")))
            check("a refusal still applies until the step ends", refused(gate("markview_flow_fix_bug", from: [4242])))
            check("the step's result is accepted", CockpitAgentRegistry.complete(root: root, token: strictTicket, result: CockpitHostResult(passed: true, detail: "ok", build: "")) && finished == 1)
            check("after the step ends its shell is no longer gated", gate("markview_flow_fix_bug", from: [4242]) == nil)
            check("and its refusals are gone", CockpitAgentRegistry.refusals(strictTicket).isEmpty)

            CockpitAgentRegistry.cancel(openTicket, reason: "stop")
            check("a cancelled step is no longer gated", gate("markview_flow_new", from: [5151]) == nil)

            let late = CockpitAgentRegistry.register(root: root) { _ in }
            CockpitAgentRegistry.restrict(late, policy: strict, shell: 0) { _ in }
            check("a shell that is not known is not bound", gate("markview_flow_new", from: [0]) == nil)
            CockpitAgentRegistry.restrict(UUID(), policy: strict, shell: 7777) { _ in }
            check("a ticket that does not exist binds nothing", gate("markview_flow_new", from: [7777]) == nil)
            CockpitAgentRegistry.cancel(late, reason: "done")

            var asked: [CockpitSupervisor.Question] = []
            let asking = CockpitAgentRegistry.register(root: root, ask: { question in asked.append(question); return "Supervisor: fine" }) { _ in }
            let question = CockpitSupervisor.Question(text: "May I?", options: ["a"], proposed: "a")
            let answer = await CockpitAgentRegistry.ask(root: root, token: asking, question: question)
            check("a question is answered by the step's supervisor", answer == "Supervisor: fine" && asked == [question])
            let elsewhere = await CockpitAgentRegistry.ask(root: URL(fileURLWithPath: "/tmp/elsewhere"), token: asking, question: question)
            check("a question from another project is not answered", elsewhere == nil && asked.count == 1)
            let unknown = await CockpitAgentRegistry.ask(root: root, token: UUID(), question: question)
            check("a question with an unknown ticket is not answered", unknown == nil)
            let silent = CockpitAgentRegistry.register(root: root) { _ in }
            let byDefault = await CockpitAgentRegistry.ask(root: root, token: silent, question: question)
            check("a step with no supervisor is told so", byDefault == CockpitSupervisor.disabledReply)
            check("a finished step takes no more questions", CockpitAgentRegistry.complete(root: root, token: asking, result: CockpitHostResult(passed: true, detail: "ok", build: "")))
            let afterEnd = await CockpitAgentRegistry.ask(root: root, token: asking, question: question)
            check("a question after the step ended is not answered", afterEnd == nil)
            CockpitAgentRegistry.cancel(silent, reason: "done")
        }
        await registryChecks()

        // MARK: what the person switched off during the run (DEC-028)

        func cuts(_ edit: (inout CockpitLiveSwitches) -> Void) -> CockpitLiveSwitches {
            var value = CockpitLiveSwitches()
            edit(&value)
            return value
        }
        check("no cuts change nothing", strict.narrowed(by: CockpitLiveSwitches()) == strict && open.narrowed(by: CockpitLiveSwitches()) == open)
        check("an empty set of cuts says so", CockpitLiveSwitches().isEmpty && !cuts { $0.fixBugsCut = true }.isEmpty)
        let cutAll = cuts { $0.fileBugsCut = true; $0.fixBugsCut = true; $0.deploymentCut = true; $0.supervisorCut = true }
        check("cutting everything leaves the policy of a strict plan", open.narrowed(by: cutAll) == strict)
        check("a cut cannot give a strict plan more than it was approved", strict.narrowed(by: CockpitLiveSwitches()) == strict && strict.narrowed(by: cutAll) == strict)
        check("filing bugs can be cut alone", !allowed(open.narrowed(by: cuts { $0.fileBugsCut = true }), "markview_create_bug")
              && allowed(open.narrowed(by: cuts { $0.fileBugsCut = true }), "markview_list_bugs"))
        check("fixing bugs can be cut alone", !allowed(open.narrowed(by: cuts { $0.fixBugsCut = true }), "markview_set_bug_status", ["status": "fixing"])
              && allowed(open.narrowed(by: cuts { $0.fixBugsCut = true }), "markview_create_bug"))
        check("deployment can be cut alone", !allowed(open.narrowed(by: cuts { $0.deploymentCut = true }), "markview_deployments_run", ["environment": "prod"])
              && allowed(open, "markview_deployments_run", ["environment": "prod"]))
        let fullControls = controls { $0.fileBugs = true; $0.fixBugs = true; $0.deployment = "Production"; $0.supervisor = true; $0.timeLimitMinutes = 90; $0.fixCycleLimit = 3 }
        let narrowedControls = fullControls.narrowed(by: cutAll)
        check("the controls under the cuts are off where cut", !narrowedControls.fileBugs && !narrowedControls.fixBugs && !narrowedControls.supervisor
              && CockpitStepPolicy.isDeploymentDisabled(narrowedControls.deployment))
        check("limits and the other controls are not touched by cuts", narrowedControls.timeLimitMinutes == 90 && narrowedControls.fixCycleLimit == 3
              && narrowedControls.build == fullControls.build && narrowedControls.checks == fullControls.checks)
        check("the policy of the narrowed controls equals the narrowed policy", CockpitStepPolicy(controls: narrowedControls) == CockpitStepPolicy(controls: fullControls).narrowed(by: cutAll))
        check("a cut that is put back returns exactly the approved controls", fullControls.narrowed(by: CockpitLiveSwitches()) == fullControls)
        check("cuts that differ are named for the timeline", CockpitLiveSwitches.changes(from: CockpitLiveSwitches(), to: cuts { $0.fixBugsCut = true; $0.supervisorCut = true }).map(\.name) == ["Fixing bugs", "The supervisor"])
        check("cuts survive a round trip", (try? JSONDecoder().decode(CockpitLiveSwitches.self, from: JSONEncoder().encode(cutAll))) == cutAll)
        check("cuts written before a lever existed still read", (try? JSONDecoder().decode(CockpitLiveSwitches.self, from: Data(#"{"fileBugsCut":true}"#.utf8))) == cuts { $0.fileBugsCut = true })

        @MainActor func liveCutChecks() async {
            let root = URL(fileURLWithPath: "/tmp/cockpit-live-cut-checks")
            var current = CockpitLiveSwitches()
            let ticket = CockpitAgentRegistry.register(root: root) { _ in }
            CockpitAgentRegistry.restrict(ticket, policy: open, cuts: { current }, shell: 6262, onFixCycle: { _ in })
            func gate(_ tool: String, _ arguments: [String: Any] = [:]) -> CockpitStepPolicy.Decision? {
                CockpitAgentRegistry.gate(tool: tool, arguments: arguments, ancestors: [6262], isFixingStatus: isFixing, environmentNames: namesOf)
            }
            func allows(_ decision: CockpitStepPolicy.Decision?) -> Bool { if case .allow? = decision { return true } else { return false } }
            func refuses(_ decision: CockpitStepPolicy.Decision?) -> Bool { if case .refuse? = decision { return true } else { return false } }
            check("before a cut the step may file bugs", allows(gate("markview_create_bug")))
            current.fileBugsCut = true
            check("a cut bites at the agent's next call, in the middle of the step", refuses(gate("markview_create_bug")))
            check("the refusal tells the agent what to do", CockpitAgentRegistry.refusals(ticket).last?.contains("Describe the problem in your step report") == true)
            check("what is not cut is still allowed", allows(gate("markview_list_bugs")))
            current.fileBugsCut = false
            check("a lever put back returns what the plan allows", allows(gate("markview_create_bug")))
            CockpitAgentRegistry.cancel(ticket, reason: "done")
        }
        await liveCutChecks()

        // MARK: notes to the supervisor (DEC-028)

        let noted = [CockpitCuratorNote(at: Date(timeIntervalSince1970: 100), text: "Do not touch the billing page."),
                     CockpitCuratorNote(at: Date(timeIntervalSince1970: 200), text: "Prefer short test runs.")]
        let notedPrompt = CockpitSupervisor.prompt(task: supervised, outline: [], question: .init(text: askText), progress: nil, notes: noted)
        check("the supervisor prompt carries the person's notes, oldest first", notedPrompt.contains("Do not touch the billing page.")
              && notedPrompt.range(of: "billing")!.lowerBound < notedPrompt.range(of: "short test runs")!.lowerBound)
        check("a note is called guidance, never a permission", notedPrompt.contains("never a permission") && CockpitSupervisor.systemPrompt.contains("never when they would widen"))
        check("without notes the prompt has no notes block", !CockpitSupervisor.prompt(task: supervised, outline: [], question: .init(text: askText), progress: nil).contains("Notes from the person"))
        check("the briefing block is the same text", CockpitCuratorNote.block(noted)?.contains("Prefer short test runs.") == true && CockpitCuratorNote.block([]) == nil)
        let manyNotes = (0..<80).reduce([CockpitCuratorNote]()) { CockpitCuratorNote.appending(CockpitCuratorNote(at: Date(timeIntervalSince1970: Double($1)), text: "note \($1)"), to: $0) }
        check("a run keeps the latest notes only", manyNotes.count == CockpitCuratorNote.capacity && manyNotes.last?.text == "note 79")
        check("a prompt carries the latest notes only", CockpitCuratorNote.block(manyNotes)!.components(separatedBy: "\n- ").count - 1 == CockpitCuratorNote.promptCount)
        check("a long note is clipped", CockpitCuratorNote.appending(CockpitCuratorNote(at: Date(), text: String(repeating: "n", count: 5_000)), to: []).first!.text.count <= CockpitCuratorNote.textLimit + 1)

    }
}
