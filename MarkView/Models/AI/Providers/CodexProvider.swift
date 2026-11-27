import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Codex (`codex`).
struct CodexProvider: AssistantProvider {
    let id = "codex"
    let displayName = "Codex"
    let binaryName = "codex"
    let authStatusArgs = ["login", "status"]
    let loginCommand = "login"
    let fullAccessArgs = ["--dangerously-bypass-approvals-and-sandbox"]
    /// Codex starts subagents only after a direct request; they are on by default and inherit the parent session's sandbox and
    /// approvals (docs and Codex 0.172, 2026-11-26).
    let parallelWork: AssistantParallelWork? = AssistantParallelWork(
        mechanism: "Codex subagents spawned from this session (they keep its permissions)")
    let continueArgs = ["resume", "--last"]
    let modelFlag = "-m"
    let defaultXRayModel = "gpt-5.6-luna"
    let terminalIcon = "chevron.left.forwardslash.chevron.right"
    let canSearchWeb = true
    let fixesBugsAsGoal = true
    var launchCapabilities: AgentLaunchCapabilities {
        AgentLaunchCapabilities(
            backgroundWebSearch: true,
            enforcesWebOptOutAtCLI: true,
            backgroundImages: true,
            backgroundStructuredOutput: true,
            backgroundReportsCostUSD: false,
            interactiveDelegation: true,
            remoteWork: true
        )
    }
    var usage: (any AssistantUsageSupport)? { CodexUsage() }
    var activity: (any AssistantActivitySupport)? { CodexActivity() }
    var completion: (any AssistantCompletionSupport)? { self }
    var remote: (any AssistantRemoteSupport)? { self }

    /// `/goal [<objective>|clear|edit|pause|resume]` (Codex 0.172). An objective over 4000 characters is written by the TUI to
    /// `goal-objective.md` and the goal becomes a reference to that file, so a long bug basket still fits.
    func goalPrompt(_ objective: String, closing: String) -> String { "/goal \(objective)" }

    func loginState(stdout: String, stderr: String) -> Bool? {
        // `codex login status` prints e.g. "Logged in using ChatGPT".
        let output = stdout + stderr
        if output.localizedCaseInsensitiveContains("not logged in") { return false }
        if output.localizedCaseInsensitiveContains("logged in") { return true }
        return nil
    }

    func modelOptions() -> [AIModelOption] {
        let configured = configuredModel()
        let fallback = AIModelOption(
            id: "", name: configured.map { "Default (\($0))" } ?? "Default",
            detail: configured.map { "\($0) (from ~/.codex/config.toml)" } ?? "Codex's configured model"
        )
        return [fallback] + catalog()
    }

