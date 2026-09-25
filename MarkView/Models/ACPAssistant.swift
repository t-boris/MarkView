import Foundation

/// Assistants driven over the Agent Client Protocol (`<cli> --acp`): JSON-RPC 2.0 over
/// stdio — Cline and GitHub Copilot.
///
/// Why ACP: every tool call that needs approval asks the client
/// (`session/request_permission`, with the tool's kind), which makes a read-only run
/// enforceable — MarkView allows only reads inside the project and searches, and
/// refuses shell commands, edits and everything else. Prompts travel over stdin with no
/// size limit. On top of that each assistant is started read-only where it can be:
/// Cline in Plan mode (its editing tools off), Copilot with only its view/grep/glob
/// tools available to the model.
///
/// Neither has a schema flag nor a system prompt over ACP, so the instructions and the
/// JSON schema lead the prompt, and a malformed JSON answer gets one repair turn.
enum ACPAssistant {
    /// How one assistant is started and what it needs around the protocol.
    private struct Profile {
        var arguments: [String]
        /// Session mode that keeps the assistant read-only, set after `session/new`.
        var readOnlyMode: String?
        /// A chunk the CLI puts into the answer that is not part of it.
        var noticePrefix: String?
    }

    private static func profile(_ tool: CLITool, effort: String?) -> Profile {
        switch tool {
        case .copilot:
            // Only these tools exist for the model: no shell, no edits, no web, no subagents.
            var arguments = ["--acp", "--no-auto-update", "--no-ask-user", "--disable-builtin-mcps",
                             "--no-custom-instructions"]
            if let effort { arguments += ["--reasoning-effort", effort] }
            arguments += ["--available-tools", "view", "grep", "glob"]
            return Profile(arguments: arguments, readOnlyMode: nil, noticePrefix: "Info: Disabled tools:")
        default:
            var arguments = ["--acp"]
            if let effort { arguments += ["--thinking", effort] }
            return Profile(arguments: arguments, readOnlyMode: "plan", noticePrefix: nil)
        }
    }

