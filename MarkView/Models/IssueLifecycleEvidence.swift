import Foundation

// Delivery evidence of an issue (issue-lifecycle-management, plan I-4, DEC-007, DEC-012): which merged work, passed checks and
// published release show that the implementation of a feature or a bug is complete. This file holds the facts as the collector
// reads them and the rules that turn them into one verdict. Missing, unavailable, stale or ambiguously associated evidence is
// never a pass (REQ-005 criterion 1). Foundation only: tools/tests/issue-lifecycle-tests.sh compiles it on its own; the
// collector that reads git and GitHub is IssueEvidenceCollector.swift.

enum EvidenceSourceState: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// A place the evidence is read from ("git", "GitHub pull requests", "GitHub checks", "GitHub releases").
struct EvidenceSource: Equatable, Sendable {
    var name: String
    var state: EvidenceSourceState

    static func available(_ name: String) -> EvidenceSource { EvidenceSource(name: name, state: .available) }
    static func unavailable(_ name: String, _ reason: String) -> EvidenceSource { EvidenceSource(name: name, state: .unavailable(reason)) }
}

/// A pull request or a commit made straight on the default branch.
enum WorkRef: Hashable, Codable, Sendable {
    case pullRequest(Int)
    case commit(String)

    var label: String {
        switch self {
        case .pullRequest(let number): return "PR #\(number)"
        case .commit(let sha): return "commit \(sha.prefix(7))"
        }
    }
}

/// What the workflow runs of a head commit say. The sha is the commit the answer is about.
enum CheckState: Equatable, Sendable {
    case passed(sha: String)
    case failed(sha: String)
    case pending(sha: String)
    /// The commit has no workflow run at all.
    case noRuns(sha: String)
    case unknown(String)
}

enum WorkAssociation: Equatable, Sendable {
    /// The work names the issue itself (its folder, its key, or an issue number only it links).
    case explicit
    /// The only link is something that more than one issue claims (a shared GitHub issue number).
    case ambiguous(String)
}

struct WorkUnit: Equatable, Sendable {
    var ref: WorkRef
    /// The commit the checks are judged on: the head of a pull request, the commit itself otherwise.
    var headSHA: String
    /// The commit on the default branch containing this work; it may differ from the PR head after a squash merge.
    var landedSHA: String?
    /// When it entered the default branch; nil while it has not.
    var mergedAt: Date?
    /// A pull request closed without merging counts for nothing.
    var closedUnmerged: Bool
    /// nil: the list of changed files could not be read.
    var changedPaths: [String]?
    var checks: CheckState
    var association: WorkAssociation

    init(ref: WorkRef, headSHA: String, mergedAt: Date?, closedUnmerged: Bool = false, changedPaths: [String]?,
         checks: CheckState, association: WorkAssociation = .explicit, landedSHA: String? = nil) {
        self.ref = ref
        self.headSHA = headSHA
        self.landedSHA = landedSHA
        self.mergedAt = mergedAt
        self.closedUnmerged = closedUnmerged
        self.changedPaths = changedPaths
        self.checks = checks
        self.association = association
    }

    /// A change of documentation only needs neither a release nor counts as implementation work (DEC-012).
    var isDocumentationOnly: Bool {
        guard let paths = changedPaths, !paths.isEmpty else { return false }
        return paths.allSatisfy(DocumentationPaths.isDocumentation)
    }
}

enum DocumentationPaths {
    /// docs/, tasks/ and Markdown files anywhere (README.md, CLAUDE.md …).
    static func isDocumentation(_ path: String) -> Bool {
        let value = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        return value.hasPrefix("docs/") || value.hasPrefix("tasks/") || value.lowercased().hasSuffix(".md")
    }
}

/// Whether the release a unit needs has been published.
enum ReleaseState: Equatable, Sendable {
    case delivered(tag: String)
    /// Checked: no published release contains the unit yet.
    case pending
    case unknown(String)
}

