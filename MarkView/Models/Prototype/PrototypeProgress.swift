import CoreGraphics
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
/// Turns the assistant's activity (files read, searches, the answer growing) into events. The CLI reports
/// from its own threads and for every token, so the answer is scanned for the file being written and the
/// size line is throttled.
// unchecked Sendable: every mutable field is read and written under `lock`; the CLI reports from its own threads.
final class PrototypeProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: PrototypeAI.Stage
    private let rootPrefix: String
    private let onRead: (@Sendable (String) -> Void)?
    private var buffer = ""
    private var lastPath = ""
    private var lastSize = Date.distantPast
    private var thinking = false
    private var reads = 0
    private var thinkingTicks = 0
    /// What the assistant reads, for the status line ("the requirements" or "the code").
    private let reading: String

    init(root: URL, reading: String = "the requirements", onRead: (@Sendable (String) -> Void)? = nil, emit: @escaping PrototypeAI.Stage) {
        self.emit = emit
        self.onRead = onRead
        self.reading = reading
        rootPrefix = root.standardizedFileURL.path + "/"
    }

    private func short(_ path: String) -> String { path.replacingOccurrences(of: rootPrefix, with: "") }

    func handle(_ activity: CLICompletion.Activity) {
        lock.lock(); defer { lock.unlock() }
        if case .thinking = activity {} else { thinking = false }
        switch activity {
        case .read(let path):
            reads += 1
            onRead?(short(path))
            emit(.log("Reading \(short(path))"))
            emit(.status("Reading \(reading) (\(reads) file\(reads == 1 ? "" : "s") so far)"))
        case .search(let query):
            emit(.log("Searching for “\(query.prefix(60))”"))
        case .run(let command):
            emit(.log("Running \(command.prefix(80))"))
        case .webSearch, .webFetch:
            break
        case .thinking:
            if !thinking { emit(.log("Thinking")) }
            thinking = true
            thinkingTicks += 1
            let base = reads == 0 ? "Thinking" : "Designing the screens"
            // The CLI reports reasoning every ~1,500 characters, so a long phase still visibly moves.
            emit(.status(thinkingTicks > 1 ? "\(base) — about \(thinkingTicks * 3 / 2)K characters of reasoning" : base))
        case .writing(let count):
            guard Date().timeIntervalSince(lastSize) > 0.7 else { return }
            lastSize = Date()
            emit(.status("Writing the files — \(count / 1000) K characters so far"))
        case .answerDelta(let text):
            buffer += text
            if buffer.count > 600 { buffer = String(buffer.suffix(600)) }
            guard let match = try? NSRegularExpression(pattern: "\"path\"\\s*:\\s*\"([^\"]+)\"")
                    .matches(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)).last,
                  let range = Range(match.range(at: 1), in: buffer) else { return }
            let path = String(buffer[range])
            if path != lastPath {
                lastPath = path
                emit(.log("Writing \(path)"))
            }
        }
    }
}
