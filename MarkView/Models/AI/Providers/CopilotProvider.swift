import Foundation

/// GitHub Copilot CLI 1.x (`copilot`), driven over the Agent Client Protocol (`ACPAssistant`).
struct CopilotProvider: AssistantProvider, AssistantACPSupport {
    let id = "copilot"
    let displayName = "Copilot"
    let binaryName = "copilot"
    let authStatusArgs: [String] = []
    let loginCommand = "login"
    let fullAccessArgs = ["--allow-all"]
    let continueArgs = ["--continue"]
    let terminalIcon = "airplane"
    var usage: (any AssistantUsageSupport)? { CopilotUsage() }
    var activity: (any AssistantActivitySupport)? { CopilotActivity() }
    /// An organisation's policy may allow only listed MCP servers; Copilot then says so at every start (BUG-025).
    let reportsMCPPolicyBlock = true

    func goalPrompt(_ objective: String, closing: String) -> String { "/autopilot \(objective)" }

    var acp: (any AssistantACPSupport)? { self }

    func modelOptions() -> [AIModelOption] {
        [AIModelOption(id: "", name: "Default", detail: "Copilot's configured model")] + ACPModelCache.cached(id)
    }

    func launchProfile(effort: String?) -> ACPLaunchProfile {
        // Only these tools exist for the model: no shell, no edits, no web, no subagents.
        var arguments = ["--acp", "--no-auto-update", "--no-ask-user", "--disable-builtin-mcps",
                         "--no-custom-instructions"]
        if let effort { arguments += ["--reasoning-effort", effort] }
        arguments += ["--available-tools", "view", "grep", "glob"]
        return ACPLaunchProfile(arguments: arguments, readOnlyMode: nil, noticePrefix: "Info: Disabled tools:")
    }

    /// Copilot lists models per account, so a list means signed in.
    var probe: ACPProbeProfile {
        ACPProbeProfile(minimumMajorVersion: 1, installCommand: "npm i -g @github/copilot@latest",
                        silentExitMessage: nil, modelListImpliesSignedIn: true)
    }

    func mcpLaunchArguments(for servers: [AgentMCPServer], quote: (String) -> String) -> [String]? {
        let config: [String: Any] = ["mcpServers": Dictionary(uniqueKeysWithValues: servers.map {
            ($0.name, ["type": "local", "command": $0.command, "args": $0.args, "tools": ["*"]] as [String: Any]) })]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["--additional-mcp-config", quote(json)]
    }

    /// An entry in `~/.copilot/mcp-config.json`, written by Connect Agents (a terminal gets its servers per session).
    var mcp: AssistantMCPRegistration? {
        .jsonFile(.init(
            file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/mcp-config.json"),
            entry: { executable, server in ["type": "local", "command": executable, "args": [server.flag], "tools": ["*"]] },
            isCurrent: { _, _ in true },
            checkedAtStart: false))
    }

    let skillPath: String? = ".copilot/skills/markview/SKILL.md"
}

// MARK: - Usage

/// Copilot's quota and usage (`DEC-021`): what Copilot CLI's `/usage` shows under "Active account/provider usage"
/// (Plan budget in AI credits or premium requests, plus 5-hour Session and Weekly rate limits when present).
/// MarkView reads no GitHub token; it asks the CLI's own headless JSON-RPC server (`account.getQuota` for live quota
/// snapshots and `account.getCurrentAuth` for credential-free account metadata and the monthly reset date).
/// `--log-level none --log-dir /dev/null` keeps each poll from writing a process log in `~/.copilot/logs`.
struct CopilotUsage: AssistantUsageSupport {
    let shortName = "Copilot"
    let dataDirectoryName = ".copilot"

    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult {
        guard let path = transport.resolve(CopilotProvider().tool) else {
            return .failed(reason: "the copilot command was not found", retryAfter: nil)
        }
        let run = await transport.run(
            path,
            ["--headless", "--no-auto-update", "--log-level", "none", "--log-dir", "/dev/null", "--stdio"],
            stdin: Self.requestPayload,
            timeout: 25)
        switch Self.interpret(exitCode: run.exitCode, stdout: run.stdout, stderr: run.stderr) {
        case .windows(let windows): return .success(windows)
        case .signedOut: return .signedOut
        case .failed(let reason): return .failed(reason: reason, retryAfter: nil)
        }
    }

