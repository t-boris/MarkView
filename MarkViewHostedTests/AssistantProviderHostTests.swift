import Foundation
import MarkViewCore
import os
import XCTest
@testable import MarkView

extension EditorHostTests {
    func testAgentActivityParsing() throws {
        func check(_ ok: Bool, _ name: String, line: UInt = #line) {
            XCTAssertTrue(ok, name, line: line)
        }
        func data(_ json: String) -> Data { json.data(using: .utf8)! }

        let now = ISO8601DateFormatter().date(from: "2026-10-12T22:20:30Z")!
        let t = "2026-10-12T22:20:14.724Z"

        func claude(_ lines: [String]) -> AgentActivity? { AgentActivityParser.claude(lines: lines.map(data), now: now) }

        let title = #"{"type":"ai-title","aiTitle":"Sign-in popups in the browser"}"#
        let edit = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/MarkView/Models/Browser/BrowserSession.swift","old_string":"SECRET"}}]}}"#
        var a = claude([title, edit, #"{"type":"attachment"}"#, #"{"type":"mode"}"#])
        check(a?.state == .working && a?.text == "Editing BrowserSession.swift", "edit tool -> Editing <file>")
        check(a?.topic == "Sign-in popups in the browser", "session title is the topic")
        check(!(a?.text.contains("SECRET") ?? true), "file contents never appear")

        let bash = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"API_KEY=abc123 /usr/bin/xcodebuild -scheme X"}}]}}"#
        a = claude([bash])
        check(a?.text == "Running xcodebuild", "shell command shows the program only")
        check(!(a?.text.contains("abc123") ?? true), "no secret from the command line")
        let bashDescribed = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"x","description":"Build the app"}}]}}"#
        check(claude([bashDescribed])?.text == "Build the app", "shell description is used when present")
        check(AgentActivityParser.program(of: "cd /tmp && FOO=1 swift test") == "swift test", "cd prefix and VAR= skipped, subcommand kept")
        check(AgentActivityParser.program(of: "gh pr merge 5 --merge") == "gh pr merge" && AgentActivityParser.program(of: "git push origin main") == "git push", "gh and git subcommands")
        check(AgentActivityParser.program(of: "git commit -m \"secret-token\"") == "git commit", "arguments are never shown")
        check(AgentActivityParser.program(of: "cd /tmp && d=/x && mkdir -p y") == "mkdir", "assignment segments skipped")

        let done = #"{"type":"assistant","timestamp":"\#(t)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
        a = claude([edit, done])
        check(a?.state == .idle && a?.text == "Waiting for you", "final text reply -> idle")

        let result = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        check(claude([edit, result])?.text == "After: Editing BrowserSession.swift" && claude([edit, result])?.state == .working,
              "after a tool result: what it just did, never a bare Thinking")
        check(claude([user("Do it"), said("Fixing the parser."), edit, result])?.text == "Fixing the parser", "between tools the turn's latest sentence says what the work is")

        let thinking = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"thinking","thinking":"..."}]}}"#
        check(claude([thinking])?.text == "Starting on the request", "thinking with nothing known yet")
        check(claude([thinking])?.text.contains("Thinking") == false, "no bare Thinking")

        let interrupted = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        check(claude([edit, interrupted])?.state == .idle, "interrupted -> idle")

        // /model (BUG-048): the CLI's own command writes user entries after the reply; the agent still waits for the user.
        let caveat = #"{"type":"user","isMeta":true,"timestamp":"\#(t)","message":{"content":"<local-command-caveat>The command below was run directly in Claude Code.</local-command-caveat>"}}"#
        let commandName = #"{"type":"user","timestamp":"\#(t)","message":{"content":"<command-name>/model</command-name>\n<command-message>model</command-message>"}}"#
        let commandOutput = #"{"type":"user","timestamp":"\#(t)","message":{"content":"<local-command-stdout>Set model to `Sonnet 5.5`</local-command-stdout>"}}"#
        check(claude([done, caveat, commandName, commandOutput])?.state == .idle, "after /model the agent is still idle")
        check(claude([done, caveat, commandName, commandOutput])?.text == "Waiting for you", "after /model it still waits for the user")
        check(claude([edit, commandOutput])?.state == .working, "a command output does not end work that was under way")
        check(claude([commandName, commandOutput]) == nil, "only command entries: nothing to report")
        check(claude([done, user("Next task")])?.state == .working, "a real prompt after a reply starts work")

        let side = #"{"type":"assistant","isSidechain":true,"timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/y.swift"}}]}}"#
        check(claude([edit, side])?.text == "Editing BrowserSession.swift", "subagent lines are ignored")

        let late = ISO8601DateFormatter().date(from: "2026-10-12T22:50:00Z")!
        check(AgentActivityParser.claude(lines: [data(edit)], now: late)?.state == .idle, "old tool call -> idle (stale)")
        check(claude([]) == nil && claude([#"{"type":"mode"}"#]) == nil, "no usable lines -> nil")
        check(claude(["not json", edit])?.text == "Editing BrowserSession.swift", "garbage lines skipped")

        func codex(_ lines: [String]) -> AgentActivity? { AgentActivityParser.codex(lines: lines.map(data), now: now) }
        let call = #"{"type":"response_item","timestamp":"\#(t)","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#
        let complete = #"{"type":"event_msg","timestamp":"\#(t)","payload":{"type":"task_complete"}}"#
        check(codex([call])?.text == "Running a command", "codex function call")
        let cu = #"{"type":"event_msg","timestamp":"\#(t)","payload":{"type":"user_message","message":"Add the report"}}"#
        let cm = #"{"type":"response_item","timestamp":"\#(t)","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Writing the report module."}]}}"#
        check(codex([cu, cm, call])?.task == "Add the report" && codex([cu, cm])?.text == "Writing the report module", "codex task and narration")
        check(codex([call, complete])?.state == .idle, "codex task_complete -> idle")
        check(codex([#"{"type":"event_msg","payload":{"type":"token_count"}}"#, call])?.state == .working, "codex ignores token_count")

        check(AgentActivityLog.claudeFolderName(for: URL(fileURLWithPath: "/Users/boris/github.com/MarkView")) == "-Users-boris-github-com-MarkView",
              "claude folder name matches the CLI's")

        // Task, narration and failure
        func user(_ text: String) -> String { #"{"type":"user","timestamp":"\#(t)","message":{"content":"\#(text)"}}"# }
        func said(_ text: String) -> String { #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"# }
        let reminder = #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}"#
        a = claude([user("Fix the sign-in popup in the browser"), said("Now I am building the app to check it. More text."), bash])
        check(a?.task == "Fix the sign-in popup in the browser", "task is the last request")
        check(a?.text == "Now I am building the app to check it" && a?.detail == "Running xcodebuild", "the agent's own sentence leads, the tool is the detail")
        a = claude([user("old request"), said("Old narration."), edit, result, user("New request"), reminder])
        check(a?.task == "New request" && a?.text == "Starting on the request", "a new request resets the narration and the system wrapper is not the task")
        a = claude([user("Do it"), said("Reading the code first."), edit, result, bash])
        check(a?.text == "Running xcodebuild", "narration from before an earlier tool result is stale")
        let failedResult = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"}]}}"#
        a = claude([user("Do it"), bash, failedResult])
        check(a?.state == .failing && a?.text.hasPrefix("Last step failed") == true, "an error result is failing")
        a = claude([user("Do it"), bash, failedResult, done])
        check(a?.state == .idle, "a finished turn is idle even after an error")
        check(AgentActivityParser.firstSentence("## Heading") == nil && AgentActivityParser.firstSentence("Done: all good") == "Done", "sentence rules")

        // Task lists
        let todo = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Parse the log","status":"completed","activeForm":"Parsing the log"},{"content":"Add the banner","status":"in_progress","activeForm":"Adding the banner"},{"content":"Release","status":"pending","activeForm":"Releasing"}]}}]}}"#
        a = claude([user("Do it"), todo, edit])
        check(a?.plan.map(\.status) == [.done, .active, .pending] && a?.plan.first?.title == "Parse the log" && a?.planDone == 1, "TodoWrite list with statuses")
        check(claude([user("Do it"), edit])?.plan.isEmpty == true, "no list, empty plan")
        let todo2 = todo.replacingOccurrences(of: "\"pending\"", with: "\"completed\"")
        check(claude([todo, edit, todo2, edit])?.planDone == 2, "the last TodoWrite wins")
        check(claude([user("a"), todo, done, user("b"), edit])?.plan.count == 3, "the list survives a new request")
        let plan = #"{"type":"response_item","timestamp":"\#(t)","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Write tests\",\"status\":\"completed\"},{\"step\":\"Ship\",\"status\":\"in_progress\"}]}"}}"#
        check(codex([plan, call])?.plan.map(\.title) == ["Write tests", "Ship"] && codex([plan, call])?.planDone == 1, "codex update_plan")

        check(AgentActivityLog.claudeFolderName(for: URL(fileURLWithPath: "/private/tmp/x.y")) == "-private-tmp-x-y", "a /private path keeps its prefix")

        // Cline and Copilot
        let clineMessages = #"{"messages":[{"role":"user","content":[{"type":"text","text":"Remove old branches"}]},{"role":"assistant","content":[{"type":"text","text":"Checking the branches first."},{"type":"tool_use","name":"run_commands","input":{"commands":["cd /p && git branch -vv"]}}]}]}"#
        var c = AgentActivityParser.cline(messagesJSON: Data(clineMessages.utf8), status: "running", now: now)
        check(c?.state == .working && c?.text == "Checking the branches first" && c?.detail == "Running git branch", "cline running: sentence and tool")
        check(c?.task == "Remove old branches", "cline task")
        c = AgentActivityParser.cline(messagesJSON: Data(clineMessages.utf8), status: "idle", now: now)
        check(c?.state == .idle && c?.text == "Waiting for you" && c?.task == "Remove old branches", "cline idle keeps the task")
        check(AgentActivityParser.cline(messagesJSON: Data("garbage".utf8), status: "idle") == nil, "cline garbage")
        check(AgentActivityParser.describe(tool: "read_files", input: ["files": [["path": "/a/b/c.txt"]]]) == "Reading c.txt", "cline read_files")
        let cp = AgentActivityParser.copilot(userMessage: "Open the page", response: "Opened the page. More.", busy: false)
        check(cp?.state == .idle && cp?.task == "Open the page" && cp?.detail == "Opened the page", "copilot idle")
        check(AgentActivityParser.copilot(userMessage: "Open the page", response: nil, busy: true)?.state == .working, "copilot working while its terminal prints")
        check(AgentActivityParser.copilot(userMessage: nil, response: nil, busy: true) == nil, "copilot without data")
        let ag = AgentActivityParser.antigravity(title: "List tabs", preview: "List MarkView Browser Tabs", status: "CASCADE_RUN_STATUS_IDLE", busy: false)
        check(ag?.state == .idle && ag?.topic == "List tabs" && ag?.task == "List MarkView Browser Tabs", "antigravity idle")
        check(AgentActivityParser.antigravity(title: "T", preview: "P", status: "CASCADE_RUN_STATUS_RUNNING", busy: false)?.state == .working, "antigravity running by status")
        check(AgentActivityParser.antigravity(title: "T", preview: "P", status: "CASCADE_RUN_STATUS_IDLE", busy: true)?.state == .working, "antigravity working while its terminal prints")
        check(AgentActivityParser.antigravity(title: nil, preview: nil, status: "", busy: true) == nil, "antigravity without data")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        check(ProcessTree.isDescendant(child.processIdentifier, of: getpid()) && ProcessTree.isDescendant(getpid(), of: getpid()) && !ProcessTree.isDescendant(getpid(), of: 999_999), "process tree")

        let wrapped = #"{"messages":[{"role":"user","content":[{"type":"text","text":"<user_input mode=\"act\"><mode_notice>The user switched.\nSecond line.</mode_notice>\nReview old branches</user_input>"}]}]}"#
        check(AgentActivityParser.cline(messagesJSON: Data(wrapped.utf8), status: "idle")?.task == "Review old branches", "cline request wrapper and notice are removed")

    }

    func testClaudeSessionModelParsing() {
        func check(_ name: String, _ condition: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail, line: line)
        }
        let start = ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z")!
        func stamp(_ seconds: Int, fractional: Bool = true) -> String {
            let date = start.addingTimeInterval(TimeInterval(seconds))
            if fractional {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: date)
            }
            return ISO8601DateFormatter().string(from: date)
        }

        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func reply(_ model: String, at seconds: Int, sidechain: Bool = false) -> Data {
            line(["type": "assistant", "timestamp": stamp(seconds), "isSidechain": sidechain,
                  "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": "ok"]]]])
        }
        func switchCommand(_ shown: String, at seconds: Int, asParts: Bool = false) -> Data {
            let text = "<local-command-stdout>Set model to `\(shown)` and saved as your default for new sessions</local-command-stdout>"
            let content: Any = asParts ? [["type": "text", "text": text]] : text
            return line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": content]])
        }
        func user(_ text: String, at seconds: Int) -> Data {
            line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": text]])
        }

        // Names and families.
        check("an id names its family", ClaudeSessionModel.family(of: "claude-sonnet-5-5") == "sonnet")
        check("a display name names its family", ClaudeSessionModel.family(of: "Fable 5.1") == "fable")
        check("opus", ClaudeSessionModel.family(of: "claude-opus-5-5") == "opus")
        check("haiku", ClaudeSessionModel.family(of: "Claude Haiku 5.5") == "haiku")
        check("another vendor names none", ClaudeSessionModel.family(of: "gpt-5") == nil)

        // The reply of the session.
        check("the newest reply wins",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), reply("claude-sonnet-5-5", at: 5)])?.model == "sonnet")
        check("an id without a known family is kept as logged",
              ClaudeSessionModel.reading(lines: [reply("claude-nova-6-0", at: 1)])?.model == "claude-nova-6-0")
        check("a subagent's reply is not the session's model",
              ClaudeSessionModel.reading(lines: [reply("claude-sonnet-5-5", at: 1), reply("claude-haiku-5-5", at: 9, sidechain: true)])?.model == "sonnet")
        check("a placeholder reply is skipped",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("<synthetic>", at: 9)])?.model == "opus")
        check("the reading carries the time of the line",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 7)])?.date == start.addingTimeInterval(7))

        // /model confirms before the next reply.
        check("a /model confirmation after a reply wins",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), switchCommand("Sonnet 5.5", at: 4)])?.model == "sonnet")
        check("a reply after the confirmation wins",
              ClaudeSessionModel.reading(lines: [switchCommand("Sonnet 5.5", at: 1), reply("claude-opus-5-5", at: 4)])?.model == "opus")
        check("a confirmation whose content is a list of parts",
              ClaudeSessionModel.reading(lines: [switchCommand("Opus 5.5", at: 2, asParts: true)])?.model == "opus")
        check("a confirmation without a family is ignored",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), switchCommand("Default (recommended)", at: 4)])?.model == "fable")
        check("ordinary user text that mentions a model is not a switch",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), user("please use sonnet for this", at: 4)])?.model == "fable")

        // Only what happened since the agent started counts (a continued session carries old replies).
        check("lines older than since are ignored",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("claude-sonnet-5-5", at: 3)],
                                         since: start.addingTimeInterval(10)) == nil)
        check("a line at since counts",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 10)], since: start.addingTimeInterval(10))?.model == "opus")
        check("old lines do not hide newer ones",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("claude-sonnet-5-5", at: 20)],
                                         since: start.addingTimeInterval(10))?.model == "sonnet")

        // Odd input.
        check("no lines, no reading", ClaudeSessionModel.reading(lines: []) == nil)
        check("garbage and blank lines are skipped",
              ClaudeSessionModel.reading(lines: [Data("not json".utf8), Data(), reply("claude-haiku-5-5", at: 1), Data("{".utf8)])?.model == "haiku")
        check("a line without a time is skipped",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1),
                                                 line(["type": "assistant", "message": ["model": "claude-haiku-5-5"]])])?.model == "opus")
        check("a time without fractions is read",
              ClaudeSessionModel.reading(lines: [line(["type": "assistant", "timestamp": stamp(3, fractional: false),
                                                       "message": ["model": "claude-opus-5-5"]])])?.date == start.addingTimeInterval(3))

        // Concurrent readers share the two timestamp parsers without changing their results.
        let concurrentLines = [reply("claude-opus-5-5", at: 1), line(["type": "assistant", "timestamp": stamp(3, fractional: false),
                                                                       "message": ["model": "claude-sonnet-5-5"]])]
        let expectedConcurrentDate = start.addingTimeInterval(3)
        let concurrentErrors = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let result = ClaudeSessionModel.reading(lines: concurrentLines)
            if result?.model != "sonnet" || result?.date != expectedConcurrentDate { concurrentErrors.withLock { $0 += 1 } }
        }
        check("concurrent readers parse fractional and plain timestamps consistently", concurrentErrors.withLock { $0 } == 0)

        // Titles.
        check("title: the model part is replaced", ClaudeSessionModel.title("Claude Code · fable", model: "sonnet") == "Claude Code · sonnet")
        check("title: a numbered tab keeps its number", ClaudeSessionModel.title("Claude Code 2 · fable", model: "opus") == "Claude Code 2 · opus")
        check("title: a title without a model gets one", ClaudeSessionModel.title("Claude Code", model: "sonnet") == "Claude Code · sonnet")
    }
}

