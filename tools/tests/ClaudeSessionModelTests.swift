import Foundation

// The model a running Claude Code session uses, read from its log lines.
var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
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

// Titles.
check("title: the model part is replaced", ClaudeSessionModel.title("Claude Code · fable", model: "sonnet") == "Claude Code · sonnet")
check("title: a numbered tab keeps its number", ClaudeSessionModel.title("Claude Code 2 · fable", model: "opus") == "Claude Code 2 · opus")
check("title: a title without a model gets one", ClaudeSessionModel.title("Claude Code", model: "sonnet") == "Claude Code · sonnet")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all claude session model checks passed")
