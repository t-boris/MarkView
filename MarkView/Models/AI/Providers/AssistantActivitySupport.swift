import Foundation

// What a running assistant is doing, read from its own session store (log files, SQLite) for the tabs and the toolbar.
// The generic types (`AgentActivity`, the log helpers) are in AgentActivity.swift; each provider says where its
// assistant keeps the session and how to read it.

/// The previous read of a terminal, so that an unchanged log is not parsed again.
struct ActivityCache {
    let url: URL
    let size: Int
    let date: Date
    let activity: AgentActivity?
}

/// One terminal to look at.
struct ActivityRequest {
    let directory: URL
    /// The terminal's shell process: the assistant running in it is its descendant.
    let shell: pid_t
    /// The terminal printed in the last few seconds.
    let printing: Bool
    let cached: ActivityCache?
    /// When this run of the assistant began.
    let since: Date?
}

/// What one look found.
struct ActivityRead {
    let source: URL
    let size: Int
    let date: Date
    let activity: AgentActivity?
    /// The model the session log says the assistant runs now, for assistants with `liveModelSwitch`.
    var model: String?
}

protocol AssistantActivitySupport: Sendable {
    /// nil when no session of this assistant can be found for the terminal.
    func read(_ request: ActivityRequest) -> ActivityRead?
}

extension AgentActivityLog {
    /// A JSON-lines session log: the cached result while the file is unchanged and idle, else its tail parsed.
    static func readLog(at url: URL, cached: ActivityCache?, parse: ([Data]) -> AgentActivity?,
                        model: (([Data]) -> String?)? = nil) -> ActivityRead? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate else { return nil }
        let size = values.fileSize ?? 0
        if let cached, cached.url == url, cached.size == size, cached.date == date, cached.activity?.state != .working {
            return ActivityRead(source: url, size: size, date: date, activity: cached.activity)
        }
        let lines = tail(of: url)
        return ActivityRead(source: url, size: size, date: date, activity: parse(lines), model: model?(lines))
    }
}
