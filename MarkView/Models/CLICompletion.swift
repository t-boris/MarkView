import Foundation

/// One-shot, non-interactive completion through the Claude Code or Codex CLI.
///
/// App features (selection actions, translation, diagrams, Recursive Insight) use
/// this instead of calling a provider's HTTP API, so they run on whichever CLI and
/// model the user picked in `AIAssistantPreferences`. Unlike the AI console, a
/// completion can never change files: Claude runs with no tools (or read-only ones),
/// Codex in its read-only sandbox. The prompt goes over stdin, so its size is not
/// bounded by the argument-list limit.
enum CLICompletion {

    struct Request {
        var prompt: String
        var systemPrompt: String? = nil
        /// JSON Schema the answer must match; the parsed object is `Result.structured`.
        var jsonSchema: [String: Any]? = nil
        /// Folder the CLI may read with its own tools. nil = no file access at all.
        var readableFolder: URL? = nil
        var timeout: TimeInterval = 180
        var tool: CLITool = AIAssistantPreferences.backend
        /// nil = the model selected for `tool` in preferences (or the CLI default).
        var model: String? = nil
        /// Reasoning effort ("low", "medium", "high"); nil = the CLI's configured default.
        /// Low roughly halves the time of large structured answers.
        var effort: String? = nil
    }

    struct Result {
        let text: String
        let structured: Any?
        let inputTokens: Int
        let outputTokens: Int
        /// Claude reports the cost of a run; Codex reports tokens only.
        let costUSD: Double?

        /// Add this run to the workspace's usage counter.
        @MainActor
        func record(in db: SemanticDatabase?) {
            db?.addUsage(inputTokens: inputTokens, outputTokens: outputTokens,
                         costCents: (costUSD ?? 0) * 100)
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
    enum Activity: Sendable {
        /// Reading a file (absolute or working-directory-relative path).
        case read(String)
        /// Searching files for a pattern.
        case search(String)
        /// Running a shell command (Codex reads files this way).
        case run(String)
        /// Reasoning before the next action.
        case thinking
        /// Characters of the answer produced so far.
        case writing(Int)
        /// The next piece of the answer as it is written (structured answers included).
        case answerDelta(String)
    }

    /// Run one completion. `onDelta` receives text as it arrives — token by token
    /// for Claude, the whole answer at once for Codex (it does not stream).
    /// `onActivity` reports file reads, searches and answer growth as they happen.
    /// Cancelling the calling task terminates the CLI process.
    static func run(_ request: Request,
                    onDelta: (@Sendable (String) -> Void)? = nil,
                    onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        let tool = request.tool
        guard let toolPath = CLIToolLocator.resolve(tool) else {
            let hint = CLIToolLocator.override(for: tool).map { "The configured path does not exist: \($0)." }
                ?? "Searched: \(CLIToolLocator.searchDirectories().joined(separator: ", "))."
            throw Failure.toolNotFound(tool, hint)
        }
        let model = request.model ?? AIAssistantPreferences.model(for: tool)
        let workDir = request.readableFolder ?? scratchDirectory()
        if tool.usesACP {
            return try await ACPAssistant.run(request, tool: tool, toolPath: toolPath, model: model, workDir: workDir,
                                              onDelta: onDelta, onActivity: onActivity)
        }

        var arguments: [String]
        var input = request.prompt
        var schemaFile: URL?
        switch tool {
        case .cline, .copilot:
            preconditionFailure("\(tool.displayName) runs through ACPAssistant")
        case .claude:
            arguments = ["-p", "--safe-mode", "--no-session-persistence",
                         "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--tools", request.readableFolder == nil ? "" : "Read,Grep,Glob"]
            arguments += tool.modelArgs(model)
            if let effort = request.effort { arguments += ["--effort", effort] }
            if let system = request.systemPrompt {
                arguments += ["--system-prompt", system]
            }
            if let schema = request.jsonSchema {
                arguments += ["--json-schema", try jsonString(schema)]
            }
        case .codex:
            arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                         "--json", "--color", "never", "-C", workDir.path]
            arguments += tool.modelArgs(model)
            if let effort = request.effort { arguments += ["-c", "model_reasoning_effort=\(effort)"] }
            if let schema = request.jsonSchema {
                let url = scratchDirectory().appendingPathComponent("schema-\(UUID().uuidString).json")
                try Data(jsonString(strictSchema(schema)).utf8).write(to: url)
                schemaFile = url
                arguments += ["--output-schema", url.path]
            }
            arguments.append("-")  // read the prompt from stdin
            // Codex has no system-prompt flag; the instructions lead the prompt.
            if let system = request.systemPrompt {
                input = "<instructions>\n\(system)\n</instructions>\n\n\(request.prompt)"
            }
        }
        defer { schemaFile.map { try? FileManager.default.removeItem(at: $0) } }

        let invocation = Invocation(tool: tool, executable: toolPath, arguments: arguments,
                                    workDir: workDir, input: input, timeout: request.timeout,
                                    onDelta: onDelta, onActivity: onActivity)
        let raw = try await withTaskCancellationHandler {
            try await invocation.start()
        } onCancel: {
            invocation.cancel()
        }

        var structured = raw.structured
        if request.jsonSchema != nil && structured == nil {
            // Codex returns the schema-shaped answer as the message text.
            guard let data = raw.text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure.invalidOutput(tool, "expected JSON, got \(raw.text.prefix(200))")
            }
            structured = object
        }
        return Result(text: raw.text, structured: structured, inputTokens: raw.inputTokens,
                      outputTokens: raw.outputTokens, costUSD: raw.costUSD)
    }

