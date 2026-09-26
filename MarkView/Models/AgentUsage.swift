import Foundation

// Usage and quota of the AI coding agents (Claude Code, Codex): quota windows, the headline
// window, colour levels, the user's fallback limit and its window, pace, the display state and
// the parsers of the vendors' official usage responses. Foundation only, no app state:
// tools/tests/agent-usage-tests.sh compiles this file on its own and checks the rules.
// Spec: docs/features/ai-agent-usage-quota-tracker-codex-claude-code.

/// The agents whose usage is tracked (DEC-012: a built-in list).
enum UsageAgent: String, CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The agent's data directory in the home folder; its presence counts as "detected".
    var dataDirectoryName: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        }
    }

    /// UserDefaults key: the user hid this agent's indicator (Settings → DDE).
    var hiddenKey: String { "settings.usage.\(rawValue).hidden" }
    /// UserDefaults key: the user's fallback limit, JSON-encoded `FallbackLimit`.
    var limitKey: String { "settings.usage.\(rawValue).limit" }
}

/// Where a value comes from (DEC-002): the vendor's own limit data, or local logs against the
/// user's limit.
enum UsageSource: Sendable {
    case official, estimated
}

enum UsageUnit: String, Codable, CaseIterable, Sendable {
    case tokens, usd

    var title: String { self == .tokens ? "tokens" : "USD" }
}

/// Usage counted from local logs. `costUSD` is nil when the logs record no cost (DEC-007).
struct UsageAmount: Equatable, Sendable {
    var tokens: Int
    var costUSD: Double?

    static let zero = UsageAmount(tokens: 0, costUSD: nil)

    func value(in unit: UsageUnit) -> Double? {
        unit == .tokens ? Double(tokens) : costUSD
    }
}

/// The indicator's colour (DEC-008): fixed thresholds on percent used.
enum UsageLevel: Sendable {
    case normal, warning, critical

    static let warningPercent = 80.0
    static let criticalPercent = 95.0

    init(percent: Double) {
        if percent >= Self.criticalPercent {
            self = .critical
        } else if percent >= Self.warningPercent {
            self = .warning
        } else {
            self = .normal
        }
    }
}

/// Percent used compared with the share of the window already elapsed (DEC-008: popover only).
enum UsagePace: Sendable {
    case under, on, ahead

    /// Points of difference still counted as "on pace".
    static let tolerance = 5.0

    var title: String {
        switch self {
        case .under: return "under pace"
        case .on: return "on pace"
        case .ahead: return "ahead of pace"
        }
    }
}

/// One quota window of an agent (DEC-009: an agent may have several at once).
struct QuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    /// Short label for the compact indicator, e.g. "5h", "week".
    let label: String
    /// Long label for the popover, e.g. "5-hour session".
    let title: String
    let percentUsed: Double
    let resetsAt: Date?
    /// Length of the window, when known; with `resetsAt` it gives the start (pace, local figures).
    let duration: TimeInterval?
    let source: UsageSource
    /// Fallback path only: the user's limit and the usage counted against it, in `unit`.
    var limit: Double? = nil
    var consumed: Double? = nil
    var unit: UsageUnit? = nil
    /// Set when the window counts one model only (e.g. "Weekly (Opus)"); local log figures cover
    /// every model, so they are not shown for it.
    var modelScope: String? = nil

    var start: Date? {
        guard let resetsAt, let duration else { return nil }
        return resetsAt.addingTimeInterval(-duration)
    }

    var level: UsageLevel { UsageLevel(percent: percentUsed) }

    /// Remaining quota as a percentage (DEC-015: the official path's only "remaining").
    var remainingPercent: Double { max(0, 100 - percentUsed) }

    /// Remaining quota in the limit's own unit; only on the fallback path (DEC-015).
    var remainingAmount: Double? {
        guard let limit, let consumed else { return nil }
        return max(0, limit - consumed)
    }

    /// Share of the window already elapsed, 0…1.
    func elapsedFraction(now: Date) -> Double? {
        guard let start, let resetsAt, resetsAt > start else { return nil }
        let fraction = now.timeIntervalSince(start) / resetsAt.timeIntervalSince(start)
        return min(1, max(0, fraction))
    }

    func pace(now: Date) -> UsagePace? {
        guard let elapsed = elapsedFraction(now: now) else { return nil }
        let difference = percentUsed - elapsed * 100
        if difference > UsagePace.tolerance { return .ahead }
        if difference < -UsagePace.tolerance { return .under }
        return .on
    }

    /// The window shown in the compact indicator (DEC-009): the highest percent used; on a tie
    /// the one that resets later (it blocks for longer).
    static func headline(of windows: [QuotaWindow]) -> QuotaWindow? {
        windows.max { a, b in
            if a.percentUsed != b.percentUsed { return a.percentUsed < b.percentUsed }
            return (a.resetsAt ?? .distantPast) < (b.resetsAt ?? .distantPast)
        }
    }
}

// MARK: - Fallback limit (DEC-014)

