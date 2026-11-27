import Foundation

/// Claude Code (`claude`).
struct ClaudeProvider: AssistantProvider {
    let id = "claude"
    let displayName = "Claude Code"
    let compactName = "Claude"
    let binaryName = "claude"
    let authStatusArgs = ["auth", "status"]
    let loginCommand = "auth login"
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    /// Subagents start with the Agent tool (it was called Task before 2.1.63); a dynamic workflow starts only when the prompt asks for
    /// one in words, never in `-p`, and without approval under bypass permissions (docs and Claude Code 2.1.332, 2026-11-26).
    let parallelWork: AssistantParallelWork? = AssistantParallelWork(
        mechanism: "subagents started with the Agent tool",
        itemsMechanism: "a workflow (use a workflow for them; when workflows are not available, subagents started with the Agent tool)")
    let continueArgs = ["--continue"]
    let defaultXRayModel = "sonnet"
    let terminalIcon = "sparkle"
    /// Claude Code updates itself before every start.
    let updateArgs = ["update"]
    let canSearchWeb = true
    let fixesBugsAsGoal = true
    var launchCapabilities: AgentLaunchCapabilities {
        AgentLaunchCapabilities(
            backgroundWebSearch: true,
            enforcesWebOptOutAtCLI: true,
            backgroundImages: true,
            backgroundStructuredOutput: true,
            backgroundReportsCostUSD: true,
            interactiveDelegation: true,
            remoteWork: true
        )
    }
    var liveModelSwitch: (any AssistantLiveModelSwitch)? { ClaudeSessionModel.liveSwitch }
    var usage: (any AssistantUsageSupport)? { ClaudeUsage() }
    var activity: (any AssistantActivitySupport)? { ClaudeActivity() }
    var completion: (any AssistantCompletionSupport)? { self }
    var remote: (any AssistantRemoteSupport)? { self }

    func goalPrompt(_ objective: String, closing: String) -> String { "/goal \(objective)" }

    func loginState(stdout: String, stderr: String) -> Bool? {
        // `claude auth status` emits JSON with a "loggedIn" boolean.
        if let data = stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let flag = json["loggedIn"] as? Bool {
            return flag
        }
        return (stdout + stderr).localizedCaseInsensitiveContains("logged in") ? true : nil
    }

    /// Claude `--add-dir`. Codex reads the whole disk in its read-only sandbox; Cline and Copilot have no such option.
    func additionalFolderArgs(_ folders: [URL]) -> [String] {
        folders.flatMap { ["--add-dir", $0.path] }
    }

    func modelOptions() -> [AIModelOption] {
        // Aliases resolve to the newest model of each family, so the list does not go stale when Claude Code ships a new version.
        [
            AIModelOption(id: "", name: "Default", detail: "Claude Code's configured model"),
            AIModelOption(id: "fable", name: "Fable", detail: "Latest Fable — most capable"),
            AIModelOption(id: "opus", name: "Opus", detail: "Latest Opus"),
            AIModelOption(id: "sonnet", name: "Sonnet", detail: "Latest Sonnet — balanced"),
            AIModelOption(id: "haiku", name: "Haiku", detail: "Latest Haiku — fastest"),
        ]
    }

