import Foundation
import Darwin

@main enum CLICompletionTimeoutTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--acp") { try serveACP(); return }
        if CommandLine.arguments.contains("exec") { try serveCodex(); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-completion-timeout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func request(_ tool: CLITool, timeout: TimeInterval?) -> CLICompletion.Request {
            var request = CLICompletion.Request(project: root, prompt: "[delayed-test]", readableFolder: root)
            request.tool = tool
            request.timeout = timeout
            request.jsonSchema = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]
            return request
        }
        if ProcessInfo.processInfo.environment["MARKVIEW_COMPLETION_LIVE_COPILOT"] != nil {
            var live = request(.copilot, timeout: nil)
            live.prompt = "Answer with exactly {\"ok\":true}. Do not use tools."
            live.readableFolder = nil
            let result = try await withThrowingTaskGroup(of: CLICompletion.Result.self) { group in
                group.addTask { try await CLICompletion.run(live) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 90_000_000_000)
                    throw CLICompletion.Failure.failed(.copilot, "Live test did not finish in 90 seconds.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            precondition((result.structured as? [String: Any])?["ok"] as? Bool == true)
            print("Real Copilot ACP: signed-in structured request without a MarkView wall-clock limit passed.")
            return
        }
        precondition(CLICompletion.Request(project: root, prompt: "x").timeout == 180,
                     "Other app features must keep their existing default deadline.")
        for tool in [CLITool.copilot, .codex] {
            let result = try await CLICompletion.run(request(tool, timeout: nil))
            precondition((result.structured as? [String: Any])?["ok"] as? Bool == true)
            do {
                _ = try await CLICompletion.run(request(tool, timeout: 0.1))
                preconditionFailure("Explicit deadlines must still stop bounded requests.")
            } catch CLICompletion.Failure.timedOut(let failedTool, _) { precondition(failedTool == tool) }
            let task = Task { try await CLICompletion.run(request(tool, timeout: nil)) }
            try await Task.sleep(nanoseconds: 120_000_000)
            task.cancel()
            do { _ = try await task.value; preconditionFailure("Stop must cancel unbounded requests.") }
            catch is CancellationError {}
        }
        var failed = request(.copilot, timeout: nil)
        failed.prompt = "[provider-error]"
        do { _ = try await CLICompletion.run(failed); preconditionFailure("Provider errors must still fail the run.") }
        catch CLICompletion.Failure.failed(_, let detail) { precondition(detail.contains("fixture provider error")) }
        for _ in 0..<100 {
            if AgentProcesses.count == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(AgentProcesses.count == 0, "Completed and cancelled test assistants must be removed.")
        print("Completion deadlines: Copilot ACP and native CLI unbounded completion, explicit limits, Stop, provider errors and cleanup passed.")
    }

    static func send(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func serveACP() throws {
        while let line = readLine() {
            let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let id = message["id"] else { continue }
            switch message["method"] as? String {
            case "session/new": try send(["id": id, "result": ["sessionId": "fixture"]])
            case "session/prompt":
                let params = message["params"] as! [String: Any]
                let text = ((params["prompt"] as! [[String: Any]]).first?["text"] as? String) ?? ""
                if text.contains("[provider-error]") {
                    try send(["id": id, "error": ["code": -32000, "message": "fixture provider error"]]); continue
                }
                usleep(350_000)
                try send(["method": "session/update", "params": ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "{\"ok\":true}"]]]])
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            default: try send(["id": id, "result": [:]])
            }
        }
    }
    static func serveCodex() throws {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        usleep(350_000)
        try send(["type": "item.completed", "item": ["type": "agent_message", "text": "{\"ok\":true}"]])
        try send(["type": "turn.completed"])
    }
}
