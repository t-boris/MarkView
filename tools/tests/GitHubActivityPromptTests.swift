import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") }
    else { failures += 1; print("FAIL \(message) (line \(line))") }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Chicago")!
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.calendar = calendar
formatter.timeZone = calendar.timeZone
formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
func date(_ value: String) -> Date { formatter.date(from: value)! }

func weekdays(_ count: Int, end: String, start: String, _ message: String) {
    let window = GitHubActivityWindow.make(period: .weekdays, count: count, now: date(end), calendar: calendar)
    check(window?.start == date(start) && window?.end == date(end), message)
}

weekdays(2, end: "2026-10-26 09:00:00", start: "2026-10-22 09:00:00", "Monday morning reaches Thursday morning")
weekdays(2, end: "2026-10-27 09:00:00", start: "2026-10-23 09:00:00", "Tuesday morning reaches Friday morning")
weekdays(2, end: "2026-10-30 16:23:45", start: "2026-10-28 16:23:45", "ordinary weekdays preserve time to the second")
weekdays(2, end: "2026-10-26 00:00:00", start: "2026-10-22 00:00:00", "midnight skips the entire weekend")
weekdays(2, end: "2026-10-31 12:00:00", start: "2026-10-29 00:00:00", "Saturday consumes no weekday hours")
weekdays(2, end: "2026-11-01 12:00:00", start: "2026-10-29 00:00:00", "Sunday consumes no weekday hours")
weekdays(2, end: "2026-11-02 09:00:00", start: "2026-10-29 09:00:00", "fall DST weekend preserves local weekday bounds")
weekdays(2, end: "2026-03-09 09:00:00", start: "2026-03-05 09:00:00", "spring DST weekend preserves local weekday bounds")
weekdays(1, end: "2026-10-26 09:00:00", start: "2026-10-23 09:00:00", "one weekday is configurable")
weekdays(5, end: "2026-10-26 09:00:00", start: "2026-10-19 09:00:00", "five weekdays span a calendar week")
weekdays(2, end: "2026-12-28 09:00:00", start: "2026-12-24 09:00:00", "holidays count as weekdays")

let now = date("2026-10-26 09:00:00")
let elapsed = GitHubActivityWindow.make(period: .hours, count: 48, now: now, calendar: calendar)!
check(elapsed.start == date("2026-10-24 09:00:00"), "calendar hours do not skip weekends")
let custom = GitHubActivityWindow.make(period: .custom, customStart: date("2026-10-01 12:00:00"),
                                       customEnd: date("2026-10-25 18:30:00"), now: now)!
check(custom.end == date("2026-10-25 18:30:00"), "custom historical end is preserved")
check(GitHubActivityWindow.make(period: .custom, customStart: now, customEnd: now, now: now) == nil,
      "empty custom range is rejected")
check(GitHubActivityWindow.make(period: .custom, customStart: now, customEnd: elapsed.start, now: now) == nil,
      "reversed custom range is rejected")
check(GitHubActivityWindow.make(period: .custom, customStart: elapsed.start,
                                customEnd: now.addingTimeInterval(60), now: now) == nil, "future end is rejected")
for period in [GitHubActivityPeriod.weekdays, .hours] {
    check(GitHubActivityWindow.make(period: period, count: 0) == nil, "zero \(period) is rejected")
    check(GitHubActivityWindow.make(period: period, count: Int.max) == nil, "unbounded \(period) is rejected")
}

// Use a volatile defaults domain so checks never persist or alter app settings.
UserDefaults.standard.setVolatileDomain([ActionOutputLanguage.storageKey: "Russian"], forName: UserDefaults.argumentDomain)
let prompt = TerminalPrompt.all.first { $0.id == "github-activity" }!
let rendered = prompt.text(file: nil, pullRequest: nil, activityWindow: custom)
check(prompt.input == .githubActivity, "button asks for its activity period")
check(rendered.contains("2026-10-01T17:00:00.000Z") && rendered.contains("2026-10-25T23:30:00.000Z"),
      "prompt contains exact UTC bounds, including the custom end")
check(!rendered.contains("{window}"), "no unresolved window placeholder")
check(rendered.contains("updated AFTER the window") && rendered.contains("complete\npagination"),
      "historical scans retain candidates updated later and require pagination")
check(rendered.contains("including weekend activity"), "weekend events remain inside the scan")
check(rendered.contains("ALL existing local features and bugs"), "matching covers older local records")
check(rendered.contains("not application implementation or GitHub\nmutations"), "scope is local reconciliation")
check(rendered.contains("Write the final report in Russian."), "selected report language is used")
UserDefaults.standard.setVolatileDomain([ActionOutputLanguage.storageKey: ActionOutputLanguage.documentLanguage], forName: UserDefaults.argumentDomain)
check(prompt.text(file: nil, pullRequest: nil, activityWindow: custom).contains("Write the final report in Russian."),
      "report defaults to Russian without changing repository language rules")
UserDefaults.standard.setVolatileDomain([ActionOutputLanguage.storageKey: "English"], forName: UserDefaults.argumentDomain)
check(prompt.text(file: nil, pullRequest: nil, activityWindow: custom).contains("Write the final report in English."),
      "explicit output language overrides the report default")
UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)

let review = TerminalPrompt.all.first { $0.id == "review-pr" }!
check(review.text(file: nil, pullRequest: "#123").contains("Review #123"), "existing PR substitution still works")
check(TerminalPrompt.all.first { $0.id == "explain-file" }!.text(file: "src/demo.swift", pullRequest: nil)
        .contains("Explain src/demo.swift"), "existing file substitution still works")

print(failures == 0 ? "All GitHub activity prompt checks passed." : "\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
