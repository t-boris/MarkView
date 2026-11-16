import Foundation

// Stand-ins for what the X-Ray stores ask of the rest of the app, so that the shipping ArchitectureStore, ChangeReviewStore,
// XRayFilterStore, CodeExplainStore and CodeNavigationStore can run in a test (AR-19): the assistant (`CLICompletion`, here an assistant
// that waits for the check to answer or for its own cancellation, as the real one waits for its process), the project database (an actor
// that counts what is saved to it), the assistant preferences and the GitHub switch. Nothing here starts a process or reads a setting.

enum CLITool: String, CaseIterable {
    case claude
    var displayName: String { "Claude Code" }
}

struct StandInFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor enum StandInAssistant {
    /// What one asked call is waiting for.
    struct Call {
        let label: String
        let prompt: String
        let continuation: CheckedContinuation<CLICompletion.Result, Error>
    }
    /// The calls made, in order, and the ones still waiting.
    static var asked: [String] = []
    static var waiting: [UUID: Call] = [:]
    /// Calls that ended because their task was cancelled (the real assistant ends its process then).
    static var cancelled: [String] = []
    static var finished: [String] = []
    /// Answers by call label; the call waits until `answer` or `fail` is called for its label unless one is scripted here.
    static var scripted: [String: CLICompletion.Result] = [:]
    /// Pieces streamed to `onDelta` before the answer, by label.
    static var deltas: [String: [String]] = [:]

    static func reset() {
        asked = []; waiting = [:]; cancelled = []; finished = []; scripted = [:]; deltas = [:]
    }

    static func waitingLabels() -> [String] { waiting.values.map(\.label).sorted() }

    /// Answer every waiting call whose label starts with `prefix`.
    static func answer(_ prefix: String, text: String = "", structured: Any? = nil) {
        for (id, call) in waiting where call.label.hasPrefix(prefix) {
            waiting[id] = nil
            finished.append(call.label)
            call.continuation.resume(returning: CLICompletion.Result(text: text, structured: structured, inputTokens: 1, outputTokens: 1, costUSD: nil))
        }
    }

    /// Fail every waiting call whose label starts with `prefix`.
    static func fail(_ prefix: String, message: String = "The assistant failed.") {
        for (id, call) in waiting where call.label.hasPrefix(prefix) {
            waiting[id] = nil
            finished.append(call.label)
            call.continuation.resume(throwing: StandInFailure(message: message))
        }
    }

    static func run(_ request: CLICompletion.Request, onDelta: (@Sendable (String) -> Void)?) async throws -> CLICompletion.Result {
        let label = request.label
        asked.append(label)
        if let result = scripted[label] { finished.append(label); return result }
        let id = UUID()
        for piece in deltas[label] ?? [] { onDelta?(piece) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = Call(label: label, prompt: request.prompt, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in
                if let call = waiting.removeValue(forKey: id) {
                    cancelled.append(call.label)
                    call.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
}

enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var jsonSchema: [String: Any]? = nil
        var readableFolder: URL? = nil
        var extraReadableFolders: [URL] = []
        var timeout: TimeInterval? = 180
        var toolOverride: CLITool? = nil
        var model: String? = nil
        var effort: String? = nil
        var label = ""
        var tool: CLITool { toolOverride ?? .claude }
        var xrayModel: String? { "fast" }
    }

    struct Result: Sendable {
        let text: String
        private let json: Data?
        var structured: Any? { json.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } }
        let inputTokens: Int
        let outputTokens: Int
        var costUSD: Double? = nil

        init(text: String, structured: Any?, inputTokens: Int, outputTokens: Int, costUSD: Double? = nil) {
            self.text = text
            self.json = structured.map { try! JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
        }
    }

    enum Activity: Sendable {
        case read(String), search(String), run(String), thinking, writing(Int), answerDelta(String), webSearch(String), webFetch(String)
    }

    static func run(_ request: Request, onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        try await StandInAssistant.run(request, onDelta: onDelta)
    }
}

enum AIAssistantPreferences {
    static func backend(project: URL?) -> CLITool { .claude }
    static func xrayModel(for tool: CLITool, project: URL?) -> String? { "fast" }
    static var autoAnalyze: Bool { false }
    static func summary(tool: CLITool, model: String) -> String { "\(tool.displayName) · \(model)" }
}

enum CLIToolLocator {
    struct ProbeResult { var path: String?; var version: String?; var loggedIn: Bool?; var error: String? }
    static func probe(_ tool: CLITool) async -> ProbeResult { ProbeResult(path: "/usr/bin/true", version: "1", loggedIn: true, error: nil) }
    static func subprocessPath(toolPath: String?) -> String { "/usr/bin:/bin" }
}

enum GitHubSettings {
    static var enabled: Bool { false }
}

/// The project database as the stores see it: what it holds, and how many times it was written to.
actor SemanticDatabase {
    private(set) var snapshot: ArchitectureSnapshot?
    private(set) var snapshotSaves = 0
    private(set) var reviews: [String: String] = [:]
    private(set) var reviewSaves = 0
    private(set) var usageRuns = 0

    func loadArchitecture() -> ArchitectureSnapshot? { snapshot }
    func saveArchitecture(_ next: ArchitectureSnapshot) throws { snapshot = next; snapshotSaves += 1 }
    func loadArchitectureReview(key: String) -> String? { reviews[key] }
    func saveArchitectureReview(key: String, json: String) { reviews[key] = json; reviewSaves += 1 }
    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) { usageRuns += 1 }
}

// Where the stores save an answer as a document; the checks never save one.
enum FeatureStore { static var today: String { "2026-01-01" } }
enum FeatureAssistant { static func nextNumbered(_ prefix: String, in folder: URL) -> String { prefix + "-001" } }
func featureSlug(_ text: String) -> String { text.lowercased().replacingOccurrences(of: " ", with: "-") }