    /// Top-level `model = "..."` from Codex's config, used to label "Default".
    func configuredModel() -> String? {
        let url = Self.home.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }  // past the top-level table
            guard line.hasPrefix("model"),
                  let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Models Codex itself lists in its picker, from the cache the CLI maintains (~350 KB of JSON).
    private func catalog() -> [AIModelOption] {
        let url = Self.home.appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return AIModelOption(
                    id: slug,
                    name: model["display_name"] as? String ?? slug,
                    detail: model["description"] as? String ?? ""
                )
            }
    }

    // MARK: Session log

    /// `~/.codex/sessions/YYYY/MM/DD/*.jsonl`: `turn_context` lines carry the model and cwd.
    func answeredModel(in directory: URL, since: Date) -> String? {
        let root = Self.home.appendingPathComponent("sessions", isDirectory: true)
        let path = directory.standardizedFileURL.path
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // The day folders of `since` and today (a session may cross midnight).
        let days = Set([since, Date()].map { calendar.dateComponents([.year, .month, .day], from: $0) })
        let folders = days.compactMap { day -> URL? in
            guard let y = day.year, let m = day.month, let d = day.day else { return nil }
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d), isDirectory: true)
        }
        for file in AssistantSessionLog.recentFiles(in: folders, since: since) {
            let lines = AssistantSessionLog.lines(of: file)
            // A one-shot run in the same folder (X-Ray, a feature's assistant) is not the terminal's reply.
            if let meta = lines.first, Self.isOneShotRollout(meta) { continue }
            for object in lines where object["type"] as? String == "turn_context" {
                guard let date = AssistantSessionLog.timestamp(object), date >= since,
                      let payload = object["payload"] as? [String: Any],
                      (payload["cwd"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == path,
                      let model = payload["model"] as? String, !model.isEmpty else { continue }
                return model
            }
        }
        return nil
    }

    // MARK: MarkView's MCP servers

    func mcpLaunchArguments(for servers: [AgentMCPServer], quote: (String) -> String) -> [String]? {
        let toml = { (text: String) in "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return servers.flatMap { server in
            ["-c", quote("mcp_servers.\(server.tomlName).command=" + toml(server.command)),
             "-c", quote("mcp_servers.\(server.tomlName).args=[" + server.args.map(toml).joined(separator: ",") + "]")]
        }
    }

    /// Servers in `~/.codex/config.toml`, added with Codex's own command (under a TOML-safe name).
    var mcp: AssistantMCPRegistration? {
        .commands(.init(
            remove: { ["mcp", "remove", $0.tomlName] },
            add: { server, executable in ["mcp", "add", server.tomlName, "--", executable, server.flag] },
            list: nil, location: "~/.codex/config.toml", reportsStdoutOnFailure: false))
    }

    var mcpConfig: (any AssistantMCPConfigAdapter)? { CodexMCPConfigAdapter() }

    let skillPath: String? = ".codex/skills/markview/SKILL.md"
}

/// Codex stores MCP servers in `~/.codex/config.toml` under `[mcp_servers.<name>]` and honors `enabled = false`.
private struct CodexMCPConfigAdapter: AssistantMCPConfigAdapter {
    private static func configURL(home: URL) -> URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    func canonicalName(for rawName: String) -> String {
        rawName == AgentMCPServer.markviewBrowserTomlName ? AgentMCPServer.markviewBrowserName : rawName
    }

    private func configKeys(for canonicalName: String) -> Set<String> {
        if canonicalName == AgentMCPServer.markviewBrowserName {
            return [AgentMCPServer.markviewBrowserTomlName, AgentMCPServer.markviewBrowserName]
        }
        return [canonicalName]
    }

    func discoverFromFiles(home: URL, stash: MCPDisabledServerStash) -> [DiscoveredAgentMCPServer] {
        let file = Self.configURL(home: home)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let parsed = CodexTOMLMCPHelper.parseServers(in: text)
        var byCanonical: [String: DiscoveredAgentMCPServer] = [:]
        for item in parsed {
            let name = canonicalName(for: item.rawName)
            if let existing = byCanonical[name] {
                byCanonical[name] = DiscoveredAgentMCPServer(
                    name: name,
                    rawName: existing.rawName,
                    isEnabled: existing.isEnabled && item.isEnabled,
                    detail: "~/.codex/config.toml"
                )
            } else {
                byCanonical[name] = DiscoveredAgentMCPServer(
                    name: name,
                    rawName: item.rawName,
                    isEnabled: item.isEnabled,
                    detail: "~/.codex/config.toml"
                )
            }
        }
        return byCanonical.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func discoverFromCLI(executable: String, home: URL) async -> [DiscoveredAgentMCPServer] {
        #if canImport(MarkViewCore)
        let codexHome = home.appendingPathComponent(".codex").path
        let spec = SubprocessSpec(
            executable: executable,
            arguments: ["mcp", "list", "--json"],
            cwd: home,
            environment: ["CODEX_HOME": codexHome],
            timeout: 10
        )
        let result = await Subprocess.run(spec)
        guard result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let configured = Set(discoverFromFiles(home: home, stash: MCPDisabledServerStash()).map(\.name))
        return entries.compactMap { entry in
            guard let raw = entry["name"] as? String, !raw.isEmpty else { return nil }
            let name = canonicalName(for: raw)
            let enabled = (entry["enabled"] as? Bool) ?? true
            let inConfig = configured.contains(name)
            return DiscoveredAgentMCPServer(
                name: name,
                rawName: raw,
                isEnabled: enabled,
                isBuiltin: !inConfig,
                detail: inConfig ? "~/.codex/config.toml" : "Codex plugin",
                canToggle: inConfig,
                note: inConfig ? nil : "Managed by a Codex plugin outside ~/.codex/config.toml."
            )
        }
        #else
        return []
        #endif
    }

    func setEnabled(_ enabled: Bool, serverName: String, home: URL, stash: MCPDisabledServerStash) throws {
        let file = Self.configURL(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw MCPConfigError.unreadableFile(path: file.path, reason: error.localizedDescription)
        }
        let result = CodexTOMLMCPHelper.updatingEnabled(enabled, forKeys: configKeys(for: serverName), in: text)
        guard result.changed else { return }
        #if canImport(MarkViewCore)
        do {
            try AtomicFile.write(result.updated, to: file)
        } catch {
            throw MCPConfigError.writeFailed(path: file.path, reason: error.localizedDescription)
        }
        #endif
    }
}

// MARK: - One-shot run

/// `codex exec --json` in its read-only sandbox; a schema answer comes back as the message text.
extension CodexProvider: AssistantCompletionSupport {
    /// What a run that may read the folder is told: Codex starts subagents only when it is asked to (codex 0.172).
    static let oneShotSubagents = "Where answering needs independent parts of the folder read (different files, modules or "
        + "questions), start subagents to read them at the same time and answer from what they return; read the files yourself "
        + "when a few are enough."

