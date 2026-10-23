import Foundation

/// What the assistant is asked in a discussion and how its structured answer is read. Foundation only, checked in
/// `tools/tests/discussion-tests.sh`.
enum DiscussionPrompt {
    struct Answer: Equatable {
        var answer: String
        var followUps: [String]
        var decisions: [String]
        var openQuestions: [String]
    }

    static let system = """
    You are a thoughtful product and engineering partner in a discussion that happens before any feature exists. \
    The person is exploring an idea, not asking for code. Look at the project (read files, search) before you \
    claim something about it, and say plainly when you did not find it. Lay out the real options with their \
    trade-offs and give a recommendation. Do not write code, do not edit files, do not ask for permission to \
    continue: answer.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "answer": ["type": "string", "description": "The answer in Markdown: short sections, options with trade-offs, a recommendation. A table or a Mermaid diagram where it helps."],
            "decisions": ["type": "array", "items": ["type": "string"], "description": "Decisions this exchange settled (only what the person clearly decided or accepted), one sentence each."],
            "open_questions": ["type": "array", "items": ["type": "string"], "description": "Questions that must still be answered before this can become a feature, one sentence each."],
            "follow_ups": ["type": "array", "items": ["type": "string"], "description": "Always two to four questions worth asking next to go deeper."]
        ],
        "required": ["answer", "decisions", "open_questions", "follow_ups"]
    ]

    static func prompt(discussion: Discussion, question: String, language: String) -> String {
        """
        # Discussion: \(discussion.title)

        \(discussion.context())

        ## New question

        \(question)

        Answer it for this project. Keep decisions and open questions consistent with what is listed above: \
        report a decision only when this exchange settled it, and an open question only when it is new or changed.

        \(language)
        """
    }

    /// The answer from the structured result; falls back to the plain text when the model skipped the schema.
    static func parse(structured: Any?, text: String) -> Answer? {
        func strings(_ value: Any?, limit: Int) -> [String] {
            Array(((value as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(limit))
        }
        if let object = structured as? [String: Any],
           let answer = (object["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            return Answer(answer: answer, followUps: strings(object["follow_ups"], limit: 4),
                          decisions: strings(object["decisions"], limit: 8), openQuestions: strings(object["open_questions"], limit: 8))
        }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : Answer(answer: plain, followUps: [], decisions: [], openQuestions: [])
    }
}
