import Darwin
import Foundation
import SQLite3

// What an assistant CLI is doing right now, read from the tail of its own session log
// (Claude Code's ~/.claude/projects/<folder>/*.jsonl, Codex's ~/.codex/sessions/**/rollout-*.jsonl).
// Foundation only and no network, like AgentUsageLogs; tools/tests/agent-activity-tests.sh checks
// the parsers. Only tool names, file names and the session's own title are shown: command lines
// and file contents are never read into the text, because they can hold secrets.

/// One item of the agent's own task list (Claude Code's TodoWrite, Codex's update_plan).
struct AgentPlanItem: Equatable {
    enum Status: Equatable { case pending, active, done }
    var title: String
    var status: Status
}

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
    /// The agent's task list as last written, in order; empty when it keeps none.
    var plan: [AgentPlanItem] = []

    var planDone: Int { plan.filter { $0.status == .done }.count }
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
        var result = finish(last, narration: running ? narration : latestNarration, action: action, failed: failed == true,
                            task: task, topic: topic, now: now)
        result.plan = claudePlan(lines)
        return result
    }

    /// The task list from the last TodoWrite call in the log tail.
    static func claudePlan(_ lines: [Data]) -> [AgentPlanItem] {
        for line in lines.reversed() where String(decoding: line, as: UTF8.self).contains("\"TodoWrite\"") {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
                  let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
                  let use = blocks.last(where: { $0["name"] as? String == "TodoWrite" }),
                  let todos = (use["input"] as? [String: Any])?["todos"] as? [[String: Any]] else { continue }
            return todos.compactMap { todo in
                guard let content = todo["content"] as? String ?? todo["activeForm"] as? String, !content.isEmpty else { return nil }
                return AgentPlanItem(title: clip(content, 90), status: planStatus(todo["status"] as? String))
            }
        }
        return []
    }

    /// Codex's update_plan: `arguments` is a JSON string `{"plan":[{"step":…,"status":…}]}`.
    static func codexPlan(_ lines: [Data]) -> [AgentPlanItem] {
        for line in lines.reversed() where String(decoding: line, as: UTF8.self).contains("update_plan") {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], payload["name"] as? String == "update_plan",
                  let arguments = payload["arguments"] as? String,
                  let input = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                  let steps = input["plan"] as? [[String: Any]] else { continue }
            return steps.compactMap { step in
                guard let title = step["step"] as? String, !title.isEmpty else { return nil }
                return AgentPlanItem(title: clip(title, 90), status: planStatus(step["status"] as? String))
            }
        }
        return []
    }

    static func planStatus(_ text: String?) -> AgentPlanItem.Status {
        switch text {
        case "completed", "done": return .done
        case "in_progress", "active": return .active
        default: return .pending
        }
    }

    /// The text of a request typed to the agent; nil for tool results, interruptions and the
    /// system's own wrappers (`<system-reminder>`, `<command-name>`…).
    private static func userPrompt(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String { text = string }
        else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        } else { return nil }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<user_input") {
            // Cline wraps the request: <user_input mode="act"><mode_notice>…</mode_notice>request</user_input>
            trimmed = trimmed.replacingOccurrences(of: #"(?s)<mode_notice>.*?</mode_notice>"#, with: "", options: [.regularExpression])
                .replacingOccurrences(of: #"</?user_input[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        var result = finish(last, narration: narration, action: nil, failed: false, task: task, topic: nil, now: now)
        result.plan = codexPlan(lines)
        return result
    }

    // MARK: Cline

    /// Cline's `<session>.messages.json` (Anthropic-shaped messages), read with the claude rules.
    /// `status` is the session row's: only "running"-like states count as working.
    static func cline(messagesJSON: Data, status: String, now: Date = Date()) -> AgentActivity? {
        guard let root = try? JSONSerialization.jsonObject(with: messagesJSON) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return nil }
        var lines: [Data] = []
        for message in messages {
            guard let role = message["role"] as? String,
                  let line = try? JSONSerialization.data(withJSONObject: ["type": role, "message": message]) else { continue }
            lines.append(line)
        }
        guard var result = claude(lines: lines, now: now) else { return nil }
        if status != "running" && status != "busy" && status != "active" {
            result.state = .idle
            result.text = status == "idle" ? "Waiting for you" : "Session " + status
            result.detail = nil
        }
        return result
    }

    // MARK: Copilot

    /// Copilot records a turn when it ends: the last request and the start of the answer. Whether
    /// it is working now is known from the terminal (`busy`), not from its store.
    static func copilot(userMessage: String?, response: String?, busy: Bool) -> AgentActivity? {
        guard userMessage != nil || response != nil else { return nil }
        let task = userMessage.map { clip($0, 90) }
        let said = response.flatMap(firstSentence)
        if busy { return AgentActivity(state: .working, text: task.map { "Working after: " + $0 } ?? "Working", detail: nil, task: task, topic: nil) }
        return AgentActivity(state: .idle, text: "Waiting for you", detail: said, task: task, topic: nil)
    }

    // MARK: Antigravity

    /// Antigravity keeps one summary row per conversation: its title, the first request and whether
    /// a run is active. Like Copilot, it does not say what it is doing; the terminal's output
    /// (`busy`) tells whether it works now.
    static func antigravity(title: String?, preview: String?, status: String, busy: Bool) -> AgentActivity? {
        guard title != nil || preview != nil else { return nil }
        let topic = title.map { clip($0, 60) }
        let task = preview.map { clip($0, 90) }
        if busy || status.hasSuffix("_RUNNING") {
            return AgentActivity(state: .working, text: task.map { "Working on: " + $0 } ?? "Working", detail: nil, task: task, topic: topic)
        }
        return AgentActivity(state: .idle, text: "Waiting for you", detail: nil, task: task, topic: topic)
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
        case "Grep", "Glob", "LS", "search_codebase", "list_files", "grep", "glob":
            return "Searching the project"
        case "run_commands":
            let first = (input["commands"] as? [String])?.first ?? input["command"] as? String
            return program(of: first).map { "Running \($0)" } ?? "Running a command"
        case "read_files":
            let path = ((input["files"] as? [[String: Any]])?.first?["path"] as? String) ?? (input["files"] as? [String])?.first
            return path.map { "Reading \(clip(($0 as NSString).lastPathComponent, 40))" } ?? "Reading files"
        case "edit_file", "write_file", "apply_patch", "editor", "replace_in_file", "write_to_file":
            return file("path", "file_path", "filePath").map { "Editing \($0)" } ?? "Editing files"
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
            return tool.isEmpty ? "Working" : "Using \(tool.replacingOccurrences(of: "_", with: " "))"
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
        String(directory.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// The folder as typed and with symlinks resolved ("/tmp" is "/private/tmp"): the CLI names its
    /// log folder after the path it was started in. (`standardizedFileURL` would drop "/private".)
    private static func spellings(_ directory: URL) -> [URL] {
        let resolved = directory.resolvingSymlinksInPath()
        return resolved.path == directory.path ? [directory] : [directory, resolved]
    }

    static func newestClaudeLog(for directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let folders = spellings(directory).map {
            home.appendingPathComponent(".claude/projects").appendingPathComponent(claudeFolderName(for: $0))
        }
        return newest(in: folders, matching: { _ in true })
    }

    /// The log of the Claude Code running under terminal shell `shellPID`: the CLI writes
    /// `~/.claude/sessions/<pid>.json` ({pid, sessionId, cwd}), so tabs of one folder do not mix up.
    static func claudeLog(shell shellPID: pid_t, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard shellPID > 0 else { return nil }
        let folder = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value, let id = object["sessionId"] as? String,
                  let cwd = object["cwd"] as? String, ProcessTree.isDescendant(pid, of: shellPID) else { continue }
            for spelling in spellings(URL(fileURLWithPath: cwd)) {
                let log = home.appendingPathComponent(".claude/projects").appendingPathComponent(claudeFolderName(for: spelling))
                    .appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: log.path) { return log }
            }
        }
        return nil
    }

    /// The live Cline CLI session of a terminal: its messages file and state. By process when the
    /// row's pid runs under the shell, else the newest live session of the folder.
    static func clineSession(directory: URL, shell shellPID: pid_t,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (messages: URL, status: String)? {
        let db = home.appendingPathComponent(".cline/data/db/sessions.db").path
        let paths = Set(spellings(directory).map(\.path))
        let rows = SQLiteRead.rows(db, "SELECT pid, status, cwd, messages_path FROM sessions WHERE ended_at IS NULL AND is_subagent = 0 ORDER BY updated_at DESC LIMIT 20", columns: 4)
        func make(_ row: [String]) -> (URL, String)? { row[3].isEmpty ? nil : (URL(fileURLWithPath: row[3]), row[1]) }
        if let row = rows.first(where: { Int32($0[0]).map { ProcessTree.isDescendant($0, of: shellPID) } ?? false }) { return make(row) }
        return rows.first { paths.contains(URL(fileURLWithPath: $0[2]).path) && Int32($0[0]).map(ProcessTree.isAlive) ?? false }.flatMap(make)
    }

    /// The last finished Copilot turn in a folder.
    static func copilotTurn(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (user: String?, response: String?)? {
        let db = home.appendingPathComponent(".copilot/session-store.db").path
        for spelling in spellings(directory) {
            let rows = SQLiteRead.rows(db, "SELECT t.user_message, t.assistant_response FROM turns t JOIN sessions s ON s.id = t.session_id WHERE s.cwd = ?1 ORDER BY t.id DESC LIMIT 1",
                                       args: [spelling.path], columns: 2)
            if let row = rows.first { return (row[0].isEmpty ? nil : row[0], row[1].isEmpty ? nil : row[1]) }
        }
        return nil
    }

    /// The newest top-level Antigravity conversation whose workspace is this folder.
    static func antigravityConversation(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (title: String?, preview: String?, status: String)? {
        let db = home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db").path
        for spelling in spellings(directory) {
            var uri = spelling.absoluteString
            if uri.hasSuffix("/") { uri.removeLast() }
            let rows = SQLiteRead.rows(db, "SELECT title, preview, status FROM conversation_summaries WHERE workspace_uris LIKE ?1 AND parent_conversation_id = '' ORDER BY last_modified_time DESC LIMIT 1",
                                       args: ["%\"" + uri + "\"%"], columns: 3)
            if let row = rows.first { return (row[0].isEmpty ? nil : row[0], row[1].isEmpty ? nil : row[1], row[2]) }
        }
        return nil
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
        let paths = Set(spellings(directory).map(\.path))
        return newest(in: folders, matching: { url in
            guard let first = firstLine(of: url), let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String else { return false }
            return paths.contains(URL(fileURLWithPath: cwd).path)
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


enum ProcessTree {
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// `pid` is `ancestor` or runs below it (a few levels: the shell, the CLI's wrapper, the CLI).
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<10 {
            if current == ancestor { return true }
            guard let next = parent(of: current), next > 1, next != current else { return false }
            current = next
        }
        return false
    }
}

/// Read-only SQLite queries returning text columns.
enum SQLiteRead {
    static func rows(_ path: String, _ sql: String, args: [String] = [], columns: Int) -> [[String]] {
        // Read-only, so another program's live database is never changed; when its WAL side files
        // cannot be opened (a database nobody has open), once more as an immutable snapshot.
        for mode in ["mode=ro", "immutable=1"] {
            var db: OpaquePointer?
            let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?" + mode
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); continue }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 300)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            return read(statement, args: args, columns: columns)
        }
        return []
    }

    private static func read(_ statement: OpaquePointer?, args: [String], columns: Int) -> [[String]] {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<columns).map { column in
                sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }
}
