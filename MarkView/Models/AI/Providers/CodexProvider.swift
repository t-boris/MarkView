import Foundation

/// Codex (`codex`).
struct CodexProvider: AssistantProvider {
    let id = "codex"
    let displayName = "Codex"
    let binaryName = "codex"
    let authStatusArgs = ["login", "status"]
    let loginCommand = "login"
    let fullAccessArgs = ["--dangerously-bypass-approvals-and-sandbox"]
    let continueArgs = ["resume", "--last"]
    let modelFlag = "-m"
    let defaultXRayModel = "gpt-5.6-luna"
    let terminalIcon = "chevron.left.forwardslash.chevron.right"
    let canSearchWeb = true
    var usage: (any AssistantUsageSupport)? { CodexUsage() }
    var activity: (any AssistantActivitySupport)? { CodexActivity() }

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
            for object in AssistantSessionLog.lines(of: file) where object["type"] as? String == "turn_context" {
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

    let skillPath: String? = ".codex/skills/markview/SKILL.md"
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
