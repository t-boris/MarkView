import Foundation

// Usage counted from the agents' local CLI logs (DEC-007): Claude Code's
// ~/.claude/projects/**/*.jsonl and Codex's ~/.codex/sessions/**/*.jsonl. Foundation only and
// no network (DEC-013); tools/tests/agent-usage-tests.sh checks the line parsers.

/// Tokens (and cost, when the log records it) of one model call.
struct UsageEvent: Sendable {
    let date: Date
    let tokens: Int
    let costUSD: Double?
}

enum UsageLogError: Error, Equatable {
    /// No log directory, or no log file could be read.
    case unreadable(String)
    /// Files were read but none of their usage lines had the expected shape (format changed).
    case unrecognised(String)

    var message: String {
        switch self {
        case .unreadable(let text), .unrecognised(let text): return text
        }
    }
}

/// Parsers of single log lines.
enum UsageLogLine {
    /// A Claude Code `assistant` line. The CLI writes one line per content block with the same
    /// `message.id` and `requestId`, so `key` is used to count each call once. Cost only when
    /// the line carries `costUSD` (older CLI versions); current ones record none per call.
    static func claude(_ line: Data, dates: ISO8601DateFormatter) -> (key: String, event: UsageEvent)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let date = parseDate(object["timestamp"], dates) else { return nil }
        let fields = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let tokens = fields.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        let id = message["id"] as? String ?? object["uuid"] as? String ?? ""
        let request = object["requestId"] as? String ?? ""
        let cost = (object["costUSD"] as? NSNumber)?.doubleValue
        return ("\(id):\(request)", UsageEvent(date: date, tokens: tokens, costUSD: cost))
    }

    /// A Codex `token_count` event: the session's cumulative total so far.
    static func codex(_ line: Data, dates: ISO8601DateFormatter) -> (date: Date, total: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let date = parseDate(object["timestamp"], dates) else { return nil }
        // `info` is null before the first model call of a session.
        guard let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any],
              let tokens = (total["total_tokens"] as? NSNumber)?.intValue else { return (date, -1) }
        return (date, tokens)
    }

    /// Fast path with fractional seconds (what the CLIs write), then any ISO 8601 form.
    private static func parseDate(_ value: Any?, _ dates: ISO8601DateFormatter) -> Date? {
        guard let string = value as? String else { return nil }
        return dates.date(from: string) ?? OfficialUsageParser.isoDate(string)
    }

    static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

/// Reads an agent's logs incrementally: each file is read from where the last scan stopped, so a
/// rescan after the CLI appended a few lines costs only those lines. Not thread-safe: it is
/// confined to one serial queue (`AgentUsageTracker.logQueue`), hence `@unchecked Sendable`.
final class UsageLogReader: @unchecked Sendable {
    let agent: UsageAgent
    private let roots: [URL]
    private let dates = UsageLogLine.timestampFormatter()

    private struct FileState {
        var offset: UInt64 = 0
        var events: [UsageEvent] = []
        var keys: [String] = []
        /// Codex: the cumulative total at the last event.
        var lastTotal = 0
        var candidates = 0
        var parsed = 0
    }

    private var files: [String: FileState] = [:]
    private var seenKeys = Set<String>()
    /// The earliest date the cached files cover; an earlier `since` forces a full rescan.
    private var coveredSince: Date?

    init(agent: UsageAgent, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.agent = agent
        let base = home.appendingPathComponent(agent.dataDirectoryName)
        switch agent {
        case .claude: roots = [base.appendingPathComponent("projects")]
        case .codex: roots = [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
        }
    }

    /// The directories to watch for changes.
    var watchedDirectories: [URL] { roots }

    /// Every call recorded since `since`, from the files changed since then.
    func events(since: Date) throws -> [UsageEvent] {
        let fm = FileManager.default
        let existingRoots = roots.filter { fm.fileExists(atPath: $0.path) }
        guard !existingRoots.isEmpty else {
            throw UsageLogError.unreadable("No local logs in ~/\(agent.dataDirectoryName)")
        }
        if let coveredSince, since < coveredSince { reset() }
        coveredSince = min(coveredSince ?? since, since)

        var seen = Set<String>()
        var failures = 0
        var attempted = 0
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for root in existingRoots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                failures += 1
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= since else { continue }
                attempted += 1
                seen.insert(url.path)
                if !read(url, size: UInt64(values.fileSize ?? 0)) { failures += 1 }
            }
        }
        // Files no longer changed inside the range: forget them.
        for path in files.keys where !seen.contains(path) { drop(path) }

