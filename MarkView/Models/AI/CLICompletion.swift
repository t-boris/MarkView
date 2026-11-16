import Foundation
import Darwin
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// One-shot, non-interactive completion through an assistant's CLI (`AssistantProvider.completion`) or over ACP.
///
/// App features (selection actions, translation, diagrams, Recursive Insight) use
/// this instead of calling a provider's HTTP API, so they run on whichever CLI and
/// model the user picked in `AIAssistantPreferences`. Unlike the AI console, a
/// completion can never change files: Claude runs with no tools (or read-only ones),
/// Codex in its read-only sandbox. The prompt goes over stdin, so its size is not
/// bounded by the argument-list limit.
enum CLICompletion {

    /// A window's assistant captured when an operation starts, including the CLI default model (nil).
    struct Assistant: Sendable {
        let tool: CLITool
        let model: String?

        static func project(_ project: URL?) -> Assistant {
            chosen(tool: AIAssistantPreferences.backend(project: project), project: project)
        }

        /// `tool` with the model chosen for it in `project` (the toolbar's assistant menu or Settings). It never reads the model a running
        /// agent tab reports: a tab shows what its session was started with or switched to with /model, and an operation such as
        /// End-to-End QA must not follow that.
        static func chosen(tool: CLITool, project: URL?) -> Assistant {
            Assistant(tool: tool, model: AIAssistantPreferences.model(for: tool, project: project))
        }
    }

    struct Request {
        /// The project the request works for: its assistant and models answer it (BUG-021).
        /// nil only outside any project; then the defaults apply.
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        /// JSON Schema the answer must match; the parsed object is `Result.structured`.
        var jsonSchema: [String: Any]? = nil
        /// Folder the CLI may read with its own tools. nil = no file access at all.
        var readableFolder: URL? = nil
        /// Further folders the CLI may read (a folder X-Ray's whole project); paths in the answer
        /// stay relative to `readableFolder`.
        var extraReadableFolders: [URL] = []
        /// Wall-clock limit; nil for long-running user-controlled work with explicit cancellation.
        var timeout: TimeInterval? = 180
        /// Set only to force a CLI (translation); otherwise `tool` is the project's assistant.
        var toolOverride: CLITool? = nil
        /// An operation tied to an open window uses that window's assistant throughout the operation.
        var assistantOverride: Assistant? = nil
        /// nil = the model selected for `tool` for the project (or the CLI default).
        var model: String? = nil
        /// Reasoning effort ("low", "medium", "high"); nil = the CLI's configured default.
        /// Low roughly halves the time of large structured answers.
        var effort: String? = nil
        /// Web search and fetching for research (Claude WebSearch/WebFetch, Codex --search).
        var allowWeb = false
        /// Images the prompt refers to. Claude opens them with its Read tool (so they must lie under
        /// `readableFolder`) and the prompt names their paths; Codex also gets them attached.
        var images: [URL] = []
        /// What this call is for, as written to the AI call log (e.g. "explore:<slug>").
        var label = ""

        var tool: CLITool {
            get { assistantOverride?.tool ?? toolOverride ?? AIAssistantPreferences.backend(project: project) }
            set { assistantOverride = nil; toolOverride = newValue }
        }
        var resolvedModel: String? {
            if let assistantOverride { return assistantOverride.model }
            return model ?? AIAssistantPreferences.model(for: tool, project: project)
        }
        /// The project's X-Ray model for this request's CLI.
        var xrayModel: String? { AIAssistantPreferences.xrayModel(for: tool, project: project) }
    }

    struct Result: Sendable {
        private struct InvalidStructuredOutput: LocalizedError {
            var errorDescription: String? { "The assistant's structured answer is not valid JSON." }
        }
        let text: String
        private let structuredJSON: Data?
        /// Decode a fresh value for each caller so mutable Foundation objects never cross executors.
        var structured: Any? {
            guard let structuredJSON else { return nil }
            return try? JSONSerialization.jsonObject(with: structuredJSON, options: [.fragmentsAllowed])
        }
        let inputTokens: Int
        let outputTokens: Int
        /// Claude reports the cost of a run; Codex reports tokens only.
        let costUSD: Double?
        /// Tool calls the CLI refused (Claude `permission_denials`): the tool and its query or URL.
        var refused: [(tool: String, input: String)] = []

