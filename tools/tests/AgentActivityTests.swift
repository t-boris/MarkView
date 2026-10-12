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

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
