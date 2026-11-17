import Foundation
import os

// End-to-End QA (feature end-to-end-qa, DEC-005): the assistant of a run is the project's own AI command line tool, asked once per turn of a
// step. It reads no files: everything it needs is in the prompt (the step and the page as text), and what it answers is only one move.

final class QACLIAssistant: QAAssistant {
    private struct Usage: Sendable {
        var cost = 0.0
        var calls = 0
    }
    private let project: URL
    private let assistant: CLICompletion.Assistant
    private let usage = OSAllocatedUnfairLock(initialState: Usage())

    init(project: URL, assistant: CLICompletion.Assistant? = nil) {
        self.project = project
        self.assistant = assistant ?? .project(project)
    }

    /// What the answers cost so far, for the tools that report a cost.
    var costUSD: Double { usage.withLock { $0.cost } }
    var calls: Int { usage.withLock { $0.calls } }

    func decide(system: String, prompt: String, schema: [String: Any], isolation: isolated (any Actor)?) async throws -> Any? {
        var request = CLICompletion.Request(project: project, prompt: prompt, systemPrompt: system, jsonSchema: schema, readableFolder: nil,
                                            timeout: 150, assistantOverride: assistant, label: "qa-step")
        request.effort = "low"
        let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>.ask(request, name: "qa-step")
        usage.withLock {
            $0.cost += result.costUSD ?? 0
            $0.calls += 1
        }
        return result.structured
    }
}
