import Foundation

// Standalone checks for MarkView/Models/HistoricalBaseline.swift (feature x-ray-comparison-by-date, REQ-001, REQ-002).
// Run through tools/tests/historical-baseline-tests.sh. The last group runs real git in a temporary repository.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, _ detail: String = "") {
    if !condition() {
        failures += 1
        print("FAIL: \(message)" + (detail.isEmpty ? "" : "\n      " + String(detail.prefix(600))))
    }
}

func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

/// A moment written in a given time zone, e.g. `moment("2026-11-05 23:59:59", "Asia/Tokyo")`.
func moment(_ text: String, _ zone: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: text)!
}

let hashA = String(repeating: "a", count: 40)
let hashB = String(repeating: "b", count: 40)
let hashC = String(repeating: "c", count: 40)

// MARK: Commit names and source ids (the id reaches git command lines, so only a full object name passes)

check(HistoricalBaseline.isCommitHash(hashA), "a 40-digit name is a commit hash")
check(HistoricalBaseline.isCommitHash(String(repeating: "0123456789abcdef", count: 4)), "a 64-digit name (SHA-256 repository) is a commit hash")
for bad in ["", "main", "HEAD", "abc1234", String(repeating: "A", count: 40), String(repeating: "g", count: 40),
            "--output=/tmp/x", hashA + " ", " " + hashA, hashA + "\n", String(repeating: "a", count: 41)] {
    check(!HistoricalBaseline.isCommitHash(bad), "not a commit hash: \(bad.debugDescription)")
}
check(HistoricalBaseline.sourceId(for: hashA) == "at:" + hashA, "the source id is at:<sha>")
check(HistoricalBaseline.sourceId(for: "main") == nil, "no source id for a branch name")
check(HistoricalBaseline.commitHash(fromSourceId: "at:" + hashB) == hashB, "the commit comes back out of its source id")
for other in ["local", "gh:12", "cmp:main", "rev:main", "at:main", "at:--output=x", "at:", "at:" + hashA + "x", hashA] {
    check(HistoricalBaseline.commitHash(fromSourceId: other) == nil, "\(other) names no historical commit")
}

// MARK: Parsing the log

let us = "\u{1F}"
let log = [
    "\(hashA)\(us)1793000000\(us)Ada Lovelace\(us)Fix the parser",
    "\(hashB)\(us)1793000100\(us)Grace\(us)Subject with \(us) a separator inside",
    "not a hash\(us)1793000200\(us)Bob\(us)bad hash",
    "\(hashC)\(us)soon\(us)Bob\(us)bad time",
    "\(hashC)\(us)1793000300",
    "",
].joined(separator: "\n")
let parsed = HistoricalBaseline.parse(log)
check(parsed.map(\.sha) == [hashA, hashB], "valid lines are kept, malformed ones skipped (got \(parsed.map(\.sha)))")
check(parsed.first?.author == "Ada Lovelace" && parsed.first?.subject == "Fix the parser", "author and subject are read")
check(parsed.last?.subject == "Subject with \(us) a separator inside", "a separator inside the subject stays in the subject")
check(parsed.first?.committed == Date(timeIntervalSince1970: 1793000000), "the committer epoch becomes the date")
check(parsed.first?.shortSha == "aaaaaaaa", "the short name is 8 digits")
check(HistoricalBaseline.parse("").isEmpty, "an empty log has no commits")

// MARK: The day the page sends

let chicagoCalendar = calendar("America/Chicago")
let sent = HistoricalBaseline.day(from: "2026-11-05", calendar: chicagoCalendar)
check(sent != nil && chicagoCalendar.dateComponents([.year, .month, .day], from: sent!) == DateComponents(year: 2026, month: 11, day: 5),
      "2026-11-05 is Nov 5 in the user's calendar")
check(HistoricalBaseline.day(from: "2026-11-05", calendar: calendar("Asia/Tokyo")) != sent, "the same text is another moment for another zone")
for bad in ["", "2026-2-3", "2026-02-31", "2026-13-01", "2026-00-10", "1969-12-31", "yesterday", "2026-11-05T10:00", "2026/11/05",
            "+026-11-05", "2026-11-05 ", "٢٠٢٦-١١-٠٥"] {
    check(HistoricalBaseline.day(from: bad, calendar: chicagoCalendar) == nil, "not a day: \(bad.debugDescription)")
}
check(HistoricalBaseline.day(from: "2028-02-29", calendar: chicagoCalendar) != nil, "a leap day is a day")
check(HistoricalBaseline.day(from: "2026-02-29", calendar: chicagoCalendar) == nil, "Feb 29 of a common year is not")
check(HistoricalBaseline.logArguments(forCommit: hashA) == ["log", "-1", "--no-color", "--format=%H%x1f%ct%x1f%an%x1f%s", hashA],
      "one commit is read with the same line format")
