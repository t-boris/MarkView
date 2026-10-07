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
        var effort: String? = nil
        var label = ""
    }
    struct Result { let text: String; let structured: Any?; let inputTokens: Int; let outputTokens: Int }
    enum Activity { case read, search, run, thinking, writing, answerDelta, webSearch, webFetch }
    /// Never called by the checks: they exercise validation and Mermaid output only.
    static func run(_ r: Request, onDelta: (@Sendable (String) -> Void)? = nil, onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        fatalError("not used by the checks")
    }
}