struct DeliveryInput: Sendable {
    var sources: [EvidenceSource]
    var work: [WorkUnit]
    /// The project's definition of done requires the deploy item (DEC-012).
    var releaseRequired: Bool
    var releases: [WorkRef: ReleaseState]
    /// When the issue was last started or reopened: implementation work for a started or reopened issue is work merged
    /// after that time, so that a reopened issue does not complete again on the work that was already there.
    var since: Date?

    init(sources: [EvidenceSource], work: [WorkUnit], releaseRequired: Bool, releases: [WorkRef: ReleaseState] = [:], since: Date? = nil) {
        self.sources = sources
        self.work = work
        self.releaseRequired = releaseRequired
        self.releases = releases
        self.since = since
    }
}

enum DeliveryEvaluator {
    /// complete only when there is merged implementation work, all of it merged with passing checks of its current head
    /// and, when the project requires it, a published release containing each unit. A definite gap makes the verdict
    /// incomplete; a gap in what could be read makes it unknown; neither completes anything.
    static func evaluate(_ input: DeliveryInput) -> DeliveryVerdict {
        var missing: [String] = []
        var unknown: [String] = []

        for source in input.sources {
            if case .unavailable(let reason) = source.state { unknown.append("\(source.name) could not be read: \(reason)") }
        }

        let units = input.work.filter { !$0.closedUnmerged }
        for unit in units {
            if case .ambiguous(let reason) = unit.association {
                unknown.append("\(unit.ref.label) cannot be tied to this issue alone (\(reason))")
            }
        }
        let ambiguous = Set(units.filter { if case .ambiguous = $0.association { return true } else { return false } }.map(\.ref))
        let code = units.filter { !$0.isDocumentationOnly && !ambiguous.contains($0.ref) }

        for unit in code {
            if unit.changedPaths == nil { unknown.append("the changed files of \(unit.ref.label) could not be read") }
            guard unit.mergedAt != nil else {
                missing.append("\(unit.ref.label) is not merged into the default branch")
                continue
            }
            switch unit.checks {
            case .passed(let sha):
                if sha != unit.headSHA { missing.append("\(unit.ref.label): the checks that passed are for an older commit, not its head") }
            case .failed:
                missing.append("\(unit.ref.label): a check failed")
            case .pending:
                missing.append("\(unit.ref.label): checks are still running")
            case .noRuns:
                unknown.append("\(unit.ref.label) has no workflow run, so its checks are unknown")
            case .unknown(let reason):
                unknown.append("\(unit.ref.label): checks could not be read (\(reason))")
            }
            if input.releaseRequired {
                switch input.releases[unit.ref] ?? .unknown("release state was not collected") {
                case .delivered: break
                case .pending: missing.append("\(unit.ref.label) is not in a published release yet")
                case .unknown(let reason): unknown.append("the release of \(unit.ref.label) could not be determined (\(reason))")
                }
            }
        }

        let merged = code.filter { $0.mergedAt != nil }
        if merged.isEmpty {
            missing.append("no merged implementation work was found (documentation-only changes, unmerged and closed pull requests do not count)")
        } else if let since = input.since, !merged.contains(where: { ($0.mergedAt ?? .distantPast) >= since }) {
            missing.append("no implementation work was merged since the issue was started or reopened")
        }

        if !missing.isEmpty { return .incomplete(missing: missing + unknown) }
        if !unknown.isEmpty { return .unknown(reasons: unknown) }
        return .complete(summary: merged.map { summary($0, input) })
    }

    private static func summary(_ unit: WorkUnit, _ input: DeliveryInput) -> String {
        var line = "\(unit.ref.label) merged, checks passed"
        if input.releaseRequired, case .delivered(let tag)? = input.releases[unit.ref] { line += ", in release \(tag)" }
        return line
    }
}

// MARK: - Association