check(HistoricalBaseline.logArguments(forCommit: "--output=/tmp/x") == nil, "no git command line for a name that is not a full hash")

// MARK: The calendar day, read in the user's time zone (DEC-005)

func commit(_ sha: String, _ date: Date, author: String = "x", subject: String = "s") -> HistoricalBaseline.Commit {
    HistoricalBaseline.Commit(sha: sha, committed: date, author: author, subject: subject)
}

let tokyo = calendar("Asia/Tokyo")
let chicago = calendar("America/Chicago")
let utc = calendar("UTC")

// The same instant is on different days for people in different zones.
let instant = moment("2026-11-05 23:30:00", "UTC")   // 2026-11-06 08:30 in Tokyo, 2026-11-05 17:30 in Chicago
let one = [commit(hashA, instant)]
check(HistoricalBaseline.commits(one, on: moment("2026-11-05 12:00:00", "UTC"), calendar: utc).count == 1, "UTC: the commit is on Nov 5")
check(HistoricalBaseline.commits(one, on: moment("2026-11-06 12:00:00", "Asia/Tokyo"), calendar: tokyo).count == 1, "Tokyo: the commit is on Nov 6")
check(HistoricalBaseline.commits(one, on: moment("2026-11-05 12:00:00", "Asia/Tokyo"), calendar: tokyo).isEmpty, "Tokyo: not on Nov 5")
check(HistoricalBaseline.commits(one, on: moment("2026-11-05 12:00:00", "America/Chicago"), calendar: chicago).count == 1, "Chicago: the commit is on Nov 5")
check(HistoricalBaseline.commits(one, on: moment("2026-11-06 12:00:00", "America/Chicago"), calendar: chicago).isEmpty, "Chicago: not on Nov 6")

// The day is half open: its first second belongs to it, the first second of the next day does not.
let edges = [commit(hashA, moment("2026-11-04 23:59:59", "Asia/Tokyo")),
             commit(hashB, moment("2026-11-05 00:00:00", "Asia/Tokyo")),
             commit(hashC, moment("2026-11-05 23:59:59", "Asia/Tokyo")),
             commit(String(repeating: "d", count: 40), moment("2026-11-06 00:00:00", "Asia/Tokyo"))]
let tokyoFifth = HistoricalBaseline.commits(edges, on: moment("2026-11-05 15:00:00", "Asia/Tokyo"), calendar: tokyo)
check(tokyoFifth.map(\.sha) == [hashC, hashB], "midnight to 23:59:59 is the day (got \(tokyoFifth.map { $0.sha.prefix(1) }))")

// Clock changes: 2026-11-01 is 25 hours long in Chicago, 2026-03-08 only 23.
let longDay = [commit(hashA, moment("2026-11-01 00:00:00", "America/Chicago")),
               commit(hashB, moment("2026-11-01 23:59:59", "America/Chicago")),
               commit(hashC, moment("2026-11-02 00:00:00", "America/Chicago"))]
check(HistoricalBaseline.commits(longDay, on: moment("2026-11-01 12:00:00", "America/Chicago"), calendar: chicago).count == 2,
      "a 25-hour day keeps both its first and its last second")
let shortDay = [commit(hashA, moment("2026-03-08 23:59:59", "America/Chicago")), commit(hashB, moment("2026-03-09 00:00:00", "America/Chicago"))]
check(HistoricalBaseline.commits(shortDay, on: moment("2026-03-08 12:00:00", "America/Chicago"), calendar: chicago).map(\.sha) == [hashA],
      "a 23-hour day ends where the next begins")

// Newest first; equal times are ordered by name so the list does not jump.
let ordering = HistoricalBaseline.commits([commit(hashB, instant), commit(hashA, instant),
                                           commit(hashC, instant.addingTimeInterval(60))], on: instant, calendar: utc)
check(ordering.map(\.sha) == [hashC, hashA, hashB], "newest first, ties by name (got \(ordering.map { $0.sha.prefix(1) }))")

// MARK: Reading the history through the injected runner

check(HistoricalBaseline.commits(on: instant, calendar: utc, run: { _ in nil }) == nil, "git failing is nil, not an empty day")
let emptyDay = HistoricalBaseline.commits(on: moment("2026-01-01 12:00:00", "UTC"), calendar: utc, run: { _ in log })
check(emptyDay != nil && emptyDay!.isEmpty, "a day without commits is an empty list (the empty state), not nil")
var asked: [[String]] = []
_ = HistoricalBaseline.commits(on: instant, calendar: utc, run: { asked.append($0); return "" })
check(asked == [HistoricalBaseline.logArguments], "git is asked once, with the fixed argument list")
check(HistoricalBaseline.logArguments.contains("--branches"), "all local branches are read")
check(!HistoricalBaseline.logArguments.contains(where: { $0.hasPrefix("--since") || $0.hasPrefix("--until") }),
      "git is given no date limit: its early stop would miss a commit with a wrong clock")

