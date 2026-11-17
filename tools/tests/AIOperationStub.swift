import Foundation
// Compile-time stand-in for CLICompletion in the pure suites that compile a file asking the assistant through AIOperation
// (QAGenerator, ResearchMapTranslation). Those suites never run an assistant, or inject their own runner, so `run` is never reached.
enum CLICompletion {
    struct Request {
        func validateSchema() throws {}
        var prompt: String
        var label = ""
    }

    struct Result {
        var text = ""
        var structured: Any?
        var costUSD: Double?
    }

    enum Activity: Sendable { case thinking }

    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        fatalError("These suites inject a runner or never ask")
    }
}
