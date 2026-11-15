import Foundation

/// What the assistant is asked in a discussion and how its answer is read. The answer streams as Markdown; the form
/// (text, table, diagram, drawing, chart) is the assistant's choice per question. Foundation only, checked in
/// `tools/tests/discussion-tests.sh`.
enum DiscussionPrompt {
    struct Answer: Equatable {
        /// The Markdown the person reads (the notes block removed).
        var answer: String
        var decisions: [String]
        var openQuestions: [String]
    }

    static let notesFence = "```discussion-notes"

    static let system = """
    You are a thoughtful product and engineering partner in a spoken-style conversation about a project, before any \
    feature exists. The person explores; they do not want code written. Read the project (files, search) before you \
    claim something about it, and say plainly when you did not find it. Do not edit files and do not ask for permission \
    to continue: answer.

    Choose the form of the answer by what was asked, and give only that:
    - A thought, opinion or explanation: plain Markdown text, short.
    - "Show me the architecture / flow / how X connects": one diagram and a few lines of caption, nothing more.
    - Options, pros and cons, comparisons: a Markdown table, then a one-paragraph recommendation.
    - Numbers or trends: a chart.
    Never pad an answer with sections nobody asked for.

    Visuals are fenced code blocks, drawn by the app:
    - ```mermaid  a Mermaid diagram (flowchart, sequence, class, state, ER). Keep node labels short.
    - ```svg  one complete <svg> element for a custom picture (no scripts, no external links).
    - ```chart  a Chart.js configuration as strict JSON (type, data, options); no functions.
    - ```html  a styled static figure (inline CSS only, no scripts) when nothing above fits.
    Put each visual in its own block, with a sentence before or after it.

    The last thing in every answer is a fenced block the app reads and hides:
    ```discussion-notes
    {"decisions": ["..."], "open_questions": ["..."]}
    ```
    "decisions" lists only what the person clearly decided or accepted in this exchange; "open_questions" lists what \
    must still be answered before this could become a feature. Both may be empty.
    """

    static func prompt(discussion: Discussion, question: String, scope: String, language: String) -> String {
        """
        # Discussion: \(discussion.title)

        Scope of this conversation: \(scope)

        \(discussion.context())

        ## New message

        \(question)

        Answer for this project and this scope. Keep decisions and open questions consistent with the lists above: \
        report a decision only when this exchange settled it, and an open question only when it is new or changed.

        \(language)
        """
    }

    /// The answer split into what is shown and what the app keeps. Nil when there is nothing to show.
    static func parse(_ text: String) -> Answer? {
        var shown = text
        var decisions: [String] = [], questions: [String] = []
        if let start = text.range(of: notesFence) {
            shown = String(text[..<start.lowerBound])
            let rest = text[start.upperBound...]
            let json = rest.range(of: "```").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            if let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                func strings(_ value: Any?) -> [String] {
                    Array(((value as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(8))
                }
                decisions = strings(object["decisions"])
                questions = strings(object["open_questions"])
            }
        }
        let answer = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : Answer(answer: answer, decisions: decisions, openQuestions: questions)
    }

    /// The line a live status shows for the assistant's work (what it reads or runs).
    static func status(read path: String) -> String { "Reading \((path as NSString).lastPathComponent)" }
}
