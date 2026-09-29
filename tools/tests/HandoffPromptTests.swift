// Checks the Implement / Fix with AI prompts (MarkView/Models/HandoffPrompt.swift) for BUG-011:
// the agent is pointed at the records that hold answers, told not to ask them again, and told to
// write new answers back.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let path = "docs/features/csv-export"
for backend in [HandoffPrompt.GoalBackend.claude, .codex, .cline, .copilot] {
    let p = HandoffPrompt.feature(path, backend: backend)
    let who = backend.rawValue
    check("\(who): feature prompt names the folder", p.contains(path))
    check("\(who): feature prompt is one line (pasted and submitted at once)", !p.contains("\n"))
    for record in ["questions/", "decisions/", "findings/", "discussion.md"] {
        check("\(who): feature prompt names \(record)", p.contains(record))
    }
    check("\(who): answers are binding and not asked again", p.contains("binding") && p.contains("do not ask them again"))
    check("\(who): new answers are written back", p.contains("back into the specification"))
    check("\(who): no open invitation to ask anything", !p.contains("ask any question if you are in doubt"))
    let b = HandoffPrompt.bug("docs/bugs/BUG-011-x.md", claude: backend == .claude)
    check("\(who): bug prompt names the report", b.contains("docs/bugs/BUG-011-x.md"))
    check("\(who): bug prompt keeps reproduce / root cause / verify", b.contains("reproduce") && b.contains("root cause") && b.contains("verify"))
    check("\(who): bug clarifications are binding", b.contains("## Clarifications") && b.contains("do not ask them again"))
    check("\(who): bug prompt is one line", !b.contains("\n"))
}
check("claude feature prompt is a /goal", HandoffPrompt.feature(path, backend: .claude).hasPrefix("/goal "))
check("codex feature prompt is a /goal", HandoffPrompt.feature(path, backend: .codex).hasPrefix("/goal "))
check("copilot feature prompt is an autopilot objective", HandoffPrompt.feature(path, backend: .copilot).hasPrefix("/autopilot "))
check("cline feature prompt sets a task goal", HandoffPrompt.feature(path, backend: .cline).hasPrefix("Goal for this Cline task:"))
check("claude bug prompt is a /goal", HandoffPrompt.bug("x.md", claude: true).hasPrefix("/goal fix the bug"))

print(failures == 0 ? "All handoff prompt checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
