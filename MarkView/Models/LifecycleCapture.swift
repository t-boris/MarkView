import Foundation

// What automatic lifecycle capture reads outside MarkView: the model an AI CLI answered with,
// from the CLI's own session log, and the review / CI / merge state of the pull requests that
// close a feature's GitHub issues. Foundation only: tools/tests/lifecycle-tests.sh checks it.

/// The model a CLI actually used, read from the session log it writes (not from MarkView's
/// settings: the user may have switched models inside the session).
enum AgentModelProbe {
    /// Claude Code: `~/.claude/projects/<cwd, non-alphanumerics as "-">/*.jsonl`, assistant
    /// lines carry `message.model`.
    static func claudeModel(cwd: URL, since: Date, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let name = String(cwd.standardizedFileURL.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let folder = home.appendingPathComponent(".claude/projects").appendingPathComponent(name, isDirectory: true)
        for file in recentFiles(in: [folder], since: since) {
            for object in lines(of: file) where object["type"] as? String == "assistant" {
                guard let date = timestamp(object), date >= since,
                      let model = (object["message"] as? [String: Any])?["model"] as? String,
                      !model.isEmpty, !model.hasPrefix("<") else { continue }  // "<synthetic>" replies
                return model
            }
        }
        return nil
    }

    /// Codex: `~/.codex/sessions/YYYY/MM/DD/*.jsonl`, `turn_context` lines carry the model and cwd.
    static func codexModel(cwd: URL, since: Date, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let path = cwd.standardizedFileURL.path
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // The day folders of `since` and today (a session may cross midnight).
        let days = Set([since, Date()].map { calendar.dateComponents([.year, .month, .day], from: $0) })
        let folders = days.compactMap { day -> URL? in
            guard let y = day.year, let m = day.month, let d = day.day else { return nil }
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d), isDirectory: true)
        }
        for file in recentFiles(in: folders, since: since) {
            for object in lines(of: file) where object["type"] as? String == "turn_context" {
                guard let date = timestamp(object), date >= since,
                      let payload = object["payload"] as? [String: Any],
                      (payload["cwd"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == path,
                      let model = payload["model"] as? String, !model.isEmpty else { continue }
                return model
            }
        }
        return nil
    }

    /// `.jsonl` files changed since `since`, newest first.
    private static func recentFiles(in folders: [URL], since: Date) -> [URL] {
        let fm = FileManager.default
        return folders.flatMap { folder in
            (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        .filter { $0.pathExtension == "jsonl" }
        .compactMap { url -> (URL, Date)? in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= since else { return nil }
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private static func lines(of url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private static func timestamp(_ object: [String: Any]) -> Date? {
        (object["timestamp"] as? String).flatMap(LifecycleGitHub.date)
    }
}

/// Review, CI and merge of the pull requests linked to a feature, as lifecycle events stamped
/// with GitHub's own times.
enum LifecycleGitHub {
    struct Capture: Equatable, Sendable {
        let stage: LifecycleStage
        let date: Date
        /// "PR #12": one event per stage and pull request.
        let note: String
    }

    /// One GraphQL query for the default branch and, per number, the pull request itself or the
    /// pull requests that close that issue.
    static func query(numbers: [Int]) -> String {
        let pr = """
            number state createdAt mergedAt baseRefName \
            reviews(states: APPROVED, first: 1) { nodes { submittedAt } } \
            commits(last: 1) { nodes { commit { statusCheckRollup { state \
            contexts(first: 100) { nodes { __typename ... on CheckRun { completedAt } ... on StatusContext { createdAt } } } } } } }
            """
        let items = numbers.map { n in
            "n\(n): issueOrPullRequest(number: \(n)) { ... on Issue { closedByPullRequestsReferences(first: 20, includeClosedPrs: true) { nodes { \(pr) } } } ... on PullRequest { \(pr) } }"
        }
        return "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { defaultBranchRef { name } \(items.joined(separator: " ")) } }"
    }

    /// The events a `query` answer shows: a PR opened → implementation finished, approved →
    /// review done, all checks green → CI passed, merged into the default branch → merged to main.
    /// Closed-unmerged pull requests count for nothing.
    static func captures(from json: Data) -> [Capture] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let repository = (root["data"] as? [String: Any])?["repository"] as? [String: Any] else { return [] }
        let main = (repository["defaultBranchRef"] as? [String: Any])?["name"] as? String
        var pulls: [Int: [String: Any]] = [:]
        for (key, value) in repository where key.hasPrefix("n") {
            guard let item = value as? [String: Any] else { continue }
            if let number = item["number"] as? Int { pulls[number] = item }
            let linked = (item["closedByPullRequestsReferences"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            for pr in linked { if let number = pr["number"] as? Int { pulls[number] = pr } }
        }
        var result: [Capture] = []
        for (number, pr) in pulls.sorted(by: { $0.key < $1.key }) {
            let state = (pr["state"] as? String ?? "").uppercased()
            let merged = (pr["mergedAt"] as? String).flatMap(date)
            guard state != "CLOSED" || merged != nil else { continue }
            let note = "PR #\(number)"
            if let opened = (pr["createdAt"] as? String).flatMap(date) {
                result.append(Capture(stage: .implementationFinished, date: opened, note: note))
            }
            let reviews = (pr["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            if let approved = reviews.compactMap({ ($0["submittedAt"] as? String).flatMap(date) }).min() {
                result.append(Capture(stage: .reviewDone, date: approved, note: note))
            }
            let commits = (pr["commits"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            if let rollup = (commits.last?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any],
               (rollup["state"] as? String)?.uppercased() == "SUCCESS" {
                let contexts = (rollup["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
                let finished = contexts.compactMap { ($0["completedAt"] as? String ?? $0["createdAt"] as? String).flatMap(date) }.max()
                if let finished { result.append(Capture(stage: .ciPassed, date: finished, note: note)) }
            }
            if let merged, let main, pr["baseRefName"] as? String == main {
                result.append(Capture(stage: .mergedToMain, date: merged, note: note))
            }
        }
        return result
    }

    /// ISO 8601, with or without fractional seconds (GitHub and the CLI logs use both).
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Work committed straight to the default branch (no pull request): a commit whose message names
/// the feature folder or one of its issues is "merged to main"; its Actions runs give "CI passed".
enum LifecycleGit {
    struct Commit: Equatable, Sendable {
        let sha: String
        let date: Date
        let message: String

        /// "commit abc1234": one event per stage and commit.
        var note: String { "commit " + sha.prefix(7) }
    }

    /// `git log` arguments whose output `commits(from:)` reads.
    static func logArguments(branch: String, limit: Int = 200) -> [String] {
        ["log", branch, "-n", String(limit), "--format=%H%x1f%cI%x1f%B%x1e"]
    }

    static func commits(from output: String) -> [Commit] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let date = LifecycleGitHub.date(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { return nil }
            return Commit(sha: sha, date: date, message: String(fields[2]))
        }
    }

    /// The message names `docs/features/<slug>` (as a whole path segment) or "#n" of one of `issues`.
    static func mentions(_ message: String, folder: String, issues: Set<Int>) -> Bool {
        if let range = message.range(of: NSRegularExpression.escapedPattern(for: folder) + "(?![A-Za-z0-9_-])", options: .regularExpression), !range.isEmpty { return true }
        guard !issues.isEmpty, let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9&])#(\d+)\b"#) else { return false }
        let range = NSRange(message.startIndex..., in: message)
        return regex.matches(in: message, range: range).contains { match in
            Range(match.range(at: 1), in: message).flatMap { Int(message[$0]) }.map(issues.contains) ?? false
        }
    }

    /// `gh run list --commit <sha> --json status,conclusion,updatedAt`: when every run finished
    /// successfully, the time the last one finished; nil while any runs, fails, or there is none.
    static func ciPassed(runsJSON: Data) -> Date? {
        guard let runs = try? JSONSerialization.jsonObject(with: runsJSON) as? [[String: Any]], !runs.isEmpty,
              runs.allSatisfy({ ($0["status"] as? String)?.lowercased() == "completed" && ($0["conclusion"] as? String)?.lowercased() == "success" })
        else { return nil }
        return runs.compactMap { ($0["updatedAt"] as? String).flatMap(LifecycleGitHub.date) }.max()
    }
}