        init(text: String, structured: Any?, inputTokens: Int, outputTokens: Int, costUSD: Double?) throws {
            self.text = text
            if let structured {
                guard JSONSerialization.isValidJSONObject([structured]) else {
                    throw InvalidStructuredOutput()
                }
                structuredJSON = try JSONSerialization.data(withJSONObject: structured, options: [.fragmentsAllowed])
            } else {
                structuredJSON = nil
            }
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
        }
    }

    enum Failure: LocalizedError {
        case toolNotFound(CLITool, String)
        case failed(CLITool, String)
        case timedOut(CLITool, TimeInterval)
        case invalidOutput(CLITool, String)

        var errorDescription: String? {
            switch self {
            case .toolNotFound(let tool, let hint):
                return "\(tool.displayName) (`\(tool.binaryName)`) was not found. \(hint) "
                    + "Set the path in DDE Settings → AI CLI Tools, or pick the other assistant."
            case .failed(let tool, let detail):
                return "\(tool.displayName) failed: \(detail)"
            case .timedOut(let tool, let seconds):
                return "\(tool.displayName) did not finish within \(Int(seconds)) s."
            case .invalidOutput(let tool, let detail):
                return "\(tool.displayName) returned an answer in an unexpected format: \(detail)"
            }
        }
    }

    /// What the assistant is doing during a run, for progress displays.
    typealias Activity = CompletionActivity

    /// Run one completion. `onDelta` receives text as it arrives — token by token
    /// for Claude, the whole answer at once for Codex (it does not stream).
    /// `onActivity` reports file reads, searches and answer growth as they happen.
    /// Cancelling the calling task terminates the CLI process.
    static func run(_ request: Request,
                    onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        let started = Date()
        let tool = request.tool
        let model = request.resolvedModel
        func log(_ result: Result?, outcome: String) {
            AICallLog.record(AICallLog.Entry(timestamp: started, project: (request.project ?? request.readableFolder)?.path ?? "",
                                             label: request.label, tool: tool.rawValue, model: model ?? "",
                                             effort: request.effort ?? "", seconds: Date().timeIntervalSince(started),
                                             inputTokens: result?.inputTokens ?? 0, outputTokens: result?.outputTokens ?? 0,
                                             costUSD: result?.costUSD, outcome: outcome))
        }
        do {
            let result = try await execute(request, tool: tool, model: model, onDelta: onDelta, onActivity: onActivity)
            log(result, outcome: "ok")
            return result
        } catch is CancellationError {
            log(nil, outcome: "cancelled")
            throw CancellationError()
        } catch {
            if case Failure.timedOut = error { log(nil, outcome: "timeout") } else { log(nil, outcome: "failed") }
            throw error
        }
    }

    private static func execute(_ request: Request, tool: CLITool, model: String?,
                                onDelta: (@Sendable (String) -> Void)?,
                                onActivity: (@Sendable (Activity) -> Void)?) async throws -> Result {
        guard let toolPath = CLIToolLocator.resolve(tool) else {
            let hint = CLIToolLocator.override(for: tool).map { "The configured path does not exist: \($0)." }
                ?? "Searched: \(CLIToolLocator.searchDirectories().joined(separator: ", "))."
            throw Failure.toolNotFound(tool, hint)
        }
        let workDir = request.readableFolder ?? scratchDirectory()
        if tool.usesACP {
            return try await ACPAssistant.run(request, tool: tool, toolPath: toolPath, model: model, workDir: workDir,
                                              onDelta: onDelta, onActivity: onActivity)
        }

        guard let completion = tool.provider.completion else {
            throw Failure.failed(tool, "has no one-shot mode")
        }
        let launch = try completion.launch(CompletionLaunchRequest(
            prompt: request.prompt, systemPrompt: request.systemPrompt, jsonSchema: request.jsonSchema,
            readableFolder: request.readableFolder, extraReadableFolders: request.extraReadableFolders,
            linkedFolders: { request.readableFolder.map { LinkedFolders.load(project: $0).map(\.url) } ?? [] },
            allowWeb: request.allowWeb, images: request.images, effort: request.effort, model: model,
            workDir: workDir, scratchDirectory: scratchDirectory))
        defer { launch.schemaFile.map { try? FileManager.default.removeItem(at: $0) } }

        let invocation = Invocation(tool: tool, executable: toolPath, arguments: launch.arguments,
                                    workDir: workDir, input: launch.input, timeout: request.timeout,
                                    parser: completion.makeParser(), sink: CompletionSink(onDelta: onDelta, onActivity: onActivity))
        let raw = try await withTaskCancellationHandler {
            try await invocation.start()
        } onCancel: {
            invocation.cancel()
        }

        var structured = raw.structured
        if request.jsonSchema != nil && structured == nil {
            // An assistant that cannot return a structured answer separately gives the schema-shaped answer as the message text.
            guard let data = raw.text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure.invalidOutput(tool, "expected JSON, got \(raw.text.prefix(200))")
            }
            structured = object
        }
        var result = try Result(text: raw.text, structured: structured, inputTokens: raw.inputTokens,
                            outputTokens: raw.outputTokens, costUSD: raw.costUSD)
        result.refused = raw.refused
        return result
    }

    // MARK: - Helpers

    /// Empty working directory for runs that must not see any files.
    private static func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markview-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Process plumbing

