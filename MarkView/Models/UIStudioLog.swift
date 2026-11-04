import Foundation

/// One entry of UI Studio's log (REQ-011): something the session did or saw. Its text is redacted before the entry exists.
struct StudioLogEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// A page load, a link or form of the page, a server redirect, a blocked or failed navigation, a route change.
        case navigation
        /// A request of the page or of the development server, with how the session answered it.
        case request
        /// The start and the end of preparing simulation rules, for one request or ahead of a page.
        case preparation
        /// What the page reported: runtime errors (console.error included), build error overlays, blocked resources.
        case page
        /// A line the development server printed.
        case server
        /// A notice of the session, or its state becoming failed or degraded.
        case notice
    }

    /// The entry's number in its log, from 1.
    var id: Int
    var date: Date
    var kind: Kind
    /// Something went wrong: an error, a failure, a request nothing could answer.
    var problem: Bool
    var text: String
}

/// The newest entries of a log, oldest first, at most `capacity` of them, with the number of problems among them.
struct StudioLogRing: Equatable, Sendable {
    static let capacity = 2_000

    let capacity: Int
    private(set) var entries: [StudioLogEntry] = []
    private(set) var problems = 0

    init(capacity: Int = StudioLogRing.capacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ entry: StudioLogEntry) {
        entries.append(entry)
        if entry.problem { problems += 1 }
        guard entries.count > capacity else { return }
        let dropped = entries.count - capacity
        problems -= entries.prefix(dropped).filter(\.problem).count
        entries.removeFirst(dropped)
    }

    mutating func removeAll() {
        entries = []
        problems = 0
    }
}

/// How an entry becomes text: redaction, the line of the log file and the signs of a problem.
enum StudioLogFormat {
    /// Longer texts (a hydration diff, a stack) are cut here.
    static let maxText = 4_000

    /// `text` as the log may keep it. Known secret values go first, by the hash of every token and of every value glued to
    /// its name with `=` (`?key=value`), then bearer credentials, then the redactor's credential shapes (JWTs, provider
    /// keys) and confidential `name=value` pairs.
    static func redact(_ text: String, redactor: StudioRedactor, hashes: [String: String]) -> String {
        var result = StudioConnections.redact(text, hashes: hashes)
        result = redactGlued(result, hashes: hashes)
        result = result.replacingOccurrences(of: #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"#, with: "$1 " + StudioRedactor.placeholder,
                                             options: .regularExpression)
        return redactor.redact(text: result)
    }

    /// Values after an `=` inside a token, which the token pass sees only together with their name.
    private static func redactGlued(_ text: String, hashes: [String: String]) -> String {
        guard !hashes.isEmpty, text.contains("="),
              let expression = try? NSRegularExpression(pattern: #"(?<==)[A-Za-z0-9._~+/=-]{8,}"#) else { return text }
        var result = text
        let whole = NSRange(result.startIndex..., in: result)
        for match in expression.matches(in: result, range: whole).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let value = String(result[range])
            if let name = hashes[StudioConnections.hash(value)] { result.replaceSubrange(range, with: "[redacted:\(name)]") }
        }
        return result
    }

    /// The text of an entry: trimmed, cut at `maxText` characters, never empty when there was something to say.
    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxText ? String(trimmed.prefix(maxText)) + "…" : trimmed
    }

    /// One line of `session.log`: local time with milliseconds and offset, the kind, `!` for a problem (`-` otherwise) and
    /// the text, its line breaks written as `\n` so an entry is always one line.
    static func line(_ entry: StudioLogEntry) -> String {
        var text = ""
        text.reserveCapacity(entry.text.utf8.count)
        var previousReturn = false
        for scalar in entry.text.unicodeScalars {
            switch scalar {
            case "\r": text += "\\n"
            case "\n": if !previousReturn { text += "\\n" }
            case "\t": text += " "
            default: text.unicodeScalars.append(scalar.value < 0x20 || scalar.value == 0x7f ? " " : scalar)
            }
            previousReturn = scalar == "\r"
        }
        return "\(timestamp(entry.date)) \(tag(entry.kind, problem: entry.problem))\(text)\n"
    }

    /// The middle of a line, between its time and its text: `request     - `, `preparation ! `.
    static func tag(_ kind: StudioLogEntry.Kind, problem: Bool) -> String {
        let width = StudioLogEntry.Kind.allCases.map(\.rawValue.count).max() ?? 0
        return kind.rawValue.padding(toLength: width, withPad: " ", startingAt: 0) + (problem ? " ! " : " - ")
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
    }

    /// A line of a development server or a notice that reports something wrong: an error, an exception, a failure, a crash.
    /// Only a sign for the log's Problems filter, never a decision about the build (see `StudioSession.buildFailure`).
    static func looksLikeError(_ text: String) -> Bool {
        let none = #"(?i)\b(?:0|no|zero)\s+(?:errors?|failures?|failed)\b"#
        let signs = #"(?i)\b(?:error|errors|exception|fatal|panic|failed|failure|crashed|traceback|uncaught|unhandled|could not|cannot|did not|econnrefused|enotfound|eaddrinuse|etimedout)\b|ERR!|⨯|✘"#
            // A request the server answered with 5xx, in the Next.js (`GET / 500 in 12ms`) and the access-log form.
            + #"|\b(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+\S+(?:\s+HTTP/[\d.]+"?)?\s+5\d\d\b"#
        guard text.range(of: signs, options: .regularExpression) != nil else { return false }
        return text.replacingOccurrences(of: none, with: "", options: .regularExpression).range(of: signs, options: .regularExpression) != nil
    }

    /// A redirect to what looks like a sign-in page: an application that sends every page there renders nothing else.
    static func isSignInPath(_ path: String) -> Bool {
        path.lowercased().range(of: #"(^|/)(log-?in|sign-?in|auth|sso|oauth|session/new)(/|$|\?|#)"#, options: .regularExpression) != nil
    }
}

