import Foundation

private struct TemporalEntry: Decodable { let stepID: String }
private struct TemporalState: Decodable { let status: String; let results: [TemporalEntry] }
private actor Events {
    private(set) var tasks: [CockpitHostTask] = []
    private(set) var cancellations = 0
    func add(_ task: CockpitHostTask) { tasks.append(task) }
    func cancelled() { cancellations += 1 }
}

@main struct Checks {
    @MainActor static func main() async throws {
        guard let path = ProcessInfo.processInfo.environment["MARKVIEW_TEST_RUNTIME"] else { fatalError("MARKVIEW_TEST_RUNTIME is required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { if AgentProcesses.count == 0 { try? FileManager.default.removeItem(at: root) } }
        let service = CockpitService(root: root, bundled: URL(fileURLWithPath: path))
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
        guard await events.tasks.isEmpty else { fatalError("agent was called before approval") }
        _ = try await service.request(request("approve", approval: CockpitTemporalApproval(fingerprint: plan.fingerprint, step: 0)))
        var final: TemporalState?
        for _ in 0..<60 {
            if let data = try? await service.request(request("state")), let value = try? JSONDecoder().decode(TemporalState.self, from: data), value.status == "finished" { final = value; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard final?.results.first?.stepID == step.id.uuidString, await events.tasks.count == 1 else { fatalError("workflow did not execute one host task") }
        let received = await events.tasks[0]
        guard received.planFingerprint == plan.fingerprint, received.goal == "Review", received.controls == plan.controls else { fatalError("host did not receive approved context") }
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
        guard await events.tasks.count == 2 else { fatalError("interruptible step did not start") }
        guard await events.tasks[1].step.qaScenarioID == "scenario-1" else { fatalError("the selected QA scenario did not reach the host") }
        _ = try await service.request(interruptedRequest("control", command: "pause"))
        for _ in 0..<150 where await events.cancellations == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await events.cancellations == 1 else { fatalError("pausing did not cancel the active host task") }
        _ = try await service.request(interruptedRequest("control", command: "stop"))
        let executionEvents = Events()
        let execution = CockpitExecution(root: root, service: service) { task in
            await executionEvents.add(task)
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "build-2"), error: "")
        }
        guard let approval = CockpitApproval(plan: original, productionConfirmed: false) else { fatalError("valid approval rejected") }
        try await execution.start(plan: original, approval: approval, step: 0)
        for _ in 0..<150 where execution.state?.status != "finished" { try await Task.sleep(nanoseconds: 100_000_000) }
        guard execution.state?.status == "finished", await executionEvents.tasks.count == 1 else { fatalError("execution coordinator did not complete the approved step") }
        let saved = try CockpitRunStore.loadAll(root: root)
        guard saved.count == 1, saved[0].status == .finished, saved[0].results.first?.build == "build-2" else { fatalError("execution history was not persisted") }
        let closingEvents = Events()
        let closing = CockpitExecution(root: root, service: service) { task in
            await closingEvents.add(task)
            do { try await Task.sleep(nanoseconds: 120_000_000_000) }
            catch { await closingEvents.cancelled() }
            return CockpitHostReply(result: CockpitHostResult(passed: false, detail: "Interrupted", build: ""), error: "closed")
        }
        try await closing.start(plan: original, approval: approval, step: 0)
        for _ in 0..<100 where await closingEvents.tasks.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await !closingEvents.tasks.isEmpty else { fatalError("project-close step did not start") }
        closing.shutdown()
        for _ in 0..<100 where await closingEvents.cancellations == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await closingEvents.cancellations == 1 else { fatalError("closing the project left its host task running") }
        let afterClose = try CockpitRunStore.loadAll(root: root)
        guard afterClose.contains(where: { $0.status == .paused && $0.steps.contains(where: { $0.status == .interrupted }) }) else { fatalError("closed execution was not recovered as interrupted") }
        let waitingID = "test-" + UUID().uuidString
        func waitingRequest(_ action: String, endpoint: CockpitEndpoint, approval: CockpitTemporalApproval? = nil) -> CockpitTemporalRequest {
            CockpitTemporalRequest(address: endpoint.address, queue: queue, workflowID: waitingID, action: action,
                                   plan: action == "start" ? plan : nil, approval: approval, command: nil, tls: endpoint.tls)
        }
        _ = try await service.request(waitingRequest("start", endpoint: endpoint))
        worker.stop(); bridge.stop(); service.stop()
        for _ in 0..<300 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard AgentProcesses.count == 0 else { fatalError("local helper processes did not stop") }
        guard !FileManager.default.fileExists(atPath: runtimeDirectory.path) else { fatalError("per-launch runtime directory remained after shutdown") }
        let restarted = try await service.start()
        let afterRestart = Events()
        let newBridge = try CockpitHostBridge { task in
            await afterRestart.add(task)
            return CockpitHostReply(result: CockpitHostResult(passed: true, detail: "Done", build: "b3"), error: "")
        }
        let newWorker = try await service.worker(socket: newBridge.path, queue: queue)
        var restored: TemporalState?
        let restoreDeadline = Date().addingTimeInterval(90)
        while Date() < restoreDeadline {
            if let data = try? await service.request(waitingRequest("state", endpoint: restarted)),
               let value = try? JSONDecoder().decode(TemporalState.self, from: data), value.status == "awaiting-approval" { restored = value; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard restored?.status == "awaiting-approval", await afterRestart.tasks.isEmpty else { fatalError("restart resumed work without approval") }
        _ = try await service.request(waitingRequest("approve", endpoint: restarted, approval: CockpitTemporalApproval(fingerprint: plan.fingerprint, step: 0)))
        var resumed: TemporalState?
        let resumeDeadline = Date().addingTimeInterval(90)
        while Date() < resumeDeadline {
            if let data = try? await service.request(waitingRequest("state", endpoint: restarted)),
               let value = try? JSONDecoder().decode(TemporalState.self, from: data), value.status == "finished" { resumed = value; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard resumed?.results.first?.stepID == step.id.uuidString, await afterRestart.tasks.count == 1 else { fatalError("persisted workflow did not continue after approval") }
        newWorker.stop(); newBridge.stop(); service.stop()
        for _ in 0..<300 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard AgentProcesses.count == 0 else { fatalError("restarted helper processes did not stop") }
        print("Cockpit packaged runtime integration checks passed")
    }
}
