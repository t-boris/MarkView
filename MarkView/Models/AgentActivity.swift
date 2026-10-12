import Foundation

// What an assistant CLI is doing right now, read from the tail of its own session log
// (Claude Code's ~/.claude/projects/<folder>/*.jsonl, Codex's ~/.codex/sessions/**/rollout-*.jsonl).
// Foundation only and no network, like AgentUsageLogs; tools/tests/agent-activity-tests.sh checks
// the parsers. Only tool names, file names and the session's own title are shown: command lines
// and file contents are never read into the text, because they can hold secrets.

struct AgentActivity: Equatable {
    enum State: Equatable { case working, idle, failing }
    var state: State
    /// What is happening now, in words: the agent's own last sentence of this turn ("Now building
    /// the app"), else the tool it is using ("Editing BrowserSession.swift"). Never a bare "Thinking".
    var text: String
    /// The concrete tool call behind `text` ("Running xcodebuild"), when it differs.
    var detail: String?
    /// What it was asked to do: the last request typed to it, one line.
    var task: String?
    /// The session's own title, when the log has one.
    var topic: String?
}

enum AgentActivityParser {
    /// A tool call over this old, with nothing after it, is a session that stopped (or was killed).
    static let staleAfter: TimeInterval = 15 * 60

    // MARK: Claude Code

