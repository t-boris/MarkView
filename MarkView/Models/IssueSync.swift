import Foundation

// Sync of documented status to GitHub issues (issue #36,
// docs/features/sync-documented-status-to-github-issues): which issues each Feature and Bug links
// to, which of them may be closed, and the report. Foundation only (with IssueListing.swift), so
// tools/tests/issue-sync-tests.sh compiles it on its own. The run itself is IssueSyncRun.swift.

/// A Feature or Bug as Sync reads it from disk.
struct IssueSyncItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case feature, bug }

    var kind: Kind
    /// Slug of a feature, key of a bug ("BUG-012").
    var id: String
    var title: String
    /// Status as written; "" when there is none.
    var status: String
    /// Values of the explicit link fields: `issue`, `issues`, `github`, the plan's issues and epic.
    var fieldValues: [String]
    /// Markdown searched for full GitHub issue URLs.
    var texts: [String]

    /// Features count when implemented, verified or archived (DEC-005); bugs when fixed or
    /// closed (owner answer 2026-09-27).
    static let doneFeature: Set<String> = ["implemented", "verified", "archived"]
    static let doneBug: Set<String> = ["fixed", "closed"]

    var isDone: Bool {
        let value = IssueStatus.normalize(status)
        return kind == .feature ? Self.doneFeature.contains(value) : Self.doneBug.contains(value)
    }

    /// "BUG-003 (fixing)", "my-feature (no status)".
    var blockingLabel: String {
        let value = IssueStatus.normalize(status)
        return "\(id) (\(value.isEmpty ? "no status" : value))"
    }
}

/// One GitHub issue or pull request, by repository ("owner/name", lower-case) and number.
struct IssueSyncTarget: Hashable, Comparable, Sendable {
    let repo: String
    let number: Int

    init(repo: String, number: Int) {
        self.repo = repo.lowercased()
        self.number = number
    }

    static func < (a: IssueSyncTarget, b: IssueSyncTarget) -> Bool {
        a.repo == b.repo ? a.number < b.number : a.repo < b.repo
    }

    /// "#12" in the project's repository, "owner/name#12" elsewhere.
    func label(origin: String) -> String {
        repo == origin.lowercased() ? "#\(number)" : "\(repo)#\(number)"
    }
}

/// An explicit reference found in an item: an issue, or a pull request link.
struct IssueSyncReference: Hashable, Sendable {
    let target: IssueSyncTarget
    let isPullLink: Bool
}

enum IssueSyncLinks {
    /// References in the explicit fields (DEC-006): `12`, `#12`, `owner/name#12` and full
    /// issue or pull request URLs. Numbers without a repository belong to `origin`.
    static func fieldReferences(_ values: [String], origin: String) -> [IssueSyncReference] {
        var found: [IssueSyncReference] = []
        for value in values {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches(fieldPattern, in: text) {
                if let owner = match[1], let name = match[2], let kind = match[3], let number = match[4].flatMap(Int.init) {
                    found.append(IssueSyncReference(target: IssueSyncTarget(repo: owner + "/" + trimGit(name), number: number),
                                                    isPullLink: kind == "pull"))
                } else if let owner = match[5], let name = match[6], let number = match[7].flatMap(Int.init) {
                    found.append(IssueSyncReference(target: IssueSyncTarget(repo: owner + "/" + name, number: number), isPullLink: false))
                } else if let number = match[8].flatMap(Int.init) {
                    found.append(IssueSyncReference(target: IssueSyncTarget(repo: origin, number: number), isPullLink: false))
                }
            }
        }
        return found
    }

    /// Full GitHub issue URLs in Markdown (DEC-001). "issue #n" and bare "#n" are not links,
    /// and pull request URLs in prose are not issue references.
    static func textReferences(_ texts: [String]) -> [IssueSyncReference] {
        texts.flatMap { text in
            matches(issueURLPattern, in: text).compactMap { match -> IssueSyncReference? in
                guard let owner = match[1], let name = match[2], let number = match[3].flatMap(Int.init) else { return nil }
                return IssueSyncReference(target: IssueSyncTarget(repo: owner + "/" + name, number: number), isPullLink: false)
            }
        }
    }

    /// Every reference of an item, first occurrence kept (DEC-008).
    static func references(of item: IssueSyncItem, origin: String) -> [IssueSyncReference] {
        var seen = Set<IssueSyncTarget>()
        var out: [IssueSyncReference] = []
        for reference in fieldReferences(item.fieldValues, origin: origin) + textReferences(item.texts)
        where seen.insert(reference.target).inserted {
            out.append(reference)
        }
        return out
    }

