import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

private struct CockpitFixtureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct TemporalEntry: Decodable { let stepID: String }
private struct TemporalState: Decodable { let status: String; let results: [TemporalEntry] }
private actor Events {
    private(set) var tasks: [CockpitHostTask] = []
    private(set) var cancellations = 0
    func add(_ task: CockpitHostTask) { tasks.append(task) }
    func cancelled() { cancellations += 1 }
}
private actor Latch {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

final class CockpitRuntimeIntegrationHostTests: XCTestCase {
    @MainActor func testPackagedCockpitRuntime() async throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let suppliedRuntime = ProcessInfo.processInfo.environment["MARKVIEW_TEST_RUNTIME"]
        let path = suppliedRuntime
            ?? Bundle.main.resourceURL?.appendingPathComponent("Cockpit/" + architecture).path
        let runtime = try XCTUnwrap(path, "The packaged runtime path is unavailable")
        print("Cockpit runtime uses supplied override: \(suppliedRuntime != nil)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { if AgentProcesses.count == 0 { try? FileManager.default.removeItem(at: root) } }
        let service = CockpitService(root: root, bundled: URL(fileURLWithPath: runtime))
        let events = Events()
        let bridge = try CockpitHostBridge { task in
            await events.add(task)
            if task.step.title == "Interrupt" {
                do { try await Task.sleep(nanoseconds: 120_000_000_000) }
                catch { await events.cancelled() }
                return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "Interrupted", build: ""), error: "interrupted")
            }
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "build-1"), error: "")
        }
        defer { bridge.stop(); service.stop() }
        let endpoint = try await service.start()
        let runtimeDirectory = URL(fileURLWithPath: endpoint.tls.key).deletingLastPathComponent()
        let queue = "test-" + UUID().uuidString
        let worker = try await service.worker(socket: bridge.path, queue: queue)
        defer { worker.stop() }
        let step = CockpitStep(title: "One", agent: "Codex", assignment: "Inspect", completionCondition: "Done")
        let original = CockpitPlan(goal: "Review", controls: CockpitControls(), scenarios: [], steps: [step], successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        let plan = try CockpitTemporalPlan(original)
        let id = "test-" + UUID().uuidString
        func request(_ action: String, approval: CockpitTemporalApproval? = nil) -> CockpitTemporalRequest {
            CockpitTemporalRequest(address: endpoint.address, queue: queue, workflowID: id, action: action, plan: action == "start" ? plan : nil,
                                   approval: approval, command: nil, tls: endpoint.tls)
        }
        _ = try await service.request(request("start"))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard await events.tasks.isEmpty else { throw CockpitFixtureFailure("agent was called before approval") }
        _ = try await service.request(request("approve", approval: CockpitTemporalApproval(fingerprint: plan.fingerprint, step: 0)))
        var final: TemporalState?
        for _ in 0..<60 {
            if let data = try? await service.request(request("state")), let value = try? JSONDecoder().decode(TemporalState.self, from: data), value.status == "finished" { final = value; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard final?.results.first?.stepID == step.id.uuidString, await events.tasks.count == 1 else { throw CockpitFixtureFailure("workflow did not execute one host task") }
        let received = await events.tasks[0]
        guard received.planFingerprint == plan.fingerprint, received.goal == "Review", received.controls == plan.controls else { throw CockpitFixtureFailure("host did not receive approved context") }
        let interruptedStep = CockpitStep(title: "Interrupt", agent: "Codex", assignment: "Wait", completionCondition: "Done", qaScenarioID: "scenario-1")
        let interruptedPlan = try CockpitTemporalPlan(CockpitPlan(goal: "Interrupt", controls: CockpitControls(), scenarios: [], steps: [interruptedStep], successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil))
        let interruptedID = "test-" + UUID().uuidString
        func interruptedRequest(_ action: String, command: String? = nil) -> CockpitTemporalRequest {
            CockpitTemporalRequest(address: endpoint.address, queue: queue, workflowID: interruptedID, action: action,
                plan: action == "start" ? interruptedPlan : nil,
                approval: action == "approve" ? CockpitTemporalApproval(fingerprint: interruptedPlan.fingerprint, step: 0) : nil,
                command: command, tls: endpoint.tls)
        }
        _ = try await service.request(interruptedRequest("start"))
        _ = try await service.request(interruptedRequest("approve"))
        for _ in 0..<60 where await events.tasks.count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await events.tasks.count == 2 else { throw CockpitFixtureFailure("interruptible step did not start") }
        guard await events.tasks[1].step.qaScenarioID == "scenario-1" else { throw CockpitFixtureFailure("the selected QA scenario did not reach the host") }
        _ = try await service.request(interruptedRequest("control", command: "pause"))
        for _ in 0..<150 where await events.cancellations == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await events.cancellations == 1 else { throw CockpitFixtureFailure("pausing did not cancel the active host task") }
        _ = try await service.request(interruptedRequest("control", command: "stop"))
        let executionEvents = Events()
        let execution = CockpitExecution(root: root, service: service) { task in
            await executionEvents.add(task)
            let progress = CockpitProgress(passNumber: 2, activity: "Checking", scenarioCoverage: ["s"], bugs: ["BUG-1"], fixes: [], latestChange: "Updated", blockers: [], buildLogPath: "build/log.txt", criteriaResults: [CockpitCriterionResult(criterion: "Done", met: true, evidence: "Verified")])
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "build-2", progress: progress), error: "")
        }
        guard let approval = CockpitApproval(plan: original, productionConfirmed: false) else { throw CockpitFixtureFailure("valid approval rejected") }
        try await execution.start(plan: original, approval: approval, step: 0)
        for _ in 0..<150 where execution.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        guard execution.state?.status == "finished", await executionEvents.tasks.count == 1 else { throw CockpitFixtureFailure("execution coordinator did not complete the approved step") }
        let saved = try CockpitRunStore.loadAll(root: root)
        guard saved.count == 1, saved[0].status == .finished, saved[0].results.first?.build == "build-2",
              saved[0].results.first?.progress?.passNumber == 2, saved[0].results.first?.progress?.bugs == ["BUG-1"],
              CockpitOutcome.evaluate(criteria: ["Done"], progress: saved[0].results.first?.progress) == .success else { throw CockpitFixtureFailure("execution history or progress was not persisted") }
        let closingEvents = Events()
        let closingExit = Latch()
        let closing = CockpitExecution(root: root, service: service) { task in
            await closingEvents.add(task)
            do { try await Task.sleep(nanoseconds: 120_000_000_000) }
            catch { await closingEvents.cancelled(); await closingExit.wait() }
            return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "Interrupted", build: ""), error: "closed")
        }
        try await closing.start(plan: original, approval: approval, step: 0)
        for _ in 0..<100 where await closingEvents.tasks.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await !closingEvents.tasks.isEmpty else { throw CockpitFixtureFailure("project-close step did not start") }
        let partial = CockpitProgress(passNumber: 1, activity: "Partial work", scenarioCoverage: [], bugs: [], fixes: [], latestChange: "Changed file", blockers: [], buildLogPath: nil)
        try await closing.saveProgress(partial, stepID: step.id, planFingerprint: plan.fingerprint)
        // A refusal the gate reports, a lever and a note are saved by tasks the execution keeps (none makes its caller wait).
        func refusals(_ runs: [CockpitRun]) -> Int { runs.flatMap { $0.events ?? [] }.filter { $0.kind == .refusal }.count }
        var cutDeployment = CockpitLiveSwitches()
        cutDeployment.deploymentCut = true
        closing.noteGate(tool: "markview_deployments_run", refusal: "deployment is switched off")
        closing.setLiveCuts(cutDeployment)
        closing.sendNote("check the build log first")
        for _ in 0..<50 {
            let runs = try CockpitRunStore.loadAll(root: root)
            if refusals(runs) == 1, runs.contains(where: { $0.switches == cutDeployment && $0.notes?.count == 1 }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let saving = try CockpitRunStore.loadAll(root: root)
        guard refusals(saving) == 1, saving.contains(where: { $0.switches == cutDeployment && $0.notes?.first?.text == "check the build log first" }) else {
            throw CockpitFixtureFailure("a refusal, a lever and a note of a running step were not saved on the run")
        }
        closing.shutdown()
        for _ in 0..<100 where await closingEvents.cancellations == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await closingEvents.cancellations == 1 else { throw CockpitFixtureFailure("closing the project left its host task running") }
        // Cancellation reaches the host before its step-end accounting finishes. Let the host
        // return and wait for that already-started accounting before comparing the late call.
        await closingExit.release()
        var accounted = false
        for _ in 0..<100 {
            let runs = try CockpitRunStore.loadAll(root: root)
            if runs.contains(where: { $0.notes?.first?.text == "check the build log first" && $0.activeSeconds != nil }) {
                accounted = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard accounted else { throw CockpitFixtureFailure("closing execution did not persist step usage") }
        // Nothing is written for a closed execution: a gate call that arrives late saves no refusal.
        let beforeLate = try CockpitRunStore.loadAll(root: root)
        closing.noteGate(tool: "markview_deployments_run", refusal: "arrived after the project closed")
        try await Task.sleep(nanoseconds: 800_000_000)
        guard try CockpitRunStore.loadAll(root: root) == beforeLate else { throw CockpitFixtureFailure("a closed execution wrote to the run it had") }
        let afterClose = try CockpitRunStore.loadAll(root: root)
        guard let recovered = afterClose.first(where: { $0.status == .paused && $0.steps.contains(where: { $0.status == .interrupted && $0.progress == partial }) }) else { throw CockpitFixtureFailure("closed execution did not retain interrupted evidence") }
        let recoveryEvents = Events()
        let recovery = CockpitExecution(root: root, service: service) { task in
            await recoveryEvents.add(task)
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Continued", build: "b5"), error: "")
        }
        try await recovery.start(plan: original, approval: approval, step: 0, recovering: recovered)
        for _ in 0..<150 where recovery.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        guard recovery.state?.status == "finished", let resumedTask = await recoveryEvents.tasks.first,
              resumedTask.priorResults.last?.result.interrupted == true, resumedTask.priorResults.last?.result.progress == partial else {
            throw CockpitFixtureFailure("user-selected continuation lost interrupted evidence")
        }
        let continued = try CockpitRunStore.load(recovered.id, root: root)
        guard continued.results.count == 2, continued.results[0].interrupted == true, continued.results[1].passed else {
            throw CockpitFixtureFailure("continued run did not preserve its history")
        }
        let latch = Latch(), revisionEvents = Events()
        let oldStep = CockpitStep(title: "Old", agent: "Codex", assignment: "Work", completionCondition: "Done")
        let obsolete = CockpitStep(title: "Obsolete", agent: "Codex", assignment: "Work", completionCondition: "Done")
        let oldPlan = CockpitPlan(goal: "Old goal", controls: CockpitControls(), scenarios: [], steps: [oldStep, obsolete], successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        let newStep = CockpitStep(title: "New", agent: "Codex", assignment: "New work", completionCondition: "Done")
        let newPlan = CockpitPlan(goal: "New goal", controls: CockpitControls(), scenarios: [], steps: [newStep], successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        let revised = CockpitExecution(root: root, service: service) { task in
            await revisionEvents.add(task)
            if task.step.id == oldStep.id.uuidString { await latch.wait() }
            if task.step.id == newStep.id.uuidString {
                let durable = await Task.detached { (try? CockpitRunStore.loadAll(root: root))?.contains(where: { $0.results.contains(where: { $0.stepID == oldStep.id }) }) == true }.value
                guard durable else { return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "", build: ""), error: "Previous result was not durable before the next step") }
            }
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "b4"), error: "")
        }
        try await revised.start(plan: oldPlan, approval: try XCTUnwrap(CockpitApproval(plan: oldPlan, productionConfirmed: false)), step: 0)
        for _ in 0..<100 {
            if revised.state?.status == "running", await !revisionEvents.tasks.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard revised.state?.status == "running", await revisionEvents.tasks.count == 1 else { throw CockpitFixtureFailure("revision test did not start") }
        try await revised.replan(newPlan, approval: try XCTUnwrap(CockpitApproval(plan: newPlan, productionConfirmed: false)), step: 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        guard await revisionEvents.tasks.count == 1 else { throw CockpitFixtureFailure("revision ran before the current step finished") }
        await latch.release()
        for _ in 0..<150 where revised.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        guard revised.state?.status == "finished", await revisionEvents.tasks.count == 2 else { throw CockpitFixtureFailure("approved revision did not finish") }
        let revisions = try CockpitRunStore.loadAll(root: root)
        guard let history = revisions.first(where: { $0.plan.id == newPlan.id }), history.results.count == 2,
              history.results[0].plan.id == oldPlan.id, history.results[1].plan.id == newPlan.id else { throw CockpitFixtureFailure("revision lost plan history") }
        let waitingID = "test-" + UUID().uuidString
        func waitingRequest(_ action: String, endpoint: CockpitEndpoint, approval: CockpitTemporalApproval? = nil) -> CockpitTemporalRequest {
            CockpitTemporalRequest(address: endpoint.address, queue: queue, workflowID: waitingID, action: action,
                                   plan: action == "start" ? plan : nil, approval: approval, command: nil, tls: endpoint.tls)
        }
        _ = try await service.request(waitingRequest("start", endpoint: endpoint))
        var readyToRestart = false
        for _ in 0..<90 {
            if let data = try? await service.request(waitingRequest("state", endpoint: endpoint)),
               let value = try? JSONDecoder().decode(TemporalState.self, from: data), value.status == "awaiting-approval" {
                readyToRestart = true; break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard readyToRestart else { throw CockpitFixtureFailure("workflow did not reach approval before restart") }
        // A managed implementation run (agent-aware-implementation-runs): an Ask me step waits for the person's answer and runs again on
        // Retry; a continuation of the same run keeps its passed steps and runs only from the step evidence selected.
        let feature = CockpitFeatureContext(slug: "fixture", title: "Fixture", folder: "docs/features/fixture", branch: "feat/fixture",
                                            done: DefinitionOfDone(items: []), mandatory: ["merge"])
        let workStep = CockpitStep(title: "Work", agent: "Codex", assignment: "Work", completionCondition: "Done", isPrerequisite: true, kind: .work)
        let mergeStep = CockpitStep(title: "Merge", agent: "Codex", assignment: "Merge", completionCondition: "Merged", isPrerequisite: true,
                                    kind: .merge, doneItem: "merge", asksFirst: true)
        var managedPlan = CockpitPlan(goal: "Implement", controls: CockpitControls(), scenarios: [], steps: [workStep, mergeStep],
                                      successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        managedPlan.feature = feature
        let managedApproval = try XCTUnwrap(CockpitApproval(plan: managedPlan, productionConfirmed: false))
        let holder = ManagedHolder()
        let managedEvents = Events()
        let managed = CockpitExecution(root: root, service: service) { task in
            await managedEvents.add(task)
            if task.step.id == mergeStep.id.uuidString {
                let approved = await MainActor.run { holder.execution?.record?.managed?.decision(for: mergeStep.id)?.approved == true }
                if !approved { return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "Waiting for your approval: Merge.", build: ""), error: "") }
            }
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "m1"), error: "")
        }
        holder.execution = managed
        try await managed.start(plan: managedPlan, approval: managedApproval, step: 0)
        for _ in 0..<150 where !(managed.state?.status == "paused" && managed.record?.steps[1].status == .failed) { try await Task.sleep(nanoseconds: 100_000_000) }
        guard managed.state?.status == "paused", managed.record?.steps[1].status == .failed, await managedEvents.tasks.count == 2 else {
            throw CockpitFixtureFailure("an Ask me step did not wait for the person")
        }
        await managed.updateManaged({ $0.decide(mergeStep.id, approved: true) }, event: "You approved Merge.")
        try await managed.control("retry")
        for _ in 0..<150 where managed.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        guard managed.state?.status == "finished", await managedEvents.tasks.count == 3,
              managed.record?.managed?.decision(for: mergeStep.id)?.approved == true,
              managed.record?.events?.contains(where: { $0.kind == .managed && $0.text == "You approved Merge." }) == true else {
            throw CockpitFixtureFailure("the person's approval did not let the Ask me step run: status \(managed.state?.status ?? "none")")
        }
        let pausedEvents = Events()
        let pausing = CockpitExecution(root: root, service: service) { task in
            await pausedEvents.add(task)
            let passed = task.step.id == workStep.id.uuidString
            return CockpitHostReply(result: CockpitHostResult(passed: passed, detail: passed ? "Done" : "Blocked", build: ""), error: "")
        }
        try await pausing.start(plan: managedPlan, approval: managedApproval, step: 0)
        for _ in 0..<150 where pausing.state?.status != "paused" { try await Task.sleep(nanoseconds: 100_000_000) }
        try await pausing.control("stop")
        for _ in 0..<150 where pausing.isActive { try await Task.sleep(nanoseconds: 100_000_000) }
        let pausedRun = try CockpitRunStore.load(try XCTUnwrap(pausing.runID), root: root)
        guard pausedRun.status == .stopped, pausedRun.steps[0].status == .passed, pausedRun.steps[1].status == .failed else {
            throw CockpitFixtureFailure("the managed run did not stop on its failed step")
        }
        let continuedEvents = Events()
        let continuing = CockpitExecution(root: root, service: service) { task in
            await continuedEvents.add(task)
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Merged", build: ""), error: "")
        }
        try await continuing.start(plan: managedPlan, approval: managedApproval, step: 1, recovering: pausedRun)
        for _ in 0..<150 where continuing.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        let continuedRun = try CockpitRunStore.load(pausedRun.id, root: root)
        guard continuing.state?.status == "finished", await continuedEvents.tasks.map(\.step.id) == [mergeStep.id.uuidString],
              continuedRun.steps[0].status == .passed, continuedRun.steps[1].status == .passed, continuedRun.status == .finished else {
            throw CockpitFixtureFailure("a managed continuation did not keep its passed step and run only from the selected one")
        }
        // BUG-128: bounded prerequisite recovery runs automatically, pauses with neededInput if the blocker persists,
        // refuses a same-run revision that skips the failed prerequisite, and succeeds after the person responds and retries.
        let prereqStep = CockpitStep(title: "Check chat", agent: "Codex", assignment: "Send test message", completionCondition: "AI replies",
                                     isPrerequisite: true, recovery: CockpitStepRecovery(assignment: "Attempt automatic sign-in", maxAttempts: 1))
        let dependentStep = CockpitStep(title: "Run QA", agent: "Codex", assignment: "Run QA", completionCondition: "Done")
        let prereqPlan = CockpitPlan(goal: "Verify chat", controls: CockpitControls(), scenarios: [], steps: [prereqStep, dependentStep],
                                     successCriteria: ["Done"], unavailableOutcomes: [], alternatives: [], productionQA: nil)
        let prereqApproval = try XCTUnwrap(CockpitApproval(plan: prereqPlan, productionConfirmed: false))
        let prereqEvents = Events()
        let prereqHolder = ManagedHolder()
        let prereqExec = CockpitExecution(root: root, service: service) { task in
            await prereqEvents.add(task)
            if task.recoveryAttempt != nil {
                return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Tried automatic sign-in", build: ""), error: "")
            }
            if task.step.id == prereqStep.id.uuidString {
                let hasResponse = await MainActor.run { prereqHolder.execution?.liveNotes.contains(where: { $0.kind == .stepResponse }) == true }
                if !hasResponse {
                    return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "Sign-in still required", build: "", neededInput: "Supply a prod test account"), error: "")
                }
            }
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Passed", build: "p1"), error: "")
        }
        prereqHolder.execution = prereqExec
        try await prereqExec.start(plan: prereqPlan, approval: prereqApproval, step: 0)
        for _ in 0..<150 where !(prereqExec.state?.status == "paused" && prereqExec.record?.steps[0].status == .failed) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let tasksBeforeRetry = await prereqEvents.tasks
        guard prereqExec.state?.status == "paused",
              prereqExec.record?.failedStepNeededInput == "Supply a prod test account",
              tasksBeforeRetry.count == 3,
              tasksBeforeRetry[0].step.id == prereqStep.id.uuidString && tasksBeforeRetry[0].recoveryAttempt == nil,
              tasksBeforeRetry[1].recoveryAttempt == 1,
              tasksBeforeRetry[2].step.id == prereqStep.id.uuidString && tasksBeforeRetry[2].recoveryAttempt == nil else {
            throw CockpitFixtureFailure("bounded prerequisite recovery did not attempt recovery once, re-check, and pause with neededInput: count=\(tasksBeforeRetry.count), status=\(prereqExec.state?.status ?? "nil")")
        }
        var bypassCandidate = prereqPlan; bypassCandidate.steps[0].assignment = "Revised check"
        let bypassCandidateApproval = try XCTUnwrap(CockpitApproval(plan: bypassCandidate, productionConfirmed: false))
        var refusedBypass = false
        do {
            try await prereqExec.replan(bypassCandidate, approval: bypassCandidateApproval, step: 1)
        } catch CockpitExecution.Failure.prerequisiteRequired {
            refusedBypass = true
        }
        guard refusedBypass else { throw CockpitFixtureFailure("replan allowed bypassing an unpassed failed prerequisite") }
        await prereqExec.sendStepResponse("Use disposable prod account")
        try await prereqExec.control("retry")
        for _ in 0..<150 where prereqExec.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        let finalPrereqTasks = await prereqEvents.tasks
        let savedPrereqRun = try CockpitRunStore.load(try XCTUnwrap(prereqExec.runID), root: root)
        guard prereqExec.state?.status == "finished",
              finalPrereqTasks.count == 5,
              finalPrereqTasks[3].step.id == prereqStep.id.uuidString,
              finalPrereqTasks[4].step.id == dependentStep.id.uuidString,
              savedPrereqRun.notes?.contains(where: { $0.kind == .stepResponse && $0.text == "Use disposable prod account" }) == true else {
            throw CockpitFixtureFailure("respond-and-retry did not unblock prerequisite and run dependent step: status=\(prereqExec.state?.status ?? "nil"), tasks=\(finalPrereqTasks.count)")
        }
        worker.stop(); bridge.stop(); service.stop()
        for _ in 0..<300 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard AgentProcesses.count == 0 else { throw CockpitFixtureFailure("local helper processes did not stop") }
        guard !FileManager.default.fileExists(atPath: runtimeDirectory.path) else { throw CockpitFixtureFailure("per-launch runtime directory remained after shutdown") }
        let restarted = try await service.start()
        let afterRestart = Events()
        let newBridge = try CockpitHostBridge { task in
            await afterRestart.add(task)
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "b3"), error: "")
        }
        defer { newBridge.stop() }
        let newWorker = try await service.worker(socket: newBridge.path, queue: queue)
        defer { newWorker.stop() }
        var restored: TemporalState?
        var lastRestoreStatus = "no response"
        var lastRestoreError = "none"
        let restoreDeadline = Date().addingTimeInterval(90)
        while Date() < restoreDeadline {
            do {
                let data = try await service.request(waitingRequest("state", endpoint: restarted))
                let value = try JSONDecoder().decode(TemporalState.self, from: data)
                lastRestoreStatus = value.status
                if value.status == "awaiting-approval" { restored = value; break }
            } catch {
                lastRestoreError = error.localizedDescription
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard restored?.status == "awaiting-approval" else {
            throw CockpitFixtureFailure("persisted workflow was not restored: last status \(lastRestoreStatus), last error \(lastRestoreError)")
        }
        guard await afterRestart.tasks.isEmpty else { throw CockpitFixtureFailure("restart resumed work without approval") }
        _ = try await service.request(waitingRequest("approve", endpoint: restarted, approval: CockpitTemporalApproval(fingerprint: plan.fingerprint, step: 0)))
        var resumed: TemporalState?
        let resumeDeadline = Date().addingTimeInterval(90)
        while Date() < resumeDeadline {
            if let data = try? await service.request(waitingRequest("state", endpoint: restarted)),
               let value = try? JSONDecoder().decode(TemporalState.self, from: data), value.status == "finished" { resumed = value; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard resumed?.results.first?.stepID == step.id.uuidString, await afterRestart.tasks.count == 1 else { throw CockpitFixtureFailure("persisted workflow did not continue after approval") }
        newWorker.stop(); newBridge.stop(); service.stop()
        for _ in 0..<300 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard AgentProcesses.count == 0 else { throw CockpitFixtureFailure("restarted helper processes did not stop") }
        print("Cockpit packaged runtime integration checks passed")
    }
}

/// The execution a managed fixture's host handler reads its run from.
@MainActor private final class ManagedHolder {
    var execution: CockpitExecution?
}