    // MARK: - Helpers

    /// Empty working directory for runs that must not see any files.
    private static func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markview-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Codex (OpenAI structured outputs) accepts only strict schemas: every object
    /// closes `additionalProperties` and lists all of its properties as required.
    /// An open object with no declared properties cannot be expressed and becomes an
    /// empty object — declare the keys you need in the schema itself.
    static func strictSchema(_ schema: Any) -> Any {
        if let array = schema as? [Any] { return array.map(strictSchema) }
        guard var object = schema as? [String: Any] else { return schema }
        for (key, value) in object where value is [String: Any] || value is [Any] {
            object[key] = strictSchema(value)
        }
        if object["type"] as? String == "object" || object["properties"] != nil {
            let properties = object["properties"] as? [String: Any] ?? [:]
            object["properties"] = properties
            object["additionalProperties"] = false
            object["required"] = Array(properties.keys).sorted()
        }
        return object
    }
}

// MARK: - Process plumbing

/// One CLI process: feeds stdin, parses the event stream, enforces the timeout.
/// All mutable state is touched only on `queue`.
private final class Invocation: @unchecked Sendable {
    struct Output {
        var text = ""
        var structured: Any?
        var inputTokens = 0
        var outputTokens = 0
        var costUSD: Double?
        var errorMessage: String?
    }

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    private let tool: CLITool
    private let process = Process()
    private let input: String
    private let timeout: TimeInterval
    private let onDelta: (@Sendable (String) -> Void)?
    private let onActivity: (@Sendable (CLICompletion.Activity) -> Void)?
    /// Tool of the content block being streamed (Claude), so tool input is not counted as answer.
    private var blockTool: String?
    private var answerChars = 0
    /// Last Codex "error" event; fatal only if no answer arrives.
    private var codexWarning: String?
    private let queue = DispatchQueue(label: "markview.cli-completion")

    private var output = Output()
    private var lineBuffer = ""
    private var stderrTail = ""
    private var streamedText = ""
    private var cancelled = false
    private var timedOut = false
    private var continuation: CheckedContinuation<Output, Error>?

    init(tool: CLITool, executable: String, arguments: [String], workDir: URL,
         input: String, timeout: TimeInterval, onDelta: (@Sendable (String) -> Void)?,
         onActivity: (@Sendable (CLICompletion.Activity) -> Void)?) {
        self.tool = tool
        self.input = input
        self.timeout = timeout
        self.onDelta = onDelta
        self.onActivity = onActivity
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CLIToolLocator.subprocessPath(toolPath: executable)
        process.environment = env
    }