    func launch(_ request: CompletionLaunchRequest) throws -> CompletionLaunch {
        // A run that may read the folder keeps its session, so the subagents it starts for independent parts can load it (an
        // `--ephemeral` run keeps none, and every spawn fails with "no rollout"); `CLICompletion` deletes the session when the run
        // ends. A run without files, or one asked to start none, keeps no session and its subagent tools are off.
        let keepsSession = request.readableFolder != nil && request.subagents
        // Explicitly disable web search when `allowWeb` is false so user config.toml cannot bypass repository opt-out.
        var arguments = request.allowWeb ? ["--search"] : ["-c", "web_search=\"disabled\""]
        if !keepsSession { arguments += ["-c", "agents.enabled=false"] }
        arguments.append("exec")
        arguments += request.images.flatMap { ["-i", $0.path] }
        arguments += ["--sandbox", "read-only", "--skip-git-repo-check"]
        if !keepsSession { arguments.append("--ephemeral") }
        arguments += ["--json", "--color", "never", "-C", request.workDir.path]
        arguments += modelArgs(request.model)
        if let effort = request.effort { arguments += ["-c", "model_reasoning_effort=\(effort)"] }
        var schemaFile: URL?
        if let schema = request.jsonSchema {
            let url = request.scratchDirectory().appendingPathComponent("schema-\(UUID().uuidString).json")
            try AtomicFile.write(CompletionJSON.string(Self.strictSchema(schema)), to: url)
            schemaFile = url
            arguments += ["--output-schema", url.path]
        }
        arguments.append("-")  // read the prompt from stdin
        // Codex has no system-prompt flag; the instructions lead the prompt.
        let instructions = [request.systemPrompt, keepsSession ? Self.oneShotSubagents : nil].compactMap { $0 }
        var input = request.prompt
        if !instructions.isEmpty {
            input = "<instructions>\n\(instructions.joined(separator: "\n\n"))\n</instructions>\n\n\(request.prompt)"
        }
        return CompletionLaunch(arguments: arguments, input: input, schemaFile: schemaFile, keepsSession: keepsSession)
    }

    func makeParser() -> any CompletionStreamParser { CodexStreamParser() }

    /// `codex delete --force` removes the session with the sessions of its subagents (files and state rows; it asks for a
    /// confirmation without `--force`).
    func deleteSessionArguments(_ id: String) -> [String]? { ["delete", "--force", id] }

    /// A rollout `rollout-<time>-<id>.jsonl` under `~/.codex/sessions` or `archived_sessions`.
    func storesSession(_ id: String) -> Bool {
        let suffix = "-\(id).jsonl"
        return ["sessions", "archived_sessions"].contains { folder in
            let root = Self.home.appendingPathComponent(folder, isDirectory: true)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
            return files.contains { ($0 as? URL)?.lastPathComponent.hasSuffix(suffix) == true }
        }
    }

