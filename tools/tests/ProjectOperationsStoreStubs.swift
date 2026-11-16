import Foundation

// Compile-time stand-ins for what `ProjectOperationsStore` and the discovery service mention but the checks do not exercise: the
// terminal that would run an operation, and the assistant that would answer discovery (here a script of canned answers). The store,
// the discovery service, the operations file, the run history and the scanner are the shipping code.

/// The terminal of a run: it starts nothing, and records that it was started.
@MainActor
final class TerminalSession: ObservableObject {
    nonisolated(unsafe) static var started: [String] = []
    let operationCommand: String?
    var onExit: ((Int32) -> Void)?
    var onLaunchFailure: ((String) -> Void)?
    var isRunning = false
    var webView: AnyObject { self }
    init(directory: URL, title: String, operationCommand: String?) { self.operationCommand = operationCommand }
    func start() { Self.started.append(operationCommand ?? "") }
    func signalProcessGroup(_ signal: Int32) {}
}

enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String?
        var jsonSchema: [String: Any]?
        var readableFolder: URL? = URL(fileURLWithPath: "/")
        var timeout: TimeInterval? = 180
        var model: String?
        var effort: String?
        var allowWeb = false
        var xrayModel: String? { "x-ray-model" }
        init(project: URL?, prompt: String, systemPrompt: String? = nil, jsonSchema: [String: Any]? = nil) {
            self.project = project; self.prompt = prompt; self.systemPrompt = systemPrompt; self.jsonSchema = jsonSchema
        }
    }
    struct Result {
        var text = ""
        var structured: Any?
    }
}

/// The assistant of discovery, as a script: each question takes the next canned answer.
enum StandInAssistant {
    nonisolated(unsafe) static var answers: [[String: Any]] = []
    nonisolated(unsafe) static var asked = 0
}

struct AIOperation<Request, Output> {
    struct Execution { let output: Output }
    enum Failure: Error { case noAnswer }
    let parse: (CLICompletion.Result) throws -> Output
    init(name: String, parse: @escaping (CLICompletion.Result) throws -> Output) { self.parse = parse }
    func execute(_ request: Request) async throws -> Execution {
        StandInAssistant.asked += 1
        guard !StandInAssistant.answers.isEmpty else { throw Failure.noAnswer }
        return Execution(output: try parse(CLICompletion.Result(structured: StandInAssistant.answers.removeFirst())))
    }
}

struct StandInProvider { var canSearchWeb: Bool }
struct StandInTool { var provider: StandInProvider }
enum AIAssistantPreferences {
    static func backend(project: URL?) -> StandInTool { StandInTool(provider: StandInProvider(canSearchWeb: true)) }
}

/// The editor request the store hands the window (defined with the editor view).
struct ProjectOperationEditRequest: Identifiable {
    let id = UUID()
    var operation: ProjectOperation?
    var kind: String?
    var environment: String?
    var label: String?
    init(operation: ProjectOperation?, kind: String? = nil, environment: String? = nil, label: String? = nil) {
        self.operation = operation; self.kind = kind; self.environment = environment; self.label = label
    }
}

extension Notification.Name {
    /// Posted when a notification of a finished run is clicked (declared with the Cockpit notices).
    static let cockpitNoticeOpened = Notification.Name("cockpitNoticeOpened")
}