/// How a commit message or a pull request text names an issue (DEC-012).
enum WorkAssociationRules {
    /// A feature: its folder `docs/features/<slug>` as a whole path segment, a `Feature: <slug>` trailer line (what the hand-off
    /// asks the agent to write), or `#n` of one of its linked GitHub issues.
    static func mentionsFeature(_ text: String, slug: String, issues: Set<Int>) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: slug)
        let folder = NSRegularExpression.escapedPattern(for: "docs/features/") + escaped + "(?![A-Za-z0-9_-])"
        let trailer = "(?m)^[ \\t]*Feature:[ \\t]*" + escaped + "[ \\t]*$"
        if text.range(of: folder, options: .regularExpression) != nil { return true }
        if text.range(of: trailer, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return mentionsIssueNumber(text, in: issues)
    }

    /// A bug: its key (`BUG-065`, not `BUG-0651`), or `#n` of one of its linked GitHub issues.
    static func mentionsBug(_ text: String, key: String, issues: Set<Int>) -> Bool {
        let pattern = "(?<![A-Za-z0-9-])" + NSRegularExpression.escapedPattern(for: key) + "(?![A-Za-z0-9])"
        if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return mentionsIssueNumber(text, in: issues)
    }

    /// `#12` as a whole token, not `a#12`, `&#12;` or `#123`.
    static func mentionsIssueNumber(_ text: String, in issues: Set<Int>) -> Bool {
        guard !issues.isEmpty, let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9&])#(\d+)\b"#) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).contains { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }.map(issues.contains) ?? false
        }
    }

    /// The GitHub issue numbers of an issue that no other issue also links: a commit that names only a shared number cannot be
    /// attributed to one of them.
    static func exclusiveNumbers(_ numbers: Set<Int>, claimedByOthers: Set<Int>) -> (exclusive: Set<Int>, shared: Set<Int>) {
        (numbers.subtracting(claimedByOthers), numbers.intersection(claimedByOthers))
    }
}

/// `git log --name-only` output: a record per commit with its files, newest first.
enum GitWorkLog {
    struct Commit: Equatable, Sendable {
        var sha: String
        var date: Date
        var message: String
        var paths: [String]
    }

    static let separator = "\u{1e}"

    /// Arguments for `git`; the output is read by `commits(from:)`.
    static func arguments(ref: String, limit: Int = 400) -> [String] {
        ["log", ref, "-n", String(limit), "--name-only", "--format=\(separator)%H%x1f%cI%x1f%B%x1f"]
    }

    static func commits(from output: String) -> [Commit] {
        output.components(separatedBy: separator).compactMap { record in
            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count >= 4 else { return nil }
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty, let date = parseDate(stamp) else { return nil }
            let paths = fields[3].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Commit(sha: sha, date: date, message: fields[2], paths: paths)
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Whether the project's definition of done requires the deploy item (DEC-012). `.dde/definition-of-done.json`:
/// `{"items": [{"id": "deploy", "mode": "require"}, ...]}`; absent or unreadable means not required.
enum ReleaseRequirement {
    static func isRequired(definitionOfDoneJSON: Data?) -> Bool {
        guard let data = definitionOfDoneJSON,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return false }
        return items.contains { ($0["id"] as? String) == "deploy" && ($0["mode"] as? String) == "require" }
    }
}

/// `gh run list --commit <sha> --json status,conclusion`: the checks of one commit.
enum RunsVerdict {
    static func state(runsJSON: Data, sha: String) -> CheckState {
        guard let runs = try? JSONSerialization.jsonObject(with: runsJSON) as? [[String: Any]] else { return .unknown("unexpected answer from GitHub") }
        if runs.isEmpty { return .noRuns(sha: sha) }
        var pending = false
        for run in runs {
            let status = (run["status"] as? String ?? "").lowercased()
            let conclusion = (run["conclusion"] as? String ?? "").lowercased()
            if status != "completed" { pending = true; continue }
            if !["success", "skipped", "neutral"].contains(conclusion) { return .failed(sha: sha) }
        }
        return pending ? .pending(sha: sha) : .passed(sha: sha)
    }

    /// A pull request's `statusCheckRollup.state` of its head commit.
    static func state(rollup: String?, sha: String) -> CheckState {
        switch (rollup ?? "").uppercased() {
        case "SUCCESS": return .passed(sha: sha)
        case "FAILURE", "ERROR": return .failed(sha: sha)
        case "PENDING", "EXPECTED": return .pending(sha: sha)
        case "": return .noRuns(sha: sha)
        default: return .unknown("check state \(rollup ?? "")")
        }
    }
}