    /// `~/.claude/settings.json` "model".
    func configuredModel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
        return model
    }

    // MARK: Session log

    /// Claude Code has a session log for `directory`: `claude --continue` has something to resume there.
    func hasSession(in directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.sessionFolder(for: directory).path)) ?? []
        return files.contains { $0.hasSuffix(".jsonl") }
    }

    /// `~/.claude/projects/<cwd, non-alphanumerics as "-">/*.jsonl`: assistant lines carry `message.model`.
    func answeredModel(in directory: URL, since: Date) -> String? {
        for file in AssistantSessionLog.recentFiles(in: [Self.sessionFolder(for: directory)], since: since) {
            for object in AssistantSessionLog.lines(of: file) where object["type"] as? String == "assistant" {
                guard let date = AssistantSessionLog.timestamp(object), date >= since,
                      let model = (object["message"] as? [String: Any])?["model"] as? String,
                      !model.isEmpty, !model.hasPrefix("<") else { continue }  // "<synthetic>" replies
                return model
            }
        }
        return nil
    }

    private static func sessionFolder(for directory: URL) -> URL {
        let name = String(directory.standardizedFileURL.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            .appendingPathComponent(name, isDirectory: true)
    }

    // MARK: MarkView's MCP servers

    func mcpLaunchArguments(for servers: [AgentMCPServer], quote: (String) -> String) -> [String]? {
        let config: [String: Any] = ["mcpServers": Dictionary(uniqueKeysWithValues: servers.map {
            ($0.name, ["command": $0.command, "args": $0.args] as [String: Any]) })]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["--mcp-config", quote(json)]
    }

    /// A user-scope MCP server, added with Claude Code's own command.
    var mcp: AssistantMCPRegistration? {
        .commands(.init(
            remove: { ["mcp", "remove", "--scope", "user", $0.name] },
            add: { server, executable in ["mcp", "add", "--scope", "user", server.name, "--", executable, server.flag] },
            list: nil, location: "user scope", reportsStdoutOnFailure: false))
    }

    var mcpConfig: (any AssistantMCPConfigAdapter)? { ClaudeMCPConfigAdapter() }

    let skillPath: String? = ".claude/skills/markview/SKILL.md"
}

/// Claude Code stores user-scope MCP servers in `~/.claude.json` under `mcpServers` and has no global
/// `disabled` flag (it connects to every entry in `mcpServers`). Disabling removes the server from
/// `~/.claude.json` and preserves its exact JSON definition in `MCPDisabledServerStash` so re-enabling
/// restores it verbatim without modifying unrelated settings.
private struct ClaudeMCPConfigAdapter: AssistantMCPConfigAdapter {
    private static let agentID = "claude"

    private static func configURL(home: URL) -> URL {
        home.appendingPathComponent(".claude.json")
    }

    func discoverFromFiles(home: URL, stash: MCPDisabledServerStash) -> [DiscoveredAgentMCPServer] {
        let file = Self.configURL(home: home)
        let activeNames: Set<String>
        if let root = try? JSONMCPConfigHelper.readRoot(from: file),
           let servers = root["mcpServers"] as? [String: Any] {
            activeNames = Set(servers.compactMap { ($0.value is [String: Any]) ? $0.key : nil })
        } else {
            activeNames = []
        }
        let stashed = stash.stashedServers(for: Self.agentID)
        var discovered: [DiscoveredAgentMCPServer] = activeNames.sorted().map { name in
            DiscoveredAgentMCPServer(name: name, isEnabled: true, detail: "~/.claude.json")
        }
        for name in stashed.keys.sorted() where !activeNames.contains(name) {
            discovered.append(DiscoveredAgentMCPServer(name: name, isEnabled: false, detail: "~/.claude.json (disabled)"))
        }
        return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setEnabled(_ enabled: Bool, serverName: String, home: URL, stash: MCPDisabledServerStash) throws {
        let file = Self.configURL(home: home)
        if !enabled {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            var root = try JSONMCPConfigHelper.readRoot(from: file)
            guard var servers = root["mcpServers"] as? [String: Any],
                  let entry = servers[serverName] as? [String: Any] else { return }
            // Save the original entry first so a write failure never loses the user's configuration.
            try stash.stash(serverName: serverName, definition: entry, for: Self.agentID)
            servers.removeValue(forKey: serverName)
            root["mcpServers"] = servers
            try JSONMCPConfigHelper.writeRoot(root, to: file)
        } else {
            guard let restored = stash.entry(serverName: serverName, for: Self.agentID) else { return }
            var root = try JSONMCPConfigHelper.readRoot(from: file)
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            if servers[serverName] == nil {
                servers[serverName] = restored
                root["mcpServers"] = servers
                try JSONMCPConfigHelper.writeRoot(root, to: file)
            }
            try stash.remove(serverName: serverName, for: Self.agentID)
        }
    }
}

// MARK: - One-shot run

/// `claude -p` with stream-json output: no tools unless the request reads files (read-only ones) or searches the web.
extension ClaudeProvider: AssistantCompletionSupport {
    /// The read-only tools of a run that may read files. `Agent` lets Claude hand independent reads to subagents running side
    /// by side; a subagent gets only the tools of the run, so it cannot write either.
    static let readingTools = ["Read", "Grep", "Glob", "Agent"]