/// Splits a process's output, which arrives in pieces, into whole lines; a piece may end inside a line. Terminal colour
/// codes are removed, and a line that never ends is cut at `maxPending` characters.
struct StudioLogLines: Sendable {
    static let maxPending = 8_000
    private var pending = ""

    /// The lines completed by `piece`, without their line breaks and without empty ones.
    mutating func feed(_ piece: String) -> [String] {
        pending += piece
        var lines: [String] = []
        while let range = pending.rangeOfCharacter(from: .newlines) {
            lines.append(String(pending[..<range.lowerBound]))
            pending.removeSubrange(..<range.upperBound)
        }
        if pending.count > Self.maxPending {
            lines.append(pending)
            pending = ""
        }
        return lines.map(Self.plain).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What is left after the last line break (the process ended without one).
    mutating func flush() -> [String] {
        let rest = Self.plain(pending)
        pending = ""
        return rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest]
    }

    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}

/// `.dde/studio/session.log` (REQ-011): one line per entry. Before a line would take the file past `limit` bytes the file
/// becomes `session.log.1`, replacing the one before. Used only on one serial queue; the file is readable by its owner only.
final class StudioLogFile: @unchecked Sendable {
    static let rotationSize = 2 * 1024 * 1024

    let root: URL
    let url: URL
    let limit: Int
    private var size: Int?

    init(root: URL, limit: Int = StudioLogFile.rotationSize) {
        self.root = root
        url = StudioStore.logURL(root)
        self.limit = limit
    }

    var rotatedURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1") }

    /// Whether a file of `size` bytes is moved aside before `adding` more bytes. A line longer than the limit still goes
    /// into an empty file, so nothing is lost.
    static func shouldRotate(size: Int, adding: Int, limit: Int) -> Bool {
        size > 0 && size + adding > limit
    }

    func append(_ line: String) {
        let data = Data(line.utf8)
        let fm = FileManager.default
        let current = size ?? ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        if Self.shouldRotate(size: current, adding: data.count, limit: limit) {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: url, to: rotatedURL)
        }
        size = nil
        if !fm.fileExists(atPath: url.path) {
            StudioStore.prepareLocalFolder(root)
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        // The size comes from the file itself, so a file removed or rotated meanwhile is measured again.
        guard let end = try? handle.seekToEnd(), (try? handle.write(contentsOf: data)) != nil else { return }
        size = Int(end) + data.count
    }
}

/// UI Studio's log (REQ-011): navigations, requests, rule preparations, page events, server output and notices of one
/// session, newest last. Every text is redacted before it is kept. The view shows the last `StudioLogRing.capacity` entries;
/// every entry is also appended to `.dde/studio/session.log` on the session's serial I/O queue.
@MainActor
final class StudioLog: ObservableObject {
    @Published private(set) var ring: StudioLogRing
    /// Hashes of the project's secret values → their names (`StudioConnectionDiscovery.secretHashes`); never the values.
    var secretHashes: [String: String] = [:]
    private let redactor: StudioRedactor
    private let file: StudioLogFile?
    private let queue: DispatchQueue
    private var next = 1

    /// `root` nil keeps the log in memory only.
    init(root: URL?, redactor: StudioRedactor, queue: DispatchQueue, capacity: Int = StudioLogRing.capacity) {
        ring = StudioLogRing(capacity: capacity)
        self.redactor = redactor
        self.queue = queue
        file = root.map { StudioLogFile(root: $0) }
    }

    var entries: [StudioLogEntry] { ring.entries }
    var problems: Int { ring.problems }
    var fileURL: URL? { file?.url }

    func add(_ kind: StudioLogEntry.Kind, problem: Bool = false, _ text: String) {
        let shown = StudioLogFormat.clean(StudioLogFormat.redact(text, redactor: redactor, hashes: secretHashes))
        guard !shown.isEmpty else { return }
        let entry = StudioLogEntry(id: next, date: Date(), kind: kind, problem: problem, text: shown)
        next += 1
        ring.append(entry)
        guard let file else { return }
        let line = StudioLogFormat.line(entry)
        queue.async { file.append(line) }
    }

    /// Empties what the view shows; the file keeps every line.
    func clear() {
        ring.removeAll()
    }

    /// `entries` as the lines of the log file, for the clipboard.
    static func text(_ entries: [StudioLogEntry]) -> String {
        entries.map(StudioLogFormat.line).joined()
    }
}
