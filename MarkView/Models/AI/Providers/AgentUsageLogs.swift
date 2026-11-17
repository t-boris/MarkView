import Foundation

// Usage counted from the agents' local CLI logs (DEC-007), in the format each assistant's provider describes
// (`UsageLogFormat`): Claude Code's ~/.claude/projects/**/*.jsonl, Codex's ~/.codex/sessions/**/*.jsonl. Foundation
// only and no network (DEC-013); app-hosted tests check the line parsers.

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

/// What the log formats share (the formats themselves are in each assistant's provider file).
enum UsageLogLine {
    /// Fast path with fractional seconds (what the CLIs write), then any ISO 8601 form.
    static func date(_ value: Any?, _ dates: ISO8601DateFormatter) -> Date? {
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
// unchecked Sendable: used only on `AgentUsageTracker.logQueue`, a serial queue, so two threads never touch it at once.
final class UsageLogReader: @unchecked Sendable {
    let agent: CLITool
    private let format: any UsageLogFormat
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

    /// Nil for an assistant that keeps no readable local logs (`CLITool.hasLocalLogs`).
    init?(agent: CLITool, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard let usage = agent.provider.usage, let format = usage.localLogs else { return nil }
        self.agent = agent
        self.format = format
        roots = format.roots(in: home.appendingPathComponent(usage.dataDirectoryName))
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

    private func parse(_ chunk: Data, into state: inout FileState) {
        var lineStart = chunk.startIndex
        while lineStart < chunk.endIndex {
            let lineEnd = chunk[lineStart...].firstIndex(of: 0x0A) ?? chunk.endIndex
            let line = chunk[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Most lines (tool output, prompts) carry no usage: skip them without decoding.
            guard line.range(of: format.marker) != nil else { continue }
            switch format.read(line: Data(line), dates: dates, lastTotal: &state.lastTotal) {
            case .notUsage:
                continue
            case .unrecognised:
                state.candidates += 1
            case .counted(let key, let event):
                state.candidates += 1
                state.parsed += 1
                if let key {
                    guard seenKeys.insert(key).inserted else { continue }
                    state.keys.append(key)
                }
                if let event { state.events.append(event) }
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