        if attempted > 0 && failures == attempted {
            throw UsageLogError.unreadable("Could not read the logs in ~/\(agent.dataDirectoryName)")
        }
        let candidates = files.values.reduce(0) { $0 + $1.candidates }
        let parsed = files.values.reduce(0) { $0 + $1.parsed }
        if candidates > 0 && parsed == 0 {
            throw UsageLogError.unrecognised("\(agent.displayName) log format not recognised")
        }
        return files.values.flatMap { $0.events.filter { $0.date >= since } }
    }

    private func reset() {
        files = [:]
        seenKeys = []
        coveredSince = nil
    }

    private func drop(_ path: String) {
        guard let state = files.removeValue(forKey: path) else { return }
        seenKeys.subtract(state.keys)
    }

    /// Reads the part of `url` appended since the last scan. False when the file can't be read.
    private func read(_ url: URL, size: UInt64) -> Bool {
        var state = files[url.path] ?? FileState()
        if size < state.offset {
            // Rewritten or truncated: start over.
            drop(url.path)
            state = FileState()
        }
        guard size > state.offset else { files[url.path] = state; return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
            // In chunks: logs reach hundreds of MB. A line cut at a chunk's end is carried over.
            var carry = Data()
            var position = state.offset
            var done = false
            while position < size && !done {
                // The reads and JSONSerialization's objects are autoreleased; drain them per chunk.
                try autoreleasepool {
                    let count = Int(min(Self.chunkSize, size - position))
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { done = true; return }
                    position += UInt64(chunk.count)
                    carry.append(chunk)
                    // Only complete lines; a line being written is read next time.
                    guard let lastNewline = carry.lastIndex(of: 0x0A) else { return }
                    parse(carry[carry.startIndex..<lastNewline], into: &state)
                    state.offset += UInt64(lastNewline - carry.startIndex + 1)
                    carry = Data(carry[(lastNewline + 1)...])
                }
            }
        } catch {
            return false
        }
        files[url.path] = state
        return true
    }

    private static let chunkSize: UInt64 = 8 << 20

    private static let claudeMarker = Data(#""usage""#.utf8)
    private static let codexMarker = Data(#""token_count""#.utf8)

    private func parse(_ chunk: Data, into state: inout FileState) {
        let marker = agent == .claude ? Self.claudeMarker : Self.codexMarker
        var lineStart = chunk.startIndex
        while lineStart < chunk.endIndex {
            let lineEnd = chunk[lineStart...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let line = chunk[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Most lines (tool output, prompts) carry no usage: skip them without decoding.
            guard line.range(of: marker) != nil else { continue }
            switch agent {
            case .claude:
                // Only assistant lines count as candidates for the format check.
                guard line.range(of: Data(#""assistant""#.utf8)) != nil else { continue }
                state.candidates += 1
                guard let (key, event) = UsageLogLine.claude(Data(line), dates: dates) else { continue }
                state.parsed += 1
                guard seenKeys.insert(key).inserted else { continue }
                state.keys.append(key)
                state.events.append(event)
            case .codex:
                state.candidates += 1
                guard let (date, total) = UsageLogLine.codex(Data(line), dates: dates) else { continue }
                state.parsed += 1
                guard total >= 0 else { continue }
                // A total below the last one means a new counter (e.g. a resumed session).
                let delta = total >= state.lastTotal ? total - state.lastTotal : total
                state.lastTotal = total
                if delta > 0 { state.events.append(UsageEvent(date: date, tokens: delta, costUSD: nil)) }
            }
        }
    }
}

extension Array where Element == UsageEvent {
    /// Tokens and cost of the calls in [from, to). Cost is nil unless some call recorded one.
    func usage(from: Date, to: Date = .distantFuture) -> UsageAmount {
        var amount = UsageAmount.zero
        for event in self where event.date >= from && event.date < to {
            amount.tokens += event.tokens
            if let cost = event.costUSD { amount.costUSD = (amount.costUSD ?? 0) + cost }
        }
        return amount
    }

    /// Whether the logs record cost at all (DEC-014: a USD limit needs it).
    var recordsCost: Bool { contains { $0.costUSD != nil } }
}