    /// Ask `tool` once. Mirrors `CLICompletion.run` for the other assistants.
    static func run(_ request: CLICompletion.Request, tool: CLITool, toolPath: String, model: String?, workDir: URL,
                    onDelta: (@Sendable (String) -> Void)?,
                    onActivity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
        let profile = profile(tool, effort: request.effort)
        let root = request.readableFolder?.standardizedFileURL
        let connection = ACPConnection(tool: tool, executable: toolPath, arguments: profile.arguments, workDir: workDir)
        // Reads inside the project and searches; nothing when the request may not see files.
        connection.permit = { kind, input in
            guard let root else { return false }
            switch kind {
            case "search":
                return true
            case "read":
                var paths = ((input["files"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }
                paths += [input["path"] as? String].compactMap { $0 }
                paths += (input["paths"] as? [String]) ?? [input["paths"] as? String].compactMap { $0 }
                // A search without paths runs in the working directory: the project.
                return paths.allSatisfy { path in
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                    let full = url.standardizedFileURL.path
                    return full == root.path || full.hasPrefix(root.path + "/")
                }
            default:
                return false
            }
        }
        let state = RunState(onDelta: onDelta, onActivity: onActivity, noticePrefix: profile.noticePrefix)
        connection.onUpdate = { update in state.receive(update) }

        return try await withTaskCancellationHandler {
            try await connection.start()
            defer { connection.close() }
            let timeout = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(request.timeout * 1_000_000_000))
                if !Task.isCancelled { connection.fail(.timedOut(tool, request.timeout)) }
            }
            defer { timeout.cancel() }

            _ = try await connection.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "MarkView", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""],
            ])
            let session = try await connection.request("session/new", ["cwd": workDir.path, "mcpServers": []])
            guard let sessionId = session["sessionId"] as? String else {
                throw CLICompletion.Failure.invalidOutput(tool, "no session id")
            }
            connection.sessionId = sessionId
            // Cline's Plan mode turns its editing tools off; the permissions above refuse the rest.
            if let mode = profile.readOnlyMode {
                _ = try await connection.request("session/set_mode", ["sessionId": sessionId, "modeId": mode])
            }
            if let model, !model.isEmpty {
                // Cline accepts any model id and then answers nothing: check it against the account.
                let offered = ((session["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? [])
                    .compactMap { $0["modelId"] as? String }
                if !offered.isEmpty, !offered.contains(model) {
                    throw CLICompletion.Failure.failed(tool, "model “\(model)” is not offered by your \(tool.displayName) account. "
                        + "Choose another \(tool.displayName) model in the toolbar's assistant menu.")
                }
                do {
                    _ = try await connection.request("session/set_model", ["sessionId": sessionId, "modelId": model])
                } catch {
                    throw CLICompletion.Failure.failed(tool, "model “\(model)” is not available: \(error.localizedDescription) "
                        + "Choose another \(tool.displayName) model in the toolbar's assistant menu.")
                }
            }

            var text = try await prompt(composePrompt(request), tool: tool, connection: connection, state: state)
            var structured: Any?
            if let schema = request.jsonSchema {
                structured = parseJSON(text, schema: schema)
                if structured == nil {
                    // One repair turn in the same session: the model sees its own answer.
                    let repaired = try await prompt("""
                        Your last answer was not one valid JSON object matching the schema. Reply again with \
                        only that JSON object — no prose, no Markdown fences.
                        """, tool: tool, connection: connection, state: state)
                    structured = parseJSON(repaired, schema: schema)
                    if structured != nil { text = repaired }
                }
                guard structured != nil else {
                    throw CLICompletion.Failure.invalidOutput(tool, "expected JSON, got \(text.prefix(200))")
                }
            }
            guard !text.isEmpty || structured != nil else {
                throw CLICompletion.Failure.invalidOutput(tool, "empty answer")
            }
            return CLICompletion.Result(text: text, structured: structured, inputTokens: state.inputTokens,
                                        outputTokens: state.outputTokens, costUSD: nil)
        } onCancel: {
            connection.cancel()
        }
    }

    /// One `session/prompt` turn; the answer text streamed while it ran.
    private static func prompt(_ text: String, tool: CLITool, connection: ACPConnection, state: RunState) async throws -> String {
        guard let sessionId = connection.sessionId else { throw CLICompletion.Failure.failed(tool, "no session") }
        state.reset()   // anything streamed before this turn is not its answer
        let result = try await connection.request("session/prompt", [
            "sessionId": sessionId, "prompt": [["type": "text", "text": text]],
        ])
        // Copilot reports the turn's tokens; Cline does not.
        if let usage = result["usage"] as? [String: Any] {
            state.addUsage(input: (usage["inputTokens"] as? NSNumber)?.intValue ?? 0,
                           output: (usage["outputTokens"] as? NSNumber)?.intValue ?? 0)
        }
        switch result["stopReason"] as? String {
        case "cancelled":
            throw CancellationError()
        case "refusal":
            throw CLICompletion.Failure.failed(tool, "the model refused the request")
        default:
            return state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Instructions first (ACP has no system prompt), then the schema, then the prompt.
    private static func composePrompt(_ request: CLICompletion.Request) -> String {
        var parts: [String] = []
        if let system = request.systemPrompt { parts.append("<instructions>\n\(system)\n</instructions>") }
        if let schema = request.jsonSchema,
           let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            parts.append("""
                <answer-format>
                Answer with exactly one JSON object that matches this JSON Schema, and nothing else — no \
                prose before or after it, no Markdown code fence:
                \(String(decoding: data, as: UTF8.self))
                </answer-format>
                """)
        }
        if request.readableFolder == nil {
            parts.append("Answer from the text given here; do not use any tools.")
        } else {
            // Refused calls cost a round trip each: say up front what works.
            parts.append("Tools: only read_files and search_codebase are available (read-only). Shell commands, "
                + "edits and web fetches are refused, so do not try them.")
        }
        parts.append(request.prompt)
        return parts.joined(separator: "\n\n")
    }

    /// The JSON object in `text` (a fenced block or the outermost braces), when it has
    /// every top-level key the schema requires.
    static func parseJSON(_ text: String, schema: [String: Any]) -> Any? {
        var candidates = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let fence = text.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            candidates.append(String(text[fence]).replacingOccurrences(of: #"^```(?:json)?\s*|```$"#, with: "", options: .regularExpression))
        }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            candidates.append(String(text[open...close]))
        }
        let required = schema["required"] as? [String] ?? []
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  required.allSatisfy({ object[$0] != nil }) else { continue }
            return object
        }
        return nil
    }

    // MARK: - Models

    private static func modelsKey(_ tool: CLITool) -> String { "settings.cli.\(tool.rawValue)Models" }

    /// Models the signed-in account offers, from the last check (Settings or menus).
    static func cachedModels(_ tool: CLITool) -> [AIModelOption] {
        guard let data = UserDefaults.standard.data(forKey: modelsKey(tool)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"], !id.isEmpty else { return nil }
            return AIModelOption(id: id, name: row["name"] ?? id, detail: row["detail"] ?? "")
        }
    }

    /// Start the assistant, open a session (no prompt, no tokens) and remember its model list.
    static func refreshModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] {
        let connection = ACPConnection(tool: tool, executable: toolPath, arguments: profile(tool, effort: nil).arguments,
                                       workDir: FileManager.default.temporaryDirectory)
        try await connection.start()
        defer { connection.close() }
        _ = try await connection.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ])
        let session = try await connection.request("session/new", [
            "cwd": FileManager.default.temporaryDirectory.path, "mcpServers": [],
        ])
        let available = ((session["models"] as? [String: Any])?["availableModels"] as? [[String: Any]]) ?? []
        let models = available.compactMap { row -> AIModelOption? in
            guard let id = row["modelId"] as? String, !id.isEmpty else { return nil }
            // Copilot says how many premium requests a call costs ("0x" = included).
            let usage = ((row["_meta"] as? [String: Any])?["copilotUsage"] as? String).map { " · \($0) premium requests" } ?? ""
            return AIModelOption(id: id, name: row["name"] as? String ?? id, detail: (row["description"] as? String ?? id) + usage)
        }
        if !models.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: models.map { ["id": $0.id, "name": $0.name, "detail": $0.detail] }) {
            UserDefaults.standard.set(data, forKey: modelsKey(tool))
        }
        return models
    }

    // MARK: - Streaming state

    /// The answer as it streams, and progress for the caller.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var answer = ""
        private var tokens = (input: 0, output: 0)
        private let noticePrefix: String?
        private let onDelta: (@Sendable (String) -> Void)?
        private let onActivity: (@Sendable (CLICompletion.Activity) -> Void)?

        init(onDelta: (@Sendable (String) -> Void)?, onActivity: (@Sendable (CLICompletion.Activity) -> Void)?,
             noticePrefix: String?) {
            self.onDelta = onDelta
            self.onActivity = onActivity
            self.noticePrefix = noticePrefix
        }

        var text: String { lock.lock(); defer { lock.unlock() }; return answer }
        var inputTokens: Int { lock.lock(); defer { lock.unlock() }; return tokens.input }
        var outputTokens: Int { lock.lock(); defer { lock.unlock() }; return tokens.output }

        func reset() { lock.lock(); answer = ""; lock.unlock() }

        func addUsage(input: Int, output: Int) {
            lock.lock(); tokens.input += input; tokens.output += output; lock.unlock()
        }

        func receive(_ update: [String: Any]) {
            switch update["sessionUpdate"] as? String {
            case "agent_message_chunk":
                guard let chunk = (update["content"] as? [String: Any])?["text"] as? String, !chunk.isEmpty else { return }
                if let noticePrefix, chunk.hasPrefix(noticePrefix) { return }
                lock.lock(); answer += chunk; let count = answer.count; lock.unlock()
                onDelta?(chunk)
                onActivity?(.writing(count))
                onActivity?(.answerDelta(chunk))
            case "agent_thought_chunk":
                onActivity?(.thinking)
            case "tool_call":
                let input = update["rawInput"] as? [String: Any] ?? [:]
                switch update["kind"] as? String {
                case "read":
                    // Copilot reports its grep/glob searches as reads too.
                    if let pattern = input["pattern"] as? String {
                        onActivity?(.search(pattern))
                        return
                    }
                    let files = ((input["files"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String }
                    onActivity?(.read(files.first ?? (input["path"] as? String ?? "")))
                case "search":
                    let queries = (input["queries"] as? [String]) ?? [input["query"] as? String ?? ""]
                    onActivity?(.search(queries.joined(separator: ", ")))
                case "execute":
                    onActivity?(.run(update["title"] as? String ?? "command"))
                default:
                    break
                }
            default:
                break
            }
        }
    }
}