    func start() async throws -> Output {
        _ = Self.ignoreSIGPIPE  // a CLI that exits early must not kill the app mid-write
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.launch(continuation) }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            if self.process.isRunning { self.process.terminate() }
        }
    }

    private func launch(_ continuation: CheckedContinuation<Output, Error>) {
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async {
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let rest = stdout.fileHandleForReading.readDataToEndOfFile()
            self.queue.async {
                if !rest.isEmpty { self.consume(rest) }
                self.consume(Data("\n".utf8))  // flush a final line without newline
                self.finish()
            }
        }

        do {
            try process.run()
        } catch {
            self.continuation = nil
            continuation.resume(throwing: CLICompletion.Failure.failed(tool, error.localizedDescription))
            return
        }

        // Write stdin off this queue so a large prompt and the stdout reader
        // cannot block each other.
        let data = Data(input.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
        }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.timedOut = true
            self.process.terminate()
        }
    }

    private func consume(_ data: Data) {
        lineBuffer += String(decoding: data, as: UTF8.self)
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            switch tool {
            case .claude: handleClaude(type, json)
            case .codex: handleCodex(type, json)
            case .cline, .copilot: break   // ACPAssistant has its own connection
            }
        }
    }

    private func handleClaude(_ type: String, _ json: [String: Any]) {
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_start" {
                let block = event["content_block"] as? [String: Any]
                blockTool = block?["type"] as? String == "tool_use" ? block?["name"] as? String : nil
                if block?["type"] as? String == "thinking" { onActivity?(.thinking) }
                return
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return }
            if delta["type"] as? String == "input_json_delta", let part = delta["partial_json"] as? String,
               !["Read", "Grep", "Glob"].contains(blockTool ?? "") {
                // Structured output arrives as the input of a final tool call.
                answerChars += part.count
                onActivity?(.writing(answerChars))
                onActivity?(.answerDelta(part))
            }
            guard delta["type"] as? String == "text_delta", let text = delta["text"] as? String else { return }
            streamedText += text
            answerChars += text.count
            onActivity?(.writing(answerChars))
            onActivity?(.answerDelta(text))
            onDelta?(text)
        case "assistant":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "Read": if let path = input["file_path"] as? String { onActivity?(.read(path)) }
                case "Grep", "Glob": onActivity?(.search(input["pattern"] as? String ?? ""))
                default: break
                }
            }
        case "result":
            output.text = json["result"] as? String ?? streamedText
            output.structured = json["structured_output"]
            output.costUSD = json["total_cost_usd"] as? Double
            if let usage = json["usage"] as? [String: Any] {
                output.inputTokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                output.outputTokens = usage["output_tokens"] as? Int ?? 0
            }
            if json["is_error"] as? Bool == true {
                output.errorMessage = output.text.isEmpty ? "the run reported an error" : output.text
            }
        default:
            break
        }
    }

    private func handleCodex(_ type: String, _ json: [String: Any]) {
        switch type {
        case "item.started":
            guard let item = json["item"] as? [String: Any] else { return }
            if item["type"] as? String == "command_execution", let command = item["command"] as? String {
                onActivity?(.run(command))
            } else if item["type"] as? String == "reasoning" {
                onActivity?(.thinking)
            }
        case "item.completed":
            guard let item = json["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else { return }
            output.text = text
            onDelta?(text)
        case "turn.completed":
            if let usage = json["usage"] as? [String: Any] {
                output.inputTokens = usage["input_tokens"] as? Int ?? 0
                output.outputTokens = usage["output_tokens"] as? Int ?? 0
            }
        case "turn.failed":
            let error = json["error"] as? [String: Any]
            output.errorMessage = Self.readableCodexError(error?["message"] as? String ?? "the turn failed")
        case "error":
            // Also used for non-fatal warnings (e.g. missing model metadata); only
            // `turn.failed` ends the run. Kept to explain an empty answer.
            codexWarning = Self.readableCodexError(json["message"] as? String ?? "unknown error")
        default:
            break
        }
    }

    /// Codex passes API errors on as raw JSON (`{"type":"error","status":400,"error":{"message":…}}`).
    /// Keep the message, and point model problems at the place to choose another model.
    private static func readableCodexError(_ raw: String) -> String {
        var message = raw
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (object["error"] as? [String: Any])?["message"] as? String {
            message = inner
        }
        if message.localizedCaseInsensitiveContains("model") {
            message += " Choose another Codex model in the toolbar's assistant menu (or DDE Settings)."
        }
        return message
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if timedOut {
            continuation.resume(throwing: CLICompletion.Failure.timedOut(tool, timeout))
        } else if let message = output.errorMessage {
            continuation.resume(throwing: CLICompletion.Failure.failed(tool, message))
        } else if process.terminationStatus != 0 {
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(throwing: CLICompletion.Failure.failed(
                tool, "exit code \(process.terminationStatus)" + (detail.isEmpty ? "" : " — \(detail.suffix(600))")))
        } else if output.text.isEmpty && output.structured == nil {
            continuation.resume(throwing: codexWarning.map { CLICompletion.Failure.failed(tool, $0) }
                                ?? CLICompletion.Failure.invalidOutput(tool, "empty answer"))
        } else {
            continuation.resume(returning: output)
        }
    }
}