    static func claude(lines: [Data], now: Date = Date()) -> AgentActivity? {
        var topic: String?, task: String?
        var last: (kind: Kind, text: String, date: Date?)?
        var narration: String?, latestNarration: String?, action: String?
        var failed: Bool?, sawResult = false
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "ai-title" {
                if topic == nil, let title = object["aiTitle"] as? String, !title.isEmpty { topic = clip(title, 60) }
                continue
            }
            guard type == "assistant" || type == "user", object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            if last == nil { last = classifyClaude(type: type, message: message, date: date(object["timestamp"])) }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "user" {
                if let result = blocks.first(where: { $0["type"] as? String == "tool_result" }) {
                    sawResult = true
                    if failed == nil { failed = result["is_error"] as? Bool ?? false }
                }
                if let prompt = userPrompt(message["content"]) { task = prompt; break }
            } else {
                if latestNarration == nil, let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
                   let sentence = firstSentence(text) {
                    latestNarration = sentence
                    if !sawResult { narration = sentence }
                }
                if action == nil, let use = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                    action = describe(tool: use["name"] as? String ?? "", input: use["input"] as? [String: Any] ?? [:])
                }
            }
        }
        // The session's title sits before the prompt; keep looking for it.
        if topic == nil {
            for line in lines.reversed() {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["type"] as? String == "ai-title",
                   let title = object["aiTitle"] as? String, !title.isEmpty { topic = clip(title, 60); break }
            }
        }
        guard let last else { return nil }
        // While a tool runs only a sentence said right before it describes it; between tools the turn's
        // latest sentence still says what the work is.
        let running = last.text.isEmpty ? false : true
        return finish(last, narration: running ? narration : latestNarration, action: action, failed: failed == true,
                      task: task, topic: topic, now: now)
    }

    /// The text of a request typed to the agent; nil for tool results, interruptions and the
    /// system's own wrappers (`<system-reminder>`, `<command-name>`…).
    private static func userPrompt(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String { text = string }
        else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        } else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("["), !trimmed.hasPrefix("Caveat:") else { return nil }
        return clip(trimmed, 90)
    }

    /// The first sentence of an assistant message, without markdown marks, at most 100 characters.
    static func firstSentence(_ text: String) -> String? {
        let plain = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, !plain.hasPrefix("#"), !plain.hasPrefix("|"), !plain.hasPrefix("-") else { return nil }
        var sentence = plain
        if let end = plain.range(of: #"[.!?:](\s|$)"#, options: .regularExpression) { sentence = String(plain[..<end.lowerBound]) }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        return sentence.count < 4 ? nil : clip(sentence, 100)
    }

    private enum Kind { case working, idle }

    private static func classifyClaude(type: String, message: [String: Any], date: Date?) -> (kind: Kind, text: String, date: Date?)? {
        let content = message["content"]
        if type == "user" {
            if let text = content as? String { return text.hasPrefix("[Request interrupted") ? (.idle, "Interrupted", date) : (.working, "", date) }
            guard let blocks = content as? [[String: Any]], let block = blocks.last else { return nil }
            let text = block["text"] as? String ?? ""
            return text.hasPrefix("[Request interrupted") ? (.idle, "Interrupted", date) : (.working, "", date)
        }
        guard let blocks = content as? [[String: Any]], let block = blocks.last else { return nil }
        switch block["type"] as? String {
        case "tool_use":
            return (.working, describe(tool: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:]), date)
        case "thinking":
            return (.working, "", date)
        case "text":
            return message["stop_reason"] as? String == "end_turn" ? (.idle, "Waiting for you", date) : (.working, "", date)
        default:
            return nil
        }
    }

    // MARK: Codex

    static func codex(lines: [Data], now: Date = Date()) -> AgentActivity? {
        var last: (kind: Kind, text: String, date: Date?)?
        var narration: String?, task: String?
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            let stamp = date(object["timestamp"])
            if last == nil {
                switch (type, kind) {
                case ("event_msg", "task_complete"): last = (.idle, "Waiting for you", stamp)
                case ("event_msg", "turn_aborted"): last = (.idle, "Interrupted", stamp)
                case ("response_item", "function_call"), ("response_item", "local_shell_call"): last = (.working, "Running a command", stamp)
                case ("event_msg", "task_started"), ("event_msg", "user_message"), ("response_item", "reasoning"),
                     ("response_item", "function_call_output"), ("response_item", "message"): last = (.working, "", stamp)
                default: break
                }
            }
            if type == "event_msg", kind == "user_message" {
                if let text = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { task = clip(text, 90) }
                break
            }
            if narration == nil, type == "response_item", kind == "message", payload["role"] as? String == "assistant",
               let parts = payload["content"] as? [[String: Any]],
               let text = parts.compactMap({ $0["text"] as? String }).last, let sentence = firstSentence(text) { narration = sentence }
        }
        guard let last else { return nil }
        return finish(last, narration: narration, action: nil, failed: false, task: task, topic: nil, now: now)
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

    private static let subcommandPrograms: Set<String> = ["git", "npm", "pnpm", "yarn", "firebase", "vercel", "fly", "docker",
                                                          "cargo", "brew", "swift", "make", "xcodegen", "kubectl", "terraform"]

    /// The program of a shell command: its name only, after any `VAR=value` prefixes and `cd x &&`.
    static func program(of command: String?) -> String? {
        guard let text = command?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let segments = text.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments {
            let words = segment.split(separator: " ").filter { !$0.contains("=") }
            guard let first = words.first, first != "cd", first != "export", first != "set" else { continue }
            let name = (String(first) as NSString).lastPathComponent
            guard name.range(of: "^[A-Za-z0-9_.+-]{1,32}$", options: .regularExpression) != nil else { return nil }
            // "git push", "gh pr merge": the subcommand says what is being done; arguments never shown.
            let depth = name == "gh" ? 2 : subcommandPrograms.contains(name) ? 1 : 0
            var parts = [name]
            for word in words.dropFirst().prefix(depth) {
                guard word.range(of: "^[a-z][a-z:-]{1,24}$", options: .regularExpression) != nil else { break }
                parts.append(String(word))
            }
            return parts.joined(separator: " ")
        }
        return nil
    }

    private static func finish(_ found: (kind: Kind, text: String, date: Date?), narration: String?, action: String?,
                                failed: Bool, task: String?, topic: String?, now: Date) -> AgentActivity {
        if found.kind == .working, let date = found.date, now.timeIntervalSince(date) > staleAfter {
            return AgentActivity(state: .idle, text: "No activity for \(Int(now.timeIntervalSince(date) / 60)) min", detail: nil, task: task, topic: topic)
        }
        if found.kind == .idle { return AgentActivity(state: .idle, text: found.text, detail: nil, task: task, topic: topic) }
        // A tool is running: its phrase. Between tools: the agent's own words, else what it just did.
        let tool = found.text.isEmpty ? nil : found.text
        var text = narration ?? tool ?? action.map { "After: " + $0 } ?? "Starting on the request"
        if failed { text = "Last step failed · " + text }
        return AgentActivity(state: failed ? .failing : .working, text: text, detail: narration != nil ? (tool ?? action) : nil,
                             task: task, topic: topic)
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