    /// One-shot JSON-RPC pipeline for `copilot --headless --stdio`: `connect`, `account.getQuota` (live fetch from
    /// GitHub's `/copilot_internal/user`), and `account.getCurrentAuth` (credential-free `copilotUser` with the
    /// monthly `quota_reset_date_utc`).
    static let requestPayload: Data = {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"connect","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account.getQuota","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"account.getCurrentAuth","params":{}}"#,
        ]
        let framed = requests.map { body in "Content-Length: \(body.utf8.count)\r\n\r\n\(body)" }.joined()
        return Data(framed.utf8)
    }()

    /// Parses the JSON-RPC responses of `account.getQuota` and `account.getCurrentAuth` (either `Content-Length` framed
    /// stdout from `copilot --stdio` or a plain JSON object/array) into quota windows: the monthly Plan window
    /// (`premium_interactions`, or finite `chat` on Copilot Free) and any finite 5-hour Session or Weekly rate-limit
    /// windows (`5hour-session-ratelimits` / `session`, `weekly-session-ratelimits` / `weekly`).
    static func parse(_ data: Data) -> [QuotaWindow]? {
        let objects = messages(in: data)
        guard !objects.isEmpty else { return nil }

        var quotaSnapshots: [String: [String: Any]] = [:]
        var rawSnapshots: [String: [String: Any]] = [:]
        var copilotUser: [String: Any]?

        for object in objects {
            let payload = (object["result"] as? [String: Any]) ?? object
            if let snapshots = payload["quotaSnapshots"] as? [String: [String: Any]] {
                for (key, value) in snapshots { quotaSnapshots[key] = value }
            }
            let user = ((payload["authInfo"] as? [String: Any])?["copilotUser"] as? [String: Any])
                ?? (payload["copilotUser"] as? [String: Any])
                ?? (payload["quota_snapshots"] != nil ? payload : nil)
            if let user {
                copilotUser = user
                if let snapshots = user["quota_snapshots"] as? [String: [String: Any]] {
                    for (key, value) in snapshots { rawSnapshots[key] = value }
                }
            }
        }

        var windows: [QuotaWindow] = []
        let premiumWindow = planWindow(
            key: "premium_interactions", id: "plan", label: "plan", baseTitle: "Plan",
            quotaSnapshots: quotaSnapshots, rawSnapshots: rawSnapshots, copilotUser: copilotUser)
        if let premiumWindow {
            windows.append(premiumWindow)
            if let chatWindow = planWindow(
                key: "chat", id: "chat", label: "chat", baseTitle: "Chat",
                quotaSnapshots: quotaSnapshots, rawSnapshots: rawSnapshots, copilotUser: copilotUser) {
                windows.append(chatWindow)
            }
        } else if let freePlanWindow = planWindow(
            key: "chat", id: "plan", label: "plan", baseTitle: "Plan",
            quotaSnapshots: quotaSnapshots, rawSnapshots: rawSnapshots, copilotUser: copilotUser) {
            windows.append(freePlanWindow)
        }

        if let session = rateLimitWindow(
            keys: ["5hour-session-ratelimits", "session"], id: "session", label: "5h", title: "5-hour session",
            duration: OfficialUsageParser.fiveHours, quotaSnapshots: quotaSnapshots, rawSnapshots: rawSnapshots) {
            windows.append(session)
        }
        if let weekly = rateLimitWindow(
            keys: ["weekly-session-ratelimits", "weekly"], id: "weekly", label: "week", title: "Weekly",
            duration: OfficialUsageParser.week, quotaSnapshots: quotaSnapshots, rawSnapshots: rawSnapshots) {
            windows.append(weekly)
        }

        return windows.isEmpty ? nil : windows
    }

    private static func planWindow(
        key: String, id: String, label: String, baseTitle: String,
        quotaSnapshots: [String: [String: Any]], rawSnapshots: [String: [String: Any]],
        copilotUser: [String: Any]?
    ) -> QuotaWindow? {
        let quota = quotaSnapshots[key]
        let raw = rawSnapshots[key]
        guard quota != nil || raw != nil else { return nil }
        let unlimited = (quota?["isUnlimitedEntitlement"] as? Bool) ?? (raw?["unlimited"] as? Bool) ?? false
        let entitlement = OfficialUsageParser.number(quota?["entitlementRequests"])
            ?? OfficialUsageParser.number(raw?["entitlement"])
        if unlimited || entitlement == -1 { return nil }

        let rawRemaining = OfficialUsageParser.number(raw?["quota_remaining"])
            ?? OfficialUsageParser.number(raw?["remaining"])
        let usedFromQuota = OfficialUsageParser.number(quota?["usedRequests"])
        let used = usedFromQuota ?? ((entitlement != nil && rawRemaining != nil) ? max(0, entitlement! - rawRemaining!) : nil)

        let percentUsed: Double
        if let remaining = OfficialUsageParser.number(quota?["remainingPercentage"])
            ?? OfficialUsageParser.number(raw?["percent_remaining"]),
           remaining.isFinite {
            percentUsed = min(100, max(0, 100 - remaining))
        } else if let entitlement, entitlement > 0, let used, used.isFinite {
            percentUsed = min(100, max(0, used / entitlement * 100))
        } else {
            return nil
        }

        let title: String
        if let entitlement, entitlement > 0 {
            let consumed = used ?? (entitlement * percentUsed / 100)
            let tokenBased = (quota?["tokenBasedBilling"] as? Bool)
                ?? (raw?["token_based_billing"] as? Bool)
                ?? (copilotUser?["token_based_billing"] as? Bool)
            let unit: String
            if key == "chat" {
                unit = tokenBased == true ? "AIC" : "chat requests"
            } else {
                unit = tokenBased == false ? "premium requests" : "AIC"
            }
            title = "\(baseTitle) (\(formatCount(consumed)) / \(formatCount(entitlement)) \(unit))"
        } else {
            title = baseTitle
        }

        let resetsAt = bucketResetDate(quota: quota, raw: raw, includeSnapshotResetDate: false)
            ?? userPlanResetDate(copilotUser, preferLimitedReset: key == "chat")
        let duration = resetsAt.flatMap(monthDuration(endingAt:))
        return QuotaWindow(id: id, label: label, title: title, percentUsed: percentUsed,
                           resetsAt: resetsAt, duration: duration, source: .official)
    }

    private static func rateLimitWindow(
        keys: [String], id: String, label: String, title: String, duration: TimeInterval,
        quotaSnapshots: [String: [String: Any]], rawSnapshots: [String: [String: Any]]
    ) -> QuotaWindow? {
        let key = keys.first { quotaSnapshots[$0] != nil || rawSnapshots[$0] != nil }
        guard let key else { return nil }
        let quota = quotaSnapshots[key]
        let raw = rawSnapshots[key]
        let unlimited = (quota?["isUnlimitedEntitlement"] as? Bool) ?? (raw?["unlimited"] as? Bool) ?? false
        let entitlement = OfficialUsageParser.number(quota?["entitlementRequests"])
            ?? OfficialUsageParser.number(raw?["entitlement"])
        if unlimited || entitlement == -1 { return nil }

        guard let remaining = OfficialUsageParser.number(quota?["remainingPercentage"])
            ?? OfficialUsageParser.number(raw?["percent_remaining"]),
              remaining.isFinite else { return nil }
        let percentUsed = min(100, max(0, 100 - remaining))
        let untouched = remaining >= 100 - 1e-7
        let explicitEpoch = (OfficialUsageParser.number(raw?["quota_reset_at"]) ?? 0) > 0
            || (OfficialUsageParser.number(quota?["resetDateEpochMs"]) ?? 0) > 0
        let resetsAt: Date?
        if untouched && !explicitEpoch {
            resetsAt = nil
        } else {
            resetsAt = bucketResetDate(quota: quota, raw: raw, includeSnapshotResetDate: true)
        }
        return QuotaWindow(id: id, label: label, title: title, percentUsed: percentUsed,
                           resetsAt: resetsAt, duration: duration, source: .official)
    }

    private static func bucketResetDate(
        quota: [String: Any]?, raw: [String: Any]?, includeSnapshotResetDate: Bool
    ) -> Date? {
        if let seconds = OfficialUsageParser.number(raw?["quota_reset_at"]), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let epochMs = OfficialUsageParser.number(quota?["resetDateEpochMs"]), epochMs > 0 {
            return Date(timeIntervalSince1970: epochMs / 1000)
        }
        if includeSnapshotResetDate,
           let resetString = quota?["resetDate"] as? String,
           resetString != (raw?["timestamp_utc"] as? String),
           let date = parseDate(resetString) {
            return date
        }
        return nil
    }

    private static func userPlanResetDate(_ copilotUser: [String: Any]?, preferLimitedReset: Bool) -> Date? {
        guard let copilotUser else { return nil }
        let keys = preferLimitedReset
            ? ["limited_user_reset_date", "quota_reset_date_utc", "quota_reset_date"]
            : ["quota_reset_date_utc", "quota_reset_date", "limited_user_reset_date"]
        for key in keys {
            if let date = parseDate(copilotUser[key]) { return date }
        }
        return nil
    }

    /// ISO 8601 date-time or a `"YYYY-MM-DD"` UTC date string (`quota_reset_date`).
    private static func parseDate(_ value: Any?) -> Date? {
        if let date = OfficialUsageParser.isoDate(value) { return date }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return OfficialUsageParser.isoDate(string + "T00:00:00Z")
    }

    /// Length of the UTC calendar month ending at `reset` (e.g. Nov 1 00:00 UTC → Dec 1 00:00 UTC = 30 days).
    private static func monthDuration(endingAt reset: Date) -> TimeInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let start = calendar.date(byAdding: .month, value: -1, to: reset), reset > start else { return nil }
        return reset.timeIntervalSince(start)
    }

    private static func formatCount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        let rounded = Int(value.rounded())
        return formatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
    }

    /// Extracts JSON objects from `Content-Length` framed stdio output, a single JSON value, or NDJSON lines.
    private static func messages(in data: Data) -> [[String: Any]] {
        if let single = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return [single] }
        if let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { return array }
        var results: [[String: Any]] = []
        let crlfSeparator = Data("\r\n\r\n".utf8)
        let lfSeparator = Data("\n\n".utf8)
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let slice = data[cursor...]
            let headerEnd: Range<Data.Index>? = {
                switch (slice.range(of: crlfSeparator), slice.range(of: lfSeparator)) {
                case (let a?, let b?): return a.lowerBound <= b.lowerBound ? a : b
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (nil, nil): return nil
                }
            }()
            guard let headerEnd,
                  let header = String(data: data[cursor..<headerEnd.lowerBound], encoding: .utf8),
                  let match = header.range(of: #"(?i)content-length:\s*(\d+)"#, options: .regularExpression),
                  let digits = header[match].split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let length = Int(digits), length >= 0,
                  headerEnd.upperBound + length <= data.endIndex else { break }
            let body = data[headerEnd.upperBound..<(headerEnd.upperBound + length)]
            if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                results.append(object)
            }
            cursor = headerEnd.upperBound + length
        }
        return results
    }

    enum Run: Equatable, Sendable {
        case windows([QuotaWindow])
        case signedOut
        case failed(String)
    }

    /// `exitCode` -1 is "could not start" and -2 "stopped at our timeout" (`CLIToolLocator.run`).
    static func interpret(exitCode: Int32, stdout: String, stderr: String) -> Run {
        let data = Data(stdout.utf8)
        if let windows = parse(data) { return .windows(windows) }
        let objects = messages(in: data)
        let text = (stdout + "\n" + stderr).lowercased()
        if text.contains("not authenticated")
            || text.contains("please authenticate")
            || text.contains("not logged in")
            || text.contains("authentication required")
            || text.contains("authentication failed") {
            return .signedOut
        }
        let sawEmptyAuthResult = objects.contains { object in
            guard let result = object["result"] as? [String: Any] else { return false }
            if result.isEmpty { return true }
            if result.keys.contains("authInfo"), !(result["authInfo"] is [String: Any]) { return true }
            return false
        }
        if sawEmptyAuthResult { return .signedOut }
        switch exitCode {
        case -1: return .failed("could not start the copilot command")
        case -2: return .failed("copilot did not answer in time")
        default: return .failed("response not recognised")
        }
    }
}

// MARK: - Activity

/// What Copilot is doing: the last finished turn of the folder in `~/.copilot/session-store.db`.
struct CopilotActivity: AssistantActivitySupport {
    func read(_ request: ActivityRequest) -> ActivityRead? {
        guard let turn = AgentActivityLog.copilotTurn(directory: request.directory) else { return nil }
        return ActivityRead(source: request.directory, size: 0, date: Date(),
                            activity: AgentActivityParser.copilot(userMessage: turn.user, response: turn.response, busy: request.printing))
    }
}
