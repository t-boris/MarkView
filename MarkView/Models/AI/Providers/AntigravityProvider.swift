import Foundation

/// Google Antigravity CLI (`agy`), the successor of Gemini CLI. Terminals use its interactive mode, one-shot
/// requests its print mode with stream-json (`CLICompletion`).
struct AntigravityProvider: AssistantProvider {
    let id = "antigravity"
    let displayName = "Antigravity"
    let binaryName = "agy"
    let authStatusArgs: [String] = []
    let loginCommand = ""
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]
    let terminalIcon = "wand.and.stars"
    var usage: (any AssistantUsageSupport)? { AntigravityUsage() }
    var activity: (any AssistantActivitySupport)? { AntigravityActivity() }
    var completion: (any AssistantCompletionSupport)? { self }

    func modelOptions() -> [AIModelOption] {
        // A few of `agy models`; any other id can be typed as a custom model name.
        [AIModelOption(id: "", name: "Default", detail: "Antigravity's configured model"),
         AIModelOption(id: "gemini-4-argon-medium", name: "Gemini 4 Argon (Medium)", detail: ""),
         AIModelOption(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash (Medium)", detail: ""),
         AIModelOption(id: "claude-opus-5-5-medium", name: "Claude Opus 5.5 (Medium)", detail: ""),
         AIModelOption(id: "claude-sonnet-5-5-medium", name: "Claude Sonnet 5.5 (Medium)", detail: "")]
    }

    /// Antigravity keeps its servers in its own configuration, added with `agy mcp add`; a start only adds what `agy mcp
    /// list` does not show with this copy of MarkView.
    var mcp: AssistantMCPRegistration? {
        .commands(.init(
            remove: { ["mcp", "remove", $0.name] },
            add: { server, executable in ["mcp", "add", server.name, "--", executable, server.flag] },
            list: ["mcp", "list"], location: "agy mcp", reportsStdoutOnFailure: true))
    }
}

// MARK: - One-shot run

/// Print mode with NDJSON on stdin. The default permission mode cannot ask anyone, so writes are denied; `--sandbox`
/// restricts its terminal. A schema answer arrives as `structured_output`.
extension AntigravityProvider: AssistantCompletionSupport {
    func launch(_ request: CompletionLaunchRequest) throws -> CompletionLaunch {
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json", "--sandbox", "-p="]
        arguments += modelArgs(request.model)
        if let effort = request.effort { arguments += ["--effort", effort] }
        if let schema = request.jsonSchema { arguments += ["--json-schema", try CompletionJSON.string(schema)] }
        if request.readableFolder != nil {
            arguments += request.extraReadableFolders.flatMap { ["--add-dir", $0.path] }
        }
        // No system-prompt flag: the instructions lead the prompt.
        let text = request.systemPrompt.map { "<instructions>\n\($0)\n</instructions>\n\n\(request.prompt)" } ?? request.prompt
        let input = try CompletionJSON.string(["event": "user", "message": ["content": text]]) + "\n"
        return CompletionLaunch(arguments: arguments, input: input, schemaFile: nil)
    }

    func makeParser() -> any CompletionStreamParser { AntigravityStreamParser() }
}

/// `agy --output-format stream-json`: `step_update` events (answer text, tool steps) and one final `result`.
private final class AntigravityStreamParser: CompletionStreamParser {
    private var answerChars = 0
    private var streamedText = ""

    func handle(_ json: [String: Any], output: inout CompletionOutput, sink: CompletionSink) {
        switch json["event"] as? String {
        case "step_update":
            guard let step = json["step_update"] as? [String: Any] else { return }
            switch step["step_type"] as? String {
            case "agent_response":
                guard let text = step["text_delta"] as? String, !text.isEmpty else { return }
                streamedText += text
                answerChars += text.count
                sink.onActivity?(.writing(answerChars))
                sink.onDelta?(text)
            case "tool":
                guard step["state"] as? String == "ACTIVE", let info = step["tool_info"] as? [String: Any] else { return }
                let parameters = info["parameters"] as? [String: Any] ?? [:]
                let value = { (keys: [String]) -> String in
                    keys.lazy.compactMap { parameters[$0] as? String }.first
                        ?? parameters.values.compactMap { $0 as? String }.first ?? ""
                }
                switch step["tool_name"] as? String {
                case "view_file", "list_dir": sink.onActivity?(.read(value(["AbsolutePath", "DirectoryPath", "Path"])))
                case "grep_search", "find_by_name": sink.onActivity?(.search(value(["Query", "Pattern"])))
                case "run_command": sink.onActivity?(.run(value(["CommandLine"])))
                case "search_web": sink.onActivity?(.webSearch(value(["query", "Query"])))
                case "read_url_content": sink.onActivity?(.webFetch(value(["Url", "URL"])))
                default: break
                }
            default:
                break
            }
        case "result":
            guard let result = json["result"] as? [String: Any] else { return }
            output.text = result["response"] as? String ?? streamedText
            output.structured = result["structured_output"]
            if let usage = result["usage"] as? [String: Any] {
                output.inputTokens = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_tokens"] as? Int ?? 0)
                output.outputTokens = usage["output_tokens"] as? Int ?? 0
            }
            for denial in result["denied_actions"] as? [[String: Any]] ?? [] {
                output.refused.append((denial["display_name"] as? String ?? "tool", denial["action"] as? String ?? ""))
            }
            if result["status"] as? String != "SUCCESS" {
                output.errorMessage = result["error"] as? String ?? "the run ended with status \(result["status"] as? String ?? "unknown")"
            }
        default:
            break
        }
    }
}

