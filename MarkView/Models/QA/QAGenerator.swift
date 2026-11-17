import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): asks the assistant for a scenario and gives the answer back with what is wrong with
// it until it is whole or the tries are used up (an AIOperation with `maxAttempts - 1` repairs). What the assistant is asked and how its
// answer is read is QAGeneration; the request around a prompt and the runner are passed in, so the tries are checked on their own
// (app-hosted QA tests).

enum QAGenerator {
    struct Outcome {
        var scenario: QAScenario
        /// What is still wrong with the scenario after the last try; empty when it is whole.
        var remaining: [String]
        var attempts: Int
        var costUSD: Double?
    }

    /// A try that came back with problems: the next prompt carries them.
    private struct Unsound: Error {
        let result: QAGenerationResult
    }

    /// Asks up to `maxAttempts` times. A try that comes back with problems is repeated with the earlier answer and the problems in the
    /// prompt; the last scenario is returned either way, so the person can fix what is left in the editor. `prepare` makes the request
    /// of a prompt (the assistant, folder, images and schema belong to the caller).
    static func generate(_ request: QAGenerationRequest, maxAttempts: Int = 3, onAttempt: (@Sendable (Int) -> Void)? = nil,
                         prepare: @escaping @Sendable (_ prompt: String) -> CLICompletion.Request,
                         onActivity: (@Sendable (CLICompletion.Activity) -> Void)? = nil,
                         runner: @escaping AIOperation<String, QAGenerationResult>.Runner = AIAssistantRunner.run) async throws -> Outcome {
        let base = QAGeneration.prompt(request)
        let tries = max(1, maxAttempts)
        var cost: Double?
        let asking = AIOperation<String, (result: QAGenerationResult, attempt: Int)>(
            name: "qa-generate",
            maxRepairAttempts: tries - 1,
            buildRequest: { prompt in
                onAttempt?(1)
                return prepare(prompt)
            },
            parse: { _, answer, attempt in (QAGeneration.parse(answer.structured, request: request), attempt.number) },
            validate: { _, read, attempt in
                if !read.result.isClean, !attempt.isLast { throw Unsound(result: read.result) }
            },
            repair: { context in
                onAttempt?(context.attempt.number + 1)
                let previous = context.result.structured.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? ""
                guard let unsound = context.error as? Unsound else { return prepare(base) }
                return prepare(QAGeneration.retryPrompt(base: base, previous: previous, result: unsound.result))
            },
            onResult: { answer in
                if let spent = answer.costUSD { cost = (cost ?? 0) + spent }
            },
            runner: runner)
        let (read, _) = try await asking.execute(base, onActivity: onActivity)
        return Outcome(scenario: read.result.scenario, remaining: read.result.isClean ? [] : read.result.messages,
                       attempts: read.attempt, costUSD: cost)
    }
}
