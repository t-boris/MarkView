import Foundation
import Darwin

/// A long structured answer (BUG-045): the assistant stops in the middle of its JSON and MarkView
/// has to ask for the rest, join the turns without duplicating them, and give up only when the
/// answer really cannot be finished. The fixture plays the shapes a real CLI produces.
@main enum ACPContinuationTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--acp") { try serve(); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-acp-continuation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func run(_ scenario: String) async throws -> CLICompletion.Result {
            var request = CLICompletion.Request(project: root, prompt: scenario, readableFolder: nil)
            request.tool = .copilot
            request.timeout = 60
            request.jsonSchema = ["type": "object", "properties": ["body": ["type": "string"]], "required": ["body"]]
            return try await CLICompletion.run(request)
        }
        func body(_ result: CLICompletion.Result) -> String {
            ((result.structured as? [String: Any])?["body"] as? String) ?? ""
        }

        // A turn that ends in the middle of the JSON is continued even though the CLI called it a
        // normal end: this is exactly what failed before the fix.
        var joined = body(try await run("[resume]"))
        precondition(joined == expected, "A cut-off JSON answer must be continued and joined.")
        // The continuation repeats the tail MarkView quoted back to it; the repeat must be dropped.
        joined = body(try await run("[repeat-tail]"))
        precondition(joined == expected, "A repeated tail must not be joined twice.")
        // The continuation starts the whole answer again; the longer restart replaces what we had.
        joined = body(try await run("[restart]"))
        precondition(joined == expected, "A restarted answer must replace the cut-off one.")
        // A complete answer is never continued, whatever stop reason the CLI reports.
        joined = body(try await run("[complete-max-tokens]"))
        precondition(joined == "done", "A finished JSON answer must not spend continuation turns.")

        // An answer that never closes ends as an error, after the continuation budget is spent.
        do {
            _ = try await run("[never-ends]")
            preconditionFailure("An answer that never ends must fail.")
        } catch CLICompletion.Failure.invalidOutput(_, let detail) {
            precondition(detail.contains("cut off"), "The failure must say the answer was cut off: \(detail)")
            precondition(detail.contains("after 10 continuation turns"), "The spent turns must be reported: \(detail)")
        }
        // A continuation that adds nothing stops the attempt instead of repeating it ten times.
        do {
            _ = try await run("[no-progress]")
            preconditionFailure("An answer that cannot be continued must fail.")
        } catch CLICompletion.Failure.invalidOutput(_, let detail) {
            precondition(detail.contains("after 1 continuation turn"), "An empty continuation must end the attempt: \(detail)")
        }

        // Unstructured answers still follow the CLI's own stop reason.
        var plain = CLICompletion.Request(project: root, prompt: "[plain-cut-off]", readableFolder: nil)
        plain.tool = .copilot
        plain.timeout = 60
        let plainText = try await CLICompletion.run(plain).text
        precondition(plainText == "first part second part",
                     "A text answer stopped at the output limit must be continued too.")

        for _ in 0..<100 {
            if AgentProcesses.count == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(AgentProcesses.count == 0, "Finished test assistants must be removed.")
        print("ACP continuations: cut-off JSON, repeated tails, restarts, finished answers, the turn budget and text answers passed.")
    }

    /// The answer every joining scenario must end up with: long enough to be split, and without a
    /// repeating pattern that would make an overlap ambiguous.
    static let expected = (0..<40).map { "prototype-markup-\($0) section" }.joined(separator: " ") + " end"
    static var full: String { "{\"body\":\"" + expected + "\"}" }
    /// Where the first turn stops: past the restart probe, inside the JSON string.
    static let split = 300

    // MARK: - Fixture assistant

    static func send(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func chunk(_ text: String) throws {
        try send(["method": "session/update", "params": ["update": [
            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text],
        ]]])
    }

    static func serve() throws {
        var scenario = ""
        var turn = 0
        var sent = ""
        while let line = readLine() {
            let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let id = message["id"] else { continue }
            guard message["method"] as? String == "session/prompt" else {
                try send(["id": id, "result": message["method"] as? String == "session/new" ? ["sessionId": "fixture"] : [:]])
                continue
            }
            let params = message["params"] as! [String: Any]
            let text = ((params["prompt"] as! [[String: Any]]).first?["text"] as? String) ?? ""
            if turn == 0 { scenario = ["[resume]", "[repeat-tail]", "[restart]", "[complete-max-tokens]",
                                       "[never-ends]", "[no-progress]", "[plain-cut-off]"].first { text.contains($0) } ?? "" }
            turn += 1
            let head = String(full.prefix(split))
            switch (scenario, turn) {
            case ("[resume]", 1), ("[repeat-tail]", 1), ("[restart]", 1), ("[no-progress]", 1):
                sent = head
                try chunk(head)
                // The CLI calls a truncated turn a normal end: only the open JSON reveals it.
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[resume]", _):
                try chunk(String(full.dropFirst(split)))
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[repeat-tail]", _):
                try chunk(String(sent.suffix(200)) + String(full.dropFirst(split)))
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[restart]", _):
                try chunk(full)
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[no-progress]", _):
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[complete-max-tokens]", 1):
                try chunk("{\"body\":\"done\"}")
                try send(["id": id, "result": ["stopReason": "max_tokens"]])
            case ("[complete-max-tokens]", _):
                try chunk("{\"body\":\"continued after a finished answer\"}")
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[never-ends]", 1):
                try chunk("{\"body\":\"segment-1 " + String(repeating: "x", count: 200))
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[never-ends]", _):
                try chunk(" segment-\(turn) " + String(repeating: "y", count: 200))
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            case ("[plain-cut-off]", 1):
                try chunk("first part")
                try send(["id": id, "result": ["stopReason": "max_tokens"]])
            case ("[plain-cut-off]", _):
                try chunk(" second part")
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            default:
                try send(["id": id, "result": ["stopReason": "end_turn"]])
            }
        }
    }
}
