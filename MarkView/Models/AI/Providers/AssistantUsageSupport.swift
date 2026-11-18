import Foundation

// What an assistant reports about its usage and quota (the Terminal tab's indicators): which local logs it keeps, how its
// official usage is read, and how the parsers turn the vendor's answers into quota windows. The generic rules (windows,
// levels, limits, display state) are in AgentUsage.swift; the tracker that polls is AgentUsageTracker.

/// What one try at reading an assistant's official usage came to.
enum UsageFetchResult {
    case success([QuotaWindow])
    /// No credentials, an expired token, or 401/403.
    case signedOut
    case keychainDenied
    case failed(reason: String, retryAfter: TimeInterval?)
}

/// The output of a command a usage reader ran.
struct UsageCommandResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// What a usage reader may do outside its own process; the app's implementation is `OfficialUsageClient`. Credentials go
/// only to the assistant's vendor: no cookies, no cache, no redirects.
protocol UsageTransport: Sendable {
    func http(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Exit code -1 is "could not start" and -2 "stopped at our timeout".
    func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval) async -> UsageCommandResult
    /// The assistant's executable, or nil when it is not installed.
    func resolve(_ tool: CLITool) -> String?
}

extension UsageTransport {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> UsageCommandResult {
        await run(executable, arguments, stdin: nil, timeout: timeout)
    }
}

protocol AssistantUsageSupport: Sendable {
    /// Name in the compact indicator ("Claude").
    var shortName: String { get }
    /// The assistant's data directory in the home folder; its presence counts as "detected".
    var dataDirectoryName: String { get }
    /// The assistant's local usage logs (the fallback of DEC-007); nil when it keeps none that can be read.
    var localLogs: (any UsageLogFormat)? { get }
    /// Seconds before the next automatic try while signed out, when it differs from the normal poll interval.
    var signedOutInterval: TimeInterval? { get }
    /// Reads the assistant's official usage with its own stored credentials or its own command (DEC-005, DEC-011).
    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult
}

extension AssistantUsageSupport {
    var localLogs: (any UsageLogFormat)? { nil }
    var signedOutInterval: TimeInterval? { nil }
}

/// What a log line is for the usage count.
enum UsageLineReading {
    /// Nothing that could be usage; not counted for the format check.
    case notUsage
    /// It looked like usage and did not parse (the format may have changed).
    case unrecognised
    /// Parsed. `key` counts one model call once when the log repeats it (`nil`: no deduplication); `event` is nil when the
    /// line adds no usage.
    case counted(key: String?, event: UsageEvent?)
}

/// One assistant's local usage log format: where the logs are and how a line becomes a usage event.
protocol UsageLogFormat: Sendable {
    /// The directories that hold the logs, inside the assistant's data directory.
    func roots(in dataDirectory: URL) -> [URL]
    /// Lines without these bytes carry no usage; they are skipped without decoding.
    var marker: Data { get }
    /// `lastTotal` is the cumulative total of the file at the previous line, for logs that record running totals.
    func read(line: Data, dates: ISO8601DateFormatter, lastTotal: inout Int) -> UsageLineReading
}

/// The HTTP exchange of an official usage request, shared by the assistants that ask a vendor's API.
enum UsageHTTP {
    /// Sends `request` with the bearer `token` and hands a 200 body to `parse`.
    static func fetch(_ request: URLRequest, token: String, transport: any UsageTransport,
                      parse: (Data) -> [QuotaWindow]?) async -> UsageFetchResult {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MarkView", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.http(request)
        } catch {
            return .failed(reason: (error as? URLError)?.localizedDescription ?? "network error", retryAfter: nil)
        }
        switch http.statusCode {
        case 200:
            guard let windows = parse(data) else { return .failed(reason: "response not recognised", retryAfter: nil) }
            return .success(windows)
        case 401, 403:
            return .signedOut
        case 429:
            return .failed(reason: "rate limited", retryAfter: retryAfter(http))
        default:
            return .failed(reason: "HTTP \(http.statusCode)", retryAfter: retryAfter(http))
        }
    }

    /// Seconds or an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
