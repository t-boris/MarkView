import Foundation
// Compile-time stand-in for CLICompletion (see diagram-tests.sh).
enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var jsonSchema: [String: Any]? = nil
        var readableFolder: URL? = nil
        var timeout: TimeInterval = 180
        var model: String? = nil
        var effort: String? = nil
        var label = ""
    }
    struct Result { let text: String; let structured: Any?; let inputTokens: Int; let outputTokens: Int }
    enum Activity { case read, search, run, thinking, writing, answerDelta, webSearch, webFetch }
    /// The answers `run` gives in turn (the last one repeats) and the prompts it was asked, for the checks of `generate`.
    nonisolated(unsafe) static var answers: [Result] = []
    nonisolated(unsafe) static var prompts: [String] = []
    static func run(_ r: Request, onDelta: (@Sendable (String) -> Void)? = nil, onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        prompts.append(r.prompt)
        guard !answers.isEmpty else { fatalError("no scripted answer") }
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}