/// The period of a user-configured window.
enum LimitPeriod: Codable, Hashable, Sendable {
    case hours(Int)
    case days(Int)
    case months(Int)

    static let presets: [LimitPeriod] = [.hours(5), .days(1), .days(7), .months(1)]

    var title: String {
        switch self {
        case .hours(let n): return n == 1 ? "1 hour" : "\(n) hours"
        case .days(let n): return n == 1 ? "1 day" : "\(n) days"
        case .months(let n): return n == 1 ? "1 month" : "\(n) months"
        }
    }

    /// Short label for the compact indicator.
    var label: String {
        switch self {
        case .hours(let n): return "\(n)h"
        case .days(7): return "week"
        case .days(let n): return "\(n)d"
        case .months(1): return "month"
        case .months(let n): return "\(n)mo"
        }
    }

    var isValid: Bool {
        switch self {
        case .hours(let n), .days(let n), .months(let n): return n > 0
        }
    }

    /// Rough length, only to estimate which window contains a date.
    fileprivate var approximateLength: TimeInterval {
        switch self {
        case .hours(let n): return Double(n) * 3600
        case .days(let n): return Double(n) * 86_400
        case .months(let n): return Double(n) * 30.44 * 86_400
        }
    }
}

/// The user's limit for an agent without official data: a value in a unit, and a window given by
/// an anchor plus a period. Window k is [anchor + k·period, anchor + (k+1)·period).
struct FallbackLimit: Codable, Equatable, Sendable {
    var value: Double
    var unit: UsageUnit
    var anchor: Date
    var period: LimitPeriod

    var isValid: Bool { value > 0 && value.isFinite && period.isValid }

    /// Start of window `k`. Days and months follow the calendar (local wall-clock time, DST);
    /// each boundary is computed from the anchor, so month-end clamping does not accumulate
    /// (Jan 31 → Feb 28 → Mar 31).
    func boundary(_ k: Int, calendar: Calendar = .current) -> Date {
        switch period {
        case .hours(let n):
            return anchor.addingTimeInterval(Double(k) * Double(n) * 3600)
        case .days(let n):
            return calendar.date(byAdding: .day, value: k * n, to: anchor) ?? anchor
        case .months(let n):
            return calendar.date(byAdding: .month, value: k * n, to: anchor) ?? anchor
        }
    }

    /// The window containing `now`; also when the anchor lies in the future.
    func window(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        var k = Int((now.timeIntervalSince(anchor) / period.approximateLength).rounded(.down))
        while boundary(k, calendar: calendar) > now { k -= 1 }
        while boundary(k + 1, calendar: calendar) <= now { k += 1 }
        return DateInterval(start: boundary(k, calendar: calendar), end: boundary(k + 1, calendar: calendar))
    }

    /// The estimated window for `consumed` usage inside the current window.
    func quotaWindow(consumed: Double, now: Date, calendar: Calendar = .current) -> QuotaWindow {
        let interval = window(containing: now, calendar: calendar)
        return QuotaWindow(id: "limit", label: period.label, title: "Your limit (\(period.title))",
                           percentUsed: consumed / value * 100, resetsAt: interval.end,
                           duration: interval.duration, source: .estimated,
                           limit: value, consumed: consumed, unit: unit)
    }
}

// MARK: - Display state (DEC-012)

/// Exactly one state per shown agent, in order of precedence.
enum AgentUsageState: Equatable, Sendable {
    /// Official limit data: every window, the headline chosen by `QuotaWindow.headline`.
    case official([QuotaWindow])
    /// No official data; local usage against the user's limit.
    case userLimit(QuotaWindow)
    /// No official data and no limit: today's absolute usage and a "set a limit" hint (DEC-003).
    case noLimit(today: UsageAmount)
    /// Neither official nor local data could be read — never shown as zero.
    case unavailable(reason: String)

    var windows: [QuotaWindow] {
        switch self {
        case .official(let windows): return windows
        case .userLimit(let window): return [window]
        case .noLimit, .unavailable: return []
        }
    }

    var headline: QuotaWindow? { QuotaWindow.headline(of: windows) }

    /// - Parameters:
    ///   - official: the official windows (nil or empty: not available).
    ///   - limitUsage: local usage inside the user's current window; nil when unreadable.
    ///   - today: local usage since midnight; nil when unreadable.
    static func resolve(official: [QuotaWindow]?, limit: FallbackLimit?, limitUsage: UsageAmount?,
                        today: UsageAmount?, localError: String?, now: Date,
                        calendar: Calendar = .current) -> AgentUsageState {
        if let official, !official.isEmpty { return .official(official) }
        if let limit, limit.isValid, let consumed = limitUsage?.value(in: limit.unit) {
            return .userLimit(limit.quotaWindow(consumed: consumed, now: now, calendar: calendar))
        }
        if let today { return .noLimit(today: today) }
        return .unavailable(reason: localError ?? "No usage data found")
    }
}

// MARK: - Official responses (DEC-005)

/// Parses the vendors' usage responses into windows. Nil means the response was not recognised.
enum OfficialUsageParser {
    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86_400

