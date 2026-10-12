import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1 }
}
func data(_ json: String) -> Data { json.data(using: .utf8)! }

let now = ISO8601DateFormatter().date(from: "2026-10-12T22:20:30Z")!
let t = "2026-10-12T22:20:14.724Z"

func claude(_ lines: [String]) -> AgentActivity? { AgentActivityParser.claude(lines: lines.map(data), now: now) }

let title = #"{"type":"ai-title","aiTitle":"Sign-in popups in the browser"}"#
let edit = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/MarkView/Models/BrowserSession.swift","old_string":"SECRET"}}]}}"#
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
check(AgentActivityParser.program(of: "cd /tmp && FOO=1 swift test") == "swift", "cd prefix and VAR= skipped")
check(AgentActivityParser.program(of: "cd /tmp && d=/x && mkdir -p y") == "mkdir", "assignment segments skipped")

let done = #"{"type":"assistant","timestamp":"\#(t)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
a = claude([edit, done])
check(a?.state == .idle && a?.text == "Waiting for you", "final text reply -> idle")

let result = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
check(claude([edit, result])?.text == "Thinking" && claude([edit, result])?.state == .working, "tool result -> thinking")

let thinking = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"thinking","thinking":"..."}]}}"#
check(claude([thinking])?.text == "Thinking", "thinking block")

let interrupted = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
check(claude([edit, interrupted])?.state == .idle, "interrupted -> idle")

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
check(codex([call, complete])?.state == .idle, "codex task_complete -> idle")
check(codex([#"{"type":"event_msg","payload":{"type":"token_count"}}"#, call])?.state == .working, "codex ignores token_count")

check(AgentActivityLog.claudeFolderName(for: URL(fileURLWithPath: "/Users/boris/github.com/MarkView")) == "-Users-boris-github-com-MarkView",
      "claude folder name matches the CLI's")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
