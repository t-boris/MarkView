import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): asks the assistant for a scenario and gives the answer back with what is wrong with
// it until it is whole or the tries are used up. What the assistant is asked and how its answer is read is QAGeneration; the call to
// the assistant itself is passed in, so this loop is checked on its own (tools/tests/qa-tests.sh). Foundation only.

enum QAGenerator {
    /// What one call to the assistant brings back.
    struct Answer {
        var structured: Any?
        var costUSD: Double?
    }

    struct Outcome {
        var scenario: QAScenario
        /// What is still wrong with the scenario after the last try; empty when it is whole.
        var remaining: [String]
        var attempts: Int
        var costUSD: Double?
    }

    /// One call to the assistant: the prompt in, the answer out.
    typealias Complete = (_ prompt: String) async throws -> Answer

    /// Asks up to `maxAttempts` times. A try that comes back with problems is repeated with the earlier answer and the problems in the
    /// prompt; the last scenario is returned either way, so the person can fix what is left in the editor.
    static func generate(_ request: QAGenerationRequest, maxAttempts: Int = 3, onAttempt: ((Int) -> Void)? = nil,
                         complete: Complete) async throws -> Outcome {
        let base = QAGeneration.prompt(request)
        var prompt = base
        var last: QAGenerationResult?
        var cost: Double?
        let tries = max(1, maxAttempts)
        for attempt in 1...tries {
            try Task.checkCancellation()
            onAttempt?(attempt)
            let answer = try await complete(prompt)
            if let spent = answer.costUSD { cost = (cost ?? 0) + spent }
            let result = QAGeneration.parse(answer.structured, request: request)
            last = result
            if result.isClean { return Outcome(scenario: result.scenario, remaining: [], attempts: attempt, costUSD: cost) }
            let previous = answer.structured.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            prompt = QAGeneration.retryPrompt(base: base, previous: previous, result: result)
        }
        let final = last ?? QAGeneration.parse(nil, request: request)
        return Outcome(scenario: final.scenario, remaining: final.messages, attempts: tries, costUSD: cost)
    }
}
