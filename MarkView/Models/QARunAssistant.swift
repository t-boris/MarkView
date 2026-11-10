import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-005): the assistant of a run is the project's own AI command line tool, asked once per turn of a
// step. It reads no files: everything it needs is in the prompt (the step and the page as text), and what it answers is only one move.

final class QACLIAssistant: QAAssistant {
    private let project: URL
    private let lock = NSLock()
    private var cost = 0.0
    private var asked = 0

    init(project: URL) { self.project = project }

    /// What the answers cost so far, for the tools that report a cost.
    var costUSD: Double { lock.withLock { cost } }
    var calls: Int { lock.withLock { asked } }

    func decide(system: String, prompt: String, schema: [String: Any]) async throws -> Any? {
        var request = CLICompletion.Request(project: project, prompt: prompt, systemPrompt: system, jsonSchema: schema, readableFolder: nil,
                                            timeout: 150, label: "qa-step")
        request.effort = "low"
        let result = try await CLICompletion.run(request)
        lock.withLock {
            cost += result.costUSD ?? 0
            asked += 1
        }
        return result.structured
    }
}