    /// A rollout written by `codex exec` (a one-shot run or one of its subagents), not by the interactive CLI of a terminal: its
    /// first line, `session_meta`, names the `codex_exec` originator.
    static func isOneShotRollout(_ sessionMeta: [String: Any]) -> Bool {
        (sessionMeta["payload"] as? [String: Any])?["originator"] as? String == "codex_exec"
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

/// Codex's `--json` events: items (commands, reasoning, web searches, the agent message) and turn results.
private final class CodexStreamParser: CompletionStreamParser {
    /// Last Codex "error" event; fatal only if no answer arrives.
    private(set) var warning: String?

    func handle(_ json: [String: Any], output: inout CompletionOutput, sink: CompletionSink) {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "thread.started":
            if let id = json["thread_id"] as? String { sink.onSession?(id) }
        case "item.started":
            guard let item = json["item"] as? [String: Any] else { return }
            if item["type"] as? String == "command_execution", let command = item["command"] as? String {
                sink.onActivity?(.run(command))
            } else if item["type"] as? String == "reasoning" {
                sink.onActivity?(.thinking)
            } else if item["type"] as? String == "web_search", let query = item["query"] as? String, !query.isEmpty {
                sink.onActivity?(.webSearch(query))
            }
        case "item.completed":
            if let item = json["item"] as? [String: Any], item["type"] as? String == "web_search",
               let query = item["query"] as? String, !query.isEmpty {
                sink.onActivity?(.webSearch(query))   // listeners de-duplicate the started/completed pair
                return
            }
            guard let item = json["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else { return }
            output.text = text
            sink.onDelta?(text)
        case "turn.completed":
            if let usage = json["usage"] as? [String: Any] {
                output.inputTokens = usage["input_tokens"] as? Int ?? 0
                output.outputTokens = usage["output_tokens"] as? Int ?? 0
            }
        case "turn.failed":
            let error = json["error"] as? [String: Any]
            output.errorMessage = Self.readableError(error?["message"] as? String ?? "the turn failed")
        case "error":
            // Also used for non-fatal warnings (e.g. missing model metadata); only
            // `turn.failed` ends the run. Kept to explain an empty answer.
            warning = Self.readableError(json["message"] as? String ?? "unknown error")
        default:
            break
        }
    }

    /// Codex passes API errors on as raw JSON (`{"type":"error","status":400,"error":{"message":…}}`).
    /// Keep the message, and point model problems at the place to choose another model.
    private static func readableError(_ raw: String) -> String {
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
}

// MARK: - Remote Work

/// Codex hosted for a work Mac: its native sandbox stays read-only, every feature that could touch the home Mac is off, and
/// the work-computer MCP server is required and pre-approved.
extension CodexProvider: AssistantRemoteSupport {
    func arguments(_ plan: AssistantRemotePlan) throws -> [String] {
        var args = ["--no-daemon", "--dangerously-bypass-hook-trust", "--cd", plan.directory.path,
                    "--sandbox", "read-only", "--ask-for-approval", "never"]
        func override(_ key: String, _ value: String) { args += ["-c", key + "=" + value] }
        for name in ["shell_tool", "view_image", "multi_agent", "apps", "plugins", "computer_use", "browser_use", "image_generation"] {
            override("features." + name, "false")
        }
        override("features.hooks", "true")
        override("features.non_prefixed_mcp_tool_names", "false")
        override("features.skip_host_skill_discovery", "true")
        let serverKey = "mcp_servers." + plan.serverName
        override(serverKey + ".command", Self.remoteToml(plan.app))
        override(serverKey + ".args", "[" + ["--remote-workspace-mcp", "--socket", plan.socket].map(Self.remoteToml).joined(separator: ",") + "]")
        override(serverKey + ".tool_timeout_sec", "120")
        override(serverKey + ".required", "true")
        override(serverKey + ".default_tools_approval_mode", Self.remoteToml("approve"))
        override("developer_instructions", Self.remoteToml(plan.instructions))
        override("hooks.PreToolUse", "[{matcher=\".*\",hooks=[{type=\"command\",command=" + Self.remoteToml(plan.guardCommand) + ",timeout=5}]}]")
        if plan.resume { args += ["resume", plan.resumeThreadID ?? "--last"] }
        return args
    }

    /// Codex's saved thread keeps the developer messages of its first start: refresh them before resuming it.
    var refreshesThreadInstructions: Bool { true }

    private static func remoteToml(_ text: String) -> String {
        // JSON string escaping is also valid for TOML basic strings.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(text), encoding: .utf8)!
    }
}

// MARK: - Usage

/// Codex's quota and usage: the ChatGPT usage endpoint with the CLI's own stored sign-in, and the CLI's local logs
/// (`~/.codex/sessions/**/*.jsonl`) as the fallback.
struct CodexUsage: AssistantUsageSupport {
    let shortName = "Codex"
    let dataDirectoryName = ".codex"
    var localLogs: (any UsageLogFormat)? { Log() }

    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return .signedOut }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        if let account = tokens["account_id"] as? String { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        return await UsageHTTP.fetch(request, token: token, transport: transport) { Self.parse($0, now: Date()) }
    }

    /// `GET https://chatgpt.com/backend-api/wham/usage`: `rate_limit.primary_window` and
    /// `secondary_window`.
    static func parse(_ data: Data, now: Date) -> [QuotaWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else { return nil }
        let windows: [QuotaWindow] = ["primary_window", "secondary_window"].compactMap { key in
            guard let window = rateLimit[key] as? [String: Any],
                  let percent = OfficialUsageParser.number(window["used_percent"]) else { return nil }
            let seconds = OfficialUsageParser.number(window["limit_window_seconds"])
            var resetsAt = OfficialUsageParser.number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            if resetsAt == nil, let after = OfficialUsageParser.number(window["reset_after_seconds"]) {
                resetsAt = now.addingTimeInterval(after)
            }
            let (label, title) = OfficialUsageParser.windowNames(seconds: seconds)
            return QuotaWindow(id: key, label: label, title: title, percentUsed: percent,
                               resetsAt: resetsAt, duration: seconds, source: .official)
        }
        return windows.isEmpty ? nil : windows
    }

    /// Codex's `~/.codex/sessions/**/*.jsonl` and `archived_sessions`.
    struct Log: UsageLogFormat {
        func roots(in dataDirectory: URL) -> [URL] {
            [dataDirectory.appendingPathComponent("sessions"), dataDirectory.appendingPathComponent("archived_sessions")]
        }
        let marker = Data(#""token_count""#.utf8)

        func read(line: Data, dates: ISO8601DateFormatter, lastTotal: inout Int) -> UsageLineReading {
            guard let (date, total) = Self.parse(line, dates: dates) else { return .unrecognised }
            guard total >= 0 else { return .counted(key: nil, event: nil) }
            // A total below the last one means a new counter (e.g. a resumed session).
            let delta = total >= lastTotal ? total - lastTotal : total
            lastTotal = total
            return .counted(key: nil, event: delta > 0 ? UsageEvent(date: date, tokens: delta, costUSD: nil) : nil)
        }

        /// A Codex `token_count` event: the session's cumulative total so far.
        static func parse(_ line: Data, dates: ISO8601DateFormatter) -> (date: Date, total: Int)? {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let date = UsageLogLine.date(object["timestamp"], dates) else { return nil }
            // `info` is null before the first model call of a session.
            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let tokens = (total["total_tokens"] as? NSNumber)?.intValue else { return (date, -1) }
            return (date, tokens)
        }
    }
}

// MARK: - Activity

/// What Codex is doing: the newest rollout of the last two days whose first line names this folder.
struct CodexActivity: AssistantActivitySupport {
    func read(_ request: ActivityRequest) -> ActivityRead? {
        guard let url = AgentActivityLog.newestCodexLog(for: request.directory) else { return nil }
        return AgentActivityLog.readLog(at: url, cached: request.cached, parse: { AgentActivityParser.codex(lines: $0) })
    }
}