// MARK: - JSON-RPC connection

/// One `<cli> --acp` process and its JSON-RPC traffic. All state lives on `queue`.
private final class ACPConnection: @unchecked Sendable {
    /// Whether a tool call of `kind` with `input` may run.
    var permit: ((String, [String: Any]) -> Bool)?
    /// `session/update` notifications (the `update` object).
    var onUpdate: (([String: Any]) -> Void)?
    var sessionId: String?

    private let tool: CLITool
    private let process = Process()
    private let queue = DispatchQueue(label: "markview.acp")
    private var stdin: FileHandle?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var lineBuffer = Data()
    private var stderrTail = ""
    private var failure: Error?

    init(tool: CLITool, executable: String, arguments: [String], workDir: URL) {
        self.tool = tool
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CLIToolLocator.subprocessPath(toolPath: executable)
        process.environment = env
    }

    func start() async throws {
        signal(SIGPIPE, SIG_IGN)   // a CLI that exits early must not kill the app mid-write
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(3000)) }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                let detail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                let killed = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
                let name = self.tool.displayName
                self.failAll(self.failure ?? CLICompletion.Failure.failed(self.tool, killed && self.tool == .cline
                    ? "macOS stopped Cline (its binary's signature is invalid — a known problem of the npm package). "
                      + "Fix: codesign --force --sign - \"$(dirname $(readlink -f $(which cline)))/.cline\""
                    : "\(name) exited (\(process.terminationStatus))" + (detail.isEmpty ? "" : ": \(detail.suffix(400))")))
            }
        }
        do {
            try process.run()
        } catch {
            throw CLICompletion.Failure.failed(tool, error.localizedDescription)
        }
        stdin = input.fileHandleForWriting
    }

    /// Send a request and wait for its result.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let failure = self.failure { continuation.resume(throwing: failure); return }
                let id = self.nextId
                self.nextId += 1
                self.pending[id] = continuation
                self.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        }
    }

    /// Stop the turn (if any) and the process; waiting requests end as cancelled.
    func cancel() {
        queue.async {
            if let sessionId = self.sessionId {
                self.write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]])
            }
            self.failAll(CancellationError())
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.terminate() }
    }

    /// End everything with `error` (a timeout).
    func fail(_ error: CLICompletion.Failure) {
        queue.async {
            self.failAll(error)
            self.terminate()
        }
    }

    func close() {
        queue.async { self.terminate() }
    }

    // MARK: - Private (on queue)

    private func terminate() {
        try? stdin?.close()
        stdin = nil
        if process.isRunning { process.terminate() }
    }

    private func failAll(_ error: Error) {
        if failure == nil { failure = error }
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: failure ?? error) }
    }

    private func write(_ message: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        // A response to one of our requests.
        if method == nil, let id = (message["id"] as? NSNumber)?.intValue, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: CLICompletion.Failure.failed(tool, Self.readable(error, tool: tool)))
            } else {
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let method else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        // A request from Cline: only permissions are answered; the rest is declined.
        if let id = message["id"] {
            if method == "session/request_permission" {
                let call = params["toolCall"] as? [String: Any] ?? [:]
                let kind = call["kind"] as? String ?? "other"
                let allowed = permit?(kind, call["rawInput"] as? [String: Any] ?? [:]) ?? false
                let options = params["options"] as? [[String: Any]] ?? []
                let wanted = allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
                if let option = options.first(where: { wanted.contains($0["kind"] as? String ?? "") }),
                   let optionId = option["optionId"] {
                    write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "selected", "optionId": optionId]]])
                } else {
                    write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                }
            } else {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "\(method) is not supported by MarkView"]])
            }
            return
        }
        if method == "session/update", let update = params["update"] as? [String: Any] {
            onUpdate?(update)
        }
    }

    /// A JSON-RPC error as a sentence; sign-in problems say how to sign in.
    private static func readable(_ error: [String: Any], tool: CLITool) -> String {
        var message = error["message"] as? String ?? "error \(error["code"] ?? "")"
        if let data = error["data"] as? [String: Any], let detail = data["message"] as? String ?? data["details"] as? String {
            message += ": " + detail
        } else if let detail = error["data"] as? String {
            message += ": " + detail
        }
        if message.localizedCaseInsensitiveContains("unauthorized") || message.localizedCaseInsensitiveContains("auth") {
            message += " — sign in with `\(tool.binaryName) \(tool.loginCommand)` (DDE Settings → \(tool.displayName) → Login in Terminal)."
        }
        return message
    }
}
