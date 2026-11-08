import Foundation

/// The baseline of a comparison by date in the PR X-Ray (feature x-ray-comparison-by-date).
///
/// The person picks a calendar day, then one of the commits made that day, and the X-Ray shows what the working
/// copy (commits, uncommitted changes and new files) has changed since that commit. This module is the part that
/// needs no UI and no model: which commits belong to a day, and the comparison id that names the chosen commit.
///
/// - Which commits (DEC-001, DEC-003, DEC-005): every commit reachable from a local branch whose *committer*
///   timestamp, read in the user's own time zone, falls on the chosen calendar day. The author date is not used,
///   and neither is the time zone recorded in the commit.
/// - The baseline is the chosen commit itself. A branch comparison starts from the merge base with `HEAD`, which
///   would be wrong here: the commit may sit on another branch, and the person asked for exactly this commit.
enum HistoricalBaseline {
    struct Commit: Equatable, Identifiable, Sendable {
        /// Full object name (40 hex digits, or 64 in a SHA-256 repository).
        let sha: String
        /// The committer timestamp: when the commit was created in this history.
        let committed: Date
        let author: String
        let subject: String

        var id: String { sha }
        var shortSha: String { String(sha.prefix(8)) }
    }

    /// `PRSource.id` of a comparison with one historical commit: `at:<full sha>`.
    static let sourcePrefix = "at:"

    /// A full commit object name, as `git rev-parse` prints it. Anything else (a branch, an abbreviation, an
    /// option such as `--output=...`) is refused before it can reach a git command line.
    static func isCommitHash(_ text: String) -> Bool {
        guard text.count == 40 || text.count == 64 else { return false }
        return text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    static func sourceId(for sha: String) -> String? {
        isCommitHash(sha) ? sourcePrefix + sha : nil
    }

    /// The commit a source id names, nil for any other source or a malformed id.
    static func commitHash(fromSourceId id: String) -> String? {
        guard id.hasPrefix(sourcePrefix) else { return nil }
        let sha = String(id.dropFirst(sourcePrefix.count))
        return isCommitHash(sha) ? sha : nil
    }

    // MARK: Which commits belong to a day

    /// The calendar day the page sends (`2026-11-05`) as a moment of that day in `calendar`; nil for any other
    /// text and for a day that does not exist (`2026-02-31`), so a mistyped date never lists another day.
    static func day(from text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), year >= 1970,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day ? date : nil
    }

    /// The day as a half-open interval `[start, end)` in the calendar's time zone. A day with a clock change is
    /// 23 or 25 hours long, which `Calendar` accounts for.
    static func bounds(of day: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    private static let separator = "\u{1F}"
    private static let format = "--format=%H%x1f%ct%x1f%an%x1f%s"

    /// `git` arguments that print every commit of the local branches, one per line:
    /// `sha US committer-epoch US author US subject`. No date limit is given to git: `--since` and `--until`
    /// stop walking when they meet an old commit, so a commit with a wrong clock deeper in the history would
    /// be missed. The day is applied by `commits(_:on:calendar:)`, which is exact.
    static let logArguments = ["log", "--branches", "--no-color", format]

    /// The same line for one commit, to name a baseline chosen by its source id. Nil for anything but a full
    /// object name.
    static func logArguments(forCommit sha: String) -> [String]? {
        isCommitHash(sha) ? ["log", "-1", "--no-color", format, sha] : nil
    }

    static func parse(_ output: String) -> [Commit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: Character(separator), maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, isCommitHash(String(fields[0])), let epoch = TimeInterval(fields[1]) else { return nil }
            return Commit(sha: String(fields[0]), committed: Date(timeIntervalSince1970: epoch),
                          author: String(fields[2]), subject: String(fields[3]))
        }
    }

    /// The commits made on `day`, newest first.
    static func commits(_ all: [Commit], on day: Date, calendar: Calendar) -> [Commit] {
        guard let (start, end) = bounds(of: day, calendar: calendar) else { return [] }
        return all.filter { $0.committed >= start && $0.committed < end }
            .sorted { $0.committed != $1.committed ? $0.committed > $1.committed : $0.sha < $1.sha }
    }

    /// The commits of `day` from the repository `run` reads (`run` gets the arguments after `git -C <root>` and
    /// returns standard output, nil when git failed). Nil when the history cannot be read; an empty list means
    /// the repository has no commit that day. Blocking: call it off the main thread.
    static func commits(on day: Date, calendar: Calendar, run: ([String]) -> String?) -> [Commit]? {
        guard let output = run(logArguments) else { return nil }
        return commits(parse(output), on: day, calendar: calendar)
    }

    // MARK: The comparison

    /// `git` arguments (after `git -C <root>`) that print what the working copy changed since the commit `sha`, as
    /// a unified diff: committed differences, staged and unstaged edits, and files added to the index. The commit is
    /// the baseline itself, not its merge base with `HEAD`, so a commit of another branch works. Files git does not
    /// track yet are not in this diff; the caller adds them as new files.
    ///  - `--no-renames`: a pure rename has no content lines to read, so it is shown as a removed and an added file.
    ///  - `core.quotepath=off`: a path with letters outside ASCII stays readable instead of an octal escape.
    ///  - `--no-ext-diff`: a configured external diff tool must not replace the unified format.
    static func diffArguments(since sha: String) -> [String]? {
        isCommitHash(sha) ? ["-c", "core.quotepath=off", "diff", sha, "--no-renames", "--no-ext-diff", "--no-color", "-U3"] : nil
    }

    // MARK: Naming

    /// What the source picker and the view header show: the working copy against the chosen commit.
    static func title(for commit: Commit, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let subject = commit.subject.count > 60 ? String(commit.subject.prefix(59)) + "…" : commit.subject
        return "Working copy vs \(commit.shortSha) (\(formatter.string(from: commit.committed))) \(subject)"
    }
}
