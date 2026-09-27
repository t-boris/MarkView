import Foundation

// Batch "Fix with AI" (issue #31, docs/features/batch-fix-with-ai-for-multiple-bugs): the basket of
// bug reports collected in the Issues panel, the one prompt that fixes them on one branch, and the
// "Suggest similar" request. Foundation only, so tools/tests/bug-basket-tests.sh compiles it on its own.

/// A bug report as the basket needs it. `path` is workspace-relative and is the identity: report
/// ids are not unique (two files can both be BUG-004).
struct BasketBug: Equatable {
    var path: String
    var key: String
    var title: String
    /// As written; a report without a status reads "open".
    var status: String
    /// Front matter `feature:` when the report names one; bugs otherwise belong to no feature.
    var feature: String = ""
}

/// The selection itself: paths in the order they were added. In memory, one per window (DEC-008).
struct BugBasket: Equatable {
    private(set) var paths: [String] = []

    /// A bug can go to the basket only while it is open (DEC-010).
    static func canAdd(_ bug: BasketBug) -> Bool { IssueStatus.normalize(bug.status) == "open" }

    /// Already being fixed: stays in the basket, marked, left out of the batch (DEC-008).
    static func isBeingFixed(_ bug: BasketBug) -> Bool { IssueStatus.inProgress.contains(IssueStatus.normalize(bug.status)) }

    var isEmpty: Bool { paths.isEmpty }
    var count: Int { paths.count }

    func contains(_ path: String) -> Bool { paths.contains(path) }

    mutating func add(_ path: String) { if !contains(path) { paths.append(path) } }
    mutating func remove(_ path: String) { paths.removeAll { $0 == path } }
    mutating func clear() { paths = [] }

    /// The basket against the current reports: deleted ones and ones that are neither open nor
    /// being fixed are dropped. Returns how many were dropped.
    @discardableResult
    mutating func reconcile(with bugs: [BasketBug]) -> Int {
        let byPath = Dictionary(bugs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let before = paths.count
        paths.removeAll { path in
            guard let bug = byPath[path] else { return true }
            return !Self.canAdd(bug) && !Self.isBeingFixed(bug)
        }
        return before - paths.count
    }

    /// The basket's reports in basket order (unknown paths skipped).
    func items(in bugs: [BasketBug]) -> [BasketBug] {
        let byPath = Dictionary(bugs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return paths.compactMap { byPath[$0] }
    }

    /// What a batch would fix now: the open ones.
    func eligible(in bugs: [BasketBug]) -> [BasketBug] { items(in: bugs).filter(Self.canAdd) }

    /// A batch needs at least two bugs; one goes through the bug's own Fix with AI (DEC-011).
    static let minimumBatch = 2
}

/// The one prompt of a batch (REQ-002…REQ-005). The app runs no git itself (DEC-002): the AI
/// makes the branch, one commit per fixed bug, and writes each outcome into the report (DEC-006).
enum BatchFixPrompt {
    /// Claude Code gets it as a one-line `/goal`; the other assistants as a numbered instruction.
    static func make(_ bugs: [BasketBug], claude: Bool) -> String {
        let list = bugs.enumerated().map { index, bug in
            var line = "\(index + 1). \(bug.key) \"\(bug.title)\" — \(bug.path)"
            if !bug.feature.isEmpty { line += " (feature \(bug.feature))" }
            return line
        }
        let paths = bugs.map(\.path).joined(separator: ", ")
        let steps = [
            "Read every report first. Paths are relative to the workspace root.",
            "Before changing anything, run git status and choose a short descriptive branch name for this batch (e.g. fix/<topic>). "
                + "The status edits to the reports listed above (their status is now fixing) and MarkView's own .dde/ folder are expected "
                + "and do not count as uncommitted changes; leave them out of every commit. "
                + "If there are any other uncommitted changes, or a branch with the planned name already exists, describe what you found, "
                + "ask me how to proceed and change nothing until I answer.",
            "Create and check out the branch from the current commit, and tell me its name.",
            "For each bug in turn: reproduce it, find the root cause, fix it and verify the fix.",
            "For each bug you fixed, make exactly one commit on that branch with its fix; the commit message starts with the bug id. "
                + "Do not commit anything for a bug you could not fix.",
            "Only after a bug's commit exists, update its report's front matter: status: fixed, branch: <branch name>. "
                + "For a bug you could not fix, set status: open and append a section \"## AI fix attempt\" to the report "
                + "with the date, the branch and the reason.",
            "Do not change the status of any bug report that is not in this list.",
            "Finish with a short outcome per bug: fixed (with the commit) or not fixed (with the reason).",
        ]
        if claude {
            let items = bugs.map { bug in "\(bug.key) \"\(bug.title)\" (\(bug.path)\(bug.feature.isEmpty ? "" : ", feature \(bug.feature)"))" }
            return "/goal fix this batch of \(bugs.count) bugs on one new git branch: " + items.joined(separator: "; ") + ". "
                + steps.joined(separator: " ") + " Ask any question if you are in doubt."
        }
        return "Fix this batch of \(bugs.count) bug reports on one new git branch (\(paths)):\n"
            + list.joined(separator: "\n") + "\n\nSteps:\n"
            + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n\nAsk any question if you are in doubt before changing code."
    }
}

/// "Suggest similar" (REQ-006): which open bugs look related to the basket. The answer only
/// proposes; nothing is added without the user's click.
enum SimilarBugs {
    struct Candidate: Equatable {
        var bug: BasketBug
        /// The start of the report's body.
        var excerpt: String
    }

    struct Suggestion: Equatable {
        var path: String
        var reason: String
    }

    static let limit = 5

    /// Open bugs that are not in the basket.
    static func candidates(_ bugs: [BasketBug], basket: BugBasket) -> [BasketBug] {
        bugs.filter { BugBasket.canAdd($0) && !basket.contains($0.path) }
    }

    static func prompt(basket: [Candidate], candidates: [Candidate]) -> String {
        func block(_ item: Candidate) -> String {
            "- path: \(item.bug.path)\n  id: \(item.bug.key)\n  title: \(item.bug.title)\n  report: "
                + item.excerpt.replacingOccurrences(of: "\n", with: " ")
        }
        return """
        The user is collecting bug reports into a basket, to fix them together in one run on one branch. \
        Suggest up to \(limit) other open bugs from the candidates that are similar or related to the basket: \
        the same symptom, the same component or code, or a shared root cause. Do not suggest unrelated bugs \
        just to fill the list; an empty list is a valid answer. Use each candidate's path exactly as given. \
        `reason` is one short sentence on what it shares with the basket.

        ## Basket
        \(basket.map(block).joined(separator: "\n"))

        ## Candidates
        \(candidates.map(block).joined(separator: "\n"))
        """
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "suggestions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["path": ["type": "string"], "reason": ["type": "string"]],
                    "required": ["path", "reason"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["suggestions"],
        "additionalProperties": false,
    ]

    /// The answer, kept to known candidates, without repeats, at most `limit`.
    static func parse(_ answer: [String: Any], candidates: [BasketBug]) -> [Suggestion] {
        let known = Set(candidates.map(\.path))
        var seen = Set<String>()
        var out: [Suggestion] = []
        for item in answer["suggestions"] as? [[String: Any]] ?? [] {
            let path = (item["path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard known.contains(path), seen.insert(path).inserted else { continue }
            out.append(Suggestion(path: path, reason: (item["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            if out.count == limit { break }
        }
        return out
    }
}
