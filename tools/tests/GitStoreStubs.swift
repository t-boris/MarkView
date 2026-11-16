import Foundation

// Compile-time stand-ins for what `GitHubStore.swift` names outside the Git folder and the tests never run: the AI call that explains a
// failed run and the database its answer is recorded in. The ownership checks start jobs, never an explanation.

final class SemanticDatabase {}

enum ActionOutputLanguage {
    static func explanationLine() -> String { "" }
}

enum CLICompletion {
    struct Request {
        var project: URL?
        var prompt: String
        var systemPrompt: String
        var model = ""
        var effort = ""
        var timeout: TimeInterval = 0
        var xrayModel: String { "" }
    }

    struct Result {
        var text = ""
        func record(in database: SemanticDatabase?) {}
    }
}

enum AIOperation<Request, Result> {
    static func ask(_ request: Request, name: String, onDelta: @escaping @Sendable (String) -> Void) async throws -> Result {
        throw CancellationError()
    }
}