    func launch(_ request: CompletionLaunchRequest) throws -> CompletionLaunch {
        var arguments = ["-p", "--safe-mode", "--no-session-persistence",
                         "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--tools", ((request.readableFolder == nil ? [] : Self.readingTools)
                                        + (request.allowWeb ? ["WebSearch", "WebFetch"] : [])).joined(separator: ",")]
        // Headless runs cannot ask for permission: web tools must be pre-approved, or the
        // CLI refuses every search (and fetches outside its built-in allowlist).
        if request.allowWeb { arguments += ["--allowedTools", "WebSearch,WebFetch"] }
        // The project's linked folders (Task 59) and any further folders are readable too.
        if request.readableFolder != nil {
            arguments += additionalFolderArgs((request.linkedFolders() + request.extraReadableFolders)
                .filter { FileManager.default.fileExists(atPath: $0.path) })
        }
        arguments += modelArgs(request.model)
        if let effort = request.effort { arguments += ["--effort", effort] }
        if let system = request.systemPrompt {
            arguments += ["--system-prompt", system]
        }
        if let schema = request.jsonSchema {
            arguments += ["--json-schema", try CompletionJSON.string(schema)]
        }
        return CompletionLaunch(arguments: arguments, input: request.prompt, schemaFile: nil)
    }

    func makeParser() -> any CompletionStreamParser { ClaudeStreamParser() }
}

/// Claude's `stream-json` events: partial messages (text, thinking, tool input), tool use, and one final `result`.
private final class ClaudeStreamParser: CompletionStreamParser {
    /// Tool of the content block being streamed, so tool input is not counted as answer.
    private var blockTool: String?
    private var answerChars = 0
    private var thinkingChars = 0
    private var thinkingTicked = 0
    private var streamedText = ""

    func handle(_ json: [String: Any], output: inout CompletionOutput, sink: CompletionSink) {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_start" {
                let block = event["content_block"] as? [String: Any]
                blockTool = block?["type"] as? String == "tool_use" ? block?["name"] as? String : nil
                if block?["type"] as? String == "thinking" { sink.onActivity?(.thinking) }
                return
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return }
            if delta["type"] as? String == "thinking_delta", let text = delta["thinking"] as? String {
                // A long reasoning phase would look like a hang: report it every few thousand characters.
                thinkingChars += text.count
                if thinkingChars - thinkingTicked >= 1500 {
                    thinkingTicked = thinkingChars
                    sink.onActivity?(.thinking)
                }
            }
            if delta["type"] as? String == "input_json_delta", let part = delta["partial_json"] as? String,
               !(ClaudeProvider.readingTools + ["WebSearch", "WebFetch"]).contains(blockTool ?? "") {
                // Structured output arrives as the input of a final tool call; a subagent's task is not part of the answer.
                answerChars += part.count
                sink.onActivity?(.writing(answerChars))
                sink.onActivity?(.answerDelta(part))
            }
            guard delta["type"] as? String == "text_delta", let text = delta["text"] as? String else { return }
            streamedText += text
            answerChars += text.count
            sink.onActivity?(.writing(answerChars))
            sink.onActivity?(.answerDelta(text))
            sink.onDelta?(text)
        case "assistant":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "Read": if let path = input["file_path"] as? String { sink.onActivity?(.read(path)) }
                case "Grep", "Glob": sink.onActivity?(.search(input["pattern"] as? String ?? ""))
                case "WebSearch": if let query = input["query"] as? String { sink.onActivity?(.webSearch(query)) }
                case "WebFetch": if let url = input["url"] as? String { sink.onActivity?(.webFetch(url)) }
                default: break
                }
            }
        case "result":
            output.text = json["result"] as? String ?? streamedText
            output.structured = json["structured_output"]
            for denial in json["permission_denials"] as? [[String: Any]] ?? [] {
                let input = denial["tool_input"] as? [String: Any] ?? [:]
                output.refused.append((denial["tool_name"] as? String ?? "tool",
                                       input["query"] as? String ?? input["url"] as? String ?? input["file_path"] as? String ?? ""))
            }
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
}