    /// `GET https://api.anthropic.com/api/oauth/usage`. Newer responses list `limits`
    /// (session / weekly_all / weekly_scoped); older ones only `five_hour`, `seven_day`, ….
    static func claude(_ data: Data) -> [QuotaWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            let windows = limits.enumerated().compactMap { index, limit in claudeLimit(limit, index: index) }
            if !windows.isEmpty { return windows }
        }
        let legacy: [(key: String, label: String, title: String, duration: TimeInterval, model: String?)] = [
            ("five_hour", "5h", "5-hour session", fiveHours, nil),
            ("seven_day", "week", "Weekly (all models)", week, nil),
            ("seven_day_opus", "Opus wk", "Weekly (Opus)", week, "Opus"),
            ("seven_day_sonnet", "Sonnet wk", "Weekly (Sonnet)", week, "Sonnet"),
        ]
        let windows: [QuotaWindow] = legacy.compactMap { entry in
            guard let value = root[entry.key] as? [String: Any],
                  let percent = number(value["utilization"]) else { return nil }
            return QuotaWindow(id: entry.key, label: entry.label, title: entry.title, percentUsed: percent,
                               resetsAt: isoDate(value["resets_at"]), duration: entry.duration, source: .official,
                               modelScope: entry.model)
        }
        return windows.isEmpty ? nil : windows
    }

    private static func claudeLimit(_ limit: [String: Any], index: Int) -> QuotaWindow? {
        guard let kind = limit["kind"] as? String, let percent = number(limit["percent"]) else { return nil }
        let resetsAt = isoDate(limit["resets_at"])
        let scope = limit["scope"] as? [String: Any]
        let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case "session":
            return QuotaWindow(id: "session", label: "5h", title: "5-hour session", percentUsed: percent,
                               resetsAt: resetsAt, duration: fiveHours, source: .official)
        case "weekly_all":
            return QuotaWindow(id: "weekly_all", label: "week", title: "Weekly (all models)", percentUsed: percent,
                               resetsAt: resetsAt, duration: week, source: .official)
        case "weekly_scoped":
            let name = model ?? "scoped"
            return QuotaWindow(id: "weekly_scoped_\(name)_\(index)", label: "\(name) wk", title: "Weekly (\(name))",
                               percentUsed: percent, resetsAt: resetsAt, duration: week, source: .official, modelScope: name)
        default:
            // Unknown kinds are shown as they come, with the group ("weekly", …) as label.
            let group = limit["group"] as? String ?? kind
            let duration: TimeInterval? = group == "weekly" ? week : group == "session" ? fiveHours : nil
            return QuotaWindow(id: "\(kind)_\(index)", label: group, title: kind.replacingOccurrences(of: "_", with: " "),
                               percentUsed: percent, resetsAt: resetsAt, duration: duration, source: .official)
        }
    }

    /// `GET https://chatgpt.com/backend-api/wham/usage`: `rate_limit.primary_window` and
    /// `secondary_window`.
    static func codex(_ data: Data, now: Date) -> [QuotaWindow]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else { return nil }
        let windows: [QuotaWindow] = ["primary_window", "secondary_window"].compactMap { key in
            guard let window = rateLimit[key] as? [String: Any],
                  let percent = number(window["used_percent"]) else { return nil }
            let seconds = number(window["limit_window_seconds"])
            var resetsAt = number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            if resetsAt == nil, let after = number(window["reset_after_seconds"]) {
                resetsAt = now.addingTimeInterval(after)
            }
            let (label, title) = windowNames(seconds: seconds)
            return QuotaWindow(id: key, label: label, title: title, percentUsed: percent,
                               resetsAt: resetsAt, duration: seconds, source: .official)
        }
        return windows.isEmpty ? nil : windows
    }

    /// "5h" / "5-hour window", "week" / "Weekly", "3d" / "3-day window".
    static func windowNames(seconds: Double?) -> (label: String, title: String) {
        guard let seconds, seconds > 0 else { return ("limit", "Limit") }
        if abs(seconds - week) < 60 { return ("week", "Weekly") }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 || hours % 24 != 0 { return ("\(hours)h", "\(hours)-hour window") }
        return ("\(hours / 24)d", "\(hours / 24)-day window")
    }

    private static func number(_ value: Any?) -> Double? {
        // `is Bool` is true for any NSNumber 0 or 1, so compare the CF type instead.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// ISO 8601 with or without fractional seconds (the API sends six digits).
    static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}

// MARK: - Formatting

enum UsageFormat {
    /// "950", "12.3K", "1.2M", "3.4B".
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return compact(value / 1_000) + "K"
        case ..<1_000_000_000: return compact(value / 1_000_000) + "M"
        default: return compact(value / 1_000_000_000) + "B"
        }
    }

    private static func compact(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    static func amount(_ value: Double, unit: UsageUnit) -> String {
        unit == .tokens ? tokens(Int(value.rounded())) + " tokens" : usd(value)
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "<1m", "45m", "1h32m", "6d 4h".
    static func countdown(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded(.down))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h\(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// "just now", "3 min ago", "2 h ago".
    static func ago(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }
}
