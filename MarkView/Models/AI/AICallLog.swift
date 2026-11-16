import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// One line per CLI completion, appended to `Application Support/MarkView/ai-calls.jsonl`: what
/// was asked (the caller's label), which assistant and model answered, the effort, how long it
/// took, the tokens and the cost. The file measures the AI workflows (how long discovery rounds
/// take, what an intake costs) without keeping any prompt or answer text.
enum AICallLog {
    struct Entry: Codable {
        var timestamp: Date
        /// The project the call worked for (its readable folder), or "" outside any project.
        var project: String
        /// The caller's label, e.g. "intake:feature", "explore:<slug>", "answer:<slug>".
        var label: String
        var tool: String
        var model: String
        var effort: String
        var seconds: Double
        var inputTokens: Int
        var outputTokens: Int
        var costUSD: Double?
        /// "ok", "failed", "cancelled" or "timeout".
        var outcome: String
    }

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MarkView", isDirectory: true).appendingPathComponent("ai-calls.jsonl")
    }

    /// Writes in order, off the caller's thread.
    private static let queue = DispatchQueue(label: "markview.ai-call-log")

    static func record(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }
        let url = url
        queue.async { try? AtomicFile.append(data + Data("\n".utf8), to: url) }
    }

    /// Entries of the log, oldest first; damaged lines are skipped.
    static func read() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return JSONLinesFile.decode(Entry.self, from: text, using: decoder, owner: "AI call log").records
    }
}