// MARK: - Remote Work

/// Claude Code hosted for a work Mac: only the work computer's MCP server, a hook that denies native home tools.
extension ClaudeProvider: AssistantRemoteSupport {
    func arguments(_ plan: AssistantRemotePlan) throws -> [String] {
        let hooks: [String: Any] = ["PreToolUse": [["matcher": ".*", "hooks": [
            ["type": "command", "command": plan.guardCommand, "timeout": 5] as [String: Any]]] as [String: Any]]]
        let settings = try plan.writeJSON(["hooks": hooks], "claude-settings.json")
        var args = ["--tools", "", "--strict-mcp-config", "--mcp-config", plan.mcpConfig.path,
                    "--settings", settings.path, "--setting-sources", "", "--append-system-prompt", plan.instructions,
                    "--allowedTools", plan.toolPrefix + "*", "--dangerously-skip-permissions"]
        if plan.resume { args.insert("--continue", at: 0) }
        return args
    }
}

// MARK: - Usage

/// Claude Code's quota and usage: the official OAuth usage endpoint with the CLI's own stored sign-in, and the CLI's
/// local logs (`~/.claude/projects/**/*.jsonl`) as the fallback.
struct ClaudeUsage: AssistantUsageSupport {
    let shortName = "Claude"
    let dataDirectoryName = ".claude"
    var localLogs: (any UsageLogFormat)? { Log() }

    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult {
        let credential: String
        switch await readCredential(transport) {
        case .found(let token): credential = token
        case .missing: return .signedOut
        case .denied: return .keychainDenied
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return await UsageHTTP.fetch(request, token: credential, transport: transport, parse: Self.parse)
    }

    private enum Credential {
        case found(String)
        case missing
        case denied
    }

    private func readCredential(_ transport: any UsageTransport) async -> Credential {
        // A credentials file (older installs), otherwise the Keychain item Claude Code writes
        // with /usr/bin/security; reading it with the same tool needs no access prompt.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) { return Self.credential(data) }
        let result = await transport.run("/usr/bin/security",
                                         ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 15)
        switch result.exitCode {
        case 0: return Self.credential(Data(result.stdout.utf8))
        case 44: return .missing  // errSecItemNotFound
        default: return .denied
        }
    }

    /// `claudeAiOauth.accessToken`; an expired token is not sent (the refresh token is never used).
    private static func credential(_ data: Data) -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return .missing }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) <= Date() {
            return .missing
        }
        return .found(token)
    }

    /// `GET https://api.anthropic.com/api/oauth/usage`. Newer responses list `limits`
    /// (session / weekly_all / weekly_scoped); older ones only `five_hour`, `seven_day`, ….
    static func parse(_ data: Data) -> [QuotaWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            let windows = limits.enumerated().compactMap { index, limit in claudeLimit(limit, index: index) }
            if !windows.isEmpty { return windows }
        }
        let legacy: [(key: String, label: String, title: String, duration: TimeInterval, model: String?)] = [
            ("five_hour", "5h", "5-hour session", OfficialUsageParser.fiveHours, nil),
            ("seven_day", "week", "Weekly (all models)", OfficialUsageParser.week, nil),
            ("seven_day_opus", "Opus wk", "Weekly (Opus)", OfficialUsageParser.week, "Opus"),
            ("seven_day_sonnet", "Sonnet wk", "Weekly (Sonnet)", OfficialUsageParser.week, "Sonnet"),
        ]
        let windows: [QuotaWindow] = legacy.compactMap { entry in
            guard let value = root[entry.key] as? [String: Any],
                  let percent = OfficialUsageParser.number(value["utilization"]) else { return nil }
            return QuotaWindow(id: entry.key, label: entry.label, title: entry.title, percentUsed: percent,
                               resetsAt: OfficialUsageParser.isoDate(value["resets_at"]), duration: entry.duration, source: .official,
                               modelScope: entry.model)
        }
        return windows.isEmpty ? nil : windows
    }

    private static func claudeLimit(_ limit: [String: Any], index: Int) -> QuotaWindow? {
        guard let kind = limit["kind"] as? String, let percent = OfficialUsageParser.number(limit["percent"]) else { return nil }
        let resetsAt = OfficialUsageParser.isoDate(limit["resets_at"])
        let scope = limit["scope"] as? [String: Any]
        let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case "session":
            return QuotaWindow(id: "session", label: "5h", title: "5-hour session", percentUsed: percent,
                               resetsAt: resetsAt, duration: OfficialUsageParser.fiveHours, source: .official)
        case "weekly_all":
            return QuotaWindow(id: "weekly_all", label: "week", title: "Weekly (all models)", percentUsed: percent,
                               resetsAt: resetsAt, duration: OfficialUsageParser.week, source: .official)
        case "weekly_scoped":
            let name = model ?? "scoped"
            return QuotaWindow(id: "weekly_scoped_\(name)_\(index)", label: "\(name) wk", title: "Weekly (\(name))",
                               percentUsed: percent, resetsAt: resetsAt, duration: OfficialUsageParser.week, source: .official, modelScope: name)
        default:
            // Unknown kinds are shown as they come, with the group ("weekly", …) as label.
            let group = limit["group"] as? String ?? kind
            let duration: TimeInterval? = group == "weekly" ? OfficialUsageParser.week : group == "session" ? OfficialUsageParser.fiveHours : nil
            return QuotaWindow(id: "\(kind)_\(index)", label: group, title: kind.replacingOccurrences(of: "_", with: " "),
                               percentUsed: percent, resetsAt: resetsAt, duration: duration, source: .official)
        }
    }

    /// Claude Code's `~/.claude/projects/**/*.jsonl`.
    struct Log: UsageLogFormat {
        func roots(in dataDirectory: URL) -> [URL] { [dataDirectory.appendingPathComponent("projects")] }
        let marker = Data(#""usage""#.utf8)
        private static let assistantMarker = Data(#""assistant""#.utf8)

        func read(line: Data, dates: ISO8601DateFormatter, lastTotal: inout Int) -> UsageLineReading {
            // Only assistant lines count as candidates for the format check.
            guard line.range(of: Self.assistantMarker) != nil else { return .notUsage }
            guard let (key, event) = Self.parse(line, dates: dates) else { return .unrecognised }
            return .counted(key: key, event: event)
        }

        /// A Claude Code `assistant` line. The CLI writes one line per content block with the same
        /// `message.id` and `requestId`, so `key` is used to count each call once. Cost only when
        /// the line carries `costUSD` (older CLI versions); current ones record none per call.
        static func parse(_ line: Data, dates: ISO8601DateFormatter) -> (key: String, event: UsageEvent)? {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let date = UsageLogLine.date(object["timestamp"], dates) else { return nil }
            let fields = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            let tokens = fields.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            let id = message["id"] as? String ?? object["uuid"] as? String ?? ""
            let request = object["requestId"] as? String ?? ""
            let cost = (object["costUSD"] as? NSNumber)?.doubleValue
            return ("\(id):\(request)", UsageEvent(date: date, tokens: tokens, costUSD: cost))
        }
    }
}

// MARK: - Activity

/// What Claude Code is doing: the log of the CLI process of this terminal (`~/.claude/sessions/<pid>.json` names it, so tabs
/// of one folder do not mix up), else the newest log of the folder.
struct ClaudeActivity: AssistantActivitySupport {
    func read(_ request: ActivityRequest) -> ActivityRead? {
        let own = AgentActivityLog.claudeLog(shell: request.shell)
        guard let url = own ?? AgentActivityLog.newestClaudeLog(for: request.directory) else { return nil }
        let reader = ClaudeSessionModel.liveSwitch
        return AgentActivityLog.readLog(at: url, cached: request.cached, parse: { AgentActivityParser.claude(lines: $0) },
                                        // The model comes only from the log that belongs to this terminal's own process.
                                        model: own == nil ? nil : { reader.reading(lines: $0, since: request.since)?.model })
    }
}
