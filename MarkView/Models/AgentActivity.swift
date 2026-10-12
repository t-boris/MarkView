import Foundation

// What an assistant CLI is doing right now, read from the tail of its own session log
// (Claude Code's ~/.claude/projects/<folder>/*.jsonl, Codex's ~/.codex/sessions/**/rollout-*.jsonl).
// Foundation only and no network, like AgentUsageLogs; tools/tests/agent-activity-tests.sh checks
// the parsers. Only tool names, file names and the session's own title are shown: command lines
// and file contents are never read into the text, because they can hold secrets.

struct AgentActivity: Equatable {
    enum State: Equatable { case working, idle }
    var state: State
    /// "Editing BrowserSession.swift", "Running xcodebuild", "Thinking", "Waiting for you".
    var text: String
    /// The session's own title ("Sign-in popups in the browser"), when the log has one.
    var topic: String?
}

enum AgentActivityParser {
    /// A tool call over this old, with nothing after it, is a session that stopped (or was killed).
    static let staleAfter: TimeInterval = 15 * 60

    // MARK: Claude Code

    static func claude(lines: [Data], now: Date = Date()) -> AgentActivity? {
        var topic: String?
        var last: (kind: Kind, text: String, date: Date?)?
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "ai-title", topic == nil, let title = object["aiTitle"] as? String, !title.isEmpty {
                topic = clip(title, 60)
                continue
            }
            guard last == nil, type == "assistant" || type == "user",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            last = classifyClaude(type: type, message: message, date: date(object["timestamp"]))
            if topic != nil { break }
        }
        guard let last else { return nil }
        return finish(last, topic: topic, now: now)
    }

    private enum Kind { case working, idle }

    private static func classifyClaude(type: String, message: [String: Any], date: Date?) -> (kind: Kind, text: String, date: Date?)? {
        let content = message["content"]
        if type == "user" {
            if let text = content as? String { return (text.hasPrefix("[Request interrupted") ? .idle : .working,
                                                      text.hasPrefix("[Request interrupted") ? "Interrupted" : "Thinking", date) }
            guard let blocks = content as? [[String: Any]], let block = blocks.last else { return nil }
            if block["type"] as? String == "tool_result" { return (.working, "Thinking", date) }
            let text = block["text"] as? String ?? ""
            return text.hasPrefix("[Request interrupted") ? (.idle, "Interrupted", date) : (.working, "Thinking", date)
        }
        guard let blocks = content as? [[String: Any]], let block = blocks.last else { return nil }
        switch block["type"] as? String {
        case "tool_use":
            return (.working, describe(tool: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:]), date)
        case "thinking":
            return (.working, "Thinking", date)
        case "text":
            let ended = message["stop_reason"] as? String == "end_turn"
            return ended ? (.idle, "Waiting for you", date) : (.working, "Writing a reply", date)
        default:
            return nil
        }
    }

    // MARK: Codex

    static func codex(lines: [Data], now: Date = Date()) -> AgentActivity? {
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            let stamp = date(object["timestamp"])
            var found: (kind: Kind, text: String, date: Date?)?
            switch (type, kind) {
            case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                found = (.idle, kind == "task_complete" ? "Waiting for you" : "Interrupted", stamp)
            case ("event_msg", "task_started"), ("event_msg", "user_message"):
                found = (.working, "Thinking", stamp)
            case ("response_item", "function_call"), ("response_item", "local_shell_call"):
                found = (.working, "Running a command", stamp)
            case ("response_item", "reasoning"), ("response_item", "function_call_output"):
                found = (.working, "Thinking", stamp)
            case ("response_item", "message"):
                found = (.working, "Writing a reply", stamp)
            default:
                continue
            }
            return found.flatMap { finish($0, topic: nil, now: now) }
        }
        return nil
    }

    // MARK: Text

    /// A readable phrase for a tool call. The command line of a shell call is not used (it can
    /// carry tokens): only its own description, else the program's name.
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ keys: String...) -> String? {
            for key in keys {
                if let path = input[key] as? String, !path.isEmpty { return clip((path as NSString).lastPathComponent, 40) }
            }
            return nil
        }
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return file("file_path", "notebook_path").map { "Editing \($0)" } ?? "Editing files"
        case "Read":
            return file("file_path").map { "Reading \($0)" } ?? "Reading files"
        case "Bash", "BashOutput":
            if let description = input["description"] as? String, !description.isEmpty { return clip(description, 60) }
            return program(of: input["command"] as? String).map { "Running \($0)" } ?? "Running a command"
        case "Grep", "Glob", "LS":
            return "Searching the project"
        case "Task", "Agent":
            if let description = input["description"] as? String, !description.isEmpty { return "Subagent: " + clip(description, 50) }
            return "Running a subagent"
        case "WebFetch", "WebSearch":
            return "Searching the web"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Planning"
        case "ExitPlanMode":
            return "Presenting a plan"
        case "AskUserQuestion":
            return "Asking you a question"
        default:
            if tool.hasPrefix("mcp__") { return "Using \(tool.split(separator: "_").last.map(String.init) ?? "a tool")" }
            return tool.isEmpty ? "Working" : "Using \(tool)"
        }
    }

    /// The program of a shell command: its name only, after any `VAR=value` prefixes and `cd x &&`.
    static func program(of command: String?) -> String? {
        guard let text = command?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let segments = text.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments {
            let words = segment.split(separator: " ").filter { !$0.contains("=") }
            guard let first = words.first, first != "cd", first != "export", first != "set" else { continue }
            let name = (String(first) as NSString).lastPathComponent
            return name.range(of: "^[A-Za-z0-9_.+-]{1,32}$", options: .regularExpression) != nil ? name : nil
        }
        return nil
    }

    private static func finish(_ found: (kind: Kind, text: String, date: Date?), topic: String?, now: Date) -> AgentActivity {
        if found.kind == .working, let date = found.date, now.timeIntervalSince(date) > staleAfter {
            let minutes = Int(now.timeIntervalSince(date) / 60)
            return AgentActivity(state: .idle, text: "No activity for \(minutes) min", topic: topic)
        }
        return AgentActivity(state: found.kind == .working ? .working : .idle, text: found.text, topic: topic)
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > length ? String(one.prefix(length - 1)) + "…" : one
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Finds and reads the log of the session running in a folder.
enum AgentActivityLog {
    /// Claude Code names a project's log folder after its path with every other character as "-".
    static func claudeFolderName(for directory: URL) -> String {
        String(directory.standardizedFileURL.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func newestClaudeLog(for directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let folder = home.appendingPathComponent(".claude/projects").appendingPathComponent(claudeFolderName(for: directory))
        return newest(in: [folder], matching: { _ in true })
    }

    /// The newest Codex rollout from the last two days whose first line names this folder.
    static func newestCodexLog(for directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               now: Date = Date()) -> URL? {
        let root = home.appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current
        let folders = (0..<2).compactMap { offset -> URL? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
        }
        let path = directory.standardizedFileURL.path
        return newest(in: folders, matching: { url in
            guard let first = firstLine(of: url), let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String else { return false }
            return URL(fileURLWithPath: cwd).standardizedFileURL.path == path
        })
    }

    private static func newest(in folders: [URL], matching accept: (URL) -> Bool) -> URL? {
        var files: [(URL, Date)] = []
        for folder in folders {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in urls where url.pathExtension == "jsonl" {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    files.append((url, date))
                }
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(6).first { accept($0.0) }?.0
    }

    /// The last complete lines of a log (at most `bytes` from its end).
    static func tail(of url: URL, bytes: Int = 256 * 1024) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func firstLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) }
    }
}
