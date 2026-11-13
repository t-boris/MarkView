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
        let interruptedStep = CockpitStep(title: "Interrupt", agent: "Codex", assignment: "Wait", completionCondition: "Done")
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
        _ = try await service.request(interruptedRequest("control", command: "pause"))
        for _ in 0..<150 where await events.cancellations == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard await events.cancellations == 1 else { fatalError("pausing did not cancel the active host task") }
        _ = try await service.request(interruptedRequest("control", command: "stop"))
        worker.stop(); bridge.stop(); service.stop()
        for _ in 0..<300 where AgentProcesses.count != 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        guard AgentProcesses.count == 0 else { fatalError("local helper processes did not stop") }
        print("Cockpit packaged runtime integration checks passed")
    }
}
