import Foundation

// The values of the Pull request X-Ray (`ChangeReviewStore`): what the page draws and what is saved with a review.
// The shapes are the page's JSON contract and the stored review's (`SemanticDatabase.loadArchitectureReview`).

struct PRSource: Codable, Hashable {
    /// local | cmp:<ref> | rev:<ref> | at:<commit> (`HistoricalBaseline`) | gh:<number>
    let id: String
    let title: String
}

struct PRFileChange: Codable {
    var path: String
    var additions: Int
    var deletions: Int
    /// New-file line ranges touched by the change: [[start, end]].
    var ranges: [[Int]]
    /// Filled by the AI review: ok | concern | bug.
    var verdict: String?
    var risk: String?
    var summary: String?
    var findings: [PRFinding]?
    /// What changed inside the file, drawn under it in the PR X-Ray (sent to the page;
    /// filled from the X-Ray contents, then from the AI's explanation).
    var changes: [PRChangeNote]?
    /// The AI's one-paragraph reading of this file's change.
    var changeSummary: String?
    var explaining: Bool?
    /// The change removes the file (it opens as it was before).
    var deleted: Bool?
}

/// One change inside a changed file.
struct PRChangeNote: Codable {
    /// The file's logical part it falls in (X-Ray contents), when known.
    var part: String?
    var title: String
    /// New-file lines it covers (a removal: the line where the text was).
    var start: Int
    var end: Int
    /// added | changed | removed | moved (AI)
    var kind: String?
    /// What the change does and why (AI).
    var why: String?
}

struct PRFinding: Codable {
    var line: Int
    /// info | warning | bug
    var severity: String
    var message: String
    /// The AI's explanation of the finding (streamed), and whether it is being written.
    var explanation: String?
    var explaining: Bool?
    /// Hidden by the reviewer as not a real problem.
    var dismissed: Bool?
    /// Posted to the pull request as a line comment.
    var commented: Bool?
    /// Link of the issue created from it.
    var issueURL: String?
}

/// The pull request on GitHub behind a "gh:<n>" change: its state, checks and review.
struct PRInfo: Codable {
    var number: Int
    var url: String
    var state: String
    var isDraft: Bool
    var author: String
    var head: String
    var base: String
    /// APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ""
    var reviewDecision: String
    var checksPassed: Int
    var checksFailed: Int
    var checksTotal: Int
    /// MERGEABLE | CONFLICTING | UNKNOWN
    var mergeable: String
    var headOid: String
    /// An action on the pull request is running (approve, merge…).
    var busy: Bool?
    /// Result of the last action, shown under the header, and whether it succeeded.
    var message: String?
    var ok: Bool?
}

/// A link between project files the change adds or removes.
struct PRDependency: Codable {
    var source: String
    var target: String
    /// added | removed
    var change: String
}

/// The AI's architectural reading of a change.
struct PRAnalysis: Codable {
    struct Impact: Codable { var component: String; var risk: String; var note: String }
    struct Check: Codable { var path: String; var line: Int; var note: String }
    var summary: String
    /// approve | attention | risky
    var verdict: String
    var impact: [Impact]
    var risks: [String]
    var checks: [Check]
}

struct PROverlay: Codable {
    var source: PRSource
    var files: [PRFileChange]
    var reviewed: Bool
    var reviewSummary: String?
    var dependencies: [PRDependency] = []
    var analysis: PRAnalysis?
    var analyzing: Bool?
    /// The diff of the file selected in the PR X-Ray.
    var fileDiff: PRFileDiff?
    /// Questions asked about this change and the AI's answers (newest last).
    var chat: [PRChat] = []
    /// The code changed after the review and analysis shown (reloaded automatically).
    var reviewOutdated: Bool?
    /// The pull request on GitHub (nil for local changes).
    var info: PRInfo?
}

struct PRFileDiff: Codable {
    var path: String
    var text: String
}

struct PRChat: Codable {
    var question: String
    /// The file the question is about, or nil for the whole change.
    var path: String?
    var answer: String
    var pending: Bool
}

/// The date-first baseline picker of the PR X-Ray: the commits of the calendar day the person chose
/// (`HistoricalBaseline`). The page asks for a day and draws what is here; nil while no day is asked for.
struct HistoryPicker: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var sha: String
        var short: String
        var subject: String
        var author: String
        /// The committer timestamp, in seconds: the page writes the time in the user's own zone.
        var time: Double
    }
    /// The day as the page sent it, `YYYY-MM-DD`.
    var day: String
    /// loading | ready (maybe no commit that day) | unavailable (the history could not be read)
    var state: String
    var commits: [Entry]
}

/// A pull request fetched into the local repository: its head commit and where it
/// branched from its base. Nothing is checked out; the working copy stays as it is.
struct PRCheckout: Sendable {
    let number: String
    let head: String
    let mergeBase: String
}

/// The loaded change as the code viewer's "Pull request" lens shows it for one file:
/// added lines, where lines were removed, and each change with its explanation and
/// its own lines of the diff. Nil when the file is not part of the change.
struct PRFileNotes: Encodable {
    struct Change: Encodable {
        var title: String
        var start: Int
        var end: Int
        var kind: String?
        var why: String?
        /// The change's lines of the diff ("+…", "-…").
        var diff: [String]
    }
    var title: String
    var summary: String?
    var explaining: Bool
    var explained: Bool
    var additions: Int
    var deletions: Int
    var changes: [Change]
    /// Added new-file line ranges.
    var added: [[Int]]
    /// [line, count]: where lines were removed.
    var removed: [[Int]]
    /// Opened from the PR X-Ray: show this lens.
    var focus: Bool
    /// The file differs from the change's version: lines were matched by content.
    var remapped: Bool
    /// Identifies the diff (a new one needs a new explanation).
    var diffKey: String
    var reviewOutdated: Bool
    /// The change removes the file: all of its lines (shown as it was).
    var deletedLines: Int?
}

extension PROverlay {
    /// The review's findings and the analysis's checks as a task list, to paste into the AI terminal or the clipboard. Nil when
    /// there is nothing to do.
    func tasksText() -> String? {
        var bugs: [String] = [], warnings: [String] = [], notes: [String] = []
        for file in files {
            for finding in file.findings ?? [] where finding.dismissed != true {
                let line = "- [ ] \(file.path)\(finding.line > 0 ? ":\(finding.line)" : "") — \(finding.message)"
                switch finding.severity {
                case "bug": bugs.append(line)
                case "warning": warnings.append(line)
                default: notes.append(line)
                }
            }
            if (file.findings ?? []).isEmpty, let verdict = file.verdict, verdict != "ok", let summary = file.summary {
                let line = "- [ ] \(file.path) — \(summary)"
                if verdict == "bug" { bugs.append(line) } else { warnings.append(line) }
            }
        }
        var checks: [String] = []
        if let analysis {
            checks = analysis.checks.map { "- [ ] \($0.path)\($0.line > 0 ? ":\($0.line)" : "") — \($0.note)" }
                + analysis.risks.map { "- [ ] Risk: \($0)" }
        }
        let sections = [("Bugs", bugs), ("Concerns", warnings), ("Notes", notes), ("To check", checks)].filter { !$0.1.isEmpty }
        guard !sections.isEmpty else { return nil }
        return "Tasks from the review of \(source.title). Check each one; fix it, or say why it is not a real problem.\n\n"
            + sections.map { "## \($0.0)\n" + $0.1.joined(separator: "\n") }.joined(separator: "\n\n")
    }
}
