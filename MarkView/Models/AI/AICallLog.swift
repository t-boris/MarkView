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
        /// "ok", "failed", "cancelled" or "timeout" (CLI process-level outcome).
        var outcome: String
        /// Result acceptance assessed by `AIOperation` separately from CLI process exit (REQ-009):
        /// "accepted", "repair_needed", "rejected", or nil for raw process-level log entries.
        var acceptance: String? = nil
        /// 1-based attempt number inside `AIOperation`, when recorded at the operation level.
        var attempt: Int? = nil
        /// Short reason `parse` or `validate` rejected a response (never contains secrets or documents).
        var rejectionReason: String? = nil
    }

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MarkView", isDirectory: true).appendingPathComponent("ai-calls.jsonl")
    }

    /// Operation-level log recording validation/acceptance separately from CLI process completion (REQ-009).
    static var operationsURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("ai-operations.jsonl")
    }

    /// Writes in order, off the caller's thread.
    private static let queue = DispatchQueue(label: "markview.ai-call-log")

    static func record(_ entry: Entry, to destination: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }
        let url = destination ?? url
        queue.async { try? AtomicFile.append(data + Data("\n".utf8), to: url) }
    }

    /// Records an operation-level acceptance outcome into `ai-operations.jsonl` (or a test destination).
    static func recordOperation(_ entry: Entry, to destination: URL? = nil) {
        record(entry, to: destination ?? operationsURL)
    }

    /// Wait for queued writes before removing a temporary destination.
    static func waitForPendingWrites() { queue.sync {} }

    /// Entries of the log, oldest first; damaged lines are skipped.
    static func read(from source: URL? = nil) -> [Entry] {
        guard let text = try? String(contentsOf: source ?? url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return JSONLinesFile.decode(Entry.self, from: text, using: decoder, owner: "AI call log").records
    }
}