    private static let owner = #"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"#
    private static let name = #"[A-Za-z0-9._-]+"#
    private static let fieldPattern = try! NSRegularExpression(pattern:
        #"(?:https?://)?(?:www\.)?github\.com/("# + owner + ")/(" + name + #")/(issues|pull)/(\d+)"#
        + "|(?<![/\\w.-])(" + owner + ")/(" + name + #")#(\d+)"#
        + #"|(?<![\w/#])#?(\d+)\b"#)
    private static let issueURLPattern = try! NSRegularExpression(pattern:
        #"https?://(?:www\.)?github\.com/("# + owner + ")/(" + name + #")/issues/(\d+)\b"#)

    private static func trimGit(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    /// Capture groups of every match (index 0 = the whole match).
    private static func matches(_ regex: NSRegularExpression, in text: String) -> [[String?]] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}

/// How one issue, or one item without links, came out of a run.
struct IssueSyncOutcome: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case updated, unchanged, skipped, failed }

    let kind: Kind
    /// What was done, or why not.
    let detail: String

    static let closed = IssueSyncOutcome(kind: .updated, detail: "closed as completed")
    static let alreadyClosed = IssueSyncOutcome(kind: .unchanged, detail: "already closed")
    static let otherRepository = IssueSyncOutcome(kind: .skipped, detail: "other repository")
    static let pullRequest = IssueSyncOutcome(kind: .skipped, detail: "pull request")
    static let notFound = IssueSyncOutcome(kind: .skipped, detail: "issue not found")
    static let unlinked = IssueSyncOutcome(kind: .skipped, detail: "unlinked")
}

/// What GitHub says about a number in the project's repository.
enum IssueSyncRemote: Equatable, Sendable {
    case issue(open: Bool)
    case pullRequest
    case notFound
    case failed(String)

    /// `gh api repos/{owner}/{name}/issues/{n}` output. The issues endpoint also answers for
    /// pull requests; they carry a `pull_request` key.
    static func parse(json: String) -> IssueSyncRemote {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let state = object["state"] as? String else {
            return .failed("Unexpected answer from GitHub.")
        }
        if object["pull_request"] != nil { return .pullRequest }
        return .issue(open: state.lowercased() == "open")
    }

    /// A failed lookup: a missing, deleted or transferred issue is "not found"; anything else
    /// (permissions, rate limit, network) is a failure with gh's message.
    static func failure(message: String) -> IssueSyncRemote {
        let lower = message.lowercased()
        if lower.contains("http 404") || lower.contains("http 410") || lower.contains("not found") { return .notFound }
        return .failed(message.isEmpty ? "GitHub lookup failed." : message)
    }
}

/// The links of one run: item–issue pairs, the unique issues to look up, and the rule for
/// closing them. Built before anything is changed (DEC-005).
struct IssueSyncPlan: Sendable {
    struct Pair: Sendable, Equatable {
        let item: Int
        /// nil: the item has no explicit reference (unlinked).
        let target: IssueSyncTarget?
    }

    /// "owner/name" of the project's origin, as detected.
    let origin: String
    let items: [IssueSyncItem]
    let pairs: [Pair]
    /// Issues of the origin repository to look up, each once.
    let lookups: [IssueSyncTarget]
    /// Outcomes known from the links alone: other repositories and pull request URLs.
    let known: [IssueSyncTarget: IssueSyncOutcome]

    init(items: [IssueSyncItem], origin: String) {
        self.origin = origin
        self.items = items
        let home = origin.lowercased()
        var pairs: [Pair] = []
        var lookups: [IssueSyncTarget] = []
        var known: [IssueSyncTarget: IssueSyncOutcome] = [:]
        for (index, item) in items.enumerated() {
            let references = IssueSyncLinks.references(of: item, origin: origin)
            if references.isEmpty { pairs.append(Pair(item: index, target: nil)) }
            for reference in references {
                let target = reference.target
                pairs.append(Pair(item: index, target: target))
                if target.repo != home {
                    known[target] = .otherRepository
                } else if reference.isPullLink {
                    known[target] = .pullRequest
                } else if !lookups.contains(target) {
                    lookups.append(target)
                }
            }
        }
        lookups.removeAll { known[$0] != nil }
        self.pairs = pairs
        self.lookups = lookups
        self.known = known
    }

    /// Items linking to `target`, in list order.
    func linkedItems(_ target: IssueSyncTarget) -> [IssueSyncItem] {
        var seen = Set<Int>()
        return pairs.filter { $0.target == target && seen.insert($0.item).inserted }.map { items[$0.item] }
    }

    /// Items that keep `target` open: every linked item must be done (DEC-005).
    func blockingItems(_ target: IssueSyncTarget) -> [IssueSyncItem] {
        linkedItems(target).filter { !$0.isDone }
    }

