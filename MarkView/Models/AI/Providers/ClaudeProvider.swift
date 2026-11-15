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
    let continueArgs = ["--continue"]
    let defaultXRayModel = "sonnet"
    let terminalIcon = "sparkle"
    /// Claude Code updates itself before every start.
    let updateArgs = ["update"]
    let canSearchWeb = true
    let fixesBugsAsGoal = true
    var liveModelSwitch: (any AssistantLiveModelSwitch)? { ClaudeSessionModel.liveSwitch }
    var usage: (any AssistantUsageSupport)? { ClaudeUsage() }
    var activity: (any AssistantActivitySupport)? { ClaudeActivity() }

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

    let skillPath: String? = ".claude/skills/markview/SKILL.md"
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
