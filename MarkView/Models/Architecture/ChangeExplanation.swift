import Foundation

/// What an assistant said about one change of a file: what it does, why it was probably made, and what it affects.
struct HunkExplanation: Equatable {
    let what: String
    let why: String
    let impact: String
}

/// The assistant's reading of all the changes of one file.
struct ChangeExplanation: Equatable {
    let summary: String
    /// By the hunk's `id`.
    let hunks: [Int: HunkExplanation]
}

/// The request for the explanation of one file's changes and the reading of the answer. Pure: the call itself is made by
/// `ProjectChangeReview`, only when the person asks (the file's changes leave MarkView only then).
enum ChangeExplainer {
    /// The most text of changes one request carries; later changes are left out of it and say so.
    static let characterBudget = 60_000

    /// The prompt for `hunks` of the file at `path`, and how many of them fit in it (they go in order).
    static func prompt(path: String, kind: String, hunks: [DiffHunk]) -> (text: String, included: Int) {
        var text = "File: \(path)\nHow it changed: \(kind)\n"
            + "Numbers on the left are line numbers of the new file; a removed line carries its old number and 'old'.\n"
        var included = 0
        for (index, hunk) in hunks.enumerated() {
            var block = "\n=== Change \(index + 1): \(hunk.location)"
            if let section = hunk.section { block += " · in \(section)" }
            block += " ===\n"
            for line in hunk.lines {
                switch line.kind {
                case .context: block += "\(line.newNumber ?? 0)   \(line.text)\n"
                case .added: block += "\(line.newNumber ?? 0) + \(line.text)\n"
                case .removed: block += "\(line.oldNumber ?? 0) old - \(line.text)\n"
                }
            }
            if text.count + block.count > characterBudget && included > 0 { break }
            text += block
            included += 1
        }
        if included < hunks.count {
            text += "\n(\(hunks.count - included) more change\(hunks.count - included == 1 ? "" : "s") are not shown; do not explain them.)\n"
        }
        return (text, included)
    }

    static func systemPrompt(language: String) -> String {
        return """
        You explain the changes made to one file of a project to the person who owns the project and did not see them being made. \
        Each numbered change is a group of added (+) and removed lines with the unchanged lines around them. For every change give: \
        what: what it does, concretely, in one sentence; why: why it was probably made, in one sentence, saying "probably" and \
        "unclear" where the diff does not tell; impact: what it affects — behaviour a user or a caller would see, other parts of the \
        project that depend on the changed code, and the risk — in one or two sentences. You may read other files of the project \
        (read-only) to find what uses the changed code; do not edit anything, and do not guess what you did not see. Explain ONLY the \
        changes shown; never describe the file in general. Also give a summary of the file's whole change in one or two sentences. \
        \(ActionOutputLanguage.explanationLine(language))
        """
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "changes": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "change": ["type": "integer"],
                    "what": ["type": "string"],
                    "why": ["type": "string"],
                    "impact": ["type": "string"],
                ],
                "required": ["change", "what", "why", "impact"],
            ]],
        ],
        "required": ["summary", "changes"],
    ]

    /// The explanation in the assistant's answer, or nil when it explains none of the `hunkCount` changes asked about.
    static func parse(_ object: [String: Any], hunkCount: Int) -> ChangeExplanation? {
        func clean(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var hunks: [Int: HunkExplanation] = [:]
        for raw in object["changes"] as? [[String: Any]] ?? [] {
            // The assistant numbers them from 1, as the prompt does; the hunks' ids start at 0.
            guard let number = raw["change"] as? Int, (1...max(1, hunkCount)).contains(number), number <= hunkCount else { continue }
            let what = clean(raw["what"])
            guard !what.isEmpty else { continue }
            hunks[number - 1] = HunkExplanation(what: what, why: clean(raw["why"]), impact: clean(raw["impact"]))
        }
        guard !hunks.isEmpty else { return nil }
        return ChangeExplanation(summary: clean(object["summary"]), hunks: hunks)
    }
}