    enum Decision: Equatable {
        case close
        case outcome(IssueSyncOutcome)
    }

    /// What to do with an issue, given what GitHub says about it. Closed issues are never
    /// reopened; open ones close only when nothing linked to them is still in progress.
    func decide(_ target: IssueSyncTarget, remote: IssueSyncRemote) -> Decision {
        switch remote {
        case .pullRequest: return .outcome(.pullRequest)
        case .notFound: return .outcome(.notFound)
        case .failed(let message): return .outcome(IssueSyncOutcome(kind: .failed, detail: message))
        case .issue(open: false): return .outcome(.alreadyClosed)
        case .issue(open: true):
            let blocking = blockingItems(target)
            if blocking.isEmpty { return .close }
            return .outcome(IssueSyncOutcome(kind: .skipped,
                                             detail: "not done yet: " + blocking.map(\.blockingLabel).joined(separator: ", ")))
        }
    }
}

/// The result of a run, kept in memory until the next run or until the window closes (DEC-009).
struct IssueSyncReport: Sendable {
    struct Row: Identifiable, Sendable {
        let id: Int
        let item: IssueSyncItem
        /// nil for an unlinked item.
        let target: IssueSyncTarget?
        let outcome: IssueSyncOutcome
    }

    let origin: String
    let finished: Date
    /// Set when the run stopped before changing anything (preflight); rows are empty then.
    let error: String?
    let rows: [Row]
    /// Outcome of each unique issue: the summary counts issues, not rows (DEC-008).
    let outcomes: [IssueSyncTarget: IssueSyncOutcome]

    init(plan: IssueSyncPlan, outcomes: [IssueSyncTarget: IssueSyncOutcome], finished: Date = Date()) {
        origin = plan.origin
        self.finished = finished
        error = nil
        self.outcomes = outcomes
        rows = plan.pairs.enumerated().map { index, pair in
            Row(id: index, item: plan.items[pair.item], target: pair.target,
                outcome: pair.target.flatMap { outcomes[$0] } ?? (pair.target == nil ? .unlinked
                    : IssueSyncOutcome(kind: .failed, detail: "not processed")))
        }
    }

    init(origin: String, error: String, finished: Date = Date()) {
        self.origin = origin
        self.finished = finished
        self.error = error
        rows = []
        outcomes = [:]
    }

    func count(_ kind: IssueSyncOutcome.Kind) -> Int {
        outcomes.values.filter { $0.kind == kind }.count
    }

    /// Items with no explicit reference, counted apart from issues.
    var unlinkedCount: Int { rows.filter { $0.target == nil }.count }

    /// Rows with a linked issue: failures first, then closed, skipped and unchanged; by issue.
    var linkedRows: [Row] {
        let order: [IssueSyncOutcome.Kind] = [.failed, .updated, .skipped, .unchanged]
        return rows.filter { $0.target != nil }.sorted { a, b in
            let ka = order.firstIndex(of: a.outcome.kind) ?? 0, kb = order.firstIndex(of: b.outcome.kind) ?? 0
            if ka != kb { return ka < kb }
            if a.target != b.target { return a.target! < b.target! }
            return a.id < b.id
        }
    }

    var unlinkedRows: [Row] { rows.filter { $0.target == nil } }

    /// "2 closed · 5 unchanged · 3 skipped · 1 failed · 7 unlinked"
    var summary: String {
        if let error { return error }
        var parts: [String] = []
        let words: [(IssueSyncOutcome.Kind, String)] = [(.updated, "closed"), (.unchanged, "unchanged"),
                                                         (.skipped, "skipped"), (.failed, "failed")]
        for (kind, word) in words where count(kind) > 0 { parts.append("\(count(kind)) \(word)") }
        if unlinkedCount > 0 { parts.append("\(unlinkedCount) unlinked") }
        return parts.isEmpty ? "Nothing to sync" : parts.joined(separator: " · ")
    }
}

/// Preflight checks before anything changes (DEC-007).
enum IssueSyncPreflight {
    /// Closing an issue needs triage access or more.
    static let closingPermissions: Set<String> = ["ADMIN", "MAINTAIN", "WRITE", "TRIAGE"]

    /// `gh repo view --json viewerPermission` output → an error message, or nil when closing is allowed.
    static func permissionProblem(json: String, repo: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return "Unexpected answer from GitHub about \(repo)."
        }
        let permission = (object["viewerPermission"] as? String ?? "").uppercased()
        if closingPermissions.contains(permission) { return nil }
        let level = permission.isEmpty ? "no" : permission.lowercased()
        return "Your GitHub account has \(level) access to \(repo); closing issues needs triage or write access. "
            + "Nothing was changed."
    }
}