/// One CLI process: feeds stdin, hands each JSON line of its output to the provider's parser, enforces the timeout.
/// All mutable state is touched only on `queue`.
// unchecked Sendable: every mutable property is touched only on `queue`, a serial queue.
private final class Invocation: @unchecked Sendable {
    private let tool: CLITool
    private let spec: SubprocessSpec
    private let timeout: TimeInterval?
    private let parser: any CompletionStreamParser
    private let sink: CompletionSink
    private let queue = DispatchQueue(label: "markview.cli-completion")

    private var output = CompletionOutput()
    private var lineBuffer = ""
    private var stderrTail = ""
    private var cancelled = false
    private var child: SubprocessChild?
    private var ended: SubprocessExit?
    private var continuation: CheckedContinuation<CompletionOutput, Error>?

    init(tool: CLITool, executable: String, arguments: [String], workDir: URL,
         input: String, timeout: TimeInterval?, parser: any CompletionStreamParser, sink: CompletionSink) {
        self.tool = tool
        self.timeout = timeout
        self.parser = parser
        self.sink = sink
        // The prompt goes to the child's standard input, which is then closed. The timeout ends the child's whole group
        // (a CLI's own helpers included), with two seconds between the request and the kill.
        self.spec = SubprocessSpec(
            executable: executable, arguments: arguments, cwd: workDir,
            environment: ["PATH": CLIToolLocator.subprocessPath(toolPath: executable)],
            stdin: Data(input.utf8), timeout: timeout ?? 0, terminationGrace: 2)
    }

    func start() async throws -> CompletionOutput {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.launch(continuation) }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.child?.terminate()
        }
    }

    /// Runs on `queue`, which is also where the child's output and its exit are delivered, in that order.
    private func launch(_ continuation: CheckedContinuation<CompletionOutput, Error>) {
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        do {
            let started = try Subprocess.start(spec, queue: queue, onStdout: { [weak self] data in
                self?.consume(data)
            }, onStderr: { [weak self] data in
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            }, onExit: { [weak self] child, exit in
                AgentProcesses.remove(child)
                guard let self else { return }
                self.ended = exit
                self.consume(Data("\n".utf8))  // flush a final line without newline
                self.finish()
            })
            child = started
            AgentProcesses.add(started)
        } catch {
            self.continuation = nil
            continuation.resume(throwing: CLICompletion.Failure.failed(tool, error.localizedDescription))
        }
    }

    private func consume(_ data: Data) {
        lineBuffer += String(decoding: data, as: UTF8.self)
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            parser.handle(json, output: &output, sink: sink)
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if ended?.timedOut == true, let timeout {
            continuation.resume(throwing: CLICompletion.Failure.timedOut(tool, timeout))
        } else if let message = output.errorMessage {
            continuation.resume(throwing: CLICompletion.Failure.failed(tool, message))
        } else if let status = ended?.status, status != 0 {
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(throwing: CLICompletion.Failure.failed(
                tool, "exit code \(status)" + (detail.isEmpty ? "" : " — \(detail.suffix(600))")))
        } else if output.text.isEmpty && output.structured == nil {
            continuation.resume(throwing: parser.warning.map { CLICompletion.Failure.failed(tool, $0) }
                                ?? CLICompletion.Failure.invalidOutput(tool, "empty answer"))
        } else {
            continuation.resume(returning: output)
        }
    }
}
