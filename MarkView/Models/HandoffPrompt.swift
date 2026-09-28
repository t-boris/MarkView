import Foundation

// What "Implement with AI" and "Fix with AI" paste into the assistant's terminal (BUG-011). The
// agent is told which records already hold the owner's answers, that they are binding, and to
// write every new answer back, so no later run has to ask again. Foundation only, so
// tools/tests/handoff-prompt-tests.sh compiles it on its own.

enum HandoffPrompt {
    /// Where a feature keeps its answers.
    static let featureRecords = "Recorded answers are binding: answered questions (questions/, their answer), "
        + "accepted decisions (decisions/), resolved findings (findings/, their Resolution) and discussion.md. "
        + "Apply them and do not ask them again. Ask only about what the specification leaves open or where it "
        + "contradicts itself or the code, and name the records you checked. Write every new answer from me back "
        + "into the specification (the question's answer or a new decision) before you finish."

    /// Where a bug report keeps its answers.
    static let bugRecords = "The answered questions in the report's front matter (questions, their answer) and its "
        + "## Clarifications are binding: use them and do not ask them again. Ask only about what the report leaves open, "
        + "and add every new answer from me to its ## Clarifications before you finish."

    /// Implement with AI: Claude Code gets a one-line `/goal`, the other assistants an instruction.
    static func feature(_ path: String, claude: Bool) -> String {
        claude
            ? "/goal implement \(path) — read the whole folder first. \(featureRecords)"
            : "Implement what \(path) specifies. Read the whole folder first. \(featureRecords)"
    }

    /// Fix with AI for one bug report.
    static func bug(_ path: String, claude: Bool) -> String {
        claude
            ? "/goal fix the bug described in \(path): reproduce it first, find the root cause, fix it and verify the fix. \(bugRecords)"
            : "Fix the bug described in \(path). Read it first, reproduce the problem, find the root cause, fix it and verify the fix. \(bugRecords)"
    }
}