extension EditorHostTests {
    func testCodexLaunchSchemaFiles() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("codex-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { chmod(scratch.path, 0o755); try? FileManager.default.removeItem(at: scratch) }

        func request(schema: [String: Any]?) -> CompletionLaunchRequest {
            CompletionLaunchRequest(prompt: "Answer.", systemPrompt: nil, jsonSchema: schema, readableFolder: nil, extraReadableFolders: [],
                                    linkedFolders: { [] }, allowWeb: false, images: [], effort: nil, model: nil, workDir: scratch,
                                    scratchDirectory: { scratch })
        }
        func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() }

        let schema: [String: Any] = ["type": "object", "properties": ["answer": ["type": "string"], "tags": ["type": "array", "items": ["type": "string"]]]]
        let provider = CodexProvider()

        // No schema, no file.
        let plain = try provider.launch(request(schema: nil))
        check(plain.schemaFile == nil && !plain.arguments.contains("--output-schema") && listing().isEmpty, "a launch without a schema writes nothing")

        // A schema: saved whole in the scratch folder, strict as Codex needs it, and named in the arguments.
        let first = try provider.launch(request(schema: schema))
        let file = first.schemaFile
        check(file?.deletingLastPathComponent().standardizedFileURL.path == scratch.standardizedFileURL.path && file?.lastPathComponent.hasPrefix("schema-") == true
              && file?.pathExtension == "json", "the schema file is in the run's scratch folder")
        if let index = first.arguments.firstIndex(of: "--output-schema") {
            check(first.arguments.indices.contains(index + 1) && first.arguments[index + 1] == file?.path, "the CLI is told to read that very file")
        } else { check(false, "the CLI is told to read that very file") }
        let saved = file.flatMap { try? Data(contentsOf: $0) }
        let parsed = saved.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(parsed != nil && (parsed?["additionalProperties"] as? Bool) == false && (parsed?["required"] as? [String]) == ["answer", "tags"],
              "the file holds the whole strict schema (closed object, every property required)")
        let expected = try CompletionJSON.string(CodexProvider.strictSchema(schema))
        check(saved.map { String(decoding: $0, as: UTF8.self) } == expected, "byte for byte what the schema serialises to")
        check(file.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o644 } == true, "it is an ordinary file, readable by the CLI")
        check(listing().count == 1, "and nothing else is in the folder (no temporary file)")

        // Every launch has a file of its own.
        let second = try provider.launch(request(schema: ["type": "object", "properties": ["x": ["type": "string"]]]))
        check(second.schemaFile != nil && second.schemaFile != file && listing().count == 2 && (file.flatMap { try? Data(contentsOf: $0) }) == saved,
              "a second launch has its own file and leaves the first as it was")

        // A scratch folder that refuses the file: the launch fails, with no partial schema, and the earlier files are as they were.
        let before = listing()
        chmod(scratch.path, 0o555)
        var refused = false
        do { _ = try provider.launch(request(schema: schema)) } catch { refused = true }
        chmod(scratch.path, 0o755)
        check(refused, "a scratch folder that refuses the schema fails the launch")
        check(listing() == before && (file.flatMap { try? Data(contentsOf: $0) }) == saved, "and adds no partial file, and the earlier schema keeps its bytes")
    }
}