// MARK: Naming

let named = HistoricalBaseline.title(for: commit(hashA, moment("2026-11-05 14:32:10", "Asia/Tokyo"), subject: "Fix it"), calendar: tokyo)
check(named == "Working copy vs aaaaaaaa (2026-11-05 14:32) Fix it", "title is the working copy against the commit (got \(named))")
let longTitle = HistoricalBaseline.title(for: commit(hashA, instant, subject: String(repeating: "x", count: 100)), calendar: utc)
check(longTitle.hasSuffix(String(repeating: "x", count: 59) + "…"), "a long subject is cut")

// MARK: Real git: all local branches, committer date, nothing else

func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path, "-c", "user.name=Tester", "-c", "user.email=tester@example.com",
                         "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

let repo = FileManager.default.temporaryDirectory.appendingPathComponent("historical-baseline-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: repo) }

func commitEmpty(_ message: String, author: String, committer: String) -> String {
    _ = git(["commit", "--allow-empty", "-m", message], in: repo,
            environment: ["GIT_AUTHOR_DATE": author, "GIT_COMMITTER_DATE": committer])
    return git(["rev-parse", "HEAD"], in: repo)!.trimmingCharacters(in: .whitespacesAndNewlines)
}

_ = git(["init", "-q"], in: repo)
let onMain = commitEmpty("main work", author: "2026-11-04T09:00:00+0000", committer: "2026-11-05T09:00:00+0000")
_ = git(["switch", "-q", "-c", "side"], in: repo)
let onSide = commitEmpty("side work", author: "2026-11-05T10:00:00+0000", committer: "2026-11-05T11:00:00+0000")
let rebasedLater = commitEmpty("rewritten later", author: "2026-11-05T12:00:00+0000", committer: "2026-11-07T12:00:00+0000")
_ = git(["switch", "-q", "main"], in: repo)
// `side` is not merged: its commits are not in main's history, and the checkout is on main.
check(git(["branch", "--contains", onSide], in: repo)?.contains("side") == true, "setup: the side commit is on branch side")
// A commit reachable only from a remote-tracking ref or a tag is not on a local branch.
_ = git(["switch", "-q", "-c", "gone"], in: repo)
let remoteOnly = commitEmpty("only on a remote", author: "2026-11-05T13:00:00+0000", committer: "2026-11-05T13:00:00+0000")
_ = git(["update-ref", "refs/remotes/origin/gone", remoteOnly], in: repo)
_ = git(["tag", "only-a-tag", remoteOnly], in: repo)
_ = git(["switch", "-q", "main"], in: repo)
_ = git(["branch", "-D", "gone"], in: repo)

let runInRepo: ([String]) -> String? = { git($0, in: repo) }
let nov5 = HistoricalBaseline.commits(on: moment("2026-11-05 12:00:00", "UTC"), calendar: utc, run: runInRepo)
check(nov5 != nil, "real git: the history is read")
check(Set(nov5?.map(\.sha) ?? []) == [onMain, onSide],
      "real git: Nov 5 has the main commit and the unmerged side-branch commit, by committer date (got \(nov5?.map { $0.subject } ?? []))")
check(nov5?.map(\.subject) == ["side work", "main work"], "real git: newest first")
check(nov5?.first?.author == "Tester", "real git: the author is read")
let nov4 = HistoricalBaseline.commits(on: moment("2026-11-04 12:00:00", "UTC"), calendar: utc, run: runInRepo)
check(nov4?.isEmpty == true, "real git: the author date (Nov 4) does not place the commit; the committer date does")
let nov7 = HistoricalBaseline.commits(on: moment("2026-11-07 12:00:00", "UTC"), calendar: utc, run: runInRepo)
check(nov7?.map(\.sha) == [rebasedLater], "real git: a commit amended later is on the day it was committed")
check(HistoricalBaseline.commits(on: moment("2026-11-05 12:00:00", "UTC"), calendar: utc, run: runInRepo)?.contains { $0.sha == remoteOnly } == false,
      "real git: a commit only on a remote-tracking ref or a tag is not offered (local branches only)")
check(HistoricalBaseline.commits(on: moment("2026-11-06 12:00:00", "UTC"), calendar: utc, run: runInRepo)?.isEmpty == true,
      "real git: a quiet day is an empty list")
// Every listed name is usable as a baseline: git resolves it to a commit.
check(nov5?.allSatisfy { git(["rev-parse", "--verify", "--quiet", $0.sha + "^{commit}"], in: repo) != nil } == true,
      "real git: each offered commit resolves")
let notARepo = FileManager.default.temporaryDirectory.appendingPathComponent("historical-baseline-none-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: notARepo) }
check(HistoricalBaseline.commits(on: instant, calendar: utc, run: { git($0, in: notARepo) }) == nil,
      "real git: a folder that is not a repository gives nil")

// MARK: Real git: what the working copy changed since the chosen commit (REQ-002)

check(HistoricalBaseline.diffArguments(since: "main") == nil && HistoricalBaseline.diffArguments(since: "--output=/tmp/x") == nil,
      "no diff command for a name that is not a full hash")

let work = FileManager.default.temporaryDirectory.appendingPathComponent("historical-diff-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
func put(_ name: String, _ text: String) { try? text.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func remove(_ name: String) { try? FileManager.default.removeItem(at: work.appendingPathComponent(name)) }
func save(_ message: String) -> String {
    _ = git(["add", "-A"], in: work)
    _ = git(["commit", "-q", "-m", message], in: work)
    return git(["rev-parse", "HEAD"], in: work)!.trimmingCharacters(in: .whitespacesAndNewlines)
}
_ = git(["init", "-q"], in: work)
put("a.txt", "one\ntwo\n"); put("gone.txt", "bye\n"); put("same.txt", "same\n")
put("rename-me.txt", "a line that identifies this file when git looks for renames\nand a second one\nand a third one\n")
put("файл.js", "let x = 1\n")
let base = save("base")
// A branch that goes its own way from the base: its commit is not in the history of what main becomes.
_ = git(["switch", "-q", "-c", "side"], in: work)
put("s.txt", "only on the side branch\n")
let sideCommit = save("side only")
_ = git(["switch", "-q", "main"], in: work)
put("a.txt", "one\ntwo\nthree\n"); remove("gone.txt"); remove("файл.js")
remove("rename-me.txt")
put("renamed.txt", "a line that identifies this file when git looks for renames\nand a second one\nand a third one\n")
_ = save("committed work")
put("a.txt", "one\ntwo\nthree\nfour\n")            // uncommitted edit
put("staged.txt", "staged\n"); _ = git(["add", "staged.txt"], in: work)   // new, in the index
put("loose.txt", "never added\n")                   // new, untracked

func diff(since sha: String) -> String {
    guard let arguments = HistoricalBaseline.diffArguments(since: sha) else { return "NO ARGUMENTS" }
    return git(arguments, in: work) ?? "GIT FAILED"
}
let sinceBase = diff(since: base)
check(sinceBase.contains("diff --git a/a.txt b/a.txt") && sinceBase.contains("+three") && sinceBase.contains("+four"),
      "since the base: committed and uncommitted edits of one file are both in the diff", sinceBase)
check(sinceBase.contains("deleted file mode") && sinceBase.contains("--- a/gone.txt"), "since the base: a file removed by a commit is a removed file", sinceBase)
check(sinceBase.contains("new file mode") && sinceBase.contains("+++ b/staged.txt"), "since the base: a new file in the index is a new file", sinceBase)
check(!sinceBase.contains("loose.txt"), "since the base: an untracked file is not in this diff (the store adds it as a new file)", sinceBase)
check(!sinceBase.contains("same.txt"), "since the base: an untouched file is not in the diff", sinceBase)
check(!sinceBase.contains("rename from") && sinceBase.contains("--- a/rename-me.txt") && sinceBase.contains("+++ b/renamed.txt"),
      "since the base: a rename is a removed and an added file, so its content lines are read", sinceBase)
check(sinceBase.contains("--- a/файл.js") && !sinceBase.contains("\\321"), "since the base: a path outside ASCII stays readable", sinceBase)
// The chosen commit is the baseline itself, not its merge base with HEAD.
let sinceSide = diff(since: sideCommit)
check(sinceSide.contains("deleted file mode") && sinceSide.contains("--- a/s.txt"),
      "since a commit of another branch: what that commit has and the working copy lacks is a removed file", sinceSide)
check(git(["merge-base", sideCommit, "HEAD"], in: work)?.trimmingCharacters(in: .whitespacesAndNewlines) == base,
      "setup: the merge base of that commit with HEAD is the base commit, which would hide s.txt")
check(!diff(since: base).contains("s.txt"), "setup: from the merge base the side file does not show")
check(diff(since: String(repeating: "f", count: 40)) == "GIT FAILED", "a commit that does not exist is a failure, not an empty diff")

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("All historical baseline checks passed")