// MARK: - Usage

/// Antigravity's quota (DEC-020): MarkView reads no token and the CLI keeps no readable logs; its own `/usage` command
/// signs in itself and asks Google. `--log-file /dev/null` keeps every call from leaving a log file behind, and a
/// signed-out CLI waits for a pasted code, so the call is cut at 25 s. The sign-in prompt (it carries a login link) is
/// classified and dropped: it is never stored or logged.
struct AntigravityUsage: AssistantUsageSupport {
    let shortName = "Antigravity"
    let dataDirectoryName = ".gemini/antigravity-cli"
    /// For Antigravity every try starts a sign-in prompt that only ends at our timeout, so it waits longer (DEC-020).
    let signedOutInterval: TimeInterval? = 30 * 60

    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult {
        guard let path = transport.resolve(AntigravityProvider().tool) else {
            return .failed(reason: "the agy command was not found", retryAfter: nil)
        }
        let run = await transport.run(path, ["--print-timeout", "20s", "--log-file", "/dev/null",
                                             "--output-format", "json", "-p", "/usage"], timeout: 25)
        switch Self.interpret(exitCode: run.exitCode, stdout: run.stdout, stderr: run.stderr) {
        case .windows(let windows): return .success(windows)
        case .signedOut: return .signedOut
        case .failed(let reason): return .failed(reason: reason, retryAfter: nil)
        }
    }

    /// `agy --output-format json -p "/usage"` (DEC-020): `command.data.groups[].buckets[]` with `window`
    /// ("5h" / "weekly"), `remaining_fraction` and `reset_time`. Models share a bucket inside a group, so the
    /// group name is the window's scope. A bucket nobody has used reports a reset time of now + window that moves
    /// on every call, so it gets none (it would show a countdown that never runs down).
    static func parse(_ data: Data) -> [QuotaWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = root["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else { return nil }
        var windows: [QuotaWindow] = []
        for (groupIndex, group) in groups.enumerated() {
            let groupName = (group["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Group \(groupIndex + 1)"
            var short = groupName
            if short.lowercased().hasSuffix(" models") { short = String(short.dropLast(" models".count)) }
            for (bucketIndex, bucket) in (group["buckets"] as? [[String: Any]] ?? []).enumerated() {
                guard let remaining = OfficialUsageParser.number(bucket["remaining_fraction"]), remaining.isFinite else { continue }
                let percent = min(100, max(0, (1 - remaining) * 100))
                let kind = bucket["window"] as? String
                let (label, title, duration): (String, String, TimeInterval?)
                switch kind {
                case "5h": (label, title, duration) = ("5h", "5-hour", OfficialUsageParser.fiveHours)
                case "weekly": (label, title, duration) = ("wk", "Weekly", OfficialUsageParser.week)
                default: (label, title, duration) = (kind ?? "limit", kind ?? "Limit", nil)
                }
                let untouched = remaining >= 1 - 1e-9
                let id = (bucket["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(groupIndex)_\(bucketIndex)_\(kind ?? "limit")"
                windows.append(QuotaWindow(id: id, label: "\(short) \(label)", title: "\(groupName) · \(title)",
                                           percentUsed: percent,
                                           resetsAt: untouched ? nil : OfficialUsageParser.isoDate(bucket["reset_time"]),
                                           duration: duration, source: .official, modelScope: groupName))
            }
        }
        return windows.isEmpty ? nil : windows
    }

    /// What reading Antigravity's usage made of one `agy` run (DEC-020): the windows, "signed out" (the CLI
    /// printed its sign-in prompt instead of an answer), or why there is nothing.
    enum Run: Equatable, Sendable {
        case windows([QuotaWindow])
        case signedOut
        case failed(String)
    }

    /// `exitCode` -1 is "could not start" and -2 "stopped at our timeout" (`CLIToolLocator.run`). A signed-out
    /// CLI waits for a pasted code, so its prompt can arrive together with the timeout.
    static func interpret(exitCode: Int32, stdout: String, stderr: String) -> Run {
        if let windows = parse(Data(stdout.utf8)) { return .windows(windows) }
        let text = (stdout + "\n" + stderr).lowercased()
        if text.contains("authentication required") || text.contains("authentication failed") { return .signedOut }
        switch exitCode {
        case -1: return .failed("could not start the agy command")
        case -2: return .failed("agy did not answer in time")
        default: return .failed("response not recognised")
        }
    }
}

// MARK: - Activity

/// What Antigravity is doing: the newest top-level conversation of the folder in its conversation summaries.
struct AntigravityActivity: AssistantActivitySupport {
    func read(_ request: ActivityRequest) -> ActivityRead? {
        guard let conversation = AgentActivityLog.antigravityConversation(directory: request.directory) else { return nil }
        return ActivityRead(source: request.directory, size: 0, date: Date(),
                            activity: AgentActivityParser.antigravity(title: conversation.title, preview: conversation.preview,
                                                                     status: conversation.status, busy: request.printing))
    }
}
